#!/bin/bash
# One place defining every target: how to configure it, what compiles it, and
# which repo directories receive the archives.
#
# br_target <name> sets: T_CONF T_CC T_EXTRA T_MAKE T_DEST T_AR T_RANLIB T_NM
# T_DEST is space separated, relative to openssl/libstatic/ in the repo.
# T_AR/T_RANLIB default to plain "ar"/"ranlib" (build.sh) - override only
# where the host's tools can't read the target's archive format (Mach-O).

br_target() {
    T_CONF=; T_CC=; T_EXTRA=; T_MAKE=; T_DEST=; T_AR=; T_RANLIB=; T_NM=; T_FLAGS="$OSSL_FLAGS"; T_OBJS=553
    case "$1" in
    # Native build, AES-NI/SHA-NI/bignum asm, CPUID-gated.
    x86-64)         T_CONF=linux-x86_64   ; T_CC="gcc"                      ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_DEST="linux/x86-64" ;;
    # x86 gates on runtime CPUID (OPENSSL_ia32cap_P), same as x86-64.
    x86)            T_CONF=linux-x86      ; T_CC="gcc -m32"                 ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_OBJS=566 ; T_DEST="linux/x86" ;;
    # AArch64 gates asm on runtime getauxval(AT_HWCAP) (crypto/armcap.c).
    aarch64)        T_CONF=linux-aarch64  ; T_CC="aarch64-linux-gnu-gcc"    ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=564 ; T_DEST="linux/aarch64" ;;
    # General-purpose glibc ARM64 build - no -Os (not space-constrained,
    # unlike aarch64 above).
    arm64)          T_CONF=linux-aarch64  ; T_CC="aarch64-linux-gnu-gcc"    ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=564 ; T_DEST="linux/arm64" ;;
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
    armhf)          T_CONF=linux-armv4    ; T_CC="arm-linux-gnueabihf-gcc -march=armv6 -marm -mfpu=vfp -mfloat-abi=hard" ; T_EXTRA="-Os" ; T_DEST="linux/armhf" ;;
    arm)            T_CONF=linux-generic32; T_CC="arm-linux-gnueabi-gcc"    ; T_EXTRA="-Os" ; T_DEST="linux/arm" ;;
    # Both MIPS dirs are little-endian, musl (dd-wrt/OpenWrt share the same
    # musl toolchain lineage now). asm builds clean and runs correct crypto
    # under qemu-mipsel.
    mips)           T_CONF=linux-mips32; T_CC="$TC_MIPS32EL_MUSL/bin/mipsel-openwrt-linux-musl-gcc" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mips linux/mipsel" ;;
    # Agent is musl; -march=rv64gc for RVC, which the toolchain default omits.
    riscv64)        T_CONF=linux64-riscv64; T_CC="$TC_RISCV64_MUSL/bin/riscv64-linux-gcc -march=rv64gc -mabi=lp64d" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_DEST="linux/riscv64" ;;
    # x86-64 asm, CPUID-gated, libc-agnostic. No -Os: general-purpose
    # container/server distro, not IoT/router.
    alpine-x86-64)  T_CONF=linux-x86_64   ; T_CC="$MUSL_CC"                 ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_DEST="linux/alpine-x86-64" ;;
    mips24kc)       T_CONF=linux-generic32; T_CC="$TC_OWRT_MIPS24KC/bin/mips-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPS24KC" ; T_EXTRA="-Os" ; T_DEST="linux/mips24kc" ;;
    mipsel24kc)     T_CONF=linux-generic32; T_CC="$TC_OWRT_MIPSEL24KC/bin/mipsel-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPSEL24KC" ; T_EXTRA="-Os" ; T_DEST="linux/mipsel24kc" ;;
    openwrt_x86_64) T_CONF=linux-x86_64   ; T_CC="$TC_OWRT_X86_64/bin/x86_64-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_X86_64" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=576 ; T_DEST="linux/openwrt_x86_64" ;;
    # No -Os: general-purpose server/desktop OS, not IoT/router.
    freebsd)        T_CONF=BSD-x86_64     ; T_CC="clang --target=$FREEBSD_TRIPLE --sysroot=$SYSROOT_FREEBSD -fuse-ld=lld" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_DEST="bsd/freebsd_x86-64" ;;
    # build_libs only: the openssl CLI needs crt objects/libcompiler_rt that
    # MeshAgent doesn't use.
    openbsd)        T_CONF=BSD-x86_64     ; T_CC="clang --target=$OPENBSD_TRIPLE --sysroot=$SYSROOT_OPENBSD -fuse-ld=lld" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_MAKE=build_libs ; T_DEST="bsd/openbsd_x86-64" ;;

    # macOS via osxcross. No explicit -target: Configure's darwin64-*-cc
    # targets add -arch themselves, avoiding the osxcross wrapper's argv0-
    # based linker-selection gotcha. T_AR/T_RANLIB/T_NM: host GNU ar/ranlib
    # don't reliably handle Mach-O archives.
    osx-arm-64)     T_CONF=darwin64-arm64-cc  ; T_CC="$OSXCROSS_BIN/aarch64-apple-darwin$OSXCROSS_DARWIN_VER-clang" ; T_AR="$OSXCROSS_BIN/aarch64-apple-darwin$OSXCROSS_DARWIN_VER-ar" ; T_RANLIB="$OSXCROSS_BIN/aarch64-apple-darwin$OSXCROSS_DARWIN_VER-ranlib" ; T_NM="$OSXCROSS_BIN/aarch64-apple-darwin$OSXCROSS_DARWIN_VER-nm" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=565 ; T_MAKE=build_libs ; T_DEST="macos/osx-arm-64" ;;
    osx-x86-64)     T_CONF=darwin64-x86_64-cc ; T_CC="$OSXCROSS_BIN/x86_64-apple-darwin$OSXCROSS_DARWIN_VER-clang" ; T_AR="$OSXCROSS_BIN/x86_64-apple-darwin$OSXCROSS_DARWIN_VER-ar" ; T_RANLIB="$OSXCROSS_BIN/x86_64-apple-darwin$OSXCROSS_DARWIN_VER-ranlib" ; T_NM="$OSXCROSS_BIN/x86_64-apple-darwin$OSXCROSS_DARWIN_VER-nm" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=577 ; T_MAKE=build_libs ; T_DEST="macos/osx-x86-64" ;;

    # dd-wrt-archive toolchain. ARMv8 crypto extensions are runtime-HWCAP-
    # gated, safe even on cores that lack them.
    aarch64-cortex-a53) T_CONF=linux-aarch64; T_CC="$TC_AARCH64_CORTEXA53_MUSL/bin/aarch64-openwrt-linux-musl-gcc" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=564 ; T_DEST="linux/aarch64-cortex-a53" ;;

    # Generic ARMv7 + static musl (Marvell Sheeva/PJ4B is ARMv7-A compatible;
    # cortex-a9 toolchain is a NEON-free portable baseline, not SoC-tuned).
    # Not Synology-specific - won't run on real Synology DSM (glibc).
    # asm disabled: same linux-armv4 crypto-correctness break as armhf.
    linux-armada370-hf) T_CONF=linux-armv4; T_CC="$TC_ARMV7_CORTEXA9_MUSL/bin/arm-openwrt-linux-muslgnueabi-gcc" ; T_EXTRA="-Os" ; T_DEST="linux/linux-armada370-hf" ;;

    # Plain apt arm-linux-gnueabihf-gcc, hardfloat armv7-a+fp.
    # linux-generic32 has no asm modules regardless of flags.
    arm-linaro)     T_CONF=linux-generic32; T_CC="arm-linux-gnueabihf-gcc"    ; T_EXTRA="-Os" ; T_DEST="linux/arm-linaro" ;;

    # Plain apt arm-linux-gnueabi-gcc (no "hf" - softfloat), matching real
    # PogoPlug hardware's ABI (ARMv5TE, softfloat). linux-generic32 has no
    # asm modules regardless of flags.
    pogo)           T_CONF=linux-generic32; T_CC="arm-linux-gnueabi-gcc"      ; T_EXTRA="-Os" ; T_DEST="linux/pogo" ;;

    # Disabled: Intel Galileo (Quark X1000) EOL since 2016, no current SDK.
    # poky)         T_CONF=linux-generic32; T_CC="???"; T_DEST="linux/poky" ;;

    *) return 1 ;;
    esac
    return 0
}

BR_ALL_TARGETS="x86-64 x86 aarch64 arm64 armhf arm mips riscv64 alpine-x86-64 \
mips24kc mipsel24kc openwrt_x86_64 freebsd openbsd \
aarch64-cortex-a53 linux-armada370-hf arm-linaro pogo \
osx-arm-64 osx-x86-64"
