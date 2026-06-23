#!/system/bin/sh

set -eu
[ -n "${BASH_VERSION:-}" ] && set -o pipefail

readonly JQ_REPO="jqlang/jq"
readonly JQ_SOURCE_URL_BASE="https://github.com/jqlang/jq/archive/refs/tags"
readonly ADDRSYNCD_TARGET="aarch64-linux-android"

usage() {
    echo "Usage: $0 --output-dir DIR --metadata-file FILE --jq-tag TAG --addrsyncd-dir DIR" >&2
    exit 1
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

sha256_file() {
    file="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | awk '{print $1}'
        return 0
    fi

    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${file}" | awk '{print $1}'
        return 0
    fi

    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "${file}" | awk '{print $NF}'
        return 0
    fi

    fail "No SHA-256 tool available"
}

host_tag() {
    os="$(uname -s 2>/dev/null || echo unknown)"
    arch="$(uname -m 2>/dev/null || echo unknown)"

    case "${os}:${arch}" in
    Linux:x86_64)
        echo "linux-x86_64"
        ;;
    Darwin:x86_64)
        echo "darwin-x86_64"
        ;;
    Darwin:arm64)
        echo "darwin-arm64"
        ;;
    *)
        fail "Unsupported NDK host platform: ${os} ${arch}"
        ;;
    esac
}

resolve_android_ndk_root() {
    if [ -n "${ANDROID_NDK_ROOT:-}" ]; then
        echo "${ANDROID_NDK_ROOT}"
        return 0
    fi

    if [ -n "${ANDROID_NDK_HOME:-}" ]; then
        echo "${ANDROID_NDK_HOME}"
        return 0
    fi

    fail "ANDROID_NDK_ROOT or ANDROID_NDK_HOME must be set"
}

setup_android_toolchain() {
    ANDROID_NDK_ROOT_RESOLVED="$(resolve_android_ndk_root)"
    ANDROID_API_LEVEL_RESOLVED="${ANDROID_API_LEVEL:-24}"
    ANDROID_HOST_TAG_RESOLVED="$(host_tag)"
    ANDROID_TOOLCHAIN_BIN="${ANDROID_NDK_ROOT_RESOLVED}/toolchains/llvm/prebuilt/${ANDROID_HOST_TAG_RESOLVED}/bin"

    [ -d "${ANDROID_TOOLCHAIN_BIN}" ] || fail "Android NDK toolchain bin directory not found: ${ANDROID_TOOLCHAIN_BIN}"

    export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT_RESOLVED}"
    export ANDROID_API_LEVEL="${ANDROID_API_LEVEL_RESOLVED}"
    export PATH="${ANDROID_TOOLCHAIN_BIN}:${PATH}"
    export AR="llvm-ar"
    export AS="llvm-as"
    export CC="aarch64-linux-android${ANDROID_API_LEVEL}-clang"
    export CXX="aarch64-linux-android${ANDROID_API_LEVEL}-clang++"
    export LD="ld.lld"
    export RANLIB="llvm-ranlib"
    export STRIP="llvm-strip"
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${CC}"
}

download_file() {
    url="$1"
    output="$2"
    curl -fsSL "${url}" -o "${output}"
}

extract_tarball() {
    archive="$1"
    output_dir="$2"
    mkdir -p "${output_dir}"
    tar -xzf "${archive}" -C "${output_dir}"
}

first_subdir() {
    search_dir="$1"
    find "${search_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1
}

build_jq_android() {
    jq_tag="$1"
    output_file="$2"

    require_cmd curl
    require_cmd tar
    require_cmd make
    require_cmd find
    require_cmd head
    require_cmd chmod

    setup_android_toolchain

    JQ_WORK_DIR="${WORK_DIR}/jq"
    JQ_ARCHIVE="${JQ_WORK_DIR}/jq-${jq_tag}.tar.gz"
    JQ_SOURCE_ROOT="${JQ_WORK_DIR}/src"
    mkdir -p "${JQ_WORK_DIR}"

    download_file "${JQ_SOURCE_URL_BASE}/${jq_tag}.tar.gz" "${JQ_ARCHIVE}" || fail "Failed to download jq source tag ${jq_tag}"
    extract_tarball "${JQ_ARCHIVE}" "${JQ_SOURCE_ROOT}"

    JQ_SOURCE_DIR="$(first_subdir "${JQ_SOURCE_ROOT}")"
    [ -n "${JQ_SOURCE_DIR}" ] || fail "Unable to locate extracted jq source directory"

    if [ ! -x "${JQ_SOURCE_DIR}/configure" ]; then
        require_cmd autoreconf
        (
            cd "${JQ_SOURCE_DIR}"
            autoreconf -fi
        ) || fail "Failed to generate jq configure script"
    fi

    if [ ! -f "${JQ_SOURCE_DIR}/configure" ]; then
        fail "jq source does not provide a configure script"
    fi

    (
        cd "${JQ_SOURCE_DIR}"
        ./configure \
            --host=aarch64-linux-android \
            --disable-maintainer-mode \
            --disable-docs \
            --with-oniguruma=builtin
    ) || fail "jq configure failed for Android arm64"

    (
        cd "${JQ_SOURCE_DIR}"
        make -j"${BUILD_JOBS}"
    ) || fail "jq build failed for Android arm64"

    [ -f "${JQ_SOURCE_DIR}/jq" ] || fail "jq build completed without producing jq executable"

    cp "${JQ_SOURCE_DIR}/jq" "${output_file}"
    chmod 755 "${output_file}"
}

require_rust_target() {
    require_cmd rustup
    rustup target list --installed | grep -qx "${ADDRSYNCD_TARGET}" || fail "Rust target ${ADDRSYNCD_TARGET} is not installed"
}

build_addrsyncd_android() {
    addrsyncd_dir="$1"
    output_file="$2"

    require_cmd cargo
    require_cmd grep
    require_cmd cp
    require_cmd chmod

    [ -d "${addrsyncd_dir}" ] || fail "addrsyncd directory not found: ${addrsyncd_dir}"
    [ -f "${addrsyncd_dir}/Cargo.toml" ] || fail "Unsupported addrsyncd layout: missing Cargo.toml in ${addrsyncd_dir}"

    setup_android_toolchain
    require_rust_target

    (
        cd "${addrsyncd_dir}"
        cargo build --release --locked --target "${ADDRSYNCD_TARGET}"
    ) || fail "addrsyncd Android build failed"

    ADDRSYNCD_BINARY="${addrsyncd_dir}/target/${ADDRSYNCD_TARGET}/release/addrsyncd"
    [ -f "${ADDRSYNCD_BINARY}" ] || fail "Unsupported addrsyncd build layout: missing ${ADDRSYNCD_BINARY}"

    cp "${ADDRSYNCD_BINARY}" "${output_file}"
    chmod 755 "${output_file}"
}

git_commit_for_dir() {
    repo_dir="$1"
    if command -v git >/dev/null 2>&1; then
        git -C "${repo_dir}" rev-parse HEAD 2>/dev/null && return 0
    fi
    fail "Unable to resolve git commit for ${repo_dir}"
}

git_remote_for_dir() {
    repo_dir="$1"
    if command -v git >/dev/null 2>&1; then
        git -C "${repo_dir}" config --get remote.origin.url 2>/dev/null && return 0
    fi
    printf '%s\n' "${repo_dir}"
}

append_metadata() {
    output_file="$1"
    cat >>"${output_file}" <<EOF
JQ_REPO=${JQ_REPO}
JQ_VERSION=${JQ_VERSION}
JQ_SHA256=${JQ_SHA256}
ADDRSYNCD_SOURCE=${ADDRSYNCD_SOURCE}
ADDRSYNCD_VERSION=${ADDRSYNCD_VERSION}
ADDRSYNCD_SHA256=${ADDRSYNCD_SHA256}
EOF
}

OUTPUT_DIR=""
METADATA_FILE=""
JQ_TAG=""
ADDRSYNCD_DIR=""

while [ "$#" -gt 0 ]; do
    case "$1" in
    --output-dir)
        [ "$#" -ge 2 ] || usage
        OUTPUT_DIR="$2"
        shift 2
        ;;
    --metadata-file)
        [ "$#" -ge 2 ] || usage
        METADATA_FILE="$2"
        shift 2
        ;;
    --jq-tag)
        [ "$#" -ge 2 ] || usage
        JQ_TAG="$2"
        shift 2
        ;;
    --addrsyncd-dir)
        [ "$#" -ge 2 ] || usage
        ADDRSYNCD_DIR="$2"
        shift 2
        ;;
    *)
        usage
        ;;
    esac
done

[ -n "${OUTPUT_DIR}" ] || usage
[ -n "${METADATA_FILE}" ] || usage
[ -n "${JQ_TAG}" ] || usage
[ -n "${ADDRSYNCD_DIR}" ] || usage

require_cmd awk
require_cmd cat
require_cmd cp
require_cmd curl
require_cmd find
require_cmd git
require_cmd grep
require_cmd head
require_cmd make
require_cmd dirname
require_cmd mkdir
require_cmd mktemp
require_cmd rm
require_cmd tar
require_cmd uname

BUILD_JOBS="${BUILD_JOBS:-1}"

mkdir -p "${OUTPUT_DIR}"
mkdir -p "$(dirname "${METADATA_FILE}")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flux-third-party-android.XXXXXX")"
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

build_jq_android "${JQ_TAG}" "${OUTPUT_DIR}/jq"
build_addrsyncd_android "${ADDRSYNCD_DIR}" "${OUTPUT_DIR}/addrsyncd"

JQ_VERSION="${JQ_TAG}"
JQ_SHA256="$(sha256_file "${OUTPUT_DIR}/jq")"
ADDRSYNCD_SOURCE="$(git_remote_for_dir "${ADDRSYNCD_DIR}")"
ADDRSYNCD_VERSION="$(git_commit_for_dir "${ADDRSYNCD_DIR}")"
ADDRSYNCD_SHA256="$(sha256_file "${OUTPUT_DIR}/addrsyncd")"

append_metadata "${METADATA_FILE}"

printf 'Built jq %s and addrsyncd %s for Android arm64\n' "${JQ_VERSION}" "${ADDRSYNCD_VERSION}"
