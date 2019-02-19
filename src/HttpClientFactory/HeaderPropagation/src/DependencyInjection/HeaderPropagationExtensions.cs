using System;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Http;
using Microsoft.Extensions.Http.HeaderPropagation;
using Microsoft.Extensions.Options;

namespace Microsoft.Extensions.DependencyInjection
{
    public static class HeaderPropagationExtensions
    {
        public static IServiceCollection AddHeaderPropagation(this IServiceCollection services, Action<HeaderPropagationOptions> configure)
        {
            services.Configure(configure);
            services.TryAddEnumerable(ServiceDescriptor.Singleton<IHttpMessageHandlerBuilderFilter, HeaderPropagationMessageHandlerBuilderFilter>());
            return services;
        }

        public static IHttpClientBuilder AddHeaderPropagation(this IHttpClientBuilder builder, Action<HeaderPropagationOptions> configure)
        {
            builder.Services.Configure(configure);
            builder.AddHttpMessageHandler((sp) =>
            {
                var options = sp.GetRequiredService<IOptions<HeaderPropagationOptions>>();
                var contextAccessor = sp.GetRequiredService<IContextValuesAccessor>();

                return new HeaderPropagationMessageHandler(options.Value, contextAccessor);
            });

            return builder;
        }
    }
}
