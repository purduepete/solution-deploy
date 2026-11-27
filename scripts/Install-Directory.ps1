[CmdletBinding()]
param(
    [string]$SourcePath=(Split-Path -Parent $PSScriptRoot),
    [string]$NodePath='C:\Program Files\nodejs\node.exe',
    [string]$PowerShellPath='C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe',
    [switch]$PreserveTailscaleRoute,
    # Lets an operator recover a downed directory by skipping the pre-install route health check.
    [switch]$AllowUnhealthyCurrent,
    # Set by the release controller; an installer started after the consent window closes changes nothing.
    [string]$ExpiresLocal
)
$ErrorActionPreference='Stop'
$root='C:\ProgramData\SolutionDeploy\apps\solution-deploy'
$entry="$root\site\server.mjs"
if(-not(Test-Path "$SourcePath\site\sites.json") -or -not(Test-Path "$SourcePath\environments\releases.json") -or -not(Test-Path $NodePath) -or -not(Test-Path -LiteralPath $PowerShellPath -PathType Leaf)){throw 'Source site/release inventory, Node executable or managed PowerShell runtime is missing.'}
$inventory=Get-Content "$SourcePath\site\sites.json" -Raw|ConvertFrom-Json
if($inventory.host -ne $env:COMPUTERNAME.ToLowerInvariant()){throw 'Install on the inventory host only.'}
if($PreserveTailscaleRoute -and -not $AllowUnhealthyCurrent){
    $current=Invoke-RestMethod 'https://jimbrownhome1.tail8ad282.ts.net:8798/health' -TimeoutSec 10
    if($current.status -ne 'ok'){throw 'Existing directory Tailscale route is not ready.'}
}
$pidFile="$root\logs\server.pid"
$taskName='SolutionDeploy-directory'
$task=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -ErrorAction SilentlyContinue

function Assert-ConsentCurrent {
    if($ExpiresLocal -and [DateTimeOffset]::Parse($ExpiresLocal) -le [DateTimeOffset]::Now){throw 'Release consent expired.'}
}

# Stops only the directory server recorded in the PID file; anything else at that PID is refused.
function Stop-RecordedDirectoryServer {
    if(-not(Test-Path $pidFile)){return}
    $serverId=[int](Get-Content $pidFile -Raw)
    $existing=Get-CimInstance Win32_Process -Filter "ProcessId=$serverId"
    if($existing){
        if($existing.ExecutablePath -ne $NodePath -or -not $existing.CommandLine.Contains($entry)){throw 'Recorded PID is not the directory server.'}
        $old=Get-Process -Id $serverId -ErrorAction SilentlyContinue
        if($old){
            $old.Kill()
            if(-not $old.WaitForExit(10000)){throw "Directory PID $serverId did not exit within 10 seconds."}
        }
    }
    Remove-Item -LiteralPath $pidFile -Force
}

function Wait-DirectoryPortReleased {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{
        if(-not(Get-NetTCPConnection -State Listen -LocalPort 18798 -ErrorAction SilentlyContinue)){return}
        Start-Sleep -Seconds 1
    }while($clock.Elapsed.TotalSeconds -lt 10)
    throw 'Directory origin port 18798 is still in use after the stop.'
}

function Wait-DirectoryHealthy {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{
        try{if((Invoke-RestMethod 'http://127.0.0.1:18798/health' -TimeoutSec 5).status -eq 'ok'){return}}catch{}
        Start-Sleep -Seconds 2
    }while($clock.Elapsed.TotalSeconds -lt 30)
    throw 'The restored directory did not report ok on http://127.0.0.1:18798/health within 30 s.'
}

# One host install at a time; the lock is held until this script exits.
New-Item -ItemType Directory -Path "$root\state" -Force|Out-Null
$lock=[IO.File]::Open("$root\state\directory-install.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$rollback=$null
$keepRollback=$false
$snapshotted=@()
$hadPriorInstall=$false
try{
    Assert-ConsentCurrent
    # Keep the installed payload so a failed install can put it back.
    if(Test-Path -LiteralPath "$root\site" -PathType Container){
        $hadPriorInstall=$true
        $rollback="$root\state\rollback-$([guid]::NewGuid().ToString('N'))"
        $managed=@(Get-ChildItem -LiteralPath "$root\site" -File|ForEach-Object {"site\$($_.Name)"})+@('environments\releases.json','Start-Directory.ps1','Update-CollectorStatus.ps1')
        $snapshotted=@($managed|Where-Object {Test-Path -LiteralPath "$root\$_" -PathType Leaf})
        foreach($relative in $snapshotted){
            $copy="$rollback\$relative"
            New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force|Out-Null
            Copy-Item -LiteralPath "$root\$relative" -Destination $copy -Force
        }
    }
    # Consent is checked again right before downtime, since snapshotting can take a while.
    Assert-ConsentCurrent
    $mutated=$false
    try{
$mutated=$true
if($task){
    # Recovery must not restart the old payload while the installer replaces it.
    Disable-ScheduledTask -InputObject $task|Out-Null
    Stop-ScheduledTask -InputObject $task
}
Stop-RecordedDirectoryServer
$listener=Get-NetTCPConnection -State Listen -LocalPort 18798 -ErrorAction SilentlyContinue|Select-Object -First 1
if($listener){
    $owner=Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
    throw "Directory origin port is already in use by PID $($listener.OwningProcess): $($owner.CommandLine)"
}
New-Item -ItemType Directory -Path $root,"$root\site","$root\logs","$root\data","$root\environments" -Force|Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)RX'|Out-Null
if($LASTEXITCODE){throw 'Directory root ACL failed.'}
foreach($folder in "$root\logs","$root\data"){
    & icacls.exe $folder /grant '*S-1-5-19:(OI)(CI)M'|Out-Null
    if($LASTEXITCODE){throw "Directory ACL failed for $folder."}
}
Assert-ConsentCurrent
Copy-Item "$SourcePath\site\*" "$root\site" -Force
Copy-Item "$SourcePath\environments\releases.json" "$root\environments\releases.json" -Force
Copy-Item "$SourcePath\scripts\Start-Directory.ps1" "$root\Start-Directory.ps1" -Force
Copy-Item "$SourcePath\scripts\Update-CollectorStatus.ps1" "$root\Update-CollectorStatus.ps1" -Force
$pwsh=$PowerShellPath
$principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount -RunLevel Limited
$statusTask='SolutionDeploy-collector-status'
$statusAction=New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -NonInteractive -File `"$root\Update-CollectorStatus.ps1`"" -WorkingDirectory $root
$statusTriggers=@(
    New-ScheduledTaskTrigger -AtStartup
    New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
)
$statusSettings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $statusTask -Action $statusAction -Trigger $statusTriggers -Principal $principal -Settings $statusSettings -Description 'Read-only collector run snapshot for the /collectors page.' -Force|Out-Null
Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $statusTask
$action=New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -NonInteractive -File `"$root\Start-Directory.ps1`" -NodePath `"$NodePath`"" -WorkingDirectory $root
$triggers=@(
    New-ScheduledTaskTrigger -AtStartup
    New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
)
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description 'Read-only solution directory; hidden launcher with five-minute recovery check.' -Force|Out-Null
Enable-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName|Out-Null
Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName
for($attempt=0;$attempt -lt 20 -and -not(Test-Path $pidFile);$attempt++){Start-Sleep -Seconds 1}
if(-not(Test-Path $pidFile)){throw 'Directory did not create its PID file.'}
$serverId=[int](Get-Content $pidFile -Raw)
Start-Sleep -Seconds 2
$process=Get-CimInstance Win32_Process -Filter "ProcessId=$serverId"
if(-not $process -or -not $process.CommandLine.Contains($entry)){throw 'Directory payload is not running.'}
$health=Invoke-RestMethod 'http://127.0.0.1:18798/health' -TimeoutSec 10
if($health.status -ne 'ok'){throw 'Directory readiness failed.'}
$actual=Invoke-RestMethod 'http://127.0.0.1:18798/sites.json' -TimeoutSec 10
if(($actual|ConvertTo-Json -Depth 10 -Compress) -cne ($inventory|ConvertTo-Json -Depth 10 -Compress)){throw 'Served inventory differs from source.'}
if(-not $PreserveTailscaleRoute){
    & 'C:\Program Files\Tailscale\tailscale.exe' serve --bg --https=8798 http://127.0.0.1:18798
    if($LASTEXITCODE){throw 'Directory Tailscale route failed.'}
}
$response=Invoke-WebRequest 'https://jimbrownhome1.tail8ad282.ts.net:8798/' -TimeoutSec 20
if($response.StatusCode -ne 200){throw 'Private directory URL failed.'}
for($attempt=0;$attempt -lt 60 -and (Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $statusTask).State -eq 'Running';$attempt++){Start-Sleep -Seconds 1}
$status=Invoke-RestMethod 'http://127.0.0.1:18798/collector-status.json' -TimeoutSec 10
if($status.schemaVersion -ne 1){throw 'Collector status snapshot is missing or invalid.'}
$summary=[pscustomobject]@{Host=$env:COMPUTERNAME;Pid=$serverId;Sites=$actual.sites.Count;PrivateStatus=$response.StatusCode;Task=$taskName;StatusRuns=$status.runs.Count;StatusErrors=($status.errors -join '; ')}
    }catch{
        $failure=$_
        $rollbackError=$null
        if($mutated -and -not $rollback){
            $rollbackError='Installation mutated the host without a prior snapshot; manual verification is required.'
        }elseif($mutated -and $rollback){
            $restored=$false
            $reenable=@()
            try{
                # Scheduled triggers stay off until every file is back, so none can start a half-restored payload.
                $statusRecord=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-collector-status' -ErrorAction SilentlyContinue
                if($statusRecord -and $statusRecord.Settings.Enabled){
                    Disable-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-collector-status'|Out-Null
                    $reenable+='SolutionDeploy-collector-status'
                }
                $currentDirTask=$null
                try{$currentDirTask=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -ErrorAction Stop}
                catch{
                    if($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound -and
                        $_.Exception.Message -notmatch 'No MSFT_ScheduledTask objects found'){throw}
                }
                if($currentDirTask){
                    Disable-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName|Out-Null
                    Stop-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -ErrorAction SilentlyContinue
                    $stopClock=[Diagnostics.Stopwatch]::StartNew()
                    while($stopClock.Elapsed.TotalSeconds -lt 10){
                        $currentDirTask=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -ErrorAction Stop
                        if($currentDirTask.State -ne 'Running'){break}
                        Start-Sleep -Milliseconds 500
                    }
                    $currentDirTask=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -ErrorAction Stop
                    if($currentDirTask.State -eq 'Running'){throw "Task $taskName did not stop within 10 seconds during rollback."}
                }
                Stop-RecordedDirectoryServer
                Wait-DirectoryPortReleased
                foreach($relative in $snapshotted){Copy-Item -LiteralPath "$rollback\$relative" -Destination "$root\$relative" -Force}
                foreach($file in Get-ChildItem -LiteralPath "$root\site" -File){
                    if("site\$($file.Name)" -notin $snapshotted){Remove-Item -LiteralPath $file.FullName -Force}
                }
                $mismatch=@($snapshotted|Where-Object {
                    (Get-FileHash -LiteralPath "$root\$_" -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath "$rollback\$_" -Algorithm SHA256).Hash})
                if($mismatch.Count){throw "Restored files differ from the snapshot: $($mismatch -join ', ')."}
                Remove-Item -LiteralPath $rollback -Recurse -Force
                $rollback=$null
                $restored=$true
            }catch{
                $rollbackError=$_.Exception.Message
                $keepRollback=$true
                Write-Warning "Rollback did not complete; the snapshot is kept in $rollback. $rollbackError"
            }
            if($restored){
                try{
                    foreach($name in $reenable){Enable-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $name|Out-Null}
                }catch{
                    $rollbackError="The restored status task did not re-enable: $($_.Exception.Message)"
                    Write-Warning "Could not re-enable the collector status task after the rollback: $($_.Exception.Message)"
                }
            }
            if($restored -and $task -and -not $rollbackError){
                try{
                    Enable-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName|Out-Null
                    Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName
                    if($hadPriorInstall -and -not $AllowUnhealthyCurrent){Wait-DirectoryHealthy}
                }catch{
                    $rollbackError="The restored directory did not start: $($_.Exception.Message)"
                    Write-Warning "Could not restart ${taskName} after the rollback: $($_.Exception.Message)"
                }
            }
        }
        if($rollbackError){throw "$($failure.Exception.Message) Rollback verification failed: $rollbackError"}
        throw $failure
    }
    $summary
}finally{
    if($rollback -and -not $keepRollback){Remove-Item -LiteralPath $rollback -Recurse -Force -ErrorAction SilentlyContinue}
    $lock.Dispose()
}
