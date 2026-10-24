#requires -Version 7.5
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$RequestSHA256,
    [Parameter(Mandatory)][ValidateSet('Prepare','Activate')][string]$Phase
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$framework='C:\ProgramData\SolutionDeploy\control\framework'
Import-Module (Join-Path $framework 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $framework 'src\Lifecycle.psm1') -DisableNameChecking
$operation=Split-Path -Parent $RequestPath
if($operation -notmatch '^C:\\ProgramData\\SolutionDeploy\\apps\\(web-bookmarks|work-log|web-inventory|plex|web-options)\\state\\routine\\[a-f0-9]{32}$' -or
    $RequestPath -ine (Join-Path $operation 'request.json')){throw 'Unexpected release request location.'}
$app=$Matches[1]
$appRoot="C:\ProgramData\SolutionDeploy\apps\$app"
$resultPath=Join-Path $operation ($Phase.ToLowerInvariant()+'-result.json')
$result=@{phase=$Phase;requestSHA256=$RequestSHA256;status='Running';startedLocal=(Get-Date).ToString('o')}
$lock=$null
$stopped=$false
$switched=$false

function Assert-RequestCurrent {
    if((Get-FileHash -LiteralPath $RequestPath).Hash.ToLowerInvariant() -ne $RequestSHA256){throw 'Release request changed.'}
    if([DateTimeOffset]::Parse($request.expiresLocal) -le [DateTimeOffset]::Now){throw 'Release consent expired.'}
    if((Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant() -ne $request.runnerSHA256){throw 'Release runner changed.'}
    if($env:COMPUTERNAME -ine 'jimbrownhome1' -or (Get-CimInstance Win32_ComputerSystemProduct).UUID -ne $request.hostIdentity){throw 'Destination identity changed.'}
    if([string]::IsNullOrWhiteSpace($request.approvedBy) -or [string]::IsNullOrWhiteSpace($request.reason)){throw 'Release consent is missing.'}
}

function Assert-PreviousCurrent {
    $link=Get-Item -LiteralPath (Join-Path $appRoot 'current') -Force
    if($request.legacyDirectory){
        if($link.LinkType){throw "$app current changed from a directory during preparation."}
    }elseif($link.LinkType -ne 'Junction' -or [string]$link.Target -ine $previous){throw "$app current destination changed."}
}

function Get-OwnedProcess {
    $paths=[Collections.Generic.List[string]]::new()
    $paths.Add([regex]::Escape("\apps\$app\current\"))
    if($previous){$paths.Add([regex]::Escape($previous+'\'))}
    $launcher=[regex]::Escape("\apps\$app\shared\Start-Service.ps1")+'"?\s+-Application\s+'+[regex]::Escape($app)+'\s*$'
    @(Get-CimInstance Win32_Process|Where-Object {
        $command=[string]$_.CommandLine
        $text=$command+"`n"+[string]$_.ExecutablePath
        $_.ProcessId -ne $PID -and ($command -match $launcher -or @($paths|Where-Object {$text -match $_}).Count -gt 0)
    })
}

function Wait-PortReleased {
    param([int]$Port,[int]$TimeoutSeconds=60)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{
        # Tailscale serve and the LAN proxy share the port on other addresses; the app binds loopback or wildcard.
        $owners=@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue|
            Where-Object {$_.OwningProcess -ne 4 -and $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::')})
        if($owners.Count -eq 0 -and @(Get-OwnedProcess).Count -eq 0){return}
        Start-Sleep -Seconds 1
    }while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "$app still holds port $Port or has running processes after the stop."
}

function Stop-HandPlacedApp {
    if($request.stop -eq 'managed'){
        $manifest=Read-LifecycleManifest -Path (Join-Path $previous 'deploy\application.json') -AppRoot $appRoot -ReleasePath $previous
        $runtime=Get-ReleaseRuntimePath -AppRoot $appRoot -ReleasePath $previous -Manifest $manifest
        Stop-ManagedApp -AppRoot $appRoot -ReleasePath $previous -Manifest $manifest -RuntimePath $runtime -TimeoutSeconds 60|Out-Null
    }else{
        Stop-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $request.task
        Start-Sleep -Seconds 2
        foreach($process in @(Get-OwnedProcess)){Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue}
    }
    Wait-PortReleased $request.originPort
}

function Start-HandPlacedApp {
    if($request.stop -eq 'managed'){Clear-AppMaintenance -AppRoot $appRoot -Confirm:$false}
    Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $request.task
}

try{
    if((Get-FileHash -LiteralPath $RequestPath).Hash.ToLowerInvariant() -ne $RequestSHA256){throw 'Release request hash mismatch.'}
    $request=Read-DeploymentJson $RequestPath
    if($request.app -ne $app -or $request.id -ne (Split-Path -Leaf $operation) -or $request.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or
        $request.releaseId -notmatch '^[a-f0-9]{12}-[a-f0-9]{8}$' -or $request.stop -notin @('managed','task') -or
        $request.task -notmatch '^SolutionDeploy-[a-z0-9-]+$'){throw 'Invalid release request.'}
    if($request.legacyDirectory){
        if($app -ne 'plex' -or $request.previousRelease){throw 'Only Plex converts a legacy directory.'}
        $previous=$null
    }else{
        if($request.previousRelease -notmatch '^[A-Za-z0-9._-]+$'){throw 'Invalid previous release id.'}
        $previous=Resolve-OwnedPath $appRoot ('releases\'+$request.previousRelease)
    }
    $release=Resolve-OwnedPath $appRoot ('releases\'+$request.releaseId)
    Assert-RequestCurrent
    Assert-PreviousCurrent
    if($Phase -eq 'Prepare'){
        $payload=Join-Path $operation 'payload.zip'
        if((Get-FileHash -LiteralPath $payload).Hash.ToLowerInvariant() -ne $request.payloadSHA256){throw 'Payload hash mismatch.'}
        if(Test-Path -LiteralPath $release){throw "Release folder already exists: $release"}
        $aclSource=if($previous){$previous}else{Join-Path $appRoot 'current'}
        [IO.Directory]::CreateDirectory($release)|Out-Null
        Set-Acl -LiteralPath $release -AclObject (Get-Acl -LiteralPath $aclSource)
        [IO.Compression.ZipFile]::ExtractToDirectory($payload,$release)
        if($request.hostInstall -eq 'npm-production'){
            $node=[string](Get-Item -LiteralPath 'C:\Files\ScoopApps\apps\nodejs\current').Target
            $exe=Join-Path $node 'node.exe'
            $cli=Join-Path $node 'node_modules\npm\bin\npm-cli.js'
            Invoke-DeploymentCommand $exe @($cli,'ci','--omit=dev','--ignore-scripts','--no-audit','--no-fund') $release -TimeoutSeconds $request.timeoutSeconds
            $result.hostInstall=@{node=$exe;sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()}
        }elseif($request.hostInstall){throw "Unknown host install step: $($request.hostInstall)"}
        $record=[ordered]@{sourceCommit=$request.sourceCommit;releaseId=$request.releaseId;operationId=$request.id
            payloadSHA256=$request.payloadSHA256;sealedLocal=(Get-Date).ToString('o')}
        if($request.stop -eq 'managed'){
            $old=Read-DeploymentJson (Join-Path $previous 'release.json')
            $record.runtimePath=$old.runtimePath;$record.runtimeSHA256=$old.runtimeSHA256
        }
        Write-DeploymentJson (Join-Path $release 'release.json') $record -CreateNew
        $result.releaseId=$request.releaseId
    }else{
        $prepared=Read-DeploymentJson (Join-Path $operation 'prepare-result.json')
        if($prepared.status -ne 'Succeeded' -or $prepared.requestSHA256 -ne $RequestSHA256){throw 'No matching prepared release.'}
        $record=Read-DeploymentJson (Join-Path $release 'release.json')
        if($record.sourceCommit -ne $request.sourceCommit -or $record.operationId -ne $request.id){throw 'Prepared release changed.'}
        $lock=Get-DeploymentLock (Join-Path $appRoot 'state\deployment.lock')
        Assert-PreviousCurrent
        $stopped=$true
        Stop-HandPlacedApp
        Assert-RequestCurrent
        Assert-PreviousCurrent
        $current=Join-Path $appRoot 'current'
        # The service account reads through current, so the new junction keeps the old link's ACL.
        $linkAcl=Get-Acl -LiteralPath $current
        $legacy=$null
        if($request.legacyDirectory){
            $legacy=Join-Path $appRoot ('releases\legacy-'+$request.id.Substring(0,8))
            Move-Item -LiteralPath $current -Destination $legacy
            $result.legacyRelease=Split-Path -Leaf $legacy
        }else{
            [IO.Directory]::Delete($current,$false)
        }
        try{
            New-Item -ItemType Junction -Path $current -Target $release|Out-Null
            Set-Acl -LiteralPath $current -AclObject $linkAcl
        }catch{
            if((Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue).LinkType -eq 'Junction'){[IO.Directory]::Delete($current,$false)}
            if(-not (Test-Path -LiteralPath $current)){
                if($legacy){Move-Item -LiteralPath $legacy -Destination $current}
                else{New-Item -ItemType Junction -Path $current -Target $previous|Out-Null;Set-Acl -LiteralPath $current -AclObject $linkAcl}
            }
            throw
        }
        $switched=$true
        Start-HandPlacedApp
        Write-DeploymentJson (Join-Path $appRoot 'state\common-release.json') @{
            releaseId=$request.releaseId;sourceCommit=$request.sourceCommit;component='web';activatedLocal=(Get-Date).ToString('o')
            previousRelease=if($request.legacyDirectory){$result.legacyRelease}else{$request.previousRelease}
            payloadSHA256=$request.payloadSHA256;operationId=$request.id}
        $result.releaseId=$request.releaseId
    }
    $result.status='Succeeded';$result.completedLocal=(Get-Date).ToString('o')
}catch{
    $result.status='Failed';$result.error=$_.Exception.Message
    if($stopped -and -not $switched){
        try{Start-HandPlacedApp;$result.recovery='Previous release restarted.'}catch{$result.recovery="Restart failed: $($_.Exception.Message)"}
    }elseif($switched){$result.recovery='New release is current. No automatic rollback was attempted.'}
    Write-Error -Message $result.error -ErrorAction Continue
}finally{
    if($lock){$lock.Dispose()}
    Write-DeploymentJson $resultPath $result
}
if($result.status -ne 'Succeeded'){exit 1}
