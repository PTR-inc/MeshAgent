# MeshAgent OpenSSL Windows build environment - vendored copy, tracked in git.
#
# Dot-source this, do not run it directly:  . openssl\libstatic\build\windows\env.ps1
#
# Native sibling of openssl/libstatic/build/env.sh: MSVC's Configure targets
# and nmake need a real vcvarsall.bat environment, not just Git Bash.

$script:BrWindowsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:BrScripts = Split-Path -Parent $BrWindowsDir
$script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $BrScripts))

if (-not $env:BUILDROOT) { $env:BUILDROOT = Join-Path $env:LOCALAPPDATA 'meshagent-buildroot' }
$env:BR_DOWNLOADS = Join-Path $env:BUILDROOT 'downloads'
$env:BR_WORK = Join-Path $env:BUILDROOT 'work-windows'

# Keep in sync with env.sh - same pinned release, same tarball, same source.
$script:OpenSslVersion = '1.1.1w'
$script:OpenSslSha256 = 'cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8'
$script:OpenSslTarball = Join-Path $env:BR_DOWNLOADS "openssl-$OpenSslVersion.tar.gz"
$script:OpenSslUrl = "https://github.com/openssl/openssl/releases/download/OpenSSL_$($OpenSslVersion -replace '\.', '_')/openssl-$OpenSslVersion.tar.gz"

# Same flags.txt env.sh reads - single source of truth for both.
$script:OsslFlags = (Get-Content (Join-Path $BrScripts 'flags.txt')) -join ' '

function Get-VsInstallPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $path) { return $null }
    return $path
}

function Get-VcVarsAllPath {
    $vs = Get-VsInstallPath
    if (-not $vs) { return $null }
    $p = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
    if (Test-Path $p) { return $p } else { return $null }
}

function Get-Arm64ToolsetVersion {
    # A newest-installed MSVC toolset can have an incomplete arm64 lib set
    # (present dir, missing setargv.obj/CRT) - pick one that's actually complete.
    $vs = Get-VsInstallPath
    if (-not $vs) { return $null }
    $mscvDir = Join-Path $vs 'VC\Tools\MSVC'
    $best = Get-ChildItem $mscvDir -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $setargv = Join-Path $_.FullName 'lib\arm64\setargv.obj'
            (Test-Path $setargv) -and (Test-Path (Join-Path $_.FullName 'bin\HostX64\arm64\cl.exe'))
        } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $best) { return $null }
    # vcvarsall's -vcvars_ver wants Major.Minor (e.g. "14.44"), not the full
    # three-part folder name (e.g. "14.44.35207").
    if ($best.Name -match '^(\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Get-NasmPath {
    $cmd = Get-Command nasm.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'bin\NASM\nasm.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Get-PerlPath {
    # OpenSSL's Configure refuses a Cygwin perl - Git for Windows' bundled
    # perl.exe is exactly that, so skip it even though it's usually on PATH.
    $portable = Join-Path $env:LOCALAPPDATA 'meshagent-buildroot\tools\strawberry-perl\perl\bin\perl.exe'
    if (Test-Path $portable) { return $portable }

    $cmd = Get-Command perl.exe -ErrorAction SilentlyContinue -All
    foreach ($c in $cmd) {
        $ver = & $c.Source -e "print $^O" 2>$null
        if ($ver -and $ver -ne 'cygwin') { return $c.Source }
    }
    return $null
}

# Read-only report - confirms every input this build needs is present,
# without building anything. Mirrors env.sh's br_check().
function Test-BuildRootWindows {
    $ok = $true

    if (Test-Path $script:OpenSslTarball) {
        Write-Host "  openssl tarball : $script:OpenSslTarball"
    } else {
        Write-Host "  MISSING openssl tarball: $script:OpenSslTarball (fetch it, see README.md)"
        $ok = $false
    }

    $vcvarsall = Get-VcVarsAllPath
    if ($vcvarsall) {
        Write-Host "  vcvarsall.bat   : $vcvarsall"
    } else {
        Write-Host "  MISSING: no Visual Studio install with the x86/x64 VC++ toolset found"
        $ok = $false
    }

    $vs = Get-VsInstallPath
    if ($vs) {
        $arm64Tools = Join-Path $vs 'VC\Tools\MSVC'
        $hasArm64 = (Get-ChildItem $arm64Tools -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'bin\HostX64\arm64\cl.exe') }) -ne $null
        if ($hasArm64) {
            Write-Host "  ARM64 toolset   : present"
        } else {
            Write-Host "  MISSING: MSVC v143 - VS 2022 C++ ARM64 build tools (needed for the arm64 target)"
            $ok = $false
        }
    }

    $perl = Get-PerlPath
    if ($perl) {
        Write-Host "  perl            : $perl"
    } else {
        Write-Host "  MISSING: perl.exe (Configure needs it - Git for Windows or Strawberry Perl both work)"
        $ok = $false
    }

    $nasm = Get-NasmPath
    if ($nasm) {
        Write-Host "  nasm            : $nasm  (asm-enabled x86/x64 targets)"
    } else {
        Write-Host "  nasm not found  : x86/x64 targets will fall back to -no-asm (see README.md to install)"
    }

    if ($ok) { Write-Host "  all required inputs present" }
    return $ok
}

Write-Host "BUILDROOT=$env:BUILDROOT  (openssl $OpenSslVersion, repo $Repo)"
