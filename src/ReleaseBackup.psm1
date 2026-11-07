#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SshTransport.psm1') -DisableNameChecking

function Get-ReleaseBackupEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]{0,43}$')][string]$Database,
        [string]$BackupRoot='C:\ProgramData\JimlerTech\PostgreSQL\backups',
        [DateTimeOffset]$Now=[DateTimeOffset]::Now,
        [Alias('DatabaseHost')][string]$ExpectedHost=$env:COMPUTERNAME
    )
    if($Database.StartsWith('sd_validate_')){throw 'A validation database cannot supply application backup evidence.'}
    if($ExpectedHost -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$'){throw 'Expected backup host must be a computer name.'}
    $zone=[TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
    $culture=[Globalization.CultureInfo]::InvariantCulture

    function Read-BackupTime($Record,[string]$Field) {
        $value=[DateTimeOffset]::MinValue
        if(-not $Record.ContainsKey($Field) -or $Record[$Field] -isnot [string] -or
            $Record[$Field] -notmatch '(Z|[+-]\d{2}:\d{2})$' -or
            -not [DateTimeOffset]::TryParse($Record[$Field],$culture,[Globalization.DateTimeStyles]::None,[ref]$value)){
            throw "Backup $Field must be a complete timestamp with an offset."
        }
        if($value -gt $Now){throw "Backup $Field is in the future."}
        if($value.Offset -ne [TimeZoneInfo]::ConvertTime($value,$zone).Offset){throw "Backup $Field must use the Pacific local offset."}
        $value
    }

    function Get-BackupRunName([DateTimeOffset]$Started) {
        'pg-'+[TimeZoneInfo]::ConvertTime($Started,$zone).ToString('yyyyMMdd-HHmmss',$culture)
    }

    $latestPath=Resolve-OwnedPath $BackupRoot 'latest-success.json'
    $latest=Read-DeploymentJson $latestPath
    foreach($field in @('status','host','databases','files')){
        if(-not $latest.ContainsKey($field)){throw "Latest backup record is missing $field."}
    }
    if($latest.status -cne 'Succeeded'){throw 'Latest backup status must be Succeeded.'}
    if($latest.host -ine $ExpectedHost){throw 'Latest backup host differs from the expected database host.'}
    $started=Read-BackupTime $latest 'startedLocal'
    $completed=Read-BackupTime $latest 'completedLocal'
    if($completed -lt $started){throw 'Backup completion precedes its start.'}
    $runName=Get-BackupRunName $started
    $manifestPath=Resolve-OwnedPath $BackupRoot ($runName+'\manifest.json')
    $manifestBytes=Invoke-DeploymentFileOperation ReadAllBytes @($manifestPath)
    $manifest=[Text.Encoding]::UTF8.GetString($manifestBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable -DateKind String
    if((ConvertTo-CanonicalJson $latest) -cne (ConvertTo-CanonicalJson $manifest)){
        throw 'Latest success record differs from its immutable run manifest.'
    }
    $destination='\\jimbrownhome\Shared\PostgreSQL\'+$ExpectedHost+'\'+$runName
    if(-not $manifest.ContainsKey('destination') -or $manifest.destination -isnot [string] -or
        $manifest.destination -ine $destination){
        throw 'Backup destination must be the complete expected off-host run path.'
    }
    $entries=@($manifest.databases | Where-Object { $_.name -ceq $Database })
    if($entries.Count -ne 1){throw "Backup must contain exactly one entry for application database $Database."}
    $entry=$entries[0]
    foreach($field in @('restored','countsMatched','bytes')){
        if(-not $entry.ContainsKey($field)){throw "Backup database entry is missing $field for $Database."}
    }
    if($entry.restored -isnot [bool] -or -not $entry.restored -or
        $entry.countsMatched -isnot [bool] -or -not $entry.countsMatched){
        throw "Backup restore and row counts are incomplete for $Database."
    }
    $hashes=@{}
    foreach($name in @("$Database.dump","$Database.counts.json")){
        $files=@($manifest.files | Where-Object { $_.path -ceq $name })
        if($files.Count -ne 1){throw "Backup must contain exactly one file record for $name."}
        $file=$files[0]
        foreach($field in @('sha256','bytes')){
            if(-not $file.ContainsKey($field)){throw "Backup file record is missing $field for $name."}
        }
        if($file.sha256 -isnot [string] -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            ($file.bytes -isnot [long] -and $file.bytes -isnot [int]) -or $file.bytes -le 0){
            throw "Backup file metadata is invalid for $name."
        }
        $path=Resolve-OwnedPath $BackupRoot ($runName+'\'+$name)
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Required backup file is missing: $name."}
        if((Get-Item -LiteralPath $path).Length -ne $file.bytes){throw "Backup file length differs for $name."}
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -ine $file.sha256){throw "Backup checksum differs for $name."}
        $hashes[$name]=$hash
    }
    if($entry.bytes -ne ($manifest.files | Where-Object { $_.path -ceq "$Database.dump" }).bytes){
        throw "Backup database dump length differs for $Database."
    }

    $localNow=[TimeZoneInfo]::ConvertTime($Now,$zone)
    $dueDate=$localNow.Date
    if($localNow.TimeOfDay -lt [TimeSpan]::FromHours(3)){$dueDate=$dueDate.AddDays(-1)}
    $due=[DateTimeOffset]::new($dueDate.AddHours(3),$zone.GetUtcOffset($dueDate.AddHours(3)))
    if($started -lt $due){
        $previousDate=$dueDate.AddDays(-1).AddHours(3)
        $previousDue=[DateTimeOffset]::new($previousDate,$zone.GetUtcOffset($previousDate))
        $running=$false
        if($started -ge $previousDue){
            foreach($directory in Get-ChildItem -LiteralPath $BackupRoot -Directory){
                if($directory.Name -notmatch '^pg-\d{8}-\d{6}$'){continue}
                $candidatePath=Resolve-OwnedPath $BackupRoot ($directory.Name+'\manifest.json')
                if(-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)){continue}
                $candidate=Read-DeploymentJson $candidatePath
                if($candidate.status -cne 'Running' -or $candidate.host -ine $ExpectedHost){continue}
                $runningStart=Read-BackupTime $candidate 'startedLocal'
                if($directory.Name -cne (Get-BackupRunName $runningStart)){throw 'Running backup directory differs from its start timestamp.'}
                if($runningStart -ge $due -and $runningStart -lt $due.AddMinutes(40) -and
                    $Now -lt $runningStart.AddMinutes(40)){$running=$true}
            }
        }
        if(-not $running){throw 'Backup is stale: the latest scheduled 03:00 Pacific run is not covered by success or a current Running manifest within its 40-minute deadline.'}
    }

    @{
        manifestPath=$manifestPath
        manifestSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant()
        startedLocal=$manifest.startedLocal
        completedLocal=$manifest.completedLocal
        database=$Database
        dumpSHA256=$hashes["$Database.dump"]
        countsSHA256=$hashes["$Database.counts.json"]
        destination=$manifest.destination
    }
}

Export-ModuleMember -Function Get-ReleaseBackupEvidence
