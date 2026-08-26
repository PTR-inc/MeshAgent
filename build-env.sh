#!/bin/bash
# MeshAgent OpenSSL cross-build environment. Source it, do not execute it:  . build-env.sh
# This directory is tracked in git, so the multi-GB toolchains, sysroots and downloads
# live under $BUILDROOT instead (default /opt/buildroot, override before sourcing).

# REPO comes from this script's own location so sibling checkouts do not
# stage into each other. Set REPO=... to stage into a different checkout.
REPO_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO="${REPO:-$REPO_DEFAULT}"

# Only this script moved to the repo root. targets.sh and flags.txt
# still live under openssl/libstatic/build/.
BR_SCRIPTS="$REPO/openssl/libstatic/build"
export BR_SCRIPTS

export BUILDROOT="${BUILDROOT:-/opt/buildroot}"
export BR_DOWNLOADS="$BUILDROOT/downloads"
export BR_SRC="$BUILDROOT/src"
export BR_SYSROOTS="$BUILDROOT/sysroots"
export BR_TOOLCHAINS="$BUILDROOT/toolchains"
export BR_WORK="$BUILDROOT/work"

# ---------------------------------------------------------------- OpenSSL ----
# The version is the only pin. fetch-toolchains.sh reads the sha256 from
# openssl.org's own <tarball>.sha256 sidecar at download time, so there is
# no checksum file to keep in sync by hand.
export OPENSSL_VERSION="${OPENSSL_VERSION:-1.1.1w}"
export OPENSSL_TARBALL="$BR_DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz"

# flags.txt is the single source of truth for every builder, including build.sh,
# windows/build.ps1 and CI. Per-target deltas never get their own file: they are
# T_FLAGS edits such as "${T_FLAGS/-no-asm/}" and T_EXTRA in targets.sh, next to the reason.
export OSSL_FLAGS="$(tr '\n' ' ' < "$BR_SCRIPTS/flags.txt")"

# --------------------------------------------------------------- sysroots ----
# The BSD release is read from the makefile's ARCH_30 and ARCH_37 BSDREL fields
# via `make print-bsdrel`, so a FreeBSD or OpenBSD version bump happens in exactly
# one place. fetch-toolchains.sh and the BSD agent workflows resolve it the same way.
FREEBSD_REL="$(make -s -C "$REPO" ARCHID=30 print-bsdrel 2>/dev/null)"
OPENBSD_REL="$(make -s -C "$REPO" ARCHID=37 print-bsdrel 2>/dev/null)"
[ -n "$FREEBSD_REL" ] || { echo "env.sh: couldn't read BSDREL from ARCH_30 in $REPO/makefile" >&2; FREEBSD_REL=14.3; }
[ -n "$OPENBSD_REL" ] || { echo "env.sh: couldn't read BSDREL from ARCH_37 in $REPO/makefile" >&2; OPENBSD_REL=7.9; }
export FREEBSD_REL OPENBSD_REL
export SYSROOT_FREEBSD="$BR_SYSROOTS/freebsd-$FREEBSD_REL"
export SYSROOT_OPENBSD="$BR_SYSROOTS/openbsd-$OPENBSD_REL"
export FREEBSD_TRIPLE="x86_64-unknown-freebsd$FREEBSD_REL"
export OPENBSD_TRIPLE="x86_64-unknown-openbsd$OPENBSD_REL"

# osxcross lives outside $BR_TOOLCHAINS because it is a whole toolchain plus SDK tree,
# and it is only needed when cross-building macOS from Linux (Darwin uses Xcode's clang).
# SDK_VER is the macOS SDK version, DARWIN_VER the kernel version in the tool prefix (SDK 26.5 is darwin25.5).
export OSXCROSS_DIR="$BUILDROOT/osxcross"
export OSXCROSS_BIN="$OSXCROSS_DIR/target/bin"
export OSXCROSS_SDK_VER="${OSXCROSS_SDK_VER:-26.5}"
export OSXCROSS_DARWIN_VER="${OSXCROSS_DARWIN_VER:-25.5}"
# The SDK is Apple-licensed under the Xcode license agreement, so it is never on the
# public mirror. It is produced locally from an Xcode .xip by build-toolchain-archives.sh
# or fetched from a private URL you supply in OSXCROSS_SDK_URL, which deliberately has no default.
export OSXCROSS_SDK_TARBALL="$BR_DOWNLOADS/MacOSX$OSXCROSS_SDK_VER.sdk.tar.xz"
export OSXCROSS_SDK_URL="${OSXCROSS_SDK_URL:-}"

# gen_sdk_package_pbzx.sh is routed through xip-sdk-cpio.py because a plain
# `cpio -i <pattern>` needs ~45 GB scratch and leaves ~25% of the SDK headers as
# "NULLcanary" fills from Apple's hard-link placeholders. See openssl/libstatic/build/README.md.
osxcross_clone() {
    [ -d "$OSXCROSS_DIR/.git" ] && return 0
    echo "  cloning osxcross into $OSXCROSS_DIR"
    git clone --depth 1 https://github.com/tpoechtrager/osxcross.git "$OSXCROSS_DIR"
}
osxcross_patch_pbzx() {
    local s="$OSXCROSS_DIR/tools/gen_sdk_package_pbzx.sh"
    grep -q 'xip-sdk-cpio' "$s" && return 0
    # An earlier pattern-only patch produced canary SDKs, so undo it first.
    grep -q 'MacOSX.platform/Developer/SDKs' "$s" && git -C "$OSXCROSS_DIR" checkout -- tools/gen_sdk_package_pbzx.sh
    sed -i -e "s|cpio -i\"|python3 '$BR_SCRIPTS/xip-sdk-cpio.py' \| cpio -id\"|" "$s"
    grep -q 'xip-sdk-cpio' "$s"
}
# Succeeds only when the SDK tarball's headers are real rather than NULLcanary placeholders.
osxcross_sdk_ok() {
    local probe; probe=$(tar xJOf "$1" "$(basename "$1" .tar.xz)/usr/include/_stdio.h" 2>/dev/null | head -c 10)
    [ -n "$probe" ] && [ "$probe" != NULLcanary ]
}
# Extracts MacOSX*.sdk.tar.xz from the Xcode .xip $1 into $2. cpio -d is required
# because a pattern-restricted copy-in otherwise lacks the parent directories for
# framework symlinks. This builds xar and pbzx first and needs several GB of scratch.
osxcross_extract_sdk() {
    local xip="$1" out="$2"
    osxcross_clone && osxcross_patch_pbzx || return 1
    # Both tools honour TMPDIR. Their temporaries run to several GB, and /tmp
    # is a small tmpfs on WSL that filled up mid-run.
    mkdir -p "$BR_WORK/tmp"
    ( cd "$OSXCROSS_DIR" && TMPDIR="$BR_WORK/tmp" ./tools/gen_sdk_package_pbzx.sh "$xip" ) || return 1
    mkdir -p "$out" && mv "$OSXCROSS_DIR"/MacOSX*.sdk.tar.xz "$out"/
}

# ------------------------------------------------------- macOS code signing --
# Apple Silicon refuses a binary whose signature no longer matches, and strip
# invalidates the linker signature, so every macOS agent is re-signed with rcodesign.
# Never name a variable RCODESIGN_*: rcodesign reads those as config keys and aborts with "UnknownField version".
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

# A self-signed identity is generated once into $BUILDROOT/private/ and reused, because
# a stable identity keeps TCC's Screen Recording and Accessibility grants across self-updates.
# Copy it to every build host rather than regenerating it, and give CI one as a secret. See ISSUES.md.
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
    # Legacy SHA1-3DES PBE is needed because rcodesign's p12 parser rejects
    # OpenSSL 3's default PBES2 AES container as "incorrect password".
    openssl pkcs12 -export -inkey "$t.key" -in "$t.crt" -name "$MACOS_SIGN_CN" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -passout "pass:$MACOS_SIGN_P12_PASSWORD" -out "$MACOS_SIGN_P12" >/dev/null 2>&1 \
        || { rm -f "$t.key" "$t.crt" "$MACOS_SIGN_P12"; echo "macos_sign: pkcs12 export failed" >&2; return 1; }
    rm -f "$t.key" "$t.crt"; chmod 600 "$MACOS_SIGN_P12"
    cp -f "$MACOS_SIGN_P12" "$MACOS_SIGN_P12.$(date +%Y%m%d).bak" 2>/dev/null
    echo "            backup: $MACOS_SIGN_P12.$(date +%Y%m%d).bak"
}

# Signs one Mach-O with the identity when one exists or can be made. Signs ad-hoc
# when SIGN_ADHOC=1, or in CI without the secret, so a PR build still yields a
# runnable arm64 binary. Fetches rcodesign, a 5 MB checksummed release binary, on first use.
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
    # rcodesign only accepts a non-empty password file, so the empty self-signed
    # default must go via argv. A real password goes via a 0600 temp file to stay out of `ps`.
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

# macOS has no sha256sum, only perl's shasum.
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
# musl.cc publishes no checksum for these, so they are gated on a smoke compile instead.
export TC_AARCH64_A53_MUSL="$BR_TOOLCHAINS/aarch64-linux-musl-cross"
export TC_ARMV7_MUSL_HF="$BR_TOOLCHAINS/arm-linux-musleabihf-cross"
export TC_X86_64_MUSL="$BR_TOOLCHAINS/x86_64-linux-musl-cross"
export TC_RISCV64_MUSL="$BR_TOOLCHAINS/riscv64-linux-musl-cross"
# The T-Head Xuantie C906 vendor toolchain has no public upstream URL, so it is
# mirrored. See p_riscv64_xthead in fetch-toolchains.sh and ARCH_45 in the makefile.
export TC_RISCV64_XTHEAD="$BR_TOOLCHAINS/riscv64-linux-musl-xthead"

# Bootlin is pinned to one release rather than "latest" so the glibc floor is a deliberate,
# reproducible choice. An apt cross-gcc always floors at GLIBC_2.34, above most real ARM hardware.
# 2020.08-1 ships glibc 2.31, gcc 9.3 and binutils 2.33.1. See ISSUES.md.
export BOOTLIN_RELEASE="${BOOTLIN_RELEASE:-2020.08-1}"
_BOOTLIN="$BOOTLIN_RELEASE"
export TC_ARMV5_BOOTLIN="$BR_TOOLCHAINS/armv5-eabi--glibc--stable-$_BOOTLIN"
export TC_ARMV7HF_BOOTLIN="$BR_TOOLCHAINS/armv7-eabihf--glibc--stable-$_BOOTLIN"
export TC_AARCH64_BOOTLIN="$BR_TOOLCHAINS/aarch64--glibc--stable-$_BOOTLIN"
# uClibc rather than glibc, to match the libc family of ARCHID 7's own agent toolchain.
# It replaces the dd-wrt archive that no longer builds against a current kernel.
# mips32el is little-endian. Plain "mips32" is big-endian and unrelated.
export TC_MIPSEL_UCLIBC_BOOTLIN="$BR_TOOLCHAINS/mips32el--uclibc--stable-$_BOOTLIN"
# x86 and x86-64 pin the oldest release Bootlin ever published for them, not $_BOOTLIN,
# to reach the lowest glibc floor available. x86-64-core-i7 is Bootlin's only x86-64 name,
# and targets.sh overrides its -march back to a generic baseline. See ISSUES.md.
export BOOTLIN_X86_RELEASE="${BOOTLIN_X86_RELEASE:-2017.05-toolchains-1-1}"
_BOOTLIN_X86_OLDEST="$BOOTLIN_X86_RELEASE"
export TC_X86_BOOTLIN="$BR_TOOLCHAINS/x86-i686--glibc--stable-$_BOOTLIN_X86_OLDEST"
export TC_X86_64_BOOTLIN="$BR_TOOLCHAINS/x86-64-core-i7--glibc--stable-$_BOOTLIN_X86_OLDEST"

# Maps a glibc version from `make GLIBCVER=2.28 ARCHID=...` to the Bootlin release tag
# that ships it, so one target can drop below the shared 2.31 without repinning the rest.
# Verify a new tag exists at toolchains.bootlin.com/downloads/releases/toolchains/ before adding it.
bootlin_release_for_glibc() {
    case "$1" in
        2.24) echo "$_BOOTLIN_X86_OLDEST" ;;   # Only the x86 and x86-64 families have this oldest release.
        2.28) echo "2019.02-1" ;;
        2.31) echo "$_BOOTLIN" ;;
        *) return 1 ;;
    esac
}

# The kernel headers must come after musl's own include path. Using -I
# would shadow musl's headers with glibc's, so -idirafter is required.
export MUSL_CC="musl-gcc -idirafter /usr/include/x86_64-linux-gnu -idirafter /usr/include"

# Symbols that musl and uClibc genuinely lack, which proves an archive can link a
# non-glibc agent. Do not add __stack_chk_fail or __stack_chk_guard, both libcs have them.
export GLIBC_ONLY_RE='secure_getenv|__isoc99_[a-z]+|_IO_[a-z_]+|gnu_get_libc_version'

# These have POSIX names, so $GLIBC_ONLY_RE cannot catch them, but musl implements
# ucontext.h on no architecture. A musl archive referencing them means __GLIBC__
# leaked into the build and the agent link will fail.
export UCONTEXT_RE='^(get|set|make|swap)context$'

# --------------------------------------------------------------- mirrors ----
# Pre-trimmed toolchains under TC/ and BSD sysroots under SR/ make a fetch one small file
# instead of the full upstream release. The host must be media.githubusercontent.com/media,
# not raw.githubusercontent.com, because the mirror tracks *.tar.* via Git LFS and raw serves only the pointer text.
export MESHAGENT_TOOLCHAINS_RAW="${MESHAGENT_TOOLCHAINS_RAW:-https://media.githubusercontent.com/media/PTR-inc/meshagent-toolchains/main}"

# --------------------------------------------------------- openssl source ----
# GitHub tags 1.x releases like OpenSSL_1_1_1w and 3.x and later like openssl-3.5.7.
openssl_release_tag() {
    case "${1:-$OPENSSL_VERSION}" in
        1.*) echo "OpenSSL_$(echo "${1:-$OPENSSL_VERSION}" | tr . _)" ;;
        *)   echo "openssl-${1:-$OPENSSL_VERSION}" ;;
    esac
}

openssl_tarball_url() {
    echo "https://github.com/openssl/openssl/releases/download/$(openssl_release_tag "${1:-$OPENSSL_VERSION}")/openssl-${1:-$OPENSSL_VERSION}.tar.gz"
}

# openssl.org publishes a <tarball>.sha256 sidecar for every release, current and old
# alike, so the checksum is looked up rather than pinned by hand anywhere.
# Two formats have been seen: bare hex, and the two-column `sha256sum` layout.
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
    # The directory alone proves nothing, since a bare clone already has target/bin/xar.
    # The prefixed clang is what `make macos` and targets.sh actually invoke.
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
