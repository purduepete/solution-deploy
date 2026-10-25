# Directory appearance

The header's custom Theme menu lists System, Light and Midnight. Midnight is the
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

The Theme menu uses radio-menu semantics and a stroke checkmark for the saved choice.
Enter or Space opens the menu and selects the focused choice. Arrow keys move
between choices; Home and End jump to the first and last. Escape dismisses the
menu and returns focus to its button. Tab or Shift+Tab dismisses it and continues
through the page. Clicking or focusing outside dismisses it without moving focus.
The opaque, square menu and its scrollbar use the current theme's color tokens.

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
