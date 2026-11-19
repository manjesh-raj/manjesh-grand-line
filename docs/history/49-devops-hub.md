# DevOps Hub

DevOps Hub is a sidebar module in Work that serves a local project on this Mac and shows it inside Grand Line.
Its first and only project is `devops-atlas`, the DevOps Atlas course: a static Vite build of HTML, CSS and ES modules, cloned at `<firstmate home>/projects/devops-atlas`.

## The design round (2026-11-19)

The scout `grand-line-devops-hub` drew three page layouts on a Lavish board (`data/grand-line-devops-hub/prototype.html`, with `report.md` beside it):

- A, a hero band over the site.
- B, a hero column beside it.
- C, a slim strip over a full-size site, with a centred hero card whenever there is no site to show.

The captain confirmed the recommended answers:

- Layout C.
- A server built into Grand Line rather than `python3 -m http.server`.
- Stopped at launch, with a per-project opt-in to start at launch.
- Operator profile only.
- The DevOps Hub row opens the last project shown.

The smaller defaults (port 7420, the folder under the firstmate home, the `shippingbox` glyph, the site keeping its own theme toggle) were the scout's.

## What shipped

- `LocalStaticServer` serves one folder on 127.0.0.1 from an in-process `NWListener`.
  It answers GET and HEAD only, refuses any dot-prefixed path component (a clone's `.git`), refuses a path or symlink out of the folder (`WebNavigationPolicy.allowsFileURL`), answers 421 to a `Host` that is not its own address and port (DNS rebinding), and sends `Cache-Control: no-cache` with an `ETag`.
- `LocalProjectRegistry` (in `LocalProjectRunner.swift`) owns every project's state, outside the page, because the page mounts lazily (GL-37) and the sidebar's dot, its menu and a launch-time start all need the state first.
- `LocalProjectStore` is `local-projects.json` under `AppPaths.dataRoot()`, with `FM_LOCAL_PROJECTS_FILE`, GL-01's backup and passthrough of unknown keys.
- `DevOpsHubController` is the page, `DevOpsHubWords` its words as pure logic, `DevOpsHubWebView` the web view, and `DevOpsHubSettingsSheet` the Project settings sheet.
- The sidebar draws a project with the session row's cell, so the two kinds of child row cannot drift apart.

## Why in-process and not `python3 -m http.server`

Measured during the scout, on this Mac:

- `python3 -m http.server` binds every interface by default, so a forgotten `--bind` serves the private repo to the LAN.
- It serves directory listings and the `.git` folder.
- It does not check `Host`.
- A crash or force quit of Grand Line would leave it running and holding the port, so the next Start would fail against our own orphan.
- A Finder-launched app finds `/usr/bin/python3`, the Command Line Tools stub, which raises an install dialog on a Mac without the tools.
- A long-lived managed child would have been a second exception to `Subprocess.swift`'s bounded runs.

A spike served the real course from an `NWListener` into a `WKWebView` over `http://127.0.0.1` with no App Transport Security key, ES modules included.
A foreign `Host` got 421 and the LAN address was unreachable.
With `python3 -m http.server` already listening on all interfaces, binding 127.0.0.1 on the same port fails with `EADDRINUSE`, which is how a busy port is detected.

## Things that bit

- **A vertical `NSStackView` does not stretch its arranged views.** The page first set `alignment = .width` on its hero column, and the hero rendered 268pt wide, centred, inside a 720pt column. Both cards are pinned to the column's width now.
- **Storage belongs to the address.** The course keeps its progress in `localStorage`, which WebKit keys by origin, port included. The port is therefore fixed rather than "the next free one", and each project gets its own persistent `WKWebsiteDataStore` (by identifier on macOS 14 and later, the default store on 13). Every other web view in the app stays `.nonPersistent()`.
- **A test process must not serve the captain's clone.** `FirstmateHome` resolves the real home in a self-test process, so the default folder resolves under the process's scratch root instead whenever `ExternalToolGuard.isActive`.
- **The content pane keeps a 32pt slot above a headerless page.** The running strip sits at the page's top edge with no inset of its own, which puts it where other headerless pages start.

## Not done

- "Show that one here" for a busy port (adopting a server some other process already runs for the same site) was left out. The busy-port hero offers Retry and Change Port.
- A project that needs a command (`npm run dev`) would need a managed child process. The model has a `kind` field for it, and nothing else.
- The site keeps its own theme toggle rather than following Grand Line's theme.

## Verification

- `FM_RUN_DEVOPS_HUB_MODEL_TESTS` (headless): the server's rules, the same rules over a real loopback listener, the store, preflight, the runner, the words, the sidebar's marks and badge, the profile settle, and the settings validation.
- `FM_RUN_PAGE_REDESIGNS_TESTS` (window-backed) has a DevOps Hub case: a real click on the project row, a real Start through the hero's button that loads a scratch site into the web view, the strip's Stop, a busy port and a missing folder.
- `FM_DEVOPS_HUB_RENDER_DIR` writes a PNG of the window per state in Daylight and Dusk, and `FM_DEVOPS_HUB_RENDER_SITE` points the running state at a real site.
