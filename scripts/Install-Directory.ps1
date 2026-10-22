[CmdletBinding()]
param(
    [string]$SourcePath=(Split-Path -Parent $PSScriptRoot),
    [string]$NodePath='C:\Files\ScoopApps\apps\nodejs\current\node.exe',
    [string]$PowerShellPath='C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'
)
$ErrorActionPreference='Stop'
$root='C:\ProgramData\SolutionDeploy\apps\solution-deploy'
$entry="$root\site\server.mjs"
if(-not(Test-Path "$SourcePath\site\sites.json") -or -not(Test-Path $NodePath) -or -not(Test-Path -LiteralPath $PowerShellPath -PathType Leaf)){throw 'Source inventory, Node executable or managed PowerShell runtime is missing.'}
$inventory=Get-Content "$SourcePath\site\sites.json" -Raw|ConvertFrom-Json
if($inventory.host -ne $env:COMPUTERNAME.ToLowerInvariant()){throw 'Install on the inventory host only.'}
$pidFile="$root\logs\server.pid"
$taskName='SolutionDeploy-directory'
$task=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -ErrorAction SilentlyContinue
if($task){
    # Recovery must not restart the old payload while the installer replaces it.
    Disable-ScheduledTask -InputObject $task|Out-Null
    Stop-ScheduledTask -InputObject $task
}
if(Test-Path $pidFile){
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
$listener=Get-NetTCPConnection -State Listen -LocalPort 18798 -ErrorAction SilentlyContinue|Select-Object -First 1
if($listener){
    $owner=Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
    throw "Directory origin port is already in use by PID $($listener.OwningProcess): $($owner.CommandLine)"
}
New-Item -ItemType Directory -Path $root,"$root\site","$root\logs","$root\data" -Force|Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)RX'|Out-Null
if($LASTEXITCODE){throw 'Directory root ACL failed.'}
foreach($folder in "$root\logs","$root\data"){
    & icacls.exe $folder /grant '*S-1-5-19:(OI)(CI)M'|Out-Null
    if($LASTEXITCODE){throw "Directory ACL failed for $folder."}
}
Copy-Item "$SourcePath\site\*" "$root\site" -Force
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
& 'C:\Program Files\Tailscale\tailscale.exe' serve --bg --https=8798 http://127.0.0.1:18798
if($LASTEXITCODE){throw 'Directory Tailscale route failed.'}
$response=Invoke-WebRequest 'https://jimbrownhome1.tail8ad282.ts.net:8798/' -TimeoutSec 20
if($response.StatusCode -ne 200){throw 'Private directory URL failed.'}
for($attempt=0;$attempt -lt 60 -and (Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $statusTask).State -eq 'Running';$attempt++){Start-Sleep -Seconds 1}
$status=Invoke-RestMethod 'http://127.0.0.1:18798/collector-status.json' -TimeoutSec 10
if($status.schemaVersion -ne 1){throw 'Collector status snapshot is missing or invalid.'}
[pscustomobject]@{Host=$env:COMPUTERNAME;Pid=$serverId;Sites=$actual.sites.Count;PrivateStatus=$response.StatusCode;Task=$taskName;StatusRuns=$status.runs.Count;StatusErrors=($status.errors -join '; ')}
