#!/bin/bash
# Repacks the cross toolchains under $BUILDROOT/toolchains into smaller archives for
# the TC/ folder of PTR-inc/meshagent-toolchains. Only share/ extras and unneeded ELF
# symbols can go, since the toolchain is the compiler, so expect a 10-20% reduction. See ISSUES.md.
#
# Every archive is smoke-tested with its own gcc before it is kept, because a
# stripped cc1 that no longer runs is worse than shipping no archive at all.
#
#   ./build-toolchain-archives.sh                                   # every toolchain in $BR_TOOLCHAINS
#   ./build-toolchain-archives.sh riscv64-lp64d--musl--stable-2025.08-1
#   ./build-toolchain-archives.sh riscv64-lp64d--musl--stable-2025.08-1 mips32el--uclibc--stable-2025.08-1
#
#   # An Xcode_<version>_Universal.xip under $BR_DOWNLOADS yields Apple's proprietary SDK,
#   # which must not go to the public mirror. The flag is a required acknowledgement of that,
#   # and the archive lands in $BUILDROOT/private/ for OSXCROSS_SDK_URL on a private host.
#   ./build-toolchain-archives.sh --i-have-rights-to-redistribute-this Xcode_26.6_Universal.xip

set -euo pipefail

export BUILDROOT="${BUILDROOT:-/opt/buildroot}"
. "$(dirname "$(readlink -f "$0")")/build-env.sh"

log() { echo "[$1] $2"; }

# xz is the only format shipped because, measured against zstd -19 on the largest
# archives here, zstd compressed ~25-30% faster but produced files 30-90% bigger,
# and both decompress in under 2s.
pack_xz() {
    local workdir="$1" out_base="$2"; shift 2
    (cd "$workdir" && tar cf - "$@" | xz -T0 -9 -c) > "$out_base.tar.xz"
}

# A repacked OpenWrt SDK keeps its compiler under staging_dir/toolchain-*/bin
# rather than bin/, so both locations are searched.
find_gcc() {
    find "$1/bin" "$1"/staging_dir/toolchain-*/bin -maxdepth 1 -name '*-gcc' -not -name '*.br_real' 2>/dev/null | head -1
}

trim_and_pack() {
    local name="$1" src="$BR_TOOLCHAINS/$1" out_base="$BUILDROOT/$1"
    [ -d "$src" ] || { log "$name" "FAILED (not found under $BR_TOOLCHAINS)"; return 1; }

    local work; work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN

    # An OpenWrt SDK is a whole source tree, and only staging_dir/toolchain-* is the compiler.
    # Its gcc wrapper execs staging_dir/host's own ld-linux and libc via a relative
    # ../../host/lib path, so host must ship too or gcc itself fails to start.
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
# The SDK is proprietary Apple content that PTR-inc cannot redistribute, so it is packed
# into $BUILDROOT/private/ where a blanket upload of $BUILDROOT/*.tar.xz cannot sweep it
# onto the public TC/ mirror, and only with --i-have-rights-to-redistribute-this given.
REDISTRIBUTE_OK=0
args=()
for a in "$@"; do
    case "$a" in
        --i-have-rights-to-redistribute-this) REDISTRIBUTE_OK=1 ;;
        *) args+=("$a") ;;
    esac
done
set -- "${args[@]}"

# Uses build-env.sh's osxcross_extract_sdk, which pipes tools/gen_sdk_package_pbzx.sh through
# openssl/build/xip-sdk-cpio.py because unrestricted extraction needs ~45GB scratch.
# The SDK tarball is also dropped in $BR_DOWNLOADS so fetch-toolchains.sh osxcross needs no second extraction.
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

    # The pinned osxcross build wants this one SDK, so keep a local copy when the xip has it.
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
