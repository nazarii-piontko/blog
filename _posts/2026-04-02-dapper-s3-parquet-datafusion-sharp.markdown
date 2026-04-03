---
layout:    "single"
classes:   "wide"
title:     "Query S3 Parquet Files with Dapper and DataFusionSharp"
excerpt:   "Use Dapper — the same micro-ORM you use with PostgreSQL or SQL Server — to query Parquet files on S3. DataFusionSharp's ADO.NET provider turns Apache DataFusion into a standard DbConnection, so QueryAsync<T> just works."
tags:      "dotnet csharp datafusion s3 aws parquet dapper datafusionsharp adonet"
date:      "2026-04-02"
header:
  teaser: /assets/posts/datafusion-sharp-dapper/logo.png
toc: false
---

Dapper is the go-to micro-ORM for .NET developers. You write SQL, define a class, and Dapper maps rows to objects. It works with PostgreSQL, SQL Server, SQLite — anything that implements `DbConnection`. But it has never worked with files on S3. If your data lives in Parquet files in a bucket, you're back to writing Arrow column accessors, or leaving .NET entirely for a Python notebook.

DataFusionSharp's ADO.NET provider changes that. It wraps the Apache DataFusion query engine in a standard `DbConnection`, which means Dapper's `QueryAsync<T>`, anonymous parameter objects, and strongly-typed result mapping all work out of the box. Same patterns you already know — pointed at S3 instead of a database.

This post builds a real example: querying the U.S. Energy Information Administration's power plant data — three related Parquet files stored in a public S3 bucket. We'll write three-way JOINs across utilities, power plants, and generators to answer questions like: which utilities have the most generation capacity? What does the energy mix look like across states? What are the largest generators in the country?

## The ADO.NET Provider

The [previous two posts](/2026/02/24/datafusion-sharp) covered DataFusionSharp's core API — runtime, session context, DataFrame — and [querying S3 data](/2026/03/23/query-s3-parquet-dotnet-datafusion-sharp) using Arrow batches. That works well for data pipelines, but most .NET application code doesn't work with Arrow batches. Service layers, reporting code, controllers — they all expect `List<T>`.

The `DataFusionSharp.Data` package bridges this with a standard ADO.NET provider:

- `DataFusionSharpConnection` extends `DbConnection`
- `DataFusionSharpCommand` extends `DbCommand`
- `DataFusionSharpDataReader` extends `DbDataReader`
- `DataFusionSharpParameter` extends `DbParameter`

Because it implements `System.Data.Common` interfaces, any library built on ADO.NET works with DataFusionSharp. Dapper is the obvious one, but it also works with libraries like Insight.Database, or your own repository abstractions built on `DbConnection`.

## The Dataset

We'll use data from the [Public Utility Data Liberation (PUDL)](https://catalyst.coop/pudl/) project, which publishes cleaned U.S. energy data as Parquet files in a public S3 bucket. The three tables we need:

**Utilities** (`out_eia__yearly_utilities.parquet`, 2.3 MB) — utility company records: name, state, entity type. Primary key: `utility_id_eia` + `report_date`.

**Plants** (`out_eia__yearly_plants.parquet`, 3.2 MB) — power plant records: name, city, state, coordinates, NERC region. Links to its operating utility via `utility_id_eia`. Primary key: `plant_id_eia` + `report_date`.

**Generators** (`out_eia__yearly_generators.parquet`, 10.3 MB) — individual generator units within plants: capacity in MW, fuel type, technology description, net generation, capacity factor. Links to its plant via `plant_id_eia`. Primary key: `plant_id_eia` + `generator_id` + `report_date`.

The relationship chain is **Utility → Plants → Generators**. A utility operates one or more plants, and each plant has one or more generators. This is a textbook relational structure — exactly the kind of data that JOINs are made for.

## Setting Up

Install the packages:

```bash
dotnet add package DataFusionSharp.Data
dotnet add package Dapper
```

`DataFusionSharp.Data` pulls in the core `DataFusionSharp` package as a dependency.

Connect to S3, register the Parquet tables, and create a Dapper-compatible connection:

```csharp
using DataFusionSharp;
using DataFusionSharp.Data;
using DataFusionSharp.ObjectStore;
using Dapper;

using var runtime = DataFusionRuntime.Create();
using var session = runtime.CreateSessionContext();

// Register public S3 bucket - no credentials needed
session.RegisterS3ObjectStore("s3://pudl.catalyst.coop", new S3ObjectStoreOptions
{
    BucketName = "pudl.catalyst.coop",
    Region = "us-west-2",
    SkipSignature = true,
});

// Register Parquet tables from S3
await session.RegisterParquetAsync(
    "utilities",
    "s3://pudl.catalyst.coop/stable/out_eia__yearly_utilities.parquet");
await session.RegisterParquetAsync(
    "plants",
    "s3://pudl.catalyst.coop/stable/out_eia__yearly_plants.parquet");
await session.RegisterParquetAsync(
    "generators",
    "s3://pudl.catalyst.coop/stable/out_eia__yearly_generators.parquet");

// Create ADO.NET connection - this is what Dapper uses
await using var connection = session.AsConnection();
```

Three Parquet files registered as SQL tables, backed by S3, queryable through a standard `DbConnection`. The `AsConnection()` extension method wraps the session context in an ADO.NET connection that Dapper knows how to work with.

## Defining Models

Dapper maps query results to C# types by matching column aliases to property names. Define records for each query shape:

```csharp
public record UtilityCapacity(
    string UtilityName,
    string? State,
    long PlantCount,
    double TotalCapacityMw);

public record StateEnergyMix(
    string State,
    string FuelType,
    long GeneratorCount,
    double TotalCapacityMw,
    double? AvgCapacityFactor);

public record TopGenerator(
    string PlantName,
    string? City,
    string? State,
    string UtilityName,
    string? Technology,
    float CapacityMw,
    double? NetGenerationMwh,
    double? CapacityFactor);
```

## Querying with Dapper

### Which utilities have the most generation capacity?

A three-way JOIN across all three tables to rank utilities by total installed capacity:

```csharp
var topUtilities = await connection.QueryAsync<UtilityCapacity>("""
    SELECT
        u.utility_name_eia AS UtilityName,
        u.state AS State,
        COUNT(DISTINCT p.plant_id_eia) AS PlantCount,
        ROUND(CAST(SUM(g.capacity_mw) AS DOUBLE), 1) AS TotalCapacityMw
    FROM generators g
        JOIN plants p
            ON g.plant_id_eia = p.plant_id_eia
            AND g.report_date = p.report_date
        JOIN utilities u
            ON p.utility_id_eia = u.utility_id_eia
            AND p.report_date = u.report_date
    WHERE g.report_date = '2026-01-01'
        AND g.operational_status = 'existing'
    GROUP BY u.utility_name_eia, u.state
    ORDER BY TotalCapacityMw DESC
    LIMIT 15
    """);

foreach (var utility in topUtilities)
    Console.WriteLine($"{utility.UtilityName} ({utility.State}): {utility.TotalCapacityMw:N1} MW across {utility.PlantCount} plants");
```

This is standard Dapper — `QueryAsync<T>` with a SQL string. The SQL runs inside DataFusion's query engine, reading Parquet data from S3 on the fly. Dapper sees a `DbDataReader` and maps columns to record properties by name. The query joins across three files totaling 16 MB, filters to currently operating generators as of the 2026 reporting year, aggregates by utility, and returns the top 15.

### What does the energy mix look like?

Join generators with plants to analyze installed capacity by fuel type and state:

```csharp
var energyMix = await connection.QueryAsync<StateEnergyMix>("""
    SELECT
        p.state AS State,
        CAST(g.fuel_type_code_pudl AS VARCHAR) AS FuelType,
        COUNT(*) AS GeneratorCount,
        ROUND(CAST(SUM(g.capacity_mw) AS DOUBLE), 1) AS TotalCapacityMw,
        ROUND(CAST(AVG(g.capacity_factor) AS DOUBLE), 3) AS AvgCapacityFactor
    FROM generators g
        JOIN plants p
            ON g.plant_id_eia = p.plant_id_eia
            AND g.report_date = p.report_date
    WHERE g.report_date = '2026-01-01'
        AND g.operational_status = 'existing'
        AND p.state IS NOT NULL
    GROUP BY p.state, g.fuel_type_code_pudl
    ORDER BY TotalCapacityMw DESC
    LIMIT 20
    """);

foreach (var row in energyMix)
    Console.WriteLine($"{row.State} - {row.FuelType}: {row.TotalCapacityMw:N1} MW ({row.GeneratorCount} generators)");
```

Notice the `CAST(g.fuel_type_code_pudl AS VARCHAR)` — some Parquet columns use Arrow's dictionary encoding for efficient storage of repeated strings. The ADO.NET provider doesn't expose dictionary types directly, so casting to `VARCHAR` in the query is the simplest way to handle them. This shows where capacity is concentrated — which states have the most gas, coal, wind, or solar, and how their capacity factors compare.

### The largest generators in the country

A three-way JOIN to find the biggest individual generators with full context — plant name, location, operator, and technology:

```csharp
var largestGenerators = await connection.QueryAsync<TopGenerator>("""
    SELECT
        p.plant_name_eia AS PlantName,
        p.city AS City,
        p.state AS State,
        u.utility_name_eia AS UtilityName,
        g.technology_description AS Technology,
        g.capacity_mw AS CapacityMw,
        ROUND(CAST(g.net_generation_mwh AS DOUBLE), 0) AS NetGenerationMwh,
        ROUND(CAST(g.capacity_factor AS DOUBLE), 3) AS CapacityFactor
    FROM generators g
        JOIN plants p
            ON g.plant_id_eia = p.plant_id_eia
            AND g.report_date = p.report_date
        JOIN utilities u
            ON p.utility_id_eia = u.utility_id_eia
            AND p.report_date = u.report_date
    WHERE g.report_date = '2026-01-01'
        AND g.operational_status = 'existing'
        AND g.capacity_mw IS NOT NULL
    ORDER BY g.capacity_mw DESC
    LIMIT 10
    """);

foreach (var gen in largestGenerators)
    Console.WriteLine($"{gen.PlantName} ({gen.State}): {gen.CapacityMw:N0} MW - {gen.Technology} [{gen.UtilityName}]");
```

## Parameterized Queries

Dapper's anonymous parameter objects work with DataFusionSharp. The ADO.NET provider translates `@param` syntax to DataFusion's native `$param` format automatically:

```csharp
var state = "TX";
var minCapacityMw = 100f;

var texasPlants = await connection.QueryAsync<TopGenerator>("""
    SELECT
        p.plant_name_eia AS PlantName,
        p.city AS City,
        p.state AS State,
        u.utility_name_eia AS UtilityName,
        g.technology_description AS Technology,
        g.capacity_mw AS CapacityMw,
        ROUND(CAST(g.net_generation_mwh AS DOUBLE), 0) AS NetGenerationMwh,
        ROUND(CAST(g.capacity_factor AS DOUBLE), 3) AS CapacityFactor
    FROM generators g
        JOIN plants p
            ON g.plant_id_eia = p.plant_id_eia
            AND g.report_date = p.report_date
        JOIN utilities u
            ON p.utility_id_eia = u.utility_id_eia
            AND p.report_date = u.report_date
    WHERE g.report_date = '2026-01-01'
        AND g.operational_status = 'existing'
        AND p.state = @state
        AND g.capacity_mw >= @minCapacityMw
    ORDER BY g.capacity_mw DESC
    LIMIT 10
    """,
    new { state, minCapacityMw });

foreach (var plant in texasPlants)
    Console.WriteLine($"{plant.PlantName}: {plant.CapacityMw:N0} MW - {plant.Technology} [{plant.UtilityName}]");
```

The `@state` and `@minCapacityMw` parameters are passed as a standard Dapper anonymous object. Under the hood, `DataFusionSharpCommand` rewrites them to `$state` and `$minCapacityMw`, maps their .NET types to DataFusion scalar values, and injects them into the query plan.

Scalar queries work the same way — `ExecuteScalarAsync` returns a single value:

```csharp
var totalCapacity = await connection.ExecuteScalarAsync<double>("""
    SELECT ROUND(CAST(SUM(g.capacity_mw) AS DOUBLE), 1)
    FROM generators g
        JOIN plants p
            ON g.plant_id_eia = p.plant_id_eia
            AND g.report_date = p.report_date
    WHERE g.report_date = '2026-01-01'
        AND g.operational_status = 'existing'
        AND p.state = @state
    """,
    new { state = "CA" });

Console.WriteLine($"California total installed capacity: {totalCapacity:N1} MW");
```

---

The complete example from this post is available in the [DataFusionSharp repository](https://github.com/nazarii-piontko/datafusion-sharp) under `examples/QueryS3DataWithDapper`. The dataset is publicly available — no AWS credentials required. The PUDL project publishes cleaned EIA data at `s3://pudl.catalyst.coop/stable/` under a [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) license.

If you're already using Dapper with a database today, adding DataFusionSharp as a second data source is straightforward: the same `QueryAsync<T>` calls, the same parameter passing, the same result mapping — just pointed at files in S3 instead of rows in a table.

---

DataFusionSharp is on GitHub at [github.com/nazarii-piontko/datafusion-sharp](https://github.com/nazarii-piontko/datafusion-sharp). If you're new to the library, the [introductory post](/2026/02/24/datafusion-sharp) covers the fundamentals — runtime, sessions, and local file queries. The [S3 querying post](/2026/03/23/query-s3-parquet-dotnet-datafusion-sharp) goes deeper on object store configuration, Hive partitioning, and Arrow batch processing. If you run into issues or have ideas for the API, open an issue or a pull request.
