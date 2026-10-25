#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:FrameworkRoot = Split-Path -Parent $PSScriptRoot
$script:DeploymentProgressPath = $null

function Get-Sha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Read-DeploymentJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required JSON file is missing: $Path" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
}

function Write-DeploymentJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value,[switch]$CreateNew)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent ('.write-' + [guid]::NewGuid().ToString('N'))
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 40))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), -not $CreateNew)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Set-DeploymentProgressPath {
    param([AllowNull()][string]$Path)
    $script:DeploymentProgressPath = $Path
}

function Write-DeploymentProgress {
    param([Parameter(Mandatory)][string]$Step, [long]$Completed = 0, [long]$Total = 0)
    if (-not $script:DeploymentProgressPath) { return }
    # Progress is informational for the controller; a failed write must never fail the operation.
    try { Write-DeploymentJson $script:DeploymentProgressPath @{step=$Step; completed=$Completed; total=$Total; updatedLocal=(Get-Date).ToString('o')} }
    catch { Write-Verbose 'Progress write skipped.' }
}

function Resolve-OwnedPath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath, [switch]$AllowRoot)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if(Test-Path -LiteralPath $base){
        if((Get-Item -LiteralPath $base -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned roots cannot be reparse points.'}
    }
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':')) { throw 'Owned paths must be relative and cannot contain alternate data streams.' }
    $path = [IO.Path]::GetFullPath((Join-Path $base $RelativePath))
    if ($path -eq $base) {
        if ($AllowRoot) { return $path }
        throw 'An owned path cannot name the ownership root itself.'
    }
    if (-not $path.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escapes the owned root.' }
    $cursor = $base
    foreach ($segment in [IO.Path]::GetRelativePath($base, $path).Split('\')) {
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are forbidden in owned input/output paths.' }
        }
    }
    $path
}

function Assert-Identifier {
    param([string]$Value)
    if ($Value -notmatch '^[a-z0-9][a-z0-9-]{1,79}$') { throw 'Invalid deployment identifier.' }
}

function Test-DeploymentLockSharingViolation {
    param([Parameter(Mandatory)][Exception]$Exception)
    $Exception -is [IO.IOException] -and (($Exception.HResult -band 0xffff) -eq 32)
}

function Get-SubmissionHolderText {
    param([Parameter(Mandatory)][string]$RemoteRoot)
    try {
        $pendingPath = Join-Path $RemoteRoot 'control\pending.json'
        if (-not (Test-Path -LiteralPath $pendingPath)) { return '' }
        $pending = Read-DeploymentJson $pendingPath
        Assert-Identifier $pending.operationId
        $age = [DateTime]::Now - (Get-Item -LiteralPath $pendingPath).LastWriteTime
        $app = ''
        $requestPath = Join-Path $RemoteRoot ('operations\' + $pending.operationId + '\request.json')
        if (Test-Path -LiteralPath $requestPath) { $app = [string](Read-DeploymentJson $requestPath).plan.app }
        '{0}operation {1} submitted {2:n0} min ago' -f $(if($app){"$app "}else{''}),$pending.operationId,$age.TotalMinutes
    } catch { '' }
}

function Get-DeploymentLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(0,86400)][int]$WaitTimeoutSeconds=0,
        [ValidateRange(0.1,60)][double]$RetryIntervalSeconds=5,
        [string]$HolderRoot
    )
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        try { return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if(-not (Test-DeploymentLockSharingViolation $_.Exception)){throw}
            if($WaitTimeoutSeconds -eq 0){throw 'Another operation holds the deployment lock.'}
            if($clock.Elapsed.TotalSeconds -ge $WaitTimeoutSeconds){
                throw "Timed out after $WaitTimeoutSeconds seconds waiting for the deployment lock."
            }
            $holder = ''
            if ($HolderRoot) { $holder = Get-SubmissionHolderText $HolderRoot }
            Write-Host ("Waiting for deployment lock {0}; elapsed {1:n0}s{2}" -f $Path,$clock.Elapsed.TotalSeconds,$(if($holder){"; $holder"}else{''}))
            Start-Sleep -Milliseconds ([int]($RetryIntervalSeconds*1000))
        }
    }
}

function Get-Manifest {
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not (Test-Json -Json $text -SchemaFile (Join-Path $script:FrameworkRoot 'schemas\application.schema.json') -ErrorAction Stop)) { throw 'Manifest schema validation failed.' }
    $manifest = $text | ConvertFrom-Json -AsHashtable
    Assert-Identifier $manifest.id
    if($manifest.database.name -cnotmatch '^[a-z][a-z0-9_]{1,39}$'){throw 'Invalid app database name.'}
    Resolve-OwnedPath -Root 'C:\SolutionDeployValidation' -RelativePath $manifest.database.migrationsDirectory | Out-Null
    if($manifest.build.ContainsKey('excludePaths')){
        foreach($path in $manifest.build.excludePaths){Resolve-OwnedPath -Root 'C:\SolutionDeployValidation' -RelativePath $path|Out-Null}
        if($manifest.launch.entrypoint -in $manifest.build.excludePaths -or 'deploy\application.json' -in $manifest.build.excludePaths){throw 'Build exclusions cannot remove the manifest or launch entrypoint.'}
    }
    if(-not $manifest.launch.environment.ContainsKey('STORAGE_BACKEND') -or $manifest.launch.environment.STORAGE_BACKEND -ne 'postgresql'){
        throw 'Production manifests must explicitly require the PostgreSQL backend.'
    }
    foreach ($relative in @($manifest.launch.entrypoint) + @($manifest.build.commands | ForEach-Object {
        if ($_.ContainsKey('workingDirectory')) { $_.workingDirectory }
    })) {
        Resolve-OwnedPath -Root 'C:\SolutionDeployValidation' -RelativePath $relative -AllowRoot | Out-Null
    }
    $stateDeclarations=@($manifest.state)
    if($manifest.ContainsKey('managedState')){
        $stateDeclarations+=@($manifest.managedState)
        foreach($item in $manifest.managedState){
            Resolve-OwnedPath -Root 'C:\SolutionDeployValidation\shared' -RelativePath $item.source|Out-Null
            if($item.source -notmatch '^(data|secrets)\\' -or $item.target -notmatch '^(data|secrets)\\'){
                throw 'Managed moves may transfer only declared data and private secrets; logs, backups, and run files stay host-local.'
            }
            foreach($other in $manifest.managedState){
                if(-not [object]::ReferenceEquals($item,$other) -and
                    ($item.target -ieq $other.target -or $item.target.StartsWith($other.target+'\',[StringComparison]::OrdinalIgnoreCase))){
                    throw 'Managed state declarations cannot overlap.'
                }
            }
        }
    }
    foreach ($item in $stateDeclarations) {
        Resolve-OwnedPath -Root 'C:\SolutionDeployValidation' -RelativePath $item.target | Out-Null
        if ($item.target -notmatch '^(data|secrets|backups|logs)\\') { throw 'State destinations must be under a shared data, secrets, backups, or logs directory.' }
        if ($item.kind -eq 'secret' -and $item.target -notmatch '^(secrets|data|backups)\\') { throw 'Credentials must be placed in protected secrets, app-owned data, or protected backup storage.' }
    }
    foreach ($key in $manifest.launch.environment.Keys) {
        if ($key -match '(?i)PASSWORD|TOKEN|API_KEY|ACCESS_CODE|USER_KEY|APP_TOKEN|^DATABASE_URL$') { throw 'Secret values cannot be declared in manifest environment fields.' }
    }
    if ($manifest.launch.ContainsKey('secretFile')) {
        $runtimeSecret=Resolve-OwnedPath -Root 'C:\SolutionDeployValidation\shared\secrets' -RelativePath $manifest.launch.secretFile
        foreach($item in $stateDeclarations){
            $importTarget=Resolve-OwnedPath -Root 'C:\SolutionDeployValidation\shared' -RelativePath $item.target
            if($runtimeSecret -ieq $importTarget -or ($item.kind -eq 'directory' -and $runtimeSecret.StartsWith($importTarget+'\',[StringComparison]::OrdinalIgnoreCase))){
                throw 'Imported source state overlaps the separately provisioned runtime secret file. Archive source environments under secrets\source instead.'
            }
        }
    }
    $hosts = @($manifest.routes | ForEach-Object { $_.hostname })
    if (@($hosts | Select-Object -Unique).Count -ne $hosts.Count) { throw 'Duplicate route hostname.' }
    foreach ($route in $manifest.routes) {
        if ($route.ContainsKey('catchPath') -and $manifest.id -ne 'ferry-tracker') { throw 'Only Ferry Tracker may declare the catch exception.' }
    }
    $manifest
}

function Get-DeploymentEnvironment {
    param([string]$Name = 'production', [string]$ConfigurationRoot = $script:FrameworkRoot)
    Assert-Identifier $Name
    $path = Join-Path $ConfigurationRoot "environments\$Name.json"
    $environment = Read-DeploymentJson $path
    foreach ($key in @('schemaVersion','name','host','address','root','apps','hosts','defaultTarget','databaseTarget')) {
        if (-not $environment.ContainsKey($key)) { throw "Environment missing $key." }
    }
    if ($environment.schemaVersion -ne 2 -or $environment.name -ne $Name) { throw 'Environment identity/version mismatch. Replan using the current host registry.' }
    if(-not $environment.hosts.ContainsKey($environment.defaultTarget)){throw 'Default target is not registered.'}
    foreach($key in $environment.hosts.Keys){
        Assert-Identifier $key
        $hostRecord=$environment.hosts[$key]
        $ip=$null
        if(-not [Net.IPAddress]::TryParse($hostRecord.address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Registered host must use an explicit private IPv4 address.'}
        $octets=$ip.GetAddressBytes()
        $private=$octets[0] -eq 10 -or ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
            ($octets[0] -eq 192 -and $octets[1] -eq 168) -or ($octets[0] -eq 100 -and $octets[1] -ge 64 -and $octets[1] -le 127)
        if($hostRecord.host -cne $key -or $hostRecord.address -cne $ip.ToString() -or -not $private -or
            $hostRecord.root -notmatch '^[A-Z]:\\ProgramData\\SolutionDeploy$' -or
            -not $hostRecord.ContainsKey('routeProfile') -or [string]::IsNullOrWhiteSpace($hostRecord.routeProfile)){
            throw 'Registered host identity, private address, dedicated root, or route profile is invalid.'
        }
        foreach($field in @('host','address','root')){
            if($environment[$field] -cne $environment.hosts[$environment.defaultTarget][$field]){throw 'Default target aliases differ from the registered host.'}
        }
    }
    $database=$environment.databaseTarget
    if($database.host -cne 'jimbrownhome1' -or $database.serverName -cne 'jimbrownhome1' -or
        $database.remoteSslMode -ne 'verify-full' -or -not $environment.hosts.ContainsKey($database.host) -or
        $database.address -ne $environment.hosts[$database.host].address -or $database.root -ne $environment.hosts[$database.host].root -or $database.port -ne 5432){
        throw 'PostgreSQL must remain on the registered jimbrownhome1 server with verified private TLS policy.'
    }
    if ($environment.host -notmatch '^[a-zA-Z0-9-]+$' -or $environment.address -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') { throw 'Invalid environment host identity.' }
    if ($environment.root -notmatch '^[A-Z]:\\.+[^\\]$' -or $environment.root -match '(?i)\\Windows(?:\\|$)|\\Users(?:\\|$)') { throw 'Environment root must be an explicit dedicated local deployment directory.' }
    $ports = @{}
    $databases=@{}
    foreach ($id in $environment.apps.Keys) {
        Assert-Identifier $id
        $placement = $environment.apps[$id]
        if($environment.storagePolicy.databases[$id] -cnotmatch '^[a-z][a-z0-9_]{1,39}$' -or $databases.ContainsKey($environment.storagePolicy.databases[$id])){
            throw 'Every solution requires its own unique valid database allocation.'
        }
        $databases[$environment.storagePolicy.databases[$id]]=$true
        if ($ports.ContainsKey([string]$placement.port)) { throw 'Two apps reserve the same production port.' }
        $ports[[string]$placement.port] = $id
        if ($placement.manifest -match '^[A-Z]:|^\\\\') { throw 'Manifest location must be relative to the framework checkout.' }
    }
    @{ Path = $path; Value = $environment; Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Invoke-DeploymentCommand {
    param([Parameter(Mandatory)][string]$Executable, [string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory, [int]$TimeoutSeconds = 120, [switch]$Capture)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable; $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    if ([IO.Path]::IsPathFullyQualified($Executable)) {
        $start.Environment['PATH'] = (Split-Path -Parent $Executable) + [IO.Path]::PathSeparator + $start.Environment['PATH']
    }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $start.Environment['GCM_INTERACTIVE'] = 'Never'
    $start.Environment['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes'
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Failed to start the requested deployment tool.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(1000)) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $process.Kill($true); $process.WaitForExit()
                throw "Deployment tool exceeded its $TimeoutSeconds-second timeout."
            }
            if ([int]$clock.Elapsed.TotalSeconds % 10 -eq 0) {
                Write-Host ("Tool running, elapsed {0:n0}s" -f $clock.Elapsed.TotalSeconds)
                Write-DeploymentProgress ('Running ' + [IO.Path]::GetFileName($Executable)) ([long]$clock.Elapsed.TotalSeconds) $TimeoutSeconds
            }
        }
        if ($process.ExitCode -ne 0) { throw "Deployment tool failed with exit code $($process.ExitCode). Output withheld because it may contain sensitive configuration." }
        if ($Capture) { $stdout.GetAwaiter().GetResult().TrimEnd("`r","`n") }
    } finally { $process.Dispose() }
}

function Get-HostSnapshot {
    param([Parameter(Mandatory)][hashtable]$Environment)
    $session = $null
    try {
        $session = New-CimSession -ComputerName $Environment.host -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 20
        $os = Get-CimInstance -CimSession $session -ClassName Win32_OperatingSystem -Property CSName,OSArchitecture -OperationTimeoutSec 20
        $product = Get-CimInstance -CimSession $session -ClassName Win32_ComputerSystemProduct -Property UUID -OperationTimeoutSec 20
        $ips = @(Get-CimInstance -CimSession $session -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -Property IPAddress -OperationTimeoutSec 20 | ForEach-Object { $_.IPAddress })
        $drive = $Environment.root.Substring(0,2)
        $disk = Get-CimInstance -CimSession $session -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'" -Property FreeSpace -OperationTimeoutSec 20
        $listeners = @(Get-CimInstance -CimSession $session -Namespace root\StandardCimv2 -ClassName MSFT_NetTCPConnection -Filter 'State=2' -Property LocalPort,OwningProcess -OperationTimeoutSec 20 |
            Where-Object { $_.LocalPort -in @($Environment.apps.Values | ForEach-Object { $_.port }) } |
            ForEach-Object { @{ port=[int]$_.LocalPort; pid=[int]$_.OwningProcess } })
        if ($os.CSName -ine $Environment.host -or $Environment.address -notin $ips -or [string]::IsNullOrWhiteSpace($product.UUID)) { throw 'Destination identity/address did not match the selected environment.' }
        @{
            host=$os.CSName; address=$Environment.address; identity=$product.UUID
            architecture=$os.OSArchitecture; freeBytes=[long]$disk.FreeSpace; listeners=$listeners
            collectedLocal=(Get-Date).ToString('o'); verified=$true
        }
    } finally { if ($session) { Remove-CimSession $session } }
}

function Get-PlanDigest {
    param([Parameter(Mandatory)][hashtable]$Plan)
    $copy = [ordered]@{}
    foreach ($key in @($Plan.Keys | Sort-Object)) {
        if ($key -notin @('planHash','reportPath')) { $copy[$key] = $Plan[$key] }
    }
    Get-Sha256Text (ConvertTo-CanonicalJson $copy)
}

function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)][AllowNull()]$Value)
    function Convert-CanonicalValue($Node){
        if($null -eq $Node){return $null}
        if($Node -is [Collections.IDictionary]){
            $ordered=[ordered]@{}
            foreach($key in @($Node.Keys | Sort-Object -CaseSensitive)){$ordered[[string]$key]=Convert-CanonicalValue $Node[$key]}
            return $ordered
        }
        if($Node -is [Collections.IEnumerable] -and $Node -isnot [string]){
            $items=[Collections.Generic.List[object]]::new()
            foreach($item in $Node){$items.Add((Convert-CanonicalValue $item))}
            return ,$items.ToArray()
        }
        return $Node
    }
    $canonical=Convert-CanonicalValue $Value
    ConvertTo-Json -InputObject $canonical -Depth 60 -Compress
}

function Read-OptionalDeploymentText {
    param([Parameter(Mandatory)][string]$Path)
    try{
        $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }catch [Management.Automation.ItemNotFoundException]{
        $parent=Split-Path -Parent $Path
        while($parent){
            try{
                $directory=Get-Item -LiteralPath $parent -Force -ErrorAction Stop
                if(-not $directory.PSIsContainer){throw 'Deployment record parent is not a directory.'}
                Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop|Out-Null
                return $null
            }catch [Management.Automation.ItemNotFoundException]{
                $parent=Split-Path -Parent $parent
            }
        }
        throw 'Deployment record storage is unreachable. Absence cannot be established.'
    }
    if($item.PSIsContainer){throw 'Deployment record is a directory.'}
    $text=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if([string]::IsNullOrWhiteSpace($text)){throw 'Deployment record is empty.'}
    $text
}

function Read-OptionalRemoteRecord {
    param([Parameter(Mandatory)][string]$Path)
    $job=Start-Job -ScriptBlock {
        param($File,$Module)
        Import-Module $Module -DisableNameChecking
        Read-OptionalDeploymentText $File
    } -ArgumentList $Path,(Join-Path $PSScriptRoot 'Deployment.psm1')
    try{
        if(-not (Wait-Job $job -Timeout 20)){throw 'Remote deployment record read timed out.'}
        $raw=Receive-Job $job -ErrorAction Stop
        if($null -ne $raw){
            $record=$raw|ConvertFrom-Json -AsHashtable -DateKind String
            if($record -isnot [hashtable]){throw 'Deployment record must be a JSON object.'}
            $record
        }else{$null}
    }finally{Stop-Job $job;Remove-Job $job}
}

function New-DeploymentPlan {
    param([Parameter(Mandatory)][string]$App, [string]$Environment='production',
        [string]$ConfigurationRoot=$script:FrameworkRoot, [string]$Commit='HEAD',
        [hashtable]$HostSnapshot, [hashtable]$DatabaseHostSnapshot, [string]$Target, [switch]$Offline)
    $envRecord = Get-DeploymentEnvironment -Name $Environment -ConfigurationRoot $ConfigurationRoot
    $configuration = $envRecord.Value
    if(-not $Target){$Target=$configuration.defaultTarget}
    if(-not $configuration.hosts.ContainsKey($Target)){throw 'Unknown application target. Register and review the host first.'}
    $env=@{}+$configuration
    foreach($field in @('host','address','root','routeProfile')){$env[$field]=$configuration.hosts[$Target][$field]}
    if (-not $env.ContainsKey('storagePolicy')) { throw 'Environment must explicitly declare its production storage policy.' }
    if (-not $env.apps.ContainsKey($App)) { throw 'Unknown app in the selected environment.' }
    $manifestPath = [IO.Path]::GetFullPath((Join-Path $ConfigurationRoot $env.apps[$App].manifest))
    $manifest = Get-Manifest $manifestPath
    if ($manifest.id -ne $App -or $manifest.launch.port -ne $env.apps[$App].port) { throw 'Manifest identity/port differs from environment reservation.' }
    if($manifest.database.name -ne $env.storagePolicy.databases[$App]){throw 'Manifest database does not match the per-solution environment allocation.'}
    foreach ($other in $env.apps.Keys) {
        if ($other -eq $App) { continue }
        $otherPath = [IO.Path]::GetFullPath((Join-Path $ConfigurationRoot $env.apps[$other].manifest))
        if (-not (Test-Path -LiteralPath $otherPath)) { throw 'Every environment app needs a manifest to verify route ownership.' }
        $otherManifest = Get-Manifest $otherPath
        if (@($manifest.routes.hostname | Where-Object { $_ -in $otherManifest.routes.hostname }).Count) { throw 'Another app reserves a requested hostname.' }
    }
    $repositoryRoot = Split-Path -Parent (Split-Path -Parent $manifestPath)
    $git = (Get-Command git -CommandType Application).Source
    if ($Commit -notmatch '^(HEAD|[a-fA-F0-9]{7,40})$') { throw 'Commit must be HEAD or a hexadecimal commit ID.' }
    $sha = Invoke-DeploymentCommand $git @('--no-optional-locks','-c','core.fsmonitor=false','rev-parse',"$Commit^{commit}") $repositoryRoot -Capture
    $origin = Invoke-DeploymentCommand $git @('--no-optional-locks','remote','get-url','origin') $repositoryRoot -Capture
    if ($origin -notmatch ('^(https://github\.com/|git@github\.com:)' + [regex]::Escape(($manifest.repository -replace '^https://github.com/','' -replace '\.git$','')) + '(\.git)?$')) {
        throw 'Checkout origin does not match the trusted manifest repository.'
    }
    $dirty = Invoke-DeploymentCommand $git @('--no-optional-locks','-c','core.fsmonitor=false','status','--porcelain','--untracked-files=normal') $repositoryRoot -Capture
    $blockers = [Collections.Generic.List[string]]::new()
    if ($env.storagePolicy.implementationStatus -ne 'validated') {
        $blockers.Add('PostgreSQL is required with a separate database per solution. Persistence adapters, schema/import scripts, backup/restore, and revised-plan approval are pending.')
    }
    if ($dirty) { $blockers.Add('Source checkout has changes. Commit the reviewed manifest/adapters before staging a pinned release.') }
    if ($Offline) {
        $HostSnapshot = @{host=$env.host; address=$env.address; verified=$false; identity=$null}
        $blockers.Add('Offline plan: destination identity and current placement are unverified.')
    } elseif (-not $HostSnapshot) { $HostSnapshot = Get-HostSnapshot $env }
    if (-not $HostSnapshot.verified -or $HostSnapshot.host -ine $env.host -or $HostSnapshot.address -ne $env.address) { $blockers.Add('Target identity/address verification is incomplete.') }
    $placement = $env.apps[$App]['observedHost']
    $active = $null
    $authority=$null
    if (-not $Offline) {
        # This is a bounded controller-side read; no production directory is created by Plan.
        $activeShare = '\\' + $env.host + '\' + $env.root.Substring(0,1) + '$' + $env.root.Substring(2) + "\apps\$App\state\active.json"
        $active=Read-OptionalRemoteRecord $activeShare
        $authorityTarget=$configuration.databaseTarget
        $authorityPath='\\'+$authorityTarget.host+'\'+$authorityTarget.root.Substring(0,1)+'$'+$authorityTarget.root.Substring(2)+"\control\placements\$Environment\$App.json"
        $authority=Read-OptionalRemoteRecord $authorityPath
        if($authority){
            if($authority.status -ne 'Active' -or -not $configuration.hosts.ContainsKey($authority.host)){throw 'Application transition authority is unresolved or names an unregistered host. Inspect it before planning.'}
            $placement=$authority.host
            if($placement -ieq $env.host -and (-not $active -or $active.planHash -ne $authority.planHash -or $active.releaseId -ne $authority.releaseId)){
                throw 'Selected host active release differs from central placement authority.'
            }
        } elseif($active){throw 'Managed destination exists without central placement authority. Review ownership instead of adopting it.'}
    }
    $transitionKind=if($authority){if($placement -ieq $env.host){'ManagedDeploy'}else{'ManagedMove'}}elseif($env.apps[$App].ContainsKey('newInstallation') -and $env.apps[$App].newInstallation){'FirstInstall'}else{'LegacyConversion'}
    $operation = if ($transitionKind -in @('ManagedDeploy','FirstInstall')) { 'Deploy' } else { 'Cutover' }
    $sourceSnapshot=$null
    if($operation -eq 'Cutover'){
        if(-not $configuration.hosts.ContainsKey($placement)){throw 'Register the actual source host before planning a migration.'}
        if($Offline){$sourceSnapshot=@{host=$placement;identity=$null;verified=$false}}
        else{
            $sourceEnvironment=@{}+$env
            foreach($field in @('host','address','root')){$sourceEnvironment[$field]=$configuration.hosts[$placement][$field]}
            $sourceSnapshot=Get-HostSnapshot $sourceEnvironment
            if($authority -and $sourceSnapshot.identity -ne $authority.hostIdentity){throw 'Source hardware identity differs from central placement authority.'}
        }
    }
    if(-not $Offline){
        if(-not $DatabaseHostSnapshot){$dbEnvironment=@{}+$env;foreach($field in @('host','address','root')){$dbEnvironment[$field]=$configuration.databaseTarget[$field]};$DatabaseHostSnapshot=Get-HostSnapshot $dbEnvironment}
    }else{$DatabaseHostSnapshot=@{host=$configuration.databaseTarget.host;address=$configuration.databaseTarget.address;identity=$null;verified=$false}}
    $transferManifest=@{}+$manifest
    if($transitionKind -eq 'ManagedMove'){
        if(-not $manifest.ContainsKey('managedState')){throw 'Managed moves require an explicit managedState declaration.'}
        $sourceHost=$configuration.hosts[$placement]
        $transferManifest.source=@{host=$placement;root=(Join-Path $sourceHost.root ("apps\$App\shared"));tasks=@("SolutionDeploy-$App");managed=$true}
        $transferManifest.state=@($manifest.managedState)
    }
    $blockers.Add('Production provisioning and mutation require review of this exact plan.')
    if ($operation -eq 'Cutover') { $blockers.Add('Final source sizing, complete state inventory, graceful-stop verification, and source fencing must pass before cutover.') }
    if (@($manifest.state | Where-Object kind -eq 'sqlite').Count) { $blockers.Add('Database action scripts and real-data startup require independent review before execution.') }
    $operationId=[guid]::NewGuid().ToString('N')
    $plan = [ordered]@{
        schemaVersion=2; id=$operationId; app=$App; environment=$Environment
        operation=$operation; createdLocal=(Get-Date).ToString('o')
        sourceCommit=$sha; repository=$manifest.repository
        manifest=$manifest; manifestHash=(Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant()
        environmentHash=$envRecord.Hash; target=$env; hostSnapshot=$HostSnapshot
        databaseTarget=$configuration.databaseTarget;databaseHostSnapshot=$DatabaseHostSnapshot
        sourceHostSnapshot=$sourceSnapshot
        solutionDatabases=@($configuration.storagePolicy.databases.Values|Sort-Object -Unique)
        transitionKind=$transitionKind;placementAuthority=$authority;transferManifest=$transferManifest
        observedHost=$placement; currentRelease=$active
        releaseId=($sha.Substring(0,12) + '-' + $operationId.Substring(0,8))
        blockers=@($blockers); status='AwaitingReview'
        databaseActionsRequired=$true
    }
    $result = @{} + $plan
    $result.planHash = Get-PlanDigest $result
    $result
}

function Assert-DeploymentApproval {
    param([Parameter(Mandatory)][hashtable]$Plan, [Parameter(Mandatory)][string]$ApprovalPath,
        [Parameter(Mandatory)][string]$Action)
    if ($Plan.planHash -ne (Get-PlanDigest $Plan)) { throw 'Plan content hash mismatch.' }
    if($Plan.ContainsKey('schemaVersion') -and $Plan.schemaVersion -eq 2){
        foreach($field in @('databaseHostIdentity','routeProfile')){if(-not (Read-DeploymentJson $ApprovalPath).ContainsKey($field)){throw "Host-aware approval missing $field."}}
        $hostApproval=Read-DeploymentJson $ApprovalPath
        if(-not $Plan.databaseHostSnapshot.verified -or $hostApproval.databaseHostIdentity -ne $Plan.databaseHostSnapshot.identity -or $hostApproval.routeProfile -ne $Plan.target.routeProfile){
            throw 'Database/authority identity or selected host route profile differs from approval.'
        }
        if($Action -in @('Cutover','PrepareCutover') -and (-not $Plan.sourceHostSnapshot.verified -or -not $hostApproval.ContainsKey('sourceHostIdentity') -or $hostApproval.sourceHostIdentity -ne $Plan.sourceHostSnapshot.identity)){
            throw 'Cutover approval must identify the verified source host hardware identity.'
        }
    }
    if ($Plan.ContainsKey('target') -and $Plan.target.ContainsKey('storagePolicy') -and
        $Plan.target.storagePolicy.implementationStatus -ne 'validated') {
        throw 'Production execution is blocked until the revised PostgreSQL implementation and migration plan pass review and validation.'
    }
    $approval = Read-DeploymentJson $ApprovalPath
    $routine=$Plan.ContainsKey('routineRelease') -and $Plan.routineRelease -eq $true
    if($routine){
        $consent=$Plan.routineConsent
        foreach($field in @('app','environment','target','sourceCommit','approvedBy','reason','expiresLocal','actions','dataActionsReviewed')){
            if(-not $consent.ContainsKey($field)){throw "Routine consent missing $field."}
        }
        if($Plan.transitionKind -ne 'ManagedDeploy' -or $Plan.operation -ne 'Deploy' -or -not $Plan.currentRelease -or
            $consent.app -ne $Plan.app -or $consent.environment -ne $Plan.environment -or $consent.target -ine $Plan.target.host -or
            $consent.sourceCommit -cne $Plan.sourceCommit -or $Plan.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or
            $Action -notin $consent.actions -or $consent.dataActionsReviewed -ne $true -or
            [string]::IsNullOrWhiteSpace($consent.reason) -or [string]::IsNullOrWhiteSpace($consent.approvedBy) -or
            [DateTimeOffset]::Parse($consent.expiresLocal) -le [DateTimeOffset]::Now){
            throw 'Routine consent does not authorize this exact release and action.'
        }
        if($approval.approvedBy -ne $consent.approvedBy -or
            [DateTimeOffset]::Parse($approval.expiresLocal) -gt [DateTimeOffset]::Parse($consent.expiresLocal)){
            throw 'Action approval expands the routine release consent.'
        }
        if(-not $approval.ContainsKey('consentSHA256') -or
            $approval.consentSHA256 -ne (Get-Sha256Text (ConvertTo-CanonicalJson $consent))){
            throw 'Action approval does not bind the exact routine release consent.'
        }
        foreach($field in @('sourceArchiveSHA256','runtimeSHA256','npmSHA256','npmCliSHA256')){
            if(-not $consent.ContainsKey($field) -or -not $approval.ContainsKey($field) -or $consent[$field] -cne $approval[$field]){
                throw "Routine approval changed pinned $field."
            }
        }
        $databaseInputs=@{}
        foreach($field in @('psqlPath','psqlSHA256','postgresPassFile','postgresRuntimeRole','postgresEndpointSHA256',
            'postgresSslRootCert','postgresSslRootCertSHA256','migrationSqlSHA256','expectedSchemaFingerprint')){
            if($approval.ContainsKey($field)){$databaseInputs[$field]=$approval[$field]}
        }
        if(-not $consent.ContainsKey('approvalInputsSHA256') -or
            $consent.approvalInputsSHA256 -ne (Get-Sha256Text (ConvertTo-CanonicalJson $databaseInputs))){
            throw 'Routine approval changed pinned database compatibility inputs.'
        }
    }
    foreach ($key in @('planHash','hostIdentity','actions','approvedBy','expiresLocal','gates')) {
        if (-not $approval.ContainsKey($key)) { throw "Approval missing $key." }
    }
    if ($approval.planHash -ne $Plan.planHash -or $approval.hostIdentity -ne $Plan.hostSnapshot.identity -or
        -not $Plan.hostSnapshot.verified -or $Action -notin $approval.actions -or
        [string]::IsNullOrWhiteSpace($approval.approvedBy) -or [DateTimeOffset]::Parse($approval.expiresLocal) -le [DateTimeOffset]::Now) {
        throw 'Approval does not match this plan, verified host, action, reviewer, or expiry.'
    }
    if ($approval.ContainsKey('transferArchiveSHA256') -and $approval.transferArchiveSHA256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'transferArchiveSHA256 must be an exact lowercase SHA-256.'
    }
    $required = @('sourceCommitted','artifactTrust','hostProvisioning','runtimeIdentity','routePreconditions')
    if($Plan.ContainsKey('schemaVersion') -and $Plan.schemaVersion -eq 2){$required+='clocksSynchronized'}
    if($Action -eq 'PrepareCutover'){
        if($Plan.operation -ne 'Cutover' -or $Plan.transitionKind -ne 'LegacyConversion' -or $Plan.currentRelease){throw 'PrepareCutover is only for initial legacy adoption.'}
        $required+=@('gracefulStopVerified','dataInventory','rollbackReady','filePreparationReviewed')
        foreach($field in @('transferSHA256','sourceFenceSHA256')){
            if(-not $approval.ContainsKey($field) -or $approval[$field] -notmatch '^[a-f0-9]{64}$'){throw "Preparation approval missing $field."}
        }
    }
    if ($Action -in @('Cutover','Deploy','Rollback')) {
        $required += @('gracefulStopVerified','dataInventory','rollbackReady')
        if ($routine) {
            $required+=@('schemaCompatible','postgresStateValidated')
        } elseif ($Plan.databaseActionsRequired) {
            $required += @('independentDatabaseReview','postgresBackupRestoreVerified','postgresRoleIsolation','schemaCompatible')
            if(-not $Plan.ContainsKey('transitionKind') -or $Plan.transitionKind -eq 'LegacyConversion'){$required+='postgresImportValidated'}
            else{$required+='postgresStateValidated'}
        }
        if($Plan.ContainsKey('transitionKind') -and $Plan.transitionKind -eq 'ManagedMove'){$required+=@('centralDatabasePreserved','managedFilesReviewed','sourceMaintenanceVerified')}
    }
    foreach ($gate in $required) {
        if (-not $approval.gates.ContainsKey($gate) -or $approval.gates[$gate] -ne $true) { throw "Execution gate not approved: $gate" }
    }
    $approval
}

function Assert-PlanInputs {
    param([Parameter(Mandatory)][hashtable]$Plan, [string]$ConfigurationRoot=$script:FrameworkRoot)
    if ($Plan.planHash -ne (Get-PlanDigest $Plan)) { throw 'Plan content hash mismatch.' }
    if(-not $Plan.ContainsKey('schemaVersion') -or $Plan.schemaVersion -ne 2){throw 'Old deployment plan version. Generate a new host-aware plan.'}
    $env = Get-DeploymentEnvironment -Name $Plan.environment -ConfigurationRoot $ConfigurationRoot
    if ($env.Hash -ne $Plan.environmentHash) { throw 'Environment changed; prepare and approve a new plan.' }
    $path = [IO.Path]::GetFullPath((Join-Path $ConfigurationRoot $env.Value.apps[$Plan.app].manifest))
    if ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $Plan.manifestHash) { throw 'Manifest changed; prepare and approve a new plan.' }
}

function Get-ReleaseInventory {
    param([Parameter(Mandatory)][string]$ReleasePath)
    $root = [IO.Path]::GetFullPath($ReleasePath)
    $seal = Join-Path $root 'release.json'
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($root)
    while ($stack.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $stack.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release inventory cannot contain reparse points.' }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
            elseif ($item.FullName -ine $seal) { $files.Add($item) }
        }
    }
    $step = 'Hashing ' + [IO.Path]::GetFileName($root.TrimEnd('\'))
    $result = [Collections.Generic.List[object]]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew(); $next = 0
    foreach ($file in $files) {
        if ($clock.Elapsed.TotalSeconds -ge $next) { Write-DeploymentProgress $step $result.Count $files.Count; $next = $clock.Elapsed.TotalSeconds + 2 }
        $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
        finally { $stream.Dispose() }
        $result.Add(@{path=[IO.Path]::GetRelativePath($root,$file.FullName); length=$file.Length; sha256=$hash})
    }
    Write-DeploymentProgress $step $result.Count $files.Count
    @($result.ToArray() | Sort-Object { $_.path })
}

function Test-ReleaseInventory {
    param([Parameter(Mandatory)][string]$ReleasePath)
    $record = Read-DeploymentJson (Join-Path $ReleasePath 'release.json')
    $actual = @(Get-ReleaseInventory $ReleasePath)
    if ($actual.Count -ne $record.files.Count) { throw 'Release file count differs from the sealed inventory.' }
    $expected = @{}
    foreach ($file in $record.files) { $expected[$file.path] = $file }
    foreach ($file in $actual) {
        if (-not $expected.ContainsKey($file.path) -or $expected[$file.path].sha256 -ne $file.sha256) { throw 'Release file integrity check failed.' }
    }
    $record
}

function Expand-TrustedRelease {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludedPaths=@())
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $size = 0L
        if ($zip.Entries.Count -gt 50000) { throw 'Release archive exceeds its file-count limit.' }
        foreach ($entry in $zip.Entries) {
            $relative = $entry.FullName.Replace('/','\')
            $target = Resolve-OwnedPath $Destination $relative.TrimEnd('\')
            if($relative -in $ExcludedPaths){continue}
            $segments = $relative.TrimEnd('\').Split('\')
            if (@($segments | Where-Object { ($_ -like '.env*' -and $_ -notin @('.env.example','.env.sample','.env.template')) -or $_ -in @('.secrets','.venv','node_modules','backups') }).Count) { throw 'Tracked release archive contains private or generated state.' }
            $size += $entry.Length
            if ($size -gt 1GB -or $entry.Length -gt 256MB) { throw 'Release archive exceeds its extraction limit.' }
            if (($entry.ExternalAttributes -shr 16 -band 0xF000) -eq 0xA000) { throw 'Symbolic links are forbidden in source archives.' }
            if ($relative.EndsWith('\')) { [IO.Directory]::CreateDirectory($target) | Out-Null }
            else {
                [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            }
        }
    } finally { $zip.Dispose() }
}

function Convert-NodeWorkspaceLinks {
    param([Parameter(Mandatory)][string]$ReleasePath)
    $packagePath=Join-Path $ReleasePath 'package.json'
    if(-not(Test-Path -LiteralPath $packagePath)){return}
    $package=Read-DeploymentJson $packagePath
    if(-not $package.ContainsKey('workspaces')){return}
    if($package.workspaces -isnot [Collections.IList]){throw 'Workspace sealing requires an explicit list of workspace directories.'}
    foreach($workspace in $package.workspaces){
        if($workspace -isnot [string] -or [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($workspace)){throw 'Workspace sealing requires explicit directory paths without patterns.'}
        $source=Resolve-OwnedPath $ReleasePath $workspace
        $workspacePackage=Read-DeploymentJson (Join-Path $source 'package.json')
        $name=[string]$workspacePackage.name
        if($name -cnotmatch '^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$'){throw 'Invalid workspace package name.'}
        $relative='node_modules\'+$name.Replace('/','\')
        $parent=Resolve-OwnedPath $ReleasePath (Split-Path -Parent $relative)
        $link=Join-Path $parent (Split-Path -Leaf $relative)
        if(-not(Test-Path -LiteralPath $link)){throw 'Expected installed workspace link is missing.'}
        $item=Get-Item -LiteralPath $link -Force
        if(-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Workspace dependency must initially be its npm-created link.'}
        if($item.LinkType -notin @('Junction','SymbolicLink') -or @($item.Target).Count -ne 1 -or
            [IO.Path]::GetFullPath([string]$item.Target).TrimEnd('\') -ine $source.TrimEnd('\')){
            throw 'Workspace link points outside its declared release directory.'
        }
        Get-ReleaseInventory $source|Out-Null
        # Keep sealed releases link-free while retaining npm workspace package resolution.
        [IO.Directory]::Delete($link)
        if(Test-Path -LiteralPath $link){throw 'Workspace destination reappeared before copying.'}
        Copy-Item -LiteralPath $source -Destination $link -Recurse -ErrorAction Stop
    }
}

function New-StagedRelease {
    param([Parameter(Mandatory)][hashtable]$Plan, [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$RuntimePath,
        [string]$NpmPath, [int]$BuildTimeoutSeconds=300,
        [string]$SourceArchive, [string]$SourceArchiveSHA256)
    if (-not [IO.Path]::IsPathFullyQualified($RuntimePath) -or -not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw 'An existing absolute pinned runtime path is required.' }
    if ((Get-Item -LiteralPath $RuntimePath).FullName -match '(?i)\\current\\|\\shims\\') { throw 'Pin the actual runtime installation, not a mutable current/shim path.' }
    $release = Resolve-OwnedPath $AppRoot ("releases\" + $Plan.releaseId)
    $lock = Get-DeploymentLock (Join-Path $AppRoot 'state\deployment.lock')
    $archive = Join-Path $AppRoot ('state\' + $Plan.id + '.zip')
    try {
        if (Test-Path -LiteralPath $release) {
            $existing = Test-ReleaseInventory $release
            if ($existing.planHash -ne $Plan.planHash) { throw 'Release ID already belongs to another approved operation. Replan rather than overwrite.' }
            return $existing
        }
        if (-not $SourceArchive) {
            $git = (Get-Command git -CommandType Application).Source
            $dirty = Invoke-DeploymentCommand $git @('--no-optional-locks','status','--porcelain','--untracked-files=normal') $RepositoryRoot -Capture
            if ($dirty) { throw 'Source checkout is not committed/clean; staging was refused.' }
        } elseif ((Get-FileHash -LiteralPath $SourceArchive).Hash.ToLowerInvariant() -ne $SourceArchiveSHA256) { throw 'Source archive hash mismatch.' }
        [IO.Directory]::CreateDirectory($release) | Out-Null
        Write-DeploymentJson (Join-Path $AppRoot 'state\stage.json') @{planHash=$Plan.planHash;release=$release;status='Building'}
        $exclusions=@()
        if($Plan.manifest.build.ContainsKey('excludePaths')){$exclusions=@($Plan.manifest.build.excludePaths)}
        if ($SourceArchive) { Expand-TrustedRelease $SourceArchive $release -ExcludedPaths $exclusions }
        else {
            Invoke-DeploymentCommand $git @('archive','--format=zip',('-o'+$archive),$Plan.sourceCommit) $RepositoryRoot
            Expand-TrustedRelease $archive $release -ExcludedPaths $exclusions
        }
        $manifestFile = Join-Path $release 'deploy\application.json'
        if ((Get-FileHash -LiteralPath $manifestFile).Hash.ToLowerInvariant() -ne $Plan.manifestHash) { throw 'Committed manifest differs from the approved manifest.' }
        $commandIndex = 0
        foreach ($command in $Plan.manifest.build.commands) {
            $commandIndex++
            Write-DeploymentProgress ('Build command ' + $commandIndex + ': ' + $command.tool + ' ' + [string]@($command.arguments)[0]) $commandIndex @($Plan.manifest.build.commands).Count
            $working = $release
            if ($command.ContainsKey('workingDirectory')) { $working = Resolve-OwnedPath $release $command.workingDirectory -AllowRoot }
            if ($command.tool -eq 'npm') {
                if (-not $NpmPath -or -not [IO.Path]::IsPathFullyQualified($NpmPath)) { throw 'An explicit npm executable path is required for a Node build.' }
                if ($NpmPath.EndsWith('.cmd')) {
                    # Invoke a fixed Node npm CLI path without cmd.exe string interpolation.
                    $npmCli = Join-Path (Split-Path -Parent $RuntimePath) 'node_modules\npm\bin\npm-cli.js'
                    if (-not (Test-Path -LiteralPath $npmCli)) { throw 'Cannot resolve npm CLI beside the pinned Node runtime.' }
                    Invoke-DeploymentCommand $RuntimePath (@($npmCli) + @($command.arguments)) $working -TimeoutSeconds $BuildTimeoutSeconds
                } else { Invoke-DeploymentCommand $NpmPath @($command.arguments) $working -TimeoutSeconds $BuildTimeoutSeconds }
            } else {
                $python = $RuntimePath
                if ($command.arguments -contains 'pip') {
                    $python = Resolve-OwnedPath $release '.venv\Scripts\python.exe'
                    if (-not (Test-Path -LiteralPath $python)) { throw 'Create the virtual environment at its final release path before installing dependencies.' }
                }
                Invoke-DeploymentCommand $python @($command.arguments) $working -TimeoutSeconds $BuildTimeoutSeconds
            }
        }
        if (-not (Test-Path -LiteralPath (Resolve-OwnedPath $release $Plan.manifest.launch.entrypoint) -PathType Leaf)) { throw 'Build did not produce the declared entrypoint.' }
        if($Plan.manifest.runtime.kind -eq 'node'){Convert-NodeWorkspaceLinks $release}
        $record = @{
            schemaVersion=1; releaseId=$Plan.releaseId; planHash=$Plan.planHash; sourceCommit=$Plan.sourceCommit
            manifestHash=$Plan.manifestHash; runtimePath=$RuntimePath; runtimeSHA256=(Get-FileHash -LiteralPath $RuntimePath).Hash.ToLowerInvariant()
            sealedLocal=(Get-Date).ToString('o'); files=@(Get-ReleaseInventory $release)
        }
        Write-DeploymentJson (Join-Path $release 'release.json') $record
        Write-DeploymentJson (Join-Path $AppRoot 'state\stage.json') @{planHash=$Plan.planHash;release=$release;status='Sealed'}
        $record
    } finally {
        if (Test-Path -LiteralPath $archive) { [IO.File]::Delete($archive) }
        $lock.Dispose()
    }
}

function Set-ActiveRelease {
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$ReleaseId,
        [Parameter(Mandatory)][string]$OperationId, [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$PlanHash)
    Assert-Identifier $ReleaseId; Assert-Identifier $OperationId
    $release = Resolve-OwnedPath $AppRoot ("releases\$ReleaseId")
    $record = Test-ReleaseInventory $release
    $maintenance = Join-Path $AppRoot 'state\maintenance.json'
    if (-not (Test-Path -LiteralPath $maintenance)) { throw 'Active release can only change while maintenance is persisted.' }
    if (Test-Path -LiteralPath (Join-Path $AppRoot 'shared\run\process.json')) { throw 'Process ownership record must be cleared by verified graceful stop before switching.' }
    $current = Join-Path $AppRoot 'current'
    $prior = $null
    $explicitRules = @()
    if (Test-Path -LiteralPath $current) {
        $item = Get-Item -LiteralPath $current
        if ($item.LinkType -ne 'Junction') { throw 'The active path is not an owned junction.' }
        $prior = $item.Target
        # The limited app account reads the junction through its own non-inherited ACE; a recreated junction must keep it.
        $explicitRules = @((Get-Acl -LiteralPath $current).Access | Where-Object { -not $_.IsInherited })
        $priorRelative = [IO.Path]::GetRelativePath($AppRoot, [string]$prior)
        if ($priorRelative -notmatch '^releases\\[^\\]+$') { throw 'Current junction points outside the owned release directory.' }
        if($prior -eq $release -and -not (Test-Path -LiteralPath (Join-Path $AppRoot 'state\active.json'))){
            $prepared=Read-DeploymentJson (Join-Path $AppRoot 'state\prepared-cutover.json')
            if($prepared.status -ne 'Prepared' -or $prepared.planHash -ne $PlanHash -or $prepared.releaseId -ne $ReleaseId){
                throw 'Initial current junction has no matching preparation receipt.'
            }
            $prior=$null
        }
    }
    $journalPath = Join-Path $AppRoot 'state\switch.json'
    if (-not $prior -and -not $explicitRules.Count) {
        # First activation: give the junction the app account's explicit, non-inheriting AppRoot read ACE.
        $explicitRules = @((Get-Acl -LiteralPath $AppRoot).Access | Where-Object {
            -not $_.IsInherited -and $_.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::None -and
            $_.AccessControlType -eq 'Allow' })
    }
    Write-DeploymentJson $journalPath @{operationId=$OperationId;phase='Prepared';previous=$prior;next=$release;planHash=$PlanHash}
    if (Test-Path -LiteralPath $current) { [IO.Directory]::Delete($current) }
    New-Item -ItemType Junction -Path $current -Target $release | Out-Null
    if ($explicitRules.Count) {
        $acl = Get-Acl -LiteralPath $current
        foreach ($rule in $explicitRules) { $acl.AddAccessRule($rule) }
        Set-Acl -LiteralPath $current -AclObject $acl
    }
    Write-DeploymentJson $journalPath @{operationId=$OperationId;phase='Switched';previous=$prior;next=$release;planHash=$PlanHash}
    Write-DeploymentJson (Join-Path $AppRoot 'state\active.json') @{
        host=$HostName;releaseId=$ReleaseId;sourceCommit=$record.sourceCommit;planHash=$PlanHash
        previousRelease=if($prior){Split-Path -Leaf $prior}else{$null};activatedLocal=(Get-Date).ToString('o')
    }
}

function Repair-ReleaseSwitch {
    param([Parameter(Mandatory)][string]$AppRoot)
    $path = Join-Path $AppRoot 'state\switch.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $journal = Read-DeploymentJson $path
    if (-not (Test-Path -LiteralPath (Join-Path $AppRoot 'state\maintenance.json'))) { throw 'Interrupted switches can only be recovered in maintenance.' }
    $next = Resolve-OwnedPath $AppRoot ([IO.Path]::GetRelativePath($AppRoot,$journal.next))
    Test-ReleaseInventory $next | Out-Null
    $current = Join-Path $AppRoot 'current'
    if (-not (Test-Path -LiteralPath $current)) {
        if ($journal.previous) {
            $previous = Resolve-OwnedPath $AppRoot ([IO.Path]::GetRelativePath($AppRoot,$journal.previous))
            Test-ReleaseInventory $previous | Out-Null
            New-Item -ItemType Junction -Path $current -Target $previous | Out-Null
            Write-DeploymentJson $path @{phase='RecoveredPrevious';previous=$previous;next=$next;operationId=$journal.operationId}
        } else { throw 'First-install switch was interrupted; replan activation before starting any app.' }
    }
}

function Get-RollbackDecision {
    param([bool]$TargetWroteData, [bool]$SchemaCompatible, [switch]$CrossHost)
    if (-not $SchemaCompatible) { return @{allowed=$false;reason='State/schema compatibility is not established.'} }
    if ($CrossHost -and $TargetWroteData) { return @{allowed=$false;reason='Reviewed reverse state transfer is required before the old host can resume.'} }
    @{allowed=$true;reason=if($CrossHost){'Stop target, verify source authority, then restore source routes.'}else{'Use retained release with current compatible shared state; never restore stale data automatically.'}}
}

function Export-DeploymentReport {
    param([Parameter(Mandatory)][hashtable]$Plan, [Parameter(Mandatory)][string]$Path,
        [hashtable]$Result, [switch]$Open)
    $encode = { param($value) [Net.WebUtility]::HtmlEncode([string]$value) }
    $app = & $encode $Plan.app
    $gates = ($Plan.blockers | ForEach-Object { '<li>' + (& $encode $_) + '</li>' }) -join ''
    $routes = ($Plan.manifest.routes | ForEach-Object { '<li><code>https://' + (& $encode $_.hostname) + '</code></li>' }) -join ''
    $transferManifest=if($Plan.ContainsKey('transferManifest')){$Plan.transferManifest}else{$Plan.manifest}
    $stateRows = ($transferManifest.state | ForEach-Object {
        '<tr><td>'+(& $encode $_.kind)+'</td><td>'+(& $encode $_.source)+'</td><td>'+(& $encode $_.target)+'</td><td>'+(& $encode $_.required)+'</td></tr>'
    }) -join ''
    $database = & $encode $Plan.manifest.database.name
    $databaseVersion = & $encode $Plan.manifest.database.schemaVersion
    $databaseEndpoint='loopback <code>127.0.0.1:5432</code>'
    $hostDetails=''
    if($Plan.ContainsKey('databaseTarget')){
        $server=& $encode $Plan.databaseTarget.host
        $address=& $encode $Plan.databaseTarget.address
        $databaseEndpoint="server <code>$server</code> / <code>$address</code>, port $(& $encode $Plan.databaseTarget.port)"
        $connection=if($Plan.target.host -ieq $Plan.databaseTarget.host){'Loopback on the database host.'}else{'Pinned private address and verified TLS server name. Remote network/TLS provisioning remains a separate approval.'}
        $hostDetails="<p>$connection Database host UUID: <code>$(& $encode $Plan.databaseHostSnapshot.identity)</code>.<br>Transition: <code>$(& $encode $Plan.transitionKind)</code>. Route profile: <code>$(& $encode $Plan.target.routeProfile)</code>.</p>"
    }
    $databaseSection="<h2>PostgreSQL allocation</h2><div class=`"card`"><p>Database <code>$database</code>, schema version <code>$databaseVersion</code>, $databaseEndpoint.</p>$hostDetails<p>Runtime role <code>sd_${database}_runtime</code>. Separate migration and non-login owner roles. Raw archives, private connection/service secrets, logs, and backup files remain protected files.</p><p>Allocation is an intended change. This report does not prove the production database, roles, schema, or imported records exist.</p></div>"
    $cutoverText='Disable source restart paths, gracefully stop and verify no source writer, export reviewed consistent SQLite/JSON snapshots, import structured records into PostgreSQL, validate destination, then change only approved routes.'
    if($Plan.ContainsKey('transitionKind')){
        $cutoverText=switch($Plan.transitionKind){
            ManagedMove {'Keep the central PostgreSQL database unchanged. Fence the managed source in durable maintenance, transfer only declared managed files, archive parked destination files, verify the selected host, then change only approved routes. Never replay a legacy importer.'}
            ManagedDeploy {'Stop the current owned process, select the staged release, preserve shared files and central PostgreSQL data, then verify runtime identity, readiness, and routes.'}
            FirstInstall {'Initialize the separately approved PostgreSQL database, validate a restored backup, provision runtime secrets, activate the staged release, then verify runtime identity, readiness, and routes.'}
            default {$cutoverText}
        }
    }
    $validationSection=''
    if($Plan.ContainsKey('validationEvidence')){
        $validationSection='<h2>Local validation evidence</h2><ul>'+(($Plan.validationEvidence|ForEach-Object{'<li>'+(& $encode $_)+'</li>'})-join '')+'</ul>'
    }
    $sizingSection=''
    if($Plan.ContainsKey('sourceSizing')){
        $sizingSection='<h2>Source metadata sizing</h2><p>'+(& $encode $Plan.sourceSizing.files)+' files, '+(& $encode $Plan.sourceSizing.bytes)+' bytes inventoried. Required source declarations found: '+(& $encode $Plan.sourceSizing.complete)+'. Legacy snapshot/checkpoint reserve: '+(& $encode $Plan.sourceSizing.minimumFreeBytes)+' bytes.</p><p>Metadata only. Row counts, final post-stop hashes, PostgreSQL storage growth, and database/archive consistency still require the reviewed export/import procedure.</p>'
    }
    if($Plan.ContainsKey('hostSnapshot') -and $Plan.hostSnapshot.ContainsKey('freeBytes')){
        $sizingSection+='<p>Destination hardware UUID: <code>'+(& $encode $Plan.hostSnapshot.identity)+'</code>. Free bytes at the read-only host snapshot: '+(& $encode $Plan.hostSnapshot.freeBytes)+'.</p>'
    }
    $status = if($Result){& $encode $Result.status}else{'Awaiting operator review. No production changes performed.'}
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$app deployment review</title><style>body{overflow-wrap:anywhere}</style>
<style>:root{color-scheme:dark;--bg:#0b0e16;--panel:#141a28;--fg:#e7ecf5;--muted:#a7b3c8;--line:#303a50;--accent:#a5a7ff}:root[data-theme=light]{color-scheme:light;--bg:#f4f6fb;--panel:#fff;--fg:#182238;--muted:#53627a;--line:#cbd3e1;--accent:#4338ca}*{box-sizing:border-box}body{margin:auto;max-width:1150px;padding:30px;font:15px/1.6 'Segoe UI',sans-serif;background:var(--bg);color:var(--fg);border-top:5px solid #818cf8}h1{font-size:32px}h2{margin-top:30px}button{float:right;background:var(--panel);color:var(--fg);border:1px solid var(--line);padding:10px;cursor:pointer}.card{border:1px solid var(--line);padding:20px;background:var(--panel);margin:16px 0}.muted{color:var(--muted)}code{font:12px Consolas,monospace;overflow-wrap:anywhere}.table{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13px}td,th{text-align:left;padding:12px;border-bottom:1px solid var(--line)}li{margin:8px 0}a{color:var(--accent)}@media(max-width:600px){body{padding:16px}h1{font-size:25px}}</style></head><body>
<button id="theme" type="button">Change theme</button><p class="muted">SolutionDeploy / production change review</p><h1>$app : $(& $encode $Plan.operation)</h1>
<div class="card"><strong>$status</strong><p>Environment: $(& $encode $Plan.environment) &middot; Target: $(& $encode $Plan.target.host) / $(& $encode $Plan.target.address)<br>Current placement: $(& $encode $Plan.observedHost)<br>Generated $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')) (local)</p></div>
<h2>Pinned inputs</h2><p>Plan <code>$(& $encode $Plan.id)</code><br>Approval digest <code>$(& $encode $Plan.planHash)</code><br>Commit <code>$(& $encode $Plan.sourceCommit)</code><br>Manifest <code>$(& $encode $Plan.manifestHash)</code><br>Environment <code>$(& $encode $Plan.environmentHash)</code><br>Release <code>$(& $encode $Plan.releaseId)</code></p>
<h2>Execution gates</h2><ul>$gates</ul>$databaseSection$validationSection$sizingSection<h2>Owned routes</h2><ul>$routes</ul><h2>Source export declaration</h2><div class="table"><table><thead><tr><th>Kind</th><th>Source path</th><th>Frozen export path</th><th>Required</th></tr></thead><tbody>$stateRows</tbody></table></div>
<h2>Task Scheduler</h2><p>All created tasks belong under <code>\JimlerTech\</code>: <code>SolutionDeploy-Executor</code> and <code>SolutionDeploy-$app</code>. Application launchers redirect both streams and exit; actual-server windowless/reboot acceptance remains required.</p>
<h2>Cutover and rollback</h2><p>$cutoverText Preserve one authoritative host. After destination writes, PostgreSQL is authoritative. Returning to the old SQLite/JSON source requires reviewed reverse conversion. A code rollback requires a PostgreSQL-capable release compatible with the current database schema.</p>
<p>No secrets are included. Unknowns block execution. Review each app migration before continuing to the next.</p><p id="storage" role="status"></p>
<script>const r=document.documentElement,m=matchMedia('(prefers-color-scheme:light)');let t=null;try{t=localStorage.getItem('solutiondeploy-theme')}catch(e){document.getElementById('storage').textContent='Theme persistence unavailable.'}function set(v){r.dataset.theme=v;document.getElementById('theme').textContent=v==='dark'?'Use light theme':'Use dark theme'}set(t==='light'||t==='dark'?t:m.matches?'light':'dark');document.getElementById('theme').onclick=()=>{t=r.dataset.theme==='dark'?'light':'dark';set(t);try{localStorage.setItem('solutiondeploy-theme',t)}catch(e){document.getElementById('storage').textContent='Theme persistence unavailable.'}};m.onchange=e=>{if(t!=='dark'&&t!=='light')set(e.matches?'light':'dark')};</script></body></html>
"@
    [IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($Path)))) | Out-Null
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),$html,[Text.UTF8Encoding]::new($false))
    if ($Open) { Start-Process -FilePath ([IO.Path]::GetFullPath($Path)) }
    [IO.Path]::GetFullPath($Path)
}

Export-ModuleMember -Function Get-Sha256Text,Read-DeploymentJson,Read-OptionalDeploymentText,Read-OptionalRemoteRecord,Write-DeploymentJson,Set-DeploymentProgressPath,Write-DeploymentProgress,Resolve-OwnedPath,Assert-Identifier,Get-DeploymentLock,Get-Manifest,Get-DeploymentEnvironment,Invoke-DeploymentCommand,Get-HostSnapshot,Get-PlanDigest,ConvertTo-CanonicalJson,New-DeploymentPlan,Assert-DeploymentApproval,Assert-PlanInputs,Get-ReleaseInventory,Test-ReleaseInventory,Expand-TrustedRelease,New-StagedRelease,Set-ActiveRelease,Repair-ReleaseSwitch,Get-RollbackDecision,Export-DeploymentReport
