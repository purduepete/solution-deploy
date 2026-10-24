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
    }
    It 'accepts fresh data outside market hours because minute tasks still run' {
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'detects the original launcher failure even with a fresh heartbeat' {
        $tasks[0].Result = 64
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'result is 64'
    }
    It 'does not treat running status as a failed exit' {
        $tasks[0].State = 'Running'; $tasks[0].Result = 267009
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
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
    It 'ignores informational audit differences' {
        $snapshot.audits[0].status = 'fail'; $snapshot.audits[0].informational = $true
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
    }
    It 'allows nightly schedules until the next report is due' {
        $tasks[0].Daily = $true; $tasks[0].LastRun = $now.AddHours(-20)
        @(Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now).Count | Should Be 0
        $tasks[0].LastRun = $now.AddHours(-27)
        (Get-CollectorMonitorIssue -Tasks $tasks -Snapshot $snapshot -Now $now) -join ';' | Should Match 'daily run is overdue'
    }
}

Describe 'Monitor runner read-only evaluation' {
    It 'surfaces task-query failures without writing state or attempting notifications' {
        Mock Get-ScheduledTask { throw 'fixture scheduler unavailable' }
        $state = Join-Path $TestDrive 'not-created.json'
        $result = & (Join-Path $PSScriptRoot '..\scripts\Test-CollectorHealth.ps1') `
            -EvaluateOnly -StatePath $state -AlertScript (Join-Path $TestDrive 'missing-alert.ps1')
        $record = $result | ConvertFrom-Json
        $record.issues -join ';' | Should Match 'fixture scheduler unavailable'
        Test-Path -LiteralPath $state | Should Be $false
    }
}
