#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CommonRelease.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'HandPlacedRelease.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SshTransport.psm1') -DisableNameChecking

$script:HostAppRoot='C:\ProgramData\SolutionDeploy\apps'
$script:HostShareRoot=Get-DeploymentRemotePath jimbrownhome1 $script:HostAppRoot
$script:TaskPath='\JimlerTech\'

# Python and test caches are written beside the code at run time and are not part of a release.
function Get-PinnedJobTree {
    param([Parameter(Mandatory)][string]$Root)
    $files=@{}
    foreach($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force){
        $relative=[IO.Path]::GetRelativePath($Root,$file.FullName)
        if($relative -match '(^|\\)(__pycache__|\.pytest_cache|\.ruff_cache)(\\|$)'){continue}
        $files[$relative]=Get-NormalizedFileDigest $file.FullName
    }
    $files
}

function Compare-PinnedJobTree {
    param([Parameter(Mandatory)][hashtable]$Expected,[Parameter(Mandatory)][hashtable]$Actual)
    @(@($Expected.Keys|Where-Object {-not $Actual.ContainsKey($_) -or $Actual[$_] -ne $Expected[$_]})+
        @($Actual.Keys|Where-Object {-not $Expected.ContainsKey($_)})|Sort-Object -Unique)
}

function Copy-PinnedJobSource {
    param([Parameter(Mandatory)][string]$Worktree,[Parameter(Mandatory)]$Paths,[Parameter(Mandatory)][string]$Output)
    [IO.Directory]::CreateDirectory($Output)|Out-Null
    foreach($item in $Paths.GetEnumerator()){
        $source=Join-Path $Worktree $item.Key
        if(-not (Test-Path -LiteralPath $source -PathType Container)){throw "Job source folder missing from the commit: $($item.Key)"}
        $destination=if($item.Value -eq '.'){$Output}else{Join-Path $Output $item.Value}
        [IO.Directory]::CreateDirectory($destination)|Out-Null
        Get-ChildItem -LiteralPath $source -Force|Copy-Item -Destination $destination -Recurse -Force
    }
    Get-ChildItem -LiteralPath $Output -Directory -Recurse -Force|
        Where-Object Name -in '__pycache__','.pytest_cache','.ruff_cache'|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-PinnedJobReleasePath {
    param([Parameter(Mandatory)][string]$App,[Parameter(Mandatory)][hashtable]$Job,[Parameter(Mandatory)][object[]]$Tasks)
    $paths=@(foreach($task in $Tasks){
        $actions=@($task.Actions)
        if($actions.Count -ne 1){throw "$($task.TaskName) must have exactly one action."}
        if($actions[0].Arguments -notmatch '-ReleasePath "([^"]+)"'){throw "$($task.TaskName) has no quoted -ReleasePath."}
        $Matches[1]
    })
    $unique=@($paths|Sort-Object -Unique)
    if($unique.Count -ne 1){throw "$App job tasks point at different releases: $($unique -join ', '). Repoint them by hand first."}
    $prefix=Join-Path $script:HostAppRoot "$App\releases\$($Job.prefix)"
    if(-not $unique[0].StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "$App job release is outside its releases folder: $($unique[0])"}
    $short=$unique[0].Substring($prefix.Length)
    if($short -cnotmatch '^[a-f0-9]{7,12}$'){throw "$App job release name does not end in a commit: $($unique[0])"}
    @{path=$unique[0];short=$short;name=Split-Path -Leaf $unique[0]}
}

function New-PinnedJobAction {
    param([Parameter(Mandatory)]$Action,[Parameter(Mandatory)][string]$OldPath,[Parameter(Mandatory)][string]$NewPath)
    if($Action.Arguments -notlike "*`"$OldPath`"*"){throw 'Task action does not reference the current release.'}
    $arguments=$Action.Arguments.Replace($OldPath,$NewPath)
    $directory=if($Action.WorkingDirectory){([string]$Action.WorkingDirectory).Replace($OldPath,$NewPath)}else{$null}
    @{Execute=$Action.Execute;Argument=$arguments;WorkingDirectory=$directory}
}

function Get-PinnedJobTasks {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string[]]$Names)
    @(foreach($name in $Names){Get-ScheduledTask -CimSession $Session -TaskPath $script:TaskPath -TaskName $name})
}

function Set-PinnedJobTaskAction {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][hashtable]$Action)
    $parameters=@{Execute=$Action.Execute;Argument=$Action.Argument}
    if($Action.WorkingDirectory){$parameters.WorkingDirectory=$Action.WorkingDirectory}
    $new=New-ScheduledTaskAction @parameters
    # Only the action changes. Triggers, settings, account and enabled state stay as installed.
    Set-ScheduledTask -CimSession $Session -TaskPath $script:TaskPath -TaskName $Name -Action $new|Out-Null
}

function Get-PinnedJobAccessParameters {
    param([Parameter(Mandatory)][object[]]$Tasks)
    $python=@();$config=@()
    foreach($task in $Tasks){
        if($task.Principal.UserId -notin @('LOCAL SERVICE','NT AUTHORITY\LOCAL SERVICE','S-1-5-19') -or
            [string]$task.Principal.LogonType -ne 'ServiceAccount'){throw "$($task.TaskName) is not running as LOCAL SERVICE."}
        $arguments=[string]$task.Actions[0].Arguments
        if($arguments -notmatch '(?i)(?:^|\s)-PythonPath\s+"([^"]+)"'){throw "$($task.TaskName) has no quoted -PythonPath."}
        $python+=$Matches[1]
        if($arguments -notmatch '(?i)(?:^|\s)-ConfigPath\s+"([^"]+)"'){throw "$($task.TaskName) has no quoted -ConfigPath."}
        $config+=$Matches[1]
        if($task.Actions[0].Execute -ine 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'){
            throw "$($task.TaskName) does not use the managed PowerShell runtime."
        }
    }
    $python=@($python|Sort-Object -Unique);$config=@($config|Sort-Object -Unique)
    if($python.Count -ne 1 -or $config.Count -ne 1){throw 'Collector tasks use different Python or configuration paths.'}
    @{pythonPath=$python[0];configPath=$config[0]}
}

function Invoke-PinnedJobAccessPreflight {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][ValidateSet('web-options','web-portfolio')][string]$App,
        [Parameter(Mandatory)][object[]]$Tasks,[Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$Id,[int]$TimeoutSeconds=180)
    $paths=Get-PinnedJobAccessParameters $Tasks
    $operation=Join-Path (Get-DeploymentRemotePath jimbrownhome1 'C:\ProgramData\SolutionDeploy\control\collector-access') "release-$Id"
    $remoteOperation=Join-Path 'C:\ProgramData\SolutionDeploy\control\collector-access' "release-$Id"
    Invoke-DeploymentFileOperation CreateDirectory @($operation)|Out-Null
    $runner=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Invoke-PinnedJobPreflight.ps1'
    $module=Join-Path $PSScriptRoot 'CollectorAccess.psm1'
    Copy-Item -LiteralPath $runner -Destination (Join-Path $operation 'runner.ps1')
    Copy-Item -LiteralPath $module -Destination (Join-Path $operation 'CollectorAccess.psm1')
    $request=@{app=$App;releasePath=$ReleasePath;pythonPath=$paths.pythonPath;configPath=$paths.configPath
        runnerSHA256=(Get-FileHash -LiteralPath $runner).Hash.ToLowerInvariant()
        helperSHA256=(Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Test-CollectorAccess.ps1')).Hash.ToLowerInvariant()
        moduleSHA256=(Get-FileHash -LiteralPath $module).Hash.ToLowerInvariant()
        timeoutSeconds=[Math]::Max(10,[Math]::Min(150,$TimeoutSeconds-10))}
    $requestPath=Join-Path $operation 'request.json'
    Write-DeploymentJson $requestPath $request -CreateNew
    $hash=(Get-FileHash -LiteralPath $requestPath).Hash.ToLowerInvariant()
    $success=$false
    try{
        $result=Invoke-ReleaseHostPhase -Session $Session -Label "$App collector access" -Operation $operation `
            -RemoteOperation $remoteOperation -RequestSHA256 $hash -Phase Prepare -TimeoutSeconds $TimeoutSeconds `
            -ProgressPath (Join-Path $operation 'progress')
        if($result.sid -ne 'S-1-5-19'){throw 'Collector preflight returned an unexpected identity.'}
        $success=$true
        return $result
    }finally{
        if($success){Remove-Item -LiteralPath $operation -Recurse -Force}
    }
}

function Set-VerifiedPinnedJobActions {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$App,[Parameter(Mandatory)][object[]]$Tasks,
        [Parameter(Mandatory)]$Current,[Parameter(Mandatory)][string]$ReleasePath,[Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$Id,[int]$TimeoutSeconds=180)
    $Receipt.access=Invoke-PinnedJobAccessPreflight -Session $Session -App $App -Tasks $Tasks `
        -ReleasePath $ReleasePath -Id $Id -TimeoutSeconds $TimeoutSeconds
    foreach($task in $Tasks){
        Set-PinnedJobTaskAction $Session $task.TaskName (New-PinnedJobAction $task.Actions[0] $Current.path $ReleasePath)
        $Receipt.repointed+=$task.TaskName
    }
}

function Wait-PinnedJobRuns {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][object[]]$Tasks,[Parameter(Mandatory)][datetime]$Since,[int]$TimeoutSeconds=180)
    $results=@{}
    $repeating=@($Tasks|Where-Object {@($_.Triggers|Where-Object {$_.Repetition -and $_.Repetition.Interval}).Count})
    foreach($task in @($Tasks|Where-Object {$_ -notin $repeating})){
        $info=Get-ScheduledTaskInfo -CimSession $Session -TaskPath $script:TaskPath -TaskName $task.TaskName
        $results[$task.TaskName]="Repointed; next run $($info.NextRunTime.ToString('MM/dd/yyyy HH:mm'))"
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds){
        $pending=@($repeating|Where-Object {-not $results.ContainsKey($_.TaskName)})
        if(-not $pending.Count){break}
        foreach($task in $pending){
            $info=Get-ScheduledTaskInfo -CimSession $Session -TaskPath $script:TaskPath -TaskName $task.TaskName
            if($info.LastRunTime -gt $Since -and $info.LastTaskResult -ne 0x41301){
                if($info.LastTaskResult -ne 0){throw "$($task.TaskName) ran on the new release and returned 0x$('{0:x}' -f $info.LastTaskResult)."}
                $results[$task.TaskName]="Ran $($info.LastRunTime.ToString('HH:mm:ss')), result 0"
            }
        }
        Write-Host ("Waiting for {0} job run(s) on the new release: elapsed {1:n0}s." -f $pending.Count,$clock.Elapsed.TotalSeconds)
        Start-Sleep -Seconds 10
    }
    foreach($task in @($repeating|Where-Object {-not $results.ContainsKey($_.TaskName)})){
        $results[$task.TaskName]='Repointed; no completed run within the wait'
    }
    $results
}

function Invoke-PinnedJobRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$App,[Parameter(Mandatory)][hashtable]$Entry,[Parameter(Mandatory)][string]$Component,
        [string]$Commit='HEAD',[Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$ApprovalReason,
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'),[int]$TimeoutSeconds=300)
    $job=$Entry['jobs'][$Component]
    if(-not $job){throw "No pinned-job entry for $App $Component."}
    $commitId=Resolve-CommonReleaseSource $Repository $Commit
    $git=(Get-Command git -CommandType Application).Source
    $sourcePaths=@($job.paths.Keys)
    $remote=Join-Path $script:HostShareRoot $App
    Invoke-DeploymentFileOperation CreateDirectory @((Join-Path $remote 'state'))|Out-Null
    $lock=Get-DeploymentLock (Join-Path $remote 'state\common-controller.lock')
    $id=[guid]::NewGuid().ToString('N')
    $directory=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "releases\$App-$Component-$id"
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $receiptPath=Join-Path $directory 'release.json'
    $receipt=@{app=$App;component=$Component;sourceCommit=$commitId;status='Preparing';startedLocal=(Get-Date).ToString('o');reason=$ApprovalReason}
    $session=$null
    $worktrees=@()
    try{
        $session=New-DeploymentSession -ComputerName jimbrownhome1.local -OperationTimeoutSec 30
        $tasks=Get-PinnedJobTasks $session @($job.tasks)
        $current=Get-PinnedJobReleasePath $App $job $tasks
        foreach($task in $tasks){
            if($task.Actions[0].Arguments -notlike "*\runtime\$($job.runtime)\Scripts\python.exe*"){throw "$($task.TaskName) does not use the recorded Python runtime $($job.runtime)."}
        }
        $baseline=Invoke-DeploymentCommand $git @('rev-parse','--verify',($current.short+'^{commit}')) $Repository -Capture
        if($baseline -cnotmatch '^[a-f0-9]{40}$' -or -not $baseline.StartsWith($current.short)){throw "Cannot resolve installed $Component release $($current.name) to one commit."}
        $receipt.previousRelease=$current.name;$receipt.baselineCommit=$baseline
        $installed=Join-Path $remote "releases\$($current.name)"
        $baseTree=Join-Path $directory 'baseline-worktree'
        $worktrees+=$baseTree
        New-ReleaseWorktree $Repository $baseline $baseTree
        $expected=Join-Path $directory 'baseline'
        Copy-PinnedJobSource $baseTree $job.paths $expected
        $drift=@(Compare-PinnedJobTree (Get-PinnedJobTree $expected) (Get-PinnedJobTree $installed))
        if($drift.Count){throw "Installed $($current.name) differs from commit $($baseline.Substring(0,12)): $(($drift|Select-Object -First 5) -join ', '). Resolve the drift before releasing."}
        if(-not (Get-CommonReleaseChanges $Repository $baseline $commitId $sourcePaths)){
            $receipt.status='NoChanges';$receipt.release=$current.name;$receipt.completedLocal=(Get-Date).ToString('o')
            Write-DeploymentJson $receiptPath $receipt
            return $receipt
        }
        $runtimeCommit=Invoke-DeploymentCommand $git @('rev-parse','--verify',($job.runtimeCommit+'^{commit}')) $Repository -Capture
        if(Get-CommonReleaseChanges $Repository $runtimeCommit $commitId @($job.requirements)){
            throw "$($job.requirements) changed since runtime $($job.runtime) was built. Build and verify a new Python runtime first; tasks unchanged."
        }
        $nextTree=Join-Path $directory 'source-worktree'
        $worktrees+=$nextTree
        New-ReleaseWorktree $Repository $commitId $nextTree
        $built=Join-Path $directory 'build'
        Copy-PinnedJobSource $nextTree $job.paths $built
        $applied=@{}
        if($job['appliedDatabaseInputs']){foreach($item in $job['appliedDatabaseInputs'].GetEnumerator()){$applied[$item.Key]=[string]$item.Value}}
        Assert-HandPlacedDatabaseInputs $built $installed $applied
        $name=$job.prefix+$commitId.Substring(0,[int]$job.shaLength)
        $receipt.release=$name
        $destination=Join-Path $remote "releases\$name"
        $builtTree=Get-PinnedJobTree $built
        if(Test-Path -LiteralPath $destination){
            $existing=@(Compare-PinnedJobTree $builtTree (Get-PinnedJobTree $destination))
            if($existing.Count){throw "$name already exists on the host with different files. Remove or inspect it first."}
        }else{
            Assert-DeploymentLease @($lock)
            $staging="$destination.staging-$($id.Substring(0,8))"
            Copy-Item -LiteralPath $built -Destination $staging -Recurse
            # The releases folder does not grant LOCAL SERVICE; copy the explicit grants from the installed release.
            $acl=Get-Acl -LiteralPath $staging
            foreach($rule in @((Get-Acl -LiteralPath $installed).Access|Where-Object {-not $_.IsInherited})){$acl.AddAccessRule($rule)}
            Set-Acl -LiteralPath $staging -AclObject $acl
            $copied=@(Compare-PinnedJobTree $builtTree (Get-PinnedJobTree $staging))
            if($copied.Count){throw "Staged $name does not match the build: $(($copied|Select-Object -First 5) -join ', ')."}
            Rename-Item -LiteralPath $staging -NewName $name
        }
        $receipt.status='Staged'
        Write-DeploymentJson $receiptPath $receipt
        $hostPath=Join-Path $script:HostAppRoot "$App\releases\$name"
        $before=@{}
        foreach($task in $tasks){$before[$task.TaskName]=@{enabled=$task.Settings.Enabled;user=$task.Principal.UserId;triggers=@($task.Triggers).Count}}
        $since=Get-Date
        $receipt.repointed=@()
        Assert-DeploymentLease @($lock)
        Set-VerifiedPinnedJobActions -Session $session -App $App -Tasks $tasks -Current $current -ReleasePath $hostPath `
            -Receipt $receipt -Id $id -TimeoutSeconds ([Math]::Min(180,$TimeoutSeconds))
        $repointed=$receipt.repointed
        $after=Get-PinnedJobTasks $session @($job.tasks)
        foreach($task in $after){
            $was=$before[$task.TaskName]
            if($task.Actions[0].Arguments -notlike "*`"$hostPath`"*" -or $task.Actions[0].Arguments -like "*`"$($current.path)`"*"){throw "$($task.TaskName) action did not move to $name."}
            if($task.Settings.Enabled -ne $was.enabled -or $task.Principal.UserId -ne $was.user -or @($task.Triggers).Count -ne $was.triggers){
                throw "$($task.TaskName) changed more than its action."
            }
        }
        Assert-DeploymentLease @($lock)
        Write-DeploymentJson (Join-Path $remote "state\job-$Component.json") @{app=$App;component=$Component;sourceCommit=$commitId
            release=$name;previousRelease=$current.name;tasks=$repointed;completedLocal=(Get-Date).ToString('o')}
        $receipt.status='Repointed'
        Write-DeploymentJson $receiptPath $receipt
        $receipt.runs=Wait-PinnedJobRuns $session $after $since $TimeoutSeconds
        $receipt.status='Succeeded';$receipt.completedLocal=(Get-Date).ToString('o')
        Write-DeploymentJson $receiptPath $receipt
        $receipt
    }catch{
        $wasRepointed=$receipt.status -eq 'Repointed'
        $receipt.status='Failed';$receipt.error=$_.Exception.Message
        if($receipt.ContainsKey('repointed') -and @($receipt.repointed).Count -and -not $wasRepointed){
            $restored=@()
            foreach($task in @($tasks|Where-Object {$_.TaskName -in @($receipt.repointed)})){
                try{Assert-DeploymentLease @($lock);Set-PinnedJobTaskAction $session $task.TaskName (New-PinnedJobAction $task.Actions[0] $current.path $current.path);$restored+=$task.TaskName}catch{}
            }
            $receipt.restored=$restored
            $receipt.repointed=@($receipt.repointed|Where-Object {$_ -notin $restored})
        }
        if($receipt.ContainsKey('repointed') -and @($receipt.repointed).Count){
            $receipt.recovery="$(@($receipt.repointed) -join ', ') now point at $($receipt.release). The previous release $($receipt.previousRelease) is kept; repoint by hand after checking what the new code wrote."
        }
        Write-DeploymentJson $receiptPath $receipt
        throw
    }finally{
        foreach($tree in $worktrees){Remove-ReleaseWorktree $Repository $tree}
        foreach($folder in 'baseline','build'){
            $path=Join-Path $directory $folder
            if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}
        }
        if($session){Close-DeploymentSession $session}
        $lock.Dispose()
    }
}

Export-ModuleMember -Function Get-PinnedJobTree,Compare-PinnedJobTree,Copy-PinnedJobSource,Get-PinnedJobReleasePath,New-PinnedJobAction,Get-PinnedJobAccessParameters,Invoke-PinnedJobAccessPreflight,Set-VerifiedPinnedJobActions,Wait-PinnedJobRuns,Invoke-PinnedJobRelease
