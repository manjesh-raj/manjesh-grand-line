// Grand Line - native macOS app.
//
// F20's calendar column: today's events, **read-only**, through EventKit.
//
// ## Read-only is a property of this file, not a promise in a comment
//
// The report's F20 entry says "calendar (EventKit, read-only)", and this is
// the only file in the app that imports EventKit. Nothing here calls
// `EKEventStore.save`, `.remove` or `.commit`, nothing constructs an
// `EKEvent`, and the rows this file hands out (`DailyReviewEventRow`) carry
// strings rather than `EKEvent`s - so no caller can reach an event object
// through the daily review even by accident.
// `DailyReviewSelfTest.checkCalendarSourceIsReadOnly` is the guard: it greps
// this file for every EventKit mutation entry point and fails the run if one
// appears. A source guard is the right shape here precisely because the
// behaviour cannot be asserted - a suite must never touch the captain's real
// calendar to prove that it does not write to it.
//
// ## Access, and why the card never prompts on its own
//
// Calendar access is a system prompt, and a briefing card that fires one the
// first time Overview is visited would be exactly the surprise F12's own
// opt-in exists to avoid. So:
//
//   - the column is off until `AppSettings.dailyReviewCalendarEnabled`, which
//     only the captain's own "Show today's calendar" button sets;
//   - until then the section is a stated gap ("not connected"), never a zero;
//   - a denied or restricted status is also a stated gap, with what to do
//     about it.
//
// **And an unbundled build refuses to ask at all.** TCC kills a process that
// requests calendar access with no `NSCalendarsUsageDescription` in its
// `Info.plist`, and `.build/debug/GrandLine` - what every self-test and
// every `swift build` dev run is - has no `Info.plist` whatsoever. So
// `canPrompt` checks for the key and `requestAccess` returns a stated reason
// instead of prompting when it is missing. The keys are added by
// `build_native_app.sh` (and `Scripts/build-probe-app.sh`), which is what
// makes the packaged app the one that can ask.

import AppKit
import EventKit

/// What the app is allowed to read today. Deliberately this app's own enum
/// rather than `EKAuthorizationStatus`: macOS 14 split "authorized" into full
/// and write-only, and a write-only grant is *useless* here (this feature only
/// reads), so it has to map to "not available" rather than to "authorized".
enum DailyReviewCalendarAccess: Equatable {
    case notDetermined
    case denied
    case restricted
    /// Enough access to read events.
    case readable
    /// macOS 14+ write-only: the captain granted something, but not the thing
    /// this feature needs.
    case writeOnly
}

/// The seam. `FleetController` holds one of these; the self-tests hand in a
/// stub, which is what lets the card's calendar column be rendered and
/// asserted without EventKit, without a permission prompt, and without ever
/// reading the captain's real calendar.
protocol DailyReviewCalendarReading: AnyObject {
    var access: DailyReviewCalendarAccess { get }
    /// `true` when asking for access is safe - see the file header's note
    /// about an unbundled binary.
    var canPrompt: Bool { get }
    /// Requests read access. `completion` runs on the main thread exactly
    /// once, with the resulting access.
    func requestAccess(completion: @escaping (DailyReviewCalendarAccess) -> Void)
    /// Today's events, or the reason there are none to show.
    func events(on day: Date) -> DailyReviewAvailability<[DailyReviewEventRow]>
}

/// The real one.
final class EventKitDailyReviewCalendar: DailyReviewCalendarReading {

    /// The keys TCC requires before a process may ask. Both are checked
    /// because macOS 14 introduced the second one and an older system still
    /// reads the first.
    static let usageDescriptionKeys = ["NSCalendarsFullAccessUsageDescription",
                                       "NSCalendarsUsageDescription"]

    /// Built lazily: constructing an `EKEventStore` is not free, and a
    /// captain who never turns the column on should never pay for one.
    private var store: EKEventStore?

    var access: DailyReviewCalendarAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return .readable
            case .writeOnly: return .writeOnly
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            // `.authorized` is the pre-14 spelling and still arrives on a
            // system that granted access before the split.
            case .authorized: return .readable
            @unknown default: return .notDetermined
            }
        }
        // A plain `default`, not `@unknown default`: `.fullAccess` and
        // `.writeOnly` are perfectly *known* cases of `EKAuthorizationStatus`
        // that merely carry an availability annotation, so a switch outside
        // the `#available` branch above is non-exhaustive without them and
        // cannot name them either. CI fails this app's build on any warning,
        // and `@unknown default` here is that warning ("switch must be
        // exhaustive"). The branch above keeps its `@unknown default`, so a
        // genuinely new case still gets diagnosed where it matters.
        switch status {
        case .authorized: return .readable
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        default: return .notDetermined
        }
    }

    var canPrompt: Bool {
        Self.usageDescriptionKeys.contains { key in
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
            return !(value ?? "").isEmpty
        }
    }

    func requestAccess(completion: @escaping (DailyReviewCalendarAccess) -> Void) {
        guard canPrompt else {
            // Not a silent no-op: the caller renders this as the stated gap
            // `unbundledReason` below.
            AppLog.ui.info("daily review: refusing to request calendar access - no usage description in this build")
            DispatchQueue.main.async { completion(.notDetermined) }
            return
        }
        let store = eventStore()
        let finish: (DailyReviewCalendarAccess) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] _, error in
                if let error {
                    AppLog.ui.info("daily review: calendar access request failed (\(error.localizedDescription, privacy: .public))")
                }
                finish(self?.access ?? .notDetermined)
            }
        } else {
            store.requestAccess(to: .event) { [weak self] _, error in
                if let error {
                    AppLog.ui.info("daily review: calendar access request failed (\(error.localizedDescription, privacy: .public))")
                }
                finish(self?.access ?? .notDetermined)
            }
        }
    }

    func events(on day: Date) -> DailyReviewAvailability<[DailyReviewEventRow]> {
        switch access {
        case .notDetermined:
            return .unavailable(canPrompt ? Self.notConnectedReason : Self.unbundledReason)
        case .denied:
            return .unavailable("calendar access is turned off for Grand Line in System Settings \u{203A} Privacy & Security \u{203A} Calendars")
        case .restricted:
            return .unavailable("calendar access is restricted on this Mac, so today\u{2019}s events could not be read")
        case .writeOnly:
            return .unavailable("Grand Line was granted write-only calendar access, which cannot read today\u{2019}s events")
        case .readable:
            break
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = start.addingTimeInterval(24 * 60 * 60)
        let store = eventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // The one EventKit read in the app.
        let found = store.events(matching: predicate)
        let rows = found
            .map { Self.row(for: $0, dayStart: start) }
            .sorted(by: DailyReviewEventRow.isOrderedBefore)
        return .available(rows)
    }

    // MARK: Mapping

    /// One `EKEvent` -> one row of strings. The boundary the file header
    /// describes: nothing past this point holds an event object.
    static func row(for event: EKEvent, dayStart: Date) -> DailyReviewEventRow {
        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return DailyReviewEventRow(
            title: title.isEmpty ? "Untitled event" : title,
            timeText: event.isAllDay ? "all day" : timeFormatter.string(from: event.startDate ?? dayStart),
            detail: detail(for: event),
            colorHex: event.calendar?.color.map(hex(from:)),
            isAllDay: event.isAllDay,
            startsAt: event.startDate ?? dayStart)
    }

    /// "6 attendees \u{00B7} Zoom", either half alone, or empty. The location
    /// is trimmed to its first line: a calendar invite routinely carries a
    /// whole conferencing block in there, and a briefing row is one line.
    static func detail(for event: EKEvent) -> String {
        var parts: [String] = []
        if let attendees = event.attendees, attendees.count > 1 {
            parts.append("\(attendees.count) attendees")
        }
        let location = (event.location ?? "")
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !location.isEmpty {
            parts.append(location.count > 40 ? String(location.prefix(40)) + "\u{2026}" : location)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// A calendar's own colour as `RRGGBB`, so a row can carry it the same way
    /// every other colour in this app travels (`HelmTheme.nsColor(_:)` reads
    /// it back). Converted through sRGB first: a calendar colour arrives in
    /// whatever space Calendar.app stored it in, and `redComponent` traps on a
    /// pattern or catalog colour.
    static func hex(from color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "808080" }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    static let notConnectedReason = "your calendar isn\u{2019}t connected yet - Grand Line has not asked for access"
    static let unbundledReason = "this build cannot read your calendar (no calendar usage description), so nothing is assumed from it"

    private func eventStore() -> EKEventStore {
        if let store { return store }
        let made = EKEventStore()
        store = made
        return made
    }
}

/// The off state, which is a real state rather than an absent source: the
/// captain has not turned the calendar column on, and the card says so.
final class DisabledDailyReviewCalendar: DailyReviewCalendarReading {
    var access: DailyReviewCalendarAccess { .notDetermined }
    var canPrompt: Bool { false }
    func requestAccess(completion: @escaping (DailyReviewCalendarAccess) -> Void) {
        DispatchQueue.main.async { completion(.notDetermined) }
    }
    func events(on day: Date) -> DailyReviewAvailability<[DailyReviewEventRow]> {
        _ = day
        return .unavailable(Self.offReason)
    }
    static let offReason = "the calendar column is off - turn it on to see today\u{2019}s events"
}

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("jm")
    return f
}()
