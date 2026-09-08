# WantsACracker.Extensions.Resilience

Extensions to the WantsACracker resilience pipeline that enrich telemetry with request metadata and exception summaries. This package depends on the separately structured `WantsACracker` core package, which is added transitively.

## Install the package

From the command-line:

```console
dotnet add package WantsACracker.Extensions.Resilience
```

Or directly in the C# project file:

```xml
<ItemGroup>
  <PackageReference Include="WantsACracker.Extensions.Resilience" Version="0.1.0-preview.1" />
</ItemGroup>
```

## Usage Examples

The enricher can be registered with the following method (in the `Microsoft.Extensions.DependencyInjection` namespace):

```csharp
public static IServiceCollection AddResilienceEnricher(this IServiceCollection services)
```

When a resilience pipeline executes, this enricher adds telemetry tags for the current operation. It optionally consumes the `IExceptionSummarizer` service if it has been registered and includes that data in the telemetry.

Request metadata can be attached to a `WantsACracker.ResilienceContext` with these extensions (in the `WantsACracker` namespace):

```csharp
public static void SetRequestMetadata(this WantsACracker.ResilienceContext context, RequestMetadata requestMetadata)
public static RequestMetadata? GetRequestMetadata(this WantsACracker.ResilienceContext context)
```

where `RequestMetadata` is `Microsoft.Extensions.Http.Diagnostics.RequestMetadata`. Metadata set on the context is included in the telemetry emitted while the pipeline runs.

## Feedback & Contributing

The source lives in the [WantsACracker fork of dotnet/extensions](https://github.com/alefranz/Extensions) on the `wants-a-cracker` branch. Feedback and contributions are welcome there.
