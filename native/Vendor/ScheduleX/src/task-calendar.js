// Grand Line - the Tasks page's calendar, as a Schedule-X page.
//
// This is the hand-written half of the bundle. `native/Scripts/build-schedule-x-web.sh`
// bundles it with the pinned packages in `package.json` into one classic IIFE,
// and `ShiftCalendarWebView.swift` is the native half of the bridge below.
//
// What this page owns, and what it does not:
//
//   - It draws. Month, week and day views, today's highlight, the now-line,
//     and the drag of an event to a new day or time are all Schedule-X's own.
//   - It does not own a single task. Every event arrives from the native side
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

const movable = new Map() // event id -> task id, for events the store lets move

function toCalendarEvent(item) {
  const classes = []
  if (item.projected) classes.push('gl-projected')
  if (item.completed) classes.push('gl-completed')
  if (item.movable) movable.set(item.id, item.taskID)
  return {
    id: item.id,
    taskID: item.taskID,
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
      views: [createViewMonthGrid(), createViewWeek(), createViewDay()],
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
          post({ type: 'open', taskID: event.taskID })
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
        // The plugin already refuses to start a drag on `disableDND`; this is
        // the second gate, so a projection or a completed task can never
        // reach `move` whatever the DOM was persuaded to do.
        onBeforeEventUpdate(oldEvent) {
          return movable.has(oldEvent.id)
        },
        onEventUpdate(event) {
          const taskID = movable.get(event.id)
          if (!taskID) return
          const at = describe(event.start)
          post({ type: 'move', taskID, day: at.day, time: at.time })
        },
      },
    },
    [controls, currentTime, scrollController, dragAndDrop],
  )
  calendar.render(document.getElementById('calendar'))
}

function postRange(range) {
  if (!range) return
  post({
    type: 'range',
    view: controls.getView(),
    start: toDateString(range.start),
    end: toDateString(range.end),
  })
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
    controls.setView(payload.view)
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
    }
  }),
}

post({ type: 'ready' })
