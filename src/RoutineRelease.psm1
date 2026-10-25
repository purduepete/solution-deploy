#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PostgreSQL.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Lifecycle.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ReleaseBackup.psm1') -DisableNameChecking

function Assert-RoutineReleaseConsent {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][string]$Action)
    if(-not $Plan.ContainsKey('routineRelease') -or $Plan.routineRelease -ne $true){throw 'Routine release consent requires a routine plan.'}
    if(-not $Plan.ContainsKey('routineConsent')){throw 'Routine release consent is missing.'}
    $consent=$Plan.routineConsent
    foreach($key in @('app','environment','target','sourceCommit','approvedBy','reason','expiresLocal','actions','dataActionsReviewed')){
        if(-not $consent.ContainsKey($key)){throw "Routine consent missing $key."}
    }
    if($consent.app -ne $Plan.app -or $consent.environment -ne $Plan.environment -or
        $consent.target -ine $Plan.target.host -or $consent.sourceCommit -cne $Plan.sourceCommit -or
        $Plan.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $Action -notin $consent.actions -or
        [string]::IsNullOrWhiteSpace($consent.approvedBy) -or [string]::IsNullOrWhiteSpace($consent.reason) -or
        $consent.dataActionsReviewed -ne $true -or [DateTimeOffset]::Parse($consent.expiresLocal) -le [DateTimeOffset]::Now){
        throw 'Routine consent is expired or differs from the exact reviewed release scope.'
    }
    if($Plan.transitionKind -ne 'ManagedDeploy' -or $Plan.operation -ne 'Deploy' -or -not $Plan.currentRelease){
        throw 'Routine releases require an existing same-host managed deployment.'
    }
}

function Get-RoutineMigrationDigest {
    param([Parameter(Mandatory)][hashtable]$Release)
    # Dependency packages and their generated caches aren't application migrations.
    $files=@($Release.files | Where-Object {
        $_.path -notmatch '(?i)(^|\\)(node_modules|\.venv)\\' -and $_.path -match '(?i)(^|\\)(migrations?|postgresql|schema)(\\|\.|$)|\.sql$'
    } | Sort-Object path | ForEach-Object {@{path=$_.path;sha256=$_.sha256}})
    if(-not $files.Count){throw 'Routine release has no sealed migration/schema baseline.'}
    Get-Sha256Text (ConvertTo-CanonicalJson $files)
}

function Assert-RoutineManifest {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][hashtable]$OldManifest,[Parameter(Mandatory)][hashtable]$NextManifest)
    if((ConvertTo-CanonicalJson $NextManifest) -cne (ConvertTo-CanonicalJson $Plan.manifest)){throw 'Application manifest changed; use the reviewed deployment path.'}
    # The migration digest skips node_modules, so routine release accepts only a plain migrations path outside it.
    # Allowlisting segment characters rules out Windows aliases such as trailing dots or spaces, streams and 8.3 names.
    if($NextManifest.ContainsKey('database')){
        $segments=([string]$NextManifest.database.migrationsDirectory) -split '[\\/]'
        if(@($segments | Where-Object {$_ -cnotmatch '^[A-Za-z0-9_-]+$' -or $_ -ieq 'node_modules'}).Count){
            throw 'Routine release needs a plain migrations directory outside node_modules; use the reviewed deployment path.'
        }
    }
    if((ConvertTo-CanonicalJson $OldManifest) -ceq (ConvertTo-CanonicalJson $NextManifest)){return}
    $consent=if($Plan.ContainsKey('routineConsent')){$Plan.routineConsent}else{@{}}
    if(-not $consent.ContainsKey('approvedManifestSHA256') -or $consent.approvedManifestSHA256 -cnotmatch '^[a-f0-9]{64}$' -or
        $consent.approvedManifestSHA256 -cne $Plan.manifestHash){throw 'Application manifest changed; use the reviewed deployment path.'}
    # An operator-approved manifest change may alter build commands only.
    $oldRest=@{}+$OldManifest; $nextRest=@{}+$NextManifest; [void]$oldRest.Remove('build'); [void]$nextRest.Remove('build')
    if((ConvertTo-CanonicalJson $oldRest) -cne (ConvertTo-CanonicalJson $nextRest)){throw 'An approved manifest change may alter only build commands; use the reviewed deployment path.'}
}

function Assert-RoutineReleaseEligibility {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][hashtable]$Approval,
        [Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$ReleasePath)
    Assert-RoutineReleaseConsent $Plan Preflight
    foreach($field in @('psqlPath','psqlSHA256','postgresPassFile','postgresRuntimeRole','postgresEndpointSHA256','expectedSchemaFingerprint','migrationSqlSHA256')){
        if(-not $Approval.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$Approval[$field])){throw "Routine activation approval missing $field."}
    }
    if($Plan.target.host -ine $Plan.databaseTarget.host -or $Plan.hostSnapshot.identity -ne $Plan.databaseHostSnapshot.identity){
        throw 'Routine release currently supports the existing colocated database only; use the reviewed deployment path.'
    }
    $oldPath=Resolve-OwnedPath $AppRoot ('releases\'+$Plan.currentRelease.releaseId)
    $old=Test-ReleaseInventory $oldPath
    $next=Test-ReleaseInventory $ReleasePath
    if($old.sourceCommit -ne $Plan.currentRelease.sourceCommit -or $old.planHash -ne $Plan.currentRelease.planHash -or
        $next.sourceCommit -ne $Plan.sourceCommit -or $next.planHash -ne $Plan.planHash -or $next.manifestHash -ne $Plan.manifestHash){
        throw 'Routine release inventory does not match the deployed and requested commits.'
    }
    $oldManifest=Get-Manifest (Join-Path $oldPath 'deploy\application.json')
    $nextManifest=Get-Manifest (Join-Path $ReleasePath 'deploy\application.json')
    Assert-RoutineManifest $Plan $oldManifest $nextManifest
    $migrationDigest=Get-RoutineMigrationDigest $old
    if($migrationDigest -ne (Get-RoutineMigrationDigest $next)){throw 'Migration or schema files changed; independent database review is required.'}
    $baselinePath=Join-Path $AppRoot 'state\verification.json'
    $baseline=Read-DeploymentJson $baselinePath
    if($baseline.planHash -notin @($Plan.currentRelease.planHash,$Plan.planHash) -or
        $baseline.database.schemaFingerprint -ne $Approval.expectedSchemaFingerprint -or
        $baseline.database.endpoint.endpointSHA256 -ne $Approval.postgresEndpointSHA256){
        throw 'Routine release database baseline differs from the verified deployment.'
    }
    if((Get-FileHash -LiteralPath $next.runtimePath).Hash.ToLowerInvariant() -ne $next.runtimeSHA256){throw 'Pinned runtime changed.'}
    $account=$env:COMPUTERNAME+'\'+$Plan.target.apps[$Plan.app].account
    $installation=Read-DeploymentJson (Join-Path (Split-Path -Parent (Split-Path -Parent $AppRoot)) 'control\installation.json')
    Assert-AppBootTask -AppId $Plan.app -AppRoot $AppRoot -PowerShellPath $installation.powerShellPath -ExpectedAccount $account | Out-Null
    @{migrationDigest=$migrationDigest;release=$next}
}

function Get-RoutineDatabaseEvidence {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][hashtable]$Approval,
        [Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$ReleasePath,
        [switch]$Create)
    $eligibility=Assert-RoutineReleaseEligibility $Plan $Approval $AppRoot $ReleasePath
    if((Get-FileHash -LiteralPath $Approval.psqlPath).Hash.ToLowerInvariant() -ne $Approval.psqlSHA256){throw 'PostgreSQL verifier changed.'}
    $role=(Get-PostgresRoleNames $Plan.manifest.database.name).runtime
    if($Approval.postgresRuntimeRole -ne $role){throw 'Routine database verifier must use the allocated runtime role.'}
    $policy=Get-PostgresConnectionPolicy $Plan
    $connection=Get-PostgresConnectionParameters -Policy $policy -ApprovedEndpointSHA256 $Approval.postgresEndpointSHA256
    $manifest=Read-LifecycleManifest -Path (Join-Path $ReleasePath 'deploy\application.json') -AppRoot $AppRoot -ReleasePath $ReleasePath
    $runtime=Get-ReleaseRuntimePath -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $manifest
    $environment=Get-ManagedAppEnvironment -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $manifest -RuntimePath $runtime
    try {
        if(-not $environment.Contains('DATABASE_URL')){throw 'Runtime database configuration is missing.'}
        Assert-PostgresRuntimeConnectionString -ConnectionString $environment.DATABASE_URL -Policy $policy -Database $Plan.manifest.database.name -RuntimeRole $role | Out-Null
    }finally{$environment.Clear()}
    $passFile=Resolve-OwnedPath (Join-Path $AppRoot 'shared\secrets') $Approval.postgresPassFile
    $live=Get-PostgresDatabaseEvidence -Manifest $Plan.manifest -PsqlPath $Approval.psqlPath -PassFile $passFile -UserName $role -SolutionDatabases $Plan.solutionDatabases @connection
    if($live.schemaFingerprint -ne $Approval.expectedSchemaFingerprint){throw 'Live database schema differs from the deployed baseline.'}
    $backup=Get-ReleaseBackupEvidence -Database $Plan.manifest.database.name -ExpectedHost $Plan.databaseTarget.host
    $path=Join-Path $AppRoot ('state\routine-'+$Plan.id+'.json')
    if($Create){
        $record=@{kind='RoutineCompatibility';planHash=$Plan.planHash;database=$Plan.manifest.database.name
            schemaFingerprint=$live.schemaFingerprint;migrationDigest=$eligibility.migrationDigest
            endpointSHA256=$policy.EndpointSHA256;backup=$backup;verifiedLocal=(Get-Date).ToString('o')
            scope='Read-only compatibility check. Existing nightly backup restore validation retained with its original timestamps. No deployment import, restore or data fix performed.'}
        Write-DeploymentJson $path $record -CreateNew
    }else{
        foreach($key in @('databaseEvidencePath','databaseEvidenceSHA256')){if(-not $Approval.ContainsKey($key)){throw "Routine activation approval missing $key."}}
        $path=Resolve-OwnedPath (Join-Path $AppRoot 'state') $Approval.databaseEvidencePath
        if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $Approval.databaseEvidenceSHA256){throw 'Routine preflight evidence changed.'}
        $record=Read-DeploymentJson $path
        if($record.kind -ne 'RoutineCompatibility' -or $record.planHash -ne $Plan.planHash -or
            $record.database -ne $Plan.manifest.database.name -or $record.schemaFingerprint -ne $live.schemaFingerprint -or
            $record.migrationDigest -ne $eligibility.migrationDigest -or $record.endpointSHA256 -ne $policy.EndpointSHA256){
            throw 'Routine preflight evidence differs from the current release.'
        }
    }
    @{database=$live;databaseEvidencePath=(Split-Path $path -Leaf);databaseEvidenceSHA256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
}

Export-ModuleMember -Function Assert-RoutineReleaseConsent,Get-RoutineMigrationDigest,Assert-RoutineManifest,Assert-RoutineReleaseEligibility,Get-RoutineDatabaseEvidence
