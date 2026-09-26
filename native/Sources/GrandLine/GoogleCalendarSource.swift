// Grand Line - native macOS app.
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
//
// ## And why the same machinery also answers "does this actually work?"
//
// The bottom of this file (`GoogleCalendarHealthCheck`) runs one real read on
// demand and reports the verdict to Settings \u{203A} Google Accounts. It exists
// because OAuth succeeding says nothing about whether the calendar can be
// read: the captain connected an account, the row said "calendar readable",
// and every read failed with Google's "Calendar API has not been used in
// project N ... Enable it by visiting <url>" - which only ever surfaced in the
// daily review card's fine print, days later and on another page. The check is
// deliberately built out of *this* file's request, token and parse, so
// "the check passed" and "the daily review can read this calendar" are one
// claim rather than two.

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
                            case .available(let rows), .partial(let rows, _):
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
            .sorted(by: DailyReviewEventRow.isOrderedBefore)
        return .available(rows)
    }

    private static func row(for item: [String: Any], dayStart: Date) -> DailyReviewEventRow {
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
        return DailyReviewEventRow(
            title: title.isEmpty ? "Untitled event" : title,
            timeText: isAllDay ? "all day" : timeFormatter.string(from: startDate),
            detail: detail(for: item),
            // Google gives a numeric `colorId` into a palette this app does
            // not have; rather than guess a hex, a Google row carries none and
            // the card falls back to its theme tint - which is what
            // `DailyReviewEventRow.colorHex`'s own `nil` case is for.
            colorHex: nil,
            isAllDay: isAllDay,
            startsAt: startDate)
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
            case .partial(let found, let reason):
                // A nested composite, or a source that answered with a gap of
                // its own: both halves travel on.
                anyAvailable = true
                rows.append(contentsOf: found)
                reasons.append(reason)
            case .unavailable(let reason):
                reasons.append(reason)
            }
        }
        guard anyAvailable else {
            return .unavailable(reasons.isEmpty
                ? "no calendar is connected"
                : reasons.joined(separator: "; "))
        }
        // All-day first, then by real start time - the same order each source
        // already uses, applied again because two sorted lists concatenated
        // are not a sorted list. On `startsAt` and never on `timeText`: that
        // string is localised, so a 12-hour locale sorts "1:00 PM" above
        // "9:00 AM" (B16).
        rows.sort(by: DailyReviewEventRow.isOrderedBefore)
        guard reasons.isEmpty else {
            // Some events **and** a source that could not be read. The rows
            // are shown, and the gap travels beside them as a gap rather than
            // as a fake row - see this class's own doc comment and B16.
            return .partial(rows, reason: reasons.joined(separator: "; "))
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

// MARK: - Connection health (fm/grandline-google-calendar-connection-health)

/// Google's error envelope, kept **whole** - the message *and* the fix-it URL
/// Google puts inside it.
///
/// The captain's own report is why this type exists. OAuth succeeded, the
/// Settings row said "calendar readable", and every actual read failed with
/// Google's most fixable error - "Google Calendar API has not been used in
/// project N before or it is disabled ... Enable it by visiting <url>".
/// `parse` above already carried that sentence into the daily review's card,
/// where it surfaced days later in the fine print. Nothing extracted the URL,
/// so the one click that fixes it was never offered anywhere.
///
/// The URL is pulled out of the message text rather than out of the
/// structured `details` array on purpose: Google's `Help` detail is not
/// present on every error shape, and the sentence is. When there is no URL the
/// message still stands on its own, which is the case this must not make
/// worse.
struct GoogleAPIFailure: Equatable {
    /// Google's own sentence, byte for byte. Never paraphrased - the whole
    /// point is that the captain can read the real cause and act on it.
    let message: String
    /// The first `https://` URL inside that sentence, when there is one.
    let fixURL: URL?

    /// `nil` when the payload carries no `error` object - i.e. the request
    /// succeeded, whatever else the body says.
    static func from(_ data: Data) -> GoogleAPIFailure? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        let message = (error["message"] as? String) ?? "Google refused the request"
        return GoogleAPIFailure(message: message, fixURL: firstURL(in: message))
    }

    /// The first `https://` run in `text`, with the trailing punctuation a
    /// sentence leaves on it stripped.
    ///
    /// Google's own wording is "... Enable it by visiting
    /// https://console.developers.google.com/... then retry.", so the URL is
    /// followed by a space - but "(<url>)" and "<url>." both occur in other
    /// Google messages, and a captain clicking a link with a `.` welded on
    /// lands on a 404 that looks like this app's fault.
    static func firstURL(in text: String) -> URL? {
        guard let start = text.range(of: "https://") else { return nil }
        var candidate = String(text[start.lowerBound...].prefix { !$0.isWhitespace })
        while let last = candidate.last, ".,;:!?)]\u{201D}\u{2019}\"'".contains(last) {
            candidate.removeLast()
        }
        guard candidate.count > "https://".count else { return nil }
        return URL(string: candidate)
    }
}

/// What one slot's *real* calendar read did, the last time it was tried.
///
/// Deliberately four states rather than two, for `GmailAccountRow`'s own
/// reason: "connected" and "actually works" are different claims (GL-14), and
/// a successful read that returned nothing is a success rather than a gap.
enum GoogleCalendarHealth: Equatable {
    /// Never tried on this launch. The row says nothing at all - a health
    /// line that reads "unknown" next to every account is noise.
    case notChecked
    case checking
    /// Google answered with a real day. `eventCount` may be zero, and zero is
    /// a **successful read**, said in those words.
    case healthy(eventCount: Int)
    /// Google, or the network, or the token refused - with Google's own
    /// sentence and, when it offered one, the page that fixes it.
    case failed(message: String, fixURL: URL?)

    /// So a caller can ask the one question it usually wants without
    /// destructuring a payload it does not need.
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Runs one real, lightweight Calendar read and reports what actually
/// happened - the check Settings › Google Accounts needed and did not have.
///
/// **It builds no second request machinery.** The URL is
/// `GoogleDailyReviewCalendar.eventsURL`, the transport is the same
/// `GoogleCalendarTransport`, the token comes from the same
/// `GoogleSignInController`, and the body goes through the same
/// `GoogleDailyReviewCalendar.parse`. So "the health check passed" and "the
/// daily review can read this calendar" are the same claim, which is the only
/// thing that makes the check worth showing.
///
/// One shared instance (GL-23): the result is what the Settings row paints,
/// and a second copy would let the page and the check disagree about the same
/// account. It caches per slot rather than per day - this is "does the
/// connection work", not "what is on today".
final class GoogleCalendarHealthCheck {

    static let shared = GoogleCalendarHealthCheck()

    var transport: GoogleCalendarTransport = URLSessionGoogleCalendarTransport()
    var signIn: GoogleSignInController = .shared
    var accounts: GoogleAccountStoring { GoogleAccountStore.shared }
    var clock: () -> Date = { Date() }

    private var results: [GoogleAccountSlot: GoogleCalendarHealth] = [:]

    private init() {}

    func result(for slot: GoogleAccountSlot) -> GoogleCalendarHealth {
        results[slot] ?? .notChecked
    }

    /// Drops a slot's verdict - for a disconnect, where a stale "calendar
    /// reads fine" under a row that no longer has an account is a lie.
    func forget(_ slot: GoogleAccountSlot) { results[slot] = nil }

    /// Reads today from Google and records the verdict.
    ///
    /// `completion` runs on main, **more than once**: once when the state
    /// turns `.checking` and once when it settles, so the row can paint the
    /// in-flight state without the caller owning a second timer. A check
    /// already in flight for this slot is not started twice.
    func check(slot: GoogleAccountSlot, on day: Date? = nil,
               completion: @escaping (GoogleCalendarHealth) -> Void = { _ in }) {
        if case .checking = result(for: slot) { return }
        guard let record = accounts.record(for: slot) else {
            settle(slot, .notChecked, completion)
            return
        }
        guard record.canReadCalendar else {
            // Not a network failure, and saying "could not reach Google"
            // here would send the captain to look in the wrong place.
            settle(slot, .failed(message: "This account is signed in but never granted "
                                 + "calendar access. Disconnect and sign in again, and tick "
                                 + "the calendar box on Google\u{2019}s consent screen.",
                                 fixURL: nil), completion)
            return
        }
        let day = day ?? clock()
        results[slot] = .checking
        completion(.checking)
        signIn.accessToken(for: slot) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.settle(slot, .failed(message: error.errorDescription
                                          ?? "the stored sign-in could not be refreshed",
                                          fixURL: nil), completion)
            case .success(let token):
                self.transport.get(GoogleDailyReviewCalendar.eventsURL(for: day),
                                   accessToken: token) { response in
                    DispatchQueue.main.async {
                        switch response {
                        case .failure(let error):
                            self.settle(slot, .failed(message: error.localizedDescription,
                                                      fixURL: nil), completion)
                        case .success(let payload):
                            self.settle(slot, Self.verdict(for: payload, day: day), completion)
                        }
                    }
                }
            }
        }
    }

    /// The body -> verdict step, pure so a suite can drive every Google reply
    /// shape with no transport at all.
    ///
    /// The **same** `parse` the daily review reads, so the two can never
    /// disagree - and `GoogleAPIFailure` is consulted only for the URL the
    /// card has no way to render.
    static func verdict(for payload: Data, day: Date) -> GoogleCalendarHealth {
        let failure = GoogleAPIFailure.from(payload)
        switch GoogleDailyReviewCalendar.parse(payload, day: day) {
        case .unavailable(let reason):
            return .failed(message: failure?.message ?? reason, fixURL: failure?.fixURL)
        case .available(let rows), .partial(let rows, _):
            return .healthy(eventCount: rows.count)
        }
    }

    private func settle(_ slot: GoogleAccountSlot, _ health: GoogleCalendarHealth,
                        _ completion: @escaping (GoogleCalendarHealth) -> Void) {
        let deliver = {
            self.results[slot] = health == .notChecked ? nil : health
            completion(health)
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }

    #if FM_SELFTESTS
    func debugSet(_ health: GoogleCalendarHealth, for slot: GoogleAccountSlot) {
        results[slot] = health == .notChecked ? nil : health
    }
    func debugReset() { results.removeAll() }
    #endif
}

#if FM_SELFTESTS
/// The backstop `main.swift` installs for every suite: a transport that
/// refuses rather than reaching Google.
///
/// Mounting a `SettingsController` builds the Google Accounts page, and that
/// page now runs a real read for a connected slot - so without this, any
/// suite that plants a fixture record would issue a live HTTPS request from
/// CI carrying a fabricated bearer token. A suite that wants a reply swaps
/// this for its own stub.
final class RefusingGoogleCalendarTransport: GoogleCalendarTransport {
    func get(_ url: URL, accessToken: String,
             completion: @escaping (Result<Data, Error>) -> Void) {
        _ = (url, accessToken)
        completion(.failure(NSError(domain: "FMSelfTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "the self-test transport refuses to reach Google",
        ])))
    }
}
#endif
