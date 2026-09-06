#Requires -Version 5.1
<#
.SYNOPSIS
  Check the committed OpenSSL archives in openssl\<version>\windows-<platform>[-debug]\lib\*.lib
  against the MSVC toolset that is about to link them. Exits 1 only for a difference that
  breaks the link or the binary. Everything else is reported as a warning.

.DESCRIPTION
  Parses the COFF archives directly, without lib.exe or dumpbin, and reports the OpenSSL
  version, the Configure platform and compiler strings and the object count of each archive.
  The version comes from openssl\VERSION unless -Version is given.
  A machine type other than the one the target directory promises is fatal.
  A release archive that pulls LIBCMTD, or a -debug one that pulls LIBCMT, is fatal because the CRTs would be mixed.
  LTCG objects built with /GL by a different compiler build are fatal, since they are build-locked (LNK1257).
  A different @comp.id compiler build is only a warning, because plain C objects link across MSVC versions.
  The current compiler is found through MSBuild with -getProperty VCToolsInstallDir. Pass -ClExe to skip that.

.EXAMPLE
  pwsh openssl\build\windows\toolset-check.ps1 -Platform x64 -Toolset v145
#>
[CmdletBinding()]
param(
    [ValidateSet('x86', 'Win32', 'x64', 'ARM64')] [string] $Platform = 'x64',
    # Empty means the default toolset, whichever MeshAgent.Configuration.props pins. The pin
    # check below applies only to that one, since any other toolset is deliberately not pinned.
    [string] $Toolset = '',
    [string] $ClExe = '',
    [string] $Version = '',
    [string] $Repo = ''
)
$ErrorActionPreference = 'Stop'

# Resolved here, not as the parameter's default: [CmdletBinding()] makes this an advanced script,
# and PowerShell leaves $PSScriptRoot empty while binding an advanced script's parameters under
# powershell -File. It is populated normally by the time the body runs.
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }

# Which toolset counts as the default is the props file's call, not a constant repeated here.
$__cfg = Join-Path $Repo 'MeshAgent.Configuration.props'
$DefaultToolset = if ((Test-Path $__cfg) -and ((Get-Content $__cfg -Raw) -match '<MeshDefaultToolset>\s*(v[0-9]+)\s*</MeshDefaultToolset>')) { $Matches[1] } else { '' }
if (-not $Toolset) { $Toolset = $DefaultToolset }

# Inspect-Archive, the COFF walker, lives in env.ps1 and is shared with build.ps1. Dot-sourcing
# env.ps1 overwrites $script:Repo with its own derivation, so the -Repo parameter is restored.
$__repo = $Repo
. (Join-Path $PSScriptRoot 'env.ps1')
$Repo = $__repo

if (-not $Version) {
    $versionFile = Join-Path $Repo 'openssl\VERSION'
    if (-not (Test-Path $versionFile)) { Write-Host "FATAL: $versionFile is missing and no -Version was given"; exit 1 }
    $Version = (Get-Content $versionFile -Raw) -replace '\s', ''
}

$fatal = New-Object System.Collections.Generic.List[string]
$warn  = New-Object System.Collections.Generic.List[string]

# Which archives this platform links, and what they must contain. The release and the
# -debug prefix both belong to the platform, and the directory name says which CRT is expected.
$arch    = switch ($Platform) { 'x86' { 'x86' } 'Win32' { 'x86' } 'x64' { 'x64' } 'ARM64' { 'arm64' } }
$machine = switch ($Platform) { 'x86' { 0x14c } 'Win32' { 0x14c } 'x64' { 0x8664 } 'ARM64' { 0xaa64 } }
$msbuildPlatform = if ($Platform -eq 'x86') { 'Win32' } else { $Platform }
$prefixRoot = Join-Path $Repo "openssl\$Version"
$libs = New-Object System.Collections.Generic.List[object]
foreach ($target in @("windows-$arch", "windows-$arch-debug")) {
    foreach ($base in @('libcrypto', 'libssl')) {
        $path = Join-Path $prefixRoot "$target\lib\$base.lib"
        if (-not (Test-Path $path)) { $fatal.Add("missing archive $path"); continue }
        $libs.Add([pscustomobject]@{ Name = "$target\$base.lib"; FullName = $path; WantDebug = $target.EndsWith('-debug') })
    }
}
if ($libs.Count -eq 0) { Write-Host "FATAL: no windows-$arch archives under $prefixRoot"; exit 1 }

# The compiler that will link them.
$clBuild = $null; $clVersion = ''
if (-not $ClExe) {
    $proj = Join-Path $Repo 'meshservice\MeshService-2022.vcxproj'
    $msbuild = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($msbuild) {
        $toolsDir = (& $msbuild.Source $proj -nologo -getProperty:VCToolsInstallDir "-p:Configuration=Release" "-p:Platform=$msbuildPlatform" "-p:MeshToolset=$Toolset" 2>$null | Select-Object -Last 1)
        $hostDir = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'HostARM64' } else { 'Hostx64' }
        $target = switch ($Platform) { 'x86' { 'x86' } 'Win32' { 'x86' } 'x64' { 'x64' } 'ARM64' { 'arm64' } }
        if ($toolsDir) { $ClExe = Join-Path $toolsDir "bin\$hostDir\$target\cl.exe" }
        if ($ClExe -and -not (Test-Path $ClExe)) { $ClExe = Get-ChildItem -Path (Join-Path $toolsDir 'bin') -Recurse -Filter cl.exe -ErrorAction SilentlyContinue | Where-Object { $_.Directory.Name -eq $target } | Select-Object -First 1 -ExpandProperty FullName }
    }
}
if ($ClExe -and (Test-Path $ClExe)) {
    # cl prints its banner on stderr, which Windows PowerShell 5.1 turns into a terminating error
    # under ErrorActionPreference Stop, so the capture goes through cmd.exe instead.
    $banner = (& cmd.exe /c "`"$ClExe`" 2>&1" | Out-String)
    if ($banner -match 'Version (\d+)\.(\d+)\.(\d+)') { $clVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])"; $clBuild = [int]$Matches[3] }
}
if (-not $clBuild) { $warn.Add("could not determine the current cl.exe build (msbuild/-getProperty or -ClExe) - compiler-build comparisons skipped") }

# The default toolset is pinned to one MSVC Major.Minor in MeshAgent.Configuration.props. Linking
# with any other version is a hard failure, the same as a wrong CRT: the fix is to install it.
$pinFile = Join-Path $Repo 'MeshAgent.Configuration.props'
$pin = if ((Test-Path $pinFile) -and ((Get-Content $pinFile -Raw) -match '<MeshVcToolsVersion>\s*([0-9]+(\.[0-9]+){1,2})\s*</MeshVcToolsVersion>')) { $Matches[1] } else { '' }
# A full pin is the whole folder name, so the path has a separator after it; a Major.Minor pin
# has the patch level after it. Either way the next character ends the version.
if ($pin -and $Toolset -eq $DefaultToolset -and $ClExe -and $ClExe -notmatch ('\\MSVC\\' + [regex]::Escape($pin) + '(\.|\\)')) {
    $fatal.Add("the linking toolset is $ClExe but MeshAgent.Configuration.props pins MSVC $pin - install the '$Toolset C++ build tools ($pin)' component (env.ps1: Install-BuildRootWindows -VsComponents)")
}

# Report.
$cl = if ($clVersion) { "cl $clVersion" } else { 'cl unknown' }
Write-Host ("OpenSSL {0} archives for {1} ({2}, {3}) under {4}:" -f $Version, $Platform, $Toolset, $cl, $prefixRoot)
"{0,-36} {1,-16} {2,5} {3,5} {4,-8} {5,-14} {6}" -f 'FILE', 'VERSION', 'OBJS', 'LTCG', 'MACHINE', 'CL-BUILD', 'CRT-DIRECTIVES' | Write-Host
foreach ($lib in $libs) {
    try { $r = Inspect-Archive $lib.FullName } catch { $fatal.Add("$($lib.Name): $_"); continue }
    $wantDebug = $lib.WantDebug
    $machList = ($r.machines.Keys | ForEach-Object { '0x{0:x}' -f $_ }) -join ','
    $buildList = ($r.builds.Keys | Sort-Object | ForEach-Object { "$_" }) -join ','
    $crt = ($r.defaultlibs.Keys | Where-Object { $_ -match '^(lib|msvc)' }) -join ','
    "{0,-36} {1,-16} {2,5} {3,5} {4,-8} {5,-14} {6}" -f $lib.Name, $r.version, $r.objs, $r.ltcg, $machList, $buildList, $(if ($crt) { $crt } else { '-' }) | Write-Host
    Write-Host ("{0,-36} platform: {1}" -f '', $r.platform)
    Write-Host ("{0,-36} compiler: {1}" -f '', $r.compiler)

    if ($r.objs -eq 0) { $fatal.Add("$($lib.Name): empty archive"); continue }
    if ($r.version -ne "OpenSSL $Version") { $warn.Add("$($lib.Name): archive reports '$($r.version)' but lives under openssl\$Version") }
    foreach ($mk in $r.machines.Keys) { if ($mk -ne $machine) { $fatal.Add(("{0}: object machine 0x{1:x}, expected 0x{2:x} for {3}" -f $lib.Name, $mk, $machine, $Platform)) } }
    foreach ($dl in $r.defaultlibs.Keys) {
        if ($dl -match '^(libcmt|libucrt|libvcruntime)d\.lib$' -and -not $wantDebug) { $fatal.Add("$($lib.Name): release (/MT) archive pulls the debug CRT via /DEFAULTLIB:$dl") }
        if ($dl -match '^(libcmt|libucrt|libvcruntime)\.lib$' -and $wantDebug)      { $fatal.Add("$($lib.Name): -debug (/MTd) archive pulls the release CRT via /DEFAULTLIB:$dl") }
        if ($dl -match '^msvcrt')                                                    { $fatal.Add("$($lib.Name): built /MD (/DEFAULTLIB:$dl) - the agent is /MT") }
    }
    if ($clBuild) {
        $other = @($r.builds.Keys | Where-Object { $_ -ne $clBuild })
        if ($r.ltcg -gt 0 -and $other.Count -gt 0) { $fatal.Add("$($lib.Name): $($r.ltcg) LTCG (/GL) objects from compiler build $($other -join ',') but linking with $clBuild - LTCG objects are build-locked") }
        elseif ($r.ltcg -gt 0 -and $r.builds.Count -eq 0) { $warn.Add("$($lib.Name): $($r.ltcg) LTCG (/GL) objects and no @comp.id to compare with - the link will decide") }
        elseif ($other.Count -gt 0) { $warn.Add("$($lib.Name): compiled by MSVC build $($other -join ','), linking with $clBuild (plain objects, fine - rebuild to align)") }
    }
    if ($r.nocompid -gt 0 -and $r.nocompid -gt [math]::Max(40, $r.objs / 4)) { $warn.Add("$($lib.Name): $($r.nocompid) of $($r.objs) objects carry no @comp.id (expected only for the NASM objects)") }
}

Write-Host ''
foreach ($w in $warn)  { Write-Host "WARNING: $w" }
foreach ($f in $fatal) { Write-Host "FATAL:   $f" }
if ($fatal.Count) { Write-Host "RESULT: FATAL - $($fatal.Count) blocking difference(s)"; exit 1 }
Write-Host ("RESULT: OK ({0} warning(s))" -f $warn.Count)
exit 0
