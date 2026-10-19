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
#      — this is what bootstraps the repo-local pinned SDK). Both build
#      outputs are captured and parsed: the actual 'N Warning(s)' /
#      'N Error(s)' summary and every distinct 'warning CODE:' line (the
#      build flow's console logger emits each diagnostic twice — inline and
#      again in the post-build summary section — so lines are deduplicated
#      before counting and reconciled against the summary count). Any error
#      or any warning outside the documented known-warning set (see "Known
#      warnings" below) fails the guard; the observed counts are printed
#      and carried into the final GUARD PASS line.
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
#      root (all three packages), every TFM dependency group declaring
#      WantsACracker 0.1.0-preview.1, no Polly anywhere.
#   6. The differential compatibility proof
#      (bash smoke/run-differential.sh, divergence 12): the full P0 HTTP
#      scenario set through both sides of the source-level compatibility
#      claim at the shared AddStandardResilienceHandler() seam — the three
#      0.1.0-preview.1 packages (no Polly in the graph) versus the Polly
#      8.4.2 reference (Microsoft.Extensions.Http.Resilience 10.9.0).
#   7. The deterministic-pack check
#      (bash smoke/run-deterministic-pack.sh, divergence 13): two consecutive
#      clean-state packs of both fork projects are byte-identical (nupkg +
#      .symbols.nupkg, zip entry timestamps pinned to the documented epoch),
#      and a fresh core pack from the pinned core commit (fresh scratch
#      clone, repo-local pinned SDK) is byte-identical to the committed feed
#      nupkg (the Core -> fork feed handoff).
#
# Known warnings (the documented known-warning set stage 1 enforces against):
#
#   The repo build flow runs the ReferenceTrimmer 3.3.1 analyzer (version
#   pinned in eng/packages/General.props:46; referenced as a global analyzer
#   in eng/MSBuild/Analyzers.props:25; active unless SkipAnalyzers=true).
#   Its RT0003 ("PackageReference {0} can be removed") can fire for
#   WantsACracker.Extensions.Resilience, TFM netstandard2.0 only:
#
#     - Origin/mechanism: an MSBuild target shipped with the package
#       (CollectDeclaredReferences, hooked into CoreCompileDependsOn) writes
#       artifacts/obj/<proj>/Release/<tfm>/_ReferenceTrimmer_DeclaredReferences.tsv
#       mapping each declared package to the assembly paths resolved from
#       project.assets.json; the Roslyn analyzer compares that set with the
#       compilation's used assembly references (logged to
#       _ReferenceTrimmer_UsedReferences.log) and fires RT0003 when none of
#       a package's declared assemblies is in the used set.
#     - netstandard2.0-only: in a full all-TFM build the TSV is written
#       non-empty only for the netstandard2.0 inner build (the
#       Microsoft.Extensions.Diagnostics.ExceptionSummarization package
#       closure); the net10.0/net9.0/net8.0/net462 TSVs are empty, so the
#       analyzer cannot fire for those TFMs.
#     - state-dependent: whether the package's declared assemblies land in
#       the compilation's used set depends on build/asset state (declared-
#       vs-used path resolution in CollectDeclaredReferences/the analyzer),
#       so the warning appears in some runs and not in others for identical
#       sources. The exact flip variable is not fully determined; the
#       established mechanism above is what this guard classifies on.
#     - not a product signal: the ExceptionSummarization PackageReference
#       is required by the source (IExceptionSummarizer is used uncondi-
#       tionally in ResilienceServiceCollectionExtensions.cs and
#       ResilienceMetricsEnricher.cs); firing vs. not firing changes no
#       shipped assembly, and src plus the API baselines are unchanged
#       across all observations (the R24 firing run and the non-firing
#       runs alike).
#
#   The documented known-warning set is exactly:
#
#     RT0003 "PackageReference Microsoft.Extensions.Diagnostics.
#     ExceptionSummarization can be removed" in the Resilience project
#     build, TFM netstandard2.0 — the only project that references the
#     package and the only TFM whose declared-references TSV is non-empty,
#     so the scope is structurally determined by code + exact message; an
#     explicit scope marker in the line, if present, must still agree.
#     RT0003 is NOT allow-listed globally: any other code, message, project,
#     or TFM fails the guard.
#
#   The known warning is printed, not suppressed (no NoWarn): its count is
#   reported in the per-project line and in the final GUARD PASS summary.
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

# One mktemp area for the whole run (build-output capture in stage 1, the
# nupkg inspection in stage 5), removed on exit.
work="$(mktemp -d "${TMPDIR:-/tmp}/wantsacracker-guard.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- 1. Build the two renamed src projects ----------------------------------

step "1. Build the two renamed src projects (Release, all TFMs)"

build_res_log="$work/resilience-build.log"
build_http_log="$work/http-build.log"
build_summary=""

# is_known_warning <code> <line>
# True only for the single documented known warning (see "Known warnings" in
# this header). An explicit scope marker in the line, if present, must agree
# with the documented scope (Resilience project + TFM netstandard2.0).
is_known_warning() {
  local code="$1" line="$2"
  [ "$code" = "RT0003" ] || return 1
  case "$line" in
    *"PackageReference Microsoft.Extensions.Diagnostics.ExceptionSummarization can be removed"*) ;;
    *) return 1 ;;
  esac
  if [[ "$line" == *"::TargetFramework="* ]]; then
    [[ "$line" == *"::TargetFramework=netstandard2.0"* ]] || return 1
  fi
  if [[ "$line" =~ \[([A-Za-z0-9.]+)\][[:space:]]*$ ]]; then
    [ "${BASH_REMATCH[1]}" = "netstandard2.0" ] || return 1
  fi
  if [[ "$line" == *.csproj* ]]; then
    [[ "$line" == *WantsACracker.Extensions.Resilience.csproj* ]] || return 1
  fi
  return 0
}

# check_build <short> <full> <log> <allow-known: 1|0>
# Parses the captured build output: the actual MSBuild summary counts (all
# 'N Warning(s)' / 'N Error(s)' lines summed) and every distinct 'warning
# CODE:' line (the build flow's console logger emits each diagnostic twice —
# inline and in the post-build summary section — so lines are deduplicated
# before counting). Fails the guard on any error or on any warning outside
# the documented known set (allowed only when <allow-known> is 1), and on a
# summary/line-count mismatch. Prints the observed per-project counts and
# appends them to build_summary.
check_build() {
  local short="$1" full="$2" log="$3" allow_known="$4"
  local warnings errors
  warnings="$(awk '/[0-9]+ Warning\(s\)/ { s += $1 } END { print s + 0 }' "$log")"
  errors="$(awk '/[0-9]+ Error\(s\)/ { s += $1 } END { print s + 0 }' "$log")"
  [ -n "$warnings" ] && [ -n "$errors" ] \
    || fail "$full: no MSBuild summary ('N Warning(s)' / 'N Error(s)') found in the build output — cannot report a truthful count"

  if [ "$errors" -gt 0 ]; then
    fail "$full: $errors build error(s):
$(grep -E 'error [A-Z][A-Z0-9]+:' "$log" | head -20)"
  fi

  local parsed=0 known=0 unlisted=0
  local wcode wline wlist unlisted_list=""
  # code \037 line  (octal unit-separator; non-whitespace, so read keeps
  # empty fields intact). The build flow's console logger emits each
  # diagnostic twice (inline during the build, then again in the post-build
  # summary section before the 'N Warning(s)' line), so each DISTINCT line is
  # counted exactly once and reconciled against the summary count.
  wlist="$(awk '!seen[$0]++ {
      if (match($0, /warning [A-Z][A-Z0-9]+:/)) {
        code = substr($0, RSTART + 8, RLENGTH - 9)
        printf "%s\037%s\n", code, $0
      }
    }' "$log")"
  while IFS=$'\037' read -r wcode wline; do
    [ -n "$wcode" ] || continue
    parsed=$((parsed + 1))
    if [ "$allow_known" = "1" ] && is_known_warning "$wcode" "$wline"; then
      known=$((known + 1))
      echo "build: $full: documented known warning (printed, not suppressed): $wline"
    else
      unlisted=$((unlisted + 1))
      unlisted_list="${unlisted_list}  $wline"$'\n'
    fi
  done <<< "$wlist"

  [ "$parsed" -eq "$warnings" ] \
    || fail "$full: parsed $parsed warning line(s) but the MSBuild summary reports $warnings Warning(s) — the build output cannot be reconciled truthfully"

  if [ "$unlisted" -gt 0 ]; then
    fail "$full: $unlisted warning(s) not in the documented known-warning set (see 'Known warnings' in this script):
$unlisted_list"
  fi

  local known_note=""
  if [ "$known" -gt 0 ]; then known_note=" [RT0003 known]"; fi
  echo "build: $full ${warnings} warning(s)${known_note}, ${errors} error(s)"
  build_summary="${build_summary}${build_summary:+; }${short} ${warnings}w/${errors}e"
  if [ "$known" -gt 0 ]; then
    build_summary="${build_summary} — documented known RT0003"
  fi
}

# One build.sh call per project: the repo wrapper (eng/build.sh) resolves
# -projects with realpath, which does not accept a semicolon-separated list.
./build.sh -restore -build -c Release -projects "$resilience_src" > "$build_res_log" 2>&1 \
  || fail "build.sh (WantsACracker.Extensions.Resilience) failed (errors: $(grep -E 'error [A-Z][A-Z0-9]+:' "$build_res_log" | head -5); tail: $(tail -2 "$build_res_log"))"
check_build "Resilience" "WantsACracker.Extensions.Resilience" "$build_res_log" 1

./build.sh -restore -build -c Release -projects "$http_src" > "$build_http_log" 2>&1 \
  || fail "build.sh (WantsACracker.Extensions.Http.Resilience) failed (errors: $(grep -E 'error [A-Z][A-Z0-9]+:' "$build_http_log" | head -5); tail: $(tail -2 "$build_http_log"))"
check_build "Http" "WantsACracker.Extensions.Http.Resilience" "$build_http_log" 0

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
[ -f "$work/core/README.md" ] \
  || fail "WantsACracker: README.md is missing at the package root"
[ -f "$work/core/THIRD-PARTY-NOTICES.TXT" ] \
  || fail "WantsACracker: THIRD-PARTY-NOTICES.TXT is missing at the package root"
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

# --- 6. The differential compatibility proof ---------------------------------

step "6. Differential compatibility proof (bash smoke/run-differential.sh, full P0 set)"
bash "$script_dir/run-differential.sh" || fail "the differential compatibility harness failed"

# --- 7. The deterministic-pack check ------------------------------------------

step "7. Deterministic-pack check (bash smoke/run-deterministic-pack.sh, divergence 13)"
bash "$script_dir/run-deterministic-pack.sh" || fail "the deterministic-pack check failed"

echo
echo "GUARD PASS: build (${build_summary}; all TFMs — actual observed counts; see 'Known warnings' in this script), test suites (net8.0), API-baseline surface, pack, package-content checks, the clean-consumer smoke, the full-P0 differential compatibility proof, and the deterministic-pack check (fork double-pack byte-identity + Core -> fork feed handoff byte-identity) all passed for the $version preview set."
