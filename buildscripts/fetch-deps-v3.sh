#!/bin/bash
# Fetches what the rows in targets-v3.conf need and nothing else: the zig releases they name, the
# BSD sysroots for the freebsd/openbsd/netbsd rows (FreeBSD from pkgbase, OpenBSD and NetBSD from the
# mirror or streamed sets, see the BSD section), the OpenSSL source tarball for openssl/build, rcodesign for the macOS
# rows, and the Bootlin gcc for the one row that cannot use zig. Every download is verified by the
# publisher's checksum or signature where one exists, or by a smoke compile where none does.
#
#   buildscripts/fetch-deps-v3.sh list           status of every dependency, fetch nothing
#   buildscripts/fetch-deps-v3.sh all            fetch everything the table needs
#   buildscripts/fetch-deps-v3.sh zig openssl    named components only
#   components: zig openssl freebsd openbsd netbsd rcodesign bootlin-sparc64 macos
#
# Not fetched, bring your own: the macOS SDK's *source* ($MACOS_SDK, Apple-licensed) and the host
# packages check-v3.sh lists (llvm-strip, qemu-user, the KVM header packages).
#
# The macOS SDK, on a host that is not itself a Mac:
#   1. Get an Xcode .xip from Apple (needs an Apple ID, no purchase). Any recent version works;
#      the SDK version inside is what osver= on the macos rows should target or sit under.
#   2. Drop it into $BR_DOWNLOADS (default "$BUILDROOT/downloads"), named Xcode*.xip, then run:
#        buildscripts/fetch-deps-v3.sh macos
#      This unpacks just the SDK (xar + pbzx + a filtering cpio pass, all handled for you - see
#      the "macos" component below for what that does and how long it takes) and places it at
#      $MACOS_SDK (default "$BUILDROOT/osxcross/target/SDK/MacOSX<ver>.sdk", <ver> read from the
#      xip itself, reported when the command finishes). Needs `xar`, `libxar-dev`, `liblzma-dev`
#      and a host cc, none of which this script installs (apt: xar libxar-dev liblzma-dev).
#   The result should have usr/include, usr/lib and System/Library/Frameworks directly under it;
#   check-v3.sh and this script's own `list` both confirm the directory is there, not its contents.
# On a Mac, none of this is needed - $MACOS_SDK defaults to `xcrun --show-sdk-path`.

. "$(dirname "$(readlink -f "$0")")/env-v3.sh"
. "$V3_DIR/target-v3.sh"

STATUS_LOG="$(mktemp)"; trap 'rm -f "$STATUS_LOG"' EXIT
log_status() { echo "$1: $2" | tee -a "$STATUS_LOG" >&2; }

archive_ok() {
    case "$1" in
        *.tar.xz|*.txz|*.xz)  xz -t "$1"   >/dev/null 2>&1 ;;
        *.tar.gz|*.tgz|*.gz)  gzip -t "$1" >/dev/null 2>&1 ;;
        *.tar.bz2|*.bz2)      bzip2 -t "$1" >/dev/null 2>&1 ;;
        *) return 0 ;;
    esac
}

# fetch <url> <sha256 or empty> <dest>. Keeps a dest that already matches, refetches anything else.
fetch() {
    local url="$1" sha="$2" dest="$3"
    if [ -f "$dest" ]; then
        if [ -n "$sha" ]; then [ "$(v3_sha256 "$dest")" = "$sha" ] && return 0
        else archive_ok "$dest" && return 0; fi
        echo "  $dest exists but fails its check - re-downloading"; rm -f "$dest"
    fi
    mkdir -p "$(dirname "$dest")"
    echo "  downloading $url"
    curl -sSL --fail --retry 3 --retry-delay 2 -o "$dest" "$url" || { echo "  FETCH FAILED: $url" >&2; return 1; }
    if [ -n "$sha" ]; then [ "$(v3_sha256 "$dest")" = "$sha" ] || { echo "  CHECKSUM MISMATCH: $dest" >&2; rm -f "$dest"; return 1; }
    else archive_ok "$dest" || { echo "  CORRUPT ARCHIVE: $dest" >&2; rm -f "$dest"; return 1; }; fi
}

# A truncated tarball can leave a bin/ that exists but cannot compile, so presence is a smoke compile.
smoke_ok() {   # <compiler command...>
    local t; t=$(mktemp -d); printf 'typedef int x;\n' > "$t/s.c"
    "$@" -c "$t/s.c" -o "$t/s.o" >/dev/null 2>&1; local rc=$?; rm -rf "$t"; return $rc
}

# ---- zig: every release the table names -----------------------------------------------------
zig_index_key() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) echo x86_64-linux ;; Linux-aarch64) echo aarch64-linux ;;
        Darwin-arm64) echo aarch64-macos ;; Darwin-x86_64) echo x86_64-macos ;;
        *) return 1 ;;
    esac
}
zig_versions() { local id; { echo "$ZIG_VERSION"; for id in $(tgt_ids); do tgt_load "$id" && echo "$T_ZIG"; done; } | sort -u; }
p_zig_one() {
    local ver="$1" dest="$BR_TOOLCHAINS/zig-$1" name="zig-$1"
    smoke_ok "$dest/zig" cc -target x86_64-linux-gnu && { log_status "$name" "already present"; return 0; }
    local key; key=$(zig_index_key) || { log_status "$name" "FAILED (no zig build for $(uname -s)-$(uname -m))"; return 1; }
    # ziglang.org's index carries the tarball URL and its sha256 together, so neither is pinned by hand.
    local out; out=$(curl -sSL --fail --retry 3 "https://ziglang.org/download/index.json" | python3 -c '
import json, sys
e = json.load(sys.stdin).get(sys.argv[1], {}).get(sys.argv[2]) or sys.exit(1)
print(e["tarball"]); print(e["shasum"])' "$ver" "$key") || { log_status "$name" "FAILED (no $key entry for $ver in index.json)"; return 1; }
    local url sha; url=$(echo "$out" | sed -n 1p); sha=$(echo "$out" | sed -n 2p)
    fetch "$url" "$sha" "$BR_DOWNLOADS/$(basename "$url")" || { log_status "$name" "FAILED (download)"; return 1; }
    rm -rf "$dest"; mkdir -p "$dest"
    tar -xaf "$BR_DOWNLOADS/$(basename "$url")" -C "$dest" --strip-components=1 || { log_status "$name" "FAILED (extract)"; return 1; }
    smoke_ok "$dest/zig" cc -target x86_64-linux-gnu && log_status "$name" "OK -> $dest" || { log_status "$name" "FAILED (smoke compile)"; return 1; }
}
p_zig() { local v rc=0; for v in $(zig_versions); do p_zig_one "$v" || rc=1; done; return $rc; }

# ---- OpenSSL source, for openssl/build/build.sh -----------------------------------------------
ossl_tag() { case "$OSSLVER" in 1.*) echo "OpenSSL_$(echo "$OSSLVER" | tr . _)" ;; *) echo "openssl-$OSSLVER" ;; esac; }
p_openssl() {
    local sha; sha=$(curl -sSL --fail --retry 3 "https://www.openssl.org/source/openssl-$OSSLVER.tar.gz.sha256" | awk '{print $1}')
    echo "$sha" | grep -qE '^[0-9a-f]{64}$' || { log_status openssl "FAILED (no sha256 sidecar for $OSSLVER on openssl.org)"; return 1; }
    fetch "https://github.com/openssl/openssl/releases/download/$(ossl_tag)/openssl-$OSSLVER.tar.gz" "$sha" "$BR_DOWNLOADS/openssl-$OSSLVER.tar.gz" \
        && log_status openssl "OK ($OSSLVER)" || { log_status openssl "FAILED"; return 1; }
}

# ---- BSD sysroots, one per freebsd/openbsd/netbsd row ------------------------------------------------
# A sysroot is lib/ (the .so.N the linker follows), usr/lib (crt objects, .so links, .a) and usr/include.
#
# FreeBSD: pkgbase. pkg.freebsd.org publishes the base system as packages per release, so the five the
# build needs (FreeBSD-clibs, -clibs-dev, -runtime for libutil.so.9, -runtime-dev for libutil.so and its
# header, -libbsm-dev for the bsm/audit.h that sys/ucred.h includes) are fetched directly, about 24 MB, and only their lib/, usr/lib and usr/include members are
# extracted. The index packagesite.yaml is RSA-signed over its sha256 hex, the key is pinned by
# FREEBSD_PKG_FINGERPRINT, and each package's "sum" is 2$ + blake2b-512 in pkg's little-endian zbase32.
# Measured 2026-09-13: the agent linked against this sysroot is the same size with the same FBSD_1.x
# symbol versions as against the trimmed base.txz. Fallback: base.txz from download.freebsd.org.
#
# OpenBSD: no pkgbase, the sets are monolithic and index.txt only lists them. The mirror's trimmed
# sysroot is the small download. Without it the sets are streamed: curl | tee >(sha256sum) | tar with
# only the three paths, so nothing is stored twice and the SHA256 manifest is still checked, after the
# fact, with the directory removed on mismatch. That still transfers the whole ~70 MB comp and ~330 MB
# base set, which is why the mirror stays first.
#
# NetBSD: the same approach as OpenBSD, with base.tar.xz (~50 MB, lib/ and the unversioned usr/lib .so links)
# and comp.tar.xz (~73 MB, usr/include, crt objects, .a). Its manifest is SHA512 only, there is no SHA256 file.
sysroot_from_mirror() {   # <name> <dir> <url>
    local dest="$BR_DOWNLOADS/$(basename "$3")"
    curl -sSfL -o /dev/null --head "$3" 2>/dev/null || return 1
    fetch "$3" "" "$dest" || return 1
    mkdir -p "$2" && tar xf "$dest" -C "$2" && log_status "$1" "OK (from mirror)"
}

# pkg's package checksum: "2$" + blake2b-512 of the file, zbase32 with the bits taken little-endian.
pkg_sum_ok() {   # <file> <sum>
    python3 - "$1" "$2" <<'EOF'
import hashlib, sys
alpha = "ybndrfg8ejkmcpqxot1uwisza345h769"
def zb32_le(b):
    out = ""; acc = 0; nb = 0
    for x in b:
        acc |= x << nb; nb += 8
        while nb >= 5: out += alpha[acc & 31]; acc >>= 5; nb -= 5
    if nb: out += alpha[acc & 31]
    return out
want = sys.argv[2]
sys.exit(0 if want.startswith("2$") and zb32_le(hashlib.blake2b(open(sys.argv[1], "rb").read()).digest()) == want[2:] else 1)
EOF
}
# FreeBSD-libbsm-dev only became necessary once ZIG_LIBC made zig use this sysroot's headers: its own bundled copy had
# bsm/, and without it 'make ARCHID=30' stopped at sys/ucred.h:42 with "fatal error: 'bsm/audit.h' file not found".
FREEBSD_PKGBASE_SET="FreeBSD-clibs FreeBSD-clibs-dev FreeBSD-runtime FreeBSD-runtime-dev FreeBSD-libbsm-dev"
freebsd_pkgbase() {   # <name> <release> <dir>
    local name="$1" rel="$2" dir="$3" repo="$FREEBSD_PKG_REPO/FreeBSD:${2%%.*}:amd64/base_release_${2#*.}"
    local t; t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
    curl -sSL --fail --retry 3 -o "$t/packagesite.pkg" "$repo/packagesite.pkg" || { log_status "$name" "pkgbase: no index at $repo"; return 1; }
    tar -xf "$t/packagesite.pkg" -C "$t" || { log_status "$name" "pkgbase: bad index archive"; return 1; }
    [ "$(v3_sha256 "$t/packagesite.yaml.pub")" = "$FREEBSD_PKG_FINGERPRINT" ] || { log_status "$name" "pkgbase: signing key does not match FREEBSD_PKG_FINGERPRINT - refusing"; return 1; }
    printf '%s' "$(v3_sha256 "$t/packagesite.yaml")" > "$t/hash"
    openssl dgst -sha256 -verify "$t/packagesite.yaml.pub" -signature "$t/packagesite.yaml.sig" "$t/hash" >/dev/null 2>&1 \
        || { log_status "$name" "pkgbase: index signature does not verify - refusing"; return 1; }
    python3 - "$t/packagesite.yaml" $FREEBSD_PKGBASE_SET > "$t/want" <<'EOF' || { log_status "$name" "pkgbase: a package is missing from the index"; return 1; }
import json, sys
want = set(sys.argv[2:]); found = {}
for line in open(sys.argv[1]):
    p = json.loads(line)
    if p["name"] in want: found[p["name"]] = p
missing = want - set(found)
if missing: print("missing:", *sorted(missing), file=sys.stderr); sys.exit(1)
for n in sys.argv[2:]: print(found[n]["path"].lstrip("./"), found[n]["sum"])
EOF
    mkdir -p "$dir"
    local path sum f
    while read -r path sum; do
        f="$BR_DOWNLOADS/$(basename "$path")"
        [ -f "$f" ] && pkg_sum_ok "$f" "$sum" || {
            fetch "$repo/$path" "" "$f" || { log_status "$name" "pkgbase: download of $path failed"; return 1; }
            pkg_sum_ok "$f" "$sum" || { log_status "$name" "pkgbase: checksum mismatch on $path"; rm -f "$f"; return 1; }
        }
        # Members are stored as /usr/lib/..., so the patterns are absolute; a package without one of the paths is normal.
        tar -xf "$f" -C "$dir" $TAR_WILD '/lib/*' '/usr/lib/*' '/usr/include/*' 2>/dev/null
    done < "$t/want"
    [ -f "$dir/usr/lib/libc.so" ] && [ -f "$dir/usr/include/stdio.h" ] && [ -f "$dir/usr/lib/libutil.so" ] && [ -f "$dir/usr/include/bsm/audit.h" ] \
        && log_status "$name" "OK (pkgbase, $(echo $FREEBSD_PKGBASE_SET | wc -w) packages, signed index)" \
        || { log_status "$name" "pkgbase: extracted, but libc.so, stdio.h, libutil.so or bsm/audit.h is missing"; return 1; }
}

# Streams one upstream set through tar, keeping only the sysroot paths, and checks its hash afterwards.
# The hash is sha512 when it is 128 hex digits long, as in NetBSD's manifest, and sha256 otherwise.
stream_set() {   # <name> <url> <sha256 or sha512> <dir>
    local t z h=v3_sha256_stream; t=$(mktemp); rm -f "$t"
    [ ${#3} -eq 128 ] && h=v3_sha512_stream
    # tar cannot sniff the compression of a stream, so it is told from the name; the member paths are
    # matched unanchored because FreeBSD stores them as ./usr/..., OpenBSD as ./usr/... and the mirror as usr/...
    case "$2" in *.txz|*.xz) z=J ;; *) z=z ;; esac
    curl -sSL --fail --retry 3 "$2" | tee >($h > "$t") \
        | tar x${z}f - -C "$4" $TAR_WILD 'usr/include/*' 'usr/lib/*' 'lib/*' 2>/dev/null
    local i=0; while [ ! -s "$t" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    local got; got=$(cat "$t" 2>/dev/null); rm -f "$t"
    [ "$got" = "$3" ] || { log_status "$1" "FAILED (streamed set $(basename "$2") has hash $got, manifest says $3)"; return 1; }
}
# OpenBSD ships no unversioned libNAME.so links and ld.lld does not do OpenBSD's version search, so
# without these it silently links the static .a for every -l and the binary has no PT_DYNAMIC.
openbsd_so_links() {
    local lib="$1/usr/lib" f base n=0
    for f in "$lib"/lib*.so.*.*; do
        [ -e "$f" ] || continue
        base="$(basename "$f" | sed -E 's/(\.so)\.[0-9]+\.[0-9]+$/\1/')"
        [ -e "$lib/$base" ] || { ln -s "$(basename "$f")" "$lib/$base"; n=$((n + 1)); }
    done
    [ "$n" -gt 0 ] && echo "  added $n unversioned .so links for ld.lld"
}
p_sysroot() {   # <freebsd|openbsd|netbsd> <release>
    local os="$1" rel="$2" dir="$BR_SYSROOTS/$1-$2" name="$1-$2"
    # A FreeBSD sysroot fetched before FreeBSD-libbsm-dev was in the set lacks bsm/audit.h, so it is fetched again rather than reported present.
    if [ -f "$dir/usr/lib/libc.so" ] && [ -d "$dir/usr/include" ] && { [ "$os" != freebsd ] || [ -f "$dir/usr/include/bsm/audit.h" ]; }; then [ "$os" = openbsd ] && openbsd_so_links "$dir"; log_status "$name" "already present"; return 0; fi
    rm -rf "$dir"; mkdir -p "$dir"
    if [ "$os" = freebsd ]; then
        freebsd_pkgbase "$name" "$rel" "$dir" && return 0
        log_status "$name" "pkgbase unavailable - streaming base.txz from download.freebsd.org instead"
        local base="https://download.freebsd.org/releases/amd64/amd64/$rel-RELEASE"
        local sha; sha=$(curl -sSL --fail "$base/MANIFEST" | awk '$1=="base.txz"{print $2}')
        [ -n "$sha" ] || { log_status "$name" "FAILED (MANIFEST)"; return 1; }
        stream_set "$name" "$base/base.txz" "$sha" "$dir" || { rm -rf "$dir"; return 1; }
        log_status "$name" "OK (streamed base.txz)"
    elif [ "$os" = netbsd ]; then
        sysroot_from_mirror "$name" "$dir" "$MESHAGENT_TOOLCHAINS_RAW/SR/$os-$rel-sysroot.tar.xz" && return 0
        log_status "$name" "not on the mirror - streaming the sets from cdn.netbsd.org"
        # NetBSD's own unversioned .so links are relative (../../lib/libc.so.12.220.1), so no link fixup is needed.
        local base="https://cdn.netbsd.org/pub/NetBSD/NetBSD-$rel/amd64/binary/sets" m s sha
        m=$(curl -sSL --fail "$base/SHA512") || { log_status "$name" "FAILED (SHA512 manifest)"; return 1; }
        for s in base comp; do
            sha=$(echo "$m" | awk -v f="$s.tar.xz" '$0 ~ "\\(" f "\\)"{print $4}')
            [ -n "$sha" ] || { log_status "$name" "FAILED (no $s.tar.xz in the manifest)"; return 1; }
            stream_set "$name" "$base/$s.tar.xz" "$sha" "$dir" || { rm -rf "$dir"; return 1; }
        done
        [ -f "$dir/usr/lib/libc.so" ] && [ -f "$dir/usr/include/stdio.h" ] \
            && log_status "$name" "OK (streamed base and comp sets)" \
            || { log_status "$name" "FAILED (streamed, but libc.so or stdio.h is missing)"; rm -rf "$dir"; return 1; }
    else
        sysroot_from_mirror "$name" "$dir" "$MESHAGENT_TOOLCHAINS_RAW/SR/$os-$rel-sysroot.tar.xz" && { openbsd_so_links "$dir"; return 0; }
        log_status "$name" "not on the mirror - streaming the sets from cdn.openbsd.org"
        # The headers and crt objects are in comp<NN>.tgz, base<NN>.tgz alone has an empty usr/include.
        local nodot="${rel//./}" base="https://cdn.openbsd.org/pub/OpenBSD/$rel/amd64" m s sha
        m=$(curl -sSL --fail "$base/SHA256") || { log_status "$name" "FAILED (SHA256 manifest)"; return 1; }
        for s in base comp; do
            sha=$(echo "$m" | awk -v f="$s$nodot.tgz" '$0 ~ "\\(" f "\\)"{print $4}')
            [ -n "$sha" ] || { log_status "$name" "FAILED (no $s$nodot.tgz in the manifest)"; return 1; }
            stream_set "$name" "$base/$s$nodot.tgz" "$sha" "$dir" || { rm -rf "$dir"; return 1; }
        done
        openbsd_so_links "$dir"; log_status "$name" "OK (streamed base and comp sets)"
    fi
}
p_bsd() {   # <freebsd|openbsd|netbsd>: every release the table's rows of that os name
    local id rc=0 rels
    rels=$(for id in $(tgt_ids); do tgt_load "$id" && [ "$T_OS" = "$1" ] && echo "$T_OSVER"; done | sort -u)
    [ -n "$rels" ] || { log_status "$1" "no $1 row in the table"; return 0; }
    for r in $rels; do p_sysroot "$1" "$r" || rc=1; done; return $rc
}

# ---- rcodesign, signs the macOS agents on any host --------------------------------------------
p_rcodesign() {
    [ -x "$RCODESIGN" ] && "$RCODESIGN" --version 2>/dev/null | grep -q "$APPLE_CODESIGN_VER" && { log_status rcodesign "already present ($APPLE_CODESIGN_VER)"; return 0; }
    local asset
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64)  asset="apple-codesign-$APPLE_CODESIGN_VER-aarch64-apple-darwin.tar.gz" ;;
        Darwin-x86_64) asset="apple-codesign-$APPLE_CODESIGN_VER-x86_64-apple-darwin.tar.gz" ;;
        Linux-aarch64) asset="apple-codesign-$APPLE_CODESIGN_VER-aarch64-unknown-linux-musl.tar.gz" ;;
        Linux-x86_64)  asset="apple-codesign-$APPLE_CODESIGN_VER-x86_64-unknown-linux-musl.tar.gz" ;;
        *) log_status rcodesign "FAILED (no release for $(uname -s)-$(uname -m))"; return 1 ;;
    esac
    local base="https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/$APPLE_CODESIGN_VER"
    local sha; sha=$(curl -sSL --fail "$base/$asset.sha256" | awk '{print $1}')
    echo "$sha" | grep -qE '^[0-9a-f]{64}$' || { log_status rcodesign "FAILED (no .sha256 sidecar)"; return 1; }
    fetch "$base/$asset" "$sha" "$BR_DOWNLOADS/$asset" || { log_status rcodesign "FAILED (download)"; return 1; }
    mkdir -p "$BUILDROOT/bin" && tar xzf "$BR_DOWNLOADS/$asset" -C "$BUILDROOT/bin" --strip-components=1 "${asset%.tar.gz}/rcodesign" \
        && chmod +x "$RCODESIGN" && log_status rcodesign "OK ($APPLE_CODESIGN_VER)" || { log_status rcodesign "FAILED (extract)"; return 1; }
}

# ---- macOS SDK, extracted from an Xcode .xip already sitting in $BR_DOWNLOADS -----------------
# The .xip itself is Apple-licensed and never downloaded here - see the header comment for how to
# get one. Once it exists, this needs no manual xar/pbzx steps: xar unpacks the xip container (a
# few seconds - the payload is inside one member, "Content", not exploded on disk), pbzx decompresses
# that payload's pbzx chunk framing, openssl/build/xip-sdk-cpio.py drops everything but the SDK and
# the libc++ headers and repairs Apple's cross-SDK hard links (see its own docstring for why a plain
# pattern-restricted cpio is not enough), and cpio -id lays the survivors out on disk. Real Xcode
# 26.6 xip measured: ~5s to unpack Content (2.97 GB), ~73s to decompress+filter+extract (kept 49787
# of 157007 entries, 776 MB written).
build_pbzx() {
    [ -x "$PBZX" ] && return 0
    command -v cc >/dev/null 2>&1 || { echo "  pbzx needs a host cc" >&2; return 1; }
    mkdir -p "$BUILDROOT/bin"
    cc -O2 -o "$PBZX" "$V3_DIR/pbzx.c" -lxar -llzma 2>&1 | sed 's/^/  pbzx: /' >&2
    [ -x "$PBZX" ]
}
p_macos() {
    local xip; xip=$(ls "$BR_DOWNLOADS"/[Xx]code*.xip 2>/dev/null | sort | tail -1)
    [ -n "$xip" ] || { log_status macos "FAILED (no Xcode*.xip in $BR_DOWNLOADS - see this script's header for where to get one)"; return 1; }
    command -v xar >/dev/null 2>&1 || { log_status macos "FAILED (xar missing - apt/brew: xar)"; return 1; }
    command -v python3 >/dev/null 2>&1 || { log_status macos "FAILED (python3 missing)"; return 1; }
    command -v cpio >/dev/null 2>&1 || { log_status macos "FAILED (cpio missing)"; return 1; }
    build_pbzx || { log_status macos "FAILED (could not build pbzx - apt: libxar-dev liblzma-dev)"; return 1; }
    local xipfilter="$REPO/openssl/build/xip-sdk-cpio.py"
    [ -f "$xipfilter" ] || { log_status macos "FAILED (missing $xipfilter)"; return 1; }

    local tmp; tmp=$(mktemp -d "$BR_DOWNLOADS/.macos-sdk-extract.XXXXXX")
    ( cd "$tmp" && xar -xf "$xip" Content ) 2>&1 | sed 's/^/  xar: /' >&2
    [ -f "$tmp/Content" ] || { log_status macos "FAILED (xar found no Content member - is this really an Xcode xip?)"; rm -rf "$tmp"; return 1; }
    mkdir -p "$tmp/out"
    ( cd "$tmp" && "$PBZX" -n Content | python3 "$xipfilter" | (cd out && cpio -id --quiet) ) 2>&1 | sed 's/^/  extract: /' >&2
    rm -f "$tmp/Content"

    local sdkdir; sdkdir=$(find "$tmp/out" -maxdepth 8 -type d -iname "MacOSX*.sdk" -path "*/Developer/SDKs/*" | sort | tail -1)
    [ -n "$sdkdir" ] || { log_status macos "FAILED (no MacOSX*.sdk found inside the xip payload)"; rm -rf "$tmp"; return 1; }
    # A recent Xcode's SDK directory is just "MacOSX.sdk" with the real version only inside
    # SDKSettings.json, not two symlinks pointing at it the way older Xcodes named the directory itself.
    local ver; ver=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['Version'])" "$sdkdir/SDKSettings.json" 2>/dev/null)
    [ -n "$ver" ] || { log_status macos "FAILED (SDKSettings.json has no Version - $sdkdir)"; rm -rf "$tmp"; return 1; }

    local dest="$BUILDROOT/osxcross/target/SDK/MacOSX$ver.sdk"
    [ -d "$sdkdir/usr/include" ] && [ -d "$sdkdir/System/Library/Frameworks" ] || { log_status macos "FAILED (extracted tree looks incomplete: $sdkdir)"; rm -rf "$tmp"; return 1; }
    rm -rf "$dest"; mkdir -p "$(dirname "$dest")"
    mv "$sdkdir" "$dest"
    rm -rf "$tmp"
    if [ "$ver" = "$OSXCROSS_SDK_VER" ]; then
        log_status macos "OK - $dest (matches the default OSXCROSS_SDK_VER, nothing else to set)"
    else
        log_status macos "OK - $dest (set OSXCROSS_SDK_VER=$ver, or MACOS_SDK=$dest, to use it - the default OSXCROSS_SDK_VER is $OSXCROSS_SDK_VER)"
    fi
}

# ---- Bootlin sparc64 gcc, the only non-zig compiler ------------------------------------------
p_bootlin_sparc64() {
    local cc="$BOOTLIN_SPARC64/bin/sparc64-linux-gcc" base; base=$(basename "$BOOTLIN_SPARC64")
    smoke_ok "$cc" && { log_status bootlin-sparc64 "already present"; return 0; }
    fetch "https://toolchains.bootlin.com/downloads/releases/toolchains/sparc64/tarballs/$base.tar.bz2" "" "$BR_DOWNLOADS/$base.tar.bz2" || { log_status bootlin-sparc64 "FAILED (download)"; return 1; }
    mkdir -p "$BR_TOOLCHAINS" && tar xjf "$BR_DOWNLOADS/$base.tar.bz2" -C "$BR_TOOLCHAINS" || { log_status bootlin-sparc64 "FAILED (extract)"; return 1; }
    smoke_ok "$cc" && log_status bootlin-sparc64 "OK" || { log_status bootlin-sparc64 "FAILED (smoke compile)"; return 1; }
}

# ---- status without fetching ------------------------------------------------------------------
list_status() {
    local v id r
    echo "BUILDROOT=$BUILDROOT"
    for v in $(zig_versions); do smoke_ok "$BR_TOOLCHAINS/zig-$v/zig" cc -target x86_64-linux-gnu && echo "  present  zig $v" || echo "  MISSING  zig $v  (fetch-deps-v3.sh zig)"; done
    [ -f "$BR_DOWNLOADS/openssl-$OSSLVER.tar.gz" ] && echo "  present  openssl-$OSSLVER.tar.gz" || echo "  MISSING  openssl-$OSSLVER.tar.gz  (fetch-deps-v3.sh openssl; only needed to rebuild the archives)"
    for id in $(tgt_ids); do
        tgt_load "$id" || continue
        [ -n "$T_SYSROOT" ] && { [ -f "$T_SYSROOT/usr/lib/libc.so" ] && echo "  present  sysroot $T_OS-$T_OSVER" || echo "  MISSING  sysroot $T_OS-$T_OSVER  (fetch-deps-v3.sh $T_OS)"; }
    done | sort -u
    [ -x "$RCODESIGN" ] && echo "  present  rcodesign" || echo "  MISSING  rcodesign  (fetch-deps-v3.sh rcodesign; macOS rows only$([ "$V3_HOST" = Darwin ] && echo ", or set MACOS_CODESIGN_IDENTITY"))"
    if [ -d "$MACOS_SDK" ]; then echo "  present  macOS SDK $MACOS_SDK"
    elif [ "$V3_HOST" = Darwin ]; then echo "  MISSING  macOS SDK $MACOS_SDK  (xcode-select --install; macOS rows only)"
    elif ls "$BR_DOWNLOADS"/[Xx]code*.xip >/dev/null 2>&1; then echo "  MISSING  macOS SDK $MACOS_SDK  (fetch-deps-v3.sh macos - an Xcode xip is sitting in $BR_DOWNLOADS; macOS rows only)"
    else echo "  MISSING  macOS SDK $MACOS_SDK  (bring your own, see fetch-deps-v3.sh help; macOS rows only)"
    fi
    smoke_ok "$BOOTLIN_SPARC64/bin/sparc64-linux-gcc" && echo "  present  bootlin sparc64 gcc" || echo "  MISSING  bootlin sparc64 gcc  (fetch-deps-v3.sh bootlin-sparc64; ARCHID 60 only)"
}

# macos is deliberately not in ALL: unlike everything else here it depends on a file only a human
# can supply (an Apple-licensed Xcode .xip), so `all` would fail on every host that doesn't have one.
ALL="zig openssl freebsd openbsd netbsd rcodesign bootlin-sparc64"
KNOWN="$ALL macos"
case "${1:-}" in
    list) list_status; exit 0 ;;
    all)  set -- $ALL ;;
    ""|help|-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
mkdir -p "$BR_DOWNLOADS" "$BR_TOOLCHAINS" "$BR_SYSROOTS"
rc=0
for c in "$@"; do
    echo "=== $c ==="
    case "$c" in
        zig) p_zig ;; openssl) p_openssl ;; freebsd|openbsd|netbsd) p_bsd "$c" ;; rcodesign) p_rcodesign ;; bootlin-sparc64) p_bootlin_sparc64 ;; macos) p_macos ;;
        *) echo "unknown component: $c (one of: $KNOWN)" >&2; false ;;
    esac || rc=1
done
echo; echo "================= SUMMARY ================="; cat "$STATUS_LOG"
exit $rc
