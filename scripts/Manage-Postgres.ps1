#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Preflight','PlanProvisioning','ApplySql','Evidence','Backup','RestoreValidation')][string]$Action,
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ToolDirectory,
    [Parameter(Mandatory)][string]$PassFile,
    [Parameter(Mandatory)][string]$UserName,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$SnapshotPath,
    [string]$SnapshotUserName,
    [string]$SnapshotPassFile,
    [string]$ApprovalPath,
    [string]$SqlPath,
    [string]$Database,
    [string]$OwnerRole,
    [string]$BackupPath,
    [switch]$Transactional,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\PostgreSQL.psm1') -DisableNameChecking
$plan=Read-DeploymentJson $PlanPath
if($plan.planHash -ne (Get-PlanDigest $plan)){throw 'Deployment plan was changed.'}
# Administrative SQL, backup, restore, and evidence run only on the verified database host over loopback.
# plan.target.host is the app host and may be a different computer when plan.databaseTarget is present.
$databaseHost=(Get-PostgresConnectionPolicy -Plan $plan).DatabaseHost
$policy=Get-PostgresConnectionPolicy -Plan $plan -ClientHost $databaseHost
if($policy.Mode -ne 'Loopback'){throw 'Database operations must use loopback on the database host.'}
$hostIdentity=$policy.DatabaseHostIdentity
if($env:COMPUTERNAME -ine $policy.DatabaseHost -or (Get-CimInstance Win32_ComputerSystemProduct -Property UUID).UUID -ne $hostIdentity){throw 'Database operations must run on the approved, identity-verified database host.'}
$port=$policy.Port
$psql=Join-Path $ToolDirectory 'psql.exe'
if($Action -in @('Preflight','PlanProvisioning')){
    if($Execute){throw 'This action is read-only and does not accept -Execute.'}
    $snapshot=Get-PostgresSnapshot -PsqlPath $psql -PassFile $PassFile -UserName $UserName -HostIdentity $hostIdentity -Port $port
    if($Action -eq 'Preflight'){Write-DeploymentJson $OutputPath $snapshot;return $snapshot}
    $provision=Get-PostgresProvisioningPlan $plan.manifest $snapshot
    if(Test-Path -LiteralPath $OutputPath){throw 'Choose a new provisioning-plan output path.'}
    Write-DeploymentJson $OutputPath $provision
    $provision
    return
}
if(-not $ApprovalPath){throw 'Database actions require a reviewed exact-action approval file, even for previews.'}
$approval=Read-DeploymentJson $ApprovalPath
foreach($field in @('planHash','action','hostIdentity','database','independentReview','expiresLocal','toolSHA256','userName')){
    if(-not $approval.ContainsKey($field)){throw "Database action approval missing $field."}
}
if($approval.planHash -ne $plan.planHash -or $approval.action -ne $Action -or $approval.hostIdentity -ne $hostIdentity -or
    [DateTimeOffset]::Parse($approval.expiresLocal) -le [DateTimeOffset]::Now -or [string]::IsNullOrWhiteSpace($approval.independentReview)){
    throw 'Database action approval does not match this plan, host, action, independent review, or expiry.'
}
$appDatabase=$plan.manifest.database.name
$roles=Get-PostgresRoleNames $appDatabase
if($approval.database -ne $appDatabase){throw 'Approval belongs to another application database.'}
if($UserName -ne $approval.userName){throw 'Database connection identity differs from the approved role.'}
$toolPath=switch($Action){'Backup'{Join-Path $ToolDirectory 'pg_dump.exe'}'RestoreValidation'{Join-Path $ToolDirectory 'pg_restore.exe'}default{$psql}}
if((Get-FileHash -LiteralPath $toolPath).Hash.ToLowerInvariant() -ne $approval.toolSHA256){throw 'Database tool differs from approved bytes.'}
if($Action -eq 'ApplySql'){
    if(-not $SqlPath -or -not $approval.ContainsKey('sqlSHA256') -or -not $approval.ContainsKey('targetDatabase') -or
        -not $approval.ContainsKey('transactional') -or $approval.transactional -ne [bool]$Transactional){throw 'SQL approval must include script hash, target database, and transactional behavior.'}
    if(-not $Database -or $Database -ne $approval.targetDatabase -or $Database -notin @('postgres',$appDatabase)){throw 'SQL target is not the approved maintenance or application database.'}
    if($OwnerRole -and $OwnerRole -ne $roles.owner){throw 'SQL role must be the approved application owner role.'}
    if($Database -eq $appDatabase -and $OwnerRole -ne $roles.owner){throw 'Application DDL/grants must explicitly use the separate owner role.'}
    if($Database -eq $appDatabase -and ($UserName -ne $roles.migrator -or -not $Transactional)){throw 'Application DDL/grants require the dedicated migrator identity and transactional execution.'}
    if($Execute){
        if(-not $SnapshotPath -or -not $approval.ContainsKey('snapshotSHA256')){throw 'SQL execution requires the reviewed preflight snapshot.'}
        if(-not $SnapshotUserName -or -not $SnapshotPassFile -or -not $approval.ContainsKey('snapshotUserName') -or $SnapshotUserName -ne $approval.snapshotUserName){
            throw 'SQL execution requires the separately approved read-only preflight identity and its private password file.'
        }
        if((Get-FileHash -LiteralPath $SnapshotPath).Hash.ToLowerInvariant() -ne $approval.snapshotSHA256){throw 'Reviewed preflight snapshot hash mismatch.'}
        $expected=Read-DeploymentJson $SnapshotPath
        $actual=Get-PostgresSnapshot -PsqlPath $psql -PassFile $SnapshotPassFile -UserName $SnapshotUserName -HostIdentity $hostIdentity -Port $port
        foreach($field in @('hostIdentity','serverVersionNum','serverSystemIdentifier','databases','roles')){
            if((ConvertTo-CanonicalJson $expected[$field]) -ne (ConvertTo-CanonicalJson $actual[$field])){throw "PostgreSQL preflight drift detected: $field. Replan the next database action."}
        }
    }
    Invoke-PostgresReviewedSql -PsqlPath $psql -PassFile $PassFile -UserName $UserName -Database $Database -SqlPath $SqlPath `
        -ApprovedSHA256 $approval.sqlSHA256 -JournalPath $OutputPath -IndependentReviewReference $approval.independentReview `
        -OwnerRole $OwnerRole -Transactional:$Transactional -Execute:$Execute -Port $port
    return
}
if($Action -eq 'Evidence'){
    if($Execute){throw 'Evidence is read-only; omit -Execute.'}
    if($UserName -ne $roles.runtime){throw 'Isolation evidence must use the application runtime database role.'}
    $solutionDatabases=@('ferry_tracker','home_automation','site_dock')
    if($plan.ContainsKey('solutionDatabases')){
        $solutionDatabases=@($plan.solutionDatabases)
        if($appDatabase -notin $solutionDatabases){throw 'Plan solutionDatabases must list every managed database, including this application.'}
    }
    $evidence=Get-PostgresDatabaseEvidence $plan.manifest $psql $PassFile $UserName -SolutionDatabases $solutionDatabases -Port $port
    Write-DeploymentJson $OutputPath $evidence
    return $evidence
}
if($Action -eq 'Backup'){
    if(-not $approval.ContainsKey('psqlSHA256')){throw 'Backup approval must pin the psql verifier hash.'}
    Backup-PostgresDatabase -Manifest $plan.manifest -ToolDirectory $ToolDirectory -PassFile $PassFile -UserName $UserName `
        -OutputPath $OutputPath -ApprovedToolSHA256 $approval.toolSHA256 -ApprovedPsqlSHA256 $approval.psqlSHA256 -ApprovedPlanHash $approval.planHash -PlanHash $plan.planHash -Execute:$Execute -Port $port
    return
}
if($Action -eq 'RestoreValidation'){
    if(-not $approval.ContainsKey('psqlSHA256')){throw 'Restore approval must pin the psql verifier hash.'}
    if(-not $Database -or -not $approval.ContainsKey('validationDatabase') -or $approval.validationDatabase -ne $Database){throw 'Validation restore requires an explicit separate database name in its approval.'}
    Restore-PostgresValidationDatabase -PgRestorePath $toolPath -PassFile $PassFile -UserName $UserName -Database $Database `
        -BackupPath $BackupPath -ApprovedBackupSHA256 $approval.backupSHA256 -ApprovedPsqlSHA256 $approval.psqlSHA256 -IndependentReviewReference $approval.independentReview -JournalPath $OutputPath -Execute:$Execute -Port $port
}
