#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'CommonRelease.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'HandPlacedRelease.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SshTransport.psm1') -DisableNameChecking

$script:HostClone=Get-DeploymentRemotePath jimbrownhome1 'C:\Files\Dev\main\solution-deploy'
$script:Installed=Get-DeploymentRemotePath jimbrownhome1 'C:\ProgramData\SolutionDeploy\apps\solution-deploy'
$script:HostOperationRoot='C:\ProgramData\SolutionDeploy\control\directory-releases'
$script:HostTemp=Get-DeploymentRemotePath jimbrownhome1 $script:HostOperationRoot
# Install-Directory.ps1 installs both components, so a successful release records both.
$script:DirectoryComponents=@('directory','collector-status')
# Written when the host installer outlives the wait; blocks new releases until an operator clears it.
$script:DirectoryUnknownMarker=Join-Path $script:Installed 'state\directory-release-unknown.json'

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
    Invoke-DeploymentSsh jimbrownhome1 {
        param($arguments,$capture)
        $env:GCM_INTERACTIVE='Never'
        $env:GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes'
        $out=& git -c safe.directory=C:\Files\Dev\main\solution-deploy -C C:\Files\Dev\main\solution-deploy @arguments
        if($LASTEXITCODE -ne 0){throw 'Host Git failed.'}
        if($capture){($out -join "`n").TrimEnd("`r","`n")}
    } @($Arguments,[bool]$Capture) -TimeoutSeconds 120
}

function Complete-DirectoryRelease {
    param([Parameter(Mandatory)][hashtable]$Receipt,[Parameter(Mandatory)][string]$Installed,[Parameter(Mandatory)][string]$ReceiptPath)
    $Receipt.status='Succeeded';$Receipt.completedLocal=(Get-Date).ToString('o')
    Write-DeploymentJson (Join-Path $Installed 'state\directory-release.json') @{sourceCommit=$Receipt.sourceCommit;previousCommit=$Receipt.previousCommit;completedLocal=$Receipt.completedLocal}
    Write-DeploymentJson $ReceiptPath $Receipt
}

function Invoke-DirectoryRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository,[string]$Commit='HEAD',[Parameter(Mandatory)][string]$ApprovalReason,
        [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) '.local'),[int]$TimeoutSeconds=300,
        [switch]$AllowUnhealthyCurrent,[DateTimeOffset]$ExpiresLocal=([DateTimeOffset]::Now.AddMinutes(60)))
    Assert-ReleaseConsentCurrent $ExpiresLocal
    $commitId=Resolve-CommonReleaseSource $Repository $Commit
    $access=Get-SiteAccess 'solution-deploy'
    $readiness=@{path='health';expected=@{status='ok'}}
    Invoke-DeploymentFileOperation CreateDirectory @((Join-Path $script:Installed 'state'))|Out-Null
    Invoke-DeploymentFileOperation CreateDirectory @($script:HostTemp)|Out-Null
    $lock=Get-DeploymentLock (Join-Path $script:Installed 'state\common-controller.lock')
    $id=[guid]::NewGuid().ToString('N')
    $directory=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "releases\solution-deploy-directory-$id"
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $receiptPath=Join-Path $directory 'release.json'
    $receipt=@{app='solution-deploy';component=$script:DirectoryComponents;sourceCommit=$commitId;status='Preparing';startedLocal=(Get-Date).ToString('o');reason=$ApprovalReason}
    $script=Join-Path $script:HostTemp "sd-directory-$($id.Substring(0,8)).ps1"
    $result=Join-Path $script:HostTemp "sd-directory-$($id.Substring(0,8)).json"
    $installerSwitches=if($AllowUnhealthyCurrent){' -AllowUnhealthyCurrent'}else{''}
    $session=$null
    $keepHostFiles=$false
    # True from just before the launch until the host installer is confirmed to have exited.
    $hostMayBeRunning=$false
    try{
        # Checked under the lock, so two callers cannot both pass it.
        if(Test-Path -LiteralPath $script:DirectoryUnknownMarker -PathType Leaf){
            $unknown=Read-DeploymentJson $script:DirectoryUnknownMarker
            throw "A previous directory release ended with an unknown outcome (operation $($unknown.operationId), host PID $($unknown.hostPid), started $($unknown.startedLocal)). Verify on jimbrownhome1 that PID $($unknown.hostPid) has exited and that the installed directory matches $($unknown.sourceCommit), then remove $($script:DirectoryUnknownMarker) before retrying."
        }
        if(Invoke-HostGit @('status','--porcelain','--untracked-files=normal') $Repository -Capture){throw 'The host clone has uncommitted files; the installer would copy them.'}
        Invoke-HostGit @('-c','credential.interactive=false','fetch','--quiet','origin') $Repository
        $receipt.previousCommit=Invoke-HostGit @('rev-parse','HEAD') $Repository -Capture
        try{Invoke-HostGit @('merge-base','--is-ancestor','HEAD',$commitId) $Repository}
        catch{throw "The host clone at $($receipt.previousCommit) is not an ancestor of $commitId. Release a newer commit."}
        $stale=@(Compare-DirectoryInstall (Get-DirectoryInstallMap $script:HostClone) $script:Installed)
        if($stale.Count -and $receipt.previousCommit -cne $commitId){throw "The installed directory differs from the host clone at $($receipt.previousCommit): $($stale -join ', '). Reinstall by hand before releasing."}
        Assert-DeploymentLease @($lock)
        Assert-ReleaseConsentCurrent $ExpiresLocal
        Invoke-HostGit @('merge','--ff-only','--quiet',$commitId) $Repository
        if((Invoke-HostGit @('rev-parse','HEAD') $Repository -Capture) -cne $commitId){throw 'The host clone did not move to the release commit.'}
        $changed=@(Compare-DirectoryInstall (Get-DirectoryInstallMap $script:HostClone) $script:Installed)
        if(-not $changed.Count -and -not $AllowUnhealthyCurrent){
            $receipt.access=Test-HandPlacedReadiness $access $readiness
            $receipt.status='NoChanges';$receipt.completedLocal=(Get-Date).ToString('o')
            Write-DeploymentJson $receiptPath $receipt
            return $receipt
        }
        $receipt.changed=$changed
        Set-Content -LiteralPath $script -Encoding utf8 -Value @"
`$ErrorActionPreference='Stop'
try{`$out=& 'C:\Files\Dev\main\solution-deploy\scripts\Install-Directory.ps1' -PreserveTailscaleRoute$installerSwitches -ExpiresLocal '$($ExpiresLocal.ToString('o'))';@{status='Succeeded';sites=`$out.Sites;privateStatus=`$out.PrivateStatus;pid=`$out.Pid}|ConvertTo-Json|Set-Content '$($result.Replace($script:HostTemp,$script:HostOperationRoot))'}
catch{@{status='Failed';error=`$_.Exception.Message;rollbackVerified=(`$_.Exception.Message -notmatch 'Rollback verification failed:')}|ConvertTo-Json|Set-Content '$($result.Replace($script:HostTemp,$script:HostOperationRoot))'}
"@
        $session=New-DeploymentSession -ComputerName jimbrownhome1.local -OperationTimeoutSec 30
        $command='"C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe" -NoProfile -NonInteractive -WindowStyle Hidden -File "'+$script.Replace($script:HostTemp,$script:HostOperationRoot)+'"'
        $receipt.status='Installing'
        Write-DeploymentJson $receiptPath $receipt
        Assert-DeploymentLease @($lock)
        Assert-ReleaseConsentCurrent $ExpiresLocal
        $launchedLocal=(Get-Date).ToString('o')
        # The marker is on disk before the launch, so an installer that starts and then loses its caller stays marked.
        $marker=@{operationId=$id;sourceCommit=$commitId;startedLocal=$launchedLocal;status='InFlight'}
        Write-DeploymentJson $script:DirectoryUnknownMarker $marker
        $hostMayBeRunning=$true
        $created=Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command}
        if($created.ReturnValue -ne 0){
            # Windows reported no launch, so nothing can be running and the marker is cleared.
            $hostMayBeRunning=$false
            Invoke-DeploymentFileOperation Delete @($script:DirectoryUnknownMarker)
            throw "Could not start the directory installer (Windows result $($created.ReturnValue))."
        }
        $marker.hostPid=[int]$created.ProcessId
        Write-DeploymentJson $script:DirectoryUnknownMarker $marker
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while(Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter "ProcessId=$($created.ProcessId)"){
            if($clock.Elapsed.TotalSeconds -gt $TimeoutSeconds){
                # The host process may still be installing, so its marker, scripts and result stay in place.
                $receipt.status='Unknown'
                $marker.status='Unknown';$marker.timedOutLocal=(Get-Date).ToString('o')
                Write-DeploymentJson $script:DirectoryUnknownMarker $marker
                throw "The directory installer ran past $TimeoutSeconds s (host PID $($created.ProcessId)); its outcome is unknown."
            }
            Write-Host ("Directory installer: elapsed {0:n0}s." -f $clock.Elapsed.TotalSeconds)
            Start-Sleep -Seconds 3
        }
        # The process has exited. A result writer may still be closing its file, so allow a short wait for it.
        $exited=[Diagnostics.Stopwatch]::StartNew()
        while(-not (Test-Path -LiteralPath $result) -and $exited.Elapsed.TotalSeconds -lt 20){Start-Sleep -Seconds 2}
        $hostMayBeRunning=$false
        if(-not (Test-Path -LiteralPath $result)){
            # A killed installer may have left a mixed installation, so the marker, script and result stay for an operator.
            $keepHostFiles=$true
            $receipt.status='Unknown'
            throw 'The directory installer exited without a result; its outcome is unknown and the installed directory may be mixed.'
        }
        Start-Sleep -Milliseconds 500
        try{$installed=Read-DeploymentJson $result}
        catch{
            $keepHostFiles=$true
            $receipt.status='Unknown'
            throw "The directory installer result could not be read: $($_.Exception.Message)"
        }
        if($installed.status -notin 'Succeeded','Failed'){
            $keepHostFiles=$true
            $receipt.status='Unknown'
            throw "The directory installer result has an unrecognized status '$($installed.status)'."
        }
        if($installed.status -eq 'Failed' -and $installed['rollbackVerified'] -ne $true){
            # Rollback did not verify recovery; retain the marker and host files so retries stay blocked.
            $keepHostFiles=$true
            $receipt.status='Unknown'
            throw "The directory installer failed without verified rollback: $($installed['error'])"
        }
        # A structured result with verified success or verified rollback is a known outcome.
        if(Test-Path -LiteralPath $script:DirectoryUnknownMarker -PathType Leaf){Invoke-DeploymentFileOperation Delete @($script:DirectoryUnknownMarker)}
        if($installed.status -ne 'Succeeded'){throw "The directory installer failed: $($installed['error'])"}
        $receipt.install=$installed
        $left=@(Compare-DirectoryInstall (Get-DirectoryInstallMap $script:HostClone) $script:Installed)
        if($left.Count){throw "Installed files still differ from $commitId after install: $($left -join ', ')."}
        $receipt.access=Test-HandPlacedReadiness $access $readiness
        Assert-DeploymentLease @($lock)
        Complete-DirectoryRelease $receipt $script:Installed $receiptPath
        $receipt
    }catch{
        if($hostMayBeRunning){
            # The installer may still be running, so its marker, scripts and result are kept for the operator.
            $keepHostFiles=$true
            $receipt.status='Unknown'
        }elseif($receipt.status -ne 'Unknown'){$receipt.status='Failed'}
        $receipt.error=$_.Exception.Message
        Write-DeploymentJson $receiptPath $receipt
        throw
    }finally{
        if(-not $keepHostFiles){
            foreach($path in $script,$result){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
        }
        if($session){Close-DeploymentSession $session}
        $lock.Dispose()
    }
}

Export-ModuleMember -Function Get-DirectoryInstallMap,Compare-DirectoryInstall,Invoke-DirectoryRelease
