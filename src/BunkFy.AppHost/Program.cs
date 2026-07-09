using Aspire.Hosting.ApplicationModel;

var builder = DistributedApplication.CreateBuilder(args);

var sqlServer = builder.AddSqlServer("sql")
    .AddDatabase("SqlServer");

var postgreSql = builder.AddPostgres("postgres")
    .AddDatabase("PostgreSql");

var nats = builder.AddNats("nats")
    .WithJetStream()
    .WithDataVolume(isReadOnly: false);

const string minioAccessKey = "minioadmin";
const string minioSecretKey = "minioadmin";
const string filesBucketName = "bunkfy-files";

var minio = builder.AddContainer("minio", "quay.io/minio/minio", "latest")
    .WithEnvironment("MINIO_ROOT_USER", minioAccessKey)
    .WithEnvironment("MINIO_ROOT_PASSWORD", minioSecretKey)
    .WithArgs("server", "/data", "--console-address", ":9001")
    .WithHttpEndpoint(targetPort: 9000, name: "api")
    .WithHttpEndpoint(targetPort: 9001, name: "console")
    .WithVolume("bunkfy-minio-data", "/data");

bool workerEnabled = bool.TryParse(
    builder.Configuration["AppHost:Worker:Enabled"],
    out bool configuredWorkerEnabled) && configuredWorkerEnabled;

var api = builder
    .AddProject("bunkfy-host-api", "../../apps/backend/src/BunkFy.Host.Api/BunkFy.Host.Api.csproj")
    .WithReference(sqlServer)
    .WithReference(postgreSql)
    .WithReference(nats)
    .WaitFor(nats)
    .WaitFor(minio)
    .WithEnvironment("ASPNETCORE_ENVIRONMENT", "Development")
    .WithEnvironment("FileManagement__Provider", "Minio")
    .WithEnvironment("FileManagement__Minio__Endpoint", "minio:9000")
    .WithEnvironment("FileManagement__Minio__AccessKey", minioAccessKey)
    .WithEnvironment("FileManagement__Minio__SecretKey", minioSecretKey)
    .WithEnvironment("FileManagement__Minio__BucketName", filesBucketName)
    .WithEnvironment("FileManagement__Minio__UseSsl", "false")
    .WithEnvironment("FileManagement__Minio__CreateBucketIfMissing", "true")
    .WithEnvironment("NatsJetStream__Enabled", workerEnabled ? "false" : "true")
    .WithHttpHealthCheck("/health");

bool adminApiEnabled = bool.TryParse(
    builder.Configuration["AppHost:AdminApi:Enabled"],
    out bool configuredAdminApiEnabled) && configuredAdminApiEnabled;

IResourceBuilder<ProjectResource>? adminApi = null;
if (adminApiEnabled)
{
    adminApi = builder
        .AddProject("bunkfy-host-admin-api", "../../apps/backend/src/BunkFy.Host.AdminApi/BunkFy.Host.AdminApi.csproj")
        .WithReference(sqlServer)
        .WithReference(postgreSql)
        .WithReference(nats)
        .WaitFor(nats)
        .WithEnvironment("ASPNETCORE_ENVIRONMENT", "Development")
        .WithEnvironment("NatsJetStream__Enabled", workerEnabled ? "false" : "true")
        .WithHttpHealthCheck("/health");
}

IResourceBuilder<ProjectResource>? worker = null;
if (workerEnabled)
{
    worker = builder
        .AddProject("bunkfy-host-worker", "../../apps/backend/src/BunkFy.Host.Worker/BunkFy.Host.Worker.csproj")
        .WithReference(sqlServer)
        .WithReference(postgreSql)
        .WithReference(nats)
        .WaitFor(nats)
        .WithEnvironment("DOTNET_ENVIRONMENT", "Development")
        .WithEnvironment("NatsJetStream__Enabled", "true")
        .WithEnvironment("NatsConsumers__Enabled", "false")
        .WithEnvironment("Tasks__Worker__Enabled", "true")
        .WithEnvironment("Worker__Modules__Auth", "true")
        .WithEnvironment("Worker__Modules__TaskRuntime", "true");
}

bool redisEnabled = bool.TryParse(
    builder.Configuration["AppHost:Redis:Enabled"],
    out bool configuredRedisEnabled) && configuredRedisEnabled;

if (redisEnabled)
{
    var redis = builder.AddRedis("redis");
    api.WithReference(redis)
        .WaitFor(redis)
        .WithEnvironment("Caching__Enabled", "true")
        .WithEnvironment("Caching__Provider", "Redis");

    if (adminApi is { } configuredAdminApi)
    {
        configuredAdminApi.WithReference(redis)
            .WaitFor(redis)
            .WithEnvironment("Caching__Enabled", "true")
            .WithEnvironment("Caching__Provider", "Redis");
    }

    if (worker is { } configuredWorker)
    {
        configuredWorker.WithReference(redis)
            .WaitFor(redis)
            .WithEnvironment("Caching__Enabled", "true")
            .WithEnvironment("Caching__Provider", "Redis");
    }
}

builder
    .AddViteApp("web", "../../apps/web")
    .WithPnpm()
    .WithReference(api)
    .WaitFor(api)
    .WithEnvironment("VITE_BUNKFY_API_BASE_URL", api.GetEndpoint("http"));

builder.Build().Run();
