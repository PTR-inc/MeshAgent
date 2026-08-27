# OpenSSL static libraries: build system (vendored)

Everything under `openssl/` that builds, verifies or documents the static `libcrypto`/`libssl`
archives this repo ships. The archives are laid out as OpenSSL install prefixes, one per version
per target, and the agent build points at exactly one prefix at a time. `targets.sh` is the
source of truth for what compiles each target, `openssl/build/verify` is the ledger of what is
actually committed. This file explains the layout and the gates. `BUILD.md` at the repo root
routes, `ISSUES.md` records decisions and incidents.

## Map of `openssl/`

```
openssl/
  VERSION                         the one pin, "1.1.1w". build-env.sh, the makefile, env.ps1
                                  and MeshAgent.Common.props all read it, nothing restates it
  build/                          this directory
    README.md                     you are here
    targets.sh                    the target table: Configure target, compiler, flags, libc, CI
    build.sh                      builds one or more targets and installs their prefixes
    probe.sh                      the gates, shared by build.sh (before install) and verify
    verify                        read-only audit of every committed prefix, CI runs it
    consistency.sh                the anti-drift gate (see BUILD.md)
    archive-info.py               ar walker: format, wordsize, machine, member count, no binutils
    flags/1.1.1.txt               shared Configure flags for the 1.1.1 series (flags/3.txt later)
    xip-sdk-cpio.py               Xcode SDK extraction helper for osxcross
    windows/                      native Windows sibling (MSVC/nmake, PowerShell)
      env.ps1, build.ps1, toolset-check.ps1
  1.1.1w/                         one directory per installed OpenSSL version
    include/openssl/*.h           the 105 source headers from the tarball, no generated files
    linux-x86_64-glibc/           one install_dev prefix per target
      include/openssl/opensslconf.h   the generated header, per target because it encodes
                                      wordsize and the OPENSSL_NO_* option set
      lib/libcrypto.a  lib/libssl.a
      lib/pkgconfig/libcrypto.pc libssl.pc openssl.pc   prefix rewritten to ${pcfiledir}/../..
    windows-x64/                  same shape, lib/libcrypto.lib and lib/libssl.lib, no .pc
    ...                           24 prefixes in all, see the target table
  legacy/                         history only: the old openssl-<arch> scripts, compileall,
                                  deleteall, state.txt and the archive dirs nothing links any more
                                  (arm2, armhf2, poky, poky64, mips, pogo, arm64, openwrt_x86_64,
                                  riscv64). Nothing reads them, verify ignores them
build-env.sh                      repo root, sourced by every script here and by CI
fetch-toolchains.sh               repo root, provisions $BUILDROOT (see "Provisioning")
```

The consumer side is the makefile: every `ARCH_<id>` block carries `OSSLTARGET = <name>`,
`OSSLVER` defaults to `openssl/VERSION`, an `ARCH_` block may set `OSSLVER = 3.x.y` to pin that one
ARCHID to another installed series (a staged migration), and `make ARCHID=n OSSLVER=3.x.y` beats
both. The prefix is `openssl/$(OSSLVER)/$(OSSLTARGET)`, `make ARCHID=n print-osslver` shows the result.
Include order is `-I$(OSSLPREFIX)/include -Iopenssl/$(OSSLVER)/include`, so the per-target
`opensslconf.h` is found before the shared headers, and the link line is `-L$(OSSLPREFIX)/lib`.
`make ARCHID=n print-ossltarget` and `print-ossldir` show the resolution. On Windows
`MeshAgent.Common.props` reads `openssl\VERSION` and derives `MeshOpenSSLTarget` as
`windows-<x86|x64|arm64>[-debug]` from `$(Platform)` and `$(MeshDebug)`.

## Quick start

```sh
./fetch-toolchains.sh                  # fresh machine: download, verify and extract everything fetchable
. build-env.sh && br_check             # every toolchain, sysroot and tarball present?
openssl/build/build.sh list            # every target, its libc, toolchain readiness, ARCHIDs, prefix
openssl/build/build.sh linux-riscv64-musl
openssl/build/build.sh all             # every linux and macos target this host can build
openssl/build/verify                   # audit every committed prefix of every installed version
openssl/build/consistency.sh           # anti-drift gate
```

`BUILDROOT=/somewhere/else . build-env.sh` moves the multi-GB toolchain tree. `build.sh` builds
the listed targets one after another, gives each OpenSSL `make` every core (`MAKE_JOBS` to use
fewer), streams output and keeps a per-target log and one-line verdict under `$BR_WORK`.
Windows targets are refused by `build.sh`, `windows/build.ps1` builds them (see below).

## The target table

A target is named by what decides link compatibility, `<os>-<arch/abi>-<libc>`, never by a board
or a distribution. Two ARCHIDs that agree on those facts share one archive. `T_CONF` is the
OpenSSL Configure target, `T_LIBC` the only list of which targets are not glibc, `T_CI` the runner
family (`linux`, `macos`, `windows`). The Windows rows carry only name, Configure target and
libc, their MSVC details live in `build.ps1`'s `$Targets`.

| Target | T_CONF | Toolchain | libc | ARCHIDs | asm | -Os |
|---|---|---|---|---|---|---|
| `linux-x86_64-glibc` | linux-x86_64 | Bootlin x86-64 glibc 2.24 (2017.05), generic march (1) | glibc | 6, 20 | yes | no |
| `linux-i686-glibc` | linux-x86 | Bootlin x86-i686 glibc 2.24 (2017.05) | glibc | 5, 19 | yes | no |
| `linux-x86_64-musl` | linux-x86_64 | apt `musl-gcc` | musl | 33, 36 | yes | no |
| `linux-aarch64-glibc` | linux-aarch64 | Bootlin aarch64 glibc 2.31 | glibc | 26, 32 | yes | yes |
| `linux-aarch64-musl` | linux-aarch64 | musl.cc aarch64 | musl | 41 | yes | yes |
| `linux-armv6hf-glibc` | linux-armv4 | apt `arm-linux-gnueabihf-gcc`, armv6 VFP hardfloat (2) | glibc | 25 | no | yes |
| `linux-armv7hf-glibc` | linux-generic32 | Bootlin armv7-eabihf glibc 2.31 | glibc | 24 | none | yes |
| `linux-armv7hf-musl` | linux-armv4 | musl.cc armhf, armv7-a VFP hardfloat (2) | musl | 35 | no | yes |
| `linux-armv5-glibc` | linux-generic32 | Bootlin armv5-eabi glibc 2.31 (softfloat) | glibc | 9 | none | yes |
| `linux-mipsel-uclibc` | linux-mips32 | Bootlin mips32el uClibc | uclibc | 7 | yes | yes |
| `linux-mipsel-musl` | linux-mips32 | OpenWrt SDK mipsel_24kc | musl | 40 | yes | yes |
| `linux-mips-musl` | linux-mips32 | OpenWrt SDK mips_24kc | musl | 28 | yes | yes |
| `linux-riscv64-musl` | linux64-riscv64 | musl.cc riscv64 (rv64gc) | musl | 45, 46, 145 | none | yes |
| `linux-riscv32-musl` | linux-generic32 | musl.cc riscv32 | musl | 47 | none | yes |
| `freebsd-x86_64` | BSD-x86_64 | clang + FreeBSD sysroot | bsd | 30 | yes | no |
| `openbsd-x86_64` | BSD-x86_64 | clang + OpenBSD sysroot | bsd | 37 | yes | no |
| `macos-arm64` | darwin64-arm64-cc | Xcode clang on a Mac, osxcross on Linux | macos | 29 | yes | no |
| `macos-x86_64` | darwin64-x86_64-cc | same | macos | 16 | yes | no |
| `windows-x86[-debug]` | VC-WIN32 | MSVC, NASM | msvc | props | yes | n/a |
| `windows-x64[-debug]` | VC-WIN64A | MSVC, NASM | msvc | props | yes | n/a |
| `windows-arm64[-debug]` | VC-WIN64-ARM | MSVC x64_arm64 cross | msvc | props | no | n/a |

(1) `-march=x86-64 -mtune=generic`, because Bootlin's only x86-64 toolchain defaults to core-i7.
(2) `-march=armv6` or `-march=armv7-a` with `-marm -mfpu=vfp -mfloat-abi=hard`: armv6 implies no
FPU and thumb has no hard-float ABI. Every `-m` flag of `T_CC` is checked against the archive.

"none" in the asm column means the Configure target has no asm modules whatever the flag says
(`linux-generic32`, and 1.1.1 has no RISC-V asm). Every 64-bit target also gets
`enable-ec_nistp_64_gcc_128`. `build.sh list` prints the same table live, with the ARCHIDs asked
from the makefile and whether the prefix exists. Read the comment on a target in `targets.sh`
before touching it, most encode a debugged reason.

Flag reasoning that applies across the table:

- **asm** is enabled where OpenSSL gates it at runtime: x86 and x86-64 on CPUID
  (`OPENSSL_ia32cap_P`, libc-agnostic), AArch64 on `getauxval(AT_HWCAP)`. MIPS asm has no runtime
  fallback and is only trusted after a real crypto run under qemu-mipsel, which passed.
- **`linux-armv4` stays at `-no-asm`** (armv6hf-glibc, armv7hf-musl). With asm the build produced
  wrong crypto results under qemu-arm (non-deterministic SHA-384/512, `RSA.verify()` rejecting its
  own fresh signature). Reverting to `-no-asm` did not fix it, so the bug is not asm itself and is
  unresolved. Do not trust RSA or SHA-384/512 on those targets. Details in ISSUES.md.
- **`-Os`** goes to space-constrained embedded and router targets only. General-purpose systems
  (x86, x86-64 on any libc, the BSDs, macOS) favour speed.
- **musl targets have no `-mcpu` tune** any more (`linux-aarch64-musl` lost `-mcpu=cortex-a53`):
  the ARMv8 crypto extensions are HWCAP-gated, so plain armv8-a code serves every core.

## Building one target

`build.sh <target>` extracts the pinned tarball into `$BR_WORK/<target>`, runs
`Configure $T_CONF --prefix=/ --libdir=lib --openssldir=/usr/local/ssl $T_FLAGS $T_EXTRA` with
`CC=$T_CC`, makes `build_libs`, then `make DESTDIR=<stage> install_dev`. `--prefix=/` makes
`install_dev` lay the prefix out directly under the stage, and the openssldir stays at OpenSSL's
default so the compiled-in certificate paths do not move with the layout. The `.pc` files get
`prefix=${pcfiledir}/../..` so they carry no machine path. Only `opensslconf.h` is kept per target,
the other headers are copied once into `openssl/<version>/include/openssl/` if that directory is
absent. The staged prefix is then gated (next section) and only on a pass copied to
`openssl/<version>/<target>/`, replacing what was there.

`BR_FETCH=1 build.sh <target>` first provisions the toolchain from the target's `T_FETCH` tokens
(`apt:<package>` or a `fetch-toolchains.sh` component). CI sets it, a local run never installs
packages unasked. `T_MAKE` is `build_libs` for every target because the repo ships only the two
archives and the 3.x apps and fuzz link needs 64-bit atomics the 32-bit targets lack.

## verify and the gates

`openssl/build/verify [target ...]` walks every `openssl/<version>/<target>/` of every installed
version, Windows `.lib` prefixes included, on any host. Everything is read with `strings` and
`archive-info.py`, so no target binutils are needed. It first checks that
`openssl/<version>/include/openssl/opensslv.h` says that version, then runs `gate_target` from
`probe.sh` on each prefix, the same function `build.sh` runs on the stage before installing. One
`REJECT` line per failure, `VERIFIED` or `REJECTED` at the end, nonzero exit on any reject. A
target of `targets.sh` with no prefix for a version is reported as `missing`, not rejected, since
a new version is filled in one target at a time. A prefix directory that is no target is rejected:
add the target or move the directory to `openssl/legacy/`.

The gates, in the order `probe.sh` applies them:

1. `lib/libcrypto.a` (`.lib` for msvc) exists and is an ar archive `archive-info.py` recognises.
2. The `OpenSSL x.y.z` string in the archive equals the version directory it lives in.
3. The `platform:` string equals `T_CONF`.
4. ELF, Mach-O or COFF wordsize and machine of the members match what `T_CONF` implies
   (`conf_class` and `conf_machine` in `probe.sh`).
5. The `compiler:` line names `T_CC`'s compiler basename, carries every `-m` flag of `T_CC`, has
   `-Os` exactly when `T_EXTRA` asks for it, and has the `_ASM` defines exactly when the recipe
   removes `-no-asm` (except `linux-generic32`/`64`, which have none to show).
6. A musl target was compiled by a toolchain whose name contains `musl`.
7. MSVC archives are not `/MD`, and show `/Od` for `--debug` targets and `/O1` or `/O2` otherwise.
8. Witness symbols: every option in the flags file plus `T_EXTRA` that has an entry in
   `probe.sh`'s `WITNESS` table left its mark. `no-engine` means `ENGINE_new` is absent, `no-cms`
   `CMS_sign`, `no-comp` `COMP_CTX_new`, `no-ocsp` `OCSP_request_add0_id`, and likewise for
   `no-bf`, `no-md4`, `no-camellia`, `no-cast`, `no-idea`, `no-rc5`, `no-seed`, `no-mdc2`,
   `no-rmd160`, `no-md2`, `no-srp`, `no-psk`. `enable-ec_nistp_64_gcc_128` means
   `EC_GFp_nistp256_method` is present. A new flag only needs a witness entry, nothing else.
9. `opensslconf.h` defines `OPENSSL_NO_<X>` for every `no-<x>` (except `shared`, `zlib`,
   `zlib-dynamic` and `ssl`, which leave no macro) and not for any `enable-<x>`.
10. `opensslconf.h`'s wordsize (`THIRTY_TWO_BIT` or `SIXTY_FOUR_BIT[_LONG]`) matches the objects.
11. `lib/pkgconfig/libcrypto.pc` exists and its `Version:` equals the version (not for msvc).
12. `GLIBC_ONLY_RE` references are zero for musl and uClibc, `UCONTEXT_RE` references are zero
    for musl (both regexes in `build-env.sh`, see the riscv64 incident below).

The member count is reported in the `ARCHIVE` column only. It used to be a gate (`T_OBJS`), which
folded version, Configure target, asm and options into one integer per target and could not
survive a second OpenSSL version. Everything it proved is now checked directly. A side effect:
the macOS archives count 564 and 576 members here, the old 565 and 577 were GNU `ar` miscounting
the Mach-O `__.SYMDEF` pseudo-member.

`consistency.sh` is the other gate, read-only and about drift rather than archives. Its eight
checks are listed in BUILD.md. The ones that touch this layout: every prefix directory is a
target, the pinned version is installed, every non-obsolete ARCHID's `OSSLTARGET` is a known and
installed target, `build.ps1`'s `$Targets` names equal `targets.sh --names windows`, the shared
`opensslv.h` is the pinned release, there is no shared `opensslconf.h`, and every prefix has its
own.

## Adding an OpenSSL version side by side

The version selects the prefix directory, so a new version is built next to the pinned one and
nothing consumes it until asked.

1. Add `flags/<series>.txt` if the series has none (`build-env.sh` picks the most specific of
   `<version>`, `<version without patch letter>`, `<major.minor>`, `<major>`). 3.x renames or
   adds options (`no-module`, `no-legacy`, `no-deprecated`), so it needs its own file, and every
   new `no-<x>` should get a `WITNESS` entry in `probe.sh`.
2. `OPENSSL_VERSION=3.x.y openssl/build/build.sh <target>` fetches nothing by itself, so run
   `OPENSSL_VERSION=3.x.y ./fetch-toolchains.sh openssl` first (sha256 and release tag are
   derived from the version). The build creates `openssl/3.x.y/<target>/` and, on the first
   target, `openssl/3.x.y/include/openssl/`.
3. `make ARCHID=n OSSLVER=3.x.y` links that prefix, or set `OSSLVER = 3.x.y` in that ARCHID's
   `ARCH_` block to make the pin permanent for that target only. `verify` audits both versions
   from now on, and `build.sh list` marks such ARCHIDs as `id@version`.
4. Switching the repo means editing `openssl/VERSION`. `consistency.sh` check 2 fails until every
   ARCHID's target is installed under the new version, and check 6 fails if the old literal is
   still written anywhere.

In CI, `build-openssl-job.yml`'s `version` input does the same: it selects the prefix directory,
the action skips a target whose prefix already carries that version unless `force` is set, and
the pull request adds `openssl/<version>`. The 3.x agent-side work (`PKCS12_create` defaulting to
RC2-40, `SSL_CTX_set_options` misuse, deprecated `ENGINE` headers) is separate from this layout.

## Adding a target

1. Add a case to `br_target` in `targets.sh` with `T_CONF`, `T_CC`, `T_FLAGS` edits, `T_EXTRA`,
   `T_LIBC`, `T_FETCH` and, if not linux, `T_CI`, plus a comment saying why the recipe is what it
   is. Add the name to `BR_ALL_TARGETS`. The name must follow `<os>-<arch>-<libc>` (check 1).
2. Put `OSSLTARGET = <name>` in the `ARCH_<id>` block of every ARCHID that links it.
3. `openssl/build/build.sh <name>`, then `openssl/build/verify <name>` and
   `openssl/build/consistency.sh`. CI picks the target up from `T_CI` with no YAML edit.
4. Windows: add the row to `build.ps1`'s `$Targets` as well, check 5 keeps the two tables equal.

## Provisioning `$BUILDROOT` on a fresh machine

`./fetch-toolchains.sh` (repo root) automates everything with a public URL: the OpenSSL tarball,
the OpenWrt SDKs, the Bootlin toolchains (glibc and uClibc, checksum-verified), the musl.cc
prebuilt cross toolchains (aarch64, armhf, x86_64, riscv64, riscv32, no published checksum, gated
on a smoke compile), the T-Head/Xuantie riscv64 vendor toolchain (mirrored, see below), the Arm
GNU toolchain, and the FreeBSD/OpenBSD sysroots. Safe to re-run, present components are skipped.
`fetch-toolchains.sh list` reports status without fetching. It does not install the apt
prerequisites below. `osxcross` clones and builds osxcross, but the macOS SDK is Apple-licensed
and must be supplied locally, see BUILD.md's macOS section. It lives at the repo root because it
also wires the toolchains the agent's own cross-compile needs (ARCHID 28, 36, 40) into
`../ToolChains/`, so `$BUILDROOT` serves the agent build too.

### Host prerequisites (apt, Debian/Ubuntu)

```
gcc gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi gcc-arm-linux-gnueabihf \
gcc-mips-linux-gnu gcc-mipsel-linux-gnu gcc-riscv64-linux-gnu \
libc6-dev-i386 lib32gcc-14-dev musl-tools clang lld make curl tar xz-utils zstd python3
```

`python3` is for `archive-info.py`. Not `gcc-multilib`: on Debian trixie and Ubuntu 24.10+ its
`gcc-14-multilib` dependency carries a blanket `Conflicts:` against every
`gcc-14-<target>-linux-gnu` cross package. `libc6-dev-i386` plus `lib32gcc-14-dev` give
`gcc -m32` the same 32-bit runtime without that conflict.

### `$BUILDROOT` layout

```
$BUILDROOT/
  downloads/                       openssl-<version>.tar.gz (sha256-verified)
  sysroots/
    freebsd-<rel>/                 FreeBSD base sysroot (clang cross)
    openbsd-<rel>/                 OpenBSD base sysroot (clang cross)
  toolchains/
    openwrt-sdk-<rel>-*_musl.Linux-x86_64/     linux-mips-musl, linux-mipsel-musl (and the agent's 36)
    aarch64-linux-musl-cross/                   linux-aarch64-musl (musl.cc)
    arm-linux-musleabihf-cross/                 linux-armv7hf-musl (musl.cc)
    riscv64-linux-musl-cross/                   linux-riscv64-musl (musl.cc)
    riscv32-linux-musl-cross/                   linux-riscv32-musl (musl.cc)
    riscv64-linux-musl-xthead/                  T-Head/Xuantie vendor toolchain (agent ARCHID 45 only)
    mips32el--uclibc--stable-<rel>/             linux-mipsel-uclibc (Bootlin)
    <family>--glibc--stable-<rel>/              armv5-eabi, armv7-eabihf, aarch64, x86-i686,
                                                x86-64-core-i7 (Bootlin, pinned)
  osxcross/                        the osxcross install when built on this host
  work/                            scratch build trees and stages per target, safe to delete
```

Version-less names are symlinks `fetch-toolchains.sh` creates, so a toolchain bump is one
`build-env.sh` edit. The musl.cc entries replaced an older dd-wrt toolchain set, any note still
saying "dd-wrt" is stale.

### Sources

- **OpenSSL tarball**: fetched and verified against openssl.org's own `<tarball>.sha256` sidecar.
- **OpenWrt SDKs**: OpenWrt's release downloads, no per-tarball checksum, smoke-tested.
- **Bootlin toolchains**: toolchains.bootlin.com, checksum-verified.
- **musl.cc toolchains**: musl.cc, no published checksum, smoke-tested.
- **T-Head/Xuantie riscv64 vendor toolchain**: no public upstream URL (the XuanTie repo ships
  source only, prebuilts sit behind their account-gated portal). Built from source once
  (2026-08-24, `xuantie-gnu-toolchain` V3.0.1, `make musl`) and mirrored at
  `PTR-inc/meshagent-toolchains/TC`, fetched via `./fetch-toolchains.sh riscv64-xthead`. A rebuild
  from source needs about 20 apt packages, a 6.65 GB submodule pull and 45 to 90 minutes. No
  OpenSSL target uses it, only the ARCHID 45 agent build.
- **Arm GNU Toolchain**: developer.arm.com, currently used by no target.
- **FreeBSD/OpenBSD sysroots**: the `usr/include` and `usr/lib` subset of each release, mirrored.

## The riscv64 ASYNC/ucontext bug (2026-08-24), read before touching a musl target

The old `riscv64` archive was built glibc (`riscv64-linux-gnu-gcc`) while ARCHID 45 and 145 both
link it as musl, a real mismatch. Linking an agent failed with `undefined reference to
getcontext/setcontext/makecontext`: OpenSSL's `crypto/async/arch/async_posix.h` compiles
`ASYNC_POSIX` in when `__GLIBC__` is defined, and musl implements `ucontext.h` on no architecture
(checked in musl's own tree, only `src/setjmp/`). It went undetected because nothing had ever
linked an agent against that archive, and `verify`'s `GLIBC` column had already shown it nonzero
without anyone acting on it.

Fixed the same day: the target builds with the musl.cc toolchain, the flags file gained `no-async`
globally (MeshAgent never calls `ASYNC_*`, and `no-engine` precludes the only thing that would),
and the ucontext gate was added. It is fatal for musl only, since uClibc's `libc.so` genuinely
implements `getcontext` and friends (checked with `nm`). `libucontext` was evaluated as a way to
make `ASYNC_POSIX` work on musl and rejected as a permanent extra static library for a feature
nothing here calls. Today gates 6 and 12 catch this class at build time.

## CI

`.github/workflows/build-openssl-job.yml` is the one dispatcher. Its matrices are generated:
`targets.sh --names linux` and `--names macos` from `T_CI`, and for Windows a grep of
`build.ps1`'s `$Targets` (act's image has no pwsh). Linux and macOS jobs run the composite action
`.github/actions/openssl-build-target`, which only calls `build.sh`, so the skip check, version
gate and every archive gate are `build.sh`'s. The action collects `out/openssl/<version>/<target>`
plus `include/` when the version is new. The Windows job calls `build.ps1`. `verify-summary`
overlays the fresh prefixes on the checkout and runs `verify` over all of them. With `commit=true`
it then commits `openssl/<version>/` to the branch the run was started from; with `create_pr=true`
it opens a pull request instead. A commit pushed with `GITHUB_TOKEN` starts no other workflow, so
the platform builds only pick the new archives up on the next ordinary push, whereas merging the
pull request triggers them.
`build-system-checks.yml` runs `consistency.sh`, `verify` and `bash -n` on every script; on any
change under `openssl/**` or the build files pushed to master (its own path list, since it is
no platform of `build.yml`). Rules for what may and may not be written into a
workflow are in BUILD.md.

## Windows build (native, PowerShell)

MSVC's `Configure` and `nmake` need a real developer environment, so the Windows sibling is
PowerShell. `build.ps1` uses the same flags file, NASM-enabled asm for x86 and x64 only
(`VC-WIN64-ARM` has no asm path in 1.1.1), patches the generated makefile from `/MD` to `/MT`
for a static CRT, and stages `lib\libcrypto.lib`, `lib\libssl.lib` and
`include\openssl\opensslconf.h` into `openssl\<version>\windows-<x86|x64|arm64>[-debug]\`. In
1.1.1 `nmake`, not `Configure`, writes `opensslconf.h`, so it is copied after the build. The
object count is reported only.

```powershell
. openssl\build\windows\env.ps1
Test-BuildRootWindows                          # VS, perl, nasm and the tarball all present?
Install-BuildRootWindows                       # fetches whatever that reported missing

openssl\build\windows\build.ps1 windows-x64
openssl\build\windows\build.ps1 all
openssl\build\windows\toolset-check.ps1 -Platform x64 -Toolset v143   # audit vs the linking toolset
```

`toolset-check.ps1` parses the committed COFF archives itself, without `lib.exe`: it reports the
version, `platform:`, `compiler:` and member count of each, and exits 1 only for a machine-type,
CRT (`/MT` vs `/MTd` or `/MD`) or LTCG-build mismatch with the toolset about to link them. A
different compiler build is a warning. `windows-build.yml` runs it before every agent build. It
took over what `verify.ps1` used to report, and `openssl/build/verify` audits the same `.lib`
files on Linux, so the Windows prefixes are covered by both.

Known caveat: the six committed `-debug` archives were compiled `/MT /Od`, not `/MTd`, because
`build.ps1`'s `/MDd` replacement never matched (the debug makefile said `/MD`). The objects are
`/Zl`, so no CRT is pulled in and the agent links, but they are not true MTd builds until rebuilt
on the Windows runner. Tracked in ISSUES.md.

### Prerequisites

`Install-BuildRootWindows` provisions everything except the MSVC toolsets. A bare call does the
three that need no admin rights, the source tarball, perl and NASM, each pinned to a version, URL
and SHA-256 and unpacked under `$BUILDROOT\tools`. Nothing is put on `PATH` or written outside
`$BUILDROOT`, so undoing it is `Remove-Item -Recurse $BUILDROOT`.

```powershell
Install-BuildRootWindows                       # tarball + perl + nasm
Install-BuildRootWindows -Nasm                 # just one of them
Install-BuildRootWindows -Force                # re-fetch even if present
Install-BuildRootWindows -VsComponents         # adds the missing MSVC components, prompts, needs admin
Install-BuildRootWindows -BuildRoot D:\br      # somewhere other than the default
```

It asks where to put the buildroot before writing anything, defaulting to `$BUILDROOT`. Set
`$env:BUILDROOT` before dot-sourcing `env.ps1` to make an answer stick. `-VsComponents` is never
implied: it shells out to the Visual Studio installer elevated with `--passive --norestart`, adds
only what is missing, and in a non-interactive session prints the command and stops.

- Visual Studio with the **C++ x64/x86 build tools** component, and the **C++ ARM64 build tools**
  for the arm64 targets. A **Windows SDK** component as well, since the build-tools components do
  not include one and a `cl.exe` without it fails on `stdlib.h`. `Test-BuildRootWindows` reports
  the toolset it picked per target and pins it with `-vcvars_ver`, because a default toolset
  folder has been seen with no compiler in it, and a newest toolset with an incomplete arm64 lib
  set. VS 2017 to 2022 and VS 2026 (v18) both work, `env.ps1` drives `vcvarsall.bat` or falls
  back to `VsDevCmd.bat`.
- A real Windows `perl.exe`. Git for Windows' bundled perl is Cygwin and `Configure` refuses it.
  Strawberry Perl (CI: `choco install strawberryperl`, locally the portable zip) works.
- NASM for asm-enabled x86 and x64. Without it `build.ps1` falls back to `-no-asm` for those
  targets. `Get-NasmPath` checks `PATH`, then `%LOCALAPPDATA%\bin\NASM\nasm.exe`.
- ARM64 targets cross-compile from an x64 host (`x64_arm64`), no ARM64 machine needed. In CI one
  `windows-2022` runner covers all six targets.

## macOS notes

`targets.sh` resolves the macOS compiler per call: Xcode's `cc` on a Mac, the osxcross prefixed
clang on Linux, with `$OSXCROSS_BIN` put on `PATH` because clang finds `<triple>-ld` only there.
No `-target` is passed, the `darwin64-*-cc` Configure targets add `-arch` themselves and an
explicit one breaks osxcross's linker selection. The deployment floor comes from the makefile's
`MACOSARCH` via `make print-macosarch`, so the archive's minos never exceeds the agent's.
`T_AR`, `T_RANLIB` and `T_NM` are the prefixed tools on Linux because host GNU binutils do not
reliably handle Mach-O archives (the gates no longer depend on them). CI builds macOS on macOS
runners, osxcross is the developer-machine path, and the SDK it needs is never on the public
mirror. The committed macOS archives were built through osxcross before the layout change.
Nothing macOS has been rebuilt or run since, the CI macOS job is what exercises the new layout.
