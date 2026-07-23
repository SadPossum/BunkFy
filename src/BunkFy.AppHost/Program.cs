using BunkFy.AppHost.Composition;

const int WebPort = 5173;
const int WebTargetPort = 5174;
const string WebLocalhostOrigin = "http://localhost:5173";
const string WebLoopbackOrigin = "http://127.0.0.1:5173";

IDistributedApplicationBuilder builder = DistributedApplication.CreateBuilder(args);
BunkFyBackendResources backend = builder.AddBunkFyBackend(new(
    Api: "../../apps/backend/src/BunkFy.Host.Api/BunkFy.Host.Api.csproj",
    AdminApi: "../../apps/backend/src/BunkFy.Host.AdminApi/BunkFy.Host.AdminApi.csproj",
    Worker: "../../apps/backend/src/BunkFy.Host.Worker/BunkFy.Host.Worker.csproj",
    Migrations: "../../apps/backend/src/BunkFy.Host.Migrations/BunkFy.Host.Migrations.csproj"));

var web = builder
    .AddViteApp("web", "../../apps/web")
    .WithPnpm()
    .WithHttpEndpoint(targetPort: WebTargetPort, port: WebPort, name: "http")
    .WithReference(backend.Api)
    .WithEnvironment("NODE_ENV", "development")
    .WithEnvironment("VITE_BUNKFY_API_BASE_URL", backend.Api.GetEndpoint("http"));

backend.Api.WithEnvironment("Http__Cors__Enabled", "true")
    .WithEnvironment("Http__Cors__AllowCredentials", "true")
    .WithEnvironment(
        "Http__Cors__AllowedOrigins__0",
        WebLocalhostOrigin)
    .WithEnvironment(
        "Http__Cors__AllowedOrigins__1",
        WebLoopbackOrigin);

builder.Build().Run();
