// Grand Line - native macOS app.
//
// R4-PERF-01 of the fourth full review: tell `FleetNotifier` the moment a
// crew's own state files change, so a transition a crew writes down is seen
// in about a second, and the 30-second tick is left as the watchdog for the
// transitions nobody writes down.
//
// **FSEvents with file events, not a `DispatchSource` on the folder.** The
// review suggested either. Measured with both on one folder: a `>>` append to
// a file inside it - which is how a crew records every transition in
// `state/<id>.status` - raised **no** event on a vnode source watching the
// folder, because a folder's vnode only changes when an entry is added,
// removed or renamed. FSEvents with `kFSEventStreamCreateFlagFileEvents`
// reported the append by path. A folder source would have caught a new task
// and a `.busy-state` replace, and slept through the one signal the notifier
// exists for.
//
// **The folder is busy, so the filter matters more than the stream.** The
// captain's `state/` holds about 3,600 entries, 3,500 of them dot-files
// firstmate's own watcher churns (locks, seen-markers, hashes): its
// modification time moved five times in a 30-second sample with no crew doing
// anything. So a callback is only relevant when it names a task's file - an
// entry `<id>.<anything>` for a task the last sweep saw, or any new `.meta` -
// and everything else is dropped on the stream's own queue without waking the
// main thread. A stream that dropped events (`MustScanSubDirs`) or lost its
// root counts as relevant, because the honest reading of "something may have
// changed" is a sweep.
//
// What a relevant change asks for is `FleetDataSource.parseTasksAfterStateChange`,
// which re-reads only the tasks whose files changed (`FleetTaskCache`'s header
// has the reuse rules). The notifier owns the debounce.

import CoreServices
import Foundation

final class FleetStateWatcher {

    /// How long FSEvents gathers events before it delivers them. A crew's
    /// transition is a burst of writes (the status line, then the busy record,
    /// then an inbox move), and one delivery for the burst is what is wanted.
    static let latency: CFTimeInterval = 1.0

    private let stateDirectory: String
    private let queue = DispatchQueue(label: "fm.fleet.stateWatcher", qos: .utility)
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    private let lock = NSLock()
    private var knownTaskIDs: Set<String> = []

    /// `onChange` runs on the main thread, once per delivery that named a
    /// task's file.
    init(stateDirectory: URL, onChange: @escaping () -> Void) {
        // FSEvents reports real paths (`/private/var/...`), so the prefix the
        // filter compares against has to be the real path too.
        self.stateDirectory = CodeSandbox.realPath(stateDirectory.path)
        self.onChange = onChange
    }

    deinit { stop() }

    /// Starts the stream. `false` when FSEvents refused it - a missing folder,
    /// say - and the notifier's tick then carries the fleet alone, as it
    /// always did.
    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FleetStateWatcher>.fromOpaque(info).takeUnretainedValue()
            let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let flagList = (0..<count).map { flags[$0] }
            watcher.deliver(paths: names, flags: flagList)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [stateDirectory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags) else {
            AppLog.store.error("fleet state watcher: FSEvents refused \(self.stateDirectory, privacy: .public)")
            return false
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            AppLog.store.error("fleet state watcher: could not start on \(self.stateDirectory, privacy: .public)")
            return false
        }
        stream = created
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// The task ids the last sweep saw, so a change to their files is
    /// recognised. Called after every sweep, from any thread.
    func setKnownTaskIDs(_ ids: Set<String>) {
        lock.lock()
        knownTaskIDs = ids
        lock.unlock()
    }

    private func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
        lock.lock()
        let known = knownTaskIDs
        lock.unlock()
        guard Self.isRelevant(paths: paths, flags: flags, stateDirectory: stateDirectory, knownTaskIDs: known) else {
            return
        }
        DispatchQueue.main.async { [onChange] in onChange() }
    }

    /// Whether one delivery names a task's file. Pure, so a suite can drive
    /// it with the paths and flags FSEvents would hand over.
    static func isRelevant(paths: [String], flags: [FSEventStreamEventFlags],
                           stateDirectory: String, knownTaskIDs: Set<String>) -> Bool {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        if flags.contains(where: { $0 & rescan != 0 }) { return true }
        let prefix = stateDirectory.hasSuffix("/") ? stateDirectory : stateDirectory + "/"
        for path in paths where path.hasPrefix(prefix) {
            // The entry directly under `state/` the event is about: the file
            // itself, or the task folder (`<id>.inbox`) it sits in.
            guard let entry = path.dropFirst(prefix.count).split(separator: "/").first.map(String.init),
                  !entry.hasPrefix(".") else { continue }
            if entry.hasSuffix(".meta") { return true }
            for dot in entry.indices where entry[dot] == "." && knownTaskIDs.contains(String(entry[..<dot])) {
                return true
            }
        }
        return false
    }
}
