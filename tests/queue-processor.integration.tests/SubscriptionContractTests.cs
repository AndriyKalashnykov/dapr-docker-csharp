using System.Net;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;

namespace QueueProcessor.IntegrationTests;

// /dapr/subscribe is the wire contract daprd polls at startup to discover which
// (pubsub, topic) → route bindings the app accepts. A regression in the
// `.WithTopic(...)` chain on Program.cs's POST /counter endpoint (topic rename,
// route mapping change, accidental removal) silently breaks every published
// message in production — the app pod stays Ready, daprd logs nothing
// actionable, every event is dropped at the subscription layer.
//
// This test asserts the contract Dapr.AspNetCore 1.17 serializes for the
// app's single subscription:
//   [{"topic":"counter","pubsubName":"pubsub","route":"counter"}]
//
// JsonNamingPolicy.CamelCase + DefaultIgnoreCondition.WhenWritingNull
// (verified against the Dapr.AspNetCore source) — null-valued routes /
// metadata / deadLetterTopic / bulkSubscribe properties are omitted.
// Route is emitted without a leading slash (the SDK joins RoutePattern's
// PathSegments with "/", which produces "counter" for a single-segment
// pattern; daprd prepends the slash when POSTing to the app).
//
// No daprd container is needed; the test runs entirely in-process against
// MapSubscribeHandler's auto-registered endpoint.
[Category("Integration")]
public sealed class SubscriptionContractTests
{
    [Test]
    public async Task DaprSubscribe_AdvertisesCounterTopicOnPubSubRoutedToSlashCounter()
    {
        await using var factory = new WebApplicationFactory<Program>();
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/dapr/subscribe");

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.OK);

        await using var body = await response.Content.ReadAsStreamAsync();
        using var doc = await JsonDocument.ParseAsync(body);

        await Assert.That(doc.RootElement.ValueKind).IsEqualTo(JsonValueKind.Array);
        await Assert.That(doc.RootElement.GetArrayLength()).IsEqualTo(1);

        var sub = doc.RootElement[0];
        await Assert.That(sub.GetProperty("pubsubName").GetString()).IsEqualTo("pubsub");
        await Assert.That(sub.GetProperty("topic").GetString()).IsEqualTo("counter");
        await Assert.That(sub.GetProperty("route").GetString()).IsEqualTo("counter");

        // enableRawPayload=false on .WithTopic — metadata must be absent.
        await Assert.That(sub.TryGetProperty("metadata", out _)).IsFalse();
    }
}
