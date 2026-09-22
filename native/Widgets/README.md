# GrandLineWidgets - the WidgetKit extension (F23)

Two widgets: **Tasks due** (small, medium) and **Sticky note** (small, medium).
F23 of full review #3 §8, whose own entry says "needs a real bundle + signing; blocked on the Developer ID item".

This file is the honest boundary for that sentence.
It says what is built, what is verified, what is *not* verified, and exactly which two edits turn the second into the first.

## Build it

```
cd native
./Scripts/build-widget-extension.sh --check     # compile + link only
./Scripts/build-widget-extension.sh             # assemble and sign .build/widgets/GrandLineWidgets.appex
./Scripts/build-widget-extension.sh --embed     # also drop it into dist/Manjesh Grand Line.app/Contents/PlugIns
./Scripts/render-widget-previews.sh             # render every state to PNG under .build/widget-previews/
```

SwiftPM has no bundle-product target, so this is `swiftc` plus a hand-written `Info.plist`, the same way `build_native_app.sh` already assembles the app itself.
No Xcode project, no `xcodebuild` - the project's standing rule.
The script compiles with `-warnings-as-errors`, matching GL-07's rule for the app's own sources.

## What actually works today

- **The extension compiles and links.** Against the real macOS SDK, targeting macOS 14, including `Button(intent:)` interactivity and the `AppIntents` entity query behind the sticky widget's configuration.
- **The app half of the data pipeline works.** `WidgetSnapshotPublisher` writes the snapshot into `~/Library/Group Containers/group.com.firstmate.cockpit.native/GrandLineWidgets/` on every store change, and reloads the timelines.
  Measured: for an **unsandboxed** process `containerURL(forSecurityApplicationGroupIdentifier:)` returns a path with no entitlement check at all - it is close to string construction - so the app may simply write there while ad-hoc signed.
- **Everything that decides content is under test.** `FM_RUN_WIDGET_SNAPSHOT_TESTS` covers the projection from the real `ShiftTask`/`ShiftFollowUp`/`StickyNote` types, the snapshot's round trip, the digest both widgets render, GL-14's unavailable and locked states, the reverse action channel, and four source guards over this directory.

## What is blocked, precisely

**A widget extension is always sandboxed by the system.**
Reading that same directory therefore needs `com.apple.security.application-groups`, and an App Group identifier is only honoured when it is prefixed by a real Team ID and the binary is signed by that team.

On this machine, today:

```
$ codesign -dv "dist/Manjesh Grand Line.app"
Identifier=com.firstmate.cockpit.native
TeamIdentifier=not set
$ spctl -a -vv "dist/Manjesh Grand Line.app"
rejected
origin=Firstmate Cockpit Local Dev
$ security find-identity -v -p codesigning
1) ... "Firstmate Cockpit Local Dev"     # self-signed, no team
```

So the consequence is specific rather than vague:

| | Status |
|---|---|
| The `.appex` compiles, links and signs | works |
| The app publishes the snapshot | works |
| The widget appears in the widget gallery | **needs a signed, Developer-ID app bundle** |
| The widget reads the snapshot | **needs a Team-ID-prefixed App Group entitlement** |
| A tick applies to a real task | the app's half is tested; the *tap* needs the two rows above |

A widget that loaded without the entitlement would render its `Not available` state - which is the correct, honest state, and is the one this feature was designed around (GL-14).

## The two edits that unblock it

Once a Developer ID / Team ID exists, this is the whole change:

1. `GrandLineWidgetContainer.appGroupIdentifier` in `Sources/FirstmateCockpit/WidgetSharedContract.swift` becomes `"<TeamID>.group.com.firstmate.cockpit.native"`.
2. The same value in `GrandLineWidgets/GrandLineWidgets.entitlements`.

`WidgetSnapshotSelfTest.checkTheExtensionAndTheContractAgree` fails if the two ever disagree, so they cannot be half-changed.
`build-widget-extension.sh` already detects a `Developer ID Application` identity, rewrites the entitlement's prefix from the certificate's own team, signs with `--options runtime --timestamp`, and prints the constant the contract must match.
The app bundle itself then needs the same treatment in `build_native_app.sh` plus notarization - that is the captain-owned item the report has been tracking all along, and it is tracked in `native/MANUAL-CHECKS.md` §17.

## How this was verified without a widget host

This repo's usual substitute for a screenshot is an off-screen `cacheDisplay`
render (AGENTS.md's "Verifying native UI bugs without a real screenshot").
**It does not apply here**, and saying so is the point: a widget is not an
`NSView`, so there is nothing for that probe to render. Its views are drawn
only by the system's widget host, which will not load an unsigned extension.

What exists instead:

- **`Scripts/render-widget-previews.sh` - a real off-screen render.** `ImageRenderer` over the same SwiftUI views the extension registers, at both families' real point sizes (168x168 and 352x168), 2x, to PNG: thirteen states including both registers, the pending tick, the empty day, the locked state and `Not available`. This is a rasterised render, not a preview, and it found a real defect on its first run - the medium Sticky widget drew `STICKY · NEWEST` on all three notes and wrapped it to two lines, costing a line of each note's body. Nothing in the logic or the type system could have caught that.
  `EnvironmentValues.widgetFamily` is read-only, which is why each widget's entry view reads the environment and hands the family to a `…Body` view as a plain parameter - that split is what makes the render possible.
- `Scripts/build-widget-extension.sh --check` - the extension really compiles, with warnings as errors.
- `#Preview` blocks in `TasksDueWidget.swift` and `StickyNoteWidget.swift`, covering both families, both registers, the pending-tick state, the locked state and the unavailable state. These compile; they render for anyone with Xcode open.
- `FM_RUN_WIDGET_SNAPSHOT_TESTS` - every decision about content, asserted against pinned fixtures and a pinned clock.
- Four source guards in that suite over this directory: the palette must equal `DaylightTokens`, the entitlements must equal the contract's App Group, the `Info.plist` must declare the WidgetKit extension point, and the build script must compile the shared contract out of the app's own sources rather than a pasted copy.

What is **not** verified, stated plainly: no widget has been rendered by the real *widget host* from this branch (`ImageRenderer` resolves the views, not the host's own container shaping, its `containerBackground` compositing, its accent tinting or its refresh budget), no tap has been made on a real desktop, and the App Group's sandbox behaviour for the extension process could not be exercised - the probe that measured the container path was unsandboxed, which is the app's case, not the extension's.

## How the two processes share data

```
ShiftStore ─┐                                    ┌─ TasksDueProvider  ──► Tasks due (S/M)
            ├─► WidgetSnapshotPublisher ──► widget-snapshot.json ──┤
StickyStore ┘        (app, unsandboxed)          └─ StickyNoteProvider ──► Sticky note (S/M)

                        actions/<id>.json  ◄── CompleteTaskIntent  (a tap)
      ShiftStore.setTaskCompleted ◄── drainPendingActions (app, on activation)
```

`WidgetSharedContract.swift` is the only file compiled into **both** binaries, which is why it imports nothing but Foundation.
The extension cannot link the app: the app's own model types reach AppKit, `Yaml` and `SwiftTerm` within a line or two of anything useful.

A tap does **not** write the captain's task files.
Those are YAML under a git working tree `ShiftGitSync` owns on a serial queue, and a second writer races `.git/index.lock` - a lesson this repo has already paid for once.
So the tap queues a request and the app applies it through `ShiftStore.setTaskCompleted`, the same call the Tasks page's own checkbox makes.
That is not tidiness: completing an occurrence is what spawns the next one, so a widget writing YAML directly would silently break every recurring task ticked from the desktop.

The widget says so rather than hiding it - a ticked row goes struck-through and reads "applies when the app opens" until the drain runs.

## Where the rest is written down

- `docs/history/42-widgets.md` - what this branch built, what it measured, what it deliberately left out.
- `AGENTS.md` - the standing rules this feature established.
