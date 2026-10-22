# Deployment PowerShell runtime

Deployment tasks use
`C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe`. The `7` directory
is an administrator-controlled junction to a private, verified release under
`versions`. The FitTrack upload watcher's windowless VBS launcher uses the same
executable. Desktop PowerShell, WindowsApps aliases, PATH and WinGet updates do
not control this runtime.

Updates are manual. You do not need to edit a shim or ask someone to repair
tasks after updating desktop PowerShell. The private runtime needs its own
security updates; it does not receive them from Windows Update.

## Update

On jimbrownhome1, open **64-bit Windows PowerShell as administrator** and run:

```powershell
powershell.exe -NoProfile -File C:\ProgramData\SolutionDeploy\runtime\powershell\management\scripts\Update-DeploymentPowerShell.ps1
```

Omit `-Version` to select the latest official stable PowerShell 7 release.
Add `-Version 7.6.7` to select a particular supported release. PowerShell 8 and
preview releases are rejected. A downgrade requires the rollback command below.

The command downloads the official Windows x64 ZIP, checks its SHA256 against
GitHub's release asset digest, checks Microsoft's executable and engine
signatures, and tests the runtime with Task Scheduler before selecting it.
An exclusive lock prevents simultaneous updates. Downloads have a 3-minute
timeout. A failed download or preflight leaves the active runtime unchanged.

Only the runtime junction changes. Task arguments, service accounts, triggers,
working directories and running applications stay unchanged. There is a brief
gap while renaming the two junctions; a task launch during that gap can fail
and needs its normal retry. A failure verifying the new fixed path restores
the previous junction. A power loss between the two renames can leave `7`
missing: rerun the updater with the desired `-Version`, or use `-Rollback`.
Inspect a leftover `pending` junction before retrying; the updater refuses to
guess how an interrupted switch should finish.

Existing PowerShell processes keep running from their original version.
New processes use the selected release. This command does not certify every
application's compatibility or restart active collectors. After an update,
check task results and both the Tailscale and Cloudflare access paths.

## Roll back

```powershell
powershell.exe -NoProfile -File C:\ProgramData\SolutionDeploy\runtime\powershell\management\scripts\Update-DeploymentPowerShell.ps1 -Rollback
```

This verifies and selects the retained previous version. It does not reverse
application or database changes. It affects new launches; already running
processes retain their loaded version.

Version folders and verification receipts are retained intentionally. Do not
delete a version while a process uses it, or while `7` or `previous` points at
it. The updater removes its download and failed staging folder automatically.

## Initial installation and existing tasks

Run `scripts\Update-DeploymentPowerShell.ps1 -Version 7.6.7` from the repository
in elevated Windows PowerShell on the host. Install the updater and its module
under `runtime\powershell\management\scripts` and `management\src`, respectively,
so the update command remains available independently of framework upgrades.

For an already provisioned host, preview then apply the path migration:

```powershell
.\scripts\Set-DeploymentPowerShellTasks.ps1
.\scripts\Set-DeploymentPowerShellTasks.ps1 -Apply -Confirm:$false
```

The migration changes only PowerShell executable paths in the `JimlerTech`
folder's `SolutionDeploy-*` tasks and `PostgreSQL-Backup`. It exports task XML
and executor configuration under `archives\powershell-tasks-<local timestamp>`,
compares task definitions after each change, and updates the executor's
`powerShellPath` setting. It does not run the backup or restart any task.
FitTrack's deployed VBS file must also match its source launcher.

Password-backed tasks require their existing account passwords once during
this initial migration. The script collects these through secure prompts before
changing any further task. Never put passwords in chat, command arguments or
files. To reuse an existing host-local DPAPI credential file, supply
`-CredentialFiles @{ 'service-account' = 'C:\protected\task-credential.dpapi.xml' }`
in the Windows account that originally encrypted it. The script checks that
the decrypted account matches the task. A `-TaskName` array can limit the
one-time migration to specific tasks. Future runtime updates do not need these
passwords because the task definitions stay unchanged.

On jimbrownhome1, nobody had the original `sd-ferry` and `sd-web-bookmarks`
passwords, so on 2026-10-22 both accounts got new random passwords and their
tasks were migrated. Each account runs only its own task. The credentials are
in `C:\ProgramData\SolutionDeploy\control\task-credentials\<account>.credential.xml`,
DPAPI-encrypted for `JimBrown` in a folder restricted to Administrators and
SYSTEM. Pass them with `-CredentialFiles` or import them with `Import-Clixml`
when reinstalling either app task.

Installers default to the fixed runtime path. An explicit `-PowerShellPath`
override is still available for separately managed hosts.
