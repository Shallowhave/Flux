#!/system/bin/sh

# ==============================================================================
# [ Flux Subscription Updater ]
# Description: Industrial-grade node synchronization with atomic deployment.
# ==============================================================================

# Strict error handling
set -eu
[ -n "${BASH_VERSION:-}" ] && set -o pipefail

_script_path="${0}"
case "${_script_path}" in
/*) ;;
*) _script_path="${PWD}/${_script_path}" ;;
esac
readonly SCRIPT_DIR="${_script_path%/*}"

. "${SCRIPT_DIR}/lib"
. "${SCRIPT_DIR}/log"

readonly LOG_COMPONENT="Updt"

load_config || exit 1

# State management
TMP_CONFIG=""
WORK_DIR=""

# ==============================================================================
# [ Core Pipeline ]
# ==============================================================================

_fetch_and_decode() {
    local url="${1}"
    local output="${2}"
    local ua="Flux/1.0 (Sing-box; Android)"

    log_info "Fetching subscription: ${url%%#*}"
    # Use pipe to avoid temp file for base64 decode if possible, but curl output needs to be checked.
    # Current implementation downloads to file first.
    if ! retry "${RETRY_COUNT}" curl -L -f -s --http1.1 --compressed \
        --connect-timeout "${UPDATE_TIMEOUT}" --max-time "${UPDATE_TIMEOUT}" \
        --user-agent "${ua}" -o "${output}" "${url}"; then
        log_error "Download failed (check URL or connection)"
        return 1
    fi

    if is_base64 "${output}"; then
        log_debug "Decoding Base64 content..."
        # Decode in-place
        base64 -d "${output}" >"${output}.tmp" && mv "${output}.tmp" "${output}" || {
            log_error "Decode fail"
            return 1
        }
    fi
    return 0
}

readonly UPDATER_COUNTRY_MAP='{
    "HK": "香港|港|hk|hongkong|hong kong",
    "TW": "台湾|台|tw|taiwan",
    "JP": "日本|日|jp|japan",
    "SG": "新加坡|新|sg|singapore",
    "US": "美国|美|us|usa|united states|america",
    "KR": "韩国|韩|kr|korea|south korea",
    "UK": "英国|英|uk|gb|united kingdom|britain",
    "DE": "德国|德|de|germany",
    "FR": "法国|法|fr|france",
    "CA": "加拿大|加|ca|canada",
    "AU": "澳大利亚|澳洲|澳|au|australia",
    "RU": "俄罗斯|俄|ru|russia",
    "NL": "荷兰|荷|nl|netherlands",
    "IN": "印度|印|in|india",
    "TR": "土耳其|土|tr|turkey|turkiye",
    "IT": "意大利|意|it|italy",
    "CH": "瑞士|ch|switzerland",
    "SE": "瑞典|se|sweden",
    "BR": "巴西|br|brazil",
    "AR": "阿根廷|ar|argentina",
    "VN": "越南|vn|vietnam",
    "TH": "泰国|th|thailand",
    "PH": "菲律宾|菲|ph|philippines",
    "MY": "马来西亚|马来|my|malaysia",
    "ID": "印尼|印度尼西亚|id|indonesia",
    "ES": "西班牙|西|es|spain",
    "PL": "波兰|pl|poland",
    "FI": "芬兰|fi|finland",
    "NO": "挪威|no|norway",
    "DK": "丹麦|dk|denmark"
}'

readonly INFRASTRUCTURE_TYPES='["selector","urltest","direct","block","dns"]'

_transform_nodes() {
    local input="${1}"
    local output="${2}"
    local unsupported_file="${WORK_DIR}/unsupported_protocols"

    : >"${unsupported_file}"

    run_pipeline() {
        # shellcheck disable=SC2016
        "${JQ_BIN}" -n \
            --slurpfile template "${TEMPLATE_FILE}" \
            --arg exclude "${UPDATER_EXCLUDE_REMARKS}" \
            --argjson renames "${UPDATER_RENAME_RULES}" \
            --argjson map "${UPDATER_COUNTRY_MAP}" \
            --argjson infra "${INFRASTRUCTURE_TYPES}" \
            --argjson maxlen "${UPDATER_MAX_TAG_LENGTH}" \
            --arg cleanup_emoji "${PREF_CLEANUP_EMOJI}" \
            '
            ($template[0]) as $tpl |
            [inputs | (.outbounds? // .)] | flatten as $raw_nodes |

            # --- Phase A: Node Refinement ---
            (
                $raw_nodes | map(
                    select(.tag != null and (.type | IN($infra[]) | not)) |
                    (if ($exclude != "") then select(.tag | test($exclude; "i") | not) else . end) |
                    reduce ($renames[]? // empty) as $r (.; if $r.match then .tag |= gsub($r.match; $r.replace) else . end) |
                    (if $cleanup_emoji == "1" then .tag |= gsub("[🇦-🇿]{2}|[🌀-🗿]|[😀-🙏]|[🚀-🛿]|[☀-⟿]|[⺀-⻿]|[\u2600-\u27BF]"; "") else . end) |
                    .tag |= (if . then gsub("[$¥](?<n>[0-9.]+)([xX倍率]*)"; "\(.n)x") | gsub("(?<n>[0-9.]+)([xX倍率]+)"; "\(.n)x") | gsub("(^\\s+|\\s+$)"; "") | gsub("\\s{2,}"; " ") else . end) |
                    .tag |= (if . == "" then .type else . end) |
                    .tag |= (if (length > $maxlen) then (.[0:($maxlen - 3)] + "...") else . end)
                )
            ) as $refined_proxies |

            # --- Phase B: Categorization & Grouping (Dynamic) ---
            (
                ($map | to_entries) as $m |
                $refined_proxies | reduce .[] as $p ({};
                    reduce $m[] as $item (.;
                        if ($p.tag | test($item.value; "i")) then
                            .[$item.key] += [$p.tag]
                        else . end
                    )
                )
            ) as $groups |

            # --- Phase C: Final Assembly ---
            $tpl | .outbounds |= (
                map(
                    if ((.type == "selector" or .type == "urltest") and (.outbounds | length) == 0) then
                        if $groups[.tag] then
                            .outbounds = $groups[.tag]
                        elif (.tag | IN("PROXY", "GLOBAL", "AUTO")) then
                            .outbounds = ($refined_proxies | map(.tag))
                        else . end
                    else . end
                ) + $refined_proxies
            ) | del(..|nulls)
            ' >"${output}"
    }

    log_debug "Executing unified processing pipeline..."
    if "${JQ_BIN}" -e '.outbounds? | type == "array"' "${input}" >/dev/null 2>&1; then
        log_debug "Detected sing-box format"
        run_pipeline <"${input}" || {
            log_error "Pipeline execution failed"
            return 1
        }
    else
        log_debug "Parsing URI list (Safe Mode)..."

        # Use awk to parse URI subscriptions in bulk -> jq aggregation -> jq pipeline.
        # Keep support aligned with sing-box outbound structures, instead of emitting lossy placeholders.
        awk -v unsupported_file="${unsupported_file}" '
# Parses URIs into sing-box compatible JSON objects
# Supported: vmess, vless, trojan, hysteria, hysteria2, hy2, tuic, socks, http, ss

BEGIN {
    b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for (i = 0; i < 64; i++) b64_val[substr(b64, i + 1, 1)] = i
    b64_val["-"] = 62
    b64_val["_"] = 63
}

function clear_map(map,    k) {
    for (k in map) delete map[k]
}

function record_unsupported(proto) {
    if (!(proto in unsupported_seen)) {
        print proto >> unsupported_file
        unsupported_seen[proto] = 1
    }
}

function trim(str) {
    sub(/^[[:space:]]+/, "", str)
    sub(/[[:space:]]+$/, "", str)
    return str
}

function truthy(str,    s) {
    s = tolower(str)
    return (s == "1" || s == "true" || s == "yes" || s == "on")
}

function decode_base64(str,    normalized, mod, cmd, out, line) {
    normalized = str
    gsub(/_/, "/", normalized)
    gsub(/-/, "+", normalized)
    mod = length(normalized) % 4
    if (mod == 2) normalized = normalized "=="
    else if (mod == 3) normalized = normalized "="
    else if (mod == 1) return ""

    cmd = "printf %s \047" normalized "\047 | base64 -d 2>/dev/null"
    out = ""
    while ((cmd | getline line) > 0) {
        out = out line
    }
    close(cmd)
    return out
}

function json_escape(str) {
    gsub(/\\/, "\\\\", str)
    gsub(/"/, "\\\"", str)
    gsub(/\n/, "\\n", str)
    gsub(/\r/, "\\r", str)
    gsub(/\t/, "\\t", str)
    return str
}

function json_array_csv(str,    out, first, n, i, item, parts) {
    out = "["
    first = 1
    n = split(str, parts, /,/)
    for (i = 1; i <= n; i++) {
        item = trim(parts[i])
        if (item == "") continue
        if (!first) out = out ","
        out = out "\"" json_escape(item) "\""
        first = 0
    }
    out = out "]"
    return out
}

function qp_get(name, default) {
    if (name in qp) return qp[name]
    return default
}

function qp_pick(a, b, c, d, default,    v) {
    v = qp_get(a, "")
    if (v != "") return v
    v = qp_get(b, "")
    if (v != "") return v
    v = qp_get(c, "")
    if (v != "") return v
    v = qp_get(d, "")
    if (v != "") return v
    return default
}

function split_tag_query(raw,    frag_idx, q_idx) {
    clear_map(qp)
    tag = ""
    query = ""
    base = raw

    frag_idx = index(base, "#")
    if (frag_idx > 0) {
        tag = url_decode(substr(base, frag_idx + 1))
        base = substr(base, 1, frag_idx - 1)
    }

    q_idx = index(base, "?")
    if (q_idx > 0) {
        query = substr(base, q_idx + 1)
        base = substr(base, 1, q_idx - 1)
    }

    parse_query(query)
}

function parse_query(query_str,    n, i, pair, eq_idx, key, val) {
    if (query_str == "") return
    n = split(query_str, q_parts, /&/)
    for (i = 1; i <= n; i++) {
        pair = q_parts[i]
        if (pair == "") continue
        eq_idx = index(pair, "=")
        if (eq_idx > 0) {
            key = url_decode(substr(pair, 1, eq_idx - 1))
            val = url_decode(substr(pair, eq_idx + 1))
        } else {
            key = url_decode(pair)
            val = ""
        }
        if (key != "") qp[key] = val
    }
}

function url_decode(str,    res, i, c, hex, h) {
    res = ""
    for (i = 1; i <= length(str); i++) {
        c = substr(str, i, 1)
        if (c == "+") {
            res = res " "
        } else if (c == "%") {
            hex = toupper(substr(str, i + 1, 2))
            if (length(hex) == 2 && index("0123456789ABCDEF", substr(hex, 1, 1)) && index("0123456789ABCDEF", substr(hex, 2, 1))) {
                h = index("0123456789ABCDEF", substr(hex, 1, 1)) - 1
                h = h * 16 + index("0123456789ABCDEF", substr(hex, 2, 1)) - 1
                res = res sprintf("%c", h)
                i += 2
            } else {
                res = res c
            }
        } else {
            res = res c
        }
    }
    return res
}

function parse_endpoint(endpoint, default_port,    n, cb, p, parts) {
    server = ""
    server_port = default_port

    if (endpoint == "") return

    if (substr(endpoint, 1, 1) == "[") {
        cb = index(endpoint, "]")
        if (cb > 0) {
            server = substr(endpoint, 2, cb - 2)
            p = substr(endpoint, cb + 1)
            sub(/^:/, "", p)
            if (p != "") server_port = p + 0
            return
        }
    }

    n = split(endpoint, parts, ":")
    if (n >= 2) {
        server_port = parts[n] + 0
        server = substr(endpoint, 1, length(endpoint) - length(parts[n]) - 1)
    } else {
        server = endpoint
    }
}

function split_userinfo(base_str,    at_idx) {
    userinfo = ""
    endpoint = base_str
    at_idx = index(base_str, "@")
    if (at_idx > 0) {
        userinfo = substr(base_str, 1, at_idx - 1)
        endpoint = substr(base_str, at_idx + 1)
    }
}

function host_fallback() {
    return qp_pick("host", "Host", "peer", "sni", server)
}

function build_tls_json(default_sni, force_enable,    tls, server_name, insecure, alpn, fp, pbk, sid) {
    server_name = qp_pick("sni", "serverName", "servername", "peer", default_sni)
    insecure = truthy(qp_pick("insecure", "allowInsecure", "", "", ""))
    alpn = qp_get("alpn", "")
    fp = qp_pick("fp", "fingerprint", "", "", "")
    pbk = qp_pick("pbk", "public-key", "public_key", "", "")
    sid = qp_pick("sid", "short_id", "", "", "")

    if (!force_enable && server_name == "" && !insecure && alpn == "" && fp == "" && pbk == "" && sid == "") return ""

    tls = "\"tls\":{\"enabled\":true"
    if (server_name != "") tls = tls ",\"server_name\":\"" json_escape(server_name) "\""
    if (insecure) tls = tls ",\"insecure\":true"
    if (alpn != "") tls = tls ",\"alpn\":" json_array_csv(alpn)
    if (fp != "") tls = tls ",\"utls\":{\"enabled\":true,\"fingerprint\":\"" json_escape(fp) "\"}"
    if (pbk != "" || sid != "") {
        tls = tls ",\"reality\":{\"enabled\":true"
        if (pbk != "") tls = tls ",\"public_key\":\"" json_escape(pbk) "\""
        if (sid != "") tls = tls ",\"short_id\":\"" json_escape(sid) "\""
        tls = tls "}"
    }
    tls = tls "}"
    return tls
}

function build_transport_json(default_host,    transport_type, path, host, service_name, mode, header_type, transport) {
    transport_type = tolower(qp_pick("type", "network", "", "", ""))
    header_type = tolower(qp_get("headerType", ""))
    if ((transport_type == "" || transport_type == "tcp") && header_type != "http") return ""

    path = qp_get("path", "")
    host = qp_pick("host", "Host", "", "", default_host)

    if (transport_type == "ws") {
        transport = "\"transport\":{\"type\":\"ws\""
        if (path != "") transport = transport ",\"path\":\"" json_escape(path) "\""
        if (host != "") transport = transport ",\"headers\":{\"Host\":\"" json_escape(host) "\"}"
        if (qp_get("ed", "") != "") transport = transport ",\"max_early_data\":" (qp_get("ed", "") + 0)
        if (qp_get("eh", "") != "") transport = transport ",\"early_data_header_name\":\"" json_escape(qp_get("eh", "")) "\""
        return transport "}"
    }

    if (transport_type == "grpc") {
        service_name = qp_pick("serviceName", "service_name", "", "", "")
        mode = tolower(qp_get("mode", ""))
        transport = "\"transport\":{\"type\":\"grpc\""
        if (service_name != "") transport = transport ",\"service_name\":\"" json_escape(service_name) "\""
        if (mode == "multi") transport = transport ",\"permit_without_stream\":true"
        return transport "}"
    }

    if (transport_type == "http") {
        transport = "\"transport\":{\"type\":\"http\""
        if (host != "") transport = transport ",\"host\":" json_array_csv(host)
        if (path != "") transport = transport ",\"path\":\"" json_escape(path) "\""
        if (qp_get("method", "") != "") transport = transport ",\"method\":\"" json_escape(qp_get("method", "")) "\""
        return transport "}"
    }

    if (transport_type == "httpupgrade" || transport_type == "http-upgrade") {
        transport = "\"transport\":{\"type\":\"httpupgrade\""
        if (host != "") transport = transport ",\"host\":\"" json_escape(host) "\""
        if (path != "") transport = transport ",\"path\":\"" json_escape(path) "\""
        return transport "}"
    }

    if (transport_type == "quic") return "\"transport\":{\"type\":\"quic\"}"

    if (transport_type == "tcp" && header_type == "http") {
        transport = "\"transport\":{\"type\":\"http\""
        if (host != "") transport = transport ",\"host\":" json_array_csv(host)
        if (path != "") transport = transport ",\"path\":\"" json_escape(path) "\""
        return transport "}"
    }

    record_unsupported("transport/" transport_type)
    return "__UNSUPPORTED__"
}

function node_begin(type_name, tag_name) {
    node = "{\"type\":\"" type_name "\",\"tag\":\"" json_escape(tag_name) "\""
}

function node_add_str(key, value) {
    if (value != "") node = node ",\"" key "\":\"" json_escape(value) "\""
}

function node_add_num(key, value) {
    if (value != "") node = node ",\"" key "\":" value
}

function node_add_bool(key, value) {
    if (value != "") node = node ",\"" key "\":" value
}

function node_add_json(fragment) {
    if (fragment != "") node = node "," fragment
}

function node_emit() {
    print node "}"
}

function get_json_val(json, key,    pat, start, end, val, rest) {
    pat = "\"" key "\"[[:space:]]*:[[:space:]]*"
    start = match(json, pat)
    if (start == 0) return ""

    rest = substr(json, start + RLENGTH)
    if (substr(rest, 1, 1) == "\"") {
        end = index(substr(rest, 2), "\"")
        if (end == 0) return ""
        val = substr(rest, 2, end - 1)
        return val
    }

    match(rest, /^[^,}\]]+/)
    val = substr(rest, 1, RLENGTH)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
    return val
}

{
    uri = $0
    if (uri == "" || uri ~ /^#/) next

    idx = index(uri, "://")
    if (idx == 0) next

    proto = tolower(substr(uri, 1, idx - 1))
    body = substr(uri, idx + 3)
    if (proto == "hy2") proto = "hysteria2"

    if (proto == "vmess") {
        json_str = decode_base64(body)
        tag = get_json_val(json_str, "ps")
        server = get_json_val(json_str, "add")
        server_port = get_json_val(json_str, "port") + 0
        uuid = get_json_val(json_str, "id")
        aid = get_json_val(json_str, "aid")
        security = get_json_val(json_str, "scy")
        transport_type = tolower(get_json_val(json_str, "net"))
        host = get_json_val(json_str, "host")
        path = get_json_val(json_str, "path")
        tls_mode = tolower(get_json_val(json_str, "tls"))
        sni = get_json_val(json_str, "sni")

        if (server == "" || uuid == "") next

        node_begin("vmess", tag != "" ? tag : "VMess")
        node_add_str("server", server)
        node_add_num("server_port", server_port)
        node_add_str("uuid", uuid)
        node_add_str("security", security == "" ? "auto" : security)
        if (aid != "" && aid != "0") node_add_num("alter_id", aid + 0)

        if (transport_type == "ws") {
            transport = "\"transport\":{\"type\":\"ws\""
            if (path != "") transport = transport ",\"path\":\"" json_escape(path) "\""
            if (host != "") transport = transport ",\"headers\":{\"Host\":\"" json_escape(host) "\"}"
            transport = transport "}"
            node_add_json(transport)
        } else if (transport_type != "" && transport_type != "tcp") {
            record_unsupported("vmess/" transport_type)
            next
        }

        if (tls_mode == "tls") node_add_json("\"tls\":{\"enabled\":true,\"server_name\":\"" json_escape(sni != "" ? sni : host_fallback()) "\"}")
        else if (tls_mode != "") {
            record_unsupported("vmess/tls=" tls_mode)
            next
        }

        node_emit()
        next
    }

    if (proto == "ss") {
        split_tag_query(body)
        if (tag == "") tag = "shadowsocks"

        split_userinfo(base)
        if (userinfo != "") {
            if (index(userinfo, ":") == 0) userinfo = decode_base64(userinfo)
            auth = userinfo
            endpoint_base = endpoint
        } else {
            decoded = decode_base64(base)
            split_userinfo(decoded)
            auth = userinfo
            endpoint_base = endpoint
        }

        if (auth == "") next
        colon_idx = index(auth, ":")
        if (colon_idx == 0) next
        method = substr(auth, 1, colon_idx - 1)
        password = substr(auth, colon_idx + 1)
        parse_endpoint(endpoint_base, 8388)
        if (server == "") next

        node_begin("shadowsocks", tag)
        node_add_str("server", server)
        node_add_num("server_port", server_port)
        node_add_str("method", method)
        node_add_str("password", password)
        node_add_str("plugin", qp_get("plugin", ""))
        node_add_str("plugin_opts", qp_pick("plugin-opts", "plugin_opts", "", "", ""))
        node_add_str("network", qp_get("network", ""))
        node_emit()
        next
    }

    split_tag_query(body)
    split_userinfo(base)
    parse_endpoint(endpoint, 443)
    if (server == "") next

    if (tag == "") tag = proto

    if (proto == "vless") {
        if (userinfo == "") next
        transport = build_transport_json(host_fallback())
        if (transport == "__UNSUPPORTED__") next
        security_mode = tolower(qp_pick("security", "tls", "", "", ""))

        node_begin("vless", tag)
        node_add_str("server", server)
        node_add_num("server_port", server_port)
        node_add_str("uuid", url_decode(userinfo))
        node_add_str("flow", qp_get("flow", ""))
        node_add_str("network", qp_get("network", ""))
        node_add_str("packet_encoding", qp_pick("packetEncoding", "packet_encoding", "", "", ""))
        if (security_mode == "tls" || security_mode == "reality") node_add_json(build_tls_json(host_fallback(), 1))
        else if (security_mode != "" && security_mode != "none") {
            record_unsupported("vless/security=" security_mode)
            next
        }
        node_add_json(transport)
        node_emit()
        next
    }

    if (proto == "trojan") {
        transport = build_transport_json(host_fallback())
        if (transport == "__UNSUPPORTED__") next

        node_begin("trojan", tag)
        node_add_str("server", server)
        node_add_num("server_port", server_port)
        node_add_str("password", url_decode(userinfo))
        node_add_str("network", qp_get("network", ""))
        node_add_json(build_tls_json(host_fallback(), 1))
        node_add_json(transport)
        node_emit()
        next
    }

    if (proto == "hysteria") {
        node_begin("hysteria", tag)
        node_add_str("server", server)
        node_add_num("server_port", server_port)
        if (qp_get("mport", "") != "") node_add_json("\"server_ports\":" json_array_csv(qp_get("mport", "")))
        node_add_str("hop_interval", qp_get("hopInterval", ""))
        node_add_str("up", qp_get("up", ""))
        node_add_str("down", qp_get("down", ""))
        node_add_num("up_mbps", qp_pick("upmbps", "up_mbps", "", "", ""))
        node_add_num("down_mbps", qp_pick("downmbps", "down_mbps", "", "", ""))
        node_add_str("obfs", qp_get("obfs", ""))
        node_add_str("auth", qp_get("auth", ""))
        node_add_str("auth_str", userinfo != "" ? url_decode(userinfo) : qp_pick("auth_str", "password", "", "", ""))
        node_add_str("network", qp_get("network", ""))
        node_add_json(build_tls_json(host_fallback(), 1))
        node_emit()
        next
    }

    if (proto == "hysteria2") {
        node_begin("hysteria2", tag)
        node_add_str("server", server)
        node_add_num("server_port", server_port)
        if (qp_get("mport", "") != "") node_add_json("\"server_ports\":" json_array_csv(qp_get("mport", "")))
        node_add_str("hop_interval", qp_pick("hopInterval", "hop_interval", "", "", ""))
        node_add_str("hop_interval_max", qp_pick("hopIntervalMax", "hop_interval_max", "", "", ""))
        node_add_num("up_mbps", qp_pick("upmbps", "up_mbps", "", "", ""))
        node_add_num("down_mbps", qp_pick("downmbps", "down_mbps", "", "", ""))
        obfs_type = qp_get("obfs", "")
        obfs_password = qp_pick("obfs-password", "obfs_password", "", "", "")
        if (obfs_password == "" && obfs_type != "" && obfs_type != "salamander" && obfs_type != "gecko") {
            obfs_password = obfs_type
            obfs_type = "salamander"
        }
        if (obfs_type != "" && obfs_password != "") node_add_json("\"obfs\":{\"type\":\"" json_escape(obfs_type) "\",\"password\":\"" json_escape(obfs_password) "\"}")
        node_add_str("password", userinfo != "" ? url_decode(userinfo) : qp_pick("password", "", "", "", ""))
        node_add_str("network", qp_get("network", ""))
        node_add_json(build_tls_json(host_fallback(), 1))
        node_emit()
        next
    }

    if (proto == "tuic") {
        colon_idx = index(userinfo, ":")
        if (colon_idx == 0) next
        tuic_uuid = url_decode(substr(userinfo, 1, colon_idx - 1))
        tuic_password = url_decode(substr(userinfo, colon_idx + 1))

        node_begin("tuic", tag)
        node_add_str("server", server)
        node_add_num("server_port", server_port)
        node_add_str("uuid", tuic_uuid)
        node_add_str("password", tuic_password)
        node_add_str("congestion_control", qp_get("congestion_control", ""))
        node_add_str("udp_relay_mode", qp_get("udp_relay_mode", ""))
        if (truthy(qp_get("udp_over_stream", ""))) node_add_bool("udp_over_stream", "true")
        if (truthy(qp_pick("zero_rtt", "zero_rtt_handshake", "", "", ""))) node_add_bool("zero_rtt_handshake", "true")
        node_add_str("heartbeat", qp_get("heartbeat", ""))
        node_add_str("network", qp_get("network", ""))
        node_add_json(build_tls_json(host_fallback(), 1))
        node_emit()
        next
    }

    if (proto == "socks") {
        colon_idx = index(userinfo, ":")
        socks_user = ""
        socks_pass = ""
        if (colon_idx > 0) {
            socks_user = url_decode(substr(userinfo, 1, colon_idx - 1))
            socks_pass = url_decode(substr(userinfo, colon_idx + 1))
        } else if (userinfo != "") {
            socks_user = url_decode(userinfo)
        }

        node_begin("socks", tag)
        node_add_str("server", server)
        node_add_num("server_port", server_port)
        node_add_str("version", qp_get("version", "5"))
        node_add_str("username", socks_user)
        node_add_str("password", socks_pass)
        node_add_str("network", qp_get("network", ""))
        node_emit()
        next
    }

    if (proto == "http" || proto == "https") {
        colon_idx = index(userinfo, ":")
        http_user = ""
        http_pass = ""
        if (colon_idx > 0) {
            http_user = url_decode(substr(userinfo, 1, colon_idx - 1))
            http_pass = url_decode(substr(userinfo, colon_idx + 1))
        } else if (userinfo != "") {
            http_user = url_decode(userinfo)
        }

        node_begin("http", tag)
        node_add_str("server", server)
        node_add_num("server_port", server_port)
        node_add_str("username", http_user)
        node_add_str("password", http_pass)
        node_add_str("path", qp_get("path", ""))
        if (qp_get("host", "") != "") node_add_json("\"headers\":{\"Host\":\"" json_escape(qp_get("host", "")) "\"}")
        if (proto == "https" || truthy(qp_get("tls", "")) || tolower(qp_get("security", "")) == "tls") node_add_json(build_tls_json(host_fallback(), 1))
        node_emit()
        next
    }

    record_unsupported(proto)
}
' "${input}" | run_pipeline || {
            log_error "Pipeline execution failed"
            return 1
        }

        if [ -s "${unsupported_file}" ]; then
            while IFS= read -r proto; do
                [ -n "${proto}" ] || continue
                log_warn "Skipped unsupported URI protocol: ${proto}"
            done <"${unsupported_file}"
        fi
    fi
    return 0
}

_validate_and_deploy() {
    local new_cfg="${1}"
    local core_cfg="${2}"

    # Basic validation
    local count
    count=$("${JQ_BIN}" --argjson infra "${INFRASTRUCTURE_TYPES}" \
        '[.outbounds[] | select(.type | IN($infra[]) | not)] | length' "${new_cfg}" 2>/dev/null || echo 0)

    is_int "${count}" || count=0
    [ "${count}" -gt 0 ] || {
        log_error "No proxy nodes generated"
        return 1
    }

    if [ -x "${SING_BOX_BIN}" ]; then
        local check_file="${WORK_DIR}/check_config.json"
        if "${JQ_BIN}" -s '.[0] as $template | .[1] as $nodes | $template | .outbounds = $nodes.outbounds' \
            "${TEMPLATE_FILE}" "${new_cfg}" >"${check_file}" 2>/dev/null; then
            :
        else
            cp -f "${new_cfg}" "${check_file}" || return 1
        fi
        if ! "${SING_BOX_BIN}" check -c "${check_file}" -D "${RUN_DIR}" >/dev/null 2>&1; then
            log_error "sing-box validation failed, keeping current config"
            return 1
        fi
    fi

    if [ -f "${core_cfg}" ] && cmp -s "${new_cfg}" "${core_cfg}"; then
        log_warn "Config unchanged, skip deploy"
        rm -f "${new_cfg}"
        return 0
    fi

    # Atomic Deploy with Single Backup
    [ -f "${core_cfg}" ] && {
        cp -p "${core_cfg}" "${core_cfg}.bak"
        log_debug "Backup created: $(basename "${core_cfg}.bak")"
    }

    if ! mv -f "${new_cfg}" "${core_cfg}"; then
        log_error "Atomic deploy failed"
        return 1
    fi
    chmod 644 "${core_cfg}"
    log_info "Deployed: ${count} nodes"
    return 0
}

# ==============================================================================
# [ Main Orchestration ]
# ==============================================================================

do_update() {
    trap 'cleanup "Cleaning up updater workspace..." "${TMP_CONFIG}" "${WORK_DIR}"' EXIT INT TERM

    log_info "Starting subscription update..."

    # Setup safe workspace
    WORK_DIR=$(mktemp -d "${RUN_DIR}/work.XXXXXX") || return 1
    local sub_raw="${WORK_DIR}/sub_raw"
    TMP_CONFIG="${WORK_DIR}/config.json"

    [ -n "${SUBSCRIPTION_URL}" ] || {
        log_error "SUBSCRIPTION_URL is empty"
        return 1
    }

    # Check dependencies
    [ -f "${JQ_BIN}" ] || {
        log_error "JQ missing"
        return 1
    }
    command -v base64 >/dev/null 2>&1 || {
        log_error "base64 command missing"
        return 1
    }
    [ -f "${TEMPLATE_FILE}" ] || {
        log_error "Template missing"
        return 1
    }
    [ ! -x "${JQ_BIN}" ] && chmod +x "${JQ_BIN}" 2>/dev/null

    # Execution stages: fetch -> transform -> deploy
    run -v "Fetch subscription" _fetch_and_decode "${SUBSCRIPTION_URL%%#*}" "${sub_raw}" || return $?
    run -v "Transform nodes" _transform_nodes "${sub_raw}" "${TMP_CONFIG}" || return $?
    run -v "Final validation & Deploy" _validate_and_deploy "${TMP_CONFIG}" "${CONFIG_FILE}" || return $?

    TMP_CONFIG="" # Safety: deployed successfully
    return 0
}

main() {
    local action="${1:-update}"

    case "${action}" in
    update)
        do_update
        ;;
    *)
        echo "Usage: $0 {update}"
        exit 1
        ;;
    esac
}

main "$@"
