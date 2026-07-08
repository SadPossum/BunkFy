var builder = DistributedApplication.CreateBuilder(args);

var api = builder
    .AddProject("api", "../../apps/backend/src/BunkFy.Host.Api/BunkFy.Host.Api.csproj")
    .WithHttpHealthCheck("/health");

builder
    .AddViteApp("web", "../../apps/web")
    .WithPnpm()
    .WithReference(api)
    .WaitFor(api)
    .WithEnvironment("VITE_BUNKFY_API_BASE_URL", api.GetEndpoint("http"));

builder.Build().Run();
