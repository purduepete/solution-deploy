#requires -Version 7.5
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$RequestSHA256,
    [Parameter(Mandatory)][ValidateSet('Prepare','Activate')][string]$Phase
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$appRoot='C:\ProgramData\SolutionDeploy\apps\fit-track'
$framework='C:\ProgramData\SolutionDeploy\control\framework'
Import-Module (Join-Path $framework 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $framework 'src\Lifecycle.psm1') -DisableNameChecking
$operation=Split-Path -Parent $RequestPath
$expectedRoot=Join-Path $appRoot 'state\routine'
if($operation -notmatch ('^'+[regex]::Escape($expectedRoot)+'\\[a-f0-9]{32}$') -or
    $RequestPath -ine (Join-Path $operation 'request.json')){throw 'Unexpected Fit Track request location.'}
$resultPath=Join-Path $operation ($Phase.ToLowerInvariant()+'-result.json')
$result=@{phase=$Phase;requestSHA256=$RequestSHA256;status='Running';startedLocal=(Get-Date).ToString('o')}
$lock=$null
function Wait-FitTrackRuntime {
    param([string]$AppRoot,[string]$Release,[hashtable]$Manifest,[string]$Runtime,[int]$TimeoutSeconds=90)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{
        Start-Sleep -Seconds 2
        $status=Get-ManagedAppStatus -AppRoot $AppRoot -ReleasePath $Release -Manifest $Manifest -RuntimePath $Runtime
        $ready=Test-AppReadiness -Port 8791 -Path $Manifest.readiness.path -Expected $Manifest.readiness.expected -TimeoutSeconds 5
    }while((-not $ready.Ready -or $status.Status -ne 'Running') -and $clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if(-not $ready.Ready -or $status.Status -ne 'Running'){throw 'Fit Track did not establish owned runtime readiness. Inspect the new release; no automatic rollback was attempted.'}
}
function Assert-RequestCurrent {
    if((Get-FileHash -LiteralPath $RequestPath).Hash.ToLowerInvariant() -ne $RequestSHA256){throw 'Fit Track request changed.'}
    if([DateTimeOffset]::Parse($request.expiresLocal) -le [DateTimeOffset]::Now){throw 'Fit Track release consent expired.'}
    if((Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant() -ne $request.runnerSHA256){throw 'Fit Track release runner changed.'}
    $identity=(Get-CimInstance Win32_ComputerSystemProduct).UUID
    if($env:COMPUTERNAME -ine 'jimbrownhome1' -or $identity -ne $request.hostIdentity){throw 'Fit Track destination identity changed.'}
    if($request.dataActionsReviewed -ne $true -or [string]::IsNullOrWhiteSpace($request.approvedBy) -or
        [string]::IsNullOrWhiteSpace($request.reason)){throw 'Fit Track release consent is missing.'}
}
function Assert-PreviousRelease {
    Assert-RequestCurrent
    $link=Get-Item -LiteralPath (Join-Path $appRoot 'current')
    if($link.LinkType -ne 'Junction' -or [string]$link.Target -ine $previous){throw 'Fit Track current destination changed.'}
    if((Get-FileHash -LiteralPath (Join-Path $appRoot 'state\active.json')).Hash.ToLowerInvariant() -ne $request.previousActiveSHA256){throw 'Fit Track active record changed.'}
    foreach($file in $request.baseline){
        $path=Resolve-OwnedPath $previous $file.path
        if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $file.sha256){throw "Fit Track installed file changed: $($file.path)."}
    }
    $actualFiles=@(foreach($relative in @('backend\app','deploy','frontend\dist')){
        Get-ChildItem -LiteralPath (Join-Path $previous $relative) -File -Recurse |
            Where-Object {$_.FullName -notmatch '\\__pycache__\\|\.pyc$'}
    })
    if(($actualFiles.Count+1) -ne $request.baseline.Count){throw 'Fit Track installed file set changed during preparation.'}
    foreach($file in $request.watcherFiles){
        $path=Resolve-OwnedPath (Join-Path $appRoot 'upload-watcher') $file.path
        if((Get-Sha256Text ([IO.File]::ReadAllText($path).Replace("`r`n","`n"))) -ne $file.sha256){throw 'Fit Track watcher source changed during preparation.'}
    }
    if((Get-Sha256Text (Export-ScheduledTask -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track-upload-watcher)) -ne $request.watcherTaskSHA256){
        throw 'Fit Track watcher task configuration changed during preparation.'
    }
    Assert-AppBootTask -AppId fit-track -AppRoot $appRoot -PowerShellPath 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe' `
        -ExpectedAccount "$env:COMPUTERNAME\sd-fittrack" -WatchdogScriptPath (Join-Path $framework 'scripts\Invoke-AppWatchdog.ps1')|Out-Null
}
try{
    if((Get-FileHash -LiteralPath $RequestPath).Hash.ToLowerInvariant() -ne $RequestSHA256){throw 'Fit Track request hash mismatch.'}
    $request=Read-DeploymentJson $RequestPath
    $plan=$request.plan
    if($plan.app -ne 'fit-track' -or $plan.id -ne (Split-Path -Leaf $operation) -or
        $plan.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or (Get-PlanDigest $plan) -ne $plan.planHash){throw 'Invalid Fit Track release plan.'}
    if($request.previousRelease -notmatch '^[a-zA-Z0-9-]+$'){throw 'Invalid previous release id.'}
    $previous=Resolve-OwnedPath $appRoot ('releases\'+$request.previousRelease)
    $release=Resolve-OwnedPath $appRoot ('releases\'+$plan.releaseId)
    Assert-PreviousRelease
    if((Get-AppMaintenance $appRoot).Active){throw 'Fit Track is already in maintenance.'}
    if((Get-FileHash -LiteralPath $request.runtimePath).Hash -ine $request.runtimeSHA256){throw 'Pinned build interpreter changed.'}
    if($Phase -eq 'Prepare'){
        $payload=Join-Path $operation 'payload.zip'
        if((Get-FileHash -LiteralPath $payload).Hash.ToLowerInvariant() -ne $request.payloadSHA256){throw 'Fit Track payload hash mismatch.'}
        $record=New-StagedRelease -Plan $plan -RepositoryRoot $operation -AppRoot $appRoot -RuntimePath $request.runtimePath `
            -SourceArchive $payload -SourceArchiveSHA256 $request.payloadSHA256 -BuildTimeoutSeconds $request.timeoutSeconds
        if(-not (Test-Path -LiteralPath (Join-Path $release 'frontend\dist\index.html'))){throw 'Fit Track frontend build is missing.'}
        $result.releaseId=$record.releaseId
    }else{
        $prepared=Read-DeploymentJson (Join-Path $operation 'prepare-result.json')
        if($prepared.status -ne 'Succeeded' -or $prepared.requestSHA256 -ne $RequestSHA256){throw 'No matching prepared Fit Track release.'}
        $lock=Get-DeploymentLock (Join-Path $appRoot 'state\deployment.lock')
        $record=Test-ReleaseInventory $release
        if($record.planHash -ne $plan.planHash -or $record.sourceCommit -ne $plan.sourceCommit){throw 'Prepared Fit Track artifact changed.'}
        Assert-PreviousRelease
        $oldManifest=Read-LifecycleManifest -Path (Join-Path $previous 'deploy\application.json') -AppRoot $appRoot -ReleasePath $previous
        $oldRuntime=Get-ReleaseRuntimePath -AppRoot $appRoot -ReleasePath $previous -Manifest $oldManifest
        Stop-ManagedApp -AppRoot $appRoot -ReleasePath $previous -Manifest $oldManifest -RuntimePath $oldRuntime -TimeoutSeconds 60|Out-Null
        Assert-PreviousRelease
        Set-ActiveRelease -AppRoot $appRoot -ReleaseId $plan.releaseId -OperationId $plan.id -HostName jimbrownhome1 -PlanHash $plan.planHash
        Assert-RequestCurrent
        Clear-AppMaintenance -AppRoot $appRoot -Confirm:$false
        Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track
        $manifest=Read-LifecycleManifest -Path (Join-Path $release 'deploy\application.json') -AppRoot $appRoot -ReleasePath $release
        $runtime=Get-ReleaseRuntimePath -AppRoot $appRoot -ReleasePath $release -Manifest $manifest
        Wait-FitTrackRuntime -AppRoot $appRoot -Release $release -Manifest $manifest -Runtime $runtime
        Write-DeploymentJson (Join-Path $appRoot 'state\common-release.json') @{
            releaseId=$plan.releaseId;sourceCommit=$plan.sourceCommit;component='web';verifiedLocal=(Get-Date).ToString('o')
            sourceArchiveSHA256=$request.sourceArchiveSHA256;payloadSHA256=$request.payloadSHA256
        }
        $result.releaseId=$plan.releaseId
        $result.runtime='Verified'
    }
    $result.status='Succeeded';$result.completedLocal=(Get-Date).ToString('o')
}catch{
    $result.status='Failed';$result.error=$_.Exception.Message
    Write-Error -Message $result.error -ErrorAction Continue
}finally{
    if($lock){$lock.Dispose()}
    Write-DeploymentJson $resultPath $result
}
if($result.status -ne 'Succeeded'){exit 1}
