#!/bin/bash
# Read-only drift check. It fails when the build system's sources of truth stop agreeing,
# or when a pinned constant is copied somewhere that should ask for it instead.
# BUILD.md says what each source of truth owns.

. "$(dirname "$(readlink -f "$0")")/../../build-env.sh" >/dev/null || exit 1
. "$BR_SCRIPTS/targets.sh" || exit 1
cd "$REPO" || exit 1

rc=0
fail() { echo "  FAIL: $*" >&2; rc=1; }
ok()   { echo "  ok:   $*"; }

echo "== 1. every target resolves ================================================"
for t in $BR_ALL_TARGETS; do
    br_target "$t" || { fail "$t is in BR_ALL_TARGETS but br_target does not know it"; continue; }
    [ -n "$T_CONF" ] || fail "$t has no T_CONF"
    case "$T_LIBC" in glibc|musl|uclibc|bsd|macos|msvc) ;; *) fail "$t has unknown T_LIBC='$T_LIBC'" ;; esac
    case "$T_CI" in linux|macos|windows) ;; *) fail "$t has unknown T_CI='$T_CI'" ;; esac
    case "$t" in
        linux-*-glibc|linux-*-musl|linux-*-uclibc|freebsd-*|openbsd-*|macos-*|windows-*) ;;
        *) fail "$t does not follow the <os>-<arch>-<libc> naming" ;;
    esac
done
[ $rc -eq 0 ] && ok "$(echo $BR_ALL_TARGETS | wc -w) targets, all with T_CONF/T_LIBC/T_CI and a conforming name"

echo "== 2. every prefix under openssl/<version>/ is a target ====================="
for d in openssl/[0-9]*/*/; do
    t=$(basename "$d"); [ "$t" = include ] && continue
    br_target "$t" || fail "$d is no target of targets.sh - add one, or move it to openssl/legacy/"
done
[ -f openssl/VERSION ] || fail "openssl/VERSION is missing"
[ -d "openssl/$OPENSSL_VERSION" ] || fail "openssl/VERSION pins $OPENSSL_VERSION but openssl/$OPENSSL_VERSION/ does not exist"
[ $rc -eq 0 ] && ok "every prefix directory is a known target, the pinned version is installed"

echo "== 3. every ARCHID links a target targets.sh knows ========================="
if command -v make >/dev/null 2>&1; then
    bad=0
    for id in $(make -s print-archids); do
        t=$(make -s ARCHID="$id" print-ossltarget 2>/dev/null)
        [ -n "$t" ] || { fail "ARCHID $id has no OSSLTARGET"; bad=1; continue; }
        br_target "$t" || { fail "ARCHID $id links OSSLTARGET $t, which targets.sh does not define"; bad=1; }
        # print-ossldir resolves the block's own OSSLVER pin, so a staged migration is checked as such.
        d=$(make -s ARCHID="$id" print-ossldir 2>/dev/null)
        [ -d "$d/lib" ] || { fail "ARCHID $id links $d, which is not installed"; bad=1; }
    done
    [ $bad -eq 0 ] && ok "every non-obsolete ARCHID names an installed target and prefix"
else
    echo "  skip: no make on this host"
fi

echo "== 4. the CI matrices cover every target =================================="
covered=$(print_target_names linux; print_target_names macos; print_target_names windows)
for t in $BR_ALL_TARGETS; do
    echo "$covered" | grep -qx "$t" || fail "$t is in no CI matrix (T_CI is neither linux, macos nor windows)"
done
[ $rc -eq 0 ] && ok "targets.sh --names linux + macos + windows == BR_ALL_TARGETS"

echo "== 5. windows/build.ps1's table names the same targets as targets.sh ======="
# build-openssl-job.yml greps build.ps1's $Targets so the matrix resolves without PowerShell,
# and the names must be targets.sh's, because verify audits the .lib prefixes by that name.
WIN_NAMES=$(grep -oE "Name *= *'[^']+'" "$BR_SCRIPTS/windows/build.ps1" | sed "s/.*'\(.*\)'/\1/" | sort)
[ -n "$WIN_NAMES" ] || fail "could not parse any Name from windows/build.ps1's \$Targets"
if [ "$WIN_NAMES" = "$(print_target_names windows | sort)" ]; then
    ok "$(echo "$WIN_NAMES" | wc -w) windows targets, build.ps1 and targets.sh agree"
else
    fail "windows/build.ps1's \$Targets ($(echo $WIN_NAMES)) differ from targets.sh --names windows ($(print_target_names windows | tr '\n' ' '))"
fi

echo "== 6. no pinned constant is restated in CI, scripts, the makefile or the props ="
# Each constant has exactly one home: openssl/VERSION, build-env.sh, or the makefile's ARCH_ blocks.
# Any other file spelling out the literal will drift, so it should ask for the value instead.
guard() {
    local what="$1" pat="$2" hits
    # An ARCH_ block's own "OSSLVER = x.y.z" is a deliberate per-target pin, so the makefile is
    # searched with those lines removed.
    hits=$(grep -rlE "$pat" --include='*.yml' --include='*.yaml' --include='*.ps1' --include='*.props' --include='*.vcxproj' \
             .github openssl/build MeshAgent.*.props mesh*/ 2>/dev/null | grep -v 'consistency.sh' || true)
    grep -vE '^  OSSLVER *=' makefile | grep -qE "$pat" && hits="$hits
makefile"
    [ -z "$hits" ] && { ok "$what not restated"; return; }
    fail "$what is pinned in one place but also written out in:"
    echo "$hits" | sed 's/^/          /' >&2
}
guard "the OpenSSL version ($OPENSSL_VERSION)"        "$(echo "$OPENSSL_VERSION" | sed 's/\./\\./g')"
guard "the OpenWrt release ($OWRT_RELEASE)"           "$(echo "$OWRT_RELEASE" | sed 's/\./\\./g')"
guard "the OpenWrt gcc version ($OWRT_GCC)"           "$(echo "$OWRT_GCC" | sed 's/\./\\./g')"
guard "the Bootlin release ($BOOTLIN_RELEASE)"        "$(echo "$BOOTLIN_RELEASE" | sed 's/\./\\./g')"
guard "the Bootlin x86 release ($BOOTLIN_X86_RELEASE)" "$(echo "$BOOTLIN_X86_RELEASE" | sed 's/\./\\./g')"
guard "the toolchain mirror URL"                      'media\.githubusercontent\.com/media/PTR-inc'
guard "the FreeBSD release ($FREEBSD_REL, ARCH_30)"   "freebsd-$(echo "$FREEBSD_REL" | sed 's/\./\\./g')"
guard "the OpenBSD release ($OPENBSD_REL, ARCH_37)"   "openbsd-$(echo "$OPENBSD_REL" | sed 's/\./\\./g')"
guard "the osxcross darwin version ($OSXCROSS_DARWIN_VER)" "darwin$(echo "$OSXCROSS_DARWIN_VER" | sed 's/\./\\./g')"
guard "the rcodesign version ($APPLE_CODESIGN_VER)"     "apple-codesign[-/]$(echo "$APPLE_CODESIGN_VER" | sed 's/\./\\./g')"
guard "the macOS SDK version ($OSXCROSS_SDK_VER)"     "MacOSX$(echo "$OSXCROSS_SDK_VER" | sed 's/\./\\./g')"

echo "== 7. the shared headers are the pinned release ============================"
ovh="openssl/$OPENSSL_VERSION/include/openssl/opensslv.h"
if [ ! -f "$ovh" ]; then fail "$ovh is missing"
elif grep -qF "\"OpenSSL $OPENSSL_VERSION " "$ovh"; then ok "opensslv.h says OpenSSL $OPENSSL_VERSION"
else fail "$ovh says $(grep -oE 'OpenSSL [0-9.a-z]+' "$ovh" | head -1), not $OPENSSL_VERSION"; fi
[ -f "openssl/$OPENSSL_VERSION/include/openssl/opensslconf.h" ] && fail "openssl/$OPENSSL_VERSION/include/openssl/opensslconf.h exists, but that header is per target"
for d in openssl/$OPENSSL_VERSION/*/; do
    t=$(basename "$d"); [ "$t" = include ] && continue
    [ -f "$d/include/openssl/opensslconf.h" ] || fail "$d has no include/openssl/opensslconf.h"
done
[ $rc -eq 0 ] && ok "every prefix carries its generated opensslconf.h"

echo "== 8. build.yml is the only push trigger and build-inputs.txt covers every input ="
SEL=.github/scripts/build-changes.sh
if [ -x "$SEL" ]; then
    bad=0
    # Every tree the makefile compiles or includes from must select at least one build platform.
    trees=$( { grep -E '^(SOURCES|[A-Z]+KVMSOURCES) *\+?= ' makefile | sed 's/^[^=]*= *//' | tr ' ' '\n' | grep -oE '^[a-z][a-z0-9_-]*/' ; \
               grep -oE '^INCDIRS *\+?= *.*' makefile | grep -oE '\-I[a-z][a-z0-9_-]*/?' | sed 's/^-I//; s#/*$#/#' ; } | sort -u)
    for d in $trees; do
        platforms=$(printf '%s\n' "${d}x.c" | "$SEL" || true)
        [ -n "$platforms" ] || { fail "the makefile compiles from $d but no platform in .github/build-inputs.txt lists it"; bad=1; }
    done
    # Every OpenSSL target's prefix must select the platform that links it, and only that one.
    for t in $BR_ALL_TARGETS; do
        platforms=$(printf '%s\n' "openssl/$OPENSSL_VERSION/$t/lib/libcrypto.a" | "$SEL" | tr '\n' ' ')
        case "$t" in
            linux-*)   want=linux ;; macos-*) want=macos ;; windows-*) want=windows ;;
            freebsd-*) want=freebsd ;; openbsd-*) want=openbsd ;;
        esac
        case " $platforms" in *" $want "*) ;; *) fail "openssl/<version>/$t/ does not start the $want platform (got '${platforms:-nothing}')"; bad=1 ;; esac
    done
    # Only build.yml may react to a push or pull request, and it must call every platform.
    for w in .github/workflows/*.yml; do
        # Not platforms: the anti-drift gate lists its own inputs, code scanning runs on every master push.
        case "$w" in .github/workflows/build.yml|.github/workflows/build-system-checks.yml|.github/workflows/codeql-analysis.yml) continue ;; esac
        sed -n '/^on:/,/^[a-z]/p' "$w" | grep -qE '^  (push|pull_request):' && { fail "$w has its own push or pull_request trigger, only build.yml may"; bad=1; }
    done
    for f in $("$SEL" --list); do
        grep -qE "^  $f:" .github/workflows/build.yml || { fail "platform $f is in build-inputs.txt but build.yml has no job for it"; bad=1; }
    done
    for u in $(grep -oE 'uses: \./\.github/workflows/[^ ]+' .github/workflows/build.yml | sed 's/uses: \.\///'); do
        [ -f "$u" ] || { fail "build.yml calls $u, which does not exist"; bad=1; }
    done
    [ $bad -eq 0 ] && ok "$(echo $trees | wc -w) source trees and $(echo $BR_ALL_TARGETS | wc -w) targets map to a platform, build.yml is the only push trigger"
else
    fail "$SEL is missing or not executable"
fi

echo
[ $rc -eq 0 ] && echo "CONSISTENT" || echo "DRIFT DETECTED - see the FAIL lines above" >&2
exit $rc
