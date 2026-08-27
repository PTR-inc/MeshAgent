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
  pwsh openssl\build\windows\toolset-check.ps1 -Platform x64 -Toolset v143
#>
[CmdletBinding()]
param(
    [ValidateSet('x86', 'Win32', 'x64', 'ARM64')] [string] $Platform = 'x64',
    [string] $Toolset = 'v143',
    [string] $ClExe = '',
    [string] $Version = '',
    [string] $Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
)
$ErrorActionPreference = 'Stop'

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
$pin = if ((Test-Path $pinFile) -and ((Get-Content $pinFile -Raw) -match '<MeshVcToolsVersion>\s*([0-9]+\.[0-9]+)\s*</MeshVcToolsVersion>')) { $Matches[1] } else { '' }
if ($pin -and $Toolset -eq 'v143' -and $ClExe -and $ClExe -notmatch ('\\MSVC\\' + [regex]::Escape($pin) + '\.')) {
    $fatal.Add("the linking toolset is $ClExe but MeshAgent.Configuration.props pins MSVC $pin - install 'MSVC v143 - VS 2022 C++ build tools ($pin)' (env.ps1: Install-BuildRootWindows -VsComponents)")
}

# Walk the COFF archive.
function Read-U16([byte[]] $b, [int] $o) { [BitConverter]::ToUInt16($b, $o) }
function Read-U32([byte[]] $b, [int] $o) { [BitConverter]::ToUInt32($b, $o) }

function Inspect-Archive([string] $path) {
    $d = [System.IO.File]::ReadAllBytes($path)
    if ([System.Text.Encoding]::ASCII.GetString($d, 0, 8) -ne "!<arch>`n") { throw "not a COFF archive" }
    $r = [ordered]@{ objs = 0; ltcg = 0; machines = @{}; builds = @{}; nocompid = 0; defaultlibs = @{}; version = 'UNKNOWN'; platform = '-'; compiler = '-' }
    $text = [System.Text.Encoding]::ASCII.GetString($d)
    if ($text -match 'OpenSSL \d+\.\d+\.\d+[a-z]?') { $r.version = $Matches[0] }
    # cversion.c embeds the Configure target and compiler line as NUL-terminated strings.
    if ($text -match 'platform: ([^\x00]+)') { $r.platform = $Matches[1].Trim() }
    if ($text -match 'compiler: ([^\x00]+)') { $r.compiler = $Matches[1].Trim() }
    $off = 8
    while ($off + 60 -le $d.Length) {
        $name = [System.Text.Encoding]::ASCII.GetString($d, $off, 16).Trim()
        $size = [int]([System.Text.Encoding]::ASCII.GetString($d, $off + 48, 10).Trim())
        $body = $off + 60
        $off = $body + $size + ($size -band 1)
        if ($name -eq '/' -or $name -eq '//') { continue }          # The symbol index and long-name table are not objects.
        $r.objs++
        $m = Read-U16 $d $body
        if ($m -eq 0 -and (Read-U16 $d ($body + 2)) -eq 0xFFFF) {  # An anonymous header means an object built with /GL.
            $r.ltcg++; $am = Read-U16 $d ($body + 6); $r.machines[$am] = 1 + $r.machines[$am]; continue
        }
        $r.machines[$m] = 1 + $r.machines[$m]
        $nsec = Read-U16 $d ($body + 2); $symoff = Read-U32 $d ($body + 8); $nsym = Read-U32 $d ($body + 12); $optsz = Read-U16 $d ($body + 16)
        for ($i = 0; $i -lt $nsec; $i++) {
            $s = $body + 20 + $optsz + $i * 40
            if ([System.Text.Encoding]::ASCII.GetString($d, $s, 8).TrimEnd([char]0) -eq '.drectve') {
                $sz = Read-U32 $d ($s + 16); $ptr = Read-U32 $d ($s + 20)
                $dir = [System.Text.Encoding]::ASCII.GetString($d, $body + $ptr, $sz)
                foreach ($mm in [regex]::Matches($dir, '/DEFAULTLIB:"?([A-Za-z0-9_.]+)"?', 'IgnoreCase')) { $r.defaultlibs[$mm.Groups[1].Value.ToLower()] = 1 }
            }
        }
        $found = $false; $i = 0
        while ($i -lt $nsym) {
            $s = $body + $symoff + $i * 18
            if ([System.Text.Encoding]::ASCII.GetString($d, $s, 8) -eq '@comp.id') {
                $v = Read-U32 $d ($s + 8); $b = [int]($v -band 0xFFFF); $r.builds[$b] = 1 + $r.builds[$b]; $found = $true; break
            }
            $i += 1 + $d[$s + 17]
        }
        if (-not $found) { $r.nocompid++ }
    }
    return $r
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
