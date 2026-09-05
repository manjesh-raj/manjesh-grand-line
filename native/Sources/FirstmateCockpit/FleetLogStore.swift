// Manjesh Grand Line - native macOS app.
//
// F6's event sink: an append-only local JSONL log (the spec's own words), one
// JSON object per line, behind Overview's "Log" tab.
//
// **Why JSONL rather than one JSON array.** The normal operation here is
// "append one event and never touch the rest", which a top-level array cannot
// do without rewriting the whole file - and a rewrite is exactly the shape
// that loses history when it is interrupted. One line per event means the
// steady-state write is an `O(1)` seek-to-end, and a line that somehow ends up
// malformed costs that one event rather than the entire log (`load` skips it
// and keeps going; see `decodeLines`).
//
// **Retention (the spec's required cap).** The file holds at most
// `maxEvents + trimSlack` lines and is trimmed back to the newest `maxEvents`
// when it crosses that. The slack matters: trimming exactly at the cap would
// turn every append past it into a full rewrite forever, which is the cost
// JSONL was chosen to avoid. At the app's real event rate (a merge, a resolved
// conflict, a saved investigation) 2000 events is years of history and a file
// well under a megabyte. Shift's task half is deliberately NOT stored here at
// all - see `FleetLogFeed` - so this cap never truncates task history that
// Shift's own activity YAML already keeps.
//
// Not thread-confined: `append` is reached from the main thread (a merge) and
// from `ShiftGitSync`'s own serial queue (a resolved conflict), so the cache
// and the file are both guarded by one lock.

import Foundation

final class FleetLogStore {

    /// The app-wide sink. `ReviewController`, `ShiftGitSync` and
    /// `LogAnalyzerStore` append through this rather than being handed an
    /// instance - none of them is constructed anywhere that could inject one,
    /// and the alternative (threading a store through three unrelated call
    /// chains) buys nothing a self-test cannot get from `init(directory:)`.
    static let shared = FleetLogStore(directory: FleetLogStore.defaultDirectory())

    /// See this file's header. Public so the self-test can assert the real
    /// numbers rather than its own copy of them.
    static let maxEvents = 2000
    static let trimSlack = 200

    private let fileURL: URL
    private let lock = NSLock()
    /// Loaded lazily on first read/append, oldest-first (file order).
    private var cache: [Line]?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("events.jsonl")
    }

    /// `~/Library/Application Support/FirstmateCockpit/fleet-log/`, overridable
    /// via `FM_FLEET_LOG_DIR` - the same `FM_*_DIR` convention
    /// `DictationStore`/`CommandLibraryStore` already established, so a test
    /// run never appends to the captain's real history.
    ///
    /// Its own directory, deliberately not a file inside `ShiftGitSync`'s
    /// `personal-tasks/` subtree: this is a machine-local audit trail of what
    /// happened *on this machine*, and syncing it would both merge two
    /// machines' histories into one confusing feed and push a record of the
    /// captain's activity to GitHub that nothing asked for.
    static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_FLEET_LOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("fleet-log", isDirectory: true)
    }

    // MARK: Reading

    /// Newest first - the order the feed renders in, so no caller has to
    /// remember to sort.
    func events() -> [FleetLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return loadedLocked().compactMap { if case .event(let e) = $0 { return e } else { return nil } }.reversed()
    }

    // MARK: Appending

    /// Appends one event. Called synchronously by the code path that caused
    /// it; never batched, never scheduled.
    func append(_ event: FleetLogEvent) {
        lock.lock()
        defer { lock.unlock() }
        var lines = loadedLocked()
        lines.append(.event(event))

        // The cap counts *events*, and the trim drops only events - an opaque
        // line is data this build cannot read, so it is also data this build
        // must not decide is expendable (finding 4.5). The bound that matters
        // is still real: every line this app writes is an event, so the
        // opaque set can only ever be as large as whatever a schema change or
        // an outside edit left behind, and it stops growing the moment the
        // log is readable again.
        let eventCount = lines.reduce(into: 0) { n, line in if case .event = line { n += 1 } }
        if eventCount >= Self.maxEvents + Self.trimSlack {
            var toDrop = eventCount - Self.maxEvents
            var kept: [Line] = []
            kept.reserveCapacity(lines.count)
            for line in lines {
                if toDrop > 0, case .event = line { toDrop -= 1; continue }
                kept.append(line)
            }
            cache = kept
            rewriteLocked(kept)
            return
        }

        cache = lines
        appendLineLocked(event)
    }

    // MARK: Disk

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // One line per event: pretty-printing would break the format outright.
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// One line of the file: either an event this build understands, or the
    /// raw text of one it does not.
    ///
    /// **The `.opaque` case is the whole of finding 4.5's fix.** The trim path
    /// rewrites the file, and it used to rewrite it from *decoded* events - so
    /// every line `decodeLines` had skipped (an old line a future schema
    /// change made unreadable, a line a hand edit corrupted) was silently
    /// deleted the next time the log crossed its cap, potentially months of
    /// history at once. That directly contradicted this file's own stated
    /// contract, three paragraphs up: "one bad line can only ever cost
    /// itself". Carrying the raw text through the rewrite is what makes that
    /// sentence true, and is what lets a later build that *can* read those
    /// lines still find them.
    enum Line {
        case event(FleetLogEvent)
        case opaque(String)
    }

    private func loadedLocked() -> [Line] {
        if let cache { return cache }
        let loaded = readFromDisk()
        cache = loaded
        return loaded
    }

    private func readFromDisk() -> [Line] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Self.parseLines(text)
    }

    /// Every line, in file order, decoded where possible and preserved
    /// verbatim where not.
    static func parseLines(_ text: String) -> [Line] {
        var out: [Line] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let event = try? decoder.decode(FleetLogEvent.self, from: Data(trimmed.utf8)) {
                out.append(.event(event))
            } else {
                out.append(.opaque(trimmed))
            }
        }
        return out
    }

    /// Skips a line that will not decode rather than failing the whole read -
    /// see this file's header. Deliberately different from the JSON stores'
    /// `StoreLoadFailure` treatment (GL-01), which backs a file up because an
    /// unreadable `hosts.json` means real, irreplaceable data is about to be
    /// overwritten wholesale. Here the very next write is an append that
    /// touches no existing line, so one bad line can only ever cost itself.
    static func decodeLines(_ text: String) -> [FleetLogEvent] {
        parseLines(text).compactMap { if case .event(let e) = $0 { return e } else { return nil } }
    }

    private func line(for event: FleetLogEvent) -> Data? {
        guard var data = try? Self.encoder.encode(event) else { return nil }
        data.append(0x0A)
        return data
    }

    private func appendLineLocked(_ event: FleetLogEvent) {
        guard let data = line(for: event) else { return }
        do {
            let fm = FileManager.default
            let dir = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: fileURL.path) {
                try AtomicWrite.data(data, to: fileURL)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            PersistenceFailureReporter.report(what: "fleet log event", path: fileURL.path, error: error)
        }
    }

    private func rewriteLocked(_ lines: [Line]) {
        var out = Data()
        for line in lines {
            switch line {
            case .event(let event):
                guard let data = self.line(for: event) else { continue }
                out.append(data)
            case .opaque(let raw):
                // Verbatim, byte for byte - the point is that this build does
                // not understand it and therefore must not reshape it.
                out.append(Data(raw.utf8))
                out.append(0x0A)
            }
        }
        do {
            try AtomicWrite.data(out, to: fileURL)
        } catch {
            PersistenceFailureReporter.report(what: "fleet log (trim)", path: fileURL.path, error: error)
        }
    }

    // MARK: Probe / self-test surface

    /// The raw file, for a test that needs to assert the on-disk shape (one
    /// JSON object per line) rather than what `events()` hands back.
    var debugFileURL: URL { fileURL }

    /// Drops the in-memory cache so the next read comes from disk - lets a
    /// test prove the file, not the cache, is what carries the history.
    func debugForgetCache() {
        lock.lock()
        cache = nil
        lock.unlock()
    }
}
