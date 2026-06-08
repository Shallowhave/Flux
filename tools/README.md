# tools/

Host-side build & release tooling. **Not shipped in the module zip** —
`customize.sh` only extracts `bin/`, `scripts/`, `conf/`, plus the
module-root files. Anything under `tools/` stays on the build host.

## package.sh

Builds an installable Magisk/KernelSU/APatch zip.

```bash
# Full build — compile addrsyncd, fetch latest sing-box + jq, package
make package

# Lite build — scripts and config only, no bin/. User supplies binaries.
make package-lite

# Pin specific upstream versions
bash tools/package.sh --singbox-version v1.10.4 --jq-version jq-1.7.1

# Re-use already-downloaded binaries (place sing-box + jq under dist/cache/)
bash tools/package.sh --no-fetch --no-addrsyncd-build
```

Output: `dist/flux-<version>.zip` (plus a SHA-256 printed on stdout).

### Host prerequisites

- `bash`, `curl`, `jq`, `sha256sum`, `tar`, `unzip`, `zip`, `awk`, `sed`
- For addrsyncd build: `rustup`, `cargo`, and the Android NDK clang linker
  on `PATH` (`aarch64-linux-android21-clang`). See `addrsyncd/README.md`
  for the exact NDK env-var setup.

Authenticated GitHub API access (recommended on shared CI): set
`GITHUB_TOKEN` in the environment. Unauthenticated requests are subject
to a 60/hour rate limit per IP.

### Verification

Every downloaded binary is SHA-256-verified against the upstream
`SHA256SUMS`/`sha256sum.txt` file in the same GitHub release. A
mismatch aborts the build before the binary touches the stage tree.

The packager refuses to ship a release whose stage tree contains a
shell script that fails `bash -n`, or a `bin/<x>` that is not ELF.

### Output manifest

The zip ships `conf/manifest.json` populated with the resolved upstream
versions and binary SHA-256s — downstream consumers can verify the
provenance of any installed Flux without re-fetching the module.
