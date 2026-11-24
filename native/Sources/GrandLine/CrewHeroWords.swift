// Grand Line - native macOS app.
//
// CR-1 Crew band, the captain's pick for Crew on the hero restyle board
// (`data/grandline-hero-restyle-designs-scout/`, stage `stage-crew`): every
// Crew tab opens on one band, a `HelmHeroColumn` in its `.band` layout, in
// the shape of the Tasks band. This file is what the band says.
//
// **Pure, and Foundation only.** Every input is a value `FleetController`
// already holds - the verdict `FleetGreeting.answer` computed, the counts its
// refresh read, Needs you's own read times - so the words are asserted in
// CI's blocking lane (`PageHeroColumnsSelfTest`) without a window or a store.
// Times and the day come in as strings or a formatter, so a suite pins them.
//
// **Each tab is one function returning one `Band`.** Needs you and In flight
// are here. Review and Log are the second half of CR-1 and take the same
// shape: a kicker naming the tab and when, a headline that says what is true
// now, a quiet second line, a tone, and the figures in the band's strip.
//
// **GL-14 throughout.** A read that has not landed says it is reading, a
// figure that is not known is `nil` (drawn as a dash), and a failed read
// paints the dimmed tone and says when it last read - never a zero.

import Foundation

enum CrewHeroWords {

    /// The band's colour: the theme's hero accent, or the accent dimmed for a
    /// reading that failed (`HelmHeroSurface.dimmed`, GL-14).
    enum Tone: Equatable { case accent, dimmed }

    /// One figure in the band's strip. A `nil` value is not known, and is
    /// drawn as a dash.
    struct Figure: Equatable {
        let value: String?
        let caption: String
        /// The one figure that is a button: Ready to merge, into Review.
        var opensReview = false
    }

    /// A state as a glass pill at the band's top right: the watcher's.
    struct Status: Equatable {
        enum State: Equatable { case good, warn, idle }
        let text: String
        let state: State
    }

    /// One tab's band.
    struct Band: Equatable {
        /// The kicker tile's glyph: the crew, or a check for a calm verdict.
        var symbol: String
        var kicker: String
        var headline: String
        var body: String?
        var tone: Tone = .accent
        /// The strip under the hairline. Empty draws none.
        var figures: [Figure] = []
        var status: Status? = nil
        /// No firstmate home: the band's foot is Open Setup (GL-31).
        var offersSetup = false
    }

    static let crewSymbol = "person.2.fill"
    static let calmSymbol = "checkmark"

    /// "Reading the crew's state…", the first-read headline of every tab.
    static let readingHeadline = "Reading the crew\u{2019}s state\u{2026}"

    /// The kicker's day: "Tue 24 Nov" (the board's), localised.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter
    }()

    // MARK: Needs you

    /// What Needs you last read, as counts.
    struct NeedsYouReading: Equatable {
        /// The first read has landed.
        var hasRead: Bool
        var homeOk: Bool
        /// The last read could not read the crew's task list at all.
        var readFailed: Bool
        /// When the crew's state was last checked, read or not.
        var checkedAt: Date?
        /// When the task list was last read successfully.
        var readAt: Date?
        /// The tasks waiting on the captain, carried ones included.
        var waiting: Int
        /// The open decisions their status files record.
        var openDecisions: Int
        /// Of `waiting`, the tasks parked on a decision, and the blocked ones.
        var needDecision: Int
        var blocked: Int
        /// Tasks listed from an earlier read because this one could not read
        /// them, and the oldest of their read times.
        var carried: Int = 0
        var carriedSince: Date? = nil
    }

    /// "2 tasks are waiting on you, with 3 open decisions." - the count
    /// today's summary line opened with, which the failed read still says.
    static func waitingSentence(waiting: Int, openDecisions: Int) -> String {
        let tasks = waiting == 1 ? "1 task is waiting on you" : "\(waiting) tasks are waiting on you"
        let open = openDecisions == 1 ? "1 open decision" : "\(openDecisions) open decisions"
        return "\(tasks), with \(open)."
    }

    static func needsYou(_ reading: NeedsYouReading, time: (Date) -> String) -> Band {
        guard reading.hasRead, let checkedAt = reading.checkedAt else {
            return Band(symbol: crewSymbol, kicker: "Needs you", headline: readingHeadline,
                        body: "Nothing is shown until the first read lands.")
        }
        let checked = time(checkedAt)
        guard reading.homeOk else {
            return Band(symbol: crewSymbol, kicker: "Needs you \u{00B7} Finish setup",
                        headline: "Grand Line isn\u{2019}t pointed at a firstmate home yet",
                        body: "So the crew\u{2019}s state cannot be read. Checked at \(checked).", offersSetup: true)
        }
        if reading.readFailed {
            let headline = "Couldn\u{2019}t read the crew\u{2019}s state at \(checked)"
            guard let readAt = reading.readAt else {
                return Band(symbol: crewSymbol, kicker: "Needs you", headline: headline, body: nil, tone: .dimmed)
            }
            let last = time(readAt)
            let body = reading.waiting == 0
                ? "Nothing was waiting on you when it was last read, at \(last)."
                : "Showing what was read at \(last): "
                    + waitingSentence(waiting: reading.waiting, openDecisions: reading.openDecisions)
            return Band(symbol: crewSymbol, kicker: "Needs you \u{00B7} last read \(last)", headline: headline,
                        body: body, tone: .dimmed, figures: reading.waiting == 0 ? [] : needsFigures(reading))
        }
        let kicker = "Needs you \u{00B7} checked \(checked)"
        guard reading.waiting > 0 else {
            return Band(symbol: calmSymbol, kicker: kicker, headline: "Nothing needs you",
                        body: "No crewmate is waiting on a decision, and none is blocked.")
        }
        let headline = reading.waiting == 1 ? "1 task is waiting on you" : "\(reading.waiting) tasks are waiting on you"
        var parts = [reading.openDecisions == 1 ? "1 open decision" : "\(reading.openDecisions) open decisions"]
        if reading.needDecision > 0 { parts.append("\(reading.needDecision) waiting on a decision") }
        if reading.blocked > 0 { parts.append("\(reading.blocked) blocked") }
        var body = parts.joined(separator: " \u{00B7} ") + ". The crew is holding for you."
        if reading.carried > 0, let since = reading.carriedSince {
            body += reading.carried == 1
                ? " One of them could not be read just now, so it shows as read at \(time(since))."
                : " \(reading.carried) of them could not be read just now, so they show as read at \(time(since))."
        }
        return Band(symbol: crewSymbol, kicker: kicker, headline: headline, body: body,
                    figures: needsFigures(reading))
    }

    private static func needsFigures(_ reading: NeedsYouReading) -> [Figure] {
        [Figure(value: "\(reading.openDecisions)", caption: "Open decisions"),
         Figure(value: "\(reading.needDecision)", caption: "Need a decision"),
         Figure(value: "\(reading.blocked)", caption: "Blocked")]
    }

    // MARK: In flight

    /// The PR half of the reading: a count, still scanning, or unknown.
    enum Ready: Equatable { case count(Int), scanning, failed }

    struct InFlightReading: Equatable {
        var hasRead: Bool
        var homeOk: Bool
        /// `FleetGreeting.answer`'s title and meta, the verdict the page has
        /// always said, word for word.
        var verdictHeadline: String
        var verdictBody: String
        var working: Int
        var queued: Int
        var doneToday: Int
        var projects: Int
        var ready: Ready
        /// The watcher's status as `FleetSnapshot` reads it: "healthy",
        /// "stale", or anything else for off.
        var watcher: String
        /// Whether the crew's task list itself was read. `FleetGreeting`
        /// cannot tell an unread list from an empty one, so without this a
        /// failed read said "Nothing needs you right now" (GL-14).
        var tasksRead = true
        var checkedAt: Date? = nil
    }

    static func inFlight(_ reading: InFlightReading, day: String, time: (Date) -> String) -> Band {
        guard reading.hasRead else {
            return Band(symbol: crewSymbol, kicker: "In flight", headline: readingHeadline,
                        body: "Loading fleet data\u{2026}")
        }
        let kicker = "In flight \u{00B7} \(day)"
        guard reading.homeOk else {
            return Band(symbol: crewSymbol, kicker: kicker, headline: reading.verdictHeadline,
                        body: reading.verdictBody, offersSetup: true)
        }
        let ready: Figure
        switch reading.ready {
        case .count(let count): ready = Figure(value: "\(count)", caption: "Ready to merge", opensReview: true)
        case .scanning: ready = Figure(value: nil, caption: "Scanning PRs", opensReview: true)
        case .failed: ready = Figure(value: nil, caption: "PRs unavailable", opensReview: true)
        }
        let watcher = watcherStatus(reading.watcher)
        let figures = [
            Figure(value: reading.tasksRead ? "\(reading.working)" : nil, caption: "Working"),
            ready,
            Figure(value: "\(reading.queued)", caption: "Queued"),
            Figure(value: "\(reading.doneToday)", caption: "Done today"),
            Figure(value: "\(reading.projects)", caption: "Projects"),
            Figure(value: watcher.state == .good ? "OK" : nil, caption: watcher.text),
        ]
        guard reading.tasksRead else {
            // The verdict would be about an empty list it never read.
            return Band(symbol: crewSymbol, kicker: kicker,
                        headline: "Couldn\u{2019}t read the crew\u{2019}s state" + (reading.checkedAt.map { " at \(time($0))" } ?? ""),
                        body: "Who is working and who is waiting on you is unknown until the next read.",
                        tone: .dimmed, figures: figures, status: watcher)
        }
        // A PR scan that failed leaves the verdict partly unknown, so the
        // band takes the dimmed tone the way a failed Needs you read does.
        return Band(symbol: crewSymbol, kicker: kicker, headline: reading.verdictHeadline, body: reading.verdictBody,
                    tone: reading.ready == .failed ? .dimmed : .accent, figures: figures, status: watcher)
    }

    /// The watcher's pill: "Watcher healthy", "Watcher stale" or "Watcher off".
    static func watcherStatus(_ status: String) -> Status {
        switch status {
        case "healthy": return Status(text: "Watcher healthy", state: .good)
        case "stale": return Status(text: "Watcher stale", state: .warn)
        default: return Status(text: "Watcher off", state: .idle)
        }
    }
}
