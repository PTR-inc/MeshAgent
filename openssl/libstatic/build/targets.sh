#!/bin/bash
# One place defining every target: how to configure it, what compiles it, and
# which repo directories receive the archives.
#
# br_target <name> sets:
#   T_CONF    OpenSSL Configure target
#   T_CC      compiler command line (empty = host cc)
#   T_FLAGS   Configure flags (starts as flags.txt; a target edits the string
#             in place, e.g. "${T_FLAGS/-no-asm/}" to enable asm)
#   T_EXTRA   extra Configure args for this target
#   T_MAKE    make goal (build_libs everywhere - the repo ships only the two archives)
#   T_DEST    space-separated dirs under openssl/libstatic/ that receive the archives
#   T_OBJS    expected libcrypto.a object count
#   T_LIBC    glibc | musl | uclibc | bsd | macos - drives the symbol gates in
#             build.sh and openssl/libstatic/verify. THE list of non-glibc targets;
#             do not restate it anywhere else.
#   T_FETCH   whitespace-separated provisioning tokens: a fetch-toolchains.sh
#             component, or apt:<package>. Empty = host toolchain / bring your own.
#   T_CI      linux | macos - which CI runner family builds it (windows targets
#             live in windows/build.ps1, not here)
#   T_AR/T_RANLIB/T_NM  override only where host binutils can't read the target's
#             archive format (Mach-O)

# osx-*: on a real macOS runner the SDK and clang are already present, so use
# them; osxcross's prefixed clang/ar/ranlib/nm only exist on the Linux cross
# host. Resolved per call, after build-env.sh is sourced (direct `targets.sh
# --field` execution sources it below, later than this file's top level runs).
# The deployment floor comes from the makefile's ARCH_29/ARCH_16 MACOSARCH (one
# home); without it Configure inherits the SDK/host default and the archive's
# minos can exceed the agent's. Empty T_CC means host cc, so on Darwin the flag
# rides on "cc".
_osx_tools() {
    local arm_min x64_min
    arm_min=$(make -s -C "$REPO" ARCHID=29 print-macosarch 2>/dev/null)
    x64_min=$(make -s -C "$REPO" ARCHID=16 print-macosarch 2>/dev/null)
    if [ "$(uname -s)" = Darwin ]; then
        _OSX_ARM_CC="cc $arm_min"; _OSX_X64_CC="cc $x64_min"; _OSX_ARM_TOOLS=; _OSX_X64_TOOLS=
    else
        _OSX_ARM_CC="$OSXCROSS_BIN/aarch64-apple-darwin$OSXCROSS_DARWIN_VER-clang $arm_min"
        _OSX_X64_CC="$OSXCROSS_BIN/x86_64-apple-darwin$OSXCROSS_DARWIN_VER-clang $x64_min"
        _OSX_ARM_TOOLS="$OSXCROSS_BIN/aarch64-apple-darwin$OSXCROSS_DARWIN_VER"
        _OSX_X64_TOOLS="$OSXCROSS_BIN/x86_64-apple-darwin$OSXCROSS_DARWIN_VER"
        # clang finds <triple>-ld via PATH only (see the makefile's macos block).
        case ":$PATH:" in *":$OSXCROSS_BIN:"*) ;; *) export PATH="$OSXCROSS_BIN:$PATH" ;; esac
    fi
}

br_target() {
    _osx_tools
    T_CONF=; T_CC=; T_EXTRA=; T_DEST=; T_AR=; T_RANLIB=; T_NM=; T_OBJS=553; T_FETCH=
    T_LIBC=glibc; T_CI=linux
    # build_libs everywhere: this repo ships only libcrypto.a/libssl.a, and 3.x's
    # apps/fuzz link pulls 64-bit atomics that the 32-bit targets lack.
    T_MAKE=build_libs
    T_FLAGS="$OSSL_FLAGS"
    case "$1" in
    # Native build, AES-NI/SHA-NI/bignum asm, CPUID-gated.
    # Bootlin x86-64-core-i7 glibc 2.24 (pinned, TC_X86_64_BOOTLIN uses the
    # OLDEST Bootlin release for this family, not the shared $_BOOTLIN=2.31 -
    # see env.sh), not apt/host gcc - apt floors at GLIBC_2.34 (libpthread-
    # into-libc merge). -march/-mtune forced back to a generic x86-64
    # baseline: Bootlin's only published x86-64 toolchain name defaults to
    # -march=core-i7, which this target must not inherit (asm modules still
    # gate on runtime CPUID via OPENSSL_ia32cap_P regardless of -march). See
    # meshagent-archid-glibc-floor.md.
    x86-64)         T_CONF=linux-x86_64   ; T_CC="$TC_X86_64_BOOTLIN/bin/x86_64-linux-gcc -march=x86-64 -mtune=generic" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_DEST="linux/x86-64" ; T_FETCH="bootlin-x86-64" ;;
    # Bootlin x86-i686 glibc 2.24 (pinned, same oldest-release reasoning as
    # x86-64 above - see env.sh's TC_X86_BOOTLIN).
    # x86 gates on runtime CPUID (OPENSSL_ia32cap_P), same as x86-64.
    x86)            T_CONF=linux-x86      ; T_CC="$TC_X86_BOOTLIN/bin/i686-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_OBJS=566 ; T_DEST="linux/x86" ; T_FETCH="bootlin-x86" ;;
    # AArch64 gates asm on runtime getauxval(AT_HWCAP) (crypto/armcap.c).
    # ARCHID 32's own compat target: Bootlin aarch64--glibc--stable (glibc 2.31, pinned), matching
    # the agent's own toolchain exactly - the point of this target is a lower glibc floor than
    # mainline arm64 (ARCHID 26/arm64 below), which apt's aarch64-linux-gnu-gcc (GLIBC_2.34 floor)
    # defeated. See meshagent-archid-glibc-floor.md.
    aarch64)        T_CONF=linux-aarch64  ; T_CC="$TC_AARCH64_BOOTLIN/bin/aarch64-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=564 ; T_DEST="linux/aarch64" ; T_FETCH="bootlin-aarch64" ;;
    # General-purpose glibc ARM64 build - no -Os (not space-constrained,
    # unlike aarch64 above).
    arm64)          T_CONF=linux-aarch64  ; T_CC="aarch64-linux-gnu-gcc"    ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=564 ; T_DEST="linux/arm64" ; T_FETCH="apt:gcc-aarch64-linux-gnu" ;;
    # ARMv6 + VFPv2 hard float. -mfpu=vfp: armv6 implies no FPU. -marm:
    # default -mthumb has no hard-float VFP ABI.
    # asm disabled: under qemu-arm it produced wrong crypto results (non-
    # deterministic SHA-384/512, RSA.verify() rejecting its own signature) -
    # unresolved, do not re-enable without root-causing first.
    #
    # ARCHID=27 (armhf2, "Raspbian 7 2015" Pi1 target) used to build this
    # separately with its own toolchain. That toolchain is gone/unreproducible;
    # what replaced it was byte-identical to armhf, so openssl/libstatic/linux/
    # armhf2 is now a symlink to armhf instead of a second build - no armhf2
    # case here anymore. The agent build itself (ARCHID=27, KVM=0) is still
    # a distinct makefile target, it just links the same OpenSSL archive.
    armhf)          T_CONF=linux-armv4    ; T_CC="arm-linux-gnueabihf-gcc -march=armv6 -marm -mfpu=vfp -mfloat-abi=hard" ; T_EXTRA="-Os" ; T_DEST="linux/armhf" ; T_FETCH="apt:gcc-arm-linux-gnueabihf" ;;
    # Bootlin armv5-eabi glibc 2.31 (pinned), not apt - apt's arm-linux-gnueabi-gcc floors at
    # GLIBC_2.34 (libpthread-into-libc merge in glibc 2.34), above what most real ARMv5 hardware
    # (Marvell Kirkwood/Orion plug computers and NAS, 2008-2013) runs. See
    # meshagent-archid-glibc-floor.md. linux-generic32 has no asm modules regardless of flags.
    arm)            T_CONF=linux-generic32; T_CC="$TC_ARMV5_BOOTLIN/bin/arm-linux-gcc" ; T_EXTRA="-Os" ; T_DEST="linux/arm" ; T_FETCH="bootlin-armv5" ;;
    # mips is big-endian, mipsel little-endian; both glibc (apt), both asm -
    # asm builds clean and runs correct crypto under qemu-mipsel.
    mips)           T_CONF=linux-mips32; T_CC="mips-linux-gnu-gcc"   ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mips" ; T_FETCH="apt:gcc-mips-linux-gnu" ;;
    # Bootlin mips32el uClibc (pinned) - matches ARCHID 7's own agent toolchain family. apt's
    # mipsel-linux-gnu-gcc is glibc, which the agent's uClibc build can't link against at all
    # (separate libc, not just a floor difference); the dd-wrt uClibc toolchain ARCHID 7 used to
    # use doesn't build against a current kernel. See meshagent-archid-glibc-floor.md.
    mipsel)         T_CONF=linux-mips32; T_CC="$TC_MIPSEL_UCLIBC_BOOTLIN/bin/mipsel-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mipsel" ; T_FETCH="bootlin-mipsel-uclibc" ; T_LIBC=uclibc ;;
    # musl rv64gc (musl.cc riscv64-linux-musl-cross - same toolchain family the
    # makefile's ARCHID=145 agent build uses). 1.1.1 has no RISC-V asm.
    # NOTE: this case used to say "glibc rv64gc (apt)" and build with
    # riscv64-linux-gnu-gcc while linux/riscv64 was already being consumed as
    # a musl target by the makefile (ARCHID 45/145) - a real mismatch, not a
    # one-off contamination. `defined(__GLIBC__)` from that glibc compile
    # left OpenSSL's ASYNC_POSIX (crypto/async/arch/async_posix.h) compiled
    # in, which musl can never satisfy (no ucontext.h implementation on any
    # arch - see meshagent-static-musl-direction.md) - undetected until an
    # actual agent link was attempted 2026-08-24. Fixed here; also see
    # flags.txt's `no-async` (added the same day - ASYNC has no user in this
    # codebase and no-engine already blocks the only thing that would call
    # it, so disabling it outright is the real fix regardless of libc).
    riscv64)        T_CONF=linux64-riscv64; T_CC="$TC_RISCV64_MUSL/bin/riscv64-linux-musl-gcc" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_DEST="linux/riscv64" ; T_FETCH="muslcc-riscv64" ; T_LIBC=musl ;;
    # glibc rv64gc (apt) - a genuinely separate target from riscv64 above, not
    # currently consumed by any makefile ARCHID (was ad-hoc built previously;
    # now tracked here so a rebuild is reproducible through the normal path).
    riscv64-generic) T_CONF=linux64-riscv64; T_CC="riscv64-linux-gnu-gcc" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_DEST="linux/riscv64-generic" ; T_LIBC=glibc ; T_FETCH="apt:gcc-riscv64-linux-gnu" ;;
    # x86-64 asm, CPUID-gated, libc-agnostic. No -Os: general-purpose
    # container/server distro, not IoT/router.
    alpine-x86-64)  T_CONF=linux-x86_64   ; T_CC="$MUSL_CC"                 ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_DEST="linux/alpine-x86-64" ; T_LIBC=musl ; T_FETCH="apt:musl-tools" ;;
    mips24kc)       T_CONF=linux-mips32; T_CC="$TC_OWRT_MIPS24KC/bin/mips-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPS24KC" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mips24kc" ; T_LIBC=musl ; T_FETCH="openwrt-mips24kc" ;;
    mipsel24kc)     T_CONF=linux-mips32; T_CC="$TC_OWRT_MIPSEL24KC/bin/mipsel-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPSEL24KC" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mipsel24kc" ; T_LIBC=musl ; T_FETCH="openwrt-mipsel24kc" ;;
    openwrt_x86_64) T_CONF=linux-x86_64   ; T_CC="$TC_OWRT_X86_64/bin/x86_64-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_X86_64" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=576 ; T_DEST="linux/openwrt_x86_64" ; T_LIBC=musl ; T_FETCH="openwrt-openwrt_x86_64" ;;
    # No -Os: general-purpose server/desktop OS, not IoT/router. build_libs
    # only - MeshAgent doesn't need the CLI (T_MAKE is build_libs everywhere now).
    freebsd)        T_CONF=BSD-x86_64     ; T_CC="clang --target=$FREEBSD_TRIPLE --sysroot=$SYSROOT_FREEBSD -fuse-ld=lld" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_MAKE=build_libs ; T_DEST="bsd/freebsd_x86-64" ; T_LIBC=bsd ; T_FETCH="apt:clang apt:lld freebsd" ;;
    # build_libs only: the openssl CLI needs crt objects/libcompiler_rt that
    # MeshAgent doesn't use.
    openbsd)        T_CONF=BSD-x86_64     ; T_CC="clang --target=$OPENBSD_TRIPLE --sysroot=$SYSROOT_OPENBSD -fuse-ld=lld" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_MAKE=build_libs ; T_DEST="bsd/openbsd_x86-64" ; T_LIBC=bsd ; T_FETCH="apt:clang apt:lld openbsd" ;;

    # macOS via osxcross. No explicit -target: Configure's darwin64-*-cc
    # targets add -arch themselves, avoiding the osxcross wrapper's argv0-
    # based linker-selection gotcha. T_AR/T_RANLIB/T_NM: host GNU ar/ranlib
    # don't reliably handle Mach-O archives.
    osx-arm-64)     T_CONF=darwin64-arm64-cc  ; T_CC="$_OSX_ARM_CC" ; T_AR="${_OSX_ARM_TOOLS:+$_OSX_ARM_TOOLS-ar}" ; T_RANLIB="${_OSX_ARM_TOOLS:+$_OSX_ARM_TOOLS-ranlib}" ; T_NM="${_OSX_ARM_TOOLS:+$_OSX_ARM_TOOLS-nm}" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=565 ; T_LIBC=macos ; T_CI=macos ; T_DEST="macos/osx-arm-64" ; T_FETCH=osxcross ;;
    osx-x86-64)     T_CONF=darwin64-x86_64-cc ; T_CC="$_OSX_X64_CC" ; T_AR="${_OSX_X64_TOOLS:+$_OSX_X64_TOOLS-ar}" ; T_RANLIB="${_OSX_X64_TOOLS:+$_OSX_X64_TOOLS-ranlib}" ; T_NM="${_OSX_X64_TOOLS:+$_OSX_X64_TOOLS-nm}" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=577 ; T_LIBC=macos ; T_CI=macos ; T_DEST="macos/osx-x86-64" ; T_FETCH=osxcross ;;

    # musl.cc prebuilt cross toolchain (was dd-wrt-archive; dd-wrt is no
    # longer fetched by fetch-toolchains.sh at all - see env.sh's
    # TC_AARCH64_A53_MUSL). ARMv8 crypto extensions are runtime-HWCAP-gated,
    # safe even on cores that lack them.
    aarch64-cortex-a53) T_CONF=linux-aarch64; T_CC="$TC_AARCH64_A53_MUSL/bin/aarch64-linux-musl-gcc -mcpu=cortex-a53" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=564 ; T_DEST="linux/aarch64-cortex-a53" ; T_FETCH="muslcc-aarch64" ; T_LIBC=musl ;;

    # Generic ARMv7 + static musl (Marvell Sheeva/PJ4B is ARMv7-A compatible;
    # cortex-a9 toolchain is a NEON-free portable baseline, not SoC-tuned).
    # Not Synology-specific - won't run on real Synology DSM (glibc).
    # asm disabled: same linux-armv4 crypto-correctness break as armhf.
    linux-armada370-hf) T_CONF=linux-armv4; T_CC="$TC_ARMV7_MUSL_HF/bin/arm-linux-musleabihf-gcc -march=armv7-a -marm -mfpu=vfp -mfloat-abi=hard" ; T_EXTRA="-Os" ; T_DEST="linux/linux-armada370-hf" ; T_LIBC=musl ; T_FETCH="muslcc-armhf" ;;

    # Plain apt arm-linux-gnueabihf-gcc, hardfloat armv7-a+fp.
    # linux-generic32 has no asm modules regardless of flags.
    # Bootlin armv7-eabihf glibc 2.31 (pinned), not apt - same GLIBC_2.34 floor problem as arm
    # above. See meshagent-archid-glibc-floor.md. linux-generic32 has no asm modules regardless.
    arm-linaro)     T_CONF=linux-generic32; T_CC="$TC_ARMV7HF_BOOTLIN/bin/arm-linux-gcc" ; T_EXTRA="-Os" ; T_DEST="linux/arm-linaro" ; T_FETCH="bootlin-armv7hf" ;;

    # Plain apt arm-linux-gnueabi-gcc (no "hf" - softfloat), matching real
    # PogoPlug hardware's ABI (ARMv5TE, softfloat). linux-generic32 has no
    # asm modules regardless of flags.
    pogo)           T_CONF=linux-generic32; T_CC="arm-linux-gnueabi-gcc"      ; T_EXTRA="-Os" ; T_DEST="linux/pogo" ; T_FETCH="apt:gcc-arm-linux-gnueabi" ;;

    # Disabled: Intel Galileo (Quark X1000) EOL since 2016, no current SDK.
    # poky)         T_CONF=linux-generic32; T_CC="???"; T_DEST="linux/poky" ;;

    # No ARCHID currently links this - kept for continuity, not agent-consumed.
    # The real Yocto 1.6.1 x86_64-poky-linux SDK the old openssl-poky64 script
    # used (/opt/poky/1.6.1/...) is defunct: no public URL, ~2014-era, not
    # reproducible on any machine today. Stands in with the host's native
    # glibc instead (linux-generic64, no cross toolchain) - matches
    # tracked here so CI builds it through the same path as everything else,
    # instead of poky64 being silently absent from the canonical list.
    poky64)         T_CONF=linux-generic64; T_CC=""; T_EXTRA="enable-ec_nistp_64_gcc_128"; T_DEST="linux/poky64" ;;

    *) return 1 ;;
    esac
    return 0
}

BR_ALL_TARGETS="x86-64 x86 aarch64 arm64 armhf arm mips mipsel riscv64 riscv64-generic alpine-x86-64 \
mips24kc mipsel24kc openwrt_x86_64 freebsd openbsd \
aarch64-cortex-a53 linux-armada370-hf arm-linaro pogo poky64 \
osx-arm-64 osx-x86-64"

# Names only, optionally filtered by T_CI - this is what the CI matrix is built
# from, so a new target is picked up by CI the moment it is added above.
print_target_names() {
    local t
    for t in $BR_ALL_TARGETS; do
        br_target "$t" || continue
        [ -z "${1:-}" ] || [ "$T_CI" = "$1" ] || continue
        echo "$t"
    done
}

# One field of one target, for shell/CI callers that want a single value.
print_target_field() {
    br_target "$1" || { echo "unknown target: $1" >&2; return 1; }
    eval "printf '%s\\n' \"\$T_$2\""
}

# Direct execution (not sourced): `targets.sh --names|--field`. Sourcing
# (`. targets.sh`) still just defines br_target/BR_ALL_TARGETS as before -
# this block only runs when the file is the actual script being executed.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    . "$(dirname "$(readlink -f "$0")")/../../../build-env.sh" >/dev/null
    case "${1:-}" in
        --names)  print_target_names "${2:-}" ;;
        --field)  print_target_field "$2" "$3" ;;
        *) echo "usage: $(basename "$0") --names [ci] | --field <target> <FIELD>" >&2; exit 2 ;;
    esac
fi
