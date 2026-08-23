#!/bin/bash
# Build small, streamable FreeBSD/OpenBSD sysroot archives from the full
# upstream release tarballs, containing only what the makefile's CROSS=1 BSD
# builds actually need (usr/include, usr/lib, and for FreeBSD also lib).
# Output lands at the root of $BUILDROOT so it can be uploaded elsewhere and
# fetched by fetch-toolchains.sh/env.sh in a later step. Safe to re-run.
#
#   ./build-bsd-sysroot-archives.sh                  # both
#   ./build-bsd-sysroot-archives.sh freebsd           # one only
#   ./build-bsd-sysroot-archives.sh openbsd

set -euo pipefail

export BUILDROOT="${BUILDROOT:-/opt/buildroot}"
. "$(dirname "$(readlink -f "$0")")/openssl/libstatic/build/env.sh"

log() { echo "[$1] $2"; }

# Packs $2 (a directory of file args, relative to $1) as .tar.xz. Measured
# against zstd -19 on the largest archives here: zstd compressed ~25-30%
# faster but produced files 30-90% BIGGER, and both formats decompress in
# under 2s regardless - xz wins outright for this content, so it's the only
# format shipped.
pack_xz() {
    local workdir="$1" out_base="$2"; shift 2
    (cd "$workdir" && tar cf - "$@" | xz -T0 -9 -c) > "$out_base.tar.xz"
}

fetch() {
    local url="$1" sha="$2" dest="$3"
    if [ -f "$dest" ] && echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1; then
        return 0
    fi
    echo "  downloading $url"
    curl -sSL --fail --retry 3 --retry-delay 2 -o "$dest" "$url"
    echo "$sha  $dest" | sha256sum -c - || { echo "  CHECKSUM MISMATCH: $dest" >&2; rm -f "$dest"; return 1; }
}

build_freebsd() {
    local rel="https://download.freebsd.org/releases/amd64/amd64/$FREEBSD_REL-RELEASE"
    local dest="$BR_DOWNLOADS/freebsd-$FREEBSD_REL-base.txz"
    local out_base="$BUILDROOT/freebsd-$FREEBSD_REL-sysroot"
    log freebsd "looking up base.txz sha256"
    local sha; sha=$(curl -sSL --fail "$rel/MANIFEST" | awk '$1=="base.txz"{print $2}')
    [ -n "$sha" ] || { log freebsd "FAILED (couldn't fetch MANIFEST)"; return 1; }
    fetch "$rel/base.txz" "$sha" "$dest" || { log freebsd "FAILED (download)"; return 1; }

    local work; work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    log freebsd "extracting usr/include, usr/lib, lib"
    tar xf "$dest" -C "$work" ./usr/include ./usr/lib ./lib

    log freebsd "packing $out_base.tar.xz"
    pack_xz "$work" "$out_base" ./usr/include ./usr/lib ./lib
    log freebsd "OK -> $out_base.tar.xz ($(du -h "$out_base.tar.xz" | cut -f1))"
}

build_openbsd() {
    local nodot="${OPENBSD_REL//./}"
    local rel="https://cdn.openbsd.org/pub/OpenBSD/$OPENBSD_REL/amd64"
    local base_dest="$BR_DOWNLOADS/openbsd-$OPENBSD_REL-base$nodot.tgz"
    local comp_dest="$BR_DOWNLOADS/openbsd-$OPENBSD_REL-comp$nodot.tgz"
    local out_base="$BUILDROOT/openbsd-$OPENBSD_REL-sysroot"
    log openbsd "looking up base/comp sha256"
    local manifest; manifest=$(curl -sSL --fail "$rel/SHA256") || { log openbsd "FAILED (couldn't fetch SHA256 manifest)"; return 1; }
    local sha_base; sha_base=$(echo "$manifest" | awk -v f="base$nodot.tgz" '$0 ~ "\\(" f "\\)"{print $4}')
    local sha_comp; sha_comp=$(echo "$manifest" | awk -v f="comp$nodot.tgz" '$0 ~ "\\(" f "\\)"{print $4}')
    [ -n "$sha_base" ] && [ -n "$sha_comp" ] || { log openbsd "FAILED (couldn't parse SHA256 manifest)"; return 1; }
    fetch "$rel/base$nodot.tgz" "$sha_base" "$base_dest" || { log openbsd "FAILED (base download)"; return 1; }
    fetch "$rel/comp$nodot.tgz" "$sha_comp" "$comp_dest" || { log openbsd "FAILED (comp download)"; return 1; }

    local work; work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    log openbsd "extracting usr/include, usr/lib from base+comp"
    tar xzf "$base_dest" -C "$work" ./usr/include ./usr/lib
    tar xzf "$comp_dest" -C "$work" ./usr/include ./usr/lib

    log openbsd "packing $out_base.tar.xz"
    pack_xz "$work" "$out_base" ./usr/include ./usr/lib
    log openbsd "OK -> $out_base.tar.xz ($(du -h "$out_base.tar.xz" | cut -f1))"
}

mkdir -p "$BR_DOWNLOADS"

list="$*"; [ -z "$list" ] && list="freebsd openbsd"
rc=0
for c in $list; do
    case "$c" in
        freebsd) build_freebsd || rc=1 ;;
        openbsd) build_openbsd || rc=1 ;;
        *) echo "unknown component: $c (expected freebsd or openbsd)" >&2; rc=2 ;;
    esac
done
exit $rc
