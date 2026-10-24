# Production deployments and new applications

`production` is the environment. Its registered application hosts are `jimbrownhome` (`192.168.2.11`) and the default, `jimbrownhome1` (`192.168.2.14`). Select either with `-Target`. PostgreSQL always stays on `jimbrownhome1`; moving an application preserves its existing central database.

The environment's `hosts` registry contains each host's private IPv4 address, dedicated root, and route profile. Add a future application host there and review its identity, infrastructure, and tunnel before using it. `defaultTarget` and the top-level `host`, `address`, and `root` aliases must describe the same registered default. Each application still needs a unique database allocation.

Plans distinguish `LegacyConversion`, `FirstInstall`, `ManagedDeploy`, and `ManagedMove`. Legacy conversion uses the original `state` declarations and the separately approved PostgreSQL importer. A managed move uses only `managedState`, with paths relative to the source's managed `shared` directory, and preserves the existing PostgreSQL data. It never replays the legacy importer.

## Routine same-host release

Treat "commit, push and deploy" as approval for the complete routine sequence.
Work in the application's development repository, review the change, commit and
push it, then invoke the shared controller below. Supply the explicit consent
flags from that request without asking for separate Stage, Preflight, Deploy or
Verify approvals. Database-changing work still needs the independent review
described below.

### One entry point, existing procedures

`Deploy.ps1 -Action Release` now routes registered apps to the existing protected
controller and other apps to a verified app-specific procedure. The
`environments\releases.json` inventory covers all 14 hosted sites and their
background components. It is separate from `production.json`: appearing in the
inventory does not grant placement authority or enable deployment.

| Apps/components                                                                                        | Current release support                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ferry Tracker, Home Automation, Site Dock, Team Scoreboard                                             | Existing complete controller sequence, unchanged                                                                                                                                                                          |
| Fit Track web (frontend, backend and in-process Strava sync)                                           | Full exact-commit release using the existing staged-release builder, graceful stop, junction activation and watchdog task                                                                                                 |
| Fit Track upload watcher                                                                               | Compare installed source and task configuration; preserve the separate copied tree and justified Google Drive logon task. Changed watcher code blocks automatic full-app selection until its update procedure is verified |
| Web Bookmarks, Plex, Work Log, Web Inventory, Web Portfolio, Web Options                               | Inventoried with live version evidence and explicit procedure blockers; no migration/provisioning scripts called                                                                                                          |
| Solution Directory, collector monitor/publisher, LAN proxy, PostgreSQL backup, shared finance launcher | Require explicit component selection; blocked until each installed baseline and publisher are verified                                                                                                                    |
| Ride and Lift, pgweb                                                                                   | Inventory-only OneDrive/binary distributions. Git commit releases rejected; remain private-only                                                                                                                           |

The access URLs and reserved Tailscale HTTPS ports stay in `site\sites.json`.
Task names, source locations, mutable paths and version evidence are recorded
in the release inventory. Shared finance launcher consumers are Web Portfolio
and Web Options; changing the template does not silently update either
installed per-app copy.

For Fit Track's first release, select the whole web component explicitly:

```powershell
& C:\Files\Dev\main\solution-deploy\Deploy.ps1 -Action Release `
    -App fit-track -Target jimbrownhome1 -Component web `
    -Commit HEAD -ApproveRelease -ApprovalReason 'Establish full web release baseline' `
    -DatabaseChangesReviewed
```

This is a full frontend/backend release, not a frontend-only copy. It establishes
an exact web baseline in `state\common-release.json` without pretending the old
mixed-version directory was a single commit. Later releases can omit
`-Component`: declared web paths are compared between that deployed commit and
the requested commit. Watcher files are compared separately, with line endings
normalized for the original copied tree. Selecting `web` never republishes the
watcher. Selecting an unchanged `upload-watcher` reports source verification
only and performs no upload. Changed watcher source is an explicit blocker,
not a successful skip.

The Fit Track procedure fetches origin, requires a clean source checkout and a
pushed immutable commit, exports it, builds the frontend locally, then prepares
a complete new release and Python virtual environment at their final host path.
Preparation happens while the current service remains available. The payload
contains the exact source archive plus that frontend build; source and payload
hashes are recorded separately. A first full release does not need a fabricated
prior commit.

Before downtime, it checks host identity, the current junction and active
metadata, installed application files, interpreter, boot task, watcher source
and watcher task configuration. The manifest and database inputs must match the
current installation. It executes no importer, schema migration or data-fix
script. The existing app's normal background writes resume when its watchdog
starts it.

Activation reuses `Stop-ManagedApp`, `Set-ActiveRelease` and the existing
dedicated-account scheduled task. No task is reinstalled or rescheduled.
Secrets, shared data and the watcher tree are not copied or changed. Runtime
success requires both process ownership and the JSON readiness probe; final
acceptance also requires Tailscale readiness and the public Cloudflare Access
redirect. The procedure changes no routes or authentication.

Local `releases\fit-track-<id>\release.json` under the output directory records
preparation, host phases, component results and external acceptance. Host
requests and phase results are retained in the app's `state\routine\<id>`
directory. The release directory contains its sealed file inventory. Failures
remain failed, even after activation; inspect the active junction, maintenance
flag and phase results before recovery. Old releases are retained. No automatic
rollback runs after possible application writes. `NoChanges` means source
comparison and access checks only; it is not a fresh runtime attestation.

Shared jobs use `-App solution-deploy -Component <name>`, for example
`collector-monitor` or `postgres-backup`. Unknown, unverified and distribution-only
routes fail before preparing or stopping an application. Existing controller
apps reject `-Component`, preserving their complete managed release scope.

### Existing controller sequence

After reviewing the application change, use one command from any working directory:

```powershell
& C:\Files\Dev\main\solution-deploy\Deploy.ps1 -Action Release `
    -App team-scoreboard -Environment production -Target jimbrownhome1 `
    -Commit HEAD -ApproveRelease -ApprovalReason 'Reviewed scoreboard display correction' `
    -DatabaseChangesReviewed
```

`-DatabaseChangesReviewed` declares that you reviewed the application code for database
writes and data fixes. Database-altering changes still require independent review and
the separate reviewed deployment procedure. Release performs no database import,
migration, restore or data fix. Starting the application can resume its ordinary writes.

Release is limited to an existing `ManagedDeploy` on the same host. The entire
application manifest and sealed database migration/schema inputs must match the active
release. The current routine verifier requires the application and database to stay
on the existing colocated host. New installations, host moves, changed database inputs and unresolved
placement authority require the existing reviewed actions.

The caller resolves `HEAD` or the supplied commit once, fetches origin and requires
that immutable commit to be reachable from an origin branch. The source checkout
must be clean. It obtains fixed runtime and PostgreSQL verifier paths from the
protected installation, sealed active release and successful prior activation
request. It checks their hashes and the prior runtime/schema verification. No
hand-written approval JSON or runtime overrides are needed.

Consent binds the app, environment, target, commit, reason, operator, exact artifact
and tool hashes, allowed actions and expiry into the saved plan digest. The default
expiry is 30 minutes; `-ExpiresLocal` can shorten it or set a time within 1 hour.
Input drift and expiry fail the run. Release never extends consent or rewrites the
plan to accept new inputs.

The sequence is Plan, Stage, protected Preflight, Deploy, protected Verify, then
external acceptance. Preflight checks the live schema, runtime role isolation,
endpoint and existing nightly backup validation. Its new read-only compatibility
evidence retains the backup's original dates. It runs before placement becomes
Pending and before the old application stops. The resulting evidence file and hash
are added to later approvals without changing the plan hash. The executor checks
them again before activation. Historical import parity or restore gates aren't
invented for a routine release.

Before staging and after protected verification, the controller checks Tailscale
HTTPS readiness against the manifest response and requires a Cloudflare Access
login redirect on the single public hostname. A public HTTP 200 doesn't satisfy
Access acceptance. The Tailscale origin is taken from the manifest's declared
`https://*.ts.net:<application-port>` origin. For applications without one, supply
`-TailscaleUrl https://<host>.<tailnet>.ts.net:<application-port>`.
Release doesn't change routes or Access policies.

Local records are under `.local\releases\<plan-id>` by default: the fixed plan,
per-action approvals and `release.json` with phase results and approval hashes.
Only a completed protected Verify and both final external checks produce
`status=Succeeded` and `externalAcceptance=Verified`. A failed external check leaves
the deployment marked incomplete even if the application has started.

Failures retain the records and don't trigger automatic rollback. Inspect the
protected operation journal and operation-scoped write-authority evidence first.
A proven preflight abort leaves the old deployment authoritative. An uncertain
start or possible application write requires operator recovery.

`-Action Recover` only reconciles a completed failed Deploy with conclusive
operation-scoped pre-mutation evidence and a verified running previous release.
Use its original saved plan and approval while that consent remains valid.
Missing evidence, maintenance, a changed junction or possible writes block this
action. It doesn't restart or roll back an application.

The host executor must contain the reviewed routine-release code before use.
An existing protected installation needs the separately reviewed host-update
procedure; rerunning the initial `Install-Host.ps1` installer won't update it.

Run the reviewed source copy of `Update-Host.ps1` locally on the selected target,
from a source tree outside `control\framework`:

```powershell
& .\scripts\Update-Host.ps1 -Root C:\ProgramData\SolutionDeploy `
    -ExpectedHostIdentity '<UUID>' `
    -ExpectedInstalledCodeSHA256 '<installation.codeSHA256>' `
    -ExpectedCodeSHA256 '<SHA-256 of canonical JSON for the reviewed src/scripts/schemas inventory>' `
    -ApproveUpdate -Confirm:$false
```

The updater takes submission and execution locks, checks the existing and new
inventories, backs up changed bytes and restores them if the update fails.
It doesn't restart applications. Retain its protected update receipt and backups.

The existing Plan, Stage, Deploy, Cutover, Verify and Rollback entry points retain
their separate approval flow.

### First measured routine release

Team Scoreboard completed the new command on 10/24/2026 at 00:07 local, using the
already-pushed commit `c32f625412d9a0460cbb0513b12a905113c5eb93`. Its protected
release was `c32f625412d9-dcb68ba3`, with Active placement and both access checks
passing.

| Phase                      | Elapsed |
| -------------------------- | ------- |
| Preparation                | 00:31   |
| Stage                      | 03:02   |
| Protected Preflight        | 02:55   |
| Deploy                     | 01:53   |
| Protected Verify           | 00:41   |
| Between-phase/final checks | 00:31   |
| Total                      | 09:32   |

The earlier 5–8 minute estimate was low. Use this measured result until more runs
provide a better estimate. These are command timings, not application downtime.

Validation found two preparation problems. Full old-release hashing over the
admin share was too slow, so the controller now reads protected metadata and the
executor still checks both full inventories locally before downtime. Host-update
inventory hashes now use canonical JSON because unordered JSON caused a
cross-process digest mismatch that correctly refused the update before copying.
Run the CLI directly: a PowerShell background-job test wrapper also timed out
during Git preparation before it submitted any protected operation.

## Migration feedback and reuse

Before each migration, record whether capture gaps are acceptable, whether the old
site must remain available during copying, the database destination, and the
completion budget. Carry these decisions through execution; do not silently
replace an accepted-gap migration with a stopped-source requirement.

After each migration:

1. Record estimated and actual times for preparation, copying, import, checks,
   and the website switch. Include failures and the user-visible downtime.
2. Fix repeatable problems in the shared scripts and add a regression test.
   Preserve tested commands and their prerequisites for the next application.
3. Before starting the next application, reuse the verified host, database,
   account, secret, startup and routing procedures. Check only what changed.
4. Report which fixes were reused and what remains application-specific. If the
   next migration repeats a known failure, stop and repair that shared step.

Ferry migration lesson: the user accepts capture gaps for these personal apps.
Keep the old site available while preparing a consistent snapshot and testing
the destination where supported. The existing fenced conversion procedure below
still requires a stopped source; an accepted-gap path must state that distinction
honestly and must never fabricate a stopped-writer receipt.

For personal applications other than webportfolio, data gaps and downtime are
acceptable unless the user changes that requirement. A completed, transactional
SQLite-to-PostgreSQL table-count and ordered-content comparison is the migration
data check. Comparing a restored third copy is a separate recovery test; do not
make it a prerequisite unless requested. Record the actual scope, including any
views or history queries that were not compared.

Use measured durations when estimating. Ferry's October 18 import and direct
comparison took about 3 minutes, its custom backup about 21 seconds, and its test
restore about 56 seconds. A configured timeout is an abort limit, not an estimate.
Define terms such as "restore validation" in plain language when first used.

Windows may return a local scheduled-task account with or without the host
prefix. Compare resolved account SIDs, as `Assert-AppBootTask` already does.
Check runtime read access before task registration; the account needs read and
execute on releases and framework code, without write access.

## Task Scheduler folder and windowless startup

Use the [managed deployment PowerShell runtime](PowerShellRuntime.md) for task
executables. Its fixed path survives desktop PowerShell updates. The runtime
has an explicit update command and retained previous releases.

All created tasks belong under **Task Scheduler Library > JimlerTech**:

- `\JimlerTech\SolutionDeploy-Executor`
- `\JimlerTech\SolutionDeploy-<app>`

Installers create the folder when needed and report failures. Executor dispatch, app startup, read-back validation, and managed-source fencing use this exact task path. Existing legacy tasks keep their original recorded paths until approved retirement.

The controller starts the executor with `Start-ScheduledTask -CimSession` and the exact folder/name. `MSFT_ScheduledTask` has no callable `Start` CIM method.

Application tasks use a short launcher that redirects both output streams and exits. The long-running Node or Python process runs without a drawn console. Tasks use Password logon, Limited privilege, startup/retry triggers, and no execution-time limit. Start applications through their registered task. Running a launcher manually from an interactive terminal is outside the supported startup path.

Local tests check real Node and Python processes, both logs, zero main-window handles, headless console flags, and visible windows. Production acceptance must repeat the check on the selected server and after a reboot without signing in. A cross-session `Unverifiable` result requires interactive inspection; it does not certify windowless startup.

## Prepare an initial legacy conversion

Initial adoption uses a separate `PrepareCutover` operation before final `Cutover`.
It is limited to `LegacyConversion` plans with no current target release. Stage the
sealed release and runtime secret first. Stop and fence the source only after a
separate live approval, then export and reconcile all source data.

1. Approve `PrepareCutover` with the ordinary host/artifact gates plus
   `gracefulStopVerified`, `dataInventory`, `rollbackReady` and
   `filePreparationReviewed`. Bind the exact `transferSHA256` and canonical
   `sourceFenceSHA256`. Database parity and restore gates belong to final
   activation and must not be asserted early.
2. Submit the frozen export with `-Action PrepareCutover -TransferDirectory ...`,
   or with `-TransferArchivePath` (see the optional compressed transfer archive).
   The controller copies and hashes the payload, then checks original source
   content and the live source. A fresh `FrozenTransferContinuity` attestation
   binds the transfer hash without inventing an import receipt. This allows a
   slow network copy to finish without rewriting the original export fence. The
   executor holds the per-app lock, requires maintenance and no active target,
   imports files once, and creates the sealed `current` junction. It writes
   `prepared-transfer.json` and a create-only `prepared-cutover.json` receipt.
   It does not write `active.json`, register a task or start a runtime.
3. The central placement becomes `Prepared`. Only final `Cutover` for the exact
   same host identity, plan, operation and release can continue it. `Pending`,
   `Prepared` and `Unknown` prevent a different plan from taking authority.
4. Install the limited-account task using `Install-AppTask.ps1` with
   `-ApproveProvisioning`, without `-StartNow`. Its startup/retry watchdog respects
   persisted maintenance. Enter the credential locally, or decrypt an approved
   target-local DPAPI credential in its original user context.
5. Run the independently reviewed importer, full source/target parity, custom
   backup and separate validation restore. The import wrapper uses a protected
   operation working directory so its `.run` files cannot change the sealed
   release. Import attempt journals prevent automatic retries after uncertain
   transaction or sequence outcomes.
6. Final `Cutover` approval includes `preparedStateSHA256` plus the existing
   transfer, source-fence and database-evidence hashes and all database gates.
   No `TransferDirectory` is required for this final phase. The executor rehashes
   the exact prepared files and checks for extra files in declared directories;
   it does not call the non-overwriting importer again.
7. The controller creates a new `SourceContinuity` attestation, leaving the
   original export/fence bytes unchanged. It hashes the original source files
   and SQLite main/WAL/SHM/journal against the exported baselines, then checks
   source hardware, disabled tasks, original PID absence, listeners and writers.
   The content job has a 300-second limit and progress every 5 seconds. A
   controller-to-source SMB sample measured 31.2 MB/s, projecting 190 seconds
   for 5.94 GB before per-file overhead. The original 180-second limit was
   insufficient. This read-only check runs before the fresh attestation time
   is recorded; the 240-second export deadline is unchanged.
   The attestation binds the original canonical fence hash, transfer hash and
   final database-evidence hash. Its own 5-minute TTL is checked again after
   database validation immediately before selecting the active release.
8. Existing database evidence, task identity and runtime readiness checks remain
   mandatory. `active.json` appears only during final activation. A prepared
   initial junction never becomes its own previous release.

The source remains stopped across phases. Source recovery always needs an
explicit state-aware review. A failure after the controller writes `Pending`
leaves central placement `Unknown`; an interrupted import also retains partial
files and an attempt journal. Inspect these records and both hosts before a
separately reviewed recovery. Deleting a receipt or retrying blindly is forbidden.

### Optional compressed transfer archive

The default transport is unchanged: `-TransferDirectory` copies each declared
file over SMB. For large frozen exports, an approved single ZIP can replace it
for `PrepareCutover` or an unprepared `Cutover`.

1. On the source, after export, run `scripts\New-TransferArchive.ps1` with the
   frozen export directory, its approved `transferSHA256`, an existing protected
   output root outside the export, and a simple `.zip` name. It reads only
   `transfer.json` and the files that proof declares, hashes each file while
   compressing, creates the archive with create-new semantics, deletes only its
   own partial file on failure, then reopens and verifies every entry. It makes
   no database, service or network calls. The archive contains the same secrets
   as the export, so keep it in the same protected staging locations only.
2. Approve `transferArchiveSHA256` (the printed `archiveSHA256`) alongside the
   existing `transferSHA256`. Submit with `-TransferArchivePath`. Supplying both
   transports, an archive for another action, an archive without the approval
   binding, or a directory when the approval binds an archive is rejected.
   A bad archive fails the operation; there is no fallback to directory copy.
3. The controller checks the archive digest, entry names and lengths and the
   archived proof hash, then copies the archive as one file to the protected
   operation as `transfer.zip`, hashing as it reads and printing progress every
   5 seconds. Source continuity checks use the archived proof unchanged.
4. The protected executor rehashes the archive locally and validates every
   entry before writing: exactly `transfer.json` plus each declared file, no
   extras, missing or case-insensitive duplicates, no traversal, backslash,
   absolute, drive, alternate-stream, trailing-dot, device-name, directory,
   symlink or reparse entries, and each length equal to the proof. It then
   extracts into a new `transfer` directory through `Resolve-OwnedPath` with
   create-new files, stops any entry that expands past its declared length, and
   hashes each file against the proof before the existing import consumes it.

Compression level is a measured tradeoff. On the 15 frozen SQLite backups
(6.55 GB), `Optimal` gave 1.744 GB in 116 s plus 19 s verification and
`Fastest` gave 2.548 GB in 37 s plus 18 s. At about 8 MB/s SMB, `Optimal`
finishes about 21 s sooner end to end, so it is the default. Pass
`-CompressionLevel Fastest` when the link is faster than about 10 MB/s or the
source CPU budget is tighter. Re-measure on the actual link before live use.

### Source stop helper and export heartbeats

Run the graceful-stop (console SIGINT) helper as a separate process from the
exporter. `FreeConsole`/`AttachConsole` in the exporter's own process detaches
its console, and a later `Write-Host` fails with `HostException` invalid handle
(0x6), which was reproduced on the source. Long export or archive jobs must
write file-based heartbeats with elapsed time; never depend on the console for
progress or liveness.

### Continuous export fencing

Export performs full source checks at both endpoints. Between them a same-process
runspace continuously repeats the full fence, with one batched task enumeration
per pass. Per-file checks consume only its synchronized verified heartbeat.
An error, completed monitor or heartbeat older than 10 seconds blocks publication.
The original fence still expires after 5 minutes; no timeout was extended.

The monitor excludes only the direct child Python process whose executable and
snapshot-script command prefix match the reviewed reader. This keeps the monitor
from mistaking its own backup-API reader for another writer. Other parents,
executables or command shapes still fail the source check. A reviewed fence may
also record relative writer command lines or a reviewed command pattern.

Measure the actual host's batched pass before live use. Synthetic tests and a
fast cached read do not establish the real export duration. Use the external
bounded job runner for cancellation of a stalled SQLite/copy operation.

## Deploy a later version

1. Implement and test the change in its application repository. Preserve shared paths, graceful-stop behavior, PostgreSQL storage, and readiness.
2. Review and commit the complete change. Staging uses a clean checkout and a pinned Git archive, not working-tree files.
3. Generate an online plan from the controller:

    ```powershell
    .\Deploy.ps1 -Action Plan -App ferry-tracker -Environment production -Target jimbrownhome1 -OpenReport
    ```

4. Inspect the exact commit, application host identity, separate database host identity, current release, manifest/environment hashes, database/schema compatibility, route profile/tunnel, and rollback. Approve that saved plan only. Approvals include `databaseHostIdentity` and `routeProfile`; `Cutover` also requires `sourceHostIdentity`.
5. Stage with reviewed absolute runtime/tool paths and its separate Stage approval. The build runs in the final release directory and produces a sealed file inventory.
6. Complete reviewed PostgreSQL checks and backup/restore evidence for this plan. An unchanged schema needs compatibility verification; a changed schema also needs independently reviewed migration actions. Never invent a new import or parity result for unchanged production data.
7. Approve `Deploy`. The executor verifies and stops the current owned application, switches the release junction under maintenance, and starts the limited-account task. Shared state and secrets stay outside releases.
8. Run approved `Verify`, then complete external Access/application acceptance. A runtime-verified result still reports external acceptance pending.

Changing a commit, manifest, environment, target placement, runtime, or reviewed input requires a fresh plan or action approval. An interrupted operation must be inspected before retrying.

### Node build and sealing checks

Deployment subprocesses prepend the pinned executable's directory to their own `PATH`. This lets npm's child commands find the reviewed Node executable even when SYSTEM has no user Scoop paths. The controller's environment is unchanged.

Sealed inventories reject all reparse points. After a Node build, the framework replaces npm's declared workspace links with physical copies. Only an explicit workspace directory list is supported, without glob patterns. Each link must point to its exact declared directory within the release, and that directory must contain no nested links. Unexpected links, duplicate package names, copy errors, and redirected targets fail staging. Inventory hashes cover both the original workspace files and their installed copies. Failed builds stay unsealed and cannot activate.

Schema migrations are explicit maintenance operations. This version does not automatically coordinate online/zero-downtime schema changes. Stop and fence every applicable writer before a migration that requires it.

## Move a managed application

1. Create an online plan selecting the other registered host. The plan must show `ManagedMove`, the current source hardware identity, and the unchanged `databaseTarget`.
2. Prepare the destination executor, account, runtime, staged release, private runtime connection file, and verified database endpoint. Remote applications require private connectivity and verified TLS to `jimbrownhome1`. PostgreSQL currently listening only on loopback cannot support a remote application until separately approved network/TLS preparation is complete.
3. Review and gracefully stop the source under durable maintenance. Disable its exact `\JimlerTech\SolutionDeploy-<app>` restart task. Review all other writers before generating a fresh fence.
4. On the verified source, use `scripts\Export-SourceState.ps1` with the saved plan, exact approved plan/fence hashes, a new export directory, and `-ApproveStateExport`. `-WhatIf` checks prerequisites without copying. Managed moves copy declared files only; legacy SQLite exports additionally require the independently reviewed snapshot script and Python executable.
5. Inspect the transfer hashes and current central database/schema/backup evidence. Approve `centralDatabasePreserved`, `managedFilesReviewed`, `sourceMaintenanceVerified`, and `postgresStateValidated` along with the ordinary activation gates. Provision the destination runtime secret separately. Never copy its old `app.env`.
6. Submit `Cutover` with the reviewed transfer directory. The controller verifies the stopped source through its authenticated management channel, then holds a central per-app transition lease through the executor result. The destination executor consumes protected source evidence and performs local operations; SYSTEM does not need to authenticate to a second server.
7. A returning destination archives its parked declared files under `shared\backups\host-moves\<plan-id>` before a non-overwriting import. An interrupted archive/import leaves a journal and blocks automatic retry. The central PostgreSQL database stays authoritative.
8. Verify local readiness, data/schema identity, routes/Access, windowless startup, and reboot behavior. Keep the old source in maintenance with its task disabled. Review the result before moving another application.

The central placement record and lock live on `jimbrownhome1` under `control\placements\<environment>` and `control\transitions\<environment>`. `Pending` or `Unknown` authority blocks another host from taking over. A timeout or failure requires inspecting both hosts, the protected operation result, and actual database writers before a separately reviewed recovery. Do not delete these records to bypass the gate.

Approve `clocksSynchronized` only after checking controller, source, destination, and database-host clock synchronization. Fences reject future timestamps and evidence older than 5 minutes; the framework never widens this window automatically. An upload or preflight failure can leave an operation directory before execution. Inspect it before creating a fresh plan; automatic cleanup and blind replay are deliberately disabled.

## Add a new solution

Phase 1 supports Windows-hosted Node and Python services. A static page needs a supported local HTTP service with JSON readiness and graceful stop. IIS, cloud, and container deployment adapters are outside this phase.

1. Add the application's `deploy\application.json` using the existing schema and adapter conventions. Specify its trusted repository, runtime/build, launch entrypoint, reserved port, JSON readiness, shared-state paths, routes, and graceful-stop environment.
2. Reserve a unique app ID, account, port, hostname, and database in `environments\production.json`. Add its manifest path under `apps` and its database under `storagePolicy.databases`. Ownership checks compare all application manifests.
3. For a genuinely new installation, set `newInstallation: true` in its environment app record. Its plan uses `FirstInstall` / `Deploy` with no current release. For an existing app, record its actual `observedHost` and use legacy conversion, including when the selected managed host is the same machine.
   A new installation may omit `observedHost`; it has no source placement to invent.
4. Allocate its own PostgreSQL database and separate owner, migration, and runtime roles. Include a schema ledger and explicit initialization SQL even if the first page has no application records.
5. Keep `DATABASE_URL` out of source and manifests. Reserve the protected runtime secret file for destination configuration. Any imported source environment belongs under `secrets\source` and cannot overlap runtime secrets.
6. Implement isolated readiness, storage, shutdown, and import tests. Independently review every database-altering test before running it.
7. Present the new-app report, obtain provisioning approval, and prepare its account/runtimes/task/database/secrets. Register the task with `Install-AppTask.ps1 -StagedReleasePath <AppRoot>\releases\<id>`, which checks the staged release manifest while the task still targets `current`; activation creates the `current` junction. Keep maintenance active until activation is approved.
8. Validate initialization and restored backup in place of a legacy import. Record that there was no source snapshot; do not manufacture source-transfer evidence.
9. Stage, approve, activate, verify, and complete external/reboot acceptance before treating it as production.

New solutions still pass the same independent database review and explicit production-action gates. They do not require a previous source installation.

## Rollback

Same-host rollback selects the explicitly reviewed retained release with current compatible PostgreSQL data. It never restores stale shared state automatically. Moving back to a managed host uses a new `ManagedMove` with the same central database. Returning to an old SQLite/JSON application after PostgreSQL writes requires independently reviewed reverse conversion.
