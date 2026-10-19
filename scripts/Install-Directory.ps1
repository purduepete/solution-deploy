[CmdletBinding()]
param(
    [string]$SourcePath=(Split-Path -Parent $PSScriptRoot),
    [string]$NodePath='C:\Files\ScoopApps\apps\nodejs\current\node.exe'
)
$ErrorActionPreference='Stop'
$root='C:\ProgramData\SolutionDeploy\apps\solution-deploy'
$entry="$root\site\server.mjs"
if(-not(Test-Path "$SourcePath\site\sites.json") -or -not(Test-Path $NodePath)){throw 'Source inventory or Node executable is missing.'}
$inventory=Get-Content "$SourcePath\site\sites.json" -Raw|ConvertFrom-Json
if($inventory.host -ne $env:COMPUTERNAME.ToLowerInvariant()){throw 'Install on the inventory host only.'}
$pidFile="$root\logs\server.pid"
if(Test-Path $pidFile){
    $serverId=[int](Get-Content $pidFile -Raw)
    $existing=Get-CimInstance Win32_Process -Filter "ProcessId=$serverId"
    if($existing){
        if($existing.ExecutablePath -ne $NodePath -or -not $existing.CommandLine.Contains($entry)){throw 'Recorded PID is not the directory server.'}
        Stop-Process -Id $serverId -Force
        Wait-Process -Id $serverId -Timeout 10 -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $pidFile -Force
}
if(Get-NetTCPConnection -State Listen -LocalPort 18798 -ErrorAction SilentlyContinue){throw 'Directory origin port is already in use.'}
New-Item -ItemType Directory -Path $root,"$root\site","$root\logs" -Force|Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)RX'|Out-Null
if($LASTEXITCODE){throw 'Directory root ACL failed.'}
& icacls.exe "$root\logs" /grant '*S-1-5-19:(OI)(CI)M'|Out-Null
if($LASTEXITCODE){throw 'Directory log ACL failed.'}
Copy-Item "$SourcePath\site\*" "$root\site" -Force
Copy-Item "$SourcePath\scripts\Start-Directory.ps1" "$root\Start-Directory.ps1" -Force
$pwsh=(Get-Process -Id $PID).Path
$action=New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -NonInteractive -File `"$root\Start-Directory.ps1`" -NodePath `"$NodePath`"" -WorkingDirectory $root
$triggers=@(
    New-ScheduledTaskTrigger -AtStartup
    New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
)
$principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-directory' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description 'Read-only solution directory; hidden launcher with five-minute recovery check.' -Force|Out-Null
Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-directory'
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
[pscustomobject]@{Host=$env:COMPUTERNAME;Pid=$serverId;Sites=$actual.sites.Count;PrivateStatus=$response.StatusCode;Task='SolutionDeploy-directory'}
