#requires -Version 7.4
#requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Transfer.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Lifecycle.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Operations.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\RoutineRelease.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\OperationSafety.psm1') -DisableNameChecking
$lock = Get-DeploymentLock (Join-Path $Root 'control\execution.lock')
$request = $null; $resultPath=$null
try {
    $install = Read-DeploymentJson (Join-Path $Root 'control\installation.json')
    if ($Root -ne $install.root -or $env:COMPUTERNAME -ine $install.host -or
        (Get-CimInstance Win32_ComputerSystemProduct -Property UUID).UUID -ne $install.identity) { throw 'Protected executor identity mismatch.' }
    foreach ($file in $install.files) {
        $path = Resolve-OwnedPath (Join-Path $Root 'control\framework') $file.path
        if ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'Installed executor code changed.' }
    }
    $pending = Read-DeploymentJson (Join-Path $Root 'control\pending.json')
    Assert-Identifier $pending.operationId
    $operation = Resolve-OwnedPath $Root ('operations\'+$pending.operationId)
    $requestPath = Join-Path $operation 'request.json'
    if ((Get-FileHash -LiteralPath $requestPath).Hash.ToLowerInvariant() -ne $pending.requestSHA256) { throw 'Protected request hash mismatch.' }
    $request = Read-DeploymentJson $requestPath
    $resultPath = Join-Path $operation 'result.json'
    if ($request.operationId -ne $pending.operationId) { throw 'Operation identity mismatch.' }
    if (Test-Path -LiteralPath $resultPath) { throw 'Operation already has a result; do not repeat side effects.' }
    $plan = $request.plan
    if($plan.schemaVersion -ne 2){throw 'Executor requires a current host-aware plan.'}
    if ($plan.target.host -ine $env:COMPUTERNAME -or $plan.hostSnapshot.identity -ne $install.identity -or $plan.target.root -ne $Root) { throw 'Operation targets a different host/root.' }
    $approvalPath = Join-Path $operation 'approval.json'
    Write-DeploymentJson $approvalPath $request.approval
    $approval = Assert-DeploymentApproval $plan $approvalPath $request.action
    if ($request.action -notin @('Stage','Preflight','Recover','PrepareCutover','Deploy','Cutover','Rollback','Verify')) { throw 'Unsupported protected action.' }
    $appRoot = Resolve-OwnedPath $Root ('apps\'+$plan.app)
    if ($request.action -eq 'Stage') {
        if ($approval.sourceArchiveSHA256 -ne $request.sourceArchiveSHA256) { throw 'Archive digest is not approved.' }
        if (-not $approval.ContainsKey('runtimeSHA256') -or (Get-FileHash -LiteralPath $request.runtimePath).Hash.ToLowerInvariant() -ne $approval.runtimeSHA256) { throw 'Runtime executable differs from approved bytes.' }
        if($plan.ContainsKey('routineRelease') -and $plan.routineRelease -eq $true){
            if($request.runtimePath -ine $plan.routineConsent.runtimePath -or $request.npmPath -ine $plan.routineConsent.npmPath){
                throw 'Stage tools differ from the exact routine consent.'
            }
            if($request.npmPath){
                $cli=Join-Path (Split-Path -Parent $request.runtimePath) 'node_modules\npm\bin\npm-cli.js'
                if((Get-FileHash -LiteralPath $request.npmPath).Hash.ToLowerInvariant() -ne $approval.npmSHA256 -or
                    (Get-FileHash -LiteralPath $cli).Hash.ToLowerInvariant() -ne $approval.npmCliSHA256){
                    throw 'npm differs from approved routine release bytes.'
                }
            }
        }
        $versionOutput = Invoke-DeploymentCommand $request.runtimePath @('--version') $Root -Capture
        if ($versionOutput -notmatch '(\d+\.\d+\.\d+)') { throw 'Runtime version could not be determined.' }
        if ([version]$Matches[1] -lt [version]$plan.manifest.runtime.minimumVersion) { throw 'Runtime does not meet the manifest minimum version.' }
        foreach ($relative in @('shared\data','shared\secrets','shared\logs','shared\backups','shared\run','state')) {
            [IO.Directory]::CreateDirectory((Resolve-OwnedPath $appRoot $relative)) | Out-Null
        }
        if(-not (Test-Path -LiteralPath (Join-Path $appRoot 'state\active.json'))){
            Write-DeploymentJson (Join-Path $appRoot 'state\maintenance.json') @{operationId=$plan.id;reason='Staged; activation requires separate approval.'}
        }
        $release = New-StagedRelease -Plan $plan -RepositoryRoot $operation -AppRoot $appRoot -RuntimePath $request.runtimePath -NpmPath $request.npmPath `
            -SourceArchive (Join-Path $operation 'source.zip') -SourceArchiveSHA256 $request.sourceArchiveSHA256
        Write-DeploymentJson $resultPath @{operationId=$request.operationId;planHash=$plan.planHash;status='Succeeded';releaseId=$release.releaseId;completedLocal=(Get-Date).ToString('o')} -CreateNew
        return
    }
    $appLock = Get-DeploymentLock (Join-Path $appRoot 'state\deployment.lock')
    try {
        if($request.action -eq 'Recover'){
            $failedDirectory=Join-Path $Root ('operations\'+$plan.id+'-deploy')
            $failed=Read-DeploymentJson (Join-Path $failedDirectory 'result.json')
            if($failed.status -ne 'Failed' -or $failed.planHash -ne $plan.planHash){throw 'Recovery requires the exact completed failed deployment.'}
            $identity=Assert-CleanOperationAbort $plan $failedDirectory $appRoot
            $path=Resolve-OwnedPath $appRoot ('releases\'+$plan.releaseId)
            $database=Assert-DatabaseActivationEvidence $plan $approval $appRoot -ReleasePath $path
            Write-DeploymentJson $resultPath @{operationId=$request.operationId;planHash=$plan.planHash;status='Succeeded'
                phase='RecoveredPrevious';verification=@{releaseId=$plan.currentRelease.releaseId;identity=$identity;database=$database}
                completedLocal=(Get-Date).ToString('o')} -CreateNew
            return
        }
        Write-OperationPhase $operation $request Preflight
        if($request.action -eq 'Preflight'){
            $path=Resolve-OwnedPath $appRoot ('releases\'+$plan.releaseId)
            $verification=Get-RoutineDatabaseEvidence $plan $approval $appRoot $path -Create
            Write-DeploymentJson $resultPath @{operationId=$request.operationId;planHash=$plan.planHash;status='Succeeded'
                phase='PreflightVerified';verification=$verification;completedLocal=(Get-Date).ToString('o')} -CreateNew
            return
        }
        $activePath = Join-Path $appRoot 'state\active.json'
        $active = if(Test-Path -LiteralPath $activePath){Read-DeploymentJson $activePath}else{$null}
        $consumesTransfer=$request.action -eq 'PrepareCutover' -or ($request.action -eq 'Cutover' -and -not $approval.ContainsKey('preparedStateSHA256'))
        if($consumesTransfer -and ($request.ContainsKey('transferArchiveSHA256') -or $approval.ContainsKey('transferArchiveSHA256'))){
            if($request['transferArchiveSHA256'] -cnotmatch '^[a-f0-9]{64}$' -or $request['transferArchiveSHA256'] -ne $approval['transferArchiveSHA256'] -or
                $request.transferSHA256 -ne $approval.transferSHA256){throw 'Transfer archive is not bound to the approved archive and transfer hashes.'}
            Expand-TransferArchive (Join-Path $operation 'transfer.zip') (Join-Path $operation 'transfer') $approval.transferSHA256 $approval.transferArchiveSHA256 | Out-Null
        }
        if($request.action -eq 'PrepareCutover'){
            if($active){throw 'Initial preparation cannot replace an active target.'}
            $proof=Read-DeploymentJson (Join-Path $operation 'transfer\transfer.json')
            $verified=$request.sourceFenceVerification
            $age=[DateTimeOffset]::Now-[DateTimeOffset]::Parse($verified.verifiedLocal)
            if($verified.kind -ne 'FrozenTransferContinuity' -or $verified.sourceContentVerified -ne $true -or
                $verified.planHash -ne $plan.planHash -or $verified.transferSHA256 -ne $approval.transferSHA256 -or
                $verified.verified -ne $true -or $verified.operationId -ne $plan.id -or $verified.sourceHost -ine $plan.observedHost -or
                $verified.fenceHash -ne $approval.sourceFenceSHA256 -or
                $verified.fenceHash -ne (Get-Sha256Text (ConvertTo-CanonicalJson $proof.fence)) -or
                $age -gt [TimeSpan]::FromMinutes(5) -or $age -lt [TimeSpan]::Zero){throw 'Preparation source verification is missing or stale.'}
            if($request.transferSHA256 -ne $approval.transferSHA256){throw 'Preparation transfer differs from approval.'}
            $preparation=Prepare-InitialCutover $plan $appRoot (Join-Path $operation 'transfer') $approval.transferSHA256
            Write-DeploymentJson $resultPath @{operationId=$request.operationId;planHash=$plan.planHash;status='Succeeded';phase='Prepared';verification=$preparation;completedLocal=(Get-Date).ToString('o')} -CreateNew
            return
        }
        if($request.action -eq 'Verify'){
            $verification=Test-ReviewedAppRuntime -Plan $plan -Approval $approval -AppRoot $appRoot
            Write-DeploymentJson $resultPath @{operationId=$request.operationId;planHash=$plan.planHash;status='Succeeded';phase='RuntimeVerified';externalAcceptance='Pending';verification=$verification;completedLocal=(Get-Date).ToString('o')} -CreateNew
            return
        }
        if ($plan.currentRelease) {
            if (-not $active -or $active.releaseId -ne $plan.currentRelease.releaseId -or $active.planHash -ne $plan.currentRelease.planHash) { throw 'Active deployment changed since approval.' }
        } elseif ($active) { throw 'An active deployment appeared after planning.' }
        if ($request.action -eq 'Cutover' -and $plan.operation -ne 'Cutover') { throw 'Same-host deployments cannot use cross-host Cutover.' }
        if ($request.action -eq 'Deploy' -and $plan.operation -ne 'Deploy') { throw 'Cross-host movement requires Cutover.' }
        $releaseId = $plan.releaseId
        if ($request.action -eq 'Rollback') {
            if (-not $active -or -not $approval.ContainsKey('rollbackReleaseId') -or $approval.rollbackReleaseId -ne $active.previousRelease) { throw 'Only an explicitly reviewed retained previous release is eligible for code rollback.' }
            if (-not $approval.gates.ContainsKey('schemaCompatible') -or -not $approval.gates.schemaCompatible) { throw 'Code rollback requires current-state schema compatibility evidence.' }
            $releaseId = $approval.rollbackReleaseId
        }
        $releasePath = Resolve-OwnedPath $appRoot ('releases\'+$releaseId)
        $release = Test-ReleaseInventory $releasePath
        if ($release.manifestHash -ne $plan.manifestHash -and $request.action -ne 'Rollback') { throw 'Release does not match the approved manifest.' }
        if ((Get-FileHash -LiteralPath $release.runtimePath).Hash.ToLowerInvariant() -ne $release.runtimeSHA256) { throw 'Pinned runtime changed since staging.' }
        if($request.action -eq 'Deploy'){
            Assert-DatabaseActivationEvidence $plan $approval $appRoot -ReleasePath $releasePath | Out-Null
            $account=$env:COMPUTERNAME+'\'+$plan.target.apps[$plan.app].account
            Assert-AppBootTask -AppId $plan.app -AppRoot $appRoot -PowerShellPath $install.powerShellPath -ExpectedAccount $account | Out-Null
        }
        Write-OperationPhase $operation $request Maintenance
        Write-DeploymentJson (Join-Path $appRoot 'state\maintenance.json') @{operationId=$plan.id;reason=$request.action}
        if ($active) {
            $oldPath = Resolve-OwnedPath $appRoot ('releases\'+$active.releaseId)
            $oldRelease = Test-ReleaseInventory $oldPath
            $oldManifest = Get-Manifest (Join-Path $oldPath 'deploy\application.json')
            $oldRuntime=Get-ReleaseRuntimePath -AppRoot $appRoot -ReleasePath $oldPath -Manifest $oldManifest
            Stop-ManagedApp -AppRoot $appRoot -ReleasePath $oldPath -Manifest $oldManifest -RuntimePath $oldRuntime -TimeoutSeconds 60
        }
        if ($request.action -eq 'Cutover') {
            if($approval.ContainsKey('preparedStateSHA256')){
                $prepared=Assert-PreparedState $plan $appRoot $approval.preparedStateSHA256
                Assert-SourceContinuity $plan $approval $request.sourceFenceVerification $prepared
                $junction=Get-Item -LiteralPath (Join-Path $appRoot 'current')
                if($junction.LinkType -ne 'Junction' -or [string]$junction.Target -ne $releasePath){throw 'Prepared current release changed.'}
            } else {
            if(Test-Path -LiteralPath (Join-Path $appRoot 'state\prepared-cutover.json')){throw 'Prepared state requires an explicitly bound final cutover approval.'}
            if (-not $approval.ContainsKey('sourceFenceSHA256')) { throw 'Cutover requires approved source fence evidence.' }
            $proof = Read-DeploymentJson (Join-Path $operation 'transfer\transfer.json')
            $fence = $proof.fence
            if ((Get-Sha256Text (ConvertTo-CanonicalJson $fence)) -ne $approval.sourceFenceSHA256) { throw 'Source fence differs from approval.' }
            $verified=$request.sourceFenceVerification
            if($verified.verified -ne $true -or $verified.operationId -ne $plan.id -or $verified.sourceHost -ine $plan.observedHost -or
                $verified.fenceHash -ne (Get-Sha256Text (ConvertTo-CanonicalJson $fence)) -or
                [DateTimeOffset]::Now-[DateTimeOffset]::Parse($verified.verifiedLocal) -gt [TimeSpan]::FromMinutes(5) -or
                [DateTimeOffset]::Now-[DateTimeOffset]::Parse($verified.verifiedLocal) -lt [TimeSpan]::Zero){
                throw 'Protected controller source verification is missing or stale. SYSTEM does not impersonate the controller for remote source access.'
            }
            if($plan.transitionKind -eq 'ManagedMove'){
                Prepare-ManagedStateImport $plan $appRoot
            }
            Import-FrozenState $plan (Join-Path $operation 'transfer') $appRoot $request.transferSHA256 | Out-Null
            }
        }
        $manifest = Get-Manifest (Join-Path $releasePath 'deploy\application.json')
        if($manifest.database.name -ne $plan.manifest.database.name -or $manifest.database.schemaVersion -ne $plan.manifest.database.schemaVersion){throw 'Selected code is incompatible with the reviewed PostgreSQL database/schema version.'}
        $identity=Test-ManagedAppIdentity -AppRoot $appRoot -ReleasePath $releasePath -Manifest $manifest -RuntimePath (Get-ReleaseRuntimePath -AppRoot $appRoot -ReleasePath $releasePath -Manifest $manifest)
        if($identity.Status -eq 'NotRunning'){
            $stale=Join-Path $appRoot 'shared\run\process.json'
            if(Test-Path -LiteralPath $stale){[IO.File]::Delete($stale)}
        }else{throw 'A live or untrusted runtime still owns the selected app. Release switch refused.'}
        Assert-DatabaseActivationEvidence $plan $approval $appRoot -ReleasePath $releasePath | Out-Null
        if($request.action -eq 'Cutover' -and $approval.ContainsKey('preparedStateSHA256')){
            Assert-SourceContinuity $plan $approval $request.sourceFenceVerification $prepared
        }
        Assert-DeploymentApproval $plan $approvalPath $request.action | Out-Null
        Write-OperationPhase $operation $request Switching
        Set-ActiveRelease -AppRoot $appRoot -ReleaseId $releaseId -OperationId $request.operationId -HostName $env:COMPUTERNAME -PlanHash $plan.planHash
        Write-OperationPhase $operation $request MayWrite
        $verification=Start-ReviewedAppTask -Plan $plan -Approval $approval -AppRoot $appRoot -PowerShellPath $install.powerShellPath -ReleaseId $releaseId
        Write-OperationPhase $operation $request Verified
        Write-DeploymentJson $resultPath @{operationId=$request.operationId;planHash=$plan.planHash;status='Succeeded';phase='RuntimeVerified';externalAcceptance='Pending';verification=$verification;completedLocal=(Get-Date).ToString('o')} -CreateNew
    } finally { $appLock.Dispose() }
} catch {
    if ($request -and $resultPath -and -not (Test-Path -LiteralPath $resultPath)) {
        $failure=$_.Exception.Message
        $cleanAbort=$false
        if($request.ContainsKey('action') -and $request.action -eq 'Deploy'){
            $failureLock=$null
            try {
                $failureLock=Get-DeploymentLock (Join-Path $Root ('apps\'+$request.plan.app+'\state\deployment.lock'))
                Assert-CleanOperationAbort $request.plan (Split-Path -Parent $resultPath) (Join-Path $Root ('apps\'+$request.plan.app)) | Out-Null
                $cleanAbort=$true
            }catch{Write-Warning 'Failure cannot be classified as a verified pre-mutation abort; placement remains unresolved.'}
            finally{if($failureLock){$failureLock.Dispose()}}
        }
        Write-DeploymentJson $resultPath @{operationId=$request.operationId;planHash=$request.plan.planHash;status='Failed'
            cleanAbort=$cleanAbort;error=$failure;completedLocal=(Get-Date).ToString('o')} -CreateNew
    }
    throw
} finally { $lock.Dispose() }
