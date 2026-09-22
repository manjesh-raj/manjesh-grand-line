// Manjesh Grand Line - native macOS app.
//
// F23 of full review #3 §8: the contract between the app and its WidgetKit
// extension. **This file is compiled into both processes** - the app target
// via SwiftPM, the extension via `Scripts/build-widget-extension.sh`'s
// explicit source list - which is the whole reason it imports nothing but
// Foundation. A widget extension cannot link `FirstmateCockpit`: it is a
// separate Mach-O in its own sandbox, and this app's real model types reach
// AppKit, `Yaml` and `SwiftTerm` within a line or two of anything useful.
//
// So the two processes share exactly three things, all of them here:
//
//   1. `GrandLineWidgetContainer` - where the shared file lives.
//   2. `GrandLineWidgetSnapshot` - the data the app publishes and the widget
//      renders. A flat, Foundation-only projection of `ShiftStore`'s tasks
//      and `StickyBoardStore`'s notes, never those types themselves.
//   3. `GrandLineWidgetDigest` - the pure derivation from a snapshot plus a
//      `now` to the rows a widget actually draws, and
//      `GrandLineWidgetActionQueue` - the reverse channel a tapped widget
//      button writes into.
//
// ## Why a published snapshot rather than the widget reading the stores
//
// The stores are the wrong shape for another process to read. `ShiftStore`
// parses a YAML *tree* under a git working tree that `ShiftGitSync` commits
// on a debounce; `StickyBoardStore` is a second store over the same clone.
// A widget timeline refresh that took a read lock on that tree - or worse,
// raced a pull - would be a data-integrity problem in exchange for nothing:
// a widget needs six task titles, not a merge engine. Publishing a small,
// versioned, read-only projection means the widget process never opens the
// captain's real data at all, which is also what keeps the *extension's*
// sandbox requirement down to one shared container.
//
// ## GL-14, which is the rule this feature is most exposed to
//
// "Unknown is never rendered as zero." A widget is the surface where that is
// easiest to get wrong, because WidgetKit will happily draw an empty
// `TimelineEntry` and the captain cannot tell "no tasks due" from "the app
// has never run since this Mac booted". So `GrandLineWidgetDigest.State`
// has a real `.unavailable` case with a reason, every caller has to switch
// on it, and `GrandLineWidgetDigest.entry(...)` returns it for a missing,
// unreadable or schema-newer file rather than an empty task list.
//
// ## GL-01
//
// `init(from:)` is hand-written with `decodeIfPresent` and a default for
// every field, and the file carries a `schemaVersion`. A snapshot written by
// a *newer* build is refused rather than half-decoded (`.unavailable`), which
// matters more here than in an in-app store: the app and the extension are
// two binaries that are updated together in one bundle but can be running
// out of step for as long as a widget process survives an app upgrade.

import Foundation

// MARK: - Where the shared file lives

/// Resolves the directory the app writes its widget snapshot into and the
/// extension reads it from.
///
/// ## The App Group, and the part of it that is genuinely blocked
///
/// The resolution order is `FM_WIDGET_DIR`, then the App Group container,
/// then a fallback under Application Support. The middle one is the real
/// answer and the other two exist for the reasons every store in this app
/// has an `FM_*` override (see the repo README's variable index) and for a
/// build that has no App Group at all.
///
/// Measured on this machine rather than assumed:
/// `containerURL(forSecurityApplicationGroupIdentifier:)` **returns a path
/// without checking any entitlement and without creating the directory** -
/// for an unsandboxed process it is little more than string construction
/// under `~/Library/Group Containers/`. That is why the app half of this
/// pipeline works today, ad-hoc signed, with no entitlement: the app is not
/// sandboxed, so it may simply write there.
///
/// The widget half is the blocked half, and precisely: a widget extension is
/// always sandboxed by the system, so reading that same directory needs the
/// `com.apple.security.application-groups` entitlement, and an App Group
/// identifier is only honoured when it is prefixed by a real Team ID and the
/// binary is signed by that team. `codesign -dv` on this app reports
/// `TeamIdentifier=not set`. See `native/Widgets/README.md` for the exact
/// list of what that gates and what it does not.
enum GrandLineWidgetContainer {

    /// The App Group the app and the extension share.
    ///
    /// Unprefixed here on purpose. The real identifier is
    /// `<TeamID>.group.com.firstmate.cockpit.native`, and the Team ID does
    /// not exist yet - so the one place it has to be filled in is this
    /// constant plus the entitlements file beside the extension, and
    /// `WidgetSnapshotSelfTest` asserts the two agree.
    static let appGroupIdentifier = "group.com.firstmate.cockpit.native"

    /// `FM_WIDGET_DIR` - the override every store in this app honours.
    static let directoryOverrideVariable = "FM_WIDGET_DIR"

    static let snapshotFileName = "widget-snapshot.json"

    /// One file per queued action rather than one queue file, so the app's
    /// drain and the extension's append never do a read-modify-write of the
    /// same bytes. Two processes, no file coordination, no lost action.
    static let actionsDirectoryName = "actions"

    static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment[directoryOverrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return group.appendingPathComponent("GrandLineWidgets", isDirectory: true)
        }
        // Reached when the App Group is genuinely unavailable (a sandboxed
        // process with no entitlement gets `nil` here). A per-process
        // fallback is better than a crash, and the snapshot it names will
        // simply not exist - which the digest reports as `.unavailable`
        // rather than as an empty day.
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support
            .appendingPathComponent("ManjeshGrandLine", isDirectory: true)
            .appendingPathComponent("GrandLineWidgets", isDirectory: true)
    }

    static func snapshotURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        directory(environment: environment, fileManager: fileManager)
            .appendingPathComponent(snapshotFileName)
    }

    static func actionsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        directory(environment: environment, fileManager: fileManager)
            .appendingPathComponent(actionsDirectoryName, isDirectory: true)
    }
}

// MARK: - The widget kinds

/// The two widget kind strings.
///
/// Here rather than on the `Widget` types themselves for a concrete reason:
/// `Widget` is `@MainActor`-isolated, so a `static let kind` on one cannot be
/// read from an `AppIntent.perform()` (which is not) - Swift 6 rejects it
/// outright. They also belong to the contract: the app may one day reload a
/// single kind rather than all of them, and that call needs the same string
/// the extension registered.
enum GrandLineWidgetKind {
    static let tasksDue = "com.firstmate.cockpit.native.widget.tasks-due"
    static let stickyNote = "com.firstmate.cockpit.native.widget.sticky-note"
}

// MARK: - The published snapshot

/// What the app publishes for the widgets to read.
///
/// Every field is a projection chosen because a widget draws it. There is
/// deliberately no "all tasks" array and no note body longer than a widget
/// can show: this file sits in a shared container, and a snapshot is the one
/// copy of the captain's data that leaves the app's own storage.
struct GrandLineWidgetSnapshot: Codable, Equatable {

    /// Bumped when a field's *meaning* changes. A snapshot whose version is
    /// higher than this build understands is refused whole (GL-01), so this
    /// is not a free-form "format tweaked" counter.
    static let currentSchemaVersion = 1

    /// How many tasks a snapshot carries. A widget shows at most four, and
    /// the extra rows are there so a family that shows more never needs a
    /// republish. GL-35: a cap rather than "however many are due".
    static let taskLimit = 12

    /// Same reasoning for notes. The sticky widget's configuration picker
    /// lists these, so the cap is also the length of that list.
    static let stickyLimit = 12

    /// The longest note body a snapshot carries. A widget truncates well
    /// before this; the cap is about what leaves the app's storage.
    static let stickyBodyLimit = 400

    /// Whether the app was in a state where it was willing to publish the
    /// captain's data at all.
    enum Availability: String, Codable {
        /// A real snapshot of real data.
        case ready
        /// The app lock is engaged (GL-09). The widget renders a locked
        /// state; it does **not** render "nothing due", and the previous
        /// snapshot's rows are overwritten rather than left on the desktop.
        case locked
    }

    /// Which of the app's two registers the widget should draw in.
    ///
    /// Carried in the snapshot rather than read from the widget's own
    /// `colorScheme` environment, because the app's theme is the captain's
    /// own explicit choice out of fourteen palettes and is **not** the
    /// system appearance - Dusk (dark) is the default on a Mac that may well
    /// be in light mode. `ThemeManager.shared.theme.mode` is the one place
    /// that decides, and this is that decision travelling to the second
    /// process. The widget falls back to the environment only when there is
    /// no snapshot to read at all.
    enum Appearance: String, Codable {
        case light, dark
    }

    var schemaVersion: Int
    var generatedAt: Date
    var availability: Availability
    var appearance: Appearance
    var tasks: [Task]
    var stickies: [Sticky]
    /// Every open task, not just the ones carried in `tasks` - this is what
    /// makes "3 of 6 open" honest.
    var openTaskCount: Int
    var pendingFollowUpCount: Int

    init(
        schemaVersion: Int = GrandLineWidgetSnapshot.currentSchemaVersion,
        generatedAt: Date,
        availability: Availability = .ready,
        appearance: Appearance = .dark,
        tasks: [Task] = [],
        stickies: [Sticky] = [],
        openTaskCount: Int = 0,
        pendingFollowUpCount: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.availability = availability
        self.appearance = appearance
        self.tasks = tasks
        self.stickies = stickies
        self.openTaskCount = openTaskCount
        self.pendingFollowUpCount = pendingFollowUpCount
    }

    // GL-01: hand-written, `decodeIfPresent` with a default for every field.
    // A Swift-side default does not make a declared key optional to the
    // synthesised decoder, and this file is read by a build that may be
    // older than the one that wrote it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        availability = try c.decodeIfPresent(Availability.self, forKey: .availability) ?? .ready
        // Dusk, because that is the app's own default theme - a snapshot from
        // a build that predates this field is overwhelmingly likely to have
        // been written by an app running in the dark register.
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .dark
        tasks = try c.decodeIfPresent([Task].self, forKey: .tasks) ?? []
        stickies = try c.decodeIfPresent([Sticky].self, forKey: .stickies) ?? []
        openTaskCount = try c.decodeIfPresent(Int.self, forKey: .openTaskCount) ?? tasks.count
        pendingFollowUpCount = try c.decodeIfPresent(Int.self, forKey: .pendingFollowUpCount) ?? 0
    }

    /// One task, flattened.
    struct Task: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        /// `ShiftPriority`'s raw value (`low`/`normal`/`high`). A string
        /// rather than a shared enum so a value this build has never heard
        /// of degrades to "not high" instead of failing the whole decode.
        var priority: String
        /// The due instant, or `nil` for an undated task. When the task has
        /// no due *time* this is the start of its due day in the app's own
        /// calendar, and `hasDueTime` says so - which is what lets the
        /// widget avoid printing "09:00" for a task that never named one.
        var dueAt: Date?
        var hasDueTime: Bool
        /// `ShiftRecurrence.displayName` verbatim ("Every weekday"), or
        /// `nil`. Carried as the app's own rendered string rather than as a
        /// parsed rule so the widget cannot word a rule differently from the
        /// task row the captain already knows - that derivation has one home
        /// and it is not this file.
        var recurrenceSummary: String?

        var isHighPriority: Bool { priority == "high" }

        init(
            id: String,
            title: String,
            priority: String = "normal",
            dueAt: Date? = nil,
            hasDueTime: Bool = false,
            recurrenceSummary: String? = nil
        ) {
            self.id = id
            self.title = title
            self.priority = priority
            self.dueAt = dueAt
            self.hasDueTime = hasDueTime
            self.recurrenceSummary = recurrenceSummary
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "normal"
            dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
            hasDueTime = try c.decodeIfPresent(Bool.self, forKey: .hasDueTime) ?? false
            recurrenceSummary = try c.decodeIfPresent(String.self, forKey: .recurrenceSummary)
        }
    }

    /// One sticky note, flattened.
    ///
    /// The paper and ink hexes travel **with the note** rather than being
    /// re-derived in the extension from a colour name. `StickyBoardModels`'
    /// own header is explicit that the six paper hues are literal values and
    /// a deliberate exception to this app's theme-token rule; copying that
    /// table into a second binary is exactly how the two would drift.
    struct Sticky: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var body: String
        var paperHex: String
        var inkHex: String
        var createdAt: Date
        /// Checklist progress, or `nil` for a plain text note. Two optionals
        /// rather than a `0/0`, for the reason `StickyNote.checklist` is
        /// itself optional: an emptied checklist and a text note are
        /// different things.
        var checklistDone: Int?
        var checklistTotal: Int?

        var isChecklist: Bool { checklistTotal != nil }

        init(
            id: String,
            title: String,
            body: String,
            paperHex: String,
            inkHex: String,
            createdAt: Date,
            checklistDone: Int? = nil,
            checklistTotal: Int? = nil
        ) {
            self.id = id
            self.title = title
            self.body = body
            self.paperHex = paperHex
            self.inkHex = inkHex
            self.createdAt = createdAt
            self.checklistDone = checklistDone
            self.checklistTotal = checklistTotal
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
            paperHex = try c.decodeIfPresent(String.self, forKey: .paperHex) ?? "FFE066"
            inkHex = try c.decodeIfPresent(String.self, forKey: .inkHex) ?? "3A2E00"
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
            checklistDone = try c.decodeIfPresent(Int.self, forKey: .checklistDone)
            checklistTotal = try c.decodeIfPresent(Int.self, forKey: .checklistTotal)
        }
    }

    // MARK: Coding

    /// One encoder/decoder pair for both processes, so a field cannot be
    /// written with one date strategy and read with another - which is the
    /// silent way this pipeline would fail, since `.deferredToDate` and
    /// `.iso8601` both decode *something*.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - The derivation both widgets draw from

/// Snapshot plus `now` in, rows out. Pure, `Foundation`-only, and the whole
/// reason this feature has real tests despite its rendering half being
/// unverifiable in this environment: "which four tasks, in which order, with
/// which sub-label, and does the footer read honestly" is the part of a
/// widget that can actually be wrong, and none of it needs WidgetKit.
///
/// AGENTS.md's "a live-updating view reads its numbers from one injectable
/// clock" applies directly: `now` is a parameter, never `Date()`. A widget is
/// the extreme case of that rule - WidgetKit renders an entry at a *future*
/// instant it chose, so a digest that read the wall clock would label rows
/// against a different day than the entry it is drawing.
enum GrandLineWidgetDigest {

    /// How far ahead a widget looks. Past this, a task is not "soon" and
    /// showing it would crowd out something that is.
    static let horizonDays = 7

    /// A snapshot older than this is still drawn - overdue is still overdue -
    /// but it is drawn as *dated*, with its own timestamp in the footer
    /// rather than a reassuring "updated 14:20". GL-14 in its subtler form:
    /// the captain has to be able to tell a quiet day from an app that has
    /// not run since Friday.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    /// Why there is nothing to draw. Each case has its own copy, because
    /// "the app has never published" and "this file is corrupt" want
    /// different things from the reader.
    enum Unavailable: String, Equatable {
        /// No snapshot file at all - the app has never run on this Mac, or
        /// the extension cannot see the shared container (which, until the
        /// App Group entitlement lands, is the expected case - see
        /// `GrandLineWidgetContainer`).
        case neverPublished
        /// The file exists and this build could not decode it (GL-01).
        case unreadable
        /// The file was written by a newer build than this extension.
        case schemaTooNew

        /// The one line a widget prints. Deliberately not "No tasks".
        var headline: String {
            switch self {
            case .neverPublished: return "Not available"
            case .unreadable: return "Not available"
            case .schemaTooNew: return "Update needed"
            }
        }

        var detail: String {
            switch self {
            case .neverPublished: return "Open Manjesh Grand Line once to publish your tasks."
            case .unreadable: return "The shared snapshot could not be read."
            case .schemaTooNew: return "This widget is older than the app. Restart the Mac to reload it."
            }
        }
    }

    /// What a timeline entry carries.
    enum State: Equatable {
        case ready(GrandLineWidgetSnapshot)
        /// The app lock is on. Its own case rather than an `Unavailable`
        /// reason: this is not a failure, and it is the one state where the
        /// right thing to draw is the app's own mark and nothing else.
        case locked
        case unavailable(Unavailable)
    }

    // MARK: Loading

    /// Reads the published snapshot. Never throws, never returns an empty
    /// snapshot in place of a missing one.
    static func load(
        from url: URL,
        fileManager: FileManager = .default
    ) -> State {
        guard let data = fileManager.contents(atPath: url.path) else {
            return .unavailable(.neverPublished)
        }
        guard let snapshot = try? GrandLineWidgetSnapshot.makeDecoder()
            .decode(GrandLineWidgetSnapshot.self, from: data) else {
            return .unavailable(.unreadable)
        }
        if snapshot.schemaVersion > GrandLineWidgetSnapshot.currentSchemaVersion {
            return .unavailable(.schemaTooNew)
        }
        // A file written by a build so old it had no version at all is not
        // something to guess at either.
        if snapshot.schemaVersion < 1 { return .unavailable(.unreadable) }
        if snapshot.availability == .locked { return .locked }
        return .ready(snapshot)
    }

    // MARK: Tasks

    /// Where a task sits relative to the entry's own day. Drives colour, not
    /// wording - the wording is `detail`.
    enum Urgency: String, Equatable {
        case overdue, today, tomorrow, soon
    }

    struct TaskRow: Equatable, Identifiable {
        let id: String
        let title: String
        let urgency: Urgency
        /// The one sub-line the medium family prints under the title.
        let detail: String
        let isHighPriority: Bool

        var isOverdue: Bool { urgency == .overdue }
    }

    struct TaskDigest: Equatable {
        let rows: [TaskRow]
        /// Overdue tasks across the whole snapshot, not just the rows shown -
        /// the small family's "1 late" pill.
        let lateCount: Int
        let openTaskCount: Int
        let pendingFollowUpCount: Int
        let generatedAt: Date
        let isStale: Bool

        /// "3 of 6 open". `rows.count` rather than a second count, so the
        /// number cannot disagree with what is on screen.
        var openSummary: String { "\(rows.count) of \(openTaskCount) open" }

        /// "2 follow-ups pending", or `nil` when there are none - an absent
        /// line rather than "0 follow-ups", which is the same instinct GL-14
        /// is about even where zero is genuinely known.
        var followUpSummary: String? {
            switch pendingFollowUpCount {
            case 0: return nil
            case 1: return "1 follow-up pending"
            default: return "\(pendingFollowUpCount) follow-ups pending"
            }
        }
    }

    /// The rows to draw, ordered soonest-first with overdue at the top.
    ///
    /// Undated tasks are deliberately absent. A widget's claim is "here is
    /// what your day needs", and a task with no due date makes no claim on
    /// today - it is still counted in `openTaskCount`, which is what keeps
    /// "3 of 6 open" from implying the other three do not exist.
    static func taskDigest(
        from snapshot: GrandLineWidgetSnapshot,
        now: Date,
        calendar: Calendar = .current,
        limit: Int,
        staleAfter: TimeInterval = GrandLineWidgetDigest.staleAfter
    ) -> TaskDigest {
        let startOfToday = calendar.startOfDay(for: now)
        let horizonEnd = calendar.date(byAdding: .day, value: horizonDays, to: startOfToday) ?? startOfToday

        let dated = snapshot.tasks.compactMap { task -> (GrandLineWidgetSnapshot.Task, Date)? in
            guard let dueAt = task.dueAt else { return nil }
            return (task, dueAt)
        }

        let inWindow = dated.filter { $0.1 < horizonEnd }
        let ordered = inWindow.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.id < rhs.0.id      // stable, so two same-minute tasks do not swap between refreshes
        }

        let rows = ordered.prefix(limit).map { task, dueAt in
            let urgency = self.urgency(of: dueAt, now: now, startOfToday: startOfToday, calendar: calendar)
            return TaskRow(
                id: task.id,
                title: task.title,
                urgency: urgency,
                detail: detail(for: task, urgency: urgency, dueAt: dueAt, calendar: calendar),
                isHighPriority: task.isHighPriority
            )
        }

        // Counted over every dated task in the snapshot, not the window: a
        // task three weeks late is not shown and is certainly still late.
        //
        // Through `urgency` rather than a bare `dueAt < now`, and that
        // distinction is load-bearing: a task due *today* with no due time
        // sits at the start of its own day, so a raw comparison calls it late
        // from 00:01 onwards. The pill would then read "3 late" beside three
        // rows the same digest labels "today", which is the widget
        // contradicting itself on a 168pt canvas.
        let lateCount = dated.filter {
            self.urgency(of: $0.1, now: now, startOfToday: startOfToday, calendar: calendar) == .overdue
        }.count

        return TaskDigest(
            rows: Array(rows),
            lateCount: lateCount,
            openTaskCount: snapshot.openTaskCount,
            pendingFollowUpCount: snapshot.pendingFollowUpCount,
            generatedAt: snapshot.generatedAt,
            isStale: now.timeIntervalSince(snapshot.generatedAt) > staleAfter
        )
    }

    static func urgency(
        of dueAt: Date,
        now: Date,
        startOfToday: Date,
        calendar: Calendar = .current
    ) -> Urgency {
        // A task due at 09:00 today, read at 14:00, is overdue - the time is
        // the claim, not the day. One with **no** due time lands on the start
        // of its own day, and would otherwise read overdue from 00:01 on the
        // day it is due, so that one instant is excluded. Any earlier day's
        // start is strictly less than `startOfToday` and still overdue, which
        // is why this is one comparison rather than a day check plus a time
        // check.
        if dueAt < now && dueAt != startOfToday { return .overdue }
        if calendar.isDate(dueAt, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
           calendar.isDate(dueAt, inSameDayAs: tomorrow) {
            return .tomorrow
        }
        return .soon
    }

    /// The medium family's sub-line.
    ///
    /// Four shapes, in this precedence: `overdue` alone, `High · <when>`,
    /// `<when> · repeats`, `<when>`. That is the reviewed mockup's own set
    /// of labels, with one deliberate change: a recurring task keeps its
    /// *when* and gains a `repeats` marker, rather than the mockup's
    /// `repeats weekdays` replacing the due day. The rule's own wording lives
    /// in `ShiftRecurrence.displayName` and has exactly one home; a second
    /// rendering of it in a second binary is how the two drift.
    static func detail(
        for task: GrandLineWidgetSnapshot.Task,
        urgency: Urgency,
        dueAt: Date,
        calendar: Calendar = .current
    ) -> String {
        if urgency == .overdue { return "overdue" }
        let when = whenLabel(for: dueAt, urgency: urgency, hasDueTime: task.hasDueTime, calendar: calendar)
        if task.isHighPriority { return "High · \(when)" }
        if task.recurrenceSummary != nil { return "\(when) · repeats" }
        return when
    }

    /// "today", "today 14:00", "tomorrow", "Mon 28 Sep".
    static func whenLabel(
        for dueAt: Date,
        urgency: Urgency,
        hasDueTime: Bool,
        calendar: Calendar = .current
    ) -> String {
        let day: String
        switch urgency {
        case .today, .overdue: day = "today"
        case .tomorrow: day = "tomorrow"
        case .soon: day = dayFormatter(calendar: calendar).string(from: dueAt)
        }
        guard hasDueTime else { return day }
        return "\(day) \(timeFormatter(calendar: calendar).string(from: dueAt))"
    }

    // GL-P3: `DateFormatter` construction is measurably expensive and these
    // carry no per-call state. Keyed by the calendar's identity so a suite
    // pinning a UTC calendar is not served a cached formatter in the host's
    // own zone - which is the one way a cached formatter would make a test
    // lie.
    private static let formatterLock = NSLock()
    private static var dayFormatters: [String: DateFormatter] = [:]
    private static var timeFormatters: [String: DateFormatter] = [:]

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let key = formatterKey(for: calendar)
        if let cached = dayFormatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        dayFormatters[key] = formatter
        return formatter
    }

    private static func timeFormatter(calendar: Calendar) -> DateFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let key = formatterKey(for: calendar)
        if let cached = timeFormatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("jm")
        timeFormatters[key] = formatter
        return formatter
    }

    private static func formatterKey(for calendar: Calendar) -> String {
        "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(calendar.locale?.identifier ?? "current")"
    }

    /// The medium family's header: "Monday 21 September", from the entry's
    /// own date rather than the wall clock.
    static func headline(for now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return formatter.string(from: now)
    }

    // MARK: Stickies

    /// The notes to draw, newest first, with the captain's configured note
    /// hoisted to the front when it is still in the snapshot.
    ///
    /// The configured note is what the reviewed mockup labels `STICKY ·
    /// PINNED`. There is no `pinned` flag on `StickyNote` and this does not
    /// add one: a widget's own configuration is where WidgetKit expects that
    /// choice to live, it is per-widget (two sticky widgets can show two
    /// different notes), and inventing a board-level pin would have been a
    /// model change driven by a widget.
    static func stickyRows(
        from snapshot: GrandLineWidgetSnapshot,
        preferredID: String?,
        limit: Int
    ) -> [GrandLineWidgetSnapshot.Sticky] {
        let ordered = snapshot.stickies.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
        guard let preferredID, let index = ordered.firstIndex(where: { $0.id == preferredID }) else {
            return Array(ordered.prefix(limit))
        }
        var hoisted = ordered
        let pinned = hoisted.remove(at: index)
        hoisted.insert(pinned, at: 0)
        return Array(hoisted.prefix(limit))
    }

    /// "STICKY · PINNED" when the captain chose this note, "STICKY · NEWEST"
    /// when the widget is showing whatever is latest. The distinction is the
    /// honest one: an unconfigured widget's note will change under the
    /// captain, and the kicker is what says so.
    static func stickyKicker(preferredID: String?, resolvedID: String?) -> String {
        let suffix = isPinned(preferredID: preferredID, resolvedID: resolvedID) ? pinnedMarker : "NEWEST"
        return "STICKY · \(suffix)"
    }

    /// The medium family's per-note badge: the marker on a genuinely pinned
    /// note, and **nothing at all** otherwise.
    ///
    /// `nil` rather than "NEWEST" because the medium family draws three notes
    /// under one header that already says "Sticky Board" - measured in a real
    /// `ImageRenderer` pass, a kicker on every note repeated the same word
    /// three times and wrapped to two lines at 110pt of column, costing a
    /// line of each note's own body. Derived from the same comparison as the
    /// kicker above, so the two surfaces cannot disagree about which note is
    /// pinned.
    static func stickyBadge(preferredID: String?, resolvedID: String?) -> String? {
        isPinned(preferredID: preferredID, resolvedID: resolvedID) ? pinnedMarker : nil
    }

    static let pinnedMarker = "PINNED"

    private static func isPinned(preferredID: String?, resolvedID: String?) -> Bool {
        guard let preferredID, let resolvedID else { return false }
        return preferredID == resolvedID
    }
}

// MARK: - The reverse channel

/// What a tapped widget button asks the app to do.
///
/// macOS 14's interactive widgets run an `AppIntent` **in the extension's own
/// process**, which cannot write the captain's task files: they are YAML
/// under a git working tree that `ShiftGitSync` owns on a serial queue, and a
/// second writer would race `.git/index.lock` (this repo has already paid for
/// that lesson once - see AGENTS.md's "Stores, subprocesses and secrets").
///
/// So a tap does not perform the write. It records the *request* in the
/// shared container, and the app applies it through the same
/// `ShiftStore.setStatus` path the Tasks page uses, with the same git sync
/// and the same recurrence handling. The app drains on launch and on
/// activation.
///
/// One file per action, named by its own id, for a specific reason: two
/// processes appending to one queue file with no file coordination lose
/// actions, and a widget tap that silently does nothing is worse than a
/// widget that cannot tick at all.
enum GrandLineWidgetAction {

    /// GL-35: nothing unbounded. A drain that never runs (the app is not
    /// installed, or never opened again) must not let a stuck widget fill the
    /// container - the oldest are dropped past this.
    static let queueCap = 64

    struct Request: Codable, Equatable, Identifiable {
        enum Kind: String, Codable {
            case completeTask
        }

        var id: String
        var kind: Kind
        var taskID: String
        var requestedAt: Date

        init(id: String = UUID().uuidString, kind: Kind, taskID: String, requestedAt: Date) {
            self.id = id
            self.kind = kind
            self.taskID = taskID
            self.requestedAt = requestedAt
        }

        // GL-01, same reasoning as the snapshot's own decoder: this file is
        // written by one binary and read by another.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            guard let kind = try c.decodeIfPresent(Kind.self, forKey: .kind) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: c, debugDescription: "unknown widget action kind"
                )
            }
            self.kind = kind
            taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
            requestedAt = try c.decodeIfPresent(Date.self, forKey: .requestedAt) ?? .distantPast
        }
    }

    /// Writes one request into the shared container. Called from the
    /// extension.
    ///
    /// Throws rather than swallowing: GL-10's rule is no silent `try?` on a
    /// persistence write, and here the caller is an `AppIntent` whose thrown
    /// error is what tells WidgetKit the tap failed.
    static func enqueue(
        _ request: Request,
        directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = GrandLineWidgetSnapshot.makeEncoder()
        let url = directory.appendingPathComponent("\(request.id).json")
        try encoder.encode(request).write(to: url, options: .atomic)
        prune(directory: directory, fileManager: fileManager)
    }

    /// Every pending request, oldest first, paired with the file it came
    /// from so the caller can delete exactly what it applied.
    ///
    /// A file that will not decode is returned in `unreadable` rather than
    /// ignored - GL-01's "file present but unreadable is its own state" - so
    /// the drain can delete it deliberately instead of retrying it forever.
    static func pending(
        directory: URL,
        fileManager: FileManager = .default
    ) -> (requests: [(request: Request, url: URL)], unreadable: [URL]) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return ([], [])
        }
        let decoder = GrandLineWidgetSnapshot.makeDecoder()
        var requests: [(request: Request, url: URL)] = []
        var unreadable: [URL] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = fileManager.contents(atPath: url.path),
                  let request = try? decoder.decode(Request.self, from: data) else {
                unreadable.append(url)
                continue
            }
            requests.append((request, url))
        }
        requests.sort { lhs, rhs in
            if lhs.request.requestedAt != rhs.request.requestedAt {
                return lhs.request.requestedAt < rhs.request.requestedAt
            }
            return lhs.request.id < rhs.request.id
        }
        return (requests, unreadable)
    }

    private static func prune(directory: URL, fileManager: FileManager) {
        let found = pending(directory: directory, fileManager: fileManager)
        let all = found.requests
        guard all.count > queueCap else { return }
        for entry in all.prefix(all.count - queueCap) {
            try? fileManager.removeItem(at: entry.url)
        }
    }
}
