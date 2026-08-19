# OpenSSL Windows build scripts (vendored)

Native-Windows sibling of `openssl/libstatic/build/`'s WSL/Linux buildroot. MSVC's `Configure`
and `nmake` need a real `vcvarsall.bat` developer environment, not Git Bash.

Recipe matches `.github/workflows/build-openssl-libs.yml`'s `windows` job: same `Configure`
targets, same shared [`../flags.txt`](../flags.txt) flags, NASM-enabled asm for x86/x64 only, and
the same post-`Configure` `/MD`→`/MT` makefile patch for a static CRT.

## Quick start

```powershell
. openssl\libstatic\build\windows\env.ps1
Test-BuildRootWindows                          # confirms VS/perl/nasm/tarball are all present

# fetch+verify the source tarball once (same pin as env.sh / fetch-openssl)
New-Item -ItemType Directory -Force -Path $env:BR_DOWNLOADS | Out-Null
Invoke-WebRequest -Uri $script:OpenSslUrl -OutFile $script:OpenSslTarball
if ((Get-FileHash $script:OpenSslTarball -Algorithm SHA256).Hash.ToLower() -ne $script:OpenSslSha256) {
    throw "checksum mismatch - delete $($script:OpenSslTarball) and retry"
}

openssl\libstatic\build\windows\build.ps1 x64
openssl\libstatic\build\windows\build.ps1 all
openssl\libstatic\build\windows\verify.ps1      # read-only report over whatever's already staged
```

## Prerequisites

- Visual Studio with the **MSVC v143 - VS 2022 C++ x64/x86 build tools** component (required), and
  **MSVC v143 - VS 2022 C++ ARM64 build tools** (only if building the `arm64`/`arm64-debug` targets).
  `Test-BuildRootWindows` checks both.
- `perl.exe` on `PATH` - Git for Windows ships one (`C:\Program Files\Git\usr\bin\perl.exe`);
  Strawberry Perl (what CI uses, via `choco install strawberryperl`) also works.
- NASM, for asm-enabled x86/x64 builds (AES-NI/SHA-NI/bignum throughput). Without it, `build.ps1`
  falls back to `-no-asm` for those targets automatically. Install with `choco install nasm` or
  from <https://www.nasm.us/> - `Get-NasmPath` in `env.ps1` checks `PATH`, then
  `%LOCALAPPDATA%\bin\NASM\nasm.exe` (the non-elevated chocolatey install location).
- ARM64 targets cross-compile from an x64 host (`vcvarsall.bat x64_arm64`) - no ARM64 machine needed.

## What gets staged, and where

Six targets, matching the twelve `.lib` files already committed flat under `openssl/libstatic/`
(no `windows/` subdirectory there - the `.vcxproj` files reference them directly, e.g.
`..\openssl\libstatic\libcrypto64MT.lib`, and this script keeps that path unchanged):

| target | `Configure` | asm | stages to |
|---|---|---|---|
| `x86` | `VC-WIN32` | on (NASM) | `libcrypto32MT.lib` / `libssl32MT.lib` |
| `x86-debug` | `VC-WIN32 --debug` | on (NASM) | `libcrypto32MTd.lib` / `libssl32MTd.lib` |
| `x64` | `VC-WIN64A` | on (NASM) | `libcrypto64MT.lib` / `libssl64MT.lib` |
| `x64-debug` | `VC-WIN64A --debug` | on (NASM) | `libcrypto64MTd.lib` / `libssl64MTd.lib` |
| `arm64` | `VC-WIN64-ARM` | off | `libcryptoARM64.lib` / `libsslARM64.lib` |
| `arm64-debug` | `VC-WIN64-ARM --debug` | off | `libcryptoARM64d.lib` / `libsslARM64d.lib` |

Nothing is staged unless it passes: the OpenSSL version string must be found in the built
`libcrypto.lib` (`OpenSSL 1.1.1w `), and the object count from `lib /list` must match the `ObjCount`
recorded per target in `build.ps1` (566 x86, 576 x64, 553 arm64 - Release and Debug match).

## Relationship to the CI workflow

`.github/workflows/build-openssl-libs.yml`'s `windows` job is the source this was mirrored from -
if the two disagree, treat the workflow as authoritative and fix these scripts to match.
