# Flux Release Automation Design

## Summary

Flux will publish a complete Magisk installation ZIP through GitHub Releases.
The source repository will remain free of bundled third-party binaries.

On a pushed Git tag, GitHub Actions will:

- read `version` and `versionCode` from `module.prop`
- verify the pushed tag matches `module.prop`
- download the latest Android release binary for `sing-box`
- build an Android binary for `jq`
- build an Android binary for `addrsyncd`
- assemble a release staging directory with a generated `bin/`
- produce a release ZIP
- create or update a GitHub Release and upload the ZIP

## Goals

- Keep the Git repository clean by excluding release binaries from source control.
- Produce a single installable ZIP suitable for GitHub Releases.
- Use `module.prop` as the canonical source of release version metadata.
- Automate release creation from pushed version tags.
- Make the produced ZIP traceable to the exact upstream binary versions used.

## Non-Goals

- Supporting automatic publishing from branch pushes.
- Supporting local developer packaging without manual dependency preparation.
- Pinning `sing-box` or `jq` to fixed versions in the default workflow.
- Publishing multiple package variants such as `lite` and `full` in the first iteration.

## Trigger Model

The release workflow will trigger only on pushed tags matching the module release format, for example `v1.4.0`.

The workflow must fail early if:

- the pushed tag does not equal `module.prop` `version`
- `module.prop` is missing required fields
- any required upstream binary cannot be resolved
- the final ZIP does not contain the required module payload

## Proposed Files

### `.github/workflows/release.yml`

Responsibilities:

- trigger on `push` to tags
- check out the repository with submodules
- set up the build environment
- read version metadata from `module.prop`
- download latest `sing-box` and `jq` Android binaries
- build `addrsyncd` Android binary
- call the packaging script
- create the GitHub Release and upload the ZIP

### `scripts/package-release.sh`

Responsibilities:

- create an isolated staging directory
- copy release payload files from the repository
- inject generated binaries into `bin/`
- optionally generate or refresh manifest metadata for the binaries
- build the final ZIP with stable layout
- place output in a predictable artifact directory

This script keeps packaging logic out of the workflow YAML and makes local debugging easier.

### `scripts/fetch-release-binaries.sh`

Responsibilities:

- resolve the latest GitHub Release for `sing-box`
- choose the Android-compatible asset
- download and normalize it to `bin/sing-box`
- compute sha256 values
- emit machine-readable metadata for downstream packaging

This script must fail explicitly if the upstream release format changes and no safe asset match is found.

### `scripts/build-third-party-android.sh`

Responsibilities:

- build Android arm64 binaries from source for upstream tools that do not publish suitable Android release assets
- build `jq` from source in the GitHub Actions environment
- build `addrsyncd` from the checked out submodule
- normalize outputs to `bin/jq` and `bin/addrsyncd`
- compute sha256 values and append machine-readable metadata for downstream packaging

## Repository Layout Constraints

The repository will continue to ignore `bin/` in source control.
The release workflow will generate `bin/` only inside a temporary staging or workspace directory.

The source-controlled files copied into the ZIP should include:

- `module.prop`
- `customize.sh`
- `flux_service.sh`
- `webroot/`
- `conf/`
- `scripts/`
- `META-INF/`

The release workflow will add:

- `bin/sing-box`
- `bin/jq`
- `bin/addrsyncd`

## Version Source of Truth

`module.prop` remains the single source of truth for:

- module id
- module name
- version
- versionCode
- author
- description

The workflow will parse `module.prop` directly.
The pushed tag must match the `version` value exactly.

Example:

- tag: `v1.4.0`
- `module.prop`: `version=v1.4.0`

If they differ, the workflow must stop before any release is created.

## Upstream Binary Strategy

### `sing-box`

The workflow will query the latest upstream release and select the Android asset that best matches Flux packaging expectations.
The selected artifact will be extracted or renamed to `bin/sing-box`.

Selection requirements:

- must be Android-targeted
- must contain the executable binary, not only metadata files
- must fail if more than one equally valid asset exists and the script cannot disambiguate safely

### `jq`

The workflow will use the latest upstream source release tag and build an Android arm64 binary in GitHub Actions.

Build requirements:

- must build from the latest upstream source tag
- must target Android arm64 explicitly
- must fail explicitly if the Android build cannot be produced
- must not fall back to a Linux arm64 binary

### Traceability

For `sing-box` and `jq`, the packaging flow will capture:

- upstream repository
- upstream release tag or version
- asset file name
- sha256 of the final packaged executable

This metadata should be surfaced either in:

- generated `conf/manifest.json`
- GitHub Release notes
- or both

## `addrsyncd` Build Strategy

`addrsyncd` is already a git submodule and will be built during the release workflow instead of being committed as a binary.

The workflow will:

- check out submodules
- enter the `addrsyncd` submodule
- build an Android-targeted executable
- copy the resulting binary into the release staging `bin/`

The exact build command depends on the submodule toolchain.
If `addrsyncd` is a Go project, the default target should be Android with the architecture expected by Flux releases.

Build requirements:

- fail fast on compile errors
- ensure the binary is executable
- record the submodule commit used for the build

## Packaging Flow

The packaging script will:

1. Create a clean temporary working directory.
2. Copy only release payload files from the repository.
3. Create `bin/` in the staging directory.
4. Copy in `sing-box`, `jq`, and `addrsyncd`.
5. Set executable permissions for staged binaries and scripts.
6. Optionally refresh `conf/manifest.json` with resolved versions and hashes.
7. Produce a ZIP named from `module.prop`, for example `flux-v1.4.0.zip`.

The ZIP must preserve the expected Magisk installer layout.

## Release Notes

The workflow should generate concise release notes containing:

- Flux version and versionCode
- source tag
- `sing-box` upstream version
- `jq` upstream version
- `addrsyncd` submodule commit

This keeps dynamic dependency resolution auditable even though the repository stays binary-free.

## Error Handling

The workflow must treat the following as hard failures:

- tag and `module.prop` version mismatch
- failed `sing-box` download
- failed `jq` download
- ambiguous upstream asset selection
- failed `addrsyncd` build
- missing required files in the final ZIP
- failed GitHub Release upload

The workflow should emit clear logs identifying which stage failed.

## Security and Reproducibility Notes

Following latest upstream releases increases convenience but reduces strict reproducibility.
To compensate, the workflow will record the resolved upstream versions and hashes in the release output.

This design intentionally optimizes for:

- clean source control
- low maintenance overhead
- transparent release provenance

If stronger reproducibility is needed later, the workflow can evolve to allow pinned versions through repository variables without changing the overall packaging design.

## Testing Strategy

Before relying on the workflow for production releases, validate:

- a dry-run tag in a test repository or branch namespace
- successful binary resolution for `sing-box`
- successful `jq` Android build from source
- successful `addrsyncd` Android build
- final ZIP structure matches installer expectations
- extracted ZIP contains executable files under `bin/`

## Implementation Plan Preview

Implementation should proceed in this order:

1. Add release packaging shell script.
2. Add Android source-build script for `jq` and `addrsyncd`.
3. Add GitHub Actions release workflow.
4. Update README documentation for release packaging behavior.
5. Validate workflow assumptions against `jq` and `addrsyncd` build requirements.

## Open Decisions Resolved

The following decisions are fixed by user direction:

- publish artifact: GitHub Release ZIP installation package
- release trigger: pushed tags
- version source: `module.prop`
- upstream dependency strategy: latest `sing-box` release plus latest `jq` source tag
- `jq` strategy: build Android binary in GitHub Actions
- `addrsyncd` strategy: build Android binary in GitHub Actions
