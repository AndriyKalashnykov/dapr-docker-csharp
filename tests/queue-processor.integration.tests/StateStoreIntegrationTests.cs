namespace QueueProcessor.IntegrationTests;

[ClassDataSource<DaprStateStoreFixture>(Shared = SharedType.PerClass)]
[Category("Integration")]
public sealed class StateStoreIntegrationTests(DaprStateStoreFixture fixture)
{
    private const string Store = "statestore";

    [Test]
    public async Task SaveState_AndGetState_Roundtrips()
    {
        var key = $"counter-{Guid.NewGuid():N}";
        await fixture.Client.SaveStateAsync(Store, key, 42);

        var value = await fixture.Client.GetStateAsync<int>(Store, key);

        await Assert.That(value).IsEqualTo(42);
    }

    [Test]
    public async Task GetState_ReturnsDefault_WhenKeyMissing()
    {
        var key = $"missing-{Guid.NewGuid():N}";

        var value = await fixture.Client.GetStateAsync<int>(Store, key);

        await Assert.That(value).IsEqualTo(0);
    }

    [Test]
    public async Task DeleteState_RemovesKey()
    {
        var key = $"counter-{Guid.NewGuid():N}";
        await fixture.Client.SaveStateAsync(Store, key, 99);

        await fixture.Client.DeleteStateAsync(Store, key);
        var value = await fixture.Client.GetStateAsync<int>(Store, key);

        await Assert.That(value).IsEqualTo(0);
    }

    [Test]
    public async Task SaveState_OverwritesExistingValue()
    {
        var key = $"counter-{Guid.NewGuid():N}";
        await fixture.Client.SaveStateAsync(Store, key, 1);
        await fixture.Client.SaveStateAsync(Store, key, 25);

        var value = await fixture.Client.GetStateAsync<int>(Store, key);

        await Assert.That(value).IsEqualTo(25);
    }
}
