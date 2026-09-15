#!/bin/bash
# Signs one macOS agent binary after strip. Called by makefile.v3; usable by hand:
#   buildscripts/sign-v3.sh build/osx-arm-64/meshagent_osx-arm-64
# Apple Silicon refuses a binary whose signature does not match the file, and strip invalidates the linker's.
#
# Identity, in this order:
#   SIGN_ADHOC=1                 ad-hoc, no identity (changes every build, so TCC re-prompts after each update)
#   MACOS_CODESIGN_IDENTITY=...  a keychain identity, Mac only, Apple's codesign
#   $MACOS_SIGN_P12              the shared self-signed identity, rcodesign on any host (generated once when
#                                missing, except in CI where it must arrive as a secret)
# The self-signed identity stays the same on every build host on purpose: TCC's Screen Recording and
# Accessibility grants are keyed on it, a new one means every Mac asks again.

. "$(dirname "$(readlink -f "$0")")/env-v3.sh"
bin="$1"
[ -f "$bin" ] || { echo "sign-v3.sh: no such file: $bin" >&2; exit 2; }

adhoc="${SIGN_ADHOC:-0}"
if [ "$adhoc" != 1 ] && [ -z "$MACOS_CODESIGN_IDENTITY" ] && [ ! -f "$MACOS_SIGN_P12" ] && [ -n "${CI:-}" ]; then
    echo "  no signing identity in CI - signing ad-hoc (set the MACOS_SIGN_P12 secret for a stable identity)"; adhoc=1
fi

# Apple's codesign when a keychain identity is named, or for ad-hoc on a Mac. Everything else is rcodesign.
if [ "$V3_HOST" = Darwin ] && { [ "$adhoc" = 1 ] || [ -n "$MACOS_CODESIGN_IDENTITY" ]; }; then
    ident="${MACOS_CODESIGN_IDENTITY:--}"; [ "$adhoc" = 1 ] && ident="-"
    codesign --force --sign "$ident" --options runtime --timestamp=none "$bin" >/dev/null 2>&1 \
        || { echo "sign-v3.sh: codesign failed on $bin" >&2; exit 1; }
    echo "  signed $bin ($([ "$ident" = - ] && echo ad-hoc || echo "$ident"))"
    exit 0
fi

# rcodesign, a checksummed 5 MB release binary, fetched on first use.
[ -x "$RCODESIGN" ] || "$V3_DIR/fetch-deps-v3.sh" rcodesign >/dev/null || exit 1
[ -x "$RCODESIGN" ] || { echo "sign-v3.sh: $RCODESIGN missing - buildscripts/fetch-deps-v3.sh rcodesign" >&2; exit 1; }

if [ "$adhoc" = 1 ]; then
    "$RCODESIGN" sign "$bin" >/dev/null 2>&1 && echo "  signed $bin (ad-hoc)"; exit
fi

if [ ! -f "$MACOS_SIGN_P12" ]; then
    echo "sign-v3.sh: generating a NEW self-signed identity at $MACOS_SIGN_P12"
    echo "            copy it to every other host that builds macOS updates - do not regenerate (TCC grants key on it)"
    mkdir -p "$MACOS_SIGN_DIR" && chmod 700 "$MACOS_SIGN_DIR"
    t="$MACOS_SIGN_DIR/.gen.$$"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
        -subj "/CN=$MACOS_SIGN_CN/O=PTR-inc" -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "subjectKeyIdentifier=hash" -keyout "$t.key" -out "$t.crt" >/dev/null 2>&1 \
        || { rm -f "$t.key" "$t.crt"; echo "sign-v3.sh: openssl req failed" >&2; exit 1; }
    # Legacy SHA1-3DES PBE because rcodesign's p12 parser rejects OpenSSL 3's default PBES2 AES container.
    openssl pkcs12 -export -inkey "$t.key" -in "$t.crt" -name "$MACOS_SIGN_CN" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -passout "pass:$MACOS_SIGN_P12_PASSWORD" -out "$MACOS_SIGN_P12" >/dev/null 2>&1 \
        || { rm -f "$t.key" "$t.crt" "$MACOS_SIGN_P12"; echo "sign-v3.sh: pkcs12 export failed" >&2; exit 1; }
    rm -f "$t.key" "$t.crt"; chmod 600 "$MACOS_SIGN_P12"
    cp -f "$MACOS_SIGN_P12" "$MACOS_SIGN_P12.$(date +%Y%m%d).bak" 2>/dev/null
    echo "            backup: $MACOS_SIGN_P12.$(date +%Y%m%d).bak"
fi

# rcodesign only accepts a non-empty password file, so the empty self-signed default goes via argv,
# and a real password goes via a 0600 temp file to stay out of `ps`.
if [ -n "$MACOS_SIGN_P12_PASSWORD" ]; then
    pf=$(mktemp "$MACOS_SIGN_DIR/.pass.XXXXXX") && chmod 600 "$pf" && printf '%s' "$MACOS_SIGN_P12_PASSWORD" > "$pf"
    "$RCODESIGN" sign --p12-file "$MACOS_SIGN_P12" --p12-password-file "$pf" --code-signature-flags runtime "$bin" >/dev/null 2>&1; rc=$?
    rm -f "$pf"
else
    "$RCODESIGN" sign --p12-file "$MACOS_SIGN_P12" --p12-password '' --code-signature-flags runtime "$bin" >/dev/null 2>&1; rc=$?
fi
[ $rc -eq 0 ] || { echo "sign-v3.sh: rcodesign failed on $bin" >&2; exit 1; }
echo "  signed $bin ($("$RCODESIGN" print-signature-info "$bin" 2>/dev/null | grep -m1 -oE 'CN=[^,]*' || echo identity))"
