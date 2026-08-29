# Upstream relationship

This repository is a fork of [`dotnet/extensions`](https://github.com/dotnet/extensions) that publishes the WantsACracker migration packages. It is deliberately narrow: the only intended divergence from upstream is the mechanical substitution of Polly for the independently implemented `WantsACracker` APIs in the HTTP resilience integration, plus the accompanying package, namespace, and metadata renames.

## Branches

- `main` — upstream-tracking baseline. Branch-protected (no force pushes, deletions, or fork syncing). Never commit product changes here.
- `wants-a-cracker` — long-lived branch where all product work happens. Submodule pins in downstream repositories point at this branch.

## Baseline

- Upstream: `dotnet/extensions`
- Baseline commit: `cc597aa24bf108c38a6a59d09555765575d11cb3` — *Validate path segments in Azure storage result store and response cache (#7718)*
- Pinned on: 2026-08-26
- Polly versions at baseline (from `eng/Versions.props`): `9.0.18` (default), `10.0.10` (net10.0), `8.0.29` (net8.0)

## Relevant paths

The only paths expected to diverge from upstream:

| Path | Reason for divergence |
|---|---|
| `src/Libraries/Microsoft.Extensions.Resilience/` | Rename to `WantsACracker.Extensions.Resilience`; replace Polly references with WantsACracker equivalents |
| `src/Libraries/Microsoft.Extensions.Http.Resilience/` | Rename to `WantsACracker.Extensions.Http.Resilience`; replace Polly references with WantsACracker equivalents |
| `test/Libraries/Microsoft.Extensions.Resilience.Tests/` | Follows the source rename; behaviour preserved |
| `test/Libraries/Microsoft.Extensions.Http.Resilience.Tests/` | Follows the source rename; behaviour preserved |
| `bench/Libraries/Microsoft.Extensions.Resilience.PerformanceTests/` | Follows the source rename |
| `bench/Libraries/Microsoft.Extensions.Http.Resilience.PerformanceTests/` | Follows the source rename |
| `eng/Versions.props` | Polly version entries replaced by WantsACracker package versions |

Everything else — build infrastructure, other libraries, analyzers, documentation, samples — must remain byte-identical to upstream. If a change outside this list becomes necessary, it must be justified in the commit message and logged in the divergence list below.

## Divergence rules

- Changes must be mechanical: package IDs, namespaces, and dependency references.
- Preserve upstream behaviour, structure, tests, metadata, and style unless a rename requires the change.
- No refactors, feature work, or unrelated cleanup in this branch.
- Every divergence carries a short rationale in its commit message.

## Divergences from baseline

1. **2026-08-29 — Rename resilience package IDs and public namespaces to `WantsACracker.Extensions.*`** (first migration slice; renames only, Polly untouched):
   - `src/Libraries/Microsoft.Extensions.Resilience/` and `src/Libraries/Microsoft.Extensions.Http.Resilience/`: the project file, the API-surface `.json` and (Http.Resilience) the `buildTransitive/*.targets` file are renamed to `WantsACracker.Extensions[.Http].Resilience.*`, which moves `AssemblyName`, `PackageId` and `RootNamespace` to the `WantsACracker` identity (the API-staging analyzer and the `$(MSBuildProjectName).json` / `buildTransitive\$(MSBuildProjectName).targets` build machinery key off the project file name, so the files had to follow). All public namespaces move from `Microsoft.Extensions[.Http].Resilience` to `WantsACracker.Extensions[.Http].Resilience`; the extension classes living in `Microsoft.Extensions.DependencyInjection` and `System.Net.Http` keep their namespaces. `EnablePackageValidation` is set to `false` in both source projects because no published baseline version exists under the new package IDs yet.
   - `test/Libraries/Microsoft.Extensions.Resilience.Tests/` and `test/Libraries/Microsoft.Extensions.Http.Resilience.Tests/`: projects, test namespaces, the proto `csharp_namespace` and the embedded path to the renamed `.targets` file follow the source rename; behaviour and assertions preserved.
   - `bench/Libraries/Microsoft.Extensions.Resilience.PerformanceTests/` and `bench/Libraries/Microsoft.Extensions.Http.Resilience.PerformanceTests/`: follow the source rename, as declared in the relevant-paths table above.
   - `src/ProjectTemplates/Microsoft.Extensions.AI.Templates/Microsoft.Extensions.AI.Templates.csproj` and `test/Libraries/Microsoft.Extensions.AotCompatibility.TestApp/Microsoft.Extensions.AotCompatibility.TestApp.csproj`: mechanical project-reference path updates only.
   - Rationale: required so the published packages carry the `WantsACracker` identity before the Polly → WantsACracker dependency swap (next slice).

## Rebase and sync policy

- **Quarterly:** compare the relevant paths to upstream `main`; log each change as adopted, deferred, or rejected in the divergence list above.
- **Before every .NET major release:** rebase `wants-a-cracker`, run conformance tests, and decide whether to publish a matching release.
- Rebases are done against the protected `main` baseline, which is fast-forwarded from upstream rather than rebased itself.
