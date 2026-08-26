# macOS code signing & notarization

Split out of [BUILD.md](BUILD.md) because it's a self-contained topic: how `make macos` signs
every agent, how to generate or replace the signing identity by hand, how to re-sign a binary
that's already been stripped/modified, and how to notarize a Developer-ID-signed build. Read
[BUILD.md's macOS section](BUILD.md#macos) first for the build itself (osxcross, the SDK, ARCHIDs
16/29) — this doc picks up after the binary exists.

**Code signing.** Apple Silicon refuses to exec a binary whose signature doesn't match the file,
and `strip` invalidates the linker's ad-hoc signature, so `make macos` re-signs every agent after
strip with [rcodesign](https://github.com/indygreg/apple-platform-rs) (`./fetch-toolchains.sh
rcodesign`, fetched on first use; works identically on Linux and macOS, no keychain). The identity
is `$BUILDROOT/private/codesign/meshagent-codesign.p12`: a **self-signed** certificate generated
once by the first `make macos` and reused after that. macOS trusts it no more than an ad-hoc
signature (no Gatekeeper benefit; nothing is imported on any Mac), but a *stable* identity keeps
TCC's Screen Recording/Accessibility grants across agent self-updates - ad-hoc changes every
build and re-prompts. Rules that follow from that:

- the identity must be the **same on every host that builds updates** - copy the `.p12` to other
  build machines, never regenerate; CI gets it as a secret (`CI` set → no auto-generation);
- back it up (a `.bak` is written next to it at generation) - losing it means every deployed
  agent re-prompts for KVM permissions on its next update;
- a real Developer ID `.p12` dropped at the same path (or `MACOS_SIGN_P12=…`,
  `MACOS_SIGN_P12_PASSWORD=…`) replaces it with no makefile change - that plus notarization is
  what removes the Gatekeeper prompt for browser-downloaded copies;
- CI without the identity secret signs **ad-hoc** automatically (runnable, no TCC persistence);
  `SIGN_ADHOC=1` forces the same locally, `SIGN=0` skips signing altogether (x86_64-only
  debugging). `./fetch-toolchains.sh list` shows the identity's subject and expiry.

**Generating a code-signing certificate by hand.** `make macos` does this automatically
(`build-env.sh macos_sign_identity`); the recipe is here for a build server, a rotation, or a
password-protected identity. Every option is load-bearing - rcodesign and macOS both reject a
certificate that lacks the code-signing EKU, and rcodesign cannot read OpenSSL 3's default p12
container.

```sh
umask 077; mkdir -p $BUILDROOT/private/codesign && cd $BUILDROOT/private/codesign

# 1. Key + self-signed certificate (one step). P-256 is what Apple issues; RSA-2048+ also works.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -subj '/CN=MeshAgent self-signed code signing (PTR-inc)/O=PTR-inc' \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=critical,codeSigning' \
    -addext 'subjectKeyIdentifier=hash' \
    -keyout codesign.key -out codesign.crt
#   -x509        self-signed leaf (no CSR/CA round-trip)      -nodes   unencrypted key file (the p12 carries the password)
#   -days 3650   10 years; TCC grants die with the cert, so long   CN     free text, shown by `codesign -dv`, otherwise unused
#   keyUsage=digitalSignature + extendedKeyUsage=codeSigning   REQUIRED - Apple's verifier and rcodesign check the EKU
#   CA:FALSE     a leaf, not a CA (a CA cert is refused as a signer)

# 2. Bundle as PKCS#12 in the legacy container rcodesign understands.
openssl pkcs12 -export -inkey codesign.key -in codesign.crt \
    -name 'MeshAgent self-signed code signing (PTR-inc)' \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout 'pass:'  -out meshagent-codesign.p12
#   -keypbe/-certpbe PBE-SHA1-3DES -macalg sha1   REQUIRED - OpenSSL 3 defaults to PBES2/AES-256 + SHA-256 MAC,
#                                                 which rcodesign 0.29 rejects as "incorrect password"
#   -passout 'pass:'      empty password (lab default). For a shared host use 'pass:<secret>' and export
#                         MACOS_SIGN_P12_PASSWORD=<secret> - build-env.sh passes it via a 0600 temp file
#   -name                 friendly name; what Keychain Access would show if the p12 is ever imported on a Mac
rm codesign.key codesign.crt          # the p12 is the only copy that matters; back IT up
cp meshagent-codesign.p12 meshagent-codesign.p12.$(date +%Y%m%d).bak

# 3. Check it
openssl pkcs12 -in meshagent-codesign.p12 -passin 'pass:' -nokeys | openssl x509 -noout -subject -enddate -ext extendedKeyUsage
$BUILDROOT/bin/rcodesign sign --p12-file meshagent-codesign.p12 --p12-password '' /tmp/any-macho && echo usable
```

Variants: `-newkey rsa:3072` instead of the two `ec` options for an RSA key; `-days 730` if you
want forced rotation; on a Mac, Keychain Access → Certificate Assistant → "Create a Certificate"
with type *Code Signing* produces an equivalent self-signed identity (export it as .p12 with a
password, then convert with `openssl pkcs12` as in step 2, since Keychain exports PBES2 too).
The p12 must be the **same on every build host** (see rules above) - generate once, copy, never
regenerate unless rotating on purpose.

**Getting a real Apple-issued Developer ID Application certificate.** Requires a paid Apple
Developer Program membership (Developer ID Program enrollment specifically). rcodesign can
generate the keypair and CSR without a Mac; only the CSR upload is a manual step through Apple's
web UI.

```sh
umask 077; mkdir -p $BUILDROOT/private/codesign && cd $BUILDROOT/private/codesign

# 1. Generate a keypair + CSR locally (no Apple interaction yet). rcodesign's
#    generate-certificate-signing-request needs an existing key to sign the CSR with,
#    so make one first via generate-self-signed-certificate - profile=developer-id-application
#    just sets the right EKU/extensions on the throwaway cert; it's discarded, only the key matters.
$BUILDROOT/bin/rcodesign generate-self-signed-certificate \
    --algorithm ecdsa --profile developer-id-application \
    --person-name "PTR-inc" --team-id <YOUR_APPLE_TEAM_ID> \
    --pem-filename devid-temp

$BUILDROOT/bin/rcodesign generate-certificate-signing-request \
    --pem-file devid-temp.key --csr-pem-file devid.csr.pem
```

Upload `devid.csr.pem` to Apple: developer.apple.com → Account → Certificates, Identifiers &
Profiles → Certificates → **+** → *Developer ID Application* → upload the CSR → download the
issued certificate (`developerID_application.cer`, DER).

Combine Apple's cert with the original private key into a p12, same legacy-PBE flags as above
because rcodesign's p12 parser rejects OpenSSL 3's default container:

```sh
openssl x509 -inform DER -in developerID_application.cer -out devid.crt.pem

# Fetch Apple's intermediate so the signature carries the full chain (Gatekeeper needs it).
# Developer ID Application/Installer certs chain through "Developer ID Certification Authority" -
# a DIFFERENT intermediate from the WWDR (Worldwide Developer Relations) ones used for App
# Store/development certs. Using the wrong one is the #1 cause of a cert showing "not trusted"
# even though Apple genuinely issued it. Check which signed yours first:
openssl x509 -inform DER -in developerID_application.cer -noout -issuer
# "Developer ID Certification Authority" with no generation suffix, or "G1" -> DeveloperIDCA.cer (expires 2027)
# "Developer ID Certification Authority G2" -> DeveloperIDG2CA.cer (expires 2031, current default)
curl -sSL -o DeveloperIDG2CA.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
openssl x509 -inform DER -in DeveloperIDG2CA.cer -out DeveloperIDG2CA.pem

openssl pkcs12 -export -inkey devid-temp.key -in devid.crt.pem -certfile DeveloperIDG2CA.pem \
    -name 'MeshAgent Developer ID (PTR-inc)' \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout 'pass:<a real password this time>' -out meshagent-codesign.p12

rm devid-temp.key devid-temp.crt devid.csr.pem devid.crt.pem DeveloperIDG2CA.*
cp meshagent-codesign.p12 meshagent-codesign.p12.$(date +%Y%m%d).bak
```

Drop it in place - same path `make macos` already expects, so no makefile change:

```sh
export MACOS_SIGN_P12=$BUILDROOT/private/codesign/meshagent-codesign.p12
export MACOS_SIGN_P12_PASSWORD='<the password you set above>'
```

Verify: `$BUILDROOT/bin/rcodesign sign --p12-file $MACOS_SIGN_P12 --p12-password-file
<(printf '%s' "$MACOS_SIGN_P12_PASSWORD") --code-signature-flags runtime /tmp/any-macho && echo usable`

Same rules as the self-signed identity apply: copy this exact `.p12` to every build host, never
regenerate, back it up - losing it re-prompts every deployed agent for TCC permissions.

**Signing an unsigned (or stripped/stale-signature) binary by hand.** Symptom on Apple Silicon:
`Killed: 9` before `main`, or `codesign -v` reporting "invalid signature" / "code has no
resources but signature indicates they must be present". Either tool below fixes it; nothing is
imported into any keychain on the Mac.

```sh
# Check first
codesign -dv --verbose=2 build/osx-arm-64/meshagent_osx-arm-64      # "code object is not signed at all" or details
codesign --verify --verbose build/osx-arm-64/meshagent_osx-arm-64   # silent = valid

# 1. On a Mac, ad-hoc (Apple's own tool, no identity, no download):
codesign --force --sign - --options runtime build/osx-arm-64/meshagent_osx-arm-64

# 2. On a Mac or Linux, with the project's identity (same signature `make macos` produces):
$BUILDROOT/bin/rcodesign sign --p12-file $BUILDROOT/private/codesign/meshagent-codesign.p12 \
    --p12-password '' --code-signature-flags runtime build/osx-arm-64/meshagent_osx-arm-64
#    (a Developer ID .p12 instead: add --p12-password-file <0600 file>; empty passwords must
#     go via --p12-password '' - rcodesign refuses an empty password file)

# 3. Ad-hoc with rcodesign (Linux or Mac, no identity):
$BUILDROOT/bin/rcodesign sign build/osx-arm-64/meshagent_osx-arm-64

# Verify
$BUILDROOT/bin/rcodesign verify build/osx-arm-64/meshagent_osx-arm-64     # or codesign --verify on a Mac
```

Rules: sign **after** the last modification — `strip`, `lipo`, `install_name_tool`, even
`chmod`-preserving copies are fine but any byte change invalidates the signature. A universal
binary is signed per slice by `lipo -create` inputs, then re-signed once after `lipo`. Use option
2, not 1, for anything that will self-update on a machine where KVM permissions were already
granted — ad-hoc has a different designated requirement every time and TCC re-prompts. If the
Mac already ran an *unsigned* copy and shows the "cannot be opened" dialog for a browser
download, that is Gatekeeper's quarantine flag, not the signature: `xattr -d
com.apple.quarantine build/osx-arm-64/meshagent_osx-arm-64` (or install via the MeshCentral script, which never
sets it).

**Notarization.** Signing with a Developer ID identity (above) stops Gatekeeper from calling the
binary "unidentified developer"; notarization is the separate, additional step Apple requires
before it drops the quarantine warning entirely for something downloaded via a browser. It needs
an App Store Connect API key, not the Developer ID `.p12` from signing.

- Requires a **real Developer ID Application** signature already on the binary — Apple's Notary
  service rejects ad-hoc or self-signed submissions outright, and rejects a binary signed without
  `--code-signature-flags runtime` (the hardened runtime flag `macos_sign` in `build-env.sh`
  already passes — see "Code signing" above).
- **Input format**: Apple's Notary API only accepts a `.zip`, `.dmg`, or `.pkg` — never a bare
  Mach-O executable. `rcodesign notary-submit` does not repackage the input for you, so a loose
  agent binary (what `make macos` produces) must be zipped first.
- **Stapling** (`--staple`, embedding the ticket directly in the artifact so Gatekeeper can check
  it offline) only works on the container formats Apple recognizes — an `.app` bundle, `.dmg`, or
  `.pkg` — **not** a bare executable, even inside a zip. Notarizing a zipped loose binary still
  gets it into Apple's notarization database (an *online* Gatekeeper check at first launch will
  succeed), but the ticket cannot be stapled to the executable itself. If an offline-capable first
  launch is required, ship the agent inside a `.pkg` installer instead of a loose binary, and
  staple that. *(Not verified against a live Apple submission from this checkout — recorded from
  Apple/rcodesign's documented format constraints, not a completed run here.)*

```sh
# 1. Create an App Store Connect API Key (once): appstoreconnect.apple.com/access/api ->
#    "Keys" tab -> generate one with at least the "Developer" role -> download the .p8 private key
#    (Apple only offers it once) and note the Issuer ID (UUID) and Key ID shown next to it.

# 2. Bundle the 3 components into the single JSON file rcodesign wants for every notary-* command.
umask 077
$BUILDROOT/bin/rcodesign encode-app-store-connect-api-key \
    <ISSUER_ID> <KEY_ID> /path/to/AuthKey_<KEY_ID>.p8 \
    --output-path $BUILDROOT/private/codesign/appstoreconnect-key.json

# 3. Zip the already Developer-ID-signed binary - Apple's Notary API does not accept a bare Mach-O.
ditto -c -k --keepParent build/osx-arm-64/meshagent_osx-arm-64 meshagent_osx-arm-64.zip

# 4. Submit, wait for Apple's scan, and staple in one call (staple is a no-op warning here, since
#    the input is a zip of a loose binary, not an app/dmg/pkg - see the caveat above).
$BUILDROOT/bin/rcodesign notary-submit \
    --api-key-file $BUILDROOT/private/codesign/appstoreconnect-key.json \
    --staple \
    meshagent_osx-arm-64.zip

# Alternative: submit without --wait, then poll separately (useful in CI to avoid a long-blocking step):
$BUILDROOT/bin/rcodesign notary-submit --api-key-file $BUILDROOT/private/codesign/appstoreconnect-key.json meshagent_osx-arm-64.zip
#   -> prints a submission ID
$BUILDROOT/bin/rcodesign notary-wait --api-key-file $BUILDROOT/private/codesign/appstoreconnect-key.json <SUBMISSION_ID>
$BUILDROOT/bin/rcodesign notary-log  --api-key-file $BUILDROOT/private/codesign/appstoreconnect-key.json <SUBMISSION_ID>   # full Apple scan report on rejection
```

Keep `appstoreconnect-key.json` as secret as the signing `.p12` - it grants API access to the
Apple Developer account, not just notarization. In CI, supply it the same way as `MACOS_SIGN_P12`
(a secret written to a file, never committed).

## Doing it natively on a Mac

Everything above works from Linux via `rcodesign`/`openssl`, which is what CI and this repo's
build hosts use. On an actual Mac with Xcode's command line tools, the built-in tools
(`security`, `codesign`, `xcrun notarytool`, `xcrun stapler`) can do the whole thing instead,
using the login Keychain instead of a loose `.p12` file. Only the CSR→certificate exchange still
requires a round trip to developer.apple.com, same as the Linux path.

**1. Generate the CSR and get the certificate.** Two ways to reach the same result:

- *Keychain Access (fully manual):* Keychain Access → menu bar **Keychain Access → Certificate
  Assistant → Request a Certificate From a Certificate Authority…** → fill in the email/name,
  choose **"Saved to disk"** (leave "CA Email Address" blank - nothing is emailed), and check
  **"Let me specify key pair information"** if you want to pick RSA vs EC. This writes a
  `CertificateSigningRequest.certSigningRequest` file and silently creates the matching private
  key in your login Keychain (marked non-exportable-looking but it *is* exportable in step 3).
  Upload that file at developer.apple.com → Account → Certificates, Identifiers & Profiles →
  Certificates → **+** → *Developer ID Application* → download the issued `.cer`, then
  double-click it - Keychain Access imports it and pairs it with the private key it already has
  from the CSR step. `security find-identity -v -p codesigning` should now list it.

- *Xcode (automatic, no manual CSR handling):* Xcode → Settings → **Accounts** → select your
  Apple ID/team → **Manage Certificates…** → **+** → *Developer ID Application*. Xcode generates
  the key, CSR, uploads it, and installs the resulting certificate into the login Keychain in one
  step. Requires the account to already have Developer ID Program enrollment; Xcode surfaces an
  error there rather than a route to enroll.

**Troubleshooting a downloaded certificate that doesn't work.** Three distinct symptoms, three
different causes - don't assume they're the same bug:

- **Importing into iCloud Keychain fails/errors.** Expected, not a bug: code-signing certificates
  aren't a supported iCloud Keychain item type (that store is for passwords/passkeys/autofill).
  Always import into **login** (or **System**), never iCloud.
- **`security find-identity -v -p codesigning` still only shows the old self-signed identity**,
  even after importing the new `.cer`. An "identity" is a certificate **paired with its matching
  private key in the same keychain** - if the CSR's private key was generated in the *login*
  keychain (the normal case) but the downloaded certificate got imported into the *System*
  keychain instead, they never pair and no new identity appears. Re-import the `.cer` into the
  same keychain as the key (Keychain Access → File → Import Items… → check the destination
  keychain dropdown).
- **The imported certificate's Keychain Access "Get Info" panel says "not trusted".** Almost
  always a missing intermediate, not a bad certificate. Developer ID Application/Installer certs
  chain through Apple's **"Developer ID Certification Authority"** intermediate - a *different*
  one from the WWDR (Worldwide Developer Relations) intermediates used for App Store/development
  certs, and the one most walkthroughs mention by reflex. Download and double-click-import the
  matching one (check "Issued by" on the cert first):
  `https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer` (current, expires 2031) or
  `DeveloperIDCA.cer` (older G1, expires 2027) - into the same keychain as the leaf cert and key.
  Trust should resolve immediately once macOS can walk the chain leaf → Developer ID CA → Apple
  Root CA (already trusted, built into the OS).

**2. Export a `.p12` for other build hosts (optional).** Only needed if this identity should also
be usable from `rcodesign` on a non-Mac build host, or copied to another Mac. In Keychain Access,
select **both** the certificate and its private key (expand the certificate's disclosure triangle,
click the cert, cmd-click the key) → right-click → **Export 2 items…** → save as `.p12`, set a
password. Keychain's export uses OpenSSL 3's PBES2 container, which `rcodesign`'s p12 parser
rejects - reprocess it exactly as step 2 of "Generating a code-signing certificate by hand" above
(`openssl pkcs12 -in <exported>.p12 ... | openssl pkcs12 -export ... -keypbe PBE-SHA1-3DES
-certpbe PBE-SHA1-3DES -macalg sha1 ...`) before handing it to `rcodesign` or dropping it at
`MACOS_SIGN_P12`.

**3. Sign with `codesign`, using the Keychain identity directly** (no `.p12` file needed on the
signing Mac itself):

```sh
# Find the exact identity string (or its SHA-1 hash) once:
security find-identity -v -p codesigning

codesign --force --sign "Developer ID Application: PTR-inc (TEAMID)" \
    --options runtime --timestamp \
    build/osx-arm-64/meshagent_osx-arm-64
#   --timestamp   secure timestamp from Apple's timestamp server (needs network) - required for
#                 notarization to accept the signature; omit only for a purely local/offline test
```

**4. Notarize with `xcrun notarytool`** (built into Xcode's command line tools, replaces
`rcodesign notary-submit`/`notary-wait`/`notary-log` one-for-one; same App Store Connect API key
from the "Notarization" section above, or an app-specific password + Apple ID instead):

```sh
# Store credentials once, reused by name afterwards:
xcrun notarytool store-credentials "meshagent-notary" \
    --key /path/to/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#   (or: --apple-id you@example.com --team-id <TEAMID> --password <app-specific password>,
#    generated at appleid.apple.com → Sign-In and Security → App-Specific Passwords)

ditto -c -k --keepParent build/osx-arm-64/meshagent_osx-arm-64 meshagent_osx-arm-64.zip
xcrun notarytool submit meshagent_osx-arm-64.zip --keychain-profile "meshagent-notary" --wait
#   prints "Accepted" or "Invalid"; on Invalid, fetch the log:
xcrun notarytool log <SUBMISSION_ID> --keychain-profile "meshagent-notary"

# Stapling - same container-format limitation as rcodesign: works on a .app/.pkg/.dmg, not a bare
# Mach-O or a zip of one. Only run this if the notarized asset is one of those container types.
xcrun stapler staple SomeInstaller.pkg
xcrun stapler validate SomeInstaller.pkg
```
