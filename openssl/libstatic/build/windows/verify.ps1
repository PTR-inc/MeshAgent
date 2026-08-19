# Report version and object count for every Windows archive in the repo.
# Read-only - mirrors verify.sh's role for the Linux/BSD/macOS archives.

. (Join-Path $PSScriptRoot 'env.ps1')

$vcvarsall = Get-VcVarsAllPath
if (-not $vcvarsall) { Write-Host "MISSING: vcvarsall.bat - lib.exe (needed for object counts) unavailable"; exit 1 }

$libs = Get-ChildItem -Path (Join-Path $Repo 'openssl\libstatic') -Filter 'libcrypto*.lib' -File | Sort-Object Name
if (-not $libs) { Write-Host "No openssl\libstatic\libcrypto*.lib files found."; exit 1 }

"{0,-28} {1,-10} {2}" -f 'FILE', 'VERSION', 'OBJS' | Write-Host
"{0,-28} {1,-10} {2}" -f '----', '-------', '----' | Write-Host

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "meshagent-ossl-verify-$PID"
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$cmdFile = Join-Path $scratch 'do-inspect.cmd'

# vcvarsall.bat shells out to vswhere.exe - put it on PATH first to silence
# a harmless "not recognized" warning.
$vswhereDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
$pathPrefix = if (Test-Path $vswhereDir) { "set `"PATH=$vswhereDir;%PATH%`"`r`n" } else { '' }

foreach ($lib in $libs) {
    $versionMatch = Select-String -Path $lib.FullName -Pattern 'OpenSSL 1\.1\.1[a-z]?' -Encoding Ascii | Select-Object -First 1
    $version = if ($versionMatch) { $versionMatch.Matches[0].Value } else { 'UNKNOWN' }

    # A .cmd file, not inline quoting - cmd.exe's quoting breaks once a path
    # like "Program Files" has spaces in it.
    $pathPrefix + (@(
        "call `"$vcvarsall`" x64 >nul"
        "lib /list `"$($lib.FullName)`""
    ) -join "`r`n") | Set-Content -Path $cmdFile -Encoding ASCII
    $listOutput = & cmd.exe /c "`"$cmdFile`""
    $objCount = ($listOutput | Where-Object { $_ -match '\.obj$' }).Count

    "{0,-28} {1,-10} {2}" -f $lib.Name, $version, $objCount | Write-Host
}

Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue

# No CRT (/MT vs /MD) check: these archives carry no /DEFAULTLIB:LIBCMT
# directive to key off. build.ps1's /MD->/MT patch step is the real gate.
