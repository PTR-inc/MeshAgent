#!/bin/bash
# Builds one or more OpenSSL targets and installs each into its prefix openssl/<version>/<target>/.
# Usage is build.sh <target|all|list>, with BUILDROOT, MAKE_JOBS and BR_FETCH=1 as optional knobs.
# Nothing is installed unless it passes the gates in probe.sh. See openssl/build/README.md.
. "$(dirname "$(readlink -f "$0")")/env.sh"
. "$BR_SCRIPTS/targets.sh"
. "$BR_SCRIPTS/probe.sh"

# The agent side of the build. It owns the ARCHID table, so the rows here are asked for, never restated.
TGT="$REPO/buildscripts/target-v3.sh"

print_manual() {
    cat <<EOF
usage: $(basename "$0") [-f|--force] [-dbg|--debug-build] <target|all|list|list-targets> [target...]

  <target> [target...]  Build one or more named targets, each installed into
                         openssl/\$OPENSSL_VERSION/<target>/. Nothing is installed
                         unless the archive passes the gates in probe.sh.
                         A target whose installed prefix carries a build-stamp.txt
                         still matching this configuration is left alone and
                         reported as UP TO DATE, so a re-run costs nothing. A
                         prefix with no stamp predates the mechanism and is
                         always rebuilt. A target already named "<name>-debug"
                         is built as one, same as -dbg/--debug-build would (see below).
  -f, --force            Build even when the stamp says the prefix is current.
  -dbg, --debug-build    Build the "<target>-debug" variant of each named target
                         instead: same toolchain, OpenSSL's own --debug Configure
                         flag (drops optimization, keeps -g), and no stripping -
                         installed into its own openssl/\$OPENSSL_VERSION/<target>-debug/
                         prefix, same idea as windows-*-debug. Off by default:
                         a plain target name never builds its debug twin.
  all                    Build every linux and macos target (BR_ALL_TARGETS,
                         filtered to those two T_CI groups). Windows targets are
                         never built here - see openssl/build/windows/build.ps1.
  list                   One row per makefile ARCHID with its ARCHNAME, whether
                         its prefix is current, the target it links, libc, asm
                         and prefix status. No build runs.
  list-targets           The same information from the other direction: the
                         target matrix (libc, toolchain readiness, the ARCHIDs
                         that link each prefix, asm on/off, whether the target
                         compiles via zig, per-target EXTRA flags, install
                         status). No build runs.
  -h, --help             Show this manual and exit.

A release archive carries no DWARF: a zig-built target is compiled with -g0 (zig cc would
otherwise emit debug info at -O2/-O3 with no -g given, see targets.sh's top-of-file comment),
a gcc-built one is stripped after the build. "<target>-debug" (or -dbg/--debug-build) builds an
unoptimized copy that keeps it, same idea as windows-*-debug.

targets: $BR_ALL_TARGETS

environment:
  BUILDROOT   Toolchain and work-directory root (see openssl/build/env.sh). Required by
              most targets unless already set in the shell.
  MAKE_JOBS   Parallel jobs per target's own make (default: nproc).
  BR_FETCH    When 1, provisions each target's toolchain via T_FETCH (apt
              packages or fetch-deps-v3.sh components) before building.
              CI sets this; a local run leaves it 0 so it never surprises you
              with an unattended package install.
EOF
}

# BR_FORCE=1/BR_DEBUG_BUILD=1 are the environment form, for CI and any caller that cannot add a flag.
BR_FORCE="${BR_FORCE:-0}"
BR_DEBUG_BUILD="${BR_DEBUG_BUILD:-0}"
args=""
for a in "$@"; do
    case "$a" in
        -h|--help)  print_manual; exit 0 ;;
        -f|--force) BR_FORCE=1 ;;
        -dbg|--debug-build) BR_DEBUG_BUILD=1 ;;
        -*)         echo "unknown option: $a" >&2; print_manual; exit 2 ;;
        *)          args="$args $a" ;;
    esac
done
# shellcheck disable=SC2086
set -- $args
[ $# -ge 1 ] || { print_manual; exit 2; }

# One tab-separated row per ARCHID: id, binary name, OpenSSL target, link mode, compiler label.
# Everything comes from targets-v3.conf through its own accessor, so no row is restated here. It is
# read in a subshell because target-v3.sh sets T_ names of its own that would overwrite targets.sh's.
# Prints nothing when target-v3.sh is absent.
archid_rows() {
    [ -x "$TGT" ] || return 0
    (
        . "$TGT"
        # The compiler that decides the row's ABI and ISA floor. A zig row is named by its target
        # triple and any -mcpu rather than by the binary, which is "zig" for every one of them.
        cc_label() {
            local rest cpu
            case "$T_CC" in
                *zig\ cc\ -target\ *|*zig\ clang\ -target\ *)
                    rest="${T_CC#*-target }"; rest="${rest%% *}"
                    case "$T_CC" in *-mcpu=*) cpu="${T_CC#*-mcpu=}"; rest="$rest+${cpu%% *}" ;; esac
                    echo "zig:$rest" ;;
                *) basename "${T_CC%% *}" ;;
            esac
        }
        for id in $(tgt_ids); do
            tgt_load "$id" >/dev/null 2>&1 || continue
            printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$T_NAME" "$T_OSSL" "$T_LINK" "$(cc_label)"
        done
    )
}

# The target-to-ARCHIDs direction of the same table.
archid_map() { archid_rows | awk -F'\t' '{print $3, $1}'; }

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
    echo "  $ready buildable here. MISSING = no compiler, see ./buildscripts/fetch-deps-v3.sh. windows = built by windows/build.ps1"
    echo "  ARCHIDS = agent targets linking that prefix ('-' = none)"
}

# One row per ARCHID, everything asked from targets-v3.conf and targets.sh so nothing is restated
# here. The inverse view of print_target_list's ARCHIDS column. The STAMP column answers what
# `build.sh <target>` would do with this prefix right now, using the same stamp_diff the build's
# own skip check calls.
prefix_state() {   # $1 target. br_target "$1" must already have been called.
    local drift
    [ -d "$T_PREFIX/lib" ] || { echo absent; return; }
    if ! drift=$(stamp_diff "$1" "$T_PREFIX"); then echo unstamped; return; fi
    # A bare "stale" makes the reader run the build to find out why, so name the disagreeing
    # fields in the parentheses. stamp_diff indents each one as "      <field>:".
    [ -n "$drift" ] || { echo current; return; }
    echo "stale($(printf '%s\n' "$drift" | sed -n 's/^ *\([a-z0-9_]*\):$/\1/p' | tr '\n' ',' | sed 's/,$//'))"
}

print_archid_list() {
    local id n t lm cc asm st rows
    rows="$(archid_rows)"
    [ -n "$rows" ] || { echo "needs $TGT"; return 1; }
    printf "%6s  %-20s %-26s %-24s %-32s %-7s %-8s %-4s %s\n" ARCHID ARCHNAME STAMP OSSLTARGET COMPILER LIBC STATIC ASM PREFIX
    while IFS=$'\t' read -r id n t lm cc; do
        [ -n "$id" ] || continue
        if br_target "$t"; then
            case "$T_FLAGS" in *-no-asm*) asm=off ;; *) asm=on ;; esac
            st=$(prefix_state "$t")
            printf "%6s  %-20s %-26s %-24s %-32s %-7s %-8s %-4s %s\n" "$id" "$n" "$st" "$t" "$cc" "$T_LIBC" "$lm" "$asm" "openssl/$OPENSSL_VERSION/$t$([ -d "$T_PREFIX/lib" ] || echo ' (absent)')"
        else
            printf "%6s  %-20s %-26s %-24s %-32s %-7s %-8s %-4s %s\n" "$id" "$n" "?" "$t" "$cc" "?" "$lm" "?" "OpenSSL target unknown to targets.sh"
        fi
    done <<EOF
$rows
EOF
    echo
    echo "  STATIC = whether the agent links its libc in, so a static row needs no matching libc"
    echo "  on the device and a dynamic one does."
    echo "  COMPILER = the agent's own compiler for that ARCHID: a zig row is named by the target"
    echo "  triple and any -mcpu, since those decide the ABI and ISA floor, not the binary's name."
    echo "  STAMP = what a build would do now: current = skipped, stale(fields) = rebuilt because"
    echo "  those build-stamp.txt fields disagree with targets.sh, unstamped = rebuilt (prefix"
    echo "  predates build-stamp.txt), absent = never built."
}

# 'list' is the ARCHID view, because that is the question asked most often: what would a build do
# for the ARCHID I am about to make. The target view keeps the older aliases so existing callers
# and muscle memory still work.
if [ "$1" = list-targets ] || [ "$1" = targets ]; then print_target_list; exit 0; fi
if [ "$1" = list ] || [ "$1" = list-archids ] || [ "$1" = archids ]; then print_archid_list; exit $?; fi

list="$*"; [ "$1" = all ] && list=$(print_target_names linux; print_target_names macos)
if [ "$BR_DEBUG_BUILD" = 1 ]; then
    # windows-*-debug is already a real name in BR_ALL_TARGETS, so 'all' never needs the suffix
    # added here; a bare '-debug' target given explicitly is left alone rather than doubled.
    list=$(for t in $list; do case "$t" in *-debug) echo "$t" ;; *) echo "$t-debug" ;; esac; done)
fi

mkdir -p "$BR_WORK"
: > "$BR_WORK/build.status"

# Targets build one after another. Each OpenSSL make gets every core unless MAKE_JOBS says otherwise.
ncpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
MAKE_JOBS="${MAKE_JOBS:-$ncpu}"
[ "$MAKE_JOBS" -ge 1 ] 2>/dev/null || MAKE_JOBS=1

# Provisions the toolchain from the target's T_FETCH tokens, which are either a
# fetch-deps-v3.sh component or an apt package. It only runs with BR_FETCH=1, which CI
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
        echo "  buildscripts/fetch-deps-v3.sh$comps"
        ( cd "$REPO" && ./buildscripts/fetch-deps-v3.sh $comps ) || return 1
    fi
}

# Strips debug info from a gcc-built release archive in place; GNU strip takes a .a directly and
# does every member. Best effort: a missing or failing tool leaves the archive untouched and
# warns rather than failing the build. A zig target comes back empty from br_strip_cmd, since
# br_target compiles it with -g0 instead - see that function's comment for why.
br_strip_archive() {   # $1 the .a to strip. Uses T_CC; br_target must have run first.
    local a="$1" strip_cmd
    strip_cmd=$(br_strip_cmd)
    [ -n "$strip_cmd" ] || return 0
    command -v "${strip_cmd%% *}" >/dev/null 2>&1 || {
        echo "  warning: strip tool '${strip_cmd%% *}' not found, leaving debug info in place"; return 0; }
    $strip_cmd "$a" || echo "  warning: $strip_cmd failed on $a, leaving debug info in place"
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
            # Not sed -i: BSD sed (macOS) spells it differently and has no "1i text" form.
            { printf '.local %s\n' "$sym"; cat "$1/$f"; } > "$1/$f.tmp" && mv "$1/$f.tmp" "$1/$f"
            BR_PATCHES="${BR_PATCHES:+$BR_PATCHES }mips-la:${f##*/}:$sym"
            echo "  forward-declared .local $sym in ${f##*/} (clang la/GOT16 workaround)"
        done
    done
}

# One build-stamp.txt per target prefix. The gating half comes from targets.sh, which verify.sh
# also sources, so a future rebuild gate compares like with like. The rest is for a human reading
# a committed prefix months later, and is deliberately not part of stamp_key.
write_build_stamp() {   # $1 target, $2 the staged prefix directory
    local f="$2/build-stamp.txt"
    {
        echo "# Written by openssl/build/build.sh. The fields above 'stamp_key' decide whether a"
        echo "# rebuild is needed; the ones below it only describe the build that produced this."
        stamp_gating_fields "$1" "${BR_PATCHES:-none}"
        echo "stamp_key: $(stamp_key "$1" "${BR_PATCHES:-none}")"
        echo "---"
        echo "built_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "archive_platform: $P_PLATFORM"
        echo "archive_compiler: $P_COMPILER"
        echo "objects: $P_MEMBERS ($P_FORMAT/$P_CLASS $P_MACHINE)"
        echo "glibc_only_refs: $P_GLIBC"
        echo "ucontext_refs: $P_UCONTEXT"
        echo "libcrypto_sha256: $(v3_sha256 "$2/lib/libcrypto.a" 2>/dev/null)"
        echo "libssl_sha256: $(v3_sha256 "$2/lib/libssl.a" 2>/dev/null)"
    } > "$f"
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

    # An installed prefix whose stamp still describes this configuration is already the archive
    # this run would produce, so building it again only rewrites identical bytes. stamp_diff
    # returns nonzero when there is no stamp at all, which is not a match: such a prefix predates
    # the mechanism, nothing can be concluded about it, and it is rebuilt.
    local drift
    if [ "$BR_FORCE" != 1 ] && [ -d "$T_PREFIX/lib" ] && drift=$(stamp_diff "$t" "$T_PREFIX") && [ -z "$drift" ]; then
        {
        echo "=================== $t ($T_CONF/$T_LIBC) ==================="
        echo "  up to date: openssl/$OPENSSL_VERSION/$t still matches its build-stamp.txt, nothing to do (-f rebuilds anyway)"
        } | tee "$log_file"
        echo "$t: UP TO DATE" > "$status_file"
        return 0
    fi

    {
    echo "=================== $t ($T_CONF/$T_LIBC) ==================="
    [ -n "${drift:-}" ] && echo "  rebuilding: build-stamp.txt disagrees with targets.sh:$drift"

    if [ "$BR_FETCH" = 1 ] && [ -n "$T_FETCH" ]; then
        br_provision || { echo "$t: PROVISIONING FAILED (T_FETCH=$T_FETCH)" > "$status_file"; return 1; }
    fi

    BR_PATCHES=
    src="$BR_WORK/$t"; stage="$BR_WORK/$t.stage"
    # zig otherwise compiles the BSD and macOS targets against its own bundled headers instead of the pinned
    # sysroot or SDK. This block runs in the pipeline's subshell, so the export ends with this target.
    if [ -n "$T_ZIGROOT" ]; then
        export ZIG_LIBC="$BR_WORK/$t.zig-libc.txt"; zig_libc_file "$T_ZIGROOT" "$ZIG_LIBC"
    else
        unset ZIG_LIBC
    fi
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

    # Debug builds (T_DEBUG=1, from a "-debug" target name) keep every symbol. A release build
    # gets DWARF stripped back out here by default - build.sh's own top comment and
    # targets.sh's br_strip_cmd explain why it was there to begin with (zig cc's default). Best
    # effort: an unresolvable strip tool is reported and skipped rather than failing the build,
    # since the archive itself is still correct either way.
    if [ "$T_DEBUG" != 1 ]; then
        br_strip_archive "$stage/$OPENSSL_VERSION/$t/lib/libcrypto.a"
        br_strip_archive "$stage/$OPENSSL_VERSION/$t/lib/libssl.a"
    fi

    # After the strip, never before it, so the gate judges the archive that actually ships. It used
    # to run above and a wrong strip could then quietly gut an already-approved archive: that is how
    # a linux-sparc64-glibc libssl.a with 0 of its 985 symbols got installed and committed, and the
    # failure only surfaced much later as "archive has no index" at agent link time. The P_ fields
    # this sets are all recorded below stamp_key, so probing later does not move the rebuild gate.
    probe_archive "$stage/$OPENSSL_VERSION/$t/lib/libcrypto.a"

    write_build_stamp "$t" "$stage/$OPENSSL_VERSION/$t"
    echo "  version : $P_VERSION"
    echo "  platform: $P_PLATFORM   objects: $P_MEMBERS ($P_FORMAT/$P_CLASS $P_MACHINE)"
    echo "  compiler: $P_COMPILER"
    echo "  glibc-only refs: $P_GLIBC   ucontext refs: $P_UCONTEXT   (libc: $T_LIBC)"
    if ! gate_target "$t" "$stage/$OPENSSL_VERSION/$t"; then
        echo "$t: REJECTED - see the REJECT lines above" > "$status_file"; return 1
    fi

    # Installed by rename rather than by copying into place. A copy interrupted partway leaves a
    # half-populated prefix that every later gate reads as a real one, and an empty
    # include/openssl is indistinguishable from a target whose headers were never generated.
    # The staging directory is a sibling so the rename stays on one filesystem.
    local installing="$T_PREFIX.installing"
    rm -rf "$installing" && mkdir -p "$(dirname "$T_PREFIX")"
    if ! cp -r "$stage/$OPENSSL_VERSION/$t" "$installing"; then
        rm -rf "$installing"
        echo "$t: INSTALL COPY FAILED (openssl/$OPENSSL_VERSION/$t left as it was)" > "$status_file"; return 1
    fi
    rm -rf "$T_PREFIX" && mv "$installing" "$T_PREFIX"
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
        "$t: OK "*|"$t: UP TO DATE") ;;
        *) rc=1 ;;
    esac
done
exit $rc
