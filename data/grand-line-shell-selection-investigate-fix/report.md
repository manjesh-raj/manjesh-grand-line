# Console Shell tab selection after the Mirror removal - investigation

Task: `fm/grand-line-shell-selection-investigate-fix`.
Trigger: the captain reported Console Shell tab text selection "messed up again" after
`fm/grand-line-remove-firstmate-mirror` (commit `9dd6076`, PR #293), with no working screenshot
of the actual symptom.

## Verdict

**The Shell tab's own text selection is not broken.**
A plain drag over a plain shell paints the active theme's `selectionHex` behind its
`selectionTextHex`, legibly, in all 14 themes - verified from real rendered pixels, not from
reading the code.

**There is one real, evidenced mechanism that produces exactly the reported symptom, and PR #293
did make it reachable where it previously was not.** It is not a defect in the Shell tab's
selection code; it is that the *mitigation* for it was scoped to the tab kind #293 deleted.
Deciding what to do about it is a product call, not an implementation one - see
"The open question" below.

## What was checked, and how

### 1. The diff, read line by line

`git show 9dd6076 -- .../CockpitTerminalView.swift` removes only the
`prefersLocalSelection` block: the property, the `mouseDown`/`mouseDragged`/`mouseUp` overrides
it drove, and the `sentToChildForTests` hook. Every one of those was gated on
`prefersLocalSelection`, which `ConsoleController+Tabs.addTab` set for `case .herdr` **only**.
A Shell tab never opted in, so on paper the deletion cannot affect it.

`git show --stat 9dd6076` touches neither `HelmTheme.swift` (which owns `apply(to:)`'s
`selectedTextBackgroundColor` / `selectedTextForegroundColor` pair) nor any vendored SwiftTerm
file (which owns the selected-run foreground override). PR #283's whole contrast machinery is
untouched.

`TerminalEnvironment.swift`'s change in that commit is comment-only.

"On paper" is not proof, so:

### 2. Real pixels, all 14 themes

`TerminalSelectionRenderSelfTest` (restored by this task - see below) drives a real
`CockpitTerminalView` in a real ordered-front window, feeds it real bytes, synthesizes a real
click-drag, renders with `cacheDisplay` and reads the pixels back:

```
  daylight:         rows=8 fill=4666D5 (want 3C67DC) inkBlend=1.00 residual=0.00
  dusk:             rows=8 fill=718CE6 (want 6A8DED) inkBlend=0.92 residual=0.00
  helm-dark:        rows=8 fill=87D5E1 (want 6CD7E3) inkBlend=1.00 residual=0.00
  helm-light:       rows=8 fill=306F91 (want 007194) inkBlend=0.91 residual=0.00
  solarized-dark:   rows=8 fill=519F98 (want 2AA198) inkBlend=0.92 residual=0.00
  solarized-light:  rows=8 fill=519F98 (want 2AA198) inkBlend=1.00 residual=0.00
  catppuccin-mocha: rows=8 fill=C5A7F2 (want CBA6F7) inkBlend=1.00 residual=0.00
  catppuccin-latte: rows=8 fill=7E3EE6 (want 8839EF) inkBlend=1.00 residual=0.00
  gruvbox-dark:     rows=8 fill=EE8739 (want FE8019) inkBlend=0.94 residual=0.00
  gruvbox-light:    rows=8 fill=A2421B (want AF3A03) inkBlend=0.91 residual=0.00
  tokyo-night-dark: rows=8 fill=82A1F1 (want 7AA2F7) inkBlend=0.94 residual=0.00
  tokyo-night-light:rows=8 fill=3558A4 (want 2959AA) inkBlend=0.91 residual=0.00
  rose-pine-main:   rows=8 fill=BFA8E3 (want C4A7E7) inkBlend=0.94 residual=0.00
  rose-pine-dawn:   rows=8 fill=3A6880 (want 286983) inkBlend=0.91 residual=0.00
```

The sampled hex differs from the palette hex by a channel step or two because
`bitmapImageRepForCachingDisplay` hands back a rep in the *display's* profile - AGENTS.md's own
probe rule. The comparison is done in the rep's own space, with tolerance; `residual=0.00` says
every glyph pixel lies exactly on the fill -> `selectionTextHex` segment, i.e. that ink and no
other is being drawn.

### 3. Real end-to-end, through the real `ConsoleController`

A temporary probe (reverted before commit, per AGENTS.md's convention) built a real
`ConsoleController`, opened its real Firstmate Shell tab (a real login-shell child, real command
output, the real `ConsoleCardChrome` inset and the real E1 display gating in effect), switched
themes through the real `ThemeManager`, and dragged:

```
  PROBE: tabs=1 mouseMode=off allowMouseReporting=true
  PROBE helm-light: selPixels=110529 want=007194
  PROBE helm-dark:  selPixels=110855 want=6cd7e3
  PROBE daylight:   selPixels=110533 want=3C67DC
  PROBE dusk:       selPixels=110848 want=6A8DED
```

Screenshots of those four renders are in `evidence/`. They match the captain's own reference bar:
a solid highlight block with clearly readable text, in both registers.

Note one difference from his reference image that is *taste*, not a defect: his dark-mode
reference shows a light-blue highlight with **white** text; `helm-dark` actually renders a cyan
highlight with **near-black** text (`selectionTextHex: 001a22`, a measured 10.6:1). `daylight` /
`dusk` are the themes whose selection is blue. All are legible.

## The open question

A plain drag only builds SwiftTerm's own selection when the child process has **mouse reporting
off**. `MacTerminalView.mouseDragged` returns early whenever
`allowMouseReporting && !shiftBypassesMouseReporting(event) && terminal.mouseMode != .off`, so a
child that enables mouse capture - Claude Code, vim, `less`, tmux, or `herdr` run by hand -
swallows the drag and the app's selection colours are never consulted at all. Measured, same
harness, same themes:

```
  helm-light plain drag:  rows=0  (nothing selected)
  helm-light shift drag:  rows=8 fill=306F91 (want 007194) inkBlend=0.91
  helm-dark  plain drag:  rows=0
  helm-dark  shift drag:  rows=8 fill=87D5E1 (want 6CD7E3) inkBlend=1.00
  daylight   plain drag:  rows=0
  daylight   shift drag:  rows=8 fill=4666D5 (want 3C67DC) inkBlend=1.00
  dusk       plain drag:  rows=0
  dusk       shift drag:  rows=8 fill=718CE6 (want 6A8DED) inkBlend=0.92
```

This is the *same* mechanism `fm/grandline-console-selection-contrast-followup` fixed for the
Mirror tab, and what a captain sees in that state is the child program's own highlight - herdr's
documented default is `selection_bg = "#313244"`, a dark navy with no idea which of the 14 themes
is active, which is precisely the original "dark navy block, illegible text in light mode"
report.

That behaviour is *not new* - a Shell tab was never opted into local selection, deliberately
(an `.ssh` tab may be running vim, where a plain drag reaching the remote program is what is
expected). What #293 changed is that the herdr session moved out of a tab that had the
mitigation and into wherever the captain now runs it. If he runs `herdr` (or Claude Code) inside
a Console Shell tab, the old symptom returns unmitigated - which fits "messed up **again**"
exactly.

Options, none of which this task took, because each is a behaviour decision:

1. **Do nothing.** Shift+drag already selects correctly in the theme's colours, in every theme.
   This is what iTerm2 and Terminal.app do, and it is what the captain already uses in his own
   terminal for a mouse-reporting TUI.
2. **Invert the default for `.shell` tabs only.** An unmodified drag builds the app's own
   selection; Shift forwards it to the child. Generalises the deleted routing (which is a
   *routing* mechanism, not a herdr-specific one) without touching `.ssh` tabs, where the current
   default is the right one.
3. **Invert it for every tab**, with Shift as the escape hatch. Simplest to explain, but changes
   plain-drag behaviour for an ssh tab running vim/tmux, which is the exact case the original fix
   deliberately excluded.

## What this task did change

`TerminalSelectionRenderSelfTest.swift`, restored as Shell-only. #293 deleted the file whole as
"dead code", but only three of its five cases were herdr-specific. Its first case - a real
`CockpitTerminalView`, a real drag, real pixels, every theme - is the only pixel-level guard in
this codebase that the theme's selection pair actually *reaches the screen* rather than merely
existing in the palette, and it never had anything to do with herdr. That half is back; the
three herdr cases stay deleted, along with every reference to `prefersLocalSelection` and
`sentToChildForTests`.

Confirmed to catch a real regression, not merely to pass:

- Removing the vendored `mutable[.foregroundColor] = selectedTextForegroundColor` line: fails by
  name in every theme (`glyphs only travel 0.00 of the way to selectionTextHex`,
  `glyph colours sit 0.69 off the fill->selectionTextHex segment`) - i.e. selected text rendered
  in its own ANSI colours, the captain's exact symptom.
- Pointing `HelmTheme.apply(to:)`'s `selectedTextBackgroundColor` at a literal: fails by name
  (`drawn fill 313243 is not selectionHex 3C67DC`). That injection happens to be herdr's own
  `#313244`, which is a neat illustration of what the failing state looks like.

Both were reverted.

## Verification

- `swift build` clean, no new warnings in this app's sources.
- `swift build -c release` clean; the release binary carries 0 `FM_RUN_*` strings.
- `./Scripts/run-all-tests.sh`: **86 passed, 0 failed, 1 skipped** (the skip is the documented
  pre-existing real-Whisper-model one).
