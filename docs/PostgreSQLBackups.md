# PostgreSQL backups and recovery

## Installed job

- Host: `jimbrownhome1`, PostgreSQL 18.
- Task: `\JimlerTech\PostgreSQL-Backup`, running as `SYSTEM`.
- Schedule: daily at 03:00 Pacific local time. Missed runs start when the host becomes available.
- Script: `C:\ProgramData\JimlerTech\PostgreSQL\Backup-Postgres.ps1`.
- Local copies: `C:\ProgramData\JimlerTech\PostgreSQL\backups\pg-yyyyMMdd-HHmmss`.
- Off-host copies: `\\jimbrownhome\Shared\PostgreSQL\jimbrownhome1\pg-yyyyMMdd-HHmmss`.
- Retention: the current local calendar day and the preceding 13 days. Expiration runs only after a new backup has been restored, compared and copied successfully.
- Failure alerts: Pushover, priority 1. Task failures also appear in Windows Task Scheduler.
- Limits: a native command gets at most 10 minutes; the job has a 40-minute internal deadline and a 45-minute scheduler limit. Commands emit progress every 15 seconds.

The daily trigger stores its start boundary without a UTC offset. Task Scheduler then keeps the
03:00 local time when daylight saving time changes. The installer sets the first boundary to
the next future 03:00; check the task's next run after changing the trigger.

The job discovers every connectable, non-template database, including the
maintenance database `postgres`. The current application databases are
`ferry_tracker`, `fit_track`, `home_automation`, `site_dock`,
`team_scoreboard`, `the_workbench`, `web_bookmarks`, `web_inventory`, `web_options`,
`web_portfolio`, and `work_log`. An unexpected `sd_validate_*` database stops
the job for inspection rather than being backed up or overwritten.

A superuser session (for example pgweb browsing as `postgres`) can still open a
validation database despite `REVOKE CONNECT`, and its `DROP DATABASE` then fails
with "being accessed by other users". On 10/29/2026 pgweb did this to
`sd_validate_backup_ferry_tracker`; after review the exact database was dropped
`WITH (FORCE)` and the rerun succeeded.

Each set contains:

- Custom-format `.dump` files, including original object ownership and grants.
- Per-table row counts from the same exported snapshot used for each dump.
- `roles.sql`: cluster roles, memberships and password hashes.
- Copies of `postgresql.conf`, `pg_hba.conf`, and `pg_ident.conf` for reference.
- `manifest.json`: outcomes, file sizes, SHA-256 checksums and local timestamps.

Each database is restored into a new `sd_validate_backup_<database>` database
on the source host, without original ownership or grants. All user-table
counts must match the saved snapshot counts before that test database is
removed. Production data is never restored over or deleted. Restore failure
leaves the test database in place for inspection and stops the run.

The off-host files are checked against the local SHA-256 checksums before the
off-host `.partial` directory is renamed into a complete backup set. Failed
or partial sets are retained for inspection, not automatically deleted.
Only complete successful backup sets are subject to retention.

These are logical backups with separate per-database snapshots. They do not
provide point-in-time recovery or a single cross-database transaction snapshot.
The worst expected data gap is one day after a successful nightly run.

## Check or run a backup

On the host, from an elevated PowerShell terminal:

```powershell
Get-ScheduledTaskInfo -TaskPath '\JimlerTech\' -TaskName 'PostgreSQL-Backup'
Get-Content C:\ProgramData\JimlerTech\PostgreSQL\backups\backup.log -Tail 30
Get-Content C:\ProgramData\JimlerTech\PostgreSQL\backups\latest-success.json
Start-ScheduledTask -TaskPath '\JimlerTech\' -TaskName 'PostgreSQL-Backup'
```

The task result must be `0`. Check the manifest's completion time as well:
a previous successful run does not prove that today's run succeeded.

If a failed restore leaves a test database, inspect the failed manifest and
obtain an independent review before deleting the exact named test database.
Do not delete all databases matching a prefix.

## Access and credentials

The local configuration and backups inherit protected permissions for
`SYSTEM`, Administrators and the existing owner. The off-host `PostgreSQL`
folder has inheritance removed and permits only destination Administrators,
`SYSTEM`, and `jimbrownhome\pgbackup`. The dedicated account has Modify access
for backup creation and retention.

The share password and Pushover keys are encrypted with Windows DPAPI under
the source host's `SYSTEM` identity in `backup-share.credential.xml` and
`backup-alert.credential.xml`. They cannot simply be copied to another host.
The share account password does not expire automatically; rotate it deliberately
and replace the encrypted credential on the source host together.

The dumps and `roles.sql` are not encrypted files. Their protection depends on
the Windows folder/share permissions and the storage devices' protection.
They contain personal information and authentication material. Never attach
them to issues, commits or chat.

For initial installation, `Install-PostgresBackup.ps1` runs as `SYSTEM`.
Its temporary credential JSON must be created inside the already protected
PostgreSQL configuration directory. It encrypts those credentials, verifies
share write access, installs the nightly task and deletes the temporary input
in `finally`. Never place that input in this repository.

## Recovery on a replacement host

Database restore and cleanup require independent review before execution.
Use the following order; do not run recovery SQL against the current live
cluster as a test.

1. Choose a backup whose manifest says `Succeeded`. Recalculate every listed
   SHA-256 checksum against the off-host files before restoring.
2. Install PostgreSQL 18 on the replacement host. Initialize the empty cluster
   with a separate temporary superuser such as `recovery_admin` so restoring
   the original `postgres` role does not collide with an existing role.
3. Review `roles.sql`, then restore it into the empty cluster with `psql -X
-v ON_ERROR_STOP=1`. This restores original role names, memberships and
   password hashes. Use a protected password file, never passwords in commands.
4. Restore each application dump with `pg_restore --create --exit-on-error`
   connected to the replacement cluster's maintenance database. Keep ownership
   and ACL restoration enabled for actual recovery. The existing maintenance
   database needs separate handling if its own dump is required.
5. Re-run the user-table count query from `Backup-Postgres.ps1` against every
   restored application database and compare with its `.counts.json`. Check
   application access under each original runtime role.
6. Review the saved server configuration as reference. Adapt paths and host
   access rules to the new installation; do not blindly overwrite its files.
7. Restore application files/secrets from their own backups, then start apps
   and verify reads, new writes and their public/private access paths. Keep
   retired collectors stopped.
8. Recreate the share credential and alert keys under the new job identity,
   install the nightly task, and verify a complete run.

The PostgreSQL job does **not** back up Azure SQL, application files, image
directories, raw file archives, app environment secrets, SSL private keys,
Windows accounts/tasks, Plex settings or media. Those require their own
recovery sources. The share is on a second computer at the same location,
so fire, theft or loss of both computers is outside this backup's protection.

## Review record

The initial restore/create/drop algorithm was independently reviewed by
Claude Sonnet 5 on 2026-10-19: **APPROVE**, no database-safety blockers.
Changes to restore or deletion behavior require another independent review.
