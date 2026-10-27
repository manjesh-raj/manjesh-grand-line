# Vendored Schedule-X (the Tasks page's Calendar)

Source: the open-source [Schedule-X](https://github.com/schedule-x/schedule-x) packages from npm, bundled with esbuild.
`web/BUILD-INFO.txt` records the exact versions the committed bundle was built from.
Every bundled package is MIT, except `temporal-spec` (ISC, type definitions only).
Their licence texts ship inside the bundle as `web/THIRD-PARTY-LICENSES.txt`, which the build script generates from the installed packages.

## Why Schedule-X, and why vendored

**Schedule-X, specifically.** This was the captain's choice, after the open-source calendar options review proposed it as the most modern option for what was then Tasks › Calendar.
The calendar is its own sidebar page now (`TaskCalendarController`).
It gives month, week, day and list (Agenda) views, today's highlight, a now-line and drag and drop, and it themes itself through CSS variables, which is what lets it follow the app theme.

**Embedded, not reimplemented.** The previous calendar was a hand-drawn AppKit month and week grid.
`ShiftCalendarViews.swift` keeps everything that is about tasks: which tasks land on which day, what a projected repeat is, what a drop may change, and the palette.
The page only draws.

**Vendored, not fetched.** Same posture as the Monaco and Excalidraw bundles: the built bundle is committed, the app loads it with `loadFileURL`, and nothing touches npm or the network at app-build time or at runtime.
The page's CSP has `connect-src 'none'`, and `FM_RUN_SHIFT_CALENDAR_TESTS` reads that policy out of the committed bytes.

## Free and open source only

Schedule-X also sells premium plugins under the `@sx-premium` scope.
None of them is used, and the build script refuses to bundle any `@sx-premium` package, or any runtime package whose licence is not on a short allow-list.
`FM_RUN_SHIFT_CALENDAR_TESTS` asserts the same against the committed manifest and lockfile.

**Drag and drop is the one feature that needed a decision.**
Schedule-X 4.0.0 removed the drag-and-drop and resize packages from the open-source repository and made them paid.
The 4.x core still calls a drag plugin through a public three-method interface (`startTimeGridDrag`, `startDateGridDrag`, `startMonthGridDrag`).
`@schedule-x/drag-and-drop@3.7.3` is the last MIT release of the official plugin, published one day before 4.0.0, and it implements exactly that interface under its 3.x names (`create*DragHandler`).
`src/task-calendar.js` adapts the three names and nothing else.
So the core is the current open-source release, and the drag plugin is the last open-source one.

The trade-off, stated plainly: the drag plugin will not receive fixes, and a future core release could change something the 3.7.3 handlers read.
`FM_RUN_SHIFT_CALENDAR_VIEW_TESTS` drives a real drag in the month grid and in the week view's time grid and reads the result back from the task store, so that kind of break fails a test rather than shipping.
Resize is not used at all: a task has a due time but no duration.

## Layout

| Path | What it is |
| --- | --- |
| `src/package.json`, `src/package-lock.json` | The pinned dependency set. Installed only by the build script, with `npm ci`. |
| `src/task-calendar.js` | Hand-written entry point: mounts the calendar, adapts the drag plugin, drives the card's own header (previous and next, the period's title, Today, the view pills), the weekday row and the legend, and exposes `window.GrandLineTaskCalendar`, the bridge `ShiftCalendarWebView` calls. |
| `src/task-calendar.css` | Hand-written layer over the default theme: the captain's raised card, a raised cell per day drawn inside the day (never as a gap, which the drag plugin would see as nowhere), dimmed days outside the month, today as a pill, chips with an accent edge, the agenda's rows, projections drawn faint, finished tasks struck through, and the now-line and today's weekday in theme colours. Schedule-X's own header is hidden. |
| `src/index.html` | Hand-written page shell: the CSP, the card's header, weekday row and legend, and the one classic `<script>` tag. |
| `web/` | **Generated and committed.** The script, the stylesheet, the page, `THIRD-PARTY-LICENSES.txt` and `BUILD-INFO.txt`. |

## Rebuilding

```sh
native/Scripts/build-schedule-x-web.sh          # needs node/npm + network, build-time only
native/Scripts/build-schedule-x-web.sh --check  # rebuild into a scratch dir and diff
```

Run it after editing anything in `src/`, or after bumping a version in `src/package.json` (then `npm install --package-lock-only` in `src/` first), and commit the regenerated `web/`.
`BUILD-INFO.txt` records a SHA-256 of every shipped file, and `FM_RUN_SHIFT_CALENDAR_TESTS` fails on a hand edit or an unlisted file.

## Upgrading

Bump the version in `src/package.json`, rebuild, and check five things, because each one fails silently:

1. **The drag plugin still works.** Run `FM_RUN_SHIFT_CALENDAR_VIEW_TESTS=1 .build/debug/GrandLine`. It drags in the month grid and the week view and reads the task store.
2. **The CSS variable names still exist.** `ShiftCalendarPalette.requiredVariables` names every `--sx-color-*` role the palette sets. A renamed role leaves Schedule-X's default purple behind.
3. **The callbacks still exist.** `task-calendar.js` uses `onEventClick`, `onDoubleClickDate`, `onDoubleClickDateTime`, `onRangeUpdate`, `onRender`, `onSelectedDateUpdate`, `onBeforeEventUpdate` and `onEventUpdate`, and the scroll controller's `scrollTo`.
4. **The locale rule still holds.** Schedule-X throws on a locale that is not `ll-RR`, which is why `ShiftCalendarPayload.scheduleXLocale` normalises it.
5. **The classes the stylesheet targets still exist.** `task-calendar.css` draws the card over `.sx__month-grid-day`, `.is-leading-or-trailing`, `.sx__month-grid-day__header-date.sx__is-today`, `.sx__month-grid-event`, `.sx__calendar-header` and the `.sx__list-*` rows. A renamed class leaves the default look behind with no error; `FM_RUN_SHIFT_CALENDAR_VIEW_TESTS` reads the cells, the dimmed days, the today pill and the hidden header back from the page, and the tour lab's `calendar` verb renders it.
