# Manjesh Grand Line - the native app

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

Every build of this app - a `swift run` binary, `.build/debug/FirstmateCockpit`,
and the packaged `dist/Manjesh Grand Line.app` - shares one bundle identity
(`com.firstmate.cockpit.native`). There is **no OS-level process isolation
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
The product is a `Mach-O arm64` executable at `.build/debug/FirstmateCockpit`.

There are **no remote SPM dependencies** and no `Package.resolved`: everything
is vendored under `Vendor/`, so the build needs no network.

| `Vendor/` | What, and the catch |
|---|---|
| `SwiftTerm` | Pinned to upstream 1.15.0 with **five local patches** - read `Vendor/SwiftTerm/README.md` before touching or re-syncing it |
| `whisper.cpp` | Local Whisper for dictation, CPU + Metal. The shader is a generated file; see `Scripts/build-whisper-metal-shader.py` |
| `YamlSwift` | Patched for insertion order and quote preservation |
| `Excalidraw`, `Monaco` | Committed, self-contained web bundles for the Whiteboard and Code Preview (the Notebook's source pane loads the same Monaco bundle - one integration, not two). Loaded from disk with no CDN and no runtime download; `swift build` never touches them |

A change to a vendored web bundle's source needs its `Scripts/build-*-web.sh`
re-run - **the app loads the committed artifact, so a source edit alone is
invisible until runtime.** Those two rebuilds need node/npm; nothing else here
does.

## Test

```bash
./Scripts/run-all-tests.sh                # build, then every suite, with timings
./Scripts/run-all-tests.sh --list         # what would run
./Scripts/run-all-tests.sh --ci           # the headless-safe half
./Scripts/run-all-tests.sh --session-only # the exact complement (window-backed)
./Scripts/run-all-tests.sh --no-build FM_RUN_SHIFT_STORE_TESTS
```

There is no XCTest target. The app carries ~157 permanent self-test suites, each
behind its own `FM_RUN_*_TESTS=1` variable and each handled **before**
`NSApplication` is ever touched - so they run headless and are safe alongside
the real app. The runner discovers its list from `main.swift`, so a new suite
joins automatically.

**Always test `.build/debug/FirstmateCockpit`.** The suites are compiled into
debug builds only (`FM_SELFTESTS`, GL-27); a release binary runs zero suites and
exits 0, which looks exactly like a clean run.

Each suite reports its own wall clock and the ten slowest are listed again at
the end, so a runtime regression is one line to read.

**Pre-flight, in this order** - all three have bitten a real run:

```bash
git status --porcelain          # must be empty: agents can share a worktree
pgrep -fl run-all-tests        # never two passes at once
defaults read FirstmateCockpit fm.themeID   # a known value (dusk)
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
`../dist/Manjesh Grand Line.app` (bundle ID `com.firstmate.cockpit.native`) and
installed over `/Applications`. The version comes from `git describe` (GL-18), so
a release is cut by tagging - never by editing a constant. Releases are
unsigned; see the repo-root README.

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

### Local signing setup (one-time, per machine)

The script codesigns with a local self-signed identity named exactly
**"Firstmate Cockpit Local Dev"** when one exists, and warns and continues
unsigned when it does not.

This is not tidiness. Saved SSH keys live in the macOS Keychain, and a
Keychain item's default ACL trusts only the code identity that created it - so
an unsigned build, which gets a *different* ad-hoc identity on every rebuild,
makes yesterday's saved key unreadable today. One fixed identity keeps that
trust stable.

```bash
# 1. A self-signed cert with the codeSigning extended key usage.
openssl req -x509 -newkey rsa:2048 -keyout /tmp/fmcockpit.key -out /tmp/fmcockpit.crt \
  -days 3650 -nodes -subj "/CN=Firstmate Cockpit Local Dev" \
  -addext "extendedKeyUsage=critical,codeSigning"

# 2. As a .p12. `-legacy` is required - OpenSSL 3.x's default PKCS12
#    encryption is not readable by macOS's importer without it.
openssl pkcs12 -export -legacy -inkey /tmp/fmcockpit.key -in /tmp/fmcockpit.crt \
  -out /tmp/fmcockpit.p12 -passout pass:temporary

# 3. Import, trusted for codesign specifically.
security import /tmp/fmcockpit.p12 -k ~/Library/Keychains/login.keychain-db \
  -P temporary -T /usr/bin/codesign

# 4. Trust it. Note `-r trustRoot`, not `-r trustAsRoot` - the latter fails
#    with a parameter error on this cert shape.
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db /tmp/fmcockpit.crt

rm -f /tmp/fmcockpit.key /tmp/fmcockpit.crt /tmp/fmcockpit.p12
```

Verify with
`security find-identity -v -p codesigning | grep "Firstmate Cockpit Local Dev"`.

---

## What the app is, structurally

One window. `AppShellController` is its root: a floating `DaylightBarController`
across the top (the wordmark or the current page's drill header, the space
pills, search, quick-access icons, theme, notifications, avatar) over a body
that holds every destination.

Destinations are **lazily mounted and then only ever hidden** (GL-37), from one
table in `DestinationRegistry.swift`. Adding one is a `RailDestination` case plus
one `register(...)` line - not six edits in lockstep, which is what it used to
be.

There is no left sidebar and no rail: both were deleted in the Daylight
migration. A page-scoped nav column (`HelmPageSidebar`) is a different thing and
several destinations have one.

### The destination map

Reached from the Home canvas's cards, the ⌘K palette, a quick-access icon on the
bar, or a Recents entry.

| Space | Destinations |
|---|---|
| Overview (no space of their own) | **Fleet**, **Straw Hat Pirates**, the morning briefing, the merge queue |
| Command | **Console**, **Tasks**, **DevOps Commands**, the merge queue card |
| Operations | **Hosts**, **Log Analyzer**, **Kubernetes**, **Health**, **Schedules** |
| Stores | **Vault**, **Poneglyph**, **Docs**, **Notebook**, **Runbooks**, **Postmortems**, **Tools**, **Dictation**, **Whiteboard**, **Sticky Board**, **Code Preview** |
| Engineering | **Updates**, **Bootstrap**, **Automation**, **GitHub Sync**, **Settings** |

`Vault` is Automic Vault's hardening panel; **`Poneglyph`** is this app's own
encrypted credential store. They swapped names once - see
[`../docs/history/14-poneglyph-and-vault.md`](../docs/history/14-poneglyph-and-vault.md)
before assuming which is which.

### Terminals

Every tab is a `CockpitTerminalView` (a `LocalProcessTerminalView` subclass -
**do not touch its paste override**, it is what makes screenshot-paste into
Claude work). Children are forked **in-process**, so a keystroke makes no
localhost round trip. 10,000-line scrollback per terminal; a tab can be **split**
into panes (`TerminalSplit.swift`).

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
