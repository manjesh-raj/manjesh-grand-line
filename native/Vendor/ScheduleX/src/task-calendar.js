// Grand Line - the Tasks page's calendar, as a Schedule-X page.
//
// This is the hand-written half of the bundle. `native/Scripts/build-schedule-x-web.sh`
// bundles it with the pinned packages in `package.json` into one classic IIFE,
// and `ShiftCalendarWebView.swift` is the native half of the bridge below.
//
// What this page owns, and what it does not:
//
//   - It draws. Month, week, day and agenda views, today's highlight, the
//     now-line, and the drag of an event to a new day or time are all
//     Schedule-X's own. The card around them - the round previous and next
//     buttons, the period's title, the view pills, the weekday row and the
//     legend - is this file's, because Schedule-X's own header is a Today
//     button, a view menu and a date field rather than the captain's design.
//   - It does not own a single record. Every event (a task or a follow-up)
//     arrives from the native side
//     (`setEvents`), and a drop only *asks* the native side to move the task
//     (`move`). The store decides; the native side then pushes the new events
//     back. A drop the store refuses is undone by that same push, so this page
//     never shows a position the store does not hold.
//
// The palette is the app theme's, never Schedule-X's own Material purple:
// `setTheme` writes the native side's resolved colours over the theme's CSS
// variables (see `applyTheme`).

import 'temporal-polyfill/global'
import {
  createCalendar,
  createViewDay,
  createViewList,
  createViewMonthGrid,
  createViewWeek,
  toDateString,
} from '@schedule-x/calendar'
import { createCalendarControlsPlugin } from '@schedule-x/calendar-controls'
import { createCurrentTimePlugin } from '@schedule-x/current-time'
import { createScrollControllerPlugin } from '@schedule-x/scroll-controller'
// The last MIT release of the official plugin. Schedule-X 4 moved drag and
// drop out of the open-source repository into a paid package; the core still
// calls a `dragAndDrop` plugin through the same three-method interface, and
// this release implements exactly that interface. See ../README.md.
import { createDragAndDropPlugin } from '@schedule-x/drag-and-drop'
import '@schedule-x/theme-default/dist/index.css'
import './task-calendar.css'

const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.grandlineTaskCalendar

function post(message) {
  if (handler) handler.postMessage(message)
}

function reply(callID, ok, extra) {
  post(Object.assign({ type: 'reply', callID, ok }, extra || {}))
}

window.addEventListener('error', (event) => {
  post({ type: 'error', message: String((event && event.message) || 'script error') })
})
window.addEventListener('unhandledrejection', (event) => {
  post({ type: 'error', message: String((event && event.reason) || 'unhandled rejection') })
})

// MARK: Dates
//
// The native side speaks "YYYY-MM-DD" for a day and "YYYY-MM-DD HH:MM" for a
// timed task, in the captain's own time zone - the same two shapes
// `ShiftTask.dueDate` / `dueTime` are stored in.

let timeZone = 'UTC'

function toTemporal(text) {
  if (text.length <= 10) return Temporal.PlainDate.from(text)
  return Temporal.PlainDateTime.from(text.replace(' ', 'T')).toZonedDateTime(timeZone)
}

function pad(n) {
  return String(n).padStart(2, '0')
}

function describe(value) {
  if (value instanceof Temporal.ZonedDateTime) {
    return { day: toDateString(value), time: pad(value.hour) + ':' + pad(value.minute) }
  }
  return { day: toDateString(value), time: null }
}

// MARK: Events

// Event id -> the record behind it, for events the store lets move. `kind`
// is "task" or "followUp"; the native side routes on it.
const movable = new Map()

function toCalendarEvent(item) {
  const classes = []
  if (item.projected) classes.push('gl-projected')
  if (item.completed) classes.push('gl-completed')
  if (item.allDay) classes.push('gl-all-day')
  if (item.movable) movable.set(item.id, { id: item.taskID, kind: item.kind || 'task' })
  return {
    id: item.id,
    taskID: item.taskID,
    kind: item.kind || 'task',
    title: item.title,
    start: toTemporal(item.start),
    end: toTemporal(item.end),
    calendarId: item.calendarId,
    _options: {
      disableDND: !item.movable,
      disableResize: true,
      additionalClasses: classes,
    },
  }
}

// MARK: The calendar

// Schedule-X 4.0.1 renamed the three hooks the core calls on a drag plugin
// (`create*DragHandler` became `start*Drag`); the arguments are unchanged, and
// the 3.7.3 handlers they construct register their own listeners. So the
// adapter is a rename and nothing more. `ShiftCalendarViewSelfTest` drives a
// real drag in all three grids, which is what catches a later core release
// moving anything the handlers read.
function adaptDragAndDrop(plugin) {
  plugin.startTimeGridDrag = (dependencies, dayBounds) => plugin.createTimeGridDragHandler(dependencies, dayBounds)
  plugin.startDateGridDrag = (dependencies) => plugin.createDateGridDragHandler(dependencies)
  plugin.startMonthGridDrag = (calendarEvent, $app) => plugin.createMonthGridDragHandler(calendarEvent, $app)
  return plugin
}

const controls = createCalendarControlsPlugin()
const currentTime = createCurrentTimePlugin({ fullWeekWidth: false })
// Week and day views draw all 24 hours (a task due at 23:30 must still have
// somewhere to be), and open scrolled to the working morning rather than to
// midnight.
const scrollController = createScrollControllerPlugin({ initialScroll: '07:50' })
const dragAndDrop = adaptDragAndDrop(createDragAndDropPlugin(15))
let calendar = null

function mount(config) {
  timeZone = config.timeZone || 'UTC'
  calendar = createCalendar(
    {
      views: [createViewMonthGrid(), createViewWeek(), createViewDay(), createViewList()],
      defaultView: config.view || 'month-grid',
      locale: config.locale || 'en-US',
      firstDayOfWeek: config.firstDayOfWeek || 1,
      timezone: timeZone,
      isDark: !!config.dark,
      calendars: config.calendars || {},
      events: [],
      monthGridOptions: { nEventsPerDay: 4 },
      weekOptions: { gridHeight: 1200, eventOverlap: false },
      skipValidation: true,
      callbacks: {
        onEventClick(event) {
          post({ type: 'open', taskID: event.taskID, kind: event.kind || 'task' })
        },
        onDoubleClickDate(date) {
          post({ type: 'add', day: toDateString(date), time: null })
        },
        onDoubleClickDateTime(dateTime) {
          post({ type: 'add', day: toDateString(dateTime), time: pad(dateTime.hour) + ':' + pad(dateTime.minute) })
        },
        onRangeUpdate(range) {
          postRange(range)
        },
        onRender($app) {
          postRange($app.calendarState.range.value)
        },
        // Clicking a day's number in the month grid opens that day; the
        // header has to follow a view change it did not make itself.
        onSelectedDateUpdate() {
          refreshHeader()
        },
        // The plugin already refuses to start a drag on `disableDND`; this is
        // the second gate, so a projection or a completed task can never
        // reach `move` whatever the DOM was persuaded to do.
        onBeforeEventUpdate(oldEvent) {
          return movable.has(oldEvent.id)
        },
        onEventUpdate(event) {
          const record = movable.get(event.id)
          if (!record) return
          const at = describe(event.start)
          post({ type: 'move', taskID: record.id, kind: record.kind, day: at.day, time: at.time })
        },
      },
    },
    [controls, currentTime, scrollController, dragAndDrop],
  )
  calendar.render(document.getElementById('calendar'))
  wireHeader()
  renderWeekdays()
  refreshHeader()
}

function postRange(range) {
  refreshHeader()
  if (!range) return
  post({
    type: 'range',
    view: controls.getView(),
    date: toDateString(controls.getDate()),
    start: toDateString(range.start),
    end: toDateString(range.end),
  })
}

// MARK: The card's header
//
// Previous and next step by the view's own unit (a month in the month grid
// and the agenda, a week, a day), the title names the period in the
// captain's locale, and the pill for the showing view is the filled one. Every
// change goes through `calendar-controls`, so Schedule-X's own range update
// is what reports the new period to the native side.

let locale = 'en-US'
let firstDayOfWeek = 1

function step(direction) {
  const date = controls.getDate()
  const view = controls.getView()
  let next
  if (view === 'week') next = date.add({ days: 7 * direction })
  else if (view === 'day') next = date.add({ days: direction })
  else next = date.add({ months: direction })
  controls.setDate(next)
}

function selectView(view) {
  if (!calendar || controls.getView() === view) return
  controls.setView(view)
  // The scroll controller's `initialScroll` only applies to the first time
  // a time grid mounts. Every later switch to week or day would open at
  // midnight, an empty screen for any task in the working day.
  if (view === 'week' || view === 'day') setTimeout(() => scrollController.scrollTo('07:50'), 0)
  // Month grid and agenda cover the same month, so switching between the two
  // may not move the range and Schedule-X then reports nothing. The native
  // side still needs to hear which view is showing.
  postRange(controls.getRange())
}

function wireHeader() {
  document.getElementById('gl-prev').addEventListener('click', () => step(-1))
  document.getElementById('gl-next').addEventListener('click', () => step(1))
  document.getElementById('gl-today').addEventListener('click', () => {
    controls.setDate(Temporal.Now.plainDateISO(timeZone))
  })
  for (const button of document.querySelectorAll('#gl-views [data-view]')) {
    button.addEventListener('click', () => selectView(button.dataset.view))
  }
}

function jsDate(plainDate) {
  // Noon, so no time zone can move it onto a neighbouring day.
  return new Date(Date.UTC(plainDate.year, plainDate.month - 1, plainDate.day, 12))
}

function periodTitle() {
  const view = controls.getView()
  const date = controls.getDate()
  const utc = { timeZone: 'UTC' }
  if (view === 'day') {
    return jsDate(date).toLocaleDateString(locale, { ...utc, weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })
  }
  if (view === 'week') {
    const range = controls.getRange()
    if (range) {
      const start = jsDate(Temporal.PlainDate.from(toDateString(range.start)))
      const end = jsDate(Temporal.PlainDate.from(toDateString(range.end)))
      const format = new Intl.DateTimeFormat(locale, { ...utc, month: 'short', day: 'numeric', year: 'numeric' })
      return typeof format.formatRange === 'function' ? format.formatRange(start, end) : format.format(start)
    }
  }
  return jsDate(date).toLocaleDateString(locale, { ...utc, month: 'long', year: 'numeric' })
}

function refreshHeader() {
  if (!calendar) return
  const view = controls.getView()
  document.getElementById('gl-title').textContent = periodTitle()
  for (const button of document.querySelectorAll('#gl-views [data-view]')) {
    const on = button.dataset.view === view
    button.classList.toggle('is-active', on)
    button.setAttribute('aria-pressed', on ? 'true' : 'false')
  }
  document.documentElement.dataset.view = view
}

// The month grid's weekday names, once, above the cells rather than inside
// the first week's (Schedule-X's own placement). In the captain's first
// weekday and locale.
function renderWeekdays() {
  const row = document.getElementById('gl-weekdays')
  row.textContent = ''
  // 2024-01-01 was a Monday, which is Schedule-X's weekday 1.
  const monday = Temporal.PlainDate.from('2024-01-01')
  for (let i = 0; i < 7; i++) {
    const day = monday.add({ days: (firstDayOfWeek - 1 + i) % 7 })
    const cell = document.createElement('span')
    cell.textContent = jsDate(day).toLocaleDateString(locale, { timeZone: 'UTC', weekday: 'short' })
    row.appendChild(cell)
  }
}

// What each colour means, from the native side: the same categories the
// events' `calendarId`s name, with the theme's own colours.
function renderLegend(items) {
  const footer = document.getElementById('gl-legend')
  footer.textContent = ''
  for (const item of items || []) {
    const entry = document.createElement('span')
    entry.className = 'gl-legend-item'
    entry.dataset.category = item.id
    const swatch = document.createElement('i')
    swatch.style.background = item.container
    swatch.style.borderInlineStartColor = item.main
    entry.appendChild(swatch)
    entry.appendChild(document.createTextNode(item.label))
    footer.appendChild(entry)
  }
}

// MARK: Theme
//
// Schedule-X themes itself through CSS variables declared on `:root` and
// again on `.is-dark`. One injected rule at `:root, :root .is-dark` beats both
// on specificity, so the dark register cannot quietly fall back to the
// default theme's purple, and the date picker's teleported popup (which is not
// inside the calendar wrapper) picks the same values up from `:root`.

const themeStyle = document.createElement('style')
themeStyle.id = 'gl-theme'
document.head.appendChild(themeStyle)

function applyTheme(theme) {
  const lines = Object.keys(theme.vars)
    .sort()
    .map((key) => `  ${key}: ${theme.vars[key]};`)
  themeStyle.textContent = `:root,\n:root .is-dark {\n${lines.join('\n')}\n}\n`
  document.documentElement.dataset.theme = theme.dark ? 'dark' : 'light'
  if (theme.legend) renderLegend(theme.legend)
  if (calendar) {
    calendar.setTheme(theme.dark ? 'dark' : 'light')
    if (theme.calendars) controls.setCalendars(theme.calendars)
  }
}

// MARK: Bridge

function guarded(fn) {
  return (callID, payload) => {
    try {
      const extra = fn(payload || {})
      reply(callID, true, extra)
    } catch (error) {
      reply(callID, false, { message: String((error && error.message) || error) })
    }
  }
}

window.GrandLineTaskCalendar = {
  // The first call, once the page reports ready. The page draws nothing until
  // it arrives, because the time zone, the locale, the first weekday and the
  // theme all decide what the first render looks like.
  configure: guarded((payload) => {
    if (calendar) return { alreadyMounted: true }
    locale = payload.locale || 'en-US'
    firstDayOfWeek = payload.firstDayOfWeek || 1
    if (payload.theme) applyTheme(payload.theme)
    mount(payload)
    return {}
  }),

  setTheme: guarded((payload) => {
    applyTheme(payload)
  }),

  setEvents: guarded((payload) => {
    movable.clear()
    const events = (payload.events || []).map(toCalendarEvent)
    if (payload.calendars) controls.setCalendars(payload.calendars)
    calendar.events.set(events)
    return { count: events.length }
  }),

  setView: guarded((payload) => {
    selectView(payload.view)
  }),

  showDate: guarded((payload) => {
    controls.setDate(Temporal.PlainDate.from(payload.date))
  }),

  // Paused while the destination is hidden: the now-line's once-a-minute
  // timer is the one timer this page owns, and CSS transitions stop too.
  suspend: guarded(() => {
    document.documentElement.classList.add('gl-suspended')
    if (currentTime.timeout) {
      clearTimeout(currentTime.timeout)
      currentTime.timeout = null
    }
  }),

  resume: guarded(() => {
    document.documentElement.classList.remove('gl-suspended')
    if (calendar && typeof currentTime.setIndicator === 'function') currentTime.setIndicator()
  }),

  // What is on screen, read back from the DOM rather than from the model, so
  // a caller asking "did it render" is answered by the render.
  state: guarded(() => {
    const range = controls.getRange()
    return {
      view: controls.getView(),
      date: toDateString(controls.getDate()),
      start: range ? toDateString(range.start) : null,
      end: range ? toDateString(range.end) : null,
      dark: document.documentElement.dataset.theme === 'dark',
      renderedEvents: document.querySelectorAll('.sx__event').length,
      todayCells: document.querySelectorAll('.sx__month-grid-day__header-date.sx__is-today, .sx__week-grid__date--is-today').length,
      title: document.getElementById('gl-title').textContent,
      activePill: (document.querySelector('#gl-views .is-active') || {}).dataset?.view || null,
      weekdays: Array.from(document.querySelectorAll('#gl-weekdays span')).map((el) => el.textContent),
      legend: Array.from(document.querySelectorAll('#gl-legend .gl-legend-item')).map((el) => el.dataset.category),
      dimmedCells: document.querySelectorAll('.sx__month-grid-day.is-leading-or-trailing').length,
      // Each month-grid chip's accent edge names its category's colour
      // variable, so a caller can see which category a chip was drawn as.
      chipEdges: Array.from(document.querySelectorAll('.sx__month-grid-event')).map((el) => el.style.borderInlineStart),
    }
  }),
}

post({ type: 'ready' })
