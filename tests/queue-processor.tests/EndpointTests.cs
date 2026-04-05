using System.Net;
using System.Net.Http.Json;
using Dapr.Client;
using NSubstitute;

namespace QueueProcessor.Tests;

public class EndpointTests
{
    [Test]
    public async Task GetRoot_ReturnsCounterState()
    {
        await using var factory = new QueueProcessorWebFactory();
        factory.MockDaprClient
            .GetStateAsync<int>("statestore", "counter", cancellationToken: Arg.Any<CancellationToken>())
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
        factory.MockDaprClient
            .GetStateAsync<int>("statestore", "counter", cancellationToken: Arg.Any<CancellationToken>())
            .Returns(0);

        using var client = factory.CreateClient();

        var response = await client.GetAsync("/");

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.OK);
        var value = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(value).IsEqualTo(0);
    }

    [Test]
    public async Task PostCounter_SquaresValue_AndSavesState()
    {
        await using var factory = new QueueProcessorWebFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/counter", 5);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.Accepted);
        var result = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(result).IsEqualTo(25); // 5 * 5

        await factory.MockDaprClient.Received(1)
            .SaveStateAsync("statestore", "counter", 25, cancellationToken: Arg.Any<CancellationToken>());
    }

    [Test]
    public async Task PostCounter_WithZero_SavesZero()
    {
        await using var factory = new QueueProcessorWebFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/counter", 0);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.Accepted);
        var result = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(result).IsEqualTo(0); // 0 * 0

        await factory.MockDaprClient.Received(1)
            .SaveStateAsync("statestore", "counter", 0, cancellationToken: Arg.Any<CancellationToken>());
    }

    [Test]
    public async Task PostCounter_WithNegative_SquaresToPositive()
    {
        await using var factory = new QueueProcessorWebFactory();
        using var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/counter", -3);

        await Assert.That(response.StatusCode).IsEqualTo(HttpStatusCode.Accepted);
        var result = await response.Content.ReadFromJsonAsync<int>();
        await Assert.That(result).IsEqualTo(9); // -3 * -3

        await factory.MockDaprClient.Received(1)
            .SaveStateAsync("statestore", "counter", 9, cancellationToken: Arg.Any<CancellationToken>());
    }
}
