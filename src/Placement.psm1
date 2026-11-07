#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SshTransport.psm1') -DisableNameChecking
$script:SourceContentTimeoutSeconds=300

function Get-PlacementRoot {
    param([Parameter(Mandatory)][hashtable]$Plan)
    $server=$Plan.databaseTarget
    Get-DeploymentRemotePath $server.host ($server.root+'\control')
}

function Get-PlacementLease {
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [ValidateRange(0,86400)][int]$WaitTimeoutSeconds=0,
        [ValidateRange(0.1,60)][double]$RetryIntervalSeconds=5
    )
    $root=Get-PlacementRoot $Plan
    if(-not (Test-Path -LiteralPath (Join-Path $root 'installation.json'))){throw 'Provision the protected authority host executor before submitting operations.'}
    $installation=Read-DeploymentJson (Join-Path $root 'installation.json')
    if(-not $Plan.databaseHostSnapshot.verified -or $installation.identity -ne $Plan.databaseHostSnapshot.identity -or
        $installation.root -ne $Plan.databaseTarget.root -or $installation.host -ine $Plan.databaseTarget.host){
        throw 'Central authority installation differs from the verified database host/root.'
    }
    Get-DeploymentLock (Join-Path $root ("transitions\$($Plan.environment)\$($Plan.app).lock")) `
        -WaitTimeoutSeconds $WaitTimeoutSeconds -RetryIntervalSeconds $RetryIntervalSeconds
}

function Assert-PlacementUnchanged {
    param([Parameter(Mandatory)][hashtable]$Plan,[switch]$Verify,[switch]$ResumePrepared)
    $path=Join-Path (Get-PlacementRoot $Plan) ("placements\$($Plan.environment)\$($Plan.app).json")
    $actual=Read-OptionalRemoteRecord $path
    if($Verify -and $actual -and $actual.status -eq 'Active' -and $actual.host -ieq $Plan.target.host -and $actual.planHash -eq $Plan.planHash){return}
    if($ResumePrepared -and $actual -and $actual.status -eq 'Prepared' -and $actual.host -ieq $Plan.target.host -and
        $actual.hostIdentity -eq $Plan.hostSnapshot.identity -and $actual.planHash -eq $Plan.planHash -and
        $actual.operationId -eq $Plan.id -and $actual.releaseId -eq $Plan.releaseId){return}
    if($ResumePrepared){throw 'Final cutover requires the exact retained Prepared placement authority.'}
    if((ConvertTo-CanonicalJson $actual) -ne (ConvertTo-CanonicalJson $Plan.placementAuthority)){
        throw 'Application placement changed or a prior transition is unresolved. Replan after inspecting authority.'
    }
}

function Set-PlacementTransition {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][ValidateSet('Pending','Prepared','Active','Unknown')][string]$Status,
        [string]$ReleaseId=$Plan.releaseId)
    $path=Join-Path (Get-PlacementRoot $Plan) ("placements\$($Plan.environment)\$($Plan.app).json")
    Write-DeploymentJson $path @{
        status=$Status;host=$Plan.target.host;hostIdentity=$Plan.hostSnapshot.identity;previousHost=$Plan.observedHost;app=$Plan.app
        environment=$Plan.environment;operationId=$Plan.id;planHash=$Plan.planHash
        releaseId=$ReleaseId;previousPlanHash=$(if($Plan.placementAuthority){$Plan.placementAuthority.planHash}else{$null})
        updatedLocal=(Get-Date).ToString('o')
    }
}

function Test-RemoteSourceFence {
    [CmdletBinding(DefaultParameterSetName='Fence')]
    param([Parameter(Mandatory,Position=0)][hashtable]$Plan,[Parameter(Mandatory,Position=1)][hashtable]$Fence,
        [Parameter(ParameterSetName='Continuity')][switch]$Continuity,
        [Parameter(ParameterSetName='TransferContinuity')][switch]$TransferContinuity,
        [string]$TransferSHA256,[string]$ImportReceiptSHA256,[hashtable]$TransferProof)
    if($Continuity -and $TransferContinuity){throw 'Select exactly one continuity stage.'}
    $checkingContent=$Continuity -or $TransferContinuity
    $manifest=$Plan.transferManifest
    if($Fence.operationId -ne $Plan.id -or $Fence.host -ine $Plan.observedHost -or
        $Fence.writersStopped -ne $true -or $Fence.restartPathsDisabled -ne $true -or
        $Fence.writerInventoryReviewed -ne $true -or $Fence.sourceProcessId -lt 1){
        throw 'Source fence does not identify the reviewed stopped writer and restart paths.'
    }
    $age=[DateTimeOffset]::Now-[DateTimeOffset]::Parse($Fence.verifiedLocal)
    if(($age -gt [TimeSpan]::FromMinutes(5) -and -not $checkingContent) -or $age -lt [TimeSpan]::Zero){throw 'Source fence timestamp is stale or in the future.'}
    if($checkingContent -and ($TransferSHA256 -notmatch '^[a-f0-9]{64}$' -or
        ($Continuity -and $ImportReceiptSHA256 -notmatch '^[a-f0-9]{64}$') -or -not $TransferProof -or
        $TransferProof.planHash -ne $Plan.planHash -or $TransferProof.operationId -ne $Plan.id -or
        (Get-Sha256Text (ConvertTo-CanonicalJson $TransferProof.fence)) -ne (Get-Sha256Text (ConvertTo-CanonicalJson $Fence)))){
        throw 'Continuity verification requires the bound transfer proof and exact transfer and import-receipt hashes.'
    }
    if($checkingContent){Invoke-FrozenSourceContentCheck $Plan $TransferProof}
    $session=New-DeploymentSession -ComputerName $Plan.observedHost -OperationTimeoutSec 20
    try{
        $product=Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystemProduct -Property UUID -OperationTimeoutSec 20
        if(-not $Plan.sourceHostSnapshot.verified -or $product.UUID -ne $Plan.sourceHostSnapshot.identity){throw 'Source hardware identity differs from the reviewed plan.'}
        if($Plan.transitionKind -eq 'ManagedMove'){
            $sourceHost=$Plan.target.hosts[$Plan.observedHost]
            if(-not $Plan.placementAuthority.ContainsKey('hostIdentity') -or $product.UUID -ne $Plan.placementAuthority.hostIdentity){throw 'Managed source hardware identity differs from placement authority.'}
            $appRoot=$sourceHost.root+"\apps\$($Plan.app)"
            $share=Get-DeploymentRemotePath $sourceHost.host $appRoot
            if(-not (Test-Path -LiteralPath (Join-Path $share 'state\maintenance.json'))){throw 'Managed source must remain in durable maintenance.'}
            $active=Read-DeploymentJson (Join-Path $share 'state\active.json')
            if($active.planHash -ne $Plan.placementAuthority.planHash -or $active.releaseId -ne $Plan.placementAuthority.releaseId){throw 'Managed source release differs from central authority.'}
            $processRoot=$appRoot
        }else{$processRoot=$manifest.source.root}
        $taskPath=if($Plan.transitionKind -eq 'ManagedMove'){'\JimlerTech\'}else{'\'}
        $allTasks=@(Get-CimInstance -CimSession $session -Namespace 'Root\Microsoft\Windows\TaskScheduler' -ClassName MSFT_ScheduledTask -OperationTimeoutSec 20)
        foreach($name in $manifest.source.tasks){
            $tasks=@($allTasks|Where-Object {$_.TaskName -eq $name -and $_.TaskPath -eq $taskPath})
            if($tasks.Count -ne 1 -or $tasks[0].State -ne 1){throw 'Source restart path is enabled or ambiguous.'}
        }
        $original=@(Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter "ProcessId=$($Fence.sourceProcessId)" -Property ProcessId -OperationTimeoutSec 20)
        if($original.Count){throw 'Original source process still exists or its PID was reused.'}
        $listeners=@(Get-CimInstance -CimSession $session -Namespace root\StandardCimv2 -ClassName MSFT_NetTCPConnection -Filter "State=2 AND LocalPort=$($manifest.launch.port)" -OperationTimeoutSec 20)
        if($listeners.Count){throw 'Source app port is still listening.'}
        $processes=@(Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter "Name='node.exe' OR Name='python.exe' OR Name='pythonw.exe' OR Name='pwsh.exe' OR Name='powershell.exe'" -Property CommandLine -OperationTimeoutSec 20|
            Where-Object {$_.CommandLine -and ($_.CommandLine.IndexOf($processRoot,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                ($Fence.ContainsKey('writerCommandLines') -and $_.CommandLine -in $Fence.writerCommandLines) -or
                ($Fence.ContainsKey('writerCommandPattern') -and $_.CommandLine -match $Fence.writerCommandPattern))})
        if($processes.Count){throw 'Source application still has a live process.'}
        $result=@{verified=$true;operationId=$Plan.id;sourceHost=$Plan.observedHost;verifiedLocal=(Get-Date).ToString('o');fenceHash=(Get-Sha256Text (ConvertTo-CanonicalJson $Fence))}
        if($Continuity){
            $result.kind='SourceContinuity';$result.planHash=$Plan.planHash
            $result.transferSHA256=$TransferSHA256;$result.importReceiptSHA256=$ImportReceiptSHA256
            $result.sourceContentVerified=$true
        }
        if($TransferContinuity){
            $result.kind='FrozenTransferContinuity';$result.planHash=$Plan.planHash
            $result.transferSHA256=$TransferSHA256;$result.sourceContentVerified=$true
        }
        $result
    }finally{Close-DeploymentSession $session}
}

function Test-FrozenSourceContent {
    param([hashtable]$Plan,[hashtable]$Proof)
    Import-Module (Join-Path $PSScriptRoot 'Transfer.psm1') -DisableNameChecking
    $directoryManifest=@{
        source=$Plan.transferManifest.source
        state=@($Plan.transferManifest.state|Where-Object kind -eq directory)
    }
    $inventory=Get-StateInventory $directoryManifest -SourceHost $Plan.observedHost
    $expected=@($Proof.files|Where-Object {
        $target=$_.target
        @($directoryManifest.state|Where-Object {$target.StartsWith($_.target+'\',[StringComparison]::OrdinalIgnoreCase)}).Count
    }|ForEach-Object target|Sort-Object)
    $actual=@($inventory.files|ForEach-Object target|Sort-Object)
    $expectedDirectories=@($Proof.directories|Sort-Object)
    if(-not $inventory.complete -or (ConvertTo-CanonicalJson $actual) -ne (ConvertTo-CanonicalJson $expected) -or
        (ConvertTo-CanonicalJson @($inventory.directories|Sort-Object)) -ne (ConvertTo-CanonicalJson $expectedDirectories)){
        throw 'Source directory inventory changed since export.'
    }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    foreach($file in $Proof.files){
        if($clock.Elapsed.TotalSeconds -gt $script:SourceContentTimeoutSeconds){throw 'Source content verification exceeded its five-minute budget.'}
        $declarations=@($Plan.transferManifest.state|Where-Object {
            $_.target -eq $file.target -or ($_.kind -eq 'directory' -and $file.target.StartsWith($_.target+'\',[StringComparison]::OrdinalIgnoreCase))
        })
        if($declarations.Count -ne 1){throw 'Source content has no unique declaration.'}
        $declaration=$declarations[0]
        $source=if([IO.Path]::IsPathFullyQualified($declaration.source)){$declaration.source}else{Resolve-OwnedPath $Plan.transferManifest.source.root $declaration.source}
        if($declaration.kind -eq 'directory'){$source=Resolve-OwnedPath $source $file.target.Substring($declaration.target.Length+1)}
        $share=Get-DeploymentRemotePath $Plan.observedHost $source
        if($file.kind -eq 'sqlite'){
            if(-not $file.ContainsKey('sourceHashes')){throw 'Source snapshot lacks original database/sidecar hashes. A new reviewed export is required.'}
            foreach($key in @('main','-wal','-shm','-journal')){
                $path=if($key -eq 'main'){$share}else{$share+$key}
                $actual=if(Test-Path -LiteralPath $path){(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}else{$null}
                if($actual -ne $file.sourceHashes[$key]){throw 'Source SQLite content changed since export.'}
            }
        }else{
            if((Get-FileHash -LiteralPath $share).Hash.ToLowerInvariant() -ne $file.sha256){throw 'Source file content changed since export.'}
        }
    }
}

function Invoke-FrozenSourceContentCheck {
    param([hashtable]$Plan,[hashtable]$Proof)
    $job=Start-Job -ScriptBlock {
        param($Module,$Plan,$Proof)
        Import-Module $Module -DisableNameChecking
        Test-FrozenSourceContent $Plan $Proof
    } -ArgumentList $MyInvocation.MyCommand.Module.Path,$Plan,$Proof
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try{
        while(-not (Wait-Job $job -Timeout 5)){
            Write-Host ("Verifying original source content: {0:n0}s" -f $clock.Elapsed.TotalSeconds)
            if($clock.Elapsed.TotalSeconds -ge $script:SourceContentTimeoutSeconds){throw 'Original source content verification timed out.'}
        }
        if($job.State -ne 'Completed'){throw 'Original source content verification failed.'}
        Receive-Job $job -ErrorAction Stop | Out-Null
    }finally{Stop-Job $job;Remove-Job $job}
}

Export-ModuleMember -Function Get-PlacementRoot,Get-PlacementLease,Assert-PlacementUnchanged,Set-PlacementTransition,Test-RemoteSourceFence,Test-FrozenSourceContent
