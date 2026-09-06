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
6. Runs the differential compatibility proof
   (`bash smoke/run-differential.sh`, divergence 12): the full P0 HTTP scenario
   set through both sides of the source-level compatibility claim at the shared
   `AddStandardResilienceHandler()` seam (see below).

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

`run-differential.sh` drives the **full P0 HTTP scenario set — all 24 behavioural
facts** of the standard-handler surface (the independently authored set in
`WantsACracker.Behavioral.Tests`; the per-scenario mapping is in the evidence table
below) — through **both** sides of the source-level compatibility claim, at the
shared public seam (a named `HttpClient` wired with `AddStandardResilienceHandler()`),
and fails on any outcome that is not the expected one for its side:

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
(in-process loopback — an `HttpListener`, or the raw-TCP server for the two
connection-abort scenarios); both apps are built **out-of-tree** in a
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
| Rate-limiter queue-overload rejection | `RateLimiterRejectedException` (Polly.Core; derives from `ExecutionRejectedException`, i.e. a non-cancellation exception) | `OperationCanceledException` whose message identifies the full queue (documented difference) |

Superseded assumption, corrected by the harness: earlier work assumed the 8.4.2
reference used `Timeout.AttemptTimeoutDuration` /
`TotalRequestTimeout.TotalRequestDuration` and `FailureThreshold` / `MinThroughput` /
`SamplingInterval` / `BreakerDelay`. Those are the **8.4.0/8.5.0-line** (Polly 8.3.0)
and **pre-8.3.0** surfaces respectively; the names that exist on the actual 8.4.2
surface are the ones the preview mirrors. The one remaining options-validation
divergence this surface exposes: the reference rejects `Retry.MaxRetryAttempts = 0`
(documented validation difference — the preview allows it), so the circuit-breaker
scenario uses `1`, the lowest value both sides accept.

### Per-scenario evidence (2026-09-06, `net8.0`, both sides, same offline server)

The full P0 set: all 24 behavioural facts of the standard-handler surface (the
`WantsACracker.Behavioral.Tests` project), each scenario encoding the named core fact.
Result: **22 MATCH + 2 documented DIFFERENCE**. The two differences are the fork's
deliberate no-retry safety gate (divergence 5) and the rate-limiter overload-rejection
exception type (documented below).

| # | Scenario (encodes the core fact) | WantsACracker `0.1.0-preview.1` | Reference (Polly 8.4.2) | Result |
| --- | --- | --- | --- | --- |
| 1 | `retry-503-then-success` — `Retries_on_http_5xx` | `response:200 (server-attempts=2)` | `response:200 (server-attempts=2)` | MATCH |
| 2 | `retry-408-then-success` — `Retries_on_http_408` | `response:200 (server-attempts=2)` | `response:200 (server-attempts=2)` | MATCH |
| 3 | `retry-429-retry-after` — `Retries_on_http_429_and_honours_retry_after_delay` | `response:200,honoured-retry-after:yes (server-attempts=2)` | `response:200,honoured-retry-after:yes (server-attempts=2)` | MATCH |
| 4 | `retry-connection-abort-then-success` — `Retries_on_transient_http_request_exception` | `response:200 (server-attempts=5)` | `response:200 (server-attempts=5)` | MATCH |
| 5 | `no-retry-404` — `Does_not_retry_on_http_4xx_other_than_408_and_429` | `response:404 (server-attempts=1)` | `response:404 (server-attempts=1)` | MATCH |
| 6 | `retry-exhaustion-last-response` — `Stops_after_max_attempts_and_surfaces_the_last_response` | `response:503 (server-attempts=3)` | `response:503 (server-attempts=3)` | MATCH |
| 7 | `retry-exhaustion-last-error` — `Stops_after_max_attempts_and_surfaces_the_last_error` + `Final_failure_with_exception_propagates_the_error_without_returning_a_response` | `exception:HttpRequestException (server-attempts=12)` | `exception:HttpRequestException (server-attempts=12)` | MATCH |
| 8 | `retry-cancellation-during-backoff` — `Respects_cancellation_during_backoff_delay` | `exception:TaskCanceledException (server-attempts=1)` | `exception:TaskCanceledException (server-attempts=1)` | MATCH |
| 9 | `attempt-timeout-then-retry` — `Per_attempt_timeout_surfaces_a_timeout_rejected_exception` (recovery variant) | `response:200 (server-attempts=2)` | `response:200 (server-attempts=2)` | MATCH |
| 10 | `attempt-timeout-rejects` — `Per_attempt_timeout_surfaces_a_timeout_rejected_exception` | `exception:TimeoutRejectedException (server-attempts=2)` | `exception:TimeoutRejectedException (server-attempts=2)` | MATCH |
| 11 | `total-timeout-fails` — `Total_timeout_wraps_retry_and_cuts_off_a_retry_storm` | `exception:TimeoutRejectedException (server-attempts=2)` | `exception:TimeoutRejectedException (server-attempts=2)` | MATCH |
| 12 | `total-timeout-dominates-client-timeout` — `Total_timeout_dominates_the_http_client_timeout_when_the_handler_owns_timeout_management` | `exception:TimeoutRejectedException,client-timeout:infinite,total-timeout-dominated:yes (server-attempts in 4–6)` | `exception:TimeoutRejectedException,client-timeout:infinite,total-timeout-dominated:yes (server-attempts in 4–6)` | MATCH (band) |
| 13 | `caller-cancellation-not-timeout` — `Caller_cancellation_is_not_reported_as_a_resilience_timeout` | `exception:TaskCanceledException (server-attempts=1)` | `exception:TaskCanceledException (server-attempts=1)` | MATCH |
| 14 | `circuit-breaker-opens` — `Opens_after_failure_ratio_threshold_within_sampling_window` | `response:503,exception:BrokenCircuitException×4 (server-attempts=2)` | `response:503,exception:BrokenCircuitException×4 (server-attempts=2)` | MATCH |
| 15 | `circuit-breaker-fails-fast` — `Fails_fast_while_open_without_reaching_the_handler` | `response:503×2,exception:BrokenCircuitException×4 (server-attempts=5)` | `response:503×2,exception:BrokenCircuitException×4 (server-attempts=5)` | MATCH |
| 16 | `circuit-breaker-half-open-recovery` — `Half_open_probe_after_break_duration_allows_recovery` | `response:503×2,exception:BrokenCircuitException×2,response:200 (server-attempts=6)` | `response:503×2,exception:BrokenCircuitException×2,response:200 (server-attempts=6)` | MATCH |
| 17 | `circuit-breaker-successful-probe-closes` — `Successful_probe_closes_the_circuit` | `response:503×2,exception:BrokenCircuitException×3,response:200×7 (server-attempts=12)` | `response:503×2,exception:BrokenCircuitException×3,response:200×7 (server-attempts=12)` | MATCH |
| 18 | `circuit-breaker-below-ratio-stays-closed` — `Failures_below_the_ratio_do_not_open_the_circuit` | `response:503,response:200×5 (server-attempts=7)` | `response:503,response:200×5 (server-attempts=7)` | MATCH |
| 19 | `rate-limiter-queues-beyond-limit` — `Requests_beyond_the_limit_are_queued_then_executed` | `response:200×2 (server-attempts=2)` | `response:200×2 (server-attempts=2)` | MATCH |
| 20 | `rate-limiter-queue-overload-rejection` — `Queue_overload_rejection_surfaces_a_distinct_error` | `exception:OperationCanceledException,queue-rejection:yes,response:200 (server-attempts=1)` | `exception:RateLimiterRejectedException,queue-rejection:no,response:200 (server-attempts=1)` | **DIFFERENCE (documented)** |
| 21 | `rate-limiter-queue-cancellation` — `Cancellation_while_waiting_in_queue_surfaces_operation_canceled` | `exception:TaskCanceledException,caller-token:yes,response:200 (server-attempts=1)` | `exception:TaskCanceledException,caller-token:yes,response:200 (server-attempts=1)` | MATCH |
| 22 | `rate-limiter-permits-no-leak` — `Permits_do_not_leak_when_requests_fail` | `response:400×3,response:200,fast-recovery:yes (server-attempts=4)` | `response:400×3,response:200,fast-recovery:yes (server-attempts=4)` | MATCH |
| 23 | `no-retry-non-replayable` — `Requests_with_non_replayable_content_are_not_retried` | `response:503 (server-attempts=1)` | `exception:HttpRequestException (server-attempts=1)` | **DIFFERENCE (documented)** |
| 24 | `replay-bufferable-content` — `Bufferable_request_content_is_safely_replayed_on_retry` | `response:200,bodies:payload,payload (server-attempts=2)` | `response:200,bodies:payload,payload (server-attempts=2)` | MATCH |

The raw-TCP scenarios' server counts include the transport's own transparent connection
retries: when a **replayable** request's connection is aborted before a response,
`SocketsHttpHandler` retries it on up to 3 further connections before surfacing the
failure (4 accepted connections per aborted GET; a non-replayable POST control opens
exactly 1 — probed on this runtime). Scenario 4's `server-attempts=5` is the four aborted
connections of the first resilience attempt — the transport's entire transparent-retry
budget, whose exhaustion is what surfaces the connection failure to the resilience layer —
plus the fifth connection, on which the resilience retry receives the `200`: the recovery
is the resilience retry itself (with it doing nothing the call would fail with
`HttpRequestException` after the four aborted connections, so the scenario would not
pass), and scenario 7's 3 resilience attempts therefore account for 12 accepted
connections on both sides.

The two documented differences:

- **`no-retry-non-replayable`** — the fork's deliberate no-retry safety gate for
  non-replayable request bodies (divergence 5): the WantsACracker standard handler never
  retries a request whose content cannot be replayed (here a non-seekable
  `StreamContent`), so the original `503` surfaces after the single attempt; the 8.4.2
  reference composes the retry strategy unconditionally, its retry's second attempt
  fails with `HttpRequestException` (the request content cannot be sent twice), and that
  exception — not the `503` — surfaces. Both sides make exactly one server attempt.
- **`rate-limiter-queue-overload-rejection`** — the overload-rejection exception type
  differs: the 8.4.2 reference throws `RateLimiterRejectedException` (Polly.Core; derives
  from `ExecutionRejectedException`, i.e. a non-cancellation exception whose message does
  not name the queue), while the preview rejects the full queue with an
  `OperationCanceledException` whose message identifies the full queue (core
  `RateLimiterResilienceStrategy`). Both sides reject after exactly one server attempt,
  and both keep the rejection distinct from a plain caller cancellation — the sibling
  `rate-limiter-queue-cancellation` scenario MATCHes on the caller token.

### Known limitations of the seam-level proof

The scenarios prove behaviour at the **seam** (a named `HttpClient` through
`AddStandardResilienceHandler()`), which is what the migration packages expose; a few
core facts are therefore proven in their seam-level form rather than the standalone
handler's form:

- **(a) Connection-failure shape** — the core fact `Retries_on_transient_http_request_exception`
  injects a bare `HttpRequestException` through a scripted inner handler; at this seam the
  failure a client actually observes is a **connection abort**, so scenarios 4 and 7 run on
  a raw-TCP loopback server that closes the connection without reading the request or
  answering. Leaving the request unread (in flight) is what makes the abort reliable: the
  client surfaces it immediately as `HttpRequestException`, whereas a connection that was
  fully read first and then closed is not surfaced until the client's own timeout. The
  transport's transparent connection retry (4 accepted connections per aborted replayable
  GET) is exhausted before the failure reaches the resilience layer, so scenario 4's
  recovery is a resilience retry on the fifth accepted connection and scenario 7 exhausts
  the resilience budget on the abort (3 attempts × 4 connections = 12).
- **(b) Options-validation divergence** — the 8.4.2 reference's options validation rejects
  `Retry.MaxRetryAttempts = 0` (the preview allows it). Where a core fact uses `0`, the
  seam uses `1`, the lowest value both sides accept (scenarios 10, 13, 14 and the shared
  circuit-breaker calibration); the proven behaviour is independent of the budget's exact
  value.
- **(c) Cancellation exception type** — the core standalone `StandardResilienceHandler`
  normalizes caller cancellation to a plain `OperationCanceledException` (its behavioural
  tests assert the exact type); the seam surfaces the **raw BCL `TaskCanceledException`**
  on both sides instead. The facts proven at the seam are the load-bearing ones: the
  cancellation is cancellation-aware (no second attempt starts — scenario 8), is never
  reported as a resilience timeout (scenario 13), and surfaces **with the caller's token**,
  which distinguishes queue cancellation from the overload rejection (scenario 21).
- **(d) Retry-storm attempt count** — scenario 12's exact server-attempt count varies with
  the exponential-backoff jitter, so the expectation is the inclusive band 4–6 on **both**
  sides (both sides falling in the band is a MATCH); the load-bearing facts — the client
  timeout is infinite at the seam, and the resilience total timeout, not the client
  timeout, ends the storm — hold exactly on both sides.

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

## Deterministic-pack check (preview-path step 6, first slice, divergence 13)

`run-deterministic-pack.sh` answers two questions (release-guard stage 7):

1. **Fork local-pack determinism** — two consecutive packs of each of the two
   renamed src projects, from the same clean state (the two projects'
   `artifacts/bin|obj` removed between rounds; repo build flow; repo-local
   pinned SDK), are identical **after the documented normalization** — for
   each project both the main nupkg and the legacy `.symbols.nupkg` (the
   previously observed drift `4bbb69fd…` vs `3c55df22…` was closed by this
   check).
2. **Core → fork feed handoff** — a fresh clone of the core repository at the
   pinned core commit (`3da5b8c`, a scratch path, never the sibling
   checkout), built and packed with the repo-local pinned SDK, is identical
   after the same normalization to the committed feed nupkg
   (`eng/local-packages/WantsACracker.0.1.0-preview.1.nupkg`, sha256
   `6df716e8…`) — the previously observed cross-checkout variance
   (`06fa2342…` vs `99a2c2e0…`, 70 changed netstandard DLL bytes) is closed:
   its cause was the absolute PDB paths embedded in the DLLs' debug
   directories (plus the SourceLink document map and the NuGet-cache content
   paths, see below), which the core normalizes at its source.

### Normalization strategy (checked in; the same strategy applies to the fork
packs and the core pack)

- **Deterministic build content at the source:** the portable-PDB identity is
  a content hash, not a random GUID. The fork already sets `Deterministic`
  unconditionally (upstream `Directory.Build.props`, untouched); the core
  sets it explicitly and maps debug paths to the canonical prefix
  `WantsACracker` (PathMap), so the committed feed nupkg is reproducible
  from **any** checkout of the pinned commit.
- **Check-time zip normalization:** source-level timestamp normalization is
  impossible on the pinned SDK 10.0.111 (`global.json`; an upstream pin this
  fork must not change) — its `NuGet.Build.Tasks.Pack` targets pass only
  `Deterministic`, not `DeterministicTimestamp`, so `SOURCE_DATE_EPOCH` is
  honored by no SDK pack path on this toolchain. The check therefore rebuilds
  each nupkg canonically — sorted entries, fixed date_time
  (2023-11-14T22:13:20Z = `SOURCE_DATE_EPOCH` 1700000000, the
  reproducible-builds convention), stable attributes, canonical
  `nuget.psmdcp` name, canonical `_rels/.rels` Target/Id for that entry —
  and asserts byte-identity of the normalized packages. On SDKs whose pack
  targets do honor the timestamp (e.g. 10.0.400, which also names the
  psmdcp deterministically) the same check behaves identically.
- **Variance accounting:** for each compared pair the check additionally
  unpacks the raw nupkgs and asserts the raw byte variance is limited to
  exactly the documented fields — identical file sets; the only file allowed
  to differ is `_rels/.rels`, and only on the psmdcp relationship line (its
  Target is the GUID filename, its Id is random, on pack targets that roll
  them); everything else — including the psmdcp content — is
  byte-identical. The zip entry timestamps are the third documented field
  (not visible in unpacked content; they differ by construction on 10.0.111).

The fork packs are asserted within this checkout: their remaining
machine-specific bytes are the absolute `artifacts/` debug paths, constant
within a checkout; cross-checkout byte-identity of the fork packs would
require changing upstream build files, which the narrow-divergence rule
forbids.

### Two core-side findings neutralized in the core's `Directory.Build.props`
(core commits `10ddbad` + `3da5b8c`, found by building sibling vs
fresh-clone checkouts with separate `NUGET_PACKAGES`)

1. The .NET 10 SDK auto-imports `Microsoft.SourceLink.Common` (the
   repository has git metadata) and embeds a SourceLink document map into
   every PDB whose keys are the **absolute checkout paths**; PathMap does
   not rewrite it, so the PDB content hash — and the PE checksum / debug
   identity it feeds — differed per checkout. The core sets
   `EnableSourceLink=false` at the source until the follow-up CI plumbing
   makes SourceLink reproducible (the main nupkg ships no PDB, so nothing is
   lost at the package level today).
2. The netstandard2.0 build compiles the `Nullable` package's contentFiles
   `.cs` straight from the package cache, so the cache path entered the PDB
   document list and identity. The core's PathMap gains a conditional second
   entry mapping `$(NUGET_PACKAGES)` to the canonical prefix `nuget` (the
   checks and the feed pack always set `NUGET_PACKAGES`).

### Result (2026-09-06, from the checked-in state)

`smoke/run-deterministic-pack.sh` → exit 0, `DET-PACK PASS`: all four fork
nupkg pairs byte-identical after normalization and the fresh core pack
(identical normalized sha256 to the committed feed). The core's own
`ci/run-deterministic-pack.sh` (same strategy, same gate) → exit 0
(normalized sha256 `e658a798…`). A cross-checkout build of core
`3da5b8c` (sibling vs fresh scratch clone, separate caches) produced
byte-identical DLL+PDB for `netstandard2.0`, `net8.0` and `net10.0`.

### How to run

```sh
smoke/run-deterministic-pack.sh
```

No arguments. Requirements: `bash`, `python3`, `unzip`, the repo-local
pinned SDK (stages 1–2 run the repo build flow, which provides
`.dotnet/dotnet`), and network access to the core repository for the stage-4
fresh clone (hermetic once in the cache). The script exits non-zero on any
failure at any stage.

## Layout

- `run-clean-consumer.sh` — the single checked-in command.
- `clean-consumer/consumer.csproj`, `clean-consumer/Program.cs` — the consumer app source. The script copies them into the temporary workspace and builds them **out-of-tree** (no repo `Directory.Build.props` inheritance, no repository solution membership), so building them never creates build output inside the repository. The `nuget.config` pinning the temporary feed is generated by the script in the workspace (the feed path is run-specific).
- `run-differential.sh` — the differential harness command (above).
- `differential/Program.cs` — the dual-side scenario source (marker pairs; the full 24-scenario P0 set — today exactly one marker pair, the options-type alias).
- `differential/wantsacracker.csproj`, `differential/polly.csproj` — the two out-of-tree app project files (package references only: the three preview packages / `Microsoft.Extensions.Http.Resilience 10.9.0`).
- `run-deterministic-pack.sh` — the deterministic-pack check (above; release-guard stage 7).
