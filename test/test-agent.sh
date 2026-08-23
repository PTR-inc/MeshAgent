#!/usr/bin/env bash
#
# MeshAgent combined test driver.
#
# Runs, in order, against one agent binary:
#   1. -info sanity banner (version / ARCHID / OpenSSL)
#   2. test/stress-test.js, core sections            -> must pass
#   3. test/stress-test.js, TLS section only         -> known crash, see meshagent-todo.md #1
#   4. test/self-test.js --LocalTests                -> must pass
#   5. connection test against <binary>.msh          -> connect + authenticate to the server
#   6. valgrind memcheck over the core stress run    -> leak report
#   7. valgrind memcheck over test/leaktest.js       -> leak report (scripted over stdin)
#   8. AddressSanitizer over the core stress run     -> needs an ASAN=1 build, see --asan
#
# Everything is written to the console and to a logfile at the same time.
#
# Usage:  test/test-agent.sh [options]
#   -b, --binary PATH     agent binary to test (default: newest ./meshagent_* in the repo root)
#   -d, --debug PATH      unstripped binary for valgrind (default: DEBUG_<binary>, if present)
#   -l, --log PATH        logfile (default: test/logs/test-agent-<host-or-arch>-<timestamp>.log)
#       --qemu "CMD"      run the agent under qemu, e.g. --qemu "qemu-riscv64 -cpu thead-c906".
#                         Auto-detected from the binary's architecture when not given.
#       --no-qemu         never use qemu (fails fast on a foreign-arch binary instead)
#   -q, --quick           skip the valgrind phases
#       --no-valgrind     same as --quick
#       --no-connect      skip the .msh connection test
#       --asan PATH       ASan-instrumented agent for phase 8 (default: <binary>_asan if present).
#                         Build one with:  make linux ARCHID=<id> ASAN=1
#   -y, --yes             non-interactive: install missing tools without asking
#       --ci              GitHub Actions mode: ::group:: folding, ::error::/::warning::
#                         annotations, a job-summary table in $GITHUB_STEP_SUMMARY, never
#                         prompts, never truncates output. Implies --yes.
#       --strict          the known TLS crash counts as a failure too
#   -h, --help            this text
#
# Notes: phase output is captured to a file, not piped (leaktest's children hold stdout open and
# a pipe never sees EOF); the script cd's to the repo root itself (stress-test.js needs it); and
# valgrind is skipped under qemu, which it cannot instrument.
#

set -u

# --------------------------------------------------------------------------------------------
# defaults / arg parsing
# --------------------------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

BIN=""
DBGBIN=""
LOGFILE=""
QEMU=""
QEMU_AUTO=1
RUN_VALGRIND=1
ASSUME_YES=0
STRICT=0
CI_MODE=0
RUN_CONNECT=1
ASAN_BIN=""

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--binary)     BIN="${2:-}"; shift 2;;
        -d|--debug)      DBGBIN="${2:-}"; shift 2;;
        -l|--log)        LOGFILE="${2:-}"; shift 2;;
        --qemu)          QEMU="${2:-}"; QEMU_AUTO=0; shift 2;;
        --no-qemu)       QEMU=""; QEMU_AUTO=0; shift;;
        -q|--quick|--no-valgrind) RUN_VALGRIND=0; shift;;
        --no-connect)    RUN_CONNECT=0; shift;;
        --asan)          ASAN_BIN="${2:-}"; shift 2;;
        -y|--yes)        ASSUME_YES=1; shift;;
        --ci)            CI_MODE=1; ASSUME_YES=1; shift;;
        --strict)        STRICT=1; shift;;
        -h|--help)       sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2;;
    esac
done

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
pkg_install_cmd() {   # $1 = package name -> prints the install command for this distro
    if   command -v apt-get >/dev/null 2>&1; then echo "apt-get install -y $1"
    elif command -v dnf     >/dev/null 2>&1; then echo "dnf install -y $1"
    elif command -v yum     >/dev/null 2>&1; then echo "yum install -y $1"
    elif command -v zypper  >/dev/null 2>&1; then echo "zypper install -y $1"
    elif command -v pacman  >/dev/null 2>&1; then echo "pacman -S --noconfirm $1"
    elif command -v apk     >/dev/null 2>&1; then echo "apk add $1"
    else echo ""; fi
}

# ensure_tool <command> <package> -> 0 if available (possibly after installing), 1 if not
ensure_tool() {
    local tool="$1" pkg="$2" cmd ans sudo=""
    command -v "$tool" >/dev/null 2>&1 && return 0

    cmd="$(pkg_install_cmd "$pkg")"
    say "MISSING TOOL: '$tool' is not installed."
    if [ -z "$cmd" ]; then
        say "  No known package manager found - install '$pkg' manually and re-run."
        return 1
    fi
    [ "$(id -u)" != "0" ] && sudo="sudo "
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
    # newest non-DEBUG meshagent_* executable in the repo root
    # *_asan is a special-purpose build - phase 8 finds it on its own, it is not the default target.
    BIN="$(find . -maxdepth 1 -type f -name 'meshagent_*' ! -name '*.db' ! -name '*.msh' ! -name '*.log' \
           ! -name '*_asan' -perm -u+x -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
fi
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "no agent binary found - pass one with --binary" >&2; exit 1; }
[ -z "$DBGBIN" ] && DBGBIN="$(dirname "$BIN")/DEBUG_$(basename "$BIN")"
[ -x "$DBGBIN" ] || DBGBIN="$BIN"

BIN_DESC="$(file -b "$BIN" 2>/dev/null)"
HOST_ARCH="$(uname -m)"

# qemu_for <file(1) description> -> qemu-user binary name, or "" when it runs natively
qemu_for() {
    case "$1" in
        *x86-64*)                     [ "$HOST_ARCH" = "x86_64" ] && echo "" || echo "qemu-x86_64";;
        *Intel\ 80386*|*Intel\ i386*) [ "$HOST_ARCH" = "x86_64" ] || [ "$HOST_ARCH" = "i686" ] && echo "" || echo "qemu-i386";;
        *aarch64*|*ARM\ aarch64*)     [ "$HOST_ARCH" = "aarch64" ] && echo "" || echo "qemu-aarch64";;
        *ARM*)                        [ "${HOST_ARCH#arm}" != "$HOST_ARCH" ] && echo "" || echo "qemu-arm";;
        *UCB\ RISC-V*)                [ "$HOST_ARCH" = "riscv64" ] && echo "" || echo "qemu-riscv64";;
        *LSB*MIPS*|*mipsel*)          [ "$HOST_ARCH" = "mips64el" ] || [ "$HOST_ARCH" = "mipsel" ] && echo "" || echo "qemu-mipsel";;
        *MSB*MIPS*|*MIPS*)            [ "$HOST_ARCH" = "mips" ] && echo "" || echo "qemu-mips";;
        *PowerPC*64*)                 echo "qemu-ppc64";;
        *PowerPC*)                    echo "qemu-ppc";;
        *) echo "";;
    esac
}

# qemu-user needs the target's dynamic loader; Debian's cross toolchains put it under /usr/<triple>.
qemu_sysroot_for() {
    local candidates=""
    case "$1" in
        qemu-riscv64) candidates="/usr/riscv64-linux-gnu";;
        qemu-aarch64) candidates="/usr/aarch64-linux-gnu";;
        qemu-arm)     candidates="/usr/arm-linux-gnueabihf /usr/arm-linux-gnueabi";;
        qemu-mipsel)  candidates="/usr/mipsel-linux-gnu";;
        qemu-mips)    candidates="/usr/mips-linux-gnu";;
        qemu-ppc*)    candidates="/usr/powerpc-linux-gnu";;
    esac
    for c in $candidates; do [ -d "$c" ] && { echo "$c"; return; }; done
    echo ""
}

# A vendor-extension build SIGILLs on qemu's default CPU model - ARCHID=45 (Allwinner D1 /
# T-Head C906) is the case in this tree. The ELF's RISC-V arch attribute names the extensions,
# so pick the CPU model from that rather than from the ARCHID.
qemu_cpu_hint() {   # $1 = binary, $2 = qemu binary name -> "-cpu <model>" or ""
    local a
    case "$2" in
        qemu-riscv64)
            a="$(readelf -A "$1" 2>/dev/null | grep -m1 Tag_RISCV_arch)"
            case "$a" in *xthead*|*v0p7*) echo "-cpu thead-c906";; *) echo "";; esac;;
        *) echo "";;
    esac
}

# Fallbacks tried, in order, if the binary dies with SIGILL on whatever model was picked first.
qemu_cpu_candidates() {   # $1 = qemu binary name -> '|'-separated list
    case "$1" in
        qemu-riscv64)          echo "-cpu thead-c906|-cpu max|-cpu rv64";;
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
            QEMU_SYSROOT="$(qemu_sysroot_for "$NEEDED")"
            QEMU_CPU="$(qemu_cpu_hint "$BIN" "$NEEDED")"
            [ -n "$QEMU_CPU" ] && QEMU_NOTE="$QEMU_CPU chosen from the ELF arch attribute (vendor ISA extensions)"
        else
            say "Cannot run a $BIN_DESC binary on $HOST_ARCH without qemu - aborting."
            exit 1
        fi
    fi
fi

# runner prefix as an array (empty when native)
build_runner

# timeout scaling: emulation is slow, valgrind is slower
SCALE=1
[ -n "$QEMU" ] && SCALE=10

# Probe the emulated binary once with -info. SIGILL (132) means the CPU model is wrong, not that
# the agent is broken - walk the candidate models and adopt the first that runs.
if [ -n "$QEMU_BIN" ]; then
    probe="$TMPDIR_RUN/probe.log"
    { timeout -k 5 $((20*SCALE)) "${RUNNER[@]}" "$BIN" -info > "$probe" 2>&1; } 2>/dev/null
    if [ $? -eq 132 ]; then
        found=0
        while IFS= read -r cand; do
            [ "$cand" = "$QEMU_CPU" ] && continue
            QEMU_CPU="$cand"; build_runner
            { timeout -k 5 $((20*SCALE)) "${RUNNER[@]}" "$BIN" -info > "$probe" 2>&1; } 2>/dev/null
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

# 128+n exit codes from `timeout`/the shell are fatal signals - name them, "exit 132" alone
# reads like an application error when it actually means SIGILL (usually a wrong qemu -cpu).
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

# run_cmd <timeout-sec> <outfile> <cmd...>  -> returns the command's exit code
run_cmd() {
    local t="$1" out="$2"; shift 2
    # The braces + 2>/dev/null swallow bash's own "Illegal instruction/Segmentation fault" job
    # message (GNU timeout re-raises the child's signal on itself, so the shell reports it) while
    # keeping the exit code and the command's own output, which is already inside "$out".
    { timeout -k 5 "$t" "$@" > "$out" 2>&1; } 2>/dev/null
    return $?
}

emit() {   # copy a phase's captured output into console+log
    local f="$1" maxlines="${2:-0}"
    [ "$CI_MODE" = "1" ] && maxlines=0        # CI folds the group instead of truncating
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
say "runner      : ${QEMU:-native}"
[ -n "$QEMU_NOTE" ] && say "              ($QEMU_NOTE)"
say "valgrind    : $( [ "$RUN_VALGRIND" = "1" ] && valgrind --version || echo "disabled (${VG_SKIP_REASON:-requested})" )"
say "logfile     : $LOGFILE"

# --- phase 1: -info -------------------------------------------------------------------------
head2 "[1/8] agent -info"
OUT="$TMPDIR_RUN/info.log"
run_cmd $((20*SCALE)) "$OUT" "${RUNNER[@]}" "$BIN" -info; RC=$?
emit "$OUT" 20
if [ $RC -eq 0 ]; then record "agent -info" PASS
else
    # Only reachable with an explicit --qemu; the auto path probes and retries CPU models itself.
    if [ $RC -eq 132 ] && [ -n "$QEMU" ]; then
        say "  SIGILL under qemu almost always means the wrong CPU model, not a broken agent."
        say "  Try: --qemu \"${RUNNER[0]} -cpu <model>${QEMU_SYSROOT:+ -L $QEMU_SYSROOT}\"  (ARCHID=45 needs -cpu thead-c906)"
    fi
    record "agent -info" FAIL "$(rcdesc $RC)"
fi

# --- phase 2: stress test, core sections ----------------------------------------------------
head2 "[2/8] stress test - core sections (JS/duktape/datastore/openssl/io)"
OUT="$TMPDIR_RUN/stress-core.log"
run_cmd $((60*SCALE)) "$OUT" "${RUNNER[@]}" "$BIN" test/stress-test.js \
        --exclude=06-tls --watchdog=$((10000*SCALE)); RC=$?
emit "$OUT"
TOTAL_LINE="$(grep -o 'TOTAL: .*' "$OUT" | tail -1)"
# Trust the TOTAL line over the exit code - a failing exit status does not always survive.
FAILED_CHECKS="$(printf '%s' "$TOTAL_LINE" | sed -n 's/.*passed, \([0-9]*\) failed.*/\1/p')"
if [ $RC -eq 0 ] && [ "${FAILED_CHECKS:-1}" = "0" ]; then record "stress (core)" PASS "$TOTAL_LINE"
elif [ -z "$TOTAL_LINE" ]; then record "stress (core)" FAIL "$(rcdesc $RC) - no TOTAL line, the run did not finish"
else record "stress (core)" FAIL "$(rcdesc $RC) $TOTAL_LINE"; fi

# --- phase 3: stress test, TLS section only -------------------------------------------------
head2 "[3/8] stress test - TLS section only (known defect, meshagent-todo.md #1)"
OUT="$TMPDIR_RUN/stress-tls.log"
run_cmd $((60*SCALE)) "$OUT" "${RUNNER[@]}" "$BIN" test/stress-test.js \
        --exclude=01-,02-,03-,04-,05- --watchdog=$((20000*SCALE)); RC=$?
emit "$OUT"
case $RC in
    0)   record "stress (TLS)" PASS "the #1 reconnect-after-end() crash did NOT reproduce";;
    254|139|134)
         if [ "$STRICT" = "1" ]; then record "stress (TLS)" FAIL "$(rcdesc $RC) - known crash, meshagent-todo.md #1"
         else record "stress (TLS)" KNOWN "$(rcdesc $RC) - reconnect-after-end() crash, meshagent-todo.md #1"; fi;;
    *)   record "stress (TLS)" FAIL "$(rcdesc $RC) (unexpected - not the known crash signature)";;
esac

# --- phase 4: self-test --LocalTests ---------------------------------------------------------
head2 "[4/8] self-test.js --LocalTests"
OUT="$TMPDIR_RUN/selftest.log"
run_cmd $((90*SCALE)) "$OUT" "${RUNNER[@]}" "$BIN" test/self-test.js --LocalTests; RC=$?
emit "$OUT" 40
BADCOUNT="$(grep -c -i '\[FAILED\]\|\[FAIL\]' "$OUT" 2>/dev/null || true)"
# self-test.js:141 exits 0 without running anything when not root - that is not a pass.
if grep -q 'requires elevated permissions' "$OUT" 2>/dev/null; then
    say "  self-test.js refused to run: it needs root"
    record "self-test --LocalTests" SKIP "needs root (re-run with sudo)"
elif [ $RC -eq 0 ] && [ "${BADCOUNT:-0}" = "0" ] && grep -q '\[OK\]' "$OUT" 2>/dev/null; then
    record "self-test --LocalTests" PASS
elif [ $RC -eq 0 ] && [ "${BADCOUNT:-0}" = "0" ]; then
    record "self-test --LocalTests" FAIL "exited 0 but ran no checks"
else record "self-test --LocalTests" FAIL "$(rcdesc $RC), ${BADCOUNT:-0} failed check(s)"; fi

# --- phase 5: connection test against the server named in <binary>.msh ------------------------
head2 "[5/8] connection test ($(basename "$BIN").msh)"
MSH="$BIN.msh"
if [ "$RUN_CONNECT" != "1" ]; then
    say "  skipped by request (--no-connect)"
    record "connection test" SKIP "--no-connect"
elif [ ! -f "$MSH" ]; then
    say "  no $(basename "$MSH") next to the agent - nothing to connect to"
    record "connection test" SKIP "no $(basename "$MSH")"
else
    # Last MeshServer= wins: the .msh files here set it twice (local, then the real wss:// URL).
    SRV="$(grep -a '^MeshServer=' "$MSH" | tail -1 | cut -d '=' -f2- | tr -d '\r')"
    say "  MeshServer=$SRV"
    hostport="${SRV#*://}"; hostport="${hostport%%/*}"
    chost="${hostport%%:*}"; cport="${hostport##*:}"
    [ "$cport" = "$chost" ] && cport=443
    reachable=1
    case "$SRV" in
        ws://*|wss://*|http://*|https://*)
            timeout 5 bash -c "exec 3<>/dev/tcp/$chost/$cport" 2>/dev/null || reachable=0;;
    esac
    if [ "$reachable" = "0" ]; then
        say "  nothing listening on $chost:$cport - start the MeshCentral server to run this phase"
        record "connection test" SKIP "no server on $chost:$cport"
    else
        OUT="$TMPDIR_RUN/connect.log"
        csec=15; [ -n "$QEMU" ] && csec=60
        say "  running '$(basename "$BIN") connect' for up to ${csec}s (writes $(basename "$BIN").db/.log next to the agent)"
        # --showModuleNames=1 forces the db key from the command line; a key set in the .msh still
        # wins, since the .msh is imported after the command-line values are cached.
        { timeout -k 5 "$csec" "${RUNNER[@]}" "$BIN" connect --showModuleNames=1 > "$OUT" 2>&1; } 2>/dev/null &
        cpid=$!; CHILD_PIDS+=("$cpid")
        for _i in $(seq 1 "$csec"); do
            grep -qF "Authentication Complete" "$OUT" 2>/dev/null && break
            kill -0 "$cpid" 2>/dev/null || break
            sleep 1
        done
        kill -TERM "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null
        emit "$OUT" 25
        cmiss=""
        for _m in "Control Channel Connection Established" "Connected." "Authentication Complete"; do
            grep -qF "$_m" "$OUT" 2>/dev/null || cmiss="$cmiss, missing '$_m'"
        done
        if [ -z "$cmiss" ]; then record "connection test" PASS "connected and authenticated to $SRV"
        else record "connection test" FAIL "${cmiss#, }"; fi
    fi
fi

# --------------------------------------------------------------------------------------------
# valgrind phases
# --------------------------------------------------------------------------------------------
vg_report() {   # $1 = valgrind logfile, $2 = phase name
    local vg="$1" name="$2" definite indirect errors
    # No summary at all means valgrind never ran the program (a startup failure, not a clean run) -
    # e.g. a 32-bit binary without libc6-dbg:i386 gives "a function redirection ... cannot be set up".
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
    # fail only on definite leaks; the uninitialised-value errors are reported, not gating
    if echo "${definite:-}" | grep -q 'definitely lost: [1-9]'; then record "$name" FAIL "${definite}"
    else record "$name" PASS "${errors:-}"; fi
}

VG_ARGS=(--tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect --num-callers=20 --error-limit=no)
[ -n "${VALGRIND_EXTRA:-}" ] && read -r -a VG_EXTRA <<< "$VALGRIND_EXTRA" && VG_ARGS+=("${VG_EXTRA[@]}")

if [ "$RUN_VALGRIND" = "1" ]; then
    # --- phase 5: valgrind over the core stress run ------------------------------------------
    head2 "[6/8] valgrind memcheck - core stress run ($DBGBIN)"
    OUT="$TMPDIR_RUN/vg-stress.log"; VG="$TMPDIR_RUN/vg-stress.valgrind"
    say "  (valgrind is ~20x slower - the stress watchdog is raised to match)"
    run_cmd $((60*VG_SCALE)) "$OUT" valgrind "${VG_ARGS[@]}" --log-file="$VG" \
            "$DBGBIN" test/stress-test.js --exclude=06-tls --watchdog=$((10000*VG_SCALE)); RC=$?
    emit "$OUT" 15
    vg_report "$VG" "valgrind (stress)"

    # --- phase 6: valgrind over leaktest.js --------------------------------------------------
    head2 "[7/8] valgrind memcheck - leaktest.js (scripted over stdin)"
    OUT="$TMPDIR_RUN/vg-leak.log"; VG="$TMPDIR_RUN/vg-leak.valgrind"
    # 'client' is deliberately NOT driven: leaktest.js:319 calls _debug(), which on POSIX is an
    # unconditional raise(SIGTRAP) (Windows guards it with IsDebuggerPresent()), killing the run.
    { { for c in final server start end start end wss exit; do printf '%s\n' "$c"; sleep 3; done; sleep 5; } \
        | timeout -k 5 $((120*VG_SCALE)) valgrind "${VG_ARGS[@]}" --log-file="$VG" \
          "$DBGBIN" test/leaktest.js > "$OUT" 2>&1; } 2>/dev/null
    RC=$?
    emit "$OUT" 15
    vg_report "$VG" "valgrind (leaktest)"
else
    head2 "[6/8] + [7/8] valgrind phases SKIPPED"
    say "  reason: ${VG_SKIP_REASON:-skipped by request (--quick)}"
    record "valgrind (stress)"   SKIP "${VG_SKIP_REASON:-}"
    record "valgrind (leaktest)" SKIP "${VG_SKIP_REASON:-}"
fi

# --- phase 8: AddressSanitizer over the core stress run ----------------------------------------
head2 "[8/8] AddressSanitizer - core stress run"
[ -z "$ASAN_BIN" ] && [ -x "${BIN}_asan" ] && ASAN_BIN="${BIN}_asan"
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
    # halt_on_error=0 needs -fsanitize-recover=address (the ASAN=1 build has it) and keeps the run
    # going so one report does not hide the rest.
    ASAN_OPTIONS=halt_on_error=0:detect_leaks=1:print_legend=0 \
        run_cmd $((120*SCALE)) "$OUT" "${RUNNER[@]}" "$ASAN_BIN" test/stress-test.js \
            --exclude=06-tls --watchdog=$((60000*SCALE))
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
endgroup    # the summary itself is never folded in CI
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
