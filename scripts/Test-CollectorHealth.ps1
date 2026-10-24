#Requires -Version 7.5
[CmdletBinding()]
param(
    [string]$SnapshotPath = 'C:\ProgramData\SolutionDeploy\apps\solution-deploy\data\collector-status.json',
    [string]$StatePath = 'C:\ProgramData\SolutionDeploy\monitor\state.json',
    [string]$AlertScript = 'C:\ProgramData\JimlerTech\PostgreSQL\Send-BackupAlert.ps1',
    [switch]$EvaluateOnly
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\CollectorMonitor.psm1') -Force
$names = @(
    'SolutionDeploy-collector-status',
    'SolutionDeploy-web-options-collector',
    'SolutionDeploy-web-options-collector-watchdog',
    'SolutionDeploy-web-options-daily-audit',
    'SolutionDeploy-web-portfolio-stock-collector',
    'SolutionDeploy-web-portfolio-stock-watchdog',
    'SolutionDeploy-web-portfolio-reference-earnings',
    'SolutionDeploy-web-portfolio-reference-indices',
    'SolutionDeploy-web-portfolio-reference-splits',
    'SolutionDeploy-web-portfolio-daily-audit'
)
$issues = @()
try {
    $registered = @(Get-ScheduledTask -TaskPath '\JimlerTech\' -ErrorAction Stop)
    $tasks = @(
        foreach ($name in $names) {
            $task = @($registered | Where-Object TaskName -EQ $name)
            if (-not $task.Count) {
                [pscustomobject]@{ Name = $name; Exists = $false }
                continue
            }
            $info = Get-ScheduledTaskInfo -InputObject $task[0] -ErrorAction Stop
            [pscustomobject]@{
                Name = $name; Exists = $true; State = [string]$task[0].State
                Result = $info.LastTaskResult; LastRun = $info.LastRunTime
                Daily = $name.EndsWith('-daily-audit')
            }
        }
    )
    $snapshot = $null
    $snapshotError = ''
    try { $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { $snapshotError = $_.Exception.Message }
    $issues = @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -SnapshotError $snapshotError)
}
catch {
    $issues = @("Collector monitor check failed: $($_.Exception.Message)")
}
if ($EvaluateOnly) {
    [pscustomobject]@{ checkedLocal = (Get-Date).ToString('o'); issues = $issues } | ConvertTo-Json -Depth 4
    return
}
$previous = $null
if (Test-Path -LiteralPath $StatePath) {
    try {
        $previous = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in @('fingerprint', 'lastNotificationLocal')) {
            if ($null -eq $previous -or -not $previous.PSObject.Properties[$property]) {
                throw 'Notification state is missing required properties.'
            }
        }
    }
    catch {
        $previous = $null
        $issues += 'Collector monitor notification state is unreadable; it will be replaced after successful alert delivery.'
        Write-Warning "Notification state could not be read: $($_.Exception.Message)"
    }
}
$fingerprint = (@($issues | Sort-Object) -join "`n")
$lastNotification = if ($previous) { $previous.lastNotificationLocal } else { $null }
$changed = $null -eq $previous -or $previous.fingerprint -cne $fingerprint
$remind = $issues.Count -and (-not $lastNotification -or
    [datetimeoffset]::Now - [datetimeoffset]$lastNotification -gt [timespan]::FromHours(24))
if (($issues.Count -and ($changed -or $remind)) -or
    (-not $issues.Count -and $previous -and $previous.fingerprint)) {
    $title = if ($issues.Count) { 'Market collectors need attention' } else { 'Market collectors recovered' }
    $message = if ($issues.Count) { $issues -join "`n" } else { 'Task schedules, snapshot, heartbeats and latest audit sections are healthy.' }
    $global:LASTEXITCODE = 0
    & $AlertScript -Title $title -Message $message
    if (-not $? -or $LASTEXITCODE -ne 0) { throw 'Collector alert delivery failed.' }
    $lastNotification = (Get-Date).ToString('o')
}
$record = [ordered]@{
    checkedLocal = (Get-Date).ToString('o')
    fingerprint = $fingerprint
    issues = $issues
    lastNotificationLocal = $lastNotification
}
$temp = "$StatePath.$PID.tmp"
try {
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temp -Encoding utf8NoBOM
    Move-Item -LiteralPath $temp -Destination $StatePath -Force
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
}
$record | ConvertTo-Json -Depth 4
if ($issues.Count) { exit 1 }
