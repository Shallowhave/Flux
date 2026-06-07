# P5 — Configuration Cleanup, Chain Shape, and Core Network Hotpath

**Status:** Design — pending approval.
**Scope:** Three orthogonal axes the user identified:
1. Settings cleanup — remove or clarify items with no clear purpose / rare use.
2. Firewall chain shape — find redundancies in the current iptables design.
3. Core network functionality and performance — find non-chain wins.

Every proposal cites a primary source (kernel commit/man page/AOSP/sing-box source/ecosystem project) or is explicitly marked `[NO EVIDENCE — DROPPED]` and dropped.

---

## A. Settings.ini cleanup

The current `conf/settings.ini` has 178 lines, 35 user-facing knobs. After this pass it should be ~150 lines, ~30 knobs, with each remaining knob having a one-line "when would I touch this" rationale.

### A.1 Audit table

Every knob below was checked against its consumers via grep. "Refs" is the count of source files (excluding README/docs/customize/settings.ini itself) that read the value.

| # | Knob | Refs | Verdict | Evidence |
|---|---|---|---|---|
| 1 | `SUBSCRIPTION_URL` | 1 (updater.sh) | **KEEP** | core feature |
| 2 | `UPDATE_TIMEOUT` | 1 | **KEEP** | covers slow networks |
| 3 | `RETRY_COUNT` | 1 | **KEEP** | covers flaky networks |
| 4 | `UPDATE_INTERVAL` | 1 | **KEEP** | core feature |
| 5 | `PREF_CLEANUP_EMOJI` | 1 (updater) | **KEEP** | UX, sing-box tag display |
| 6 | `LOG_LEVEL` | 1 (log) | **KEEP** | universal |
| 7 | `LOG_MAX_SIZE` | 1 (log) | **KEEP** | rotation policy |
| 8 | `CORE_USER` / `CORE_GROUP` | 2 (rules, init) | **KEEP but document risk** | needed for xt_owner loopback REJECT; changing them silently breaks loopback rule |
| 9 | `CORE_TIMEOUT` | 1 (core) | **KEEP** | startup gate |
| 10 | `MOBILE_INTERFACE` / `WIFI_INTERFACE` / `USB_INTERFACE` | 1 (rules) | **KEEP** | per-interface granularity |
| 11 | `HOTSPOT_INTERFACE` | 1 (rules) | **DOWNGRADE TO COMMENTED EXAMPLE** | Most devices don't expose a stable hotspot iface name. Use `wlan2` example only — leave blank by default. |
| 12 | `PROXY_MOBILE/WIFI/HOTSPOT/USB` | 1 (rules) | **KEEP** | per-interface switches |
| 13 | `PROXY_IPV6` | 2 (rules consumer + tproxy) | **KEEP, RECLASSIFY** | currently labeled "deprecated - now protocol-agnostic" in the comment but actually still drives the families loop at `scripts/tproxy:515` and `:539`. The comment is wrong and misleading. Either fix the comment or rename to clarify it controls IPv6 family activation. |
| 14 | `PROXY_MODE` | 4 | **KEEP** | tproxy/tun selection |
| 15 | `TUN_INTERFACE`/`TUN_INET4_ADDRESS`/`TUN_INET6_ADDRESS`/`TUN_MTU` | 1 (config) | **MOVE TO SUB-SECTION** | only meaningful when `PROXY_MODE=tun`; segregate into clearly conditional block |
| 16 | `ROUTING_MARK` | 1 (rules) | **KEEP** | alt path to xt_owner |
| 17 | `APP_PROXY_MODE` / `APP_LIST` / `APP_USER_SCOPE` / `APP_USER_LIST` | 2 (rules, config) | **KEEP** | core feature |
| 18 | `MSS_CLAMP_ENABLE` | 1 (rules) | **KEEP** | needed on carrier networks with PMTU blackholes |
| 19 | `BLOCK_QUIC` | 1 (tproxy) | **KEEP** | known sing-box+QUIC issue |
| 20 | `MARK_MASK` | 2 | **KEEP** | conntrack isolation primitive |
| 21 | `RULE_BACKEND` | 3 | **DEMOTE TO INTERNAL** | only value `iptables_restore` works today; `nft` is documented as falling back. No reason to expose this to users until P1b ships a real nft generator. Move to internal default; remove from settings.ini and from schema. (Evidence: `scripts/tproxy:362-368` explicitly logs "not yet implemented; falling back to iptables_restore".) |
| 22 | `BYPASS_SET_BACKEND` | 2 | **DEMOTE TO INTERNAL** | values `ipset`/`auto` are reserved-but-unused — only `zone` is exercised. `scripts/tproxy:101` just records the value verbatim with no branch. Hide until ipset backend lands. |
| 23 | `PERFORMANCE_MODE` | 2 | **KEEP, IMPROVE COMMENT** | only value `1` enables the DIVERT fast-path. Current comment "Optional socket/conntrack fast path" is opaque. Should say what it actually does and the kernel requirement. |
| 24 | `SOCKET_UDP_PROBE` | 2 | **KEEP** | added in P4a; well-documented already |
| 25 | `PRIVATE_DNS_GUARD` | 2 | **KEEP** | added in P2b; well-documented |
| 26 | `IPV6_FORCE_DISABLE` | 2 (tproxy) | **KEEP, ADD WARNING** | sets `/proc/sys/net/ipv6/conf/all/disable_ipv6=1` — system-wide effect. Comment should warn this affects non-Flux traffic too. |
| 27 | `VENDOR_FIX_PROFILE` | 2 (tproxy) | **REMOVE** | `scripts/tproxy:318-320` literally logs `"Vendor fix profile '...' is recorded but has no generic safe action"` then returns. It's recorded in features file but does nothing else. Only the enum value `oneplus` is listed and has no effect. Drop. |
| 28 | `HOTSPOT_FIX` | 2 (tproxy, rules indirect) | **KEEP, IMPROVE COMMENT** | enables IPv4 forwarding. Current comment doesn't say what gets fixed. Should say "Enables ip_forward=1 for share-from-hotspot scenarios where the upstream blocks unsolicited forwarding." |
| 29 | `EXCLUDE_INTERFACES` | 1 (rules) | **KEEP** | now defaults to `wg+` post-P4c |
| 30 | `UPDATER_EXCLUDE_REMARKS` | 1 (updater) | **KEEP** | core updater feature |
| 31 | `UPDATER_RENAME_RULES` | 1 (updater) | **KEEP** | core updater feature |
| 32 | `UPDATER_MAX_TAG_LENGTH` | 1 (updater) | **KEEP** | tag-length limit, sing-box tag constraint |
| 33 | `eBPF note` comment | 0 | **REMOVE** | the comment "Future eBPF helpers should stay diagnostic/auxiliary..." references a never-implemented feature and is the only orphan comment in the file. The analysis in `docs/flux-architecture-analysis.md` §3.2 already established BPF is not viable as primary interception. The note is misleading clutter. |

### A.2 Concrete removal/demotion list

**Remove from settings.ini AND schema (no consumer, or consumer is a no-op):**
- `VENDOR_FIX_PROFILE` — see row 27. The schema entry at `scripts/config:149`, the settings line at `conf/settings.ini:147`, and the three references in `scripts/tproxy:115, 176, 318` are all dead code. Removal LOC: ~10.
- Free-form `# eBPF note:` comment — see row 33.

**Demote to internal (defined as `readonly` in `scripts/lib`, removed from settings.ini AND schema; user cannot override until a real second value exists):**
- `RULE_BACKEND` — schema entry at `scripts/config:143` and settings entry at `conf/settings.ini:121`. Keep the variable name in code (`scripts/tproxy:100, 362`); just stop pretending it's a user knob. The "nft" log warning at `:362-368` becomes dead but stays as a guard against future config drift.
- `BYPASS_SET_BACKEND` — schema entry at `scripts/config:144` and settings entry at `conf/settings.ini:124`. Same treatment.

**Reword/reorganize (no semantic change):**
- `PROXY_IPV6` — fix the "deprecated" comment which is factually wrong (consumer is live at `scripts/tproxy:515, 539`).
- `HOTSPOT_INTERFACE` default `wlan2` — leave the schema default empty; show `wlan2` only as a commented example. Most users don't have `wlan2`; defaulting to a wrong value caused 'rule generated but never matches' confusion in NetProxy-Magisk (per `docs/netproxy-magisk-analysis-report.md`).
- TUN-mode knobs (`TUN_INTERFACE`, `TUN_INET4_ADDRESS`, `TUN_INET6_ADDRESS`, `TUN_MTU`) — group under a clearly-labeled `# Only used when PROXY_MODE=tun` sub-header instead of being mixed into general settings.
- `PERFORMANCE_MODE` — rewrite comment to: "Fast path: skip rule traversal for already-tracked proxied connections via xt_socket + connmark match. Requires KFEAT_SOCKET=1 (kernel 3.10+, universal on Android)."
- `HOTSPOT_FIX` — rewrite comment to: "Set net.ipv4.ip_forward=1 (and IPv6 equivalent when PROXY_IPV6=1) for tethering-share scenarios where the upstream rejects un-forwarded packets."
- `IPV6_FORCE_DISABLE` — prefix with a `# WARNING:` line — see row 26.
- `CORE_USER`/`CORE_GROUP` — prefix with a `# WARNING:` line: changing this requires sing-box to actually run as that uid/gid (init script doesn't enforce it), and the loopback REJECT rule at `scripts/rules:290` will silently break otherwise.

### A.3 Verification gates for A

1. `bash -n scripts/config conf/settings.ini` — exit 0 (settings.ini is loosely sourceable for syntax checks).
2. Schema entry count drops by 3 (RULE_BACKEND, BYPASS_SET_BACKEND, VENDOR_FIX_PROFILE).
3. `scripts/tproxy:318-320` dead block removed; cleanup function at `:334+` still handles `IPV6_FORCE_DISABLE` correctly (this branch is the only restoration-relevant one — VENDOR_FIX_PROFILE restoration was a no-op).
4. `_validate_cache` succeeds with default settings.ini.

---

## B. Firewall chain shape

The architecture is good. Two specific tightenings have direct precedent in established projects.

### B.1 Audit of current chain shape

Per `scripts/rules`:
- 24 chains created per family: `PROXY_PREROUTING`, `PROXY_OUTPUT`, `BYPASS_IP`, `APP_CHAIN`, `ACTION_PROXY_PRE`, `ACTION_PROXY_OUT`, `ACTION_BYPASS`, `BYP_Z0..15`, and optionally `DIVERT`.
- 16-zone bypass tree is intentional and documented (`scripts/rules:21-31`). This is the right design for iptables (the alternative is `ipset`, deferred until BYPASS_SET_BACKEND ships).
- Action chains (`ACTION_BYPASS`, `ACTION_PROXY_PRE`, `ACTION_PROXY_OUT`) are clean.

### B.2 Observation #1: `_build_fast_path_rules` emits identical TPROXY pair twice per family

Reading `scripts/rules:202-225` and `scripts/rules:153-169`:

The "fast path" block at `:218-219` issues:
```
-A PROXY_PREROUTING -m connmark --mark ${proxy_mark} -p tcp -j TPROXY --on-port ... --tproxy-mark ${proxy_mark}
-A PROXY_PREROUTING -m connmark --mark ${proxy_mark} -p udp -j TPROXY --on-port ... --tproxy-mark ${proxy_mark}
```

And the "slow path" terminal `ACTION_PROXY_PRE` chain at `:165-166`:
```
-A ACTION_PROXY_PRE -p tcp -j TPROXY --on-port ${PROXY_PORT} --tproxy-mark ${full_mark}
-A ACTION_PROXY_PRE -p udp -j TPROXY --on-port ${PROXY_PORT} --tproxy-mark ${full_mark}
```

…carry the same `--on-port` and `--tproxy-mark`. The fast path skips the BYPASS_IP zone walk + APP_CHAIN owner match for established connections, which is the whole point of `PERFORMANCE_MODE=1` — the duplication is **not redundancy**, it's an early termination shortcut. This is correct and matches the pattern used by `mihomo` (Clash.Meta) at `https://github.com/MetaCubeX/mihomo/blob/Alpha/listener/tproxy/tproxy_linux.go` and in `box4magisk`'s reference iptables script. **Leave it.**

### B.3 Observation #2: REPLY-direction ACCEPT also applied on OUTPUT

At `scripts/rules:210-212`:
```bash
[ "${KFEAT_CONNTRACK}" = "1" ] && {
    printf -- '-A PROXY_PREROUTING%s -m conntrack --ctdir REPLY -j ACCEPT\n' "${suffix}"
    printf -- '-A PROXY_OUTPUT%s -m conntrack --ctdir REPLY -j ACCEPT\n' "${suffix}"
}
```

On the OUTPUT chain, `--ctdir REPLY` matches the reply direction of a connection — but locally-originated packets traversing OUTPUT are virtually never in the REPLY direction (REPLY is from peer→us, which arrives at PREROUTING, not OUTPUT). The OUTPUT rule is a no-op in normal traffic.

**Evidence:** `man iptables-extensions` on `--ctdir`: "Match packets that are flowing in the specified direction. If this flag is not specified at all, matches packets in both directions."

REPLY-direction packets in OUTPUT exist only for split-host / NETMAP / oddball NAT setups, not Android.

**Proposal:** Drop the OUTPUT line. Saves one rule traversal per outbound packet per family. With two families (`PROXY_IPV6=1`) that's two rules per packet eliminated — a non-zero amount for high-pps traffic.

**Risk:** Negligible. The only way the OUTPUT REPLY rule could matter is if a local process somehow originates a packet that the kernel classifies as REPLY (e.g. injected via `nfqueue` reinjection). Not applicable to sing-box's outbound model.

**Precedent:** `mihomo`'s reference iptables setup script does NOT install the REPLY-on-OUTPUT rule. `box4magisk` doesn't either. AndroidTProxyShell doesn't either. We are the outlier.

### B.4 Observation #3: `BYP_Z*` chain creation is unconditional even when zone is empty

At `scripts/rules:11`, all 16 `BYP_Z0..BYP_Z15` chains are listed in `PROXY_CHAINS`, so `_build_ipt_chains` at `:193-199` creates all 16 chains, even though `_build_bypass_ip_rules` at `:72-79` only emits the jump-to-zone for zones that actually have entries (`if (!zones[i]) continue`).

**Consequence:** Empty chains exist but are never jumped to. They consume one chain slot each in the netfilter rule store and add noise to `iptables -L`. Not a correctness or perf issue (an empty chain is never traversed), just clutter.

Looking at `BYPASS_IPv4_LIST` (`scripts/rules:14`):
```
0.0.0.0/8 10.0.0.0/8 100.0.0.0/8 127.0.0.0/8 169.254.0.0/16
172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24
192.168.0.0/16 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4
240.0.0.0/4 255.255.255.255/32
```

Zone occupancy (first octet / 16):
- Zone 0 (0-15): `0.0.0.0/8`, `10.0.0.0/8`
- Zone 6 (96-111): `100.0.0.0/8`
- Zone 7 (112-127): `127.0.0.0/8`
- Zone 10 (160-175): `169.254.0.0/16`, `172.16.0.0/12`
- Zone 12 (192-207): six entries
- Zone 14 (224-239): `224.0.0.0/4` (multicast)
- Zone 15 (240-255): two entries

So **7 of 16 IPv4 zones are empty** by default. Likewise, IPv6 `BYPASS_IPv6_LIST` populates only ~5 zones.

**Proposal:** Make `BYP_Z*` chain creation conditional. Have `_build_bypass_ip_rules` first compute the set of zones-in-use, then emit `:BYP_Zn - [0:0]` only for those zones. The PROXY_CHAINS readonly list shrinks accordingly. Net effect: fewer phantom chains per family (rule count drops from ~24 per family to ~17 with default bypass list).

Implementation impact: one extra awk pass in `_build_bypass_ip_rules` or have it emit both the chain declarations and the rules from a single awk invocation. Caller (`_orchestrate`) passes the result through.

**Evidence:** No upstream project advocates phantom chains; this is purely a hygiene improvement. The pattern of "emit chain only when used" is universal — see `nft` rule generators across all major projects, and `iptables-save` output which omits empty chains.

**Risk:** Force-cleanup at `scripts/tproxy:419-428` references all 16 chains by name to flush+delete. If a chain doesn't exist, `iptables -X` returns non-zero; the existing `|| true` swallows that. Verify still works after the change.

### B.5 Verification gates for B

1. `iptables-restore --test` accepts the new rule cache (no syntax break).
2. `_validate_cache` still passes.
3. `iptables -t mangle -L | grep -c '^Chain BYP_Z'` shows only the populated zones (was 16, now 7 for default IPv4).
4. Force-cleanup still removes phantom-but-existing chains from prior installs (backwards compatibility).

---

## C. Other core network / performance optimizations

Three candidates examined; one accepted, two rejected with reasons.

### C.1 [ACCEPTED] `iptables -w` wait timeout — confirm and document the unit

At `scripts/tproxy:382`, the call is `iptables-restore -w "${IPTABLES_WAIT}"`. `IPTABLES_WAIT` is `100` per `scripts/lib`.

The `-w` flag on `iptables-restore` takes **seconds**, not centiseconds. The unit was changed between iptables versions:
- Old `iptables` (pre-1.6): `-w` is a boolean (block forever).
- New `iptables` (1.6+): `-w[seconds]` is a timeout in **seconds**. `iptables-restore --wait[=seconds]` same.

Reference: `iptables(8)` man page (Debian 1.8.x): `"-w, --wait [seconds] - Wait for the xtables lock. ... If a numeric value is provided, it is interpreted as the maximum number of seconds to wait."`

Reference: kernel iptables source `https://git.netfilter.org/iptables/tree/iptables/iptables.c` — `OPT_WAIT_INTERVAL` is parsed as seconds via `strtoul`.

**Current code sets `IPTABLES_WAIT=100`, which means 100 seconds.** That is much longer than intended (the comment-free constant suggests centiseconds were imagined). On a hung lock, dispatcher would block for 100 s before reporting failure.

**Proposal:** Reduce to `5` (seconds) and add a comment explaining the unit. 5 s is the value used by AOSP's `iptables-restore` wrapper at `system/netd/server/IptablesRestoreController.cpp` (Android source), which is the most authoritative precedent on Android.

**Evidence:** `https://android.googlesource.com/platform/system/netd/+/refs/heads/main/server/IptablesRestoreController.cpp` — search for `--wait`.

**Risk:** If a previous Flux invocation is mid-restore, the second invocation now fails after 5 s instead of 100 s. That is the desired behavior — fail fast and let the dispatcher lock arbitrate.

### C.2 [ACCEPTED] `sysctl` tunables: drop the magic, document the few that matter

`scripts/tproxy:296-321` applies a handful of `_write_file_value` calls. Audit:
- `/proc/sys/net/ipv4/ip_forward 1` — needed for HOTSPOT_FIX. Keep.
- `/proc/sys/net/ipv6/conf/all/disable_ipv6 1` — gated by IPV6_FORCE_DISABLE. Keep with the existing P4 warning.

Missing tunables that **established projects do set** for TPROXY hosts:

1. **`/proc/sys/net/ipv4/conf/all/rp_filter = 2`** (loose reverse-path filter).
   `mihomo`'s wiki at `https://wiki.metacubex.one/config/inbounds/tproxy/` and `https://github.com/MetaCubeX/mihomo/blob/Alpha/docs/api/iptables/iptables.md` both call out `rp_filter` as a TPROXY requirement. Without it, the kernel may drop packets entering on one interface whose route would leave on another — exactly the situation when TPROXY redirects.
   Kernel reference: `Documentation/networking/ip-sysctl.rst` on `rp_filter`: "1 - Strict mode... 2 - Loose mode". Loose mode is correct for TPROXY hosts.

2. **`/proc/sys/net/ipv4/conf/all/route_localnet = 1`** (optional, only for users hitting 127.0.0.1 from non-local). NetProxy-Magisk sets this; sing-box's docs at `https://sing-box.sagernet.org/configuration/inbound/tproxy/` show TPROXY listening on `::` which doesn't strictly require it, but some chipsets misbehave without it. Mark **optional** — opt-in via setting.

**Proposal:** When `PROXY_MODE=tproxy` and the apply runs, additionally set `rp_filter=2` on `all/` and on each `PROXY_*` interface; snapshot prior values for restoration. Make `route_localnet` opt-in via a new `LOCALNET_FIX=0` toggle (default off) — only users debugging localhost-redirect should enable.

**Risk:** `rp_filter=2` is strictly safer than `1` for TPROXY hosts. It does NOT disable RP filtering, only relaxes it. No risk on devices that already have `2` or `0`. Snapshot-restore on cleanup keeps it reversible.

**Evidence summary:**
- Mihomo wiki: `rp_filter=2` required.
- box4magisk reference iptables: sets `rp_filter=2`.
- Linux kernel docs (`Documentation/networking/ip-sysctl.rst`): defines `2` as "loose mode" for TPROXY hosts.

### C.3 [REJECTED] `tcp_fastopen` / `tcp_mtu_probing` / `tcp_notsent_lowat`

**Verdict:** Out of scope. These tune Android's local TCP stack, not sing-box's outbound. sing-box owns its socket options for its outbounds (see `option.OutboundDialerOptions`). Tuning system-wide TCP affects every other app on the device — high blast radius for ambiguous gain. **Drop with no implementation.**

**Evidence:** `https://github.com/SagerNet/sing/blob/dev-next/common/control/tcp_keep_alive_idle.go` and sibling files — sing-box manages its own socket options via `setsockopt` per outbound.

### C.4 [REJECTED] Per-family `ROUTE_BUDGET` tuning in addrsyncd

Mentioned in `flux-architecture-analysis.md` §3.7 as low-effort. After reading `addrsyncd` source, the budget is already adaptive (64–1024). Splitting per-family adds code paths without clear evidence that IPv6 specifically needs a different shape. **Defer.** Revisit only if metrics from `fluxctl stats` (added in P2a) show IPv6 path is starving.

### C.5 [ACCEPTED] Conntrack zone isolation — minimal version

Re-examination of `flux-architecture-analysis.md` §3.4 against current code:

The doc proposes `-j CT --zone 0x14` on PREROUTING and OUTPUT. The risk is that Android's vendor netd uses conntrack for tethering/NAT (see `https://android.googlesource.com/platform/system/netd/+/refs/heads/main/server/TetherController.cpp`), and unconditionally re-zoning every packet could break vendor tethering.

**Minimal version:** Apply `-j CT --zone 0x14` only on **Flux's own marked traffic** — that is, in `ACTION_PROXY_PRE` and `ACTION_PROXY_OUT`, not on PREROUTING/OUTPUT directly. The CT target is set after the bypass classification, so untouched (non-proxied) traffic stays in the system zone.

This requires `CONFIG_NF_CT_NETLINK` and `CONFIG_NF_CONNTRACK_ZONES` in the kernel. GKI base config has `CONFIG_NF_CONNTRACK_ZONES=y` per `https://android.googlesource.com/kernel/configs/+/refs/heads/main/android-base.config`.

**Evidence:**
- `iptables-extensions(8)` on `CT --zone`: "Assign this packet to zone id and only have lookups done in that zone."
- mihomo's TPROXY howto recommends zone isolation when running multiple TPROXY instances or alongside system NAT.
- AOSP netd `TetherController.cpp` uses zone 0 for tethering, so any non-zero zone is safe.

**Risk:** Moderate. Adds two new rules per family. Needs verification on a real device that the cleanup correctly removes them (existing snapshot-cleanup should handle this since the rules are inside the snapshot scope).

**Proposal scope:** Add as **opt-in** behind a new `CT_ZONE_ISOLATE=0` toggle (default off). When set, append two `-j CT --zone 0x14` rules at the head of the two action chains. Document the kernel requirement.

### C.6 Verification gates for C

1. `IPTABLES_WAIT` reduced to 5; comment cites AOSP `IptablesRestoreController.cpp`.
2. `rp_filter` snapshot+set+restore round-trips cleanly.
3. `route_localnet`/`CT_ZONE_ISOLATE` toggles default off; default behavior unchanged.
4. `_validate_cache` passes for all toggle combinations.

---

## D. Sequencing & blast radius

In ascending blast radius, identical to the P4 pattern:

| # | Section | LOC | Blast radius | Order |
|---|---|---|---|---|
| 1 | A.2 — remove `VENDOR_FIX_PROFILE` + `eBPF note` | -30 | None (dead code) | **first** |
| 2 | A.2 — demote `RULE_BACKEND` + `BYPASS_SET_BACKEND` | -15 | None (only one value worked) | **second** |
| 3 | A.2 — reword/regroup comments + warning prefixes | +30 / -10 | None (docs only) | **third** |
| 4 | B.3 — drop OUTPUT REPLY ACCEPT | -2 | Very low | **fourth** |
| 5 | B.4 — conditional BYP_Z chain creation | +20 / -5 | Low (force-cleanup unchanged) | **fifth** |
| 6 | C.1 — `IPTABLES_WAIT=5` + unit comment | +2 / -1 | Low | **sixth** |
| 7 | C.2 — `rp_filter=2` snapshot+set+restore | +30 | Medium (sysctl side-effect, fully reversible) | **seventh** |
| 8 | C.5 — opt-in `CT_ZONE_ISOLATE` | +20 | Medium (opt-in, default off) | **eighth (optional, can be deferred)** |

Each cell is one commit on `dev`. Items 1–3 are pure cleanup and should land together if reviewing convenient.

---

## E. Goal-driven execution

Same pattern as P4 — one master agent (this session) plus a single subagent per item, with 5-minute health-check cadence and explicit success criteria.

### E.1 Pseudocode

```python
# Goal-Driven (1 master + 1 subagent) System for P5

GOAL = (
    "Implement P5 sections A-C sequentially. Each item: one commit "
    "on dev, all six success criteria met, every change cites a "
    "verified source from this design doc."
)

CRITERIA = [
    "every_change_cites_verified_source",   # AOSP/kernel/sing-box/man page/established project
    "default_behavior_unchanged_for_kept_settings",
    "demoted_or_removed_settings_have_no_live_consumer",
    "sing_box_check_and_validate_cache_pass",
    "iptables_restore_test_accepts_cache",
    "no_new_external_dependencies",
    "all_sysctl_changes_are_snapshot_restored",
]

ITEMS = [
    "P5-A1-remove-dead-settings",      # VENDOR_FIX_PROFILE + eBPF note
    "P5-A2-demote-internal-settings",  # RULE_BACKEND, BYPASS_SET_BACKEND
    "P5-A3-comments-and-warnings",     # PROXY_IPV6 comment fix, warnings
    "P5-B3-drop-output-reply-accept",
    "P5-B4-conditional-byp-z-chains",
    "P5-C1-iptables-wait-seconds",
    "P5-C2-rp-filter-tunable",
    "P5-C5-ct-zone-isolate-optin",     # optional
]

def master():
    for item in ITEMS:
        subagent = spawn_subagent(item, GOAL, CRITERIA,
                                  design_doc="docs/p5-config-and-chain-cleanup.md")
        while True:
            sleep(300)
            if subagent.completed():
                if all_criteria_met(subagent.result, CRITERIA):
                    push_dev(item)
                    break
                else:
                    subagent = restart(item, corrections=subagent.failures)
            elif subagent.inactive():
                # current item not yet complete; restart with same goal
                subagent = restart(item)
        # next item, or stop when ITEMS exhausted / user halts manually
```

The master agent runs this session. Each subagent receives a self-contained briefing pointing to the exact section of this doc plus the file:line references already cited above.

---

## Appendix — Source list

- `iptables-extensions(8)` — `--ctdir`, `CT --zone`, `socket` match
- `iptables(8)` — `-w` semantics in 1.6+
- Linux kernel `Documentation/networking/ip-sysctl.rst` — `rp_filter` modes
- AOSP `system/netd/server/IptablesRestoreController.cpp` — wait timeout precedent
- AOSP `system/netd/server/TetherController.cpp` — tethering conntrack zone usage
- GKI `android-base.config` — `CONFIG_NF_CONNTRACK_ZONES=y`
- sing-box `protocol/tproxy/inbound.go` — TPROXY listening behavior
- sing-box `https://sing-box.sagernet.org/configuration/inbound/tproxy/` — config reference
- mihomo wiki `https://wiki.metacubex.one/config/inbounds/tproxy/` — `rp_filter=2` requirement
- mihomo `https://github.com/MetaCubeX/mihomo/blob/Alpha/listener/tproxy/tproxy_linux.go` — reference iptables pattern
- box4magisk `https://github.com/CHIZI-0618/box4magisk` — reference iptables script
- AndroidTProxyShell `https://github.com/CHIZI-0618/AndroidTProxyShell` — reference iptables script
- NetProxy-Magisk analysis at `docs/netproxy-magisk-analysis-report.md`
- Flux prior phases: `docs/flux-architecture-analysis.md`, `docs/p1b-nftables-backend-design.md`, `docs/p3-hot-restart-verification.md`, `docs/p4-kernel-features-and-forensics.md`
