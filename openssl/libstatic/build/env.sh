#!/bin/bash
# MeshAgent OpenSSL cross-build environment - vendored copy, tracked in git.
#
# Source this, do not execute it:   . openssl/libstatic/build/env.sh
#
# This dir is git-tracked; $BUILDROOT (default /opt/buildroot, override
# before sourcing) holds the multi-GB toolchains/sysroots/downloads instead.

BR_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BR_SCRIPTS

# REPO derives from this script's own location, not a hardcoded checkout
# path. Override with REPO=... to stage into a different checkout.
REPO_DEFAULT="$(cd "$BR_SCRIPTS/../../.." && pwd)"
export REPO="${REPO:-$REPO_DEFAULT}"

export BUILDROOT="${BUILDROOT:-/opt/buildroot}"
export BR_DOWNLOADS="$BUILDROOT/downloads"
export BR_SRC="$BUILDROOT/src"
export BR_SYSROOTS="$BUILDROOT/sysroots"
export BR_TOOLCHAINS="$BUILDROOT/toolchains"
export BR_WORK="$BUILDROOT/work"

# ---------------------------------------------------------------- OpenSSL ----
# Version is the only pin needed - fetch-toolchains.sh looks the sha256 up
# from openssl.org's own <tarball>.sha256 sidecar at download time (both the
# current release series and every "old" series resolve through that one URL
# shape), so there is no separate checksum file to keep in sync by hand.
export OPENSSL_VERSION="${OPENSSL_VERSION:-1.1.1w}"
export OPENSSL_TARBALL="$BR_DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz"

# Shared flag set, kept identical to build-openssl-libs.yml. flags.txt is
# the single source of truth (also read by windows/*.ps1).
export OSSL_FLAGS="$(tr '\n' ' ' < "$BR_SCRIPTS/flags.txt")"

# --------------------------------------------------------------- sysroots ----
# The OS release is not hardcoded here - it's read from the makefile's ARCH_30/
# ARCH_37 stanzas (BSDREL field, via `make print-bsdrel`) so there is exactly
# one place a FreeBSD/OpenBSD version bump has to happen. The CI workflow
# (openssl-bsd.yml) reads the same two values the same way.
FREEBSD_REL="$(make -s -C "$REPO" ARCHID=30 print-bsdrel 2>/dev/null)"
OPENBSD_REL="$(make -s -C "$REPO" ARCHID=37 print-bsdrel 2>/dev/null)"
[ -n "$FREEBSD_REL" ] || { echo "env.sh: couldn't read BSDREL from ARCH_30 in $REPO/makefile" >&2; FREEBSD_REL=14.3; }
[ -n "$OPENBSD_REL" ] || { echo "env.sh: couldn't read BSDREL from ARCH_37 in $REPO/makefile" >&2; OPENBSD_REL=7.9; }
export FREEBSD_REL OPENBSD_REL
export SYSROOT_FREEBSD="$BR_SYSROOTS/freebsd-$FREEBSD_REL"
export SYSROOT_OPENBSD="$BR_SYSROOTS/openbsd-$OPENBSD_REL"
export FREEBSD_TRIPLE="x86_64-unknown-freebsd$FREEBSD_REL"
export OPENBSD_TRIPLE="x86_64-unknown-openbsd$OPENBSD_REL"

# osxcross - not under $BR_TOOLCHAINS since it's its own toolchain+SDK tree,
# not a single cross-gcc.
export OSXCROSS_BIN="$BUILDROOT/osxcross/target/bin"
export OSXCROSS_DARWIN_VER=25.5

# ------------------------------------------------------------- toolchains ----
_OWRT=24.10.8
_OWRT_GCC=13.3.0
export TC_OWRT_MIPS24KC="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-ath79-generic_gcc-${_OWRT_GCC}_musl.Linux-x86_64/staging_dir/toolchain-mips_24kc_gcc-${_OWRT_GCC}_musl"
export TC_OWRT_MIPSEL24KC="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-ramips-mt7621_gcc-${_OWRT_GCC}_musl.Linux-x86_64/staging_dir/toolchain-mipsel_24kc_gcc-${_OWRT_GCC}_musl"
export TC_OWRT_X86_64="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-x86-64_gcc-${_OWRT_GCC}_musl.Linux-x86_64/staging_dir/toolchain-x86_64_gcc-${_OWRT_GCC}_musl"
export TC_OWRT_AARCH64_A53="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-armsr-armv8_gcc-${_OWRT_GCC}_musl.Linux-x86_64/staging_dir/toolchain-aarch64_generic_gcc-${_OWRT_GCC}_musl"
export TC_OWRT_ARMVIRT32="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-armsr-armv7_gcc-${_OWRT_GCC}_musl_eabi.Linux-x86_64/staging_dir/toolchain-arm_cortex-a15+neon-vfpv4_gcc-${_OWRT_GCC}_musl_eabi"
# musl.cc prebuilt cross toolchains - no published checksum, gated on a smoke compile.
export TC_AARCH64_A53_MUSL="$BR_TOOLCHAINS/aarch64-linux-musl-cross"
export TC_ARMV7_MUSL_HF="$BR_TOOLCHAINS/arm-linux-musleabihf-cross"
export TC_X86_64_MUSL="$BR_TOOLCHAINS/x86_64-linux-musl-cross"

# Bootlin toolchains, pinned to one release (not "latest") so the glibc floor they produce is a
# deliberate, reproducible choice - not whatever the build host's package manager has today. See
# ~/.claude/docs/meshagent-archid-glibc-floor.md: apt cross-gcc on this era of Debian/Ubuntu always
# floors at GLIBC_2.34 (libpthread-into-libc merge), which is above what most of the real ARMv5/
# ARMv7/old-aarch64 hardware population runs. 2020.08-1 = glibc 2.31/gcc 9.3/binutils 2.33.1.
_BOOTLIN=2020.08-1
export TC_ARMV5_BOOTLIN="$BR_TOOLCHAINS/armv5-eabi--glibc--stable-$_BOOTLIN"
export TC_ARMV7HF_BOOTLIN="$BR_TOOLCHAINS/armv7-eabihf--glibc--stable-$_BOOTLIN"
export TC_AARCH64_BOOTLIN="$BR_TOOLCHAINS/aarch64--glibc--stable-$_BOOTLIN"
# uClibc, not glibc - matches ARCHID 7's own agent toolchain family (the dd-wrt archive it
# previously used doesn't build against a current kernel; this replaces it, not the archive/agent
# libc choice). mips32EL, little-endian - "mips32" (no el) is big-endian and unrelated.
export TC_MIPSEL_UCLIBC_BOOTLIN="$BR_TOOLCHAINS/mips32el--uclibc--stable-$_BOOTLIN"
# Lowest priority per meshagent-archid-glibc-floor.md (x86-64 hardware population
# is overwhelmingly current) but fixed on request. x86-64-core-i7 is Bootlin's only
# published x86-64 toolchain name - the -march is overridden back to a generic
# baseline in targets.sh so this stays a "generic x86-64" target, not an
# accidental Core-i7-only build.
export TC_X86_BOOTLIN="$BR_TOOLCHAINS/x86-i686--glibc--stable-$_BOOTLIN"
export TC_X86_64_BOOTLIN="$BR_TOOLCHAINS/x86-64-core-i7--glibc--stable-$_BOOTLIN"

# musl-gcc needs the kernel headers appended AFTER musl's own include path.
# -I would shadow musl's headers with glibc's; -idirafter must be used.
export MUSL_CC="musl-gcc -idirafter /usr/include/x86_64-linux-gnu -idirafter /usr/include"

# Symbols musl/uClibc genuinely lack, proving an archive can link a non-glibc
# agent. Do NOT add __stack_chk_fail/__stack_chk_guard - both libcs have them.
export GLIBC_ONLY_RE='secure_getenv|__isoc99_[a-z]+|_IO_[a-z_]+|gnu_get_libc_version'

br_check() {
    local missing=0 p
    for p in "$OPENSSL_TARBALL" "$SYSROOT_FREEBSD" "$SYSROOT_OPENBSD" \
             "$TC_OWRT_MIPS24KC" "$TC_OWRT_MIPSEL24KC" "$TC_OWRT_X86_64" \
             "$TC_OWRT_AARCH64_A53" "$TC_OWRT_ARMVIRT32" \
             "$TC_AARCH64_A53_MUSL" "$TC_ARMV7_MUSL_HF" "$TC_X86_64_MUSL" \
             "$TC_ARMV5_BOOTLIN" "$TC_ARMV7HF_BOOTLIN" "$TC_AARCH64_BOOTLIN" "$TC_MIPSEL_UCLIBC_BOOTLIN" \
             "$TC_X86_BOOTLIN" "$TC_X86_64_BOOTLIN" \
             "$OSXCROSS_BIN"; do
        [ -e "$p" ] || { echo "  MISSING: $p"; missing=1; }
    done
    if [ $missing -ne 0 ]; then
        echo "  see openssl/libstatic/build/README.md for how to provision \$BUILDROOT ($BUILDROOT)"
    else
        echo "  all sysroots, toolchains and sources present"
    fi
    return $missing
}

echo "BUILDROOT=$BUILDROOT  (openssl $OPENSSL_VERSION, repo $REPO)"
