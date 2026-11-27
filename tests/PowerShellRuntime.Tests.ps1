$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\PowerShellRuntime.psm1') -Force

Describe 'Managed PowerShell release selection' {
    function New-Release([string]$Tag = 'v7.6.7') {
        $version = $Tag.TrimStart('v')
        [pscustomobject]@{
            tag_name = $Tag; draft = $false; prerelease = $false
            assets = @([pscustomobject]@{
                name = "PowerShell-$version-win-x64.zip"
                digest = 'sha256:' + ('a' * 64)
                browser_download_url = "https://github.com/PowerShell/PowerShell/releases/download/$Tag/PowerShell-$version-win-x64.zip"
            })
        }
    }
    It 'uses a fixed path outside the desktop installation' {
        Get-ManagedPowerShellPath | Should Be 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'
    }
    It 'requires an exact official stable asset with a SHA256 digest' {
        $asset = Get-PowerShellReleaseAsset -Release (New-Release)
        $asset.Version | Should Be '7.6.7'
        $asset.SHA256 | Should Be ('a' * 64)
    }
    It 'rejects preview releases' {
        $release = New-Release
        $release.prerelease = $true
        { Get-PowerShellReleaseAsset -Release $release } | Should Throw 'stable'
    }
    It 'rejects unsupported versions, missing digests and foreign URLs' {
        { Get-PowerShellReleaseAsset -Release (New-Release 'v7.4.9') } | Should Throw '7.5'
        $release = New-Release
        $release.assets[0].digest = ''
        { Get-PowerShellReleaseAsset -Release $release } | Should Throw 'SHA256'
        $release = New-Release
        $release.assets[0].browser_download_url = 'https://example.org/runtime.zip'
        { Get-PowerShellReleaseAsset -Release $release } | Should Throw 'URL'
    }
}

Describe 'Verified runtime archive extraction' {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    It 'rejects a corrupted archive before extracting' {
        $archive = Join-Path $TestDrive 'corrupted.zip'
        Set-Content $archive 'not an archive'
        { Expand-VerifiedPowerShellArchive -Archive $archive -SHA256 ('0' * 64) -Destination (Join-Path $TestDrive 'bad') } | Should Throw 'SHA256'
        Test-Path (Join-Path $TestDrive 'bad') | Should Be $false
    }
    It 'rejects path traversal even when the archive digest matches' {
        $archive = Join-Path $TestDrive 'traversal.zip'
        $zip = [IO.Compression.ZipFile]::Open($archive, 'Create')
        try { $zip.CreateEntry('../escape.txt') | Out-Null } finally { $zip.Dispose() }
        $hash = (Get-FileHash $archive).Hash
        { Expand-VerifiedPowerShellArchive -Archive $archive -SHA256 $hash -Destination (Join-Path $TestDrive 'extract') } | Should Throw 'Unsafe'
        Test-Path (Join-Path $TestDrive 'escape.txt') | Should Be $false
    }
    It 'extracts a matching archive without replacing an existing destination' {
        $source = Join-Path $TestDrive 'source'
        New-Item -ItemType Directory $source | Out-Null
        Set-Content (Join-Path $source 'pwsh.exe') 'fixture'
        $archive = Join-Path $TestDrive 'good.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($source, $archive)
        $hash = (Get-FileHash $archive).Hash
        $destination = Join-Path $TestDrive 'good'
        Expand-VerifiedPowerShellArchive -Archive $archive -SHA256 $hash -Destination $destination
        Get-Content (Join-Path $destination 'pwsh.exe') | Should Be 'fixture'
        { Expand-VerifiedPowerShellArchive -Archive $archive -SHA256 $hash -Destination $destination } | Should Throw 'already exists'
    }
}

Describe 'Runtime selection and rollback' {
    BeforeEach {
        $runtimeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($version in @('7.6.6', '7.6.7')) {
            New-Item -ItemType Directory -Path (Join-Path $runtimeRoot "versions\$version") -Force | Out-Null
            Set-Content (Join-Path $runtimeRoot "versions\$version\pwsh.exe") 'fixture'
        }
        Mock Test-ManagedPowerShell {} -ModuleName PowerShellRuntime
        Mock Test-ManagedPowerShell {} -ModuleName PowerShellRuntime -ParameterFilter { $Executable -like '*\7\pwsh.exe' }
    }
    AfterEach {
        foreach ($name in @('7', 'previous', 'pending')) {
            $link = Join-Path $runtimeRoot $name
            if ((Test-Path -LiteralPath $link) -and (Get-Item -LiteralPath $link -Force).LinkType -eq 'Junction') {
                [IO.Directory]::Delete($link)
            }
        }
    }
    It 'selects a version and retains the old runtime during an upgrade' {
        Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.6'
        Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.7'
        @((Get-Item (Join-Path $runtimeRoot '7') -Force).Target)[0] | Should Be (Join-Path $runtimeRoot 'versions\7.6.7')
        @((Get-Item (Join-Path $runtimeRoot 'previous') -Force).Target)[0] | Should Be (Join-Path $runtimeRoot 'versions\7.6.6')
        Test-Path (Join-Path $runtimeRoot 'versions\7.6.6\pwsh.exe') | Should Be $true
    }
    It 'leaves the current link unchanged when preflight fails' {
        Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.6'
        Mock Test-ManagedPowerShell { throw 'bad candidate' } -ModuleName PowerShellRuntime
        { Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.7' } | Should Throw 'bad candidate'
        @((Get-Item (Join-Path $runtimeRoot '7') -Force).Target)[0] | Should Be (Join-Path $runtimeRoot 'versions\7.6.6')
    }
    It 'restores the old junction when verification through the fixed path fails' {
        Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.6'
        Mock Test-ManagedPowerShell { throw 'fixed path failed' } -ModuleName PowerShellRuntime -ParameterFilter { $Executable -like '*\7\pwsh.exe' }
        { Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.7' } | Should Throw 'fixed path failed'
        @((Get-Item (Join-Path $runtimeRoot '7') -Force).Target)[0] | Should Be (Join-Path $runtimeRoot 'versions\7.6.6')
        Test-Path (Join-Path $runtimeRoot 'pending') | Should Be $false
    }
    It 'supports selecting the retained version again' {
        Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.6'
        Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.7'
        Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.6'
        @((Get-Item (Join-Path $runtimeRoot '7') -Force).Target)[0] | Should Be (Join-Path $runtimeRoot 'versions\7.6.6')
        @((Get-Item (Join-Path $runtimeRoot 'previous') -Force).Target)[0] | Should Be (Join-Path $runtimeRoot 'versions\7.6.7')
    }
    It 'refuses to replace an ordinary directory' {
        New-Item -ItemType Directory (Join-Path $runtimeRoot '7') | Out-Null
        { Set-ManagedPowerShellVersion -Root $runtimeRoot -Version '7.6.7' } | Should Throw 'owned version junction'
    }
}

Describe 'Signed runtime launch' {
    It 'starts the real runtime and imports Task Scheduler without profiles' {
        Test-ManagedPowerShell -Executable (Join-Path $PSHOME 'pwsh.exe') -Version $PSVersionTable.PSVersion.ToString()
    }
    It 'rejects an unsigned executable' {
        $file = Join-Path $TestDrive 'pwsh.exe'
        Set-Content $file 'unsigned'
        { Test-ManagedPowerShell -Executable $file -Version '7.6.7' } | Should Throw 'signature'
    }
    It 'rejects a runtime that reports a different version' {
        { Test-ManagedPowerShell -Executable (Join-Path $PSHOME 'pwsh.exe') -Version '7.0.0' } | Should Throw 'verification failed'
    }
}

Describe 'Expanded runtime smoke checks' {
    function Invoke-SmokeScript([string]$Script) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded 2>$null
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = [string]::Join('', @($output)) }
    }
    It 'prints the exact runtime version from the smoke script' {
        $result = Invoke-SmokeScript (Get-ManagedPowerShellSmokeScript)
        $result.ExitCode | Should Be 0
        $result.Output | Should Be $PSVersionTable.PSVersion.ToString()
    }
    It 'fails when ScheduledTasks cannot be imported' {
        $script = (Get-ManagedPowerShellSmokeScript).Replace('Import-Module ScheduledTasks', 'Import-Module NoSuchModule.Fixture')
        (Invoke-SmokeScript $script).ExitCode | Should Not Be 0
    }
    It 'fails when CimCmdlets cannot be imported' {
        $script = (Get-ManagedPowerShellSmokeScript).Replace('Import-Module CimCmdlets', 'Import-Module NoSuchModule.Fixture')
        (Invoke-SmokeScript $script).ExitCode | Should Not Be 0
    }
    It 'keeps the exact JSON timestamp string check in the script' {
        Get-ManagedPowerShellSmokeScript | Should Match 'ConvertFrom-Json .*-DateKind String'
        Get-ManagedPowerShellSmokeScript | Should Match '2026-10-31T01:28:20\.1839545-07:00'
    }
}

Describe 'Runtime switch lock and market-hours fencing' {
    BeforeEach {
        $lockFolder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $lockFolder | Out-Null
        $lockPath = Join-Path $lockFolder 'deployment.lock'
        # 2026-11-28 is a Saturday; 2026-11-24 is a Tuesday (EST); 2026-07-14 is a Tuesday (EDT).
        $saturdayAfternoon = [datetime]'2026-11-28T15:00:00Z'
    }
    It 'allows a switch when no lock file exists and the market is closed' {
        { Test-ManagedPowerShellLockSafety -LockPath @($lockPath) -UtcNow $saturdayAfternoon } | Should Not Throw
    }
    It 'refuses a switch while a deployment lock is held exclusively' {
        Set-Content -LiteralPath $lockPath 'held'
        $held = [IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None')
        try {
            { Test-ManagedPowerShellLockSafety -LockPath @($lockPath) -UtcNow $saturdayAfternoon } | Should Throw 'lock is held'
        } finally { $held.Dispose() }
        { Test-ManagedPowerShellLockSafety -LockPath @($lockPath) -UtcNow $saturdayAfternoon } | Should Not Throw
    }
    It 'refuses a switch during Eastern market hours on a weekday' {
        { Test-ManagedPowerShellLockSafety -LockPath @() -UtcNow ([datetime]'2026-11-24T14:30:00Z') } | Should Throw 'market hours'
        { Test-ManagedPowerShellLockSafety -LockPath @() -UtcNow ([datetime]'2026-07-14T13:30:00Z') } | Should Throw 'market hours'
    }
    It 'uses the Eastern boundaries from 09:30 inclusive to 16:00 exclusive' {
        { Test-ManagedPowerShellLockSafety -LockPath @() -UtcNow ([datetime]'2026-11-24T14:29:00Z') } | Should Not Throw
        { Test-ManagedPowerShellLockSafety -LockPath @() -UtcNow ([datetime]'2026-11-24T21:00:00Z') } | Should Not Throw
    }
    It 'allows a switch on weekends and during market hours when -AllowMarketHours is given' {
        { Test-ManagedPowerShellLockSafety -LockPath @() -UtcNow $saturdayAfternoon } | Should Not Throw
        { Test-ManagedPowerShellLockSafety -LockPath @() -UtcNow ([datetime]'2026-11-24T15:00:00Z') -AllowMarketHours } | Should Not Throw
    }
}

Describe 'Runtime switch lock fence' {
    # Returns $true when another open of the path is refused. Pester's Should Throw does not catch .NET exceptions thrown in a scriptblock, so this is checked directly.
    function Test-LockOpenRefused([string]$Path) {
        try { $handle = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); $handle.Dispose(); return $false }
        catch [IO.IOException] { return $true }
    }
    BeforeEach {
        $fenceFolder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $fenceFolder | Out-Null
        $fenceLock = Join-Path $fenceFolder 'deployment.lock'
        $fenceSaturday = [datetime]'2026-11-28T15:00:00Z'
    }
    It 'keeps the lock held until the fence is exited' {
        $fence = Enter-ManagedPowerShellLockFence -LockPath @($fenceLock) -UtcNow $fenceSaturday
        try {
            @($fence).Count | Should Be 1
            Test-LockOpenRefused $fenceLock | Should Be $true
            { Test-ManagedPowerShellLockSafety -LockPath @($fenceLock) -UtcNow $fenceSaturday } | Should Throw 'lock is held'
        } finally { Exit-ManagedPowerShellLockFence -Fence $fence }
        Test-LockOpenRefused $fenceLock | Should Be $false
    }
    It 'creates a missing lock file so a later deployment cannot slip past the fence' {
        Test-Path -LiteralPath $fenceLock | Should Be $false
        $fence = Enter-ManagedPowerShellLockFence -LockPath @($fenceLock) -UtcNow $fenceSaturday
        try {
            Test-Path -LiteralPath $fenceLock | Should Be $true
            Test-LockOpenRefused $fenceLock | Should Be $true
        } finally { Exit-ManagedPowerShellLockFence -Fence $fence }
    }
    It 'releases already-acquired locks when a later lock is held' {
        $second = Join-Path $fenceFolder 'backup.lock'
        $heldElsewhere = [IO.File]::Open($second, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            { Enter-ManagedPowerShellLockFence -LockPath @($fenceLock, $second) -UtcNow $fenceSaturday } | Should Throw 'lock is held'
        } finally { $heldElsewhere.Dispose() }
        Test-LockOpenRefused $fenceLock | Should Be $false
    }
    It 'fences the host executor lock so a runtime switch waits for active Stage operations' {
        $paths = & (Get-Module PowerShellRuntime) { param($apps, $backup, $exec) @(Get-DeploymentLockPaths -AppsRoot $apps -BackupLock $backup -ExecutionLock $exec) } (Join-Path $TestDrive 'no-apps') 'backup.lock' 'control\execution.lock'
        ($paths -contains 'control\execution.lock') | Should Be $true
        $default = & (Get-Module PowerShellRuntime) { @(Get-DeploymentLockPaths -AppsRoot (Join-Path $TestDrive 'no-apps')) }
        @($default | Where-Object { $_ -like '*\SolutionDeploy\control\execution.lock' }).Count | Should Be 1
    }
    It 'refuses the switch while the execution lock is held by a Stage operation' {
        $executionLock = Join-Path $fenceFolder 'execution.lock'
        $held = [IO.File]::Open($executionLock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            { Enter-ManagedPowerShellLockFence -LockPath @($fenceLock, $executionLock) -UtcNow $fenceSaturday } | Should Throw 'lock is held'
        } finally { $held.Dispose() }
        Test-LockOpenRefused $fenceLock | Should Be $false
    }

    It 'refuses during market hours before taking any lock' {
        { Enter-ManagedPowerShellLockFence -LockPath @($fenceLock) -UtcNow ([datetime]'2026-11-24T15:00:00Z') } | Should Throw 'market hours'
        Test-Path -LiteralPath $fenceLock | Should Be $false
    }
}

