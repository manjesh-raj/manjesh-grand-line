# Grand Line - the native app

A Swift + AppKit + SwiftTerm macOS cockpit for observing and lightly driving a
[firstmate](https://github.com/kunchenguid/firstmate) fleet. It is the **only**
app in this repository; the earlier Python/FastAPI + WKWebView cockpit it
replaced has been removed.

No server component. It reads the firstmate home's files directly and shells out
to its `bin/` helpers (`fm-crew-state.sh`, `fm-pr-merge.sh`, `fm-send.sh`, …) -
the same guarded scripts a human would run. **firstmate is never modified.**

This file is the front door. Deeper reading, in order of how often you will
want it:

| Read | For |
|---|---|
| [`../AGENTS.md`](../AGENTS.md) | The standing rules: the AppKit gotcha catalogue, `GL-01`..`GL-38`, the component index, the verification conventions |
| [`../docs/history/`](../docs/history/) | Per-feature history - what shipped, what was tried, what replaced it. Not loaded by default; open the file for the area you are touching |
| [`../README.md`](../README.md) | The complete `FM_*` environment-variable index, releasing, logging |
| [`MANUAL-CHECKS.md`](MANUAL-CHECKS.md) | The things the automated suites provably cannot verify |

---

## ⚠️ Never launch a built copy from a worktree

Every build of this app - a `swift run` binary, `.build/debug/GrandLine`,
and the packaged `dist/Grand Line.app` - shares one bundle identity
(`com.manjesh.grandline.native`). There is **no OS-level process isolation
between them**, so a copy launched from a worktree contends with the captain's
own running instance over the same JSON stores and the same git working tree.

`SingleInstanceGuard` plus `LSMultipleInstancesProhibited` turns most of this
into a clean "already running" exit rather than silent corruption - but the rule
still stands, because the guard *activates the existing instance* instead of
giving you a separate one to test against.

So, when working in a worktree:

- Verify with `swift build` plus `./Scripts/run-all-tests.sh`.
- Do **not** run `swift run`, and do not open the assembled `.app`.
- If you genuinely need a composited window, `./Scripts/build-probe-app.sh`
  builds a separately-identified copy (its own bundle id, its own instance lock,
  its own scratch stores) that is safe to launch alongside the real app.

## Requirements

- macOS 13 or newer, Apple Silicon.
- **Swift 6.x**. Command Line Tools alone are enough - this uses
  `swift build` / `swift run`, never Xcode or `xcodebuild`. Verified on 6.3.3.

CI pins `macos-15` and **asserts the same major** in every job that builds Swift
(`EXPECTED_SWIFT_MAJOR` in `.github/workflows/ci.yml`). That matters: the build
job fails on any warning in this app's own sources, and 5.10 and 6.x genuinely
disagree about diagnostics in both directions, so a warning-clean build on one
says nothing about the other. Bump the runner label, the assertion and this
section together.

## Build

```bash
cd native
swift build
```

First build is ~90s because it compiles the vendored dependencies from source.
The product is a `Mach-O arm64` executable at `.build/debug/GrandLine`.

There are **no remote SPM dependencies** and no `Package.resolved`: everything
is vendored under `Vendor/`, so the build needs no network.

| `Vendor/` | What, and the catch |
|---|---|
| `SwiftTerm` | Pinned to upstream 1.15.0 with **ten local patches** - read `Vendor/SwiftTerm/README.md` before touching or re-syncing it |
| `whisper.cpp` | Local Whisper for dictation, CPU + Metal. The shader is a generated file; see `Scripts/build-whisper-metal-shader.py` |
| `YamlSwift` | Patched for insertion order and quote preservation |
| `Excalidraw`, `Monaco` | Committed, self-contained web bundles for the Whiteboard and Code Preview (the Notebook's source pane loads the same Monaco bundle - one integration, not two). Loaded from disk with no CDN and no runtime download; `swift build` never touches them |
| `ScheduleX` | The same kind of bundle for Tasks' Calendar view. Open-source packages only, and its drag plugin is the last MIT release adapted to the 4.x core - read `Vendor/ScheduleX/README.md` before bumping it |

A change to a vendored web bundle's source needs its `Scripts/build-*-web.sh`
re-run - **the app loads the committed artifact, so a source edit alone is
invisible until runtime.** Those three rebuilds need node/npm; nothing else here
does.

## Test

```bash
./Scripts/run-all-tests.sh                # build, then every suite, with timings
./Scripts/run-all-tests.sh --list         # what would run
./Scripts/run-all-tests.sh --ci           # the headless-safe half
./Scripts/run-all-tests.sh --session-only # the exact complement (window-backed)
./Scripts/run-all-tests.sh --session-only --ci --shard=2/3   # one of CI's three windowed shards
./Scripts/run-all-tests.sh --no-build FM_RUN_SHIFT_STORE_TESTS
```

There is no XCTest target. The app carries a permanent self-test suite per
`FM_RUN_*` flag - `./Scripts/run-all-tests.sh --list` prints the current list
and its total, which is the only place that count is not stale. Each sits
behind its own `FM_RUN_*_TESTS=1` variable and each is handled **before**
`NSApplication` is ever touched - so they run headless and are safe alongside
the real app. The runner discovers its list from `SelfTests/SelfTestDispatch.swift`, so a new suite
joins automatically.

**Always test `.build/debug/GrandLine`.** The suites are compiled into
debug builds only (`FM_SELFTESTS`, GL-27); a release binary runs zero suites and
exits 0, which looks exactly like a clean run.

Each suite reports its own wall clock and the ten slowest are listed again at
the end, so a runtime regression is one line to read.

**Pre-flight, in this order** - all three have bitten a real run:

```bash
git status --porcelain          # must be empty: agents can share a worktree
pgrep -fl run-all-tests        # never two passes at once
defaults read GrandLine fm.themeID   # a known value (dusk)
```

`../AGENTS.md` has the reasoning for each, plus the rule for deciding whether a
new suite is window-backed or pure logic - which decides whether it guards the
blocking CI lane, and is enforced in both directions by
`E2ETestingPolicySelfTest`.

## Package as an app

```bash
cd native
./build_native_app.sh
```

`swift build -c release`, assembled into a real bundle at
`../dist/Grand Line.app` (bundle ID `com.manjesh.grandline.native`) and
installed over `/Applications`. The version comes from `git describe` (GL-18), so
a release is cut by tagging - never by editing a constant. Releases are
unsigned; see the repo-root README.

**The copy being replaced is kept.** The script renames it to
`/Applications/Grand Line (previous).app.bak` before installing, one generation
only, so a bad build always has a last-known-good beside it (P8 of the
2026-09-25 review - it used to `rm -rf` the installed copy first). The `.bak`
suffix means macOS does not register it as a second app under the same bundle
identifier. To roll back, with the app quit:

```bash
rm -rf "/Applications/Grand Line.app"
mv "/Applications/Grand Line (previous).app.bak" "/Applications/Grand Line.app"
```

### App Intents / Shortcuts registration (F21)

The five `AppIntent` types compile into the binary with a plain `swift build`,
but Shortcuts, Siri and Spotlight discover them from a `Metadata.appintents`
bundle that only Xcode's `appintentsmetadataprocessor` can produce. SwiftPM
never runs it.

`build_native_app.sh` runs it itself **when it can find it**, as a packaging
step - the build command is unchanged on a machine without it, so
`swift build` stays Command-Line-Tools-only as this project requires. A bundle
packaged without the processor is not broken: it simply publishes no Shortcuts
actions, and Settings → **Shortcuts & Siri** reads the bundle and says which of
the two states that copy is in.

So: to get the actions registered, package the app on a Mac with Xcode
installed. The script prints a warning when it skips the step.

### The widget extension

```bash
cd native
./Scripts/build-widget-extension.sh --check     # compile + link only
./Scripts/build-widget-extension.sh --embed     # assemble, sign, drop into dist/<app>/Contents/PlugIns
```

`swift build` does **not** build this - SwiftPM has no bundle product, so the
`.appex` is assembled by that script the same way the app bundle is assembled
above. It is blocked on the Developer ID item and the boundary is written out
in [`Widgets/README.md`](Widgets/README.md): what compiles, what runs today,
and the two edits that make the widgets actually load.

The extension declares `AppIntent` types of its own (the tick, and the sticky
widget's note picker), so the section above applies to it too: without
`appintentsmetadataprocessor` the `.appex` carries no `Metadata.appintents`
and the widget's own configuration sheet has no note list to offer. The tick
does not depend on it - a `Button(intent:)` inside a widget is resolved by
WidgetKit directly - and neither half is reachable at all until the signing
work lands.

### Local signing setup (one-time, per machine)

Run this once on each machine that builds the app:

```bash
Scripts/local-signing-identity.sh setup
```

It creates two certificates in the login keychain.

- **"Grand Line Local CA"** is a local certificate authority, valid for 30 years.
  It is the app's identity as far as macOS is concerned, so it is created once and never replaced.
- **"Grand Line Code Signing"** is the certificate builds are actually signed with.
  The CA issues it, and `setup` issues it again whenever it is missing, expired or invalid.

macOS asks for your password once, to trust the CA for code signing.
`Scripts/local-signing-identity.sh status` says which identity a build will use.
It needs `openssl`, either Homebrew's OpenSSL 3.x or the LibreSSL `/usr/bin/openssl` macOS ships.

**Why a CA.**
macOS files every privacy grant (Accessibility, which dictation's paste needs, Screen Recording, Input Monitoring) and every Keychain ACL under the app's designated requirement.
For a self-signed certificate, codesign's default requirement pins that exact certificate:

```text
identifier "com.manjesh.grandline.native" and certificate leaf = H"<certificate sha1>"
```

So recreating the certificate revoked every grant at once, which is what happened on 2026-11-15.
Builds signed by `local-signing-identity.sh` carry an explicit requirement that names the CA instead:

```text
identifier "com.manjesh.grandline.native" and certificate root = H"<CA sha1>"
```

A reissued "Grand Line Code Signing" certificate still satisfies it, so no grant is lost.
A certificate with the same names from any other CA does not.
Saved SSH keys benefit the same way, because a Keychain item's ACL trusts the requirement too.

**Moving an existing machine onto the CA (once).**
Until `setup` has run, builds keep signing with the older self-signed "Grand Line Local Dev" certificate (or "Firstmate Cockpit Local Dev" before that) and print a note saying so.
After `setup`, the first build is signed by the CA, which is a new identity to macOS one last time.
`build_native_app.sh` notices and prints the repair, which is to quit Grand Line and run:

```bash
tccutil reset All com.manjesh.grandline.native
```

Then open Grand Line and allow each permission again when it asks, and choose Always Allow when macOS asks about each saved SSH key.
Once that build is installed, the old certificate can go:

```bash
security delete-identity -c "Grand Line Local Dev"
```

**If the build says the certificate is missing or invalid**, run `setup` again.
It reissues "Grand Line Code Signing" from the existing CA and keeps every grant.
macOS asks before `setup` reads the CA's private key, which is stored in the login keychain as "Grand Line Local CA private key" and readable by no application without asking.
To see why a certificate is rejected, list identities without `-v`:

```bash
security find-identity -p codesigning
```

`(CSSMERR_TP_NOT_TRUSTED)` after "Grand Line Code Signing" means the CA's trust setting is gone.
`(Invalid Key Usage for policy)` after "Grand Line Local Dev" is the older recipe's defect, and is fixed by moving to the CA rather than by recreating that certificate.

**Replacing the CA itself** is the one thing that still costs every grant, so `setup` never does it on its own and refuses to run with two CAs of the same name.
If the CA really is lost, delete what is left of it, run `setup`, and then do the one-time `tccutil reset` above:

```bash
security find-certificate -c "Grand Line Local CA" -p > /tmp/grandline-ca.crt
security remove-trusted-cert -d /tmp/grandline-ca.crt
security delete-certificate -c "Grand Line Local CA"
security delete-generic-password -s "Grand Line Local CA private key"
rm -f /tmp/grandline-ca.crt
```

Whenever a build stops satisfying the requirement of the copy it replaces, `build_native_app.sh` prints the repair last, so it is the final thing on screen.
System Settings keeps showing Grand Line switched on in that state, and switching it off and on does not help, because macOS keeps the old record.

---

## What the app is, structurally

One window. `MainSplitShellController` is its root: a sidebar (Home, then the
modules in four groups, with the live sessions under Console), a window
toolbar (Back and Forward, the module's tabs, the page's actions, the
light/dark toggle, notifications and search), the content column and an
inspector. It is the only layout: P-03 of the 2026-11-25 review removed the
floating bar.

Destinations are **lazily mounted and then only ever hidden** (GL-37), from one
table in `DestinationRegistry.swift`. Adding one is a `RailDestination` case plus
one `register(...)` line - not six edits in lockstep, which is what it used to
be.

A page-scoped nav column (`HelmPageSidebar`) is a different thing from the
app's sidebar, and several destinations have one.

### The destination map

Reached from the sidebar, the ⌘K palette, Home's cards, or a Recents entry.
The map is `ModuleTable.swift`: every `RailDestination` lands on one module
and, where the module has several pages, one of its tabs.

`Vault` is Automic Vault's hardening panel; **`Poneglyph`** is this app's own
encrypted credential store. They swapped names once - see
[`../docs/history/14-poneglyph-and-vault.md`](../docs/history/14-poneglyph-and-vault.md)
before assuming which is which.

### Terminals

Every tab is a `CockpitTerminalView` (a `LocalProcessTerminalView` subclass -
**do not touch its paste override**, it is what makes screenshot-paste into
Claude work). Children are forked **in-process**, so a keystroke makes no
localhost round trip. 10,000-line scrollback per terminal by default
(`ConsoleController.interactiveScrollbackLines`), which Settings › Terminal can
set from 1,000 to 100,000 (`TerminalScrollback.swift`); a tab can be **split**
into panes (`TerminalSplit.swift`).

**What that scrollback costs.**
A full pane is about **52 MB** at 200 columns: 10,000 rows of 24-byte cells is
46 MB of cells alone.
That is a measurement, not an estimate: `FM_RUN_BACKGROUND_SCROLLBACK_TESTS`
fills one 200-column pane past its ceiling and prints the process's physical
footprint before and after (a debug build, on the machine PERF-07 landed on).
A narrower pane costs proportionally less (about 31 MB at 120 columns), and
only a pane that has actually filled its history costs this much.

Terminal memory still scales with tabs x panes, so a tab that has been out of
sight for five minutes keeps only `ConsoleController.backgroundScrollbackLines`
(2,000, about 10 MB at 200 columns) and gets its full depth back the moment it
is selected.
The selected tab of a Console or host page the captain has navigated away from
counts as out of sight too, and gets its depth back when the page is shown
again (R5-PERF-03).
A minimised window or a hidden app does not count: only the page being left
does.
Settings › Terminal can turn that trim off, and the depth itself scales the
figure above: about 5.2 MB per 1,000 rows of a full 200-column pane.
The trim is real: the oldest lines above the most recent 2,000 are dropped, not
paged out.
A pane the captain has scrolled back in, and the Kubernetes feed tab, are left
alone.
`ConsoleController+Scrollback.swift` has the reasoning.

### Reading Activity Monitor

The **Energy** tab and the **CPU** tab count different things for this app (R5-PERF-05 of review #5).
Energy Impact for an app's row includes its child processes, and the CPU column does not.
Grand Line forks every terminal's shell in-process and runs its tool checks as children, so its Energy row also carries `git`, `brew`, `npm`, `bash`, `starship` and the `herdr` client.
A `claude` session started from a herdr pane is not one of them: its parent chain is `launchd > bash > herdr server > zsh`, so it is billed to herdr's row, not this one.
To see what the app itself costs, read the CPU tab, or `top -stats pid,cpu,idlew -pid <pid>`.
To see what its children cost, read the Energy tab.

## Keyboard shortcuts

The menu bar carries App, Edit, Hosts, Tasks, Log Analyzer, Keys and Snippets,
in that order.
There is no Tab or View menu - both were removed, so the tab shortcuts below are
served by a local `NSEvent` monitor (`TabKeyboardShortcuts.swift`) rather than
by menu items.

| Shortcut | Action |
|---|---|
| `⌘K` | Search everything (the unified palette) |
| `⌘F` | Find in the active terminal |
| `⌘,` | Settings |
| `⌥Space` | Quick capture (global) |
| `⌘T` / `⌘D` / `⌘W` | New / duplicate / close tab |
| `⇧⌘R` / `⌘R` | Rename / reconnect the current tab |
| `⌘1`…`⌘9` | Select the Nth tab |
| `⌃⌘→` / `⌃⌘←` / `⌃⌘↓` | Split the tab right / left / down |
| `⌥⌘]` / `⌥⌘[` | Focus the next / previous pane |
| `⌃⌘W` / `⌃⌘⏎` | Close / zoom the focused pane |
| `⇧⌘]` / `⇧⌘[` | Next / previous tab |
| `⌃⌘N` / `⌃⌘S` | New host / show Hosts |
| `⌃⌘1`…`⌃⌘9`, `⌘]`, `⌘[` | Switch to a live SSH session |
| `⇧⌘N` / `⇧⌘K` | New key / manage keys |
| `⌥⌘N` / `⌥⌘P` | New snippet / manage snippets |
| `⌘N` / `⇧⌘F` | New task / new follow-up |
| `⇧⌘L` / `⇧⌘C` / `⇧⌘T` / `⇧⌘I` / `⇧⌘A` | Log Analyzer: open / copy analysis / send to terminal / investigate / create RCA |

Every shortcut in the split/pane/tab-cycling block is **configurable** in
Settings → Terminal Shortcuts; the table shows the defaults. A configured chord
wins over the fixed table above it.

## Scope

- Secrets (private key bytes, passphrases, vault material) live **only** in the
  macOS Keychain, `ThisDeviceOnly`. Non-secret metadata lives in plain JSON
  under Application Support, or in the git-synced config repo.
- SSH features (jump hosts, port forwarding, agent forwarding) are all extra
  `ssh` argv. This app re-implements no part of the SSH protocol, host-key
  trust, or the agent protocol. `.ppk` import is explicitly refused, not
  silently mishandled.
- Every subprocess goes through one bounded runner (`Subprocess.swift`), and
  every `claude -p` call through one (`ClaudeOneShot.swift`). Nothing leaves the
  machine beyond what those two do; there is no telemetry.
