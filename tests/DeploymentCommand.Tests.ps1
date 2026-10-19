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
}
