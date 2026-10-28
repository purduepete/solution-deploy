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

$script:TaskLogs = @{
    'SolutionDeploy-web-options-collector'            = 'web-options\shared\logs\collector-tick.log'
    'SolutionDeploy-web-options-collector-watchdog'   = 'web-options\shared\logs\collector-watchdog.log'
    'SolutionDeploy-web-options-daily-audit'          = 'web-options\shared\logs\collector-audit.log'
    'SolutionDeploy-web-portfolio-stock-collector'    = 'web-portfolio\shared\logs\stock-collector-tick.log'
    'SolutionDeploy-web-portfolio-stock-watchdog'     = 'web-portfolio\shared\logs\stock-collector-watchdog.log'
    'SolutionDeploy-web-portfolio-reference-earnings' = 'web-portfolio\shared\logs\stock-reference-earnings.log'
    'SolutionDeploy-web-portfolio-reference-indices'  = 'web-portfolio\shared\logs\stock-reference-indices.log'
    'SolutionDeploy-web-portfolio-reference-splits'   = 'web-portfolio\shared\logs\stock-reference-splits.log'
    'SolutionDeploy-web-portfolio-daily-audit'        = 'web-portfolio\shared\logs\stock-collector-audit.log'
}

function Protect-CollectorLogLine([string]$Line) {
    $Line = $Line -replace '(?i)\b(password|passwd|pwd|token|secret|api[_-]?key|authorization)(\s*[=:]\s*)("[^"]*"|''[^'']*''|\S+)', '$1$2[redacted]'
    $Line = $Line -replace '(?i)\bBearer\s+\S+', 'Bearer [redacted]'
    $Line = $Line -replace '(?i)\b([a-z][a-z0-9+.-]*)://[^\s/@]+@', '$1://[redacted]@'
    if ($Line.Length -gt 400) { $Line = $Line.Substring(0, 400) + ' ...' }
    return $Line
}

function Read-CollectorTaskLog {
    <#
    .SYNOPSIS
    Returns the log lines written by a task's last run and a one-line plain cause.
    Python collectors stamp each line; untimestamped logs (the audits) return their last lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][Nullable[datetime]]$Since,
        [int]$MaxLines = 25,
        [int]$TailBytes = 262144
    )
    $result = [pscustomobject]@{ Path = $Path; Lines = @(); Cause = '' }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $start = [Math]::Max(0, $stream.Length - $TailBytes)
        [void]$stream.Seek($start, 'Begin')
        $text = [IO.StreamReader]::new($stream).ReadToEnd()
    }
    finally { $stream.Dispose() }
    $raw = @($text -split '\r?\n')
    if ($start -gt 0) { $raw = @($raw | Select-Object -Skip 1) }
    $stampPattern = '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ (\w+) (.*)$'
    $kept = [Collections.Generic.List[string]]::new()
    if ($null -ne $Since -and @($raw -match $stampPattern).Count) {
        # Each collector run opens with a "local time" line, so the run ends at the next one.
        # A first match well after Since means that run is no longer in the log tail.
        $from = ([datetime]$Since).AddSeconds(-1)
        $latestStart = ([datetime]$Since).AddMinutes(2)
        $inRun = $false
        foreach ($line in $raw) {
            if ($line -match $stampPattern) {
                $message = $Matches[3]
                $isRunStart = $message -like 'local time *'
                if (-not $inRun) {
                    $stamp = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                    if ($stamp -lt $from) { continue }
                    if ($stamp -gt $latestStart) { break }
                    $inRun = $true
                }
                elseif ($isRunStart) { break }
                if ($isRunStart -or $message -like 'HTTP Request:*') { continue }
            }
            if ($inRun -and $line.Trim()) { $kept.Add((Protect-CollectorLogLine $line)) }
        }
    }
    else {
        foreach ($line in @($raw | Where-Object { $_.Trim() } | Select-Object -Last $MaxLines)) {
            $kept.Add((Protect-CollectorLogLine $line))
        }
    }
    $result.Lines = @($kept | Select-Object -Last $MaxLines)
    $message = { param($pattern) for ($i = $kept.Count - 1; $i -ge 0; $i--) { if ($kept[$i] -match $pattern) { return $Matches['m'] } } }
    $reason = & $message '^\S+ \S+ \w+ unhealthy: (?<m>.*)$'
    if (-not $reason) { $reason = & $message '^\S+ \S+ (ERROR|CRITICAL) (?<m>.*)$' }
    if (-not $reason) { $reason = & $message '^\S+ \S+ WARNING (?<m>.*)$' }
    if (-not $reason) { $reason = & $message '^(?<m>([\w.]+\.)?\w*(Error|Exception)\b.*)$' }
    if (-not $reason) {
        $sections = @($kept | Where-Object { $_ -match '^\w+: (fail|error)\b' } | ForEach-Object { ($_ -split ':')[0] })
        if ($sections.Count) { $reason = "audit section $($sections -join ', ') failed" }
    }
    $outcome = ''
    for ($i = $kept.Count - 1; $i -ge 0; $i--) {
        if ($kept[$i] -match 'run=\d+ kind=(?<kind>\w+) (?<json>\{.*\})') {
            try {
                $run = $Matches['json'] | ConvertFrom-Json -ErrorAction Stop
                if ($run.status -ne 'complete') {
                    $outcome = "$($Matches['kind']) run $($run.status)"
                    if ($null -ne $run.expected -and $null -ne $run.price) { $outcome += ", $($run.price) of $($run.expected) prices" }
                }
            }
            catch { $outcome = '' }
            break
        }
    }
    $cause = (@($reason, $outcome) | Where-Object { $_ }) -join '; '
    if ($cause.Length -gt 300) { $cause = $cause.Substring(0, 300) + ' ...' }
    $result.Cause = $cause
    return $result
}

function Add-CollectorIssueLog {
    <#
    .SYNOPSIS
    Fills cause, logPath and log on task-failure issue details from the task's own log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Details,
        [Parameter(Mandatory)][string]$AppsRoot
    )
    foreach ($detail in $Details) {
        if (-not $detail.task -or -not $detail.exitCode -or -not $script:TaskLogs.ContainsKey($detail.task)) { continue }
        $path = Join-Path $AppsRoot $script:TaskLogs[$detail.task]
        try {
            $since = if ($detail.lastRun) { [Nullable[datetime]]([datetimeoffset]$detail.lastRun).LocalDateTime } else { $null }
            $log = Read-CollectorTaskLog -Path $path -Since $since
            $detail.logPath = $path
            $detail.log = @($log.Lines)
            $detail.cause = $log.Cause
        }
        catch { $detail.cause = "Log could not be read: $($_.Exception.Message)" }
        $detail.summary = if ($detail.cause) { "$($detail.label) failed: $($detail.cause)" } else { $detail.text }
    }
}

function Get-CollectorMonitorIssue {
    <#
    .SYNOPSIS
    Returns issue text lines, or with -Detail one object per issue (text, summary, meaning, task, exit code, log fields).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Tasks,
        [AllowNull()]$Snapshot,
        [AllowNull()]$OptionsAuditReport,
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        [string]$SnapshotError,
        [int]$SnapshotMaxAgeMinutes = 12,
        [int]$HeartbeatMaxAgeMinutes = 10,
        [switch]$Detail
    )
    $issues = [Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Text, [string]$Meaning, $Task, $Label, $ExitCode)
        $issues.Add([pscustomobject][ordered]@{
                text = $Text; summary = $Text; label = $Label; meaning = $Meaning
                task = if ($Task) { [string]$Task.Name } else { $null }
                exitCode = $ExitCode
                lastRun = if ($Task -and $Task.PSObject.Properties['LastRun'] -and $Task.LastRun) { ([datetimeoffset]$Task.LastRun).ToString('o') } else { $null }
                cause = ''; logPath = $null; log = @()
            })
    }
    foreach ($task in $Tasks) {
        $name = [string]$task.Name
        if (-not $task.Exists) { & $add "$name is missing." 'The scheduled task is not registered, so this job does not run at all. Reinstall the component that owns it.' $task; continue }
        if ($task.State -eq 'Disabled') { & $add "$name is disabled." 'The scheduled task is registered but disabled, so this job does not run. Enable it in Task Scheduler if that was not intended.' $task; continue }
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
                'The health check found a problem with the collector, or could not finish. This does not by itself mean collected prices are wrong; the cause and log lines show which.'
            }
            elseif ($name -like '*daily-audit') {
                'The nightly audit did not pass or could not finish. Collected data is unchanged; the audit compares it with the source and reports differences.'
            }
            else {
                'The scheduled run did not finish cleanly, so data for that slot may be incomplete. The collector retries missing items on its next run while the slot is still open.'
            }
            & $add "$label failed (exit code $result)." $guidance $task $label $result
        }
        if ($task.Daily) {
            if ($Now - [datetimeoffset]$task.LastRun -gt [timespan]::FromHours(26)) {
                & $add "$name daily run is overdue." 'The task has not run in over 26 hours. Check that it is enabled and that the host was up at its scheduled time.' $task
            }
        }
        elseif ($Now - [datetimeoffset]$task.LastRun -gt [timespan]::FromMinutes(10)) {
            & $add "$name minute schedule is overdue." 'The task normally runs every minute and has not run in over 10 minutes. A run may be stuck, or Task Scheduler stopped triggering it.' $task
        }
    }
    if ($SnapshotError) {
        & $add "Collector snapshot cannot be read: $SnapshotError" 'The Collectors page data file could not be read, so job health below could not be checked.'
    }
    elseif ($null -eq $Snapshot) {
        & $add 'Collector snapshot is missing.' 'The SolutionDeploy-collector-status task has not written the Collectors page data file.'
    }
    else {
        if ($Snapshot.schemaVersion -ne 1) { & $add 'Collector snapshot schema is unsupported.' }
        if ($Now - [datetimeoffset]$Snapshot.generatedAt -gt [timespan]::FromMinutes($SnapshotMaxAgeMinutes) -or
            [datetimeoffset]$Snapshot.generatedAt -gt $Now.AddMinutes(2)) {
            & $add 'Collector snapshot timestamp is stale or in the future.' 'The SolutionDeploy-collector-status task is not refreshing the Collectors page data, so the page shows old results.'
        }
        if (@($Snapshot.errors).Count) {
            & $add 'Collector snapshot publisher reports errors; inspect the protected snapshot on the host.' "Snapshot errors: $(@($Snapshot.errors) -join '; ')"
        }
        foreach ($job in @('stock-prices', 'earnings', 'indices', 'splits', 'option-quotes')) {
            $health = @($Snapshot.health | Where-Object job -EQ $job)
            if ($health.Count -ne 1 -or -not $health[0].heartbeatAt) {
                & $add "$job heartbeat is missing." 'The collector has no heartbeat row in its database, so it has not completed a run that records health.'
                continue
            }
            if ($Now - [datetimeoffset]$health[0].heartbeatAt -gt [timespan]::FromMinutes($HeartbeatMaxAgeMinutes) -or
                [datetimeoffset]$health[0].heartbeatAt -gt $Now.AddMinutes(2)) {
                & $add "$job heartbeat is stale or in the future." "The collector's last heartbeat was $($health[0].heartbeatAt). Each run updates it, so runs are failing before they finish or have stopped."
            }
        }
        foreach ($job in @('stock-audit', 'options-audit')) {
            $rows = @($Snapshot.audits | Where-Object job -EQ $job)
            if (-not $rows.Count) { & $add "$job has no audit report." 'No audit report file was found in the last 30 days.'; continue }
            $latest = @($rows | Sort-Object writtenAt -Descending)[0]
            if ($Now - [datetimeoffset]$latest.writtenAt -gt [timespan]::FromHours(26)) {
                & $add "$job report is overdue." "The latest audit report was written $($latest.writtenAt); a new one is expected every night at 23:30."
            }
            foreach ($row in @($rows | Where-Object date -EQ $latest.date)) {
                $expectedSkip = $job -eq 'options-audit' -and $row.status -eq 'not_run' -and
                    $row.PSObject.Properties['reportStatus'] -and $row.reportStatus -eq 'pass'
                if ($expectedSkip) { continue }
                if (-not $row.informational -and $row.status -ne 'pass') {
                    $why = if ($row.PSObject.Properties['error'] -and $row.error) { " Error: $($row.error)" } else { '' }
                    & $add "$job section $($row.subject) reports $($row.status)." "The $($latest.date) audit compared the $($row.subject) data with its source and it did not pass.$why"
                }
            }
        }
    }
    if ($Detail) { return $issues.ToArray() }
    return [string[]]@($issues | ForEach-Object text)
}

Export-ModuleMember -Function Get-CollectorMonitorIssue, Add-CollectorIssueLog, Read-CollectorTaskLog
