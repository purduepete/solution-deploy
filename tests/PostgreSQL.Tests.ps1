$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\PostgreSQL.psm1') -Force -DisableNameChecking
function Assert-Throws([scriptblock]$Action) {
    $thrown=$false
    try{& $Action|Out-Null}catch{$thrown=$true}
    $thrown|Should Be $true
}
Describe 'PostgreSQL identifiers and isolation planning without a database connection' {
    BeforeEach {
        $script:manifest=@{id='ferry-tracker';database=@{engine='postgresql';name='ferry_tracker';schemaVersion=1}}
        $script:snapshot=@{hostIdentity='host-1';serverVersion='18.0';serverSystemIdentifier='12345';databases=@('postgres');roles=@('postgres')}
    }
    It 'allocates separate owner migrator and runtime identities' {
        $roles=Get-PostgresRoleNames 'ferry_tracker'
        $roles.owner|Should Be 'sd_ferry_tracker_owner'
        $roles.migrator|Should Be 'sd_ferry_tracker_migrator'
        $roles.runtime|Should Be 'sd_ferry_tracker_runtime'
    }
    It 'refuses SQL-shaped identifiers' {
        Assert-Throws{Get-PostgresRoleNames 'ferry";DROP DATABASE postgres;--'}
    }
    It 'refuses long role names' {
        Assert-Throws{Get-PostgresRoleNames ('a'*41)}
    }
    It 'requires reviewed ownership of any existing database' {
        $script:snapshot.databases+= 'ferry_tracker'
        Assert-Throws{Get-PostgresProvisioningPlan $script:manifest $script:snapshot}
    }
    It 'requires reviewed ownership of colliding runtime roles' {
        $script:snapshot.roles+='sd_ferry_tracker_runtime'
        Assert-Throws{Get-PostgresProvisioningPlan $script:manifest $script:snapshot}
    }
    It 'plans nontransactional creation without superuser or password literals' {
        $plan=Get-PostgresProvisioningPlan $script:manifest $script:snapshot
        $plan.transactional|Should Be $false
        $plan.provisioningSql.Contains('NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION')|Should Be $true
        $plan.provisioningSql.Contains('REVOKE ALL ON DATABASE "ferry_tracker" FROM PUBLIC;')|Should Be $true
        $plan.provisioningSql.Contains('PASSWORD')|Should Be $false
        $plan.runtimeGrantsSql.Contains('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.solutiondeploy_schema')|Should Be $true
        $plan.runtimeGrantsSql.Contains("IF to_regclass('public.solutiondeploy_import') IS NOT NULL")|Should Be $true
        $plan.runtimeGrantsSql.Contains('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.solutiondeploy_import FROM "sd_ferry_tracker_runtime";')|Should Be $true
        $plan.runtimeGrantsSql.Contains('GRANT CREATE')|Should Be $false
    }
    It 'keeps runtime out of the owner membership grant' {
        $plan=Get-PostgresProvisioningPlan $script:manifest $script:snapshot
        $plan.provisioningSql.Contains('GRANT "sd_ferry_tracker_owner" TO "sd_ferry_tracker_migrator";')|Should Be $true
        $plan.provisioningSql.Contains('GRANT "sd_ferry_tracker_owner" TO "sd_ferry_tracker_runtime"')|Should Be $false
    }
    It 'rejects incomplete server identity evidence' {
        $script:snapshot.Remove('serverSystemIdentifier')
        Assert-Throws{Get-PostgresProvisioningPlan $script:manifest $script:snapshot}
    }
    It 'uses the site_dock allocation for the database and all three roles' {
        $manifest=@{id='site-dock';database=@{engine='postgresql';name='site_dock';schemaVersion=1}}
        $plan=Get-PostgresProvisioningPlan $manifest $script:snapshot
        $plan.database|Should Be 'site_dock'
        $plan.roles.owner|Should Be 'sd_site_dock_owner'
        $plan.roles.migrator|Should Be 'sd_site_dock_migrator'
        $plan.roles.runtime|Should Be 'sd_site_dock_runtime'
        $plan.provisioningSql.Contains('CREATE DATABASE "site_dock" OWNER "sd_site_dock_owner"')|Should Be $true
    }
}

Describe 'SiteDock allocation in runtime isolation evidence' {
    BeforeEach {
        Mock Invoke-PostgresTool -ModuleName PostgreSQL {
            '{"database":"ferry_tracker","runtimeRole":"sd_ferry_tracker_runtime","schemaVersion":1,"privilegedRole":false,"ownerMember":false,"migratorMember":false,"canAlterLedger":false,"canAlterImportLedger":false,"canCreateSchema":false,"canCreatePublic":false,"schemaDefinition":{},"crossSolutionConnect":[]}'
        }
    }
    It 'checks cross-solution access against site_dock rather than the superseded name' {
        $manifest=@{id='ferry-tracker';database=@{name='ferry_tracker';schemaVersion=1}}
        Get-PostgresDatabaseEvidence $manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime'|Out-Null
        Assert-MockCalled Invoke-PostgresTool -ModuleName PostgreSQL -Scope It -Times 1 -ParameterFilter {
            $Arguments[-1].Contains("datname IN ('ferry_tracker','home_automation','site_dock')")
        }
    }
    It 'rejects runtime access to the renamed SiteDock database' {
        Mock Invoke-PostgresTool -ModuleName PostgreSQL {
            '{"database":"ferry_tracker","runtimeRole":"sd_ferry_tracker_runtime","schemaVersion":1,"privilegedRole":false,"ownerMember":false,"migratorMember":false,"canAlterLedger":false,"canAlterImportLedger":false,"canCreateSchema":false,"canCreatePublic":false,"schemaDefinition":{},"crossSolutionConnect":["site_dock"]}'
        }
        $manifest=@{id='ferry-tracker';database=@{name='ferry_tracker';schemaVersion=1}}
        Assert-Throws{Get-PostgresDatabaseEvidence $manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime'}
    }
}

Describe 'Import provenance runtime isolation' {
    It 'refuses runtime write access to the import ledger' {
        Mock Invoke-PostgresTool -ModuleName PostgreSQL {
            '{"database":"ferry_tracker","runtimeRole":"sd_ferry_tracker_runtime","schemaVersion":1,"privilegedRole":false,"ownerMember":false,"migratorMember":false,"canAlterLedger":false,"canAlterImportLedger":true,"canCreateSchema":false,"canCreatePublic":false,"schemaDefinition":{},"crossSolutionConnect":[]}'
        }
        $manifest=@{id='ferry-tracker';database=@{name='ferry_tracker';schemaVersion=1}}
        Assert-Throws{Get-PostgresDatabaseEvidence $manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime'}
    }
    It 'refuses incomplete provenance privilege evidence' {
        Mock Invoke-PostgresTool -ModuleName PostgreSQL {
            '{"database":"ferry_tracker","runtimeRole":"sd_ferry_tracker_runtime","schemaVersion":1,"privilegedRole":false,"ownerMember":false,"migratorMember":false,"canAlterLedger":false,"canCreateSchema":false,"canCreatePublic":false,"schemaDefinition":{},"crossSolutionConnect":[]}'
        }
        $manifest=@{id='ferry-tracker';database=@{name='ferry_tracker';schemaVersion=1}}
        Assert-Throws{Get-PostgresDatabaseEvidence $manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime'}
    }
}

Describe 'Reviewed SQL execution gates without connecting to PostgreSQL' {
    BeforeEach {
        $script:sqlPath=Join-Path $TestDrive 'reviewed.sql'
        [IO.File]::WriteAllText($script:sqlPath,'SELECT 1;')
        $script:hash=(Get-FileHash -LiteralPath $script:sqlPath).Hash.ToLowerInvariant()
    }
    It 'previews reviewed SQL without starting any process' {
        $result=Invoke-PostgresReviewedSql -PsqlPath 'C:\not-installed\psql.exe' -PassFile 'C:\not-installed\pgpass' -UserName 'postgres' -Database 'postgres' -SqlPath $script:sqlPath -ApprovedSHA256 $script:hash -JournalPath (Join-Path $TestDrive 'journal.json') -IndependentReviewReference 'synthetic-review-only'
        $result.status|Should Be 'Preview'
        Test-Path -LiteralPath (Join-Path $TestDrive 'journal.json')|Should Be $false
    }
    It 'rejects script drift before execution' {
        [IO.File]::AppendAllText($script:sqlPath,'SELECT 2;')
        Assert-Throws{Invoke-PostgresReviewedSql -PsqlPath 'C:\not-installed\psql.exe' -PassFile 'C:\not-installed\pgpass' -UserName 'postgres' -Database 'postgres' -SqlPath $script:sqlPath -ApprovedSHA256 $script:hash -JournalPath (Join-Path $TestDrive 'journal.json') -IndependentReviewReference 'review'}
    }
    It 'requires an independent review reference' {
        Assert-Throws{Invoke-PostgresReviewedSql -PsqlPath 'C:\not-installed\psql.exe' -PassFile 'C:\not-installed\pgpass' -UserName 'postgres' -Database 'postgres' -SqlPath $script:sqlPath -ApprovedSHA256 $script:hash -JournalPath (Join-Path $TestDrive 'journal.json') -IndependentReviewReference ' '}
    }
    It 'blocks replay when a prior SQL action may have run' {
        $journal=Join-Path $TestDrive 'prior.json'
        [IO.File]::WriteAllText($journal,'{"status":"Running"}')
        Assert-Throws{Invoke-PostgresReviewedSql -PsqlPath 'C:\not-installed\psql.exe' -PassFile 'C:\not-installed\pgpass' -UserName 'postgres' -Database 'postgres' -SqlPath $script:sqlPath -ApprovedSHA256 $script:hash -JournalPath $journal -IndependentReviewReference 'review' -Execute}
    }
    It 'forbids validation restore over an application database' {
        Assert-Throws{Restore-PostgresValidationDatabase -PgRestorePath 'C:\not-installed\pg_restore.exe' -PassFile 'C:\not-installed\pgpass' -UserName 'postgres' -Database 'ferry_tracker' -BackupPath 'C:\not-installed\backup' -ApprovedBackupSHA256 'abc' -ApprovedPsqlSHA256 'hash' -JournalPath (Join-Path $TestDrive 'restore.json') -IndependentReviewReference 'review' -Execute}
    }
    It 'rejects nonloopback database tools' {
        Assert-Throws{Invoke-PostgresTool -ToolPath 'C:\not-installed\psql.exe' -Arguments @('-X') -PassFile 'C:\not-installed\pgpass' -HostName '192.168.2.14' -UserName 'postgres' -Database 'postgres'}
    }
}

function New-SeparatedPlan {
    @{
        target=@{host='jimbrownhome';address='192.168.2.11'};hostSnapshot=@{identity='synthetic-app-host'}
        databaseTarget=@{host='jimbrownhome1';address='192.168.2.14';root='C:\ProgramData\SolutionDeploy';port=5432;serverName='jimbrownhome1';remoteSslMode='verify-full'}
        databaseHostSnapshot=@{identity='synthetic-db-host';host='jimbrownhome1';address='192.168.2.14';verified=$true}
    }
}

Describe 'Central database host connection policy' {
    It 'connects a separate app host to the verified database host with pinned verify-full transport' {
        $policy=Get-PostgresConnectionPolicy -Plan (New-SeparatedPlan)
        $policy.Mode|Should Be 'Remote'
        $policy.HostName|Should Be 'jimbrownhome1'
        $policy.HostAddress|Should Be '192.168.2.14'
        $policy.Port|Should Be 5432
        $policy.SslMode|Should Be 'verify-full'
        $policy.ServerName|Should Be 'jimbrownhome1'
        $policy.DatabaseHost|Should Be 'jimbrownhome1'
        $policy.DatabaseHostIdentity|Should Be 'synthetic-db-host'
        $policy.ClientHost|Should Be 'jimbrownhome'
        $policy.EndpointSHA256|Should Be (Get-PostgresEndpointDigest -HostName 'jimbrownhome1' -HostAddress '192.168.2.14' -Port 5432 -SslMode 'verify-full')
    }
    It 'uses loopback when the app is deployed on the database host' {
        $plan=New-SeparatedPlan;$plan.target=@{host='JIMBROWNHOME1'};$plan.hostSnapshot=@{identity='synthetic-db-host'}
        $policy=Get-PostgresConnectionPolicy -Plan $plan
        $policy.Mode|Should Be 'Loopback'
        $policy.HostName|Should Be '127.0.0.1'
        $policy.HostAddress|Should BeNullOrEmpty
        $policy.SslMode|Should BeNullOrEmpty
    }
    It 'uses loopback for the database host itself regardless of the app host' {
        (Get-PostgresConnectionPolicy -Plan (New-SeparatedPlan) -ClientHost 'jimbrownhome1').Mode|Should Be 'Loopback'
    }
    It 'keeps plans without databaseTarget on the original colocated loopback contract' {
        $policy=Get-PostgresConnectionPolicy -Plan @{target=@{host='jimbrownhome1'};hostSnapshot=@{identity='legacy-host'}}
        $policy.Mode|Should Be 'Loopback'
        $policy.Legacy|Should Be $true
        $policy.DatabaseHost|Should Be 'jimbrownhome1'
        $policy.DatabaseHostIdentity|Should Be 'legacy-host'
        $policy.Port|Should Be 5432
        Assert-Throws{Get-PostgresConnectionPolicy -Plan @{target=@{host='jimbrownhome1'};hostSnapshot=@{identity='legacy-host'}} -ClientHost 'jimbrownhome'}
    }
    It 'reads the configured port from the plan' {
        $plan=New-SeparatedPlan;$plan.databaseTarget.port=[long]5433
        (Get-PostgresConnectionPolicy -Plan $plan).Port|Should Be 5433
    }
    It 'binds the endpoint hash to the address' {
        $plan=New-SeparatedPlan;$other=New-SeparatedPlan
        $other.databaseTarget.address='192.168.2.15';$other.databaseHostSnapshot.address='192.168.2.15'
        (Get-PostgresConnectionPolicy -Plan $plan).EndpointSHA256|Should Not Be (Get-PostgresConnectionPolicy -Plan $other).EndpointSHA256
    }
    $cases=@(
        @{name='public address';edit={param($p)$p.databaseTarget.address='8.8.8.8';$p.databaseHostSnapshot.address='8.8.8.8'}}
        @{name='abbreviated address';edit={param($p)$p.databaseTarget.address='192.168.2';$p.databaseHostSnapshot.address='192.168.2'}}
        @{name='weaker TLS mode';edit={param($p)$p.databaseTarget.remoteSslMode='require'}}
        @{name='unverified database host';edit={param($p)$p.databaseHostSnapshot.verified=$false}}
        @{name='snapshot address drift';edit={param($p)$p.databaseHostSnapshot.address='192.168.2.11'}}
        @{name='snapshot host drift';edit={param($p)$p.databaseHostSnapshot.host='jimbrownhome'}}
        @{name='missing snapshot';edit={param($p)$p.Remove('databaseHostSnapshot')}}
        @{name='empty identity';edit={param($p)$p.databaseHostSnapshot.identity=' '}}
        @{name='server name for another host';edit={param($p)$p.databaseTarget.serverName='jimbrownhome'}}
        @{name='server name as IP';edit={param($p)$p.databaseTarget.serverName='192.168.2.14'}}
        @{name='privileged port';edit={param($p)$p.databaseTarget.port=80}}
        @{name='relative root';edit={param($p)$p.databaseTarget.root='ProgramData'}}
        @{name='missing serverName';edit={param($p)$p.databaseTarget.Remove('serverName')}}
        @{name='colocated identity disagreement';edit={param($p)$p.target.host='jimbrownhome1';$p.hostSnapshot.identity='other'}}
    )
    foreach($case in $cases){
        It "fails closed on $($case.name)" {
            $plan=New-SeparatedPlan;& $case.edit $plan
            Assert-Throws{Get-PostgresConnectionPolicy -Plan $plan}
        }
    }
    It 'accepts a fully qualified server name for the database host' {
        $plan=New-SeparatedPlan;$plan.databaseTarget.serverName='jimbrownhome1.home.arpa'
        (Get-PostgresConnectionPolicy -Plan $plan).HostName|Should Be 'jimbrownhome1.home.arpa'
    }
    It 'builds remote connection parameters only for the approved endpoint hash' {
        $policy=Get-PostgresConnectionPolicy -Plan (New-SeparatedPlan)
        $parameters=Get-PostgresConnectionParameters -Policy $policy -ApprovedEndpointSHA256 $policy.EndpointSHA256 -SslRootCert 'C:\synthetic\root.crt' -SslRootCertSHA256 ('a'*64)
        $parameters.HostName|Should Be 'jimbrownhome1'
        $parameters.HostAddress|Should Be '192.168.2.14'
        $parameters.Port|Should Be 5432
        $parameters.SslRootCert|Should Be 'C:\synthetic\root.crt'
        $parameters.EndpointSHA256|Should Be $policy.EndpointSHA256
        Assert-Throws{Get-PostgresConnectionParameters -Policy $policy -ApprovedEndpointSHA256 ('b'*64) -SslRootCert 'C:\synthetic\root.crt' -SslRootCertSHA256 ('a'*64)}
        Assert-Throws{Get-PostgresConnectionParameters -Policy $policy -ApprovedEndpointSHA256 $policy.EndpointSHA256}
        $policy.HostAddress='192.168.2.11'
        Assert-Throws{Get-PostgresConnectionParameters -Policy $policy -ApprovedEndpointSHA256 $policy.EndpointSHA256 -SslRootCert 'C:\synthetic\root.crt' -SslRootCertSHA256 ('a'*64)}
    }
    It 'builds loopback parameters without remote transport settings' {
        $policy=Get-PostgresConnectionPolicy -Plan (New-SeparatedPlan) -ClientHost 'jimbrownhome1'
        $parameters=Get-PostgresConnectionParameters -Policy $policy -ApprovedEndpointSHA256 $policy.EndpointSHA256
        $parameters.HostName|Should Be '127.0.0.1'
        $parameters.ContainsKey('HostAddress')|Should Be $false
        Assert-Throws{Get-PostgresConnectionParameters -Policy $policy -ApprovedEndpointSHA256 $policy.EndpointSHA256 -SslRootCert 'C:\synthetic\root.crt' -SslRootCertSHA256 ('a'*64)}
    }
}

function Get-TestAcl([string]$Path) {[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($Path),[Security.AccessControl.AccessControlSections]::Access)}
function Set-TestAcl([string]$Path,$Acl) {[IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path),$Acl)}
function Add-TestRule([string]$Path,[string]$Sid,[string]$Rights) {
    $acl=Get-TestAcl $Path
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($Sid),$Rights,'Allow'))
    Set-TestAcl $Path $acl
}
function Protect-TestFile([string]$Path) {
    $acl=Get-TestAcl $Path
    $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))){$acl.RemoveAccessRuleAll($rule)|Out-Null}
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','Allow'))
    Set-TestAcl $Path $acl
}

Describe 'Remote read-only transport without starting a PostgreSQL process' {
    BeforeEach {
        Mock Start-PostgresToolProcess -ModuleName PostgreSQL {'ok'}
        $script:psql=Join-Path $TestDrive 'psql.exe'
        $script:pass=Join-Path $TestDrive 'runtime.pgpass'
        $script:root=Join-Path $TestDrive 'root.crt'
        foreach($file in @($script:psql,$script:pass,$script:root)){[IO.File]::WriteAllText($file,'synthetic fixture');Protect-TestFile $file}
        $script:rootHash=(Get-FileHash -LiteralPath $script:root).Hash.ToLowerInvariant()
        $script:endpoint=Get-PostgresEndpointDigest -HostName 'jimbrownhome1' -HostAddress '192.168.2.14' -Port 5432 -SslMode 'verify-full'
        $script:remote=@{ToolPath=$script:psql;Arguments=@('-X','-c','SELECT 1;');PassFile=$script:pass;UserName='sd_ferry_tracker_runtime';Database='ferry_tracker'
            HostName='jimbrownhome1';HostAddress='192.168.2.14';Port=5432;SslRootCert=$script:root;SslRootCertSHA256=$script:rootHash;EndpointSHA256=$script:endpoint}
    }
    It 'pins host address, verify-full, root certificate, and read-only sessions through the environment' {
        Invoke-PostgresTool @script:remote -Capture|Should Be 'ok'
        Assert-MockCalled Start-PostgresToolProcess -ModuleName PostgreSQL -Scope It -Times 1 -ParameterFilter {
            $e=$StartInfo.Environment;$a=@($StartInfo.ArgumentList)
            $e['PGHOST'] -eq 'jimbrownhome1' -and $e['PGHOSTADDR'] -eq '192.168.2.14' -and $e['PGPORT'] -eq '5432' -and
            $e['PGSSLMODE'] -eq 'verify-full' -and $e['PGSSLROOTCERT'] -eq $script:root -and $e['PGGSSENCMODE'] -eq 'disable' -and
            $e['PGSSLCERTMODE'] -eq 'disable' -and $e['PGOPTIONS'].Contains('default_transaction_read_only=on') -and
            $e['PGPASSFILE'] -eq $script:pass -and -not $e.ContainsKey('PGPASSWORD') -and
            '--host' -notin $a -and '192.168.2.14' -notin $a -and $script:pass -notin $a -and ($a -join ' ') -eq '--username sd_ferry_tracker_runtime --no-password -X -c SELECT 1;'
        }
    }
    It 'keeps loopback arguments and environment unchanged and clears inherited TLS overrides' {
        $env:PGSSLMODE='disable'
        try{
            Invoke-PostgresTool -ToolPath $script:psql -Arguments @('-X') -PassFile $script:pass -UserName 'postgres' -Database 'postgres' -Port 5433|Out-Null
        }finally{Remove-Item Env:\PGSSLMODE}
        Assert-MockCalled Start-PostgresToolProcess -ModuleName PostgreSQL -Scope It -Times 1 -ParameterFilter {
            $e=$StartInfo.Environment
            (@($StartInfo.ArgumentList) -join ' ') -eq '--host 127.0.0.1 --port 5433 --username postgres --no-password -X' -and
            -not $e.ContainsKey('PGHOST') -and -not $e.ContainsKey('PGHOSTADDR') -and -not $e.ContainsKey('PGSSLMODE') -and
            $e['PGOPTIONS'] -eq '-c statement_timeout=120000 -c lock_timeout=10000'
        }
    }
    It 'accepts a matching loopback endpoint hash' {
        $hash=Get-PostgresEndpointDigest -HostName '127.0.0.1' -HostAddress '' -Port 5432 -SslMode ''
        Invoke-PostgresTool -ToolPath $script:psql -Arguments @('-X') -PassFile $script:pass -UserName 'postgres' -Database 'postgres' -EndpointSHA256 $hash|Out-Null
        Assert-MockCalled Start-PostgresToolProcess -ModuleName PostgreSQL -Scope It -Times 1
    }
    It 'accepts a root certificate that others can read but not modify' {
        Add-TestRule $script:root 'S-1-5-32-545' 'Read'
        Invoke-PostgresTool @script:remote|Out-Null
        Assert-MockCalled Start-PostgresToolProcess -ModuleName PostgreSQL -Scope It -Times 1
    }
    $rejections=@(
        @{name='missing endpoint hash';edit={param($c)$c.Remove('EndpointSHA256')}}
        @{name='unapproved endpoint hash';edit={param($c)$c.EndpointSHA256='0'*64}}
        @{name='address outside the approved endpoint';edit={param($c)$c.HostAddress='192.168.2.11'}}
        @{name='public address';edit={param($c)$c.HostAddress='8.8.8.8';$c.EndpointSHA256=Get-PostgresEndpointDigest -HostName 'jimbrownhome1' -HostAddress '8.8.8.8' -Port 5432 -SslMode 'verify-full'}}
        @{name='address as server name';edit={param($c)$c.HostName='192.168.2.14';$c.EndpointSHA256=Get-PostgresEndpointDigest -HostName '192.168.2.14' -HostAddress '192.168.2.14' -Port 5432 -SslMode 'verify-full'}}
        @{name='missing pinned address';edit={param($c)$c.Remove('HostAddress')}}
        @{name='missing root certificate';edit={param($c)$c.Remove('SslRootCert')}}
        @{name='root certificate drift';edit={param($c)$c.SslRootCertSHA256='0'*64}}
        @{name='remote backup tool';edit={param($c)$p=Join-Path (Split-Path $c.ToolPath) 'pg_dump.exe';[IO.File]::WriteAllText($p,'x');$c.ToolPath=$p}}
        @{name='broad password file';edit={param($c)Add-TestRule $c.PassFile 'S-1-5-11' 'Read'}}
        @{name='broadly writable root certificate';edit={param($c)Add-TestRule $c.SslRootCert 'S-1-1-0' 'Write'}}
        @{name='loopback with remote settings';edit={param($c)$c.HostName='127.0.0.1';$c.Remove('EndpointSHA256')}}
    )
    foreach($case in $rejections){
        It "rejects $($case.name) before starting a process" {
            & $case.edit $script:remote
            Assert-Throws{Invoke-PostgresTool @script:remote}
            Assert-MockCalled Start-PostgresToolProcess -ModuleName PostgreSQL -Scope It -Times 0
        }
    }
}

function Set-EvidenceJson([string]$Tls,[string]$Address) {
    $json='{"database":"ferry_tracker","runtimeRole":"sd_ferry_tracker_runtime","schemaVersion":1,"transportSsl":'+$Tls+',"serverAddress":"'+$Address+'","privilegedRole":false,"ownerMember":false,"migratorMember":false,"canAlterLedger":false,"canAlterImportLedger":false,"canCreateSchema":false,"canCreatePublic":false,"schemaDefinition":{},"crossSolutionConnect":[]}'
    $global:SyntheticPostgresEvidenceJson=$json
}

Describe 'Runtime evidence endpoint parameters' {
    BeforeEach {
        $script:manifest=@{id='ferry-tracker';database=@{name='ferry_tracker';schemaVersion=1}}
        $script:remote=@{HostName='jimbrownhome1';HostAddress='192.168.2.14';Port=5432;SslRootCert='C:\synthetic\root.crt';SslRootCertSHA256=('a'*64);EndpointSHA256=('b'*64)}
    }
    AfterEach {Remove-Variable -Name SyntheticPostgresEvidenceJson -Scope Global -ErrorAction SilentlyContinue}
    It 'passes the approved remote endpoint to the tool and records it' {
        Set-EvidenceJson 'true' '192.168.2.14';Mock Invoke-PostgresTool -ModuleName PostgreSQL {$global:SyntheticPostgresEvidenceJson}
        $evidence=Get-PostgresDatabaseEvidence $script:manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime' @script:remote
        $evidence.endpoint.mode|Should Be 'Remote'
        $evidence.endpoint.hostAddress|Should Be '192.168.2.14'
        $evidence.endpoint.sslMode|Should Be 'verify-full'
        $evidence.endpoint.endpointSHA256|Should Be ('b'*64)
        Assert-MockCalled Invoke-PostgresTool -ModuleName PostgreSQL -Scope It -Times 1 -ParameterFilter {
            $HostName -eq 'jimbrownhome1' -and $HostAddress -eq '192.168.2.14' -and $Port -eq 5432 -and $SslRootCert -eq 'C:\synthetic\root.crt' -and
            $SslRootCertSHA256 -eq ('a'*64) -and $EndpointSHA256 -eq ('b'*64) -and $Arguments[-1].Contains('pg_stat_ssl') -and $Arguments[-1].Contains('inet_server_addr()')
        }
    }
    It 'rejects remote evidence that the server did not receive over TLS' {
        Set-EvidenceJson 'false' '192.168.2.14';Mock Invoke-PostgresTool -ModuleName PostgreSQL {$global:SyntheticPostgresEvidenceJson}
        Assert-Throws{Get-PostgresDatabaseEvidence $script:manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime' @script:remote}
    }
    It 'rejects remote evidence answered on another server address' {
        Set-EvidenceJson 'true' '192.168.2.11';Mock Invoke-PostgresTool -ModuleName PostgreSQL {$global:SyntheticPostgresEvidenceJson}
        Assert-Throws{Get-PostgresDatabaseEvidence $script:manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime' @script:remote}
    }
    It 'keeps the default local call on loopback' {
        Set-EvidenceJson 'null' '127.0.0.1';Mock Invoke-PostgresTool -ModuleName PostgreSQL {$global:SyntheticPostgresEvidenceJson}
        $evidence=Get-PostgresDatabaseEvidence $script:manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime'
        $evidence.endpoint.mode|Should Be 'Loopback'
        Assert-MockCalled Invoke-PostgresTool -ModuleName PostgreSQL -Scope It -Times 1 -ParameterFilter {
            $HostName -eq '127.0.0.1' -and $Port -eq 5432 -and -not $HostAddress -and -not $SslRootCert -and -not $EndpointSHA256
        }
    }
    It 'uses the environment-supplied managed database list' {
        Set-EvidenceJson 'null' '127.0.0.1';Mock Invoke-PostgresTool -ModuleName PostgreSQL {$global:SyntheticPostgresEvidenceJson}
        Get-PostgresDatabaseEvidence $script:manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime' -SolutionDatabases @('ferry_tracker','site_dock','new_app')|Out-Null
        Assert-MockCalled Invoke-PostgresTool -ModuleName PostgreSQL -Scope It -Times 1 -ParameterFilter {$Arguments[-1].Contains("datname IN ('ferry_tracker','site_dock','new_app')")}
        Assert-Throws{Get-PostgresDatabaseEvidence $script:manifest 'C:\synthetic\psql.exe' 'C:\synthetic\pgpass' 'sd_ferry_tracker_runtime' -SolutionDatabases @('bad;name')}
    }
}

Describe 'Runtime DATABASE_URL validation against the approved endpoint' {
    BeforeEach {
        $script:policy=Get-PostgresConnectionPolicy -Plan (New-SeparatedPlan)
        $script:good='postgresql://sd_ferry_tracker_runtime:synthetic-not-a-secret@jimbrownhome1:5432/ferry_tracker?sslmode=verify-full&hostaddr=192.168.2.14&gssencmode=disable&sslrootcert=C%3A%5CProgramData%5CSolutionDeploy%5Croot.crt'
    }
    It 'accepts the pinned verify-full endpoint and never returns the password' {
        $result=Assert-PostgresRuntimeConnectionString -ConnectionString $script:good -Policy $script:policy -Database 'ferry_tracker' -RuntimeRole 'sd_ferry_tracker_runtime' -SslRootCert 'C:\ProgramData\SolutionDeploy\root.crt'
        $result.mode|Should Be 'Remote'
        $result.hostAddress|Should Be '192.168.2.14'
        $result.sslRootCert|Should Be 'C:\ProgramData\SolutionDeploy\root.crt'
        $result.endpointSHA256|Should Be $script:policy.EndpointSHA256
        ($result|ConvertTo-Json -Compress).Contains('synthetic-not-a-secret')|Should Be $false
    }
    It 'withholds the URL from failure messages' {
        $message=''
        try{Assert-PostgresRuntimeConnectionString -ConnectionString $script:good.Replace('verify-full','require') -Policy $script:policy -Database 'ferry_tracker' -RuntimeRole 'sd_ferry_tracker_runtime'}catch{$message=$_.Exception.Message}
        $message.Contains('synthetic-not-a-secret')|Should Be $false
        $message|Should Not BeNullOrEmpty
    }
    $urlCases=@(
        @{name='weaker sslmode';from='sslmode=verify-full';to='sslmode=require'}
        @{name='missing hostaddr pin';from='&hostaddr=192.168.2.14';to=''}
        @{name='other hostaddr';from='hostaddr=192.168.2.14';to='hostaddr=192.168.2.11'}
        @{name='IP as host';from='@jimbrownhome1:';to='@192.168.2.14:'}
        @{name='other host';from='@jimbrownhome1:';to='@jimbrownhome:'}
        @{name='other port';from=':5432/';to=':5433/'}
        @{name='other database';from='/ferry_tracker?';to='/site_dock?'}
        @{name='other role';from='sd_ferry_tracker_runtime:';to='sd_ferry_tracker_migrator:'}
        @{name='GSS left enabled';from='&gssencmode=disable';to=''}
        @{name='missing root certificate';from='&sslrootcert=C%3A%5CProgramData%5CSolutionDeploy%5Croot.crt';to=''}
        @{name='unlisted options parameter';from='gssencmode=disable';to='gssencmode=disable&options=-c%20role%3Dpostgres'}
        @{name='repeated parameter';from='sslmode=verify-full';to='sslmode=verify-full&sslmode=disable'}
        @{name='multiple hosts';from='@jimbrownhome1:5432/';to='@jimbrownhome1:5432,evil:5432/'}
        @{name='non-postgres scheme';from='postgresql://';to='mysql://'}
    )
    foreach($case in $urlCases){
        It "rejects $($case.name)" {
            Assert-Throws{Assert-PostgresRuntimeConnectionString -ConnectionString $script:good.Replace($case.from,$case.to) -Policy $script:policy -Database 'ferry_tracker' -RuntimeRole 'sd_ferry_tracker_runtime'}
        }
    }
    It 'rejects a root certificate path other than the approved file' {
        Assert-Throws{Assert-PostgresRuntimeConnectionString -ConnectionString $script:good -Policy $script:policy -Database 'ferry_tracker' -RuntimeRole 'sd_ferry_tracker_runtime' -SslRootCert 'C:\Other\root.crt'}
    }
    It 'rejects a policy whose endpoint hash was not recomputed after tampering' {
        $script:policy.Port=5432;$script:policy.EndpointSHA256='0'*64
        Assert-Throws{Assert-PostgresRuntimeConnectionString -ConnectionString $script:good -Policy $script:policy -Database 'ferry_tracker' -RuntimeRole 'sd_ferry_tracker_runtime'}
    }
    It 'accepts loopback for an app on the database host and rejects remote pins there' {
        $loopback=Get-PostgresConnectionPolicy -Plan (New-SeparatedPlan) -ClientHost 'jimbrownhome1'
        $url='postgresql://sd_ferry_tracker_runtime:synthetic@127.0.0.1:5432/ferry_tracker'
        (Assert-PostgresRuntimeConnectionString -ConnectionString $url -Policy $loopback -Database 'ferry_tracker' -RuntimeRole 'sd_ferry_tracker_runtime').mode|Should Be 'Loopback'
        Assert-Throws{Assert-PostgresRuntimeConnectionString -ConnectionString $script:good -Policy $loopback -Database 'ferry_tracker' -RuntimeRole 'sd_ferry_tracker_runtime'}
    }
}
