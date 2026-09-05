#!/usr/bin/env bash
#
# WantsACracker minimum release guard (preview-path step 4; see smoke/README.md).
#
# One checked-in command, additive-only (divergence 10; the thin CI wrapper is
# .github/workflows/wantsacracker-release-guard.yml — the upstream workflows
# are untouched). Stages, in order (any failure aborts with a non-zero exit
# code):
#
#   1. Build the two renamed src projects (Release, all TFMs, repo build flow
#      — this is what bootstraps the repo-local pinned SDK).
#   2. Run the two renamed test suites on net8.0.
#   3. API surface check: the build runs the ApiLifecycle analyzer against
#      the committed API-baseline jsons; a public-surface drift fails the
#      build and/or dirties the baselines, so the baselines must be untouched
#      afterwards.
#   4. The unchanged clean-consumer smoke command
#      (bash smoke/run-clean-consumer.sh): pack the two projects at
#      0.1.0-preview.1, exactly-three-nupkg feed with the sha256-pinned
#      committed core nupkg, empty isolated cache, exact resolved graph with
#      zero Polly, offline 503 -> retry -> 200 scenario.
#   5. Package-content checks on the three preview nupkgs: nuspec id/version,
#      MIT expression licence, README + THIRD-PARTY-NOTICES at the package
#      root (fork packs), every TFM dependency group declaring
#      WantsACracker 0.1.0-preview.1, no Polly anywhere.
#
# Locally runnable from a plain checkout (bash + the repo build flow; the
# repo-local SDK is bootstrapped by stage 1). No tracked build output is
# left behind: pack output goes to the gitignored artifacts/ tree, and every
# inspection happens in a mktemp directory removed on exit.
#
# Entry point (locally and in CI; no arguments):
#   smoke/run-release-guard.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

version="0.1.0-preview.1"

resilience_src="src/Libraries/Microsoft.Extensions.Resilience/WantsACracker.Extensions.Resilience.csproj"
http_src="src/Libraries/Microsoft.Extensions.Http.Resilience/WantsACracker.Extensions.Http.Resilience.csproj"
resilience_test="test/Libraries/Microsoft.Extensions.Resilience.Tests/WantsACracker.Extensions.Resilience.Tests.csproj"
http_test="test/Libraries/Microsoft.Extensions.Http.Resilience.Tests/WantsACracker.Extensions.Http.Resilience.Tests.csproj"
baseline_resilience="src/Libraries/Microsoft.Extensions.Resilience/WantsACracker.Extensions.Resilience.json"
baseline_http="src/Libraries/Microsoft.Extensions.Http.Resilience/WantsACracker.Extensions.Http.Resilience.json"

fail() { echo "GUARD FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

# --- 1. Build the two renamed src projects ----------------------------------

step "1. Build the two renamed src projects (Release, all TFMs)"
# One build.sh call per project: the repo wrapper (eng/build.sh) resolves
# -projects with realpath, which does not accept a semicolon-separated list.
./build.sh -restore -build -c Release -projects "$resilience_src" \
  || fail "build.sh (WantsACracker.Extensions.Resilience) failed"
./build.sh -restore -build -c Release -projects "$http_src" \
  || fail "build.sh (WantsACracker.Extensions.Http.Resilience) failed"

dotnet="$repo_root/.dotnet/dotnet"
[ -x "$dotnet" ] || fail "repo-local SDK not found at .dotnet/dotnet after the repo build flow"

# --- 2. Run the two renamed test suites --------------------------------------

step "2. Run the two renamed test suites (net8.0)"
"$dotnet" test "$resilience_test" -c Release -f net8.0 --nologo \
  || fail "test suite WantsACracker.Extensions.Resilience.Tests failed"
"$dotnet" test "$http_test" -c Release -f net8.0 --nologo \
  || fail "test suite WantsACracker.Extensions.Http.Resilience.Tests failed"

# --- 3. API surface: committed baselines must be untouched -------------------

step "3. API surface check (committed API-baseline jsons must be untouched)"
baseline_status="$(git status --porcelain -- "$baseline_resilience" "$baseline_http" || true)"
[ -z "$baseline_status" ] \
  || fail "the committed API-baseline jsons changed during the build (public API surface drift): $baseline_status"

# --- 4. The unchanged clean-consumer smoke -----------------------------------

step "4. Clean-consumer smoke (bash smoke/run-clean-consumer.sh, unchanged)"
bash "$script_dir/run-clean-consumer.sh" || fail "the clean-consumer smoke failed"

# --- 5. Package-content checks on the three preview nupkgs -------------------

step "5. Package-content checks on the three $version nupkgs"
work="$(mktemp -d "${TMPDIR:-/tmp}/wantsacracker-guard.XXXXXX")"
trap 'rm -rf "$work"' EXIT

core_nupkg="$repo_root/eng/local-packages/WantsACracker.$version.nupkg"
res_nupkg="$repo_root/artifacts/packages/Release/Shipping/WantsACracker.Extensions.Resilience.$version.nupkg"
http_nupkg="$repo_root/artifacts/packages/Release/Shipping/WantsACracker.Extensions.Http.Resilience.$version.nupkg"
[ -f "$core_nupkg" ] || fail "committed core nupkg $core_nupkg is missing"
[ -f "$res_nupkg" ]  || fail "fresh pack $res_nupkg is missing from artifacts/packages/Release/Shipping"
[ -f "$http_nupkg" ] || fail "fresh pack $http_nupkg is missing from artifacts/packages/Release/Shipping"

unpack() { # $1 = nupkg path, $2 = name
  local nupkg="$1" name="$2"
  mkdir -p "$work/$name"
  unzip -q -o "$nupkg" -d "$work/$name" || fail "unzipping $nupkg failed"
}

check_nuspec() { # $1 = nuspec, $2 = expected id
  local nuspec="$1" id="$2"
  grep -qF "<id>$id</id>" "$nuspec" || fail "$nuspec: id is not $id"
  grep -qF "<version>$version</version>" "$nuspec" || fail "$nuspec: version is not $version"
  grep -qF '<license type="expression">MIT</license>' "$nuspec" \
    || fail "$nuspec: the MIT expression licence is missing"
  if grep -qi "polly" "$nuspec"; then
    fail "$nuspec: a Polly reference is present: $(grep -oi 'polly[^ <"]*' "$nuspec" | sort -u | tr '\n' ' ')"
  fi
}

# 5a. The committed core nupkg (the smoke already sha256-verified it)
unpack "$core_nupkg" "core"
check_nuspec "$work/core/WantsACracker.nuspec" "WantsACracker"
for tfm in netstandard2.0 net8.0 net10.0; do
  [ -d "$work/core/lib/$tfm" ] || fail "the core nupkg is missing lib/$tfm"
done

# 5b. The two fresh fork packs
check_fork_pack() { # $1 = nupkg, $2 = name, $3 = id, $4 = required sibling ("" if none)
  local nupkg="$1" name="$2" id="$3" sibling="$4"
  unpack "$nupkg" "$name"
  local nuspec="$work/$name/$id.nuspec"
  check_nuspec "$nuspec" "$id"
  [ -f "$work/$name/README.md" ] || fail "$id: README.md is missing at the package root"
  [ -f "$work/$name/THIRD-PARTY-NOTICES.TXT" ] \
    || fail "$id: THIRD-PARTY-NOTICES.TXT is missing at the package root"
  local groups core_deps sibling_deps
  groups="$(grep -cF '<group targetFramework=' "$nuspec")"
  core_deps="$(grep -cF "<dependency id=\"WantsACracker\" version=\"$version\"" "$nuspec")"
  [ "$groups" -gt 0 ] && [ "$groups" -eq "$core_deps" ] \
    || fail "$id: WantsACracker $version is not declared in every TFM dependency group (groups=$groups, declarations=$core_deps)"
  if [ -n "$sibling" ]; then
    sibling_deps="$(grep -cF "<dependency id=\"$sibling\" version=\"$version\"" "$nuspec")"
    [ "$groups" -eq "$sibling_deps" ] \
      || fail "$id: $sibling $version is not declared in every TFM dependency group (groups=$groups, declarations=$sibling_deps)"
  fi
}

check_fork_pack "$res_nupkg"  "res"  "WantsACracker.Extensions.Resilience" ""
check_fork_pack "$http_nupkg" "http" "WantsACracker.Extensions.Http.Resilience" "WantsACracker.Extensions.Resilience"

echo
echo "GUARD PASS: build (0w/0e, all TFMs), test suites (net8.0), API-baseline surface, pack, package-content checks, and the clean-consumer smoke all passed for the $version preview set."
