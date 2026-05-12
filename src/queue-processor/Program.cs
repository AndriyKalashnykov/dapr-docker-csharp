using Dapr.Client;
using Microsoft.AspNetCore.HttpLogging;
using Microsoft.AspNetCore.Mvc;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

var builder = WebApplication.CreateBuilder(args);

const string ServiceName = "queueprocessor";

builder.Services.AddHttpLogging(logging =>
{
    logging.LoggingFields = HttpLoggingFields.All;
    logging.RequestHeaders.Add("Pubsubname");
    logging.RequestBodyLogLimit = 4096;
    logging.ResponseBodyLogLimit = 4096;
});

builder.Services.AddHealthChecks();

// OpenTelemetry: trace ASP.NET Core incoming requests and HttpClient outgoing
// calls (including the Dapr SDK's gRPC client). Exporter destination is read
// from OTEL_EXPORTER_OTLP_ENDPOINT (e.g. http://jaeger:4317); when unset, the
// exporter defaults to http://localhost:4317 and emits no traces if nothing
// listens there — safe for unit tests.
builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService(
        serviceName: ServiceName,
        serviceVersion: typeof(Program).Assembly.GetName().Version?.ToString() ?? "0.0.0"))
    .WithTracing(t => t
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddOtlpExporter());

builder.Services.AddSingleton(new DaprClientBuilder().Build());

var app = builder.Build();

app.UseCloudEvents();

app.MapSubscribeHandler();

app.MapHealthChecks("/healthz");

app.MapGet("/", async (DaprClient dapr) => await dapr.GetStateAsync<int>("statestore", "counter"));

app.MapPost("/counter", async ([FromBody] int counter, ILogger<Program> logger, DaprClient dapr) =>
{
    var newCounter = counter * counter;
    logger.LogInformation("Updating counter: {newCounter}", newCounter);
    // Save state out to a data store.  We don't care which one!
    await dapr.SaveStateAsync("statestore", "counter", newCounter);
    return Results.Accepted("/", newCounter);
}).WithTopic("pubsub", "counter", false);

app.Run();

// Enable WebApplicationFactory<Program> in integration tests
public partial class Program;
