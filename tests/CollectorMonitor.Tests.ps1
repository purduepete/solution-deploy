Import-Module (Join-Path $PSScriptRoot '..\src\CollectorMonitor.psm1') -Force

Describe 'Independent collector monitoring' {
    BeforeEach {
        $now = [datetimeoffset]'2026-10-23T19:30:00-07:00'
        $tasks = @([pscustomobject]@{
            Name = 'fixture'; Exists = $true; State = 'Ready'; Result = 0
            LastRun = $now.AddMinutes(-1); Daily = $false
        })
        $snapshot = [pscustomobject]@{
            schemaVersion = 1; generatedAt = $now.AddMinutes(-4).ToString('o'); errors = @()
            health = @('stock-prices', 'earnings', 'indices', 'splits', 'option-quotes') | ForEach-Object {
                [pscustomobject]@{ job = $_; heartbeatAt = $now.AddMinutes(-1).ToString('o') }
            }

            audits = @('stock-audit', 'options-audit') | ForEach-Object {
                [pscustomobject]@{
                    job = $_; date = '2026-10-22'; writtenAt = $now.AddHours(-20).ToString('o')
                    informational = $false; status = 'pass'; subject = 'coverage'
                }
            }
        }
        $optionsReport = [pscustomobject]@{
            date = '2026-10-22'; status = 'pass'; notification_sent = $true
            generated_at_local = $now.AddMinutes(-5).ToString('o')
            sections = [pscustomobject]@{
                vader = [pscustomobject]@{ status = 'pass' }
                portfolio = [pscustomobject]@{ status = 'pass' }
                coverage = [pscustomobject]@{ status = 'pass' }
            }
        }
    }
    It 'accepts fresh data outside market hours because minute tasks still run' {
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'detects the original launcher failure even with a fresh heartbeat' {
        $tasks[0].Result = 64
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'exit code 64'
    }
    It 'explains watchdog failures without claiming price data is wrong' {
        $tasks[0].Name = 'SolutionDeploy-web-portfolio-stock-watchdog'
        $tasks[0].Result = 1
        $message = (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';'
        $message | Should Be 'Stock collector health check failed (exit code 1).'
        $detail = @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now -Detail)[0]
        $detail.meaning | Should Match 'does not by itself mean collected prices are wrong'
        $detail.task | Should Be 'SolutionDeploy-web-portfolio-stock-watchdog'
        $detail.exitCode | Should Be 1
    }
    It 'names collection failures and explains the possible impact' {
        $tasks[0].Name = 'SolutionDeploy-web-options-collector'
        $tasks[0].Result = 1
        $message = (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';'
        $message | Should Be 'Option quote collection failed (exit code 1).'
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now -Detail)[0].meaning |
            Should Match 'may be incomplete'
    }
    It 'reads the cause and run lines from the failed task log' {
        $logs = Join-Path $TestDrive 'web-options\shared\logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        @(
            '2026-10-28 13:10:35,731 INFO run=1 kind=settle {"status": "complete", "expected": 2, "price": 2}'
            '2026-10-28 13:11:15,083 INFO local time 2026-10-28T13:11:15.083690-07:00'
            '2026-10-28 13:11:16,600 INFO HTTP Request: POST https://api.tastyworks.com/oauth/token "HTTP/1.1 200 OK"'
            '2026-10-28 13:11:17,000 INFO connecting postgresql://collector:secretpw@localhost/web_options password=hunter2'
            '2026-10-28 13:11:18,113 ERROR Quote stream timed out with missing prices'
            '2026-10-28 13:11:18,200 INFO run=417676 kind=settle {"status": "partial", "expected": 346, "price": 344, "delta": 346, "iv": 346}'
        ) | Set-Content (Join-Path $logs 'collector-tick.log')
        $tasks[0].Name = 'SolutionDeploy-web-options-collector'
        $tasks[0].Result = 1
        $tasks[0].LastRun = [datetimeoffset]'2026-10-28T13:11:15-07:00'
        $details = @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now -Detail)
        Add-CollectorIssueLog -Details $details -AppsRoot $TestDrive
        $details[0].summary | Should Be 'Option quote collection failed: Quote stream timed out with missing prices; settle run partial, 344 of 346 prices'
        $details[0].log.Count | Should Be 3
        $details[0].log -join "`n" | Should Not Match 'secretpw|hunter2|local time|HTTP Request|kind=settle \{"status": "complete"'
        $details[0].logPath | Should Match 'collector-tick\.log$'
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
    It 'keeps the last lines of an untimestamped audit log and names failed sections' {
        $log = Join-Path $TestDrive 'audit.log'
        @('Options audit 2026-10-27: FAIL', 'vader: pass matched=1/1', 'portfolio: fail matched=6/19') | Set-Content $log
        $read = Read-CollectorTaskLog -Path $log -Since ([datetime]'2026-10-28T00:00:00')
        $read.Lines.Count | Should Be 3
        $read.Cause | Should Be 'audit section portfolio failed'
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
    It 'detects missing audit reports and future heartbeat timestamps' {
        $snapshot.audits = @()
        $snapshot.health[0].heartbeatAt = $now.AddMinutes(3).ToString('o')
        $issues = (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';'
        $issues | Should Match 'no audit report'
        $issues | Should Match 'future'
    }
    It 'reports data audit failures despite task exit success' {
        $snapshot.audits[0].status = 'fail'
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'stock-audit section coverage reports fail'
    }
    It 'accepts a verified successful rerun after the failed options task' {
        $tasks[0].Name = 'SolutionDeploy-web-options-daily-audit'
        $tasks[0].Result = 1; $tasks[0].Daily = $true; $tasks[0].LastRun = $now.AddHours(-20)
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now `
                -OptionsAuditReport $optionsReport).Count | Should Be 0
    }
    It 'still reports a failing snapshot section after a successful rerun' {
        $tasks[0].Name = 'SolutionDeploy-web-options-daily-audit'
        $tasks[0].Result = 1; $tasks[0].Daily = $true; $tasks[0].LastRun = $now.AddHours(-20)
        $snapshot.audits[1].status = 'fail'
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now `
                -OptionsAuditReport $optionsReport) -join ';' | Should Match 'options-audit section coverage reports fail'
    }
    It 'retains a task failure when the report predates the failed execution' {
        $tasks[0].Name = 'SolutionDeploy-web-options-daily-audit'
        $tasks[0].Result = 1; $tasks[0].Daily = $true; $tasks[0].LastRun = $now.AddHours(-20)
        $optionsReport.generated_at_local = $now.AddHours(-21).ToString('o')
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now `
                -OptionsAuditReport $optionsReport) -join ';' | Should Match 'exit code 1'
    }
    It 'requires the failed execution date and a successful notification' {
        $tasks[0].Name = 'SolutionDeploy-web-options-daily-audit'
        $tasks[0].Result = 1; $tasks[0].Daily = $true; $tasks[0].LastRun = $now.AddHours(-20)
        $optionsReport.date = '2026-10-23'
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now `
                -OptionsAuditReport $optionsReport) -join ';' | Should Match 'exit code 1'
        $optionsReport.date = '2026-10-22'; $optionsReport.notification_sent = $false
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now `
                -OptionsAuditReport $optionsReport) -join ';' | Should Match 'exit code 1'
    }
    It 'does not accept missing or failing audit sections as recovery' {
        $tasks[0].Name = 'SolutionDeploy-web-options-daily-audit'
        $tasks[0].Result = 1; $tasks[0].Daily = $true; $tasks[0].LastRun = $now.AddHours(-20)
        $optionsReport.sections.coverage.status = 'fail'
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now `
                -OptionsAuditReport $optionsReport) -join ';' | Should Match 'exit code 1'
        $optionsReport.sections.PSObject.Properties.Remove('coverage')
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now `
                -OptionsAuditReport $optionsReport) -join ';' | Should Match 'exit code 1'
    }
    It 'rejects future-dated recovery and still detects a stale snapshot' {
        $tasks[0].Name = 'SolutionDeploy-web-options-daily-audit'
        $tasks[0].Result = 1; $tasks[0].Daily = $true; $tasks[0].LastRun = $now.AddHours(-20)
        $optionsReport.generated_at_local = $now.AddMinutes(3).ToString('o')
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now `
                -OptionsAuditReport $optionsReport) -join ';' | Should Match 'exit code 1'
        $optionsReport.generated_at_local = $now.AddMinutes(-5).ToString('o')
        $snapshot.generatedAt = $now.AddMinutes(-13).ToString('o')
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now `
                -OptionsAuditReport $optionsReport) -join ';' | Should Match 'snapshot timestamp'
    }
    It 'ignores informational audit differences' {
        $snapshot.audits[0].status = 'fail'; $snapshot.audits[0].informational = $true
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'accepts options non-session skips only when the overall audit passed' {
        $row = $snapshot.audits[1]
        $row.status = 'not_run'
        $row | Add-Member -NotePropertyName reportStatus -NotePropertyValue 'pass'
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
        $row.reportStatus = 'fail'
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' |
            Should Match 'options-audit section coverage reports not_run'
    }
    It 'still reports unverified skips and missing stock earnings runs' {
        $snapshot.audits[1].status = 'not_run'
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' |
            Should Match 'options-audit section coverage reports not_run'
        $snapshot.audits[0].status = 'not_run'
        $snapshot.audits[0] | Add-Member -NotePropertyName reportStatus -NotePropertyValue 'pass'
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' |
            Should Match 'stock-audit section coverage reports not_run'
    }
    It 'allows nightly schedules until the next report is due' {
        $tasks[0].Daily = $true; $tasks[0].LastRun = $now.AddHours(-20)
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
        $tasks[0].LastRun = $now.AddHours(-27)
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'daily run is overdue'
    }
}

Describe 'Monitor runner read-only evaluation' {
    It 'reads the failed task date report for rerun verification' {
        $lastRun = (Get-Date).AddHours(-20)
        $scheduledTask = New-CimInstance -ClassName MSFT_ScheduledTask -ClientOnly -Property @{
            TaskName = 'SolutionDeploy-web-options-daily-audit'; State = 'Ready'
        }
        Mock Get-ScheduledTask { $scheduledTask }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastTaskResult = 1; LastRunTime = $lastRun } }
        $folder = Join-Path $TestDrive 'web-options\shared\logs\audit'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $report = [ordered]@{
            date = $lastRun.ToString('yyyy-MM-dd'); status = 'pass'; notification_sent = $true
            generated_at_local = (Get-Date).AddMinutes(-1).ToString('o')
            sections = @{ vader = @{status='pass'}; portfolio = @{status='pass'}; coverage = @{status='pass'} }
        }
        $report | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $folder "options-$($report.date).json")
        $snapshotPath = Join-Path $TestDrive 'snapshot.json'
        @{schemaVersion=1; generatedAt=(Get-Date).ToString('o'); errors=@(); health=@(); audits=@()} |
            ConvertTo-Json | Set-Content $snapshotPath
        $result = & (Join-Path $PSScriptRoot '..\scripts\Test-CollectorHealth.ps1') `
            -EvaluateOnly -AppsRoot $TestDrive -SnapshotPath $snapshotPath
        $record = $result | ConvertFrom-Json
        $record.issues -join ';' | Should Not Match 'Options nightly audit failed'
        $record.issues -join ';' | Should Not Match 'monitor check failed'
    }
    It 'surfaces task-query failures without writing state or attempting notifications' {
        Mock Get-ScheduledTask { throw 'fixture scheduler unavailable' }
        $state = Join-Path $TestDrive 'not-created.json'
        $result = & (Join-Path $PSScriptRoot '..\scripts\Test-CollectorHealth.ps1') `
            -EvaluateOnly -StatePath $state -AlertScript (Join-Path $TestDrive 'missing-alert.ps1')
        $record = $result | ConvertFrom-Json
        $record.issues -join ';' | Should Match 'fixture scheduler unavailable'
        Test-Path -LiteralPath $state | Should Be $false
    }

    It 'records each sent notification in a pruned alert history' {
        Mock Get-ScheduledTask { throw 'fixture scheduler unavailable' }
        $alert = Join-Path $TestDrive 'alert.ps1'
        Set-Content -LiteralPath $alert -Value 'param($Title, $Message) $global:LASTEXITCODE = 0'
        $history = Join-Path $TestDrive 'collector-alerts.json'
        ConvertTo-Json -InputObject @([ordered]@{ sentAt = (Get-Date).AddDays(-40).ToString('o'); kind = 'alert'
                title = 'old'; issues = @('old') }) | Set-Content -LiteralPath $history
        & (Join-Path $PSScriptRoot '..\scripts\Test-CollectorHealth.ps1') -StatePath (Join-Path $TestDrive 'state.json') `
            -AlertScript $alert -AlertLogPath $history | Out-Null
        $rows = @(Get-Content -LiteralPath $history -Raw | ConvertFrom-Json)
        $rows.Count | Should Be 1
        $rows[0].kind | Should Be 'alert'
        $rows[0].issues -join ';' | Should Match 'fixture scheduler unavailable'
        $rows[0].details[0].meaning | Should Match 'collector health is unknown'
    }
}
