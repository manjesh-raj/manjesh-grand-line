// Grand Line - native macOS app.
//
// The pure half of Home's feel pass (the Fable second-opinion review's Stage
// 1, cut to the feasibility audit's items 1 to 3): the greeting's two lines,
// the briefing hero's words and the KPI strip's four tiles. No view and no
// store here - the canvas hands each function what it already holds (rule 1
// of `HomeCanvasController`'s header), and `FeelPassSelfTest` drives every
// branch headless.

import Foundation

// MARK: - The greeting

/// "Good morning, Manjesh" over "Wednesday, 18 November. 1 task needs your
/// call, 2 tasks are due today and 1 service needs a look." - the
/// prototype's page title and its one-line summary.
enum HomeGreeting {

    /// The figures the summary sentence is built from. `nil` is a figure this
    /// render has not read, and is left out of the sentence rather than
    /// spoken as zero (GL-14).
    struct Facts: Equatable {
        var dueToday: Int?
        var overdue: Int?
        /// The fleet's verdict when it needs the captain ("1 task needs your
        /// call"), as `FleetGreeting` words it; `nil` when it does not.
        var fleetNeedsYou: String? = nil
        var prsReady: Int?
        var servicesFailing: Int?
    }

    /// The captain's name: the fleet's own (`FM_CAPTAIN`, which the Fleet
    /// page's greeting already uses) when a snapshot has arrived, else the
    /// first word of the account's full name, else the account name.
    static func captainName(fleetCaptain: String?, fullName: String = NSFullUserName(),
                            userName: String = NSUserName()) -> String {
        if let fleetCaptain, !fleetCaptain.isEmpty { return fleetCaptain }
        let first = fullName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? userName : first
    }

    static func title(captain: String, now: Date = Date()) -> String {
        FleetGreeting.greeting(captain: captain, at: now)
    }

    /// The date, then one sentence of what is worth knowing first.
    static func summary(_ facts: Facts, now: Date = Date()) -> String {
        let date = now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return "\(date). \(sentence(facts))"
    }

    static func sentence(_ facts: Facts) -> String {
        var parts: [String] = []
        if let fleet = facts.fleetNeedsYou, !fleet.isEmpty {
            // Mid-sentence, so the verdict's own capital goes.
            let clause = fleet.prefix(1).lowercased() + fleet.dropFirst()
            parts.append(clause.hasSuffix(".") ? String(clause.dropLast()) : clause)
        }
        let due = facts.dueToday ?? 0
        let late = facts.overdue ?? 0
        if due > 0 {
            parts.append(late > 0
                ? "\(counted(due, "task")) \(due == 1 ? "is" : "are") due, \(late) overdue"
                : "\(counted(due, "task")) \(due == 1 ? "is" : "are") due today")
        }
        if let prs = facts.prsReady, prs > 0 {
            parts.append("\(counted(prs, "PR")) \(prs == 1 ? "is" : "are") ready to merge")
        }
        if let failing = facts.servicesFailing, failing > 0 {
            parts.append("\(counted(failing, "service")) \(failing == 1 ? "needs" : "need") a look")
        }
        guard !parts.isEmpty else {
            // Only an all-clear when every figure was actually read.
            let read = facts.dueToday != nil
            return read ? "Nothing is due today." : "Your day is still being read."
        }
        var joined: String
        if parts.count == 1 {
            joined = parts[0]
        } else {
            joined = parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
        joined = joined.prefix(1).uppercased() + joined.dropFirst()
        return joined + "."
    }

    static func counted(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

// MARK: - The briefing hero

/// What the briefing hero says, from the stored briefing.
enum HomeBriefingHero {

    /// The first clause is the headline and the rest is the body - the
    /// prototype's "2 calls need you" over its two supporting sentences. With
    /// no briefing today the hero says why, in `fillBriefing`'s own words.
    static func words(record: MorningBriefingRecord?, enabled: Bool,
                      settingsName: String) -> (title: String, body: String) {
        guard let record, let first = record.clauses.first else {
            return enabled
                ? ("Not generated yet today", "Your first briefing of the day appears here.")
                : ("Morning briefing is off",
                   "Turn on Morning briefing in \(settingsName) to get one short summary each morning.")
        }
        let rest = record.clauses.dropFirst().map(\.text).joined(separator: " ")
        return (first.text, rest)
    }
}

// MARK: - Today's task figures

/// The task figures the greeting and the KPI strip share, read once per
/// render from the injected store's in-memory lists.
struct HomeTaskCounts: Equatable {
    /// Open tasks due today or earlier.
    var due: Int
    /// Of those, the ones already late (`ShiftDue`'s one definition).
    var overdue: Int
    /// Pending follow-ups due today or earlier.
    var followUpsDue: Int
    /// Tasks completed today.
    var doneToday: Int

    /// `nil` when the store failed to load: "could not read" is not "nothing
    /// due" (GL-14, GL-01).
    init?(store: ShiftStore, now: Date = Date()) {
        guard !store.isInFailedLoadState else { return nil }
        self.init(tasks: store.activeTasks, followUps: store.followUps, now: now)
    }

    init(tasks: [ShiftTask], followUps: [ShiftFollowUp], now: Date = Date(), calendar: Calendar = .current) {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = startOfToday.addingTimeInterval(24 * 60 * 60)
        var due = 0, overdue = 0, done = 0
        for task in tasks {
            switch task.status {
            case .todo, .inProgress:
                guard let at = ShiftDateFormatting.dateTime(from: task.dueDate, time: task.dueTime),
                      at < endOfToday else { continue }
                due += 1
                if let late = ShiftDue.overdueInstant(date: task.dueDate, time: task.dueTime, calendar: calendar),
                   late <= now {
                    overdue += 1
                }
            case .completed:
                if let completed = task.completedAt.flatMap(ShiftStore.date(fromISO8601:)),
                   completed >= startOfToday, completed < endOfToday {
                    done += 1
                }
            case .cancelled:
                continue
            }
        }
        var followUpsDue = 0
        for item in followUps where item.status == .pending {
            guard let at = ShiftDateFormatting.dateTime(from: item.followUpAt, time: item.followUpTime),
                  at < endOfToday else { continue }
            followUpsDue += 1
        }
        self.due = due
        self.overdue = overdue
        self.followUpsDue = followUpsDue
        self.doneToday = done
    }
}
