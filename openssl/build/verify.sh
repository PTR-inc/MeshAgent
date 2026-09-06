#!/bin/bash
# Read-only audit of every committed OpenSSL prefix under openssl/<version>/. Usage is
# verify.sh [target ...], defaulting to every target of every installed version. Every gate
# comes from probe.sh, the same code build.sh runs before it stages anything.

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/../../build-env.sh" >/dev/null || exit 1
. "$BR_SCRIPTS/targets.sh" || exit 1
. "$BR_SCRIPTS/probe.sh" || exit 1
cd "$REPO" || exit 1

rc=0
unstamped=0
stale=0

# Reports one prefix's build-stamp.txt against what targets.sh would produce today. The comparison
# itself lives in targets.sh, which build.sh's skip check uses too, so the audit and the rebuild
# decision can never disagree. A prefix built before stamps existed is counted, not rejected. Only a
# real disagreement is a REJECT, because that means the committed archive is not what the current
# configuration builds.
check_stamp() {   # $1 target, $2 prefix, $3 version directory. br_target "$1" must have run.
    local t="$1" diffs
    # A prefix from another version series is described by a different tarball and a different
    # $OPENSSL_VERSION than this environment pins, so recomputing here would compare two series.
    if [ "$3" != "$OPENSSL_VERSION" ]; then
        echo "  note: $t stamp not checked, openssl/$3 is not the pinned series ($OPENSSL_VERSION)"
        return 0
    fi
    if ! diffs=$(stamp_diff "$t" "$2"); then
        echo "  note: $t has no build-stamp.txt (built before build.sh wrote one)"
        unstamped=$((unstamped+1)); return 0
    fi
    [ -n "$diffs" ] || return 0
    echo "  REJECT: $t: build-stamp.txt disagrees with targets.sh - the committed archive is not what this configuration builds:$diffs" >&2
    stale=$((stale+1)); rc=1
}

versions=$(ls -d openssl/[0-9]*/ 2>/dev/null | xargs -n1 basename)
[ -n "$versions" ] || { echo "no openssl/<version>/ prefixes found" >&2; exit 1; }

printf '%-8s %-22s %-7s %-9s %-16s %-8s %-6s %s\n' VERSION TARGET LIBC ARCHIVE PLATFORM MACHINE GLIBC COMPILER
printf '%-8s %-22s %-7s %-9s %-16s %-8s %-6s %s\n' ------- ------ ---- ------- -------- ------- ----- --------
for v in $versions; do
    # The shared headers must be the release the directory claims.
    ovh="openssl/$v/include/openssl/opensslv.h"
    if [ ! -f "$ovh" ]; then
        echo "  REJECT: openssl/$v has no include/openssl/opensslv.h" >&2; rc=1
    elif ! grep -qF "\"OpenSSL $v " "$ovh"; then
        echo "  REJECT: openssl/$v/include/openssl/opensslv.h says $(grep -oE 'OpenSSL [0-9.a-z]+' "$ovh" | head -1), not $v" >&2; rc=1
    fi
    for d in openssl/$v/*/; do
        t=$(basename "$d"); [ "$t" = include ] && continue
        if [ $# -gt 0 ]; then case " $* " in *" $t "*) ;; *) continue ;; esac; fi
        if ! br_target "$t"; then
            echo "  REJECT: openssl/$v/$t is no target of targets.sh - add it, or move the directory to openssl/legacy/" >&2; rc=1; continue
        fi
        prefix="$REPO/openssl/$v/$t"
        gate_target "$t" "$prefix" || rc=1
        check_stamp "$t" "$prefix" "$v"
        printf '%-8s %-22s %-7s %-9s %-16s %-8s %-6s %s\n' "$v" "$t" "$T_LIBC" "$P_FORMAT${P_CLASS:+/$P_CLASS} $P_MEMBERS" "$P_PLATFORM" "$P_MACHINE" "$P_GLIBC" "$(echo "${P_COMPILER%% *}" | sed 's|.*/||') $(echo " $P_COMPILER" | grep -oE ' -O[s0-3]| /O[d12]' | tail -1)"
    done
    # A target that exists in targets.sh but has no prefix for this version is reported, not rejected,
    # because a new version is filled in one target at a time.
    for t in $BR_ALL_TARGETS; do [ -d "openssl/$v/$t" ] || echo "  missing: openssl/$v/$t (not built yet)"; done
done

echo
echo "ARCHIVE = container format, wordsize and member count. GLIBC = references to $GLIBC_ONLY_RE,"
echo "which must be 0 for musl and uClibc. Every REJECT line above is a gate from openssl/build/probe.sh."
echo "STAMPS: $stale disagree with targets.sh, $unstamped predate build-stamp.txt and were not compared."
[ $rc -eq 0 ] && echo "VERIFIED" || echo "REJECTED - see the REJECT lines above" >&2
exit $rc
