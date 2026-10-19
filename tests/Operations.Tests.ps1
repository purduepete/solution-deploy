$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Operations.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\PostgreSQL.psm1') -DisableNameChecking
function Assert-Throws([scriptblock]$Action) {
    $thrown=$false
    try{& $Action|Out-Null}catch{$thrown=$true}
    $thrown|Should Be $true
}
Describe 'Database activation evidence gates with no database access' {
    BeforeEach {
        $script:appRoot=Join-Path $TestDrive 'app'
        New-Item -ItemType Directory -Path (Join-Path $script:appRoot 'state') -Force|Out-Null
        $script:tool=Join-Path $TestDrive 'not-an-executable.txt'
        [IO.File]::WriteAllText($script:tool,'A hash-only synthetic fixture. Never execute.')
        $script:plan=@{planHash='plan1';operation='Cutover';manifest=@{database=@{name='ferry_tracker';schemaVersion=1}}}
        $script:record=@{
            planHash='plan1';database='ferry_tracker';sourceTransferSHA256='transfer1';migrationSqlSHA256='sql1'
            schemaFingerprint=('a'*64);parityValidated=$true;backupRestoredAndValidated=$true;independentReview='synthetic-review'
        }
        $path=Join-Path $script:appRoot 'state\database-proof.json'
        Write-DeploymentJson $path $script:record
        $script:approval=@{
            psqlPath=$script:tool;psqlSHA256=(Get-FileHash -LiteralPath $script:tool).Hash.ToLowerInvariant()
            postgresPassFile='not-used';postgresRuntimeRole='sd_ferry_tracker_runtime'
            databaseEvidencePath='database-proof.json';databaseEvidenceSHA256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
            transferSHA256='transfer1'
            expectedSchemaFingerprint=('a'*64);migrationSqlSHA256='sql1'
        }
        Mock Get-PostgresDatabaseEvidence -ModuleName Operations {
            @{database='ferry_tracker';schemaVersion=1;schemaFingerprint=('a'*64)}
        }
    }
    It 'accepts matching imported-state restore and schema evidence' {
        (Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot).database|Should Be 'ferry_tracker'
        Assert-MockCalled Get-PostgresDatabaseEvidence -ModuleName Operations -Times 1 -Exactly -Scope It
    }
    It 'requires import parity before touching the verifier' {
        $script:record.parityValidated=$false
        $path=Join-Path $script:appRoot 'state\database-proof.json';Write-DeploymentJson $path $script:record
        $script:approval.databaseEvidenceSHA256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        Assert-Throws {Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot}
        Assert-MockCalled Get-PostgresDatabaseEvidence -ModuleName Operations -Times 0 -Exactly -Scope It
    }
    It 'rejects a source snapshot different from the validated PostgreSQL import' {
        $script:approval.transferSHA256='different'
        Assert-Throws {Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot}
    }
    It 'rejects an owner or superuser identity substituted for the runtime role' {
        $script:approval.postgresRuntimeRole='postgres'
        Assert-Throws {Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot}
    }
    It 'rejects a changed live schema fingerprint' {
        Mock Get-PostgresDatabaseEvidence -ModuleName Operations {@{schemaFingerprint=('b'*64)}}
        Assert-Throws {Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot}
    }
    It 'rejects escaped database-proof paths' {
        $script:approval.databaseEvidencePath='..\..\outside.json'
        Assert-Throws {Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot}
    }
    Context 'Host-aware runtime configuration and preserved central data' {
        BeforeEach {
            $script:plan.schemaVersion=2
            $script:plan.transitionKind='ManagedMove'
            $script:plan.target=@{host='jimbrownhome1';address='192.168.2.14'}
            $script:plan.hostSnapshot=@{host='jimbrownhome1';address='192.168.2.14';identity='db-uuid';verified=$true}
            $script:plan.databaseTarget=@{host='jimbrownhome1';address='192.168.2.14';root='C:\ProgramData\SolutionDeploy';port=5432;serverName='jimbrownhome1';remoteSslMode='verify-full'}
            $script:plan.databaseHostSnapshot=@{host='jimbrownhome1';address='192.168.2.14';identity='db-uuid';verified=$true}
            $script:plan.solutionDatabases=@('ferry_tracker','home_automation','site_dock')
            $script:record.transitionKind='ManagedMove'
            $script:record.databaseHost='jimbrownhome1'
            $script:record.databaseHostIdentity='db-uuid'
            $script:record.legacyImportPerformed=$false
            $script:record.sourceTransferSHA256=$null
            $script:record.centralDatabasePreserved=$true
            $path=Join-Path $script:appRoot 'state\database-proof.json'
            Write-DeploymentJson $path $script:record
            $script:approval.databaseEvidenceSHA256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
            $script:approval.postgresEndpointSHA256=(Get-PostgresConnectionPolicy $script:plan).EndpointSHA256
            $global:SyntheticRuntimeUrl='postgresql://sd_ferry_tracker_runtime@127.0.0.1:5432/ferry_tracker'
            Mock Read-LifecycleManifest -ModuleName Operations {@{launch=@{}}}
            Mock Get-ReleaseRuntimePath -ModuleName Operations {'C:\synthetic\node.exe'}
            Mock Get-ManagedAppEnvironment -ModuleName Operations {[ordered]@{DATABASE_URL=$global:SyntheticRuntimeUrl}}
        }
        AfterEach {Remove-Variable SyntheticRuntimeUrl -Scope Global}
        It 'uses actual launcher configuration and checks every solution database' {
            (Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot).database|Should Be 'ferry_tracker'
            Assert-MockCalled Get-ManagedAppEnvironment -ModuleName Operations -Times 1 -Exactly -Scope It
            Assert-MockCalled Get-PostgresDatabaseEvidence -ModuleName Operations -Times 1 -Exactly -Scope It -ParameterFilter {
                $HostName -eq '127.0.0.1' -and $Port -eq 5432 -and
                $SolutionDatabases.Count -eq 3 -and 'site_dock' -in $SolutionDatabases
            }
        }
        It 'propagates the approved remote endpoint and certificate to live evidence' {
            $script:plan.target=@{host='jimbrownhome';address='192.168.2.11'}
            $script:plan.hostSnapshot=@{host='jimbrownhome';address='192.168.2.11';identity='app-uuid';verified=$true}
            $script:approval.postgresEndpointSHA256=(Get-PostgresConnectionPolicy $script:plan).EndpointSHA256
            $script:approval.postgresSslRootCert=Join-Path $TestDrive 'synthetic-ca.crt'
            [IO.File]::WriteAllText($script:approval.postgresSslRootCert,'Synthetic hash-only fixture. No TLS connection is opened.')
            $script:approval.postgresSslRootCertSHA256=(Get-FileHash $script:approval.postgresSslRootCert).Hash.ToLowerInvariant()
            $certificate=[uri]::EscapeDataString($script:approval.postgresSslRootCert)
            $global:SyntheticRuntimeUrl="postgresql://sd_ferry_tracker_runtime@jimbrownhome1:5432/ferry_tracker?hostaddr=192.168.2.14&sslmode=verify-full&gssencmode=disable&sslrootcert=$certificate"
            (Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot).database|Should Be 'ferry_tracker'
            Assert-MockCalled Get-PostgresDatabaseEvidence -ModuleName Operations -Times 1 -Exactly -Scope It -ParameterFilter {
                $HostName -eq 'jimbrownhome1' -and $HostAddress -eq '192.168.2.14' -and $SslRootCert -like '*\synthetic-ca.crt'
            }
        }
        It 'rejects a runtime secret pointing at another database or privileged identity' {
            foreach($url in @('postgresql://postgres@127.0.0.1:5432/ferry_tracker','postgresql://sd_ferry_tracker_runtime@127.0.0.1:5432/home_automation')){
                $global:SyntheticRuntimeUrl=$url
                Assert-Throws {Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot}
            }
            Assert-MockCalled Get-PostgresDatabaseEvidence -ModuleName Operations -Times 0 -Exactly -Scope It
        }
        It 'rejects a verifier endpoint approval that differs from runtime policy' {
            $script:approval.postgresEndpointSHA256=('b'*64)
            Assert-Throws {Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot}
            Assert-MockCalled Get-PostgresDatabaseEvidence -ModuleName Operations -Times 0 -Exactly -Scope It
        }
        It 'rejects a managed move described as a legacy replay or another database server' {
            $path=Join-Path $script:appRoot 'state\database-proof.json'
            foreach($key in @('legacyImportPerformed','databaseHostIdentity','centralDatabasePreserved')){
                $saved=$script:record[$key]
                $script:record[$key]=switch($key){legacyImportPerformed {$true};databaseHostIdentity {'other-uuid'};centralDatabasePreserved {$false}}
                Write-DeploymentJson $path $script:record
                $script:approval.databaseEvidenceSHA256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
                Assert-Throws {Assert-DatabaseActivationEvidence $script:plan $script:approval $script:appRoot}
                $script:record[$key]=$saved
            }
            Assert-MockCalled Get-PostgresDatabaseEvidence -ModuleName Operations -Times 0 -Exactly -Scope It
        }
    }
}
