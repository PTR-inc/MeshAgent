#!/bin/bash
# OpenSSL cross-build environment. Source it, do not execute it:  . openssl/build/env.sh
# Everything the agent and OpenSSL must agree on - BUILDROOT, the zig release, openssl/VERSION,
# the BSD releases - comes from buildscripts/env-v3.sh and targets-v3.conf, so only what is
# specific to building OpenSSL itself lives here.

BR_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BR_SCRIPTS
. "$BR_SCRIPTS/../../buildscripts/env-v3.sh"

# Where a build unpacks, patches and compiles. The install prefixes are in the checkout instead,
# under openssl/<version>/<target>/, because those are what the repo ships.
export BR_WORK="$BUILDROOT/work"

# ---------------------------------------------------------------- OpenSSL ----
# env-v3.sh reads openssl/VERSION into OSSLVER. These scripts and windows/build.ps1 have always
# called it OPENSSL_VERSION, and an override still selects another installed prefix.
export OPENSSL_VERSION="${OPENSSL_VERSION:-$OSSLVER}"
export OPENSSL_TARBALL="$BR_DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz"
export OPENSSL_PREFIX_ROOT="$REPO/openssl/$OPENSSL_VERSION"

# One flags file per OpenSSL release series, the single source of truth for build.sh,
# windows/build.ps1 and CI. The most specific of flags/<version>.txt, flags/1.1.1.txt (the
# trailing patch letter dropped), flags/3.5.txt and flags/3.txt wins. Per-target deltas stay in targets.sh.
ossl_flags_file() {
    local v="$1" c
    for c in "$v" "${v%[a-z]}" "$(echo "$v" | cut -d. -f1-2)" "${v%%.*}"; do
        [ -f "$BR_SCRIPTS/flags/$c.txt" ] && { echo "$BR_SCRIPTS/flags/$c.txt"; return 0; }
    done
    echo "openssl/build/env.sh: no flags file for OpenSSL $v under $BR_SCRIPTS/flags/" >&2; return 1
}
OSSL_FLAGS_FILE="$(ossl_flags_file "$OPENSSL_VERSION")"
export OSSL_FLAGS_FILE
export OSSL_FLAGS="$([ -n "$OSSL_FLAGS_FILE" ] && tr '\n' ' ' < "$OSSL_FLAGS_FILE")"

# ------------------------------------------------------------- toolchains ----
# Zig's bundled Clang compiles every target but sparc64. ZIG_VERSION is env-v3.sh's pin, which is
# also the release the agent itself is compiled with, so an archive and the agent linking it can
# never be built by two different compilers.
export TC_ZIG="$BR_TOOLCHAINS/zig-$ZIG_VERSION"

# The retired linux-mips32r1el-uclibc row, kept buildable on demand. Nothing provisions this
# toolchain any more, because ARCHID 7 moved to static musl and fetch-deps-v3.sh dropped it.
export TC_MIPSEL_UCLIBC_BOOTLIN="$BR_TOOLCHAINS/mips32el--uclibc--stable-$BOOTLIN_RELEASE"

# --------------------------------------------------------------- sysroots ----
# The BSD releases and their sysroot paths are the osver= of the freebsd, openbsd and netbsd rows in
# targets-v3.conf, read through target-v3.sh's own derivation in one subshell. That keeps a release
# bump inside that table, and keeps the T_* names it sets out of this shell.
eval "$(
    . "$REPO/buildscripts/target-v3.sh"
    for _id in $(tgt_ids); do
        tgt_load "$_id" >/dev/null 2>&1 || continue
        case "$T_OS" in
            freebsd) echo "FREEBSD_REL='$T_OSVER'; SYSROOT_FREEBSD='$T_SYSROOT'" ;;
            openbsd) echo "OPENBSD_REL='$T_OSVER'; SYSROOT_OPENBSD='$T_SYSROOT'" ;;
            netbsd)  echo "NETBSD_REL='$T_OSVER'; SYSROOT_NETBSD='$T_SYSROOT'" ;;
        esac
    done
)"
[ -n "$FREEBSD_REL" ] || echo "openssl/build/env.sh: no os=freebsd row in $TGT_CONF" >&2
[ -n "$OPENBSD_REL" ] || echo "openssl/build/env.sh: no os=openbsd row in $TGT_CONF" >&2
[ -n "$NETBSD_REL" ] || echo "openssl/build/env.sh: no os=netbsd row in $TGT_CONF" >&2
export FREEBSD_REL OPENBSD_REL NETBSD_REL SYSROOT_FREEBSD SYSROOT_OPENBSD SYSROOT_NETBSD

# ----------------------------------------------------------- archive gates ----
# Symbols that musl and uClibc genuinely lack, which proves an archive can link a
# non-glibc agent. Do not add __stack_chk_fail or __stack_chk_guard, both libcs have them.
export GLIBC_ONLY_RE='secure_getenv|__isoc99_[a-z]+|_IO_[a-z_]+|gnu_get_libc_version'

# These have POSIX names, so $GLIBC_ONLY_RE cannot catch them, but musl implements
# ucontext.h on no architecture. A musl archive referencing them means __GLIBC__
# leaked into the build and the agent link will fail.
export UCONTEXT_RE='^(get|set|make|swap)context$'

# openssl.org publishes a <tarball>.sha256 sidecar for every release, current and old alike, so a
# version dispatched into CI is checked against the publisher rather than a list kept here.
# Two formats have been seen: bare hex, and the two-column `sha256sum` layout.
openssl_sha256_lookup() {
    local v="${1:-$OPENSSL_VERSION}" sha
    sha=$(curl -sSL --fail --retry 3 --retry-delay 2 "https://www.openssl.org/source/openssl-$v.tar.gz.sha256" | awk '{print $1}') || return 1
    echo "$sha" | grep -qE '^[0-9a-f]{64}$' || return 1
    echo "$sha"
}

echo "BUILDROOT=$BUILDROOT  (openssl $OPENSSL_VERSION, repo $REPO)"
