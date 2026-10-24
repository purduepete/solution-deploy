Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CollectorMonitorIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Tasks,
        [AllowNull()]$Snapshot,
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        [string]$SnapshotError,
        [int]$SnapshotMaxAgeMinutes = 12,
        [int]$HeartbeatMaxAgeMinutes = 10
    )
    $issues = [Collections.Generic.List[string]]::new()
    foreach ($task in $Tasks) {
        $name = [string]$task.Name
        if (-not $task.Exists) { $issues.Add("$name is missing."); continue }
        if ($task.State -eq 'Disabled') { $issues.Add("$name is disabled."); continue }
        $result = [long]$task.Result
        if ($result -notin @(0, 267009)) {
            $issues.Add("$name last result is $result.")
        }
        if ($task.Daily) {
            if ($Now - [datetimeoffset]$task.LastRun -gt [timespan]::FromHours(26)) {
                $issues.Add("$name daily run is overdue.")
            }
        }
        elseif ($Now - [datetimeoffset]$task.LastRun -gt [timespan]::FromMinutes(10)) {
            $issues.Add("$name minute schedule is overdue.")
        }
    }
    if ($SnapshotError) {
        $issues.Add("Collector snapshot cannot be read: $SnapshotError")
    }
    elseif ($null -eq $Snapshot) {
        $issues.Add('Collector snapshot is missing.')
    }
    else {
        if ($Snapshot.schemaVersion -ne 1) { $issues.Add('Collector snapshot schema is unsupported.') }
        if ($Now - [datetimeoffset]$Snapshot.generatedAt -gt [timespan]::FromMinutes($SnapshotMaxAgeMinutes) -or
            [datetimeoffset]$Snapshot.generatedAt -gt $Now.AddMinutes(2)) {
            $issues.Add('Collector snapshot timestamp is stale or in the future.')
        }
        if (@($Snapshot.errors).Count) {
            $issues.Add('Collector snapshot publisher reports errors; inspect the protected snapshot on the host.')
        }
        foreach ($job in @('stock-prices', 'earnings', 'indices', 'splits', 'option-quotes')) {
            $health = @($Snapshot.health | Where-Object job -EQ $job)
            if ($health.Count -ne 1 -or -not $health[0].heartbeatAt) {
                $issues.Add("$job heartbeat is missing.")
                continue
            }
            if ($Now - [datetimeoffset]$health[0].heartbeatAt -gt [timespan]::FromMinutes($HeartbeatMaxAgeMinutes) -or
                [datetimeoffset]$health[0].heartbeatAt -gt $Now.AddMinutes(2)) {
                $issues.Add("$job heartbeat is stale or in the future.")
            }
        }
        foreach ($job in @('stock-audit', 'options-audit')) {
            $rows = @($Snapshot.audits | Where-Object job -EQ $job)
            if (-not $rows.Count) { $issues.Add("$job has no audit report."); continue }
            $latest = @($rows | Sort-Object writtenAt -Descending)[0]
            if ($Now - [datetimeoffset]$latest.writtenAt -gt [timespan]::FromHours(26)) {
                $issues.Add("$job report is overdue.")
            }
            foreach ($row in @($rows | Where-Object date -EQ $latest.date)) {
                if (-not $row.informational -and $row.status -ne 'pass') {
                    $issues.Add("$job section $($row.subject) reports $($row.status).")
                }
            }
        }
    }
    return $issues.ToArray()
}

Export-ModuleMember -Function Get-CollectorMonitorIssue
