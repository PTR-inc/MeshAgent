# Build one or more Windows OpenSSL targets and stage them into the repo as install prefixes,
# openssl\<version>\<target>\ with lib\libcrypto.lib, lib\libssl.lib and include\openssl\opensslconf.h.
# Run it as build.ps1 windows-x64, build.ps1 all, or build.ps1 --names-json to print the CI matrix.

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$TargetNames
)

# One entry per staged target. The Name values must match the windows rows of targets.sh,
# because consistency.sh compares the two tables. Asm is only enabled for x86 and x64
# because OpenSSL 1.1.1's VC-WIN64-ARM config has no asm path.
$Targets = @(
    @{ Name = 'windows-x86';         VcVars = 'x86';       VcConf = 'VC-WIN32';     Asm = $true;  Debug = $false }
    @{ Name = 'windows-x86-debug';   VcVars = 'x86';       VcConf = 'VC-WIN32';     Asm = $true;  Debug = $true  }
    @{ Name = 'windows-x64';         VcVars = 'x64';       VcConf = 'VC-WIN64A';    Asm = $true;  Debug = $false }
    @{ Name = 'windows-x64-debug';   VcVars = 'x64';       VcConf = 'VC-WIN64A';    Asm = $true;  Debug = $true  }
    @{ Name = 'windows-arm64';       VcVars = 'x64_arm64'; VcConf = 'VC-WIN64-ARM'; Asm = $false; Debug = $false }
    @{ Name = 'windows-arm64-debug'; VcVars = 'x64_arm64'; VcConf = 'VC-WIN64-ARM'; Asm = $false; Debug = $true  }
)

# The CI matrix is generated from $Targets above so it is never restated in YAML.
if ($TargetNames -and $TargetNames[0] -eq '--names-json') {
    Write-Output (($Targets.Name | ForEach-Object { '"' + $_ + '"' }) -join ',' | ForEach-Object { "[$_]" })
    exit 0
}
. (Join-Path $PSScriptRoot 'env.ps1')

if (-not $TargetNames -or $TargetNames.Count -eq 0) {
    Write-Host "usage: build.ps1 <target|all|--names-json> [target...]"
    Write-Host "targets: $($Targets.Name -join ' ')"
    exit 2
}
$list = if ($TargetNames[0] -eq 'all') { $Targets } else { $Targets | Where-Object { $TargetNames -contains $_.Name } }
if ($list.Count -eq 0) { Write-Host "no matching targets in: $($TargetNames -join ' ')"; exit 2 }

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
    $mdPattern = if ($t.Debug) { '/MT\b' } else { '/MD\b' }
    $mtReplacement = if ($t.Debug) { '/MTd' } else { '/MT' }
    # Release builds drop /Zi and nasm -g, which VC-common forces even in release.
    $stripDbg = if ($t.Debug) { '' } else { " -replace '/Zi /Fdossl_static\.pdb ','' -replace 'ASFLAGS=-g','ASFLAGS='" }

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
        "powershell -NoProfile -Command `"(Get-Content makefile) -replace '$mdPattern','$mtReplacement'$stripDbg | Set-Content makefile`""
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

    $versionMatch = Select-String -Path $libcrypto -Pattern "OpenSSL $($script:OpenSslVersion) " -Encoding Ascii
    if (-not $versionMatch) {
        Write-Host "${name}: REJECTED - version string 'OpenSSL $($script:OpenSslVersion) ' not found in libcrypto.lib"
        $overallOk = $false
        continue
    }

    $listCmdFile = Join-Path $src 'do-list.cmd'
    $listCmdLines = @()
    if ($extraPath) { $listCmdLines += "set `"PATH=$($extraPath -join ';');%PATH%`"" }
    $listCmdLines += @(
        "$vcEnvCall >nul"
        "lib /list `"$libcrypto`""
    )
    $listCmdLines -join "`r`n" | Set-Content -Path $listCmdFile -Encoding ASCII
    $listOutput = & cmd.exe /c "`"$listCmdFile`""
    $objCount = ($listOutput | Where-Object { $_ -match '\.obj$' }).Count
    # The object count is reported only. It is not a gate, since it moves with every flag and toolset change.
    Write-Host "  version : OK ($($script:OpenSslVersion))"
    Write-Host "  objects : $objCount"

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

if (-not $overallOk) { exit 1 }
