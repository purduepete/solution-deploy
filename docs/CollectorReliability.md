# Collector release access and monitoring

The Web Options and Web Portfolio collectors run as LOCAL SERVICE
(`S-1-5-19`). An administrator being able to read a new release does not prove
that the scheduled task can read it. The October 23, 2026 incident stopped both
the Options collector and its release-local watchdog before either could run.

## Release changes

- Keep secrets outside releases. Grant the task identity read/execute on the
  selected code release only. Do not grant write access to code or reset the
  entire app's permissions.
- Use the managed PowerShell executable at
  `C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe`.
- Run the installer access preflight before updating task definitions. It must
  use the actual task identity, rather than the installing administrator.
  Preserve the existing healthy tasks if the candidate fails.
- Check collector, watchdog, reference and audit task definitions together.
  Different compatible releases are allowed; a leftover task must be deliberate.
- Preserve disabled tasks and existing activation approvals. Do not rerun a full
  activation installer merely to repair ACLs or trigger database isolation probes.
- Preserve Web Portfolio availability and scheduled captures. Permission repairs
  do not require stopping or restarting its tasks. Schedule any necessary task
  definition changes outside capture windows.

An inherited parent grant alone cannot prove readability. Same-volume moves can
retain old permissions, and protected descendants or deny entries can block reads.
Use the account-level probe and review exact failed paths. Save scoped ACLs and
task definitions before changing them.

The deployed maintenance copies are under
`C:\ProgramData\SolutionDeploy\installers\web-options` and
`C:\ProgramData\SolutionDeploy\installers\web-portfolio`. Use these updated
installers for task changes, rather than an older install script in a retained
release. New source releases contain the same gates. The shared helper is
`control\framework\src\CollectorAccess.psm1`; update it through
`scripts\Update-HostExecutor.ps1` so its installation inventory stays valid.

`scripts\Test-CollectorAccess.ps1` can check an existing selected release without
rerunning activation or database probes. It accepts an external configuration,
optional Python path, additional read paths and writable directories. It starts
only a disposable LOCAL SERVICE file-access probe and isolated Python interpreter,
never the application. Failed probes restore the saved release ACLs and leave
production task definitions unchanged. Scoped ACL snapshots and failure records
remain under `control\collector-access` for diagnosis; transient probe tasks,
manifests and output directories are removed.

## Independent monitor

`scripts\Install-CollectorMonitor.ps1` installs
`\JimlerTech\SolutionDeploy-collector-monitor`. It runs at startup and every
minute from `C:\ProgramData\SolutionDeploy\monitor`, outside collector releases
and Python environments. The host-plumbing task uses SYSTEM so it can reuse the
existing SYSTEM-encrypted PostgreSQL backup notification credentials through
`C:\ProgramData\JimlerTech\PostgreSQL\Send-BackupAlert.ps1`. It has no database
connection or additional database grants.

The monitor checks expected enabled tasks, failed exit codes, overdue minute or
daily schedules, snapshot generation time/errors, collector heartbeats and the
latest non-informational audit section results. `267009` means running, not a
failed exit. Minute tasks and heartbeats continue outside market hours, so their
freshness is checked continuously. Daily audit tasks/reports have a 26-hour
allowance. The five-minute snapshot has a 12-minute freshness allowance;
heartbeats and minute tasks have 10 minutes.

Identical findings send one alert, then a daily reminder. A changed finding or
full recovery sends another notification. A failed delivery does not mark the
notification as sent. State is in `monitor\state.json`; a nonzero monitor result
can mean it successfully reported an unhealthy collector or audit.

Each sent notification is also appended to
`apps\solution-deploy\data\collector-alerts.json` (30 days kept). The status
snapshot copies it, and the Collectors page lists it under "Monitor alerts", so
past alerts are visible without Pushover. A history write failure only warns.
Task failures use readable job names, explain the possible impact and direct
the reader to the relevant log. Task names and exit codes remain as technical
details. A watchdog failure alone does not establish that captured prices are wrong.

The snapshot includes up to 30 days of runs, audits and alerts. Each history
group defaults to 7 calendar days including today, with independent 14 and 30-day
dropdowns at the right of each section heading. Range choices survive snapshot
refreshes and reset on page reload.

Audit INFO badges show report counts and comparison errors on hover, focus or
tap. Counts come from the saved audit report; absent counts display as unavailable.
Tooltip IDs use a page-local counter so plain HTTP LAN access works without
secure-context browser APIs.

The earnings reference job waits each morning (about 05:00 to 05:02) for Azure's
earnings rows. That scheduled wait used to exit 1 and caused 2 false alerts on
10/24; it now exits 0, and a missed deadline still fails through the expired
slot check (web-portfolio, after `fd39a205`).

For a read-only evaluation without notifications or state changes:

```powershell
& C:\ProgramData\SolutionDeploy\runtime\powershell\7\pwsh.exe `
  -NoProfile -NonInteractive `
  -File C:\ProgramData\SolutionDeploy\monitor\scripts\Test-CollectorHealth.ps1 `
  -EvaluateOnly
```

The monitor still depends on the host, Task Scheduler, the managed PowerShell
runtime, the existing snapshot publisher and Pushover. It does not certify
capture data merely because a task exits successfully.

## October 23 findings and acceptance

Read-only inspection found inheritable release-parent grants for the dedicated
accounts used by Ferry Tracker, FitTrack, Home Automation, Site Dock, Team
Scoreboard and Web Bookmarks. Web Options, Web Portfolio and Web Inventory
had LOCAL SERVICE access on the parent without inheritance. Existing selected
collector releases already had explicit inheritable read/execute grants after
the incident repair. The solution is preflight on each selected release, not
a blanket grant across every historical release.

The real account probe also found LOCAL SERVICE write access to the pinned
Scoop Python 3.14.8 installation through inherited Authenticated Users permissions.
The runtime and its two existing persistent junctions (`Scripts` and
`Lib\site-packages`) are now checked at their physical targets. Arbitrary links
in application code remain rejected.

The live repair denies LOCAL SERVICE write/delete/permission-change rights only
on `C:\Files\ScoopApps\apps\python314\3.14.8` and
`C:\Files\ScoopApps\persist\python314`. Five containing directories received
LOCAL SERVICE self-only Delete denies, without inheritance, to prevent replacing
the runtime's ancestors. Other users' permissions were retained. One runtime
cache file owned by LOCAL SERVICE was assigned to Administrators, with its DACL
verified unchanged, because an owner can otherwise change its own permissions.
The repair required no service restart or task repointing. Recheck a new Scoop
version before using it; these grants deliberately cover the pinned version.

Task definitions, original ACL/owner records, applied-change results and deployment
transcripts are retained in
`C:\ProgramData\SolutionDeploy\archives\collector-hardening-20261023-1935`.
Independent review: Claude Sonnet 5.5 approved the monitor and access preflight,
and approved the scoped runtime deny and owner repairs with rollback,
no-link-traversal and unchanged-DACL conditions.

All 12 configured public app endpoints returned Cloudflare Access redirects;
all configured private Tailscale endpoints returned HTTP 200 during inspection.
These are access-path checks, not full application or capture-data tests.

The October 22 audit failures were completed comparisons, not launcher failures:

- Options: 108 VADER value mismatches, 18 portfolio value mismatches and 12,324
  missing coverage comparisons in the saved report.
- Portfolio: 73 stock value mismatches and 12 index value mismatches; earnings
  passed and splits were informational.

Options comparison remediation is tracked in
[purduepete/web-options#8](https://github.com/purduepete/web-options/issues/8).
The Portfolio stock audit's run-selection defect was addressed in
[purduepete/web-portfolio#662](https://github.com/purduepete/web-portfolio/issues/662);
the next report must show the result of that fix. These existing data-comparison
work items are separate from preventing unreadable releases.

Keep those reports failing until their comparison/data issues are resolved.
Do not change historical data, suppress sections or treat exit code zero as
the only acceptance condition. Database-writing repairs need a separate
exact-command independent review.

On October 24, 2026 Jim approved making Options VADER and portfolio value
mismatches and `missing_azure` rows informational (web-options `02db285`).
Every report from 10/20 to 10/23 failed on them while coverage passed: local
and Azure samples are 5 minutes apart (12:55 vs 12:50, 13:10 vs 13:15) against
a 1-cent tolerance. The counts and examples stay in each report for the
web-options#8 session review. Missing local data, coverage and degraded runs
still fail.

The same day Jim asked whether a real value failure would still alert. A
gross-error gate followed (web-options, after `02db285`): a price off by more
than max($0.50, 25%), a delta off by more than 0.15, a negative or zero local
price against an Azure price above $0.05, a local |delta| above 1, a delta sign
flip past 0.05, or a value missing locally fails the section. Fewer than half of
the expected rows compared with Azure also fails (`low_comparison_coverage`).
IV differences stay informational. A host backtest of 10/23 had 0 gross rows.

The monitor skips task result `267011` (registered, not yet run). Re-running
the installer sets it, which caused a false alert at 00:35 on 10/24.

Immediate acceptance is a successful account-level file/runtime probe, unchanged
healthy production task targets, fresh normal scheduled heartbeats, focused
regression tests and actual notification delivery. Actual market capture and
the next nightly audit are separate scheduled evidence. Record those as pending
until the corresponding run has happened and its data/report has been checked.

### Deployment result

Completed October 23, 2026, with all times below in Pacific local time:

- Work began about 7:28 p.m.; the independent monitor delivered its first
  Pushover alert at 7:45 p.m. Subsequent identical findings were deduplicated.
- All four real LOCAL SERVICE probes passed by 8:04 p.m.: Options releases
  `collector-dd7ccdb` and `collector-827733c`, Portfolio release
  `stock-collector-6d5f8819`, and Inventory release `20261018`.
- Cleanup finished by 8:06 p.m. Four one-time tasks and six copied probe modules
  were removed. All 14 original task definitions remained unchanged; ACL
  snapshots, failure records and deployment transcripts were retained.

Implementation and live verification took about 38 minutes. Live checks required
correcting the administrator-role check, supporting the two verified Scoop
junctions, repairing runtime permissions/ownership, and replacing slow per-path
PowerShell access checks with native bulk checks. Regression coverage includes
these access-check cases.

The combined focused suite passed 32 tests. Portfolio's offline smoke checks
also passed. No database commands were run during deployment. Normal collector
tasks continued running, with fresh error-free heartbeats. The monitor still
reports the existing audit comparison failures listed above; market capture and
the next 11:30 p.m. audit remain pending scheduled evidence.

## Local validation

```powershell
$result = Invoke-Pester -Script @(
  '.\tests\CollectorAccess.Tests.ps1',
  '.\tests\CollectorMonitor.Tests.ps1'
) -PassThru
if ($result.FailedCount) { exit 1 }
```
