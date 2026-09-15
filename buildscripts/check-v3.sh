#!/bin/bash
# Read-only check that targets-v3.conf, the installed dependencies and the repository agree.
# Exit 0 means every row can be built on this host as far as files on disk can tell.
#   buildscripts/check-v3.sh            check every row
#   buildscripts/check-v3.sh 7 36       only these ARCHIDs

. "$(dirname "$(readlink -f "$0")")/env-v3.sh"
. "$V3_DIR/target-v3.sh"
cd "$REPO" || exit 1

rc=0
fail() { echo "  FAIL: $*" >&2; rc=1; }
ok()   { echo "  ok:   $*"; }

echo "== 1. every row resolves and names things that exist in the repository ============"
ids="${*:-$(tgt_ids)}"
seen_names=""
for id in $ids; do
    tgt_load "$id" || { fail "ARCHID $id does not resolve"; continue; }
    [ -n "$T_NAME" ] && [ -n "$T_OS" ] && [ -n "$T_ARCH" ] || fail "ARCHID $id: name, os and arch are required"
    case " $seen_names " in *" $T_NAME "*) fail "ARCHID $id: name $T_NAME is used twice" ;; esac; seen_names="$seen_names $T_NAME"
    case "$T_OS" in linux) [ "$T_LIBC" = glibc ] || [ "$T_LIBC" = musl ] || fail "ARCHID $id: linux needs libc=glibc or musl" ;;
                    freebsd|openbsd) [ -n "$T_OSVER" ] || fail "ARCHID $id: $T_OS needs osver=" ;;
                    macos) [ -n "$T_OSVER" ] || fail "ARCHID $id: macos needs osver= (deployment floor)" ;;
                    *) fail "ARCHID $id: unknown os $T_OS" ;; esac
    [ "$T_LIBC" = glibc ] && [ -z "$T_LIBCVER" ] && fail "ARCHID $id: glibc rows pin their floor with libcver="
    [ -d "$T_OSSLDIR/lib" ] || fail "ARCHID $id: OpenSSL prefix $T_OSSLDIR is not installed (openssl/build/build.sh $T_OSSL)"
    [ -f "$T_OSSLDIR/include/openssl/opensslconf.h" ] || fail "ARCHID $id: $T_OSSLDIR has no generated opensslconf.h"
    [ -z "$T_JPEG" ] || [ -f "$T_JPEG" ] || fail "ARCHID $id: jpeg archive $T_JPEG missing"
done
[ $rc -eq 0 ] && ok "$(echo $ids | wc -w) rows resolve, every OpenSSL prefix and jpeg archive is in the tree"

echo "== 2. every OpenSSL prefix in openssl/$OSSLVER/ is used by a row, or is windows or -debug ======"
used=$(for id in $(tgt_ids); do tgt_load "$id" && echo "$T_OSSL"; done | sort -u)
for d in openssl/$OSSLVER/*/; do
    t=$(basename "$d"); case "$t" in include|windows-*|*-debug) continue ;; esac
    echo "$used" | grep -qx "$t" || fail "openssl/$OSSLVER/$t is linked by no row - stale, or a row is missing"
done
[ $rc -eq 0 ] && ok "no orphaned OpenSSL prefix"

echo "== 3. the tools this host needs ========================================================="
r3=$rc
for id in $ids; do
    tgt_load "$id" || continue
    { command -v "$T_CCBIN" >/dev/null 2>&1 || [ -x "$T_CCBIN" ]; } || fail "ARCHID $id: compiler $T_CCBIN missing$(case "$T_CC" in *zig*) echo " (fetch-deps-v3.sh zig)";; esac)"
    [ "$T_LDBIN" = "$T_CCBIN" ] || command -v "$T_LDBIN" >/dev/null 2>&1 || fail "ARCHID $id: linker driver $T_LDBIN missing"
    case "$T_LD" in *-fuse-ld=lld*) command -v ld64.lld >/dev/null 2>&1 || ls /usr/lib/llvm-*/bin/ld64.lld >/dev/null 2>&1 || fail "ARCHID $id: macOS cross link needs the lld package (ld64.lld)" ;; esac
    command -v "$T_STRIPBIN" >/dev/null 2>&1 || fail "ARCHID $id: $T_STRIPBIN missing (apt/brew: llvm)"
    # libc.so, not just the directory: zig falls back to its own bundled BSD headers and ABI lists and
    # links happily against an empty sysroot, which is exactly the release drift osver= is there to prevent.
    [ -z "$T_SYSROOT" ] || { [ -f "$T_SYSROOT/usr/lib/libc.so" ] && [ -f "$T_SYSROOT/usr/include/stdio.h" ]; } || fail "ARCHID $id: sysroot $T_SYSROOT missing or empty (fetch-deps-v3.sh $T_OS)"
    [ -z "$T_SDK" ] || [ -d "$T_SDK" ] || fail "ARCHID $id: macOS SDK $T_SDK missing ($([ "$V3_HOST" = Darwin ] && echo "xcode-select --install" || echo "bring your own"))"
    [ "$T_OS" = macos ] && [ "$T_MACOSCC" = xcode ] && ! xcrun -f clang >/dev/null 2>&1 && fail "ARCHID $id: MACOS_CC=xcode but Apple clang is not installed (xcode-select --install, or MACOS_CC=zig)"
done
needkvm=0
for id in $ids; do tgt_load "$id" && [ "$T_KVM$T_OS" = 1linux ] && needkvm=1; done
if [ $needkvm = 1 ]; then
    /usr/bin/pkg-config --exists libdrm egl glesv2 wayland-client 2>/dev/null || fail "KVM rows need libdrm-dev libegl-dev libgles-dev libwayland-dev pkg-config"
    [ -d /usr/include/X11 ] || fail "KVM rows need libx11-dev (X11 headers)"
fi
[ $rc -eq $r3 ] && ok "compilers, sysroots and host packages present for the selected rows"

echo "== 4. no pinned value is restated outside its home ====================================="
r4=$rc
# The zig release and the BSD releases have one home each; a literal elsewhere will drift.
hits=$(grep -rnE "zig-$(echo "$ZIG_VERSION" | sed 's/\./\\./g')|\bzig $(echo "$ZIG_VERSION" | sed 's/\./\\./g')\b" makefile.v3 buildscripts/target-v3.sh buildscripts/fetch-deps-v3.sh buildscripts/check-v3.sh 2>/dev/null | grep -v 'ZIG_VERSION' || true)
[ -z "$hits" ] || fail "zig $ZIG_VERSION written out instead of \$ZIG_VERSION:
$hits"
for id in $(tgt_ids); do
    tgt_load "$id" || continue
    case "$T_OS" in freebsd|openbsd)
        hits=$(grep -rnE "$T_OS-$(echo "$T_OSVER" | sed 's/\./\\./g')" makefile.v3 buildscripts/*.sh 2>/dev/null || true)
        [ -z "$hits" ] || fail "$T_OS $T_OSVER is pinned in the table but also written in:
$hits" ;;
    esac
done
# A row that restates a column default (link=dyn, kvm=0, lms=0, opt=O2, server=<archid>, zig=$ZIG_VERSION, or
# link=static on musl, which is static anyway) hides which rows really deviate and goes stale unnoticed.
for id in $(tgt_ids); do
    row=$(grep -E "^archid=$id " "$TGT_CONF"); eval "set -- $row"; libc=""
    for kv in "$@"; do [ "${kv%%=*}" = libc ] && libc=${kv#*=}; done
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        case "$k=$v" in
            link=dyn|kvm=0|lms=0|opt=O2|server=$id|zig=$ZIG_VERSION) fail "ARCHID $id restates the default $kv" ;;
            link=static) [ "$libc" = musl ] && fail "ARCHID $id: musl is static regardless, drop link=static" ;;
        esac
    done
done
[ $rc -eq $r4 ] && ok "no restated pins in makefile.v3 or buildscripts/, no restated defaults in the table"

echo
[ $rc -eq 0 ] && echo "CONSISTENT" || echo "PROBLEMS FOUND - see the FAIL lines above" >&2
exit $rc
