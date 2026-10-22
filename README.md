# SolutionDeploy

Windows deployment tools, migration procedures and the hosted solution directory.

## Hosted solution directory

The [solution directory](https://solution-deploy.jimlertech.com/) lists all hosted
sites, their purpose, local/Cloudflare/Tailscale URLs, current storage and original
data sources. [Private access](https://jimbrownhome1.tail8ad282.ts.net:8798/) uses
Tailscale. Edit `site/sites.json`; see [directory updates and deployment](docs/Directory.md).

The [Collectors page](https://solution-deploy.jimlertech.com/collectors) shows each
market data job's schedule, last slot and heartbeat, every slot from the last 7 days
and 14 days of nightly Azure audit results. Times are Pacific. The
`\JimlerTech\SolutionDeploy-collector-status` task runs
`scripts\Update-CollectorStatus.ps1` as LOCAL SERVICE every 5 minutes. It reads
`web_portfolio` and `web_options` through each collector's runtime role in read-only
sessions, reads the audit JSON under each app's `shared\logs\audit`, and writes
`data\collector-status.json`. The server reads that file on each request and returns
503 when it is missing. The job catalog at the top of the script mirrors the
collector schedules; update it when a schedule changes.

Home LAN access starts at http://192.168.2.14/ without login. The IPv4-only LAN
proxy restricts clients to `192.168.2.0/24`; HTTP is unencrypted and every device
on that subnet has application access. See [LAN access](docs/LanAccess.md).

For later same-host releases and new applications, see [Production deployments](docs/Deployment.md).

Scheduled tasks use a private, fixed-path PowerShell runtime, independent of
desktop PowerShell updates. See [runtime updates and rollback](docs/PowerShellRuntime.md).

To preview removal of the stale response-header rule for the retired
`ferry.jimlertech.com` alias, run
`.\scripts\Set-CloudflareHostnames.ps1 -RemoveRetiredFerryHeaderRule`.
Add `-Apply` to delete only that rule. This mode leaves DNS, tunnel routes,
Access policies and the current `ferry-tracker.jimlertech.com` hostname unchanged.

For the nightly PostgreSQL backup schedule, off-host copies, restore checks and
recovery procedure, see [PostgreSQL backups](docs/PostgreSQLBackups.md).

Application deployment supports `-Target jimbrownhome` and `-Target jimbrownhome1` (the default). Future application hosts can be added to the environment registry. PostgreSQL and central transition authority remain on `jimbrownhome1`.

## Current status

Ten application websites have moved to `jimbrownhome1`. The directory also runs
there. Public access uses Cloudflare Access with Google/Microsoft owner sign-in;
each site has a separate private Tailscale HTTPS port. The maintained
[`site/sites.json`](site/sites.json) records the actual URLs and storage.

| Application                   | Current database / storage                                         |
| ----------------------------- | ------------------------------------------------------------------ |
| Ferry Tracker                 | PostgreSQL `ferry_tracker.public`                                  |
| Home Automation               | PostgreSQL `home_automation.public`                                |
| SiteDock                      | PostgreSQL `site_dock.public`                                      |
| FitTrack                      | PostgreSQL `fit_track.public`                                      |
| WebBookmarks                  | PostgreSQL `web_bookmarks.public`                                  |
| WorkLog                       | PostgreSQL `work_log.public`                                       |
| WebInventory                  | PostgreSQL `web_inventory.public`; images on destination `D:`      |
| Web Portfolio and Web Options | Existing Azure SQL `webportfolio`, retained unchanged              |
| Plex web UI                   | Local JSON settings; existing media server on `jimbrownhome:32400` |
| Solution directory            | Read-only JSON inventory; Collectors page reads a snapshot file    |

PostgreSQL is on `jimbrownhome1:5432`, with a separate database per application
and tables in `public`. Private secrets, logs and raw archives remain protected
files. The framework lifecycle registry still covers its original three apps;
it is not the complete hosted inventory. The component and approval contracts
below remain requirements for future operations, not proof of a new deployment.

## Local components

- `Deploy.ps1`: read-only Plan and Status, with gated Stage/PrepareCutover/Deploy/Cutover/Verify/Rollback entrypoints. Verify checks the current protected executor result, process/listener ownership, readiness, and PostgreSQL evidence. External Access and reboot acceptance remain separate production checks. `-TimeoutSeconds` (default 300, range 60 to 1800) sets how long to wait for the host executor; large apps such as Ferry Tracker (about 17k files, Stage about 280 s) need 660.

Lifecycle listener ownership checks cover loopback and wildcard bindings. A Tailscale HTTPS listener on its own interface can use the same port as the loopback origin without blocking app startup.

- `src\Deployment.psm1`: manifest/environment validation, plan hashing, locks, staged releases, inventory checks, stopped junction switching, reports.
- `src\Controller.psm1`: protected SMB submission and CIM/DCOM fixed-task invocation. Requires separately provisioned host executor.
- `src\Lifecycle.psm1`: limited-account launcher/watchdog, readiness, process identity checks, maintenance, graceful stop.
- `src\Transfer.psm1`: source state inventory, writer fencing, consistent SQLite/file export, hashed transfer provenance, and non-overwriting frozen-file import. Each application's separate importer converts its reviewed SQLite/JSON export into PostgreSQL.
- `src\PostgreSQL.psm1`: database/role SQL plans, independently reviewed action execution, schema/role evidence, custom-format backup, and isolated restore. See [PostgreSQL contract](docs/PostgreSQL.md).
- `src\Operations.psm1`: activation-proof validation, limited-account task activation, readiness, and data-authority records.
- `src\Cloudflare.psm1`: exact owned-route planning and guarded execution. See [Cloudflare contract](docs/Cloudflare.md).
- `scripts\sqlite_snapshot.py`: reviewed synthetic-test source-export helper, not a PostgreSQL migration implementation. Real-source use remains gated on exact writer inventory/action review.
- `scripts\Install-Host.ps1`: protected executor installation with code inventory and fixed dispatch. Not run or accepted for production.
- `scripts\Update-HostExecutor.ps1 -HostName <host>`: upgrades the installed executor code from a clean commit over the admin share and rewrites the code inventory in `control\installation.json`. Use it after any framework change instead of copying files by hand; a hand copy makes the executor refuse every operation.
- `scripts\Manage-Postgres.ps1`: reviewed, pinned database-tool operations. Preview is the default for mutating actions.
- `scripts\Invoke-ReviewedNodeImport.ps1`: exact-action Ferry import wrapper. Default validation opens no database. Execution requires protected inputs, a prepared receipt, fresh source continuity, dedicated migrator credentials, a separate operation directory, a create-only attempt journal and a bounded deadline.
- `scripts\Invoke-CloudflareTransition.ps1`: exact route-plan execution bound to the verified application deployment.
- `scripts\Grant-AppToolkitAccess.ps1` and `scripts\Install-AppTask.ps1`: separately approved limited-account provisioning.

Activation orchestration is implemented and covered by isolated tests. Actual account credentials, batch-logon rights, machine-wide runtime access, PostgreSQL authentication, source shutdown, Cloudflare configuration, and no-sign-in reboot acceptance still require production preparation and verification.

The original source installations do not have the new stop-file adapters. A reviewed source upgrade or other proven graceful shutdown procedure is required before fencing/export. Do not substitute Windows process termination for worker draining and durable-state persistence.

## Safe local plan

PowerShell 7.5 or newer for the complete host lifecycle:

```powershell
.\Deploy.ps1 -Action Plan -App ferry-tracker -Environment production -Offline -OpenReport
.\Deploy.ps1 -Action Plan -App ferry-tracker -Environment production -Target jimbrownhome -Offline -OpenReport
```

This writes a local plan and HTML report, without accessing or modifying production. An online Plan additionally reads host identity/current placement through authenticated CIM/DCOM and SMB; it does not provision anything.

A plan is tied to manifest/environment hashes and a pinned commit. Uncommitted app adapters cannot be staged as a trusted release. Commit and push require separate operator instruction.

## Validation

The focused suite uses installed Pester 3.4 syntax and PowerShell 7-compatible exception assertions:

```powershell
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Script .\tests\Deployment.Tests.ps1,.\tests\Targets.Tests.ps1,.\tests\Controller.Tests.ps1,.\tests\Executor.Tests.ps1,.\tests\PostgreSQL.Tests.ps1,.\tests\DatabaseActions.Tests.ps1,.\tests\Operations.Tests.ps1,.\tests\Cloudflare.Tests.ps1,.\tests\Lifecycle.Tests.ps1
```

SQLite tests write only synthetic temporary databases. They require independent review before execution under the operator's database-action policy:

```powershell
python -m unittest discover -s tests -p test_sqlite_snapshot.py -v
```

No PostgreSQL-altering test or live database action is authorized by these examples.

The SQLite snapshot helper uses immutable read-only access only after the reviewed
writer fence and when no WAL, shared-memory, or rollback-journal sidecar exists.
An existing WAL keeps normal read-only access so committed WAL rows are included.
Any rollback journal blocks the export pending recovery review. Main-file, WAL,
and rollback-journal hashes must remain unchanged; shared-memory sidecar presence
must also stay unchanged. Temporary output sidecars block publication. Snapshot
evidence records the selected URI mode and initial sidecar presence. Run these
regressions with the exact source Python/SQLite versions before production use.

Independently reviewed tests against a disposable, pinned PostgreSQL 18 Docker fixture passed all 8 application persistence tests. A separate real-database test passed runtime DML/sequence access, schema/ledger-write denial, cross-database denial, privileged-role denial, and custom-backup restore parity. These synthetic results do not establish production-data parity or destination-host acceptance.

### Web standard check

`scripts/Test-WebStandard.mjs` loads every app in `site/sites.json` in headless Edge and checks it
against `copilot/global-instructions/web-standards.instructions.md`. It checks the default Midnight
theme, live System tracking, `theme-color` against the top bar, iOS head tags, both icons, Roboto Flex,
sideways scroll at 390px, console and CSP errors, and native `<select>`/`<datalist>` in page and source.
Requests other than GET are blocked, so it never writes app data. Web Portfolio and Web Bookmarks are
reported but never fail the run. The HTML report goes to `reports/` and opens when the run finishes.

```powershell
npm install                      # once; installs playwright-core, uses installed Edge
npm run check:web                # Tailscale URLs, about 1 minute
node scripts/Test-WebStandard.mjs --public --signin   # first public run: sign in to Access once
npm run check:web:public         # Cloudflare URLs with the saved Access session (730 hours)
```

The Access session lives in `%LOCALAPPDATA%\JimlerTech\SolutionDeploy\web-standard-profile`. iPhone and
iPad rendering still needs a device check.

## Host account preparation

After approval, use a standalone elevated terminal on the destination to:

1. Provision the protected executor and machine-wide pinned runtimes. Verify the actual granted runtime paths and host UUID.
2. Create each dedicated non-administrator account and grant its batch-logon right. Enter passwords only through secure local prompts.
3. Grant the exact reviewed account SID read-only toolkit access using `Grant-AppToolkitAccess.ps1`. This does not grant write access to control records or another application's state.
4. Stage the trusted release. For initial legacy adoption, use the separately approved `PrepareCutover` phase described in [Production deployments](docs/Deployment.md) before `Install-AppTask.ps1`. It creates `current` under maintenance without an active deployment. Then run `Install-AppTask.ps1` with its secure credential prompt and provisioning approval. It validates account rights, runtime/toolkit readability, Password logon, Limited privilege, startup/retry triggers, and unlimited execution time.
5. Keep maintenance active until approved activation. Do not use `-StartNow` against production data or devices during account setup.
6. Complete app-specific secret ACLs and PostgreSQL preparation through the separate reviewed workflow.

All framework-created scheduled tasks belong in the Task Scheduler Library's `JimlerTech` folder (`\JimlerTech\`). This includes `SolutionDeploy-Executor` and each `SolutionDeploy-<app>` startup/watchdog task. Existing legacy tasks retain their recorded locations until their separately approved migration.

Source environment files are preserved under `shared\secrets\source`. They must never overwrite the destination's `shared\secrets\app.env`. Prepare that runtime file in a secure standalone terminal from the reviewed source configuration, preserving service keys and supplying the destination runtime-role `DATABASE_URL`. Omit environment names already declared in the manifest, because the launcher deliberately rejects duplicates. Review Ferry's primary/fallback precedence. The source export remains unchanged.

## Production gates

1. Confirm storage scope and inspect local implementation/validation evidence.
2. Verify the actual target PostgreSQL catalog, authentication, tools, and database-name ownership. Synthetic importer tests have passed; real-data import validation is still required.
3. Independently review exact database provisioning, schema, import, and restore/test scripts.
4. Present a concrete Ferry-only change report: source/target identity, trusted artifact, runtime/account, roles/grants, state size/counts, schema fingerprint, backup/restore proof, maintenance budget, route preconditions, and rollback.
5. Obtain explicit approval before host/account/runtime/database provisioning, secret transfer, real-data startup, source stopping, or route changes.
6. Migrate Ferry Tracker, present the result, and wait for operator review before Home Automation. Repeat the gate before SiteDock.

After destination application writes, PostgreSQL is authoritative. A retained SQLite/JSON source cannot resume with stale state. Code rollback needs a compatible PostgreSQL-capable release; returning to the old backend requires independently reviewed reverse conversion.
