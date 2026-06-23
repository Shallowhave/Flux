#!/system/bin/sh

set -eu
[ -n "${BASH_VERSION:-}" ] && set -o pipefail

usage() {
    echo "Usage: $0 --repo-root DIR --bin-dir DIR --metadata-file FILE --output-dir DIR" >&2
    exit 1
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

require_path() {
    path="$1"
    description="$2"
    [ -e "${path}" ] || fail "Missing ${description}: ${path}"
}

module_prop_value() {
    key="$1"
    prop_file="$2"
    awk -F= -v k="${key}" '$1 == k {print substr($0, index($0, "=") + 1); exit}' "${prop_file}"
}

append_copy_item() {
    source_path="$1"
    target_dir="$2"
    require_path "${source_path}" "module payload"
    cp -R "${source_path}" "${target_dir}/"
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

load_metadata() {
    metadata_file="$1"

    require_path "${metadata_file}" "metadata file"

    # shellcheck disable=SC1090
    . "${metadata_file}"
}

update_manifest_if_possible() {
    manifest_file="$1"

    [ -f "${manifest_file}" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    metadata_json="$(mktemp "${WORK_DIR}/manifest.XXXXXX.json")"

    jq \
        --arg generated_by "scripts/package-release.sh" \
        --arg module_id "${MODULE_ID}" \
        --arg module_name "${MODULE_NAME}" \
        --arg module_version "${MODULE_VERSION}" \
        --arg module_version_code "${MODULE_VERSION_CODE}" \
        --arg sing_box_source "${SING_BOX_REPO:-}" \
        --arg sing_box_version "${SING_BOX_VERSION:-}" \
        --arg sing_box_sha "${SING_BOX_SHA256:-}" \
        --arg jq_source "${JQ_REPO:-}" \
        --arg jq_version "${JQ_VERSION:-}" \
        --arg jq_sha "${JQ_SHA256:-}" \
        --arg addrsyncd_source "${ADDRSYNCD_SOURCE:-}" \
        --arg addrsyncd_version "${ADDRSYNCD_VERSION:-}" \
        --arg addrsyncd_sha "${ADDRSYNCD_SHA256:-}" \
        '
        .generated_by = $generated_by
        | .module = {
            id: $module_id,
            name: $module_name,
            version: $module_version,
            versionCode: $module_version_code
        }
        | .binaries = (
            .binaries
            | map(
                if .name == "sing-box" then
                    .source = (if $sing_box_source == "" then .source else ("https://github.com/" + $sing_box_source) end)
                    | .version = (if $sing_box_version == "" then .version else $sing_box_version end)
                    | .target = "android"
                    | .sha256 = (if $sing_box_sha == "" then .sha256 else $sing_box_sha end)
                elif .name == "jq" then
                    .source = (if $jq_source == "" then .source else ("https://github.com/" + $jq_source) end)
                    | .version = (if $jq_version == "" then .version else $jq_version end)
                    | .target = "android"
                    | .sha256 = (if $jq_sha == "" then .sha256 else $jq_sha end)
                elif .name == "addrsyncd" then
                    .source = (if $addrsyncd_source == "" then .source else $addrsyncd_source end)
                    | .version = (if $addrsyncd_version == "" then .version else $addrsyncd_version end)
                    | .target = "android"
                    | .sha256 = (if $addrsyncd_sha == "" then .sha256 else $addrsyncd_sha end)
                else
                    .
                end
            )
        )
        ' "${manifest_file}" >"${metadata_json}" || fail "Failed to refresh staged manifest metadata"

    mv "${metadata_json}" "${manifest_file}"
}

zip_list_file() {
    archive_file="$1"
    listing_file="$2"

    if has_cmd unzip; then
        unzip -Z1 "${archive_file}" >"${listing_file}" || fail "Failed to inspect ZIP structure"
        return 0
    fi

    if has_cmd powershell.exe; then
        powershell.exe -NoProfile -Command \
            "[System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null; \$zip = [System.IO.Compression.ZipFile]::OpenRead('${archive_file}'); try { \$zip.Entries | ForEach-Object { \$_.FullName } | Set-Content -Path '${listing_file}' -NoNewline:$false } finally { \$zip.Dispose() }" \
            >/dev/null || fail "Failed to inspect ZIP structure"
        return 0
    fi

    fail "Missing command: unzip"
}

create_zip_archive() {
    archive_file="$1"
    stage_dir="$2"

    if has_cmd zip; then
        (
            cd "${stage_dir}"
            zip -qr "${archive_file}" .
        ) || fail "Failed to create release ZIP"
        return 0
    fi

    if has_cmd powershell.exe; then
        powershell.exe -NoProfile -Command \
            "Compress-Archive -Path '${stage_dir}\\*' -DestinationPath '${archive_file}' -Force" \
            >/dev/null || fail "Failed to create release ZIP"
        return 0
    fi

    fail "Missing command: zip"
}

verify_zip_structure() {
    archive_file="$1"

    require_path "${archive_file}" "release archive"

    zip_listing="$(mktemp "${WORK_DIR}/zip-list.XXXXXX.txt")"
    zip_list_file "${archive_file}" "${zip_listing}"

    for required_entry in \
        "module.prop" \
        "customize.sh" \
        "flux_service.sh" \
        "bin/sing-box" \
        "bin/jq" \
        "bin/addrsyncd" \
        "scripts/fluxctl" \
        "conf/settings.ini"
    do
        if ! grep -Fx "${required_entry}" "${zip_listing}" >/dev/null 2>&1; then
            fail "ZIP missing required entry: ${required_entry}"
        fi
    done
}

REPO_ROOT=""
BIN_DIR=""
METADATA_FILE=""
OUTPUT_DIR=""

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo-root)
        [ "$#" -ge 2 ] || usage
        REPO_ROOT="$2"
        shift 2
        ;;
    --bin-dir)
        [ "$#" -ge 2 ] || usage
        BIN_DIR="$2"
        shift 2
        ;;
    --metadata-file)
        [ "$#" -ge 2 ] || usage
        METADATA_FILE="$2"
        shift 2
        ;;
    --output-dir)
        [ "$#" -ge 2 ] || usage
        OUTPUT_DIR="$2"
        shift 2
        ;;
    *)
        usage
        ;;
    esac
done

[ -n "${REPO_ROOT}" ] || usage
[ -n "${BIN_DIR}" ] || usage
[ -n "${METADATA_FILE}" ] || usage
[ -n "${OUTPUT_DIR}" ] || usage

require_cmd awk
require_cmd basename
require_cmd cp
require_cmd dirname
require_cmd grep
require_cmd mkdir
require_cmd mktemp
require_cmd mv
require_cmd rm
require_cmd chmod

REPO_ROOT="$(cd "${REPO_ROOT}" && pwd)"
require_path "${BIN_DIR}" "bin directory"
BIN_DIR="$(cd "${BIN_DIR}" && pwd)"
OUTPUT_DIR="$(mkdir -p "${OUTPUT_DIR}" && cd "${OUTPUT_DIR}" && pwd)"

MODULE_PROP_FILE="${REPO_ROOT}/module.prop"
require_path "${MODULE_PROP_FILE}" "module.prop"

MODULE_ID="$(module_prop_value "id" "${MODULE_PROP_FILE}")"
MODULE_NAME="$(module_prop_value "name" "${MODULE_PROP_FILE}")"
MODULE_VERSION="$(module_prop_value "version" "${MODULE_PROP_FILE}")"
MODULE_VERSION_CODE="$(module_prop_value "versionCode" "${MODULE_PROP_FILE}")"

[ -n "${MODULE_ID}" ] || fail "module.prop missing id"
[ -n "${MODULE_NAME}" ] || fail "module.prop missing name"
[ -n "${MODULE_VERSION}" ] || fail "module.prop missing version"
[ -n "${MODULE_VERSION_CODE}" ] || fail "module.prop missing versionCode"

load_metadata "${METADATA_FILE}"

require_path "${BIN_DIR}/sing-box" "binary"
require_path "${BIN_DIR}/jq" "binary"
require_path "${BIN_DIR}/addrsyncd" "binary"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flux-package-release.XXXXXX")"
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

STAGE_DIR="${WORK_DIR}/stage"
mkdir -p "${STAGE_DIR}"

append_copy_item "${REPO_ROOT}/META-INF" "${STAGE_DIR}"
append_copy_item "${REPO_ROOT}/conf" "${STAGE_DIR}"
append_copy_item "${REPO_ROOT}/scripts" "${STAGE_DIR}"
append_copy_item "${REPO_ROOT}/webroot" "${STAGE_DIR}"
append_copy_item "${REPO_ROOT}/module.prop" "${STAGE_DIR}"
append_copy_item "${REPO_ROOT}/customize.sh" "${STAGE_DIR}"
append_copy_item "${REPO_ROOT}/flux_service.sh" "${STAGE_DIR}"

mkdir -p "${STAGE_DIR}/bin"
cp "${BIN_DIR}/sing-box" "${STAGE_DIR}/bin/sing-box"
cp "${BIN_DIR}/jq" "${STAGE_DIR}/bin/jq"
cp "${BIN_DIR}/addrsyncd" "${STAGE_DIR}/bin/addrsyncd"
chmod 755 "${STAGE_DIR}/bin/sing-box" "${STAGE_DIR}/bin/jq" "${STAGE_DIR}/bin/addrsyncd"

if [ -f "${STAGE_DIR}/bin/sing-box" ] && [ -z "${SING_BOX_SHA256:-}" ]; then
    SING_BOX_SHA256="$(sha256_file "${STAGE_DIR}/bin/sing-box")"
fi
if [ -f "${STAGE_DIR}/bin/jq" ] && [ -z "${JQ_SHA256:-}" ]; then
    JQ_SHA256="$(sha256_file "${STAGE_DIR}/bin/jq")"
fi
if [ -f "${STAGE_DIR}/bin/addrsyncd" ] && [ -z "${ADDRSYNCD_SHA256:-}" ]; then
    ADDRSYNCD_SHA256="$(sha256_file "${STAGE_DIR}/bin/addrsyncd")"
fi

update_manifest_if_possible "${STAGE_DIR}/conf/manifest.json"

ARCHIVE_FILE="${OUTPUT_DIR}/flux-${MODULE_VERSION}.zip"
rm -f "${ARCHIVE_FILE}"

create_zip_archive "${ARCHIVE_FILE}" "${STAGE_DIR}"
verify_zip_structure "${ARCHIVE_FILE}"

printf 'Packaged %s %s (%s) at %s\n' "${MODULE_NAME}" "${MODULE_VERSION}" "${MODULE_VERSION_CODE}" "${ARCHIVE_FILE}"
