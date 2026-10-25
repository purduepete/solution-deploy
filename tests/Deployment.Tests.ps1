$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Transfer.psm1') -Force -DisableNameChecking
function Assert-Throws([scriptblock]$Action) {
    $thrown=$false
    try { & $Action | Out-Null } catch { $thrown=$true }
    $thrown | Should Be $true
}

Describe 'Owned deployment paths' {
    It 'rejects parent traversal' {
        Assert-Throws { Resolve-OwnedPath $TestDrive '..\outside' }
    }
    It 'rejects rooted input' {
        Assert-Throws { Resolve-OwnedPath $TestDrive 'C:\Windows\file' }
    }
    It 'rejects alternate streams' {
        Assert-Throws { Resolve-OwnedPath $TestDrive 'data.txt:stream' }
    }
    It 'rejects root deletion or replacement targets' {
        Assert-Throws { Resolve-OwnedPath $TestDrive '.' }
    }
    It 'allows a bounded relative file' {
        Resolve-OwnedPath $TestDrive 'state\active.json' | Should Be (Join-Path $TestDrive 'state\active.json')
    }
    It 'rejects junction traversal' {
        $target = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'target')
        New-Item -ItemType Junction -Path (Join-Path $TestDrive 'link') -Target $target.FullName | Out-Null
        Assert-Throws { Resolve-OwnedPath $TestDrive 'link\payload' }
        [IO.Directory]::Delete((Join-Path $TestDrive 'link'))
    }
}

Describe 'Approval and content binding' {
    BeforeEach {
        $script:plan = @{
            id='test-operation'; manifestHash='abc'; environmentHash='def'; databaseActionsRequired=$true
            hostSnapshot=@{identity='machine-1';verified=$true}; app='test-app'
        }
        $script:plan.planHash = Get-PlanDigest $script:plan
        $script:approval = @{
            planHash=$script:plan.planHash;hostIdentity='machine-1';actions=@('Stage','Deploy');approvedBy='operator'
            expiresLocal=[DateTimeOffset]::Now.AddHours(1).ToString('o')
            gates=@{sourceCommitted=$true;artifactTrust=$true;hostProvisioning=$true;runtimeIdentity=$true;routePreconditions=$true}
        }
        $script:approvalPath = Join-Path $TestDrive 'approval.json'
        Write-DeploymentJson $script:approvalPath $script:approval
    }
    It 'accepts only an exact stage approval' {
        (Assert-DeploymentApproval $script:plan $script:approvalPath Stage).approvedBy | Should Be 'operator'
    }
    It 'detects plan tampering' {
        $script:plan.manifestHash='changed'
        Assert-Throws { Assert-DeploymentApproval $script:plan $script:approvalPath Stage }
    }
    It 'rejects an unapproved action' {
        Assert-Throws { Assert-DeploymentApproval $script:plan $script:approvalPath Cutover }
    }
    It 'requires independent database review before startup' {
        Assert-Throws { Assert-DeploymentApproval $script:plan $script:approvalPath Deploy }
    }
    It 'rejects expired approval' {
        $script:approval.expiresLocal=[DateTimeOffset]::Now.AddMinutes(-1).ToString('o')
        Write-DeploymentJson $script:approvalPath $script:approval
        Assert-Throws { Assert-DeploymentApproval $script:plan $script:approvalPath Stage }
    }
    It 'blocks production execution while PostgreSQL adapters are pending' {
        $script:plan.target=@{storagePolicy=@{engine='postgresql';implementationStatus='awaiting-revised-plan-review'}}
        $script:plan.planHash=Get-PlanDigest $script:plan
        $script:approval.planHash=$script:plan.planHash
        Write-DeploymentJson $script:approvalPath $script:approval
        Assert-Throws { Assert-DeploymentApproval $script:plan $script:approvalPath Stage }
    }
    It 'survives a JSON round trip without a changed digest' {
        $path=Join-Path $TestDrive 'plan.json'; Write-DeploymentJson $path $script:plan
        Get-PlanDigest (Read-DeploymentJson $path) | Should Be $script:plan.planHash
    }
    It 'canonicalizes nested dictionaries independent of insertion order' {
        Get-PlanDigest @{nested=[ordered]@{z=1;a=2};list=@('one','two')} | Should Be (Get-PlanDigest @{list=@('one','two');nested=[ordered]@{a=2;z=1}})
    }
    It 'preserves timestamp text and digests through JSON without date coercion' {
        $timestamps=@('2026-10-17T16:00:00.1234500-07:00','2026-10-17T23:00:00.1234500Z','2026-10-17T16:00:00.0000000-07:00')
        foreach($timestamp in $timestamps){
            $record=@{createdLocal=$timestamp;nested=@{observed=$timestamp}}
            $digest=Get-PlanDigest $record
            $path=Join-Path $TestDrive 'timestamp.json'
            Write-DeploymentJson $path $record
            $loaded=Read-DeploymentJson $path
            $loaded.createdLocal|Should Be $timestamp
            ($loaded.createdLocal -is [string])|Should Be $true
            Get-PlanDigest $loaded|Should Be $digest
        }
    }
}

Describe 'Locks and sealed releases' {
    It 'refuses a second lock' {
        $path=Join-Path $TestDrive 'lock'
        $handle=Get-DeploymentLock $path
        try { Assert-Throws { Get-DeploymentLock $path } } finally {$handle.Dispose()}
    }
    It 'waits for a held lock only until its bounded deadline' {
        $path=Join-Path $TestDrive 'bounded-lock'
        $handle=Get-DeploymentLock $path
        try {
            InModuleScope Deployment {
                $error=$null
                try { Get-DeploymentLock (Join-Path $TestDrive 'bounded-lock') -WaitTimeoutSeconds 1 -RetryIntervalSeconds 0.1 | Out-Null }
                catch { $error=$_.Exception.Message }
                $error|Should Match 'Timed out after 1 seconds waiting for the deployment lock'
            }
        } finally {$handle.Dispose()}
    }
    It 'classifies only sharing violations as retryable lock contention' {
        InModuleScope Deployment {
            (Test-DeploymentLockSharingViolation ([IO.IOException]::new('sharing failure')))|Should Be $false
            (Test-DeploymentLockSharingViolation ([UnauthorizedAccessException]::new('access denied')))|Should Be $false
        }
    }
    It 'writes JSON atomically and reads it back' {
        $path=Join-Path $TestDrive 'json\record.json'
        Write-DeploymentJson $path @{status='before'}
        Write-DeploymentJson $path @{status='after'}
        (Read-DeploymentJson $path).status | Should Be 'after'
        @(Get-ChildItem -LiteralPath (Split-Path $path) -Filter '.write-*' -Force).Count | Should Be 0
    }
    It 'detects modified and added release files' {
        $release=Join-Path $TestDrive 'release'
        New-Item -ItemType Directory -Path $release | Out-Null
        [IO.File]::WriteAllText((Join-Path $release 'app.js'),'original')
        Write-DeploymentJson (Join-Path $release 'release.json') @{files=@(Get-ReleaseInventory $release)}
        @(Test-ReleaseInventory $release).Count | Should Be 1
        [IO.File]::WriteAllText((Join-Path $release 'app.js'),'tampered')
        Assert-Throws { Test-ReleaseInventory $release }
    }
    It 'detects an added file independently of known hashes' {
        $release=Join-Path $TestDrive 'added'
        New-Item -ItemType Directory -Path $release | Out-Null
        Write-DeploymentJson (Join-Path $release 'release.json') @{files=@()}
        [IO.File]::WriteAllText((Join-Path $release 'extra'),'unexpected')
        Assert-Throws { Test-ReleaseInventory $release }
    }
    It 'does not switch releases without maintenance' {
        $app=Join-Path $TestDrive 'no-maintenance'
        $release=Join-Path $app 'releases\abc-123'
        New-Item -ItemType Directory -Path $release | Out-Null
        Write-DeploymentJson (Join-Path $release 'release.json') @{files=@();sourceCommit='123'}
        Assert-Throws { Set-ActiveRelease $app 'abc-123' 'test-operation' 'test-host' 'digest' }
    }
    It 'journals a stopped junction switch' {
        $app=Join-Path $TestDrive 'switch'
        $release=Join-Path $app 'releases\abc-123'
        New-Item -ItemType Directory -Path $release | Out-Null
        Write-DeploymentJson (Join-Path $release 'release.json') @{files=@();sourceCommit='123'}
        Write-DeploymentJson (Join-Path $app 'state\maintenance.json') @{reason='test'}
        Set-ActiveRelease $app 'abc-123' 'test-operation' 'test-host' 'digest'
        (Read-DeploymentJson (Join-Path $app 'state\switch.json')).phase | Should Be 'Switched'
        (Read-DeploymentJson (Join-Path $app 'state\active.json')).releaseId | Should Be 'abc-123'
        [IO.Directory]::Delete((Join-Path $app 'current'))
    }
    It 'keeps the app account junction ACE across a release switch' {
        $app=Join-Path $TestDrive 'switch-acl'
        foreach($id in 'old-1','new-2'){
            $release=Join-Path $app "releases\$id"
            New-Item -ItemType Directory -Path $release | Out-Null
            Write-DeploymentJson (Join-Path $release 'release.json') @{files=@();sourceCommit='123'}
        }
        $current=Join-Path $app 'current'
        New-Item -ItemType Junction -Path $current -Target (Join-Path $app 'releases\old-1') | Out-Null
        $sid=[Security.Principal.SecurityIdentifier]'S-1-5-32-545'
        $acl=Get-Acl -LiteralPath $current
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute, Synchronize','None','None','Allow'))
        Set-Acl -LiteralPath $current -AclObject $acl
        Write-DeploymentJson (Join-Path $app 'state\maintenance.json') @{reason='test'}
        Set-ActiveRelease $app 'new-2' 'test-operation' 'test-host' 'digest'
        [string](Get-Item -LiteralPath $current).Target | Should Be (Join-Path $app 'releases\new-2')
        @((Get-Acl -LiteralPath $current).Access | Where-Object { -not $_.IsInherited -and $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $sid }).Count | Should Be 1
        [IO.Directory]::Delete($current)
    }
    It 'gives a first-install junction the app account root ACE' {
        $app=Join-Path $TestDrive 'first-acl'
        $release=Join-Path $app 'releases\first-1'
        New-Item -ItemType Directory -Path $release | Out-Null
        Write-DeploymentJson (Join-Path $release 'release.json') @{files=@();sourceCommit='123'}
        $sid=[Security.Principal.SecurityIdentifier]'S-1-5-32-545'
        $acl=Get-Acl -LiteralPath $app
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute, Synchronize','None','None','Allow'))
        Set-Acl -LiteralPath $app -AclObject $acl
        Write-DeploymentJson (Join-Path $app 'state\maintenance.json') @{reason='test'}
        Set-ActiveRelease $app 'first-1' 'test-operation' 'test-host' 'digest'
        $current=Join-Path $app 'current'
        @((Get-Acl -LiteralPath $current).Access | Where-Object { -not $_.IsInherited -and $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $sid }).Count | Should Be 1
        (Read-DeploymentJson (Join-Path $app 'state\active.json')).previousRelease | Should Be $null
        [IO.Directory]::Delete($current)
    }
}

Describe 'Data authority and state inventory' {
    It 'blocks stale-source rollback after destination writes' {
        (Get-RollbackDecision -TargetWroteData $true -SchemaCompatible $true -CrossHost).allowed | Should Be $false
    }
    It 'permits same-host compatible code rollback with current state' {
        (Get-RollbackDecision -TargetWroteData $true -SchemaCompatible $true).allowed | Should Be $true
    }
    It 'blocks unverified schema compatibility' {
        (Get-RollbackDecision -TargetWroteData $false -SchemaCompatible $false).allowed | Should Be $false
    }
    It 'measures raw history recursively without reading content' {
        $source=Join-Path $TestDrive 'state-source'
        New-Item -ItemType Directory -Path (Join-Path $source 'raw') | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'raw\a.json'),'123456')
        $manifest=@{source=@{root=$source};state=@(@{source='raw';target='data\raw';kind='directory';required=$true})}
        $inventory=Get-StateInventory $manifest
        $inventory.totalBytes | Should Be 6
        $inventory.complete | Should Be $true
        $inventory.files[0].sha256 | Should Be $null
        $inventory.minimumFreeBytes | Should Be (5GB+18)
    }
    It 'reports missing required files as blocking' {
        $manifest=@{source=@{root=$TestDrive};state=@(@{source='absent';target='secrets\app.env';kind='secret';required=$true})}
        (Get-StateInventory $manifest).complete | Should Be $false
    }
    It 'never treats a sizing-only WAL as an import payload' {
        $source=Join-Path $TestDrive 'db-size'
        New-Item -ItemType Directory -Path $source | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'test.db'),'main')
        [IO.File]::WriteAllText((Join-Path $source 'test.db-wal'),'wal')
        $manifest=@{source=@{root=$source};state=@(@{source='test.db';target='data\test.db';kind='sqlite';required=$true})}
        $inventory=Get-StateInventory $manifest
        $inventory.totalBytes | Should Be 7
        @($inventory.files | Where-Object kind -eq 'sizing-only').Count | Should Be 1
    }
}

Describe 'Production environment contract' {
    It 'maps production to the destination and preserves current app placement' {
        $environment=(Get-DeploymentEnvironment).Value
        $environment.host | Should Be 'jimbrownhome1'
        $environment.apps['ferry-tracker'].observedHost | Should Be 'jimbrownhome1'
        $environment.storagePolicy.databases['site-dock'] | Should Be 'site_dock'
    }
    It 'rejects unknown environments' {
        Assert-Throws { Get-DeploymentEnvironment 'missing-environment' }
    }
    It 'does not allow shell-shaped operation identifiers' {
        Assert-Throws { Assert-Identifier 'abc;whoami' }
    }
}

Describe 'Trusted archive exclusions' {
    BeforeEach {
        $suffix=[guid]::NewGuid().ToString('N')
        $script:archive=Join-Path $TestDrive ($suffix+'.zip')
        $zip=[IO.Compression.ZipFile]::Open($script:archive,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach($name in @('.env.development','app.js')){
                $writer=[IO.StreamWriter]::new($zip.CreateEntry($name).Open())
                try {$writer.Write('synthetic')} finally {$writer.Dispose()}
            }
        } finally {$zip.Dispose()}
        $script:destination=Join-Path $TestDrive ($suffix+'-extracted')
    }
    It 'rejects private tracked files without an explicit exclusion' {
        Assert-Throws {Expand-TrustedRelease $script:archive $script:destination}
    }
    It 'excludes only the reviewed exact path' {
        Expand-TrustedRelease $script:archive $script:destination -ExcludedPaths @('.env.development')
        Test-Path -LiteralPath (Join-Path $script:destination '.env.development') | Should Be $false
        Get-Content -LiteralPath (Join-Path $script:destination 'app.js') | Should Be 'synthetic'
    }
    It 'does not treat an exclusion as a wildcard' {
        Assert-Throws {Expand-TrustedRelease $script:archive $script:destination -ExcludedPaths @('.env*')}
    }
}

Describe 'PostgreSQL change reports' {
    It 'shows the selected host, fixed remote database, managed state, and JimlerTech tasks' {
        $plan=@{
            app='test-app';operation='Cutover';environment='production';observedHost='source';transitionKind='ManagedMove'
            target=@{host='jimbrownhome';address='192.168.2.11';routeProfile='jimbrownhome'};blockers=@('Review required')
            databaseTarget=@{host='jimbrownhome1';address='192.168.2.14';port=5432};databaseHostSnapshot=@{identity='database-uuid'}
            id='report-test';planHash='digest';sourceCommit='commit';manifestHash='manifest';environmentHash='environment';releaseId='release'
            manifest=@{database=@{name='test_app';schemaVersion=1};routes=@();state=@(@{source='legacy.db';target='data\legacy.db';kind='sqlite';required=$true})}
            transferManifest=@{state=@(@{source='data\raw';target='data\raw';kind='directory';required=$true})}
        }
        $path=Join-Path $TestDrive 'managed-review.html'
        Export-DeploymentReport $plan $path|Out-Null
        $html=Get-Content -LiteralPath $path -Raw
        $html.Contains('server <code>jimbrownhome1</code>')|Should Be $true
        $html.Contains('verified TLS server name')|Should Be $true
        $html.Contains('\JimlerTech\')|Should Be $true
        $html.Contains('data\raw')|Should Be $true
        $html.Contains('legacy.db')|Should Be $false
        $html.Contains('Never replay a legacy importer')|Should Be $true
    }
    It 'includes escaped validation evidence and source sizing without legacy rollback claims' {
        $plan=@{
            app='test-app';operation='Cutover';environment='production';observedHost='source'
            target=@{host='destination';address='127.0.0.1'};blockers=@('Review required')
            id='report-test';planHash='digest';sourceCommit='commit';manifestHash='manifest';environmentHash='environment';releaseId='release'
            manifest=@{database=@{name='test_app';schemaVersion=1};routes=@();state=@()}
            validationEvidence=@('First <test>','Second check')
            sourceSizing=@{files=234;bytes=5936425533L;complete=$true;minimumFreeBytes=23177985719L}
        }
        $path=Join-Path $TestDrive 'review.html'
        Export-DeploymentReport $plan $path | Out-Null
        $html=Get-Content -LiteralPath $path -Raw
        $html.Contains('<code>test_app</code>') | Should Be $true
        $html.Contains('<li>First &lt;test&gt;</li><li>Second check</li>') | Should Be $true
        $html.Contains('5936425533 bytes') | Should Be $true
        $html.Contains('reviewed reverse conversion') | Should Be $true
        $html.Contains('data-theme=light') | Should Be $true
        $html.Contains('localStorage') | Should Be $true
    }
}

Describe 'Source and runtime secret separation' {
    BeforeEach {
        $script:manifest=@{
            schemaVersion=1;id='test-app';repository='https://github.com/purduepete/test-app'
            runtime=@{kind='node';minimumVersion='22.0.0'};build=@{commands=@()}
            launch=@{entrypoint='app.js';arguments=@();port=9999;environment=@{STORAGE_BACKEND='postgresql'};secretFile='app.env'}
            readiness=@{path='/health';expected=@{ok=$true}}
            state=@(@{source='.env';target='secrets\source\app.env';kind='secret';required=$true})
            routes=@();source=@{host='synthetic-source';root='C:\synthetic';tasks=@()}
            database=@{engine='postgresql';name='test_app';connectionEnvironment='DATABASE_URL';backendEnvironment='STORAGE_BACKEND';schemaVersion=1;migrationsDirectory='deploy\postgresql';backupFormat='custom'}
        }
        $script:manifestPath=Join-Path $TestDrive 'manifest.json'
    }
    It 'accepts source archives separately from prepared runtime secrets' {
        Write-DeploymentJson $script:manifestPath $script:manifest
        (Get-Manifest $script:manifestPath).launch.secretFile|Should Be 'app.env'
    }
    It 'rejects a source file mapped onto prepared runtime secrets' {
        $script:manifest.state[0].target='secrets\app.env'
        Write-DeploymentJson $script:manifestPath $script:manifest
        Assert-Throws {Get-Manifest $script:manifestPath}
    }
    It 'rejects a source directory enclosing prepared runtime secrets' {
        $script:manifest.state[0].kind='directory'
        $script:manifest.state[0].target='secrets\import'
        $script:manifest.launch.secretFile='import\app.env'
        Write-DeploymentJson $script:manifestPath $script:manifest
        Assert-Throws {Get-Manifest $script:manifestPath}
    }
    It 'rejects a database connection in a versioned manifest environment' {
        $script:manifest.launch.environment.DATABASE_URL='postgresql://runtime@localhost/test_app'
        Write-DeploymentJson $script:manifestPath $script:manifest
        Assert-Throws {Get-Manifest $script:manifestPath}
    }
}
