---
layout:    "single"
classes:   "wide"
title:     "Introducing DataFusionSharp: Apache DataFusion for .NET"
excerpt:   "Apache DataFusion is one of the most capable query engines available today — but until now, .NET developers had no way to use it. DataFusionSharp bridges that gap with idiomatic C# bindings built on Rust FFI and Apache Arrow."
tags:      "dotnet csharp rust datafusion"
date:      "2026-02-24"
header:
  teaser: /assets/posts/datafusion-sharp/logo.png
toc: false
---

At some point, every .NET developer working with data hits a wall. Maybe you have a directory full of Parquet files that keeps growing, or a few CSV dumps from a data pipeline that you need to join and aggregate. You don't want to spin up a database, you don't want to write a Python script, and you don't want to roll your own file parser. You just want to run a SQL query and get results.

The options in the .NET ecosystem have historically been limited. You could use `System.Data` with a file-backed SQLite database, wire up DuckDB, or ship data over the network to an external query engine. None of these feel right as a first-class .NET solution. What's missing is an idiomatic, embeddable, high-performance SQL query engine that works directly on columnar data — something .NET has never really had.

That gap is what motivated me to build **DataFusionSharp**.

## What Is Apache DataFusion?

[Apache DataFusion](https://datafusion.apache.org/) is a query engine written in Rust, built on top of [Apache Arrow](https://arrow.apache.org/). It's designed for high-performance analytical workloads: think scanning large files, aggregating millions of rows, joining multiple tables — all processed in-process without a server.

What makes DataFusion stand out is the combination of things it brings together:

- **Vectorized execution** — it processes data in columnar batches using Apache Arrow's in-memory format, which maps naturally to modern CPU cache behavior and SIMD instructions
- **SQL query optimizer** — a full logical and physical query planner with rule-based and cost-based optimizations
- **Datasource abstraction** — read from CSV, Parquet, JSON, or plug in a custom source
- **Async, parallel execution** — built on Tokio, DataFusion can execute queries using a thread pool with true async I/O

DataFusion has become the foundation for a number of serious data tools in the Rust ecosystem. The Python community got [datafusion-python](https://github.com/apache/datafusion-python) — official Apache-maintained bindings. The Java community got [datafusion-java](https://github.com/datafusion-contrib/datafusion-java). The .NET community had nothing. Until now.

## Introducing DataFusionSharp

[DataFusionSharp](https://github.com/nazarii-piontko/datafusion-sharp) is a .NET library that exposes Apache DataFusion through idiomatic C# APIs. The approach is straightforward: a thin Rust FFI layer bridges the managed and native worlds, and C# P/Invoke calls drive it from the .NET side. Results are exchanged using Apache Arrow's C Data Interface, so you get native Arrow `RecordBatch` objects on the .NET side.

The library is organized around three types that map directly to how DataFusion works:

**`DataFusionRuntime`** — wraps a Tokio async runtime and manages the native library's lifecycle. Create one per application and keep it alive for the duration of your process. It owns the thread pool that executes your queries.

**`SessionContext`** — an isolated query execution environment. Register your data sources here and execute SQL. Multiple contexts can coexist on the same runtime, and each is independent: tables registered in one context are not visible in another. Create one per logical session or per query workflow.

**`DataFrame`** — a lazy handle to a query result. The actual computation happens when you call a terminal operation. Available terminal operations are:
- `CollectAsync()` — execute the query and return all results as Arrow `RecordBatch` objects
- `ExecuteStreamAsync()` — execute the query and stream results as an `IAsyncEnumerable<RecordBatch>`
- `CountAsync()` — count result rows without materializing data
- `GetSchemaAsync()` — inspect the result schema before executing
- `ShowAsync()` / `ToStringAsync()` — print results, useful during development

The library ships prebuilt native binaries for Linux x64, Linux arm64, Windows x64, and macOS arm64, so you don't need a Rust toolchain to use it. Add it with:

```bash
dotnet add package DataFusionSharp
```

## A Quick Example

Let's say we have two CSV files: `customers.csv` with customer records and `orders.csv` with order data, and we want to find the total completed order value per customer. Here is the full program:

```csharp
using Apache.Arrow;
using DataFusionSharp;

// Create runtime — one per application, owns the Tokio thread pool
using var runtime = DataFusionRuntime.Create();

// Create session — one per logical query workflow
using var context = runtime.CreateSessionContext();

// Register CSV tables (Parquet and JSON work the same way)
await context.RegisterCsvAsync("customers", "data/customers.csv");
await context.RegisterCsvAsync("orders", "data/orders.csv");

// Execute SQL — returns a lazy DataFrame
using var df = await context.SqlAsync(
    """
    SELECT
        c.customer_name,
        sum(o.order_amount) AS total_amount
    FROM orders AS o
        JOIN customers AS c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'Completed'
    GROUP BY c.customer_name
    ORDER BY c.customer_name
    """);

// Print a formatted table to console — handy for development
Console.WriteLine(await df.ToStringAsync());

// Inspect the result schema
var schema = await df.GetSchemaAsync();
foreach (var field in schema.FieldsList)
    Console.WriteLine($"{field.Name}: {field.DataType}");
```

Notice the structure: create runtime, create session, register sources, execute SQL, consume results. The SQL is standard — the same query would run unchanged in PostgreSQL or DuckDB.

For use cases where you need to process rows as they come rather than loading everything into memory at once, `ExecuteStreamAsync` gives you an async enumerable of `RecordBatch` objects:

```csharp
using var stream = await df.ExecuteStreamAsync();
await foreach (var batch in stream)
{
    for (var row = 0; row < batch.Length; row++)
    {
        var name = ((StringArray)batch.Column(0)).GetString(row);
        var total = ((Int64Array)batch.Column(1)).GetValue(row);
        Console.WriteLine($"{name}: {total}");
    }
}
```

If you prefer to collect all data at once and then process it in memory, `CollectAsync` returns a collection of batches:

```csharp
using var result = await df.CollectAsync();
foreach (var batch in result.Batches)
{
    // process batch...
}
```

Both paths give you Apache Arrow `RecordBatch` objects. The Arrow ecosystem in .NET — via the [Apache.Arrow](https://www.nuget.org/packages/Apache.Arrow) NuGet package — gives you typed arrays, schema introspection, and interoperability with other Arrow-compatible tools.

For Parquet files, the registration is a single method swap:

```csharp
await context.RegisterParquetAsync("orders", "data/orders.parquet");
```

The rest of the query code stays identical. Same for JSONL files:

```csharp
await context.RegisterJsonAsync("orders", "data/orders.json");
```

This is one of the things I appreciate about DataFusion's design: the query layer is completely decoupled from the storage layer.

## Current State

DataFusionSharp is early-stage software. Here is an honest picture of what works today and what doesn't:

| Component    | Feature                                   | Status                              |
|--------------|-------------------------------------------|-------------------------------------|
| Runtime      | Create Tokio runtime, graceful shutdown   | ✅                                  |
| Session      | Create session, execute SQL               | ✅                                  |
| Data Sources | CSV read/write                            | ✅ partial — basic options exposed  |
|              | Parquet read/write                        | ✅ partial — no options exposed yet |
|              | JSONL read/write                          | ✅ partial — no options exposed yet |
|              | In-memory tables                          | ❌ not yet                          |
| DataFrame    | Count, schema, collect, stream, print     | ✅                                  |
|              | Select, filter, join, aggregate operators | ❌ use SQL instead                  |
|              | Write to file                             | ✅ partial                          |
| Arrow        | Apache Arrow record batches               | ✅                                  |
|              | Zero-copy data transfer                   | ✅                                  |
| Advanced     | UDF registration                          | ❌ not yet                          |
|              | Catalog management                        | ❌ not yet                          |
| Platforms    | Linux x64/arm64, Windows x64, macOS arm64 | ✅                                  |

The practical implication: if you want to query CSV, Parquet, or JSON files using SQL and consume the results as Arrow batches, that works today and works well. If you need to push in-memory Arrow data into DataFusion, or register custom functions, or manage catalogs — those are on the roadmap.

Note that this is an independent community project. It is not affiliated with or endorsed by the Apache Software Foundation.

## What's Next

The most impactful things on the near-term roadmap:

- **In-memory table registration** — push an Arrow `RecordBatch` directly into a session context as a table, no files required
- **Catalog management** — expose APIs to create and manage catalogs, schemas, and tables programmatically
- **UDF support** — register C# functions that DataFusion can call during query execution

If any of these are interesting to you, contributions are very welcome.

---

DataFusionSharp is on GitHub at [github.com/nazarii-piontko/datafusion-sharp](https://github.com/nazarii-piontko/datafusion-sharp). If you try it and run into something unexpected, open an issue. If you have ideas for the API design or want to contribute, pull requests are open.
