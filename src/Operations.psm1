#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PostgreSQL.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Lifecycle.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Transfer.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'RoutineRelease.psm1') -DisableNameChecking

function Prepare-InitialCutover {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ExportDirectory,[Parameter(Mandatory)][string]$TransferSHA256)
    if($Plan.transitionKind -ne 'LegacyConversion' -or $Plan.currentRelease){throw 'Initial preparation only supports legacy adoption without an active target.'}
    foreach($relative in @('current','state\active.json','state\prepared-cutover.json','state\prepare-attempt.json','shared\run\process.json')){
        if(Test-Path -LiteralPath (Join-Path $AppRoot $relative)){throw 'Initial preparation was attempted or a target already exists. Inspect before retrying.'}
    }
    if(-not (Test-Path -LiteralPath (Join-Path $AppRoot 'state\maintenance.json'))){throw 'Initial preparation requires persisted maintenance.'}
    $releasePath=Resolve-OwnedPath $AppRoot ('releases\'+$Plan.releaseId)
    $release=Test-ReleaseInventory $releasePath
    if($release.manifestHash -ne $Plan.manifestHash -or
        (Get-FileHash -LiteralPath $release.runtimePath).Hash.ToLowerInvariant() -ne $release.runtimeSHA256){throw 'Initial release or runtime differs from the reviewed artifact.'}
    Write-DeploymentJson (Join-Path $AppRoot 'state\prepare-attempt.json') @{operationId=$Plan.id;planHash=$Plan.planHash;status='Started'} -CreateNew
    $proof=Import-FrozenState $Plan $ExportDirectory $AppRoot $TransferSHA256
    [IO.File]::Copy((Join-Path $ExportDirectory 'transfer.json'),(Join-Path $AppRoot 'state\prepared-transfer.json'),$false)
    New-Item -ItemType Junction -Path (Join-Path $AppRoot 'current') -Target $releasePath | Out-Null
    $receipt=@{
        status='Prepared';operationId=$Plan.id;planHash=$Plan.planHash;releaseId=$Plan.releaseId
        transferSHA256=$TransferSHA256;sourceFenceSHA256=(Get-Sha256Text (ConvertTo-CanonicalJson $proof.fence))
        preparedLocal=(Get-Date).ToString('o');runtimeStarted=$false
    }
    $receiptPath=Join-Path $AppRoot 'state\prepared-cutover.json'
    Write-DeploymentJson $receiptPath $receipt -CreateNew
    $hash=(Get-FileHash -LiteralPath $receiptPath).Hash.ToLowerInvariant()
    Assert-PreparedState $Plan $AppRoot $hash | Out-Null
    @{phase='Prepared';releaseId=$Plan.releaseId;preparedStateSHA256=$hash;runtimeStarted=$false}
}

function Assert-SourceContinuity {
    param([hashtable]$Plan,[hashtable]$Approval,[hashtable]$Verification,[hashtable]$Receipt)
    foreach($field in @('preparedStateSHA256','databaseEvidenceSHA256','transferSHA256','sourceFenceSHA256')){
        if(-not $Approval.ContainsKey($field) -or $Approval[$field] -notmatch '^[a-f0-9]{64}$'){throw "Final cutover approval missing $field."}
    }
    $age=[DateTimeOffset]::Now-[DateTimeOffset]::Parse($Verification.verifiedLocal)
    if($Verification.kind -ne 'SourceContinuity' -or $Verification.verified -ne $true -or $Verification.sourceContentVerified -ne $true -or
        $Verification.operationId -ne $Plan.id -or $Verification.planHash -ne $Plan.planHash -or
        $Verification.sourceHost -ine $Plan.observedHost -or $Verification.fenceHash -ne $Approval.sourceFenceSHA256 -or
        $Verification.transferSHA256 -ne $Approval.transferSHA256 -or $Verification.importReceiptSHA256 -ne $Approval.databaseEvidenceSHA256 -or
        $Receipt.transferSHA256 -ne $Approval.transferSHA256 -or $Receipt.sourceFenceSHA256 -ne $Approval.sourceFenceSHA256 -or
        $age -gt [TimeSpan]::FromMinutes(5) -or $age -lt [TimeSpan]::Zero){
        throw 'Final source continuity is missing, stale or not chained to the approved export and database receipt.'
    }
}

function Assert-DatabaseActivationEvidence {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][hashtable]$Approval,
        [Parameter(Mandatory)][string]$AppRoot,[string]$ReleasePath=(Join-Path $AppRoot 'current'))
    if($Plan.ContainsKey('routineRelease') -and $Plan.routineRelease -eq $true){
        $resolved=(Get-Item -LiteralPath $ReleasePath).FullName
        $item=Get-Item -LiteralPath $ReleasePath
        if($item.LinkType -eq 'Junction'){$resolved=[string]$item.Target}
        return (Get-RoutineDatabaseEvidence $Plan $Approval $AppRoot $resolved).database
    }
    foreach($field in @('psqlPath','psqlSHA256','postgresPassFile','postgresRuntimeRole','databaseEvidencePath','databaseEvidenceSHA256','expectedSchemaFingerprint','migrationSqlSHA256')){
        if(-not $Approval.ContainsKey($field)){throw "Database activation approval missing $field."}
    }
    if((Get-FileHash -LiteralPath $Approval.psqlPath).Hash.ToLowerInvariant() -ne $Approval.psqlSHA256){throw 'PostgreSQL verifier differs from the reviewed executable.'}
    $expectedRole=(Get-PostgresRoleNames $Plan.manifest.database.name).runtime
    if($Approval.postgresRuntimeRole -ne $expectedRole){throw 'Database runtime role does not match the per-solution allocation.'}
    $passFile=Resolve-OwnedPath (Join-Path $AppRoot 'shared\secrets') $Approval.postgresPassFile
    $evidencePath=Resolve-OwnedPath (Join-Path $AppRoot 'state') $Approval.databaseEvidencePath
    if((Get-FileHash -LiteralPath $evidencePath).Hash.ToLowerInvariant() -ne $Approval.databaseEvidenceSHA256){throw 'Database migration/restore evidence differs from the reviewed proof.'}
    $record=Read-DeploymentJson $evidencePath
    foreach($key in @('planHash','database','sourceTransferSHA256','migrationSqlSHA256','schemaFingerprint','parityValidated','backupRestoredAndValidated','independentReview')){
        if(-not $record.ContainsKey($key)){throw "Database evidence missing $key."}
    }
    if($record.planHash -ne $Plan.planHash -or $record.database -ne $Plan.manifest.database.name -or
        $record.parityValidated -ne $true -or $record.backupRestoredAndValidated -ne $true -or
        $record.schemaFingerprint -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace($record.independentReview)){
        throw 'Database import, schema fingerprint, independent review, or restore validation is incomplete.'
    }
    if($record.schemaFingerprint -ne $Approval.expectedSchemaFingerprint -or $record.migrationSqlSHA256 -ne $Approval.migrationSqlSHA256){
        throw 'Schema fingerprint or migration SQL differs from the exact reviewed activation approval.'
    }
    $hostAware=$Plan.ContainsKey('schemaVersion') -and $Plan.schemaVersion -eq 2
    $legacyImport=-not $hostAware -or $Plan.transitionKind -eq 'LegacyConversion'
    if($Plan.operation -eq 'Cutover' -and $legacyImport -and $record.sourceTransferSHA256 -ne $Approval.transferSHA256){throw 'Database import evidence belongs to a different source snapshot.'}
    $connection=@{}
    if($hostAware){
        foreach($key in @('transitionKind','databaseHostIdentity','databaseHost','legacyImportPerformed')){
            if(-not $record.ContainsKey($key)){throw "Host-aware database evidence missing $key."}
        }
        if($record.transitionKind -ne $Plan.transitionKind -or $record.databaseHostIdentity -ne $Plan.databaseHostSnapshot.identity -or
            $record.databaseHost -ine $Plan.databaseTarget.host -or $record.legacyImportPerformed -ne $legacyImport){
            throw 'Database evidence belongs to a different server or transition type.'
        }
        if(-not $legacyImport -and -not [string]::IsNullOrEmpty($record.sourceTransferSHA256)){throw 'Managed deployment evidence must preserve central data without replaying a legacy import.'}
        if($Plan.transitionKind -eq 'ManagedMove' -and (-not $record.ContainsKey('centralDatabasePreserved') -or $record.centralDatabasePreserved -ne $true)){
            throw 'Managed host movement requires explicit central database preservation evidence.'
        }
        if(-not $Approval.ContainsKey('postgresEndpointSHA256')){throw 'Activation requires the reviewed application database endpoint.'}
        $policy=Get-PostgresConnectionPolicy -Plan $Plan
        $certificate=@{}
        if($policy.Mode -eq 'Remote'){
            foreach($key in @('postgresSslRootCert','postgresSslRootCertSHA256')){if(-not $Approval.ContainsKey($key)){throw "Remote activation approval missing $key."}}
            $certificate=@{SslRootCert=$Approval.postgresSslRootCert;SslRootCertSHA256=$Approval.postgresSslRootCertSHA256}
        }
        $connection=Get-PostgresConnectionParameters -Policy $policy -ApprovedEndpointSHA256 $Approval.postgresEndpointSHA256 @certificate
        $runtimeManifest=Read-LifecycleManifest -Path (Join-Path $ReleasePath 'deploy\application.json') -AppRoot $AppRoot -ReleasePath $ReleasePath
        $runtime=Get-ReleaseRuntimePath -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $runtimeManifest
        $environment=Get-ManagedAppEnvironment -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $runtimeManifest -RuntimePath $runtime
        $urlOptions=@{}
        if($policy.Mode -eq 'Remote'){$urlOptions.SslRootCert=$Approval.postgresSslRootCert}
        try{
            if(-not $environment.Contains('DATABASE_URL') -or [string]::IsNullOrWhiteSpace($environment.DATABASE_URL)){throw 'The actual runtime environment has no DATABASE_URL.'}
            Assert-PostgresRuntimeConnectionString -ConnectionString $environment.DATABASE_URL -Policy $policy -Database $Plan.manifest.database.name -RuntimeRole $expectedRole @urlOptions|Out-Null
        }finally{$environment.Clear()}
        $connection.SolutionDatabases=$Plan.solutionDatabases
    }
    $live=Get-PostgresDatabaseEvidence -Manifest $Plan.manifest -PsqlPath $Approval.psqlPath -PassFile $passFile -UserName $expectedRole @connection
    if($live.schemaFingerprint -ne $record.schemaFingerprint){throw 'Database schema changed after migration validation.'}
    $live
}

function Start-ReviewedAppTask {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][hashtable]$Approval,
        [Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$ReleaseId,[int]$TimeoutSeconds=90)
    $current=Join-Path $AppRoot 'current'
    $manifest=Read-LifecycleManifest -Path (Join-Path $current 'deploy\application.json') -AppRoot $AppRoot -ReleasePath $current
    $runtime=Get-ReleaseRuntimePath -AppRoot $AppRoot -ReleasePath $current -Manifest $manifest
    $account=$env:COMPUTERNAME+'\'+$Plan.target.apps[$Plan.app].account
    Assert-AppBootTask -AppId $Plan.app -AppRoot $AppRoot -PowerShellPath $PowerShellPath -ExpectedAccount $account | Out-Null
    $database=Assert-DatabaseActivationEvidence $Plan $Approval $AppRoot
    $authorityPath=Join-Path $AppRoot 'state\authority.json'
    Write-DeploymentJson $authorityPath @{operationId=$Plan.id;targetMayHaveWritten=$true;host=$env:COMPUTERNAME;database=$Plan.manifest.database.name;startedLocal=(Get-Date).ToString('o')}
    Clear-AppMaintenance -AppRoot $AppRoot
    try{
        Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName ('SolutionDeploy-'+$Plan.app) -ErrorAction Stop
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $identity=$null
        while($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds){
            $identity=Test-ManagedAppIdentity -AppRoot $AppRoot -ReleasePath $current -Manifest $manifest -RuntimePath $runtime
            if($identity.Verified -and $identity.ListenerOwned){break}
            if($identity.Status -in @('Foreign','Untrusted')){throw 'Started app identity cannot be trusted.'}
            Write-Host ("Waiting for limited-account app identity, elapsed {0:n0}s" -f $clock.Elapsed.TotalSeconds)
            Start-Sleep -Seconds 2
        }
        if(-not $identity -or -not $identity.Verified -or -not $identity.ListenerOwned){throw 'Limited-account boot task did not produce a verified listener-owning app process before its deadline.'}
        $ready=Test-AppReadiness -Port $manifest.launch.port -Path $manifest.readiness.path -Expected $manifest.readiness.expected -TimeoutSeconds 30
        if(-not $ready.Ready){throw 'Application readiness failed after activation. Target may have written; do not restart a stale source.'}
        $headless=Test-ManagedAppHeadless -AppRoot $AppRoot -ReleasePath $current -Manifest $manifest -RuntimePath $runtime
        if($headless.Result -eq 'NotHeadless'){throw 'Application owns a visible or non-headless console window. Keep maintenance and inspect the launcher.'}
        if($headless.Result -eq 'Unverifiable'){Write-Warning 'Windowless startup could not be verified from this session. Interactive target-host acceptance remains required.'}
        $result=@{
            app=$Plan.app;releaseId=$ReleaseId;planHash=$Plan.planHash;host=$env:COMPUTERNAME
            identity=@{verified=$identity.Verified;pid=$identity.Pid;releasePath=$identity.ReleasePath;runtimePath=$identity.RuntimePath}
            readiness=@{ready=$ready.Ready;statusCode=$ready.StatusCode}
            database=$database;windowless=$headless;status='RuntimeVerified';externalAcceptance='Pending';verifiedLocal=(Get-Date).ToString('o')
        }
        Write-DeploymentJson (Join-Path $AppRoot 'state\verification.json') $result
        $result
    }catch{
        Write-DeploymentJson (Join-Path $AppRoot 'state\maintenance.json') @{operationId=$Plan.id;reason='Activation failed; target may have written. Review authority before rollback.'}
        throw
    }
}

function Test-ReviewedAppRuntime {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][hashtable]$Approval,
        [Parameter(Mandatory)][string]$AppRoot)
    if(Test-Path -LiteralPath (Join-Path $AppRoot 'state\maintenance.json')){throw 'Application is in maintenance; live verification cannot pass.'}
    $active=Read-DeploymentJson (Join-Path $AppRoot 'state\active.json')
    if($active.planHash -ne $Plan.planHash){throw 'Active release is not the approved deployment.'}
    $path=Resolve-OwnedPath $AppRoot ('releases\'+$active.releaseId)
    Test-ReleaseInventory $path|Out-Null
    $current=Join-Path $AppRoot 'current'
    $manifest=Read-LifecycleManifest -Path (Join-Path $current 'deploy\application.json') -AppRoot $AppRoot -ReleasePath $current
    $runtime=Get-ReleaseRuntimePath -AppRoot $AppRoot -ReleasePath $current -Manifest $manifest
    $identity=Test-ManagedAppIdentity -AppRoot $AppRoot -ReleasePath $current -Manifest $manifest -RuntimePath $runtime
    if(-not $identity.Verified -or -not $identity.ListenerOwned -or $identity.ReleasePath -ine $path){throw 'Runtime identity, listener, or active release verification failed.'}
    $ready=Test-AppReadiness -Port $manifest.launch.port -Path $manifest.readiness.path -Expected $manifest.readiness.expected -TimeoutSeconds 30
    if(-not $ready.Ready){throw 'Live local application readiness failed.'}
    $headless=Test-ManagedAppHeadless -AppRoot $AppRoot -ReleasePath $current -Manifest $manifest -RuntimePath $runtime
    if($headless.Result -eq 'NotHeadless'){throw 'Live application has a visible or non-headless console window.'}
    if($headless.Result -eq 'Unverifiable'){Write-Warning 'Windowless verification needs interactive target-host acceptance.'}
    $database=Assert-DatabaseActivationEvidence $Plan $Approval $AppRoot
    @{
        status='RuntimeVerified';externalAcceptance='Pending';app=$Plan.app;host=$env:COMPUTERNAME
        planHash=$Plan.planHash;releaseId=$active.releaseId;database=$database;windowless=$headless
        identity=@{verified=$true;pid=$identity.Pid;releasePath=$identity.ReleasePath}
        readiness=@{ready=$true;statusCode=$ready.StatusCode};verifiedLocal=(Get-Date).ToString('o')
    }
}

Export-ModuleMember -Function Prepare-InitialCutover,Assert-SourceContinuity,Assert-DatabaseActivationEvidence,Start-ReviewedAppTask,Test-ReviewedAppRuntime
