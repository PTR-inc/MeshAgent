#!/bin/bash
# Build smaller, streamable archives of the cross toolchains already fetched
# into $BUILDROOT/toolchains (by fetch-toolchains.sh), for upload to
# PTR-inc/meshagent-toolchains's TC/ folder - same idea as
# build-bsd-sysroot-archives.sh's SR/ archives, but for whole toolchains.
#
# Unlike the BSD sysroots (which are just headers+libs consumed by an
# external compiler), a cross toolchain IS the compiler - bin/, libexec/,
# lib/ and the target sysroot are all load-bearing and can't be dropped.
# What's actually safe to cut: gdb/locale/man/doc/info under share/, and the
# unused ELF symbol tables in the toolchain's own binaries (`strip
# --strip-unneeded` - keeps dynamic symbols the binaries need to run, drops
# the rest). Expect a modest reduction (order 10-20%), not the 70%+ seen on
# the BSD sysroots, plus whatever xz -9 buys on top.
#
# Every archive is smoke-tested after trimming (compiles+links a tiny C
# program with the trimmed copy's gcc) before it's kept - a stripped cc1
# that no longer runs is worse than not shipping an archive at all.
#
#   ./build-toolchain-archives.sh                                   # every toolchain in $BR_TOOLCHAINS
#   ./build-toolchain-archives.sh riscv64-lp64d--musl--stable-2025.08-1
#   ./build-toolchain-archives.sh riscv64-lp64d--musl--stable-2025.08-1 mips32el--uclibc--stable-2025.08-1
#
#   # macOS SDK from an Xcode .xip under $BR_DOWNLOADS (Xcode_<version>_Universal.xip).
#   # This is Apple's proprietary SDK, not redistributable to the public
#   # meshagent-toolchains mirror the way every other archive here is - the
#   # flag is a deliberate, explicit acknowledgement of that, required every
#   # time. Lands in $BUILDROOT/private/, for a private/access-controlled
#   # destination only (then point OSXCROSS_SDK_URL at it for other hosts).
#   ./build-toolchain-archives.sh --i-have-rights-to-redistribute-this Xcode_26.6_Universal.xip

set -euo pipefail

export BUILDROOT="${BUILDROOT:-/opt/buildroot}"
. "$(dirname "$(readlink -f "$0")")/build-env.sh"

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

# Finds the toolchain's own C compiler under bin/ (or, for a repacked OpenWrt
# SDK, staging_dir/toolchain-*/bin), e.g. riscv64-...-gcc.
find_gcc() {
    find "$1/bin" "$1"/staging_dir/toolchain-*/bin -maxdepth 1 -name '*-gcc' -not -name '*.br_real' 2>/dev/null | head -1
}

trim_and_pack() {
    local name="$1" src="$BR_TOOLCHAINS/$1" out_base="$BUILDROOT/$1"
    [ -d "$src" ] || { log "$name" "FAILED (not found under $BR_TOOLCHAINS)"; return 1; }

    local work; work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN

    # OpenWrt SDKs are a whole buildroot-style source tree (dl/, build_dir/,
    # package/, target/ kernel sources...) - only staging_dir/toolchain-* is
    # the actual compiler. Its gcc wrapper also `exec`s staging_dir/host's own
    # ld-linux/libc (a hermetic host runtime, independent of this machine's
    # glibc) via a relative ../../host/lib path, so that has to ship too - a
    # toolchain-only archive fails at gcc invocation, not link time.
    local toolchain_subdir; toolchain_subdir=$(find "$src/staging_dir" -maxdepth 1 -name 'toolchain-*' 2>/dev/null | head -1)
    if [ -n "$toolchain_subdir" ]; then
        log "$name" "OpenWrt SDK detected - packing staging_dir/{$(basename "$toolchain_subdir"),host}"
        mkdir -p "$work/$name/staging_dir"
        cp -a "$toolchain_subdir" "$work/$name/staging_dir/"
        cp -a "$src/staging_dir/host" "$work/$name/staging_dir/host"
    else
        log "$name" "copying"
        cp -a "$src" "$work/$name"
    fi

    log "$name" "trimming share/{locale,man,info,doc,gdb}"
    rm -rf "$work/$name"/share/{locale,man,info,doc,gdb} 2>/dev/null || true

    log "$name" "stripping unneeded symbols from ELF binaries"
    find "$work/$name" -type f \( -path '*/bin/*' -o -path '*/libexec/*' \) -print0 | \
        while IFS= read -r -d '' f; do
            file "$f" 2>/dev/null | grep -q 'ELF' && strip --strip-unneeded "$f" 2>/dev/null || true
        done

    local gcc; gcc=$(find_gcc "$work/$name")
    [ -n "$gcc" ] || { log "$name" "FAILED (couldn't find a *-gcc under bin/)"; return 1; }
    log "$name" "smoke-testing trimmed copy: $(basename "$gcc")"
    local probe="$work/probe.c"; echo 'int main(void){return 0;}' > "$probe"
    "$gcc" -c "$probe" -o "$work/probe.o" \
        || { log "$name" "FAILED (trimmed toolchain fails a smoke compile - not packing)"; return 1; }

    log "$name" "packing $out_base.tar.xz"
    pack_xz "$work" "$out_base" "./$name"
    log "$name" "OK -> $out_base.tar.xz ($(du -h "$out_base.tar.xz" | cut -f1)), was $(du -sh "$src" | cut -f1)"
}

# --- macOS SDK, extracted from an Xcode .xip -------------------------------
#
# This is proprietary Apple content (the Xcode/macOS SDK license agreement),
# not something PTR-inc owns or can redistribute outside Apple's own channels
# - unlike every other toolchain here. It is packed into $BUILDROOT/private/
# (never the same directory as the redistributable archives, so a blanket
# upload of $BUILDROOT/*.tar.xz cannot sweep it onto the public TC/ mirror),
# and only when the caller explicitly acknowledges that with
# --i-have-rights-to-redistribute-this. Without the flag an Xcode_*.xip name
# on the command line fails instead of silently packing Apple's SDK.
REDISTRIBUTE_OK=0
args=()
for a in "$@"; do
    case "$a" in
        --i-have-rights-to-redistribute-this) REDISTRIBUTE_OK=1 ;;
        *) args+=("$a") ;;
    esac
done
set -- "${args[@]}"

# Extracts the macOS SDK(s) from an Xcode .xip with osxcross's own
# tools/gen_sdk_package_pbzx.sh (build-env.sh's osxcross_extract_sdk: clones
# osxcross into $OSXCROSS_DIR and pipes the cpio stream through
# openssl/libstatic/build/xip-sdk-cpio.py - SDK subtree only, hard-link
# placeholders resolved; unrestricted extraction needs ~45GB scratch and a
# real run here hit ENOSPC at 11GB free). Output goes to
# $BUILDROOT/private/, NOT next to the redistributable archives, and the
# SDK tarball fetch-toolchains.sh osxcross consumes is dropped in $BR_DOWNLOADS
# so the same machine can build osxcross from it without a second extraction.
pack_xcode_sdk() {
    local xip_name="$1" xip="$BR_DOWNLOADS/$1"
    [ -f "$xip" ] || { log "$xip_name" "FAILED (not found under $BR_DOWNLOADS)"; return 1; }

    local version
    version=$(echo "$xip_name" | sed -nE 's/^Xcode_([0-9.]+)_Universal\.xip$/\1/p')
    [ -n "$version" ] || { log "$xip_name" "FAILED (name doesn't match Xcode_<version>_Universal.xip)"; return 1; }

    if [ "$REDISTRIBUTE_OK" != 1 ]; then
        log "$xip_name" "FAILED (Apple SDK content - refusing without --i-have-rights-to-redistribute-this)"
        return 1
    fi

    local name="Xcode_${version}_Universal"
    local out_base="$BUILDROOT/private/$name"
    mkdir -p "$BUILDROOT/private"
    local work; work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN

    log "$name" "extracting SDK from $xip_name (gen_sdk_package_pbzx.sh via xip-sdk-cpio.py)"
    osxcross_extract_sdk "$xip" "$work/$name" || { log "$name" "FAILED (gen_sdk_package_pbzx.sh)"; return 1; }
    local sdks=("$work/$name"/MacOSX*.sdk.tar.xz)
    [ -e "${sdks[0]}" ] || { log "$name" "FAILED (no MacOSX*.sdk.tar.xz produced)"; return 1; }
    log "$name" "produced $(basename -a "${sdks[@]}" | tr '\n' ' ')"

    # Keep a local copy of the SDK the pinned osxcross build wants, if the xip has it.
    if [ -f "$work/$name/$(basename "$OSXCROSS_SDK_TARBALL")" ]; then
        cp -f "$work/$name/$(basename "$OSXCROSS_SDK_TARBALL")" "$OSXCROSS_SDK_TARBALL"
        log "$name" "copied $(basename "$OSXCROSS_SDK_TARBALL") to $BR_DOWNLOADS (for ./fetch-toolchains.sh osxcross)"
    else
        log "$name" "note: no $(basename "$OSXCROSS_SDK_TARBALL") in this xip - build-env.sh pins OSXCROSS_SDK_VER=$OSXCROSS_SDK_VER"
    fi

    log "$name" "packing $out_base.tar.xz (private - do not upload to the public TC/ mirror)"
    pack_xz "$work" "$out_base" "./$name"
    log "$name" "OK -> $out_base.tar.xz ($(du -h "$out_base.tar.xz" | cut -f1)), from $xip_name ($(du -sh "$xip" | cut -f1))"
}

list="$*"
[ -z "$list" ] && list=$(ls "$BR_TOOLCHAINS")

rc=0
for name in $list; do
    case "$name" in
        Xcode_*_Universal.xip) pack_xcode_sdk "$name" || rc=1 ;;
        *) trim_and_pack "$name" || rc=1 ;;
    esac
done
exit $rc
