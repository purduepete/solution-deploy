Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TaskLogs = @{
    'SolutionDeploy-web-options-collector'            = 'web-options\shared\logs\collector-tick.log'
    'SolutionDeploy-web-options-collector-watchdog'   = 'web-options\shared\logs\collector-watchdog.log'
    'SolutionDeploy-web-portfolio-stock-collector'    = 'web-portfolio\shared\logs\stock-collector-tick.log'
    'SolutionDeploy-web-portfolio-stock-watchdog'     = 'web-portfolio\shared\logs\stock-collector-watchdog.log'
    'SolutionDeploy-web-portfolio-reference-earnings' = 'web-portfolio\shared\logs\stock-reference-earnings.log'
    'SolutionDeploy-web-portfolio-reference-indices'  = 'web-portfolio\shared\logs\stock-reference-indices.log'
    'SolutionDeploy-web-portfolio-reference-splits'   = 'web-portfolio\shared\logs\stock-reference-splits.log'
}

# Data checks name the job; this maps each job to the task whose log explains a bad run.
$script:Jobs = [ordered]@{
    'stock-prices'  = @{ Name = 'Stock prices'; Task = 'SolutionDeploy-web-portfolio-stock-collector' }
    'option-quotes' = @{ Name = 'Option quotes'; Task = 'SolutionDeploy-web-options-collector' }
    'earnings'      = @{ Name = 'Earnings dates'; Task = 'SolutionDeploy-web-portfolio-reference-earnings' }
    'indices'       = @{ Name = 'Index closes'; Task = 'SolutionDeploy-web-portfolio-reference-indices' }
    'splits'        = @{ Name = 'Stock splits'; Task = 'SolutionDeploy-web-portfolio-reference-splits' }
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
    Python collectors stamp each line; an untimestamped log returns its last lines.
    With -Until, later ticks up to that time are kept, so a run retried until its deadline reports its final outcome.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][Nullable[datetime]]$Since,
        [AllowNull()][Nullable[datetime]]$Until,
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
                $stamp = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                if (-not $inRun) {
                    if ($stamp -lt $from) { continue }
                    if ($stamp -gt $latestStart) { break }
                    $inRun = $true
                }
                elseif ($isRunStart -and ($null -eq $Until -or $stamp -gt $Until)) { break }
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
    $outcome = ''
    # The final outcome is the last summary of the first run read; later ticks in the window may start other runs.
    $runId = foreach ($line in $kept) { if ($line -match 'run=(?<id>\d+) kind=\w+ \{') { $Matches['id']; break } }
    for ($i = $kept.Count - 1; $i -ge 0; $i--) {
        if ($kept[$i] -match 'run=(?<id>\d+) kind=(?<kind>\w+) (?<json>\{.*\})' -and $Matches['id'] -eq $runId) {
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
        if (-not $detail.task -or -not $detail.lastRun -or -not ($detail.exitCode -or $detail.job) -or
            -not $script:TaskLogs.ContainsKey($detail.task)) { continue }
        $path = Join-Path $AppsRoot $script:TaskLogs[$detail.task]
        try {
            $since = [Nullable[datetime]]([datetimeoffset]$detail.lastRun).LocalDateTime
            $until = if ($detail.deadline) { [Nullable[datetime]]([datetimeoffset]$detail.deadline).LocalDateTime } else { $null }
            $log = Read-CollectorTaskLog -Path $path -Since $since -Until $until
            $detail.logPath = $path
            $detail.log = @($log.Lines)
            $detail.cause = $log.Cause
        }
        catch { $detail.cause = "Log could not be read: $($_.Exception.Message)" }
        if ($detail.cause) { $detail.summary = "$($detail.label): $($detail.cause)" }
    }
}

function Get-CollectorMonitorIssue {
    <#
    .SYNOPSIS
    Returns issue text lines, or with -Detail one object per issue (text, summary, meaning, job, task, log fields).
    The text of each issue must stay the same while the problem lasts, because the notifier compares texts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Tasks,
        [AllowNull()]$Snapshot,
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        [string]$SnapshotError,
        [int]$SnapshotMaxAgeMinutes = 12,
        [int]$HeartbeatMaxAgeMinutes = 10,
        [int]$RunLookbackHours = 24,
        [switch]$Detail
    )
    $issues = [Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Text, [string]$Meaning, [hashtable]$Extra = @{})
        $issues.Add([pscustomobject][ordered]@{
                text = $Text; summary = $Text; label = $Extra['label']; meaning = $Meaning
                job = $Extra['job']; task = $Extra['task']; exitCode = $Extra['exitCode']; lastRun = $Extra['lastRun']
                deadline = $Extra['deadline']; cause = ''; logPath = $null; log = @()
            })
    }
    foreach ($task in $Tasks) {
        $name = [string]$task.Name
        if (-not $task.Exists) { & $add "$name is missing." 'The scheduled task is not registered, so this job does not run at all. Reinstall the component that owns it.' @{ task = $name }; continue }
        if ($task.State -eq 'Disabled') { & $add "$name is disabled." 'The scheduled task is registered but disabled, so this job does not run. Enable it in Task Scheduler if that was not intended.' @{ task = $name }; continue }
        $result = [long]$task.Result
        # 267011: registered but not yet run, as after a reinstall. The heartbeat checks cover a task that never starts.
        if ($result -eq 267011) { continue }
        # Collector ticks exit nonzero for a bad slot, which the run checks below report once with the data.
        # Only the publisher's exit code is checked. 2147946720 (0x800710E0) is a trigger skipped by IgnoreNew.
        if ($name -eq 'SolutionDeploy-collector-status' -and $result -notin @(0, 267009, 2147946720)) {
            & $add 'Collector status publisher failed.' "The last run exited with code $result, so the Collectors page and the run checks may be using old data." @{
                task = $name; label = 'Collector status publisher'; exitCode = $result
                lastRun = ([datetimeoffset]$task.LastRun).ToString('o')
            }
        }
        if ($Now - [datetimeoffset]$task.LastRun -gt [timespan]::FromMinutes(10)) {
            & $add "$name schedule is overdue." 'The task normally runs every few minutes and has not run in over 10 minutes. A run may be stuck, or Task Scheduler stopped triggering it.' @{ task = $name }
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
        foreach ($job in $script:Jobs.Keys) {
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

        # A run is judged only after its deadline, when the collector has stopped retrying it.
        # Snapshots written before runs carried a deadline skip these checks.
        $runs = @($Snapshot.runs | Where-Object { $_.PSObject.Properties['deadline'] -and $_.deadline })
        $settled = @($runs | Where-Object {
                $deadline = [datetimeoffset]$_.deadline
                $deadline -le $Now.AddMinutes(-2) -and $deadline -gt $Now.AddHours(-$RunLookbackHours)
            } | Sort-Object { [datetimeoffset]$_.scheduledAt } -Descending)
        $isBad = { param($run) $run.status -notin @('complete', 'no_work') -and -not ($run.PSObject.Properties['vixOnly'] -and $run.vixOnly) }
        $describe = {
            param($run)
            $count = if ($run.expected) { ", $($run.ok) of $($run.expected) usable" } else { '' }
            "$(([datetimeoffset]$run.scheduledAt).ToLocalTime().ToString('MM/dd HH:mm')) $($run.status)$count"
        }
        $runIssue = {
            param([string]$Job, [string]$Text, [string]$Meaning, $Run)
            & $add $Text $Meaning @{
                job = $Job; label = $script:Jobs[$Job].Name; task = $script:Jobs[$Job].Task
                lastRun = ([datetimeoffset]$Run.scheduledAt).ToString('o')
                deadline = ([datetimeoffset]$Run.deadline).ToString('o')
            }
        }
        foreach ($job in @('stock-prices', 'option-quotes')) {
            $name = $script:Jobs[$job].Name
            $jobRuns = @($settled | Where-Object job -EQ $job)
            # The next session slot retries missing items, so one bad slot is normal; 2 in a row is not.
            $sessions = @($jobRuns | Where-Object kind -In @('session', 'open_session') | Select-Object -First 2)
            if ($sessions.Count -eq 2 -and @($sessions | Where-Object { & $isBad $_ }).Count -eq 2) {
                & $runIssue $job "${name}: the last 2 session runs are incomplete." `
                    "Runs $((@($sessions | ForEach-Object { & $describe $_ })) -join '; '). Two incomplete slots in a row means collection is failing, not just a slow quote." $sessions[0]
            }
            foreach ($kind in @('close', 'settle')) {
                $last = @($jobRuns | Where-Object kind -EQ $kind | Select-Object -First 1)
                if (-not $last.Count -or -not (& $isBad $last[0])) { continue }
                $recovered = @($runs | Where-Object {
                        $_.job -eq $job -and $_.kind -eq 'recovery' -and $_.status -eq 'complete' -and
                        [datetimeoffset]$_.scheduledAt -gt [datetimeoffset]$last[0].scheduledAt
                    }).Count
                if ($recovered) { continue }
                & $runIssue $job "${name}: the latest $kind run is incomplete." `
                    "Run $(& $describe $last[0]), and no later recovery run completed. The day's $kind prices are missing for some symbols." $last[0]
            }
        }
        foreach ($job in @('earnings', 'indices', 'splits')) {
            $last = @($settled | Where-Object job -EQ $job | Select-Object -First 1)
            if ($last.Count -and (& $isBad $last[0])) {
                & $runIssue $job "$($script:Jobs[$job].Name): the latest run did not complete." `
                    "Run $(& $describe $last[0]). This reference data is refreshed by the next scheduled run; until then the app shows the previous values." $last[0]
            }
        }
    }
    if ($Detail) { return $issues.ToArray() }
    return [string[]]@($issues | ForEach-Object text)
}

Export-ModuleMember -Function Get-CollectorMonitorIssue, Add-CollectorIssueLog, Read-CollectorTaskLog
