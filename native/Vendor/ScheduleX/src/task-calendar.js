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
//     never shows a position the store does not hold. The check on a chip is
//     the same: it asks (`complete`), and the push draws the result. So are a
//     tray row dropped on a day (`place`), a chip dropped on the tray
//     (`unschedule`) and a task typed into a day's quick add (`quickAdd`):
//     each is a request, and the next `setEvents` and `setTray` are the
//     answer.
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

// A `gl-ref-N` class -> the record a chip's check completes, for the events
// the native side marks `completable` (a real, open record; never a
// projection). A class rather than the event id because Schedule-X's agenda
// rows carry no `data-event-id`, only the event's additional classes, and a
// class built from a counter is safe whatever characters a hand-edited id
// holds.
const completable = new Map()

function toCalendarEvent(item) {
  const classes = []
  if (item.projected) classes.push('gl-projected')
  if (item.completed) classes.push('gl-completed')
  if (item.allDay) classes.push('gl-all-day')
  if (item.movable) movable.set(item.id, { id: item.taskID, kind: item.kind || 'task' })
  if (item.completable) {
    const ref = 'gl-ref-' + completable.size
    completable.set(ref, { id: item.taskID, kind: item.kind || 'task', title: item.title })
    classes.push('gl-completable', ref)
  }
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

// MARK: The check
//
// Schedule-X draws every chip and agenda row itself, and re-renders them as
// it likes, so the check is added after it draws rather than inside its
// templates: one observer gives every `gl-completable` event a check, and
// takes it off an element Schedule-X has reused for anything else. Which
// record a check finishes is read from its chip's class at click time, never
// remembered on the button, for the same reason.
//
// The check sits inside the chip, so it stops every event the chip listens
// for: a click would otherwise also open the task, a press would start the
// drag timer, and a double-click would reach the day's "new task".

function refOf(chip) {
  for (const name of chip.classList) if (name.startsWith('gl-ref-')) return name
  return null
}

function completeFrom(button) {
  const chip = button.closest('.sx__event')
  const record = chip && completable.get(refOf(chip))
  if (!record) return
  chip.classList.add('is-completing')
  post({ type: 'complete', taskID: record.id, kind: record.kind })
}

function makeCheck() {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'gl-check'
  button.draggable = false
  for (const type of ['mousedown', 'mouseup', 'touchstart', 'touchend', 'dblclick', 'keydown']) {
    button.addEventListener(type, (event) => event.stopPropagation())
  }
  button.addEventListener('dragstart', (event) => {
    event.preventDefault()
    event.stopPropagation()
  })
  button.addEventListener('click', (event) => {
    event.preventDefault()
    event.stopPropagation()
    completeFrom(button)
  })
  return button
}

function decorateChecks() {
  for (const stale of document.querySelectorAll('.sx__event:not(.gl-completable) > .gl-check')) stale.remove()
  for (const chip of document.querySelectorAll('.sx__event.gl-completable')) {
    const record = completable.get(refOf(chip))
    if (!record) continue
    let button = chip.querySelector(':scope > .gl-check')
    if (!button) {
      button = makeCheck()
      chip.appendChild(button)
    }
    const label = 'Complete \u201C' + record.title + '\u201D'
    if (button.getAttribute('aria-label') !== label) {
      button.setAttribute('aria-label', label)
      button.title = record.kind === 'followUp' ? 'Mark done' : 'Complete'
    }
  }
}

// A microtask rather than an animation frame: WebKit stops animation frames
// for a page nobody can see, and a chip finished from the Agenda must not
// wait for the window to come forward before its neighbours get their checks.
let decorateQueued = false

function queueDecorate() {
  if (decorateQueued) return
  decorateQueued = true
  queueMicrotask(() => {
    decorateQueued = false
    decorateChecks()
  })
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
      // The native app owns the layout, and the view. Left on, Schedule-X
      // switches to Day whenever its wrapper is under 700px - which is every
      // time the shell hides this page, because a hidden page loses its pins
      // and collapses - and the wide branch never switches back, since Day
      // also counts as wide-screen. Leave the page, come back: Day, for good
      // (review #4's R4-BUG-01).
      isResponsive: false,
      callbacks: {
        // "+N more" on a crowded day opens that day. Schedule-X would switch
        // the view itself; going through the pill handler instead is what
        // tells the native side, which only follows a view the captain chose.
        onClickPlusEvents(date) {
          controls.setDate(date)
          selectView('day')
        },
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
        // The selected date can move without the header's own buttons
        // ("+N more" opens its day), and the header's title has to follow.
        onSelectedDateUpdate() {
          refreshHeader()
        },
        // The plugin already refuses to start a drag on `disableDND`; this is
        // the second gate, so a projection or a completed task can never
        // reach `move` whatever the DOM was persuaded to do. A chip the tray
        // just took is refused too: the plugin would otherwise also move it
        // to the last day the pointer crossed on its way there.
        onBeforeEventUpdate(oldEvent) {
          if (unscheduledChip !== null && String(oldEvent.id) === unscheduledChip) return false
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
  const root = document.getElementById('calendar')
  calendar.render(root)
  // Only the calendar's own subtree, and only structure and classes: the
  // check's own insertions settle in one more pass, because a decorated chip
  // is skipped.
  new MutationObserver(queueDecorate).observe(root, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['class'],
  })
  wireHeader()
  renderWeekdays()
  refreshHeader()
}

function postRange(range) {
  refreshHeader()
  // A quick add belongs to a day on screen; a new period has other days.
  closeQuickAdd()
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

// The one place the page changes its view, for a pill, for "+N more" and for
// the native side's `setView`. It says so in a `view` message of its own: a
// `range` report only ever moves the period on the native side, so nothing
// Schedule-X does by itself can change the scale behind the captain's back.
function selectView(view) {
  if (!calendar || controls.getView() === view) return
  controls.setView(view)
  post({ type: 'view', view })
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

// MARK: The Unscheduled tray
//
// Beside the card: the open tasks with no date, grouped by project, and the
// overdue ones pinned above them. The native side sends every word and every
// colour (`ShiftCalendarPayload.tray`), so this only builds rows. A row's
// Today and Tomorrow post `schedule` with the button's word, never a date:
// which day "today" is belongs to the native clock. The fold button asks the
// native side, which remembers the choice and sends the tray back folded.

let trayCollapsed = false

function trayButton(label, when, title) {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'gl-quick'
  button.dataset.when = when
  button.textContent = label
  if (title) button.title = title
  return button
}

function trayRow(item) {
  const row = document.createElement('div')
  row.className = 'gl-tray-item' + (item.overdue ? ' is-overdue' : '')
  row.dataset.taskId = item.taskID
  row.dataset.kind = item.kind
  row.tabIndex = 0
  row.setAttribute('role', 'button')
  // A row drags onto a day or a time (see "Dragging from the tray").
  row.draggable = true
  const edge = document.createElement('span')
  edge.className = 'gl-tray-edge'
  edge.style.background = item.edge
  const body = document.createElement('div')
  body.className = 'gl-tray-body'
  const title = document.createElement('div')
  title.className = 'gl-tray-title'
  title.textContent = item.title
  const meta = document.createElement('div')
  meta.className = 'gl-tray-meta'
  meta.textContent = item.meta
  const quick = document.createElement('div')
  quick.className = 'gl-tray-quick'
  quick.appendChild(trayButton('Today', 'today'))
  quick.appendChild(trayButton('Tomorrow', 'tomorrow'))
  quick.appendChild(trayButton('Pick\u2026', 'pick', 'Open it to choose a date'))
  body.appendChild(title)
  body.appendChild(meta)
  body.appendChild(quick)
  row.appendChild(edge)
  row.appendChild(body)
  return row
}

function trayGroup(title, dot, extraClass) {
  const heading = document.createElement('div')
  heading.className = 'gl-tray-group' + (extraClass ? ' ' + extraClass : '')
  if (dot !== undefined) {
    const swatch = document.createElement('i')
    if (dot) swatch.style.background = dot
    heading.appendChild(swatch)
  }
  heading.appendChild(document.createTextNode(title))
  return heading
}

function renderTray(tray) {
  const aside = document.getElementById('gl-tray')
  const list = document.getElementById('gl-tray-list')
  trayCollapsed = !!tray.collapsed
  aside.hidden = false
  aside.classList.toggle('is-collapsed', trayCollapsed)
  const toggle = document.getElementById('gl-tray-toggle')
  toggle.setAttribute('aria-expanded', trayCollapsed ? 'false' : 'true')
  toggle.setAttribute('aria-label', trayCollapsed ? 'Expand Unscheduled' : 'Collapse Unscheduled')
  document.getElementById('gl-tray-count').textContent = String(tray.count || 0)
  document.getElementById('gl-tray-hint').textContent = tray.hint || ''
  document.getElementById('gl-tray-drop').textContent = tray.dropHint || ''
  list.textContent = ''
  const overdue = tray.overdue || []
  if (overdue.length) {
    list.appendChild(trayGroup(tray.overdueTitle || 'Overdue', undefined, 'is-overdue'))
    for (const item of overdue) list.appendChild(trayRow(item))
  }
  for (const group of tray.groups || []) {
    list.appendChild(trayGroup(group.title + ' \u00B7 ' + group.count, group.dot || ''))
    for (const item of group.items || []) list.appendChild(trayRow(item))
  }
  if (tray.nothing) {
    const none = document.createElement('p')
    none.className = 'gl-tray-nothing'
    none.textContent = tray.nothing
    list.appendChild(none)
  }
  renderEmpty(tray.empty || null)
}

// The first-run state over the grid: open tasks exist and none has a date.
function renderEmpty(empty) {
  const section = document.getElementById('gl-empty')
  document.getElementById('gl-card').classList.toggle('is-empty', !!empty)
  section.hidden = !empty
  if (!empty) return
  document.getElementById('gl-empty-title').textContent = empty.title
  document.getElementById('gl-empty-body').textContent = empty.body
  document.getElementById('gl-empty-new').textContent = empty.newTask
  document.getElementById('gl-empty-list').textContent = empty.openList
}

function wireTray() {
  const list = document.getElementById('gl-tray-list')
  list.addEventListener('click', (event) => {
    const row = event.target.closest('.gl-tray-item')
    if (!row) return
    const button = event.target.closest('.gl-quick')
    if (button) {
      post({ type: 'schedule', taskID: row.dataset.taskId, kind: row.dataset.kind, when: button.dataset.when })
    } else {
      post({ type: 'open', taskID: row.dataset.taskId, kind: row.dataset.kind })
    }
  })
  list.addEventListener('keydown', (event) => {
    const row = event.target
    if (!row.classList || !row.classList.contains('gl-tray-item')) return
    if (event.key !== 'Enter' && event.key !== ' ') return
    event.preventDefault()
    post({ type: 'open', taskID: row.dataset.taskId, kind: row.dataset.kind })
  })
  document.getElementById('gl-tray-toggle').addEventListener('click', () => {
    post({ type: 'tray', collapsed: !trayCollapsed })
  })
  document.getElementById('gl-empty-new').addEventListener('click', () => post({ type: 'newTask' }))
  document.getElementById('gl-empty-list').addEventListener('click', () => post({ type: 'openList' }))
}

wireTray()

// MARK: Dragging from the tray, and back to it
//
// A tray row is an HTML5 drag source of this page's own, so the grid Schedule-X
// draws is the drop target: a month cell (`.sx__month-grid-day`, the drag
// plugin's own day lookup), a time in Week and Day (`.sx__time-grid-day`, a
// column 24 hours tall) or the all-day row (`.sx__date-grid-day`). A drop
// posts `place` with the day and, for a time slot, the time. Which task may
// land where is the native side's rule (`ShiftCalendarReschedule`).
//
// The other way, a real chip dropped on the tray posts `unschedule`. The
// chip's own drag belongs to the drag plugin - HTML5 in the month grid, mouse
// events in the time grid - so this only notes which chip was pressed, sees
// where the drag ended, and has `onBeforeEventUpdate` refuse the plugin's own
// move of it. A projection or a finished task is never pressed here, because
// only `movable` events count.

const SLOT_MINUTES = 15
const DAY_MINUTES = 24 * 60
// The row being dragged: { taskID, kind }.
let trayDrag = null
// The movable chip under a mouse-down, until that drag ends: { eventID,
// taskID, kind, x, y, moved }.
let pressedChip = null
// The chip the tray just took, so the plugin's own update of it is refused.
let unscheduledChip = null

function shortDay(day) {
  return jsDate(Temporal.PlainDate.from(day)).toLocaleDateString(locale, {
    timeZone: 'UTC',
    weekday: 'short',
    day: 'numeric',
    month: 'short',
  })
}

// The day, and for a time slot the time, under the pointer: `null` when it
// is over nothing a task can be dated to.
function dropTargetAt(element, clientY) {
  if (!element || !element.closest) return null
  const cell = element.closest('.sx__month-grid-day[data-date]')
  if (cell) return { element: cell, day: cell.dataset.date, time: null }
  const column = element.closest('.sx__time-grid-day[data-time-grid-date]')
  if (column) {
    const rect = column.getBoundingClientRect()
    const fraction = Math.min(Math.max((clientY - rect.top) / rect.height, 0), 1)
    const minutes = Math.min(Math.floor((fraction * DAY_MINUTES) / SLOT_MINUTES) * SLOT_MINUTES, DAY_MINUTES - SLOT_MINUTES)
    return {
      element: column,
      day: column.dataset.timeGridDate,
      time: pad(Math.floor(minutes / 60)) + ':' + pad(minutes % 60),
      top: rect.top + (minutes / DAY_MINUTES) * rect.height,
      height: (30 / DAY_MINUTES) * rect.height,
    }
  }
  const allDay = element.closest('.sx__date-grid-day[data-date-grid-date]')
  if (allDay) return { element: allDay, day: allDay.dataset.dateGridDate, time: null }
  return null
}

// The dashed target over the cell or the slot a row would land on, with the
// day (and time) it means. Drawn over the grid, never inside it.
function showDrop(target) {
  const drop = document.getElementById('gl-drop')
  const body = document.querySelector('.gl-body').getBoundingClientRect()
  const rect = target.element.getBoundingClientRect()
  const top = target.time ? target.top : rect.top
  const height = target.time ? Math.max(target.height, 26) : rect.height
  drop.style.left = rect.left - body.left + 'px'
  drop.style.top = top - body.top + 'px'
  drop.style.width = rect.width + 'px'
  drop.style.height = height + 'px'
  drop.classList.toggle('is-slot', !!target.time)
  document.getElementById('gl-drop-label').textContent = target.time
    ? target.time + ' \u00B7 ' + shortDay(target.day)
    : 'Drop to schedule ' + shortDay(target.day)
  drop.dataset.day = target.day
  drop.dataset.time = target.time || ''
  drop.hidden = false
}

function hideDrop() {
  const drop = document.getElementById('gl-drop')
  drop.hidden = true
  drop.dataset.day = ''
  drop.dataset.time = ''
}

function setTrayDropTarget(on) {
  document.getElementById('gl-tray').classList.toggle('is-drop-target', on)
}

function insideTray(x, y) {
  const tray = document.getElementById('gl-tray')
  if (tray.hidden) return false
  const r = tray.getBoundingClientRect()
  return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
}

function endTrayDrag() {
  if (!trayDrag) return
  for (const row of document.querySelectorAll('.gl-tray-item.is-dragging')) row.classList.remove('is-dragging')
  trayDrag = null
  hideDrop()
}

function unscheduleChip(chip) {
  unscheduledChip = chip.eventID
  post({ type: 'unschedule', taskID: chip.taskID, kind: chip.kind })
  // Long enough for the plugin's own drop to ask and be refused, and no
  // longer: the store's answer redraws the chip or takes it away.
  setTimeout(() => {
    if (unscheduledChip === chip.eventID) unscheduledChip = null
  }, 1000)
}

function wireDragging() {
  const list = document.getElementById('gl-tray-list')
  const tray = document.getElementById('gl-tray')

  list.addEventListener('dragstart', (event) => {
    const row = event.target.closest && event.target.closest('.gl-tray-item')
    if (!row) return
    closeQuickAdd()
    trayDrag = { taskID: row.dataset.taskId, kind: row.dataset.kind }
    row.classList.add('is-dragging')
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = 'move'
      event.dataTransfer.setData('text/plain', row.querySelector('.gl-tray-title').textContent)
    }
  })
  list.addEventListener('dragend', endTrayDrag)

  document.addEventListener('dragover', (event) => {
    if (!trayDrag) return
    const target = dropTargetAt(event.target, event.clientY)
    if (!target) {
      hideDrop()
      return
    }
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
    showDrop(target)
  })
  document.addEventListener('drop', (event) => {
    if (!trayDrag) return
    event.preventDefault()
    const target = dropTargetAt(event.target, event.clientY)
    if (target) post({ type: 'place', taskID: trayDrag.taskID, kind: trayDrag.kind, day: target.day, time: target.time })
    endTrayDrag()
  })

  // A chip dragged in the month grid: HTML5, so the tray is a real drop
  // target. `drop` fires before the plugin's own `dragend`.
  tray.addEventListener('dragover', (event) => {
    if (trayDrag || !pressedChip) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
    setTrayDropTarget(true)
  })
  tray.addEventListener('dragleave', (event) => {
    if (!event.relatedTarget || !tray.contains(event.relatedTarget)) setTrayDropTarget(false)
  })
  tray.addEventListener('drop', (event) => {
    if (trayDrag || !pressedChip) return
    event.preventDefault()
    event.stopPropagation()
    setTrayDropTarget(false)
    unscheduleChip(pressedChip)
  })

  // Which chip a drag started on, read before the plugin sees the press.
  document.addEventListener(
    'mousedown',
    (event) => {
      const el = event.target.closest && event.target.closest('.sx__event[data-event-id]')
      const record = el && movable.get(el.dataset.eventId)
      pressedChip = record
        ? { eventID: el.dataset.eventId, taskID: record.id, kind: record.kind, x: event.clientX, y: event.clientY, moved: false }
        : null
    },
    true,
  )
  // A chip dragged in the time grid: mouse events, so the tray is found by
  // where the pointer is when the button comes up.
  document.addEventListener('mousemove', (event) => {
    if (!pressedChip || !(event.buttons & 1)) return
    if (Math.abs(event.clientX - pressedChip.x) + Math.abs(event.clientY - pressedChip.y) > 4) pressedChip.moved = true
    if (pressedChip.moved) setTrayDropTarget(insideTray(event.clientX, event.clientY))
  })
  document.addEventListener(
    'mouseup',
    (event) => {
      const chip = pressedChip
      if (!chip) return
      setTrayDropTarget(false)
      if (chip.moved && insideTray(event.clientX, event.clientY)) unscheduleChip(chip)
      // After the plugin's own handlers, which run on this same event.
      setTimeout(() => {
        if (pressedChip === chip) pressedChip = null
      }, 0)
    },
    true,
  )
  document.addEventListener('dragend', () => {
    setTrayDropTarget(false)
    const chip = pressedChip
    setTimeout(() => {
      if (pressedChip === chip) pressedChip = null
    }, 0)
  })
}

wireDragging()

// MARK: Quick add in a day
//
// Hovering a day in the month grid shows a small + beside its date. It opens
// a title field over that day. The native side reads what is typed with the
// app's own title parser and answers with what it understood - the day, a
// time, a repeat rule - as pills under the field (`setQuickAddHint`). Return
// adds the task, Command-Return opens the full sheet with everything filled
// in, and Escape closes the field. The day belongs to the cell; which day
// "tomorrow" or "every tue" means belongs to the native clock and parser.

let quickAdd = null // { day, seq }
let hoverDay = null

function placeCellAdd(cell) {
  const button = document.getElementById('gl-cell-add')
  const body = document.querySelector('.gl-body').getBoundingClientRect()
  const rect = cell.getBoundingClientRect()
  button.style.left = rect.right - body.left - 30 + 'px'
  button.style.top = rect.top - body.top + 9 + 'px'
  button.dataset.day = cell.dataset.date
  button.setAttribute('aria-label', 'Add a task on ' + shortDay(cell.dataset.date))
  button.hidden = false
}

function hideCellAdd() {
  const button = document.getElementById('gl-cell-add')
  button.hidden = true
  hoverDay = null
}

function openQuickAdd(day) {
  const cell = document.querySelector(`.sx__month-grid-day[data-date="${day}"]`)
  if (!cell) return
  hideCellAdd()
  const panel = document.getElementById('gl-quick-add')
  const input = document.getElementById('gl-quick-add-input')
  const bodyEl = document.querySelector('.gl-body')
  const body = bodyEl.getBoundingClientRect()
  const rect = cell.getBoundingClientRect()
  const width = Math.max(rect.width - 8, 220)
  const left = Math.min(rect.left - body.left + 4, body.width - width - 4)
  panel.style.left = Math.max(left, 4) + 'px'
  panel.style.top = rect.top - body.top + 32 + 'px'
  panel.style.width = width + 'px'
  panel.dataset.day = day
  input.value = ''
  input.placeholder = 'New task on ' + shortDay(day)
  document.getElementById('gl-quick-add-keys').textContent = '\u21A9 add \u00B7 \u2318\u21A9 details'
  quickAdd = { day, seq: 0 }
  renderQuickAddPills([])
  panel.hidden = false
  input.focus()
}

function closeQuickAdd() {
  if (!quickAdd) return
  quickAdd = null
  const panel = document.getElementById('gl-quick-add')
  panel.hidden = true
  panel.dataset.day = ''
  document.getElementById('gl-quick-add-input').value = ''
  renderQuickAddPills([])
}

function renderQuickAddPills(pills) {
  const row = document.getElementById('gl-quick-add-pills')
  row.textContent = ''
  for (const pill of pills) {
    const chip = document.createElement('b')
    chip.className = 'gl-quick-add-pill'
    if (pill.kind) chip.dataset.kind = pill.kind
    chip.textContent = pill.label
    row.appendChild(chip)
  }
}

function wireQuickAdd() {
  document.addEventListener('mouseover', (event) => {
    if (quickAdd || trayDrag || pressedChip || controls.getView() !== 'month-grid') return
    if (event.target.closest && event.target.closest('#gl-cell-add')) return
    const cell = event.target.closest && event.target.closest('.sx__month-grid-day[data-date]')
    if (!cell) {
      if (hoverDay) hideCellAdd()
      return
    }
    if (hoverDay === cell.dataset.date) return
    hoverDay = cell.dataset.date
    placeCellAdd(cell)
  })
  document.querySelector('.gl-body').addEventListener('mouseleave', hideCellAdd)
  document.getElementById('gl-cell-add').addEventListener('click', (event) => {
    event.stopPropagation()
    openQuickAdd(event.currentTarget.dataset.day)
  })

  const input = document.getElementById('gl-quick-add-input')
  input.addEventListener('input', () => {
    if (!quickAdd) return
    quickAdd.seq += 1
    const text = input.value
    if (!text.trim()) {
      renderQuickAddPills([])
      return
    }
    post({ type: 'quickAddParse', day: quickAdd.day, text, seq: quickAdd.seq })
  })
  input.addEventListener('keydown', (event) => {
    if (!quickAdd) return
    if (event.key === 'Escape') {
      event.preventDefault()
      closeQuickAdd()
      return
    }
    if (event.key !== 'Enter' || event.isComposing) return
    event.preventDefault()
    const text = input.value.trim()
    if (!text) return
    post({ type: 'quickAdd', day: quickAdd.day, text, details: !!event.metaKey })
    closeQuickAdd()
  })
  // Clicking away from an empty field puts it away. A field with words in
  // it stays until Return or Escape, so a stray click loses nothing.
  input.addEventListener('blur', () => {
    if (quickAdd && !input.value.trim()) setTimeout(() => {
      if (document.activeElement !== input && !input.value.trim()) closeQuickAdd()
    }, 0)
  })
}

wireQuickAdd()

function visible(id) {
  const el = document.getElementById(id)
  return !!el && !el.hidden && getComputedStyle(el).display !== 'none'
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
    completable.clear()
    const events = (payload.events || []).map(toCalendarEvent)
    if (payload.calendars) controls.setCalendars(payload.calendars)
    calendar.events.set(events)
    // A chip Schedule-X keeps across the set keeps its element, so the
    // observer may see nothing change; the new refs still need checking.
    queueDecorate()
    return { count: events.length }
  }),

  setTray: guarded((payload) => {
    renderTray(payload)
    return { rows: document.querySelectorAll('#gl-tray-list .gl-tray-item').length }
  }),

  setView: guarded((payload) => {
    selectView(payload.view)
  }),

  // The native parser's reading of the quick-add field, for the text whose
  // `seq` it names. An answer to an older keystroke is dropped.
  setQuickAddHint: guarded((payload) => {
    if (!quickAdd || payload.seq !== quickAdd.seq) return { applied: false }
    renderQuickAddPills(payload.pills || [])
    return { applied: true }
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
      // The tray and the empty state, as drawn.
      trayVisible: visible('gl-tray'),
      trayCollapsed: document.getElementById('gl-tray').classList.contains('is-collapsed'),
      trayCount: document.getElementById('gl-tray-count').textContent,
      trayRows: Array.from(document.querySelectorAll('#gl-tray-list .gl-tray-item')).map((el) => el.dataset.taskId),
      trayOverdueRows: Array.from(document.querySelectorAll('#gl-tray-list .gl-tray-item.is-overdue')).map(
        (el) => el.dataset.taskId,
      ),
      trayGroups: Array.from(document.querySelectorAll('#gl-tray-list .gl-tray-group')).map((el) => el.textContent),
      // The checks, as drawn: the record each one would complete, and how
      // many sit on a projection (which must be none).
      checks: Array.from(document.querySelectorAll('.sx__event > .gl-check')).map((button) => {
        const record = completable.get(refOf(button.parentElement))
        return record ? record.id : null
      }),
      projectedChecks: document.querySelectorAll('.sx__event.gl-projected .gl-check').length,
      emptyVisible: visible('gl-empty'),
      emptyTitle: document.getElementById('gl-empty-title').textContent,
      // Dragging and quick add, as drawn.
      trayDraggableRows: document.querySelectorAll('#gl-tray-list .gl-tray-item[draggable="true"]').length,
      trayDropHint: document.getElementById('gl-tray-drop').textContent,
      trayDropTarget: document.getElementById('gl-tray').classList.contains('is-drop-target'),
      dropVisible: visible('gl-drop'),
      dropLabel: document.getElementById('gl-drop-label').textContent,
      cellAddVisible: visible('gl-cell-add'),
      cellAddDay: document.getElementById('gl-cell-add').dataset.day || null,
      quickAddOpen: visible('gl-quick-add'),
      quickAddDay: document.getElementById('gl-quick-add').dataset.day || null,
      quickAddFocused: document.activeElement === document.getElementById('gl-quick-add-input'),
      quickAddPills: Array.from(document.querySelectorAll('#gl-quick-add-pills .gl-quick-add-pill')).map((el) => el.textContent),
    }
  }),
}

post({ type: 'ready' })
