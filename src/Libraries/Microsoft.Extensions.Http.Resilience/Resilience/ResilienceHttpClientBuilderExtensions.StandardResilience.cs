// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Net.Http;
using System.Net.Http.Json;
using System.Threading;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using Microsoft.Shared.Diagnostics;
using WantsACracker;
using WantsACracker.Extensions.Http.Resilience;
using WantsACracker.Extensions.Http.Resilience.Internal;
using WantsACracker.Extensions.Http.Resilience.Internal.Validators;
using WantsACracker.Registry;

namespace Microsoft.Extensions.DependencyInjection;

public static partial class ResilienceHttpClientBuilderExtensions
{
    private const string StandardIdentifier = "standard";

    /// <summary>
    /// Adds a standard resilience handler that uses multiple resilience strategies with default options to send the requests and handle any transient errors.
    /// </summary>
    /// <param name="builder">The builder instance.</param>
    /// <param name="section">The section that the options will bind against.</param>
    /// <returns>The value of <paramref name="builder"/>.</returns>
    /// <remarks>
    /// The resilience pipeline combines multiple strategies that are configured based on HTTP-specific <see cref="HttpStandardResilienceOptions"/> options with recommended defaults.
    /// See <see cref="HttpStandardResilienceOptions"/> for more details about the individual resilience strategies configured by this method.
    /// </remarks>
    public static IHttpStandardResiliencePipelineBuilder AddStandardResilienceHandler(this IHttpClientBuilder builder, IConfigurationSection section)
    {
        _ = Throw.IfNull(builder);
        _ = Throw.IfNull(section);

        return builder.AddStandardResilienceHandler().Configure(section);
    }

    /// <summary>
    /// Adds a standard resilience handler that uses multiple resilience strategies with default options to send the requests and handle any transient errors.
    /// </summary>
    /// <param name="builder">The builder instance.</param>
    /// <param name="configure">The callback that configures the options.</param>
    /// <returns>The value of <paramref name="builder"/>.</returns>
    /// <remarks>
    /// The resilience pipeline combines multiple strategies that are configured based on HTTP-specific <see cref="HttpStandardResilienceOptions"/> options with recommended defaults.
    /// See <see cref="HttpStandardResilienceOptions"/> for more details about the individual resilience strategies configured by this method.
    /// </remarks>
    public static IHttpStandardResiliencePipelineBuilder AddStandardResilienceHandler(this IHttpClientBuilder builder, Action<HttpStandardResilienceOptions> configure)
    {
        _ = Throw.IfNull(builder);
        _ = Throw.IfNull(configure);

        return builder.AddStandardResilienceHandler().Configure(configure);
    }

    /// <summary>
    /// Adds a standard resilience handler that uses multiple resilience strategies with default options to send the requests and handle any transient errors.
    /// </summary>
    /// <param name="builder">The builder instance.</param>
    /// <returns>The value of <paramref name="builder"/>.</returns>
    /// <remarks>
    /// The resilience pipeline combines multiple strategies that are configured based on HTTP-specific <see cref="HttpStandardResilienceOptions"/> options with recommended defaults.
    /// See <see cref="HttpStandardResilienceOptions"/> for more details about the individual resilience strategies configured by this method.
    /// </remarks>
    public static IHttpStandardResiliencePipelineBuilder AddStandardResilienceHandler(this IHttpClientBuilder builder)
    {
        _ = Throw.IfNull(builder);

        var optionsName = PipelineNameHelper.GetName(builder.Name, StandardIdentifier);

        _ = builder.Services.AddOptionsWithValidateOnStart<HttpStandardResilienceOptions, HttpStandardResilienceOptionsCustomValidator>(optionsName);
        _ = builder.Services.AddOptionsWithValidateOnStart<HttpStandardResilienceOptions, HttpStandardResilienceOptionsValidator>(optionsName);

        // Two standard pipelines: the ordinary one with the retry strategy and
        // an identical pipeline without it. The handler below picks the pipeline
        // per request, so that requests whose content cannot be safely replayed
        // are never re-sent (mirroring the WantsACracker StandardResilienceHandler).
        _ = builder.AddHttpResiliencePipeline(StandardIdentifier, (pipelineBuilder, context) =>
            ConfigureStandardPipeline(pipelineBuilder, context, optionsName, includeRetry: true));

        _ = builder.AddHttpResiliencePipeline(StandardIdentifier + "-no-retry", (pipelineBuilder, context) =>
            ConfigureStandardPipeline(pipelineBuilder, context, optionsName, includeRetry: false));

        _ = builder.AddHttpMessageHandler(serviceProvider =>
            new ResilienceHandler(CreateStandardPipelineSelector(
                serviceProvider,
                PipelineNameHelper.GetName(builder.Name, StandardIdentifier),
                PipelineNameHelper.GetName(builder.Name, StandardIdentifier + "-no-retry"))));

        // Disable the HttpClient timeout to allow the timeout strategies to control the timeout.
        _ = builder.ConfigureHttpClient(client => client.Timeout = Timeout.InfiniteTimeSpan);

        return new HttpStandardResiliencePipelineBuilder(optionsName, builder.Services);
    }

    private static void ConfigureStandardPipeline(
        ResiliencePipelineBuilder<HttpResponseMessage> pipelineBuilder,
        ResilienceHandlerContext context,
        string optionsName,
        bool includeRetry)
    {
        context.EnableReloads<HttpStandardResilienceOptions>(optionsName);

        var monitor = context.ServiceProvider.GetRequiredService<IOptionsMonitor<HttpStandardResilienceOptions>>();
        var options = monitor.Get(optionsName);

        _ = pipelineBuilder
            .AddRateLimiter(options.RateLimiter)
            .AddTimeout(options.TotalRequestTimeout);

        if (includeRetry)
        {
            _ = pipelineBuilder.AddRetry(options.Retry);
        }

        _ = pipelineBuilder
            .AddCircuitBreaker(options.CircuitBreaker)
            .AddTimeout(options.AttemptTimeout);
    }

    private static Func<HttpRequestMessage, ResiliencePipeline<HttpResponseMessage>> CreateStandardPipelineSelector(
        IServiceProvider serviceProvider,
        string standardName,
        string noRetryName)
    {
        var resilienceProvider = serviceProvider.GetRequiredService<ResiliencePipelineProvider<HttpKey>>();
        var keyProvider = serviceProvider.GetPipelineKeyProvider(standardName);

        if (keyProvider == null)
        {
            // Build the pipelines eagerly so that misconfigured options fail fast
            // with an OptionsValidationException when the handler is created. The
            // selector still fetches the pipeline per request (instead of caching
            // the instance) so that dynamically reloaded pipelines take effect.
            _ = resilienceProvider.GetPipeline<HttpResponseMessage>(new HttpKey(standardName, string.Empty));
            _ = resilienceProvider.GetPipeline<HttpResponseMessage>(new HttpKey(noRetryName, string.Empty));

            return request => HasReplayableContent(request)
                ? resilienceProvider.GetPipeline<HttpResponseMessage>(new HttpKey(standardName, string.Empty))
                : resilienceProvider.GetPipeline<HttpResponseMessage>(new HttpKey(noRetryName, string.Empty));
        }
        else
        {
            // Eagerly check that the pipeline key provider is correctly configured.
            TouchPipelineKey(keyProvider);

            return request => HasReplayableContent(request)
                ? resilienceProvider.GetPipeline<HttpResponseMessage>(new HttpKey(standardName, keyProvider(request)))
                : resilienceProvider.GetPipeline<HttpResponseMessage>(new HttpKey(noRetryName, string.Empty));
        }
    }

    private static bool HasReplayableContent(HttpRequestMessage request)
    {
        HttpContent? content = request.Content;

        return content is null
            || content is StringContent or ByteArrayContent or FormUrlEncodedContent or JsonContent
            || content is MultipartContent;
    }

    private sealed record HttpStandardResiliencePipelineBuilder(string PipelineName, IServiceCollection Services) : IHttpStandardResiliencePipelineBuilder;
}
