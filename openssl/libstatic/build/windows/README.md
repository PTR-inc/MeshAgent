# OpenSSL Windows build scripts (vendored)

Native-Windows sibling of `openssl/libstatic/build/`'s WSL/Linux buildroot. MSVC's `Configure`
and `nmake` need a real MSVC developer environment, not Git Bash.

Recipe matches `.github/workflows/build-openssl-libs.yml`'s `windows` job: same `Configure`
targets, same shared [`../flags.txt`](../flags.txt) flags, NASM-enabled asm for x86/x64 only, and
the same post-`Configure` `/MD`→`/MT` makefile patch for a static CRT.

## Quick start

```powershell
. openssl\libstatic\build\windows\env.ps1
Test-BuildRootWindows                          # confirms VS/perl/nasm/tarball are all present
Install-BuildRootWindows                       # fetches whatever that reported missing

openssl\libstatic\build\windows\build.ps1 x64
openssl\libstatic\build\windows\build.ps1 all
openssl\libstatic\build\windows\verify.ps1      # read-only report over whatever's already staged
```

## Prerequisites

`Install-BuildRootWindows` provisions everything below except the MSVC toolsets. A bare call does
the three that need no admin rights - source tarball, perl and NASM - each pinned to a fixed
version, URL and SHA-256 and unpacked under `$BUILDROOT\tools`. Nothing is installed system-wide,
put on `PATH`, or written outside `$BUILDROOT`, so undoing it is `Remove-Item -Recurse $BUILDROOT`.

```powershell
Install-BuildRootWindows                       # tarball + perl + nasm
Install-BuildRootWindows -Nasm                 # just one of them
Install-BuildRootWindows -Force                # re-fetch and re-unpack even if present
Install-BuildRootWindows -VsComponents         # adds the missing MSVC components - prompts, needs admin
Install-BuildRootWindows -BuildRoot D:\br      # somewhere other than the default
```

It asks where to put the buildroot before writing anything, defaulting to the current `$BUILDROOT`
(under the user profile unless overridden) - press Enter to take it. A typed path may be relative
or contain `%VARS%`/`~`; it is expanded and made absolute. `-BuildRoot` answers the question up
front, and `-Force` or a non-interactive session takes the default without asking. The answer
applies to that session only: set `$env:BUILDROOT` before dot-sourcing `env.ps1` to make it stick.

`-VsComponents` is never implied by a bare call: it shells out to the Visual Studio installer
elevated, so it asks first and prints the exact `setup.exe modify` command it intends to run. That
command uses `--passive --norestart`, so the installer shows progress and proceeds without further
interaction (`--norestart` alone is rejected - the installer answers with its usage dialog). It
adds only what is missing, so re-running it is a no-op rather than another trip through the
installer, and because setup.exe can exit before its child finishes, a toolset that is not visible
immediately afterwards means "not done yet" rather than a failed install. Component ids come from the installer's own catalog of what the product offers, which
lists them whether or not they are installed - so this still works when the C++ workload has been
removed outright, which is exactly when it is needed. In a non-interactive session it prints the
command and stops rather than elevating unasked; pass `-Force` to skip the prompt.


- Visual Studio with the **C++ x64/x86 build tools** component (required), and the **C++ ARM64
  build tools** (only if building the `arm64`/`arm64-debug` targets). On VS 2022 these are named
  *MSVC v143 - VS 2022 C++ x64/x86 build tools* and *... ARM64 build tools*.
  `Test-BuildRootWindows` reports the toolset version it picked for each target.
- A **Windows SDK** component. The `C++ ... build tools` components do *not* include one, and an
  install without it gets a working `cl.exe` that then fails on `Cannot open include file:
  'stdlib.h'`. `Test-BuildRootWindows` checks for it per target.
- VS 2017-2022 and VS 2026 (v18) are both supported. `env.ps1` handles the differences: it drives
  `vcvarsall.bat` when present and falls back to `Common7\Tools\VsDevCmd.bat` when it is not (seen
  on a v18 install carrying only versioned v143 toolset packages), matches the vswhere component id
  whether or not it is version-stamped, and pins every target to a toolset verified complete on
  disk (`-vcvars_ver`) rather than trusting the default, which has pointed at a compiler-less
  toolset folder.
- `perl.exe` on `PATH` - Git for Windows ships one (`C:\Program Files\Git\usr\bin\perl.exe`);
  Strawberry Perl (what CI uses, via `choco install strawberryperl`) also works.
- NASM, for asm-enabled x86/x64 builds (AES-NI/SHA-NI/bignum throughput). Without it, `build.ps1`
  falls back to `-no-asm` for those targets automatically. Install with `choco install nasm` or
  from <https://www.nasm.us/> - `Get-NasmPath` in `env.ps1` checks `PATH`, then
  `%LOCALAPPDATA%\bin\NASM\nasm.exe` (the non-elevated chocolatey install location).
- ARM64 targets cross-compile from an x64 host (`x64_arm64`) - no ARM64 machine needed.

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
