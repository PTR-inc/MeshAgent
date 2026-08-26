#Requires -Version 5.1
<#
.SYNOPSIS
  Check the committed OpenSSL archives in openssl\libstatic\windows\*.lib against the MSVC
  toolset that is about to link them. Exits 1 only for a difference that breaks the link
  or the binary. Everything else is reported as a warning.

.DESCRIPTION
  Parses the COFF archives directly, without lib.exe or dumpbin.
  A machine type other than the one the file name promises is fatal.
  An MT archive that pulls LIBCMTD, or the reverse, is fatal because the CRTs would be mixed.
  LTCG objects built with /GL by a different compiler build are fatal, since they are build-locked (LNK1257).
  A different @comp.id compiler build is only a warning, because plain C objects link across MSVC versions.
  The current compiler is found through MSBuild with -getProperty VCToolsInstallDir. Pass -ClExe to skip that.

.EXAMPLE
  pwsh openssl\libstatic\build\windows\toolset-check.ps1 -Platform x64 -Toolset v145
#>
[CmdletBinding()]
param(
    [ValidateSet('x86', 'Win32', 'x64', 'ARM64')] [string] $Platform = 'x64',
    [string] $Toolset = 'v143',
    [string] $ClExe = '',
    [string] $Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
)
$ErrorActionPreference = 'Stop'

$fatal = New-Object System.Collections.Generic.List[string]
$warn  = New-Object System.Collections.Generic.List[string]

# Which archives this platform links, and what they must contain.
$suffix  = switch ($Platform) { 'x86' { '32' } 'Win32' { '32' } 'x64' { '64' } 'ARM64' { 'ARM64' } }
$machine = switch ($Platform) { 'x86' { 0x14c } 'Win32' { 0x14c } 'x64' { 0x8664 } 'ARM64' { 0xaa64 } }
$msbuildPlatform = if ($Platform -eq 'x86') { 'Win32' } else { $Platform }
$libDir = Join-Path $Repo 'openssl\libstatic\windows'
$libs = Get-ChildItem -Path $libDir -File -Filter 'lib*.lib' | Where-Object { $_.Name -match "^lib(crypto|ssl)$($suffix)MTd?\.lib$" } | Sort-Object Name
if (-not $libs) { Write-Host "FATAL: no lib*$($suffix)MT*.lib in $libDir"; exit 1 }

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
    $banner = (& $ClExe 2>&1 | Out-String)
    if ($banner -match 'Version (\d+)\.(\d+)\.(\d+)') { $clVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])"; $clBuild = [int]$Matches[3] }
}
if (-not $clBuild) { $warn.Add("could not determine the current cl.exe build (msbuild/-getProperty or -ClExe) - compiler-build comparisons skipped") }

# Walk the COFF archive.
function Read-U16([byte[]] $b, [int] $o) { [BitConverter]::ToUInt16($b, $o) }
function Read-U32([byte[]] $b, [int] $o) { [BitConverter]::ToUInt32($b, $o) }

function Inspect-Archive([string] $path) {
    $d = [System.IO.File]::ReadAllBytes($path)
    if ([System.Text.Encoding]::ASCII.GetString($d, 0, 8) -ne "!<arch>`n") { throw "not a COFF archive" }
    $r = [ordered]@{ objs = 0; ltcg = 0; machines = @{}; builds = @{}; nocompid = 0; defaultlibs = @{}; version = 'UNKNOWN' }
    $text = [System.Text.Encoding]::ASCII.GetString($d)
    if ($text -match 'OpenSSL \d+\.\d+\.\d+[a-z]?') { $r.version = $Matches[0] }
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
Write-Host ("OpenSSL archives for {0} ({1}, {2}):" -f $Platform, $Toolset, $cl)
"{0,-24} {1,-16} {2,5} {3,5} {4,-8} {5,-14} {6}" -f 'FILE', 'VERSION', 'OBJS', 'LTCG', 'MACHINE', 'CL-BUILD', 'CRT-DIRECTIVES' | Write-Host
foreach ($lib in $libs) {
    try { $r = Inspect-Archive $lib.FullName } catch { $fatal.Add("$($lib.Name): $_"); continue }
    $wantDebug = $lib.BaseName.EndsWith('MTd')
    $machList = ($r.machines.Keys | ForEach-Object { '0x{0:x}' -f $_ }) -join ','
    $buildList = ($r.builds.Keys | Sort-Object | ForEach-Object { "$_" }) -join ','
    $crt = ($r.defaultlibs.Keys | Where-Object { $_ -match '^(lib|msvc)' }) -join ','
    "{0,-24} {1,-16} {2,5} {3,5} {4,-8} {5,-14} {6}" -f $lib.Name, $r.version, $r.objs, $r.ltcg, $machList, $buildList, $(if ($crt) { $crt } else { '-' }) | Write-Host

    if ($r.objs -eq 0) { $fatal.Add("$($lib.Name): empty archive"); continue }
    foreach ($mk in $r.machines.Keys) { if ($mk -ne $machine) { $fatal.Add(("{0}: object machine 0x{1:x}, expected 0x{2:x} for {3}" -f $lib.Name, $mk, $machine, $Platform)) } }
    foreach ($dl in $r.defaultlibs.Keys) {
        if ($dl -match '^(libcmt|libucrt|libvcruntime)d\.lib$' -and -not $wantDebug) { $fatal.Add("$($lib.Name): release (MT) archive pulls the debug CRT via /DEFAULTLIB:$dl") }
        if ($dl -match '^(libcmt|libucrt|libvcruntime)\.lib$' -and $wantDebug)      { $fatal.Add("$($lib.Name): debug (MTd) archive pulls the release CRT via /DEFAULTLIB:$dl") }
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
