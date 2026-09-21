# Scratchpad calculator (F9)

The Tools page's tenth tab, built by
`fm/grandline-feature-f9-scratchpad-calculator` - one of three of full review
#3 §8's recommendations the captain picked to build in parallel (F7 and F11
were the other two, in their own worktrees).

The report's own entry:

> **F9 - Scratchpad calculator / unit converter.** A Soulver-style live pad:
> type `3 * 4.5 USD in INR`, `2 weeks from Friday`, `0x1F + 12` and see results
> per line. Pure logic, one Tools tab, huge daily utility. Scope: M.

The captain reviewed a mockup of the pad before it existed, in the published
"Grand Line Futures" artifact (F9's section): twelve live lines with a
right-aligned tabular result column, variables and `that`, and a footer stating
how old the currency rates are. The shipped tab is that mockup, with the
departures stated below.

---

## What shipped

A new `ToolKind.scratchpad`, first in the Tools landing grid - which is also
what turns that page's own subtitle from "9 offline utilities" into "10", the
number the mockup's chrome already showed.

- **The pad** (`ScratchpadPadView`): an editable monospace text view with a
  196pt right-aligned result column beside it, one row per line, tabular
  figures, a hairline between them.
- **Copy all results** in the panel header, and **⌘↩** for the line the caret
  is on. The copied column keeps blank lines blank, so a paste still lines up
  with what is on screen.
- **A footer** naming the currency table's size and date, verbatim from
  `ScratchpadRates.footerLine`, plus the six example expressions the engine
  advertises (`ScratchpadEngine.examples` - kept next to the grammar so the
  claim and the code change in the same commit).
- **Persistence** (`ScratchpadStore`): `scratchpad.json` under Application
  Support, 0600 in a 0700 directory, keyed by tab name, debounced at 500ms and
  flushed on tab close and on quit.

### What the engine understands

Four Foundation-only files, no AppKit:

| File | What is in it |
| --- | --- |
| `ScratchpadUnits.swift` | The dimensions, ~60 units and their aliases, the static currency table |
| `ScratchpadValue.swift` | `ScratchpadQuantity` / `ScratchpadValue`, and every formatting decision |
| `ScratchpadDates.swift` | Weekday words, `next`/`last`, calendar-aware shifting |
| `ScratchpadEngine.swift` | The lexer, the recursive-descent parser, the document API |
| `ScratchpadMath.swift` | Addition, multiplication, division, percentages, conversion, radix |

Arithmetic with precedence and parentheses, hex/binary/octal literals and `as
hex`/`as binary`/`as octal`, percentages (`15% of 2400`, `2400 + 15%`), length,
mass, data (both SI and IEC), duration, temperature, Kubernetes CPU, 44
currencies, rates (`18.50 USD / month`), variables, `that`, `;`-separated
statements, and date phrases (`2 weeks from Friday`, `next tuesday`, `3 days
ago`, `1789977651 as date`, `2026-10-09 - today`).

---

## The decisions worth keeping

**Results are positioned rows, not a second text view.** The obvious build - a
read-only text view holding one result per line - lines up only while no input
line wraps. The moment one does, every result below it is off by a row, which
is the worst failure available to a pad whose job is telling you which answer
belongs to which line. So each result is an `NSTextField` placed against the
input's own layout manager, on the **last visual row** of its logical line.
`ScratchpadPadViewSelfTest.checkResultsTrackWrappedLines` asserts it with a
line long enough to wrap at the width it is rendered at, and asserts that it
really wrapped before asserting anything else.

**And the rows are re-placed on the input's frame change, not in `layout()`.**
Measured, not reasoned: placing them from the pad's own `layout()` runs *before*
the input has its new width, so a wrapped line kept its answer on its first
visual row. Confirmed by removing the observer and watching that case fail by
name, then restoring it.

**A parse failure is silent; a semantic failure is not.** A scratchpad is also
a notepad - "call finance about the renewal" sits on the line above `seats *
seat_price`. So a line that is not an expression at all renders as nothing,
while a line that *is* one and cannot be computed prints its reason ("kg and
seconds are not the same kind of thing"). Both directions are asserted, because
the second is the half that would rot unnoticed.

**Currency rates are static, and the pad says so.** Tools promises "everything
runs locally, nothing leaves this machine", and one line in twelve mentioning a
currency is not a reason to open a socket. The table is hand-maintained in
`ScratchpadRates`, carries its own `asOf`, and the footer prints it - GL-14
applied to a stale rate rather than a failed fetch. To update: edit `perUSD`
and `asOf` in one commit; the suite asserts USD is exactly 1, every rate is
positive and finite, and `asOf` parses, so half an update fails by name.

**Numbers are formatted in one engineering locale, with one borrowing.** A
column mixing `1,539.32 GB` with `92,00 €` is unreadable, so grouping is `,`
and the point is `.` regardless of the machine's locale. Currency borrows only
its own locale's **grouping size**, which is what keeps `₹7,79,020` in lakhs,
and the symbol always goes in front.

**`m` stays metres.** It is a genuine three-way collision - metres, minutes,
millicores - and the rule is that context resolves it, never the token: it is
minutes when what it extends is a duration (`3h 40m + 95m`), millicores when
the word `cpu` follows (`250m cpu`), and metres otherwise. Making it minutes
outright would make `840ms` ambiguous the moment a space slipped in. The
parser carries a one-operand `dimensionHint` for this, set around a sub-parse
and restored immediately.

**A duration with no named unit is rendered the way a human says it** - `1.134
s` under a minute, `5 h 15 min` above one - while an *explicit* conversion is
left exactly as asked (`90 min in h` is `1.5 h`). That is the whole reason
`ScratchpadQuantity.explicitUnit` exists, and it is set only by `in`/`to`/`as`.

**Data auto-scales inside its own family.** An answer that started in GiB stays
binary, one that started in GB stays decimal. Silently crossing between the two
is the most expensive mistake a size calculator can make, and `1.4 TiB in GB`
exists precisely so the crossing is deliberate.

**Pads are keyed by tab name.** Tools tabs are multi-instance and session
restore reopens them by name, so two pads keep two documents, a relaunch puts
each back, and a rename carries the text with it. The map is capped at 30
entries, most recently edited first (GL-35).

---

## Departures from the reviewed mockup

1. **`that * 12 in INR` keeps its `/mo` suffix** (`₹7,79,020/mo`, where the
   mockup drew `₹7,78,900`). The value is a monthly figure and dropping the
   period would make it read as a year's total. The mockup's own arithmetic was
   illustrative rather than computed.
2. **The footer says "a static table … as of 21 Sep 2026", not "rates fetched
   08:12".** Nothing is fetched, and a footer implying otherwise is exactly the
   thing GL-14 exists to prevent.
3. **A pure date carries its year (`9 Oct 2026`); a date with a time in the
   current year does not (`21 Sep, 8:00 AM`).** Both forms appear in the
   mockup; this is the rule that produces both. A computed future date is a
   plan and wants its year; an epoch being read out of a log line does not.

---

## Verification

- `FM_RUN_SCRATCHPAD_TESTS` - the engine and its store, ~190 assertions over
  the lexer, precedence, radix, percentages, every unit family, currency,
  durations, dates, Kubernetes CPU, variables, `that`, the whole reviewed
  mockup pad line for line, the prose/error split, and a real file round trip
  including the 0600 mode and the 30-pad cap. Pure logic, so it guards CI's
  **blocking** lane.
- `FM_RUN_SCRATCHPAD_VIEW_TESTS` - the pad in a real `NSWindow`: one row per
  line and in order, wrapped lines, error colouring, both copy paths, both
  theme registers, a real render sample of the result column (in
  `rep.colorSpace`, indexed in pixels), the tab's persistence/rename/duplicate
  behaviour, and gotcha (13)'s window-cap check. In `NEEDS_SESSION`.
- Both confirmed to catch a real regression rather than merely to pass:
  removing the `m`-means-minutes rule fails `"3h 40m + 95m"` by name, and
  removing the pad's frame observer fails `checkResultsTrackWrappedLines` by
  name. Both were restored and both suites re-run green.
- Full `./Scripts/run-all-tests.sh` before and after.
- **Not verified**: the tab was never opened in a running app. AGENTS.md
  forbids launching a build from a worktree, and this machine grants the
  agent's shell neither Screen Recording nor Accessibility - so every visual
  claim here comes from the off-screen render probe and the measured geometry
  above, not from a screenshot.
