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

### 3.2 Priority 1: BPF-based Fast Path

**Current state:** The DIVERT chain uses `xt_socket --transparent` for established connection handoff. This is a netfilter match that still incurs skb linearization cost.

**Why it matters:** Android kernels 5.4+ ship with BPF JIT enabled and the BPF traffic controller (`bpfloader`). sing-box itself has BPF support for TUN mode. For TPROXY mode, a small BPF program attached to the ingress/egress path could:

1. **Replace the 16-zone bypass tree** with a BPF LPM (Longest Prefix Match) trie
   - Current: 16 zone rules + N subnet rules, evaluated linearly per zone
   - BPF: Single `bpf_fib_lookup` or `BPF_MAP_TYPE_LPM_TRIE` lookup, O(log N)

2. **Replace connmark fast-path rules** with BPF sockmap/skmsg
   - Current: 6 connmark rules checked per packet, plus conntrack dependency
   - BPF: Direct socket redirect via `bpf_sk_assign()`, bypasses netfilter entirely

3. **Replace UID matching** with cgroup/BPF integration
   - Current: `-m owner --uid-owner` requires linear sk lookup
   - BPF: `bpf_get_current_uid_gid()` or cgroup socket cookies

**Suggested architecture:**

```
BPF program (attached to TC ingress on lo or cgroup connect4/6):
  1. If destination in BYPASS_LPM → PF_PASS (skip proxy)
  2. If destination in PROXY_LPM → bpf_sk_assign(sk) redirect to sing-box socket
  3. Else → fall through to existing iptables path (compatibility)

Flux provides:
  - bpftool/ fluxbpfd: load programs, populate BPF maps from conf/bypass_ipv4.txt
  - Fallback: if BPF load fails (pre-5.4 kernel), use existing iptables path
```

**Risk:** BPF program verification is kernel-version dependent. Need to test against 5.4, 5.10, 5.15, 6.1 LTS kernels. Keep as opt-in (`PERFORMANCE_MODE=2` or `BPF_ENABLE=1`).

### 3.3 Priority 2: sing-box Hot Reload

**Current state:** Any config change triggers `stop all → init → start all`. sing-box is restarted, which resets connections.

**Why it matters:** sing-box supports gRPC/HTTP API for hot config reload. When only outbounds change (subscription update), sing-box can reload without dropping connections.

**Suggested approach:**

```bash
# In dispatcher:
case "${key}" in
  config.json:y)
    # Check if only outbounds changed (not inbounds/dns)
    if _outbounds_only_changed; then
      # Hot reload via sing-box API
      curl -X PUT http://127.0.0.1:9090/config -d @config.json
    else
      _state_restart "${event_name}"
    fi
    ;;
esac
```

For the updater, deploy the new config and signal sing-box via API instead of triggering a full restart. This preserves long-lived connections (downloads, video calls).

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

## 5. Concrete Next Steps (Suggested Order)

1. **`fluxctl validate`** command (1–2 days) — immediate user value, low risk
2. **nftables rule backend** (3–5 days) — structural improvement, opt-in
3. **sing-box hot reload for outbound changes** (2–3 days) — eliminates restart on subscription update
4. **`fluxctl stats` with iptables counters** (1–2 days) — better debugging
5. **BPF bypass map prototype** (1–2 weeks) — largest performance gain, highest complexity
6. **Crash tombstone with state dump** (1–2 days) — practical debugging
7. **io_uring in addrsyncd** (3–5 days) — performance for event-loop-heavy workload

---

## 6. Conclusion

Flux is architecturally sound for its current design center (iptables TPROXY + netlink address sync). The main strategic question is whether to invest in the **nftables/BPF transition now** or to continue optimizing the iptables path and defer the transition until iptables is actually removed from Android kernels (which is still years away).

The pragmatic answer: **add nftables as an opt-in backend first** (it's the most incremental step, and the kernel detection is already in place), then incrementally introduce BPF for the hot path (bypass matching, socket redirect) while keeping iptables as the reliable fallback.
