#!/usr/bin/env bash
#
# WantsACracker clean-consumer smoke test (preview-path step 3; see smoke/README.md).
#
# Proves that the three 0.1.0-preview.1 packages ship as a consumer-restorable
# set. Stages, in order (any failure aborts with a non-zero exit code):
#
#   1. Build and pack the two renamed src projects at 0.1.0-preview.1
#      (repo build flow, repo-local pinned SDK).
#   2. Collect EXACTLY the three 0.1.0-preview.1 nupkgs (the committed core
#      feed nupkg under eng/local-packages, sha256-verified, + the two fresh
#      fork packs) into a temporary local feed.
#   3. From an empty isolated NUGET_PACKAGES cache, restore and build the
#      minimal consumer app (smoke/clean-consumer/, package references only —
#      never project references) for net8.0 and net10.0 against that feed
#      plus nuget.org.
#   4. Verify the resolved dependency graph: exactly the expected package
#      set at the expected versions, per-TFM asset selection for the three
#      candidate packages, and no Polly package anywhere.
#   5. Run the offline scenarios on both runtimes: 503 -> 200 retry with the
#      exact attempt count (named and typed clients), and a cancelled slow
#      request followed by a successful request (caller cancellation
#      classified and cleaned up). The app exits 0 only if every scenario
#      passes on that runtime.
#
# All intermediate state lives in a mktemp directory removed on exit; the
# consumer is built out-of-tree, so no tracked build output is left behind
# (the pack output goes to the gitignored artifacts/ tree).
#
# Entry point (locally and for the step-4 CI job; no arguments):
#   smoke/run-clean-consumer.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

version="0.1.0-preview.1"
core_nupkg_sha256="ea72b15f486e8365d9e5d00741d2bf2e36410cdf8d0bb5c67815d0104cf597ad"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

work="$(mktemp -d "${TMPDIR:-/tmp}/wantsacracker-smoke.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- 1. Build + pack the two renamed src projects ----------------------------

step "Build the two renamed src projects (Release)"
# One build.sh call per project: the repo wrapper (eng/build.sh) resolves
# -projects with realpath, which does not accept a semicolon-separated list.
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

# --- 3. Restore + build the consumer from an empty isolated cache ------------

consumer="$work/consumer"
mkdir -p "$consumer"
cp "$script_dir/clean-consumer/consumer.csproj" "$consumer/"
cp "$script_dir/clean-consumer/Program.cs" "$consumer/"
cat > "$consumer/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="wants-a-cracker-preview-feed" value="$feed" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF

cache="$work/packages"
mkdir -p "$cache"
export NUGET_PACKAGES="$cache"

step "Restore the consumer (empty isolated NUGET_PACKAGES)"
"$dotnet" restore "$consumer/consumer.csproj" --nologo || fail "consumer restore failed"

# --- 4. Verify the resolved dependency graph ---------------------------------

assets="$consumer/obj/project.assets.json"
[ -f "$assets" ] || fail "project.assets.json missing after restore"

if grep -qi '"polly' "$assets"; then
  fail "a Polly package resolved in the consumer graph: $(grep -oi '"polly[^"]*"' "$assets" | sort -u | tr '\n' ' ')"
fi

resolved="$(grep -oE '"[A-Za-z0-9][A-Za-z0-9._-]*/[0-9][^"]*": \{' "$assets" | sed 's/": {$//' | tr -d '"' | sort -u)"
# The consumer is multi-targeted (net8.0;net10.0), so the expected set is the
# union of the per-TFM closures. The net8.0 closure is the original
# single-target set, unchanged. The net10.0 closure additionally carries the
# shared Microsoft.Extensions.* packages at 10.0.11: NuGet selects each
# package's per-TFM dependency group per target, and the net9.0/net10.0
# groups of the published 10.9.0 siblings (and the fork packages' net10.0
# groups, e.g. Microsoft.Extensions.ObjectPool >= 10.0.11) pull the 10.0.11
# closure. This is a legitimate TFM/version change of the multi-targeting —
# inspected 2026-10-19 (C3) — not a drift of the candidate set: all three
# preview packages stay at 0.1.0-preview.1 and the 10.9.0 siblings are
# unchanged on both targets.
expected_resolved="$(printf '%s\n' \
  "Microsoft.Extensions.AmbientMetadata.Application/10.9.0" \
  "Microsoft.Extensions.Compliance.Abstractions/10.9.0" \
  "Microsoft.Extensions.Configuration/10.0.11" \
  "Microsoft.Extensions.Configuration/8.0.0" \
  "Microsoft.Extensions.Configuration.Abstractions/10.0.11" \
  "Microsoft.Extensions.Configuration.Abstractions/8.0.0" \
  "Microsoft.Extensions.Configuration.Binder/10.0.11" \
  "Microsoft.Extensions.Configuration.Binder/8.0.2" \
  "Microsoft.Extensions.DependencyInjection/10.0.11" \
  "Microsoft.Extensions.DependencyInjection/8.0.1" \
  "Microsoft.Extensions.DependencyInjection.Abstractions/10.0.11" \
  "Microsoft.Extensions.DependencyInjection.Abstractions/8.0.2" \
  "Microsoft.Extensions.DependencyInjection.AutoActivation/10.9.0" \
  "Microsoft.Extensions.Diagnostics/10.0.11" \
  "Microsoft.Extensions.Diagnostics/8.0.1" \
  "Microsoft.Extensions.Diagnostics.Abstractions/10.0.11" \
  "Microsoft.Extensions.Diagnostics.Abstractions/8.0.1" \
  "Microsoft.Extensions.Diagnostics.ExceptionSummarization/10.9.0" \
  "Microsoft.Extensions.FileProviders.Abstractions/10.0.11" \
  "Microsoft.Extensions.FileProviders.Abstractions/8.0.0" \
  "Microsoft.Extensions.Hosting.Abstractions/10.0.11" \
  "Microsoft.Extensions.Hosting.Abstractions/8.0.1" \
  "Microsoft.Extensions.Http/10.0.11" \
  "Microsoft.Extensions.Http/8.0.1" \
  "Microsoft.Extensions.Http.Diagnostics/10.9.0" \
  "Microsoft.Extensions.Logging/10.0.11" \
  "Microsoft.Extensions.Logging/8.0.1" \
  "Microsoft.Extensions.Logging.Abstractions/10.0.11" \
  "Microsoft.Extensions.Logging.Abstractions/8.0.3" \
  "Microsoft.Extensions.Logging.Configuration/10.0.11" \
  "Microsoft.Extensions.Logging.Configuration/8.0.1" \
  "Microsoft.Extensions.ObjectPool/10.0.11" \
  "Microsoft.Extensions.ObjectPool/8.0.30" \
  "Microsoft.Extensions.Options/10.0.11" \
  "Microsoft.Extensions.Options/8.0.2" \
  "Microsoft.Extensions.Options.ConfigurationExtensions/10.0.11" \
  "Microsoft.Extensions.Options.ConfigurationExtensions/8.0.0" \
  "Microsoft.Extensions.Primitives/10.0.11" \
  "Microsoft.Extensions.Primitives/8.0.0" \
  "Microsoft.Extensions.Telemetry/10.9.0" \
  "Microsoft.Extensions.Telemetry.Abstractions/10.9.0" \
  "System.IO.Pipelines/8.0.0" \
  "System.Threading.RateLimiting/8.0.0" \
  "WantsACracker/0.1.0-preview.1" \
  "WantsACracker.Extensions.Http.Resilience/0.1.0-preview.1" \
  "WantsACracker.Extensions.Resilience/0.1.0-preview.1" | sort -u)"
if [ "$resolved" != "$expected_resolved" ]; then
  echo "resolved graph:" >&2;  echo "$resolved"  >&2
  echo "expected graph:" >&2;  echo "$expected_resolved" >&2
  fail "the resolved package set/versions differ from the expected graph"
fi

step "Verify per-TFM asset selection for the three candidate packages"
# The consumer is multi-targeted (net8.0;net10.0): per TFM the resolved
# assets of the three candidate packages must select the matching lib/ folder
# (net8.0 -> lib/net8.0, net10.0 -> lib/net10.0) — not the netstandard2.0
# fallback, not a TFM's sibling.
python3 - "$assets" <<'PY' || fail "the per-TFM asset selection of the candidate packages is wrong"
import json, sys
with open(sys.argv[1]) as f:
    assets = json.load(f)
expected = {"net8.0": "lib/net8.0", "net10.0": "lib/net10.0"}
candidates = ["WantsACracker",
              "WantsACracker.Extensions.Resilience",
              "WantsACracker.Extensions.Http.Resilience"]
targets = assets["targets"]
assert set(targets) == set(expected), f"unexpected target frameworks: {sorted(targets)}"
for tfm, libdir in sorted(expected.items()):
    for pkg in candidates:
        entry = targets[tfm].get(f"{pkg}/0.1.0-preview.1")
        assert entry is not None, f"{pkg} 0.1.0-preview.1 is missing from the {tfm} target"
        want = [f"{libdir}/{pkg}.dll"]
        assert sorted(entry.get("compile", {})) == want, f"{pkg} on {tfm}: compile assets {sorted(entry.get('compile', {}))}, expected {want}"
        assert sorted(entry.get("runtime", {})) == want, f"{pkg} on {tfm}: runtime assets {sorted(entry.get('runtime', {}))}, expected {want}"
print("per-TFM asset selection OK (net8.0 -> lib/net8.0, net10.0 -> lib/net10.0, all three candidate packages)")
PY

step "Build the consumer (net8.0 + net10.0)"
"$dotnet" build "$consumer/consumer.csproj" -c Release --no-restore --nologo \
  || fail "consumer build failed"

# --- 5. Run the offline scenarios on both runtimes ---------------------------

step "Run the consumer on net8.0 and net10.0 (offline scenarios)"
for tfm in net8.0 net10.0; do
  "$dotnet" "$consumer/bin/Release/$tfm/consumer.dll" \
    || fail "the consumer exited non-zero on $tfm"
done

if find "$cache" -maxdepth 1 -type d -iname 'polly*' | grep -q .; then
  fail "a Polly package was downloaded into the consumer cache"
fi

echo
echo "SMOKE PASS: exactly the three $version packages restore, build, and run named and typed clients through AddStandardResilienceHandler() (503 -> 200 retry with exactly 2 server attempts on both; caller cancellation classified with the caller's token, not retried, and the next request succeeds) on net8.0 and net10.0, with zero Polly in the resolved graph."
