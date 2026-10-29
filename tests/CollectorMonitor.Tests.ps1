Import-Module (Join-Path $PSScriptRoot '..\src\CollectorMonitor.psm1') -Force

Describe 'Independent collector monitoring' {
    BeforeEach {
        $now = [datetimeoffset]'2026-10-23T19:30:00-07:00'
        $tasks = @([pscustomobject]@{
            Name = 'fixture'; Exists = $true; State = 'Ready'; Result = 0; LastRun = $now.AddMinutes(-1)
        })
        $snapshot = [pscustomobject]@{
            schemaVersion = 1; generatedAt = $now.AddMinutes(-4).ToString('o'); errors = @(); runs = @()
            health = @('stock-prices', 'earnings', 'indices', 'splits', 'option-quotes') | ForEach-Object {
                [pscustomobject]@{ job = $_; heartbeatAt = $now.AddMinutes(-1).ToString('o') }
            }
        }
        # A run scheduled $Ago minutes before now whose retry window closed 5 minutes after it started.
        $run = {
            param([string]$Job, [string]$Kind, [string]$Status, [int]$Ago, [bool]$VixOnly = $false)
            [pscustomobject]@{
                job = $Job; kind = $Kind; status = $Status; expected = 10; ok = if ($Status -eq 'complete') { 10 } else { 7 }
                scheduledAt = $now.AddMinutes(-$Ago).ToString('o'); deadline = $now.AddMinutes(5 - $Ago).ToString('o')
                vixOnly = $VixOnly
            }
        }
    }
    It 'accepts fresh data outside market hours because minute tasks still run' {
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'leaves collector exit codes to the run checks' {
        foreach ($name in @('SolutionDeploy-web-portfolio-stock-collector', 'SolutionDeploy-web-portfolio-stock-watchdog',
                'SolutionDeploy-web-options-collector', 'SolutionDeploy-web-portfolio-reference-splits')) {
            $tasks[0].Name = $name; $tasks[0].Result = 1
            @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
        }
    }
    It 'reports a failed publisher run with a stable text' {
        $tasks[0].Name = 'SolutionDeploy-collector-status'; $tasks[0].Result = 64
        $detail = @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now -Detail)[0]
        $detail.text | Should Be 'Collector status publisher failed.'
        $detail.meaning | Should Match 'code 64'
        $detail.exitCode | Should Be 64
    }
    It 'tolerates one incomplete session slot and reports 2 in a row' {
        $snapshot.runs = @((& $run 'stock-prices' 'session' 'complete' 30), (& $run 'stock-prices' 'session' 'partial' 20))
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
        $snapshot.runs = @((& $run 'stock-prices' 'session' 'missed' 30), (& $run 'stock-prices' 'session' 'partial' 20))
        $detail = @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now -Detail)[0]
        $detail.text | Should Be 'Stock prices: the last 2 session runs are incomplete.'
        $detail.meaning | Should Match '7 of 10 usable'
        $detail.task | Should Be 'SolutionDeploy-web-portfolio-stock-collector'
        $detail.job | Should Be 'stock-prices'
    }
    It 'judges a run only after its deadline' {
        $snapshot.runs = @((& $run 'option-quotes' 'open_session' 'failed' 30), (& $run 'option-quotes' 'open_session' 'running' 3))
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'accepts a stock run whose only shortfall is a stale VIX quote' {
        $snapshot.runs = @((& $run 'stock-prices' 'session' 'partial' 30 $true), (& $run 'stock-prices' 'session' 'partial' 20 $true),
            (& $run 'stock-prices' 'close' 'partial' 15 $true))
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'reports a bad close or settle run unless a later recovery run completed' {
        $snapshot.runs = @((& $run 'option-quotes' 'close' 'partial' 60), (& $run 'option-quotes' 'settle' 'complete' 50))
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' |
            Should Be 'Option quotes: the latest close run is incomplete.'
        $snapshot.runs += & $run 'option-quotes' 'recovery' 'complete' 40
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'reports the latest reference run when it did not complete' {
        $snapshot.runs = @((& $run 'earnings' 'earnings' 'complete' 600), (& $run 'earnings' 'earnings' 'failed' 60))
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' |
            Should Be 'Earnings dates: the latest run did not complete.'
        $snapshot.runs = @((& $run 'splits' 'splits' 'missed' 600), (& $run 'splits' 'splits' 'no_work' 60))
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'ignores runs older than the lookback and snapshots without deadlines' {
        $snapshot.runs = @((& $run 'indices' 'indices' 'failed' 1500))
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
        $old = & $run 'indices' 'indices' 'failed' 60
        $old.PSObject.Properties.Remove('deadline')
        $snapshot.runs = @($old)
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'attaches the collector log for the bad run' {
        $logs = Join-Path $TestDrive 'web-portfolio\shared\logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        $at = $now.AddMinutes(-60).LocalDateTime
        @(
            "$($at.ToString('yyyy-MM-dd HH:mm:ss')),000 INFO local time $($at.ToString('s'))"
            "$($at.AddSeconds(5).ToString('yyyy-MM-dd HH:mm:ss')),000 ERROR Finnhub quota exhausted"
        ) | Set-Content (Join-Path $logs 'stock-reference-earnings.log')
        $snapshot.runs = @((& $run 'earnings' 'earnings' 'failed' 60))
        $details = @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now -Detail)
        Add-CollectorIssueLog -Details $details -AppsRoot $TestDrive
        $details[0].summary | Should Be 'Earnings dates: Finnhub quota exhausted'
        $details[0].text | Should Be 'Earnings dates: the latest run did not complete.'
    }
    It 'reads the cause and run lines from a task log' {
        $logs = Join-Path $TestDrive 'web-options\shared\logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        @(
            '2026-10-28 13:10:35,731 INFO run=1 kind=settle {"status": "complete", "expected": 2, "price": 2}'
            '2026-10-28 13:11:15,083 INFO local time 2026-10-28T13:11:15.083690-07:00'
            '2026-10-28 13:11:16,600 INFO HTTP Request: POST https://api.tastyworks.com/oauth/token "HTTP/1.1 200 OK"'
            '2026-10-28 13:11:17,000 INFO connecting ******localhost/web_options ******'
            '2026-10-28 13:11:18,113 ERROR Quote stream timed out with missing prices'
            '2026-10-28 13:11:18,200 INFO run=417676 kind=settle {"status": "partial", "expected": 346, "price": 344, "delta": 346, "iv": 346}'
        ) | Set-Content (Join-Path $logs 'collector-tick.log')
        $read = Read-CollectorTaskLog -Path (Join-Path $logs 'collector-tick.log') -Since ([datetime]'2026-10-28T13:11:15')
        $read.Cause | Should Be 'Quote stream timed out with missing prices; settle run partial, 344 of 346 prices'
        $read.Lines.Count | Should Be 3
        $read.Lines -join "`n" | Should Not Match 'local time|HTTP Request|kind=settle \{"status": "complete"'
    }
    It 'prefers the watchdog unhealthy reason over notification errors' {
        $log = Join-Path $TestDrive 'watchdog.log'
        @(
            '2026-10-28 13:12:15,000 INFO local time 2026-10-28T13:12:15-07:00'
            '2026-10-28 13:12:15,100 WARNING unhealthy: heartbeat overdue, last 13:05:00 (7 min ago)'
            '2026-10-28 13:12:15,200 ERROR notification failed: URLError'
        ) | Set-Content $log
        (Read-CollectorTaskLog -Path $log -Since ([datetime]'2026-10-28T13:12:15')).Cause |
            Should Be 'heartbeat overdue, last 13:05:00 (7 min ago)'
    }
    It 'keeps only the failed run when later runs follow it in the log' {
        $log = Join-Path $TestDrive 'tick-later.log'
        @(
            '2026-10-28 13:11:15,083 INFO local time 2026-10-28T13:11:15.083690-07:00'
            '2026-10-28 13:11:18,113 ERROR Quote stream timed out with missing prices'
            '2026-10-28 13:11:18,200 INFO run=417676 kind=settle {"status": "partial", "expected": 346, "price": 344}'
            '2026-10-28 13:12:15,000 INFO local time 2026-10-28T13:12:15-07:00'
            '2026-10-28 13:12:35,000 INFO run=417676 kind=settle {"status": "complete", "expected": 346, "price": 346}'
            '2026-10-28 14:48:00,000 INFO local time 2026-10-28T14:48:00-07:00'
            '2026-10-28 14:48:01,000 INFO no eligible capture slot'
        ) | Set-Content $log
        $read = Read-CollectorTaskLog -Path $log -Since ([datetime]'2026-10-28T13:11:15')
        $read.Lines.Count | Should Be 2
        $read.Lines -join "`n" | Should Not Match '13:12|14:48|complete'
        $read.Cause | Should Be 'Quote stream timed out with missing prices; settle run partial, 344 of 346 prices'
    }
    It 'returns no lines when the failed run is no longer in the log' {
        $log = Join-Path $TestDrive 'tick-rotated.log'
        @(
            '2026-10-28 14:48:00,000 INFO local time 2026-10-28T14:48:00-07:00'
            '2026-10-28 14:48:01,000 INFO no eligible capture slot'
        ) | Set-Content $log
        $read = Read-CollectorTaskLog -Path $log -Since ([datetime]'2026-10-28T13:10:15')
        $read.Lines.Count | Should Be 0
        $read.Cause | Should Be ''
    }
    It 'does not treat running status as a failed exit' {
        $tasks[0].State = 'Running'; $tasks[0].Result = 267009
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'does not alert on a freshly registered task that has not run yet' {
        $tasks[0].Result = 267011; $tasks[0].LastRun = [datetimeoffset]'1999-11-30T00:00:00-08:00'
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'does not alert when a minute trigger was skipped because the previous run was still going' {
        $tasks[0].Result = 2147946720
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'still reports a skipped task whose minute schedule is overdue' {
        $tasks[0].Result = 2147946720; $tasks[0].LastRun = $now.AddMinutes(-11)
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'overdue'
    }
    It 'detects missing and disabled expected tasks' {
        $tasks[0].Exists = $false
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'missing'
        $tasks[0].Exists = $true; $tasks[0].State = 'Disabled'
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'disabled'
    }
    It 'detects stale snapshots even if contained heartbeats look fresh' {
        $snapshot.generatedAt = $now.AddMinutes(-13).ToString('o')
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'snapshot timestamp'
    }
    It 'detects stale heartbeats independently of snapshot generation' {
        $snapshot.health[0].heartbeatAt = $now.AddMinutes(-11).ToString('o')
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'stock-prices heartbeat'
    }
    It 'detects reader errors and missing snapshots' {
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $null -SnapshotError 'access denied' -Now $now) -join ';' | Should Match 'access denied'
    }
    It 'reports publisher errors without forwarding database diagnostic contents' {
        $snapshot.errors = @('private connection diagnostic')
        $issues = (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';'
        $issues | Should Match 'publisher reports errors'
        $issues | Should Not Match 'private connection'
    }
    It 'detects future heartbeat timestamps' {
        $snapshot.health[0].heartbeatAt = $now.AddMinutes(3).ToString('o')
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'future'
    }
}

Describe 'Monitor runner' {
    BeforeEach {
        $alert = Join-Path $TestDrive 'alert.ps1'
        $sent = Join-Path $TestDrive 'sent.txt'
        Remove-Item -LiteralPath $sent -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $alert -Value "param(`$Title, `$Message) Add-Content -LiteralPath '$sent' -Value `$Title; `$global:LASTEXITCODE = 0"
        $runner = Join-Path $PSScriptRoot '..\scripts\Test-CollectorHealth.ps1'
        $common = @{
            StatePath = Join-Path $TestDrive 'state.json'; AlertScript = $alert
            AlertLogPath = Join-Path $TestDrive 'collector-alerts.json'; MonitorPath = Join-Path $TestDrive 'collector-monitor.json'
        }
        Remove-Item -LiteralPath $common.StatePath, $common.AlertLogPath, $common.MonitorPath -ErrorAction SilentlyContinue
    }
    It 'surfaces task-query failures without writing state or attempting notifications' {
        Mock Get-ScheduledTask { throw 'fixture scheduler unavailable' }
        $result = & $runner -EvaluateOnly -StatePath $common.StatePath -AlertScript (Join-Path $TestDrive 'missing-alert.ps1')
        $record = $result | ConvertFrom-Json
        $record.issues -join ';' | Should Match 'fixture scheduler unavailable'
        Test-Path -LiteralPath $common.StatePath | Should Be $false
    }
    It 'records each sent notification in a pruned alert history and writes the current result' {
        Mock Get-ScheduledTask { throw 'fixture scheduler unavailable' }
        ConvertTo-Json -InputObject @([ordered]@{ sentAt = (Get-Date).AddDays(-40).ToString('o'); kind = 'alert'
                title = 'old'; issues = @('old') }) | Set-Content -LiteralPath $common.AlertLogPath
        & $runner @common | Out-Null
        $rows = @(Get-Content -LiteralPath $common.AlertLogPath -Raw | ConvertFrom-Json)
        $rows.Count | Should Be 1
        $rows[0].kind | Should Be 'alert'
        $rows[0].issues -join ';' | Should Match 'fixture scheduler unavailable'
        $rows[0].details[0].meaning | Should Match 'collector health is unknown'
        $current = Get-Content -LiteralPath $common.MonitorPath -Raw | ConvertFrom-Json
        $current.details[0].text | Should Match 'fixture scheduler unavailable'
    }
    It 'notifies only when an issue opens, not when one of several clears' {
        $open = 'Collector monitor check failed: fixture A'
        [ordered]@{ fingerprint = "other`n$open"; issues = @($open, 'other'); lastNotificationLocal = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $common.StatePath
        Mock Get-ScheduledTask { throw 'fixture A' }
        & $runner @common | Out-Null
        Test-Path -LiteralPath $sent | Should Be $false
        Mock Get-ScheduledTask { throw 'fixture B' }
        & $runner @common | Out-Null
        @(Get-Content -LiteralPath $sent) -join ';' | Should Be 'Market collectors need attention'
    }
}
