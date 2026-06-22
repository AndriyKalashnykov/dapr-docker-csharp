using System.Net;
using System.Net.Http.Json;
using Dapr.Client;
using FakeItEasy;

namespace QueueProcessor.Tests;

[Category("Unit")]
public class EndpointTests
{
    [Test]
    public async Task GetRoot_ReturnsCounterState()
    {
        await using var factory = new QueueProcessorWebFactory();
        A.CallTo(() => factory.MockDaprClient
                .GetStateAsync<int>("statestore", "counter", A<ConsistencyMode?>.Ignored, A<IReadOnlyDictionary<string, string>?>.Ignored, A<CancellationToken>.Ignored))
            .Returns(42);

        using var client = factory.CreateClient();

        var response = await client.GetAsync("/");

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.OK);
        var value = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(value).IsEqualTo(42);
    }

    [Test]
    public async Task GetRoot_WhenNoState_ReturnsZero()
    {
        await using var factory = new QueueProcessorWebFactory();
        A.CallTo(() => factory.MockDaprClient
                .GetStateAsync<int>("statestore", "counter", A<ConsistencyMode?>.Ignored, A<IReadOnlyDictionary<string, string>?>.Ignored, A<CancellationToken>.Ignored))
            .Returns(0);

        using var client = factory.CreateClient();

        var response = await client.GetAsync("/");

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.OK);
        var value = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(value).IsEqualTo(0);
    }

    [Test]
    public async Task GetRoot_WhenStateStoreThrows_Returns500()
    {
        await using var factory = new QueueProcessorWebFactory();
        A.CallTo(() => factory.MockDaprClient
                .GetStateAsync<int>("statestore", "counter", A<ConsistencyMode?>.Ignored, A<IReadOnlyDictionary<string, string>?>.Ignored, A<CancellationToken>.Ignored))
            .Throws(new Exception("redis down"));

        using var client = factory.CreateClient();

        var response = await client.GetAsync("/");

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.InternalServerError);
    }

    [Test]
    public async Task PostCounter_SquaresValue_AndSavesState()
    {
        await using var factory = new QueueProcessorWebFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/counter", 5);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.Accepted);
        var result = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(result).IsEqualTo(25);

        A.CallTo(() => factory.MockDaprClient
                .SaveStateAsync("statestore", "counter", 25, A<StateOptions?>.Ignored, A<IReadOnlyDictionary<string, string>?>.Ignored, A<CancellationToken>.Ignored))
            .MustHaveHappenedOnceExactly();
    }

    [Test]
    public async Task PostCounter_WithZero_SavesZero()
    {
        await using var factory = new QueueProcessorWebFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/counter", 0);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.Accepted);
        var result = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(result).IsEqualTo(0);

        A.CallTo(() => factory.MockDaprClient
                .SaveStateAsync("statestore", "counter", 0, A<StateOptions?>.Ignored, A<IReadOnlyDictionary<string, string>?>.Ignored, A<CancellationToken>.Ignored))
            .MustHaveHappenedOnceExactly();
    }

    [Test]
    public async Task GetHealthz_ReturnsHealthy()
    {
        await using var factory = new QueueProcessorWebFactory();
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/healthz");

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.OK);
        var body = await response.Content.ReadAsStringAsync();
        await Assert.That(body).IsEqualTo("Healthy");
    }

    [Test]
    public async Task PostCounter_WithNegative_SquaresToPositive()
    {
        await using var factory = new QueueProcessorWebFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/counter", -3);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.Accepted);
        var result = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(result).IsEqualTo(9);

        A.CallTo(() => factory.MockDaprClient
                .SaveStateAsync("statestore", "counter", 9, A<StateOptions?>.Ignored, A<IReadOnlyDictionary<string, string>?>.Ignored, A<CancellationToken>.Ignored))
            .MustHaveHappenedOnceExactly();
    }

    [Test]
    public async Task PostCounter_WithNonIntegerBody_Returns400()
    {
        await using var factory = new QueueProcessorWebFactory();
        using var client = factory.CreateClient();

        // Malformed body for `[FromBody] int` — a JSON string, not an int.
        // Minimal-API model binding rejects it before the handler runs.
        var content = new StringContent("\"abc\"", System.Text.Encoding.UTF8, "application/json");
        var response = await client.PostAsync("/counter", content);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.BadRequest);

        A.CallTo(() => factory.MockDaprClient
                .SaveStateAsync("statestore", "counter", A<int>.Ignored, A<StateOptions?>.Ignored, A<IReadOnlyDictionary<string, string>?>.Ignored, A<CancellationToken>.Ignored))
            .MustNotHaveHappened();
    }

    [Test]
    public async Task PostCounter_WithMaxValue_OverflowsUnchecked()
    {
        await using var factory = new QueueProcessorWebFactory();
        using var client = factory.CreateClient();

        // Documents the UNCHECKED-arithmetic contract: counter * counter wraps.
        var expected = unchecked(int.MaxValue * int.MaxValue);

        var response = await client.PostAsJsonAsync("/counter", int.MaxValue);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.Accepted);
        var result = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(result).IsEqualTo(expected);

        A.CallTo(() => factory.MockDaprClient
                .SaveStateAsync("statestore", "counter", expected, A<StateOptions?>.Ignored, A<IReadOnlyDictionary<string, string>?>.Ignored, A<CancellationToken>.Ignored))
            .MustHaveHappenedOnceExactly();
    }

    [Test]
    public async Task PostCounter_WhenStateStoreThrows_Returns500()
    {
        await using var factory = new QueueProcessorWebFactory();
        A.CallTo(() => factory.MockDaprClient
                .SaveStateAsync("statestore", "counter", A<int>.Ignored, A<StateOptions?>.Ignored, A<IReadOnlyDictionary<string, string>?>.Ignored, A<CancellationToken>.Ignored))
            .Throws(new Exception("redis down"));

        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/counter", 5);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.InternalServerError);
    }
}
