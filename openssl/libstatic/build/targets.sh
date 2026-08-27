#!/bin/bash
# The one place defining every target: how it is configured, what compiles it, and which
# repo directories receive the archives. br_target <name> sets the T_ variables, and T_LIBC
# is the only list of non-glibc targets. The fields are documented in openssl/libstatic/build/README.md.

# A real macOS runner already has clang and the SDK, while the osxcross prefixed tools only
# exist on a Linux cross host, so this is resolved per call after build-env.sh is sourced.
# The deployment floor comes from the makefile's MACOSARCH so the archive's minos never exceeds the agent's.
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
        # clang can only find the prefixed ld through PATH, as the makefile's macos block explains.
        case ":$PATH:" in *":$OSXCROSS_BIN:"*) ;; *) export PATH="$OSXCROSS_BIN:$PATH" ;; esac
    fi
}

br_target() {
    _osx_tools
    T_CONF=; T_CC=; T_EXTRA=; T_DEST=; T_AR=; T_RANLIB=; T_NM=; T_OBJS=553; T_FETCH=
    T_LIBC=glibc; T_CI=linux
    # build_libs everywhere, because the repo ships only the two archives and the 3.x
    # apps and fuzz link needs 64-bit atomics that the 32-bit targets lack.
    T_MAKE=build_libs
    T_FLAGS="$OSSL_FLAGS"
    case "$1" in
    # Uses the pinned Bootlin glibc 2.24 toolchain because apt gcc floors at GLIBC_2.34. The
    # -march=x86-64 -mtune=generic override is needed because that toolchain defaults to core-i7.
    # The asm modules still gate on runtime CPUID. See ISSUES.md.
    x86-64)         T_CONF=linux-x86_64   ; T_CC="$TC_X86_64_BOOTLIN/bin/x86_64-linux-gcc -march=x86-64 -mtune=generic" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_DEST="linux/x86-64" ; T_FETCH="bootlin-x86-64" ;;
    # Uses the pinned Bootlin glibc 2.24 toolchain for the same floor reason as x86-64 above.
    # The asm modules gate on runtime CPUID, just as on x86-64.
    x86)            T_CONF=linux-x86      ; T_CC="$TC_X86_BOOTLIN/bin/i686-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_OBJS=566 ; T_DEST="linux/x86" ; T_FETCH="bootlin-x86" ;;
    # The compat target for ARCHID 32. It exists for a lower glibc floor than arm64 below, so it
    # must use the pinned Bootlin glibc 2.31 toolchain that matches the agent's own, not apt's
    # GLIBC_2.34 gcc. AArch64 asm gates on runtime AT_HWCAP. See ISSUES.md.
    aarch64)        T_CONF=linux-aarch64  ; T_CC="$TC_AARCH64_BOOTLIN/bin/aarch64-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=564 ; T_DEST="linux/aarch64" ; T_FETCH="bootlin-aarch64" ;;
    # General-purpose glibc ARM64 build. No -Os because it is not space-constrained like aarch64 above.
    arm64)          T_CONF=linux-aarch64  ; T_CC="aarch64-linux-gnu-gcc"    ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=564 ; T_DEST="linux/arm64" ; T_FETCH="apt:gcc-aarch64-linux-gnu" ;;
    # -mfpu=vfp and -marm are needed because armv6 implies no FPU and thumb has no hard-float ABI.
    # asm stays disabled: under qemu-arm it produced wrong crypto results, still unresolved.
    # ARCHID 27 now links this same archive through a symlink. See ISSUES.md.
    armhf)          T_CONF=linux-armv4    ; T_CC="arm-linux-gnueabihf-gcc -march=armv6 -marm -mfpu=vfp -mfloat-abi=hard" ; T_EXTRA="-Os" ; T_DEST="linux/armhf" ; T_FETCH="apt:gcc-arm-linux-gnueabihf" ;;
    # Uses the pinned Bootlin glibc 2.31 toolchain because apt's gcc floors at GLIBC_2.34, above
    # what real ARMv5 hardware runs. linux-generic32 has no asm modules regardless of flags.
    # See ISSUES.md.
    arm)            T_CONF=linux-generic32; T_CC="$TC_ARMV5_BOOTLIN/bin/arm-linux-gcc" ; T_EXTRA="-Os" ; T_DEST="linux/arm" ; T_FETCH="bootlin-armv5" ;;
    # mips is big-endian and mipsel is little-endian. asm is enabled on both because it
    # builds clean and runs correct crypto under qemu-mipsel.
    mips)           T_CONF=linux-mips32; T_CC="mips-linux-gnu-gcc"   ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mips" ; T_FETCH="apt:gcc-mips-linux-gnu" ;;
    # Uses the pinned Bootlin uClibc toolchain because ARCHID 7's agent is uClibc and cannot link
    # a glibc archive at all. The old dd-wrt toolchain no longer builds on a current kernel.
    # See ISSUES.md.
    mipsel)         T_CONF=linux-mips32; T_CC="$TC_MIPSEL_UCLIBC_BOOTLIN/bin/mipsel-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mipsel" ; T_FETCH="bootlin-mipsel-uclibc" ; T_LIBC=uclibc ;;
    # Must be musl, because the makefile's ARCHID 45 and 145 agents link linux/riscv64 as musl.
    # A glibc build here once left ASYNC_POSIX compiled in, which musl cannot satisfy, so the
    # agent link failed. 1.1.1 has no RISC-V asm. See openssl/libstatic/build/README.md.
    riscv64)        T_CONF=linux64-riscv64; T_CC="$TC_RISCV64_MUSL/bin/riscv64-linux-musl-gcc" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_DEST="linux/riscv64" ; T_FETCH="muslcc-riscv64" ; T_LIBC=musl ;;
    riscv64-generic) T_CONF=linux64-riscv64; T_CC="$TC_RISCV64_MUSL/bin/riscv64-linux-musl-gcc" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_DEST="linux/riscv64-generic" ; T_LIBC=musl ; T_FETCH="muslcc-riscv64" ;;
    # OpenSSL 1.1.1 has no riscv32 Configure target (only linux64-riscv64/BSD-riscv64 exist), so
    # this Configures as linux-generic32 like arm/arm-linaro/pogo - no asm modules regardless of flags.
    riscv32-generic) T_CONF=linux-generic32; T_CC="$TC_RISCV32_MUSL/bin/riscv32-linux-musl-gcc" ; T_EXTRA="-Os" ; T_DEST="linux/riscv32-generic" ; T_LIBC=musl ; T_FETCH="muslcc-riscv32" ;;
    # x86-64 asm is CPUID-gated and works on any libc. No -Os because Alpine is a
    # general-purpose distro, not a space-constrained router.
    alpine-x86-64)  T_CONF=linux-x86_64   ; T_CC="$MUSL_CC"                 ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_DEST="linux/alpine-x86-64" ; T_LIBC=musl ; T_FETCH="apt:musl-tools" ;;
    mips24kc)       T_CONF=linux-mips32; T_CC="$TC_OWRT_MIPS24KC/bin/mips-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPS24KC" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mips24kc" ; T_LIBC=musl ; T_FETCH="openwrt-mips24kc" ;;
    mipsel24kc)     T_CONF=linux-mips32; T_CC="$TC_OWRT_MIPSEL24KC/bin/mipsel-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPSEL24KC" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mipsel24kc" ; T_LIBC=musl ; T_FETCH="openwrt-mipsel24kc" ;;
    openwrt_x86_64) T_CONF=linux-x86_64   ; T_CC="$TC_OWRT_X86_64/bin/x86_64-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_X86_64" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=576 ; T_DEST="linux/openwrt_x86_64" ; T_LIBC=musl ; T_FETCH="openwrt-openwrt_x86_64" ;;
    # No -Os because FreeBSD is a general-purpose OS, not a space-constrained router.
    freebsd)        T_CONF=BSD-x86_64     ; T_CC="clang --target=$FREEBSD_TRIPLE --sysroot=$SYSROOT_FREEBSD -fuse-ld=lld" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_MAKE=build_libs ; T_DEST="bsd/freebsd_x86-64" ; T_LIBC=bsd ; T_FETCH="apt:clang apt:lld freebsd" ;;
    # build_libs only, because the openssl CLI needs crt objects and libcompiler_rt that
    # MeshAgent does not use.
    openbsd)        T_CONF=BSD-x86_64     ; T_CC="clang --target=$OPENBSD_TRIPLE --sysroot=$SYSROOT_OPENBSD -fuse-ld=lld" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_MAKE=build_libs ; T_DEST="bsd/openbsd_x86-64" ; T_LIBC=bsd ; T_FETCH="apt:clang apt:lld openbsd" ;;

    # No explicit -target, because the darwin64 Configure targets add -arch themselves and an
    # explicit one breaks the osxcross wrapper's linker selection. The T_AR, T_RANLIB and T_NM
    # overrides exist because host GNU binutils do not reliably handle Mach-O archives.
    osx-arm-64)     T_CONF=darwin64-arm64-cc  ; T_CC="$_OSX_ARM_CC" ; T_AR="${_OSX_ARM_TOOLS:+$_OSX_ARM_TOOLS-ar}" ; T_RANLIB="${_OSX_ARM_TOOLS:+$_OSX_ARM_TOOLS-ranlib}" ; T_NM="${_OSX_ARM_TOOLS:+$_OSX_ARM_TOOLS-nm}" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=565 ; T_LIBC=macos ; T_CI=macos ; T_DEST="macos/osx-arm-64" ; T_FETCH=osxcross ;;
    osx-x86-64)     T_CONF=darwin64-x86_64-cc ; T_CC="$_OSX_X64_CC" ; T_AR="${_OSX_X64_TOOLS:+$_OSX_X64_TOOLS-ar}" ; T_RANLIB="${_OSX_X64_TOOLS:+$_OSX_X64_TOOLS-ranlib}" ; T_NM="${_OSX_X64_TOOLS:+$_OSX_X64_TOOLS-nm}" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=577 ; T_LIBC=macos ; T_CI=macos ; T_DEST="macos/osx-x86-64" ; T_FETCH=osxcross ;;

    # Uses the musl.cc prebuilt toolchain, since fetch-toolchains.sh no longer fetches dd-wrt.
    # The ARMv8 crypto extensions are runtime-HWCAP-gated, so cores that lack them are safe.
    aarch64-cortex-a53) T_CONF=linux-aarch64; T_CC="$TC_AARCH64_A53_MUSL/bin/aarch64-linux-musl-gcc -mcpu=cortex-a53" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=564 ; T_DEST="linux/aarch64-cortex-a53" ; T_FETCH="muslcc-aarch64" ; T_LIBC=musl ;;

    # Generic ARMv7 static musl, a NEON-free portable baseline rather than an SoC-tuned build.
    # It will not run on real Synology DSM, which is glibc.
    # asm stays disabled because of the same linux-armv4 crypto-correctness break as armhf.
    linux-armada370-hf) T_CONF=linux-armv4; T_CC="$TC_ARMV7_MUSL_HF/bin/arm-linux-musleabihf-gcc -march=armv7-a -marm -mfpu=vfp -mfloat-abi=hard" ; T_EXTRA="-Os" ; T_DEST="linux/linux-armada370-hf" ; T_LIBC=musl ; T_FETCH="muslcc-armhf" ;;

    # Hardfloat ARMv7 on the pinned Bootlin glibc 2.31 toolchain, for the same GLIBC_2.34 floor
    # reason as arm above. linux-generic32 has no asm modules regardless of flags.
    # See ISSUES.md.
    arm-linaro)     T_CONF=linux-generic32; T_CC="$TC_ARMV7HF_BOOTLIN/bin/arm-linux-gcc" ; T_EXTRA="-Os" ; T_DEST="linux/arm-linaro" ; T_FETCH="bootlin-armv7hf" ;;

    # Softfloat apt toolchain, because real PogoPlug hardware is ARMv5TE softfloat.
    # linux-generic32 has no asm modules regardless of flags.
    pogo)           T_CONF=linux-generic32; T_CC="arm-linux-gnueabi-gcc"      ; T_EXTRA="-Os" ; T_DEST="linux/pogo" ; T_FETCH="apt:gcc-arm-linux-gnueabi" ;;

    # Disabled because the Intel Galileo has been end of life since 2016 and has no current SDK.
    # poky)         T_CONF=linux-generic32; T_CC="???"; T_DEST="linux/poky" ;;

    # No ARCHID links this. The original Yocto 1.6.1 SDK under /opt/poky/1.6.1/ is defunct and
    # not reproducible, so the host's native glibc stands in. It stays in the table so CI builds
    # it through the same path as everything else instead of silently dropping it.
    poky64)         T_CONF=linux-generic64; T_CC=""; T_EXTRA="enable-ec_nistp_64_gcc_128"; T_DEST="linux/poky64" ;;

    *) return 1 ;;
    esac
    return 0
}

BR_ALL_TARGETS="x86-64 x86 aarch64 arm64 armhf arm mips mipsel riscv64 riscv64-generic riscv32-generic alpine-x86-64 \
mips24kc mipsel24kc openwrt_x86_64 freebsd openbsd \
aarch64-cortex-a53 linux-armada370-hf arm-linaro pogo poky64 \
osx-arm-64 osx-x86-64"

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
    . "$(dirname "$(readlink -f "$0")")/../../../build-env.sh" >/dev/null
    case "${1:-}" in
        --names)  print_target_names "${2:-}" ;;
        --field)  print_target_field "$2" "$3" ;;
        *) echo "usage: $(basename "$0") --names [ci] | --field <target> <FIELD>" >&2; exit 2 ;;
    esac
fi
