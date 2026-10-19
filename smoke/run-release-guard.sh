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
#      before counting and reconciled against the summary count). The
#      summary records are required, not defaulted: a missing or malformed
#      (non-numeric) 'N Warning(s)' or 'N Error(s)' record fails the guard —
#      counts are never fabricated (fail-closed). Any error or any warning
#      outside the documented known-warning set (see "Known warnings"
#      below, matched on exact tokens) fails the guard; the observed counts
#      are printed and carried into the final GUARD PASS line.
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
#   The documented known-warning set is exactly, matched on EXACT tokens
#   (substring or prefix similarity never matches):
#
#     RT0003 "PackageReference Microsoft.Extensions.Diagnostics.
#     ExceptionSummarization can be removed" — the diagnostic message (the
#     text after 'warning RT0003:' up to an optional ' [...]' scope
#     marker, trimmed) is compared EXACTLY. The marker grammar is defined
#     on that diagnostic remainder (the text after the FIRST 'warning
#     RT0003:'); the logger prefix before the diagnostic (e.g. 'CSC :' or a
#     file/line path) is OUTSIDE the grammar and cannot change the
#     diagnostic's identity — no whole-line single-marker grammar is
#     claimed. The unscoped form (no '[' anywhere in the remainder) is the
#     approved R24 form and stays known; a scope marker, if present, must
#     be a COMPLETE single fully-bracketed ' [path::TargetFramework=tfm]'
#     token whose path basename is EXACTLY
#     WantsACracker.Extensions.Resilience.csproj and whose TFM is EXACTLY
#     netstandard2.0 (a bare TFM marker must be exactly netstandard2.0).
#     A present marker must be whitespace-separated from the message (the
#     character immediately before the first '[' must be whitespace — an
#     adjacent 'removed[...' is unlisted). Marker PRESENCE is tracked
#     separately from marker CONTENT: a dangling '[' (present but empty) is
#     a present-but-malformed marker and fails the guard (it is NOT the
#     unscoped form), and a marker whose CONTENT (the text between the
#     first '[' and the final ']') contains any literal '[' or ']' (nested
#     or unbalanced brackets) fails the guard. For the scoped form
#     everything after the FIRST '::' must be exactly
#     'TargetFramework=netstandard2.0' — a scope token with extra '::'
#     fields between the path and the TFM fails the guard (the fields are
#     not discarded).
#     The Resilience project is the only project that references the
#     package and netstandard2.0 the only TFM whose declared-references
#     TSV is non-empty, so the scope is structurally determined by code +
#     exact message. RT0003 is NOT allow-listed globally: any other code,
#     altered/prefixed/suffixed message, project (e.g.
#     OtherWantsACracker...csproj), TFM (e.g. netstandard2.01), a
#     non-whitespace message/marker boundary, a dangling '[', a
#     nested/unbalanced bracket, or a scope token with extra '::' fields
#     fails the guard.
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
#
# Opt-in regression self-test (canned pass/fail cases for the stage-1 check
# logic only — the exact known-warning matching, including the demonstrated
# bypasses, and the required-summary fail-closed rule; no builds, no
# network, and it never runs during a normal guard invocation):
#   bash smoke/run-release-guard.sh --self-test

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

# The documented known-warning tokens (see "Known warnings" in this header).
# Matching against them is exact: no substring, prefix, or case-insensitive
# similarity.
known_message="PackageReference Microsoft.Extensions.Diagnostics.ExceptionSummarization can be removed"
known_project="WantsACracker.Extensions.Resilience.csproj"
known_tfm="netstandard2.0"

# is_known_warning <code> <line>
# True only for the single documented known warning, classified on EXACT
# tokens (see "Known warnings" in this header). The marker grammar is
# defined on the diagnostic REMAINDER — the text after the FIRST
# 'warning RT0003:' — NOT on the whole line: the logger prefix before the
# diagnostic (e.g. 'CSC :' or a file/line path) is outside the grammar and
# cannot change the diagnostic's identity.
#   - the code is exactly RT0003;
#   - the diagnostic message — the text after 'warning RT0003:' up to an
#     optional ' [...]' scope marker, trimmed — is EXACTLY the documented
#     message (any prefix, suffix, or alteration is unlisted);
#   - when a marker is present it must be whitespace-separated from the
#     exact message: the character immediately BEFORE the first '[' must be
#     whitespace, so an adjacent 'removed[...' (no delimiter) is unlisted
#     (fail closed);
#   - marker PRESENCE is tracked separately from marker CONTENT: a line
#     with no '[' at all is the unscoped approved R24 form and stays
#     known; a present marker must be a COMPLETE single fully-bracketed
#     ' [path::TargetFramework=tfm]' token at the end of the line — a
#     dangling '[' (present, empty content) is a present-but-malformed
#     marker and is unlisted (fail closed), NOT the unscoped form;
#   - the marker CONTENT (the text between the first '[' and the final ']')
#     must contain NO literal '[' and NO literal ']': nested or unbalanced
#     brackets are unlisted (fail closed);
#   - for the scoped form the complete scope token is parsed: the path
#     before the FIRST '::' must have a basename EXACTLY the documented
#     project, and everything after that first '::' must be EXACTLY
#     'TargetFramework=netstandard2.0' — no extra '::' fields between the
#     path and the TFM are discarded; a bare TFM marker must be exactly
#     the documented TFM.
# Anything else — any other code, altered message, other project (e.g.
# OtherWantsACracker...csproj), other TFM (e.g. netstandard2.01), a
# dangling '[', a nested/unbalanced bracket, a non-whitespace message/
# marker boundary, or a scope token with extra fields — is unlisted and
# fails the guard.
is_known_warning() {
  local code="$1" line="$2"
  [ "$code" = "RT0003" ] || return 1
  local rest="${line#*warning RT0003:}"
  local message marker="" marker_present=0 pre
  case "$rest" in
    *"["*)
      # The marker must be whitespace-separated from the exact message: the
      # character immediately BEFORE the first '[' in the diagnostic
      # remainder must be whitespace, so an adjacent 'removed[...' (no
      # delimiter) is unlisted (fail closed).
      pre="${rest%%\[*}"
      [ -z "$pre" ] || [[ "${pre: -1}" == [[:space:]] ]] || return 1
      message="$pre"
      marker="${rest#*\[}"
      marker_present=1 ;;
    *)     message="$rest" ;;
  esac
  message="${message#"${message%%[![:space:]]*}"}"
  message="${message%"${message##*[![:space:]]}"}"
  [ "$message" = "$known_message" ] || return 1
  [ "$marker_present" -eq 1 ] || return 0
  # A present marker must be complete: a dangling '[' (empty content) is
  # present-but-malformed and unlisted (fail closed).
  [ -n "$marker" ] || return 1
  marker="${marker%"${marker##*[![:space:]]}"}"
  [[ "$marker" == *"]" ]] || return 1
  local content="${marker%]}"
  # The marker CONTENT (the text between the first '[' and the final ']')
  # must contain NO literal '[' and NO literal ']' — nested or unbalanced
  # brackets are unlisted (fail closed). Literal matching (quoted '[' and
  # ']'), NOT the broken character-class glob: ' [* ]' is a class matching
  # a literal '*', not an escaped '['.
  case "$content" in
    *"["*|*"]"*) return 1 ;;
  esac
  if [[ "$content" == *"::TargetFramework="* ]]; then
    # The complete scope token: everything after the FIRST '::' must be
    # exactly the TFM field itself — an extra '::field' between the path
    # and the TFM is unlisted, not discarded.
    local rest_after_sep="${content#*::}"
    [ "$rest_after_sep" = "TargetFramework=$known_tfm" ] || return 1
    local path="${content%%::*}"
    [ "${path##*/}" = "$known_project" ] || return 1
  else
    [ "$content" = "$known_tfm" ] || return 1
  fi
  return 0
}

# check_build <short> <full> <log> <allow-known: 1|0>
# Parses the captured build output: the actual MSBuild summary counts (all
# 'N Warning(s)' / 'N Error(s)' lines summed) and every distinct 'warning
# CODE:' line (the build flow's console logger emits each diagnostic twice —
# inline and in the post-build summary section — so lines are deduplicated
# before counting). A valid summary record is a digit run immediately before
# ' Warning(s)' / ' Error(s)'; BOTH records are required before any total is
# calculated or printed — an empty log, missing summary lines, or a
# malformed (non-numeric) summary fails the guard (fail-closed; a zero is
# never fabricated for an unobserved count). Fails the guard on any error or
# on any warning outside the documented known set (allowed only when
# <allow-known> is 1), and on a summary/line-count mismatch. Prints the
# observed per-project counts and appends them to build_summary.
check_build() {
  local short="$1" full="$2" log="$3" allow_known="$4"
  local warnings errors
  warnings="$(awk '{
      if (match($0, /[0-9]+ Warning\(s\)/)) {
        tok = substr($0, RSTART, RLENGTH)
        sub(/ Warning\(s\)$/, "", tok)
        s += tok; found = 1
      }
    }
    END { if (found) print s }' "$log")"
  errors="$(awk '{
      if (match($0, /[0-9]+ Error\(s\)/)) {
        tok = substr($0, RSTART, RLENGTH)
        sub(/ Error\(s\)$/, "", tok)
        s += tok; found = 1
      }
    }
    END { if (found) print s }' "$log")"
  case "$warnings" in
    ''|*[!0-9]*) fail "$full: no valid 'N Warning(s)' summary observed in the build output — cannot report a truthful count (fail-closed)" ;;
  esac
  case "$errors" in
    ''|*[!0-9]*) fail "$full: no valid 'N Error(s)' summary observed in the build output — cannot report a truthful count (fail-closed)" ;;
  esac

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

# --- Self-test mode (opt-in; bash smoke/run-release-guard.sh --self-test) ---
#
# Regression cases for the stage-1 check logic: the same is_known_warning /
# check_build code path the guard uses, fed canned build outputs. Covers the
# exact known-warning matching — including the demonstrated bypasses (changed
# message, OtherWantsACracker...csproj, netstandard2.01, wrong project,
# dangling '[', extra '::' scope field, a nested/unbalanced opening bracket
# in the marker content, an opening bracket inside the scoped path, and the
# non-whitespace message/marker boundary) — and the required-summary
# fail-closed rule (empty / missing / malformed summaries). Never runs
# during a normal guard invocation.

# self_case <name> <expect: pass|fail> <allow-known: 1|0> <log>
self_case() {
  local name="$1" expect="$2" allow="$3" log="$4"
  local rc=0 out reason
  out="$( ( check_build "selftest" "selftest" "$log" "$allow" ) 2>&1 )" || rc=$?
  if { [ "$expect" = "pass" ] && [ "$rc" -eq 0 ]; } || { [ "$expect" = "fail" ] && [ "$rc" -ne 0 ]; }; then
    echo "self-test: PASS [$name] expected=$expect observed=$([ "$rc" -eq 0 ] && echo pass || echo fail)"
  else
    reason="$(printf '%s\n' "$out" | grep -m1 'GUARD FAIL' || true)"
    echo "self-test: FAIL [$name] expected=$expect observed=rc=$rc ${reason}" >&2
    self_failed=1
  fi
}

run_self_tests() {
  local dir="$work/selftest"
  local known line
  mkdir -p "$dir"
  self_failed=0
  known="CSC : warning RT0003: $known_message"
  line="$known [/x/src/Libraries/Microsoft.Extensions.Resilience/WantsACracker.Extensions.Resilience.csproj::TargetFramework=$known_tfm]"

  # (a) exact unscoped R24 form (emitted twice, deduplicated) -> known/pass
  printf '%s\n%s\n    1 Warning(s)\n    0 Error(s)\n' "$known" "$known" > "$dir/a-unscoped.log"
  self_case "a-unscoped-rt0003-known" pass 1 "$dir/a-unscoped.log"

  # (a2) same line with the exact documented scope marker -> known/pass
  printf '%s\n    1 Warning(s)\n    0 Error(s)\n' "$line" > "$dir/a2-scoped.log"
  self_case "a2-scoped-exact-marker-known" pass 1 "$dir/a2-scoped.log"

  # (b) demonstrated bypass: changed-message suffix -> unlisted/FAIL
  printf '%s BUT THIS IS A DIFFERENT MESSAGE\n    1 Warning(s)\n    0 Error(s)\n' "$known" > "$dir/b-changed-message.log"
  self_case "b-changed-message-suffix" fail 1 "$dir/b-changed-message.log"

  # (c) demonstrated bypass: OtherWantsACracker...csproj marker -> unlisted/FAIL
  printf '%s [/x/OtherWantsACracker.Extensions.Resilience.csproj::TargetFramework=%s]\n    1 Warning(s)\n    0 Error(s)\n' "$known" "$known_tfm" > "$dir/c-other-project.log"
  self_case "c-otherwantsacracker-project" fail 1 "$dir/c-other-project.log"

  # (d) demonstrated bypass: netstandard2.01 prefix-similar TFM -> unlisted/FAIL
  printf '%s [/x/WantsACracker.Extensions.Resilience.csproj::TargetFramework=netstandard2.01]\n    1 Warning(s)\n    0 Error(s)\n' "$known" > "$dir/d-tfm-prefix.log"
  self_case "d-tfm-netstandard2-01-prefix" fail 1 "$dir/d-tfm-prefix.log"

  # (e) wrong project, right message -> unlisted/FAIL
  printf '%s [/x/SomeOther.Project.csproj::TargetFramework=%s]\n    1 Warning(s)\n    0 Error(s)\n' "$known" "$known_tfm" > "$dir/e-wrong-project.log"
  self_case "e-wrong-project-right-message" fail 1 "$dir/e-wrong-project.log"

  # (f) B2: empty log -> no valid summaries -> FAIL
  : > "$dir/f-empty.log"
  self_case "f-empty-log-no-summary" fail 1 "$dir/f-empty.log"

  # (f2) B2: build noise but no summary lines -> FAIL
  printf 'Determining projects to restore...\nRestore finished in 0.1 s.\n' > "$dir/f2-no-summary.log"
  self_case "f2-no-summary-lines" fail 1 "$dir/f2-no-summary.log"

  # (g) B2: malformed (non-numeric) summary -> FAIL
  printf '%s\n  Warning(s)\n    0 Error(s)\n' "$known" > "$dir/g-malformed.log"
  self_case "g-malformed-summary" fail 1 "$dir/g-malformed.log"

  # (h) clean 0w/0e with both valid summaries -> pass
  printf '    0 Warning(s)\n    0 Error(s)\n' > "$dir/h-clean.log"
  self_case "h-clean-zero-state" pass 0 "$dir/h-clean.log"

  # (i) unlisted CS0618 -> FAIL
  printf '%s(1,1): warning CS0618: %s\n    1 Warning(s)\n    0 Error(s)\n' \
    "/x/src/Libraries/Microsoft.Extensions.Resilience/Foo.cs" "'R27Probe' is obsolete: use 'New'" > "$dir/i-cs0618.log"
  self_case "i-unlisted-cs0618" fail 1 "$dir/i-cs0618.log"

  # (j) a build error present -> FAIL
  printf '%s(1,1): error CS0103: %s\n    0 Warning(s)\n    1 Error(s)\n' \
    "/x/src/Libraries/Microsoft.Extensions.Resilience/Foo.cs" "The name 'Missing' does not exist in the current context" > "$dir/j-error.log"
  self_case "j-build-error" fail 1 "$dir/j-error.log"

  # (k) demonstrated R28 B1 bypass: dangling '[' — marker present but empty
  #     (no content, no closing bracket) -> unlisted/FAIL, not the unscoped form
  printf '%s [\n    1 Warning(s)\n    0 Error(s)\n' "$known" > "$dir/k-dangling-bracket.log"
  self_case "k-dangling-open-bracket" fail 1 "$dir/k-dangling-bracket.log"

  # (l) demonstrated R28 B1 bypass: extra '::Unexpected=value' field between
  #     the project path and the TFM in the scope token -> unlisted/FAIL
  printf '%s [/x/%s::Unexpected=value::TargetFramework=%s]\n    1 Warning(s)\n    0 Error(s)\n' \
    "$known" "$known_project" "$known_tfm" > "$dir/l-extra-scope-field.log"
  self_case "l-extra-scope-field" fail 1 "$dir/l-extra-scope-field.log"

  # (o) demonstrated R30 B1 bypass: a nested/unbalanced OPENING bracket —
  #     'removed [[/x/...]' (a second '[' absorbed into the path prefix).
  #     The marker content contains a literal '[' -> unlisted/FAIL.
  printf '%s [[/x/%s::TargetFramework=%s]\n    1 Warning(s)\n    0 Error(s)\n' \
    "$known" "$known_project" "$known_tfm" > "$dir/o-nested-open-bracket.log"
  self_case "o-nested-open-bracket" fail 1 "$dir/o-nested-open-bracket.log"

  # (p) demonstrated R30 B1 bypass: an OPENING bracket inside the scoped
  #     path — 'removed [/x/[/...csproj...]' (marker content carries a
  #     literal '[') -> unlisted/FAIL.
  printf '%s [/x/[/%s::TargetFramework=%s]\n    1 Warning(s)\n    0 Error(s)\n' \
    "$known" "$known_project" "$known_tfm" > "$dir/p-path-internal-open-bracket.log"
  self_case "p-path-internal-open-bracket" fail 1 "$dir/p-path-internal-open-bracket.log"

  # (q) demonstrated R30 boundary: the exact message immediately adjacent
  #     to '[...]' WITHOUT the documented whitespace delimiter
  #     ('removed[/x/...') -> unlisted/FAIL (fail closed).
  printf '%s[/x/%s::TargetFramework=%s]\n    1 Warning(s)\n    0 Error(s)\n' \
    "$known" "$known_project" "$known_tfm" > "$dir/q-no-delimiter.log"
  self_case "q-no-whitespace-delimiter" fail 1 "$dir/q-no-whitespace-delimiter.log"

  if [ "$self_failed" -eq 0 ]; then
    echo "self-test: all 17 cases behaved as expected"
    return 0
  fi
  echo "self-test: one or more cases misbehaved" >&2
  return 1
}

if [ "${1:-}" = "--self-test" ]; then
  run_self_tests
  exit $?
fi

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
