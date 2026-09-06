#!/usr/bin/env bash
#
# WantsACracker differential compatibility harness (preview-path step 5; see smoke/README.md).
#
# Drives the full independently authored P0 HTTP scenario set (all 24 behavioural facts of
# the standard-handler surface) through BOTH sides of the source-level compatibility claim,
# at the shared public seam (a named HttpClient wired with AddStandardResilienceHandler()),
# and fails on any outcome that is not the expected one for its side:
#
#   * the WantsACracker side — the three 0.1.0-preview.1 packages (the committed core feed
#     nupkg, sha256-verified, + fresh packs of the two fork projects), restored from an empty
#     isolated NUGET_PACKAGES cache against that feed plus nuget.org (published siblings only;
#     no Polly may resolve or download);
#   * the Polly 8.4.2 side — Microsoft.Extensions.Http.Resilience 10.9.0 from nuget.org (the
#     one non-local package fetch; hermetic once in the cache). 10.9.0 is the published sibling
#     of the fork's 10.10.0-dev upstream baseline; it resolves Microsoft.Extensions.Resilience
#     10.9.0, which pins exactly Polly.Core/Polly.Extensions/Polly.RateLimiting 8.4.2 — the
#     compatibility surface this harness proves against. No 8.4.x version of the package
#     exists (8.4.0/8.5.0 resolve Polly 8.3.0), so the script asserts the resolved graph
#     carries exactly Polly 8.4.2. See smoke/README.md.
#
# The scenario source is a single checked-in file (smoke/differential/Program.cs) that encodes
# both sides: every line that legitimately differs (genuine surface differences, each
# documented in smoke/README.md) appears as a paired marker block (an active line marked with
# the trailing "// @@WAC@@" and its 8.4.2 counterpart as a "//@@POLLY@@" comment). The WantsACracker
# build compiles the file as-is; the Polly build removes the @@WAC@@ lines and uncomments the
# @@POLLY@@ lines, and the script verifies the transformation is exactly that pair swap.
# All scenarios are fully offline (in-process loopback — an HttpListener, or the raw-TCP
# server for the two connection-abort scenarios).
#
# Per scenario the harness records: matching behaviour (MATCH), or a documented difference
# (DIFFERENCE — the scenario must be on the KNOWN_DIFFERENCES list below, with the reason).
# One scenario (the retry-storm total timeout) carries a band expectation for the
# server-attempt count — the count varies with the exponential-backoff jitter — and both
# sides falling in the band is a MATCH (the raw lines may then differ only in the count).
#
# Stages, in order (any failure aborts with a non-zero exit code):
#
#   1. Build and pack the two renamed src projects at 0.1.0-preview.1
#      (repo build flow, repo-local pinned SDK).
#   2. Collect EXACTLY the three preview nupkgs into a temporary local feed.
#   3. WantsACracker side: copy the scenario sources to a temp workspace, restore from the
#      empty isolated cache, assert no Polly in the resolved graph, build, run.
#   4. Polly 8.4.2 side: same, with the marker-pair transformation and nuget.org only.
#   5. Compare each per-scenario line against the expected outcome for its side; print the
#      per-scenario table (MATCH / DIFFERENCE) and the verdict.
#
# All intermediate state lives in a mktemp directory removed on exit; both scenario apps are
# built out-of-tree, so no tracked build output is left behind (pack output goes to the
# gitignored artifacts/ tree).
#
# Entry point (locally; no arguments):
#   smoke/run-differential.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

version="0.1.0-preview.1"
polly_version="8.4.2"
ref_package_version="10.9.0"  # Microsoft.Extensions.Http.Resilience -> Polly $polly_version (see header)
core_nupkg_sha256="6df716e82896fc6eec518859ee85936a5e526749fba320d02916f52d09318234"

fail() { echo "DIFF FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

work="$(mktemp -d "${TMPDIR:-/tmp}/wantsacracker-diff.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- 1. Build + pack the two renamed src projects ----------------------------

step "Build the two renamed src projects (Release)"
./build.sh -restore -build -c Release -projects \
  src/Libraries/Microsoft.Extensions.Resilience/WantsACracker.Extensions.Resilience.csproj \
  || fail "build.sh (WantsACracker.Extensions.Resilience) failed"
./build.sh -restore -build -c Release -projects \
  src/Libraries/Microsoft.Extensions.Http.Resilience/WantsACracker.Extensions.Http.Resilience.csproj \
  || fail "build.sh (WantsACracker.Extensions.Http.Resilience) failed"

dotnet="$repo_root/.dotnet/dotnet"
[ -x "$dotnet" ] || fail "repo-local SDK not found at .dotnet/dotnet after the repo build flow"

step "Pack the two renamed src projects"
"$dotnet" pack src/Libraries/Microsoft.Extensions.Resilience/WantsACracker.Extensions.Resilience.csproj -c Release --nologo \
  || fail "dotnet pack (WantsACracker.Extensions.Resilience) failed"
"$dotnet" pack src/Libraries/Microsoft.Extensions.Http.Resilience/WantsACracker.Extensions.Http.Resilience.csproj -c Release --nologo \
  || fail "dotnet pack (WantsACracker.Extensions.Http.Resilience) failed"

# --- 2. Assemble a feed with exactly the three preview nupkgs ----------------

feed="$work/feed"
mkdir -p "$feed"

[ -f "$repo_root/eng/local-packages/WantsACracker.$version.nupkg" ] \
  || fail "committed core nupkg eng/local-packages/WantsACracker.$version.nupkg is missing"
actual_sha="$(sha256sum "$repo_root/eng/local-packages/WantsACracker.$version.nupkg" | cut -d' ' -f1)"
[ "$actual_sha" = "$core_nupkg_sha256" ] \
  || fail "committed core nupkg sha256 mismatch: $actual_sha != $core_nupkg_sha256"

cp "$repo_root/eng/local-packages/WantsACracker.$version.nupkg" "$feed/" \
  || fail "copying the committed core nupkg failed"
cp "$repo_root/artifacts/packages/Release/Shipping/WantsACracker.Extensions.Resilience.$version.nupkg" "$feed/" \
  || fail "fresh pack WantsACracker.Extensions.Resilience.$version.nupkg is missing from artifacts/packages/Release/Shipping"
cp "$repo_root/artifacts/packages/Release/Shipping/WantsACracker.Extensions.Http.Resilience.$version.nupkg" "$feed/" \
  || fail "fresh pack WantsACracker.Extensions.Http.Resilience.$version.nupkg is missing from artifacts/packages/Release/Shipping"

actual_feed="$(ls "$feed" | sort)"
expected_feed="$(printf '%s\n' \
  "WantsACracker.$version.nupkg" \
  "WantsACracker.Extensions.Http.Resilience.$version.nupkg" \
  "WantsACracker.Extensions.Resilience.$version.nupkg" | sort)"
[ "$actual_feed" = "$expected_feed" ] \
  || fail "the feed does not contain exactly the three preview nupkgs: $actual_feed"

# --- 3. WantsACracker side: restore, assert graph, build, run ----------------

wac="$work/wac"
mkdir -p "$wac"
cp "$script_dir/differential/Program.cs" "$wac/"
cp "$script_dir/differential/wantsacracker.csproj" "$wac/differential.csproj"
cat > "$wac/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="wants-a-cracker-preview-feed" value="$feed" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF

wac_cache="$work/packages-wac"
mkdir -p "$wac_cache"
export NUGET_PACKAGES="$wac_cache"

step "WantsACracker side: restore the scenario app (empty isolated NUGET_PACKAGES)"
"$dotnet" restore "$wac/differential.csproj" --nologo || fail "WantsACracker side restore failed"

wac_assets="$wac/obj/project.assets.json"
[ -f "$wac_assets" ] || fail "project.assets.json missing after the WantsACracker side restore"
if grep -qi '"polly' "$wac_assets"; then
  fail "a Polly package resolved in the WantsACracker side graph: $(grep -oi '"polly[^"]*"' "$wac_assets" | sort -u | tr '\n' ' ')"
fi

step "WantsACracker side: build and run the scenarios"
"$dotnet" build "$wac/differential.csproj" -c Release --no-restore --nologo \
  || fail "WantsACracker side build failed"
"$dotnet" "$wac/bin/Release/net8.0/differential.dll" > "$work/out-wac.txt" \
  || fail "the WantsACracker side scenario app exited non-zero"

if find "$wac_cache" -maxdepth 1 -type d -iname 'polly*' | grep -q .; then
  fail "a Polly package was downloaded into the WantsACracker side cache"
fi

# --- 4. Polly 8.4.2 side: substitute the alias line, restore, build, run -----

polly="$work/polly"
mkdir -p "$polly"
# Transform the single scenario source into the 8.4.2 side: remove every active WantsACracker
# line (marked with the trailing "// @@WAC@@") and uncomment every "//@@POLLY@@" line in
# place. The marker pairs encode exactly the genuine surface differences (documented in
# smoke/README.md); everything else is byte-identical between the two builds.
sed -e '/\/\/ @@WAC@@$/d' -e 's|^\([[:space:]]*\)//@@POLLY@@ |\1|' \
  "$script_dir/differential/Program.cs" > "$polly/Program.cs"
wac_marker_count="$(grep -c '// @@WAC@@$' "$script_dir/differential/Program.cs" || true)"
polly_marker_count="$(grep -c '//@@POLLY@@ ' "$script_dir/differential/Program.cs" || true)"
[ "$wac_marker_count" -eq "$polly_marker_count" ] && [ "$wac_marker_count" -gt 0 ] \
  || fail "the @@WAC@@/@POLLY@@ marker lines are not paired ($wac_marker_count vs $polly_marker_count)"
if grep -q '@@' "$polly/Program.cs"; then
  fail "marker lines remain in the transformed 8.4.2 scenario source"
fi
# The transformation must be EXACTLY the pair swap: each marker pair occupies two lines in the
# checked-in source (the active WAC line + its POLLY comment line) and one line in the
# transformed file. Because no line within a marker block equals any other line in either
# file, the plain diff between the two files shows exactly three diffed lines per pair
# (the WAC line and the POLLY comment line removed, the uncommented 8.4.2 line added) —
# 3 * <pair count> in total, no matter how diff aligns a multi-line block — and nothing else.
# Note: diff exits 1 when the files differ (which they always do here), so capture its status
# instead of letting set -e + pipefail abort the script before the count is checked.
diff_status=0
diff_report="$(diff "$script_dir/differential/Program.cs" "$polly/Program.cs" || diff_status=$?)"
[ "$diff_status" -le 1 ] \
  || fail "diff between the scenario sources failed unexpectedly (exit $diff_status)"
diffed_lines="$(printf '%s\n' "$diff_report" | grep -c '^[<>]' || true)"
[ "$diffed_lines" -eq $((wac_marker_count * 3)) ] \
  || fail "the 8.4.2 side transformation changed more than the marked lines ($diffed_lines diffed lines, expected $((wac_marker_count * 3)))"
cp "$script_dir/differential/polly.csproj" "$polly/differential.csproj"
cat > "$polly/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF

polly_cache="$work/packages-polly"
mkdir -p "$polly_cache"
export NUGET_PACKAGES="$polly_cache"

step "Polly $polly_version side: restore, build and run the scenarios (reference package $ref_package_version)"
"$dotnet" restore "$polly/differential.csproj" --nologo || fail "Polly side restore failed"

# The reference side must run on exactly Polly 8.4.2 (the compatibility surface), not on a
# higher Polly line a newer reference package might pull in.
polly_assets="$polly/obj/project.assets.json"
[ -f "$polly_assets" ] || fail "project.assets.json missing after the Polly side restore"
for p in "Polly.Core" "Polly.Extensions" "Polly.RateLimiting"; do
  v="$(grep -o "\"$p/[^\"]*\"" "$polly_assets" | head -n 1 | tr -d '"' | cut -d/ -f2)"
  [ "$v" = "$polly_version" ] \
    || fail "$p resolved to '${v:-nothing}' on the reference side, expected exactly $polly_version"
done

"$dotnet" build "$polly/differential.csproj" -c Release --no-restore --nologo \
  || fail "Polly side build failed"
"$dotnet" "$polly/bin/Release/net8.0/differential.dll" > "$work/out-polly.txt" \
  || fail "the Polly side scenario app exited non-zero"

# --- 5. Compare the per-scenario outcomes against the expectations -----------

step "Per-scenario results"

# Expected outcome per side, per scenario. The array lists the scenarios in the order
# smoke/differential/Program.cs runs them (one observed line per scenario, in order). A
# scenario present in known_difference_reason must differ between the sides, with the
# reason as documented in smoke/README.md; every other scenario must produce the identical
# line on both sides. The final "(server-attempts=...)" clause is an exact count, except
# where an inclusive "(server-attempts:A-B)" band is expected (side_ok).
scenarios=(
  "retry-503-then-success"
  "retry-408-then-success"
  "retry-429-retry-after"
  "retry-connection-abort-then-success"
  "no-retry-404"
  "retry-exhaustion-last-response"
  "retry-exhaustion-last-error"
  "retry-cancellation-during-backoff"
  "attempt-timeout-then-retry"
  "attempt-timeout-rejects"
  "total-timeout-fails"
  "total-timeout-dominates-client-timeout"
  "caller-cancellation-not-timeout"
  "circuit-breaker-opens"
  "circuit-breaker-fails-fast"
  "circuit-breaker-half-open-recovery"
  "circuit-breaker-successful-probe-closes"
  "circuit-breaker-below-ratio-stays-closed"
  "rate-limiter-queues-beyond-limit"
  "rate-limiter-queue-overload-rejection"
  "rate-limiter-queue-cancellation"
  "rate-limiter-permits-no-leak"
  "no-retry-non-replayable"
  "replay-bufferable-content"
)

expected() {
  # expected <scenario> <wac|polly>
  # NB: case patterns must stay unquoted — a quoted * or ? becomes a literal.
  case "$1:$2" in
    retry-503-then-success:*)
      echo "$1: response:200 (server-attempts=2)" ;;
    retry-408-then-success:*)
      echo "$1: response:200 (server-attempts=2)" ;;
    retry-429-retry-after:*)
      # ~1 s observed wait: the base backoff is 50 ms, so it can only come from the
      # Retry-After header (honoured by default on both sides).
      echo "$1: response:200,honoured-retry-after:yes (server-attempts=2)" ;;
    retry-connection-abort-then-success:*)
      # Identical on both sides: every connection of the first resilience attempt is
      # aborted (the raw-TCP server closes each without reading or answering), and
      # SocketsHttpHandler transparently retries an aborted replayable connection on up
      # to 3 further connections before surfacing the failure — 4 accepted connections
      # per aborted GET (the same mechanism the retry-exhaustion-last-error count below
      # reflects). The four aborted connections exhaust the transport budget of the
      # first resilience attempt, so the connection failure surfaces to the resilience
      # layer, which retries: its fifth accepted connection receives the 200. The
      # recovery is the resilience retry itself — with it doing nothing the call would
      # fail with HttpRequestException after the four aborted connections.
      echo "$1: response:200 (server-attempts=5)" ;;
    no-retry-404:*)
      echo "$1: response:404 (server-attempts=1)" ;;
    retry-exhaustion-last-response:*)
      echo "$1: response:503 (server-attempts=3)" ;;
    retry-exhaustion-last-error:*)
      # Identical on both sides: every attempt's connection is aborted (raw-TCP transport),
      # the budget is exhausted, and the last error (the connection failure) surfaces.
      # The count is 12, not 3: each of the 3 resilience attempts is a replayable GET,
      # and SocketsHttpHandler transparently retries an aborted connection on up to 3
      # further connections before surfacing the failure — 4 accepted connections per
      # attempt (a non-replayable POST control opens exactly 1; probed on this runtime),
      # so 3 attempts x 4 connections = 12.
      echo "$1: exception:HttpRequestException (server-attempts=12)" ;;
    retry-cancellation-during-backoff:*)
      # Raw seam behaviour: both sides surface the BCL TaskCanceledException from the
      # cancellation-aware backoff delay (the standalone WantsACracker handler normalizes
      # it to a plain OperationCanceledException, which this seam does not — documented
      # in smoke/README.md). No second attempt starts on either side.
      echo "$1: exception:TaskCanceledException (server-attempts=1)" ;;
    attempt-timeout-then-retry:*)
      echo "$1: response:200 (server-attempts=2)" ;;
    attempt-timeout-rejects:*)
      # Identical on both sides: the timeout rejection is transient and retried once
      # (the reference's options validation rejects MaxRetryAttempts = 0 — a documented
      # validation divergence, the preview allows it — so the seam uses 1), then the
      # dedicated resilience timeout exception surfaces.
      echo "$1: exception:TimeoutRejectedException (server-attempts=2)" ;;
    total-timeout-fails:*)
      echo "$1: exception:TimeoutRejectedException (server-attempts=2)" ;;
    total-timeout-dominates-client-timeout:*)
      # Both sides set HttpClient.Timeout to infinite at registration (the client-timeout
      # token), and the resilience total timeout is the only timeout in force. The exact
      # attempt count varies with the exponential-backoff jitter, so both sides must fall
      # in the inclusive band.
      echo "$1: exception:TimeoutRejectedException,client-timeout:infinite,total-timeout-dominated:yes (server-attempts:4-6)" ;;
    caller-cancellation-not-timeout:*)
      # Identical on both sides: the caller's own cancellation surfaces (raw BCL
      # TaskCanceledException at this seam, never the resilience timeout exception).
      echo "$1: exception:TaskCanceledException (server-attempts=1)" ;;
    circuit-breaker-opens:*)
      # Identical on both sides: with retry=1 the breaker opens within the first send
      # (after the second failed attempt), so one 503 is followed by four breaker-open
      # rejections. The 8.4.2 rejection exception is Polly.Core's BrokenCircuitException
      # (CircuitBreakerOpenException is the legacy v7 name), the same type name the
      # preview throws.
      echo "$1: response:503,exception:BrokenCircuitException,exception:BrokenCircuitException,exception:BrokenCircuitException,exception:BrokenCircuitException (server-attempts=2)" ;;
    circuit-breaker-fails-fast:*)
      # Identical on both sides: five failed attempts (two per send) cross the
      # 5 / 0.5 threshold on the third send's first attempt; that send's retry and the
      # three following sends fail fast without reaching the server.
      echo "$1: response:503,response:503,exception:BrokenCircuitException,exception:BrokenCircuitException,exception:BrokenCircuitException,exception:BrokenCircuitException (server-attempts=5)" ;;
    circuit-breaker-half-open-recovery:*)
      # Identical on both sides: the breaker opens on the third send's first attempt;
      # sends three (retry) and four fail fast, and after the break duration the
      # half-open probe succeeds and the circuit recovers.
      echo "$1: response:503,response:503,exception:BrokenCircuitException,exception:BrokenCircuitException,response:200 (server-attempts=6)" ;;
    circuit-breaker-successful-probe-closes:*)
      # Identical on both sides: the successful half-open probe closes the circuit —
      # the following burst of six requests all reach the server.
      echo "$1: response:503,response:503,exception:BrokenCircuitException,exception:BrokenCircuitException,exception:BrokenCircuitException,response:200,response:200,response:200,response:200,response:200,response:200,response:200 (server-attempts=12)" ;;
    circuit-breaker-below-ratio-stays-closed:*)
      # Identical on both sides: two failures out of seven executions (0.29) stay below
      # the 0.5 ratio — the circuit never opens and every send reaches the server.
      echo "$1: response:503,response:200,response:200,response:200,response:200,response:200 (server-attempts=7)" ;;
    rate-limiter-queues-beyond-limit:*)
      echo "$1: response:200,response:200 (server-attempts=2)" ;;
    rate-limiter-queue-overload-rejection:wac)
      # Documented difference (see known_difference_reason): the preview rejects the full
      # queue with a cancellation that names the queue; the 8.4.2 reference throws its
      # dedicated non-cancellation rejection exception.
      echo "$1: exception:OperationCanceledException,queue-rejection:yes,response:200 (server-attempts=1)" ;;
    rate-limiter-queue-overload-rejection:polly)
      echo "$1: exception:RateLimiterRejectedException,queue-rejection:no,response:200 (server-attempts=1)" ;;
    rate-limiter-queue-cancellation:*)
      # Identical on both sides: both pass the caller's token to the BCL ConcurrencyLimiter,
      # so the queue cancellation surfaces with the caller's token (distinguishing it from
      # the overload rejection).
      echo "$1: exception:TaskCanceledException,caller-token:yes,response:200 (server-attempts=1)" ;;
    rate-limiter-permits-no-leak:*)
      echo "$1: response:400,response:400,response:400,response:200,fast-recovery:yes (server-attempts=4)" ;;
    no-retry-non-replayable:wac)
      echo "$1: response:503 (server-attempts=1)" ;;
    no-retry-non-replayable:polly)
      echo "$1: exception:HttpRequestException (server-attempts=1)" ;;
    replay-bufferable-content:*)
      # Identical on both sides: bufferable content may be replayed — the retried attempt
      # re-sends the identical body, which the server observes on both attempts.
      echo "$1: response:200,bodies:payload,payload (server-attempts=2)" ;;
    *)
      fail "no expectation defined for scenario '$1' (side '$2')" ;;
  esac
}

# side_ok <observed-line> <expected-line>: exact line match, or — when the expectation
# carries an inclusive "(server-attempts:A-B)" band — an exact match of everything before
# the attempts clause plus the observed count inside the band.
side_ok() {
  local obs="$1" exp="$2"
  local obs_body obs_n exp_body exp_n lo hi
  case "$obs" in
    *" (server-attempts="*) ;;
    *) fail "observed line carries no (server-attempts=<n>) clause: $obs" ;;
  esac
  obs_body="${obs% (server-attempts=*}"
  obs_n="${obs##*(server-attempts=}"
  obs_n="${obs_n%)}"
  [[ "$obs_n" =~ ^[0-9]+$ ]] || fail "observed server-attempts is not an integer: $obs"
  case "$exp" in
    *" (server-attempts:"*)
      exp_body="${exp% (server-attempts:*}"
      exp_n="${exp##*(server-attempts:}"
      exp_n="${exp_n%)}"
      [[ "$exp_n" == *-* && "${exp_n%-*}" =~ ^[0-9]+$ && "${exp_n#*-}" =~ ^[0-9]+$ ]] \
        || fail "band expectation is malformed (expected (server-attempts:A-B)): $exp"
      lo="${exp_n%-*}"
      hi="${exp_n#*-}"
      [ "$obs_body" = "$exp_body" ] && [ "$obs_n" -ge "$lo" ] && [ "$obs_n" -le "$hi" ]
      ;;
    *" (server-attempts="*)
      [ "$obs" = "$exp" ]
      ;;
    *)
      fail "expected line carries no (server-attempts=...) clause: $exp"
      ;;
  esac
}

known_difference_reason() {
  case "$1" in
    "no-retry-non-replayable")
      echo "documented difference: the WantsACracker standard handler never retries non-replayable request bodies (fork UPSTREAM.md divergence 5, fork README policy), so the original 503 surfaces after the single attempt; the 8.4.2 reference composes the retry strategy unconditionally, and its retry's second attempt fails with HttpRequestException (the request content cannot be sent twice), so that exception — not the 503 — surfaces. Same single server attempt on both sides" ;;
    "rate-limiter-queue-overload-rejection")
      echo "documented difference: the overload rejection type differs — the 8.4.2 reference throws RateLimiterRejectedException (Polly.Core; derives from ExecutionRejectedException, i.e. a non-cancellation exception whose message does not name the queue), while the preview rejects the full queue with an OperationCanceledException whose message identifies the full queue (core RateLimiterResilienceStrategy). Both sides reject after exactly one server attempt, and both keep the rejection distinct from a plain caller cancellation (the sibling queue-cancellation scenario MATCHes on the caller token)" ;;
    *)
      echo "" ;;
  esac
}

[ "$(wc -l < "$work/out-wac.txt")" -eq "${#scenarios[@]}" ] \
  || fail "the WantsACracker side produced $(wc -l < "$work/out-wac.txt") scenario lines, expected ${#scenarios[@]}"
[ "$(wc -l < "$work/out-polly.txt")" -eq "${#scenarios[@]}" ] \
  || fail "the Polly side produced $(wc -l < "$work/out-polly.txt") scenario lines, expected ${#scenarios[@]}"

wac_lines="$(cat "$work/out-wac.txt")"
polly_lines="$(cat "$work/out-polly.txt")"

overall="PASS"
printf '%-42s  %-44s  %-44s  %s\n' "scenario" "wantsacracker (observed)" "polly $polly_version (observed)" "result"
for i in "${!scenarios[@]}"; do
  name="${scenarios[$i]}"
  wac_obs="$(sed -n "$((i + 1))p" "$work/out-wac.txt")"
  polly_obs="$(sed -n "$((i + 1))p" "$work/out-polly.txt")"
  wac_exp="$(expected "$name" "wac")"
  polly_exp="$(expected "$name" "polly")"

  status=""
  if ! side_ok "$wac_obs" "$wac_exp"; then
    status="MISMATCH (WantsACracker)"
    overall="FAIL"
  elif ! side_ok "$polly_obs" "$polly_exp"; then
    status="MISMATCH (Polly)"
    overall="FAIL"
  elif [ "$wac_obs" = "$polly_obs" ]; then
    status="MATCH"
  elif [[ "$wac_exp" == *" (server-attempts:"* ]]; then
    # Both sides met their (band) expectation; the raw lines then differ only in the
    # per-side attempt count the band tolerates — matching behaviour.
    status="MATCH"
  else
    reason="$(known_difference_reason "$name")"
    if [ -z "$reason" ]; then
      status="UNEXPECTED DIFFERENCE"
      overall="FAIL"
    else
      status="DIFFERENCE"
    fi
  fi

  if [ "$status" = "DIFFERENCE" ]; then
    printf '%-42s  %-44s  %-44s  %s\n' "$name" "$wac_obs" "$polly_obs" "$status"
    printf '%-42s  %s\n' "" "$(known_difference_reason "$name")"
  else
    printf '%-42s  %-44s  %-44s  %s\n' "$name" "$wac_obs" "$polly_obs" "$status"
  fi
done

if [ "$overall" != "PASS" ]; then
  echo >&2
  fail "one or more scenarios did not produce their expected outcome"
fi

echo
echo "DIFF PASS: all ${#scenarios[@]} scenarios produced their expected outcome at the shared AddStandardResilienceHandler() seam (matching behaviour, or the recorded difference)."
