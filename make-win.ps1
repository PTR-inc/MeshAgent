# Build the Windows agents (MeshService and MeshConsole) from MeshAgent-2022.sln and stamp what
# each output directory was built from, so a later run can tell whether it still matches.
# Run it as make-win.ps1 win-x64-Release, make-win.ps1 all, or make-win.ps1 list for the table.
# `all` covers the Release and Debug targets; -Asan adds the Release_ASAN ones.
# A target whose output directory carries a stamp matching what a build would produce now is left
# alone. -Force builds it anyway, from scratch: MSBuild's own up-to-date check would otherwise
# leave the objects and the binary untouched.
# By default it prints phase progress, warnings and errors. Add -verbose for the full MSBuild log.

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$TargetNames,
    [switch]$Force,
    # The Release_ASAN targets are a debugging tool, not something to ship, and they cost a full
    # extra build per platform, so `all` leaves them out unless this is given. Naming one on the
    # command line still builds it: asking for it by name is its own opt-in.
    [switch]$Asan,
    # The agent's OpenSSL archives are built by a different script, and linking a prefix that is not
    # the one that script would produce now is exactly the mistake the stamp exists to catch.
    [switch]$IgnoreOpenSSL,
    # /p:MeshToolset. Anything other than the default gets its own output directory, so a v142
    # build never overwrites a v143 one. MeshAgent.Configuration.props owns the default.
    [string]$Toolset = ''
)

# -verbose is not declared as a parameter: the [Parameter()] attribute above makes this an advanced
# script, so PowerShell supplies -verbose itself and declaring it again is an error.
$IsVerbose = $VerbosePreference -ne 'SilentlyContinue'

function Info([string]$Message) { if ($IsVerbose) { Write-Host $Message } }

# What is worth printing from an otherwise successful MSBuild run: the compiler, linker and MSBuild
# spellings, 'warning C4996', 'error MSB8036', 'fatal error LNK1181'.
$ProblemPattern = '(?i)\b(warning|error)\b'

# One entry per Platform/Configuration pair the solution offers. Name is the output directory the
# build lands in, build\<name>\, so a target names the thing it produces rather than a code for it.
$Targets = foreach ($p in @(@{ Plat = 'Win32'; Dir = 'x86' }, @{ Plat = 'x64'; Dir = 'x64' }, @{ Plat = 'ARM64'; Dir = 'ARM64' })) {
    foreach ($c in @('Release', 'Debug', 'Release_ASAN')) {
        @{ Name = "win-$($p.Dir)-$c"; Platform = $p.Plat; Configuration = $c
           # The solution names the 32-bit platform x86 and maps it to the projects' Win32, so a
           # solution build takes x86 and a project query takes Win32. Passing one the other's
           # spelling is MSB4126, or an evaluation of a configuration the project does not have.
           SlnPlatform = $(if ($p.Plat -eq 'Win32') { 'x86' } else { $p.Plat })
           # Mirrors MeshAgent.Common.props: MeshTargetSuffix, plus _asan for the ASAN configuration.
           Suffix = $(switch ($p.Plat) { 'x64' { '64' } 'ARM64' { 'ARM64' } default { '' } }) +
                    $(if ($c.EndsWith('_ASAN')) { '_asan' } else { '' })
           # Which openssl\<version>\<target>\ prefix this pair links, the rule in MeshAgent.Common.props.
           OpenSsl = "windows-$($p.Dir.ToLower())" + $(if ($c.StartsWith('Debug')) { '-debug' } else { '' })
           # vcvars naming, for the toolset and SDK lookups in env.ps1.
           VcVars = $(switch ($p.Plat) { 'x64' { 'x64' } 'ARM64' { 'x64_arm64' } default { 'x86' } })
           # The lib\<arch>\ folder the ASan runtime for this platform lives in.
           AsanArch = $(switch ($p.Plat) { 'x64' { 'x64' } 'ARM64' { 'arm64' } default { 'x86' } }) }
    }
}

# env.ps1 owns the repo root, the OpenSSL version and prefix root, and every toolset and SDK lookup,
# so none of that is restated here. Its banner is per-target detail rather than progress.
if ($IsVerbose) { . (Join-Path $PSScriptRoot 'openssl\build\windows\env.ps1') }
else            { . (Join-Path $PSScriptRoot 'openssl\build\windows\env.ps1') 6>$null }

$Solution = Join-Path $PSScriptRoot 'MeshAgent-2022.sln'
# The properties live in the shared props files, so any agent project answers for all of them. A
# solution cannot be queried this way, it has no properties of its own.
$QueryProject = Join-Path $PSScriptRoot 'meshservice\MeshService-2022.vcxproj'

# The default toolset, read from the props file that owns it, so -Toolset v143 and no -Toolset at
# all produce the same output directory and the same stamp rather than two of each.
$MeshDefaultToolset = $(
    $cfg = Join-Path $PSScriptRoot 'MeshAgent.Configuration.props'
    if ((Test-Path $cfg) -and ((Get-Content $cfg -Raw) -match '<MeshDefaultToolset>\s*(v[0-9]+)\s*</MeshDefaultToolset>')) { $Matches[1] } else { '' })

function Get-MsBuildPath {
    $vs = Get-VsInstallPath
    if (-not $vs) { return $null }
    foreach ($rel in @('MSBuild\Current\Bin\amd64\MSBuild.exe', 'MSBuild\Current\Bin\MSBuild.exe')) {
        $p = Join-Path $vs $rel
        if (Test-Path $p) { return $p }
    }
    return $null
}

# The properties that decide what MSBuild puts in the output directory, spelled the way they are
# passed. $Platform picks the spelling: the solution's or the projects'. An empty -Toolset leaves
# MeshToolset unset so the props file's default applies.
function Get-MsBuildProps($t, [string]$Platform) {
    $props = @("Configuration=$($t.Configuration)", "Platform=$Platform")
    if ($Toolset) { $props += "MeshToolset=$Toolset" }
    return $props
}

# build\win-<arch>-<configuration>[-<toolset>]\, mirroring OutDir in MeshAgent.Common.props. Derived
# rather than asked of MSBuild because `list` would otherwise pay a project evaluation per row. The
# build path below asks MSBuild for the real value and refuses to run if the two ever disagree.
function Get-OutDir($t) {
    $suffix = if ($Toolset -and $Toolset -ne $MeshDefaultToolset) { "-$Toolset" } else { '' }
    return (Join-Path $PSScriptRoot "build\$($t.Name)$suffix")
}

# The two binaries every target produces. Both projects build from one solution, so a target is
# only finished when both are there.
function Get-TargetBinaries($t) {
    $out = Get-OutDir $t
    return @('MeshService', 'MeshConsole') | ForEach-Object { Join-Path $out "$_$($t.Suffix).exe" }
}

# The staged OpenSSL prefix this target links, and the stamp openssl\build\windows\build.ps1 left in
# it. Its absence is recorded rather than guessed at: an unstamped prefix predates that script.
function Get-OpenSslStampLines($t) {
    $stampFile = Join-Path (Join-Path $script:OpenSslPrefixRoot $t.OpenSsl) 'build-stamp.txt'
    if (-not (Test-Path $stampFile)) { return @('openssl.stamp=absent') }
    # openssl.stamp. rather than openssl., or the prefix's own version= line lands on top of the
    # openssl.version= this script writes and the two say the same thing twice.
    return (((Get-Content $stampFile -Raw) -replace "`r`n", "`n").TrimEnd() -split "`n" |
                Where-Object { $_ } | ForEach-Object { "openssl.stamp.$_" })
}

# Every input that decides what the binaries contain and that MSBuild will not notice on its own.
# Source changes are deliberately absent: MSBuild's own up-to-date check covers those, and this
# stamp answers the different question of whether the environment and the dependencies still match.
# The toolset is the full 14.44.35207 rather than v143, because a patch-level bump changes the code
# generation without changing anything MSBuild compares.
# The openssl.* lines make this a gate on the archives too: rebuild them against another compiler,
# SDK or Configure line and every agent target that links them reads stale, which is what it is.
function Get-BuildStamp($t) {
    $lines = @(
        "solution=$(Split-Path -Leaf $Solution)"
        "platform=$($t.Platform)"
        "configuration=$($t.Configuration)"
        "toolset=$(if ($Toolset) { $Toolset } else { $MeshDefaultToolset })"
        "vctools=$(Get-VcToolsetVersion -Arch $t.VcVars -Full)"
        "sdk=$(Get-WindowsSdkVersion -Arch $t.VcVars)"
        "openssl.version=$($script:OpenSslVersion)"
        "openssl.target=$($t.OpenSsl)"
    )
    if (-not $IgnoreOpenSSL) { $lines += Get-OpenSslStampLines $t }
    return ($lines -join "`n")
}

function Get-StampFile($t) { Join-Path (Get-OutDir $t) 'build-stamp.txt' }

# One definition of "the output directory already holds what a build would produce now", used by the
# stamp column in `list` and by the skip in the build loop. 'unknown' rather than 'stale' when the
# toolset or SDK cannot be read, because a stamp built from blanks condemns every target.
function Get-StampState($t) {
    if (@(Get-TargetBinaries $t | ForEach-Object { Test-Path $_ }) -contains $false) { return 'absent' }
    if (-not (Get-VcToolsetVersion -Arch $t.VcVars -Full) -or -not (Get-WindowsSdkVersion -Arch $t.VcVars)) { return 'unknown' }
    $stampFile = Get-StampFile $t
    if (-not (Test-Path $stampFile)) { return 'stale' }
    if ((((Get-Content $stampFile -Raw) -replace "`r`n", "`n").TrimEnd()) -eq (Get-BuildStamp $t)) { return 'ok' }
    return 'stale'
}

if (-not $TargetNames -or $TargetNames.Count -eq 0) {
    Write-Host "usage: make-win.ps1 [-Force] [-Asan] [-IgnoreOpenSSL] [-Toolset v142] [-verbose] <target|all|list> [target...]"
    Write-Host "targets: $($Targets.Name -join ' ')"
    exit 2
}

# What every row in the table shares, so the per-target columns carry only what differs. Each value
# is gathered across the listed targets and joined, so a machine where one architecture resolves a
# different toolset or SDK says so here rather than reporting the first one it found as the truth.
function Get-CommonProperties($targets) {
    $uniq = { param($v) $j = @($v | Where-Object { $_ } | Select-Object -Unique); if ($j) { $j -join ', ' } else { 'none' } }
    return @(
        "toolset $(if ($Toolset) { $Toolset } else { "$MeshDefaultToolset (default)" })"
        "msvc $(& $uniq ($targets | ForEach-Object { Get-VcToolsetVersion -Arch $_.VcVars -Full }))"
        "sdk $(& $uniq ($targets | ForEach-Object { Get-WindowsSdkVersion -Arch $_.VcVars }))"
        "openssl $($script:OpenSslVersion)"
        "solution $(Split-Path -Leaf $Solution)"
    ) -join '   '
}


# Which stamp lines a build would write differently, so a stale row says what moved rather than only
# that something did. The openssl.stamp.* lines are the staged prefix's own stamp copied in, so they
# are reported as one thing: the archives were rebuilt, and the individual keys are that build's story.
function Get-StampReason($t) {
    $file = Get-StampFile $t
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
        if ($was[$k] -ne $v) { $why += $(if ($k -like 'openssl.stamp.*') { 'openssl archives' } else { $k }) }
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
    '' | Write-Host
    # ok = a build would reproduce it, stale = an input moved, absent = never built here,
    # unknown = no toolset or SDK on this machine to compare against.
    $rows = foreach ($t in $Targets) {
        $state = Get-StampState $t
        if ($state -eq 'stale') { $state = "stale ($(Get-StampReason $t))" }
        [pscustomobject]@{ Name = $t.Name; State = $state; Configuration = $t.Configuration
                           Platform = $t.Platform; Prefix = "openssl\$($script:OpenSslVersion)\$($t.OpenSsl)" }
    }
    # The stale reasons decide how wide the column has to be, so it is measured rather than guessed:
    # a table with nothing stale stays narrow instead of carrying room for a reason that never comes.
    $w = [Math]::Max(5, ($rows.State | Measure-Object -Property Length -Maximum).Maximum)
    $fmt = "{0,-24} {1,-$w} {2,-13} {3,-8} {4}"
    $fmt -f 'TARGET', 'STAMP', 'CONFIGURATION', 'PLATFORM', 'OPENSSL PREFIX' | Write-Host
    foreach ($r in $rows) { $fmt -f $r.Name, $r.State, $r.Configuration, $r.Platform, $r.Prefix | Write-Host }
    '' | Write-Host
    "the Release_ASAN targets are left out of 'all' unless -Asan is given; naming one builds it either way" | Write-Host
    exit 0
}

# A misspelled name must refuse the whole run, not be silently dropped from the list.
if ($TargetNames[0] -ne 'all') {
    $unknown = @($TargetNames | Where-Object { $n = $_; -not ($Targets.Name -contains $n) })
    if ($unknown.Count -gt 0) {
        Write-Host "unknown target(s): $($unknown -join ' ')"
        Write-Host "targets: $($Targets.Name -join ' ')"
        exit 2
    }
}
$list = if ($TargetNames[0] -eq 'all') {
            $Targets | Where-Object { $Asan -or -not $_.Configuration.EndsWith('_ASAN') }
        } else { $Targets | Where-Object { $TargetNames -contains $_.Name } }

if (-not (Test-Path $Solution)) { Write-Host "MISSING: $Solution"; exit 1 }
$msbuild = Get-MsBuildPath
if (-not $msbuild) { Write-Host "MISSING: MSBuild.exe - no Visual Studio install with the C++ toolset was found"; exit 1 }
Info "msbuild : $msbuild"

# Minutes and seconds, or seconds alone under a minute. A build is worth timing because the only
# lever on it is how long it takes: nmake has no parallel option, so this is what a target costs.
function Format-Elapsed([TimeSpan]$span) {
    if ($span.TotalMinutes -lt 1) { return ('{0:0.0}s' -f $span.TotalSeconds) }
    return ('{0}m {1:00}s' -f [int]$span.TotalMinutes, $span.Seconds)
}

$overallOk = $true
$runStart = [Diagnostics.Stopwatch]::StartNew()
$timings = @()
foreach ($t in $list) {
    $name = $t.Name
    $targetStart = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "=================== $name ($($t.Configuration)|$($t.Platform)) ==================="

    # Refuse before MSBuild does, because a missing prefix surfaces as a C1083 on openssl\ssl.h
    # several hundred lines into the compile.
    $prefix = Join-Path $script:OpenSslPrefixRoot $t.OpenSsl
    $need = @('lib\libcrypto.lib', 'lib\libssl.lib', 'include\openssl\opensslconf.h') |
        Where-Object { -not (Test-Path (Join-Path $prefix $_)) }
    if ($need.Count -gt 0) {
        Write-Host "${name}: MISSING OpenSSL prefix $prefix ($($need -join ', '))"
        Write-Host "  build it with: openssl\build\windows\build.ps1 $($t.OpenSsl)"
        $overallOk = $false
        continue
    }

    $projArgs = Get-MsBuildProps $t $t.Platform | ForEach-Object { "-p:$_" }
    $slnArgs = Get-MsBuildProps $t $t.SlnPlatform | ForEach-Object { "-p:$_" }

    # A Release_ASAN build needs the ASan runtime for this architecture, which comes from the
    # VC.ASAN component and not from any VC.Tools one. Without it the build still succeeds and
    # EnableASAN still renames the output, so an un-instrumented *_asan.exe comes out looking
    # sanitized, and test-agent.ps1 finds its ASan phase by that name. Measured on ARM64 before this
    # check existed: 207 ASan strings in the x64 _asan console binary against 1 in the ARM64 one.
    if ($t.Configuration.EndsWith('_ASAN')) {
        # The toolset MSBuild will actually use, not the newest installed: MSVC gained ARM64 ASan
        # support later than x86 and x64, so an older pinned toolset can have the component
        # installed and still lack this architecture's runtime, and its cl answers
        # /fsanitize=address with 'warning D9002: ignoring unknown option'.
        $toolsVersion = ((& $msbuild $QueryProject @projArgs -getProperty:VCToolsVersion -nologo 2>&1 |
                            ForEach-Object { "$_" }) -join '').Trim()
        if (-not (Get-VcAsanRuntime -Arch $t.AsanArch -ToolsVersion $toolsVersion)) {
            Write-Host "${name}: MISSING the $($t.AsanArch) AddressSanitizer runtime in MSVC $toolsVersion"
            Write-Host "  add the '$(Get-VcComponentId -Arch asan)' component, or run: Install-BuildRootWindows -VsComponents"
            if ($t.AsanArch -eq 'arm64') {
                Write-Host "  ARM64 ASan arrived in a later toolset than the pinned one; -Toolset v145 builds it where the component has an arm64 runtime"
            }
            $overallOk = $false
            continue
        }
    }

    # After the ASan check, not before it: a directory stamped by a run that produced an
    # un-instrumented *_asan.exe must be refused rather than reported as up to date.
    if ((Get-StampState $t) -eq 'ok' -and -not $Force) {
        Write-Host "${name}: up to date (-Force rebuilds it from source)"
        continue
    }

    # The one place the derived output directory is checked against the real one. If the props ever
    # change how OutDir is composed, this stops rather than stamping a directory nobody reads.
    $outDir = Get-OutDir $t
    $reported = ((& $msbuild $QueryProject @projArgs -getProperty:OutDir -nologo 2>&1 |
                    ForEach-Object { "$_" }) -join '').Trim()
    if (-not $reported) {
        Write-Host "${name}: FAILED - MSBuild would not evaluate $QueryProject"
        $overallOk = $false
        continue
    }
    if ($reported.TrimEnd('\') -ne $outDir.TrimEnd('\')) {
        Write-Host "${name}: FAILED - this script derives $outDir but MSBuild reports $reported"
        Write-Host "  Get-OutDir no longer mirrors OutDir in MeshAgent.Common.props; fix it before building"
        $overallOk = $false
        continue
    }

    Write-Host "  [1/2] build"
    # -m parallelises across the two projects. The C++ toolset's own MultiProcessorCompilation is
    # already on in the props. Verbose streams the log; quiet captures it and shows every line on
    # failure, or only the warning and error lines when it worked.
    # -Force means Rebuild, not Build: MSBuild has its own up-to-date check, and skipping the stamp
    # only to have it answer "All outputs are up-to-date" would make -Force a no-op. Rebuild is Clean
    # plus Build, so the objects and the binary are made again from source.
    $mbTarget = if ($Force) { '-t:Rebuild' } else { '-t:Build' }
    $mbArgs = @($Solution) + $slnArgs + @('-nologo', '-m', $mbTarget)
    if ($IsVerbose) {
        & $msbuild @mbArgs -v:n
        $code = $LASTEXITCODE
    }
    else {
        $log = @(& $msbuild @mbArgs -v:m 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        $show = if ($code -ne 0) { $log } else { $log | Where-Object { $_ -match $ProblemPattern } }
        $show | ForEach-Object { Write-Host $_ }
    }
    if ($code -ne 0) {
        Write-Host "${name}: BUILD FAILED (exit $code)"
        $overallOk = $false
        continue
    }

    Write-Host "  [2/2] verify and stamp"
    $missingBin = @(Get-TargetBinaries $t | Where-Object { -not (Test-Path $_) })
    if ($missingBin.Count -gt 0) {
        Write-Host "${name}: REJECTED - MSBuild succeeded but did not produce $($missingBin -join ', ')"
        $overallOk = $false
        continue
    }
    Get-TargetBinaries $t | ForEach-Object { Info "  $([IO.Path]::GetFileName($_)) : $([math]::Round((Get-Item $_).Length / 1KB)) KB" }

    # Written last, so a stamp on disk also proves both binaries above were there. LF, like every
    # other text this repo writes.
    [IO.File]::WriteAllText((Get-StampFile $t), (Get-BuildStamp $t) + "`n", [Text.UTF8Encoding]::new($false))
    Info "  stamped -> $(Get-StampFile $t)"
    $timings += [pscustomobject]@{ Name = $name; Elapsed = $targetStart.Elapsed }
    Write-Host "${name}: OK ($(Format-Elapsed $targetStart.Elapsed))"
}

# Only the targets this run actually built, so a run that skipped everything says nothing rather
# than reporting a total made up of the time it took to decide there was nothing to do.
if ($timings.Count -gt 1) {
    Write-Host "built $($timings.Count) target(s) in $(Format-Elapsed $runStart.Elapsed): $(($timings | ForEach-Object { "$($_.Name) $(Format-Elapsed $_.Elapsed)" }) -join ', ')"
}

if (-not $overallOk) { exit 1 }
exit 0
