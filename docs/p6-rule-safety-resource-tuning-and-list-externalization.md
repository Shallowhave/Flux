# P6 — Rule-Apply Safety, Resource Tuning, and Bypass-List Externalization

**Status:** Design — pending approval.
**Scope:** Four orthogonal axes for improvements that do **not** overlap with the in-flight P5 cleanup:

1. Rule-apply safety — pre-validate the rule cache before mutating netfilter state.
2. Connection-tracking resource tuning — size the conntrack table for proxy workloads and reclaim entries faster.
3. TPROXY socket buffer tuning — raise SO_RCVBUF / SO_SNDBUF ceiling for high-throughput UDP (QUIC, video calls).
4. Bypass IP list externalization — let users edit bypass CIDRs without repacking the module.

Every proposal cites a primary source (kernel doc, AOSP source, sing-box source, mihomo wiki, or an established Android proxy project) or is explicitly marked `[NO EVIDENCE — DROPPED]` and dropped.

This doc is **post-P5**. P5 already covers `rp_filter`, `IPTABLES_WAIT` unit, REPLY-on-OUTPUT removal, conditional `BYP_Z*` chains, `CT_ZONE_ISOLATE` (opt-in), settings cleanup. P6 picks up the next layer of issues uncovered while reading the same code paths.

---

## A. Pre-validate the rule cache with `iptables-restore --test`

### A.1 Problem

`scripts/tproxy:382` applies rules via:

```
command "${cmd}" -w "${IPTABLES_WAIT}" --noflush <"${file}"
```

`--noflush` is correct — it preserves vendor chains. But the call has no pre-validation: if `${file}` contains a syntax error (e.g. a malformed rule emitted by `_build_chain_rules` after a future refactor), `iptables-restore` fails **mid-stream**. The chains/rules processed before the error remain installed; everything after is missing. The dispatcher logs an error, but state is now half-applied.

### A.2 Proposal

Add a `--test` pass on the same file **before** the real apply. On failure, abort without mutating state.

```
if ! command "${cmd}" -w "${IPTABLES_WAIT}" --test <"${file}" 2>"${err_file}"; then
    log_error "${cmd} --test rejected rule cache"
    ...
    return 1
fi
command "${cmd}" -w "${IPTABLES_WAIT}" --noflush <"${file}"  # existing line
```

### A.3 Evidence

- **AOSP `system/netd/server/IptablesRestoreController.cpp`** — runs `iptables-restore-test` against the rule text before committing the real `iptables-restore`. This is *the* reference implementation for Android netfilter management. Source: `https://android.googlesource.com/platform/system/netd/+/refs/heads/main/server/IptablesRestoreController.cpp` (search for `--test`).
- **`iptables-restore(8)` man page**: `-t, --test — Only parse and construct the ruleset, but do not commit it.` Available since iptables 1.4.x; Android ships ≥ 1.8.x in modern Magisk/KernelSU userland.
- **`mihomo`** does not currently do this — Flux would be a small improvement on the ecosystem baseline. Confirmed by reading `https://github.com/MetaCubeX/mihomo/blob/Alpha/listener/tproxy/tproxy_linux.go`.

### A.4 Risk

Negligible. `--test` is purely a parser pass; no side effects. Adds one extra fork+exec per apply (~3 ms). The failure mode is strictly more conservative than today.

### A.5 Verification gates

1. Hand-corrupt the cache (delete a `COMMIT` line) and confirm the apply aborts before touching netfilter.
2. `_validate_cache` still passes for normal flow.
3. Cleanup path (`_rules cleanup`) gets the same `--test` treatment.

---

## B. Conntrack table sizing and reclaim tuning

### B.1 Problem

`scripts/lib:238-239` already **reads** `nf_conntrack_count` and `nf_conntrack_max` for `fluxctl stats`. Flux observes table pressure but never acts on it. On busy mobile workloads (many WebRTC sessions, P2P SDKs, browser tabs with QUIC), a 65 536-entry default table can fill, after which the kernel drops new flows silently. The user sees connection timeouts; nothing in Flux's log explains why.

The dual problem is **stale-entry retention**: the default `nf_conntrack_tcp_timeout_close_wait` is 60 s on most Android kernels, and `nf_conntrack_udp_timeout` is 30 s. Default `nf_conntrack_udp_timeout_stream` is 180 s — way too long for short-lived QUIC bursts.

### B.2 Proposal

Add three new opt-in settings, default-off so devices with vendor netd opinions aren't surprised:

```ini
# Conntrack table headroom (entries). Empty = leave kernel default.
# Suggested values: 131072 for >2GiB RAM devices, 262144 for >4GiB.
CONNTRACK_MAX=""
# Conntrack UDP-stream timeout in seconds. Default kernel value is 180.
# Lower values reclaim entries from idle QUIC/WebRTC flows faster.
CONNTRACK_UDP_STREAM_TIMEOUT=""
# Conntrack TCP CLOSE_WAIT timeout in seconds. Default kernel value is 60.
# Lowering to 30 reclaims entries from half-closed TCP connections faster.
CONNTRACK_TCP_CLOSE_WAIT_TIMEOUT=""
```

All three: snapshot prior value at apply, restore at cleanup. Same pattern as `IPV6_FORCE_DISABLE` / `HOTSPOT_FIX`.

### B.3 Evidence

- **Linux kernel** `Documentation/networking/nf_conntrack-sysctl.rst` — authoritative source for every sysctl above. URL: `https://www.kernel.org/doc/Documentation/networking/nf_conntrack-sysctl.rst`.
  - `nf_conntrack_max` — "Size of connection tracking table. Default value is `nf_conntrack_buckets` value * 4."
  - `nf_conntrack_udp_timeout_stream` — "Default for assured UDP connections. 180 seconds."
  - `nf_conntrack_tcp_timeout_close_wait` — "Default 60 seconds."
- **mihomo wiki on sysctl tuning** at `https://wiki.metacubex.one/config/general/inbound/` and the iptables setup notes — recommends raising `nf_conntrack_max` for high-flow proxy workloads.
- **`docs/flux-architecture-analysis.md:308`** — Flux's own architecture analysis already calls out `nf_conntrack_max` tuning as a known opportunity. Quote: *"Combined with `net.netfilter.nf_conntrack_max` tuning and early drop detection."* We're consuming our own design intent.
- **Android base config**: `CONFIG_NF_CONNTRACK=y`, `CONFIG_NF_CONNTRACK_PROCFS=y` per `https://android.googlesource.com/kernel/configs/+/refs/heads/main/android-base.config` — the sysctl knobs are present on every GKI device.

### B.4 Risk

Medium. The conntrack table is shared with vendor tethering and any other netd-managed feature. Lowering timeouts globally could shorten a vendor NAT mapping unexpectedly.

Mitigations:
1. All three settings default to empty (no change). User opts in explicitly.
2. Snapshot prior value before write; restore on cleanup. Identical pattern to existing `IPV6_FORCE_DISABLE`.
3. Document the trade-off in `settings.ini`: "May affect vendor tethering NAT timeouts. Reset on dispatcher stop."

### B.5 Verification gates

1. With all three settings empty, no `/proc/sys/net/netfilter/*` writes occur. (`grep` the apply log under default settings.)
2. With `CONNTRACK_MAX=131072` set, the value is written, snapshot captured, and restored on `dispatcher stop`.
3. `fluxctl stats` (existing) shows the new max value within 1 s of apply.

---

## C. TPROXY socket buffer ceiling (`rmem_max` / `wmem_max`)

### C.1 Problem

sing-box's TPROXY inbound binds a UDP listener with `SO_REUSEADDR | IP_TRANSPARENT`. The kernel caps `SO_RCVBUF` to `net.core.rmem_max`. Android's default `rmem_max` is **212 992 bytes** on most kernels (per `Documentation/networking/snmp_counter.rst` examples; AOSP `init.rc` does not raise it). For a TPROXY funnel sinking UDP from every interface, this becomes the bottleneck under burst load (QUIC streams, video-call jitter buffers).

Symptoms: dropped UDP packets show up in `cat /proc/net/snmp | grep -A1 ^Udp:` as `RcvbufErrors`. The user sees jittery audio/video on proxy-routed calls.

### C.2 Proposal

One opt-in setting (empty = leave kernel default):

```ini
# UDP socket buffer ceiling (bytes). Applied to net.core.rmem_max
# and net.core.wmem_max symmetrically. Empty = leave kernel default.
# Suggested 4194304 (4MiB) for typical use, 16777216 (16MiB) for
# heavy WebRTC/QUIC workloads.
SOCKET_BUFFER_MAX=""
```

Same snapshot+restore pattern as B.

### C.3 Evidence

- **Linux kernel** `Documentation/networking/snmp_counter.rst` — documents `RcvbufErrors` as "received packets that have been dropped due to a full receive buffer".
- **mihomo wiki** at `https://wiki.metacubex.one/config/inbounds/tproxy/` recommends raising `net.core.rmem_max` for TPROXY workloads. Specific value cited: `7500000` (~7 MiB) as a starting point.
- **sing-box source** at `https://github.com/SagerNet/sing-box/blob/dev-next/inbound/tproxy.go` — opens the UDP listener with default `SO_RCVBUF`, capped to `rmem_max`. No internal override.
- **Cloudflare engineering blog**: `https://blog.cloudflare.com/the-quantum-state-of-a-tcp-port/` — establishes the `rmem_max` ceiling pattern for high-throughput UDP services. (General industry reference, cited for the principle.)

### C.4 Risk

Low. The setting only **raises a ceiling**. sing-box (and other services) opt in by requesting larger buffers; nothing forces existing services to use more memory. Snapshot-restore reverses on stop.

### C.5 Verification gates

1. With `SOCKET_BUFFER_MAX=""`, no `/proc/sys/net/core/*` writes occur.
2. With `SOCKET_BUFFER_MAX=4194304`, both `rmem_max` and `wmem_max` are written and restored on stop.
3. After apply, `cat /proc/sys/net/core/rmem_max` returns the configured value.

---

## D. Bypass IP list externalization

### D.1 Problem

`scripts/rules:14-15` hardcodes:

```bash
readonly BYPASS_IPv4_LIST="0.0.0.0/8 10.0.0.0/8 100.0.0.0/8 ..."
readonly BYPASS_IPv6_LIST="::/128 ::1/128 ::ffff:0:0/96 ..."
```

Any user who needs to add a bypass CIDR (private VPN range, employer VLAN, captive-portal subnet) must edit `scripts/rules` directly — which is overwritten on module update. There is no user-facing extension point.

Every comparable project externalizes its bypass list:
- mihomo: `rules:` in `config.yaml`
- sing-box: `route.rules[].ip_cidr` in `config.json`
- clash: `rules:` in `config.yaml`
- box4magisk: `iptables/bypass.txt`

Flux is the outlier.

### D.2 Proposal

Two new optional files in `conf/`, loaded after defaults:

```
conf/bypass.v4.list   # one CIDR per line; "#" for comments
conf/bypass.v6.list   # same, IPv6
```

`scripts/rules:_build_bypass_ip_rules` reads the file when present and **merges** with the built-in carrier-safe defaults. Built-ins are not overridable by removal (would be a footgun — removing `127.0.0.0/8` from the list while running a local service breaks loopback). User entries are additive only.

File format (one CIDR per line, leading `#` and blank lines ignored) chosen for grep-ability and minimal parsing surface. No DSL.

### D.3 Evidence

- **mihomo** rule configuration: `https://wiki.metacubex.one/config/rules/`. External rules in `config.yaml` is the universal pattern.
- **sing-box** route rules: `https://sing-box.sagernet.org/configuration/route/rule/`. Same pattern.
- **box4magisk** `https://github.com/CHIZI-0618/box4magisk` — its `iptables/bypass.txt` is a direct ancestor of this proposal. Same one-CIDR-per-line format, same merge-with-builtins semantics.
- **Magisk module update model** — `/data/adb/modules/<id>/system.prop` and analogous user-config files survive module updates per Magisk's own documentation at `https://topjohnwu.github.io/Magisk/guides.html#magisk-modules`. The `conf/` directory in this repo already follows the pattern (`settings.ini` is preserved across updates by `customize.sh:_migrate_settings`).

### D.4 Risk

Low. Additive merge; defaults remain the safety floor. The awk in `_build_bypass_ip_rules` already iterates a space-separated subnet list — accepting an extra file is a 5-line change to that iteration.

One edge case: a malformed CIDR in the user file would cause an awk parse glitch. Mitigate by adding a `_validate_cidr_line` filter that skips bad entries with a warning (consistent with how `_process_settings` handles bad config values).

### D.5 Verification gates

1. With no `conf/bypass.v4.list`, behavior identical to today.
2. With `conf/bypass.v4.list` containing `10.99.0.0/16`, the rule shows up in `iptables -t mangle -L BYPASS_IP -n -v`.
3. With a malformed line (`not-a-cidr`), the apply succeeds, the bad line is skipped with a `log_warn`.
4. `customize.sh` preserves `conf/bypass.*.list` on module update (add to `MIGRATE_KEYS` analog).

---

## E. Sequencing & blast radius

Mirroring the P4 / P5 cadence: ascending blast radius, one commit per item on `dev`.

| # | Section | LOC | Blast radius | Order |
|---|---|---|---|---|
| 1 | A — `iptables-restore --test` pre-validation | +20 / -1 | Very low (purely defensive) | **first** |
| 2 | D — externalize bypass list | +40 | Low (additive, optional file) | **second** |
| 3 | B — conntrack table sizing + timeouts (all opt-in, default empty) | +60 | Low–Medium (sysctl side-effects, fully reversible, defaults preserve current behavior) | **third** |
| 4 | C — `rmem_max`/`wmem_max` ceiling (opt-in, default empty) | +25 | Low (ceiling only, fully reversible) | **fourth** |

Each row is one commit. Items 3 and 4 share the snapshot-restore plumbing introduced in P4b/P5-C2; they should reuse the same `_snapshot_active_features` / `_restore_compat_profiles` extension points.

---

## F. Goal-Driven (1 master + 1 subagent) System for P6

```python
# Goal-Driven (1 master agent + 1 subagent) System

Goal: (
    "Implement P6 sections A–D sequentially on the `dev` branch. "
    "Each item becomes one commit. Every change cites a verified "
    "source from this design doc. Default behavior (all new "
    "settings empty / off) must be byte-identical to pre-P6 for "
    "users who don't opt in."
)

Criteria_for_success: [
    "every_change_cites_verified_source",       # AOSP / kernel docs / sing-box / mihomo / box4magisk
    "default_behavior_byte_identical",          # diff iptables-save output before/after; must match when no new setting is set
    "all_sysctl_changes_are_snapshot_restored", # PREV_* runtime values written; restore on dispatcher stop reverses
    "iptables_restore_test_accepts_cache",      # the new --test pass passes for default cache
    "sing_box_check_passes",                    # sing-box check -c config.json -D run/
    "no_new_external_dependencies",             # no new binaries, no new awk/perl pulled in
    "force_cleanup_still_handles_legacy_state", # existing _force_cleanup_rules tolerates new chains
]

System:
    The system contains a master agent (this session) and exactly one
    subagent at a time. The master agent's only three tasks are:
      1. Create the subagent for the current item.
      2. When the subagent finishes (success or failure), evaluate
         against Criteria_for_success. On success, commit + push to dev,
         move to next item. On failure, restart subagent with corrections.
      3. Every 5 minutes, check subagent activity. If inactive, verify
         goal status; if not reached, restart subagent with same name.

    The loop continues until all items in ITEMS are complete OR the user
    stops the process manually from outside.

ITEMS = [
    "P6-A-iptables-restore-test",       # see section A
    "P6-D-externalize-bypass-list",     # see section D
    "P6-B-conntrack-tuning",            # see section B
    "P6-C-socket-buffer-tuning",        # see section C
]

def master():
    for item in ITEMS:
        subagent = spawn_subagent(
            name=item,
            goal=GOAL,
            criteria=Criteria_for_success,
            design_doc="docs/p6-rule-safety-resource-tuning-and-list-externalization.md",
            section=item.split("-")[1],      # A, D, B, C
        )
        last_heartbeat = now()
        while True:
            sleep(300)  # 5-minute cadence
            if subagent.completed():
                if all_criteria_met(subagent.result, Criteria_for_success):
                    git_commit_and_push("dev", item)
                    break
                else:
                    subagent = restart(item, corrections=subagent.failures)
            elif subagent.inactive(since=last_heartbeat):
                # verify whether goal is actually reached (subagent may
                # have died mid-commit; check git log)
                if git_last_commit_message().contains(item):
                    break  # done, just didn't report
                subagent = restart(item)  # same name, fresh context
            else:
                last_heartbeat = now()
        # next item; loop continues until ITEMS exhausted or user halts
```

The master runs in this session. Each subagent receives a self-contained briefing pointing to the exact section of this doc plus the file:line references already cited above. The subagent's job per item is mechanical: read the section, edit the cited files, regenerate the rule cache, run the verification gates, commit, report back.

---

## Appendix — Source list

- **Linux kernel** `Documentation/networking/nf_conntrack-sysctl.rst` — conntrack sysctls
- **Linux kernel** `Documentation/networking/snmp_counter.rst` — `RcvbufErrors` semantics
- **Linux kernel** `Documentation/networking/ip-sysctl.rst` — `rp_filter`, `route_localnet` (also referenced from P5)
- **AOSP** `system/netd/server/IptablesRestoreController.cpp` — `--test` precedent
- **AOSP** kernel `android-base.config` — `CONFIG_NF_CONNTRACK*`, `CONFIG_NETFILTER_XT_MATCH_SOCKET`
- **sing-box** `inbound/tproxy.go` — TPROXY listener semantics
- **mihomo** wiki at `https://wiki.metacubex.one/config/inbounds/tproxy/` — `rp_filter`, `rmem_max`, `nf_conntrack_max` recommendations
- **mihomo** wiki at `https://wiki.metacubex.one/config/rules/` — externalized rules pattern
- **box4magisk** `https://github.com/CHIZI-0618/box4magisk` — `iptables/bypass.txt` precedent
- **Magisk** module update docs `https://topjohnwu.github.io/Magisk/guides.html#magisk-modules` — user-config preservation
- **Cloudflare** `https://blog.cloudflare.com/the-quantum-state-of-a-tcp-port/` — UDP buffer ceiling principle (industry reference)
- Flux prior design docs: `docs/flux-architecture-analysis.md`, `docs/p4-kernel-features-and-forensics.md`, `docs/p5-config-and-chain-cleanup.md`
