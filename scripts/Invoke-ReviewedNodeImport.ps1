#requires -Version 7.5
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ApprovalPath,
    [Parameter(Mandatory)][string]$AppRoot,
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$PassFile,
    [Parameter(Mandatory)][string]$SourceVerificationPath,
    [Parameter(Mandatory)][string]$OperationDirectory,
    [ValidateRange(30,900)][int]$TimeoutSeconds=180,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$framework=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $framework 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $framework 'src\PostgreSQL.psm1') -DisableNameChecking
Import-Module (Join-Path $framework 'src\Transfer.psm1') -DisableNameChecking
Import-Module (Join-Path $framework 'src\Operations.psm1') -DisableNameChecking
$plan=Read-DeploymentJson $PlanPath
$approval=Read-DeploymentJson $ApprovalPath
foreach($field in @('action','planHash','hostIdentity','independentReview','expiresLocal','wrapperSHA256','nodePath','nodeSHA256',
    'importerSHA256','sourceSHA256','transferSHA256','preparedStateSHA256','sourceVerificationSHA256','timeoutSeconds')){
    if(-not $approval.ContainsKey($field)){throw "Import approval missing $field."}
}
if($plan.planHash -ne (Get-PlanDigest $plan) -or $plan.app -ne 'ferry-tracker' -or
    $plan.transitionKind -ne 'LegacyConversion' -or $approval.action -ne 'Import' -or
    $approval.planHash -ne $plan.planHash -or $approval.hostIdentity -ne $plan.databaseHostSnapshot.identity -or
    $env:COMPUTERNAME -ine $plan.databaseTarget.host -or $plan.target.host -ine $plan.databaseTarget.host -or
    (Get-CimInstance Win32_ComputerSystemProduct -Property UUID).UUID -ne $approval.hostIdentity -or
    [DateTimeOffset]::Parse($approval.expiresLocal) -le [DateTimeOffset]::Now -or
    [string]::IsNullOrWhiteSpace($approval.independentReview) -or $TimeoutSeconds -ne $approval.timeoutSeconds){
    throw 'Import action, plan, host, review, expiry or deadline differs from approval.'
}
$expectedRoot=Join-Path $plan.target.root ('apps\'+$plan.app)
if([IO.Path]::GetFullPath($AppRoot) -ine $expectedRoot){throw 'Import app root differs from plan.'}
if((Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant() -ne $approval.wrapperSHA256){throw 'Import wrapper changed after review.'}
$receipt=Assert-PreparedState $plan $AppRoot $approval.preparedStateSHA256
if($receipt.transferSHA256 -ne $approval.transferSHA256){throw 'Import source differs from prepared state.'}
if(Test-Path -LiteralPath (Join-Path $AppRoot 'state\active.json')){throw 'Production importer refuses an activated app.'}
if(@(Get-NetTCPConnection -State Listen -LocalPort $plan.manifest.launch.port -ErrorAction SilentlyContinue).Count){throw 'Import requires an absent application listener.'}
$proofPath=Join-Path $SourceDirectory 'transfer.json'
if((Get-FileHash -LiteralPath $proofPath).Hash.ToLowerInvariant() -ne $approval.transferSHA256){throw 'Import transfer proof changed.'}
$proof=Read-DeploymentJson $proofPath
$sqlite=@($proof.files|Where-Object kind -eq sqlite)
if($sqlite.Count -ne 1 -or $sqlite[0].sha256 -ne $approval.sourceSHA256){throw 'Import requires exactly one reviewed SQLite snapshot.'}
$verification=Read-DeploymentJson $SourceVerificationPath
if((Get-FileHash -LiteralPath $SourceVerificationPath).Hash.ToLowerInvariant() -ne $approval.sourceVerificationSHA256){throw 'Source verification changed.'}
$continuityApproval=@{
    preparedStateSHA256=$approval.preparedStateSHA256;databaseEvidenceSHA256=$approval.preparedStateSHA256
    transferSHA256=$approval.transferSHA256;sourceFenceSHA256=$receipt.sourceFenceSHA256
}
Assert-SourceContinuity $plan $continuityApproval $verification $receipt
$release=Resolve-OwnedPath $AppRoot ('releases\'+$plan.releaseId)
$seal=Test-ReleaseInventory $release
$importer=Resolve-OwnedPath $release 'deploy\postgresql\import.mjs'
if((Get-FileHash -LiteralPath $importer).Hash.ToLowerInvariant() -ne $approval.importerSHA256 -or
    $seal.runtimePath -ne $approval.nodePath -or (Get-FileHash -LiteralPath $approval.nodePath).Hash.ToLowerInvariant() -ne $approval.nodeSHA256){
    throw 'Importer or Node executable differs from approved release.'
}
if(Test-Path -LiteralPath $OperationDirectory){throw 'Import operation directory already exists; inspect the prior outcome.'}
$parent=Split-Path -Parent ([IO.Path]::GetFullPath($OperationDirectory))
$null=Resolve-OwnedPath $parent (Split-Path -Leaf $OperationDirectory)
foreach($path in @($parent,$SourceDirectory)){
    $acl=Get-Acl -LiteralPath $path
    if(-not $acl.AreAccessRulesProtected){throw 'Import input/output parent requires a protected admin-only ACL.'}
    foreach($rule in $acl.Access|Where-Object AccessControlType -eq Allow){
        if($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){
            throw 'Import input/output parent grants access outside SYSTEM and Administrators.'
        }
    }
}
Assert-PostgresProtectedFile $PassFile 'migrator password file' -DenyBroadRead
if(-not $Execute){return @{status='ValidatedOnly';planHash=$plan.planHash;databaseOpened=$false;runtimeStarted=$false}}

[IO.Directory]::CreateDirectory($OperationDirectory)|Out-Null
$journal=Join-Path $OperationDirectory 'result.json'
$result=@{status='Running';planHash=$plan.planHash;sourceTransferSHA256=$approval.transferSHA256;sourceSHA256=$approval.sourceSHA256;runtimeStarted=$false;independentReview=$approval.independentReview}
Write-DeploymentJson $journal $result -CreateNew
$process=$null
$start=$null
$lease=$null
try {
    $lease=Get-DeploymentLock (Join-Path $AppRoot 'state\deployment.lock')
    Assert-PreparedState $plan $AppRoot $approval.preparedStateSHA256 | Out-Null
    Assert-SourceContinuity $plan $continuityApproval $verification $receipt
    if(Test-Path -LiteralPath (Join-Path $AppRoot 'state\active.json')){throw 'An active app appeared before import.'}
    Write-DeploymentJson (Join-Path $AppRoot 'state\database-import-attempt.json') @{
        planHash=$plan.planHash;operationDirectory=$OperationDirectory;sourceTransferSHA256=$approval.transferSHA256
        independentReview=$approval.independentReview;startedLocal=(Get-Date).ToString('o')
    } -CreateNew
    $role=(Get-PostgresRoleNames $plan.manifest.database.name).migrator
    $credential=[IO.File]::ReadAllText($PassFile).TrimEnd("`r","`n")
    $match=[regex]::Match($credential,('^127\.0\.0\.1:'+ $plan.databaseTarget.port +':'+[regex]::Escape($plan.manifest.database.name)+':'+[regex]::Escape($role)+':(?<password>[a-fA-F0-9]{96})$'))
    if(-not $match.Success){throw 'Expected one exact loopback migrator pgpass entry with the provisioned hex credential.'}
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$approval.nodePath;$start.WorkingDirectory=$OperationDirectory
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($name in @($start.Environment.Keys|Where-Object {$_ -like 'PG*' -or $_ -in @('DATABASE_URL','NODE_OPTIONS','NODE_PATH')})){$null=$start.Environment.Remove($name)}
    $start.Environment['DATABASE_URL']='postgresql://'+$role+':'+$match.Groups['password'].Value+'@127.0.0.1:'+$plan.databaseTarget.port+'/'+$plan.manifest.database.name
    $start.Environment['CAPTURE_ARCHIVE_DIR']=Join-Path $AppRoot 'shared\data\raw'
    foreach($argument in @($importer,'--source-dir',$SourceDirectory,'--expected-source-sha256',$approval.sourceSHA256,
        '--source-index',$proofPath,'--expected-index-sha256',$approval.transferSHA256,'--execute')){$start.ArgumentList.Add($argument)}
    $credential=$null;$match=$null
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    if(-not $process.Start()){throw 'Import child did not start.'}
    $start.Environment['DATABASE_URL']=''
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not $process.WaitForExit(1000)){
        if($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'Import deadline exceeded. Preserve target maintenance; inspect transaction and sequence state before recovery.'}
        if([int]$clock.Elapsed.TotalSeconds % 5 -eq 0){Write-Host ("Import running: {0:n0}s, worker PID {1}" -f $clock.Elapsed.TotalSeconds,$process.Id)}
    }
    if(-not $stdout.Wait(10000) -or -not $stderr.Wait(10000)){throw 'Import output drain exceeded ten seconds.'}
    if($process.ExitCode -ne 0){throw 'Importer failed. Error output withheld to protect credentials. Do not retry automatically.'}
    $lines=@($stdout.Result -split '\r?\n'|Where-Object {$_})
    $tableResults=@($lines|Where-Object {$_ -match '^[a-z_]+: count and ordered row digest match \([0-9]+ rows\)$'})
    if($tableResults.Count -ne 11 -or $lines[-1] -ne 'Ferry import committed; source retained. No application writer was started.'){
        throw 'Importer exited without its complete parity and commit evidence.'
    }
    $result.status='ImportedNeedsIndependentParityAndRestore'
    $result.tableParity=$tableResults
} catch {
    $result.status='FailedOrUnknown'
    $result.error=$_.Exception.Message
    throw
} finally {
    if($process){
        try{if(-not $process.HasExited){$process.Kill($true);if(-not $process.WaitForExit(10000)){throw 'Import child cleanup timed out.'}}}
        finally{$process.Dispose()}
    }
    if($start){$start.Environment['DATABASE_URL']=''}
    if($lease){$lease.Dispose()}
    $credential=$null;$match=$null
    $result.completedLocal=(Get-Date).ToString('o')
    Write-DeploymentJson $journal $result
}
