# WantsACracker.Extensions.Http.Resilience

Resilience mechanisms for `HttpClient` built on the independently implemented `WantsACracker` core package. This package provides a migration path for supported `Microsoft.Extensions.Http.Resilience` scenarios: the same handler registration surface, with the resilience strategies supplied by `WantsACracker` instead of Polly.

## Install the package

From the command-line:

```console
dotnet add package WantsACracker.Extensions.Http.Resilience
```

Or directly in the C# project file:

```xml
<ItemGroup>
  <PackageReference Include="WantsACracker.Extensions.Http.Resilience" Version="0.1.0-preview.1" />
</ItemGroup>
```

## Usage Examples

When configuring an `HttpClient` through the [HTTP client factory](https://learn.microsoft.com/dotnet/core/extensions/httpclient-factory), the handler registration extensions add pre-configured resilience behaviors. The standard resilience pipeline combines multiple strategies with pre-configured defaults:

- The total request timeout limits the overall duration of the request, including retries.
- The retry pipeline retries the request when the dependency is slow or returns a transient error.
- The rate limiter limits the maximum number of requests being sent to the dependency.
- The circuit breaker blocks execution if too many direct failures or timeouts are detected.
- The attempt timeout limits the duration of each individual request attempt and throws if it is exceeded.

### Resilience

```csharp
var clientBuilder = services.AddHttpClient("MyClient");

clientBuilder.AddStandardResilienceHandler().Configure(o =>
{
    o.CircuitBreaker.MinimumThroughput = 10;
});
```

### Retrying requests with content

The standard resilience handler never silently retries a request whose body cannot be replayed. The pipeline is selected per request based on the request's content:

- The content is considered **replayable** when it is absent (the request has no content) or when it is one of the built-in bufferable `HttpContent` types: `StringContent`, `ByteArrayContent`, `FormUrlEncodedContent`, `JsonContent`, or `MultipartContent`. Requests with replayable content are sent through the standard pipeline, including the retry pipeline.
- **All other content** — including a non-seekable `StreamContent` and any custom `HttpContent` subclass — is treated as **non-replayable**. Such requests are sent through an identical pipeline without the retry pipeline, so the request body is sent at most once and is never silently re-sent.

This rule matches the replayability rule of the `WantsACracker` standard resilience handler.

### Hedging

The standard hedging pipeline uses a pool of circuit breakers to ensure that unhealthy endpoints are not hedged against. By default, the selection from the pool is based on the URL authority (scheme + host + port). It is recommended that you configure the way the strategies are selected by calling the `SelectPipelineByAuthority()` extension.

```csharp
var clientBuilder = services.AddHttpClient("MyClient");

clientBuilder.AddStandardHedgingHandler().Configure(o =>
{
    o.TotalRequestTimeout.Timeout = TimeSpan.FromSeconds(10);
});
```

The routing strategy builder (`IStandardHedgingHandlerBuilder.RoutingStrategyBuilder`) supports ordered groups (`ConfigureOrderedGroups`) and weighted groups (`ConfigureWeightedGroups`).

### Custom Resilience

For more granular control, a custom pipeline can be constructed with the `WantsACracker` builder extensions:

```csharp
var clientBuilder = services.AddHttpClient("MyClient");

clientBuilder.AddResilienceHandler("myHandler", b =>
{
    b.AddRetry(new HttpRetryStrategyOptions())
     .AddCircuitBreaker(new HttpCircuitBreakerStrategyOptions())
     .AddTimeout(new HttpTimeoutStrategyOptions());
});
```

## Known issues

The following sections detail various known issues.

### Compatibility with the `Grpc.Net.ClientFactory` package

If you're using `Grpc.Net.ClientFactory` version `2.63.0` or earlier, then enabling the standard resilience or hedging handlers for a gRPC client could cause a runtime exception when the client is created. The package includes a build-time check that verifies the `Grpc.Net.ClientFactory` version and produces a compilation warning if it is `2.63.0` or earlier. To resolve the issue, upgrade to `Grpc.Net.ClientFactory` version `2.64.0` or later; to suppress the warning, set the following property in your project file:

```xml
<PropertyGroup>
  <SuppressCheckGrpcNetClientFactoryVersion>true</SuppressCheckGrpcNetClientFactoryVersion>
</PropertyGroup>
```

### Compatibility with .NET Application Insights

If you're using .NET Application Insights version **2.22.0** or lower, then registering the resilience handlers before the Application Insights services could cause all Application Insights telemetry to be missing. The issue can be fixed by updating .NET Application Insights to version **2.23.0** or higher. If you cannot update it, register the Application Insights services before the resilience functionality:

```csharp
services.AddApplicationInsightsTelemetry();
services.AddHttpClient().AddStandardResilienceHandler();
```

## Feedback & Contributing

The source lives in the [WantsACracker fork of dotnet/extensions](https://github.com/alefranz/Extensions) on the `wants-a-cracker` branch. Feedback and contributions are welcome there.
