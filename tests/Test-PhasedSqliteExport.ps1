#requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$PythonPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ReviewedSnapshotSHA256,
    [Parameter(Mandatory)][string]$IndependentReviewReference
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($IndependentReviewReference)){throw 'Synthetic SQLite writes require independent review.'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Synthetic output already exists.'}
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\Transfer.psm1') -DisableNameChecking
Import-Module (Join-Path $root 'src\Operations.psm1') -DisableNameChecking
$snapshot=Join-Path $root 'scripts\sqlite_snapshot.py'
if((Get-FileHash $snapshot).Hash.ToLowerInvariant() -ne $ReviewedSnapshotSHA256){throw 'Snapshot helper differs from exact reviewed bytes.'}
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$source=Join-Path $OutputDirectory 'synthetic-source'
[IO.Directory]::CreateDirectory((Join-Path $source 'raw'))|Out-Null
$db=Join-Path $source 'synthetic.db'
$setup='import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA journal_mode=WAL"); c.execute("CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT NOT NULL)"); c.executemany("INSERT INTO sample VALUES(?,?)", [(i,"synthetic") for i in range(1,1001)]); c.commit(); c.close()'
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=$PythonPath;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
foreach($arg in @('-c',$setup,$db)){$start.ArgumentList.Add($arg)}
$writer=[Diagnostics.Process]::new();$writer.StartInfo=$start
try{
    if(-not $writer.Start()){throw 'Synthetic writer did not start.'}
    if(-not $writer.WaitForExit(10000)){$writer.Kill($true);throw 'Synthetic writer timed out.'}
    if($writer.ExitCode -ne 0){throw 'Synthetic writer failed.'}
    $writerId=$writer.Id
}finally{$writer.Dispose()}
foreach($n in 1..234){[IO.File]::WriteAllText((Join-Path $source "raw\$n.txt"),"Synthetic archive $n")}
$reservation=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$reservation.Start();$port=$reservation.LocalEndpoint.Port;$reservation.Stop()
$plan=@{
    id='syntheticphase20261017';planHash=('a'*64);observedHost=$env:COMPUTERNAME;currentRelease=$null;transitionKind='LegacyConversion'
    releaseId='synthetic-release';manifestHash='synthetic'
    manifest=@{
        source=@{host=$env:COMPUTERNAME;root=$source;tasks=@()};launch=@{port=$port}
        state=@(
            @{source=$db;target='backups\source\synthetic.db';kind='sqlite';required=$true},
            @{source=(Join-Path $source 'raw');target='data\raw';kind='directory';required=$true}
        )
    }
}
$fence=@{
    operationId=$plan.id;host=$env:COMPUTERNAME;sourceProcessId=$writerId;writersStopped=$true;restartPathsDisabled=$true
    writerInventoryReviewed=$true;verifiedLocal=(Get-Date).ToString('o')
}
$clock=[Diagnostics.Stopwatch]::StartNew()
$export=Join-Path $OutputDirectory 'export'
$proof=Export-FrozenState $plan $fence $export -PythonPath $PythonPath -ReviewedSnapshotSHA256 $ReviewedSnapshotSHA256
if($proof.files.Count -ne 235){throw 'Synthetic export did not include every declared file.'}
$database=@($proof.files|Where-Object kind -eq sqlite)
if($database.Count -ne 1 -or $database[0].snapshot.integrity -ne 'ok' -or
    $database[0].sourceHashes.main -ne (Get-FileHash $db).Hash.ToLowerInvariant()){throw 'Synthetic SQLite source/export evidence failed.'}
$app=Join-Path $OutputDirectory 'app'
$release=Join-Path $app 'releases\synthetic-release'
[IO.Directory]::CreateDirectory($release)|Out-Null
Write-DeploymentJson (Join-Path $release 'release.json') @{
    files=@();manifestHash=$plan.manifestHash;sourceCommit='synthetic';runtimePath=$PythonPath;runtimeSHA256=(Get-FileHash $PythonPath).Hash.ToLowerInvariant()
}
Write-DeploymentJson (Join-Path $app 'state\maintenance.json') @{reason='Synthetic only'}
try{
    $transferHash=(Get-FileHash (Join-Path $export 'transfer.json')).Hash.ToLowerInvariant()
    $prepared=Prepare-InitialCutover $plan $app $export $transferHash
    Assert-PreparedState $plan $app $prepared.preparedStateSHA256|Out-Null
    Set-ActiveRelease $app $plan.releaseId $plan.id $env:COMPUTERNAME $plan.planHash
    if((Read-DeploymentJson (Join-Path $app 'state\active.json')).previousRelease){throw 'Initial activation has a false previous release.'}
    Write-DeploymentJson (Join-Path $OutputDirectory 'result.json') @{
        status='PassedSyntheticOnly';exportedFiles=$proof.files.Count;sqliteIntegrity='ok';realContinuousMonitor=$true
        preparedWithoutRuntime=$true;previousRelease=$null;databaseProductionTouched=$false;tasksChanged=$false
        independentReview=$IndependentReviewReference;elapsedSeconds=$clock.Elapsed.TotalSeconds;completedLocal=(Get-Date).ToString('o')
    } -CreateNew
}finally{
    $junction=Join-Path $app 'current'
    if(Test-Path -LiteralPath $junction){[IO.Directory]::Delete($junction)}
}
