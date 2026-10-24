#Requires -Version 7.5
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Root = 'C:\ProgramData\SolutionDeploy\monitor',
    [string]$PowerShellPath = 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe',
    [string]$AlertScript = 'C:\ProgramData\JimlerTech\PostgreSQL\Send-BackupAlert.ps1'
)
$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathFullyQualified($Root)) { throw 'Monitor root must be an absolute path.' }
foreach ($path in @($PowerShellPath, $AlertScript)) {
    if (-not [IO.Path]::IsPathFullyQualified($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing absolute monitor dependency: $path"
    }
}
if (Test-Path -LiteralPath $Root) {
    if ((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Monitor root must not be a reparse point.'
    }
}
New-Item -ItemType Directory -Path $Root -Force | Out-Null
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
        'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
Set-Acl -LiteralPath $Root -AclObject $acl
foreach ($folder in @('scripts', 'src')) {
    $destination = Join-Path $Root $folder
    if ((Test-Path -LiteralPath $destination) -and
        ((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Monitor child must not be a reparse point: $destination"
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
}
foreach ($relative in @('scripts\Test-CollectorHealth.ps1', 'src\CollectorMonitor.psm1')) {
    $destination = Join-Path $Root $relative
    if ((Test-Path -LiteralPath $destination) -and
        ((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Monitor file must not be a reparse point: $destination"
    }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-CollectorHealth.ps1') -Destination (Join-Path $Root 'scripts\Test-CollectorHealth.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\src\CollectorMonitor.psm1') -Destination (Join-Path $Root 'src\CollectorMonitor.psm1') -Force
$action = New-ScheduledTaskAction -Execute $PowerShellPath -WorkingDirectory $Root -Argument (
    '-NoProfile -NonInteractive -File "' + (Join-Path $Root 'scripts\Test-CollectorHealth.ps1') +
    '" -StatePath "' + (Join-Path $Root 'state.json') + '" -AlertScript "' + $AlertScript + '"')
$triggers = @(
    New-ScheduledTaskTrigger -AtStartup
    New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
)
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds 50) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$name = 'SolutionDeploy-collector-monitor'
Register-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $name -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Description (
        'Host-level collector launch, schedule, snapshot and audit failure alerts. Independent of collector releases and Python; ' +
        'SYSTEM uses the existing machine-protected backup alert credentials. No database access.') -Force | Out-Null
Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName $name
[pscustomobject]@{ task = $name; root = $Root; started = $true }
