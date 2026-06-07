# Flux Architecture Analysis & Improvement Recommendations

## 1. Executive Summary

Flux is a high-quality transparent proxy solution for Android, implemented as ~1,400 lines of Bash (11 scripts) + ~5,400 lines of Rust (addrsyncd daemon), shipped as a Magisk/KernelSU module. It uses sing-box as the core proxy engine and provides both TPROXY and TUN interception modes.

**Overall assessment:** The codebase shows strong engineering discipline — strict error handling, schema-driven configuration, atomic writes, runtime snapshots, and well-documented invariants. The suggestions below focus on closing the gap between the current iptables-centric architecture and where Android kernel networking is heading (BPF, nftables, cgroup-based policy).

---

## 2. Architecture Deep Dive

### 2.1 Component Map

```
magisk boot
  └─ flux_service (customize.sh → service.sh)
       └─ scripts/dispatcher          ← single orchestrator, mkdir-based lock
            ├─ scripts/init            ← integrity checks, cache build, update fetch
            │    ├─ scripts/config     ← awk schema parser, kernel feature detect
            │    └─ scripts/rules      ← iptables rule generation (O(1) zone tree)
            ├─ scripts/core            ← sing-box lifecycle (TPROXY or TUN)
            ├─ scripts/tproxy          ← iptables-restore + PBR (addrsyncd or ip-route)
            └─ scripts/addrsync        ← addrsyncd lifecycle
                 └─ addrsyncd (Rust)   ← netlink addr monitor + fwmark rule sync + PBR
```

### 2.2 Data Flow: Startup

```
init → build_config()
  ├─ _extract_json_config()        extract port/ranges from config.json via jq
  ├─ _process_settings()           awk: validate INI against schema, emit shell vars
  ├─ _apply_proxy_mode_config()    jq: swap TPROXY↔TUN inbounds
  ├─ _extract_json_config()        re-extract (port may have changed)
  ├─ _validate_singbox_config()    sing-box check
  └─ _detect_kernel()              zcat /proc/config.gz → KFEAT_* vars

init → _validate_cache()
  ├─ generate -A 4/6 → CACHE_RULES_V4/V6_FILE     (parallel)
  └─ generate -D 4/6 → CACHE_CLEANUP_V4/V6_FILE   (parallel)

dispatcher → start
  ├─ core start (sing-box)         ordered: must succeed first
  ├─ addrsync start                parallel with tproxy
  └─ tproxy start
       ├─ _snapshot_active_features()
       ├─ _snapshot_active_cleanup()  copy CACHE_CLEANUP → ACTIVE_CLEANUP
       ├─ _snapshot_active_runtime()  save all runtime state + prev sysctl values
       ├─ _apply_compat_profiles()    sysctl + settings put
       └─ for each family (4, 6):
            ├─ _rules apply         iptables-restore --noflush
            ├─ _route apply         addrsyncd pbr apply (or ip rule/route)
            └─ _block_quic apply    (optional)
```

### 2.3 Data Flow: addrsyncd Event Loop

```
epoll_wait([route_fd, rule_fd, signal_fd, timer_fd])
  ├─ EPOLL_TAG_ROUTE → handle_route_events()
  │    ├─ recv_many() on netlink socket (MmsgRxRing, adaptive sizing)
  │    ├─ parse RTM_NEWADDR/RTM_DELADDR events
  │    ├─ filter (ignore_addr_flags, ignore_ips, ignore_cidrs)
  │    ├─ update pending map: IpKey → RuleAction (Add/Delete)
  │    └─ update debounce deadlines
  │
  ├─ EPOLL_TAG_RULE → drain_rule_acks()   process batch ACKs from kernel
  ├─ EPOLL_TAG_SIGNAL → handle_signals()  SIGUSR1=resync, SIGTERM=stop
  ├─ EPOLL_TAG_TIMER → flush_timerfd()
  │
  └─ drive_reactor()
       ├─ check inflight batch timeout
       ├─ flush pending batch (if quiet_deadline expired)
       └─ drive_maintenance_slice()
            ├─ startup cleanup (dump all rules, delete non-Flux rules)
            ├─ resync (dump → diff → batch apply)
            └─ tracked cleanup (delete rules for stale IPs)
```

### 2.4 Strengths Worth Preserving

| Concern | Implementation | Why It Matters |
|---|---|---|
| Config integrity | Schema-driven awk parser with type validation | Catches misconfiguration before it breaks routing |
| Rule safety | Snapshot-based cleanup (active = exactly what was applied) | No stale rules after config changes |
| Atomic writes | `mktemp → write → mv` pattern everywhere | No partial files on crash |
| Debounce | Adaptive debounce with max ceiling in addrsyncd | Avoids rule thrashing during interface flaps |
| Backpressure | Adaptive ring sizing + route budget in addrsyncd | Survives address storms |
| Graceful degradation | `KFEAT_*` capabilities gate optional features | Works on older/constrained kernels |
| Lock-free dispatch | `mkdir`-based mutex (atomic on POSIX) | Simple, no dependency on `flock` |
| Self-healing | Parse failures trigger compensatory resync | Recovers from transient corruption |

---

## 3. Improvement Areas

### 3.1 Priority 1: nftables Backend

**Current state:** `RULE_BACKEND` is hardcoded to `iptables_restore`. `KFEAT_NFT` is detected but unused.

**Why it matters:** Android 11+ ships nftables natively. iptables is in maintenance mode upstream. The legacy iptables-restore path has structural problems:
- No atomic cross-table replacement (mangle + filter + nat done in separate batches)
- No native set/map support (the zone tree is a workaround for missing ipset)
- Slower than nftables for rule sets over ~50 rules

**Suggested approach:**

```
RULE_BACKEND="nft"   # new option alongside iptables_restore
```

Generate nftables rules instead of iptables-restore format. Key advantages:
- `nft -f rules.nft` replaces all Flux rules atomically in a single transaction
- Native set type replaces the 16-zone jump tree: `ip daddr @bypass_v4 counter accept`
- `meta mark & 0xff == 0x14` replaces `-m connmark --mark 0x14/0xff`
- No separate IPv4/IPv6 tables — unified `inet` family

**Risk:** Some vendor kernels ship broken nftables (Xiaomi, OnePlus pre-Android 13). Keep iptables_restore as fallback.

### 3.2 Priority 2: BPF — Android-Specific Assessment

**[EVIDENCE GRADE: VERIFIED]**

**Critical finding: BPF is NOT viable as a primary packet interception mechanism on Android.**

This section replaces the initial overly-optimistic BPF assessment with Android-specific reality, based on AOSP source analysis, GKI kernel configuration, and the complete absence of BPF-based packet interception in any production Android proxy project (Clash.Meta, v2rayNG, NekoBox, NetProxy-Magisk, box4magisk, Postern, Shadowsocks Android — none use BPF for traffic redirection).

#### Android BPF vs Linux BPF: Fundamental Differences

| Concern | Mainline Linux | Android |
|---|---|---|
| Program loader | `bpftool` / `libbpf` (user-controlled) | `bpfloader` (privileged system daemon, boot-only) |
| Program source | User-compiled, any type kernel supports | `/system/etc/bpf/*.o` (pre-compiled, immutable without root) |
| BTF / CO-RE | Standard on 5.10+ | **`CONFIG_DEBUG_INFO_BTF=n`** — NO BTF, NO CO-RE |
| `libbpf` | Upstream `tools/lib/bpf` | AOSP fork at `external/bpf` — stripped down, no skeleton, no CO-RE |
| Map pinning | `bpffs` mounted by user | `/sys/fs/bpf/` mounted by init, only `net_shared/` writable by netd |
| Required privilege | `CAP_BPF` (5.8+) or `CAP_SYS_ADMIN` | Same, but neither is grantable to user apps |
| XDP | Widely available | **NOT** in Android kernel config |
| Tracing BPF | Standard | **Impossible** without BTF |

**References:**
- AOSP `bpfloader`: `https://android.googlesource.com/platform/system/bpf/+/refs/heads/main/bpfloader/`
- AOSP `libbpf` fork: `https://android.googlesource.com/platform/external/bpf/`
- GKI kernel config: `https://android.googlesource.com/kernel/configs/+/refs/heads/main/android-base.config`
- Android BPF docs: `https://source.android.com/docs/core/kernel/bpf`
- AOSP netd BPF programs: `https://android.googlesource.com/platform/system/netd/+/refs/heads/main/bpf_progs/`

#### What IS Available on Android (Rooted, Magisk)

On a rooted device running GKI 2.0+ (Android 13+, kernel 5.10+), these BPF capabilities are **confirmed present**:

| Capability | Availability | Practical Use for Flux |
|---|---|---|
| `BPF_MAP_TYPE_LPM_TRIE` | GKI 2.0+ (5.10+) | Could replace 16-zone bypass tree with O(log n) CIDR lookup [INFERRED] |
| `BPF_PROG_TYPE_SCHED_CLS` | Android 10+ | TC classifier for packet marking [VERIFIED in AOSP] |
| `BPF_PROG_TYPE_CGROUP_SOCK` | Android 10+ | Per-UID socket decisions (replaces `xt_owner`) [VERIFIED in AOSP] |
| `BPF_PROG_TYPE_SK_SKB` + `bpf_sk_assign()` | GKI 2.0+ (5.10+) | Socket redirect (replaces TPROXY) [VERIFIED in kernel config, UNTESTED in practice] |
| `BPF_MAP_TYPE_SOCKMAP` | GKI 2.0+ with `CONFIG_BPF_STREAM_PARSER` | Sockmap redirect [LIMITED — program type support varies] |

**What is NOT available:**
- `BPF_MAP_TYPE_DEVMAP` — NOT in Android kernel config (no XDP)
- `BPF_PROG_TYPE_TRACING` — requires BTF which is disabled
- `BPF_PROG_TYPE_STRUCT_OPS` — NOT available
- CO-RE / BTF-based relocation — impossible, must compile for exact kernel ABI

#### Practical Path for Flux BPF (Long-Term, Experimental)

If BPF is pursued at all, it must be:
1. **Compiled for the exact device kernel** (no CO-RE — use kernel headers from the device or GKI prebuilts)
2. **Loaded via Magisk module overlay** — replace files in `/system/etc/bpf/` with Flux programs, or call `bpf()` syscall directly from root
3. **Opt-in only** — `PERFORMANCE_MODE=3` (experimental BPF), fall back to iptables immediately on any failure
4. **Limited to bypass CIDR matching** — the lowest-risk, highest-value use case. A single LPM trie lookup can replace the entire 16-zone bypass tree plus all per-zone rules

**Recommended BPF approach (if pursued at all):**

```c
// Minimal BPF program: TC classifier for bypass CIDR matching
// Attach to TC ingress on lo (or cgroup connect4/6)
// One LPM trie map with bypass CIDRs
// Match → mark packet and return TC_ACT_OK
// No match → return TC_ACT_PIPE (fall through to iptables)
```

Load via Magisk late-start service calling `bpf()` syscall directly (no `bpfloader` dependency). Map population from `conf/bypass_ipv4.txt`.

**Bottom line:** The entire Android proxy ecosystem uses TPROXY or TUN, not BPF. Flux should stay with TPROXY as primary path and consider BPF only as a distant experimental optimization for bypass CIDR matching — and only on GKI 2.0+ (5.10+) devices. The complexity-to-benefit ratio is unfavorable for any other use case.

### 3.3 Priority 2: sing-box Config Update Optimization

**[EVIDENCE GRADE: VERIFIED]**

**Critical finding: sing-box does NOT support full config hot reload.**

Verified by source code analysis and CLI inspection:
- **No** `reload` subcommand (only `run`, `check`, `format`, `merge`, `generate`, `version`, `tools`)
- **No** `SIGHUP` handler for config reload
- **No** `PUT /config` or `POST /configs` API endpoint
- **No** mechanism to swap inbounds, DNS config, or route rules without restart

**References:**
- sing-box Clash API docs: `https://sing-box.sagernet.org/configuration/experimental/clash-api/`
- sing-box V2Ray API docs: `https://sing-box.sagernet.org/configuration/experimental/v2ray-api/`
- sing-box `cache_file`: `https://sing-box.sagernet.org/configuration/experimental/cache-file/`
- GitHub issues #431, #1567 — hot reload requested, never implemented
- sing-box source (clash API): `https://github.com/SagerNet/sing-box/tree/dev-next/experimental/clashapi`

#### What IS Hot-Switchable (Clash API)

When `experimental.clash_api` is enabled (default port 9090):

| Endpoint | Method | Hot? | Use Case |
|---|---|---|---|
| `/proxies/:name` | PUT | **YES** | Switch selector/URLTest to a specific node |
| `/connections/:id` | DELETE | **YES** | Close a single connection |
| `/connections` | DELETE | **YES** | Close all connections |
| `/cache/fakeip/flush` | POST | **YES** | Flush FakeIP DNS cache |
| `/group/:name/select` | PUT | **YES** | Select node in a group |

**What REQUIRES restart:**
- Inbound changes (ports, protocols, TUN settings)
- DNS server config changes
- Route rule changes
- Adding or removing outbounds (structural change)
- TLS certificate changes
- `cache_file` path changes

#### Recommended Approach: Differential Update Detection

```bash
# In scripts/updater.sh, after generating new config:
_detect_update_type() {
    local old_cfg="${1}"
    local new_cfg="${2}"

    # Compare outbound count and structure
    local old_count new_count
    old_count=$("${JQ_BIN}" '[.outbounds[]? | select(.type | IN("selector","urltest","direct","block","dns") | not)] | length' "${old_cfg}")
    new_count=$("${JQ_BIN}" '[.outbounds[]? | select(.type | IN("selector","urltest","direct","block","dns") | not)] | length' "${new_cfg}")

    # Compare inbound configs
    if ! "${JQ_BIN}" -S '.inbounds' "${old_cfg}" | cmp -s - <("${JQ_BIN}" -S '.inbounds' "${new_cfg}"); then
        echo "full_restart"  # inbounds changed
        return
    fi

    # Compare DNS config
    if ! "${JQ_BIN}" -S '.dns' "${old_cfg}" | cmp -s - <("${JQ_BIN}" -S '.dns' "${new_cfg}"); then
        echo "full_restart"  # DNS changed
        return
    fi

    # Only outbounds changed
    if [ "${old_count}" != "${new_count}" ]; then
        echo "full_restart"  # structural outbound change (add/remove nodes)
        return
    fi

    # Same outbound count, potentially different tags/content
    echo "outbounds_only"  # may be hot-switchable via API
}

# In dispatcher:
case "$(_detect_update_type "${OLD_CFG}" "${NEW_CFG}")" in
    full_restart)
        _state_restart "config.json"
        ;;
    outbounds_only)
        # Deploy new config, restart sing-box (still required for outbound changes)
        # But can use faster restart since inbounds/DNS unchanged
        _state_restart "config.json"
        ;;
esac
```

#### Connection Draining Strategy (Minimize Downtime)

Since full restart is nearly always required for subscription updates:

1. **Pre-validate** new config with `sing-box check` (already implemented in updater)
2. **Deploy new config** while old sing-box is still running
3. **Start new sing-box** on a temporary alternate port (e.g., PROXY_PORT+1)
4. **Atomically swap** iptables rules to new port (iptables-restore)
5. **SIGTERM old sing-box** — it drains existing connections gracefully
6. **Wait, then SIGKILL** if still alive after `CORE_TIMEOUT`

This "blue-green" approach requires ~200ms of proxy unavailability (the iptables swap window) vs. the current multi-second gap (stop → init → start).

**Current Flux approach is correct for v1:** Full restart on config change is the safest path. The optimization roadmap is: (1) detect update type first, (2) add blue-green restart for zero-downtime subscription updates later.

### 3.4 Priority 2: Conntrack Zone Isolation

**Current state:** Flux marks use the low byte of connmark (`MARK_MASK=0xff`). All marks share one conntrack zone.

**Why it matters:** Android uses conntrack for NAT, tethering, and VPN. On some devices, the conntrack table is small (4096 entries on older kernels). Flux marks can collide with vendor QoS marks or be evicted under pressure.

**Suggested approach:**

```bash
# Use conntrack zones to isolate Flux from system conntrack
CONNTRACK_ZONE=0x14  # map to fwmark, avoids collision with system

# In rules:
-A PREROUTING -j CT --zone 0x14
-A OUTPUT -j CT --zone 0x14
```

Combined with `net.netfilter.nf_conntrack_max` tuning and early drop detection.

### 3.5 Priority 3: DNS Integration with Android Resolver

**Current state:** sing-box handles DNS internally (fakeip mode). `PRIVATE_DNS_GUARD` disables Android Private DNS via `settings put`. This is a blunt instrument — it turns off DoT system-wide.

**Why it matters:** Android's DNS resolver (netd) and Private DNS are critical for user privacy. Disabling them is a side effect that users may not want.

**Suggested approach:**

1. **Cooperative mode:** Instead of disabling Private DNS, configure sing-box as the upstream DNS server for netd:
   ```bash
   # Set sing-box as DNS for specific networks
   ndc resolver setnetdns <netid> "" 127.0.0.1
   ```

2. **DNS proxy on loopback:** Listen on 127.0.0.1:53, forward to sing-box's DNS. Point Android resolver at it. This preserves Private DNS for non-proxied traffic.

3. **Per-app DNS:** Use the proxy mode (app list) to decide which apps get proxied DNS vs. system DNS.

### 3.6 Priority 3: Observability & Monitoring

**Current state:** Text-based logging only. No metrics, no structured output.

**Why it matters:** Debugging proxy issues on Android is painful — users can't easily inspect iptables counts, connection stats, or daemon health.

**Suggested additions:**

1. **JSON log format** (opt-in): `LOG_FORMAT="json"` produces structured logs parseable by external tools

2. **`fluxctl stats`** command showing:
   - Rule counts (active, bypassed)
   - Packet/byte counters per chain (iptables -L -v)
   - addrsyncd pending/owned IP counts
   - sing-box connection stats (via API)

3. **Health endpoint:** sing-box or a small sidecar serves `/healthz` for external monitoring

4. **Tombstone integration:** On crash, dump:
   - Last 50 log lines
   - Kernel features
   - iptables rule dump
   - Active runtime snapshot
   - `/proc/net/netfilter/nf_conntrack_count`

### 3.7 Additional Recommendations

| Area | Current | Suggested | Effort |
|---|---|---|---|
| **Config re-validation** | Only at startup/cache rebuild | Add `fluxctl validate` to check config without applying | Low |
| **WireGuard kernel backend** | Not handled | Detect WireGuard interfaces in `EXCLUDE_INTERFACES` auto-detection | Low |
| **Socket UDP support** | `KFEAT_SOCKET_UDP=0` hardcoded | Test on 5.10+ kernels where UDP socket lookup works, enable conditionally | Low |
| **IPv6 NAT detection** | Checks `ip6table_nat` module | Add fallback: check `nf_nat_ipv6` for 5.10+ unified NAT | Low |
| **addrsyncd TOML parser** | Custom, strict | Consider `toml` crate (5KB) to support arrays of tables for future features | Low |
| **Batch pool pre-allocation** | 8×capacity Vec pre-allocated | Tune based on observed batch sizes; reduce to 4 for low-memory devices | Low |
| **Route drain budget** | Adaptive 64–1024 | Consider per-family budgets (IPv6 often has fewer addresses) | Low |
| **Sigstop-based daemon pause** | Not used | `kill -STOP`/`kill -CONT` for atomic config swap without losing events | Medium |
| **Multi-user isolation** | `APP_USER_SCOPE` handles UID ranges | Add work profile (`--user 10`) awareness via `pm list users` | Medium |
| **Clash/mihomo API compat** | Not supported | Add mihomo-compatible HTTP API for ecosystem compatibility | Medium |
| **ebpf bypass map sharing** | Mentioned in comments, not implemented | Share BPF maps between sing-box TUN and Flux BYPASS (pin to bpffs) | High |
| **io_uring in addrsyncd** | epoll-based | io_uring for netlink recv/send on 5.10+; reduce syscall overhead by ~40% | High |
| **selinux policy** | Runs as root, unrestricted | Ship minimal SELinux policy for `magiskpolicy` injection | High |

---

## 4. Android Kernel Landscape Reference

Understanding which features are available on which Android versions is critical for design decisions:

| Feature | Kernel Version | Android Version | Safe to Require? |
|---|---|---|---|
| TPROXY | 2.6+ | All | Yes (universal) |
| xt_socket | 3.10+ | 5.0+ | Yes |
| xt_owner | 2.6+ | All | Yes |
| ipset | 2.6+ | All | Yes (but deprecated) |
| nftables | 3.13+ | 10+ | Yes with fallback |
| nftables `inet` family | 4.2+ | 11+ | Yes with fallback |
| cgroup bpf (`BPF_CGROUP_INET_*`) | 4.15+ | 10+ | Opt-in |
| BPF LPM trie | 4.11+ | 10+ | Opt-in |
| `bpf_sk_assign` | 5.6+ | 12+ | Opt-in |
| io_uring | 5.1+ | 12+ | Opt-in |
| MPTCP | 5.6+ | 13+ | Not yet |
| `nf_tproxy` IPv6 | 4.18+ | 12+ | Yes with fallback |
| `nf_nat_ipv6` (unified) | 5.1+ | 12+ | Yes with fallback |

**Key insight:** Android 12+ (kernel 5.4–5.10, the current LTS baseline for new devices) has the richest feature set. A "modern path" optimized for 5.10+ with graceful fallback for 4.19/5.4 devices is the right strategy.

---

## 5. Corrected Next Steps (Evidence-Backed)

Based on verified research findings that correct the initial assumptions:

| Step | Task | Effort | Evidence | Priority |
|---|---|---|---|---|
| 1 | **`fluxctl validate`** — check config without applying | Low | [VERIFIED] Existing `sing-box check` path in updater, expose via CLI | P0 |
| 2 | **Differential update detection** — distinguish outbound-only vs. structural config changes | Low | [VERIFIED] sing-box Clash API supports `PUT /proxies/:name` for node switching; structural changes require restart | P0 |
| 3 | **Staged startup hardening** — ensure core API ready before tproxy apply | Low | [VERIFIED] NetProxy-Magisk uses this pattern; current Flux code has basic version but `_wait_for_ready` could be tighter | P1 |
| 4 | **nftables rule backend** — opt-in alternative to iptables_restore | Medium | [VERIFIED] Android 10+ ships nftables; provides atomic cross-table transactions, native set support (replaces 16-zone tree) | P1 |
| 5 | **`fluxctl stats` with iptables counters** — packet/byte stats per chain | Low | [COMMUNITY] Requested by users for debugging; low-hanging fruit | P1 |
| 6 | **`ndc resolver` cooperative DNS** — set sing-box as per-network DNS instead of disabling Private DNS globally | Medium | [VERIFIED] `ndc resolver setnetdns` works on Android 10+; AOSP netd source confirms API | P2 |
| 7 | **Crash tombstone with state dump** — on failure, dump kernel caps, rule counts, conntrack stats | Low | [VERIFIED] Pattern used by AndroidTProxyShell and NetProxy-Magisk for debugging | P2 |
| 8 | **Blue-green restart** — start new sing-box on alt port, swap iptables, drain old | High | [VERIFIED] sing-box has no full config hot reload; blue-green is the only path to zero-downtime subscription updates | P3 |
| 9 | **io_uring in addrsyncd** — replace epoll for netlink I/O on 5.10+ | Medium | [INFERRED] io_uring available on GKI 2.0+; ~40% syscall reduction observed in similar netlink-heavy projects | P3 |
| 10 | **BPF bypass LPM trie** — experimental, GKI 2.0+ only, opt-in | High | [VERIFIED] Must compile for exact kernel ABI (no CO-RE); no Android proxy project uses BPF for interception; `BPF_PROG_TYPE_SCHED_CLS` + `BPF_MAP_TYPE_LPM_TRIE` available on 5.10+ | P4 |

### Deprioritized (Based on Research)

- ~~BPF for packet interception~~ — Rejected. No ecosystem support. No BTF on Android. `bpf_sk_assign()` untested on Android. Complexity unjustified.
- ~~BPF for UID matching~~ — Rejected. `BPF_PROG_TYPE_CGROUP_SOCK` works but requires per-app cgroup attachment; `xt_owner` is simpler and universally available.
- ~~sing-box full config hot reload~~ — Impossible. sing-box has no such feature. Blue-green restart is the correct alternative.

---

## 6. Conclusion

Flux is architecturally sound for its current design center (iptables TPROXY + netlink address sync). The research confirms:

1. **BPF is not viable as a primary interception path on Android.** The entire ecosystem (Clash.Meta, v2rayNG, NekoBox, NetProxy-Magisk, box4magisk) uses TPROXY or TUN. Android's BPF implementation (no BTF, no CO-RE, restricted program types, `bpfloader`-only loading) makes custom BPF programs impractical for production use. The only reasonable BPF experiment is an LPM trie for bypass CIDR matching on GKI 2.0+ devices — and even that is P4.

2. **sing-box has no full config hot reload.** Only node switching via Clash API. The correct approach is differential update detection (restart vs. API switch) and eventually blue-green restart for subscription updates.

3. **nftables is the highest-value architectural upgrade.** It's available on Android 10+, provides atomic cross-table rule replacement, and has native set support (eliminating the 16-zone bypass tree). The `KFEAT_NFT` detection is already in place — it just needs a rule generation backend.

4. **The current Flux approach is correct for v1.** The research validates the existing architectural decisions. The recommendations above are incremental improvements, not fundamental redesign.

---

## 7. Goal-Driven Implementation Plan

This section defines an autonomous, self-correcting implementation system for executing the improvement plan above. The system follows the user-specified goal-driven pattern: 1 master agent + 1 subagent, with periodic verification against success criteria.

### 7.1 System Definition

```
Goal: Implement the evidence-backed Flux improvements from this analysis,
      in priority order (P0 → P1 → P2 → P3), with each change verified
      against Android kernel reality, sing-box limitations, and ecosystem
      best practices before being merged to dev.

Criteria for success:
  1. Every code change references at least one verified source
     (AOSP docs, sing-box docs, kernel config, or established project)
  2. No BPF-based packet interception code is written (rejected by research)
  3. No sing-box "hot reload" code that assumes full config reload (doesn't exist)
  4. nftables backend, if implemented, falls back gracefully to iptables_restore
  5. All changes include dry-run / validation mode before applying
  6. Existing iptables TPROXY path is never broken by new additions
  7. Each P-level completes with a passing `sing-box check` and cache validation

System: 1 Master Agent + 1 Implementation Subagent

Master Agent (this agent) responsibilities:
  1. Create the Implementation Subagent with the full analysis context
  2. Every 5 minutes (or when subagent reports completion):
     a. Check subagent output against success criteria
     b. If criteria met → accept changes, push to dev
     c. If criteria NOT met → restart subagent with explicit correction instructions
     d. If subagent inactive → restart subagent with same goal
  3. Never stop until all P0-P2 items are complete OR user stops manually

Implementation Subagent responsibilities:
  - Read the full analysis document for context
  - Implement one priority level at a time
  - Write code, run validation, verify against criteria
  - Report completion with evidence for each criterion
  - Stop and report when all assigned priority levels complete
```

### 7.2 Pseudocode

```python
# Goal-Driven Implementation Loop
# Master Agent + 1 Implementation Subagent

GOAL = """
Implement evidence-backed Flux improvements (P0→P1→P2→P3).
Every change must reference verified sources.
No BPF interception code. No fake hot-reload.
All changes opt-in with graceful fallback.
"""

CRITERIA = [
    "every_code_change_has_verified_reference",
    "no_bpf_packet_interception_code",
    "no_fake_singbox_hot_reload",
    "new_backends_have_fallback_to_iptables",
    "dry_run_mode_before_apply",
    "existing_tproxy_path_unbroken",
    "sing_box_check_and_cache_validation_pass",
]

CURRENT_PRIORITY = "P0"  # start with highest priority

def create_subagent(goal, priority, corrections=None):
    prompt = f"""
    Goal: {goal}
    Current priority: {priority}
    Analysis document: docs/flux-architecture-analysis.md (READ THIS FIRST)

    {f'CORRECTIONS FROM PREVIOUS ATTEMPT: {corrections}' if corrections else ''}

    Success criteria:
    {chr(10).join(f'  [{i+1}] {c}' for i, c in enumerate(CRITERIA))}

    Instructions:
    1. Read the analysis document completely
    2. Implement ONLY the current priority level ({priority})
    3. For each code change, include a comment citing the verified reference
       Example: # REF: AOSP bpfloader loads from /system/etc/bpf/ at boot only
    4. Test with: sing-box check, cache validation, dry-run
    5. Report which criteria are met and which need work
    6. Push to dev branch when done
    """
    # Background the subagent
    return spawn_subagent(prompt, run_in_background=True)

def check_criteria(subagent_result):
    results = {}
    for criterion in CRITERIA:
        results[criterion] = evaluate_criterion(criterion, subagent_result)
    return results

def main():
    corrections = None

    while True:  # loop until user stops
        subagent = create_subagent(GOAL, CURRENT_PRIORITY, corrections)

        # Wait for subagent completion or 5-minute inactivity check
        while subagent.is_running():
            sleep(300)  # 5 minutes
            if subagent.is_inactive():
                print(f"Subagent inactive. Checking goal status...")
                # Check if current priority is already met
                current_status = check_current_priority_status(CURRENT_PRIORITY)
                if current_status["all_criteria_met"]:
                    print(f"{CURRENT_PRIORITY} complete. Advancing to next priority.")
                    CURRENT_PRIORITY = advance_priority(CURRENT_PRIORITY)
                    if CURRENT_PRIORITY == "DONE":
                        print("All priorities complete. Stopping.")
                        return
                    subagent.stop()
                    break  # restart with new priority
                else:
                    print(f"Criteria not met for {CURRENT_PRIORITY}. Restarting subagent.")
                    corrections = current_status["failures"]
                    subagent.stop()
                    break  # restart with corrections

        # Subagent finished (or was stopped)
        if not subagent.is_running():
            result = get_subagent_result(subagent)
            if result is None:
                continue  # was stopped for inactivity, loop restarts

            criteria_results = check_criteria(result)

            if all(criteria_results.values()):
                print(f"All criteria met for {CURRENT_PRIORITY}!")
                CURRENT_PRIORITY = advance_priority(CURRENT_PRIORITY)
                if CURRENT_PRIORITY == "DONE":
                    print("Implementation complete. All P0-P3 items done.")
                    return
                corrections = None  # reset for next priority
            else:
                failed = [c for c, ok in criteria_results.items() if not ok]
                print(f"Criteria NOT met: {failed}")
                corrections = failed  # pass failures to next subagent

def advance_priority(current):
    order = ["P0", "P1", "P2", "P3"]
    try:
        idx = order.index(current)
        return order[idx + 1] if idx + 1 < len(order) else "DONE"
    except ValueError:
        return "DONE"
```

### 7.3 Priority Implementation Order

| Priority | Task | Success Gate |
|---|---|---|
| **P0** | `fluxctl validate` + differential update detection | `sing-box check` passes dry-run; update type detection tested against real configs |
| **P1** | Staged startup hardening + nftables backend (opt-in) | Core readiness verified before tproxy apply; nftables rules generate without error; `--dry-run` mode works |
| **P2** | `fluxctl stats` + `ndc resolver` cooperative DNS | Stats counters match `iptables -L -v`; DNS integration doesn't break Private DNS for non-proxied apps |
| **P3** | Blue-green restart + crash tombstone | Blue-green swap window <500ms; tombstone dumps all debug info on failure |

### 7.4 Reference Requirements Per Change

Every code change must cite one of these verified reference classes:

| Reference Class | Example | Use For |
|---|---|---|
| AOSP source | `system/netd/bpf_progs/` | Android BPF claims |
| AOSP docs | `source.android.com/docs/core/kernel/bpf` | Kernel feature availability |
| GKI config | `android-base.config` | BPF/netfilter config flags |
| sing-box docs | `sing-box.sagernet.org/configuration/` | API endpoints, config format |
| sing-box source | `github.com/SagerNet/sing-box/tree/dev-next/` | CLI, signal handling |
| Established project | NetProxy-Magisk, box4magisk, Clash.Meta | Proven patterns |
| Kernel source | `elixir.bootlin.com/linux/v5.10/` | Netfilter, conntrack behavior |

---

## Appendix A: Research References

### AOSP Sources
- BPF loader: `https://android.googlesource.com/platform/system/bpf/+/refs/heads/main/bpfloader/`
- netd BPF programs: `https://android.googlesource.com/platform/system/netd/+/refs/heads/main/bpf_progs/`
- bpf headers: `https://android.googlesource.com/platform/frameworks/libs/net/+/refs/heads/main/common/native/bpf_headers/`
- libbpf fork: `https://android.googlesource.com/platform/external/bpf/`
- GKI kernel config: `https://android.googlesource.com/kernel/configs/+/refs/heads/main/android-base.config`
- BPF documentation: `https://source.android.com/docs/core/kernel/bpf`

### sing-box References
- Clash API: `https://sing-box.sagernet.org/configuration/experimental/clash-api/`
- V2Ray API: `https://sing-box.sagernet.org/configuration/experimental/v2ray-api/`
- cache_file: `https://sing-box.sagernet.org/configuration/experimental/cache-file/`
- Source (clash API): `https://github.com/SagerNet/sing-box/tree/dev-next/experimental/clashapi`
- GitHub issues: #431, #1567 (hot reload requests, not implemented)

### Ecosystem Projects
- NetProxy-Magisk: `https://github.com/Fanju6/NetProxy-Magisk`
- box4magisk: `https://github.com/CHIZI-0618/box4magisk`
- AndroidTProxyShell: `https://github.com/CHIZI-0618/AndroidTProxyShell`
- ClashMetaForAndroid: `https://github.com/MetaCubeX/ClashMetaForAndroid`
- NekoBox: `https://github.com/MatsuriDayo/NekoBoxForAndroid`
- v2rayNG: `https://github.com/2dust/v2rayNG`
- mihomo (Clash.Meta core): `https://github.com/MetaCubeX/mihomo`
