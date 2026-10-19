#requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.psm1') -DisableNameChecking

function Get-StateInventory {
    param([Parameter(Mandatory)][hashtable]$Manifest, [string]$SourceRoot=$Manifest.source.root,
        [string]$SourceHost)
    $files = [Collections.Generic.List[object]]::new()
    $directories = [Collections.Generic.List[string]]::new()
    $missing = [Collections.Generic.List[string]]::new()
    foreach ($state in $Manifest.state) {
        $source = if ([IO.Path]::IsPathFullyQualified($state.source)) { $state.source } else { Resolve-OwnedPath $SourceRoot $state.source }
        if($SourceHost){
            if($SourceHost -notmatch '^[a-zA-Z0-9-]+$' -or $source -notmatch '^[A-Z]:\\'){throw 'Remote source inventory requires an explicit host and a local source drive path.'}
            $source='\\'+$SourceHost+'\'+$source.Substring(0,1)+'$'+$source.Substring(2)
        }
        if (-not (Test-Path -LiteralPath $source)) {
            if ($state.required) { $missing.Add($state.target) }
            continue
        }
        $item = Get-Item -LiteralPath $source -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'State inventory cannot follow a reparse point.' }
        if ($state.kind -eq 'directory') {
            if (-not $item.PSIsContainer) { throw 'Declared state directory is a file.' }
            $directories.Add($state.target)
            $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($source)
            while ($stack.Count) {
                foreach ($child in Get-ChildItem -LiteralPath $stack.Pop() -Force) {
                    if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'State directory contains a reparse point.' }
                    if ($child.PSIsContainer) { $stack.Push($child.FullName) }
                    else {
                        $relative = [IO.Path]::GetRelativePath($source,$child.FullName)
                        $files.Add(@{source=$child.FullName;target=($state.target+'\'+$relative);kind='file';bytes=$child.Length;sha256=$null})
                    }
                }
            }
        } else {
            if ($item.PSIsContainer) { throw 'Declared state file is a directory.' }
            $files.Add(@{source=$source;target=$state.target;kind=$state.kind;bytes=$item.Length;sha256=$null})
            if ($state.kind -eq 'sqlite') {
                # WAL is sizing input only. Export uses SQLite backup, never raw-main-file copying.
                $wal = $source + '-wal'
                if (Test-Path -LiteralPath $wal) { $files.Add(@{source=$wal;target=$null;kind='sizing-only';bytes=(Get-Item -LiteralPath $wal).Length;sha256=$null}) }
            }
        }
    }
    $targets = @($files | Where-Object target | ForEach-Object { $_.target })
    if (@($targets | Select-Object -Unique).Count -ne $targets.Count) { throw 'Two state declarations map to the same target file.' }
    $bytes = 0L
    foreach ($file in $files) { $bytes += $file.bytes }
    @{files=$files.ToArray();directories=$directories.ToArray();missingRequired=$missing.ToArray();totalBytes=[long]$bytes;minimumFreeBytes=([long]$bytes*3 + 5GB);complete=($missing.Count -eq 0)}
}

function Assert-SourceFence {
    param([Parameter(Mandatory)][hashtable]$Manifest,[Parameter(Mandatory)][hashtable]$Fence,
        [Parameter(Mandatory)][string]$OperationId,[hashtable]$ReadOnlyChild)
    if ($Fence.operationId -ne $OperationId -or $Fence.host -ine $Manifest.source.host -or
        $Fence.writersStopped -ne $true -or $Fence.restartPathsDisabled -ne $true) { throw 'Source fence does not match the approved migration.' }
    $age=[DateTimeOffset]::Now - [DateTimeOffset]::Parse($Fence.verifiedLocal)
    if ($age -gt [TimeSpan]::FromMinutes(5) -or $age -lt [TimeSpan]::Zero) { throw 'Source fence is stale or in the future; reverify source immediately before transfer.' }
    if (-not $Fence.ContainsKey('sourceProcessId') -or $Fence.sourceProcessId -lt 1) { throw 'Source fence must identify the original source writer process.' }
    if ($env:COMPUTERNAME -ine $Manifest.source.host) { throw 'Source fence must be reverified by the protected executor on the source host.' }
    if (Get-Process -Id $Fence.sourceProcessId -ErrorAction SilentlyContinue) { throw 'The original source writer PID is still present or has been reused; reverify the fence.' }
    if (-not $Fence.ContainsKey('writerInventoryReviewed') -or $Fence.writerInventoryReviewed -ne $true) { throw 'A complete reviewed writer inventory, including backup and command-line writers, is required.' }
    $taskPath=if($Manifest.source.ContainsKey('managed') -and $Manifest.source.managed){'\JimlerTech\'}else{'\'}
    $tasks=@(Get-ScheduledTask -TaskPath $taskPath -ErrorAction Stop)
    foreach ($name in $Manifest.source.tasks) {
        $matches=@($tasks | Where-Object TaskName -eq $name)
        if ($matches.Count -ne 1 -or $matches[0].State -ne 'Disabled') { throw "Source restart path is enabled or ambiguous: $name" }
    }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Manifest.launch.port -ErrorAction SilentlyContinue)
    if ($listeners.Count) { throw 'The source application port still has a listener.' }
    $root = if($Manifest.source.ContainsKey('managed') -and $Manifest.source.managed){Split-Path -Parent $Manifest.source.root}else{$Manifest.source.root}
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='python.exe' OR Name='pythonw.exe' OR Name='pwsh.exe' OR Name='powershell.exe'" -OperationTimeoutSec 5 |
        Where-Object {
            $processCommand=$_.CommandLine
            if($ReadOnlyChild -and $_.ParentProcessId -eq $ReadOnlyChild.parentProcessId -and
                $_.ExecutablePath -ieq $ReadOnlyChild.executable -and
                $processCommand -match ('^(?:"'+[regex]::Escape($ReadOnlyChild.executable)+'"|'+[regex]::Escape($ReadOnlyChild.executable)+')\s+(?:"'+[regex]::Escape($ReadOnlyChild.scriptPath)+'"|'+[regex]::Escape($ReadOnlyChild.scriptPath)+')\s+--source\s+')){
                return $false
            }
            $_.CommandLine -and ($_.CommandLine.IndexOf($root,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ($Fence.ContainsKey('writerCommandLines') -and $processCommand -in $Fence.writerCommandLines) -or
            ($Fence.ContainsKey('writerCommandPattern') -and $processCommand -match $Fence.writerCommandPattern))
        })
    if ($processes.Count) { throw 'A source application process still exists.' }
}

function Start-SourceFenceMonitor {
    param([hashtable]$Manifest,[hashtable]$Fence,[string]$OperationId,[hashtable]$ReadOnlyChild)
    $state=[hashtable]::Synchronized(@{lastVerified=[Environment]::TickCount64;error=$null})
    $cancel=[Threading.CancellationTokenSource]::new()
    $shell=[PowerShell]::Create()
    $null=$shell.AddScript({
        param($ModulePath,$Manifest,$Fence,$OperationId,$State,$Cancel,$ReadOnlyChild)
        $ErrorActionPreference='Stop'
        try {
            Import-Module $ModulePath -DisableNameChecking
            while(-not $Cancel.IsCancellationRequested){
                Assert-SourceFence $Manifest $Fence $OperationId -ReadOnlyChild $ReadOnlyChild
                $State.lastVerified=[Environment]::TickCount64
                if($Cancel.Token.WaitHandle.WaitOne(2000)){break}
            }
        } catch { $State.error=$_.Exception.Message; throw }
    }).AddArgument($MyInvocation.MyCommand.Module.Path).AddArgument($Manifest).AddArgument($Fence).AddArgument($OperationId).AddArgument($state).AddArgument($cancel).AddArgument($ReadOnlyChild)
    try { @{shell=$shell;pending=$shell.BeginInvoke();state=$state;cancel=$cancel} }
    catch { $shell.Dispose();$cancel.Dispose();throw }
}

function Assert-SourceFenceMonitor {
    param([hashtable]$Monitor)
    if($Monitor.state.error){throw "Continuous source fence failed: $($Monitor.state.error)"}
    if($Monitor.pending.IsCompleted -or [Environment]::TickCount64-$Monitor.state.lastVerified -gt 10000){
        throw 'Continuous source fence is unavailable or older than ten seconds.'
    }
}

function Stop-SourceFenceMonitor {
    param([hashtable]$Monitor)
    $Monitor.cancel.Cancel()
    try {
        if(-not $Monitor.pending.AsyncWaitHandle.WaitOne(10000)){
            $Monitor.shell.Stop()
            throw 'Continuous source fence did not stop within ten seconds.'
        }
        $null=$Monitor.shell.EndInvoke($Monitor.pending)
    } finally { $Monitor.shell.Dispose();$Monitor.cancel.Dispose() }
}

function Get-SqliteSourceHashes {
    param([Parameter(Mandatory)][string]$Path)
    $hashes=@{}
    foreach($suffix in @('','-wal','-shm','-journal')){
        $file=$Path+$suffix
        $key=if($suffix){$suffix}else{'main'}
        $hashes[$key]=if(Test-Path -LiteralPath $file){(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()}else{$null}
    }
    $hashes
}

function Export-FrozenState {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][hashtable]$Fence,
        [Parameter(Mandatory)][string]$Destination,[string]$PythonPath,
        [string]$ReviewedSnapshotSHA256)
    if($Plan.ContainsKey('transferManifest')){$Plan=@{}+$Plan;$Plan.manifest=$Plan.transferManifest}
    Assert-SourceFence $Plan.manifest $Fence $Plan.id
    $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\sqlite_snapshot.py'
    if(@($Plan.manifest.state|Where-Object kind -eq sqlite).Count){
        if(-not $PythonPath -or (Get-FileHash -LiteralPath $script).Hash.ToLowerInvariant() -ne $ReviewedSnapshotSHA256){throw 'SQLite export requires the independently reviewed snapshot script and Python executable.'}
    }
    if (Test-Path -LiteralPath $Destination) { throw 'Export directory must be new. An interrupted export needs review before retry.' }
    $inventory = Get-StateInventory $Plan.manifest
    if (-not $inventory.complete) { throw 'Required source state is missing.' }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $records = [Collections.Generic.List[object]]::new()
    $monitor=Start-SourceFenceMonitor $Plan.manifest $Fence $Plan.id -ReadOnlyChild @{
        parentProcessId=$PID;executable=$PythonPath;scriptPath=$script
    }
    try {
    foreach ($file in $inventory.files) {
        if ($file.kind -eq 'sizing-only') { continue }
        Assert-SourceFenceMonitor $monitor
        $target = Resolve-OwnedPath $Destination $file.target
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        if ($file.kind -eq 'sqlite') {
            $sourceHashes=Get-SqliteSourceHashes $file.source
            $dbFence = @{} + $Fence; $dbFence.sourcePath = [IO.Path]::GetFullPath($file.source)
            $fencePath = Join-Path $Destination ('snapshot-fence-' + (Get-Sha256Text $file.target).Substring(0,16) + '.json')
            Write-DeploymentJson $fencePath $dbFence
            $fenceHash = (Get-FileHash -LiteralPath $fencePath).Hash.ToLowerInvariant()
            $raw = Invoke-DeploymentCommand $PythonPath @($script,'--source',$file.source,'--destination',$target,'--root',$Destination,'--fence',$fencePath,'--fence-sha256',$fenceHash,'--operation',$Plan.id) $Destination -Capture
            $snapshot = $raw | ConvertFrom-Json -AsHashtable
            if ($snapshot.integrity -ne 'ok') { throw 'SQLite export did not pass integrity validation.' }
            $afterHashes=Get-SqliteSourceHashes $file.source
            foreach($key in @('main','-wal','-journal')){
                if($sourceHashes[$key] -ne $afterHashes[$key]){throw 'Source database changed around the snapshot.'}
            }
            if(($null -eq $sourceHashes['-shm']) -ne ($null -eq $afterHashes['-shm'])){throw 'Source shared-memory presence changed.'}
        } else {
            [IO.File]::Copy($file.source,$target,$false)
            if ((Get-FileHash -LiteralPath $file.source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw 'Source changed during final transfer.' }
        }
        $record=@{target=$file.target;kind=$file.kind;bytes=(Get-Item -LiteralPath $target).Length;sha256=(Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant()}
        if($file.kind -eq 'sqlite'){$record.snapshot=$snapshot;$record.sourceHashes=$afterHashes}
        $records.Add($record)
    }
    Assert-SourceFence $Plan.manifest $Fence $Plan.id
    Assert-SourceFenceMonitor $monitor
    } finally { Stop-SourceFenceMonitor $monitor }
    $proof = @{planHash=$Plan.planHash;operationId=$Plan.id;sourceHost=$Plan.manifest.source.host;stateDeclarationSHA256=(Get-Sha256Text (ConvertTo-CanonicalJson $Plan.manifest.state));fence=$Fence;directories=$inventory.directories;files=$records.ToArray();exportedLocal=(Get-Date).ToString('o')}
    Write-DeploymentJson (Join-Path $Destination 'transfer.json') $proof
    $proof
}

function Import-FrozenState {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][string]$ExportDirectory,
        [Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$ApprovedTransferSHA256)
    if($Plan.ContainsKey('transferManifest')){$Plan=@{}+$Plan;$Plan.manifest=$Plan.transferManifest}
    $proofPath = Join-Path $ExportDirectory 'transfer.json'
    if ((Get-FileHash -LiteralPath $proofPath).Hash.ToLowerInvariant() -ne $ApprovedTransferSHA256) { throw 'Transfer record is not the reviewed snapshot.' }
    $proof = Read-DeploymentJson $proofPath
    if ($proof.planHash -ne $Plan.planHash -or $proof.operationId -ne $Plan.id -or $proof.sourceHost -ine $Plan.observedHost) { throw 'Transfer provenance differs from the approved plan.' }
    if ($proof.stateDeclarationSHA256 -ne (Get-Sha256Text (ConvertTo-CanonicalJson $Plan.manifest.state))) { throw 'Transfer state declaration differs from the approved manifest.' }
    if (-not (Test-Path -LiteralPath (Join-Path $AppRoot 'state\maintenance.json'))) { throw 'State import requires maintenance mode.' }
    $authorityPath = Join-Path $AppRoot 'state\authority.json'
    if (Test-Path -LiteralPath $authorityPath) {
        $authority = Read-DeploymentJson $authorityPath
        if ($authority.targetMayHaveWritten) { throw 'Target has prior authority. Review its parked filesystem state before importing; automatic overwrite is forbidden.' }
    }
    $targets = @{}
    foreach ($file in $proof.files) {
        $input = Resolve-OwnedPath $ExportDirectory $file.target
        $target = Resolve-OwnedPath (Join-Path $AppRoot 'shared') $file.target
        if ($targets.ContainsKey($target)) { throw 'Transfer contains duplicate output paths.' }
        $targets[$target] = $true
        if ((Get-FileHash -LiteralPath $input).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'Transfer payload hash mismatch.' }
        if (Test-Path -LiteralPath $target) { throw 'State already exists. Review interrupted import rather than overwriting state.' }
        if ($file.target -notmatch '^(data|secrets|backups|logs)\\') { throw 'Transfer target is outside durable shared state.' }
        $declarations=@($Plan.manifest.state | Where-Object { $_.target -eq $file.target -or ($_.kind -eq 'directory' -and $file.target.StartsWith($_.target+'\',[StringComparison]::OrdinalIgnoreCase)) })
        if($declarations.Count -ne 1){throw 'Transfer file has no unique manifest declaration.'}
        if($declarations[0].kind -ne 'directory' -and $declarations[0].kind -ne $file.kind){throw 'Transfer kind differs from the state declaration.'}
        if($file.kind -eq 'sqlite' -and ($file.snapshot.integrity -ne 'ok' -or $file.snapshot.sha256 -ne $file.sha256)){throw 'SQLite payload has no validated backup-API snapshot.'}
    }
    foreach($required in $Plan.manifest.state | Where-Object required){
        if($required.kind -eq 'directory'){
            if($required.target -notin $proof.directories){throw 'A required state directory is missing from the export.'}
        } elseif(@($proof.files | Where-Object target -eq $required.target).Count -ne 1){throw 'A required state file is missing from the export.'}
    }
    foreach($directory in $proof.directories){
        if(@($Plan.manifest.state | Where-Object { $_.kind -eq 'directory' -and $_.target -eq $directory }).Count -ne 1){throw 'Export contains an undeclared directory.'}
        [IO.Directory]::CreateDirectory((Resolve-OwnedPath (Join-Path $AppRoot 'shared') $directory)) | Out-Null
    }
    foreach ($file in $proof.files) {
        $input = Resolve-OwnedPath $ExportDirectory $file.target
        $target = Resolve-OwnedPath (Join-Path $AppRoot 'shared') $file.target
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        [IO.File]::Copy($input,$target,$false)
        if ((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'Imported state hash mismatch.' }
    }
    Write-DeploymentJson $authorityPath @{operationId=$Plan.id;source=$Plan.observedHost;targetMayHaveWritten=$false;transferHash=$ApprovedTransferSHA256}
    $proof
}

function Prepare-ManagedStateImport {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][string]$AppRoot)
    if($Plan.transitionKind -ne 'ManagedMove'){throw 'Only managed host moves can archive parked filesystem state.'}
    if(-not (Test-Path -LiteralPath (Join-Path $AppRoot 'state\maintenance.json'))){throw 'Archiving parked state requires maintenance.'}
    $journalPath=Join-Path $AppRoot ('state\managed-import-'+$Plan.id+'.json')
    if(Test-Path -LiteralPath $journalPath){throw 'Managed file import was already attempted. Inspect its journal before retrying.'}
    $moves=@()
    foreach($item in $Plan.transferManifest.state){
        $target=Resolve-OwnedPath (Join-Path $AppRoot 'shared') $item.target
        if(Test-Path -LiteralPath $target){
            $backup=Resolve-OwnedPath (Join-Path $AppRoot 'shared\backups') ("host-moves\$($Plan.id)\"+$item.target)
            if(Test-Path -LiteralPath $backup){throw 'Parked-state backup already exists.'}
            $moves+=@{source=$target;backup=$backup;kind=$item.kind}
        }
    }
    Write-DeploymentJson $journalPath @{status='Archiving';operationId=$Plan.id;moves=$moves}
    foreach($move in $moves){
        [IO.Directory]::CreateDirectory((Split-Path -Parent $move.backup))|Out-Null
        if($move.kind -eq 'directory'){[IO.Directory]::Move($move.source,$move.backup)}
        else{[IO.File]::Move($move.source,$move.backup)}
    }
    Write-DeploymentJson (Join-Path $AppRoot 'state\authority.json') @{operationId=$Plan.id;targetMayHaveWritten=$false;databasePreserved=$true;parkedFilesJournal=$journalPath}
    Write-DeploymentJson $journalPath @{status='Archived';operationId=$Plan.id;moves=$moves}
}

function Assert-PreparedState {
    param([Parameter(Mandatory)][hashtable]$Plan,[Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$ApprovedReceiptSHA256)
    $receiptPath=Join-Path $AppRoot 'state\prepared-cutover.json'
    if((Get-FileHash -LiteralPath $receiptPath).Hash.ToLowerInvariant() -ne $ApprovedReceiptSHA256){throw 'Prepared cutover receipt differs from approval.'}
    $receipt=Read-DeploymentJson $receiptPath
    if($receipt.status -ne 'Prepared' -or $receipt.planHash -ne $Plan.planHash -or $receipt.operationId -ne $Plan.id -or
        $receipt.releaseId -ne $Plan.releaseId){throw 'Prepared cutover belongs to another plan or phase.'}
    if(-not (Test-Path -LiteralPath (Join-Path $AppRoot 'state\maintenance.json')) -or
        (Test-Path -LiteralPath (Join-Path $AppRoot 'shared\run\process.json'))){throw 'Prepared state must remain stopped in maintenance.'}
    $authority=Read-DeploymentJson (Join-Path $AppRoot 'state\authority.json')
    if($authority.targetMayHaveWritten -or $authority.operationId -ne $Plan.id -or $authority.transferHash -ne $receipt.transferSHA256){
        throw 'Prepared filesystem authority changed.'
    }
    $proofPath=Join-Path $AppRoot 'state\prepared-transfer.json'
    if((Get-FileHash -LiteralPath $proofPath).Hash.ToLowerInvariant() -ne $receipt.transferSHA256){throw 'Prepared transfer proof changed.'}
    $proof=Read-DeploymentJson $proofPath
    $manifest=if($Plan.ContainsKey('transferManifest')){$Plan.transferManifest}else{$Plan.manifest}
    if($proof.planHash -ne $Plan.planHash -or $proof.operationId -ne $Plan.id -or $proof.sourceHost -ine $Plan.observedHost -or
        $proof.stateDeclarationSHA256 -ne (Get-Sha256Text (ConvertTo-CanonicalJson $manifest.state))){throw 'Prepared provenance changed.'}
    foreach($file in $proof.files){
        $path=Resolve-OwnedPath (Join-Path $AppRoot 'shared') $file.target
        if((Get-Item -LiteralPath $path).Length -ne $file.bytes -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ne $file.sha256){
            throw 'Prepared file changed after import.'
        }
    }
    foreach($declaration in $manifest.state | Where-Object kind -eq directory){
        $directory=Resolve-OwnedPath (Join-Path $AppRoot 'shared') $declaration.target
        if(Test-Path -LiteralPath $directory){
            $actual=@(Get-ChildItem -LiteralPath $directory -File -Recurse -Force)
            $expected=@($proof.files | Where-Object { $_.target.StartsWith($declaration.target+'\',[StringComparison]::OrdinalIgnoreCase) })
            if($actual.Count -ne $expected.Count){throw 'Prepared directory contains extra or missing files.'}
            foreach($item in Get-ChildItem -LiteralPath $directory -Recurse -Force){
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Prepared directory contains a reparse point.'}
            }
        } elseif($declaration.required){throw 'Prepared directory is missing.'}
    }
    $receipt
}

function Assert-TransferEntryName {
    param([string]$Name)
    if([string]::IsNullOrEmpty($Name) -or $Name.Length -gt 400 -or $Name -match '[\x00-\x1f\\:*?"<>|]' -or
        $Name.StartsWith('/') -or $Name.EndsWith('/')){throw 'Transfer archive entry name is unsafe.'}
    foreach($segment in $Name.Split('/')){
        if($segment -in @('','.','..') -or $segment -match '[. ]$' -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$'){throw 'Transfer archive entry name is unsafe.'}
    }
}

function Get-TransferArchiveLayout {
    param([Parameter(Mandatory)][hashtable]$Proof)
    if(-not $Proof.ContainsKey('files') -or $null -eq $Proof['files']){throw 'Transfer proof does not declare files.'}
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null=$names.Add('transfer.json')
    $layout=[Collections.Generic.List[object]]::new()
    foreach($file in @($Proof.files)){
        if($file -isnot [hashtable] -or $file['target'] -isnot [string] -or $file['target'].Contains('/') -or
            $file['sha256'] -isnot [string] -or $file['sha256'] -cnotmatch '^[a-f0-9]{64}$' -or
            ($file['bytes'] -isnot [long] -and $file['bytes'] -isnot [int]) -or $file['bytes'] -lt 0){throw 'Transfer proof file record is malformed.'}
        $name=$file.target.Replace('\','/')
        Assert-TransferEntryName $name
        if(-not $names.Add($name)){throw 'Transfer proof declares duplicate files.'}
        $layout.Add(@{name=$name;target=$file.target;bytes=[long]$file.bytes;sha256=$file.sha256})
    }
    ,$layout.ToArray()
}

function Copy-BoundedStream {
    param([Parameter(Mandatory)][IO.Stream]$Source,[IO.Stream]$Output,[Parameter(Mandatory)][long]$Bytes)
    $hasher=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try{
        $buffer=[byte[]]::new(1MB);$total=0L
        while(($read=$Source.Read($buffer,0,$buffer.Length)) -gt 0){
            $total+=$read
            if($total -gt $Bytes){throw 'Transfer content expands beyond its declared length.'}
            $hasher.AppendData($buffer,0,$read)
            if($Output){$Output.Write($buffer,0,$read)}
        }
        if($total -ne $Bytes){throw 'Transfer content length differs from the proof.'}
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }finally{$hasher.Dispose()}
}

function ConvertFrom-TransferProofBytes {
    param([byte[]]$Bytes)
    $offset=if($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF){3}else{0}
    $proof=[Text.Encoding]::UTF8.GetString($Bytes,$offset,$Bytes.Length-$offset)|ConvertFrom-Json -AsHashtable -DateKind String
    if($proof -isnot [hashtable]){throw 'Transfer proof is not an object.'}
    $proof
}

function Open-TransferArchive {
    # Validates the archive digest, every entry name/type/length and the exact proof before any caller writes.
    param([Parameter(Mandatory)][IO.Stream]$Stream,[Parameter(Mandatory)][string]$ApprovedTransferSHA256,
        [Parameter(Mandatory)][string]$ApprovedArchiveSHA256)
    foreach($value in @($ApprovedTransferSHA256,$ApprovedArchiveSHA256)){
        if($value -cnotmatch '^[a-f0-9]{64}$'){throw 'Transfer archive approval requires exact lowercase SHA-256 values.'}
    }
    $Stream.Position=0
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Stream)).ToLowerInvariant() -ne $ApprovedArchiveSHA256){
        throw 'Transfer archive differs from the approved transferArchiveSHA256.'
    }
    $Stream.Position=0
    $zip=[IO.Compression.ZipArchive]::new($Stream,[IO.Compression.ZipArchiveMode]::Read,$true)
    try{
        $entries=[hashtable]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in $zip.Entries){
            Assert-TransferEntryName $entry.FullName
            if($entries.ContainsKey($entry.FullName)){throw 'Transfer archive contains duplicate entries.'}
            $attributes=[long]$entry.ExternalAttributes -band 0xFFFFFFFFL
            $unixType=($attributes -shr 16) -band 0xF000
            if(($unixType -ne 0 -and $unixType -ne 0x8000) -or ($attributes -band 0x410)){throw 'Transfer archive entries must be regular files.'}
            $entries[$entry.FullName]=$entry
        }
        $proofEntry=$entries['transfer.json']
        if(-not $proofEntry -or $proofEntry.FullName -cne 'transfer.json' -or $proofEntry.Length -gt 64MB){
            throw 'Transfer archive must contain one bounded root transfer.json.'
        }
        $memory=[IO.MemoryStream]::new()
        $source=$proofEntry.Open()
        try{$proofHash=Copy-BoundedStream $source $memory $proofEntry.Length}finally{$source.Dispose()}
        if($proofHash -ne $ApprovedTransferSHA256){throw 'Archived transfer proof differs from the approved transferSHA256.'}
        $proofBytes=$memory.ToArray()
        $proof=ConvertFrom-TransferProofBytes $proofBytes
        $layout=Get-TransferArchiveLayout $proof
        if($entries.Count -ne $layout.Count+1){throw 'Transfer archive has extra or missing entries.'}
        $declared=[long]$proofBytes.Length
        foreach($item in $layout){
            $entry=$entries[$item.name]
            if(-not $entry -or $entry.FullName -cne $item.name){throw 'Transfer archive is missing a declared file.'}
            if($entry.Length -ne $item.bytes){throw 'Transfer archive entry length differs from the proof.'}
            $declared+=$item.bytes
        }
        @{zip=$zip;entries=$entries;proof=$proof;proofBytes=$proofBytes;layout=$layout;declaredBytes=$declared;archiveSHA256=$ApprovedArchiveSHA256}
    }catch{$zip.Dispose();throw}
}

function Test-TransferArchive {
    param([Parameter(Mandatory)][string]$ArchivePath,[Parameter(Mandatory)][string]$ApprovedTransferSHA256,
        [Parameter(Mandatory)][string]$ApprovedArchiveSHA256,[switch]$VerifyContent)
    $stream=[IO.File]::Open($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $archive=Open-TransferArchive $stream $ApprovedTransferSHA256 $ApprovedArchiveSHA256
        try{
            if($VerifyContent){
                foreach($item in $archive.layout){
                    $source=$archive.entries[$item.name].Open()
                    try{$hash=Copy-BoundedStream $source $null $item.bytes}finally{$source.Dispose()}
                    if($hash -ne $item.sha256){throw 'Archived transfer file differs from the proof.'}
                }
            }
            $archive.proof
        }finally{$archive.zip.Dispose()}
    }finally{$stream.Dispose()}
}

function Expand-TransferArchive {
    param([Parameter(Mandatory)][string]$ArchivePath,[Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ApprovedTransferSHA256,[Parameter(Mandatory)][string]$ApprovedArchiveSHA256)
    $Destination=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $parent=Split-Path -Parent $Destination
    if(-not (Test-Path -LiteralPath $parent -PathType Container)){throw 'Transfer extraction parent must already exist.'}
    $null=Resolve-OwnedPath $parent (Split-Path -Leaf $Destination)
    if(Test-Path -LiteralPath $Destination){throw 'Transfer extraction destination must be new.'}
    $stream=[IO.File]::Open($ArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $archive=Open-TransferArchive $stream $ApprovedTransferSHA256 $ApprovedArchiveSHA256
        try{
            [IO.Directory]::CreateDirectory($Destination)|Out-Null
            foreach($item in $archive.layout){
                $to=Resolve-OwnedPath $Destination $item.target
                if(Test-Path -LiteralPath $to){throw 'Transfer extraction would overwrite an existing path.'}
                [IO.Directory]::CreateDirectory((Split-Path -Parent $to))|Out-Null
                $null=Resolve-OwnedPath $Destination $item.target
                $output=[IO.File]::Open($to,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{
                    $source=$archive.entries[$item.name].Open()
                    try{$hash=Copy-BoundedStream $source $output $item.bytes}finally{$source.Dispose()}
                    $output.Flush($true)
                }finally{$output.Dispose()}
                if($hash -ne $item.sha256){throw 'Extracted transfer file differs from the proof.'}
            }
            $proofPath=Join-Path $Destination 'transfer.json'
            $output=[IO.File]::Open($proofPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$output.Write($archive.proofBytes,0,$archive.proofBytes.Length);$output.Flush($true)}finally{$output.Dispose()}
            if((Get-FileHash -LiteralPath $proofPath).Hash.ToLowerInvariant() -ne $ApprovedTransferSHA256){throw 'Extracted transfer proof differs from approval.'}
            $archive.proof
        }finally{$archive.zip.Dispose()}
    }finally{$stream.Dispose()}
}

function New-TransferArchive {
    param([Parameter(Mandatory)][string]$ExportDirectory,[Parameter(Mandatory)][string]$ApprovedTransferSHA256,
        [Parameter(Mandatory)][string]$OutputRoot,[Parameter(Mandatory)][string]$ArchiveName,
        [ValidateSet('Fastest','Optimal','SmallestSize')][string]$CompressionLevel='Optimal')
    if($ApprovedTransferSHA256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Archive creation requires the exact approved transferSHA256.'}
    if($ArchiveName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.zip$'){throw 'Archive name must be a simple .zip file name.'}
    $export=[IO.Path]::GetFullPath($ExportDirectory).TrimEnd('\')
    $root=[IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
    foreach($directory in @($export,$root)){
        if(-not (Test-Path -LiteralPath $directory -PathType Container)){throw 'Export directory and protected output root must already exist.'}
        if((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Archive input/output roots cannot be reparse points.'}
    }
    if($root -ieq $export -or $root.StartsWith($export+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'The archive cannot be written inside the frozen export.'}
    $archivePath=Resolve-OwnedPath $root $ArchiveName
    if(Test-Path -LiteralPath $archivePath){throw 'Transfer archive already exists; outputs are create-only.'}
    $proofBytes=[IO.File]::ReadAllBytes((Resolve-OwnedPath $export 'transfer.json'))
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($proofBytes)).ToLowerInvariant() -ne $ApprovedTransferSHA256){
        throw 'Export transfer.json differs from the approved transferSHA256.'
    }
    $layout=Get-TransferArchiveLayout (ConvertFrom-TransferProofBytes $proofBytes)
    $level=[IO.Compression.CompressionLevel]$CompressionLevel
    $created=$false;$complete=$false
    try{
        $output=[IO.File]::Open($archivePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $created=$true
        try{
            $zip=[IO.Compression.ZipArchive]::new($output,[IO.Compression.ZipArchiveMode]::Create,$true)
            try{
                $entryStream=$zip.CreateEntry('transfer.json',$level).Open()
                try{$entryStream.Write($proofBytes,0,$proofBytes.Length)}finally{$entryStream.Dispose()}
                foreach($item in $layout){
                    $from=Resolve-OwnedPath $export $item.target
                    $info=Get-Item -LiteralPath $from -Force
                    if($info.PSIsContainer -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $info.Length -ne $item.bytes){
                        throw 'Export file differs from its proof record.'
                    }
                    $source=[IO.File]::Open($from,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                    try{
                        $entryStream=$zip.CreateEntry($item.name,$level).Open()
                        try{$hash=Copy-BoundedStream $source $entryStream $item.bytes}finally{$entryStream.Dispose()}
                    }finally{$source.Dispose()}
                    if($hash -ne $item.sha256){throw 'Export file content differs from the proof.'}
                }
            }finally{$zip.Dispose()}
            $output.Flush($true)
        }finally{$output.Dispose()}
        $archiveSHA256=(Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant()
        $proof=Test-TransferArchive $archivePath $ApprovedTransferSHA256 $archiveSHA256 -VerifyContent
        $complete=$true
    }finally{
        if($created -and -not $complete -and [IO.File]::Exists($archivePath)){[IO.File]::Delete($archivePath)}
    }
    $declared=[long]$proofBytes.Length
    foreach($item in $layout){$declared+=$item.bytes}
    @{archivePath=$archivePath;archiveSHA256=$archiveSHA256;transferSHA256=$ApprovedTransferSHA256;operationId=$proof['operationId']
        archiveBytes=(Get-Item -LiteralPath $archivePath).Length;declaredBytes=$declared;files=$layout.Count;compressionLevel=$CompressionLevel}
}
Export-ModuleMember -Function Get-StateInventory,Assert-SourceFence,Start-SourceFenceMonitor,Assert-SourceFenceMonitor,Stop-SourceFenceMonitor,Export-FrozenState,Import-FrozenState,Prepare-ManagedStateImport,Assert-PreparedState,New-TransferArchive,Test-TransferArchive,Expand-TransferArchive
