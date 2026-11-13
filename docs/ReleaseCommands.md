# Release commands: master list

Use this page whenever someone asks to deploy a solution. It gives the exact
release command for every app and component, how long it should take, and
what must be true before you call it done. [Production deployments](Deployment.md)
explains how each procedure works.

`tests\ReleaseCommands.Tests.ps1` fails when this list and
`environments\releases.json` disagree. Update both together.

## Before you run anything

All deployment and maintenance access to `jimbrownhome1` uses key-only SSH to
`jimbrownhome1.local` on the LAN. Install Windows OpenSSH clients locally. The host
must already have its SSH server, LAN-only firewall rule, local maintenance
administrator and authorized key configured. Entra accounts cannot authenticate
to Windows OpenSSH. The default account is `sd-maintenance`; override it with
`$env:SOLUTION_DEPLOY_SSH_USER`. Set `$env:SOLUTION_DEPLOY_SSH_KEY` to an existing
private-key path when the SSH agent/default key is insufficient. Verify the
server's host-key fingerprint independently and install it in `known_hosts`
before running any command. Helpers require `BatchMode=yes`,
`StrictHostKeyChecking=yes` and public-key authentication; they never accept a
new host key or fall back to passwords, SMB or DCOM.

The remote shell is `C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe`.
Remote commands run in one PowerShell session over SSH per host, opened on first
use and reused for the rest of the process, so each call takes about 0.1 s
instead of a new 3 to 10 s connection. The host's `sshd_config` needs
`Subsystem powershell C:/ProgramData/SolutionDeploy/runtime/powershell/7/pwsh.exe -sshs -NoLogo -NoProfile`.
A broken session is reopened before the next command. A session that ends while
a command runs is reported as an unknown outcome and never retried automatically.
Deployment locks keep their own SSH process for the life of the lease; it passes
the destination and command as separate arguments and invokes PowerShell 7 with
the `&` call operator, because Windows OpenSSH's default shell is PowerShell 7.
SCP uses SFTP with each Windows drive path passed as one argument, including
spaces. The release commands and consent flags below are unchanged.

1. Commit and push in the app repo. Release reads the repo at `..\<app>`
   relative to this repo (the `source` in `releases.json`), not your current
   directory. That checkout must be clean, and the commit must be on an origin
   branch.
2. Database-altering changes need the independent model review first. Release
   never runs migrations; changed SQL blocks hand-placed, pinned-job and Fit Track
   releases unless the file is in `appliedDatabaseInputs`.
3. Check the shared executor is idle (controller apps only, see below).
4. Run one release at a time. Never start a second release while one is running.

Every `Deploy.ps1` release uses the same consent flags:

```powershell
-ApproveRelease -ApprovalReason '<what the user asked for>' -DatabaseChangesReviewed
```

`-Target jimbrownhome1` is required on every `Deploy.ps1` call. `-Commit` defaults to `HEAD`
of the app checkout; pass `origin/main` or a full SHA to be explicit.

## The list

For every row except `web-bookmarks` tampermonkey, prefix the flags with
`& C:\Files\Dev\main\solution-deploy\Deploy.ps1 -Action Release -Target jimbrownhome1`
and append the consent flags above. The tampermonkey row is a complete command
on its own: run it as written, with no prefix and no consent flags.

| App               | Component             | Add these flags                                                                         | Procedure   | Expected time             | Downtime                       |
| ----------------- | --------------------- | --------------------------------------------------------------------------------------- | ----------- | ------------------------- | ------------------------------ |
| `ferry-tracker`   | all (web, capture)    | `-App ferry-tracker -TailscaleUrl https://jimbrownhome1.tail8ad282.ts.net:8787`         | controller  | 9 to 13 min               | about 2 min                    |
| `home-automation` | all (web, automation) | `-App home-automation -TailscaleUrl https://jimbrownhome1.tail8ad282.ts.net:8788`       | controller  | 9 to 13 min               | about 2 min                    |
| `site-dock`       | all (web)             | `-App site-dock`                                                                        | controller  | 9 to 10 min               | about 2 min                    |
| `team-scoreboard` | all (web)             | `-App team-scoreboard`                                                                  | controller  | 9 to 10 min               | about 2 min                    |
| `the-workbench`   | all (web)             | `-App the-workbench`                                                                    | controller  | 9 to 10 min               | about 2 min                    |
| `fit-track`       | web                   | `-App fit-track -Component web`                                                         | fit-track   | about 5 min               | stop and restart, not measured |
| `fit-track`       | upload-watcher        | `-App fit-track -Component upload-watcher`                                              | fit-track   | about 30 s                | watcher only                   |
| `web-bookmarks`   | web                   | `-App web-bookmarks` (defaults to web)                                                  | hand-placed | about 1 min               | about 30 s                     |
| `web-bookmarks`   | tampermonkey          | Not `Deploy.ps1`. In the web-bookmarks repo: `.\tampermonkey\Publish.ps1 -Commit <sha>` | external    | under 1 min               | none                           |
| `plex`            | web                   | `-App plex`                                                                             | hand-placed | about 30 s                | about 20 s                     |
| `work-log`        | web                   | `-App work-log`                                                                         | hand-placed | about 30 s                | about 20 s                     |
| `web-inventory`   | web                   | `-App web-inventory`                                                                    | hand-placed | about 1 min               | about 30 s                     |
| `web-options`     | web                   | `-App web-options -Component web`                                                       | hand-placed | about 4 min               | about 30 s                     |
| `web-options`     | collector             | `-App web-options -Component collector`                                                 | pinned-job  | under 1 min plus next run | none                           |
| `web-portfolio`   | web                   | `-App web-portfolio -Component web`                                                     | hand-placed | about 6 min               | about 30 s                     |
| `web-portfolio`   | stock-collector       | `-App web-portfolio -Component stock-collector`                                         | pinned-job  | under 1 min plus next run | none                           |
| `solution-deploy` | directory             | `-App solution-deploy -Component directory`                                             | directory   | under 1 min               | about 10 s                     |
| `solution-deploy` | collector-status      | `-App solution-deploy -Component collector-status` (same as directory)                  | directory   | under 1 min               | about 10 s                     |
| `solution-deploy` | collector-monitor     | `-App solution-deploy -Component collector-monitor`                                     | file-set    | about 1 min               | none                           |
| `solution-deploy` | lan-proxy             | `-App solution-deploy -Component lan-proxy`                                             | file-set    | under 30 s                | a few seconds (LAN only)       |
| `solution-deploy` | postgres-backup       | `-App solution-deploy -Component postgres-backup`                                       | file-set    | under 30 s                | none                           |
| `solution-deploy` | finance-launcher      | `-App solution-deploy -Component finance-launcher`                                      | file-set    | about 1 min               | Web Portfolio + Web Options    |
| `ride-and-lift`   | web                   | Not releasable from Git. Manual OneDrive update                                         | manual      |                           |                                |
| `pgweb`           | binary                | Not releasable from Git. Manual binary update                                           | manual      |                           |                                |

Rules the table encodes:

- Controller apps (Ferry Tracker, Home Automation, Site Dock, Team Scoreboard,
  The Workbench) reject `-Component`. They always release everything.
- Web Options and Web Portfolio have no default component. Leaving out
  `-Component` releases web and the collector together. Pass `-Component web`
  for a site change.
- Every Web Options and Web Portfolio component, plus `solution-deploy`
  `finance-launcher` (it restarts both), is blocked Monday to Friday 9:30 to
  16:00 Eastern (6:30 to 13:00 Pacific). Release after the close. Add
  `-AllowMarketHours` only when the user explicitly asks to deploy during market
  hours. Market holidays are still blocked; use the override then too.
- `solution-deploy` always needs `-Component`.
- Fit Track without `-Component` releases whichever of web and upload-watcher
  changed. A changed `Register-UploadWatcherTask.ps1` stops the release for a
  manual re-registration.
- `-ApprovedManifestSHA256 <hash>` is for controller apps only, when a commit
  changes the `build` key of `deploy\application.json`. See "Slim Node releases"
  in [Production deployments](Deployment.md).
- `-ApprovedPsqlSHA256 <hash>` is for controller apps only, on the first release of
  each app after a PostgreSQL update replaces `psql.exe`. The release error prints the
  new hash. That release records it, so later releases need no flag. Follow
  "After a PostgreSQL update" in [PostgreSQL](PostgreSQL.md) first.
- Use 3 times the expected time as the abort threshold.

## Pass criteria

A release is done only when all of these hold:

1. The command returns `status` `Succeeded` or `NoChanges`. Controller apps also
   need `externalAcceptance` `Verified`.
2. Tailscale URL for the app answers (port from `site\sites.json`).
3. The Cloudflare hostname returns the Cloudflare Access login redirect. A public
   200 is a failure.
4. Solution Directory `/deployments.json` shows each changed component with the
   released full commit and a completion time matching the receipt, compared in
   milliseconds. A missing or stale record is an incomplete release.
5. Components you didn't select are unchanged (for example the collectors after a
   web-only release).

`NoChanges` means the deployed commit already matches. It writes no new record.

## Executor check (controller apps)

Controller releases go through the shared `SolutionDeploy-Executor` task. Run
this read-only check first. Go only when the task is `Ready`, no executor
process runs, and there is no pending operation or it has a `Succeeded` or
`Failed` result.

```powershell
Import-Module C:\Files\Dev\main\solution-deploy\src\SshTransport.psm1 -DisableNameChecking
Invoke-DeploymentSsh jimbrownhome1 {
    $root='C:\ProgramData\SolutionDeploy'
    $state=(Get-ScheduledTask -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-Executor).State
    $processes=@(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
        Where-Object CommandLine -match 'Invoke-HostExecutor').Count
    $lock='Free'
    if([IO.File]::Exists("$root\control\submission.lock")){
        try{$held=[IO.File]::Open("$root\control\submission.lock",'Open','ReadWrite','None');$held.Dispose()}
        catch{$lock='Held or unreadable'}
    }
    $pendingStatus='none'
    if(Test-Path "$root\control\pending.json"){
        $p=Get-Content "$root\control\pending.json" -Raw|ConvertFrom-Json
        if($p.operationId -notmatch '^[a-z0-9][a-z0-9-]{1,79}$'){throw 'Invalid pending operation.'}
        $request="$root\operations\$($p.operationId)\request.json"
        if((Get-FileHash $request).Hash.ToLowerInvariant() -ne $p.requestSHA256){throw 'Pending request hash differs.'}
        $q=Get-Content $request -Raw|ConvertFrom-Json
        $r="$root\operations\$($p.operationId)\result.json"
        $pendingStatus='NO RESULT'
        if(Test-Path $r){
            $result=Get-Content $r -Raw|ConvertFrom-Json
            if($q.operationId -ne $p.operationId -or $result.operationId -ne $p.operationId -or
                $result.planHash -ne $q.plan.planHash){throw 'Pending result differs from its request.'}
            $pendingStatus=$result.status
        }
    }
    @{taskState=[string]$state;executorProcesses=$processes;submissionLock=$lock;pendingStatus=$pendingStatus}
}
```

The other procedures don't use the executor. They share
`apps\solution-deploy\state\common-controller.lock`, so two of them can't run at
once.

Go only when `submissionLock` is `Free` as well. The controller holds native
exclusive file locks on the host through live SSH connections for the entire
submission, including its bounded wait. An unresolved pending request is never
replaced or submitted again.

## Maintenance transport

`scripts\Update-HostExecutor.ps1 -HostName jimbrownhome1` and
`scripts\Set-PostgresPasswordFile.ps1` use the same SSH helpers. Host-local
installers and task maintenance scripts run inside `Invoke-DeploymentSsh`, for
example after their existing review and approval:

```powershell
Invoke-DeploymentSsh jimbrownhome1 {
    & C:\Files\Dev\main\solution-deploy\scripts\Set-DeploymentPowerShellTasks.ps1 -WhatIf
}
```

Keep every installer's existing identity, digest and approval arguments. SSH
changes the transport, not its authorization. `jimbrownhome` remains explicitly
legacy LAN SMB/DCOM until its SSH configuration is approved. The PostgreSQL
off-host backup share on that older host remains unchanged.

### SSH smoke check

After server setup and independent host-key verification, run these read-only
checks from the controller checkout:

```powershell
Import-Module .\src\SshTransport.psm1 -Force -DisableNameChecking
Invoke-DeploymentSsh jimbrownhome1 {
    @{
        host=$env:COMPUTERNAME
        identity=(Get-CimInstance Win32_ComputerSystemProduct).UUID
        user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        powerShell=$PSVersionTable.PSVersion.ToString()
    }
}
$path=Get-DeploymentRemotePath jimbrownhome1 'C:\ProgramData\SolutionDeploy\control\installation.json'
Get-FileHash -LiteralPath $path
Get-Content -LiteralPath $path -Raw
$session=New-DeploymentSession jimbrownhome1
try{
    Get-ScheduledTask -CimSession $session -TaskPath '\JimlerTech\' -TaskName SolutionDeploy-Executor
}finally{Close-DeploymentSession $session}
```

Expect `jimbrownhome1`, hardware identity
`4B3D9000-B6D0-11EA-91A7-1B5B997B1500`, the local `sd-maintenance` account and
PowerShell 7. The `-CimSession` parameter above belongs to the shared transport
proxy; it runs a host-local task query through SSH. It never opens DCOM on this
host.

### Protected framework update

For the initial transport update, use `scripts\Update-Host.ps1` from a reviewed
staging tree. It checks the host identity, installed code baseline and new code
digest, takes submission and execution locks, retains rollback files and writes
a protected update result.

1. Run the executor check above. Wait for active work and inspect any unresolved
   pending operation before copying or updating.
2. Build the sorted `path`/`sha256` inventory of reviewed `.ps1`, `.psm1`, `.py`
   and `.json` files under `src`, `scripts` and `schemas`. Compute its digest with
   `Get-Sha256Text (ConvertTo-CanonicalJson $inventory)`, as the update script does.
   Capture the current protected `installation.json` code digest and task
   account/actions.
3. Through `Copy-DeploymentItem -Recurse`, stage those 3 directories beneath one
   unique `C:\ProgramData\SolutionDeploy\control\transport-updates\<id>` directory.
   Verify every staged file hash against the reviewed inventory. This is a
   staging tree, never an app runtime directory.
4. Through `Invoke-DeploymentSsh`, run that tree's `scripts\Update-Host.ps1` with
   the already approved values:

```powershell
Invoke-DeploymentSsh jimbrownhome1 {
    param($script,$identity,$installedDigest,$newDigest)
    & $script -Root 'C:\ProgramData\SolutionDeploy' `
        -ExpectedHostIdentity $identity `
        -ExpectedInstalledCodeSHA256 $installedDigest `
        -ExpectedCodeSHA256 $newDigest -ApproveUpdate -Confirm:$false
} @($stagedScript,$approvedIdentity,$approvedInstalledDigest,$approvedNewDigest)
```

5. Verify the updated protected inventory and every installed file hash, task
   account/actions and successful update receipt. Keep its rollback backup.
   Remove the staging tree after confirming no live task depends on it.
   Rerun the SSH smoke check and the executor check. This updates deployment
   code without deploying or restarting an application.

## When it gets stuck

- Every controller wait prints a heartbeat every 5 s. Two checks with no new
  step means stop waiting and diagnose.
- The controller stops after 5 minutes with no executor progress, and after 30
  minutes total.
- `NO RESULT` on the pending operation: wait for the running executor to finish.
  If nothing is running, inspect `operations\<id>` on the host. Never delete
  `pending.json` and never resubmit the same release.
- A deadline with no matching result is an unknown outcome. Check the app,
  `operations\<id>\result.json` and the app's `state` folder before doing
  anything else. `-Action Recover` applies only to a failed Deploy with
  conclusive pre-change evidence.
- Hand-placed releases spend 2 minutes in host `npm ci` before the stop (Web
  Options, Web Portfolio). That is normal.

## Errors caused by the wrong flags

| Message starts with                                               | Fix                                                                              |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `Controller releases retain their complete managed scope`         | Remove `-Component`.                                                             |
| `Manifest does not identify one private HTTPS origin`             | Add `-TailscaleUrl` from the table.                                              |
| `Shared host jobs require explicit -Component selection`          | Add `-Component` for `solution-deploy`.                                          |
| `Unknown component`                                               | Use a component name from the table.                                             |
| `... has a separate release procedure`                            | Tampermonkey: use `Publish.ps1` in the web-bookmarks repo.                       |
| `Release requires -ApproveRelease, a non-empty -ApprovalReason`   | Add all 3 consent flags.                                                         |
| `Release requires a clean committed source checkout`              | Commit or stash in `C:\Files\Dev\main\<app>`.                                    |
| `Release commit is not reachable from a fetched origin branch`    | Push first.                                                                      |
| `Non-controller releases support only the existing jimbrownhome1` | Use `-Target jimbrownhome1`.                                                     |
| `-ApprovedManifestSHA256 applies only to framework-managed apps`  | Remove it; it is for controller apps only.                                       |
| `PostgreSQL verifier changed since activation`                    | After a checked PostgreSQL update, rerun with the printed `-ApprovedPsqlSHA256`. |
| `... releases are blocked during US market hours`                 | Wait for 16:00 Eastern, or add `-AllowMarketHours` if the user asked for it.     |
| `Release consent must expire within 1 hour`                       | Drop `-ExpiresLocal` or set it within the next hour.                             |
