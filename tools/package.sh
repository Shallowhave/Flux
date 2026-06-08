#!/usr/bin/env bash

# ==============================================================================
# Flux release packager
# ==============================================================================
# Builds a Magisk/KernelSU/APatch-installable zip:
#
#   1. Compile addrsyncd (Rust submodule) for aarch64-linux-android.
#   2. Download latest sing-box (android-arm64) from GitHub releases.
#   3. Download latest jq (linux-arm64 static) from GitHub releases.
#   4. Verify SHA-256 of every downloaded binary against the upstream sum file.
#   5. Stage bin/ + conf/ + scripts/ + module.prop + customize.sh + META-INF.
#   6. Emit dist/flux-<version>.zip.
#
# Outputs are reproducible given pinned versions; the manifest at
# conf/manifest.json is rewritten in-zip with the resolved versions and
# SHA-256s so downstream consumers can verify provenance.
#
# Defaults target arm64 only (matches addrsyncd's rust-toolchain.toml pin).
# Bash is required for arrays and `set -o pipefail`; POSIX-only sh is too
# painful for the URL/JSON wrangling and offers no actual portability win
# (every modern dev host has bash).
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Paths and metadata
# ------------------------------------------------------------------------------

# Walk up from tools/ to the repo root regardless of cwd.
_self="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd "${_self}/.." && pwd -P)"
unset _self

readonly ADDRSYNCD_DIR="${REPO_ROOT}/addrsyncd"
readonly ADDRSYNCD_TARGET="aarch64-linux-android"
readonly STAGE_DIR_DEFAULT="${REPO_ROOT}/dist/stage"
readonly OUT_DIR_DEFAULT="${REPO_ROOT}/dist"

# Extracted from module.prop so version is single-sourced.
_module_prop="${REPO_ROOT}/module.prop"
[ -f "${_module_prop}" ] || { echo "fatal: ${_module_prop} missing" >&2; exit 2; }
MODULE_VERSION="$(awk -F= '$1=="version"{print $2; exit}' "${_module_prop}")"
MODULE_ID="$(awk -F= '$1=="id"{print $2; exit}' "${_module_prop}")"
unset _module_prop

# ------------------------------------------------------------------------------
# Flags
# ------------------------------------------------------------------------------

SINGBOX_VERSION=""             # empty = resolve "latest"
JQ_VERSION=""
SKIP_ADDRSYNCD_BUILD=0
SKIP_FETCH=0
LITE_PROFILE=0
OUT_DIR="${OUT_DIR_DEFAULT}"
KEEP_STAGE=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

  --singbox-version VER   Pin sing-box version (e.g. v1.10.4). Default: latest.
  --jq-version VER        Pin jq version (e.g. jq-1.7.1). Default: latest.
  --no-addrsyncd-build    Reuse \${addrsyncd}/target/${ADDRSYNCD_TARGET}/release/addrsyncd
                          instead of running cargo build.
  --no-fetch              Reuse already-staged bin/sing-box and bin/jq under
                          dist/stage/bin instead of downloading. Useful for
                          offline builds.
  --lite                  Produce a lite zip without bin/. User supplies the
                          binaries (per conf/manifest.json "lite" profile).
  --out-dir DIR           Output directory. Default: ${OUT_DIR_DEFAULT}.
  --keep-stage            Leave dist/stage on disk after packaging (debugging).
  -h, --help              This help.

Required tools on PATH: bash, curl, jq, sha256sum, tar, unzip, zip.
Addrsyncd build additionally requires: rustup, cargo, and the Android NDK
clang linker (\${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/<host>/bin in PATH).
USAGE
}

while [ $# -gt 0 ]; do
    case "${1:-}" in
        --singbox-version) SINGBOX_VERSION="$2"; shift 2 ;;
        --jq-version)      JQ_VERSION="$2";      shift 2 ;;
        --no-addrsyncd-build) SKIP_ADDRSYNCD_BUILD=1; shift ;;
        --no-fetch)        SKIP_FETCH=1;            shift ;;
        --lite)            LITE_PROFILE=1;          shift ;;
        --out-dir)         OUT_DIR="$2";            shift 2 ;;
        --keep-stage)      KEEP_STAGE=1;            shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 echo "unknown flag: $1" >&2; usage; exit 2 ;;
    esac
done

# ------------------------------------------------------------------------------
# Pretty output
# ------------------------------------------------------------------------------

if [ -t 1 ]; then
    _bold=$'\033[1m'; _dim=$'\033[2m'; _red=$'\033[31m'; _grn=$'\033[32m'; _rst=$'\033[0m'
else
    _bold=""; _dim=""; _red=""; _grn=""; _rst=""
fi
log() { printf '%s==>%s %s\n' "${_bold}" "${_rst}" "$*"; }
note() { printf '    %s%s%s\n' "${_dim}" "$*" "${_rst}"; }
ok()  { printf '    %sok%s %s\n' "${_grn}" "${_rst}" "$*"; }
die() { printf '%s!!%s %s\n' "${_red}" "${_rst}" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Tool checks
# ------------------------------------------------------------------------------

require() {
    command -v "$1" >/dev/null 2>&1 || die "required tool not on PATH: $1"
}

log "Checking host toolchain"
for t in curl jq sha256sum tar unzip zip awk sed; do
    require "$t"
done
if [ "${SKIP_ADDRSYNCD_BUILD}" -eq 0 ] && [ "${LITE_PROFILE}" -eq 0 ]; then
    require cargo
    require rustup
fi
ok "host tools present"

# ------------------------------------------------------------------------------
# Version resolution
# ------------------------------------------------------------------------------

resolve_latest() {
    # arg1: owner/repo. Echoes tag name on stdout.
    local repo="$1"
    local api="https://api.github.com/repos/${repo}/releases/latest"
    local headers=()
    [ -n "${GITHUB_TOKEN:-}" ] && headers=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    curl -fsSL "${headers[@]}" "${api}" | jq -r '.tag_name'
}

if [ "${LITE_PROFILE}" -eq 0 ] && [ "${SKIP_FETCH}" -eq 0 ]; then
    log "Resolving upstream versions"
    if [ -z "${SINGBOX_VERSION}" ]; then
        SINGBOX_VERSION="$(resolve_latest SagerNet/sing-box)" \
            || die "failed to resolve sing-box latest release"
        ok "sing-box latest: ${SINGBOX_VERSION}"
    else
        note "sing-box pinned: ${SINGBOX_VERSION}"
    fi
    if [ -z "${JQ_VERSION}" ]; then
        JQ_VERSION="$(resolve_latest jqlang/jq)" \
            || die "failed to resolve jq latest release"
        ok "jq latest: ${JQ_VERSION}"
    else
        note "jq pinned: ${JQ_VERSION}"
    fi
fi

# ------------------------------------------------------------------------------
# Stage directory layout (matches what customize.sh extracts)
# ------------------------------------------------------------------------------

STAGE_DIR="${STAGE_DIR_DEFAULT}"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}" "${OUT_DIR}"

# ------------------------------------------------------------------------------
# addrsyncd build
# ------------------------------------------------------------------------------

ADDRSYNCD_BIN_SRC="${ADDRSYNCD_DIR}/target/${ADDRSYNCD_TARGET}/release/addrsyncd"

if [ "${LITE_PROFILE}" -eq 0 ]; then
    if [ "${SKIP_ADDRSYNCD_BUILD}" -eq 0 ]; then
        log "Building addrsyncd (${ADDRSYNCD_TARGET})"
        if ! ls "${ADDRSYNCD_DIR}/Cargo.toml" >/dev/null 2>&1; then
            die "addrsyncd submodule missing — run: git submodule update --init --recursive"
        fi
        # Verify NDK linker is reachable. cargo would surface a cryptic
        # error otherwise; fail fast with an actionable message.
        if ! command -v aarch64-linux-android21-clang >/dev/null 2>&1; then
            die "aarch64-linux-android21-clang not in PATH. Set up Android NDK:
    export ANDROID_NDK_HOME=/path/to/android-ndk
    export PATH=\"\$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin:\$PATH\"
(swap linux-x86_64 for your NDK host triple)"
        fi
        rustup target add "${ADDRSYNCD_TARGET}" >/dev/null 2>&1 || true
        ( cd "${ADDRSYNCD_DIR}" && cargo build --release --target "${ADDRSYNCD_TARGET}" )
        ok "addrsyncd compiled"
    else
        note "addrsyncd build skipped per --no-addrsyncd-build"
        [ -x "${ADDRSYNCD_BIN_SRC}" ] || die "no prebuilt addrsyncd at ${ADDRSYNCD_BIN_SRC}"
    fi
fi

# ------------------------------------------------------------------------------
# Binary fetch helpers
# ------------------------------------------------------------------------------

# Download a URL with retries and write to $1 ($2). On failure, $1 is removed.
fetch() {
    local url="$1" out="$2"
    local headers=()
    [ -n "${GITHUB_TOKEN:-}" ] && headers=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    if ! curl -fsSL --retry 3 --retry-delay 2 "${headers[@]}" "${url}" -o "${out}"; then
        rm -f "${out}"
        die "fetch failed: ${url}"
    fi
}

# Compute sha256 of $1, echo hex.
sha() { sha256sum "$1" | awk '{print $1}'; }

# Pull a row from a SHA256SUMS-style file. $1 = sums file, $2 = filename.
expected_sha() {
    awk -v want="$2" '$2==want || $2=="*"want {print $1; exit}' "$1"
}

# ------------------------------------------------------------------------------
# sing-box (android-arm64)
# ------------------------------------------------------------------------------
# Asset names:
#   sing-box-<ver-trimmed>-android-arm64.tar.gz
# SHA256 lives in the same release as a single sums file. Older releases used
# .sha256 sidecars; we tolerate either by looking up the right asset URL via
# the releases API.
# ------------------------------------------------------------------------------

stage_singbox() {
    local ver="${SINGBOX_VERSION#v}"  # strip leading v for the asset name
    local tarball="sing-box-${ver}-android-arm64.tar.gz"
    local dl="${STAGE_DIR}/.dl/${tarball}"
    local sums="${STAGE_DIR}/.dl/sing-box-${ver}.sha256sums"

    mkdir -p "${STAGE_DIR}/.dl"

    log "Fetching sing-box ${SINGBOX_VERSION}"
    local api="https://api.github.com/repos/SagerNet/sing-box/releases/tags/${SINGBOX_VERSION}"
    local rel_json="${STAGE_DIR}/.dl/sing-box-release.json"
    local headers=()
    [ -n "${GITHUB_TOKEN:-}" ] && headers=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    curl -fsSL "${headers[@]}" "${api}" -o "${rel_json}" \
        || die "no sing-box release for tag ${SINGBOX_VERSION}"

    local tarball_url sums_url
    tarball_url="$(jq -r --arg n "${tarball}" \
        '.assets[] | select(.name==$n) | .browser_download_url' "${rel_json}")"
    [ -n "${tarball_url}" ] && [ "${tarball_url}" != "null" ] \
        || die "asset not found in release: ${tarball}"

    # Prefer the consolidated sums file; fall back to per-file .sha256.
    sums_url="$(jq -r '.assets[] | select(.name|test("sha256sums?$";"i")) | .browser_download_url' \
        "${rel_json}" | head -n1)"
    if [ -z "${sums_url}" ] || [ "${sums_url}" = "null" ]; then
        sums_url="${tarball_url}.sha256"
    fi

    fetch "${tarball_url}" "${dl}"
    fetch "${sums_url}" "${sums}"

    local want got
    want="$(expected_sha "${sums}" "${tarball}")"
    [ -n "${want}" ] || die "no sha256 entry for ${tarball} in sums file"
    got="$(sha "${dl}")"
    [ "${want}" = "${got}" ] || die "sing-box sha256 mismatch: want=${want} got=${got}"
    ok "sing-box sha256 verified"

    # Extract just the binary; the upstream tarball nests under
    # sing-box-<ver>-android-arm64/sing-box.
    tar -xzf "${dl}" -C "${STAGE_DIR}/.dl"
    local extracted="${STAGE_DIR}/.dl/sing-box-${ver}-android-arm64/sing-box"
    [ -x "${extracted}" ] || die "sing-box not found in tarball at ${extracted}"
    install -m 0755 "${extracted}" "${STAGE_DIR}/bin/sing-box"
    SINGBOX_BIN_SHA="$(sha "${STAGE_DIR}/bin/sing-box")"
}

# ------------------------------------------------------------------------------
# jq (linux-arm64 static — bionic-compatible)
# ------------------------------------------------------------------------------
# jqlang ships statically-linked linux-arm64 binaries since v1.7. They run on
# Android arm64 (bionic) because they're musl-static — no libc resolution at
# runtime. Confirmed by the box4magisk / similar projects which ship the same
# binary on Magisk modules.
# ------------------------------------------------------------------------------

stage_jq() {
    local asset="jq-linux-arm64"
    local dl="${STAGE_DIR}/.dl/${asset}"
    local sums="${STAGE_DIR}/.dl/jq-${JQ_VERSION}.sha256sums"

    mkdir -p "${STAGE_DIR}/.dl"

    log "Fetching jq ${JQ_VERSION}"
    local api="https://api.github.com/repos/jqlang/jq/releases/tags/${JQ_VERSION}"
    local rel_json="${STAGE_DIR}/.dl/jq-release.json"
    local headers=()
    [ -n "${GITHUB_TOKEN:-}" ] && headers=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    curl -fsSL "${headers[@]}" "${api}" -o "${rel_json}" \
        || die "no jq release for tag ${JQ_VERSION}"

    local asset_url sums_url
    asset_url="$(jq -r --arg n "${asset}" \
        '.assets[] | select(.name==$n) | .browser_download_url' "${rel_json}")"
    [ -n "${asset_url}" ] && [ "${asset_url}" != "null" ] \
        || die "asset not found in release: ${asset}"
    sums_url="$(jq -r '.assets[] | select(.name=="sha256sum.txt" or .name=="SHA256SUMS") | .browser_download_url' \
        "${rel_json}" | head -n1)"
    [ -n "${sums_url}" ] && [ "${sums_url}" != "null" ] \
        || die "jq release has no sha256 sums file — refusing to ship unverified binary"

    fetch "${asset_url}" "${dl}"
    fetch "${sums_url}" "${sums}"

    local want got
    want="$(expected_sha "${sums}" "${asset}")"
    [ -n "${want}" ] || die "no sha256 entry for ${asset} in sums file"
    got="$(sha "${dl}")"
    [ "${want}" = "${got}" ] || die "jq sha256 mismatch: want=${want} got=${got}"
    ok "jq sha256 verified"

    install -m 0755 "${dl}" "${STAGE_DIR}/bin/jq"
    JQ_BIN_SHA="$(sha "${STAGE_DIR}/bin/jq")"
}

# ------------------------------------------------------------------------------
# Stage bin/
# ------------------------------------------------------------------------------

ADDRSYNCD_SHA=""
SINGBOX_BIN_SHA=""
JQ_BIN_SHA=""

if [ "${LITE_PROFILE}" -eq 0 ]; then
    mkdir -p "${STAGE_DIR}/bin"

    if [ "${SKIP_FETCH}" -eq 0 ]; then
        stage_singbox
        stage_jq
    else
        note "binary fetch skipped per --no-fetch"
        for f in sing-box jq; do
            [ -x "${STAGE_DIR}/bin/${f}" ] \
                || die "--no-fetch requires bin/${f} prestaged in ${STAGE_DIR}/bin/"
        done
        SINGBOX_BIN_SHA="$(sha "${STAGE_DIR}/bin/sing-box")"
        JQ_BIN_SHA="$(sha "${STAGE_DIR}/bin/jq")"
    fi

    install -m 0755 "${ADDRSYNCD_BIN_SRC}" "${STAGE_DIR}/bin/addrsyncd"
    ADDRSYNCD_SHA="$(sha "${STAGE_DIR}/bin/addrsyncd")"
    ok "bin/ staged (addrsyncd ${ADDRSYNCD_SHA:0:12}…)"
else
    note "lite profile — skipping bin/"
fi

# ------------------------------------------------------------------------------
# Stage scripts/, conf/, module root files
# ------------------------------------------------------------------------------

log "Staging module tree"

# scripts/ — exclude any host-side tooling we may add later under scripts/.
# Today the on-device set is the entire directory; if we ever add scripts/dev/
# or similar we should extend this rsync include list.
mkdir -p "${STAGE_DIR}/scripts"
for f in addrsync config core dispatcher fluxctl init lib log rules tproxy updater.sh; do
    install -m 0755 "${REPO_ROOT}/scripts/${f}" "${STAGE_DIR}/scripts/${f}"
done

# conf/ — ship template, addrsyncd config, and the regenerated manifest.
# settings.ini is shipped as-is; customize.sh migrates the user's prior copy.
mkdir -p "${STAGE_DIR}/conf"
for f in settings.ini template.json addrsyncd.toml; do
    if [ -f "${REPO_ROOT}/conf/${f}" ]; then
        install -m 0644 "${REPO_ROOT}/conf/${f}" "${STAGE_DIR}/conf/${f}"
    fi
done

# Manifest with resolved versions + checksums. We rewrite it from scratch
# rather than templating — explicit values are easier to verify by eye.
{
    cat <<MANIFEST_HEAD
{
  "schema_version": 1,
  "project": "Flux",
  "module_version": "${MODULE_VERSION}",
  "generated_by": "tools/package.sh",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "profile": "$([ "${LITE_PROFILE}" -eq 1 ] && echo lite || echo full)",
  "binaries": [
MANIFEST_HEAD
    if [ "${LITE_PROFILE}" -eq 0 ]; then
        cat <<MANIFEST_BIN
    { "name": "sing-box",  "path": "bin/sing-box",  "version": "${SINGBOX_VERSION}", "target": "android-arm64", "sha256": "${SINGBOX_BIN_SHA}" },
    { "name": "jq",        "path": "bin/jq",        "version": "${JQ_VERSION}",      "target": "linux-arm64-static (bionic-compatible)", "sha256": "${JQ_BIN_SHA}" },
    { "name": "addrsyncd", "path": "bin/addrsyncd", "version": "$(git -C "${ADDRSYNCD_DIR}" describe --always --dirty 2>/dev/null || printf "unknown")", "target": "aarch64-linux-android", "sha256": "${ADDRSYNCD_SHA}" }
MANIFEST_BIN
    fi
    cat <<MANIFEST_TAIL
  ]
}
MANIFEST_TAIL
} > "${STAGE_DIR}/conf/manifest.json"

# Module root files
install -m 0644 "${REPO_ROOT}/module.prop"      "${STAGE_DIR}/module.prop"
install -m 0755 "${REPO_ROOT}/customize.sh"     "${STAGE_DIR}/customize.sh"
install -m 0755 "${REPO_ROOT}/flux_service.sh"  "${STAGE_DIR}/flux_service.sh"

mkdir -p "${STAGE_DIR}/META-INF/com/google/android"
install -m 0644 "${REPO_ROOT}/META-INF/com/google/android/update-binary"  "${STAGE_DIR}/META-INF/com/google/android/update-binary"
install -m 0644 "${REPO_ROOT}/META-INF/com/google/android/updater-script" "${STAGE_DIR}/META-INF/com/google/android/updater-script"

mkdir -p "${STAGE_DIR}/webroot"
install -m 0644 "${REPO_ROOT}/webroot/index.html" "${STAGE_DIR}/webroot/index.html"

if [ -f "${REPO_ROOT}/LICENSE" ]; then
    install -m 0644 "${REPO_ROOT}/LICENSE" "${STAGE_DIR}/LICENSE"
fi

ok "stage tree complete"

# ------------------------------------------------------------------------------
# Validate before zipping
# ------------------------------------------------------------------------------

log "Validating stage"
# Shell syntax — refuse to ship a broken script.
for f in customize.sh flux_service.sh scripts/addrsync scripts/config scripts/core \
         scripts/dispatcher scripts/fluxctl scripts/init scripts/lib scripts/log \
         scripts/rules scripts/tproxy scripts/updater.sh; do
    bash -n "${STAGE_DIR}/${f}" || die "syntax error in staged ${f}"
done
ok "all staged shell scripts pass bash -n"

# Spot-check binaries are ELF (only on full builds)
if [ "${LITE_PROFILE}" -eq 0 ]; then
    for b in sing-box jq addrsyncd; do
        head -c 4 "${STAGE_DIR}/bin/${b}" | grep -q $'\x7fELF' \
            || die "bin/${b} is not an ELF binary"
    done
    ok "binaries are ELF"
fi

# ------------------------------------------------------------------------------
# Zip
# ------------------------------------------------------------------------------

VERSION_TAG="${MODULE_VERSION#v}"
OUT_NAME="${MODULE_ID}-${VERSION_TAG}$([ "${LITE_PROFILE}" -eq 1 ] && echo -lite || true).zip"
OUT_PATH="${OUT_DIR}/${OUT_NAME}"

rm -f "${OUT_PATH}"

log "Building ${OUT_NAME}"
( cd "${STAGE_DIR}" && zip -qr "${OUT_PATH}" \
    module.prop customize.sh flux_service.sh META-INF webroot conf scripts \
    $([ "${LITE_PROFILE}" -eq 0 ] && echo bin) \
    $([ -f LICENSE ] && echo LICENSE) )

OUT_SHA="$(sha "${OUT_PATH}")"
OUT_SIZE="$(wc -c <"${OUT_PATH}" | tr -d ' ')"
ok "${OUT_PATH}"
note "size:   ${OUT_SIZE} bytes"
note "sha256: ${OUT_SHA}"

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------

if [ "${KEEP_STAGE}" -eq 0 ]; then
    rm -rf "${STAGE_DIR}"
fi

printf '\n%sdone%s — %s\n' "${_bold}" "${_rst}" "${OUT_PATH}"
