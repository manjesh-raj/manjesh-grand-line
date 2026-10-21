# Grand Line feature inventory

This is the list of every feature Grand Line has, and where each one lives in the modular workspace shell.
It exists for one rule the captain set for the migration: no feature may be lost.

The migration replaces the floating bar, the space pills, the drill header, the quick-access squares and the ⌘⇧D map with a sidebar, a window toolbar, an inspector and a status line.
It regroups 29 destinations into 18 sidebar items: Home, then 17 modules in four groups.
The plan is section 4 and section 5.8 of the full review, and the captain's modular workspace prototype (Version 2) is the visual reference.
`native/Sources/GrandLine/ModuleTable.swift` is the destination-level half of the same plan.

## How this file is checked

`FM_RUN_FEATURE_INVENTORY_TESTS=1 .build/debug/GrandLine` runs `FeatureInventorySelfTest`, which is a pure-logic suite in CI's blocking lane.
It fails in four situations:

- **A feature the code has has no row.** Most sections below are code-backed: the suite enumerates them from the live enums, from the real main menu, from the shortcut catalog, or from a source scan, and compares that list with the rows here in both directions.
- **A row names something the code no longer has.** In a code-backed section that is a stale id. In the hand-written sections at the end, every row carries an Evidence cell (a file and a token), and the row fails when that token is gone from that file outside a comment.
- **A row has no real home.** The New shell cell must start with a sidebar module or one of the shell places (Sidebar, Toolbar, Status line, Inspector, Main menu, Window, Menu bar extra, System, Navigator, Every module). A `Module › Child` reference must name a child that module declares in `WorkspaceModule.children`.
- **A row says a feature is dropped.** The New shell cell may say what replaces a piece of chrome, but never that the feature itself is removed.

When the suite fails on a missing row, it prints the row to add.
When a later stage moves a feature, update its New shell cell and, for an evidence row, point the Evidence cell at the new code.
Deleting the old bar in step 5 is meant to fail every chrome row until each one names the new shell's code.

## Columns

- **ID** is the stable key the suite matches on. The prefix is the family.
- **Feature** says what the captain can do.
- **Today** says where it is now and how it is reached. For page actions it lists the selectors, and the suite checks that list exactly.
- **New shell** says where it lives after the migration. "Unchanged" means the feature itself does not move; it is hosted inside the module named first.
- **Evidence** is only for the hand-written sections: `File.swift` `token`, several separated by `;`.

## What the inventory does not see

A page action wired through a closure rather than a selector (a `HoverHighlightView.onClick`, a card's tap handler) has no stable name to enumerate.
Those are covered by their page's destination row, its surface rows and its Home card row rather than one by one.
Dialog Return and Escape buttons are part of the dialog they belong to and are not listed separately.

## Decisions taken

- The prototype's Snippets caption that mentioned ⌘; reads "run in any terminal tab" when Connections › Snippets is built, because the real app has no ⌘; shortcut. The real Snippets empty state already says "send it to any terminal tab".
- The big page title is dropped on Connections and Console only. Home and the other modules keep their subtitles.
- There is no Today page and no calendar integration anywhere, and neither comes back.
- Honest state stays: a number that is not known yet is a dash with "scanning", never 0, and a failed read keeps the last good value and says when.
- **The bell stays, as a toolbar button.** The prototype removed it together with the Inbox row, but the real Notification Center holds lasting reports that have no other home (backup and persistence failures, crew decisions, failing checks). A notifications button sits in the toolbar's trailing cluster, where the review's plan puts it, and there is no Inbox row in the sidebar. The captain kept this default.
- **The light/dark toggle stays, in the toolbar.** The prototype follows the system appearance and has no toggle, but the toggle is a real feature with a real preference behind it, so it sits in the toolbar's trailing cluster. The captain kept this default.

## Destinations

One row per `RailDestination`. The route id stays the deep-link id after the consolidation, and the New shell cell must agree with `ModuleTable`.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `dest.automation` | Automation page | Engineering space card; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Setup › Automation |  |
| `dest.bootstrap` | Bootstrap page | Engineering space card; Updates' not-installed rows; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Setup › Setup steps |  |
| `dest.codePreview` | Code Preview page | Stores space card; quick-access square (default pin); File > Run Snippet ⌘R and Hide Snippet List ⌘B; ⌘K snippets; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Code (Workbench group) |  |
| `dest.commandLibrary` | DevOps Commands page | Command space card; ⌘K commands; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Connections › Commands |  |
| `dest.console` | Console page | Command space card and Home's Claude card; quick-access square (default pin); ⌃⌘1-9 and Next/Previous Session; Hosts' Connect; ⌘K sessions and hosts; Find in Terminal; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Console (its own sidebar item in Work; live sessions are its sidebar children; no page title, per the captain) |  |
| `dest.dictation` | Dictation page | Stores space card; the dictation hotkey; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Dictation (Workbench group) |  |
| `dest.docs` | Docs page | Stores space card; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Knowledge › Playbook |  |
| `dest.githubSync` | GitHub Sync page | Engineering space card; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Setup › GitHub sync |  |
| `dest.health` | Health page | Home's Health card; Operations space card; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Health (Observe group; its state also shows in the status line) |  |
| `dest.homeCanvas` | Home page | Launch landing; the Home space pill and Go > Home (⌘1); every drill page's back button; the bar's logo | Home (top of the sidebar, above the four groups; the launch landing) |  |
| `dest.hosts` | Hosts page | Operations space card; quick-access square (default pin); Hosts menu (Show Hosts ⌃⌘S, Quick Connect, Manage SSH Keys ⇧⌘K, Manage Snippets ⌥⌘P); ⌘K hosts; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Connections › Hosts (SSH Keys and Snippets are the next two tabs; no page title, per the captain) |  |
| `dest.kubernetes` | Kubernetes page | Operations space card; Console's Tail Logs button; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Kubernetes (Observe group) |  |
| `dest.logAnalyzer` | Log Analyzer page | Operations space card; Log Analyzer menu (Open ⇧⌘L, Analyze Clipboard); Console's Analyze Logs button; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Logs (Observe group) |  |
| `dest.notebook` | Notebook page | Stores space card; ⌘K notebook pages; the New Note App Intent appends to today's daily note; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Knowledge › Notebook |  |
| `dest.overview` | Fleet page | Home's Fleet and Morning briefing cards; the fleet-task notification's Show in app; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Crew › In flight (its Log tab becomes Crew › Log and its decisions Crew › Needs you) |  |
| `dest.poneglyph` | Poneglyph page | Stores space card; quick-access square (default pin); ⌘K Lock Poneglyph; the Poneglyph menu bar extra; the Copy Credential App Intent; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Secrets › Poneglyph (the lock state also shows on the sidebar item) |  |
| `dest.postmortems` | Postmortems page | Stores space card; ⌘K postmortems; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Knowledge › Postmortems |  |
| `dest.readingList` | Reading List page | Stores space card; ⌘K saved links; ⌥Space quick capture files links here; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Knowledge › Reading list |  |
| `dest.review` | Review page | Home's Merge queue card; the pr-ready notification's Show in app; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Crew › Review (ready PRs also fill Crew › Merge queue) |  |
| `dest.runbooks` | Runbooks page | Stores space card; ⌘K runbooks; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Knowledge › Runbooks |  |
| `dest.schedules` | Schedules page | Operations space card; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Schedules (Observe group) |  |
| `dest.settings` | Settings page | App menu Settings… ⌘,; Engineering space card; the avatar menu; ⌘K Settings; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Settings (Machine group; its eight categories become sidebar children) |  |
| `dest.shift` | Tasks page | Command space card; quick-access square (default pin); Tasks menu; ⌘N fallback; task and follow-up notifications; the Tasks widget; the New Task App Intent; the Tasks menu bar extra; ⌘K tasks; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Tasks (Work group; projects and smart views become sidebar children) |  |
| `dest.stickyBoard` | Sticky Board page | Stores space card; quick-access square (default pin); ⌘K sticky notes; the Sticky note widget; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Sticky Board (Workbench group) |  |
| `dest.strawHat` | Straw Hat Pirates page | Command space card; quick-access square (default pin); ⌘K Ask the Crew; the Ask the Crew App Intent; the Straw Hat menu bar extra; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Crew › Ask the crew |  |
| `dest.tools` | Tools page | Stores space card; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Tools (Workbench group) |  |
| `dest.updates` | Updates page | Engineering space card; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Setup › Updates |  |
| `dest.vault` | Vault page | Stores space card; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Secrets › Automic Vault |  |
| `dest.whiteboard` | Whiteboard page | Stores space card; File > Copy Board as Image; Go menu item, ⌘K "Switch to", Recents, the ⌘⇧D map | Whiteboard (Workbench group) |  |

## Space pills

The five pills that filter Home's card grid today.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `space.command` | Command space | Command space pill (⌘2): Console, Tasks, Merge queue, DevOps Commands, Straw Hat cards | Sidebar (Work group: Tasks, Crew, Connections, Console) |  |
| `space.engineering` | Engineering space | Engineering space pill (⌘5): the four Setup cards and Settings | Sidebar (Machine group: Setup and Settings) |  |
| `space.operations` | Operations space | Operations space pill (⌘3): Hosts, Logs, Kubernetes, Health, Schedules cards | Sidebar (Observe group: Kubernetes, Logs, Health, Schedules; Hosts moves to Connections) |  |
| `space.overview` | Home space | Home space pill (⌘1): Home's five-card canvas | Home (its five default cards are this space's cards) |  |
| `space.stores` | Stores space | Stores space pill (⌘4): the reference shelf's cards | Sidebar (Workbench group, plus Knowledge and Secrets in Work) |  |

## Home canvas cards

One row per `DaylightModule`. Every card stays available in Home's configurable set.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `home.automation` | Automation card | Engineering canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.bootstrap` | Bootstrap card | Engineering canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.briefing` | Morning briefing card | Home canvas only | Home (a card in the configurable set, on by default) |  |
| `home.claudeStatus` | Claude card | Home canvas only | Home (a card in the configurable set, on by default) |  |
| `home.codePreview` | Code Preview card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.commandLibrary` | DevOps Commands card | Command canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.console` | Console card | Command canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.dictation` | Dictation card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.docs` | Docs card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.fleet` | Fleet card | Home canvas only | Home (a card in the configurable set, on by default) |  |
| `home.githubSync` | GitHub Sync card | Engineering canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.health` | Health card | Home canvas and the Operations canvas | Home (a card in the configurable set, on by default) |  |
| `home.hosts` | Hosts card | Operations canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.kubernetes` | Kubernetes card | Operations canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.logAnalyzer` | Log Analyzer card | Operations canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.mergeQueue` | Merge queue card | Home canvas and the Command canvas | Home (a card in the configurable set, on by default) |  |
| `home.notebook` | Notebook card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.poneglyph` | Poneglyph card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.postmortems` | Postmortems card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.readingList` | Reading List card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.runbooks` | Runbooks card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.schedules` | Schedules card | Operations canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.settings` | Settings card | Engineering canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.stickyBoard` | Sticky Board card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.strawHat` | Straw Hat Pirates card | Command canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.tasks` | Tasks card | Command canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.tools` | Tools card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.updates` | Updates card | Engineering canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.vault` | Vault card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |
| `home.whiteboard` | Whiteboard card | Stores canvas | Home (a card in the configurable set, available in Customize, off by default) |  |

## Main menu items

Every actionable item in the real menu bar, read from `AppDelegate.buildMenu(installing: false)`.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `menu.App/About Grand Line` | App > About Grand Line | no shortcut | Main menu › App (unchanged) |  |
| `menu.App/Hide Grand Line` | App > Hide Grand Line | shortcut ⌘H | Main menu › App (unchanged) |  |
| `menu.App/Hide Others` | App > Hide Others | shortcut ⌥⌘H | Main menu › App (unchanged) |  |
| `menu.App/Quit Grand Line` | App > Quit Grand Line | shortcut ⌘Q | Main menu › App (unchanged) |  |
| `menu.App/Services` | App > Services | no shortcut | Main menu › App (unchanged) |  |
| `menu.App/Settings…` | App > Settings… | shortcut ⌘, | Main menu › App (unchanged; selects the Settings module) |  |
| `menu.App/Show All` | App > Show All | no shortcut | Main menu › App (unchanged) |  |
| `menu.Edit/Clipboard History…` | Edit > Clipboard History… | shortcut ⇧⌘V | Main menu › Edit (unchanged) |  |
| `menu.Edit/Copy` | Edit > Copy | shortcut ⌘C | Main menu › Edit (unchanged) |  |
| `menu.Edit/Cut` | Edit > Cut | shortcut ⌘X | Main menu › Edit (unchanged) |  |
| `menu.Edit/Find in Terminal` | Edit > Find in Terminal | no shortcut | Main menu › Edit (unchanged) |  |
| `menu.Edit/Find…` | Edit > Find… | shortcut ⌘F | Main menu › Edit (unchanged) |  |
| `menu.Edit/Paste` | Edit > Paste | shortcut ⌘V | Main menu › Edit (unchanged) |  |
| `menu.Edit/Search…` | Edit > Search… | shortcut ⌘K | Main menu › Edit (unchanged; opens the toolbar search's ⌘K palette) |  |
| `menu.Edit/Select All` | Edit > Select All | shortcut ⌘A | Main menu › Edit (unchanged) |  |
| `menu.File/Capture Screen Region…` | File > Capture Screen Region… | shortcut ⇧⌘S | Main menu › File (unchanged) |  |
| `menu.File/Copy Board as Image` | File > Copy Board as Image | no shortcut | Main menu › File (unchanged) |  |
| `menu.File/Hide Snippet List` | File > Hide Snippet List | shortcut ⌘B | Main menu › File (unchanged) |  |
| `menu.File/New Task…` | File > New Task… | shortcut ⌘N | Main menu › File (unchanged) |  |
| `menu.File/Run Snippet` | File > Run Snippet | shortcut ⌘R | Main menu › File (unchanged) |  |
| `menu.Go/All Destinations…` | Go > All Destinations… | shortcut ⇧⌘D | Main menu › Go (reveals and focuses the sidebar, which is the whole map) |  |
| `menu.Go/Automation` | Go > Automation | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Setup › Automation) |  |
| `menu.Go/Bootstrap` | Go > Bootstrap | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Setup › Setup steps) |  |
| `menu.Go/Code Preview` | Go > Code Preview | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Code) |  |
| `menu.Go/Command` | Go > Command | shortcut ⌘2 | Main menu › Go (⌘1-⌘6 select the first six sidebar items - Home, Tasks, Crew, Connections, Console, Knowledge - and the space names become sidebar sections) |  |
| `menu.Go/Console` | Go > Console | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Console) |  |
| `menu.Go/DevOps Commands` | Go > DevOps Commands | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Connections › Commands) |  |
| `menu.Go/Dictation` | Go > Dictation | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Dictation) |  |
| `menu.Go/Docs` | Go > Docs | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Knowledge › Playbook) |  |
| `menu.Go/Engineering` | Go > Engineering | shortcut ⌘5 | Main menu › Go (⌘1-⌘6 select the first six sidebar items - Home, Tasks, Crew, Connections, Console, Knowledge - and the space names become sidebar sections) |  |
| `menu.Go/Fleet` | Go > Fleet | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Crew › In flight) |  |
| `menu.Go/GitHub Sync` | Go > GitHub Sync | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Setup › GitHub sync) |  |
| `menu.Go/Health` | Go > Health | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Health) |  |
| `menu.Go/Home` | Go > Home | shortcut ⌘1 | Main menu › Go (⌘1-⌘6 select the first six sidebar items - Home, Tasks, Crew, Connections, Console, Knowledge - and the space names become sidebar sections) |  |
| `menu.Go/Hosts` | Go > Hosts | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Connections › Hosts) |  |
| `menu.Go/Kubernetes` | Go > Kubernetes | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Kubernetes) |  |
| `menu.Go/Log Analyzer` | Go > Log Analyzer | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Logs) |  |
| `menu.Go/Notebook` | Go > Notebook | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Knowledge › Notebook) |  |
| `menu.Go/Operations` | Go > Operations | shortcut ⌘3 | Main menu › Go (⌘1-⌘6 select the first six sidebar items - Home, Tasks, Crew, Connections, Console, Knowledge - and the space names become sidebar sections) |  |
| `menu.Go/Poneglyph` | Go > Poneglyph | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Secrets › Poneglyph) |  |
| `menu.Go/Postmortems` | Go > Postmortems | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Knowledge › Postmortems) |  |
| `menu.Go/Reading List` | Go > Reading List | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Knowledge › Reading list) |  |
| `menu.Go/Review` | Go > Review | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Crew › Review) |  |
| `menu.Go/Runbooks` | Go > Runbooks | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Knowledge › Runbooks) |  |
| `menu.Go/Schedules` | Go > Schedules | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Schedules) |  |
| `menu.Go/Settings` | Go > Settings | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Settings) |  |
| `menu.Go/Sticky Board` | Go > Sticky Board | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Sticky Board) |  |
| `menu.Go/Stores` | Go > Stores | shortcut ⌘4 | Main menu › Go (⌘1-⌘6 select the first six sidebar items - Home, Tasks, Crew, Connections, Console, Knowledge - and the space names become sidebar sections) |  |
| `menu.Go/Straw Hat Pirates` | Go > Straw Hat Pirates | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Crew › Ask the crew) |  |
| `menu.Go/Tasks` | Go > Tasks | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Tasks) |  |
| `menu.Go/Toggle Sidebar` | Go > Toggle Sidebar | shortcut ⌥⌘S | Main menu › Go (toggles the workspace sidebar) |  |
| `menu.Go/Tools` | Go > Tools | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Tools) |  |
| `menu.Go/Updates` | Go > Updates | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Setup › Updates) |  |
| `menu.Go/Vault` | Go > Vault | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Secrets › Automic Vault) |  |
| `menu.Go/Whiteboard` | Go > Whiteboard | no shortcut | Main menu › Go (lists the sidebar modules; this item opens Whiteboard) |  |
| `menu.Help/Keyboard Shortcuts…` | Help > Keyboard Shortcuts… | shortcut ⇧⌘/ | Main menu › Help (unchanged) |  |
| `menu.Help/Manual Checks` | Help > Manual Checks | no shortcut | Main menu › Help (unchanged) |  |
| `menu.Hosts/Manage Snippets…` | Hosts > Manage Snippets… | shortcut ⌥⌘P | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Manage SSH Keys…` | Hosts > Manage SSH Keys… | shortcut ⇧⌘K | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/New Host…` | Hosts > New Host… | shortcut ⌃⌘N | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/New Snippet…` | Hosts > New Snippet… | shortcut ⌥⌘N | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/New SSH Key…` | Hosts > New SSH Key… | shortcut ⇧⌘N | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Next Session` | Hosts > Next Session | shortcut ⌘] | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Previous Session` | Hosts > Previous Session | shortcut ⌘[ | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Quick Connect` | Hosts > Quick Connect | no shortcut | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Session 1` | Hosts > Session 1 | shortcut ⌃⌘1 | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Session 2` | Hosts > Session 2 | shortcut ⌃⌘2 | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Session 3` | Hosts > Session 3 | shortcut ⌃⌘3 | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Session 4` | Hosts > Session 4 | shortcut ⌃⌘4 | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Session 5` | Hosts > Session 5 | shortcut ⌃⌘5 | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Session 6` | Hosts > Session 6 | shortcut ⌃⌘6 | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Session 7` | Hosts > Session 7 | shortcut ⌃⌘7 | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Session 8` | Hosts > Session 8 | shortcut ⌃⌘8 | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Session 9` | Hosts > Session 9 | shortcut ⌃⌘9 | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Hosts/Show Hosts` | Hosts > Show Hosts | shortcut ⌃⌘S | Main menu › Hosts (unchanged; its items target Connections and Console) |  |
| `menu.Log Analyzer/Analyze Clipboard` | Log Analyzer > Analyze Clipboard | no shortcut | Main menu › Log Analyzer (unchanged; targets Logs) |  |
| `menu.Log Analyzer/Copy Analysis` | Log Analyzer > Copy Analysis | shortcut ⇧⌘C | Main menu › Log Analyzer (unchanged; targets Logs) |  |
| `menu.Log Analyzer/Create RCA` | Log Analyzer > Create RCA | shortcut ⇧⌘A | Main menu › Log Analyzer (unchanged; targets Logs) |  |
| `menu.Log Analyzer/Investigate Further` | Log Analyzer > Investigate Further | shortcut ⇧⌘I | Main menu › Log Analyzer (unchanged; targets Logs) |  |
| `menu.Log Analyzer/Open Log Analyzer` | Log Analyzer > Open Log Analyzer | shortcut ⇧⌘L | Main menu › Log Analyzer (unchanged; targets Logs) |  |
| `menu.Log Analyzer/Send Top Command to Terminal` | Log Analyzer > Send Top Command to Terminal | shortcut ⇧⌘T | Main menu › Log Analyzer (unchanged; targets Logs) |  |
| `menu.Tasks/Capture…` | Tasks > Capture… | shortcut ⌥Space | Main menu › Tasks (unchanged) |  |
| `menu.Tasks/New Follow-up…` | Tasks > New Follow-up… | shortcut ⇧⌘F | Main menu › Tasks (unchanged) |  |
| `menu.Tasks/New Project…` | Tasks > New Project… | no shortcut | Main menu › Tasks (unchanged) |  |
| `menu.Tasks/New Task…` | Tasks > New Task… | no shortcut | Main menu › Tasks (unchanged) |  |
| `menu.Tasks/Weekly Review` | Tasks > Weekly Review | no shortcut | Main menu › Tasks (unchanged) |  |
| `menu.Window/Bring All to Front` | Window > Bring All to Front | no shortcut | Main menu › Window (unchanged) |  |
| `menu.Window/Minimize` | Window > Minimize | shortcut ⌘M | Main menu › Window (unchanged) |  |
| `menu.Window/Zoom` | Window > Zoom | no shortcut | Main menu › Window (unchanged) |  |

## Keyboard shortcuts

The Help menu's shortcut catalog: every menu chord, plus the configurable terminal and dictation bindings.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `key.dictation` | Dictation hotkey | system-wide; configurable on the Dictation page | System (global hotkey, unchanged; configured on Dictation) |  |
| `key.terminal.closePane` | Terminal shortcut: Close pane | Console tabs and panes; configurable in Settings > Terminal | Console (unchanged; still recorded in Settings › Terminal) |  |
| `key.terminal.focusNextPane` | Terminal shortcut: Focus next pane | Console tabs and panes; configurable in Settings > Terminal | Console (unchanged; still recorded in Settings › Terminal) |  |
| `key.terminal.focusPreviousPane` | Terminal shortcut: Focus previous pane | Console tabs and panes; configurable in Settings > Terminal | Console (unchanged; still recorded in Settings › Terminal) |  |
| `key.terminal.nextTab` | Terminal shortcut: Next tab | Console tabs and panes; configurable in Settings > Terminal | Console (unchanged; still recorded in Settings › Terminal) |  |
| `key.terminal.previousTab` | Terminal shortcut: Previous tab | Console tabs and panes; configurable in Settings > Terminal | Console (unchanged; still recorded in Settings › Terminal) |  |
| `key.terminal.splitDown` | Terminal shortcut: Split down | Console tabs and panes; configurable in Settings > Terminal | Console (unchanged; still recorded in Settings › Terminal) |  |
| `key.terminal.splitLeft` | Terminal shortcut: Split left | Console tabs and panes; configurable in Settings > Terminal | Console (unchanged; still recorded in Settings › Terminal) |  |
| `key.terminal.splitRight` | Terminal shortcut: Split right | Console tabs and panes; configurable in Settings > Terminal | Console (unchanged; still recorded in Settings › Terminal) |  |
| `key.terminal.zoomPane` | Terminal shortcut: Zoom pane | Console tabs and panes; configurable in Settings > Terminal | Console (unchanged; still recorded in Settings › Terminal) |  |
| `key.⇧⌘/` | ⇧⌘/ - Keyboard Shortcuts… | Help menu | Main menu › Help (unchanged chord) |  |
| `key.⇧⌘A` | ⇧⌘A - Create RCA | Log Analyzer menu | Main menu › Log Analyzer (unchanged chord) |  |
| `key.⇧⌘C` | ⇧⌘C - Copy Analysis | Log Analyzer menu | Main menu › Log Analyzer (unchanged chord) |  |
| `key.⇧⌘D` | ⇧⌘D - All Destinations… | Go menu | Sidebar (reveals and focuses the sidebar, which is the whole map) |  |
| `key.⇧⌘F` | ⇧⌘F - New Follow-up… | Tasks menu | Main menu › Tasks (unchanged chord) |  |
| `key.⇧⌘I` | ⇧⌘I - Investigate Further | Log Analyzer menu | Main menu › Log Analyzer (unchanged chord) |  |
| `key.⇧⌘K` | ⇧⌘K - Manage SSH Keys… | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⇧⌘L` | ⇧⌘L - Open Log Analyzer | Log Analyzer menu | Main menu › Log Analyzer (unchanged chord) |  |
| `key.⇧⌘N` | ⇧⌘N - New SSH Key… | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⇧⌘S` | ⇧⌘S - Capture Screen Region… | File menu | Main menu › File (unchanged chord) |  |
| `key.⇧⌘T` | ⇧⌘T - Send Top Command to Terminal | Log Analyzer menu | Main menu › Log Analyzer (unchanged chord) |  |
| `key.⇧⌘V` | ⇧⌘V - Clipboard History… | Edit menu | Main menu › Edit (unchanged chord) |  |
| `key.⌃⌘1` | ⌃⌘1 - Session 1 | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘2` | ⌃⌘2 - Session 2 | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘3` | ⌃⌘3 - Session 3 | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘4` | ⌃⌘4 - Session 4 | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘5` | ⌃⌘5 - Session 5 | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘6` | ⌃⌘6 - Session 6 | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘7` | ⌃⌘7 - Session 7 | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘8` | ⌃⌘8 - Session 8 | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘9` | ⌃⌘9 - Session 9 | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘N` | ⌃⌘N - New Host… | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌃⌘S` | ⌃⌘S - Show Hosts | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌘,` | ⌘, - Settings… | Grand Line menu | Main menu › App (unchanged chord) |  |
| `key.⌘1` | ⌘1 - Home | Go menu | Main menu › Go (now selects a sidebar module; see the Go menu rows) |  |
| `key.⌘2` | ⌘2 - Command | Go menu | Main menu › Go (now selects a sidebar module; see the Go menu rows) |  |
| `key.⌘3` | ⌘3 - Operations | Go menu | Main menu › Go (now selects a sidebar module; see the Go menu rows) |  |
| `key.⌘4` | ⌘4 - Stores | Go menu | Main menu › Go (now selects a sidebar module; see the Go menu rows) |  |
| `key.⌘5` | ⌘5 - Engineering | Go menu | Main menu › Go (now selects a sidebar module; see the Go menu rows) |  |
| `key.⌘[` | ⌘[ - Previous Session | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌘]` | ⌘] - Next Session | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌘A` | ⌘A - Select All | Edit menu | Main menu › Edit (unchanged chord) |  |
| `key.⌘B` | ⌘B - Hide Snippet List | File menu | Main menu › File (unchanged chord) |  |
| `key.⌘C` | ⌘C - Copy | Edit menu | Main menu › Edit (unchanged chord) |  |
| `key.⌘F` | ⌘F - Find… | Edit menu | Main menu › Edit (unchanged chord) |  |
| `key.⌘H` | ⌘H - Hide Grand Line | Grand Line menu | Main menu › App (unchanged chord) |  |
| `key.⌘K` | ⌘K - Search… | Edit menu | Main menu › Edit (unchanged chord) |  |
| `key.⌘M` | ⌘M - Minimize | Window menu | Main menu › Window (unchanged chord) |  |
| `key.⌘N` | ⌘N - New Task… | File menu | Main menu › File (unchanged chord) |  |
| `key.⌘Q` | ⌘Q - Quit Grand Line | Grand Line menu | Main menu › App (unchanged chord) |  |
| `key.⌘R` | ⌘R - Run Snippet | File menu | Main menu › File (unchanged chord) |  |
| `key.⌘V` | ⌘V - Paste | Edit menu | Main menu › Edit (unchanged chord) |  |
| `key.⌘X` | ⌘X - Cut | Edit menu | Main menu › Edit (unchanged chord) |  |
| `key.⌥Space` | ⌥Space - Capture… | Tasks menu | Main menu › Tasks (unchanged chord) |  |
| `key.⌥⌘H` | ⌥⌘H - Hide Others | Grand Line menu | Main menu › App (unchanged chord) |  |
| `key.⌥⌘N` | ⌥⌘N - New Snippet… | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌥⌘P` | ⌥⌘P - Manage Snippets… | Hosts menu | Main menu › Hosts (unchanged chord) |  |
| `key.⌥⌘S` | ⌥⌘S - Toggle Sidebar | Go menu | Sidebar (show or hide the workspace sidebar) |  |

## Command palette

The ⌘K providers registered in `main.swift` and the action provider's verbs. "Switch to X" exists for every destination and is covered by the destination rows.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `palette.action.All Destinations…` | ⌘K verb: All Destinations… | ⌘K palette, Actions group | Toolbar (⌘K palette verb; now reveals the sidebar map) |  |
| `palette.action.Analyze Clipboard` | ⌘K verb: Analyze Clipboard | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.Ask the Crew` | ⌘K verb: Ask the Crew | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.Find in Terminal` | ⌘K verb: Find in Terminal | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.Lock Poneglyph` | ⌘K verb: Lock Poneglyph | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.Manage Snippets` | ⌘K verb: Manage Snippets | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.Manage SSH Keys` | ⌘K verb: Manage SSH Keys | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New Code Snippet` | ⌘K verb: New Code Snippet | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New Credential…` | ⌘K verb: New Credential… | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New Follow-up…` | ⌘K verb: New Follow-up… | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New Host…` | ⌘K verb: New Host… | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New Project…` | ⌘K verb: New Project… | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New Schedule…` | ⌘K verb: New Schedule… | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New Snippet…` | ⌘K verb: New Snippet… | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New SSH Key…` | ⌘K verb: New SSH Key… | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New Sticky Note` | ⌘K verb: New Sticky Note | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.New Task…` | ⌘K verb: New Task… | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.Open Log Analyzer` | ⌘K verb: Open Log Analyzer | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.Quick Connect` | ⌘K verb: Quick Connect | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.Settings` | ⌘K verb: Settings | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.action.Weekly Review` | ⌘K verb: Weekly Review | ⌘K palette, Actions group | Toolbar (⌘K palette verb, unchanged) |  |
| `palette.provider.UnifiedSearchActionProvider` | ⌘K searches app verbs and Switch to every destination | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |
| `palette.provider.UnifiedSearchCommandProvider` | ⌘K searches saved DevOps commands (send to the terminal) | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |
| `palette.provider.UnifiedSearchDocsProvider` | ⌘K searches runbooks and postmortems | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |
| `palette.provider.UnifiedSearchHostProvider` | ⌘K searches saved hosts (connect) | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |
| `palette.provider.UnifiedSearchNotebookProvider` | ⌘K searches notebook pages | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |
| `palette.provider.UnifiedSearchReadingListProvider` | ⌘K searches saved links | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |
| `palette.provider.UnifiedSearchSessionProvider` | ⌘K searches live sessions (switch into one) | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |
| `palette.provider.UnifiedSearchShiftProvider` | ⌘K searches tasks, follow-ups and projects | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |
| `palette.provider.UnifiedSearchSnippetProvider` | ⌘K searches code snippets | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |
| `palette.provider.UnifiedSearchStickyNoteProvider` | ⌘K searches sticky notes | ⌘K palette (Edit > Search…, the bar's search pill) | Toolbar (the search field opens the same ⌘K palette; this provider is unchanged) |  |

## Deep links

The shell's public routes, the notification categories and buttons, the App Intents and the widgets.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `link.intent.GrandLineAskCrewIntent` | App Intent: Ask the Crew | Shortcuts, Spotlight, Siri | System (Shortcuts, unchanged) |  |
| `link.intent.GrandLineCopyCredentialIntent` | App Intent: Copy Credential | Shortcuts, Spotlight, Siri | System (Shortcuts, unchanged) |  |
| `link.intent.GrandLineNewNoteIntent` | App Intent: New Note (appends to a Notebook page) | Shortcuts, Spotlight, Siri | System (Shortcuts, unchanged) |  |
| `link.intent.GrandLineNewTaskIntent` | App Intent: New Task | Shortcuts, Spotlight, Siri | System (Shortcuts, unchanged) |  |
| `link.intent.GrandLineStartFocusTimerIntent` | App Intent: Start Focus Timer | Shortcuts, Spotlight, Siri | System (Shortcuts, unchanged) |  |
| `link.notification-action.fm.action.merge` | Notification button "Merge" | Notification Center banner action | System (Notification Center, unchanged; an opening button routes through the Navigator) |  |
| `link.notification-action.fm.action.open-fleet-task` | Notification button "Open task" | Notification Center banner action | System (Notification Center, unchanged; an opening button routes through the Navigator) |  |
| `link.notification-action.fm.action.open-pr` | Notification button "Open PR" | Notification Center banner action | System (Notification Center, unchanged; an opening button routes through the Navigator) |  |
| `link.notification-action.fm.action.open-shift-follow-up` | Notification button "Open follow-up" | Notification Center banner action | System (Notification Center, unchanged; an opening button routes through the Navigator) |  |
| `link.notification-action.fm.action.open-shift-task` | Notification button "Open task" | Notification Center banner action | System (Notification Center, unchanged; an opening button routes through the Navigator) |  |
| `link.notification-action.fm.action.show-in-app` | Notification button "Show in app" | Notification Center banner action | System (Notification Center, unchanged; an opening button routes through the Navigator) |  |
| `link.notification-action.fm.action.snooze-follow-up-1h` | Notification button "Snooze 1h" | Notification Center banner action | System (Notification Center, unchanged; an opening button routes through the Navigator) |  |
| `link.notification.fm.category.fleet-task` | Notification category fm.category.fleet-task | posted by FleetNotifier, ShiftDuePush and the PR scan | System (Notification Center, unchanged; routes through the Navigator) |  |
| `link.notification.fm.category.pr-ready` | Notification category fm.category.pr-ready | posted by FleetNotifier, ShiftDuePush and the PR scan | System (Notification Center, unchanged; routes through the Navigator) |  |
| `link.notification.fm.category.shift-follow-up` | Notification category fm.category.shift-follow-up | posted by FleetNotifier, ShiftDuePush and the PR scan | System (Notification Center, unchanged; routes through the Navigator) |  |
| `link.notification.fm.category.shift-task` | Notification category fm.category.shift-task | posted by FleetNotifier, ShiftDuePush and the PR scan | System (Notification Center, unchanged; routes through the Navigator) |  |
| `link.route.newCodeSnippetFromMenu` | Route `newCodeSnippetFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newCommandFromMenu` | Route `newCommandFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newContextualItem` | Route `newContextualItem` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newCredentialFromMenu` | Route `newCredentialFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newHostFromMenu` | Route `newHostFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newKeyFromMenu` | Route `newKeyFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newNotebookPageFromMenu` | Route `newNotebookPageFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newRunbookFromMenu` | Route `newRunbookFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newSavedLinkFromMenu` | Route `newSavedLinkFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newScheduleFromMenu` | Route `newScheduleFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newShiftFollowUpFromMenu` | Route `newShiftFollowUpFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newShiftProjectFromMenu` | Route `newShiftProjectFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newShiftTaskFromMenu` | Route `newShiftTaskFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newSnippetFromMenu` | Route `newSnippetFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.newStickyNoteFromMenu` | Route `newStickyNoteFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openCodeSnippet` | Route `openCodeSnippet` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openCommandLibraryCommand` | Route `openCommandLibraryCommand` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openDestinationForCrew` | Route `openDestinationForCrew` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openFleetLog` | Route `openFleetLog` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openKubernetes` | Route `openKubernetes` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openLogAnalyzer` | Route `openLogAnalyzer` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openNotebookPage` | Route `openNotebookPage` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openPostmortem` | Route `openPostmortem` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openReadingListLink` | Route `openReadingListLink` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openRunbook` | Route `openRunbook` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openSavedInvestigation` | Route `openSavedInvestigation` | Navigator - the incident card's Evidence tab reopening a saved Log Analyzer investigation | Navigator (split out of `connectHost`'s closure in stage 2) |  |
| `link.route.openShiftFollowUp` | Route `openShiftFollowUp` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openShiftProject` | Route `openShiftProject` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openShiftTask` | Route `openShiftTask` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openSRELeadForCrew` | Route `openSRELeadForCrew` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.openStickyNote` | Route `openStickyNote` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.revealHost` | Route `revealHost` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.revealHostsQuickConnect` | Route `revealHostsQuickConnect` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.revealHostPage` | Route `revealHostPage` | Navigator - the one definition of "this host's page is now on screen", reached by connect, switch, the strip, Recents and ⌘⌃1-9 | Navigator (moved there in stage 2 as `revealHostConsole`'s new name) |  |
| `link.route.selectDestinationFromMenu` | Route `selectDestinationFromMenu` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.selectHosts` | Route `selectHosts` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.selectKeys` | Route `selectKeys` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.selectSessionByShortcut` | Route `selectSessionByShortcut` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.selectSettings` | Route `selectSettings` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.selectSnippets` | Route `selectSnippets` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.selectSpace` | Route `selectSpace` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (space pills become sidebar groups; the call selects Home's matching card set until step 5) |  |
| `link.route.selectSpaceByShortcut` | Route `selectSpaceByShortcut` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (⌘1-⌘6 select sidebar modules) |  |
| `link.route.show` | Route `show` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (show(route) for every destination; stage 2 extracts it) |  |
| `link.route.showHomeCanvas` | Route `showHomeCanvas` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (selects Home) |  |
| `link.route.showLock` | Route `showLock` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Window (the lock overlay over sidebar, toolbar and content) |  |
| `link.route.showLogAnalyzer` | Route `showLogAnalyzer` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.showShiftDestination` | Route `showShiftDestination` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.showShiftWeeklyReview` | Route `showShiftWeeklyReview` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.route.showToast` | Route `showToast` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Window (the toast host, bottom centre) |  |
| `link.route.switchToSession` | Route `switchToSession` | AppShellController - called by menus, ⌘K, notifications, App Intents, menu bar extras or Home | Navigator (moved there in stage 2; AppShellController forwards to it) |  |
| `link.widget.com.manjesh.grandline.native.widget.sticky-note` | Sticky note widget | WidgetKit extension (blocked on Developer ID); tap opens the app | System (widget, unchanged; a tap opens the app) |  |
| `link.widget.com.manjesh.grandline.native.widget.tasks-due` | Tasks due widget | WidgetKit extension (blocked on Developer ID); tap opens the app | System (widget, unchanged; a tap opens the app) |  |

## Settings

The eight categories and every row whose title is a literal. Rows built in a loop are covered by their own families (terminal shortcuts, App Intents, backup sections).

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `settings.category.appearance` | Settings category: Appearance | Settings page's own sidebar | Settings › Appearance (a sidebar child of Settings; the page's private column becomes these children) |  |
| `settings.category.backup` | Settings category: Backup & Restore | Settings page's own sidebar | Settings › Backup & Restore (a sidebar child of Settings; the page's private column becomes these children) |  |
| `settings.category.briefings` | Settings category: Briefings | Settings page's own sidebar | Settings › Briefings (a sidebar child of Settings; the page's private column becomes these children) |  |
| `settings.category.capture` | Settings category: Capture | Settings page's own sidebar | Settings › Capture (a sidebar child of Settings; the page's private column becomes these children) |  |
| `settings.category.intents` | Settings category: App Intents & Shortcuts | Settings page's own sidebar | Settings › App Intents & Shortcuts (a sidebar child of Settings; the page's private column becomes these children) |  |
| `settings.category.menuBar` | Settings category: Menu Bar | Settings page's own sidebar | Settings › Menu Bar (a sidebar child of Settings; the page's private column becomes these children) |  |
| `settings.category.security` | Settings category: Security | Settings page's own sidebar | Settings › Security (a sidebar child of Settings; the page's private column becomes these children) |  |
| `settings.category.terminal` | Settings category: Terminal | Settings page's own sidebar | Settings › Terminal (a sidebar child of Settings; the page's private column becomes these children) |  |
| `settings.row.Accessibility permission` | Settings row: Accessibility permission | Settings > Capture | Settings › Capture (unchanged row) |  |
| `settings.row.Command snippets & dictation` | Settings row: Command snippets & dictation | Settings > Backup & Restore | Settings › Backup & Restore (unchanged row) |  |
| `settings.row.Currently saved` | Settings row: Currently saved | Settings > Backup & Restore | Settings › Backup & Restore (unchanged row) |  |
| `settings.row.Default font size` | Settings row: Default font size | Settings > Terminal | Settings › Terminal (unchanged row) |  |
| `settings.row.Follow system appearance` | Settings row: Follow system appearance | Settings > Appearance | Settings › Appearance (unchanged row) |  |
| `settings.row.Hide the Dock icon` | Settings row: Hide the Dock icon | Settings > Menu Bar | Settings › Menu Bar (unchanged row) |  |
| `settings.row.Hosts, SSH keys, jump hosts` | Settings row: Hosts, SSH keys, jump hosts | Settings > Backup & Restore | Settings › Backup & Restore (unchanged row) |  |
| `settings.row.Interface text size` | Settings row: Interface text size | Settings > Appearance | Settings › Appearance (unchanged row) |  |
| `settings.row.Light and dark pair` | Settings row: Light and dark pair | Settings > Appearance | Settings › Appearance (unchanged row) |  |
| `settings.row.Live in the menu bar` | Settings row: Live in the menu bar | Settings > Menu Bar | Settings › Menu Bar (unchanged row) |  |
| `settings.row.Lock after a full session` | Settings row: Lock after a full session | Settings > Security | Settings › Security (unchanged row) |  |
| `settings.row.Lock when idle` | Settings row: Lock when idle | Settings > Security | Settings › Security (unchanged row) |  |
| `settings.row.Notify when the crew needs you` | Settings row: Notify when the crew needs you | Settings > Terminal | Settings › Terminal (unchanged row) |  |
| `settings.row.Open Grand Line from anywhere` | Settings row: Open Grand Line from anywhere | Settings > Menu Bar | Settings › Menu Bar (unchanged row) |  |
| `settings.row.Open the capture panel` | Settings row: Open the capture panel | Settings > Capture | Settings › Capture (unchanged row) |  |
| `settings.row.Poneglyph vault` | Settings row: Poneglyph vault | Settings > Backup & Restore | Settings › Backup & Restore (unchanged row) |  |
| `settings.row.Reconnect automatically` | Settings row: Reconnect automatically | Settings > Terminal | Settings › Terminal (unchanged row) |  |
| `settings.row.Separate icons for Tasks, the vault and the crew` | Settings row: Separate icons for Tasks, the vault and the crew | Settings > Menu Bar | Settings › Menu Bar (unchanged row) |  |
| `settings.row.Show a morning briefing on Fleet` | Settings row: Show a morning briefing on Fleet | Settings > Briefings | Settings › Briefings (unchanged row) |  |
| `settings.row.Show the overdue count on the icon` | Settings row: Show the overdue count on the icon | Settings > Menu Bar | Settings › Menu Bar (unchanged row) |  |
| `settings.row.Terminal scrollback & session state` | Settings row: Terminal scrollback & session state | Settings > Backup & Restore | Settings › Backup & Restore (unchanged row) |  |
| `settings.row.Touch ID for sudo` | Settings row: Touch ID for sudo | Settings > Security | Settings › Security (unchanged row) |  |
| `settings.row.Vault settings live in the vault` | Settings row: Vault settings live in the vault | Settings > Security | Settings › Security (unchanged row) |  |
| `settings.row.Working directory` | Settings row: Working directory | Settings > Terminal | Settings › Terminal (unchanged row) |  |

## In-page tabs

Every `HelmSegmentedTabs` built from literal titles, plus the Hosts column, the Tools tabs and the compact popover's tabs.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `tab.CompactModeTab.crew` | Compact popover tab: crew | menu-bar compact mode popover | Menu bar extra (compact mode popover, unchanged) |  |
| `tab.CompactModeTab.notes` | Compact popover tab: notes | menu-bar compact mode popover | Menu bar extra (compact mode popover, unchanged) |  |
| `tab.CompactModeTab.today` | Compact popover tab: today | menu-bar compact mode popover | Menu bar extra (compact mode popover, unchanged) |  |
| `tab.CompactModeTab.vault` | Compact popover tab: vault | menu-bar compact mode popover | Menu bar extra (compact mode popover, unchanged) |  |
| `tab.HostsTab.hosts` | Hosts page column: Hosts | Hosts page's own sidebar column | Connections › Hosts |  |
| `tab.HostsTab.keys` | Hosts page column: SSH Keys | Hosts page's own sidebar column | Connections › Keys |  |
| `tab.HostsTab.snippets` | Hosts page column: Snippets | Hosts page's own sidebar column | Connections › Snippets |  |
| `tab.KeyEditorController.Generate` | SSH key editor mode: Generate | New SSH Key sheet | Connections › Keys (key editor sheet, unchanged) |  |
| `tab.KeyEditorController.Import` | SSH key editor mode: Import | New SSH Key sheet | Connections › Keys (key editor sheet, unchanged) |  |
| `tab.KubernetesController.Cluster` | Kubernetes tab: Cluster | Kubernetes page tab | Kubernetes › Cluster |  |
| `tab.KubernetesController.Deployments` | Kubernetes cluster sub-tab: Deployments | Kubernetes > Cluster | Kubernetes › Cluster (sub-tab, unchanged) |  |
| `tab.KubernetesController.Events` | Kubernetes cluster sub-tab: Events | Kubernetes > Cluster | Kubernetes › Cluster (sub-tab, unchanged) |  |
| `tab.KubernetesController.Log Tail` | Kubernetes tab: Log Tail | Kubernetes page tab | Kubernetes › Log Tail |  |
| `tab.KubernetesController.Pods` | Kubernetes cluster sub-tab: Pods | Kubernetes > Cluster | Kubernetes › Cluster (sub-tab, unchanged) |  |
| `tab.KubernetesController.Services` | Kubernetes cluster sub-tab: Services | Kubernetes > Cluster | Kubernetes › Cluster (sub-tab, unchanged) |  |
| `tab.LogAnalyzerController.Analysis` | Log Analyzer result tab: Analysis | Log Analyzer results | Logs (result tab, unchanged) |  |
| `tab.LogAnalyzerController.Compare` | Log Analyzer result tab: Compare | Log Analyzer results | Logs (result tab, unchanged) |  |
| `tab.LogAnalyzerController.Correlation` | Log Analyzer result tab: Correlation | Log Analyzer results | Logs (result tab, unchanged) |  |
| `tab.LogAnalyzerController.Error Groups` | Log Analyzer result tab: Error Groups | Log Analyzer results | Logs (result tab, unchanged) |  |
| `tab.LogAnalyzerController.Evidence` | Log Analyzer result tab: Evidence | Log Analyzer results | Logs (result tab, unchanged) |  |
| `tab.LogAnalyzerController.Timeline` | Log Analyzer result tab: Timeline | Log Analyzer results | Logs (result tab, unchanged) |  |
| `tab.SettingsController.All` | Theme filter: All | Settings > Appearance theme grid | Settings › Appearance (theme filter, unchanged) |  |
| `tab.SettingsController.Dark` | Theme filter: Dark | Settings > Appearance theme grid | Settings › Appearance (theme filter, unchanged) |  |
| `tab.SettingsController.Light` | Theme filter: Light | Settings > Appearance theme grid | Settings › Appearance (theme filter, unchanged) |  |
| `tab.ShiftController.Board` | Tasks view: Board | Tasks page view tabs | Tasks › Board |  |
| `tab.ShiftController.Calendar` | Tasks view: Calendar | Tasks page view tabs | Tasks › Calendar |  |
| `tab.ShiftController.List` | Tasks view: List | Tasks page view tabs | Tasks › List |  |
| `tab.ShiftController.Review` | Tasks view: Review | Tasks page view tabs | Tasks › Weekly review |  |
| `tab.ToolKind.base64` | Tool: base64 | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.ToolKind.cert` | Tool: cert | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.ToolKind.cron` | Tool: cron | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.ToolKind.diff` | Tool: diff | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.ToolKind.json` | Tool: json | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.ToolKind.jwt` | Tool: jwt | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.ToolKind.resource` | Tool: resource | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.ToolKind.scratchpad` | Tool: scratchpad | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.ToolKind.timestamp` | Tool: timestamp | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.ToolKind.yaml` | Tool: yaml | Tools page tab | Tools (tool tab, unchanged) |  |
| `tab.UpdatesController.All` | Updates filter: All | Updates page | Setup › Updates (filter, unchanged) |  |
| `tab.UpdatesController.Needs Attention` | Updates filter: Needs Attention | Updates page | Setup › Updates (filter, unchanged) |  |

## Page sidebar rows

The rows and headers of every page's own column (`HelmPageSidebar`): literal ones by title, enum-driven ones by case. A project, a notebook page or a tag is the captain's data rather than a feature, and has no row.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `nav.CredentialCategory.apiKey` | Poneglyph column: API keys | Poneglyph column | Secrets › Poneglyph (the vault's own filter column, unchanged) |  |
| `nav.CredentialCategory.cloud` | Poneglyph column: Cloud & AWS | Poneglyph column | Secrets › Poneglyph (the vault's own filter column, unchanged) |  |
| `nav.CredentialCategory.email` | Poneglyph column: Email | Poneglyph column | Secrets › Poneglyph (the vault's own filter column, unchanged) |  |
| `nav.CredentialCategory.other` | Poneglyph column: Other | Poneglyph column | Secrets › Poneglyph (the vault's own filter column, unchanged) |  |
| `nav.CredentialVaultSidebar.All credentials` | Poneglyph column: All credentials | Poneglyph column | Secrets › Poneglyph (the vault's own filter column, unchanged) |  |
| `nav.CredentialVaultSidebar.Collections` | Poneglyph column: Collections | Poneglyph column | Secrets › Poneglyph (the vault's own filter column, unchanged) |  |
| `nav.CredentialVaultSidebar.Kinds` | Poneglyph column: Kinds | Poneglyph column | Secrets › Poneglyph (the vault's own filter column, unchanged) |  |
| `nav.CredentialVaultSidebar.Vault` | Poneglyph column: Vault | Poneglyph column | Secrets › Poneglyph (the vault's own filter column, unchanged) |  |
| `nav.HostsController.Activity` | Hosts page column: Activity | Hosts page column | Crew › Log (the captain's log this row opens; Connections keeps an Activity link in its toolbar) |  |
| `nav.HostsController.Add host` | Hosts page, the shortcut hints panel: Add host | Hosts page, the shortcut hints panel | Connections › Hosts (the shortcut hints panel, unchanged) |  |
| `nav.HostsController.Command palette` | Hosts page, the shortcut hints panel: Command palette | Hosts page, the shortcut hints panel | Connections › Hosts (the shortcut hints panel, unchanged) |  |
| `nav.HostsController.Commands` | Hosts page column: Commands | Hosts page column | Connections › Commands (now a tab beside Hosts) |  |
| `nav.HostsController.New key` | Hosts page, the shortcut hints panel: New key | Hosts page, the shortcut hints panel | Connections › Hosts (the shortcut hints panel, unchanged) |  |
| `nav.HostsController.New snippet` | Hosts page, the shortcut hints panel: New snippet | Hosts page, the shortcut hints panel | Connections › Hosts (the shortcut hints panel, unchanged) |  |
| `nav.HostsController.Tools` | Hosts page column: Tools | Hosts page column | Connections (its two rows become a tab and a link, see below) |  |
| `nav.HostsController.Workspace` | Hosts page column: Workspace | Hosts page column | Connections (the Hosts, SSH Keys and Snippets rows become Connections' tabs) |  |
| `nav.NotebookController.Pages` | Notebook column: Pages | Notebook column | Knowledge › Notebook (the page tree) |  |
| `nav.ReadingListController.Added today` | Reading List column: Added today | Reading List column | Knowledge › Reading list (the tab's own filter column, unchanged) |  |
| `nav.ReadingListController.Everything` | Reading List column: Everything | Reading List column | Knowledge › Reading list (the tab's own filter column, unchanged) |  |
| `nav.ReadingListController.Inbox` | Reading List column: Inbox | Reading List column | Knowledge › Reading list (the tab's own filter column, unchanged) |  |
| `nav.ReadingListController.Read` | Reading List column: Read | Reading List column | Knowledge › Reading list (the tab's own filter column, unchanged) |  |
| `nav.ReadingListController.Summarised` | Reading List column: Summarised | Reading List column | Knowledge › Reading list (the tab's own filter column, unchanged) |  |
| `nav.ReadingListController.Tags` | Reading List column: Tags | Reading List column | Knowledge › Reading list (the tab's own filter column, unchanged) |  |
| `nav.ReadingListController.Unread` | Reading List column: Unread | Reading List column | Knowledge › Reading list (the tab's own filter column, unchanged) |  |
| `nav.SchedulesController.Manage` | Schedules page column: Manage | Schedules page column | Schedules (the module's own filter column, unchanged) |  |
| `nav.SchedulesController.Run history` | Schedules page column: Run history | Schedules page column | Schedules (the module's own filter column, unchanged) |  |
| `nav.SchedulesController.Workspace` | Schedules page column: Workspace | Schedules page column | Schedules (the module's own filter column, unchanged) |  |
| `nav.ScheduleStatusFilter.active` | Schedules page column: Active | Schedules page column | Schedules (the module's own filter column, unchanged) |  |
| `nav.ScheduleStatusFilter.all` | Schedules page column: All schedules | Schedules page column | Schedules (the module's own filter column, unchanged) |  |
| `nav.ScheduleStatusFilter.needsYou` | Schedules page column: Needs you | Schedules page column | Schedules (the module's own filter column, unchanged) |  |
| `nav.ScheduleStatusFilter.paused` | Schedules page column: Paused | Schedules page column | Schedules (the module's own filter column, unchanged) |  |
| `nav.ScheduleStatusFilter.worthALook` | Schedules page column: Worth a look | Schedules page column | Schedules (the module's own filter column, unchanged) |  |
| `nav.ShiftController.Follow-ups` | Tasks page column: Follow-ups | Tasks page column | Tasks (a sidebar child of Tasks that opens the follow-ups panel) |  |
| `nav.ShiftController.Projects` | Tasks page column: Projects | Tasks page column | Tasks (each project becomes a sidebar child of Tasks) |  |
| `nav.ShiftController.Settings` | Tasks page column: Settings | Tasks page column | Sidebar (Settings is its own sidebar item) |  |
| `nav.ShiftController.Shortcuts` | Tasks page column: Shortcuts | Tasks page column | Toolbar (the search field opens the same ⌘K palette) |  |
| `nav.ShiftController.Smart views` | Tasks page column: Smart views | Tasks page column | Tasks (these become sidebar children of Tasks) |  |
| `nav.ShiftController.Workspace` | Tasks page column: Workspace | Tasks page column | Tasks (these scopes become sidebar children of Tasks) |  |
| `nav.ShiftTaskScope.all` | Tasks page column: All tasks | Tasks page column | Tasks (a sidebar child of Tasks) |  |
| `nav.ShiftTaskScope.due_today` | Tasks page column: Due today | Tasks page column | Tasks (a sidebar child of Tasks) |  |
| `nav.ShiftTaskScope.my_priorities` | Tasks page column: My priorities | Tasks page column | Tasks (a sidebar child of Tasks) |  |
| `nav.ShiftTaskScope.overdue` | Tasks page column: Overdue | Tasks page column | Tasks (a sidebar child of Tasks) |  |
| `nav.ShiftTaskScope.recently_updated` | Tasks page column: Recently updated | Tasks page column | Tasks (a sidebar child of Tasks) |  |

## Toolbar actions

The buttons a page hands the floating bar's drill header (`drillHeaderActions`, by property) and every `HelmPageToolbar` button (by selector).

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `toolbar.AutomationController.refreshButton` | AutomationController header action `refreshButton` | the floating bar's drill header, right side | Setup › Automation (moves into the window toolbar as a module action) |  |
| `toolbar.CodePreviewController.formatTapped()` | Format | CodePreviewController page toolbar (`formatTapped()`) | Code |  |
| `toolbar.CodePreviewController.newSnippetTapped()` | New snippet | CodePreviewController page toolbar (`newSnippetTapped()`) | Code |  |
| `toolbar.CodePreviewController.runnersTapped()` | Which runners and formatters this machine has | CodePreviewController page toolbar (`runnersTapped()`) | Code |  |
| `toolbar.CodePreviewController.runTapped()` | Run | CodePreviewController page toolbar (`runTapped()`) | Code |  |
| `toolbar.CodePreviewController.showFind()` | Find in this snippet (⌘F) | CodePreviewController page toolbar (`showFind()`) | Code |  |
| `toolbar.CodePreviewController.toggleSidebarTapped()` | Hide the snippet list (⌘B) | CodePreviewController page toolbar (`toggleSidebarTapped()`) | Code |  |
| `toolbar.CodePreviewController.toggleWrapTapped()` | Toggle soft wrap | CodePreviewController page toolbar (`toggleWrapTapped()`) | Code |  |
| `toolbar.CodeRunOutputPane.clearTapped()` | Clear | CodeRunOutputPane page toolbar (`clearTapped()`) | Code |  |
| `toolbar.CodeRunOutputPane.copyTapped()` | Copy | CodeRunOutputPane page toolbar (`copyTapped()`) | Code |  |
| `toolbar.CodeRunOutputPane.stopTapped()` | Stop | CodeRunOutputPane page toolbar (`stopTapped()`) | Code |  |
| `toolbar.ConsoleController+Toolbar.analyzeLogsTapped()` | Analyze Logs | ConsoleController+Toolbar page toolbar (`analyzeLogsTapped()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.herdrRestartButtonClicked()` | Herdr | ConsoleController+Toolbar page toolbar (`herdrRestartButtonClicked()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.incidentButtonClicked()` | Start Incident | ConsoleController+Toolbar page toolbar (`incidentButtonClicked()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.newShellTab()` | New Shell Tab | ConsoleController+Toolbar page toolbar (`newShellTab()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.refreshBlockView()` | Refresh Blocks | ConsoleController+Toolbar page toolbar (`refreshBlockView()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.showFind()` | Find | ConsoleController+Toolbar page toolbar (`showFind()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.tailLogsTapped()` | Tail Logs | ConsoleController+Toolbar page toolbar (`tailLogsTapped()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.toggleBlockView()` | Blocks | ConsoleController+Toolbar page toolbar (`toggleBlockView()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.toggleComposer()` | Compose | ConsoleController+Toolbar page toolbar (`toggleComposer()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.toggleDragForwarding()` | App Selection (forward drags into the terminal app) | ConsoleController+Toolbar page toolbar (`toggleDragForwarding()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.toggleKubeContextBadge()` | Check Context (the Kubernetes context badge) | ConsoleController+Toolbar page toolbar (`toggleKubeContextBadge()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.toggleQuotaUsage()` | Claude usage | ConsoleController+Toolbar page toolbar (`toggleQuotaUsage()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.ConsoleController+Toolbar.toggleSRELead()` | Toggle the SRE Lead investigation pane | ConsoleController+Toolbar page toolbar (`toggleSRELead()`) | Console (the toolbar above the terminal, unchanged) |  |
| `toolbar.CredentialVaultController.addButton` | CredentialVaultController header action `addButton` | the floating bar's drill header, right side | Secrets › Poneglyph (moves into the window toolbar as a module action) |  |
| `toolbar.CredentialVaultController.lockButton` | CredentialVaultController header action `lockButton` | the floating bar's drill header, right side | Secrets › Poneglyph (moves into the window toolbar as a module action) |  |
| `toolbar.CredentialVaultController.recoveryButton` | CredentialVaultController header action `recoveryButton` | the floating bar's drill header, right side | Secrets › Poneglyph (moves into the window toolbar as a module action) |  |
| `toolbar.CredentialVaultController.settingsButton` | CredentialVaultController header action `settingsButton` | the floating bar's drill header, right side | Secrets › Poneglyph (moves into the window toolbar as a module action) |  |
| `toolbar.DictationController.refreshButton` | DictationController header action `refreshButton` | the floating bar's drill header, right side | Dictation (moves into the window toolbar as a module action) |  |
| `toolbar.DocsController.backTapped()` | Back | DocsController page toolbar (`backTapped()`) | Knowledge › Playbook |  |
| `toolbar.DocsController.forwardTapped()` | Forward | DocsController page toolbar (`forwardTapped()`) | Knowledge › Playbook |  |
| `toolbar.DocsController.openLiveButton` | DocsController header action `openLiveButton` | the floating bar's drill header, right side | Knowledge › Playbook (moves into the window toolbar as a module action) |  |
| `toolbar.DocsController.reloadTapped()` | Reload (local copy only) | DocsController page toolbar (`reloadTapped()`) | Knowledge › Playbook |  |
| `toolbar.HealthController.healthCard.diagnosticsButton` | HealthController header action `healthCard.diagnosticsButton` | the floating bar's drill header, right side | Health (moves into the window toolbar as a module action) |  |
| `toolbar.HelmKit.open()` | open | HelmKit page toolbar (`open()`) | Every module (a shared component; it travels with each page that uses it) |  |
| `toolbar.HostsController.addHostButton` | HostsController header action `addHostButton` | the floating bar's drill header, right side | Connections › Hosts (moves into the window toolbar as a module action) |  |
| `toolbar.HostsController.addKeyButton` | HostsController header action `addKeyButton` | the floating bar's drill header, right side | Connections › Hosts (moves into the window toolbar as a module action) |  |
| `toolbar.HostsController.addSnippetButton` | HostsController header action `addSnippetButton` | the floating bar's drill header, right side | Connections › Hosts (moves into the window toolbar as a module action) |  |
| `toolbar.KubernetesController.refreshButton` | KubernetesController header action `refreshButton` | the floating bar's drill header, right side | Kubernetes (moves into the window toolbar as a module action) |  |
| `toolbar.LogAnalyzerController.historyToggleButton` | LogAnalyzerController header action `historyToggleButton` | the floating bar's drill header, right side | Logs (moves into the window toolbar as a module action) |  |
| `toolbar.LogAnalyzerController.newInvestigationButton` | LogAnalyzerController header action `newInvestigationButton` | the floating bar's drill header, right side | Logs (moves into the window toolbar as a module action) |  |
| `toolbar.NotebookController.deleteTapped()` | Delete this page | NotebookController page toolbar (`deleteTapped()`) | Knowledge › Notebook |  |
| `toolbar.NotebookController.newPageButton` | NotebookController header action `newPageButton` | the floating bar's drill header, right side | Knowledge › Notebook (moves into the window toolbar as a module action) |  |
| `toolbar.NotebookController.showFind()` | Find in this page (⌘F) | NotebookController page toolbar (`showFind()`) | Knowledge › Notebook |  |
| `toolbar.NotebookController.todayButton` | NotebookController header action `todayButton` | the floating bar's drill header, right side | Knowledge › Notebook (moves into the window toolbar as a module action) |  |
| `toolbar.NotebookController.toggleRail()` | Show or hide backlinks and page details | NotebookController page toolbar (`toggleRail()`) | Knowledge › Notebook |  |
| `toolbar.ReadingListController.closeReaderTapped()` | Back to the reading list | ReadingListController page toolbar (`closeReaderTapped()`) | Knowledge › Reading list |  |
| `toolbar.ReadingListController.pasteButton` | ReadingListController header action `pasteButton` | the floating bar's drill header, right side | Knowledge › Reading list (moves into the window toolbar as a module action) |  |
| `toolbar.ReadingListController.pasteTapped()` | Save the link on the clipboard (⌘V) | ReadingListController page toolbar (`pasteTapped()`) | Knowledge › Reading list |  |
| `toolbar.ReadingListController.readerBackTapped()` | Back | ReadingListController page toolbar (`readerBackTapped()`) | Knowledge › Reading list |  |
| `toolbar.ReadingListController.readerOpenExternallyTapped()` | Open in the system browser | ReadingListController page toolbar (`readerOpenExternallyTapped()`) | Knowledge › Reading list |  |
| `toolbar.ReadingListController.readerReloadTapped()` | Reload | ReadingListController page toolbar (`readerReloadTapped()`) | Knowledge › Reading list |  |
| `toolbar.ReadingListController.refreshMetadataTapped()` | Re-read titles for everything still waiting | ReadingListController page toolbar (`refreshMetadataTapped()`) | Knowledge › Reading list |  |
| `toolbar.ReviewController.refreshButton` | ReviewController header action `refreshButton` | the floating bar's drill header, right side | Crew › Review (moves into the window toolbar as a module action) |  |
| `toolbar.RunbooksController.newRunbookButton` | RunbooksController header action `newRunbookButton` | the floating bar's drill header, right side | Knowledge › Runbooks (moves into the window toolbar as a module action) |  |
| `toolbar.SchedulesController.refreshButton` | SchedulesController header action `refreshButton` | the floating bar's drill header, right side | Schedules (moves into the window toolbar as a module action) |  |
| `toolbar.SchedulesController.schedulesCard.addButton` | SchedulesController header action `schedulesCard.addButton` | the floating bar's drill header, right side | Schedules (moves into the window toolbar as a module action) |  |
| `toolbar.ShiftController.newTaskButton` | ShiftController header action `newTaskButton` | the floating bar's drill header, right side | Tasks (moves into the window toolbar as a module action) |  |
| `toolbar.ShiftController.syncPill` | ShiftController header action `syncPill` | the floating bar's drill header, right side | Tasks (moves into the window toolbar as a module action) |  |
| `toolbar.StickyBoardController.archiveButton` | StickyBoardController header action `archiveButton` | the floating bar's drill header, right side | Sticky Board (moves into the window toolbar as a module action) |  |
| `toolbar.StickyBoardController.archiveToggleTapped()` | Archive | StickyBoardController page toolbar (`archiveToggleTapped()`) | Sticky Board |  |
| `toolbar.StickyBoardController.newNoteButton` | StickyBoardController header action `newNoteButton` | the floating bar's drill header, right side | Sticky Board (moves into the window toolbar as a module action) |  |
| `toolbar.StickyBoardController.newNoteTapped()` | New Note | StickyBoardController page toolbar (`newNoteTapped()`) | Sticky Board |  |
| `toolbar.StrawHatController.newButton` | StrawHatController header action `newButton` | the floating bar's drill header, right side | Crew › Ask the crew (moves into the window toolbar as a module action) |  |
| `toolbar.StrawHatController.rosterButton` | StrawHatController header action `rosterButton` | the floating bar's drill header, right side | Crew › Ask the crew (moves into the window toolbar as a module action) |  |
| `toolbar.StrawHatController.rosterTapped()` | Crew roster - who does what | StrawHatController page toolbar (`rosterTapped()`) | Crew › Ask the crew |  |
| `toolbar.ToolsController.newShellTab()` | New Tool Tab | ToolsController page toolbar (`newShellTab()`) | Tools |  |
| `toolbar.VaultController.refreshButton` | VaultController header action `refreshButton` | the floating bar's drill header, right side | Secrets › Automic Vault (moves into the window toolbar as a module action) |  |
| `toolbar.WhiteboardController.dslButton` | WhiteboardController header action `dslButton` | the floating bar's drill header, right side | Whiteboard (moves into the window toolbar as a module action) |  |
| `toolbar.WhiteboardController.dslTapped()` | From text | WhiteboardController page toolbar (`dslTapped()`) | Whiteboard |  |
| `toolbar.WhiteboardController.generateButton` | WhiteboardController header action `generateButton` | the floating bar's drill header, right side | Whiteboard (moves into the window toolbar as a module action) |  |
| `toolbar.WhiteboardController.generateTapped()` | Generate | WhiteboardController page toolbar (`generateTapped()`) | Whiteboard |  |
| `toolbar.WhiteboardController.moreMenu.button` | WhiteboardController header action `moreMenu.button` | the floating bar's drill header, right side | Whiteboard (moves into the window toolbar as a module action) |  |

## Page actions

Every selector a control targets, one row per file, with the selectors listed in the Today cell. The suite checks that list exactly, so a button added or removed in a file is caught.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `action.AllDestinationsOverlay` | AllDestinationsOverlay controls | `clicked`, `togglePin` | Sidebar (the ⌘⇧D map becomes the sidebar; pinning moves to the sidebar's Pinned section) |  |
| `action.AutomationController` | AutomationController controls | `refreshTapped`, `restoreConfigChooseFileClicked`, `restoreConfigSkipClicked`, `runAutomationClicked` | Setup › Automation |  |
| `action.BlockView` | BlockView controls | `chevronClicked` | Console (block view) |  |
| `action.BootstrapController` | BootstrapController controls | `browseClicked`, `cloneAndBootstrapClicked`, `createLinkClicked`, `driftRecheckClicked`, `hardenAwsClicked`, `hardenCodexClicked`, `hardenGhClicked`, `hardenHomebrewClicked`, `homebrewDisruptionToggled`, `importRestoreConfigClicked`, `installAllMissingClicked`, `installSoftwareClicked`, `refreshAllTapped`, `restartClicked`, `runFullSetupClicked`, `runRebuildClicked`, `saveClicked`, `saveUsernameClicked`, `syncDotfilesNowClicked` | Setup › Setup steps |  |
| `action.CodePreviewController` | CodePreviewController controls | `formatTapped`, `languagePicked`, `newSnippetTapped`, `runTapped`, `runnersTapped`, `showFind`, `toggleSidebarTapped`, `toggleWrapTapped` | Code |  |
| `action.CodePreviewFileSidebar` | CodePreviewFileSidebar controls | `closeClicked`, `rowClicked` | Code |  |
| `action.CodeRunOutputPane` | CodeRunOutputPane controls | `clearTapped`, `copyTapped`, `stopTapped` | Code |  |
| `action.CommandEditorController` | CommandEditorController controls | `addParameterClicked`, `removeParameterClicked` | Connections › Commands |  |
| `action.CommandLibraryAIPopover` | CommandLibraryAIPopover controls | `askClicked`, `copyClicked`, `saveTemplateClicked` | Connections › Commands |  |
| `action.CommandLibraryViews` | CommandLibraryViews controls | `addCommandClicked`, `aiActionPicked`, `aiClicked`, `appendToExistingRunbook`, `categoryCommandRowClicked`, `categoryRowClicked`, `copyClicked`, `createNewWorkflowRunbook`, `duplicateClicked`, `editClicked`, `favoriteClicked`, `favoriteRowClicked`, `paramValueChanged`, `recentRowClicked`, `searchResultRowClicked`, `sendToHostsClicked`, `sendToTerminalClicked`, `workflowClicked` | Connections › Commands |  |
| `action.CompactMode` | CompactMode controls | `iconClicked` | Menu bar extra (compact mode, unchanged) |  |
| `action.CompactModePopover` | CompactModePopover controls | `captureSubmitted`, `clicked`, `openBoardTapped`, `openTasksTapped`, `openWindowTapped`, `settingsTapped`, `submitTapped` | Menu bar extra (compact mode, unchanged) |  |
| `action.CompactModeStatusMenu` | CompactModeStatusMenu controls | `fire` | Menu bar extra (compact mode, unchanged) |  |
| `action.ConsoleComposerPopover` | ConsoleComposerPopover controls | `copyClicked`, `exampleClicked`, `generateClicked`, `runClicked` | Console (Compose popover) |  |
| `action.ConsoleController+SRELead` | ConsoleController+SRELead controls | `generatePostmortemClicked`, `startSRELeadForCurrentTabClicked` | Console (SRE Lead) |  |
| `action.ConsoleController+Toolbar` | ConsoleController+Toolbar controls | `analyzeLogsTapped`, `herdrRestartButtonClicked`, `incidentButtonClicked`, `newShellTab`, `refreshBlockView`, `showFind`, `tailLogsTapped`, `toggleBlockView`, `toggleComposer`, `toggleDragForwarding`, `toggleKubeContextBadge`, `toggleQuotaUsage`, `toggleSRELead` | Console (the toolbar above the terminal, unchanged) |  |
| `action.CredentialVaultController` | CredentialVaultController controls | `addTapped`, `clearClipboardNow`, `lockTapped`, `recoveryTapped`, `settingsTapped` | Secrets › Poneglyph |  |
| `action.CredentialVaultEditorController` | CredentialVaultEditorController controls | `deleteTapped`, `pasteTOTPFromClipboard`, `toggleGenerator` | Secrets › Poneglyph |  |
| `action.CredentialVaultInspector` | CredentialVaultInspector controls | `closeClicked`, `copyAccountClicked`, `copyClicked`, `deleteClicked`, `editClicked`, `revealClicked` | Secrets › Poneglyph |  |
| `action.CredentialVaultListSection` | CredentialVaultListSection controls | `copyClicked`, `copyCodeClicked`, `overflowClicked`, `overflowItemPicked`, `revealClicked` | Secrets › Poneglyph |  |
| `action.CredentialVaultRecoverySheet` | CredentialVaultRecoverySheet controls | `chooseFile`, `copyCode`, `printCard`, `printNewKey`, `removeKey`, `runImport`, `savePDF` | Secrets › Poneglyph |  |
| `action.CredentialVaultSettingsController` | CredentialVaultSettingsController controls | `changePasswordClicked`, `syncNowClicked` | Secrets › Poneglyph |  |
| `action.CredentialVaultUnlockView` | CredentialVaultUnlockView controls | `primaryClicked`, `recoveryLinkClicked`, `touchIDClicked` | Secrets › Poneglyph |  |
| `action.DaylightBarController` | DaylightBarController controls | `avatarClicked`, `clicked`, `destinationButtonClicked`, `focusChipClicked`, `logoutRowClicked`, `pillClicked`, `quickAccessMenuPicked`, `quickAccessOverflowClicked`, `settingsRowClicked`, `themeToggleClicked` | Toolbar (the bar's controls move to the window toolbar and the sidebar - see the chrome rows) |  |
| `action.DictationController` | DictationController controls | `cleanupToggled`, `localWhisperToggled`, `modelActionTapped`, `modelDeleteTapped`, `modelMoreTapped`, `refreshTapped`, `resetShortcutTapped`, `statusActionTapped` | Dictation |  |
| `action.DictationHistoryAndVocabularyViews` | DictationHistoryAndVocabularyViews controls | `deleteClicked`, `removeTapped` | Dictation |  |
| `action.DiffResultView` | DiffResultView controls | `clicked` | Tools (Diff tool) |  |
| `action.DocsController` | DocsController controls | `backTapped`, `forwardTapped`, `openLiveTapped`, `reloadTapped`, `syncNowTapped` | Knowledge › Playbook |  |
| `action.FleetController` | FleetController controls | `crewTapped`, `refreshTapped` | Crew › In flight |  |
| `action.FleetController+Reply` | FleetController+Reply controls | `replyTapped` | Crew › Needs you |  |
| `action.FleetMessageComposer` | FleetMessageComposer controls | `cancelTapped`, `sendTapped` | Crew › Needs you |  |
| `action.FocusTimerViews` | FocusTimerViews controls | `extendTapped`, `finishTapped`, `pauseTapped` | Status line (the focus timer chip and its ring popover) |  |
| `action.GitHubSyncController` | GitHubSyncController controls | `refreshTapped`, `syncAllTapped`, `syncTapped` | Setup › GitHub sync |  |
| `action.HealthCardView` | HealthCardView controls | `copyDiagnostics`, `openSchedulesTapped` | Health |  |
| `action.HelmConfirm` | HelmConfirm controls | `cancelClicked`, `confirmClicked`, `extraClicked` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HelmDateField` | HelmDateField controls | `cardClicked`, `pickerChanged` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HelmDesignSystem` | HelmDesignSystem controls | `pillClicked`, `rowClicked`, `tileClicked` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HelmDrillHeader` | HelmDrillHeader controls | `backClicked` | Toolbar (the back button, tile and title move to the window toolbar) |  |
| `action.HelmForm` | HelmForm controls | `choicePicked`, `clicked`, `closeSquareClicked`, `extraPicked`, `fallbackSwitchChanged`, `pillClicked` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HelmKit` | HelmKit controls | `open`, `picked` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HelmModuleCard` | HelmModuleCard controls | `PeekRowClick.fire`, `cardClicked`, `footerActionTapped`, `headerActionTapped` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HelmPageSidebar` | HelmPageSidebar controls | `emptyStateActionClicked`, `footerLinkClicked`, `rowClicked` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HelmPlateCard` | HelmPlateCard controls | `deleteClicked`, `openClicked` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HelmRevealableSecretField` | HelmRevealableSecretField controls | `toggleReveal` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HelmZoomStepper` | HelmZoomStepper controls | `larger`, `reset`, `smaller` | Every module (a shared component; it travels with each page that uses it) |  |
| `action.HomeCanvasController` | HomeCanvasController controls | `refreshTapped` | Home |  |
| `action.HostEditorController` | HostEditorController controls | `deleteHost`, `editPortForwarding`, `pickColor`, `pickIcon`, `pillClicked` | Connections › Hosts (host editor) |  |
| `action.HostsController` | HostsController controls | `groupPicked`, `newHost`, `newKey`, `newSnippet`, `onlineChipClicked`, `self.tagChipClicked` | Connections › Hosts |  |
| `action.HostsListSection` | HostsListSection controls | `emptyActionPressed`, `overflowClicked`, `overflowItemPicked`, `primaryClicked` | Connections › Hosts |  |
| `action.HostsSidebar` | HostsSidebar controls | `logoutPicked`, `rowClicked`, `settingsPicked` | Connections › Hosts (the column becomes the module's tabs) |  |
| `action.HostsSidePanels` | HostsSidePanels controls | `actionClicked`, `buttonClicked` | Connections › Hosts (inspector) |  |
| `action.IncidentCardView` | IncidentCardView controls | `addNoteClicked`, `endIncidentClicked`, `openEvidenceClicked` | Console (incident card) |  |
| `action.KeyboardShortcutsSheetController` | KeyboardShortcutsSheetController controls | `closeSheet` | Main menu › Help (Keyboard Shortcuts sheet, unchanged) |  |
| `action.KeyEditorController` | KeyEditorController controls | `chooseImportFile`, `copyFingerprint`, `copyPublicKey`, `deleteKey`, `generateKey`, `verifyImport` | Connections › Keys (key editor) |  |
| `action.KubernetesController` | KubernetesController controls | `clearTailTapped`, `closeDescribeTapped`, `copyDescribeTapped`, `duplicateFeedTapped`, `feedTabPicked`, `namespaceCommitted`, `namespacePicked`, `openHostsTapped`, `refreshTapped`, `retryFeedTapped`, `retryStuckClusterRefreshTapped`, `revealHostTapped`, `toggleErrorsOnlyTapped`, `togglePauseTapped` | Kubernetes |  |
| `action.KubernetesController+Render` | KubernetesController+Render controls | `togglePodSelection` | Kubernetes |  |
| `action.LockScreenController` | LockScreenController controls | `copySetupCommandTapped`, `installTapped`, `localAuthTapped`, `submitTapped` | Window (the lock overlay) |  |
| `action.LogAnalyzerController` | LogAnalyzerController controls | `addClipboardAsEvidence`, `addCurrentInputAsEvidence`, `addFileTapped`, `analyzeClipboard`, `analyzeTapped`, `comparePickerChanged`, `copyCommandTapped`, `copyComparison`, `copyEvidence`, `copyNextSteps`, `copyRootCause`, `createIncident`, `focusInput`, `goToConsole`, `investigateFurther`, `modeChanged`, `newInvestigation`, `overrideChanged`, `runCompare`, `sendCommandTapped`, `sourceChanged`, `storageRowClicked`, `toggleHistory`, `toggleRedactions` | Logs |  |
| `action.LogAnalyzerViews` | LogAnalyzerViews controls | `rowClicked` | Logs |  |
| `action.main` | main controls | `AppDelegate.showAllDestinations`, `AppDelegate.showKeyboardShortcuts`, `AppDelegate.showManualChecks`, `AppDelegate.showShiftQuickCapture`, `AppDelegate.showUnifiedSearch`, `AppShellController.activateConsoleFind`, `AppShellController.analyzeClipboardInLogAnalyzer`, `AppShellController.captureScreenRegionFromMenu`, `AppShellController.copyWhiteboardImageFromMenu`, `AppShellController.logAnalyzerCopyAnalysis`, `AppShellController.logAnalyzerCreateRCA`, `AppShellController.logAnalyzerInvestigateFurther`, `AppShellController.logAnalyzerSendToTerminal`, `AppShellController.newContextualItem`, `AppShellController.newHostFromMenu`, `AppShellController.newKeyFromMenu`, `AppShellController.newShiftFollowUpFromMenu`, `AppShellController.newShiftProjectFromMenu`, `AppShellController.newShiftTaskFromMenu`, `AppShellController.newSnippetFromMenu`, `AppShellController.nextSession`, `AppShellController.previousSession`, `AppShellController.revealHostsQuickConnect`, `AppShellController.runCodeSnippetFromMenu`, `AppShellController.selectDestinationFromMenu`, `AppShellController.selectHosts`, `AppShellController.selectKeys`, `AppShellController.selectSessionByShortcut`, `AppShellController.selectSettings`, `AppShellController.selectSnippets`, `AppShellController.selectSpaceByShortcut`, `AppShellController.showLogAnalyzer`, `AppShellController.showShiftWeeklyReview`, `AppShellController.toggleClipboardHistory`, `AppShellController.toggleCodePreviewSidebarFromMenu`, `AppShellController.toggleSidebarFromMenu`, `ConsoleController.showFind`, `NSApplication.arrangeInFront`, `NSApplication.hide`, `NSApplication.hideOtherApplications`, `NSApplication.orderFrontStandardAboutPanel`, `NSApplication.terminate`, `NSApplication.unhideAllApplications`, `NSText.copy`, `NSText.cut`, `NSText.paste`, `NSText.selectAll`, `NSWindow.performMiniaturize`, `NSWindow.performZoom` | Main menu (these are the menu items' targets - see the menu rows) |  |
| `action.MorningBriefingCard` | MorningBriefingCard controls | `dismissClicked`, `refreshClicked` | Home (Morning briefing card) |  |
| `action.MultiHostSendPicker` | MultiHostSendPicker controls | `checkClicked`, `pillClicked` | Connections › Hosts (send to many hosts) |  |
| `action.NeedsAttentionCard` | NeedsAttentionCard controls | `actionClicked`, `checkboxClicked`, `refreshClicked` | Home (Needs you card) |  |
| `action.NotebookController` | NotebookController controls | `ClosureSleeve.invoke`, `deleteTapped`, `newPageTapped`, `showFind`, `todayTapped`, `toggleRail` | Knowledge › Notebook |  |
| `action.NotificationCenterPopover` | NotificationCenterPopover controls | `actionClicked`, `activate`, `bellClicked`, `disclosureClicked`, `markAllReadClicked`, `primaryActionClicked`, `restoreSnoozedClicked`, `undoClicked` | Toolbar (the notifications button opens the same Notification Center) |  |
| `action.PasswordGeneratorPanel` | PasswordGeneratorPanel controls | `copyTapped`, `lengthChanged`, `regenerate`, `useTapped` | Secrets › Poneglyph (password generator) |  |
| `action.PoneglyphMenuBar` | PoneglyphMenuBar controls | `copyTapped`, `iconClicked`, `openVault` | Menu bar extra (Poneglyph, unchanged) |  |
| `action.PortForwardingController` | PortForwardingController controls | `addRuleClicked`, `cancel`, `kindChanged`, `removeClicked`, `save` | Connections › Hosts (host editor) |  |
| `action.PostmortemsController` | PostmortemsController controls | `openLogAnalyzerTapped`, `seedExamplePostmortemTapped` | Knowledge › Postmortems |  |
| `action.QuotaUsagePopover` | QuotaUsagePopover controls | `copyClicked` | Console (Claude usage popover) |  |
| `action.ReadingListCardView` | ReadingListCardView controls | `copyLinkTapped`, `deleteTapped`, `editTagsTapped`, `openExternallyTapped`, `openTapped`, `summariseTapped`, `toggleReadTapped` | Knowledge › Reading list |  |
| `action.ReadingListController` | ReadingListController controls | `clicked`, `closeReaderTapped`, `pasteTapped`, `readerBackTapped`, `readerOpenExternallyTapped`, `readerReloadTapped`, `refreshMetadataTapped` | Knowledge › Reading list |  |
| `action.RecentDestinationsPopover` | RecentDestinationsPopover controls | `buttonClicked` | Toolbar (back and forward, with the Recents list as their menu) |  |
| `action.ReviewController` | ReviewController controls | `refreshTapped`, `toggleFailureDetail` | Crew › Review |  |
| `action.RunbooksController` | RunbooksController controls | `ClosureSleeve.invoke`, `newRunbookTapped`, `seedExampleRunbookTapped` | Knowledge › Runbooks |  |
| `action.ScheduleEditorController` | ScheduleEditorController controls | `deleteSchedule` | Schedules |  |
| `action.ScheduleHistoryController` | ScheduleHistoryController controls | `closeClicked`, `viewLogClicked` | Schedules |  |
| `action.ScheduleRunLogController` | ScheduleRunLogController controls | `closeClicked`, `copyLogClicked`, `copyReportClicked`, `toggleRawClicked` | Schedules |  |
| `action.SchedulesCardView` | SchedulesCardView controls | `deletePicked`, `editPicked`, `newScheduleClicked`, `openDestinationPicked`, `overflowClicked`, `reviewClicked`, `runNowPicked`, `viewHistoryPicked` | Schedules |  |
| `action.SchedulesController` | SchedulesController controls | `refreshTapped` | Schedules |  |
| `action.SessionStripView` | SessionStripView controls | `addClicked`, `closeClicked`, `pillClicked` | Console (the Sessions strip; live sessions are also sidebar children of Console) |  |
| `action.SettingsController` | SettingsController controls | `chooseShellCwd`, `disableSudoTouchIDClicked`, `enableSudoTouchIDClicked`, `exportBackupClicked`, `fontPresetClicked`, `goBack`, `goForward`, `importBackupClicked`, `openAccessibilitySettings`, `openShortcutsApp`, `openVault`, `recheckSudoTouchIDClicked`, `resetQuickCaptureShortcut`, `resetTerminalShortcuts`, `textFieldChanged`, `themeDisclosureClicked`, `uiScaleClicked` | Settings |  |
| `action.SettingsThemeCard` | SettingsThemeCard controls | `cardClicked` | Settings › Appearance |  |
| `action.ShiftBoardViews` | ShiftBoardViews controls | `addTapped`, `chipClicked`, `clearFilterTapped`, `menuDelete`, `menuFocus`, `menuMove`, `menuOpen`, `menuPush` | Tasks › Board |  |
| `action.ShiftCalendarViews` | ShiftCalendarViews controls | `cellClicked`, `clicked`, `goNext`, `goPrevious`, `goToday` | Tasks › Calendar |  |
| `action.ShiftConflictController` | ShiftConflictController controls | `applyClicked`, `cancelClicked`, `choiceClicked` | Tasks (sync conflict sheet) |  |
| `action.ShiftController` | ShiftController controls | `detailBackClicked`, `detailSaveClicked`, `newTaskClicked`, `openFailedFile`, `sortChanged`, `syncPillClicked` | Tasks |  |
| `action.ShiftImageAttachmentWell` | ShiftImageAttachmentWell controls | `removeClicked` | Tasks (task editor attachments) |  |
| `action.ShiftListViews` | ShiftListViews controls | `checkboxClicked`, `deleteClicked`, `doneClicked`, `editClicked`, `focusClicked`, `openClicked`, `pushClicked`, `reopenClicked`, `snooze30`, `snoozeCustom`, `snoozeHour`, `snoozeNextWeek`, `snoozeTomorrow`, `stopFocusClicked` | Tasks › List |  |
| `action.ShiftMenuBar` | ShiftMenuBar controls | `iconClicked`, `quickAddSubmitted` | Menu bar extra (Tasks, unchanged) |  |
| `action.ShiftProjectDetailView` | ShiftProjectDetailView controls | `checkboxClicked`, `chevronClicked` | Tasks (project page; projects become sidebar children) |  |
| `action.ShiftProjectViews` | ShiftProjectViews controls | `openClicked`, `statusButtonClicked`, `statusItemSelected` | Tasks (projects; they become sidebar children) |  |
| `action.ShiftQuickCapture` | ShiftQuickCapture controls | `askTheCrew`, `clicked` | System (⌥Space quick capture panel, unchanged) |  |
| `action.ShiftSnoozeCustomController` | ShiftSnoozeCustomController controls | `cancel`, `confirm` | Tasks (snooze sheet) |  |
| `action.ShiftTaskEditorController` | ShiftTaskEditorController controls | `chooseImageClicked`, `deleteTask`, `dismissDetected`, `dueDatePickerChanged`, `priorityItemSelected`, `projectItemSelected`, `weekdayChipClicked` | Tasks (task editor; also the inspector's fields) |  |
| `action.SnippetEditorController` | SnippetEditorController controls | `deleteSnippet` | Connections › Snippets (snippet editor) |  |
| `action.SnippetExpansionPanel` | SnippetExpansionPanel controls | `requestPermission` | System (snippet expansion panel, unchanged) |  |
| `action.SRELeadChatView` | SRELeadChatView controls | `submit` | Console (SRE Lead pane) |  |
| `action.StickyBoardController` | StickyBoardController controls | `archiveToggleTapped`, `newNoteTapped`, `seedExampleNoteTapped` | Sticky Board |  |
| `action.StickyBoardViews` | StickyBoardViews controls | `addClicked`, `archiveClicked`, `boxClicked`, `colorClicked`, `deleteClicked`, `makeTaskClicked`, `overflowClicked`, `toggleChecklistClicked`, `unarchiveClicked` | Sticky Board |  |
| `action.StrawHatChatView` | StrawHatChatView controls | `submit` | Crew › Ask the crew |  |
| `action.StrawHatController` | StrawHatController controls | `newConversationTapped`, `rosterTapped` | Crew › Ask the crew |  |
| `action.StrawHatCrewViews` | StrawHatCrewViews controls | `activate`, `confirmTapped`, `projectPicked` | Crew › Ask the crew |  |
| `action.StrawHatMenuBar` | StrawHatMenuBar controls | `iconClicked`, `openFullChatTapped`, `submit` | Menu bar extra (Straw Hat, unchanged) |  |
| `action.StrawHatRosterView` | StrawHatRosterView controls | `closeClicked` | Crew › Ask the crew |  |
| `action.TabChipView` | TabChipView controls | `closeClicked`, `duplicateFromMenu`, `reconnectFromMenu`, `renameFromMenu`, `toggleForwardDragsFromMenu` | Console (tab strip) |  |
| `action.Toast` | Toast controls | `UndoSlot.undoClicked` | Window (toast) |  |
| `action.ToolInstance` | ToolInstance controls | `base64CopyClicked`, `base64DecodeClicked`, `base64EncodeClicked`, `certCopyClicked`, `certInspectClicked`, `cpuCoresCopyClicked`, `cpuMillicoresCopyClicked`, `cpuToCoresClicked`, `cpuToMillicoresClicked`, `cronCopyClicked`, `cronExplainClicked`, `cronRandomClicked`, `diffCompareClicked`, `diffShowOnlyDifferencesToggled`, `epochToHumanClicked`, `humanToEpochClicked`, `jsonBeautifyClicked`, `jsonCopyClicked`, `jsonValidateClicked`, `jwtCopyHeaderClicked`, `jwtCopyPayloadClicked`, `jwtDecodeClicked`, `memoryConvertClicked`, `memoryCopyClicked`, `nowClicked`, `scratchpadCopyAllClicked`, `tsCopyEpochClicked`, `tsCopyHumanClicked`, `yamlBeautifyClicked`, `yamlCopyClicked`, `yamlValidateClicked` | Tools |  |
| `action.ToolsController` | ToolsController controls | `newShellTab`, `toolCardClicked` | Tools |  |
| `action.UnifiedSearch` | UnifiedSearch controls | `clicked` | Toolbar (the search field and its ⌘K palette) |  |
| `action.UpdatesController` | UpdatesController controls | `checkAllTapped`, `checkTapped`, `installInBootstrapTapped`, `runInTerminalTapped`, `updateTapped` | Setup › Updates |  |
| `action.VaultController` | VaultController controls | `addSecretTapped`, `cancel`, `checkBackupTapped`, `closeTapped`, `confirm`, `copyNameTapped`, `exportRecipeTapped`, `refreshTapped`, `runInjectedTapped` | Secrets › Automic Vault |  |
| `action.WelcomeSheetController` | WelcomeSheetController controls | `backTapped`, `copyCommandTapped`, `nextTapped`, `skipTapped`, `themePicked` | Window (first-run welcome sheet) |  |
| `action.WhiteboardComposerPopover` | WhiteboardComposerPopover controls | `appendToggled`, `exampleClicked`, `generateClicked`, `startOverClicked` | Whiteboard |  |
| `action.WhiteboardController` | WhiteboardController controls | `dslTapped`, `generateTapped` | Whiteboard |  |
| `action.WhiteboardDSLPopover` | WhiteboardDSLPopover controls | `appendToggled`, `componentMenuPicked`, `componentsButtonClicked`, `insertClicked` | Whiteboard |  |

## Lock-gated surfaces

`AppLockedSurface`: every surface that asks the app lock before showing the captain's data.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `lock.allDestinations` | App-lock gate: allDestinations | AppLockGate consults this before showing the captain's data off the main window | Sidebar (it sits inside the locked window, so the window's lock overlay covers it) |  |
| `lock.appIntentAskCrew` | App-lock gate: appIntentAskCrew | AppLockGate consults this before showing the captain's data off the main window | System (App Intent, unchanged gate) |  |
| `lock.appIntentCopyCredential` | App-lock gate: appIntentCopyCredential | AppLockGate consults this before showing the captain's data off the main window | System (App Intent, unchanged gate) |  |
| `lock.appIntentNewNote` | App-lock gate: appIntentNewNote | AppLockGate consults this before showing the captain's data off the main window | System (App Intent, unchanged gate) |  |
| `lock.appIntentNewTask` | App-lock gate: appIntentNewTask | AppLockGate consults this before showing the captain's data off the main window | System (App Intent, unchanged gate) |  |
| `lock.appIntentStartTimer` | App-lock gate: appIntentStartTimer | AppLockGate consults this before showing the captain's data off the main window | System (App Intent, unchanged gate) |  |
| `lock.clipboardHistory` | App-lock gate: clipboardHistory | AppLockGate consults this before showing the captain's data off the main window | Window (clipboard history panel, unchanged gate) |  |
| `lock.compactModeMenu` | App-lock gate: compactModeMenu | AppLockGate consults this before showing the captain's data off the main window | Menu bar extra (unchanged gate) |  |
| `lock.compactModePopover` | App-lock gate: compactModePopover | AppLockGate consults this before showing the captain's data off the main window | Menu bar extra (unchanged gate) |  |
| `lock.crewReply` | App-lock gate: crewReply | AppLockGate consults this before showing the captain's data off the main window | Crew › Needs you (unchanged gate) |  |
| `lock.dictation` | App-lock gate: dictation | AppLockGate consults this before showing the captain's data off the main window | Dictation (unchanged gate) |  |
| `lock.incidentCard` | App-lock gate: incidentCard | AppLockGate consults this before showing the captain's data off the main window | Console (unchanged gate) |  |
| `lock.menuBarContent` | App-lock gate: menuBarContent | AppLockGate consults this before showing the captain's data off the main window | Menu bar extra (unchanged gate) |  |
| `lock.menuBarPopover` | App-lock gate: menuBarPopover | AppLockGate consults this before showing the captain's data off the main window | Menu bar extra (unchanged gate) |  |
| `lock.notificationAction` | App-lock gate: notificationAction | AppLockGate consults this before showing the captain's data off the main window | System (notification buttons, unchanged gate) |  |
| `lock.poneglyphMenuBarPopover` | App-lock gate: poneglyphMenuBarPopover | AppLockGate consults this before showing the captain's data off the main window | Menu bar extra (unchanged gate) |  |
| `lock.quickCapture` | App-lock gate: quickCapture | AppLockGate consults this before showing the captain's data off the main window | System (⌥Space, unchanged gate) |  |
| `lock.screenCapture` | App-lock gate: screenCapture | AppLockGate consults this before showing the captain's data off the main window | Whiteboard (screen capture, unchanged gate) |  |
| `lock.snippetExpansion` | App-lock gate: snippetExpansion | AppLockGate consults this before showing the captain's data off the main window | System (snippet expansion, unchanged gate) |  |
| `lock.strawHatChat` | App-lock gate: strawHatChat | AppLockGate consults this before showing the captain's data off the main window | Crew › Ask the crew (unchanged gate) |  |
| `lock.strawHatMenuBarPopover` | App-lock gate: strawHatMenuBarPopover | AppLockGate consults this before showing the captain's data off the main window | Menu bar extra (unchanged gate) |  |
| `lock.tabShortcuts` | App-lock gate: tabShortcuts | AppLockGate consults this before showing the captain's data off the main window | Console (tab shortcuts, unchanged gate) |  |
| `lock.terminalAutoReconnect` | App-lock gate: terminalAutoReconnect | AppLockGate consults this before showing the captain's data off the main window | Console (unchanged gate) |  |
| `lock.terminalFocus` | App-lock gate: terminalFocus | AppLockGate consults this before showing the captain's data off the main window | Console (unchanged gate) |  |
| `lock.terminalSession` | App-lock gate: terminalSession | AppLockGate consults this before showing the captain's data off the main window | Console (unchanged gate) |  |
| `lock.unifiedSearch` | App-lock gate: unifiedSearch | AppLockGate consults this before showing the captain's data off the main window | Toolbar (⌘K palette, unchanged gate) |  |
| `lock.whiteboardCopy` | App-lock gate: whiteboardCopy | AppLockGate consults this before showing the captain's data off the main window | Whiteboard (unchanged gate) |  |
| `lock.widgetSnapshot` | App-lock gate: widgetSnapshot | AppLockGate consults this before showing the captain's data off the main window | System (widgets, unchanged gate) |  |

## Drag and drop targets

Every view that registers for dragged types.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `drop.CodePreviewController` | Drop a file onto Code Preview to open it | CodePreviewController | Code |  |
| `drop.CredentialVaultListSection` | Drag credentials to reorder them | CredentialVaultListSection | Secrets › Poneglyph |  |
| `drop.KeyEditorController` | Drop a private key file into the SSH key editor | KeyEditorController | Connections › Keys (key editor) |  |
| `drop.LogAnalyzerController` | Drop a log file onto the Log Analyzer | LogAnalyzerController | Logs |  |
| `drop.ReadingListController` | Drop a URL or text onto the Reading List to save it | ReadingListController | Knowledge › Reading list |  |
| `drop.ShiftBoardViews` | Drag task cards between board lanes | ShiftBoardViews | Tasks › Board |  |
| `drop.ShiftImageAttachmentWell` | Drop an image onto a task's attachment well | ShiftImageAttachmentWell | Tasks (task editor attachments) |  |

## Saved state

Every preference key declared as an `fm.` constant.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `state.fm.autoReconnect` | Saved preference `fm.autoReconnect` | declared in AppSettings | Settings › Terminal |  |
| `state.fm.codePreview.sidebarVisible` | Saved preference `fm.codePreview.sidebarVisible` | declared in CodePreviewFileSidebar | Code |  |
| `state.fm.codePreview.sidebarWidth` | Saved preference `fm.codePreview.sidebarWidth` | declared in CodePreviewFileSidebar | Code |  |
| `state.fm.compactModeBadgesOverdueCount` | Saved preference `fm.compactModeBadgesOverdueCount` | declared in AppSettings | Settings › Menu Bar |  |
| `state.fm.compactModeEnabled` | Saved preference `fm.compactModeEnabled` | declared in AppSettings | Settings › Menu Bar |  |
| `state.fm.compactModeHidesDockIcon` | Saved preference `fm.compactModeHidesDockIcon` | declared in AppSettings | Settings › Menu Bar |  |
| `state.fm.defaultShellCwd` | Saved preference `fm.defaultShellCwd` | declared in AppSettings | Settings › Terminal |  |
| `state.fm.dictationCleanupEnabled` | Saved preference `fm.dictationCleanupEnabled` | declared in AppSettings | Dictation |  |
| `state.fm.dictationLocalWhisperEnabled` | Saved preference `fm.dictationLocalWhisperEnabled` | declared in AppSettings | Dictation |  |
| `state.fm.dictationShortcut` | Saved preference `fm.dictationShortcut` | declared in AppSettings | Dictation |  |
| `state.fm.didSeedDailyGitHubSyncSchedule` | Saved preference `fm.didSeedDailyGitHubSyncSchedule` | declared in AppSettings | Schedules (one-time seeding marker) |  |
| `state.fm.dotfilesAutoCommitEnabled` | Saved preference `fm.dotfilesAutoCommitEnabled` | declared in AppSettings | Setup › Setup steps |  |
| `state.fm.fmHome` | Saved preference `fm.fmHome` | declared in AppSettings | Crew (the firstmate home the crew pages read) |  |
| `state.fm.followSystemAppearance` | Saved preference `fm.followSystemAppearance` | declared in AppSettings | Settings › Appearance |  |
| `state.fm.fontSize` | Saved preference `fm.fontSize` | declared in AppSettings | Settings › Terminal |  |
| `state.fm.hasSeenWelcome` | Saved preference `fm.hasSeenWelcome` | declared in AppSettings | Window (welcome sheet) |  |
| `state.fm.keychainMigratedFromFirstmateCockpit` | Saved preference `fm.keychainMigratedFromFirstmateCockpit` | declared in LegacyNameMigration | System (launch migration marker, unchanged) |  |
| `state.fm.keychainMigratedItems` | Saved preference `fm.keychainMigratedItems` | declared in LegacyNameMigration | System (launch migration marker, unchanged) |  |
| `state.fm.keychainMigrationFailedAttempts` | Saved preference `fm.keychainMigrationFailedAttempts` | declared in LegacyNameMigration | System (launch migration marker, unchanged) |  |
| `state.fm.keychainMigrationGaveUpReasons` | Saved preference `fm.keychainMigrationGaveUpReasons` | declared in LegacyNameMigration | System (launch migration marker, unchanged) |  |
| `state.fm.menuBarSeparateItems` | Saved preference `fm.menuBarSeparateItems` | declared in AppSettings | Settings › Menu Bar |  |
| `state.fm.morningBriefingEnabled` | Saved preference `fm.morningBriefingEnabled` | declared in AppSettings | Settings › Briefings |  |
| `state.fm.morningBriefingRecord` | Saved preference `fm.morningBriefingRecord` | declared in AppSettings | Home (Morning briefing card's cache) |  |
| `state.fm.notebook.inspectorVisible` | Saved preference `fm.notebook.inspectorVisible` | declared in NotebookController | Knowledge › Notebook |  |
| `state.fm.notifyOnNeedsDecision` | Saved preference `fm.notifyOnNeedsDecision` | declared in AppSettings | Settings › Terminal |  |
| `state.fm.quickAccess` | Saved preference `fm.quickAccess` | declared in AppSettings | Sidebar (the Pinned section reads the same list) |  |
| `state.fm.quickCaptureShortcut` | Saved preference `fm.quickCaptureShortcut` | declared in AppSettings | Settings › Capture |  |
| `state.fm.renamedFromFirstmateCockpit` | Saved preference `fm.renamedFromFirstmateCockpit` | declared in LegacyNameMigration | System (launch migration marker, unchanged) |  |
| `state.fm.sessionRestoreState` | Saved preference `fm.sessionRestoreState` | declared in SessionRestoreStore | Navigator (session restore reopens the same route; legacy key, migrated to a file) |  |
| `state.fm.shift.taskSort` | Saved preference `fm.shift.taskSort` | declared in ShiftController | Tasks |  |
| `state.fm.snippetExpansionEnabled` | Saved preference `fm.snippetExpansionEnabled` | declared in AppSettings | Settings › Capture |  |
| `state.fm.systemDarkThemeID` | Saved preference `fm.systemDarkThemeID` | declared in AppSettings | Settings › Appearance |  |
| `state.fm.systemLightThemeID` | Saved preference `fm.systemLightThemeID` | declared in AppSettings | Settings › Appearance |  |
| `state.fm.terminalShortcuts` | Saved preference `fm.terminalShortcuts` | declared in AppSettings | Settings › Terminal |  |
| `state.fm.themeID` | Saved preference `fm.themeID` | declared in ThemeManager | Settings › Appearance |  |
| `state.fm.themeMode` | Saved preference `fm.themeMode` | declared in ThemeManager | Settings › Appearance (legacy key, migrated) |  |
| `state.fm.todayCalendarRetired` | Saved preference `fm.todayCalendarRetired` | declared in TodayCalendarRetirement | System (one-time cleanup of the retired Today page's keys, unchanged) |  |
| `state.fm.uiTextScale` | Saved preference `fm.uiTextScale` | declared in AppSettings | Settings › Appearance |  |

## Shell chrome

The floating bar and the other window-level surfaces. These are what the migration replaces, so every row names what takes its job.
Step 5 deletes the bar; until each row's Evidence names the new shell's code, these rows fail.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `chrome.wordmark` | The app's logo tile and "Grand Line" wordmark | Bar, leading edge, on Home | Sidebar (the workspace header at the top of the sidebar: Grand Line, this Mac) | `DaylightBarController.swift` `NSTextField(labelWithString: "Grand Line")` |
| `chrome.spacePills` | Five space pills that filter Home's card grid | Bar, centre, on Home | Sidebar (the four groups are the spaces; Home keeps its own card set) | `DaylightBarController.swift` `var onSelectSpace` |
| `chrome.spaceFilter` | Home's canvas shows one space's cards at a time | Home canvas, picked by a pill | Home (Customize adds any card to Home; the module pages are one sidebar click away) | `DaylightSpace.swift` `func isVisible(in space` |
| `chrome.drillBack` | Back to Home from any page | Bar's drill header back chevron | Toolbar (back and forward buttons at the leading edge) | `DaylightBarController.swift` `var onDrillBack` |
| `chrome.drillTitle` | The page's tile and title | Bar's drill header | Toolbar (the module title; Connections and Console show none, per the captain) | `HelmDrillHeader.swift` `final class HelmDrillHeader` |
| `chrome.drillSubtitle` | A page's live subtitle (counts, sync state) | Bar's drill header, from each page's `drillHeaderSubtitle` | Toolbar (the subtitle under the module title, same live text) | `DestinationRegistry.swift` `var drillHeaderSubtitle: String? { get }` |
| `chrome.drillActions` | A page's own action cluster | Bar's drill header, right side, from `drillHeaderActions` | Toolbar (module toolbar items; see the Toolbar actions rows) | `DaylightBarController.swift` `func setDrillActions` |
| `chrome.searchPill` | Search pill with its ⌘K badge | Bar, trailing | Toolbar (search field with the ⌘K hint) | `DaylightBarController.swift` `final class DaylightSearchPill` |
| `chrome.recents` | Recents dropdown: recently visited pages and hosts | Bar, trailing, after search | Toolbar (back and forward buttons, with Recents as their menu) | `RecentDestinationsPopover.swift` `final class RecentDestinationsController` |
| `chrome.quickAccess` | Captain-configured quick-access squares (default: Sticky Board, Code Preview, Tasks, Straw Hat, Poneglyph, Console, Hosts) | Bar, trailing | Sidebar (a Pinned section at the top, in the captain's order, from the same saved list) | `QuickAccessConfiguration.swift` `struct QuickAccessConfiguration` |
| `chrome.quickAccessOverflow` | "More destinations" overflow when the squares do not fit | Bar, below 1300pt | Sidebar (the Pinned section scrolls with the sidebar; nothing overflows) | `DaylightBarController.swift` `quickAccessOverflowButton` |
| `chrome.quickAccessPin` | Pin or unpin a page to the quick-access row | Right-click a page in the ⌘⇧D map | Sidebar (Pin and Unpin on a sidebar row's context menu) | `AppShellController.swift` `func toggleQuickAccessPin` |
| `chrome.allDestinations` | The ⌘⇧D map of every page | Floating panel over the window | Sidebar (the sidebar is the whole map; ⌘⇧D reveals and focuses it) | `AllDestinationsOverlay.swift` `final class AllDestinationsOverlayController` |
| `chrome.themeToggle` | Light and dark quick toggle | Bar, trailing | Toolbar (trailing cluster; the captain kept it, see the header) | `DaylightBarController.swift` `final class DaylightThemeToggleButton` |
| `chrome.notificationCenter` | The bell and the Notification Center popover (crew decisions, failing checks, lasting reports) | Bar, trailing | Toolbar (a notifications button in the trailing cluster; the captain kept it, see the header) | `NotificationCenterPopover.swift` `final class NotificationCenterController` |
| `chrome.avatar` | Avatar menu: Settings and Log out | Bar, trailing edge | Sidebar (the workspace header's menu: Settings, Log out) | `DaylightBarController.swift` `final class AvatarLogoutPopoverController` |
| `chrome.focusChip` | Running focus timer chip and its ring popover | Bar, before the search pill, while a timer runs | Status line (the focus timer chip and ring popover) | `FocusTimerViews.swift` `final class FocusTimerChip` |
| `chrome.scrollEdge` | The bar deepens its shadow once the page scrolls | Bar | Toolbar (the system toolbar's own scroll-edge effect) | `DaylightBarController.swift` `func setScrollEdgeActive` |
| `chrome.windowChrome` | Traffic lights set into the bar, no title bar | Window | Window (a standard unified title bar and toolbar; traffic lights over the sidebar) | `WindowChromeFusion.swift` `enum WindowChromeFusion` |
| `chrome.fullScreenFill` | Fills the menu-bar strip in full screen | Window | Window (unchanged) | `FullScreenMenuBarFill.swift` `final class FullScreenMenuBarFill` |
| `chrome.pageCrossfade` | Crossfade between pages | Body area | Window (the content transition between modules) | `PageCrossfade.swift` `final class PageCrossfade` |
| `chrome.statusLine` | One row of live indicators: crew needs, sessions, a failing service, vault lock, Claude usage, sync | Not in the app today; the same signals are spread over Home cards and the bell | Status line (new, from the review's Direction B; reads the existing signals) | `BackgroundSignalsPoller.swift` `final class BackgroundSignalsPoller` |
| `chrome.toast` | Toasts for transient confirmations | Under the bar | Window (bottom centre, under the content) | `Toast.swift` `enum Toast` |
| `chrome.feedback` | One router between toast, bell entry and modal | Every page | Every module (unchanged) | `Feedback.swift` `enum Feedback` |
| `chrome.clipboardHistory` | ⌘⇧V clipboard history panel | Drops from the bar beside Recents | Window (the same panel, anchored under the toolbar) | `ClipboardHistoryPicker.swift` `final class ClipboardHistoryController` |
| `chrome.shortcutsSheet` | Keyboard Shortcuts sheet, generated from the menu | Help menu, ⇧⌘/ | Main menu › Help (unchanged) | `KeyboardShortcutsSheetController.swift` `final class KeyboardShortcutsSheetController` |
| `chrome.manualChecks` | Manual checks list | Help menu | Main menu › Help (unchanged) | `main.swift` `func showManualChecks` |
| `chrome.welcome` | First-run welcome sheet and tour | First launch | Window (unchanged first-run sheet) | `WelcomeSheetController.swift` `final class WelcomeSheetController` |
| `chrome.lockScreen` | App lock screen | Covers the window | Window (the lock overlay covers sidebar, toolbar, content and inspector) | `LockScreenController.swift` `final class LockScreenController`; `LockPresenter.swift` `func install(in parent: NSViewController, over root: NSView)` |
| `chrome.theme` | 26 palettes, the Daylight and Dusk pair, follow system appearance | Settings > Appearance and the bar toggle | Settings › Appearance (unchanged) | `ThemeManager.swift` `final class ThemeManager` |
| `chrome.splitSidebars` | Seven pages with a real split-view sidebar and ⌥⌘S to toggle it | Pages' own columns | Every module (a page column stays inside its module; ⌥⌘S toggles the workspace sidebar) | `HelmSplitPage.swift` `final class HelmSplitPage` |
| `chrome.singleInstance` | One running copy of the app | Launch | System (unchanged) | `SingleInstanceGuard.swift` `SingleInstanceGuard` |
| `chrome.quitGuard` | Quit is guarded while work is in flight | Quit | System (unchanged) | `QuitGuard.swift` `final class QuitGuard` |

## Home

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `surface.home.greeting` | Time-of-day greeting with the fleet verdict | Home hero | Home (the page heading and its subtitle) | `HomeCanvasController.swift` `func renderGreeting` |
| `surface.home.needsAttention` | Needs you: due-today tasks, crew decisions and failing checks, with inline Reply | Home's attention column | Home (the Needs you card, first in the default set) | `NeedsAttentionCard.swift` `final class NeedsAttentionCard` |
| `surface.home.briefing` | Morning briefing paragraph, Regenerate and Dismiss until tomorrow | Home card | Home (Morning briefing card) | `MorningBriefingCard.swift` `final class MorningBriefingCard` |
| `surface.home.claudeUsage` | Claude's five quota figures as a usage report | Home card | Home (Claude card) | `HomeCanvasController.swift` `private func fillClaudeStatus` |
| `surface.home.mergeQueue` | Merge queue with Merge on the ready PRs | Home card | Home (Merge queue card) | `HomeCanvasController.swift` `private func fillMergeQueue` |
| `surface.home.firstRun` | First-run invitation copy when nothing is saved yet | Home hero | Home (unchanged copy) | `HomeCanvasController.swift` `static func firstRunHeroCopy` |
| `surface.home.customize` | Customize Home: reorder, size, hide and restore cards | Not in the app today | Home (new: the configurable card set from the prototype) | `DaylightSpace.swift` `var appearsOnOverview: Bool` |

## Crew

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `surface.fleet.dashboard` | Fleet dashboard: KPI tiles, in-flight crewmates, setup banner | Fleet page, Dashboard tab | Crew › In flight | `FleetController.swift` `case overview, log` |
| `surface.fleet.log` | The fleet log with its filters | Fleet page, Log tab | Crew › Log | `FleetLogListView.swift` `final class FleetLogListView` |
| `surface.fleet.reply` | Reply to a crewmate's decision | Fleet rows and Home's Needs you | Crew › Needs you | `FleetController+Reply.swift` `extension FleetController` |
| `surface.fleet.notifier` | Notifications when the crew needs a decision or finishes | Notification Center | System (unchanged) | `FleetNotifier.swift` `final class FleetNotifier` |
| `surface.review.prList` | Open PRs with checks, Merge and Open | Review page | Crew › Review (ready ones also in Crew › Merge queue) | `ReviewPRListView.swift` `final class ReviewPRListView` |
| `surface.strawHat.chat` | Straw Hat crew chat with confirm-before-write proposals | Straw Hat Pirates page | Crew › Ask the crew | `StrawHatChatView.swift` `final class StrawHatChatView` |
| `surface.strawHat.proposals` | A crew proposal executes only after the captain confirms | Straw Hat chat | Crew › Ask the crew (unchanged gate) | `StrawHatProposalExecutor.swift` `enum StrawHatProposalExecutor` |
| `surface.strawHat.roster` | The crew roster | Straw Hat toolbar | Crew › Ask the crew (roster button) | `StrawHatRosterView.swift` `final class StrawHatRosterController` |

## Connections and Console

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `surface.hosts.list` | Saved hosts with search, online filter and Connect | Hosts page | Connections › Hosts (a table with an inspector) | `HostsListSection.swift` `HostsListSection` |
| `surface.hosts.workspace` | Workspace panel: at-a-glance inventory and live sessions | Hosts side panel | Connections › Hosts (inspector and the Sessions tab) | `HostsSidePanels.swift` `final class HostsWorkspacePanel` |
| `surface.hosts.editor` | Host editor with jump hosts and port forwarding | Hosts sheet | Connections › Hosts (editor sheet; quick edits in the inspector) | `HostEditorController.swift` `final class HostEditorController` |
| `surface.hosts.quickConnect` | Quick connect to user@host | Hosts menu and ⌘K | Connections › Hosts (and ⌘K `ssh user@host`) | `Navigator.swift` `func revealHostsQuickConnect` |
| `surface.hosts.multiSend` | Send one command to many hosts | Hosts page | Connections › Hosts (send to many hosts) | `MultiHostSend.swift` `enum MultiHostSend` |
| `surface.hosts.keyGen` | Generate or import an SSH key into the Keychain | SSH Keys column | Connections › Keys | `SSHKeyGenerator.swift` `SSHKeyGenerator` |
| `surface.console.firstmate` | The shared Firstmate shell, opened at launch | Console page | Console (the Firstmate session, which cannot be ended) | `ConsoleController+Sessions.swift` `func openFirstmateHost` |
| `surface.console.ssh` | Dedicated host pages that connect over ssh | Console, one page per host | Console (one sidebar child per live session) | `ConsoleController+Sessions.swift` `func connectSSH` |
| `surface.console.tabs` | Terminal tabs with rename, duplicate, reconnect and close | Console tab strip | Console (tab strip, unchanged) | `TabChipView.swift` `final class TabChipView` |
| `surface.console.splits` | Split panes right, left and down, focus and zoom | Console | Console (unchanged) | `ConsoleController+Splits.swift` `func splitFocusedPane` |
| `surface.console.reconnect` | Auto-reconnect with backoff and a fast-failure stop | Console tabs | Console (the reconnect band, unchanged) | `TabModel.swift` `enum ConsoleReconnectPolicy` |
| `surface.console.startupSnippet` | A host's startup command waits at the prompt | Console on connect | Console (unchanged) | `StartupSnippetGate.swift` `enum StartupSnippetGate` |
| `surface.console.sreLead` | SRE Lead investigation pane per tab | Console toolbar; the pane slides in at the terminal's trailing edge | Console (the same pane at the terminal's trailing edge, unchanged; it stays Console's own pane rather than becoming an inspector item) | `SRELeadChatView.swift` `final class SRELeadChatView` |
| `surface.console.compose` | Compose a command with AI and insert it at the prompt | Console toolbar popover | Console (Compose popover, unchanged) | `ConsoleCommandComposer.swift` `enum ConsoleCommandComposer` |
| `surface.console.claudeUsage` | Claude usage ring popover | Console toolbar | Console (Claude usage popover, unchanged) | `QuotaUsagePopover.swift` `final class QuotaUsageController` |
| `surface.console.blocks` | Block view of parsed commands | Console toolbar, host pages | Console (unchanged) | `TerminalBlockTracker.swift` `final class TerminalBlockTracker` |
| `surface.console.incident` | Incident mode with its card and postmortem | Console toolbar, host pages | Console (incident band and card, unchanged) | `IncidentCardView.swift` `final class IncidentCardView` |
| `surface.console.kubeBadge` | Kubernetes context and namespace badge | Console toolbar, host pages | Console (unchanged) | `KubeContextBadgeStatus.swift` `KubeContextBadgeStatus` |
| `surface.console.dragForwarding` | Forward drags into the terminal app | Console toolbar, shell tabs | Console (App Selection button, unchanged) | `DragForwardingIndicator.swift` `enum DragForwardingIndicator` |
| `surface.console.herdr` | Restart herdr from the Firstmate console | Console toolbar, Firstmate only | Console (unchanged) | `ConsoleController+Herdr.swift` `herdrRestartButtonClicked` |
| `surface.console.logCapture` | Analyze Logs sends a tab's output to the Log Analyzer | Console toolbar | Console (Analyze Logs, unchanged) | `ConsoleController+LogCapture.swift` `func analyzeLogsTapped` |
| `surface.console.scrollback` | Background tabs shrink their scrollback and restore it | Console | Console (unchanged) | `ConsoleController+Scrollback.swift` `func shrinkScrollbackForBackground` |
| `surface.console.theme` | The terminal follows the app's light and dark theme | Console | Console (unchanged; the prototype asks for this too) | `HerdrThemeSync.swift` `HerdrThemeSync` |
| `surface.commands.library` | DevOps command library with parameters, risk levels and AI | DevOps Commands page | Connections › Commands | `CommandLibraryViews.swift` `enum CommandRiskConfirmation` |
| `surface.commands.workflow` | Multi-step command workflows | DevOps Commands page | Connections › Commands (unchanged) | `CommandLibraryWorkflow.swift` `enum CommandLibraryWorkflow` |

## Tasks

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `surface.tasks.board` | Kanban board with lanes and drag between them | Tasks, Board view | Tasks › Board | `ShiftBoardViews.swift` `ShiftBoardPasteboard` |
| `surface.tasks.followUps` | Follow-ups with snooze | Tasks page | Tasks (follow-ups become a sidebar smart view) | `ShiftFollowUpEditorController.swift` `ShiftFollowUpEditorController` |
| `surface.tasks.projects` | Projects with a detail page | Tasks page | Tasks (projects become sidebar children) | `ShiftProjectDetailView.swift` `final class ShiftProjectTaskListView` |
| `surface.tasks.editor` | Task editor: project, due, priority, repeat, remind, notes, attachments | Tasks sheet | Tasks (editor sheet; its fields also fill the inspector) | `ShiftTaskEditorController.swift` `ShiftTaskEditorController` |
| `surface.tasks.recurrence` | Recurring tasks and reminder offsets | Task editor | Tasks (unchanged) | `ShiftRecurrence.swift` `struct ShiftRecurrence` |
| `surface.tasks.weeklyReview` | Weekly review with time on tasks | Tasks, Review view | Tasks › Weekly review | `ShiftController.swift` `static let reviewViewID` |
| `surface.tasks.sync` | Git sync of the task store, with conflict resolution | Tasks sync pill | Tasks (sync state in the toolbar and the status line) | `ShiftGitSync.swift` `final class ShiftGitSync` |
| `surface.tasks.duePush` | Due and overdue task notifications | Notification Center | System (unchanged) | `ShiftDuePush.swift` `enum ShiftDuePush` |
| `surface.capture.router` | ⌥Space capture routes to a task, a note, a link or a sticky | Quick capture panel | System (unchanged) | `CaptureRouter.swift` `enum CaptureRouter`; `CaptureFilingService.swift` `func file(_ destination: CaptureDestination` |
| `surface.focusTimer` | Task-bound focus timer | Tasks and the bar chip | Status line (and Tasks, unchanged controller) | `FocusTimer.swift` `final class FocusTimerController` |

## Knowledge

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `surface.notebook.tree` | Notebook page tree, daily notes and Today | Notebook page | Knowledge › Notebook | `NotebookController.swift` `todayButton` |
| `surface.notebook.links` | Wiki-links and backlinks | Notebook | Knowledge › Notebook (backlinks in the inspector) | `NotebookLinks.swift` `struct NotebookBacklinkIndex` |
| `surface.notebook.modes` | Source, Split and Preview modes | Notebook | Knowledge › Notebook (unchanged) | `NotebookController.swift` `case edit, split, preview` |
| `surface.runbooks.grid` | Runbooks with an editor and a run in the terminal | Runbooks page | Knowledge › Runbooks | `RunbooksController.swift` `newRunbookButton` |
| `surface.postmortems.list` | Postmortems, including SRE Lead's generated ones | Postmortems page | Knowledge › Postmortems | `SRELeadPostmortem.swift` `enum SRELeadPostmortem` |
| `surface.docs.playbook` | The DevOps Playbook viewer with back, forward and reload | Docs page | Knowledge › Playbook | `DocsController.swift` `openLiveButton` |
| `surface.readingList.cards` | Saved links with titles, tags, read state and an opt-in summary | Reading List page | Knowledge › Reading list | `ReadingListAI.swift` `enum ReadingListAI` |

## Secrets

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `surface.poneglyph.unlock` | Unlock the vault with the password or Touch ID | Poneglyph page | Secrets › Poneglyph (lock state also on the sidebar item) | `CredentialVaultStore.swift` `func unlockWithTouchID` |
| `surface.poneglyph.list` | Credential list, inspector, copy, reveal and TOTP ring | Poneglyph page | Secrets › Poneglyph (table and inspector) | `PoneglyphTOTPViews.swift` `final class TOTPRingView` |
| `surface.poneglyph.kinds` | Filter credentials by kind: logins, 2FA codes, secure notes | Poneglyph column | Secrets › Poneglyph (the vault's own filter column, unchanged) | `CredentialVaultSidebar.swift` `title: "2FA codes"` |
| `surface.poneglyph.import` | Import credentials from a CSV export | Poneglyph page | Secrets › Poneglyph (unchanged) | `CredentialVaultImport.swift` `enum CredentialVaultImport` |
| `surface.poneglyph.recovery` | Recovery key enrolment and a printable recovery kit | Poneglyph page | Secrets › Poneglyph (unchanged) | `CredentialVaultRecovery.swift` `enum CredentialVaultRecovery` |
| `surface.poneglyph.generator` | Password generator | Poneglyph editor | Secrets › Poneglyph (unchanged) | `PasswordGeneratorPanel.swift` `PasswordGeneratorPanel` |
| `surface.vault.panel` | Automic Vault secret names, hardeners and recipes | Vault page | Secrets › Automic Vault | `VaultRecipe.swift` `struct VaultRecipe` |

## Observe and Workbench

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `surface.logs.analyzer` | Paste or capture output, analyse, redact, explain, create an RCA | Log Analyzer page | Logs (unchanged page) | `LogRedactor.swift` `enum LogRedactor` |
| `surface.kubernetes.logTail` | Multi-pod log tail | Kubernetes, Log Tail tab | Kubernetes › Log Tail | `KubeLogTail.swift` `final class KubeLogMerger` |
| `surface.health.services` | Background service health and copied diagnostics | Health page | Health (and the status line's failing-service indicator) | `ServiceHealth.swift` `final class ServiceHealthRegistry` |
| `surface.schedules.runner` | Scheduled runs with history, logs and insights | Schedules page | Schedules (unchanged) | `ScheduleRunner.swift` `final class ScheduleRunner` |
| `surface.tools.scratchpad` | Scratchpad calculator with units, currency and dates | Tools, Scratchpad tab | Tools (unchanged) | `ScratchpadEngine.swift` `enum ScratchpadEngine` |
| `surface.whiteboard.canvas` | Excalidraw canvas with AI diagrams, the DSL, capture and copy | Whiteboard page | Whiteboard (unchanged) | `WhiteboardController.swift` `dslButton` |
| `surface.stickyBoard.notes` | Sticky notes with colours, archive and promote to a task | Sticky Board page | Sticky Board (unchanged) | `StickyBoardController.swift` `newNoteButton` |
| `surface.code.run` | Code preview with sandboxed Run and Format | Code Preview page | Code (unchanged) | `CodeRunner.swift` `final class CodeRunner` |
| `surface.dictation.hud` | Dictation with a HUD, history, vocabulary, clean-up and local Whisper | Dictation page and hotkey | Dictation (unchanged) | `DictationHUD.swift` `final class DictationHUDController` |

## Setup and Settings

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `surface.setup.steps` | Setup step checks shared by Bootstrap and Automation | Bootstrap and Automation pages | Setup › Setup steps (one status model for the whole module) | `SetupStepChecks.swift` `enum SetupStepChecks` |
| `surface.setup.dotfiles` | Dotfiles auto-sync | Bootstrap page | Setup › Setup steps (unchanged) | `DotfilesAutoSync.swift` `final class DotfilesAutoSync` |
| `surface.settings.search` | Search Settings by keyword | The Settings page's own search field | Toolbar (the search field and ⌘K find Settings categories and rows by the same keywords) | `SettingsController.swift` `func buildSidebarSections(filter: String` |
| `surface.settings.backup` | Export and import a .glbackup bundle | Settings > Backup & Restore | Settings › Backup & Restore (unchanged) | `BackupUI.swift` `enum BackupUI` |
| `surface.settings.sudoTouchID` | Touch ID for sudo | Settings > Security | Settings › Security (unchanged) | `SudoTouchIDData.swift` `enum SudoTouchIDStatus` |

## Gates

The checks that stand between the captain and an irreversible or secret-revealing action. None of them is shell code, and each one travels with its surface.

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `gate.appLock` | App lock: idle and session timers and the lock screen | Whole app | Window (the lock overlay; every module sits under it) | `AppLockGate.swift` `enum AppLockedSurface` |
| `gate.poneglyphReveal` | Touch ID before revealing a protected credential | Poneglyph | Secrets › Poneglyph (unchanged) | `CredentialVaultController.swift` `requiresTouchIDToReveal` |
| `gate.avApproval` | Nothing unattended calls `av list` | Vault and its poller | Secrets › Automic Vault (unchanged) | `VaultData.swift` `func loadToolStatus` |
| `gate.commandRisk` | Risk confirmation before a destructive command runs | DevOps Commands and ⌘K | Connections › Commands (unchanged) | `CommandLibraryViews.swift` `enum CommandRiskConfirmation` |
| `gate.aiAuthored` | An AI-authored command always asks first | Command library | Connections › Commands (unchanged) | `CommandLibraryViews.swift` `func confirmAIAuthored` |
| `gate.configPrivacy` | The config repo must be private before any push | Every git sync | System (unchanged) | `ConfigRepoPrivacy.swift` `enum ConfigRepoPrivacy` |
| `gate.destructive` | One confirmation for an irreversible delete | Every delete | Every module (unchanged) | `DestructiveConfirm.swift` `enum DestructiveConfirm` |
| `gate.sandbox` | Captain-authored code runs only under sandbox-exec | Code Preview's Run | Code (unchanged) | `CodeRunner.swift` `sandbox-exec` |

## Global hotkeys, menu bar extras and the system

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `hotkey.quickCapture` | ⌥Space quick capture from anywhere | System-wide, configurable in Settings > Capture | System (global hotkey, unchanged) | `ShiftQuickCapture.swift` `final class ShiftGlobalHotkey` |
| `hotkey.dictation` | Dictation hotkey from anywhere | System-wide, configurable on Dictation | System (global hotkey, unchanged) | `DictationHotkey.swift` `final class DictationHotkey` |
| `hotkey.openApp` | Open Grand Line from anywhere | System-wide, Settings > Menu Bar | System (global hotkey, unchanged) | `CompactMode.swift` `globalMonitor` |
| `hotkey.snippetExpander` | ;abbrev snippet expansion in any app | System-wide, Settings > Capture | System (unchanged) | `SnippetExpander.swift` `final class SnippetExpander` |
| `tabkey.newTab` | ⌘T opens a new shell tab | Console and Tools, while showing | Console (unchanged; the key monitor still checks the showing module) | `TabKeyboardShortcuts.swift` `case "t": return .newTab` |
| `tabkey.duplicate` | ⌘D duplicates the tab | Console and Tools | Console (unchanged) | `TabKeyboardShortcuts.swift` `case "d": return .duplicate` |
| `tabkey.close` | ⌘W closes the tab | Console and Tools | Console (unchanged) | `TabKeyboardShortcuts.swift` `case "w": return .close` |
| `tabkey.reconnect` | ⌘R reconnects the tab | Console | Console (unchanged) | `TabKeyboardShortcuts.swift` `case "r": return .reconnect` |
| `tabkey.rename` | Rename the tab from the keyboard | Console and Tools | Console (unchanged) | `TabKeyboardShortcuts.swift` `case .rename: target.renameCurrentTab()` |
| `tabkey.select` | ⌘1-⌘9 select a tab while a tab-bearing page shows | Console and Tools | Console (unchanged; elsewhere ⌘1-⌘6 select sidebar modules) | `TabKeyboardShortcuts.swift` `case .select(let index): target.selectTab(atIndex: index)` |
| `extra.tasks` | Tasks menu bar extra | Menu bar | Menu bar extra (unchanged) | `ShiftMenuBar.swift` `final class ShiftMenuBarController` |
| `extra.poneglyph` | Poneglyph menu bar extra with copy and TOTP | Menu bar | Menu bar extra (unchanged) | `PoneglyphMenuBar.swift` `final class PoneglyphMenuBarController` |
| `extra.strawHat` | Straw Hat menu bar extra | Menu bar | Menu bar extra (unchanged) | `StrawHatMenuBar.swift` `final class StrawHatMenuBarController` |
| `extra.compactMode` | Compact mode: the app lives in the menu bar with a four-tab popover | Menu bar | Menu bar extra (unchanged) | `CompactMode.swift` `final class CompactModeController` |
| `system.notificationCenter` | The app's notification store and its sources | Bell, Home, the poller | System (unchanged; read by the toolbar's notifications button and the status line) | `GrandLineNotificationCenter.swift` `GrandLineNotificationCenter` |
| `system.widgetSnapshot` | Publishes the widget snapshot and drains queued widget taps | App | System (unchanged) | `WidgetSnapshotPublisher.swift` `final class WidgetSnapshotPublisher` |
| `system.widgetComplete` | Complete a task from the Tasks widget | Widget | System (widget button, unchanged) | `CompleteTaskIntent.swift` `struct CompleteTaskIntent` |
| `system.clipboardStore` | Encrypted clipboard history that refuses concealed items | App | System (unchanged) | `ClipboardHistoryStore.swift` `final class ClipboardHistoryStore` |
| `system.appearanceFollower` | Follows the system's light and dark setting | App | System (unchanged) | `SystemAppearanceFollower.swift` `final class SystemAppearanceFollower` |

## Live sessions and recents

| ID | Feature | Today | New shell | Evidence |
|---|---|---|---|---|
| `session.registry` | Live session registry: state per host, used by the switcher and ⌘K | App | Console (the sidebar's session children read it) | `HostSessionRegistry.swift` `final class HostSessionRegistry` |
| `session.strip` | Session strip of live sessions with a status dot | Under the bar | Console (the Sessions strip above the tabs; also sidebar children) | `SessionStripView.swift` `final class SessionStripView` |
| `session.restore` | Reopens the last page and the host sessions at launch | Launch | Navigator (restores the same route and sessions) | `SessionRestore.swift` `struct SessionRestoreState` |
| `session.recents` | Recently visited pages and hosts | Recents dropdown | Navigator (feeds the toolbar's back and forward menus) | `RecentDestinations.swift` `final class RecentDestinations` |
