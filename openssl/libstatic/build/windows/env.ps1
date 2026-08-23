# MeshAgent OpenSSL Windows build environment - vendored copy, tracked in git.
#
# Dot-source this, do not run it directly:  . openssl\libstatic\build\windows\env.ps1
#
# Native sibling of openssl/libstatic/build/env.sh: MSVC's Configure targets
# and nmake need a real MSVC developer environment, not just Git Bash.

$script:BrWindowsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:BrScripts = Split-Path -Parent $BrWindowsDir
$script:Repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $BrScripts))

# Keep in sync with env.sh - same pinned release, same tarball, same source.
$script:OpenSslVersion = '1.1.1w'
$script:OpenSslSha256 = 'cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8'
$script:OpenSslUrl = "https://github.com/openssl/openssl/releases/download/OpenSSL_$($OpenSslVersion -replace '\.', '_')/openssl-$OpenSslVersion.tar.gz"

# The default lives under the user profile; override by setting BUILDROOT before
# dot-sourcing, or answer Install-BuildRootWindows's prompt for this session.
$script:BuildRootDefault = Join-Path $env:LOCALAPPDATA 'meshagent-buildroot'

function Resolve-BrPath {
    # Normalise a hand-typed path: strip stray quotes, expand %VARS% and ~, and
    # make it absolute, so a relative answer cannot quietly produce a buildroot
    # somewhere else once a later step changes directory.
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
    # Repoint $BUILDROOT and everything derived from it in one place. The
    # derived paths are fixed at dot-source time, so setting $env:BUILDROOT on
    # its own would leave BR_DOWNLOADS and the tarball path addressing the old
    # tree while BUILDROOT claimed otherwise.
    param([Parameter(Mandatory)][string]$Path)

    $env:BUILDROOT = $Path
    $env:BR_DOWNLOADS = Join-Path $Path 'downloads'
    $env:BR_WORK = Join-Path $Path 'work-windows'
    $env:BR_TOOLS = Join-Path $Path 'tools'
    $script:OpenSslTarball = Join-Path $env:BR_DOWNLOADS "openssl-$($script:OpenSslVersion).tar.gz"
}

Set-BuildRoot $(if ($env:BUILDROOT) { $env:BUILDROOT } else { $script:BuildRootDefault })

# Same flags.txt env.sh reads - single source of truth for both.
$script:OsslFlags = (Get-Content (Join-Path $BrScripts 'flags.txt')) -join ' '

# Prerequisites Install-BuildRootWindows can provision, pinned the same way the
# OpenSSL tarball is - fixed version, URL and SHA-256 - so an unattended install
# can never pick up a substituted archive. Both are portable ZIPs: no installer,
# no admin rights, no PATH edits, everything under $BUILDROOT\tools. The URLs are
# literal rather than built from the versions - Strawberry's release tag
# (SP_5380_5361) does not derive from its version string.
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
    # VS 2026 (v18) version-stamped the x86/x64 toolset component id -
    # Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64 - where 2017-2022
    # used a fixed Microsoft.VisualStudio.Component.VC.Tools.x86.x64. The
    # wildcard matches both ("Tools" is just another segment), but -requires
    # only understands wildcards in vswhere 2.6.7+, so try the fixed id first:
    # on 2017-2022 that hits regardless of how old the installer is.
    foreach ($req in @('Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
                       'Microsoft.VisualStudio.Component.VC.*.x86.x64')) {
        $path = & $vswhere -latest -products * -requires $req -property installationPath 2>$null
        if ($LASTEXITCODE -eq 0 -and $path) { return ($path | Select-Object -First 1) }
    }
    # Last resort - an installer too old for wildcards paired with a VS too new
    # for the fixed id. Get-VcToolsetVersion still gates on a real toolset being
    # on disk, so a C++-less install is reported as such rather than half-used.
    $path = & $vswhere -latest -products * -property installationPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $path) { return $null }
    return ($path | Select-Object -First 1)
}

function Get-VcEnvScript {
    # The batch file that puts cl/nmake/lib on PATH. vcvarsall.bat is the usual
    # one, but it is not guaranteed: a v18 install carrying only the versioned
    # v143 toolset packages had no vcvarsall.bat anywhere, while VsDevCmd.bat -
    # which every VS since 2017 ships - was present and worked. Prefer
    # vcvarsall.bat, fall back to VsDevCmd.bat, and record which one we found
    # because the two take different arguments.
    $vs = Get-VsInstallPath
    if (-not $vs) { return $null }
    $vcvarsall = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
    if (Test-Path $vcvarsall) { return @{ Path = $vcvarsall; Kind = 'vcvarsall' } }
    $vsdevcmd = Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
    if (Test-Path $vsdevcmd) { return @{ Path = $vsdevcmd; Kind = 'vsdevcmd' } }
    return $null
}

function Get-VcToolsetVersion {
    # An installed MSVC toolset folder is not proof of a usable toolset. Both
    # failure modes have been seen on real installs: a props-only version folder
    # carrying no compiler at all, which the product's own default resolution
    # still pointed at (leaving an unpinned vcvars call with no cl.exe), and a
    # newest-installed toolset with an incomplete arm64 lib set - present dir,
    # missing setargv.obj/CRT. Pick the newest that is complete for $Arch.
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

    # -vcvars_ver wants Major.Minor (e.g. "14.44"), not the full three-part
    # folder name (e.g. "14.44.35207").
    if ($best.Name -match '^(\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Get-WindowsSdkVersion {
    # A usable MSVC toolset is only half the environment: stdlib.h, windows.h
    # and the import libs all live in the Windows SDK, which the individual
    # VC.Tools components do NOT pull in. Without this check a build gets a
    # working cl.exe and then dies on "Cannot open include file: 'stdlib.h'".
    # Returns the newest SDK complete for $Arch, or $null.
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
            # Headers and import libs both, for this target arch - an SDK can
            # be installed for one architecture and not another.
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
    # The `call "..."` line that enters the developer environment for $Arch,
    # in whichever dialect the installed VS speaks. Callers append their own
    # redirection. $Arch uses vcvarsall's naming even on the VsDevCmd path.
    param([ValidateSet('x86', 'x64', 'x64_arm64')][string]$Arch)

    $vcEnv = Get-VcEnvScript
    if (-not $vcEnv) { return $null }

    # Always pin the toolset: the default is unusable on VS 2026, and pinning
    # keeps the object-count gate reproducible everywhere else.
    $ver = Get-VcToolsetVersion -Arch $Arch
    $verArg = if ($ver) { " -vcvars_ver=$ver" } else { '' }

    if ($vcEnv.Kind -eq 'vsdevcmd') {
        # vcvarsall packs host and target into one token; VsDevCmd takes them
        # separately and, unasked, cd's to the VS default directory.
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
    # OpenSSL's Configure refuses a Cygwin perl - Git for Windows' bundled
    # perl.exe is exactly that, so skip it even though it's usually on PATH.
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
    # Download once into $BR_DOWNLOADS and gate on SHA-256. A file that fails
    # the check is deleted rather than left in place, so a retry re-fetches
    # instead of failing forever on a truncated download.
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
    # Unpack into a staging dir and swap it into place, so an interrupted
    # extract never leaves a half-populated tools dir that the probes would
    # then treat as a working install. A ZIP with one top-level folder (nasm)
    # is flattened; one that unpacks flat (strawberry) is taken as-is.
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
    # Component id to hand the VS installer's --add, read from the installer's
    # own catalog of what this product offers. The catalog lists every component
    # whether or not it is installed, so this still resolves when the C++
    # workload has been removed outright - deriving it from the *installed*
    # packages instead would go blind exactly when it is needed most.
    param([ValidateSet('x64', 'arm64', 'sdk')][string]$Arch)

    # x86 and x64 come from one component; arm64 is its own. The Windows SDK is
    # a separate component again - installing only VC.Tools yields a cl.exe with
    # no stdlib.h, so it has to be asked for by name.
    $suffix = switch ($Arch) { 'arm64' { 'ARM64' } 'sdk' { $null } default { 'x86.x64' } }
    $fixed = if ($suffix) { "Microsoft.VisualStudio.Component.VC.Tools.$suffix" } else { $null }

    $vswhere = Join-Path $script:VsWhereDir 'vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $instanceId = & $vswhere -latest -products * -property instanceId 2>$null | Select-Object -First 1
    $catalog = if ($instanceId) {
        Join-Path $env:ProgramData "Microsoft\VisualStudio\Packages\_Instances\$instanceId\components.json"
    } else { $null }

    # No catalog to consult: the fixed id is correct for every VS that shipped
    # vcvarsall.bat, so offer that rather than nothing. The SDK id is versioned
    # with no fixed alias, so it cannot be guessed without the catalog.
    if (-not $catalog -or -not (Test-Path $catalog)) { return $fixed }

    $text = Get-Content $catalog -Raw

    if ($Arch -eq 'sdk') {
        # Newest Windows SDK this VS offers, e.g. Windows11SDK.26100.
        $rx = [regex]'"Microsoft\.VisualStudio\.Component\.Windows\d+SDK\.(\d+)"'
        $best = $rx.Matches($text) |
            Sort-Object { [int]$_.Groups[1].Value } -Descending |
            Select-Object -First 1
        if (-not $best) { return $null }
        return $best.Value.Trim('"')
    }

    # Prefer the fixed "latest toolset" id - 2017-2022 and v18 all offer it, and
    # it keeps tracking the newest toolset across VS updates.
    if ($text.Contains('"' + $fixed + '"')) { return $fixed }

    $rx = [regex]('"Microsoft\.VisualStudio\.Component\.VC\.(\d[\d.]*)\.' + [regex]::Escape($suffix) + '"')
    $best = $rx.Matches($text) |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object { try { [version]$_ } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if (-not $best) { return $null }
    return "Microsoft.VisualStudio.Component.VC.$best.$suffix"
}

# Provisioning half of Test-BuildRootWindows: fetch and unpack whatever that
# report lists as missing. Everything lands under $BUILDROOT - nothing is
# installed system-wide, added to PATH, or left behind outside it.
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

    # Settle where this is all going before writing anything. -BuildRoot wins
    # outright; otherwise ask, with Enter taking the current default. A session
    # that cannot answer (non-interactive, or -Force) keeps the default rather
    # than blocking on a prompt nobody is there to see.
    if ($BuildRoot) {
        Set-BuildRoot (Resolve-BrPath $BuildRoot)
    } elseif (-not $Force) {
        try {
            $answer = Read-Host "  buildroot path [$env:BUILDROOT]"
            if ($answer -and $answer.Trim()) { Set-BuildRoot (Resolve-BrPath $answer.Trim()) }
        } catch {
            # Non-interactive host - Read-Host cannot return an answer here.
        }
    }
    Write-Host "  buildroot: $env:BUILDROOT"

    # A bare call provisions everything that needs no admin rights.
    # -VsComponents is never implied: it drives the Visual Studio installer,
    # needs elevation, and changes an install this script does not own.
    if (-not ($Tarball -or $Perl -or $Nasm -or $VsComponents)) {
        $Tarball = $true; $Perl = $true; $Nasm = $true
    }
    $ok = $true

    if ($Tarball) {
        Write-Host "  openssl $script:OpenSslVersion source tarball"
        if (Save-BrDownload -Url $script:OpenSslUrl -Path $script:OpenSslTarball -Sha256 $script:OpenSslSha256 -Force:$Force) {
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
        # Only ask for what is actually absent, so re-running this is a no-op
        # rather than a needless trip through the installer.
        $need = @()
        if (-not (Get-VcToolsetVersion -Arch x64))       { $need += Get-VcComponentId -Arch x64 }
        if (-not (Get-VcToolsetVersion -Arch x64_arm64)) { $need += Get-VcComponentId -Arch arm64 }
        # The SDK ships separately from the toolset - ask for it whenever no
        # target has one, or the install ends up with a cl.exe and no headers.
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
            # --passive is not optional decoration: the installer rejects
            # --norestart on its own ("requires either --quiet or --passive")
            # and answers with its usage dialog instead of doing anything. It
            # also keeps the progress UI visible, which a multi-GB component
            # install wants.
            $setupArgs += @('--passive', '--norestart')
            Write-Host "    `"$setup`" $($setupArgs -join ' ')"
            # Elevating into someone's Visual Studio install is not a call this
            # script makes unattended.
            $approved = [bool]$Force
            if (-not $approved) {
                try {
                    $approved = $PSCmdlet.ShouldContinue(
                        "Run the Visual Studio installer elevated to add $($need -join ', ')?",
                        'Modify the Visual Studio installation')
                } catch {
                    # A non-interactive host cannot answer, and silently
                    # elevating is the wrong way to resolve that.
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
                    # setup.exe hands the real work to a child process and can
                    # exit before it finishes, so this is "not done yet", not
                    # proof the install failed.
                    Write-Host "    if the Visual Studio installer is still running, re-run Test-BuildRootWindows once it finishes"
                    $ok = $false
                }
            } else {
                # Declining is a valid choice, but the toolset is still absent -
                # don't report a provisioned buildroot to a caller checking this.
                Write-Host "    skipped - run the command above yourself when ready"
                $ok = $false
            }
        }
    }

    if ($ok) { Write-Host "  done - re-run Test-BuildRootWindows to confirm" }
    return $ok
}

# Read-only report - confirms every input this build needs is present,
# without building anything. Mirrors env.sh's br_check().
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

        # Report per-target toolsets, not just "a VS exists" - a complete
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
