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

_None yet — this branch is published directly from the baseline commit._

## Rebase and sync policy

- **Quarterly:** compare the relevant paths to upstream `main`; log each change as adopted, deferred, or rejected in the divergence list above.
- **Before every .NET major release:** rebase `wants-a-cracker`, run conformance tests, and decide whether to publish a matching release.
- Rebases are done against the protected `main` baseline, which is fast-forwarded from upstream rather than rebased itself.
