<#
.SYNOPSIS
    MeshAgent combined test driver for Windows, the PowerShell counterpart of test/test-agent.sh.

.DESCRIPTION
    The single entry point for automated agent testing on Windows. Runs, in order, against one
    agent binary (MeshConsole*.exe by default):
      1. -info sanity banner (version, ARCHID, OpenSSL)
      2. test/stress-test.js, every testmodule except 06-*   must pass
      3. test/stress-test.js, the 06-* sections only          known native crashes (TLS reconnect,
                                                              WebSocket teardown), see meshagent-todo.md
      4. the same core run delivered via -b64exec             the meshcore delivery path, must pass
      5. connection test against <binary>.msh                 connect, authenticate, launch meshcore,
                                                              and persist the identity into <binary>.db
      6. Dr. Memory over the core stress run                  leak and error report (optional tool)
      7. AddressSanitizer over the core stress run            needs an ASan build, see -Asan
    Every check lives in test/testmodules/*.js. This script only launches, judges and tabulates.
    The legacy upstream scripts (self-test.js, leaktest.js, update-test.js, authtest.js) are unused.
    Everything is written to the console and to a logfile at the same time.
.PARAMETER Binary
    Agent .exe to test. Default: newest MeshConsole*.exe under build\win-*\ (or the pre-layout Release\, Debug\).

.PARAMETER Log
    Logfile path. Default: test\logs\test-agent-<timestamp>.log

.PARAMETER Quick
    Skip the Dr. Memory phase.

.PARAMETER NoConnect
    Skip the .msh connection test.

.PARAMETER Asan
    ASan-instrumented agent for phase 8. Default: <binary>_asan.exe if it exists. Build one with:
    msbuild MeshAgent-2022.sln /p:Configuration=Release /p:Platform=x64 /p:EnableASAN=true

.PARAMETER AsanRuntimeDir
    Directory holding clang_rt.asan_dynamic-<arch>.dll. Default: probed from the MSVC toolsets.

.PARAMETER Strict
    Treat the known TLS crash as a failure (default under -Ci).
.PARAMETER Lenient
    Under -Ci, keep reporting the known TLS crash as KNOWN instead of FAIL.

.PARAMETER Ci
    GitHub Actions mode: ::group:: folding, annotations, job summary table. Implies -Yes.

.PARAMETER Yes
    Non-interactive: install missing tools without asking.

.EXAMPLE
    .\test\test-agent.ps1
.EXAMPLE
    .\test\test-agent.ps1 -Binary .\build\win-x64-Release\MeshConsole64.exe -Quick
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Binary,
    [string]$Log,
    [switch]$Quick,
    [switch]$NoConnect,
    [string]$Asan,
    [string]$AsanRuntimeDir,
    [switch]$Strict,
    [switch]$Lenient,
    [switch]$Ci,
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'
if ($Ci) { $Yes = $true; if (-not $Lenient) { $Strict = $true } }

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

$TmpDir = Join-Path ([IO.Path]::GetTempPath()) ('test-agent-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $TmpDir
$script:Started = @()

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
        [string]$StopWhen
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

    $sb = New-Object System.Text.StringBuilder
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $handler = { if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } }
    $eo = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action $handler -MessageData $sb
    $ee = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived  -Action $handler -MessageData $sb

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
    while (-not $p.HasExited) {
        if ($StopWhen -and $sb.ToString().Contains($StopWhen)) { break }
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
    [pscustomobject]@{ Output = $sb.ToString(); ExitCode = $code; TimedOut = $timedOut }
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

# NTSTATUS values such as 0xC0000005 read as huge negative numbers. Name them, or nobody can
# tell a crash from an application exit code.
function RcDesc($Code) {
    if ($null -eq $Code) { return 'no exit code (killed)' }
    $name = switch ($Code) {
        -1073741819 { 'ACCESS_VIOLATION 0xC0000005' }
        -1073741795 { 'ILLEGAL_INSTRUCTION 0xC000001D' }
        -1073741571 { 'STACK_OVERFLOW 0xC00000FD' }
        -1073740791 { 'STACK_BUFFER_OVERRUN 0xC0000409' }
        -2147483645 { 'BREAKPOINT 0x80000003 - see meshagent-todo.md #0j' }
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
# tool discovery
# ---------------------------------------------------------------------------------------------
function Ensure-Tool([string]$Tool, [string]$WingetId, [string]$ChocoId) {
    if (Get-Command $Tool -ErrorAction SilentlyContinue) { return $true }
    $cmd = $null
    if (Get-Command winget -ErrorAction SilentlyContinue) { $cmd = "winget install --id $WingetId -e --accept-source-agreements --accept-package-agreements" }
    elseif (Get-Command choco -ErrorAction SilentlyContinue) { $cmd = "choco install $ChocoId -y" }
    Say "MISSING TOOL: '$Tool' is not installed."
    if (-not $cmd) { Say "  No winget or choco found - install $Tool manually and re-run."; return $false }
    $ans = 'N'
    if ($script:Yes) { $ans = 'y' }
    elseif ([Environment]::UserInteractive -and -not $script:Ci) {
        $ans = Read-Host "  Install it now with: $cmd  [y/N]"
        Add-Content -Path $script:Log -Value "  Install prompt answered: $ans" -Encoding UTF8
    }
    else { Say "  Not interactive - skipping. To enable this phase, run: $cmd"; return $false }
    if ($ans -notmatch '^[yY]') { Say "  Skipped. To enable this phase later, run: $cmd"; return $false }
    Say "  Installing: $cmd"
    cmd.exe /c $cmd 2>&1 | Add-Content -Path $script:Log -Encoding UTF8
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Get-Command $Tool -ErrorAction SilentlyContinue) { Say "  '$Tool' installed."; return $true }
    Say '  Install failed - see the log for the package manager output.'
    return $false
}

# ---------------------------------------------------------------------------------------------
# binary selection
# ---------------------------------------------------------------------------------------------
if (-not $Binary) {
    $Binary = Get-ChildItem -Path @('build\win-*', 'Release', 'Debug', '.') -Filter 'Mesh*.exe' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like 'MeshConsole*' -or $_.Name -like 'MeshService*' } |
              Sort-Object @{Expression = { $_.Name -like 'MeshConsole*' }; Descending = $true}, LastWriteTime -Descending |
              Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Binary -or -not (Test-Path $Binary)) {
    Write-Error 'no agent binary found - build the solution or pass -Binary <path to MeshConsole*.exe>'
    exit 2
}
$Binary = (Resolve-Path $Binary).Path

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
    # An MSVC ASan build imports clang_rt.asan*.dll, and the name is in the import table as plain text.
    try { return [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Path)) -match 'clang_rt\.asan' }
    catch { return $false }
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

$RunDrMemory = -not $Quick
$DrMemSkipReason = ''
if ($Quick) { $DrMemSkipReason = 'requested (-Quick)' }
# Package IDs are best-effort. A wrong one just fails the install and the phase skips.
if ($RunDrMemory -and -not (Ensure-Tool 'drmemory' 'DynamoRIO.DrMemory' 'drmemory')) {
    $RunDrMemory = $false; $DrMemSkipReason = 'Dr. Memory not installed'
}

# ---------------------------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------------------------
if (Test-IsAsan $Binary) { $null = Resolve-AsanRuntime $Binary }

Head2 'MeshAgent test driver (Windows)'
Say ("date        : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say "repo        : $RepoRoot"
Say "binary      : $Binary"
Say "             PE machine: $BinMachine, host: $HostArch"
Say ("powershell  : {0}" -f $PSVersionTable.PSVersion)
Say ("elevated    : {0}" -f $(if ($IsElevated) { 'yes' } else { 'NO - some connect paths need it' }))
Say ("dr. memory  : {0}" -f $(if ($RunDrMemory) { 'enabled' } else { "disabled ($DrMemSkipReason)" }))
Say "logfile     : $Log"

if (-not $CanRun) {
    Say ''
    Say "Cannot run an $BinMachine binary on $HostArch - test it on matching hardware."
    exit 1
}

# --- phase 1: -info ---------------------------------------------------------------------------
Head2 '[1/7] agent -info'
$r = Invoke-Agent -FilePath $Binary -ArgumentList @('-info') -TimeoutSec 30
Emit $r 20
if ($r.ExitCode -eq 0) { Record 'agent -info' 'PASS' } else { Record 'agent -info' 'FAIL' (RcDesc $r.ExitCode) }

# --- phase 2: stress test, core sections ------------------------------------------------------
# The 06-* testmodules are the known native-crash sections (TLS reconnect and WebSocket session
# teardown). They run in phase 3, apart from the core, so one crash cannot take every other
# check down with it.
$coreExcl = ((Get-ChildItem 'test\testmodules' -Filter '*.js' | Where-Object { $_.Name -notlike '06-*' } | ForEach-Object { $_.BaseName }) -join ',')
Head2 '[2/7] stress test - every testmodule except the known-crash 06-* sections'
$r = Invoke-Agent -FilePath $Binary -ArgumentList @('test\stress-test.js', '--exclude=06-', '--watchdog=120000') -TimeoutSec 240
Emit $r
$total = ([regex]::Matches($r.Output, 'TOTAL: .*') | Select-Object -Last 1).Value
# Trust the TOTAL line over the exit code, because process.exit(1) does not always survive on Windows.
$failedChecks = if ($total -match 'TOTAL: \d+ passed, (\d+) failed') { [int]$Matches[1] } else { -1 }
if ($r.ExitCode -eq 0 -and $failedChecks -eq 0) { Record 'stress (core)' 'PASS' $total }
elseif ($failedChecks -lt 0) { Record 'stress (core)' 'FAIL' ((RcDesc $r.ExitCode) + ' - no TOTAL line, the run did not finish') }
else { Record 'stress (core)' 'FAIL' ((RcDesc $r.ExitCode) + ' ' + $total) }

# --- phase 3: stress test, TLS section only ---------------------------------------------------
Head2 '[3/7] stress test - known-crash 06-* sections only (TLS, WebSocket - meshagent-todo.md #1/#2)'
$r = Invoke-Agent -FilePath $Binary -ArgumentList @('test\stress-test.js', "--exclude=$coreExcl", '--watchdog=40000') -TimeoutSec 120
Emit $r
$knownTls = @(254, -1073741819, -2147483645)
if ($r.ExitCode -eq 0) { Record 'stress (known 06-*)' 'PASS' 'the #1 reconnect-after-end() crash did NOT reproduce' }
elseif ($knownTls -contains $r.ExitCode) {
    if ($Strict) { Record 'stress (known 06-*)' 'FAIL' ((RcDesc $r.ExitCode) + ' - known crash, meshagent-todo.md #1') }
    else { Record 'stress (known 06-*)' 'KNOWN' ((RcDesc $r.ExitCode) + ' - reconnect-after-end() crash, meshagent-todo.md #1') }
}
else { Record 'stress (known 06-*)' 'FAIL' ((RcDesc $r.ExitCode) + ' (unexpected - not the known crash signature)') }

# --- phase 4: the core run again, delivered the way meshcore is (-b64exec) -------------------
Head2 '[4/7] stress test via -b64exec (meshcore delivery path)'
# argv is empty under -b64exec, so the exclude and watchdog defaults are patched into the script.
$src = Get-Content -Raw 'test\stress-test.js'
$src = $src -replace '(?m)^var OPT_EXCLUDE = \[\];', 'var OPT_EXCLUDE = ["06-"];' -replace '(?m)^var OPT_WATCHDOG = 10000;', 'var OPT_WATCHDOG = 60000;'
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($src))
$r = Invoke-Agent -FilePath $Binary -ArgumentList @('-b64exec', $b64) -TimeoutSec 180
Emit $r 30
$b64Total = ([regex]::Matches($r.Output, 'TOTAL: .*') | Select-Object -Last 1).Value
$b64Failed = if ($b64Total -match 'TOTAL: \d+ passed, (\d+) failed') { [int]$Matches[1] } else { -1 }
if ($r.ExitCode -eq 0 -and $b64Failed -eq 0 -and $b64Total -eq $total) { Record 'stress (-b64exec)' 'PASS' $b64Total }
elseif ($r.ExitCode -eq 0 -and $b64Failed -eq 0) { Record 'stress (-b64exec)' 'FAIL' "passed, but ran a different check count than phase 2: '$b64Total' vs '$total'" }
elseif ($b64Failed -lt 0) { Record 'stress (-b64exec)' 'FAIL' ((RcDesc $r.ExitCode) + ' - no TOTAL line, the run did not finish') }
else { Record 'stress (-b64exec)' 'FAIL' ((RcDesc $r.ExitCode) + ' ' + $b64Total) }

# --- phase 5: connection test against <binary>.msh ---------------------------------------------
$msh = [IO.Path]::ChangeExtension($Binary, '.msh')
Head2 ('[5/7] connection test ({0})' -f (Split-Path -Leaf $msh))
if ($NoConnect) {
    Say '  skipped by request (-NoConnect)'
    Record 'connection test' 'SKIP' '-NoConnect'
}
elseif (-not (Test-Path $msh)) {
    Say ("  no {0} next to the agent - nothing to connect to" -f (Split-Path -Leaf $msh))
    Record 'connection test' 'SKIP' ('no ' + (Split-Path -Leaf $msh))
}
else {
    # The last MeshServer= line wins. These .msh files set it twice, local first, then the real wss:// URL.
    $srv = (Select-String -Path $msh -Pattern '^MeshServer=' | Select-Object -Last 1).Line -replace '^MeshServer=', ''
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
        Say ("  running '{0} connect' for up to 20s (writes .db/.log next to the agent)" -f (Split-Path -Leaf $Binary))
        # --showModuleNames=1 forces the db key from the command line. A key set in the .msh still
        # wins, since the .msh is imported after the command-line values are cached.
        $verb = 'connect'
        $r = Invoke-Agent -FilePath $Binary -ArgumentList @($verb, '--showModuleNames=1') -TimeoutSec 20 -StopWhen 'Launching meshcore'
        Emit $r 25
        $missing = @()
        # 'Launching meshcore' is the real end state. Authentication alone can succeed while
        # meshcore still fails to start.
        foreach ($m in @('Control Channel Connection Established', 'Connected.', 'Authentication Complete', 'Launching meshcore')) {
            if (-not $r.Output.Contains($m)) { $missing += "missing '$m'" }
        }
        # The node cert and its server must have been persisted, or the agent re-provisions on
        # every start.
        $db = [IO.Path]::ChangeExtension($Binary, '.db')
        if (Test-Path $db) {
            foreach ($k in @('SelfNodeCert', 'MeshServer')) {
                if (-not (Select-String -Path $db -Pattern $k -SimpleMatch -Encoding Ascii -Quiet)) { $missing += "'$k' not persisted in $(Split-Path -Leaf $db)" }
            }
        }
        else { $missing += "no $(Split-Path -Leaf $db) written" }
        if ($missing.Count -eq 0) { Record 'connection test' 'PASS' "connected, authenticated, meshcore launched, identity persisted ($srv)" }
        else {
            # The agent's C-level printf output is block-buffered when stdout is a pipe, so a run
            # that has to be killed can lose everything it printed. Say so instead of blaming it.
            $hint = ''
            if (($r.Output -split "`r?`n" | Where-Object { $_ -ne '' }).Count -lt 5) {
                $hint = ' - almost no output captured; the agent block-buffers stdout when redirected and was still running when killed'
                Say "  $hint"
                Say "  confirm by hand: .\$(Split-Path -Leaf $Binary) $verb > out.txt 2>&1  (Ctrl-C to stop, then read out.txt)"
            }
            Record 'connection test' 'FAIL' (($missing -join ', ') + $hint)
        }
    }
}

# --- phase 7: Dr. Memory over the core stress run ----------------------------------------------
Head2 '[6/7] Dr. Memory - core stress run'
if (-not $RunDrMemory) {
    Say "  reason: $DrMemSkipReason"
    Record 'drmemory (stress)' 'SKIP' $DrMemSkipReason
}
else {
    $dmLog = Join-Path $TmpDir 'drmemory'
    $null = New-Item -ItemType Directory -Force -Path $dmLog
    Say '  (Dr. Memory is far slower than a bare run - the stress watchdog is raised to match)'
    $r = Invoke-Agent -FilePath (Get-Command drmemory).Source -TimeoutSec 900 -ArgumentList @(
        '-batch', '-logdir', $dmLog, '--', $Binary, 'test\stress-test.js', '--exclude=06-', '--watchdog=300000')
    Emit $r 15
    $results = Get-ChildItem -Path $dmLog -Recurse -Filter 'results.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $results) {
        Say '  Dr. Memory produced no results.txt - it did not run the program'
        if ($r.Output -match 'failed to start the target application|internal crash') {
            # Known upstream breakage on Windows 11 24H2 and later (DynamoRIO/drmemory #2543 and #2539).
            Say '  Dr. Memory itself failed, before the agent ran. To confirm it is not this agent:'
            Say '    drmemory -batch -- C:\Windows\System32\where.exe /?'
            Say '    "C:\Program Files (x86)\Dr. Memory\dynamorio\bin64\drrun.exe" -- .\<agent>.exe -info'
            Record 'drmemory (stress)' 'SKIP' 'Dr. Memory itself crashed/failed to start - the agent was not tested'
        }
        else { Record 'drmemory (stress)' 'FAIL' 'no report produced - see the log' }
    }
    else {
        $txt = Get-Content -Raw $results.FullName
        Add-Content -Path $Log -Value $txt -Encoding UTF8
        $leaks = ([regex]::Match($txt, '(?m)^\s*ERRORS FOUND:.*$')).Value
        $bytes = ([regex]::Match($txt, '(?m)^\s*\d+ total.*leak.*$')).Value
        foreach ($l in @($leaks, $bytes)) { if ($l) { Say ('  ' + $l.Trim()) } }
        if ($txt -match 'LEAK\s+\d+ direct bytes') { Record 'drmemory (stress)' 'FAIL' 'definite leak reported - see the log' }
        else { Record 'drmemory (stress)' 'PASS' ($leaks.Trim()) }
    }
}

# --- phase 8: AddressSanitizer over the core stress run ----------------------------------------
Head2 '[7/7] AddressSanitizer - core stress run'
if (-not $Asan) {
    $cand = [IO.Path]::ChangeExtension($Binary, $null) + '_asan.exe'
    if (Test-Path $cand) { $Asan = $cand }
    elseif (Test-IsAsan $Binary) { $Asan = $Binary }
}
if (-not $Asan) {
    Say '  no ASan build found - make one with:'
    Say '    msbuild MeshAgent-2022.sln /p:Configuration=Release /p:Platform=x64 /p:EnableASAN=true'
    Record 'asan (stress)' 'SKIP' 'no ASan build'
}
elseif (-not (Test-Path $Asan)) {
    Record 'asan (stress)' 'FAIL' "$Asan not found"
}
else {
    Say "  using $Asan"
    $null = Resolve-AsanRuntime $Asan
    $env:ASAN_OPTIONS = 'halt_on_error=0:print_legend=0'
    $r = Invoke-Agent -FilePath $Asan -TimeoutSec 600 -ArgumentList @(
        'test\stress-test.js', '--exclude=06-', '--watchdog=300000')
    Remove-Item Env:\ASAN_OPTIONS -ErrorAction SilentlyContinue
    Emit $r 12
    $reports = ([regex]::Matches($r.Output, 'ERROR: AddressSanitizer')).Count
    $total = ([regex]::Matches($r.Output, 'TOTAL: .*') | Select-Object -Last 1).Value
    if ($reports -gt 0) {
        Say "  $reports AddressSanitizer report(s):"
        [regex]::Matches($r.Output, '(?m)^\s+#[01] 0x[0-9a-f]+ in (.+)$') |
            ForEach-Object { '    ' + $_.Groups[1].Value } | Sort-Object -Unique | Select-Object -First 10 |
            ForEach-Object { Say $_ }
        Record 'asan (stress)' 'FAIL' "$reports report(s) - $total"
    }
    elseif (@(-1073741515, -1073741511) -contains $r.ExitCode) {
        Say '  the ASan runtime still does not match this binary - build and test with one toolset,'
        Say '  or pass -AsanRuntimeDir <dir containing clang_rt.asan_dynamic-*.dll>.'
        Record 'asan (stress)' 'FAIL' (RcDesc $r.ExitCode)
    }
    elseif (-not $total) { Record 'asan (stress)' 'FAIL' ((RcDesc $r.ExitCode) + ' - the run did not finish') }
    else { Record 'asan (stress)' 'PASS' "no ASan reports - $total" }
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
Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
exit $(if ($Failed -gt 0) { 1 } else { 0 })
