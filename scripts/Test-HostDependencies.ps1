#requires -Version 7.5
<#
.SYNOPSIS
Read-only check of PostgreSQL, the managed PowerShell runtime and app health on jimbrownhome1.
Run before and after PostgreSQL or PowerShell updates. Exits 1 when any check fails.
.EXAMPLE
pwsh.exe -NoProfile -File .\scripts\Test-HostDependencies.ps1 -CheckSignature -CheckApps -ExpectedClusterId 7000000000000000000
#>
[CmdletBinding()]
param(
    [string]$ExpectedHostName = 'jimbrownhome1',
    [string]$ExpectedDataDirectory = 'D:\data\postgres',
    [string]$ExpectedClusterId = '',
    [string]$ControllerVersion = '',
    [ValidateRange(1, 720)][int]$LookbackHours = 24,
    [ValidateRange(1, 720)][int]$MaxBackupAgeHours = 36,
    [switch]$CheckSignature,
    [switch]$CheckApps,
    [string]$SitesPath = (Join-Path $PSScriptRoot '..\site\sites.json'),
    [string]$ReleasesPath = (Join-Path $PSScriptRoot '..\environments\releases.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\HostDependencies.psm1') -Force

$observationParameters = @{
    ExpectedHostName = $ExpectedHostName
    ExpectedDataDirectory = $ExpectedDataDirectory
    ExpectedClusterId = $ExpectedClusterId
    ControllerVersion = $ControllerVersion
    LookbackHours = $LookbackHours
    MaxBackupAgeHours = $MaxBackupAgeHours
    CheckSignature = $CheckSignature
    CheckApps = $CheckApps
    SitesPath = $SitesPath
    ReleasesPath = $ReleasesPath
}
$observations = Get-HostDependencyObservations @observationParameters
$report = Test-HostDependencyObservations -Observations $observations
$report
if ($report.status -ne 'Passed') {
    Write-Error "Host dependency check failed: $($report.failures.Count) failure(s)."
    exit 1
}
