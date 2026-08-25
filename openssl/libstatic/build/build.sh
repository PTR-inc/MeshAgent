#!/bin/bash
# Build one or more OpenSSL targets and stage the archives into the repo.
#
#   openssl/libstatic/build/build.sh riscv64
#   openssl/libstatic/build/build.sh all
#   openssl/libstatic/build/build.sh list      # targets, toolchains, ARCHIDs
#   BUILDROOT=/some/other/buildroot openssl/libstatic/build/build.sh mips
#   BR_JOBS=4 openssl/libstatic/build/build.sh all      # 4 targets built concurrently
#   BR_FETCH=1 openssl/libstatic/build/build.sh mips    # provision the toolchain first (T_FETCH)
#
# Nothing here is staged unless it passes: right version, right object count
# (per-target, see targets.sh), and - for non-glibc targets (T_LIBC) - no
# glibc-only and no ucontext symbol references. All three gates read targets.sh;
# there is no second list of "which targets are musl" anywhere.
. "$(dirname "$(readlink -f "$0")")/../../../build-env.sh"
. "$BR_SCRIPTS/targets.sh"

[ $# -ge 1 ] || { echo "usage: $(basename $0) <target|all|list> [target...]"; echo "targets: $BR_ALL_TARGETS"; exit 2; }

# Maps "openssl/libstatic/<dir>" -> the ARCHIDs whose agent links it, asking
# the makefile rather than second-guessing its target table. Empty if there's
# no makefile (or no make) to ask.
archid_map() {
    [ -f "$REPO/makefile" ] && command -v make >/dev/null 2>&1 || return 0
    make -s -C "$REPO" list 2>/dev/null | awk 'NR>1{print $1}' | while read -r id; do
        d=$(make -s -C "$REPO" ARCHID="$id" print-ossldir 2>/dev/null)
        [ -n "$d" ] && echo "$d $id"
    done
}

# One line per target: can this host build it, who consumes it, where it lands.
print_target_list() {
    local map ready=0 total=0
    map="$(archid_map)"
    printf "%-20s %-7s %-9s %-10s %s\n" TARGET LIBC TOOLCHAIN ARCHIDS "STAGES INTO"
    for t in $BR_ALL_TARGETS; do
        br_target "$t" || continue
        total=$((total+1))
        local cc="${T_CC%% *}" st ids="" d
        # Empty T_CC (poky64) means "host's native gcc" - always ready, not MISSING.
        if [ -z "$T_CC" ] || command -v "$cc" >/dev/null 2>&1 || [ -x "$cc" ]; then st=ready; ready=$((ready+1)); else st=MISSING; fi
        for d in $T_DEST; do
            ids="$ids$(echo "$map" | awk -v d="$d" '$1==d{printf "%s%s", (n++?",":""), $2}')"
        done
        printf "%-20s %-7s %-9s %-10s %s\n" "$t" "$T_LIBC" "$st" "${ids:--}" "$T_DEST"
    done
    echo
    echo "  $ready/$total buildable here. MISSING = no compiler; see ./fetch-toolchains.sh"
    echo "  ARCHIDS = agent targets linking that archive ('-' = none, archive is unused)"
}

if [ "$1" = list ]; then print_target_list; exit 0; fi

list="$*"; [ "$1" = all ] && list="$BR_ALL_TARGETS"

mkdir -p "$BR_WORK"
: > "$BR_WORK/build.status"

# BR_JOBS targets build concurrently (default 1 = old one-at-a-time behavior).
# Cores are split across slots (MAKE_JOBS = nproc / BR_JOBS) instead of every
# slot claiming `make -j$(nproc)` and oversubscribing the machine.
BR_JOBS="${BR_JOBS:-1}"
[ "$BR_JOBS" -ge 1 ] 2>/dev/null || BR_JOBS=1
ncpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
MAKE_JOBS="${MAKE_JOBS:-$((ncpu / BR_JOBS))}"
[ "$MAKE_JOBS" -ge 1 ] 2>/dev/null || MAKE_JOBS=1

# Runs one target end to end, output buffered into a per-target log/status
# file under $BR_WORK so concurrent runs (BR_JOBS>1) don't interleave. Main
# loop below replays each in listed order, not completion order.
build_one() {
    local t="$1" src status_file log_file
    status_file="$BR_WORK/$t.status"
    log_file="$BR_WORK/$t.log"

    if ! br_target "$t"; then
        echo "$t: UNKNOWN TARGET" > "$status_file"
        : > "$log_file"
        return 1
    fi

    {
    echo "=================== $t ($T_CONF/$T_LIBC) ==================="

    if [ "$BR_FETCH" = 1 ] && [ -n "$T_FETCH" ]; then
        br_provision || { echo "$t: PROVISIONING FAILED (T_FETCH=$T_FETCH)" > "$status_file"; return 1; }
    fi

    src="$BR_WORK/$t"
    rm -rf "$src" && mkdir -p "$src"
    tar xzf "$OPENSSL_TARBALL" -C "$src" --strip-components=1

    if ! ( cd "$src" && CC="$T_CC" AR="${T_AR:-ar}" RANLIB="${T_RANLIB:-ranlib}" ./Configure $T_CONF $T_FLAGS $T_EXTRA >configure.log 2>&1 ); then
        echo "$t: CONFIGURE FAILED ($src/configure.log)" > "$status_file"; return 1
    fi
    if ! ( cd "$src" && AR="${T_AR:-ar}" RANLIB="${T_RANLIB:-ranlib}" make -j"$MAKE_JOBS" $T_MAKE >make.log 2>&1 ); then
        echo "$t: MAKE FAILED ($src/make.log)" > "$status_file"
        grep -iE 'error' "$src/make.log" | head -5 | sed 's/^/    /'; return 1
    fi

    t_ar="${T_AR:-ar}"; t_nm="${T_NM:-nm}"
    v=$(strings "$src/libcrypto.a" | grep -oE 'OpenSSL 1\.1\.1[a-z]' | sort -u)
    n=$("$t_ar" t "$src/libcrypto.a" | wc -l)
    g=$("$t_nm" --undefined-only "$src/libcrypto.a" 2>/dev/null | awk '{print $NF}' | grep -cE "$GLIBC_ONLY_RE")
    u=$("$t_nm" --undefined-only "$src/libcrypto.a" 2>/dev/null | awk '{print $NF}' | grep -cE "$UCONTEXT_RE")
    obj=$("$t_ar" t "$src/libcrypto.a" | grep -m1 '\.o$')
    rm -rf "$src/.probe" && mkdir -p "$src/.probe" && ( cd "$src/.probe" && "$t_ar" x "$src/libcrypto.a" "$obj" )
    arch=$(file -b "$src/.probe/$obj" | cut -d, -f1-4)

    echo "  version : $v"
    echo "  objects : $n (expect $T_OBJS)"
    echo "  glibc-only refs: $g   ucontext refs: $u   (libc: $T_LIBC)"
    echo "  arch    : $arch"

    if [ "$v" != "OpenSSL $OPENSSL_VERSION" ] || [ "$n" -ne "$T_OBJS" ]; then
        echo "$t: REJECTED (version=$v objects=$n)" > "$status_file"; return 1
    fi
    # Gates derived from T_LIBC, never from a second hand-kept target list.
    # glibc-only symbols: fatal for musl AND uClibc agents.
    case "$T_LIBC" in
      musl|uclibc)
        if [ "$g" -ne 0 ]; then
            echo "$t: REJECTED - $g glibc-only refs in a $T_LIBC target" > "$status_file"
            "$t_nm" --undefined-only "$src/libcrypto.a" | awk '{print $NF}' | grep -oE "$GLIBC_ONLY_RE" | sort -u | sed 's/^/      /'
            return 1
        fi ;;
    esac
    # ucontext: musl implements it on no arch; uClibc's libc.so does, so it is
    # fatal only for musl.
    if [ "$T_LIBC" = musl ] && [ "$u" -ne 0 ]; then
        echo "$t: REJECTED - $u ucontext refs; musl implements none, the agent link will fail" > "$status_file"
        "$t_nm" --undefined-only "$src/libcrypto.a" | awk '{print $NF}' | grep -E "$UCONTEXT_RE" | sort -u | sed 's/^/      /'
        return 1
    fi

    for d in $T_DEST; do
        install -d "$REPO/openssl/libstatic/$d"
        cp -f "$src/libcrypto.a" "$src/libssl.a" "$REPO/openssl/libstatic/$d/"
        echo "  staged -> openssl/libstatic/$d"
    done
    echo "$t: OK $v objs=$n libc=$T_LIBC glibc=$g ucontext=$u" > "$status_file"
    } > "$log_file" 2>&1
}

# Provisions this target's toolchain from its T_FETCH tokens (a
# fetch-toolchains.sh component, or apt:<pkg>). Only runs with BR_FETCH=1 -
# CI sets it; locally the makefile's own prompt or `list` output tells you what
# to run. One provisioning table (targets.sh), used by both.
BR_FETCH="${BR_FETCH:-0}"
br_provision() {
    local tok apt_pkgs="" comps=""
    for tok in $T_FETCH; do
        case "$tok" in
            apt:*) apt_pkgs="$apt_pkgs ${tok#apt:}" ;;
            *)     comps="$comps $tok" ;;
        esac
    done
    if [ -n "$apt_pkgs" ]; then
        echo "  apt-get install:$apt_pkgs"
        ${SUDO:-sudo} apt-get update -qq && ${SUDO:-sudo} apt-get install -y $apt_pkgs || return 1
    fi
    if [ -n "$comps" ]; then
        echo "  fetch-toolchains.sh$comps"
        ( cd "$REPO" && ./fetch-toolchains.sh -y $comps ) || return 1
    fi
}

# Slot-throttled fan-out: never more than BR_JOBS running at once. `wait -n`
# needs bash 4.3+, which macOS's /bin/bash (3.2) is not - so the default
# BR_JOBS=1 path stays plain sequential and works everywhere.
if [ "$BR_JOBS" -eq 1 ]; then
    for t in $list; do build_one "$t"; done
else
    for t in $list; do
        build_one "$t" &
        while [ "$(jobs -rp | wc -l)" -ge "$BR_JOBS" ]; do wait -n; done
    done
    wait
fi

rc=0
for t in $list; do
    cat "$BR_WORK/$t.log"
    status_line=$(cat "$BR_WORK/$t.status" 2>/dev/null)
    echo "$status_line" | tee -a "$BR_WORK/build.status"
    case "$status_line" in
        "$t: OK "*) ;;
        *) rc=1 ;;
    esac
done

echo
echo "================= SUMMARY ================="
cat "$BR_WORK/build.status"
exit $rc
