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
    # Bootlin x86-64-core-i7 glibc 2.31 (pinned), not apt/host gcc - apt floors at
    # GLIBC_2.34 (libpthread-into-libc merge). -march/-mtune forced back to a
    # generic x86-64 baseline: Bootlin's only published x86-64 toolchain name
    # defaults to -march=core-i7, which this target must not inherit (asm modules
    # still gate on runtime CPUID via OPENSSL_ia32cap_P regardless of -march).
    # See meshagent-archid-glibc-floor.md.
    x86-64)         T_CONF=linux-x86_64   ; T_CC="$TC_X86_64_BOOTLIN/bin/x86_64-linux-gcc -march=x86-64 -mtune=generic" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_DEST="linux/x86-64" ;;
    # Bootlin x86-i686 glibc 2.31 (pinned) - same floor fix as x86-64 above.
    # x86 gates on runtime CPUID (OPENSSL_ia32cap_P), same as x86-64.
    x86)            T_CONF=linux-x86      ; T_CC="$TC_X86_BOOTLIN/bin/i686-linux-gcc" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_OBJS=566 ; T_DEST="linux/x86" ;;
    # AArch64 gates asm on runtime getauxval(AT_HWCAP) (crypto/armcap.c).
    # ARCHID 32's own compat target: Bootlin aarch64--glibc--stable (glibc 2.31, pinned), matching
    # the agent's own toolchain exactly - the point of this target is a lower glibc floor than
    # mainline arm64 (ARCHID 26/arm64 below), which apt's aarch64-linux-gnu-gcc (GLIBC_2.34 floor)
    # defeated. See meshagent-archid-glibc-floor.md.
    aarch64)        T_CONF=linux-aarch64  ; T_CC="$TC_AARCH64_BOOTLIN/bin/aarch64-linux-gcc" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=564 ; T_DEST="linux/aarch64" ;;
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
    # Bootlin armv5-eabi glibc 2.31 (pinned), not apt - apt's arm-linux-gnueabi-gcc floors at
    # GLIBC_2.34 (libpthread-into-libc merge in glibc 2.34), above what most real ARMv5 hardware
    # (Marvell Kirkwood/Orion plug computers and NAS, 2008-2013) runs. See
    # meshagent-archid-glibc-floor.md. linux-generic32 has no asm modules regardless of flags.
    arm)            T_CONF=linux-generic32; T_CC="$TC_ARMV5_BOOTLIN/bin/arm-linux-gcc" ; T_EXTRA="-Os" ; T_DEST="linux/arm" ;;
    # mips is big-endian, mipsel little-endian; both glibc (apt), both asm -
    # asm builds clean and runs correct crypto under qemu-mipsel.
    mips)           T_CONF=linux-mips32; T_CC="mips-linux-gnu-gcc"   ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mips" ;;
    # Bootlin mips32el uClibc (pinned) - matches ARCHID 7's own agent toolchain family. apt's
    # mipsel-linux-gnu-gcc is glibc, which the agent's uClibc build can't link against at all
    # (separate libc, not just a floor difference); the dd-wrt uClibc toolchain ARCHID 7 used to
    # use doesn't build against a current kernel. See meshagent-archid-glibc-floor.md.
    mipsel)         T_CONF=linux-mips32; T_CC="$TC_MIPSEL_UCLIBC_BOOTLIN/bin/mipsel-linux-gcc" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mipsel" ;;
    # glibc rv64gc (apt). 1.1.1 has no RISC-V asm; rv64gc also runs on T-Head C906.
    riscv64)        T_CONF=linux64-riscv64; T_CC="riscv64-linux-gnu-gcc" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_DEST="linux/riscv64" ;;
    # x86-64 asm, CPUID-gated, libc-agnostic. No -Os: general-purpose
    # container/server distro, not IoT/router.
    alpine-x86-64)  T_CONF=linux-x86_64   ; T_CC="$MUSL_CC"                 ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_DEST="linux/alpine-x86-64" ;;
    mips24kc)       T_CONF=linux-mips32; T_CC="$TC_OWRT_MIPS24KC/bin/mips-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPS24KC" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mips24kc" ;;
    mipsel24kc)     T_CONF=linux-mips32; T_CC="$TC_OWRT_MIPSEL24KC/bin/mipsel-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPSEL24KC" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_OBJS=556 ; T_DEST="linux/mipsel24kc" ;;
    openwrt_x86_64) T_CONF=linux-x86_64   ; T_CC="$TC_OWRT_X86_64/bin/x86_64-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_X86_64" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=576 ; T_DEST="linux/openwrt_x86_64" ;;
    # No -Os: general-purpose server/desktop OS, not IoT/router. build_libs
    # only, matching openssl-bsd.yml exactly - MeshAgent doesn't need the CLI.
    freebsd)        T_CONF=BSD-x86_64     ; T_CC="clang --target=$FREEBSD_TRIPLE --sysroot=$SYSROOT_FREEBSD -fuse-ld=lld" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_OBJS=576 ; T_MAKE=build_libs ; T_DEST="bsd/freebsd_x86-64" ;;
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
    aarch64-cortex-a53) T_CONF=linux-aarch64; T_CC="$TC_AARCH64_A53_MUSL/bin/aarch64-linux-musl-gcc -mcpu=cortex-a53" ; T_FLAGS="${OSSL_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_OBJS=564 ; T_DEST="linux/aarch64-cortex-a53" ;;

    # Generic ARMv7 + static musl (Marvell Sheeva/PJ4B is ARMv7-A compatible;
    # cortex-a9 toolchain is a NEON-free portable baseline, not SoC-tuned).
    # Not Synology-specific - won't run on real Synology DSM (glibc).
    # asm disabled: same linux-armv4 crypto-correctness break as armhf.
    linux-armada370-hf) T_CONF=linux-armv4; T_CC="$TC_ARMV7_MUSL_HF/bin/arm-linux-musleabihf-gcc -march=armv7-a -marm -mfpu=vfp -mfloat-abi=hard" ; T_EXTRA="-Os" ; T_DEST="linux/linux-armada370-hf" ;;

    # Plain apt arm-linux-gnueabihf-gcc, hardfloat armv7-a+fp.
    # linux-generic32 has no asm modules regardless of flags.
    # Bootlin armv7-eabihf glibc 2.31 (pinned), not apt - same GLIBC_2.34 floor problem as arm
    # above. See meshagent-archid-glibc-floor.md. linux-generic32 has no asm modules regardless.
    arm-linaro)     T_CONF=linux-generic32; T_CC="$TC_ARMV7HF_BOOTLIN/bin/arm-linux-gcc" ; T_EXTRA="-Os" ; T_DEST="linux/arm-linaro" ;;

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

BR_ALL_TARGETS="x86-64 x86 aarch64 arm64 armhf arm mips mipsel riscv64 alpine-x86-64 \
mips24kc mipsel24kc openwrt_x86_64 freebsd openbsd \
aarch64-cortex-a53 linux-armada370-hf arm-linaro pogo \
osx-arm-64 osx-x86-64"
