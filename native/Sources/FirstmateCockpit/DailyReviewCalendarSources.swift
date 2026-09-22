// Manjesh Grand Line - native macOS app.
//
// Which calendars the daily review reads, and the one place that decision is
// made.
//
// There are two sources now - the Mac's own calendars through EventKit
// (`DailyReviewCalendar.swift`) and any connected Google account
// (`GoogleCalendarSource.swift`) - each behind its own switch, and the column
// is the **union** of whatever is on. Neither replaces the other:
//
//   - both off:  the column is off, and says so (the state F20 shipped).
//   - one on:    that source alone, with its own unavailability reasons.
//   - both on:   `CompositeDailyReviewCalendar`, which merges the rows and
//                keeps every reason (GL-14 - "one of your two calendars could
//                not be read" is not "nothing on").
//
// **The Google sources are held here, not rebuilt per render**, because they
// cache a day's events: a fresh instance per render would have no snapshot
// and the column would say "not read yet" forever. GL-23's rule, for the same
// reason it exists - a store that caches gets one instance.

import Foundation

final class DailyReviewCalendarSources {

    static let shared = DailyReviewCalendarSources()

    /// One per slot, built on first use and kept - see the header.
    private var google: [GoogleAccountSlot: GoogleDailyReviewCalendar] = [:]

    private init() {}

    /// The Google sources that are currently both switched on and usable.
    ///
    /// "Usable" is the account's own granted scope, asked rather than assumed:
    /// a captain who unticked calendar on the consent screen is connected and
    /// has no calendar, and including that source would put its explanation in
    /// front of the captain, which is exactly right - so it **is** included,
    /// and it is the account with no record at all that is left out.
    func googleSources() -> [GoogleDailyReviewCalendar] {
        guard AppSettings.shared.googleCalendarEnabled else { return [] }
        return GoogleAccountSlot.allCases.compactMap { slot in
            guard GoogleAccountStore.shared.record(for: slot) != nil else { return nil }
            if let existing = google[slot] { return existing }
            let made = GoogleDailyReviewCalendar(slot: slot)
            google[slot] = made
            return made
        }
    }

    /// The source the review should read, or `nil` when every source is off.
    ///
    /// - Parameter local: the EventKit source the host controller owns. Passed
    ///   in rather than built here so a suite's stub still reaches the merge -
    ///   the point of `DailyReviewCalendarReading` being a seam at all.
    func source(local: DailyReviewCalendarReading) -> DailyReviewCalendarReading? {
        var sources: [DailyReviewCalendarReading] = []
        if AppSettings.shared.dailyReviewCalendarEnabled { sources.append(local) }
        sources.append(contentsOf: googleSources())
        switch sources.count {
        case 0: return nil
        // One source needs no wrapper, and not wrapping it is what keeps the
        // pre-Google behaviour byte-identical: the reasons the card shows for
        // a lone EventKit source are the ones `DailyReviewCalendar` writes,
        // not a merged restatement of them.
        case 1: return sources[0]
        default: return CompositeDailyReviewCalendar(sources: sources)
        }
    }

    /// Refresh every live Google source. `completion` runs on main once every
    /// source has answered, with whether any of them changed - so a page can
    /// re-render only when there is something new (GL-24's sibling).
    ///
    /// Does nothing at all when no Google source is on, which is the common
    /// case and must cost nothing.
    func refreshGoogle(for day: Date, completion: @escaping (Bool) -> Void) {
        let sources = googleSources()
        guard !sources.isEmpty else { completion(false); return }
        var remaining = sources.count
        var changed = false
        for source in sources {
            source.refresh(for: day) { didChange in
                changed = changed || didChange
                remaining -= 1
                if remaining == 0 { completion(changed) }
            }
        }
    }

    /// Drops every cached snapshot - for a sign-out, or for the switch being
    /// turned off. Showing a disconnected account's last-read events would be
    /// showing data the captain revoked.
    func forgetGoogle() {
        for source in google.values { source.forget() }
        google.removeAll()
    }
}
