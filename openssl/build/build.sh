#!/bin/bash
# Builds one or more OpenSSL targets and installs each into its prefix openssl/<version>/<target>/.
# Usage is build.sh <target|all|list>, with BUILDROOT, MAKE_JOBS and BR_FETCH=1 as optional knobs.
# Nothing is installed unless it passes the gates in probe.sh. See openssl/build/README.md.
. "$(dirname "$(readlink -f "$0")")/../../build-env.sh"
. "$BR_SCRIPTS/targets.sh"
. "$BR_SCRIPTS/probe.sh"

print_manual() {
    cat <<EOF
usage: $(basename "$0") <target|all|list|list-archids> [target...]

  <target> [target...]  Build one or more named targets, each installed into
                         openssl/\$OPENSSL_VERSION/<target>/. Nothing is installed
                         unless the archive passes the gates in probe.sh.
  all                    Build every linux and macos target (BR_ALL_TARGETS,
                         filtered to those two T_CI groups). Windows targets are
                         never built here - see openssl/build/windows/build.ps1.
  list                   Print the target matrix (libc, toolchain readiness, the
                         ARCHIDs that link each prefix, asm on/off, whether the
                         target compiles via zig, per-target EXTRA flags,
                         install status) and exit. No build runs.
  list-archids           The same information from the other direction: one row
                         per makefile ARCHID with its ARCHNAME, the target it
                         links, libc, asm and prefix status. No build runs.
  -h, --help             Show this manual and exit.

Zig-built archives (ZIG column above) run 3-4x larger than a gcc-built target - zig cc embeds
DWARF debug info by default even with no -g flag, see targets.sh's top-of-file comment. Left in
on purpose: the agent's own STRIP_AND_SYMBOLCP (makefile) already strips it from the shipped
binary, and the pre-strip DEBUG_ copy gets real file/line frames inside OpenSSL for free.

targets: $BR_ALL_TARGETS

environment:
  BUILDROOT   Toolchain and work-directory root (see build-env.sh). Required by
              most targets unless already set in the shell.
  MAKE_JOBS   Parallel jobs per target's own make (default: nproc).
  BR_FETCH    When 1, provisions each target's toolchain via T_FETCH (apt
              packages or fetch-toolchains.sh components) before building.
              CI sets this; a local run leaves it 0 so it never surprises you
              with an unattended package install.
EOF
}

case "${1:-}" in -h|--help) print_manual; exit 0 ;; esac
[ $# -ge 1 ] || { print_manual; exit 2; }

# Asks the makefile which ARCHIDs link each target, so its table is never duplicated here.
# Prints nothing when make or the makefile is absent.
archid_map() {
    [ -f "$REPO/makefile" ] && command -v make >/dev/null 2>&1 || return 0
    make -s -C "$REPO" print-archids 2>/dev/null | tr ' ' '\n' | while read -r id; do
        [ -n "$id" ] || continue
        # One sub-make resolves both probes, since every invocation pays a full makefile parse.
        set -- $(make -s -C "$REPO" ARCHID="$id" print-ossltarget print-osslver 2>/dev/null)
        [ $# -eq 2 ] || continue
        # An ARCHID pinned to another series is shown as id@version, so the reader sees it.
        echo "$1 $id$([ "$2" = "$OPENSSL_VERSION" ] || echo "@$2")"
    done
}

# Prints one line per target so a reader can see what this host can build and who consumes it.
print_target_list() {
    local map ready=0 total=0
    map="$(archid_map)"
    echo "shared flags: $OSSL_FLAGS"
    printf "%-22s %-7s %-9s %-10s %-4s %-4s %-30s %s\n" TARGET LIBC TOOLCHAIN ARCHIDS ASM ZIG "EXTRA flags" "PREFIX"
    for t in $BR_ALL_TARGETS; do
        br_target "$t" || continue
        total=$((total+1))
        local cc="${T_CC%% *}" st ids asm zig
        if [ "$T_CI" = windows ]; then st=windows
        elif command -v "$cc" >/dev/null 2>&1 || [ -x "$cc" ]; then st=ready; ready=$((ready+1)); else st=MISSING; fi
        ids=$(echo "$map" | awk -v d="$t" '$1==d{printf "%s%s", (n++?",":""), $2}')
        case "$T_FLAGS" in *-no-asm*) asm=off ;; *) asm=on ;; esac
        case "$T_CC" in "$TC_ZIG"/zig*) zig=yes ;; *) zig=- ;; esac
        printf "%-22s %-7s %-9s %-10s %-4s %-4s %-30s %s\n" "$t" "$T_LIBC" "$st" "${ids:--}" "$asm" "$zig" "${T_EXTRA:--}" "openssl/$OPENSSL_VERSION/$t$([ -d "$T_PREFIX/lib" ] || echo ' (absent)')"
    done
    echo
    echo "  $ready buildable here. MISSING = no compiler, see ./fetch-toolchains.sh. windows = built by windows/build.ps1"
    echo "  ARCHIDS = agent targets linking that prefix ('-' = none, id@version = pinned to another series)"
}

# One row per makefile ARCHID, everything asked from the makefile and targets.sh so
# nothing is restated here. The inverse view of print_target_list's ARCHIDS column.
print_archid_list() {
    local id n t v asm
    [ -f "$REPO/makefile" ] && command -v make >/dev/null 2>&1 || { echo "needs make and the repo makefile"; return 1; }
    printf "%6s  %-16s %-24s %-7s %-4s %s\n" ARCHID ARCHNAME OSSLTARGET LIBC ASM PREFIX
    for id in $(make -s -C "$REPO" print-archids); do
        set -- $(make -s -C "$REPO" ARCHID="$id" print-archname print-ossltarget print-osslver 2>/dev/null)
        [ $# -eq 3 ] || continue
        n="$1"; t="$2"; v="$3"
        if br_target "$t"; then
            case "$T_FLAGS" in *-no-asm*) asm=off ;; *) asm=on ;; esac
            printf "%6s  %-16s %-24s %-7s %-4s %s\n" "$id" "$n" "$t" "$T_LIBC" "$asm" "openssl/$v/$t$([ -d "$REPO/openssl/$v/$t/lib" ] || echo ' (absent)')"
        else
            printf "%6s  %-16s %-24s %-7s %-4s %s\n" "$id" "$n" "$t" "?" "?" "OSSLTARGET unknown to targets.sh"
        fi
    done
}

if [ "$1" = list ]; then print_target_list; exit 0; fi
if [ "$1" = list-archids ] || [ "$1" = archids ]; then print_archid_list; exit $?; fi

list="$*"; [ "$1" = all ] && list=$(print_target_names linux; print_target_names macos)

mkdir -p "$BR_WORK"
: > "$BR_WORK/build.status"

# Targets build one after another. Each OpenSSL make gets every core unless MAKE_JOBS says otherwise.
ncpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
MAKE_JOBS="${MAKE_JOBS:-$ncpu}"
[ "$MAKE_JOBS" -ge 1 ] 2>/dev/null || MAKE_JOBS=1

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
        ${SUDO:-sudo} apt-get -qq update >/dev/null && ${SUDO:-sudo} apt-get -qq -y install $apt_pkgs >/dev/null || return 1
    fi
    if [ -n "$comps" ]; then
        echo "  fetch-toolchains.sh$comps"
        ( cd "$REPO" && ./fetch-toolchains.sh -y $comps ) || return 1
    fi
}

# clang's integrated assembler expands `la` of a symbol defined later in the same file as if it
# were external, dropping the R_MIPS_LO16 pair - the AES/SHA-256 tables then load from a wrong
# address (llvm/llvm-project#65020). Forward .local declarations fix that, GNU as needs none.
br_patch_mips_la() {   # $1 is the extracted source tree. Uses T_CC; must run after Configure.
    local gen f sym
    case "$T_CC" in "$TC_ZIG"/zig*) ;; *) return 0 ;; esac
    gen=$(sed -n 's/^\(crypto\/[a-z0-9/-]*mips[a-z0-9-]*\.S\):.*/\1/p' "$1/Makefile" | sort -u)
    [ -n "$gen" ] || return 0
    ( cd "$1" && make $gen >gen-asm.log 2>&1 ) || return 1
    for f in $gen; do
        for sym in $(grep -oE 'la[[:space:]]+\$[0-9]+,[A-Za-z_][A-Za-z0-9_]+' "$1/$f" | sed 's/.*,//' | sort -u); do
            grep -q "^$sym:" "$1/$f" || continue
            grep -qE "^[[:space:]]*\.globl[[:space:]]+$sym\$" "$1/$f" && continue
            sed -i "1i .local $sym" "$1/$f"
            echo "  forward-declared .local $sym in ${f##*/} (clang la/GOT16 workaround)"
        done
    done
}

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
        echo "$t: CONFIGURE FAILED ($src/configure.log)" > "$status_file"
        tail -20 "$src/configure.log" | sed 's/^/    /'; return 1
    fi
    if ! br_patch_mips_la "$src"; then
        echo "$t: MIPS ASM GENERATION FAILED ($src/gen-asm.log)" > "$status_file"; return 1
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
