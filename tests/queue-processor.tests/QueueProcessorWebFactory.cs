using Dapr.Client;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using NSubstitute;

namespace QueueProcessor.Tests;

public class QueueProcessorWebFactory : WebApplicationFactory<Program>
{
    public DaprClient MockDaprClient { get; } = Substitute.For<DaprClient>();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.ConfigureServices(services =>
        {
            // Remove the real DaprClient registration
            var descriptor = services.SingleOrDefault(d => d.ServiceType == typeof(DaprClient));
            if (descriptor is not null)
                services.Remove(descriptor);

            // Register mock
            services.AddSingleton(MockDaprClient);
        });
    }
}
