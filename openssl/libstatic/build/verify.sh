#!/bin/bash
# Report version, object count, architecture and glibc-only symbol references
# for every archive currently in the repo. Read-only.
. "$(dirname "$(readlink -f "$0")")/env.sh"

cd "$REPO" || { echo "REPO not found: $REPO"; exit 1; }
printf '%-26s %-9s %-5s %-6s %s\n' TARGET VERSION OBJS GLIBC ARCH
printf '%-26s %-9s %-5s %-6s %s\n' ------ ------- ---- ----- ----
for f in $(find openssl/libstatic -name libcrypto.a | sort); do
    d=${f#openssl/libstatic/}; d=${d%/libcrypto.a}
    v=$(strings "$f" | grep -oE 'OpenSSL 1\.1\.1[a-z-]*' | sort -u | head -1)
    n=$(ar t "$f" | wc -l)
    g=$(nm --undefined-only "$f" 2>/dev/null | awk '{print $NF}' | grep -cE "$GLIBC_ONLY_RE")
    obj=$(ar t "$f" | grep -m1 '\.o$')
    tmp=$(mktemp -d); ( cd "$tmp" && ar x "$REPO/$f" "$obj" 2>/dev/null )
    a=$(file -b "$tmp/$obj" 2>/dev/null | cut -d, -f1-3 | sed 's/ELF //;s/ relocatable//;s/, version 1 (SYSV)//')
    rm -rf "$tmp"
    printf '%-26s %-9s %-5s %-6s %s\n' "$d" "${v#OpenSSL }" "$n" "$g" "$a"
done

echo
echo "GLIBC column: references to $GLIBC_ONLY_RE"
echo "Must be 0 for mips, mipsel, riscv64, alpine-x86-64, *24kc, openwrt_x86_64"
echo "(their agents are musl or uClibc). Nonzero elsewhere is expected and fine."
