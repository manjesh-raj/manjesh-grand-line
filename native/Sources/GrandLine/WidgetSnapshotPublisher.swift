// Grand Line - native macOS app.
//
// F23's app half: build a `GrandLineWidgetSnapshot` from the real stores,
// write it into the shared container, and tell WidgetKit to reload. Also the
// other direction - drain the requests a tapped widget button left behind and
// apply them through `ShiftStore`, which is the only writer of the captain's
// task files.
//
// The widget's own half (its SwiftUI views, its timeline providers and the
// `AppIntent` behind a tick) lives in `native/Widgets/GrandLineWidgets/` and
// is built by `Scripts/build-widget-extension.sh`, not by SwiftPM - a widget
// extension is a separate `.appex` bundle and SwiftPM has no bundle target.
// See `native/Widgets/README.md` for what that build can and cannot prove in
// this environment.
//
// ## What is pure and why
//
// Everything that decides *content* is `static` and takes its inputs as
// values: `snapshot(tasks:followUps:notes:now:availability:calendar:)` is a
// function of four arrays and a clock. That is what lets
// `WidgetSnapshotSelfTest` assert the published bytes against pinned
// fixtures in CI's blocking lane, with no window, no WidgetKit and no
// captain data. The instance methods are the wiring: observers, a debounce,
// the lock gate, `WidgetCenter`.
//
// ## GL-13
//
// Publishing is debounced and event-driven - the store changed, the app was
// activated, the lock flipped. There is no timer: a widget's refresh cadence
// is WidgetKit's business (the providers ask for the next hour boundary), and
// a poller here would burn the captain's battery to rewrite an identical file.
// A publish whose bytes match what is already on disk is dropped before the
// write, so a noisy observer costs one comparison rather than a write plus a
// timeline reload.

import AppKit
import Foundation
import WidgetKit

final class WidgetSnapshotPublisher {

    /// Coalescing window. A single task edit fires several store
    /// notifications (the array's `didSet`, then the persist, then the git
    /// sync's own status change), and a widget does not need three writes.
    static let debounceInterval: TimeInterval = 1.5

    private let shiftStore: ShiftStore
    private let stickyStore: StickyBoardStore
    private let directory: URL
    private let fileManager: FileManager
    /// Injected so a suite can assert a reload was asked for without
    /// WidgetKit being present, and so the publisher is testable off a real
    /// widget host. Production passes `WidgetCenter`'s own reload.
    private let reloadTimelines: () -> Void
    /// Injected for the same reason `FocusTimerController.clock` is: a suite
    /// drives a fabricated instant, and a publisher that read `Date()` would
    /// measure the real one.
    private let clock: () -> Date
    private let calendar: Calendar

    private var pendingPublish: DispatchWorkItem?
    private var lastPublishedBytes: Data?
    private var started = false

    init(
        shiftStore: ShiftStore,
        stickyStore: StickyBoardStore,
        directory: URL = GrandLineWidgetContainer.directory(),
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        clock: @escaping () -> Date = { Date() },
        reloadTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.shiftStore = shiftStore
        self.stickyStore = stickyStore
        self.directory = directory
        self.fileManager = fileManager
        self.calendar = calendar
        self.clock = clock
        self.reloadTimelines = reloadTimelines
    }

    var snapshotURL: URL { directory.appendingPathComponent(GrandLineWidgetContainer.snapshotFileName) }
    var actionsDirectory: URL {
        directory.appendingPathComponent(GrandLineWidgetContainer.actionsDirectoryName, isDirectory: true)
    }

    // MARK: Wiring

    /// Registers the observers and publishes once. Idempotent - a second
    /// call is a no-op rather than a second set of handlers, since
    /// `ShiftStore.observe` has no way to remove one.
    func start() {
        guard !started else { return }
        started = true

        shiftStore.observe { [weak self] in self?.publishSoon() }
        stickyStore.observe { [weak self] in self?.publishSoon() }

        // GL-09: the lock is a state the widget must reflect, not just a
        // gate on this method. Flipping it republishes, which is what
        // *overwrites* the rows already sitting on the desktop - a gate that
        // only refused to write would leave the captain's tasks visible to
        // whoever locked the app.
        AppLockGate.shared.observe { [weak self] _ in self?.publishSoon() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Coming back to the app is also when a widget tap is applied:
            // the extension queued it while the app may not even have been
            // running.
            self.drainPendingActions()
            self.publishSoon()
        }

        drainPendingActions()
        publishNow()
    }

    func publishSoon() {
        pendingPublish?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publishNow() }
        pendingPublish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// Writes the snapshot and reloads the timelines. Returns whether
    /// anything was written - `false` for "the bytes are unchanged", which is
    /// the common case and not a failure.
    @discardableResult
    func publishNow() -> Bool {
        pendingPublish?.cancel()
        pendingPublish = nil

        let locked = !AppLockGate.shared.allows(.widgetSnapshot)
        let snapshot = Self.snapshot(
            tasks: shiftStore.activeTasks,
            followUps: shiftStore.followUps,
            notes: stickyStore.activeNotes,
            now: clock(),
            availability: locked ? .locked : .ready,
            appearance: ThemeManager.shared.theme.mode == .light ? .light : .dark,
            calendar: calendar
        )
        return write(snapshot)
    }

    @discardableResult
    func write(_ snapshot: GrandLineWidgetSnapshot) -> Bool {
        guard let data = try? GrandLineWidgetSnapshot.makeEncoder().encode(snapshot) else {
            AppLog.store.error("Widgets: could not encode the snapshot - nothing was published.")
            return false
        }
        // `generatedAt` moves on every publish, so comparing whole files
        // would never match. Compare everything else.
        if let previous = lastPublishedBytes,
           let decoded = try? GrandLineWidgetSnapshot.makeDecoder()
            .decode(GrandLineWidgetSnapshot.self, from: previous),
           Self.isEquivalent(decoded, snapshot) {
            return false
        }
        do {
            // GL-10: no silent `try?` on a persistence write. Through
            // `AtomicWrite` because a widget process may be reading this
            // file at any instant - a partial write is a decode failure the
            // captain sees as "Not available".
            try AtomicWrite.data(data, to: snapshotURL)
            lastPublishedBytes = data
            PersistenceFailureReporter.reportSuccess()
        } catch {
            PersistenceFailureReporter.report(
                what: "the widget snapshot", path: snapshotURL.path, error: error
            )
            return false
        }
        reloadTimelines()
        return true
    }

    /// Everything but `generatedAt`. A widget does not redraw because a
    /// second passed.
    static func isEquivalent(_ lhs: GrandLineWidgetSnapshot, _ rhs: GrandLineWidgetSnapshot) -> Bool {
        var left = lhs
        var right = rhs
        left.generatedAt = .distantPast
        right.generatedAt = .distantPast
        return left == right
    }

    // MARK: Building the snapshot - pure

    /// The projection, as a function of its inputs.
    ///
    /// A `.locked` snapshot carries **no** tasks and no notes. That is the
    /// point of publishing one at all: it replaces whatever was on the
    /// desktop, so the lock covers the widgets the way the overlay covers the
    /// window. The counts go too - "3 due today" is a real disclosure about
    /// the captain's day, which is `ShiftMenuBarController`'s own conclusion
    /// for the same reason.
    static func snapshot(
        tasks: [ShiftTask],
        followUps: [ShiftFollowUp],
        notes: [StickyNote],
        now: Date,
        availability: GrandLineWidgetSnapshot.Availability,
        appearance: GrandLineWidgetSnapshot.Appearance = .dark,
        calendar: Calendar = .current
    ) -> GrandLineWidgetSnapshot {
        guard availability == .ready else {
            // A locked snapshot still carries the register, so the locked
            // state is drawn in the captain's own theme rather than jumping
            // to the other one at the moment the lock engages.
            return GrandLineWidgetSnapshot(
                generatedAt: now, availability: .locked, appearance: appearance
            )
        }

        let open = tasks.filter { $0.status != .completed && $0.status != .cancelled }

        // Only dated tasks are carried: an undated task is never a row (see
        // `GrandLineWidgetDigest.taskDigest`), so shipping it would put the
        // captain's task titles in a shared container for nothing.
        let dated = open
            .compactMap { task -> (ShiftTask, Date)? in
                guard let dueAt = dueInstant(for: task, calendar: calendar) else { return nil }
                return (task, dueAt)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.id < rhs.0.id
            }
            .prefix(GrandLineWidgetSnapshot.taskLimit)

        let projectedTasks = dated.map { task, dueAt in
            GrandLineWidgetSnapshot.Task(
                id: task.id,
                title: task.title,
                priority: task.priority.rawValue,
                dueAt: dueAt,
                hasDueTime: (task.dueTime?.isEmpty == false),
                recurrenceSummary: task.recurrence?.displayName
            )
        }

        let projectedNotes = notes
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id < rhs.id
            }
            .prefix(GrandLineWidgetSnapshot.stickyLimit)
            .map { note in
                GrandLineWidgetSnapshot.Sticky(
                    id: note.id,
                    title: UnifiedSearchStickyNoteProvider.displayTitle(for: note),
                    body: String(note.text.prefix(GrandLineWidgetSnapshot.stickyBodyLimit)),
                    paperHex: note.color.paperHex,
                    inkHex: note.color.inkHex,
                    createdAt: note.createdAt,
                    checklistDone: note.checklist.map { items in items.filter { $0.isDone }.count },
                    checklistTotal: note.checklist?.count
                )
            }

        return GrandLineWidgetSnapshot(
            generatedAt: now,
            availability: .ready,
            appearance: appearance,
            tasks: Array(projectedTasks),
            stickies: Array(projectedNotes),
            openTaskCount: open.count,
            pendingFollowUpCount: followUps.filter { $0.status == .pending }.count
        )
    }

    /// A task's due instant in a given calendar.
    ///
    /// Deliberately not `ShiftDateFormatting.dateTime(from:time:)`, which
    /// this app uses everywhere else: that one resolves through
    /// `Calendar.current` with no seam, and every date in this feature is
    /// asserted against a pinned UTC calendar because a widget entry is
    /// rendered at an instant WidgetKit chose rather than now. Same
    /// components, same meaning - the calendar is a parameter.
    static func dueInstant(for task: ShiftTask, calendar: Calendar = .current) -> Date? {
        guard let dueDate = task.dueDate, !dueDate.isEmpty else { return nil }
        let dayParts = dueDate.split(separator: "-").compactMap { Int($0) }
        guard dayParts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = dayParts[0]
        components.month = dayParts[1]
        components.day = dayParts[2]
        if let dueTime = task.dueTime, !dueTime.isEmpty {
            let timeParts = dueTime.split(separator: ":").compactMap { Int($0) }
            if timeParts.count >= 2 {
                components.hour = timeParts[0]
                components.minute = timeParts[1]
            }
        }
        return calendar.date(from: components)
    }

    // MARK: The reverse channel

    /// Applies everything a tapped widget queued, newest last, and deletes
    /// each request once its write has happened.
    ///
    /// Returns the number applied. Runs on the main thread because
    /// `ShiftStore` does.
    @discardableResult
    func drainPendingActions(now: Date? = nil) -> Int {
        let found = GrandLineWidgetAction.pending(directory: actionsDirectory, fileManager: fileManager)

        // GL-01: a request this build cannot decode is deleted deliberately
        // rather than retried on every activation for the rest of time. It
        // is a button press, not captain-authored data - there is nothing to
        // recover and no next write that could overwrite something real.
        for url in found.unreadable {
            AppLog.store.error("Widgets: discarding an unreadable queued widget action at \(url.path, privacy: .public).")
            try? fileManager.removeItem(at: url)
        }

        guard !found.requests.isEmpty else { return 0 }

        // GL-09: a widget button is reachable while the app is locked - it is
        // on the desktop, outside every overlay this app can draw. A queued
        // request is *kept* rather than dropped, so a tick the captain made
        // before locking still lands when they come back.
        guard AppLockGate.shared.allows(.widgetSnapshot) else {
            AppLog.store.info("""
                Widgets: \(found.requests.count, privacy: .public) queued action(s) held - \
                the app is locked (GL-09). They will apply after unlock.
                """)
            return 0
        }

        let applyAt = now ?? clock()
        var applied = 0
        for entry in found.requests {
            switch entry.request.kind {
            case .completeTask:
                // Through the same call the Tasks page's own checkbox uses,
                // so a ticked recurring task advances its series and the
                // activity log records it exactly as it would in-app. A task
                // that is already gone (completed in the app, then the
                // widget's stale button tapped) is a no-op inside the store,
                // which is the right answer - not an error.
                shiftStore.setTaskCompleted(id: entry.request.taskID, completed: true, now: applyAt)
            }
            try? fileManager.removeItem(at: entry.url)
            applied += 1
        }
        if applied > 0 { publishNow() }
        return applied
    }
}
