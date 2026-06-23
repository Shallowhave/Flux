#!/system/bin/sh

set -eu
[ -n "${BASH_VERSION:-}" ] && set -o pipefail

readonly SING_BOX_REPO="SagerNet/sing-box"

usage() {
    echo "Usage: $0 --output-dir DIR --metadata-file FILE" >&2
    exit 1
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

json_string() {
    jq -r "$2" "$1"
}

github_latest_release_json() {
    repo="$1"
    output="$2"
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${repo}/releases/latest" \
        -o "${output}"
}

select_unique_asset() {
    json_file="$1"
    jq_filter="$2"
    asset_name=""
    asset_name="$(jq -r "${jq_filter}" "${json_file}")" || return 1

    [ -n "${asset_name}" ] || fail "No matching asset found in ${json_file}"
    [ "${asset_name}" != "null" ] || fail "No matching asset found in ${json_file}"

    printf '%s\n' "${asset_name}"
}

select_singbox_asset() {
    json_file="$1"
    select_unique_asset "${json_file}" '
        [
            .assets[]
            | select(.name | test("^sing-box-.*-android-arm64\\.(tar\\.gz|tgz)$"; "i"))
            | .name
        ] as $matches
        | if ($matches | length) == 1 then
            $matches[0]
          elif ($matches | length) == 0 then
            empty
          else
            error("Ambiguous sing-box asset selection: " + ($matches | join(", ")))
          end
    '
}

asset_download_url() {
    json_file="$1"
    asset_name="$2"
    jq -r --arg asset_name "${asset_name}" '
        .assets[]
        | select(.name == $asset_name)
        | .browser_download_url
    ' "${json_file}"
}

download_file() {
    url="$1"
    output="$2"
    curl -fsSL "${url}" -o "${output}"
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

extract_tar_member() {
    archive="$1"
    member_path="$2"
    output="$3"

    if tar -xOf "${archive}" "${member_path}" >"${output}"; then
        return 0
    fi

    tar -xzf "${archive}" -C "$(dirname "${output}")" || return 1
}

extract_singbox_binary() {
    archive="$1"
    output="$2"

    member_path="$(
        tar -tzf "${archive}" \
        | awk '/(^|\/)sing-box$/ { print; count += 1 } END { if (count != 1) exit 1 }'
    )" || fail "Expected exactly one sing-box executable in $(basename "${archive}")"

    rm -f "${output}"
    extract_tar_member "${archive}" "${member_path}" "${output}" || fail "Failed to extract sing-box from $(basename "${archive}")"
    chmod 755 "${output}"
}

emit_metadata() {
    output_file="$1"

    cat >"${output_file}" <<EOF
SING_BOX_REPO=${SING_BOX_REPO}
SING_BOX_VERSION=${SING_BOX_VERSION}
SING_BOX_ASSET=${SING_BOX_ASSET}
SING_BOX_URL=${SING_BOX_URL}
SING_BOX_SHA256=${SING_BOX_SHA256}
EOF
}

OUTPUT_DIR=""
METADATA_FILE=""

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
    *)
        usage
        ;;
    esac
done

[ -n "${OUTPUT_DIR}" ] || usage
[ -n "${METADATA_FILE}" ] || usage

require_cmd curl
require_cmd jq
require_cmd tar
require_cmd awk
require_cmd basename
require_cmd cat
require_cmd chmod
require_cmd dirname
require_cmd mkdir
require_cmd mktemp
require_cmd rm

mkdir -p "${OUTPUT_DIR}"
mkdir -p "$(dirname "${METADATA_FILE}")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flux-release-binaries.XXXXXX")"
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

SING_BOX_JSON="${WORK_DIR}/sing-box-release.json"
github_latest_release_json "${SING_BOX_REPO}" "${SING_BOX_JSON}"

SING_BOX_VERSION="$(json_string "${SING_BOX_JSON}" '.tag_name')"

SING_BOX_ASSET="$(select_singbox_asset "${SING_BOX_JSON}")"

SING_BOX_URL="$(asset_download_url "${SING_BOX_JSON}" "${SING_BOX_ASSET}")"

[ -n "${SING_BOX_URL}" ] || fail "Missing download URL for ${SING_BOX_ASSET}"

SING_BOX_ARCHIVE="${WORK_DIR}/${SING_BOX_ASSET}"

download_file "${SING_BOX_URL}" "${SING_BOX_ARCHIVE}"

extract_singbox_binary "${SING_BOX_ARCHIVE}" "${OUTPUT_DIR}/sing-box"

SING_BOX_SHA256="$(sha256_file "${OUTPUT_DIR}/sing-box")"

emit_metadata "${METADATA_FILE}"

printf 'Fetched %s (%s)\n' "${SING_BOX_REPO}" "${SING_BOX_VERSION}"
