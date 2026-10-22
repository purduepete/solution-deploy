#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Installs or updates the private deployment PowerShell runtime, independently of desktop PowerShell.
.EXAMPLE
powershell.exe -NoProfile -File C:\ProgramData\SolutionDeploy\runtime\powershell\management\scripts\Update-DeploymentPowerShell.ps1
.EXAMPLE
powershell.exe -NoProfile -File .\scripts\Update-DeploymentPowerShell.ps1 -Rollback
#>
[CmdletBinding(DefaultParameterSetName = 'Update')]
param(
    [Parameter(ParameterSetName = 'Update')][ValidatePattern('^7\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory, ParameterSetName = 'Rollback')][switch]$Rollback
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Import-Module (Join-Path $PSScriptRoot '..\src\PowerShellRuntime.psm1') -Force
$root = 'C:\ProgramData\SolutionDeploy\runtime\powershell'
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
if ($PSHOME.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Run this updater using Windows PowerShell (powershell.exe), outside the deployment runtime.'
}
[IO.Directory]::CreateDirectory($root) | Out-Null
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($entry in @(@('S-1-5-18','FullControl'), @('S-1-5-32-544','FullControl'), @('S-1-5-11','ReadAndExecute'))) {
    $sid = New-Object Security.Principal.SecurityIdentifier($entry[0])
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, $entry[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
Set-Acl -LiteralPath $root -AclObject $acl
$lock = $null
$archive = $null
$staging = $null
try {
    $lock = [IO.File]::Open((Join-Path $root 'update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    if ($Rollback) {
        $previous = Get-Item -LiteralPath (Join-Path $root 'previous') -Force
        if ($previous.LinkType -ne 'Junction') { throw 'Previous runtime is not a junction.' }
        $Version = Split-Path -Leaf @($previous.Target)[0]
    } else {
        $uri = 'https://api.github.com/repos/PowerShell/PowerShell/releases/'
        if ($Version) { $uri += "tags/v$Version" } else { $uri += 'latest' }
        Write-Host 'Reading the official PowerShell release (60-second timeout).'
        $release = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'SolutionDeploy' } -TimeoutSec 60
        $asset = Get-PowerShellReleaseAsset -Release $release
        $Version = $asset.Version
        $current = Join-Path $root '7'
        if (Test-Path -LiteralPath $current) {
            $installed = Split-Path -Leaf @((Get-Item -LiteralPath $current -Force).Target)[0]
            if ([version]$Version -lt [version]$installed) { throw 'Downgrades require -Rollback to a retained, verified runtime.' }
        }
        $destination = Join-Path $root "versions\$Version"
        if (-not (Test-Path -LiteralPath $destination)) {
            $archive = Join-Path $root ($asset.Name + '.download')
            Write-Host "Downloading PowerShell $Version (180-second timeout)."
            Invoke-WebRequest -UseBasicParsing -Uri $asset.Url -OutFile $archive -TimeoutSec 180
            $staging = Join-Path $root ('staging-' + [guid]::NewGuid().ToString('N'))
            Expand-VerifiedPowerShellArchive -Archive $archive -SHA256 $asset.SHA256 -Destination $staging
            Test-ManagedPowerShell -Executable (Join-Path $staging 'pwsh.exe') -Version $Version
            [IO.Directory]::CreateDirectory((Join-Path $root 'versions')) | Out-Null
            Move-Item -LiteralPath $staging -Destination $destination
            $staging = $null
            @{ version = $Version; archiveSHA256 = $asset.SHA256; url = $asset.Url; verifiedLocal = (Get-Date).ToString('o') } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'deployment-runtime.json') -Encoding UTF8
        }
    }
    Write-Host "Verifying and selecting PowerShell $Version. Existing processes keep their retained runtime."
    Set-ManagedPowerShellVersion -Root $root -Version $Version
    [pscustomobject]@{ Version = $Version; Executable = Get-ManagedPowerShellPath; Previous = (Join-Path $root 'previous'); AutomaticUpdates = $false }
} finally {
    if ($archive -and (Test-Path -LiteralPath $archive)) { Remove-Item -LiteralPath $archive -Force }
    if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force }
    if ($lock) { $lock.Dispose() }
}
