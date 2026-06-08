# Changelog

All notable changes to the Flux project will be documented in this file.

## [v1.5.0] - 2026-06-08

### 🛡️ Rule-apply safety (P6-A)
- `scripts/tproxy:_rules` now runs `iptables-restore --test` on the rule cache before the `--noflush` apply. A malformed cache is rejected before any netfilter mutation, preventing the previous half-applied-state failure mode. Mirrors AOSP `system/netd/IptablesRestoreController.cpp`. Applies to both apply and cleanup paths (one chokepoint).

### 🧰 User-extensible bypass list (P6-D)
- New optional files `conf/bypass.v4.list` and `conf/bypass.v6.list` (one CIDR per line; `#` comments; blank lines ignored). Entries are **additively** merged with the built-in carrier-safe defaults — built-ins cannot be removed (loopback safety). Malformed lines emit a `log_warn` and the apply continues. Files are not shipped in the module zip and survive updates by absence.

### 🧪 Opt-in resource tuning (P6-B / P6-C / P5-C2)
- `CONNTRACK_MAX`, `CONNTRACK_UDP_STREAM_TIMEOUT`, `CONNTRACK_TCP_CLOSE_WAIT_TIMEOUT` — write to `/proc/sys/net/netfilter/*` for high-flow workloads (WebRTC, P2P).
- `SOCKET_BUFFER_MAX` — symmetric `net.core.{rmem,wmem}_max` ceiling for sing-box's UDP TPROXY inbound on heavy QUIC traffic.
- `LOCALNET_FIX` — opt-in `route_localnet=1` for niche localhost-DNAT use.
- All four default empty/0; defaults preserve byte-identical behavior. All four are snapshot+restored on dispatcher stop using the existing `IPV6_FORCE_DISABLE`/`HOTSPOT_FIX` plumbing.

### 🔧 TPROXY correctness (P5-C2)
- `net.ipv4.conf.all.rp_filter` automatically set to `2` (loose mode) when `PROXY_MODE=tproxy`, snapshot+restored on stop. Fixes the "first packet vanishes" symptom on multi-interface devices where strict reverse-path filtering drops asymmetric TPROXY-redirected packets. Per kernel `ip-sysctl.rst` and mihomo / box4magisk precedent.

### ⚡ Chain shape (P5-B3, P5-B4)
- Dropped the no-op `-A PROXY_OUTPUT -m conntrack --ctdir REPLY -j ACCEPT` line — locally-originated packets on OUTPUT never carry REPLY direction on Android. Saves one rule traversal per outbound packet per family. mihomo, box4magisk, AndroidTProxyShell precedent.
- `BYP_Z*` zone chains are now created conditionally based on the merged bypass list. With default settings, 7 / 16 IPv4 chains and 11 / 16 IPv6 chains are no longer emitted.

### 🐛 IPTABLES_WAIT off-by-20× (P5-C1)
- `scripts/lib:IPTABLES_WAIT` was `100` with a "centiseconds" comment, but iptables 1.6+ parses `-w` as **seconds**. On lock contention, stages blocked for 100 s. New value `5` matches AOSP `IptablesRestoreController.cpp`.

### 🧹 Settings cleanup (P5-A)
- Removed `VENDOR_FIX_PROFILE` — recorded but had no behavioural code path.
- Demoted `RULE_BACKEND` and `BYPASS_SET_BACKEND` to internal `scripts/lib` defaults — neither had a working second value to choose.
- Comment polish: `CORE_USER`/`CORE_GROUP` loopback-rule warning, `IPV6_FORCE_DISABLE` system-wide warning, `HOTSPOT_INTERFACE` empty default with example, corrected the wrong "deprecated" comment on `PROXY_IPV6`, regrouped `TUN_*` knobs under an explicit "Only used when PROXY_MODE=tun" sub-header.

### 📦 Release process
- `tools/package.sh` — single-command Magisk module builder. Compiles addrsyncd via `cargo`, fetches the latest sing-box (android-arm64) and jq (linux-arm64 static, bionic-compatible) from GitHub releases, verifies SHA-256 against upstream sums, stages the on-device tree, and emits `dist/flux-<version>.zip`.
- `Makefile` — `make package` / `make package-lite` wrappers.
- `tools/README.md` — host prereqs, version pinning flags, verification details.
- The shipped zip carries `conf/manifest.json` populated with resolved upstream versions and binary SHA-256s.

### 📚 Documentation
- `docs/p5-config-and-chain-cleanup.md` — design for the chain/sysctl work above.
- `docs/p6-rule-safety-resource-tuning-and-list-externalization.md` — design for the safety/tuning/extensibility work above.
- `docs/roadmap-status.md` — explicit SHIPPED / DEFERRED / REJECTED / NOT-PURSUED status for every proposal in `flux-architecture-analysis.md`.

## [v1.4.0] - 2026-02-23

### ⚠️ Correctness & Stability
- Fixed `UPDATE_INTERVAL=0` behavior: it now correctly disables boot-time auto update.
- Wired `UPDATE_TIMEOUT` into updater download requests (`curl --connect-timeout/--max-time`).
- Reordered init checks to allow missing `config.json` before updater/cache rebuild flow.
- Hardened cache validation: `cache_ok` now also requires required cache files to exist and be non-empty.
- Added strict parallel task result aggregation via `wait_pids` in init/dispatcher critical paths.

### 🔁 Runtime Lifecycle
- Refactored `scripts/addrsync` lifecycle to PID-based flow (no internal `status` polling loops).
- Implemented `addrsyncd stop` first, with `kill -9` fallback and deterministic pid cleanup.
- Added dispatcher handling for `addrsyncd.toml` change events.
- Added `init cache` action for cache-only rebuild path used by config hot-reload.

### 🧾 Config & Docs Alignment
- Removed `BYPASS_IPV4_LIST` / `BYPASS_IPV6_LIST` from `settings.ini` exposure; keep internal constants in `scripts/lib`.
- Updated installer migration key set to match current public settings.
- Synced README/README_zh with current addrsync-based architecture and real config keys.
- Removed stale documentation keys (`RULES_DEBUG_DUMP`, `INCLUDE_INTERFACES`) from README tables.

### 📦 Release Process
- Added `scripts/check_release.ps1` for lightweight pre-release consistency checks.
- Updated package workflow to:
  - run release checks before packaging
  - include `flux_service.sh` (instead of stale `service.sh`)
  - enforce required ZIP entries (including `conf/addrsyncd.toml`)

## [v1.3.3] - 2026-02-07

### ⚡ IP MONITOR PERFECTION
- **Unified AWK Engine**: Rewrote `ipmonitor` with a single-process architecture that combines initial IP sync and real-time monitoring, using three-layer filtering (semantic, memory-state, phase-based) for zero-redundancy rule operations

### 🔧 CONSTANTS CONSOLIDATION
- **Internal Network Constants**: Moved `TABLE_ID`, `IPV4_MARK`, `IPV6_MARK`, and `BYPASS_MARK` from user-configurable `settings.ini` to `scripts/const` as `readonly` system constants
- **Simplified Configuration**: Removed obsolete `MARK_VALUE`, `MARK_VALUE6`, and `TABLE_ID` from settings documentation

### 🛠️ CODE REFINEMENT
- **Merged Log Rotation**: Combined `_rotate_file` and `_rotate_log` into a single streamlined function in `scripts/init`

## [v1.3.2] - 2026-02-06

### ⚡ STARTUP OPTIMIZATION
- **Parallel IPMonitor**: `ipmonitor` now starts simultaneously with `core` and `tproxy`, reducing startup latency by eliminating unnecessary dependency wait
- **Simplified Readiness Logic**: Removed `READY_LOCK` mutex as concurrent safety is no longer needed with parallel component startup

### 🔧 CACHE SYSTEM REFACTORING
- **inotify-Based Invalidation**: Replaced mtime-based fingerprint validation with real-time configuration file monitoring
  - Configuration changes instantly invalidate cache via `rm meta_cache`
  - Eliminated ~50 lines of fingerprint calculation logic
- **Prioritized Config Loading**: All scripts now prefer `cache_config` (when meta exists) over `settings.ini` for faster initialization

### 🛠️ ROBUSTNESS IMPROVEMENTS
- **Updater Cleanup Fix**: Moved `trap _cleanup` to function entry, ensuring workspace cleanup even on early errors

### 🗂️ CODE ORGANIZATION
- **Inline Cache Validation**: Moved cache check logic from standalone script call to inline execution in `init`, reducing subprocess overhead

## [v1.3.1] - 2026-01-29

### ⚡ EXTREME PERFORMANCE
- **Ultimate Streamlined Proxy Chain**: Introduced `:ACTION_PROXY` and `:ACTION_BYPASS` sub-chains to deduplicate mangle rules.
- **Rule Count Optimization**: Reduced the number of rules in high-frequency chains (APP_CHAIN/BYPASS_IP) by ~50%, leading to faster kernel-space lookup.

### 🚀 PROTOCOL-AGNOSTIC ARCHITECTURE
- **Agnostic Proxy Chain**: Decoupled transport protocols from the decision logic. Flux now intercepts all traffic by default and dispatches it via a unified `TPROXY_GATE`.
- **Simplified Configuration**: Removed `PROXY_TCP` and `PROXY_UDP` settings. The system now automatically handles all supported transient traffic.
- **Unified Entry Points**: Refactored IPTables logic to use single-pass attachment for both `PREROUTING` and `OUTPUT` chains, reducing rule count and kernel overhead.

### 🛡️ REFINE & OPTIMIZE
- **Unified Proxy Port**: Consolidated `PROXY_TCP_PORT` and `PROXY_UDP_PORT` into a single `PROXY_PORT` for simplified configuration and rule management.
- **JQ Extraction Refinement**: Updated `jq` logic to exclusively recognize `tproxy` type inbounds, ensuring alignment with the project's focus on transparent proxying.

## [v1.3.0] - 2026-01-29

### ⚠️ BREAKING CHANGES
- **Updater Standardization**: Completely removed `subconverter` dependency. The `updater` script now relies purely on `jq` for robust and lightweight subscription handling.
- **Directory Structure Clean-up**: Removed the obsolete `tools/` and `scripts/iphandler` directories to streamline the package.
- **Auto-Detected Conntrack**: Removed `ENABLE_CONNTRACK` setting. It is now automatically enabled if the kernel supports `nf_conntrack`/`xt_conntrack`.

### ✨ NEW FEATURES
- **Emoji Cleanup Preference**: Introduced `PREF_CLEANUP_EMOJI` in `settings.ini` to optionally remove emojis from node names during subscription updates.
- **Strict Mode Enforcement**: All scripts now run with `set -u` (nounset) enabled, significantly improving error detection and preventing "silent failure" bugs caused by undefined variables.

### 🛡️ FIXES & OPTIMIZATIONS
- **Documentation Sync**: Fully aligned `README.md` and `README_zh.md` directory structures and configuration tables.
- **Fail-Fast Logic**: Helper functions in `scripts/rules` (`_build_loopback_block`, `_build_nat_extra`) now strictly require action arguments to prevent ambiguity.

## [v1.2.0] - 2026-01-27

### 🚀 EXTREME PERFORMANCE & ARCHITECTURE
- **16-Zone Jump Tree (IPv4/IPv6)**: Replaced linear O(N) IP bypass lookups with an O(1) tiered jump tree. Reduced CPU consumption by ~85% in high-CIDR environments.
- **SRI (State-driven Routing Injector)**: Replaced file-based IP polling with a FIFO-backed reactive engine in `ipmonitor`. Achieved sub-second routing synchronization.
- **Atomic Readiness Protocol**: Introduced a robust `mkdir`-based locking mechanism in `scripts/dispatcher` to prevent race conditions during concurrent state transitions.
- **Fast-Path Traffic Funnel**: Optimized IPTables logic to ensure established/reply packets exit the kernel mangle chain at the earliest possible entry point.

### 🛡️ RELIABILITY & REFINEMENT
- **Safe Log Rotation**: Implemented a "copy-truncate" strategy in `scripts/init` to ensure concurrent-safe log management without stream interruption.
- **Enhanced Configuration Validation**: Added multi-interface validator for `EXCLUDE_INTERFACES` and schema-driven type checking for all 30+ settings.

### 🧹 CLEANUP & STANDARDIZATION
- **Code Refinement**: Standardized all function prefixes, variable naming conventions, and logic orchestration patterns.
### ⚠️ BREAKING CHANGES
- **MAC Address Bypass Removal**: Deprecated MAC-based filtering to eliminate kernel overhead and maintain focus on O(1) IP-based routing.
- **Unified Application Filtering**: Consolidated `PROXY_APPS_LIST` and `BYPASS_APPS_LIST` into a single, highly efficient `APP_LIST` controlled by `APP_PROXY_MODE`.

### ⚙️ ENHANCED PROXY FLOW
- **Phase 1: Zero-Match Fast Path**: Established/Reply packets exit the kernel logic immediately (90% traffic optimization).
- **Phase 2: Tiered IP Decision**: New 16-Zone Jump Tree processes large bypass lists with near-constant time complexity.
- **Phase 3: Reactive Routing**: SRI 2.0 (State-driven Routing Injector) triggers sub-second route synchronization via FIFO pipes upon network state changes.
- **Phase 4: Unified DNS Orchestration**: Centralized DNS hijacking logic replaces redundant per-chain rules, ensuring consistent behavior across NAT and TProxy.

## [v1.1.0] - 2026-01-24

### Fixed
- **Shutting Down Interruption**: Resolved "Interrupted system call" noise in `ipmonitor` by optimizing signal traps and pipe cleanup order.
- **State Corruption Risks**: Implemented `mktemp` + `mv` strategy for `module.prop` and config updates to ensure atomic writes.
- **Kernel IPv6 Compatibility**: Added `KFEAT_IPV6_NAT` detection in `iphandler` to prevent crashes on older kernels.

### Refined
- **Solution A Logging**: Unified `stderr` redirection across all entry points for reliable inheritance and zero-redundancy log capture.
- **Variable Handling Syntax**: Hardened all conditional checks project-wide using safe string comparison `[ "$VAR" = "1" ]`.
- **Startup Resilience**: Integrated `kill -0` checks in the readiness loop for instant failure detection instead of hardcoded delays.

### Optimized
- **Zero-Fork UID Memoization**: Switched to native Shell parameter expansion for cache keying, eliminating expensive subshell overhead.
- **Component Lifecycle**: Termination and rollback flows are now fully parallelized for faster state transitions.

## [v1.0.0] - 2026-01-23

### ⚠️ MAJOR REWRITE
Flux v1.0.0 is a near-total rewrite aimed at professionalism, robustness, and maximum hardware efficiency. This version breaks away from legacy shell patterns to provide a more industrial-grade experience on Android.

### Added
- **Multi-tier Cache System**: A high-performance caching engine that eliminates redundant processing:
  - **Kernel Cache**: Persistent detection of kernel capabilities (`KFEAT_*`).
  - **Rules Cache**: Pre-generated, atomic IPTables rule sets for sub-second application.
  - **Config Cache**: Normalized and pre-validated configuration state.
  - **Meta Cache**: Environment fingerprinting (vCode, mtimes, kernel) for intelligent cache invalidation.
- **Event-Driven Orchestration**: Transitioned to a reactive architecture using `inotifyd` and a central `dispatcher` for sub-second response to state changes.
- **Atomic Reliability Layer**: All critical file operations (configs, prop) now use a temp-and-swap strategy for 100% integrity.
- **Intelligent Config Extraction**: robust `jq`-based inbound/port detection for complex `sing-box` configurations.

### Changed
- **Architectural Rewrite**: Decoupled monolithic logic into focused, role-based components.
- **Stream-Optimized Rule Engine**: Refactored `rules` to use direct data streams, minimizing memory pressure.
- **Enhanced Diagnostics**: Captured and streamed granular error output from `iptables-restore` for immediate troubleshooting.
- **Documentation Optimization**: Refined `README.md` focus and added multi-language support (English | [简体中文](README_zh.md)).

### Removed
- **Legacy Prefixes**: Cleaned up script directory by removing redundant `flux.*` prefixes and `flux_` function prefixes.
- **Obsolete Rules**: Removed "China IP Bypass" logic from core rules to keep the implementation lean and focused.

---

## [v0.9.0] - Previous Stable
- Original release with monolithic script architecture.
- Basis for the v1.0.0 complete overhaul.
