#!/bin/bash
# Anti-drift gate. Fails when the build system's four sources of truth stop
# agreeing with each other, or when a pinned constant gets copied into a place
# that should be asking for it instead. Read-only; run it anywhere.
#
#   openssl/libstatic/build/consistency.sh
#
# See BUILD.md for what each source of truth owns.

. "$(dirname "$(readlink -f "$0")")/../../../build-env.sh" >/dev/null || exit 1
. "$BR_SCRIPTS/targets.sh" || exit 1
cd "$REPO" || exit 1

rc=0
fail() { echo "  FAIL: $*" >&2; rc=1; }
ok()   { echo "  ok:   $*"; }

ORPHANS=$(sed 's/#.*//' "$BR_SCRIPTS/orphans.txt" 2>/dev/null | tr -s '[:space:]' ' ')
ALL_DEST=""
for t in $BR_ALL_TARGETS; do br_target "$t" && ALL_DEST="$ALL_DEST $T_DEST"; done

echo "== 1. every target resolves and has a destination =========================="
for t in $BR_ALL_TARGETS; do
    br_target "$t" || { fail "$t is in BR_ALL_TARGETS but br_target does not know it"; continue; }
    [ -n "$T_DEST" ] || fail "$t has no T_DEST"
    [ -n "$T_CONF" ] || fail "$t has no T_CONF"
    case "$T_LIBC" in glibc|musl|uclibc|bsd|macos) ;; *) fail "$t has unknown T_LIBC='$T_LIBC'" ;; esac
    case "$T_CI" in linux|macos) ;; *) fail "$t has unknown T_CI='$T_CI'" ;; esac
done
[ $rc -eq 0 ] && ok "$(echo $BR_ALL_TARGETS | wc -w) targets, all with T_DEST/T_CONF/T_LIBC/T_CI"

echo "== 2. every archive dir is claimed by a target (or listed as an orphan) ===="
for d in $(find openssl/libstatic -name libcrypto.a -printf '%h\n' | sed 's|openssl/libstatic/||' | sort); do
    case " $ALL_DEST $ORPHANS " in
        *" $d "*) ;;
        *) fail "openssl/libstatic/$d is built by no target - add one to targets.sh, or list the dir in build/orphans.txt" ;;
    esac
done
[ $rc -eq 0 ] && ok "no unclaimed archive dirs"

echo "== 3. every ARCHID links a dir some target actually builds ================="
if command -v make >/dev/null 2>&1; then
    for id in $(make -s print-archids); do
        d=$(make -s ARCHID="$id" print-ossldir 2>/dev/null)
        [ -n "$d" ] || { fail "ARCHID $id has no print-ossldir"; continue; }
        case " $ALL_DEST " in
            *" $d "*) ;;
            *) fail "ARCHID $id links openssl/libstatic/$d, which no targets.sh target builds" ;;
        esac
    done
    ok "every non-obsolete ARCHID maps to a built archive dir"
else
    echo "  skip: no make on this host"
fi

echo "== 4. the CI matrices cover every target =================================="
covered=$(print_target_names linux; print_target_names macos)
for t in $BR_ALL_TARGETS; do
    echo "$covered" | grep -qx "$t" || fail "$t is in no CI matrix (T_CI is neither linux nor macos)"
done
[ $rc -eq 0 ] && ok "targets.sh --names linux + macos == BR_ALL_TARGETS"

echo "== 5. the Windows target names parse the same with and without pwsh ======="
# build-openssl-job.yml greps build.ps1's $Targets directly so the matrix can be
# resolved on a runner (or under `act`) with no PowerShell. Assert that parse
# still agrees with build.ps1's own --names-json wherever pwsh is available.
WIN_NAMES=$(grep -oE "Name *= *'[^']+'" "$BR_SCRIPTS/windows/build.ps1" | sed "s/.*'\(.*\)'/\1/")
[ -n "$WIN_NAMES" ] || fail "could not parse any Name from windows/build.ps1's \$Targets"
if command -v pwsh >/dev/null 2>&1; then
    auth=$(pwsh -File "$BR_SCRIPTS/windows/build.ps1" --names-json 2>/dev/null | tr -d '[]"' | tr ',' '\n' | grep -v '^$')
    [ "$(echo "$auth" | sort)" = "$(echo "$WIN_NAMES" | sort)" ] \
        && ok "$(echo "$WIN_NAMES" | wc -w) windows targets, both parses agree" \
        || fail "the grep parse of build.ps1's \$Targets disagrees with build.ps1 --names-json"
else
    echo "  skip: no pwsh - grep parse found: $(echo $WIN_NAMES)"
fi

echo "== 6. no pinned constant is restated in CI or scripts ====================="
# Each of these has exactly one home (build-env.sh, or the makefile's ARCH_
# blocks). Anything else that spells the literal out is drift waiting to happen:
# ask for the value instead (`. build-env.sh`, `make print-bsdrel`, targets.sh).
guard() {
    local what="$1" pat="$2" hits
    hits=$(grep -rlE "$pat" --include='*.yml' --include='*.yaml' --include='*.ps1' \
             .github openssl/libstatic/build 2>/dev/null | grep -v 'consistency.sh' || true)
    [ -z "$hits" ] && { ok "$what not restated"; return; }
    fail "$what is pinned in build-env.sh but also written out in:"
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

echo
[ $rc -eq 0 ] && echo "CONSISTENT" || echo "DRIFT DETECTED - see the FAIL lines above" >&2
exit $rc
