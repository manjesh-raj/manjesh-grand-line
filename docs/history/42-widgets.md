# Widgets (F23)

`fm/grandline-feature-f23-widgets`.
F23 of full review #3 §8: "A Tasks-due and a Sticky-note WidgetKit extension (needs a real bundle + signing; blocked on the Developer ID item). Scope: L."

The operational front door is [`native/Widgets/README.md`](../../native/Widgets/README.md) - how to build it, and the exact boundary of what the signing gap blocks.
This file is what the branch did and why.

## What shipped

A real WidgetKit extension, built by `swiftc` and a hand-written `Info.plist` (SwiftPM has no bundle-product target, so this follows `build_native_app.sh`'s existing "assemble the bundle by hand" shape rather than introducing an Xcode project).

- **Tasks due**, small and medium. Small: the identity tile, "Today", a `N late` pill, three tappable rows, `3 of 6 open`. Medium: the day's own headline, four rows in two columns each with a sub-label, follow-ups pending and an `updated 14:20` stamp.
- **Sticky note**, small and medium. Small is the note itself - its own paper reaching the widget's edge. Medium is up to three notes on the app's card ground. Which note is a WidgetKit *configuration* (`AppIntentConfiguration` + an `AppEntity` query over the published notes), which is the answer to the mockup's `STICKY · PINNED` label.
- **Interactive**, which is the whole reason this is worth an L. `Button(intent: CompleteTaskIntent(...))` on each task row - macOS 14.
- **The data pipeline**: `WidgetSnapshotPublisher` (app) writes a versioned snapshot into the App Group container on every store change and reloads the timelines; `GrandLineWidgetAction` (both) is the reverse channel a tap writes into; `drainPendingActions` applies it through `ShiftStore`.

## The three decisions worth recording

### A published snapshot, not the widget reading the stores

The obvious design - point the extension at `notes.yaml` and `active.yaml` - was rejected before it was tried.
Those files live under a git working tree that `ShiftGitSync` commits on a debounce and pulls on a schedule, and this repo has already paid for a second writer racing `.git/index.lock`.
A widget needs six task titles, not a merge engine.

So the app publishes a small, capped, versioned projection and the widget process never opens the captain's real data at all.
That also keeps the extension's sandbox requirement down to one shared container, which matters because a widget extension's sandbox is not optional.

The snapshot is capped at 12 tasks, 12 notes and 400 characters of note body (GL-35), and it carries only *dated* open tasks - an undated task is never a row, so shipping it would put a task title in a shared container for nothing. It is still counted in `openTaskCount`, which is what keeps "3 of 6 open" honest.

### A tap queues, the app applies

`CompleteTaskIntent.perform()` runs in the extension. It does not write YAML - it writes `actions/<uuid>.json` into the shared container, and the app drains it on launch and on activation through `ShiftStore.setTaskCompleted`.

Not tidiness. Completing an occurrence of a recurring task is what *schedules the next one* (`ShiftStore.nextOccurrence`), so a widget that wrote the file itself would silently break every repeating task ticked from the desktop. The self-test asserts exactly that: ticking `Standup notes` from the widget queue produces a new task due the next weekday.

One file per action rather than one queue file, deliberately: two processes doing read-modify-write on one file with no coordination lose actions, and a widget tap that silently does nothing is worse than a widget that cannot tick at all.

The honest cost is that the row does not vanish on tap. The widget says so - struck through, "applies when the app opens" - rather than pretending.

### The app's register travels in the snapshot

A widget would normally follow the system appearance. This app's theme is a choice out of fourteen palettes and **Dusk (dark) is the default on a Mac that may be in light mode**, so `ThemeManager.shared.theme.mode` is published in the snapshot and the widget draws that. `colorScheme` is the fallback for the one case with no snapshot to read - the `Not available` state, where there is nothing else to go on.

## Where this deviated from the reviewed mockup, and why

The mockup (F23's section of the `grandline-future-features-mockups-artifact` deck) was followed closely. Three deliberate differences:

1. **The Tasks identity tile is rose, not violet.** The mockup drew it violet; the app's own `RailDestination` → `HelmDomainHue` table says Tasks is `rose` and the Sticky Board is `amber`, and `HelmDomainHue`'s header is explicit that identity colours do not move. A widget using a different hue for Tasks than every other Tasks surface would be the one place the captain's colour language breaks.
2. **A recurring row reads `today · repeats`, not `repeats weekdays`.** The mockup's version replaces the due day with the rule's wording. `ShiftRecurrence.displayName` is the app's single derivation of that wording and it lives in the app, not the extension - so the widget carries the summary as data and prints a marker instead of re-wording a rule in a second binary. The row keeps its *when*, which is strictly more information on a canvas where the day is the point.
3. **The medium header carries the `N late` pill, not the mockup's "tap a row to tick it" hint.** Both cannot fit on one 352pt header row, and one of them is information about the day while the other is a tutorial the captain reads once. The tick is discoverable by the checkbox being a real button, and a *pending* tick explains itself in the row's own sub-label.
4. **`STICKY · PINNED` only when the captain actually chose that note.** Unconfigured, the kicker reads `STICKY · NEWEST`, because an unconfigured widget's note genuinely changes under them. `StickyNote` gained no `pinned` flag: a note choice is per-widget (two sticky widgets should be able to show two notes), which is what WidgetKit's own configuration is for, and a board-level pin would have been a model change - a new field, a GL-01 decoder default, a synced schema bump, a board affordance - driven by a widget rather than by the board.

## GL-14, which this feature is most exposed to

A widget will happily draw an empty `TimelineEntry`, and an empty `VStack` reads exactly like a finished day.

So the load path has real states: `.neverPublished` (no file - the expected case until the entitlement lands), `.unreadable` (GL-01: present-but-unreadable is its own state), `.schemaTooNew` (the app and the extension are two binaries that can run out of step), `.locked`, and `.ready`. Each unavailable reason has its own headline and its own detail, and the suite asserts none of them borrows the wording of a finished day. A genuinely empty day says "Nothing due" - a different claim, worded differently on purpose.

The subtler half: a snapshot older than 24h is still drawn (overdue is still overdue) but stamped `as of 19 Sep` rather than `updated 14:20`, so a quiet day and an app that has not run since Friday do not look the same.

## GL-09: the one surface no overlay can cover

A widget is the only thing in this app that renders the captain's data **on the desktop**. No `orderOut`, no lock screen, no popover dismissal reaches it - which is why `.widgetSnapshot` is its own `AppLockedSurface` case and why the gate does two different jobs:

- `publishNow` publishes an explicitly **empty** `.locked` snapshot while locked. A gate that merely declined to write would leave yesterday's tasks sitting on the desktop for whoever locked the app. Counts go too - "3 due today" is a real disclosure, which is `ShiftMenuBarController`'s own conclusion for the same reason.
- `drainPendingActions` refuses to apply a tapped tick while locked, and **keeps** the request queued - the captain did tap it, and it lands after the unlock.

Confirmed by injection: replacing the gate's `guard` with `if false` failed six named cases, including "the request must be *kept*, not dropped".

The publisher is also started **after** `appLock.lock(reason: .launch)` rather than beside the three menu-bar status items, for two reasons. It reads `appShell.stickyBoardStore`, and forcing that `lazy` property earlier would move `AppShellController`'s construction ahead of the carefully-ordered window/`contentViewController`/lock sequence that `main.swift`'s own comment records having been got wrong once. And publishing after the launch lock means the first snapshot this process writes is the locked one - so a relaunch cannot flash yesterday's tasks onto the desktop before the password has been typed.

## What could and could not be verified

`native/Widgets/README.md` has the table and the raw `codesign`/`spctl` output. In short: the extension compiles and links (warnings as errors), the app half of the pipeline works today ad-hoc signed, and everything that decides content is asserted in CI's blocking lane. No widget has been rendered by the real *widget host* from this branch, because the host will not load an extension whose App Group entitlement has no Team ID behind it.

### The views were rendered, and the render found a bug

The one thing worth taking away from this branch's verification: `ImageRenderer` is a working substitute for this repo's `cacheDisplay` probe when the thing being drawn is SwiftUI rather than an `NSView`. `Scripts/render-widget-previews.sh` compiles the extension's real view files against a small entry point and rasterises thirteen states to PNG at both families' real point sizes, which an agent reads back with `Read`.

It earned its place immediately. The medium Sticky widget drew `STICKY · NEWEST` on **all three** notes - meaningless on the second and third, and wrapped to two lines at 110pt of column, costing a line of each note's own body. The kicker is now on the pinned note only, and only when one is genuinely pinned. Nothing in the timeline logic, the suite or the type system could have found that; it is a "looks wrong on screen" defect, and this repo's whole verification convention exists because those are the ones that ship.

Making the render possible cost one refactor worth knowing about: **`EnvironmentValues.widgetFamily` is read-only** - there is no `.environment(\.widgetFamily, .systemMedium)` - so a view that reads it directly can only ever be drawn by a widget host. Each widget's entry view now reads the environment and hands the family to a `…Body` view as a plain parameter. Both files say so in their own doc comments, because the obvious "simplification" is to fold them back together.

Two measurements worth keeping:

- `containerURL(forSecurityApplicationGroupIdentifier:)` **returns a path without checking any entitlement, and without creating the directory**. For an unsandboxed process it is close to string construction under `~/Library/Group Containers/`. That is why the app half works with no entitlement at all, and it is the reason the blocked half is specifically the *sandboxed extension's* read, not "App Groups don't work here".
- The `swiftc` invocation that produces a loadable `.appex` is `-application-extension -parse-as-library` plus `-Xlinker -e -Xlinker _NSExtensionMain`. Without the last one the bundle is a signed binary with an `_main` no widget host ever calls, and nothing fails loudly.

### Injections run

AGENTS.md's rule is that a test must be confirmed to catch a regression, not merely to pass. Three, each by copying the file aside and editing it (never `git stash`):

| Injection | Failed case |
|---|---|
| `WidgetPalette.dusk.badText` `E07272` → `E07273` | "Dusk: the widget's `badText` should be DaylightTokens' own E07272" |
| `lateCount` back to a bare `dueAt < now` | "exactly one of the mockup's tasks is late (got 3)", + two more |
| `load()` returns `.ready(empty)` for a missing file | "a missing snapshot should load as .neverPublished, never as an empty day" |
| the lock `guard` in `drainPendingActions` → `if false` | six cases, incl. "a locked app must not apply a widget tap" |
| `notifyChanged()` removed from `StickyBoardStore.persist()` | "a write should notify (got 0)" |

### The `lateCount` bug the suite found

Worth recording because it is the kind of thing that reads fine and is wrong on screen. `lateCount` started as `dated.filter { $0.dueAt < now }`. A task due *today with no due time* sits at the start of its own day, so that comparison calls it late from 00:01 - and the pill read "3 late" beside three rows the same digest labelled "today". The widget contradicting itself on a 168pt canvas. It now goes through the same `urgency` function the rows do.

## Deliberately not done

- **No `pinned` flag on `StickyNote`** - see above.
- **No accessory/lock-screen families.** Those are iOS; on macOS the systemSmall/systemMedium pair is what the Notification Center and desktop show, and the mockup draws exactly those three tiles.
- **No second store for widget state.** The snapshot is derived, disposable and rewritten whole; there is nothing in it that is not already in a real store.
- **No `xcodebuild`, no Xcode project.** The project's standing rule, and the hand-assembled bundle keeps `swift build` the only thing a contributor needs.
- **The app bundle was not re-signed as a Developer ID app**, and notarization was not attempted. That is the captain-owned item, tracked in `native/MANUAL-CHECKS.md` §17.

## The App Group container is gated on a Team ID now, and why

The captain was getting a "would like to access data from other apps" dialog on
every launch.
It was the app touching its own App Group container.
On this macOS version `~/Library/Group Containers/<group-id>/` is TCC-protected
app data (`kTCCServiceSystemPolicyAppData`), so an unentitled process reading or
writing under it goes through `sandboxd` and prompts.
A scout investigation confirmed this causally - a bare `/bin/ls` of that one
directory reproduces the prompt - and the full evidence is in
`data/grandline-launch-permission-prompts-investigation/report.md` in
firstmate's own repo.

The measurement this file already records is still correct, and is worth
keeping separate from the new one.
`containerURL(forSecurityApplicationGroupIdentifier:)` really does return a path
with no entitlement check, for an unsandboxed process.
What nobody had measured is that the *first read or write under that path* is a
different question from resolving it, and that one prompts.

So the cost was a dialog on every launch, thirteen launches in twenty-four
hours, each one a fresh TCC `type=Create` record because no grant survived to
the next launch.
The benefit was nothing at all: the extension is not packaged into the shipped
bundle (there is no `Contents/PlugIns/`), and it could not read that directory
if it were, for the Team ID reason this file's "What is blocked, precisely"
section already sets out.

`GrandLineWidgetContainer.directory()` now gates its App Group branch on
`appGroupIsTeamPrefixed` rather than taking it unconditionally.
Until a Team ID exists the snapshot lives in the Application Support fallback
that function already had, which no TCC service protects.
`FM_WIDGET_DIR` still wins over both.

The gate reads `appGroupIdentifier` itself rather than taking a separate flag,
which keeps `native/Widgets/README.md`'s "two edits that unblock it" true
unchanged: prefixing that constant with a real Team ID switches the branch back
on, with nothing else to remember.
`isTeamPrefixed` asserts the shape (ten uppercase alphanumerics, then an
ordinary `group.…` identifier) rather than merely "something before `group.`",
so a typo cannot switch the gate on.

The branch was **not** deleted, because the extension will need it the day the
Developer ID item lands.

### How this was verified

Static and mechanical, deliberately.
Triggering a live TCC prompt on the captain's machine to prove the fix would
have put another dialog on his screen, which is what the scout had already done
once by accident.

- `GrandLineWidgetContainer.directory()` is the **only** place in either binary
  that calls `containerURL(forSecurityApplicationGroupIdentifier:)`, and every
  app-side and extension-side caller resolves through it.
  A grep over `Sources/` and `Widgets/` is the whole proof, and it is short.
- `WidgetSnapshotSelfTest.checkTheAppGroupBranchIsGatedOnATeamID` asserts the
  resolved path at runtime, in-process: with no Team ID nothing may resolve into
  `Group Containers`, and the documented Application Support fallback is what
  comes back.
  It also asserts `isTeamPrefixed`'s own discriminating power first, so a
  rewrite that made it constant fails loudly rather than passing vacuously.
- Confirmed to catch the regression, not merely to pass.
  Removing the `appGroupIsTeamPrefixed` condition from `directory()` failed that
  case by name, reporting the real Group Containers path it had resolved to.

The existing App-Group-versus-entitlement assertion
(`checkTheExtensionAndTheContractAgree`) is untouched and still passes: the
constant did not change, only whether `directory()` acts on it.
