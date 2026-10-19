$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\PostgreSQL.psm1') -Force -DisableNameChecking

Describe 'Separate metadata and mutation identities' {
    BeforeEach {
        Mock Import-Module {}
        Mock Get-CimInstance {@{UUID='synthetic-host'}}
        $script:snapshot=@{
            hostIdentity='synthetic-host';serverVersionNum=180000;serverSystemIdentifier='synthetic-cluster'
            databases=@('postgres','test_app');roles=@('postgres_metadata','sd_test_app_migrator')
        }
        Mock Get-PostgresSnapshot {
            @{
                hostIdentity='synthetic-host';serverVersionNum=180000;serverSystemIdentifier='synthetic-cluster'
                databases=@('postgres','test_app');roles=@('postgres_metadata','sd_test_app_migrator')
            }
        }
        Mock Invoke-PostgresReviewedSql {}
        $script:plan=@{
            target=@{host=$env:COMPUTERNAME};hostSnapshot=@{identity='synthetic-host'}
            manifest=@{database=@{name='test_app'}}
        }
        $script:plan.planHash=Get-PlanDigest $script:plan
        $script:planPath=Join-Path $TestDrive 'plan.json'
        Write-DeploymentJson $script:planPath $script:plan
        $script:snapshotPath=Join-Path $TestDrive 'snapshot.json'
        Write-DeploymentJson $script:snapshotPath $script:snapshot
        $script:tools=Join-Path $TestDrive 'tools'
        [IO.Directory]::CreateDirectory($script:tools)|Out-Null
        [IO.File]::WriteAllText((Join-Path $script:tools 'psql.exe'),'non-executable synthetic fixture')
        $script:approval=@{
            planHash=$script:plan.planHash;action='ApplySql';hostIdentity='synthetic-host';database='test_app'
            independentReview='synthetic action review';expiresLocal=[DateTimeOffset]::Now.AddHours(1).ToString('o')
            toolSHA256=(Get-FileHash (Join-Path $script:tools 'psql.exe')).Hash.ToLowerInvariant()
            userName='sd_test_app_migrator';snapshotUserName='postgres_metadata';sqlSHA256='synthetic-sql-hash'
            targetDatabase='test_app';transactional=$true
            snapshotSHA256=(Get-FileHash $script:snapshotPath).Hash.ToLowerInvariant()
        }
        $script:approvalPath=Join-Path $TestDrive 'approval.json'
        Write-DeploymentJson $script:approvalPath $script:approval
        $script:arguments=@{
            Action='ApplySql';PlanPath=$script:planPath;ToolDirectory=$script:tools;PassFile='C:\synthetic\migrator.pgpass'
            UserName='sd_test_app_migrator';OutputPath=(Join-Path $TestDrive 'journal.json')
            SnapshotPath=$script:snapshotPath;ApprovalPath=$script:approvalPath;SqlPath='C:\synthetic\schema.sql'
            Database='test_app';OwnerRole='sd_test_app_owner';Transactional=$true;Execute=$true
        }
    }
    It 'checks catalog drift with metadata credentials but executes DDL as the app migrator' {
        & (Join-Path $root 'scripts\Manage-Postgres.ps1') @script:arguments -SnapshotUserName postgres_metadata -SnapshotPassFile 'C:\synthetic\metadata.pgpass'
        Assert-MockCalled Get-PostgresSnapshot -Scope It -Times 1 -ParameterFilter {
            $UserName -eq 'postgres_metadata' -and $PassFile -eq 'C:\synthetic\metadata.pgpass'
        }
        Assert-MockCalled Invoke-PostgresReviewedSql -Scope It -Times 1 -ParameterFilter {
            $UserName -eq 'sd_test_app_migrator' -and $PassFile -eq 'C:\synthetic\migrator.pgpass' -and $OwnerRole -eq 'sd_test_app_owner'
        }
    }
    It 'rejects a metadata identity that differs from approval before executing SQL' {
        $thrown=$false
        try {
            & (Join-Path $root 'scripts\Manage-Postgres.ps1') @script:arguments -SnapshotUserName other_account -SnapshotPassFile 'C:\synthetic\metadata.pgpass'
        } catch {$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Invoke-PostgresReviewedSql -Scope It -Times 0
    }
    It 'rejects omitted metadata credentials before executing SQL' {
        $thrown=$false
        try {& (Join-Path $root 'scripts\Manage-Postgres.ps1') @script:arguments} catch {$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Invoke-PostgresReviewedSql -Scope It -Times 0
    }
}

Describe 'Central database host binding for database actions' {
    BeforeEach {
        Mock Import-Module {}
        Mock Get-CimInstance {@{UUID='synthetic-db-host'}}
        Mock Get-PostgresSnapshot {
            @{hostIdentity='synthetic-db-host';serverVersionNum=180000;serverSystemIdentifier='synthetic-cluster'
                databases=@('postgres','test_app');roles=@('postgres_metadata','sd_test_app_migrator')}
        }
        Mock Invoke-PostgresReviewedSql {}
        Mock Get-PostgresDatabaseEvidence {@{schemaFingerprint=('c'*64)}}
        $script:plan=@{
            target=@{host='synthetic-apphost'};hostSnapshot=@{identity='synthetic-app-host'}
            databaseTarget=@{host=$env:COMPUTERNAME;address='192.168.2.14';root='C:\ProgramData\SolutionDeploy';port=5433;serverName=$env:COMPUTERNAME.ToLowerInvariant();remoteSslMode='verify-full'}
            databaseHostSnapshot=@{identity='synthetic-db-host';host=$env:COMPUTERNAME;address='192.168.2.14';verified=$true}
            solutionDatabases=@('test_app','other_app')
            manifest=@{id='test-app';database=@{name='test_app'}}
        }
        $script:snapshot=@{hostIdentity='synthetic-db-host';serverVersionNum=180000;serverSystemIdentifier='synthetic-cluster'
            databases=@('postgres','test_app');roles=@('postgres_metadata','sd_test_app_migrator')}
        $script:snapshotPath=Join-Path $TestDrive 'snapshot.json'
        Write-DeploymentJson $script:snapshotPath $script:snapshot
        $script:tools=Join-Path $TestDrive 'tools'
        [IO.Directory]::CreateDirectory($script:tools)|Out-Null
        [IO.File]::WriteAllText((Join-Path $script:tools 'psql.exe'),'non-executable synthetic fixture')
        function script:Write-Plan {
            $script:plan.planHash=Get-PlanDigest $script:plan
            $script:planPath=Join-Path $TestDrive 'plan.json'
            Write-DeploymentJson $script:planPath $script:plan
        }
        function script:Write-Approval([string]$Action,[string]$UserName,[string]$HostIdentity='synthetic-db-host') {
            $approval=@{
                planHash=$script:plan.planHash;action=$Action;hostIdentity=$HostIdentity;database='test_app'
                independentReview='synthetic action review';expiresLocal=[DateTimeOffset]::Now.AddHours(1).ToString('o')
                toolSHA256=(Get-FileHash (Join-Path $script:tools 'psql.exe')).Hash.ToLowerInvariant()
                userName=$UserName;snapshotUserName='postgres_metadata';sqlSHA256='synthetic-sql-hash'
                targetDatabase='test_app';transactional=$true
                snapshotSHA256=(Get-FileHash $script:snapshotPath).Hash.ToLowerInvariant()
            }
            $script:approvalPath=Join-Path $TestDrive 'approval.json'
            Write-DeploymentJson $script:approvalPath $approval
        }
        function script:Invoke-ApplySql {
            & (Join-Path $root 'scripts\Manage-Postgres.ps1') -Action ApplySql -PlanPath $script:planPath -ToolDirectory $script:tools `
                -PassFile 'C:\synthetic\migrator.pgpass' -UserName 'sd_test_app_migrator' -OutputPath (Join-Path $TestDrive 'journal.json') `
                -SnapshotPath $script:snapshotPath -ApprovalPath $script:approvalPath -SqlPath 'C:\synthetic\schema.sql' -Database 'test_app' `
                -OwnerRole 'sd_test_app_owner' -Transactional -Execute -SnapshotUserName postgres_metadata -SnapshotPassFile 'C:\synthetic\metadata.pgpass'
        }
    }
    It 'runs on the database host with its identity and port while the app targets another host' {
        Write-Plan;Write-Approval 'ApplySql' 'sd_test_app_migrator'
        Invoke-ApplySql
        Assert-MockCalled Get-PostgresSnapshot -Scope It -Times 1 -ParameterFilter {$HostIdentity -eq 'synthetic-db-host' -and $Port -eq 5433}
        Assert-MockCalled Invoke-PostgresReviewedSql -Scope It -Times 1 -ParameterFilter {$Port -eq 5433 -and $UserName -eq 'sd_test_app_migrator'}
    }
    It 'rejects an approval bound to the app host identity' {
        Write-Plan;Write-Approval 'ApplySql' 'sd_test_app_migrator' 'synthetic-app-host'
        $thrown=$false;try{Invoke-ApplySql}catch{$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Invoke-PostgresReviewedSql -Scope It -Times 0
    }
    It 'refuses to run anywhere except the configured database host' {
        $script:plan.databaseTarget.host='synthetic-dbhost';$script:plan.databaseTarget.serverName='synthetic-dbhost';$script:plan.databaseHostSnapshot.host='synthetic-dbhost'
        $script:plan.target.host=$env:COMPUTERNAME
        Write-Plan;Write-Approval 'ApplySql' 'sd_test_app_migrator'
        $thrown=$false;try{Invoke-ApplySql}catch{$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Invoke-PostgresReviewedSql -Scope It -Times 0
    }
    It 'refuses a database host whose identity does not match the verified snapshot' {
        Mock Get-CimInstance {@{UUID='synthetic-app-host'}}
        Write-Plan;Write-Approval 'ApplySql' 'sd_test_app_migrator'
        $thrown=$false;try{Invoke-ApplySql}catch{$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Invoke-PostgresReviewedSql -Scope It -Times 0
    }
    It 'collects loopback evidence with the plan database list and port' {
        Write-Plan;Write-Approval 'Evidence' 'sd_test_app_runtime'
        & (Join-Path $root 'scripts\Manage-Postgres.ps1') -Action Evidence -PlanPath $script:planPath -ToolDirectory $script:tools `
            -PassFile 'C:\synthetic\runtime.pgpass' -UserName 'sd_test_app_runtime' -OutputPath (Join-Path $TestDrive 'evidence.json') -ApprovalPath $script:approvalPath|Out-Null
        Assert-MockCalled Get-PostgresDatabaseEvidence -Scope It -Times 1 -ParameterFilter {
            $Port -eq 5433 -and ($SolutionDatabases -join ',') -eq 'test_app,other_app' -and -not $HostAddress
        }
    }
    It 'rejects a plan database list that omits the application' {
        $script:plan.solutionDatabases=@('other_app')
        Write-Plan;Write-Approval 'Evidence' 'sd_test_app_runtime'
        $thrown=$false
        try{& (Join-Path $root 'scripts\Manage-Postgres.ps1') -Action Evidence -PlanPath $script:planPath -ToolDirectory $script:tools `
            -PassFile 'C:\synthetic\runtime.pgpass' -UserName 'sd_test_app_runtime' -OutputPath (Join-Path $TestDrive 'evidence.json') -ApprovalPath $script:approvalPath}catch{$thrown=$true}
        $thrown|Should Be $true
        Assert-MockCalled Get-PostgresDatabaseEvidence -Scope It -Times 0
    }
}
