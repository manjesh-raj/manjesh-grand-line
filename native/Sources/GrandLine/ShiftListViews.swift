// Grand Line - native macOS app.
//
// Shift's shared list pieces: the round check badge every task and
// follow-up row draws, the project tag the List tab's and the Follow-ups
// card's tables draw, the Snooze presets, and the day formatting the page,
// the board and the calendar share.
//
// This file used to hold the page's flat task and follow-up lists, the
// `NSTableView`-based "My Tasks" and Follow-ups panels of the floating-bar
// layout. The List tab's table and the Follow-ups card's table
// (`HelmDataTable`) replaced both, and P-03 of the 2026-11-25 review removed
// them with that layout.

import AppKit

// MARK: - The check badge

/// A real, clickable checkbox styled as a small round tinted tile (the
/// notification card's own "icon in a badge" idiom, `IconTileView`'s circular
/// cousin) rather than a bare system checkbox floating on its own - still a
/// genuine `NSButton` with a real target/action, so click-to-toggle-complete
/// is byte-for-byte the same behavior as before this restyle, only the
/// drawing changed. The List tab's and the Follow-ups card's tables draw it
/// in their check column, and `ShiftProjectDetailView.swift`'s task/subtask
/// checklist rows reuse it (`fm/grandline-shift-project-detail-theming`)
/// rather than hand-rolling a second tinted-circle checkbox.
final class ShiftTaskCheckBadge: NSButton {
    static let size: CGFloat = 26

    private let diameter: CGFloat

    init(size: CGFloat = ShiftTaskCheckBadge.size) {
        diameter = size
        super.init(frame: .zero)
        title = ""
        isBordered = false
        imagePosition = .imageOnly  // HelmIconButton-exempt: the list row check badge, a toggle sized with its row
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.borderWidth = 1.5
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.checkBox)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// `tint` drives both the outline (unchecked) and the fill (checked).
    func setChecked(_ checked: Bool, tint: NSColor) {
        image = checked
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Completed")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: diameter * 0.42, weight: .bold))
            : nil
        contentTintColor = .white
        layer?.backgroundColor = checked ? tint.cgColor : NSColor.clear.cgColor
        layer?.borderColor = tint.cgColor
        setAccessibilityValue(checked)
        toolTip = checked ? "Mark incomplete" : "Mark complete"
    }
}

// MARK: - The project tag

/// A project's dot and name, as the List tab's Project column and the
/// prototype's table draw it - the hue its board cards use.
final class ShiftProjectTag: NSView {
    static let dotSide = HelmMetrics.s2

    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    init(name: String, hex: String, theme: HelmTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        dot.layer?.backgroundColor = HelmTheme.nsColor(hex).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = name
        label.font = HelmType.body()
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - Snooze

/// The Snooze preset options (phase 2 acceptance criteria). `.custom` opens a
/// small date/time picker sheet, which `ShiftController` presents.
enum ShiftSnoozeOption {
    case minutes30, hour1, tomorrow, nextWeek, custom
}

// MARK: - Shared date formatting

enum ShiftDateFormatting {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private static let friendlyTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jm")
        return f
    }()

    static func date(from yyyyMMdd: String) -> Date? { iso.date(from: yyyyMMdd) }

    /// A wall-clock time in the captain's own locale ("1:11 PM", "13:11") -
    /// the same formatter the task rows already use for a due time, so a
    /// capture's timestamp and a task's due time are written the same way
    /// (review X6).
    static func clockTime(_ date: Date) -> String { friendlyTime.string(from: date) }

    /// "Today" / "Tomorrow" / "Aug 12" - never a raw ISO string in the UI.
    static func friendly(_ yyyyMMdd: String) -> String {
        guard let date = date(from: yyyyMMdd) else { return yyyyMMdd }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return monthDayFormatter.string(from: date)
    }

    // GL-P3: built once. `DateFormatter` construction is measurably
    // expensive and this carries no per-call state - the same treatment
    // `FleetLogFeed`/`HealthCardView` already give theirs.
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// "16 Sep" - the month-day part alone, with no relative "Today"/
    /// "Tomorrow" substitution.
    ///
    /// Exposed for F22's compact popover (`CompactModeDigest`), which decides
    /// relative wording against an *injected* clock and so cannot use
    /// `friendly(_:)`: that one resolves "Today" against `Calendar.current`
    /// and the real `Date()`, which a suite pinning a fabricated instant
    /// would read as a second, disagreeing clock. Sharing this formatter
    /// rather than building a fourth one is GL-P3's own rule for this file.
    static func monthDay(_ date: Date) -> String { monthDayFormatter.string(from: date) }

    /// "Today at 3:00 PM" / "Aug 12" (no time shown when `hhmm` is nil).
    static func friendly(_ yyyyMMdd: String, time hhmmStr: String?) -> String {
        let dayPart = friendly(yyyyMMdd)
        guard let hhmmStr, let t = hhmm.date(from: hhmmStr) else { return dayPart }
        return "\(dayPart) at \(friendlyTime.string(from: t))"
    }

    /// Just the clock part of an `"HH:MM"` string, in the captain's own
    /// locale ("3:00 PM" / "15:00") - what a calendar chip prefixes a task
    /// title with. Shares `friendly(_:time:)`'s own formatter rather than
    /// building a second one (GL-P3: `DateFormatter` construction is
    /// measurably expensive, and a grid builds one chip per task per day).
    static func clock(_ hhmmStr: String) -> String {
        guard let t = hhmm.date(from: hhmmStr) else { return hhmmStr }
        return friendlyTime.string(from: t)
    }

    /// Combines a `"YYYY-MM-DD"` date string with an optional `"HH:MM"` time
    /// string into one `Date` - the shared "read the two persisted scalar
    /// fields back into a real moment in time" used by both sorting (task due
    /// dates) and Snooze's relative-offset math (follow-up date + time).
    /// Falls back to local midnight when `timeStr` is nil/unparseable.
    static func dateTime(from yyyyMMdd: String?, time timeStr: String?) -> Date? {
        guard let yyyyMMdd, let base = date(from: yyyyMMdd) else { return nil }
        guard let timeStr, let t = hhmm.date(from: timeStr) else { return base }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: base)
        let timeComps = Calendar.current.dateComponents([.hour, .minute], from: t)
        comps.hour = timeComps.hour
        comps.minute = timeComps.minute
        return Calendar.current.date(from: comps)
    }

    /// Splits a real `Date` back into the `("YYYY-MM-DD", "HH:MM")` pair the
    /// YAML layer persists - the inverse of `dateTime(from:time:)`, used by
    /// Snooze to write its recomputed moment back to the two scalar fields.
    static func components(from date: Date) -> (dateStr: String, timeStr: String) {
        (iso.string(from: date), hhmm.string(from: date))
    }
}
