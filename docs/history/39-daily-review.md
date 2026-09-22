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
  stores after it has built them (`attachDailyReviewSources`). **This page was
  the wrong host, and a later task added the right one** - see "The placement
  correction, and the Overview page" at the bottom of this file. Fleet still
  carries the card; `DailyOverviewController` is now its primary home.

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

**Recommended manual check:** open the Overview page in the packaged app
(the leftmost pill - see the placement correction below), press "Show
today's calendar" and grant access, and confirm today's events appear with
their own calendar colours. Then dismiss the card and re-visit Overview - it
should stay gone until tomorrow.

---

## The placement correction, and the Overview page (`fm/grandline-overview-page-daily-review`)

F20's spec above says "a full-width card on Overview", and the implementation
put it on `RailDestination.overview`. **That was the wrong page**, and nobody
noticed for a release: `.overview` is titled **"Fleet"** in the running app, and
the landing page the captain calls Overview is `.homeCanvas` / "Home". The
captain reported the card as missing; it was rendering correctly, on a page he
was not looking at.

`data/grandline-daily-review-card-not-showing/report.md` (firstmate's own repo)
is the scout investigation that established this, with a real off-screen probe
of both controllers:

```
== HOME (RailDestination.homeCanvas, title="Home") ==
  NO DailyReviewCard / MorningBriefingCard anywhere in this view tree
== FLEET (RailDestination.overview, title="Fleet") ==
  DailyReviewCard  isHidden=false frame=(0.0, 227.0, 1152.0, 333.0) window=true
```

No gating bug, no stale `UserDefaults`, no stale build, no layout gotcha - a
naming collision, and one that had already been half-corrected once (review #3
§7 renamed the canvas's first pill from "Overview" to "Home" precisely because
three names were in use for two things).

### What the captain asked for

A **new, sixth top-level tab** called "Overview", leftmost, carrying the daily
review as a page of its own - not a move, and with "Home" and its module grid
left exactly as they are.

### What shipped

- **`DaylightSpace.dailyOverview`**, declared first, so it is the leftmost pill
  and takes ⌘1 (Home moved to ⌘2 and keeps its own ⌘0 in the Go menu).
- **`DaylightSpace.destination`** - the one new seam. A space pill was always a
  *filter* over the home canvas's module grid; this property lets one be a page
  instead, and `AppShellController.selectSpace` asks it rather than assuming the
  canvas. `DaylightModule.space(forDestination:)` reads the same table, so a
  ⌘K jump or a deep link to the page lights the right pill. Five of the six
  spaces return `nil` and behave exactly as before; `filtersCanvas` is what
  every canvas-shaped loop (and every canvas-shaped test sweep) filters on, so
  nothing had to name the new case.
- **`RailDestination.dailyOverview`** + a slot + `DailyOverviewController`,
  which is a **host, not a rebuild**: the same `DailyReviewCard`, the same
  `DailyReviewComposer.digest(from:)`, the same two gates, the same
  `attachDailyReviewSources` wiring, the same `dailyReviewCalendar` seam.
  `renderDailyReview()` was ported from `FleetController` rather than
  reimplemented.
- Two things the page needs that a card in a stack does not: a **viewport-height
  minimum** so the card fills the page (see below), and a **real empty state**
  for the two gated cases - a dismissed day and the feature turned off - because
  a destination that renders nothing is a dead end where a hidden card is just a
  shorter dashboard.

### Why the case is named `dailyOverview`

Because `.overview` already means two different things depending on which enum
you are reading, and that ambiguity is the entire cause of this task. A third
`overview` would have been worse than the two that already existed. The
user-facing name is still "Overview" - it is the word the captain uses.

`NavigationCoherenceSelfTest`'s "nothing says Overview any more" source guard
was **rewritten rather than deleted**: it now asserts the word names exactly one
thing, is declared in exactly the two files that declare it
(`DaylightSpace.swift`, `RailDestination.swift`) and appears in no other source
file. The rule it enforces changed; the protection did not.

### Fleet keeps its copy - and why that is not the duplication the component index forbids

The scout report flagged that two surfaces rendering one digest is something
this repo argues against. The decision here is to **keep** Fleet's card, and the
reasoning is that the component index's rule is about duplicate
*implementations*, not duplicate *placements*: there is still exactly one
`DailyReviewCard`, one composer, one dismissal key - dismissing on either page
puts the day away on both, because both read
`AppSettings.shared.dailyReviewDismissedDay`. Against that:

- The captain asked for an addition, explicitly, after being asked whether this
  should replace an existing tab.
- Removing shipped UI he has not complained about, in the same change that adds
  a page, is two decisions where one was asked for.
- `DailyReviewViewSelfTest.checkFleetStillHostsIt` pins it, so dropping Fleet's
  copy later fails by name and is a deliberate act rather than a silent one.

If it does come out, `DailyOverviewController` changes not at all.

### The page fills its own height

Rendered off-screen at 1400x900, the first version put a 325pt card at the top
of the page with 575pt of bare background under it - which reads as a card that
lost its dashboard rather than as a destination. A **minimum** height on the
content stack, tied to the scroll view's clip view at `HelmDaylightPriority
.contentTie` (499), fills the viewport: the footer's actions sit on the bottom
of the page and the two column rules run its height. A minimum rather than an
equality so a genuinely taller card still scrolls, and 499 rather than anything
higher because gotcha (13) is exactly this shape - a full-page content
constraint over 500 resizes the window. The suite asserts both directions: the
card fills the page, and a window shrunk to 760x520 really shrinks.

### Verification

Baseline before the change: **194 passed, 0 failed** (`run-all-tests.sh`, full).

The window-backed suite moved host: `DailyReviewViewSelfTest` now mounts
`DailyOverviewController` for every case, through a test-only
`DailyReviewHosting` protocol over the debug hooks both controllers already had
- which is what let the whole file change page without rewriting an assertion.

| Injection | Result |
| --- | --- |
| `showEmptyState` leaves the empty state hidden | view suite fails "the page says so rather than rendering an empty destination" and the feature-off case |
| the card's width tie replaced by `width == 400` | fails "the card should fill the page inside its gutter - expected 1252.0, got 400.0" (and the footer-rule check) |
| the viewport-height minimum deactivated | fails "the card should fill the page's height too - got 352.0 on a 900.0pt page" |
| `DaylightSpace.dailyOverview.destination` returns `nil` | `FM_RUN_DAYLIGHT_MODULE_TESTS` fails "space dailyOverview has no modules at all"; `FM_RUN_NAVIGATION_COHERENCE_TESTS` fails "the pill really opens that page" |
| `selectSpace`'s destination branch removed (the pill goes back to filtering the canvas) | module suite fails "selecting dailyOverview did not mount dailyOverview", "landed on the canvas" and the drill-header title check |
| `RailDestination.dailyOverview.title` renamed "Daily Review" | coherence suite fails three named checks, including the two-declaration-sites guard |

One real finding the full suite turned up, and it is a harness correction rather
than a product bug: `AppShellBodyWidthSelfTest
.moduleCardCountDoesNotAccumulateOverALongSession` failed with "1 extra
HelmGradientTile, 1 extra HoverHighlightView, and 3 extra ThemeManager
observers ... constant across all 5 checkpoints - a bounded, one-time artifact,
not a growing leak". That is exactly what it was: the case warmed up with one
space round trip before reading its baseline, and a pill that opens a
*destination* mounts that destination lazily and permanently (GL-37) on its
first selection - which now happened after the baseline. The warm-up is a full
sweep of `DaylightSpace.allCases` now, so the baseline is a real steady state;
the same class of correction as the `autoreleasepool` one recorded in that
file's own header. With it, 300 switches leave zero excess.

Every injection was made by copying the file aside and restoring from that copy
- never `git stash`, never `git checkout --`.

**What was not verified:** no screenshot of the real running app (this repo has
no Screen Recording grant); the page's appearance is an off-screen
`cacheDisplay` render in both registers, read back as a PNG, per AGENTS.md's
"Verifying native UI bugs" convention. The probe was reverted before commit.

**Recommended manual check:** click the leftmost "Overview" pill (or ⌘1), and
confirm the page carries the digest full-bleed with its footer at the bottom.
Dismiss it and confirm the page says so rather than going blank, then check
Fleet shows the same dismissal.

---

## The Overview page's layout, corrected (`fm/grandline-overview-layout-fix-gmail-settings`)

The captain sent a screenshot of the page above, and five things were wrong with
it. Four were in the **shell around the page** rather than in
`DailyOverviewController`, which is why the page's own suite was green
throughout.

**The tab strip was gone.** `AppShellController.show` asked
`slot.id == .homeCanvas` to decide whether the bar keeps its wordmark and space
pills, and everything else got the drill cluster - which *hides the pills*
(`DaylightBarController.setDrillContext`). So the new Overview tab, which is
opened by a space pill, rendered with a back arrow and no tab strip at all: a
pill that hid the pill strip the moment you pressed it. Measured in an
off-screen probe before the fix: `drillNavIsHidden = false`,
`pillsAreHidden = true`.

The fix is one question changed. `DaylightSpace.owning(destination:)` is the
reverse of the `destination` table #441 added, and `show(_:)` now asks
"is this page some space's own page, or the canvas" rather than naming the
canvas. A second such page is one line in that enum and none in the shell -
which is what the `destination` seam was for in the first place.

The consequence worth recording: **a top-level page has no drill header**, so
`DailyOverviewController`'s `DaylightDrillActions` conformance and its
`onDrillSubtitleChanged` wiring were dead. Both are gone. The line it computed
is kept as `pageSummary` and asserted against what the card is actually
painting, rather than against a header nobody renders.

**A terminal session strip drew over the review card.** `SESSIONS / Prod
Bastion`, on a page with nothing to do with terminals. The strip was gated on
"is there a live session" alone, which is how `fm/grandline-session-switcher`
built it ("reachable from anywhere"). `RailDestination.showsSessionStrip` is
the second input, and `.dailyOverview` is the one page it is off on - a table
rather than a `dest == .dailyOverview` in the shell, so a second such page is
one line. Everywhere else the strip is unchanged.

**The card sat 2pt inside the bar above it.** The Daylight bar is a floating
panel inset `DaylightBarController.sideMargin` (22) from the window; the page
used `HelmMetrics.pageGutter` (24). Measured at 1220pt: bar 22..1198, card
24..1196. Four points on a 1220pt page, and the captain saw it at once, because
this is the only page in the app whose single element's edge is vertically
adjacent to the bar's. Every other page keeps `pageGutter`.

**The dead zone below the card was the card.** #441 added a viewport-height
minimum at `contentTie` so the card "fills the page rather than floating at the
top of it". What that actually produces is in the captain's screenshot: a 317pt
card stretched to 592pt, its three column rules running down through ~275pt of
empty background and its footer parked on the bottom edge of the window. The
constraint is gone. A card sizes to its content, and what is under it is page
background - which is what the approved mockup shows and what every other short
page here already does.

**"Settings" and "Dismiss" were a gear and an X.** Two
`HelmPageToolbar.iconButton`s. A bare X on a card whose whole point is "here is
your day" reads as closing the page rather than as putting today's review away,
and a gear says nothing about *which* settings it opens. Two labelled
`HelmButton`s now, on the one card both hosts share.

### Verification

Root-caused with a real off-screen probe rather than by reading the code, per
AGENTS.md's "Verifying native UI bugs" convention - the measurements above are
that probe's. After: pills back, card 1468x289 at x=22 against a 289pt fitting
size, document 341pt against an 824pt viewport. Rendered at 1512pt in Dusk and
Catppuccin Latte and read back; both match the mockup's chrome. The probe was
reverted before commit.

Five injections confirmed the new checks catch real regressions: reverting
`isTopLevel` to the canvas-only test fails the three bar-chrome checks by name;
`showsSessionStrip` always-true fails the three strip checks;
the viewport fill back fails the card-height check (848 against a 352 fitting
size); `pageGutter` back fails the width check by exactly 4pt; the icon buttons
back fails the labelled-button check with `["", ""]`.

`DaylightModuleSelfTest`'s drill sweep asserted the old rule and had to change
with it: it now excludes every top-level space page from the drill loop and
asserts the *opposite* property for them in a loop of its own, so both
directions are still covered. Its "which page did the pill open" check moved
off the drill header's title (a top-level page has none) onto
`currentContextTitle`, which the window title and the Recents list already read.
