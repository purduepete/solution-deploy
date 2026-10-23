#Requires -Version 7.5
<#
.SYNOPSIS
Provisions one app's boot task: per-account ACLs under AppRoot and a scheduled task that runs the watchdog at
startup and on repeat as the dedicated account (stored password, no sign-in, no S4U, RunLevel Limited).

.DESCRIPTION
Run from an elevated PowerShell 7 terminal on the target host. Nothing changes without -ApproveProvisioning.
When -Credential is omitted the script prompts for it in the console; it never accepts a password string.
With -StartNow it starts the task once and waits for a verified, ready process.

.EXAMPLE
.\Install-AppTask.ps1 -AppId ferry-tracker -AppRoot C:\ProgramData\SolutionDeploy\apps\ferry-tracker `
    -ReleasePath C:\ProgramData\SolutionDeploy\apps\ferry-tracker\current `
    -ManifestPath C:\ProgramData\SolutionDeploy\apps\ferry-tracker\current\deploy\application.json `
    -AccountName sd-ferry -ApproveProvisioning
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{1,39}$')][string]$AppId,
    [Parameter(Mandatory)][string]$AppRoot,
    [Parameter(Mandatory)][string]$ReleasePath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$PowerShellPath = 'C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe',
    [pscredential]$Credential,
    [string]$AccountName,
    [string]$StagedReleasePath,
    [ValidateRange(1, 60)][int]$WatchdogIntervalMinutes = 5,
    [switch]$ApproveProvisioning,
    [switch]$StartNow,
    [ValidateRange(10, 600)][int]$StartTimeoutSeconds = 90
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\Lifecycle.psm1') -Force

if (-not $ApproveProvisioning) {
    throw 'This script changes ACLs and registers a scheduled task. Re-run with -ApproveProvisioning to approve.'
}
if ($StagedReleasePath -and $StartNow) { throw 'A first-install task starts at activation; omit -StartNow with -StagedReleasePath.' }
foreach ($pair in @(@('AppRoot', $AppRoot), @('ReleasePath', $ReleasePath), @('ManifestPath', $ManifestPath), @('PowerShellPath', $PowerShellPath))) {
    if (-not [IO.Path]::IsPathFullyQualified($pair[1])) { throw "$($pair[0]) must be an absolute path: $($pair[1])" }
}
if (-not (Test-Path -LiteralPath $AppRoot -PathType Container)) { throw "AppRoot does not exist: $AppRoot" }
if (-not $StagedReleasePath -and -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "ManifestPath does not exist: $ManifestPath" }

if (-not $Credential) {
    if (-not [Environment]::UserInteractive -or $Host.Name -ne 'ConsoleHost') {
        throw 'No -Credential given and this is not an interactive console. Run from a local terminal so the password is entered at a secure prompt.'
    }
    if (-not $AccountName) { throw 'Pass -AccountName (the dedicated account) or -Credential.' }
    $Credential = Get-Credential -UserName $AccountName -Message "Password for the $AppId service account. It is stored only in Task Scheduler."
    if (-not $Credential) { throw 'No credential entered.' }
}
elseif ($AccountName -and $Credential.UserName -ne $AccountName) {
    throw "Credential user '$($Credential.UserName)' does not match -AccountName '$AccountName'."
}

$staged = @{}
if ($StagedReleasePath) { $staged.StagedReleasePath = $StagedReleasePath }
$result = Install-AppBootTask -AppId $AppId -AppRoot $AppRoot -ReleasePath $ReleasePath -ManifestPath $ManifestPath `
    -PowerShellPath $PowerShellPath -Credential $Credential -ApproveProvisioning @staged `
    -WatchdogIntervalMinutes $WatchdogIntervalMinutes
$Credential = $null

if ($StartNow) {
    $manifest = Read-LifecycleManifest -Path $ManifestPath -AppRoot $AppRoot -ReleasePath $ReleasePath
    $RuntimePath = Get-ReleaseRuntimePath -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $manifest
    Start-ScheduledTask -TaskPath $result.TaskPath -TaskName $result.TaskName
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $status = $null
    while ($deadline.Elapsed.TotalSeconds -lt $StartTimeoutSeconds) {
        Start-Sleep -Seconds 2
        $status = Get-ManagedAppStatus -AppRoot $AppRoot -ReleasePath $ReleasePath -Manifest $manifest -RuntimePath $RuntimePath
        if ($status.Status -eq 'Running') { break }
    }
    if (-not $status -or $status.Status -ne 'Running') {
        throw "Task started, but no verified $AppId process appeared within $StartTimeoutSeconds s. Check shared\logs\watchdog.log and $AppId.err.log."
    }
    $launch = $manifest['launch']; $readiness = $manifest['readiness']
    $ready = Test-AppReadiness -Port ([int]$launch['port']) -Path $readiness['path'] -Expected $readiness['expected'] -TimeoutSeconds 30
    $result.Started = $ready.Ready
    $result | Add-Member -NotePropertyName Pid -NotePropertyValue $status.Pid
    $result | Add-Member -NotePropertyName Readiness -NotePropertyValue $ready.Reason
}
$result
