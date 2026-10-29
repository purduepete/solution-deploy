#Requires -Version 7.5
Set-StrictMode -Version Latest

# Lifecycle primitives for one SolutionDeploy app on a local Windows host.
# Layout under AppRoot: releases\<id>, current, shared\{data,secrets,logs,backups,run}, state.
# shared\run is runtime-writable, so everything read from it is untrusted until validated.
# state is admin-controlled; the runtime account only reads state\maintenance.json.

$script:StopFileName = 'STOP'
$script:OwnerFileName = 'process.json'
$script:LockFileName = 'lifecycle.lock'
$script:MaintenanceFileName = 'maintenance.json'
$script:MaxRecordBytes = 16KB
$script:MaxSecretFileBytes = 64KB
$script:MaxReadinessBodyBytes = 1MB
$script:EnvNamePattern = '^[A-Za-z_][A-Za-z0-9_]{0,127}$'
$script:AppIdPattern = '^[a-z][a-z0-9-]{1,39}$'
# All tasks this toolkit registers live in this Task Scheduler folder; task names stay SolutionDeploy-<AppId>.
$script:TaskPath = '\JimlerTech\'
$script:ModulePath = $PSCommandPath

#region Path guards

function Get-NormalizedFullPath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path, [string]$Name = 'Path')
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name is empty." }
    if ($Path.IndexOfAny([char[]]@('"', '*', '?', '<', '>', '|', "`0", "`r", "`n")) -ge 0) {
        throw "$Name contains characters that are not allowed: $Path"
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($Path)) { throw "$Name must be an absolute path: $Path" }
    if ($Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) { throw "$Name must not use a device path prefix: $Path" }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-PathIsUnder {
    param([Parameter(Mandatory)][string]$Child, [Parameter(Mandatory)][string]$Parent)
    $p = $Parent.TrimEnd('\') + '\'
    return $Child.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SamePath {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false }
    return [string]::Equals($A.TrimEnd('\'), $B.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NotReparsePoint {
    param([Parameter(Mandatory)][string]$Path, [string]$Name = 'Path')
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "$Name is a reparse point (link or junction) and is not trusted: $Path"
    }
    return $item
}

function Assert-Directory {
    param([Parameter(Mandatory)][string]$Path, [string]$Name = 'Directory')
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name does not exist: $Path" }
    [void](Assert-NotReparsePoint -Path $Path -Name $Name)
}

function Get-AppLayout {
    <#
    .SYNOPSIS
    Returns the fixed AppRoot layout paths. Does not touch the disk.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot)
    $root = Get-NormalizedFullPath -Path $AppRoot -Name 'AppRoot'
    $shared = Join-Path $root 'shared'
    $run = Join-Path $shared 'run'
    $state = Join-Path $root 'state'
    return [ordered]@{
        Root            = $root
        Releases        = Join-Path $root 'releases'
        Current         = Join-Path $root 'current'
        Shared          = $shared
        Data            = Join-Path $shared 'data'
        Secrets         = Join-Path $shared 'secrets'
        Logs            = Join-Path $shared 'logs'
        Backups         = Join-Path $shared 'backups'
        Run             = $run
        State           = $state
        MaintenanceFile = Join-Path $state $script:MaintenanceFileName
        OwnerFile       = Join-Path $run $script:OwnerFileName
        StopFile        = Join-Path $run $script:StopFileName
        LockFile        = Join-Path $run $script:LockFileName
    }
}

function Assert-AppLayout {
    param([Parameter(Mandatory)]$Layout)
    Assert-Directory -Path $Layout.Root -Name 'AppRoot'
    foreach ($key in 'Releases', 'Shared', 'Data', 'Secrets', 'Logs', 'Run', 'State') {
        Assert-Directory -Path $Layout[$key] -Name "AppRoot $key directory"
    }
}

function Resolve-ReleaseDirectory {
    # Accepts releases\<id> directly or the AppRoot\current link; returns the real releases\<id> path.
    param([Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$ReleasePath)
    $full = Get-NormalizedFullPath -Path $ReleasePath -Name 'ReleasePath'
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "ReleasePath does not exist: $full" }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        if (-not (Test-SamePath $full $Layout.Current)) {
            throw "ReleasePath is a link but is not AppRoot\current: $full"
        }
        $target = @($item.Target) | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($target)) { throw 'AppRoot\current has no readable link target.' }
        if (-not [System.IO.Path]::IsPathFullyQualified($target)) { $target = Join-Path $Layout.Root $target }
        $full = Get-NormalizedFullPath -Path $target -Name 'AppRoot\current target'
        Assert-Directory -Path $full -Name 'Release directory'
    }
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not (Test-SamePath $parent $Layout.Releases)) {
        throw "ReleasePath must be a direct child of $($Layout.Releases): $full"
    }
    return $full
}

function Resolve-UnderRelease {
    # Rebases a path given through AppRoot\current onto the resolved release.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$Release)
    if (Test-PathIsUnder -Child $Path -Parent $Layout.Current) {
        return Join-Path $Release $Path.Substring($Layout.Current.Length + 1)
    }
    return $Path
}

function Resolve-RuntimeExecutable {
    param([Parameter(Mandatory)][string]$RuntimePath, [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$Release)
    $full = Get-NormalizedFullPath -Path $RuntimePath -Name 'RuntimePath'
    $full = Resolve-UnderRelease -Path $full -Layout $Layout -Release $Release
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "RuntimePath does not exist: $full" }
    $leaf = [System.IO.Path]::GetFileName($full)
    switch ($Kind) {
        'node' {
            if ($leaf -ne 'node.exe') { throw "RuntimePath for a node app must be node.exe: $full" }
        }
        'python' {
            $expected = Join-Path $Release '.venv\Scripts\python.exe'
            if (-not (Test-SamePath $full $expected)) {
                throw "RuntimePath for a python app must be the release virtual environment: $expected"
            }
        }
        default { throw "Unsupported runtime kind: $Kind" }
    }
    [void](Assert-NotReparsePoint -Path $full -Name 'RuntimePath')
    return $full
}

#endregion

#region Manifest

function Get-ManifestValue {
    param($Map, [string]$Key)
    if ($null -eq $Map -or -not ($Map -is [System.Collections.IDictionary])) { return $null }
    if ($Map.Contains($Key)) { return $Map[$Key] }
    return $null
}

function Assert-LifecycleManifest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Manifest)
    $id = Get-ManifestValue $Manifest 'id'
    if (-not ($id -is [string]) -or $id -cnotmatch $script:AppIdPattern) { throw 'Manifest id is missing or invalid.' }
    $runtime = Get-ManifestValue $Manifest 'runtime'
    $kind = Get-ManifestValue $runtime 'kind'
    if ($kind -cnotin @('node', 'python')) { throw 'Manifest runtime.kind must be node or python.' }
    $launch = Get-ManifestValue $Manifest 'launch'
    if (-not ($launch -is [System.Collections.IDictionary])) { throw 'Manifest launch is missing.' }
    $entry = Get-ManifestValue $launch 'entrypoint'
    if (-not ($entry -is [string]) -or [string]::IsNullOrWhiteSpace($entry)) { throw 'Manifest launch.entrypoint is missing.' }
    $port = Get-ManifestValue $launch 'port'
    if (-not ($port -is [int] -or $port -is [long]) -or $port -lt 1024 -or $port -gt 65535) {
        throw 'Manifest launch.port must be an integer from 1024 to 65535.'
    }
    $arguments = Get-ManifestValue $launch 'arguments'
    if ($null -ne $arguments) {
        foreach ($a in @($arguments)) { if (-not ($a -is [string])) { throw 'Manifest launch.arguments must be strings.' } }
    }
    $environment = Get-ManifestValue $launch 'environment'
    if ($null -ne $environment -and -not ($environment -is [System.Collections.IDictionary])) {
        throw 'Manifest launch.environment must be an object.'
    }
    $readiness = Get-ManifestValue $Manifest 'readiness'
    $path = Get-ManifestValue $readiness 'path'
    if (-not ($path -is [string]) -or $path -notmatch '^/[^?#]*$') { throw 'Manifest readiness.path is missing or invalid.' }
    $expected = Get-ManifestValue $readiness 'expected'
    if (-not ($expected -is [hashtable]) -or $expected.Count -eq 0) {
        throw 'Manifest readiness.expected must be a non-empty object.'
    }
    $timeout = Get-ManifestValue $readiness 'timeoutSeconds'
    if ($null -ne $timeout -and (-not ($timeout -is [int] -or $timeout -is [long]) -or $timeout -lt 1 -or $timeout -gt 300)) {
        throw 'Manifest readiness.timeoutSeconds must be an integer from 1 to 300.'
    }
}

function Resolve-Entrypoint {
    param([Parameter(Mandatory)][string]$Entrypoint, [Parameter(Mandatory)][string]$Release)
    if ([System.IO.Path]::IsPathRooted($Entrypoint) -or $Entrypoint.Contains(':')) {
        throw "launch.entrypoint must be relative to the release: $Entrypoint"
    }
    $segments = $Entrypoint -split '[\\/]'
    if ($segments -contains '..') { throw "launch.entrypoint must not contain '..': $Entrypoint" }
    $full = [System.IO.Path]::GetFullPath((Join-Path $Release $Entrypoint))
    if (-not (Test-PathIsUnder -Child $full -Parent $Release)) { throw "launch.entrypoint escapes the release: $Entrypoint" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "launch.entrypoint does not exist in the release: $full" }
    [void](Assert-NotReparsePoint -Path $full -Name 'launch.entrypoint')
    return $full
}

function Expand-LifecycleToken {
    param([AllowEmptyString()][string]$Value, [Parameter(Mandatory)][System.Collections.IDictionary]$Tokens, [string]$Name = 'value')
    $unknown = [System.Collections.Generic.List[string]]::new()
    $result = [regex]::Replace($Value, '\{([A-Za-z]+)\}', {
            param($m)
            $k = $m.Groups[1].Value
            if ($Tokens.Contains($k)) { return [string]$Tokens[$k] }
            $unknown.Add($k)
            return $m.Value
        })
    if ($unknown.Count -gt 0) { throw "Unknown token {$($unknown[0])} in $Name." }
    return $result
}

function ConvertTo-CommandLineArgument {
    # Quotes one argument using the CommandLineToArgvW rules that node.exe and python.exe follow.
    param([AllowEmptyString()][string]$Value)
    if ($Value.IndexOfAny([char[]]@("`0", "`r", "`n")) -ge 0) { throw 'Launch arguments must not contain NUL or newline characters.' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\', $slashes * 2 + 1).Append('"') }
        else { [void]$sb.Append('\', $slashes).Append($ch) }
        $slashes = 0
    }
    [void]$sb.Append('\', $slashes * 2).Append('"')
    return $sb.ToString()
}

function Get-VenvBaseInterpreter {
    # The venv python.exe is a launcher. It starts <home>\python.exe from pyvenv.cfg as its child with the same
    # command line, and that child is the process that listens. pyvenv.cfg sits in the admin-sealed release.
    param([Parameter(Mandatory)][string]$Release)
    $cfg = Join-Path $Release '.venv\pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { throw "Python release has no .venv\pyvenv.cfg: $cfg" }
    $item = Assert-NotReparsePoint -Path $cfg -Name 'pyvenv.cfg'
    if ($item.Length -gt 64KB) { throw "pyvenv.cfg is too large: $cfg" }
    $venvHome = $null
    foreach ($line in [System.IO.File]::ReadAllLines($cfg)) {
        if ($line -match '^\s*home\s*=\s*(.+?)\s*$') { $venvHome = $Matches[1] }
    }
    if (-not $venvHome -or -not [System.IO.Path]::IsPathFullyQualified($venvHome)) { throw "pyvenv.cfg has no absolute home: $cfg" }
    $exe = [System.IO.Path]::GetFullPath((Join-Path $venvHome 'python.exe'))
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Base interpreter from pyvenv.cfg does not exist: $exe" }
    return $exe
}

function New-LifecycleContext {
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest, [Parameter(Mandatory)][string]$RuntimePath)
    Assert-LifecycleManifest -Manifest $Manifest
    $layout = Get-AppLayout -AppRoot $AppRoot
    Assert-AppLayout -Layout $layout
    $release = Resolve-ReleaseDirectory -Layout $layout -ReleasePath $ReleasePath
    $launch = $Manifest['launch']
    $kind = $Manifest['runtime']['kind']
    $runtime = Resolve-RuntimeExecutable -RuntimePath $RuntimePath -Kind $kind -Layout $layout -Release $release
    $entry = Resolve-Entrypoint -Entrypoint $launch['entrypoint'] -Release $release
    $childRuntime = $null
    if ($kind -ceq 'python') { $childRuntime = Get-VenvBaseInterpreter -Release $release }
    $tokens = @{ data = $layout.Data; secrets = $layout.Secrets; logs = $layout.Logs; backups = $layout.Backups; run = $layout.Run; release = $release }

    $stopEnv = Get-ManifestValue $launch 'stopFileEnvironment'
    if ($null -ne $stopEnv -and (-not ($stopEnv -is [string]) -or $stopEnv -notmatch $script:EnvNamePattern)) {
        throw 'Manifest launch.stopFileEnvironment is not a valid environment variable name.'
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @(Get-ManifestValue $launch 'arguments')) {
        if ($null -eq $a) { continue }
        $arguments.Add((Expand-LifecycleToken -Value $a -Tokens $tokens -Name 'launch.arguments'))
    }

    $environment = [ordered]@{}
    $envMap = Get-ManifestValue $launch 'environment'
    if ($null -ne $envMap) {
        foreach ($k in $envMap.Keys) {
            if ($k -notmatch $script:EnvNamePattern) { throw "launch.environment has an invalid name: $k" }
            if ($stopEnv -and $k -ieq $stopEnv) { throw "launch.environment must not set the stop file variable $k." }
            $v = $envMap[$k]
            if (-not ($v -is [string])) { throw "launch.environment value for $k must be a string." }
            $environment[$k] = Expand-LifecycleToken -Value $v -Tokens $tokens -Name "launch.environment.$k"
        }
    }

    $secretFile = $null
    $secretSpec = Get-ManifestValue $launch 'secretFile'
    if ($null -ne $secretSpec) {
        $expanded = Expand-LifecycleToken -Value ([string]$secretSpec) -Tokens $tokens -Name 'launch.secretFile'
        if (-not [System.IO.Path]::IsPathFullyQualified($expanded)) { $expanded = Join-Path $layout.Secrets $expanded }
        $secretFile = [System.IO.Path]::GetFullPath($expanded)
        if (-not (Test-PathIsUnder -Child $secretFile -Parent $layout.Secrets)) {
            throw "launch.secretFile must resolve under $($layout.Secrets)."
        }
    }

    $readiness = $Manifest['readiness']
    $readyTimeout = Get-ManifestValue $readiness 'timeoutSeconds'
    if ($null -eq $readyTimeout) { $readyTimeout = 30 }

    return [ordered]@{
        Id                = $Manifest['id']
        Kind              = $kind
        Layout            = $layout
        Release           = $release
        Runtime           = $runtime
        ChildRuntime      = $childRuntime
        Entrypoint        = $entry
        Port              = [int]$launch['port']
        Arguments         = $arguments.ToArray()
        Environment       = $environment
        SecretFile        = $secretFile
        StopEnvironment   = $stopEnv
        ReadinessPath     = $readiness['path']
        ReadinessExpected = $readiness['expected']
        ReadinessTimeout  = [int]$readyTimeout
        CommandLinePrefix = '"' + $runtime + '" ' + (ConvertTo-CommandLineArgument -Value $entry)
    }
}

function Read-LifecycleManifest {
    <#
    .SYNOPSIS
    Loads a manifest JSON file that must live in the release (or AppRoot\state), never in a runtime-writable path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$ReleasePath)
    $layout = Get-AppLayout -AppRoot $AppRoot
    Assert-AppLayout -Layout $layout
    $release = Resolve-ReleaseDirectory -Layout $layout -ReleasePath $ReleasePath
    $full = Get-NormalizedFullPath -Path $Path -Name 'ManifestPath'
    $full = Resolve-UnderRelease -Path $full -Layout $layout -Release $release
    if (-not ((Test-PathIsUnder -Child $full -Parent $release) -or (Test-PathIsUnder -Child $full -Parent $layout.State))) {
        throw "ManifestPath must be inside the release or AppRoot\state: $full"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "ManifestPath does not exist: $full" }
    $item = Assert-NotReparsePoint -Path $full -Name 'ManifestPath'
    if ($item.Length -gt 256KB) { throw 'Manifest file is too large.' }
    $manifest = [System.IO.File]::ReadAllText($full) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if (-not ($manifest -is [hashtable])) { throw 'Manifest must be a JSON object.' }
    Assert-LifecycleManifest -Manifest $manifest
    return $manifest
}

#endregion

#region Secrets

function Read-AppSecretFile {
    # Parses KEY=VALUE lines into memory. Values are never expanded, executed, or logged.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SecretsRoot)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-PathIsUnder -Child $full -Parent $SecretsRoot)) { throw 'Secret file is outside the secrets directory.' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Secret file does not exist: $full" }
    $item = Assert-NotReparsePoint -Path $full -Name 'Secret file'
    if ($item.Length -gt $script:MaxSecretFileBytes) { throw 'Secret file is larger than the allowed size.' }
    $values = [ordered]@{}
    $lineNumber = 0
    foreach ($raw in [System.IO.File]::ReadAllLines($full)) {
        $lineNumber++
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { throw "Secret file line $lineNumber is not KEY=VALUE." }
        $key = $line.Substring(0, $eq).Trim()
        if ($key -notmatch $script:EnvNamePattern) { throw "Secret file line $lineNumber has an invalid name." }
        $value = $line.Substring($eq + 1).Trim()
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($values.Contains($key)) { throw "Secret file line $lineNumber repeats a name." }
        $values[$key] = $value
    }
    return $values
}

#endregion

#region Run-directory records

function Write-RunFile {
    # Writes a file in shared\run without following a pre-planted link: create a new file, then rename over.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RunDirectory, [AllowEmptyString()][string]$Content)
    if (-not (Test-SamePath ([System.IO.Path]::GetDirectoryName($Path)) $RunDirectory)) { throw "Refusing to write outside shared\run: $Path" }
    Assert-Directory -Path $RunDirectory -Name 'shared\run'
    if (Test-Path -LiteralPath $Path -PathType Container) { throw "Expected a file but found a directory: $Path" }
    $temp = Join-Path $RunDirectory ('.tmp-' + [guid]::NewGuid().ToString('N'))
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
    $fs = [System.IO.FileStream]::new($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    try { [System.IO.File]::Move($temp, $Path, $true) }
    catch { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw }
}

function Remove-RunFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RunDirectory)
    if (-not (Test-SamePath ([System.IO.Path]::GetDirectoryName($Path)) $RunDirectory)) { throw "Refusing to remove outside shared\run: $Path" }
    if (Test-Path -LiteralPath $Path -PathType Container) { throw "Expected a file but found a directory: $Path" }
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Delete($Path) }
}

function Read-OwnershipRecord {
    # Returns @{ Record; Reason }. Record is $null when absent or malformed. Never trusted on its own.
    param([Parameter(Mandatory)]$Layout)
    $path = $Layout.OwnerFile
    if (-not (Test-Path -LiteralPath $path)) { return @{ Record = $null; Reason = 'no-record' } }
    try {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer) { return @{ Record = $null; Reason = 'record-not-a-file' } }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return @{ Record = $null; Reason = 'record-is-link' } }
        if ($item.Length -gt $script:MaxRecordBytes) { return @{ Record = $null; Reason = 'record-too-large' } }
        $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
    }
    catch { return @{ Record = $null; Reason = 'record-unreadable' } }
    if (-not ($data -is [System.Collections.IDictionary])) { return @{ Record = $null; Reason = 'record-malformed' } }
    $processId = $data['pid']
    if (-not ($processId -is [int] -or $processId -is [long]) -or $processId -le 4 -or $processId -gt [int]::MaxValue) {
        return @{ Record = $null; Reason = 'record-bad-pid' }
    }
    $created = [datetimeoffset]::MinValue
    if (-not ($data['creationTimeUtc'] -is [string]) -or
        -not [datetimeoffset]::TryParseExact($data['creationTimeUtc'], 'o', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$created)) {
        return @{ Record = $null; Reason = 'record-bad-creation-time' }
    }
    foreach ($k in 'appId', 'executablePath', 'releasePath', 'entrypointPath') {
        if (-not ($data[$k] -is [string])) { return @{ Record = $null; Reason = "record-missing-$k" } }
    }
    $childId = $null; $childCreated = $null
    if ($data.Contains('childPid') -and $null -ne $data['childPid']) {
        $childId = $data['childPid']
        if (-not ($childId -is [int] -or $childId -is [long]) -or $childId -le 4 -or $childId -gt [int]::MaxValue) {
            return @{ Record = $null; Reason = 'record-bad-child-pid' }
        }
        $c = [datetimeoffset]::MinValue
        if (-not ($data['childCreationTimeUtc'] -is [string]) -or
            -not [datetimeoffset]::TryParseExact($data['childCreationTimeUtc'], 'o', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$c)) {
            return @{ Record = $null; Reason = 'record-bad-child-creation-time' }
        }
        $childId = [int]$childId; $childCreated = $c.UtcDateTime
    }
    return @{
        Record = [ordered]@{
            AppId          = $data['appId']
            Pid            = [int]$processId
            CreationUtc    = $created.UtcDateTime
            ExecutablePath = $data['executablePath']
            ReleasePath    = $data['releasePath']
            EntrypointPath = $data['entrypointPath']
            ChildPid       = $childId
            ChildCreationUtc = $childCreated
        }
        Reason = 'ok'
    }
}

function Get-ProcessIdentity {
    param([Parameter(Mandatory)][int]$ProcessId)
    $p = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    $created = $null
    if ($p.CreationDate) { $created = $p.CreationDate.ToUniversalTime() }
    return [ordered]@{
        Pid            = [int]$p.ProcessId
        ParentPid      = [int]$p.ParentProcessId
        CreationUtc    = $created
        ExecutablePath = $p.ExecutablePath
        CommandLine    = $p.CommandLine
    }
}

function Test-SameCreationTime {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    return [Math]::Abs(($A - $B).TotalMilliseconds) -lt 2
}

function New-OwnershipState {
    param([string]$Status, [string]$Reason, $ProcessId, $CreationUtc, $ChildProcessId = $null, $ChildCreationUtc = $null, $Tracked = @())
    return [ordered]@{ Status = $Status; Reason = $Reason; Pid = $ProcessId; CreationUtc = $CreationUtc
        ChildPid = $ChildProcessId; ChildCreationUtc = $ChildCreationUtc; Tracked = @($Tracked) }
}

function Get-IdentityMismatch {
    # $null when the live process runs $Executable with the release entrypoint first; otherwise a reason.
    param([Parameter(Mandatory)]$Process, [Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$Prefix)
    if ([string]::IsNullOrEmpty($Process.ExecutablePath) -or [string]::IsNullOrEmpty($Process.CommandLine)) { return 'identity-unverifiable' }
    if (-not (Test-SamePath $Process.ExecutablePath $Executable)) { return 'executable-mismatch' }
    $cmd = $Process.CommandLine.Trim()
    if (-not ($cmd.Equals($Prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $cmd.StartsWith($Prefix + ' ', [System.StringComparison]::OrdinalIgnoreCase))) { return 'entrypoint-mismatch' }
    return $null
}

function Find-VenvChildProcess {
    # The base interpreter the venv launcher started: same parent PID, created after it, expected executable and entrypoint.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Launcher)
    $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$($Launcher.Pid)" -ErrorAction SilentlyContinue)
    foreach ($c in $children) {
        $id = Get-ProcessIdentity -ProcessId ([int]$c.ProcessId)
        if ($null -eq $id -or $null -eq $id.CreationUtc -or $id.ParentPid -ne $Launcher.Pid) { continue }
        if ($id.CreationUtc -lt $Launcher.CreationUtc.AddMilliseconds(-2)) { continue }
        if ($null -eq (Get-IdentityMismatch -Process $id -Executable $Context.ChildRuntime -Prefix $Context.CommandLinePrefix)) { return $id }
    }
    return $null
}

function Get-OwnedProcessState {
    # Status: Running (a verified process is alive), NotRunning (no live owned process), Foreign (a live process with a
    # recorded PID and creation time fails identity checks), Untrusted (record unreadable or describes another app/release).
    # Python records also carry the venv launcher's child, the base interpreter that actually listens. Tracked lists
    # every live verified PID + creation time, so a stop waits for all of them.
    param([Parameter(Mandatory)]$Context)
    $read = Read-OwnershipRecord -Layout $Context.Layout
    $r = $read.Record
    if ($null -eq $r) {
        $status = if ($read.Reason -eq 'no-record') { 'NotRunning' } else { 'Untrusted' }
        return New-OwnershipState $status $read.Reason $null $null
    }
    if ($r.AppId -cne $Context.Id -or -not (Test-SamePath $r.ReleasePath $Context.Release) -or
        -not (Test-SamePath $r.ExecutablePath $Context.Runtime) -or -not (Test-SamePath $r.EntrypointPath $Context.Entrypoint)) {
        return New-OwnershipState 'Untrusted' 'record-describes-another-app-or-release' $r.Pid $r.CreationUtc
    }
    if ($null -ne $r.ChildPid -and -not $Context.ChildRuntime) {
        return New-OwnershipState 'Untrusted' 'record-has-child-for-non-python-app' $r.Pid $r.CreationUtc
    }
    $tracked = [System.Collections.Generic.List[object]]::new()

    $proc = Get-ProcessIdentity -ProcessId $r.Pid
    $mainReason = 'process-exited'
    if ($null -ne $proc) {
        if (Test-SameCreationTime $proc.CreationUtc $r.CreationUtc) {
            $bad = Get-IdentityMismatch -Process $proc -Executable $Context.Runtime -Prefix $Context.CommandLinePrefix
            if ($bad) { return New-OwnershipState 'Foreign' $bad $r.Pid $r.CreationUtc $r.ChildPid $r.ChildCreationUtc }
            $tracked.Add([pscustomobject]@{ Pid = $r.Pid; CreationUtc = $r.CreationUtc })
            $mainReason = $null
        }
        else { $mainReason = 'pid-reused' }
    }

    $childAlive = $false
    if ($null -ne $r.ChildPid) {
        $child = Get-ProcessIdentity -ProcessId $r.ChildPid
        if ($null -ne $child -and (Test-SameCreationTime $child.CreationUtc $r.ChildCreationUtc)) {
            if ($child.ParentPid -ne $r.Pid -or $child.CreationUtc -lt $r.CreationUtc.AddMilliseconds(-2)) {
                return New-OwnershipState 'Foreign' 'child-parent-mismatch' $r.Pid $r.CreationUtc $r.ChildPid $r.ChildCreationUtc
            }
            $bad = Get-IdentityMismatch -Process $child -Executable $Context.ChildRuntime -Prefix $Context.CommandLinePrefix
            if ($bad) { return New-OwnershipState 'Foreign' "child-$bad" $r.Pid $r.CreationUtc $r.ChildPid $r.ChildCreationUtc }
            $tracked.Add([pscustomobject]@{ Pid = $r.ChildPid; CreationUtc = $r.ChildCreationUtc })
            $childAlive = $true
        }
    }

    if ($tracked.Count -eq 0) { return New-OwnershipState 'NotRunning' $mainReason $r.Pid $r.CreationUtc $r.ChildPid $r.ChildCreationUtc }
    $reason = 'verified'
    if ($null -ne $r.ChildPid -and -not $childAlive) { $reason = 'verified-launcher-child-exited' }
    elseif ($null -ne $r.ChildPid -and $null -ne $mainReason) { $reason = 'verified-child-launcher-exited' }
    return New-OwnershipState 'Running' $reason $r.Pid $r.CreationUtc $r.ChildPid $r.ChildCreationUtc $tracked.ToArray()
}

function Get-PortListenerProcessId {
    param([Parameter(Mandatory)][int]$Port)
    $ids = @()
    try {
        # Listener-shaped rows (no remote port) count regardless of State: jimbrownhome1 has reported real
        # listeners with an undefined State 0, which a -State Listen query silently drops.
        $ids = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction Stop |
                Where-Object { $_.RemotePort -eq 0 -and $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::1', '::', '::ffff:127.0.0.1') } |
                Select-Object -ExpandProperty OwningProcess -Unique)
    }
    catch {
        $listening = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
                Where-Object { $_.Port -eq $Port -and $_.Address.ToString() -in @('127.0.0.1', '0.0.0.0', '::1', '::', '::ffff:127.0.0.1') })
        if ($listening.Count -gt 0) { $ids = @('unknown') }
    }
    return , $ids
}

#endregion

#region Maintenance and locking

function Get-AppMaintenance {
    <#
    .SYNOPSIS
    Reports whether state\maintenance.json exists. Any file there, readable or not, means maintenance.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot)
    $layout = Get-AppLayout -AppRoot $AppRoot
    $path = $layout.MaintenanceFile
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Active = $false; Reason = $null; Path = $path } }
    $reason = 'unreadable maintenance flag'
    try {
        $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($data -is [System.Collections.IDictionary] -and $data['reason'] -is [string]) { $reason = $data['reason'] }
    }
    catch { $reason = 'unreadable maintenance flag' }
    return [pscustomobject]@{ Active = $true; Reason = $reason; Path = $path }
}

function Set-AppMaintenance {
    <#
    .SYNOPSIS
    Persists the admin-controlled maintenance flag. The watchdog and Start-ManagedApp do not launch while it exists.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Reason)
    $layout = Get-AppLayout -AppRoot $AppRoot
    Assert-Directory -Path $layout.State -Name 'AppRoot state directory'
    $body = [ordered]@{
        schemaVersion = 1
        reason        = $Reason
        setAtUtc      = [datetime]::UtcNow.ToString('o')
        setBy         = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    } | ConvertTo-Json
    if ($PSCmdlet.ShouldProcess($layout.MaintenanceFile, 'Set maintenance flag')) {
        $temp = Join-Path $layout.State ('.tmp-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($temp, $body, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temp, $layout.MaintenanceFile, $true)
    }
}

function Clear-AppMaintenance {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$AppRoot)
    $layout = Get-AppLayout -AppRoot $AppRoot
    if ((Test-Path -LiteralPath $layout.MaintenanceFile) -and $PSCmdlet.ShouldProcess($layout.MaintenanceFile, 'Clear maintenance flag')) {
        [System.IO.File]::Delete($layout.MaintenanceFile)
    }
}

function Enter-AppLock {
    # Exclusive per-app lock file in shared\run. Returns the open stream, or $null on timeout.
    param([Parameter(Mandatory)]$Layout, [ValidateRange(0, 600)][int]$TimeoutSeconds = 30)
    $path = $Layout.LockFile
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Lock path is not a plain file: $path"
        }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            return [System.IO.FileStream]::new($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return $null }
            Start-Sleep -Milliseconds 200
        }
    }
}

#endregion

#region Readiness

function Test-IsNumber {
    param($Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [System.Numerics.BigInteger])
}

function Compare-ReadinessValue {
    # Returns $null when Actual satisfies Expected, otherwise a short mismatch description (no values echoed).
    param($Expected, $Actual, [string]$Path = '$')
    if ($Expected -is [System.Collections.IDictionary]) {
        if (-not ($Actual -is [System.Collections.IDictionary])) { return "$Path is not an object" }
        foreach ($k in $Expected.Keys) {
            if (-not $Actual.Contains($k)) { return "$Path.$k is missing" }
            $r = Compare-ReadinessValue -Expected $Expected[$k] -Actual $Actual[$k] -Path "$Path.$k"
            if ($r) { return $r }
        }
        return $null
    }
    if ($null -eq $Expected) { if ($null -eq $Actual) { return $null } else { return "$Path is not null" } }
    if ($Expected -is [string]) {
        if ($Actual -is [string] -and $Actual -ceq $Expected) { return $null }
        return "$Path does not match"
    }
    if ($Expected -is [bool]) {
        if ($Actual -is [bool] -and $Actual -eq $Expected) { return $null }
        return "$Path does not match"
    }
    if (Test-IsNumber $Expected) {
        if ((Test-IsNumber $Actual) -and ([decimal]$Actual -eq [decimal]$Expected)) { return $null }
        return "$Path does not match"
    }
    if ($Expected -is [System.Collections.IList]) {
        if (-not ($Actual -is [System.Collections.IList])) { return "$Path is not an array" }
        if ($Actual.Count -ne $Expected.Count) { return "$Path has a different length" }
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            $r = Compare-ReadinessValue -Expected $Expected[$i] -Actual $Actual[$i] -Path "$Path[$i]"
            if ($r) { return $r }
        }
        return $null
    }
    return "$Path has an unsupported expected type"
}

function Invoke-ReadinessProbe {
    param([System.Net.Http.HttpClient]$Client, [string]$Uri, [hashtable]$Expected)
    $response = $null
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
        $request.Headers.Accept.ParseAdd('application/json')
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -ne 200) { return @{ Ready = $false; StatusCode = $status; Reason = "HTTP $status" } }
        $mediaType = $null
        if ($response.Content.Headers.ContentType) { $mediaType = $response.Content.Headers.ContentType.MediaType }
        if (-not $mediaType -or -not ($mediaType -ieq 'application/json' -or $mediaType -like 'application/*+json')) {
            return @{ Ready = $false; StatusCode = $status; Reason = "content type '$mediaType' is not JSON" }
        }
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $body.TrimStart().StartsWith('{')) { return @{ Ready = $false; StatusCode = $status; Reason = 'body is not a JSON object' } }
        try { $actual = $body | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop }
        catch { return @{ Ready = $false; StatusCode = $status; Reason = 'body is not valid JSON' } }
        $mismatch = Compare-ReadinessValue -Expected $Expected -Actual $actual
        if ($mismatch) { return @{ Ready = $false; StatusCode = $status; Reason = $mismatch } }
        return @{ Ready = $true; StatusCode = $status; Reason = 'ready' }
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        return @{ Ready = $false; StatusCode = $null; Reason = $inner.Message }
    }
    finally { if ($response) { $response.Dispose() } }
}

function Test-AppReadiness {
    <#
    .SYNOPSIS
    Polls http://127.0.0.1:<Port><Path> until it returns HTTP 200 JSON containing every Expected key and value.
    Redirects, non-JSON bodies (for example an HTML sign-in page), and partial matches never pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [Parameter(Mandatory)][ValidatePattern('^/[^?#]*$')][string]$Path,
        [Parameter(Mandatory)][hashtable]$Expected,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 10
    )
    if ($Expected.Count -eq 0) { throw 'Expected must contain at least one key.' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $handler.UseCookies = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.MaxResponseContentBufferSize = $script:MaxReadinessBodyBytes
    $client.Timeout = [TimeSpan]::FromSeconds([Math]::Min(5, $TimeoutSeconds))
    $uri = "http://127.0.0.1:$Port$Path"
    $last = @{ Ready = $false; StatusCode = $null; Reason = 'not attempted' }
    $attempts = 0
    try {
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $attempts++
            $last = Invoke-ReadinessProbe -Client $client -Uri $uri -Expected $Expected
            if ($last.Ready) { break }
            if ($sw.Elapsed.TotalSeconds + 0.5 -ge $TimeoutSeconds) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    finally { $client.Dispose() }
    return [pscustomobject]@{
        Ready          = [bool]$last.Ready
        StatusCode     = $last.StatusCode
        Reason         = $last.Reason
        Attempts       = $attempts
        ElapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        Uri            = $uri
    }
}

#endregion

#region Start / stop / watchdog

function Test-IsElevated {
    $principal = [System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Move-PreviousLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-Path -LiteralPath $Path -PathType Container) { throw "Log path is a directory: $Path" }
    $previous = [System.IO.Path]::ChangeExtension($Path, '.previous.log')
    if (Test-Path -LiteralPath $previous -PathType Container) { throw "Log path is a directory: $previous" }
    # A rename only changes the directory entry, so a planted link is never written through.
    [System.IO.File]::Move($Path, $previous, $true)
}

function New-LaunchEnvironment {
    # The exact variables the launcher sets for the child: expanded launch.environment, then the secret file parsed by
    # Read-AppSecretFile (a name repeated in the file, or one that collides with launch.environment or the stop
    # variable, throws), then the stop file variable. Error messages carry names and line numbers, never values.
    param([Parameter(Mandatory)]$Context)
    $layout = $Context.Layout
    $childEnv = [ordered]@{}
    foreach ($k in $Context.Environment.Keys) { $childEnv[$k] = $Context.Environment[$k] }
    if ($Context.SecretFile) {
        $secrets = Read-AppSecretFile -Path $Context.SecretFile -SecretsRoot $layout.Secrets
        try {
            foreach ($k in $secrets.Keys) {
                if ($childEnv.Contains($k)) { throw "Secret file name $k collides with launch.environment." }
                if ($Context.StopEnvironment -and $k -ieq $Context.StopEnvironment) { throw "Secret file must not set $k." }
                $childEnv[$k] = $secrets[$k]
            }
        }
        finally { $secrets.Clear() }
    }
    if ($Context.StopEnvironment) { $childEnv[$Context.StopEnvironment] = $layout.StopFile }
    return $childEnv
}

function Start-ManagedAppCore {
    # Caller holds the app lock and has checked maintenance.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][int]$TimeoutSeconds)
    $layout = $Context.Layout
    $state = Get-OwnedProcessState -Context $Context
    if ($state.Status -eq 'Running') {
        $ready = Test-AppReadiness -Port $Context.Port -Path $Context.ReadinessPath -Expected $Context.ReadinessExpected -TimeoutSeconds ([Math]::Min(5, $TimeoutSeconds))
        return [pscustomobject]@{ AppId = $Context.Id; Status = 'AlreadyRunning'; Pid = $state.Pid; Ready = $ready.Ready; Reason = $ready.Reason }
    }
    $listeners = Get-PortListenerProcessId -Port $Context.Port
    if ($listeners.Count -gt 0) {
        throw "Port $($Context.Port) is already in use (PID $($listeners -join ', ')) by a process not verified as $($Context.Id); ownership '$($state.Status)' ($($state.Reason)). Not starting."
    }

    Assert-Directory -Path $layout.Logs -Name 'shared\logs'
    $stdout = Join-Path $layout.Logs "$($Context.Id).out.log"
    $stderr = Join-Path $layout.Logs "$($Context.Id).err.log"
    Move-PreviousLog -Path $stdout
    Move-PreviousLog -Path $stderr
    Remove-RunFile -Path $layout.StopFile -RunDirectory $layout.Run

    $childEnv = New-LaunchEnvironment -Context $Context

    $argLine = (@($Context.Entrypoint) + @($Context.Arguments) | ForEach-Object { ConvertTo-CommandLineArgument -Value $_ }) -join ' '

    # The child inherits this process environment. Values exist only for the launch and are restored after.
    $saved = @{}
    foreach ($k in $childEnv.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
    $process = $null
    try {
        foreach ($k in $childEnv.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$childEnv[$k], 'Process') }
        $process = Start-Process -FilePath $Context.Runtime -ArgumentList $argLine -WorkingDirectory $Context.Release `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
        $childEnv.Clear()
    }

    $identity = Get-ProcessIdentity -ProcessId $process.Id
    if ($null -eq $identity -or $null -eq $identity.CreationUtc) {
        throw "$($Context.Id) exited immediately after launch (PID $($process.Id)). See $stderr."
    }
    $record = [ordered]@{
        schemaVersion   = 1
        appId           = $Context.Id
        pid             = $identity.Pid
        creationTimeUtc = $identity.CreationUtc.ToString('o')
        executablePath  = $Context.Runtime
        releasePath     = $Context.Release
        entrypointPath  = $Context.Entrypoint
        port            = $Context.Port
        startedAtUtc    = [datetime]::UtcNow.ToString('o')
        startedBy       = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    Write-RunFile -Path $layout.OwnerFile -RunDirectory $layout.Run -Content ($record | ConvertTo-Json)

    $child = $null
    if ($Context.ChildRuntime) {
        $find = [System.Diagnostics.Stopwatch]::StartNew()
        while ($find.Elapsed.TotalSeconds -lt 10) {
            $child = Find-VenvChildProcess -Context $Context -Launcher $identity
            if ($child) { break }
            $still = Get-ProcessIdentity -ProcessId $identity.Pid
            if ($null -eq $still -or -not (Test-SameCreationTime $still.CreationUtc $identity.CreationUtc)) { break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $child) {
            throw "$($Context.Id) venv launcher (PID $($identity.Pid)) did not start $($Context.ChildRuntime) within 10 s, or exited. Nothing was stopped. See $stderr."
        }
        $record['childPid'] = $child.Pid
        $record['childCreationTimeUtc'] = $child.CreationUtc.ToString('o')
        $record['childExecutablePath'] = $Context.ChildRuntime
        Write-RunFile -Path $layout.OwnerFile -RunDirectory $layout.Run -Content ($record | ConvertTo-Json)
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ready = $null
    while ($true) {
        $remaining = [int][Math]::Floor($TimeoutSeconds - $sw.Elapsed.TotalSeconds)
        if ($remaining -lt 1) { break }
        $ready = Test-AppReadiness -Port $Context.Port -Path $Context.ReadinessPath -Expected $Context.ReadinessExpected -TimeoutSeconds ([Math]::Min(2, $remaining))
        if ($ready.Ready) { break }
        if ((Get-OwnedProcessState -Context $Context).Status -ne 'Running') {
            throw "$($Context.Id) exited before it became ready (last check: $($ready.Reason)). See $stderr."
        }
    }
    if (-not $ready -or -not $ready.Ready) {
        $why = if ($ready) { $ready.Reason } else { 'no readiness attempt' }
        throw "$($Context.Id) (PID $($identity.Pid)) did not become ready within $TimeoutSeconds s: $why. The process was left running; use Stop-ManagedApp."
    }
    return [pscustomobject]@{ AppId = $Context.Id; Status = 'Started'; Pid = $identity.Pid; Ready = $true; Reason = $ready.Reason }
}

function Start-ManagedApp {
    <#
    .SYNOPSIS
    Launches the app hidden with redirected output, records PID + creation time in shared\run\owner.json,
    and waits for readiness. Refuses under maintenance, from an elevated token, or when the port is taken.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$RuntimePath,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )
    $context = New-LifecycleContext -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $Manifest -RuntimePath $RuntimePath
    if (Test-IsElevated) {
        throw "Refusing to launch $($context.Id) from an elevated token. The app must run as its dedicated account; start its scheduled task instead."
    }
    $maintenance = Get-AppMaintenance -AppRoot $context.Layout.Root
    if ($maintenance.Active) { throw "$($context.Id) is in maintenance ($($maintenance.Reason)); not starting." }
    $lock = Enter-AppLock -Layout $context.Layout -TimeoutSeconds 30
    if (-not $lock) { throw "Timed out waiting for the $($context.Id) lifecycle lock." }
    try {
        $maintenance = Get-AppMaintenance -AppRoot $context.Layout.Root
        if ($maintenance.Active) { throw "$($context.Id) is in maintenance ($($maintenance.Reason)); not starting." }
        return Start-ManagedAppCore -Context $context -TimeoutSeconds $TimeoutSeconds
    }
    finally { $lock.Dispose() }
}

function Stop-ManagedApp {
    <#
    .SYNOPSIS
    Sets the maintenance flag, writes the stop request file the app polls, and waits for the verified process to exit.
    Never terminates a process. On timeout or missing stop support it throws and leaves maintenance set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$RuntimePath,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )
    $context = New-LifecycleContext -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $Manifest -RuntimePath $RuntimePath
    $layout = $context.Layout
    Set-AppMaintenance -AppRoot $layout.Root -Reason "stop requested for $($context.Id)"
    $lock = Enter-AppLock -Layout $layout -TimeoutSeconds ([Math]::Min(60, $TimeoutSeconds))
    if (-not $lock) { throw "Timed out waiting for the $($context.Id) lifecycle lock. Maintenance remains set." }
    try {
        $state = Get-OwnedProcessState -Context $context
        if ($state.Status -ne 'Running') {
            $listeners = Get-PortListenerProcessId -Port $context.Port
            if ($listeners.Count -gt 0) {
                throw "Port $($context.Port) is in use by PID $($listeners -join ', '), which is not verified as $($context.Id) (ownership '$($state.Status)': $($state.Reason)). Nothing was stopped; maintenance remains set."
            }
            return [pscustomobject]@{ AppId = $context.Id; Status = 'NotRunning'; Pid = $state.Pid; Reason = $state.Reason; MaintenanceActive = $true; ElapsedSeconds = 0 }
        }
        if (-not $context.StopEnvironment) {
            throw "$($context.Id) (PID $($state.Pid)) has no launch.stopFileEnvironment, so it cannot be asked to stop. Nothing was stopped; maintenance remains set."
        }
        $request = [ordered]@{ appId = $context.Id; pid = $state.Pid; requestedAtUtc = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
        Write-RunFile -Path $layout.StopFile -RunDirectory $layout.Run -Content $request
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 250
            $alive = @($state.Tracked | Where-Object {
                    $p = Get-ProcessIdentity -ProcessId $_.Pid
                    $null -ne $p -and (Test-SameCreationTime $p.CreationUtc $_.CreationUtc) })
            if ($alive.Count -eq 0) {
                Remove-RunFile -Path $layout.StopFile -RunDirectory $layout.Run
                Remove-RunFile -Path $layout.OwnerFile -RunDirectory $layout.Run
                return [pscustomobject]@{ AppId = $context.Id; Status = 'Stopped'; Pid = $state.Pid; Reason = 'exited after stop request'; MaintenanceActive = $true; ElapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 2) }
            }
        }
        throw "$($context.Id) (PID $(@($state.Tracked.Pid) -join ', ')) did not exit within $TimeoutSeconds s of the stop request. It was left running, the request file remains, and maintenance remains set."
    }
    finally { $lock.Dispose() }
}

function Get-ManagedAppEnvironment {
    <#
    .SYNOPSIS
    Returns the environment the launcher would give the app, built by the same code path Start-ManagedApp uses
    (New-LifecycleContext, then New-LaunchEnvironment) without starting a process or touching this process's
    environment. The result is an ordered dictionary of secret values: keep it in memory, never log or persist it,
    and call .Clear() when done.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$RuntimePath
    )
    $context = New-LifecycleContext -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $Manifest -RuntimePath $RuntimePath
    return , (New-LaunchEnvironment -Context $context)
}

function Get-ManagedAppStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$RuntimePath
    )
    $context = New-LifecycleContext -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $Manifest -RuntimePath $RuntimePath
    $state = Get-OwnedProcessState -Context $context
    $maintenance = Get-AppMaintenance -AppRoot $context.Layout.Root
    return [pscustomobject]@{ AppId = $context.Id; Status = $state.Status; Reason = $state.Reason; Pid = $state.Pid; MaintenanceActive = $maintenance.Active }
}

function Test-ManagedAppIdentity {
    <#
    .SYNOPSIS
    Reads shared\run\process.json and verifies it against the live process (PID + creation time + executable +
    release entrypoint). Returns Verified=$true only for Status Running. Never trusts the record by itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$RuntimePath
    )
    $context = New-LifecycleContext -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $Manifest -RuntimePath $RuntimePath
    $state = Get-OwnedProcessState -Context $context
    $listeners = Get-PortListenerProcessId -Port $context.Port
    $owned = @($state.Tracked | ForEach-Object { $_.Pid })
    $listenerOwned = $state.Status -eq 'Running' -and $listeners.Count -gt 0 -and
        @($listeners | Where-Object { $owned -notcontains $_ }).Count -eq 0
    return [pscustomobject]@{
        AppId = $context.Id; Verified = ($state.Status -eq 'Running'); Status = $state.Status; Reason = $state.Reason
        Pid = $state.Pid; CreationUtc = $state.CreationUtc; ChildPid = $state.ChildPid; ChildCreationUtc = $state.ChildCreationUtc
        ListenerPids = $listeners; ListenerOwned = $listenerOwned
        ReleasePath = $context.Release; RuntimePath = $context.Runtime; ChildRuntimePath = $context.ChildRuntime; EntrypointPath = $context.Entrypoint
    }
}

function New-WatchdogResult {
    param($AppId, $Status, $Reason, $ProcessId, $Ready)
    return [pscustomobject]@{ AppId = $AppId; Status = $Status; Reason = $Reason; Pid = $ProcessId; Ready = $Ready; AtUtc = [datetime]::UtcNow.ToString('o') }
}

function Invoke-AppWatchdog {
    <#
    .SYNOPSIS
    One watchdog pass. Skips under maintenance or while another lifecycle action holds the lock; checks a verified
    process for readiness; starts the app only when no verified process exists and the port is free. Never stops anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$RuntimePath,
        [ValidateRange(1, 60)][int]$HealthTimeoutSeconds = 5
    )
    $context = New-LifecycleContext -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $Manifest -RuntimePath $RuntimePath
    $id = $context.Id
    $maintenance = Get-AppMaintenance -AppRoot $context.Layout.Root
    if ($maintenance.Active) { return New-WatchdogResult $id 'Skipped' "maintenance: $($maintenance.Reason)" $null $null }
    $lock = Enter-AppLock -Layout $context.Layout -TimeoutSeconds 2
    if (-not $lock) { return New-WatchdogResult $id 'Skipped' 'another lifecycle action holds the lock' $null $null }
    try {
        $maintenance = Get-AppMaintenance -AppRoot $context.Layout.Root
        if ($maintenance.Active) { return New-WatchdogResult $id 'Skipped' "maintenance: $($maintenance.Reason)" $null $null }
        $state = Get-OwnedProcessState -Context $context
        if ($state.Status -eq 'Running') {
            $ready = Test-AppReadiness -Port $context.Port -Path $context.ReadinessPath -Expected $context.ReadinessExpected -TimeoutSeconds $HealthTimeoutSeconds
            $status = if ($ready.Ready) { 'Healthy' } else { 'Unhealthy' }
            return New-WatchdogResult $id $status $ready.Reason $state.Pid $ready.Ready
        }
        if (Test-IsElevated) { return New-WatchdogResult $id 'Failed' 'the watchdog must run as the dedicated account, not elevated' $null $false }
        try {
            $started = Start-ManagedAppCore -Context $context -TimeoutSeconds $context.ReadinessTimeout
            return New-WatchdogResult $id $started.Status "previous ownership: $($state.Status) ($($state.Reason)); $($started.Reason)" $started.Pid $started.Ready
        }
        catch { return New-WatchdogResult $id 'Failed' $_.Exception.Message $null $false }
    }
    finally { $lock.Dispose() }
}

#endregion

#region Headless launch evidence

$script:WindowProbeSource = @'
using System;
using System.Runtime.InteropServices;
namespace SolutionDeploy {
    public static class WindowProbe {
        private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
        // Visible top-level windows on the caller's desktop owned by the given process.
        public static int VisibleTopLevelWindows(int processId) {
            int count = 0;
            EnumWindows((h, l) => {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if (owner == (uint)processId && IsWindowVisible(h)) { count++; }
                return true;
            }, IntPtr.Zero);
            return count;
        }
    }
}
'@

function Get-VisibleWindowCount {
    param([Parameter(Mandatory)][int]$ProcessId)
    if (-not ('SolutionDeploy.WindowProbe' -as [type])) { Add-Type -TypeDefinition $script:WindowProbeSource }
    return [SolutionDeploy.WindowProbe]::VisibleTopLevelWindows($ProcessId)
}

function Get-ProcessWindowEvidence {
    # Read-only facts for one app process and the console hosts it owns. Never attaches to or changes a console.
    param([Parameter(Mandatory)][int]$ProcessId, [Parameter(Mandatory)][string]$Role)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return [pscustomobject]@{ Role = $Role; Pid = $ProcessId; Alive = $false } }
    $hosts = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ProcessId AND Name='conhost.exe'" -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{
                    Pid = [int]$_.ProcessId; CommandLine = $_.CommandLine
                    Headless = ($null -ne $_.CommandLine -and $_.CommandLine -match '(^|\s)0x4(\s|$)')
                    VisibleWindows = Get-VisibleWindowCount -ProcessId ([int]$_.ProcessId)
                }
            })
    return [pscustomobject]@{
        Role = $Role; Pid = $ProcessId; Alive = $true; SessionId = [int]$proc.SessionId
        MainWindowHandle = [long]$proc.MainWindowHandle; VisibleWindows = Get-VisibleWindowCount -ProcessId $ProcessId
        ConsoleHosts = $hosts
    }
}

function Get-HeadlessDecision {
    # Pure decision over evidence. NotHeadless: a drawn window, a console host not in headless mode, a missing log, or
    # an unverified identity. Unverifiable: the process runs in another session (its windows cannot be enumerated
    # from here), a console host command line cannot be read, or the main process has no console host to inspect.
    param([object[]]$Processes, [int]$CurrentSessionId, [bool]$StdoutLog, [bool]$StderrLog, [string]$IdentityProblem)
    $bad = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    if ($IdentityProblem) { $bad.Add($IdentityProblem) }
    if (-not $StdoutLog) { $bad.Add('stdout log missing') }
    if (-not $StderrLog) { $bad.Add('stderr log missing') }
    foreach ($p in @($Processes)) {
        $tag = "$($p.Role) PID $($p.Pid)"
        if (-not $p.Alive) { $bad.Add("$tag is not running"); continue }
        if ($p.MainWindowHandle -ne 0) { $bad.Add("$tag has main window $($p.MainWindowHandle)") }
        $sameSession = $p.SessionId -eq $CurrentSessionId
        if (-not $sameSession) { $unknown.Add("$tag runs in session $($p.SessionId); its windows are not enumerable from session $CurrentSessionId") }
        elseif ($p.VisibleWindows -gt 0) { $bad.Add("$tag owns $($p.VisibleWindows) visible window(s)") }
        foreach ($h in @($p.ConsoleHosts)) {
            if ([string]::IsNullOrWhiteSpace([string]$h.CommandLine)) { $unknown.Add("$tag console host $($h.Pid) command line unreadable"); continue }
            if (-not $h.Headless) { $bad.Add("$tag console host $($h.Pid) is not headless: $($h.CommandLine)") }
            if ($sameSession -and $h.VisibleWindows -gt 0) { $bad.Add("$tag console host $($h.Pid) has a visible window") }
        }
        if ($p.Role -eq 'main' -and @($p.ConsoleHosts).Count -eq 0) { $unknown.Add("$tag has no console host to inspect") }
    }
    $result = if ($bad.Count -gt 0) { 'NotHeadless' } elseif ($unknown.Count -gt 0) { 'Unverifiable' } else { 'Headless' }
    return [pscustomobject]@{ Result = $result; Problems = [string[]]@(@($bad) + @($unknown)) }
}

function Test-ManagedAppHeadless {
    <#
    .SYNOPSIS
    Read-only check that the verified app process chain (main PID and, for python, the venv child) runs without a
    window: MainWindowHandle 0, no visible top-level window, every console host started headless (conhost 0x4), and
    both redirected logs present. Result is Headless, NotHeadless, or Unverifiable (process in another session, or a
    console host command line this caller cannot read). Headless is $true only for Result Headless. Starts, stops,
    and attaches to nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$RuntimePath
    )
    $id = Test-ManagedAppIdentity -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $Manifest -RuntimePath $RuntimePath
    $layout = Get-AppLayout -AppRoot $AppRoot
    $processes = @()
    $identityProblem = $null
    if (-not $id.Verified) { $identityProblem = "identity not verified ($($id.Status): $($id.Reason))" }
    else {
        $processes += Get-ProcessWindowEvidence -ProcessId $id.Pid -Role 'main'
        if ($null -ne $id.ChildPid) { $processes += Get-ProcessWindowEvidence -ProcessId $id.ChildPid -Role 'child' }
    }
    $stdout = Join-Path $layout.Logs "$($id.AppId).out.log"
    $stderr = Join-Path $layout.Logs "$($id.AppId).err.log"
    $decision = Get-HeadlessDecision -Processes $processes -CurrentSessionId ([System.Diagnostics.Process]::GetCurrentProcess().SessionId) `
        -StdoutLog (Test-Path -LiteralPath $stdout -PathType Leaf) -StderrLog (Test-Path -LiteralPath $stderr -PathType Leaf) -IdentityProblem $identityProblem
    return [pscustomobject]@{
        AppId = $id.AppId; Headless = ($decision.Result -eq 'Headless'); Result = $decision.Result; Problems = $decision.Problems
        Pid = $id.Pid; ChildPid = $id.ChildPid; Processes = $processes; StdoutLog = $stdout; StderrLog = $stderr
    }
}

#endregion

#region Provisioning

function New-AppAclPlan {
    # Pure description of the per-account ACL. AppRoot is protected (no inherited ProgramData entries):
    # SYSTEM and Administrators get full control, the app account gets only what the runtime needs.
    # Data, logs, backups, and run allow create in the directory and modify on children, so the
    # account cannot delete or replace the directory itself with a junction.
    param([Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$Account)
    $rx = 'ReadAndExecute, Synchronize'
    $createInDir = 'ReadAndExecute, CreateFiles, CreateDirectories, Synchronize'
    $tree = 'ContainerInherit, ObjectInherit'
    $plan = [System.Collections.Generic.List[object]]::new()
    $plan.Add([pscustomobject]@{ Path = $Layout.Root; Protect = $true; Account = $Account; Rights = $rx; Inheritance = 'None'; Propagation = 'None' })
    $plan.Add([pscustomobject]@{ Path = $Layout.Releases; Protect = $false; Account = $Account; Rights = $rx; Inheritance = $tree; Propagation = 'None' })
    $plan.Add([pscustomobject]@{ Path = $Layout.Shared; Protect = $false; Account = $Account; Rights = $rx; Inheritance = 'None'; Propagation = 'None' })
    $plan.Add([pscustomobject]@{ Path = $Layout.Secrets; Protect = $false; Account = $Account; Rights = $rx; Inheritance = $tree; Propagation = 'None' })
    $plan.Add([pscustomobject]@{ Path = $Layout.State; Protect = $false; Account = $Account; Rights = $rx; Inheritance = $tree; Propagation = 'None' })
    foreach ($dir in $Layout.Data, $Layout.Logs, $Layout.Backups, $Layout.Run) {
        $plan.Add([pscustomobject]@{ Path = $dir; Protect = $false; Account = $Account; Rights = $createInDir; Inheritance = 'None'; Propagation = 'None' })
        $plan.Add([pscustomobject]@{ Path = $dir; Protect = $false; Account = $Account; Rights = 'Modify, Synchronize'; Inheritance = $tree; Propagation = 'InheritOnly' })
    }
    return $plan.ToArray()
}

function Set-AppAcl {
    param([Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$Account)
    $sid = ([System.Security.Principal.NTAccount]$Account).Translate([System.Security.Principal.SecurityIdentifier])
    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $admins = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $tree = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($step in (New-AppAclPlan -Layout $Layout -Account $Account)) {
        [void](Assert-NotReparsePoint -Path $step.Path -Name 'ACL target')
        $dir = [System.IO.DirectoryInfo]::new($step.Path)
        if ($step.Protect) {
            $acl = [System.Security.AccessControl.DirectorySecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($system, $full, $tree, $none, $allow))
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($admins, $full, $tree, $none, $allow))
        }
        else {
            $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl($dir, [System.Security.AccessControl.AccessControlSections]::Access)
        }
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid,
                [System.Security.AccessControl.FileSystemRights]$step.Rights,
                [System.Security.AccessControl.InheritanceFlags]$step.Inheritance,
                [System.Security.AccessControl.PropagationFlags]$step.Propagation, $allow))
        [System.IO.FileSystemAclExtensions]::SetAccessControl($dir, $acl)
    }
}

function New-AppTaskArgument {
    param([string]$ScriptPath, [string]$AppRoot, [string]$ReleasePath, [string]$ManifestPath, [string]$RuntimePath)
    $parts = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath, '-AppRoot', $AppRoot, '-ReleasePath', $ReleasePath, '-ManifestPath', $ManifestPath)
    if ($RuntimePath) { $parts += @('-RuntimePath', $RuntimePath) }
    return ($parts | ForEach-Object { ConvertTo-CommandLineArgument -Value $_ }) -join ' '
}

function New-AppTaskDefinition {
    # ExecutionTimeLimit is zero (PT0S, no limit): the app is a child of the watchdog run that started it, and a
    # limit would let Task Scheduler end that run. The watchdog itself is bounded by its own lock and readiness timeouts.
    param([Parameter(Mandatory)][string]$PowerShellPath, [Parameter(Mandatory)][string]$Argument,
        [Parameter(Mandatory)][string]$WorkingDirectory, [Parameter(Mandatory)][int]$IntervalMinutes)
    $action = New-ScheduledTaskAction -Execute $PowerShellPath -Argument $Argument -WorkingDirectory $WorkingDirectory
    $repeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Repetition = $repeat.Repetition
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    return [pscustomobject]@{ Action = $action; BootTrigger = $boot; RepeatTrigger = $repeat; Settings = $settings }
}

$script:LsaSource = @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace SolutionDeploy {
public static class LsaRights {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES attributes, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaEnumerateAccountsWithUserRight(IntPtr handle, ref LSA_UNICODE_STRING right, out IntPtr buffer, out uint count);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr buffer);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    public static string[] AccountsWithRight(string right) {
        var attributes = new LSA_OBJECT_ATTRIBUTES();
        attributes.Length = Marshal.SizeOf(attributes);
        IntPtr handle;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, 0x801, out handle);
        if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
        var name = new LSA_UNICODE_STRING();
        name.Buffer = Marshal.StringToHGlobalUni(right);
        name.Length = (ushort)(right.Length * 2);
        name.MaximumLength = (ushort)(name.Length + 2);
        try {
            IntPtr buffer; uint count;
            status = LsaEnumerateAccountsWithUserRight(handle, ref name, out buffer, out count);
            if (status == 0x8000001A) return new string[0];
            if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
            try {
                var sids = new List<string>();
                for (int i = 0; i < count; i++) { sids.Add(new SecurityIdentifier(Marshal.ReadIntPtr(buffer, i * IntPtr.Size)).Value); }
                return sids.ToArray();
            }
            finally { LsaFreeMemory(buffer); }
        }
        finally { Marshal.FreeHGlobal(name.Buffer); LsaClose(handle); }
    }
}
}
"@

function Get-UserRightHolder {
    # SIDs holding a user right in local policy (effective after Group Policy refresh). Needs an elevated session.
    param([Parameter(Mandatory)][string]$Right)
    if (-not ('SolutionDeploy.LsaRights' -as [type])) { Add-Type -TypeDefinition $script:LsaSource }
    return @([SolutionDeploy.LsaRights]::AccountsWithRight($Right))
}

function Get-AccountTokenSid {
    # SIDs a password (batch) logon token for a local account carries: the account, its local groups, and well-known
    # groups. Domain group memberships are not expanded, so a right granted only through a domain group is not seen.
    param([Parameter(Mandatory)][string]$Sid)
    $sids = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Sid, 'S-1-1-0', 'S-1-2-0', 'S-1-5-3', 'S-1-5-11', 'S-1-5-15', 'S-1-5-113') { $sids.Add($s) }
    foreach ($group in @(Get-LocalGroup -ErrorAction SilentlyContinue)) {
        try {
            $members = @(Get-LocalGroupMember -SID $group.SID -ErrorAction Stop | ForEach-Object { $_.SID.Value })
            if ($members -contains $Sid) { $sids.Add($group.SID.Value) }
        }
        catch { Write-Verbose "Could not list members of $($group.Name): $($_.Exception.Message)" }
    }
    return $sids.ToArray()
}

function Test-UserRightDecision {
    param([string[]]$TokenSids, [string[]]$Granted, [string[]]$Denied)
    $deniedBy = @($TokenSids | Where-Object { $Denied -contains $_ })
    if ($deniedBy.Count -gt 0) { return [pscustomobject]@{ Allowed = $false; Reason = 'denied'; Sids = $deniedBy } }
    $grantedBy = @($TokenSids | Where-Object { $Granted -contains $_ })
    if ($grantedBy.Count -eq 0) { return [pscustomobject]@{ Allowed = $false; Reason = 'not-granted'; Sids = @() } }
    return [pscustomobject]@{ Allowed = $true; Reason = 'granted'; Sids = $grantedBy }
}

function Assert-BatchLogonRight {
    param([Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string[]]$TokenSids)
    $decision = Test-UserRightDecision -TokenSids $TokenSids -Granted (Get-UserRightHolder -Right 'SeBatchLogonRight') `
        -Denied (Get-UserRightHolder -Right 'SeDenyBatchLogonRight')
    if ($decision.Reason -eq 'denied') {
        throw "$Account is covered by 'Deny log on as a batch job' (SeDenyBatchLogonRight) through $($decision.Sids -join ', '). Remove it in secpol.msc > Local Policies > User Rights Assignment (or the Group Policy that sets it), run gpupdate /force, then re-run. Nothing was changed."
    }
    if (-not $decision.Allowed) {
        throw "$Account does not hold 'Log on as a batch job' (SeBatchLogonRight), so the boot task could not log on. Grant it to $Account in secpol.msc > Local Policies > User Rights Assignment > Log on as a batch job (or through Group Policy if the host is domain-managed), then re-run. Nothing was changed."
    }
}

function Get-MissingReadRight {
    # Rights from ReadAndExecute that the ACL on $Path does not grant to any of $TokenSids (deny entries win).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$TokenSids)
    $need = [int][System.Security.AccessControl.FileSystemRights]'ReadAndExecute, Synchronize'
    $item = Get-Item -LiteralPath $Path -Force
    $acl = if ($item.PSIsContainer) { [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.DirectoryInfo]$item, 'Access') }
    else { [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.FileInfo]$item, 'Access') }
    $allowed = 0; $denied = 0
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($TokenSids -notcontains $rule.IdentityReference.Value) { continue }
        if ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($rule.AccessControlType -eq 'Deny') { $denied = $denied -bor [int]$rule.FileSystemRights }
        else { $allowed = $allowed -bor [int]$rule.FileSystemRights }
    }
    $missing = $need -band -bnot ($allowed -band -bnot $denied)
    if ($missing -eq 0) { return $null }
    return [System.Security.AccessControl.FileSystemRights]$missing
}

function Assert-AccountCanRead {
    param([Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string[]]$TokenSids, [Parameter(Mandatory)][string[]]$Path)
    $problems = foreach ($p in $Path) {
        $missing = Get-MissingReadRight -Path $p -TokenSids $TokenSids
        if ($missing) { "$p (missing $missing)" }
    }
    if (@($problems).Count -gt 0) {
        throw "$Account cannot read files the boot task needs: $(@($problems) -join '; '). Grant read and execute on the containing folder, for example icacls `"<folder>`" /grant `"$($Account):(OI)(CI)RX`", then re-run. Nothing was changed."
    }
}

function Get-AppBootTaskSpec {
    # The one task shape the installer writes and Assert-AppBootTask accepts. The task always targets AppRoot\current
    # and current\deploy\application.json and never passes -RuntimePath, so each run follows the active release.
    param([Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)]$Layout, [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$WatchdogScriptPath)
    $script = Get-NormalizedFullPath -Path $WatchdogScriptPath -Name 'WatchdogScriptPath'
    $toolkit = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($script))
    $release = $Layout.Current
    $manifest = Join-Path $Layout.Current 'deploy\application.json'
    return [pscustomobject]@{
        TaskPath         = $script:TaskPath
        TaskName         = "SolutionDeploy-$AppId"
        Execute          = Get-NormalizedFullPath -Path $PowerShellPath -Name 'PowerShellPath'
        Arguments        = New-AppTaskArgument -ScriptPath $script -AppRoot $Layout.Root -ReleasePath $release -ManifestPath $manifest
        WorkingDirectory = $toolkit
        ScriptPath       = $script
        ReleasePath      = $release
        ManifestPath     = $manifest
    }
}

function Initialize-AppTaskFolder {
    # Ensures the single-level Task Scheduler folder exists through the Schedule.Service COM API. Only "not found"
    # (0x80070002) leads to creation; every other COM error throws with its HRESULT. Creation is verified by reading
    # the folder back. -Service exists so tests can pass a fake; production callers omit it.
    param([string]$TaskPath = $script:TaskPath, $Service)
    if ($TaskPath -notmatch '^\\[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}\\$') { throw "Task folder '$TaskPath' must be a single folder like \JimlerTech\." }
    $name = $TaskPath.Trim('\')
    if (-not $Service) {
        try { $Service = New-Object -ComObject 'Schedule.Service'; $Service.Connect() }
        catch { throw "Cannot connect to the Task Scheduler service to prepare $TaskPath ($(Get-ComErrorText $_.Exception)). Nothing was registered." }
    }
    try { [void]$Service.GetFolder("\$name"); return [pscustomobject]@{ TaskPath = $TaskPath; Created = $false } }
    catch {
        if (-not (Test-ComHResult -Exception $_.Exception -HResult -2147024894)) {
            throw "Cannot read Task Scheduler folder $TaskPath ($(Get-ComErrorText $_.Exception)). Nothing was registered."
        }
    }
    try { [void]$Service.GetFolder('\').CreateFolder($name) }
    catch { throw "Cannot create Task Scheduler folder $TaskPath ($(Get-ComErrorText $_.Exception)). Nothing was registered." }
    try { [void]$Service.GetFolder("\$name") }
    catch { throw "Task Scheduler folder $TaskPath is still not readable after creation ($(Get-ComErrorText $_.Exception)). Nothing was registered." }
    return [pscustomobject]@{ TaskPath = $TaskPath; Created = $true }
}

function Test-ComHResult {
    param([System.Exception]$Exception, [int]$HResult)
    for ($e = $Exception; $e; $e = $e.InnerException) { if ($e.HResult -eq $HResult) { return $true } }
    return $false
}

function Get-ComErrorText {
    param([System.Exception]$Exception)
    $e = $Exception; while ($e.InnerException) { $e = $e.InnerException }
    return ('0x{0:X8}: {1}' -f $e.HResult, $e.Message.Trim())
}

function Get-AppBootTaskObject {
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    return Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Assert-AppBootTask {
    <#
    .SYNOPSIS
    Read-only check that \JimlerTech\SolutionDeploy-<AppId> is exactly the task the installer writes: the expected
    account (compared by SID), stored-password logon, RunLevel Limited, enabled, no execution time limit, IgnoreNew,
    a boot trigger, and one action running the reviewed pwsh.exe with the toolkit watchdog script and the fixed
    AppRoot\current arguments. Throws on any difference. Changes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{1,39}$')][string]$AppId,
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$ExpectedAccount,
        [string]$WatchdogScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\Invoke-AppWatchdog.ps1'))
    )
    $layout = Get-AppLayout -AppRoot $AppRoot
    $spec = Get-AppBootTaskSpec -AppId $AppId -Layout $layout -PowerShellPath $PowerShellPath -WatchdogScriptPath $WatchdogScriptPath
    if ([System.IO.Path]::GetFileName($spec.Execute) -ne 'pwsh.exe' -or -not (Test-Path -LiteralPath $spec.Execute -PathType Leaf)) {
        throw "PowerShellPath must be an existing pwsh.exe: $($spec.Execute)"
    }
    if (-not (Test-Path -LiteralPath $spec.ScriptPath -PathType Leaf)) { throw "Watchdog script not found: $($spec.ScriptPath)" }
    $expectedSid = ([System.Security.Principal.NTAccount]$ExpectedAccount).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $where = "$($spec.TaskPath)$($spec.TaskName)"
    $task = Get-AppBootTaskObject -TaskPath $spec.TaskPath -TaskName $spec.TaskName
    if ($null -eq $task) { throw "Boot task $where is not registered." }

    $problems = [System.Collections.Generic.List[string]]::new()
    $principal = $task.Principal
    $actualSid = $null
    try { $actualSid = ([System.Security.Principal.NTAccount][string]$principal.UserId).Translate([System.Security.Principal.SecurityIdentifier]).Value }
    catch { $problems.Add("principal '$($principal.UserId)' does not resolve to a SID") }
    if ($actualSid -and $actualSid -ne $expectedSid) { $problems.Add("principal '$($principal.UserId)' ($actualSid) is not $ExpectedAccount ($expectedSid)") }
    if ([string]$principal.LogonType -ne 'Password') { $problems.Add("logon type is $($principal.LogonType), expected Password") }
    if ([string]$principal.RunLevel -ne 'Limited') { $problems.Add("run level is $($principal.RunLevel), expected Limited") }
    if ([string]$task.State -eq 'Disabled' -or -not $task.Settings.Enabled) { $problems.Add('task is disabled') }
    if ([string]$task.Settings.ExecutionTimeLimit -ne 'PT0S') { $problems.Add("execution time limit is '$($task.Settings.ExecutionTimeLimit)', expected PT0S (none)") }
    if ([string]$task.Settings.MultipleInstances -ne 'IgnoreNew') { $problems.Add("multiple instances is $($task.Settings.MultipleInstances), expected IgnoreNew") }
    $boot = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' -and $_.Enabled -ne $false })
    if ($boot.Count -eq 0) { $problems.Add('no enabled at-startup trigger') }
    $actions = @($task.Actions)
    if ($actions.Count -ne 1) { $problems.Add("task has $($actions.Count) actions, expected 1") }
    else {
        $a = $actions[0]
        if (-not [string]::Equals([string]$a.Execute, $spec.Execute, [System.StringComparison]::OrdinalIgnoreCase)) { $problems.Add("action runs '$($a.Execute)', expected '$($spec.Execute)'") }
        if ([string]$a.Arguments -cne $spec.Arguments) { $problems.Add("action arguments differ from the installer form: '$($a.Arguments)'") }
        if (-not [string]::Equals([string]$a.WorkingDirectory, $spec.WorkingDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
            $problems.Add("working directory is '$($a.WorkingDirectory)', expected '$($spec.WorkingDirectory)'")
        }
    }
    if ($problems.Count -gt 0) { throw "Boot task $where failed validation: $($problems -join '; ')." }
    return [pscustomobject]@{
        Validated = $true; AppId = $AppId; TaskPath = $spec.TaskPath; TaskName = $spec.TaskName; AccountSid = $expectedSid
        Execute = $spec.Execute; Arguments = $spec.Arguments; WorkingDirectory = $spec.WorkingDirectory
    }
}

function Get-ReleaseRuntimePath {
    <#
    .SYNOPSIS
    Resolves the launch runtime for the release that ReleasePath (releases\<id> or AppRoot\current) points at.
    node: runtimePath from the admin-sealed <release>\release.json, which must exist and match runtimeSHA256.
    python: <release>\.venv\Scripts\python.exe (release.json runtimePath is the build interpreter).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][hashtable]$Manifest
    )
    $layout = Get-AppLayout -AppRoot $AppRoot
    $release = Resolve-ReleaseDirectory -Layout $layout -ReleasePath $ReleasePath
    $kind = Get-ManifestValue (Get-ManifestValue $Manifest 'runtime') 'kind'
    if ($kind -ceq 'python') { return (Join-Path $release '.venv\Scripts\python.exe') }
    $recordPath = Join-Path $release 'release.json'
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw "release.json not found in $release" }
    $item = Assert-NotReparsePoint -Path $recordPath -Name 'release.json'
    if ($item.Length -gt 16MB) { throw 'release.json is too large.' }
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $runtime = $record['runtimePath']; $hash = $record['runtimeSHA256']
    if (-not ($runtime -is [string]) -or -not [System.IO.Path]::IsPathFullyQualified($runtime)) { throw 'release.json runtimePath is missing or not absolute.' }
    if (-not ($hash -is [string]) -or $hash -notmatch '^[0-9a-fA-F]{64}$') { throw 'release.json runtimeSHA256 is missing or invalid.' }
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) { throw "Release runtime does not exist: $runtime" }
    if ((Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash -ne $hash.ToUpperInvariant()) { throw "Release runtime hash does not match release.json: $runtime" }
    return [System.IO.Path]::GetFullPath($runtime)
}

function Install-AppBootTask {
    <#
    .SYNOPSIS
    Applies per-account ACLs under AppRoot and registers \JimlerTech\SolutionDeploy-<AppId>. The task runs the
    watchdog at startup and every few minutes as the dedicated account with a stored password: no sign-in, no S4U,
    RunLevel Limited. Requires an elevated session and -ApproveProvisioning. Does not start the task.
    ReleasePath must be AppRoot\current and ManifestPath current\deploy\application.json; the runtime is read from the
    active release's release.json on every run. Preflight (logon right, read access) runs before any change.
    For a first install, where activation has not yet created AppRoot\current, pass -StagedReleasePath releases\<id>
    so preflight reads the staged release while maintenance is persisted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{1,39}$')][string]$AppId,
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ReleasePath,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$RuntimePath,
        [string]$StagedReleasePath,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$ApproveProvisioning,
        [ValidateRange(1, 60)][int]$WatchdogIntervalMinutes = 5,
        [string]$WatchdogScriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\Invoke-AppWatchdog.ps1'))
    )
    if (-not $ApproveProvisioning) {
        throw 'Install-AppBootTask changes ACLs and registers a scheduled task. Re-run with -ApproveProvisioning to approve.'
    }
    $layout = Get-AppLayout -AppRoot $AppRoot
    $fixedManifest = Join-Path $layout.Current 'deploy\application.json'
    if (-not (Test-SamePath (Get-NormalizedFullPath -Path $ReleasePath -Name 'ReleasePath') $layout.Current) -or
        -not (Test-SamePath (Get-NormalizedFullPath -Path $ManifestPath -Name 'ManifestPath') $fixedManifest)) {
        throw "The boot task follows the active release: use -ReleasePath $($layout.Current) and -ManifestPath $fixedManifest."
    }
    if ($RuntimePath) { throw 'Do not pass -RuntimePath: the boot task resolves the runtime from the active release on every run.' }
    # A first install registers the task before activation creates AppRoot\current, so preflight reads the staged release.
    $checkRelease = $ReleasePath
    if ($StagedReleasePath) {
        if (Test-Path -LiteralPath $layout.Current) { throw 'Omit -StagedReleasePath: AppRoot\current exists, so preflight uses the active release.' }
        $checkRelease = Resolve-ReleaseDirectory -Layout $layout -ReleasePath $StagedReleasePath
        if (-not (Test-Path -LiteralPath (Join-Path $layout.State $script:MaintenanceFileName) -PathType Leaf)) {
            throw 'A first-install task can only be registered while maintenance is persisted.'
        }
    }
    $checkManifestPath = Join-Path $checkRelease 'deploy\application.json'
    $manifest = Read-LifecycleManifest -Path $checkManifestPath -AppRoot $layout.Root -ReleasePath $checkRelease
    if ($manifest['id'] -cne $AppId) { throw "Manifest id '$($manifest['id'])' does not match AppId '$AppId'." }
    $checkRuntime = Get-ReleaseRuntimePath -AppRoot $layout.Root -ReleasePath $checkRelease -Manifest $manifest
    $pwsh = Get-NormalizedFullPath -Path $PowerShellPath -Name 'PowerShellPath'
    if ([System.IO.Path]::GetFileName($pwsh) -ne 'pwsh.exe') { throw "PowerShellPath must be pwsh.exe (PowerShell 7.5+): $pwsh" }
    if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { throw "PowerShellPath does not exist: $pwsh" }
    $script = Get-NormalizedFullPath -Path $WatchdogScriptPath -Name 'WatchdogScriptPath'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Watchdog script not found: $script" }

    $user = $Credential.UserName
    if ([string]::IsNullOrWhiteSpace($user)) { throw 'Credential has no user name.' }
    $sid = ([System.Security.Principal.NTAccount]$user).Translate([System.Security.Principal.SecurityIdentifier])
    if ($sid.Value -in @('S-1-5-18', 'S-1-5-19', 'S-1-5-20') -or $sid.Value -like 'S-1-5-21-*-500') {
        throw "The task account must be a dedicated non-privileged account, not $user."
    }
    if (-not (Test-IsElevated)) { throw 'Install-AppBootTask must run from an elevated session.' }
    $adminMembers = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { $_.SID.Value })
    if ($adminMembers -contains $sid.Value) { throw "$user is a member of Administrators; use a dedicated non-admin account." }

    # Preflight before any change: logon right, then read access to everything the task loads outside AppRoot.
    $tokenSids = Get-AccountTokenSid -Sid $sid.Value
    Assert-BatchLogonRight -Account $user -TokenSids $tokenSids
    $readPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $pwsh, (Join-Path (Split-Path -Parent $pwsh) 'System.Management.Automation.dll'), $script, $script:ModulePath) { $readPaths.Add($p) }
    $checkContext = New-LifecycleContext -AppRoot $layout.Root -ReleasePath $checkRelease -Manifest $manifest -RuntimePath $checkRuntime
    if (-not (Test-PathIsUnder -Child $checkContext.Runtime -Parent $layout.Root)) { $readPaths.Add($checkContext.Runtime) }
    if ($checkContext.ChildRuntime) { $readPaths.Add($checkContext.ChildRuntime) }
    Assert-AccountCanRead -Account $user -TokenSids $tokenSids -Path $readPaths.ToArray()

    [void](Initialize-AppTaskFolder -TaskPath $script:TaskPath)
    Set-AppAcl -Layout $layout -Account $user

    $spec = Get-AppBootTaskSpec -AppId $AppId -Layout $layout -PowerShellPath $pwsh -WatchdogScriptPath $script
    $definition = New-AppTaskDefinition -PowerShellPath $spec.Execute -Argument $spec.Arguments -WorkingDirectory $spec.WorkingDirectory -IntervalMinutes $WatchdogIntervalMinutes
    $action = $definition.Action; $boot = $definition.BootTrigger; $repeat = $definition.RepeatTrigger; $settings = $definition.Settings
    $taskName = "SolutionDeploy-$AppId"
    $password = $Credential.GetNetworkCredential().Password
    try {
        Register-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath -Action $action -Trigger @($boot, $repeat) `
            -Settings $settings -User $user -Password $password -RunLevel Limited `
            -Description "SolutionDeploy watchdog for $AppId. Starts at boot and repeats every $WatchdogIntervalMinutes min." -Force -ErrorAction Stop | Out-Null
    }
    finally { $password = $null }
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath -ErrorAction Stop
    if ([string]$task.Principal.LogonType -ne 'Password') { throw "Task registered with logon type $($task.Principal.LogonType), expected Password." }
    if ([string]$task.Principal.RunLevel -ne 'Limited') { throw "Task registered with run level $($task.Principal.RunLevel), expected Limited." }
    [void](Assert-AppBootTask -AppId $AppId -AppRoot $layout.Root -PowerShellPath $spec.Execute -ExpectedAccount $user -WatchdogScriptPath $spec.ScriptPath)
    return [pscustomobject]@{
        AppId = $AppId; TaskPath = $script:TaskPath; TaskName = $taskName; Account = $user
        LogonType = 'Password'; RunLevel = 'Limited'; IntervalMinutes = $WatchdogIntervalMinutes; Started = $false
    }
}

#endregion

Export-ModuleMember -Function Test-AppReadiness, Start-ManagedApp, Stop-ManagedApp, Invoke-AppWatchdog, Install-AppBootTask,
    Get-ManagedAppStatus, Get-ManagedAppEnvironment, Initialize-AppTaskFolder, Test-ManagedAppIdentity, Test-ManagedAppHeadless, Assert-AppBootTask, Get-ReleaseRuntimePath, Get-AppMaintenance, Set-AppMaintenance, Clear-AppMaintenance, Read-LifecycleManifest, Get-AppLayout
