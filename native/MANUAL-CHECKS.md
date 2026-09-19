# Manual checks (captain-run)

Everything in this list is a thing the automated suites **provably cannot**
verify, not a thing nobody got round to automating. It exists because the
full-app audit's §7 asked for the honest boundary to be written down rather
than left implicit, so a green
`./Scripts/run-all-tests.sh` is not mistaken for "the app is verified".

Run this before a release, or after a change that touches one of the areas
below. It is short on purpose - a checklist nobody finishes is worse than none.

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

The traffic lights are repositioned *outside* their own superview and reached
by hit-test forwarding. A suite can hand the content view a synthetic point;
it cannot click a real one, drag a real window, or enter real full screen.

- [ ] Click **close**, **minimise** and **zoom**. All three work. (They were
      unreachable for three releases while every geometry test passed.)
- [ ] Drag the window by the floating bar's empty area. It moves.
- [ ] Enter and leave full screen. The lights hand off to macOS's own overlay
      and come back correctly, and the bar keeps its leading inset.
- [ ] Let a Console tab report shell titles for a minute (a few `cd`s). The
      lights must not drift - a bare `title` change resets them.
- [ ] Switch theme with a page scrolled away from its top. The chrome
      crossfades, the scroll-edge treatment stays, and nothing snaps.
- [ ] Sweep the cursor across the whole bar without clicking. **Nothing may
      activate** - no theme flip, no navigation. A bare hover once fired the
      theme toggle.

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

**Every 183 days** (six months), or sooner on an upstream security fix. Last
done 2026-09-19, against upstream `v1.20.0`: stay pinned. The recipe, the
decision rule and the running record are in
[`Vendor/SwiftTerm/README.md`](Vendor/SwiftTerm/README.md)'s "Updating this
vendored copy, and the scheduled check".

Here because it is a network fetch plus a judgement call: the question is not
"is there a newer tag" (there always is) but "has any of the five local patches'
root cause been fixed upstream, or gained a `public`/`open` hook" - which needs
reading upstream's current source and deciding, not a comparison a suite can
make.

- [ ] Run the four commands in that README section.
- [ ] Record the date and a per-patch verdict **even when the answer is
      "stay pinned"** - a check that leaves no record is one nobody can tell was
      skipped.

`FM_RUN_VENDORED_PATCHES_TESTS` covers the automated half (all five patches are
still present in the tree, so a sync that drops one fails by name) and prints a
NOTE - never a failure - once the recorded date is older than the interval.

## 16. Packaging

- [ ] `./build_native_app.sh`, then launch from `/Applications`.
- [ ] Confirm saved SSH keys still unlock (a changed signing identity breaks
      Keychain trust).
- [ ] Confirm the About/version string matches `git describe`.

---

## When something here fails

Prefer turning it into an automated suite if the failure is reachable
headlessly - most are not, which is why they are here. If it is genuinely only
observable in a real session, add the *mechanism* to a suite (a source guard, a
geometry check, a state-machine test) and leave the observation here.
