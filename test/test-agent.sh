#!/usr/bin/env bash
#
# MeshAgent combined test driver.
#
# The single entry point for automated agent testing. Runs these phases, in order, against one binary:
#   1. -info sanity banner (version, ARCHID, OpenSSL), and the linked OpenSSL must be openssl/VERSION
#   2. test/stress-test.js, every testmodule except 06-*   must pass
#   3. test/stress-test.js, the 06-* sections only          known native crashes (TLS reconnect,
#                                                           WebSocket teardown)
#   4. the same core run delivered via -b64exec             the meshcore delivery path, must pass
#   5. connection test against <binary>.msh                 connect, authenticate, launch meshcore,
#                                                           and persist the identity into <binary>.db
#   6. valgrind memcheck over the core stress run           leak report
#   7. AddressSanitizer over the core stress run            needs an ASAN=1 build, see --asan
#
# Every check lives in test/testmodules/*.js, which stress-test.js discovers on its own. This
# script only launches the runs, judges exit codes and markers, and tabulates. The legacy
# upstream scripts in test/ (self-test.js, leaktest.js, update-test.js, authtest.js) are not used.
# Everything is written to the console and to a logfile at the same time.
#
# Usage:  test/test-agent.sh [options]
#   -b, --binary PATH     agent binary to test (default: newest build/*/meshagent_*)
#   -d, --debug PATH      unstripped binary for valgrind (default: DEBUG_<binary>, if present)
#   -l, --log PATH        logfile (default: test/logs/test-agent-<host-or-arch>-<timestamp>.log)
#       --qemu "CMD"      run the agent under qemu, for example --qemu "qemu-riscv64 -cpu thead-c906".
#                         Auto-detected from the binary's architecture when not given.
#       --no-qemu         never use qemu (fails fast on a foreign-arch binary instead)
#   -q, --quick           skip the valgrind phases
#       --no-valgrind     same as --quick
#       --no-connect      skip the .msh connection test
#       --msh PATH        .msh to connect with. The agent only ever reads <binary>.msh next to
#                         itself, so PATH is copied there. An existing, different <binary>.msh
#                         is kept as <binary>.msh.prev-<timestamp> and never overwritten silently.
#       --connect-timeout N  ceiling in seconds for the connection phase (default 15, or 120 under
#                         qemu). The phase ends as soon as meshcore is seen running.
#       --asan PATH       ASan-instrumented agent for the ASan phase (default: <binary>_asan next to
#                         it, or the build/<arch>_asan/ sibling directory from `make ... ASAN=1`).
#                         Build one with:  make linux ARCHID=<id> ASAN=1
#   -y, --yes             non-interactive: install missing tools without asking
#       --ci              GitHub Actions mode: ::group:: folding, ::error:: and ::warning::
#                         annotations, a job-summary table in $GITHUB_STEP_SUMMARY, never
#                         prompts, never truncates output. Implies --yes.
#       --strict          the known TLS crash counts as a failure too (default under --ci)
#       --lenient         under --ci, keep reporting the known TLS crash as KNOWN, not FAIL
#   -h, --help            this text
#
# Notes: phase output is captured to a file rather than piped, because spawned children can hold
# stdout open so a pipe never sees EOF. The script changes to the repo root itself, since
# stress-test.js needs that. Valgrind is skipped under qemu, which it cannot instrument.

set -u

# --------------------------------------------------------------------------------------------
# defaults / arg parsing
# --------------------------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_PWD="$PWD"
# Relative paths on the command line are the caller's, not the repo's. Anchor them before the
# cd into the repo root that the rest of the script relies on.
abspath() { case "$1" in ''|/*) printf '%s' "$1";; *) printf '%s/%s' "$CALLER_PWD" "$1";; esac; }

BIN=""
DBGBIN=""
LOGFILE=""
QEMU=""
QEMU_AUTO=1
RUN_VALGRIND=1
ASSUME_YES=0
STRICT=0
LENIENT=0
CI_MODE=0
RUN_CONNECT=1
ASAN_BIN=""
MSH_SRC=""
CONNECT_TIMEOUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--binary)     BIN="${2:-}"; shift 2;;
        -d|--debug)      DBGBIN="${2:-}"; shift 2;;
        -l|--log)        LOGFILE="${2:-}"; shift 2;;
        --qemu)          QEMU="${2:-}"; QEMU_AUTO=0; shift 2;;
        --no-qemu)       QEMU=""; QEMU_AUTO=0; shift;;
        -q|--quick|--no-valgrind) RUN_VALGRIND=0; shift;;
        --no-connect)    RUN_CONNECT=0; shift;;
        --msh|--mesh)    MSH_SRC="${2:-}"; shift 2;;
        --connect-timeout) CONNECT_TIMEOUT="${2:-}"; shift 2;;
        --asan)          ASAN_BIN="${2:-}"; shift 2;;
        -y|--yes)        ASSUME_YES=1; shift;;
        --ci)            CI_MODE=1; ASSUME_YES=1; [ "$LENIENT" = 1 ] || STRICT=1; shift;;
        --strict)        STRICT=1; shift;;
        --lenient)       LENIENT=1; [ "$CI_MODE" = 1 ] && STRICT=0; shift;;
        -h|--help)       sed -n '2,49p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2;;
    esac
done
BIN="$(abspath "$BIN")"; DBGBIN="$(abspath "$DBGBIN")"; LOGFILE="$(abspath "$LOGFILE")"
ASAN_BIN="$(abspath "$ASAN_BIN")"; MSH_SRC="$(abspath "$MSH_SRC")"
cd "$REPO_ROOT" || exit 1

# --------------------------------------------------------------------------------------------
# logging
# --------------------------------------------------------------------------------------------
if [ -z "$LOGFILE" ]; then
    mkdir -p test/logs
    LOGFILE="test/logs/test-agent-$(date +%Y%m%d-%H%M%S).log"
fi
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null
: > "$LOGFILE" || { echo "cannot write logfile: $LOGFILE" >&2; exit 1; }

say()  { printf '%s\n' "$*" | tee -a "$LOGFILE"; }
hr()   { say "------------------------------------------------------------------------------"; }
GROUP_OPEN=0
endgroup() { [ "$CI_MODE" = "1" ] && [ "$GROUP_OPEN" = "1" ] && { echo "::endgroup::"; GROUP_OPEN=0; }; return 0; }
head2(){
    endgroup
    say ""; say "=============================================================================="; say "$*"; say "=============================================================================="
    if [ "$CI_MODE" = "1" ]; then echo "::group::$*"; GROUP_OPEN=1; fi
}

TMPDIR_RUN="$(mktemp -d)"
CHILD_PIDS=()
cleanup() {
    for p in "${CHILD_PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$TMPDIR_RUN"
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------------------------
# tool discovery: offer to install what's missing
# --------------------------------------------------------------------------------------------
pkg_install_cmd() {   # $1 is the package name. Prints the install command for this distro.
    if command -v brew >/dev/null 2>&1; then
        case "$1" in
            # Upstream valgrind has no macOS support past 10.13. LouisBrunner's fork covers
            # current macOS including Apple Silicon and is what brew can install.
            valgrind) echo "brew install --HEAD LouisBrunner/valgrind/valgrind";;
            *)        echo "brew install $1";;
        esac
    elif command -v apt-get >/dev/null 2>&1; then echo "apt-get install -y $1"
    elif command -v dnf     >/dev/null 2>&1; then echo "dnf install -y $1"
    elif command -v yum     >/dev/null 2>&1; then echo "yum install -y $1"
    elif command -v zypper  >/dev/null 2>&1; then echo "zypper install -y $1"
    elif command -v pacman  >/dev/null 2>&1; then echo "pacman -S --noconfirm $1"
    elif command -v apk     >/dev/null 2>&1; then echo "apk add $1"
    else echo ""; fi
}

# ensure_tool <command> <package> returns 0 if available (possibly after installing), 1 if not.
ensure_tool() {
    local tool="$1" pkg="$2" cmd ans sudo=""
    command -v "$tool" >/dev/null 2>&1 && return 0

    cmd="$(pkg_install_cmd "$pkg")"
    say "MISSING TOOL: '$tool' is not installed."
    if [ -z "$cmd" ]; then
        say "  No known package manager found - install '$pkg' manually and re-run."
        return 1
    fi
    # brew refuses to run as root and never wants sudo. The distro package managers do.
    [ "$(id -u)" != "0" ] && [ "${cmd%% *}" != brew ] && sudo="sudo "
    if [ "$ASSUME_YES" = "1" ]; then
        ans=y
    elif [ -t 0 ]; then
        printf '  Install it now with: %s%s  [y/N] ' "$sudo" "$cmd"
        read -r ans
        printf '  Install it now with: %s%s  [answered: %s]\n' "$sudo" "$cmd" "${ans:-N}" >> "$LOGFILE"
    else
        say "  Not interactive - skipping. To enable this phase, run: ${sudo}${cmd}"
        return 1
    fi
    case "${ans:-N}" in
        [yY]*)
            say "  Installing: ${sudo}${cmd}"
            # shellcheck disable=SC2086
            ${sudo}${cmd} >>"$LOGFILE" 2>&1
            if command -v "$tool" >/dev/null 2>&1; then say "  '$tool' installed."; return 0; fi
            say "  Install failed - see the log for the package manager output."; return 1;;
        *)  say "  Skipped. To enable this phase later, run: ${sudo}${cmd}"; return 1;;
    esac
}

# --------------------------------------------------------------------------------------------
# binary + architecture / qemu selection
# --------------------------------------------------------------------------------------------
if [ -z "$BIN" ]; then
    # Newest non-DEBUG meshagent_* executable under build/<arch>/, or the repo root for pre-layout
    # builds. *_asan is a special-purpose build that the ASan phase finds on its own.
    BIN="$(find build -mindepth 2 -maxdepth 2 -type f -name 'meshagent_*' ! -name '*.db' ! -name '*.msh' ! -name '*.log' \
           ! -name '*_asan' -perm -u+x -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    [ -n "$BIN" ] || BIN="$(find . -maxdepth 1 -type f -name 'meshagent_*' ! -name '*.db' ! -name '*.msh' ! -name '*.log' \
           ! -name '*_asan' -perm -u+x -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
fi
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "no agent binary found - pass one with --binary" >&2; exit 1; }
[ -z "$DBGBIN" ] && DBGBIN="$(dirname "$BIN")/DEBUG_$(basename "$BIN")"
[ -x "$DBGBIN" ] || DBGBIN="$BIN"

elf_interp() { readelf -l "$1" 2>/dev/null | sed -n 's/.*interpreter: \([^]]*\).*/\1/p' | head -1; }
libc_of_interp() {
    case "$1" in
        "")            echo "static";;
        *ld-musl*)     echo "musl";;
        *ld-uClibc*)   echo "uclibc";;
        *ld-linux*|*ld.so*) echo "glibc";;
        *)             echo "unknown";;
    esac
}
BIN_DESC="$(file -b "$BIN" 2>/dev/null)"
BIN_INTERP="$(elf_interp "$BIN")"; BIN_LIBC="$(libc_of_interp "$BIN_INTERP")"
case "$BIN_DESC" in *Mach-O*)
    BIN_LIBC="macos (libSystem)"
    # There is no qemu-user for Darwin. On any other host the kernel would hand a Mach-O to /bin/sh.
    [ "$(uname -s)" = Darwin ] || { echo "$(basename "$BIN") is a Mach-O binary - run this driver on a Mac (there is no user-mode emulator for Darwin)." >&2; exit 1; };;
esac
command -v readelf >/dev/null 2>&1 || case "$BIN_DESC" in *ELF*) BIN_LIBC="unknown (no readelf)";; esac
HOST_ARCH="$(uname -m)"

# qemu_for <file(1) description> prints the qemu-user binary name, or "" when it runs natively.
qemu_for() {
    case "$1" in
        *x86-64*)                     [ "$HOST_ARCH" = "x86_64" ] && echo "" || echo "qemu-x86_64";;
        *Intel\ 80386*|*Intel\ i386*) [ "$HOST_ARCH" = "x86_64" ] || [ "$HOST_ARCH" = "i686" ] && echo "" || echo "qemu-i386";;
        *aarch64*|*ARM\ aarch64*)     [ "$HOST_ARCH" = "aarch64" ] && echo "" || echo "qemu-aarch64";;
        *ARM*)                        [ "${HOST_ARCH#arm}" != "$HOST_ARCH" ] && echo "" || echo "qemu-arm";;
        *32-bit*UCB\ RISC-V*)         [ "$HOST_ARCH" = "riscv32" ] && echo "" || echo "qemu-riscv32";;
        *UCB\ RISC-V*)                [ "$HOST_ARCH" = "riscv64" ] && echo "" || echo "qemu-riscv64";;
        *LSB*MIPS*|*mipsel*)          [ "$HOST_ARCH" = "mips64el" ] || [ "$HOST_ARCH" = "mipsel" ] && echo "" || echo "qemu-mipsel";;
        *MSB*MIPS*|*MIPS*)            [ "$HOST_ARCH" = "mips" ] && echo "" || echo "qemu-mips";;
        *PowerPC*64*)                 echo "qemu-ppc64";;
        *PowerPC*)                    echo "qemu-ppc";;
        *) echo "";;
    esac
}

# qemu-user needs a sysroot that holds the loader named in the ELF's PT_INTERP, because qemu
# prefixes that path verbatim. glibc loaders live under /usr, musl and uClibc loaders only in
# the toolchains under $BUILDROOT/toolchains. Override per host with QEMU_SYSROOT_ROOTS. See BUILD.md.
QEMU_SYSROOT_ROOTS="${QEMU_SYSROOT_ROOTS:-${BUILDROOT:-/opt/buildroot}/toolchains ${BUILDROOT:-/opt/buildroot}/sysroots /usr}"
qemu_sysroot_for() {   # $1 is the qemu binary name, $2 is the PT_INTERP path, which may be empty.
    local interp="$2" hits r
    [ -z "$interp" ] && { echo ""; return; }
    # Match the interpreter's full relative path, because lib/ versus lib64/ matters. find -L lets
    # lib64 symlinks resolve. OpenWrt's staging_dir/host holds x86_64 host tools, not the target.
    hits="$(for r in $QEMU_SYSROOT_ROOTS; do [ -d "$r" ] && find -L "$r" -maxdepth 6 -path "*$interp" 2>/dev/null; done \
            | grep -v '/staging_dir/host/' | sort -V)"
    [ -z "$hits" ] && { echo ""; return; }
    case "$(libc_of_interp "$interp")" in
        glibc) r="$(echo "$hits" | grep -m1 '^/usr/')"; [ -n "$r" ] || r="$(echo "$hits" | tail -1)";;
        *)     r="$(echo "$hits" | tail -1)";;
    esac
    echo "${r%$interp}"
}

# A vendor-extension build dies with SIGILL on qemu's default CPU model. ARCHID=45 (Allwinner D1,
# T-Head C906) is that case in this tree. The ELF's RISC-V arch attribute names the extensions,
# so the CPU model is picked from that rather than from the ARCHID.
qemu_cpu_hint() {   # $1 is the binary, $2 the qemu binary name. Prints "-cpu <model>" or "".
    local a
    case "$2" in
        qemu-riscv64)
            a="$(readelf -A "$1" 2>/dev/null | grep -m1 Tag_RISCV_arch)"
            case "$a" in *xthead*|*v0p7*) echo "-cpu thead-c906";; *) echo "";; esac;;
        *) echo "";;
    esac
}

# Fallbacks tried in order when the binary dies with SIGILL on whatever model was picked first.
qemu_cpu_candidates() {   # $1 is the qemu binary name. Prints a list separated by '|' characters.
    case "$1" in
        qemu-riscv64)          echo "-cpu thead-c906|-cpu max|-cpu rv64";;
        qemu-riscv32)          echo "-cpu max|-cpu rv32";;
        qemu-aarch64)          echo "-cpu max|-cpu cortex-a53";;
        qemu-arm)              echo "-cpu max|-cpu cortex-a15";;
        qemu-mips|qemu-mipsel) echo "-cpu max|-cpu 24Kf";;
        *)                     echo "-cpu max";;
    esac
}

QEMU_BIN=""; QEMU_CPU=""; QEMU_SYSROOT=""; QEMU_NOTE=""
build_runner() {
    RUNNER=()
    [ -z "$QEMU_BIN" ] && { [ -n "$QEMU" ] && read -r -a RUNNER <<< "$QEMU"; return; }
    RUNNER=("$QEMU_BIN")
    [ -n "$QEMU_CPU" ] && RUNNER+=($QEMU_CPU)
    [ -n "$QEMU_SYSROOT" ] && RUNNER+=(-L "$QEMU_SYSROOT")
    QEMU="${RUNNER[*]}"
}

if [ "$QEMU_AUTO" = "1" ]; then
    NEEDED="$(qemu_for "$BIN_DESC")"
    if [ -n "$NEEDED" ]; then
        if ensure_tool "$NEEDED" "qemu-user"; then
            QEMU_BIN="$NEEDED"
            QEMU_SYSROOT="$(qemu_sysroot_for "$NEEDED" "$BIN_INTERP")"
            if [ -n "$BIN_INTERP" ] && [ -z "$QEMU_SYSROOT" ]; then
                say "No sysroot providing $BIN_INTERP found for this $BIN_LIBC binary (searched: $QEMU_SYSROOT_ROOTS)."
                say "  fetch the matching toolchain (./fetch-toolchains.sh list) or pass --qemu \"$NEEDED -L <sysroot>\" - aborting."
                exit 1
            fi
            QEMU_CPU="$(qemu_cpu_hint "$BIN" "$NEEDED")"
            [ -n "$QEMU_CPU" ] && QEMU_NOTE="$QEMU_CPU chosen from the ELF arch attribute (vendor ISA extensions)"
        else
            say "Cannot run a $BIN_DESC binary on $HOST_ARCH without qemu - aborting."
            exit 1
        fi
    fi
fi

# The runner prefix as an array, empty when running natively.
build_runner

# Timeout scaling, because emulation is slow and valgrind is slower.
SCALE=1
[ -n "$QEMU" ] && SCALE=10

# Probe the emulated binary once with -info. SIGILL (exit 132) means the CPU model is wrong, not
# that the agent is broken, so walk the candidate models and adopt the first one that runs.
if [ -n "$QEMU_BIN" ]; then
    probe="$TMPDIR_RUN/probe.log"
    { timeout -k 5 $((20*SCALE)) ${RUNNER[@]+"${RUNNER[@]}"} "$BIN" -info > "$probe" 2>&1; } 2>/dev/null
    if [ $? -eq 132 ]; then
        found=0
        while IFS= read -r cand; do
            [ "$cand" = "$QEMU_CPU" ] && continue
            QEMU_CPU="$cand"; build_runner
            { timeout -k 5 $((20*SCALE)) ${RUNNER[@]+"${RUNNER[@]}"} "$BIN" -info > "$probe" 2>&1; } 2>/dev/null
            if [ $? -ne 132 ]; then found=1; break; fi
        done <<< "$(qemu_cpu_candidates "$QEMU_BIN" | tr '|' '\n')"
        if [ "$found" = "1" ]; then
            QEMU_NOTE="$QEMU_CPU adopted after the previous model raised SIGILL"
        else
            QEMU_CPU=""; build_runner
            QEMU_NOTE="every candidate -cpu model raised SIGILL - pass the right one with --qemu"
        fi
    fi
fi
VG_SCALE=30

if [ "$RUN_VALGRIND" = "1" ] && [ -n "$QEMU" ]; then
    RUN_VALGRIND=0
    VG_SKIP_REASON="valgrind cannot instrument a qemu-user emulated binary"
fi
if [ "$RUN_VALGRIND" = "1" ]; then
    if ! ensure_tool valgrind valgrind; then
        RUN_VALGRIND=0
        VG_SKIP_REASON="valgrind not installed"
    fi
fi

# --------------------------------------------------------------------------------------------
# phase plumbing
# --------------------------------------------------------------------------------------------
PHASE_NAMES=(); PHASE_RESULTS=(); PHASE_NOTES=()
FAILED=0

# Exit codes of 128 plus n from timeout or the shell are fatal signals. Name them, because
# "exit 132" alone reads like an application error when it really means SIGILL.
signame() {
    case "$1" in
        132) echo "SIGILL";;  134) echo "SIGABRT";; 133) echo "SIGTRAP";;
        139) echo "SIGSEGV";; 137) echo "SIGKILL";; 143) echo "SIGTERM";;
        124) echo "timed out";; *) echo "";;
    esac
}
rcdesc() { local n; n="$(signame "$1")"; [ -n "$n" ] && echo "exit $1 ($n)" || echo "exit $1"; }

record() { PHASE_NAMES+=("$1"); PHASE_RESULTS+=("$2"); PHASE_NOTES+=("${3:-}"); 
           case "$2" in FAIL) FAILED=$((FAILED+1));; esac; }

# run_cmd <timeout-sec> <outfile> <cmd...> returns the command's exit code.
# macOS ships no coreutils timeout, so perl's alarm is the portable stand-in with the same -k
# grace handling: TERM at the deadline, then KILL a few seconds later.
if ! command -v timeout >/dev/null 2>&1; then
timeout() {
    local grace=0
    if [ "$1" = -k ]; then grace="$2"; shift 2; fi
    local t="$1"; shift
    perl -e '
        my ($t, $g) = (shift, shift);
        my $pid = fork();
        if ($pid == 0) { exec @ARGV or exit 127; }
        my $rc; my $killed = 0;
        local $SIG{ALRM} = sub { kill "TERM", $pid; $killed = 1; alarm $g if $g > 0; $SIG{ALRM} = sub { kill "KILL", $pid }; };
        alarm $t;
        waitpid($pid, 0); $rc = $?;
        exit 124 if $killed;
        exit(($rc & 127) ? 128 + ($rc & 127) : $rc >> 8);
    ' "$t" "$grace" "$@"
}
fi

run_cmd() {
    local t="$1" out="$2"; shift 2
    # GNU timeout re-raises the child's signal on itself, so the shell would print its own
    # "Illegal instruction" or "Segmentation fault" message. The braces and 2>/dev/null swallow
    # that while keeping the exit code and the command's output, which is already in "$out".
    { timeout -k 5 "$t" "$@" > "$out" 2>&1; } 2>/dev/null
    return $?
}

emit() {   # Copy a phase's captured output to the console and the log.
    local f="$1" maxlines="${2:-0}"
    [ "$CI_MODE" = "1" ] && maxlines=0        # CI folds the group instead of truncating.
    if [ "$maxlines" -gt 0 ] && [ "$(wc -l < "$f")" -gt "$maxlines" ]; then
        head -"$maxlines" "$f"
        echo "  ... (output truncated, full text in $LOGFILE)"
        cat "$f" >> "$LOGFILE"
    else
        tee -a "$LOGFILE" < "$f"
    fi
}

# --------------------------------------------------------------------------------------------
# start
# --------------------------------------------------------------------------------------------
head2 "MeshAgent test driver"
say "date        : $(date '+%Y-%m-%d %H:%M:%S')"
say "repo        : $REPO_ROOT"
say "binary      : $BIN"
say "             $BIN_DESC"
say "debug binary: $DBGBIN"
say "host arch   : $HOST_ARCH"
say "libc        : $BIN_LIBC${BIN_INTERP:+ (PT_INTERP $BIN_INTERP)}${QEMU_SYSROOT:+, sysroot $QEMU_SYSROOT}"
say "runner      : ${QEMU:-native}"
[ -n "$QEMU_NOTE" ] && say "              ($QEMU_NOTE)"
say "valgrind    : $( [ "$RUN_VALGRIND" = "1" ] && valgrind --version || echo "disabled (${VG_SKIP_REASON:-requested})" )"
say "logfile     : $LOGFILE"

# --- phase 1: -info -------------------------------------------------------------------------
head2 "[1/7] agent -info"
OUT="$TMPDIR_RUN/info.log"
run_cmd $((20*SCALE)) "$OUT" ${RUNNER[@]+"${RUNNER[@]}"} "$BIN" -info; RC=$?
emit "$OUT" 20
if [ $RC -eq 0 ]; then
    record "agent -info" PASS
    # OpenSSL's own headers-match-library test, done here instead of as a startup abort: the
    # version the linked libcrypto reports must be the prefix version, openssl/VERSION unless
    # OSSLVER was passed to make. A mismatch means the agent was linked against another prefix.
    WANT_OSSL="${OSSLVER:-$(tr -d '[:space:]' < openssl/VERSION 2>/dev/null)}"
    GOT_OSSL="$(grep -oE 'Using OpenSSL [0-9]+\.[0-9]+\.[0-9]+[a-z]?' "$OUT" | head -1 | cut -c15-)"
    if [ -z "$WANT_OSSL" ]; then say "  (no openssl/VERSION to compare the linked OpenSSL against)"
    elif [ -z "$GOT_OSSL" ]; then record "openssl version" SKIP "-info printed no 'Using OpenSSL' line (NOTLS build?)"
    elif [ "$GOT_OSSL" = "$WANT_OSSL" ]; then record "openssl version" PASS
    else record "openssl version" FAIL "agent links OpenSSL $GOT_OSSL, openssl/VERSION pins $WANT_OSSL (pass OSSLVER=$GOT_OSSL if that was intended)"; fi
else
    # Only reachable with an explicit --qemu. The auto path probes and retries CPU models itself.
    if [ $RC -eq 132 ] && [ -n "$QEMU" ]; then
        say "  SIGILL under qemu almost always means the wrong CPU model, not a broken agent."
        say "  Try: --qemu \"${RUNNER[0]} -cpu <model>${QEMU_SYSROOT:+ -L $QEMU_SYSROOT}\"  (ARCHID=45 needs -cpu thead-c906)"
    fi
    record "agent -info" FAIL "$(rcdesc $RC)"
fi

# --- phase 2: stress test, core sections ----------------------------------------------------
# The 06-* testmodules are the known native-crash sections (TLS reconnect and WebSocket session
# teardown, and the net.c:938 use-after-free). They run in phase 3, apart
# from the core, so one crash cannot take every other check down with it.
KNOWN_EXCL="06-"
CORE_EXCL="$(ls test/testmodules | grep -v '^06-' | sed 's/\.js$//' | tr '\n' ',' | sed 's/,$//')"
head2 "[2/7] stress test - every testmodule except the known-crash 06-* sections"
OUT="$TMPDIR_RUN/stress-core.log"
run_cmd $((120*SCALE)) "$OUT" ${RUNNER[@]+"${RUNNER[@]}"} "$BIN" test/stress-test.js \
        --exclude=$KNOWN_EXCL --watchdog=$((60000*SCALE)); RC=$?
emit "$OUT"
TOTAL_LINE="$(grep -o 'TOTAL: .*' "$OUT" | tail -1)"
# Trust the TOTAL line over the exit code, because a failing exit status does not always survive.
FAILED_CHECKS="$(printf '%s' "$TOTAL_LINE" | sed -n 's/.*passed, \([0-9]*\) failed.*/\1/p')"
if [ $RC -eq 0 ] && [ "${FAILED_CHECKS:-1}" = "0" ]; then record "stress (core)" PASS "$TOTAL_LINE"
elif [ -z "$TOTAL_LINE" ]; then record "stress (core)" FAIL "$(rcdesc $RC) - no TOTAL line, the run did not finish"
else record "stress (core)" FAIL "$(rcdesc $RC) $TOTAL_LINE"; fi

# --- phase 3: stress test, TLS section only -------------------------------------------------
head2 "[3/7] stress test - known-crash 06-* sections only (TLS, WebSocket)"
OUT="$TMPDIR_RUN/stress-known.log"
run_cmd $((60*SCALE)) "$OUT" ${RUNNER[@]+"${RUNNER[@]}"} "$BIN" test/stress-test.js \
        --exclude=$CORE_EXCL --watchdog=$((20000*SCALE)); RC=$?
emit "$OUT"
KNOWN_TOTAL="$(grep -o 'TOTAL: .*' "$OUT" | tail -1)"
KNOWN_FAILED="$(printf '%s' "$KNOWN_TOTAL" | sed -n 's/.*passed, \([0-9]*\) failed.*/\1/p')"
case $RC in
    0)   if [ "${KNOWN_FAILED:-1}" = "0" ]; then record "stress (known 06-*)" PASS "no crash reproduced - $KNOWN_TOTAL"
         else record "stress (known 06-*)" FAIL "$KNOWN_TOTAL"; fi;;
    254|139|134)
         if [ "$STRICT" = "1" ]; then record "stress (known 06-*)" FAIL "$(rcdesc $RC) - known crash (TLS #1 / WebSocket teardown), ${KNOWN_TOTAL:-no TOTAL}"
         else record "stress (known 06-*)" KNOWN "$(rcdesc $RC) - known crash (TLS #1 / WebSocket teardown), ${KNOWN_TOTAL:-no TOTAL}"; fi;;
    *)   record "stress (known 06-*)" FAIL "$(rcdesc $RC) (unexpected - not the known crash signature)";;
esac

# --- phase 4: the core run again, delivered the way meshcore is (-b64exec) -------------------
head2 "[4/7] stress test via -b64exec (meshcore delivery path)"
OUT="$TMPDIR_RUN/stress-b64.log"
# argv is empty under -b64exec, so the exclude and watchdog defaults are patched into the script.
B64="$(sed 's/^var OPT_EXCLUDE = \[\];/var OPT_EXCLUDE = ["06-"];/; s/^var OPT_WATCHDOG = 10000;/var OPT_WATCHDOG = '$((60000*SCALE))';/' test/stress-test.js | base64 -w0)"
run_cmd $((90*SCALE)) "$OUT" ${RUNNER[@]+"${RUNNER[@]}"} "$BIN" -b64exec "$B64"; RC=$?
emit "$OUT" 30
B64_TOTAL="$(grep -o 'TOTAL: .*' "$OUT" | tail -1)"
B64_FAILED="$(printf '%s' "$B64_TOTAL" | sed -n 's/.*passed, \([0-9]*\) failed.*/\1/p')"
# Only the check count "(of N)" must match phase 2. The KNOWN split varies between runs.
B64_OF="$(printf '%s' "$B64_TOTAL" | sed -n 's/.*(of \([0-9]*\)).*/\1/p')"
CORE_OF="$(printf '%s' "$TOTAL_LINE" | sed -n 's/.*(of \([0-9]*\)).*/\1/p')"
if [ $RC -eq 0 ] && [ "${B64_FAILED:-1}" = "0" ] && [ -n "$B64_OF" ] && [ "$B64_OF" = "$CORE_OF" ]; then record "stress (-b64exec)" PASS "$B64_TOTAL"
elif [ $RC -eq 0 ] && [ "${B64_FAILED:-1}" = "0" ]; then record "stress (-b64exec)" FAIL "passed, but ran a different check count than phase 2: '$B64_TOTAL' vs '$TOTAL_LINE'"
elif [ -z "$B64_TOTAL" ]; then record "stress (-b64exec)" FAIL "$(rcdesc $RC) - no TOTAL line, the run did not finish"
else record "stress (-b64exec)" FAIL "$(rcdesc $RC) $B64_TOTAL"; fi

# --- phase 5: connection test against the server named in <binary>.msh ------------------------
head2 "[5/7] connection test ($(basename "$BIN").msh)"
MSH="$BIN.msh"
if [ -n "$MSH_SRC" ] && [ "$RUN_CONNECT" = "1" ]; then
    if [ ! -f "$MSH_SRC" ]; then
        say "  --msh $MSH_SRC: no such file"
        record "connection test" FAIL "--msh $MSH_SRC not found"; MSH=""
    elif [ -f "$MSH" ] && ! cmp -s "$MSH_SRC" "$MSH"; then
        keep="$MSH.prev-$(date +%Y%m%d-%H%M%S)"
        mv -f "$MSH" "$keep" && cp -f "$MSH_SRC" "$MSH"
        say "  using $MSH_SRC -> $(basename "$MSH") (previous one kept as $(basename "$keep"))"
    elif [ ! -f "$MSH" ]; then
        cp -f "$MSH_SRC" "$MSH"
        say "  using $MSH_SRC -> $(basename "$MSH")"
    else
        say "  using $MSH_SRC (identical to $(basename "$MSH"))"
    fi
fi
if [ -n "$MSH_SRC" ] && [ -z "$MSH" ]; then
    :   # Already recorded above.
elif [ "$RUN_CONNECT" != "1" ]; then
    say "  skipped by request (--no-connect)"
    record "connection test" SKIP "--no-connect"
elif [ ! -f "$MSH" ]; then
    say "  no $(basename "$MSH") next to the agent - nothing to connect to"
    record "connection test" SKIP "no $(basename "$MSH")"
else
    # The last MeshServer= line wins. The .msh files here set it twice, local first, then the real wss:// URL.
    SRV="$(grep -a '^MeshServer=' "$MSH" | tail -1 | cut -d '=' -f2- | tr -d '\r')"
    say "  MeshServer=$SRV"
    hostport="${SRV#*://}"; hostport="${hostport%%/*}"
    chost="${hostport%%:*}"; cport="${hostport##*:}"
    [ "$cport" = "$chost" ] && cport=443
    # Reachability pre-check. bash's /dev/tcp tries only the first address a name resolves to,
    # so a host with a link-local IPv6 record ahead of its IPv4 one looks refused while the agent,
    # which walks every address, connects fine. A failed probe is a hint, not a verdict.
    reachable=1
    case "$SRV" in
        ws://*|wss://*|http://*|https://*)
            if command -v nc >/dev/null 2>&1; then
                nc -z -w 5 "$chost" "$cport" >/dev/null 2>&1 || reachable=0
            else
                addrs="$(getent ahosts "$chost" 2>/dev/null | awk '{print $1}' | sort -u)"; [ -n "$addrs" ] || addrs="$chost"
                reachable=0
                for a in $addrs; do
                    case "$a" in *:*) a="[$a]";; esac
                    timeout 5 bash -c "exec 3<>/dev/tcp/$a/$cport" 2>/dev/null && { reachable=1; break; }
                done
            fi;;
    esac
    [ "$reachable" = "0" ] && say "  pre-check could not reach $chost:$cport (no listener, or a resolver order the probe can't follow) - letting the agent try anyway"
    {
        OUT="$TMPDIR_RUN/connect.log"
        # This is a ceiling, not a wait: the poll below stops the moment the core is seen running.
        # Under qemu a first connect (core download, SHA384 verify, module loads) took about 90 s,
        # and a 60 s limit was killing it mid-transfer.
        csec=15; [ -n "$QEMU" ] && csec=120
        [ -n "$CONNECT_TIMEOUT" ] && csec="$CONNECT_TIMEOUT"
        say "  running '$(basename "$BIN") connect' for up to ${csec}s (writes $(basename "$BIN").db/.log next to the agent)"
        # --showModuleNames=1 forces the db key from the command line. A key set in the .msh still
        # wins, since the .msh is imported after the command-line values are cached.
        { timeout -k 5 "$csec" ${RUNNER[@]+"${RUNNER[@]}"} "$BIN" connect --showModuleNames=1 > "$OUT" 2>&1; } 2>/dev/null &
        cpid=$!; CHILD_PIDS+=("$cpid")
        # 'Launching meshcore' is printed only when a core already in <binary>.db was re-verified
        # (agentcore.c ~3304). A first connect receives the core via MeshCommand_CoreModule and runs
        # it silently, so its 'require("MeshAgent")' is the marker in that case.
        for _i in $(seq 1 "$csec"); do
            grep -qE "Launching meshcore|ModuleLoader: MeshAgent$" "$OUT" 2>/dev/null && break
            kill -0 "$cpid" 2>/dev/null || break
            sleep 1
        done
        kill -TERM "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null
        emit "$OUT" 25
        cmiss=""
        # 'Launching meshcore' is the real end state: the server verified the core and the agent
        # started it. Authentication alone can succeed while meshcore still fails to run.
        for _m in "Control Channel Connection Established" "Connected." "Authentication Complete"; do
            grep -qF "$_m" "$OUT" 2>/dev/null || cmiss="$cmiss, missing '$_m'"
        done
        grep -qE "Launching meshcore|ModuleLoader: MeshAgent$" "$OUT" 2>/dev/null \
            || cmiss="$cmiss, meshcore never ran (no 'Launching meshcore' and no require of MeshAgent)"
        # A connect that authenticated but did not persist its identity would re-provision on
        # every start, so the node cert and the server it belongs to must both be in <binary>.db.
        DB="$BIN.db"
        if [ -f "$DB" ]; then
            for _k in SelfNodeCert MeshServer; do
                strings -a "$DB" 2>/dev/null | grep -q "$_k" || cmiss="$cmiss, '$_k' not persisted in $(basename "$DB")"
            done
        else cmiss="$cmiss, no $(basename "$DB") written"; fi
        if [ "$reachable" = "0" ] && ! grep -qF "Control Channel Connection Established" "$OUT" 2>/dev/null; then
            say "  no server answered on $chost:$cport - start the MeshCentral server to run this phase"
            record "connection test" SKIP "no server on $chost:$cport"
        elif [ -z "$cmiss" ]; then record "connection test" PASS "connected, authenticated, meshcore launched, identity persisted ($SRV)"
        else record "connection test" FAIL "${cmiss#, }"; fi
    }
fi

# --------------------------------------------------------------------------------------------
# valgrind phases
# --------------------------------------------------------------------------------------------
vg_report() {   # $1 is the valgrind logfile, $2 the phase name.
    local vg="$1" name="$2" definite indirect errors
    # No summary at all means valgrind never ran the program, which is a startup failure and not a
    # clean run. A 32-bit binary without libc6-dbg:i386 gives "a function redirection ... cannot be set up".
    if ! grep -q 'ERROR SUMMARY' "$vg" 2>/dev/null; then
        say "  valgrind produced no summary - it did not run the program:"
        grep -m 6 '^valgrind:' "$vg" 2>/dev/null | sed 's/^/    /' | tee -a "$LOGFILE"
        case "$BIN_DESC" in *Intel\ 80386*|*Intel\ i386*) say "    (32-bit x86 under valgrind needs the i386 debug libs: apt-get install libc6-dbg:i386)";; esac
        cat "$vg" >> "$LOGFILE" 2>/dev/null
        record "$name" SKIP "valgrind failed to start - the agent was not tested, see $LOGFILE"
        return
    fi
    definite="$(grep -o 'definitely lost: [0-9,]* bytes' "$vg" | tail -1)"
    indirect="$(grep -o 'indirectly lost: [0-9,]* bytes' "$vg" | tail -1)"
    errors="$(grep -o 'ERROR SUMMARY: [0-9,]* errors from [0-9,]* contexts' "$vg" | tail -1)"
    grep -q 'All heap blocks were freed' "$vg" && definite="no leaks are possible (all blocks freed)"
    say "  ${definite:-<no leak summary>}"
    [ -n "$indirect" ] && say "  $indirect"
    say "  ${errors:-<no error summary>}"
    cat "$vg" >> "$LOGFILE"
    # Fail only on definite leaks. The uninitialised-value errors are reported but not gating.
    if echo "${definite:-}" | grep -q 'definitely lost: [1-9]'; then record "$name" FAIL "${definite}"
    else record "$name" PASS "${errors:-}"; fi
}

VG_ARGS=(--tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect --num-callers=20 --error-limit=no)
# On macOS, libobjc class realization, dyld and libdispatch one-time init leak in every process
# (762 x 32 B under main on a 26.x run). Without these suppressions the leak gate means nothing.
[ "$(uname -s)" = Darwin ] && [ -f test/valgrind-macos.supp ] && VG_ARGS+=(--suppressions=test/valgrind-macos.supp)
[ -n "${VALGRIND_EXTRA:-}" ] && read -r -a VG_EXTRA <<< "$VALGRIND_EXTRA" && VG_ARGS+=("${VG_EXTRA[@]}")

if [ "$RUN_VALGRIND" = "1" ]; then
    # --- phase 6: valgrind over the core stress run ------------------------------------------
    head2 "[6/7] valgrind memcheck - core stress run ($DBGBIN)"
    OUT="$TMPDIR_RUN/vg-stress.log"; VG="$TMPDIR_RUN/vg-stress.valgrind"
    say "  (valgrind is ~20x slower - the stress watchdog is raised to match)"
    run_cmd $((120*VG_SCALE)) "$OUT" valgrind "${VG_ARGS[@]}" --log-file="$VG" \
            "$DBGBIN" test/stress-test.js --exclude=$KNOWN_EXCL --watchdog=$((60000*VG_SCALE)); RC=$?
    emit "$OUT" 15
    vg_report "$VG" "valgrind (stress)"
else
    head2 "[6/7] valgrind phase SKIPPED"
    say "  reason: ${VG_SKIP_REASON:-skipped by request (--quick)}"
    record "valgrind (stress)"   SKIP "${VG_SKIP_REASON:-}"
fi

# --- phase 8: AddressSanitizer over the core stress run ----------------------------------------
head2 "[7/7] AddressSanitizer - core stress run"
[ -z "$ASAN_BIN" ] && [ -x "${BIN}_asan" ] && ASAN_BIN="${BIN}_asan"
[ -z "$ASAN_BIN" ] && [ -x "$(dirname "$BIN")_asan/$(basename "$BIN")_asan" ] && ASAN_BIN="$(dirname "$BIN")_asan/$(basename "$BIN")_asan"
if [ -z "$ASAN_BIN" ]; then
    say "  no ASan build found - make one with: make linux ARCHID=<id> ASAN=1"
    record "asan (stress)" SKIP "no ${BIN##*/}_asan build"
elif [ ! -x "$ASAN_BIN" ]; then
    say "  $ASAN_BIN is not executable"
    record "asan (stress)" FAIL "$ASAN_BIN not executable"
elif ! grep -qa '__asan_' "$ASAN_BIN" 2>/dev/null; then
    say "  $ASAN_BIN has no ASan runtime in it - was it built with ASAN=1?"
    record "asan (stress)" FAIL "$ASAN_BIN is not an ASan build"
else
    OUT="$TMPDIR_RUN/asan.log"
    say "  using $ASAN_BIN"
    # halt_on_error=0 needs -fsanitize-recover=address, which the ASAN=1 build has. It keeps the
    # run going so one report does not hide the rest.
    ASAN_OPTIONS=halt_on_error=0:detect_leaks=1:print_legend=0 \
        run_cmd $((180*SCALE)) "$OUT" ${RUNNER[@]+"${RUNNER[@]}"} "$ASAN_BIN" test/stress-test.js \
            --exclude=$KNOWN_EXCL --watchdog=$((120000*SCALE))
    RC=$?
    emit "$OUT" 12
    ACOUNT="$(grep -c 'ERROR: AddressSanitizer' "$OUT" 2>/dev/null || true)"
    ATOTAL="$(grep -o 'TOTAL: .*' "$OUT" | tail -1)"
    if [ "${ACOUNT:-0}" -gt 0 ]; then
        say "  $ACOUNT AddressSanitizer report(s):"
        grep -A2 'ERROR: AddressSanitizer' "$OUT" | grep -E '^ *#[01] ' | sed 's/0x[0-9a-f]* in //;s/^ */    /' |
            sort -u | head -10 | tee -a "$LOGFILE"
        record "asan (stress)" FAIL "$ACOUNT report(s) - $ATOTAL"
    elif [ -z "$ATOTAL" ]; then
        record "asan (stress)" FAIL "$(rcdesc $RC) - the run did not finish"
    else
        record "asan (stress)" PASS "no ASan reports - $ATOTAL"
    fi
fi

# --------------------------------------------------------------------------------------------
# summary
# --------------------------------------------------------------------------------------------
endgroup    # The summary itself is never folded in CI.
say ""; say "=============================================================================="
say "SUMMARY"; say "=============================================================================="

if [ "$CI_MODE" = "1" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### MeshAgent test driver"
        echo ""
        echo "\`$(basename "$BIN")\` - $BIN_DESC"
        echo ""
        echo "runner: \`${QEMU:-native}\` on \`$HOST_ARCH\`"
        echo ""
        echo "| phase | result | notes |"
        echo "|---|---|---|"
    } >> "$GITHUB_STEP_SUMMARY"
fi

i=0
while [ $i -lt ${#PHASE_NAMES[@]} ]; do
    printf '  %-24s %-6s %s\n' "${PHASE_NAMES[$i]}" "${PHASE_RESULTS[$i]}" "${PHASE_NOTES[$i]}" | tee -a "$LOGFILE"
    if [ "$CI_MODE" = "1" ]; then
        case "${PHASE_RESULTS[$i]}" in
            FAIL)  echo "::error title=${PHASE_NAMES[$i]}::${PHASE_NOTES[$i]:-failed}";;
            KNOWN) echo "::warning title=${PHASE_NAMES[$i]}::${PHASE_NOTES[$i]:-known defect}";;
            SKIP)  echo "::notice title=${PHASE_NAMES[$i]}::skipped - ${PHASE_NOTES[$i]:-}";;
        esac
        [ -n "${GITHUB_STEP_SUMMARY:-}" ] && \
            echo "| ${PHASE_NAMES[$i]} | ${PHASE_RESULTS[$i]} | ${PHASE_NOTES[$i]//|/\\|} |" >> "$GITHUB_STEP_SUMMARY"
    fi
    i=$((i+1))
done
hr
if [ "$FAILED" -eq 0 ]; then say "RESULT: OK ($FAILED failing phases)"; else say "RESULT: FAILED ($FAILED failing phases)"; fi
say "full log: $LOGFILE"
if [ "$CI_MODE" = "1" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "" >> "$GITHUB_STEP_SUMMARY"
    echo "**RESULT: $( [ "$FAILED" -eq 0 ] && echo OK || echo "FAILED ($FAILED phases)" )**" >> "$GITHUB_STEP_SUMMARY"
fi
exit $(( FAILED > 0 ? 1 : 0 ))
