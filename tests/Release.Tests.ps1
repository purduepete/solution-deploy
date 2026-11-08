$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Release.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking
function Assert-ReleaseThrows([scriptblock]$Action) {
    $thrown=$false
    try{& $Action|Out-Null}catch{$thrown=$true}
    $thrown|Should Be $true
}

Describe 'Routine Release orchestration without production access' {
    BeforeEach {
        $global:ReleaseTestPlan=@{
            id=[guid]::NewGuid().ToString('N');app='sample';environment='production';sourceCommit=('a'*40)
            transitionKind='ManagedDeploy';operation='Deploy';environmentHash=('b'*64);manifestHash=('c'*64)
            target=@{host='synthetic';root='C:\ProgramData\SolutionDeploy';routeProfile='synthetic'}
            hostSnapshot=@{identity='app-identity';verified=$true};databaseHostSnapshot=@{identity='db-identity';verified=$true}
            databaseTarget=@{host='synthetic'};currentRelease=@{releaseId='old';planHash='old-plan'};observedHost='synthetic'
            manifest=@{
                launch=@{port=8801;environment=@{ALLOWED_ORIGINS='https://synthetic.example.ts.net:8801'}}
                readiness=@{path='/api/health';expected=@{ok=$true}}
                routes=@(@{hostname='sample.jimlertech.com'})
            }
        }
        $global:ReleaseTestPlan.planHash=Get-PlanDigest $global:ReleaseTestPlan
        $global:ReleaseTestOutput=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:ReleaseTestActions=@()
        $global:ReleaseTestApprovals=@()
        $global:ReleaseTestFail=$null
        Mock New-DeploymentPlan -ModuleName Release {$global:ReleaseTestPlan}
        Mock Get-RoutineReleaseContext -ModuleName Release {
            @{
                runtimePath='C:\synthetic\node.exe';runtimeSHA256=('d'*64);npmPath='C:\synthetic\npm.cmd'
                npmSHA256=('e'*64);npmCliSHA256=('f'*64);installationSHA256=('1'*64);priorApprovalSHA256=('2'*64)
                approvalFields=@{expectedSchemaFingerprint=('3'*64);migrationSqlSHA256=('4'*64)}
            }
        }
        Mock Assert-ReleaseClocks -ModuleName Release {}
        Mock Assert-ReleaseTools -ModuleName Release {}
        Mock Assert-PlanInputs -ModuleName Release {}
        Mock Get-DeploymentEnvironment -ModuleName Release {@{Value=@{apps=@{sample=@{manifest='sample\deploy\application.json'}}}}}
        Mock Invoke-DeploymentCommand -ModuleName Release {
            if($Arguments[0] -eq 'for-each-ref'){return 'refs/remotes/origin/main'}
            if($Arguments[0] -eq 'archive'){[IO.File]::WriteAllText($Arguments[2].Substring(2),'Synthetic source archive')}
        }
        Mock Test-ReleaseAccess -ModuleName Release {
            @{tailscale=@{verified=$true};cloudflare=@{verified=$true};verifiedLocal=(Get-Date).ToString('o')}
        }
        Mock Submit-DeploymentOperation -ModuleName Release {
            $global:ReleaseTestActions+=@($Action)
            $global:ReleaseTestApprovals+=@(Read-DeploymentJson $ApprovalPath)
            if($Action -eq $global:ReleaseTestFail){throw 'Synthetic protected phase failure'}
            @{
                status='Succeeded';planHash=$Plan.planHash
                verification=@{databaseEvidencePath=('routine-'+$Plan.id+'.json');databaseEvidenceSHA256=('5'*64)}
            }
        }
    }
    AfterEach {
        Get-Variable -Scope Global -Name 'ReleaseTest*'|Remove-Variable -Scope Global
    }
    It 'runs every phase in order and persists success only after both external checks' {
        $result=Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason 'Reviewed synthetic fixture' -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput
        ($global:ReleaseTestActions -join ',')|Should Be 'Stage,Preflight,Deploy,Verify'
        $result.status|Should Be 'Succeeded'
        $result.externalAcceptance|Should Be 'Verified'
        $saved=Read-DeploymentJson (Join-Path $global:ReleaseTestOutput ('releases\'+$global:ReleaseTestPlan.id+'\release.json'))
        $saved.status|Should Be 'Succeeded'
        Assert-MockCalled Test-ReleaseAccess -ModuleName Release -Times 2 -Exactly -Scope It
        Assert-MockCalled Assert-ReleaseClocks -ModuleName Release -Times 5 -Exactly -Scope It
    }
    It 'records an approved manifest hash in the consent and passes it to the context check' {
        Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput -ApprovedManifestSHA256 ('7'*64)|Out-Null
        $saved=Read-DeploymentJson (Join-Path $global:ReleaseTestOutput ('releases\'+$global:ReleaseTestPlan.id+'\plan.json'))
        $saved.routineConsent.approvedManifestSHA256|Should Be ('7'*64)
        Assert-MockCalled Get-RoutineReleaseContext -ModuleName Release -Times 1 -Exactly -Scope It -ParameterFilter {$ApprovedManifestSHA256 -eq ('7'*64)}
    }
    It 'signs an unused npm path as the empty string sent by the typed controller parameter' {
        Mock Get-RoutineReleaseContext -ModuleName Release {
            @{
                runtimePath='C:\synthetic\python.exe';runtimeSHA256=('d'*64);npmPath=$null
                npmSHA256=$null;npmCliSHA256=$null;installationSHA256=('1'*64);priorApprovalSHA256=('2'*64)
                approvalFields=@{expectedSchemaFingerprint=('3'*64);migrationSqlSHA256=('4'*64)}
            }
        }
        Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput|Out-Null
        $saved=Read-DeploymentJson (Join-Path $global:ReleaseTestOutput ('releases\'+$global:ReleaseTestPlan.id+'\plan.json'))
        ($null -eq $saved.routineConsent.npmPath)|Should Be $false
        $saved.routineConsent.npmPath|Should Be ''
        $saved.routineConsent.runtimePath|Should Be 'C:\synthetic\python.exe'
        Assert-MockCalled Submit-DeploymentOperation -ModuleName Release -Times 4 -Exactly -Scope It -ParameterFilter {
            [string]$NpmPath -ceq $Plan.routineConsent.npmPath
        }
    }
    It 'binds preflight evidence only into later approvals without changing the plan digest' {
        Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput|Out-Null
        $global:ReleaseTestApprovals[0].ContainsKey('databaseEvidenceSHA256')|Should Be $false
        $global:ReleaseTestApprovals[1].ContainsKey('databaseEvidenceSHA256')|Should Be $false
        $global:ReleaseTestApprovals[2].databaseEvidenceSHA256|Should Be ('5'*64)
        $global:ReleaseTestApprovals[3].databaseEvidenceSHA256|Should Be ('5'*64)
        @($global:ReleaseTestApprovals.planHash|Sort-Object -Unique).Count|Should Be 1
        $global:ReleaseTestPlan.planHash|Should Be (Get-PlanDigest $global:ReleaseTestPlan)
        $global:ReleaseTestApprovals[0].gates.ContainsKey('schemaCompatible')|Should Be $false
        $global:ReleaseTestApprovals[2].gates.schemaCompatible|Should Be $true
        $global:ReleaseTestApprovals[2].gates.ContainsKey('postgresBackupRestoreVerified')|Should Be $false
        $global:ReleaseTestApprovals[2].gates.ContainsKey('independentDatabaseReview')|Should Be $false
    }
    It 'rejects missing release consent before planning' {
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApprovalReason reviewed -DatabaseChangesReviewed}
        Assert-MockCalled New-DeploymentPlan -ModuleName Release -Times 0 -Exactly -Scope It
    }
    It 'requires explicit review of application database writes' {
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed}
        Assert-MockCalled New-DeploymentPlan -ModuleName Release -Times 0 -Exactly -Scope It
    }
    It 'rejects a blank reason and an expiry outside the consent window' {
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason ' ' -DatabaseChangesReviewed}
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -ExpiresLocal ([DateTimeOffset]::Now.AddHours(2))}
        Assert-MockCalled New-DeploymentPlan -ModuleName Release -Times 0 -Exactly -Scope It
    }
    It 'requires a pushed immutable commit' {
        Mock Invoke-DeploymentCommand -ModuleName Release {''}
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput}
        Assert-MockCalled Submit-DeploymentOperation -ModuleName Release -Times 0 -Exactly -Scope It
    }
    It 'stops after preflight failure without Deploy or automatic rollback' {
        $global:ReleaseTestFail='Preflight'
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput}
        ($global:ReleaseTestActions -join ',')|Should Be 'Stage,Preflight'
        $saved=Read-DeploymentJson (Join-Path $global:ReleaseTestOutput ('releases\'+$global:ReleaseTestPlan.id+'\release.json'))
        $saved.status|Should Be 'Failed'
        $saved.externalAcceptance|Should Be 'Pending'
    }
    It 'does not automatically recover after Deploy has failed' {
        $global:ReleaseTestFail='Deploy'
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput}
        ($global:ReleaseTestActions -join ',')|Should Be 'Stage,Preflight,Deploy'
    }
    It 'requires matching protected evidence before requesting Deploy' {
        Mock Submit-DeploymentOperation -ModuleName Release {@{status='Succeeded';planHash=$Plan.planHash;verification=@{databaseEvidencePath='';databaseEvidenceSHA256=''}}}
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput}
        Assert-MockCalled Submit-DeploymentOperation -ModuleName Release -Times 0 -Exactly -Scope It -ParameterFilter {$Action -eq 'Deploy'}
    }
    It 'records external acceptance failure honestly after successful protected phases' {
        Mock Test-ReleaseAccess -ModuleName Release {
            if($global:ReleaseTestActions.Count -eq 4){throw 'Synthetic public Access failure'}
            @{tailscale=@{verified=$true};cloudflare=@{verified=$true}}
        }
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput}
        $saved=Read-DeploymentJson (Join-Path $global:ReleaseTestOutput ('releases\'+$global:ReleaseTestPlan.id+'\release.json'))
        $saved.status|Should Be 'Failed'
        $saved.externalAcceptance|Should Be 'Pending'
        $saved.phases.Count|Should Be 4
    }
    It 'does not renew expired consent after preflight' {
        Mock Submit-DeploymentOperation -ModuleName Release {
            if($Action -eq 'Preflight'){
                $Plan.routineConsent.expiresLocal=([DateTimeOffset]::Now.AddMinutes(-1)).ToString('o')
                $Plan.planHash=Get-PlanDigest $Plan
            }
            @{status='Succeeded';planHash=$Plan.planHash;verification=@{databaseEvidencePath='proof.json';databaseEvidenceSHA256=('5'*64)}}
        }
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput}
        Assert-MockCalled Submit-DeploymentOperation -ModuleName Release -Times 0 -Exactly -Scope It -ParameterFilter {$Action -eq 'Deploy'}
    }
    It 'checks environment and manifest drift before each protected action' {
        Mock Assert-PlanInputs -ModuleName Release {throw 'Synthetic environment drift'}
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput}
        Assert-MockCalled Submit-DeploymentOperation -ModuleName Release -Times 0 -Exactly -Scope It
    }
    It 'rejects tool drift before submitting any protected action' {
        Mock Assert-ReleaseTools -ModuleName Release {throw 'Synthetic runtime drift'}
        Assert-ReleaseThrows {Invoke-RoutineRelease sample -Target synthetic -ApproveRelease -ApprovalReason reviewed -DatabaseChangesReviewed -OutputDirectory $global:ReleaseTestOutput}
        Assert-MockCalled Submit-DeploymentOperation -ModuleName Release -Times 0 -Exactly -Scope It
    }
}

Describe 'Routine Release private origin constraints' {
    BeforeEach {
        $global:ReleaseAccessPlan=@{
            target=@{host='synthetic'}
            manifest=@{launch=@{port=8801};readiness=@{path='/api/health';expected=@{ok=$true}};routes=@(@{hostname='sample.jimlertech.com'})}
        }

        Mock Invoke-ReleaseAccessRequest -ModuleName Release {
            if($Uri.Host -like '*.ts.net'){@{statusCode=200;body='{"ok":true}';location=$null}}
            else{@{statusCode=302;body='';location=[uri]'https://team.cloudflareaccess.com/cdn-cgi/access/login/sample.jimlertech.com'}}
        }
    }
    AfterEach {Remove-Variable ReleaseAccessPlan -Scope Global}
    It 'requires private readiness and a public Access login redirect' {
        $result=Test-ReleaseAccess $global:ReleaseAccessPlan 'https://synthetic.example.ts.net:8801'
        $result.tailscale.verified|Should Be $true
        $result.cloudflare.verified|Should Be $true
        Assert-MockCalled Invoke-ReleaseAccessRequest -ModuleName Release -Times 2 -Exactly -Scope It
    }
    It 'rejects a public HTTP 200 response even if Tailscale is healthy' {
        Mock Invoke-ReleaseAccessRequest -ModuleName Release {@{statusCode=200;body='{"ok":true}';location=$null}}
        Assert-ReleaseThrows {Test-ReleaseAccess $global:ReleaseAccessPlan 'https://synthetic.example.ts.net:8801'}
    }
    It 'rejects a healthy public redirect when private readiness differs' {
        Mock Invoke-ReleaseAccessRequest -ModuleName Release {@{statusCode=200;body='{"ok":false}';location=$null}}
        Assert-ReleaseThrows {Test-ReleaseAccess $global:ReleaseAccessPlan 'https://synthetic.example.ts.net:8801'}
        Assert-MockCalled Invoke-ReleaseAccessRequest -ModuleName Release -Times 1 -Exactly -Scope It
    }
    It 'rejects an unrelated public redirect' {
        Mock Invoke-ReleaseAccessRequest -ModuleName Release {
            if($Uri.Host -like '*.ts.net'){@{statusCode=200;body='{"ok":true}';location=$null}}
            else{@{statusCode=302;body='';location=[uri]'https://example.com/cdn-cgi/access/login/sample.jimlertech.com'}}
        }
        Assert-ReleaseThrows {Test-ReleaseAccess $global:ReleaseAccessPlan 'https://synthetic.example.ts.net:8801'}
    }
    It 'rejects a private origin for a different host' {
        Assert-ReleaseThrows {Test-ReleaseAccess $global:ReleaseAccessPlan 'https://another.example.ts.net:8801'}
        Assert-MockCalled Invoke-ReleaseAccessRequest -ModuleName Release -Times 0 -Exactly -Scope It
    }
    It 'rejects public, plaintext and implicit-port private origins without making a request' {
        $plan=@{target=@{host='synthetic'};manifest=@{launch=@{port=8801}}}
        Assert-ReleaseThrows {Test-ReleaseAccess $plan 'http://synthetic.ts.net:8801'}
        Assert-ReleaseThrows {Test-ReleaseAccess $plan 'https://example.com:8801'}
        Assert-ReleaseThrows {Test-ReleaseAccess $plan 'https://synthetic.ts.net'}
        Assert-ReleaseThrows {Test-ReleaseAccess $plan 'https://synthetic.ts.net:8801/path'}
    }
    It 'rejects new installations before reading protected host records' {
        Assert-ReleaseThrows {Get-RoutineReleaseContext @{transitionKind='FirstInstall';operation='Deploy';currentRelease=$null;observedHost='synthetic';target=@{host='synthetic'}}}
    }
}

Describe 'Routine Release prior approval context' {
    BeforeEach {
        $global:ReleaseContextManifest=@{build=@{commands=@()};database=@{name='sample';schemaVersion=1}}
        $global:ReleaseContextPrior=@{
            operationId='prior-deploy';action='Deploy';plan=@{planHash='prior';manifest=$global:ReleaseContextManifest}
            approval=@{
                gates=@{gracefulStopVerified=$true;dataInventory=$true;rollbackReady=$true}
                psqlPath='C:\fixed\psql.exe';psqlSHA256=('b'*64);postgresPassFile='postgres.pgpass'
                postgresRuntimeRole='sd_sample_runtime';postgresEndpointSHA256=('b'*64);migrationSqlSHA256=('b'*64)
            }
        }
        $global:ReleaseContextPlan=@{
            app='sample';transitionKind='ManagedDeploy';operation='Deploy';observedHost='synthetic'
            target=@{host='synthetic';root='C:\fixed'};hostSnapshot=@{identity='identity'}
            currentRelease=@{planHash='prior';releaseId='old';sourceCommit=('a'*40)};manifest=$global:ReleaseContextManifest
        }
        Mock Get-RemoteDeploymentRoot -ModuleName Release {'C:\synthetic'}
        Mock Resolve-OwnedPath -ModuleName Release {Join-Path $Root $RelativePath}
        Mock Test-Path -ModuleName Release {$true}
        Mock Get-ChildItem -ModuleName Release {@{FullName='C:\synthetic\operations\prior-deploy'}}
        Mock Get-FileHash -ModuleName Release {@{Hash=('b'*64)}}
        Mock Get-ReleaseToolHash -ModuleName Release {('b'*64)}
        Mock Read-DeploymentJson -ModuleName Release {
            switch -Wildcard ($Path){
                '*installation.json' {@{identity='identity';root='C:\fixed';files=@(@{path='src\RoutineRelease.psm1';sha256=('b'*64)})}}
                '*active.json' {@{planHash='prior';releaseId='old'}}
                '*release.json' {@{planHash='prior';releaseId='old';sourceCommit=('a'*40);runtimePath='C:\fixed\node.exe';runtimeSHA256=('b'*64)}}
                '*verification.json' {@{planHash='prior';releaseId='old';status='RuntimeVerified';readiness=@{ready=$true};database=@{schemaFingerprint=('b'*64)}}}
                '*request.json' {$global:ReleaseContextPrior}
                '*result.json' {@{planHash='prior';status='Succeeded';operationId='prior-deploy'}}
                default {throw 'Unexpected synthetic read'}
            }
        }
    }
    AfterEach {Get-Variable -Scope Global -Name 'ReleaseContext*'|Remove-Variable -Scope Global}
    It 'uses verified fixed runtime and approved database settings without fabricating database gates' {
        $context=Get-RoutineReleaseContext $global:ReleaseContextPlan
        $context.runtimePath|Should Be 'C:\fixed\node.exe'
        $context.approvalFields.psqlPath|Should Be 'C:\fixed\psql.exe'
        $context.approvalFields.expectedSchemaFingerprint|Should Be ('b'*64)
        $context.approvalFields.ContainsKey('gates')|Should Be $false
        $context.approvalFields.ContainsKey('databaseEvidencePath')|Should Be $false
    }
    It 'rejects a release record from another immutable commit' {
        $global:ReleaseContextPlan.currentRelease.sourceCommit=('c'*40)
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan}
    }
    It 'rejects missing prior stop capability approval' {
        $global:ReleaseContextPrior.approval.gates.gracefulStopVerified=$false
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan}
    }
    It 'rejects manifest changes before deriving any inherited approval' {
        $global:ReleaseContextPlan.manifest=@{build=@{commands=@()};database=@{name='different';schemaVersion=1}}
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan}
    }
    It 'accepts a build-only manifest change only with its exact approved hash' {
        $global:ReleaseContextPlan.manifest=@{build=@{commands=@(@{tool='npm';arguments=@('prune')})};database=@{name='sample';schemaVersion=1}}
        $global:ReleaseContextPlan.manifestHash=('9'*64)
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan}
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan -ApprovedManifestSHA256 ('8'*64)}
        (Get-RoutineReleaseContext $global:ReleaseContextPlan -ApprovedManifestSHA256 ('9'*64)).runtimePath|Should Be 'C:\fixed\node.exe'
    }
    It 'rejects an approved hash for a change outside build commands or an unchanged manifest' {
        $global:ReleaseContextPlan.manifestHash=('9'*64)
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan -ApprovedManifestSHA256 ('9'*64)}
        $global:ReleaseContextPlan.manifest=@{build=@{commands=@()};database=@{name='different';schemaVersion=1}}
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan -ApprovedManifestSHA256 ('9'*64)}
    }
    It 'rejects a runtime with changed bytes' {
        Mock Get-ReleaseToolHash -ModuleName Release {('c'*64)}
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan}
    }
    It 'accepts a failed deploy only with a matching operator reconciliation receipt' {
        $global:ReleaseContextReceipt=@{planHash='prior';operationId='prior-deploy';verification=@{releaseId='old';status='RuntimeVerified'}}
        Mock Read-DeploymentJson -ModuleName Release {
            switch -Wildcard ($Path){
                '*installation.json' {@{identity='identity';root='C:\fixed';files=@(@{path='src\RoutineRelease.psm1';sha256=('b'*64)})}}
                '*active.json' {@{planHash='prior';releaseId='old'}}
                '*release.json' {@{planHash='prior';releaseId='old';sourceCommit=('a'*40);runtimePath='C:\fixed\node.exe';runtimeSHA256=('b'*64)}}
                '*verification.json' {@{planHash='prior';releaseId='old';status='RuntimeVerified';readiness=@{ready=$true};database=@{schemaFingerprint=('b'*64)}}}
                '*request.json' {$global:ReleaseContextPrior}
                '*result.json' {@{planHash='prior';status='Failed';operationId='prior-deploy'}}
                '*operator-reconciliation.json' {$global:ReleaseContextReceipt}
                default {throw 'Unexpected synthetic read'}
            }
        }
        (Get-RoutineReleaseContext $global:ReleaseContextPlan).runtimePath|Should Be 'C:\fixed\node.exe'
        $global:ReleaseContextReceipt.verification.releaseId='other'
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan}
        $global:ReleaseContextReceipt.verification.releaseId='old'
        Mock Test-Path -ModuleName Release {$LiteralPath -notlike '*operator-reconciliation.json'}
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan}
    }
    It 'scans an SSH host in one call each and keeps the same checks' {
        Mock Resolve-DeploymentSshPath -ModuleName Release {if($Path -eq 'C:\synthetic'){@{hostName='jimbrownhome1.local';path='C:\host'}}}
        Mock Get-DeploymentRemotePath -ModuleName Release {"C:\synthetic\operations\$(Split-Path -Leaf $Path)"}
        $global:ReleaseContextBadFiles=@()
        Mock Invoke-DeploymentSsh -ModuleName Release {
            if([string]$ArgumentList[0] -like '*operations'){@('C:\host\operations\prior-deploy')}else{$global:ReleaseContextBadFiles}
        }
        (Get-RoutineReleaseContext $global:ReleaseContextPlan).runtimePath|Should Be 'C:\fixed\node.exe'
        Assert-MockCalled Invoke-DeploymentSsh -ModuleName Release -Times 2 -Exactly -Scope It
        Assert-MockCalled Get-ChildItem -ModuleName Release -Times 0 -Scope It
        $global:ReleaseContextBadFiles=@('src\RoutineRelease.psm1')
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan}
        $global:ReleaseContextBadFiles=@()
        Mock Invoke-DeploymentSsh -ModuleName Release {if([string]$ArgumentList[0] -like '*operations'){@()}else{@()}}
        Assert-ReleaseThrows {Get-RoutineReleaseContext $global:ReleaseContextPlan}
    }
}
