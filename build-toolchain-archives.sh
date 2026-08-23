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

list="$*"
[ -z "$list" ] && list=$(ls "$BR_TOOLCHAINS")

rc=0
for name in $list; do
    trim_and_pack "$name" || rc=1
done
exit $rc
