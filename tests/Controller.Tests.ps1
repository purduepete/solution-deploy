$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Controller.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\Transfer.psm1') -DisableNameChecking
function Assert-ControllerThrows([scriptblock]$Action){
    $thrown=$false
    try{&$Action|Out-Null}catch{$thrown=$true}
    $thrown|Should Be $true
}

Describe 'Protected submission and central placement with no remote writes' {
    BeforeEach {
        $global:SyntheticControllerRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:SyntheticControllerPlan=@{
            schemaVersion=2;id='synthetic-operation';app='synthetic-app';planHash='synthetic-hash';releaseId='new-release';environment='production'
            target=@{host='target';address='192.168.2.10';root='C:\ProgramData\SolutionDeploy'}
            hostSnapshot=@{identity='synthetic-uuid'};databaseHostSnapshot=@{identity='synthetic-uuid'}
            databaseTarget=@{host='database';address='192.168.2.20';root='C:\ProgramData\SolutionDeploy'}
        }
        $global:SyntheticPlacementStates=[Collections.Generic.List[string]]::new()
        $global:SyntheticPlacementLease=[IO.MemoryStream]::new()
        $global:SyntheticCimSession=[Microsoft.Management.Infrastructure.CimSession]::Create('synthetic-no-network')
        Write-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\installation.json') @{identity='synthetic-uuid';root='C:\ProgramData\SolutionDeploy'}
        $script:approval=Join-Path $global:SyntheticControllerRoot 'review.json'
        Write-DeploymentJson $script:approval @{purpose='synthetic no-remote test'}
        Mock Assert-DeploymentApproval -ModuleName Controller {@{}}
        Mock Get-HostSnapshot -ModuleName Controller {@{identity='synthetic-uuid'}}
        Mock Get-AdminSharePath -ModuleName Controller {$global:SyntheticControllerRoot}
        Mock Get-PlacementLease -ModuleName Controller {$global:SyntheticPlacementLease}
        Mock Assert-PlacementUnchanged -ModuleName Controller {}
        Mock Set-PlacementTransition -ModuleName Controller {
            param($Plan,$Status)
            $global:SyntheticPlacementStates.Add($Status)
        }
        Mock New-CimSessionOption -ModuleName Controller {}
        Mock New-CimSession -ModuleName Controller {$global:SyntheticCimSession}
        Mock Remove-CimSession -ModuleName Controller {}
        Mock Get-ScheduledTask -ModuleName Controller {[pscustomobject]@{State='Ready'}}
        Mock Get-CimInstance -ModuleName Controller {@()}
        Mock Start-Sleep -ModuleName Controller {}
        Mock Start-ScheduledTask -ModuleName Controller {
            $pending=Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json')
            Write-DeploymentJson (Join-Path $global:SyntheticControllerRoot "operations\$($pending.operationId)\result.json") @{
                operationId=$pending.operationId;planHash=$global:SyntheticControllerPlan.planHash;status='Succeeded'
                verification=@{releaseId='new-release'}
            }
        }
    }
    AfterEach {
        $global:SyntheticPlacementLease.Dispose()
        $global:SyntheticCimSession.Dispose()
        foreach($name in @('SyntheticControllerRoot','SyntheticControllerPlan','SyntheticPlacementStates','SyntheticPlacementLease','SyntheticCimSession')){
            Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'uses the executor in JimlerTech and records active authority only after success' {
        $result=Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy
        $result.status|Should Be Succeeded
        ($global:SyntheticPlacementStates -join ',')|Should Be 'Pending,Active'
        $global:SyntheticPlacementLease.CanRead|Should Be $false
        Assert-MockCalled Start-ScheduledTask -ModuleName Controller -Times 1 -Exactly -Scope It -ParameterFilter {
            $TaskName -eq 'SolutionDeploy-Executor' -and $TaskPath -eq '\JimlerTech\'
        }
    }
    It 'leaves failed or unknown execution blocked and releases the central lease' {
        Mock Start-ScheduledTask -ModuleName Controller {throw 'Synthetic task start failure'}
        Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy}
        ($global:SyntheticPlacementStates -join ',')|Should Be 'Pending,Unknown'
        $global:SyntheticPlacementLease.CanRead|Should Be $false
    }
    It 'does not change placement while running protected preflight' {
        (Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Preflight).status | Should Be Succeeded
        $global:SyntheticPlacementStates.Count | Should Be 0
    }
    It 'waits for a running executor before writing the next pending request' {
        $global:SyntheticTaskStateReads=0
        Mock Get-ScheduledTask -ModuleName Controller {
            $global:SyntheticTaskStateReads++
            [pscustomobject]@{State=if($global:SyntheticTaskStateReads -eq 1){'Running'}else{'Ready'}}
        }
        (Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy -PollIntervalSeconds 0.1).status|Should Be Succeeded
        $global:SyntheticTaskStateReads|Should BeGreaterThan 2
        $global:SyntheticPlacementStates.Count|Should Be 2
        Remove-Variable SyntheticTaskStateReads -Scope Global
    }
    It 'waits for an active executor process even when the task reports Ready' {
        $global:SyntheticProcessReads=0
        Mock Get-CimInstance -ModuleName Controller {
            $global:SyntheticProcessReads++
            if($global:SyntheticProcessReads -eq 1){
                [pscustomobject]@{CommandLine='pwsh.exe Invoke-HostExecutor.ps1'}
            }
        }
        (Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy -PollIntervalSeconds 0.1).status|Should Be Succeeded
        $global:SyntheticProcessReads|Should BeGreaterThan 1
        Remove-Variable SyntheticProcessReads -Scope Global
    }
    It 'does not write a pending request when the submission lock wait expires' {
        $handle=Get-DeploymentLock (Join-Path $global:SyntheticControllerRoot 'control\submission.lock')
        try {
            Assert-ControllerThrows {
                Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy -SubmissionWaitTimeoutSeconds 1 -PollIntervalSeconds 0.1
            }
            Test-Path (Join-Path $global:SyntheticControllerRoot 'control\pending.json')|Should Be $false
            Test-Path (Join-Path $global:SyntheticControllerRoot 'operations\synthetic-operation-deploy')|Should Be $false
        } finally {$handle.Dispose()}
    }
    It 'waits for a prior pending operation with a matching terminal result' {
        $previousId='prior-operation-deploy'
        $previous=Join-Path $global:SyntheticControllerRoot "operations\$previousId"
        $previousRequest=@{operationId=$previousId;plan=@{planHash='prior-hash'}}
        Write-DeploymentJson (Join-Path $previous 'request.json') $previousRequest
        $previousHash=(Get-FileHash (Join-Path $previous 'request.json')).Hash.ToLowerInvariant()
        Write-DeploymentJson (Join-Path $previous 'result.json') @{operationId=$previousId;planHash='prior-hash';status='Succeeded'}
        Write-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json') @{operationId=$previousId;requestSHA256=$previousHash}
        (Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy).status|Should Be Succeeded
        (Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json')).operationId|Should Be 'synthetic-operation-deploy'
    }
    It 'rejects a terminal result that belongs to a different operation' {
        $previousId='mismatched-operation-deploy'
        $previous=Join-Path $global:SyntheticControllerRoot "operations\$previousId"
        Write-DeploymentJson (Join-Path $previous 'request.json') @{operationId=$previousId;plan=@{planHash='prior-hash'}}
        $previousHash=(Get-FileHash (Join-Path $previous 'request.json')).Hash.ToLowerInvariant()
        Write-DeploymentJson (Join-Path $previous 'result.json') @{operationId='other-operation';planHash='prior-hash';status='Succeeded'}
        Write-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json') @{operationId=$previousId;requestSHA256=$previousHash}
        Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy}
        (Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json')).operationId|Should Be $previousId
        Assert-MockCalled Start-ScheduledTask -ModuleName Controller -Times 0 -Exactly -Scope It
    }
    It 'fails closed when an idle executor has an unresolved pending operation' {
        $previousId='stale-operation-deploy'
        $previous=Join-Path $global:SyntheticControllerRoot "operations\$previousId"
        Write-DeploymentJson (Join-Path $previous 'request.json') @{operationId=$previousId;plan=@{planHash='stale-hash'}}
        $previousHash=(Get-FileHash (Join-Path $previous 'request.json')).Hash.ToLowerInvariant()
        Write-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json') @{operationId=$previousId;requestSHA256=$previousHash}
        Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy -PollIntervalSeconds 0.1}
        (Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json')).operationId|Should Be $previousId
        Test-Path (Join-Path $global:SyntheticControllerRoot 'operations\synthetic-operation-deploy')|Should Be $false
        Assert-MockCalled Start-ScheduledTask -ModuleName Controller -Times 0 -Exactly -Scope It
    }
    It 'does not resubmit after a post-submit deadline leaves the result unknown' {
        Mock Start-ScheduledTask -ModuleName Controller {}
        Assert-ControllerThrows {
            Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy -TimeoutSeconds 1 -PollIntervalSeconds 0.1
        }
        $pending=Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json')
        $pending.operationId|Should Be 'synthetic-operation-deploy'
        Test-Path (Join-Path $global:SyntheticControllerRoot 'operations\synthetic-operation-deploy\result.json')|Should Be $false
        Assert-MockCalled Start-ScheduledTask -ModuleName Controller -Times 1 -Exactly -Scope It
    }
    It 'requires the protected routine preflight result before recording Pending' {
        $global:SyntheticControllerPlan.routineRelease=$true
        Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy}
        $global:SyntheticPlacementStates.Count | Should Be 0
        Assert-MockCalled Start-ScheduledTask -ModuleName Controller -Times 0 -Exactly -Scope It
    }
    It 'restores conclusive clean-abort placement instead of unconditionally writing Unknown' {
        Mock Restore-VerifiedPlacement -ModuleName Controller {}
        Mock Start-ScheduledTask -ModuleName Controller {
            $pending=Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json')
            Write-DeploymentJson (Join-Path $global:SyntheticControllerRoot "operations\$($pending.operationId)\result.json") @{
                operationId=$pending.operationId;planHash=$global:SyntheticControllerPlan.planHash;status='Failed';cleanAbort=$true
            }
        }
        Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy}
        ($global:SyntheticPlacementStates -join ',') | Should Be 'Pending'
        Assert-MockCalled Restore-VerifiedPlacement -ModuleName Controller -Times 1 -Exactly -Scope It
    }
    It 'keeps Unknown when clean-abort reconciliation cannot be verified' {
        Mock Restore-VerifiedPlacement -ModuleName Controller {throw 'Recovery verification failed'}
        Mock Start-ScheduledTask -ModuleName Controller {
            $pending=Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json')
            Write-DeploymentJson (Join-Path $global:SyntheticControllerRoot "operations\$($pending.operationId)\result.json") @{
                operationId=$pending.operationId;planHash=$global:SyntheticControllerPlan.planHash;status='Failed';cleanAbort=$true
            }
        }
        Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy}
        ($global:SyntheticPlacementStates -join ',') | Should Be 'Pending,Unknown'
    }
    It 'releases the lease even if recording unknown authority fails' {
        Mock Start-ScheduledTask -ModuleName Controller {throw 'Synthetic task start failure'}
        Mock Set-PlacementTransition -ModuleName Controller {
            param($Plan,$Status)
            if($Status -eq 'Unknown'){throw 'Synthetic authority share unavailable'}
        }
        Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy}
        $global:SyntheticPlacementLease.CanRead|Should Be $false
    }
    It 'does not change placement while performing live verification' {
        (Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Verify).status|Should Be Succeeded
        $global:SyntheticPlacementStates.Count|Should Be 0
        Assert-MockCalled Assert-PlacementUnchanged -ModuleName Controller -Times 1 -Exactly -Scope It -ParameterFilter {$Verify}
    }
    It 'rejects database host identity drift before a target operation' {
        Mock Get-HostSnapshot -ModuleName Controller {@{identity='wrong-uuid'}}
        Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy}
        Assert-MockCalled Start-ScheduledTask -ModuleName Controller -Times 0 -Exactly -Scope It
    }
    It 'records prepared authority without marking a runtime active' {
        $export=Join-Path $global:SyntheticControllerRoot 'synthetic-export'
        $global:SyntheticControllerPlan.observedHost='source'
        Write-DeploymentJson (Join-Path $export 'transfer.json') @{files=@();fence=@{synthetic=$true}}
        $hash=(Get-FileHash (Join-Path $export 'transfer.json')).Hash.ToLowerInvariant()
        $global:SyntheticTransferHash=$hash
        Mock Assert-DeploymentApproval -ModuleName Controller {@{transferSHA256=$global:SyntheticTransferHash}}
        Mock Test-RemoteSourceFence -ModuleName Controller {@{verified=$true}}
        Mock Start-ScheduledTask -ModuleName Controller {
            $pending=Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json')
            Write-DeploymentJson (Join-Path $global:SyntheticControllerRoot "operations\$($pending.operationId)\result.json") @{
                operationId=$pending.operationId;planHash=$global:SyntheticControllerPlan.planHash;status='Succeeded';phase='Prepared'
                verification=@{releaseId='new-release';runtimeStarted=$false;preparedStateSHA256=('a'*64)}
            }
        }
        try {
            (Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval PrepareCutover -TransferDirectory $export).phase|Should Be Prepared
            ($global:SyntheticPlacementStates -join ',')|Should Be 'Pending,Prepared'
        } finally {Remove-Variable SyntheticTransferHash -Scope Global}
        $request=Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'operations\synthetic-operation-preparecutover\request.json')
        $request.ContainsKey('transferArchiveSHA256')|Should Be $false
        Test-Path (Join-Path $global:SyntheticControllerRoot 'operations\synthetic-operation-preparecutover\transfer\transfer.json')|Should Be $true
    }
    It 'stages by default with only the approved source archive and no transfer payload' {
        Mock Get-DeploymentEnvironment -ModuleName Controller {@{Value=@{apps=@{'synthetic-app'=@{manifest='apps\synthetic\deploy\application.json'}}}}}
        Mock Get-Command -ModuleName Controller {[pscustomobject]@{Source='C:\synthetic\git.exe'}}
        Mock Invoke-DeploymentCommand -ModuleName Controller {
            param($FilePath,$Arguments,$WorkingDirectory,[switch]$Capture)
            if($Arguments -contains 'archive'){[IO.File]::WriteAllText(($Arguments|Where-Object {$_ -like '-o*'}).Substring(2),'synthetic-source')}
        }
        $global:SyntheticSourceHash=(Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('synthetic-source')))).Hash.ToLowerInvariant()
        Mock Assert-DeploymentApproval -ModuleName Controller {@{sourceArchiveSHA256=$global:SyntheticSourceHash}}
        $global:SyntheticControllerPlan.sourceCommit='0123456789abcdef'
        try{
            (Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Stage -RuntimePath 'C:\synthetic\node.exe').status|Should Be Succeeded
        }finally{Remove-Variable SyntheticSourceHash -Scope Global}
        $operation=Join-Path $global:SyntheticControllerRoot 'operations\synthetic-operation-stage'
        $request=Read-DeploymentJson (Join-Path $operation 'request.json')
        $request.sourceArchiveSHA256|Should Be (Get-FileHash (Join-Path $operation 'source.zip')).Hash.ToLowerInvariant()
        $request.transferSHA256|Should BeNullOrEmpty
        $request.ContainsKey('transferArchiveSHA256')|Should Be $false
        Test-Path (Join-Path $operation 'transfer.zip')|Should Be $false
        Test-Path (Join-Path $operation 'transfer')|Should Be $false
        $global:SyntheticPlacementStates.Count|Should Be 0
    }
    Context 'optional compressed transfer archive' {
        BeforeEach {
            $global:SyntheticControllerPlan.observedHost='source'
            $export=Join-Path $global:SyntheticControllerRoot 'synthetic-export'
            [IO.Directory]::CreateDirectory((Join-Path $export 'data'))|Out-Null
            [IO.File]::WriteAllText((Join-Path $export 'data\app.db'),'synthetic-state')
            $fileHash=(Get-FileHash (Join-Path $export 'data\app.db')).Hash.ToLowerInvariant()
            Write-DeploymentJson (Join-Path $export 'transfer.json') @{planHash='synthetic-hash';operationId='synthetic-operation';fence=@{synthetic=$true};files=@(@{target='data\app.db';kind='file';bytes=15;sha256=$fileHash})}
            $global:SyntheticTransferHash=(Get-FileHash (Join-Path $export 'transfer.json')).Hash.ToLowerInvariant()
            $outRoot=Join-Path $global:SyntheticControllerRoot 'archives'
            [IO.Directory]::CreateDirectory($outRoot)|Out-Null
            $created=New-TransferArchive $export $global:SyntheticTransferHash $outRoot 'state.zip'
            $global:SyntheticArchive=$created.archivePath
            $global:SyntheticArchiveHash=$created.archiveSHA256
            $global:SyntheticExport=$export
            Mock Assert-DeploymentApproval -ModuleName Controller {@{transferSHA256=$global:SyntheticTransferHash;transferArchiveSHA256=$global:SyntheticArchiveHash}}
            Mock Test-RemoteSourceFence -ModuleName Controller {@{verified=$true;proofOperation=$TransferProof.operationId}}
            Mock Start-ScheduledTask -ModuleName Controller {
                $pending=Read-DeploymentJson (Join-Path $global:SyntheticControllerRoot 'control\pending.json')
                Write-DeploymentJson (Join-Path $global:SyntheticControllerRoot "operations\$($pending.operationId)\result.json") @{
                    operationId=$pending.operationId;planHash=$global:SyntheticControllerPlan.planHash;status='Succeeded';phase='Prepared'
                    verification=@{releaseId='new-release';runtimeStarted=$false;preparedStateSHA256=('a'*64)}
                }
            }
        }
        AfterEach {
            foreach($name in @('SyntheticTransferHash','SyntheticArchive','SyntheticArchiveHash','SyntheticExport')){Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue}
        }
        It 'copies one approved archive and leaves extraction to the protected executor' {
            (Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval PrepareCutover -TransferArchivePath $global:SyntheticArchive).phase|Should Be Prepared
            $operation=Join-Path $global:SyntheticControllerRoot 'operations\synthetic-operation-preparecutover'
            (Get-FileHash (Join-Path $operation 'transfer.zip')).Hash.ToLowerInvariant()|Should Be $global:SyntheticArchiveHash
            Test-Path (Join-Path $operation 'transfer')|Should Be $false
            $request=Read-DeploymentJson (Join-Path $operation 'request.json')
            $request.transferArchiveSHA256|Should Be $global:SyntheticArchiveHash
            $request.transferSHA256|Should Be $global:SyntheticTransferHash
            $request.sourceFenceVerification.proofOperation|Should Be 'synthetic-operation'
            ($global:SyntheticPlacementStates -join ',')|Should Be 'Pending,Prepared'
            Assert-MockCalled Test-RemoteSourceFence -ModuleName Controller -Times 1 -Exactly -Scope It -ParameterFilter {$TransferContinuity}
        }
        It 'rejects a changed archive without falling back or starting the executor' {
            [IO.File]::AppendAllText($global:SyntheticArchive,'x')
            Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval PrepareCutover -TransferArchivePath $global:SyntheticArchive}
            Assert-MockCalled Start-ScheduledTask -ModuleName Controller -Times 0 -Exactly -Scope It
            $global:SyntheticPlacementStates.Count|Should Be 0
        }
        It 'requires approval to bind transferArchiveSHA256' {
            Mock Assert-DeploymentApproval -ModuleName Controller {@{transferSHA256=$global:SyntheticTransferHash}}
            Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval PrepareCutover -TransferArchivePath $global:SyntheticArchive}
            Assert-MockCalled Get-PlacementLease -ModuleName Controller -Times 0 -Exactly -Scope It
        }
        It 'refuses directory transport when approval binds an archive' {
            Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval PrepareCutover -TransferDirectory $global:SyntheticExport}
            Assert-MockCalled Start-ScheduledTask -ModuleName Controller -Times 0 -Exactly -Scope It
        }
        It 'refuses both transports together and archives on non-transfer actions' {
            Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval PrepareCutover -TransferDirectory $global:SyntheticExport -TransferArchivePath $global:SyntheticArchive}
            Assert-ControllerThrows {Submit-DeploymentOperation $global:SyntheticControllerPlan $script:approval Deploy -TransferArchivePath $global:SyntheticArchive}
            Assert-MockCalled Start-ScheduledTask -ModuleName Controller -Times 0 -Exactly -Scope It
        }
    }
}
