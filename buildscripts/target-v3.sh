#!/bin/bash
# Reads targets-v3.conf and derives every build parameter of one ARCHID. Sourced by the other
# buildscripts for the tgt_* functions, or run directly:
#   buildscripts/target-v3.sh list                 one line per ARCHID
#   buildscripts/target-v3.sh ids                  the ARCHIDs, space separated
#   buildscripts/target-v3.sh show <archid>        every field, one per line
#   buildscripts/target-v3.sh make <archid>        the same as make assignments, for makefile.v3 to include
#   buildscripts/target-v3.sh field <archid> <F>   one field, e.g. field 7 OSSL
# The pins (BUILDROOT, ZIG_VERSION, OSSLVER, the SDK path) come from env-v3.sh.

. "$(dirname "${BASH_SOURCE[0]}")/env-v3.sh"

tgt_ids() { sed -n 's/^archid=\([0-9]*\) .*/\1/p' "$TGT_CONF" | sort -n | tr '\n' ' '; echo; }

# Loads the row of $1 into T_* with the column defaults applied.
tgt_load() {
    local row; row=$(grep -E "^archid=$1 " "$TGT_CONF") || { echo "target.sh: no ARCHID $1 in $TGT_CONF" >&2; return 1; }
    T_ARCHID= T_NAME= T_OS= T_OSVER= T_ARCH= T_CPU= T_ABI= T_LIBC= T_LIBCVER= T_LINK=dyn T_KVM=0 T_LMS=0 T_OPT=O2
    T_SERVER= T_ZIG="$ZIG_VERSION" T_CC= T_LD= T_MACOSCC= T_CFLAGS=
    local kv k v
    eval "set -- $row"
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        case "$k" in
            archid) T_ARCHID=$v ;; name) T_NAME=$v ;; os) T_OS=$v ;; osver) T_OSVER=$v ;; arch) T_ARCH=$v ;;
            cpu) T_CPU=$v ;; abi) T_ABI=$v ;; libc) T_LIBC=$v ;; libcver) T_LIBCVER=$v ;; link) T_LINK=$v ;;
            kvm) T_KVM=$v ;; lms) T_LMS=$v ;; opt) T_OPT=$v ;; server) T_SERVER=$v ;; zig) T_ZIG=$v ;;
            cc) T_CC=$v ;; cflags) T_CFLAGS=$v ;;
            *) echo "target.sh: ARCHID $1: unknown column '$k'" >&2; return 1 ;;
        esac
    done
    [ -n "$T_SERVER" ] || T_SERVER=$T_ARCHID
    case "$T_OS" in freebsd|openbsd|netbsd) T_LIBC=bsd ;; macos) T_LIBC=macos ;; esac
    tgt_derive
}

# Everything below is computed from the row, nothing is stated twice.
tgt_derive() {
    T_ZIGBIN="$BUILDROOT/toolchains/zig-$T_ZIG/zig"
    T_SYSROOT=; T_SDK=; T_TUNE=; T_ZIGLIBC=
    # The triple decides the compiler, the libc and the glibc floor at once.
    case "$T_OS" in
        linux)
            local env
            case "$T_LIBC" in
                glibc) env="gnu"; case "$T_ARCH" in arm) env="gnu$T_ABI" ;; esac; [ -n "$T_LIBCVER" ] && env="$env.$T_LIBCVER" ;;
                musl)  env="musl"; case "$T_ARCH" in arm|mips|mipsel) env="musl$T_ABI" ;; esac ;;
            esac
            T_TRIPLE="$T_ARCH-linux-$env"
            case "$T_ARCH" in riscv*) T_TUNE="-mabi=$T_ABI" ;; esac ;;
        freebsd|netbsd)
            T_TRIPLE="$T_ARCH-$T_OS-none"
            T_SYSROOT="$BUILDROOT/sysroots/$T_OS-$T_OSVER" ;;
        openbsd)
            T_TRIPLE="$T_ARCH-unknown-$T_OS$T_OSVER"
            T_SYSROOT="$BUILDROOT/sysroots/$T_OS-$T_OSVER" ;;
        macos)
            T_TRIPLE="$T_ARCH-macos.$T_OSVER"
            T_SDK="$MACOS_SDK" ;;
    esac
    [ -n "$T_CPU" ] && T_TUNE="-mcpu=$T_CPU${T_TUNE:+ $T_TUNE}"

    # The OpenSSL prefix name, <os>-<arch key>-<libc>. The arch key folds cpu and abi in because
    # they change the archive's instruction set, which is what decides link compatibility.
    local key="$T_ARCH"
    case "$T_ARCH:$T_ABI:$T_CPU" in
        x86:*)               key=i686 ;;
        arm:eabi:*)          key=armv5sf ;;
        arm:eabihf:arm1176*) key=armv6hf ;;
        arm:eabihf:*)        key=armv7hf ;;
        mipsel:*:mips32)     key=mips32r1el ;;
        mipsel:*)            key=mips32r2el ;;
        mips:*)              key=mips32r2eb ;;
        powerpc64le:*)       key=ppc64le ;;
    esac
    case "$T_OS" in
        linux) T_OSSL="linux-$key-$T_LIBC" ;;
        macos) T_OSSL="macos-$([ "$T_ARCH" = aarch64 ] && echo arm64 || echo x86_64)" ;;
        *)     T_OSSL="$T_OS-$T_ARCH" ;;
    esac
    T_OSSLDIR="openssl/$OSSLVER/$T_OSSL"

    # The committed jpeg archives are keyed by an older naming; this is the only place that knows it.
    T_JPEG=
    if [ "$T_KVM" = 1 ]; then
        case "$T_OSSL" in
            linux-i686-glibc)     T_JPEG=lib-jpeg-turbo/linux/x86/libturbojpeg.a ;;
            linux-x86_64-glibc)   T_JPEG=lib-jpeg-turbo/linux/x86-64/libturbojpeg.a ;;
            linux-armv6hf-glibc|linux-armv7hf-glibc) T_JPEG=lib-jpeg-turbo/linux/arm6hf/libturbojpeg.a ;;
            linux-aarch64-glibc)  T_JPEG=lib-jpeg-turbo/linux/arm64/libturbojpeg.a ;;
            macos-arm64)          T_JPEG=lib-jpeg-turbo/macos/osx-arm-64/libturbojpeg.a ;;
            macos-x86_64)         T_JPEG=lib-jpeg-turbo/macos/osx-x86-64/libturbojpeg.a ;;
            *) echo "target.sh: ARCHID $T_ARCHID has kvm=1 but no jpeg archive is known for $T_OSSL" >&2; return 1 ;;
        esac
    fi

    # The compiler. zig everywhere but a row with its own cc=, and a native host uses its own clang.
    T_HOST=$(uname -s)
    T_LDEXTRA=
    if [ -n "$T_CC" ]; then
        :
    else
        case "$T_OS" in
            linux)
                T_CC="$T_ZIGBIN cc -target $T_TRIPLE${T_TUNE:+ $T_TUNE} -Wno-date-time" ;;
            freebsd|netbsd)
                if [ "$(echo "$T_HOST" | tr A-Z a-z)" = "$T_OS" ]; then T_CC="clang"
                else
                    # zig bundles a libc for both and searches it before the sysroot, so ZIG_LIBC points it at the
                    # sysroot instead, and the headers match osver= (see zig_libc_file in env-v3.sh).
                    # zig adds no sysroot library directories on its own, and prefixes --sysroot onto -L,
                    # so the library paths are written sysroot-relative and go last, after openssl/'s own -L.
                    T_CC="$T_ZIGBIN cc -target $T_TRIPLE --sysroot=$T_SYSROOT -Wno-date-time"
                    T_ZIGLIBC="$REPO/build/.zig-libc-$T_ARCHID.txt"
                    T_LDEXTRA="-L/usr/lib -L/lib"
                fi ;;
            openbsd)
                # zig has no bundled OpenBSD libc past 7.7 (and even 7.6/7.7 refuse to link: "unable to
                # provide libc"), so unlike FreeBSD this always uses a real clang against the real sysroot -
                # host clang when the host is OpenBSD itself, otherwise this repo's zig-bundled clang.
                T_CC="$([ "$(echo "$T_HOST" | tr A-Z a-z)" = "$T_OS" ] && echo clang || echo "$T_ZIGBIN clang") -target $T_TRIPLE --sysroot=$T_SYSROOT -Wno-date-time"
                # ld.lld is what brands the ELF as OpenBSD. Without it the driver falls back to the host's
                # GNU ld, which leaves OS/ABI at SYSV and OpenBSD will not run that. Link only, because the
                # compile step warns the argument is unused.
                T_LDEXTRA="-fuse-ld=lld" ;;
            macos)
                T_MACOSCC="$MACOS_CC"
                local apple_cc="cc -arch $([ "$T_ARCH" = aarch64 ] && echo arm64 || echo x86_64) -mmacosx-version-min=$T_OSVER"
                if [ "$T_HOST" = Darwin ] && [ "$T_MACOSCC" = xcode ]; then
                    # Apple clang and ld64 from Xcode or the Command Line Tools; the SDK is the one xcrun selects.
                    T_CC="$apple_cc"
                elif [ "$T_HOST" = Darwin ]; then
                    # zig compiles, Apple's ld64 links (zig's own Mach-O linker is not used, see env-v3.sh).
                    # ZIG_LIBC makes zig use the SDK's headers instead of its own bundled macOS ones.
                    T_CC="$T_ZIGBIN cc -target $T_TRIPLE --sysroot=$T_SDK -F$T_SDK/System/Library/Frameworks -Wno-date-time"
                    T_ZIGLIBC="$REPO/build/.zig-libc-$T_ARCHID.txt"
                    T_LD="$apple_cc"
                else
                    # Cross from Linux: zig compiles against the osxcross-extracted SDK, the host's clang + ld64.lld links.
                    T_MACOSCC=zig
                    T_CC="$T_ZIGBIN cc -target $T_TRIPLE --sysroot=$T_SDK -F$T_SDK/System/Library/Frameworks -Wno-date-time"
                    T_ZIGLIBC="$REPO/build/.zig-libc-$T_ARCHID.txt"
                    T_LD="clang -target $([ "$T_ARCH" = aarch64 ] && echo arm64 || echo x86_64)-apple-macos$T_OSVER -fuse-ld=lld --sysroot=$T_SDK -F$T_SDK/System/Library/Frameworks"
                fi ;;
        esac
    fi
    # The linker driver is the compiler unless the OS branch above set another one.
    T_LD="${T_LD:-$T_CC}"
    T_CCBIN=${T_CC%% *}
    T_LDBIN=${T_LD%% *}
    # Apple's strip for a Mach-O built on a Mac, llvm-strip everywhere else. Either one invalidates the
    # signature, which sign-v3.sh puts back.
    if [ "$T_HOST" = Darwin ] && [ "$T_OS" = macos ]; then T_STRIP=strip; else T_STRIP=llvm-strip; fi
    T_STRIPBIN=${T_STRIP%% *}

    # For `list` and the stamp: what libc the binary needs on the device.
    case "$T_LIBC" in
        glibc) T_LIBCLABEL="glibc${T_LIBCVER:+ $T_LIBCVER}" ;;
        musl)  T_LIBCLABEL="musl (static)"; T_LINK=static ;;
        *)     T_LIBCLABEL="$T_OS $T_OSVER" ;;
    esac
    return 0
}

TGT_FIELDS="ARCHID NAME OS OSVER ARCH CPU ABI LIBC LIBCVER LINK KVM LMS OPT SERVER ZIG CFLAGS TRIPLE TUNE OSSL OSSLDIR JPEG CC CCBIN LD LDBIN LDEXTRA STRIP STRIPBIN MACOSCC SYSROOT SDK ZIGLIBC LIBCLABEL"

tgt_show() { tgt_load "$1" || return 1; local f; for f in $TGT_FIELDS; do eval "printf '%-10s %s\n' \"$f\" \"\$T_$f\""; done; }

# Make syntax: T_<FIELD> = <value>, one per line. Values pass through untouched, so a $ in a row
# (only cc= uses one) is spelled for make as $$ here.
tgt_make() {
    tgt_load "$1" || return 1
    local f v
    # The makefile exports T_ZIGLIBC as ZIG_LIBC, so the paths file has to exist before it compiles.
    [ -n "$T_ZIGLIBC" ] && { zig_libc_file "${T_SYSROOT:-$T_SDK}" "$T_ZIGLIBC" || return 1; }
    for f in $TGT_FIELDS; do eval "v=\$T_$f"; printf 'T_%s = %s\n' "$f" "${v//\$/\$\$}"; done
    printf 'T_OSSLVER = %s\n' "$OSSLVER"
}

tgt_list() {
    printf "%6s  %-22s %-8s %-25s %-15s %-7s %-3s %-3s %-3s %-26s %s\n" ARCHID NAME OS ARCH LIBC LINK KVM LMS OPT OPENSSL COMPILER
    local id st
    for id in $(tgt_ids); do
        tgt_load "$id" || continue
        if command -v "$T_CCBIN" >/dev/null 2>&1 || [ -x "$T_CCBIN" ]; then st="${T_CCBIN##*/}"; case "$T_CC" in *zig*) st="zig $T_ZIG" ;; esac; else st="MISSING ${T_CCBIN##*/}"; fi
        if [ "$T_LDBIN" != "$T_CCBIN" ]; then if command -v "$T_LDBIN" >/dev/null 2>&1; then st="$st, link ${T_LDBIN##*/}$(case "$T_LD" in *lld*) echo +lld ;; *) echo " (ld64)" ;; esac)"; else st="$st, MISSING ${T_LDBIN##*/}"; fi; fi
        [ "$T_OS" = macos ] && [ "$T_MACOSCC" = xcode ] && st="apple clang (xcode)"
        [ -n "$T_SYSROOT" ] && [ ! -d "$T_SYSROOT" ] && st="$st, no sysroot"
        printf "%6s  %-22s %-8s %-25s %-15s %-7s %-3s %-3s %-3s %-26s %s\n" "$id" "$T_NAME" "$T_OS" "$T_ARCH${T_CPU:+/$T_CPU}${T_ABI:+ $T_ABI}" "$T_LIBCLABEL" "$T_LINK" "$T_KVM" "$T_LMS" "$T_OPT" "$T_OSSL" "$st"
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        list)  tgt_list ;;
        ids)   tgt_ids ;;
        show)  tgt_show "$2" ;;
        make)  tgt_make "$2" ;;
        field) tgt_load "$2" && eval "printf '%s\n' \"\$T_$3\"" ;;
        *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    esac
fi
