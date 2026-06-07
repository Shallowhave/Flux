# P3 Verification: Blue-Green Restart Strategy for sing-box on Android

**Status:** Verification only. No implementation in this commit.

**Question this report answers:** Is the blue-green restart strategy from `flux-architecture-analysis.md` §3.3 actually viable on Android, given how sing-box and iptables behave?

**Recommendation up front:** Conditional GO, with two material caveats that reshape the design:

1. **iptables-restore is not cross-table atomic** — only per-table. A blue-green swap that touches mangle + nat + filter has three lock windows, not one. The current design must add a sequencing rule, or wait for the nftables backend (P1b) and do the swap there.
2. **sing-box has no built-in port-conflict handling**, so the operator (Flux scripts) must allocate the alternate port and rewrite the alternate config's listen address explicitly. This is doable, but it is real work — not "just start a second sing-box."

If both caveats are accepted, the strategy works. Otherwise, the simpler `stop → start` used by every established Android proxy project (AndroidTProxyShell, box4magisk, NetProxy-Magisk) is the safer default.

---

## Assumption 1: sing-box can be started on an alternate port concurrently with the live instance

**Verdict:** TRUE, but **with operator responsibility**.

### Evidence

- `box.go:54-69` (sing-box main branch) defines the `Box` struct. There is no port-conflict detection inside Box: it binds whatever its config says. Two `Box` instances with non-overlapping listen addresses can coexist.
- `box.go:574-630` shows `Box.Close()` is a sequential teardown (`service → inbound → endpoint → outbound → router → DNS → network`). The done channel is closed exactly once; a second `Close()` returns `os.ErrClosed`. This means concurrent close attempts on the *same* Box are safe-idempotent, but it has no bearing on a *second* Box on a different port.
- There is no shared global state on disk between Box instances except `cache_file` (default `cache.db`). Two instances sharing the same `cache_file` path would race on the BBolt-format file. **The blue-green design must give the alternate-port instance its own `cache_file` path.**

References:
- sing-box `box.go`: https://github.com/SagerNet/sing-box/blob/testing/box.go
- sing-box `cache_file` config: https://sing-box.sagernet.org/configuration/experimental/cache-file/

### What this means for the design

The Flux dispatcher must:
1. Generate a parallel sing-box config — same outbounds and DNS, but **different inbound listen ports** (e.g., `PROXY_PORT + 1`) and **different `cache_file.path`** (e.g., `${RUN_DIR}/cache_alt.db`).
2. Start the alternate sing-box from that config.
3. Wait for the alternate to reach the readiness probe (reuse `_verify_core_actually_ready` from P1a — already shipped).
4. Swap iptables / nftables rules to point at the alternate port.
5. SIGTERM the old sing-box.

Caveat: the FakeIP allocations in the old instance's `cache_file` are not visible to the alternate. In-flight FakeIP-resolved domains may show as cold cache to the new instance until they re-resolve. This is acceptable — a fresh resolution is faster than a new connection establishment anyway — but worth a one-line warning in fluxctl output.

---

## Assumption 2: iptables -w atomic swap

**Verdict:** PARTIALLY TRUE. **This is the load-bearing concern of the report.**

### Evidence

From the upstream commit adding `-w` support to `iptables-restore` (aosp-mirror/platform_external_iptables@1e95b6c):

> The lock is not acquired on startup. Instead, it is acquired when a new table handle is created (on encountering '*') and released when the table is committed (COMMIT).

This means atomicity scope is **per-table**, not per-restore invocation. A `restore` file like:

```
*mangle
... rules ...
COMMIT
*nat
... rules ...
COMMIT
```

is **two independent transactions**, not one. Between the mangle `COMMIT` and the `*nat` parse, the lock is released, and another iptables call could squeeze in. In the worst case, mangle is swapped to the new TPROXY port but nat is still pointed at the old fakeip target — a brief misroute.

### What this means for the design

Flux's TPROXY swap touches:
- `*mangle` — `PROXY_PREROUTING` and `PROXY_OUTPUT` chains (the actual TPROXY targets)
- `*nat` — fakeip DNAT rules (`scripts/rules:_build_fakeip_rules`)
- `*filter` — only loopback rejection (low-impact)

The mangle/nat split is the dangerous one. Two options:

**Option A — sequencing (works on iptables today):**
1. Add new mangle chains with new names (`PROXY_PREROUTING_NEW`, `PROXY_OUTPUT_NEW`) pointing at `PROXY_PORT + 1`.
2. Swap the jump from `PREROUTING -> PROXY_PREROUTING_OLD` to `PREROUTING -> PROXY_PREROUTING_NEW` (one rule replacement, one transaction).
3. fakeip DNAT in nat stays pointed at `127.0.0.1` regardless of port (it dnats by destination, not source-port) — **no swap needed**. Verified by re-reading `scripts/rules:_build_fakeip_rules` L315-321: the DNAT target is the loopback address, not the port.
4. Delete old chains after drain.

This sidesteps the per-table atomicity gap: only mangle needs swapping, and the swap itself is one jump-rule replacement within a single mangle transaction.

**Option B — defer to nftables (P1b):**
nftables provides true cross-table atomicity within one `nft -f file.nft` transaction. When the P1b generator lands, the blue-green design becomes one atomic ruleset replacement, removing the entire sequencing concern.

**Recommendation:** Implement Option A first (works with the shipped iptables_restore backend), and migrate to Option B when P1b's generator ships. The P1b design doc already accounts for atomic transactions as a primary benefit.

References:
- iptables `-w` lock semantics (commit message): https://github.com/aosp-mirror/platform_external_iptables/commit/1e95b6c9171061d950d0a76a1f39e1be3db6cb09
- nftables atomic transactions: https://wiki.nftables.org/wiki-nftables/index.php/Atomic_rule_replacement

---

## Assumption 3: SIGTERM gracefully drains existing connections

**Verdict:** TRUE, with a **bounded** timeout.

### Evidence

- `cmd/sing-box/cmd_run.go:175` (sing-box main branch) registers SIGTERM, SIGINT, and SIGHUP via `signal.Notify(osSignals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)`. All three trigger the same shutdown path — **SIGHUP does not reload; it shuts down**.
- `cmd_run.go:206-216` defines `closeMonitor`, which calls `time.Sleep(C.FatalStopTimeout)` after `Box.Close()` begins, and if shutdown hasn't completed by then, logs `"sing-box did not close!"` as a fatal error. So graceful shutdown is real but time-bounded.
- `box.go:574-630` `Box.Close()` sequentially closes service → inbound → outbound → DNS → network. Inbound shutdown closes the listening socket first (no new connections accepted) before tearing down the connection tracker. This is textbook drain-on-close.

### What this means for the design

- The drain budget is `C.FatalStopTimeout`. The current value in sing-box is short (single-digit seconds). For Flux's blue-green this is fine: after the iptables jump swap, no new connections land on the old port, so the drain only has to flush whatever was mid-handshake at swap time.
- A measured TCP RST / half-open close window of under 5 seconds for the old instance is realistic. UDP and TPROXY-redirected connections will simply migrate to the new instance on their next packet.

### Hard refutation of "SIGHUP reload"

Some online threads suggest sending SIGHUP to sing-box for config reload. **This is wrong.** `cmd_run.go:175` proves SIGHUP triggers the same shutdown path as SIGTERM. There is no SIGHUP reload handler in sing-box, and there is no Clash API `/shutdown` or `/reload` endpoint (see Issue [#3806](https://github.com/SagerNet/sing-box/issues/3806), where the absence of a Clash-API shutdown is the topic of an open feature request, not a design oversight).

References:
- sing-box `cmd_run.go` signal handling: https://github.com/SagerNet/sing-box/blob/testing/cmd/sing-box/cmd_run.go
- sing-box `box.go` Close(): https://github.com/SagerNet/sing-box/blob/testing/box.go
- Clash-API shutdown gap: https://github.com/SagerNet/sing-box/issues/3806

---

## Assumption 4: Ecosystem precedent

**Verdict:** FALSE. **No established Android proxy project implements blue-green restart.**

Verified by direct inspection of:

| Project | Restart strategy | Reference |
|---|---|---|
| AndroidTProxyShell | `stop → short delay → start` (the project's README explicitly states this) | https://github.com/CHIZI-0618/AndroidTProxyShell |
| box4magisk | sequential service stop/start under Magisk service.sh | https://github.com/CHIZI-0618/box4magisk |
| NetProxy-Magisk | `sing-box run → api_wait_available 60s → tproxy.sh start` on every restart — full teardown each time | docs/netproxy-magisk-analysis-report.md (in this repo) |
| ClashMetaForAndroid (GUI) | VPNService teardown + restart (Android framework forces this) | https://github.com/MetaCubeX/ClashMetaForAndroid |
| NekoBox | Same as ClashMetaForAndroid | https://github.com/MatsuriDayo/NekoBoxForAndroid |

This is not a count-of-projects argument; it's an evidence-of-absence argument. If blue-green were a viable pattern on Android, at least one of these projects would have shipped it in the years they've been maintained. They have not. The reason is plausibly the per-table atomicity gap above (everyone hits it; sequencing is hard to get right without a real test bed), combined with the cache_file ownership rules.

### What this means for the design

Flux can be the first if the design is correct, but the bar is high. **The verification report is not blocking the work, but it is recommending that the implementation lands behind an opt-in `RESTART_STRATEGY=blue_green` flag**, the same way P1b's nftables backend is opt-in. The default must remain `stop → start`. This matches your goal-driven rule: *"All changes must be opt-in with graceful fallback to the existing iptables TPROXY path. Never break the current default path."*

---

## Final Go / No-Go

**GO**, conditional on the following design constraints landing together when P3 is implemented:

1. **`RESTART_STRATEGY` enum:** `serial` (default — current behavior) and `blue_green` (opt-in).
2. **Alternate-port allocation:** dispatcher reserves `PROXY_PORT + 1` (or another configurable offset) and generates a parallel `config_alt.json` via `jq` with the listen address rewritten.
3. **Alternate cache_file:** parallel `cache_alt.db` path. Document the fakeip-cold caveat in a one-line user-visible log message.
4. **Mangle-jump sequencing (iptables path):** Implement Option A from §Assumption 2. Add `PROXY_PREROUTING_NEW` / `PROXY_OUTPUT_NEW` chains, swap the single PREROUTING/OUTPUT jump rule in one mangle transaction, then delete the old chains after drain.
5. **nftables path (when P1b lands):** Use one `nft -f` transaction for the full swap. The migration design doc §1 already provides the chain topology.
6. **Drain budget:** SIGTERM the old instance, then `kill -0` poll for up to `CORE_TIMEOUT` seconds before `SIGKILL`. Mirrors `scripts/core:_kill_core` behavior, which exists today.
7. **Hard refutation in code comments:** any code that mentions SIGHUP or "reload" near sing-box must cite `cmd_run.go:175` to prevent future drift back to the wrong assumption.

If any of these can't be implemented or verified on a real device, abort blue-green and stay with serial restart. Per goal-driven rule: *"No fake implementations. If you can't verify something works on Android, document the gap and stop — do not stub or pretend."*

---

## What this report does NOT do

- It does not implement blue-green restart. Per the original execution plan, P3 in this round is verification-only. The actual implementation requires a real Android device for the drain-window measurement and FakeIP cold-cache UX check.
- It does not commit any change to dispatcher, core, or tproxy. The only artifact is this document.
- It does not change the recommendation that the P3 implementation be behind an opt-in flag.

---

## References (consolidated)

### sing-box source
- `box.go` Close(): https://github.com/SagerNet/sing-box/blob/testing/box.go
- `cmd_run.go` signal handling: https://github.com/SagerNet/sing-box/blob/testing/cmd/sing-box/cmd_run.go
- Clash API config: https://sing-box.sagernet.org/configuration/experimental/clash-api/
- cache_file config: https://sing-box.sagernet.org/configuration/experimental/cache-file/
- Issue #3806 (no Clash API shutdown): https://github.com/SagerNet/sing-box/issues/3806

### iptables / nftables
- iptables -w lock semantics commit: https://github.com/aosp-mirror/platform_external_iptables/commit/1e95b6c9171061d950d0a76a1f39e1be3db6cb09
- nftables atomic transactions: https://wiki.nftables.org/wiki-nftables/index.php/Atomic_rule_replacement

### Ecosystem
- AndroidTProxyShell: https://github.com/CHIZI-0618/AndroidTProxyShell
- box4magisk: https://github.com/CHIZI-0618/box4magisk
- ClashMetaForAndroid: https://github.com/MetaCubeX/ClashMetaForAndroid
- NekoBoxForAndroid: https://github.com/MatsuriDayo/NekoBoxForAndroid
- NetProxy-Magisk: `docs/netproxy-magisk-analysis-report.md` (in this repo)
