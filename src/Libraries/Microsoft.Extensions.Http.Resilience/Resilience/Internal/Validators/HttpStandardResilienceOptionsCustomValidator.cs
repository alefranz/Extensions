// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using Microsoft.Extensions.Options;

namespace WantsACracker.Extensions.Http.Resilience.Internal.Validators;

internal sealed class HttpStandardResilienceOptionsCustomValidator : IValidateOptions<HttpStandardResilienceOptions>
{
    private const int CircuitBreakerTimeoutMultiplier = 2;

    public ValidateOptionsResult Validate(string? name, HttpStandardResilienceOptions options)
    {
        var builder = new ValidateOptionsResultBuilder();

        if (options.AttemptTimeout.Timeout > options.TotalRequestTimeout.Timeout)
        {
            builder.AddError($"Total request timeout resilience strategy must have a greater timeout than the attempt resilience strategy. " +
                $"Total Request Timeout: {options.TotalRequestTimeout.Timeout.TotalSeconds}s, " +
                $"Attempt Timeout: {options.AttemptTimeout.Timeout.TotalSeconds}s");
        }

        if (options.CircuitBreaker.SamplingDuration < TimeSpan.FromMilliseconds(options.AttemptTimeout.Timeout.TotalMilliseconds * CircuitBreakerTimeoutMultiplier))
        {
            builder.AddError("The sampling duration of circuit breaker strategy needs to be at least double of " +
                $"an attempt timeout strategy’s timeout interval, in order to be effective. " +
                $"Sampling Duration: {options.CircuitBreaker.SamplingDuration.TotalSeconds}s," +
                $"Attempt Timeout: {options.AttemptTimeout.Timeout.TotalSeconds}s");
        }

        // the strategy options have no data annotations for the generated options
        // validator to range-check, so mirror the builder validation here to make
        // invalid configurations fail with an OptionsValidationException early
        if (options.Retry.MaxRetryAttempts < 0)
        {
            builder.AddError("The maximum retry attempts must be zero or a positive value.");
        }

        if (options.Retry.Delay < TimeSpan.Zero)
        {
            builder.AddError("The retry delay must be zero or a positive value.");
        }

        if (options.Retry.MaxDelay is { } maxRetryDelay && maxRetryDelay < TimeSpan.Zero)
        {
            builder.AddError("The maximum retry delay must be zero or a positive value.");
        }

        ValidateTimeout(builder, options.TotalRequestTimeout);
        ValidateTimeout(builder, options.AttemptTimeout);

        if (options.CircuitBreaker.SamplingDuration <= TimeSpan.Zero)
        {
            builder.AddError("The sampling duration of circuit breaker strategy must be a positive value.");
        }

        if (options.CircuitBreaker.MinimumThroughput < 1)
        {
            builder.AddError("The minimum throughput of circuit breaker strategy must be one or a positive value.");
        }

        if (options.CircuitBreaker.FailureRatio <= 0.0 || options.CircuitBreaker.FailureRatio > 1.0)
        {
            builder.AddError("The failure ratio of circuit breaker strategy must be a value between 0.0 and 1.0, exclusive of 0.0.");
        }

        if (options.CircuitBreaker.BreakDurationGenerator is null && options.CircuitBreaker.BreakDuration <= TimeSpan.Zero)
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
