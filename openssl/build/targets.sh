#!/bin/bash
# The one place defining every OpenSSL target: how it is configured and what compiles it.
# A target is named by what decides link compatibility, <os>-<arch/abi>-<libc>, never by a
# board or distribution, and its archives live in openssl/<version>/<target>/. br_target <name>
# sets the T_ variables. The fields are documented in openssl/build/README.md.

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
    T_CONF=; T_CC=; T_EXTRA=; T_AR=; T_RANLIB=; T_NM=; T_FETCH=
    T_LIBC=glibc; T_CI=linux
    # build_libs everywhere, because the repo ships only the two archives and the 3.x
    # apps and fuzz link needs 64-bit atomics that the 32-bit targets lack.
    T_MAKE=build_libs
    T_FLAGS="$OSSL_FLAGS"
    case "$1" in
    # Pinned Bootlin glibc 2.24 toolchains, because apt gcc floors at GLIBC_2.34. The x86-64
    # -march override is needed because that toolchain defaults to core-i7. The asm modules
    # gate on runtime CPUID.
    linux-x86_64-glibc) T_CONF=linux-x86_64 ; T_CC="$TC_X86_64_BOOTLIN/bin/x86_64-linux-gcc -march=x86-64 -mtune=generic" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_FETCH="bootlin-x86-64" ;;
    linux-i686-glibc)   T_CONF=linux-x86    ; T_CC="$TC_X86_BOOTLIN/bin/i686-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_FETCH="bootlin-x86" ;;
    # x86-64 asm is CPUID-gated and works on any libc. Serves Alpine and OpenWrt x86-64 alike,
    # so no -Os: the archive is shared and the general-purpose use favours speed.
    linux-x86_64-musl)  T_CONF=linux-x86_64 ; T_CC="$MUSL_CC" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=musl ; T_FETCH="apt:musl-tools" ;;
    # The pinned Bootlin glibc 2.31 toolchain gives the lowest floor, so one archive serves both
    # the compat ARCHID 32 and the general ARCHID 26. AArch64 asm gates on runtime AT_HWCAP.
    linux-aarch64-glibc) T_CONF=linux-aarch64 ; T_CC="$TC_AARCH64_BOOTLIN/bin/aarch64-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -O2" ; T_FETCH="bootlin-aarch64" ;;
    # sparcv9 asm on since 2026-08-28. No hardware here, so it is validated under qemu-sparc64 only.
    linux-sparc64-glibc) T_CONF=linux64-sparcv9 ; T_CC="$TC_SPARC64_BOOTLIN/bin/sparc64-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_FETCH="bootlin-sparc64" ;;
    linux-ppc64le-glibc) T_CONF=linux-ppc64le ; T_CC="$TC_POWERPC64LE_BOOTLIN/bin/powerpc64le-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_FETCH="bootlin-powerpc64le" ;;
    # musl.cc toolchain. The ARMv8 crypto extensions are runtime-HWCAP-gated, so plain armv8-a
    # code is generated and cores with or without them are both safe.
    linux-aarch64-musl) T_CONF=linux-aarch64 ; T_CC="$TC_AARCH64_A53_MUSL/bin/aarch64-linux-musl-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -O2" ; T_LIBC=musl ; T_FETCH="muslcc-aarch64" ;;
    # -mfpu=vfp and -marm are needed because armv6 implies no FPU and thumb has no hard-float ABI.
    # asm stays disabled: under qemu-arm it produced wrong crypto results, still unresolved.
    linux-armv6hf-glibc) T_CONF=linux-armv4 ; T_CC="arm-linux-gnueabihf-gcc -march=armv6 -marm -mfpu=vfp -mfloat-abi=hard" ; T_EXTRA="-Os" ; T_FETCH="apt:gcc-arm-linux-gnueabihf" ;;
    # Hardfloat ARMv7 on the pinned Bootlin glibc 2.31 toolchain, because apt's gcc floors at
    # GLIBC_2.34. linux-generic32 has no asm modules regardless of flags.
    linux-armv7hf-glibc) T_CONF=linux-generic32 ; T_CC="$TC_ARMV7HF_BOOTLIN/bin/arm-linux-gcc" ; T_EXTRA="-Os" ; T_FETCH="bootlin-armv7hf" ;;
    # Generic ARMv7 static musl, a NEON-free portable baseline rather than an SoC-tuned build.
    # asm stays disabled because of the same linux-armv4 crypto-correctness break as armv6hf.
    linux-armv7hf-musl) T_CONF=linux-armv4 ; T_CC="$TC_ARMV7_MUSL_HF/bin/arm-linux-musleabihf-gcc -march=armv7-a -marm -mfpu=vfp -mfloat-abi=hard" ; T_EXTRA="-Os" ; T_LIBC=musl ; T_FETCH="muslcc-armhf" ;;
    # Softfloat ARMv5 on the pinned Bootlin glibc 2.31 toolchain, for the same floor reason.
    # linux-generic32 has no asm modules regardless of flags.
    linux-armv5-glibc)  T_CONF=linux-generic32 ; T_CC="$TC_ARMV5_BOOTLIN/bin/arm-linux-gcc" ; T_EXTRA="-Os" ; T_FETCH="bootlin-armv5" ;;
    # Little-endian MIPS on the pinned Bootlin uClibc toolchain, because ARCHID 7's agent is
    # uClibc and cannot link a glibc archive at all. asm runs correct crypto under qemu-mipsel.
    linux-mipsel-uclibc) T_CONF=linux-mips32 ; T_CC="$TC_MIPSEL_UCLIBC_BOOTLIN/bin/mipsel-linux-gcc" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_LIBC=uclibc ; T_FETCH="bootlin-mipsel-uclibc" ;;
    linux-mipsel-musl)  T_CONF=linux-mips32 ; T_CC="$TC_OWRT_MIPSEL24KC/bin/mipsel-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPSEL24KC" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_LIBC=musl ; T_FETCH="openwrt-mipsel24kc" ;;
    linux-mips-musl)    T_CONF=linux-mips32 ; T_CC="$TC_OWRT_MIPS24KC/bin/mips-openwrt-linux-musl-gcc --sysroot=$TC_OWRT_MIPS24KC" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="-Os" ; T_LIBC=musl ; T_FETCH="openwrt-mips24kc" ;;
    # Generic rv64gc musl. Serves the T-Head C906 boards too, since rv64gc is a subset of what
    # they run. 1.1.1 has no RISC-V asm. A glibc build here once leaked ASYNC_POSIX.
    linux-riscv64-musl) T_CONF=linux64-riscv64 ; T_CC="$TC_RISCV64_MUSL/bin/riscv64-linux-musl-gcc" ; T_EXTRA="enable-ec_nistp_64_gcc_128 -Os" ; T_LIBC=musl ; T_FETCH="muslcc-riscv64" ;;
    # OpenSSL 1.1.1 has no riscv32 Configure target, so this Configures as linux-generic32.
    linux-riscv32-musl) T_CONF=linux-generic32 ; T_CC="$TC_RISCV32_MUSL/bin/riscv32-linux-musl-gcc" ; T_EXTRA="-Os" ; T_LIBC=musl ; T_FETCH="muslcc-riscv32" ;;
    # No -Os: general-purpose operating systems favour speed.
    freebsd-x86_64)     T_CONF=BSD-x86_64 ; T_CC="clang --target=$FREEBSD_TRIPLE --sysroot=$SYSROOT_FREEBSD -fuse-ld=lld" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=bsd ; T_FETCH="apt:clang apt:lld freebsd" ;;
    openbsd-x86_64)     T_CONF=BSD-x86_64 ; T_CC="clang --target=$OPENBSD_TRIPLE --sysroot=$SYSROOT_OPENBSD -fuse-ld=lld" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=bsd ; T_FETCH="apt:clang apt:lld openbsd" ;;
    # No explicit -target, because the darwin64 Configure targets add -arch themselves and an
    # explicit one breaks the osxcross wrapper's linker selection. The T_AR, T_RANLIB and T_NM
    # overrides exist because host GNU binutils do not reliably handle Mach-O archives.
    macos-arm64)        T_CONF=darwin64-arm64-cc  ; T_CC="$_OSX_ARM_CC" ; T_AR="${_OSX_ARM_TOOLS:+$_OSX_ARM_TOOLS-ar}" ; T_RANLIB="${_OSX_ARM_TOOLS:+$_OSX_ARM_TOOLS-ranlib}" ; T_NM="${_OSX_ARM_TOOLS:+$_OSX_ARM_TOOLS-nm}" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=macos ; T_CI=macos ; T_FETCH=osxcross ;;
    macos-x86_64)       T_CONF=darwin64-x86_64-cc ; T_CC="$_OSX_X64_CC" ; T_AR="${_OSX_X64_TOOLS:+$_OSX_X64_TOOLS-ar}" ; T_RANLIB="${_OSX_X64_TOOLS:+$_OSX_X64_TOOLS-ranlib}" ; T_NM="${_OSX_X64_TOOLS:+$_OSX_X64_TOOLS-nm}" ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="enable-ec_nistp_64_gcc_128" ; T_LIBC=macos ; T_CI=macos ; T_FETCH=osxcross ;;

    # Windows is built natively by windows/build.ps1, whose own table carries the MSVC details.
    # These rows exist so the name list, the Configure target and the libc family have one home
    # and verify can audit the .lib archives on any host. asm needs NASM, so VC-WIN64-ARM has none.
    windows-x86)        T_CONF=VC-WIN32     ; T_CC=cl ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_LIBC=msvc ; T_CI=windows ;;
    windows-x86-debug)  T_CONF=VC-WIN32     ; T_CC=cl ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="--debug" ; T_LIBC=msvc ; T_CI=windows ;;
    windows-x64)        T_CONF=VC-WIN64A    ; T_CC=cl ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_LIBC=msvc ; T_CI=windows ;;
    windows-x64-debug)  T_CONF=VC-WIN64A    ; T_CC=cl ; T_FLAGS="${T_FLAGS/-no-asm/}" ; T_EXTRA="--debug" ; T_LIBC=msvc ; T_CI=windows ;;
    windows-arm64)      T_CONF=VC-WIN64-ARM ; T_CC=cl ; T_LIBC=msvc ; T_CI=windows ;;
    windows-arm64-debug) T_CONF=VC-WIN64-ARM ; T_CC=cl ; T_EXTRA="--debug" ; T_LIBC=msvc ; T_CI=windows ;;

    *) return 1 ;;
    esac
    # The install prefix this target's archives and generated header live in.
    T_PREFIX="$OPENSSL_PREFIX_ROOT/$1"
    return 0
}

BR_ALL_TARGETS="linux-x86_64-glibc linux-i686-glibc linux-x86_64-musl \
linux-aarch64-glibc linux-aarch64-musl \
linux-armv6hf-glibc linux-armv7hf-glibc linux-armv7hf-musl linux-armv5-glibc \
linux-mipsel-uclibc linux-mipsel-musl linux-mips-musl \
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
