// Grand Line - native macOS app.
//
// The Tasks page's calendar - the third view beside Board and List.
//
// **It is a Schedule-X calendar in a web view** (the captain's choice, after
// the open-source calendar options review): month, week and day views, today's
// highlight, a now-line, and dragging a task to a new day or time. The bundle
// is vendored and offline (`Vendor/ScheduleX/README.md`); this file decides
// what goes into it and what comes back out.
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

/// The three views the calendar offers, by Schedule-X's own view names.
enum ShiftCalendarScale: String, CaseIterable {
    case month = "month-grid"
    case week
    case day

    var title: String {
        switch self {
        case .month: return "Month"
        case .week: return "Week"
        case .day: return "Day"
        }
    }
}

/// One task's appearance on one day.
///
/// A value rather than a view so the placement rules are assertable without a
/// window - which is what lets the recurrence projection be covered by the
/// blocking CI lane rather than only by the windowed one.
struct ShiftCalendarEntry: Equatable {
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

    /// Whether a drag may move this entry. Only a real, open task.
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
        return out.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            // An all-day task sorts above a timed one: it is the day's
            // heading, not an event inside it.
            switch (lhs.time, rhs.time) {
            case let (l?, r?) where l != r: return l < r
            case (nil, .some): return true
            case (.some, nil): return false
            default: return lhs.title < rhs.title
            }
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
        case .month:
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
    /// while every one of them still opens the same task (`taskID`).
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
        return [
            "id": entry.isProjected ? "\(entry.taskID)@\(entry.day)" : entry.taskID,
            "taskID": entry.taskID,
            "title": entry.title,
            "start": start,
            "end": end,
            "calendarId": calendarID(forProjectID: entry.projectID),
            "projected": entry.isProjected,
            "completed": entry.isCompleted,
            "movable": entry.isMovable,
        ]
    }

    static let timedBlockMinutes = 30

    /// A task's colour is its project's, through the same palette the board's
    /// cards use, so one project reads as one colour on every Tasks view.
    static func calendarID(forProjectID id: String?) -> String {
        "tint-\(ShiftProjectPalette.tint(forProjectID: id))"
    }

    /// Every calendar id `calendarID(forProjectID:)` can produce.
    static var allCalendarIDs: [String] {
        (ShiftProjectPalette.tints + [.neutral]).map { "tint-\($0)" }
    }

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
        ]
    }

    /// `setTheme`'s payload: the variables plus the register.
    static func themePayload(for theme: HelmTheme) -> [String: Any] {
        ["vars": variables(for: theme), "dark": theme.mode == .dark,
         "calendars": calendars(for: theme)]
    }

    /// One Schedule-X calendar per project hue, plus one for a task with no
    /// project.
    ///
    /// A project's events are a tinted surface: the fill and the label come
    /// from `HelmContrast.tintedSurface` rather than being picked, because a
    /// `HelmTint` hue is safe as a fill and not automatically as text. The
    /// no-project calendar takes the quiet well with ink text instead, because
    /// `.neutral` is page ink and washing it produces a near-black chip
    /// (AGENTS.md's colour rules record that defect). Both registers get the
    /// same values: the page is re-themed on every theme change, so the
    /// light/dark pair Schedule-X asks for is always the active theme's.
    static func calendars(for theme: HelmTheme) -> [String: Any] {
        var out: [String: Any] = [:]
        for tint in ShiftProjectPalette.tints + [.neutral] {
            let colours: [String: String]
            if tint == .neutral {
                let well = HelmField.fill(theme)
                colours = [
                    "main": CodePreviewTheme.hex(opaque(HelmTheme.mutedInk(theme),
                                                        over: HelmTheme.nsColor(theme.chromeBackgroundHex))),
                    "container": CodePreviewTheme.hex(well),
                    "onContainer": CodePreviewTheme.legibleHex(HelmTheme.nsColor(theme.chromeInkHex),
                                                               on: quantised(well)),
                ]
            } else {
                let surface = HelmContrast.tintedSurface(tintHex: tint.hex(in: theme), theme: theme,
                                                        target: HelmContrast.textTarget)
                colours = [
                    "main": "#" + tint.hex(in: theme),
                    "container": CodePreviewTheme.hex(surface.fill),
                    "onContainer": CodePreviewTheme.legibleHex(surface.foreground, on: quantised(surface.fill)),
                ]
            }
            let id = "tint-\(tint)"
            out[id] = ["colorName": id, "lightColors": colours, "darkColors": colours]
        }
        return out
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

    private static func isClock(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (0..<24).contains(h) && (0..<60).contains(m)
    }
}

// MARK: - The view

/// The calendar tab: a caption stating what is in the visible period, and the
/// Schedule-X page in a card. The page is not loaded until the tab is first
/// shown, so a session that never opens the calendar pays nothing for it.
final class ShiftCalendarView: NSView {

    /// Opens the task behind an event - the same `ShiftController.openBoardTask`
    /// path the board's cards use, so there is one "open a task" in this page.
    var onOpenTask: ((String) -> Void)?
    /// A new task on a double-clicked day, at a time when one was clicked.
    var onAddTask: ((_ day: String, _ time: String?) -> Void)?
    /// A dropped event. The controller decides; see this file's header.
    var onMoveTask: ((_ taskID: String, _ day: String, _ time: String?) -> Void)?

    private(set) var scale: ShiftCalendarScale = .month

    private let captionLabel = NSTextField(labelWithString: "")
    private let card = NSView()
    private let webView = ShiftCalendarWebView()
    /// Built only when this machine has no bundle, which is never on a
    /// normal install.
    private var missingBundleState: HelmEmptyState?
    /// The sidebar layout's card radius - see `adoptWorkspaceStyle`.
    private(set) var usesWorkspaceStyle = false

    private var tasks: [ShiftTask] = []
    private var projects: [ShiftProject] = []
    /// The period the page last reported, as `YYYY-MM-DD` strings. Until the
    /// first report it is the month grid around today, which is what the page
    /// opens on.
    private var visibleRange: (start: String, end: String)?
    private var isConfigured = false
    private(set) var lastEventsPayload: [[String: Any]] = []

    /// The calendar's own height. A required constant is safe here in a way
    /// a required *width* is not (gotcha (13) is about a width reaching the
    /// window): the page is inside a vertical scroll view, so a tall card
    /// scrolls rather than growing the window. Month view fits six weeks in
    /// it, and week and day view scroll their hours inside it.
    static let calendarHeight: CGFloat = 720

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

        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(webView)

        addSubview(captionLabel)
        addSubview(card)
        NSLayoutConstraint.activate([
            captionLabel.topAnchor.constraint(equalTo: topAnchor),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: HelmMetrics.s2),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.heightAnchor.constraint(equalToConstant: Self.calendarHeight),
            webView.topAnchor.constraint(equalTo: card.topAnchor),
            webView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        webView.onReady = { [weak self] in self?.pageDidBecomeReady() }
        webView.onPageError = { message in
            AppLog.lifecycle.error("task calendar page error: \(message, privacy: .public)")
        }
        webView.onRangeChanged = { [weak self] view, start, end in
            guard let self else { return }
            self.scale = ShiftCalendarScale(rawValue: view) ?? self.scale
            self.visibleRange = (start, end)
            self.pushEvents()
        }
        webView.onOpenTask = { [weak self] id in self?.onOpenTask?(id) }
        webView.onAddTask = { [weak self] day, time in self?.onAddTask?(day, time) }
        webView.onMoveTask = { [weak self] id, day, time in self?.onMoveTask?(id, day, time) }

        applyTheme(ThemeManager.shared.theme)
        refreshCaption()
    }

    /// The sidebar layout's card: the prototype's 12pt corners. Once, the
    /// first time the sidebar layout shows the page; never undone.
    func adoptWorkspaceStyle() {
        guard !usesWorkspaceStyle else { return }
        usesWorkspaceStyle = true
        applyTheme(ThemeManager.shared.theme)
    }

    // MARK: Loading

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activateIfShowing()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        activateIfShowing()
    }

    /// Loads the page the first time the tab is genuinely on screen, or puts
    /// up the "no bundle" state when this machine has none.
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
        card.addSubview(state)
        NSLayoutConstraint.activate([
            state.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            state.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            state.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -48),
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

    // MARK: Data

    func configure(tasks: [ShiftTask], projects: [ShiftProject]) {
        self.tasks = tasks
        self.projects = projects
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
        return ShiftCalendarModel.entries(tasks: tasks, from: start, through: end.addingTimeInterval(-1),
                                          calendar: calendar)
    }

    private func refreshCaption(entries: [ShiftCalendarEntry]? = nil) {
        let list = entries ?? visibleEntries()
        captionLabel.stringValue = Self.subtitle(total: list.count, projected: list.filter(\.isProjected).count)
    }

    /// GL-14: "no tasks in this period" is a real, stated answer, never a
    /// blank grid the reader has to interpret. The projected count is stated
    /// separately because a month showing 40 events of which 35 are
    /// projections is a different fact from a month with 40 real tasks.
    static func subtitle(total: Int, projected: Int) -> String {
        guard total > 0 else { return "Nothing scheduled in this period." }
        let real = total - projected
        var text = real == 1 ? "1 task" : "\(real) tasks"
        if projected > 0 { text += ", \(projected) projected from a repeat rule" }
        return text + " in this period. Drag a task to move its due date."
    }

    // MARK: Theme

    /// GL-24: a repaint, never a fetch - the events are already in the page,
    /// and only their colours change.
    func applyTheme(_ theme: HelmTheme) {
        captionLabel.textColor = HelmTheme.mutedInk(theme)
        let radius = usesWorkspaceStyle ? 12 : HelmMetrics.rCard
        HelmCard.applyCardSurface(to: card, theme: theme, cornerRadius: radius, daylightRadius: radius)
        card.layer?.masksToBounds = true
        // AGENTS.md's theming rule: a themed view forces its appearance, or
        // anything resolving a system colour (the web view's own scrollers)
        // follows the OS instead of the theme.
        card.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
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
    var debugIsConfigured: Bool { isConfigured }
    var debugShowsMissingBundle: Bool { missingBundleState != nil }
    var debugEventIDs: [String] { lastEventsPayload.compactMap { $0["id"] as? String } }
    #endif
}
