#!/bin/bash
# Download+verify+extract every cross toolchain, sysroot and source with a
# stable public URL into $BUILDROOT; prints manual instructions for the rest
# (see openssl/libstatic/build/README.md's "Sources"). Also wires two OpenWrt
# toolchains the makefile needs (ARCHID 28/40), which is why this lives at the
# repo root rather than under openssl/. Safe to re-run.
#
#   ./fetch-toolchains.sh                   # everything fetchable
#   ./fetch-toolchains.sh list              # show status, fetch nothing
#   ./fetch-toolchains.sh deps              # show which packages are installed
#   ./fetch-toolchains.sh help              # usage + resolved paths
#   ./fetch-toolchains.sh freebsd openbsd   # named components only
#   ./fetch-toolchains.sh -y                # answer the apt-get prompts yes

# Where the multi-GB toolchains/sysroots/downloads land. env.sh carries the
# same fallback; set BUILDROOT in the environment to override both.
export BUILDROOT="${BUILDROOT:-/opt/buildroot}"

. "$(dirname "$(readlink -f "$0")")/openssl/libstatic/build/env.sh"

STATUS_LOG="$(mktemp)"
trap 'rm -f "$STATUS_LOG"' EXIT
log_status() { echo "$1: $2" | tee -a "$STATUS_LOG" >&2; }

# True if dest reads clean as an archive (xz/gzip's own checksum) - catches a
# truncated download that a checksum-less fetch can't. Unknown ext = pass.
archive_ok() {
    case "$1" in
        *.tar.zst|*.zst)      zstd -t "$1"  >/dev/null 2>&1 ;;
        *.tar.xz|*.txz|*.xz)  xz -t "$1"    >/dev/null 2>&1 ;;
        *.tar.bz2|*.bz2)      bzip2 -t "$1" >/dev/null 2>&1 ;;
        *.tar.gz|*.tgz|*.gz)  gzip -t "$1"   >/dev/null 2>&1 ;;
        *) return 0 ;;
    esac
}

# download URL sha256 dest_file - skips if dest already matches sha256, or
# (no sha256 published) passes archive_ok; else deleted and re-fetched.
fetch() {
    local url="$1" sha="$2" dest="$3"
    if [ -f "$dest" ]; then
        if [ -n "$sha" ]; then
            if echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1; then
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
        echo "$sha  $dest" | sha256sum -c - || { echo "  CHECKSUM MISMATCH: $dest" >&2; rm -f "$dest"; return 1; }
    elif ! archive_ok "$dest"; then
        echo "  CORRUPT ARCHIVE (failed integrity check): $dest" >&2; rm -f "$dest"; return 1
    fi
}

# ---------------------------------------------------------------- OpenSSL ----
# sha256 isn't a hand-maintained pin - openssl.org's own <tarball>.sha256
# sidecar resolves for every release (current series or "old"), so it's looked
# up fresh here rather than kept in a separate checksum file.
openssl_sha256_lookup() {
    local url="https://www.openssl.org/source/openssl-$1.tar.gz.sha256" body sha
    body=$(curl -sSL --fail --retry 3 --retry-delay 2 "$url") || return 1
    # openssl.org's sidecar has two observed formats: a bare hex hash, or the
    # standard `sha256sum` two-column form ("<hash> *filename") - $1 covers both.
    sha=$(echo "$body" | awk '{print $1}')
    echo "$sha" | grep -qE '^[0-9a-f]{64}$' || return 1
    echo "$sha"
}

p_openssl() {
    local sha; sha=$(openssl_sha256_lookup "$OPENSSL_VERSION") \
        || { log_status openssl "FAILED (couldn't look up sha256 for $OPENSSL_VERSION from openssl.org)"; return 1; }
    # 1.x is tagged OpenSSL_1_1_1w; 3.x and later, openssl-3.5.7.
    local tag; case "$OPENSSL_VERSION" in
        1.*) tag="OpenSSL_${OPENSSL_VERSION//./_}" ;;
        *)   tag="openssl-$OPENSSL_VERSION" ;;
    esac
    fetch "https://github.com/openssl/openssl/releases/download/$tag/openssl-$OPENSSL_VERSION.tar.gz" \
        "$sha" "$OPENSSL_TARBALL" \
        && log_status openssl "OK ($OPENSSL_VERSION, sha256 looked up from openssl.org)" || { log_status openssl "FAILED"; return 1; }
}

# True if $1 (a cross-gcc) can actually compile, not just exist - a truncated
# tarball can extract a working bin/*-gcc wrapper while cc1 is still empty.
toolchain_smoke_ok() {
    [ -x "$1" ] || return 1
    echo 'typedef int x;' | "$1" -c -x c -o /dev/null - >/dev/null 2>&1
}

# -------------------------------------------------------------- OpenWrt SDKs -
# No published checksum for the SDKs - verified via toolchain_smoke_ok instead.
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
# Pre-trimmed sysroots (usr/include + usr/lib + lib, built by
# build-bsd-sysroot-archives.sh) are mirrored at PTR-inc/meshagent-toolchains
# so a fetch is one small file instead of the ~200-600MB upstream release
# tarball. Falls back to fetching+trimming from the real upstream release if
# the mirror doesn't have this OS release yet.
# media.githubusercontent.com, not raw.githubusercontent.com - the mirror
# repo tracks *.tar.* via Git LFS (see its .gitattributes), and raw.* only
# serves the LFS pointer text, not the actual archive.
MESHAGENT_TOOLCHAINS_RAW="https://media.githubusercontent.com/media/PTR-inc/meshagent-toolchains/main"

# name sysroot_dir url -> 0 and extracts if the mirror has it, 1 if not (not fatal)
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

# usr/include + usr/lib + lib/ - usr/lib's libfoo.so symlinks need that last one.
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

# OpenBSD splits base79.tgz (runtime) from comp79.tgz (headers/crt objects) -
# base79 alone has an EMPTY usr/include, so both sets are fetched here.
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

# ------------------------------------------------------------ musl.cc cross ----
# Prebuilt musl cross toolchains (~100MB each). No published checksum, so each
# is gated on a real smoke compile rather than a hash.
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
# Pinned-release glibc/uClibc cross toolchains (~100MB each). No published
# checksum, so each is gated on a real smoke compile rather than a hash. Pinned
# (not "latest") so the glibc/uClibc floor these toolchains produce is a
# deliberate, reproducible choice - see meshagent-archid-glibc-floor.md.
p_bootlin() {
    local name="$1" family="$2" destvar="$3" ccname="$4"
    local destdir="${!destvar}" base; base="$(basename "$destdir")"
    local tarball="$BR_DOWNLOADS/$base.tar.bz2"
    toolchain_smoke_ok "$destdir/bin/$ccname" && { log_status "$name" "already present"; return 0; }
    [ -e "$destdir" ] && { echo "  $destdir present but fails a smoke compile - re-fetching" >&2; rm -rf "$destdir"; }
    fetch "https://toolchains.bootlin.com/downloads/releases/toolchains/$family/tarballs/$base.tar.bz2" "" "$tarball" \
        || { log_status "$name" "FAILED (download)"; return 1; }
    mkdir -p "$BR_TOOLCHAINS" && tar xjf "$tarball" -C "$BR_TOOLCHAINS" || { log_status "$name" "FAILED (extract)"; return 1; }
    toolchain_smoke_ok "$destdir/bin/$ccname" \
        && log_status "$name" "OK" \
        || { log_status "$name" "FAILED (extracted, but $destdir/bin/$ccname fails a smoke compile)"; return 1; }
}

# ---------------------------------------------------------- not fetchable ----
# No stable public URL for these - genuinely bring-your-own, reported only.

# apt package list, shared between check_host_deps's message and print_manual.
APT_PACKAGES="gcc gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi gcc-arm-linux-gnueabihf gcc-mips-linux-gnu gcc-mipsel-linux-gnu gcc-riscv64-linux-gnu libc6-dev-i386 lib32gcc-14-dev musl-tools clang lld make perl curl tar xz-utils zstd libx11-dev libxext-dev libxtst-dev libxrandr-dev"

print_manual() {
    echo
    echo "NOT fetchable by this script - bring your own (see README.md 'Sources'):"
    [ -d "$OSXCROSS_BIN" ]            || echo "  - $OSXCROSS_BIN  (osxcross, built from an Apple-distributed Xcode .xip)"
    echo
    echo "Host apt prerequisites (this script offers to install these):"
    echo "  sudo apt-get install -y $APT_PACKAGES"
    echo "  (NOT gcc-multilib - on Debian trixie/Ubuntu 24.10+ that metapackage's"
    echo "  gcc-14-multilib dependency Conflicts with every gcc-14-<target>-linux-gnu"
    echo "  cross package. libc6-dev-i386 + lib32gcc-14-dev are the same underlying"
    echo "  32-bit runtime gcc-multilib pulls in - 'gcc -m32' works identically -"
    echo "  without the metapackage-level conflict.)"
}

# Commands this script itself needs, and the apt package carrying each where
# the two names differ.
HOST_DEPS="curl tar xz zstd bzip2 perl"
apt_pkg_for() { case "$1" in xz) echo xz-utils ;; *) echo "$1" ;; esac; }

# Echoes the subset of $* that dpkg doesn't have installed. Silent (nothing
# missing) if there's no dpkg-query to ask.
missing_apt_packages() {
    command -v dpkg-query >/dev/null 2>&1 || return 0
    local pkg out=""
    for pkg in "$@"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed" || out="$out $pkg"
    done
    echo "$out"
}

# apt-get install $2, prompting first (default yes) unless -y was given.
# Returns 1 if nothing was installed - callers decide whether that's fatal.
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

# Needs curl (fetch), tar/xz/zstd (extract) and perl (OpenSSL's Configure) -
# checked upfront instead of failing halfway with a bare "command not found".
# Fatal: without these the script can't do anything.
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

# Per-package installed/MISSING table - what check_cross_prereqs decides on.
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

# The cross-compilers and friends the openssl build scripts need later. This
# script doesn't use them, so declining is non-fatal - just noted in the summary.
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
# Symlinks the OpenWrt toolchains `make ARCHID=28`/`36`/`40` need; others aren't.
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
            # Versioned name plus a version-less alias - point the makefile at the
            # alias so the next gcc bump is not also a makefile edit.
            ln -sfn "$src" "$tc_dir/$name"
            ln -sfn "$src" "$tc_dir/$(echo "$name" | sed -E 's/_gcc-[0-9.]+_musl(_eabi)?$/_musl\1/')"
            log_status "makefile-wiring:$name" "-> $src (enables agent ARCHID build)"
        fi
    done
    # musl.cc / Bootlin toolchains -> a version-less alias each, so a pin bump
    # (env.sh's _BOOTLIN, or a musl.cc rename) is a one-line env.sh edit, not a
    # makefile edit. ARCHID 35 (armada370-hf) reuses the same musl.cc armhf
    # toolchain OpenSSL is already built with - see meshagent-archid-glibc-floor.md.
    for pair in "armv5-eabi-glibc:$TC_ARMV5_BOOTLIN" \
                "armv7-eabihf-glibc:$TC_ARMV7HF_BOOTLIN" \
                "aarch64-glibc:$TC_AARCH64_BOOTLIN" \
                "mips32el-uclibc:$TC_MIPSEL_UCLIBC_BOOTLIN" \
                "x86-i686-glibc:$TC_X86_BOOTLIN" \
                "x86-64-glibc:$TC_X86_64_BOOTLIN" \
                "arm-linux-musleabihf-cross:$TC_ARMV7_MUSL_HF" \
                "aarch64-linux-musl-cross:$TC_AARCH64_A53_MUSL" \
                "x86_64-linux-musl-cross:$TC_X86_64_MUSL"; do
        name="${pair%%:*}"; src="${pair#*:}"
        if [ -d "$src" ]; then
            ln -sfn "$src" "$tc_dir/$name"
            log_status "makefile-wiring:$name" "-> $src (enables agent ARCHID build)"
        fi
    done
}

# --------------------------------------------------------------------- main --
ALL="openssl openwrt-mips24kc openwrt-mipsel24kc openwrt-openwrt_x86_64 openwrt-aarch64-cortex-a53 openwrt-armvirt32 muslcc-aarch64 muslcc-armhf muslcc-x86_64 \
bootlin-armv5 bootlin-armv7hf bootlin-aarch64 bootlin-mipsel-uclibc bootlin-x86 bootlin-x86-64 freebsd openbsd"

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
  repo (staged)   $REPO
EOF
    print_manual
}

# -y answers the "install missing host deps?" prompt up front.
ASSUME_YES="${ASSUME_YES:-0}"
case "$1" in -y|--yes) ASSUME_YES=1; shift ;; esac

case "$1" in
    help|-h|--help) usage; exit 0 ;;
    # Both read-only: report status without demanding the fetch/extract tools.
    deps) print_dep_status; exit 0 ;;
    list) print_dep_status; echo; br_check; exit $? ;;
esac

check_host_deps
check_cross_prereqs
mkdir -p "$BR_DOWNLOADS" "$BR_SYSROOTS" "$BR_TOOLCHAINS"

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
        bootlin-armv5)          p_bootlin bootlin-armv5  armv5-eabi    TC_ARMV5_BOOTLIN     arm-linux-gcc ;;
        bootlin-armv7hf)        p_bootlin bootlin-armv7hf armv7-eabihf TC_ARMV7HF_BOOTLIN   arm-linux-gcc ;;
        bootlin-aarch64)        p_bootlin bootlin-aarch64 aarch64      TC_AARCH64_BOOTLIN   aarch64-linux-gcc ;;
        bootlin-mipsel-uclibc)  p_bootlin bootlin-mipsel-uclibc mips32el TC_MIPSEL_UCLIBC_BOOTLIN mipsel-linux-gcc ;;
        bootlin-x86)            p_bootlin bootlin-x86    x86-i686      TC_X86_BOOTLIN       i686-linux-gcc ;;
        bootlin-x86-64)         p_bootlin bootlin-x86-64 x86-64-core-i7 TC_X86_64_BOOTLIN   x86_64-linux-gcc ;;
        freebsd)                p_freebsd ;;
        openbsd)                p_openbsd ;;
        *) echo "unknown component: $1 - run '$0 help' for the list" >&2; return 2 ;;
    esac
}

list="$*"; [ -z "$list" ] && list="$ALL"
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
