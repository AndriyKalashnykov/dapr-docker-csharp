using System.Net;
using System.Net.Http.Json;
using Dapr.Client;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;

namespace QueueProcessor.IntegrationTests;

// Endpoints exercised through Program.cs's real route handlers against a real
// daprd sidecar + real Redis. Unit tests cover the same handlers with a mocked
// DaprClient; this layer catches DI wiring, state-store name drift, and
// serialization regressions that only surface against real Dapr.
//
// The app's `/counter` endpoint persists to a fixed key ("counter") so tests
// within this class must serialize (NotInParallel) to avoid cross-test races.
// Other test classes are unaffected: StateStoreIntegrationTests uses
// Guid-suffixed keys.
[ClassDataSource<DaprStateStoreFixture>(Shared = SharedType.PerClass)]
[Category("Integration")]
[NotInParallel]
public sealed class EndpointsIntegrationTests(DaprStateStoreFixture fixture)
{
    private const string Store = "statestore";
    private const string CounterKey = "counter";

    private WebApplicationFactory<Program> CreateFactory() =>
        new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            builder.ConfigureServices(services =>
            {
                var descriptor = services.SingleOrDefault(d => d.ServiceType == typeof(DaprClient));
                if (descriptor is not null)
                    services.Remove(descriptor);
                services.AddSingleton(fixture.Client);
            });
        });

    [Test]
    public async Task PostCounter_PersistsState_AndGetReturnsSquaredValue()
    {
        await fixture.Client.DeleteStateAsync(Store, CounterKey);

        await using var factory = CreateFactory();
        using var client = factory.CreateClient();

        var postResponse = await client.PostAsJsonAsync("/counter", 7);
        await Assert.That(postResponse.StatusCode).IsEqualTo(HttpStatusCode.Accepted);
        await Assert.That(postResponse.Headers.Location?.OriginalString).IsEqualTo("/");
        var postValue = await postResponse.Content.ReadFromJsonAsync<int>();
        await Assert.That(postValue).IsEqualTo(49);

        var getResponse = await client.GetAsync("/");
        await Assert.That(getResponse.StatusCode).IsEqualTo(HttpStatusCode.OK);
        var getValue = await getResponse.Content.ReadFromJsonAsync<int>();
        await Assert.That(getValue).IsEqualTo(49);
    }

    [Test]
    public async Task GetRoot_ReturnsZero_WhenStateIsAbsent()
    {
        await fixture.Client.DeleteStateAsync(Store, CounterKey);

        await using var factory = CreateFactory();
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/");

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.OK);
        var value = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(value).IsEqualTo(0);
    }

    [Test]
    public async Task PostCounter_OverwritesPriorValue()
    {
        await fixture.Client.SaveStateAsync(Store, CounterKey, 100);

        await using var factory = CreateFactory();
        using var client = factory.CreateClient();

        var postResponse = await client.PostAsJsonAsync("/counter", 4);
        await Assert.That(postResponse.StatusCode).IsEqualTo(HttpStatusCode.Accepted);

        var stored = await fixture.Client.GetStateAsync<int>(Store, CounterKey);
        await Assert.That(stored).IsEqualTo(16);
    }

    [Test]
    public async Task PostCounter_WithMalformedBody_Returns400_AndLeavesStateUnchanged()
    {
        await fixture.Client.SaveStateAsync(Store, CounterKey, 123);

        await using var factory = CreateFactory();
        using var client = factory.CreateClient();

        // Malformed body for `[FromBody] int` — a JSON string, not an int.
        // Direct HTTP POST (no pub/sub) makes this deterministic vs. an e2e
        // redelivery-prone negative payload check, against real Dapr.
        var content = new StringContent("\"abc\"", System.Text.Encoding.UTF8, "application/json");
        var response = await client.PostAsync("/counter", content);
        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.BadRequest);

        // Bad input must not have corrupted the persisted state.
        var stored = await fixture.Client.GetStateAsync<int>(Store, CounterKey);
        await Assert.That(stored).IsEqualTo(123);
    }

    [Test]
    public async Task CounterTopic_DeliveredAsCloudEvent_IsSquaredAndPersisted()
    {
        // The tests above POST a raw int, which bypasses app.UseCloudEvents().
        // daprd, however, delivers a published `counter` message to the
        // [Topic("pubsub","counter")] handler as a CloudEvent envelope
        // (application/cloudevents+json). This exercises that delivery-side
        // contract end to end: UseCloudEvents unwrapping + the topic route +
        // a real daprd state save. (The daprd->app HTTP transport itself is
        // covered by the e2e suite; SubscriptionContractTests covers the
        // /dapr/subscribe wire that tells daprd to route counter -> /counter.)
        await fixture.Client.DeleteStateAsync(Store, CounterKey);

        await using var factory = CreateFactory();
        using var client = factory.CreateClient();

        // Shape mirrors what daprd POSTs for a published `counter` message.
        var cloudEvent = new
        {
            specversion = "1.0",
            type = "com.dapr.event.sent",
            source = "queue-processor-it",
            id = Guid.NewGuid().ToString(),
            datacontenttype = "application/json",
            pubsubname = "pubsub",
            topic = "counter",
            data = 9,
        };
        var content = new StringContent(
            System.Text.Json.JsonSerializer.Serialize(cloudEvent),
            System.Text.Encoding.UTF8,
            "application/cloudevents+json");
        var response = await client.PostAsync("/counter", content);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.Accepted);

        // 9 squared, unwrapped from the CloudEvent `data` field and persisted.
        var stored = await fixture.Client.GetStateAsync<int>(Store, CounterKey);
        await Assert.That(stored).IsEqualTo(81);
    }
}
