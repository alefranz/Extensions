#!/usr/bin/env bash
#
# WantsACracker deterministic-pack check (preview-path step 6, first slice;
# see smoke/README.md; additive-only, divergence 13).
#
# Questions answered (any failure aborts with a non-zero exit code):
#   1. Are two consecutive packs of each of the two renamed fork projects,
#      from the same clean state (fresh build each time), identical after the
#      documented normalization?
#   2. Core -> fork feed handoff: is a fresh pack of the core project, built
#      from the pinned core commit with the repo-local pinned SDK, identical
#      after the documented normalization to the committed feed nupkg
#      (eng/local-packages/WantsACracker.0.1.0-preview.1.nupkg)?
#
# Empirically established cause of the non-determinism (see UPSTREAM.md,
# divergence 13): the SDK stamps nupkg zip entries with the **current time**
# (per-second DOS timestamps; two same-state packs a few seconds apart differ
# in exactly those fields, payloads byte-identical), and — on the repo-local
# pinned SDK 10.0.111 (global.json; an upstream pin this fork must not
# change) — the pack targets also embed a **random-GUID filename** for
# `package/services/metadata/core-properties/<32-hex>.psmdcp` plus its
# random `Id="R<hex>"` and GUID `Target` in `_rels/.rels` on every pack.
# The cross-checkout feed variance (the audit finding of 70 changed
# netstandard DLL bytes) was the absolute PDB path in the DLL's debug
# directory, which the core normalizes at its source (PathMap).
#
# Chosen strategy (the same strategy applies to the fork packs and the core
# pack; "at the source" wherever the repository owns the build files):
#   - Deterministic build content at the source: the portable-PDB identity is
#     a content hash, not a random GUID. The fork already sets `Deterministic`
#     unconditionally (upstream `Directory.Build.props`, untouched); the core
#     sets it explicitly in its own `Directory.Build.props` and maps debug
#     paths to the canonical prefix `WantsACracker` (PathMap), which is what
#     makes the committed feed nupkg reproducible from ANY checkout of the
#     pinned commit.
#   - Check-time zip normalization: source-level timestamp normalization is
#     impossible on the pinned SDK 10.0.111 (its `NuGet.Build.Tasks.Pack`
#     targets pass only `Deterministic`, not `DeterministicTimestamp`, so
#     `SOURCE_DATE_EPOCH` is honored by no SDK pack path on this toolchain),
#     so the check itself rebuilds each nupkg canonically — sorted entries,
#     fixed date_time (2023-11-14T22:13:20Z, SOURCE_DATE_EPOCH=1700000000,
#     the reproducible-builds convention), canonical `nuget.psmdcp` name,
#     canonical `.rels` Target/Id for that entry — and asserts
#     byte-identity of the normalized packages.
#   - Variance accounting: for each compared pair the check additionally
#     unpacks the RAW nupkgs and asserts the raw byte variance is limited to
#     exactly the documented fields — the file sets are identical, the only
#     file allowed to differ is `_rels/.rels`, and only on the psmdcp
#     relationship line (its Target is the GUID filename, its Id is random);
#     everything else — including the psmdcp content — is byte-identical.
#     (The zip entry timestamps are the third documented field; they are not
#     visible in unpacked content and differ by construction on this SDK.)
#
# The fork packs are asserted within this checkout: their remaining
# machine-specific bytes are the absolute `artifacts/` debug paths, constant
# within a checkout; asserting cross-checkout byte-identity of the fork packs
# would require changing upstream build files, which the narrow-divergence
# rule forbids.
#
# Stages, in order:
#   1. Fork round 1: clean the two projects' build state, build + pack both
#      (repo build flow, repo-local pinned SDK) at 0.1.0-preview.1.
#   2. Fork round 2 (a few seconds later): the same clean/build/pack again —
#      the pause guarantees unnormalized wall-clock stamps differ, so the
#      normalized identity proves normalization rather than luck.
#   3. Normalize all four nupkgs (main + .symbols.nupkg per project), assert
#      the per-project normalized sha256 pairs are equal, and assert the raw
#      variance is limited to the documented fields.
#   4. Feed handoff: clone the core repository at the pinned commit (fresh
#      scratch checkout — never a sibling checkout, so the proof does not
#      depend on this checkout's layout), build + pack with the repo-local
#      pinned SDK, normalize both the fresh pack and the committed feed
#      nupkg, assert the normalized sha256s are equal, and assert the raw
#      variance is limited to the documented fields.
#
# Isolated and temporary: an isolated NUGET_PACKAGES cache, the two pack
# rounds' outputs, the core clone, and the unpack/normalization scratch all
# live in a scratch directory under ${XDG_CACHE_HOME:-$HOME/.cache}/
# opencode-work, removed on exit. No tracked build output is left behind
# (pack output goes to the gitignored artifacts/ tree; the core is built in
# the scratch clone).
#
# Entry point (locally and as release-guard stage 7; no arguments):
#   smoke/run-deterministic-pack.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

version="0.1.0-preview.1"

resilience_src="src/Libraries/Microsoft.Extensions.Resilience/WantsACracker.Extensions.Resilience.csproj"
http_src="src/Libraries/Microsoft.Extensions.Http.Resilience/WantsACracker.Extensions.Http.Resilience.csproj"
res_proj="WantsACracker.Extensions.Resilience"
http_proj="WantsACracker.Extensions.Http.Resilience"

# The committed feed nupkg and the core commit it was produced from. A feed
# regeneration (a Core commit whose packed bytes change) must update both the
# nupkg and these two values together, and re-run this check.
core_repo_url="https://github.com/alefranz/WantsACracker-Development.git"
core_commit="3da5b8c8f2b19d56b1d58f67fc62fc37b8f8081d"
core_nupkg="eng/local-packages/WantsACracker.$version.nupkg"
core_nupkg_sha256="6df716e82896fc6eec518859ee85936a5e526749fba320d02916f52d09318234"

fail() { echo "DET-PACK FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

work="$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/opencode-work/wantsacracker-fork-detpack.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The normalization epoch (reproducible-builds convention; the pinned-SDK
# pack targets do not consume it, so it is the normalization constant the
# check itself applies) and an isolated package cache under the scratch policy.
export SOURCE_DATE_EPOCH=1700000000
export NUGET_PACKAGES="$work/nuget"

# --- Normalization helpers ---------------------------------------------------

# Rebuild a nupkg canonically: sorted entries, fixed date_time
# (2023-11-14T22:13:20Z = SOURCE_DATE_EPOCH 1700000000), stable attributes,
# canonical `nuget.psmdcp` name, canonical _rels/.rels Target/Id for that
# entry. This is the check-time normalization described in the header: on
# the pinned SDK 10.0.111 the only pack-to-pack variance is these fields, so
# two packs are "the same package" iff their normalizations are equal.
normalize_nupkg() { # $1 = source nupkg, $2 = destination nupkg
  python3 - "$1" "$2" <<'PY' || fail "zip normalization failed for $1"
import re, sys, zipfile
EPOCH = (2023, 11, 14, 22, 13, 20)  # SOURCE_DATE_EPOCH=1700000000
src, dst = sys.argv[1], sys.argv[2]
zin = zipfile.ZipFile(src)
entries = {}
for info in zin.infolist():
    name, data = info.filename, zin.read(info.filename)
    if re.fullmatch(r"package/services/metadata/core-properties/[0-9a-f]{32}\.psmdcp", name):
        name = "package/services/metadata/core-properties/nuget.psmdcp"
    if name == "_rels/.rels":
        data = re.sub(rb"(package/services/metadata/core-properties/)[0-9a-f]{32}\.psmdcp",
                      rb"\1nuget.psmdcp", data)
        data = re.sub(rb'(<Relationship\s[^>]*Target="[^"]*\.psmdcp"[^>]*?Id=")[^"]*(")',
                      rb"\1Rpsmdcp\2", data)
    entries[name] = data
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for name in sorted(entries):
        zi = zipfile.ZipInfo(name, date_time=EPOCH)
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.external_attr = 0
        zout.writestr(zi, entries[name])
PY
}

# Unpack both nupkgs, canonicalize the psmdcp name in each tree (the older
# pack targets — e.g. SDK 10.0.111 — emit a random-GUID filename, while newer
# ones — e.g. 10.0.400 — already name it deterministically `nuget.psmdcp`),
# and assert the raw byte variance is limited to the documented fields: the
# file sets are identical, the only file allowed to differ is _rels/.rels,
# and only on the psmdcp relationship line (Target = GUID filename, Id =
# random); everything else — including the psmdcp content — is
# byte-identical.
assert_raw_variance_accounted() { # $1 = nupkg A, $2 = nupkg B, $3 = label
  local cpdir="package/services/metadata/core-properties"
  local da="$work/variance-a" db="$work/variance-b" d f n out
  rm -rf "$da" "$db"; mkdir -p "$da" "$db"
  unzip -q -o "$1" -d "$da" || fail "$3: could not unpack $1"
  unzip -q -o "$2" -d "$db" || fail "$3: could not unpack $2"
  for d in "$da" "$db"; do
    n=0
    for f in "$d/$cpdir"/*.psmdcp; do
      [ -e "$f" ] || continue
      n=$((n+1))
      [ "$(basename "$f")" = "nuget.psmdcp" ] || mv "$f" "$d/$cpdir/nuget.psmdcp"
    done
    [ "$n" = 1 ] || fail "$3: expected exactly one core-properties psmdcp, found $n"
  done
  out="$(diff -r "$da" "$db" || true)"
  [ -z "$(printf '%s\n' "$out" | grep '^Only in')" ] \
    || fail "$3: the two nupkgs contain different file sets — unaccounted variance:
$(printf '%s\n' "$out" | grep '^Only in')"
  local unexpected
  unexpected="$(printf '%s\n' "$out" | grep 'differ' | grep -v '_rels/\.rels' || true)"
  [ -z "$unexpected" ] \
    || fail "$3: files other than _rels/.rels differ — unaccounted variance:
$unexpected"
  if printf '%s\n' "$out" | grep -q '_rels/\.rels.*differ'; then
    local bad
    bad="$(diff "$da/_rels/.rels" "$db/_rels/.rels" | grep -E '^[<>]' | grep -v 'psmdcp' || true)"
    [ -z "$bad" ] \
      || fail "$3: _rels/.rels differs beyond the psmdcp relationship line — unaccounted variance:
$bad"
  fi
}

# --- 1+2. Pack the two fork projects twice, from clean states ---------------

fork_pack_round() { # $1 = round output directory
  # Clean the two projects' build state (Arcade artifacts layout) so each
  # round is a fresh restore + build + pack of the same clean state.
  rm -rf "artifacts/bin/$res_proj" "artifacts/obj/$res_proj" \
         "artifacts/bin/$http_proj" "artifacts/obj/$http_proj" \
         "artifacts/packages"
  # One build.sh call per project: the repo wrapper (eng/build.sh) resolves
  # -projects with realpath, which does not accept a semicolon-separated list.
  ./build.sh -restore -build -c Release -projects "$resilience_src" \
    || fail "build.sh ($res_proj) failed (round into $1)"
  ./build.sh -restore -build -c Release -projects "$http_src" \
    || fail "build.sh ($http_proj) failed (round into $1)"
  "$dotnet" pack "$resilience_src" -c Release --nologo \
    || fail "dotnet pack ($res_proj) failed (round into $1)"
  "$dotnet" pack "$http_src" -c Release --nologo \
    || fail "dotnet pack ($http_proj) failed (round into $1)"
  mkdir -p "$1"
  cp "artifacts/packages/Release/Shipping/$res_proj.$version.nupkg" "$1/" \
    || fail "fresh pack $res_proj nupkg is missing from artifacts/packages/Release/Shipping"
  cp "artifacts/packages/Release/Shipping/$res_proj.$version.symbols.nupkg" "$1/" \
    || fail "fresh pack $res_proj .symbols.nupkg is missing"
  cp "artifacts/packages/Release/Shipping/$http_proj.$version.nupkg" "$1/" \
    || fail "fresh pack $http_proj nupkg is missing"
  cp "artifacts/packages/Release/Shipping/$http_proj.$version.symbols.nupkg" "$1/" \
    || fail "fresh pack $http_proj .symbols.nupkg is missing"
}

dotnet="$repo_root/.dotnet/dotnet"
[ -x "$dotnet" ] || fail "repo-local SDK not found at .dotnet/dotnet"

step "1. Fork pack round 1 (clean state, repo build flow, $version)"
fork_pack_round "$work/fork1"

# A short pause makes any unnormalized wall-clock stamp differ between the
# two rounds, so normalized identity proves normalization rather than luck.
sleep 3

step "2. Fork pack round 2 (fresh clean state, a few seconds later)"
fork_pack_round "$work/fork2"

# --- 3. Normalized identity of the two rounds --------------------------------

step "3. Assert the two rounds are byte-identical after normalization"
mkdir -p "$work/norm"
for f in "$res_proj.$version.nupkg" "$res_proj.$version.symbols.nupkg" \
         "$http_proj.$version.nupkg" "$http_proj.$version.symbols.nupkg"; do
  normalize_nupkg "$work/fork1/$f" "$work/norm/r1-$f"
  normalize_nupkg "$work/fork2/$f" "$work/norm/r2-$f"
  sha1="$(sha256sum "$work/norm/r1-$f" | cut -d' ' -f1)"
  sha2="$(sha256sum "$work/norm/r2-$f" | cut -d' ' -f1)"
  echo "$f: normalized $sha1 / $sha2"
  [ "$sha1" = "$sha2" ] \
    || fail "$f is NOT byte-identical between the two rounds after normalization (sha256 $sha1 vs $sha2) — the deterministic-pack strategy regressed"
  assert_raw_variance_accounted "$work/fork1/$f" "$work/fork2/$f" "$f (round 1 vs round 2)"
done

# --- 4. Core -> fork feed handoff --------------------------------------------

step "4. Feed handoff: fresh core pack from $core_commit vs the committed feed nupkg"
[ -f "$core_nupkg" ] || fail "committed feed nupkg $core_nupkg is missing"
committed_sha="$(sha256sum "$core_nupkg" | cut -d' ' -f1)"
[ "$committed_sha" = "$core_nupkg_sha256" ] \
  || fail "committed feed nupkg sha256 mismatch: $committed_sha != $core_nupkg_sha256 (feed drift — regenerate the nupkg and update the pin together)"

# A fresh clone at a scratch path (not the sibling checkout): proves the
# committed nupkg is reproducible from the pinned commit alone, independent
# of this checkout's layout or state.
core_clone="$work/core"
git init -q "$core_clone"
git -C "$core_clone" remote add origin "$core_repo_url"
git -C "$core_clone" fetch -q --depth 1 origin "$core_commit" \
  || fail "fetching core commit $core_commit from $core_repo_url failed"
git -C "$core_clone" checkout -q FETCH_HEAD \
  || fail "checking out core commit $core_commit failed"
[ "$(git -C "$core_clone" rev-parse HEAD)" = "$core_commit" ] \
  || fail "the core clone is not at the pinned commit $core_commit"

# The repo-local pinned SDK (global.json pins the exact SDK the committed
# nupkg was produced with; stage 1 already ran the repo build flow, which
# bootstraps .dotnet).
"$dotnet" build "$core_clone/src/WantsACracker/WantsACracker.csproj" -c Release --nologo -v q \
  || fail "fresh core build at $core_commit failed"
"$dotnet" pack "$core_clone/src/WantsACracker/WantsACracker.csproj" -c Release --no-build \
  -o "$work/core-pack" --nologo \
  || fail "fresh core pack at $core_commit failed"
fresh_core="$work/core-pack/WantsACracker.$version.nupkg"
[ -f "$fresh_core" ] || fail "the fresh core pack did not produce WantsACracker.$version.nupkg"

normalize_nupkg "$fresh_core" "$work/norm/fresh-core.nupkg"
normalize_nupkg "$repo_root/$core_nupkg" "$work/norm/committed-feed.nupkg"
fresh_norm_sha="$(sha256sum "$work/norm/fresh-core.nupkg" | cut -d' ' -f1)"
committed_norm_sha="$(sha256sum "$work/norm/committed-feed.nupkg" | cut -d' ' -f1)"
echo "committed feed (raw sha256 $committed_sha) normalized: $committed_norm_sha"
echo "fresh core pack normalized: $fresh_norm_sha"
[ "$fresh_norm_sha" = "$committed_norm_sha" ] \
  || fail "the fresh core pack (commit $core_commit, repo-local pinned SDK) is NOT identical after normalization to the committed feed nupkg (sha256 $fresh_norm_sha vs $committed_norm_sha) — regenerate the feed nupkg from the pinned commit and update the pin"
assert_raw_variance_accounted "$fresh_core" "$repo_root/$core_nupkg" "feed handoff (fresh core pack vs committed feed)"

echo
echo "DET-PACK PASS: two consecutive clean-state packs of both fork projects (nupkg + .symbols.nupkg) and a fresh core pack from commit $core_commit (fresh scratch clone, repo-local pinned SDK) are byte-identical to the committed feed nupkg after the documented normalization, and the raw byte variance of every compared pair is limited to exactly the documented fields (zip entry timestamps; the GUID core-properties psmdcp filename; its _rels/.rels Target and Id) — no variance remains unaccounted for."
