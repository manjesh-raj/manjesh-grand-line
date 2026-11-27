// Grand Line - native macOS app.
//
// F-02 of full review 4: plan my day, and close it.
//
// A two-minute morning flow over Home: pick up to three tasks, place them on
// today's timeline around the Mac's meetings (F-01), and start the first focus
// session. In the evening, Close the day ticks what got done and moves the
// rest. It is the Weekly review (UX-05) at day size.
//
// This file is the model and its rules, with no view in it:
//
//  - `DayPlan` is one day's plan: the picked tasks with a start and a length,
//    when it was set, and whether the day was closed.
//  - `DayPlanStore` keeps the last month of plans in one JSON file under the
//    app's data root (`FM_DAY_PLAN_DIR` overrides it). One shared instance
//    (GL-23), since it caches.
//  - `DayPlanRules` is every decision the sheets and Home make: the candidate
//    groups, the default picks, placing around meetings, the drag and resize
//    snapping, the close-the-day moves, the hero's words, and the 9:00 and
//    18:00 bell nudges.
//
// A plan does not change a task's due date. Placing a task at 14:00 is a plan
// for today, not a deadline, so the task keeps the date the captain gave it.
// Only Close the day writes to tasks: it completes what was ticked, and moves
// the rest to the day the captain chose.

import AppKit

// MARK: - The plan

struct DayPlan: Codable, Equatable {

    struct Item: Codable, Equatable {
        var taskID: String
        var title: String
        /// Minutes since local midnight.
        var startMinute: Int
        var minutes: Int

        var endMinute: Int { startMinute + minutes }
    }

    /// `"YYYY-MM-DD"`, local.
    var day: String
    var setAt: Date
    var items: [Item]
    var closedAt: Date? = nil
    /// Close the day's "one line for tomorrow". Tomorrow's Plan my day shows it.
    var tomorrowNote: String? = nil
}

struct DayPlanState: Codable, Equatable {
    var plans: [DayPlan] = []
    /// Nudge id ("morning" / "evening") to the day it was last posted, so a
    /// dismissed bell entry is not posted again the same day.
    var nudged: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        // GL-01: every key is optional, so a file from an older build reads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plans = try c.decodeIfPresent([DayPlan].self, forKey: .plans) ?? []
        nudged = try c.decodeIfPresent([String: String].self, forKey: .nudged) ?? [:]
    }
}

// MARK: - The store

final class DayPlanStore {

    static let directoryVariable = "FM_DAY_PLAN_DIR"
    /// GL-35: a month of plans is plenty for "carried over from yesterday".
    static let keptPlans = 31

    /// The app's one instance (GL-23).
    static let shared = DayPlanStore()

    let url: URL
    private(set) var state = DayPlanState()
    private var observers: [UUID: () -> Void] = [:]

    init(directory: URL? = nil) {
        let env = ProcessInfo.processInfo.environment[Self.directoryVariable]
        let dir = directory
            ?? env.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.dataRoot().appendingPathComponent("day-plan", isDirectory: true)
        url = dir.appendingPathComponent("plans.json")
        load()
    }

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func unobserve(_ token: UUID) { observers[token] = nil }

    func plan(for day: String) -> DayPlan? { state.plans.last { $0.day == day } }

    func plan(on date: Date, calendar: Calendar = .current) -> DayPlan? {
        plan(for: DayPlanRules.dayString(date))
    }

    func save(_ plan: DayPlan) {
        update { state in
            state.plans.removeAll { $0.day == plan.day }
            state.plans.append(plan)
            state.plans.sort { $0.day < $1.day }
            if state.plans.count > Self.keptPlans { state.plans.removeFirst(state.plans.count - Self.keptPlans) }
        }
    }

    func markNudged(_ id: String, day: String) {
        update { $0.nudged[id] = day }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = try decoder.decode(DayPlanState.self, from: Data(contentsOf: url))
        } catch {
            // GL-01: an unreadable file is kept aside, never read as empty
            // and then overwritten.
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("plans.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            AppLog.store.error("day plan: plans.json was unreadable and was moved aside")
        }
    }

    private func update(_ change: (inout DayPlanState) -> Void) {
        change(&state)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicWrite.data(encoder.encode(state), to: url)
        } catch {
            PersistenceFailureReporter.report(what: "Today's plan", path: url.path, error: error)
        }
        observers.values.forEach { $0() }
    }
}

// MARK: - The rules

enum DayPlanRules {

    static let maxPicks = 3
    static let dayStartMinute = MacCalendarRules.dayStartHour * 60
    static let dayEndMinute = MacCalendarRules.dayEndHour * 60
    static let defaultMinutes = 45
    static let snapMinutes = 15
    static let minimumMinutes = 15
    /// How many backlog tasks step 1 offers under the dated ones.
    static let backlogLimit = 4
    /// From this hour Home offers Close the day.
    static let eveningHour = 17
    static let morningNudgeHour = 9
    static let eveningNudgeHour = 18

    // MARK: Days

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func date(minute: Int, on day: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(minute * 60))
    }

    /// "9:45", in the 24-hour form the calendar head and the mock-up use.
    static func clock(minute: Int) -> String { String(format: "%d:%02d", minute / 60, minute % 60) }

    /// "45 min", "1h", "1h 30m".
    static func length(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : MacCalendarRules.duration(TimeInterval(minutes * 60))
    }

    // MARK: Step 1: the candidates

    enum Group: String, CaseIterable {
        case overdue, dueToday, carriedOver, backlog

        var title: String {
            switch self {
            case .overdue: return "Overdue"
            case .dueToday: return "Due today"
            case .carriedOver: return "Carried over from yesterday"
            case .backlog: return "From your backlog"
            }
        }
    }

    struct Candidate: Equatable {
        var task: ShiftTask
        var group: Group
        /// "Overdue 2 days", "Today", "Today at 15:00", "In progress", "28 Nov".
        var when: String
        var isHigh: Bool { task.priority == .high }

        static func == (a: Candidate, b: Candidate) -> Bool { a.task.id == b.task.id && a.group == b.group && a.when == b.when }
    }

    static func isOpen(_ task: ShiftTask) -> Bool { task.status == .todo || task.status == .inProgress }

    /// The tasks step 1 offers, grouped, each group in the order shown.
    /// `carried` are the task ids yesterday's plan left undone.
    static func candidates(tasks: [ShiftTask], carried: Set<String>, now: Date,
                           calendar: Calendar = .current) -> [(group: Group, items: [Candidate])] {
        let today = calendar.startOfDay(for: now)
        var overdue: [Candidate] = [], dueToday: [Candidate] = [], carriedOver: [Candidate] = [], backlog: [Candidate] = []
        for task in tasks where isOpen(task) {
            if let dueString = task.dueDate, let due = ShiftDateFormatting.date(from: dueString) {
                let dueDay = calendar.startOfDay(for: due)
                if dueDay < today {
                    let days = calendar.dateComponents([.day], from: dueDay, to: today).day ?? 1
                    overdue.append(.init(task: task, group: .overdue, when: days == 1 ? "Overdue 1 day" : "Overdue \(days) days"))
                    continue
                }
                if dueDay == today {
                    let when = task.dueTime.map { "Today at \(ShiftDateFormatting.clock($0))" } ?? "Today"
                    dueToday.append(.init(task: task, group: .dueToday, when: when))
                    continue
                }
            }
            if carried.contains(task.id) || task.status == .inProgress {
                carriedOver.append(.init(task: task, group: .carriedOver, when: task.status == .inProgress ? "In progress" : "Not done yesterday"))
                continue
            }
            let when = task.dueDate.flatMap(ShiftDateFormatting.date(from:)).map(ShiftDateFormatting.monthDay) ?? "No date"
            backlog.append(.init(task: task, group: .backlog, when: when))
        }
        func byDue(_ a: Candidate, _ b: Candidate) -> Bool {
            let ad = a.task.dueDate ?? "9999", bd = b.task.dueDate ?? "9999"
            if ad != bd { return ad < bd }
            if a.isHigh != b.isHigh { return a.isHigh }
            return a.task.title < b.task.title
        }
        backlog.sort(by: byDue)
        let groups: [(Group, [Candidate])] = [(.overdue, overdue.sorted(by: byDue)), (.dueToday, dueToday.sorted(by: byDue)),
                                              (.carriedOver, carriedOver.sorted(by: byDue)),
                                              (.backlog, Array(backlog.prefix(backlogLimit)))]
        return groups.filter { !$0.1.isEmpty }.map { (group: $0.0, items: $0.1) }
    }

    /// Step 1's ticks when it opens: the first three of the dated and carried
    /// groups. Backlog is never pre-ticked, because a day with nothing due
    /// should not fill itself.
    static func defaultPicks(_ groups: [(group: Group, items: [Candidate])]) -> [String] {
        Array(groups.filter { $0.group != .backlog }.flatMap { $0.items.map(\.task.id) }.prefix(maxPicks))
    }

    /// Whether ticking one more is allowed.
    static func canPick(more picked: Int) -> Bool { picked < maxPicks }

    static func pickedSentence(_ count: Int) -> String {
        switch count {
        case 0: return "Pick up to three."
        case maxPicks: return "\(maxPicks) of \(maxPicks) picked. Untick one to choose another."
        default: return "\(count) of \(maxPicks) picked."
        }
    }

    // MARK: Step 2: the timeline

    /// The busy minutes of today's timed meetings.
    static func busy(meetings: [MacMeeting], on day: Date, calendar: Calendar = .current) -> [ClosedRange<Int>] {
        meetings.filter { !$0.isAllDay && calendar.isDate($0.start, inSameDayAs: day) }
            .map { minuteOfDay($0.start, calendar: calendar)...max(minuteOfDay($0.start, calendar: calendar), minuteOfDay($0.end, calendar: calendar) - 1) }
    }

    static func snap(_ minute: Int) -> Int {
        Int((Double(minute) / Double(snapMinutes)).rounded()) * snapMinutes
    }

    /// Places the picks in order, each in the first free slot of its length
    /// after `now` (rounded up to the quarter hour), clear of meetings and of
    /// the picks before it. A pick that fits nowhere in the working day goes
    /// at its end, so it is still on the plan and the captain can move it.
    static func place(_ picks: [ShiftTask], meetings: [MacMeeting], now: Date, calendar: Calendar = .current) -> [DayPlan.Item] {
        var taken = busy(meetings: meetings, on: now, calendar: calendar)
        let nowMinute = minuteOfDay(now, calendar: calendar)
        let rounded = (nowMinute + snapMinutes - 1) / snapMinutes * snapMinutes
        let cursor = max(dayStartMinute, rounded)
        var items: [DayPlan.Item] = []
        for task in picks {
            let length = defaultMinutes
            var start = cursor
            var placed: Int?
            while start + length <= dayEndMinute {
                let range = start...(start + length - 1)
                if let clash = taken.first(where: { $0.overlaps(range) }) {
                    start = (clash.upperBound + 1 + snapMinutes - 1) / snapMinutes * snapMinutes
                    continue
                }
                placed = start
                break
            }
            let at = placed ?? max(cursor, dayEndMinute - length)
            items.append(.init(taskID: task.id, title: task.title, startMinute: at, minutes: length))
            taken.append(at...(at + length - 1))
        }
        return items
    }

    /// A drag of an item to `start`: snapped, and kept inside the day.
    static func moved(_ item: DayPlan.Item, toStart start: Int) -> DayPlan.Item {
        var item = item
        item.startMinute = min(max(dayStartMinute, snap(start)), dayEndMinute - item.minutes)
        return item
    }

    /// A drag of an item's bottom edge to `end`: snapped, at least a quarter
    /// hour, and not past the end of the day.
    static func resized(_ item: DayPlan.Item, toEnd end: Int) -> DayPlan.Item {
        var item = item
        let snapped = snap(end)
        item.minutes = min(max(minimumMinutes, snapped - item.startMinute), dayEndMinute - item.startMinute)
        return item
    }

    /// The meeting an item overlaps, if any, so the timeline can say so.
    static func clash(_ item: DayPlan.Item, meetings: [MacMeeting], on day: Date, calendar: Calendar = .current) -> MacMeeting? {
        let range = item.startMinute...(item.endMinute - 1)
        return meetings.first { m in
            guard !m.isAllDay, calendar.isDate(m.start, inSameDayAs: day) else { return false }
            let start = minuteOfDay(m.start, calendar: calendar)
            return (start...max(start, minuteOfDay(m.end, calendar: calendar) - 1)).overlaps(range)
        }
    }

    /// Minutes of the working day after `now` that neither a meeting nor a
    /// placed item takes.
    static func freeMinutes(items: [DayPlan.Item], meetings: [MacMeeting], now: Date, calendar: Calendar = .current) -> Int {
        let from = max(dayStartMinute, minuteOfDay(now, calendar: calendar))
        guard from < dayEndMinute else { return 0 }
        var taken = busy(meetings: meetings, on: now, calendar: calendar)
        taken += items.map { $0.startMinute...($0.endMinute - 1) }
        return (from..<dayEndMinute).filter { minute in !taken.contains { $0.contains(minute) } }.count
    }

    static func freeSentence(_ minutes: Int) -> String {
        minutes == 0 ? "The rest of the day is full." : "\(length(minutes)) still free"
    }

    // MARK: Step 3 and Home's hero

    /// The ids of tasks completed this month or the last, which is every
    /// task a plan from the kept month can name. A completed task leaves
    /// `active.yaml` for its month file, so the active list alone cannot say
    /// a planned task was done.
    static func completedIDs(store: ShiftStore, now: Date, calendar: Calendar = .current) -> Set<String> {
        let month = DateFormatter()
        month.dateFormat = "yyyy-MM"
        month.calendar = Calendar(identifier: .gregorian)
        month.locale = Locale(identifier: "en_US_POSIX")
        let last = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        var ids = Set(store.completedTasks(inMonths: [month.string(from: now), month.string(from: last)]).map(\.id))
        ids.formUnion(store.activeTasks.filter { $0.status == .completed }.map(\.id))
        return ids
    }

    /// The first item not done yet: what Start focus starts.
    static func nextItem(_ plan: DayPlan, completed: Set<String>) -> DayPlan.Item? {
        plan.items.sorted { $0.startMinute < $1.startMinute }.first { !completed.contains($0.taskID) }
    }

    struct HeroWords: Equatable {
        var kicker: String
        var title: String
        var tiles: [HelmHeroCard.Content.Tile]
    }

    /// Home's hero while a plan for today is open.
    static func heroWords(_ plan: DayPlan, completed: Set<String>, date: String) -> HeroWords {
        let done = plan.items.filter { completed.contains($0.taskID) }.count
        let total = plan.items.count
        let kicker = "\(date) \u{00B7} Today\u{2019}s plan \u{00B7} \(done) of \(total) done \u{00B7} set at \(clockTime(plan.setAt))"
        let title: String
        if let next = nextItem(plan, completed: completed) {
            title = "First up: \(next.title)"
        } else {
            title = total == 1 ? "It\u{2019}s done. Close the day when you\u{2019}re ready." : "All \(total) done. Close the day when you\u{2019}re ready."
        }
        let tiles = plan.items.sorted { $0.startMinute < $1.startMinute }.map { item -> HelmHeroCard.Content.Tile in
            let isDone = completed.contains(item.taskID)
            return .init(label: "\(clock(minute: item.startMinute)) \u{00B7} \(length(item.minutes))\(isDone ? " \u{00B7} done" : "")",
                         text: item.title, tint: isDone ? .good : nil, isLink: true)
        }
        return HeroWords(kicker: kicker, title: title, tiles: tiles)
    }

    static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        clock(minute: minuteOfDay(date, calendar: calendar))
    }

    /// Home's hero status while a session runs. It names when the session
    /// ends rather than counting down, the same rule the Focus card follows,
    /// so Home renders when the session changes and not every second.
    /// The task's name is already the hero's "First up" and the toolbar
    /// chip's, so the pill says only when.
    static func focusStatus(endsAt: Date) -> String {
        "Focusing until \(clockTime(endsAt))"
    }

    /// The hero's actions, in order.
    enum Action: String, Equatable { case planMyDay, changePlan, startFocus, closeDay }

    static func heroActions(plan: DayPlan?, hasCandidates: Bool, focusing: Bool, completed: Set<String>,
                            now: Date, calendar: Calendar = .current) -> [Action] {
        let evening = (calendar.dateComponents([.hour], from: now).hour ?? 0) >= eveningHour
        guard let plan, plan.closedAt == nil else {
            // No plan yet, or the day already closed.
            if plan?.closedAt != nil { return [] }
            return hasCandidates ? (focusing ? [.planMyDay] : [.startFocus, .planMyDay]) : [.planMyDay]
        }
        var actions: [Action] = []
        if !focusing, nextItem(plan, completed: completed) != nil { actions.append(.startFocus) }
        actions.append(evening ? .closeDay : .changePlan)
        return actions
    }

    static func title(of action: Action) -> String {
        switch action {
        case .planMyDay: return "Plan my day"
        case .changePlan: return "Change the plan"
        case .startFocus: return "Start focus"
        case .closeDay: return "Close the day"
        }
    }

    // MARK: Close the day

    enum Move: Equatable {
        case tomorrow
        case day(Date)
        case backlog
    }

    /// The task as Close the day leaves it, for one that is moved.
    static func applying(_ move: Move, to task: ShiftTask, now: Date, calendar: Calendar = .current) -> ShiftTask {
        var task = task
        switch move {
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            task.dueDate = dayString(tomorrow)
            task.dueTime = nil
        case .day(let date):
            task.dueDate = dayString(date)
            task.dueTime = nil
        case .backlog:
            task.dueDate = nil
            task.dueTime = nil
        }
        return task
    }

    /// Closes the day: completes the ticked, moves the rest, and records the
    /// note for tomorrow. Returns the closed plan, which the caller saves.
    static func close(_ plan: DayPlan, done: Set<String>, moves: [String: Move], note: String?,
                      store: ShiftStore, now: Date, calendar: Calendar = .current) -> DayPlan {
        for item in plan.items {
            if done.contains(item.taskID) {
                if let task = store.activeTasks.first(where: { $0.id == item.taskID }), task.status != .completed {
                    store.setTaskCompleted(id: item.taskID, completed: true, now: now)
                }
            } else if let move = moves[item.taskID], let task = store.activeTasks.first(where: { $0.id == item.taskID }) {
                store.updateTask(applying(move, to: task, now: now, calendar: calendar), now: now)
            }
        }
        var closed = plan
        closed.closedAt = now
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        closed.tomorrowNote = trimmed.isEmpty ? nil : trimmed
        return closed
    }

    static func closeHeadline(done: Int, total: Int) -> String {
        if total == 0 { return "Nothing was planned today." }
        if done == total { return total == 1 ? "Done. Nice work." : "All \(total) done. Nice work." }
        if done == 0 { return "None of \(total) done. Tomorrow is another go." }
        return "\(done) of \(total) done. Nice work."
    }

    static func closeDetail(focusSeconds: Int, meetings: Int, toMove: Int) -> String {
        var parts: [String] = []
        let minutes = focusSeconds / 60
        parts.append(minutes == 0 ? "No focus time" : "Focus \(minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes) min")")
        parts.append(meetings == 1 ? "1 meeting" : "\(meetings) meetings")
        parts.append(toMove == 1 ? "1 task to move" : "\(toMove) tasks to move")
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: The bell's nudges

    enum Nudge: String, Equatable {
        case morning, evening

        var id: String { "day-plan.\(rawValue)" }

        var message: String {
            switch self {
            case .morning: return "Plan your day: pick up to three tasks."
            case .evening: return "Close the day: tick what got done and move the rest."
            }
        }

        var actionTitle: String { self == .morning ? "Plan my day" : "Close the day" }
    }

    /// The nudge due now, if any. Morning from 9:00 to noon when there is no
    /// plan and something to plan. Evening from 18:00 when today's plan is
    /// still open. Each at most once a day.
    static func nudge(now: Date, plan: DayPlan?, hasCandidates: Bool, nudged: [String: String],
                      calendar: Calendar = .current) -> Nudge? {
        let hour = calendar.dateComponents([.hour], from: now).hour ?? 0
        let today = dayString(now)
        if hour >= eveningNudgeHour, let plan, plan.closedAt == nil, nudged[Nudge.evening.rawValue] != today {
            return .evening
        }
        if hour >= morningNudgeHour, hour < 12, plan == nil, hasCandidates, nudged[Nudge.morning.rawValue] != today {
            return .morning
        }
        return nil
    }
}

// MARK: - The bell's nudges

/// Posts the 9:00 "Plan your day" and 18:00 "Close the day" entries in the
/// bell, each at most once a day, and clears them once the plan is set or the
/// day closed (GL-30's pair).
final class DayPlanNudger {

    var onOpen: ((DayPlanRules.Nudge) -> Void)?
    private let store: ShiftStore
    private let plans: DayPlanStore
    private let now: () -> Date
    private var timer: Timer?

    init(store: ShiftStore, plans: DayPlanStore = .shared, now: @escaping () -> Date = DayRollover.now) {
        self.store = store
        self.plans = plans
        self.now = now
    }

    /// Arms a quarter-hourly check. A self-test or tour process never arms
    /// it; those call `check()` by hand.
    func start() {
        guard !ProcessMode.current.isIsolated, timer == nil else { return }
        let tick = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.check() }
        tick.tolerance = 5 * 60
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
    }

    /// Posts the nudge due now, if any, and returns it.
    @discardableResult
    func check() -> DayPlanRules.Nudge? {
        let at = now()
        let plan = plans.plan(on: at)
        // A plan that exists or a day that closed answers its nudge.
        if plan != nil { Feedback.clear(id: DayPlanRules.Nudge.morning.id) }
        if plan?.closedAt != nil { Feedback.clear(id: DayPlanRules.Nudge.evening.id) }
        guard !store.isInFailedLoadState else { return nil }
        let hasCandidates = store.activeTasks.contains(where: DayPlanRules.isOpen)
        guard let nudge = DayPlanRules.nudge(now: at, plan: plan, hasCandidates: hasCandidates,
                                             nudged: plans.state.nudged) else { return nil }
        plans.markNudged(nudge.rawValue, day: DayPlanRules.dayString(at))
        // A prompt, not an outcome, so it goes to the bell directly rather
        // than through `Feedback`, whose kinds are done, warning and failure.
        let open: () -> Void = { [weak self] in self?.onOpen?(nudge) }
        GrandLineNotificationCenter.shared.set(
            AppNotification(id: nudge.id, title: nudge.message, subtext: PlaceName.of(.homeCanvas),
                            source: "Plan my day",
                            clearCondition: nudge == .morning ? "Clears once today has a plan." : "Clears once the day is closed.",
                            kind: .informational, tint: .accent, date: at,
                            primaryAction: AppNotificationAction(label: nudge.actionTitle, doneMessage: "Opened", perform: open),
                            navigate: open),
            id: nudge.id)
        return nudge
    }
}
