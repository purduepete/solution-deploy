#requires -Version 5.1
Set-StrictMode -Version Latest

function Get-ManagedPowerShellPath {
    param([string]$Root = 'C:\ProgramData\SolutionDeploy\runtime\powershell')
    Join-Path $Root '7\pwsh.exe'
}

function Get-PowerShellReleaseAsset {
    param([Parameter(Mandatory)]$Release)
    if ($Release.draft -or $Release.prerelease -or $Release.tag_name -notmatch '^v(7\.\d+\.\d+)$') {
        throw 'Only stable PowerShell 7 releases are supported.'
    }
    $version = $Matches[1]
    if ([version]$version -lt [version]'7.5.0') { throw 'PowerShell 7.5 or newer is required.' }
    $name = "PowerShell-$version-win-x64.zip"
    $assets = @($Release.assets | Where-Object name -eq $name)
    if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw "Official release has no unique SHA256-pinned asset: $name"
    }
    $hash = $Matches[1].ToLowerInvariant()
    $url = "https://github.com/PowerShell/PowerShell/releases/download/v$version/$name"
    if ($assets[0].browser_download_url -cne $url) { throw 'Unexpected release download URL.' }
    [pscustomobject]@{ Version = $version; Name = $name; Url = $url; SHA256 = $hash }
}

function Get-ManagedPowerShellSmokeScript {
    # Runs inside the candidate runtime. The caller compares the printed version with the expected one.
    @'
$ErrorActionPreference = 'Stop'
Import-Module ScheduledTasks -ErrorAction Stop
Import-Module CimCmdlets -ErrorAction Stop
$timestamp = (ConvertFrom-Json '{"t":"2026-10-31T01:28:20.1839545-07:00"}' -DateKind String).t
if ($timestamp -cne '2026-10-31T01:28:20.1839545-07:00') { throw "ConvertFrom-Json changed the timestamp: $timestamp" }
[Console]::Write($PSVersionTable.PSVersion.ToString())
'@
}

function Test-ManagedPowerShell {
    param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$Version)
    foreach ($file in @($Executable, (Join-Path (Split-Path -Parent $Executable) 'System.Management.Automation.dll'))) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|, )O=Microsoft Corporation(?:,|$)') {
            throw "Microsoft signature verification failed: $file"
        }
    }
    # Encoding the smoke script avoids nested quoting between Windows PowerShell and the candidate runtime.
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-ManagedPowerShellSmokeScript)))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedScript"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Could not start $Executable" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'PowerShell runtime verification exceeded 30 seconds.'
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $output -cne $Version -or $errorOutput) {
            throw "PowerShell runtime verification failed (exit $($process.ExitCode)): $output $errorOutput"
        }
    } finally { $process.Dispose() }
}

function Get-DeploymentLockPaths {
    param(
        [string]$AppsRoot = 'C:\ProgramData\SolutionDeploy\apps',
        [string]$BackupLock = 'C:\ProgramData\JimlerTech\PostgreSQL\backups\backup.lock',
        # The host executor's global lock, so a runtime switch also waits for active Stage operations.
        [string]$ExecutionLock = 'C:\ProgramData\SolutionDeploy\control\execution.lock'
    )
    $paths = @()
    if (Test-Path -LiteralPath $AppsRoot -PathType Container) {
        $apps = @(Get-ChildItem -LiteralPath $AppsRoot -Directory)
        foreach ($name in 'common-controller.lock', 'deployment.lock', 'directory-install.lock') {
            $paths += @($apps | ForEach-Object { Join-Path $_.FullName "state\$name" })
        }
    }
    $paths + $BackupLock + $ExecutionLock
}

function Assert-ManagedPowerShellMarketClosed {
    param([switch]$AllowMarketHours, [datetime]$UtcNow = [datetime]::UtcNow)
    if ($AllowMarketHours) { return }
    $eastern = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $utc = if ($UtcNow.Kind -eq [DateTimeKind]::Local) { $UtcNow.ToUniversalTime() } else { [datetime]::SpecifyKind($UtcNow, 'Utc') }
    $local = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $eastern)
    $weekday = $local.DayOfWeek -notin 'Saturday', 'Sunday'
    if ($weekday -and $local.TimeOfDay -ge [timespan]'09:30' -and $local.TimeOfDay -lt [timespan]'16:00') {
        throw "Refusing to switch PowerShell during US market hours (Eastern $($local.ToString('ddd HH:mm'))). Rerun with -AllowMarketHours to override."
    }
}

function Enter-ManagedPowerShellLockFence {
    <#
    Checks market hours, then opens every deployment and backup lock exclusively and returns the open handles.
    Missing lock files are created, as Get-DeploymentLock does, so a deployment that starts later cannot
    slip past the fence. Pass the handles to Exit-ManagedPowerShellLockFence once the switch is done.
    If any lock is held, the handles already acquired are released before the error is thrown.
    #>
    param(
        [string[]]$LockPath = (Get-DeploymentLockPaths),
        [switch]$AllowMarketHours,
        [datetime]$UtcNow = [datetime]::UtcNow
    )
    Assert-ManagedPowerShellMarketClosed -AllowMarketHours:$AllowMarketHours -UtcNow $UtcNow
    $handles = [Collections.Generic.List[IO.FileStream]]::new()
    try {
        foreach ($path in $LockPath) {
            [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
            try {
                $handles.Add([IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
            } catch [IO.IOException] {
                throw "A deployment or backup lock is held. Wait for it to finish before switching PowerShell: $path"
            }
        }
    } catch {
        foreach ($handle in $handles) { $handle.Dispose() }
        throw
    }
    , $handles.ToArray()
}

function Exit-ManagedPowerShellLockFence {
    param([AllowNull()][IO.FileStream[]]$Fence)
    foreach ($handle in @($Fence)) { if ($handle) { $handle.Dispose() } }
}

function Test-ManagedPowerShellLockSafety {
    <#
    Point-in-time check: refuses while a deployment or backup holds a lock, or during US market hours
    (Mon-Fri 09:30-16:00 Eastern) unless -AllowMarketHours is given. Use Enter-ManagedPowerShellLockFence
    to keep the locks held across a switch.
    #>
    param(
        [string[]]$LockPath = (Get-DeploymentLockPaths),
        [switch]$AllowMarketHours,
        [datetime]$UtcNow = [datetime]::UtcNow
    )
    $fence = Enter-ManagedPowerShellLockFence -LockPath $LockPath -AllowMarketHours:$AllowMarketHours -UtcNow $UtcNow
    Exit-ManagedPowerShellLockFence -Fence $fence
}

function Expand-VerifiedPowerShellArchive {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$SHA256,
        [Parameter(Mandatory)][string]$Destination
    )
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ine $SHA256) { throw 'PowerShell archive SHA256 mismatch.' }
    if (Test-Path -LiteralPath $Destination) { throw "Extraction destination already exists: $Destination" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $prefix = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
        foreach ($entry in $zip.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe archive entry: $($entry.FullName)"
            }
        }
    } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
}

function Set-ManagedPowerShellVersion {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Version
    )
    if ($Version -notmatch '^7\.\d+\.\d+$' -or [version]$Version -lt [version]'7.5.0') { throw "Unsupported version: $Version" }
    $release = Join-Path $Root "versions\$Version"
    Test-ManagedPowerShell -Executable (Join-Path $release 'pwsh.exe') -Version $Version
    $current = Join-Path $Root '7'
    $previous = Join-Path $Root 'previous'
    $pending = Join-Path $Root 'pending'
    foreach ($link in @($current, $previous)) {
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1 -or
                (Split-Path -Parent @($item.Target)[0]) -ine (Join-Path $Root 'versions')) {
                throw "Runtime link is not an owned version junction: $link"
            }
        }
    }
    if (Test-Path -LiteralPath $pending) { throw "Unfinished runtime switch at $pending. Inspect it before retrying." }
    $oldTarget = $null
    if (Test-Path -LiteralPath $current) {
        $oldTarget = @((Get-Item -LiteralPath $current -Force).Target)[0]
        if ($oldTarget -ieq $release) { return }
    }
    New-Item -ItemType Junction -Path $pending -Target $release -ErrorAction Stop | Out-Null
    try {
        if ($oldTarget -and (Test-Path -LiteralPath $previous)) { [IO.Directory]::Delete($previous) }
        if ($oldTarget) { Move-Item -LiteralPath $current -Destination $previous -ErrorAction Stop }
        try {
            Move-Item -LiteralPath $pending -Destination $current -ErrorAction Stop
            Test-ManagedPowerShell -Executable (Get-ManagedPowerShellPath -Root $Root) -Version $Version
        } catch {
            if (Test-Path -LiteralPath $current) { [IO.Directory]::Delete($current) }
            if ($oldTarget) { Move-Item -LiteralPath $previous -Destination $current -ErrorAction Stop }
            throw
        }
    } finally {
        if (Test-Path -LiteralPath $pending) { [IO.Directory]::Delete($pending) }
    }
}

Export-ModuleMember -Function Get-ManagedPowerShellPath, Get-PowerShellReleaseAsset, Get-ManagedPowerShellSmokeScript, Test-ManagedPowerShell, Enter-ManagedPowerShellLockFence, Exit-ManagedPowerShellLockFence, Test-ManagedPowerShellLockSafety, Expand-VerifiedPowerShellArchive, Set-ManagedPowerShellVersion
