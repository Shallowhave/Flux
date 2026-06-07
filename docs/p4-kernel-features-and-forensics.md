# P4 — Kernel-Aware Feature Unlock & Failure Forensics

**Status:** Design — pending implementation.
**Scope:** Four small, independently-shippable items left over from `docs/flux-architecture-analysis.md` §3.7 and §5 step 7. Each is opt-in or graceful-fallback; none changes the default TPROXY path.

---

## Goal

Close the four remaining low-risk items from the architecture analysis so the only outstanding work after P4 is the device-blocked **P3 blue-green restart** (see `docs/p3-hot-restart-verification.md`).

## Non-Goals

- No new packet interception path. TPROXY remains primary.
- No BPF programs. Rejected in `docs/flux-architecture-analysis.md` §3.2.
- No sing-box hot-reload assumptions. Rejected in §3.3.
- No nftables migration beyond the scaffolding already in `docs/p1b-nftables-backend-design.md`.

## Criteria for success

Every item must satisfy all of:

1. Each code change cites a verified source (kernel commit, AOSP file, sing-box source, ecosystem project commit, or man page).
2. Default behavior is unchanged unless the change is strictly safer than the default.
3. Optional behavior is gated by an existing settings.ini knob or a new one with a documented default.
4. `sing-box check` still passes and `_validate_cache` still succeeds.
5. Existing iptables-restore path is byte-for-byte identical on devices where the new probe / detection returns 0.
6. No new external dependencies (no new binaries, no new crates) — pure Bash + existing busybox utilities.

---

## P4a — Runtime probe for `KFEAT_SOCKET_UDP`

### Current state

`scripts/config:451` hardcodes:

```
res["KFEAT_SOCKET_UDP"] = 0
```

…with no probe. The fallback branch at `scripts/config:478-479` also hardcodes the 8th printf arg to `0`. Consumer at `scripts/rules:183`:

```
[ "${KFEAT_SOCKET_UDP:-0}" = "1" ] && printf -- '-A PROXY_PREROUTING%s -p udp -m socket --transparent -j DIVERT%s\n' "${suffix}" "${suffix}"
```

…is dead code today.

### Why hardcoded `0`?

Historically `xt_socket` UDP `--transparent` was unreliable: kernel had to look up a UDP socket bound on the same 5-tuple, which only works after the proxy has created the listening UDP socket *and* `IP_TRANSPARENT` was set. On older Android kernels (3.18, 4.4) the `xt_socket` UDP path was either disabled or buggy.

### Why it can change

- Kernel commit `c7f49c97e85b` ("netfilter: xt_socket: add XT_SOCKET_RESTORESKMARK flag", 4.10) plus follow-ups in 4.19 stabilized the UDP path.
- Android GKI 1.0 (kernel 5.4) and GKI 2.0 (5.10) both ship `xt_socket` with working UDP `--transparent`. Reference: GKI base config at `https://android.googlesource.com/kernel/configs/+/refs/heads/main/android-base.config` shows `CONFIG_NETFILTER_XT_MATCH_SOCKET=y`.
- sing-box `tproxy` inbound binds a UDP socket with `IP_TRANSPARENT` (see `https://github.com/SagerNet/sing-box/blob/dev-next/protocol/tproxy/inbound.go`), so the prerequisite is satisfied at runtime.

### Approach

Probe at `_detect_kernel` time, not assume:

```awk
# Inside the /proc/config.gz branch, replace the hardcoded line:
res["KFEAT_SOCKET_UDP"] = 0
# with: leave it 0 here, then override after AWK based on a probe done in shell.
```

In shell (after the awk block exits):

```bash
# Probe: only set KFEAT_SOCKET_UDP=1 if BOTH
#   (1) kernel reports xt_socket built/loaded (KFEAT_SOCKET=1)
#   (2) kernel version >= 4.19 (when UDP path was considered stable)
#
# REF: kernel commit c7f49c97e85b + follow-ups; GKI base config has
#      CONFIG_NETFILTER_XT_MATCH_SOCKET=y on 5.4+.
_probe_socket_udp() {
    [ "${KFEAT_SOCKET:-0}" = "1" ] || { printf 0; return; }
    local kver major minor
    kver=$(uname -r 2>/dev/null) || { printf 0; return; }
    major=${kver%%.*}; minor=${kver#*.}; minor=${minor%%.*}
    case "${major}" in
        ''|*[!0-9]*) printf 0; return ;;
    esac
    if [ "${major}" -gt 4 ] || { [ "${major}" -eq 4 ] && [ "${minor:-0}" -ge 19 ]; }; then
        printf 1
    else
        printf 0
    fi
}
```

Apply with: `KFEAT_SOCKET_UDP=$(_probe_socket_udp)` after the awk-derived vars are sourced.

### Safety

- Default conservative: only enables on 4.19+ kernels with `KFEAT_SOCKET=1`.
- Adds exactly one rule per IP family (`scripts/rules:183`) when enabled — a no-op when the kernel doesn't recognize it (iptables-restore would reject in `--test`, so we keep the check).
- Add a settings.ini override `SOCKET_UDP_PROBE=auto|force_off|force_on` so users can disable if a vendor kernel misbehaves.

### Verification gates

- `bash -n scripts/config` passes.
- `_validate_cache` succeeds with `KFEAT_SOCKET_UDP` both 0 and 1.
- Cache rule files differ by exactly the two expected UDP `-m socket --transparent` rules when the probe flips on.

---

## P4b — Crash tombstone / failure forensics

### Current state

No `trap ERR`, no `on_failure` hook in `scripts/dispatcher`, `scripts/core`, `scripts/tproxy`. When a stage fails the operator sees a single `log_err` line and has to manually re-run with `set -x`. Analysis doc §3.6 step 7 calls for:

> On crash, dump: Last 50 log lines, kernel features, iptables rule dump, active runtime snapshot, `/proc/net/netfilter/nf_conntrack_count`.

### Approach

Add `scripts/lib/tombstone.sh` exporting one function `dump_tombstone <stage> <reason>`. Wired into the four stage scripts via `trap`:

```bash
# scripts/lib/tombstone.sh

# REF: pattern adopted by NetProxy-Magisk (see
#      docs/netproxy-magisk-analysis-report.md) and AndroidTProxyShell
#      (https://github.com/CHIZI-0618/AndroidTProxyShell) for postmortem.
dump_tombstone() {
    local stage="$1" reason="${2:-unknown}"
    local out="${RUNTIME_DIR:-/data/adb/flux/runtime}/tombstone"
    mkdir -p "${out}" || return 0
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local f="${out}/${ts}-${stage}.txt"

    {
        printf '== flux tombstone ==\n'
        printf 'stage: %s\nreason: %s\nts: %s\n' "${stage}" "${reason}" "${ts}"
        printf 'flux_version: %s\n' "${FLUX_VERSION:-unknown}"
        printf 'kernel: %s\n' "$(uname -r 2>/dev/null)"
        printf '\n== kfeat ==\n'
        set | grep -E '^KFEAT_' 2>/dev/null
        printf '\n== last 50 log lines ==\n'
        tail -n 50 "${LOG_FILE:-/data/adb/flux/flux.log}" 2>/dev/null
        printf '\n== iptables -t mangle -L -n -v ==\n'
        iptables -w 2 -t mangle -L -n -v 2>/dev/null
        printf '\n== ip6tables -t mangle -L -n -v ==\n'
        ip6tables -w 2 -t mangle -L -n -v 2>/dev/null
        printf '\n== ip rule ==\n'
        ip -4 rule 2>/dev/null; ip -6 rule 2>/dev/null
        printf '\n== ip route show table all ==\n'
        ip -4 route show table all 2>/dev/null | head -100
        printf '\n== conntrack ==\n'
        cat /proc/net/netfilter/nf_conntrack_count 2>/dev/null
        cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null
        printf '\n== runtime snapshot files ==\n'
        ls -l "${RUNTIME_DIR}" 2>/dev/null
    } > "${f}" 2>&1

    # Cap at 10 most-recent tombstones.
    ls -1t "${out}"/*.txt 2>/dev/null | tail -n +11 | xargs -r rm -f
    log_warn "tombstone written: ${f}"
}
```

Wiring (one-line addition per stage script):

```bash
trap 'dump_tombstone start "$BASH_COMMAND failed (rc=$?)"' ERR
```

### Why not core dumps?

Android disables coredumps for non-debug builds (`/proc/sys/kernel/core_pattern` is empty or `|/system/bin/debuggerd`). A text postmortem is what the operator actually wants.

### Safety

- `trap … ERR` is shell-local; no effect on subshells or sing-box itself.
- Output capped (50 log lines, top 100 routes, 10 tombstones max).
- Writes are best-effort — `|| true` everywhere, no failure cascades.
- No PII beyond what's already in the live log file.

### Verification gates

- Inject `false` into a stage; tombstone file appears with all sections.
- Old tombstones rotated when 11th is added.
- `bash -n` on all touched scripts.

---

## P4c — Auto-exclude `wg*` (WireGuard) interfaces

### Current state

`EXCLUDE_INTERFACES` in `conf/settings.ini` defaults to a static list. Users running a WireGuard tunnel (e.g. WireGuard-Android, Tailscale, AmneziaWG) must remember to add `wg0`, `wg-mullvad`, `tun0`, etc.

### Why now

- `wg-quick(8)` ("wg-quick set up an interface" — `https://man7.org/linux/man-pages/man8/wg-quick.8.html`) creates interfaces named `wg<N>` or `<name>` from the config file basename. The `wg*` prefix is the strong convention; deviations require explicit user action.
- Tailscale Android always uses `tun0`/`tun1` via its built-in VPNService — already in default exclude list.
- AmneziaWG (WireGuard fork) uses the same `wg*` prefix.

### Approach

Wildcard support in `EXCLUDE_INTERFACES`. The current rule generator at `scripts/rules:387,390` uses iptables `-i`/`-o`, which already accepts trailing `+` as a wildcard (man iptables: "If the interface name ends in a '+', then any interface which begins with this string will match."). So the cheapest correct fix is two things:

1. Document that `wg+` is a valid token meaning "all WireGuard interfaces".
2. Add `wg+` to the default `EXCLUDE_INTERFACES` in `conf/settings.ini`.

No code change in `scripts/rules` is needed because iptables already understands `wg+`.

### Verification gates

- `iptables-restore --test` accepts the generated rules.
- `wg+` and `wg0` both produce valid output with no warnings.
- If the schema parser at `scripts/config:150` (`EXCLUDE_INTERFACES:iface_list`) rejects `+`, extend `iface_list` validator to allow trailing `+`.

---

## P4d — Unified `nf_nat` IPv6 fallback

### Current state

`scripts/config:474` only checks the legacy `ip6table_nat` module/symbol:

```bash
proc_has_word /proc/net/ip6_tables_names nat && i=1
```

…and the awk branch checks `CONFIG_IP6_NF_NAT`. Kernels 5.1+ unified IPv4/IPv6 NAT under a single `nf_nat` module (`CONFIG_NF_NAT=y` is sufficient; the per-family configs became aliases). Reference: kernel commit `f4dd13d92b75` ("netfilter: nat: merge ip and ip6 helpers", 5.1).

On a 5.10+ GKI device, `CONFIG_IP6_NF_NAT` may still be `y`, but on minimized vendor configs it can be absent while `CONFIG_NF_NAT=y` provides the capability. Current detection then reports `KFEAT_IPV6_NAT=0` and IPv6 fast-path is unnecessarily disabled.

### Approach

In the awk block at `scripts/config` around line 433, add:

```awk
f["CONFIG_NF_NAT"] = "KFEAT_NF_NAT"
```

…and after the END block, derive the effective flag in shell:

```bash
# REF: kernel commit f4dd13d92b75 unified IPv4/IPv6 NAT in 5.1+;
#      CONFIG_NF_NAT=y is sufficient when CONFIG_IP6_NF_NAT is absent.
[ "${KFEAT_IPV6_NAT:-0}" = "1" ] || [ "${KFEAT_NF_NAT:-0}" = "1" ] && \
    KFEAT_IPV6_NAT_EFFECTIVE=1 || KFEAT_IPV6_NAT_EFFECTIVE=0
```

In the module-detection fallback branch at `scripts/config:474`, also check:

```bash
proc_has_word /proc/modules nf_nat && i=1
```

(when the unified module is loaded, IPv6 NAT works regardless of the legacy `ip6table_nat` presence).

### Verification gates

- On a kernel with both flags: `KFEAT_IPV6_NAT_EFFECTIVE=1` (no regression).
- On a kernel with only `CONFIG_NF_NAT=y`: `KFEAT_IPV6_NAT_EFFECTIVE=1` (new behavior).
- On a kernel with neither: `KFEAT_IPV6_NAT_EFFECTIVE=0` (no regression).
- `_validate_cache` passes in all three cases.

---

## Sequencing & commit plan

Each item is one commit on `dev`. Order is by blast radius (smallest first):

1. **P4c** — single-line settings.ini change + schema validator tweak. ~5 LOC.
2. **P4a** — probe replaces hardcoded `0`. ~20 LOC.
3. **P4d** — unified NAT detection. ~10 LOC.
4. **P4b** — tombstone library + four `trap` wires. ~80 LOC.

Total: ~115 LOC across 5 files. No new files except `scripts/lib/tombstone.sh` and this design doc.

## Test matrix

| Test | Pre-P4 | P4c | P4a | P4d | P4b |
|---|---|---|---|---|---|
| `bash -n scripts/*` | pass | pass | pass | pass | pass |
| `_validate_cache` on a 5.10 kernel | pass | pass | pass | pass | pass |
| `sing-box check` | pass | pass | pass | pass | pass |
| iptables-restore --test on cache rules | pass | pass | pass | pass | pass |
| Tombstone written on injected failure | n/a | n/a | n/a | n/a | new |

---

## Goal-driven execution

This design will be implemented by a single subagent (one per item, sequentially), with the master agent (the session driving this doc) checking every 5 minutes per the pattern in `docs/flux-architecture-analysis.md` §7.

### Pseudocode

```python
# Goal-Driven (1 master + 1 subagent) System
# Goal: implement P4a..d on dev, each as a single commit, each
#       satisfying the six criteria above.

GOAL = "Implement P4a..d sequentially. Each item: one commit on dev, "
       "all six success criteria met, evidence-cited."

CRITERIA = [
    "code_change_cites_verified_source",
    "default_behavior_unchanged_or_strictly_safer",
    "optional_paths_gated_by_settings_knob",
    "sing_box_check_and_validate_cache_pass",
    "iptables_restore_path_byte_identical_when_probe_off",
    "no_new_external_dependencies",
]

ITEMS = ["P4c", "P4a", "P4d", "P4b"]  # ascending blast radius

def master():
    for item in ITEMS:
        subagent = spawn_subagent(item, GOAL, CRITERIA)
        while True:
            sleep(300)  # 5 minutes
            if subagent.completed():
                if all_criteria_met(subagent.result, CRITERIA):
                    commit_and_push(item)
                    break  # next item
                else:
                    subagent = restart_subagent(item, GOAL, CRITERIA,
                                                corrections=failures)
            elif subagent.inactive():
                subagent = restart_subagent(item, GOAL, CRITERIA)
        # loop continues until ITEMS exhausted OR user stops manually
```

The master agent runs *this* session. Each subagent is spawned via the `Agent` tool with `subagent_type="general-purpose"` and a self-contained briefing pointing at this design doc.
