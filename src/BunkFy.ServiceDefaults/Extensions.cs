namespace BunkFy.ServiceDefaults;

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

public static class Extensions
{
    public static IHostApplicationBuilder AddBunkFyServiceDefaults(this IHostApplicationBuilder builder)
    {
        builder.Services.AddHealthChecks();
        return builder;
    }

    public static WebApplication MapBunkFyDefaultEndpoints(this WebApplication app)
    {
        app.MapHealthChecks("/health");
        app.MapGet("/alive", () => Results.Ok(new
        {
            Status = "Alive"
        }));

        return app;
    }
}

