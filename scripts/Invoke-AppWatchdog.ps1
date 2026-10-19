#Requires -Version 7.5
<#
.SYNOPSIS
One watchdog pass for one app. The scheduled task runs this as the app's dedicated account at startup and on repeat.

.DESCRIPTION
Loads the manifest from the release (or AppRoot\state). Without -RuntimePath it resolves the runtime from the
active release's release.json on every pass, so a task pointed at AppRoot\current follows Deploy/Rollback. Then calls Invoke-AppWatchdog. It respects the maintenance
flag and the per-app lock, starts the app only when no verified process owns it, and never stops a process.
Appends one JSON line per pass to shared\logs\watchdog.log. Exit code 0 means Healthy, AlreadyRunning, Started,
or Skipped; 1 means Unhealthy or Failed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppRoot,
    [Parameter(Mandatory)][string]$ReleasePath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$RuntimePath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Lifecycle.psm1') -Force

try {
    $manifest = Read-LifecycleManifest -Path $ManifestPath -AppRoot $AppRoot -ReleasePath $ReleasePath
    if (-not $RuntimePath) { $RuntimePath = Get-ReleaseRuntimePath -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $manifest }
    $result = Invoke-AppWatchdog -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $manifest -RuntimePath $RuntimePath
}
catch {
    $result = [pscustomobject]@{ AppId = $null; Status = 'Failed'; Reason = $_.Exception.Message; Pid = $null; Ready = $false; AtUtc = [datetime]::UtcNow.ToString('o') }
}

$line = $result | ConvertTo-Json -Compress
try {
    $logs = (Get-AppLayout -AppRoot $AppRoot).Logs
    if ((Test-Path -LiteralPath $logs -PathType Container) -and -not ((Get-Item -LiteralPath $logs -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $log = Join-Path $logs 'watchdog.log'
        if ((Test-Path -LiteralPath $log -PathType Leaf) -and (Get-Item -LiteralPath $log -Force).Length -gt 1MB) {
            [IO.File]::Move($log, (Join-Path $logs 'watchdog.previous.log'), $true)
        }
        [IO.File]::AppendAllText($log, $line + [Environment]::NewLine)
    }
}
catch { Write-Warning "Could not write watchdog log: $($_.Exception.Message)" }

Write-Output $line
if ($result.Status -in @('Healthy', 'AlreadyRunning', 'Started', 'Skipped')) { exit 0 }
exit 1
