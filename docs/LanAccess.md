# LAN access

The optional LAN proxy listens only on IPv4 `192.168.2.14`. Reserve that address
for the host's Ethernet adapter in DHCP, or configure a static address outside
the DHCP allocation range. A changed address makes startup fail. Ethernet must
use the Windows Private network profile.

This is plain, unencrypted HTTP. Use it only on a trusted `192.168.2.0/24` LAN.
Passwords, API tokens, cookies, and response bodies are visible to devices able
to observe that traffic. Cloudflare Access does not protect this path. The proxy
uses the apps' existing private-access mode, as the Tailscale fallback does.
Use the existing HTTPS access paths when confidentiality or browser secure-context
APIs are required. HTTP cannot support secure-only cookies or every installed PWA,
passkey, service worker, or browser permission flow.

| LAN port | Loopback HTTP destination | Trusted private HTTPS port |
| --- | --- | --- |
| 80 | 127.0.0.1:18798 (directory) | 8798 |
| 8787 | 127.0.0.1:8787 | 8787 |
| 8788 | 127.0.0.1:8788 | 8788 |
| 8790 | 127.0.0.1:8790 | 8790 |
| 8791 | 127.0.0.1:8791 | 8791 |
| 8792 | 127.0.0.1:8792 | 8792 |
| 8793 | 127.0.0.1:18793 | 8793 |
| 8794 | 127.0.0.1:18794 | 8794 |
| 8795 | 127.0.0.1:18795 | 8795 |
| 8796 | 127.0.0.1:18796 | 8796 |
| 8797 | 127.0.0.1:18797 | 8797 |
| 8798 | 127.0.0.1:18798 (directory) | 8798 |

The trusted upstream origin is
`https://jimbrownhome1.tail8ad282.ts.net:<private-port>`. The proxy sets Origin
to that origin after checking the incoming request. Upstream Host is
`127.0.0.1:<loopback-port>` for HTTP.sys/HttpListener compatibility.
Port 8794 redirects GET `/` to `/app` and rejects every HEAD request with 405
without contacting WorkLog. WorkLog's HttpListener cannot safely handle HEAD.
Other paths, queries, methods, and bodies pass unchanged.

## Request boundary

- Only IPv4 sources in `192.168.2.0/24` are accepted. Production rejects loopback,
  IPv6, and IPv4-mapped IPv6. Loopback is an explicit test-only configuration.
- Host must be exactly `192.168.2.14:<listener-port>`. Port 80 also accepts
  `192.168.2.14`. A present Origin must match the HTTP listener origin.
  Duplicate Host/Origin and `Sec-Fetch-Site: cross-site` are rejected.
- Client forwarding headers and Cloudflare identity headers are removed.
  Authorization, cookies, and API tokens pass unchanged. No credentials are added.
- Connection-specific headers are removed in both directions. HTTP uploads,
  SSE, and WebSockets use streams with backpressure; no request/response bodies
  are accumulated. CONNECT and upgrades other than WebSocket are rejected.
- A redirect to the trusted HTTPS origin is rewritten to this LAN origin.
  Relative redirects and other destinations are unchanged.
- Ordinary cookies have Secure removed for HTTP. A Domain equal to the trusted
  private hostname is removed to make the cookie host-only. `__Host-`,
  `__Secure-`, `SameSite=None`, `Partitioned`, and foreign-Domain response cookies cause an
  explicit 502 and a server log error. Use HTTPS for apps requiring them.
  Cookie Path, HttpOnly, and other attributes are preserved. Cookies share an
  IP host across ports, so app cookie names must avoid collisions.
- CSP `upgrade-insecure-requests` is removed only on this LAN response.
  Existing `frame-ancestors` directives gain `http://192.168.2.14:8790`;
  `'none'` is removed when allowing that ancestor. All other CSP directives
  remain. Both enforced and report-only policies are processed, including each
  policy when there are multiple headers. Other response headers remain.
- Upstream connection or incompatible-header failures return 502 before headers
  are sent. A failure after streaming begins closes that response and is logged.
  Any listener startup failure closes every proxy listener.

## Install on the host

Run from an elevated PowerShell terminal only after the existing apps and directory
are available on their loopback ports:

```powershell
.\scripts\Install-LanProxy.ps1
```

The installer copies just the proxy and launcher to
`C:\ProgramData\SolutionDeploy\apps\lan-proxy`. Administrators and SYSTEM own the
payload; LOCAL SERVICE has read/execute access and write access only to `logs`.
Node and PowerShell executables must be accessible to LOCAL SERVICE.

Task `\JimlerTech\SolutionDeploy-lan-proxy` runs a short launcher under LOCAL
SERVICE at startup and every 5 minutes for recovery. The launcher redirects both
Node streams, records `logs\server.pid`, and exits. It never leaves a long-running
PowerShell console. A live recorded PID must match the Node executable and exact
entry-script path before it can be reused or stopped.

The owned firewall rule `SolutionDeploy-LanProxy-Ethernet` allows TCP on exactly
the listed ports, local address `192.168.2.14`, Ethernet, Private profile, and
remote subnet `192.168.2.0/24`. It does not disable the firewall or remove unrelated
rules. The application source check remains active even if another Node firewall
rule is broader. Router forwarding, UPnP, other network devices, and existing rules
are outside this installer's control. **Absence of external reachability is not
guaranteed.** Check the router separately and do not forward these ports.

The installer verifies the PID, every listener's owner/address, and HTTP readiness
through the host's actual LAN IP, bypassing any configured HTTP proxy. It checks
the directory returns 200, port 8794 redirects to `/app`, and all app roots plus
`/app` return successful or redirect statuses. It disables recovery on verification failure. This
is host-local readiness; verify from a second LAN device after installation.
Installation creates no database, Tailscale route, Cloudflare route, or secrets.

## Local validation

```powershell
node --test .\tests\LanProxy.test.mjs
```

Tests use disposable loopback HTTP servers and ephemeral ports. They require no
real services, database, packages, elevated privileges, or production listeners.
