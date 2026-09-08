#!/usr/bin/env bash
#
# WantsACracker fork SBOM generation + reproducibility check (preview-path
# step 6, release-truth artifacts; see RELEASE-NOTES.md).
#
# Generates the SPDX 2.2 SBOM for each packed fork package with a pinned tool
# and fixed inputs, and proves the checked-in SBOMs reproduce from the
# checked-in state. Stages, in order (any failure aborts with a non-zero exit
# code):
#
#   1. Install Microsoft.Sbom.DotNetTool (pinned version) into a scratch tool
#      path (repo-local pinned SDK; removed on exit).
#   2. Build + pack both fork projects (the repo build flow, same as
#      smoke/run-deterministic-pack.sh, with the git revision pinned to the
#      all-zeros placeholder — see the revision-pinning note below) and
#      unpack the main nupkgs — the SBOM input is the SHIPPED file set of
#      each package (the nupkg's own contents).
#   3. Run `sbom-tool generate` on each drop directory with fixed inputs: the
#      pinned tool version, a fixed generation timestamp
#      (-gt 2023-11-14T22:13:20Z = SOURCE_DATE_EPOCH 1700000000, the same
#      documented epoch as smoke/run-deterministic-pack.sh), the fixed
#      package name/version/supplier, and a fixed namespace unique part.
#   4. Reproducibility check: each checked-in SBOM
#      (eng/sbom/<PackageId>-<version>.spdx.json) is compared to the fresh
#      generation after the documented canonicalization, by sha256 of the
#      canonical bytes. With `--update`, the fresh raw artifacts are copied
#      over the checked-in ones instead (the regeneration path; the checked-in
#      artifact is always one raw generation).
#
# Determinism, documented exactly as the deterministic-pack slice documented
# its fields: the pinned tool version + fixed inputs make each SBOM's content
# a pure function of that package's bytes. The SBOM build pins the git
# revision to the all-zeros placeholder (see the revision-pinning note
# below), so the package's bytes — and hence each SBOM — are a pure function
# of the source tree + the repo-local pinned SDK, independent of the commit
# being checked out (the same source+SDK function
# smoke/run-deterministic-pack.sh gates, plus the documented revision pin),
# but PATH-BOUND: the packed DLLs embed the generation checkout's absolute
# `artifacts/obj/...` debug paths (divergence 13 — the fork does not
# canonicalize them, which would require changing upstream build files) and
# the nuspec's `<repository>` element carries a
# `branch="refs/heads/<branch>"` attribute only when the pack runs on that
# branch. Both flow into the SBOM's file hashes, so each checked-in SBOM
# binds to the generation checkout's path and branch: reproducible from any
# commit of the source tree, but from this checkout's path.
# The tool's residual
# non-deterministic fields — asserted to be exactly these, all neutralized by
# the canonicalization — are: (1) the file-traversal order in the top-level
# `files` array and in the package's `hasFiles`; (2) the random GUID embedded
# in `documentNamespace`; (3) the random GUID in the package purl's
# `tag_id`. Everything else — including `creationInfo.created` (fixed by -gt),
# every file's SHA1/SHA256, and the package verification code — must be
# byte-identical. In addition, on the repo-local pinned SDK 10.0.111 the pack
# carries the documented raw variance that smoke/run-deterministic-pack.sh
# normalizes at check time, and two of those pack fields leak into the SBOM —
# asserted to be exactly these, also neutralized by the canonicalization:
# (4) the psmdcp file's random-GUID filename in the `files` entry's `fileName`
# (and its derived file SPDXID; the file's own checksums are stable, the
# psmdcp content is byte-identical) — the canonical name is `nuget.psmdcp`,
# the same canonical name the nupkg normalization uses; (5) the `_rels/.rels`
# file's checksums (its content carries the psmdcp GUID relationship line, so
# its hashes differ pack to pack — the only file whose content the
# deterministic-pack variance check allows to differ) — canonicalized to
# zeroed checksums (and the zeroed sha1 in the derived file SPDXID); (6) the
# root package's `packageVerificationCode` — the tool computes it over the
# RAW file entries (so it covers the two raw variances above) and varies
# pack to pack — canonicalized to zeros (its content is implied by the
# individual file checksums it aggregates over). The checked-in artifacts
# are one raw generation each: their raw bytes differ from a fresh
# generation only in those six documented fields.
#
# Revision pinning (why the checked-in SBOMs can reproduce at all): the
# pack can embed the git HEAD in three places — the nuspec `<repository
# commit>` (from `SourceRevisionId`), the `OriginalRepoCommitHash`
# AssemblyMetadataAttribute in the DLLs (emitted by
# `Directory.Build.targets:71-74` — untouched upstream — only when Arcade's
# `RepoOriginalSourceRevisionId` property is set; the default build never
# sets it, so an unpinned local DLL carries no commit attribute at all),
# and the PDB's SourceLink document-map URI
# (`https://raw.githubusercontent.com/alefranz/Extensions/<commit>/*`).
# Unpinned, a checked-in SBOM can therefore NEVER reproduce from the commit
# that contains it: any regeneration re-stamps the new HEAD into the pack
# before the SBOM is taken (a fixed point — the SBOM would have to describe
# a pack stamped with its own, future, commit). The SBOM build therefore
# passes `-p:SourceRevisionId=0000…0` and `-p:RepoOriginalSourceRevisionId=0000…0`
# (the explicit all-zeros placeholder — the dotnet CLI silently drops empty
# `-p:Foo=` values), plus `-p:EnableSourceLink=false`, to both the build.sh
# and the dotnet pack calls. The SBOMs describe this revision-pinned build
# variant: the nuspec `<repository commit>` and the DLLs'
# `OriginalRepoCommitHash` are the all-zeros placeholder, and the PDBs carry
# no SourceLink document map. Every product file's content is identical to
# a live pack's except in those revision metadata fields; a live pack at any
# commit differs from the SBOM's input only in those revision metadata fields
# (the PDBs are not in the main nupkg, so they never enter the SBOM).
#
# Entry point:
#   eng/sbom/generate-sboms.sh            (verify: regenerate + canonical compare)
#   eng/sbom/generate-sboms.sh --update   (regenerate: copy the fresh raw artifacts over the checked-in ones)
#
# Requirements: the repo-local pinned SDK (`.dotnet/dotnet`), `bash`,
# `unzip`, `python3`, and network access to nuget.org for the pinned tool and
# the isolated restore (the tool installs into the per-run scratch path, so
# network is needed on every run).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

update=0
[ "${1:-}" = "--update" ] && update=1

fail() { echo "SBOM FAIL: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

version="0.1.0-preview.1"

resilience_src="src/Libraries/Microsoft.Extensions.Resilience/WantsACracker.Extensions.Resilience.csproj"
http_src="src/Libraries/Microsoft.Extensions.Http.Resilience/WantsACracker.Extensions.Http.Resilience.csproj"
res_proj="WantsACracker.Extensions.Resilience"
http_proj="WantsACracker.Extensions.Http.Resilience"

dotnet="$repo_root/.dotnet/dotnet"
[ -x "$dotnet" ] || fail "repo-local SDK not found at .dotnet/dotnet"

tool_version="4.1.5"  # Microsoft.Sbom.DotNetTool (pinned; the SBOM records it)
generation_timestamp="2023-11-14T22:13:20Z"  # SOURCE_DATE_EPOCH=1700000000 (the documented deterministic-pack epoch)
# Namespace unique parts (fixed; one per package).
declare -A nsu=(
  ["$res_proj"]="wantsacracker-extensions-resilience-$version"
  ["$http_proj"]="wantsacracker-extensions-http-resilience-$version"
)

work="$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/opencode-work/wantsacracker-fork-sbom.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The normalization epoch (reproducible-builds convention; the pinned-SDK pack
# targets do not consume it, so it is the documented constant only) and an
# isolated package cache under the scratch policy (same as
# smoke/run-deterministic-pack.sh).
export SOURCE_DATE_EPOCH=1700000000
export NUGET_PACKAGES="$work/nuget"

# --- 1. Install the pinned SBOM tool ----------------------------------------

step "1. Install Microsoft.Sbom.DotNetTool $tool_version (scratch tool path)"
# --add-source: the repo-local SDK's `dotnet tool install` resolves against
# the Arcade dnceng feeds only (no nuget.org), and the pinned tool is on
# nuget.org.
"$dotnet" tool install --tool-path "$work/tools" Microsoft.Sbom.DotNetTool \
  --version "$tool_version" --add-source "https://api.nuget.org/v3/index.json" >/dev/null \
  || fail "installing Microsoft.Sbom.DotNetTool $tool_version from nuget.org failed"
sbom_tool="$work/tools/sbom-tool"
[ -x "$sbom_tool" ] || fail "the sbom-tool executable is missing after the tool install"

# --- 2. Build + pack + unpack: the SBOM input is the shipped file set -------

step "2. Build + pack both fork projects (repo build flow, revision-pinned) and unpack the main nupkgs"
# Clean the two projects' build state (Arcade artifacts layout) so the pack
# is a fresh restore + build + pack of the checked-in state.
rm -rf "artifacts/bin/$res_proj" "artifacts/obj/$res_proj" \
       "artifacts/bin/$http_proj" "artifacts/obj/$http_proj" \
       "artifacts/packages"
# Revision pin (see the header): the SBOM build stamps the all-zeros
# placeholder instead of the git HEAD, so the checked-in SBOMs reproduce
# from any commit (the pack would otherwise embed the HEAD in the nuspec
# <repository commit>, the DLL's OriginalRepoCommitHash, and the PDB's
# SourceLink doc-map URI).
sbom_revision="0000000000000000000000000000000000000000"
# One build.sh call per project: the repo wrapper (eng/build.sh) resolves
# -projects with realpath, which does not accept a semicolon-separated list.
./build.sh -restore -build -c Release -projects "$resilience_src" \
  -p:SourceRevisionId="$sbom_revision" \
  -p:RepoOriginalSourceRevisionId="$sbom_revision" \
  -p:EnableSourceLink=false \
  || fail "build.sh ($res_proj) failed"
./build.sh -restore -build -c Release -projects "$http_src" \
  -p:SourceRevisionId="$sbom_revision" \
  -p:RepoOriginalSourceRevisionId="$sbom_revision" \
  -p:EnableSourceLink=false \
  || fail "build.sh ($http_proj) failed"
"$dotnet" pack "$resilience_src" -c Release --nologo \
  -p:SourceRevisionId="$sbom_revision" \
  -p:RepoOriginalSourceRevisionId="$sbom_revision" \
  -p:EnableSourceLink=false \
  || fail "dotnet pack ($res_proj) failed"
"$dotnet" pack "$http_src" -c Release --nologo \
  -p:SourceRevisionId="$sbom_revision" \
  -p:RepoOriginalSourceRevisionId="$sbom_revision" \
  -p:EnableSourceLink=false \
  || fail "dotnet pack ($http_proj) failed"
for proj in "$res_proj" "$http_proj"; do
  nupkg="artifacts/packages/Release/Shipping/$proj.$version.nupkg"
  [ -f "$nupkg" ] || fail "the pack did not produce $nupkg"
  mkdir -p "$work/drop-$proj"
  unzip -q -o "$nupkg" -d "$work/drop-$proj" || fail "unzipping $nupkg failed"
  echo "$proj pack sha256: $(sha256sum "$nupkg" | cut -d' ' -f1)"
done

# --- 3. Generate the SBOMs with fixed inputs --------------------------------

step "3. Generate the SPDX 2.2 SBOMs (pinned tool $tool_version, fixed timestamp $generation_timestamp)"
for proj in "$res_proj" "$http_proj"; do
  mkdir -p "$work/manifest-$proj"
  "$sbom_tool" generate -b "$work/drop-$proj" -m "$work/manifest-$proj" \
    -pn "$proj" -pv "$version" -ps "WantsACracker contributors" \
    -gt "$generation_timestamp" -nsu "${nsu[$proj]}" >/dev/null 2>&1 \
    || fail "sbom-tool generate failed for $proj"
  # The tool places the SBOM under <ManifestDirPath>/_manifest/spdx_2.2/.
  fresh="$work/manifest-$proj/_manifest/spdx_2.2/manifest.spdx.json"
  [ -f "$fresh" ] || fail "sbom-tool generate did not produce the spdx_2.2 manifest for $proj"
  echo "$proj fresh SBOM sha256: $(sha256sum "$fresh" | cut -d' ' -f1)"
done

# --- 4. Compare against the checked-in SBOMs (or update them) ----------------

# Canonicalize an SBOM: neutralize exactly the six documented
# non-deterministic fields (file order in `files` and the package's
# `hasFiles`; the documentNamespace GUID; the purl tag_id GUID; the psmdcp
# GUID filename; the _rels/.rels content hashes; the derived
# packageVerificationCode) and print canonical JSON on stdout. Two
# generations of the same package are the same SBOM iff their
# canonicalizations are byte-identical.
canonicalize() { # $1 = SBOM json path
  python3 - "$1" <<'PY' || fail "SBOM canonicalization failed for $1"
import json, re, sys
GUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
PSMDCP = r"(./)?package/services/metadata/core-properties/[0-9a-f]{32}\.psmdcp"
ZERO = "00000000-0000-0000-0000-000000000000"
d = json.load(open(sys.argv[1]))
# (4) the psmdcp GUID filename -> the documented canonical name (the file
# content, and hence its checksums, is stable); (5) the _rels/.rels content
# hashes -> zeroed (its content carries the psmdcp GUID relationship line);
# (6) the packageVerificationCode -> zeroed (computed over the raw file
# entries, so it covers the two raw variances above). Both (4) and (5) remap
# the derived file SPDXIDs, which embed the filename / sha1.
remap = {}
for f in d["files"]:
    old = f["SPDXID"]
    if re.fullmatch(PSMDCP, f["fileName"]):
        f["fileName"] = "./package/services/metadata/core-properties/nuget.psmdcp"
        f["SPDXID"] = re.sub(r"core-properties-[0-9a-f]{32}\.psmdcp",
                             "core-properties-nuget.psmdcp", f["SPDXID"])
    elif re.fullmatch(r"(./)?_rels/\.rels", f["fileName"]):
        for c in f["checksums"]:
            c["checksumValue"] = "0" * len(c["checksumValue"])
        f["SPDXID"] = re.sub(r"-[0-9A-F]{40}$", "-" + "0" * 40, f["SPDXID"])
    if f["SPDXID"] != old:
        remap[old] = f["SPDXID"]
d["files"].sort(key=lambda f: f["fileName"])
for p in d.get("packages", []):
    for key in ("hasFiles", "fileReferences"):
        if key in p:
            p[key] = sorted(remap.get(r, r) for r in p[key])
    if "packageVerificationCode" in p:
        p["packageVerificationCode"] = "0" * len(p["packageVerificationCode"])
    for r in p.get("externalRefs", []):
        r["referenceLocator"] = re.sub(r"tag_id=" + GUID, "tag_id=" + ZERO, r.get("referenceLocator", ""))
d["documentNamespace"] = re.sub(GUID, ZERO, d["documentNamespace"])
sys.stdout.write(json.dumps(d, sort_keys=True, indent=2) + "\n")
PY
}

for proj in "$res_proj" "$http_proj"; do
  sbom_path="eng/sbom/$proj-$version.spdx.json"
  fresh="$work/manifest-$proj/_manifest/spdx_2.2/manifest.spdx.json"

  step "4. $proj: $sbom_path"
  if [ "$update" = 1 ]; then
    if [ -f "$sbom_path" ]; then
      echo "replacing checked-in $sbom_path with the fresh raw generation"
    else
      echo "creating checked-in $sbom_path from the fresh raw generation"
    fi
    cp "$fresh" "$sbom_path"
    continue
  fi
  [ -f "$sbom_path" ] || fail "checked-in SBOM $sbom_path is missing — generate it: eng/sbom/generate-sboms.sh --update"
  canonicalize "$fresh" > "$work/fresh-$proj.canon"
  canonicalize "$repo_root/$sbom_path" > "$work/checkedin-$proj.canon"
  fresh_canon_sha="$(sha256sum "$work/fresh-$proj.canon" | cut -d' ' -f1)"
  checkedin_canon_sha="$(sha256sum "$work/checkedin-$proj.canon" | cut -d' ' -f1)"
  echo "checked-in canonical sha256: $checkedin_canon_sha"
  echo "fresh canonical sha256:      $fresh_canon_sha"
  [ "$fresh_canon_sha" = "$checkedin_canon_sha" ] \
    || fail "$sbom_path does NOT reproduce from the checked-in state (canonical sha256 $fresh_canon_sha vs $checkedin_canon_sha) — regenerate the artifact: eng/sbom/generate-sboms.sh --update"
done

if [ "$update" = 1 ]; then
  echo
  echo "SBOM UPDATE PASS: the checked-in artifacts under eng/sbom/ are the fresh raw generations (revision-pinned build variant; pinned tool $tool_version, fixed timestamp; verify with eng/sbom/generate-sboms.sh)."
else
  echo
  echo "SBOM REPRO PASS: the checked-in SBOMs under eng/sbom/ reproduce from the checked-in state (revision-pinned build variant; canonical byte-identity under the pinned tool $tool_version; raw variance limited to the documented fields: the files/hasFiles traversal order, the documentNamespace GUID, the purl tag_id GUID, the psmdcp GUID filename, the _rels/.rels content hashes, and the derived packageVerificationCode)."
fi
