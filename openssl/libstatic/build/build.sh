#!/bin/bash
# Builds one or more OpenSSL targets and stages the archives into the repo. Usage is
# build.sh <target|all|list>, with BUILDROOT, MAKE_JOBS and BR_FETCH=1 as optional knobs.
# Nothing is staged unless it passes the gates that targets.sh defines. See openssl/libstatic/build/README.md.
. "$(dirname "$(readlink -f "$0")")/../../../build-env.sh"
. "$BR_SCRIPTS/targets.sh"

[ $# -ge 1 ] || { echo "usage: $(basename $0) <target|all|list> [target...]"; echo "targets: $BR_ALL_TARGETS"; exit 2; }

# Asks the makefile which ARCHIDs link each openssl/libstatic directory, so its
# target table is never duplicated here. Prints nothing when make or the makefile is absent.
archid_map() {
    [ -f "$REPO/makefile" ] && command -v make >/dev/null 2>&1 || return 0
    make -s -C "$REPO" list 2>/dev/null | awk 'NR>1{print $1}' | while read -r id; do
        d=$(make -s -C "$REPO" ARCHID="$id" print-ossldir 2>/dev/null)
        [ -n "$d" ] && echo "$d $id"
    done
}

# Prints one line per target so a reader can see what this host can build and who consumes it.
print_target_list() {
    local map ready=0 total=0
    map="$(archid_map)"
    printf "%-20s %-7s %-9s %-10s %s\n" TARGET LIBC TOOLCHAIN ARCHIDS "STAGES INTO"
    for t in $BR_ALL_TARGETS; do
        br_target "$t" || continue
        total=$((total+1))
        local cc="${T_CC%% *}" st ids="" d
        # An empty T_CC (poky64) means the host's native gcc, so it must count as ready.
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

# Targets build one after another. Each OpenSSL make gets every core unless MAKE_JOBS says otherwise.
ncpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
MAKE_JOBS="${MAKE_JOBS:-$ncpu}"
[ "$MAKE_JOBS" -ge 1 ] 2>/dev/null || MAKE_JOBS=1

# Runs one target end to end. Output streams to the terminal and is kept in a per-target log
# under $BR_WORK. The one-line verdict goes to a status file that the summary loop reads.
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
    # The gates come from T_LIBC so there is never a second hand-kept target list.
    # A glibc-only symbol is fatal for both musl and uClibc agents.
    case "$T_LIBC" in
      musl|uclibc)
        if [ "$g" -ne 0 ]; then
            echo "$t: REJECTED - $g glibc-only refs in a $T_LIBC target" > "$status_file"
            "$t_nm" --undefined-only "$src/libcrypto.a" | awk '{print $NF}' | grep -oE "$GLIBC_ONLY_RE" | sort -u | sed 's/^/      /'
            return 1
        fi ;;
    esac
    # ucontext is fatal only for musl, because musl implements it on no architecture
    # while uClibc's libc.so does.
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
    } 2>&1 | tee "$log_file"
}

# Provisions the toolchain from the target's T_FETCH tokens, which are either a
# fetch-toolchains.sh component or an apt package. It only runs with BR_FETCH=1, which CI
# sets, so a local run is never surprised by a package install.
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

for t in $list; do build_one "$t"; done

echo
echo "Summary:"
rc=0
for t in $list; do
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
