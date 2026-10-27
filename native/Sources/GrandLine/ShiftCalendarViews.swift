// Grand Line - native macOS app.
//
// The Calendar - its own sidebar row in Work, after Tasks
// (`TaskCalendarController`). It was Tasks' third tab until the captain moved
// it out.
//
// **It is a Schedule-X calendar in a web view** (the captain's choice, after
// the open-source calendar options review): month, week, day and agenda
// views, today's highlight, a now-line, and dragging a task or a follow-up to
// a new day or time. The bundle is vendored and offline
// (`Vendor/ScheduleX/README.md`); this file decides what goes into it and
// what comes back out.
//
// Three rules carry over from the hand-drawn grid this replaced
// (`docs/history/34-recurrence-and-calendar.md`), and all three are enforced
// here on the native side, where a self-test can see them without a page:
//
//   - **A projected occurrence is not a task.** Only one instance of a
//     recurring task exists in `active.yaml` at a time
//     (`ShiftStore.nextOccurrence`'s header says why); later dates are a
//     projection of the rule. The page draws them faint and marked, and they
//     cannot be dragged - `ShiftCalendarPayload` marks them immovable, and the
//     page refuses a drop on anything not marked movable a second time.
//   - **A completed task is shown and cannot be moved.** `updateTask` only
//     touches `active.yaml`, so a dropped completed task would save nothing.
//   - **What is on screen is stated** (GL-14). The caption above the calendar
//     counts the tasks in the visible period, and says so when there are none
//     rather than leaving an empty grid to be interpreted.
//
// A drop is a request. The page posts `move`, `ShiftController.rescheduleTask`
// applies `ShiftCalendarReschedule` and writes through the store, and the
// events are pushed back - so a drop the store refuses snaps back to where it
// was, and Undo restores the date the controller already held (GL-33).

import AppKit

// MARK: - The model

/// The four views the calendar offers, by Schedule-X's own view names.
/// Agenda is Schedule-X's open-source list view: a month of records, day by
/// day.
enum ShiftCalendarScale: String, CaseIterable {
    case month = "month-grid"
    case week
    case day
    case agenda = "list"

    /// Also the Calendar module's tab names (`ModuleTable.modules`).
    var title: String {
        switch self {
        case .month: return "Month"
        case .week: return "Week"
        case .day: return "Day"
        case .agenda: return "Agenda"
        }
    }

    init?(title: String) {
        guard let match = Self.allCases.first(where: { $0.title == title }) else { return nil }
        self = match
    }
}

/// One task's or follow-up's appearance on one day.
///
/// A value rather than a view so the placement rules are assertable without a
/// window - which is what lets the recurrence projection be covered by the
/// blocking CI lane rather than only by the windowed one.
struct ShiftCalendarEntry: Equatable {
    /// The two Shift records that carry a date. A follow-up is its own type
    /// with its own `followUpAt`, so it opens its own editor and a drop
    /// writes its own date.
    enum Kind: String {
        case task
        case followUp
    }

    /// The record's id: a task's, or a follow-up's when `kind` says so.
    var taskID: String
    var title: String
    var day: String          // "YYYY-MM-DD"
    var time: String?        // "HH:MM", nil for an all-day task
    var projectID: String?
    var priority: ShiftPriority
    /// `true` for a date the recurrence rule produces but no task record
    /// exists for yet - see this file's header.
    var isProjected: Bool
    var isCompleted: Bool
    /// A cancelled task is still drawn (it is on the board too) but, like a
    /// completed one, it is not something a drag should reschedule.
    var isCancelled: Bool = false
    var kind: Kind = .task

    /// Whether a drag may move this entry. Only a real, open record.
    var isMovable: Bool { !isProjected && !isCompleted && !isCancelled }
}

/// What lands on which day. Pure; no AppKit.
enum ShiftCalendarModel {

    /// Every entry falling inside `[from, through]`, sorted by time then
    /// title so two runs of the same data produce the same calendar.
    ///
    /// A task contributes its own due date when that date is in range, and -
    /// if it carries a rule - every occurrence the rule produces in range
    /// after it. The real record is always the earliest of the two, because
    /// `next(after:)` never returns the anchor itself.
    ///
    /// `perTaskLimit` bounds a daily rule across a long window (GL-35).
    static func entries(tasks: [ShiftTask], from: Date, through: Date,
                        calendar: Calendar = .current,
                        perTaskLimit: Int = 200) -> [ShiftCalendarEntry] {
        var out: [ShiftCalendarEntry] = []
        for task in tasks {
            guard let dueDate = task.dueDate else { continue }
            guard let anchor = ShiftDateFormatting.dateTime(from: dueDate, time: task.dueTime) else { continue }

            if anchor >= calendar.startOfDay(for: from) && anchor <= through {
                out.append(entry(for: task, day: dueDate, time: task.dueTime, projected: false))
            }
            guard let rule = task.recurrence else { continue }
            // A completed task's rule has already been advanced by
            // `ShiftStore.nextOccurrence` into a real successor record, so
            // projecting it again would double every repeated task on the
            // calendar for as long as the completed one stays in the Done
            // window.
            guard task.status != .completed, task.status != .cancelled else { continue }
            let projected = rule.occurrences(anchor: anchor, from: max(from, anchor.addingTimeInterval(1)),
                                             through: through, calendar: calendar, limit: perTaskLimit)
            for date in projected {
                let (day, time) = ShiftDateFormatting.components(from: date)
                out.append(entry(for: task, day: day, time: task.dueTime == nil ? nil : time, projected: true))
            }
        }
        return out.sorted(by: inDayOrder)
    }

    /// Every pending follow-up whose date falls inside `[from, through]`. A
    /// follow-up marked done has been dealt with, and like a completed task's
    /// later dates it is not something still to come.
    static func entries(followUps: [ShiftFollowUp], from: Date, through: Date,
                        calendar: Calendar = .current) -> [ShiftCalendarEntry] {
        followUps.compactMap { item in
            guard item.status == .pending, let day = item.followUpAt,
                  let at = ShiftDateFormatting.dateTime(from: day, time: item.followUpTime),
                  at >= calendar.startOfDay(for: from), at <= through else { return nil }
            return ShiftCalendarEntry(taskID: item.id, title: item.title, day: day, time: item.followUpTime,
                                      projectID: item.projectID, priority: item.priority,
                                      isProjected: false, isCompleted: false, kind: .followUp)
        }
    }

    /// Tasks and follow-ups together, in the one order `entries(tasks:)`
    /// sorts by.
    static func entries(tasks: [ShiftTask], followUps: [ShiftFollowUp], from: Date, through: Date,
                        calendar: Calendar = .current) -> [ShiftCalendarEntry] {
        (entries(tasks: tasks, from: from, through: through, calendar: calendar)
            + entries(followUps: followUps, from: from, through: through, calendar: calendar))
            .sorted(by: inDayOrder)
    }

    /// By day; an all-day record above a timed one, because it is the day's
    /// heading rather than an event inside it; then by time and title.
    static func inDayOrder(_ lhs: ShiftCalendarEntry, _ rhs: ShiftCalendarEntry) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        switch (lhs.time, rhs.time) {
        case let (l?, r?) where l != r: return l < r
        case (nil, .some): return true
        case (.some, nil): return false
        default: return lhs.title < rhs.title
        }
    }

    private static func entry(for task: ShiftTask, day: String, time: String?,
                              projected: Bool) -> ShiftCalendarEntry {
        ShiftCalendarEntry(taskID: task.id, title: task.title, day: day, time: time,
                           projectID: task.projectID, priority: task.priority,
                           isProjected: projected,
                           isCompleted: task.status == .completed,
                           isCancelled: task.status == .cancelled)
    }

    /// The month grid's own date range around `anchor`: whole weeks covering
    /// its month, six rows. Used for the events pushed before the page has
    /// reported its first real range, which is the same period it opens on.
    static func range(for anchor: Date, scale: ShiftCalendarScale,
                      calendar: Calendar = .current) -> (start: Date, days: Int) {
        let startOfDay = calendar.startOfDay(for: anchor)
        switch scale {
        case .day:
            return (startOfDay, 1)
        case .week:
            return (weekStart(of: startOfDay, calendar: calendar), 7)
        case .month, .agenda:
            let components = calendar.dateComponents([.year, .month], from: startOfDay)
            let firstOfMonth = calendar.date(from: components) ?? startOfDay
            return (weekStart(of: firstOfMonth, calendar: calendar), 42)
        }
    }

    static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        var back = weekday - calendar.firstWeekday
        if back < 0 { back += 7 }
        return calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: date)) ?? date
    }
}

// MARK: - What crosses the bridge

/// The page's wire shapes. Pure functions from the store's values to JSON-ready
/// dictionaries, so the rules about what can move and how a task is drawn are
/// tested without WebKit.
enum ShiftCalendarPayload {

    /// One Schedule-X event for one entry.
    ///
    /// The id is the task's own for a real record, and the task id plus the
    /// day for a projection, so the many projections of one rule stay distinct
    /// while every one of them still opens the same task (`taskID`). A
    /// follow-up's carries a prefix, because a follow-up and a task are two
    /// stores whose ids nothing keeps apart.
    ///
    /// A task has a due time but no duration, so a timed task is drawn as a
    /// half-hour block. It ends at 23:59 at the latest: a block that crossed
    /// midnight would become a two-day event in the week view's all-day row.
    static func event(for entry: ShiftCalendarEntry) -> [String: Any] {
        let start: String
        let end: String
        if let time = entry.time, let minutes = minutes(of: time) {
            start = "\(entry.day) \(time)"
            end = "\(entry.day) \(clock(min(minutes + timedBlockMinutes, 23 * 60 + 59)))"
        } else {
            start = entry.day
            end = entry.day
        }
        let id: String
        switch entry.kind {
        case .task: id = entry.isProjected ? "\(entry.taskID)@\(entry.day)" : entry.taskID
        case .followUp: id = "followup:\(entry.taskID)"
        }
        return [
            "id": id,
            "taskID": entry.taskID,
            "kind": entry.kind.rawValue,
            "title": entry.title,
            "start": start,
            "end": end,
            "allDay": entry.time == nil,
            "calendarId": ShiftCalendarCategory(entry: entry).rawValue,
            "projected": entry.isProjected,
            "completed": entry.isCompleted,
            "movable": entry.isMovable,
        ]
    }

    static let timedBlockMinutes = 30

    /// Schedule-X accepts a locale only in `ll-RR` form and throws on
    /// anything else ("en", "zh-Hans-CN"), so the captain's locale is reduced
    /// to that shape, and falls back to `en-US` when it has no region.
    static func scheduleXLocale(_ locale: Locale) -> String {
        guard let language = locale.language.languageCode?.identifier,
              let region = locale.region?.identifier,
              language.count == 2, region.count == 2,
              language.allSatisfy(\.isLowercase), region.allSatisfy(\.isUppercase) else { return "en-US" }
        return "\(language)-\(region)"
    }

    /// Schedule-X numbers weekdays Monday = 1 ... Sunday = 7; `Calendar`
    /// numbers them Sunday = 1 ... Saturday = 7.
    static func scheduleXFirstDayOfWeek(_ calendar: Calendar) -> Int {
        calendar.firstWeekday == 1 ? 7 : calendar.firstWeekday - 1
    }

    /// The first call the page gets, once it reports ready.
    static func configuration(theme: HelmTheme, scale: ShiftCalendarScale,
                              calendar: Calendar = .current, locale: Locale = .current,
                              timeZone: TimeZone = .current) -> [String: Any] {
        [
            "timeZone": timeZone.identifier,
            "locale": scheduleXLocale(locale),
            "firstDayOfWeek": scheduleXFirstDayOfWeek(calendar),
            "view": scale.rawValue,
            "dark": theme.mode == .dark,
            "theme": ShiftCalendarPalette.themePayload(for: theme),
            "calendars": ShiftCalendarPalette.calendars(for: theme),
        ]
    }

    private static func minutes(of hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

// MARK: - What each colour means

/// The calendar's colour categories, one per kind of record, and the legend
/// under the grid that names them.
///
/// A task is coloured by its priority and a follow-up by being one. Both are
/// real fields every record has, which is why the calendar colours by them
/// rather than by project: most tasks carry no project, and a calendar where
/// nearly every chip is the one no-project grey says nothing. The mapping is
/// fixed, so a colour means the same thing in every month and every theme.
enum ShiftCalendarCategory: String, CaseIterable {
    case high = "kind-high"
    case normal = "kind-normal"
    case low = "kind-low"
    case followUp = "kind-followup"

    init(entry: ShiftCalendarEntry) {
        guard entry.kind == .task else { self = .followUp; return }
        switch entry.priority {
        case .high: self = .high
        case .normal: self = .normal
        case .low: self = .low
        }
    }

    /// The legend's words.
    var title: String {
        switch self {
        case .high: return "High priority"
        case .normal: return "Normal priority"
        case .low: return "Low priority"
        case .followUp: return "Follow-up"
        }
    }

    /// A semantic hue, resolved per theme, so every palette supplies its own:
    /// the theme's red for urgent, its green for low, its amber for a
    /// follow-up, which is a thing to check on, and its violet for the
    /// commonest case, which must not read as a warning.
    var tint: HelmTint {
        switch self {
        case .high: return .critical
        case .normal: return .violet
        case .low: return .good
        case .followUp: return .warn
        }
    }
}

// MARK: - The palette

/// The app theme, as Schedule-X's CSS variables.
///
/// Schedule-X themes itself through Material-style roles (`primary`,
/// `surface`, `on-surface`, `outline` ...), declared once for light and again
/// under `.is-dark`. The page writes these over both registers, so the
/// calendar follows the *app* theme (never the terminal's colours) and has no
/// purple left in it. Every text role goes through the same quantised contrast
/// correction Code Preview's palette uses (`CodePreviewTheme.legibleHex`), so a
/// colour that clears the floor as an `NSColor` and misses it as the shipped
/// `#rrggbb` cannot reach the page.
enum ShiftCalendarPalette {

    /// The roles the page must receive; `ShiftCalendarSelfTest` asserts every
    /// one is present, so a role dropped here cannot quietly fall back to
    /// Schedule-X's default purple.
    static let requiredVariables: [String] = [
        "--sx-color-primary", "--sx-color-on-primary",
        "--sx-color-primary-container", "--sx-color-on-primary-container",
        "--sx-color-secondary", "--sx-color-on-secondary",
        "--sx-color-secondary-container", "--sx-color-on-secondary-container",
        "--sx-color-tertiary", "--sx-color-on-tertiary",
        "--sx-color-tertiary-container", "--sx-color-on-tertiary-container",
        "--sx-color-surface", "--sx-color-surface-dim", "--sx-color-surface-bright",
        "--sx-color-on-surface",
        "--sx-color-surface-container", "--sx-color-surface-container-low",
        "--sx-color-surface-container-high",
        "--sx-color-background", "--sx-color-on-background",
        "--sx-color-outline", "--sx-color-outline-variant",
        "--sx-color-neutral", "--sx-color-neutral-variant",
        "--sx-color-shadow", "--sx-color-surface-tint",
        "--sx-internal-color-gray-ripple-background", "--sx-internal-color-light-gray",
        "--sx-internal-color-text",
        "--gl-now-line", "--gl-accent-ink",
        // The card and its cells (task-calendar.css).
        "--gl-ground", "--gl-card", "--gl-card-edge", "--gl-cell", "--gl-cell-dim",
        "--gl-ink", "--gl-muted", "--gl-faint", "--gl-control-edge", "--gl-control-hover",
    ]

    /// Every CSS variable, resolved from `theme`.
    static func variables(for theme: HelmTheme) -> [String: String] {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let inkColor = HelmTheme.nsColor(theme.chromeInkHex)
        let ink = CodePreviewTheme.legibleHex(inkColor, on: surface)
        let muted = CodePreviewTheme.legibleHex(opaque(HelmTheme.mutedInk(theme), over: surface), on: surface)
        let well = HelmField.fill(theme)
        let wellHex = CodePreviewTheme.hex(well)
        let line = CodePreviewTheme.hex(opaque(HelmField.border(theme), over: surface))
        let accent = HelmTheme.nsColor(theme.accentHex)
        // Text on a fill is measured against the fill *as shipped*: both
        // sides cross the bridge as 8-bit hex, and `legibleOn`'s answer lands
        // just over the floor by construction, so rounding either side can
        // take it under (measured 4.47-4.49:1 on seven themes).
        let onAccent = CodePreviewTheme.legibleHex(inkColor, on: accent)
        let accentWash = HelmContrast.tintedSurface(tintHex: theme.accentHex, theme: theme,
                                                   target: HelmContrast.textTarget)
        let washFill = CodePreviewTheme.hex(accentWash.fill)
        let washInk = CodePreviewTheme.legibleHex(accentWash.foreground, on: quantised(accentWash.fill))
        let surfaceHex = CodePreviewTheme.hex(surface)
        func toward(_ fraction: CGFloat) -> String {
            CodePreviewTheme.hex(surface.blended(withFraction: fraction, of: inkColor) ?? surface)
        }
        let cell = cellFill(theme)
        // A day outside the month sits almost flat on the card: present, so
        // the weeks stay whole, but plainly not this month's.
        let cellDim = CodePreviewTheme.hex(cell.blended(withFraction: 0.8, of: surface) ?? surface)
        let edge = CodePreviewTheme.hex(opaque(HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(theme.isDaylight ? 1 : HelmCard.borderAlpha), over: surface))
        let faint = faintHex(theme, on: HelmTheme.nsColor(String(cellDim.dropFirst())))
        return [
            "--sx-color-primary": "#" + theme.accentHex,
            "--sx-color-on-primary": onAccent,
            "--sx-color-primary-container": washFill,
            "--sx-color-on-primary-container": washInk,
            // Secondary and tertiary are barely used by the views this page
            // offers (the date picker, the view menu). They take the quiet
            // well and the accent wash rather than inventing two more hues.
            "--sx-color-secondary": muted,
            "--sx-color-on-secondary": surfaceHex,
            "--sx-color-secondary-container": wellHex,
            "--sx-color-on-secondary-container": ink,
            "--sx-color-tertiary": "#" + theme.accentHex,
            "--sx-color-on-tertiary": onAccent,
            "--sx-color-tertiary-container": washFill,
            "--sx-color-on-tertiary-container": washInk,
            "--sx-color-surface": surfaceHex,
            "--sx-color-surface-dim": wellHex,
            "--sx-color-surface-bright": surfaceHex,
            "--sx-color-on-surface": ink,
            // The month grid's drag-over day and the menus' hover.
            "--sx-color-surface-container": wellHex,
            "--sx-color-surface-container-low": toward(0.04),
            "--sx-color-surface-container-high": toward(0.12),
            "--sx-color-background": surfaceHex,
            "--sx-color-on-background": ink,
            "--sx-color-outline": muted,
            "--sx-color-outline-variant": line,
            "--sx-color-neutral": muted,
            "--sx-color-neutral-variant": line,
            "--sx-color-shadow": "#000000",
            "--sx-color-surface-tint": "#" + theme.accentHex,
            "--sx-internal-color-gray-ripple-background": wellHex,
            "--sx-internal-color-light-gray": wellHex,
            "--sx-internal-color-text": ink,
            // The default theme draws the now-line in a literal red. This is
            // the theme's own red, used as a line rather than as text.
            "--gl-now-line": "#" + theme.ansiHex[1],
            // Today's weekday name in the week view is text, so it takes the
            // accent corrected for legibility, not the raw fill colour.
            "--gl-accent-ink": CodePreviewTheme.legibleHex(accent, on: surface),
            // The card is a `HelmCard`'s own surface and edge, on the page
            // ground the native pane paints, so it reads as the same card
            // every other page draws.
            "--gl-ground": "#" + theme.backgroundHex,
            "--gl-card": surfaceHex,
            "--gl-card-edge": edge,
            "--gl-cell": CodePreviewTheme.hex(cell),
            "--gl-cell-dim": cellDim,
            "--gl-ink": ink,
            "--gl-muted": CodePreviewTheme.legibleHex(opaque(HelmTheme.mutedInk(theme), over: surface),
                                                      on: quantised(cell)),
            "--gl-faint": faint,
            "--gl-control-edge": line,
            "--gl-control-hover": toward(0.06),
        ]
    }

    /// A day cell: a step from the card toward the page ground, which is the
    /// captain's design (cells sunk a shade into their card), or, where a
    /// palette paints the two the same (`chromeBackgroundHex ==
    /// backgroundHex` in several), the smallest step that still separates
    /// the cell from its card - sinking first, and rising toward ink where
    /// the card is already too close to black to sink from (High contrast
    /// dark: black can only give it 1.05:1).
    static func cellFill(_ theme: HelmTheme) -> NSColor {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ground = HelmTheme.nsColor(theme.backgroundHex)
        let step = theme.mode == .dark ? 0.55 : 0.6
        let towardGround = quantised(surface.blended(withFraction: step, of: ground) ?? surface)
        if HelmContrast.ratio(towardGround, surface) >= cellSeparation { return towardGround }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let targets: [NSColor] = theme.mode == .dark ? [.black, ink] : [ink]
        for target in targets {
            var fraction: CGFloat = 0.01
            while fraction <= 0.3 {
                let fill = quantised(surface.blended(withFraction: fraction, of: target) ?? surface)
                if HelmContrast.ratio(fill, surface) >= cellSeparation { return fill }
                fraction += 0.01
            }
        }
        return towardGround
    }

    /// How far a cell steps from its card: Daylight's own card-over-paper
    /// separation, the same floor a page's nav column clears.
    static let cellSeparation = HelmTheme.sidePanelSeparation

    /// A day number outside the month: quiet, not gone. Muted ink stepped
    /// toward the dimmed cell for as long as it still clears 3:1 against it,
    /// the large-text floor (WCAG 1.4.3), which a 14pt medium numeral that
    /// is not the month's own is held to here rather than to body text's.
    static let faintTextFloor = 3.0

    static func faintHex(_ theme: HelmTheme, on dimCell: NSColor) -> String {
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let muted = quantised(opaque(HelmTheme.mutedInk(theme), over: surface))
        var best = muted
        var fraction: CGFloat = 0.05
        while fraction <= 0.6 {
            let candidate = quantised(muted.blended(withFraction: fraction, of: dimCell) ?? muted)
            guard HelmContrast.ratio(candidate, dimCell) >= faintTextFloor else { break }
            best = candidate
            fraction += 0.05
        }
        return CodePreviewTheme.hex(best)
    }

    /// `setTheme`'s payload: the variables plus the register, the calendars
    /// and the legend that names them.
    static func themePayload(for theme: HelmTheme) -> [String: Any] {
        ["vars": variables(for: theme), "dark": theme.mode == .dark,
         "calendars": calendars(for: theme), "legend": legend(for: theme)]
    }

    /// The legend under the grid, one item per category in a fixed order.
    static func legend(for theme: HelmTheme) -> [[String: String]] {
        ShiftCalendarCategory.allCases.map { category in
            let colours = colours(for: category, theme: theme)
            return ["id": category.rawValue, "label": category.title,
                    "main": colours["main"] ?? "", "container": colours["container"] ?? ""]
        }
    }

    /// One Schedule-X calendar per category (`ShiftCalendarCategory`).
    ///
    /// A chip is a tinted surface: the fill and the label come from
    /// `HelmContrast.tintedSurface` rather than being picked, because a
    /// `HelmTint` hue is safe as a fill and not automatically as text. The
    /// accent edge is the hue itself. Both registers get the same values: the
    /// page is re-themed on every theme change, so the light/dark pair
    /// Schedule-X asks for is always the active theme's.
    static func calendars(for theme: HelmTheme) -> [String: Any] {
        var out: [String: Any] = [:]
        for category in ShiftCalendarCategory.allCases {
            let colours = colours(for: category, theme: theme)
            out[category.rawValue] = ["colorName": category.rawValue, "lightColors": colours, "darkColors": colours]
        }
        return out
    }

    /// One category's three colours: the edge, the chip's fill and its text.
    static func colours(for category: ShiftCalendarCategory, theme: HelmTheme) -> [String: String] {
        let hex = category.tint.hex(in: theme)
        let surface = HelmContrast.tintedSurface(tintHex: hex, theme: theme, target: HelmContrast.textTarget)
        return [
            "main": "#" + hex,
            "container": CodePreviewTheme.hex(surface.fill),
            "onContainer": CodePreviewTheme.legibleHex(surface.foreground, on: quantised(surface.fill)),
        ]
    }

    /// `color` as the page will receive it: rounded to 8 bits per channel.
    static func quantised(_ color: NSColor) -> NSColor {
        HelmTheme.nsColor(String(CodePreviewTheme.hex(color).dropFirst()))
    }

    /// A translucent colour composited over an opaque one, as an opaque
    /// colour - what the page needs, since a CSS variable's alpha would be
    /// composited over whatever happens to be underneath it.
    static func opaque(_ color: NSColor, over base: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let alpha = rgb.alphaComponent
        guard alpha < 1 else { return rgb }
        return base.blended(withFraction: alpha, of: rgb.withAlphaComponent(1)) ?? base
    }
}

// MARK: - Rescheduling

/// What a drop does to a task. Pure, so the rule is tested without a page.
enum ShiftCalendarReschedule {

    enum Outcome: Equatable {
        /// Write this task.
        case moved(ShiftTask)
        /// Nothing to write: the drop landed where the task already was.
        case unchanged
        /// The drop is refused, and the page is told by being redrawn.
        case refused(String)
    }

    /// A drop of `task` on `day`, at `time` when it landed in a time grid.
    ///
    /// An all-day task stays all-day wherever it lands: a time is only
    /// adopted by a task that already had one. That keeps a drop in the month
    /// grid (which carries no time of its own) from inventing one, and keeps
    /// "due on this day" from silently becoming "due at 9:00".
    static func apply(task: ShiftTask, day: String, time: String?) -> Outcome {
        guard task.status != .completed, task.status != .cancelled else {
            return .refused("A finished task can't be moved.")
        }
        guard ShiftDateFormatting.date(from: day) != nil, day.count == 10 else {
            return .refused("That isn't a day the calendar can save.")
        }
        let newTime: String? = task.dueTime == nil ? nil : (time ?? task.dueTime)
        if let newTime, !isClock(newTime) {
            return .refused("That isn't a time the calendar can save.")
        }
        guard day != task.dueDate || newTime != task.dueTime else { return .unchanged }
        var moved = task
        moved.dueDate = day
        moved.dueTime = newTime
        return .moved(moved)
    }

    /// A drop of a follow-up. The same rule as a task's: a follow-up with no
    /// time stays dated only, and a done one cannot move.
    enum FollowUpOutcome: Equatable {
        case moved(ShiftFollowUp)
        case unchanged
        case refused(String)
    }

    static func apply(followUp: ShiftFollowUp, day: String, time: String?) -> FollowUpOutcome {
        guard followUp.status == .pending else { return .refused("A finished follow-up can't be moved.") }
        guard ShiftDateFormatting.date(from: day) != nil, day.count == 10 else {
            return .refused("That isn't a day the calendar can save.")
        }
        let newTime: String? = followUp.followUpTime == nil ? nil : (time ?? followUp.followUpTime)
        if let newTime, !isClock(newTime) {
            return .refused("That isn't a time the calendar can save.")
        }
        guard day != followUp.followUpAt || newTime != followUp.followUpTime else { return .unchanged }
        var moved = followUp
        moved.followUpAt = day
        moved.followUpTime = newTime
        return .moved(moved)
    }

    private static func isClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (0..<24).contains(h) && (0..<60).contains(m)
    }
}

// MARK: - The view

/// The calendar: the Schedule-X page, and - in the sidebar layout - the
/// mockup's heading with a caption stating what is in the visible period.
/// The floating bar's drill header states that caption itself (the
/// controller's `drillHeaderSubtitle`), so there it is not drawn twice. The
/// page draws its own card (the captain's raised card,
/// with its header, weekday row and legend), so this view only hosts it and
/// fills whatever its page gives it. The page is not loaded until the view is
/// first shown, so a session that never opens the calendar pays nothing for
/// it.
final class ShiftCalendarView: NSView {

    /// Opens the task behind an event, through the one task editor
    /// (`ShiftRecordSheets`).
    var onOpenTask: ((String) -> Void)?
    /// Opens the follow-up behind an event.
    var onOpenFollowUp: ((String) -> Void)?
    /// A new task on a double-clicked day, at a time when one was clicked.
    var onAddTask: ((_ day: String, _ time: String?) -> Void)?
    /// A dropped task. The controller decides; see this file's header.
    var onMoveTask: ((_ taskID: String, _ day: String, _ time: String?) -> Void)?
    /// A dropped follow-up.
    var onMoveFollowUp: ((_ id: String, _ day: String, _ time: String?) -> Void)?
    /// The visible period or the view changed: the caption and the scale
    /// may both be new.
    var onPeriodChanged: (() -> Void)?

    private(set) var scale: ShiftCalendarScale = .month

    private let captionLabel = NSTextField(labelWithString: "")
    /// The sidebar layout's "Calendar" heading, the captain's mockup's. The
    /// shell's module header draws no title there (only a subtitle), so the
    /// page draws its own, with the period's count beside it.
    private let headingLabel = NSTextField(labelWithString: "")
    private let host = NSView()
    private let webView = ShiftCalendarWebView()
    /// Built only when this machine has no bundle, which is never on a
    /// normal install.
    private var missingBundleState: HelmEmptyState?
    /// Drawn only with the heading: the card starts at the top until then.
    private var headingRow: [NSLayoutConstraint] = []
    private var hostTopToSelf: NSLayoutConstraint?

    private var tasks: [ShiftTask] = []
    private var followUps: [ShiftFollowUp] = []
    /// The period the page last reported, as `YYYY-MM-DD` strings. Until the
    /// first report it is the month grid around today, which is what the page
    /// opens on.
    private var visibleRange: (start: String, end: String)?
    /// The day the page is focused on, as it last reported it.
    private(set) var focusedDay: String?
    /// The period on screen, once the page has reported one.
    var visibleDays: (start: String, end: String)? { visibleRange }
    private var isConfigured = false
    private(set) var lastEventsPayload: [[String: Any]] = []
    private(set) var caption = ""

    /// The calendar's floor. The page fills the height its page gives it, so
    /// month view's cells grow with the window; below this the month grid's
    /// six weeks stop fitting two chips a day.
    static let minimumHeight: CGFloat = 520

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = HelmType.captionSmall()
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)

        headingLabel.font = HelmType.pageTitle()
        headingLabel.lineBreakMode = .byTruncatingTail
        headingLabel.translatesAutoresizingMaskIntoConstraints = false
        headingLabel.isHidden = true
        captionLabel.isHidden = true
        headingLabel.setContentHuggingPriority(.required, for: .horizontal)
        headingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(headingLabel)
        addSubview(captionLabel)
        addSubview(host)
        let toSelf = host.topAnchor.constraint(equalTo: topAnchor)
        hostTopToSelf = toSelf
        headingRow = [
            headingLabel.topAnchor.constraint(equalTo: topAnchor),
            headingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            captionLabel.firstBaselineAnchor.constraint(equalTo: headingLabel.firstBaselineAnchor),
            captionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: headingLabel.trailingAnchor, constant: HelmMetrics.s4),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            host.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: HelmMetrics.s3),
        ]
        NSLayoutConstraint.activate([
            toSelf,
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        webView.onReady = { [weak self] in self?.pageDidBecomeReady() }
        webView.onPageError = { message in
            AppLog.lifecycle.error("task calendar page error: \(message, privacy: .public)")
        }
        webView.onRangeChanged = { [weak self] view, start, end in
            guard let self else { return }
            self.scale = ShiftCalendarScale(rawValue: view) ?? self.scale
            self.visibleRange = (start, end)
            self.focusedDay = self.webView.focusedDay
            self.pushEvents()
            self.onPeriodChanged?()
        }
        webView.onOpenTask = { [weak self] id in self?.onOpenTask?(id) }
        webView.onOpenFollowUp = { [weak self] id in self?.onOpenFollowUp?(id) }
        webView.onAddTask = { [weak self] day, time in self?.onAddTask?(day, time) }
        webView.onMoveTask = { [weak self] id, day, time in self?.onMoveTask?(id, day, time) }
        webView.onMoveFollowUp = { [weak self] id, day, time in self?.onMoveFollowUp?(id, day, time) }

        applyTheme(ThemeManager.shared.theme)
        refreshCaption()
    }

    /// The sidebar layout's heading: `title` large on the left and the
    /// period's count beside it, trailing. Once, and never undone (the layout
    /// is chosen at launch).
    func showHeading(_ title: String) {
        guard headingLabel.isHidden else { return }
        headingLabel.stringValue = title
        headingLabel.isHidden = false
        captionLabel.isHidden = false
        hostTopToSelf?.isActive = false
        NSLayoutConstraint.activate(headingRow)
    }

    var showsHeading: Bool { !headingLabel.isHidden }

    // MARK: Loading

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activateIfShowing()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        activateIfShowing()
    }

    /// Loads the page the first time the calendar is genuinely on screen, or
    /// puts up the "no bundle" state when this machine has none.
    private func activateIfShowing() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, !webView.hasLoaded else { return }
        if !webView.activate() { showMissingBundle() }
    }

    private func showMissingBundle() {
        webView.isHidden = true
        guard missingBundleState == nil else { return }
        let state = HelmEmptyState(symbol: "calendar.badge.exclamationmark",
                                   title: "Calendar unavailable",
                                   body: ShiftCalendarAssets.missingBundleMessage)
        state.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(state)
        NSLayoutConstraint.activate([
            state.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            state.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            state.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48),
        ])
        missingBundleState = state
    }

    private func pageDidBecomeReady() {
        isConfigured = false
        let theme = ThemeManager.shared.theme
        webView.call("configure", payload: ShiftCalendarPayload.configuration(theme: theme, scale: scale)) {
            [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                AppLog.lifecycle.error("task calendar: configure failed: \(error.message, privacy: .public)")
                return
            }
            self.isConfigured = true
            self.pushEvents()
        }
    }

    // MARK: Views

    /// Shows `scale`, through the page's own pill handler, so a toolbar tab
    /// and a pill in the card are one path. Before the page is up it is the
    /// view the page opens on.
    func show(scale: ShiftCalendarScale) {
        guard scale != self.scale else { return }
        self.scale = scale
        onPeriodChanged?()
        guard isConfigured else { return }
        webView.call("setView", payload: ["view": scale.rawValue]) { result in
            if case .failure(let error) = result {
                AppLog.lifecycle.error("task calendar: setView failed: \(error.message, privacy: .public)")
            }
        }
    }

    // MARK: Data

    func configure(tasks: [ShiftTask], followUps: [ShiftFollowUp] = []) {
        self.tasks = tasks
        self.followUps = followUps
        pushEvents()
    }

    /// Recomputes the visible period's entries, states them in the caption,
    /// and hands them to the page when it is up.
    private func pushEvents() {
        let entries = visibleEntries()
        lastEventsPayload = entries.map(ShiftCalendarPayload.event(for:))
        refreshCaption(entries: entries)
        guard isConfigured else { return }
        webView.call("setEvents", payload: ["events": lastEventsPayload]) { result in
            if case .failure(let error) = result {
                AppLog.lifecycle.error("task calendar: setEvents failed: \(error.message, privacy: .public)")
            }
        }
    }

    private func visibleEntries() -> [ShiftCalendarEntry] {
        let calendar = Calendar.current
        let start: Date
        let end: Date
        if let visibleRange,
           let s = ShiftDateFormatting.date(from: visibleRange.start),
           let e = ShiftDateFormatting.date(from: visibleRange.end) {
            start = s
            end = calendar.date(byAdding: .day, value: 1, to: e) ?? e
        } else {
            let (s, days) = ShiftCalendarModel.range(for: Date(), scale: .month, calendar: calendar)
            start = s
            end = calendar.date(byAdding: .day, value: days, to: s) ?? s
        }
        return ShiftCalendarModel.entries(tasks: tasks, followUps: followUps,
                                          from: start, through: end.addingTimeInterval(-1), calendar: calendar)
    }

    private func refreshCaption(entries: [ShiftCalendarEntry]? = nil) {
        let list = entries ?? visibleEntries()
        let tasksOnly = list.filter { $0.kind == .task }
        caption = Self.subtitle(total: tasksOnly.count, projected: tasksOnly.filter(\.isProjected).count,
                                followUps: list.count - tasksOnly.count)
        captionLabel.stringValue = caption
    }

    /// GL-14: "nothing in this period" is a real, stated answer, never a
    /// blank grid the reader has to interpret. The projected count is stated
    /// separately because a month showing 40 events of which 35 are
    /// projections is a different fact from a month with 40 real tasks.
    static func subtitle(total: Int, projected: Int, followUps: Int = 0) -> String {
        guard total + followUps > 0 else { return "Nothing scheduled in this period." }
        let real = total - projected
        var parts: [String] = []
        if real > 0 || total > 0 { parts.append(real == 1 ? "1 task" : "\(real) tasks") }
        if followUps > 0 { parts.append(followUps == 1 ? "1 follow-up" : "\(followUps) follow-ups") }
        var text = parts.joined(separator: " and ")
        if projected > 0 { text += ", \(projected) projected from a repeat rule" }
        return text + " in this period. Drag one to move its date."
    }

    // MARK: Theme

    /// GL-24: a repaint, never a fetch - the events are already in the page,
    /// and only their colours change.
    func applyTheme(_ theme: HelmTheme) {
        captionLabel.textColor = HelmTheme.mutedInk(theme)
        headingLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        // AGENTS.md's theming rule: a themed view forces its appearance, or
        // anything resolving a system colour (the web view's own scrollers)
        // follows the OS instead of the theme.
        host.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        guard isConfigured else { return }
        webView.call("setTheme", payload: ShiftCalendarPalette.themePayload(for: theme)) { result in
            if case .failure(let error) = result {
                AppLog.lifecycle.error("task calendar: setTheme failed: \(error.message, privacy: .public)")
            }
        }
    }

    // MARK: Debug hooks (GL-27)

    #if FM_SELFTESTS
    var debugWebView: ShiftCalendarWebView { webView }
    var debugCaption: String { captionLabel.stringValue }
    var debugHeading: NSTextField { headingLabel }
    var debugCaptionLabel: NSTextField { captionLabel }
    var debugIsConfigured: Bool { isConfigured }
    var debugShowsMissingBundle: Bool { missingBundleState != nil }
    var debugEventIDs: [String] { lastEventsPayload.compactMap { $0["id"] as? String } }
    #endif
}
