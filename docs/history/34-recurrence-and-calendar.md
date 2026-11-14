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

## The Calendar becomes its own sidebar row, in the captain's card (`fm/grandline-calendar-sidebar-and-schedulex-ui-1793087315`)

The captain tested PR 542 and reported two things, each with an expected screenshot.
There was no Calendar in the sidebar, and the page was Schedule-X's plain default look inside the Tasks page.
The mockup puts Calendar in Work between Tasks and Crew, and draws it as a raised card with a raised cell per day.

### What shipped

- **A destination and a module of its own.** `RailDestination.calendar`, its slot, its `ModuleTable` row and its `WorkspaceModule` row, in Work right after Tasks.
  `TaskCalendarController` is the page, and it hosts the same `ShiftCalendarView` on the shell's one `ShiftStore` (GL-23).
  Its tabs are Month, Week, Day and Agenda, which the page draws through `ModuleTabHosting`.
- **One route.** Tasks lost its Calendar tab in both layouts, and the toolbar's calendar button opens the Calendar page through the same `openModule(.calendar)` the sidebar row uses.
  It reopens the view the calendar last showed, as a row does.
  The button now draws the Calendar row's own glyph, `calendar.badge.checkmark`, because the plain `calendar` glyph is Schedules' a few rows down.
  In the floating bar the page is reached from the Go menu, All Destinations and ⌘K, since that layout is frozen and gets no new pill.
- **The editors are shared, not copied.** `ShiftRecordSheets` holds the task editor, the follow-up editor, the delete confirmation and the completed-task notice.
  Tasks and the Calendar both present them, and each redraws itself afterwards.
- **The captain's card**, drawn by the page in `task-calendar.css` and `index.html`.
  It has round previous and next buttons, the period's title, a Today pill and Day, Week, Month and Agenda pills with the active one filled in the accent.
  Below that are a weekday row, a raised cell per day, dimmed days outside the month, today as a filled accent pill, chips with a left accent edge, and a legend.
  Schedule-X's own header is hidden.
  In the sidebar layout the page draws the mockup's "Calendar" heading with the period's count beside it, so the module declares `showsHeader: false`, like Connections and Console.
  In the floating bar its drill header carries that count instead.
- **Agenda** is Schedule-X's open-source list view (`createViewList` in `@schedule-x/calendar` 4.9.1), so no paid package was needed.
  A record with no time hides the midnight-to-midnight times Schedule-X would print.
- **Colour by kind, from real fields.** `ShiftCalendarCategory` maps a task's priority to the theme's red, violet or green, and a follow-up to its amber.
  Each one is a `HelmContrast.tintedSurface` chip with the hue as its edge, and the legend names all four.
  Colouring by project was dropped here, because most tasks carry no project and nearly every chip came out the same no-project grey.
- **Follow-ups are on the calendar too.** A pending, dated follow-up is drawn, opens its own editor, and drags to a new date with Undo (`ShiftCalendarReschedule.apply(followUp:)`).
- **New task** is the toolbar's primary action and ⌘N on this page.
  It opens the same New Task sheet dated to today when today is on screen, and otherwise to the day the calendar is focused on.

### Decisions

**The raised cells are drawn inside each day, never as a gap between days.**
The drag plugin finds the drop day with `closest('.sx__month-grid-day')`, so a margin between two days would be a strip where a drop lands on nothing and throws.
Each day keeps its full box, and the visible cell is an inset `::before`.

**A cell steps from its card toward the page ground**, which is the mockup's sunk-in cell.
Where a palette paints the two the same, the cell takes the smallest step that clears `HelmTheme.sidePanelSeparation`.
On High contrast dark the card is too close to black to sink from (black can only give it 1.05:1), so there the cell rises toward ink instead.

**An outside day's number is held to 3:1, not 4.5:1.**
It is muted ink stepped toward the dimmed cell for as long as it clears the large-text floor, which is what makes it read as not this month's.
`FM_RUN_SHIFT_CALENDAR_TESTS` also asserts it reads fainter than the month's own numbers, and that a dimmed cell sits flatter on the card than a month cell.

**Week and day re-scroll to the working morning on every switch.**
The scroll controller's `initialScroll` applies only the first time a time grid mounts, so a later switch from the month opened at midnight.

**The card's pills stay in the sidebar layout**, beside the toolbar's tabs, because the captain's mockup draws both.
They are one path: a pill posts the range with its view, and the toolbar follows through `onModuleTabChanged`.

**Saved settings needed no migration, and a test pins why.**
`fm.hiddenModules` stores the modules to *hide*, so an id the list has never heard of is shown.
A customised sidebar, either profile's starting set, and even a sidebar with Tasks hidden all show the Calendar row.
Nothing stores sidebar order, and page tabs are not persisted.
`SplitShellModelSelfTest.checkSavedSidebarsGetTheCalendar` fails on the plausible-looking rewrite to a list of modules to show.

**The Calendar takes no number chord.** ⌘1 to ⌘9 are the first nine sidebar items by position (R2-UX-03).
Numbering the new row would have moved Crew off ⌘3, shifted every module below it, and taken ⌘9 from Logs, which CI's `FM_RUN_REVIEW2_UX_TESTS` caught as ⌘3 opening the Calendar.
So `WorkspaceGoMenu.unnumbered` skips it, every chord a captain already knows stays put, and the Calendar's one-click route is the toolbar's calendar button.

**The Calendar's native label floor is 1**, `.whiteboard`'s reason: its body is one web view, and `FM_RUN_DESTINATION_MOUNTING_TESTS` counts native labels.
The page's own text is read back from its DOM by the view suite.
`FM_RUN_SETTINGS_SIDEBAR_TESTS`' guard against the retired Google calendar integration now allows exactly the Calendar module's own title in Appearance's show-or-hide list.

### What the renders showed

Rendered with the tour lab's new `calendar <month|week|day|agenda>` verb, in the sidebar layout and the floating bar.
The themes were Dusk, Daylight, Graphite, Graphite Dark, Paper, Ink, Harbor, Night Watch, both High contrast palettes, Ember, Cinder, Grove and Moss.
Two defects were found that way and fixed before the PR, and one difference turned out not to be one:

- At 1512pt the crumb dropped "Work ›". That is the toolbar's existing compact rule at that width, not a defect; a wider window shows "Work › Calendar" as the mockup does.
- The shell's module header draws only a subtitle in this layout, so the mockup's "Calendar" heading had nowhere to come from, and the floating bar printed the count twice. The page now draws its own heading in the sidebar layout and nothing in the floating bar.
- Out-of-month days were three levels off a month day on Dusk. They are dimmed much harder now, and the palette suite checks both the separation and the fainter number.

### Verification

- `FM_RUN_SHIFT_CALENDAR_TESTS` (pure, CI's blocking lane) adds the card's shell (every control and every view pill in the committed bundle, the hidden Schedule-X header, the inside-the-day cell), the categories and the legend, the follow-up payload and drop rule, the cell and faint-number contrast on every app theme, and the four scales against the module's tabs.
- `FM_RUN_SHIFT_CALENDAR_VIEW_TESTS` (window-backed) now mounts `TaskCalendarController`.
  It reads the title, the filled pill, the weekday row, the legend, the hidden header, a filled cell, a dimmed day and the today pill back from the page, along with each chip's category edge.
  It also checks a follow-up's click and drag, the Week pill moving the toolbar, the card's Next button, and the toolbar's Agenda tab.
- `FM_RUN_SPLIT_SHELL_MODEL_TESTS` adds the row's position, routing, glyph, the single route, the Go menu order and chords, and the saved-settings case.
- `FM_RUN_MAIN_SPLIT_SHELL_TESTS` checks that the toolbar's calendar button lands on the Calendar page with its row lit and the page's own view tab selected.

Each was confirmed to catch a regression:

| Injection | What failed |
|---|---|
| `case calendar` moved after `case crew` in `WorkspaceModule` | "Work lists ... want Calendar between Tasks and Crew", the sidebar tree's Work rows, the Go menu order |
| The stored hidden set always unioned with `.calendar` | "a customised sidebar's Work lists ...", its Go menu, its ⌘3 |
| The toolbar button sent back to `openModule(.tasks)` | "the calendar button went to shift", the lit row and the lit tab |

### Left out

- The Schedules page, outside calendar sync and other pages were out of scope.
- No resize: a task has no duration.
- The New task button says "New task", not the mockup's "New event", because it opens the New Task sheet and makes a task.

## The Calendar keeps its view across a hide and show (R4-BUG-01, `fm/grandline-review4-bugs-1793180000`)

Full review #4 reproduced it in the tour lab at 1512×950: open Calendar on Month, go to Home, come back, and it was Day for the rest of the session.
Schedule-X's `isResponsive` defaults to true.
On every window `resize` it checks whether the wrapper is under 700px and, if so, switches to the first view with small-screen compat, which is Day.
The shell hides a page by deactivating its pins (gotcha (15)), so a hidden calendar collapses and the page sees that resize.
The wide branch never switches back, because Day also counts as wide-screen.
The native side then adopted the `view` named in the page's `range` report, so the toolbar followed a switch the captain never made.

The fix has two halves, and either one alone would have hidden the symptom:

- The page passes `isResponsive: false`, and the bundle is rebuilt (`BUILD-INFO.txt` changed with it; `build-schedule-x-web.sh --check` matches).
- A `range` report moves the period and nothing else.
  The page's `selectView` is the one place the page changes its view, and it posts a `view` message of its own.
  `ShiftCalendarView` changes `scale` only from that message and from `show(scale:)`.

Taking the view out of the range report exposed the one other view change the captain makes inside the page: "+N more" on a crowded month day opens that day.
Schedule-X does that itself unless `onClickPlusEvents` is set, so the page now sets it and routes it through `selectView`.

`ShiftCalendarViewSelfTest` hides the page, deactivates its pins the way `setDestinationVisible` does, checks the page really saw a width under 700px, shows it again, pages once, and reads the view back on both sides.
It also posts a `range` report naming Day through the page's real message handler, and clicks "+N more" on a day with six tasks.
Confirmed to fail with `isResponsive` turned back on in the built bundle (the page on Day), with the native side adopting the range report's view again (the scale on Day), and with "+N more" switching the view directly instead of through `selectView` (page on Day, native on Month).

## The native side owns every web island's view state (R4-ARCH-01, `fm/grandline-review4-archperf-1793251195`)

Full review #4 turned R4-BUG-01 into a rule for all three web islands: the page reports, the native side decides, and a report that would change a native-owned value is logged and dropped.
The behaviour was already right after R4-BUG-01's fix, so this round changed no behaviour and made the rule visible and checked.

- `ShiftCalendarWebView`, `WhiteboardWebView` and `CodePreviewWebView` each state the rule in their header, with the values that island owns.
- The Calendar's `range` report still names the view Schedule-X is showing.
  The native side used to ignore it silently.
  It now passes it to `ShiftCalendarView`, which logs it when it disagrees with the scale and then drops it.
- The `view` report no longer assigns `scale` inside its callback.
  It goes through `adoptSelectedView(_:)`, which also logs and drops a view name with no scale.
- Code Preview logs a `change` for a snippet key it does not hold, where it used to drop it silently.

`WebIslandOwnershipSelfTest` (CI's blocking lane) reads each header for the rule and fails on any `on*` callback in the wiring files whose body assigns `scale`.
It checks its own detector on a planted callback first.
`ShiftCalendarViewSelfTest`'s existing range-report case now also asserts the report's view was counted as dropped exactly once.
Confirmed to fail with the old inline assignment put back in `onViewSelected`, and with the `logDroppedView` call removed.

The PR's first CI run then failed `MainSplitShellSelfTest` once with "Calendar › Agenda left the page on Week".
Clicking Month, Week, Day and Agenda in a row sends four `setView` calls, and the page answers each with a `view` report.
On a slow runner the report for Week arrived after the Agenda click, and `adoptSelectedView` took it, so for a moment the scale was Week again until the page's own `list` report put it back.
The toolbar check landed in that moment.
`show(scale:)` now remembers the scale it asked for until the page confirms it or the call completes, and a `view` report naming anything else in that window is logged and dropped as stale.
`ShiftCalendarViewSelfTest` requests Week then Agenda, delivers a stale `view: week` through the page's message entry before the page answers, and reads the scale at once.
Confirmed to fail with the guard disabled ("a stale view report pulled the scale back to week").

## The rule line round-trips (calendar plan PR 1, `fm/grand-line-calendar-pr1-rule-roundtrip`)

The tasks-and-calendar plan (2026-11-13) adds skipped dates, "2nd Friday" rules and series identity in later PRs.
Its first PR makes the data model safe for them before anything writes them, and changes no UI.

### What shipped

- `ShiftRecurrence` carries every component it does not model in `carried`, verbatim and in file order, and `ruleText` writes them back after its own.
  Before this, `parse` ignored an unknown component and the next save dropped it.
  The task-level `ShiftYamlPassthrough` could not help, because the whole rule is one value under the known `recurrence` key.
- A known key whose value this build cannot read for the rule's frequency is carried whole rather than half-applied.
  Examples are a plain `BYDAY=MO` on a monthly rule, an ordinal `BYDAY` on a weekly rule, and `BYMONTHDAY` on a daily one.
- New modelled components:
  - `EXDATE=YYYY-MM-DD,...` skips dates.
    A skipped date still counts toward `COUNT`, as RFC 5545 has it.
  - `BYMONTHDAY` (`13`, or `-1` for the last day) on monthly rules.
    A day the month lacks is skipped, unlike the plain monthly rule's clamping.
  - Ordinal `BYDAY` (`2FR`, `-1MO`) on monthly rules.
    With `BYMONTHDAY` as well, the two intersect ("Friday the 13th").
  - `FREQ=YEARLY`, which clamps a 29 February anchor to the 28th in common years.
- `series_id` and `occurrence` are task fields and known keys.
  `ShiftStore.nextOccurrence` walks the rule from `occurrence` when it is set, so an instance moved "only this" does not shift the series.
  The spawned instance keeps `series_id`, carries no `occurrence`, and drops skipped dates before its own due date (GL-35).
- `ShiftThreeWayMerge` asks the record type for a safe merge when both sides edited a record.
  For a task, skipped dates merge as a three-way set when at least one side changed them, with `updatedAt` set aside.
  A three-way set rather than a plain union, so an un-skip on one side survives.
  Any other edit on both sides is still a conflict, and the conflict's field list now includes the rule line as "Repeat".

### Decisions

- Nothing mints `series_id` yet, and nothing writes `occurrence` or a new rule component.
  Those belong to the PRs that add the editor and the exceptions, and this one has to reach the captain's build first.
- An unknown `FREQ` value (anything other than the four above) still makes `parse` return `nil`, and the next save drops the line.
  Nothing in the plan writes one, and keeping it would need editor semantics for a rule the sheet cannot show.
- The calendar still projects from the due date rather than from `occurrence`.
  It only differs once something writes `occurrence`, which is the exceptions PR's job.

### Verification

`FM_RUN_SHIFT_RECURRENCE_TESTS`, `FM_RUN_SHIFT_STORE_TESTS` and `FM_RUN_SHIFT_CONFLICT_TESTS` gained the new cases, all in CI's blocking lane.
`FM_RUN_SHIFT_CALENDAR_TESTS`, `FM_RUN_WIDGET_SNAPSHOT_TESTS` and `FM_RUN_SHIFT_DUE_TESTS` were also run, because they read the rule.
Confirmed to catch a regression:

- Dropping the carried-component append failed seven recurrence cases and four store cases, including the store's "a rule component this build does not model must survive the rewrite".
- Disabling the merge hook failed the conflict suite's "skipping different dates on two machines must not conflict".
- A plain union instead of the three-way set failed "the date GitHub un-skipped stays un-skipped".
- Not applying `EXDATE` in the walk failed five recurrence cases, including "skipped dates must not be produced".

## Every open task has a place: the Unscheduled tray (PR 2 of the tasks-and-calendar plan, `fm/grand-line-calendar-pr2-unscheduled-tray`)

The captain opened the Calendar with 13 open tasks, none of them dated, and saw an empty month captioned "Nothing scheduled in this period."
`ShiftCalendarModel.entries` skips every task with no due date, and nothing else on the page showed one, so the caption read as if there was no work.
The plan (`grand-line-tasks-calendar-plan`, captain decision 2A) puts an Unscheduled tray beside the calendar card.
This PR is that tray, the new caption, the first-run empty state, and past months read from `completed/`.
It is independent of the plan's other PRs: the tray belongs to the calendar card wherever the card ends up living (PR 4).

### What shipped

- **The tray**, a second card beside the calendar's, inside the same Schedule-X page.
  It lists open tasks with no date, grouped by project in the store's own order with "No project" last, sorted by priority then title.
  Overdue tasks and overdue follow-ups are pinned above them, oldest first, and still drawn on their own day too.
  A row's edge is its category colour (the same one its chip would have), and a group's dot is its project's colour, with "No project" drawn faint rather than in page ink.
  Hovering a row shows Today, Tomorrow and Pick….
  Today and Tomorrow go through `ShiftCalendarReschedule` and the store, with the same Undo a drop has.
  Pick… opens the task's editor until the When panel (PR 5) exists.
  The fold button folds the tray to a 44pt strip, and the choice is kept in `fm.calendar.trayCollapsed`.
- **The caption** counts the period's records, how many of them are repeat dates not yet created, then the unscheduled and overdue counts, in the period's own words ("this month", "this week", "today").
  For example: "24 tasks this month, 9 of them repeat dates not yet created · 8 unscheduled · 2 overdue".
  A period with nothing dated but open work elsewhere says "Nothing dated this week · …", and "Nothing scheduled this month." is left for a store with no open work at all.
- **The first-run state.** When open tasks exist and none of them (and no pending follow-up) has a date, a card over the dimmed grid says "Nothing has a date yet", counts the open tasks, points at the tray, and offers New task and Open List (Tasks › List, through the shell's navigator).
  Agenda shows its own empty text instead.
- **Past months.** The Calendar used to load finished tasks only inside the board's 7-day Done window, so any earlier month looked like nothing had happened.
  The view now asks `ShiftStore.completedTasks(inMonths:)` for the `completed/` files its visible period touches, plus one month either side, because a task is filed by the month it was finished in rather than the month it was due.
  Each month file is memoised and invalidated with the existing completed-tasks cache, and the month key is validated before it becomes a file name.

### Decisions

- **The tray lives in the web page, not in AppKit.** The plan's risk table chose this so that PR 7's drag from the tray onto a day can use the same DOM the grid's drag already uses.
  Every word and colour still comes from `ShiftCalendarPayload.tray`, so the wording is asserted in the blocking lane without a page.
- **`schedule` names the button, never a date.** The page posts `when: "today"`, and `TaskCalendarController.scheduleFromTray` resolves the day on the native clock.
- **The fold is a request.** The page posts `tray`, the native side stores the choice and sends the tray back folded, which is R4-ARCH-01's rule for web islands.
- **No drag wording.** The board's tray copy says "Drag onto a day" and "Drop a chip here to clear its date", which are PR 7.
  The hint and the empty state offer Today and Tomorrow instead, and `checkTrayPayload` fails if the empty state mentions a drag.
- **The Agenda's "No date" group** is part of the Agenda rework in the plan and is not in this PR.
- **A new palette variable, `--gl-overdue-ink`**, is the theme's red corrected for legibility on the card, because the Overdue heading and rows are text and `--gl-now-line` is the raw red used as a line.

### Verification

- `FM_RUN_SHIFT_CALENDAR_TESTS` (blocking lane): `checkTrayModel` (grouping, order, overdue, in-progress included, finished and cancelled excluded, undated follow-ups excluded, the first-run predicate and its discriminating fixtures), `checkTrayPayload` (meta strings, edges, dots, the empty state's words), `checkCompletedMonths` (the month window, the month-key guard, and a real scratch store whose memo is invalidated by un-completing a task), the new caption cases, and the bridge entries and page ids.
  Confirmed to fail with the old "Nothing scheduled" caption put back for an empty grid (three cases).
- `FM_RUN_SHIFT_CALENDAR_VIEW_TESTS` (windowed lane): an undated-only store draws its two tasks in the tray, grouped, with the first-run state over the grid and a caption that counts open tasks.
  The real Today button on a row writes today's date, read back from the store, after which the row leaves the tray, the empty state gives way and the chip is on today.
  Tomorrow on an overdue follow-up writes the follow-up's date, the fold button folds and is remembered, and a task finished two months ago is drawn struck through when that month is shown.
  Confirmed to fail with the bridge's `schedule` handler disconnected and with the controller's `completedTasks` hookup returning nothing (eight checks between them).
- Rendered with `WKWebView.takeSnapshot` in Daylight and Dusk, for the empty state, the tray with a hovered row, and the folded strip.
  The first render found the quick buttons spilling out of a hovered row, because `.gl-tray button { font: inherit }` out-ranked `.gl-quick`'s own size.
  The reset now inherits only the font family.
- `build-schedule-x-web.sh` regenerated `web/` (and `BUILD-INFO.txt`) from `src/`.

## Reminders: the all-day time, a missed repeat, and follow-ups (tasks-calendar plan PR 3, `fm/grand-line-calendar-pr3-reminders`)

PR 3 of the tasks-calendar plan (`data/grand-line-tasks-calendar-plan/report.md`).
It changes when a Tasks reminder fires and nothing about how one is delivered.

### What shipped

- **A date-only item reminds at `all_day_reminder_at` on its own day.**
  `settings.yaml` gained `all_day_reminder_at`, `"09:00"` by default.
  `ShiftDue.reminderInstant` used to be local midnight for a date with no time, and the poll's 30-minute lookahead then posted "Task due today" at 23:30 the evening before.
  A date-only item with no offset takes no lookahead now, because its reminder moment is already a chosen time.
  "1 day before" means that time on the day before.
  An unreadable value falls back to 09:00, never to midnight.
- **One fire rule.** `ShiftDue.reminderFireInstant` answers "when does this fire" for a task, a follow-up and the next date of a missed repeat.
  It replaced `ShiftNotificationScheduler.horizon(for:now:default:)`.
- **A missed repeat reminds for its next date.**
  When a repeating task's live occurrence is overdue, the poll also reminds for the series' next date, once, as `shift.task.<id>@<YYYY-MM-DD>`.
  The live record is not rolled forward, so the missed one stays overdue (the captain's decision 5A).
  `nextDateToRemind` walks the rule the way `ShiftStore.nextOccurrence` does: from the rule slot (`occurrence`, PR 1) when the live record was moved "only this", a last `COUNT` occurrence has no next date, `UNTIL` ends it, and missed slots do not spend the budget.
  A skipped date (`EXDATE`) is never reminded for, because the walk already leaves it out.
  It starts at today, so a series left for months reminds once for today rather than once per missed date.
  A next-date banner is withdrawn when its date has passed and when the task is completed or deleted.
- **Follow-ups have "Remind me".** `ShiftFollowUp.reminderMinutesBefore` (`reminder_minutes_before` in `follow-ups.yaml`, added to the known keys), the same choices as a task, and a card on the follow-up sheet.
- **A snooze resets an explicit offset to "at the time".**
  The banner's "Snooze 1h" writes a new time and used to keep the offset, so "1 day before" put the snoozed follow-up a day in the past and the next poll reminded again.
  A follow-up with no offset keeps the default lookahead it always had.
- `poll(now:)` takes an injectable instant, so a suite can ask about 23:30 and 09:00 directly.

### One trap

`YamlSwift` follows YAML 1.1, which reads an unquoted `07:30` as a **base-60 integer** (450).
A captain who types `all_day_reminder_at: 07:30` would otherwise silently get 09:00.
`ShiftYaml.settings(from:)` turns such an integer back into `HH:MM`.
The same parser treats an unquoted `due_time` the same way, which this PR did not change.

### Verification

`ShiftDueSelfTest` (blocking lane) gained five cases: the date-only fire rule through the helper and through `poll(now:)`, the setting (including the unquoted form and five unreadable values), the next-date walk, the next-date banners through the poll, and follow-up offsets through the poll, the YAML, a snooze and the sheet's own Save.
`ShiftRecurrenceSelfTest`'s offset cases moved to `reminderFireInstant` unchanged in meaning.
Confirmed to fail by injection:

- The old rule put back (midnight anchor plus the lookahead) failed 14 checks, including "a task due Friday with no time must not remind at 23:30 on Thursday" and the same through the poll.
- Removing the next-date call from `poll` failed five, starting with "with Monday missed, the poll reminds for Wednesday".
- Passing `nil` for a follow-up's offset failed "a follow-up's own "2 hours before" fires at 13:00".
- Dropping the follow-up's YAML write failed "the offset round-trips through follow-ups.yaml".
- Removing the snooze reset failed "a follow-up snoozed by an hour must not remind again a minute later".
- Walking from the due date instead of `occurrence` failed "a moved occurrence's next date follows the rule slot".

### Left out

- No UI for `all_day_reminder_at`.
  It is a `settings.yaml` key, and the When panel (PR 5) is where the time controls are being reworked.
- The task editor still writes a time for every due date, so a date-only task saved through the sheet becomes `00:00`.
  PR 5's "All day or At a time" row is the fix for that.
- The conflict UI's field list shows neither a task's nor a follow-up's reminder offset, as before.

## One Tasks surface: the Calendar is Tasks' view again, and its row is a door (tasks-calendar plan PR 4, `fm/grand-line-calendar-pr4-one-tasks-surface`)

The captain chose decision 1A of the tasks-calendar plan: one Tasks surface with two doors.
The Calendar page had none of the Tasks page's filters, its project picker or its New task, so a filter set on Board was lost on the way to the calendar.
This PR makes the calendar Tasks' third view again and keeps the sidebar row the captain asked for, as a way in rather than a second page.

### What shipped

- **Tasks' views are Board, List, Calendar and Weekly review**, in the toolbar and in the floating bar's switcher.
  `TaskCalendarController` is a child controller the Tasks page embeds under its filter row (`ShiftController+Calendar.swift`), not more of the 3,500-line page (GL-36).
  It lost its own header, its New task button and its toolbar tabs.
- **Two doors.** The Calendar sidebar row, the toolbar's calendar button, the Go menu's ⌘0, ⌘K, Recents, a notification and a saved session all land on Tasks' Calendar view.
  The crumb, the tabs and the header are Tasks'.
  The Calendar row is lit while that view shows, and the Tasks row on the other views.
- **Shared filters and tray.** The scope (All tasks, Due today, Overdue, My priorities, Recently updated) and the project picker run through the same `matchesFilters` the board uses, so they apply to the grid, the finished tasks of past months, the Unscheduled tray and the caption.
  Follow-ups take the project filter, as the board's Follow-ups lane does.
- **The header's line on the Calendar view is the calendar's caption**, after the project when one is picked.
- **New task and ⌘N on the Calendar view** date the task to the day on screen, as the old page's New task did.
- **Day, Week, Month and Agenda are the card's own pills**, the one switcher for the period.
- **Colour by Priority or Project**, beside the filters while the calendar shows and in the Filter menu when the row collapses.
  Remembered in `fm.calendar.colourBy`.
  By project, each project is its own Schedule-X calendar in the board's project hue, and a task with no project is the neutral field fill with ink text, never a wash of page ink.
  The legend becomes the projects, No project and Follow-up, and a follow-up stays amber.

### Decisions

- **`RailDestination.calendar` stays as a route.** ⌘K, Recents, notifications and saved sessions address it, so removing it would have turned every saved "calendar" into Home.
  Its `ModuleTable` row now says it lives in Tasks › Calendar and names the Calendar row as its `door`.
  `ModuleTable.landing(for:)` turns the route into the Tasks page plus its Calendar tab, and `Navigator.show` lands it there.
  Its slot is the Tasks page's, so `DestinationSlotID.calendar` is gone.
- **The lit row is one mapping**, `ModuleTable.sidebarModule(for:pageTab:)`, as the plan's risk table asked.
  The sidebar asks it with the page's current tab, and a hidden Calendar row falls back to lighting Tasks.
- **The Tasks row reopens Board or List after a Calendar visit**, not the Calendar.
  The shell does not record a door's tab as the module's last tab, because clicking Tasks and seeing the Calendar row light up reads as the wrong click.
- **The Tasks route means Tasks, not its Calendar view.** ⌘K's "Switch to Tasks", Home's Tasks card or a notification arriving while the page was last on the Calendar lands on Tasks' first view with the Tasks row lit.
  `Navigator.show` decides it, so a route lights the row it names whichever entry point used it.
  The full local run found this: `ReviewTwoUXSelfTest` opened `.shift` on an empty store after the route sweep had left Tasks on its Calendar view, and got the calendar instead of the start-here state.
- **One Go menu item.** Tasks' Calendar tab is left to the Calendar row (⌘0), and comes back under Tasks when the row is hidden.
  ⌘1 to ⌘9 and ⌘3 for Crew are unchanged.
- **Hiding the Calendar row hides the route in ⌘K**, and hiding Tasks does not (`hidesPage` asks the door).
- **The calendar fills the column under the filter row.**
  Its section's height is tied to the clip view's at priority 490, under the window's hold on its size (gotcha (13)), so a short window scrolls the page instead of squeezing the month below `ShiftCalendarView.minimumHeight`.
  The tie is released while another view shows, because a hidden view keeps its constraints (gotcha (15)).
- **An empty store shows the calendar, not the start-here state**, on the Calendar view only.
  An empty month is still what the captain opened, and a double-click on a day adds the first task.
- **The calendar no longer observes the store itself.** The Tasks page already re-renders on a store change (REL-02) and renders the calendar while it shows.

### What the renders found

Tour-lab renders of Tasks › Calendar at 1512 × 920 in Daylight and Dusk, of Board, and of the Calendar at 1100 × 820.
Two defects were found that way and fixed before the PR, both in `fitFilterRow`:

- On the first visit the filter row showed the Board's sort instead of Colour by.
- After narrowing the window to 1100 the row ran past the page's edge instead of collapsing into Filter.

Both came from reading the row's own width, which lags the content column's by one layout pass.
`fitFilterRow` runs from the column's frame change, so it now measures the column, which the row is tied to.

The full local run then found one more: in the floating bar, a project's detail showed the Projects grid behind it, because the Calendar view's hiding of that section also un-hid it.
`DaylightDrillPageSelfTest` caught it, and the section now stays hidden for a project's detail.

One pre-existing defect is left for a follow-up: at 1100pt the card's header has no room for the period's title, and the Agenda pill is clipped.
The card and its CSS are unchanged by this PR, and the old Calendar page had the same width there.

### Verification

- `FM_RUN_SPLIT_SHELL_MODEL_TESTS`: the Calendar row's place, the door's route, tab and landing, the lit row by view name (Board, List and Weekly review light Tasks, Calendar lights Calendar, a tab of that name elsewhere does not), one Go menu item with ⌘0 and the tab back when the row is hidden, and every route landing on its module's tab.
- `FM_RUN_MAIN_SPLIT_SHELL_TESTS`: the calendar button from Hosts lands on Tasks' Calendar view with Tasks' crumb, tabs and header and the Calendar row lit.
  The calendar fills the column under the filter row.
  Board lights Tasks, the Calendar row brings the view back, and the Tasks row returns to Board.
  Overdue set on Board is still the filter on the Calendar: today's task leaves the grid and the late one stays pinned in the tray, and All tasks brings it back.
- `FM_RUN_SHIFT_CALENDAR_TESTS`: the colouring's calendar ids, calendars, legend, tray edges and saved key, and the project and No project chips' contrast on every app theme.
- `FM_RUN_SHIFT_CALENDAR_VIEW_TESTS`: by project the page's legend and chip edges change, and back again, and `taskFilter` takes a task off the grid and out of the tray.
- `FM_RUN_MODULE_TABLE_TESTS`, `FM_RUN_FEATURE_INVENTORY_TESTS`, `FM_RUN_REVIEW2_UX_MODEL_TESTS` and `FM_RUN_NAVIGATION_COHERENCE_TESTS` follow the new table, the inventory rows and the toolbar tooltip, which now names the place through `PlaceName`.
- Two full local runs, because this changes shell structure.
  The first failed three suites, all from this change, and each is fixed above or follows the new routing (`DaylightModuleSelfTest`'s drill header names the page a door lands on).
  The second failed one source guard in `ShellSplitSelfTest` on `Navigator.show`'s parameter name, which is restored, and every suite that reads `Navigator.swift` was re-run after it.
  `swift build -c release` is clean.

Confirmed to catch a regression:

| Injection | What failed |
|---|---|
| `sidebarModule(for:pageTab:)` never returns the door | "Tasks' Calendar view lights tasks", "the Go menu has 2 Calendar items", and four `MainSplitShellSelfTest` checks including the lit row and the Tasks row reopening the Calendar |
| `render()` hands the calendar every task, unfiltered | "with Overdue set on Board the calendar draws ..." and the view suite's filter check |
| `calendarID` ignores the colouring | three colouring checks in `ShiftCalendarSelfTest` and "a task with no project should be drawn in the No project colour" |

### Left out

- PRs 5 to 8 of the plan: the When panel, exceptions, the tray drag and quick add, and completing from the calendar.
- Weekly review's next-week list as a link into Calendar › Week.
- A saved session restores Tasks, not its Calendar view, because the Tasks page does not persist its view.

## Tray drag and quick add (tasks-calendar plan PR 7, `fm/grand-line-calendar-pr7-tray-drag-quickadd`)

PR 2 put the Unscheduled tray in the calendar's web page rather than in AppKit so that a row could be dragged onto the grid through one DOM.
This PR is that drag, the reverse drag (a chip back onto the tray), the quick add in a day, and repeat phrases in the title parser.
It leaves out the rest of the plan's interaction list: dragging a projection and the "Only this / This and following" dialog are PR 6, and the When panel is PR 5.

### What shipped

- **A tray row drags onto the grid.** Rows are HTML5 drag sources.
  The page finds the target under the pointer with the same DOM lookups the drag plugin and Schedule-X use: a month cell (`.sx__month-grid-day`), a time in Week and Day (`.sx__time-grid-day`, a column 24 hours tall, snapped to 15 minutes like the plugin) or the all-day row (`.sx__date-grid-day`).
  A dashed box over the target names the day ("Drop to schedule Mon, 16 Nov") or the slot ("10:00 · Sat, 14 Nov").
  The box is drawn over the grid, never inside a day, so a Schedule-X re-render cannot take it with it.
  A drop posts `place`, and `TaskCalendarController.placeFromTray` writes it through the same path, toast and Undo a chip drop takes.
- **A time slot gives an all-day task its time.** `ShiftCalendarReschedule.apply` keeps an all-day task all-day for a chip drag, which is still right.
  A tray row dropped on a slot is the captain answering "when", so `adoptsTime` lets the slot's time stand.
  A row dropped on a day still keeps whatever time it had.
- **A chip drags onto the tray** and loses its date, its time and its reminder, with Undo.
  The chip's drag belongs to the plugin (HTML5 in the month grid, mouse events in the time grid), so the page only records which movable chip was pressed and where the drag ended.
  `onBeforeEventUpdate` then refuses the plugin's own move of that chip, which the plugin would otherwise also make to the last day the pointer crossed on its way to the tray.
  A repeating task is refused with a toast: its rule is anchored on the due date, and deleting the rule to honour a drop would lose more than the drop asked for.
  A follow-up is refused too, because the tray does not list undated follow-ups, so it would vanish from the calendar.
- **Quick add in a day.** Hovering a month cell shows a + beside its date.
  It opens a title field over the cell, and every keystroke posts `quickAddParse`.
  The native side reads the text with `ShiftDateParser` and answers with pills for the day, the time and the rule (`setQuickAddHint`, matched by a sequence number so an answer to an older keystroke is dropped).
  Return posts `quickAdd`, which adds the task with an Undo that deletes it again.
  Command-Return opens New Task with everything filled in, and Escape closes the field.
  `ShiftCalendarQuickAdd` is the pure half: the cell's day stands in for a missing day phrase, a typed day phrase wins, and a repeat phrase moves the date to the rule's first date on or after the cell.
- **Repeat phrases in the parser.** "every day", "every weekday", "every weekend", "every mon, wed", "every other week", "every 2 weeks on mon", "every month on the 2nd friday", "monthly on the last day", "every 3 months", "yearly" and similar become a `ShiftRecurrence`.
  The returned date is the rule's first occurrence, so "every tue" typed on a Wednesday is due next Tuesday.
  The phrase is blanked out of the text before the day scan runs, or "every wed" would also be read as the day phrase "wed" and land a week late.
  `parse` gained `on day:`, the day the text is being added on, for the quick add.
- **The parser's other callers.** The New Task sheet's title detection now sets Repeat from a repeat phrase, because Save lifts the phrase out of the title and the rule would otherwise be lost.
  Dismissing the detection, or typing the phrase away, puts back the rule Repeat held before, and a rule picked by hand is never overridden.
  The menu-bar quick add saves the rule as well.
  ⌥Space capture, App Intents and the crew's due text still take only the date, as before.

### Decisions

- **The bare adverbs only count at the end of their phrase.** "Weekly review", "Send the monthly report" and "Daily standup notes" are ordinary titles.
  "daily", "weekly", "monthly", "yearly" and "annually" become a rule only when followed by "on …", by nothing, by "at", "@", "from" or "starting", or by a time.
  "every" is explicit and needs no such guard.
- **The tray drop words are back.** PR 2's `checkTrayPayload` asserted the empty state did *not* mention a drag, because the drag was not built yet.
  That check is inverted here, and the tray gains the board's footer, "Drop a chip here to clear its date."
- **No `color-mix` in the stylesheet.** The bundle targets Safari 16, and `color-mix` arrived in 16.2.
  The drop box's wash is a pseudo-element in `--sx-color-primary-container` at reduced opacity.
- **Quick add is in the month grid only.** Week and Day keep the double-click on a slot, which already opens New Task at that time.

### Verification

- `FM_RUN_SHIFT_DATE_PARSER_TESTS` (blocking lane): fourteen repeat phrases with their rule, due date, time and stripped title; "every wed" on a Wednesday starting today; a day phrase beside a rule; six ordinary titles that must not parse; and the `on day:` cases.
  Confirmed to fail with the masking removed (the "every wed" case and seven stripped titles) and with the bare-adverb guard removed (four ordinary titles).
- `FM_RUN_SHIFT_CALENDAR_TESTS` (blocking lane): `checkTrayDropRules` (slot time adopted from the tray but not from a chip, unschedule clearing exactly date, time and reminder, the repeating and finished refusals) and `checkQuickAdd` (the draft, the task and the pills), plus the new bridge entries, messages and page ids.
- `FM_RUN_SHIFT_CALENDAR_VIEW_TESTS` (windowed lane), each read back from the store: a tray row dragged onto a month day, and onto 15:00 in the week view; a month chip and a week-view timed chip dragged onto the tray; a repeating chip refused; and a real + click, typed text, the native pills, and Return adding "Patch notes" on the first Tuesday at 10:00, weekly.
  Confirmed to fail with the `onBeforeEventUpdate` gate removed (five checks: the chip was moved to the day it crossed) and with `adoptsTime` off in `placeFromTray` (the 15:00 case).
  Passed three runs in a row.
- Rendered with `WKWebView.takeSnapshot` in Daylight and Dusk: the month drop box, the tray lit as a target, the + on a hovered day, the quick-add field with its pills, and the week slot box.
  The first render found the month label cut off at "Drop to schedule M…" in a cell narrowed by the tray, so it now wraps to two lines.
  A render taken before Schedule-X's view and theme transitions finish shows a faded, offset grid, so wait a beat before snapping.
- `build-schedule-x-web.sh` regenerated `web/` (and `BUILD-INFO.txt`) from `src/`.
  On this machine its `npm ci` runs through Automic Vault's `av inject`, and the rebuild waits on that approval prompt.
- The local build used `swift build --build-system native`: Swift 6.4's default build system compiles the vendored Metal shaders, and this machine has no Metal toolchain installed.

