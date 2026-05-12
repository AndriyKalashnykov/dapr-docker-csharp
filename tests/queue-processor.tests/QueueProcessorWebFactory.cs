using Dapr.Client;
using FakeItEasy;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;

namespace QueueProcessor.Tests;

public class QueueProcessorWebFactory : WebApplicationFactory<Program>
{
    public DaprClient MockDaprClient { get; } = A.Fake<DaprClient>();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.ConfigureServices(services =>
        {
            var descriptor = services.SingleOrDefault(d => d.ServiceType == typeof(DaprClient));
            if (descriptor is not null)
                services.Remove(descriptor);

            services.AddSingleton(MockDaprClient);
        });
    }
}
