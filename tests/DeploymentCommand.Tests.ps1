$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking

Describe 'Pinned deployment tool subprocesses' {
    It 'makes the pinned executable directory available to child tools without changing the parent PATH' {
        $executable=Join-Path $PSHOME 'pwsh.exe'
        $original=$env:PATH
        try{
            $env:PATH="$env:SystemRoot\System32"
            $result=Invoke-DeploymentCommand -Executable $executable -WorkingDirectory $TestDrive -Arguments @(
                '-NoProfile','-NonInteractive','-Command',
                '$child=Start-Process -FilePath pwsh.exe -ArgumentList @("-NoProfile","-NonInteractive","-Command","exit 0") -Wait -PassThru -WindowStyle Hidden; if($child.ExitCode -ne 0){exit 1}; [Console]::WriteLine(($env:PATH -split [IO.Path]::PathSeparator)[0])'
            ) -Capture
            $result|Should Be $PSHOME
            $env:PATH|Should Be "$env:SystemRoot\System32"
        }finally{$env:PATH=$original}
    }
    It 'passes release npm settings to the child process only' {
        $executable=Join-Path $PSHOME 'pwsh.exe'
        Remove-Item Env:npm_config_audit -ErrorAction SilentlyContinue
        $result=Invoke-DeploymentCommand -Executable $executable -WorkingDirectory $TestDrive -Environment (Get-ReleaseNpmEnvironment) -Arguments @(
            '-NoProfile','-NonInteractive','-Command',
            '[Console]::WriteLine($env:npm_config_audit+","+$env:npm_config_fund+","+$env:npm_config_update_notifier)'
        ) -Capture
        $result|Should Be 'false,false,false'
        Test-Path Env:npm_config_audit|Should Be $false
    }
}

Describe 'Same-host snapshot reuse' {
    It 'treats matching host, address and root as one machine, case-insensitively' {
        Test-SameDeploymentHost @{host='JimBrownHome1';address='10.0.0.5';root='C:\ProgramData\SolutionDeploy'} @{host='jimbrownhome1';address='10.0.0.5';root='c:\programdata\solutiondeploy'}|Should Be $true
    }
    It 'treats any differing field or missing value as separate hosts' {
        $a=@{host='h';address='10.0.0.5';root='C:\R'}
        Test-SameDeploymentHost $a @{host='other';address='10.0.0.5';root='C:\R'}|Should Be $false
        Test-SameDeploymentHost $a @{host='h';address='10.0.0.6';root='C:\R'}|Should Be $false
        Test-SameDeploymentHost $a @{host='h';address='10.0.0.5';root='D:\R'}|Should Be $false
        Test-SameDeploymentHost @{host='';address='';root=''} @{host='';address='';root=''}|Should Be $false
    }
}
