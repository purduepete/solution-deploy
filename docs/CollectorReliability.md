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

Immediate acceptance is a successful account-level file/runtime probe, unchanged
healthy production task targets, fresh normal scheduled heartbeats, focused
regression tests and actual notification delivery. Actual market capture and
the next nightly audit are separate scheduled evidence. Record those as pending
until the corresponding run has happened and its data/report has been checked.

## Local validation

```powershell
Invoke-Pester -Script .\tests\CollectorMonitor.Tests.ps1 -EnableExit
```
