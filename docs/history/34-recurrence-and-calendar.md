# Recurrence, reminders and the calendar (F5)

F5 of full review #3 §8, built after F1 (Notebook, PR #426) and F2+F3
(universal capture and clipboard history, PR #427).

The report's own entry:

> **F5 - Recurring tasks, reminders, and a calendar view.** `RRULE`-lite
> recurrence on `ShiftTask`, a "remind me N minutes before" that rides
> `ShiftNotificationScheduler`, and a week/month calendar view as a third
> Tasks view (Board/List/Calendar). *Fit:* the Kanban just shipped its own
> view switcher. *Scope:* M (calendar is most of it).

The captain reviewed a mockup of this first, in the published
"Grand Line Futures" artifact (F5's panel: a September month grid with the
Board/List/Calendar switch, plus a recurrence/reminder panel showing "Every
weekday", the seven weekday chips and "15 minutes before"). What shipped
follows that shape.

---

## What shipped

Three pieces, in the order they depend on each other.

**`ShiftRecurrence`** (`native/Sources/GrandLine/ShiftRecurrence.swift`)
is the rule: three frequencies (daily/weekly/monthly), an interval, a weekday
set, and `UNTIL`/`COUNT` to stop. It serialises to an RFC 5545-shaped scalar -
`FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR` - under one `recurrence` key on
the task's YAML, plus `reminder_minutes_before` beside it.

**`ShiftStore.nextOccurrence`** advances the series. Completing an instance is
what writes the next one into `active.yaml`; nothing expands a rule in the
background and no series is stored.

**`ShiftCalendarViews.swift`** is the third Tasks view: a month or week grid of
day cells, mounted beside the board in `ShiftController` and switched by the
same `HelmSegmentedTabs` the Kanban shipped.

---

## The decisions, and why

### RRULE-lite means the syntax, not the parser

The report said "lite" and this took it literally. `BYSETPOS`, `BYMONTHDAY`,
`WKST`, `EXDATE` and the `VEVENT` envelope are all absent, because nothing in
this app reads or writes a real `.ics` file - the one thing a full parser buys
is interoperability with a calendar client, which is not what was asked for.

What *is* borrowed is the **serialized form**, and that is not decoration. The
store is a captain-owned YAML tree that a person edits by hand
(`ShiftYaml.swift`'s header says so), and
`FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR` is a line a captain can read,
recognise and correct in a text editor. A nested YAML sub-map for the same five
fields is not. So the whole rule travels as one scalar.

`parse` returns `nil` rather than guessing: a real `FREQ=YEARLY` rule from
somewhere else must not silently become a daily task that fires every morning
forever. Unknown components are ignored, and `INTERVAL=0` is clamped to 1 -
a hand-edited file is a real input, and that particular value would otherwise
make the generator produce the anchor forever.

### One live instance, advanced on completion

A recurring task is an ordinary task everywhere else in this app. The board,
the list, the calendar, the notifier, the stat tiles and Weekly Review all see
a task with a due date, and none of them had to learn what a rule is. That is
the whole reason for the "one instance at a time" design: the alternative -
materialising a series - would have put N copies of every repeating task into
`active.yaml` and into every count on the page.

Three things the spawned instance deliberately does not carry:

- `completedAt` - it is not done.
- The subtasks' `done` flags, which reset. A checklist on a repeating task is
  the checklist for *this* occurrence.
- The attachment. The file is keyed by task id, so a new id has none, and
  copying the bytes for every occurrence of a daily task is how a git-synced
  tree grows without bound (GL-35).

Reopening a completed recurring task does **not** withdraw the instance it
spawned. Un-completing is a correction to one occurrence, and silently deleting
a future task the captain may already have edited is the worse of the two
surprises.

### The reminder rides the existing scheduler rather than adding one

`ShiftNotificationScheduler` already polls every 60s and fires anything due
within a fixed 30-minute lookahead. "Remind me N minutes before" is that same
comparison with a per-task horizon:
`ShiftNotificationScheduler.horizon(for:now:default:)` returns
`now + N minutes` for a task that carries an offset and the scheduler's own
lookahead for one that does not. A task with no offset behaves exactly as it
did.

`0` is a real value ("at the due time") and is deliberately not the same as
`nil` ("this app's default"), which is why the optional is unwrapped rather
than defaulted.

The function is `static` and takes its inputs so the rule can be asserted with
no timer, no store and no notification centre - the whole of what the feature
means is that one comparison.

### Month is the calendar's default

The report left week-vs-month open. Month is the default because the thing a
recurrence rule needs a person to *see* is the pattern: five chips in a row
across a week, repeated down four weeks, is "every weekday" verified by eye -
and that is exactly the check a week view cannot offer. Week is still there,
because a day with six tasks on it is unreadable at month density.

### A projected occurrence is drawn differently from a real one

Only one instance of a recurring task exists as a record. Everything after it
on the grid is a *projection* of the rule. Drawing the two identically would be
GL-14's own failure in a new place - a thing that does not exist yet rendered
as a thing that does - so a projection is drawn at `alpha 0.55`, carries a
repeat glyph, and says "repeats on this day" in its accessibility label, which
is the one thing a sighted reader gets from the alpha and nobody else would.

The calendar's subtitle states the split ("7 tasks, 17 projected from a repeat
rule"), because a month showing 24 chips of which 17 are projections is a
different fact from a month with 24 real tasks.

### The grid lays itself out by hand

42 cells times up to 4 chips is ~200 views, and putting that in the window's
constraint graph is precisely AGENTS.md gotcha (15)'s measured cost - a full
re-solve of every required constraint in the window on any invalidation.
`ShiftCalendarGridView.layout()` computes frames instead: it costs nothing when
nothing changes, and it cannot reach the window's own size derivation at all.
Cells are reused rather than rebuilt across a month step, so paging through a
year does not churn the view tree.

---

## What the render actually showed

Two real defects, found by rendering the mounted calendar off-screen to a PNG
in both themes and looking at it (AGENTS.md's "Verifying native UI bugs"
convention - a temporary `FM_RUN_F5_RENDER_PROBE` suite, reverted before
commit). Neither was visible from the code or from any value assertion.

1. **No day boundaries.** The cells tiled edge to edge, and in
   `catppuccin-latte` the card and page tones are close enough that the whole
   month read as one undifferentiated field - no grid at all. Fixed by insetting
   each cell frame by the 1pt hairline, so the grid view's own background is
   seen *between* the cells. `ShiftCalendarViewSelfTest` now asserts that gap as
   a number rather than as "greater than zero", so an inset that drifts to 4pt
   fails rather than quietly becoming spacing.

2. **The commonest chip was the heaviest.** `ShiftProjectPalette` resolves a
   task with **no project** to `.neutral`, which is `chromeInkHex` - full page
   ink. Washed through `HelmContrast.tintedSurface` that produces a near-black
   bar on a light page, and most tasks have no project. An unprojected chip now
   takes `HelmField.fill` with ink text instead, which is the same "no identity
   signal" treatment the board's cards already use. This generalises and is now
   a standing rule in AGENTS.md's colour section.

---

## Verification

- `ShiftRecurrenceSelfTest` (`FM_RUN_SHIFT_RECURRENCE_TESTS`, pure logic, CI's
  blocking lane): parsing and round-trip, the daily/weekly/monthly generators,
  a weekly rule anchored **mid-week** (the case that catches a generator
  walking from the anchor rather than from the week's own first day), monthly
  clamping across February, `UNTIL`/`COUNT` termination, the completion
  advance and its three negative cases, and the reminder horizon.

  It runs against a fixed Gregorian/UTC/Monday-first calendar so a machine
  whose week starts on Sunday asserts the same dates.

- `ShiftCalendarViewSelfTest` (`FM_RUN_SHIFT_CALENDAR_VIEW_TESTS`,
  window-backed, `NEEDS_SESSION`): the real Tasks page in a real window, the
  Calendar pill genuinely clicked through `HelmSegmentedTabs`, the 42 cells'
  own laid-out frames, the hairline between them, real-vs-projected placement
  and alpha, the overflow count, paging, the week scale, and a real theme
  change.

**Both were confirmed to catch a regression, not merely to pass:**

| Injection | What failed |
|---|---|
| `next(after:)` reverted to start-of-day rather than the instant | 3 cases, including "the next weekday after Wed 16th is Thu 17th, got 2026-09-16" |
| A projected chip's alpha forced to 1 | "a projected chip should be drawn faint, got [1.0]" |
| `applyTasksViewVisibility` no longer hiding the flat panel for the calendar | "the flat task panel should hide when the calendar is showing" |

Two real bugs were found by the suites themselves while building, both in the
generator: `next(after:)` answering with the anchor itself (it was excluding
the anchor's whole *day* rather than the instant), and `UNTIL` losing its own
last day whenever the caller's calendar and the machine's local zone differed -
`ShiftDateFormatting.date(from:)` always resolves locally, and mixing that with
a caller-supplied calendar shifts the bound by the offset between the two.
`ShiftRecurrence.endExclusive` resolves `UNTIL` in the caller's calendar now.

- Full suite before: 170 passed, 0 failed, 1 skipped. After: the same plus the
  two new suites.

## What was deliberately left out

- **No custom interval stepper in the editor.** Six presets plus the weekday
  chips cover every recurrence this app's own data carries, and the mockup
  shows one popup. A hand-edited `INTERVAL=3` still loads, still generates and
  is still named by `displayName` - the Repeat card just shows "Does not
  repeat" for a rule its list cannot name, and Save preserves it.
- **No `UNTIL`/`COUNT` control.** The model supports both and the parser reads
  both; there is no UI for them yet. "Ends: never" is what the mockup shows.
- **No drag to reschedule on the grid.** A double-click on a day opens the New
  Task sheet pre-dated to it; moving an existing task between days is still the
  editor's or the row menu's job.
- **No completion affordance on a calendar chip.** A chip opens the task. A
  projected chip has no record to complete at all, and offering the gesture on
  one and not the other is worse than offering it on neither.

## The calendar becomes a Schedule-X page (`fm/grandline-calendar-schedule-x-1793081267`)

The captain chose [Schedule-X](https://github.com/schedule-x/schedule-x) for Tasks › Calendar, after the open-source calendar options review proposed it as the most modern option.
This replaces the hand-drawn month and week grid described above.
The model half of this file still holds: `ShiftCalendarModel.entries`, the one-live-instance rule and the projection rule are unchanged, and they are what the page is fed.

### What shipped

- The vendored bundle in `native/Vendor/ScheduleX/`, built by `native/Scripts/build-schedule-x-web.sh` the way the Monaco bundle is built.
  It is copied into the `.app` as `Contents/Resources/ScheduleXWeb`, and found by `ShiftCalendarAssets` in the same three steps as the other two web bundles.
- `ShiftCalendarWebView`, the `WKWebView` host, in `CodePreviewWebView`'s shape: call ids, a weak message proxy, page-loss recovery, the shared `WebNavigationPolicy`, and display gating.
- `ShiftCalendarView` is now a caption plus the page in a card.
  The page is not loaded until the tab is first shown.
- Month, week and day views, today highlighted, a now-line in the theme's own red, and the week and day views opening at 8 AM.
- A click on an event opens its task through the same `openBoardTask` the board uses.
  A double-click on a day, or on a time slot in week and day view, opens New Task pre-dated (and pre-timed) to it.
- **Drag to reschedule, which the grid never had.** A drop posts `move`, `ShiftController.rescheduleTask` applies `ShiftCalendarReschedule` and writes through `ShiftStore.updateTask`, and the toast offers Undo, which restores the date and time the controller held (GL-33).
  A projection, a completed task and a cancelled task cannot be dragged, and the page refuses a drop on one a second time in `onBeforeEventUpdate`.
  An all-day task stays all-day wherever it lands, and a timed task keeps its time when dropped in the month grid.
- The palette (`ShiftCalendarPalette`) maps the **app** theme onto Schedule-X's CSS variables in both registers, and is re-sent on every theme change.

### Decisions

**Drag and drop uses the last MIT release of the official plugin.**
Schedule-X 4.0.0 removed drag and drop and resize from the open-source repository and sells them as `@sx-premium` packages.
The 4.x core still calls a drag plugin through a three-method interface, and `@schedule-x/drag-and-drop@3.7.3` (MIT, released the day before 4.0.0) implements that interface under its 3.x method names.
4.0.1 renamed the hooks (`create*DragHandler` became `start*Drag`) with identical arguments, so the bundle adapts the names and nothing else.
The two alternatives were pinning the whole calendar at 3.7.3, which freezes the core on a dead major for one feature, or writing our own drag on Schedule-X's DOM, which is more code against less stable structure than the plugin interface.
`native/Vendor/ScheduleX/README.md` has the trade-off and the upgrade checklist.

**The native side decides; the page draws.**
A drop is a request, and the events are always re-pushed from the store afterwards, so a refused drop snaps back.
Every rule about what can move lives in Swift, where `FM_RUN_SHIFT_CALENDAR_TESTS` checks it in CI's blocking lane without a web view.

**Events are pushed for the visible period only.**
The page reports its range on every navigation, and the native side recomputes entries for exactly that range.
That keeps the recurrence projection bounded (GL-35), and it is what makes the caption's count true for the period on screen.

**A timed task is a half-hour block that ends by 23:59.**
A task has a due time but no duration, and a block that crossed midnight would turn into a two-day event in the week view's all-day row.

**Schedule-X's locale shape.**
It throws on anything that is not `ll-RR`, so `ShiftCalendarPayload.scheduleXLocale` reduces the captain's locale to that shape and falls back to `en-US`.

### What the renders showed

Rendered with the tour lab in the sidebar layout, across Daylight, Dusk, Graphite light, Night Watch, High contrast dark and Ember, in month, week and day.
Three defects were found that way and fixed before the PR:

- Schedule-X's own dark theme hides the View and Date field labels (`display: none` under `.is-dark`), so a dark theme had a different header from a light one.
  Our label ground is the theme's surface in both registers, so the labels stay.
- The default now-line is a literal `#f00`; it now takes the theme's own red.
- Week and day view opened at midnight, an empty screen for any task during the working day.
  The open-source `@schedule-x/scroll-controller` opens them at 07:50 instead.

The palette suite found one more: seven themes' text on the accent fill measured 4.47-4.49:1 once both colours were rounded to the `#rrggbb` the page receives.
It is the same quantisation trap `CodePreviewTheme.legibleHex` documents, and every text-on-fill pair is now measured against the quantised fill.

### Verification

- `FM_RUN_SHIFT_CALENDAR_TESTS` (pure, CI's blocking lane): the bundle's digests, the CSP, the licences and the `@sx-premium` ban, the bridge in the committed bundle including the drag adapter, the event payload, the locale and first weekday, the palette on all fourteen app themes, the reschedule rule, and the caption.
- `FM_RUN_SHIFT_CALENDAR_VIEW_TESTS` (window-backed): lazy load, events rendered from the store, today highlighted, a projection faint and real tasks opaque, a click opening its task, a real month-grid drag and a real week-view time drag read back from the store, a projection refusing to move, paging re-reading the store, a live theme change reaching the page's CSS variables and Schedule-X's own dark class, and suspension when hidden.

Each was confirmed to catch a regression:

| Injection | What failed |
|---|---|
| `calendarView.onMoveTask` wiring deleted from `ShiftController` | both drag cases: the store kept the old date and time |
| `isMovable` no longer excluding projections | "dragging a projection must not move the real task", plus two pure cases |
| The drag adapter removed from the bundle | all three drag cases in the view suite, and the three adapter cases in the pure suite |
| The live `setTheme` push skipped | "a theme change should repaint the page", the dark register and the dark class |
| Text on fills measured against the unquantised fill | eight palette cases on seven themes |

### Left out, and follow-ups

- The Schedules page's week view, Home's date cards and outside calendar sync were out of scope for this change.
- No resize: a task has no duration.
- No completion affordance on an event, for the reason the section above gives.
- The floating bar layout gets the same calendar, since both layouts share `ShiftCalendarView`; it is the sidebar layout's card radius that differs.
