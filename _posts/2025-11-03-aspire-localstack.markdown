---
layout: single
classes: wide
title: Configuring .NET Aspire with AWS and LocalStack
excerpt: Stop paying for AWS services during development or fighting over shared dev environments. Here's how to use LocalStack with .NET Aspire to develop against AWS services locally, with automatic configuration injection that makes the same code work in development and production.
tags: dotnet, aspire, aws, localstack
date: 2025-11-03
toc: false
header:
 teaser: /assets/posts/aspire-localstack/logo.png
---

Developing a .NET application that uses AWS services presents several challenges. Either we're constantly hitting real AWS and watching our bill climb, or mocking everything and wondering if code actually works. Teams often share dev environments, stepping on each other's data and debugging sessions. Developers frequently get stuck waiting for the "dev environment" to be free while someone else is testing their integration. .NET Aspire helps with microservice orchestration, but it doesn't solve the AWS development problem.

That's where [LocalStack](https://www.localstack.cloud/) comes in. Think of it as AWS running on our computer - S3, Lambda, DynamoDB, SQS, SNS, etc. The community edition is free and covers almost everything needed for typical development. No more spinning up separate AWS environments for each developer or dealing with resource cleanup across multiple accounts. Plus, we get faster feedback loops, can work offline, and can reset entire environment with a simple container restart.

In this article, we'll build a practical example that many developers encounter: an API service that uploads files to S3 and serves them via static website hosting (or CDN). This pattern is everywhere: profile picture uploads, document storage, media galleries, etc. We'll configure everything through .NET Aspire and LocalStack, so the same code works locally and in production without changes.

Before diving into the configuration, we need to get the dependencies right. We'll need one package in our Aspire AppHost project:

```xml
<PackageReference Include="LocalStack.Aspire.Hosting" Version="9.5.2" />
```

This package includes everything: LocalStack container management, AWS CDK integration, and CloudFormation orchestration.

Next, we need to configure the AWS SDK by adding a shared AWS configuration context:

```csharp
var awsConfig = builder.AddAWSSDKConfig()
    .WithProfile("default")
    .WithRegion(RegionEndpoint.EUCentral1);
```

The profile leverages AWS credential chains - local development can use AWS CLI profiles, while production uses IAM roles. Region specification ensures correct endpoints. We can make this more flexible with configuration:

```csharp
var awsConfig = builder.AddAWSSDKConfig()
    .WithProfile(builder.Configuration["AWS:Profile"] ?? "default")
    .WithRegion(RegionEndpoint.GetBySystemName(builder.Configuration["AWS:Region"] ?? "eu-central-1"));
```

Next, we need to set up LocalStack itself by telling Aspire to manage a LocalStack container for us, configure its lifetime, and set logging levels for debugging:

```csharp
var awsLocal = builder.AddLocalStack("aws-local",
    awsConfig: awsConfig,
    configureContainer: c =>
    {
        c.Lifetime = ContainerLifetime.Persistent;
        c.DebugLevel = 1;
        c.LogLevel = LocalStackLogLevel.Debug;
    });
```

Key settings here:
- **Lifetime**:
    - `Persistent`: container survives app restarts, keeping our data
    - `Session`: container resets every time we restart the app
- **LogLevel**: see exactly what's happening with AWS calls
- **DebugLevel**: `1` - detailed request/response logging for troubleshooting

The persistent lifetime is important; we don't want to recreate S3 buckets every time we restart debugging. While Session lifetime is useful for testing setups, Persistent lifetime is better for day-to-day development.

The important part here is the AppHost configuration. `AddLocalStack` will use the `LocalStack:UseLocalStack` setting to determine whether it should run in local mode. It looks for this setting in our configuration (`appsettings.json`, environment variables, etc.):

```json
{
  "LocalStack": {
    "UseLocalStack": true
  }
}
```

Without this setting, LocalStack integration is disabled, and our services will try to connect to real AWS. This makes it easy to switch between local development and production without code changes.

After that, we can start defining AWS infrastructure. We can define AWS infrastructure as code and have it work with both LocalStack and real AWS. We'll use the AWS CDK (Cloud Development Kit) for this. Think of it as a way to write our infrastructure using familiar programming languages instead of YAML or JSON. CDK lets us define AWS resources like S3 buckets, SQS queues, or Lambda functions using C# classes, complete with IntelliSense, type safety, and all the benefits of a real programming language. When we build our CDK code, it generates CloudFormation templates that AWS (or LocalStack) can deploy.

```csharp
var awsStack = builder.AddAWSCDKStack("aws-stack", s => new AwsStack(s))
    .WithReference(awsConfig);

var awsStackOutputs = AwsStack.Outputs.Add(awsStack);
```

`AwsStack` is a custom class where we define our AWS resources. To define the actual infrastructure, here's an S3 bucket with website hosting:

```csharp
public sealed class AwsStack : Amazon.CDK.Stack
{
    public IBucket Bucket { get; }

    public AwsStack(Constructs.Construct scope)
        : base(scope, "bucket")
    {
        // Create S3 bucket with website hosting enabled
        Bucket = new Bucket(this,
            "bucket",
            new BucketProps
            {
                BucketName = "test-data-bucket",
                AccessControl = BucketAccessControl.PRIVATE,
                WebsiteIndexDocument = "index.html"
            });

        // Allow public read access for static website hosting
        Bucket.AddToResourcePolicy(new PolicyStatement(new PolicyStatementProps
        {
            Actions = ["s3:GetObject"],
            Effect = Effect.ALLOW,
            Principals = [new AnyPrincipal()],
            Resources = [Bucket.ArnForObjects("*")]
        }));
    }
    
    // The Outputs class provides type-safe access to stack resources.
    // Instead of handling raw strings in Program.cs, this gives compile-time validation
    // and prevents typos from becoming runtime errors.
    public sealed class Outputs(IResourceBuilder<IStackResource> stack)
    {
        public StackOutputReference BucketName => stack.GetOutput(nameof(BucketName));

        public StackOutputReference BucketWebsiteUrl => stack.GetOutput(nameof(BucketWebsiteUrl));

        public static Outputs Add(IResourceBuilder<IStackResource<AwsStack>> stack)
        {
            stack.AddOutput(nameof(BucketName), s => s.Bucket.BucketName);
            stack.AddOutput(nameof(BucketWebsiteUrl), s => s.Bucket.BucketWebsiteUrl);
            return new Outputs(stack);
        }
    }
}
```

The bucket configuration sets up static website hosting with public read access. The resource policy allows public access to objects while keeping the bucket itself private. Similarly, we can define other AWS resources as needed. For example, for SQS queues, we can call `new Queue(this, "queue", new QueueProps { ... })` and expose outputs like `QueueUrl` and/or `QueueArn`. For DynamoDB tables, we can define `new Table(this, "table", new TableProps { ... })` and expose outputs like `TableName`.

Once the infrastructure is defined, we can reference these resources in our services. Here's how to configure an API service to use the S3 bucket we created:

```csharp
var apiService = builder.AddProject<Projects.ApiService>("apiservice")
    .WithHttpHealthCheck("/health")
    .WithReference(awsStack)
    .WithEnvironment("Storage__BucketName", awsStackOutputs.BucketName)
    .WithEnvironment("Storage__PublicBaseUrl", awsStackOutputs.BucketWebsiteUrl);
```

The `WithEnvironment(...)` calls inject these values as environment variables. `Storage__BucketName` becomes `Storage:BucketName` in our service's configuration.

It's also important to note that `WithReference(awsStack)` will automatically inject AWS resource outputs under the `AWS__Resources__*` configuration section, so we can access them directly as well. However, providing explicit configuration like `Storage:BucketName` in the service is often preferable to relying on generic output access. This approach also decouples our service configuration from the underlying infrastructure implementation, making it easier to change infrastructure without affecting service code.

Just before building the host, we need to enable LocalStack integration:

```csharp
builder.UseLocalStack(awsLocal);
```

This one line does a lot of heavy lifting. It configures all AWS resources in the application to use the specified LocalStack instance, automatically detects CloudFormation templates and CDK stacks, and handles CDK bootstrap if needed. This method scans all resources in the application and automatically configures AWS resources and projects that reference AWS resources to use LocalStack for local development. It:
- Detects all CloudFormation templates and CDK stack resources
- Creates a CDK bootstrap resource automatically if CDK stacks are present
- Configures all AWS resources to use LocalStack endpoints
- Sets up proper dependency ordering for CDK bootstrap
- Automatically configures projects that reference AWS resources
- Adds annotation tracking to prevent duplicate configuration

Here's where it gets really interesting. When we call `WithReference(awsStack)` and enable LocalStack, Aspire automatically injects configuration into our services. We don't have to manage any of this ourselves.

Our service gets all these environment variables automatically:

**LocalStack Configuration (Example)**:
```toml
LocalStack__UseLocalStack = True
LocalStack__Config__EdgePort = 42483
LocalStack__Config__LocalStackHost = localhost
LocalStack__Config__UseLegacyPorts = False
LocalStack__Config__UseSsl = False
LocalStack__Session__AwsAccessKey = secretKey
LocalStack__Session__AwsAccessKeyId = accessKey
LocalStack__Session__AwsSessionToken = token
LocalStack__Session__RegionName = eu-central-1
```

**AWS Resource References (Example)**:
```toml
AWS__Resources__ProfileBucketName = test-data-bucket
AWS__Resources__ProfileBucketWebsiteUrl = http://test-data-bucket.s3-website.localhost:42483
```

**Application Configuration (Example)**:
```toml
Storage__BucketName = test-data-bucket
Storage__PublicBaseUrl = http://test-data-bucket.s3-website.localhost:42483
```

This maps to a JSON configuration structure in our service:

```json
{
  "LocalStack": {
    "UseLocalStack": true,
    "Config": {
      "EdgePort": 42483,
      "LocalStackHost": "localhost",
      "UseLegacyPorts": false,
      "UseSsl": false
    },
    "Session": {
      "AwsAccessKey": "secretKey",
      "AwsAccessKeyId": "accessKey", 
      "AwsSessionToken": "token",
      "RegionName": "eu-central-1"
    }
  },
  "AWS": {
    "Resources": {
      "ProfileBucketName": "test-data-bucket",
      "ProfileBucketWebsiteUrl": "http://test-data-bucket.s3-website.localhost:42483"
    }
  },
    "Storage": {
    "BucketName": "test-data-bucket",
    "PublicBaseUrl": "http://test-data-bucket.s3-website.localhost:42483"
  }
}
```

It is also interesting that LocalStack handles URL rewriting for S3 website endpoints automatically. When we access `http://test-data-bucket.s3-website.localhost:42483`, LocalStack knows to route this to the correct S3 bucket in the LocalStack container. So if application code uploads an object to S3 and then constructs a URL using the bucket's website URL, it will work seamlessly with LocalStack without any additional configuration. Similarly, we can use CloudFront in front of S3 by creating a [Distribution object](https://aws-cdk.com/deploying-a-static-website-using-s3-and-cloudfront), and that will work with LocalStack as well.

Now the AppHost is configured. It's time to set up service itself to use the AWS SDK with LocalStack. In the service, we just need a couple of lines to make everything work:

```csharp
builder.Services.AddLocalStack(builder.Configuration);
builder.Services.AddDefaultAWSOptions(builder.Configuration.GetAWSOptions());
builder.Services.AddAwsService<IAmazonS3>();
```

That's it. The `AddLocalStack(...)` method reads all the configuration Aspire injected and sets up the AWS SDK to talk to LocalStack. S3 client now points to LocalStack automatically.

We can access our resources like this:

```csharp
// This works in all environments - no endpoint configuration needed
var bucketName = builder.Configuration["Storage:BucketName"];
var s3Client = serviceProvider.GetRequiredService<IAmazonS3>();
```

The beauty here is that the LocalStack client automatically falls back to real AWS when LocalStack isn't enabled. We don't need conditional registration - just use `AddAwsService<...>()` everywhere and let the configuration decide where calls go.

When it's all done, here's what happens under the hood when we run our application in local development mode with LocalStack enabled:

1. Aspire starts the LocalStack container
2. CDK stack deploys to LocalStack (creates the S3 bucket)
3. Aspire injects all the configuration services need
4. Services start up with LocalStack endpoints configured
5. AWS SDK calls go to LocalStack instead of real AWS

The result? We're developing against AWS services without touching real AWS. No surprise bills, no internet required, instant feedback.

When we deploy to production, we simply disable LocalStack by setting `LocalStack:UseLocalStack` to `false` and use `cdk` cli to push our infrastructure to real AWS. The details of deployment to real AWS are outside the scope of this article, but with Aspire and LocalStack, the same code works seamlessly in both local development and production environments.

Useful links:
- [LocalStack](https://github.com/localstack/localstack)
- [.NET Aspire Integrations for LocalStack](https://github.com/localstack-dotnet/dotnet-aspire-for-localstack)
- [LocalStack .NET Client](https://github.com/localstack-dotnet/localstack-dotnet-client)
- [Integrating AWS with .NET Aspire](https://aws.amazon.com/blogs/developer/integrating-aws-with-net-aspire/)
- [Working with the AWS CDK in C#](https://docs.aws.amazon.com/cdk/v2/guide/work-with-cdk-csharp.html)
- [LocalStack Provisioning Examples](https://github.com/localstack-dotnet/dotnet-aspire-for-localstack/tree/master/playground/provisioning)
