# Roadmap Status Reconciliation

**Purpose:** Single source of truth for every proposal in `flux-architecture-analysis.md` — what shipped, what's deferred, what was rejected. Generated after the P5+P6 cleanup so future maintainers don't have to grep commits to know the state.

**As of:** commit `6ddac12` (P5-C2). Updated whenever an item changes state.

---

## §3.1 — nftables backend

| Status | Commit | Notes |
|---|---|---|
| **DEFERRED-BY-DESIGN** | `80653c8` (P1b) | Scaffolding shipped: enum extended, dispatcher recognises `RULE_BACKEND=nft` with logged fallback. Generator awaits real-device verification per `docs/p1b-nftables-backend-design.md`. After P5-A2 the user-visible knob is removed; the internal default (`scripts/lib`) keeps the fallback branch alive so the next implementer can flip it on. |

## §3.2 — BPF as primary interception

| Status | Notes |
|---|---|
| **REJECTED** | Architecture analysis itself §3.2 rejects BPF as primary — netfilter TPROXY remains the path. No future P-doc plans to revisit. |

## §3.3 — Hot reload / blue-green / differential

| Sub-item | Status | Commit |
|---|---|---|
| Differential update detection | **SHIPPED** | `662e93f` (P0) |
| Pre-validate via `sing-box check` | **SHIPPED** | already in updater pre-P0 |
| Blue-green restart | **VERIFICATION-ONLY** | `8466f03` (P3-prep) is a verification report that documents the blueprint without code changes. Full implementation deferred. |
| Atomic iptables-restore swap | **PARTIAL** | `--noflush` mode used today; P6-A added `--test` pre-validation. Full atomic-replace per table not pursued — design judges current model sufficient. |

## §3.4 — Conntrack zone isolation

| Status | Notes |
|---|---|
| **REJECTED-AS-OPT-IN-ONLY** | P5 §C.5 designed an opt-in `CT_ZONE_ISOLATE` toggle but the implementation was skipped: the toggle adds dead-code complexity until someone verifies it on a vendor-tethering device, and there is no current incident proving the conntrack collision risk is real on modern Android. Will be revisited if `fluxctl stats` (P2a) shows actual table pressure traceable to vendor collisions. |

## §3.5 — DNS integration with Android resolver

| Sub-item | Status | Commit | Notes |
|---|---|---|---|
| Cooperative DNS via `ndc resolver setnetdns` | **REJECTED** | `9858b12` (P2b) | Commit body documents the rejection: `ndc` is gated behind SELinux on Android 10+; `settings put global private_dns_mode` is the supported surface. |
| Three-mode `PRIVATE_DNS_GUARD` (off/strict/auto) | **SHIPPED** | `9858b12` (P2b) | The cooperative path is auto-mode: override only when current `private_dns_mode=hostname` would bypass sing-box. |
| Loopback DNS proxy on 127.0.0.1:53 | **NOT-PURSUED** | — | Would require sing-box config restructuring; the auto-mode `PRIVATE_DNS_GUARD` solves the same user-visible problem with one setting. |
| Per-app DNS via APP_PROXY_MODE | **NOT-PURSUED** | — | sing-box's DNS plane is global; per-app DNS would need either DoH per-app (Android API only) or a routing-table-per-app rewrite. Out of scope for v1. |

## §3.6 — Observability & monitoring

| Sub-item | Status | Commit | Notes |
|---|---|---|---|
| JSON log format | **NOT-PURSUED** | — | Text logs are tail-able from Termux. Demand has not surfaced. If/when a structured-ingest user appears, `LOG_FORMAT=json` can ride on top of existing `log_*` helpers. |
| `fluxctl stats` | **SHIPPED** | `e51af06` (P2a) | iptables counters + addrsyncd status + Clash API connection summary. |
| Health endpoint `/healthz` | **NOT-PURSUED** | — | Adds a sidecar process. Same data is already in `fluxctl stats`; for external monitoring users can poll the existing CLI from cron or Magisk-Manager. Sidecar would need its own restart-supervision plumbing — non-trivial. |
| Crash tombstone | **SHIPPED** | `d36ba8f` (P4b) | Stage scripts emit a postmortem on ERR trap with last log lines, kfeat dump, iptables -L -v, conntrack count, active runtime snapshot. |

## §3.7 — "Additional recommendations"

| Item | Status | Commit | Notes |
|---|---|---|---|
| `fluxctl validate` | **SHIPPED** | `662e93f` (P0) | |
| WireGuard auto-exclude | **SHIPPED** | `0c7de3f` (P4c) | `wg+` default in `EXCLUDE_INTERFACES`. |
| Socket UDP probe | **SHIPPED** | `9ebcdf0` (P4a) | Runtime probe replaces hardcoded `KFEAT_SOCKET_UDP=0`. |
| IPv6 NAT unified fallback | **SHIPPED** | `54f8e3e` (P4d) | `CONFIG_NF_NAT` / `nf_nat` module satisfies IPv6 NAT on 5.1+. |
| addrsyncd TOML crate | **NOT-PURSUED** | — | Custom parser handles flat KV. No upcoming feature requires arrays-of-tables; cost not justified. Will revisit if a real config shape forces it. |
| Batch pool pre-allocation tuning | **NOT-PURSUED** | — | Current 8×capacity headroom has not shown allocation pressure under the workloads tested. Tuning without a measured signal is premature. |
| Per-family route drain budget | **DEFERRED** | — | P5 §C.4 explicitly deferred: budget is already adaptive (64–1024). Revisit only if `fluxctl stats` (P2a) shows IPv6 starvation. |
| Sigstop-based daemon pause | **NOT-PURSUED** | — | Andoid init's signal handling for native daemons is finicky; the SIGSTOP/SIGCONT dance can leave the daemon in an unrecoverable state on some vendor kernels. Hot-restart via the dispatcher (P0/P1a/P3) avoids this class of risk. |
| Multi-user work-profile awareness | **NOT-PURSUED** | — | `APP_USER_SCOPE=all` covers the common case (cross-profile proxy for the same app id). Per-profile differentiation would need `pm list users` polling and a per-profile UID table — substantial complexity for unclear demand. |
| mihomo HTTP API compat | **NOT-PURSUED** | — | sing-box already exposes the Clash API at its own endpoint (consumed by `fluxctl stats`). Shipping a second compat surface would be code duplication. Users wanting mihomo dashboards can point them at sing-box's existing Clash-compatible endpoint. |
| eBPF map sharing | **REJECTED** | — | §3.2 rejects BPF as primary; map-sharing as an accessory only makes sense once BPF is on the hot path. Composes downstream of a rejected proposal. |
| io_uring in addrsyncd | **NOT-PURSUED** | — | epoll is fine for the addrsyncd workload (single fd, low rate). io_uring adoption would require kernel-version probing and dual-path code — cost not justified by the ~40% syscall-overhead reduction in a process that is already idle most of the time. |
| Minimal SELinux policy | **NOT-PURSUED** | — | Magisk modules run in the magisk daemon context; tightening SELinux for the dispatcher would require a custom policy load that varies per Magisk/KernelSU/APatch. Compatibility cost > security gain for a root-required tool. |

## §5 — Implementation roadmap steps

| Step | Status | Commit |
|---|---|---|
| 1. `fluxctl validate` | SHIPPED | `662e93f` (P0) |
| 2. Differential update detection | SHIPPED | `662e93f` (P0) |
| 3. Staged startup hardening | SHIPPED | `0eede9b` (P1a) |
| (post-§5) JSON log format | NOT-PURSUED | see §3.6 |
| (post-§5) Cooperative DNS | SHIPPED-AS-PRIVATE-DNS-GUARD | `9858b12` (P2b) |
| (post-§5) Hot reload — verification | SHIPPED | `8466f03` (P3-prep) |
| (post-§5) Hot reload — implementation | DEFERRED | needs device-time |
| (post-§5) Conntrack zone isolation | REJECTED-AS-OPT-IN-ONLY | see §3.4 above |
| (post-§5) Per-app SO_BINDTODEVICE | OUT-OF-SCOPE | sing-box outbound concern |
| (post-§5) io_uring addrsyncd | NOT-PURSUED | see §3.7 |

---

## Beyond `flux-architecture-analysis.md`

P-series items that were added later (not in the original analysis):

| Item | Status | Commit | Origin |
|---|---|---|---|
| Settings cleanup / chain shape / IPTABLES_WAIT / rp_filter | SHIPPED | P5 series — `a619686`, `4e94aca`, `20083be`, `198ccf4`, `6ddac12` | `docs/p5-config-and-chain-cleanup.md` |
| iptables-restore --test prevalidation | SHIPPED | `a7a0a55` (P6-A) | `docs/p6-…md` §A |
| External bypass.v{4,6}.list | SHIPPED | `2908c63` (P6-D) | `docs/p6-…md` §D |
| Conntrack table sizing + reclaim | SHIPPED (opt-in) | `97e75f9` (P6-B) | `docs/p6-…md` §B |
| Socket buffer ceiling | SHIPPED (opt-in) | `d735143` (P6-C) | `docs/p6-…md` §C |

---

## Open work items

Nothing on the roadmap requires further code action right now. If new work is taken on, the candidates with the strongest evidence-to-effort ratio are:

1. **Blue-green hot-restart implementation** (closes §3.3, design already verified in P3-prep).
2. **Per-family route drain budget** (closes §3.7 row 7) — but only after `fluxctl stats` data shows it matters.
3. **Conntrack zone isolation as opt-in** (closes §3.4) — pending a real incident proving collision risk.

Everything else listed under "NOT-PURSUED" above was evaluated and judged either out-of-scope, cost-not-justified, or composed downstream of a rejected proposal. They will be revisited only on new evidence (incident, user report, kernel-feature gate landing).
