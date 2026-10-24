$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Deployment.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'src\ReleaseBackup.psm1') -Force -DisableNameChecking

function Save-BackupFixture {
    Write-DeploymentJson (Join-Path $script:backupRoot 'latest-success.json') $script:record
    Write-DeploymentJson (Join-Path $script:run 'manifest.json') $script:record
}
function New-BackupFixture([string]$Started='2026-10-23T03:00:00-07:00',[string]$Completed='2026-10-23T03:10:00-07:00') {
    $script:backupRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $name='pg-'+([DateTimeOffset]::Parse($Started)).ToString('yyyyMMdd-HHmmss')
    $script:run=Join-Path $script:backupRoot $name
    New-Item -ItemType Directory -Path $script:run | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:run 'app_db.dump'),'synthetic dump')
    [IO.File]::WriteAllText((Join-Path $script:run 'app_db.counts.json'),'[{"table":"items","rows":1}]')
    $script:record=@{
        status='Succeeded';host='backup-host';startedLocal=$Started;completedLocal=$Completed
        destination="\\jimbrownhome\Shared\PostgreSQL\backup-host\$name"
        databases=@(@{name='app_db';bytes=14;restored=$true;countsMatched=$true})
        files=@(foreach($file in Get-ChildItem -LiteralPath $script:run -File){
            @{path=$file.Name;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash}
        })
    }
    Save-BackupFixture
}
function New-RunningFixture([string]$Started='2026-10-24T03:00:00-07:00',[string]$Status='Running',[string]$HostName='backup-host') {
    $name='pg-'+([DateTimeOffset]::Parse($Started)).ToString('yyyyMMdd-HHmmss')
    Write-DeploymentJson (Join-Path $script:backupRoot "$name\manifest.json") @{
        status=$Status;host=$HostName;startedLocal=$Started;databases=@()
    }
}
function Get-FixtureEvidence([string]$At='2026-10-23T12:00:00-07:00') {
    Get-ReleaseBackupEvidence -Database app_db -BackupRoot $script:backupRoot -ExpectedHost backup-host -Now ([DateTimeOffset]::Parse($At))
}
function Assert-BackupError([scriptblock]$Action,[string]$Message) {
    $caught=$null
    try { & $Action | Out-Null } catch { $caught=$_.Exception.Message }
    [bool]$caught | Should Be $true
    $caught | Should Match $Message
}

Describe 'Read-only release backup evidence' {
    BeforeEach { New-BackupFixture }

    It 'returns only a small evidence summary and verifies the exact manifest hash' {
        $result=Get-FixtureEvidence
        $result.Count | Should Be 8
        $result.database | Should Be 'app_db'
        $result.manifestPath | Should Be (Join-Path $script:run 'manifest.json')
        $result.manifestSHA256 | Should Be ((Get-FileHash -LiteralPath $result.manifestPath).Hash.ToLowerInvariant())
        $result.dumpSHA256 | Should Be ((Get-FileHash -LiteralPath (Join-Path $script:run 'app_db.dump')).Hash.ToLowerInvariant())
        $result.countsSHA256 | Should Be ((Get-FileHash -LiteralPath (Join-Path $script:run 'app_db.counts.json')).Hash.ToLowerInvariant())
    }
    It 'compares JSON by canonical content rather than whitespace and key order' {
        $reordered=[ordered]@{}
        foreach($key in @($script:record.Keys | Sort-Object -Descending)){$reordered[$key]=$script:record[$key]}
        [IO.File]::WriteAllText((Join-Path $script:backupRoot 'latest-success.json'),(ConvertTo-Json -InputObject $reordered -Depth 12 -Compress))
        (Get-FixtureEvidence).database | Should Be 'app_db'
    }
    It 'requires the latest success record' {
        Remove-Item -LiteralPath (Join-Path $script:backupRoot 'latest-success.json')
        Assert-BackupError {Get-FixtureEvidence} 'missing'
    }
    It 'requires the matching run manifest' {
        Remove-Item -LiteralPath (Join-Path $script:run 'manifest.json')
        Assert-BackupError {Get-FixtureEvidence} 'manifest.json'
    }
    It 'rejects incomplete top-level records with an explicit missing-field error' {
        foreach($field in @('status','host','databases','files','startedLocal','completedLocal')){
            $original=$script:record[$field]
            $script:record.Remove($field)
            Save-BackupFixture
            Assert-BackupError {Get-FixtureEvidence} "missing $field|$field must"
            $script:record[$field]=$original
        }
    }
    It 'rejects partial and failed success records' {
        foreach($status in @('Running','VerifiedLocally','Failed')){
            $script:record.status=$status
            Save-BackupFixture
            Assert-BackupError {Get-FixtureEvidence} 'Succeeded'
        }
    }
    It 'rejects a success record changed separately from the immutable run' {
        $script:record.destination='elsewhere'
        Write-DeploymentJson (Join-Path $script:backupRoot 'latest-success.json') $script:record
        Assert-BackupError {Get-FixtureEvidence} 'immutable'
    }
    It 'requires the expected database host' {
        $script:record.host='another-host'
        Save-BackupFixture
        Assert-BackupError {Get-FixtureEvidence} 'host'
    }
    It 'requires the application database rather than only postgres' {
        $script:record.databases[0].name='postgres'
        Save-BackupFixture
        Assert-BackupError {Get-FixtureEvidence} 'application database'
    }
    It 'rejects duplicate database entries' {
        $script:record.databases+=@{name='app_db';bytes=14;restored=$true;countsMatched=$true}
        Save-BackupFixture
        Assert-BackupError {Get-FixtureEvidence} 'exactly one entry'
    }
    It 'requires boolean restore and count success' {
        foreach($field in @('restored','countsMatched')){
            foreach($value in @($false,'true')){
                $script:record.databases[0][$field]=$value
                Save-BackupFixture
                Assert-BackupError {Get-FixtureEvidence} 'incomplete'
            }
            $script:record.databases[0][$field]=$true
        }
    }
    It 'rejects missing or future completion and reversed timestamps' {
        foreach($completion in @('','2026-10-23T12:01:00-07:00','2026-10-23T02:59:00-07:00')){
            $script:record.completedLocal=$completion
            Save-BackupFixture
            Assert-BackupError {Get-FixtureEvidence} 'timestamp|future|precedes'
        }
    }
    It 'rejects future start timestamps' {
        New-BackupFixture '2026-10-24T03:00:00-07:00' '2026-10-24T03:10:00-07:00'
        Assert-BackupError {Get-FixtureEvidence} 'future'
    }
    It 'rejects offset-free and wrong Pacific offset timestamps' {
        foreach($timestamp in @('2026-10-23T03:00:00','2026-10-23T03:00:00-08:00')){
            $script:record.startedLocal=$timestamp
            Save-BackupFixture
            Assert-BackupError {Get-FixtureEvidence} 'offset'
        }
    }
    It 'rejects missing, truncated and same-length corrupt application files' {
        foreach($name in @('app_db.dump','app_db.counts.json')){
            $path=Join-Path $script:run $name
            $original=[IO.File]::ReadAllBytes($path)
            Remove-Item -LiteralPath $path
            Assert-BackupError {Get-FixtureEvidence} 'missing'
            [IO.File]::WriteAllBytes($path,@(1))
            Assert-BackupError {Get-FixtureEvidence} 'length'
            $corrupt=$original.Clone()
            $corrupt[0]=$corrupt[0] -bxor 1
            [IO.File]::WriteAllBytes($path,$corrupt)
            Assert-BackupError {Get-FixtureEvidence} 'checksum'
            [IO.File]::WriteAllBytes($path,$original)
        }
    }
    It 'rejects absent, duplicate or traversing application file records' {
        $original=$script:record.files
        $script:record.files=@($original | Where-Object path -ne 'app_db.dump')
        Save-BackupFixture
        Assert-BackupError {Get-FixtureEvidence} 'file record'
        $script:record.files=$original+@($original[0])
        Save-BackupFixture
        Assert-BackupError {Get-FixtureEvidence} 'file record'
        $script:record.files=$original
        ($script:record.files | Where-Object path -eq 'app_db.dump').path='..\app_db.dump'
        Save-BackupFixture
        Assert-BackupError {Get-FixtureEvidence} 'file record'
    }
    It 'requires positive numeric lengths and valid file hashes' {
        $file=$script:record.files[0]
        $length=$file.bytes
        foreach($bytes in @(0,-1,'14',14.5)){
            $file.bytes=$bytes
            Save-BackupFixture
            Assert-BackupError {Get-FixtureEvidence} 'metadata'
        }
        $file.bytes=$length
        $file.sha256='not-a-checksum'
        Save-BackupFixture
        Assert-BackupError {Get-FixtureEvidence} 'metadata'
    }
    It 'requires the database length to agree with the dump file record' {
        $script:record.databases[0].bytes=13
        Save-BackupFixture
        Assert-BackupError {Get-FixtureEvidence} 'dump length'
    }
    It 'derives the run path from the timestamp rather than a record-supplied path' {
        $script:record.manifestPath='..\outside\manifest.json'
        Save-BackupFixture
        $evidence=Get-FixtureEvidence
        $evidence.manifestPath | Should Be (Join-Path $script:run 'manifest.json')
        Move-Item -LiteralPath $script:run -Destination ($script:run+'.partial')
        Assert-BackupError {Get-FixtureEvidence} 'manifest.json'
    }
    It 'does not write backup files or inspect the destination share' {
        $before=@(Get-ChildItem -LiteralPath $script:backupRoot -Recurse -File | ForEach-Object {
            $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash
        }) -join "`n"
        Get-FixtureEvidence | Out-Null
        $after=@(Get-ChildItem -LiteralPath $script:backupRoot -Recurse -File | ForEach-Object {
            $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash
        }) -join "`n"
        $after | Should Be $before
    }
    It 'rejects an empty, partial, relative or unexpected destination without accessing it' {
        foreach($destination in @('','pg-20261023-030000',"\\jimbrownhome\Shared\PostgreSQL\backup-host\pg-20261023-030000.partial",'\\another-host\share\pg-20261023-030000')){
            $script:record.destination=$destination
            Save-BackupFixture
            Assert-BackupError {Get-FixtureEvidence} 'destination'
        }
    }
    It 'does not require unrelated database or server configuration files' {
        $script:record.files+=@{path='roles.sql';bytes=999;sha256=('0'*64)}
        Save-BackupFixture
        (Get-FixtureEvidence).database | Should Be 'app_db'
    }
    It 'rejects a junction at the backup root, run directory or application file' {
        $alias=Join-Path $TestDrive ('link-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Junction -Path $alias -Target $script:backupRoot | Out-Null
        try {
            Assert-BackupError {Get-ReleaseBackupEvidence -Database app_db -BackupRoot $alias -ExpectedHost backup-host} 'reparse'
        } finally { [IO.Directory]::Delete($alias) }
        $originalRun=$script:run
        $moved=$script:run+'-real'
        Move-Item -LiteralPath $originalRun -Destination $moved
        New-Item -ItemType Junction -Path $originalRun -Target $moved | Out-Null
        try { Assert-BackupError {Get-FixtureEvidence} 'reparse' } finally { [IO.Directory]::Delete($originalRun) }
        Move-Item -LiteralPath $moved -Destination $originalRun
        $dump=Join-Path $originalRun 'app_db.dump'
        Remove-Item -LiteralPath $dump
        New-Item -ItemType Junction -Path $dump -Target $originalRun | Out-Null
        try { Assert-BackupError {Get-FixtureEvidence} 'reparse' } finally { [IO.Directory]::Delete($dump) }
    }
}

Describe 'Pacific 03:00 coverage and the proven Running deadline' {
    BeforeEach { New-BackupFixture }
    It 'accepts yesterday before the next due time and rejects it exactly at 03:00 without clock grace' {
        (Get-FixtureEvidence '2026-10-24T02:59:59-07:00').database | Should Be 'app_db'
        Assert-BackupError {Get-FixtureEvidence '2026-10-24T03:00:00-07:00'} 'stale'
    }
    It 'rejects retention-aged success even with a current Running manifest' {
        New-RunningFixture '2026-10-25T03:00:00-07:00'
        Assert-BackupError {Get-FixtureEvidence '2026-10-25T03:10:00-07:00'} 'stale'
    }
    It 'accepts the previous due run only until the Running deadline' {
        New-RunningFixture
        (Get-FixtureEvidence '2026-10-24T03:39:59-07:00').database | Should Be 'app_db'
        Assert-BackupError {Get-FixtureEvidence '2026-10-24T03:40:00-07:00'} 'stale'
    }
    It 'measures the deadline from a proven delayed start within the due window' {
        New-RunningFixture '2026-10-24T03:10:00-07:00'
        (Get-FixtureEvidence '2026-10-24T03:49:59-07:00').database | Should Be 'app_db'
        Assert-BackupError {Get-FixtureEvidence '2026-10-24T03:50:00-07:00'} 'stale'
    }
    It 'rejects a Running start outside the due window' {
        New-RunningFixture '2026-10-24T03:40:00-07:00'
        Assert-BackupError {Get-FixtureEvidence '2026-10-24T03:41:00-07:00'} 'stale'
    }
    It 'rejects failed, wrong-host and pre-due current candidates' {
        foreach($status in @('Failed','VerifiedLocally','Succeeded')){
            New-RunningFixture -Status $status
            Assert-BackupError {Get-FixtureEvidence '2026-10-24T03:10:00-07:00'} 'stale'
        }
        New-RunningFixture -HostName 'wrong-host'
        Assert-BackupError {Get-FixtureEvidence '2026-10-24T03:10:00-07:00'} 'stale'
        Remove-Item -LiteralPath (Join-Path $script:backupRoot 'pg-20261024-030000') -Recurse
        New-RunningFixture '2026-10-24T02:59:00-07:00'
        Assert-BackupError {Get-FixtureEvidence '2026-10-24T03:10:00-07:00'} 'stale'
    }
    It 'rejects future or misnamed Running manifests' {
        New-RunningFixture '2026-10-24T03:20:00-07:00'
        Assert-BackupError {Get-FixtureEvidence '2026-10-24T03:10:00-07:00'} 'future'
        Remove-Item -LiteralPath (Join-Path $script:backupRoot 'pg-20261024-032000') -Recurse
        New-RunningFixture
        Move-Item -LiteralPath (Join-Path $script:backupRoot 'pg-20261024-030000') -Destination (Join-Path $script:backupRoot 'pg-20261024-030001')
        Assert-BackupError {Get-FixtureEvidence '2026-10-24T03:10:00-07:00'} 'directory'
    }
    It 'uses the spring DST due boundary rather than a fixed 24-hour age' {
        New-BackupFixture '2026-03-07T03:00:00-08:00' '2026-03-07T03:10:00-08:00'
        (Get-FixtureEvidence '2026-03-08T01:59:59-08:00').database | Should Be 'app_db'
        Assert-BackupError {Get-FixtureEvidence '2026-03-08T03:00:00-07:00'} 'stale'
        New-RunningFixture '2026-03-08T03:00:00-07:00'
        (Get-FixtureEvidence '2026-03-08T03:39:59-07:00').database | Should Be 'app_db'
        Assert-BackupError {Get-FixtureEvidence '2026-03-08T03:40:00-07:00'} 'stale'
    }
    It 'uses the fall DST due boundary across the 25-hour day' {
        New-BackupFixture '2026-10-31T03:00:00-07:00' '2026-10-31T03:10:00-07:00'
        (Get-FixtureEvidence '2026-11-01T02:59:59-08:00').database | Should Be 'app_db'
        Assert-BackupError {Get-FixtureEvidence '2026-11-01T03:00:00-08:00'} 'stale'
        New-RunningFixture '2026-11-01T03:00:00-08:00'
        (Get-FixtureEvidence '2026-11-01T03:39:59-08:00').database | Should Be 'app_db'
        Assert-BackupError {Get-FixtureEvidence '2026-11-01T03:40:00-08:00'} 'stale'
    }
    It 'accepts a completed current due run without inspecting unrelated older runs' {
        New-RunningFixture '2026-10-22T03:00:00-07:00'
        (Get-FixtureEvidence).database | Should Be 'app_db'
    }
}
