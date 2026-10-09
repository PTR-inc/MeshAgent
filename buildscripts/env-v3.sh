#!/bin/bash
# Pins and paths shared by target-v3.sh, fetch-deps-v3.sh, check-v3.sh and makefile.v3. Source it.
# Everything per ARCHID lives in targets-v3.conf; only fleet-wide values belong here.

V3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO="${REPO:-$(dirname "$V3_DIR")}"
export TGT_CONF="${TGT_CONF:-$V3_DIR/targets-v3.conf}"

# Toolchains, sysroots and downloads are multi-GB and live outside the checkout.
export BUILDROOT="${BUILDROOT:-/opt/buildroot}"
export BR_DOWNLOADS="$BUILDROOT/downloads"
export BR_TOOLCHAINS="$BUILDROOT/toolchains"
export BR_SYSROOTS="$BUILDROOT/sysroots"

# The one compiler. A row may name another release with zig=, which fetch-deps-v3.sh installs as well.
export ZIG_VERSION="${ZIG_VERSION:-0.15.2}"

# openssl/VERSION is the only OpenSSL pin; the prefixes are openssl/<version>/<target>/.
export OSSLVER="${OSSLVER:-$(tr -d '[:space:]' < "$REPO/openssl/VERSION")}"

# The sparc64 row cannot use zig (LLVM's SPARC assembler lacks the `srln` pseudo-op the OpenSSL asm uses).
export BOOTLIN_RELEASE="${BOOTLIN_RELEASE:-2020.08-1}"
export BOOTLIN_SPARC64="$BR_TOOLCHAINS/sparc64--glibc--stable-$BOOTLIN_RELEASE"

# The build host. A Mac (macOS 15 or newer assumed) builds every row too: zig has Darwin releases, and the
# macOS rows can use Apple's own toolchain when it is installed (Xcode or the Command Line Tools).
export V3_HOST="$(uname -s)"

# macOS rows: MACOS_CC=xcode compiles and links with Apple clang and ld64 (LTO on), MACOS_CC=zig compiles with
# zig. The default is xcode on a Mac that has Apple clang, zig everywhere else. Cross from Linux always links with
# the host's clang + ld64.lld, and zig on a Mac links with Apple's ld64, because zig's own Mach-O linker writes
# rebase entries into __TEXT for OpenSSL's arm64 asm and the binary dies with SIGBUS before main.
if [ -z "${MACOS_CC:-}" ]; then
    if [ "$V3_HOST" = Darwin ] && xcrun -f clang >/dev/null 2>&1; then MACOS_CC=xcode; else MACOS_CC=zig; fi
fi
export MACOS_CC

# The SDK is Apple-licensed and never downloaded from anywhere public. On a Mac it is the one Xcode selects.
export OSXCROSS_SDK_VER="${OSXCROSS_SDK_VER:-26.5}"
if [ -z "${MACOS_SDK:-}" ]; then
    if [ "$V3_HOST" = Darwin ]; then MACOS_SDK="$(xcrun --show-sdk-path 2>/dev/null)"; fi
    MACOS_SDK="${MACOS_SDK:-$BUILDROOT/osxcross/target/SDK/MacOSX$OSXCROSS_SDK_VER.sdk}"
fi
export MACOS_SDK

# Signing (buildscripts/sign-v3.sh). rcodesign signs on any host; a Mac may name a keychain identity instead.
# The self-signed identity is generated once into $BUILDROOT/private/ and copied between build hosts, never
# regenerated, because TCC's Screen Recording and Accessibility grants are keyed on it.
export APPLE_CODESIGN_VER="${APPLE_CODESIGN_VER:-0.29.0}"
export RCODESIGN="$BUILDROOT/bin/rcodesign"
# pbzx unpacks an Xcode .xip's compressed payload (fetch-deps-v3.sh macos); built once from the
# vendored buildscripts/pbzx.c and cached here, like rcodesign.
export PBZX="$BUILDROOT/bin/pbzx"
export MACOS_SIGN_DIR="$BUILDROOT/private/codesign"
export MACOS_SIGN_P12="${MACOS_SIGN_P12:-$MACOS_SIGN_DIR/meshagent-codesign.p12}"
export MACOS_SIGN_P12_PASSWORD="${MACOS_SIGN_P12_PASSWORD-}"
export MACOS_SIGN_CN="${MACOS_SIGN_CN:-MeshAgent self-signed code signing (PTR-inc)}"
export MACOS_CODESIGN_IDENTITY="${MACOS_CODESIGN_IDENTITY-}"

# FreeBSD sysroots come from pkgbase (pkg.freebsd.org), five packages instead of the 200 MB base.txz.
# The repository index is RSA-signed; this is the sha256 of the signing key, the same value FreeBSD ships
# in /usr/share/keys/pkg/trusted/pkg.freebsd.org.2013102301, so a swapped key is refused.
export FREEBSD_PKG_REPO="${FREEBSD_PKG_REPO:-https://pkg.freebsd.org}"
export FREEBSD_PKG_FINGERPRINT="${FREEBSD_PKG_FINGERPRINT:-b0170035af3acc5f3f3ae1859dc717101b4e6c1d0a794ad554928ca0cbb2f438}"

# OpenBSD has no pkgbase. Pre-trimmed sysroots on the mirror are the small download; the fallback streams the
# upstream sets. media.githubusercontent.com, not raw, because the mirror stores them in Git LFS.
export MESHAGENT_TOOLCHAINS_RAW="${MESHAGENT_TOOLCHAINS_RAW:-https://media.githubusercontent.com/media/PTR-inc/meshagent-toolchains/main}"

# macOS has no sha256sum, only perl's shasum. v3_sha256_stream and v3_sha512_stream hash stdin the same way.
v3_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
v3_sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    else shasum -a 256 | awk '{print $1}'; fi
}
v3_sha512_stream() {
    if command -v sha512sum >/dev/null 2>&1; then sha512sum | awk '{print $1}'
    else shasum -a 512 | awk '{print $1}'; fi
}

# Writes the zig libc paths file that makes zig compile against the sysroot or SDK at $1, into $2.
# zig 0.15.2 puts its bundled FreeBSD, NetBSD and macOS libc headers ahead of --sysroot, -isystem, -nostdlibinc and -nostdinc alike, so without this FreeBSD saw __FreeBSD_version 1400500 instead of the 14.4 sysroot's 1404000.
# Only ZIG_LIBC=<this file> replaces them, and zig cc has no command-line flag for it.
zig_libc_file() {
    mkdir -p "$(dirname "$2")" && printf 'include_dir=%s/usr/include\nsys_include_dir=%s/usr/include\ncrt_dir=%s/usr/lib\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n' "$1" "$1" "$1" > "$2"
}

# GNU tar needs --wildcards --no-anchored to match member patterns anywhere in the path; bsdtar (macOS) does
# that by default and rejects the flags.
if tar --version 2>/dev/null | grep -q GNU; then TAR_WILD="--wildcards --no-anchored"; else TAR_WILD=""; fi
export TAR_WILD
