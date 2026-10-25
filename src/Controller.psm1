#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Placement.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Transfer.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'OperationSafety.psm1') -DisableNameChecking

function Get-AdminSharePath {
    param([Parameter(Mandatory)][hashtable]$Target,[string]$RelativePath='')
    $base = '\\' + $Target.host + '\' + $Target.root.Substring(0,1) + '$' + $Target.root.Substring(2)
    if ($RelativePath) { Join-Path $base $RelativePath } else { $base }
}

function Get-RemoteDeploymentStatus {
    param([Parameter(Mandatory)][hashtable]$Plan,[switch]$Verify)
    $observed = Get-HostSnapshot $Plan.target
    if ($observed.identity -ne $Plan.hostSnapshot.identity) { throw 'Destination identity drifted; prepare a new plan.' }
    $root = Get-AdminSharePath $Plan.target
    $activePath = Join-Path $root ("apps\"+$Plan.app+'\state\active.json')
    $active = if (Test-Path -LiteralPath $activePath) { Read-DeploymentJson $activePath } else { $null }
    if ($Verify) {
        if (-not $active -or $active.host -ine $Plan.target.host) { throw 'Selected target does not have a verified active deployment.' }
        throw 'Remote Verify requires protected executor readiness evidence and external Access/browser checks. Status alone is not verification.'
    }
    @{app=$Plan.app;configuredTarget=$Plan.target.host;observedPlacement=$Plan.observedHost;active=$active;host=$observed;verified=$false}
}

function Wait-ForDeploymentExecutor {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$RemoteRoot,
        [ValidateRange(1,86400)][int]$TimeoutSeconds,
        [ValidateRange(0.1,60)][double]$PollIntervalSeconds
    )
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $idlePendingSeen=$false
    while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds){
        $task=Get-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-Executor' -ErrorAction Stop
        if(-not $task){throw 'Fixed protected executor task is missing.'}
        $taskState=[string]$task.State
        $processes=@(Get-CimInstance -CimSession $Session -ClassName Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -Property ProcessId,CommandLine |
            Where-Object {$_.CommandLine -match '(?i)Invoke-HostExecutor\.ps1'})
        $pendingPath=Join-Path $RemoteRoot 'control\pending.json'
        $pendingExists=Test-Path -LiteralPath $pendingPath -PathType Leaf
        $pending=$null
        $terminalResult=$false
        if($pendingExists){
            $pending=Read-DeploymentJson $pendingPath
            if($pending.operationId -notmatch '^[a-z0-9][a-z0-9-]{1,79}$' -or
                $pending.requestSHA256 -notmatch '^[a-f0-9]{64}$'){
                throw 'Protected executor pending record is malformed. Inspect it before submitting another operation.'
            }
            $operation=Resolve-OwnedPath $RemoteRoot ('operations\'+$pending.operationId)
            $requestPath=Join-Path $operation 'request.json'
            if(-not (Test-Path -LiteralPath $requestPath -PathType Leaf)){
                throw 'Pending operation has no request file. Inspect it before submitting another operation.'
            }
            if((Get-FileHash -LiteralPath $requestPath).Hash.ToLowerInvariant() -ne $pending.requestSHA256){
                throw 'Pending operation request hash differs from its record. Inspect it before submitting another operation.'
            }
            $request=Read-DeploymentJson $requestPath
            if($request.operationId -ne $pending.operationId){
                throw 'Pending operation identity differs from its request. Inspect it before submitting another operation.'
            }
            $resultPath=Join-Path $operation 'result.json'
            if(Test-Path -LiteralPath $resultPath -PathType Leaf){
                $result=Read-DeploymentJson $resultPath
                if($result.operationId -ne $pending.operationId -or $result.planHash -ne $request.plan.planHash -or
                    $result.status -notin @('Succeeded','Failed')){
                    throw 'Pending operation has a mismatched or non-terminal result. Inspect it before submitting another operation.'
                }
                $terminalResult=$true
            }
        }
        $busy=$taskState -ne 'Ready' -or $processes.Count -gt 0
        if($terminalResult -and -not $busy){return}
        if(-not $pendingExists -and -not $busy){return}
        if($pendingExists -and -not $terminalResult -and -not $busy){
            if($idlePendingSeen){
                throw "Pending operation $($pending.operationId) has no result and the executor is idle. Inspect it before submitting another operation."
            }
            $idlePendingSeen=$true
            Write-Host ("Executor is idle with unresolved operation {0}; checking once more before treating it as stale." -f $pending.operationId)
        }else{
            $idlePendingSeen=$false
            Write-Host ("Waiting for protected executor operation {0}; elapsed {1:n0}s" -f $(if($pending){$pending.operationId}else{'(task startup)'}),$clock.Elapsed.TotalSeconds)
        }
        Start-Sleep -Milliseconds ([int]($PollIntervalSeconds*1000))
    }
    if($pendingExists -and -not $terminalResult){
        throw "Timed out after $TimeoutSeconds seconds waiting for the previous executor operation to finish. No new request was submitted; inspect operation $($pending.operationId)."
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for the protected executor to become idle. No new request was submitted."
}

function Copy-ApprovedTransferArchive {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ApprovedArchiveSHA256)
    $hasher=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $reader=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $output=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{
            $buffer=[byte[]]::new(4MB);$copied=0L
            $clock=[Diagnostics.Stopwatch]::StartNew();$next=5
            while(($read=$reader.Read($buffer,0,$buffer.Length)) -gt 0){
                $hasher.AppendData($buffer,0,$read);$output.Write($buffer,0,$read);$copied+=$read
                if($clock.Elapsed.TotalSeconds -ge $next){
                    Write-Host ("Copying transfer archive {0:n0}/{1:n0} MB; elapsed {2:n0}s" -f ($copied/1MB),($reader.Length/1MB),$clock.Elapsed.TotalSeconds)
                    $next=$clock.Elapsed.TotalSeconds+5
                }
            }
            $output.Flush($true)
        }finally{$output.Dispose()}
    }finally{$reader.Dispose()}
    try{if([Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant() -ne $ApprovedArchiveSHA256){throw 'Transfer archive changed while copying.'}}
    finally{$hasher.Dispose()}
}

function Submit-DeploymentOperation {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][string]$ApprovalPath,
        [Parameter(Mandatory)][ValidateSet('Stage','Preflight','Recover','PrepareCutover','Deploy','Cutover','Rollback','Verify')][string]$Action,
        [string]$RuntimePath,[string]$NpmPath,[string]$TransferDirectory,[string]$TransferArchivePath,
        [ValidateRange(1,86400)][int]$TimeoutSeconds=300,[ValidateRange(1,86400)][int]$SubmissionWaitTimeoutSeconds=1800,
        [ValidateRange(0.1,60)][double]$PollIntervalSeconds=5)
    if(-not $Plan.ContainsKey('schemaVersion') -or $Plan.schemaVersion -ne 2){throw 'Submission requires a current host-aware plan.'}
    $approval = Assert-DeploymentApproval $Plan $ApprovalPath $Action
    if($TransferArchivePath){
        if($Action -notin @('PrepareCutover','Cutover') -or ($Action -eq 'Cutover' -and $approval.ContainsKey('preparedStateSHA256'))){
            throw '-TransferArchivePath applies only to PrepareCutover or an unprepared Cutover.'
        }
        if($TransferDirectory){throw 'Choose either -TransferDirectory or -TransferArchivePath, not both.'}
        if(-not $approval.ContainsKey('transferArchiveSHA256')){throw 'Archive transport requires approval to bind transferArchiveSHA256.'}
    }
    $databaseHost=@{}+$Plan.target
    foreach($field in @('host','address','root')){$databaseHost[$field]=$Plan.databaseTarget[$field]}
    $databaseObserved=Get-HostSnapshot $databaseHost
    if($databaseObserved.identity -ne $Plan.databaseHostSnapshot.identity){throw 'Database/authority host identity drifted.'}
    $observed = Get-HostSnapshot $Plan.target
    if ($observed.identity -ne $Plan.hostSnapshot.identity) { throw 'Destination identity drifted.' }
    $remote = Get-AdminSharePath $Plan.target
    $installPath = Join-Path $remote 'control\installation.json'
    if (-not (Test-Path -LiteralPath $installPath)) { throw 'Protected host executor is not provisioned. Review and approve Install-Host.ps1 before staging.' }
    $installation = Read-DeploymentJson $installPath
    if ($installation.identity -ne $observed.identity -or $installation.root -ne $Plan.target.root) { throw 'Host executor installation does not match the approved destination.' }
    $submissionWaitClock=[Diagnostics.Stopwatch]::StartNew()
    $placementLock=Get-PlacementLease $Plan -WaitTimeoutSeconds $SubmissionWaitTimeoutSeconds -RetryIntervalSeconds $PollIntervalSeconds
    $lock=$null
    $transitionStarted=$false
    $session = $null
    try {
        $resumePrepared=$Action -eq 'Cutover' -and $approval.ContainsKey('preparedStateSHA256')
        if($Action -eq 'Recover'){
            $actual=Read-OptionalRemoteRecord (Join-Path (Get-PlacementRoot $Plan) ("placements\$($Plan.environment)\$($Plan.app).json"))
            if(-not $actual -or $actual.status -notin @('Pending','Unknown') -or $actual.planHash -ne $Plan.planHash -or
                $actual.hostIdentity -ne $Plan.hostSnapshot.identity){throw 'Recovery requires the exact unresolved placement.'}
        }else{Assert-PlacementUnchanged $Plan -Verify:($Action -eq 'Verify') -ResumePrepared:$resumePrepared}
        $remainingWait=[int][Math]::Floor($SubmissionWaitTimeoutSeconds-$submissionWaitClock.Elapsed.TotalSeconds)
        if($remainingWait -le 0){throw "Submission wait exceeded $SubmissionWaitTimeoutSeconds seconds before acquiring the executor lock. No request was submitted."}
        $lock=Get-DeploymentLock (Join-Path $remote 'control\submission.lock') -WaitTimeoutSeconds $remainingWait -RetryIntervalSeconds $PollIntervalSeconds
        $session = New-CimSession -ComputerName $Plan.target.host -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 20
        $remainingWait=[int][Math]::Floor($SubmissionWaitTimeoutSeconds-$submissionWaitClock.Elapsed.TotalSeconds)
        if($remainingWait -le 0){throw "Submission wait exceeded $SubmissionWaitTimeoutSeconds seconds before inspecting the executor. No request was submitted."}
        Wait-ForDeploymentExecutor -Session $session -RemoteRoot $remote -TimeoutSeconds $remainingWait -PollIntervalSeconds $PollIntervalSeconds
        if($Action -eq 'Deploy' -and $Plan.ContainsKey('routineRelease') -and $Plan.routineRelease -eq $true){
            $preflightPath=Join-Path $remote ('operations\'+$Plan.id+'-preflight\result.json')
            $preflight=Read-DeploymentJson $preflightPath
            if($preflight.status -ne 'Succeeded' -or $preflight.planHash -ne $Plan.planHash -or
                $preflight.operationId -ne ($Plan.id+'-preflight') -or $preflight.phase -ne 'PreflightVerified' -or
                $preflight.verification.databaseEvidencePath -ne $approval.databaseEvidencePath -or
                $preflight.verification.databaseEvidenceSHA256 -ne $approval.databaseEvidenceSHA256){
                throw 'Routine deployment requires its exact protected preflight result before placement changes.'
            }
        }
        $operationId = $Plan.id + '-' + $Action.ToLowerInvariant()
        if($Action -eq 'Verify'){$operationId+='-'+[guid]::NewGuid().ToString('N').Substring(0,8)}
        $relative = 'operations\' + $operationId
        $operation = Resolve-OwnedPath $remote $relative
        if (Test-Path -LiteralPath $operation) {
            $result = Join-Path $operation 'result.json'
            if (Test-Path -LiteralPath $result) {
                $prior = Read-DeploymentJson $result
                if ($prior.planHash -eq $Plan.planHash -and $prior.status -eq 'Succeeded' -and $Action -ne 'PrepareCutover') { return $prior }
            }
            throw 'Operation already exists without a completed success result. Inspect its journal before retrying; do not repeat unknown side effects.'
        }
        [IO.Directory]::CreateDirectory($operation) | Out-Null
        $package = @{
            operationId=$operationId; action=$Action; plan=$Plan
            approval=(Read-DeploymentJson $ApprovalPath); runtimePath=$RuntimePath; npmPath=$NpmPath
            sourceArchiveSHA256=$null; transferSHA256=$null
        }
        if ($Action -eq 'Stage') {
            if (-not $RuntimePath) { throw 'Stage requires an explicitly reviewed destination runtime executable.' }
            $environment = Get-DeploymentEnvironment $Plan.environment
            $manifestPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) $environment.Value.apps[$Plan.app].manifest))
            $repository = Split-Path -Parent (Split-Path -Parent $manifestPath)
            $git = (Get-Command git -CommandType Application).Source
            $dirty = Invoke-DeploymentCommand $git @('--no-optional-locks','status','--porcelain','--untracked-files=normal') $repository -Capture
            if ($dirty) { throw 'Source is not clean and committed. Review the manifest/adapters before staging.' }
            $archive = Join-Path $operation 'source.zip'
            Invoke-DeploymentCommand $git @('archive','--format=zip',('-o'+$archive),$Plan.sourceCommit) $repository
            $package.sourceArchiveSHA256=(Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()
            if (-not $approval.ContainsKey('sourceArchiveSHA256') -or $approval.sourceArchiveSHA256 -ne $package.sourceArchiveSHA256) {
                throw 'Source archive digest must be reviewed and included in approval before submission.'
            }
        }
        if($resumePrepared){
            $appShare=Join-Path $remote ('apps\'+$Plan.app)
            $receiptPath=Join-Path $appShare 'state\prepared-cutover.json'
            if((Get-FileHash -LiteralPath $receiptPath).Hash.ToLowerInvariant() -ne $approval.preparedStateSHA256){throw 'Prepared receipt differs from final approval.'}
            $receipt=Read-DeploymentJson $receiptPath
            $proofPath=Join-Path $appShare 'state\prepared-transfer.json'
            if((Get-FileHash -LiteralPath $proofPath).Hash.ToLowerInvariant() -ne $approval.transferSHA256 -or
                $receipt.transferSHA256 -ne $approval.transferSHA256){throw 'Prepared transfer differs from final approval.'}
            $proof=Read-DeploymentJson $proofPath
            $package.transferSHA256=$approval.transferSHA256
            $package.sourceFenceVerification=Test-RemoteSourceFence $Plan $proof.fence -Continuity -TransferSHA256 $approval.transferSHA256 -ImportReceiptSHA256 $approval.databaseEvidenceSHA256 -TransferProof $proof
        }
        if ($Action -eq 'PrepareCutover' -or ($Action -eq 'Cutover' -and -not $resumePrepared)) {
            if($TransferArchivePath){
                if(-not $approval.ContainsKey('transferSHA256')){throw 'Cutover requires a reviewed frozen-state export.'}
                # Structural check before the slow copy; the protected executor rehashes every extracted file.
                $transfer=Test-TransferArchive $TransferArchivePath $approval.transferSHA256 $approval.transferArchiveSHA256
                Copy-ApprovedTransferArchive $TransferArchivePath (Join-Path $operation 'transfer.zip') $approval.transferArchiveSHA256
                $package.transferSHA256=$approval.transferSHA256
                $package.transferArchiveSHA256=$approval.transferArchiveSHA256
            } else {
            if (-not $TransferDirectory -or -not $approval.ContainsKey('transferSHA256')) { throw 'Cutover requires a reviewed frozen-state export.' }
            if ($approval.ContainsKey('transferArchiveSHA256')) { throw 'Approval binds a transfer archive; submit it with -TransferArchivePath.' }
            $proof = Join-Path $TransferDirectory 'transfer.json'
            if ((Get-FileHash -LiteralPath $proof).Hash.ToLowerInvariant() -ne $approval.transferSHA256) { throw 'Transfer proof differs from approval.' }
            $package.transferSHA256 = $approval.transferSHA256
            $destination = Join-Path $operation 'transfer'
            [IO.Directory]::CreateDirectory($destination) | Out-Null
            $transfer = Read-DeploymentJson $proof
            foreach ($file in $transfer.files) {
                $from = Resolve-OwnedPath $TransferDirectory $file.target
                $to = Resolve-OwnedPath $destination $file.target
                if ((Get-FileHash -LiteralPath $from).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'Transfer payload differs from proof.' }
                [IO.Directory]::CreateDirectory((Split-Path -Parent $to)) | Out-Null
                [IO.File]::Copy($from,$to,$false)
            }
            [IO.File]::Copy($proof,(Join-Path $destination 'transfer.json'),$false)
            }
            if($Action -eq 'PrepareCutover'){
                $package.sourceFenceVerification=Test-RemoteSourceFence $Plan $transfer.fence -TransferContinuity -TransferSHA256 $approval.transferSHA256 -TransferProof $transfer
            }else{$package.sourceFenceVerification=Test-RemoteSourceFence $Plan $transfer.fence}
        }
        if($Action -in @('PrepareCutover','Deploy','Cutover','Rollback')){
            Set-PlacementTransition $Plan Pending
            $transitionStarted=$true
        }
        $request = Join-Path $operation 'request.json'
        Write-DeploymentJson $request $package
        $requestHash = (Get-FileHash -LiteralPath $request).Hash.ToLowerInvariant()
        Write-DeploymentJson (Join-Path $remote 'control\pending.json') @{operationId=$operationId;requestSHA256=$requestHash}
        $task = Get-ScheduledTask -CimSession $session -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-Executor' -ErrorAction Stop
        if (-not $task) { throw 'Fixed protected executor task is missing.' }
        Start-ScheduledTask -CimSession $session -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-Executor' -ErrorAction Stop
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $resultPath = Join-Path $operation 'result.json'
        while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            if (Test-Path -LiteralPath $resultPath) {
                $result = Read-DeploymentJson $resultPath
                if ($result.operationId -ne $operationId -or $result.planHash -ne $Plan.planHash) { throw 'Executor result does not match the submitted operation.' }
                if ($result.status -ne 'Succeeded') {
                    if($Action -eq 'Deploy' -and $result.ContainsKey('cleanAbort') -and $result.cleanAbort -eq $true){
                        Restore-VerifiedPlacement -Plan $Plan -RemoteRoot $remote -OperationDirectory $operation
                        $transitionStarted=$false
                    }
                    throw "Executor reported $($result.status). Inspect the protected operation journal."
                }
                if($Action -eq 'Recover'){
                    if($result.phase -ne 'RecoveredPrevious' -or $result.verification.releaseId -ne $Plan.currentRelease.releaseId){
                        throw 'Recovery result does not establish the previous active release.'
                    }
                    Restore-VerifiedPlacement -Plan $Plan -RemoteRoot $remote -OperationDirectory (Join-Path $remote ('operations\'+$Plan.id+'-deploy'))
                }
                if($transitionStarted){
                    if($Action -eq 'PrepareCutover'){
                        if($result.phase -ne 'Prepared' -or $result.verification.runtimeStarted -ne $false -or
                            $result.verification.preparedStateSHA256 -notmatch '^[a-f0-9]{64}$'){throw 'Preparation result is incomplete.'}
                        Set-PlacementTransition $Plan Prepared
                    }else{Set-PlacementTransition $Plan Active -ReleaseId $result.verification.releaseId}
                    $transitionStarted=$false
                }
                return $result
            }
            Write-Host ("Waiting for {0}; elapsed {1:n0}s" -f $operationId,$clock.Elapsed.TotalSeconds)
            Start-Sleep -Seconds 5
        }
        throw "Executor deadline exceeded. Outcome is unknown for operation $operationId; do not resubmit. Inspect its result and source/target authority before resuming."
    } finally {
        try{if($transitionStarted){Set-PlacementTransition $Plan Unknown}}
        finally{
            try{if($session){Remove-CimSession $session}}
            finally{
                try{if($lock){$lock.Dispose()}}finally{$placementLock.Dispose()}
            }
        }
    }
}

function Restore-VerifiedPlacement {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][string]$RemoteRoot,
        [Parameter(Mandatory)][string]$OperationDirectory)
    if(-not $Plan.placementAuthority -or $Plan.placementAuthority.status -ne 'Active'){throw 'Previous placement is not a verified active baseline.'}
    $executionLock=$null;$appLock=$null
    try {
        $deadline=[DateTimeOffset]::Now.AddSeconds(10)
        while(-not $executionLock){
            try{$executionLock=[IO.File]::Open((Join-Path $RemoteRoot 'control\execution.lock'),'OpenOrCreate','ReadWrite','None')}
            catch [IO.IOException]{
                if([DateTimeOffset]::Now -ge $deadline){throw 'Executor is still active; placement reconciliation deferred.'}
                Start-Sleep -Milliseconds 200
            }
        }
        $appRoot=Join-Path $RemoteRoot ('apps\'+$Plan.app)
        $appLock=Get-DeploymentLock (Join-Path $appRoot 'state\deployment.lock')
        foreach($directory in Get-ChildItem -LiteralPath (Join-Path $RemoteRoot 'operations') -Directory){
            $candidatePath=Join-Path $directory.FullName 'request.json'
            if(-not (Test-Path -LiteralPath $candidatePath) -or (Test-Path -LiteralPath (Join-Path $directory.FullName 'result.json'))){continue}
            $candidate=Read-DeploymentJson $candidatePath
            if($candidate.plan.app -eq $Plan.app -and
                [DateTimeOffset]::Parse($candidate.plan.createdLocal) -ge [DateTimeOffset]::Parse($Plan.createdLocal)){
                throw 'An incomplete competing operation prevents placement reconciliation.'
            }
        }
        $phase=Read-DeploymentJson (Join-Path $OperationDirectory 'phase.json')
        $requestPath=Join-Path $OperationDirectory 'request.json'
        $request=Read-DeploymentJson $requestPath
        if($phase.phase -ne 'Preflight' -or $phase.planHash -ne $Plan.planHash -or
            $phase.operationId -ne $request.operationId -or -not $phase.ContainsKey('targetMayHaveWritten') -or
            $phase.targetMayHaveWritten -ne $false -or
            $phase.requestSHA256 -ne (Get-FileHash $requestPath).Hash.ToLowerInvariant()){
            throw 'Clean-abort journal changed; placement reconciliation refused.'
        }
        $active=Read-DeploymentJson (Join-Path $appRoot 'state\active.json')
        if($active.planHash -ne $Plan.currentRelease.planHash -or $active.releaseId -ne $Plan.currentRelease.releaseId -or
            (Test-Path -LiteralPath (Join-Path $appRoot 'state\maintenance.json'))){throw 'Old release changed after clean-abort verification.'}
        $placementPath=Join-Path (Get-PlacementRoot $Plan) ("placements\$($Plan.environment)\$($Plan.app).json")
        $before=Read-DeploymentJson $placementPath
        if($before.planHash -ne $Plan.planHash -or $before.status -notin @('Pending','Unknown')){throw 'Placement changed before reconciliation.'}
        $receipt=Join-Path $OperationDirectory 'placement-recovery.json'
        Write-DeploymentJson $receipt @{planHash=$Plan.planHash;before=$before;restored=$Plan.placementAuthority;verifiedLocal=(Get-Date).ToString('o')} -CreateNew
        Write-DeploymentJson $placementPath $Plan.placementAuthority
        if((ConvertTo-CanonicalJson (Read-DeploymentJson $placementPath)) -ne (ConvertTo-CanonicalJson $Plan.placementAuthority)){throw 'Restored placement read-back differs.'}
    }finally{
        if($appLock){$appLock.Dispose()}
        if($executionLock){$executionLock.Dispose()}
    }
}

Export-ModuleMember -Function Get-AdminSharePath,Get-RemoteDeploymentStatus,Submit-DeploymentOperation
