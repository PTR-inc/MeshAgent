# Build one or more Windows OpenSSL targets and stage them into the repo as install prefixes,
# openssl\<version>\<target>\ with lib\libcrypto.lib, lib\libssl.lib and include\openssl\opensslconf.h.
# Run it as build.ps1 windows-x64, build.ps1 all, or build.ps1 list for the target table.

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$TargetNames
)

# One entry per target, derived from the name: Debug from the -debug suffix, the vcvars pair from
# the arch (arm64 cross-builds with x64 host tools), asm off for arm64 (VC-WIN64-ARM has no asm path).
# consistency.sh check 5 keeps names, VcConf, --debug and asm in step with targets.sh's windows rows.
$VcConfByArch = @{ x86 = 'VC-WIN32'; x64 = 'VC-WIN64A'; arm64 = 'VC-WIN64-ARM' }
$Targets = @('windows-x86', 'windows-x86-debug', 'windows-x64', 'windows-x64-debug', 'windows-arm64', 'windows-arm64-debug') |
    ForEach-Object {
        $arch = $_ -replace '^windows-', '' -replace '-debug$', ''
        @{ Name = $_; VcVars = $(if ($arch -eq 'arm64') { 'x64_arm64' } else { $arch })
           VcConf = $VcConfByArch[$arch]; Asm = ($arch -ne 'arm64'); Debug = $_.EndsWith('-debug') }
    }

. (Join-Path $PSScriptRoot 'env.ps1')

if (-not $TargetNames -or $TargetNames.Count -eq 0) {
    Write-Host "usage: build.ps1 <target|all|list> [target...]"
    Write-Host "targets: $($Targets.Name -join ' ')"
    exit 2
}
# One row per target with the MSBuild consumer that links each prefix. ARCHIDs are a unix
# makefile concept; on Windows the props derive the target from $(Platform) and $(MeshDebug),
# so that platform/configuration pairing is what a per-consumer listing means here.
if ($TargetNames[0] -eq 'list') {
    "{0,-22} {1,-14} {2,-13} {3,-4} {4}" -f 'TARGET', 'CONSUMER', 'VCCONF', 'ASM', 'PREFIX' | Write-Host
    foreach ($t in $Targets) {
        $arch = $t.Name -replace '^windows-', '' -replace '-debug$', ''
        $plat = if ($arch -eq 'x86') { 'Win32' } elseif ($arch -eq 'arm64') { 'ARM64' } else { 'x64' }
        $consumer = '{0} {1}' -f $plat, $(if ($t.Debug) { 'Debug' } else { 'Release' })
        $state = if (Test-Path (Join-Path $script:OpenSslPrefixRoot "$($t.Name)\lib\libcrypto.lib")) { '' } else { ' (absent)' }
        "{0,-22} {1,-14} {2,-13} {3,-4} {4}" -f $t.Name, $consumer, $t.VcConf, $(if ($t.Asm) { 'on' } else { 'off' }), "openssl\$($script:OpenSslVersion)\$($t.Name)$state" | Write-Host
    }
    exit 0
}
# A misspelled name must refuse the whole run, not be silently dropped from the list.
if ($TargetNames[0] -ne 'all') {
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

$nasm = Get-NasmPath
$nasmDir = if ($nasm) { Split-Path -Parent $nasm } else { $null }

$perl = Get-PerlPath
if (-not $perl) { Write-Host "MISSING: perl.exe - Configure cannot run without it"; exit 1 }
$perlDir = Split-Path -Parent $perl

# Refuse up front, because an incomplete toolset for a target only shows up as a
# link failure deep into nmake. See Get-VcToolsetVersion.
foreach ($vcArch in ($list.VcVars | Select-Object -Unique)) {
    if (-not (Get-VcToolsetVersion -Arch $vcArch)) {
        Write-Host "MISSING: no complete MSVC toolset for $vcArch - see README.md for the required VS components"
        exit 1
    }
    # A toolset without a Windows SDK gives a working cl.exe that then fails on stdlib.h.
    # Catch it here rather than 40 lines into the nmake output.
    if (-not (Get-WindowsSdkVersion -Arch $vcArch)) {
        Write-Host "MISSING: no Windows SDK for $vcArch - the VC.Tools components do not include one (Install-BuildRootWindows -VsComponents)"
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $env:BR_WORK | Out-Null

$overallOk = $true
foreach ($t in $list) {
    $name = $t.Name
    Write-Host "=================== $name ($($t.VcConf)) ==================="

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
    & tar xzf $script:OpenSslTarball -C $src --strip-components=1
    if ($LASTEXITCODE -ne 0) { Write-Host "${name}: EXTRACT FAILED"; $overallOk = $false; continue }

    $flags = $script:OsslFlags
    $useAsm = $t.Asm -and $nasm
    if ($t.Asm -and -not $nasm) {
        Write-Host "  nasm not found - building $name with -no-asm instead of the CI's asm-enabled recipe"
    }
    if ($useAsm) { $flags = $flags -replace '-no-asm', '' }

    $debugFlag = if ($t.Debug) { '--debug' } else { '' }
    # With no-shared, OpenSSL's VC-noCE-common never emits /MD or /MDd; it puts "/MT /Zl" in lib_cflags for
    # debug and release alike, so a --debug build has to have that /MT rewritten to /MTd here. /Zl stays, so
    # the objects carry no /DEFAULTLIB and the agent's own CRT choice wins at link time.
    # Release builds also drop /Zi and nasm -g, which VC-common forces even in release. The patch runs
    # through perl, already a hard requirement, rather than a quoting-fragile nested powershell.
    $makefilePatch = 's{/MD\b}{/MT}g; s{/Zi /Fdossl_static\.pdb }{}g; s{ASFLAGS=-g}{ASFLAGS=}g'
    if ($t.Debug) { $makefilePatch = 's{/MT\b}{/MTd}g' }

    # Each target gets its own cmd.exe session because the vcvars script only mutates its
    # own process. PATH is extended before the call so its own vswhere.exe lookup succeeds.
    $vswhereDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $extraPath = @($nasmDir, $perlDir, $vswhereDir) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    $cmdLines = @()
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
        "nmake"
    )
    $cmdFile = Join-Path $src 'do-build.cmd'
    $cmdLines -join "`r`n" | Set-Content -Path $cmdFile -Encoding ASCII

    & cmd.exe /c "`"$cmdFile`""
    if ($LASTEXITCODE -ne 0) {
        Write-Host "${name}: BUILD FAILED (exit $LASTEXITCODE) - see $src\do-build.cmd and the nmake output above"
        $overallOk = $false
        continue
    }

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
    Write-Host "  version : OK ($($script:OpenSslVersion))"
    Write-Host "  objects : $($info.objs)"
    Write-Host "  platform: $($info.platform)"

    # In 1.1.1 nmake, not Configure, writes include\openssl\opensslconf.h, so it is only copied after the build.
    $conf = Join-Path $src 'include\openssl\opensslconf.h'
    if (-not (Test-Path $conf)) {
        Write-Host "${name}: REJECTED - include\openssl\opensslconf.h not generated"
        $overallOk = $false
        continue
    }

    # Stage only the three files the agent build consumes. nmake install_dev would need a
    # prefix and installs much more than that.
    $prefix = Join-Path $script:OpenSslPrefixRoot $name
    $libDir = Join-Path $prefix 'lib'
    $incDir = Join-Path $prefix 'include\openssl'
    New-Item -ItemType Directory -Force -Path $libDir, $incDir | Out-Null
    Copy-Item $libcrypto (Join-Path $libDir 'libcrypto.lib') -Force
    Copy-Item $libssl    (Join-Path $libDir 'libssl.lib') -Force
    # nmake writes CRLF; the repo normalises text to LF, so stage it that way and avoid a spurious diff.
    [IO.File]::WriteAllText((Join-Path $incDir 'opensslconf.h'), ([IO.File]::ReadAllText($conf) -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    Write-Host "  staged  -> $prefix (lib\libcrypto.lib, lib\libssl.lib, include\openssl\opensslconf.h)"
    Write-Host "${name}: OK"
}

# Report-only audit of what was just staged, so a local build is not blind until CI's verify
# runs. toolset-check.ps1 covers an arch's release and -debug prefix together, and its verdict
# does not gate the staging above - a FATAL there is a reason to look, not an unstage.
$arches = @($list | ForEach-Object { $_.Name -replace '^windows-', '' -replace '-debug$', '' } | Select-Object -Unique)
foreach ($a in $arches) {
    $plat = if ($a -eq 'arm64') { 'ARM64' } else { $a }
    Write-Host "=================== toolset-check ($plat, report only) ==================="
    & (Join-Path $PSScriptRoot 'toolset-check.ps1') -Platform $plat
}

if (-not $overallOk) { exit 1 }
exit 0
