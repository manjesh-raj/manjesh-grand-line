// Grand Line - native macOS app.
//
// CR-1 Crew band, the captain's pick for Crew on the hero restyle board
// (`data/grandline-hero-restyle-designs-scout/`, stage `stage-crew`): every
// Crew tab opens on one band, a `HelmHeroColumn` in its `.band` layout, in
// the shape of the Tasks band. This file is what the band says.
//
// **Pure, and Foundation only.** Every input is a value `FleetController`
// already holds - the verdict `FleetGreeting.answer` computed, the counts its
// refresh read, Needs you's own read times, the PR counts `ReviewController`
// rendered - so the words are asserted in CI's blocking lane
// (`PageHeroColumnsSelfTest`) without a window or a store. Times and the day
// come in as strings or a formatter, so a suite pins them.
//
// **Each tab is one function returning one `Band`.** Needs you, In flight,
// Review and Log, each in the same shape: a kicker naming the tab and when, a
// headline that says what is true now, a quiet second line, a tone, and the
// figures in the band's strip - or, on Log, the filter's segments with their
// counts.
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

    /// A ring at the band's top right: Review's ready over open.
    struct Ring: Equatable {
        let value: Int
        let total: Int
        /// The centre label: "2/9".
        var label: String { "\(value)/\(total)" }
        /// 0...1 of the arc. An empty total draws an empty arc.
        var fraction: Double { total > 0 ? min(1, Double(value) / Double(total)) : 0 }
        /// The words beside the ring.
        let caption: String
        /// What VoiceOver reads for the ring.
        let spoken: String
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
        /// Review's ring of ready over open. `nil` draws none.
        var ring: Ring? = nil
        /// Review's projects folder could not be read: the band's foot is
        /// Show folder path, which reveals the path the scan tried.
        var offersFolderPath = false
        /// Log's filter on the band's foot, one segment per kind with its
        /// count. Empty draws none: a log with nothing in it has nothing to
        /// filter, and the band is its empty state.
        var filter: [LogSegment] = []
    }

    static let crewSymbol = "person.2.fill"
    static let calmSymbol = "checkmark"
    /// Review's kicker glyph: its own sidebar row's (`ModuleTable`).
    static let reviewSymbol = "arrow.triangle.branch"

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

    // MARK: Review

    /// What Review's last PR scan found, as the counts its forge cards show.
    struct ReviewReading: Equatable {
        /// The first scan has landed.
        var hasRead: Bool
        /// When the last scan finished, whether or not it reached every forge.
        var checkedAt: Date? = nil
        /// When the last scan that reached every forge finished.
        var cleanReadAt: Date? = nil
        /// The open pull requests on each forge card: GitHub, Bitbucket, and
        /// the task-tracked ones on no known forge.
        var github = 0
        var bitbucket = 0
        var other = 0
        /// Of those: ready to merge (`FleetDataSource.readyToMerge`, the one
        /// definition every surface counts), checks running, checks failing.
        var ready = 0
        var running = 0
        var failing = 0
        /// The scan did not fully succeed: its one short sentence, never a
        /// path (`ReviewController.ScanFailure.headline`).
        var failure: String? = nil
        /// The projects folder itself could not be listed, so no forge was
        /// asked anything.
        var failureIsTotal = false

        var open: Int { github + bitbucket + other }
    }

    /// "2 pull requests are ready to merge", the board's headline, over the
    /// checks still running and failing and where the pull requests are.
    ///
    /// GL-14: a scan that did not reach every forge paints the dimmed tone and
    /// says when it tried. What it did find stays counted, and says it is
    /// only part of the picture. A scan that found nothing it could trust
    /// draws no figure and no ring rather than a zero.
    static func review(_ reading: ReviewReading, time: (Date) -> String) -> Band {
        guard reading.hasRead else {
            return Band(symbol: reviewSymbol, kicker: "Review", headline: "Checking your projects\u{2026}",
                        body: "Reading open pull requests from every clone in your firstmate home.")
        }
        let open = reading.open
        let found = open == 1 ? "1 pull request" : "\(open) pull requests"
        if let failure = reading.failure {
            // The scan's own sentence, set as the band's other headlines are.
            let sentence = (failure.hasSuffix(".") ? String(failure.dropLast()) : failure)
                .replacingOccurrences(of: "'", with: "\u{2019}")
            let headline = sentence + (reading.checkedAt.map { " at \(time($0))" } ?? "")
            let kicker = reading.cleanReadAt.map { "Review \u{00B7} last read \(time($0))" } ?? "Review"
            guard open > 0 else {
                let body = reading.failureIsTotal
                    ? "Open pull requests are read from the clones in your firstmate home\u{2019}s projects folder. "
                        + "None could be read, so no count is shown."
                    : "The forges that answered have no open pull requests. "
                        + "The others are unknown until the next read, so no count is shown."
                return Band(symbol: reviewSymbol, kicker: kicker, headline: headline, body: body, tone: .dimmed,
                            offersFolderPath: reading.failureIsTotal)
            }
            let body = reading.failureIsTotal
                ? "Showing the \(found) your crew\u{2019}s tasks point at, \(reading.ready) ready to merge. "
                    + "Your clones could not be read, so theirs are not counted."
                : "Showing the \(found) found in the repositories that answered, \(reading.ready) ready to merge. "
                    + "The others are not counted."
            return Band(symbol: reviewSymbol, kicker: kicker, headline: headline, body: body, tone: .dimmed,
                        figures: reviewFigures(reading), ring: reviewRing(reading),
                        offersFolderPath: reading.failureIsTotal)
        }
        let checked = reading.checkedAt.map { " \u{00B7} checked \(time($0))" } ?? ""
        guard open > 0 else {
            return Band(symbol: calmSymbol, kicker: "Review" + checked, headline: "No open pull requests right now",
                        body: "Every clone was read. Nothing is waiting on a review or a merge.")
        }
        let headline: String
        switch reading.ready {
        case 0: headline = "No pull requests are ready to merge"
        case 1: headline = "1 pull request is ready to merge"
        default: headline = "\(reading.ready) pull requests are ready to merge"
        }
        var parts: [String] = []
        if reading.running > 0 { parts.append("\(reading.running) with checks running") }
        if reading.failing > 0 { parts.append("\(reading.failing) failing") }
        if parts.isEmpty { parts.append("No checks running or failing") }
        parts.append(forgePlace(reading))
        return Band(symbol: reviewSymbol, kicker: "Review \u{00B7} \(open) open" + checked, headline: headline,
                    body: parts.joined(separator: " \u{00B7} ") + ".",
                    figures: reviewFigures(reading), ring: reviewRing(reading))
    }

    /// Where the open pull requests are, as the page's forge cards group
    /// them: "on GitHub", "across GitHub and Bitbucket", "and elsewhere" for
    /// the task-tracked ones on no known forge.
    static func forgePlace(_ reading: ReviewReading) -> String {
        var known: [String] = []
        if reading.github > 0 { known.append("GitHub") }
        if reading.bitbucket > 0 { known.append("Bitbucket") }
        if reading.other > 0 {
            return known.isEmpty ? "on no known forge" : "across \(known.joined(separator: ", ")) and elsewhere"
        }
        return known.count == 1 ? "on \(known[0])" : "across \(known.joined(separator: " and "))"
    }

    private static func reviewFigures(_ reading: ReviewReading) -> [Figure] {
        [Figure(value: "\(reading.open)", caption: "Open PRs"),
         Figure(value: "\(reading.ready)", caption: "Ready to merge"),
         Figure(value: "\(reading.running)", caption: "Checks running"),
         Figure(value: "\(reading.failing)", caption: "Checks failing")]
    }

    private static func reviewRing(_ reading: ReviewReading) -> Ring {
        Ring(value: reading.ready, total: reading.open, caption: "ready",
             spoken: "\(reading.ready) of \(reading.open) open pull request\(reading.open == 1 ? "" : "s") ready to merge")
    }

    // MARK: Log

    /// Log's kicker glyph: the feed's own (`FleetLogListView`'s empty state),
    /// the board's clock turning back.
    static let logSymbol = "clock.arrow.circlepath"

    /// What the log holds when it holds nothing - the words the feed's own
    /// empty state has always said, and now the band's.
    static let emptyLogBody = "Merges, completed tasks, resolved sync conflicts and saved investigations land here as they happen."

    /// One segment of Log's filter on the band.
    struct LogSegment: Equatable {
        /// `nil` is All.
        let kind: FleetLogEventKind?
        /// The floating bar's own title for it (`FleetLogListView.filterItems`).
        let title: String
        /// How many events the feed holds of this kind. `nil` is not known:
        /// the half of the log that holds it could not be read (GL-14), and
        /// the segment says its title alone rather than a zero.
        let count: Int?
        /// "Merges 3", with an en space, as Hosts' and DevOps Hub's counted
        /// segments say it.
        var label: String { count.map { "\(title)\u{2002}\($0)" } ?? title }
    }

    /// What the last read of the log found, as counts. Built from the feed's
    /// own read (`FleetLogFeed.read`), so the band counts exactly the events
    /// the list below it shows.
    struct LogReading: Equatable {
        var hasRead = false
        var readAt: Date?
        /// Every event the feed holds, by kind.
        var counts: [FleetLogEventKind: Int] = [:]
        /// Of those, the ones on `readAt`'s day.
        var today: [FleetLogEventKind: Int] = [:]
        /// Today's newest event.
        var latestToday: Date?
        /// The newest event of all, and its day as the feed's own header says
        /// it ("Yesterday", "Saturday 22 November").
        var newest: Date?
        var newestDay: String?
        /// The log file is there and could not be read: merges, sync fixes,
        /// investigations and incidents are unknown.
        var logUnreadable = false
        /// Part of Shift's activity could not be read: some task updates are
        /// unknown.
        var activityUnreadable = false

        /// Not read yet.
        init() {}

        init(_ read: FleetLogFeed.Read, calendar: Calendar = .current) {
            hasRead = true
            readAt = read.readAt
            for event in read.events {
                counts[event.kind, default: 0] += 1
                guard calendar.isDate(event.date, inSameDayAs: read.readAt) else { continue }
                today[event.kind, default: 0] += 1
                latestToday = max(latestToday ?? event.date, event.date)
            }
            newest = read.events.map(\.date).max()
            newestDay = newest.map { FleetLogFeed.dayLabel(for: $0, reference: read.readAt, calendar: calendar) }
            logUnreadable = read.logUnreadable
            activityUnreadable = read.activityUnreadable
        }

        var total: Int { counts.values.reduce(0, +) }
        var todayTotal: Int { today.values.reduce(0, +) }
        /// Some of the log could not be read.
        var isPartial: Bool { logUnreadable || activityUnreadable }

        /// Whether `kind`'s count is known. Task updates come from Shift's
        /// activity and every other kind from the log file (`FleetLogFeed`'s
        /// header), so each half's failure leaves only its own kinds unknown.
        /// All is known only when both halves were read.
        func knows(_ kind: FleetLogEventKind?) -> Bool {
            guard let kind else { return !isPartial }
            return kind == .task ? !activityUnreadable : !logUnreadable
        }
    }

    /// "5 events today", the board's headline, over what they were and when
    /// the latest was, with the filter and its counts on the band's foot.
    ///
    /// GL-14: a read that could not read part of the log paints the dimmed
    /// tone, says when it tried and what is unknown, and counts only what it
    /// read. A segment whose kind is unknown carries no count, never a zero.
    static func log(_ reading: LogReading, day: String, time: (Date) -> String) -> Band {
        guard reading.hasRead else {
            return Band(symbol: logSymbol, kicker: "Log", headline: "Reading the log\u{2026}", body: nil)
        }
        let kicker = "Log \u{00B7} \(day)"
        let filter = reading.total > 0 ? logSegments(reading) : []
        if reading.isPartial {
            let at = reading.readAt.map { " at \(time($0))" } ?? ""
            let unknown = logUnknownPhrase(reading)
            let body: String
            if reading.total > 0 {
                let shown = reading.total == 1 ? "the 1 event" : "the \(reading.total) events"
                let today = reading.todayTotal == 0 ? "none" : "\(reading.todayTotal)"
                body = "Showing \(shown) that could be read, \(today) today. "
                    + "\(unknown) could not be read, so they are not counted."
            } else {
                body = "\(unknown) could not be read, so no count is shown."
            }
            let headline = reading.total > 0 ? "Couldn\u{2019}t read all of the log" : "Couldn\u{2019}t read the log"
            return Band(symbol: logSymbol, kicker: kicker, headline: headline + at, body: body, tone: .dimmed,
                        filter: filter)
        }
        guard reading.total > 0 else {
            return Band(symbol: calmSymbol, kicker: "Log", headline: "Nothing logged yet", body: emptyLogBody)
        }
        guard reading.todayTotal > 0, let latest = reading.latestToday else {
            var body: String?
            if let newest = reading.newest, let newestDay = reading.newestDay {
                let when = newestDay == "Yesterday" ? "yesterday" : "on \(newestDay)"
                body = "The last event was \(when) at \(time(newest))."
            }
            return Band(symbol: logSymbol, kicker: kicker, headline: "Quiet so far today", body: body, filter: filter)
        }
        let headline = reading.todayTotal == 1 ? "1 event today" : "\(reading.todayTotal) events today"
        let parts = logTodayOrder.compactMap { kind, words -> String? in
            guard let count = reading.today[kind], count > 0 else { return nil }
            return words(count)
        }
        return Band(symbol: logSymbol, kicker: kicker, headline: headline,
                    body: parts.joined(separator: " \u{00B7} ") + ". Latest at \(time(latest)).", filter: filter)
    }

    /// Today's events by kind, in the board's order, as the band's second
    /// line says them. Task updates rather than the board's "tasks done":
    /// Shift logs every task change into the feed (created, completed, a due
    /// date moved), so not every one of them is a task done.
    private static let logTodayOrder: [(FleetLogEventKind, (Int) -> String)] = [
        (.merge, { $0 == 1 ? "1 merge" : "\($0) merges" }),
        (.task, { $0 == 1 ? "1 task update" : "\($0) task updates" }),
        (.investigation, { $0 == 1 ? "1 investigation saved" : "\($0) investigations saved" }),
        (.incident, { $0 == 1 ? "1 incident update" : "\($0) incident updates" }),
        (.sync, { $0 == 1 ? "1 sync fix" : "\($0) sync fixes" }),
    ]

    /// The filter's segments: All, then one per kind in the feed's own order,
    /// each with its count when that count is known.
    static func logSegments(_ reading: LogReading) -> [LogSegment] {
        let kinds: [FleetLogEventKind?] = [nil] + FleetLogEventKind.allCases.map { $0 }
        return kinds.map { kind in
            let count = kind.map { reading.counts[$0] ?? 0 } ?? reading.total
            return LogSegment(kind: kind, title: kind?.pluralTitle ?? "All", count: reading.knows(kind) ? count : nil)
        }
    }

    /// What could not be read, as the start of a sentence.
    private static func logUnknownPhrase(_ reading: LogReading) -> String {
        switch (reading.logUnreadable, reading.activityUnreadable) {
        case (true, true): return "Merges, sync fixes, investigations, incidents and some task updates"
        case (true, false): return "Merges, sync fixes, investigations and incidents"
        default: return "Some task updates"
        }
    }

    /// The list's empty state under a filter whose kind could not be read:
    /// unknown, not "Nothing here" (GL-14). `nil` when the kind is known, and
    /// the list keeps its own words.
    static func logListUnknown(_ reading: LogReading, kind: FleetLogEventKind?,
                               time: (Date) -> String) -> (title: String, body: String)? {
        guard reading.hasRead, !reading.knows(kind) else { return nil }
        let at = reading.readAt.map { " at \(time($0))" } ?? ""
        let what: String
        switch kind {
        case .none: what = "The log"
        case .merge?: what = "Merges"
        case .task?: what = "Some task updates"
        case .sync?: what = "Sync fixes"
        case .investigation?: what = "Saved investigations"
        case .incident?: what = "Incident updates"
        }
        return ("Couldn\u{2019}t read the log", "\(what) could not be read\(at), so none are shown.")
    }
}
