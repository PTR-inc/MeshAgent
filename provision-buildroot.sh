#!/bin/bash
# Provision $BUILDROOT: download+verify+extract every toolchain/sysroot/source
# that CAN be fetched from a stable public URL, and print exact manual
# instructions for the handful that genuinely can't (see
# openssl/libstatic/build/README.md's "Sources" section - this script follows
# that table component for component).
#
# NOT an OpenSSL-only tool: $BUILDROOT's toolchains are the same ones several
# makefile ARCHIDs need to cross-compile the AGENT itself (PATH_MIPS24KC/
# PATH_MIPSEL24KC etc. in the makefile) - this script lives at the repo root,
# not under openssl/, for exactly that reason. See the "makefile wiring"
# section below for which toolchains it symlinks into ../ToolChains/ (the
# makefile's own expected location) after fetching them.
#
#   ./provision-buildroot.sh                # everything fetchable
#   ./provision-buildroot.sh openssl freebsd # just these components
#   ./provision-buildroot.sh list            # show status, fetch nothing
#   BUILDROOT=/some/other/buildroot ./provision-buildroot.sh
#
# Safe to re-run: an already-present component is skipped, not re-downloaded.
. "$(dirname "$(readlink -f "$0")")/openssl/libstatic/build/env.sh"

mkdir -p "$BR_DOWNLOADS" "$BR_SYSROOTS" "$BR_TOOLCHAINS"

STATUS_LOG="$(mktemp)"
trap 'rm -f "$STATUS_LOG"' EXIT
log_status() { echo "$1: $2" | tee -a "$STATUS_LOG" >&2; }

# download URL sha256 dest_file
# Skips the download if dest_file already exists and matches sha256 (or no
# sha256 was given, in which case existence alone is enough).
fetch() {
    local url="$1" sha="$2" dest="$3"
    if [ -f "$dest" ]; then
        if [ -z "$sha" ] || echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1; then
            return 0
        fi
        echo "  $dest exists but fails checksum - re-downloading"
        rm -f "$dest"
    fi
    echo "  downloading $url"
    curl -sSL --fail -o "$dest" "$url" || { echo "  FETCH FAILED: $url" >&2; return 1; }
    if [ -n "$sha" ]; then
        echo "$sha  $dest" | sha256sum -c - || { echo "  CHECKSUM MISMATCH: $dest" >&2; rm -f "$dest"; return 1; }
    fi
}

# ---------------------------------------------------------------- OpenSSL ----
p_openssl() {
    [ -f "$OPENSSL_TARBALL" ] && echo "$OPENSSL_SHA256  $OPENSSL_TARBALL" | sha256sum -c - >/dev/null 2>&1 && { log_status openssl "already present"; return 0; }
    fetch "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VERSION//./_}/openssl-$OPENSSL_VERSION.tar.gz" \
        "$OPENSSL_SHA256" "$OPENSSL_TARBALL" \
        && log_status openssl "OK" || { log_status openssl "FAILED"; return 1; }
}

# -------------------------------------------------------------- OpenWrt SDKs -
# No published per-tarball checksum for this old (18.06.9) release - see
# README.md. Verified by extraction sanity (expected CC binary present)
# instead of a hash.
p_openwrt() {
    local name="$1" wtarget="$2" wsubtarget="$3" destvar="$4" ccbin="$5"
    local file="openwrt-sdk-18.06.9-${wtarget}-${wsubtarget}_gcc-7.3.0_musl.Linux-x86_64.tar.xz"
    local tarball="$BR_DOWNLOADS/$file"
    local destdir="${!destvar}"
    [ -x "$destdir/bin/$ccbin" ] && { log_status "$name" "already present"; return 0; }
    fetch "https://downloads.openwrt.org/releases/18.06.9/targets/$wtarget/$wsubtarget/$file" "" "$tarball" || { log_status "$name" "FAILED (download)"; return 1; }
    mkdir -p "$BR_TOOLCHAINS" && tar xf "$tarball" -C "$BR_TOOLCHAINS" || { log_status "$name" "FAILED (extract)"; return 1; }
    [ -x "$destdir/bin/$ccbin" ] \
        && log_status "$name" "OK" \
        || { log_status "$name" "FAILED (extracted, but $destdir/bin/$ccbin not found - archive layout changed?)"; return 1; }
}

# ------------------------------------------------------------ bootlin toolchains
# Bootlin does publish a per-tarball .sha256 next to the download, despite
# README.md's "no stable checksum" caveat. Fetched and pinned here.
p_bootlin() {
    local name="$1" arch="$2" tag="$3" destvar="$4"
    local file="$arch--$tag.tar.xz"
    local tarball="$BR_DOWNLOADS/$file"
    local destdir="${!destvar}"
    [ -d "$destdir" ] && { log_status "$name" "already present"; return 0; }
    local base="https://toolchains.bootlin.com/downloads/releases/toolchains/$arch/tarballs"
    local sha; sha=$(curl -sSL --fail "$base/${file%.tar.xz}.sha256" | awk '{print $1}')
    [ -n "$sha" ] || { log_status "$name" "FAILED (couldn't fetch .sha256 manifest)"; return 1; }
    fetch "$base/$file" "$sha" "$tarball" || { log_status "$name" "FAILED (download)"; return 1; }
    tar xf "$tarball" -C "$BR_TOOLCHAINS" || { log_status "$name" "FAILED (extract)"; return 1; }
    [ -d "$destdir" ] && log_status "$name" "OK" || { log_status "$name" "FAILED (extracted, but $destdir missing - archive top-level dir name changed?)"; return 1; }
}

# ------------------------------------------------------------- Arm GNU toolchain
# Unused by any target as of 2026-08-18 (see targets.sh/README.md) - fetched
# anyway since it's cheap and README lists it as part of the layout. Arm's own
# release archive top-level dir doesn't match the name env.sh expects
# (TC_ARMGNU_HF), so it's renamed after extraction.
p_armgnu() {
    [ -d "$TC_ARMGNU_HF" ] && { log_status armgnu "already present"; return 0; }
    local file="arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-linux-gnueabihf.tar.xz"
    local tarball="$BR_DOWNLOADS/$file"
    fetch "https://developer.arm.com/-/media/Files/downloads/gnu/15.2.rel1/binrel/$file" "" "$tarball" || { log_status armgnu "FAILED (download)"; return 1; }
    tar xf "$tarball" -C "$BR_TOOLCHAINS" || { log_status armgnu "FAILED (extract)"; return 1; }
    mv "$BR_TOOLCHAINS/${file%.tar.xz}" "$TC_ARMGNU_HF" \
        && log_status armgnu "OK" \
        || { log_status armgnu "FAILED (extracted, but rename to $TC_ARMGNU_HF failed)"; return 1; }
}

# --------------------------------------------------------------- BSD sysroots
# Only usr/include + usr/lib are pulled out of the base set - that's all
# Configure/clang need to cross-compile against (see README.md).
p_freebsd() {
    [ -d "$SYSROOT_FREEBSD/usr/include" ] && { log_status freebsd "already present"; return 0; }
    local rel="https://download.freebsd.org/releases/amd64/amd64/14.3-RELEASE"
    local sha; sha=$(curl -sSL --fail "$rel/MANIFEST" | awk '$1=="base.txz"{print $2}')
    [ -n "$sha" ] || { log_status freebsd "FAILED (couldn't fetch MANIFEST)"; return 1; }
    fetch "$rel/base.txz" "$sha" "$BR_DOWNLOADS/freebsd-14.3-base.txz" || { log_status freebsd "FAILED (download)"; return 1; }
    mkdir -p "$SYSROOT_FREEBSD"
    tar xf "$BR_DOWNLOADS/freebsd-14.3-base.txz" -C "$SYSROOT_FREEBSD" ./usr/include ./usr/lib \
        && log_status freebsd "OK" \
        || { log_status freebsd "FAILED (extract)"; return 1; }
}

p_openbsd() {
    [ -d "$SYSROOT_OPENBSD/usr/include" ] && { log_status openbsd "already present"; return 0; }
    local rel="https://cdn.openbsd.org/pub/OpenBSD/7.9/amd64"
    local sha; sha=$(curl -sSL --fail "$rel/SHA256" | awk '/^SHA256 \(base79.tgz\)/{print $4}')
    [ -n "$sha" ] || { log_status openbsd "FAILED (couldn't fetch SHA256 manifest)"; return 1; }
    fetch "$rel/base79.tgz" "$sha" "$BR_DOWNLOADS/openbsd-7.9-base79.tgz" || { log_status openbsd "FAILED (download)"; return 1; }
    mkdir -p "$SYSROOT_OPENBSD"
    tar xzf "$BR_DOWNLOADS/openbsd-7.9-base79.tgz" -C "$SYSROOT_OPENBSD" ./usr/include ./usr/lib \
        && log_status openbsd "OK" \
        || { log_status openbsd "FAILED (extract)"; return 1; }
}

# ------------------------------------------------------------ dd-wrt toolchains
# dd-wrt publishes one 4.2GB tar.xz with every current toolchain, including
# the 3 this buildroot needs - top-level dir names match env.sh's TC_* vars
# exactly (verified by listing). No published checksum. The download server
# aborts mid-transfer often - resumed with curl -C -/--http1.1 rather than
# restarted from scratch each time.
p_ddwrt() {
    [ -d "$TC_MIPS32EL_MUSL" ] && [ -d "$TC_AARCH64_CORTEXA53_MUSL" ] && [ -d "$TC_ARMV7_CORTEXA9_MUSL" ] \
        && { log_status ddwrt "already present"; return 0; }
    local url="https://download1.dd-wrt.com/dd-wrtv2/downloads/toolchains/toolchains.tar.xz"
    local tarball="$BR_DOWNLOADS/dd-wrt-toolchains.tar.xz"
    local i
    for i in $(seq 1 50); do
        curl --http1.1 -sS -C - --connect-timeout 20 --max-time 300 -o "$tarball" "$url" && break
    done
    [ -f "$tarball" ] || { log_status ddwrt "FAILED (download)"; return 1; }
    tar xf "$tarball" -C "$BR_TOOLCHAINS" \
        "$(basename "$TC_MIPS32EL_MUSL")" "$(basename "$TC_AARCH64_CORTEXA53_MUSL")" "$(basename "$TC_ARMV7_CORTEXA9_MUSL")" \
        || { log_status ddwrt "FAILED (extract)"; return 1; }
    [ -d "$TC_MIPS32EL_MUSL" ] && [ -d "$TC_AARCH64_CORTEXA53_MUSL" ] && [ -d "$TC_ARMV7_CORTEXA9_MUSL" ] \
        && log_status ddwrt "OK" \
        || { log_status ddwrt "FAILED (extracted, but an expected dir is missing - archive layout changed?)"; return 1; }
}

# ---------------------------------------------------------- not fetchable ----
# No stable public URL for these (README.md's "Sources" section) - genuinely
# bring-your-own. Reported, never attempted.
print_manual() {
    echo
    echo "NOT fetchable by this script - bring your own (see README.md 'Sources'):"
    [ -d "$OSXCROSS_BIN" ]            || echo "  - $OSXCROSS_BIN  (osxcross, built from an Apple-distributed Xcode .xip)"
    echo
    echo "Host apt prerequisites (not installed by this script - run manually):"
    echo "  sudo apt-get install -y gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \\"
    echo "    gcc-arm-linux-gnueabihf gcc-mips-linux-gnu gcc-mipsel-linux-gnu \\"
    echo "    gcc-riscv64-linux-gnu gcc-multilib musl-tools clang lld"
}

# ---------------------------------------------------------- makefile wiring -
# The makefile expects two of these OpenWrt toolchains at ../ToolChains/<name>/
# (PATH_MIPS24KC/PATH_MIPSEL24KC) - symlinked in for `make linux ARCHID=28`/
# `ARCHID=40`. The rest of the PATH_* vars aren't wired: different names/
# versions, or no public URL.
wire_makefile_toolchains() {
    local tc_dir; tc_dir="$(cd "$REPO/.." && pwd)/ToolChains"
    mkdir -p "$tc_dir"
    local name src
    for pair in "toolchain-mips_24kc_gcc-7.3.0_musl:$TC_OWRT_MIPS24KC" \
                "toolchain-mipsel_24kc_gcc-7.3.0_musl:$TC_OWRT_MIPSEL24KC"; do
        name="${pair%%:*}"; src="${pair#*:}"
        if [ -d "$src" ]; then
            ln -sfn "$src" "$tc_dir/$name"
            log_status "makefile-wiring:$name" "-> $src (enables agent ARCHID build)"
        fi
    done
}

# --------------------------------------------------------------------- main --
ALL="openssl openwrt-mips24kc openwrt-mipsel24kc openwrt-openwrt_x86_64 bootlin-mips32el bootlin-riscv64 armgnu freebsd openbsd ddwrt"

run_one() {
    case "$1" in
        openssl)                p_openssl ;;
        openwrt-mips24kc)       p_openwrt mips24kc       ar71xx generic TC_OWRT_MIPS24KC   mips-openwrt-linux-musl-gcc ;;
        openwrt-mipsel24kc)     p_openwrt mipsel24kc      ramips mt7621  TC_OWRT_MIPSEL24KC mipsel-openwrt-linux-musl-gcc ;;
        openwrt-openwrt_x86_64) p_openwrt openwrt_x86_64  x86    64      TC_OWRT_X86_64      x86_64-openwrt-linux-musl-gcc ;;
        bootlin-mips32el)       p_bootlin bootlin-mips32el mips32el uclibc--stable-2025.08-1 TC_MIPS32EL_UCLIBC ;;
        bootlin-riscv64)        p_bootlin bootlin-riscv64  riscv64-lp64d musl--stable-2025.08-1 TC_RISCV64_MUSL ;;
        armgnu)                 p_armgnu ;;
        freebsd)                p_freebsd ;;
        openbsd)                p_openbsd ;;
        ddwrt)                  p_ddwrt ;;
        *) echo "unknown component: $1 (known: $ALL)" >&2; return 2 ;;
    esac
}

if [ "$1" = "list" ]; then
    br_check
    exit $?
fi

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
