# Clean-consumer smoke test (package-level release guard)

`run-clean-consumer.sh` proves that the three `0.1.0-preview.1` packages ship as a set a clean consumer can actually use. It is the checked-in, durable form of the 2026-09-04 three-feed scratch probe (preview-path step 3) and is the smoke test the step-4 CI release guard invokes.

## What it does

1. Builds and packs the two renamed src projects at `0.1.0-preview.1` (repo build flow, repo-local pinned SDK).
2. Collects **exactly** the three preview nupkgs into a temporary local feed: the committed core feed nupkg (`eng/local-packages/WantsACracker.0.1.0-preview.1.nupkg`, sha256-verified) plus fresh packs of `WantsACracker.Extensions.Resilience` and `WantsACracker.Extensions.Http.Resilience`.
3. Restores and builds the minimal consumer app in `clean-consumer/` — a named `HttpClient` wired through the real `AddHttpClient("smoke")` + `AddStandardResilienceHandler()` path, using **package references only** (never project references) to exactly the three packages — from an **empty isolated `NUGET_PACKAGES` cache**, against the feed plus `nuget.org` (the published `10.9.0` sibling dependencies resolve from `nuget.org`).
4. Verifies the resolved dependency graph: exactly the expected 29-package set at the expected versions (the three preview packages at `0.1.0-preview.1`, the three un-renamed siblings and their transitive closure at their pinned versions) and **no `Polly` package anywhere** (checked in `project.assets.json` and in the populated cache).
5. Runs a fully **offline** scenario: a small in-process loopback `HttpListener` answers `503` to the first request; the standard handler's retry recovers and the retried response is `200`. The consumer exits `0` only then.

The script exits non-zero on any failure at any stage: build/pack, restore, build, run, feed drift, an unexpected resolved package set or version, or a resolved/downloaded Polly package.

## How to run

```sh
smoke/run-clean-consumer.sh
```

No arguments; runnable from any working directory. Requirements: `bash`, and network access to `nuget.org` for the published sibling dependencies and the net8.0 reference pack — the scenario itself needs no network (loopback only). All intermediate state is kept in a temporary directory that is removed on exit; the pack output goes to the gitignored `artifacts/` tree, so the run leaves **no tracked build output** behind.

## Release guard (preview-path step 4, divergence 10)

`run-release-guard.sh` is the one checked-in release-guard command; it runs, in
order (non-zero exit on any failure):

1. Builds the two renamed src projects (Release, all TFMs, repo build flow).
2. Runs the two renamed test suites on `net8.0`.
3. Checks the API surface: the build runs the ApiLifecycle analyzer against the
   committed API-baseline jsons, and the guard asserts those baselines are
   untouched afterwards.
4. Invokes **this script, unchanged** (`bash smoke/run-clean-consumer.sh`).
5. Runs package-content checks on the three preview nupkgs (nuspec id/version,
   MIT expression licence, README + THIRD-PARTY-NOTICES at the package root,
   `WantsACracker 0.1.0-preview.1` declared in every TFM dependency group, no
   Polly anywhere).

Locally (any plain checkout):

```sh
smoke/run-release-guard.sh
```

CI: the thin wrapper `.github/workflows/wantsacracker-release-guard.yml` runs
exactly `bash smoke/run-release-guard.sh` on pushes to `wants-a-cracker` and
PRs targeting it (the upstream dotnet/extensions workflows are untouched; no
publishing, signing, matrix, or other platform expansion). The guard is
additive-only and leaves no tracked build output behind.

## Differential compatibility harness (preview-path step 5, divergence 11)

`run-differential.sh` drives a representative offline subset of the P0 HTTP scenarios
through **both** sides of the source-level compatibility claim, at the shared public
seam (a named `HttpClient` wired with `AddStandardResilienceHandler()`), and fails on
any outcome that is not the expected one for its side:

- **WantsACracker side** — the three `0.1.0-preview.1` packages (the committed core
  feed nupkg, sha256-verified, + fresh packs of the two fork projects) restored from an
  **empty isolated `NUGET_PACKAGES` cache** against a temporary feed that contains
  exactly those three nupkgs plus `nuget.org`; the resolved graph must contain **no
  Polly** (checked in `project.assets.json` and the populated cache).
- **Reference side (Polly 8.4.2)** — `Microsoft.Extensions.Http.Resilience 10.9.0`
  from `nuget.org` (the one non-local package fetch). Why 10.9.0: **no 8.4.x version of
  this package exists** (the 8.x line stops at 8.5.0, and 8.4.0/8.5.0 resolve
  `Polly 8.3.0`, not the 8.4.2 surface). 10.9.0 is the published sibling of the fork's
  10.10.0-dev upstream baseline (the same line the un-renamed sibling deps are pinned to,
  divergence 8); it resolves `Microsoft.Extensions.Resilience 10.9.0`, which pins
  **exactly `Polly.Core` / `Polly.Extensions` / `Polly.RateLimiting` 8.4.2** — the
  compatibility surface the fork proves against. The script asserts the resolved graph
  carries exactly 8.4.2 of all three, so the reference side cannot silently drift to a
  newer Polly line.

The scenario source is one checked-in file (`differential/Program.cs`) that encodes
**both** sides: every line that legitimately differs appears as a paired marker block
(active line marked `// @@WAC@@` + its counterpart as a `//@@POLLY@@` comment). The
WantsACracker build compiles the file as checked in; the reference build removes the
marked lines and uncomments the counterparts, and the script verifies the
transformation is exactly the pair swap (marker counts paired, no leftover markers,
diff line count = 3 × pairs). Today exactly **one** source line differs between the
two builds (the options-type alias below); everything else — request sequences,
server, scenario plumbing — is byte-identical. All scenarios are fully offline
(in-process loopback `HttpListener`); both apps are built **out-of-tree** in a
temporary workspace, so no tracked build output is left behind.

### Surface differences at the 8.4.2 reference (as proven by the harness)

| Surface | Reference (Polly 8.4.2, via `Microsoft.Extensions.Http.Resilience 10.9.0`) | WantsACracker `0.1.0-preview.1` |
| --- | --- | --- |
| Options type | `Microsoft.Extensions.Http.Resilience.HttpStandardResilienceOptions` | `WantsACracker.Extensions.Http.Resilience.HttpStandardResilienceOptions` (same type name, different package — the one marked line) |
| Attempt timeout | `AttemptTimeout.Timeout` | `AttemptTimeout.Timeout` (identical) |
| Total-request timeout | `TotalRequestTimeout.Timeout` | `TotalRequestTimeout.Timeout` (identical) |
| Circuit-breaker options | `FailureRatio` / `MinimumThroughput` / `SamplingDuration` / `BreakDuration` (Polly.Core 8.4.2 names) | `FailureRatio` / `MinimumThroughput` / `SamplingDuration` / `BreakDuration` (identical) |
| Retry options | `Retry.MaxRetryAttempts` / `Delay` / `MaxDelay` | identical |
| Breaker-open rejection | `BrokenCircuitException` (Polly.Core's name; `CircuitBreakerOpenException` is the legacy Polly v7 name and does not exist in the 8.4.2 surface) | `BrokenCircuitException` (identical) |

Superseded assumption, corrected by the harness: earlier work assumed the 8.4.2
reference used `Timeout.AttemptTimeoutDuration` /
`TotalRequestTimeout.TotalRequestDuration` and `FailureThreshold` / `MinThroughput` /
`SamplingInterval` / `BreakerDelay`. Those are the **8.4.0/8.5.0-line** (Polly 8.3.0)
and **pre-8.3.0** surfaces respectively; the names that exist on the actual 8.4.2
surface are the ones the preview mirrors. The one remaining options-validation
divergence this surface exposes: the reference rejects `Retry.MaxRetryAttempts = 0`
(documented validation difference — the preview allows it), so the circuit-breaker
scenario uses `1`, the lowest value both sides accept.

### Per-scenario results (2026-09-05, `net8.0`, both sides, same offline server)

| Scenario | WantsACracker `0.1.0-preview.1` | Reference (Polly 8.4.2) | Result |
| --- | --- | --- | --- |
| `retry-503-then-success` | `response:200 (server-attempts=2)` | `response:200 (server-attempts=2)` | MATCH |
| `attempt-timeout-then-retry` | `response:200 (server-attempts=2)` | `response:200 (server-attempts=2)` | MATCH |
| `total-timeout-fails` | `exception:TimeoutRejectedException (server-attempts=2)` | `exception:TimeoutRejectedException (server-attempts=2)` | MATCH |
| `circuit-breaker-opens` | `response:503,exception:BrokenCircuitException×4 (server-attempts=2)` | `response:503,exception:BrokenCircuitException×4 (server-attempts=2)` | MATCH |
| `no-retry-non-replayable` | `response:503 (server-attempts=1)` | `exception:HttpRequestException (server-attempts=1)` | **DIFFERENCE (documented)** |

The single documented difference is the fork's deliberate no-retry safety gate for
non-replayable request bodies (divergence 5): the WantsACracker standard handler never
retries a request whose content cannot be replayed (here a non-seekable
`StreamContent`), so the original `503` surfaces after the single attempt; the 8.4.2
reference composes the retry strategy unconditionally, its retry's second attempt
fails with `HttpRequestException` (the request content cannot be sent twice), and that
exception — not the `503` — surfaces. Both sides make exactly one server attempt.

### How to run

```sh
smoke/run-differential.sh
```

No arguments. Requirements: `bash`, the repo-local pinned SDK (the script runs the
repo build flow first, which provides `.dotnet/dotnet`), and network access to
`nuget.org` for the published sibling dependencies and the reference package (hermetic
once in the cache; the scenario apps themselves are offline). The script exits
non-zero on any failure at any stage — build/pack, restore, feed drift, a resolved
Polly package on the WantsACracker side, a Polly version other than 8.4.2 on the
reference side, a marker transformation that is not exactly the pair swap, an app
exit failure, or a per-scenario outcome that is neither the expected one for its side
nor a documented difference.

## Layout

- `run-clean-consumer.sh` — the single checked-in command.
- `clean-consumer/consumer.csproj`, `clean-consumer/Program.cs` — the consumer app source. The script copies them into the temporary workspace and builds them **out-of-tree** (no repo `Directory.Build.props` inheritance, no repository solution membership), so building them never creates build output inside the repository. The `nuget.config` pinning the temporary feed is generated by the script in the workspace (the feed path is run-specific).
- `run-differential.sh` — the differential harness command (above).
- `differential/Program.cs` — the dual-side scenario source (marker pairs).
- `differential/wantsacracker.csproj`, `differential/polly.csproj` — the two out-of-tree app project files (package references only: the three preview packages / `Microsoft.Extensions.Http.Resilience 10.9.0`).
