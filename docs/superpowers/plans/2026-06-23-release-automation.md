# Flux Release Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate GitHub Release ZIP packaging for Flux so pushed tags build a complete Magisk module archive with a downloaded `sing-box` Android binary plus Actions-built `jq` and `addrsyncd` Android binaries.

**Architecture:** Add repository-owned shell scripts to separate release-asset fetching, third-party Android builds, and packaging, then wire them into a tag-triggered GitHub Actions workflow. The workflow will validate `module.prop`, fetch `sing-box`, build `jq` and `addrsyncd`, package the ZIP in a clean staging directory, and publish it as a GitHub Release.

**Tech Stack:** GitHub Actions, POSIX shell, curl, jq (runner-side), zip/unzip, GitHub Releases API, existing Flux repository layout

---

## File Structure

- Modify: [README.md](D:/git/Flux/README.md:1)  
  Document that source control does not include release binaries and that official ZIPs are assembled in GitHub Actions.

- Modify: [README_zh.md](D:/git/Flux/README_zh.md:1)  
  Mirror the release-packaging documentation changes in Chinese.

- Modify: [conf/manifest.json](D:/git/Flux/conf/manifest.json:1)  
  Align binary metadata semantics with Actions-generated packaging output.

- Create: [.github/workflows/release.yml](D:/git/Flux/.github/workflows/release.yml:1)  
  Tag-triggered release workflow that validates module version, resolves dependencies, builds `addrsyncd`, packages the ZIP, and publishes the release.

- Create: [scripts/fetch-release-binaries.sh](D:/git/Flux/scripts/fetch-release-binaries.sh:1)  
  Download the latest Android binary for `sing-box`, normalize it into a staging `bin/`, and emit metadata for packaging.

- Create: [scripts/build-third-party-android.sh](D:/git/Flux/scripts/build-third-party-android.sh:1)  
  Build Android binaries for `jq` and `addrsyncd` and append metadata for packaging.

- Create: [scripts/package-release.sh](D:/git/Flux/scripts/package-release.sh:1)  
  Build a clean Magisk module ZIP from repository files plus generated binaries.

- Optional modify: [module.prop](D:/git/Flux/module.prop:1)  
  Only if packaging needs additional metadata normalization; otherwise leave untouched.

## Task 1: Define the Workflow Contract

**Files:**
- Create: [docs/superpowers/plans/2026-06-23-release-automation.md](D:/git/Flux/docs/superpowers/plans/2026-06-23-release-automation.md:1)
- Modify later: [.github/workflows/release.yml](D:/git/Flux/.github/workflows/release.yml:1)
- Modify later: [scripts/fetch-release-binaries.sh](D:/git/Flux/scripts/fetch-release-binaries.sh:1)
- Modify later: [scripts/package-release.sh](D:/git/Flux/scripts/package-release.sh:1)

- [ ] **Step 1: Inspect current repository packaging assumptions**

Run: `rg -n "bin/|manifest.json|module.prop|zip|release|sing-box|jq|addrsyncd" README.md README_zh.md customize.sh scripts conf -S`
Expected: references showing that `bin/` is required at install/package time and that `module.prop` is the current metadata source.

- [ ] **Step 2: Write down the environment contract for the workflow**

Document these contract points in implementation notes before coding:

```text
Trigger: push tag matching v*
Version source: module.prop
Release artifact: one installable ZIP
Source repo policy: no checked-in bin/
Dynamic inputs: latest sing-box release, latest jq source tag, current addrsyncd submodule commit
Hard failures: version mismatch, missing assets, failed jq/addrsyncd build, malformed ZIP
```

- [ ] **Step 3: Confirm submodule checkout is mandatory**

Run: `Get-Content .gitmodules`
Expected: `addrsyncd` submodule entry is present, so workflow must use submodule checkout.

- [ ] **Step 4: Commit the planning context when implementation starts**

```bash
git add docs/superpowers/specs/2026-06-23-release-automation-design.md docs/superpowers/plans/2026-06-23-release-automation.md
git commit -m "docs: add release automation spec and plan"
```

## Task 2: Add the `sing-box` Release Fetch Script

**Files:**
- Create: [scripts/fetch-release-binaries.sh](D:/git/Flux/scripts/fetch-release-binaries.sh:1)
- Test: local shell invocation against a temporary output directory

- [ ] **Step 1: Write the failing script usage contract**

Create the script with an argument parser that requires:

```sh
#!/system/bin/sh
set -eu
[ -n "${BASH_VERSION:-}" ] && set -o pipefail

usage() {
    echo "Usage: $0 --output-dir DIR --metadata-file FILE"
    exit 1
}

OUTPUT_DIR=""
METADATA_FILE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
    --output-dir)
        OUTPUT_DIR="${2:-}"
        shift 2
        ;;
    --metadata-file)
        METADATA_FILE="${2:-}"
        shift 2
        ;;
    *)
        usage
        ;;
    esac
done

[ -n "${OUTPUT_DIR}" ] || usage
[ -n "${METADATA_FILE}" ] || usage
```

- [ ] **Step 2: Run the script with missing args to verify it fails**

Run: `sh scripts/fetch-release-binaries.sh`
Expected: non-zero exit and `Usage:` output.

- [ ] **Step 3: Implement minimal GitHub release resolution helpers**

Extend the script with:

```sh
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing command: $1" >&2
        exit 1
    }
}

github_latest_release_json() {
    repo="${1}"
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest"
}

json_field() {
    jq -r "${2}" "${1}"
}
```

- [ ] **Step 4: Implement asset selection for `sing-box`**

Add a function that chooses exactly one asset name from the latest release JSON:

```sh
select_singbox_asset() {
    json_file="${1}"
    jq -r '
        [
            .assets[]
            | select(.name | test("android"; "i"))
            | select(.name | test("arm64|aarch64"; "i"))
            | select(.name | test("\\.(tar\\.gz|tgz|zip)$"; "i"))
        ] | if length == 1 then .[0].browser_download_url else "" end
    ' "${json_file}"
}
```

- [ ] **Step 5: Remove `jq` from this script's responsibilities**

Constrain this script to `sing-box` only.
Do not download or normalize `jq` here.

- [ ] **Step 6: Implement download and normalization logic**

Add functions that:

```sh
download_file() {
    url="${1}"
    out="${2}"
    curl -fsSL "${url}" -o "${out}"
}

sha256_file() {
    sha256sum "${1}" | awk '{print $1}'
}
```

Then normalize output files to:

```text
${OUTPUT_DIR}/sing-box
```

If an archive is downloaded, extract the expected executable and rename it.

- [ ] **Step 7: Emit metadata for packaging**

Write a simple metadata file format:

```text
SING_BOX_REPO=SagerNet/sing-box
SING_BOX_VERSION=<resolved-tag>
SING_BOX_SHA256=<sha>
```

- [ ] **Step 8: Run the fetch script to verify it fails safely on ambiguous assets**

Run: `sh scripts/fetch-release-binaries.sh --output-dir .tmp/bin --metadata-file .tmp/binaries.env`
Expected: either successful output with a normalized `sing-box` binary, or a clear non-zero error explaining that asset selection was ambiguous or missing.

- [ ] **Step 9: Commit**

```bash
git add scripts/fetch-release-binaries.sh
git commit -m "build: add sing-box release fetch script"
```

## Task 3: Add the Third-Party Android Build Script

**Files:**
- Create: [scripts/build-third-party-android.sh](D:/git/Flux/scripts/build-third-party-android.sh:1)
- Test: local shell invocation for usage contract and syntax

- [ ] **Step 1: Write the failing build script usage contract**

Create a script that requires:

```sh
#!/system/bin/sh
set -eu
[ -n "${BASH_VERSION:-}" ] && set -o pipefail

usage() {
    echo "Usage: $0 --output-dir DIR --metadata-file FILE --jq-tag TAG --addrsyncd-dir DIR"
    exit 1
}
```

- [ ] **Step 2: Run the script with missing args to verify it fails**

Run: `sh scripts/build-third-party-android.sh`
Expected: non-zero exit and `Usage:` output.

- [ ] **Step 3: Implement `jq` source build flow**

Add logic that:

```text
- downloads jq source tarball for a specific upstream tag
- prepares an Android-capable build environment
- configures/builds jq for Android arm64
- writes normalized output to ${OUTPUT_DIR}/jq
```

The script must fail rather than falling back to `jq-linux-arm64`.

- [ ] **Step 4: Implement `addrsyncd` Android build flow**

Add logic that:

```text
- inspects ${ADDRSYNCD_DIR} for supported build layout
- builds Android arm64 output
- writes normalized output to ${OUTPUT_DIR}/addrsyncd
```

If the submodule build layout is unsupported, fail with a clear error.

- [ ] **Step 5: Append metadata for built binaries**

Write or append fields like:

```text
JQ_REPO=jqlang/jq
JQ_VERSION=<resolved-tag>
JQ_SHA256=<sha>
ADDRSYNCD_SOURCE=<repo-or-submodule-path>
ADDRSYNCD_VERSION=<submodule-commit>
ADDRSYNCD_SHA256=<sha>
```

- [ ] **Step 6: Run syntax verification**

Run: `sh -n scripts/build-third-party-android.sh`
Expected: exit code `0`.

- [ ] **Step 7: Commit**

```bash
git add scripts/build-third-party-android.sh
git commit -m "build: add android source build script"
```

## Task 4: Add the Release Packaging Script

**Files:**
- Create: [scripts/package-release.sh](D:/git/Flux/scripts/package-release.sh:1)
- Modify: [conf/manifest.json](D:/git/Flux/conf/manifest.json:1)
- Test: local shell invocation against a temporary staging directory

- [ ] **Step 1: Write the failing packaging script usage contract**

Create a script skeleton:

```sh
#!/system/bin/sh
set -eu
[ -n "${BASH_VERSION:-}" ] && set -o pipefail

usage() {
    echo "Usage: $0 --repo-root DIR --bin-dir DIR --metadata-file FILE --output-dir DIR"
    exit 1
}
```

- [ ] **Step 2: Run the packaging script with missing args to verify it fails**

Run: `sh scripts/package-release.sh`
Expected: non-zero exit and `Usage:` output.

- [ ] **Step 3: Implement `module.prop` parsing**

Add a parser that reads:

```sh
module_prop_value() {
    key="${1}"
    awk -F= -v k="${key}" '$1 == k {print substr($0, index($0, "=") + 1)}' module.prop
}
```

Capture:

```text
id
version
versionCode
name
```

- [ ] **Step 4: Implement clean staging copy**

Copy only:

```text
META-INF/
conf/
scripts/
webroot/
module.prop
customize.sh
flux_service.sh
```

Into:

```text
${STAGE_DIR}/
```

Then create:

```text
${STAGE_DIR}/bin/
```

And copy in:

```text
${BIN_DIR}/sing-box
${BIN_DIR}/jq
${BIN_DIR}/addrsyncd
```

- [ ] **Step 5: Refresh manifest metadata**

Modify [conf/manifest.json](D:/git/Flux/conf/manifest.json:1) generation expectations so the script can update:

```json
{
  "name": "sing-box",
  "path": "bin/sing-box",
  "source": "https://github.com/SagerNet/sing-box",
  "version": "<resolved-version>",
  "target": "android",
  "sha256": "<resolved-sha256>"
}
```

Do the same for `jq` and `addrsyncd`.

- [ ] **Step 6: Implement ZIP assembly**

Produce:

```text
${OUTPUT_DIR}/flux-${VERSION}.zip
```

Using a clean working directory so the final archive root matches Magisk expectations.

- [ ] **Step 7: Add structural verification**

After ZIP creation, verify it contains:

```text
module.prop
customize.sh
flux_service.sh
bin/sing-box
bin/jq
bin/addrsyncd
scripts/fluxctl
conf/settings.ini
```

Fail if any are missing.

- [ ] **Step 8: Run the packaging script to verify expected failure before binaries exist**

Run: `sh scripts/package-release.sh --repo-root . --bin-dir .tmp/bin --metadata-file .tmp/binaries.env --output-dir .tmp/out`
Expected: non-zero exit with a clear error about whichever staged dependency is still absent.

- [ ] **Step 9: Commit**

```bash
git add scripts/package-release.sh conf/manifest.json
git commit -m "build: add release packaging script"
```

## Task 5: Add the GitHub Actions Release Workflow

**Files:**
- Create: [.github/workflows/release.yml](D:/git/Flux/.github/workflows/release.yml:1)
- Test: workflow YAML validation by inspection and later GitHub run

- [ ] **Step 1: Write the workflow trigger and checkout steps**

Add:

```yaml
name: Release

on:
  push:
    tags:
      - "v*"
```

And:

```yaml
- uses: actions/checkout@v4
  with:
    submodules: recursive
```

- [ ] **Step 2: Add version validation from `module.prop`**

Add a shell step that exports:

```sh
VERSION=$(awk -F= '$1=="version"{print $2}' module.prop)
VERSION_CODE=$(awk -F= '$1=="versionCode"{print $2}' module.prop)
TAG_NAME="${GITHUB_REF_NAME}"
[ "${TAG_NAME}" = "${VERSION}" ] || {
    echo "Tag ${TAG_NAME} does not match module.prop version ${VERSION}" >&2
    exit 1
}
```

- [ ] **Step 3: Add runner dependencies**

Install runner tools needed for release packaging:

```yaml
- name: Install tooling
  run: |
    sudo apt-get update
    sudo apt-get install -y jq zip unzip
```

- [ ] **Step 4: Add `sing-box` fetch step**

Invoke:

```yaml
- name: Fetch sing-box release binary
  run: |
    mkdir -p .release/bin .release/meta
    sh scripts/fetch-release-binaries.sh \
      --output-dir .release/bin \
      --metadata-file .release/meta/binaries.env
```

- [ ] **Step 5: Add `jq` and `addrsyncd` build step**

Invoke the build script with the resolved `jq` tag and checked-out submodule path.

- [ ] **Step 6: Add ZIP packaging step**

Invoke:

```yaml
- name: Package release ZIP
  run: |
    mkdir -p .release/out
    sh scripts/package-release.sh \
      --repo-root . \
      --bin-dir .release/bin \
      --metadata-file .release/meta/binaries.env \
      --output-dir .release/out
```

- [ ] **Step 7: Add release notes generation**

Generate a notes file containing:

```text
Flux version: <version>
VersionCode: <versionCode>
Tag: <tag>
sing-box: <resolved version>
jq: <resolved version>
addrsyncd commit: <submodule commit>
```

- [ ] **Step 8: Add GitHub Release publish step**

Use:

```yaml
- name: Publish release
  uses: softprops/action-gh-release@v2
  with:
    files: .release/out/*.zip
    body_path: .release/meta/release-notes.txt
```

- [ ] **Step 9: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add tag-driven release workflow"
```

## Task 6: Update User-Facing Documentation

**Files:**
- Modify: [README.md](D:/git/Flux/README.md:1)
- Modify: [README_zh.md](D:/git/Flux/README_zh.md:1)

- [ ] **Step 1: Add release packaging documentation to `README.md`**

Document:

```text
- source repo does not include bin/
- official release ZIPs are generated by GitHub Actions
- release workflow downloads the latest sing-box Android binary
- release workflow builds jq and addrsyncd Android binaries
- pushed version tags publish GitHub Release ZIPs
```

- [ ] **Step 2: Add equivalent documentation to `README_zh.md`**

Mirror the same points in Chinese.

- [ ] **Step 3: Verify README updates are consistent with `conf/manifest.json`**

Run: `rg -n "lite|full|bin/|Release|Actions|GitHub Release" README.md README_zh.md conf/manifest.json -S`
Expected: wording reflects the new release packaging behavior and does not claim binaries live in source control.

- [ ] **Step 4: Commit**

```bash
git add README.md README_zh.md
git commit -m "docs: explain release packaging workflow"
```

## Task 7: Verify the End-to-End Packaging Path

**Files:**
- Test: [scripts/fetch-release-binaries.sh](D:/git/Flux/scripts/fetch-release-binaries.sh:1)
- Test: [scripts/package-release.sh](D:/git/Flux/scripts/package-release.sh:1)
- Test: [.github/workflows/release.yml](D:/git/Flux/.github/workflows/release.yml:1)

- [ ] **Step 1: Run the fetch script successfully**

Run: `sh scripts/fetch-release-binaries.sh --output-dir .release/bin --metadata-file .release/meta/binaries.env`
Expected: normalized `sing-box` binary plus metadata.

- [ ] **Step 2: Build `jq` and `addrsyncd` locally if toolchain is available**

Run the same build script used by the workflow.
Expected: `.release/bin/jq` and `.release/bin/addrsyncd` are created and executable.

- [ ] **Step 3: Run the packaging script successfully**

Run: `sh scripts/package-release.sh --repo-root . --bin-dir .release/bin --metadata-file .release/meta/binaries.env --output-dir .release/out`
Expected: `flux-<version>.zip` exists and passes structural verification.

- [ ] **Step 4: Inspect ZIP contents**

Run: `unzip -l .release/out/flux-*.zip`
Expected: required Magisk layout with `bin/sing-box`, `bin/jq`, and `bin/addrsyncd`.

- [ ] **Step 5: Review workflow references**

Run: `rg -n "fetch-release-binaries|build-third-party-android|package-release|action-gh-release|submodules: recursive|module.prop" .github/workflows/release.yml scripts -S`
Expected: workflow and scripts are wired consistently.

- [ ] **Step 6: Commit final implementation**

```bash
git add .github/workflows/release.yml scripts/fetch-release-binaries.sh scripts/build-third-party-android.sh scripts/package-release.sh README.md README_zh.md conf/manifest.json
git commit -m "feat: automate GitHub release packaging"
```

## Self-Review

- Spec coverage check:
  - tag-triggered release: covered in Task 4
  - `module.prop` as version source: covered in Task 4 and Task 3
  - dynamic `sing-box` resolution: covered in Task 2
  - `jq` Android source build: covered in Task 3, Task 5, and Task 7
  - `addrsyncd` Android build: covered in Task 3, Task 5, and Task 7
  - clean source repo without committed `bin/`: covered in Task 4, Task 5, and Task 6
  - GitHub Release ZIP artifact: covered in Task 4, Task 5, and Task 7

- Placeholder scan:
  - one guarded unknown remains: the exact `jq` Android toolchain setup and `addrsyncd` build entrypoint must be verified after implementation because local submodule contents are not present in this workspace yet
  - the plan explicitly contains the detection step and failure behavior instead of hand-waving over it

- Type and naming consistency:
  - workflow script names are consistent across all tasks
  - metadata file path `.release/meta/binaries.env` is consistent across fetch, package, and release tasks
  - output ZIP naming uses `flux-${VERSION}.zip` consistently
