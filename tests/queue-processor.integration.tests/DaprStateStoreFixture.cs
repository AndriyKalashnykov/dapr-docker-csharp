using System.Text;
using Dapr.Client;
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Containers;
using DotNet.Testcontainers.Networks;
using Testcontainers.Redis;
using TUnit.Core.Interfaces;

namespace QueueProcessor.IntegrationTests;

public sealed class DaprStateStoreFixture : IAsyncInitializer, IAsyncDisposable
{
    // renovate: datasource=docker depName=daprio/daprd
    private const string DaprdImage = "daprio/daprd:1.17.6";
    // renovate: datasource=docker depName=redis
    private const string RedisImage = "redis:8-alpine";

    // Sidecar ports — env-fallback per rules/common/configuration.md.
    // Defaults mirror .env.example so the fixture works without a `.env` file.
    // ushort because Testcontainers' WithPortBinding / WithWaitStrategy.ForPort
    // both take ushort.
    private static readonly ushort DaprHttpPort =
        ushort.Parse(Environment.GetEnvironmentVariable("DAPR_HTTP_PORT") ?? "3500");
    private static readonly ushort DaprGrpcPort =
        ushort.Parse(Environment.GetEnvironmentVariable("DAPR_GRPC_PORT") ?? "50001");

    private const string StateStoreComponent = """
        apiVersion: dapr.io/v1alpha1
        kind: Component
        metadata:
          name: statestore
        spec:
          type: state.redis
          version: v1
          metadata:
          - name: redisHost
            value: redis:6379
          - name: redisPassword
            value: ""
          - name: keyPrefix
            value: none
        """;

    private INetwork _network = null!;
    private RedisContainer _redis = null!;
    private IContainer _daprd = null!;

    public DaprClient Client { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        _network = new NetworkBuilder().Build();
        await _network.CreateAsync();

        _redis = new RedisBuilder(RedisImage)
            .WithNetwork(_network)
            .WithNetworkAliases("redis")
            .Build();
        await _redis.StartAsync();

        _daprd = new ContainerBuilder(DaprdImage)
            .WithNetwork(_network)
            .WithResourceMapping(
                Encoding.UTF8.GetBytes(StateStoreComponent),
                "/components/statestore.yaml")
            .WithCommand(
                "./daprd",
                "--app-id", "queue-processor-it",
                "--app-protocol", "http",
                "--dapr-http-port", DaprHttpPort.ToString(),
                "--dapr-grpc-port", DaprGrpcPort.ToString(),
                "--resources-path", "/components",
                "--log-level", "warn")
            .WithPortBinding(DaprHttpPort, true)
            .WithPortBinding(DaprGrpcPort, true)
            .WithWaitStrategy(
                Wait.ForUnixContainer()
                    .UntilHttpRequestIsSucceeded(req => req
                        .ForPort(DaprHttpPort)
                        .ForPath("/v1.0/healthz")
                        .ForStatusCode(System.Net.HttpStatusCode.NoContent)))
            .Build();
        await _daprd.StartAsync();

        var httpEndpoint = $"http://localhost:{_daprd.GetMappedPublicPort(DaprHttpPort)}";
        var grpcEndpoint = $"http://localhost:{_daprd.GetMappedPublicPort(DaprGrpcPort)}";
        Client = new DaprClientBuilder()
            .UseHttpEndpoint(httpEndpoint)
            .UseGrpcEndpoint(grpcEndpoint)
            .Build();
    }

    public async ValueTask DisposeAsync()
    {
        Client?.Dispose();
        if (_daprd is not null)
            await _daprd.DisposeAsync();
        if (_redis is not null)
            await _redis.DisposeAsync();
        if (_network is not null)
            await _network.DisposeAsync();
    }
}
