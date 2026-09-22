# Daily review (F20)

Built by `fm/grandline-feature-f20-daily-review-briefing` - one of five of full
review #3 §8's recommendations the captain picked to build in parallel (F21+F24
together, F22 and F23 were the others, each in its own worktree).

The report's own entry:

> **F20 - Daily review and morning briefing for a general user.** The Morning
> Briefing is fleet-shaped; a general-user variant reads Tasks due, follow-ups,
> habits, calendar (EventKit, read-only), reading list, and top sticky notes.
> *Scope:* S.

The captain reviewed a mockup before it existed, in the published "Grand Line
Futures" artifact (F20's section): a full-width card on Overview with a gradient
sun tile, the date as a kicker, one sentence ("Two things are due, and one is
already late."), three columns - due + follow-ups, calendar + habits, board +
reading + a "Not available" block - and a footer with a primary action, a
secondary "Plan the day in Tasks" and the line "Generated locally at 08:30 - no
data left this Mac". The shipped card is that mockup, with the departures stated
below.

---

## What shipped

Four files, and the split between them is the same one F12 already uses:

- **`DailyReviewData.swift`** - the composer. Imports nothing but Foundation.
  Takes `DailyReviewInputs` (six sections) and returns `DailyReviewDigest`
  (every string the card paints, already formatted). No store, no view, no
  EventKit, so the whole of "what does the card say" is assertable with no
  window.
- **`DailyReviewCalendar.swift`** - the only file in the app that imports
  EventKit, behind a `DailyReviewCalendarReading` protocol.
- **`DailyReviewCard.swift`** - the render. Three equal columns, two vertical
  rules, a footer, and no date maths or branching on availability.
- **`FleetController`** reads the six sources and renders, directly under F12's
  briefing card. `AppShellController` hands it the sticky-board and reading-list
  stores after it has built them (`attachDailyReviewSources`).

Plus a Settings card ("Daily review", two toggles), three `AppSettings` keys,
and `NSCalendarsUsageDescription` / `NSCalendarsFullAccessUsageDescription` in
both the packaged app's and the probe app's `Info.plist`.

### Two cards, not one longer one

F12 answers "what does the fleet need from me" - crew tasks, the PR queue, fork
drift, tool updates, quota. Every one of those is a supervision signal and none
is about the captain's own day. They share the *shape* of a card and nothing
else, so F20 reuses F12's conventions and none of its data:

- `MorningBriefing.dayKey` is reused rather than re-derived, so the two cards
  turn over at the same midnight. A second definition of "today" is exactly how
  two cards on one page end up disagreeing at 00:00.
- The composer/card split, for the same reason F12 has it.
- The dismiss affordance, with the same "gone for the rest of today, back
  tomorrow" behaviour.

**The AI layer is deliberately not reused. There is no `claude -p` call here at
all.** The card is an aggregation of local records, cheap enough to recompute on
every appearance, and the mockup's own footer is a promise that only holds if
nothing leaves the machine.

### GL-14 is the feature, not a detail of it

Every section is a `DailyReviewAvailability<T>` - `.available(T)` or
`.unavailable(reason)` - never a plain array. There is no third "empty" case on
purpose: an empty array is `available([])` and reads as "nothing is due today",
which is a different sentence from "we could not read your tasks".

An unavailable section renders twice, and only one of the two carries the
reason:

- in its own column, as a one-line `not available - see below`, so the column
  keeps its shape; and
- in the third column's **"Not available"** block, as `<Section> - <reason>`.

The reason lives in exactly one place. A reason repeated in two places is a
reason that will eventually disagree with itself.

The live gaps as shipped today:

| Section | State on a normal machine | Reason shown |
|---|---|---|
| Habits | unavailable | "no habits are tracked yet - habit streaks aren't part of this build" |
| Calendar | unavailable until the captain connects it | "the calendar column is off - turn it on to see today's events" |
| Tasks / Follow-ups | available | a store in its GL-01 failed-load state yields "your tasks could not be read - a file in the Tasks store failed to parse" |
| Sticky board / Reading list | available | same shape, per store |

### Habits, which have not shipped

F8 (habits and streaks) is in the same §8 list and was not built. The honest
rendering of that is not an empty section and not a hidden one - it is a stated
gap, exactly like a calendar nobody granted access to.

`DailyReviewHabits.read()` is the one function to change the day F8 lands:
return `.available(rows)` from whatever store it introduces and the composer,
the card and both suites already handle it. `DailyReviewSelfTest` asserts the
available path today, with fabricated rows, for that reason.

### The calendar is read-only, and that is a property of the file

`DailyReviewCalendar.swift` never calls `save`, `remove`, `commit`,
`saveCalendar` or `removeCalendar`, never constructs an `EKEvent`, and hands out
`DailyReviewEventRow` (strings) rather than `EKEvent`s - so no caller can reach
an event object through the daily review even by accident.

`DailyReviewSelfTest.checkCalendarSourceIsReadOnly` is the guard, and a source
guard is the *only* available shape: proving "this never writes to your
calendar" behaviourally would mean writing to a real calendar to see whether it
happened. It also asserts that this is the only file in the app importing
EventKit, so a second, unreviewed calendar path cannot appear quietly. Both
halves assert their own discriminating power first (the file really does
`import EventKit` and really does call `events(matching:)`), so a rename cannot
make the check pass vacuously.

Three access rules that are not obvious:

1. **The card never prompts on its own.** The permission request is behind a
   real click on "Show today's calendar", in the "Not available" block. A
   briefing card that fired a system prompt on the first visit to Overview
   would be the exact surprise F12's opt-in exists to avoid.
2. **An unbundled build refuses to ask.** TCC kills a process that requests
   calendar access with no usage description in its `Info.plist`, and
   `.build/debug/FirstmateCockpit` - every self-test and every `swift build`
   dev run - has no `Info.plist` at all. `canPrompt` checks for the key; with
   it missing, `requestAccess` logs and returns instead of prompting, and the
   card does not offer the button.
3. **macOS 14's write-only grant maps to "not available", not to
   "authorized".** This feature only reads, so a write-only grant is useless to
   it and says so rather than rendering an empty day.

### On by default, unlike F12

`dailyReviewEnabled` defaults to **on**; `morningBriefingEnabled` defaults to
off. That is not an inconsistency. F12 is off by default because it makes a
`claude -p` call, which needs the network, the captain's own Claude
authentication and quota - there is something to consent to before it runs. F20
makes no call at all. The one part of it that does need consent, the calendar,
has its own flag and is off.

### Caps are stated, never silent

Each column holds a handful of rows (5 due tasks, 3 follow-ups, 4 events, 3
stickies). An overflow is a count on the digest and renders as "+3 more in
Tasks" - the same rule `HomeCanvasController.fillBriefing` already follows for
F12's clause list.

**The sentence at the top counts the day, not the column.** With 8 tasks and 6
follow-ups due it reads "14 things are due", while the column shows five rows
and says so. That is why the cap is kept out of the headline.

---

## Departures from the mockup

1. **The header's title is the sentence; the date is the subtitle.** The mockup
   draws the date above the sentence. `HelmCard`'s structured header is
   title-then-subtitle and owns both fonts, and a page must not reach in and
   restyle a component's chrome. The sentence is the thing being read, so it
   takes the title slot.
2. **No primary action when nothing is due.** The mockup's button names a
   specific task ("Start on the TLS renewal"). With nothing due there is no task
   to name, so the footer keeps only "Plan the day in Tasks" rather than
   showing a disabled button that says nothing.
3. **The "Not available" block holds every gap**, rather than only the one the
   mockup happened to draw (weather, which this app does not read). The mockup's
   own closing note is that naming the gap is the point; this is that rule
   applied to all six sections.
4. **Rows are not clickable.** GL-16 requires a clickable row to be a
   `HoverHighlightView` carrying its own role, label and focus ring. Six kinds
   of row would have meant six of those for a card whose navigation the footer
   already covers, so the rows are text and the footer is the way out.

---

## Layout, and the three gotchas this card is shaped around

- **gotcha (13)** - the three columns are tied equal-width at
  `HelmDaylightPriority.contentTie` (499), never higher. The card spans the
  page, which is exactly the shape that caps a window.
- **gotcha (12)** - the column stacks use `setHuggingPriority` /
  `setClippingResistancePriority` (the **stack**-level APIs), not the content
  ones, which are no-ops on a view with no intrinsic size. The footer's spacer
  gets a real low-priority `width == 0` for the same reason.
- **gotcha (5)** - every label in a column is `.defaultLow` compression
  resistance and truncates, so a long task title yields rather than pushing the
  card wider.
- **gotcha (16)** - each column's content is pinned `top ==` and `bottom <=` to
  its container, which makes the container at least as tall as its content
  rather than leaving its height to be picked.

One measurement worth recording, taken while confirming the suite catches a
real regression: **a horizontal `NSStackView` does stretch an arranged subview
with no intrinsic height to the row's full height**, whatever its `alignment`.
Removing both column dividers' bottom pins, and then switching the row to
`.centerY`, left them at the full 246pt in all three cases. The pins are kept
anyway - that stretching is undocumented behaviour a layout should not depend
on - but the file no longer claims they are load-bearing.

---

## Verification

Two suites, split by AGENTS.md's own rule (the test is what a suite asserts,
never what it imports):

- **`FM_RUN_DAILY_REVIEW_TESTS`** - pure logic, so it guards CI's **blocking**
  lane. The composer over a fabricated 21 September morning, the sentence's
  number agreement, every one of the six sections unavailable one at a time,
  the caps, the sticky/reading rules, the day key, and the read-only source
  guard.
- **`FM_RUN_DAILY_REVIEW_VIEW_TESTS`** - window-backed, in `NEEDS_SESSION`. The
  real `FleetController` in a real off-screen window over scratch stores:
  what each column actually paints, the columns' real laid-out widths, the
  dividers' heights, the theme repaint, the calendar button's four states, and
  dismissal.

The view suite assigns `window.contentView` rather than
`contentViewController`, deliberately: that keeps AppKit's appearance
notifications out of it, so `viewWillAppear` never fires and the suite never
triggers the page's real fleet refresh (which shells out). The card is rendered
through the same function appearance would have called.

It saves and restores the theme **and** F20's three `AppSettings` keys, for the
reason AGENTS.md's "The self-test suite is not hermetic" section gives - they
live in the same real `UserDefaults` domain every other suite reads.

### Confirmed to catch a real regression

Each injection was made by copying the file aside first and restoring from that
copy afterwards - never `git stash`, never `git checkout --`.

| Injection | Result |
| --- | --- |
| `DailyReviewHabits.read()` returns `.available([])` (the silent-omission bug) | `FM_RUN_DAILY_REVIEW_TESTS` fails 3 named checks, including "the habits section is a stated gap rather than a silent omission" |
| a required `height == 1` on one column divider | view suite fails "each column divider should span its row, got [1.0, 1.0]" and "the card should have a real height, got 108.0" |
| a required `width >= 900` on the first column (a floor of the kind gotcha (13) is about) | view suite fails "the three columns should be equal width, got [900.0, 160.0, 190.0]" and "the card should have yielded rather than overflowed, got 966.0" |
| the same floor at 420pt | fails the equal-width check only - the window still held 760pt, because this card lives inside a scroll view and overflows the page rather than pressuring the window |

Two real defects the suites found while being written, both fixed:

1. **`overdueCount` counted overdue tasks and not overdue follow-ups**, so a
   morning with a two-day-old follow-up read "Four things are due, and one is
   already late" when two were. The count is now taken across everything
   pending and late, and across all of it rather than only the rows that fit
   the column.
2. The first draft of the "Not available" block drew each gap **twice** - once
   in its own column with the reason and once in the block with it. Fixed to
   one home for the reason before it shipped.

### What was not verified

- **The calendar column against a real calendar.** The suites drive a stub, and
  the read path itself (`EKEventStore.predicateForEvents` ->
  `events(matching:)`) is not exercised: the agent shell's binary has no
  `Info.plist`, so it cannot be granted access, and a CI runner has no calendar
  either. What is asserted is everything either side of that call - the four
  access states, the gap wording, the row mapping's pure parts
  (`hex(from:)`), and that the file cannot write.
- **No screenshot.** This repo has no Screen Recording grant (AGENTS.md's
  "Verifying native UI bugs" section); the geometry above is read back from a
  real layout pass in a real `NSWindow`, which is this project's substitute.

**Recommended manual check:** open Overview in the packaged app, press "Show
today's calendar" and grant access, and confirm today's events appear with
their own calendar colours. Then dismiss the card and re-visit Overview - it
should stay gone until tomorrow.
