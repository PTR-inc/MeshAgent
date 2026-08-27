# MeshAgent OpenSSL Windows build environment. This is a vendored copy tracked in git.
# Dot-source it rather than running it:  . openssl\build\windows\env.ps1
# It is the native sibling of build-env.sh at the repo root, because MSVC's Configure targets and nmake need a real developer environment, not Git Bash.

# This file lives in openssl\build\windows, so the repo root is three parents up.
$script:BrWindowsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:BrScripts = Split-Path -Parent $BrWindowsDir
$script:Repo = Split-Path -Parent (Split-Path -Parent $BrScripts)

# The version is read out of openssl\VERSION so that file stays the single pin, exactly as build-env.sh does.
# Override it for one session with $env:OPENSSL_VERSION.
$script:OpenSslVersion = if ($env:OPENSSL_VERSION) { $env:OPENSSL_VERSION } else {
    $versionFile = Join-Path $script:Repo 'openssl\VERSION'
    if (-not (Test-Path $versionFile)) { throw "couldn't read the OpenSSL version: $versionFile is missing" }
    $v = ((Get-Content $versionFile -Raw) -replace '\s', '')
    if (-not $v) { throw "couldn't read the OpenSSL version: $versionFile is empty" }
    $v
}
# Every archive of this version is staged under one install prefix per target, openssl\<version>\<target>\.
$script:OpenSslPrefixRoot = Join-Path $script:Repo "openssl\$($script:OpenSslVersion)"
# 1.x releases are tagged like OpenSSL_1_1_1w, and 3.x and later like openssl-3.5.7.
# This is the same rule as openssl_release_tag in build-env.sh.
$script:OpenSslTag = if ($script:OpenSslVersion -like '1.*') { "OpenSSL_" + ($script:OpenSslVersion -replace '\.', '_') } else { "openssl-$($script:OpenSslVersion)" }
$script:OpenSslUrl = "https://github.com/openssl/openssl/releases/download/$($script:OpenSslTag)/openssl-$($script:OpenSslVersion).tar.gz"

# There is no hand-pinned checksum because openssl.org publishes a <tarball>.sha256
# sidecar for every release. It is looked up at download time exactly as build-env.sh does.
function Get-OpenSslSha256 {
    param([string]$Version = $script:OpenSslVersion)
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "https://www.openssl.org/source/openssl-$Version.tar.gz.sha256"
    # The sidecar redirects to a GitHub release asset served as octet-stream, which pwsh 7 hands
    # back as bytes, and its text starts with a space that -split would turn into an empty field.
    $body = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::ASCII.GetString($resp.Content) } else { [string]$resp.Content }
    $sha = ($body.Trim() -split '\s+')[0]
    if ($sha -notmatch '^[0-9a-f]{64}$') { throw "openssl-$Version.tar.gz.sha256 did not parse to a sha256" }
    return $sha
}

# The default lives under the user profile. Override it by setting BUILDROOT before
# dot-sourcing, or answer the Install-BuildRootWindows prompt for this session.
$script:BuildRootDefault = Join-Path $env:LOCALAPPDATA 'meshagent-buildroot'

function Resolve-BrPath {
    # Normalise a hand-typed path by stripping stray quotes, expanding %VARS% and ~, and making
    # it absolute, so a relative answer cannot quietly land the buildroot elsewhere after a later cd.
    param([Parameter(Mandatory)][string]$Path)

    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($p -eq '~' -or $p.StartsWith('~\') -or $p.StartsWith('~/')) {
        $p = Join-Path $env:USERPROFILE $p.Substring(1).TrimStart('\', '/')
    }
    try {
        # Combine() returns $p unchanged when it is already absolute.
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $p))
    } catch {
        return $p
    }
}

function Set-BuildRoot {
    # Repoint $BUILDROOT and everything derived from it in one place. The derived paths
    # are fixed at dot-source time, so setting $env:BUILDROOT on its own would leave
    # BR_DOWNLOADS and the tarball path pointing at the old tree.
    param([Parameter(Mandatory)][string]$Path)

    $env:BUILDROOT = $Path
    $env:BR_DOWNLOADS = Join-Path $Path 'downloads'
    $env:BR_WORK = Join-Path $Path 'work-windows'
    $env:BR_TOOLS = Join-Path $Path 'tools'
    $script:OpenSslTarball = Join-Path $env:BR_DOWNLOADS "openssl-$($script:OpenSslVersion).tar.gz"
}

Set-BuildRoot $(if ($env:BUILDROOT) { $env:BUILDROOT } else { $script:BuildRootDefault })

# One flags file per OpenSSL release series, shared with build-env.sh so both have one source of truth.
# The most specific of flags\<version>.txt, flags\<version without the patch letter>.txt,
# flags\<major.minor>.txt and flags\<major>.txt wins. Per-target deltas live in the $Targets table in build.ps1 and in targets.sh.
function Get-OsslFlagsFile {
    param([string]$Version = $script:OpenSslVersion)
    $candidates = @(
        $Version
        ($Version -replace '[a-z]$', '')
        (($Version -split '\.')[0..1] -join '.')
        (($Version -split '\.')[0])
    ) | Select-Object -Unique
    foreach ($c in $candidates) {
        $f = Join-Path $BrScripts "flags\$c.txt"
        if (Test-Path $f) { return $f }
    }
    throw "no flags file for OpenSSL $Version under $(Join-Path $BrScripts 'flags')"
}
$script:OsslFlagsFile = Get-OsslFlagsFile
$script:OsslFlags = (Get-Content $script:OsslFlagsFile) -join ' '

# Prerequisites Install-BuildRootWindows can provision. Each is pinned by version, URL and SHA-256
# like the OpenSSL tarball, so an unattended install can never pick up a substituted archive. Both are
# portable ZIPs under $BUILDROOT\tools. The URLs are literal because Strawberry's release tag SP_5380_5361 does not derive from its version string.
$script:PerlVersion = '5.38.0.1'
$script:PerlUrl = 'https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/SP_5380_5361/strawberry-perl-5.38.0.1-64bit-portable.zip'
$script:PerlSha256 = 'ca6402a466939d5d658cc0d09a20dc59635ae68f6903a92a747a802539e40908'
$script:NasmVersion = '2.16.03'
$script:NasmUrl = 'https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/win64/nasm-2.16.03-win64.zip'
$script:NasmSha256 = '3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6'

$script:VsWhereDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'

function Get-VsInstallPath {
    $vswhere = Join-Path $script:VsWhereDir 'vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    # VS 2026 (v18) version-stamped the x86 and x64 toolset component id as
    # Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64, where 2017-2022 used the fixed
    # Microsoft.VisualStudio.Component.VC.Tools.x86.x64. Only vswhere 2.6.7+ accepts wildcards in -requires, so try the fixed id first.
    foreach ($req in @('Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
                       'Microsoft.VisualStudio.Component.VC.*.x86.x64')) {
        $path = & $vswhere -latest -products * -requires $req -property installationPath 2>$null
        if ($LASTEXITCODE -eq 0 -and $path) { return ($path | Select-Object -First 1) }
    }
    # Last resort for an installer too old for wildcards paired with a VS too new for the fixed id.
    # Get-VcToolsetVersion still requires a real toolset on disk, so an install without C++ is
    # reported as such rather than half-used.
    $path = & $vswhere -latest -products * -property installationPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $path) { return $null }
    return ($path | Select-Object -First 1)
}

function Get-VcEnvScript {
    # Find the batch file that puts cl, nmake and lib on PATH. vcvarsall.bat is not guaranteed: a v18
    # install carrying only the versioned v143 packages had none, while VsDevCmd.bat, which every VS
    # since 2017 ships, worked. Prefer vcvarsall.bat and record which one was found, since they take different arguments.
    $vs = Get-VsInstallPath
    if (-not $vs) { return $null }
    $vcvarsall = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
    if (Test-Path $vcvarsall) { return @{ Path = $vcvarsall; Kind = 'vcvarsall' } }
    $vsdevcmd = Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
    if (Test-Path $vsdevcmd) { return @{ Path = $vsdevcmd; Kind = 'vsdevcmd' } }
    return $null
}

function Get-VcToolsetVersion {
    # An installed toolset folder is not proof of a usable toolset. Real installs have shown a
    # props-only version folder with no compiler that the default resolution still pointed at, and
    # a newest toolset missing setargv.obj and the CRT for arm64. Pick the newest that is complete for $Arch.
    param([ValidateSet('x86', 'x64', 'x64_arm64')][string]$Arch)

    $vs = Get-VsInstallPath
    if (-not $vs) { return $null }

    $required = switch ($Arch) {
        'x86'       { @('bin\HostX86\x86\cl.exe',   'lib\x86\setargv.obj') }
        'x64'       { @('bin\HostX64\x64\cl.exe',   'lib\x64\setargv.obj') }
        'x64_arm64' { @('bin\HostX64\arm64\cl.exe', 'lib\arm64\setargv.obj') }
    }

    $best = Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $dir = $_.FullName
            -not ($required | Where-Object { -not (Test-Path (Join-Path $dir $_)) })
        } |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if (-not $best) { return $null }

    # -vcvars_ver wants Major.Minor such as "14.44", not the full folder name such as "14.44.35207".
    if ($best.Name -match '^(\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Get-WindowsSdkVersion {
    # A usable toolset is only half the environment. stdlib.h, windows.h and the import libs live in
    # the Windows SDK, which the VC.Tools components do NOT pull in, so without this check cl.exe runs
    # and then dies on "Cannot open include file: 'stdlib.h'". Returns the newest SDK complete for $Arch, or $null.
    param(
        [ValidateSet('x86', 'x64', 'x64_arm64')][string]$Arch,
        [string]$KitsRoot
    )

    $libArch = switch ($Arch) { 'x64' { 'x64' } 'x64_arm64' { 'arm64' } default { 'x86' } }

    $roots = @()
    if ($KitsRoot) { $roots += $KitsRoot }
    if ($env:WindowsSdkDir) { $roots += $env:WindowsSdkDir }
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots',
                     'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots') {
        $r = (Get-ItemProperty -Path $key -Name KitsRoot10 -ErrorAction SilentlyContinue).KitsRoot10
        if ($r) { $roots += $r }
    }
    $roots += @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10')
        (Join-Path $env:ProgramFiles 'Windows Kits\10')
    )

    $best = $null
    foreach ($root in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        $incRoot = Join-Path $root 'Include'
        if (-not (Test-Path $incRoot)) { continue }
        foreach ($dir in (Get-ChildItem $incRoot -Directory -ErrorAction SilentlyContinue)) {
            $v = $dir.Name
            # Check headers and import libs both for this target arch, because an SDK
            # can be installed for one architecture and not another.
            $required = @(
                (Join-Path $dir.FullName 'ucrt\stdlib.h')
                (Join-Path $dir.FullName 'um\windows.h')
                (Join-Path $root "Lib\$v\ucrt\$libArch\libucrt.lib")
                (Join-Path $root "Lib\$v\um\$libArch\kernel32.lib")
            )
            if ($required | Where-Object { -not (Test-Path $_) }) { continue }
            $cur = try { [version]$v } catch { [version]'0.0' }
            if (-not $best -or $cur -gt $best[0]) { $best = @($cur, $v) }
        }
    }
    if ($best) { return $best[1] }
    return $null
}

function Get-VcEnvCall {
    # Build the call line that enters the developer environment for $Arch in whichever dialect
    # the installed VS speaks. Callers append their own redirection. $Arch uses vcvarsall's
    # naming even on the VsDevCmd path.
    param([ValidateSet('x86', 'x64', 'x64_arm64')][string]$Arch)

    $vcEnv = Get-VcEnvScript
    if (-not $vcEnv) { return $null }

    # Always pin the toolset, because the default is unusable on VS 2026 and pinning
    # keeps the object-count gate reproducible everywhere else.
    $ver = Get-VcToolsetVersion -Arch $Arch
    $verArg = if ($ver) { " -vcvars_ver=$ver" } else { '' }

    if ($vcEnv.Kind -eq 'vsdevcmd') {
        # vcvarsall packs host and target into one token. VsDevCmd takes them
        # separately and, unasked, changes directory to the VS default directory.
        $archArgs = @{
            'x86'       = '-arch=x86 -host_arch=x86'
            'x64'       = '-arch=amd64 -host_arch=amd64'
            'x64_arm64' = '-arch=arm64 -host_arch=amd64'
        }
        return "call `"$($vcEnv.Path)`" $($archArgs[$Arch])$verArg -startdir=none -no_logo"
    }
    return "call `"$($vcEnv.Path)`" $Arch$verArg"
}

function Get-NasmPath {
    $portable = Join-Path $env:BR_TOOLS 'nasm\nasm.exe'
    if (Test-Path $portable) { return $portable }
    $cmd = Get-Command nasm.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'bin\NASM\nasm.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Get-PerlPath {
    # OpenSSL's Configure refuses a Cygwin perl, and Git for Windows' bundled perl.exe
    # is exactly that, so skip it even though it is usually on PATH.
    $portable = Join-Path $env:BR_TOOLS 'strawberry-perl\perl\bin\perl.exe'
    if (Test-Path $portable) { return $portable }

    $cmd = Get-Command perl.exe -ErrorAction SilentlyContinue -All
    foreach ($c in $cmd) {
        $ver = & $c.Source -e "print $^O" 2>$null
        if ($ver -and $ver -ne 'cygwin') { return $c.Source }
    }
    return $null
}

function Save-BrDownload {
    # Download once into $BR_DOWNLOADS and gate on SHA-256. A file that fails the check is
    # deleted rather than left in place, so a retry re-fetches instead of failing forever on a truncated download.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sha256,
        [switch]$Force
    )

    if ($Force -and (Test-Path $Path)) { Remove-Item -Force $Path }
    if (Test-Path $Path) {
        if ((Get-FileHash $Path -Algorithm SHA256).Hash.ToLower() -eq $Sha256.ToLower()) {
            Write-Host "    cached  : $Path"
            return $true
        }
        Write-Host "    cached copy failed its checksum - refetching"
        Remove-Item -Force $Path
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    Write-Host "    fetching: $Url"
    # Invoke-WebRequest's progress bar costs more than the download on a big ZIP.
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
    } catch {
        Write-Host "    FAILED  : $($_.Exception.Message)"
        return $false
    } finally {
        $ProgressPreference = $prevProgress
    }

    $got = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $Sha256.ToLower()) {
        Remove-Item -Force $Path
        Write-Host "    REJECTED: sha256 $got does not match the pinned $Sha256"
        return $false
    }
    return $true
}

function Expand-BrZip {
    # Unpack into a staging dir and swap it into place, so an interrupted extract never leaves a
    # half-populated tools dir that the probes would treat as a working install. A ZIP with one
    # top-level folder (nasm) is flattened, and one that unpacks flat (strawberry) is taken as-is.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $staging = "$Destination.unpack"
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null

    [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $staging)
    $entries = @(Get-ChildItem -Force $staging)
    $root = if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { $entries[0].FullName } else { $staging }

    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    Move-Item -LiteralPath $root -Destination $Destination
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
}

function Get-VcComponentId {
    # Component id for the VS installer's --add, read from the installer's own catalog. The catalog
    # lists every component whether or not it is installed, so this still resolves after the C++
    # workload was removed, which is exactly when deriving it from installed packages would go blind.
    param([ValidateSet('x64', 'arm64', 'sdk')][string]$Arch)

    # x86 and x64 come from one component and arm64 is its own. The Windows SDK is a separate
    # component again, and installing only VC.Tools yields a cl.exe with no stdlib.h, so it must be asked for by name.
    $suffix = switch ($Arch) { 'arm64' { 'ARM64' } 'sdk' { $null } default { 'x86.x64' } }
    $fixed = if ($suffix) { "Microsoft.VisualStudio.Component.VC.Tools.$suffix" } else { $null }

    $vswhere = Join-Path $script:VsWhereDir 'vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $instanceId = & $vswhere -latest -products * -property instanceId 2>$null | Select-Object -First 1
    $catalog = if ($instanceId) {
        Join-Path $env:ProgramData "Microsoft\VisualStudio\Packages\_Instances\$instanceId\components.json"
    } else { $null }

    # With no catalog to consult, the fixed id is correct for every VS that shipped vcvarsall.bat,
    # so offer that rather than nothing. The SDK id is versioned with no fixed alias, so it cannot be guessed.
    if (-not $catalog -or -not (Test-Path $catalog)) { return $fixed }

    $text = Get-Content $catalog -Raw

    if ($Arch -eq 'sdk') {
        # Newest Windows SDK this VS offers, such as Windows11SDK.26100.
        $rx = [regex]'"Microsoft\.VisualStudio\.Component\.Windows\d+SDK\.(\d+)"'
        $best = $rx.Matches($text) |
            Sort-Object { [int]$_.Groups[1].Value } -Descending |
            Select-Object -First 1
        if (-not $best) { return $null }
        return $best.Value.Trim('"')
    }

    # Prefer the fixed "latest toolset" id. 2017-2022 and v18 all offer it, and it
    # keeps tracking the newest toolset across VS updates.
    if ($text.Contains('"' + $fixed + '"')) { return $fixed }

    $rx = [regex]('"Microsoft\.VisualStudio\.Component\.VC\.(\d[\d.]*)\.' + [regex]::Escape($suffix) + '"')
    $best = $rx.Matches($text) |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object { try { [version]$_ } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if (-not $best) { return $null }
    return "Microsoft.VisualStudio.Component.VC.$best.$suffix"
}

# Provisioning half of Test-BuildRootWindows. It fetches and unpacks whatever that report
# lists as missing. Everything lands under $BUILDROOT, and nothing is installed system-wide or added to PATH.
function Install-BuildRootWindows {
    [CmdletBinding()]
    param(
        [string]$BuildRoot,
        [switch]$Tarball,
        [switch]$Perl,
        [switch]$Nasm,
        [switch]$VsComponents,
        [switch]$Force
    )

    # Settle where this is all going before writing anything. -BuildRoot wins outright, otherwise
    # ask, with Enter taking the current default. A session that cannot answer, because it is
    # non-interactive or -Force was given, keeps the default rather than blocking on a prompt nobody sees.
    if ($BuildRoot) {
        Set-BuildRoot (Resolve-BrPath $BuildRoot)
    } elseif (-not $Force) {
        try {
            $answer = Read-Host "  buildroot path [$env:BUILDROOT]"
            if ($answer -and $answer.Trim()) { Set-BuildRoot (Resolve-BrPath $answer.Trim()) }
        } catch {
            # Non-interactive host, so Read-Host cannot return an answer here.
        }
    }
    Write-Host "  buildroot: $env:BUILDROOT"

    # A bare call provisions everything that needs no admin rights. -VsComponents is never implied,
    # because it drives the Visual Studio installer, needs elevation, and changes an install this script does not own.
    if (-not ($Tarball -or $Perl -or $Nasm -or $VsComponents)) {
        $Tarball = $true; $Perl = $true; $Nasm = $true
    }
    $ok = $true

    if ($Tarball) {
        Write-Host "  openssl $script:OpenSslVersion source tarball"
        if (Save-BrDownload -Url $script:OpenSslUrl -Path $script:OpenSslTarball -Sha256 (Get-OpenSslSha256) -Force:$Force) {
            Write-Host "    ready   : $script:OpenSslTarball"
        } else { $ok = $false }
    }

    if ($Perl) {
        Write-Host "  strawberry perl $script:PerlVersion (portable)"
        $dest = Join-Path $env:BR_TOOLS 'strawberry-perl'
        $exe = Join-Path $dest 'perl\bin\perl.exe'
        if ((Test-Path $exe) -and -not $Force) {
            Write-Host "    ready   : $exe"
        } else {
            $zip = Join-Path $env:BR_DOWNLOADS "strawberry-perl-$script:PerlVersion-64bit-portable.zip"
            if (Save-BrDownload -Url $script:PerlUrl -Path $zip -Sha256 $script:PerlSha256) {
                Write-Host "    unpacking (a few GB once extracted, give it a minute)"
                Expand-BrZip -Path $zip -Destination $dest
                if (Test-Path $exe) { Write-Host "    ready   : $exe" }
                else { Write-Host "    FAILED  : perl.exe not found under $dest"; $ok = $false }
            } else { $ok = $false }
        }
    }

    if ($Nasm) {
        Write-Host "  nasm $script:NasmVersion"
        $dest = Join-Path $env:BR_TOOLS 'nasm'
        $exe = Join-Path $dest 'nasm.exe'
        if ((Test-Path $exe) -and -not $Force) {
            Write-Host "    ready   : $exe"
        } else {
            $zip = Join-Path $env:BR_DOWNLOADS "nasm-$script:NasmVersion-win64.zip"
            if (Save-BrDownload -Url $script:NasmUrl -Path $zip -Sha256 $script:NasmSha256) {
                Expand-BrZip -Path $zip -Destination $dest
                if (Test-Path $exe) { Write-Host "    ready   : $exe" }
                else { Write-Host "    FAILED  : nasm.exe not found under $dest"; $ok = $false }
            } else { $ok = $false }
        }
    }

    if ($VsComponents) {
        Write-Host "  MSVC build tools"
        # Only ask for what is actually absent, so re-running this is a no-op rather
        # than a needless trip through the installer.
        $need = @()
        if (-not (Get-VcToolsetVersion -Arch x64))       { $need += Get-VcComponentId -Arch x64 }
        if (-not (Get-VcToolsetVersion -Arch x64_arm64)) { $need += Get-VcComponentId -Arch arm64 }
        # The SDK ships separately from the toolset, so ask for it whenever no target
        # has one, or the install ends up with a cl.exe and no headers.
        if (-not (Get-WindowsSdkVersion -Arch x64))      { $need += Get-VcComponentId -Arch sdk }
        $need = @($need | Where-Object { $_ })

        $vs = Get-VsInstallPath
        $setup = Join-Path $script:VsWhereDir 'setup.exe'
        if ($need.Count -eq 0) {
            Write-Host "    ready   : x86/x64 $(Get-VcToolsetVersion -Arch x64), arm64 $(Get-VcToolsetVersion -Arch x64_arm64)"
        } elseif (-not $vs -or -not (Test-Path $setup)) {
            Write-Host "    no Visual Studio installer found - add the C++ components from the VS installer UI instead"
            $ok = $false
        } else {
            $setupArgs = @('modify', '--installPath', "`"$vs`"")
            foreach ($id in $need) { $setupArgs += @('--add', $id) }
            # --passive is required because the installer rejects --norestart on its own
            # ("requires either --quiet or --passive") and shows its usage dialog instead of doing
            # anything. It also keeps the progress UI visible, which a multi-GB component install wants.
            $setupArgs += @('--passive', '--norestart')
            Write-Host "    `"$setup`" $($setupArgs -join ' ')"
            # Elevating into someone's Visual Studio install is not a call this script makes unattended.
            $approved = [bool]$Force
            if (-not $approved) {
                try {
                    $approved = $PSCmdlet.ShouldContinue(
                        "Run the Visual Studio installer elevated to add $($need -join ', ')?",
                        'Modify the Visual Studio installation')
                } catch {
                    # A non-interactive host cannot answer, and silently elevating is the wrong way to resolve that.
                    Write-Host "    cannot prompt in a non-interactive session - re-run with -Force to proceed"
                    $approved = $false
                }
            }
            if ($approved) {
                Start-Process -FilePath $setup -ArgumentList $setupArgs -Verb RunAs -Wait
                $x64Got = Get-VcToolsetVersion -Arch x64
                $armGot = Get-VcToolsetVersion -Arch x64_arm64
                $sdkGot = Get-WindowsSdkVersion -Arch x64
                Write-Host "    x86/x64 : $(if ($x64Got) { $x64Got } else { 'not present yet' })"
                Write-Host "    arm64   : $(if ($armGot) { $armGot } else { 'not present yet' })"
                Write-Host "    sdk     : $(if ($sdkGot) { $sdkGot } else { 'not present yet' })"
                if (-not $x64Got -or -not $armGot -or -not $sdkGot) {
                    # setup.exe hands the real work to a child process and can exit before it
                    # finishes, so this means not done yet, not proof that the install failed.
                    Write-Host "    if the Visual Studio installer is still running, re-run Test-BuildRootWindows once it finishes"
                    $ok = $false
                }
            } else {
                # Declining is a valid choice, but the toolset is still absent, so do not
                # report a provisioned buildroot to a caller checking this.
                Write-Host "    skipped - run the command above yourself when ready"
                $ok = $false
            }
        }
    }

    if ($ok) { Write-Host "  done - re-run Test-BuildRootWindows to confirm" }
    return $ok
}

# Read-only report that confirms every input this build needs is present without
# building anything. Mirrors br_check() in build-env.sh.
function Test-BuildRootWindows {
    $ok = $true

    if (Test-Path $script:OpenSslTarball) {
        Write-Host "  openssl tarball : $script:OpenSslTarball"
    } else {
        Write-Host "  MISSING openssl tarball: $script:OpenSslTarball (run Install-BuildRootWindows)"
        $ok = $false
    }

    $vcEnv = Get-VcEnvScript
    if ($vcEnv) {
        Write-Host "  msvc env script : $($vcEnv.Path)"

        # Report per-target toolsets, not just that a VS exists, because a complete
        # install for x64 can still be missing the arm64 target's lib set.
        foreach ($a in @('x86', 'x64', 'x64_arm64')) {
            $ver = Get-VcToolsetVersion -Arch $a
            $sdk = Get-WindowsSdkVersion -Arch $a
            if ($ver -and $sdk) {
                Write-Host ("  {0,-15} : {1}  (sdk {2})" -f "$a toolset", $ver, $sdk)
                continue
            }
            if (-not $ver) {
                $component = if ($a -eq 'x64_arm64') { 'C++ ARM64 build tools' } else { 'C++ x64/x86 build tools' }
                Write-Host "  MISSING: no complete MSVC toolset for $a - install the '$component' component (Install-BuildRootWindows -VsComponents)"
            }
            if (-not $sdk) {
                Write-Host "  MISSING: no Windows SDK for $a - the VC.Tools components do not include it (Install-BuildRootWindows -VsComponents)"
            }
            $ok = $false
        }
    } else {
        Write-Host "  MISSING: no Visual Studio install with the x86/x64 VC++ toolset found"
        $ok = $false
    }

    $perl = Get-PerlPath
    if ($perl) {
        Write-Host "  perl            : $perl"
    } else {
        Write-Host "  MISSING: perl.exe (run Install-BuildRootWindows, or use Git for Windows / Strawberry Perl)"
        $ok = $false
    }

    $nasm = Get-NasmPath
    if ($nasm) {
        Write-Host "  nasm            : $nasm  (asm-enabled x86/x64 targets)"
    } else {
        Write-Host "  nasm not found  : x86/x64 targets will fall back to -no-asm (run Install-BuildRootWindows)"
    }

    if ($ok) { Write-Host "  all required inputs present" }
    return $ok
}

Write-Host "BUILDROOT=$env:BUILDROOT  (openssl $OpenSslVersion, repo $Repo)"
