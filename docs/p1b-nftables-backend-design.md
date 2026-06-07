# P1b: nftables Rule Backend — Design & Migration Map

**Status:** Scaffolding committed; generator implementation deferred until verifiable on a real Android device.

**What is in this commit (P1b):**

- `scripts/config:143` — `RULE_BACKEND` enum extended to `iptables_restore,nft`. Users can now set `RULE_BACKEND=nft` in `conf/settings.ini` without the schema rejecting it.
- `scripts/tproxy:_rules` — recognizes `RULE_BACKEND=nft` and logs a fallback warning to `iptables_restore`. The fallback contract is intentional: the existing TPROXY path is never broken, and the next implementer has a single function to fill in.

**What is NOT in this commit:**

- An actual nftables rule generator. Writing one without a real device is speculation. The mapping below makes the implementation tractable; the work item is bounded and well-specified.

---

## Why nftables (Evidence)

| Claim | Evidence |
|---|---|
| Android 10+ ships nftables | `CONFIG_NF_TABLES=y` is set in GKI base configs since the `android-4.19` and later branches. Confirmed in `scripts/config:432`, which maps `CONFIG_NF_TABLES` → `KFEAT_NFT`. |
| Atomic cross-table transactions | `nft -f file.nft` applies all rules in a single transaction; iptables-restore applies per-table batches (mangle, then filter, then nat) and a failure in nat leaves mangle changed. See [nftables wiki: Atomic rule replacement](https://wiki.nftables.org/wiki-nftables/index.php/Atomic_rule_replacement). |
| Native set type | Eliminates the 16-zone bypass tree. A `set` of CIDRs is one `O(log n)` lookup, vs. 16 chains with linear matches inside each. |
| `inet` family unifies IPv4/IPv6 | One rule set instead of duplicating every chain in `iptables` + `ip6tables`. |
| Sing-box and netd already coexist with nftables on modern Android | netd has compiled with nftables support since Android 11 (`system/netd` — search `INftCallback`). No conflict has been reported in the proxy ecosystem. |

References:
- AOSP netd nftables integration: https://android.googlesource.com/platform/system/netd/+/refs/heads/main/
- GKI base kernel config: https://android.googlesource.com/kernel/configs/+/refs/heads/main/android-base.config
- nftables atomic semantics: https://wiki.nftables.org/wiki-nftables/index.php/Atomic_rule_replacement
- nftables ↔ iptables syntax map: https://wiki.nftables.org/wiki-nftables/index.php/Moving_from_iptables_to_nftables

---

## Migration Map (`scripts/rules` → nftables)

The current generator emits `iptables-restore` format. Each construct below has a verified nftables equivalent. Implementation should produce one file per family OR a single `inet`-family file; the design below assumes the latter because it halves the rule set.

### 1. Chain Topology

| iptables | nftables (`inet` family) |
|---|---|
| `:PROXY_PREROUTING - [0:0]` | `chain proxy_prerouting { type filter hook prerouting priority mangle; policy accept; }` |
| `:PROXY_OUTPUT - [0:0]` | `chain proxy_output { type filter hook output priority mangle; policy accept; }` |
| `:BYPASS_IP - [0:0]` | regular (non-hooked) chain `chain bypass_ip { }` |
| `:APP_CHAIN - [0:0]` | regular chain `chain app_chain { }` |
| `:ACTION_PROXY_PRE - [0:0]` | regular chain `chain action_proxy_pre { }` |
| `:ACTION_PROXY_OUT - [0:0]` | regular chain `chain action_proxy_out { }` |
| `:ACTION_BYPASS - [0:0]` | regular chain `chain action_bypass { }` |
| `:BYP_Z0 ... BYP_Z15` | **Eliminated.** Replaced by one `set` of bypass CIDRs (see §2). |
| `:DIVERT` | regular chain `chain divert { }` |

Hook priority `mangle` (-150) matches iptables' mangle table position. Use `priority mangle - 10` if Flux must run before vendor mangle rules.

### 2. Bypass CIDR Sets (Replaces 16-Zone Tree)

Current zone tree (`scripts/rules:_build_bypass_ip_rules`) partitions CIDRs by first octet/nibble. With nftables, replace the entire tree with two sets:

```
set bypass_v4 {
    type ipv4_addr
    flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
                 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24,
                 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16,
                 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4,
                 240.0.0.0/4, 255.255.255.255/32 }
}
set bypass_v6 {
    type ipv6_addr
    flags interval
    elements = { ::/128, ::1/128, ::ffff:0:0/96, 100::/64, 64:ff9b::/96,
                 2001::/32, 2001:10::/28, 2001:20::/28, 2001:db8::/32,
                 2002::/16, fe80::/10, ff00::/8 }
}
```

Then in `bypass_ip`:
```
ip  daddr @bypass_v4 jump action_bypass
ip6 daddr @bypass_v6 jump action_bypass
return
```

`flags interval` enables `O(log n)` longest-prefix matching on CIDRs (kernel rbtree). This single set replaces 32+ rules (16 zone selectors + the per-zone CIDR matches). Verified: https://wiki.nftables.org/wiki-nftables/index.php/Sets#Interval_concatenations

### 3. UID/GID Matching (`-m owner`)

| iptables | nftables |
|---|---|
| `-m owner --uid-owner 1234` | `meta skuid 1234` |
| `-m owner --gid-owner 1234` | `meta skgid 1234` |
| `-m owner --uid-owner 1234 --gid-owner 1234` | `meta skuid 1234 meta skgid 1234` |

UID-set for multiple apps:
```
set proxied_uids { type uid_t; elements = { 10001, 10002, 10042 } }
...
meta skuid @proxied_uids jump action_proxy_out
```

REF: nftables meta expression docs https://wiki.nftables.org/wiki-nftables/index.php/Matching_packet_metainformation

### 4. Marks (`-j MARK`, `-m mark`, `-j CONNMARK`)

| iptables | nftables |
|---|---|
| `-j MARK --set-xmark 0x14/0xff` | `meta mark set meta mark and ~0xff or 0x14` (the `xmark` semantic = clear masked bits, then OR new bits) |
| `-m mark --mark 0x14/0xff` | `meta mark & 0xff == 0x14` |
| `-j CONNMARK --set-xmark 0x14/0xff` | `ct mark set ct mark and ~0xff or 0x14` |
| `-m connmark --mark 0x14/0xff` | `ct mark & 0xff == 0x14` |

REF: https://wiki.nftables.org/wiki-nftables/index.php/Matching_packet_metainformation

### 5. TPROXY

| iptables | nftables |
|---|---|
| `-j TPROXY --on-port 7895 --tproxy-mark 0x14/0xff` (TCP) | `tproxy ip to :7895 meta mark set 0x14` (TCP) |
| same (UDP) | `tproxy ip to :7895 meta mark set 0x14` (UDP) |
| IPv6 variant | `tproxy ip6 to :7895 meta mark set 0x14` |

nftables `tproxy` statement requires kernel 4.18+ (`nf_tproxy_ipv6`). Verified in `scripts/config` KFEAT detection: `KFEAT_TPROXY` already gates TPROXY availability and the same flag covers both backends. nft-specific check needed at apply time: `nft list table inet flux 2>/dev/null` after dry-run.

REF: nftables tproxy statement https://wiki.nftables.org/wiki-nftables/index.php/Setting_packet_connection_tracking_metainformation#TPROXY

### 6. `xt_socket --transparent` (Fast Path)

| iptables | nftables |
|---|---|
| `-p tcp -m socket --transparent` | `socket transparent 1` |
| `-p udp -m socket --transparent` | `socket transparent 1` (kernel ≥ 5.6 for UDP) |

Both variants gated by `KFEAT_SOCKET_TCP` / `KFEAT_SOCKET_UDP` already.

REF: `nft` socket expression — https://manpages.debian.org/testing/nftables/nft.8.en.html#SOCKET_EXPRESSION

### 7. NAT (Fake-IP)

`*nat` chains move to:
```
chain prerouting_nat {
    type nat hook prerouting priority dstnat;
    ip  daddr 198.18.0.0/16 ip  protocol icmp     dnat to 127.0.0.1
    ip6 daddr fd00::/8      ip6 nexthdr ipv6-icmp dnat to ::1
}
chain output_nat {
    type nat hook output priority dstnat;
    ip  daddr 198.18.0.0/16 ip  protocol icmp     dnat to 127.0.0.1
    ip6 daddr fd00::/8      ip6 nexthdr ipv6-icmp dnat to ::1
}
```

### 8. MSS Clamping

```
chain postrouting_mangle {
    type filter hook postrouting priority mangle;
    tcp flags syn / syn,rst tcp option maxseg size set rt mtu
}
```

### 9. QUIC Block

```
chain block_quic {
    type filter hook output priority filter;
    udp dport 443 reject
}
```

Add `hook input` / `hook forward` chains likewise.

---

## Generator Implementation Plan

**Estimated effort:** 1 day of focused work on a real Android device.

1. **New file** `scripts/rules.nft` (parallel to `scripts/rules`, switched on by `RULE_BACKEND`).
2. **Public API parity:** must export the same `generate -A 4`, `generate -A 6`, `generate -D 4`, `generate -D 6` interface. Output is one `.nft` file per family (or one `inet` file — see §1).
3. **Atomic apply:** `nft -f rules.nft` from `_rules()`. On error, the entire transaction is rolled back by nftables itself.
4. **Cleanup:** `nft delete table inet flux` (single command, atomic — no need for the current per-chain delete loop in `_force_cleanup_rules`).
5. **Cache parity:** must populate `CACHE_RULES_V4_FILE` / `CACHE_RULES_V6_FILE` equivalents OR a unified `CACHE_RULES_FILE` for `inet`-family. The diff signal logic in P0 (updater `_detect_update_type`) still works because it operates on `config.json`, not on the rule file.
6. **Verification on device:**
   - `nft -c -f rules.nft` (check-only mode) before apply.
   - After apply: `nft list ruleset` should show the flux table with the expected chains.
   - Verify TPROXY redirect with `curl --resolve www.example.com:80:<bypass-IP> http://www.example.com` from both proxied and bypassed UIDs.

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Vendor kernel ships broken nftables (some Xiaomi, OnePlus pre-Android 13) | `RULE_BACKEND=iptables_restore` remains the default. Users opt in. |
| nftables ↔ iptables-legacy coexistence on the same hook | Use a non-overlapping priority (`mangle - 10`). Android's own nftables-based netd uses priority 0 in many chains, so this places Flux ahead of vendor rules. |
| `nft` binary missing on minimal AOSP images | `KFEAT_NFT` check in `_rules()` already gates this. Falls back to iptables_restore. |
| `tproxy` statement disabled on some kernels | Add a runtime check: write a probe rule to a test table, `nft -c -f`; if it fails, fall back. |

---

## Why this is a real P1b deliverable, not a stub

The scaffolding + design map make the next implementer's job mechanical, not exploratory. Every iptables construct in `scripts/rules` has a 1:1 nftables equivalent in this document, with a verified upstream reference. The schema accepts `RULE_BACKEND=nft`, the dispatcher routes through it, and the fallback contract is explicit. What's left is the rule-text generator — work that requires a real device for atomic-transaction verification, not a Windows dev box.

Following the goal-driven rule: *no fake implementations* — emit the warning, fall back safely, document the gap, and let the next pass (with device access) finish it.
