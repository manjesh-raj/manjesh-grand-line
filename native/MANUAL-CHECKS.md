# Manual checks (captain-run)

Everything in this list is a thing the automated suites **provably cannot**
verify, not a thing nobody got round to automating. It exists because the
full-app audit's §7 asked for the honest boundary to be written down rather
than left implicit, so a green
`./Scripts/run-all-tests.sh` is not mistaken for "the app is verified".

Run this before a release, or after a change that touches one of the areas
below. It is short on purpose - a checklist nobody finishes is worse than none.

**A section that must be re-done on a schedule says so in one line of its own**:

    Cadence: every 183 days, last done 2026-09-19.
    Cadence: every 30 days, never done.

The app's weekly "Manual checks due" schedule (`ManualChecksRegister.swift`,
R5-PROC-06) reads those lines and rings the bell when one is due.
Record a check by updating its `last done` date here.
A section without the line is a before-a-release check and is not tracked.

## Why these cannot be automated

A self-test process is **not a composited UI app**. It runs from a terminal,
never calls `NSApp.run()`, and its windows are never drawn by the window
server. Concretely, that means:

- A `WKWebView` reports `document.visibilityState === "hidden"` **even while
  its view is shown**, so only the *hidden* half of the display-gating
  contract is assertable. (`WhiteboardViewSelfTest` says so in its own output.)
- SwiftTerm draws nothing in a window that was never ordered front, and an
  ancestor's `cacheDisplay` does not capture the terminal's glyphs.
- Energy Impact, biometric prompts, real notification banners, and a real
  global hotkey with another app frontmost all need a genuine login session.

And a set of them need something no machine in CI - or in an agent worktree -
has: a real bastion, a real cluster, a real forge, a real herdr server.

For the composited-but-local half, `Scripts/build-probe-app.sh` builds a
separately-identified copy that is safe to launch alongside the real app (its
own bundle id, its own instance lock, its own scratch stores). Use it rather
than launching a worktree build - see that script's header.

---

## 1. Energy

- [ ] Open the app, leave it **frontmost and idle** for 2 minutes. Activity
      Monitor → Energy: Energy Impact should settle near zero.
- [ ] Switch to another app so Grand Line is **backgrounded**, wait 2 minutes.
      Impact should be lower still, and Grand Line should not be near the top
      of the list.
- [ ] Open a Console tab with something producing continuous output, then
      switch to another destination. CPU should drop sharply - that is the
      display gating (`CockpitTerminalView.refreshDisplayGating`) working.
- [ ] Leave the Console **frontmost and focused** on a live `herdr` tab for a
      minute and run `top -stats pid,cpu,idlew,csw -pid <pid>`. Then click into
      another pane so the terminal loses focus, and run it again. The second
      reading should be lower (30 Hz instead of 60), and neither should come
      near the 8-15% review #5 measured before vendored SwiftTerm patch 10.
- [ ] With a Whiteboard or Code Preview tab open, navigate away. Its web
      content process should go quiet.

## 2. Notifications

- [ ] With "Bell & notifications" on, trigger a needs-decision task. A real
      banner should appear.
- [ ] Press the banner's **action button** (Merge / Snooze / Open). Confirm it
      does the thing without bringing the app forward for the Merge case.
- [ ] Confirm a **red or pending** PR's banner offers no Merge button at all.
- [ ] Lock the app (avatar → Logout), then press a banner action. It must do
      nothing but show the lock screen.

## 3. Credentials and biometrics

- [ ] Connect a saved host whose key is in the Keychain. Touch ID should
      prompt.
- [ ] **Cancel** the prompt. The connection must be abandoned - it must *not*
      silently fall through to agent auth.
- [ ] Confirm the app stays responsive while the prompt is up (the unlock runs
      off the main thread; a freeze here is a regression).

## 4. Global input

- [ ] With **another app frontmost**, hold the dictation shortcut, speak, and
      release. The text should paste at that app's cursor.
- [ ] With another app frontmost, press ⌥Space. Quick capture should appear.
- [ ] Lock the app and repeat both. Neither should do anything.

## 5. Terminal rendering

- [ ] Drag to select text in a Console `.shell` tab. The selection must use the
      **active Helm theme's** colours, not a foreign palette.
- [ ] Repeat with a mouse-reporting program running (`vim`, `less`, `claude`).
      Plain drag should still select locally; Shift+drag should reach the
      program.
- [ ] Toggle "Forward Drags to This Tab's Program" and confirm the two swap,
      and that the chip shows its indicator.
- [ ] Switch themes with a terminal on screen and confirm scrollback survives.
- [ ] With a live TUI (`herdr`, `htop`, `vim`) on screen, watch for a row that
      keeps old text after it changed: scroll, resize the window, select text,
      use Find, and switch themes. Patch 10 repaints only the rows whose
      content changed, and a suite cannot see the real screen's pixels, so a
      stale row is the failure to look for.

## 6. Terminal splits and configurable shortcuts

`TerminalShortcutsSelfTest` asserts pane *frames* and the monitor's routing in
an off-screen window, and `hasAppeared` gates `startSplitPane`, so **no pane in
a suite ever forks a shell**. Two real shells side by side is therefore entirely
outside its reach, and so is a real keystroke from a real keyboard layout.

- [ ] Split a Console tab (default `⌃⌘→`). Both panes are live shells - run a
      command in each, switch focus between them, confirm neither loses its
      scrollback.
- [ ] Drag the divider. Both terminals reflow to their new column count and
      neither garbles what is already on screen.
- [ ] Split a *host* (ssh) tab. Its new pane is a **local login shell** with a
      one-line note saying so - it must not open a second ssh session or
      prompt for Touch ID.
- [ ] Close the primary pane. The tab's own session survives and the tab does
      not go dead.
- [ ] Rebind one action in Settings → Terminal Shortcuts, then use the new
      chord. Confirm the old one no longer fires and the new one does.
- [ ] Record a modifier-only or unmodified chord. The recorder must refuse it
      rather than accepting a binding a shell would eat.
- [ ] Quit with a split open, relaunch: the tab comes back, the split does not.
      That is the documented behaviour, not a bug.

## 7. Window chrome

The window keeps the system title bar and installs its own toolbar
(`MainSplitShellController.attach(to:)`). Until P-03 of the 2026-11-25 review
removed the floating bar, the traffic lights were repositioned onto the bar
and reached by hit-test forwarding; that is gone. A suite cannot click a real
traffic light, drag a real window, or enter real full screen.

- [ ] Click **close**, **minimise** and **zoom**. All three work.
- [ ] Drag the window by the toolbar's empty area. It moves.
- [ ] Enter and leave full screen. The toolbar and the sidebar come back
      correctly, with no black band above the window (`FullScreenMenuBarFill`).

## 8. Session restore across a relaunch

Suites cover the captured state, its decoding, and that a restored host page
does **not** connect. The relaunch itself is not reachable from a suite.

- [ ] Open several Console tabs, rename one, open two host pages, then quit and
      reopen. The showing destination, the Console tabs and their names come
      back.
- [ ] Confirm the restored host pages are **not** connected: no `ssh` process,
      no Touch ID prompt at launch. Opening one connects it then, and only then.
- [ ] Confirm the auto-opened Shell tab is *reused* as the first restored tab
      rather than left beside it (no duplicate).
- [ ] Declare an incident, quit, reopen, open that host page. The incident card
      announces itself. (The app will not reopen the page for you - that is F2's
      documented limit.)
- [ ] Force-quit instead of quitting cleanly. Restore still works: the state is
      written on every navigation, not only on quit.

## 9. Poneglyph (the credential vault)

Every unlock runs a real 600,000-round PBKDF2 derivation and every reveal
reaches the real Keychain and the real pasteboard. A suite drives the crypto and
the store; it cannot press Touch ID, watch a clipboard expire, or drag a row.

- [ ] Unlock with the master password. It should take a perceptible moment and
      not freeze the window - a beachball here is a regression.
- [ ] Get it wrong five times. The throttle engages, and the message says so
      rather than implying the vault is damaged.
- [ ] Turn on Touch ID unlock, lock, unlock again. The prompt appears and the
      typed password still works as the fallback.
- [ ] **Reveal** a credential. The value appears and the clipboard is untouched.
- [ ] **Copy** it. The clipboard has it and nothing appeared on screen. Wait out
      the auto-clear and confirm the clipboard is empty - then repeat, copy
      something else in between, and confirm the *other* value survives.
- [ ] Paste into another app and confirm nothing about it reached that Mac's
      other devices (Universal Clipboard) or a clipboard-history manager.
- [ ] Drag a credential to reorder it within its category. The order persists
      across a relaunch, and a drag cannot move a row into another category.
- [ ] With a detail panel open, lock the vault (button, idle timeout, and the
      app lock - all three). The panel **empties**; it must not keep showing a
      revealed secret over the lock screen.
- [ ] Add a credential, wait a few seconds, and confirm it commits and pushes.
      Then change it on a second machine and confirm this one picks that up.

## 10. Straw Hat Pirates (the AI crew)

Every turn is a real `claude -p` call, so a suite drives the parser, the
proposal executor and the confirm cards against a fake `claude`. The reply's
*quality* - whether a crew member sounds like that character, and whether it
ever claims a write it has not made - is only observable live.

- [ ] Ask something that needs no action. One crew member answers, in voice,
      and the rest stay quiet.
- [ ] Ask for a task. The proposal arrives as a confirm card, Luffy closes the
      turn, and **nothing is written until you press it**.
- [ ] Press it. The real editor opens pre-filled (task/follow-up/command/
      schedule), and *its* Save is what writes. A sticky note and a runbook
      draft write directly and offer a real Undo.
- [ ] Press the same card twice, and separately switch theme with a card on
      screen. Neither may write a duplicate, and a pressed card must stay
      pressed through the rebuild.
- [ ] Read the wording of a drafted turn carefully. It must be draft-tense -
      "confirm to add", never "added"/"saved"/"got it on the board".
- [ ] Ask a question only a read-only MCP tool could answer (something in a
      runbook's body, a saved command's risk level). Confirm the answer is real
      and that asking it to read an arbitrary file is refused.
- [ ] Use the **menu-bar** quick-chat with the app in the background. It lands
      in the same conversation, and it offers no confirm control.
- [ ] Lock the app and click the menu-bar icon. Nothing opens.
- [ ] Quit and reopen. The conversation is gone - chat history is deliberately
      not persisted yet.

## 11. Whiteboard and Code Preview (the web islands)

`cacheDisplay` does not capture `WKWebView` content, so a suite can prove the
bridge round trip and the page's own reported state and nothing about what is
drawn.

- [ ] Whiteboard: type a DSL diagram, insert it. Every component draws its real
      icon chip with a legible caption - not a letterform, not a clipped word.
- [ ] Open the **Components** drop-down and walk a submenu. Clicking a leaf
      appends that component and never wipes the board.
- [ ] Generate a diagram from a description, then refine it twice. The second
      refinement edits the first rather than starting over, and moving a box by
      hand in between is respected.
- [ ] Switch theme with the Whiteboard showing. Its island chrome follows;
      nothing cross-fades a blank rectangle over the canvas.
- [ ] Code Preview: paste Swift, then JSON. Both highlight, and the language
      picker renames the file. Scroll down and confirm the hairline appears at
      the editor card's own top edge.
- [ ] Zoom with the stepper, confirm a Console tab's font moved with it, then
      click the readout to reset.
- [ ] Quit and reopen: the snippets and their tab order come back.

## 12. Tasks: the Kanban board

A suite drives `NSDraggingInfo` through a stub and asserts the store. A real
`NSDraggingSession` needs a real mouse in a real window.

- [ ] Drag a card between all three columns. The move persists across a
      relaunch, and a card dragged out of **Done** genuinely leaves its month
      file rather than only flipping a flag.
- [ ] Drag a card and drop it outside any column. Nothing changes.
- [ ] Do the same moves from a card's context menu and from VoiceOver's rotor.
      Both must work - dragging is never the only way.
- [ ] Fill a column past its visible height and confirm the last card is not
      sliced through its own pill.

## 13. Real remote paths

These need a real bastion and cannot be faked meaningfully.

- [ ] Connect to a real bastion through its full hop chain.
- [ ] Confirm the Kubernetes **context badge** resolves and shows the real
      context/namespace.
- [ ] Open the Kubernetes page, adopt a feed tab, confirm a real cluster sweep
      populates the Pods table.
- [ ] Start **Log Tail** on 2-3 pods; confirm lines arrive and each pod keeps a
      stable colour.
- [ ] Ask **SRE Lead** a question that needs `kubectl`; confirm it runs
      read-only commands in the shared terminal and answers with a Finding.
- [ ] Ask it to run a runbook containing a **mutating** step; confirm it
      refuses by name and runs nothing.

## 14. Sync and external tools

- [ ] Make a Shift edit; confirm it commits and pushes within a few seconds.
- [ ] Make conflicting edits on two machines; confirm the conflict sheet
      appears and resolving it pushes the chosen version.
- [ ] Change the theme and confirm herdr's own selection colour follows after
      `herdr server reload-config`.
- [ ] Run a Setup → Updates check against real `brew`/`npm` and confirm the
      statuses match reality.

## 15. Scheduled: the vendored SwiftTerm pin

Cadence: every 183 days, last done 2026-09-19.

**Every 183 days** (six months), or sooner on an upstream security fix. Last
done 2026-09-19, against upstream `v1.20.0`: stay pinned. The recipe, the
decision rule and the running record are in
[`Vendor/SwiftTerm/README.md`](Vendor/SwiftTerm/README.md)'s "Updating this
vendored copy, and the scheduled check".

Here because it is a network fetch plus a judgement call: the question is not
"is there a newer tag" (there always is) but "has any of the ten local patches'
root cause been fixed upstream, or gained a `public`/`open` hook" - which needs
reading upstream's current source and deciding, not a comparison a suite can
make.

- [ ] Run the four commands in that README section.
- [ ] Record the date and a per-patch verdict **even when the answer is
      "stay pinned"** - a check that leaves no record is one nobody can tell was
      skipped.

`FM_RUN_VENDORED_PATCHES_TESTS` covers the automated half (all ten patches are
still present in the tree, so a sync that drops one fails by name) and prints a
NOTE - never a failure - once the recorded date is older than the interval.

## 15a. The vendored web bundles match their inputs (was open until 2026-10-28)

P11 of the 2026-09-25 review added a committed `package-lock.json` and a
`--check` to the web-bundle generators. Monaco passed. **Excalidraw did not**,
and this section held that open for a month.

What was measured on 2026-09-25, kept because it is why the fix was safe:

- `Vendor/Excalidraw/web/whiteboard.js` was 8,449,843 bytes; a rebuild from the
  pinned inputs was 8,451,183. Everything else in that directory matched.
- The build is **deterministic**: two rebuilds from the lockfile came out
  byte-identical. So the committed bundle had been produced from a different
  transitive dependency tree, which is the drift the lockfile now prevents.
- `BUILD-INFO.txt` matching meant the *direct* pins agreed
  (`@excalidraw/excalidraw` 0.18.1, React 19.1.0, esbuild 0.25.9). The
  difference was below them.

R4-PROC-03 of the fourth full review closed it: `./Scripts/build-excalidraw-web.sh`
was run from the lockfile and its output committed (8,451,183 bytes, exactly
the size measured above), and all three generators' `--check` now print
"matches a rebuild". `FM_RUN_WHITEBOARD_TESTS` and `FM_RUN_WHITEBOARD_VIEW_TESTS`
pass against the rebuilt bundle.

The same change added `Scripts/check-web-bundles.sh`, which runs in
`run-all-tests.sh`'s default and `--ci` selections and so in CI's blocking
headless lane. Each build script now records a SHA-256 of every input (`src/`
and the script itself) in `BUILD-INFO.txt`, and the check recomputes them with
no node and no network. An edit to `src/` that was never rebuilt now fails CI
by name. The full rebuild-and-diff is still each script's `--check`, by hand.

Still the captain's, because an agent worktree cannot launch the app (AGENTS.md,
"Never launch a built copy from a worktree"):

- [ ] Open the Whiteboard and confirm drawing, the DSL, image export and the
      annotate flow still work on the rebuilt bundle. The suites cover the
      page's own wiring and the bundle loading, not Excalidraw's internals.

## 16. Packaging

- [ ] `./build_native_app.sh`, then launch from `/Applications`.
- [ ] Confirm saved SSH keys still unlock (a changed signing identity breaks
      Keychain trust).
- [ ] Confirm the About/version string matches `git describe`.

---

## 17. Widgets and the Developer ID (F23)

Nothing in this section can be automated or even attempted from a worktree, and
it is the one open item F23 was scoped around.

`native/Widgets/README.md` is the authority; this is the checklist.

- [ ] **Developer ID.** `security find-identity -v -p codesigning` shows a
      `Developer ID Application: … (TEAMID)` certificate. Until it does,
      everything below is unreachable - and `codesign -dv "dist/Grand Line.app"`
      reporting `TeamIdentifier=not set` is the current state.
- [ ] **The App Group id agrees in both files.** Set
      `GrandLineWidgetContainer.appGroupIdentifier` and
      `GrandLineWidgets/GrandLineWidgets.entitlements` to
      `<TeamID>.group.com.manjesh.grandline.native`.
      `FM_RUN_WIDGET_SNAPSHOT_TESTS` fails if they diverge, so this cannot be
      half-done.
- [ ] **Build, embed, launch.** `./build_native_app.sh` then
      `Scripts/build-widget-extension.sh --embed`, then launch the installed
      copy once so Launch Services registers the extension.
- [ ] **The two widgets appear in the widget gallery** (right-click the
      desktop > Edit Widgets), under "Grand Line".
- [ ] **They render real data**, not `Not available`. If they say
      `Not available`, the App Group entitlement is not being honoured - that
      is the expected failure, not a code bug.
- [ ] **A tick works end to end.** Tap a task's checkbox on the desktop: the
      row strikes through and reads "applies when the app opens"; bring the app
      forward; the task is completed in Tasks, and a *recurring* one has
      spawned its next occurrence.
- [ ] **The lock covers it.** Lock the app (GL-09). Within a refresh both
      widgets show "Locked" with no task titles and no counts. Tap a checkbox
      while locked - nothing is applied; unlock, and it applies then.
- [ ] **Both registers.** Switch the app between a Daylight and a Dusk theme;
      the widgets follow the *app's* register, not the system appearance.

## 17a. Signing posture: Developer ID, hardened runtime, notarization (R2-SEC-02)

Open since review #2, and confirmed again by full review #5 (R5-SEC-00).
`/Applications/Grand Line.app` is signed by the local identity
"Grand Line Local Dev": `TeamIdentifier=not set`, `flags=0x0(none)` (no
hardened runtime), no entitlements, and `spctl --assess --type execute` says
`rejected`. Nothing in this section can be done from a worktree, because every
step needs the captain's Apple Developer account. It shares its first step with
section 17.

- [ ] **Developer ID certificate.** `security find-identity -v -p codesigning`
      lists `Developer ID Application: <Name> (<TEAMID>)`.
- [ ] **An entitlements file for the app.** Create
      `native/GrandLine.entitlements` with exactly one key,
      `com.apple.security.device.audio-input` set to `true`. Dictation records
      through `AVAudioEngine`, and under the hardened runtime the microphone
      needs it. Nothing else in the app needs one today: there is no JIT, no
      unsigned dylib (SwiftTerm is compiled in), and the admin prompt runs in
      an `osascript` child, not as Apple Events from this process.
- [ ] **Sign with the runtime on.** In `build_native_app.sh`, the signing line
      becomes
      `codesign --force --options runtime --timestamp --entitlements GrandLine.entitlements --sign "Developer ID Application: <Name> (<TEAMID>)" --identifier "$BUNDLE_ID" "$APP_DIR"`,
      and `SIGNING_IDENTITY` names the Developer ID. Keep the local identity as
      the fallback for machines without the certificate.
- [ ] **Notarize and staple.** `xcrun notarytool store-credentials grandline`
      once, then for each release:
      `ditto -c -k --keepParent "dist/Grand Line.app" /tmp/GrandLine.zip`,
      `xcrun notarytool submit /tmp/GrandLine.zip --keychain-profile grandline --wait`,
      and `xcrun stapler staple "dist/Grand Line.app"`.
- [ ] **Verify.** `codesign -dv --verbose=4 "dist/Grand Line.app"` shows
      `flags=0x10000(runtime)` and a real `TeamIdentifier`.
      `codesign -d --entitlements - "dist/Grand Line.app"` shows the one key.
      `spctl --assess --type execute -vv "dist/Grand Line.app"` says
      `accepted` with `source=Notarized Developer ID`.
- [ ] **Expect a one-time trust reset.** A new signing identity is a new
      designated requirement. The saved SSH keys and the vault will ask once to
      be allowed again (choose Always Allow), and the Microphone, Speech
      Recognition and Accessibility grants have to be given again, the same
      way section 18 describes.
- [ ] **Then do section 17**, which this unblocks.

## 18. After the rename: the macOS privacy grants (one-time)

macOS keys Accessibility, Automation and every other privacy grant to the
**bundle identifier**, and
[`docs/history/45-rename-to-grand-line.md`](../docs/history/45-rename-to-grand-line.md)
changed it from `com.firstmate.cockpit.native` to `com.manjesh.grandline.native`.
The rebuilt app is therefore a brand-new app as far as TCC is concerned. This
cannot be scripted and nothing in the codebase tries - granting is a user
consent action by design.

Do this once, after the first `./build_native_app.sh` on the renamed build.

- [ ] **Accessibility.** System Settings > Privacy & Security > Accessibility.
      Remove any stale "Firstmate Cockpit" / "Manjesh Grand Line" entry, then
      add and enable **Grand Line**.
- [ ] **Automation**, and whichever of **Screen Recording**, **Microphone**,
      **Speech Recognition** and **Calendars** the app had before. Same shape:
      drop the stale entry, grant the new one.
- [ ] **The three global hotkeys work from another app**: the capture chord,
      compact mode (`^ ⌥ G`) and dictation. Until Accessibility is granted
      they have no global monitor. `ShiftGlobalHotkey.reassertIfTrustChanged()`
      picks the grant up on the next app activation, so no relaunch is needed.
- [ ] **The saved SSH keys still unlock**, and the credential vault still
      opens. Those items were **copied** onto the new Keychain service names at
      first launch, not moved. Once both are confirmed, the old
      `com.firstmate.cockpit.*` items in Keychain Access can be deleted by hand.
- [ ] **Your own settings came with you**: the app opens in the theme you had,
      at the text scale you had, at the window size and position you left it.
      That copy runs once, so if you clear a setting afterwards it stays clear.
- [ ] **The data folder moved.** `~/Library/Application Support/GrandLine/`
      exists and `.../FirstmateCockpit/` does not. If both are there, the app
      is reading the new one and left the old one alone - reconcile by hand.

## 18a. One-time: the shelved clipboard history copies from 2026-09-25 (B1)

Full review #5 (R5-SEC-00) found three `clipboard-history.sealed.corrupt-*`
files from the B1 incident still in `~/Library/Application Support/GrandLine/`.
They are the history the app shelved when it could not open it with this Mac's
clipboard key, still encrypted, and nothing on a working machine points at them.

The app now removes them itself.
When the clipboard history store opens the live `clipboard-history.sealed`
cleanly, it deletes every shelved copy whose name dates it more than 30 days
ago (`ClipboardHistoryStore.shelvedBackupRetention`) and logs each one by name.
It removes nothing while the live history is missing or cannot be opened,
because a shelved copy may then be the only one left.
The store is built the first time a launch uses the history (the first copy
anywhere, or the first ⌘⇧V), and only while the history is switched on in
Settings, so that is when the cleanup runs.

- [ ] **Confirm it ran**, after launching a build that has it with the
      clipboard history on, and copying something:

      log show --last 1h --predicate \
        'subsystem == "com.manjesh.grandline.native" && category == "store"' \
        | grep "removed shelved copy"

      Expect one line per file from 2026-09-25.
- [ ] **Look, without opening anything.**
      `ls -l ~/Library/Application\ Support/GrandLine/clipboard-history.sealed*`
      should list only the live file (plus any copy shelved in the last 30 days).

## 19. Launch cost (the signpost baseline)

The 2026-10 end-to-end review's PERF-01, PERF-02 and PERF-08 (section 3.6) are
claims about launch cost.
The fixes for them are proved by deterministic suites (call counts, what is
built at launch, what a second `start()` does), but the time they save can only
be measured in Instruments, against real data, by the captain.
`LaunchSignposts.swift` puts a named interval on every row of the launch path
so that measurement is one table rather than a call tree.

- [ ] Copy the data folder somewhere disposable and point `FM_SCRATCH_ROOT` at
      the copy, so nothing below reads or writes the real stores.
- [ ] Instruments > App Launch against `.build/debug/GrandLine` (or the probe
      app), warm disk, three runs.
      Filter the os_signpost track to subsystem `com.manjesh.grandline.native`,
      category `launch`.
- [ ] Record, per run: process start to the window becoming key, and the
      duration of `WorkspaceShellController.init`, `MainSplitShellController.loadView`,
      every `*.init` store interval, and `restoreSessionIfNeeded`.
- [ ] Pass: `WorkspaceShellController.init` under 50 ms, no store `init` over 10 ms,
      first frame under 400 ms, and the main thread free within 100 ms of the
      first frame with five restored host pages.
- [ ] Record the numbers in
      [`docs/history/26-production-readiness.md`](../docs/history/26-production-readiness.md),
      so the next change to the launch path has a baseline to compare against.

**The real-data Instruments pass is still open.**
No per-interval baseline against a copy of the captain's data is recorded anywhere.
What is recorded now is the whole-launch number for a release build on an empty data root, in the table below.

`Launch.mainToFirstKeyWindow` is the one interval from `main` to the first
window that becomes key (R4-PERF-02 of the fourth full review).
It is opened on the first line of `main.swift`, closed by the first window
that becomes key, and guarded by `FM_RUN_LAUNCH_PATH_TESTS`.
It writes its length to the unified log on every launch, release builds
included, so the whole-launch number needs no Instruments.

### The release baseline (R5-PERF-04)

Recorded 2026-11-17 on an Apple M5 Pro, macOS 26.7 (25G229), on AC power, load average about 2.3.
Build: `main` at `v0.2.0-67-g30e26ac3`, `swift build -c release` with the real SDK stamped (`sdk 27.0`), as `build_native_app.sh` builds it.
Five launches in a row, each stopped by pid once its window was key:

| Run | Main to first key window |
| --- | --- |
| 1 (first launch on the data root) | 1108.9 ms |
| 2 | 1173.9 ms |
| 3 | 956.0 ms |
| 4 | 1003.8 ms |
| 5 | 1130.2 ms |

Median **1108.9 ms**, range 956 to 1174 ms.
That is well over the 400 ms target, and slower than the in-process debug figure below, because it includes process start, `dyld`, and a real window being composited and made key.
None of the runs was disk-cold, since the binary had been launched before in the same session.

How it was taken, so the next run is comparable:

- The release binary was assembled into a separately-identified bundle the way `Scripts/build-probe-app.sh` builds its debug probe (bundle id `com.manjesh.grandline.native.probe`, ad-hoc signed), so it never contended with the captain's running app.
- It was launched with `open -n` and the probe script's own environment (`FM_SCRATCH_ROOT`, `FM_INSTANCE_LOCK_FILE`, `FM_CLIPBOARD_HISTORY_EPHEMERAL=1`), plus `FM_HOME` pointed at a stub firstmate home so the launch lands on Home rather than Setup, and `HERDR_CONFIG_PATH` pointed at scratch.
  A release build has no `FM_KEYCHAIN_SERVICE_PREFIX`, and those variables are what keep it off the captain's Keychain items and data.
- The number was read for that pid only:

      log show --predicate \
        'processID == <pid> && subsystem == "com.manjesh.grandline.native" && category == "lifecycle"' \
        | grep "main to first key window"

- The window has to be activated to become key, so a launch with `open -g` logs nothing. Each run takes the keyboard focus for about a second.

Two earlier runs of the same build restored a Console with three shell tabs, each printing 12,000 lines at startup.
They measured 1246.6 ms and 1041.9 ms, under a higher load (about 4 to 5).
Two runs are too few to say what the restore itself costs.

- [ ] **Still the captain's**: the same five launches of the installed app against real data (the `log show` line above, with `--last 10m` instead of a pid), and the Instruments pass for the per-interval rows.
      Record them beside the table above and in
      [`docs/history/26-production-readiness.md`](../docs/history/26-production-readiness.md),
      with the date, the machine and `git describe`.

### The in-process numbers (not the real-data baseline)

The real-data Instruments pass above is still the captain's, and nothing below replaces it.
R2-PERF-01 of the second full review asked for the closest measurement a worktree can take without launching the app.
`FM_RUN_LAUNCH_TIMING_TESTS` (`LaunchTimingSelfTest`) builds the real `AppDelegate`, its shell and an off-screen window in a self-test process, and times every launch interval through `LaunchSignposts` plus one display pass.
It does not see process start, the window is never composited, and the stores are the suite's own empty scratch stores.
Read its numbers as a floor and a trend, never as what the captain's launch costs.

Recorded 2026-10-26 on an Apple M5 Pro, macOS 26.7, debug build, `main` plus the R2-A11Y and R2-PERF branch.
Five processes per layout, the first one cold and the other four warm:

| Layout | First frame, cold | First frame, warm (median of 4) | `WorkspaceShellController.init` | `loadView` | Slowest store `init` |
| --- | --- | --- | --- | --- | --- |
| Sidebar | 605.8 ms | 592.6 ms | 20.8 to 23.0 ms | 125.5 to 130.4 ms | `ShiftStore.init`, 1.79 ms |
| Floating bar | 611.4 ms | 609.3 ms | 21.0 to 21.9 ms | 214.6 to 217.9 ms | `ShiftStore.init`, 1.63 ms |

- Every store `init` passed the 10 ms target, by a wide margin. The thirteen together take under 5 ms.
- The first frame **did not** pass the 400 ms target in this debug build, in either layout.
  Where it goes, per warm sidebar launch: building `appShell` about 160 ms, of which `WorkspaceShellController.init` is only about 21 ms.
  Assigning `contentViewController` takes about 190 ms, of which `loadView` is about 128 ms.
  Setting the default frame takes about 125 ms, `orderFront` about 43 ms, and the display pass about 61 ms.
  The 140 ms of `appShell` outside the init interval, and the frame's own layout pass, are the follow-up.
  Both need a release-build measurement first, which this suite cannot take, because `FM_RUN_*` suites exist only in debug builds.

## 20. The macOS floor: running on 13 (TEST-10)

`Package.swift` declares `.macOS(.v13)`, and since R4-PROC-04 CI proves the
release binary really is a macOS 13 binary: `Scripts/check-deployment-target.sh`
fails the `swift build (release)` job when the binary's `minos`, the declared
platform and the `LSMinimumSystemVersion` the packaging scripts write disagree.
Compiling at that target is also what makes the compiler reject an API newer
than 13 without an `#available` check.

What CI cannot do is **run** anything on 13. GitHub retired its macOS 13
runner image in December 2025, and `macos-15` is the oldest image this project
builds on. So every `else` branch of an `#available(macOS 14, *)` or
`#available(macOS 15, *)` check is code no suite has ever executed
(`grep -rn '#available(macOS' Sources/GrandLine` lists them; there were three
on 2026-10-28).

The first full review's own fix for TEST-10 was to raise the floor to what is
tested and delete those branches. That drops support for 13 and 14, which is a
product decision rather than a process fix, so it is the captain's call.
Until then:

- [ ] On a Mac running macOS 13 (or a macOS 13 VM), install a packaged build,
      launch it, and open Home, Tasks, Console and Settings once each.
- [ ] Open the inspector, and the menu-bar popover's status menu - the two
      surfaces whose macOS 13 fallbacks only run there.

## 21. Flaky suites: the measured rate

R4-PROC-01 of the fourth full review: a flake that the runner re-runs is a
flake nobody sees. `run-all-tests.sh --rerun-failed` names it, CI's suite
history (`Scripts/suite_history.py`, uploaded as `suite-history-*` artifacts)
counts it, and this table is where the counts are written down, the same way
`SHARD_WEIGHTS` in `run-all-tests.sh` records the measured suite times.

Measured from the suite history that `main`'s run for #551 (run 40642363998,
2026-10-28) carried: the last 20 recorded runs of each lane, 2026-10-26 to
2026-10-28. "Flaky" means it failed and then passed on the runner's re-run;
"failed" means it failed both times. Every suite not listed passed all 20.

| Suite | Lane | Flaky | Failed | Which check, and where it stands |
| --- | --- | --- | --- | --- |
| `FM_RUN_MAIN_SPLIT_SHELL_TESTS` | windowed | 5 of 20 | 0 | Three were "taking Recents off saved nil", fixed in #549 by waiting for the save rather than a 50 ms drain, with none since. One was "overview at 998pt: the sidebar is collapsed" (and it recurred on this PR's own first run), fixed by R4-PROC-01. One was "Home's own cards at 1280pt, sidebar open" (#551's push), also fixed by R4-PROC-01. Both are described below. |
| `FM_RUN_MAIN_SPLIT_SHELL_TESTS` (after R4-PROC-01) | windowed | 1 on PR #553 | 0 | "setPosition left the sidebar at 264.0pt holding at 499.5, want 224.0" in `checkTheSidebarKeepsOneWidthOnEveryPage`, once, on PR #553's second CI run. It had not appeared in `main`'s 20 runs above. A traced replay on CI (25 placements after the same 1100 -> 1512 -> Console sequence, logging the pin range, holding priorities and every horizontal constraint at 490 or above) did not reproduce it, so the cause is **not known**. The 2026-10 placement fix (`placingDividerDidChange` laying the placement out before the resting hold returns) covers the one macOS 15 cause measured so far. If it recurs, the trace recipe is in `docs/history/31-testing-policy.md`. |
| `FM_RUN_REVIEW2_UX_TESTS` | windowed | 2 of 20 | 1 | "a narrowed sidebar did not grow back to 264 with the window (247.0pt)" every time, fixed by #547 (`holdDividerAtSidebarWidth`, merged 2026-10-27 11:37); none since. |
| `FM_RUN_SIDEBAR_REDESIGNS_TESTS` | windowed | 1 of 20 | 0 | Once, 2026-10-26: the Setup and Updates summaries read "—" / "In sync" for "Synced" / "Paused", a summary read before its async load. Not recurred in the 15 runs since; unexplained, so watch it. |

The Home rows flake, measured rather than guessed. Opening the sidebar narrows
Home's clip view without resizing the window, and Home reflows its cards on
the next main-queue turn after that (its clip-view observer). The suite
asserted after `settle`'s one 50 ms run-loop turn. On CI's loaded runner that
turn sometimes did not include the reflow, so the row had the new width and its
cards the old one ("row 1 ends at 1217.0pt of 952.0pt"). Twenty replays of the
case alone on CI, and twenty more on the runner's re-run, all passed, so it
only shows under the load of the cases before it. Asserting with no run-loop
turn at all reproduces the exact shape on every sidebar-open step, locally.
The case now waits for `HomeCanvasController.gridIsCurrentForTests` (the grid
was last built for the clip view's current width) before it measures, and
fails by name if that never happens within two seconds. The injected no-turn
variant passes with the wait in place.

The 998pt flake, also traced on CI rather than guessed. The check measures the
narrowest window that keeps the sidebar (the page's floor, plus a legacy
scroller's track while the system draws them, plus the sidebar), resizes to
it, and expects the sidebar to stay. A traced replay on CI measured 1013pt for
Overview (760 + 15 + 236 + 1 + 1). Both failures measured 998pt, which is the
same sum without the scroller track. CI's runner changes
`NSScroller.preferredScrollerStyle` after launch, and the shell re-fits its
panes on that notification. So the floor was read under overlay scrollers,
the style turned legacy during the resize's settle, and the shell correctly
stepped the sidebar aside at a width that no longer had room. The check now
re-measures after the resize until the floor holds
(`narrowestWidthKeepingSidebar`). Simulating the flip locally (raising the
floor by a track and posting the notification during the resize) fails the
old check with "overview at 1006pt: the sidebar is collapsed" and passes the
new one.

To refresh it, download the newest `main` run's histories and print each
lane's summary:

```sh
gh run download <run id> -p 'suite-history-*' -D /tmp/history
for f in /tmp/history/*/suite-history.json; do
  python3 Scripts/suite_history.py summary --file "$f" --lane "$(basename "$(dirname "$f")" | sed 's/^suite-history-//')"
done
```

- [ ] Before a release, refresh this table. A suite that shows up here twice is
      a defect to root-cause, never one to re-run.

---

## When something here fails

Prefer turning it into an automated suite if the failure is reachable
headlessly - most are not, which is why they are here. If it is genuinely only
observable in a real session, add the *mechanism* to a suite (a source guard, a
geometry check, a state-machine test) and leave the observation here.
