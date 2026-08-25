#!/bin/bash
# MeshAgent OpenSSL cross-build environment - vendored copy, tracked in git.
#
# Source this, do not execute it:   . build-env.sh
#
# This dir is git-tracked; $BUILDROOT (default /opt/buildroot, override
# before sourcing) holds the multi-GB toolchains/sysroots/downloads instead.

# REPO derives from this script's own location, not a hardcoded checkout
# path. Override with REPO=... to stage into a different checkout.
REPO_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO="${REPO:-$REPO_DEFAULT}"

# targets.sh/flags.txt still live under openssl/libstatic/build/ - this
# script only moved to the repo root, they didn't.
BR_SCRIPTS="$REPO/openssl/libstatic/build"
export BR_SCRIPTS

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

# Shared flag set. flags.txt is the single source of truth for every builder
# (build.sh, windows/build.ps1, CI). Per-target deltas do NOT get their own
# file: they live in targets.sh as T_FLAGS edits ("${T_FLAGS/-no-asm/}") and
# T_EXTRA - one place per target, greppable, next to the reason why.
export OSSL_FLAGS="$(tr '\n' ' ' < "$BR_SCRIPTS/flags.txt")"

# --------------------------------------------------------------- sysroots ----
# The OS release is not hardcoded here - it's read from the makefile's ARCH_30/
# ARCH_37 blocks (BSDREL field, via `make print-bsdrel`) so there is exactly
# one place a FreeBSD/OpenBSD version bump has to happen. fetch-toolchains.sh
# and the BSD agent workflows resolve the same two values the same way.
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
# not a single cross-gcc. Needed only when cross-building macOS from Linux;
# on Darwin the makefile and targets.sh use Xcode's own clang instead.
# SDK_VER is the macOS SDK (marketing) version, DARWIN_VER the kernel version
# osxcross derives its tool prefix from (SDK 26.5 -> darwin25.5).
export OSXCROSS_DIR="$BUILDROOT/osxcross"
export OSXCROSS_BIN="$OSXCROSS_DIR/target/bin"
export OSXCROSS_SDK_VER="${OSXCROSS_SDK_VER:-26.5}"
export OSXCROSS_DARWIN_VER="${OSXCROSS_DARWIN_VER:-25.5}"
# The SDK is Apple-licensed (Xcode license agreement): never on the public
# toolchain mirror. It is either produced locally from an Xcode .xip (see
# build-toolchain-archives.sh) or fetched from a PRIVATE url you supply via
# OSXCROSS_SDK_URL - there is deliberately no default for that variable.
export OSXCROSS_SDK_TARBALL="$BR_DOWNLOADS/MacOSX$OSXCROSS_SDK_VER.sdk.tar.xz"
export OSXCROSS_SDK_URL="${OSXCROSS_SDK_URL:-}"

# Clones osxcross into $OSXCROSS_DIR (idempotent) and routes its
# gen_sdk_package_pbzx.sh through xip-sdk-cpio.py, which keeps only the SDK
# subtree of the Xcode .xip (unrestricted: ~45 GB scratch) AND resolves Apple's
# hard-link placeholders - a plain `cpio -i <pattern>` leaves ~25% of the SDK
# headers as "NULLcanary" fills, because the bytes of a multiply-linked file
# travel with its first link, usually under another platform's SDK.
osxcross_clone() {
    [ -d "$OSXCROSS_DIR/.git" ] && return 0
    echo "  cloning osxcross into $OSXCROSS_DIR"
    git clone --depth 1 https://github.com/tpoechtrager/osxcross.git "$OSXCROSS_DIR"
}
osxcross_patch_pbzx() {
    local s="$OSXCROSS_DIR/tools/gen_sdk_package_pbzx.sh"
    grep -q 'xip-sdk-cpio' "$s" && return 0
    # Undo the earlier pattern-only patch (the one that produced canary SDKs).
    grep -q 'MacOSX.platform/Developer/SDKs' "$s" && git -C "$OSXCROSS_DIR" checkout -- tools/gen_sdk_package_pbzx.sh
    sed -i -e "s|cpio -i\"|python3 '$BR_SCRIPTS/xip-sdk-cpio.py' \| cpio -id\"|" "$s"
    grep -q 'xip-sdk-cpio' "$s"
}
# True if the SDK tarball's headers are real, not NULLcanary placeholders.
osxcross_sdk_ok() {
    local probe; probe=$(tar xJOf "$1" "$(basename "$1" .tar.xz)/usr/include/_stdio.h" 2>/dev/null | head -c 10)
    [ -n "$probe" ] && [ "$probe" != NULLcanary ]
}
# Extracts MacOSX*.sdk.tar.xz from an Xcode .xip ($1) into $2. cpio -d is
# required: pattern-restricted copy-in otherwise lacks parent dirs for
# framework symlinks. Heavy: builds xar/pbzx first, needs several GB scratch.
osxcross_extract_sdk() {
    local xip="$1" out="$2"
    osxcross_clone && osxcross_patch_pbzx || return 1
    # Several GB of temporaries (xip-sdk-cpio's spool, gen_sdk_package.sh's
    # mktemp copy of each SDK): keep them off /tmp, which is a small tmpfs on
    # WSL and filled up mid-run - both tools honour TMPDIR.
    mkdir -p "$BR_WORK/tmp"
    ( cd "$OSXCROSS_DIR" && TMPDIR="$BR_WORK/tmp" ./tools/gen_sdk_package_pbzx.sh "$xip" ) || return 1
    mkdir -p "$out" && mv "$OSXCROSS_DIR"/MacOSX*.sdk.tar.xz "$out"/
}

# ------------------------------------------------------- macOS code signing --
# Apple Silicon refuses to exec a binary whose signature doesn't match the
# file, and osxcross's strip invalidates ld64's linker signature - so every
# macOS agent is re-signed after strip. rcodesign (apple-codesign, pure Rust)
# does it identically on Linux and macOS with no keychain involved.
# Not RCODESIGN_<anything>: rcodesign reads every RCODESIGN_* env var as a
# config key and aborts on unknown ones ("UnknownField version").
export APPLE_CODESIGN_VER="${APPLE_CODESIGN_VER:-0.29.0}"
export RCODESIGN="$BUILDROOT/bin/rcodesign"
rcodesign_asset() {
    local m; m=$(uname -m)
    case "$(uname -s)-$m" in
        Darwin-arm64)          echo "apple-codesign-$APPLE_CODESIGN_VER-aarch64-apple-darwin.tar.gz" ;;
        Darwin-x86_64)         echo "apple-codesign-$APPLE_CODESIGN_VER-x86_64-apple-darwin.tar.gz" ;;
        Linux-aarch64)         echo "apple-codesign-$APPLE_CODESIGN_VER-aarch64-unknown-linux-musl.tar.gz" ;;
        Linux-x86_64)          echo "apple-codesign-$APPLE_CODESIGN_VER-x86_64-unknown-linux-musl.tar.gz" ;;
        *) return 1 ;;
    esac
}
rcodesign_url() { echo "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/$APPLE_CODESIGN_VER/$1"; }

# The signing identity. Self-signed by default, generated once into
# $BUILDROOT/private/ (next to the other non-redistributable material) and
# reused from then on: macOS trusts it no more than an ad-hoc signature, but a
# STABLE identity keeps TCC's Screen Recording/Accessibility grants across agent
# self-updates (ad-hoc changes every build -> re-prompt). Drop a Developer ID
# .p12 at the same path, or point MACOS_SIGN_P12 elsewhere, to sign for real.
# The identity must be the SAME on every host that builds updates - copy it,
# never regenerate; CI must get it as a secret ($CI set -> no auto-generation).
export MACOS_SIGN_DIR="$BUILDROOT/private/codesign"
export MACOS_SIGN_P12="${MACOS_SIGN_P12:-$MACOS_SIGN_DIR/meshagent-codesign.p12}"
export MACOS_SIGN_P12_PASSWORD="${MACOS_SIGN_P12_PASSWORD-}"
export MACOS_SIGN_CN="${MACOS_SIGN_CN:-MeshAgent self-signed code signing (PTR-inc)}"

macos_sign_identity() {
    [ -f "$MACOS_SIGN_P12" ] && return 0
    if [ -n "${CI:-}" ]; then
        echo "macos_sign: no signing identity at $MACOS_SIGN_P12 and this is CI - provide it as a secret, not a throwaway" >&2
        return 1
    fi
    echo "macos_sign: generating a NEW self-signed identity at $MACOS_SIGN_P12"
    echo "            copy it to every other host that builds macOS updates - do not regenerate (TCC grants key on it)"
    mkdir -p "$MACOS_SIGN_DIR" && chmod 700 "$MACOS_SIGN_DIR"
    local t="$MACOS_SIGN_DIR/.gen.$$" ext
    ext=$(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
        -subj "/CN=$MACOS_SIGN_CN/O=PTR-inc" -addext "$(echo "$ext" | sed -n 1p)" \
        -addext "$(echo "$ext" | sed -n 2p)" -addext "$(echo "$ext" | sed -n 3p)" -addext "$(echo "$ext" | sed -n 4p)" \
        -keyout "$t.key" -out "$t.crt" >/dev/null 2>&1 || { rm -f "$t.key" "$t.crt"; echo "macos_sign: openssl req failed" >&2; return 1; }
    # Legacy PBE (SHA1-3DES): rcodesign's p12 parser rejects OpenSSL 3's
    # default PBES2/AES container as "incorrect password".
    openssl pkcs12 -export -inkey "$t.key" -in "$t.crt" -name "$MACOS_SIGN_CN" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -passout "pass:$MACOS_SIGN_P12_PASSWORD" -out "$MACOS_SIGN_P12" >/dev/null 2>&1 \
        || { rm -f "$t.key" "$t.crt" "$MACOS_SIGN_P12"; echo "macos_sign: pkcs12 export failed" >&2; return 1; }
    rm -f "$t.key" "$t.crt"; chmod 600 "$MACOS_SIGN_P12"
    cp -f "$MACOS_SIGN_P12" "$MACOS_SIGN_P12.$(date +%Y%m%d).bak" 2>/dev/null
    echo "            backup: $MACOS_SIGN_P12.$(date +%Y%m%d).bak"
}

# Signs one Mach-O. With the identity when there is (or can be) one; ad-hoc
# when SIGN_ADHOC=1, or automatically in CI without the identity secret (a PR
# build still yields a runnable arm64 binary, just without TCC persistence).
# Fetches rcodesign on first use - a 5 MB checksummed release binary.
macos_sign() {
    local bin="$1"
    [ -x "$RCODESIGN" ] || ( cd "$REPO" && ./fetch-toolchains.sh -y rcodesign >/dev/null ) || return 1
    [ -x "$RCODESIGN" ] || { echo "macos_sign: $RCODESIGN missing - ./fetch-toolchains.sh rcodesign" >&2; return 1; }
    local adhoc="${SIGN_ADHOC:-0}"
    if [ "$adhoc" != 1 ] && [ ! -f "$MACOS_SIGN_P12" ] && [ -n "${CI:-}" ]; then
        echo "  no signing identity in CI - signing ad-hoc (set the MACOS_SIGN_P12 secret for a stable identity)"; adhoc=1
    fi
    if [ "$adhoc" = 1 ]; then
        "$RCODESIGN" sign "$bin" >/dev/null 2>&1 && echo "  signed $bin (ad-hoc)"; return
    fi
    macos_sign_identity || return 1
    # rcodesign wants the password in argv or a NON-empty file; an empty
    # password (the self-signed default) can only go via argv, a real one via
    # a 0600 temp file so it stays out of `ps`.
    local pf="" rc
    if [ -n "$MACOS_SIGN_P12_PASSWORD" ]; then
        pf=$(mktemp "$MACOS_SIGN_DIR/.pass.XXXXXX") && chmod 600 "$pf" && printf '%s' "$MACOS_SIGN_P12_PASSWORD" > "$pf"
        "$RCODESIGN" sign --p12-file "$MACOS_SIGN_P12" --p12-password-file "$pf" --code-signature-flags runtime "$bin" >/dev/null 2>&1; rc=$?
        rm -f "$pf"
    else
        "$RCODESIGN" sign --p12-file "$MACOS_SIGN_P12" --p12-password '' --code-signature-flags runtime "$bin" >/dev/null 2>&1; rc=$?
    fi
    [ $rc -eq 0 ] || { echo "macos_sign: rcodesign failed on $bin" >&2; return 1; }
    echo "  signed $bin ($("$RCODESIGN" print-signature-info "$bin" 2>/dev/null | grep -m1 -oE 'CN=[^,]*' || echo identity))"
}

# sha256 of a file - GNU coreutils on Linux, perl's shasum on macOS.
br_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ------------------------------------------------------------- toolchains ----
export OWRT_RELEASE="${OWRT_RELEASE:-24.10.8}"
export OWRT_GCC="${OWRT_GCC:-13.3.0}"
_OWRT="$OWRT_RELEASE"
_OWRT_GCC="$OWRT_GCC"
export TC_OWRT_MIPS24KC="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-ath79-generic_gcc-${_OWRT_GCC}_musl.Linux-x86_64/staging_dir/toolchain-mips_24kc_gcc-${_OWRT_GCC}_musl"
export TC_OWRT_MIPSEL24KC="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-ramips-mt7621_gcc-${_OWRT_GCC}_musl.Linux-x86_64/staging_dir/toolchain-mipsel_24kc_gcc-${_OWRT_GCC}_musl"
export TC_OWRT_X86_64="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-x86-64_gcc-${_OWRT_GCC}_musl.Linux-x86_64/staging_dir/toolchain-x86_64_gcc-${_OWRT_GCC}_musl"
export TC_OWRT_AARCH64_A53="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-armsr-armv8_gcc-${_OWRT_GCC}_musl.Linux-x86_64/staging_dir/toolchain-aarch64_generic_gcc-${_OWRT_GCC}_musl"
export TC_OWRT_ARMVIRT32="$BR_TOOLCHAINS/openwrt-sdk-$_OWRT-armsr-armv7_gcc-${_OWRT_GCC}_musl_eabi.Linux-x86_64/staging_dir/toolchain-arm_cortex-a15+neon-vfpv4_gcc-${_OWRT_GCC}_musl_eabi"
# musl.cc prebuilt cross toolchains - no published checksum, gated on a smoke compile.
export TC_AARCH64_A53_MUSL="$BR_TOOLCHAINS/aarch64-linux-musl-cross"
export TC_ARMV7_MUSL_HF="$BR_TOOLCHAINS/arm-linux-musleabihf-cross"
export TC_X86_64_MUSL="$BR_TOOLCHAINS/x86_64-linux-musl-cross"
export TC_RISCV64_MUSL="$BR_TOOLCHAINS/riscv64-linux-musl-cross"
# T-Head/Xuantie C906 vendor toolchain, mirrored (no public upstream URL) -
# see fetch-toolchains.sh's p_riscv64_xthead and ARCH_45 in the makefile.
export TC_RISCV64_XTHEAD="$BR_TOOLCHAINS/riscv64-linux-musl-xthead"

# Bootlin toolchains, pinned to one release (not "latest") so the glibc floor they produce is a
# deliberate, reproducible choice - not whatever the build host's package manager has today. See
# ~/.claude/docs/meshagent-archid-glibc-floor.md: apt cross-gcc on this era of Debian/Ubuntu always
# floors at GLIBC_2.34 (libpthread-into-libc merge), which is above what most of the real ARMv5/
# ARMv7/old-aarch64 hardware population runs. 2020.08-1 = glibc 2.31/gcc 9.3/binutils 2.33.1.
export BOOTLIN_RELEASE="${BOOTLIN_RELEASE:-2020.08-1}"
_BOOTLIN="$BOOTLIN_RELEASE"
export TC_ARMV5_BOOTLIN="$BR_TOOLCHAINS/armv5-eabi--glibc--stable-$_BOOTLIN"
export TC_ARMV7HF_BOOTLIN="$BR_TOOLCHAINS/armv7-eabihf--glibc--stable-$_BOOTLIN"
export TC_AARCH64_BOOTLIN="$BR_TOOLCHAINS/aarch64--glibc--stable-$_BOOTLIN"
# uClibc, not glibc - matches ARCHID 7's own agent toolchain family (the dd-wrt archive it
# previously used doesn't build against a current kernel; this replaces it, not the archive/agent
# libc choice). mips32EL, little-endian - "mips32" (no el) is big-endian and unrelated.
export TC_MIPSEL_UCLIBC_BOOTLIN="$BR_TOOLCHAINS/mips32el--uclibc--stable-$_BOOTLIN"
# x86/x86-64 pin their OWN (older) release, not $_BOOTLIN - deliberately the
# oldest Bootlin has ever published for these families (glibc 2.17, RHEL7/
# CentOS7, would be lower still but has no working toolchain source; tried
# manylinux2014, abandoned - CentOS7's yum repos are broken post-EOL. See
# meshagent-glibc-2.28-vs-2.31.md). x86-64-core-i7 is Bootlin's only
# published x86-64 toolchain name - the -march is overridden back to a
# generic baseline in targets.sh so this stays a "generic x86-64" target,
# not an accidental Core-i7-only build.
export BOOTLIN_X86_RELEASE="${BOOTLIN_X86_RELEASE:-2017.05-toolchains-1-1}"
_BOOTLIN_X86_OLDEST="$BOOTLIN_X86_RELEASE"
export TC_X86_BOOTLIN="$BR_TOOLCHAINS/x86-i686--glibc--stable-$_BOOTLIN_X86_OLDEST"
export TC_X86_64_BOOTLIN="$BR_TOOLCHAINS/x86-64-core-i7--glibc--stable-$_BOOTLIN_X86_OLDEST"

# Per-ARCHID glibc floor pin (make GLIBCVER=2.28 ARCHID=...) - maps a glibc
# version to the Bootlin "stable-<date>" release tag that ships it, so a
# single target can float below $_BOOTLIN's shared 2.31 without repinning
# every other Bootlin target. Only the tags below are verified against
# toolchains.bootlin.com/downloads/releases/toolchains/ - confirm a new one
# actually exists (and for which families) before adding it here.
bootlin_release_for_glibc() {
    case "$1" in
        2.24) echo "$_BOOTLIN_X86_OLDEST" ;;   # x86/x86-64 families only - their oldest release
        2.28) echo "2019.02-1" ;;
        2.31) echo "$_BOOTLIN" ;;
        *) return 1 ;;
    esac
}

# musl-gcc needs the kernel headers appended AFTER musl's own include path.
# -I would shadow musl's headers with glibc's; -idirafter must be used.
export MUSL_CC="musl-gcc -idirafter /usr/include/x86_64-linux-gnu -idirafter /usr/include"

# Symbols musl/uClibc genuinely lack, proving an archive can link a non-glibc
# agent. Do NOT add __stack_chk_fail/__stack_chk_guard - both libcs have them.
export GLIBC_ONLY_RE='secure_getenv|__isoc99_[a-z]+|_IO_[a-z_]+|gnu_get_libc_version'

# POSIX-named, so $GLIBC_ONLY_RE can't catch them, but musl implements
# ucontext.h on no architecture - a musl archive referencing these means
# __GLIBC__ leaked into the build and the agent link will fail.
export UCONTEXT_RE='^(get|set|make|swap)context$'

# --------------------------------------------------------------- mirrors ----
# Pre-trimmed toolchains (TC/) and BSD sysroots (SR/) live here so a fetch is
# one small file instead of the full upstream release. media.githubusercontent
# .com/media, NOT raw.* - the mirror repo tracks *.tar.* via Git LFS and raw.*
# serves only the pointer text.
export MESHAGENT_TOOLCHAINS_RAW="${MESHAGENT_TOOLCHAINS_RAW:-https://media.githubusercontent.com/media/PTR-inc/meshagent-toolchains/main}"

# --------------------------------------------------------- openssl source ----
# 1.x releases are tagged OpenSSL_1_1_1w; 3.x and later, openssl-3.5.7.
openssl_release_tag() {
    case "${1:-$OPENSSL_VERSION}" in
        1.*) echo "OpenSSL_$(echo "${1:-$OPENSSL_VERSION}" | tr . _)" ;;
        *)   echo "openssl-${1:-$OPENSSL_VERSION}" ;;
    esac
}

openssl_tarball_url() {
    echo "https://github.com/openssl/openssl/releases/download/$(openssl_release_tag "${1:-$OPENSSL_VERSION}")/openssl-${1:-$OPENSSL_VERSION}.tar.gz"
}

# openssl.org publishes a <tarball>.sha256 sidecar for every release (current
# series and "old" alike), so the checksum is looked up rather than pinned by
# hand anywhere. Two observed formats: bare hex, or `sha256sum` two-column.
openssl_sha256_lookup() {
    local v="${1:-$OPENSSL_VERSION}" body sha
    body=$(curl -sSL --fail --retry 3 --retry-delay 2 "https://www.openssl.org/source/openssl-$v.tar.gz.sha256") || return 1
    sha=$(echo "$body" | awk '{print $1}')
    echo "$sha" | grep -qE '^[0-9a-f]{64}$' || return 1
    echo "$sha"
}

br_check() {
    local missing=0 p
    for p in "$OPENSSL_TARBALL" "$SYSROOT_FREEBSD" "$SYSROOT_OPENBSD" \
             "$TC_OWRT_MIPS24KC" "$TC_OWRT_MIPSEL24KC" "$TC_OWRT_X86_64" \
             "$TC_OWRT_AARCH64_A53" "$TC_OWRT_ARMVIRT32" \
             "$TC_AARCH64_A53_MUSL" "$TC_ARMV7_MUSL_HF" "$TC_X86_64_MUSL" "$TC_RISCV64_MUSL" \
             "$TC_ARMV5_BOOTLIN" "$TC_ARMV7HF_BOOTLIN" "$TC_AARCH64_BOOTLIN" "$TC_MIPSEL_UCLIBC_BOOTLIN" \
             "$TC_X86_BOOTLIN" "$TC_X86_64_BOOTLIN" "$TC_RISCV64_XTHEAD"; do
        [ -e "$p" ] || { echo "  MISSING: $p"; missing=1; }
    done
    # The dir alone proves nothing (a bare clone has target/bin/xar) - the
    # prefixed clang is what `make macos` and targets.sh actually invoke.
    p="$OSXCROSS_BIN/aarch64-apple-darwin$OSXCROSS_DARWIN_VER-clang"
    if [ "$(uname -s)" = Darwin ]; then echo "  osxcross: not needed on macOS (Xcode clang)"
    elif [ -x "$p" ]; then echo "  osxcross: $p"
    else echo "  MISSING: $p  (osxcross - ./fetch-toolchains.sh osxcross, needs the Apple-licensed SDK)"; missing=1; fi
    if [ -x "$RCODESIGN" ]; then echo "  rcodesign: $RCODESIGN ($("$RCODESIGN" --version 2>/dev/null | head -1))"
    else echo "  MISSING: $RCODESIGN  (./fetch-toolchains.sh rcodesign - signs the macOS agents)"; missing=1; fi
    if [ -f "$MACOS_SIGN_P12" ]; then
        echo "  macOS signing identity: $MACOS_SIGN_P12 ($(openssl pkcs12 -in "$MACOS_SIGN_P12" -nokeys -passin "pass:$MACOS_SIGN_P12_PASSWORD" 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null | tr '\n' ' '))"
    else echo "  macOS signing identity: none yet - self-signed one is generated by the first 'make macos' ($MACOS_SIGN_P12)"; fi
    if [ $missing -ne 0 ]; then
        echo "  see openssl/libstatic/build/README.md for how to provision \$BUILDROOT ($BUILDROOT)"
    else
        echo "  all sysroots, toolchains and sources present"
    fi
    return $missing
}

echo "BUILDROOT=$BUILDROOT  (openssl $OPENSSL_VERSION, repo $REPO)"
