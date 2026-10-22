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
}
