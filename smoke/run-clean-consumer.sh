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
#      minimal named-HttpClient consumer app (smoke/clean-consumer/, package
#      references only — never project references) against that feed plus
#      nuget.org.
#   4. Verify the resolved dependency graph: exactly the expected package
#      set at the expected versions, and no Polly package anywhere.
#   5. Run the offline scenario: the first request to the named client gets
#      503, the standard handler's retry succeeds, the app exits 0.
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
core_nupkg_sha256="99a2c2e08248fbb301751569b696c57bf0549a3ceef6c3913856bfd157935fc8"

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
expected_resolved="$(printf '%s\n' \
  "Microsoft.Extensions.AmbientMetadata.Application/10.9.0" \
  "Microsoft.Extensions.Compliance.Abstractions/10.9.0" \
  "Microsoft.Extensions.Configuration/8.0.0" \
  "Microsoft.Extensions.Configuration.Abstractions/8.0.0" \
  "Microsoft.Extensions.Configuration.Binder/8.0.2" \
  "Microsoft.Extensions.DependencyInjection/8.0.1" \
  "Microsoft.Extensions.DependencyInjection.Abstractions/8.0.2" \
  "Microsoft.Extensions.DependencyInjection.AutoActivation/10.9.0" \
  "Microsoft.Extensions.Diagnostics/8.0.1" \
  "Microsoft.Extensions.Diagnostics.Abstractions/8.0.1" \
  "Microsoft.Extensions.Diagnostics.ExceptionSummarization/10.9.0" \
  "Microsoft.Extensions.FileProviders.Abstractions/8.0.0" \
  "Microsoft.Extensions.Hosting.Abstractions/8.0.1" \
  "Microsoft.Extensions.Http/8.0.1" \
  "Microsoft.Extensions.Http.Diagnostics/10.9.0" \
  "Microsoft.Extensions.Logging/8.0.1" \
  "Microsoft.Extensions.Logging.Abstractions/8.0.3" \
  "Microsoft.Extensions.Logging.Configuration/8.0.1" \
  "Microsoft.Extensions.ObjectPool/8.0.30" \
  "Microsoft.Extensions.Options/8.0.2" \
  "Microsoft.Extensions.Options.ConfigurationExtensions/8.0.0" \
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

step "Build the consumer"
"$dotnet" build "$consumer/consumer.csproj" -c Release --no-restore --nologo \
  || fail "consumer build failed"

# --- 5. Run the offline 503 -> retry -> success scenario ---------------------

step "Run the consumer (offline 503 -> retry -> success)"
"$dotnet" "$consumer/bin/Release/net8.0/consumer.dll" \
  || fail "the consumer exited non-zero"

if find "$cache" -maxdepth 1 -type d -iname 'polly*' | grep -q .; then
  fail "a Polly package was downloaded into the consumer cache"
fi

echo
echo "SMOKE PASS: exactly the three $version packages restore, build, and run a named HttpClient through AddStandardResilienceHandler() (first attempt 503, retry 200) with zero Polly in the resolved graph."
