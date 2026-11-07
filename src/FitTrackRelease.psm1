#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Release.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CommonRelease.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SshTransport.psm1') -DisableNameChecking

function Get-FitTrackSourceDigest {
    param([Parameter(Mandatory)][string]$Path)
    # Git checkouts and the original copied watcher use different line endings.
    Get-Sha256Text ((Invoke-DeploymentFileOperation ReadAllText @($Path)).Replace("`r`n","`n"))
}

function Assert-FitTrackDatabaseInputs {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Installed,[hashtable]$Applied=@{})
    $paths=@('deploy\application.json')
    foreach($root in @($Source,$Installed)){
        $paths+=@(Get-ChildItem -LiteralPath (Join-Path $root 'deploy\postgresql') -File -Recurse |
            ForEach-Object {[IO.Path]::GetRelativePath($root,$_.FullName)})
    }
    foreach($path in @($paths|Sort-Object -Unique)){
        $next=Join-Path $Source $path
        $old=Join-Path $Installed $path
        # An input already verified live passes only at exactly its recorded digest.
        $key=$path.Replace('\','/')
        if($Applied.ContainsKey($key) -and (Test-Path -LiteralPath $next -PathType Leaf) -and
            (Get-FitTrackSourceDigest $next) -eq $Applied[$key]){continue}
        if(-not (Test-Path -LiteralPath $next -PathType Leaf) -or
            -not (Test-Path -LiteralPath $old -PathType Leaf) -or
            (Get-FitTrackSourceDigest $next) -ne (Get-FitTrackSourceDigest $old)){
            throw "Fit Track manifest/database input changed: $path. Use a separately reviewed procedure; the review flag does not bypass this gate."
        }
    }
    $sql=@(Get-ChildItem -LiteralPath $Source -File -Recurse -Filter '*.sql')
    if(@($sql|Where-Object {$_.FullName -notlike ((Join-Path $Source 'deploy\postgresql')+'\*')}).Count){
        throw 'SQL outside the verified migration directory requires a separately reviewed procedure.'
    }
}

function Get-FitTrackBaseline {
    param([Parameter(Mandatory)][string]$Installed)
    $files=@(foreach($relative in @('backend\app','deploy','frontend\dist')){
        foreach($file in Get-ChildItem -LiteralPath (Join-Path $Installed $relative) -File -Recurse){
            if($file.FullName -match '\\__pycache__\\|\.pyc$'){continue}
            @{path=[IO.Path]::GetRelativePath($Installed,$file.FullName);sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()}
        }
    })
    $files+=@(@{path='.venv\Scripts\python.exe';sha256=(Get-FileHash -LiteralPath (Join-Path $Installed '.venv\Scripts\python.exe')).Hash.ToLowerInvariant()})
    $files
}

function Invoke-FitTrackHostPhase {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$RemoteOperation,[Parameter(Mandatory)][string]$RequestSHA256,
        [Parameter(Mandatory)][ValidateSet('Prepare','Activate')][string]$Phase,[int]$TimeoutSeconds=300)
    $powerShell='C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'
    $command='"'+$powerShell+'" -NoProfile -NonInteractive -WindowStyle Hidden -File "'+
        (Join-Path $RemoteOperation 'runner.ps1')+'" -RequestPath "'+
        (Join-Path $RemoteOperation 'request.json')+'" -RequestSHA256 '+$RequestSHA256+' -Phase '+$Phase
    $created=Invoke-CimMethod -CimSession $Session -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command}
    if($created.ReturnValue -ne 0){throw "Could not launch Fit Track $Phase (Windows result $($created.ReturnValue))."}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $path=Join-Path $Operation ($Phase.ToLowerInvariant()+'-result.json')
    while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds){
        if(Test-Path -LiteralPath $path){
            $result=Read-DeploymentJson $path
            if($result.requestSHA256 -ne $RequestSHA256 -or $result.phase -ne $Phase){throw 'Fit Track host result does not match the request.'}
            if($result.status -ne 'Succeeded'){throw "Fit Track $Phase failed: $($result.error) Inspect $path before recovery."}
            return $result
        }
        Write-Host ("Fit Track {0}: elapsed {1:n0}s; host PID {2}." -f $Phase,$clock.Elapsed.TotalSeconds,$created.ProcessId)
        Start-Sleep -Seconds 5
        $process=Get-CimInstance -CimSession $Session -ClassName Win32_Process -Filter "ProcessId=$($created.ProcessId)"
        if(-not $process -and -not (Test-Path -LiteralPath $path)){throw "Fit Track $Phase exited without a result. Outcome unknown; inspect $Operation."}
    }
    throw "Fit Track $Phase exceeded its deadline. Outcome unknown; inspect host PID $($created.ProcessId) and $Operation. Do not automatically retry or roll back."
}

$script:WatcherPaths=@('backend\scripts\Watch-Upload.ps1','backend\scripts\run-watcher-hidden.vbs','backend\scripts\upload_folder.py',
    'backend\scripts\Register-UploadWatcherTask.ps1','backend\scripts\Test-UploadWatcher.ps1')

function Get-FitTrackWatcherFiles {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Installed)
    @(foreach($path in $script:WatcherPaths){
        $next=Join-Path $Source $path
        if(-not (Test-Path -LiteralPath $next -PathType Leaf)){throw "Watcher file missing from the commit: $path."}
        $old=Join-Path $Installed $path
        $sha=if(Test-Path -LiteralPath $old -PathType Leaf){Get-FitTrackSourceDigest $old}else{$null}
        @{path=$path;sha256=$sha;matches=($sha -eq (Get-FitTrackSourceDigest $next))}
    })
}

function Update-FitTrackWatcherFiles {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Installed,
        [Parameter(Mandatory)][object[]]$Files,[Parameter(Mandatory)][string]$Backup)
    $changed=@($Files|Where-Object {-not $_.matches})
    if(@($changed|Where-Object {$_.path -like '*Register-UploadWatcherTask.ps1'}).Count){
        throw 'Register-UploadWatcherTask.ps1 changed, so the watcher task definition changes too. Re-register the task on jimbrownhome1 from your session, then release again. Nothing was copied.'
    }
    foreach($file in $changed){
        $old=Join-Path $Installed $file.path
        if(Test-Path -LiteralPath $old){
            $saved=Join-Path $Backup $file.path
            Invoke-DeploymentFileOperation CreateDirectory @((Split-Path -Parent $saved))|Out-Null
            Invoke-DeploymentFileOperation Copy @($old,$saved,$true)
        }
    }
    foreach($file in $changed){
        # The installed copies use CRLF (wscript needs it for the .vbs); git stores LF.
        $text=[IO.File]::ReadAllText((Join-Path $Source $file.path)).Replace("`r`n","`n").Replace("`n","`r`n")
        $target=Join-Path $Installed $file.path
        Invoke-DeploymentFileOperation CreateDirectory @((Split-Path -Parent $target))|Out-Null
        Invoke-DeploymentFileOperation WriteAllBytes @($target,[Text.UTF8Encoding]::new($false).GetBytes($text))
    }
    @($changed|ForEach-Object {$_.path})
}

function Get-FitTrackWatcherProcesses {
    param([Parameter(Mandatory)]$Session)
    @(Get-CimInstance -CimSession $Session -ClassName Win32_Process -Filter "Name='wscript.exe' OR Name='pwsh.exe' OR Name='python.exe' OR Name='pythonw.exe'"|
        Where-Object {$_.CommandLine -like '*run-watcher-hidden.vbs*' -or $_.CommandLine -like '*Watch-Upload.ps1*' -or $_.CommandLine -like '*scripts.upload_folder*'})
}

function Restart-FitTrackWatcher {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Log)
    if(-not @(Get-CimInstance -CimSession $Session -ClassName Win32_Process -Filter "Name='explorer.exe'").Count){
        return @{restarted=$false;note='Nobody is signed in on jimbrownhome1. The updated watcher starts at the next sign-in.'}
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $restartedAt=[DateTime]::Now.AddSeconds(-2)
    Stop-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track-upload-watcher
    # Stopping the task ends only wscript; the pwsh and python children keep running and the singleton guard would skip the new start.
    foreach($process in Get-FitTrackWatcherProcesses $Session){
        # wscript exits on its own after Stop-ScheduledTask, so a process already gone is fine; the wait below proves they all exited.
        try{Invoke-CimMethod -InputObject $process -MethodName Terminate -ErrorAction Stop|Out-Null}catch{}
    }
    while(@(Get-FitTrackWatcherProcesses $Session).Count){
        if($clock.Elapsed.TotalSeconds -gt 20){throw 'The old upload watcher processes did not exit within 20 s. Nothing was started; check them on jimbrownhome1.'}
        Start-Sleep -Seconds 1
    }
    Start-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track-upload-watcher
    $watcher=$null
    while(-not $watcher){
        if($clock.Elapsed.TotalSeconds -gt 45){throw 'The upload watcher task started, but no upload_folder process appeared within 45 s. Check backend\logs\upload-watcher.log on jimbrownhome1.'}
        Start-Sleep -Seconds 2
        $watcher=@(Get-FitTrackWatcherProcesses $Session|Where-Object {$_.CommandLine -like '*scripts.upload_folder*'})|Select-Object -First 1
    }
    Start-Sleep -Seconds 10
    $python=@(Get-FitTrackWatcherProcesses $Session|Where-Object {$_.CommandLine -like '*scripts.upload_folder*'})
    if($python.Count -ne 1 -or $python[0].ProcessId -ne $watcher.ProcessId){
        throw "The upload watcher did not stay up: expected 1 upload_folder process 10 s after start, found $($python.Count). Check backend\logs\upload-watcher.log on jimbrownhome1."
    }
    $started=@(Get-Content -LiteralPath $Log -Tail 50|Where-Object {$_ -match '^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\] Watching ' -and [DateTime]::Parse($Matches[1]) -ge $restartedAt})
    if(-not $started.Count){throw 'The upload watcher is running, but its log has no new "Watching" line. Check backend\logs\upload-watcher.log on jimbrownhome1.'}
    @{restarted=$true;processId=$watcher.ProcessId;seconds=[Math]::Round($clock.Elapsed.TotalSeconds,1)}
}

function Invoke-FitTrackRelease {
    [CmdletBinding()]
    param([string]$App='fit-track',[string[]]$Component,[string]$Environment='production',
        [string]$Target='jimbrownhome1',[string]$Commit='HEAD',[Parameter(Mandatory)][string]$Repository,
        [switch]$ApproveRelease,[string]$ApprovalReason,[switch]$DatabaseChangesReviewed,
        [DateTimeOffset]$ExpiresLocal=([DateTimeOffset]::Now.AddMinutes(30)),[string]$TailscaleUrl,
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'),
        [int]$TimeoutSeconds=300,[hashtable]$Entry=@{})
    $startedLocal=(Get-Date).ToString('o')
    if($App -ne 'fit-track' -or $Environment -ne 'production' -or $Target -ine 'jimbrownhome1' -or
        -not $ApproveRelease -or -not $DatabaseChangesReviewed -or [string]::IsNullOrWhiteSpace($ApprovalReason)){
        throw 'Fit Track routine releases require the existing production placement and explicit release/code-review consent.'
    }
    if($ExpiresLocal -le [DateTimeOffset]::Now -or $ExpiresLocal -gt [DateTimeOffset]::Now.AddHours(1)){throw 'Release consent must expire within 1 hour.'}
    $commitId=Resolve-CommonReleaseSource $Repository $Commit
    $configuration=(Get-DeploymentEnvironment production).Value
    $hostConfig=@{}+$configuration.hosts.jimbrownhome1
    $hostConfig.apps=@{'fit-track'=@{port=8791}}
    $snapshot=Get-HostSnapshot $hostConfig
    $remote=Get-DeploymentRemotePath jimbrownhome1 'C:\ProgramData\SolutionDeploy\apps\fit-track'
    $appRoot='C:\ProgramData\SolutionDeploy\apps\fit-track'
    $lock=Get-DeploymentLock (Join-Path $remote 'state\common-controller.lock')
    $session=$null
    $id=[guid]::NewGuid().ToString('N')
    $directory=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('releases\fit-track-'+$id)
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $receipt=@{app=$App;sourceCommit=$commitId;status='Preparing';components=@{web='NotAttempted';'upload-watcher'='NotAttempted'}
        startedLocal=$startedLocal;externalAcceptance='Pending';phases=@();reason=$ApprovalReason}
    $receiptPath=Join-Path $directory 'release.json'
    try{
        $active=Read-DeploymentJson (Join-Path $remote 'state\active.json')
        if($active.releaseId -notmatch '^[a-zA-Z0-9-]+$'){throw 'Unexpected Fit Track release id.'}
        $current=Join-Path $remote ('releases\'+$active.releaseId)
        $currentLocal=Join-Path $appRoot ('releases\'+$active.releaseId)
        $link=Get-Item -LiteralPath (Join-Path $remote 'current')
        if($link.LinkType -ne 'Junction' -or [string]$link.Target -ine $currentLocal){throw 'Fit Track current junction differs from active metadata.'}
        if(Test-Path -LiteralPath (Join-Path $remote 'state\maintenance.json')){throw 'Fit Track is already in maintenance. Inspect it before release.'}
        $git=(Get-Command git -CommandType Application).Source
        $archive=Join-Path $directory 'source.zip'
        Invoke-DeploymentCommand $git @('archive','--format=zip',('-o'+$archive),$commitId) $Repository
        $source=Join-Path $directory 'source'
        Expand-TrustedRelease $archive $source
        $sourceHash=(Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()
        $watcherFiles=Get-FitTrackWatcherFiles $source (Join-Path $remote 'upload-watcher')
        $watcherChanged=@($watcherFiles|Where-Object {-not $_.matches}).Count -gt 0
        $watcherSelected=$watcherChanged -and (-not $Component -or 'upload-watcher' -in $Component)
        $receipt.components.'upload-watcher'=if(-not $watcherChanged){'UnchangedSourceVerified'}elseif($watcherSelected){'Pending'}else{'NotSelected'}
        $session=New-DeploymentSession -ComputerName jimbrownhome1.local -OperationTimeoutSec 20
        $watcherTask=Get-ScheduledTask -CimSession $session -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track-upload-watcher
        $watcherTaskHash=Get-Sha256Text (Export-ScheduledTask -CimSession $session -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track-upload-watcher)
        $receipt.watcher=@{taskStateBefore=[string]$watcherTask.State;configurationSHA256=$watcherTaskHash;source=$watcherFiles
            scope='Google Drive logon task definition retained; no upload or ingestion triggered.'}
        $webSelected='web' -in $Component
        if(-not $Component){
            $baselinePath=Join-Path $remote 'state\common-release.json'
            if(-not (Test-Path -LiteralPath $baselinePath)){throw 'Fit Track has mixed legacy web versions. Establish the first full web baseline with -Component web; the unchanged watcher remains separate.'}
            $baseline=Read-DeploymentJson $baselinePath
            $record=Read-DeploymentJson (Join-Path $current 'release.json')
            if($baseline.releaseId -ne $active.releaseId -or $baseline.sourceCommit -ne $record.sourceCommit){throw 'Fit Track component baseline differs from the active release.'}
            $webSelected=Get-CommonReleaseChanges $Repository $baseline.sourceCommit $commitId @('frontend','backend/app','backend/requirements.txt','deploy')
        }
        $applied=@{}
        if($Entry['appliedDatabaseInputs']){foreach($item in $Entry['appliedDatabaseInputs'].GetEnumerator()){$applied[$item.Key]=[string]$item.Value}}
        Assert-FitTrackDatabaseInputs $source $current $applied
        $manifest=Read-DeploymentJson (Join-Path $source 'deploy\application.json')
        $accessPlan=@{target=@{host=$Target};manifest=$manifest}
        if(-not $TailscaleUrl){$TailscaleUrl='https://jimbrownhome1.tail8ad282.ts.net:8791/'}
        $receipt.initialAccess=Test-ReleaseAccess $accessPlan $TailscaleUrl
        if($watcherSelected){
            Assert-DeploymentLease @($lock)
            $receipt.components.'upload-watcher'='Copying'
            Write-DeploymentJson $receiptPath $receipt
            $watcherRoot=Join-Path $remote 'upload-watcher'
            $receipt.watcher.updated=Update-FitTrackWatcherFiles $source $watcherRoot $watcherFiles (Join-Path $directory 'previous-watcher')
            if(@(Get-FitTrackWatcherFiles $source $watcherRoot|Where-Object {-not $_.matches}).Count){throw 'Watcher files still differ from the commit after copying.'}
            $receipt.components.'upload-watcher'='Copied'
            Write-DeploymentJson $receiptPath $receipt
            Assert-DeploymentLease @($lock)
            $receipt.watcher.restart=Restart-FitTrackWatcher $session (Join-Path $watcherRoot 'backend\logs\upload-watcher.log')
            if((Get-Sha256Text (Export-ScheduledTask -CimSession $session -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track-upload-watcher)) -ne $watcherTaskHash){
                throw 'Fit Track watcher task configuration changed during release.'
            }
            $receipt.components.'upload-watcher'=if($receipt.watcher.restart.restarted){'Verified'}else{'Copied'}
            Write-DeploymentJson $receiptPath $receipt
        }
        if(-not $webSelected){
            if($Component -and 'upload-watcher' -notin $Component){throw 'No supported component was selected.'}
            $receipt.components.web=if($Component){'NotSelected'}else{'SourceUnchanged'}
            $receipt.externalAcceptance='Verified'
            # Do not claim runtime or external verification from a source-only comparison.
            $receipt.status=if($watcherSelected){'Succeeded'}else{'NoChanges'}
            if($watcherSelected){$receipt.completedLocal=(Get-Date).ToString('o')}
            Write-DeploymentJson $receiptPath $receipt
            return $receipt
        }
        $receipt.components.web='Preparing'
        Write-DeploymentJson $receiptPath $receipt
        Write-Host 'Fit Track: building frontend from the pinned source archive before downtime.'
        $frontend=Join-Path $source 'frontend'
        $nodeCommand=(Get-Command node -CommandType Application|Select-Object -First 1).Source
        $node=Invoke-DeploymentCommand $nodeCommand @('-p','process.execPath') $source -Capture
        $npmCli=Join-Path (Split-Path -Parent $node) 'node_modules\npm\bin\npm-cli.js'
        if(-not (Test-Path -LiteralPath $npmCli)){throw 'Cannot resolve npm CLI beside the actual Node runtime.'}
        $receipt.frontendTools=@{node=$node;nodeSHA256=(Get-FileHash -LiteralPath $node).Hash.ToLowerInvariant()
            npmCliSHA256=(Get-FileHash -LiteralPath $npmCli).Hash.ToLowerInvariant()}
        Invoke-DeploymentCommand $node @($npmCli,'ci','--ignore-scripts','--no-audit','--no-fund') $frontend -TimeoutSeconds $TimeoutSeconds
        Invoke-DeploymentCommand $node @($npmCli,'run','build') $frontend -TimeoutSeconds $TimeoutSeconds
        $payload=Join-Path $directory 'payload.zip'
        Invoke-DeploymentFileOperation Copy @($archive,$payload,$false)
        $zip=[IO.Compression.ZipFile]::Open($payload,[IO.Compression.ZipArchiveMode]::Update)
        try{
            foreach($file in Get-ChildItem -LiteralPath (Join-Path $frontend 'dist') -File -Recurse){
                $name='frontend/dist/'+[IO.Path]::GetRelativePath((Join-Path $frontend 'dist'),$file.FullName).Replace('\','/')
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$file.FullName,$name)|Out-Null
            }
        }finally{$zip.Dispose()}
        $prior=Read-DeploymentJson (Join-Path $current 'release.json')
        $runtime=[string]$prior.runtimePath
        if($runtime -notmatch '^[A-Za-z]:\\' -or $runtime -match '(?i)\\current\\|\\shims\\'){throw 'Existing Fit Track build runtime must be a fixed installation.'}
        $runtimeShare=Get-DeploymentRemotePath jimbrownhome1 $runtime
        if((Get-FileHash -LiteralPath $runtimeShare).Hash -ine $prior.runtimeSHA256){throw 'Fit Track build runtime differs from installed metadata.'}
        $operation=Join-Path $remote ('state\routine\'+$id)
        $remoteOperation=Join-Path $appRoot ('state\routine\'+$id)
        Assert-DeploymentLease @($lock)
        Invoke-DeploymentFileOperation CreateDirectory @($operation)|Out-Null
        Copy-Item -LiteralPath $payload -Destination (Join-Path $operation 'payload.zip')
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Invoke-FitTrackRelease.ps1') -Destination (Join-Path $operation 'runner.ps1')
        $plan=@{id=$id;app=$App;sourceCommit=$commitId;releaseId=('routine-'+$commitId.Substring(0,12)+'-'+$id.Substring(0,8))
            manifest=$manifest;manifestHash=(Get-FileHash -LiteralPath (Join-Path $source 'deploy\application.json')).Hash.ToLowerInvariant()}
        $plan.planHash=Get-PlanDigest $plan
        $request=@{plan=$plan;hostIdentity=$snapshot.identity;expiresLocal=$ExpiresLocal.ToString('o');reason=$ApprovalReason
            approvedBy=[Security.Principal.WindowsIdentity]::GetCurrent().Name;dataActionsReviewed=$true
            previousRelease=$active.releaseId;previousActiveSHA256=(Get-FileHash -LiteralPath (Join-Path $remote 'state\active.json')).Hash.ToLowerInvariant()
            baseline=@(Get-FitTrackBaseline $current);watcherFiles=$watcherFiles;runtimePath=$runtime;runtimeSHA256=$prior.runtimeSHA256
            watcherTaskSHA256=$watcherTaskHash
            sourceArchiveSHA256=$sourceHash;payloadSHA256=(Get-FileHash -LiteralPath $payload).Hash.ToLowerInvariant()
            runnerSHA256=(Get-FileHash -LiteralPath (Join-Path $operation 'runner.ps1')).Hash.ToLowerInvariant()
            timeoutSeconds=$TimeoutSeconds}
        Write-DeploymentJson (Join-Path $operation 'request.json') $request -CreateNew
        $requestHash=(Get-FileHash -LiteralPath (Join-Path $operation 'request.json')).Hash.ToLowerInvariant()
        $receipt.operation=$remoteOperation;$receipt.requestSHA256=$requestHash
        $receipt.phases+=@(Invoke-FitTrackHostPhase $session $operation $remoteOperation $requestHash Prepare $TimeoutSeconds)
        $receipt.components.web='Prepared'
        Write-DeploymentJson $receiptPath $receipt
        Assert-DeploymentLease @($lock)
        $receipt.phases+=@(Invoke-FitTrackHostPhase $session $operation $remoteOperation $requestHash Activate $TimeoutSeconds)
        $receipt.components.web='RuntimeVerified'
        Write-DeploymentJson $receiptPath $receipt
        $receipt.access=Test-ReleaseAccess $accessPlan $TailscaleUrl
        if((Get-Sha256Text (Export-ScheduledTask -CimSession $session -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track-upload-watcher)) -ne $watcherTaskHash){
            throw 'Fit Track watcher task configuration changed during release.'
        }
        $receipt.watcher.taskStateAfter=[string](Get-ScheduledTask -CimSession $session -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-fit-track-upload-watcher).State
        $receipt.components.web='Verified';$receipt.externalAcceptance='Verified';$receipt.status='Succeeded'
        $receipt.completedLocal=(Get-Date).ToString('o')
        Write-DeploymentJson $receiptPath $receipt
        $receipt
    }catch{
        $receipt.status='Failed';$receipt.error=$_.Exception.Message
        Write-DeploymentJson $receiptPath $receipt
        throw
    }finally{
        if($session){Close-DeploymentSession $session}
        $lock.Dispose()
    }
}

Export-ModuleMember -Function Get-FitTrackSourceDigest,Assert-FitTrackDatabaseInputs,Get-FitTrackBaseline,Invoke-FitTrackHostPhase,Invoke-FitTrackRelease,Get-FitTrackWatcherFiles,Update-FitTrackWatcherFiles,Get-FitTrackWatcherProcesses,Restart-FitTrackWatcher
