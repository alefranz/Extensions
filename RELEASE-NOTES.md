# Release notes

This file records the release notes for the WantsACracker migration packages this branch publishes (`WantsACracker.Extensions.Resilience` and `WantsACracker.Extensions.Http.Resilience`). It is a fork-owned release-truth document (like `UPSTREAM.md`); it is not packed into the packages — the per-package user documentation is the `README.md` at each project directory's root, which is packed. It records what shipped and what was proven; it is not marketing.

## 0.1.0-preview.1 (2026-09-06)

### What this preview ships

Exactly two packages from this branch, both at `0.1.0-preview.1`, completing the three-package preview set with the `WantsACracker` core package (the committed feed nupkg under `eng/local-packages`, packed from the core repository at the pinned commit and tracked by `smoke/run-deterministic-pack.sh`):

| Package | What it is |
| --- | --- |
| `WantsACracker.Extensions.Resilience` | Extensions to the resilience pipeline that enrich telemetry with metadata and exception summaries. `net10.0;net9.0;net8.0;netstandard2.0;net462`. |
| `WantsACracker.Extensions.Http.Resilience` | The HTTP resilience integration for `IHttpClientFactory`, including `AddStandardResilienceHandler()`. The source-compatible migration path for supported `Microsoft.Extensions.Http.Resilience` scenarios. Same TFM set. |

Both packages depend on `WantsACracker 0.1.0-preview.1` (declared in every TFM dependency group) and on the published `10.9.0` sibling line (`UPSTREAM.md` divergence 8). Neither package carries any Polly dependency. MIT expression licence; each package carries its `README.md` and `THIRD-PARTY-NOTICES.TXT` at the package root.

The standard-handler surface — the supported migration surface — is `AddStandardResilienceHandler()` (all three overloads) on a named `HttpClient`, composing, outside-in: rate limiter → total request timeout → retry (honouring `Retry-After`) → circuit breaker → attempt timeout. The standard handler never retries a request whose content cannot be replayed (the no-retry safety gate; `UPSTREAM.md` divergence 5, policy in the Http.Resilience package README "Retrying requests with content"). Hedging and routing surfaces are present in the packages and documented as **experimental** in the package READMEs; dynamic options reload is wired and documented as experimental. The per-surface four-state compatibility matrix against the Polly 8.4.2 reference is in the core repository's `docs/MIGRATION.md` (the preview section).

### Differential evidence (the supported P0 surface, as proven at the seam)

The full 24-scenario P0 set of the standard-handler surface — all 24 behavioural facts, driven at the shared public seam (a named `HttpClient` through `AddStandardResilienceHandler()`) by the checked-in harness `smoke/run-differential.sh` (release-guard stage 6) — compares the three `0.1.0-preview.1` packages (no Polly in the resolved graph) against the Polly 8.4.2 reference (`Microsoft.Extensions.Http.Resilience 10.9.0`, which pins exactly `Polly.Core`/`Polly.Extensions`/`Polly.RateLimiting` 8.4.2). Result (2026-09-06, `net8.0`, two consecutive end-to-end runs, exit 0): **22 MATCH + 2 documented DIFFERENCE**. The per-scenario table is the durable evidence record in `smoke/README.md`.

The two documented differences:

1. **`no-retry-non-replayable`** — the deliberate no-retry safety gate (`UPSTREAM.md` divergence 5): the preview never retries a non-replayable body (the original `503` surfaces after the single attempt), while the 8.4.2 reference composes the retry strategy unconditionally and surfaces the retry's `HttpRequestException` (the content cannot be sent twice). Both sides make exactly one server attempt.
2. **`rate-limiter-queue-overload-rejection`** — the overload-rejection exception type: the 8.4.2 reference throws `RateLimiterRejectedException` (Polly.Core; a non-cancellation exception whose message does not name the queue), while the preview rejects the full queue with an `OperationCanceledException` whose message identifies the full queue. Both sides reject after exactly one server attempt, and both keep the rejection distinct from a plain caller cancellation.

Documented limitations of the seam-level proof (full list in `smoke/README.md`): connection-failure shape is proven as a real connection abort (raw-TCP loopback) rather than the core's scripted-injection form; `Retry.MaxRetryAttempts = 0` is rejected by the 8.4.2 reference's options validation but allowed by the preview (scenarios use `1`, the lowest value both sides accept); the seam surfaces the raw BCL `TaskCanceledException` for caller cancellation (the core standalone handler normalizes to `OperationCanceledException`); and the retry-storm scenario's exact server-attempt count varies with backoff jitter (both sides must fall in the inclusive band 4–6).

### Preview caveats

- **Not yet published.** All three packages are packed but not on NuGet, and the three package IDs are **not reserved** (NuGet flat-container 404s are an availability signal, not a reservation). Publication, after ID reservation, is a maintainer-operated handoff.
- **0.x preview line.** Breaking changes are allowed between minor versions; the public API is not frozen. The migration packages track the versioning line of the upstream packages they replace.
- **Symbols / source links.** The pack produces the main nupkg plus a legacy `.symbols.nupkg` (per-TFM PDBs); SourceLink metadata is not yet included in the pack and its validation at the CI pack is a pending step-6 item (the core disables the SDK-embedded SourceLink document map at the source until the CI plumbing makes it reproducible — `UPSTREAM.md` divergence 13).
- **Package signing** is not applied to the preview (optional for the first preview; mandatory before production support).
- The un-renamed sibling dependencies are consumed from the **published `10.9.0` line** (divergence 8), not the fork's `10.10.0-dev` local-train version, which is unpublished and would make the packages unresolvable from public feeds.

### Release artifacts (this branch, `0.1.0-preview.1`)

- **Deterministic packaging:** `smoke/run-deterministic-pack.sh` (release-guard stage 7; divergence 13) proves two consecutive clean-state packs of both projects are byte-identical after the documented normalization, and that a fresh pack of the pinned core commit is identical to the committed feed nupkg (the sha256 pin is tracked in `smoke/run-deterministic-pack.sh`).
- **Release guard:** `smoke/run-release-guard.sh` (stages 1–7) is the one checked-in command covering build, tests, API-surface baselines, the clean-consumer smoke, package-content checks (id/version, MIT expression licence, README + THIRD-PARTY-NOTICES, per-group core dependency, no Polly), the differential proof, and the deterministic-pack check.
- **SBOM:** one SPDX 2.2 SBOM per package, checked in under `eng/sbom/`, generated with the pinned `Microsoft.Sbom.DotNetTool 4.1.5` by `eng/sbom/generate-sboms.sh` (fixed generation timestamp; canonical reproducibility check documented in the script header).
- **Licence/notices:** the MIT expression licence and the per-package `THIRD-PARTY-NOTICES.TXT` content (dotnet/extensions-derived code, .NET Foundation, MIT; the MIT-licensed dependencies including the WantsACracker core) were verified against the actual package contents and dependency graph for this release.
