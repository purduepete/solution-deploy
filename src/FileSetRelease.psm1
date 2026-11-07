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

function Restart-FileSetApp {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string]$App,[Parameter(Mandatory)][hashtable]$AppEntry)
    $current=[string](Get-Item -LiteralPath "$script:Share\ProgramData\SolutionDeploy\apps\$App\current" -Force).Target
    $paths=@([regex]::Escape("\apps\$App\current\"))
    if($current){$paths+=[regex]::Escape($current.TrimEnd('\')+'\')}
    $launcher=[regex]::Escape("\apps\$App\shared\Start-Service.ps1")+'"?\s+-Application\s+'+[regex]::Escape($App)+'\s*$'
    Stop-ScheduledTask -CimSession $Session -TaskPath '\JimlerTech\' -TaskName $AppEntry.task
    Start-Sleep -Seconds 2
    foreach($process in @(Get-CimInstance -CimSession $Session -ClassName Win32_Process|Where-Object {
        $command=[string]$_.CommandLine;$text=$command+"`n"+[string]$_.ExecutablePath
        $command -match $launcher -or @($paths|Where-Object {$text -match $_}).Count -gt 0
    })){Invoke-CimMethod -InputObject $process -MethodName Terminate|Out-Null}
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
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'))
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
        $session=New-DeploymentSession -ComputerName jimbrownhome1.local -OperationTimeoutSec 30
        # Keep the replaced files with the receipt; copy them back by hand to roll back.
        $previous=Join-Path $directory 'previous'
        [IO.Directory]::CreateDirectory($previous)|Out-Null
        $index=0
        foreach($file in $changed){
            $index++
            if(Test-Path -LiteralPath $file.share){Copy-Item -LiteralPath $file.share -Destination (Join-Path $previous "$index-$(Split-Path -Leaf $file.target)")}
        }
        $receipt.previousFiles=$previous
        $receipt.status='Copying'
        Write-DeploymentJson $receiptPath $receipt
        $copied=Get-Date
        # Writing in place keeps each installed file's existing ACL.
        foreach($file in $changed){Assert-DeploymentLease @($lock);Invoke-DeploymentFileOperation WriteAllBytes @($file.share,[IO.File]::ReadAllBytes((Join-Path $source $file.source)))}
        $left=@(foreach($plan in $plans){Compare-FileSet $plan.files $source})
        if($left.Count){throw "Installed files still differ from $commitId after the copy: $(@($left|ForEach-Object {$_.target}) -join ', ')."}
        $receipt.status='Checking'
        Write-DeploymentJson $receiptPath $receipt
        $checks=@{}
        foreach($plan in $plans){
            $targets=@($plan.files|ForEach-Object {$_.target})
            if(-not @($changed|Where-Object {$_.target -in $targets}).Count){continue}
            $checks[$plan.component]=switch($plan.after.type){
                'none'{@{result='copied; runs at its next schedule'}}
                'next-run'{Wait-FileSetNextRun $session $plan.after.task $copied}
                'lan-proxy'{Assert-DeploymentLease @($lock);Restart-FileSetLanProxy $session}
                'restart-apps'{
                    $apps=@{}
                    foreach($app in @($plan.after.apps)){
                        Write-Host "Restarting $app on the new launcher."
                        Assert-DeploymentLease @($lock)
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
        $receipt.status='Failed';$receipt.error=$_.Exception.Message
        Write-DeploymentJson $receiptPath $receipt
        throw
    }finally{
        if($session){Close-DeploymentSession $session}
        $lock.Dispose()
    }
}

Export-ModuleMember -Function Get-FileSetPlan,Compare-FileSet,Invoke-FileSetRelease
