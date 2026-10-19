[CmdletBinding()]
param(
    [string]$Root='C:\ProgramData\SolutionDeploy\apps\lan-proxy',
    [string]$NodePath='C:\Files\ScoopApps\apps\nodejs\current\node.exe'
)
$ErrorActionPreference='Stop'
$entry=Join-Path $Root 'site\lan-proxy.mjs'
$pidFile=Join-Path $Root 'logs\server.pid'
if(-not(Test-Path -LiteralPath $entry) -or -not(Test-Path -LiteralPath $NodePath)){throw 'LAN proxy payload or Node executable is missing.'}
if(Test-Path -LiteralPath $pidFile){
    $serverId=[int](Get-Content -LiteralPath $pidFile -Raw)
    $existing=Get-CimInstance Win32_Process -Filter "ProcessId=$serverId"
    if($existing){
        $expected='(?i)(?:^|\s)"?'+[regex]::Escape($entry)+'"?(?:\s|$)'
        if($existing.ExecutablePath -eq $NodePath -and $existing.CommandLine -match $expected){return}
        throw 'LAN proxy PID belongs to another process; inspect before restarting.'
    }
    Remove-Item -LiteralPath $pidFile -Force
}
$process=Start-Process -FilePath $NodePath -ArgumentList "`"$entry`"" -WorkingDirectory (Split-Path $entry) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $Root 'logs\stdout.log') -RedirectStandardError (Join-Path $Root 'logs\stderr.log')
$process.Id|Set-Content -LiteralPath $pidFile
Start-Sleep -Seconds 2
$process.Refresh()
if($process.HasExited){
    Remove-Item -LiteralPath $pidFile -Force
    throw "LAN proxy exited with code $($process.ExitCode); inspect logs."
}
