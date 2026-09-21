# Focus timer (F7)

A Pomodoro-style timer bound to one Shift task. Built by
`fm/grandline-feature-f7-focus-timer`, the fifth of full review #3 §8's
twenty-four recommendations the captain picked, after F1 (Notebook, PR #426),
F2+F3 (universal capture and clipboard history, PR #427), F6 (sticky → task,
PR #428), F5 (recurrence and calendar, PR #429) and F4 (reading list, PR
#430).

The report's own entry:

> **F7 - Focus timer / time boxing.** A Pomodoro-style timer bound to a task
> card ("Start 25 min on this"), logged to the task's activity, shown as a
> quiet bar chip, with a daily "time on tasks" tile on Weekly Review. *Fit:*
> Weekly Review, the activity log and `HelmRingGauge` all exist. *Scope:* S.

The captain reviewed a mockup before any of it existed, in the published
"Grand Line Futures" artifact (F7's section, rose hue). The mockup's own
closing note is the design decision the whole feature turns on:

> **Where it lives.** The chip in the top bar is the whole design decision: a
> timer that is only visible on the Tasks page is a timer you forget you
> started. It rides the bar the way the Kubernetes context badge already does,
> so it follows you into Console and Poneglyph.

---

## What shipped

- **A "Start 25 min" action on every task row.** `ShiftTaskListView`'s rows
  are `HelmAccentRow`s, which already own a `trailingAccessory` slot, so the
  button went there rather than into a new row layout. It fades in on hover
  (`ActionReveal.onAim`) on a list longer than three rows and stays visible on
  a shorter one, which is D1's own discoverability floor. The focused row's
  button reads **Stop** instead.
- **A "Focus for" submenu** on the row's context menu with 10 / 15 / 25 / 45 /
  50 minutes, plus **Stop Focus**, enabled only on the row that is actually
  being focused.
- **A bar chip** on `DaylightBarController`, between the drill actions and the
  search pill: a 14pt countdown arc, `17:24` in mono digits, and the task's
  name. Clicking it opens the ring panel.
- **A popover panel** behind the chip: `HelmRingGauge` at its full 66pt with
  the countdown in its centre, "of 25:00" under it, the task's name, and
  Pause / +5 min / Finish.
- **A "Time on tasks" panel on Weekly Review**: today's total as a headline,
  the number of distinct tasks under it, and a seven-day bar chart beside it.
- **A completion notification.** A session that runs out files a `lasting`
  `Feedback` report (GL-30) as well as its toast, because the captain is very
  likely in another app for the last ten minutes of a Pomodoro - which is the
  entire point of one.

Nothing about a *running* session is persisted. A running timer is runtime
state, not data; only the finished session is written.

---

## Where the session is recorded, and why there is no new store

Into Shift's existing `activity/<YYYY-MM>.yaml`, under a new kind
`task_focus_logged`, with the duration on a new
`ShiftActivityEntry.durationSeconds` field. A focus session is a thing that
happened to a task, which is exactly what that log already is - and Overview's
captain's log picks the entries up for free without a second feed.

The duration rides its own field rather than being parsed back out of the
`summary` string. Weekly Review's tile sums that field; a tile whose number
comes from scraping a human-readable sentence breaks the first time the
wording is improved.

`ShiftYaml.activity(from:)` defaults a missing `duration_seconds` key rather
than failing to decode - the same treatment `target_id` got when it was added,
and GL-01's rule applied to a type that is not `Codable`.

---

## The three design decisions worth stating

### 1. Elapsed time is accumulated, not derived from `startedAt`

A session can be paused, and a paused session must not keep earning minutes
the captain did not spend. `now - startedAt` would credit the whole lunch
break to the task. So `FocusTimerEngine` banks seconds into
`accumulatedSeconds` at every pause and measures only the *current* run
segment from `segmentStartedAt`.

That also bounds the damage from a wall-clock jump - a sleep, a timezone
change, a correction - to the one segment it happened in rather than to the
whole session. `FocusSession.elapsed(at:)` clamps the live segment at zero, so
a *backwards* jump cannot produce a growing countdown.

### 2. The logged duration is focused seconds, not planned minutes

"Start 25 min" is a request, not a record. A session stopped at 6 minutes logs
6 minutes; one extended twice and run to the end logs 35. A tile that reported
what was *intended* would be GL-14's "unknown rendered as a number" in a
different costume.

A session under one minute logs nothing at all
(`FocusTimerEngine.minimumLoggedSeconds`). Stopping ten seconds after starting
is a misclick, and `Focused 0m` in a task's permanent activity log turns the
log into a record of the captain's mouse.

### 3. Every rendered surface reads its numbers through the controller

`FocusTimerController.fraction` / `.countdownText` / `.plannedText` /
`.isPaused`, never `session.fraction(at: Date())` at the view. This is not
tidiness. It was measured: the first version had the chip and the popover each
call `Date()` for themselves, and the windowed suite - which drives a
fabricated clock - reported `0:00` and a full ring on a session that had just
started, because the views were reading a *different clock* from the one the
controller counts on. Eleven checks failed on it. With one clock the whole
feature is assertable against fabricated instants, and the chip and the ring
cannot disagree by a tick.

---

## Where the implementation departs from the mockup, and why

### The ring panel is a popover, not a right-hand column

The mockup draws the ring in a right-hand column on the Tasks page. This app's
Tasks page has a *leading* `HelmPageSidebar` and no trailing column; adding one
is a page-layout change F7 does not need. And the ring's own content - how long
is left, on what, and the three controls - is exactly what a captain wants
while they are somewhere *else* in the app, which is the same argument the
mockup itself makes for the chip. So the ring hangs off the chip: the same
content, reachable from every destination rather than from one.

### Rose on Daylight, the theme accent everywhere else

The mockup draws the whole feature in Daylight's rose. `HelmDomainHue.rose`'s
`fallbackTint` is `.critical`, so resolving it the usual way would paint a **red
alert** chip on the twelve pre-Daylight palettes for a benign running timer -
precisely the trap AGENTS.md's colour rules call out ("`fallbackTint` resolves a
*semantic* slot and will paint an alert bar on a benign row"). `identityHex` is
the sanctioned identity path, but its non-Daylight answer is `.neutral`, i.e.
page ink - too quiet for the one chrome element whose whole job is to be
noticed.

`FocusTint` is the resulting two-line split: rose on the Daylight family (the
captain's own default, and the only register the mockup was reviewed in), the
theme's own accent elsewhere. The accent is contrast-guaranteed across all
thirteen palettes by `FM_RUN_CONTRAST_TESTS` and already means "the live thing"
throughout this app.

### `HelmRingGauge` grew one variant rather than being duplicated

The existing `configure(value:total:)` renders an `N/M` count, where the arc
and the label come from the same pair. A countdown genuinely does not: the arc
is "how much of the session has been served" and the label reads "how much is
left". So the gauge gained `configure(fraction:text:monospaced:)` and a
`valueColorOverride` (the arc carries `FocusTint`, which a `HelmDomainHue`
cannot express). Every existing call site renders byte-identically - the
monospaced flag and the override both default off.

The chip's own 14pt arc is *not* a `HelmRingGauge`: that component is a fixed
66pt with a centre label, five times too big for a 34pt bar and carrying text
the chip already renders beside it.

---

## Two traps this branch actually hit

### The chip must be an *arranged* subview, or it keeps its width forever

AGENTS.md gotcha (11) in the direction that helps: a hidden ordinary `NSView`
keeps every constraint it had, and a hidden arranged subview of an
`NSStackView` genuinely leaves layout. So the chip lives inside a
`focusChipHost` stack - the same shape `drillActions` already uses on that bar
- and its gap constraint goes to zero alongside it, so a bar with no timer
running is byte-for-byte the bar that existed before F7.

`FocusTimerViewSelfTest` measures the **host's** width, not the chip's: a
hidden arranged subview keeps its own stale frame, so the chip's own width
proves nothing. Confirmed by injection - removing the `isHidden` line failed
"the chip should leave the bar when the session ends" and "and give its width
back, got 254.0".

### The chip's title needs priority 499, not 750 and not `.defaultLow`

Measured twice. At `.defaultLow` compression resistance the chip's own
`.required` hugging squeezed the title to nothing: a chip that said `25:00` and
named no task (the windowed suite reported a 78.5pt chip against an expected
~170pt). At the 750 default the title's natural width becomes a floor on the
whole *window* - AGENTS.md gotcha (13), a content constraint above
`NSLayoutPriorityWindowSizeStayPut` (500).

`HelmDaylightPriority.contentTie` (499) is the answer, inside the 251-499 band
gotcha (13) names: the title holds its natural width up to its 190pt `<=` cap
on any normal window, and a genuinely narrow one truncates it rather than
being capped by it.

---

### Three things the repository's own guards caught, not review

Worth recording because all three are the kind of thing that reads fine in a
diff:

1. **`FM_RUN_AUDIT_ENERGY_FIXES_TESTS`** (audit 3.4) failed by name the first
   time `FocusTimer.swift` existed: a repeating `Timer` with no `tolerance` is
   a hard wake-up the kernel cannot batch. Set to a quarter of the tick, which
   costs nothing here because every number on screen is re-derived from a real
   `Date` at paint time rather than counted in ticks.
2. **`FM_RUN_LOCK_GATE_COVERAGE_TESTS`** (GL-09 / §5.1(b)) failed on the
   popover: a popover left open when the app lock fires stays readable and
   interactive *above* the overlay. This one names the captain's current task,
   which is exactly what the lock exists to hide. Registered with
   `AppLockGate.registerLockDismissiblePopover`.
3. **`FM_RUN_CONTRAST_TESTS`** failed on `.secondaryLabelColor` as a stored
   default in `FocusWeekBarView`. A system semantic colour resolves against the
   OS's light/dark setting rather than the Helm palette - the "half-themed"
   defect this codebase has shipped four times. The defaults are seeded from
   the live theme instead.

And one the *source* guard could not catch on its own:
`DaylightModuleSelfTest.checkBarDoesNotCapWindow` flags **any** width
constraint at priority >= 500 anywhere on the bar, which the chip's 14pt ring
and its `<= 190` title cap both are. The chip is added to that walker's
skip list on the same ground the bell and `HelmDrillHeader` already are - a
content-sized cluster whose one flexible element yields at 499 - and
`FocusTimerViewSelfTest` carries the behavioural half the skip would otherwise
hide: a real window shrunk to the bar's own 700pt floor with the chip on it,
asserting the window actually holds that width. A source guard and a
behavioural check catch different things, and this trap needs both.

Also caught in self-review rather than by a guard: the Weekly Review panel's
text column used `setContentHuggingPriority` on an `NSStackView`, which gotcha
(12) measured to be a **no-op** - a stack has no intrinsic content size. It is
`setHuggingPriority` / `setClippingResistancePriority` now.

## Verification

Two suites, split the way AGENTS.md's classification rule requires.

- **`FocusTimerSelfTest`** (`FM_RUN_FOCUS_TIMER_TESTS`, CI's **blocking**
  lane). Pure logic: the start/pause/resume/extend/stop matrix against
  fabricated instants, both duration formats, the backwards-clock clamp, the
  displaced-session hand-back, the activity-log write, the one-minute floor,
  the per-day aggregation, and the YAML round trip in both directions (a new
  entry keeps its duration; a pre-F7 entry with no `duration_seconds` key
  still decodes, with `nil` rather than zero).
- **`FocusTimerViewSelfTest`** (`FM_RUN_FOCUS_TIMER_VIEW_TESTS`,
  `NEEDS_SESSION`). A real `DaylightBarController` and a real `ShiftController`
  in real `OffScreenProbe` windows: the chip's real laid-out width appearing
  and going away, its countdown text and ring fraction tracking a driven
  clock, the popover ring's own centre label and arc, Pause relabelling and
  actually stopping the clock, +5 min putting time back, the seven-day chart's
  bars and real frame, the headline and caption, and both surfaces repainting
  across a Daylight/legacy theme change (the chart sampled out of a real
  render, in pixels not points, per AGENTS.md's probe rule).

**Confirmed to catch regressions, not merely to pass** - three injections,
each reverted afterwards:

1. `pause` no longer clearing `segmentStartedAt` (so paused time keeps
   counting) failed 8 named cases, including "an hour paused must add nothing,
   got 4200".
2. The YAML writer dropping `duration_seconds` failed 6 cases across both
   suites, including "the duration rides its own field, got nil" and "the
   headline reads the day's total, got None yet today".
3. The chip no longer hiding when a session ends failed "the chip should leave
   the bar when the session ends" and "and give its width back, got 254.0".

Injection 2 was not deliberate: it was reverted with `git checkout --
ShiftYaml.swift`, which on a branch with no commits yet **discards the whole
task's work on that file** - the original codec change went with it, and the
windowed suite caught the loss by name on the next run. AGENTS.md already
states that rule under "Verification conventions"; this is the second time the
repository has paid for it.

**Not verified:** no captain-visible screenshot. This machine's agent shell has
neither Screen Recording nor Accessibility permission (AGENTS.md's "Verifying
native UI bugs" convention), so every geometry and colour claim above is a real
off-screen render read back through `cacheDisplay` and real `NSView.frame`
values, not a visual check. The live half - what the chip looks like riding the
captain's own bar while they work - is the captain's own check.

Full suite: **176 passed, 0 failed, 1 skipped (of 177)** on the final run,
against 173/175 on the baseline taken at `HEAD` before this branch (the two
new suites being the difference in the total).

One honest note on that baseline: the run was started immediately after the
pre-flight and `FocusTimer.swift` was written while it was still going, so the
source-grep guards in it saw the new file. That is how
`FM_RUN_AUDIT_ENERGY_FIXES_TESTS` caught the missing timer tolerance, and it is
the one failure the baseline reported. Everything else in that run measured a
binary built from the clean tree.
