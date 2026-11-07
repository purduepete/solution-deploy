$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Placement.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Transfer.psm1') -Force -DisableNameChecking
function Assert-TargetThrows([scriptblock]$Action){
    $thrown=$false
    try{&$Action|Out-Null}catch{$thrown=$true}
    $thrown|Should Be $true
}

Describe 'Absent versus unreadable placement records' {
    It 'returns absence only when a parent can actually be read' {
        $missing=Join-Path $TestDrive 'not-created\control\placements\production\app.json'
        (Read-OptionalRemoteRecord $missing)|Should Be $null
    }
    It 'preserves a real record and refuses empty or non-object JSON' {
        $path=Join-Path $TestDrive 'placement.json'
        Write-DeploymentJson $path @{status='Active';host='synthetic'}
        (Read-OptionalRemoteRecord $path).host|Should Be synthetic
        [IO.File]::WriteAllText($path,'')
        Assert-TargetThrows {Read-OptionalRemoteRecord $path}
        [IO.File]::WriteAllText($path,'null')
        Assert-TargetThrows {Read-OptionalRemoteRecord $path}
    }
    It 'propagates denied record access rather than adopting an empty placement' {
        Mock Get-Item -ModuleName Deployment {throw [UnauthorizedAccessException]::new('Synthetic denied record')}
        Assert-TargetThrows {Read-OptionalDeploymentText (Join-Path $TestDrive 'placement.json')}
    }
    It 'requires directory listing rights before confirming a missing record' {
        Mock Get-ChildItem -ModuleName Deployment {throw [UnauthorizedAccessException]::new('Synthetic denied directory')}
        Assert-TargetThrows {Read-OptionalDeploymentText (Join-Path $TestDrive 'missing\placement.json')}
    }
}

Describe 'Host registry and target-aware planning' {
    BeforeEach {
        $script:configuration=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:environment=Read-DeploymentJson (Join-Path $root 'environments\production.json')
        foreach($id in $script:environment.apps.Keys){
            $absolute=[IO.Path]::GetFullPath((Join-Path $root $script:environment.apps[$id].manifest))
            $script:environment.apps[$id].manifest=[IO.Path]::GetRelativePath($script:configuration,$absolute)
        }
        $script:environmentPath=Join-Path $script:configuration 'environments\production.json'
        Write-DeploymentJson $script:environmentPath $script:environment
        Mock Read-OptionalRemoteRecord -ModuleName Deployment {$null}
        Mock Get-HostSnapshot -ModuleName Deployment {
            param($Environment)
            @{host=$Environment.host;address=$Environment.address;identity=('uuid-'+$Environment.host);verified=$true;freeBytes=100GB;listeners=@()}
        }
    }
    It 'preserves the default application host and fixed database host' {
        $plan=New-DeploymentPlan ferry-tracker -ConfigurationRoot $script:configuration -Offline
        $plan.target.host|Should Be 'jimbrownhome1'
        $plan.databaseTarget.host|Should Be 'jimbrownhome1'
        $plan.schemaVersion|Should Be 2
    }
    It 'selects the old application host without moving PostgreSQL' {
        $plan=New-DeploymentPlan ferry-tracker -Target jimbrownhome -ConfigurationRoot $script:configuration -Offline
        $plan.target.host|Should Be 'jimbrownhome'
        $plan.target.address|Should Be '192.168.2.11'
        $plan.databaseTarget.host|Should Be 'jimbrownhome1'
        $plan.transitionKind|Should Be 'LegacyConversion'
        $plan.operation|Should Be 'Cutover'
    }
    It 'accepts a future configured application host without new code' {
        $script:environment.hosts['synthetic-third']=@{host='synthetic-third';address='192.168.2.99';root='C:\ProgramData\SolutionDeploy';routeProfile='synthetic-third'}
        Write-DeploymentJson $script:environmentPath $script:environment
        $plan=New-DeploymentPlan ferry-tracker -Target synthetic-third -ConfigurationRoot $script:configuration -Offline
        $plan.target.host|Should Be 'synthetic-third'
        $plan.databaseTarget.host|Should Be 'jimbrownhome1'
    }
    It 'rejects unknown targets and a changed database server' {
        Assert-TargetThrows {New-DeploymentPlan ferry-tracker -Target unknown -ConfigurationRoot $script:configuration -Offline}
        $script:environment.databaseTarget.host='jimbrownhome'
        Write-DeploymentJson $script:environmentPath $script:environment
        Assert-TargetThrows {Get-DeploymentEnvironment -ConfigurationRoot $script:configuration}
    }
    It 'classifies a managed move and transfers only the explicit managed files' {
        Mock Read-OptionalRemoteRecord -ModuleName Deployment {
            param($Path)
            if($Path -like '*\placements\*'){@{status='Active';host='jimbrownhome';hostIdentity='uuid-jimbrownhome';releaseId='old';planHash='old-hash'}}
        }
        $plan=New-DeploymentPlan ferry-tracker -Target jimbrownhome1 -ConfigurationRoot $script:configuration
        $plan.transitionKind|Should Be 'ManagedMove'
        $plan.transferManifest.source.root|Should Be 'C:\ProgramData\SolutionDeploy\apps\ferry-tracker\shared'
        @($plan.transferManifest.state|Where-Object kind -eq sqlite).Count|Should Be 0
        $plan.transferManifest.state[0].source|Should Be 'data\raw'
        $plan.databaseHostSnapshot.identity|Should Be 'uuid-jimbrownhome1'
    }
    It 'supports a managed move in the opposite direction' {
        Mock Read-OptionalRemoteRecord -ModuleName Deployment {
            param($Path)
            if($Path -like '*\placements\*'){@{status='Active';host='jimbrownhome1';hostIdentity='uuid-jimbrownhome1';releaseId='old';planHash='old-hash'}}
        }
        $plan=New-DeploymentPlan site-dock -Target jimbrownhome -ConfigurationRoot $script:configuration
        $plan.transitionKind|Should Be 'ManagedMove'
        $plan.databaseTarget.host|Should Be 'jimbrownhome1'
        @($plan.transferManifest.state).Count|Should Be 0
        $plan.manifest.database.name|Should Be 'site_dock'
    }
    It 'classifies a same-host managed release separately from legacy adoption' {
        Mock Read-OptionalRemoteRecord -ModuleName Deployment {
            param($Path)
            if($Path -like '*\placements\*'){@{status='Active';host='jimbrownhome1';hostIdentity='uuid-jimbrownhome1';releaseId='old';planHash='old-hash'}}
            else{@{releaseId='old';planHash='old-hash'}}
        }
        (New-DeploymentPlan ferry-tracker -ConfigurationRoot $script:configuration).transitionKind|Should Be ManagedDeploy
    }
    It 'classifies an explicitly new application as a first install' {
        $script:environment.apps['ferry-tracker'].newInstallation=$true
        Write-DeploymentJson $script:environmentPath $script:environment
        (New-DeploymentPlan ferry-tracker -ConfigurationRoot $script:configuration -Offline).transitionKind|Should Be FirstInstall
    }
    It 'plans a first install without an observed source host' {
        $script:environment.apps['ferry-tracker'].newInstallation=$true
        $script:environment.apps['ferry-tracker'].Remove('observedHost')
        Write-DeploymentJson $script:environmentPath $script:environment
        $plan=New-DeploymentPlan ferry-tracker -ConfigurationRoot $script:configuration -Offline
        $plan.transitionKind|Should Be FirstInstall
        $plan.operation|Should Be Deploy
        $plan.observedHost|Should Be $null
        $plan.sourceHostSnapshot|Should Be $null
    }
    It 'rejects unresolved authority instead of selecting another live host' {
        Mock Read-OptionalRemoteRecord -ModuleName Deployment {
            param($Path)
            if($Path -like '*\placements\*'){@{status='Unknown';host='jimbrownhome1'}}
        }
        Assert-TargetThrows {New-DeploymentPlan ferry-tracker -ConfigurationRoot $script:configuration}
    }
    It 'rejects stale registry hashes and old saved plan versions' {
        $plan=New-DeploymentPlan ferry-tracker -ConfigurationRoot $script:configuration -Offline
        $script:environment.hosts.jimbrownhome.address='192.168.2.12'
        Write-DeploymentJson $script:environmentPath $script:environment
        Assert-TargetThrows {Assert-PlanInputs $plan -ConfigurationRoot $script:configuration}
        $plan.schemaVersion=1;$plan.planHash=Get-PlanDigest $plan
        Assert-TargetThrows {Assert-PlanInputs $plan -ConfigurationRoot $script:configuration}
    }
    It 'rejects malformed and public registry addresses' {
        foreach($address in @('999.1.2.3','8.8.8.8','127.0.0.1')){
            $script:environment.hosts.jimbrownhome.address=$address
            Write-DeploymentJson $script:environmentPath $script:environment
            Assert-TargetThrows {Get-DeploymentEnvironment -ConfigurationRoot $script:configuration}
        }
    }
    It 'rejects local managed release drift against central authority' {
        Mock Read-OptionalRemoteRecord -ModuleName Deployment {
            param($Path)
            if($Path -like '*\placements\*'){@{status='Active';host='jimbrownhome1';hostIdentity='uuid-jimbrownhome1';releaseId='old';planHash='old-hash'}}
            else{@{releaseId='other';planHash='other-hash'}}
        }
        Assert-TargetThrows {New-DeploymentPlan ferry-tracker -ConfigurationRoot $script:configuration}
    }
}

Describe 'Shared transition authority' {
    BeforeEach {
        $script:control=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:SyntheticPlacementRoot=$script:control
        Mock Get-PlacementRoot -ModuleName Placement {$global:SyntheticPlacementRoot}
        $script:plan=@{
            app='test-app';environment='production';id='operation';releaseId='release'
            target=@{host='target'};hostSnapshot=@{identity='target-uuid'};observedHost='source'
            databaseTarget=@{host='database';root='C:\ProgramData\SolutionDeploy'}
            databaseHostSnapshot=@{verified=$true;identity='database-uuid'}
            placementAuthority=$null;planHash='new-hash'
        }
    }
    AfterEach {Remove-Variable SyntheticPlacementRoot -Scope Global -ErrorAction SilentlyContinue}
    It 'serializes transitions to different hosts through the same app lock' {
        Write-DeploymentJson (Join-Path $script:control 'installation.json') @{host='database';root='C:\ProgramData\SolutionDeploy';identity='database-uuid'}
        $lease=Get-PlacementLease $script:plan
        try {
            $other=@{}+$script:plan;$other.target=@{host='another'}
            Assert-TargetThrows {Get-PlacementLease $other}
        }finally{$lease.Dispose()}
    }
    It 'blocks a pending or unknown prior transition and preserves it on disk' {
        Set-PlacementTransition $script:plan Pending
        Assert-TargetThrows {Assert-PlacementUnchanged $script:plan}
        Set-PlacementTransition $script:plan Unknown
        Assert-TargetThrows {Assert-PlacementUnchanged $script:plan}
    }
    It 'allows exact post-activation verification without replaying activation' {
        Set-PlacementTransition $script:plan Active
        Assert-PlacementUnchanged $script:plan -Verify
        Assert-TargetThrows {Assert-PlacementUnchanged $script:plan}
    }
}

Describe 'Managed filesystem move without a database import' {
    BeforeEach {
        Mock Assert-SourceFence -ModuleName Transfer {}
        Mock Start-SourceFenceMonitor -ModuleName Transfer {@{}}
        Mock Assert-SourceFenceMonitor -ModuleName Transfer {}
        Mock Stop-SourceFenceMonitor -ModuleName Transfer {}
    }
    It 'round-trips an empty SiteDock managed transfer without Python or legacy state' {
        $source=Join-Path $TestDrive 'empty-source'
        [IO.Directory]::CreateDirectory($source)|Out-Null
        $plan=@{
            id='empty-move';planHash='empty-hash';observedHost='source';transitionKind='ManagedMove'
            manifest=@{state=@(@{source='obsolete.db';target='data\obsolete.db';kind='sqlite';required=$true})}
            transferManifest=@{source=@{host='source';root=$source};state=@()}
        }
        $export=Join-Path $TestDrive 'empty-export'
        $proof=Export-FrozenState $plan @{synthetic=$true} $export
        @($proof.files).Count|Should Be 0
        $proof.stateDeclarationSHA256|Should Be (Get-Sha256Text '[]')
        $app=Join-Path $TestDrive 'empty-target'
        Write-DeploymentJson (Join-Path $app 'state\maintenance.json') @{reason='synthetic'}
        Prepare-ManagedStateImport $plan $app
        $hash=(Get-FileHash (Join-Path $export 'transfer.json')).Hash.ToLowerInvariant()
        (Import-FrozenState $plan $export $app $hash).operationId|Should Be 'empty-move'
    }
    It 'round-trips declared raw files while archiving old parked bytes' {
        $source=Join-Path $TestDrive 'file-source'
        [IO.Directory]::CreateDirectory((Join-Path $source 'data\raw'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'data\raw\new.gz'),'synthetic new bytes')
        $plan=@{
            id='files-move';planHash='files-hash';observedHost='source';transitionKind='ManagedMove'
            manifest=@{state=@(@{source='obsolete.db';target='data\obsolete.db';kind='sqlite';required=$true})}
            transferManifest=@{source=@{host='source';root=$source};state=@(@{source='data\raw';target='data\raw';kind='directory';required=$true})}
        }
        $export=Join-Path $TestDrive 'files-export'
        $proof=Export-FrozenState $plan @{synthetic=$true} $export
        @($proof.files).Count|Should Be 1
        $proof.files[0].target|Should Be 'data\raw\new.gz'
        $app=Join-Path $TestDrive 'files-target'
        Write-DeploymentJson (Join-Path $app 'state\maintenance.json') @{reason='synthetic'}
        [IO.Directory]::CreateDirectory((Join-Path $app 'shared\data\raw'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $app 'shared\data\raw\parked.gz'),'synthetic parked bytes')
        Prepare-ManagedStateImport $plan $app
        $hash=(Get-FileHash (Join-Path $export 'transfer.json')).Hash.ToLowerInvariant()
        Import-FrozenState $plan $export $app $hash|Out-Null
        Get-Content (Join-Path $app 'shared\data\raw\new.gz')|Should Be 'synthetic new bytes'
        Get-Content (Join-Path $app 'shared\backups\host-moves\files-move\data\raw\parked.gz')|Should Be 'synthetic parked bytes'
        Test-Path (Join-Path $app 'shared\data\obsolete.db')|Should Be $false
    }
    It 'archives parked state before import and refuses blind retry' {
        $app=Join-Path $TestDrive 'parked'
        Write-DeploymentJson (Join-Path $app 'state\maintenance.json') @{reason='synthetic'}
        [IO.Directory]::CreateDirectory((Join-Path $app 'shared\data\raw'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $app 'shared\data\raw\old.gz'),'old synthetic bytes')
        $plan=@{id='synthetic-move';transitionKind='ManagedMove';transferManifest=@{state=@(@{target='data\raw';kind='directory'})}}
        Prepare-ManagedStateImport $plan $app
        Get-Content (Join-Path $app 'shared\backups\host-moves\synthetic-move\data\raw\old.gz')|Should Be 'old synthetic bytes'
        Test-Path (Join-Path $app 'shared\data\raw')|Should Be $false
        (Read-DeploymentJson (Join-Path $app 'state\authority.json')).databasePreserved|Should Be $true
        Assert-TargetThrows {Prepare-ManagedStateImport $plan $app}
    }

    Context 'Controller-authenticated source fencing' {
        BeforeEach {
            $global:SyntheticSourceSession=[Microsoft.Management.Infrastructure.CimSession]::Create('synthetic-no-network')
            $global:SyntheticSourceState=@{uuid='source-uuid';taskPath='\JimlerTech\';taskState=1;maintenance=$true;processes=@();listeners=@()}
            $script:sourcePlan=@{
                id='move';app='ferry-tracker';observedHost='source';transitionKind='ManagedMove'
                sourceHostSnapshot=@{verified=$true;identity='source-uuid'}
                target=@{hosts=@{source=@{host='source';root='C:\ProgramData\SolutionDeploy'}}}
                placementAuthority=@{hostIdentity='source-uuid';releaseId='old';planHash='old-hash'}
                transferManifest=@{source=@{host='source';root='C:\ProgramData\SolutionDeploy\apps\ferry-tracker\shared';tasks=@('SolutionDeploy-ferry-tracker')};launch=@{port=8787}}
            }
            $script:fence=@{operationId='move';host='source';writersStopped=$true;restartPathsDisabled=$true;writerInventoryReviewed=$true;sourceProcessId=12345;verifiedLocal=(Get-Date).ToString('o')}
            Mock New-DeploymentSession -ModuleName Placement {$global:SyntheticSourceSession}
            Mock Close-DeploymentSession -ModuleName Placement {}
            Mock Invoke-FrozenSourceContentCheck -ModuleName Placement {}
            Mock Test-Path -ModuleName Placement {$global:SyntheticSourceState.maintenance}
            Mock Read-DeploymentJson -ModuleName Placement {@{releaseId='old';planHash='old-hash'}}
            Mock Get-CimInstance -ModuleName Placement {
                param($ClassName)
                switch($ClassName){
                    Win32_ComputerSystemProduct {@{UUID=$global:SyntheticSourceState.uuid}}
                    MSFT_ScheduledTask {@{TaskName='SolutionDeploy-ferry-tracker';TaskPath=$global:SyntheticSourceState.taskPath;State=$global:SyntheticSourceState.taskState}}
                    Win32_Process {$global:SyntheticSourceState.processes}
                    MSFT_NetTCPConnection {$global:SyntheticSourceState.listeners}
                }
            }
        }
        AfterEach {
            $global:SyntheticSourceSession.Dispose()
            Remove-Variable SyntheticSourceSession,SyntheticSourceState -Scope Global
        }
        It 'accepts a stopped managed source only in the exact JimlerTech task folder' {
            $result=Test-RemoteSourceFence $script:sourcePlan $script:fence
            $result.verified|Should Be $true
            $result.fenceHash|Should Be (Get-Sha256Text (ConvertTo-CanonicalJson $script:fence))
            $global:SyntheticSourceState.taskPath='\'
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence}
        }
        It 'rejects enabled restart paths, live writers, listeners, and missing durable maintenance' {
            $global:SyntheticSourceState.taskState=3
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence}
            $global:SyntheticSourceState.taskState=1
            $global:SyntheticSourceState.processes=@(@{ProcessId=12345;CommandLine='synthetic'})
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence}
            $global:SyntheticSourceState.processes=@()
            $global:SyntheticSourceState.listeners=@(@{LocalPort=8787})
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence}
            $global:SyntheticSourceState.listeners=@()
            $global:SyntheticSourceState.maintenance=$false
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence}
        }
        It 'rejects source hardware drift and stale or future evidence' {
            $global:SyntheticSourceState.uuid='another-machine'
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence}
            $global:SyntheticSourceState.uuid='source-uuid'
            $script:fence.verifiedLocal=(Get-Date).AddMinutes(-6).ToString('o')
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence}
            $script:fence.verifiedLocal=(Get-Date).AddMinutes(1).ToString('o')
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence}
        }
        It 'rechecks live source continuity without rewriting an old frozen fence' {
            $script:sourcePlan.planHash=('a'*64)
            $script:fence.verifiedLocal=[DateTimeOffset]::Now.AddHours(-2).ToString('o')
            $before=ConvertTo-CanonicalJson $script:fence
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence}
            $proof=@{planHash=$script:sourcePlan.planHash;operationId=$script:sourcePlan.id;fence=$script:fence}
            $result=Test-RemoteSourceFence $script:sourcePlan $script:fence -Continuity -TransferSHA256 ('b'*64) -ImportReceiptSHA256 ('c'*64) -TransferProof $proof
            $result.kind|Should Be SourceContinuity
            $result.transferSHA256|Should Be ('b'*64)
            $result.importReceiptSHA256|Should Be ('c'*64)
            (ConvertTo-CanonicalJson $script:fence)|Should Be $before
            $global:SyntheticSourceState.taskState=3
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence -Continuity -TransferSHA256 ('b'*64) -ImportReceiptSHA256 ('c'*64) -TransferProof $proof}
        }
        It 'timestamps fresh continuity only after the content check completes' {
            $script:sourcePlan.planHash=('a'*64)
            $proof=@{planHash=$script:sourcePlan.planHash;operationId=$script:sourcePlan.id;fence=$script:fence}
            Mock Invoke-FrozenSourceContentCheck -ModuleName Placement {$global:SyntheticContentFinished=[DateTimeOffset]::Now}
            try{
                $result=Test-RemoteSourceFence $script:sourcePlan $script:fence -Continuity -TransferSHA256 ('b'*64) -ImportReceiptSHA256 ('c'*64) -TransferProof $proof
                ([DateTimeOffset]::Parse($result.verifiedLocal) -ge $global:SyntheticContentFinished)|Should Be $true
            }finally{Remove-Variable SyntheticContentFinished -Scope Global -ErrorAction SilentlyContinue}
        }
        It 'rechecks original content and stopped source after a slow initial transfer without inventing an import receipt' {
            $script:sourcePlan.planHash=('a'*64)
            $script:fence.verifiedLocal=[DateTimeOffset]::Now.AddHours(-2).ToString('o')
            $proof=@{planHash=$script:sourcePlan.planHash;operationId=$script:sourcePlan.id;fence=$script:fence}
            $before=ConvertTo-CanonicalJson $script:fence
            $result=Test-RemoteSourceFence $script:sourcePlan $script:fence -TransferContinuity -TransferSHA256 ('b'*64) -TransferProof $proof
            $result.kind|Should Be FrozenTransferContinuity
            $result.sourceContentVerified|Should Be $true
            $result.ContainsKey('importReceiptSHA256')|Should Be $false
            $result.transferSHA256|Should Be ('b'*64)
            (ConvertTo-CanonicalJson $script:fence)|Should Be $before
            Assert-MockCalled Invoke-FrozenSourceContentCheck -ModuleName Placement -Times 1 -Exactly -Scope It
            $global:SyntheticSourceState.taskState=3
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence -TransferContinuity -TransferSHA256 ('b'*64) -TransferProof $proof}
            $global:SyntheticSourceState.taskState=1
            $global:SyntheticSourceState.processes=@(@{ProcessId=12345;CommandLine='synthetic'})
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence -TransferContinuity -TransferSHA256 ('b'*64) -TransferProof $proof}
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence -TransferContinuity -Continuity -TransferSHA256 ('b'*64) -TransferProof $proof}
            $global:SyntheticSourceState.processes=@()
            Assert-TargetThrows {Test-RemoteSourceFence $script:sourcePlan $script:fence -TransferContinuity -TransferSHA256 ('b'*64)}
        }
    }
}
