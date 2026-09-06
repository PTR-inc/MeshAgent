# Build one or more Windows OpenSSL targets and stage them into the repo as install prefixes,
# openssl\<version>\<target>\ with lib\libcrypto.lib, lib\libssl.lib and include\openssl\opensslconf.h.
# Run it as build.ps1 windows-x64, build.ps1 all, or build.ps1 list for the target table.
# A target whose staged prefix was built from the same version, Configure flags and recipe is
# left alone. -Force rebuilds it anyway. -InstallMissing adds a missing toolset or SDK without
# asking, for an unattended run.
# By default it prints phase progress, warnings and errors. Add -verbose for the full log: the
# per-target facts and the raw tar, Configure and nmake output.

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$TargetNames,
    [switch]$Force,
    # Build the -debug twin of each named target instead, e.g. -DebugBuild windows-x64 (or -Dbg,
    # the same short form build.sh takes) builds windows-x64-debug. Not called -Debug because the
    # [Parameter()] attribute above makes this an advanced script and PowerShell supplies -Debug
    # itself. A "...-debug" name is left alone.
    [Alias('Dbg')][switch]$DebugBuild,
    [switch]$InstallMissing,
    # Where the tarball, the tools and the per-target source trees live. Same meaning as the
    # BUILDROOT environment variable, which stays the way to set it for a whole session.
    [string]$BuildRoot = '',
    # Just the scratch trees, leaving the downloads and tools where they are. Each target is
    # extracted and compiled in here, so it is the directory worth putting on a fast disk or one
    # the virus scanner is told to leave alone.
    [string]$WorkDir = '',
    # Parallel compile jobs when jom is available. 0 means one per logical processor.
    [int]$Jobs = 0
)

# -verbose is not declared as a parameter: the [Parameter()] attribute above makes this an
# advanced script, so PowerShell supplies -verbose itself and declaring it again is an error.
# It reaches us as $VerbosePreference, which also honours -verbose:$false and an inherited value.
$IsVerbose = $VerbosePreference -ne 'SilentlyContinue'

# Per-target detail, written only when -verbose is given. Progress, warnings, errors and the
# per-target verdict stay in the default output and call Write-Host directly.
function Info([string]$Message) { if ($IsVerbose) { Write-Host $Message } }

# What counts as worth printing from a command's own output on an otherwise successful run.
# Matches the compiler, linker, nmake and perl spellings: 'warning C4996', 'fatal error LNK1181',
# 'perl: warning:'. Anchored on the words so a source file named err.c does not trip it.
$ProblemPattern = '(?i)\b(warning|error)\b'

# Narrowing size_t and __int64 conversions all through crypto\. Upstream 1.1.1 does not fix
# them and several cannot be fixed without changing a public return type, so they say nothing
# about a given run. The compiler still emits them: -verbose and any failed build show them.
$ProblemIgnorePattern = 'C4267|C4244'

# One entry per target, derived from the name: Debug from the -debug suffix, the vcvars pair from
# the arch (arm64 cross-builds with x64 host tools), asm off for arm64 (VC-WIN64-ARM has no asm path).
# consistency.sh check 5 keeps names, VcConf, --debug and asm in step with targets.sh's windows rows.
$VcConfByArch = @{ x86 = 'VC-WIN32'; x64 = 'VC-WIN64A'; arm64 = 'VC-WIN64-ARM' }

# The shared flags file is written for the unix targets, so it carries GCC/Clang flags that cl
# only answers with 'warning D9002: ignoring unknown option'. -fPIC needs no MSVC equivalent (PE
# ASLR is the linker's /DYNAMICBASE, on by default) and the VC-WIN* targets set their own /std:.
# Patterns, not literals, so a later dialect bump such as -std=gnu17 is still dropped.
$MsvcUnsupportedFlagPatterns = @('^-fPIC$', '^-std=')

$Targets = @('windows-x86', 'windows-x86-debug', 'windows-x64', 'windows-x64-debug', 'windows-arm64', 'windows-arm64-debug') |
    ForEach-Object {
        $arch = $_ -replace '^windows-', '' -replace '-debug$', ''
        @{ Name = $_; VcVars = $(if ($arch -eq 'arm64') { 'x64_arm64' } else { $arch })
           VcConf = $VcConfByArch[$arch]; Asm = ($arch -ne 'arm64'); Debug = $_.EndsWith('-debug') }
    }

. (Join-Path $PSScriptRoot 'env.ps1')

# After env.ps1, which settles the defaults, and before anything reads them. env.ps1 prints its
# banner as it is dot-sourced, so an override has to say where things actually ended up.
if ($BuildRoot -or $WorkDir) {
    if ($BuildRoot) { Set-BuildRoot (Resolve-BrPath $BuildRoot) }
    if ($WorkDir) { $env:BR_WORK = Resolve-BrPath $WorkDir }
    Write-Host "BUILDROOT=$env:BUILDROOT  (work $env:BR_WORK)"
}

# asm needs NASM. Looked up here rather than with the other tools because `list` reports a stamp,
# and the stamp records whether the archives were built with asm.
$nasm = Get-NasmPath
$nasmDir = if ($nasm) { Split-Path -Parent $nasm } else { $null }

# nmake is strictly serial, so a target costs whatever one core can do. jom is Qt's drop-in clone
# that takes /J, and it is used for the two archives when it is there. Absent, nothing changes.
$jom = Get-JomPath
$jomJobs = if ($Jobs -gt 0) { $Jobs } else { [int]$env:NUMBER_OF_PROCESSORS }
if ($jomJobs -lt 1) { $jomJobs = 1 }

# The Configure command line for one target: the shared flags file minus what cl cannot take, with
# -no-asm dropped when NASM is present. The build passes exactly this, so the stamp can record it.
function Get-ConfigureFlags($t) {
    $flags = ($script:OsslFlags -split '\s+' | Where-Object {
            $tok = $_
            $tok -and -not ($MsvcUnsupportedFlagPatterns | Where-Object { $tok -match $_ })
        }) -join ' '
    if ($t.Asm -and $nasm) { $flags = $flags -replace '-no-asm', '' }
    return $flags
}

# With no-shared, OpenSSL's VC-noCE-common never emits /MD or /MDd; it puts "/MT /Zl" in lib_cflags for
# debug and release alike, so a --debug build has to have that /MT rewritten to /MTd here. /Zl stays, so
# the objects carry no /DEFAULTLIB and the agent's own CRT choice wins at link time.
# Release builds also drop /Zi and nasm -g, which VC-common forces even in release. The patch runs
# through perl, already a hard requirement, rather than a quoting-fragile nested powershell.
function Get-MakefilePatch($t) {
    # /Z7 rather than the /Zi and /Fdossl_static.pdb that VC-common asks for: one shared PDB has a
    # single writer, so parallel compiles die with 'C1041: cannot open program database'. /Z7 puts
    # the debug info in each object instead, which is also what reaches the agent's own PDB at link
    # time, since only the libs and opensslconf.h are staged and that PDB never was.
    if ($t.Debug) { return 's{/MT\b}{/MTd}g; s{/Zi /Fdossl_static\.pdb}{/Z7}g' }
    return 's{/MD\b}{/MT}g; s{/Zi /Fdossl_static\.pdb }{}g; s{ASFLAGS=-g}{ASFLAGS=}g'
}

# Every input that changes what the archives contain: the source version, the compiler, the SDK, the
# Configure target and flags, and the makefile rewrite that picks the CRT. openssl\VERSION also
# names the prefix, so a version bump is a rebuild by construction rather than by this stamp.
# The toolset is the full 14.44.35207, not the Major.Minor vcvars_ver wants: a patch-level bump
# changes the objects' @comp.id, which is exactly what toolset-check.ps1 flags afterwards.
# The SDK is in here because ucrt and um headers compile into the objects as surely as the compiler
# does, and the VC.Tools components do not carry one, so it moves independently.
function Get-BuildStamp($t) {
    @(
        "version=$($script:OpenSslVersion)"
        "toolset=$(Get-VcToolsetVersion -Arch $t.VcVars -Full)"
        "sdk=$(Get-WindowsSdkVersion -Arch $t.VcVars)"
        "vcconf=$($t.VcConf)"
        "configure=$($t.VcConf) $(if ($t.Debug) { '--debug' }) $(Get-ConfigureFlags $t)"
        "makefile-patch=$(Get-MakefilePatch $t)"
    ) -join "`n"
}

# One definition of "the staged prefix already matches what a build would produce", used by the
# stamp column in `list` and by the skip in the build loop. 'unknown' rather than 'stale' when the
# toolset or SDK cannot be read, because a stamp built from blanks would condemn every target.
function Get-StampState($t) {
    $prefix = Join-Path $script:OpenSslPrefixRoot $t.Name
    $have = @('lib\libcrypto.lib', 'lib\libssl.lib', 'include\openssl\opensslconf.h') |
        ForEach-Object { Test-Path (Join-Path $prefix $_) }
    if ($have -contains $false) { return 'absent' }
    if (-not (Get-VcToolsetVersion -Arch $t.VcVars -Full) -or -not (Get-WindowsSdkVersion -Arch $t.VcVars)) { return 'unknown' }
    $stampFile = Join-Path $prefix 'build-stamp.txt'
    if (-not (Test-Path $stampFile)) { return 'stale' }
    if ((((Get-Content $stampFile -Raw) -replace "`r`n", "`n").TrimEnd()) -eq (Get-BuildStamp $t)) { return 'ok' }
    return 'stale'
}

if (-not $TargetNames -or $TargetNames.Count -eq 0) {
    Write-Host "usage: build.ps1 [-Force] [-DebugBuild|-Dbg] [-InstallMissing] [-BuildRoot <dir>] [-WorkDir <dir>] [-Jobs <n>] [-verbose] <target|all|list> [target...]"
    Write-Host "targets: $($Targets.Name -join ' ')"
    exit 2
}
# One row per target with the MSBuild consumer that links each prefix. ARCHIDs are a unix
# makefile concept; on Windows the props derive the target from $(Platform) and $(MeshDebug),
# so that platform/configuration pairing is what a per-consumer listing means here.
# What every row shares, so the per-target columns carry only what differs. Gathered across the
# listed targets and joined, so a machine whose architectures resolve different toolsets or SDKs
# says so rather than reporting the first one found as the truth.
function Get-CommonProperties($targets) {
    $uniq = { param($v) $j = @($v | Where-Object { $_ } | Select-Object -Unique); if ($j) { $j -join ', ' } else { 'none' } }
    return @(
        "openssl $($script:OpenSslVersion)"
        "msvc $(& $uniq ($targets | ForEach-Object { Get-VcToolsetVersion -Arch $_.VcVars -Full }))"
        "sdk $(& $uniq ($targets | ForEach-Object { Get-WindowsSdkVersion -Arch $_.VcVars }))"
        "nasm $(if ($nasm) { Get-NasmVersion } else { 'not found, every target falls back to -no-asm' })"
        "make $(if ($jom) { "jom /J $jomJobs" } else { 'nmake, serial - install jom for a parallel build' })"
        "work $env:BR_WORK"
    ) -join '   '
}

# The Configure flags every target shares, which is what the flags file resolves to once cl's
# unsupported options are dropped. -no-asm is left out because it is per-target: the ASM column
# says which targets keep it.
function Get-CommonFlags {
    return ((Get-ConfigureFlags @{ Asm = $true }) -replace '-no-asm', '').Trim() -replace '\s+', ' '
}

function Get-NasmVersion {
    if (-not $nasm) { return $null }
    $v = & $nasm -v 2>$null
    if ("$v" -match 'NASM version ([0-9][0-9.]*)') { return $Matches[1] }
    return 'unknown version'
}


# Which stamp lines a build would write differently, so a stale row says what moved rather than only
# that something did.
function Get-StampReason($t) {
    $file = Join-Path (Join-Path $script:OpenSslPrefixRoot $t.Name) 'build-stamp.txt'
    if (-not (Test-Path $file)) { return 'never stamped' }
    $was = @{}
    foreach ($l in (((Get-Content $file -Raw) -replace "`r`n", "`n").TrimEnd() -split "`n")) {
        $k, $v = $l -split '=', 2
        $was[$k] = $v
    }
    $why = @()
    foreach ($l in ((Get-BuildStamp $t) -split "`n")) {
        $k, $v = $l -split '=', 2
        if (-not $was.ContainsKey($k)) { $why += "+$k"; continue }
        if ($was[$k] -ne $v) { $why += $k }
        $was.Remove($k)
    }
    # Whatever is left was in the old stamp and is not written any more, which is a recipe change too.
    $why += @($was.Keys | ForEach-Object { "-$_" })
    $why = @($why | Select-Object -Unique)
    if (-not $why) { return 'stamp text differs' }
    return ($why -join ', ')
}

if ($TargetNames[0] -eq 'list') {
    Get-CommonProperties $Targets | Write-Host
    "flags $(Get-CommonFlags)   (-no-asm on top for every target whose ASM column says off)" | Write-Host
    '' | Write-Host
    # ok = a build would reproduce it, stale = the recipe moved, absent = not staged,
    # unknown = no toolset or SDK on this machine to compare against.
    $rows = foreach ($t in $Targets) {
        $arch = $t.Name -replace '^windows-', '' -replace '-debug$', ''
        $plat = if ($arch -eq 'x86') { 'Win32' } elseif ($arch -eq 'arm64') { 'ARM64' } else { 'x64' }
        $state = Get-StampState $t
        if ($state -eq 'stale') { $state = "stale ($(Get-StampReason $t))" }
        [pscustomobject]@{ Name = $t.Name; State = $state
                           Consumer = '{0} {1}' -f $plat, $(if ($t.Debug) { 'Debug' } else { 'Release' })
                           # What this run would actually do, not what the target asks for: asm
                           # needs NASM, and a buildroot without it silently builds -no-asm.
                           VcConf = $t.VcConf; Asm = $(if ($t.Asm -and $nasm) { 'on' } elseif ($t.Asm) { 'n/a' } else { 'off' })
                           Prefix = "openssl\$($script:OpenSslVersion)\$($t.Name)" }
    }
    # The stale reasons decide how wide the column has to be, so it is measured rather than guessed:
    # a table with nothing stale stays narrow instead of carrying room for a reason that never comes.
    $w = [Math]::Max(5, ($rows.State | Measure-Object -Property Length -Maximum).Maximum)
    $fmt = "{0,-22} {1,-$w} {2,-14} {3,-13} {4,-4} {5}"
    $fmt -f 'TARGET', 'STAMP', 'CONSUMER', 'VCCONF', 'ASM', 'PREFIX' | Write-Host
    foreach ($r in $rows) { $fmt -f $r.Name, $r.State, $r.Consumer, $r.VcConf, $r.Asm, $r.Prefix | Write-Host }
    exit 0
}
# A misspelled name must refuse the whole run, not be silently dropped from the list.
if ($TargetNames[0] -ne 'all') {
    # -DebugBuild builds the -debug twin of each named target instead. 'all' already covers every
    # -debug row on its own, so this only matters for an explicit target list.
    if ($DebugBuild) {
        $TargetNames = $TargetNames | ForEach-Object { if ($_.EndsWith('-debug')) { $_ } else { "$_-debug" } }
    }
    $unknown = @($TargetNames | Where-Object { $Targets.Name -notcontains $_ })
    if ($unknown.Count -gt 0) {
        Write-Host "unknown target(s): $($unknown -join ' ')"
        Write-Host "targets: $($Targets.Name -join ' ')"
        exit 2
    }
}
$list = if ($TargetNames[0] -eq 'all') { $Targets } else { $Targets | Where-Object { $TargetNames -contains $_.Name } }

if (-not (Test-Path $script:OpenSslTarball)) {
    Write-Host "MISSING: $script:OpenSslTarball - fetch it first, see README.md"
    exit 1
}

$vcEnv = Get-VcEnvScript
if (-not $vcEnv) { Write-Host "MISSING: no usable Visual Studio install found (need vcvarsall.bat or VsDevCmd.bat)"; exit 1 }

$perl = Get-PerlPath
if (-not $perl) { Write-Host "MISSING: perl.exe - Configure cannot run without it"; exit 1 }
$perlDir = Split-Path -Parent $perl

# Refuse up front, because an incomplete toolset for a target only shows up as a link failure deep
# into nmake, and a toolset without an SDK gives a working cl.exe that then dies on stdlib.h.
function Get-MissingVsComponents([string[]]$arches) {
    $missing = @()
    foreach ($a in $arches) {
        $tv = Get-MeshVcToolsVersion
        if (-not (Get-VcToolsetVersion -Arch $a)) {
            $missing += "MSVC toolset for $a`: $(if ($tv) { "$tv (pinned by MeshAgent.Configuration.props)" } else { 'any complete one' })"
        }
        if (-not (Get-WindowsSdkVersion -Arch $a)) {
            $want = if (Get-MeshWindowsSdkVersion) { "$(Get-MeshWindowsSdkVersion) (pinned by MeshAgent.Sdk.props)" }
                    else { "at or above the $(Get-MeshMinWindowsSdk) floor (MeshAgent.Common.props)" }
            $missing += "Windows SDK for $a`: $want"
        }
    }
    return @($missing)
}

$vcArches = @($list.VcVars | Select-Object -Unique)
$missing = Get-MissingVsComponents $vcArches
if ($missing.Count -gt 0) {
    Write-Host "MISSING:"
    $missing | ForEach-Object { Write-Host "  $_" }
    # env.ps1's installer resolves the component ids from the VS catalog and asks again before it
    # elevates, so this only decides whether to start it. A host that cannot prompt says no.
    # Modifying a Visual Studio install is an administrator operation, so say up front whether
    # answering yes will put a UAC dialog on screen. An elevated session gets none.
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
    $uac = if ($elevated) { 'already elevated, no UAC prompt' } else { 'Windows will ask for administrator rights' }
    if ($InstallMissing) {
        # Still not silent from Windows' point of view unless the session is already elevated:
        # the installer is started with RunAs and UAC is the operating system's call, not ours.
        Write-Host "  -InstallMissing: adding them without asking ($uac)"
        $answer = 'y'
    }
    else {
        $answer = try { Read-Host "  run the Visual Studio installer to add these now? $uac [y/N]" } catch { '' }
    }
    if ($answer -match '^\s*y(es)?\s*$') {
        # -BuildRoot keeps it from asking for a path this script has already settled. -Force skips
        # env.ps1's own confirmation, -Quiet drops the installer's progress window too.
        if ($InstallMissing) { Install-BuildRootWindows -BuildRoot $env:BUILDROOT -VsComponents -Force -Quiet }
        else                 { Install-BuildRootWindows -BuildRoot $env:BUILDROOT -VsComponents }
        $missing = Get-MissingVsComponents $vcArches
        # The installer offers the newest SDK its catalog lists, which is not necessarily the pinned one.
        if ($missing.Count -gt 0) { Write-Host "  still missing after the installer:"; $missing | ForEach-Object { Write-Host "    $_" } }
    }
    if ($missing.Count -gt 0) {
        Write-Host "  add them from the Visual Studio installer UI, or see README.md"
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $env:BR_WORK | Out-Null

# Minutes and seconds, or seconds alone under a minute. A build is worth timing because the only
# lever on it is how long it takes: nmake has no parallel option, so this is what a target costs.
function Format-Elapsed([TimeSpan]$span) {
    if ($span.TotalMinutes -lt 1) { return ('{0:0.0}s' -f $span.TotalSeconds) }
    return ('{0}m {1:00}s' -f [int]$span.TotalMinutes, $span.Seconds)
}

$overallOk = $true
$runStart = [Diagnostics.Stopwatch]::StartNew()
$timings = @()
$staged = @()
$rebuilt = @()
foreach ($t in $list) {
    $name = $t.Name
    $targetStart = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "=================== $name ($($t.VcConf)) ==================="

    $flags = Get-ConfigureFlags $t
    if ($t.Asm -and -not $nasm) {
        Write-Host "  nasm not found - building $name with -no-asm instead of the CI's asm-enabled recipe"
    }
    $debugFlag = if ($t.Debug) { '--debug' } else { '' }
    $makefilePatch = Get-MakefilePatch $t

    # Nothing about the recipe changed and all three staged files are there, so there is nothing to
    # rebuild. The prefix still goes to the audit below, because it is what the agent will link.
    $prefix = Join-Path $script:OpenSslPrefixRoot $name
    $stampFile = Join-Path $prefix 'build-stamp.txt'
    $stamp = Get-BuildStamp $t
    if ((Get-StampState $t) -eq 'ok' -and -not $Force) {
        Write-Host "${name}: up to date (-Force rebuilds it)"
        $staged += $name
        continue
    }

    Write-Host "  [1/4] extract"
    $src = Join-Path $env:BR_WORK $name
    if (Test-Path $src) {
        # OpenSSL's makefile can leave a literal file named NUL, a reserved device
        # name that Remove-Item cannot touch without the \\?\ prefix.
        $nulFile = "\\?\$src\NUL"
        if (Test-Path -LiteralPath $nulFile) { Remove-Item -LiteralPath $nulFile -Force -ErrorAction SilentlyContinue }
        Remove-Item -Recurse -Force $src -ErrorAction SilentlyContinue
        if (Test-Path $src) { & cmd.exe /c "rd /s /q `"$src`"" }
    }
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    # Windows' own bsdtar, not whatever tar is on PATH: a shell like Git Bash puts MSYS tar first,
    # and that one reads the D: in an archive path as a remote host ('Cannot connect to D:').
    $tar = Join-Path $env:SystemRoot 'System32	ar.exe'
    if (-not (Test-Path $tar)) { $tar = 'tar' }
    $tarLog = @(& $tar xzf $script:OpenSslTarball -C $src --strip-components=1 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        $tarLog | ForEach-Object { Write-Host $_ }
        Write-Host "${name}: EXTRACT FAILED"; $overallOk = $false; continue
    }
    if ($IsVerbose) { $tarLog | ForEach-Object { Write-Host $_ } }

    # Each target gets its own cmd.exe session because the vcvars script only mutates its
    # own process. PATH is extended before the call so its own vswhere.exe lookup succeeds.
    $vswhereDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $extraPath = @($nasmDir, $perlDir, $vswhereDir) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    $cmdLines = @()
    # Strawberry Perl is a native Windows build with no POSIX locales, so a LANG or LC_* inherited
    # from a shell like Git Bash makes every perl call here warn and fall back. Clear them for the
    # session rather than leaving the warning in the log of an otherwise clean build.
    $cmdLines += @('LANG', 'LC_ALL', 'LC_CTYPE', 'LC_COLLATE', 'LC_MESSAGES', 'LC_MONETARY',
                   'LC_NUMERIC', 'LC_TIME') | ForEach-Object { "set `"$_=`"" }
    if ($extraPath) { $cmdLines += "set `"PATH=$($extraPath -join ';');%PATH%`"" }
    $vcEnvCall = Get-VcEnvCall -Arch $t.VcVars
    $cmdLines += @(
        "$vcEnvCall >nul"
        "if errorlevel 1 exit /b 1"
    )
    $cmdLines += @(
        "cd /d `"$src`""
        "perl Configure $($t.VcConf) $debugFlag $flags"
        "if errorlevel 1 exit /b 1"
        "perl -pi.bak -e `"$makefilePatch`" makefile"
        "if errorlevel 1 exit /b 1"
        "del makefile.bak"
        # A bare nmake builds openssl.exe, 11 fuzzers and 165 test binaries as well as the two
        # archives, and every C4267/C4244 in the log comes from apps\, which only libapps.lib
        # and those programs need. build_libs is no help: LIBS names libapps.lib too. Naming the
        # two archives builds only what gets staged. build_generated first, because
        # include\openssl\opensslconf.h is a mandatory generated file the staging step copies.
        # The depend step the stock targets run first is for incremental rebuilds, and this
        # script always builds from a freshly extracted tree.
        # build_generated stays on nmake: it is a handful of perl runs whose outputs the compile
        # step depends on, and 1.1.1w does not declare those dependencies well enough to trust a
        # parallel run with them. Only the two archives, which are thousands of independent
        # compiles, go to jom.
        "nmake build_generated"
        "if errorlevel 1 exit /b 1"
        $(if ($jom) { "`"$jom`" /J $jomJobs libcrypto.lib libssl.lib" } else { "nmake libcrypto.lib libssl.lib" })
    )
    $cmdFile = Join-Path $src 'do-build.cmd'
    $cmdLines -join "`r`n" | Set-Content -Path $cmdFile -Encoding ASCII

    Write-Host "  [2/4] configure and build"
    # Verbose streams the build live, the way it always did. Quiet captures it and then shows
    # either every line (the build failed) or only the warning and error lines (it did not).
    if ($IsVerbose) {
        & cmd.exe /c "`"$cmdFile`""
        $buildCode = $LASTEXITCODE
    }
    else {
        $buildLog = @(& cmd.exe /c "`"$cmdFile`"" 2>&1 | ForEach-Object { "$_" })
        $buildCode = $LASTEXITCODE
        $show = if ($buildCode -ne 0) { $buildLog }
                else { $buildLog | Where-Object { $_ -match $ProblemPattern -and $_ -notmatch $ProblemIgnorePattern } }
        $show | ForEach-Object { Write-Host $_ }
    }
    if ($buildCode -ne 0) {
        Write-Host "${name}: BUILD FAILED (exit $buildCode) - see $src\do-build.cmd and the nmake output above"
        $overallOk = $false
        continue
    }

    Write-Host "  [3/4] verify"
    $libcrypto = Join-Path $src 'libcrypto.lib'
    $libssl = Join-Path $src 'libssl.lib'
    if (-not (Test-Path $libcrypto) -or -not (Test-Path $libssl)) {
        Write-Host "${name}: REJECTED - libcrypto.lib/libssl.lib not produced"
        $overallOk = $false
        continue
    }

    $versionMatch = Select-String -Path $libcrypto -Pattern "OpenSSL $($script:OpenSslVersion) " -SimpleMatch -Encoding Ascii
    if (-not $versionMatch) {
        Write-Host "${name}: REJECTED - version string 'OpenSSL $($script:OpenSslVersion) ' not found in libcrypto.lib"
        $overallOk = $false
        continue
    }

    # The object count is reported only. It is not a gate, since it moves with every flag and
    # toolset change. Inspect-Archive (env.ps1) parses the COFF archive itself, so no second
    # vcvars session for lib /list is needed.
    $info = try { Inspect-Archive $libcrypto } catch { $null }
    if (-not $info) {
        Write-Host "${name}: REJECTED - libcrypto.lib is not a readable COFF archive"
        $overallOk = $false
        continue
    }
    Info "  version : OK ($($script:OpenSslVersion))"
    Info "  objects : $($info.objs)"
    Info "  platform: $($info.platform)"

    # In 1.1.1 nmake, not Configure, writes include\openssl\opensslconf.h, so it is only copied after the build.
    $conf = Join-Path $src 'include\openssl\opensslconf.h'
    if (-not (Test-Path $conf)) {
        Write-Host "${name}: REJECTED - include\openssl\opensslconf.h not generated"
        $overallOk = $false
        continue
    }

    # Stage only the three files the agent build consumes. nmake install_dev would need a
    # prefix and installs much more than that.
    Write-Host "  [4/4] stage"
    $libDir = Join-Path $prefix 'lib'
    $incDir = Join-Path $prefix 'include\openssl'
    New-Item -ItemType Directory -Force -Path $libDir, $incDir | Out-Null
    Copy-Item $libcrypto (Join-Path $libDir 'libcrypto.lib') -Force
    Copy-Item $libssl    (Join-Path $libDir 'libssl.lib') -Force
    # nmake writes CRLF; the repo normalises text to LF, so stage it that way and avoid a spurious diff.
    [IO.File]::WriteAllText((Join-Path $incDir 'opensslconf.h'), ([IO.File]::ReadAllText($conf) -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    # Written last, so a stamp on disk also proves the three files above were all copied. LF, for
    # the same reason opensslconf.h is staged that way: the repo normalises text and this is committed.
    [IO.File]::WriteAllText($stampFile, $stamp + "`n", [Text.UTF8Encoding]::new($false))
    Info "  staged  -> $prefix (lib\libcrypto.lib, lib\libssl.lib, include\openssl\opensslconf.h)"
    $staged += $name
    $rebuilt += $name
    $timings += [pscustomobject]@{ Name = $name; Elapsed = $targetStart.Elapsed }
    Write-Host "${name}: OK ($(Format-Elapsed $targetStart.Elapsed))"
}

# Report-only audit of what was just staged, so a local build is not blind until CI's verify
# runs. toolset-check.ps1 compares an arch's release and -debug prefix against each other, so it
# reads both whatever this run built. Its verdict does not gate the staging above - a FATAL there
# is a reason to look, not an unstage. Only arches that actually staged something are audited,
# because auditing prefixes from an earlier run after a failure reports on the wrong archives.
$arches = @($staged | ForEach-Object { $_ -replace '^windows-', '' -replace '-debug$', '' } | Select-Object -Unique)
foreach ($a in $arches) {
    $plat = if ($a -eq 'arm64') { 'ARM64' } else { $a }
    $thisRun = @($rebuilt | Where-Object { $_ -replace '-debug$', '' -eq "windows-$a" })
    Write-Host "=================== toolset-check ($plat, report only) ==================="
    # Every staged windows-<arch> prefix is read, not only the ones this run rebuilt, so say which
    # rows are fresh. Otherwise a windows-x86 run looks like it also built windows-x86-debug.
    $rebuiltText = if ($thisRun.Count) { $thisRun -join ', ' } else { 'nothing, all up to date' }
    Write-Host "  reads every staged windows-$a* prefix; rebuilt by this run: $rebuiltText"
    if ($IsVerbose) {
        & (Join-Path $PSScriptRoot 'toolset-check.ps1') -Platform $plat
    }
    else {
        # Its table is per-archive detail. Quiet keeps only what it flags, never 'RESULT: OK'.
        $checkLog = @(& (Join-Path $PSScriptRoot 'toolset-check.ps1') -Platform $plat 2>&1 | ForEach-Object { "$_" })
        $checkLog | Where-Object { $_ -match '^(WARNING:|FATAL:|RESULT: FATAL)' } |
            ForEach-Object { Write-Host "toolset-check ($plat): $_" }
    }
}

# Only the targets this run actually built, so a run that skipped everything says nothing rather
# than reporting a total made up of the time it took to decide there was nothing to do.
if ($timings.Count -gt 1) {
    Write-Host "built $($timings.Count) target(s) in $(Format-Elapsed $runStart.Elapsed): $(($timings | ForEach-Object { "$($_.Name) $(Format-Elapsed $_.Elapsed)" }) -join ', ')"
}

if (-not $overallOk) { exit 1 }
exit 0
