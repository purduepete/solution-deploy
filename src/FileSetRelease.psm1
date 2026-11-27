#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CommonRelease.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'HandPlacedRelease.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SshTransport.psm1') -DisableNameChecking

$script:Share=(Get-DeploymentRemotePath jimbrownhome1 'C:\').TrimEnd('\')
$script:Lock=Get-DeploymentRemotePath jimbrownhome1 'C:\ProgramData\SolutionDeploy\apps\solution-deploy\state\common-controller.lock'
$script:Target='^C:\\ProgramData\\(SolutionDeploy|JimlerTech\\PostgreSQL)(\\[A-Za-z0-9_.-]+)+$'
$script:LanProxy='C:\ProgramData\SolutionDeploy\apps\lan-proxy'
# Processes that share an app's folder but are not its web service; a restart must never stop them.
$script:NonWebProcess='telegram_ingest|Run-TelegramPull'

function Get-FileSetPlan {
    param([Parameter(Mandatory)][hashtable]$Entry,[Parameter(Mandatory)][string]$Component)
    if(-not $Entry.ContainsKey('fileSets') -or -not $Entry.fileSets.ContainsKey($Component)){throw "No file set for $Component."}
    $set=$Entry.fileSets[$Component]
    $allowed=@($Entry.componentPaths[$Component])
    $files=@(foreach($file in $set.files){
        if($file.source -notin $allowed){throw "$Component source $($file.source) is outside its component paths."}
        foreach($target in @($file.targets)){
            if($target -notmatch $script:Target -or $target -match '\\\.\.?(\\|$)'){throw "$Component target $target is not an allowed host path."}
            @{source=[string]$file.source;target=[string]$target;share=$script:Share+$target.Substring(2)}
        }
    })
    if(-not $files.Count){throw "$Component file set is empty."}
    if($set.after.type -notin @('none','next-run','lan-proxy','restart-apps')){throw "$Component has an unknown after step."}
    @{component=$Component;files=$files;after=$set.after}
}

function Compare-FileSet {
    param([Parameter(Mandatory)][object[]]$Files,[Parameter(Mandatory)][string]$Source)
    @($Files|Where-Object {
        -not (Test-Path -LiteralPath $_.share -PathType Leaf) -or
            (Get-NormalizedFileDigest $_.share) -ne (Get-NormalizedFileDigest (Join-Path $Source $_.source))
    })
}

function Get-FileSetFenceTasks {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Inventory)
    $names=@(switch($Plan.after.type){
        'next-run'{$Plan.after.task}
        'lan-proxy'{'SolutionDeploy-lan-proxy'}
        'restart-apps'{
            foreach($app in @($Plan.after.apps)){
                if(-not $Inventory.ContainsKey($app)){throw "No inventory entry for $app; cannot fence its web task."}
                $Inventory[$app].task
            }
        }
    })
    if($Plan.component -eq 'postgres-backup'){$names+='PostgreSQL-Backup'}
    @($names|Where-Object {$_}|Select-Object -Unique)
}

# The fence records each task only after disabling succeeds, so tasksLeftFenced never lists a task that stayed enabled.
function Suspend-FileSetTask {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][hashtable]$Fence)
    $task=Get-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName $Name
    $wasEnabled=[bool]$task.Settings.Enabled
    if($wasEnabled){Disable-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName $Name|Out-Null}
    $Fence[$Name]=$wasEnabled
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while((Get-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName $Name).State -eq 'Running'){
        if($clock.Elapsed.TotalSeconds -gt 60){throw "$Name is still running after 60 s; its files were not replaced."}
        Start-Sleep -Seconds 2
    }
}

# Each name is added to $Resumed as soon as its task is enabled, so a failure midway knows exactly which tasks run again.
function Resume-FileSetTasks {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][hashtable]$Fence,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Resumed)
    foreach($name in @($Fence.Keys)){
        if($Fence[$name]){
            Enable-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName $name|Out-Null
            $Resumed.Add($name)
        }
        $Fence.Remove($name)
    }
}

# Writes beside the target and renames over it, so a reader never sees a half-written file.
# The rename drops the old ACL, so the captured ACL is put back on the new file.
function Replace-FileSetFile {
    param([Parameter(Mandatory)][string]$Share,[Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)][string]$Temporary,$Acl)
    Invoke-DeploymentFileOperation WriteAllBytes @($Temporary,$Bytes)
    try{Invoke-DeploymentFileOperation Move @($Temporary,$Share,$true)}
    finally{if(Test-Path -LiteralPath $Temporary){Remove-Item -LiteralPath $Temporary -Force -ErrorAction SilentlyContinue}}
    if($Acl){Set-Acl -LiteralPath $Share -AclObject $Acl}
}

function Restore-FileSetFiles {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Previous,[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Created)
    $failed=[Collections.Generic.List[string]]::new()
    foreach($item in $Previous){
        try{Replace-FileSetFile -Share $item.share -Bytes ([IO.File]::ReadAllBytes($item.backup)) `
            -Temporary ($item.share+'.tmp-rollback-'+[guid]::NewGuid().ToString('N').Substring(0,8)) -Acl $item.acl}
        catch{$failed.Add($item.share)}
    }
    foreach($share in $Created){
        try{if(Test-Path -LiteralPath $share -PathType Leaf){Invoke-DeploymentFileOperation Delete @($share)}}
        catch{$failed.Add($share)}
    }
    @($failed)
}

# A process belongs to an app only when it runs from that app's current release or its launcher, and never when it is a Telegram pull.
function Test-FileSetAppProcess {
    param([Parameter(Mandatory)][string]$App,[Parameter(Mandatory)]$Process)
    $text=[string]$Process.CommandLine+"`n"+[string]$Process.ExecutablePath
    $escaped=[regex]::Escape($App)
    $currentPath='\\apps\\'+$escaped+'\\current\\'
    $launcher='\\apps\\'+$escaped+'\\shared\\Start-Service\.ps1"?\s+-Application\s+'+$escaped+'\s*$'
    ($text -match $currentPath -or $text -match $launcher) -and $text -notmatch $script:NonWebProcess
}

function Get-FileSetWebProcesses {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$App,[Parameter(Mandatory)][hashtable]$AppEntry)
    $launcher=[regex]::Escape("\apps\$App\shared\Start-Service.ps1")+'"?\s+-Application\s+'+[regex]::Escape($App)+'\s*$'
    $processes=@(Get-CimInstance -CimSession $Session -ClassName Win32_Process)
    $selected=@{}
    foreach($process in @($processes|Where-Object {[string]$_.CommandLine -match $launcher})){$selected[[int]$process.ProcessId]=$process}
    $owners=@(Get-NetTCPConnection -CimSession $Session -LocalPort $AppEntry.originPort -State Listen -ErrorAction SilentlyContinue|
        Where-Object {$_.OwningProcess -ne 4 -and $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::')}|
        ForEach-Object {[int]$_.OwningProcess}|Select-Object -Unique)
    foreach($ownerId in $owners){
        $owner=$processes|Where-Object {[int]$_.ProcessId -eq $ownerId}|Select-Object -First 1
        if(-not $owner){continue}
        if(-not (Test-FileSetAppProcess $App $owner)){
            throw "Refusing to terminate unknown process PID $ownerId owning port $($AppEntry.originPort) while restarting $App."
        }
        $selected[$ownerId]=$owner
        $parent=$processes|Where-Object {[int]$_.ProcessId -eq [int]$owner.ParentProcessId}|Select-Object -First 1
        if($parent -and [string]$parent.CommandLine -match $launcher){$selected[[int]$parent.ProcessId]=$parent}
    }
    # Portfolio's Telegram pulls share the app's folder but are not part of its web service.
    @($selected.Values|Where-Object {[string]$_.CommandLine -notmatch $script:NonWebProcess})
}

function Restart-FileSetApp {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$App,[Parameter(Mandatory)][hashtable]$AppEntry)
    Stop-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName $AppEntry.task
    Start-Sleep -Seconds 2
    foreach($process in @(Get-FileSetWebProcesses $Session $App $AppEntry)){
        Invoke-CimMethod -InputObject $process -MethodName Terminate|Out-Null
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(@(Get-NetTCPConnection -CimSession $Session -LocalPort $AppEntry.originPort -State Listen -ErrorAction SilentlyContinue|
        Where-Object {$_.OwningProcess -ne 4 -and $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::')}).Count){
        if($clock.Elapsed.TotalSeconds -gt 60){throw "$App still holds port $($AppEntry.originPort) after the stop."}
        Start-Sleep -Seconds 1
    }
    Start-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName $AppEntry.task
    Test-HandPlacedReadiness (Get-SiteAccess $App) $AppEntry.readiness
}

function Restart-FileSetLanProxy {
    param([Parameter(Mandatory)]$Session)
    $pidFile="$script:Share$($script:LanProxy.Substring(2))\logs\server.pid"
    $old=if(Test-Path -LiteralPath $pidFile){[int](Get-Content -LiteralPath $pidFile -Raw)}else{0}
    if($old){
        $process=Get-CimInstance -CimSession $Session -ClassName Win32_Process -Filter "ProcessId=$old"
        if($process -and [string]$process.CommandLine -match 'lan-proxy\.mjs'){Invoke-CimMethod -InputObject $process -MethodName Terminate|Out-Null}
    }
    Start-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-lan-proxy'
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{
        Start-Sleep -Seconds 2
        $new=if(Test-Path -LiteralPath $pidFile){[int](Get-Content -LiteralPath $pidFile -Raw)}else{0}
        if($new -and $new -ne $old){
            try{
                $status=(Invoke-WebRequest 'http://192.168.2.14:8798/' -TimeoutSec 5 -UseBasicParsing).StatusCode
                if($status -eq 200){return @{pid=$new;lanStatus=$status}}
            }catch{}
        }
    }while($clock.Elapsed.TotalSeconds -lt 60)
    throw 'The LAN proxy did not come back on http://192.168.2.14:8798/ within 60 s.'
}

function Wait-FileSetNextRun {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$Task,[Parameter(Mandatory)][datetime]$After)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{
        Start-Sleep -Seconds 5
        $info=Get-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName $Task|Get-ScheduledTaskInfo
        $state=(Get-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName $Task).State
        if($info.LastRunTime -gt $After -and $state -ne 'Running'){
            if($info.LastTaskResult -ne 0){throw "$Task ran with the new files and returned $($info.LastTaskResult)."}
            return @{task=$Task;lastRunLocal=$info.LastRunTime.ToString('o');result=0}
        }
        Write-Host ("Waiting for {0} to run: elapsed {1:n0}s." -f $Task,$clock.Elapsed.TotalSeconds)
    }while($clock.Elapsed.TotalSeconds -lt 150)
    throw "$Task did not complete a run within 150 s of the copy."
}

function Invoke-FileSetRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][hashtable]$Entry,[Parameter(Mandatory)][string[]]$Component,
        [string]$Commit='HEAD',[Parameter(Mandatory)][string]$ApprovalReason,
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'),
        [DateTimeOffset]$ExpiresLocal=([DateTimeOffset]::Now.AddMinutes(60)))
    Assert-ReleaseConsentCurrent $ExpiresLocal
    $commitId=Resolve-CommonReleaseSource $Repository $Commit
    $plans=@(foreach($name in $Component){Get-FileSetPlan $Entry $name})
    $inventory=(Read-DeploymentJson (Join-Path (Split-Path -Parent $PSScriptRoot) 'environments\releases.json')).apps
    $id=[guid]::NewGuid().ToString('N')
    $directory=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "releases\solution-deploy-files-$id"
    $source=Join-Path $directory 'source'
    [IO.Directory]::CreateDirectory($source)|Out-Null
    $receiptPath=Join-Path $directory 'release.json'
    $receipt=@{app='solution-deploy';component=$Component;sourceCommit=$commitId;status='Preparing';startedLocal=(Get-Date).ToString('o');reason=$ApprovalReason}
    $lock=Get-DeploymentLock $script:Lock
    $session=$null
    $fence=@{}
    $fencedNames=@()
    $previous=[Collections.Generic.List[hashtable]]::new()
    $created=[Collections.Generic.List[string]]::new()
    $copying=$false
    # Tasks added here run again; a later failure must fence each of them again before any rollback.
    $resumedTasks=[Collections.Generic.List[string]]::new()
    $lanRestarted=$false
    $restartedApps=[Collections.Generic.List[string]]::new()
    $rollbackFailed=$false
    try{
        $zip=Join-Path $directory 'source.zip'
        $git=(Get-Command git -CommandType Application).Source
        $paths=@($plans|ForEach-Object {$_.files.source}|Select-Object -Unique)
        Invoke-DeploymentCommand $git (@('archive','--format=zip','-o',$zip,$commitId,'--')+$paths) $Repository
        Expand-Archive -LiteralPath $zip -DestinationPath $source
        $changed=@(foreach($plan in $plans){Compare-FileSet $plan.files $source})
        $receipt.changed=@($changed|ForEach-Object {$_.target})
        if(-not $changed.Count){
            $receipt.status='NoChanges';$receipt.completedLocal=(Get-Date).ToString('o')
            Write-DeploymentJson $receiptPath $receipt
            return $receipt
        }
        $changedPlans=@(foreach($plan in $plans){
            $targets=@($plan.files|ForEach-Object {$_.target})
            if(@($changed|Where-Object {$_.target -in $targets}).Count){$plan}
        })
        if(@($changedPlans|Where-Object {$_.component -eq 'postgres-backup'}).Count){
            $pinFile="$script:Share\ProgramData\JimlerTech\PostgreSQL\cluster-id.txt"
            if(-not (Test-Path -LiteralPath $pinFile -PathType Leaf)){
                throw 'PostgreSQL cluster ID is not pinned at C:\ProgramData\JimlerTech\PostgreSQL\cluster-id.txt. Pin it before releasing the guarded backup script.'
            }
            $pinnedId=(Invoke-DeploymentFileOperation ReadAllText @($pinFile)).Trim()
            if($pinnedId -notmatch '^\d{10,30}$'){
                throw "PostgreSQL cluster ID pin at C:\ProgramData\JimlerTech\PostgreSQL\cluster-id.txt is malformed ('$pinnedId')."
            }
            $liveId=[string](Invoke-DeploymentSsh jimbrownhome1 {
                param($passFile)
                $env:PGPASSFILE=$passFile
                $out=& 'C:\Program Files\PostgreSQL\18\bin\psql.exe' -X -qAt -w -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'SELECT system_identifier FROM pg_control_system();'
                if($LASTEXITCODE -ne 0){throw 'Could not query live PostgreSQL system_identifier.'}
                ($out -join "`n").Trim()
            } @('C:\ProgramData\JimlerTech\PostgreSQL\postgres.pgpass') -TimeoutSeconds 30)
            if($liveId -cne $pinnedId){
                throw "PostgreSQL cluster ID pin '$pinnedId' does not match live cluster '$liveId'."
            }
        }
        $session=New-DeploymentSession -ComputerName jimbrownhome1.local -OperationTimeoutSec 30
        # Tasks that read the changed files stay off while they are replaced, so none runs half-copied or mid-run.
        Assert-ReleaseConsentCurrent $ExpiresLocal
        Assert-DeploymentLease @($lock)
        $fencedNames=@($changedPlans|ForEach-Object {Get-FileSetFenceTasks $_ $inventory}|Select-Object -Unique)
        foreach($name in $fencedNames){Suspend-FileSetTask $session $name $fence}
        # Keep the replaced files with the receipt; a failed release restores them from here.
        $previousDirectory=Join-Path $directory 'previous'
        [IO.Directory]::CreateDirectory($previousDirectory)|Out-Null
        $index=0
        foreach($file in $changed){
            $index++
            if(Test-Path -LiteralPath $file.share -PathType Leaf){
                $backup=Join-Path $previousDirectory "$index-$(Split-Path -Leaf $file.target)"
                Copy-Item -LiteralPath $file.share -Destination $backup
                $previous.Add(@{share=$file.share;target=$file.target;backup=$backup;acl=(Get-Acl -LiteralPath $file.share)})
            }else{$created.Add($file.share)}
        }
        $receipt.previousFiles=$previousDirectory
        $receipt.status='Copying'
        Write-DeploymentJson $receiptPath $receipt
        $copied=Get-Date
        $copying=$true
        foreach($file in $changed){
            Assert-DeploymentLease @($lock)
            Assert-ReleaseConsentCurrent $ExpiresLocal
            $acl=$null
            $old=$previous|Where-Object {$_.share -eq $file.share}|Select-Object -First 1
            if($old){$acl=$old.acl}
            Replace-FileSetFile -Share $file.share -Bytes ([IO.File]::ReadAllBytes((Join-Path $source $file.source))) `
                -Temporary ($file.share+".tmp-$($id.Substring(0,8))") -Acl $acl
        }
        $left=@(foreach($plan in $plans){Compare-FileSet $plan.files $source})
        if($left.Count){throw "Installed files still differ from $commitId after the copy: $(@($left|ForEach-Object {$_.target}) -join ', ')."}
        Resume-FileSetTasks $session $fence $resumedTasks
        $receipt.status='Checking'
        Write-DeploymentJson $receiptPath $receipt
        $checks=@{}
        foreach($plan in $changedPlans){
            $checks[$plan.component]=switch($plan.after.type){
                'none'{@{result='copied; runs at its next schedule'}}
                'next-run'{Wait-FileSetNextRun $session $plan.after.task $copied}
                'lan-proxy'{
                    Assert-ReleaseConsentCurrent $ExpiresLocal;Assert-DeploymentLease @($lock)
                    $lanRestarted=$true
                    Restart-FileSetLanProxy $session
                }
                'restart-apps'{
                    $apps=@{}
                    foreach($app in @($plan.after.apps)){
                        Write-Host "Restarting $app on the new launcher."
                        Assert-ReleaseConsentCurrent $ExpiresLocal
                        Assert-DeploymentLease @($lock)
                        $restartedApps.Add($app)
                        $apps[$app]=Restart-FileSetApp $session $app $inventory[$app]
                    }
                    $apps
                }
            }
        }
        $receipt.checks=$checks
        $receipt.status='Succeeded';$receipt.completedLocal=(Get-Date).ToString('o')
        Write-DeploymentJson $receiptPath $receipt
        $receipt
    }catch{
        $failure=$_
        $receipt.status='Failed';$receipt.error=$failure.Exception.Message
        if($copying){
            $rollbackErrors=[Collections.Generic.List[string]]::new()
            $failedFenceTasks=[Collections.Generic.List[string]]::new()
            try{
                # Tasks that already ran again are fenced before the old files go back; attempt every task so one failure does not leave others running.
                if($resumedTasks.Count -gt 0){
                    foreach($name in @($resumedTasks)){
                        $fence.Remove($name)
                        try{
                            Suspend-FileSetTask $session $name $fence
                            $resumedTasks.Remove($name)|Out-Null
                        }catch{
                            $failedFenceTasks.Add($name)
                            $rollbackErrors.Add("could not re-fence $name`: $($_.Exception.Message)")
                        }
                    }
                }
                if($rollbackErrors.Count -eq 0){
                    foreach($share in @(Restore-FileSetFiles @($previous) @($created))){$rollbackErrors.Add("could not restore $share")}
                    foreach($item in $previous){
                        if(-not (Test-Path -LiteralPath $item.share -PathType Leaf) -or
                            (Get-NormalizedFileDigest $item.share) -ne (Get-NormalizedFileDigest $item.backup)){
                            $rollbackErrors.Add("$($item.share) does not match its backup after the restore")
                        }
                    }
                    foreach($share in $created){
                        if(Test-Path -LiteralPath $share -PathType Leaf){$rollbackErrors.Add("$share was not removed")}
                    }
                }
                $receipt.rolledBack=$rollbackErrors.Count -eq 0
                if($receipt.rolledBack -and ($lanRestarted -or $restartedApps.Count)){
                    # The restored files are the old release, so the tasks can run again before their restarts.
                    Resume-FileSetTasks $session $fence $resumedTasks
                    if($lanRestarted){Restart-FileSetLanProxy $session|Out-Null}
                    foreach($app in $restartedApps){Restart-FileSetApp $session $app $inventory[$app]|Out-Null}
                }
            }catch{$rollbackErrors.Add("rollback: $($_.Exception.Message)")}
            if($rollbackErrors.Count){
                $rollbackFailed=$true
                $receipt.rolledBack=$false
                $receipt.rollbackFailures=@($rollbackErrors)
                $fencedConfirmed=@($fence.Keys|Where-Object {$fence[$_]})
                if($fencedConfirmed.Count){$receipt.tasksLeftFenced=$fencedConfirmed}
                if($failedFenceTasks.Count){$receipt.tasksFailedToFence=@($failedFenceTasks)}
            }
        }
        Write-DeploymentJson $receiptPath $receipt
        throw $failure
    }finally{
        if($fence.Count -and $session -and -not $rollbackFailed){
            try{Resume-FileSetTasks $session $fence ([Collections.Generic.List[string]]::new())}
            catch{Write-Warning "Could not re-enable the fenced tasks $($fence.Keys -join ', '): $($_.Exception.Message)"}
        }
        if($session){Close-DeploymentSession $session}
        $lock.Dispose()
    }
}


Export-ModuleMember -Function Get-FileSetPlan,Compare-FileSet,Invoke-FileSetRelease
