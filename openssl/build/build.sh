#!/bin/bash
# Builds one or more OpenSSL targets and installs each into its prefix openssl/<version>/<target>/.
# Usage is build.sh <target|all|list>, with BUILDROOT, MAKE_JOBS and BR_FETCH=1 as optional knobs.
# Nothing is installed unless it passes the gates in probe.sh. See openssl/build/README.md.
. "$(dirname "$(readlink -f "$0")")/../../build-env.sh"
. "$BR_SCRIPTS/targets.sh"
. "$BR_SCRIPTS/probe.sh"

[ $# -ge 1 ] || { echo "usage: $(basename $0) <target|all|list> [target...]"; echo "targets: $BR_ALL_TARGETS"; exit 2; }

# Asks the makefile which ARCHIDs link each target, so its table is never duplicated here.
# Prints nothing when make or the makefile is absent.
archid_map() {
    [ -f "$REPO/makefile" ] && command -v make >/dev/null 2>&1 || return 0
    make -s -C "$REPO" print-archids 2>/dev/null | tr ' ' '\n' | while read -r id; do
        [ -n "$id" ] || continue
        t=$(make -s -C "$REPO" ARCHID="$id" print-ossltarget 2>/dev/null)
        v=$(make -s -C "$REPO" ARCHID="$id" print-osslver 2>/dev/null)
        # An ARCHID pinned to another series is shown as id@version, so the reader sees it.
        [ -n "$t" ] && echo "$t $id$([ "$v" = "$OPENSSL_VERSION" ] || echo "@$v")"
    done
}

# Prints one line per target so a reader can see what this host can build and who consumes it.
print_target_list() {
    local map ready=0 total=0
    map="$(archid_map)"
    printf "%-22s %-7s %-9s %-10s %s\n" TARGET LIBC TOOLCHAIN ARCHIDS "PREFIX"
    for t in $BR_ALL_TARGETS; do
        br_target "$t" || continue
        total=$((total+1))
        local cc="${T_CC%% *}" st ids
        if [ "$T_CI" = windows ]; then st=windows
        elif command -v "$cc" >/dev/null 2>&1 || [ -x "$cc" ]; then st=ready; ready=$((ready+1)); else st=MISSING; fi
        ids=$(echo "$map" | awk -v d="$t" '$1==d{printf "%s%s", (n++?",":""), $2}')
        printf "%-22s %-7s %-9s %-10s %s\n" "$t" "$T_LIBC" "$st" "${ids:--}" "openssl/$OPENSSL_VERSION/$t$([ -d "$T_PREFIX/lib" ] || echo ' (absent)')"
    done
    echo
    echo "  $ready buildable here. MISSING = no compiler, see ./fetch-toolchains.sh. windows = built by windows/build.ps1"
    echo "  ARCHIDS = agent targets linking that prefix ('-' = none, id@version = pinned to another series)"
}

if [ "$1" = list ]; then print_target_list; exit 0; fi

list="$*"; [ "$1" = all ] && list=$(print_target_names linux; print_target_names macos)

mkdir -p "$BR_WORK"
: > "$BR_WORK/build.status"

# Targets build one after another. Each OpenSSL make gets every core unless MAKE_JOBS says otherwise.
ncpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
MAKE_JOBS="${MAKE_JOBS:-$ncpu}"
[ "$MAKE_JOBS" -ge 1 ] 2>/dev/null || MAKE_JOBS=1

# Runs one target end to end. Output streams to the terminal and is kept in a per-target log
# under $BR_WORK. The one-line verdict goes to a status file that the summary loop reads.
build_one() {
    local t="$1" src stage status_file log_file
    status_file="$BR_WORK/$t.status"
    log_file="$BR_WORK/$t.log"

    if ! br_target "$t"; then
        echo "$t: UNKNOWN TARGET" > "$status_file"
        : > "$log_file"
        return 1
    fi
    if [ "$T_CI" = windows ]; then
        echo "$t: WINDOWS TARGET - build it with openssl/build/windows/build.ps1" > "$status_file"
        : > "$log_file"
        return 1
    fi

    {
    echo "=================== $t ($T_CONF/$T_LIBC) ==================="

    if [ "$BR_FETCH" = 1 ] && [ -n "$T_FETCH" ]; then
        br_provision || { echo "$t: PROVISIONING FAILED (T_FETCH=$T_FETCH)" > "$status_file"; return 1; }
    fi

    src="$BR_WORK/$t"; stage="$BR_WORK/$t.stage"
    rm -rf "$src" "$stage" && mkdir -p "$src"
    tar xzf "$OPENSSL_TARBALL" -C "$src" --strip-components=1

    # --prefix=/ makes install_dev lay the prefix out directly under DESTDIR. The openssldir stays
    # at its default so the compiled-in certificate paths do not change with the layout.
    if ! ( cd "$src" && CC="$T_CC" AR="${T_AR:-ar}" RANLIB="${T_RANLIB:-ranlib}" ./Configure $T_CONF --prefix=/ --libdir=lib --openssldir=/usr/local/ssl $T_FLAGS $T_EXTRA >configure.log 2>&1 ); then
        echo "$t: CONFIGURE FAILED ($src/configure.log)" > "$status_file"; return 1
    fi
    if ! ( cd "$src" && AR="${T_AR:-ar}" RANLIB="${T_RANLIB:-ranlib}" make -j"$MAKE_JOBS" $T_MAKE >make.log 2>&1 ); then
        echo "$t: MAKE FAILED ($src/make.log)" > "$status_file"
        grep -iE 'error' "$src/make.log" | head -5 | sed 's/^/    /'; return 1
    fi
    # install_dev is OpenSSL's own developer install: headers, the two archives and the .pc files.
    if ! ( cd "$src" && make DESTDIR="$stage" install_dev >install.log 2>&1 ); then
        echo "$t: INSTALL FAILED ($src/install.log)" > "$status_file"; return 1
    fi
    # The .pc files must not carry this machine's path, so prefix is made relative to the file.
    sed -i.bak 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$stage"/lib/pkgconfig/*.pc && rm -f "$stage"/lib/pkgconfig/*.bak

    # Only the generated header stays per target. The shared headers live once per version.
    local shared="$OPENSSL_PREFIX_ROOT/include/openssl"
    if [ ! -d "$shared" ]; then
        mkdir -p "$shared"
        cp "$stage"/include/openssl/*.h "$shared"/ && rm -f "$shared/opensslconf.h"
        echo "  shared headers -> openssl/$OPENSSL_VERSION/include/openssl"
    fi
    rm -rf "$stage/prefix" && mkdir -p "$stage/prefix/include/openssl" "$stage/prefix/lib"
    cp "$stage/include/openssl/opensslconf.h" "$stage/prefix/include/openssl/"
    cp "$stage"/lib/libcrypto.a "$stage"/lib/libssl.a "$stage/prefix/lib/"
    cp -r "$stage/lib/pkgconfig" "$stage/prefix/lib/"

    # The same gate verify runs on the committed tree, against the staged prefix under its version name.
    mkdir -p "$stage/$OPENSSL_VERSION" && mv "$stage/prefix" "$stage/$OPENSSL_VERSION/$t"
    probe_archive "$stage/$OPENSSL_VERSION/$t/lib/libcrypto.a"
    echo "  version : $P_VERSION"
    echo "  platform: $P_PLATFORM   objects: $P_MEMBERS ($P_FORMAT/$P_CLASS $P_MACHINE)"
    echo "  compiler: $P_COMPILER"
    echo "  glibc-only refs: $P_GLIBC   ucontext refs: $P_UCONTEXT   (libc: $T_LIBC)"
    if ! gate_target "$t" "$stage/$OPENSSL_VERSION/$t"; then
        echo "$t: REJECTED - see the REJECT lines above" > "$status_file"; return 1
    fi

    rm -rf "$T_PREFIX" && mkdir -p "$(dirname "$T_PREFIX")"
    cp -r "$stage/$OPENSSL_VERSION/$t" "$T_PREFIX"
    echo "  installed -> openssl/$OPENSSL_VERSION/$t"
    echo "$t: OK $P_VERSION objs=$P_MEMBERS libc=$T_LIBC glibc=$P_GLIBC ucontext=$P_UCONTEXT" > "$status_file"
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
exit $rc
