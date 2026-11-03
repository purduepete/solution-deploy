# Directory appearance

The header's palette icon opens an appearance popover on both the directory and
Collectors pages. Its square segmented Theme control lists Light, Midnight and
System, matching Home Automation's icon and layout. Midnight is the
default. System follows OS changes live; fixed choices stay fixed. Preferences
persist in `solution-deploy-theme` as `system`, `light` or `midnight`. A saved
legacy `dark` choice resolves to Midnight.

The compact sort control uses an A-Z button for alphabetical order and a calendar
button for deployment date, newest first. Alphabetical order is the default.
Sites without a recorded release date appear after dated sites.
The square control slides its selection fill when switching order, unless reduced
motion is requested. The selected order is restored from `solution-deploy-sort`
in local storage on the next visit. If browser storage is blocked, sorting still
works for the current page and a warning is logged.

Each card shows its site's favicon through the directory server. The server reads
`/favicon.svg` from the site's LAN address by default, using the IPv4 address
in the inventory to avoid a Tailscale DNS result. Set `faviconPath` in
`sites.json` for a different root-relative icon path, or to `null` when the site
has no icon. If an icon cannot be loaded, the card shows initials and the server
logs the failure.

## Workbench idea counts

Cards with unarchived ideas show one compact, rounded pill with open, active
(in-progress) and done counts. Counts use solution ids, exclude archived and unassigned ideas,
and refresh when the directory is loaded. Solutions without ideas have no badge.
Phone-sized screens use smaller solution names and show the counts without their status initials.
The read-only `/idea-counts.json` endpoint reads The Workbench's LAN `/api/ideas`
and returns counts only, never idea titles or bodies. Requests time out after
5 seconds; failures are logged and shown on the page instead of displaying zeros.

## Alternative directory icons

The [tabbed-index](./icon-options/tabbed-index/) set is the active icon in the
directory source. The [connected-sites](./icon-options/connected-sites/) and
[compass](./icon-options/compass/) sets are also saved. Each contains
`favicon.svg`, `favicon-dark.svg`, `favicon-light.svg`, an `apple-touch-icon.svg`
source, and its 180-by-180 `apple-touch-icon.png`.

The other sets are not served or selected automatically. To use one, copy its
5 files over the matching files in `site`, update this note, then follow the
[directory release procedure](../docs/ReleaseCommands.md) when a deployment is
approved. The tabbed index uses the original dark background in Midnight and a
light background in Light. Browser tabs use the fixed theme-specific SVGs; the
shared favicon follows the surrounding page theme in the directory card and
Site Dock. The iPhone and iPad home-screen PNG stays dark in both themes.

## Appearance controls

The Theme group uses pressed buttons, theme icons and a sliding selection fill.
Reduced motion disables the slide. Enter or Space opens the popover and selects
the focused choice. Arrow keys move
between choices; Home and End jump to the first and last. Escape dismisses the
menu and returns focus to its button. Tab or Shift+Tab dismisses it and continues
through the page. Clicking or focusing outside dismisses it without moving focus.
The opaque, square popover uses the current theme's color tokens. The palette
button's accessible name includes the selected preference.

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

The desktop width reference is a centered 1440px border-box outer container with
20px side padding, leaving at most 1400px for content. Header contents and main
content share those edges. `scripts\Test-WebStandard.mjs` checks these bounds at
1280, 1440 and 1920px for the directory, Fit Track, Ferry Tracker, Home Automation,
Team Scoreboard and Web Inventory. The check accounts for scrollbar gutters and
keeps Web Inventory's 240px desktop rail outside its inner content area.

The directory and Ferry Tracker reserve a normal-width desktop scrollbar gutter
even on short pages. Header and main containers both use the remaining layout
width, rather than viewport units, so their edges match and stay fixed when
content starts or stops scrolling. Ferry Tracker keeps thin scrollbars inside
controls and at phone/tablet widths.
