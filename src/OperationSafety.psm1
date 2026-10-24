#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Lifecycle.psm1') -DisableNameChecking

function Write-OperationPhase {
    param([Parameter(Mandatory)][string]$OperationDirectory,[Parameter(Mandatory)][hashtable]$Request,
        [Parameter(Mandatory)][ValidateSet('Preflight','Maintenance','Switching','MayWrite','Verified')][string]$Phase)
    $path=Join-Path $OperationDirectory 'phase.json'
    $prior=if(Test-Path -LiteralPath $path){Read-DeploymentJson $path}else{$null}
    if($prior -and ($prior.operationId -ne $Request.operationId -or $prior.planHash -ne $Request.plan.planHash)){throw 'Operation phase belongs to another request.'}
    $mayWrite=$Phase -in @('MayWrite','Verified') -or ($prior -and $prior.targetMayHaveWritten -eq $true)
    Write-DeploymentJson $path @{operationId=$Request.operationId;planHash=$Request.plan.planHash;phase=$Phase
        requestSHA256=(Get-FileHash (Join-Path $OperationDirectory 'request.json')).Hash.ToLowerInvariant()
        targetMayHaveWritten=[bool]$mayWrite;updatedLocal=(Get-Date).ToString('o')}
}

function Assert-PreviousReleaseRunning {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][string]$AppRoot)
    $active=Read-DeploymentJson (Join-Path $AppRoot 'state\active.json')
    if(-not $Plan.currentRelease -or $active.planHash -ne $Plan.currentRelease.planHash -or $active.releaseId -ne $Plan.currentRelease.releaseId){
        throw 'Previous active release changed; recovery requires review.'
    }
    if(Test-Path -LiteralPath (Join-Path $AppRoot 'state\maintenance.json')){throw 'Maintenance remains active; automatic reconciliation refused.'}
    $path=Resolve-OwnedPath $AppRoot ('releases\'+$active.releaseId)
    $junction=Get-Item -LiteralPath (Join-Path $AppRoot 'current')
    if($junction.LinkType -ne 'Junction' -or [string]$junction.Target -ine $path){throw 'Previous release junction changed.'}
    $manifest=Read-LifecycleManifest -Path (Join-Path $path 'deploy\application.json') -AppRoot $AppRoot -ReleasePath $path
    $runtime=Get-ReleaseRuntimePath -AppRoot $AppRoot -ReleasePath $path -Manifest $manifest
    $identity=Test-ManagedAppIdentity -AppRoot $AppRoot -ReleasePath $path -Manifest $manifest -RuntimePath $runtime
    if(-not $identity.Verified -or -not $identity.ListenerOwned){throw 'Previous runtime identity is not verified.'}
    $ready=Test-AppReadiness -Port $manifest.launch.port -Path $manifest.readiness.path -Expected $manifest.readiness.expected -TimeoutSeconds 5
    if(-not $ready.Ready){throw 'Previous runtime readiness failed.'}
    $identity
}

function Assert-CleanOperationAbort {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][string]$OperationDirectory,
        [Parameter(Mandatory)][string]$AppRoot)
    $phase=Read-DeploymentJson (Join-Path $OperationDirectory 'phase.json')
    $requestPath=Join-Path $OperationDirectory 'request.json'
    $request=Read-DeploymentJson $requestPath
    if($phase.operationId -ne $request.operationId -or $phase.planHash -ne $Plan.planHash -or
        $request.plan.planHash -ne $Plan.planHash -or $phase.phase -ne 'Preflight' -or
        -not $phase.ContainsKey('targetMayHaveWritten') -or $phase.targetMayHaveWritten -ne $false -or
        $phase.requestSHA256 -ne (Get-FileHash $requestPath).Hash.ToLowerInvariant()){
        throw 'Operation has no conclusive pre-mutation abort evidence.'
    }
    $authorityPath=Join-Path $AppRoot 'state\authority.json'
    if(Test-Path -LiteralPath $authorityPath){
        $authority=Read-DeploymentJson $authorityPath
        if($authority.operationId -in @($Plan.id,$request.operationId) -and $authority.targetMayHaveWritten -eq $true){
            throw 'The failed operation may have written data; state-aware review is required.'
        }
    }
    Assert-PreviousReleaseRunning $Plan $AppRoot
}

Export-ModuleMember -Function Write-OperationPhase,Assert-PreviousReleaseRunning,Assert-CleanOperationAbort
