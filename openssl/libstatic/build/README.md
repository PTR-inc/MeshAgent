# OpenSSL cross-compile buildroot scripts (vendored)

Portable, git-tracked scripts to rebuild every `openssl/libstatic/**` static archive this repo
ships, without leaving the WSL filesystem and without depending on any one machine's ad-hoc setup.
Originally developed and iterated on as an external buildroot at `/opt/build`, then vendored here
(2026-08-18) so the scripts themselves travel with every clone — only the large toolchain/sysroot
data stays external, at `$BUILDROOT` (see below).

## Two things, deliberately kept separate

1. **This directory** (`openssl/libstatic/build/`) — the OpenSSL-archive build scripts themselves
   (`env.sh`/`targets.sh`/`build.sh`/`verify.sh`). Tracked in git, travels with the repo. The
   fetcher, `fetch-toolchains.sh`, lives one level up at the repo root instead — it provisions
   `$BUILDROOT` for more than just this directory (see "Provisioning" below).
2. **`$BUILDROOT`** (default `/opt/buildroot`) — toolchains, sysroots, downloaded source tarballs,
   and scratch build trees. Multi-gigabyte, **not** in the repo (mix of large-but-reproducible and
   genuinely non-redistributable inputs — see below). Provision this once per machine; every
   checkout on that machine shares it by default.

## Quick start

```sh
./fetch-toolchains.sh               # fresh machine: download+verify+extract everything fetchable
. openssl/libstatic/build/env.sh       # sets REPO (derived from this script's location) and BUILDROOT
br_check                                # confirms every toolchain/sysroot/source is present
openssl/libstatic/build/build.sh riscv64
openssl/libstatic/build/build.sh all
openssl/libstatic/build/verify.sh       # read-only report over whatever's already staged
```

`fetch-toolchains.sh` lives at the repo root, not under `openssl/`, on purpose: `$BUILDROOT`'s
toolchains aren't only for OpenSSL archives - the makefile cross-compiles the *agent* against a
couple of the same OpenWrt SDK toolchains (`ARCHID=28`/`40`, `PATH_MIPS24KC`/`PATH_MIPSEL24KC`),
and provisioning symlinks those into `../ToolChains/` (the makefile's own expected location) after
fetching them. See the script's own header comment for exactly which toolchains are wired and why
the rest deliberately aren't (name/version mismatches, or no fetchable source at all).

Override the buildroot location if you keep it somewhere other than `/opt/buildroot`:

```sh
BUILDROOT=/somewhere/else . openssl/libstatic/build/env.sh
```

### Building targets concurrently

`build.sh` builds one target at a time by default (`BR_JOBS=1`) - the same behavior as before
concurrency was added. Set `BR_JOBS` to build that many targets at once:

```sh
BR_JOBS=4 openssl/libstatic/build/build.sh all
```

Each target's own `make -j` still wants multiple cores, so raising `BR_JOBS` splits the host's
cores across the concurrent slots (`MAKE_JOBS = nproc / BR_JOBS`) instead of every slot
independently claiming `make -j$(nproc)` and oversubscribing the machine `BR_JOBS`-fold. Override
`MAKE_JOBS` directly if you want a different split (e.g. a few large-`T_OBJS` targets alongside
many small ones). Per-target output and pass/fail status are buffered per target and replayed in
the order you listed the targets, so a `BR_JOBS>1` run reads the same as a sequential one, just
faster on a multi-core box.

## Provisioning `$BUILDROOT` on a fresh machine

`./fetch-toolchains.sh` (repo root) automates everything below that has a public URL: the
OpenSSL tarball, the 3 OpenWrt 18.06.9 SDKs, the 2 bootlin toolchains (checksum-verified -
bootlin does publish a per-tarball `.sha256`, despite the "no stable checksum" note below), the Arm
GNU toolchain, the FreeBSD/OpenBSD sysroots (checksum-verified against each project's own release
manifest), and dd-wrt's toolchain archive (one 4.2GB tar.xz with every current dd-wrt toolchain -
no published checksum; the download server aborts mid-transfer often, so the fetch resumes rather
than restarting). Safe to re-run - already-present components are skipped. Run it with no
arguments for everything, or name specific components (`fetch-toolchains.sh freebsd openbsd`);
`fetch-toolchains.sh list` reports status without fetching anything. It also symlinks the two
OpenWrt toolchains the makefile itself needs (`ARCHID=28`/`40`) into `../ToolChains/` - see "Two
things" above.

It does NOT install the apt prerequisites below (a `sudo` step, left manual on purpose), and it
cannot fetch osxcross - that has no stable public URL at all (see "Sources" below). It prints
exactly what's still missing and how to get it at the end of every run.

### Host prerequisites (apt, Debian/Ubuntu)

```
gcc gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi gcc-arm-linux-gnueabihf \
gcc-mips-linux-gnu gcc-mipsel-linux-gnu gcc-riscv64-linux-gnu \
libc6-dev-i386 lib32gcc-14-dev musl-tools clang lld make curl tar xz-utils
```

These are used directly by name (`aarch64-linux-gnu-gcc`, `arm-linux-gnueabi-gcc`,
`arm-linux-gnueabihf-gcc`, `gcc -m32`, `musl-gcc`, `clang`) — no `$BUILDROOT` entry needed for them.
`curl`/`tar`/`xz` are what `fetch-toolchains.sh` itself needs to fetch and extract
toolchains; it checks for them upfront and prints this same list if any are missing.

Note: not `gcc-multilib`. On Debian trixie / Ubuntu 24.10+, `gcc-multilib`'s
`gcc-14-multilib` dependency carries a blanket `Conflicts:` against every
`gcc-14-<target>-linux-gnu` cross package (it's really just a dummy package
depending on `gcc-14`, `libc6-dev-i386` and `lib32gcc-14-dev` — see
`apt-cache show gcc-14-multilib`). Installing those two packages directly
gives `gcc -m32` the same 32-bit runtime without the metapackage-level
conflict, so it coexists fine with the cross compilers above.

### `$BUILDROOT` layout

```
$BUILDROOT/
  downloads/                       openssl-1.1.1w.tar.gz (sha256-verified, see env.sh)
  sysroots/
    freebsd-14.3/                  FreeBSD 14.3 base sysroot (for the `freebsd` target, clang cross)
    openbsd-7.9/                   OpenBSD 7.9 base sysroot (for the `openbsd` target, clang cross)
  toolchains/
    openwrt-sdk-18.06.9-ar71xx-generic_gcc-7.3.0_musl.Linux-x86_64/       mips24kc
    openwrt-sdk-18.06.9-ramips-mt7621_gcc-7.3.0_musl.Linux-x86_64/        mipsel24kc
    openwrt-sdk-18.06.9-x86-64_gcc-7.3.0_musl.Linux-x86_64/               openwrt_x86_64
    mips32el--uclibc--stable-2025.08-1/                                  (kept, not used by default)
    toolchain-mipsel_mips32_gcc-13.1.0_musl/                             mips + mipsel
    riscv64-lp64d--musl--stable-2025.08-1/                                riscv64
    toolchain-aarch64_cortex-a53_gcc-15.2.0_musl/                        aarch64-cortex-a53
    toolchain-arm_cortex-a9_gcc-15.2.0_musl_eabi/                        linux-armada370-hf
    armgnu-15.2.rel1-arm-none-linux-gnueabihf/                           (unused - arm-linaro/pogo use
                                                                           apt toolchains instead)
  src/                              (optional) extracted OpenSSL reference source, informational only
  work/                             scratch build trees per target - safe to delete, recreated on demand
```

### Sources, since none of these have one unified fetcher

- **OpenSSL tarball**: the only piece with a real fetch+verify script — see `../linux/fetch-openssl`
  (same sha256 pin as `env.sh`'s `OPENSSL_SHA256`). Not duplicated here; `build.sh` expects it
  already downloaded to `$BR_DOWNLOADS` (copy it there, or symlink).
- **OpenWrt SDKs** (`mips24kc`/`mipsel24kc`/`openwrt_x86_64`): from OpenWrt's own archived
  downloads for 18.06.9. No per-tarball checksum published by OpenWrt for this old a release —
  verify by toolchain smoke-test (build a trivial static binary, run it under the matching
  `qemu-*`) rather than a hash.
- **bootlin toolchains** (`mips32el--uclibc`, `riscv64-lp64d--musl`): from bootlin's toolchain
  archive (toolchains.bootlin.com). Same caveat — no stable per-tarball checksum from bootlin
  either.
- **dd-wrt-archive toolchains** (`toolchain-mipsel_mips32_gcc-13.1.0_musl`,
  `toolchain-aarch64_cortex-a53_gcc-15.2.0_musl`, `toolchain-arm_cortex-a9_gcc-15.2.0_musl_eabi`):
  extracted from dd-wrt's own toolchain archive at
  `download1.dd-wrt.com/dd-wrtv2/downloads/toolchains/toolchains.tar.xz` (one 4.2GB tar.xz with
  every current dd-wrt toolchain). No published checksum; the server aborts mid-transfer often.
- **Arm GNU Toolchain** (`armgnu-15.2.rel1-arm-none-linux-gnueabihf`): downloaded from
  `developer.arm.com`'s official releases page (redirects through
  `armkeil.blob.core.windows.net`, confirming it's Arm's own distribution). Currently unused by any
  target (see table above) — kept in case a future target needs a toolchain apt doesn't provide.
- **FreeBSD/OpenBSD sysroots**: base system extracted from the respective project's official
  release `.txz`/`.tgz` sets, just the `usr/include` + `usr/lib` subset `Configure`/`clang` need to
  cross-compile against, not a full OS install.

### Verifying a fresh provision

```sh
. openssl/libstatic/build/env.sh
br_check            # every listed path present?
build.sh riscv64     # one target, full build+verify+stage cycle
```

`build.sh` itself is the real verification gate — it rejects (and stages nothing) on the wrong
OpenSSL version, wrong object count for that target, or (for musl/uClibc targets) any glibc-only
symbol reference. See `targets.sh` for the exact, current, per-target flag/toolchain list and the
reasoning behind each one — it is the single source of truth, this README is a map to get there, not
a duplicate of it.

## Relationship to `openssl/libstatic/linux/openssl-<arch>` scripts

Those 14 scripts remain — they're the older, glibc-apt-only, no-external-buildroot-dependency
reference path (portable to any bare Debian/Ubuntu box with nothing at `$BUILDROOT` at all, no clone
of this directory needed). This `build/` directory is additive: it covers everything those scripts
do, plus musl/uClibc OpenWrt targets, BSD cross-sysroots, and dd-wrt-archive toolchains those scripts
have no toolchain for. Where both exist for the same destination directory (`x86-64`, `x86`,
`arm64`, `armhf`, `arm`, `arm-linaro`, `pogo`), `targets.sh` is kept in sync with the
`openssl-<arch>` script's flags/toolchain choice deliberately — if you ever find them disagreeing,
treat the `openssl-<arch>` script as authoritative and fix `targets.sh` to match, not the other way
around (this has happened before).
