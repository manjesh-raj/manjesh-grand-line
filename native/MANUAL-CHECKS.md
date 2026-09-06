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

## 6. Real remote paths

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

## 7. Sync and external tools

- [ ] Make a Shift edit; confirm it commits and pushes within a few seconds.
- [ ] Make conflicting edits on two machines; confirm the conflict sheet
      appears and resolving it pushes the chosen version.
- [ ] Change the theme and confirm herdr's own selection colour follows after
      `herdr server reload-config`.
- [ ] Run a Setup → Updates check against real `brew`/`npm` and confirm the
      statuses match reality.

## 8. Packaging

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
