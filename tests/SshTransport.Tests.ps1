$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\SshTransport.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking

Describe 'SSH transport addressing and authentication' {
    It 'uses a logical drive address for the new host and LAN legacy address for the old host' {
        Get-DeploymentRemotePath jimbrownhome1 'D:\Folder with spaces\file.txt' |
            Should Be 'C:\.solution-deploy-ssh\jimbrownhome1.local\D\Folder with spaces\file.txt'
        Get-DeploymentRemotePath jimbrownhome 'C:\ProgramData\SolutionDeploy' |
            Should Be '\\jimbrownhome.local\C$\ProgramData\SolutionDeploy'
        $remote=Resolve-DeploymentSshPath 'C:\.solution-deploy-ssh\jimbrownhome1.local\D\Folder with spaces\file.txt'
        $remote.hostName|Should Be 'jimbrownhome1.local'
        $remote.path|Should Be 'D:\Folder with spaces\file.txt'
    }
    It 'rejects direct admin-share access to the SSH host' {
        $thrown=$false
        try{Resolve-DeploymentSshPath '\\jimbrownhome1.local\c$\file'|Out-Null}catch{$thrown=$true}
        $thrown|Should Be $true
    }
    It 'keeps the maintenance username configurable and pins the shell' {
        $old=$env:SOLUTION_DEPLOY_SSH_USER
        try{
            $env:SOLUTION_DEPLOY_SSH_USER='test-maintenance'
            $configuration=Get-DeploymentSshConfiguration
            $configuration.user|Should Be 'test-maintenance'
            $configuration.hostName|Should Be 'jimbrownhome1.local'
            $configuration.powerShell|Should Be 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe'
            $env:SOLUTION_DEPLOY_SSH_USER='name;command'
            $thrown=$false
            try{Get-DeploymentSshConfiguration|Out-Null}catch{$thrown=$true}
            $thrown|Should Be $true
        }finally{$env:SOLUTION_DEPLOY_SSH_USER=$old}
    }
    InModuleScope SshTransport {
        It 'passes destination and PowerShell call expression as separate SSH arguments' {
            $info=New-DeploymentSshStartInfo jimbrownhome1 '[Console]::Out.Write("hello")'
            $info.ArgumentList[-2]|Should Match '^[-A-Za-z0-9_.]+@jimbrownhome1\.local$'
            $info.ArgumentList[-1]|Should Match "^& 'C:\\ProgramData\\SolutionDeploy\\runtime\\powershell\\7\\pwsh.exe' -NoLogo"
            $info.ArgumentList.Count|Should Be 18
        }
        It 'requires key-only authentication and a previously trusted host key' {
            $arguments=Get-DeploymentSshArguments (Get-DeploymentSshConfiguration)
            foreach($required in @('BatchMode=yes','StrictHostKeyChecking=yes','PreferredAuthentications=publickey',
                'PasswordAuthentication=no','KbdInteractiveAuthentication=no')){
                ($arguments -contains $required)|Should Be $true
            }
        }
    }
    It 'creates an SSH session without connecting over CIM' {
        Mock New-CimSession -ModuleName SshTransport {throw 'DCOM must not be used'}
        $session=New-DeploymentSession jimbrownhome1
        $session.DeploymentSsh|Should Be $true
        $session.ComputerName|Should Be 'jimbrownhome1.local'
        Close-DeploymentSession $session
        Assert-MockCalled New-CimSession -ModuleName SshTransport -Times 0 -Scope It
    }
}

Describe 'Encrypted command protocol using a host-local process substitute' {
    BeforeEach {
        Mock New-DeploymentSshProcess -ModuleName SshTransport {
            param($HostName,$Script)
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=(Get-Command pwsh.exe -CommandType Application|Select-Object -First 1).Source
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',
                [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script)))){$start.ArgumentList.Add($argument)}
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start
            $null=$process.Start()
            $process
        }
    }
    It 'preserves separate arguments, empty arrays, hashtables, bytes and dates' {
        $bytes=[byte[]]@(0,1,127,255)
        $result=Invoke-DeploymentSsh jimbrownhome1 {
            param($first,$second,$bytes,$empty)
            @{first=$first;second=$second;bytes=$bytes;empty=$empty;date=[datetime]'2026-11-07T10:00:00'}
        } @('quoted "value"','C:\Folder with spaces\file',$bytes,@())
        $result.first|Should Be 'quoted "value"'
        $result.second|Should Be 'C:\Folder with spaces\file'
        ($result.bytes -join ',')|Should Be '0,1,127,255'
        @($result.empty).Count|Should Be 0
        $result.date.Year|Should Be 2026
    }
    It 'surfaces remote errors without disclosing their contents' {
        $message=''
        try{Invoke-DeploymentSsh jimbrownhome1 {throw 'synthetic-private-value'}|Out-Null}catch{$message=$_.Exception.Message}
        $message|Should Match 'SSH failed'
        $message|Should Not Match 'synthetic-private-value'
    }
    It 'keeps host informational output out of the serialized result' {
        $result=Invoke-DeploymentSsh jimbrownhome1 {
            Write-Host 'Host phase heartbeat'
            Write-Warning 'Host informational warning'
            @{status='Succeeded'}
        }
        $result.status|Should Be Succeeded
    }
    It 'bounds silent commands and reports an unknown outcome' {
        $message=''
        try{Invoke-DeploymentSsh jimbrownhome1 {Start-Sleep -Seconds 10} -TimeoutSeconds 1|Out-Null}catch{$message=$_.Exception.Message}
        $message|Should Match 'deadline.*Outcome unknown.*do not resubmit'
    }
    It 'writes local JSON with create-new semantics and reads it back unchanged' {
        $path=Join-Path $TestDrive 'record.json'
        Write-DeploymentJson $path @{status='Succeeded';nested=@{count=2}} -CreateNew
        (Read-DeploymentJson $path).nested.count|Should Be 2
        $thrown=$false
        try{Write-DeploymentJson $path @{status='Changed'} -CreateNew}catch{$thrown=$true}
        $thrown|Should Be $true
        (Read-DeploymentJson $path).status|Should Be Succeeded
    }
    It 'materializes raw file content before serializing remote metadata' {
        $path=Join-Path $TestDrive 'installation.json'
        Write-DeploymentJson $path @{codeSHA256=('a'*64);files=@(@{path='src\fixture.psm1';sha256=('b'*64)})}
        $remote=Get-DeploymentRemotePath jimbrownhome1 $path
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $record=Read-DeploymentJson $remote
        $record.codeSHA256|Should Be ('a'*64)
        $record.files[0].path|Should Be 'src\fixture.psm1'
        ($clock.Elapsed.TotalSeconds -lt 15)|Should Be $true
    }
    It 'holds the exclusive file lock on the host until the SSH channel closes' {
        $path=Join-Path $TestDrive 'ssh-submission.lock'
        $remote=Get-DeploymentRemotePath jimbrownhome1 $path
        $lease=Open-DeploymentSshLock $remote
        try{
            $lease.AssertHeld()
            $blocked=$false
            try{$other=[IO.File]::Open($path,'OpenOrCreate','ReadWrite','None');$other.Dispose()}catch [IO.IOException]{$blocked=$true}
            $blocked|Should Be $true
            $message=''
            try{Open-DeploymentSshLock $remote|Out-Null}catch{$message=$_.Exception.Message}
            $message|Should Match 'Another operation holds'
        }finally{$lease.Dispose()}
        $released=[IO.File]::Open($path,'Open','ReadWrite','None')
        $released.Dispose()
    }
    It 'refuses further work when the SSH lock process exited' {
        $path=Join-Path $TestDrive 'ssh-lost.lock'
        $lease=Open-DeploymentSshLock (Get-DeploymentRemotePath jimbrownhome1 $path)
        try{
            $lease.Process.Kill($true);$lease.Process.WaitForExit()
            $message=''
            try{Assert-DeploymentLease @($lease)}catch{$message=$_.Exception.Message}
            $message|Should Match 'SSH lock connection ended.*Outcome unknown'
        }finally{$lease.Dispose()}
    }
}

Describe 'Remote filesystem and task routing without a network connection' {
    It 'converts filesystem arguments and returned paths while retaining reparse-point evidence' {
        Mock Invoke-DeploymentSsh -ModuleName SshTransport {
            [pscustomobject]@{FullName='C:\Folder with spaces\file';PSPath='C:\Folder with spaces\file'
                Attributes=[IO.FileAttributes]::ReparsePoint;Target='C:\RealTarget';PSIsContainer=$false}
        }
        $item=Get-Item -LiteralPath 'C:\.solution-deploy-ssh\jimbrownhome1.local\C\Folder with spaces\file' -Force
        $item.FullName|Should Be 'C:\.solution-deploy-ssh\jimbrownhome1.local\C\Folder with spaces\file'
        $item.Target|Should Be 'C:\RealTarget'
        [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)|Should Be $true
        Assert-MockCalled Invoke-DeploymentSsh -ModuleName SshTransport -Times 1 -Scope It -ParameterFilter {
            $HostName -eq 'jimbrownhome1.local' -and $ArgumentList[1].LiteralPath[0] -eq 'C:\Folder with spaces\file'
        }
    }
    It 'routes task calls with the existing account and exact task path unchanged' {
        Mock Invoke-DeploymentSsh -ModuleName SshTransport {
            [pscustomobject]@{TaskName='SolutionDeploy-Executor';TaskPath='\JimlerTech\';State='Ready'}
        }
        $session=New-DeploymentSession jimbrownhome1
        $task=Get-ScheduledTask -CimSession $session -TaskName SolutionDeploy-Executor -TaskPath '\JimlerTech\'
        $task.DeploymentSession.ComputerName|Should Be 'jimbrownhome1.local'
        $task.State|Should Be Ready
        Assert-MockCalled Invoke-DeploymentSsh -ModuleName SshTransport -Times 1 -Scope It -ParameterFilter {
            $ArgumentList[0] -eq 'Get-ScheduledTask' -and -not $ArgumentList[1].ContainsKey('CimSession') -and
            $ArgumentList[1].TaskPath -eq '\JimlerTech\'
        }
    }
    It 'retains host-local filesystem behavior including binary writes and recursive enumeration' {
        $path=Join-Path $TestDrive 'local\file.bin'
        Invoke-DeploymentFileOperation CreateDirectory @((Split-Path $path))|Out-Null
        Invoke-DeploymentFileOperation WriteAllBytes @($path,[byte[]]@(0,255))
        ((Invoke-DeploymentFileOperation ReadAllBytes @($path)) -join ',')|Should Be '0,255'
        @(Get-ChildItem (Split-Path $path) -File -Recurse).Count|Should Be 1
    }
    It 'passes Windows paths with spaces as single SFTP-backed SCP arguments' {
        Mock New-DeploymentCopyProcess -ModuleName SshTransport {
            param($Arguments)
            $global:SyntheticCopyArguments=$Arguments
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=$env:ComSpec;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
            foreach($argument in @('/c','exit','0')){$start.ArgumentList.Add($argument)}
            $process=[Diagnostics.Process]::new();$process.StartInfo=$start
            $null=$process.Start()
            $process
        }
        try{
            Copy-DeploymentItem -LiteralPath 'C:\Local folder\source.zip' -Destination 'C:\.solution-deploy-ssh\jimbrownhome1.local\D\Remote folder\payload.zip'
            $global:SyntheticCopyArguments[-2]|Should Be 'C:\Local folder\source.zip'
            $global:SyntheticCopyArguments[-1]|Should Match '^[-A-Za-z0-9_.]+@jimbrownhome1\.local:D:/Remote folder/payload.zip$'
            ($global:SyntheticCopyArguments -ccontains '-O')|Should Be $false
            ($global:SyntheticCopyArguments -contains 'StrictHostKeyChecking=yes')|Should Be $true
        }finally{Remove-Variable SyntheticCopyArguments -Scope Global -ErrorAction SilentlyContinue}
    }
    It 'contains no direct admin-share or DCOM session construction outside the explicit legacy helper' {
        foreach($name in @('Controller','Deployment','Placement','Transfer','Release','CommonRelease','FitTrackRelease',
            'HandPlacedRelease','DirectoryRelease','FileSetRelease','PinnedJobRelease')){
            $text=[IO.File]::ReadAllText((Join-Path $root "src\$name.psm1"))
            $text|Should Not Match 'New-CimSession|Protocol Dcom|\\\\jimbrownhome1(?:\.local)?\\'
            $text|Should Match 'SshTransport.psm1'
        }
    }
}
