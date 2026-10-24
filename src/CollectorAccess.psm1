Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CollectorTree {
    param([Parameter(Mandatory)][string]$Path, [switch]$Code, [string[]]$AllowedRuntimeJunction = @())
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($Code -or -not $AllowedRuntimeJunction -or
            $item.FullName -notin $AllowedRuntimeJunction -or $item.LinkType -ne 'Junction') {
            throw "Reparse path rejected: $Path"
        }
        $target = $item.ResolveLinkTarget($false)
        if ($null -eq $target -or $target -isnot [IO.DirectoryInfo] -or $target.FullName.StartsWith('\\')) {
            throw "Runtime site-packages junction target rejected: $Path"
        }
        $ancestor = $target
        while ($null -ne $ancestor) {
            if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Runtime junction target ancestor is another reparse path: $($ancestor.FullName)"
            }
            $ancestor = $ancestor.Parent
        }
        $null = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        $item
        # No nested junction allowance when checking the canonical target tree.
        Get-CollectorTree -Path $target.FullName
        return
    }
    if ($Code -and $item.Name -match '^\.?(secrets?|credentials?)(\.|$)|^\.env($|\.(?!example$))|^(config|settings)(\.(production|local))?\.json$|\.pgpass$|\.(pem|key|pfx|p12)$|password') {
        throw "Secret-like path rejected (contents not read): $Path"
    }
    # Reading every ACL before any grant catches denied/protected descendants.
    $null = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
    $item
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop) {
            Get-CollectorTree -Path $child.FullName -Code:$Code -AllowedRuntimeJunction $AllowedRuntimeJunction
        }
    }
}

function Assert-CollectorOutsideRelease {
    param([string]$ReleasePath, [string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Absolute path required: $Path" }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -eq $ReleasePath -or $full.StartsWith($ReleasePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Configuration and writable state must be outside the release.'
    }
}

function Assert-CollectorElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run collector access preflight elevated on the local host.'
    }
}

function Assert-CollectorAdminDirectory {
    param([string]$Path)
    $trustedSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0')
    try {
        $trustedSids += @(Get-LocalGroupMember -SID ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')) -ErrorAction Stop |
            ForEach-Object { $_.SID.Value })
    }
    catch { throw 'Cannot resolve local Administrators membership; control directory trust check failed closed.' }
    $item = Get-Item -LiteralPath $Path -Force
    $first = $true
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Control directory reparse path rejected: $($item.FullName)" }
        $acl = Get-Acl -LiteralPath $item.FullName
        foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($ace.AccessControlType -eq 'Allow' -and
                ($ace.FileSystemRights -band $(if ($first) { 0xD0156 } else { 0xD0040 })) -and
                $ace.IdentityReference.Value -notin $trustedSids -and
                -not ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) {
                throw "Control directory must be administrator-controlled: $($item.FullName)"
            }
        }
        $first = $false
        $item = $item.Parent
    }
}

function Invoke-CollectorTokenProbe {
    param([Parameter(Mandatory)][string]$ManifestPath)
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $result = @{ Success = $false; Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; Error = '' }
    try {
        if ($result.Sid -ne 'S-1-5-19') { throw 'Probe did not run as LOCAL SERVICE.' }
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class CollectorFileAccess {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
}
'@
        $paths = @($manifest.ReadFiles)
        $enumerated = 0
        foreach ($tree in $manifest.ReadTrees) {
            $paths += @(Get-CollectorTree -Path $tree -AllowedRuntimeJunction $manifest.AllowedRuntimeJunction | ForEach-Object {
                $enumerated++
                if ($enumerated % 100 -eq 0) {
                    "Enumerated $enumerated code/runtime paths" | Set-Content -LiteralPath $manifest.ProgressPath
                }
                $_.FullName
            })
        }
        $payloadPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $paths) { $null = $payloadPaths.Add($path) }
        $allPaths = [Collections.Generic.HashSet[string]]::new($payloadPaths, [StringComparer]::OrdinalIgnoreCase)
        foreach ($path in @($paths)) {
            $parent = [IO.Path]::GetDirectoryName($path.TrimEnd('\'))
            while ($parent) {
                $null = $allPaths.Add($parent)
                $parent = [IO.Path]::GetDirectoryName($parent.TrimEnd('\'))
            }
        }
        $checked = 0
        foreach ($path in $allPaths) {
            # OPEN_EXISTING requests access without writing, truncating or deleting.
            $rights = @(64, 65536, 262144, 524288)
            $flags = 0x02000000
            if ($payloadPaths.Contains($path)) {
                $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if (-not $item.PSIsContainer) {
                    $stream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
                    $stream.Dispose()
                }
                $rights = @(2, 4, 16, 256, 65536, 262144, 524288)
                if ($item.PSIsContainer) { $rights += 64 }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $flags = $flags -bor 0x00200000 }
            }
            foreach ($right in $rights) {
                $handle = [CollectorFileAccess]::CreateFile($path, $right, 7, [IntPtr]::Zero, 3, $flags, [IntPtr]::Zero)
                $writable = -not $handle.IsInvalid
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                $handle.Dispose()
                if ($writable) { throw "LOCAL SERVICE can modify code/config/runtime: $path" }
                if ($errorCode -ne 5) { throw "Cannot establish read-only access ($errorCode): $path" }
            }
            $checked++
            if ($checked % 100 -eq 0) {
                "Checked $checked of $($allPaths.Count) paths" | Set-Content -LiteralPath $manifest.ProgressPath
            }
        }
        foreach ($directory in $manifest.WriteDirectories) {
            $testFile = Join-Path $directory ("collector-access-" + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                $stream = [IO.File]::Open($testFile, 'CreateNew', 'Write', 'None')
                try { $stream.WriteByte(0) } finally { $stream.Dispose() }
            }
            finally { if ([IO.File]::Exists($testFile)) { [IO.File]::Delete($testFile) } }
        }
        if ($manifest.PythonPath) {
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $manifest.PythonPath
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.WorkingDirectory = $manifest.WorkingDirectory
            $start.ArgumentList.Add('-I')
            $start.ArgumentList.Add('-B')
            $start.ArgumentList.Add('-S')
            $start.ArgumentList.Add('-c')
            $start.ArgumentList.Add('import sys; assert sys.version_info.major == 3')
            $process = [Diagnostics.Process]::Start($start)
            try {
                if (-not $process.WaitForExit(20000)) { $process.Kill(); throw 'Isolated Python startup timed out.' }
                if ($process.ExitCode -ne 0) { throw 'Isolated Python startup failed.' }
            }
            finally { $process.Dispose() }
        }
        $result.Success = $true
    }
    catch { $result.Error = $_.Exception.Message }
    $pending = $manifest.ResultPath + '.pending'
    $result | ConvertTo-Json | Set-Content -LiteralPath $pending -Encoding utf8
    [IO.File]::Move($pending, $manifest.ResultPath)
}

function Invoke-CollectorAccessPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleasePath,
        [string]$PythonPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Alias('ReadPath')][string[]]$AdditionalReadFiles = @(),
        [string[]]$WritableDirectories = @(),
        [string]$PowerShellPath = 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe',
        [string]$ControlPath = 'C:\ProgramData\SolutionDeploy\control\collector-access',
        [ValidateRange(10, 300)][int]$TimeoutSeconds = 300
    )
    Assert-CollectorElevated
    foreach ($path in (@($ReleasePath, $PythonPath, $ConfigPath, $PowerShellPath, $ControlPath) | Where-Object { $_ })) {
        if (-not [IO.Path]::IsPathFullyQualified($path) -or $path.StartsWith('\\')) { throw 'Use absolute native local paths.' }
    }
    $root = [IO.Path]::GetFullPath($ReleasePath).TrimEnd('\')
    $ancestor = Get-Item -LiteralPath $root -Force
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release ancestors must not be reparse paths.' }
        $ancestor = $ancestor.Parent
    }
    Assert-CollectorOutsideRelease $root $ConfigPath
    foreach ($directory in $WritableDirectories) { Assert-CollectorOutsideRelease $root $directory }
    $postgresProperty = $null
    if ([IO.Path]::GetExtension($ConfigPath) -eq '.json') {
        try { $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
        catch { throw 'Protected configuration could not be read as JSON (contents withheld).' }
        if ($null -ne $configuration) { $postgresProperty = $configuration.PSObject.Properties['postgres'] }
    }
    if ($postgresProperty -and $postgresProperty.Value -match '(?:^|\s)passfile\s*=\s*(?:''([^'']*)''|"([^"]*)"|(\S+))') {
        $passfile = @($Matches[1], $Matches[2], $Matches[3]) | Where-Object { $_ }
        # libpq backslash escapes are removed when it parses connection values.
        $AdditionalReadFiles += ($passfile -replace '\\\\', '\')
    }
    foreach ($file in $AdditionalReadFiles) {
        if (-not [IO.Path]::IsPathFullyQualified($file) -or $file.StartsWith('\\')) { throw 'Read paths must be absolute native local paths.' }
    }
    $scanCount = 0
    $code = @(Get-CollectorTree -Path $root -Code | ForEach-Object {
        $scanCount++
        if ($scanCount % 100 -eq 0) { Write-Information "Collector preflight: inspected $scanCount code paths." -InformationAction Continue }
        $_
    })
    $runtimeTrees = @((Split-Path -Parent $PowerShellPath))
    $allowedRuntimeJunction = @()
    if ($PythonPath) {
        $pythonDirectory = Split-Path -Parent $PythonPath
        $venvRoot = Split-Path -Parent $pythonDirectory
        $venvConfig = Join-Path $venvRoot 'pyvenv.cfg'
        $runtimeTrees += $pythonDirectory
        if (Test-Path -LiteralPath $venvConfig) {
            $homeLine = @(Get-Content -LiteralPath $venvConfig | Where-Object { $_ -match '^home\s*=' })
            if ($homeLine.Count -ne 1) { throw 'Cannot identify venv base interpreter.' }
            $base = ($homeLine[0] -split '=', 2)[1].Trim()
            if (-not [IO.Path]::IsPathFullyQualified($base)) { throw 'Venv home must be absolute.' }
            if ($base -match '\\ScoopApps\\apps\\python314\\3\.14\.\d+$') {
                $allowedRuntimeJunction = @(
                    (Join-Path $base 'Lib\site-packages'),
                    (Join-Path $base 'Scripts')
                )
            }
            $runtimeTrees += @($venvRoot, $base)
        }
    }
    # Runtime's managed "7" junction is intentional; enumerate its resolved target.
    $runtimeTrees = @($runtimeTrees | ForEach-Object {
        $item = Get-Item -LiteralPath $_ -Force
        if ($item.LinkType) { $item.ResolveLinkTarget($true).FullName } else { $item.FullName }
    } | Sort-Object -Unique)
    foreach ($tree in $runtimeTrees) {
        Get-CollectorTree $tree -AllowedRuntimeJunction $allowedRuntimeJunction | ForEach-Object {
            $scanCount++
            if ($scanCount % 100 -eq 0) { Write-Information "Collector preflight: inspected $scanCount code/runtime paths." -InformationAction Continue }
        }
    }
    $null = Get-Item -LiteralPath $ConfigPath -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $ControlPath)) { New-Item -ItemType Directory -Path $ControlPath -Force | Out-Null }
    Assert-CollectorAdminDirectory $ControlPath
    $run = Join-Path $ControlPath ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $run | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-19')) {
        $rights = if ($sid -eq 'S-1-5-19') { 'ReadAndExecute' } else { 'FullControl' }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $run -AclObject $acl
    $output = New-Item -ItemType Directory -Path (Join-Path $run 'output')
    $outputAcl = Get-Acl $output.FullName
    $outputAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-19'), 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath $output.FullName -AclObject $outputAcl
    $snapshot = Join-Path $run 'original-acl.json'
    @($code | ForEach-Object {
        @{ Path = $_.FullName; Sddl = (Get-Acl -LiteralPath $_.FullName).Sddl }
    }) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $snapshot -Encoding utf8
    $probeModule = Join-Path $run 'CollectorAccess.psm1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $probeModule
    $taskName = 'SolutionDeploy-collector-access-' + [guid]::NewGuid().ToString('N')
    $registered = $false
    try {
        foreach ($item in @($code[0])) {
            $itemAcl = Get-Acl -LiteralPath $item.FullName
            $inheritance = 'ContainerInherit,ObjectInherit'
            $itemAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-5-19'), 'ReadAndExecute', $inheritance, 'None', 'Allow'))
            Set-Acl -LiteralPath $item.FullName -AclObject $itemAcl
        }
        $resultPath = Join-Path $output.FullName 'result.json'
        $manifestPath = Join-Path $run 'manifest.json'
        @{
            ReadFiles = @((@($ConfigPath, $PythonPath, $PowerShellPath, $probeModule) + $AdditionalReadFiles) | Where-Object { $_ })
            ReadTrees = @($root) + $runtimeTrees
            WriteDirectories = @($WritableDirectories)
            PythonPath = $PythonPath; WorkingDirectory = $run; ResultPath = $resultPath
            ProgressPath = (Join-Path $output.FullName 'progress.txt')
            AllowedRuntimeJunction = $allowedRuntimeJunction
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $modulePath = $probeModule.Replace("'", "''")
        $command = "Import-Module '$modulePath' -Force; Invoke-CollectorTokenProbe -ManifestPath '$($manifestPath.Replace("'", "''"))'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $action = New-ScheduledTaskAction -Execute $PowerShellPath -Argument "-NoProfile -NonInteractive -EncodedCommand $encoded" -WorkingDirectory $run
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds)
        Register-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
        $registered = $true
        $task = Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName
        $actualSid = $task.Principal.UserId
        if ($actualSid -ne 'S-1-5-19') {
            $actualSid = ([Security.Principal.NTAccount]::new($actualSid)).Translate([Security.Principal.SecurityIdentifier]).Value
        }
        if ($actualSid -ne 'S-1-5-19' -or $task.Principal.LogonType -ne 'ServiceAccount') { throw 'Probe principal read-back failed.' }
        $startedAt = Get-Date
        Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $nextHeartbeat = 5
        while (-not (Test-Path -LiteralPath $resultPath)) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'LOCAL SERVICE access probe timed out.' }
            if ($clock.Elapsed.TotalSeconds -ge $nextHeartbeat) {
                $progressPath = Join-Path $output.FullName 'progress.txt'
                $progress = if (Test-Path -LiteralPath $progressPath) { Get-Content -LiteralPath $progressPath -Raw } else { 'enumerating paths' }
                Write-Information "Collector LOCAL SERVICE probe: $([int]$clock.Elapsed.TotalSeconds)s, $progress" -InformationAction Continue
                $nextHeartbeat += 5
            }
            $info = Get-ScheduledTaskInfo -TaskPath '\JimlerTech\' -TaskName $taskName
            if ($info.LastRunTime -ge $startedAt.AddSeconds(-1) -and $info.LastTaskResult -notin @(0, 267009, 267011)) {
                throw "LOCAL SERVICE probe process failed, scheduler result $($info.LastTaskResult)."
            }
            Start-Sleep -Milliseconds 250
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if (-not $result.Success -or $result.Sid -ne 'S-1-5-19') { throw "LOCAL SERVICE access probe failed: $($result.Error)" }
        [pscustomobject]@{ Success = $true; Sid = $result.Sid; AclSnapshot = $snapshot }
    }
    catch {
        $failure = $_
        $diagnostics = Join-Path $run 'failure.json'
        @{ Success = $false; Error = $failure.Exception.Message; AclSnapshot = $snapshot } |
            ConvertTo-Json | Set-Content -LiteralPath $diagnostics -Encoding utf8
        if ($registered) { Stop-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -ErrorAction SilentlyContinue }
        Restore-CollectorAccess -SnapshotPath $snapshot
        throw "Collector access preflight failed: $($failure.Exception.Message) Diagnostics: $diagnostics"
    }
    finally {
        if ($registered) {
            Stop-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $taskName -Confirm:$false
        }
        Remove-Item -LiteralPath (Join-Path $run 'manifest.json') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $output.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restore-CollectorAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SnapshotPath)
    foreach ($entry in (Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json)) {
        $acl = Get-Acl -LiteralPath $entry.Path
        $acl.SetSecurityDescriptorSddlForm($entry.Sddl, [Security.AccessControl.AccessControlSections]::Access)
        Set-Acl -LiteralPath $entry.Path -AclObject $acl
    }
}

Export-ModuleMember -Function Invoke-CollectorAccessPreflight, Invoke-CollectorTokenProbe, Restore-CollectorAccess
