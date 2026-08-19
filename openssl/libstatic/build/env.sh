#!/bin/bash
# MeshAgent OpenSSL cross-build environment - vendored copy, tracked in git.
#
# Source this, do not execute it:   . openssl/libstatic/build/env.sh
#
# Two locations matter here:
#   - This script's own directory (openssl/libstatic/build/) is git-tracked,
#     travels with every clone.
#   - $BUILDROOT (default /opt/buildroot) holds the toolchains/sysroots/
#     downloads instead - not in the repo, multi-GB. Shared by every
#     checkout on a machine by default; override BUILDROOT before sourcing
#     this file to use a different one.

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
export OPENSSL_VERSION=1.1.1w
export OPENSSL_TARBALL="$BR_DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz"
export OPENSSL_SHA256=cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8

# The flag set every target shares - kept identical to the repo's own
# .github/workflows/build-openssl-libs.yml and
# openssl/libstatic/linux/openssl-<arch> scripts.
#
# no-threads was dropped: MeshAgent is a multi-SSL_CTX process, so no-threads
# is a real correctness bug against it, not just a reproducibility concern.
#
# no-afalgeng/no-devcryptoeng were dropped too, but no-engine still disables
# both via Configure's own disable_cascades table.
export OSSL_FLAGS="no-weak-ssl-ciphers no-srp no-psk no-comp no-zlib \
no-zlib-dynamic no-hw no-dso no-shared -no-asm no-rc5 no-idea no-md4 \
no-rmd160 no-ssl no-ssl3 no-seed no-camellia no-bf no-cast no-md2 no-mdc2 \
no-engine no-ocsp no-cms"

# --------------------------------------------------------------- sysroots ----
export SYSROOT_FREEBSD="$BR_SYSROOTS/freebsd-14.3"
export SYSROOT_OPENBSD="$BR_SYSROOTS/openbsd-7.9"
export FREEBSD_TRIPLE=x86_64-unknown-freebsd14.3
export OPENBSD_TRIPLE=x86_64-unknown-openbsd7.9

# osxcross - not under $BR_TOOLCHAINS since it's its own toolchain+SDK tree,
# not a single cross-gcc.
export OSXCROSS_BIN="$BUILDROOT/osxcross/target/bin"
export OSXCROSS_DARWIN_VER=25.5

# ------------------------------------------------------------- toolchains ----
_OWRT=18.06.9
export TC_OWRT_MIPS24KC="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-ar71xx-generic_gcc-7.3.0_musl.Linux-x86_64/staging_dir/toolchain-mips_24kc_gcc-7.3.0_musl"
export TC_OWRT_MIPSEL24KC="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-ramips-mt7621_gcc-7.3.0_musl.Linux-x86_64/staging_dir/toolchain-mipsel_24kc_gcc-7.3.0_musl"
export TC_OWRT_X86_64="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-x86-64_gcc-7.3.0_musl.Linux-x86_64/staging_dir/toolchain-x86_64_gcc-7.3.0_musl"
export TC_MIPS32EL_UCLIBC="$BR_TOOLCHAINS/mips32el--uclibc--stable-2025.08-1"
export TC_MIPS32EL_MUSL="$BR_TOOLCHAINS/toolchain-mipsel_mips32_gcc-13.1.0_musl"
export TC_RISCV64_MUSL="$BR_TOOLCHAINS/riscv64-lp64d--musl--stable-2025.08-1"
export TC_AARCH64_CORTEXA53_MUSL="$BR_TOOLCHAINS/toolchain-aarch64_cortex-a53_gcc-15.2.0_musl"
export TC_ARMV7_CORTEXA9_MUSL="$BR_TOOLCHAINS/toolchain-arm_cortex-a9_gcc-15.2.0_musl_eabi"
export TC_ARMGNU_HF="$BR_TOOLCHAINS/armgnu-15.2.rel1-arm-none-linux-gnueabihf"

# musl-gcc needs the kernel headers appended AFTER musl's own include path.
# -I would shadow musl's headers with glibc's; -idirafter must be used.
export MUSL_CC="musl-gcc -idirafter /usr/include/x86_64-linux-gnu -idirafter /usr/include"

# Symbols musl and uClibc genuinely lack. Used to prove an archive can link a
# non-glibc agent. Do NOT add __stack_chk_fail/__stack_chk_guard - both libcs
# provide them and SSP-enabled toolchains emit one per object.
export GLIBC_ONLY_RE='secure_getenv|__isoc99_[a-z]+|_IO_[a-z_]+|gnu_get_libc_version'

br_check() {
    local missing=0 p
    for p in "$OPENSSL_TARBALL" "$SYSROOT_FREEBSD" "$SYSROOT_OPENBSD" \
             "$TC_OWRT_MIPS24KC" "$TC_OWRT_MIPSEL24KC" "$TC_OWRT_X86_64" \
             "$TC_MIPS32EL_UCLIBC" "$TC_MIPS32EL_MUSL" "$TC_RISCV64_MUSL" \
             "$TC_AARCH64_CORTEXA53_MUSL" "$TC_ARMV7_CORTEXA9_MUSL" "$TC_ARMGNU_HF" \
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
