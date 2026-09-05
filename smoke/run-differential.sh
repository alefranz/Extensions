#!/usr/bin/env bash
#
# WantsACracker differential compatibility harness (preview-path step 5; see smoke/README.md).
#
# Drives a representative subset of the independently authored P0 HTTP scenarios through BOTH
# sides of the source-level compatibility claim, at the shared public seam (a named HttpClient
# wired with AddStandardResilienceHandler()), and fails on any outcome that is not the expected
# one for its side:
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
# All scenarios are fully offline (in-process loopback HttpListener).
#
# Per scenario the harness records: matching behaviour (MATCH), or a documented difference
# (DIFFERENCE — the scenario must be on the KNOWN_DIFFERENCES list below, with the reason).
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
core_nupkg_sha256="99a2c2e08248fbb301751569b696c57bf0549a3ceef6c3913856bfd157935fc8"

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

# Expected outcome per side, per scenario. A scenario present in KNOWN_DIFFERENCES must
# differ between the sides, with the reason as documented in smoke/README.md; every other
# scenario must produce the identical line on both sides.
scenarios=(
  "retry-503-then-success"
  "attempt-timeout-then-retry"
  "total-timeout-fails"
  "circuit-breaker-opens"
  "no-retry-non-replayable"
)

expected() {
  # expected <scenario> <wac|polly>
  # NB: case patterns must stay unquoted — a quoted * or ? becomes a literal.
  case "$1:$2" in
    retry-503-then-success:*)
      echo "$1: response:200 (server-attempts=2)" ;;
    attempt-timeout-then-retry:*)
      echo "$1: response:200 (server-attempts=2)" ;;
    total-timeout-fails:*)
      echo "$1: exception:TimeoutRejectedException (server-attempts=2)" ;;
    circuit-breaker-opens:*)
      # Identical on both sides: with retry=1 the breaker opens within the first send
      # (after the second failed attempt), so one 503 is followed by four breaker-open
      # rejections. The 8.4.2 rejection exception is Polly.Core's BrokenCircuitException
      # (CircuitBreakerOpenException is the legacy v7 name), the same type name the
      # preview throws.
      echo "$1: response:503,exception:BrokenCircuitException,exception:BrokenCircuitException,exception:BrokenCircuitException,exception:BrokenCircuitException (server-attempts=2)" ;;
    no-retry-non-replayable:wac)
      echo "$1: response:503 (server-attempts=1)" ;;
    no-retry-non-replayable:polly)
      echo "$1: exception:HttpRequestException (server-attempts=1)" ;;
    *)
      fail "no expectation defined for scenario '$1' (side '$2')" ;;
  esac
}

known_difference_reason() {
  case "$1" in
    "no-retry-non-replayable")
      echo "documented difference: the WantsACracker standard handler never retries non-replayable request bodies (fork UPSTREAM.md divergence 5, fork README policy), so the original 503 surfaces after the single attempt; the 8.4.2 reference composes the retry strategy unconditionally, and its retry's second attempt fails with HttpRequestException (the request content cannot be sent twice), so that exception — not the 503 — surfaces. Same single server attempt on both sides" ;;
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
printf '%-28s  %-44s  %-44s  %s\n' "scenario" "wantsacracker (observed)" "polly $polly_version (observed)" "result"
for i in "${!scenarios[@]}"; do
  name="${scenarios[$i]}"
  wac_obs="$(sed -n "$((i + 1))p" "$work/out-wac.txt")"
  polly_obs="$(sed -n "$((i + 1))p" "$work/out-polly.txt")"
  wac_exp="$(expected "$name" "wac")"
  polly_exp="$(expected "$name" "polly")"

  status=""
  if [ "$wac_obs" != "$wac_exp" ]; then
    status="MISMATCH (WantsACracker)"
    overall="FAIL"
  elif [ "$polly_obs" != "$polly_exp" ]; then
    status="MISMATCH (Polly)"
    overall="FAIL"
  elif [ "$wac_obs" = "$polly_obs" ]; then
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
    printf '%-28s  %-44s  %-44s  %s\n' "$name" "$wac_obs" "$polly_obs" "$status"
    printf '%-28s  %s\n' "" "$(known_difference_reason "$name")"
  else
    printf '%-28s  %-44s  %-44s  %s\n' "$name" "$wac_obs" "$polly_obs" "$status"
  fi
done

if [ "$overall" != "PASS" ]; then
  echo >&2
  fail "one or more scenarios did not produce their expected outcome"
fi

echo
echo "DIFF PASS: all ${#scenarios[@]} scenarios produced their expected outcome at the shared AddStandardResilienceHandler() seam (matching behaviour, or the recorded difference)."
