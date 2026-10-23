[CmdletBinding()]
param(
    [string]$SourcePath=(Split-Path -Parent $PSScriptRoot),
    [string]$NodePath='C:\Files\ScoopApps\apps\nodejs\current\node.exe',
    [string]$PowerShellPath='C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'
)
$ErrorActionPreference='Stop'
$root='C:\ProgramData\SolutionDeploy\apps\lan-proxy'
$entry="$root\site\lan-proxy.mjs"
$pidFile="$root\logs\server.pid"
$address='192.168.2.14'
$ports=@(80,8787,8788,8790,8791,8792,8793,8794,8795,8796,8797,8798,8801)
$taskName='SolutionDeploy-lan-proxy'
if(-not([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw 'Run the installer from an elevated PowerShell terminal.'
}
if(-not(Test-Path "$SourcePath\site\lan-proxy.mjs") -or -not(Test-Path "$SourcePath\scripts\Start-LanProxy.ps1") -or -not(Test-Path $NodePath) -or -not(Test-Path -LiteralPath $PowerShellPath -PathType Leaf)){
    throw 'LAN proxy source, launcher, Node executable or managed PowerShell runtime is missing.'
}
function Resolve-FinalPath([string]$Path){
    $item=Get-Item -LiteralPath $Path -Force
    if($item.LinkType){$Path=$item.ResolveLinkTarget($true).FullName}
    $parent=Split-Path -Parent $Path
    if(-not $parent){return $Path}
    Join-Path (Resolve-FinalPath $parent) (Split-Path -Leaf $Path)
}
# Windows Firewall matches the final image path; Scoop's current folder is a junction.
$firewallProgram=Resolve-FinalPath ([IO.Path]::GetFullPath($NodePath))
if(-not(Test-Path -LiteralPath $firewallProgram -PathType Leaf)){throw "Resolved Node path is invalid: $firewallProgram"}
$ip=Get-NetIPAddress -AddressFamily IPv4 -IPAddress $address
if($ip.InterfaceAlias -ne 'Ethernet'){throw '192.168.2.14 must be assigned to the Ethernet interface.'}
$profile=Get-NetConnectionProfile -InterfaceIndex $ip.InterfaceIndex
if($profile.NetworkCategory -ne 'Private'){throw 'Ethernet must use the Private network profile.'}
$task=Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -ErrorAction SilentlyContinue
if($task){
    Disable-ScheduledTask -InputObject $task|Out-Null
    Stop-ScheduledTask -InputObject $task
}
if(Test-Path -LiteralPath $pidFile){
    $serverId=[int](Get-Content -LiteralPath $pidFile -Raw)
    $existing=Get-CimInstance Win32_Process -Filter "ProcessId=$serverId"
    if($existing){
        $expected='(?i)(?:^|\s)"?'+[regex]::Escape($entry)+'"?(?:\s|$)'
        if($existing.ExecutablePath -ne $NodePath -or $existing.CommandLine -notmatch $expected){throw 'Recorded PID is not the LAN proxy.'}
        $old=Get-Process -Id $serverId -ErrorAction SilentlyContinue
        if($old){
            $old.Kill()
            if(-not $old.WaitForExit(10000)){throw "LAN proxy PID $serverId did not exit within 10 seconds."}
        }
    }
    Remove-Item -LiteralPath $pidFile -Force
}
$collision=Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue|Where-Object {
    $_.LocalPort -in $ports -and $_.LocalAddress -in @($address,'0.0.0.0','::')
}
if($collision){throw 'A requested LAN listener port is already occupied. No unrelated listener was stopped.'}
New-Item -ItemType Directory -Path $root,"$root\site","$root\logs" -Force|Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-19:(OI)(CI)RX'|Out-Null
if($LASTEXITCODE){throw 'LAN proxy root ACL failed.'}
& icacls.exe "$root\logs" /grant:r '*S-1-5-19:(OI)(CI)M'|Out-Null
if($LASTEXITCODE){throw 'LAN proxy log ACL failed.'}
Copy-Item "$SourcePath\site\lan-proxy.mjs" $entry -Force
Copy-Item "$SourcePath\scripts\Start-LanProxy.ps1" "$root\Start-LanProxy.ps1" -Force
$ruleName='SolutionDeploy-LanProxy-Ethernet'
$rule=Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if($rule){Remove-NetFirewallRule -Name $ruleName}
New-NetFirewallRule -Name $ruleName -DisplayName 'SolutionDeploy LAN proxy (Ethernet subnet only)' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ports -LocalAddress $address `
    -RemoteAddress '192.168.2.0/24' -InterfaceAlias 'Ethernet' -Profile Private -Program $firewallProgram -EdgeTraversalPolicy Block|Out-Null
$pwsh=$PowerShellPath
$action=New-ScheduledTaskAction -Execute $pwsh `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\Start-LanProxy.ps1`" -NodePath `"$NodePath`"" -WorkingDirectory $root
$triggers=@(
    New-ScheduledTaskTrigger -AtStartup
    New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
)
$principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Description 'LAN IPv4 proxy; short hidden launcher and five-minute process recovery.' -Force|Out-Null
Enable-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName|Out-Null
Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName
try{
    $process=$null
    for($attempt=0;$attempt -lt 20;$attempt++){
        Start-Sleep -Seconds 1
        if(Test-Path -LiteralPath $pidFile){
            $serverId=[int](Get-Content -LiteralPath $pidFile -Raw)
            $candidate=Get-CimInstance Win32_Process -Filter "ProcessId=$serverId"
            $expected='(?i)(?:^|\s)"?'+[regex]::Escape($entry)+'"?(?:\s|$)'
            if($candidate -and $candidate.ExecutablePath -eq $NodePath -and $candidate.CommandLine -match $expected){
                $bound=@(Get-NetTCPConnection -State Listen -OwningProcess $serverId -ErrorAction SilentlyContinue|Where-Object LocalAddress -eq $address)
                if(@($bound|Where-Object LocalPort -in $ports).Count -eq $ports.Count){$process=$candidate;break}
            }
        }
    }
    if(-not $process){throw 'LAN proxy did not bind every requested port with the expected process identity.'}
    $handler=[System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy=$false
    $handler.AllowAutoRedirect=$false
    $client=[System.Net.Http.HttpClient]::new($handler)
    $client.Timeout=[timespan]::FromSeconds(10)
    try{
        foreach($port in $ports){
            $url="http://${address}:${port}/"
            $response=$client.GetAsync($url,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            try{
                if([int]$response.StatusCode -ge 400){throw "LAN readiness failed at $url with status $([int]$response.StatusCode)."}
                if($port -in @(80,8798) -and [int]$response.StatusCode -ne 200){throw "Directory readiness failed at $url."}
                if($port -eq 8794 -and ($response.StatusCode -ne [System.Net.HttpStatusCode]::Found -or $response.Headers.Location.OriginalString -ne '/app')){throw 'Port 8794 root redirect failed.'}
            }finally{$response.Dispose()}
        }
        $response=$client.GetAsync("http://${address}:8794/app",[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try{if([int]$response.StatusCode -ge 400){throw 'Port 8794 upstream /app readiness failed.'}}finally{$response.Dispose()}
    }finally{$client.Dispose();$handler.Dispose()}
}catch{
    Disable-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName|Out-Null
    Stop-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName
    if($process){
        $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ProcessId)"
        $expected='(?i)(?:^|\s)"?'+[regex]::Escape($entry)+'"?(?:\s|$)'
        if($current -and $current.ExecutablePath -eq $NodePath -and $current.CommandLine -match $expected){
            Stop-Process -Id $process.ProcessId -Force
        }
    }
    throw
}
[pscustomobject]@{Host=$env:COMPUTERNAME;Pid=$serverId;Address=$address;Ports=($ports -join ',');Task=$taskName;FirewallRule=$ruleName;FirewallProgram=$firewallProgram}
