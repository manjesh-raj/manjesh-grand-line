# Menu-bar (compact) mode (F22)

Built by `fm/grandline-feature-f22-menu-bar-mode` - one of five of full review
#3 §8's recommendations the captain picked to build in parallel (F20, F23, and
F21+F24 together, were the others, each in its own worktree).

The report's own entry:

> **F22 - Menu-bar mode.** A "compact" mode where the app lives entirely in the
> menu bar (tasks + sticky + vault popovers already exist for two of three), for
> a user who never wants the window. *Scope:* S-M.

The captain reviewed a mockup before it existed, in the published "Grand Line
Futures" artifact (F22's section): a macOS menu bar over a desktop with one
"Grand Line" popover open below it - a header carrying the app mark, the app
name, a `compact mode` caption and a gear; a full-width four-tab segmented
header (Today / Notes / Vault / Crew); a list of due tasks with checkboxes and
urgency captions; a focus chip and a follow-ups chip; a `Capture something…`
line with a return button; and a footer reading `⌃⌥G toggle` beside an
**Open full window** button. Beside it, three Settings toggles. The shipped
feature is that mockup, with the departures stated below.

The mockup's own closing note is the design decision this whole branch turns
on:

> Four tabs, not a menu. The report notes two of three popovers already exist;
> a popover with a real segmented header is the shape that lets them merge
> without a user learning three separate status items - and the capture field
> at the bottom means F2 works here too.

---

## What shipped

### The report undercounted: three popovers already existed, not two

The report says "two of three". In fact all three were there -
`ShiftMenuBar.swift` (tasks), `StrawHatMenuBar.swift` (the crew) and
`PoneglyphMenuBar.swift` (F16's 2FA quick-copy) - and the one that did *not*
exist was **Sticky**, which is the mockup's Notes tab. So the missing surface
was a different one from the one the report's phrasing implies, and the count
of existing status items was three rather than two. That matters because it
changes what the feature is: with three items already in the menu bar, adding a
fourth alongside them would have been the wrong end state, which is exactly
what the mockup's judgment note says.

### Compact mode merges three status items into one, rather than adding a fourth

`CompactModeController` owns one `NSStatusItem` whose popover carries all four
surfaces as tabs. Turning the mode on hides the three per-feature items
(`setStatusItemVisible(false)` on each - hidden via `NSStatusItem.isVisible`,
never torn down, so each keeps its store observation and its lock observer and
comes back with its count already current). Turning the mode off puts them back
and hides the merged one.

`CompactModePolicy.showsPerFeatureStatusItems` is asserted to be the **exact
inverse** of `showsCompactStatusItem`, so "four items, one of which contains
the other three" is not a reachable state.

### The Vault and Crew tabs are the real controllers, not lookalikes

This is the part that is reuse rather than a second implementation. The Vault
tab *is* `PoneglyphMenuBarPopoverController` and the Crew tab *is*
`StrawHatMenuBarPopoverController` - the same classes F16's and the crew's own
status items present - hosted as real child view controllers of the compact
popover. The countdown rings, the copy flash, the vault-locked state, the
per-second ticking, the crew's four-state reply area and its ask field are all
that code, unchanged.

Two things had to become parameters for that to work, and both are one line
each with the old behaviour as the default:

- **An injectable width.** Both controllers pinned their root at a required
  fixed width (300 and 320). A required 300 inside a 330pt popover is a
  constraint conflict, and per AGENTS.md gotcha (13) a required content width
  above priority 500 is a window-size cap waiting to happen. Both now take
  `init(width:)` defaulting to their own constant, so the standalone popovers
  are byte-identical.
- **A suppressible header.** Each drew its own title, which inside a popover
  that already says "Grand Line" is the second title the merge exists to
  avoid. `showsOwnHeader: false` hides the header row - hidden rather than
  omitted, because a hidden *arranged subview of an `NSStackView`* drops out of
  layout entirely, which is gotcha (11)'s one named exception and the same
  mechanism the crew pane already used for its own four states.

### Today is a new pane, deliberately

The Today tab is **not** a reuse of `ShiftMenuBarPopoverController`, and that
was a judgment call rather than laziness. That controller renders two stat rows
("Tasks today: 3") plus the next follow-up's title. The mockup's Today tab is a
different surface: a list of the actual due tasks, each with a real checkbox
that completes it, colour-coded by urgency, with the focus and follow-up chips
under a rule. Reusing the stat rows would have meant shipping the stat rows,
which is not what was reviewed.

`CompactTodayPane` and `CompactNotesPane` are the two new panes.
`CompactNotesPane` is built to `PoneglyphMenuBarPopoverController`'s shape -
a rows stack, a loud empty state, one persistent "Open …" affordance at the
bottom - because that is the convention the two existing menu-bar surfaces
already established, and following it was the brief.

### Every string on those two tabs comes from one injectable clock

`CompactModeDigest` is the whole derivation, takes `now` as a parameter,
returns value types, and imports nothing the panes need. The panes render what
they are handed and compute nothing. This is AGENTS.md's own "a live-updating
view reads its numbers from one injectable clock" convention, learned on F7 -
and it is what makes "overdue", "due today" and "tomorrow" assertable at all.

Decisions worth recording:

- **Ordering** is overdue first (oldest first - the one that has been late
  longest is the one being asked about), then today, then everything later
  soonest-first, with the task id as a stable last resort so two tasks due the
  same day never swap places between two opens.
- **Urgency is compared by day, not by instant.** A task due today at 09:00
  read at 17:00 is still "due today", not overdue. Using the task's own time
  would flip a row to red mid-afternoon, which is not what "overdue" means
  anywhere else in this app.
- **`overdueCount` is not `rows.filter { .overdue }.count`.** Rows are capped
  at five for a 330pt popover; the status item's badge has to report the truth.
- **A task with no due date never appears.** This tab answers "what is due",
  and a backlog item is not an answer to that. Completed and cancelled tasks
  are excluded too, and the badge count makes the same three exclusions.
- **GL-14 twice over**: no focus time logged today is a different state from
  "0:00" and renders no chip at all; a pending follow-up count of zero renders
  no chip; an untitled sticky note falls back through its first text line and
  then its first checklist item before reading "Untitled note", which is a
  state rather than a blank row.

### The capture line goes through F2's own filer

The footer's capture line is `AppShellController.makeCaptureFiler()` - the same
`CaptureFiler` ⌥Space writes through - so a task captured from the menu bar and
one captured from the overlay are one code path with one set of refusals. The
active tab decides the destination: Today files a task, Notes files a sticky
note.

**Vault and Crew take no capture**, and the reasons differ. The crew pane
already owns an ask field, and a second field under it asking the same question
differently is worse than no field. The vault's is a security position rather
than a layout one: `PoneglyphMenuBarController`'s header is explicit that a
menu-bar surface with no window and no Touch ID gate is the wrong place to hand
out credential material, and that argument runs in both directions - it is also
the wrong place to type one.

A **refused** capture keeps the typed text in the field and shows the reason.
Losing a capture to a failure is the one outcome ⌥Space's own panel refuses to
allow, and this is the same rule in one line.

### Lifecycle

Three pieces of app-level state, all derived from `CompactModePolicy` and none
of them inline at a call site:

- **`applicationShouldTerminateAfterLastWindowClosed`** returns
  `!isEnabled`. The whole mode rests on this: compact mode's way of having no
  window is to close the main one, and with the stock `true` answer switching
  the mode on would have quit the app.
- **The window is `orderOut`, never `close`.** The window and its whole mounted
  shell survive, so leaving the mode is instant and every destination keeps its
  state. The hide happens only on the *transition* into the mode - flipping the
  badge toggle later must not re-close a window the captain had deliberately
  brought back with "Open full window", which leaves the mode on.
- **`.accessory` is applied at runtime, and gated on the mode.** "Hide the Dock
  icon" resolves to `.accessory` only when compact mode is also on, and returns
  to `.regular` the moment the mode is switched off - so it can never leave a
  captain with a window and no Dock icon to raise it from.

**Departure from the mockup, stated deliberately:** the mockup's Dock-icon row
says "`LSUIElement` at runtime · needs a relaunch". `setActivationPolicy` is
a real runtime operation in both directions, so the shipped toggle applies
immediately with no relaunch and the row's copy says so. The behaviour the
mockup asked for is unchanged; only the caveat went away.

`leaveCompactMode()` writes the setting off *before* raising the window, and
the order is load-bearing: a `.accessory` app cannot activate or show a regular
window, so raising it first would silently do nothing. A mode you can leave but
which is still on next launch is not a mode anyone can get out of, which is why
"Open full window" writes the setting rather than only raising the window.

### ⌃⌥G

`CompactModeHotkey` is shaped on `ShiftGlobalHotkey` - same local + global
monitor pair, same honesty about the global half needing Accessibility trust.
Two deliberate differences: it is installed **only while compact mode is on**
(a chord for "open the menu-bar popover" is meaningless when there is no
menu-bar popover, and a monitor nothing can reach is what
`AppSettings.snippetExpansionEnabled`'s own note refuses to leave installed and
ignored), and it asks for no permission of its own - it is a convenience on top
of a status item that is always clickable, so an ungranted permission costs the
chord and nothing else. The local monitor still works whenever this app is
frontmost.

### Settings

Its own card ("Compact mode", `menubar.rectangle`, subtitle "Live in the menu
bar, with no main window"), immediately before Security. Its own card rather
than three rows inside Appearance, on the same reasoning F12's briefing card
records: this is not a look-and-feel preference, it is a switch that hides the
main window and changes what the menu bar contains, and the card's subtitle is
where that gets said.

All three settings are **off by default**, for three different reasons, each
recorded on the property in `AppSettings`:

| Setting | Off because |
|---|---|
| `compactModeEnabled` | it hides the main window, and a fresh install whose window never appeared would read as a launch failure |
| `compactModeHidesDockIcon` | gated on the mode anyway; on its own it would be a promise the policy refuses to keep |
| `compactModeBadgesOverdueCount` | the mockup states it as design rather than caution - a permanent red number is a bad neighbour in a menu bar |

All three toggles call one callback, not three: everything that follows from
them is `CompactModeController.refresh()`, which re-reads all of them and is
idempotent. Three separate notifications would invite three separate partial
applications.

### GL-09

`.compactModePopover` is its own `AppLockedSurface` case, per that file's
add-a-case rule, and here the rule earns its keep more plainly than anywhere
else: this one popover *contains* the tasks, vault and crew surfaces three
other cases already gate, so a shared case would have made four gates look like
coverage of one thing. It is also the only walk-up surface in the app that is
the captain's entire product - in compact mode there is no window for the lock
overlay to cover, so this gate is the whole of the lock.

The popover is refused outright while locked rather than opened empty (an empty
popover invites a second click), registered as lock-dismissible, and the badge
clears on the lock transition rather than on the next open. The task-completion
write consults the gate again at the write itself, which is the
belt-and-braces `ShiftMenuBarController.createQuickTask` already keeps.

### GL-23

Nothing here owns a store. Every number arrives through a closure and every
write leaves through one, all wired in `AppDelegate.wireCompactMode()` - one
method, so "what can the menu bar see and write?" is a question with one answer
to read. `ShiftStore` is the delegate's shared instance; `StickyBoardStore`,
`CredentialVaultStore` and the crew's runner are reached through
`AppShellController`, which forwards into the one page that owns each.

---

## Verification

Two suites, split the way AGENTS.md's "Writing a self-test" requires.

**`FM_RUN_COMPACT_MODE_TESTS` (pure logic, CI's blocking lane, 15 cases).** The
policy's four decisions across all four setting combinations, the badge's
opt-in and locked behaviour, `CompactModePolicy.current`'s reading of all three
keys, the ⌃⌥G chord against five near-misses, the tab table's capture mapping,
and the whole Today/Notes derivation - ordering, the row cap versus the true
count, the three exclusions, every caption, both chips' none-versus-zero
distinction, notes ordering and the title/detail fallbacks. It opens with
`checkTheFixtureIsTheDayItClaims`, which asserts the fixture really produces
three distinct dates and all three urgencies before anything reads it.

**`FM_RUN_COMPACT_MODE_VIEW_TESTS` (window-backed, `NEEDS_SESSION`, 16 cases).**
The real popover content in a real `NSWindow` at its real 330pt: the mockup's
chrome, exactly-one-pane-laid-out on every tab, the real segmented pill click
path, the embedded panes asserted **by type** (so a future "simplification"
into lookalikes fails), the capture line's presence per tab, a filed capture
clearing and a refused one not, a per-tab reported height, urgency painted
differently in both light and Dusk, the chips' contrast floor, the empty
states, real row clicks reaching the store, the Settings card, and the real
`CompactModeController`'s four transition effects.

### What was confirmed to catch a regression, not merely to pass

Injected by copying the file aside and editing it - never `git stash`, never
`git checkout -- <file>`:

| Injection | Failed |
|---|---|
| `showsPerFeatureStatusItems` → `true` | 12 cases across all four setting combinations, including "the two status-item decisions must be exact inverses" |
| `activationPolicy` no longer gated on `isEnabled` | "hide-the-Dock-icon left on with compact mode OFF must still be `.regular`" |
| `terminatesAfterLastWindowClosed` → `true` | both compact-mode lifecycle cases |
| vault pane built with its own header and width | "the embedded vault pane hides its own header", naming the four labels it found |
| checkbox border always the hairline | six cases, three in Daylight and three in Dusk, each printing both colour triples |
| all four panes left unhidden | all four tabs of `checkExactlyOnePaneIsEverLaidOut` |
| `onHideMainWindow` called on every refresh | "a later refresh while already in the mode does NOT hide it again - got 3" |
| `exitCompactMode()` stops writing the setting | three cases, including the activation-policy ordering |
| the hotkey monitor never torn down | "tears the hotkey monitor down rather than leaving it installed" |
| the Compact mode card never added to `cardsInOrder` | three suites at once: `DaylightDrillPageSlice6SelfTest`, `SettingsThemeLayoutParitySelfTest`, and this branch's own "Settings carries a real Compact mode card - the mode's discoverable home", which is why that case mounts the page rather than grepping for the builder |

### Rebased onto F20, which landed first

F20 (the daily review) merged ahead of this branch and touched five of the same
files. None of the conflicts was a logic collision - they were all additive
adjacency in one of two shapes.

**The shared-file conflicts**, all resolved by keeping both sides: a `Keys`
block in `AppSettings`, a pair of `HelmToggle` properties, a `card(...)`
binding, `cardsInOrder`, `refreshFromSettings`, `debugToggles`, and the feature
index row in `AGENTS.md`. One needed an actual merge rather than a
concatenation: `debugToggles` now lists all eight in card order, with a doc
comment saying so, because the suite that asserts its count reads that order.

Two things worth knowing if a third feature lands on this page:

- **F20 and this branch both wanted `docs/history/39-`.** F20 got there first,
  so this file is `40-`. Check the directory before picking a number.
- **A conflict hunk can split mid-function, and "keep both" then interleaves
  two function bodies.** That happened here between
  `buildDailyReviewSection()` and `buildCompactModeSection()`: the two hunks
  cut across the end of one function and the start of the other, so a
  mechanical both-sides resolution produced a file whose braces balanced
  nowhere and whose real symptom was `cannot find 'FlippedView' in scope` in
  eleven unrelated files - `FlippedView` is declared at file scope at the
  bottom of `SettingsController.swift`, and the missing brace had swallowed it
  into the class. The fix was to rewrite the whole region as the two complete
  sections rather than to patch braces. **`swift build` is the check that
  catches this**, and it is why a rebase here is not done until it passes.

### Five hardcoded counts in two existing Settings suites had to move

Adding one card and three toggles made two suites fail, and both were right to:
`SettingsThemeLayoutParitySelfTest` and `DaylightDrillPageSlice6SelfTest` each
pin Settings' card count as a **literal**, deliberately, so that "both themes
produced the same layout" cannot pass vacuously against a page that built
nothing. Their own comments say so.

So the honest response was to move the literal and name the change that moved
it, not to relax it into a `>=`. The counts are now **nine cards and eight
toggles** (seven and three at base, plus F20's card and pair, plus F22's card
and three).

The more useful half of the fix is that there is now **one** literal per suite
instead of four. `DaylightDrillPageSlice6SelfTest` had the same number in four
places; it now has a single named `expectedCardCount` with the whole lineage as
its doc comment, and every other card count in the file derives - one from
`settings.debugCards.count` captured before the resize (so the check asserts
"the same cards came back" rather than restating the total), and two that were
only literals inside `print` lines.

That mattered immediately: F20 and this branch landed a day apart, each had to
find and move all four copies, and the second of the two then hit a merge
conflict in **every** copy. One constant would have made that one conflict.

The injection above confirms all of it still bites: dropping the card from
`cardsInOrder` fails both suites by name.

### Two traps hit while writing the suites, both already in AGENTS.md

- **`NSApp` is nil in a headless suite**, and it is an implicitly-unwrapped
  `NSApplication!`, so `NSApp.setActivationPolicy` *crashed* rather than
  failing - which reads as a broken suite rather than a broken assertion.
  `NSApplication.shared` is what brings the instance into existence.
- **A pinned UTC calendar made the fixture wrong rather than hermetic.** A due
  date is persisted as a bare `"YYYY-MM-DD"` and read back by
  `ShiftDateFormatting.date(from:)`, whose formatter resolves it to *local*
  midnight - because "due today" means today where the captain is. Under a UTC
  fixture calendar every date parsed 5.5 hours on the wrong side of
  `startOfDay` and a task due today reported as overdue: the suite was
  measuring two calendars rather than the feature. Production passes
  `Calendar.current`, so the fixture does too, pinned to a *day* at local noon
  so no runner's time zone can land it on a boundary.

- **The compiler caught a vacuous assertion.** The first version of
  `checkTheEmbeddedPanesAreTheRealControllers` asserted
  `controller.vaultPane is PoneglyphMenuBarPopoverController` at runtime, and
  `swift build` answered "'is' test is always true" - which CI would have
  failed the build on, since the `build` job fails on any warning in this
  app's own sources. The warning was right twice over: the property's declared
  type already *is* the guarantee and is enforced at compile time (swapping in
  a lookalike stops the suite compiling), so the runtime check was exactly the
  "check that cannot fail" AGENTS.md warns about. It was replaced with the
  observable half a lookalike could actually get wrong - the real controller's
  own locked-vault copy, its child-controller hosting, its suppressed header
  and its width.

Two more found by the suites rather than by reading the code:

- `refreshStatusItemTitle()` reads the controller's *cached* policy, so writing
  a setting without calling `refresh()` leaves it stale. That is correct
  behaviour - Settings calls `refresh()` on every one of its three toggles -
  and was worth finding out in a suite rather than in the app.
- The badge observer was wired to `refresh()`, which meant ticking any checkbox
  anywhere in the app re-applied the activation policy, re-decided three status
  items' visibility and logged a line. Split into `refreshBadge()`, which
  repaints one number - GL-24's own shape.

### What was not verified

**The live half is the captain's own check.** Nothing here launched the app:
AGENTS.md's "never launch a built copy from a worktree" rule is absolute (one
bundle identity, no process isolation, the same JSON stores and git working
tree as the captain's running instance), and this machine's agent shell has
neither Screen Recording nor Accessibility permission, so there is no
screenshot and no synthesised global keystroke.

Concretely, three things are proven by mechanism rather than by observation:

- **⌃⌥G firing while another app is frontmost.** The chord predicate is
  asserted against five near-misses, and the monitor pair is the same shape
  ⌥Space's already-shipped hotkey uses - but the *global* monitor needs
  Accessibility trust this process does not have, so it was never seen to
  deliver an event.
- **The Dock icon actually disappearing.** `setActivationPolicy(.accessory)`
  is asserted to be called and to be reverted, via
  `NSApplication.shared.activationPolicy()`; whether the Dock visibly drops the
  icon is a window-server observation.
- **The popover appearing under the status item.**
  `NSPopover.show(relativeTo:of:preferredEdge:)` raises when its anchor has no
  window, which a headless process cannot guarantee - the same finding
  `StrawHatMenuBarSelfTest` records for the identical call. The suites drive
  the popover's *content* directly and only exercise the click path from the
  locked state, where `iconClicked()` returns before reaching `.show()`.

The status-item badge assertions **skip loudly** when the process got no
status-bar button, rather than passing vacuously; `CompactModePolicy`'s title
function itself is asserted unconditionally in the pure suite.

### Full suite

Before: 186 passed, 0 failed, 1 skipped, of 187. After: 188 passed, 0 failed,
1 skipped, of 189 - the two new suites, with the count literals above moved.

That full pass was taken **before** the rebase onto F20. After the rebase the
captain asked for CI to cover it rather than a second local pass, so what ran
locally was `swift build` (warning-clean) plus the eight suites the rebase
could actually have touched: both compact-mode suites, both Settings suites
whose literals moved, `E2ETestingPolicySelfTest` and `Phase3PolishSelfTest` (the
two policy guards), and both of F20's own suites, since this branch merged
their code. All eight pass. CI is the authority on the rest.

One operational note for whoever runs this next. The first post-change run
overlapped a sibling worktree's own pass, which AGENTS.md forbids for exactly
the reason it then demonstrated: `SelfTestDefaultsGuard` reported the shared
`FirstmateCockpit` domain dirty twice, naming themes neither lane had selected.
The clean run was taken after that pass finished, from `fm.themeID = dusk`, with
`git status --porcelain` empty. Checking `pgrep -fl run-all-tests` first is the
cheap half of that pre-flight - and note that a naive `until ! pgrep -f
"run-all-tests.sh"` waiter **matches its own command line** and never exits;
break the literal (`run-all-tests[.]sh`) or it waits forever.
