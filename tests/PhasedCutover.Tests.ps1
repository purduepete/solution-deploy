$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Operations.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Transfer.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\Placement.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking
function Assert-PhaseThrows([scriptblock]$Action){
    $thrown=$false
    try{&$Action|Out-Null}catch{$thrown=$true}
    $thrown|Should Be $true
}

Describe 'Initial legacy preparation without databases, task registration or app launch' {
    BeforeEach {
        $script:base=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:app=Join-Path $script:base 'app'
        $script:export=Join-Path $script:base 'export'
        $release=Join-Path $script:app 'releases\synthetic-release'
        [IO.Directory]::CreateDirectory($release)|Out-Null
        $runtime=Join-Path $script:base 'not-executable.txt'
        [IO.File]::WriteAllText($runtime,'Synthetic hash fixture. Never execute.')
        Write-DeploymentJson (Join-Path $release 'release.json') @{
            files=@();manifestHash='manifest';sourceCommit='synthetic';runtimePath=$runtime;runtimeSHA256=(Get-FileHash $runtime).Hash.ToLowerInvariant()
        }
        Write-DeploymentJson (Join-Path $script:app 'state\maintenance.json') @{reason='Synthetic'}
        $script:plan=@{
            id='synthetic-phase';planHash=('a'*64);manifestHash='manifest';releaseId='synthetic-release'
            transitionKind='LegacyConversion';currentRelease=$null;observedHost='synthetic-source'
            manifest=@{source=@{host='synthetic-source'};state=@(@{kind='directory';source='raw';target='data\raw';required=$true})}
        }
        [IO.Directory]::CreateDirectory((Join-Path $script:export 'data\raw'))|Out-Null
        $file=Join-Path $script:export 'data\raw\a.gz'
        [IO.File]::WriteAllText($file,'Synthetic bytes, not a database or gzip.')
        $script:proof=@{
            planHash=$script:plan.planHash;operationId=$script:plan.id;sourceHost='synthetic-source'
            stateDeclarationSHA256=(Get-Sha256Text (ConvertTo-CanonicalJson $script:plan.manifest.state))
            directories=@('data\raw');files=@(@{target='data\raw\a.gz';kind='file';bytes=(Get-Item $file).Length;sha256=(Get-FileHash $file).Hash.ToLowerInvariant()})
            fence=@{operationId=$script:plan.id;sourceProcessId=123;verifiedLocal=[DateTimeOffset]::Now.AddHours(-2).ToString('o')}
        }
        Write-DeploymentJson (Join-Path $script:export 'transfer.json') $script:proof
        $script:transferHash=(Get-FileHash (Join-Path $script:export 'transfer.json')).Hash.ToLowerInvariant()
    }
    AfterEach {
        $junction=Join-Path $script:app 'current'
        if(Test-Path -LiteralPath $junction){[IO.Directory]::Delete($junction)}
    }
    It 'prepares current and files while preserving maintenance and leaving active absent' {
        $result=Prepare-InitialCutover $script:plan $script:app $script:export $script:transferHash
        $result.phase|Should Be Prepared
        $result.runtimeStarted|Should Be $false
        Test-Path (Join-Path $script:app 'state\active.json')|Should Be $false
        Test-Path (Join-Path $script:app 'state\maintenance.json')|Should Be $true
        (Get-Item (Join-Path $script:app 'current')).LinkType|Should Be Junction
        (Assert-PreparedState $script:plan $script:app $result.preparedStateSHA256).transferSHA256|Should Be $script:transferHash
        Assert-PhaseThrows {Prepare-InitialCutover $script:plan $script:app $script:export $script:transferHash}
    }
    It 'finishes the release switch without a false previous release or reimporting files' {
        $result=Prepare-InitialCutover $script:plan $script:app $script:export $script:transferHash
        Assert-PreparedState $script:plan $script:app $result.preparedStateSHA256|Out-Null
        Set-ActiveRelease $script:app $script:plan.releaseId $script:plan.id 'synthetic-host' $script:plan.planHash
        $active=Read-DeploymentJson (Join-Path $script:app 'state\active.json')
        $active.previousRelease|Should Be $null
        Get-Content (Join-Path $script:app 'shared\data\raw\a.gz')|Should Be 'Synthetic bytes, not a database or gzip.'
    }
    It 'rejects changed files and extra directory entries after preparation' {
        $result=Prepare-InitialCutover $script:plan $script:app $script:export $script:transferHash
        $file=Join-Path $script:app 'shared\data\raw\a.gz'
        [IO.File]::WriteAllText($file,'Changed')
        Assert-PhaseThrows {Assert-PreparedState $script:plan $script:app $result.preparedStateSHA256}
        [IO.File]::WriteAllText($file,'Synthetic bytes, not a database or gzip.')
        [IO.File]::WriteAllText((Join-Path (Split-Path $file) 'extra.gz'),'Extra')
        Assert-PhaseThrows {Assert-PreparedState $script:plan $script:app $result.preparedStateSHA256}
    }
    It 'rejects target writes, missing maintenance and changed receipt bytes' {
        $result=Prepare-InitialCutover $script:plan $script:app $script:export $script:transferHash
        $authority=Join-Path $script:app 'state\authority.json'
        $record=Read-DeploymentJson $authority
        $record.targetMayHaveWritten=$true
        Write-DeploymentJson $authority $record
        Assert-PhaseThrows {Assert-PreparedState $script:plan $script:app $result.preparedStateSHA256}
        $record.targetMayHaveWritten=$false;Write-DeploymentJson $authority $record
        Assert-PhaseThrows {Assert-PreparedState $script:plan $script:app ('b'*64)}
        Remove-Item (Join-Path $script:app 'state\maintenance.json')
        Assert-PhaseThrows {Assert-PreparedState $script:plan $script:app $result.preparedStateSHA256}
    }
    It 'preserves conflict evidence instead of overwriting existing files' {
        [IO.Directory]::CreateDirectory((Join-Path $script:app 'shared\data\raw'))|Out-Null
        $file=Join-Path $script:app 'shared\data\raw\a.gz'
        [IO.File]::WriteAllText($file,'Prior state')
        Assert-PhaseThrows {Prepare-InitialCutover $script:plan $script:app $script:export $script:transferHash}
        Get-Content $file|Should Be 'Prior state'
        Test-Path (Join-Path $script:app 'state\prepare-attempt.json')|Should Be $true
        Test-Path (Join-Path $script:app 'state\prepared-cutover.json')|Should Be $false
    }
    It 'accepts fresh chained continuity for an old immutable export without rewriting it' {
        $result=Prepare-InitialCutover $script:plan $script:app $script:export $script:transferHash
        $receipt=Assert-PreparedState $script:plan $script:app $result.preparedStateSHA256
        $approval=@{preparedStateSHA256=$result.preparedStateSHA256;databaseEvidenceSHA256=('c'*64);transferSHA256=$script:transferHash;sourceFenceSHA256=$receipt.sourceFenceSHA256}
        $verification=@{
            kind='SourceContinuity';verified=$true;sourceContentVerified=$true;operationId=$script:plan.id;planHash=$script:plan.planHash;sourceHost=$script:plan.observedHost
            fenceHash=$receipt.sourceFenceSHA256;transferSHA256=$script:transferHash;importReceiptSHA256=('c'*64);verifiedLocal=(Get-Date).ToString('o')
        }
        Assert-SourceContinuity $script:plan $approval $verification $receipt
        $verification.kind='FrozenTransferContinuity'
        Assert-PhaseThrows {Assert-SourceContinuity $script:plan $approval $verification $receipt}
        $verification.kind='SourceContinuity'
        (Get-FileHash (Join-Path $script:export 'transfer.json')).Hash.ToLowerInvariant()|Should Be $script:transferHash
        foreach($field in @('fenceHash','transferSHA256','importReceiptSHA256','planHash')){
            $old=$verification[$field];$verification[$field]=('d'*64)
            Assert-PhaseThrows {Assert-SourceContinuity $script:plan $approval $verification $receipt}
            $verification[$field]=$old
        }
        foreach($time in @([DateTimeOffset]::Now.AddMinutes(-6),[DateTimeOffset]::Now.AddMinutes(1))){
            $verification.verifiedLocal=$time.ToString('o')
            Assert-PhaseThrows {Assert-SourceContinuity $script:plan $approval $verification $receipt}
        }
    }
}

Describe 'Cheap per-file source monitoring with full endpoint checks' {
    BeforeEach {
        Mock Assert-SourceFence -ModuleName Transfer {}
        Mock Start-SourceFenceMonitor -ModuleName Transfer {@{synthetic=$true}}
        Mock Assert-SourceFenceMonitor -ModuleName Transfer {}
        Mock Stop-SourceFenceMonitor -ModuleName Transfer {}
        $script:source=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($script:source)|Out-Null
        foreach($n in 1..20){[IO.File]::WriteAllText((Join-Path $script:source "$n.txt"),"Synthetic $n")}
        $script:plan=@{id='monitor-test';planHash='synthetic';manifest=@{
            source=@{root=$script:source;host='synthetic'};state=@(@{kind='directory';source='.';target='data\raw';required=$true})
        }}
        # An absolute source keeps Resolve-OwnedPath's root-replacement guard intact.
        $script:plan.manifest.state[0].source=$script:source
        $script:output=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    It 'runs two full fences for twenty files, with a monitor check per file and before publication' {
        $proof=Export-FrozenState $script:plan @{} $script:output
        @($proof.files).Count|Should Be 20
        Assert-MockCalled Assert-SourceFence -ModuleName Transfer -Times 2 -Exactly -Scope It
        Assert-MockCalled Assert-SourceFenceMonitor -ModuleName Transfer -Times 21 -Exactly -Scope It
        Assert-MockCalled Stop-SourceFenceMonitor -ModuleName Transfer -Times 1 -Exactly -Scope It
    }
    It 'never publishes transfer proof if the continuous monitor fails' {
        Mock Assert-SourceFenceMonitor -ModuleName Transfer {throw 'Synthetic restarted writer'}
        Assert-PhaseThrows {Export-FrozenState $script:plan @{} $script:output}
        Test-Path (Join-Path $script:output 'transfer.json')|Should Be $false
        Assert-MockCalled Stop-SourceFenceMonitor -ModuleName Transfer -Times 1 -Exactly -Scope It
    }
}

Describe 'Continuous monitor failure gates' {
    It 'rejects stale, failed and stopped monitor state' {
        foreach($monitor in @(
            @{state=@{error='Synthetic failure';lastVerified=[Environment]::TickCount64};pending=@{IsCompleted=$false}},
            @{state=@{error=$null;lastVerified=[Environment]::TickCount64-11000};pending=@{IsCompleted=$false}},
            @{state=@{error=$null;lastVerified=[Environment]::TickCount64};pending=@{IsCompleted=$true}}
        )){
            Assert-PhaseThrows {Assert-SourceFenceMonitor $monitor}
        }
    }
    It 'propagates a real runspace failure without querying another computer' {
        $manifest=@{source=@{host='synthetic-never-a-real-host'}}
        $fence=@{operationId='synthetic';host='synthetic-never-a-real-host';writersStopped=$true;restartPathsDisabled=$true;sourceProcessId=1;verifiedLocal=(Get-Date).ToString('o')}
        $monitor=Start-SourceFenceMonitor $manifest $fence synthetic
        $monitor.pending.AsyncWaitHandle.WaitOne(5000)|Should Be $true
        Assert-PhaseThrows {Assert-SourceFenceMonitor $monitor}
        Assert-PhaseThrows {Stop-SourceFenceMonitor $monitor}
    }
}

Describe 'Full batched fences and owned snapshot child exclusion' {
    BeforeEach {
        $script:manifest=@{source=@{host=$env:COMPUTERNAME;root='C:\synthetic-source';tasks=@('SyntheticA','SyntheticB')};launch=@{port=9999}}
        $script:fence=@{operationId='synthetic';host=$env:COMPUTERNAME;writersStopped=$true;restartPathsDisabled=$true;writerInventoryReviewed=$true;sourceProcessId=12345;verifiedLocal=(Get-Date).ToString('o');writerCommandLines=@('node.exe relative-writer.js')}
        $global:SyntheticFenceProcesses=@()
        Mock Get-Process -ModuleName Transfer {}
        Mock Get-ScheduledTask -ModuleName Transfer {@{TaskName='SyntheticA';State='Disabled'},@{TaskName='SyntheticB';State='Disabled'}}
        Mock Get-NetTCPConnection -ModuleName Transfer {}
        Mock Get-CimInstance -ModuleName Transfer {$global:SyntheticFenceProcesses}
    }

    AfterEach {Remove-Variable SyntheticFenceProcesses -Scope Global}
    It 'enumerates task definitions only once and rejects future evidence' {
        Assert-SourceFence $script:manifest $script:fence synthetic
        Assert-MockCalled Get-ScheduledTask -ModuleName Transfer -Times 1 -Exactly -Scope It -ParameterFilter {$TaskPath -eq '\'}
        $script:fence.verifiedLocal=[DateTimeOffset]::Now.AddMinutes(1).ToString('o')
        Assert-PhaseThrows {Assert-SourceFence $script:manifest $script:fence synthetic}
    }
    It 'detects a relative writer recorded in the original fence' {
        $global:SyntheticFenceProcesses=@(@{CommandLine='node.exe relative-writer.js';ParentProcessId=1;ExecutablePath='C:\node.exe'})
        Assert-PhaseThrows {Assert-SourceFence $script:manifest $script:fence synthetic}
    }
    It 'excludes only the direct child using the exact reviewed snapshot script' {
        $child=@{parentProcessId=456;executable='C:\python.exe';scriptPath='C:\tools\sqlite_snapshot.py'}
        $process=@{CommandLine='"C:\python.exe" "C:\tools\sqlite_snapshot.py" --source C:\synthetic-source\capture.db';ParentProcessId=456;ExecutablePath='C:\python.exe'}
        $global:SyntheticFenceProcesses=@($process)
        Assert-SourceFence $script:manifest $script:fence synthetic -ReadOnlyChild $child
        $process.ParentProcessId=789
        Assert-PhaseThrows {Assert-SourceFence $script:manifest $script:fence synthetic -ReadOnlyChild $child}
        $process.ParentProcessId=456;$process.ExecutablePath='C:\other-python.exe'
        Assert-PhaseThrows {Assert-SourceFence $script:manifest $script:fence synthetic -ReadOnlyChild $child}
        $process.ExecutablePath='C:\python.exe';$process.CommandLine='"C:\python.exe" -c "print(''C:\tools\sqlite_snapshot.py --source C:\synthetic-source\capture.db'')"'
        Assert-PhaseThrows {Assert-SourceFence $script:manifest $script:fence synthetic -ReadOnlyChild $child}
    }
}

Describe 'Original source hash continuity without database connections' {
    It 'keeps the source content-check budget bounded to 300 seconds' {
        InModuleScope Placement {$script:SourceContentTimeoutSeconds|Should Be 300}
    }
    BeforeEach {
        $script:sourcePlan=@{
            observedHost='synthetic';transferManifest=@{
                source=@{root='C:\synthetic-source'}
                state=@(@{source='capture.db';target='backups\source\capture.db';kind='sqlite'})
            }
        }
        $script:sourceProof=@{directories=@();files=@(@{
            kind='sqlite';target='backups\source\capture.db'
            sourceHashes=@{main=('a'*64);'-wal'=$null;'-shm'=$null;'-journal'=$null}
        })}
        $global:SyntheticOriginalHashes=@{'\\synthetic.local\C$\synthetic-source\capture.db'=('a'*64)}
        Mock Test-Path -ModuleName Placement {param([string]$LiteralPath) $global:SyntheticOriginalHashes.ContainsKey($LiteralPath)}
        Mock Get-FileHash -ModuleName Placement {param([string]$LiteralPath) @{Hash=$global:SyntheticOriginalHashes[$LiteralPath]}}
    }
    AfterEach {Remove-Variable SyntheticOriginalHashes -Scope Global}
    It 'accepts the exact old main-file hash and absent sidecars' {
        Test-FrozenSourceContent $script:sourcePlan $script:sourceProof
        Assert-MockCalled Get-FileHash -ModuleName Placement -Times 1 -Exactly -Scope It
    }
    It 'rejects changed source content even when a writer already exited' {
        $global:SyntheticOriginalHashes['\\synthetic.local\C$\synthetic-source\capture.db']=('b'*64)
        Assert-PhaseThrows {Test-FrozenSourceContent $script:sourcePlan $script:sourceProof}
    }
    It 'rejects newly appearing sidecars and old exports without source baselines' {
        $global:SyntheticOriginalHashes['\\synthetic.local\C$\synthetic-source\capture.db-wal']=('c'*64)
        Assert-PhaseThrows {Test-FrozenSourceContent $script:sourcePlan $script:sourceProof}
        $script:sourceProof.files[0].Remove('sourceHashes')
        Assert-PhaseThrows {Test-FrozenSourceContent $script:sourcePlan $script:sourceProof}
    }
    It 'rejects extra source directory files before hashing listed content' {
        $script:sourcePlan.transferManifest.state+=@{source='raw';target='data\raw';kind='directory';required=$true}
        $script:sourceProof.directories=@('data\raw')
        Mock Get-StateInventory -ModuleName Placement {
            @{complete=$true;directories=@('data\raw');files=@(@{target='data\raw\unexpected.gz'})}
        }
        Assert-PhaseThrows {Test-FrozenSourceContent $script:sourcePlan $script:sourceProof}
        Assert-MockCalled Get-FileHash -ModuleName Placement -Times 0 -Exactly -Scope It
    }
}

Describe 'Prepared placement and stage-specific approval gates' {
    BeforeEach {
        $script:authority=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:SyntheticPhaseAuthority=$script:authority
        Mock Get-PlacementRoot -ModuleName Placement {$global:SyntheticPhaseAuthority}
        $script:plan=@{
            schemaVersion=2;id='phase-approval';app='synthetic';environment='production';operation='Cutover';observedHost='source'
            transitionKind='LegacyConversion';currentRelease=$null;releaseId='new-release';placementAuthority=$null
            target=@{host='synthetic';routeProfile='synthetic'};hostSnapshot=@{identity='target-uuid';verified=$true}
            databaseHostSnapshot=@{identity='target-uuid';verified=$true};sourceHostSnapshot=@{identity='source-uuid';verified=$true}
            databaseActionsRequired=$true
        }
        $script:plan.planHash=Get-PlanDigest $script:plan
    }
    AfterEach {Remove-Variable SyntheticPhaseAuthority -Scope Global}
    It 'requires exact Prepared authority, refusing absent, pending, unknown and another release' {
        Assert-PhaseThrows {Assert-PlacementUnchanged $script:plan -ResumePrepared}
        foreach($status in @('Pending','Unknown','Active')){
            Set-PlacementTransition $script:plan $status
            Assert-PhaseThrows {Assert-PlacementUnchanged $script:plan -ResumePrepared}
        }
        Set-PlacementTransition $script:plan Prepared
        Assert-PlacementUnchanged $script:plan -ResumePrepared
        $script:plan.releaseId='different-release'
        Assert-PhaseThrows {Assert-PlacementUnchanged $script:plan -ResumePrepared}
    }
    It 'allows only file preparation without inventing import or restored-backup gates' {
        $approval=@{
            planHash=$script:plan.planHash;hostIdentity='target-uuid';databaseHostIdentity='target-uuid'
            sourceHostIdentity='source-uuid';routeProfile='synthetic';actions=@('PrepareCutover');approvedBy='synthetic-review'
            expiresLocal=[DateTimeOffset]::Now.AddMinutes(5).ToString('o');transferSHA256=('a'*64);sourceFenceSHA256=('b'*64)
            gates=@{sourceCommitted=$true;artifactTrust=$true;hostProvisioning=$true;runtimeIdentity=$true;routePreconditions=$true
                clocksSynchronized=$true;gracefulStopVerified=$true;dataInventory=$true;rollbackReady=$true;filePreparationReviewed=$true}
        }
        $path=Join-Path $TestDrive 'phase-approval.json';Write-DeploymentJson $path $approval
        (Assert-DeploymentApproval $script:plan $path PrepareCutover).approvedBy|Should Be 'synthetic-review'
        Assert-PhaseThrows {Assert-DeploymentApproval $script:plan $path Cutover}
        $approval.gates.filePreparationReviewed=$false;Write-DeploymentJson $path $approval
        Assert-PhaseThrows {Assert-DeploymentApproval $script:plan $path PrepareCutover}
    }
}
