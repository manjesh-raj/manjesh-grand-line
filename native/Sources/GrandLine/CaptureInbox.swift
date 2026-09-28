// Grand Line - native macOS app.
//
// **UX issue X6 of the 2026-09-27 review**: "Capture in, triage out".
//
// > ⌥Space capture is excellent and reaches tasks, follow-ups, stickies,
// > reading list and notebook. What is missing is the other half: an Inbox
// > view where everything captured today sits until it is filed. Today
// > captured items scatter into five destinations and the daily review only
// > counts what is due.
//
// The capture router already decides *where* a line goes, and it is good at
// it - nothing here changes any of that. What was missing is that once a
// line has gone, there is no surface that remembers it went anywhere. Six
// captures in a morning are six rows in six different pages, and the only
// way to see the morning's work is to remember which pages to open.
//
// ## What this is, and what it deliberately is not
//
// It is a **log**, not a second inbox store. A captured task is a task; it
// lives in `ShiftStore` and nowhere else. This file records one small row
// per capture - when, where it went, and what it was called - so a single
// list can say "here is what you captured today, and here is where each one
// went". Following a row opens the destination it landed in.
//
// Making it a real staging area (capture goes *here* first, and is filed
// later) was the other shape available, and it is the wrong one for this
// app: the router's whole point is that ⌥Space files immediately, and a
// staging step would put work back in front of the captain between typing
// and filing.
//
// ## The rules this store owes
//
// - **GL-01.** A new field needs `decodeIfPresent` and a default, and a
//   failed read is never an empty log - `loadFailed` is a state the card
//   renders differently from "nothing captured today".
// - **GL-10.** No silent `try?` on the write. `AtomicWrite` plus
//   `PersistenceFailureReporter`.
// - **GL-35.** Capped. A log nobody prunes is a file that grows forever;
//   `maxEntries` is a few weeks of heavy use and the oldest fall off.
// - **GL-23.** One shared instance, because it caches.

import Foundation

/// One captured line, after it was filed.
struct CaptureInboxEntry: Codable, Equatable, Identifiable {
    let id: String
    /// When it was captured. The card groups on the captain's own calendar
    /// day, never UTC - "today" means today where they are.
    let at: Date
    /// Where it went, as `CaptureDestination.rawValue`. Stored as the raw
    /// string rather than the enum so a destination removed in a later build
    /// leaves a readable row instead of making the whole file undecodable
    /// (GL-01's usual shape).
    let destination: String
    /// What the row should say - the draft's own title, which is the first
    /// line of what was typed.
    let title: String

    init(id: String = UUID().uuidString, at: Date, destination: CaptureDestination, title: String) {
        self.id = id
        self.at = at
        self.destination = destination.rawValue
        self.title = title
    }

    /// GL-01: hand-written, so a field added later is optional to the
    /// decoder and an existing file stays readable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    }

    /// The destination this landed in, or `nil` for a row written by a build
    /// that had a destination this one does not.
    var captureDestination: CaptureDestination? { CaptureDestination(rawValue: destination) }
}

final class CaptureInboxStore {

    /// GL-23: one instance, because this one caches.
    static let shared = CaptureInboxStore()

    /// GL-35. About three weeks of heavy use; the oldest fall off the end.
    static let maxEntries = 300

    /// This store's own narrow override, over `AppPaths.dataRoot()`'s
    /// `FM_SCRATCH_ROOT` - the convention every file-backed store here
    /// follows.
    static let fileVariable = "FM_CAPTURE_INBOX_FILE"

    private let url: URL
    private var entries: [CaptureInboxEntry] = []

    /// GL-14/GL-01: "the file would not parse" is not "nothing has been
    /// captured", and the card says so rather than drawing an empty day.
    private(set) var loadFailed = false

    private var observers: [(UUID, () -> Void)] = []

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment[Self.fileVariable], !override.isEmpty {
            url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            url = AppPaths.dataRoot(environment: environment)
                .appendingPathComponent("capture-inbox.json")
        }
        load()
    }

    // MARK: Reading

    /// Everything captured on `day`, newest first.
    ///
    /// Stable on a tie, and that matters more than it looks: two captures a
    /// few hundred milliseconds apart can carry the same second, and Swift's
    /// `sorted` is not a stable sort - so ordering on `at` alone would let
    /// two rows swap places between one render and the next for no reason
    /// the captain could see. The tie-break is insertion order reversed,
    /// which is the honest "later" when the clock cannot say.
    func entries(on day: Date, calendar: Calendar = .current) -> [CaptureInboxEntry] {
        entries.enumerated()
            .filter { calendar.isDate($0.element.at, inSameDayAs: day) }
            .sorted { left, right in
                if left.element.at != right.element.at { return left.element.at > right.element.at }
                return left.offset > right.offset
            }
            .map(\.element)
    }

    var allEntries: [CaptureInboxEntry] { entries }

    // MARK: Writing

    /// Records one filed capture. Called from the app shell's one
    /// `CaptureFiler`, which every entry point (⌥Space's panel, the compact
    /// popover) goes through - so there is one place a capture is logged,
    /// and it is the same place a capture is filed.
    func record(destination: CaptureDestination, title: String, at: Date = Date()) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(CaptureInboxEntry(at: at, destination: destination, title: trimmed))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        persist()
        notify()
    }

    /// Forgets one row. The list is a record of what happened, so a row is
    /// only ever removed by the captain saying "I have dealt with that" -
    /// nothing here deletes the thing it points at.
    func forget(id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        persist()
        notify()
    }

    // MARK: Observation

    @discardableResult
    func observe(_ block: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers.append((token, block))
        return token
    }

    func unobserve(_ token: UUID) { observers.removeAll { $0.0 == token } }

    private func notify() {
        for (_, block) in observers { block() }
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else {
            // GL-01: "present but unreadable" is its own state.
            loadFailed = true
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = try decoder.decode([CaptureInboxEntry].self, from: data)
            loadFailed = false
        } catch {
            loadFailed = true
            AppLog.store.error("capture inbox failed to decode: \(String(describing: error))")
        }
    }

    private func persist() {
        // GL-01: never overwrite a file this process could not read. A
        // capture log is not worth losing somebody's history over.
        guard !loadFailed else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try AtomicWrite.data(try encoder.encode(entries), to: url)
            PersistenceFailureReporter.reportSuccess()
        } catch {
            PersistenceFailureReporter.report(what: "the capture log", path: url.path, error: error)
        }
    }
}
