// Manjesh Grand Line - native macOS app.
//
// Google Calendar as a **second, additive** source for the daily review's
// calendar column. The local Mac calendars (`DailyReviewCalendar.swift`,
// EventKit) are unchanged and still the first source; this one joins them
// when the captain has connected a Gmail account that granted the read-only
// calendar scope.
//
// ## Read-only, enforced by the scope rather than by this file
//
// `DailyReviewCalendar.swift`'s header explains why its own read-only-ness is
// a property of the file plus a source guard: EventKit hands out an object
// that *can* write, so the guarantee has to be "nothing here calls save".
// Here the guarantee is stronger and lives one layer down - the only scope
// this app ever asks Google for is `calendar.readonly`
// (`GoogleOAuth.scopes`), so the access token physically cannot write. This
// file additionally issues exactly one request shape, a `GET` of
// `events`; `GoogleCalendarSelfTest` asserts both, because neither can be
// proved by running it against a real calendar.
//
// ## Why it caches instead of fetching
//
// `DailyReviewCalendarReading.events(on:)` is **synchronous**, and it is
// called from `renderDailyReview()` on the main thread. A network round trip
// there would be GL-12's pre-window beachball in a different place. So this
// source answers from a snapshot and refreshes in the background
// (`refresh(for:completion:)`), which the page calls when it appears.
//
// The honest consequence, and GL-14 is the rule it follows: **before the
// first refresh lands there is no snapshot, and "no snapshot" is reported as
// a stated gap, never as an empty day.** "Google Calendar has not been read
// yet" and "you have nothing on" are different sentences, and a briefing that
// confuses them is worse than one that has no calendar at all.

import Foundation

/// The HTTP half, so a suite can exercise every branch with no network.
protocol GoogleCalendarTransport: AnyObject {
    /// Issues an authenticated `GET`. `completion` runs exactly once, on the
    /// transport's own thread.
    func get(_ url: URL, accessToken: String,
             completion: @escaping (Result<Data, Error>) -> Void)
}

final class URLSessionGoogleCalendarTransport: GoogleCalendarTransport {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func get(_ url: URL, accessToken: String,
             completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Bounded, like every other outbound call in this app.
        request.timeoutInterval = 20
        session.dataTask(with: request) { data, _, error in
            if let error { completion(.failure(error)); return }
            completion(.success(data ?? Data()))
        }.resume()
    }
}

/// One connected Google account's calendar, read-only.
final class GoogleDailyReviewCalendar: DailyReviewCalendarReading {

    let slot: GoogleAccountSlot
    var transport: GoogleCalendarTransport = URLSessionGoogleCalendarTransport()
    var signIn: GoogleSignInController = .shared
    var accounts: GoogleAccountStoring { GoogleAccountStore.shared }

    /// The last successful read, and the day it was for. A snapshot from
    /// yesterday is not today's calendar, so the day is part of the key.
    private var snapshot: (dayKey: String, rows: [DailyReviewEventRow])?
    /// Why the last refresh produced nothing, when it produced nothing.
    private var lastFailure: String?
    private var refreshing = false

    init(slot: GoogleAccountSlot) { self.slot = slot }

    // MARK: DailyReviewCalendarReading

    /// This source has no system permission of its own - the captain's grant
    /// *is* the OAuth consent. So access is simply "is there a connected
    /// account that granted the calendar scope".
    var access: DailyReviewCalendarAccess {
        guard let record = accounts.record(for: slot) else { return .notDetermined }
        return record.canReadCalendar ? .readable : .writeOnly
    }

    /// There is no TCC prompt to fire, so nothing here needs an `Info.plist`
    /// key - `true` unconditionally, unlike the EventKit source.
    var canPrompt: Bool { true }

    /// "Requesting access" here means "sign in", and signing in is a Settings
    /// action with two independent slots rather than a one-button grant. The
    /// card's own Connect button must not open a browser, so this reports the
    /// current state rather than starting a flow.
    func requestAccess(completion: @escaping (DailyReviewCalendarAccess) -> Void) {
        let access = self.access
        DispatchQueue.main.async { completion(access) }
    }

    func events(on day: Date) -> DailyReviewAvailability<[DailyReviewEventRow]> {
        guard let record = accounts.record(for: slot) else {
            return .unavailable("\(slot.title) is not connected to Google")
        }
        guard record.canReadCalendar else {
            return .unavailable("\(slot.title) is signed in but did not grant calendar access")
        }
        let key = Self.dayKey(for: day)
        if let snapshot, snapshot.dayKey == key { return .available(snapshot.rows) }
        // GL-14, and the whole reason this file caches: not yet read is not
        // the same as nothing on.
        return .unavailable(lastFailure ?? "\(slot.title)\u{2019}s calendar has not been read yet")
    }

    // MARK: The refresh

    /// Reads today from Google and replaces the snapshot.
    ///
    /// `completion` runs on main exactly once, with whether anything changed
    /// - so a caller can repaint only when there is something new to paint
    /// (GL-24's sibling: a repaint is cheap, a rebuild is not).
    func refresh(for day: Date, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !refreshing else { completion(false); return }
        guard let record = accounts.record(for: slot), record.canReadCalendar else {
            completion(false)
            return
        }
        refreshing = true
        let key = Self.dayKey(for: day)
        signIn.accessToken(for: slot) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.refreshing = false
                self.lastFailure = "\(self.slot.title)\u{2019}s calendar could not be read - "
                    + (error.errorDescription ?? "sign in again")
                completion(true)
            case .success(let token):
                let url = Self.eventsURL(for: day)
                self.transport.get(url, accessToken: token) { data in
                    DispatchQueue.main.async {
                        self.refreshing = false
                        switch data {
                        case .failure(let error):
                            self.lastFailure = "\(self.slot.title)\u{2019}s calendar could not be "
                                + "read - \(error.localizedDescription)"
                            completion(true)
                        case .success(let payload):
                            switch Self.parse(payload, day: day) {
                            case .unavailable(let reason):
                                self.lastFailure = "\(self.slot.title)\u{2019}s calendar could not "
                                    + "be read - \(reason)"
                                completion(true)
                            case .available(let rows):
                                let changed = self.snapshot?.rows != rows
                                    || self.snapshot?.dayKey != key
                                self.snapshot = (key, rows)
                                self.lastFailure = nil
                                completion(changed)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Drops the snapshot - for a sign-out, where continuing to show the last
    /// read events would be showing a disconnected account's data.
    func forget() {
        snapshot = nil
        lastFailure = nil
    }

    // MARK: Pure helpers (the asserted half)

    /// `GET .../calendars/primary/events` bounded to one local day, expanded
    /// (`singleEvents`) so a recurring meeting arrives as today's instance
    /// rather than as its rule.
    static func eventsURL(for day: Date, calendar: Calendar = .current) -> URL {
        let start = calendar.startOfDay(for: day)
        let end = start.addingTimeInterval(24 * 60 * 60)
        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: iso8601.string(from: start)),
            URLQueryItem(name: "timeMax", value: iso8601.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]
        return components.url!
    }

    /// Google's `events.list` JSON -> this app's own rows.
    ///
    /// Cancelled events are dropped: Google returns them in the list with
    /// `status: "cancelled"`, and a briefing that lists a meeting the captain
    /// is no longer expected at is worse than one that omits it.
    static func parse(_ data: Data, day: Date,
                      calendar: Calendar = .current) -> DailyReviewAvailability<[DailyReviewEventRow]> {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unavailable("Google\u{2019}s reply was not JSON")
        }
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Google refused the request"
            return .unavailable(message)
        }
        let items = (object["items"] as? [[String: Any]]) ?? []
        let dayStart = calendar.startOfDay(for: day)
        let rows = items
            .filter { ($0["status"] as? String) != "cancelled" }
            .map { row(for: $0, dayStart: dayStart) }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.sortKey < rhs.sortKey
            }
            .map(\.row)
        return .available(rows)
    }

    private static func row(for item: [String: Any], dayStart: Date)
        -> (row: DailyReviewEventRow, isAllDay: Bool, sortKey: Date) {
        let title = ((item["summary"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let start = item["start"] as? [String: Any] ?? [:]
        // An all-day event carries `date`; a timed one carries `dateTime`.
        // That distinction is Google's only signal for it - there is no
        // `isAllDay` field.
        let isAllDay = start["dateTime"] == nil
        let startDate = (start["dateTime"] as? String).flatMap { iso8601.date(from: $0) }
            ?? (start["date"] as? String).flatMap { dayOnly.date(from: $0) }
            ?? dayStart
        return (DailyReviewEventRow(
            title: title.isEmpty ? "Untitled event" : title,
            timeText: isAllDay ? "all day" : timeFormatter.string(from: startDate),
            detail: detail(for: item),
            // Google gives a numeric `colorId` into a palette this app does
            // not have; rather than guess a hex, a Google row carries none and
            // the card falls back to its theme tint - which is what
            // `DailyReviewEventRow.colorHex`'s own `nil` case is for.
            colorHex: nil,
            isAllDay: isAllDay), isAllDay, startDate)
    }

    /// "6 attendees \u{00B7} Meet" - the same sentence shape the EventKit
    /// source produces, so a merged column reads as one list rather than as
    /// two.
    static func detail(for item: [String: Any]) -> String {
        var parts: [String] = []
        if let attendees = item["attendees"] as? [[String: Any]], attendees.count > 1 {
            parts.append("\(attendees.count) attendees")
        }
        let location = ((item["location"] as? String) ?? "")
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !location.isEmpty {
            parts.append(location.count > 40 ? String(location.prefix(40)) + "\u{2026}" : location)
        }
        if parts.isEmpty, item["hangoutLink"] != nil { parts.append("Meet") }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func dayKey(for day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Both sources at once: the Mac's own calendars and every connected Google
/// account's, in one column.
///
/// **Additive, and neither half can hide the other.** The rules, all three of
/// which are asserted:
///
///   - a source with events contributes them;
///   - a source that is unavailable contributes its **reason**, and a reason
///     is never dropped just because another source had events (GL-14: the
///     captain must be able to tell "nothing on" from "one of your two
///     calendars could not be read");
///   - only when *every* source is unavailable does the column itself become
///     unavailable, and then it says all of their reasons.
final class CompositeDailyReviewCalendar: DailyReviewCalendarReading {

    private let sources: [DailyReviewCalendarReading]

    init(sources: [DailyReviewCalendarReading]) { self.sources = sources }

    var access: DailyReviewCalendarAccess {
        // Readable if anything is readable - the column has something to
        // show. Otherwise the first source's own answer, so a lone EventKit
        // `.denied` still reaches the card that explains how to fix it.
        if sources.contains(where: { $0.access == .readable }) { return .readable }
        return sources.first?.access ?? .notDetermined
    }

    var canPrompt: Bool { sources.contains { $0.canPrompt } }

    func requestAccess(completion: @escaping (DailyReviewCalendarAccess) -> Void) {
        // The EventKit source is the only one with a system prompt, so this
        // asks the first source that can prompt and reports the composite's
        // resulting access - never a second prompt from a second source.
        guard let prompting = sources.first(where: { $0.canPrompt }) else {
            let access = self.access
            DispatchQueue.main.async { completion(access) }
            return
        }
        prompting.requestAccess { [weak self] _ in
            completion(self?.access ?? .notDetermined)
        }
    }

    func events(on day: Date) -> DailyReviewAvailability<[DailyReviewEventRow]> {
        var rows: [DailyReviewEventRow] = []
        var reasons: [String] = []
        var anyAvailable = false
        for source in sources {
            switch source.events(on: day) {
            case .available(let found):
                anyAvailable = true
                rows.append(contentsOf: found)
            case .unavailable(let reason):
                reasons.append(reason)
            }
        }
        guard anyAvailable else {
            return .unavailable(reasons.isEmpty
                ? "no calendar is connected"
                : reasons.joined(separator: "; "))
        }
        // All-day first, then by time - the same order each source already
        // uses, applied again because two sorted lists concatenated are not a
        // sorted list.
        rows.sort { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            return lhs.timeText < rhs.timeText
        }
        guard reasons.isEmpty else {
            // Some events **and** a source that could not be read. The rows
            // are shown, and the gap is stated rather than swallowed - see
            // this class's own doc comment.
            return .available(rows + [DailyReviewEventRow(
                title: reasons.joined(separator: "; "),
                timeText: "", detail: "", colorHex: nil, isAllDay: false)])
        }
        return .available(rows)
    }
}

private let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Google's all-day form, `YYYY-MM-DD`, resolved in the **current** calendar.
///
/// AGENTS.md: a `"YYYY-MM-DD"` fixture needs `Calendar.current`, not a pinned
/// UTC one - "all day today" means today where the captain is, and forcing UTC
/// here is what puts an event on the wrong side of midnight.
private let dayOnly: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.calendar = Calendar.current
    f.timeZone = Calendar.current.timeZone
    return f
}()

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("jm")
    return f
}()
