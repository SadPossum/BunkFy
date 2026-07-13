using BunkFy.AppHost.Composition;

IDistributedApplicationBuilder builder = DistributedApplication.CreateBuilder(args);
BunkFyBackendResources backend = builder.AddBunkFyBackend(new(
    Api: "../../apps/backend/src/BunkFy.Host.Api/BunkFy.Host.Api.csproj",
    AdminApi: "../../apps/backend/src/BunkFy.Host.AdminApi/BunkFy.Host.AdminApi.csproj",
    Worker: "../../apps/backend/src/BunkFy.Host.Worker/BunkFy.Host.Worker.csproj"));

var web = builder
    .AddViteApp("web", "../../apps/web")
    .WithPnpm()
    .WithReference(backend.Api)
    .WaitFor(backend.Api)
    .WithEnvironment("NODE_ENV", "development")
    .WithEnvironment("VITE_BUNKFY_API_BASE_URL", backend.Api.GetEndpoint("http"));

backend.Api.WithEnvironment("Http__Cors__Enabled", "true")
    .WithEnvironment("Http__Cors__AllowCredentials", "true")
    .WithEnvironment("Http__Cors__AllowedOrigins__0", web.GetEndpoint("http"));

builder.Build().Run();
