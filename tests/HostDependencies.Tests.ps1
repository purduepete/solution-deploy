$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\HostDependencies.psm1') -Force

function New-PassingObservations {
    @{
        computerName = 'JIMBROWNHOME1'
        expectedHostName = 'jimbrownhome1'
        now = [datetimeoffset]'2026-11-27T09:00:00-08:00'
        errors = @()
        expectedDataDirectory = 'D:\data\postgres'
        expectedClusterId = '7000000000000000001'
        lookbackHours = 24
        maxBackupAgeHours = 36
        collectorMaxAgeMinutes = 30
        serviceImagePath = '"C:\Program Files\PostgreSQL\18\bin\pg_ctl.exe" runservice -N "postgresql-x64-18" -D "D:\data\postgres" -w'
        dataDirectory = 'D:/data/postgres'
        systemIdentifier = '7000000000000000001'
        serverVersionNum = '180006'
        psql = @{ path = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'; exists = $true; version = 'psql (PostgreSQL) 18.1'; sha256 = ('A' * 64); signatureStatus = 'Valid'; signerSubject = 'CN=EnterpriseDB' }
        pgDumpVersion = 'pg_dump (PostgreSQL) 18.1'
        authFailures = @()
        backupManifest = [pscustomobject]@{ status = 'Succeeded'; completedLocal = '2026-11-27T02:00:00.1234567-08:00' }
        runtimeRoot = 'C:\ProgramData\SolutionDeploy\runtime\powershell'
        managedExecutable = 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'
        links = @{
            '7' = @{ isJunction = $true; target = 'C:\ProgramData\SolutionDeploy\runtime\powershell\versions\7.6.7'; executableExists = $true }
            'previous' = @{ isJunction = $true; target = 'C:\ProgramData\SolutionDeploy\runtime\powershell\versions\7.6.6'; executableExists = $true }
        }
        sshdConfigText = "Subsystem sftp sftp-server.exe`nSubsystem powershell C:/ProgramData/SolutionDeploy/runtime/powershell/7/pwsh.exe -sshs -NoLogo -NoProfile`n"
        tasks = @(
            @{ path = '\JimlerTech\'; name = 'SolutionDeploy-ferry'; execute = 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe' }
            @{ path = '\JimlerTech\'; name = 'PostgreSQL-Backup'; execute = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
        )
        controllerVersion = '7.6.7'
        hostVersion = '7.6.7'
        apps = @(@{ id = 'ferry-tracker'; url = 'http://192.168.2.14:8787/health'; statusCode = 200; error = '' })
        collectorStatus = [pscustomobject]@{ schemaVersion = 1; generatedAt = '2026-11-27T08:55:00-08:00'; errors = @() }
    }
}

function Get-Report([hashtable]$Observations) {
    Test-HostDependencyObservations -Observations $Observations
}

function Get-Check($Report, [string]$Pattern) {
    @($Report.checks | Where-Object { $_.name -like $Pattern })[0]
}

Describe 'Host dependency report' {
    It 'passes a healthy host and reports no failures' {
        $report = Get-Report (New-PassingObservations)
        $report.status | Should Be 'Passed'
        @($report.failures).Count | Should Be 0
        $report.hostName | Should Be 'JIMBROWNHOME1'
    }
    It 'fails and names the failed check' {
        $observations = New-PassingObservations
        $observations.dataDirectory = 'C:/Program Files/PostgreSQL/18/data'
        $report = Get-Report $observations
        $report.status | Should Be 'Failed'
        @($report.failures)[0] | Should Match 'data_directory'
    }
    It 'fails when observation gathering recorded an error' {
        $observations = New-PassingObservations
        $observations.errors = @('data_directory: psql.exe failed (2): connection refused')
        (Get-Check (Get-Report $observations) 'Observations gathered*').status | Should Be 'Failed'
    }
    It 'fails when the script runs on another host' {
        $observations = New-PassingObservations
        $observations.computerName = 'OTHERHOST'
        (Get-Check (Get-Report $observations) 'Running on*').status | Should Be 'Failed'
    }
}

Describe 'PostgreSQL service and data directory checks' {
    It 'accepts the live -D path with quoting, case and slash differences' {
        $path = 'C:\Program Files\PostgreSQL\18\bin\pg_ctl.exe runservice -N postgresql-x64-18 -d d:/DATA/postgres -w'
        (Test-PostgresServiceImagePath $path 'D:\data\postgres').status | Should Be 'Passed'
    }
    It 'rejects a service re-registered with the installer default data folder' {
        $path = '"C:\Program Files\PostgreSQL\18\bin\pg_ctl.exe" runservice -N "postgresql-x64-18" -D "C:\Program Files\PostgreSQL\18\data" -w'
        (Test-PostgresServiceImagePath $path 'D:\data\postgres').status | Should Be 'Failed'
    }
    It 'rejects a data folder that only shares the expected prefix' {
        $path = '"pg_ctl.exe" -D "D:\data\postgres-old" -w'
        (Test-PostgresServiceImagePath $path 'D:\data\postgres').status | Should Be 'Failed'
    }
    It 'rejects a missing service PathName' {
        (Test-PostgresServiceImagePath $null 'D:\data\postgres').status | Should Be 'Failed'
    }
    It 'rejects a wrong data_directory from SHOW' {
        (Test-PostgresDataDirectory 'C:/Program Files/PostgreSQL/18/data' 'D:\data\postgres').status | Should Be 'Failed'
    }
    It 'accepts the live data_directory with forward slashes' {
        (Test-PostgresDataDirectory 'D:/data/postgres' 'D:\data\postgres').status | Should Be 'Passed'
    }
}

Describe 'PostgreSQL cluster identity checks' {
    It 'fails when the system_identifier differs from the expected cluster' {
        $check = Test-PostgresClusterIdentity '7000000000000000009' '7000000000000000001'
        $check.status | Should Be 'Failed'
        $check.detail | Should Match '7000000000000000009'
    }
    It 'passes an exact match' {
        (Test-PostgresClusterIdentity '7000000000000000001' '7000000000000000001').status | Should Be 'Passed'
    }
    It 'still reports the observed identifier when no expected id is supplied' {
        $check = Test-PostgresClusterIdentity '7000000000000000009' ''
        $check.status | Should Be 'Passed'
        $check.detail | Should Match '7000000000000000009'
    }
    It 'fails when system_identifier is unreadable' {
        (Test-PostgresClusterIdentity '' '').status | Should Be 'Failed'
    }
}

Describe 'PostgreSQL client tool checks' {
    It 'passes a present, versioned, hashed and validly signed psql.exe' {
        $checks = Test-PostgresClientTools -Path 'psql.exe' -Exists $true -Version 'psql (PostgreSQL) 18.1' -SHA256 ('a' * 64) -SignatureStatus 'Valid' -SignerSubject 'CN=x'
        @($checks | Where-Object status -eq 'Failed').Count | Should Be 0
    }
    It 'fails an unsigned psql.exe' {
        $checks = Test-PostgresClientTools -Path 'psql.exe' -Exists $true -Version 'psql (PostgreSQL) 18.1' -SHA256 ('a' * 64) -SignatureStatus 'NotSigned' -SignerSubject $null
        $checks[1].status | Should Be 'Failed'
    }
    It 'skips the signature check when it was not requested' {
        $checks = Test-PostgresClientTools -Path 'psql.exe' -Exists $true -Version 'psql (PostgreSQL) 18.1' -SHA256 ('a' * 64) -SignatureStatus $null -SignerSubject $null
        $checks[1].status | Should Be 'Skipped'
    }
    It 'fails a missing psql.exe' {
        $checks = Test-PostgresClientTools -Path 'C:\missing\psql.exe' -Exists $false -Version $null -SHA256 $null -SignatureStatus $null -SignerSubject $null
        $checks[0].status | Should Be 'Failed'
    }
}

Describe 'pg_dump major version check' {
    It 'fails when pg_dump is a different major version from the server' {
        (Test-PgDumpMajorVersion 'pg_dump (PostgreSQL) 17.5' '180006').status | Should Be 'Failed'
    }
    It 'passes when the major versions match even if minors differ' {
        (Test-PgDumpMajorVersion 'pg_dump (PostgreSQL) 18.1' '180006').status | Should Be 'Passed'
    }
    It 'fails when the version output cannot be read' {
        (Test-PgDumpMajorVersion 'something else' '180006').status | Should Be 'Failed'
    }
}

Describe 'PostgreSQL authentication failure check' {
    $now = [datetimeoffset]'2026-11-27T09:00:00-08:00'
    It 'fails on a password authentication failure inside the lookback window' {
        $events = @(@{ time = $now.AddHours(-2).DateTime; message = 'FATAL:  password authentication failed for user "sd_app"' })
        (Test-PostgresAuthenticationFailures $events $now 24).status | Should Be 'Failed'
    }
    It 'ignores failures older than the lookback window and unrelated messages' {
        $events = @(
            @{ time = $now.AddHours(-30).DateTime; message = 'password authentication failed for user "old"' }
            @{ time = $now.AddHours(-1).DateTime; message = 'connection received' }
        )
        (Test-PostgresAuthenticationFailures $events $now 24).status | Should Be 'Passed'
    }
}

Describe 'PostgreSQL log line timestamps and authentication entries' {
    It 'parses a leading timestamp with fraction and zone abbreviation or offset' {
        $pst = ConvertFrom-PostgresLogLine '2026-11-27 08:30:00.123 PST [4313] FATAL:  password authentication failed'
        $pst.Offset.TotalHours | Should Be -8
        $pst.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fff') | Should Be '2026-11-27T16:30:00.123'
        $offset = ConvertFrom-PostgresLogLine '2026-11-27 08:30:00 -07 [4313] FATAL'
        $offset.Offset.TotalHours | Should Be -7
    }
    It 'returns null for a line without a leading timestamp' {
        ConvertFrom-PostgresLogLine 'DETAIL:  password authentication failed for user "x"' | Should BeNullOrEmpty
    }
    It 'ignores old failures in a recently written log and flags recent ones' {
        $now = [datetimeoffset]::Now
        $folder = Join-Path $TestDrive 'pg-log-recent'
        New-Item -ItemType Directory $folder -Force | Out-Null
        $old = $now.AddDays(-3).ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
        $recent = $now.AddMinutes(-30).ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
        Set-Content -LiteralPath (Join-Path $folder 'postgresql.log') -Value @(
            "$old [4312] FATAL:  password authentication failed for user `"old_app`""
            "$recent [4313] FATAL:  password authentication failed for user `"sd_app`""
            "$recent [4314] DETAIL:  Connection matched pg_hba.conf line 90."
        )
        $entries = @(Get-PostgresLogAuthenticationEntries -LogFolder $folder -Cutoff $now.AddHours(-24))
        $entries.Count | Should Be 1
        $entries[0].message | Should Match 'sd_app'
        $entries[0].timeSource | Should Be 'line timestamp'
        (Test-PostgresAuthenticationFailures $entries $now 24).status | Should Be 'Failed'
    }
    It 'ignores a log file whose last write is older than the cutoff' {
        $now = [datetimeoffset]::Now
        $folder = Join-Path $TestDrive 'pg-log-stale'
        New-Item -ItemType Directory $folder -Force | Out-Null
        $file = Join-Path $folder 'postgresql.log'
        Set-Content -LiteralPath $file -Value "$($now.ToString('yyyy-MM-dd HH:mm:ss zzz')) FATAL:  password authentication failed"
        (Get-Item -LiteralPath $file).LastWriteTime = $now.AddDays(-5).LocalDateTime
        @(Get-PostgresLogAuthenticationEntries -LogFolder $folder -Cutoff $now.AddHours(-24)).Count | Should Be 0
    }
    It 'dates a matching line with no timestamp by the file LastWriteTime and says so' {
        $now = [datetimeoffset]::Now
        $folder = Join-Path $TestDrive 'pg-log-fallback'
        New-Item -ItemType Directory $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'postgresql.log') -Value 'password authentication failed for user "sd_app"'
        $entries = @(Get-PostgresLogAuthenticationEntries -LogFolder $folder -Cutoff $now.AddHours(-24))
        $entries.Count | Should Be 1
        $entries[0].timeSource | Should Be 'file LastWriteTime'
        $check = Test-PostgresAuthenticationFailures $entries $now 24
        $check.status | Should Be 'Failed'
        $check.detail | Should Match 'LastWriteTime'
    }
}

Describe 'App readiness URLs' {
    It 'uses the localUrl origin with the releases.json readiness path' {
        Get-AppHealthUrl 'http://192.168.2.14:8797/' @{ path = '/healthz'; expected = @{ status = 'ok' } } | Should Be 'http://192.168.2.14:8797/healthz'
    }
    It 'does not build a health path under the /app base of work-log' {
        Get-AppHealthUrl 'http://192.168.2.14:8794/app' @{ path = '/healthz' } | Should Be 'http://192.168.2.14:8794/healthz'
    }
    It 'accepts a bare string readiness path' {
        Get-AppHealthUrl 'http://192.168.2.14:8795/' '/api/ready' | Should Be 'http://192.168.2.14:8795/api/ready'
    }
    It 'checks localUrl as-is when no readiness path exists' {
        Get-AppHealthUrl 'http://192.168.2.14:8787/' $null | Should Be 'http://192.168.2.14:8787/'
    }
    It 'builds targets from the real sites.json and releases.json without /app/health or static pages' {
        $sites = (Get-Content -LiteralPath (Join-Path $root 'site\sites.json') -Raw | ConvertFrom-Json).sites
        $releases = Get-Content -LiteralPath (Join-Path $root 'environments\releases.json') -Raw | ConvertFrom-Json
        $targets = @(Get-AppHealthTargets -Sites $sites -Releases $releases)
        ($targets | Where-Object id -eq 'work-log').url | Should Be 'http://192.168.2.14:8794/healthz'
        ($targets | Where-Object id -eq 'web-options').url | Should Be 'http://192.168.2.14:8797/healthz'
        @($targets | Where-Object { $_.url -like '*/app/health*' }).Count | Should Be 0
        @($targets | Where-Object id -eq 'blank-page').Count | Should Be 0
    }
}

Describe 'Controller version parity' {
    It 'reports Skipped rather than comparing the host with itself when no controller version is supplied' {
        $check = Test-PowerShellVersionParity '' '7.6.7'
        $check.status | Should Be 'Skipped'
        $check.detail | Should Be 'Pass -ControllerVersion <major.minor.patch> from the controller to verify parity.'
    }
    It 'skips in the full report without failing it' {
        $observations = New-PassingObservations
        $observations.controllerVersion = ''
        $report = Get-Report $observations
        $report.status | Should Be 'Passed'
        (Get-Check $report 'Controller and host*').status | Should Be 'Skipped'
    }
    It 'compares Major.Minor when a controller version is supplied' {
        (Test-PowerShellVersionParity '7.6.1' '7.6.7').status | Should Be 'Passed'
        (Test-PowerShellVersionParity '7.5.4' '7.6.7').status | Should Be 'Failed'
    }
}

Describe 'Backup freshness check' {
    $now = [datetimeoffset]'2026-11-27T09:00:00-08:00'
    It 'passes a recent successful manifest' {
        $manifest = [pscustomobject]@{ status = 'Succeeded'; completedLocal = '2026-11-27T02:00:00.1234567-08:00' }
        (Test-PostgresBackupManifest $manifest $now 36).status | Should Be 'Passed'
    }
    It 'fails a stale backup older than the limit' {
        $manifest = [pscustomobject]@{ status = 'Succeeded'; completedLocal = '2026-11-23T02:00:00.1234567-08:00' }
        (Test-PostgresBackupManifest $manifest $now 36).detail | Should Match 'hours ago'
        (Test-PostgresBackupManifest $manifest $now 36).status | Should Be 'Failed'
    }
    It 'fails a manifest that did not succeed' {
        $manifest = [pscustomobject]@{ status = 'Failed'; completedLocal = '2026-11-27T02:00:00-08:00' }
        (Test-PostgresBackupManifest $manifest $now 36).status | Should Be 'Failed'
    }
    It 'fails when latest-success.json is missing' {
        (Test-PostgresBackupManifest $null $now 36).status | Should Be 'Failed'
    }
}

Describe 'Managed PowerShell runtime checks' {
    It 'fails when the 7 junction drifts outside versions' {
        $links = @{
            '7' = @{ isJunction = $true; target = 'C:\Program Files\PowerShell\7'; executableExists = $true }
            'previous' = @{ isJunction = $true; target = 'C:\ProgramData\SolutionDeploy\runtime\powershell\versions\7.6.6'; executableExists = $true }
        }
        (Test-PowerShellRuntimeLinks 'C:\ProgramData\SolutionDeploy\runtime\powershell' $links).status | Should Be 'Failed'
    }
    It 'fails when a link is an ordinary directory rather than a junction' {
        $links = @{
            '7' = @{ isJunction = $false; target = ''; executableExists = $true }
            'previous' = @{ isJunction = $true; target = 'C:\ProgramData\SolutionDeploy\runtime\powershell\versions\7.6.6'; executableExists = $true }
        }
        (Test-PowerShellRuntimeLinks 'C:\ProgramData\SolutionDeploy\runtime\powershell' $links).detail | Should Match 'not a junction'
    }
    It 'fails a drifted scheduled task that launches Program Files pwsh' {
        $tasks = @(@{ path = '\JimlerTech\'; name = 'SolutionDeploy-ferry'; execute = 'C:\Program Files\PowerShell\7\pwsh.exe' })
        $check = Test-PowerShellScheduledTasks $tasks 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'
        $check.status | Should Be 'Failed'
        $check.detail | Should Match 'SolutionDeploy-ferry'
    }
    It 'fails a task that launches bare pwsh.exe' {
        $tasks = @(@{ path = '\JimlerTech\'; name = 'PostgreSQL-Backup'; execute = 'pwsh.exe' })
        (Test-PowerShellScheduledTasks $tasks 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe').status | Should Be 'Failed'
    }
    It 'passes tasks on the managed executable and ignores tasks that do not run pwsh' {
        $tasks = @(
            @{ path = '\JimlerTech\'; name = 'SolutionDeploy-ferry'; execute = 'c:\programdata\solutiondeploy\runtime\powershell\7\PWSH.EXE' }
            @{ path = '\JimlerTech\'; name = 'FitTrack'; execute = 'C:\Windows\System32\wscript.exe' }
        )
        $check = Test-PowerShellScheduledTasks $tasks 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'
        $check.status | Should Be 'Passed'
        $check.detail | Should Match '^1 pwsh'
    }
    It 'fails a wrong sshd PowerShell subsystem' {
        $config = "Subsystem powershell C:/Program Files/PowerShell/7/pwsh.exe -sshs -NoLogo -NoProfile`n"
        (Test-PowerShellSubsystem $config 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe').status | Should Be 'Failed'
    }
    It 'fails when sshd has no PowerShell subsystem' {
        (Test-PowerShellSubsystem "Subsystem sftp sftp-server.exe`n" 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe').status | Should Be 'Failed'
    }
    It 'passes the managed sshd subsystem written with forward slashes' {
        $config = "Subsystem powershell C:/ProgramData/SolutionDeploy/runtime/powershell/7/pwsh.exe -sshs -NoLogo -NoProfile`n"
        (Test-PowerShellSubsystem $config 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe').status | Should Be 'Passed'
    }
    It 'fails controller and host Major.Minor skew' {
        (Test-PowerShellVersionParity '7.6.7' '7.5.4').status | Should Be 'Failed'
    }
    It 'passes a patch-level difference within the same Major.Minor' {
        (Test-PowerShellVersionParity '7.6.7' '7.6.5').status | Should Be 'Passed'
    }
}

Describe 'App health and collector snapshot checks' {
    $now = [datetimeoffset]'2026-11-27T09:00:00-08:00'
    It 'fails an app whose health endpoint returns 503' {
        $checks = @(Test-AppHealthEndpoints @(@{ id = 'fit-track'; url = 'http://192.168.2.14:8791/health'; statusCode = 503; error = 'Service Unavailable' }))
        $checks[0].status | Should Be 'Failed'
        $checks[0].detail | Should Match '503'
    }
    It 'skips app checks unless -CheckApps supplied observations' {
        $checks = @(Test-AppHealthEndpoints $null)
        $checks[0].status | Should Be 'Skipped'
    }
    It 'fails an app that answers 200 but whose body misses a readiness.expected field' {
        $checks = @(Test-AppHealthEndpoints @(@{ id = 'work-log'; url = 'http://192.168.2.14:8794/healthz'; statusCode = 200; error = ''; body = '{"status":"degraded"}'; expected = [pscustomobject]@{ status = 'ok' } }))
        $checks[0].status | Should Be 'Failed'
        $checks[0].detail | Should Match "readiness field 'status' is"
    }
    It 'passes an app whose body contains every readiness.expected field' {
        $checks = @(Test-AppHealthEndpoints @(@{ id = 'work-log'; url = 'http://192.168.2.14:8794/healthz'; statusCode = 200; error = ''; body = '{"ok":true,"version":"1"}'; expected = [pscustomobject]@{ ok = $true } }))
        $checks[0].status | Should Be 'Passed'
    }
    It 'fails a 200 response with a non-JSON body when readiness.expected is set' {
        $checks = @(Test-AppHealthEndpoints @(@{ id = 'fit-track'; url = 'http://192.168.2.14:8791/health'; statusCode = 200; error = ''; body = '<html>up</html>'; expected = [pscustomobject]@{ status = 'ok' } }))
        $checks[0].status | Should Be 'Failed'
        $checks[0].detail | Should Match 'not valid JSON'
    }
    It 'compares readiness values by JSON type, so a string "true" does not satisfy boolean true' {
        (Get-ReadinessBodyMismatch '{"ok":"true"}' ([pscustomobject]@{ ok = $true })) | Should Not BeNullOrEmpty
        (Get-ReadinessBodyMismatch '{"ok":true}' ([pscustomobject]@{ ok = $true })) | Should BeNullOrEmpty
    }
    It 'fails when an expected readiness field is absent from the body' {
        (Get-ReadinessBodyMismatch '{"status":"ok"}' @{ status = 'ok'; ready = $true }) | Should Match "readiness field 'ready' is missing"
    }
    It 'passes without a readiness.expected object, regardless of the body' {
        (Get-ReadinessBodyMismatch 'anything' $null) | Should BeNullOrEmpty
    }
    It 'carries readiness.expected from releases.json into the health targets' {
        $sites = @([pscustomobject]@{ id = 'fit-track'; localUrl = 'http://192.168.2.14:8791/'; database = 'postgres' })
        $releases = [pscustomobject]@{ apps = [pscustomobject]@{ 'fit-track' = [pscustomobject]@{ readiness = [pscustomobject]@{ path = '/healthz'; expected = [pscustomobject]@{ status = 'ok' } } } } }
        $target = @(Get-AppHealthTargets -Sites $sites -Releases $releases)[0]
        $target.url | Should Be 'http://192.168.2.14:8791/healthz'
        $target.expected.status | Should Be 'ok'
    }
    It 'fails a stale collector snapshot' {
        $snapshot = [pscustomobject]@{ schemaVersion = 1; generatedAt = '2026-11-27T07:00:00-08:00'; errors = @() }
        (Test-CollectorStatusSnapshot $snapshot $now 30).status | Should Be 'Failed'
    }
    It 'fails a collector snapshot that records errors' {
        $snapshot = [pscustomobject]@{ schemaVersion = 1; generatedAt = '2026-11-27T08:58:00-08:00'; errors = @('stock: timeout') }
        (Test-CollectorStatusSnapshot $snapshot $now 30).detail | Should Match 'stock: timeout'
    }
    It 'fails when the snapshot is missing' {
        (Test-CollectorStatusSnapshot $null $now 30).status | Should Be 'Failed'
    }
}

Describe 'Backup-Postgres identity guard' {
    $tokens = $null
    $parseErrors = $null
    $scriptPath = Join-Path $root 'scripts\Backup-Postgres.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-PostgresBackupIdentity'
        }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))

    function New-FakeQuery([hashtable]$Answers) {
        $values = $Answers
        { param([string]$Sql) $values[$Sql] }.GetNewClosure()
    }
    $script:answers = @{
        'SHOW data_directory;' = 'D:\data\postgres'
        'SELECT system_identifier FROM pg_control_system();' = '7000000000000000001'
        'SHOW server_version_num;' = '180006'
    }

    It 'parses cleanly and exposes the expected-cluster parameters' {
        @($parseErrors).Count | Should Be 0
        $parameters = $ast.ParamBlock.Parameters
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ExpectedDataDirectory' }).DefaultValue.Value | Should Be 'D:\data\postgres'
        @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ExpectedClusterId' }).Count | Should Be 1
    }
    It 'runs the guard before the database list is read' {
        $guardCall = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-PostgresBackupIdentity'
            }, $true)
        $listing = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$databases'
            }, $true)
        $guardCall | Should Not BeNullOrEmpty
        ($guardCall.Extent.StartOffset -lt $listing.Extent.StartOffset) | Should Be $true
    }
    It 'returns the observed identity for the manifest' {
        $identity = Assert-PostgresBackupIdentity -Query (New-FakeQuery $script:answers) -PgDumpVersion 'pg_dump (PostgreSQL) 18.1' -ExpectedDataDirectory 'D:\data\postgres' -ExpectedClusterId '7000000000000000001'
        $identity.systemIdentifier | Should Be '7000000000000000001'
        $identity.serverMajor | Should Be 18
    }
    It 'refuses a data directory reset to the installer default' {
        $answers = @{} + $script:answers
        $answers['SHOW data_directory;'] = 'C:\Program Files\PostgreSQL\18\data'
        { Assert-PostgresBackupIdentity -Query (New-FakeQuery $answers) -PgDumpVersion 'pg_dump (PostgreSQL) 18.1' -ExpectedDataDirectory 'D:\data\postgres' } | Should Throw 'not'
    }
    It 'accepts the expected data directory written with a trailing slash' {
        $answers = @{} + $script:answers
        $answers['SHOW data_directory;'] = 'D:/data/postgres/'
        { Assert-PostgresBackupIdentity -Query (New-FakeQuery $answers) -PgDumpVersion 'pg_dump (PostgreSQL) 18.1' -ExpectedDataDirectory 'D:\data\postgres' -ExpectedClusterId '7000000000000000001' } | Should Not Throw
    }
    It 'refuses a cluster identifier that differs from the expected one' {
        { Assert-PostgresBackupIdentity -Query (New-FakeQuery $script:answers) -PgDumpVersion 'pg_dump (PostgreSQL) 18.1' -ExpectedDataDirectory 'D:\data\postgres' -ExpectedClusterId '7000000000000000009' } | Should Throw 'does not match'
    }
    It 'pins the cluster from cluster-id.txt when -ExpectedClusterId is not passed' {
        $file = Join-Path $TestDrive 'cluster-id.txt'
        [IO.File]::WriteAllText($file, "7000000000000000001`r`n")
        $identity = Assert-PostgresBackupIdentity -Query (New-FakeQuery $script:answers) -PgDumpVersion 'pg_dump (PostgreSQL) 18.1' -ExpectedDataDirectory 'D:\data\postgres' -ClusterIdFile $file
        $identity.systemIdentifier | Should Be '7000000000000000001'
        [IO.File]::WriteAllText($file, "7000000000000000009`n")
        { Assert-PostgresBackupIdentity -Query (New-FakeQuery $script:answers) -PgDumpVersion 'pg_dump (PostgreSQL) 18.1' -ExpectedDataDirectory 'D:\data\postgres' -ClusterIdFile $file } | Should Throw 'does not match'
    }
    It 'refuses to run unattended without a pinned cluster and names the observed system_identifier' {
        $missing = Join-Path $TestDrive 'pin\cluster-id.txt'
        $message = $null
        try { Assert-PostgresBackupIdentity -Query (New-FakeQuery $script:answers) -PgDumpVersion 'pg_dump (PostgreSQL) 18.1' -ExpectedDataDirectory 'D:\data\postgres' -ClusterIdFile $missing }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'system_identifier 7000000000000000001'
        $message | Should Match 'cluster-id\.txt'
    }
    It 'prefers -ExpectedClusterId over the pinned file' {
        $file = Join-Path $TestDrive 'pinned-elsewhere.txt'
        [IO.File]::WriteAllText($file, '7000000000000000009')
        (Assert-PostgresBackupIdentity -Query (New-FakeQuery $script:answers) -PgDumpVersion 'pg_dump (PostgreSQL) 18.1' -ExpectedDataDirectory 'D:\data\postgres' -ExpectedClusterId '7000000000000000001' -ClusterIdFile $file).systemIdentifier | Should Be '7000000000000000001'
    }
    It 'refuses a pg_dump whose major version differs from the server' {
        { Assert-PostgresBackupIdentity -Query (New-FakeQuery $script:answers) -PgDumpVersion 'pg_dump (PostgreSQL) 17.5' -ExpectedDataDirectory 'D:\data\postgres' -ExpectedClusterId '7000000000000000001' -ClusterIdFile (Join-Path $TestDrive 'none.txt') } | Should Throw 'pg_dump is 17'
    }
}
