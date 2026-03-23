---
layout:    "single"
classes:   "wide"
title:     "Query Parquet Files on S3 from .NET with DataFusionSharp"
excerpt:   "Run SQL queries on Parquet files stored in Amazon S3 directly from C# — no Python, no Athena, no file downloads. DataFusionSharp brings Apache DataFusion's query engine to .NET with full support for S3, Hive partitioning, and partition pruning."
tags:      "dotnet csharp datafusion s3 aws parquet arrow datafusionsharp"
date:      "2026-03-23"
header:
  teaser: /assets/posts/datafusion-sharp-s3/logo.png
toc: false
---

Sooner or later, every data workflow ends up with files in S3. A data pipeline writes Parquet output to a bucket. A vendor drops CSV exports into a shared prefix. A public dataset lives in an AWS open data registry. You need to explore it, query it, maybe join it with something else — and you're working in .NET.

The typical path forward is to leave .NET. Fire up a Jupyter notebook with PyArrow, spin up an Athena query, or download the files locally and process them with something else. If you've done this enough times, the friction becomes familiar: context-switching between languages, waiting for infrastructure, or managing local copies of data that already lives perfectly well in the cloud.

When I built [DataFusionSharp](https://github.com/nazarii-piontko/datafusion-sharp), the first version only worked with local files — CSV, Parquet, and JSON on disk. That was useful, but it didn't address the reality that most analytical data lives in object stores. The latest release changes that. DataFusionSharp now supports S3, Azure Blob Storage, Google Cloud Storage, and HTTP endpoints as data sources. Register a store, register a table, write SQL. The data stays where it is.

This post walks through querying Parquet data in S3 from a .NET console application. The dataset is public, so everything here runs without AWS credentials.

## Connecting to S3

The pattern is two steps: register an object store for a URL scheme, then register tables using URLs instead of local paths. Here's what connecting to a public S3 bucket looks like:

```csharp
using var runtime = DataFusionRuntime.Create();
using var context = runtime.CreateSessionContext();

// Register public S3 bucket (no credentials needed)
context.RegisterS3ObjectStore("s3://arrow-datasets", new S3ObjectStoreOptions
{
    BucketName = "arrow-datasets",
    Region = "us-east-1",
    SkipSignature = true,
});
```

`SkipSignature = true` tells the client to skip request signing, which is how you access public buckets anonymously. For private buckets, you'd set `AccessKeyId` and `SecretAccessKey`, or provide a session `Token` for temporary credentials. If you're running on EC2 or ECS with an IAM role, leave the credentials out entirely and the AWS credential chain handles it.

The same pattern works for S3-compatible services like MinIO — just set the `Endpoint` property to your service URL and `AllowHttp = true` if you're not using TLS.

## Hive Partitioning

The dataset we'll query is the diamonds dataset from the Apache Arrow test data registry. It's stored as Parquet files using Hive-style partitioning, where directory names encode column values:

```
s3://arrow-datasets/diamonds/
  cut=Fair/
    part-0.parquet
  cut=Good/
    part-0.parquet
  cut=Ideal/
    part-0.parquet
  cut=Premium/
    part-0.parquet
  cut=Very Good/
    part-0.parquet
```

Each subdirectory contains rows for one value of the `cut` column. The column itself doesn't exist inside the Parquet files — DataFusion reconstructs it from the directory structure. To use this, you declare partition columns when registering the table:

```csharp
await context.RegisterParquetAsync("diamonds", "s3://arrow-datasets/diamonds/",
    new ParquetReadOptions
    {
        TablePartitionCols = [new PartitionColumn("cut", StringType.Default)],
        ParquetPruning = true,
    });
```

`TablePartitionCols` tells DataFusion which directory levels map to which columns and their types. `ParquetPruning = true` enables predicate pushdown at the partition level: when your query filters on `cut`, DataFusion only reads the matching partition directories. A `WHERE cut = 'Ideal'` skips four out of five partitions entirely. For large datasets with many partitions, this is the difference between scanning everything and scanning almost nothing.

## Querying the Data

Once the table is registered, everything works exactly like querying local files. The SQL is standard, the results come back as Arrow batches, and you can use the same `DataFrame` API from my [previous post](/2026/02/24/datafusion-sharp).

A useful first step with an unfamiliar dataset is inspecting its schema:

```csharp
using (var df = await context.SqlAsync("SELECT * FROM diamonds LIMIT 0"))
{
    var schema = df.GetSchema();
    foreach (var field in schema.FieldsList)
        Console.WriteLine($"  {field.Name}: {field.DataType.Name}");
}
```

The `LIMIT 0` trick returns no rows but still resolves the full schema, including the `cut` partition column that DataFusion injects. This is a fast way to understand what columns are available before writing any real queries.

With the schema in hand, we can run aggregations. Here's a breakdown of price statistics by cut:

```csharp
using (var df = await context.SqlAsync("""
    SELECT
        cut,
        count(*) AS cnt,
        ROUND(avg(price), 2) AS avg_price,
        min(price) AS min_price,
        max(price) AS max_price,
        ROUND(stddev(price), 2) AS price_stddev
    FROM diamonds
    GROUP BY cut
    ORDER BY avg_price DESC
    """))
    Console.WriteLine(await df.ToStringAsync());
```

DataFusionSharp also supports parameterized queries. Parameters are passed as a list of name-value tuples, and DataFusion substitutes them before execution:

```csharp
using (var df = await context.SqlAsync("""
    SELECT carat, color, clarity, price
    FROM diamonds
    WHERE cut = $cut
      AND carat >= $min_carat
    ORDER BY price DESC
    LIMIT 10
    """,
    [("cut", "Ideal"), ("min_carat", 2.0)]))
    Console.WriteLine(await df.ToStringAsync());
```

Notice that the `$cut` parameter filters on the partition column. Because partition pruning is enabled, DataFusion resolves the parameter value before planning the scan and only reads the `cut=Ideal/` directory. The other partitions are never touched.

Query results can also be written back to files. If you want to materialize an aggregation as a local Parquet file:

```csharp
using (var df = await context.SqlAsync("""
    SELECT
        cut,
        color,
        count(*) AS cnt,
        ROUND(avg(price), 2) AS avg_price,
        ROUND(avg(carat), 3) AS avg_carat
    FROM diamonds
    GROUP BY cut, color
    ORDER BY cut, color
    """))
{
    var outputPath = Path.Combine(Directory.GetCurrentDirectory(), "output", "diamond_summary.parquet");
    Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
    await df.WriteParquetAsync(outputPath);
    Console.WriteLine($"Written to: {outputPath}");
}
```

This reads from S3, aggregates in-process, and writes the result locally — a one-way ETL step in a dozen lines.

## Working with Arrow Batches

When you need to process results programmatically rather than printing them, `CollectAsync` gives you Apache Arrow `RecordBatch` objects with typed column arrays:

```csharp
using (var df = await context.SqlAsync("""
    SELECT
        carat,
        cut,
        color,
        clarity,
        price,
        ROUND(CAST(price AS DOUBLE) / carat, 2) AS price_per_carat
    FROM diamonds
    WHERE carat > 0.5
    ORDER BY price_per_carat ASC
    LIMIT 5
    """))
{
    using var collected = await df.CollectAsync();
    foreach (var batch in collected.Batches)
    {
        for (var r = 0; r < batch.Length; r++)
        {
            for (var c = 0; c < batch.ColumnCount; c++)
            {
                var v = batch.Column(c) switch
                {
                    StringArray a => (object?)a.GetString(r),
                    DoubleArray a => a.GetValue(r),
                    Int64Array a => a.GetValue(r),
                    FloatArray a => a.GetValue(r),
                    _ => batch.Column(c).GetType().Name
                };
                Console.Write($"{v}\t");
            }
            Console.WriteLine();
        }
    }
}
```

These are the same Arrow `RecordBatch` objects you'd get from querying local files. The [Apache.Arrow](https://www.nuget.org/packages/Apache.Arrow) NuGet package gives you typed arrays (`StringArray`, `DoubleArray`, `Int64Array`, etc.), schema introspection, and interoperability with other Arrow-compatible tools in the .NET ecosystem.

## Beyond S3

The same object store pattern works for other cloud storage backends. Azure Blob Storage uses the `az://` scheme:

```csharp
context.RegisterAzureBlobStorage("az://my-container", new AzureBlobStorageOptions
{
    ContainerName = "my-container",
    AccountName = "myaccount",
    AccessKey = "base64key...",
});
```

Google Cloud Storage uses `gs://`:

```csharp
context.RegisterGoogleCloudStorage("gs://my-bucket", new GoogleCloudStorageOptions
{
    BucketName = "my-bucket",
    CredentialsPath = "/path/to/service-account.json",
});
```

Each backend has its own options class with the authentication methods you'd expect: access keys, SAS tokens, service principals for Azure; service account credentials for GCS. HTTP endpoints are also supported for read-only access to data served over plain HTTPS.

The query code doesn't change — once a table is registered, SQL works the same regardless of where the data lives. This is one of the things I appreciate about DataFusion's architecture: the storage layer is fully decoupled from the query engine.

## Getting Started

```bash
dotnet add package DataFusionSharp
```

The complete example from this post is available in the [DataFusionSharp repository](https://github.com/nazarii-piontko/datafusion-sharp) under `examples/QueryS3Data`. The public `arrow-datasets` bucket needs no AWS credentials, so you can run it as-is.

---

DataFusionSharp is on GitHub at [github.com/nazarii-piontko/datafusion-sharp](https://github.com/nazarii-piontko/datafusion-sharp). If you're new to the library, the [introductory post](/2026/02/24/datafusion-sharp) covers the basics — runtime, sessions, and local file queries. If you run into issues or have ideas for the API, open an issue or a pull request.
