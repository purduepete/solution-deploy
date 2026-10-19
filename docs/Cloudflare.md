# Cloudflare route module

`src/Cloudflare.psm1` (PowerShell 7). It plans and applies reviewed exact-host route transitions. Import it optionally. The Stage step never calls it.

## Save an API token securely

Open PowerShell 7 outside VS Code under the Windows account used by the deployment controller:

```powershell
& C:\Files\Dev\main\solution-deploy\scripts\Set-CloudflareToken.ps1
```

Enter an appropriately scoped API token only at its masked prompt. The helper writes `%LOCALAPPDATA%\JimlerTech\SolutionDeploy\cloudflare-token.dpapi.xml`, encrypted with Windows DPAPI for the current user and machine. Directory access is restricted to that user, SYSTEM, and Administrators. No API requests or Cloudflare changes occur. `-WhatIf` previews without prompting; `-Replace` permits deliberate replacement.

The helper writes only directory access rules through the .NET ACL API; it does not request audit-policy privileges or require elevation for a directory owned by the current user. Supply a Cloudflare API token, not a Global API Key or tunnel connector token. Validate the token through a read-only API request before planning route changes.

The deployment controller must explicitly load this credential under the same Windows identity and machine and pass it to the module in memory. The module does not load it automatically. Never print the decrypted token, put it in process arguments, or include it in a report.

## Public sign-in providers

The ten allowlisted public applications accept Microsoft or Google sign-in. Both
paths retain the existing owner email allowlist. The ferry `/api/catch` bypass is
unchanged.

Use `scripts\Set-CloudflareHostnames.ps1 -EnableGoogleSignIn` to preview the scope,
then add `-Apply` to enable the configured Google provider and attach a separate
Google owner policy. The existing Microsoft policy remains attached. The command
can be repeated without creating duplicate policies. It does not configure OAuth
credentials or add hostnames.

Publish Web Portfolio before Web Options with
`-PublishWebPortfolio -Apply`, then `-PublishWebOptions -Apply`.
Portfolio uses origin `127.0.0.1:18796` and private Tailscale HTTPS port `8796`;
Options uses origin `127.0.0.1:18797` and private HTTPS port `8797`.
Both keep their existing Azure SQL database. Publication creates the owner
Access application before tunnel ingress and DNS. During Portfolio publication
only, the Options hostname may still be pending. A normal final verification
requires all ten hostnames.

## Route API contract

| Function | Effect |
|---|---|
| `Get-CloudflareSnapshot -AccountId -ZoneId -TunnelId -Hostname[] (-Token \| -TokenEnvironmentVariable CLOUDFLARE_*) [-Transport]` | GET only. Reads the zone, tunnel and config, DNS per host, Access apps/policies/IdPs, and the rate-limit ruleset, then returns `SnapshotHash` (sha256 of canonical JSON). |
| `New-CloudflareRoutePlan -Manifest -Current -TunnelId -ZoneId -AccountId -Access @{IdentityProviderId; AllowEmails} -Target @{Host; Address; HostIdentity; RouteProfile} [-CatchTokenEvidence] [-AllowDnsRepoint] [-TunnelName]` | No API calls. Returns `SchemaVersion` 2, `Status` (Ready, NoChange, Blocked), `Blockers`, `Operations`, `Limitations`, `Target` (the input plus `TunnelId` and `Origin`), and `PlanHash`. An invalid target blocks the plan. Pass `-Target (Get-CloudflareRouteTarget -DeploymentPlan $d)`. |
| `Assert-CloudflareRoutePlan -Plan` | Recomputes the hash and checks the allowed method/path shapes, op order, the Ferry-only catch, and the terminal 404. |
| `Invoke-CloudflareRoutePlan -Plan [-Token\|-TokenEnvironmentVariable] -ApprovedPlanHash -JournalDirectory [-Transport] [-Execute]` | Previews by default. `-Execute` requires the exact approved hash, re-snapshots, and fails on drift. When the plan has catch ops, it re-runs the token probe live (`-CatchProbe` is injectable) and makes no write unless both answers are 401. Per op: read region, journal prior, compare, write, read back, journal. |
| `Get-CloudflareRouteTarget -DeploymentPlan` | Reads a schema 2 deployment plan. Requires `target.hosts[target.host]` to match the target host, address, and `routeProfile`, and a verified `hostSnapshot` for that host and address. Returns `Host`, `Address`, `HostIdentity` (hardware UUID), and `RouteProfile`. |
| `Assert-CloudflareDeploymentBinding -Plan -DeploymentPlan -ApprovedTunnelId` | Runs `Assert-CloudflareRoutePlan`, then requires plan `Target` to equal `Get-CloudflareRouteTarget` for the deployment, plan `TunnelId` and `Target.TunnelId` to equal the approved tunnel GUID, `AppId` = deployment `app` = manifest `id`, `Service` = `Target.Origin` = `http://127.0.0.1:<launch.port>`, `Hostnames` = the manifest route hostnames, `CatchHosts` = the routes with `catchPath`, and every planned ingress rule and catch evidence to point at that upstream. Returns `PlanHash`, `AppId`, `Target`, `TunnelId`, `Service`, `Hostnames`, `CatchHosts`, and `Status`. The tunnel comes from approval `routeTunnelId`; nothing infers it from a host or tunnel name. Schema 1 plans are rejected and must be replanned. |
| `Test-CloudflareAccessPolicy`, `Test-CloudflareCatchBypass`, `Test-CloudflareCatchRateRule` | Evidence checks over snapshot data. Each returns `@{Passed; Reasons}`. |
| `Test-CloudflareCatchTokenEnforcement -Origin http://127.0.0.1:<port> [-Probe]` | Sends `GET /api/catch?departingTerminalId=7&arrivingTerminalId=3` to the loopback origin, once without `X-Ferry-Token` and once with a random 64-hex token. Both must return exactly 401 with `{"error":"Unauthorized."}`. This matches `ferry_tracker/server/src/app.ts`, which checks the token before the query. A 400 (validation answered first), 404 (token unset), 403, or 3xx fails. Returns hashed evidence that is valid for 60 minutes. |

Op order: Access policy, then Access app (exact domain, Microsoft IdP, allow by email and `login_method`), then the Ferry catch bypass per host, then the tunnel ingress, then DNS. The ingress PUT keeps foreign rules and non-ingress keys and inserts before the bare `http_status:404` terminal rule. DNS is created only after the read confirms it's absent. A repoint requires `-AllowDnsRepoint` and a proxied CNAME to another tunnel.

Plan keys are PascalCase (`PlanHash`, `AppId`, `Service`, `Hostnames`, `CatchHosts`, `Status`). `ConvertFrom-Json -AsHashtable` returns a case-sensitive `OrderedHashtable`, so `$route.planHash` is `$null`.

Transport: `param([hashtable] $Request)` with `Method`, `Path`, `Body`, `BodyJson`, and `Token`. It returns the Cloudflare envelope.

## Limitations

- The host registry has no tunnel mapping, so the module cannot detect one tunnel approved for two route profiles. The reviewer's `routeTunnelId` is that mapping.

- Cloudflare has no If-Match on these writes. The region is re-read and hash-compared just before each write, which leaves a short race window.
- Tunnel config can only be written by a whole-document PUT. A named mutex per tunnel serializes local runs only.
- There's no automatic rollback. The journal (`cloudflare-<utc>-<hash12>.jsonl`) records the prior state for a manual restore. The token is never written to it.
- Plan evidence is caller-supplied. Its hash only shows it was not edited, so the live re-probe at execute time is the gate. A probe proves that wrong tokens are refused. It cannot prove that the configured token is the one the watch uses.
- The rate rule is verified from the snapshot and re-read before routing.
