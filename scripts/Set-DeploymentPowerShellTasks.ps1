#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$Apply,
    [string[]]$TaskName,
    [hashtable]$CredentialFiles = @{}
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\PowerShellRuntime.psm1') -Force
$executable = Get-ManagedPowerShellPath
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Install and verify the deployment runtime first.' }
$root = 'C:\ProgramData\SolutionDeploy'
$runtimeRoot = Join-Path $root 'runtime\powershell'
$version = Split-Path -Leaf @((Get-Item -LiteralPath (Join-Path $runtimeRoot '7') -Force).Target)[0]
Test-ManagedPowerShell -Executable $executable -Version $version
$tasks = @(Get-ScheduledTask | Where-Object {
    $_.TaskPath -eq '\JimlerTech\' -and ($_.TaskName -like 'SolutionDeploy-*' -or $_.TaskName -eq 'PostgreSQL-Backup') -and
        (-not $TaskName -or $_.TaskName -in $TaskName)
})
foreach ($name in $TaskName) {
    if ($name -notin $tasks.TaskName) { throw "Task is missing or outside the migration scope: $name" }
}
$changes = @()
foreach ($task in $tasks) {
    foreach ($action in $task.Actions) {
        if ($action.Execute -match '(?i)\\pwsh\.exe$' -and $action.Execute -ine $executable) {
            if ($action.Execute -notmatch '^(?i)C:\\Program Files\\PowerShell\\7(?:\.\d+\.\d+)?\\pwsh\.exe$') {
                throw "Unrecognized PowerShell path on $($task.TaskName): $($action.Execute)"
            }
            $changes += $task
            break
        }
    }
}
$changes | Select-Object TaskPath, TaskName, @{ Name = 'NewExecutable'; Expression = { $executable } },
    @{ Name = 'RequiresCredential'; Expression = { $_.Principal.LogonType -eq 'Password' } }
if (-not $Apply -or -not $PSCmdlet.ShouldProcess("$($changes.Count) task definitions", 'Change only PowerShell executable paths; keep running processes')) { return }
$credentials = @{}
foreach ($task in $changes) {
    if ($task.Principal.LogonType -ne 'Password') { continue }
    $user = $task.Principal.UserId
    if ($credentials.ContainsKey($user)) { continue }
    if ($CredentialFiles.ContainsKey($user)) {
        $credential = Import-Clixml -LiteralPath $CredentialFiles[$user]
    } elseif ([Environment]::UserInteractive) {
        $credential = Get-Credential -UserName $user -Message "Existing password for $user. It is required once to update the task; it will not be saved to a file."
    } else {
        throw "Task $($task.TaskName) requires the existing $user credential. Supply its host-local DPAPI file with -CredentialFiles, or run interactively. No further tasks were changed."
    }
    if ($credential -isnot [pscredential]) { throw "No PSCredential supplied for $user." }
    $expected = (New-Object Security.Principal.NTAccount($user)).Translate([Security.Principal.SecurityIdentifier]).Value
    $actual = (New-Object Security.Principal.NTAccount($credential.UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
    if ($expected -ne $actual) { throw "Credential account does not match task account $user." }
    $credentials[$user] = $credential
}
$backup = Join-Path $root ('archives\powershell-tasks-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
[IO.Directory]::CreateDirectory($backup) | Out-Null
foreach ($task in $changes) {
    Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath |
        Set-Content -LiteralPath (Join-Path $backup ($task.TaskName + '.xml')) -Encoding UTF8
}
$installationPath = Join-Path $root 'control\installation.json'
if (Test-Path -LiteralPath $installationPath) { Copy-Item -LiteralPath $installationPath -Destination $backup }
foreach ($task in $changes) {
    [xml]$before = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
    foreach ($action in $task.Actions) {
        if ($action.Execute -match '(?i)\\pwsh\.exe$') { $action.Execute = $executable }
    }
    if ($task.Principal.LogonType -eq 'Password') {
        $credential = $credentials[$task.Principal.UserId]
        Set-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Action $task.Actions `
            -User $task.Principal.UserId -Password $credential.GetNetworkCredential().Password | Out-Null
    } else {
        Set-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Action $task.Actions | Out-Null
    }
    [xml]$after = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
    $ns = New-Object Xml.XmlNamespaceManager($before.NameTable)
    $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    foreach ($command in $before.SelectNodes('/t:Task/t:Actions/t:Exec/t:Command', $ns)) {
        if ($command.InnerText -match '(?i)\\pwsh\.exe$') { $command.InnerText = $executable }
    }
    # Task Scheduler can change its registration timestamp when updating actions.
    foreach ($document in @($before, $after)) {
        $manager = New-Object Xml.XmlNamespaceManager($document.NameTable)
        $manager.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        $date = $document.SelectSingleNode('/t:Task/t:RegistrationInfo/t:Date', $manager)
        if ($date) { $date.ParentNode.RemoveChild($date) | Out-Null }
    }
    if ($before.OuterXml -cne $after.OuterXml) { throw "Task changed beyond its executable path: $($task.TaskName). Backup: $backup" }
    Write-Host "Verified $($task.TaskPath)$($task.TaskName)"
}
$executor = Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'SolutionDeploy-Executor'
if ((Test-Path -LiteralPath $installationPath) -and $executor.Actions[0].Execute -ieq $executable) {
    $installation = Get-Content -LiteralPath $installationPath -Raw | ConvertFrom-Json
    $installation.powerShellPath = $executable
    $temporary = $installationPath + '.powershell-update'
    $installation | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding UTF8
    [IO.File]::Replace($temporary, $installationPath, (Join-Path $backup 'installation-replaced.json'))
    if ((Get-Content -LiteralPath $installationPath -Raw | ConvertFrom-Json).powerShellPath -cne $executable) {
        throw 'Executor PowerShell path read-back failed.'
    }
}
Write-Host "Task definitions updated without restarting workloads. Backups: $backup"
