# OpenSSL static libraries — build system (vendored)

Consolidated entry point for everything under `openssl/` that builds, verifies, or documents the
static `libcrypto.a`/`libssl.a` (and Windows `.lib`) archives this repo ships — including the
per-target provenance ledger that used to live in two separate `state.txt` files (`libstatic/
state.txt` and the older, stale `libstatic/linux/state.txt`, both folded in here and removed
2026-08-24). If you're looking for *why a specific archive is the way it is*, the "Per-target
status" section below has it; for *exactly what flags/toolchain build it*, `targets.sh` is the
actual source of truth for path-2 Linux/BSD/macOS builds.

## Map of this area

```
openssl/
  libstatic/                    the archives themselves (committed .a/.lib files)
    linux/
      openssl-<arch>            path 1: old, portable, glibc/apt-only build scripts (14 of them)
      <arch>/libcrypto.a         the committed archives themselves, one dir per target
    bsd/, macos/                 same idea, non-Linux targets
    windows/                     the committed Windows .lib archives (twelve of them)
    build/                       path 2: this directory
      README.md                  <- you are here (also the per-target status ledger and the
                                     Windows build docs)
      targets.sh / build.sh      the Linux/BSD/macOS build system
      consistency.sh             the anti-drift gate (see BUILD.md)
      orphans.txt                archive dirs kept but built by nothing
      flags.txt                  shared Configure flags, single source of truth
      windows/                    native-Windows sibling (MSVC/nmake, PowerShell)
        env.ps1, build.ps1, verify.ps1
build-env.sh                     repo root - shared env, sourced by every path-2 script + CI
fetch-toolchains.sh              repo root - provisions $BUILDROOT (see "Provisioning" below)
```

## Two build paths, one Windows path

1. **`openssl/libstatic/linux/openssl-<arch>` scripts** (path 1) — the older, portable,
   no-external-dependency reference path. Runs on any bare Debian/Ubuntu box with nothing at
   `$BUILDROOT` at all — glibc/apt cross-compilers and native `gcc`/`gcc -m32` only. 14 scripts,
   one per glibc target.
2. **`openssl/libstatic/build/`** (path 2, this directory) — `build-env.sh`/`targets.sh`/`build.sh`,
   git-tracked, additive to path 1: covers everything path 1 does, plus musl/uClibc
   OpenWrt SDKs, Bootlin toolchains, musl.cc toolchains, BSD clang cross-sysroots, and osxcross
   macOS cross-builds. Toolchain/sysroot/download data stays outside the repo at `$BUILDROOT`
   (default `/opt/buildroot`) — multi-gigabyte, provisioned once per machine via
   `fetch-toolchains.sh` (repo root, not under `openssl/` — it also wires two toolchains the
   *agent's own* cross-compile needs, `ARCHID=28`/`40`, into `../ToolChains/`).
3. **`openssl/libstatic/build/windows/`** — native-Windows sibling for the six MSVC/nmake targets
   (`x86`/`x64`/`arm64`, each Release+Debug). PowerShell, not bash — MSVC's `Configure` and `nmake`
   need a real MSVC developer environment. See "Windows build" below.

Where a destination directory exists in both path 1 and path 2 (`x86-64`, `x86`, `arm64`, `armhf`,
`arm`, `arm-linaro`, `pogo`), `targets.sh` is kept in sync with the `openssl-<arch>` script's
flags/toolchain choice deliberately. If they ever disagree, treat the `openssl-<arch>` script as
authoritative and fix `targets.sh` — this has happened before.

## Quick start (Linux/BSD/macOS, path 2)

```sh
./fetch-toolchains.sh                    # fresh machine: download+verify+extract everything fetchable
. build-env.sh         # sets REPO (derived from script location) and BUILDROOT
br_check                                 # confirms every toolchain/sysroot/source is present
openssl/libstatic/build/build.sh riscv64
openssl/libstatic/build/build.sh all
openssl/libstatic/verify                 # read-only audit + gate over whatever's already staged
openssl/libstatic/build/consistency.sh   # anti-drift gate (see BUILD.md)
```

Override the buildroot location if you keep it somewhere other than `/opt/buildroot`:

```sh
BUILDROOT=/somewhere/else . build-env.sh
```

### Building targets concurrently

`build.sh` builds one target at a time by default (`BR_JOBS=1`). Set `BR_JOBS` to build that many
targets at once:

```sh
BR_JOBS=4 openssl/libstatic/build/build.sh all
```

Each target's own `make -j` still wants multiple cores, so raising `BR_JOBS` splits the host's
cores across the concurrent slots (`MAKE_JOBS = nproc / BR_JOBS`) instead of every slot
independently claiming `make -j$(nproc)` and oversubscribing the machine `BR_JOBS`-fold. Override
`MAKE_JOBS` directly for a different split. Per-target output and pass/fail status are buffered
per target and replayed in the order you listed the targets, so a `BR_JOBS>1` run reads the same
as a sequential one, just faster on a multi-core box.

## What every script does

- **`flags.txt`** — the shared `Configure` flag set for every path-2 target (and, via
  `windows/env.ps1`, every Windows target too): `no-weak-ssl-ciphers no-srp no-psk no-comp
  no-zlib no-zlib-dynamic no-hw no-dso no-shared -no-asm no-rc5 no-idea no-md4 no-rmd160 no-ssl
  no-ssl3 no-seed no-camellia no-bf no-cast no-md2 no-mdc2 no-engine no-async no-ocsp no-cms`.
  Per-target overrides live in `targets.sh` (`T_FLAGS`, usually just re-enabling asm by removing
  `-no-asm`) and `T_EXTRA` (e.g. `enable-ec_nistp_64_gcc_128`, `-Os`). `no-async` was added
  2026-08-24 — see "The riscv64 ASYNC/ucontext bug" below.
  Per-target deltas are **not** separate files. There used to be a `flags.d/<name>.txt` override
  protocol — its loader was pasted into 8 workflows (keyed by *workflow* name) and implemented in
  none of `flags.txt`'s actual consumers, so an override file would have changed CI without
  changing any local build. Both the workflows and the mechanism are gone: a target that needs to
  deviate from the base set edits `T_FLAGS`/`T_EXTRA` in its own `targets.sh` case (Windows: the
  `Asm` field in `build.ps1`'s `$Targets`), which reaches local builds and CI identically because
  they run the same script.
- **`build-env.sh`** (repo root) — sourced, not executed. Defines `$BUILDROOT` and its subdirectories, the OpenSSL
  version pin, every `TC_*`/`SYSROOT_*` toolchain path, `GLIBC_ONLY_RE` (symbols that prove an
  archive can't be glibc-contaminated), and `br_check` (confirms every path referenced by any
  target is present).
- **`targets.sh`** — **the single hand-edited source of truth** for what compiles each target:
  `br_target <name>` sets `T_CONF` (Configure target), `T_CC`, `T_FLAGS`, `T_EXTRA`, `T_MAKE`,
  `T_DEST` (repo-relative destination dir(s)), `T_OBJS` (expected object count, the build's own
  regression check), `T_LIBC` (glibc/musl/uclibc/bsd/macos — the **only** list of which targets
  are non-glibc), `T_FETCH` (provisioning tokens) and `T_CI` (which CI runner family builds it). `BR_ALL_TARGETS` lists every buildable name. Read the comment on the specific
  target before touching it — most encode a real, previously-debugged reason (asm correctness
  bugs, glibc floor choices, hardware ABI matches) that isn't obvious from the flags alone. Also
  runnable directly (not sourced) as `targets.sh --names [ci]` (the CI matrix source) and
  `targets.sh --field <target> <FIELD>` (one value for shell/CI callers). Not committed anywhere as a static file —
  `T_CC` resolves through this machine's `$BUILDROOT`, so a checked-in snapshot would go stale the
  moment `$BUILDROOT` differs; instead it's generated fresh by whatever consumes it.
- **`build.sh`** — builds one or more targets and stages the result. Rejects and stages *nothing*
  on: wrong OpenSSL version, wrong object count (`T_OBJS`), a nonzero glibc-only symbol count in a
  `T_LIBC=musl`/`uclibc` target, or a nonzero ucontext count in a `musl` one. `BR_FETCH=1`
  provisions the toolchain first from the target's own `T_FETCH` tokens (CI sets this). `build.sh list` shows every target,
  its toolchain readiness, and which ARCHIDs in the makefile actually consume it (cross-referenced
  live via `make list`/`print-ossldir`, not a hardcoded map).
- **`../verify`** (`openssl/libstatic/verify`) — the single archive auditor, read-only, run both
  by hand and by CI (`build-system-checks.yml`). Reports version, object count, architecture and
  the `GLIBC`/`UCONTEXT` symbol columns for every staged archive, and **gates**: exits nonzero if
  the object count differs from the target's `T_OBJS` (the recipe's fingerprint — a miss means
  the archive was built with different Configure options, e.g. asm or `ec_nistp_64_gcc_128`, than
  `targets.sh` now says), if a `T_LIBC=musl`/`uclibc` target references a glibc-only symbol, if a `musl` target references
  `getcontext`/`setcontext`/`makecontext`/`swapcontext` (musl implements them on no architecture),
  or if an archive dir belongs to no target and is not listed in `orphans.txt`.

  There used to be two of these — this file and a `build/verify.sh` — each with its own copy of
  the "which targets are musl" list, and the two lists disagreed (`build/verify.sh`'s and
  `build.sh`'s both omitted `riscv64`, which is exactly how the glibc-built `riscv64` archive got
  past the gate). Both now derive that list from `targets.sh`'s `T_LIBC`; `build/verify.sh` is
  deleted.

- **`consistency.sh`** (this directory) — the anti-drift gate. Fails when the sources of truth
  stop agreeing, or when a value pinned in `build-env.sh`/an `ARCH_` block is spelled out in a
  workflow instead of being asked for. See **BUILD.md** at the repo root for the full list.

## Provisioning `$BUILDROOT` on a fresh machine

`./fetch-toolchains.sh` (repo root) automates everything with a public URL: the OpenSSL tarball,
the OpenWrt SDKs, the Bootlin toolchains (glibc/uClibc, checksum-verified), the musl.cc prebuilt
cross toolchains (aarch64, armhf, x86_64, riscv64 — no published checksum, gated on a smoke
compile instead), the T-Head/Xuantie riscv64 vendor toolchain (mirrored, see below), the Arm GNU
toolchain, and the FreeBSD/OpenBSD sysroots. Safe to re-run — already-present components are
skipped. Run with no arguments for everything, name specific components
(`fetch-toolchains.sh freebsd openbsd`), or `fetch-toolchains.sh list` to report status without
fetching. It does **not** install the apt prerequisites below (a `sudo` step, left manual). `osxcross`
(part of the default run, or `fetch-toolchains.sh osxcross`) clones and builds osxcross, but the
macOS SDK is Apple-licensed and must be supplied locally — see BUILD.md's macOS section for the
three accepted sources. Without one the default run reports it as SKIPPED; naming it explicitly
makes that a failure.

It also symlinks the two OpenWrt toolchains the *agent's own* cross-compile needs (`ARCHID=28`/
`40`) into `../ToolChains/` — `fetch-toolchains.sh` lives at the repo root rather than under
`openssl/` for exactly this reason: `$BUILDROOT` serves the agent build too, not just OpenSSL.

### Host prerequisites (apt, Debian/Ubuntu)

```
gcc gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi gcc-arm-linux-gnueabihf \
gcc-mips-linux-gnu gcc-mipsel-linux-gnu gcc-riscv64-linux-gnu \
libc6-dev-i386 lib32gcc-14-dev musl-tools clang lld make curl tar xz-utils zstd
```

Used directly by name (`aarch64-linux-gnu-gcc`, `gcc -m32`, `musl-gcc`, `clang`, ...) — no
`$BUILDROOT` entry needed for them. `curl`/`tar`/`xz`/`zstd` are what `fetch-toolchains.sh` itself
needs to fetch and extract toolchains.

Not `gcc-multilib`: on Debian trixie / Ubuntu 24.10+, its `gcc-14-multilib` dependency carries a
blanket `Conflicts:` against every `gcc-14-<target>-linux-gnu` cross package. `libc6-dev-i386` +
`lib32gcc-14-dev` give `gcc -m32` the same 32-bit runtime without the metapackage-level conflict.

### `$BUILDROOT` layout

```
$BUILDROOT/
  downloads/                       openssl-1.1.1w.tar.gz (sha256-verified)
  sysroots/
    freebsd-14.3/                  FreeBSD base sysroot (clang cross)
    openbsd-7.9/                   OpenBSD base sysroot (clang cross)
  toolchains/
    openwrt-sdk-24.10.8-*_musl.Linux-x86_64/    mips24kc, mipsel24kc, openwrt_x86_64
    aarch64-linux-musl-cross/                   aarch64-cortex-a53 (musl.cc, NOT dd-wrt anymore)
    arm-linux-musleabihf-cross/                 linux-armada370-hf (musl.cc)
    x86_64-linux-musl-cross/                    alpine-x86-64 (musl.cc)
    riscv64-linux-musl-cross/                   riscv64 (musl.cc)
    riscv64-linux-musl-xthead/                  T-Head/Xuantie vendor toolchain (mirrored, agent ARCHID=45)
    mips32el--uclibc--stable-<rel>/             mips/mipsel-family uClibc (Bootlin)
    <family>--glibc--stable-<rel>/              armv5-eabi, armv7-eabihf, aarch64, x86-i686, x86-64-core-i7 (Bootlin, pinned)
  src/                              (optional) extracted OpenSSL reference source, informational
  work/                             scratch build trees per target - safe to delete, recreated on demand
```

The musl.cc entries above replaced an older dd-wrt-archive toolchain set (`toolchain-
aarch64_cortex-a53_gcc-*_musl`, etc.) — `fetch-toolchains.sh` has no dd-wrt fetch logic anymore;
if you find a comment or note anywhere still saying "dd-wrt-archive toolchain" for
aarch64-cortex-a53 or linux-armada370-hf, it's stale.

### Sources, since none of these have one unified fetcher

- **OpenSSL tarball**: fetched+verified against openssl.org's own `<tarball>.sha256` sidecar.
- **OpenWrt SDKs** (mips24kc/mipsel24kc/openwrt_x86_64): OpenWrt's own release downloads. No
  per-tarball checksum published — verified by toolchain smoke-test instead.
- **Bootlin toolchains** (armv5/armv7hf/aarch64 glibc, mips32el uClibc): toolchains.bootlin.com,
  checksum-verified (Bootlin does publish a per-tarball `.sha256`).
- **musl.cc toolchains** (aarch64, armhf, x86_64, riscv64): musl.cc, no published checksum, gated
  on a smoke compile.
- **T-Head/Xuantie riscv64 vendor toolchain** (`riscv64-linux-musl-xthead`): no public
  upstream URL at all (the XuanTie GNU toolchain repo ships source only; a prebuilt needs their
  account-gated OCC portal at xrvm.cn). Built from source once (2026-08-24, `xuantie-gnu-toolchain`
  V3.0.1, `make musl`) and mirrored at `PTR-inc/meshagent-toolchains/TC` — fetched via
  `./fetch-toolchains.sh riscv64-xthead`. If that mirror ever goes away, rebuilding from source
  needs ~20 apt build packages, a ~6.65GB submodule pull, and 45-90+ minutes.
- **Arm GNU Toolchain**: developer.arm.com's official releases. Currently unused by any target
  (kept in case a future target needs a toolchain apt doesn't provide).
- **FreeBSD/OpenBSD sysroots**: `usr/include` + `usr/lib` subset of each project's official
  release `.txz`/`.tgz`, not a full OS install.

### Verifying a fresh provision

```sh
. build-env.sh
br_check              # every listed path present?
build.sh riscv64       # one target, full build+verify+stage cycle
```

## The riscv64 ASYNC/ucontext bug (2026-08-24) — read before touching a musl target

`openssl/libstatic/linux/riscv64` was built glibc (`riscv64-linux-gnu-gcc`) via `targets.sh` while
the makefile's ARCHID=45/145 both consume that directory as a **musl** target — a real mismatch,
not a one-off contamination. The concrete symptom: linking an agent against it failed with
`undefined reference to getcontext/setcontext/makecontext`, because OpenSSL's
`crypto/async/arch/async_posix.h` only compiles in `ASYNC_POSIX` support when `defined(__GLIBC__)`
— which a real musl build should never define, but this archive did, because it was actually
compiled with glibc. musl implements `ucontext.h` on **no** architecture (checked musl's own
source tree directly — only `src/setjmp/`, nothing ucontext-shaped anywhere), so any musl archive
that *does* pull in `ASYNC_POSIX` will fail to link an agent, silently, until someone actually
tries.

This went undetected because nothing had ever linked a real agent against that archive —
the old `state.txt` even said so explicitly ("staged via the buildroot, not independently
run-tested").
`verify`'s pre-existing `GLIBC` column had actually already caught it (nonzero, violating its
own documented rule) but the finding wasn't acted on before staging.

Fixed 2026-08-24, three parts:
1. `targets.sh`'s `riscv64` case now builds with `$TC_RISCV64_MUSL` (musl.cc), matching what
   ARCHID=45/145 actually need. A separate `riscv64-generic` case (apt glibc) was added for the
   previously-ad-hoc glibc build, tracked properly instead of being built outside this script.
2. `flags.txt` gained `no-async` globally — MeshAgent never calls `ASYNC_*` anywhere in its own
   code, and `no-engine` (already set) precludes the only thing that would ever call it (a
   hardware-offload engine). Zero functional impact on any target, any libc.
3. `verify` gained a `UCONTEXT` column specifically checking for
   `getcontext`/`setcontext`/`makecontext`/`swapcontext` references, since they aren't covered by
   `GLIBC_ONLY_RE` (they're POSIX-named, not glibc-exclusive by name — musl just never implements
   them). **Must be 0 for musl targets** (riscv64, alpine-x86-64, `*24kc`, openwrt_x86_64,
   aarch64-cortex-a53, linux-armada370-hf). **NOT** required to be 0 for mips/mipsel — those are
   uClibc, and uClibc's own libc genuinely does implement `getcontext`/`setcontext`/`makecontext`
   (confirmed via `nm` on the real uClibc `libc.so`), so nonzero there is fine.

`libucontext` (github.com/kaniini/libucontext, ISC license, riscv64 tier-1/CI-tested, explicitly
musl-targeted) was evaluated as an alternative that would let `ASYNC_POSIX` actually work on musl
instead of disabling it — rejected as unnecessary integration effort (a separate static lib per
target, forever) for a feature nothing in this codebase calls.

See [[meshagent-static-musl-direction]] (`~/.claude/docs/`) for the fuller writeup.

## CI sources `targets.sh` directly (2026-08-24)

`.github/workflows/openssl-linux-cross.yml` (since deleted, see below) used to carry its own hand-written `matrix.include`
duplicating every target's Configure target, compiler/toolchain, asm flag, and extra flags — the
exact copy that drifted from `targets.sh` for riscv64 (see above) and, less severely, was missing
`targets.sh`'s x86-64 `-march`/`-mtune` fix (`openssl-linux-native.yml`, also fixed 2026-08-24).
Rather than adding a drift-detection script to catch this class of bug after the fact, the
duplication itself was eliminated:

- `targets.sh` gained a `T_FETCH` field per target (initially only for the 10 targets that
  workflow built; now populated for every target) naming the exact
  `fetch-toolchains.sh` component (`bootlin-aarch64`, `muslcc-riscv64`, ...) or an apt package
  (`apt:gcc-arm-linux-gnueabihf`) needed to provision that target's toolchain.
- The workflow's `matrix` is now just a flat list of target names
  (`dir: [aarch64, arm64, ..., riscv64]`) — pure curation of *which* targets this workflow builds
  (vs. the OpenWrt/BSD/musl/macOS/Windows workflows), not *how*.
- A "Resolve target from targets.sh" step sources `build-env.sh`+`targets.sh`, calls `br_target
  "$dir"`, and exports `T_CONF`/`T_CC`/`T_FLAGS`/`T_EXTRA`/`T_OBJS`/`T_FETCH` via `$GITHUB_ENV`
  for later steps. `BUILDROOT` is set to a runner-local dir at job level, so `T_CC`'s
  `$TC_*`-based paths resolve to wherever the toolchain-install step actually put it — same
  `$BUILDROOT`-relative convention `targets.sh`/`build-env.sh` already use everywhere else, no
  CI-specific path translation needed.
- Toolchain install branches on `T_FETCH`: `apt:*` → `apt-get install`, anything else →
  `./fetch-toolchains.sh "$T_FETCH"` (the exact same mirror-with-fallback fetcher every local dev
  machine uses — no more separately-maintained inline `curl`/`tar` steps per toolchain family).
- Build/verify/asm-check steps use `$T_CONF`/`$T_FLAGS`/`$T_EXTRA`/`$T_OBJS`/`$T_ASM`
  (derived from whether `$T_FLAGS` still contains `-no-asm`) instead of `matrix.*` fields.

Verified end-to-end locally before landing: resolved all 10 targets via `br_target` (values match
the old hand-written matrix exactly), and ran the full Configure→build→object-count→version
pipeline for `riscv64` through the new logic (553 objects, `OpenSSL 1.1.1w`, matches `T_OBJS`).

**Migration completed 2026-08-24 (second pass).** The remaining seven workflows
(`openssl-linux-native.yml`, `openssl-linux-musl.yml`, `openssl-openwrt-mips.yml`,
`openssl-openwrt-x86_64.yml`, `openssl-armada370-hf.yml`, `openssl-bsd.yml`, `openssl-macos.yml`)
and `openssl-linux-cross.yml` itself are all **deleted**. One dispatcher,
`.github/workflows/build-openssl-job.yml`, now drives everything:

- Its matrices are *generated*: `targets.sh --names linux` / `--names macos` (from the new `T_CI`
  field), and for Windows, a grep of `windows/build.ps1`'s own `$Targets`. Adding a target to
  `BR_ALL_TARGETS` puts it in CI with no YAML edit; `consistency.sh` check 4 fails if some target
  ends up in no matrix.
- The build itself is `.github/actions/openssl-build-target` — one composite action shared by the
  linux and macos jobs — which just runs `build.sh`. The skip-check, version gate, object-count
  gate and libc symbol gates are `build.sh`'s, not the workflow's. Windows likewise calls
  `build.ps1`, which already carried the same contract.
- Provisioning is `BR_FETCH=1`, which makes `build.sh` act on the target's own `T_FETCH` tokens
  (now populated for every target, and accepting several whitespace-separated tokens, e.g.
  `apt:clang apt:lld freebsd`). No toolchain-install step exists in YAML any more.
- macOS builds through the same `build.sh`: `targets.sh` selects the runner's native
  clang/ar/ranlib/nm on Darwin and osxcross's prefixed ones only when cross-building from Linux.
- `T_MAKE` is now `build_libs` for *every* target. Previously only bsd/macos set it, so a local
  `build.sh` linked `apps/` while every workflow did not — one of several behaviours that differed
  between a developer's machine and CI. The blanket `sed -i 's/ -O3 / -Os /g'` five workflows
  applied is likewise gone: `-Os` is a per-target `T_EXTRA` decision, and `targets.sh` documents
  which targets deliberately do *not* take it.

Verified with `act` (local GitHub Actions runner) before landing: `build-system-checks.yml` in
full, both `resolve` jobs, and one complete `linux` job (`alpine-x86-64`) end to end in a clean
container with an empty `$BUILDROOT`.

## Per-target status

Target version for every archive below: **OpenSSL 1.1.1w** (11 Sep 2023, the last public 1.1.1
release — sha256 `cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8`, fetched via
`./linux/fetch-openssl`). 1.1.1 is end-of-life and receives no further public fixes; 1.1.1w is an
interim step closing the CVEs published while it was still supported — migration to 3.5 LTS is
tracked separately. Exceptions: `linux/poky` and `linux/poky64` are still unbuilt at 1.1.1i (see
below).

Verified by inspecting the version string in each committed `libcrypto.a`
(`strings libcrypto.a | grep "OpenSSL 1."`) and the object count (`ar t libcrypto.a | wc -l`).
**Keep this table honest — a stale claim here is worse than none.**

Flag reasoning that applies across the whole table (per-target overrides are in `targets.sh`):
- **asm** is enabled (no `-no-asm`) wherever OpenSSL has a per-arch `Configure` target with genuine
  runtime capability-gated asm: the x86/x86-64 family (CPUID → `OPENSSL_ia32cap_P`: x86-64, x86,
  alpine-x86-64, openwrt_x86_64, freebsd, openbsd) and AArch64 (`getauxval(AT_HWCAP)` →
  `crypto/armcap.c`: arm64, aarch64, aarch64-cortex-a53). 32-bit ARM (`linux-armv4`: armhf, armhf2,
  linux-armada370-hf) is **deliberately left at `-no-asm`** — asm produced WRONG crypto results
  under qemu-arm (non-deterministic SHA-384/512 hashes, `RSA.verify()` rejecting its own fresh
  signature); reverting to `-no-asm` did **not** fix it, so the bug is unrelated to asm itself,
  unresolved, HIGH severity — **do not trust any RSA or SHA-384/512 operation on these three
  targets, asm or not.** Everything Configured as `linux-generic32`/`linux-generic64` (arm,
  arm-linaro, pogo, poky, poky64) has no asm modules to enable regardless of the flag. MIPS
  (`mips`/`mipsel`, `linux-mips32`) has no runtime capability fallback — asm compiles in
  unconditionally for the Configure-time ISA, only trusted here after a real crypto run.
- Every 64-bit `Configure` target gets `enable-ec_nistp_64_gcc_128` (faster P-256 ECC via native
  128-bit ints); it doesn't add a separate object file.
- `-Os` is applied only to genuinely IoT/router/flash-space-constrained targets, not simply
  "everything cross-compiled" — general-purpose 64-bit targets that happen to be built
  cross/emulated but aren't actually space-constrained (arm64, alpine-x86-64, freebsd, openbsd)
  favor speed instead, same as x86-64/x86.

### Run-tested (build+link+run, correct crypto results confirmed)

| target | objs | notes |
|---|---|---|
| `linux/x86-64` | 576 | No `-Os` (native, favors speed). AES-NI/SHA-NI/bignum asm. |
| `linux/x86` | 566 | No `-Os`. `gcc -m32` native i386 multilib. aesni-x86/sha1-586/sha256-586/x86cpuid present. |
| `linux/arm64` | 564 | No `-Os` (general-purpose glibc ARM64, ARCHID=26). asm ENABLED (aesv8-armx, sha1-256-512-armv8, ghashv8-armx, chacha-armv8, poly1305-armv8, armcap). Ran clean under qemu-aarch64 through the full OpenSSL/IO stress-test. Needs a makefile `INCDIRS` entry for jpeg headers (KVM=1 → `linux_kvm.c` → `jpeglib.h` → `jconfig.h`) via the repo's vendored `lib-jpeg-turbo/includes/`. |
| `linux/mips` + `linux/mipsel` | 556 | musl (`toolchain-mipsel_mips32_gcc-13.1.0_musl`), `linux-mips32`, asm ENABLED, `-Os`. Byte-identical, one build staged to both dirs. `meshagent_mips` (ARCHID=7) under qemu-mipsel: 12-cycle × 120-key `ILibSimpleDataStore` stress test clean, 0 SIGBUS; `apps/openssl speed aes-128-cbc sha256` clean with correct throughput. |

### Staged via `build.sh` (version+object-count+glibc-symbol checks passed, no qemu agent run)

| target | objs | `-Os` | notes |
|---|---|---|---|
| `linux/aarch64` | 564 | yes | ARCHID=32-equivalent, legacy-ABI arm64 embedded compat — same toolchain/Configure/object-count as `arm64` above, just a lower glibc floor. |
| `linux/aarch64-cortex-a53` | 564 | yes | Router/AP chip class, genuinely restricted-space. musl (musl.cc `aarch64-linux-musl-cross`, **not** dd-wrt — see above). ARCHID=41. |
| `linux/alpine-x86-64` | 576 | no | General-purpose container/server distro, not IoT/router. musl. |
| `linux/openwrt_x86_64` | 576 | yes | OpenWrt is router firmware by definition regardless of the x86-64 CPU. musl (OpenWrt 18.06.9 SDK). |
| `bsd/freebsd_x86-64` | 576 | no | General-purpose server/desktop OS. clang cross + FreeBSD 14.3 sysroot. |
| `bsd/openbsd_x86-64` | 576 | no | Same reasoning as FreeBSD. clang cross + OpenBSD 7.9 sysroot, `build_libs` only (CLI needs crt objects MeshAgent doesn't use). |
| `macos/osx-arm-64` | 565 | no | General-purpose macOS. osxcross clang cross (SDK 26.5, `darwin64-arm64-cc`), `build_libs` only. `meshagent_osx-arm-64` (ARCHID=29) links clean. |
| `macos/osx-x86-64` | 577 | no | Same reasoning. osxcross clang cross (`darwin64-x86_64-cc`), `build_libs` only. `meshagent_osx-x86-64` (ARCHID=16) links clean. |

### `-no-asm` embedded/router/SBC targets — all genuinely flash/space-constrained, all `-Os`

| target | objs | notes |
|---|---|---|
| `linux/armhf` | 553 | Raspberry Pi (ARCHID=25) — glibc, ARMv6+VFPv2 hardfloat. **DO NOT TRUST RSA/SHA-384/512.** `linux/armhf2` is a **symlink** to this directory, not a separate build: ARCHID=27 ("Raspbian 7 2015" Pi1 target) used a different, now-gone/unreproducible toolchain; its replacement built byte-identical OpenSSL output to armhf, so the two were consolidated (see `targets.sh`). ARCHID=27 is still a distinct *agent* build (KVM=0 vs KVM=1) — it just links this same archive now. |
| `linux/linux-armada370-hf` | 553 | NAS/plug-computer/router SoC (ARCHID=35) — musl, static, generic ARMv7 Cortex-A9 build (will **not** run on a real Synology DSM glibc target). Same `linux-armv4` Configure as armhf — same RSA/SHA-384/512 caution applies. |
| `linux/arm` | 553 | ARCHID=9 "Official Linux ARM" — glibc, `linux-generic32` (no asm regardless). Makefile's `PATH_ARM5` naming and `ILIBCHAIN_GLOBAL_LOCK` grouping (shared only with MIPS/Pogo) mark this ARMv5-class. |
| `linux/arm-linaro` | 553 | Industrial/embedded ARMv7 gear, 2012-2016 generation (ARCHID=24) — glibc hardfloat, apt `arm-linux-gnueabihf-gcc`. `linux-generic32`. |
| `linux/pogo` | 553 | PogoPlug NAS/plug computer (ARCHID=13) — glibc, apt `arm-linux-gnueabi-gcc` (no "hf" — softfloat), matching real ARMv5TE softfloat PogoPlug hardware. A hardfloat toolchain here would silently produce a binary that doesn't run on real hardware. `linux-generic32`. |
| `linux/mips24kc` | 553 | Classic OpenWrt router SoC family (ARCHID=28) — musl (OpenWrt ar71xx SDK). |
| `linux/mipsel24kc` | 553 | Same family (ARCHID=40) — musl (OpenWrt ramips-mt7621 SDK). |

### RISC-V64 — rebuilt 2026-08-24, see "The riscv64 ASYNC/ucontext bug" above

| target | objs | notes |
|---|---|---|
| `linux/riscv64` | 553 | `-Os`, no asm (1.1.1 has none for RISC-V), `enable-ec_nistp_64_gcc_128`, `no-async`. musl (musl.cc `riscv64-linux-musl-cross` via `$TC_RISCV64_MUSL` — same toolchain family agent ARCHID=145 uses), `linux64-riscv64`, `-march=rv64gc -mabi=lp64d`. Backs agent ARCHID=45 (T-Head/Xuantie vendor musl, `-mcpu=c906fdv`) and ARCHID=145 (generic musl, static). Build+link+stage verified 2026-08-24: both `meshagent_riscv64` and `meshagent_riscv64-generic-musl` link clean with 0 undefined references; **neither has been run yet** (no qemu-riscv64 execution attempted). |
| `linux/riscv64-generic` | 553 | `-Os`, no asm, `enable-ec_nistp_64_gcc_128`. Genuinely separate target, glibc, no vendor extensions — **not currently consumed by any makefile ARCHID** (an older note here referred to "ARCHID=46"; no such ARCHID exists in the current makefile post-refactor, commit `a4ce0e3` — a generic-glibc riscv64 agent target would need a new ARCHID wired up). Built via apt `riscv64-linux-gnu-gcc`, `-march=rv64gc -mabi=lp64d`, `Configure linux-generic64`, now tracked in `targets.sh` (previously ad-hoc). `meshagent_riscv64-generic` ran under plain qemu-riscv64 (`-agentHash` succeeded) prior to the refactor, 0 `.insn` custom opcodes. `.github/workflows/build-openssl-libs.yml`'s linux-cross matrix has a matching row that hasn't actually been run yet — this archive is still the local build. |

### Not built

| target | status |
|---|---|
| `linux/poky` | 1.1.1i, unbuilt. Intel Galileo/Quark X1000, EOL since 2016 — no current SDK targets it. |
| `linux/poky64` | 1.1.1i, unbuilt. No ARCHID references this directory at all — orphaned. |

Not tracked in this table (Windows `.lib` files under `libstatic/windows/`): `32MT` / `32MTd` /
`64MT` / `64MTd` / `ARM64MT` / `ARM64MTd` — see "Windows build" above.

**Do not trust RSA or SHA-384/512 on `armhf`/`armhf2`/`linux-armada370-hf`** — a real, unresolved,
asm-unrelated bug (see above). This is the one correctness caveat that applies regardless of
anything else in this table.

## Windows build (native, PowerShell)

Native-Windows sibling of this directory's WSL/Linux buildroot, living in `windows/`. MSVC's
`Configure` and `nmake` need a real MSVC developer environment, not Git Bash, so this is
PowerShell, not the bash scripts above. `build-openssl-job.yml`'s `windows` job calls `build.ps1` directly: same
`Configure` targets, same shared [`flags.txt`](flags.txt) flags, NASM-enabled asm for x86/x64
only, and the same post-`Configure` `/MD`→`/MT` makefile patch for a static CRT. If the workflow
and these scripts ever disagree, treat the workflow as authoritative and fix these scripts to
match.

### Quick start

```powershell
. openssl\libstatic\build\windows\env.ps1
Test-BuildRootWindows                          # confirms VS/perl/nasm/tarball are all present
Install-BuildRootWindows                       # fetches whatever that reported missing

openssl\libstatic\build\windows\build.ps1 x64
openssl\libstatic\build\windows\build.ps1 all
openssl\libstatic\build\windows\verify.ps1      # read-only report over whatever's already staged
```

### Prerequisites

`Install-BuildRootWindows` provisions everything below except the MSVC toolsets. A bare call does
the three that need no admin rights - source tarball, perl and NASM - each pinned to a fixed
version, URL and SHA-256 and unpacked under `$BUILDROOT\tools`. Nothing is installed system-wide,
put on `PATH`, or written outside `$BUILDROOT`, so undoing it is `Remove-Item -Recurse $BUILDROOT`.

```powershell
Install-BuildRootWindows                       # tarball + perl + nasm
Install-BuildRootWindows -Nasm                 # just one of them
Install-BuildRootWindows -Force                # re-fetch and re-unpack even if present
Install-BuildRootWindows -VsComponents         # adds the missing MSVC components - prompts, needs admin
Install-BuildRootWindows -BuildRoot D:\br      # somewhere other than the default
```

It asks where to put the buildroot before writing anything, defaulting to the current `$BUILDROOT`
(under the user profile unless overridden) - press Enter to take it. A typed path may be relative
or contain `%VARS%`/`~`; it is expanded and made absolute. `-BuildRoot` answers the question up
front, and `-Force` or a non-interactive session takes the default without asking. The answer
applies to that session only: set `$env:BUILDROOT` before dot-sourcing `env.ps1` to make it stick.

`-VsComponents` is never implied by a bare call: it shells out to the Visual Studio installer
elevated, so it asks first and prints the exact `setup.exe modify` command it intends to run. That
command uses `--passive --norestart`, so the installer shows progress and proceeds without further
interaction (`--norestart` alone is rejected - the installer answers with its usage dialog). It
adds only what is missing, so re-running it is a no-op rather than another trip through the
installer, and because setup.exe can exit before its child finishes, a toolset that is not visible
immediately afterwards means "not done yet" rather than a failed install. Component ids come from
the installer's own catalog of what the product offers, which lists them whether or not they are
installed - so this still works when the C++ workload has been removed outright, which is exactly
when it is needed. In a non-interactive session it prints the command and stops rather than
elevating unasked; pass `-Force` to skip the prompt.

- Visual Studio with the **C++ x64/x86 build tools** component (required), and the **C++ ARM64
  build tools** (only if building the `arm64`/`arm64-debug` targets). On VS 2022 these are named
  *MSVC v143 - VS 2022 C++ x64/x86 build tools* and *... ARM64 build tools*.
  `Test-BuildRootWindows` reports the toolset version it picked for each target.
- A **Windows SDK** component. The `C++ ... build tools` components do *not* include one, and an
  install without it gets a working `cl.exe` that then fails on `Cannot open include file:
  'stdlib.h'`. `Test-BuildRootWindows` checks for it per target.
- VS 2017-2022 and VS 2026 (v18) are both supported. `env.ps1` handles the differences: it drives
  `vcvarsall.bat` when present and falls back to `Common7\Tools\VsDevCmd.bat` when it is not (seen
  on a v18 install carrying only versioned v143 toolset packages), matches the vswhere component id
  whether or not it is version-stamped, and pins every target to a toolset verified complete on
  disk (`-vcvars_ver`) rather than trusting the default, which has pointed at a compiler-less
  toolset folder.
- `perl.exe` on `PATH` - Git for Windows ships one (`C:\Program Files\Git\usr\bin\perl.exe`);
  Strawberry Perl (what CI uses, via `choco install strawberryperl`) also works.
- NASM, for asm-enabled x86/x64 builds (AES-NI/SHA-NI/bignum throughput). Without it, `build.ps1`
  falls back to `-no-asm` for those targets automatically. Install with `choco install nasm` or
  from <https://www.nasm.us/> - `Get-NasmPath` in `env.ps1` checks `PATH`, then
  `%LOCALAPPDATA%\bin\NASM\nasm.exe` (the non-elevated chocolatey install location).
- ARM64 targets cross-compile from an x64 host (`x64_arm64`) - no ARM64 machine needed.

### What gets staged, and where

Six targets, matching the twelve `.lib` files already committed under `openssl/libstatic/windows/`
- the `.vcxproj` files reference them there directly, e.g.
`..\openssl\libstatic\windows\libcrypto64MT.lib`, and this script keeps that path unchanged):

| target | `Configure` | asm | stages to |
|---|---|---|---|
| `x86` | `VC-WIN32` | on (NASM) | `libcrypto32MT.lib` / `libssl32MT.lib` |
| `x86-debug` | `VC-WIN32 --debug` | on (NASM) | `libcrypto32MTd.lib` / `libssl32MTd.lib` |
| `x64` | `VC-WIN64A` | on (NASM) | `libcrypto64MT.lib` / `libssl64MT.lib` |
| `x64-debug` | `VC-WIN64A --debug` | on (NASM) | `libcrypto64MTd.lib` / `libssl64MTd.lib` |
| `arm64` | `VC-WIN64-ARM` | off | `libcryptoARM64MT.lib` / `libsslARM64MT.lib` |
| `arm64-debug` | `VC-WIN64-ARM --debug` | off | `libcryptoARM64MTd.lib` / `libsslARM64MTd.lib` |

Nothing is staged unless it passes: the OpenSSL version string must be found in the built
`libcrypto.lib` (`OpenSSL 1.1.1w `), and the object count from `lib /list` must match the `ObjCount`
recorded per target in `build.ps1` (566 x86, 576 x64, 553 arm64 - Release and Debug match). Not
tracked in the "Per-target status" table below (Windows `.lib` files under
`libstatic/windows/`): `32MT` / `32MTd` / `64MT` / `64MTd` / `ARM64MT` / `ARM64MTd`.

## Rebuilding

- **CI**: `.github/workflows/build-openssl-libs.yml` (`workflow_dispatch`) builds every target
  reachable from GitHub runners and uploads them staged in this repo's directory layout.
- **Manual, path 1** (portable, glibc-only): `./linux/fetch-openssl`, then run the matching
  `openssl-<arch>` script from inside the extracted source directory.
- **Manual, path 2** (musl/uClibc/BSD/macOS, any machine with `$BUILDROOT` provisioned):
  `./fetch-toolchains.sh` once, then `openssl/libstatic/build/build.sh <target|all>`. `REPO` is
  auto-derived from the script's own location (override with `REPO=...` to stage into a different
  checkout). Before running `build.sh all` (or any target whose `targets.sh` entry doesn't
  obviously match this repo's own `openssl-<arch>` recipe for the same directory), diff the two —
  a mismatched `Configure` target or missing asm override will silently overwrite a better archive
  with a worse one.
- **Windows**: see "Windows build" above.
