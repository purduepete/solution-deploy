#requires -Version 7.5
<#
Read-only checks for PostgreSQL, the managed PowerShell runtime and app health.
Test-HostDependencyObservations is pure: it evaluates an observations hashtable, so every check can be
unit tested without a host. Get-HostDependencyObservations gathers those observations with read-only
queries and file reads.
#>
Set-StrictMode -Version Latest

function ConvertTo-HostPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $Path.Trim().Trim('"').Replace('/', '\').TrimEnd('\')
}

function New-HostCheck {
    param([string]$Name, [string]$Status, [string]$Detail)
    [pscustomobject]@{ name = $Name; status = $Status; detail = $Detail }
}

function Get-HostProperty {
    param([AllowNull()]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function Test-HostIdentity {
    param([AllowNull()][string]$ComputerName, [Parameter(Mandatory)][string]$ExpectedHostName)
    $name = 'Running on the expected host'
    if ($ComputerName -ieq $ExpectedHostName) { New-HostCheck $name 'Passed' $ComputerName }
    else { New-HostCheck $name 'Failed' "Running on '$ComputerName', expected '$ExpectedHostName'." }
}

function Test-PostgresServiceImagePath {
    param([AllowNull()][string]$ImagePath, [Parameter(Mandatory)][string]$ExpectedDataDirectory)
    $name = 'PostgreSQL service uses the live data directory'
    $expected = ConvertTo-HostPath $ExpectedDataDirectory
    if (-not $ImagePath) { return New-HostCheck $name 'Failed' 'The postgresql-x64-18 service PathName could not be read.' }
    $normalized = $ImagePath.Replace('"', '').Replace('/', '\')
    $pattern = '(?i)(?:^|\s)-D\s+' + [regex]::Escape($expected) + '(?=\s|$)'
    if ($normalized -match $pattern) { New-HostCheck $name 'Passed' "PathName includes -D `"$expected`"." }
    else { New-HostCheck $name 'Failed' "PathName does not include -D `"$expected`": $ImagePath" }
}

function Test-PostgresDataDirectory {
    param([AllowNull()][string]$Observed, [Parameter(Mandatory)][string]$Expected)
    $name = 'PostgreSQL data_directory matches the live cluster'
    $actual = ConvertTo-HostPath $Observed
    $wanted = ConvertTo-HostPath $Expected
    if (-not $actual) { New-HostCheck $name 'Failed' 'SHOW data_directory returned nothing.' }
    elseif ($actual -ieq $wanted) { New-HostCheck $name 'Passed' $actual }
    else { New-HostCheck $name 'Failed' "PostgreSQL is serving '$actual', expected '$wanted'. An installer may have reset the data folder." }
}

function Test-PostgresClusterIdentity {
    param([AllowNull()][string]$Observed, [AllowNull()][string]$Expected)
    $name = 'PostgreSQL system_identifier'
    $actual = ([string]$Observed).Trim()
    if ($actual -notmatch '^\d+$') { return New-HostCheck $name 'Failed' "system_identifier could not be read: '$actual'" }
    if (-not $Expected) { return New-HostCheck $name 'Passed' "system_identifier $actual (no expected cluster id supplied)" }
    if ($actual -ceq $Expected.Trim()) { New-HostCheck $name 'Passed' "system_identifier $actual matches the expected cluster." }
    else { New-HostCheck $name 'Failed' "system_identifier $actual does not match expected $($Expected.Trim())." }
}

function Test-PostgresClientTools {
    param(
        [string]$Path,
        [bool]$Exists,
        [AllowNull()][string]$Version,
        [AllowNull()][string]$SHA256,
        [AllowNull()][string]$SignatureStatus,
        [AllowNull()][string]$SignerSubject
    )
    $versionName = 'psql.exe is present, reports its version and has a SHA-256 hash'
    if (-not $Exists) { $versionCheck = New-HostCheck $versionName 'Failed' "$Path was not found." }
    elseif ([string]$Version -notmatch '^psql \(PostgreSQL\) \d+') { $versionCheck = New-HostCheck $versionName 'Failed' "Unexpected psql --version output: '$Version'" }
    elseif ([string]$SHA256 -notmatch '^[A-Fa-f0-9]{64}$') { $versionCheck = New-HostCheck $versionName 'Failed' 'No SHA-256 hash was computed.' }
    else { $versionCheck = New-HostCheck $versionName 'Passed' "$Version; SHA-256 $($SHA256.ToUpperInvariant())" }

    $signatureName = 'psql.exe has a valid Authenticode signature'
    if ([string]::IsNullOrEmpty($SignatureStatus)) { $signatureCheck = New-HostCheck $signatureName 'Skipped' 'Not checked; pass -CheckSignature to verify.' }
    elseif ($SignatureStatus -ceq 'Valid') { $signatureCheck = New-HostCheck $signatureName 'Passed' "Valid signature: $SignerSubject" }
    else { $signatureCheck = New-HostCheck $signatureName 'Failed' "Signature status is '$SignatureStatus'." }

    @($versionCheck, $signatureCheck)
}

function Test-PgDumpMajorVersion {
    param([AllowNull()][string]$PgDumpVersion, [AllowNull()][string]$ServerVersionNum)
    $name = 'pg_dump major version matches the server'
    if ([string]$ServerVersionNum -notmatch '^\d+$') { return New-HostCheck $name 'Failed' "server_version_num could not be read: '$ServerVersionNum'" }
    if ([string]$PgDumpVersion -notmatch 'pg_dump \(PostgreSQL\) (\d+)') { return New-HostCheck $name 'Failed' "pg_dump --version output was not recognized: '$PgDumpVersion'" }
    $serverMajor = [int][Math]::Floor([int]$ServerVersionNum / 10000)
    $dumpMajor = [int]$Matches[1]
    if ($serverMajor -eq $dumpMajor) { New-HostCheck $name 'Passed' "Both are PostgreSQL $serverMajor." }
    else { New-HostCheck $name 'Failed' "Server is PostgreSQL $serverMajor but pg_dump is $dumpMajor." }
}

function Test-PostgresAuthenticationFailures {
    param([AllowNull()]$Failures, [Parameter(Mandatory)][datetimeoffset]$Now, [Parameter(Mandatory)][int]$LookbackHours)
    $name = "No 'password authentication failed' entries in the last $LookbackHours hours"
    $cutoff = $Now.AddHours(-$LookbackHours)
    $recent = @($Failures | Where-Object {
        $message = [string](Get-HostProperty $_ 'message')
        $time = Get-HostProperty $_ 'time'
        $message -match 'password authentication failed' -and $null -ne $time -and [datetimeoffset]$time -ge $cutoff
    })
    if ($recent.Count -eq 0) { return New-HostCheck $name 'Passed' 'None found.' }
    $latest = ($recent | ForEach-Object { [datetimeoffset](Get-HostProperty $_ 'time') } | Sort-Object -Descending | Select-Object -First 1).ToString('o')
    $fallback = @($recent | Where-Object { (Get-HostProperty $_ 'timeSource') -eq 'file LastWriteTime' }).Count
    $note = if ($fallback) { " $fallback of these lines had no parseable timestamp and were dated by the file's LastWriteTime." } else { '' }
    New-HostCheck $name 'Failed' "$($recent.Count) failed authentication(s); latest $latest. An app or the backup is using a stale password.$note"
}

$script:PostgresLogTimeZoneHours = @{ UTC = 0; GMT = 0; PST = -8; PDT = -7; MST = -7; MDT = -6; CST = -6; CDT = -5; EST = -5; EDT = -4 }

function ConvertFrom-PostgresLogLine {
    <#
    Reads the leading timestamp of a PostgreSQL log line (log_line_prefix %m, %t or %Z forms).
    Returns $null when the line does not start with a timestamp. A line without a zone uses the host's local offset.
    #>
    param([Parameter(Mandatory)][string]$Line)
    $pattern = '^(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,7})?)(?: (?<tz>[+-]\d{2}(?::?\d{2})?|UTC|GMT|[PMCE][SD]T))?(?=[\s\[]|$)'
    if ($Line -notmatch $pattern) { return $null }
    $stamp = $Matches['ts']
    $local = [datetime]::ParseExact($stamp.Split('.')[0], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
    if ($stamp.Contains('.')) { $local = $local.AddTicks([long]$stamp.Split('.')[1].PadRight(7, '0').Substring(0, 7)) }
    $zone = $Matches['tz']
    if (-not $zone) { return [datetimeoffset]::new($local, [TimeZoneInfo]::Local.GetUtcOffset($local)) }
    if ($zone -match '^(?<sign>[+-])(?<h>\d{2}):?(?<m>\d{2})?$') {
        $minutes = ([int]$Matches['h'] * 60) + [int]('0' + $Matches['m'])
        if ($Matches['sign'] -eq '-') { $minutes = -$minutes }
        $offset = [timespan]::FromMinutes($minutes)
    } else {
        $offset = [timespan]::FromHours($script:PostgresLogTimeZoneHours[$zone])
    }
    [datetimeoffset]::new($local, $offset)
}

function Get-PostgresLogAuthenticationEntries {
    <#
    Returns one entry per 'password authentication failed' line in log files written since the cutoff.
    Each entry is dated by its own line timestamp. A matching line with no parseable timestamp falls back to the
    file's LastWriteTime and is marked timeSource 'file LastWriteTime'. Lines older than the cutoff are dropped.
    #>
    param([Parameter(Mandatory)][string]$LogFolder, [Parameter(Mandatory)][datetimeoffset]$Cutoff)
    if (-not (Test-Path -LiteralPath $LogFolder -PathType Container)) { return @() }
    $entries = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -LiteralPath $LogFolder -File | Where-Object { [datetimeoffset]$_.LastWriteTime -ge $Cutoff })
    foreach ($file in $files) {
        $lastWrite = [datetimeoffset]$file.LastWriteTime
        foreach ($match in @(Select-String -LiteralPath $file.FullName -Pattern 'password authentication failed' -SimpleMatch)) {
            $time = ConvertFrom-PostgresLogLine $match.Line
            $timeSource = 'line timestamp'
            if ($null -eq $time) { $time = $lastWrite; $timeSource = 'file LastWriteTime' }
            if ($time -ge $Cutoff) {
                $entries.Add(@{ source = $file.FullName; time = $time; timeSource = $timeSource; message = $match.Line })
            }
        }
    }
    $entries.ToArray()
}


function Test-PostgresBackupManifest {
    param([AllowNull()]$Manifest, [Parameter(Mandatory)][datetimeoffset]$Now, [Parameter(Mandatory)][int]$MaxBackupAgeHours)
    $name = 'Latest successful PostgreSQL backup is recent'
    if ($null -eq $Manifest) { return New-HostCheck $name 'Failed' 'latest-success.json is missing or unreadable.' }
    $status = [string](Get-HostProperty $Manifest 'status')
    if ($status -cne 'Succeeded') { return New-HostCheck $name 'Failed' "latest-success.json has status '$status'." }
    $parsed = [datetimeoffset]::MinValue
    $completed = [string](Get-HostProperty $Manifest 'completedLocal')
    if (-not [datetimeoffset]::TryParse($completed, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return New-HostCheck $name 'Failed' "completedLocal could not be read: '$completed'"
    }
    $age = $Now - $parsed
    if ($age -lt [timespan]::FromMinutes(-5)) { New-HostCheck $name 'Failed' "Backup completion $($parsed.ToString('o')) is in the future." }
    elseif ($age -gt [timespan]::FromHours($MaxBackupAgeHours)) { New-HostCheck $name 'Failed' "Last backup completed $([int]$age.TotalHours) hours ago; limit is $MaxBackupAgeHours." }
    else { New-HostCheck $name 'Passed' "Completed $($parsed.ToString('o')) ($([math]::Round($age.TotalHours, 1)) hours ago)." }
}

function Test-PowerShellRuntimeLinks {
    param([Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)][hashtable]$Links)
    $name = 'Managed PowerShell junctions 7 and previous point to versions\7.x.y'
    $versions = ConvertTo-HostPath (Join-Path $RuntimeRoot 'versions')
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($linkName in '7', 'previous') {
        $link = $Links[$linkName]
        if ($null -eq $link) { $problems.Add("$linkName is missing."); continue }
        if (-not $link['isJunction']) { $problems.Add("$linkName is not a junction."); continue }
        $target = ConvertTo-HostPath ([string]$link['target'])
        if (-not $target -or (Split-Path -Parent $target) -ine $versions -or (Split-Path -Leaf $target) -notmatch '^7\.\d+\.\d+$') {
            $problems.Add("$linkName targets '$target', not a versions\7.x.y folder.")
        } elseif (-not $link['executableExists']) {
            $problems.Add("$linkName target has no pwsh.exe.")
        }
    }
    if ($problems.Count) { New-HostCheck $name 'Failed' ($problems -join ' ') }
    else { New-HostCheck $name 'Passed' "7 -> $($Links['7']['target']); previous -> $($Links['previous']['target'])" }
}

function Test-PowerShellSubsystem {
    param([AllowNull()][string]$SshdConfigText, [Parameter(Mandatory)][string]$ManagedExecutable)
    $name = 'sshd PowerShell subsystem uses the managed runtime'
    if ($null -eq $SshdConfigText) { return New-HostCheck $name 'Failed' 'sshd_config could not be read.' }
    $expected = ConvertTo-HostPath $ManagedExecutable
    $found = @([regex]::Matches($SshdConfigText, '(?im)^\s*Subsystem\s+powershell\s+("[^"]+"|\S+)') |
        ForEach-Object { ConvertTo-HostPath $_.Groups[1].Value })
    if ($found.Count -eq 0) { return New-HostCheck $name 'Failed' 'No "Subsystem powershell" line was found.' }
    $wrong = @($found | Where-Object { $_ -ine $expected })
    if ($wrong.Count) { New-HostCheck $name 'Failed' "Subsystem points to '$($wrong -join "', '")', expected '$expected'." }
    else { New-HostCheck $name 'Passed' "Subsystem uses $expected." }
}

function Test-PowerShellScheduledTasks {
    param([AllowNull()]$Tasks, [Parameter(Mandatory)][string]$ManagedExecutable)
    $name = 'JimlerTech tasks launch the managed pwsh.exe'
    $expected = ConvertTo-HostPath $ManagedExecutable
    $drifted = [System.Collections.Generic.List[string]]::new()
    $count = 0
    foreach ($task in @($Tasks)) {
        $execute = ConvertTo-HostPath ([string](Get-HostProperty $task 'execute'))
        if (-not $execute -or [IO.Path]::GetFileName($execute) -inotmatch '^pwsh(\.exe)?$') { continue }
        $count++
        if ($execute -ine $expected) { $drifted.Add("$(Get-HostProperty $task 'path')$(Get-HostProperty $task 'name') -> '$execute'") }
    }
    if ($drifted.Count) { New-HostCheck $name 'Failed' "Tasks not using ${expected}: $($drifted -join '; ')" }
    else { New-HostCheck $name 'Passed' "$count pwsh task action(s) use the managed runtime." }
}

function Test-PowerShellVersionParity {
    param([AllowNull()][string]$ControllerVersion, [AllowNull()][string]$HostVersion)
    $name = 'Controller and host PowerShell share Major.Minor'
    if ([string]::IsNullOrWhiteSpace($ControllerVersion)) {
        return New-HostCheck $name 'Skipped' 'Pass -ControllerVersion <major.minor.patch> from the controller to verify parity.'
    }
    try {
        $controller = [version]$ControllerVersion
        $remote = [version]$HostVersion
    } catch {
        return New-HostCheck $name 'Failed' "Versions could not be read: controller '$ControllerVersion', host '$HostVersion'."
    }
    if ($controller.Major -eq $remote.Major -and $controller.Minor -eq $remote.Minor) { New-HostCheck $name 'Passed' "Host $HostVersion, controller $ControllerVersion." }
    else { New-HostCheck $name 'Failed' "Host runs PowerShell $HostVersion but the controller runs $ControllerVersion." }
}

function Get-AppHealthUrl {
    <#
    Builds an app's readiness URL: the origin of its localUrl plus the readiness path from releases.json.
    Apps without a readiness path are checked at localUrl as-is.
    #>
    param([Parameter(Mandatory)][string]$LocalUrl, [AllowNull()]$Readiness)
    $readinessPath = if ($Readiness -is [string]) { $Readiness } else { [string](Get-HostProperty $Readiness 'path') }
    if (-not $readinessPath) { return $LocalUrl }
    $origin = [uri]::new($LocalUrl).GetLeftPart([UriPartial]::Authority)
    $origin.TrimEnd('/') + '/' + $readinessPath.TrimStart('/')
}

function Get-AppHealthTargets {
    <#
    Returns id and readiness URL for each site that has an application (static 'None' databases are skipped).
    Readiness comes from the app entry with the same id in releases.json.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Sites, [AllowNull()]$Releases)
    $apps = Get-HostProperty $Releases 'apps'
    foreach ($site in @($Sites)) {
        $id = [string](Get-HostProperty $site 'id')
        $localUrl = [string](Get-HostProperty $site 'localUrl')
        if (-not $localUrl -or [string](Get-HostProperty $site 'database') -like 'None*') { continue }
        $readiness = Get-HostProperty (Get-HostProperty $apps $id) 'readiness'
        [pscustomobject]@{ id = $id; url = (Get-AppHealthUrl -LocalUrl $localUrl -Readiness $readiness); expected = (Get-HostProperty $readiness 'expected') }
    }
}

# Returns why a readiness body fails releases.json readiness.expected, or $null when every expected field matches.
function Get-ReadinessBodyMismatch {
    param([AllowNull()][string]$Body, [AllowNull()]$Expected)
    if ($null -eq $Expected) { return $null }
    try { $parsed = $Body | ConvertFrom-Json -AsHashtable -DateKind String }
    catch { return "the body is not valid JSON: $($_.Exception.Message)" }
    if ($parsed -isnot [hashtable]) { return 'the body is not a JSON object.' }
    $wanted = @{}
    if ($Expected -is [System.Collections.IDictionary]) { foreach ($key in $Expected.Keys) { $wanted[[string]$key] = $Expected[$key] } }
    else { foreach ($property in $Expected.PSObject.Properties) { $wanted[$property.Name] = $property.Value } }
    foreach ($key in $wanted.Keys) {
        if (-not $parsed.ContainsKey($key)) { return "readiness field '$key' is missing." }
        $want = ConvertTo-Json -InputObject $wanted[$key] -Compress -Depth 10
        $got = ConvertTo-Json -InputObject $parsed[$key] -Compress -Depth 10
        if ($got -cne $want) { return "readiness field '$key' is $got, expected $want." }
    }
    $null
}


function Test-AppHealthEndpoints {
    param([AllowNull()]$Apps)
    if ($null -eq $Apps) { return @(New-HostCheck 'App health endpoints' 'Skipped' 'Not checked; pass -CheckApps to verify.') }
    foreach ($app in @($Apps)) {
        $id = Get-HostProperty $app 'id'
        $url = Get-HostProperty $app 'url'
        $code = [int](Get-HostProperty $app 'statusCode')
        $name = "App health: $id"
        if ($code -lt 200 -or $code -gt 299) {
            $reason = [string](Get-HostProperty $app 'error')
            New-HostCheck $name 'Failed' "$url returned HTTP $code$(if ($reason) { ": $reason" })"
            continue
        }
        $mismatch = Get-ReadinessBodyMismatch -Body ([string](Get-HostProperty $app 'body')) -Expected (Get-HostProperty $app 'expected')
        if ($mismatch) { New-HostCheck $name 'Failed' "$url returned HTTP $code but $mismatch" }
        else { New-HostCheck $name 'Passed' "HTTP $code from $url" }
    }
}

function Test-CollectorStatusSnapshot {
    param([AllowNull()]$Snapshot, [Parameter(Mandatory)][datetimeoffset]$Now, [Parameter(Mandatory)][int]$MaxAgeMinutes)
    $name = 'Collector status snapshot is fresh and error-free'
    if ($null -eq $Snapshot) { return New-HostCheck $name 'Failed' 'collector-status.json is missing or unreadable.' }
    if ([int](Get-HostProperty $Snapshot 'schemaVersion') -ne 1) { return New-HostCheck $name 'Failed' 'collector-status.json has an unexpected schemaVersion.' }
    $generated = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string](Get-HostProperty $Snapshot 'generatedAt'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$generated)) {
        return New-HostCheck $name 'Failed' 'generatedAt could not be read.'
    }
    if ($Now - $generated -gt [timespan]::FromMinutes($MaxAgeMinutes)) {
        return New-HostCheck $name 'Failed' "Snapshot generated $($generated.ToString('o')) is older than $MaxAgeMinutes minutes."
    }
    $collectorErrors = @(Get-HostProperty $Snapshot 'errors')
    if ($collectorErrors.Count) { New-HostCheck $name 'Failed' "$($collectorErrors.Count) collector error(s): $($collectorErrors[0])" }
    else { New-HostCheck $name 'Passed' "Generated $($generated.ToString('o')) with no errors." }
}

function Test-HostDependencyObservations {
    <#
    Evaluates gathered observations. Expected keys: computerName, expectedHostName, now (datetimeoffset),
    errors (gather failures), expectedDataDirectory, expectedClusterId, lookbackHours, maxBackupAgeHours,
    collectorMaxAgeMinutes, serviceImagePath, dataDirectory, systemIdentifier, serverVersionNum,
    psql (hashtable), pgDumpVersion, authFailures, backupManifest, runtimeRoot, managedExecutable,
    links (hashtable), sshdConfigText, tasks, controllerVersion, hostVersion, apps (null = skipped),
    collectorStatus.
    #>
    param([Parameter(Mandatory)][hashtable]$Observations)
    $o = $Observations
    $now = [datetimeoffset]$o['now']
    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add((Test-HostIdentity $o['computerName'] $o['expectedHostName']))
    $gatherErrors = @($o['errors'])
    $checks.Add($(if ($gatherErrors.Count) { New-HostCheck 'Observations gathered without errors' 'Failed' ($gatherErrors -join ' | ') }
            else { New-HostCheck 'Observations gathered without errors' 'Passed' 'All read-only queries and reads succeeded.' }))
    $checks.Add((Test-PostgresServiceImagePath $o['serviceImagePath'] $o['expectedDataDirectory']))
    $checks.Add((Test-PostgresDataDirectory $o['dataDirectory'] $o['expectedDataDirectory']))
    $checks.Add((Test-PostgresClusterIdentity $o['systemIdentifier'] $o['expectedClusterId']))
    $psql = $o['psql']
    @(Test-PostgresClientTools -Path $psql['path'] -Exists ([bool]$psql['exists']) -Version $psql['version'] -SHA256 $psql['sha256'] `
            -SignatureStatus $psql['signatureStatus'] -SignerSubject $psql['signerSubject']) | ForEach-Object { $checks.Add($_) }
    $checks.Add((Test-PgDumpMajorVersion $o['pgDumpVersion'] $o['serverVersionNum']))
    $checks.Add((Test-PostgresAuthenticationFailures $o['authFailures'] $now ([int]$o['lookbackHours'])))
    $checks.Add((Test-PostgresBackupManifest $o['backupManifest'] $now ([int]$o['maxBackupAgeHours'])))
    $checks.Add((Test-PowerShellRuntimeLinks $o['runtimeRoot'] $o['links']))
    $checks.Add((Test-PowerShellSubsystem $o['sshdConfigText'] $o['managedExecutable']))
    $checks.Add((Test-PowerShellScheduledTasks $o['tasks'] $o['managedExecutable']))
    $checks.Add((Test-PowerShellVersionParity $o['controllerVersion'] $o['hostVersion']))
    @(Test-AppHealthEndpoints $o['apps']) | ForEach-Object { $checks.Add($_) }
    if ($null -eq $o['apps']) {
        $checks.Add((New-HostCheck 'Collector status snapshot' 'Skipped' 'Not checked; pass -CheckApps to verify.'))
    } else {
        $checks.Add((Test-CollectorStatusSnapshot $o['collectorStatus'] $now ([int]$o['collectorMaxAgeMinutes'])))
    }

    $failures = @($checks | Where-Object status -eq 'Failed' | ForEach-Object { "$($_.name): $($_.detail)" })
    [pscustomobject]@{
        status = if ($failures.Count) { 'Failed' } else { 'Passed' }
        hostName = $o['computerName']
        checkedAt = $now.ToString('o')
        checks = $checks.ToArray()
        failures = $failures
    }
}

function Invoke-HostTool {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 60)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Tool not found: $Path" }
    $info = [Diagnostics.ProcessStartInfo]::new($Path)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw "$Path exceeded $TimeoutSeconds seconds."
        }
        $process.WaitForExit()
        $text = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$(Split-Path -Leaf $Path) failed ($($process.ExitCode)): $($errorText.Trim())" }
        $text.Trim()
    } finally { $process.Dispose() }
}

function Get-HostDependencyObservations {
    <#
    Read-only gatherer for jimbrownhome1. Each probe records its error instead of stopping, so the
    report shows every failing dependency. Queries run in a read-only session.
    #>
    param(
        [string]$ExpectedHostName = 'jimbrownhome1',
        [string]$ServiceName = 'postgresql-x64-18',
        [string]$ExpectedDataDirectory = 'D:\data\postgres',
        [string]$ExpectedClusterId = '',
        [string]$ToolDirectory = 'C:\Program Files\PostgreSQL\18\bin',
        [string]$PassFile = 'C:\ProgramData\JimlerTech\PostgreSQL\postgres.pgpass',
        [string]$BackupRoot = 'C:\ProgramData\JimlerTech\PostgreSQL\backups',
        [string]$RuntimeRoot = 'C:\ProgramData\SolutionDeploy\runtime\powershell',
        [string]$SshdConfigPath = 'C:\ProgramData\ssh\sshd_config',
        [string]$SitesPath,
        [string]$ReleasesPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'environments\releases.json'),
        [string]$CollectorStatusPath = 'C:\ProgramData\SolutionDeploy\apps\solution-deploy\data\collector-status.json',
        [string]$ControllerVersion = '',
        [int]$LookbackHours = 24,
        [int]$MaxBackupAgeHours = 36,
        [int]$CollectorMaxAgeMinutes = 30,
        [switch]$CheckSignature,
        [switch]$CheckApps
    )
    $probeErrors = [System.Collections.Generic.List[string]]::new()
    function Invoke-Probe([string]$Name, [scriptblock]$Probe) {
        try { & $Probe } catch { $probeErrors.Add("${Name}: $($_.Exception.Message)"); $null }
    }

    $psql = Join-Path $ToolDirectory 'psql.exe'
    $pgDump = Join-Path $ToolDirectory 'pg_dump.exe'
    $managedExecutable = Join-Path $RuntimeRoot '7\pwsh.exe'
    $previousEnv = @{ PGPASSFILE = $env:PGPASSFILE; PGOPTIONS = $env:PGOPTIONS; PGCONNECT_TIMEOUT = $env:PGCONNECT_TIMEOUT }
    $env:PGPASSFILE = $PassFile
    $env:PGCONNECT_TIMEOUT = '15'
    $env:PGOPTIONS = '-c default_transaction_read_only=on -c statement_timeout=30000'
    try {
        $query = {
            param([string]$Sql)
            Invoke-HostTool $psql @('-X', '-qAt', '-w', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-c', $Sql)
        }
        $serviceImagePath = Invoke-Probe 'service' {
            $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
            if ($service) { [string]$service.PathName }
        }
        $dataDirectory = Invoke-Probe 'data_directory' { & $query 'SHOW data_directory;' }
        $systemIdentifier = Invoke-Probe 'system_identifier' { & $query 'SELECT system_identifier FROM pg_control_system();' }
        $serverVersionNum = Invoke-Probe 'server_version_num' { & $query 'SHOW server_version_num;' }
        $psqlVersion = Invoke-Probe 'psql --version' { Invoke-HostTool $psql @('--version') }
        $pgDumpVersion = Invoke-Probe 'pg_dump --version' { Invoke-HostTool $pgDump @('--version') }
        $psqlHash = Invoke-Probe 'psql hash' { if (Test-Path -LiteralPath $psql -PathType Leaf) { (Get-FileHash -LiteralPath $psql -Algorithm SHA256).Hash } }
        $signatureStatus = $null
        $signerSubject = $null
        if ($CheckSignature) {
            $signature = Invoke-Probe 'psql signature' { Get-AuthenticodeSignature -LiteralPath $psql -ErrorAction Stop }
            if ($signature) {
                $signatureStatus = [string]$signature.Status
                $signerSubject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
            }
        }
        $dataDirectoryPath = ConvertTo-HostPath $dataDirectory
        $authFailures = @(Invoke-Probe 'authentication log' {
                $cutoff = [datetimeoffset]::Now.AddHours(-$LookbackHours)
                $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $cutoff.LocalDateTime } -ErrorAction SilentlyContinue |
                        Where-Object { $_.Message -match 'password authentication failed' } |
                        ForEach-Object { @{ source = 'Application'; time = $_.TimeCreated; timeSource = 'event TimeCreated'; message = $_.Message } })
                $logFolder = if ($dataDirectoryPath) { Join-Path $dataDirectoryPath 'log' } else { $null }
                if ($logFolder) { $events += @(Get-PostgresLogAuthenticationEntries -LogFolder $logFolder -Cutoff $cutoff) }
                $events
            })
        $manifest = Invoke-Probe 'latest-success.json' {
            $path = Join-Path $BackupRoot 'latest-success.json'
            if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
        }
        $links = @{}
        foreach ($linkName in '7', 'previous') {
            $item = Invoke-Probe "runtime link $linkName" { Get-Item -LiteralPath (Join-Path $RuntimeRoot $linkName) -Force -ErrorAction SilentlyContinue }
            $links[$linkName] = if ($item) {
                @{ isJunction = ($item.LinkType -eq 'Junction'); target = [string](@($item.Target)[0]); executableExists = (Test-Path -LiteralPath (Join-Path $item.FullName 'pwsh.exe') -PathType Leaf) }
            } else { @{ isJunction = $false; target = ''; executableExists = $false } }
        }
        $sshdText = Invoke-Probe 'sshd_config' { if (Test-Path -LiteralPath $SshdConfigPath -PathType Leaf) { Get-Content -LiteralPath $SshdConfigPath -Raw } }
        $tasks = @(Invoke-Probe 'scheduled tasks' {
                Get-ScheduledTask -TaskPath '\JimlerTech\*' -ErrorAction SilentlyContinue | ForEach-Object {
                    $task = $_
                    foreach ($action in @($task.Actions)) {
                        if ($action.PSObject.Properties['Execute']) {
                            @{ path = $task.TaskPath; name = $task.TaskName; execute = [string]$action.Execute }
                        }
                    }
                }
            })
        $hostVersion = Invoke-Probe 'managed PowerShell version' {
            Invoke-HostTool $managedExecutable @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString()')
        }
        $apps = $null
        $collectorStatus = $null
        if ($CheckApps) {
            $apps = @(Invoke-Probe 'app health targets' {
                    $sites = @((Get-Content -LiteralPath $SitesPath -Raw | ConvertFrom-Json).sites)
                    $releases = Get-Content -LiteralPath $ReleasesPath -Raw | ConvertFrom-Json
                    foreach ($target in @(Get-AppHealthTargets -Sites $sites -Releases $releases)) {
                        $code = 0
                        $reason = ''
                        $body = ''
                        try {
                            $response = Invoke-WebRequest -UseBasicParsing -Uri $target.url -TimeoutSec 10
                            $code = [int]$response.StatusCode
                            $body = [string]$response.Content
                        } catch {
                            $reason = $_.Exception.Message
                            if ($_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) {
                                $code = [int]$_.Exception.Response.StatusCode
                            }
                        }
                        @{ id = $target.id; url = $target.url; statusCode = $code; error = $reason; body = $body; expected = $target.expected }
                    }
                })
            $collectorStatus = Invoke-Probe 'collector-status.json' {
                if (Test-Path -LiteralPath $CollectorStatusPath -PathType Leaf) { Get-Content -LiteralPath $CollectorStatusPath -Raw | ConvertFrom-Json }
            }
        }
        @{
            computerName = $env:COMPUTERNAME
            expectedHostName = $ExpectedHostName
            now = [datetimeoffset]::Now
            errors = $probeErrors.ToArray()
            expectedDataDirectory = $ExpectedDataDirectory
            expectedClusterId = $ExpectedClusterId
            lookbackHours = $LookbackHours
            maxBackupAgeHours = $MaxBackupAgeHours
            collectorMaxAgeMinutes = $CollectorMaxAgeMinutes
            serviceImagePath = $serviceImagePath
            dataDirectory = $dataDirectory
            systemIdentifier = $systemIdentifier
            serverVersionNum = $serverVersionNum
            psql = @{ path = $psql; exists = (Test-Path -LiteralPath $psql -PathType Leaf); version = $psqlVersion; sha256 = $psqlHash; signatureStatus = $signatureStatus; signerSubject = $signerSubject }
            pgDumpVersion = $pgDumpVersion
            authFailures = $authFailures
            backupManifest = $manifest
            runtimeRoot = $RuntimeRoot
            managedExecutable = $managedExecutable
            links = $links
            sshdConfigText = $sshdText
            tasks = $tasks
            controllerVersion = $ControllerVersion
            hostVersion = $hostVersion
            apps = $apps
            collectorStatus = $collectorStatus
        }
    } finally {
        foreach ($name in $previousEnv.Keys) {
            if ($null -eq $previousEnv[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath "Env:$name" -Value $previousEnv[$name] }
        }
    }
}

Export-ModuleMember -Function Test-HostDependencyObservations, Get-HostDependencyObservations, Test-PostgresServiceImagePath, Test-PostgresDataDirectory, Test-PostgresClusterIdentity, Test-PostgresClientTools, Test-PgDumpMajorVersion, Test-PostgresAuthenticationFailures, ConvertFrom-PostgresLogLine, Get-PostgresLogAuthenticationEntries, Test-PostgresBackupManifest, Test-PowerShellRuntimeLinks, Test-PowerShellSubsystem, Test-PowerShellScheduledTasks, Test-PowerShellVersionParity, Get-AppHealthUrl, Get-AppHealthTargets, Get-ReadinessBodyMismatch, Test-AppHealthEndpoints, Test-CollectorStatusSnapshot, Test-HostIdentity
