# Shell tabs keep an unmodified drag for their own themed selection

Task: `fm/grand-line-shell-tab-local-selection`.
Follow-on to `fm/grand-line-shell-selection-investigate-fix` (PR #296), which established the
facts; this is the captain's chosen fix for them.

## The decision this implements

That investigation found the Shell tab's own selection was fine, and that the reported symptom
came from a different mechanism: `MacTerminalView.mouseDragged` returns early whenever
`allowMouseReporting && !shiftBypassesMouseReporting(event) && terminal.mouseMode != .off`, so a
child that enables mouse capture (Claude Code, vim, `less`, tmux, `herdr` run by hand) swallows
the drag and the theme's `selectionHex` / `selectionTextHex` pair is never consulted at all. What
gets highlighted is the *child program's* own selection, from its own fixed palette.

Three options were put to the captain. He chose **option 2**: an unmodified drag builds the app's
own themed selection in a **`.shell` tab specifically**, with Shift+drag forwarding the gesture to
the child - the reverse of today's default, and scoped so `.ssh` (and every other tab kind) is
untouched.

This is a re-scoping of routing that existed before the Mirror tab was removed
(`CockpitTerminalView.prefersLocalSelection` / `divertsToLocalSelection`), implemented fresh
against `.shell`. It is **not** a reinstatement of that tab: nothing herdr-specific comes back,
and `TabLaunch` has no `.herdr` case to opt in.

## Why `.shell` and not everything

A `.shell` tab is a local login shell on the captain's own machine. Whatever mouse-reporting
program he starts inside it is something he can also reach through its own keyboard interface, and
*reading* that output is the tab's main job - so an unmodified drag is worth more as a selection
than as a mouse report.

An `.ssh` tab is the opposite case. It may be running vim or the captain's own tmux on a remote
host, where a plain drag reaching that program is the expected behaviour and the keyboard
alternative is someone else's machine away. That is the same reasoning the original fix used to
exclude `.ssh`, and it still holds.

The scope is invisible in a render - an `.ssh` tab opted in by mistake would paint exactly the
same pixels - so it is pinned by a source guard (case 5) rather than left to a comment.

## What a drag does now, per tab kind

| | `.shell` tab | `.ssh` tab |
|---|---|---|
| child has mouse reporting **off** | app's themed selection (unchanged) | app's themed selection (unchanged) |
| plain drag, reporting **on** | **app's themed selection** (new) | reported to the child (unchanged) |
| Shift+drag, reporting **on** | **reported to the child** (new) | app's themed selection (unchanged) |
| plain click, reporting **on** | reported to the child | reported to the child |
| scroll wheel | untouched | untouched |

A press is *deferred*, not forwarded-then-stolen: the child never sees a press whose release it
will not also see, which is what keeps its own button state consistent when a gesture turns out to
be a click.

## Verification

### Against real vim, in a real Shell tab

A temporary probe (reverted before commit, per AGENTS.md's convention) built a real
`ConsoleController`, opened its real Firstmate Shell tab, ran `vim -c 'set mouse=a'` on a real
fixture file, waited for vim to actually enable mouse capture, and then drove real gestures:

```
  PROBE: prefersLocalSelection=true mouseMode(before)=off
  PROBE: mouseMode(in vim)=buttonEventTracking
  PROBE helm-light: plainDrag sentToChild=0 selPixels=75738 | shiftDrag sentToChild=55 selPixels=0 | click sentToChild=18
  PROBE helm-dark:  plainDrag sentToChild=0 selPixels=76133 | shiftDrag sentToChild=55 selPixels=0 | click sentToChild=18
```

- **plain drag**: 0 bytes to vim, ~76k pixels of the theme's own selection fill.
- **Shift+drag**: 55 bytes to vim, 0 selection pixels - and `evidence/vimsel-helm-dark-shiftdrag.png`
  shows vim's status line reading `-- VISUAL --` with vim's own grey highlight, i.e. the escape
  hatch genuinely reached the program.
- **plain click**: 18 bytes to vim, so its own click targets still work.

Screenshots for both registers are in `evidence/`. The probe saved and restored
`ThemeManager.shared.theme`; `fm.themeID` read `helm-dark` before and after.

### Self-test

`FM_RUN_TERMINAL_SELECTION_RENDER_TESTS` grew from two cases to five. Cases 3-5 are new:

3. With a mouse-reporting child, an opted-in tab renders byte-identically to a plain one
   (`helm-light`, `helm-dark`, `daylight`, `dusk`); with the opt-in off, the same drag paints
   **nothing** - the pre-fix behaviour asserted rather than described, so a future change that
   makes the fix a no-op cannot pass case 3 vacuously.
4. A plain click and a Shift+drag are both still reported to the child, and an unmodified drag
   reports **zero** bytes (so the child never draws a second selection under ours).
5. Source guard: `.shell` opts in, and there is **exactly one** opt-in in `addTab`.

**Confirmed to catch three real injected regressions**, not merely to pass:

- Removing the `.shell` opt-in: `ConsoleController+Tabs.swift no longer opts the .shell tab into
  local selection`, plus `found 0`.
- Also opting `.ssh` in - the scope the captain excluded: `expected exactly one
  prefersLocalSelection = true opt-in in addTab, found 2`.
- Making `divertsToLocalSelection` return `false`: every theme in case 3 by name, e.g.
  `helm-light: mouse-reporting drew F5F6F8 ink-blend 0.00, plain drew 306F91 ink-blend 0.91`.

All reverted.

### Builds

- `swift build` clean, no new warnings in this app's sources.
- `swift build -c release` clean; the release binary carries 0 `FM_RUN_*` strings and 0
  `sentToChildForTests` (the probe hook is behind `FM_SELFTESTS`).
- `./Scripts/run-all-tests.sh`: **87 passed, 0 failed, 1 skipped** (the documented
  real-Whisper-model skip).
