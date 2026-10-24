# Hosted solution directory

The read-only directory runs on **jimbrownhome1**. It lists site purposes, access
URLs, current databases/storage, and original sources or retained dependencies.
It reads no application database and contains no credentials.

| Access                                        | URL                                           |
| --------------------------------------------- | --------------------------------------------- |
| Cloudflare, Google or Microsoft owner sign-in | https://solution-deploy.jimlertech.com/       |
| Private Tailscale                             | https://jimbrownhome1.tail8ad282.ts.net:8798/ |
| Home LAN, no login                            | http://192.168.2.14/                          |

`site/sites.json` is the maintained inventory. It is separate from the framework's
three-app lifecycle registry in `environments/production.json`. The directory
includes all ten migrated web apps, itself, and 2 private-only tools with no
Cloudflare path: Ride and Lift (Tailscale 8799 → 127.0.0.1:8080) and pgweb
(Tailscale 8800 → 127.0.0.1:8081). Their Local LAN links go straight to the app
port, outside the LAN proxy. It is not a live uptime monitor.
The Local LAN row links through the subnet-restricted LAN proxy. It accepts only
`192.168.2.0/24` clients on the Ethernet interface at `192.168.2.14`. Anyone on that
subnet can use the applications without login. HTTP traffic is unencrypted.
Existing origin listeners and the Cloudflare/Tailscale routes stay unchanged.
See [LAN access](LanAccess.md) for installation and network limitations.

Portfolio and Options **still use live Azure SQL**. Other migrated applications
name their destination PostgreSQL databases and former data sources. Plex's media
server still runs on jimbrownhome; its web UI has local JSON volume settings.
The directory needs no database of its own.

## Update and deploy

1. Edit `site/sites.json`, including its `updated` date. Add or change URLs,
   purpose, current storage, original source and notes together. Do not add
   connection strings, passwords, tokens or user data.
2. Run `node --test tests\SiteDirectory.test.mjs` from the repo root.
   For routing changes also run the existing `tests\CloudflareSignIn.Tests.ps1`
   suite with Pester 3.4. The inventory test compares hostnames/origin ports
   against the canonical Cloudflare allowlist.
3. Commit and push. Synchronize the canonical host checkout at
   `C:\Files\Dev\main\solution-deploy` without overwriting local changes.
4. On jimbrownhome1 in elevated PowerShell 7, run:

    ```powershell
    & C:\Files\Dev\main\solution-deploy\scripts\Install-Directory.ps1
    ```

    The installer updates only this directory service. It checks the recorded
    process identity before stopping it, installs permanent files, starts the
    task, and verifies the exact served inventory and private URL.

5. Verify both published URLs and refresh the browser. Assets use `no-store`.
   The inventory is loaded at process start, so edits need redeployment.

Initial Cloudflare publication is through the sole hostname manager:

```powershell
.\scripts\Set-CloudflareHostnames.ps1 -PublishDirectory
.\scripts\Set-CloudflareHostnames.ps1 -PublishDirectory -Apply
.\scripts\Set-CloudflareHostnames.ps1 -EnableGoogleSignIn
```

The publication copies the existing SiteDock Google/Microsoft owner policy before
adding ingress and DNS. Keep the origin loopback-only; do not add a public
firewall rule. The private path relies on Tailscale access controls.

## Runtime

- Files: `C:\ProgramData\SolutionDeploy\apps\solution-deploy\site`
- Task: `\JimlerTech\SolutionDeploy-directory`, LOCAL SERVICE, boot plus a
  five-minute recovery check.
- Launcher: a short hidden-process launcher with both output streams redirected.
- Logs and PID: `...\solution-deploy\logs\stdout.log`, `stderr.log`, `server.pid`.
- Node: `C:\Files\ScoopApps\apps\nodejs\current\node.exe`.
- Server: Node built-ins only, no packages, fixed read-only asset routes.

Dark/light themes follow the system until toggled, then retain the selected theme.
Sites can be sorted alphabetically by name or by deployment date, newest first.
Search includes purpose, URLs, database names and notes. The page allows embedding
only by itself or the public/private SiteDock origins.
