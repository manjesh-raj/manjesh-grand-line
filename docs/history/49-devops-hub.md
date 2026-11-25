# DevOps Hub

DevOps Hub is a sidebar module in Work that serves a local project on this Mac and shows it inside Grand Line.
Its first and only project is `devops-atlas`, the DevOps Atlas course: a static Vite build of HTML, CSS and ES modules, cloned at `<firstmate home>/projects/devops-atlas`.

## The design round (2026-11-19)

The scout `grand-line-devops-hub` drew three page layouts on a Lavish board (`data/grand-line-devops-hub/prototype.html`, with `report.md` beside it):

- A, a hero band over the site.
- B, a hero column beside it.
- C, a slim strip over a full-size site, with a centred hero card whenever there is no site to show.

The recommended answers were confirmed:

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
- **A test process must not serve the real clone.** `FirstmateHome` resolves the real home in a self-test process, so the default folder resolves under the process's scratch root instead whenever `ExternalToolGuard.isActive`.
- **The content pane keeps a 32pt slot above a headerless page.** The running strip sits at the page's top edge with no inset of its own, which puts it where other headerless pages start.

## Not done

- "Show that one here" for a busy port (adopting a server some other process already runs for the same site) was left out. The busy-port hero offers Retry and Change Port.
- A project that needs a command (`npm run dev`) would need a managed child process. The model has a `kind` field for it, and nothing else.
- The site keeps its own theme toggle rather than following Grand Line's theme.

## Verification

- `FM_RUN_DEVOPS_HUB_MODEL_TESTS` (headless): the server's rules, the same rules over a real loopback listener, the store, preflight, the runner, the words, the sidebar's marks and badge, the profile settle, and the settings validation.
- `FM_RUN_PAGE_REDESIGNS_TESTS` (window-backed) has a DevOps Hub case: a real click on the project row, a real Start through the hero's button that loads a scratch site into the web view, the strip's Stop, a busy port and a missing folder.
- `FM_DEVOPS_HUB_RENDER_DIR` writes a PNG of the window per state in Daylight and Dusk, and `FM_DEVOPS_HUB_RENDER_SITE` points the running state at a real site.

## DevOps Hub as a page of project cards (2026-11-20)

The first round nested each project under the DevOps Hub row, and the row opened the last project shown.
The second board (`data/grand-line-devops-hub-page/`) drew the hub as a page of its own on Connections' pattern, in three layouts:

- A, Connections' twin: a hero column beside the host card's roomy cards.
- B, bigger preview cards that lead with the site's share image.
- C, a hero band over a table.

The recommended answers were confirmed:

- Layout A.
- A project opens inside the hub page rather than as a pushed view with a route of its own.
- Add Project registers any local folder that has an `index.html` (name, folder, port).
- Coming back to DevOps Hub finds it as it was left this session, and a click on the row while a project shows goes back to the cards.
- No menu on the DevOps Hub row.

### What shipped

- `DevOpsHubController` is now the page that holds two views and switches between them.
  `DevOpsHubCardsController` is the cards: a `HelmHeroColumn` in a `HelmSplitPage` pane, a filter row, and `HelmCardGrid` or `HelmDataTable`.
  `DevOpsHubProjectController` is PR 619's page, with a Projects button on its strip and over its hero card.
- `DevOpsHubHeroWords` and `DevOpsHubCardWords` (`DevOpsHubCardsWords.swift`) are the words, pure and asserted headless.
  The column's verdict follows the sidebar badge's precedence, so the row and the page never disagree.
- The two views are places in the window's Back and Forward history (`WorkspaceHistoryPlace`), so Back steps from a project to the cards.
- A click on a sidebar row that is already lit changes no selection, so it never reached the shell.
  The sidebar now records, at mouse-down, whether the click began on the lit row, and the table's own action reports it (`onReselectModule`).
- `LocalProjectRegistry` gained `add` and `remove`.
  The store seeds devops-atlas only when its file is missing: an emptied list stays empty (GL-21), or removing the last project would bring the seed back on the next launch.
- `fm.devopsHub.lastProject` is no longer read, and is cleared once the window is up.
- The project settings sheet is also the Add Project sheet: a name field, no default folder, the folder checked off the main thread as it is chosen, and a port another project uses refused in both modes.

### Things that bit

- **The share image held the window open.**
  The project view's preview is an `NSImageView`, whose intrinsic size is its image's, and the course's `og.jpg` is 1200pt wide.
  At the default compression resistance (750, above the window's 500) it kept the window at 1513pt whenever the project view was in the hierarchy, hidden or not.
  It was there in PR 619 too, and only the real course showed it, because the suite's fixture site had no share image.
  The preview gives way now, the fixture has a 1200pt `og.png`, and the cards check resizes to 1100 with a running project's view hidden.
  Injected back, the check fails with the window at 1513.
- **A hidden view still holds the window (gotcha (15)).**
  The page deactivates the hidden view's pins as well, so nothing in it has a required path to the window.
- **Long status lines ran under the card's icon column.**
  `HelmCardGrid`'s status pill does not truncate, so "Port 50378 in use by python3 (pid 48211)" drew under the pencil.
  The card keeps to short words, and who holds the port is in the column, the project view and the card's VoiceOver label.
  A stopped project uses the card's quiet detail line ("Not started · last ran 2 hours ago"), the host card's "Last connected" shape.

### Verification

- `FM_RUN_DEVOPS_HUB_MODEL_TESTS` (headless) adds the column's words in every state and their precedence, each card's lines, the filter, add and remove, the emptied store, and Add Project's validation.
- `FM_RUN_PAGE_REDESIGNS_TESTS` drives one row with no children, a real click that opens the cards, a real Start through a card that opens the course, the strip's Projects button, the window's Back, the row's click back to the cards, Stop, a busy port, the pencil's sheet, the band at 1100, and a missing folder.
- `FM_DEVOPS_HUB_RENDER_DIR` now writes ten states per theme: no projects, not started, starting, running with the course, running on the cards, a busy port, a missing folder, three projects, and the narrowest window on the cards and on the course.

## A site's own dialogs, and a site that keeps crashing (full review 2026-11-25, B-04 and B-05)

### B-04

The web view named itself the UI delegate but handled only new-window requests.
WebKit then answered `confirm()` with false and `prompt()` with null, showed nothing for `alert()`, and ignored a file input.
A load that failed after it had started was not handled either, so the page never heard the load end.

- `alert`, `confirm` and `prompt` are `HelmConfirm`, titled "<project> says" with the hub's hue.
  A prompt is a field holding the page's default text.
- A file input opens an `NSOpenPanel` sheet over the window, with files, several only for `multiple`, and folders only when asked for.
- None of them shows under the app lock (`AppLockedSurface.devopsHubSiteDialog`), because a running site keeps running and any of its timers may ask.
  WebKit's own answers then stand.
- `webView(_:didFail:withError:)` ends the wait as the provisional failure does.

### B-05

`webViewWebContentProcessDidTerminate` reloaded the site unconditionally, so a site that crashes its content process on load was reloaded forever.
One ended process is still reloaded.
A second within a minute stops there, and the page shows "This site keeps crashing" in the hero card the hub already uses for its other recoverable states, with Reload, Open in Browser and Stop.
Reload, the strip's Reload and ⌘R start a fresh count, and so does a stop.

### Verification

- `FM_RUN_DEVOPS_HUB_MODEL_TESTS` (headless) drives a real `DevOpsHubWebView` with no window.
  Page script calls `confirm`, `prompt` and `alert`, and the suite reads what the page got back.
  Under the lock nothing shows.
  The `didFail` delegate call ends the wait.
  Terminations are driven through the delegate call WebKit makes, with the view's own clock.
- With the delegate methods renamed away and the reload made unconditional, ten checks fail by name.
- Not verified by a test: the open panel itself, which needs a window and a real file input click.
