<#
.SYNOPSIS
    MeshAgent combined test driver for Windows, the PowerShell counterpart of test/test-agent.sh.

.DESCRIPTION
    This script and test/test-agent.sh are one driver in two languages. Every change here, be it a
    timeout, a milestone string, a discovery rule or the verdict wording, goes into the .sh as well.

    The single entry point for automated agent testing on Windows. Runs, in order, against one
    agent binary (MeshConsole*.exe by default):
      1. -info sanity banner (version, ARCHID, OpenSSL)
      2. test/stress-test.js, every testmodule except 06-*   must pass
      3. test/stress-test.js, the 06-* sections only          known native crashes (TLS reconnect,
                                                              WebSocket teardown)
      4. the same core run delivered via -b64exec             the meshcore delivery path, must pass
      5. connection test against <binary>.msh                 connect, authenticate, launch meshcore,
                                                              and persist the identity into <binary>.db
      6. AddressSanitizer over the core stress run            needs an ASan build, see -Asan
    Every check lives in test/testmodules/*.js. This script only launches, judges and tabulates.
    The stress phases run the agent through a hard link in the repo root, because on Windows the
    agent chdirs to its own directory and stress-test.js resolves its modules against the cwd.
    The legacy upstream scripts (self-test.js, leaktest.js, update-test.js, authtest.js) are unused.
    Everything is written to the console and to a logfile at the same time.
.PARAMETER Binary
    Agent .exe to test. Default: newest MeshConsole*.exe under build\win-*\ (or the pre-layout Release\, Debug\).

.PARAMETER Platform
    Restrict auto-discovery to one platform: x86, x64 or ARM64.

.PARAMETER Configuration
    Restrict auto-discovery to one configuration: Debug or Release. Each one has its own
    build\win-<platform>-<configuration>\ directory, so without this a newer build of the
    other configuration can be picked instead.

.PARAMETER AllowStale
    Do not fail when the agent was not built from the current HEAD commit.

.PARAMETER Log
    Logfile path. Default: test\logs\test-agent-<timestamp>.log

.PARAMETER NoConnect
    Skip the .msh connection test.

.PARAMETER Msh
    The .msh to connect with. The agent only ever reads <binary>.msh next to itself, so this is
    copied there, overwriting whatever was beside the binary.

.PARAMETER Asan
    ASan-instrumented agent for phase 6. Default: the Release_ASAN build of the same platform,
    or <binary>_asan.exe beside the agent. Build one with:
    msbuild MeshAgent-2022.sln /p:Configuration=Release_ASAN /p:Platform=x64

.PARAMETER AsanRuntimeDir
    Directory holding clang_rt.asan_dynamic-<arch>.dll. Default: probed from the MSVC toolsets.

.PARAMETER Strict
    Treat the known TLS crash as a failure (default under -Ci).
.PARAMETER Lenient
    Under -Ci, keep reporting the known TLS crash as KNOWN instead of FAIL.

.PARAMETER Ci
    GitHub Actions mode: ::group:: folding, annotations, job summary table. Implies -Yes.

.EXAMPLE
    .\test\test-agent.ps1
.EXAMPLE
    .\test\test-agent.ps1 -Binary .\build\win-x64-Release\MeshConsole64.exe -NoConnect
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Binary,
    [ValidateSet('x86', 'x64', 'ARM64')][string]$Platform,
    [ValidateSet('Debug', 'Release', 'Release_ASAN')][string]$Configuration,
    [switch]$AllowStale,
    [string]$Log,
    [switch]$NoConnect,
    [string]$Msh,
    [string]$Asan,
    [string]$AsanRuntimeDir,
    [switch]$Strict,
    [switch]$Lenient,
    [switch]$Ci
)

$ErrorActionPreference = 'Continue'
if ($Ci -and -not $Lenient) { $Strict = $true }

# The cwd must be the repo root, because stress-test.js resolves its testmodules relative to it.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

# ---------------------------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------------------------
if (-not $Log) {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'test\logs')
    $Log = Join-Path $RepoRoot ('test\logs\test-agent-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Log) -ErrorAction SilentlyContinue
Set-Content -Path $Log -Value '' -Encoding UTF8

function Say([string]$Text = '') {
    Write-Host $Text
    Add-Content -Path $script:Log -Value $Text -Encoding UTF8
}
function Hr { Say ('-' * 78) }

$script:GroupOpen = $false
function EndGroup { if ($script:Ci -and $script:GroupOpen) { Write-Host '::endgroup::'; $script:GroupOpen = $false } }
function Head2([string]$Title) {
    EndGroup
    Say ''; Say ('=' * 78); Say $Title; Say ('=' * 78)
    if ($script:Ci) { Write-Host "::group::$Title"; $script:GroupOpen = $true }
}

$script:Started = @()
$script:Shims = @()

# ---------------------------------------------------------------------------------------------
# process helper: run with a timeout, capture output, optionally drive stdin, stop early
# ---------------------------------------------------------------------------------------------
function Invoke-Agent {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSec = 60,
        [string[]]$StdinLines,
        [int]$StdinDelaySec = 2,
        [string]$StopWhen,
        # A file to watch beside stdout, for an agent whose stdout is block-buffered but whose own
        # .log is not. The run stops as soon as StopFileWhen shows up in it.
        [string]$StopFile,
        [string]$StopFileWhen
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Resolve-Path $FilePath).Path
    $psi.Arguments = ($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.WorkingDirectory = $script:RepoRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($PSBoundParameters.ContainsKey('StdinLines')) { $psi.RedirectStandardInput = $true }

    # stdout and stderr are delivered on two different threads. A plain StringBuilder is not
    # thread-safe, so the two handlers could interleave or lose a line. A synchronised list cannot.
    $lines = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $handler = { if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.Add($EventArgs.Data) } }
    $eo = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $handler -MessageData $lines
    $ee = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived  -Action $handler -MessageData $lines

    [void]$p.Start()
    $script:Started += $p
    $p.BeginOutputReadLine(); $p.BeginErrorReadLine()

    if ($PSBoundParameters.ContainsKey('StdinLines')) {
        foreach ($line in $StdinLines) {
            if ($p.HasExited) { break }
            try { $p.StandardInput.WriteLine($line); $p.StandardInput.Flush() } catch { break }
            Start-Sleep -Seconds $StdinDelaySec
        }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $timedOut = $false
    $sawStop = $false
    $scanned = 0
    while (-not $p.HasExited) {
        if ($StopWhen) {
            # Only the lines that arrived since the last poll are scanned, so a chatty run does not
            # re-read its whole output every 250 ms.
            $seen = $lines.ToArray()
            for ($i = $scanned; $i -lt $seen.Count; $i++) { if ($seen[$i].Contains($StopWhen)) { $sawStop = $true } }
            $scanned = $seen.Count
            if ($sawStop) { break }
        }
        if ($StopFile -and $StopFileWhen -and (Test-Path -LiteralPath $StopFile)) {
            if (Select-String -LiteralPath $StopFile -Pattern $StopFileWhen -SimpleMatch -Quiet) { $sawStop = $true; break }
        }
        if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $p.HasExited) {
        # Polite kill first, because a redirected agent block-buffers stdout and /F would throw away
        # the whole run's output. /T reaps the children too, which Kill() alone would leave running.
        try { & taskkill.exe /T /PID $p.Id 2>&1 | Out-Null } catch { }
        if (-not $p.WaitForExit(5000)) {
            try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch { try { $p.Kill() } catch { } }
            $null = $p.WaitForExit(5000)
        }
    }
    Start-Sleep -Milliseconds 500
    $code = if ($p.HasExited) { $p.ExitCode } else { $null }
    Unregister-Event -SourceIdentifier $eo.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $ee.Name -ErrorAction SilentlyContinue
    $p.Dispose()
    $text = $lines.ToArray() -join "`r`n"
    if ($text) { $text += "`r`n" }
    [pscustomobject]@{ Output = $text; ExitCode = $code; TimedOut = $timedOut }
}

function Emit($Result, [int]$MaxLines = 0) {
    $lines = $Result.Output -split "`r?`n"
    if ($script:Ci) { $MaxLines = 0 }
    if ($MaxLines -gt 0 -and $lines.Count -gt $MaxLines) {
        # The console gets the head and the log gets all of it. Never both, or the log reads doubled.
        $lines[0..($MaxLines - 1)] | ForEach-Object { Write-Host $_ }
        Write-Host "  ... (output truncated, full text in $script:Log)"
        Add-Content -Path $script:Log -Value $Result.Output -Encoding UTF8
    }
    else { $lines | ForEach-Object { Say $_ } }
}

# Every stress phase judges itself on the TOTAL line rather than on the exit code, because
# process.exit(1) does not always survive on Windows.
function Get-StressTotals([string]$Text) {
    $line = ([regex]::Matches($Text, 'TOTAL: .*') | Select-Object -Last 1).Value
    if ($line -match 'TOTAL: (\d+) passed, (\d+) failed') {
        return [pscustomobject]@{ Line = $line; Passed = [int]$Matches[1]; Failed = [int]$Matches[2] }
    }
    return [pscustomobject]@{ Line = $line; Passed = -1; Failed = -1 }
}

# NTSTATUS values such as 0xC0000005 read as huge negative numbers. Name them, or nobody can
# tell a crash from an application exit code.
function RcDesc($Code) {
    if ($null -eq $Code) { return 'no exit code (killed)' }
    $name = switch ($Code) {
        -1073741819 { 'ACCESS_VIOLATION 0xC0000005' }
        -1073741795 { 'ILLEGAL_INSTRUCTION 0xC000001D' }
        -1073741571 { 'STACK_OVERFLOW 0xC00000FD' }
        -1073740791 { 'STACK_BUFFER_OVERRUN 0xC0000409' }
        -2147483645 { 'BREAKPOINT 0x80000003' }
        -1073741510 { 'CONTROL_C_EXIT 0xC000013A' }
        -1073741515 { 'DLL_NOT_FOUND 0xC0000135 - missing runtime DLL, e.g. clang_rt.asan_dynamic-*.dll' }
        -1073741511 { 'ENTRYPOINT_NOT_FOUND 0xC0000139 - a DLL loaded but lacks an export the binary needs' }
        254         { 'agent FATAL EXCEPTION (ILIBCRITICALEXIT)' }
        default     { '' }
    }
    if ($name) { "exit $Code ($name)" } else { "exit $Code" }
}

# ---------------------------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------------------------
$script:Phases = @()
$script:Failed = 0
function Record([string]$Name, [string]$Result, [string]$Note = '') {
    $script:Phases += [pscustomobject]@{ Name = $Name; Result = $Result; Note = $Note }
    if ($Result -eq 'FAIL') { $script:Failed++ }
}

# ---------------------------------------------------------------------------------------------
# binary selection
# ---------------------------------------------------------------------------------------------
# Each platform and configuration has its own build\win-<platform>-<configuration>\ directory, so
# the newest binary in the tree is often not the one that was just built. Name what was chosen.
function Get-BuildTag([string]$Path) {
    $dir = Split-Path -Leaf (Split-Path -Parent $Path)
    if ($dir -match '^win-(x86|x64|ARM64)-(.+)$') {
        return [pscustomobject]@{ Platform = $Matches[1]; Configuration = $Matches[2] }
    }
    return [pscustomobject]@{ Platform = ''; Configuration = $dir }
}

# On Windows only, the agent chdirs to its own directory at startup (the WIN32 block around
# SetCurrentDirectoryW in meshcore/agentcore.c). A binary under build\win-<platform>-<configuration>\
# therefore resolves both test\stress-test.js and test/testmodules against that directory and finds
# neither. Running it through a hard link in the repo root puts the working directory where
# stress-test.js expects it. The bash driver needs none of this, because the chdir is WIN32-only.
# The testmodules write their scratch files to a per-pid directory under the temp dir, and Windows
# will not unlink one whose read stream is still open, so a run can leave that directory behind.
# The repo root is swept too, because that is where a checkout from before this change wrote them.
function Clear-TestResidue {
    $globs = @((Join-Path ([IO.Path]::GetTempPath()) 'meshagent-stresstest-*'),
               (Join-Path $script:RepoRoot 'meshagent-stresstest-*'))
    Get-ChildItem -Path $globs -ErrorAction SilentlyContinue |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    # A file another process still has open cannot be deleted, and the next phase then fails to
    # create it. Name the survivors, or that failure looks like a defect in the phase itself.
    $left = @(Get-ChildItem -Path $globs -Recurse -File -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
        Say ('  WARNING: {0} scratch file(s) from an earlier phase could not be removed - something still holds them open:' -f $left.Count)
        $left | ForEach-Object { Say ('    ' + $_.FullName) }
    }
}

function New-RootShim([string]$Path) {
    if ((Split-Path -Parent $Path) -eq $script:RepoRoot) { return $Path }
    $shim = Join-Path $script:RepoRoot ('testrun-' + (Split-Path -Leaf $Path))
    Remove-Item -LiteralPath $shim -Force -ErrorAction SilentlyContinue
    try { $null = New-Item -ItemType HardLink -Path $shim -Target $Path -ErrorAction Stop }
    catch { Copy-Item -LiteralPath $Path -Destination $shim -Force }
    $script:Shims += $shim
    return $shim
}

if (-not $Binary) {
    $roots = @('build\win-*', 'Release', 'Debug', '.')
    if ($Platform -or $Configuration) {
        $pf = if ($Platform) { $Platform } else { '*' }
        $cf = if ($Configuration) { $Configuration } else { '*' }
        $roots = @("build\win-$pf-$cf")
    }
    $cands = @(Get-ChildItem -Path $roots -Filter 'Mesh*.exe' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like 'MeshConsole*' -or $_.Name -like 'MeshService*' } |
               Sort-Object @{Expression = { $_.Name -like 'MeshConsole*' }; Descending = $true}, LastWriteTime -Descending)
    if ($cands.Count -gt 1) {
        Say ('{0} agent binaries match - taking the first. Narrow it with -Platform, -Configuration or -Binary:' -f $cands.Count)
        $cands | ForEach-Object { Say ('    {0}  ({1:yyyy-MM-dd HH:mm})' -f $_.FullName, $_.LastWriteTime) }
    }
    if ($cands.Count -gt 0) { $Binary = $cands[0].FullName }
}
if (-not $Binary -or -not (Test-Path $Binary)) {
    $what = if ($Platform -or $Configuration) { " for -Platform '$Platform' -Configuration '$Configuration'" } else { '' }
    Write-Error "no agent binary found$what - build the solution or pass -Binary <path to MeshConsole*.exe>"
    exit 2
}
$Binary = (Resolve-Path $Binary).Path
$BuildTag = Get-BuildTag $Binary

function Get-PeMachine([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        [void]$fs.Seek(0x3C, 'Begin'); $peOff = $br.ReadInt32()
        [void]$fs.Seek($peOff, 'Begin'); [void]$br.ReadUInt32()
        switch ($br.ReadUInt16()) { 0x014C { 'x86' } 0x8664 { 'x64' } 0xAA64 { 'ARM64' } 0x01C4 { 'ARM' } default { 'unknown' } }
    }
    finally { $fs.Close() }
}
function Test-IsAsan([string]$Path) {
    # An MSVC ASan build imports clang_rt.asan*.dll, and the name sits in the import table as plain
    # ASCII. Read it in fixed blocks, so a large agent never lands in memory whole.
    try {
        $sr = New-Object IO.StreamReader($Path, [Text.Encoding]::ASCII)
        try {
            $buf = New-Object char[] 65536
            $tail = ''
            while (($n = $sr.Read($buf, 0, $buf.Length)) -gt 0) {
                $block = $tail + (New-Object string($buf, 0, $n))
                if ($block.Contains('clang_rt.asan')) { return $true }
                $tail = $block.Substring([Math]::Max(0, $block.Length - 16))
            }
        }
        finally { $sr.Close() }
    }
    catch { return $false }
    return $false
}

# The ASan runtime DLL is needed even by /MT builds since VS 17.7 and is not on PATH outside a
# Developer prompt, so find it in the MSVC toolset and prepend its directory ourselves.
function Get-AsanRuntimeDirs([string]$Machine) {
    $dll = switch ($Machine) {
        'x64'   { 'clang_rt.asan_dynamic-x86_64.dll' }
        'x86'   { 'clang_rt.asan_dynamic-i386.dll' }
        'ARM64' { 'clang_rt.asan_dynamic-aarch64.dll' }
        default { $null }
    }
    if (-not $dll) { return $null }
    $roots = @()
    if ($env:VCToolsInstallDir) { $roots += $env:VCToolsInstallDir }
    $pf86 = ${env:ProgramFiles(x86)}
    $vswhere = if ($pf86) { Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe' } else { $null }
    if ($vswhere -and (Test-Path $vswhere)) {
        foreach ($vs in (& $vswhere -latest -prerelease -products * -property installationPath 2>$null)) {
            if ($vs) { $roots += (Join-Path $vs 'VC\Tools\MSVC') }
        }
    }
    $found = @()
    foreach ($r in $roots) {
        $found += Get-ChildItem -Path $r -Recurse -Filter $dll -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.DirectoryName }
    }
    return ($found | Select-Object -Unique)
}

# 0xC0000135 means the DLL is missing. 0xC0000139 means it was found but its exports do not match
# the binary, which is an ASan runtime from a different MSVC toolset. Probe until the agent starts.
function Resolve-AsanRuntime([string]$ExePath) {
    $bad = @(-1073741515, -1073741511)
    $dirs = if ($script:AsanRuntimeDir) { @($script:AsanRuntimeDir) } else { @(Get-AsanRuntimeDirs (Get-PeMachine $ExePath)) }
    if (-not $dirs -or $dirs.Count -eq 0) {
        Say '  clang_rt.asan_dynamic-*.dll not found in any MSVC toolset - install the'
        Say '  "C++ AddressSanitizer" component, or pass -AsanRuntimeDir <path>.'
        return $false
    }
    $saved = $env:PATH
    foreach ($dir in $dirs) {
        $env:PATH = "$dir;$saved"
        $probe = Invoke-Agent -FilePath $ExePath -ArgumentList @('-info') -TimeoutSec 30
        if ($bad -notcontains $probe.ExitCode) { Say "  ASan runtime: $dir"; return $true }
        Say ("  rejected {0} ({1})" -f $dir, (RcDesc $probe.ExitCode))
    }
    $env:PATH = $saved
    Say '  no MSVC toolset here has an ASan runtime this binary accepts. Candidates tried:'
    $dirs | ForEach-Object { Say "    $_" }
    Say '  Build the agent and run the test with the same toolset, or pass -AsanRuntimeDir <path>.'
    return $false
}

$BinMachine = Get-PeMachine $Binary
$HostArch = $env:PROCESSOR_ARCHITECTURE
$IsElevated = $false
try {
    $IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# ARM64 Windows emulates x86 and x64. x64 Windows cannot run an ARM64 build at all.
$CanRun = $true
if ($BinMachine -eq 'ARM64' -and $HostArch -ne 'ARM64') { $CanRun = $false }

# ---------------------------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------------------------
Head2 'MeshAgent test driver (Windows)'
Say ("date        : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say "repo        : $RepoRoot"
Say "binary      : $Binary"
Say ("build       : {0}" -f $(if ($BuildTag.Platform) { "$($BuildTag.Platform) $($BuildTag.Configuration)" } else { "unrecognised layout ($($BuildTag.Configuration))" }))
Say "             PE machine: $BinMachine, host: $HostArch"
Say ("powershell  : {0}" -f $PSVersionTable.PSVersion)
Say ("elevated    : {0}" -f $(if ($IsElevated) { 'yes' } else { 'NO - some connect paths need it' }))
Say "logfile     : $Log"

# This has to come before the ASan probe below, which starts the agent to find a runtime it accepts.
if (-not $CanRun) {
    Say ''
    Say "Cannot run an $BinMachine binary on $HostArch - test it on matching hardware."
    exit 1
}

$IsAsanBinary = Test-IsAsan $Binary
if ($IsAsanBinary) { $null = Resolve-AsanRuntime $Binary }

# The stress phases run through this, the connection phase does not: that one wants its .msh and .db
# beside the real binary.
$RunBinary = New-RootShim $Binary
if ($RunBinary -ne $Binary) { Say ("run-as       : {0}  (hard link, so the agent's own chdir lands on the repo root)" -f $RunBinary) }

# --- phase 1: -info ---------------------------------------------------------------------------
# -info already reports the commit the agent was built from, whether TLS is compiled in, and the
# ARCHID it claims. Reading it turns the banner into a check on what is about to be tested.
Head2 '[1/6] agent -info'
$r = Invoke-Agent -FilePath $Binary -ArgumentList @('-info') -TimeoutSec 30
Emit $r 20

$HasTls = $false
$infoNotes = @()
if ($r.Output -match '(?m)^Using OpenSSL (.+)$') { $HasTls = $true; $infoNotes += ('OpenSSL ' + $Matches[1].Trim()) }
else { $infoNotes += 'no TLS (MICROSTACK_NOTLS build)' }
if ($r.Output -match '(?m)^Agent ARCHID: (\d+)') { $infoNotes += ('ARCHID ' + $Matches[1]) }

# Nothing here builds without TLS, so an agent that reports none did not come out of this tree.
if ($BuildTag.Platform -and -not $HasTls) {
    Say '  WARNING: this agent reports no OpenSSL, which no configuration here produces - stale or foreign binary?'
}

# Auto-discovery takes the newest binary, which makes it easy to test yesterday's build by accident.
$binCommit = if ($r.Output -match '(?m)Commit Hash:\s*([0-9a-f]{40})') { $Matches[1] } else { '' }
$headCommit = ''
try { $headCommit = (& git rev-parse HEAD 2>$null) } catch { }
$stale = ($binCommit -and $headCommit -and $binCommit -ne $headCommit)
if ($stale) { $infoNotes += ('built from {0}, HEAD is {1}' -f $binCommit.Substring(0, 12), $headCommit.Substring(0, 12)) }
elseif ($binCommit -and $headCommit) { $infoNotes += ('at HEAD ' + $binCommit.Substring(0, 12)) }

if ($r.ExitCode -ne 0) { Record 'agent -info' 'FAIL' (RcDesc $r.ExitCode) }
elseif ($stale -and -not $AllowStale) { Record 'agent -info' 'FAIL' (($infoNotes -join ', ') + ' - rebuild, or pass -AllowStale') }
else { Record 'agent -info' 'PASS' ($infoNotes -join ', ') }

# OpenSSL version: report only, not gating - a mismatch is expected on some platforms (Windows
# still pins whatever openssl\<version>\windows-<platform>\ MeshOpenSSLVersion resolves to, see
# MeshAgent.Common.props) and shouldn't fail the run over it.
$wantOssl = ''
try { $wantOssl = (Get-Content -Raw (Join-Path $RepoRoot 'openssl\VERSION') -ErrorAction Stop).Trim() } catch { }
if (-not $wantOssl) { Say '  (no openssl\VERSION to compare the linked OpenSSL against)' }
elseif (-not $HasTls) { Record 'openssl version' 'SKIP' "-info printed no 'Using OpenSSL' line (NOTLS build?)" }
else {
    $gotOssl = if ($r.Output -match '(?m)Using OpenSSL (\d+\.\d+\.\d+[a-z]?)') { $Matches[1] } else { '' }
    if (-not $gotOssl) { Record 'openssl version' 'SKIP' "-info printed no version after 'Using OpenSSL'" }
    elseif ($gotOssl -eq $wantOssl) { Record 'openssl version' 'PASS' $gotOssl }
    else { Record 'openssl version' 'PASS' "agent links OpenSSL $gotOssl, openssl\VERSION pins $wantOssl (report only, not gating)" }
}

# --- phase 2: stress test, core sections ------------------------------------------------------
# The 06-* testmodules are the known native-crash sections (TLS reconnect and WebSocket session
# teardown). They run in phase 3, apart from the core, so one crash cannot take every other
# check down with it.
$coreExcl = ((Get-ChildItem 'test\testmodules' -Filter '*.js' | Where-Object { $_.Name -notlike '06-*' } | ForEach-Object { $_.BaseName }) -join ',')
Head2 '[2/6] stress test - every testmodule except the known-crash 06-* sections'
Clear-TestResidue
$r = Invoke-Agent -FilePath $RunBinary -ArgumentList @('test\stress-test.js', '--exclude=06-', '--watchdog=120000') -TimeoutSec 240
Emit $r
$core = Get-StressTotals $r.Output
if ($r.ExitCode -eq 0 -and $core.Failed -eq 0) { Record 'stress (core)' 'PASS' $core.Line }
elseif ($core.Failed -lt 0) { Record 'stress (core)' 'FAIL' ((RcDesc $r.ExitCode) + ' - no TOTAL line, the run did not finish') }
else { Record 'stress (core)' 'FAIL' ((RcDesc $r.ExitCode) + ' ' + $core.Line) }

# --- phase 3: stress test, TLS section only ---------------------------------------------------
Head2 '[3/6] stress test - known-crash 06-* sections only (TLS, WebSocket)'
if (-not $HasTls) {
    Say '  this agent has no TLS compiled in, so the 06-* sections have nothing to exercise'
    Record 'stress (known 06-*)' 'SKIP' 'no TLS in this build'
}
else {
    Clear-TestResidue
    $r = Invoke-Agent -FilePath $RunBinary -ArgumentList @('test\stress-test.js', "--exclude=$coreExcl", '--watchdog=40000') -TimeoutSec 120
    Emit $r
    $knownTls = @(254, -1073741819, -2147483645)
    if ($r.ExitCode -eq 0) { Record 'stress (known 06-*)' 'PASS' 'the #1 reconnect-after-end() crash did NOT reproduce' }
    elseif ($knownTls -contains $r.ExitCode) {
        if ($Strict) { Record 'stress (known 06-*)' 'FAIL' ((RcDesc $r.ExitCode) + ' - known crash') }
        else { Record 'stress (known 06-*)' 'KNOWN' ((RcDesc $r.ExitCode) + ' - reconnect-after-end() crash') }
    }
    else { Record 'stress (known 06-*)' 'FAIL' ((RcDesc $r.ExitCode) + ' (unexpected - not the known crash signature)') }
}

# --- phase 4: the core run again, delivered the way meshcore is (-b64exec) -------------------
Head2 '[4/6] stress test via -b64exec (meshcore delivery path)'
# argv is empty under -b64exec, so the exclude and watchdog defaults are patched into the script.
$src = Get-Content -Raw 'test\stress-test.js'
$src = $src -replace '(?m)^var OPT_EXCLUDE = \[\];', 'var OPT_EXCLUDE = ["06-"];' -replace '(?m)^var OPT_WATCHDOG = 10000;', 'var OPT_WATCHDOG = 60000;'
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($src))
# The whole script travels on the command line, and Windows caps that at 32767 characters. Say so
# rather than letting the phase fail with an unexplained startup error once the script outgrows it.
if ($b64.Length -gt 32000) {
    Say ('  the base64 payload is {0} characters, past the Windows command-line limit' -f $b64.Length)
    Record 'stress (-b64exec)' 'SKIP' "payload too large for a command line ($($b64.Length) chars)"
}
else {
    Clear-TestResidue
    $r = Invoke-Agent -FilePath $RunBinary -ArgumentList @('-b64exec', $b64) -TimeoutSec 180
    Emit $r 30
    $b64r = Get-StressTotals $r.Output
    if ($r.ExitCode -eq 0 -and $b64r.Failed -eq 0 -and $b64r.Passed -eq $core.Passed) { Record 'stress (-b64exec)' 'PASS' $b64r.Line }
    elseif ($r.ExitCode -eq 0 -and $b64r.Failed -eq 0) { Record 'stress (-b64exec)' 'FAIL' ('passed, but ran {0} checks where phase 2 ran {1}' -f $b64r.Passed, $core.Passed) }
    elseif ($b64r.Failed -lt 0) { Record 'stress (-b64exec)' 'FAIL' ((RcDesc $r.ExitCode) + ' - no TOTAL line, the run did not finish') }
    else { Record 'stress (-b64exec)' 'FAIL' ((RcDesc $r.ExitCode) + ' ' + $b64r.Line) }
}

# --- phase 5: connection test against <binary>.msh ---------------------------------------------
$mshFile = [IO.Path]::ChangeExtension($Binary, '.msh')
Head2 ('[5/6] connection test ({0})' -f (Split-Path -Leaf $mshFile))
$mshSrcFailed = $false
if ($Msh -and -not $NoConnect) {
    if (-not (Test-Path $Msh)) {
        Say "  -Msh ${Msh}: no such file"
        Record 'connection test' 'FAIL' "-Msh $Msh not found"
        $mshSrcFailed = $true
    }
    else {
        Copy-Item -LiteralPath $Msh -Destination $mshFile -Force
        Say ("  using {0} -> {1}" -f $Msh, (Split-Path -Leaf $mshFile))
    }
}
if ($mshSrcFailed) {
    # already recorded above
}
elseif ($NoConnect) {
    Say '  skipped by request (-NoConnect)'
    Record 'connection test' 'SKIP' '-NoConnect'
}
elseif (-not $HasTls) {
    Say '  this agent has no TLS compiled in, so it cannot reach a wss:// server'
    Record 'connection test' 'SKIP' 'no TLS in this build'
}
elseif (-not (Test-Path $mshFile)) {
    Say ("  no {0} next to the agent - nothing to connect to" -f (Split-Path -Leaf $mshFile))
    Record 'connection test' 'SKIP' ('no ' + (Split-Path -Leaf $mshFile))
}
else {
    # The last MeshServer= line wins. These .msh files set it twice, local first, then the real wss:// URL.
    $srv = (Select-String -Path $mshFile -Pattern '^MeshServer=' | Select-Object -Last 1).Line -replace '^MeshServer=', ''
    Say "  MeshServer=$srv"
    $reachable = $true
    if ($srv -match '^(wss?|https?)://([^/:]+)(:(\d+))?') {
        $chost = $Matches[2]
        $cport = if ($Matches[4]) { [int]$Matches[4] } else { 443 }
        $tcp = New-Object Net.Sockets.TcpClient
        try { $reachable = $tcp.ConnectAsync($chost, $cport).Wait(5000) } catch { $reachable = $false } finally { $tcp.Close() }
        if (-not $reachable) { Say "  nothing listening on ${chost}:${cport} - start the MeshCentral server to run this phase" }
    }
    if (-not $reachable) { Record 'connection test' 'SKIP' "no server on ${chost}:${cport}" }
    else {
        # A ceiling, not a wait: the run stops as soon as 'Server verified meshcore' shows up. An ASan
        # agent measured about 18s to reach CoreOk where a Release one took 3s, so it gets more room.
        $connectSec = if ($IsAsanBinary) { 60 } else { 20 }
        Say ("  running '{0} connect' for up to {1}s (writes .db/.log next to the agent)" -f (Split-Path -Leaf $Binary), $connectSec)
        # controlChannelDebug and showModuleNames gate the markers this phase greps for, and logUpdate
        # gates the 'Connection Established' line in the agent's own .log. Forced into the .msh
        # because .msh is imported into the .db on every start and always wins.
        $mshLines = @(Get-Content $mshFile)
        $mshChanged = $false
        foreach ($key in @('controlChannelDebug', 'showModuleNames', 'logUpdate')) {
            if ($mshLines -notcontains "$key=1") {
                $mshLines = @($mshLines | Where-Object { $_ -notmatch "^$key=" }) + "$key=1"
                Say "  forced $key=1 into the .msh"
                $mshChanged = $true
            }
        }
        if ($mshChanged) { Set-Content -Path $mshFile -Value $mshLines -Encoding Ascii }
        $verb = 'connect'
        # This phase judges the agent's own <binary>.log, never its stdout. stdout is block-buffered
        # when it is a pipe and 'Server verified meshcore' is printed without a newline, so a run that
        # has to be killed loses it. The .log is written unbuffered with controlChannelDebug and
        # logUpdate on. The stale log goes first, so only this run is judged.
        $agentLog = [IO.Path]::ChangeExtension($Binary, '.log')
        Remove-Item -LiteralPath $agentLog -Force -ErrorAction SilentlyContinue
        # MeshCommand_CoreOk (16) is the last milestone, logged as ProcessCommand(16).
        $null = Invoke-Agent -FilePath $Binary -ArgumentList @($verb) -TimeoutSec $connectSec -StopFile $agentLog -StopFileWhen 'ProcessCommand(16)'
        $logText = if (Test-Path $agentLog) { Get-Content -Raw $agentLog } else { '' }
        Emit ([pscustomobject]@{ Output = $logText }) 25
        $missing = @()
        # What each event writes to the .log -> how it is reported when absent
        $milestones = [ordered]@{
            'Control Channel Connection Established' = 'control channel'
            'Authentication Complete'                = 'authentication'
            'Connection Established ['               = 'connection established'
            'ProcessCommand(16)'              = 'server verified meshcore (CoreOk)'
        }
        foreach ($m in $milestones.Keys) {
            if (-not $logText.Contains($m)) { $missing += "missing $($milestones[$m]) ('$m' not in $(Split-Path -Leaf $agentLog))" }
        }
        # The node identity and its server must have been persisted, or the agent re-provisions on
        # every start. On Windows the node cert normally lives in the Windows cert store and the .db
        # only carries NodeID (agentcore.c, agent_GenerateCertificates and the noCertStore switch),
        # so either key counts as the identity.
        $db = [IO.Path]::ChangeExtension($Binary, '.db')
        if (Test-Path $db) {
            foreach ($k in @('SelfNodeCert|NodeID', 'MeshServer')) {
                if (-not (Select-String -Path $db -Pattern $k -Encoding Ascii -Quiet)) { $missing += "'$k' not persisted in $(Split-Path -Leaf $db)" }
            }
        }
        else { $missing += "no $(Split-Path -Leaf $db) written" }
        if ($missing.Count -eq 0) { Record 'connection test' 'PASS' "connected, authenticated, meshcore launched, identity persisted ($srv)" }
        else {
            $hint = ''
            if (-not $logText) {
                $hint = " - no $(Split-Path -Leaf $agentLog) was written; the agent only logs with controlChannelDebug=1 and logUpdate=1 in the .msh"
                Say "  $hint"
            }
            Record 'connection test' 'FAIL' (($missing -join ', ') + $hint)
        }
    }
}

# --- phase 6: AddressSanitizer over the core stress run ----------------------------------------
Head2 '[6/6] AddressSanitizer - core stress run'
if (-not $Asan) {
    # A Release_ASAN build lands in its own directory beside this one, named <target>_asan.exe.
    $stem = Split-Path -Leaf ([IO.Path]::ChangeExtension($Binary, $null)).TrimEnd('.')
    $cand = @([IO.Path]::ChangeExtension($Binary, $null) + '_asan.exe')
    if ($BuildTag.Platform) {
        $cand += Join-Path $RepoRoot ("build{0}win-{1}-Release_ASAN{0}{2}_asan.exe" -f [IO.Path]::DirectorySeparatorChar, $BuildTag.Platform, $stem)
    }
    $hit = $cand | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($hit) { $Asan = $hit }
    elseif (Test-IsAsan $Binary) { $Asan = $Binary }
}
if (-not $Asan) {
    Say '  no ASan build found - make one with:'
    Say '    msbuild MeshAgent-2022.sln /p:Configuration=Release_ASAN /p:Platform=x64'
    Record 'asan (stress)' 'SKIP' 'no ASan build'
}
elseif (-not (Test-Path $Asan)) {
    Record 'asan (stress)' 'FAIL' "$Asan not found"
}
else {
    Say "  using $Asan"
    $null = Resolve-AsanRuntime $Asan
    # continue_on_error reports every error and keeps running. halt_on_error=0 also keeps running
    # but still reports only the first: measured on a bare -info, 1 report became 3.
    $env:ASAN_OPTIONS = 'continue_on_error=1:print_legend=0'
    Clear-TestResidue
    $r = Invoke-Agent -FilePath (New-RootShim $Asan) -TimeoutSec 600 -ArgumentList @(
        'test\stress-test.js', '--exclude=06-', '--watchdog=300000')
    Remove-Item Env:\ASAN_OPTIONS -ErrorAction SilentlyContinue
    Emit $r 12
    $reports = ([regex]::Matches($r.Output, 'ERROR: AddressSanitizer')).Count
    $asanTotals = Get-StressTotals $r.Output
    if ($reports -gt 0) {
        Say "  $reports AddressSanitizer report(s):"
        [regex]::Matches($r.Output, '(?m)^\s+#[01] 0x[0-9a-f]+ in (.+)$') |
            ForEach-Object { '    ' + $_.Groups[1].Value } | Sort-Object -Unique | Select-Object -First 10 |
            ForEach-Object { Say $_ }
        $tail = if ($asanTotals.Line) { $asanTotals.Line } else { 'the run stopped before the TOTAL line' }
        Record 'asan (stress)' 'FAIL' "$reports report(s) - $tail"
    }
    elseif (@(-1073741515, -1073741511) -contains $r.ExitCode) {
        Say '  the ASan runtime still does not match this binary - build and test with one toolset,'
        Say '  or pass -AsanRuntimeDir <dir containing clang_rt.asan_dynamic-*.dll>.'
        Record 'asan (stress)' 'FAIL' (RcDesc $r.ExitCode)
    }
    elseif (-not $asanTotals.Line) { Record 'asan (stress)' 'FAIL' ((RcDesc $r.ExitCode) + ' - the run did not finish') }
    else { Record 'asan (stress)' 'PASS' "no ASan reports - $($asanTotals.Line)" }
}

# ---------------------------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------------------------
EndGroup
Say ''; Say ('=' * 78); Say 'SUMMARY'; Say ('=' * 78)

if ($Ci -and $env:GITHUB_STEP_SUMMARY) {
    $md = @("### MeshAgent test driver (Windows)", '', "``$(Split-Path -Leaf $Binary)`` - PE $BinMachine on $HostArch", '',
            '| phase | result | notes |', '|---|---|---|')
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $md -Encoding UTF8
}
foreach ($p in $Phases) {
    Say ('  {0,-24} {1,-6} {2}' -f $p.Name, $p.Result, $p.Note)
    if ($Ci) {
        switch ($p.Result) {
            'FAIL'  { Write-Host "::error title=$($p.Name)::$($p.Note)" }
            'KNOWN' { Write-Host "::warning title=$($p.Name)::$($p.Note)" }
            'SKIP'  { Write-Host "::notice title=$($p.Name)::skipped - $($p.Note)" }
        }
        if ($env:GITHUB_STEP_SUMMARY) {
            Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ('| {0} | {1} | {2} |' -f $p.Name, $p.Result, ($p.Note -replace '\|', '\|')) -Encoding UTF8
        }
    }
}
Hr
if ($Failed -eq 0) { Say "RESULT: OK ($Failed failing phases)" } else { Say "RESULT: FAILED ($Failed failing phases)" }
Say "full log: $Log"
if ($Ci -and $env:GITHUB_STEP_SUMMARY) {
    $verdict = if ($Failed -eq 0) { 'OK' } else { "FAILED ($Failed phases)" }
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value @('', "**RESULT: $verdict**") -Encoding UTF8
}

foreach ($p in $Started) { try { if (-not $p.HasExited) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } } catch { try { $p.Kill() } catch { } } }
Clear-TestResidue
foreach ($s in $Shims) {
    # The agent writes its .log and .db beside argv[0], so sweep the whole stem, not just the link.
    $stem = Join-Path (Split-Path -Parent $s) ([IO.Path]::GetFileNameWithoutExtension($s))
    Get-ChildItem -Path ($stem + '*') -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
exit $(if ($Failed -gt 0) { 1 } else { 0 })
