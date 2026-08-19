# Build one or more Windows OpenSSL targets and stage the archives into the repo.
#
#   openssl\libstatic\build\windows\build.ps1 x64
#   openssl\libstatic\build\windows\build.ps1 all
#
# Mirrors build.sh's contract (version + object-count gate before staging)
# and the CI `windows` job's recipe, so local and CI builds match.

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$TargetNames
)

. (Join-Path $PSScriptRoot 'env.ps1')

# One entry per staged target. Asm: x86/x64 only (CPUID-gated); ARM64 has no
# asm path in OpenSSL 1.1.1's VC-WIN64-ARM config. ObjCount via `lib /list`.
$Targets = @(
    @{ Name = 'x86';       VcVars = 'x86';       VcConf = 'VC-WIN32';     Suffix = '32';    MtTag = 'MT'; Asm = $true;  Debug = $false; ObjCount = 566 }
    @{ Name = 'x86-debug'; VcVars = 'x86';       VcConf = 'VC-WIN32';     Suffix = '32';    MtTag = 'MT'; Asm = $true;  Debug = $true;  ObjCount = 566 }
    @{ Name = 'x64';       VcVars = 'x64';       VcConf = 'VC-WIN64A';    Suffix = '64';    MtTag = 'MT'; Asm = $true;  Debug = $false; ObjCount = 576 }
    @{ Name = 'x64-debug'; VcVars = 'x64';       VcConf = 'VC-WIN64A';    Suffix = '64';    MtTag = 'MT'; Asm = $true;  Debug = $true;  ObjCount = 576 }
    # ARM64 lib names have no "MT" tag - only x86/x64 do (.vcxproj expects
    # libcryptoARM64.lib, not libcryptoARM64MT.lib).
    @{ Name = 'arm64';       VcVars = 'x64_arm64'; VcConf = 'VC-WIN64-ARM'; Suffix = 'ARM64'; MtTag = '';   Asm = $false; Debug = $false; ObjCount = 553 }
    @{ Name = 'arm64-debug'; VcVars = 'x64_arm64'; VcConf = 'VC-WIN64-ARM'; Suffix = 'ARM64'; MtTag = '';   Asm = $false; Debug = $true;  ObjCount = 553 }
)

if (-not $TargetNames -or $TargetNames.Count -eq 0) {
    Write-Host "usage: build.ps1 <target|all> [target...]"
    Write-Host "targets: $($Targets.Name -join ' ')"
    exit 2
}
$list = if ($TargetNames[0] -eq 'all') { $Targets } else { $Targets | Where-Object { $TargetNames -contains $_.Name } }
if ($list.Count -eq 0) { Write-Host "no matching targets in: $($TargetNames -join ' ')"; exit 2 }

if (-not (Test-Path $script:OpenSslTarball)) {
    Write-Host "MISSING: $script:OpenSslTarball - fetch it first, see README.md"
    exit 1
}

$vcvarsall = Get-VcVarsAllPath
if (-not $vcvarsall) { Write-Host "MISSING: vcvarsall.bat - no usable Visual Studio install found"; exit 1 }

$nasm = Get-NasmPath
$nasmDir = if ($nasm) { Split-Path -Parent $nasm } else { $null }

$perl = Get-PerlPath
if (-not $perl) { Write-Host "MISSING: perl.exe - Configure cannot run without it"; exit 1 }
$perlDir = Split-Path -Parent $perl

# Pin to whichever toolset has a complete arm64 lib set - see
# Get-Arm64ToolsetVersion.
$arm64ToolsetVer = Get-Arm64ToolsetVersion
if (($list | Where-Object { $_.VcVars -eq 'x64_arm64' }) -and -not $arm64ToolsetVer) {
    Write-Host "WARNING: no installed MSVC toolset has a complete arm64 lib set (setargv.obj missing everywhere) - arm64 targets will likely fail to link apps\openssl.exe"
}

New-Item -ItemType Directory -Force -Path $env:BR_WORK | Out-Null

$overallOk = $true
foreach ($t in $list) {
    $name = $t.Name
    Write-Host "=================== $name ($($t.VcConf)) ==================="

    $src = Join-Path $env:BR_WORK $name
    if (Test-Path $src) {
        # OpenSSL's makefile can leave a literal file named NUL - a reserved
        # device name Remove-Item can't touch without the \\?\ prefix.
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
    $mdPattern = if ($t.Debug) { '/MDd\b' } else { '/MD\b' }
    $mtReplacement = if ($t.Debug) { '/MTd' } else { '/MT' }

    # One cmd.exe session per target - vcvarsall.bat only mutates its own
    # process. Extend PATH before calling it, so its own vswhere.exe call finds it.
    $vswhereDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    $extraPath = @($nasmDir, $perlDir, $vswhereDir) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    $cmdLines = @()
    if ($extraPath) { $cmdLines += "set `"PATH=$($extraPath -join ';');%PATH%`"" }
    $vcvarsVerArg = if ($t.VcVars -eq 'x64_arm64' -and $arm64ToolsetVer) { "-vcvars_ver=$arm64ToolsetVer" } else { '' }
    $cmdLines += @(
        "call `"$vcvarsall`" $($t.VcVars) $vcvarsVerArg >nul"
        "if errorlevel 1 exit /b 1"
    )
    $cmdLines += @(
        "cd /d `"$src`""
        "perl Configure $($t.VcConf) $debugFlag $flags"
        "if errorlevel 1 exit /b 1"
        "powershell -NoProfile -Command `"(Get-Content makefile) -replace '$mdPattern','$mtReplacement' | Set-Content makefile`""
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
        "call `"$vcvarsall`" $($t.VcVars) $vcvarsVerArg >nul"
        "lib /list `"$libcrypto`""
    )
    $listCmdLines -join "`r`n" | Set-Content -Path $listCmdFile -Encoding ASCII
    $listOutput = & cmd.exe /c "`"$listCmdFile`""
    $objCount = ($listOutput | Where-Object { $_ -match '\.obj$' }).Count
    Write-Host "  version : OK ($($script:OpenSslVersion))"
    Write-Host "  objects : $objCount"
    if ($t.ObjCount -gt 0 -and $objCount -ne $t.ObjCount) {
        Write-Host "${name}: REJECTED - object count $objCount does not match expected $($t.ObjCount)"
        $overallOk = $false
        continue
    }

    $dsuffix = if ($t.Debug) { 'd' } else { '' }
    $destDir = Join-Path $Repo 'openssl\libstatic'
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item $libcrypto (Join-Path $destDir "libcrypto$($t.Suffix)$($t.MtTag)$dsuffix.lib") -Force
    Copy-Item $libssl    (Join-Path $destDir "libssl$($t.Suffix)$($t.MtTag)$dsuffix.lib") -Force
    Write-Host "  staged  -> openssl\libstatic\libcrypto$($t.Suffix)$($t.MtTag)$dsuffix.lib / libssl$($t.Suffix)$($t.MtTag)$dsuffix.lib"
    Write-Host "${name}: OK"
}

if (-not $overallOk) { exit 1 }
