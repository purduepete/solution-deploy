# PostgreSQL deployment contract

The existing PostgreSQL instance on `jimbrownhome1` is shared host infrastructure. The framework must not reinstall it, restart it, change global authentication, or expose its loopback listener as part of an app deployment.

| App             | Production database | Runtime role                 | Migration role                | Owner role                 |
| --------------- | ------------------- | ---------------------------- | ----------------------------- | -------------------------- |
| Ferry Tracker   | `ferry_tracker`     | `sd_ferry_tracker_runtime`   | `sd_ferry_tracker_migrator`   | `sd_ferry_tracker_owner`   |
| Home Automation | `home_automation`   | `sd_home_automation_runtime` | `sd_home_automation_migrator` | `sd_home_automation_owner` |
| SiteDock        | `site_dock`         | `sd_site_dock_runtime`       | `sd_site_dock_migrator`       | `sd_site_dock_owner`       |

Names are allocations, not proof that any database or role has been created.

Before setting login passwords, audit `has_database_privilege(<role>, <database>, 'CONNECT')` for every existing database and inspect the applicable authentication rules. `NOINHERIT` does not remove privileges granted to `PUBLIC`. The initial deployment found that the passwordless Ferry roles could connect to `mydb` and `postgres` through default grants once a password was set. Keep the roles passwordless until the operator accepts that exposure or a separate reviewed change restricts access. Do not revoke shared grants or edit `pg_hba.conf` silently.

### Reviewed Ferry access restriction

On October 17, 2026, the operator approved restricting Ferry roles to `ferry_tracker`. Claude Sonnet 5.5 reviewed the exact change before execution. The active authentication file, discovered through `SHOW hba_file`, is `D:\data\postgres\pg_hba.conf`; the installation directory contains a separate copy and must not be assumed active.

The active file now has first-match rules allowing only `ferry_tracker` on loopback for `sd_ferry_tracker_runtime` and `sd_ferry_tracker_migrator`, followed by explicit rejection of other databases and replication for those roles. Existing rules and other users' grants were preserved. The file ACL was unchanged, parsing reported no errors, and administrator authentication still worked after reload.

All 12 IPv4/IPv6 role/database probes passed: both roles reached password authentication on `ferry_tracker` and were rejected by HBA on `mydb` and `postgres`. Passwords remained unset. This verifies authentication restrictions; catalog `CONNECT` privileges inherited through `PUBLIC` remain unchanged. Any later deployment to another app host requires separately reviewed remote-access rules and TLS setup.

Following a separate Claude Sonnet 5.5 review, both role credentials were provisioned on the server and authenticated successfully. The operation used independent CSPRNG secrets and salts, locally computed SCRAM-SHA-256 verifiers, protected role-specific `pgpass` files, and SQL through redirected stdin. No secret was included in command arguments or reports. Statement logging was checked before writing verifiers. A failed or uncertain credential operation requires checking the role and its retained credential file before retrying; never remove the file or reset credentials automatically.

The reviewed Ferry schema and grants were then applied through `Manage-Postgres.ps1` with the migration identity and explicit owner role. Runtime evidence verified schema version 1, no privileged-role membership, no schema creation, and no writes to either deployment ledger. This is schema preparation only; it does not establish imported records, restore proof, application activation, or public cutover.

## Database host separation

PostgreSQL always runs on the configured database host (`jimbrownhome1`, `192.168.2.14`). Apps may deploy to any configured app host, including `jimbrownhome` (`192.168.2.11`). `plan.target.host` names the app host; the database host comes from two plan fields:

```text
plan.databaseTarget       = { host, address, root, port, serverName, remoteSslMode }
plan.databaseHostSnapshot = { identity, host, address, verified, ... }
```

`Get-PostgresConnectionPolicy -Plan <plan> [-ClientHost <computer>]` validates them and fails closed. The address must be private IPv4, `serverName` must be the database host name or its FQDN (never an IP), `remoteSslMode` must be `verify-full`, and the snapshot must be verified with the same host and address. `ClientHost` defaults to `plan.target.host`. The returned hashtable has `Mode` (`Loopback` or `Remote`), `HostName`, `HostAddress`, `Port`, `SslMode`, `ServerName`, `DatabaseHost`, `DatabaseAddress`, `DatabaseHostIdentity`, `ClientHost`, `Legacy`, and `EndpointSHA256`. A client on the database host gets loopback. Any other client gets `HostName=serverName`, `HostAddress=address`, `SslMode=verify-full`. Plans without `databaseTarget` keep the original colocated loopback contract.

`EndpointSHA256` is `Get-PostgresEndpointDigest` over host name, pinned address, port, and TLS mode. Activation approval binds it, along with the root certificate file and its SHA-256. `Get-PostgresConnectionParameters -Policy -ApprovedEndpointSHA256 [-SslRootCert -SslRootCertSHA256]` checks that binding and returns the splat for `Get-PostgresDatabaseEvidence`.

Remote connections are limited to read-only `psql` evidence from an app host. The tool receives `PGHOST=<serverName>`, `PGHOSTADDR=<address>`, `PGPORT`, `PGSSLMODE=verify-full`, `PGSSLROOTCERT`, `PGGSSENCMODE=disable`, `PGSSLCERTMODE=disable`, and `default_transaction_read_only=on`. libpq checks the certificate against the server name while the connection goes only to the pinned address. Inherited `PGSSL*`, GSS, service, and target overrides are cleared for every call. The password stays in the protected `.pgpass` file, whose host field must be the server name. The root certificate must have the approved hash and must not be writable by Everyone, Users, or Authenticated Users. Evidence also requires the server to report TLS (`pg_stat_ssl`) and the approved address (`inet_server_addr()`).

`Assert-PostgresRuntimeConnectionString -ConnectionString -Policy -Database -RuntimeRole [-SslRootCert]` checks the app's actual runtime `DATABASE_URL`. It must be a single-host `postgresql://` URL for the runtime role and app database on the approved port. Remote URLs need the server name as host plus `hostaddr`, `sslmode=verify-full`, `gssencmode=disable`, and an absolute `sslrootcert`. Only `sslmode`, `hostaddr`, `sslrootcert`, `gssencmode`, `connect_timeout`, and `application_name` are accepted. The result omits the password and failures never echo the URL.

Nothing here changes `pg_hba.conf`, `listen_addresses`, server certificates, or firewall rules. A remote app host stays unusable until those are separately reviewed and changed on the database host.

## Runtime

Production manifests require `STORAGE_BACKEND=postgresql`. A protected app-specific secret file supplies `DATABASE_URL`. Missing credentials or failed PostgreSQL connections must fail readiness without switching to SQLite or JSON.

Frozen source environment files are archival inputs under `shared\secrets\source`. The separately provisioned runtime `shared\secrets\app.env` contains the reviewed destination configuration and database URL. These paths must not overlap. Preserve original service-key values and primary/fallback precedence during secure local preparation; omit keys already provided by the manifest. Never modify a frozen source file to insert destination credentials.

All structured durable application records belong in PostgreSQL, including current JSON-backed settings, histories, and revisions. Service/connection secrets and hardware provisioning keys remain protected files. Ferry's raw gzip archives remain files, with their metadata in PostgreSQL. Diagnostic logs and backup artifacts also stay outside releases.

Runtime identities receive CONNECT to their own database, USAGE on `public`, required table DML, and sequence USAGE/SELECT. They must not have schema creation, superuser, BYPASSRLS, database/role creation, owner/migrator membership, or writes to `public.solutiondeploy_schema` or `public.solutiondeploy_import`. The grant plan revokes DML on the optional import ledger when present; runtime evidence explicitly checks both ledgers and rejects missing import-privilege evidence. Verify denial of CONNECT to the other managed solutions' databases.

Apply schema changes only with the dedicated migration identity and explicit `SET ROLE` to the non-login owner. Runtime startup verifies the expected schema version and must not apply DDL.

## Operator workflow

Run database tools locally on the verified database host (`plan.databaseTarget.host`, or `plan.target.host` for older plans) over loopback, using the plan's port and a pinned PostgreSQL toolchain matching the actual server major version. `Manage-Postgres.ps1` checks the computer name and `databaseHostSnapshot.identity`, and approvals must carry that database host identity. Administrative SQL, backup, and restore never run remotely. `Evidence` uses `plan.solutionDatabases` for cross-solution checks when present; the list must include the app's own database. The service name indicates 18; confirm by querying the server first.

Provision private `.pgpass` files and passwords from a standalone secure terminal. Do not put password values in chat, command arguments, scripts, source control, or reports. Set role passwords interactively using `psql`'s `\password` command. Passwordless roles created during provisioning are deliberately unusable until that separate step.

### Save the existing administrator password

On the controller laptop, open **PowerShell 7 outside VS Code** under the Windows account that can administer `jimbrownhome1`. Run:

```powershell
& C:\Files\Dev\main\solution-deploy\scripts\Set-PostgresPasswordFile.ps1 -PlanPath '<current deployment plan.json>'
```

The masked prompt requests the existing `postgres` password. The helper verifies the plan hash and database machine UUID before requesting it, then saves `C:\ProgramData\JimlerTech\PostgreSQL\postgres.pgpass` on `jimbrownhome1` through its authenticated administrative share. Only SYSTEM and Administrators receive inherited access. libpq requires plaintext in this file; keep it on the protected server disk. The password is absent from command arguments, output, reports, and source control.

This only stores a credential. It does not change a database, reset the password, alter authentication, or test whether the supplied password is correct. Use that server path with `Manage-Postgres.ps1 -PassFile` for the subsequent read-only preflight. `-WhatIf` previews without requesting or storing a password. `-Replace` explicitly permits replacement; `-UserName` supports separately provisioned migration or runtime accounts.

`scripts\Manage-Postgres.ps1` exposes:

| Action              | Behavior                                                                                                                                                                |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Preflight`         | Read server identity/version/catalog metadata and write a local evidence file. Requires operator-provisioned administrative connectivity.                               |
| `PlanProvisioning`  | Produce exact nontransactional database/role SQL and separate post-schema runtime-grant SQL. No SQL is executed. Existing names are conflicts.                          |
| `ApplySql`          | Preview by default. Execution requires exact script/tool hashes, host/role/database binding, unexpired independent review, and a freshly compared preflight snapshot.   |
| `Evidence`          | Read schema fingerprint and role/isolation evidence using the app runtime role.                                                                                         |
| `Backup`            | Preview by default. Approved execution writes a new custom-format `pg_dump` artifact, without overwriting existing files.                                               |
| `RestoreValidation` | Preview by default. Approved execution restores only into an empty, separately approved `sd_validate_*` database. It does not report parity verification automatically. |

Database creation cannot run inside a transaction. Every operation is journaled before execution. A failed or interrupted operation needs inspection and an explicit resume plan; it must never rerun blindly.

Every `ApplySql -Execute` also requires `-SnapshotUserName` and `-SnapshotPassFile`, with the username pinned by the approval's `snapshotUserName`. This separate connection reads the preflight catalog and server system identifier. PostgreSQL restricts `pg_control_system()`; the app migrator must not receive extra monitoring/admin privileges just to perform this check. The mutation connection remains the approved `-UserName`/`-PassFile`, and application DDL still requires the app migrator with explicit owner role.

For each application:

1. Independently review the exact provisioning SQL, schema SQL, import scripts, and test/restore operations before execution.
2. Obtain explicit user approval for the app's production provisioning/migration.
3. Apply database and role provisioning from the maintenance database using the exact reviewed administrative identity.
4. Apply the app's schema transactionally using its migration role and owner role. The app SQL creates `public.solutiondeploy_schema`.
5. Apply runtime grants transactionally **after** the schema exists. Repeat explicit grants after later migrations. New objects receive no automatic runtime privileges.
6. Securely provision the runtime connection and source application secrets. Verify the runtime role cannot modify the schema ledger or reach another app's database.
7. Import the source's reviewed frozen export using the app-specific import script. Preserve IDs, revisions, ordering, timestamps, numeric semantics, and credential representations.
8. Validate exact counts, keys, representative results, archive references, and schema fingerprint. Preserve source-export hashes and independent review references.
9. Take a backup and restore it to an approved isolated validation database. Validate restored record/credential parity before activation.
10. Store the reviewed proof under the app's administrator-owned `state` directory and bind its hash to activation approval. The executor rechecks the live schema and role privileges before launch.

## Activation proof

The activation approval requires:

- Pinned `psqlPath` / `psqlSHA256`.
- `postgresPassFile`, a relative path beneath the app's `shared\secrets`.
- `postgresRuntimeRole`, the exact app runtime database role.
- `postgresEndpointSHA256`, equal to `EndpointSHA256` from `Get-PostgresConnectionPolicy` for this plan and app host. Always required, including loopback.
- For `Mode=Remote` only: `postgresSslRootCert`, the root certificate file used for `verify-full`, and `postgresSslRootCertSHA256`, its SHA-256. Loopback approvals must not depend on them.
- `databaseEvidencePath`, relative to administrator-owned `state`, plus `databaseEvidenceSHA256`.
- An explicitly reviewed `expectedSchemaFingerprint` and `migrationSqlSHA256`.
- Import, restored-backup, isolation, schema-compatibility, and independent-review gates.

`plan.solutionDatabases` lists every managed solution database. Live evidence passes it to `Get-PostgresDatabaseEvidence -SolutionDatabases`, and the runtime role must have CONNECT to none of them except its own.

### Evidence record (schema 2)

Every record contains `planHash`, `database`, `sourceTransferSHA256`, `migrationSqlSHA256`, `schemaFingerprint`, `parityValidated`, `backupRestoredAndValidated`, and `independentReview`. Schema 2 adds:

| Field                      | Value                                                                 |
| -------------------------- | --------------------------------------------------------------------- |
| `transitionKind`           | `LegacyConversion`, `ManagedMove`, `ManagedDeploy`, or `FirstInstall` |
| `databaseHost`             | `plan.databaseTarget.host`                                            |
| `databaseHostIdentity`     | `plan.databaseHostSnapshot.identity`                                  |
| `legacyImportPerformed`    | Fixed by `transitionKind`, see below                                  |
| `centralDatabasePreserved` | `ManagedMove` only, must be `true`                                    |

| `transitionKind`   | `legacyImportPerformed` | `sourceTransferSHA256`                       | Extra requirement               |
| ------------------ | ----------------------- | -------------------------------------------- | ------------------------------- |
| `LegacyConversion` | `true`                  | Must equal the approved source transfer hash | None                            |
| `ManagedMove`      | `false`                 | `null`                                       | `centralDatabasePreserved=true` |
| `ManagedDeploy`    | `false`                 | `null`                                       | None                            |
| `FirstInstall`     | `false`                 | `null`                                       | None                            |

A managed move relocates the app between app hosts. The database stays on the central host, so there is no import, and the record must claim that the existing database was preserved. These claims require the actual reviewed validation results, not manually invented success values.

The fingerprint covers public table/view column definitions, constraints, views, and indexes from PostgreSQL catalogs. Activation compares it to the reviewed fingerprint and the live runtime-role view of the schema. Live evidence also records `endpoint` (`mode`, `hostName`, `hostAddress`, `port`, `sslMode`, `endpointSHA256`). Remote evidence fails unless the server reports TLS for the session (`pg_stat_ssl`) and answers on the approved address (`inet_server_addr()`).

### Runtime DATABASE_URL

`Assert-PostgresRuntimeConnectionString -ConnectionString -Policy -Database -RuntimeRole [-SslRootCert]` checks the app's actual runtime `DATABASE_URL` from its protected `app.env`, not only the verifier connection. Pass `postgresSslRootCert` as `-SslRootCert` for remote apps. The URL must be a single-host `postgresql://` URL for the runtime role and app database on the approved port. Only `sslmode`, `hostaddr`, `sslrootcert`, `gssencmode`, `connect_timeout`, and `application_name` are accepted. The result omits the password and failures never echo the URL.

Loopback form:

```text
postgresql://sd_<db>_runtime:<password>@127.0.0.1:<port>/<db>
```

Remote form (URL-encode the certificate path):

```text
postgresql://sd_<db>_runtime:<password>@<serverName>:<port>/<db>?sslmode=verify-full&hostaddr=<address>&gssencmode=disable&sslrootcert=<absolute path>
```

These are libpq semantics. libpq connects to `hostaddr` without DNS and verifies the server certificate against the host name, so the pin and the certificate check both hold. The validator proves the URL states that contract. It does not prove the app's driver honors it.

Drivers that are not libpq may differ. node-postgres (`pg`) ignores `hostaddr`, so it would resolve `<serverName>` through DNS and the address pin would be lost. Its `sslmode` handling also differs from libpq. A remote app on such a driver must set the driver's own TLS options explicitly: connect to the approved address, verify the certificate chain against the approved root file, and check the certificate name against `serverName`. Until that driver configuration is reviewed for the app, treat remote activation for that app as blocked. The psql-based evidence checks only the verifier's own session, not the app's connection.

## After a PostgreSQL update

A PostgreSQL update (for example 18.6 to 18.7) can re-register the
`postgresql-x64-18` service with the installer's default data folder,
`C:\Program Files\PostgreSQL\18\data`. On November 13, 2026 that started an
empty October cluster, and every app's runtime login failed until the service
was pointed back at the live cluster.

After every update, before releasing anything:

1. Check the service command line ends with `-D "D:\data\postgres" -w`:
   `(Get-CimInstance Win32_Service -Filter "Name='postgresql-x64-18'").PathName`.
2. If it names another folder, stop the service, set the `ImagePath` value under
   `HKLM:\SYSTEM\CurrentControlSet\Services\postgresql-x64-18` to the live
   folder (registry, not `sc.exe`, which mangles the quotes), confirm port 5432 is
   free, then start it. This changes how the live server runs, so it needs the
   independent review first.
3. Confirm the PostgreSQL event log shows no `password authentication failed`
   after the restart and each app's health check passes.
4. The first release of each controller app then fails with
   `PostgreSQL verifier changed since activation` and prints the new
   `psql.exe` hash. Rerun it with `-ApprovedPsqlSHA256 <hash>`; the release
   records the hash and later releases of that app need no flag.

## Data authority and rollback

Keep original writers and their restart/backup paths disabled before final export/import. Do not run two Home Automation instances against real devices.

Before the destination application accepts new writes, a failed import can leave the destination isolated and resume the unchanged source after verifying there is no destination writer.

Record target authority before starting the app, because startup can write before readiness. After target writes, PostgreSQL is authoritative. Roll back code only to a retained PostgreSQL-capable release compatible with the current schema. Do not restore stale SQLite/JSON data or automatically run a down-migration.

Returning to the original storage backend requires a separately reviewed reverse conversion and consistent snapshot.

## Isolated tests

`tests\postgres-container.json` declares the disposable PostgreSQL dependency. `Start-PostgresFixture.ps1` requires its independently reviewed script hash and a pinned image digest, uses 2 CPUs / 1 GiB and tmpfs storage, and publishes only a random loopback port. It creates only `sd_test_ferry`, `sd_test_home`, and `sd_test_sitedock`.

The returned random test password must stay in memory. Never display or serialize the returned fixture object. Use only synthetic records, independently review app integration-test DDL before running it, and remove the exact fixture container in a `finally` block.

`Test-PostgresIsolation.ps1` additionally creates only `sd_test_roles_a`, `sd_test_roles_b`, and `sd_validate_roles` inside the verified fixture. It applies generated provisioning SQL, runs schema/grants with the actual migrator identity, proves runtime DML/sequence access and privilege denials, and verifies an exact synthetic record after custom-format backup/restore. This test passed after independent Gemini 4 Argon approval. No production database was involved.
