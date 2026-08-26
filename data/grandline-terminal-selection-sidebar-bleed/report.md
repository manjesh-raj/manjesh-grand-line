# Terminal selection bleeding into herdr's sidebar - investigation

## The original report

Captain, in a Console `.shell` tab running `herdr` (the terminal agent-multiplexer TUI,
which draws its own left sidebar of spaces/agents plus a right-hand content pane): a plain
click-drag to select text in the right-hand content area also visually highlights, and
copies, characters from the left sidebar - even though the drag never moves the mouse over
the sidebar itself.

## First hypothesis (wrong, corrected by the captain before any code was written)

The original brief assumed this was ordinary "any terminal selects the full row width for
intermediate rows" stream-selection behaviour, fixable only by adding rectangular/block
(column) selection, opt-in via a held modifier (Option), since SwiftTerm has no protocol-
level notion of herdr's own pane boundaries. That hypothesis was investigated first (see
"Standing fact" below - it's still true in general) but the captain tested the *same herdr
session* in WezTerm (a different terminal, no Grand Line code involved) and found: **a
plain drag there already selects only the right-hand content and never touches the
sidebar.** That falsifies "full-row selection is just how terminals work" as the
explanation for this specific case - WezTerm proves a plain drag against this exact herdr
session *can* be pane-correct.

## Standing fact, confirmed by reading the code, not changed by the correction

The vendored SwiftTerm engine (`native/Vendor/SwiftTerm/Sources/SwiftTerm/SelectionService.swift`
+ `Terminal.swift`'s `getSelectedLines`/`_getSelectedLines`) has **no rectangular/block/
column selection mode at all** - `SelectionService.SelectionMode` is only
`.character`/`.word`/`.row`, and `Terminal._getSelectedLines` explicitly selects the full
row width (`location: 0, length: cols`) for every row strictly between the selection's
start and end rows. `AppleTerminalView.selectedColumnsRange(row:cols:)` (the rendering
side) does the identical thing for the "in between" case. This is real, and if Grand Line's
*own* local SwiftTerm-native selection were ever the mechanism drawing a drag against
herdr's sidebar, it genuinely would paint the full row width across every "in between" row.
**But that isn't what's actually happening here** - see below.

## Root cause, confirmed by tracing the actual code path (not guessed)

Grand Line's `.shell` tabs opt into `CockpitTerminalView.prefersLocalSelection = true`
(`ConsoleController.addTab`, `if case .shell = launch`). Per its own extensive doc comment
and the `fm/grand-line-shell-tab-local-selection` history in `AGENTS.md`, this makes an
*unmodified* left-button drag build Grand Line's own local, themed SwiftTerm selection -
**even while the child process (herdr) has enabled real SGR mouse-reporting** - by
temporarily setting `allowMouseReporting = false` for the duration of the drag
(`withoutMouseReporting { ... }`) and replaying the press/drag through the vendored
`MacTerminalView.mouseDragged`'s own `selection.dragExtend(...)` path.

So: WezTerm forwards the plain drag to herdr (herdr enables `?1002h`/`?1006h` SGR mouse
reporting, confirmed present in the herdr binary per this app's own prior investigation
notes - see `AGENTS.md`'s `fm/grandline-console-selection-contrast-followup` entry), and
herdr - the one program that actually knows where its own sidebar/content boundary is -
renders its own pane-aware highlight in response. Grand Line's `.shell` tab, by contrast,
**deliberately hijacks the same plain drag away from herdr and into Grand Line's own local,
pane-blind stream selection**, which is exactly the "full row width for every row in
between" behaviour above. The bleed is real and the mechanism above (SwiftTerm's lack of
block selection) is a real, true fact about the engine - but it is not what's firing here.
**What's firing is that Grand Line is choosing not to let herdr's own, already-correct
selection run at all.**

This was a deliberate, captain-approved decision (`fm/grand-line-shell-tab-local-selection`),
not an accident - see its doc comment on `CockpitTerminalView.swift:210-259` and the
matching `AGENTS.md` bullet. The stated reasoning: for a `.shell` tab, "whatever
mouse-reporting program the captain starts inside it (Claude Code, vim, `less`, tmux,
`herdr` run by hand) is also reachable through its own keyboard interface... so an
unmodified drag is worth more as a selection than as a mouse report." That evaluation was
made across vim/tmux/Claude Code/herdr collectively, and concluded local selection wins as
the *default*. herdr is a real, demonstrated counter-example: it has a correct, pane-aware
mouse-driven selection UI of its own, and hijacking the drag away from it makes the result
*worse* than doing nothing.

## The mechanism the captain wants already exists today, gated behind Shift

`CockpitTerminalView.prefersLocalSelection`'s own design already has an escape hatch:
**holding Shift while dragging forwards the whole gesture to the child** instead of
building local selection (`divertsToLocalSelection`'s `!event.modifierFlags.contains(.shift)`
check; `withoutShift(_:)` strips the flag before handing the event to vendored
`MacTerminalView`, so the *child* doesn't see Shift as a modifier - only Grand Line's own
routing decision reads it).

Traced end to end through `mouseDown`/`mouseDragged`/`mouseUp` in both
`CockpitTerminalView.swift` and the vendored `MacTerminalView.swift`, and through
`MouseMode.sendButtonPress()`/`sendButtonTracking()`/`sendButtonRelease()` and the `?1002h`
CSI handler (`Terminal.swift:4407`, `mouseMode = .buttonEventTracking`): a Shift-held press,
every subsequent drag motion event, and the release are **all** delivered to
`sharedMouseEvent`/`terminal.sendMotion`, i.e. encoded and sent to herdr as real mouse
reports, for the whole duration of the gesture - with no gap, no missed release, and no
discontinuity even if Shift happens to be released mid-drag (once the gesture starts as a
Shift-drag, `deferredPress` is never populated, so it never re-enters the local-selection
branch later in the same gesture). This is mechanically identical to what WezTerm does on a
plain drag: forward the raw mouse events to herdr and let herdr paint its own selection.

**In other words: Shift+drag in Grand Line's Shell tab running herdr should already
reproduce WezTerm's plain-drag behaviour today, with no code change.** This was not
live-verified against a running GUI session in this sandbox (the captain's real signed
instance was already running when this investigation started - see "What was not verified"
below) - it is a full, unambiguous code trace, not a guess.

## The actual tension, and why this needs a decision rather than a unilateral fix

This is not "genuinely infeasible," and it is not simply "already working, nothing to do"
either, because the captain's own comparison point (WezTerm) requires *no* modifier at all
- an unmodified drag just works there. The open question is squarely about which gesture
should be the *default* in a `.shell` tab, and Grand Line has no reliable, non-herdr-specific
way to tell "this particular mouse-reporting child implements a correct pane-aware selection
of its own" from "this mouse-reporting child wants mouse events for some other reason and
would be worse to forward to for selection purposes" - vim, tmux, and `less` all enable the
identical `?1002h`/`?1006h` combination herdr does, and that combination was exactly the
original, deliberate reason `prefersLocalSelection` was added as a **blanket** policy across
all of them. There is no protocol signal that distinguishes "forward, I have a good
selection UI" from "don't forward, I don't." Building a hardcoded "if the child is named
`herdr`, forward" special case would be exactly the kind of herdr-layout-specific hack the
original brief (correctly) ruled out - it doesn't generalize, and it re-derives Grand Line's
own knowledge of a third-party tool's internals rather than working with a real protocol
signal.

## Options, with their real trade-offs

**A. No code change - Shift+drag already gives WezTerm-equivalent behaviour.** The fix is
telling the captain (and possibly a UI hint / tooltip / doc note) that holding Shift while
dragging in a `.shell` tab forwards the gesture to the child, which is what a herdr session
needs for its own correct selection. Zero regression risk to the vim/tmux motivation that
justified today's default. Downside: doesn't match "just drag, no modifier" the way WezTerm
does, and it's easy to forget/not discover.

**B. Invert the default for `.shell` tabs**: unmodified drag forwards to the child (matches
WezTerm exactly, zero modifier needed), Shift+drag forces Grand Line's own local themed
selection instead. This reopens the exact trade-off the original `fm/grand-line-shell-tab-
local-selection` decision weighed and resolved the other way - a captain selecting text
inside vim or tmux running in a `.shell` tab would now need to remember Shift+drag to get
Grand Line's own selection back, the opposite of today. Real regression risk to the
originally-reported (and captain-approved) motivating cases for that decision, unless
those are re-confirmed to be fine with the swap too.

**C. Add an explicit, persistent toggle** (global setting, or a per-tab context-menu item -
"Forward mouse drags to the program running in this tab") defaulting to today's behaviour,
so a captain who knows a specific session (herdr) has good native selection can flip it for
that tab/session without a herdr-specific hack in the code and without changing anyone
else's default. Buildable and avoids guessing globally either way, but is itself a new UI
surface and a real product-shape decision (global vs per-tab, persisted vs session-only,
where it lives in the UI) that deserves the captain's own call rather than a guess.

## What was not verified

This app has no OS-level process isolation between separate builds sharing one bundle
identity (`com.firstmate.cockpit.native`) - `pgrep` confirmed the captain's real, packaged
instance was already running at the start of this investigation
(`dist/Manjesh Grand Line.app/Contents/MacOS/FirstmateCockpit`), so per this repo's own
established convention no built copy of the app - debug or packaged - was launched for live
GUI verification, to avoid disturbing or colliding with that running instance. Everything
above is a full, traced code-path analysis across `CockpitTerminalView.swift` and the
vendored `MacTerminalView.swift`/`Terminal.swift`/`AppleTerminalView.swift`, not a live
click-drag reproduction.
