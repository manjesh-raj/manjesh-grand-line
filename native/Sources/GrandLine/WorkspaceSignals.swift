// Grand Line - native macOS app.
//
// The sidebar layout's badges (the modular-shell migration's polish), as one
// pure model: what each signal last read, and what a module's row says about
// it.
//
// **Every signal is one a real controller already holds.** Nothing here
// fetches, polls or runs a subprocess; `WorkspaceSignalsMonitor` subscribes to
// the sources the app already has and hands their readings in:
//
// | Signal              | Source                                                   | Drawn as        |
// |---------------------|----------------------------------------------------------|-----------------|
// | Crew needs you      | the Fleet page's own read (`FleetController.needsYouReading`) | Crew's badge |
// | Tasks due           | `ShiftStore`, by day, as compact mode counts it          | Tasks' badge    |
// | Poneglyph's lock    | the vault store's lock state and its file's state        | Secrets' badge  |
// | A failing service   | `ServiceHealthRegistry`, the Health page's own source    | Health's dot    |
// | Setup's updates     | `BackgroundSignalsPoller.lastCounts`                     | Setup's badge   |
// | Live sessions       | the session registry (unchanged)                         | Console's badge |
//
// The layout also drew a status strip under every page, with readouts of its
// own for Claude usage and Tasks sync. The captain had the strip removed from
// every module; Claude usage is Home's Claude card and Console's usage
// popover, and Tasks sync is the Tasks page's own sync pill, so neither is
// read here any more.
//
// **The honest states (GL-14, and the inventory's own "Decisions taken").**
// A signal nobody has read and nobody is reading draws nothing. One whose
// first read is in flight is a dash, "scanning". One whose latest read failed
// keeps its last good value and says when that was read; with no good value
// to keep it says the read failed. A real zero draws no badge, the way a
// source list's counts do.
//
// Pure logic: no view, no window. `WorkspaceSignalsSelfTest` asserts every
// state of every signal in CI's blocking lane.

import Foundation

/// One signal's latest reading.
enum WorkspaceReading<Value: Equatable>: Equatable {
    /// Nothing has read it and nothing is reading it.
    case unknown
    /// The first read is in flight.
    case reading
    /// The latest read succeeded.
    case read(Value, at: Date)
    /// The latest read failed. `last` is the last good value, read at
    /// `lastReadAt`, or nil when there has never been one.
    case failed(last: Value?, lastReadAt: Date?, failedAt: Date)

    /// The value to draw: the latest, or the last good one.
    var value: Value? {
        switch self {
        case .read(let value, _): return value
        case .failed(let last, _, _): return last
        case .unknown, .reading: return nil
        }
    }

    /// A new read failed: keep what was there, and say when.
    func failing(at date: Date) -> WorkspaceReading {
        switch self {
        case .read(let value, let at): return .failed(last: value, lastReadAt: at, failedAt: date)
        case .failed(let last, let lastReadAt, _): return .failed(last: last, lastReadAt: lastReadAt, failedAt: date)
        case .unknown, .reading: return .failed(last: nil, lastReadAt: nil, failedAt: date)
        }
    }
}

/// Everything the sidebar's badges draw from.
struct WorkspaceSignals: Equatable {

    /// Poneglyph's vault, as the lock sees it.
    enum VaultState: Equatable {
        /// No vault has been created on this Mac.
        case none
        case locked
        case unlocked
        /// The vault file is there and cannot be read (GL-01).
        case unreadable
    }

    struct TasksDue: Equatable {
        var today: Int
        var overdue: Int
        var total: Int { today + overdue }
    }

    /// Setup's three counts, each nil until its check has run this session.
    struct SetupCounts: Equatable {
        var toolUpdates: Int?
        var setupDrift: Int?
        var forkDrift: Int?

        var known: [Int] { [toolUpdates, setupDrift, forkDrift].compactMap { $0 } }
        var isEmpty: Bool { known.isEmpty }
    }

    /// A service the Health page reports as failing or degraded.
    struct ServiceIssue: Equatable {
        let title: String
        let failures: Int
        let lastFailure: Date?
    }

    /// How many tasks are waiting on the captain (`needs_decision` or
    /// `blocked`), from the same read Crew › Needs you lists. Unknown when
    /// there is no firstmate home to read.
    var crew: WorkspaceReading<Int> = .reading
    var tasksDue: WorkspaceReading<TasksDue> = .unknown
    var vault: VaultState = .none
    /// At `ServiceHealthRegistry.failureThreshold` failures in a row, or more.
    var failingServices: [ServiceIssue] = []
    /// One or two failures in a row: worth a quiet dot, not an alarm.
    var degradedServices: [ServiceIssue] = []
    var setup: WorkspaceReading<SetupCounts> = .unknown
    /// Connected sessions in the registry.
    var liveSessions = 0
}

// MARK: - Badges

/// What a module's sidebar row draws on its trailing edge.
struct WorkspaceBadge: Equatable {
    enum Mark: Equatable {
        /// A count, or the dash that stands for one being read.
        case count(String)
        /// A small dot with no number.
        case dot
        /// An SF Symbol.
        case symbol(String)
    }

    /// The tint the mark takes. `neutral` is the row's own muted ink.
    enum Tone: Equatable { case neutral, attention, alarm }

    let mark: Mark
    let tone: Tone
    /// What VoiceOver reads after the module's name, and the tooltip.
    let description: String
}

extension WorkspaceSignals {

    /// The dash a count shows while its first read is in flight.
    static let scanningMark = "\u{2013}"

    /// The badge on `module`'s row, or nil for none.
    func badge(for module: WorkspaceModule, now: Date = Date()) -> WorkspaceBadge? {
        switch module {
        case .crew: return crewBadge(now: now)
        case .tasks: return tasksBadge(now: now)
        case .secrets: return vaultBadge
        case .health: return healthBadge(now: now)
        case .setup: return setupBadge(now: now)
        case .console:
            guard liveSessions > 0 else { return nil }
            return WorkspaceBadge(mark: .count("\(liveSessions)"), tone: .neutral, description: "\(liveSessions) connected")
        default: return nil
        }
    }

    private func crewBadge(now: Date) -> WorkspaceBadge? {
        switch crew {
        case .unknown: return nil
        case .reading:
            return WorkspaceBadge(mark: .count(Self.scanningMark), tone: .neutral,
                                  description: "Reading the crew\u{2019}s state")
        case .read(let waiting, _):
            guard waiting > 0 else { return nil }
            return WorkspaceBadge(mark: .count("\(waiting)"), tone: .attention, description: Self.waiting(waiting))
        case .failed(let last, let lastReadAt, let failedAt):
            let failed = "Couldn\u{2019}t read the crew\u{2019}s state at \(Self.clock(failedAt))"
            guard let last, let lastReadAt else {
                return WorkspaceBadge(mark: .count("?"), tone: .neutral, description: failed)
            }
            guard last > 0 else { return nil }
            return WorkspaceBadge(mark: .count("\(last)"), tone: .attention,
                                  description: "\(Self.waiting(last)) when last read, at \(Self.clock(lastReadAt)). \(failed)")
        }
    }

    private func tasksBadge(now: Date) -> WorkspaceBadge? {
        func describe(_ due: TasksDue) -> String {
            var parts: [String] = []
            if due.today > 0 { parts.append("\(due.today) due today") }
            if due.overdue > 0 { parts.append("\(due.overdue) overdue") }
            return parts.joined(separator: ", ")
        }
        switch tasksDue {
        case .unknown, .reading: return nil
        case .read(let due, _):
            guard due.total > 0 else { return nil }
            return WorkspaceBadge(mark: .count("\(due.total)"), tone: .neutral, description: describe(due))
        case .failed(let last, let lastReadAt, let failedAt):
            let failed = "Couldn\u{2019}t read every task file at \(Self.clock(failedAt))"
            guard let last, last.total > 0 else {
                return WorkspaceBadge(mark: .count("?"), tone: .neutral, description: failed)
            }
            let when = lastReadAt.map { " when last read, at \(Self.clock($0))" } ?? ""
            return WorkspaceBadge(mark: .count("\(last.total)"), tone: .neutral,
                                  description: "\(describe(last))\(when). \(failed)")
        }
    }

    private var vaultBadge: WorkspaceBadge? {
        switch vault {
        case .none, .unlocked: return nil
        case .locked: return WorkspaceBadge(mark: .symbol("lock.fill"), tone: .neutral, description: "Poneglyph is locked")
        case .unreadable:
            return WorkspaceBadge(mark: .symbol("exclamationmark.triangle.fill"), tone: .alarm,
                                  description: "Poneglyph\u{2019}s vault file can\u{2019}t be read")
        }
    }

    private func healthBadge(now: Date) -> WorkspaceBadge? {
        if !failingServices.isEmpty {
            return WorkspaceBadge(mark: .dot, tone: .alarm, description: Self.failing(failingServices))
        }
        if !degradedServices.isEmpty {
            let names = degradedServices.map(\.title).joined(separator: ", ")
            let checks = degradedServices.count == 1 ? "a failed check" : "failed checks"
            return WorkspaceBadge(mark: .dot, tone: .attention, description: "\(names): \(checks), not failing yet")
        }
        return nil
    }

    private func setupBadge(now: Date) -> WorkspaceBadge? {
        func describe(_ counts: SetupCounts) -> String {
            var parts: [String] = []
            if let n = counts.toolUpdates { parts.append(n == 1 ? "1 tool update" : "\(n) tool updates") }
            if let n = counts.setupDrift { parts.append(n == 1 ? "1 setup step drifted" : "\(n) setup steps drifted") }
            if let n = counts.forkDrift { parts.append(n == 1 ? "1 fork behind" : "\(n) forks behind") }
            var unchecked: [String] = []
            if counts.toolUpdates == nil { unchecked.append("tool updates") }
            if counts.setupDrift == nil { unchecked.append("setup drift") }
            if counts.forkDrift == nil { unchecked.append("forks") }
            if !unchecked.isEmpty { parts.append("\(unchecked.joined(separator: ", ")) not checked yet") }
            return parts.joined(separator: ", ")
        }
        switch setup {
        case .unknown: return nil
        case .reading:
            return WorkspaceBadge(mark: .count(Self.scanningMark), tone: .neutral, description: "Checking for updates")
        case .read(let counts, _):
            let total = counts.known.reduce(0, +)
            guard total > 0 else { return nil }
            return WorkspaceBadge(mark: .count("\(total)"), tone: .neutral, description: describe(counts))
        case .failed(let last, let lastReadAt, let failedAt):
            let failed = "The latest check failed at \(Self.clock(failedAt))"
            guard let last, !last.isEmpty else {
                return WorkspaceBadge(mark: .count("?"), tone: .neutral, description: failed)
            }
            let total = last.known.reduce(0, +)
            guard total > 0 else { return nil }
            let when = lastReadAt.map { " as of \(Self.clock($0))" } ?? ""
            return WorkspaceBadge(mark: .count("\(total)"), tone: .neutral, description: "\(describe(last))\(when). \(failed)")
        }
    }
}

// MARK: - Words

extension WorkspaceSignals {

    static func waiting(_ count: Int) -> String {
        count == 1 ? "1 task is waiting on you" : "\(count) tasks are waiting on you"
    }

    static func failing(_ services: [ServiceIssue]) -> String {
        services.count == 1
            ? "\(services[0].title) is failing"
            : "\(services.count) services are failing: \(services.map(\.title).joined(separator: ", "))"
    }

    /// "10:42", in the captain's own locale - when a reading was taken.
    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
