#requires -Version 7.4
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ExpectedHostIdentity,
    [string]$PowerShellPath = (Join-Path $Root 'runtime\powershell\7\pwsh.exe'),
    [Parameter(Mandatory)][string]$ExpectedCodeSHA256,
    [switch]$ApproveProvisioning
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Deployment.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Lifecycle.psm1') -DisableNameChecking
if (-not $ApproveProvisioning) { throw 'Host provisioning requires explicit operator review and -ApproveProvisioning.' }
if ($Root -notmatch '^[A-Z]:\\ProgramData\\SolutionDeploy$') { throw 'Phase 1 host provisioning requires the reviewed dedicated ProgramData root.' }
$identity = (Get-CimInstance Win32_ComputerSystemProduct -Property UUID).UUID
if ($identity -ne $ExpectedHostIdentity) { throw 'Host hardware identity does not match the reviewed destination.' }
if (-not [IO.Path]::IsPathFullyQualified($PowerShellPath) -or -not (Test-Path -LiteralPath $PowerShellPath)) { throw 'PowerShell must be an installed absolute executable.' }
if ($PowerShellPath -match '(?i)\\current\\|\\shims\\') { throw 'Use an immutable PowerShell installation path.' }
$source = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath (Join-Path $source 'src'),(Join-Path $source 'scripts'),(Join-Path $source 'schemas') -File -Recurse |
    Where-Object Extension -in @('.ps1','.psm1','.py','.json') | Sort-Object FullName)
$inventory = @($files | ForEach-Object { @{path=[IO.Path]::GetRelativePath($source,$_.FullName);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()} })
$digest = Get-Sha256Text ($inventory | ConvertTo-Json -Depth 10 -Compress)
if ($digest -ne $ExpectedCodeSHA256) { throw "Reviewed executor code digest differs. Observed digest: $digest" }
if (-not $PSCmdlet.ShouldProcess("$env:COMPUTERNAME / $Root",'Provision protected SYSTEM deployment executor')) { return }
if (Test-Path -LiteralPath $Root) {
    $existing = @(Get-ChildItem -LiteralPath $Root -Force)
    $runtimeOnly = $existing.Count -eq 1 -and $existing[0].Name -eq 'runtime' -and
        -not ((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        $PowerShellPath -ieq (Join-Path $Root 'runtime\powershell\7\pwsh.exe')
    if (-not $runtimeOnly) { throw 'Deployment root already exists. Executor upgrades require a separate reviewed operation.' }
}
[IO.Directory]::CreateDirectory($Root) | Out-Null
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
    $principal = [Security.Principal.SecurityIdentifier]::new($sid)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $Root -AclObject $acl
foreach ($relative in @('control\framework','operations','apps')) { [IO.Directory]::CreateDirectory((Join-Path $Root $relative)) | Out-Null }
foreach ($file in $inventory) {
    $target = Resolve-OwnedPath (Join-Path $Root 'control\framework') $file.path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    [IO.File]::Copy((Join-Path $source $file.path),$target,$false)
    if ((Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'Installed executor file digest differs.' }
}
Write-DeploymentJson (Join-Path $Root 'control\installation.json') @{schemaVersion=1;root=$Root;identity=$identity;host=$env:COMPUTERNAME;codeSHA256=$digest;files=$inventory;powerShellPath=$PowerShellPath;installedLocal=(Get-Date).ToString('o')}
$executor = Join-Path $Root 'control\framework\scripts\Invoke-HostExecutor.ps1'
if ($Root.Contains('"') -or $executor.Contains('"')) { throw 'Invalid task path.' }
$action = New-ScheduledTaskAction -Execute $PowerShellPath -Argument "-NoLogo -NoProfile -NonInteractive -File `"$executor`" -Root `"$Root`"" -WorkingDirectory (Split-Path -Parent $executor)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Initialize-AppTaskFolder -TaskPath '\JimlerTech\'|Out-Null
Register-ScheduledTask -TaskName 'SolutionDeploy-Executor' -TaskPath '\JimlerTech\' -Action $action -Principal $principal -Settings $settings -Description 'Fixed protected SolutionDeploy operation dispatcher. No arbitrary commands.' -ErrorAction Stop | Out-Null
Get-ScheduledTask -TaskName 'SolutionDeploy-Executor' -TaskPath '\JimlerTech\' | Select-Object TaskName,TaskPath,State
