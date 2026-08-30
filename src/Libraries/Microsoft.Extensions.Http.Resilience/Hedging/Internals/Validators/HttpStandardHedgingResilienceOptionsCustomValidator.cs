// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using Microsoft.Extensions.Options;

namespace WantsACracker.Extensions.Http.Resilience.Internal.Validators;

internal sealed class HttpStandardHedgingResilienceOptionsCustomValidator : IValidateOptions<HttpStandardHedgingResilienceOptions>
{
    private const int CircuitBreakerTimeoutMultiplier = 2;

    // Mirrors the hedging limits enforced by the WantsACracker AddHedging builder method.
    private const int MinimumHedgedAttempts = 1;
    private const int MaximumHedgedAttempts = 10;

    public ValidateOptionsResult Validate(string? name, HttpStandardHedgingResilienceOptions options)
    {
        var builder = new ValidateOptionsResultBuilder();

        if (options.Endpoint.Timeout.Timeout > options.TotalRequestTimeout.Timeout)
        {
            builder.AddError($"Total request timeout strategy must have a greater timeout than the attempt timeout strategy. " +
                $"Total Request Timeout: {options.TotalRequestTimeout.Timeout.TotalSeconds}s, " +
                $"Attempt Timeout: {options.Endpoint.Timeout.Timeout.TotalSeconds}s");
        }

        var timeout = TimeSpan.FromMilliseconds(options.Endpoint.Timeout.Timeout.TotalMilliseconds * CircuitBreakerTimeoutMultiplier);
        if (options.Endpoint.CircuitBreaker.SamplingDuration < timeout)
        {
            builder.AddError("The sampling duration of circuit breaker strategy needs to be at least double of " +
                $"an attempt timeout strategy’s timeout interval, in order to be effective. " +
                $"Sampling Duration: {options.Endpoint.CircuitBreaker.SamplingDuration.TotalSeconds}s," +
                $"Attempt Timeout: {options.Endpoint.Timeout.Timeout.TotalSeconds}s");
        }

        // if generator is specified we cannot calculate the max hedging delay
        if (options.Hedging.DelayGenerator == null)
        {
            var maxHedgingDelay = TimeSpan.FromMilliseconds(options.Hedging.MaxHedgedAttempts * options.Hedging.Delay.TotalMilliseconds);

            // Stryker disable once Equality
            if (maxHedgingDelay > options.TotalRequestTimeout.Timeout)
            {
                builder.AddError($"The cumulative delay of the hedging strategy is larger than total request timeout interval. " +
                    $"Total Request Timeout: {options.TotalRequestTimeout.Timeout.TotalSeconds}s, " +
                    $"Cumulative Hedging Delay: {maxHedgingDelay.TotalSeconds}s");
            }
        }

        // the strategy options have no data annotations for the generated options
        // validator to range-check, so mirror the builder validation here to make
        // invalid configurations fail with an OptionsValidationException early
        if (options.Hedging.MaxHedgedAttempts < MinimumHedgedAttempts || options.Hedging.MaxHedgedAttempts > MaximumHedgedAttempts)
        {
            builder.AddError($"The maximum hedged attempts must be between {MinimumHedgedAttempts} and {MaximumHedgedAttempts}.");
        }

        ValidateTimeout(builder, options.TotalRequestTimeout);
        ValidateTimeout(builder, options.Endpoint.Timeout);

        if (options.Endpoint.CircuitBreaker.SamplingDuration <= TimeSpan.Zero)
        {
            builder.AddError("The sampling duration of circuit breaker strategy must be a positive value.");
        }

        if (options.Endpoint.CircuitBreaker.MinimumThroughput < 1)
        {
            builder.AddError("The minimum throughput of circuit breaker strategy must be one or a positive value.");
        }

        if (options.Endpoint.CircuitBreaker.FailureRatio <= 0.0 || options.Endpoint.CircuitBreaker.FailureRatio > 1.0)
        {
            builder.AddError("The failure ratio of circuit breaker strategy must be a value between 0.0 and 1.0, exclusive of 0.0.");
        }

        if (options.Endpoint.CircuitBreaker.BreakDurationGenerator is null && options.Endpoint.CircuitBreaker.BreakDuration <= TimeSpan.Zero)
        {
            builder.AddError("The break duration of circuit breaker strategy must be a positive value when no break duration generator is provided.");
        }

        return builder.Build();
    }

    private static void ValidateTimeout(ValidateOptionsResultBuilder builder, HttpTimeoutStrategyOptions timeout)
    {
        if (timeout.TimeoutGenerator is null
            && (timeout.Timeout < TimeSpan.FromMilliseconds(10) || timeout.Timeout > TimeSpan.FromDays(1)))
        {
            builder.AddError("The timeout must be between 00:00:00.01 (ten milliseconds) and 1.00:00:00 (one day), inclusive, when no timeout generator is provided.");
        }
    }
}
