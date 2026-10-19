#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Root='C:\ProgramData\JimlerTech\PostgreSQL\backups',
    [string]$Destination='\\jimbrownhome\Shared\PostgreSQL\jimbrownhome1',
    [string]$ToolDirectory='C:\Program Files\PostgreSQL\18\bin',
    [string]$PassFile='C:\ProgramData\JimlerTech\PostgreSQL\postgres.pgpass',
    [string]$ShareCredential='C:\ProgramData\JimlerTech\PostgreSQL\backup-share.credential.xml',
    [ValidateRange(2,365)][int]$RetentionDays=14
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$started=Get-Date
$runName='pg-'+$started.ToString('yyyyMMdd-HHmmss')
$run=Join-Path $Root $runName
$lock=$null
$snapshotProcess=$null
$shareDrive=$null
$manifest=@{status='Running';startedLocal=$started.ToString('o');host=$env:COMPUTERNAME;databases=@()}

function Write-ProgressLog([string]$Message) {
    $line='{0} [{1:n0}s] {2}' -f (Get-Date).ToString('o'),((Get-Date)-$started).TotalSeconds,$Message
    Write-Host $line
    Add-Content -LiteralPath (Join-Path $Root 'backup.log') -Value $line
}

function Invoke-PgTool([string]$Tool,[string[]]$Arguments,[int]$TimeoutSeconds=600) {
    $TimeoutSeconds=[Math]::Min($TimeoutSeconds,2400-[int]((Get-Date)-$started).TotalSeconds)
    if($TimeoutSeconds -le 0){throw 'Backup job exceeded its 40-minute internal time limit.'}
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $ToolDirectory $Tool))
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    foreach($arg in $Arguments){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$p.StandardOutput.ReadToEndAsync()
        $stderr=$p.StandardError.ReadToEndAsync()
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while(-not $p.WaitForExit(15000)){
            Write-ProgressLog "$Tool running ($([int]$clock.Elapsed.TotalSeconds)s)"
            if($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds){$p.Kill($true);throw "$Tool exceeded $TimeoutSeconds seconds."}
        }
        $text=$stdout.GetAwaiter().GetResult()
        $errorText=$stderr.GetAwaiter().GetResult()
        if($p.ExitCode -ne 0){throw "$Tool failed ($($p.ExitCode)): $errorText"}
        if($errorText){Write-ProgressLog "$Tool warning: $($errorText.Trim())"}
        return $text.Trim()
    } finally { $p.Dispose() }
}

function Invoke-PgQuery([string]$Database,[string]$Sql) {
    Invoke-PgTool 'psql.exe' @('-X','-qAt','-w','-h','127.0.0.1','-U','postgres','-d',$Database,'-v','ON_ERROR_STOP=1','-c',$Sql)
}

function Get-TableCounts([string]$Database,[string]$Snapshot) {
    $sql=@'
SELECT COALESCE(json_agg(json_build_object('schema',schemaname,'table',tablename,'rows',
((xpath('/row/n/text()',query_to_xml(format('SELECT count(*) AS n FROM %I.%I',schemaname,tablename),false,true,'')))[1]::text)::bigint)
ORDER BY schemaname,tablename),'[]')::text
FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') AND schemaname !~ '^pg_toast';
'@
    if($Snapshot){$sql="BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SET TRANSACTION SNAPSHOT '$Snapshot'; $sql COMMIT;"}
    else {$sql="BEGIN READ ONLY; $sql COMMIT;"}
    Invoke-PgQuery $Database $sql
}

function Save-Manifest {
    $manifest|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $run 'manifest.json') -Encoding utf8
}

try {
    if($env:COMPUTERNAME -ine 'jimbrownhome1'){throw 'Run this job on jimbrownhome1 only.'}
    if(-not (Test-Path -LiteralPath $Root -PathType Container)){throw 'The protected backup directory must be installed first.'}
    $lock=[IO.File]::Open((Join-Path $Root 'backup.lock'),'OpenOrCreate','ReadWrite','None')
    [IO.Directory]::CreateDirectory($run)|Out-Null
    $env:PGPASSFILE=$PassFile
    $env:PGCONNECT_TIMEOUT='15'
    $env:PGOPTIONS='-c statement_timeout=540000 -c lock_timeout=30000'
    Write-ProgressLog "Starting $runName"
    Save-Manifest
    $databases=@((Invoke-PgQuery 'postgres' "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname;") -split '\r?\n')
    if(-not $databases.Count){throw 'No databases found.'}
    foreach($database in $databases){
        if($database -cnotmatch '^[a-z][a-z0-9_]{0,43}$' -or $database.StartsWith('sd_validate_')){
            throw "Unexpected database '$database'. Inspect it before running backups."
        }
    }
    $manifest.databaseNames=$databases
    $manifest.serverVersion=Invoke-PgQuery 'postgres' 'SHOW server_version;'
    $manifest.globalRolesFile='roles.sql'
    Invoke-PgTool 'pg_dumpall.exe' @('-w','-h','127.0.0.1','-U','postgres','--globals-only','--file',(Join-Path $run 'roles.sql'))|Out-Null
    $configDir=Join-Path $run 'server-config'
    [IO.Directory]::CreateDirectory($configDir)|Out-Null
    foreach($setting in 'config_file','hba_file','ident_file'){
        $path=Invoke-PgQuery 'postgres' "SHOW $setting;"
        Copy-Item -LiteralPath $path -Destination (Join-Path $configDir ([IO.Path]::GetFileName($path)))
    }
    foreach($database in $databases){
        Write-ProgressLog "Backing up $database with snapshot-matched row counts"
        $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $ToolDirectory 'psql.exe'))
        $info.UseShellExecute=$false
        $info.CreateNoWindow=$true
        $info.RedirectStandardInput=$true
        $info.RedirectStandardOutput=$true
        $info.RedirectStandardError=$true
        foreach($arg in @('-X','-qAt','-w','-h','127.0.0.1','-U','postgres','-d',$database,'-v','ON_ERROR_STOP=1')){$info.ArgumentList.Add($arg)}
        $snapshotProcess=[Diagnostics.Process]::Start($info)
        $snapshotErrors=$snapshotProcess.StandardError.ReadToEndAsync()
        $snapshotProcess.StandardInput.WriteLine('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SELECT pg_export_snapshot();')
        $read=$snapshotProcess.StandardOutput.ReadLineAsync()
        if(-not $read.Wait(20000)){throw 'Snapshot export timed out.'}
        $snapshot=$read.Result
        if($snapshot -notmatch '^[A-Fa-f0-9]+-[A-Fa-f0-9]+-[0-9]+$'){throw "Invalid snapshot for $database."}
        $counts=Get-TableCounts $database $snapshot
        $counts|Set-Content -LiteralPath (Join-Path $run "$database.counts.json") -Encoding utf8
        $dump=Join-Path $run "$database.dump"
        Invoke-PgTool 'pg_dump.exe' @('-w','-h','127.0.0.1','-U','postgres','--dbname',$database,'--format=custom',"--snapshot=$snapshot",'--file',($dump+'.partial'))|Out-Null
        $snapshotProcess.StandardInput.WriteLine('COMMIT;')
        $snapshotProcess.StandardInput.Close()
        if(-not $snapshotProcess.WaitForExit(20000)){throw 'Snapshot connection did not close.'}
        if($snapshotProcess.ExitCode -ne 0){throw "Snapshot connection failed: $($snapshotErrors.GetAwaiter().GetResult())"}
        $snapshotProcess.Dispose()
        $snapshotProcess=$null
        Move-Item -LiteralPath ($dump+'.partial') -Destination $dump
        $manifest.databases+=@{name=$database;bytes=(Get-Item -LiteralPath $dump).Length;restored=$false;countsMatched=$false}
        Save-Manifest
    }
    # A fixed snapshot keeps counts comparable even while collectors continue writing.
    foreach($entry in $manifest.databases){
        $database=$entry.name
        $validation='sd_validate_backup_'+$database
        Write-ProgressLog "Restoring $database into $validation"
        $exists=Invoke-PgQuery 'postgres' "SELECT count(*) FROM pg_database WHERE datname='$validation';"
        if($exists -ne '0'){throw "Validation database $validation already exists. Inspect it; this job never overwrites an existing database."}
        Invoke-PgQuery 'postgres' "CREATE DATABASE `"$validation`" TEMPLATE template0;"|Out-Null
        Invoke-PgQuery 'postgres' "REVOKE CONNECT ON DATABASE `"$validation`" FROM PUBLIC;"|Out-Null
        Invoke-PgTool 'pg_restore.exe' @('-w','-h','127.0.0.1','-U','postgres','--dbname',$validation,'--no-owner','--no-acl','--exit-on-error','--single-transaction',(Join-Path $run "$database.dump"))|Out-Null
        $entry.restored=$true
        $restored=Get-TableCounts $validation ''
        $expected=Get-Content -LiteralPath (Join-Path $run "$database.counts.json") -Raw
        if(($restored|ConvertFrom-Json|ConvertTo-Json -Depth 8 -Compress) -cne ($expected|ConvertFrom-Json|ConvertTo-Json -Depth 8 -Compress)){
            throw "Table counts differ for $database. Leaving $validation for inspection."
        }
        $entry.countsMatched=$true
        Save-Manifest
        # Only this run's freshly created, checked validation database is removed.
        Invoke-PgQuery 'postgres' "DROP DATABASE `"$validation`";"|Out-Null
        Write-ProgressLog "$database restore and row counts verified"
    }
    $manifest.files=@(Get-ChildItem -LiteralPath $run -Recurse -File|Where-Object Name -ne 'manifest.json'|ForEach-Object {
        @{path=[IO.Path]::GetRelativePath($run,$_.FullName);bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
    $manifest.status='VerifiedLocally'
    Save-Manifest
    if(-not (Test-Path -LiteralPath $ShareCredential -PathType Leaf)){throw 'Backup share credential is missing.'}
    $credential=Import-Clixml -LiteralPath $ShareCredential
    $shareDrive=New-PSDrive -Name PgBackupShare -PSProvider FileSystem -Root '\\jimbrownhome\Shared' -Credential $credential -Scope Script
    if(-not (Test-Path -LiteralPath $Destination -PathType Container)){throw 'Protected off-host backup folder is missing.'}
    $remote=Join-Path $Destination $runName
    if(Test-Path -LiteralPath $remote){throw 'Off-host backup output already exists.'}
    $remotePartial=$remote+'.partial'
    Copy-Item -LiteralPath $run -Destination $remotePartial -Recurse
    foreach($file in $manifest.files){
        $copied=Join-Path $remotePartial $file.path
        if((Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -cne $file.sha256){throw "Off-host checksum mismatch: $($file.path)"}
    }
    $manifest.status='Succeeded'
    $manifest.completedLocal=(Get-Date).ToString('o')
    $manifest.destination=$remote
    Save-Manifest
    Copy-Item -LiteralPath (Join-Path $run 'manifest.json') -Destination (Join-Path $remotePartial 'manifest.json') -Force
    if((Get-FileHash -LiteralPath (Join-Path $run 'manifest.json')).Hash -cne
        (Get-FileHash -LiteralPath (Join-Path $remotePartial 'manifest.json')).Hash){
        throw 'Off-host manifest checksum mismatch.'
    }
    Move-Item -LiteralPath $remotePartial -Destination $remote
    $cutoff=(Get-Date).Date.AddDays(1-$RetentionDays)
    foreach($base in @($Root,$Destination)){
        foreach($old in Get-ChildItem -LiteralPath $base -Directory){
            if($old.Name -notmatch '^pg-(\d{8})-\d{6}$'){continue}
            $day=[datetime]::ParseExact($Matches[1],'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture)
            if($day -ge $cutoff){continue}
            $record=Join-Path $old.FullName 'manifest.json'
            if(-not (Test-Path -LiteralPath $record)){continue}
            if((Get-Content -LiteralPath $record -Raw|ConvertFrom-Json).status -ne 'Succeeded'){continue}
            Remove-Item -LiteralPath $old.FullName -Recurse -Force
            Write-ProgressLog "Expired backup removed: $($old.Name) from $base"
        }
    }
    $manifest|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $Root 'latest-success.json')
    Write-ProgressLog "SUCCESS: all $($databases.Count) databases restored, counts matched, off-host checksums verified"
} catch {
    $failure=$_.Exception.Message
    if(Test-Path -LiteralPath $run){
        $manifest.status='Failed'
        $manifest.error=$failure
        $manifest.failedLocal=(Get-Date).ToString('o')
        Save-Manifest
    }
    Write-ProgressLog "FAILED: $failure"
    $notice=Join-Path (Split-Path -Parent $Root) 'Send-BackupAlert.ps1'
    if(Test-Path -LiteralPath $notice){& $notice -Message "PostgreSQL backup failed on jimbrownhome1: $failure"}
    throw
} finally {
    if($snapshotProcess){
        if(-not $snapshotProcess.HasExited){$snapshotProcess.Kill($true)}
        $snapshotProcess.Dispose()
    }
    if($shareDrive){Remove-PSDrive -Name PgBackupShare -Force}
    if($lock){$lock.Dispose()}
}
