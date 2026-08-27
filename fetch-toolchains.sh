#!/bin/bash
# Fetches, verifies and extracts every toolchain, sysroot and source that has a stable
# public URL into $BUILDROOT, and prints manual instructions for the rest. It lives at the
# repo root because it also wires the OpenWrt toolchains for ARCHID 28 and 40. See openssl/build/README.md.
#
#   ./fetch-toolchains.sh                   # everything fetchable
#   ./fetch-toolchains.sh list              # show status, fetch nothing
#   ./fetch-toolchains.sh deps              # show which packages are installed
#   ./fetch-toolchains.sh help              # usage + resolved paths
#   ./fetch-toolchains.sh freebsd openbsd   # named components only
#   ./fetch-toolchains.sh -y                # answer the apt-get prompts yes

# build-env.sh carries the same fallback. Set BUILDROOT in the
# environment to override both at once.
export BUILDROOT="${BUILDROOT:-/opt/buildroot}"

. "$(dirname "$(readlink -f "$0")")/build-env.sh"

STATUS_LOG="$(mktemp)"
trap 'rm -f "$STATUS_LOG"' EXIT
log_status() { echo "$1: $2" | tee -a "$STATUS_LOG" >&2; }

# The archive format's own checksum catches a truncated download that a
# checksum-less fetch cannot. An unknown extension passes.
archive_ok() {
    case "$1" in
        *.tar.zst|*.zst)      zstd -t "$1"  >/dev/null 2>&1 ;;
        *.tar.xz|*.txz|*.xz)  xz -t "$1"    >/dev/null 2>&1 ;;
        *.tar.bz2|*.bz2)      bzip2 -t "$1" >/dev/null 2>&1 ;;
        *.tar.gz|*.tgz|*.gz)  gzip -t "$1"   >/dev/null 2>&1 ;;
        *) return 0 ;;
    esac
}

# Skips the download when dest already matches the sha256, or passes archive_ok
# when no sha256 is published. Anything else is deleted and fetched again.
fetch() {
    local url="$1" sha="$2" dest="$3"
    if [ -f "$dest" ]; then
        if [ -n "$sha" ]; then
            if [ "$(br_sha256 "$dest")" = "$sha" ]; then
                return 0
            fi
            echo "  $dest exists but fails checksum - re-downloading"
        elif archive_ok "$dest"; then
            return 0
        else
            echo "  $dest exists but fails archive integrity check - re-downloading"
        fi
        rm -f "$dest"
    fi
    echo "  downloading $url"
    curl -sSL --fail --retry 3 --retry-delay 2 -o "$dest" "$url" || { echo "  FETCH FAILED: $url" >&2; return 1; }
    if [ -n "$sha" ]; then
        [ "$(br_sha256 "$dest")" = "$sha" ] || { echo "  CHECKSUM MISMATCH: $dest" >&2; rm -f "$dest"; return 1; }
    elif ! archive_ok "$dest"; then
        echo "  CORRUPT ARCHIVE (failed integrity check): $dest" >&2; rm -f "$dest"; return 1
    fi
}

# ---------------------------------------------------------------- OpenSSL ----
# The URL, release tag and sha256 lookup live in build-env.sh so CI and the
# Windows scripts resolve them the same way. Nothing is pinned by hand here.
p_openssl() {
    local sha; sha=$(openssl_sha256_lookup "$OPENSSL_VERSION") \
        || { log_status openssl "FAILED (couldn't look up sha256 for $OPENSSL_VERSION from openssl.org)"; return 1; }
    fetch "$(openssl_tarball_url "$OPENSSL_VERSION")" "$sha" "$OPENSSL_TARBALL" \
        && log_status openssl "OK ($OPENSSL_VERSION, sha256 looked up from openssl.org)" || { log_status openssl "FAILED"; return 1; }
}

# Checks that the cross-gcc $1 can actually compile, because a truncated
# tarball can extract a working bin/*-gcc wrapper while cc1 is still empty.
toolchain_smoke_ok() {
    [ -x "$1" ] || return 1
    echo 'typedef int x;' | "$1" -c -x c -o /dev/null - >/dev/null 2>&1
}

# -------------------------------------------------------------- OpenWrt SDKs -
# OpenWrt publishes no checksum for the SDKs, so toolchain_smoke_ok verifies them instead.
p_openwrt() {
    local name="$1" wtarget="$2" wsubtarget="$3" destvar="$4" ccbin="$5" variant="$6"
    local file="openwrt-sdk-${_OWRT}-${wtarget}-${wsubtarget}_gcc-${_OWRT_GCC}_musl${variant}.Linux-x86_64.tar.zst"
    local tarball="$BR_DOWNLOADS/$file"
    local destdir="${!destvar}"
    toolchain_smoke_ok "$destdir/bin/$ccbin" && { log_status "$name" "already present"; return 0; }
    [ -e "$destdir" ] && { echo "  $destdir present but fails a smoke compile - re-fetching" >&2; rm -rf "$destdir"; }
    fetch "https://downloads.openwrt.org/releases/${_OWRT}/targets/$wtarget/$wsubtarget/$file" "" "$tarball" || { log_status "$name" "FAILED (download)"; return 1; }
    mkdir -p "$BR_TOOLCHAINS" && tar -xaf "$tarball" -C "$BR_TOOLCHAINS" || { log_status "$name" "FAILED (extract)"; return 1; }
    toolchain_smoke_ok "$destdir/bin/$ccbin" \
        && log_status "$name" "OK" \
        || { log_status "$name" "FAILED (extracted, but $destdir/bin/$ccbin fails a smoke compile - archive layout changed, or extraction incomplete?)"; return 1; }
}

# --------------------------------------------------------------- BSD sysroots
# Sysroots pre-trimmed by build-bsd-sysroot-archives.sh are mirrored at PTR-inc/meshagent-toolchains
# so a fetch is one small file instead of the ~200-600MB upstream release. When the mirror lacks
# this OS release, the real upstream release is fetched and trimmed. $MESHAGENT_TOOLCHAINS_RAW comes from build-env.sh.

# Takes name, sysroot directory and url. Extracts and returns 0 when the mirror has it, otherwise returns 1, which is not fatal.
fetch_sysroot_mirror() {
    local name="$1" sysroot="$2" url="$3"
    local dest="$BR_DOWNLOADS/$(basename "$url")"
    curl -sSfL -o /dev/null --head "$url" 2>/dev/null || return 1
    log_status "$name" "found on meshagent-toolchains mirror"
    fetch "$url" "" "$dest" || { log_status "$name" "FAILED (mirror download)"; return 1; }
    archive_ok "$dest" || { log_status "$name" "mirror archive is corrupt/truncated - discarding"; rm -f "$dest"; return 1; }
    mkdir -p "$sysroot"
    tar xf "$dest" -C "$sysroot" || { log_status "$name" "FAILED (mirror extract)"; return 1; }
    log_status "$name" "OK (from mirror)"
    return 0
}

# lib/ is included as well because the libfoo.so symlinks in usr/lib point into it.
p_freebsd() {
    [ -d "$SYSROOT_FREEBSD/usr/include" ] && { log_status freebsd "already present"; return 0; }
    fetch_sysroot_mirror freebsd "$SYSROOT_FREEBSD" "$MESHAGENT_TOOLCHAINS_RAW/SR/freebsd-$FREEBSD_REL-sysroot.tar.xz" && return 0
    log_status freebsd "not on mirror - falling back to download.freebsd.org"
    local rel="https://download.freebsd.org/releases/amd64/amd64/$FREEBSD_REL-RELEASE"
    local sha; sha=$(curl -sSL --fail "$rel/MANIFEST" | awk '$1=="base.txz"{print $2}')
    [ -n "$sha" ] || { log_status freebsd "FAILED (couldn't fetch MANIFEST)"; return 1; }
    fetch "$rel/base.txz" "$sha" "$BR_DOWNLOADS/freebsd-$FREEBSD_REL-base.txz" || { log_status freebsd "FAILED (download)"; return 1; }
    mkdir -p "$SYSROOT_FREEBSD"
    tar xf "$BR_DOWNLOADS/freebsd-$FREEBSD_REL-base.txz" -C "$SYSROOT_FREEBSD" ./usr/include ./usr/lib ./lib \
        && log_status freebsd "OK" \
        || { log_status freebsd "FAILED (extract)"; return 1; }
}

# OpenBSD keeps the headers and crt objects in comp79.tgz, not base79.tgz, and
# base79 alone has an empty usr/include, so both sets are fetched.
p_openbsd() {
    [ -d "$SYSROOT_OPENBSD/usr/include" ] && { log_status openbsd "already present"; return 0; }
    fetch_sysroot_mirror openbsd "$SYSROOT_OPENBSD" "$MESHAGENT_TOOLCHAINS_RAW/SR/openbsd-$OPENBSD_REL-sysroot.tar.xz" && return 0
    log_status openbsd "not on mirror - falling back to cdn.openbsd.org"
    local nodot="${OPENBSD_REL//./}"
    local rel="https://cdn.openbsd.org/pub/OpenBSD/$OPENBSD_REL/amd64"
    local sha_manifest; sha_manifest=$(curl -sSL --fail "$rel/SHA256") || { log_status openbsd "FAILED (couldn't fetch SHA256 manifest)"; return 1; }
    local sha_base; sha_base=$(echo "$sha_manifest" | awk -v f="base$nodot.tgz" '$0 ~ "\\(" f "\\)"{print $4}')
    local sha_comp; sha_comp=$(echo "$sha_manifest" | awk -v f="comp$nodot.tgz" '$0 ~ "\\(" f "\\)"{print $4}')
    [ -n "$sha_base" ] && [ -n "$sha_comp" ] || { log_status openbsd "FAILED (couldn't parse SHA256 manifest)"; return 1; }
    fetch "$rel/base$nodot.tgz" "$sha_base" "$BR_DOWNLOADS/openbsd-$OPENBSD_REL-base$nodot.tgz" || { log_status openbsd "FAILED (download base)"; return 1; }
    fetch "$rel/comp$nodot.tgz" "$sha_comp" "$BR_DOWNLOADS/openbsd-$OPENBSD_REL-comp$nodot.tgz" || { log_status openbsd "FAILED (download comp)"; return 1; }
    mkdir -p "$SYSROOT_OPENBSD"
    tar xzf "$BR_DOWNLOADS/openbsd-$OPENBSD_REL-base$nodot.tgz" -C "$SYSROOT_OPENBSD" ./usr/include ./usr/lib \
        && tar xzf "$BR_DOWNLOADS/openbsd-$OPENBSD_REL-comp$nodot.tgz" -C "$SYSROOT_OPENBSD" ./usr/include ./usr/lib \
        && log_status openbsd "OK" \
        || { log_status openbsd "FAILED (extract)"; return 1; }
}

# ------------------------------------------------------- vendor toolchains ----
# The T-Head Xuantie C906 riscv64-unknown-linux-musl toolchain has no public upstream URL,
# since a prebuilt needs their account-gated OCC portal, so it is mirrored at
# PTR-inc/meshagent-toolchains/TC. A miss is not fatal, ARCH_45 stays bring-your-own. See ISSUES.md.
p_riscv64_xthead() {
    local destdir="$TC_RISCV64_XTHEAD" url="$MESHAGENT_TOOLCHAINS_RAW/TC/riscv64-linux-musl-xthead.tar.xz"
    toolchain_smoke_ok "$destdir/bin/riscv64-unknown-linux-musl-gcc" && { log_status riscv64-xthead "already present"; return 0; }
    curl -sSfL -o /dev/null --head "$url" 2>/dev/null || { log_status riscv64-xthead "FAILED (not on meshagent-toolchains mirror, no other source - see ARCH_45 in the makefile)"; return 1; }
    local dest="$BR_DOWNLOADS/riscv64-linux-musl-xthead.tar.xz"
    fetch "$url" "" "$dest" || { log_status riscv64-xthead "FAILED (mirror download)"; return 1; }
    archive_ok "$dest" || { log_status riscv64-xthead "mirror archive is corrupt/truncated - discarding"; rm -f "$dest"; return 1; }
    mkdir -p "$BR_TOOLCHAINS" && tar xf "$dest" -C "$BR_TOOLCHAINS" || { log_status riscv64-xthead "FAILED (extract)"; return 1; }
    toolchain_smoke_ok "$destdir/bin/riscv64-unknown-linux-musl-gcc" \
        && log_status riscv64-xthead "OK (from mirror)" \
        || { log_status riscv64-xthead "FAILED (extracted, but $destdir/bin/riscv64-unknown-linux-musl-gcc fails a smoke compile)"; return 1; }
}

# ------------------------------------------------------------ musl.cc cross ----
# Prebuilt musl cross toolchains of ~100MB each. musl.cc publishes no checksum,
# so each is gated on a real smoke compile rather than a hash.
p_muslcc() {
    local name="$1" destvar="$2"
    local destdir="${!destvar}" base; base="$(basename "$destdir")"
    local tarball="$BR_DOWNLOADS/$base.tgz"
    toolchain_smoke_ok "$destdir/bin/${base%-cross}-gcc" && { log_status "$name" "already present"; return 0; }
    [ -e "$destdir" ] && rm -rf "$destdir"
    fetch "https://musl.cc/$base.tgz" "" "$tarball" || { log_status "$name" "FAILED (download)"; return 1; }
    tar xzf "$tarball" -C "$BR_TOOLCHAINS" || { log_status "$name" "FAILED (extract)"; return 1; }
    toolchain_smoke_ok "$destdir/bin/${base%-cross}-gcc" \
        && log_status "$name" "OK" \
        || { log_status "$name" "FAILED (extracted, but $destdir/bin/${base%-cross}-gcc fails a smoke compile)"; return 1; }
}

# ------------------------------------------------------------ Bootlin cross --
# Bootlin glibc and uClibc cross toolchains of ~100MB each. No checksum is published,
# so each is gated on a smoke compile. The release is pinned rather than "latest"
# so the libc floor is a deliberate, reproducible choice. See ISSUES.md.
p_bootlin() {
    local name="$1" family="$2" destvar="$3" ccname="$4"
    local destdir="${!destvar}" base; base="$(basename "$destdir")"
    local tarball="$BR_DOWNLOADS/$base.tar.bz2"
    toolchain_smoke_ok "$destdir/bin/$ccname" && { log_status "$name" "already present"; return 0; }
    [ -e "$destdir" ] && { echo "  $destdir present but fails a smoke compile - re-fetching" >&2; rm -rf "$destdir"; }
    fetch "https://toolchains.bootlin.com/downloads/releases/toolchains/$family/tarballs/$base.tar.bz2" "" "$tarball" \
        || { log_status "$name" "FAILED (download)"; return 1; }
    mkdir -p "$BR_TOOLCHAINS" && tar xjf "$tarball" -C "$BR_TOOLCHAINS" || { log_status "$name" "FAILED (extract)"; return 1; }
    bootlin_fixup_extracted_dirname "$family" "$destdir"
    toolchain_smoke_ok "$destdir/bin/$ccname" \
        && log_status "$name" "OK" \
        || { log_status "$name" "FAILED (extracted, but $destdir/bin/$ccname fails a smoke compile)"; return 1; }
}

# Bootlin's 2017.05 releases extract to <family>--glibc--stable with no release
# suffix, unlike every later release, so the directory is renamed into place
# for destdir to resolve either way.
bootlin_fixup_extracted_dirname() {
    local family="$1" destdir="$2" nosuffix="$BR_TOOLCHAINS/$family--glibc--stable"
    [ -d "$destdir" ] || [ ! -d "$nosuffix" ] || mv "$nosuffix" "$destdir"
}

# Like p_bootlin but for an explicit GLIBCVER= pin. It lands in its own <alias>-<glibcver>
# directory so it cannot collide with, or silently move, a target still on the shared pin.
p_bootlin_pinned() {
    local name="$1" family="$2" ccname="$3" glibcver="$4" alias="$5"
    local rel; rel="$(bootlin_release_for_glibc "$glibcver")" || {
        echo "unknown GLIBCVER=$glibcver - no known Bootlin release ships it for $family" >&2
        return 1
    }
    local base="$family--glibc--stable-$rel"
    local destdir="$BR_TOOLCHAINS/$base"
    local tarball="$BR_DOWNLOADS/$base.tar.bz2"
    if ! toolchain_smoke_ok "$destdir/bin/$ccname"; then
        [ -e "$destdir" ] && { echo "  $destdir present but fails a smoke compile - re-fetching" >&2; rm -rf "$destdir"; }
        fetch "https://toolchains.bootlin.com/downloads/releases/toolchains/$family/tarballs/$base.tar.bz2" "" "$tarball" \
            || { log_status "$name" "FAILED (download)"; return 1; }
        mkdir -p "$BR_TOOLCHAINS" && tar xjf "$tarball" -C "$BR_TOOLCHAINS" || { log_status "$name" "FAILED (extract)"; return 1; }
        bootlin_fixup_extracted_dirname "$family" "$destdir"
        toolchain_smoke_ok "$destdir/bin/$ccname" \
            || { log_status "$name" "FAILED (extracted, but $destdir/bin/$ccname fails a smoke compile)"; return 1; }
    fi
    local tc_dir; tc_dir="$(cd "$REPO/.." && pwd)/ToolChains"
    mkdir -p "$tc_dir"
    ln -sfn "$destdir" "$tc_dir/$alias-$glibcver"
    log_status "$name" "OK (glibc $glibcver pinned -> $tc_dir/$alias-$glibcver)"
}

# ---------------------------------------------------------------- osxcross --
# Builds osxcross in $OSXCROSS_DIR. The default run skips it, without failing, when no SDK
# is available, because the SDK is Apple-licensed and never downloaded from anywhere public.
# The SDK is taken from $OSXCROSS_SDK_TARBALL, then an Xcode_<ver>_Universal.xip in $BR_DOWNLOADS, then $OSXCROSS_SDK_URL. See BUILD.md.
OSXCROSS_APT="clang llvm-dev libxml2-dev uuid-dev libssl-dev libbz2-dev zlib1g-dev cmake patch cpio git python3"
osxcross_cc() { ls "$OSXCROSS_BIN"/aarch64-apple-darwin*-clang 2>/dev/null | head -1; }
# The probe includes the SDK's libc headers because a broken SDK with NULLcanary headers
# still passes a header-free compile. It also links, with $OSXCROSS_BIN on PATH the way
# the makefile runs it, because clang only finds <triple>-ld through PATH and otherwise uses host ld.
osxcross_smoke_ok() {
    [ -n "$1" ] || return 1
    local o; o=$(mktemp)
    printf '#include <stdio.h>\n#include <pthread.h>\nint main(void){puts("x");return 0;}\n' \
        | PATH="$OSXCROSS_BIN:$PATH" "$1" -x c -o "$o" - >/dev/null 2>&1
    local rc=$?; rm -f "$o"; return $rc
}
p_osxcross() {
    if [ "$(uname -s)" = Darwin ]; then log_status osxcross "not needed on macOS (Xcode clang)"; return 0; fi
    local cc; cc=$(osxcross_cc)
    if osxcross_smoke_ok "$cc"; then
        log_status osxcross "already present ($cc)"; return 0
    fi
    [ -n "$cc" ] && echo "  $cc exists but cannot compile a <stdio.h>/<pthread.h> program - rebuilding"
    # A tarball from the old pattern-only extraction is full of NULLcanary placeholder
    # headers, so quarantine it and extract again rather than build a toolchain that cannot compile hello.c.
    if [ -f "$OSXCROSS_SDK_TARBALL" ] && ! osxcross_sdk_ok "$OSXCROSS_SDK_TARBALL"; then
        echo "  $OSXCROSS_SDK_TARBALL has NULLcanary placeholder headers - moving to .broken, re-extracting"
        mv -f "$OSXCROSS_SDK_TARBALL" "$OSXCROSS_SDK_TARBALL.broken"
    fi
    if [ ! -f "$OSXCROSS_SDK_TARBALL" ]; then
        local xip; xip=$(ls "$BR_DOWNLOADS"/Xcode_*_Universal.xip 2>/dev/null | head -1)
        if [ -n "$xip" ]; then
            echo "  extracting the macOS SDK from $xip (xar + pbzx + cpio, a few minutes)"
            osxcross_extract_sdk "$xip" "$BR_DOWNLOADS" || { log_status osxcross "FAILED (SDK extraction from $xip)"; return 1; }
            osxcross_sdk_ok "$OSXCROSS_SDK_TARBALL" || { log_status osxcross "FAILED (extracted SDK still has placeholder headers)"; return 1; }
        elif [ -n "$OSXCROSS_SDK_URL" ]; then
            fetch "$OSXCROSS_SDK_URL" "" "$OSXCROSS_SDK_TARBALL" || { log_status osxcross "FAILED (download of OSXCROSS_SDK_URL)"; return 1; }
        fi
    fi
    local miss; miss="$(missing_apt_packages $OSXCROSS_APT)"
    [ -z "$miss" ] || offer_apt "osxcross build prerequisites" "$miss" || { log_status osxcross "FAILED (missing:$miss)"; return 1; }
    osxcross_clone || { log_status osxcross "FAILED (clone)"; return 1; }
    mkdir -p "$OSXCROSS_DIR/tarballs"
    # Only the pinned SDK goes in, because build.sh picks whichever tarballs/ holds.
    cmp -s "$OSXCROSS_SDK_TARBALL" "$OSXCROSS_DIR/tarballs/$(basename "$OSXCROSS_SDK_TARBALL")" \
        || cp -f "$OSXCROSS_SDK_TARBALL" "$OSXCROSS_DIR/tarballs/"
    # SDK_VERSION and BUILD_FLAVOR must be explicit or build.sh prompts and, under set -e,
    # dies silently on EOF. UNATTENDED skips its final confirmation. Every run rebuilds
    # cctools and ld64 from scratch, about 15 minutes, since build.sh has no incremental mode.
    echo "  building/configuring/testing the osxcross environment (SDK $OSXCROSS_SDK_VER, cctools, ld64, clang wrappers)"
    echo "  log: $OSXCROSS_DIR/build.log"
    ( cd "$OSXCROSS_DIR" && SDK_VERSION="$OSXCROSS_SDK_VER" BUILD_FLAVOR=latest UNATTENDED=1 \
        JOBS="$(nproc 2>/dev/null || echo 2)" ./build.sh >build.log 2>&1 ) \
        || { log_status osxcross "FAILED (build - $(grep -m1 -E 'error:|Error|failed' "$OSXCROSS_DIR/build.log" | cut -c1-120); see $OSXCROSS_DIR/build.log)"; return 1; }
    cc=$(osxcross_cc)
    osxcross_smoke_ok "$cc" \
        && log_status osxcross "OK ($cc, SDK $OSXCROSS_SDK_VER)" \
        || { log_status osxcross "FAILED (built, but no working aarch64-apple-darwin*-clang in $OSXCROSS_BIN)"; return 1; }
}

# --------------------------------------------------------------- rcodesign --
# rcodesign from apple-codesign signs the macOS agents on Linux and macOS alike through
# build-env.sh's macos_sign. The checksum comes from the release's own .sha256 sidecar.
p_rcodesign() {
    if [ -x "$RCODESIGN" ] && "$RCODESIGN" --version 2>/dev/null | grep -q "$APPLE_CODESIGN_VER"; then
        log_status rcodesign "already present ($APPLE_CODESIGN_VER)"; return 0
    fi
    local asset; asset=$(rcodesign_asset) || { log_status rcodesign "FAILED (no release asset for $(uname -s)/$(uname -m))"; return 1; }
    local sha; sha=$(curl -sSL --fail "$(rcodesign_url "$asset.sha256")" | awk '{print $1}')
    echo "$sha" | grep -qE '^[0-9a-f]{64}$' || { log_status rcodesign "FAILED (couldn't fetch $asset.sha256)"; return 1; }
    fetch "$(rcodesign_url "$asset")" "$sha" "$BR_DOWNLOADS/$asset" || { log_status rcodesign "FAILED (download)"; return 1; }
    # The member is named explicitly because macOS bsdtar has no --wildcards.
    mkdir -p "$BUILDROOT/bin" \
        && tar xzf "$BR_DOWNLOADS/$asset" -C "$BUILDROOT/bin" --strip-components=1 "${asset%.tar.gz}/rcodesign" \
        && chmod +x "$RCODESIGN" \
        && "$RCODESIGN" --version >/dev/null 2>&1 \
        && log_status rcodesign "OK ($APPLE_CODESIGN_VER -> $RCODESIGN)" \
        || { log_status rcodesign "FAILED (extract/run)"; return 1; }
}

# ---------------------------------------------------------- not fetchable ----
# These have no stable public URL, so they are genuinely bring-your-own and only reported.

# Shared between check_host_deps's message and print_manual so the two never drift apart.
APT_PACKAGES="gcc gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi gcc-arm-linux-gnueabihf gcc-mips-linux-gnu gcc-mipsel-linux-gnu gcc-riscv64-linux-gnu libc6-dev-i386 lib32gcc-14-dev musl-tools clang lld make perl curl tar xz-utils zstd libx11-dev libxext-dev libxtst-dev libxrandr-dev"

print_manual() {
    echo
    echo "NOT fetchable by this script - bring your own (see README.md 'Sources'):"
    [ -n "$(osxcross_cc)" ] || echo "  - $OSXCROSS_BIN  (osxcross: './fetch-toolchains.sh osxcross' builds it, but the Apple-licensed SDK must be supplied - see p_osxcross)"
    echo
    echo "Host apt prerequisites (this script offers to install these):"
    echo "  sudo apt-get install -y $APT_PACKAGES"
    echo "  (NOT gcc-multilib - on Debian trixie/Ubuntu 24.10+ that metapackage's"
    echo "  gcc-14-multilib dependency Conflicts with every gcc-14-<target>-linux-gnu"
    echo "  cross package. libc6-dev-i386 + lib32gcc-14-dev are the same underlying"
    echo "  32-bit runtime gcc-multilib pulls in - 'gcc -m32' works identically -"
    echo "  without the metapackage-level conflict.)"
}

# Commands this script itself needs. apt_pkg_for maps a command to its
# apt package where the two names differ.
HOST_DEPS="curl tar xz zstd bzip2 perl"
# A macOS host only ever fetches the OpenSSL tarball, since the cross toolchains
# are Linux-only, so the Linux-side extractors are not demanded there.
[ "$(uname -s)" = Darwin ] && HOST_DEPS="curl tar perl"
apt_pkg_for() { case "$1" in xz) echo xz-utils ;; *) echo "$1" ;; esac; }

# Echoes the subset of $* that dpkg does not have installed. Stays silent,
# meaning nothing missing, when there is no dpkg-query to ask.
missing_apt_packages() {
    command -v dpkg-query >/dev/null 2>&1 || return 0
    local pkg out=""
    for pkg in "$@"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed" || out="$out $pkg"
    done
    echo "$out"
}

# Prompts before apt-get install, defaulting to yes, unless -y was given.
# Returns 1 when nothing was installed and lets the caller decide whether that is fatal.
offer_apt() {
    local what="$1" pkgs="$2" sudo="" reply
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "  no apt-get here - install the equivalent of:$pkgs" >&2; return 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || { echo "  not root and no sudo - install manually:$pkgs" >&2; return 1; }
        sudo=sudo
    fi

    if [ "$ASSUME_YES" = 1 ]; then
        reply=y
    elif [ -t 0 ]; then
        read -r -p "  Install $what now with '${sudo:+$sudo }apt-get install -y$pkgs'? [Y/n] " reply
    else
        reply=n
        echo "  (stdin is not a terminal - re-run with -y to install without asking)" >&2
    fi
    case "$reply" in
        ""|[yY]|[yY][eE][sS]) ;;
        *) echo "  not installing $what." >&2; return 1 ;;
    esac

    $sudo apt-get update && $sudo apt-get install -y $pkgs \
        || { echo "ERROR: apt-get failed - install manually:$pkgs" >&2; return 1; }
}

# curl, tar, xz, zstd and perl are checked upfront instead of failing halfway
# with a bare "command not found". Without them the script can do nothing, so this is fatal.
check_host_deps() {
    local missing="" cmd pkgs=""
    for cmd in $HOST_DEPS; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] && return 0

    for cmd in $missing; do pkgs="$pkgs $(apt_pkg_for "$cmd")"; done
    echo "Missing required command(s):$missing" >&2
    offer_apt "them" "$pkgs" || { print_manual >&2; exit 1; }

    missing=""
    for cmd in $HOST_DEPS; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] || { echo "ERROR: still missing after install:$missing" >&2; exit 1; }
}

# Prints the per-package installed or MISSING table that check_cross_prereqs decides on.
print_dep_status() {
    local pkg n=0 miss=0
    echo "Host commands this script needs:"
    for pkg in $HOST_DEPS; do
        command -v "$pkg" >/dev/null 2>&1 \
            && printf "  present  %s\n" "$pkg" || printf "  MISSING  %s\n" "$pkg"
    done
    echo "Apt prerequisites for the openssl cross-builds:"
    for pkg in $APT_PACKAGES; do
        n=$((n+1))
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            printf "  present  %s\n" "$pkg"
        else
            printf "  MISSING  %s\n" "$pkg"; miss=$((miss+1))
        fi
    done
    echo "  ($((n-miss))/$n installed)"
}

# The cross-compilers are only needed later by the openssl build scripts, not by
# this script, so declining is non-fatal and just noted in the summary.
check_cross_prereqs() {
    local pkgs; pkgs="$(missing_apt_packages $APT_PACKAGES)"
    local total; total=$(set -- $APT_PACKAGES; echo $#)
    [ -z "$pkgs" ] && { log_status prerequisites "all $total apt prerequisites already installed - nothing to ask"; return 0; }
    echo "Missing apt prerequisites for the openssl cross-builds:$pkgs" >&2
    if offer_apt "prerequisites" "$pkgs"; then
        pkgs="$(missing_apt_packages $APT_PACKAGES)"
        [ -z "$pkgs" ] && log_status prerequisites "installed" \
                       || log_status prerequisites "STILL MISSING:$pkgs"
    else
        log_status prerequisites "SKIPPED - still missing:$pkgs"
    fi
    return 0
}

# ---------------------------------------------------------- makefile wiring -
# Symlinks only the OpenWrt toolchains that `make ARCHID=28`, `36` and `40` need.
wire_makefile_toolchains() {
    local tc_dir; tc_dir="$(cd "$REPO/.." && pwd)/ToolChains"
    mkdir -p "$tc_dir"
    local name src
    for pair in "toolchain-mips_24kc_gcc-${_OWRT_GCC}_musl:$TC_OWRT_MIPS24KC" \
                "toolchain-mipsel_24kc_gcc-${_OWRT_GCC}_musl:$TC_OWRT_MIPSEL24KC" \
                "toolchain-x86_64_gcc-${_OWRT_GCC}_musl:$TC_OWRT_X86_64" \
                "toolchain-aarch64_generic_gcc-${_OWRT_GCC}_musl:$TC_OWRT_AARCH64_A53" \
                "toolchain-arm_cortex-a15+neon-vfpv4_gcc-${_OWRT_GCC}_musl_eabi:$TC_OWRT_ARMVIRT32"; do
        name="${pair%%:*}"; src="${pair#*:}"
        if [ -d "$src" ]; then
            # The makefile points at the version-less alias so the next
            # gcc bump is not also a makefile edit.
            ln -sfn "$src" "$tc_dir/$name"
            ln -sfn "$src" "$tc_dir/$(echo "$name" | sed -E 's/_gcc-[0-9.]+_musl(_eabi)?$/_musl\1/')"
            log_status "makefile-wiring:$name" "-> $src (enables agent ARCHID build)"
        fi
    done
    # Each musl.cc and Bootlin toolchain gets a version-less alias so a pin bump is a
    # one-line build-env.sh edit, not a makefile edit. ARCHID 35 reuses the same musl.cc
    # armhf toolchain OpenSSL is already built with. See ISSUES.md.
    for pair in "armv5-eabi-glibc:$TC_ARMV5_BOOTLIN" \
                "armv7-eabihf-glibc:$TC_ARMV7HF_BOOTLIN" \
                "aarch64-glibc:$TC_AARCH64_BOOTLIN" \
                "mips32el-uclibc:$TC_MIPSEL_UCLIBC_BOOTLIN" \
                "x86-i686-glibc:$TC_X86_BOOTLIN" \
                "x86-64-glibc:$TC_X86_64_BOOTLIN" \
                "arm-linux-musleabihf-cross:$TC_ARMV7_MUSL_HF" \
                "aarch64-linux-musl-cross:$TC_AARCH64_A53_MUSL" \
                "x86_64-linux-musl-cross:$TC_X86_64_MUSL" \
                "riscv64-linux-musl-cross:$TC_RISCV64_MUSL" \
                "riscv32-linux-musl-cross:$TC_RISCV32_MUSL" \
                "riscv64-linux-musl-x86_64:$TC_RISCV64_XTHEAD"; do
        name="${pair%%:*}"; src="${pair#*:}"
        if [ -d "$src" ]; then
            ln -sfn "$src" "$tc_dir/$name"
            log_status "makefile-wiring:$name" "-> $src (enables agent ARCHID build)"
        fi
    done
}

# --------------------------------------------------------------------- main --
ALL="openssl openwrt-mips24kc openwrt-mipsel24kc openwrt-openwrt_x86_64 openwrt-aarch64-cortex-a53 openwrt-armvirt32 muslcc-aarch64 muslcc-armhf muslcc-x86_64 muslcc-riscv64 muslcc-riscv32 riscv64-xthead \
bootlin-armv5 bootlin-armv7hf bootlin-aarch64 bootlin-mipsel-uclibc bootlin-x86 bootlin-x86-64 freebsd openbsd rcodesign osxcross"

usage() {
    cat <<EOF
Download+verify+extract every cross toolchain, sysroot and source with a stable
public URL, and wire the two OpenWrt toolchains the makefile needs (ARCHID 28/40).
Safe to re-run - anything already present and passing its check is skipped.

  ./fetch-toolchains.sh                   everything fetchable
  ./fetch-toolchains.sh list              show status, fetch nothing
  ./fetch-toolchains.sh deps              show which packages are installed
  ./fetch-toolchains.sh help              this message
  ./fetch-toolchains.sh freebsd openbsd   named components only
  ./fetch-toolchains.sh osxcross          macOS cross toolchain (Linux only). Built when the
                                          Apple-licensed SDK is supplied locally (see below);
                                          the no-argument run skips it otherwise, naming it
                                          explicitly makes a missing SDK fatal.
  ./fetch-toolchains.sh rcodesign         apple-codesign's rcodesign (signs the macOS agents)
  ./fetch-toolchains.sh -y [components]   answer the apt-get prompts yes

Missing packages are offered for install (default yes): the host deps this
script needs ($HOST_DEPS), then the cross-compilers
the openssl build scripts need.

Components:
$(for c in $ALL; do echo "  $c"; done)

Paths - BUILDROOT defaults to /opt/buildroot; override it in the environment:
  BUILDROOT=/data/buildroot ./fetch-toolchains.sh

  BUILDROOT       $BUILDROOT
  downloads       $BR_DOWNLOADS
  toolchains      $BR_TOOLCHAINS
  sysroots        $BR_SYSROOTS
  osxcross        $OSXCROSS_BIN
  rcodesign       $RCODESIGN
  signing id      $MACOS_SIGN_P12  (self-signed, generated on first 'make macos' if absent)
  repo (staged)   $REPO
EOF
    print_manual
}

# -y answers the "install missing host deps?" prompt up front so CI never blocks on it.
ASSUME_YES="${ASSUME_YES:-0}"
case "$1" in -y|--yes) ASSUME_YES=1; shift ;; esac

case "$1" in
    help|-h|--help) usage; exit 0 ;;
    # Both are read-only, so they report status without demanding the fetch and extract tools.
    deps) print_dep_status; exit 0 ;;
    list) print_dep_status; echo; br_check; exit $? ;;
esac

check_host_deps
# Only the "fetch everything" run offers to install the full cross-compiler set.
# A single-component call such as `fetch-toolchains.sh freebsd` or a CI call for one target must not.
[ $# -eq 0 ] && check_cross_prereqs
mkdir -p "$BR_DOWNLOADS" "$BR_SYSROOTS" "$BR_TOOLCHAINS"

# GLIBCVER=<version> routes a bootlin-* component to p_bootlin_pinned instead
# of the shared $_BOOTLIN default. See bootlin_release_for_glibc in build-env.sh.
GLIBCVER="${GLIBCVER:-}"
bootlin_dispatch() {
    local name="$1" family="$2" destvar="$3" ccname="$4" alias="$5"
    if [ -n "$GLIBCVER" ]; then
        p_bootlin_pinned "$name" "$family" "$ccname" "$GLIBCVER" "$alias"
    else
        p_bootlin "$name" "$family" "$destvar" "$ccname"
    fi
}

run_one() {
    case "$1" in
        openssl)                p_openssl ;;
        openwrt-mips24kc)       p_openwrt mips24kc       ath79 generic TC_OWRT_MIPS24KC   mips-openwrt-linux-musl-gcc ;;
        openwrt-mipsel24kc)     p_openwrt mipsel24kc      ramips mt7621  TC_OWRT_MIPSEL24KC mipsel-openwrt-linux-musl-gcc ;;
        openwrt-openwrt_x86_64) p_openwrt openwrt_x86_64  x86    64      TC_OWRT_X86_64      x86_64-openwrt-linux-musl-gcc ;;
        openwrt-aarch64-cortex-a53) p_openwrt aarch64-cortex-a53 armsr armv8 TC_OWRT_AARCH64_A53 aarch64-openwrt-linux-gcc ;;
        openwrt-armvirt32)      p_openwrt armvirt32       armsr  armv7   TC_OWRT_ARMVIRT32   arm-openwrt-linux-gcc "_eabi" ;;
        muslcc-aarch64)         p_muslcc muslcc-aarch64 TC_AARCH64_A53_MUSL ;;
        muslcc-armhf)           p_muslcc muslcc-armhf   TC_ARMV7_MUSL_HF ;;
        muslcc-x86_64)          p_muslcc muslcc-x86_64  TC_X86_64_MUSL ;;
        muslcc-riscv64)         p_muslcc muslcc-riscv64 TC_RISCV64_MUSL ;;
        muslcc-riscv32)         p_muslcc muslcc-riscv32 TC_RISCV32_MUSL ;;
        riscv64-xthead)         p_riscv64_xthead ;;
        bootlin-armv5)          bootlin_dispatch bootlin-armv5  armv5-eabi    TC_ARMV5_BOOTLIN     arm-linux-gcc     armv5-eabi-glibc ;;
        bootlin-armv7hf)        bootlin_dispatch bootlin-armv7hf armv7-eabihf TC_ARMV7HF_BOOTLIN   arm-linux-gcc     armv7-eabihf-glibc ;;
        bootlin-aarch64)        bootlin_dispatch bootlin-aarch64 aarch64      TC_AARCH64_BOOTLIN   aarch64-linux-gcc aarch64-glibc ;;
        bootlin-mipsel-uclibc)  p_bootlin bootlin-mipsel-uclibc mips32el TC_MIPSEL_UCLIBC_BOOTLIN mipsel-linux-gcc ;;
        bootlin-x86)            bootlin_dispatch bootlin-x86    x86-i686      TC_X86_BOOTLIN       i686-linux-gcc    x86-i686-glibc ;;
        bootlin-x86-64)         bootlin_dispatch bootlin-x86-64 x86-64-core-i7 TC_X86_64_BOOTLIN   x86_64-linux-gcc  x86-64-glibc ;;
        freebsd)                p_freebsd ;;
        openbsd)                p_openbsd ;;
        osxcross)               p_osxcross ;;
        rcodesign)              p_rcodesign ;;
        *) echo "unknown component: $1 - run '$0 help' for the list" >&2; return 2 ;;
    esac
}

list="$*"; EXPLICIT=1; [ -z "$list" ] && { list="$ALL"; EXPLICIT=0; }
rc=0
for c in $list; do
    echo "=== $c ==="
    run_one "$c" || rc=1
done
wire_makefile_toolchains

echo
echo "================= SUMMARY ================="
cat "$STATUS_LOG"
print_manual
exit $rc
