// Grand Line - native macOS app.
//
// F-01 of full review 4: your real calendar beside your tasks.
//
// The Mac's own calendars - whatever accounts the Calendar app already has,
// iCloud, Google or Exchange - are read through EventKit, read-only, and
// shown in the Tasks page's Calendar view beside the tasks. Home's hero
// names the first meeting, the view says how much of today is free, and a
// task dropped onto a meeting is offered the next free gap instead.
//
// **Nothing leaves the Mac and no account is added.** EventKit reads what
// the system already holds; this file never writes an event, never asks for
// a credential, and keeps no copy of an event on disk. The one thing stored
// is which calendars the captain chose to show (by identifier, in
// preferences).
//
// **Asked once.** Access is requested only when the captain presses "Show my
// calendars". Until then, and after a refusal, the tasks show exactly as
// before; a refusal is said ("Calendar access is off in System Settings,
// Privacy, Calendars") with a button to that setting, never as an empty
// calendar (GL-14).
//
// The Google path this replaces was removed (docs/history/43); EventKit is
// local.

import AppKit
import EventKit

// MARK: - A meeting

struct MacMeeting: Equatable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String
    var calendarTitle: String
    var calendarSource: String
    /// The calendar's own colour, as hex, for the nearest identity hue.
    var colorHex: String
    var location: String?
    var organizer: String?
    var attendeeCount: Int

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct MacCalendarInfo: Equatable, Identifiable {
    var id: String
    var title: String
    var source: String
    var colorHex: String
}

// MARK: - The rules

enum MacCalendarRules {

    /// A gap shorter than this is not "free".
    static let minimumGap: TimeInterval = 30 * 60
    /// The working day the free time is counted inside.
    static let dayStartHour = 9
    static let dayEndHour = 18

    /// The free stretches of `day` between `dayStartHour` and `dayEndHour`
    /// that no timed meeting covers, from `from` onwards (so "free today"
    /// does not count the morning already gone).
    static func freeGaps(on day: Date, meetings: [MacMeeting], from: Date? = nil,
                         minimum: TimeInterval = minimumGap, calendar: Calendar = .current) -> [DateInterval] {
        guard let start = calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: day),
              let end = calendar.date(bySettingHour: dayEndHour, minute: 0, second: 0, of: day) else { return [] }
        var cursor = max(start, from ?? start)
        var gaps: [DateInterval] = []
        let busy = meetings.filter { !$0.isAllDay && $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
        for meeting in busy {
            if meeting.start > cursor, meeting.start.timeIntervalSince(cursor) >= minimum {
                gaps.append(DateInterval(start: cursor, end: min(meeting.start, end)))
            }
            cursor = max(cursor, meeting.end)
        }
        if end > cursor, end.timeIntervalSince(cursor) >= minimum { gaps.append(DateInterval(start: cursor, end: end)) }
        return gaps
    }

    /// Whether a block starting at `start` for `length` overlaps a timed
    /// meeting.
    static func overlaps(start: Date, length: TimeInterval, meetings: [MacMeeting]) -> MacMeeting? {
        let block = DateInterval(start: start, duration: length)
        return meetings.first { !$0.isAllDay && DateInterval(start: $0.start, end: max($0.start, $0.end)).intersects(block)
            && $0.end > start && $0.start < block.end }
    }

    /// The next gap of at least `length` from `after`, looking `days` ahead.
    static func nextGap(after: Date, length: TimeInterval, meetings: [MacMeeting], days: Int = 7,
                        calendar: Calendar = .current) -> Date? {
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: after)) else { continue }
            let gaps = freeGaps(on: day, meetings: meetings, from: offset == 0 ? after : nil, minimum: length, calendar: calendar)
            if let first = gaps.first { return first.start }
        }
        return nil
    }

    /// The first timed meeting still to come today, or nil.
    static func firstMeeting(after now: Date, meetings: [MacMeeting], calendar: Calendar = .current) -> MacMeeting? {
        meetings.filter { !$0.isAllDay && $0.end > now && calendar.isDate($0.start, inSameDayAs: now) }
            .sorted { $0.start < $1.start }.first
    }

    /// "2h 30m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "H:mm"
        return f.string(from: date)
    }

    /// "Your first meeting is Platform stand-up at 9:30, in 18 minutes." -
    /// Home's hero sentence.
    static func firstMeetingSentence(_ meeting: MacMeeting, now: Date) -> String {
        let minutes = Int(meeting.start.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "\(meeting.title) is on now, until \(clock(meeting.end))." }
        let when = minutes < 60 ? "in \(minutes) minute\(minutes == 1 ? "" : "s")" : "in \(duration(TimeInterval(minutes * 60)))"
        return "Your first meeting is \(meeting.title) at \(clock(meeting.start)), \(when)."
    }

    /// A meeting link's path, kept short and its identifying part masked:
    /// "zoom.us/j/••••4471".
    static func maskedLocation(_ location: String?) -> String? {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else { return nil }
        guard let url = URL(string: location), let host = url.host else { return location }
        let tail = url.path.split(separator: "/").last.map(String.init) ?? ""
        let digits = tail.suffix(4)
        let firstPath = url.path.split(separator: "/").first.map { "/\($0)" } ?? ""
        return tail.count > 4 ? "\(host)\(firstPath)/\u{2022}\u{2022}\u{2022}\u{2022}\(digits)" : host
    }

    /// The identity hue nearest a calendar's own colour.
    static func hue(forHex hex: String) -> HelmDomainHue {
        func rgb(_ h: String) -> (Double, Double, Double) {
            let v = Int(h, radix: 16) ?? 0
            return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
        }
        let target = rgb(hex)
        let hues: [HelmDomainHue] = [.blue, .teal, .green, .amber, .rose, .violet, .slate]
        return hues.min { a, b in
            func distance(_ hue: HelmDomainHue) -> Double {
                let c = rgb(hue.categoricalHex)
                return pow(c.0 - target.0, 2) + pow(c.1 - target.1, 2) + pow(c.2 - target.2, 2)
            }
            return distance(a) < distance(b)
        } ?? .slate
    }

    /// The calendar a meeting is drawn with on the page.
    static func calendarID(for meeting: MacMeeting) -> String {
        ShiftCalendarPalette.meetingCalendarID(hue(forHex: meeting.colorHex))
    }
}

// MARK: - The source

/// The one EventKit reader. Read-only, and nothing is cached on disk.
final class MacCalendarSource {

    static let shared = MacCalendarSource()

    enum Access: Equatable {
        case notAsked
        case granted
        case denied
    }

    private lazy var store = EKEventStore()
    /// Replaced in a self-test, which hands it meetings directly.
    var meetingsProvider: ((DateInterval) -> [MacMeeting])?
    var accessProvider: (() -> Access)?
    var calendarsProvider: (() -> [MacCalendarInfo])?
    private var observers: [() -> Void] = []
    private var changeObserver: NSObjectProtocol?

    func observe(_ handler: @escaping () -> Void) {
        observers.append(handler)
        if changeObserver == nil, !ProcessMode.current.isIsolated {
            changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) {
                [weak self] _ in self?.observers.forEach { $0() }
            }
        }
    }

    var access: Access {
        if let accessProvider { return accessProvider() }
        guard !ProcessMode.current.isIsolated else { return .notAsked }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        default:
            if #available(macOS 14.0, *) {
                return EKEventStore.authorizationStatus(for: .event) == .writeOnly ? .denied : .granted
            }
            return .granted
        }
    }

    /// Whether the calendars show at all: asked and allowed, and not turned
    /// off on the page.
    var isShowing: Bool { access == .granted && AppSettings.shared.macCalendarsShown }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                AppSettings.shared.macCalendarsShown = granted
                completion(granted)
                self?.observers.forEach { $0() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in finish(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in finish(granted) }
        }
    }

    func calendars() -> [MacCalendarInfo] {
        if let calendarsProvider { return calendarsProvider() }
        guard access == .granted, meetingsProvider == nil else { return [] }
        return store.calendars(for: .event).map {
            MacCalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "",
                            colorHex: Self.hex($0.color))
        }.sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// The meetings in `interval`, from the chosen calendars.
    func meetings(in interval: DateInterval) -> [MacMeeting] {
        if let meetingsProvider { return meetingsProvider(interval) }
        guard isShowing else { return [] }
        let hidden = AppSettings.shared.macCalendarsHidden
        let calendars = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        return store.events(matching: predicate).map { event in
            MacMeeting(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Busy",
                       start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                       calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
                       calendarSource: event.calendar.source?.title ?? "", colorHex: Self.hex(event.calendar.color),
                       location: event.url?.absoluteString ?? event.location, organizer: event.organizer?.name,
                       attendeeCount: event.attendees?.count ?? 0)
        }
    }

    func meetings(on day: Date, calendar: Calendar = .current) -> [MacMeeting] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return meetings(in: DateInterval(start: start, end: end))
    }

    static func hex(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return "8B8677" }
        return String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")

    /// System Settings, Privacy, Calendars: a fixed pane.
    static func openPrivacySettings() {
        if let url = settingsURL { NSWorkspace.shared.open(url) }
    }
}

// MARK: - A meeting's card

/// The read-only popover a meeting opens: the mock-up's state 4.
final class MacMeetingCard: NSView {

    var onPrepTask: (() -> Void)?

    init(meeting: MacMeeting) {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 220))
        let theme = ThemeManager.shared.theme
        wantsLayer = true
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        let title = NSTextField(wrappingLabelWithString: meeting.title)
        title.font = HelmType.sectionTitle()
        title.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        title.preferredMaxLayoutWidth = 240
        let pill = HelmStatusPill(style: .pill)
        pill.configure(text: "Read-only", tint: .neutral, theme: theme)
        let head = NSStackView(views: [title, pill])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = HelmMetrics.s2
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM, H:mm"
        let when = meeting.isAllDay ? "All day" : "\(f.string(from: meeting.start)) to \(MacCalendarRules.clock(meeting.end))"
        var rows: [(String, String)] = [("When", when),
                                        ("Calendar", meeting.calendarSource.isEmpty ? meeting.calendarTitle
                                            : "\(meeting.calendarTitle) (\(meeting.calendarSource))")]
        if meeting.attendeeCount > 0 || meeting.organizer != nil {
            var people = meeting.attendeeCount > 0 ? "\(meeting.attendeeCount)" : ""
            if let organizer = meeting.organizer { people += people.isEmpty ? "Organised by \(organizer)" : ", organised by \(organizer)" }
            rows.append(("People", people))
        }
        if let place = MacCalendarRules.maskedLocation(meeting.location) { rows.append(("Where", place)) }
        let grid = NSGridView(views: rows.map { label, value in
            let l = NSTextField(labelWithString: label)
            l.font = HelmType.caption()
            l.textColor = HelmTheme.mutedInk(theme)
            let v = NSTextField(wrappingLabelWithString: value)
            v.font = HelmType.body()
            v.textColor = HelmTheme.nsColor(theme.chromeInkHex)
            v.preferredMaxLayoutWidth = 230
            return [l, v]
        })
        grid.rowSpacing = HelmMetrics.s2
        grid.columnSpacing = HelmMetrics.s3
        grid.column(at: 0).width = 64
        let open = HelmButton(title: "Open in Calendar", variant: .secondary, size: .small, symbol: "calendar",
                              target: self, action: #selector(openCalendar))
        let prep = HelmButton(title: "Prep task before it", variant: .primary, size: .small, symbol: "checkmark.circle",
                              target: self, action: #selector(prepTapped))
        let buttons = NSStackView(views: [open, prep])
        buttons.spacing = HelmMetrics.s2
        let stack = NSStackView(views: [head, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 340),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func openCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    @objc private func prepTapped() { onPrepTask?() }
}
