#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# These are logical addresses, never directories, mounts or SMB connections.
$script:RemotePrefix='C:\.solution-deploy-ssh\'
$script:PowerShell='C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'

function Get-DeploymentSshConfiguration {
    param([string]$HostName='jimbrownhome1')
    $name=$HostName -replace '\.local$',''
    if($name -ine 'jimbrownhome1'){throw "SSH is not configured for $HostName."}
    $user=if($env:SOLUTION_DEPLOY_SSH_USER){$env:SOLUTION_DEPLOY_SSH_USER}else{'sd-maintenance'}
    if($user -notmatch '^[A-Za-z0-9_.-]+$'){throw 'Invalid SSH maintenance username.'}
    @{hostName='jimbrownhome1.local';user=$user;powerShell=$script:PowerShell}
}

function Get-DeploymentRemotePath {
    param([Parameter(Mandatory)][string]$HostName,[Parameter(Mandatory)][string]$Path)
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path.Contains("`n") -or $Path.Contains("`r") -or $Path.Contains('"')){
        throw 'Remote paths must be absolute Windows drive paths.'
    }
    $name=$HostName -replace '\.local$',''
    if($env:COMPUTERNAME -ieq $name){return $Path}
    if($name -ieq 'jimbrownhome1'){
        return $script:RemotePrefix+'jimbrownhome1.local\'+$Path.Substring(0,1)+$Path.Substring(2)
    }
    if($name -notmatch '^[A-Za-z0-9-]+$'){throw 'Invalid legacy deployment hostname.'}
    # The older host remains explicitly legacy until its SSH installation is approved.
    '\\'+$name+'.local\'+$Path.Substring(0,1)+'$'+$Path.Substring(2)
}

function Resolve-DeploymentSshPath {
    param([AllowNull()][string]$Path)
    if($Path -and $Path.StartsWith($script:RemotePrefix,[StringComparison]::OrdinalIgnoreCase)){
        if($Path -notmatch '^C:\\\.solution-deploy-ssh\\(jimbrownhome1\.local)\\([A-Za-z])(?:\\(.*))?$'){
            throw 'Invalid logical SSH path.'
        }
        return @{hostName=$Matches[1];path=$Matches[2]+':\'+$Matches[3]}
    }
    # Fail closed if an old callsite tries the new host through an admin share.
    if($Path -match '^\\\\jimbrownhome1(?:\.local)?\\'){throw 'jimbrownhome1 requires a logical SSH path; SMB is forbidden.'}
    $null
}

function New-DeploymentSession {
    param([Parameter(Mandatory)][string]$ComputerName,[int]$OperationTimeoutSec=20)
    $name=$ComputerName -replace '\.local$',''
    if($name -ieq 'jimbrownhome1'){
        $configuration=Get-DeploymentSshConfiguration $ComputerName
        return [pscustomobject]@{DeploymentSsh=$true;ComputerName=$configuration.hostName;OperationTimeoutSec=$OperationTimeoutSec}
    }
    if($name -notmatch '^[A-Za-z0-9-]+$'){throw 'Invalid legacy deployment hostname.'}
    CimCmdlets\New-CimSession -ComputerName ($name+'.local') -SessionOption (CimCmdlets\New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec $OperationTimeoutSec
}

function Close-DeploymentSession {
    param([Parameter(Mandatory,Position=0)]$Session)
    if(-not $Session.PSObject.Properties['DeploymentSsh']){CimCmdlets\Remove-CimSession $Session}
}

function Get-DeploymentSshArguments {
    param([Parameter(Mandatory)][hashtable]$Configuration)
    $arguments=@('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','PreferredAuthentications=publickey',
        '-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','ConnectTimeout=10',
        '-o','ServerAliveInterval=10','-o','ServerAliveCountMax=3')
    if($env:SOLUTION_DEPLOY_SSH_KEY){$arguments+=@('-i',$env:SOLUTION_DEPLOY_SSH_KEY,'-o','IdentitiesOnly=yes')}
    $arguments
}

function New-DeploymentSshStartInfo {
    param([Parameter(Mandatory)][string]$HostName,[Parameter(Mandatory)][string]$Script)
    $configuration=Get-DeploymentSshConfiguration $HostName
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Command ssh.exe -CommandType Application|Select-Object -First 1).Source
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $destination=$configuration.user+'@'+$configuration.hostName
    $remoteCommand='& '''+$configuration.powerShell+''' -NoLogo -NoProfile -NonInteractive -EncodedCommand '+
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    foreach($argument in (Get-DeploymentSshArguments $configuration)+@($destination,$remoteCommand)){
        $start.ArgumentList.Add($argument)
    }
    $start
}

function New-DeploymentSshProcess {
    param([Parameter(Mandatory)][string]$HostName,[Parameter(Mandatory)][string]$Script)
    $process=[Diagnostics.Process]::new();$process.StartInfo=New-DeploymentSshStartInfo $HostName $Script
    if(-not $process.Start()){$process.Dispose();throw 'SSH did not start.'}
    $process
}

function New-DeploymentCopyProcess {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Command scp.exe -CommandType Application|Select-Object -First 1).Source
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    if(-not $process.Start()){$process.Dispose();throw 'SCP did not start.'}
    $process
}

function Invoke-DeploymentSsh {
    param([Parameter(Mandatory)][string]$HostName,[Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList=@(),[int]$TimeoutSeconds=30)
    # Input travels over the encrypted channel, never in the command line (it may contain credentials).
    $script=@'
$ErrorActionPreference='Stop'
try{
    $inputData=[Management.Automation.PSSerializer]::Deserialize([Console]::In.ReadToEnd())
    $arguments=$inputData.arguments
    $result=@(& ([scriptblock]::Create($inputData.script)) @arguments 3>$null 4>$null 5>$null 6>$null)
    [Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($result,40))))
}catch{
    [Console]::Error.Write('Remote command failed. Inspect the protected operation record.')
    exit 1
}
'@
    $process=New-DeploymentSshProcess $HostName $script
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write([Management.Automation.PSSerializer]::Serialize(@{script=$ScriptBlock.ToString();arguments=$ArgumentList},40))
        $process.StandardInput.Close()
        $clock=[Diagnostics.Stopwatch]::StartNew();$next=10
        while(-not $process.WaitForExit(1000)){
            if($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds){
                $process.Kill($true);$process.WaitForExit()
                throw "SSH deadline exceeded after $TimeoutSeconds seconds. Outcome unknown; do not resubmit."
            }
            if($clock.Elapsed.TotalSeconds -ge $next){Write-Host ("SSH command: elapsed {0:n0}s" -f $clock.Elapsed.TotalSeconds);$next+=10}
        }
        if($process.ExitCode -ne 0){throw "SSH failed with exit code $($process.ExitCode). Check key-only access and the trusted host key; remote output withheld."}
        $text=$stdout.GetAwaiter().GetResult().Trim()
        if(-not $text){return}
        [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($text)))
    }finally{$process.Dispose()}
}

function ConvertTo-DeploymentNativeArguments {
    param([Parameter(Mandatory)][hashtable]$Parameters)
    $output=@{}
    foreach($key in $Parameters.Keys){
        $value=$Parameters[$key]
        if($value -is [string]){
            $remote=Resolve-DeploymentSshPath $value
            $output[$key]=if($remote){$remote.path}else{$value}
        }elseif($value -is [string[]]){
            $output[$key]=@($value|ForEach-Object {$remote=Resolve-DeploymentSshPath $_;if($remote){$remote.path}else{$_}})
        }else{$output[$key]=$value}
    }
    $output
}

function Invoke-DeploymentTransportCommand {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][hashtable]$Parameters)
    $session=$Parameters['CimSession']
    if(-not $session -and $Parameters['InputObject']){
        $inputObject=@($Parameters['InputObject'])[0]
        if($inputObject.PSObject.Properties['DeploymentSession']){$session=$inputObject.DeploymentSession}
    }
    $remote=$null
    foreach($key in @('LiteralPath','Path','Destination')){
        foreach($path in @($Parameters[$key])){
            if($path -is [string]){
                $candidate=Resolve-DeploymentSshPath $path
                if($candidate){$remote=$candidate}
            }
        }
    }
    if($Name -eq 'Copy-Item' -and $remote){
        Copy-DeploymentItem @Parameters
        return
    }
    $command=$script:NativeCommands[$Name]
    if(-not $remote -and (-not $session -or -not $session.PSObject.Properties['DeploymentSsh'])){
        & $command @Parameters
        return
    }
    $hostName=if($remote){$remote.hostName}else{$session.ComputerName}
    $native=ConvertTo-DeploymentNativeArguments $Parameters
    $native.Remove('CimSession')|Out-Null
    if($WhatIfPreference -and $command.Parameters.ContainsKey('WhatIf')){$native.WhatIf=$true}
    if($Name -eq 'Set-Acl'){
        $native.AclObject=$native.AclObject.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
    }
    $result=Invoke-DeploymentSsh $hostName {
        param($name,$parameters)
        if($name -eq 'Get-Content' -and $parameters.Raw -and -not $parameters.AsByteStream){
            # Materialize file-provider output before returning across redirected SSH stdin/stdout.
            return [string](Get-Content @parameters)
        }
        if($name -eq 'Get-Acl'){
            return @{directory=(Test-Path -LiteralPath $parameters.LiteralPath -PathType Container);sddl=(Get-Acl @parameters).Sddl}
        }
        if($name -eq 'Set-Acl'){
            $security=if(Test-Path -LiteralPath $parameters.LiteralPath -PathType Container){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
            $security.SetSecurityDescriptorSddlForm($parameters.AclObject);$parameters.AclObject=$security
        }
        if($parameters.ContainsKey('Action')){
            $parameters.Action=@(foreach($action in @($parameters.Action)){
                $args=@{Execute=[string]$action.Execute}
                if($action.Arguments){$args.Argument=[string]$action.Arguments}
                if($action.WorkingDirectory){$args.WorkingDirectory=[string]$action.WorkingDirectory}
                New-ScheduledTaskAction @args
            })
        }
        if($parameters.ContainsKey('InputObject')){
            if($name -eq 'Invoke-CimMethod'){
                $parameters.InputObject=Get-CimInstance Win32_Process -Filter "ProcessId=$($parameters.InputObject.ProcessId)"
                if(-not $parameters.InputObject){throw 'The selected process no longer exists.'}
            }elseif($name -like '*ScheduledTask*'){
                $parameters.TaskName=$parameters.InputObject.TaskName;$parameters.TaskPath=$parameters.InputObject.TaskPath
                $parameters.Remove('InputObject')|Out-Null
            }
        }
        & (Get-Command $name -CommandType Cmdlet,Function|Select-Object -First 1) @parameters
    } @($Name,$native) -TimeoutSeconds $(if($session){$session.OperationTimeoutSec}elseif($Name -eq 'Get-FileHash'){300}else{30})
    foreach($item in @($result)){
        if($null -eq $item){continue}
        if($Name -eq 'Get-Acl'){
            $security=if($item.directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
            $security.SetSecurityDescriptorSddlForm($item.sddl)
            $security
            continue
        }
        if($Name -in @('Get-Item','Get-ChildItem','New-Item')){
            if($item.PSObject.Properties['FullName']){
                $item.FullName=Get-DeploymentRemotePath $hostName ([string]$item.FullName)
                if($item.PSObject.Properties['PSPath']){$item.PSPath=$item.FullName}
            }
        }
        if($session -and $Name -in @('Get-CimInstance','Get-ScheduledTask')){
            $item|Add-Member -NotePropertyName DeploymentSession -NotePropertyValue $session -Force
        }
        $item
    }
}

function Copy-DeploymentItem {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$LiteralPath,[string[]]$Path,[Parameter(Mandatory)][string]$Destination,[switch]$Recurse,[switch]$Force,[switch]$CreateNew,
        [ValidateRange(1,1800)][int]$TimeoutSeconds=1800)
    $sources=if($LiteralPath){$LiteralPath}else{$Path}
    foreach($source in $sources){
        if(-not $PSCmdlet.ShouldProcess($Destination,"Copy $source")){continue}
        $from=Resolve-DeploymentSshPath $source;$to=Resolve-DeploymentSshPath $Destination
        if(-not $from -and -not $to){
            if($CreateNew){[IO.File]::Copy($source,$Destination,$false)}
            else{Microsoft.PowerShell.Management\Copy-Item -LiteralPath $source -Destination $Destination -Recurse:$Recurse -Force:$Force}
            continue
        }
        if($from -and $to){
            if($from.hostName -ne $to.hostName){throw 'Cross-host copies require an explicit local transfer archive.'}
            Invoke-DeploymentSsh $from.hostName {param($source,$target,$recurse,$force,$createNew)
                if($createNew){[IO.File]::Copy($source,$target,$false)}
                else{Copy-Item -LiteralPath $source -Destination $target -Recurse:$recurse -Force:$force}
            } @($from.path,$to.path,[bool]$Recurse,[bool]$Force,[bool]$CreateNew) -TimeoutSeconds 300
            continue
        }
        $remote=if($from){$from}else{$to}
        $configuration=Get-DeploymentSshConfiguration $remote.hostName
        # OpenSSH's SFTP-backed scp accepts an unquoted drive path in ONE argument, including spaces.
        # Do not use -O: that invokes a remote shell and changes Windows quoting rules.
        $copyPath=$remote.path
        if($to -and $CreateNew){
            $copyPath=Join-Path (Split-Path -Parent $remote.path) ('.copy-'+[guid]::NewGuid().ToString('N'))
        }
        $remoteArgument=$configuration.user+'@'+$configuration.hostName+':'+$copyPath.Replace('\','/')
        $arguments=@(Get-DeploymentSshArguments $configuration)
        if($Recurse){$arguments+='-r'}
        $arguments+=@('--')
        $arguments+=if($from){@($remoteArgument,$Destination)}else{@($source,$remoteArgument)}
        if($CreateNew){
            $exists=if($to){Test-Path -LiteralPath $Destination}else{Microsoft.PowerShell.Management\Test-Path -LiteralPath $Destination}
            $container=if($to){Test-Path -LiteralPath $Destination -PathType Container}else{Microsoft.PowerShell.Management\Test-Path -LiteralPath $Destination -PathType Container}
            if($exists -and -not $container){throw 'Copy destination already exists.'}
        }
        $process=New-DeploymentCopyProcess $arguments
        try{
            $clock=[Diagnostics.Stopwatch]::StartNew();$next=5
            while(-not $process.WaitForExit(1000)){
                if($clock.Elapsed.TotalSeconds -gt $TimeoutSeconds){$process.Kill($true);$process.WaitForExit();throw 'SCP copy deadline exceeded. Inspect the operation; do not resubmit.'}
                if($clock.Elapsed.TotalSeconds -ge $next){Write-Host ("SCP copy: elapsed {0:n0}s" -f $clock.Elapsed.TotalSeconds);$next+=5}
            }
            if($process.ExitCode -ne 0){throw "SCP failed with exit code $($process.ExitCode)."}
            if($to -and $CreateNew){
                Invoke-DeploymentSsh $remote.hostName {param($source,$target) [IO.File]::Move($source,$target,$false)} @($copyPath,$remote.path)
            }
        }finally{
            $process.Dispose()
            if($to -and $CreateNew){
                Invoke-DeploymentSsh $remote.hostName {param($path) if([IO.File]::Exists($path)){[IO.File]::Delete($path)}} @($copyPath)
            }
        }
    }
}

function Invoke-DeploymentFileOperation {
    param([Parameter(Mandatory)][ValidateSet('CreateDirectory','ReadAllText','ReadAllBytes','WriteAllBytes','Copy','Delete','Move')][string]$Operation,
        [Parameter(Mandatory)][object[]]$Arguments)
    $remote=Resolve-DeploymentSshPath ([string]$Arguments[0])
    if($Operation -eq 'Copy'){
        Copy-DeploymentItem -LiteralPath $Arguments[0] -Destination $Arguments[1] -Force:([bool]$Arguments[2]) -CreateNew:(-not [bool]$Arguments[2])
        return
    }
    if($remote){
        $Arguments[0]=$remote.path
        if($Operation -eq 'Move'){
            $target=Resolve-DeploymentSshPath ([string]$Arguments[1])
            if(-not $target -or $target.hostName -ne $remote.hostName){throw 'Atomic moves must stay on one host.'}
            $Arguments[1]=$target.path
        }
        Invoke-DeploymentSsh $remote.hostName {param($operation,$arguments)
            if($operation -eq 'CreateDirectory'){[IO.Directory]::CreateDirectory($arguments[0])|Out-Null;return}
            if($operation -eq 'ReadAllText'){return [IO.File]::ReadAllText($arguments[0])}
            if($operation -eq 'ReadAllBytes'){return ,([IO.File]::ReadAllBytes($arguments[0]))}
            if($operation -eq 'WriteAllBytes'){[IO.File]::WriteAllBytes($arguments[0],[byte[]]$arguments[1]);return}
            if($operation -eq 'Delete'){[IO.File]::Delete($arguments[0]);return}
            if($operation -eq 'Move'){[IO.File]::Move($arguments[0],$arguments[1],[bool]$arguments[2])}
        } @($Operation,$Arguments)
        return
    }
    switch($Operation){
        CreateDirectory {[IO.Directory]::CreateDirectory($Arguments[0])}
        ReadAllText {[IO.File]::ReadAllText($Arguments[0])}
        ReadAllBytes {,([IO.File]::ReadAllBytes($Arguments[0]))}
        WriteAllBytes {[IO.File]::WriteAllBytes($Arguments[0],$Arguments[1])}
        Delete {[IO.File]::Delete($Arguments[0])}
        Move {[IO.File]::Move($Arguments[0],$Arguments[1],[bool]$Arguments[2])}
    }
}

function Open-DeploymentSshLock {
    param([Parameter(Mandatory)][string]$Path)
    $remote=Resolve-DeploymentSshPath $Path
    if(-not $remote){throw 'Expected an SSH lock path.'}
    $literal=$remote.path.Replace("'","''")
    $script=@"
`$ErrorActionPreference='Stop'
try{`$lock=[IO.File]::Open('$literal','OpenOrCreate','ReadWrite','None')}
catch [IO.IOException]{
    if((`$_.Exception.HResult -band 65535) -eq 32){[Console]::Out.WriteLine('BUSY')}
    else{[Console]::Out.WriteLine('ERROR')}
    exit 2
}
try{[Console]::Out.WriteLine('LOCKED');[Console]::Out.Flush();[Console]::In.ReadToEnd()|Out-Null}
finally{`$lock.Dispose()}
"@
    $process=New-DeploymentSshProcess $remote.hostName $script
    $line=$process.StandardOutput.ReadLineAsync()
    if(-not $line.Wait(20000) -or $line.Result -ne 'LOCKED'){
        if(-not $process.HasExited){$process.Kill($true);$process.WaitForExit()}
        $process.Dispose()
        if($line.IsCompletedSuccessfully -and $line.Result -eq 'BUSY'){throw [IO.IOException]::new('Another operation holds the deployment lock.',[int]0x80070020)}
        throw 'Could not acquire the remote SSH file lock.'
    }
    $lease=[pscustomobject]@{Process=$process}
    $lease|Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Process.StandardInput.Close()
        if(-not $this.Process.WaitForExit(10000)){$this.Process.Kill($true);$this.Process.WaitForExit()}
        $this.Process.Dispose()
    }
    $lease|Add-Member -MemberType ScriptMethod -Name AssertHeld -Value {
        if($this.Process.HasExited){throw 'The SSH lock connection ended. Outcome unknown; inspect the operation before any new submission.'}
    }
    $lease
}

function Assert-DeploymentLease {
    param([Parameter(Mandatory)][object[]]$Lease)
    foreach($item in $Lease){
        if($item.PSObject.Methods['AssertHeld']){$item.AssertHeld()}
    }
}

# Proxies keep native parameter/pipeline behavior, including host-local execution and Pester mocks.
$names=@('Test-Path','Get-Item','Get-ChildItem','Get-Content','Set-Content','Copy-Item','Remove-Item','New-Item','Rename-Item','Move-Item',
    'Get-FileHash','Get-Acl','Set-Acl','Get-CimInstance','Invoke-CimMethod','Get-NetTCPConnection',
    'Get-ScheduledTask','Get-ScheduledTaskInfo','Start-ScheduledTask','Stop-ScheduledTask','Set-ScheduledTask','Export-ScheduledTask')
$script:NativeCommands=@{}
foreach($name in $names){
    $module=if($name -like '*ScheduledTask*'){'ScheduledTasks'}elseif($name -like '*Cim*'){'CimCmdlets'}elseif($name -eq 'Get-NetTCPConnection'){'NetTCPIP'}elseif($name -like '*Acl'){'Microsoft.PowerShell.Security'}elseif($name -eq 'Get-FileHash'){'Microsoft.PowerShell.Utility'}else{'Microsoft.PowerShell.Management'}
    $script:NativeCommands[$name]=Get-Command ($module+'\'+$name) -ErrorAction Stop|Select-Object -First 1
}
foreach($name in $names){
    $command=$script:NativeCommands[$name]
    $metadata=[Management.Automation.CommandMetadata]::new($command)
    $parameters=[Management.Automation.ProxyCommand]::GetParamBlock($metadata)
    $parameters=$parameters -replace '\[(?:Microsoft\.Management\.Infrastructure\.)?Cim(?:Instance|Session)(?:\[\])?\]','[object]'
    $parameters=$parameters -replace '\[Microsoft\.PowerShell\.Commands\.FileSystemContentWriterDynamicParameters\]','[object]'
    if($name -eq 'Get-ChildItem'){$parameters+=',[switch]$File,[switch]$Directory,[switch]$Hidden,[switch]$ReadOnly,[switch]$System,[IO.FileAttributes]$Attributes,[switch]$FollowSymlink'}
    if($name -in @('Get-Content','Set-Content')){
        $parameters+=',[string]$Encoding,[switch]$AsByteStream'
        if($name -eq 'Get-Content'){$parameters+=',[switch]$Raw,[string]$Delimiter,[switch]$Wait'}
        else{$parameters+=',[switch]$NoNewline'}
    }
    $binding=[Management.Automation.ProxyCommand]::GetCmdletBindingAttribute($metadata)
    $body="$binding param($parameters) process { Invoke-DeploymentTransportCommand -Name '$name' -Parameters `$PSBoundParameters }"
    Set-Item -Path ('Function:script:'+$name) -Value ($ExecutionContext.SessionState.Module.NewBoundScriptBlock([scriptblock]::Create($body)))
}
Export-ModuleMember -Function ($names+@('Get-DeploymentSshConfiguration','Get-DeploymentRemotePath','Resolve-DeploymentSshPath',
    'New-DeploymentSession','Close-DeploymentSession','Invoke-DeploymentSsh','Copy-DeploymentItem','Invoke-DeploymentFileOperation','Open-DeploymentSshLock','Assert-DeploymentLease'))
