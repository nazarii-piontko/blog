---
layout: single
classes: wide
title: Deploying .NET Aspire to AWS
excerpt: Deploy .NET Aspire applications to AWS without maintaining separate infrastructure code. One C# project switches between local emulation and production. Aspire handles orchestration, AWS CDK handles provisioning.
tags: dotnet, aspire, aws, cdk
date: 2025-11-14
toc: false
header:
 teaser: /assets/posts/aspire-aws-deployment/logo.png
---

In the [previous article](/2025/11/03/aspire-localstack) I set up a local development loop using Aspire + LocalStack. No AWS costs, fast iterations, AWS services emulation. The natural next question: how do we deploy this same application to AWS environments (testing, staging, production) without maintaining separate infrastructure code? And can we even do this while keeping everything in C#? Long story short: yes, but with some trade-offs.

This article shows the pattern: one Aspire Host project that switches between local emulation and real AWS deployment based on execution context. When running locally, Aspire wires up LocalStack and containers. When publishing, the same file hands off to an AWS CDK stack that provisions VPC, Aurora Serverless, DynamoDB, Lambda, and API Gateway. Same logical service architecture (API → Database, API → DynamoDB), slightly different infrastructure implementations.

Before diving into code, the key constraint: Aspire today (late 2025) doesn't have a native publisher for AWS. It can't package a .NET project into a Lambda-compatible zip, manage versions, or model AWS-specific resources like RDS Proxy or VPC endpoints. Luckily, AWS CDK already solves all of this. So the pattern is: **Aspire orchestrates (decides local vs publish, wires references), CDK provisions (synthesizes CloudFormation, bundles Lambda assets, deploys to AWS)**. This keeps everything in one place without waiting for Aspire to grow full AWS deployment primitives. Think of it as Aspire being the high-level orchestrator that knows about services and their relationships, while CDK is the specialized tool that knows exactly how to package .NET code for Lambda, create VPC configurations, and wire up security groups. Each tool does what it does best.

## What We'll Build

We'll deploy a sample application based on a serverless services: a Lambda function running our API, Aurora Serverless v2 for PostgreSQL, DynamoDB for auxiliary storage, and API Gateway routing HTTP traffic. Everything runs in a private VPC with no direct internet access except the API Gateway endpoint.

During local development, Aspire spins up LocalStack to emulate DynamoDB and other AWS services, plus a Postgres container for the database. When publishing, we'll provision real AWS resources.

**Local mode**:
- LocalStack emulates DynamoDB
- Local Postgres container for the database
- AWS Lambda emulator runs the API locally
- API Gateway emulator routes HTTP requests

**AWS mode**:
- CDK stack provisions real AWS resources
- VPC
- Aurora Serverless v2 + RDS Proxy
- DynamoDB table
- Lambda function
- HTTP API Gateway

## The Aspire Host

Now that we've outlined the architectural differences, let's see how Aspire orchestrates this dual-mode behavior. The key insight is that Aspire can detect whether it's running in local development mode or publish mode (when deploying to AWS), and conditionally wire up different infrastructure providers based on that context.

The entire orchestration logic lives in a single host file. There's no separate deployment configuration, no CI/CD YAML with infrastructure definitions scattered across multiple files. Instead, we use Aspire's `ExecutionContext.IsPublishMode` to branch between local emulation and AWS deployment:

Here's the complete branching logic:

```csharp
// Select between local emulation and AWS deployment
// IsPublishMode is true when running 'dotnet run --project Host -- --publisher ...'
if (builder.ExecutionContext.IsPublishMode)
{
    // AWS SDK configuration
    var awsConfig = builder.AddAWSSDKConfig()
        .WithProfile(builder.Configuration.GetValue("AWS:Profile"))
        .WithRegion(RegionEndpoint.GetBySystemName(builder.Configuration.GetValue("AWS:Region")));

    // CDK stack provisioning full production infrastructure
    builder.AddAWSCDKStack("AwsSampleStack", s => new SampleStack(s))
        .WithReference(awsConfig);
}
else
{
    // AWS SDK configuration for LocalStack
    var awsConfig = builder.AddAWSSDKConfig()
        .WithProfile(builder.Configuration.GetValue("AWS:Profile"))
        .WithRegion(RegionEndpoint.GetBySystemName(builder.Configuration.GetValue("AWS:Region")));
    
    // LocalStack setup
    var awsLocal = builder.AddLocalStack("AwsLocal", awsConfig: awsConfig);
    
    // CDK stack provisioning subset of resources for LocalStack
    var awsStack = builder.AddAWSCDKStack("AwsSampleBaseStack", s => new SampleBaseStack(s))
        .WithReference(awsConfig);

    // Local Postgres container
    var postgres = builder.AddPostgres("Postgres");

    // Lambda function running the API locally
    var api = builder.AddAWSLambdaFunction<Projects.Api>("Api", "Api")
        .WithReference(awsStack)
        .WithReference(postgres);

    // API Gateway emulator routing all requests to the Lambda
    builder.AddAWSAPIGatewayEmulator("ApiGatewayEmulator", APIGatewayType.HttpV2)
        .WithReference(api, Method.Any, "/{proxy+}");
    
    // Wire up LocalStack
    builder.UseLocalStack(awsLocal);
}
```

**Key differences:**
- **CDK Stack**: Publish provisions `SampleStack` (full production infrastructure with VPC, Aurora, Lambda, API Gateway); local provisions `SampleBaseStack` (just a subset of AWS services for LocalStack to emulate, DynamoDB table)
- **Database**: Local adds an explicit Postgres container resource; publish mode relies on the RDS Aurora cluster defined in the CDK stack
- **Lambda Reference**: Local mode uses `.AddAWSLambdaFunction<Projects.Api>` to run the API as a Lambda emulator locally

That single `IsPublishMode` check is the seam between emulation and deployment. When we run `dotnet run --project Host`, we get local mode. When we run `dotnet run --project Host -- --publisher ...`, we get publish mode and CDK takes over.

## The Environment Parity Trade-Off

Here's the elephant in the room: this approach technically violates the principle of environment parity. Local mode uses Postgres in a container; production uses Aurora Serverless v2 with RDS Proxy. Local uses LocalStack's DynamoDB emulation; production uses real DynamoDB. Local runs the API in a Lambda emulator; production runs it in actual Lambda with VPC networking, security groups, and IAM roles.

**So why accept this split?**

Perfect parity between local and cloud is rarely worth the cost. Emulating every managed service nuance (full VPC routing, Aurora serverless scaling behavior, RDS Proxy, IAM evaluation, realistic latency) on a laptop adds friction and slows the inner loop. The alternative - developing directly against live AWS - slows feedback (deploy per change), consumes budget, requires constant connectivity, and blocks offline work.

So we aim for **logical parity over physical parity**: same code paths, dependency graph, configuration keys, contracts (HTTP/data/events), and instrumentation; different implementations tuned for their environment. Local maximizes iteration speed; production maximizes reliability, scalability, and security.

What makes this work:
- **Same application code**: The services code runs identically in both environments. We use a small provider pattern: a startup flag selects which dependencies to register (LocalStack endpoints + static Postgres password OR real AWS SDK clients + IAM auth token generator). Endpoints only depend on abstractions like `IDynamoDBContext` and `NpgsqlDataSource`, so no code changes are needed when swapping providers (we'll see the API configuration details later).
- **Single repository ownership**: Infrastructure and application code live together. No separate IaC repo, no coordination between teams, no deployment scripts scattered across CI/CD pipelines.
- **Reduced maintenance burden**: When we add a new service (e.g., SQS queue), we add it once in the CDK stack. LocalStack automatically emulates it locally; CloudFormation provisions it in production. No duplicate YAML files, no drift.
- **Developer autonomy**: Developers can iterate locally without AWS credentials, network access, or cloud costs. When ready, they deploy the same codebase with one command, either manually, either via CI/CD.

The cost is awareness: developers need to know that Postgres and Aurora aren't byte-for-byte identical (e.g., Aurora-specific features won't work locally), and that LocalStack's emulation has limitations. But this is a manageable trade-off compared to maintaining separate infrastructure repositories or forcing developers to develop against live AWS.

## The CDK Stack: AWS Infrastructure

Now that we understand the orchestration strategy and trade-offs, let's examine how CDK provisions the actual AWS infrastructure. Remember, in publish mode, the Aspire Host hands off to `SampleStack`, which defines all the production resources. Here's what gets created:

1. **VPC with isolated subnets** → no internet gateway, no public IPs
2. **Aurora Serverless v2 cluster** → auto-scaling Postgres (0.5-1 ACU)
3. **RDS Proxy** → connection pooling + IAM auth for Lambda
4. **DynamoDB table** → table with partition key
5. **Lambda function** → .NET 8 runtime, bundled via Docker (AWS currently supports .NET 8 as bundled runtime)
6. **HTTP API Gateway** → single catch-all route `/{proxy+}` to Lambda

**The Full CDK Code**

```csharp
// Base stack: Shared resources used by both LocalStack (local dev) and AWS (production).
// This stack only creates resources that LocalStack can emulate (e.g., DynamoDB).
public class SampleBaseStack : Stack
{
    public Table DynamoDbTable { get; }
    
    public SampleBaseStack(Construct scope)
        : this(scope, "SampleBaseStack")
    {
    }

    protected SampleBaseStack(Construct scope, string id)
        : base(scope, id)
    {
        DynamoDbTable = new Table(this,
            "Table",
            new TableProps
            {
                TableName = "sample-records",
                PartitionKey = new Attribute
                {
                    Name = "id",
                    Type = AttributeType.STRING
                },
                RemovalPolicy = RemovalPolicy.DESTROY // Demo only - use RETAIN in production
            });
    }
}

// Production stack: Inherits shared resources, adds AWS-specific infrastructure.
// VPC, Aurora, RDS Proxy, Lambda, and API Gateway only exist in production.
public class SampleStack : SampleBaseStack
{
    public CfnOutput PgConnectionString { get; }
    public CfnOutput ApiUrl { get; }
    
    public SampleStack(Construct scope)
        : base(scope, "SampleStack")
    {
        // --- VPC: Isolated Network ---
        // PRIVATE_ISOLATED = no internet gateway, no NAT gateway, no public IPs.
        // Lambda and Aurora can only communicate within VPC or through VPC endpoints.
        // DynamoDB access via VPC endpoint (no internet traversal).
        var privateSubnets = new SubnetSelection { SubnetType = SubnetType.PRIVATE_ISOLATED };

        var vpc = new Vpc(this,
            "ClusterVPC",
            new VpcProps
            {
                MaxAzs = 2, // High availability across 2 availability zones
                VpcName = "sample-cluster-vpc",
                SubnetConfiguration =
                [
                    new SubnetConfiguration
                    {
                        Name = "private",
                        SubnetType = SubnetType.PRIVATE_ISOLATED,
                        CidrMask = 24
                    }
                ],
                // VPC Gateway Endpoint for DynamoDB: Lambda can reach DynamoDB without internet access.
                // Traffic stays within AWS network, improves security and reduces latency.
                GatewayEndpoints = new Dictionary<string, IGatewayVpcEndpointOptions>
                {
                    {
                        "DynamoDbEndpoint",
                        new GatewayVpcEndpointOptions
                        {
                            Service = GatewayVpcEndpointAwsService.DYNAMODB,
                            Subnets = [privateSubnets]
                        }
                    }
                }
            });
        
        // --- Security Groups: Firewall Rules ---
        // Separate security groups follow least-privilege principle.
        // We'll configure rules later to allow Lambda → RDS Proxy communication.
        var dbSg = new SecurityGroup(this,
            "DatabaseSecurityGroup",
            new SecurityGroupProps
            {
                SecurityGroupName = "db-sg",
                Vpc = vpc
            });
        
        var lambdaSg = new SecurityGroup(this,
            "LambdaSecurityGroup",
            new SecurityGroupProps
            {
                SecurityGroupName = "lambda-sg",
                Vpc = vpc
            });

        // --- RDS Aurora PostgreSQL Cluster ---
        // Aurora Serverless v2: Scales capacity automatically based on load (0.5-1 ACU here).
        // Pay only for what you use, ideal for variable workloads.
        const string pgUser = "lambda";
        const string? pgDatabaseName = "sample";

        var pg = new DatabaseCluster(this,
            "DatabaseCluster",
            new DatabaseClusterProps
            {
                Engine = DatabaseClusterEngine.AuroraPostgres(new AuroraPostgresClusterEngineProps
                {
                    Version = AuroraPostgresEngineVersion.VER_17_5
                }),
                Writer = ClusterInstance.ServerlessV2("SampleDatabaseClusterWriter",
                    new ServerlessV2ClusterInstanceProps
                    {
                        PubliclyAccessible = false, // Must be false for PRIVATE_ISOLATED subnets
                        EnablePerformanceInsights = false
                    }),
                ServerlessV2MinCapacity = 0.5,
                ServerlessV2MaxCapacity = 1,
                Vpc = vpc,
                VpcSubnets = privateSubnets,
                SecurityGroups = [dbSg],
                Credentials = Credentials.FromGeneratedSecret(pgUser), // Password stored in Secrets Manager
                DefaultDatabaseName = pgDatabaseName,
                EnableDataApi = true,
                RemovalPolicy = RemovalPolicy.DESTROY, // Demo only - use RETAIN in production
                DeletionProtection = false
            });

        // --- RDS Proxy: Connection Pooling + IAM Auth ---
        // Why RDS Proxy? Lambda might create many concurrent connections. Without pooling,
        // Aurora will quickly exhaust max_connections. Proxy multiplexes Lambda connections
        // into a smaller pool, prevents "too many connections" errors.
        // IAM auth eliminates password management - Lambda uses its role to authenticate.
        var pgProxy = new DatabaseProxy(this,
            "DatabaseClusterProxy",
            new DatabaseProxyProps
            {
                DbProxyName = "sample-db-proxy",
                ProxyTarget = ProxyTarget.FromCluster(pg),
                Vpc = vpc,
                VpcSubnets = privateSubnets,
                SecurityGroups = [dbSg],
                RequireTLS = true,    // Enforce encrypted connections
                IamAuth = true,       // Enable IAM database authentication (no passwords)
                Secrets = [pg.Secret!] // Proxy uses this secret to connect to Aurora
            });
        
        // Connection string points to RDS Proxy endpoint, not Aurora directly.
        // Lambda will generate IAM auth tokens at runtime (see Api/Program.cs).
        PgConnectionString = new CfnOutput(this, "DatabaseConnectionString", new CfnOutputProps
        {
            Value = $"Host={pgProxy.Endpoint};Port=5432;Username={pgUser};Database={pgDatabaseName};Ssl Mode=Require;Trust Server Certificate=true;"
        });
        
        // Security group rule: Lambda can connect to RDS Proxy on port 5432
        pgProxy.Connections.AllowFrom(lambdaSg, Port.POSTGRES, "Lambda to Proxy");

        // --- IAM Role for Lambda ---
        // Least-privilege principle: Lambda needs CloudWatch Logs, VPC networking, 
        // RDS IAM auth, and DynamoDB access. Nothing more.
        var lambdaRole = new Role(this,
            "LambdaRole",
            new RoleProps
            {
                RoleName = "sample-lambda-execution-role",
                AssumedBy = new ServicePrincipal("lambda.amazonaws.com"),
                ManagedPolicies =
                [
                    ManagedPolicy.FromAwsManagedPolicyName("service-role/AWSLambdaBasicExecutionRole"),
                    ManagedPolicy.FromAwsManagedPolicyName("service-role/AWSLambdaVPCAccessExecutionRole")
                ]
            });
        
        // Grant fine-grained permissions: Lambda can generate RDS auth tokens and access DynamoDB table.
        // No wildcards, no overly broad policies.
        pgProxy.GrantConnect(lambdaRole, pgUser);
        DynamoDbTable.GrantReadWriteData(lambdaRole);
        
        // --- Lambda Function: Bundling Strategy ---
        // Build vs Runtime split: We use .NET 9 SDK to build (latest tooling, optimizations),
        // but need to deploy to .NET 8 runtime (current latest AWS Lambda support with LTS, .NET 10 will arrive January 2026).
        // The bundle-lambda.sh script runs inside a .NET 9 container to:
        // 1. Install Amazon.Lambda.Tools CLI
        // 2. Run `dotnet lambda package` with Lambda-specific settings
        // 3. Output function.zip ready for deployment
        var buildOption = new BundlingOptions
        {
            Image = Runtime.DOTNET_9.BundlingImage, // Build-time: .NET 9 SDK
            User = "root",
            OutputType = BundlingOutput.ARCHIVED,
            Command = ["/bin/bash", "bundle-lambda.sh"],
            BundlingFileAccess = BundlingFileAccess.VOLUME_COPY
        };
        
        // Find solution root (bundle-lambda.sh expects to run from solution directory)
        var solutionPath = Path.GetDirectoryName(Path.GetDirectoryName(new Projects.Api().ProjectPath)!)!;

        var lambda = new Function(this,
            "Lambda",
            new FunctionProps
            {
                FunctionName = "sample-lambda-function",
                Runtime = Runtime.DOTNET_8, // Runtime: .NET 8 (AWS Lambda support)
                Handler = "Api", // Assembly name (entry point)
                Code = Code.FromAsset(solutionPath,
                    new Amazon.CDK.AWS.S3.Assets.AssetOptions
                    {
                        Bundling = buildOption
                    }),
                Role = lambdaRole,
                Vpc = vpc,
                VpcSubnets = privateSubnets,
                SecurityGroups = [lambdaSg],
                MemorySize = 512,
                Timeout = Duration.Seconds(10),
                Environment = new Dictionary<string, string>
                {
                    // Lambda reads connection string from environment.
                    // Api/Program.cs uses this to configure Npgsql + IAM auth.
                    ["ConnectionStrings__Postgres"] = PgConnectionString.Value.ToString()!
                }
            });

        // --- API Gateway: Public HTTP Endpoint ---
        // HTTP API (v2) is simpler and cheaper than REST API (v1).
        // Catch-all route /{proxy+} forwards ALL requests to Lambda.
        // Lambda (ASP.NET Core) handles routing internally.
        var httpApi = new HttpApi(this,
            "Api",
            new HttpApiProps
            {
                ApiName = "api",
                Description = "HTTP API"
            });
        
        // Catch-all integration: API Gateway doesn't need to know about routes.
        // /{proxy+} matches /users, /products/123, etc.
        // Lambda's ASP.NET Core app handles routing via controllers/endpoints.
        httpApi.AddRoutes(new AddRoutesOptions
        {
            Path = "/{proxy+}",
            Methods = [Amazon.CDK.AWS.Apigatewayv2.HttpMethod.ANY],
            Integration = new HttpLambdaIntegration("LambdaIntegration", lambda)
        });
        
        ApiUrl = new CfnOutput(this,
            "ApiUrl",
            new CfnOutputProps
            {
                Value = httpApi.Url!,
            });
    }
}
```

**Bundling Script Details:** The `bundle-lambda.sh` script runs during `cdk deploy`. It installs `Amazon.Lambda.Tools`, runs `dotnet lambda package` with Lambda-specific optimizations, and outputs `function.zip` to `/asset-output/`. CDK uploads this zip to S3, then CloudFormation deploys it to Lambda.

**Inheritance in Stacks**: `SampleStack` inherits from `SampleBaseStack`. This allows us to share common resources (like the DynamoDB table) between local and production stacks, while adding production-specific resources (VPC, Aurora, Lambda, API Gateway) in the derived class. This reduces duplication and keeps shared definitions in one place. Alternatively, we can use concept of nested stacks. Nested stacks allow us to compose stacks within stacks, promoting reuse and modularity. However, for simplicity, inheritance suffices here. Nested stacks can be explored in more complex scenarios.

## API Project: Environment-Aware Configuration

With the infrastructure defined, we need to make the application code aware of which environment it's running in. The CDK stack creates the infrastructure, but the API itself needs to connect to the right services - LocalStack when running locally, real AWS when deployed.

The `Program.cs` adapts to its environment using a simple config flag. `UseLocalStack` determines whether to use emulated services or real AWS (while it is possible to use only LocalStack configuration which will automatically fallback to real AWS services, but I prefer to be explicit here). Also, the Postgres connection uses either a static password (local) or IAM auth tokens (production) via a periodic password provider.

```csharp
if (builder.Configuration.GetValue("LocalStack:UseLocalStack", false))
{
    // Local: Use LocalStack endpoints and static DB password
    builder.Services.AddLocalStack(builder.Configuration);
    builder.Services.AddAWSServiceLocalStack<IAmazonDynamoDB>();
    builder.Services.AddNpgsqlDataSource(builder.Configuration.GetConnectionString("Postgres")!);
}
else
{
    // AWS: Use real AWS and IAM auth tokens for DB
    builder.Services.AddAWSService<IAmazonDynamoDB>();
    builder.Services.AddNpgsqlDataSource(builder.Configuration.GetConnectionString("Postgres")!,
        b => {
            b.UsePeriodicPasswordProvider((cs, _) =>
                ValueTask.FromResult(RDSAuthTokenGenerator.GenerateAuthToken(cs.Host, cs.Port, cs.Username)),
            TimeSpan.FromMinutes(10),  // Refresh every 10 minutes
            TimeSpan.FromSeconds(5));  // Refresh after 5 seconds in case of failure
        });
}
```

**Why periodic password provider?**

RDS Proxy with IAM authentication doesn't use static passwords. Instead, the Lambda generates a temporary authentication token (valid for 15 minutes) signed with its IAM credentials. The `RDSAuthTokenGenerator.GenerateAuthToken` method creates this token on-demand using the Lambda's IAM role.

The periodic provider automatically handles token refresh:
- Generates a fresh token every 10 minutes (before the 15-minute expiry)
- Handles token refresh transparently - application code sees a normal connection, never knows tokens are being rotated
- Eliminates secrets management entirely (no passwords stored in environment variables, config files, or secrets managers)

Locally, the Postgres container uses a static password from the connection string (simpler for development). Same application queries, different credential strategy.

## Deploying to AWS

Before deploying for the first time, we need to bootstrap CDK in AWS account and region. Bootstrapping is a one-time setup that creates:
- An S3 bucket to store CloudFormation templates and Lambda deployment packages
- IAM roles that allow CloudFormation to create resources on our behalf
- An ECR repository for Docker images (if needed)

If [AWS environment is set up](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-quickstart.html) and [cdk is installed](https://docs.aws.amazon.com/cdk/v2/guide/getting-started.html), we can just run the bootstrap command:

```bash
cdk bootstrap
```

We only need to run this once per account/region combination. If we deploy to multiple regions (e.g., `us-east-1`, `eu-west-1`), bootstrap each one separately.

**What happens during bootstrap:**
1. CDK creates a CloudFormation stack named `CDKToolkit`
2. An S3 bucket (named like `cdk-hnb659fds-assets-ACCOUNT-REGION`) is created to store deployment artifacts
3. IAM roles are created with permissions to deploy infrastructure
4. The bootstrap stack is versioned, allowing CDK to upgrade its own infrastructure over time

**Important**

* CDK requires `cdk.json` file to be present in the project root. If it is missing, it can be created with `cdk init app --language csharp` command and then copied to the Aspire Host project root.
* `cdk.json` has to contain correct `app` command to run the Aspire Host project to get the CDK stack. Example content: `"app": "dotnet run -- --publisher manifest --output-path ./manifest.json"`

As long as bootstrap is done, we can deploy the stack. One command triggers publish mode:

```bash
cdk deploy --outputs-file ./cdk-outputs.json
```

When we run the deployment command, here's the step-by-step process:

1. **Aspire evaluates resources in publish mode** → `IsPublishMode = true`, so the publish branch runs
2. **CDK synthesizes CloudFormation template** → CDK compiles our C# infrastructure code into a CloudFormation template, saved in the `cdk.out/` directory along with any assets (like Lambda zip files)
3. **Lambda code is bundled** → A Docker container with the .NET SDK runs `bundle-lambda.sh`, which builds the Api project with Lambda-specific settings and packages it into a zip file
4. **CDK deploys stack** → CloudFormation creates all the resources: VPC (with isolated subnets, route tables, security groups), Aurora Serverless v2 cluster (with auto-scaling capacity), RDS Proxy (with IAM auth configuration), DynamoDB table, Lambda function (uploaded from the bundled zip), and HTTP API Gateway (with routing configuration)
5. **Stack outputs are displayed** → After deployment completes, CDK shows the outputs we defined: `ApiUrl` (the public endpoint to test) and `DatabaseConnectionString` (for diagnostics)
6. **Stack outputs saved to file** → The `--outputs-file` option saves the outputs to `cdk-outputs.json`

First deployment takes 5-10 minutes, mostly waiting for the Aurora cluster to provision. Subsequent updates are much faster (30-60 seconds) because CloudFormation only updates changed resources. If we only modify Lambda code, CloudFormation just updates the function, leaving the database and VPC untouched.

After deployment, we can test the API by sending HTTP requests to the `ApiUrl` endpoint using Postman, curl, or a web browser.

## Why This Pattern Works

* **Single Language, Full Stack**. Stay in C# for both application logic and infrastructure. We get IntelliSense, compile-time checks, and refactoring tools for infrastructure code - benefits we don't get with YAML or HCL.
* **Dev/Prod Parity for Services**. The same service `Program.cs` defines both environments. Only the *providers* change (LocalStack vs real AWS), not the topology. This reduces the probability of "works on my machine" issues.
* **Application-Centric Infrastructure**. Infrastructure lives next to code. Adding a new service means: add project reference + add infra fragment in the same file. No separate IaC repo to keep in sync.
* **Simplified CI/CD**. One command deploys everything. PRs can bundle code + infrastructure changes atomically. No risk of "infra merged, app not deployed" or vice versa.

## Current Limitations and Future Direction

**Why Not "Just Aspire Deploy" Today?**

Aspire (as of late 2025) doesn't have native AWS publishers that handle:
- Building and zipping .NET projects for Lambda runtime
- Modeling AWS services with first-class abstractions
- Modeling AWS-specific constructs, RDS Proxy, VPCs, VPC endpoints, IAM roles, etc.
- Advanced deployment strategies (blue/green, canary)

AWS CDK already solves these problems. So the division of labor is:
- Aspire Orchestrates: decides mode, wires dependencies, manages service references
- CDK Provisions: synthesizes CloudFormation, bundles assets, deploys to AWS

**What Could Improve**

If Aspire evolves to include first-class resource abstractions for common AWS services (Aurora, DynamoDB, API Gateway, Lambda, etc.), then this pattern could simplify: fewer explicit CDK constructs, more declarative Aspire resource definitions. But we don't need to wait for that future to ship productively today.

**Good news**: There's active work happening in this space. AWS and the .NET team are collaborating on [improving AWS integration with Aspire](https://github.com/aws/integrations-on-dotnet-aspire-for-aws/issues/50). The initiative aims to create first-class AWS resource support, native deployment primitives, and streamlined workflows - exactly the kind of improvements outlined above.
