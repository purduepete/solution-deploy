#Requires -Version 7.5
[CmdletBinding()]
param(
    [string]$SnapshotPath = 'C:\ProgramData\SolutionDeploy\apps\solution-deploy\data\collector-status.json',
    [string]$AppsRoot = 'C:\ProgramData\SolutionDeploy\apps',
    [string]$StatePath = 'C:\ProgramData\SolutionDeploy\monitor\state.json',
    [string]$AlertScript = 'C:\ProgramData\JimlerTech\PostgreSQL\Send-BackupAlert.ps1',
    # Shown on the Collectors page; the LOCAL SERVICE snapshot builder can read this folder, not the monitor's.
    [string]$AlertLogPath = 'C:\ProgramData\SolutionDeploy\apps\solution-deploy\data\collector-alerts.json',
    [string]$MonitorPath = 'C:\ProgramData\SolutionDeploy\apps\solution-deploy\data\collector-monitor.json',
    [int]$AlertLogDays = 30,
    [switch]$EvaluateOnly
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\CollectorMonitor.psm1') -Force
$names = @(
    'SolutionDeploy-collector-status',
    'SolutionDeploy-web-options-collector',
    'SolutionDeploy-web-options-collector-watchdog',
    'SolutionDeploy-web-portfolio-stock-collector',
    'SolutionDeploy-web-portfolio-stock-watchdog',
    'SolutionDeploy-web-portfolio-reference-earnings',
    'SolutionDeploy-web-portfolio-reference-indices',
    'SolutionDeploy-web-portfolio-reference-splits'
)
$issues = @()
$summaries = @()
$details = @()
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
            }
        }
    )
    $snapshot = $null
    $snapshotError = ''
    try { $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { $snapshotError = $_.Exception.Message }
    $details = @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -SnapshotError $snapshotError -Detail)
    # Log reading only adds explanation; it must never hide the issue itself.
    try { Add-CollectorIssueLog -Details $details -AppsRoot $AppsRoot }
    catch { Write-Warning "Collector logs could not be read: $($_.Exception.Message)" }
}
catch {
    $details = @([pscustomobject]@{
            text = "Collector monitor check failed: $($_.Exception.Message)"
            summary = "Collector monitor check failed: $($_.Exception.Message)"
            meaning = 'The monitor itself could not finish its checks, so collector health is unknown until it succeeds.'
        })
}
# The fingerprint uses the stable text; summaries carry the cause, which can change minute to minute.
$issues = @($details | ForEach-Object text)
$summaries = @($details | ForEach-Object summary)
if ($EvaluateOnly) {
    [pscustomobject]@{ checkedLocal = (Get-Date).ToString('o'); issues = $issues; details = $details } | ConvertTo-Json -Depth 5
    return
}
$previous = $null
if (Test-Path -LiteralPath $StatePath) {
    try {
        $previous = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in @('fingerprint', 'issues', 'lastNotificationLocal')) {
            if ($null -eq $previous -or -not $previous.PSObject.Properties[$property]) {
                throw 'Notification state is missing required properties.'
            }
        }
    }
    catch {
        $previous = $null
        $stateIssue = 'Collector monitor notification state is unreadable; it will be replaced after successful alert delivery.'
        $issues += $stateIssue
        $summaries += $stateIssue
        $details += [pscustomobject]@{ text = $stateIssue; summary = $stateIssue; meaning = "State file: $StatePath" }
        Write-Warning "Notification state could not be read: $($_.Exception.Message)"
    }
}
$fingerprint = (@($issues | Sort-Object) -join "`n")
$lastNotification = if ($previous) { $previous.lastNotificationLocal } else { $null }
# Notify once when a problem opens and once when everything clears. An issue clearing while others stay
# open does not send again; the 24-hour reminder repeats open issues.
$previousIssues = if ($previous) { @($previous.issues) } else { @() }
$changed = $null -eq $previous -or @($issues | Where-Object { $_ -cnotin $previousIssues }).Count -gt 0
$remind = $issues.Count -and (-not $lastNotification -or
    [datetimeoffset]::Now - [datetimeoffset]$lastNotification -gt [timespan]::FromHours(24))
if (($issues.Count -and ($changed -or $remind)) -or
    (-not $issues.Count -and $previous -and $previous.fingerprint)) {
    $title = if ($issues.Count) { 'Market collectors need attention' } else { 'Market collectors recovered' }
    $message = if ($issues.Count) { $summaries -join "`n" } else { 'Task schedules, snapshot, heartbeats and collection runs are healthy.' }
    $global:LASTEXITCODE = 0
    & $AlertScript -Title $title -Message $message
    if (-not $? -or $LASTEXITCODE -ne 0) { throw 'Collector alert delivery failed.' }
    $lastNotification = (Get-Date).ToString('o')
    # History is a convenience copy; failing to write it must not stop alerting.
    try {
        $history = @()
        if (Test-Path -LiteralPath $AlertLogPath) {
            try { $history = @(Get-Content -LiteralPath $AlertLogPath -Raw | ConvertFrom-Json -ErrorAction Stop) }
            catch { Write-Warning "Alert history was unreadable and is being restarted: $($_.Exception.Message)" }
        }
        $since = [datetimeoffset]::Now.AddDays(-$AlertLogDays)
        $history = @($history | Where-Object { $_.sentAt -and [datetimeoffset]$_.sentAt -ge $since })
        $history += [ordered]@{
            sentAt = $lastNotification
            kind = if ($issues.Count) { 'alert' } else { 'recovered' }
            title = $title
            issues = @($summaries)
            details = @($details)
        }
        $historyTemp = "$AlertLogPath.$PID.tmp"
        ConvertTo-Json -InputObject @($history) -Depth 6 | Set-Content -LiteralPath $historyTemp -Encoding utf8NoBOM
        Move-Item -LiteralPath $historyTemp -Destination $AlertLogPath -Force
    }
    catch { Write-Warning "Alert history could not be written: $($_.Exception.Message)" }
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
# Current result for the Collectors page, which runs as LOCAL SERVICE and cannot read the state folder.
try {
    $monitorTemp = "$MonitorPath.$PID.tmp"
    [ordered]@{ checkedAt = $record.checkedLocal; details = @($details) } | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath $monitorTemp -Encoding utf8NoBOM
    Move-Item -LiteralPath $monitorTemp -Destination $MonitorPath -Force
}
catch { Write-Warning "Monitor result could not be written: $($_.Exception.Message)" }
if ($issues.Count) { exit 1 }
