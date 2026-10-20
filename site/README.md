# Directory appearance

The header's Theme select lists System, Light and Midnight. Midnight is the
default. System follows OS changes live; fixed choices stay fixed. Preferences
persist in `solution-deploy-theme` as `system`, `light` or `midnight`. A saved
legacy `dark` choice resolves to Midnight.

Light uses a white page and header. Midnight uses a `#020617` page and opaque
`#0f172a` header. The header is full-width and sticky. Roboto Flex loads from
Google Fonts; the server's CSP allows only the required style and font hosts.
The blocking theme script runs before the local stylesheet to set the launch
background, color scheme and theme-color before paint.

From the repo root, run:

```powershell
node --test site\Theme.test.mjs tests\SiteDirectory.test.mjs
```

The directory server caches assets in memory. Copy the updated site files and
restart the directory task during deployment, then reload the browser. No
database, routing or infrastructure changes are needed. iPhone and iPad
home-screen behavior still needs device verification after deployment.
