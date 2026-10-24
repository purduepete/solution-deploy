#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CommonRelease.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'HandPlacedRelease.psm1') -DisableNameChecking

$script:HostClone='\\jimbrownhome1.local\c$\Files\Dev\main\solution-deploy'
$script:Installed='\\jimbrownhome1.local\c$\ProgramData\SolutionDeploy\apps\solution-deploy'
$script:HostTemp='\\jimbrownhome1.local\c$\Windows\Temp'

# Mirrors the copies made by scripts\Install-Directory.ps1.
function Get-DirectoryInstallMap {
    param([Parameter(Mandatory)][string]$Source)
    $map=[ordered]@{}
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $Source 'site') -File){$map["site\$($file.Name)"]=$file.FullName}
    $map['environments\releases.json']=Join-Path $Source 'environments\releases.json'
    $map['Start-Directory.ps1']=Join-Path $Source 'scripts\Start-Directory.ps1'
    $map['Update-CollectorStatus.ps1']=Join-Path $Source 'scripts\Update-CollectorStatus.ps1'
    $map
}

function Compare-DirectoryInstall {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Map,[Parameter(Mandatory)][string]$Installed)
    @(foreach($relative in $Map.Keys){
        $target=Join-Path $Installed $relative
        if(-not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-NormalizedFileDigest $target) -ne (Get-NormalizedFileDigest $Map[$relative])){$relative}
    })
}

function Invoke-HostGit {
    param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$Repository,[switch]$Capture)
    $git=(Get-Command git -CommandType Application).Source
    Invoke-DeploymentCommand $git (@('-c','safe.directory=*','-C',$script:HostClone)+$Arguments) $Repository -Capture:$Capture
}

function Invoke-DirectoryRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository,[string]$Commit='HEAD',[Parameter(Mandatory)][string]$ApprovalReason,
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'),[int]$TimeoutSeconds=300)
    $commitId=Resolve-CommonReleaseSource $Repository $Commit
    $access=Get-SiteAccess 'solution-deploy'
    $readiness=@{path='health';expected=@{status='ok'}}
    [IO.Directory]::CreateDirectory((Join-Path $script:Installed 'state'))|Out-Null
    $lock=Get-DeploymentLock (Join-Path $script:Installed 'state\common-controller.lock')
    $id=[guid]::NewGuid().ToString('N')
    $directory=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "releases\solution-deploy-directory-$id"
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $receiptPath=Join-Path $directory 'release.json'
    $receipt=@{app='solution-deploy';component='directory';sourceCommit=$commitId;status='Preparing';startedLocal=(Get-Date).ToString('o');reason=$ApprovalReason}
    $script=Join-Path $script:HostTemp "sd-directory-$($id.Substring(0,8)).ps1"
    $result=Join-Path $script:HostTemp "sd-directory-$($id.Substring(0,8)).json"
    $session=$null
    try{
        if(Invoke-HostGit @('status','--porcelain','--untracked-files=normal') $Repository -Capture){throw 'The host clone has uncommitted files; the installer would copy them.'}
        Invoke-HostGit @('-c','credential.interactive=false','fetch','--quiet','origin') $Repository
        $receipt.previousCommit=Invoke-HostGit @('rev-parse','HEAD') $Repository -Capture
        try{Invoke-HostGit @('merge-base','--is-ancestor','HEAD',$commitId) $Repository}
        catch{throw "The host clone at $($receipt.previousCommit) is not an ancestor of $commitId. Release a newer commit."}
        $stale=@(Compare-DirectoryInstall (Get-DirectoryInstallMap $script:HostClone) $script:Installed)
        if($stale.Count -and $receipt.previousCommit -cne $commitId){throw "The installed directory differs from the host clone at $($receipt.previousCommit): $($stale -join ', '). Reinstall by hand before releasing."}
        Invoke-HostGit @('merge','--ff-only','--quiet',$commitId) $Repository
        if((Invoke-HostGit @('rev-parse','HEAD') $Repository -Capture) -cne $commitId){throw 'The host clone did not move to the release commit.'}
        $changed=@(Compare-DirectoryInstall (Get-DirectoryInstallMap $script:HostClone) $script:Installed)
        if(-not $changed.Count){
            $receipt.access=Test-HandPlacedReadiness $access $readiness
            $receipt.status='NoChanges';$receipt.completedLocal=(Get-Date).ToString('o')
            Write-DeploymentJson $receiptPath $receipt
            return $receipt
        }
        $receipt.changed=$changed
        Set-Content -LiteralPath $script -Encoding utf8 -Value @"
`$ErrorActionPreference='Stop'
try{`$out=& 'C:\Files\Dev\main\solution-deploy\scripts\Install-Directory.ps1';@{status='Succeeded';sites=`$out.Sites;privateStatus=`$out.PrivateStatus;pid=`$out.Pid}|ConvertTo-Json|Set-Content '$($result.Replace($script:HostTemp,'C:\Windows\Temp'))'}
catch{@{status='Failed';error=`$_.Exception.Message}|ConvertTo-Json|Set-Content '$($result.Replace($script:HostTemp,'C:\Windows\Temp'))'}
"@
        $session=New-CimSession -ComputerName jimbrownhome1.local -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 30
        $command='"C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe" -NoProfile -NonInteractive -WindowStyle Hidden -File "'+$script.Replace($script:HostTemp,'C:\Windows\Temp')+'"'
        $receipt.status='Installing'
        Write-DeploymentJson $receiptPath $receipt
        $created=Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command}
        if($created.ReturnValue -ne 0){throw "Could not start the directory installer (Windows result $($created.ReturnValue))."}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while(-not (Test-Path -LiteralPath $result)){
            if($clock.Elapsed.TotalSeconds -gt $TimeoutSeconds){throw "The directory installer ran past $TimeoutSeconds s (host PID $($created.ProcessId))."}
            if(-not (Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter "ProcessId=$($created.ProcessId)") -and -not (Test-Path -LiteralPath $result)){
                throw 'The directory installer exited without a result.'
            }
            Write-Host ("Directory installer: elapsed {0:n0}s." -f $clock.Elapsed.TotalSeconds)
            Start-Sleep -Seconds 3
        }
        Start-Sleep -Milliseconds 500
        $installed=Read-DeploymentJson $result
        if($installed.status -ne 'Succeeded'){throw "The directory installer failed: $($installed['error'])"}
        $receipt.install=$installed
        $left=@(Compare-DirectoryInstall (Get-DirectoryInstallMap $script:HostClone) $script:Installed)
        if($left.Count){throw "Installed files still differ from $commitId after install: $($left -join ', ')."}
        $receipt.access=Test-HandPlacedReadiness $access $readiness
        Write-DeploymentJson (Join-Path $script:Installed 'state\directory-release.json') @{sourceCommit=$commitId;previousCommit=$receipt.previousCommit;completedLocal=(Get-Date).ToString('o')}
        $receipt.status='Succeeded';$receipt.completedLocal=(Get-Date).ToString('o')
        Write-DeploymentJson $receiptPath $receipt
        $receipt
    }catch{
        $receipt.status='Failed';$receipt.error=$_.Exception.Message
        Write-DeploymentJson $receiptPath $receipt
        throw
    }finally{
        foreach($path in $script,$result){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
        if($session){Remove-CimSession $session}
        $lock.Dispose()
    }
}

Export-ModuleMember -Function Get-DirectoryInstallMap,Compare-DirectoryInstall,Invoke-DirectoryRelease
