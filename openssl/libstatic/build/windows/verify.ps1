# Report version and object count for every Windows archive in the repo.
# Read-only - mirrors openssl/libstatic/verify's role for the Linux/BSD/macOS archives.

. (Join-Path $PSScriptRoot 'env.ps1')

# Check the toolset too, not just the env script: an unusable x64 toolset would
# leave lib.exe off PATH and report every archive as 0 objects rather than fail.
$vcEnvCall = Get-VcEnvCall -Arch x64
if (-not $vcEnvCall -or -not (Get-VcToolsetVersion -Arch x64)) {
    Write-Host "MISSING: no complete MSVC x64 toolset - lib.exe (needed for object counts) unavailable"
    exit 1
}

$libs = Get-ChildItem -Path (Join-Path $Repo 'openssl\libstatic\windows') -Filter 'libcrypto*.lib' -File | Sort-Object Name
if (-not $libs) { Write-Host "No openssl\libstatic\windows\libcrypto*.lib files found."; exit 1 }

"{0,-28} {1,-10} {2}" -f 'FILE', 'VERSION', 'OBJS' | Write-Host
"{0,-28} {1,-10} {2}" -f '----', '-------', '----' | Write-Host

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "meshagent-ossl-verify-$PID"
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$cmdFile = Join-Path $scratch 'do-inspect.cmd'

# The vcvars script shells out to vswhere.exe - put it on PATH first to
# silence a harmless "not recognized" warning.
$pathPrefix = if (Test-Path $script:VsWhereDir) { "set `"PATH=$script:VsWhereDir;%PATH%`"`r`n" } else { '' }

foreach ($lib in $libs) {
    $versionMatch = Select-String -Path $lib.FullName -Pattern 'OpenSSL 1\.1\.1[a-z]?' -Encoding Ascii | Select-Object -First 1
    $version = if ($versionMatch) { $versionMatch.Matches[0].Value } else { 'UNKNOWN' }

    # A .cmd file, not inline quoting - cmd.exe's quoting breaks once a path
    # like "Program Files" has spaces in it.
    $pathPrefix + (@(
        "$vcEnvCall >nul"
        "lib /list `"$($lib.FullName)`""
    ) -join "`r`n") | Set-Content -Path $cmdFile -Encoding ASCII
    $listOutput = & cmd.exe /c "`"$cmdFile`""
    $objCount = ($listOutput | Where-Object { $_ -match '\.obj$' }).Count

    "{0,-28} {1,-10} {2}" -f $lib.Name, $version, $objCount | Write-Host
}

Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue

# No CRT (/MT vs /MD) check: these archives carry no /DEFAULTLIB:LIBCMT
# directive to key off. build.ps1's /MD->/MT patch step is the real gate.
