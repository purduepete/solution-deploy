$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\RoutineRelease.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking
function Assert-RoutineThrows([scriptblock]$Action){
    $thrown=$false
    try{& $Action | Out-Null}catch{$thrown=$true}
    $thrown | Should Be $true
}

Describe 'Routine release consent is exact and bounded' {
    BeforeEach {
        $script:plan=@{routineRelease=$true;app='test-app';environment='production';sourceCommit=('a'*40)
            target=@{host='target'};currentRelease=@{releaseId='old-release'};transitionKind='ManagedDeploy';operation='Deploy'
            routineConsent=@{app='test-app';environment='production';target='target';sourceCommit=('a'*40)
                approvedBy='operator';reason='commit push deploy';expiresLocal=[DateTimeOffset]::Now.AddMinutes(15).ToString('o')
                actions=@('Stage','Preflight','Deploy','Verify');dataActionsReviewed=$true}}
    }
    It 'accepts the exact routine release action scope' {
        Assert-RoutineReleaseConsent $script:plan Deploy
    }
    It 'rejects missing data-change code review' {
        $script:plan.routineConsent.dataActionsReviewed=$false
        Assert-RoutineThrows {Assert-RoutineReleaseConsent $script:plan Deploy}
    }
    It 'rejects expired consent' {
        $script:plan.routineConsent.expiresLocal=[DateTimeOffset]::Now.AddMinutes(-1).ToString('o')
        Assert-RoutineThrows {Assert-RoutineReleaseConsent $script:plan Deploy}
    }
    It 'rejects different commit host and action' {
        $script:plan.sourceCommit=('b'*40)
        Assert-RoutineThrows {Assert-RoutineReleaseConsent $script:plan Deploy}
        $script:plan.sourceCommit=('a'*40);$script:plan.target.host='other'
        Assert-RoutineThrows {Assert-RoutineReleaseConsent $script:plan Deploy}
        $script:plan.target.host='target'
        Assert-RoutineThrows {Assert-RoutineReleaseConsent $script:plan Cutover}
    }
    It 'rejects first installations and host moves' {
        foreach($kind in @('FirstInstall','ManagedMove','LegacyConversion')){
            $script:plan.transitionKind=$kind
            Assert-RoutineThrows {Assert-RoutineReleaseConsent $script:plan Deploy}
        }
    }
}

Describe 'Routine manifest changes need an exact build-only approval' {
    BeforeEach {
        $script:old=@{id='app';build=@{commands=@(@{tool='npm';arguments=@('ci')})};launch=@{port=1}}
        $script:next=@{id='app';build=@{commands=@(@{tool='npm';arguments=@('ci')},@{tool='npm';arguments=@('prune','--omit=dev')})};launch=@{port=1}}
        $script:plan=@{manifest=$script:next;manifestHash=('a'*64);routineConsent=@{approvedManifestSHA256=('a'*64)}}
    }
    It 'accepts an unchanged manifest without approval' {
        Assert-RoutineManifest @{manifest=$script:old;manifestHash=('a'*64);routineConsent=@{}} $script:old $script:old
    }
    It 'accepts a build-only change whose exact hash was approved' {
        Assert-RoutineManifest $script:plan $script:old $script:next
    }
    It 'rejects a change without approval or with another hash' {
        $script:plan.routineConsent=@{}
        Assert-RoutineThrows {Assert-RoutineManifest $script:plan $script:old $script:next}
        $script:plan.routineConsent=@{approvedManifestSHA256=('b'*64)}
        Assert-RoutineThrows {Assert-RoutineManifest $script:plan $script:old $script:next}
    }
    It 'rejects an approved change outside build commands' {
        $script:next.launch=@{port=2}
        Assert-RoutineThrows {Assert-RoutineManifest $script:plan $script:old $script:next}
    }
    It 'rejects a release manifest that differs from the plan' {
        Assert-RoutineThrows {Assert-RoutineManifest $script:plan $script:old $script:old}
    }
    It 'rejects migrations kept under node_modules or behind a path alias even when the manifest is unchanged' {
        foreach($dir in @('node_modules\app-db\migrations','Node_Modules/x','node_modules.\x','node_modules \x','node_modules::$INDEX_ALLOCATION\x','NODE_M~1\x','x\..\node_modules\x','')){
            $m=@{id='app';database=@{migrationsDirectory=$dir}}
            Assert-RoutineThrows {Assert-RoutineManifest @{manifest=$m;manifestHash=('a'*64)} $m $m}
        }
        $m=@{id='app';database=@{migrationsDirectory='deploy\postgresql'}}
        Assert-RoutineManifest @{manifest=$m;manifestHash=('a'*64)} $m $m
    }
}

Describe 'Routine migration classification uses sealed file hashes' {
    It 'detects a changed migration or added SQL file' {
        $old=@{files=@(@{path='deploy\postgresql\001.sql';sha256=('a'*64)},@{path='src\App.tsx';sha256=('b'*64)})}
        $next=@{files=@(@{path='deploy\postgresql\001.sql';sha256=('c'*64)},@{path='src\App.tsx';sha256=('b'*64)})}
        (Get-RoutineMigrationDigest $old) | Should Not Be (Get-RoutineMigrationDigest $next)
        $next.files=@($old.files)+@(@{path='server\repair.sql';sha256=('d'*64)})
        (Get-RoutineMigrationDigest $old) | Should Not Be (Get-RoutineMigrationDigest $next)
    }
    It 'ignores dependency package files that only look like schema or migration files' {
        $old=@{files=@(@{path='deploy\postgresql\001.sql';sha256=('a'*64)},@{path='node_modules\js-yaml\lib\schema.js';sha256=('b'*64)},
            @{path='server\node_modules\pkg\migrations\x.sql';sha256=('c'*64)})}
        $next=@{files=@(@{path='deploy\postgresql\001.sql';sha256=('a'*64)})}
        (Get-RoutineMigrationDigest $old) | Should Be (Get-RoutineMigrationDigest $next)
    }
}

Describe 'Routine approvals bind the reviewed release inputs' {
        BeforeEach {
            $script:consent=@{app='test-app';environment='production';target='target';sourceCommit=('a'*40)
                approvedBy='operator';reason='commit push deploy';expiresLocal=[DateTimeOffset]::Now.AddMinutes(15).ToString('o')
                actions=@('Stage','Preflight','Deploy','Verify');dataActionsReviewed=$true
                sourceArchiveSHA256=('a'*64);runtimeSHA256=('b'*64);npmSHA256=('c'*64);npmCliSHA256=('d'*64)
                approvalInputsSHA256=Get-Sha256Text (ConvertTo-CanonicalJson @{psqlPath='C:\postgres\psql.exe'})}
            $script:boundPlan=@{routineRelease=$true;app='test-app';environment='production';sourceCommit=('a'*40)
                target=@{host='target'};hostSnapshot=@{identity='machine';verified=$true};currentRelease=@{releaseId='old'}
                operation='Deploy';transitionKind='ManagedDeploy';routineConsent=$script:consent}
            $script:boundPlan.planHash=Get-PlanDigest $script:boundPlan
            $script:boundApproval=@{approvedBy='operator';expiresLocal=$script:consent.expiresLocal;actions=@('Stage')
                consentSHA256=Get-Sha256Text (ConvertTo-CanonicalJson $script:consent)
                planHash=$script:boundPlan.planHash;hostIdentity='machine';psqlPath='C:\postgres\psql.exe'
                gates=@{sourceCommitted=$true;artifactTrust=$true;hostProvisioning=$true;runtimeIdentity=$true;routePreconditions=$true}}
            foreach($field in @('sourceArchiveSHA256','runtimeSHA256','npmSHA256','npmCliSHA256')){$script:boundApproval[$field]=$script:consent[$field]}
            $script:boundPath=Join-Path $TestDrive 'bound-approval.json'
            Write-DeploymentJson $script:boundPath $script:boundApproval
        }
        It 'accepts the exact approval without adding database review or restore claims' {
            (Assert-DeploymentApproval $script:boundPlan $script:boundPath Stage).approvedBy | Should Be operator
        }
        It 'rejects a substituted verifier or source archive after consent' {
            $script:boundApproval.psqlPath='C:\changed\psql.exe'
            Write-DeploymentJson $script:boundPath $script:boundApproval
            Assert-RoutineThrows {Assert-DeploymentApproval $script:boundPlan $script:boundPath Stage}
            $script:boundApproval.psqlPath='C:\postgres\psql.exe'
            $script:boundApproval.sourceArchiveSHA256=('f'*64)
            Write-DeploymentJson $script:boundPath $script:boundApproval
            Assert-RoutineThrows {Assert-DeploymentApproval $script:boundPlan $script:boundPath Stage}
        }
        It 'rejects a substituted consent digest' {
            $script:boundApproval.consentSHA256=('f'*64)
            Write-DeploymentJson $script:boundPath $script:boundApproval
            Assert-RoutineThrows {Assert-DeploymentApproval $script:boundPlan $script:boundPath Stage}
        }
    }
Describe 'Routine migration non-schema behavior' {
    It 'allows only unrelated code hash changes without changing the migration digest' {
        $old=@{files=@(@{path='deploy\postgresql\001.sql';sha256=('a'*64)},@{path='src\App.tsx';sha256=('b'*64)})}
        $next=@{files=@(@{path='deploy\postgresql\001.sql';sha256=('a'*64)},@{path='src\App.tsx';sha256=('c'*64)})}
        (Get-RoutineMigrationDigest $old) | Should Be (Get-RoutineMigrationDigest $next)
    }
    It 'refuses a missing migration baseline' {
        Assert-RoutineThrows {Get-RoutineMigrationDigest @{files=@(@{path='src\App.tsx';sha256=('a'*64)})}}
    }
}
