[CmdletBinding()]
param(
    [string]$Root='C:\ProgramData\SolutionDeploy\apps\solution-deploy',
    [string]$NodePath='C:\Files\ScoopApps\apps\nodejs\current\node.exe'
)
$ErrorActionPreference='Stop'
$entry=Join-Path $Root 'site\server.mjs'
$pidFile=Join-Path $Root 'logs\server.pid'
if(Test-Path $pidFile){
    $serverId=[int](Get-Content $pidFile -Raw)
    $existing=Get-CimInstance Win32_Process -Filter "ProcessId=$serverId"
    if($existing -and $existing.ExecutablePath -eq $NodePath -and $existing.CommandLine.Contains($entry)){return}
    if($existing){throw 'Directory PID belongs to a different process; inspect before restarting.'}
}
$env:PORT='18798'
$process=Start-Process -FilePath $NodePath -ArgumentList "`"$entry`"" -WorkingDirectory (Split-Path $entry) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $Root 'logs\stdout.log') -RedirectStandardError (Join-Path $Root 'logs\stderr.log')
$process.Id|Set-Content $pidFile
Start-Sleep -Seconds 2
if($process.HasExited){throw "Directory process exited with code $($process.ExitCode); inspect logs."}
