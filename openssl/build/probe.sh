#!/bin/bash
# Sourced by build.sh and verify, so the gate that decides what gets staged is the gate that
# audits what is committed. Everything is read from the archive itself with strings and a small
# python archive walker, so no target binutils are needed on the host. See openssl/build/README.md.

# Symbols that prove a Configure option took effect. "absent" options remove the symbol,
# "present" ones add it. Read straight from the flags file plus T_EXTRA, so the list needs
# no edit when a flag changes, only when a new flag has no witness yet.
WITNESS="no-engine=ENGINE_new no-cms=CMS_sign no-comp=COMP_CTX_new no-ocsp=OCSP_request_add0_id
no-bf=BF_encrypt no-md4=MD4_Init no-camellia=Camellia_set_key no-cast=CAST_set_key
no-idea=IDEA_set_encrypt_key no-rc5=RC5_32_set_key no-seed=SEED_set_key no-mdc2=MDC2_Init
no-rmd160=RIPEMD160_Init no-md2=MD2_Init no-srp=SRP_Calc_A no-psk=SSL_CTX_set_psk_client_callback
enable-ec_nistp_64_gcc_128=+EC_GFp_nistp256_method"

# Fills P_* from one libcrypto archive: version, platform and compiler strings, and the
# container facts from archive-info.py. Returns 1 when the file is not an archive.
probe_archive() {
    local f="$1" info
    P_VERSION=$(strings "$f" | grep -oE '^OpenSSL [0-9]+\.[0-9]+\.[0-9]+[a-z]?' | sort -u | head -1)
    # grep -o rather than an anchored sed, because a printable byte can precede the string.
    P_PLATFORM=$(strings "$f" | grep -oE 'platform: [^ ]+' | head -1 | cut -c11-)
    P_COMPILER=$(strings "$f" | grep -oE 'compiler: .*' | head -1 | cut -c11-)
    P_GLIBC=$(strings "$f" | grep -cE "^($GLIBC_ONLY_RE)$")
    P_UCONTEXT=$(strings "$f" | grep -cE "$UCONTEXT_RE")
    info=$(python3 "$BR_SCRIPTS/archive-info.py" "$f" 2>/dev/null) || return 1
    P_FORMAT=${info#*format=}; P_FORMAT=${P_FORMAT%% *}
    P_CLASS=${info#*class=};   P_CLASS=${P_CLASS%% *}
    P_MACHINE=${info#*machine=}; P_MACHINE=${P_MACHINE%% *}
    P_MEMBERS=${info#*members=}
}

# What the Configure target implies about the object files.
conf_class()   { case "$1" in *64*|BSD-x86_64|darwin64*) echo 64 ;; *) echo 32 ;; esac; }
conf_machine() {
    case "$1" in
        linux-x86_64|BSD-x86_64|darwin64-x86_64-cc|VC-WIN64A) echo x86_64 ;;
        linux-x86|VC-WIN32) echo i386 ;;
        linux-aarch64|VC-WIN64-ARM) echo arm64 aarch64 ;;
        darwin64-arm64-cc) echo arm64 ;;
        linux-armv4) echo arm ;;
        linux-mips32) echo mips ;;
        linux64-riscv64) echo riscv ;;
        *) echo any ;;
    esac
}

# Runs every gate for target $1 whose archives sit in prefix $2. Prints one REJECT line per
# failure and returns nonzero if there was any. br_target "$1" must already have been called.
gate_target() {
    local t="$1" prefix="$2" ver lib sym want rc=0 opt tok conf pc
    ver=$(basename "$(dirname "$prefix")")
    case "$T_LIBC" in msvc) lib="$prefix/lib/libcrypto.lib" ;; *) lib="$prefix/lib/libcrypto.a" ;; esac
    # A header written by nmake on Windows has CRLF endings, which git normalises to LF on commit
    # but which would make every anchored grep here miss before that.
    conf_has() { tr -d '\r' < "$conf" | grep -qE "$1"; }
    conf="$prefix/include/openssl/opensslconf.h"
    reject() { echo "  REJECT: $t: $*" >&2; rc=1; }

    [ -f "$lib" ] || { reject "no $(basename "$lib") in $prefix/lib"; return 1; }
    probe_archive "$lib" || { reject "not a recognised archive"; return 1; }

    [ "$P_VERSION" = "OpenSSL $ver" ] || reject "archive says '$P_VERSION', prefix is openssl/$ver"
    [ "$P_PLATFORM" = "$T_CONF" ] || reject "built for Configure target '$P_PLATFORM', targets.sh says $T_CONF"
    [ "$P_CLASS" = "$(conf_class "$T_CONF")" ] || reject "objects are $P_CLASS-bit, $T_CONF is $(conf_class "$T_CONF")-bit"
    want=$(conf_machine "$T_CONF")
    case " $want " in *" any "*|*" $P_MACHINE "*) ;; *) reject "objects are $P_MACHINE, $T_CONF wants $want" ;; esac

    # The compiler line records the recipe: the compiler, its -m flags, -Os and the asm defines.
    if [ -n "$P_COMPILER" ]; then
        local cc="${T_CC%% *}"
        [ -n "$cc" ] && case "$P_COMPILER" in *"$(basename "$cc")"*) ;; *) reject "compiled by '${P_COMPILER%% *}', targets.sh says $cc" ;; esac
        for tok in ${T_CC#* }; do
            case "$tok" in -m*) case " $P_COMPILER " in *" $tok "*) ;; *) reject "compiler line lacks $tok" ;; esac ;; esac
        done
        case " $T_EXTRA " in *" -Os "*) case " $P_COMPILER " in *" -Os "*) ;; *) reject "built without -Os, T_EXTRA asks for it" ;; esac ;;
                              *) case " $P_COMPILER " in *" -Os "*) reject "built with -Os, T_EXTRA does not ask for it" ;; esac ;; esac
        case " $T_FLAGS " in *" -no-asm "*|*" no-asm "*) case "$P_COMPILER" in *_ASM*) reject "asm modules present, recipe says -no-asm" ;; esac ;;
            *) case "$T_CONF" in linux-generic32|linux-generic64) ;; *) case "$P_COMPILER" in *_ASM*) ;; *) reject "no asm modules, recipe enables asm" ;; esac ;; esac ;; esac
        # MSVC objects are compiled /Zl, so the CRT choice is the agent's. /MD would still be wrong,
        # and --debug shows as /Od.
        if [ "$T_LIBC" = msvc ]; then
            case " $P_COMPILER " in *" /MD"*) reject "built /MD, the agent is /MT" ;; esac
            case " $T_EXTRA " in *" --debug "*) want=/Od ;; *) want=/O[12] ;; esac
            echo " $P_COMPILER " | grep -qE " $want " || reject "compiler line lacks $want for this configuration"
        fi
        # A musl toolchain names itself. glibc and uClibc do not, so those rely on the symbol gates.
        [ "$T_LIBC" = musl ] && case "${P_COMPILER%% *}" in *musl*) ;; *) reject "compiled by '${P_COMPILER%% *}', which is not a musl toolchain" ;; esac
    else
        reject "no 'compiler:' string in the archive"
    fi

    # Every option in the flags line must have left its mark, both in the symbols and in the header.
    for opt in $T_FLAGS $T_EXTRA; do
        for tok in $WITNESS; do
            [ "${tok%%=*}" = "$opt" ] || continue
            sym=${tok#*=}
            case "$sym" in
                +*) strings "$lib" | grep -qE "^_?${sym#+}$" || reject "$opt did not take: ${sym#+} is missing" ;;
                *)  strings "$lib" | grep -qE "^_?$sym$" && reject "$opt did not take: $sym is present" ;;
            esac
        done
        # shared, zlib and ssl are build-time only and leave no OPENSSL_NO_ macro behind.
        case "$opt" in
            no-shared|no-zlib|no-zlib-dynamic|no-ssl) ;;
            no-*|-no-*) sym=$(echo "OPENSSL_NO_${opt#*no-}" | tr 'a-z-' 'A-Z_')
                        [ -f "$conf" ] && ! conf_has "^# *define $sym\$" && reject "opensslconf.h lacks $sym for $opt" ;;
            enable-*)   sym=$(echo "OPENSSL_NO_${opt#enable-}" | tr 'a-z-' 'A-Z_')
                        [ -f "$conf" ] && conf_has "^# *define $sym\$" && reject "opensslconf.h defines $sym although $opt is set" ;;
        esac
    done

    # The generated header must describe these objects, or BN_ULONG and friends silently change size.
    # linux64-sparcv9 is a deliberate upstream exception: Configurations/10-main.conf overrides its
    # bn_ops to BN_LLONG, keeping BN_ULONG 32-bit even though the objects themselves are 64-bit ELF.
    if [ -f "$conf" ]; then
        if [ "$t" != linux-sparc64-glibc ]; then
            case "$P_CLASS" in
                32) conf_has '^# *define THIRTY_TWO_BIT$' || reject "opensslconf.h is not the 32-bit variant" ;;
                64) conf_has '^# *define SIXTY_FOUR_BIT(_LONG)?$' || reject "opensslconf.h is not the 64-bit variant" ;;
            esac
        fi
    else
        reject "no include/openssl/opensslconf.h in the prefix"
    fi
    if [ "$T_LIBC" != msvc ]; then
        pc="$prefix/lib/pkgconfig/libcrypto.pc"
        [ -f "$pc" ] || reject "no lib/pkgconfig/libcrypto.pc in the prefix"
        [ -f "$pc" ] && ! grep -q "^Version: $ver\$" "$pc" && reject "libcrypto.pc Version is not $ver"
    fi

    # libc gates. A glibc-only symbol means a musl or uClibc agent links but will not start.
    case "$T_LIBC" in musl|uclibc) [ "$P_GLIBC" -eq 0 ] || reject "references $P_GLIBC glibc-only symbol(s) in a $T_LIBC target" ;; esac
    # musl implements ucontext on no architecture, so the agent link would fail outright.
    [ "$T_LIBC" = musl ] && [ "$P_UCONTEXT" -ne 0 ] && reject "references $P_UCONTEXT ucontext symbol(s), which musl lacks"
    return $rc
}
