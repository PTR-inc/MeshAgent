#!/bin/bash
# The one place defining every OpenSSL target: how it is configured and what compiles it.
# A target is named by what decides link compatibility, <os>-<arch/abi>-<libc>, never by a
# board or distribution, and its archives live in openssl/<version>/<target>/. br_target <name>
# sets the T_ variables. The fields are documented in openssl/build/README.md.
#
# Every T_CC="$TC_ZIG/zig cc ..." target below embeds DWARF debug info by default, confirmed via
# the real compile lines in $BR_WORK/<target>.log having no -g anywhere, yet every .o still
# carries .debug_info/.debug_line/etc (plain clang/gcc never do this without an explicit -g).
# That's why these archives run noticeably larger than the old openssl/libstatic/ ones on the
# same target - left in deliberately: the agent's own STRIP_AND_SYMBOLCP (see makefile) already
# strips it back out of the shipped binary, and the pre-strip DEBUG_ copy gets real file/line
# frames inside OpenSSL for free. Pass -g0 in a target's T_FLAGS to opt a target out of this.

# A real macOS runner already has clang and the SDK - no toolchain-floor problem to solve there,
# so that branch is untouched. The Linux-cross-host branch (previously osxcross's own clang
# wrapper) moved to zig 2026-08-30: zig has no bundled Apple SDK (can't - it's licensed), so
# --sysroot still points at the same osxcross-extracted SDK either way. Two zig-specific gotchas
# found verifying this, both silent rather than erroring, so easy to miss:
#  1. -mmacosx-version-min= is ignored outright (confirmed via otool -l: LC_BUILD_VERSION's minos
#     stayed 13.0 regardless of the flag's value). The floor has to be baked into the target
#     triple's own version suffix instead - "aarch64-macos.11.0", not "-target aarch64-macos
#     -mmacosx-version-min=11.0" - which otool then confirms lands correctly.
#  2. zig's own bundled generic-macos headers cover plain libc (stdio.h et al.) but not Apple
#     frameworks - CommonCrypto/CommonCryptoError.h ("crypto/rand.h" pulls it in) 404s under
#     --sysroot alone. Needs an explicit -isystem $SDK/usr/include forcing the real SDK headers in.
# This is resolved per call after build-env.sh is sourced.
_osx_tools() {
    # br_target calls this for every target, and the two make probes below cost a full makefile
    # parse each, so the result is computed once and reused for the rest of the process.
    [ -n "${_OSX_TOOLS_DONE:-}" ] && return
    _OSX_TOOLS_DONE=1
    local arm_min x64_min sdk
    arm_min=$(make -s -C "$REPO" ARCHID=29 print-macosarch 2>/dev/null)
    x64_min=$(make -s -C "$REPO" ARCHID=16 print-macosarch 2>/dev/null)
    if [ "$(uname -s)" = Darwin ]; then
        _OSX_ARM_CC="cc $arm_min"; _OSX_X64_CC="cc $x64_min"
        _OSX_ARM_AR=; _OSX_ARM_RANLIB=; _OSX_ARM_NM=; _OSX_X64_AR=; _OSX_X64_RANLIB=; _OSX_X64_NM=
    else
        sdk="$OSXCROSS_DIR/target/SDK/MacOSX$OSXCROSS_SDK_VER.sdk"
        _OSX_ARM_CC="$TC_ZIG/zig cc -target aarch64-macos.${arm_min#-mmacosx-version-min=} --sysroot=$sdk -isystem $sdk/usr/include"
        _OSX_X64_CC="$TC_ZIG/zig cc -target x86_64-macos.${x64_min#-mmacosx-version-min=} --sysroot=$sdk -isystem $sdk/usr/include"
        # Previously (osxcross's own clang wrapper, still what a from-scratch `fetch-toolchains.sh
        # osxcross` provisions - see the T_FETCH note below):
        #   _OSX_ARM_CC="$OSXCROSS_BIN/aarch64-apple-darwin$OSXCROSS_DARWIN_VER-clang $arm_min"
        #   _OSX_X64_CC="$OSXCROSS_BIN/x86_64-apple-darwin$OSXCROSS_DARWIN_VER-clang $x64_min"
        #   _OSX_ARM_TOOLS/_OSX_X64_TOOLS were the osxcross <triple>-ar/-ranlib/-nm prefix.
        # zig ar/ranlib (llvm-ar) handle Mach-O archives correctly - verified: `file` reports a
        # valid ar archive and a real Configure+build_libs run for both arches completed clean.
        # T_NM stays empty: zig has no `nm` subcommand (only ar/ranlib/objcopy), and T_NM turns
        # out to be dead wiring anyway - grep confirms build.sh/probe.sh never pass NM= to the
        # real build, so there's nothing depending on it either way.
        _OSX_ARM_AR="$TC_ZIG/zig ar"; _OSX_ARM_RANLIB="$TC_ZIG/zig ranlib"; _OSX_ARM_NM=
        _OSX_X64_AR="$TC_ZIG/zig ar"; _OSX_X64_RANLIB="$TC_ZIG/zig ranlib"; _OSX_X64_NM=
    fi
}

br_target() {
    _osx_tools
    T_CONF=; T_CC=; T_EXTRA=; T_AR=; T_RANLIB=; T_NM=; T_FETCH=
    T_LIBC=glibc; T_CI=linux
    # build_libs everywhere, because the repo ships only the two archives and the 3.x
    # apps and fuzz link needs 64-bit atomics that the 32-bit targets lack.
    T_MAKE=build_libs
    T_FLAGS="$OSSL_FLAGS"
    case "$1" in
    # 2026-08-30: switched to Zig's bundled Clang (zig cc -target <triple>.<glibcver>), which
    # reaches the same glibc floor as the old toolchain with a current compiler instead of
    # whatever gcc version that toolchain's era happened to ship - see meshagent-optimizations.md.
    # Previously: pinned Bootlin glibc 2.24 toolchain ($TC_X86_64_BOOTLIN/bin/x86_64-linux-gcc
    # -march=x86-64 -mtune=generic; the -march/-mtune override existed only because that
    # toolchain otherwise defaulted to core-i7 tuning - zig's default x86_64 baseline needs no
    # such override). The asm modules gate on runtime CPUID.
    linux-x86_64-glibc) T_CONF=linux-x86_64 ; T_CC="$TC_ZIG/zig cc -target x86_64-linux-gnu.2.24" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_FETCH="zig" ;;
    # Previously: pinned Bootlin glibc 2.24 toolchain ($TC_X86_BOOTLIN/bin/i686-linux-gcc).
    linux-i686-glibc)   T_CONF=linux-x86    ; T_CC="$TC_ZIG/zig cc -target x86-linux-gnu.2.24" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_FETCH="zig" ;;
    # x86-64 asm is CPUID-gated and works on any libc. Serves Alpine and OpenWrt x86-64 alike,
    # so no -Os: the archive is shared and the general-purpose use favours speed.
    # Previously: $MUSL_CC (apt musl-tools' host musl-gcc).
    linux-x86_64-musl)  T_CONF=linux-x86_64 ; T_CC="$TC_ZIG/zig cc -target x86_64-linux-musl" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=musl ; T_FETCH="zig" ;;
    # One archive serves both the compat ARCHID 32 and the general ARCHID 26. AArch64 asm
    # gates on runtime AT_HWCAP. Previously: pinned Bootlin glibc 2.31 toolchain
    # ($TC_AARCH64_BOOTLIN/bin/aarch64-linux-gcc).
    linux-aarch64-glibc) T_CONF=linux-aarch64 ; T_CC="$TC_ZIG/zig cc -target aarch64-linux-gnu.2.31" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -O2" ; T_FETCH="zig" ;;
    # sparcv9 asm on since 2026-08-28. No hardware here, so it is validated under qemu-sparc64
    # only. NOT switched to zig: root-caused 2026-08-30 - `srln`, a genuine GNU-as-native
    # synthetic SPARC pseudo-op used 14x in the vendored crypto asm (not a macro; resolves to a
    # real shift on 32-bit V8, a nop on 64-bit V9 - see crypto/perlasm/sparcv9_modes.pl's own
    # comment), isn't implemented by LLVM's SPARC integrated assembler through LLVM 21.1.0 (zig
    # 0.15.2/0.16.0). Fixed in LLVM 22.1.8 (zig 0.17.0-dev master) - confirmed with a real
    # Configure+build_libs pass - but not adopted: ziglang.org's release index only exposes a
    # moving "master" key, not that exact dev snapshot, so it isn't a reproducible pin the way
    # every other toolchain here is. Revisit at a tagged 0.17.0 stable release. Stays on the
    # pinned Bootlin glibc 2.31 toolchain ($TC_SPARC64_BOOTLIN/bin/sparc64-linux-gcc) until then.
    linux-sparc64-glibc) T_CONF=linux64-sparcv9 ; T_CC="$TC_SPARC64_BOOTLIN/bin/sparc64-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_FETCH="bootlin-sparc64" ;;
    # Previously: pinned Bootlin glibc 2.31 toolchain ($TC_POWERPC64LE_BOOTLIN/bin/powerpc64le-linux-gcc).
    linux-ppc64le-glibc) T_CONF=linux-ppc64le ; T_CC="$TC_ZIG/zig cc -target powerpc64le-linux-gnu.2.31" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_FETCH="zig" ;;
    # The ARMv8 crypto extensions are runtime-HWCAP-gated, so plain armv8-a code is generated
    # and cores with or without them are both safe. Previously: musl.cc toolchain
    # ($TC_AARCH64_A53_MUSL/bin/aarch64-linux-musl-gcc).
    linux-aarch64-musl) T_CONF=linux-aarch64 ; T_CC="$TC_ZIG/zig cc -target aarch64-linux-musl" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -O2" ; T_LIBC=musl ; T_FETCH="zig" ;;
    # asm stays disabled: under qemu-arm it produced wrong crypto results, still unresolved.
    # No glibc floor was ever pinned for this row (apt's cross gcc, whatever floor that carries),
    # so none is pinned in the zig triple either - same floor behaviour as before the switch.
    # Previously: apt's arm-linux-gnueabihf-gcc -march=armv6 -marm -mfpu=vfp -mfloat-abi=hard.
    # -mcpu=arm1176jzf_s, because this target is named for the ARM1176JZF-S boards (Pi 1, Zero,
    # Zero W) and neither zig's default nor any Debian armhf gcc targets them: both emit ARMv7 with
    # VFPv3. Measured 2026-08-31, before the flag: every object here was Tag_CPU_arch v7, so an
    # agent linking it could not run on the hardware the target exists for. ARCHID 24 is the ARMv7
    # target and keeps linux-armv7hf-glibc.
    linux-armv6hf-glibc) T_CONF=linux-armv4 ; T_CC="$TC_ZIG/zig cc -target arm-linux-gnueabihf -mcpu=arm1176jzf_s" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_EXTRA="-Os" ; T_FETCH="zig" ;;
    # linux-generic32 has no asm modules regardless of flags. Previously: pinned Bootlin glibc
    # 2.31 toolchain ($TC_ARMV7HF_BOOTLIN/bin/arm-linux-gcc).
    linux-armv7hf-glibc) T_CONF=linux-generic32 ; T_CC="$TC_ZIG/zig cc -target arm-linux-gnueabihf.2.31" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_EXTRA="-Os" ; T_FETCH="zig" ;;
    # Generic ARMv7 static musl, a NEON-free portable baseline rather than an SoC-tuned build.
    # asm stays disabled because of the same linux-armv4 crypto-correctness break as armv6hf.
    # Previously: musl.cc toolchain ($TC_ARMV7_MUSL_HF/bin/arm-linux-musleabihf-gcc -march=armv7-a
    # -marm -mfpu=vfp -mfloat-abi=hard).
    linux-armv7hf-musl) T_CONF=linux-armv4 ; T_CC="$TC_ZIG/zig cc -target arm-linux-musleabihf" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_EXTRA="-Os" ; T_LIBC=musl ; T_FETCH="zig" ;;
    # linux-generic32 has no asm modules regardless of flags. Previously: pinned Bootlin glibc
    # 2.31 toolchain ($TC_ARMV5_BOOTLIN/bin/arm-linux-gcc).
    linux-armv5sf-glibc)  T_CONF=linux-generic32 ; T_CC="$TC_ZIG/zig cc -target arm-linux-gnueabi.2.31" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_EXTRA="-Os" ; T_FETCH="zig" ;;
    # Little-endian MIPS on the pinned Bootlin uClibc toolchain, because ARCHID 7's agent is
    # uClibc and cannot link a glibc archive at all. asm runs correct crypto under qemu-mipsel.
    # NOT switched to zig: Zig has no uClibc ABI at all (confirmed 2026-08-30 -
    # 'unable to parse target query mipsel-linux-uclibceabi: UnknownApplicationBinaryInterface').
    linux-mips32r1el-uclibc) T_CONF=linux-mips32 ; T_CC="$TC_MIPSEL_UCLIBC_BOOTLIN/bin/mipsel-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_LIBC=uclibc ; T_FETCH="bootlin-mipsel-uclibc" ;;
    # 2026-08-30: switched to zig. First attempt used the bare `mipsel-linux-musl` triple, which
    # zig accepts but silently never wires up its own -isystem search path for (0 auto isystems
    # vs. 4 for a working target - a driver footgun, not a real "unsupported" error). The fix was
    # the target name, not a workaround: zig renamed this triple to require an explicit float-ABI
    # suffix, `musleabihf`/`musleabi`. The OpenWrt mipsel24kc toolchain this replaces defaults to
    # soft-float (`-mhard-float [disabled]`, confirmed via `-Q --help=target`), so `musleabi` is
    # the correct match, not `musleabihf`. Previously: $TC_OWRT_MIPSEL24KC/bin/mipsel-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPSEL24KC.
    # Rebuilt 2026-08-31 with build.sh's br_patch_mips_la, which fixes the clang-miscompiled
    # aes-mips.S/sha256-mips.S the previous archive carried - see the linux-mips32r1el-musl row.
    linux-mips32r2el-musl)  T_CONF=linux-mips32 ; T_CC="$TC_ZIG/zig cc -target mipsel-linux-musleabi" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_LIBC=musl ; T_FETCH="zig" ;;
    # MIPS32r1 little-endian static musl, for ARCHID 7's pre-r2 silicon (Broadcom BMIPS3300/4350,
    # Atheros AR231x, MIPS 4Kc). It cannot share linux-mips32r2el-musl: that archive is built at zig's
    # default -target-cpu mips32r2 and carries 426 r2-only instructions (ext, ins, wsbh, seb),
    # which SIGILL on r1. -mcpu=mips32 pins the baseline; endianness and the soft-float musleabi
    # ABI are otherwise identical to linux-mips32r2el-musl.
    # asm is ON again since 2026-08-31. It was off because clang's integrated assembler miscompiled
    # aes-mips.S and sha256-mips.S: `la` of a table symbol defined later in the file loses its
    # R_MIPS_LO16 pair, so the K256/AES_Te pointers dropped their in-page offset and SHA-256/AES
    # computed garbage (llvm/llvm-project#65020, fix PR 83115 unmerged in every zig/LLVM so far).
    # build.sh's br_patch_mips_la works around it with forward .local declarations. At -mcpu=mips32
    # the asm carries no r2-only instructions, since mips_arch.h keys off __mips_isa_rev.
    linux-mips32r1el-musl) T_CONF=linux-mips32 ; T_CC="$TC_ZIG/zig cc -target mipsel-linux-musleabi -mcpu=mips32" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_LIBC=musl ; T_FETCH="zig" ;;
    # Same fix and same soft-float confirmation as linux-mips32r2el-musl above, big-endian variant.
    # Previously: $TC_OWRT_MIPS24KC/bin/mips-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPS24KC.
    # Rebuilt 2026-08-31 with br_patch_mips_la, same clang-miscompile fix as the rows above.
    linux-mips32r2eb-musl)    T_CONF=linux-mips32 ; T_CC="$TC_ZIG/zig cc -target mips-linux-musleabi" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_LIBC=musl ; T_FETCH="zig" ;;
    # Generic rv64gc musl. Serves the T-Head C906 boards too, since rv64gc is a subset of what
    # they run. 1.1.1 has no RISC-V asm. A glibc build here once leaked ASYNC_POSIX.
    # Previously: musl.cc toolchain ($TC_RISCV64_MUSL/bin/riscv64-linux-musl-gcc).
    linux-riscv64-musl) T_CONF=linux64-riscv64 ; T_CC="$TC_ZIG/zig cc -target riscv64-linux-musl" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_LIBC=musl ; T_FETCH="zig" ;;
    # OpenSSL 1.1.1 has no riscv32 Configure target, so this Configures as linux-generic32.
    # Previously: musl.cc toolchain ($TC_RISCV32_MUSL/bin/riscv32-linux-musl-gcc).
    linux-riscv32-musl) T_CONF=linux-generic32 ; T_CC="$TC_ZIG/zig cc -target riscv32-linux-musl" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_EXTRA="-Os" ; T_LIBC=musl ; T_FETCH="zig" ;;
    # No -Os: general-purpose operating systems favour speed. 2026-08-30: switched to zig. Zig
    # bundles no FreeBSD/OpenBSD libc either (same reason as macOS below - real, versioned OS
    # headers, not something to vendor generically), so --sysroot still points at the same pinned
    # sysroots either way, forced past zig's own bundled-header attempt with -nostdlibinc
    # -isystem $SYSROOT/usr/include (found via a real failure: an unforced FreeBSD build silently
    # compiled against zig's own bundled generic-freebsd headers, targeting __FreeBSD_version
    # 14.0 rather than this repo's pinned $FREEBSD_REL - a header/sysroot version-drift risk, not
    # just a missing-file error, so worth the explicit force even where it doesn't hard-fail).
    # zig has no OS-version triple suffix for these two (unlike glibc's .2.31 or macOS's .11.0) -
    # $FREEBSD_REL/$OPENBSD_REL take no effect on the compiler here, only on which sysroot tree
    # is baked into $SYSROOT_FREEBSD/$SYSROOT_OPENBSD already.
    # Previously: clang --target=$FREEBSD_TRIPLE --sysroot=$SYSROOT_FREEBSD -fuse-ld=lld (apt:clang apt:lld).
    freebsd-x86_64)     T_CONF=BSD-x86_64 ; T_CC="$TC_ZIG/zig cc -target x86_64-freebsd-none --sysroot=$SYSROOT_FREEBSD -isystem $SYSROOT_FREEBSD/usr/include -nostdlibinc" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=bsd ; T_FETCH="zig freebsd" ;;
    # Previously: clang --target=$OPENBSD_TRIPLE --sysroot=$SYSROOT_OPENBSD -fuse-ld=lld (apt:clang apt:lld).
    openbsd-x86_64)     T_CONF=BSD-x86_64 ; T_CC="$TC_ZIG/zig cc -target x86_64-openbsd-none --sysroot=$SYSROOT_OPENBSD -isystem $SYSROOT_OPENBSD/usr/include -nostdlibinc" ; T_AR="$TC_ZIG/zig ar" ; T_RANLIB="$TC_ZIG/zig ranlib" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=bsd ; T_FETCH="zig openbsd" ;;
    # No explicit -target beyond what _osx_tools baked in, because the darwin64 Configure targets
    # add -arch themselves and an explicit one breaks the (pre-zig) osxcross wrapper's linker
    # selection - kept as-is since it's still true for the native-Darwin-host branch. T_AR/T_RANLIB
    # come from _osx_tools too now; see its own comment for the zig gotchas found switching this.
    macos-arm64)        T_CONF=darwin64-arm64-cc  ; T_CC="$_OSX_ARM_CC" ; T_AR="$_OSX_ARM_AR" ; T_RANLIB="$_OSX_ARM_RANLIB" ; T_NM="$_OSX_ARM_NM" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=macos ; T_CI=macos ; T_FETCH=osxcross ;;
    macos-x86_64)       T_CONF=darwin64-x86_64-cc ; T_CC="$_OSX_X64_CC" ; T_AR="$_OSX_X64_AR" ; T_RANLIB="$_OSX_X64_RANLIB" ; T_NM="$_OSX_X64_NM" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=macos ; T_CI=macos ; T_FETCH=osxcross ;;

    # Windows is built natively by windows/build.ps1, whose own table carries the MSVC details.
    # These rows exist so the name list, the Configure target and the libc family have one home
    # and verify can audit the .lib archives on any host. asm needs NASM, so VC-WIN64-ARM has none.
    # -fPIC is meaningless to cl and has no MSVC equivalent flag needed here: PE ASLR comes from
    # the linker's /DYNAMICBASE, on by default, not from a compile-time position-independence flag.
    # -std=gnu11 is a GCC/Clang dialect flag; cl has its own /std: switch and OpenSSL's VC-WIN*
    # Configure targets don't pass one, so it is stripped here rather than mismatched onto cl.
    windows-x86)        T_CONF=VC-WIN32     ; T_CC=cl ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_FLAGS="${T_FLAGS/-fPIC/}" ; T_FLAGS="${T_FLAGS/-std=gnu11/}" ; T_LIBC=msvc ; T_CI=windows ;;
    windows-x86-debug)  T_CONF=VC-WIN32     ; T_CC=cl ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_FLAGS="${T_FLAGS/-fPIC/}" ; T_FLAGS="${T_FLAGS/-std=gnu11/}" ; T_EXTRA="--debug" ; T_LIBC=msvc ; T_CI=windows ;;
    windows-x64)        T_CONF=VC-WIN64A    ; T_CC=cl ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_FLAGS="${T_FLAGS/-fPIC/}" ; T_FLAGS="${T_FLAGS/-std=gnu11/}" ; T_LIBC=msvc ; T_CI=windows ;;
    windows-x64-debug)  T_CONF=VC-WIN64A    ; T_CC=cl ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_FLAGS="${T_FLAGS/-fPIC/}" ; T_FLAGS="${T_FLAGS/-std=gnu11/}" ; T_EXTRA="--debug" ; T_LIBC=msvc ; T_CI=windows ;;
    windows-arm64)      T_CONF=VC-WIN64-ARM ; T_CC=cl ; T_FLAGS="${T_FLAGS/-fPIC/}" ; T_FLAGS="${T_FLAGS/-std=gnu11/}" ; T_LIBC=msvc ; T_CI=windows ;;
    windows-arm64-debug) T_CONF=VC-WIN64-ARM ; T_CC=cl ; T_FLAGS="${T_FLAGS/-fPIC/}" ; T_FLAGS="${T_FLAGS/-std=gnu11/}" ; T_EXTRA="--debug" ; T_LIBC=msvc ; T_CI=windows ;;

    *) return 1 ;;
    esac
    # The install prefix this target's archives and generated header live in.
    T_PREFIX="$OPENSSL_PREFIX_ROOT/$1"
    return 0
}

# ---------------------------------------------------------------- build stamp ----
# One build-stamp.txt per target, written into openssl/<version>/<target>/ by build.sh, so a
# rebuild decision needs no archive forensics. It lives here rather than in build.sh because
# verify.sh sources this file too, and a gate has to recompute the same key it compares against.
#
# What gates a rebuild: anything that changes the bytes of the archive. That is the source
# release, the Configure target and arguments, the compiler and archiver commands with their
# versions, the libc, and any patch build.sh applies to the generated asm. Everything else in the
# file is recorded for the reader, not compared. br_target "$1" must already have been called.
#
# The recorded compiler version is the toolchain's own, not the triple's: two zig releases with
# the same triple can emit different code, which is exactly the case the object-count gate missed.
stamp_libc_version() {
    case "$T_CC" in
        # A zig triple carries its libc floor as a version suffix (gnu.2.31), and its musl comes
        # from the zig release itself, so the zig version is the musl version for these targets.
        *zig*)  local suffix="${T_CC#*-target }"; suffix="${suffix%% *}"
                case "$suffix" in *gnu.[0-9]*|*gnueabi.[0-9]*|*gnueabihf.[0-9]*) echo "glibc ${suffix##*.} pinned in the triple" ;;
                                  *musl*) echo "musl as shipped by $(basename "$TC_ZIG")" ;;
                                  *) echo "$T_LIBC, unpinned" ;; esac ;;
        *)      echo "$T_LIBC, from $(dirname "$(dirname "${T_CC%% *}")" | sed 's|.*/||')" ;;
    esac
}

# The gating fields, one "key: value" per line, in a fixed order so the key is stable.
stamp_gating_fields() {
    local cc_ver ar_ver
    cc_ver=$("${T_CC%% *}" ${T_CC#* } --version 2>/dev/null | head -1)
    # llvm-ar prints its banner first and the version on the next line, GNU ar puts both on one.
    ar_ver=$(${T_AR:-ar} --version 2>/dev/null | tr '\n' ' ' | grep -oE '(LLVM version|GNU ar[^0-9]*) *[0-9][0-9.]*' | head -1)
    cat <<EOF
target: $1
openssl_version: $OPENSSL_VERSION
source_sha256: $(sha256sum "$OPENSSL_TARBALL" 2>/dev/null | cut -d' ' -f1)
configure_target: $T_CONF
configure_args: --prefix=/ --libdir=lib --openssldir=/usr/local/ssl $T_FLAGS $T_EXTRA
make_target: $T_MAKE
cc: $T_CC
cc_version: ${cc_ver:-unknown}
ar: ${T_AR:-ar}
ar_version: ${ar_ver:-unknown}
ranlib: ${T_RANLIB:-ranlib}
libc: $T_LIBC
libc_version: $(stamp_libc_version)
asm: $(case "$T_FLAGS" in *-no-asm*) echo off ;; *) echo on ;; esac)
patches: ${2:-none}
EOF
}

# sha256 of the gating fields. A rebuild is needed when this differs from the installed stamp's.
stamp_key() { stamp_gating_fields "$@" | sha256sum | cut -d' ' -f1; }

# Compares an installed prefix's stamp against what targets.sh would produce now, and prints one
# indented block per field that differs. Empty output means the prefix is up to date. Returns 1
# when the prefix carries no stamp at all, which is not the same as a mismatch: it predates the
# mechanism, so nothing can be concluded and the caller decides what to do. build.sh treats that
# as "rebuild", verify.sh as "cannot check". br_target "$1" must already have been called.
#
# Field by field rather than on stamp_key alone, so a caller can say what drifted. Two fields are
# never compared: 'patches' records what the build did to the generated asm and cannot be
# recomputed without building, and 'source_sha256' is skipped when the release tarball is not on
# this host, which is normal for a checkout that has never run build.sh.
stamp_diff() {   # $1 target, $2 prefix
    local f="$2/build-stamp.txt" line k have want skip_src=0 out=""
    [ -f "$f" ] || return 1
    [ -r "$OPENSSL_TARBALL" ] || skip_src=1
    while IFS= read -r line; do
        k=${line%%:*}; want=${line#*: }
        case "$k" in patches) continue ;; source_sha256) [ "$skip_src" = 1 ] && continue ;; esac
        have=$(sed -n "s/^$k: //p" "$f" | head -1)
        [ "$have" = "$want" ] && continue
        out="$out
      $k:
        stamp: ${have:-<absent>}
        now:   $want"
    done <<EOF
$(stamp_gating_fields "$1" "$(sed -n 's/^patches: //p' "$f" | head -1)")
EOF
    printf '%s' "$out"
}

BR_ALL_TARGETS="linux-x86_64-glibc linux-i686-glibc linux-x86_64-musl \
linux-aarch64-glibc linux-aarch64-musl \
linux-armv6hf-glibc linux-armv7hf-glibc linux-armv7hf-musl linux-armv5sf-glibc \
linux-mips32r1el-uclibc linux-mips32r2el-musl linux-mips32r1el-musl linux-mips32r2eb-musl \
linux-riscv64-musl linux-riscv32-musl linux-sparc64-glibc linux-ppc64le-glibc \
freebsd-x86_64 openbsd-x86_64 macos-arm64 macos-x86_64 \
windows-x86 windows-x86-debug windows-x64 windows-x64-debug windows-arm64 windows-arm64-debug"

# Prints target names, optionally filtered by T_CI. The CI matrix is built from this,
# so a new target is picked up by CI the moment it is added above.
print_target_names() {
    local t
    for t in $BR_ALL_TARGETS; do
        br_target "$t" || continue
        [ -z "${1:-}" ] || [ "$T_CI" = "$1" ] || continue
        echo "$t"
    done
}

# Prints one field of one target, for shell and CI callers that want a single value.
print_target_field() {
    br_target "$1" || { echo "unknown target: $1" >&2; return 1; }
    eval "printf '%s\\n' \"\$T_$2\""
}

# This block only runs when the file is executed directly, so sourcing it still just
# defines br_target and BR_ALL_TARGETS as before.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    . "$(dirname "$(readlink -f "$0")")/../../build-env.sh" >/dev/null
    case "${1:-}" in
        --names)  print_target_names "${2:-}" ;;
        --field)  print_target_field "$2" "$3" ;;
        *) echo "usage: $(basename "$0") --names [ci] | --field <target> <FIELD>" >&2; exit 2 ;;
    esac
fi
