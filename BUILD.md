# Building MeshAgent

Routing table for the build system. **Where to make a change**, not how the code
works. If you are about to write a version number, a URL, a toolchain path or a
target list into a file, check this page first — it probably belongs somewhere
else, and `openssl/libstatic/build/consistency.sh` will fail the PR if it does.

## Quick start

```sh
./fetch-toolchains.sh                      # provision every fetchable toolchain into $BUILDROOT
make list                                  # every ARCHID, its class, and whether it can build here
make linux ARCHID=6                        # build one agent
openssl/libstatic/build/build.sh list      # every OpenSSL target, its libc, who links it
openssl/libstatic/build/build.sh x86-64    # rebuild one OpenSSL archive and stage it
openssl/libstatic/verify                   # audit every committed archive
openssl/libstatic/build/consistency.sh     # the anti-drift gate CI runs
```

`$BUILDROOT` (default `/opt/buildroot`) holds the multi-GB toolchains, sysroots
and downloads. Everything in the repo is small and tracked.

## Build output layout

Everything a build produces lands under `build/` (gitignored), one directory per target and
variant, so nothing is written to the repo root:

```
build/<arch>/                 meshagent_<arch>        stripped binary (what ships)
                              DEBUG_meshagent_<arch>  unstripped copy for valgrind/gdb
                              obj/                    objects + .d deps + .cflags stamp
                              meshagent_<arch>.msh/.db/.log   written by the agent at runtime
build/<arch>-debug/           DEBUG=1 build of the same target
build/<arch>_asan/            ASAN=1 build (phase 7 of test/test-agent.sh)
build/<arch>_nokvm/           the _nokvm ARCHIDs
build/win-<x86|x64|ARM64>-<Configuration>/   MSBuild: MeshService*.exe, MeshConsole*.exe, .pdb, obj/
```

`<arch>` is the makefile's `ARCHNAME` (`make list`). The agent only reads `<exe>.msh`/`.db` next
to itself, so each target keeps its own server config and identity. `make clean` removes every
`build/*/obj`; `make cleanbin` removes the binaries; `rm -rf build` removes it all.

## Windows (MSBuild)

```powershell
msbuild MeshAgent-2022.sln /p:Configuration=Release /p:Platform=x64      # x86 | x64 | ARM64
msbuild MeshAgent-2022.sln /p:Configuration=Release_NoOpenSSL /p:Platform=x64
```

`MeshAgent.sln` (VS2019, `v142`, x86/x64) and `MeshAgent-2022.sln` (VS2022, `v143`, + ARM64) build the
same thing; only the toolset differs. All four projects are
thin: they name the exe base, the `MESH_AGENTID` per platform and their own files, and import
`MeshAgent.Configuration.props` + `MeshAgent.Common.props` from the repo root, which hold the
shared source list, defines, libs, output layout and hardening for every configuration.
Configuration axis: `Debug` | `Release`, optionally `_NoOpenSSL` (`MICROSTACK_NOTLS`, BCrypt
only, no OpenSSL linked). Platform axis: `Win32` (`x86` in the solution) | `x64` | `ARM64` —
picks `MESH_AGENTID`, the `libcrypto<32|64|ARM64>MT[d].lib` pair, and the exe suffix
(`MeshService`, `MeshService64`, `MeshServiceARM64`). Output lands in
`build\win-<x86|x64|ARM64>-<Configuration>\`. Toolset is `v143` everywhere; the linker floor is
Windows 7 SP1 (`/SUBSYSTEM:CONSOLE,6.01`) on x86/x64 and the `/MT` static UCRT keeps it
self-contained. Add `/p:EnableASAN=true` for an ASan build (phase 7 of `test\test-agent.ps1`).

## Dependencies

The agent links two static libs: OpenSSL (see the four sources of truth below) and
libjpeg-turbo (for KVM screen capture — `NOTURBOJPEG=1` to build without it).

Host dev libraries for a native Linux build (X11, jpeg):

```sh
# apt
sudo apt-get install libx11-dev libxtst-dev libxext-dev libjpeg62-dev libxrandr-dev
# yum
sudo yum install libX11-devel libXtst-devel libXext-devel libjpeg-devel libXrandr-devel
# 32-bit on a 64-bit host, additionally:
sudo apt-get install linux-libc-dev:i386 libc6-dev-i386 libjpeg62-dev:i386 libxrandr-dev:i386
# Raspberry Pi cross toolchain (ARCHID=25):
sudo apt-get install libc6-armel-cross libc6-dev-armel-cross binutils-arm-linux-gnueabi libncurses5-dev gcc-arm-linux-gnueabihf
# Alpine Linux (musl, ARCHID=33):
apk add build-base gcc abuild binutils linux-headers libexecinfo-dev bash binutils-doc gcc-doc
```

Building `libturbojpeg.a` from `libjpeg-turbo-1.4.2` source (only needed if the committed
archive under `lib-jpeg-turbo/` doesn't cover your target):

```sh
# Linux 64-bit
./configure && make -j8                                    # -> .libs/libturbojpeg.a
# Linux 32-bit
./configure --build=i686-pc-linux-gnu CFLAGS=-m32 CXXFLAGS=-m32 LDFLAGS=-m32 && make -j8
# macOS, cross-compiled
./configure --host=x86_64-apple-darwin20.0.0 CFLAGS='-arch x86_64'    # Intel
./configure --host=aarch64-apple-darwin20.0.0 CFLAGS='-arch arm64'    # Apple Silicon
```

Add `--with-jpeg8` to any of the above to build against jpeg8 headers instead of jpeg62 (the
default); pass the matching `JPEGVER=v80` when building the agent, and put the resulting `.a`
in the `v80` subfolder next to the default one.

### macOS

`make macos ARCHID=16|29` detects the host: on a Mac it uses Xcode's clang (`gcc -arch ...`),
anywhere else it uses [osxcross](https://github.com/tpoechtrager/osxcross) from
`$BUILDROOT/osxcross` (`OSXCROSS_BIN` in `build-env.sh`). Nothing to pass either way. When the
cross compiler is missing, `make` offers `./fetch-toolchains.sh osxcross`, which builds osxcross -
but the **macOS SDK it needs is Apple-licensed and is never on the public toolchain mirror**. Supply
it yourself, one of:

- `$BUILDROOT/downloads/MacOSX<ver>.sdk.tar.xz` (`OSXCROSS_SDK_VER` in `build-env.sh`), copied
  from a Mac or produced by `build-toolchain-archives.sh --i-have-rights-to-redistribute-this
  Xcode_<ver>_Universal.xip` (output lands in `$BUILDROOT/private/`, kept apart from the
  redistributable archives on purpose);
- an `Xcode_<ver>_Universal.xip` from developer.apple.com in `$BUILDROOT/downloads` - extracted
  on the spot (slow, several GB of scratch);
- `OSXCROSS_SDK_URL=https://...` pointing at a private/access-controlled copy.

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

CI keeps building macOS on macOS runners (`mac-build.yml`, and the macOS rows of the OpenSSL
workflow) - osxcross is the developer-machine path, not the release path.

macOS universal binary: build both ARCHIDs, then combine with `lipo` (on a Mac, or
`$OSXCROSS_BIN/lipo`):

```sh
make macos ARCHID=16   # macOS x86 64 bit
make macos ARCHID=29   # macOS ARM 64 bit
lipo -create -output meshagent_osx-universal-64 build/osx-x86-64/meshagent_osx-x86-64 build/osx-arm-64/meshagent_osx-arm-64
```

## Platform notes

**FreeBSD** — mount procfs (`echo 'proc /proc procfs rw 0 0' >> /etc/fstab`, or `mount -t procfs
proc /proc` for the current session); build with `gmake`, not `make`; installing `bash` is
recommended (`pkg install bash`). KVM is disabled by default — `gmake freebsd ARCHID=30 KVM=1`.

**Linux KVM / X11** — an "Xauthority cannot be found" error or a black login screen usually
means the display manager is running Wayland. Uncomment `WaylandEnable=false` in
`/etc/gdm/custom.conf` (or `/etc/gdm3/custom.conf`) and add `DefaultSession=gnome-xorg.desktop`
under `[daemon]`.

**ChromeOS** — installing the agent needs rootfs verification disabled first:

```sh
sudo su -
cd /usr/share/vboot/bin/
./make_dev_ssd.sh --remove_rootfs_verification   # note the boot partition number in the warning
./make_dev_ssd.sh --remove_rootfs_verification --partitions <ID>
reboot
```

Then copy the agent binary to a path that isn't mounted `noexec` (e.g. `/usr/local`) before
running the installer from there.

## The four sources of truth

| I want to change… | Edit **only** this | Everything else asks it via |
|---|---|---|
| An OpenSSL target: compiler, Configure target, asm, flags, libc, object count, where the archive lands | `openssl/libstatic/build/targets.sh` (`br_target`) | `. targets.sh`, `targets.sh --names / --field` |
| An agent target: ARCHID, toolchain, tuning, hardening, KVM/LMS, BSD release (an ARCHID ≥ 100 is the updated build of ARCHID−100 and reports that classic id to the server) | `makefile` (`ARCH_<id>` blocks) | `make list`, `make print-archids / print-toolchain / print-ossldir / print-bsdrel` |
| A pinned version, path or URL: OpenSSL version, OpenWrt/Bootlin releases, toolchain dirs, mirror URL, symbol regexes | `build-env.sh` | `. build-env.sh` |
| How a toolchain or sysroot is obtained | `fetch-toolchains.sh` | `./fetch-toolchains.sh <component>`, or `BR_FETCH=1 build.sh` via `T_FETCH` |

Windows OpenSSL is its own pair, mirroring the same split:
`openssl/libstatic/build/windows/build.ps1` (`$Targets` — the target table) and
`windows/env.ps1` (environment, prerequisites, downloads). `env.ps1` reads the
OpenSSL version out of `build-env.sh`; it does not pin one.

Configure flags live in `openssl/libstatic/build/flags.txt` — the shared base
set every builder loads. Per-target deltas are **not** separate files: they are
the `T_FLAGS` edit (`"${T_FLAGS/-no-asm/}"` to enable asm) and `T_EXTRA` in the
target's own `targets.sh` case (Windows: the `Asm` field in `build.ps1`'s
`$Targets`). One place per target, next to the comment saying why.

## Rules

1. **Never write a pinned literal into a workflow.** No OpenSSL version, no
   OpenWrt/Bootlin release, no mirror URL, no BSD release. Source `build-env.sh`
   or ask `make`. Check 6 of `consistency.sh` greps for exactly this.
2. **Never restate "which targets are musl."** `T_LIBC` in `targets.sh` is the
   only list. `build.sh`'s symbol gates and `verify` both derive from it. Three
   divergent copies of this list is how a glibc-built `riscv64` archive shipped
   as a musl target in Aug 2026 and was only caught at agent-link time.
3. **CI runs the same scripts you do.** `build-openssl-job.yml` calls
   `build.sh` / `build.ps1`; the agent workflows call `make` and
   `fetch-toolchains.sh`. If CI needs a step your machine does not, that step is
   provisioning, not recipe — and it belongs in `fetch-toolchains.sh` or
   `T_FETCH`.
4. **A new target is picked up automatically.** Adding a case to `br_target`
   plus its name to `BR_ALL_TARGETS` puts it in the CI matrix (via `T_CI`), the
   audit, and `build.sh list`. Adding an `ARCH_` block puts the ARCHID in
   `linux-build.yml`'s matrix. Nothing else needs editing.
5. **Keep built artifacts.** Agent binaries and static libs are expensive;
   rebuild only when you must, and rename rather than delete.

## Anti-drift gate

`openssl/libstatic/build/consistency.sh` (CI job `build-system-checks /
consistency`) fails when:

1. a target is missing `T_DEST`/`T_CONF`, or has an unknown `T_LIBC`/`T_CI`
2. an `openssl/libstatic/*/` archive dir is built by no target — add the target,
   or document the dir in `build/orphans.txt`
3. an ARCHID's `print-ossldir` names a dir no target builds
4. a target is in no CI matrix
5. the pwsh-free grep of `build.ps1`'s `$Targets` (what CI's resolve job uses)
   disagrees with `build.ps1 --names-json` (checked where pwsh exists)
6. a value pinned in `build-env.sh` or an `ARCH_` block is spelled out anywhere
   in `.github/` or `openssl/libstatic/build/`

`openssl/libstatic/verify` separately audits every committed archive: version,
object count (must equal the target's `T_OBJS` — rejects an archive built with a
different recipe than `targets.sh` states), architecture, and the `T_LIBC`-derived symbol gates (glibc-only
symbols must be 0 for musl and uClibc; `getcontext`/`setcontext`/`makecontext`/
`swapcontext` must be 0 for musl, which implements them on no architecture).

## Testing an agent

`test/test-agent.sh` (Windows: `test/test-agent.ps1`) is the **single entry point** for
automated testing. Seven phases: `-info`; every `test/testmodules/*.js` except the `06-*`
group via `test/stress-test.js`; the `06-*` group alone (the known native-crash sections: TLS
reconnect, http/WebSocket server teardown on musl — one crash there cannot take the core
down); the same core run delivered via `-b64exec` (the meshcore path); a connection test
against `<binary>.msh` that
also requires `Launching meshcore` and a persisted identity in `<binary>.db`; valgrind (Linux)
/ Dr. Memory (Windows); and ASan.

```sh
test/test-agent.sh -b build/x86-64/meshagent_x86-64         # auto-detects qemu and build/x86-64_asan/<binary>_asan
make linux ARCHID=6 ASAN=1                                  # build the ASan binary phase 7 wants
test/test-agent.sh -b build/riscv64-generic-musl/meshagent_riscv64-generic-musl --no-connect
test/test-agent.sh -b build/mips24kc/meshagent_mips24kc      # dynamic musl: loader found in $BUILDROOT/toolchains
test/test-agent.sh -b build/osx-arm-64/meshagent_osx-arm-64 --msh test.msh # connection test with this .msh (copied to <binary>.msh)
test/test-agent.sh --ci                                     # CI mode: the known TLS crash is a FAIL (--lenient to keep KNOWN)
```

**Cross-built binaries run under qemu-user automatically.** The driver reads the ELF
`PT_INTERP` to learn the libc (static → nothing needed) and looks for that exact interpreter path
under `QEMU_SYSROOT_ROOTS` — default `$BUILDROOT/toolchains $BUILDROOT/sysroots /usr`, i.e. **the
toolchains `fetch-toolchains.sh` installed** (musl.cc `<triple>/lib`, OpenWrt
`staging_dir/toolchain-*/lib`, Bootlin `…/sysroot/lib`, glibc or musl or uClibc alike) plus the
distro's apt cross dirs. Userlands are never stored under `/usr` by hand — that is dpkg's; a
hand-supplied rootfs goes in `$BUILDROOT/sysroots`. When several roots carry the loader: glibc
prefers the apt dir (newest glibc runs any older-floor build; an older sysroot might not), musl/
uClibc take the newest toolchain by version (an OpenWrt 18.06 SDK's musl 1.1 lacks the
`*_time64` symbols a 24.10-built agent imports). The banner prints `libc : musl (PT_INTERP
/lib/ld-musl-riscv64.so.1), sysroot …`; with no match it aborts listing the roots searched, or
pass `--qemu "qemu-<arch> -L <sysroot>"`. An apt-free host works: the Bootlin glibc sysroots are
found the same way. Mach-O binaries are refused on non-Darwin hosts (no Darwin user-mode
emulator).

**Adding a test = adding a file to `test/testmodules/`** (`exports.name`, `exports.run(check,
deepEqual, done)`); it is picked up automatically. The four legacy upstream scripts in `test/`
(`self-test.js`, `leaktest.js`, `update-test.js`, `authtest.js`) are read-only fixtures that
nothing depends on any more — do not edit them, do not wire them back in.

## Where the long-form docs are

`openssl/libstatic/build/README.md` — the full OpenSSL buildroot reference:
per-target rationale, provisioning recipes, Windows prerequisites, and the
history behind individual target decisions. This page routes; that one explains.
