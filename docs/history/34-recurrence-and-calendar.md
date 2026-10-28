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
