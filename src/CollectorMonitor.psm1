Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-OptionsAuditTaskRecovery {
    param($Report, $Task, [datetimeoffset]$Now)
    if ($null -eq $Report) { return $false }
    foreach ($property in @('date', 'status', 'notification_sent', 'generated_at_local', 'sections')) {
        if (-not $Report.PSObject.Properties[$property]) { return $false }
    }
    if ($Report.status -ne 'pass' -or $Report.notification_sent -isnot [bool] -or
        -not $Report.notification_sent -or $null -eq $Report.sections) { return $false }
    $lastRun = [datetimeoffset]$Task.LastRun
    if ([string]$Report.date -ne $lastRun.ToString('yyyy-MM-dd')) { return $false }
    $generated = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Report.generated_at_local, [ref]$generated) -or
        $generated -le $lastRun -or $generated -gt $Now.AddMinutes(2) -or
        $Now - $generated -gt [timespan]::FromHours(26)) { return $false }
    foreach ($name in @('vader', 'portfolio', 'coverage')) {
        if (-not $Report.sections.PSObject.Properties[$name]) { return $false }
    }
    foreach ($section in $Report.sections.PSObject.Properties) {
        if ($null -eq $section.Value -or -not $section.Value.PSObject.Properties['status'] -or
            $section.Value.status -notin @('pass', 'not_run')) { return $false }
    }
    return $true
}

function Get-CollectorMonitorIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Tasks,
        [AllowNull()]$Snapshot,
        [AllowNull()]$OptionsAuditReport,
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
        # 267011: registered but not yet run, as after a reinstall. Heartbeat and audit-age checks cover a task that never starts.
        if ($result -eq 267011) { continue }
        # 2147946720 (0x800710E0): a trigger skipped because the previous run was still going (IgnoreNew).
        # A run that stays stuck is caught by the overdue and heartbeat checks.
        $recoveredAudit = $name -eq 'SolutionDeploy-web-options-daily-audit' -and
            $task.State -eq 'Ready' -and (Test-OptionsAuditTaskRecovery $OptionsAuditReport $task $Now)
        if ($result -notin @(0, 267009, 2147946720) -and -not $recoveredAudit) {
            $label = switch ($name) {
                'SolutionDeploy-web-portfolio-stock-watchdog' { 'Stock collector health check' }
                'SolutionDeploy-web-options-collector-watchdog' { 'Options collector health check' }
                'SolutionDeploy-web-portfolio-stock-collector' { 'Stock price collection' }
                'SolutionDeploy-web-options-collector' { 'Option quote collection' }
                'SolutionDeploy-web-portfolio-reference-earnings' { 'Earnings date collection' }
                'SolutionDeploy-web-portfolio-reference-indices' { 'Index price collection' }
                'SolutionDeploy-web-portfolio-reference-splits' { 'Stock split collection' }
                'SolutionDeploy-web-portfolio-daily-audit' { 'Stock nightly audit' }
                'SolutionDeploy-web-options-daily-audit' { 'Options nightly audit' }
                default { $name }
            }
            $guidance = if ($name -like '*watchdog') {
                'The check could not finish successfully; this does not by itself mean collected prices are wrong. Check the collector watchdog log for the cause.'
            }
            else {
                'The scheduled job could not finish successfully. Check its collector log for the cause; collected data may be incomplete.'
            }
            $issues.Add("$label failed. $guidance Technical details: task $name; exit code $result.")
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
                $expectedSkip = $job -eq 'options-audit' -and $row.status -eq 'not_run' -and
                    $row.PSObject.Properties['reportStatus'] -and $row.reportStatus -eq 'pass'
                if ($expectedSkip) { continue }
                if (-not $row.informational -and $row.status -ne 'pass') {
                    $issues.Add("$job section $($row.subject) reports $($row.status).")
                }
            }
        }
    }
    return $issues.ToArray()
}

Export-ModuleMember -Function Get-CollectorMonitorIssue
