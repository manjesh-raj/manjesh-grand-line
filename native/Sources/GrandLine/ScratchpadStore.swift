// Grand Line - native macOS app.
//
// Where a Scratchpad tab's text lives between launches (F9 of full review #3
// §8). One JSON file under Application Support, the same shape `SnippetStore`
// and `SessionRestoreStore` already have: GL-01's back-up-before-overwrite
// load, GL-10's reported write, an `FM_*` override, and `sensitive: true`.
//
// ## Why this one persists at all, when no other Tools tab does
//
// `ToolsController.restorableToolTabs` says it deliberately: a tool tab is a
// scratch surface, and writing whatever was pasted into a JWT decoder to disk
// would be recording the captain's material for a feature that only promised
// to reopen the tab.
//
// A scratchpad is the exception, and the difference is in the word. The report
// scoped F9 as "a pad you come back to", and a pad that forgot its contents
// every launch would be a calculator - which macOS already ships. So this one
// keeps its text, and the cost is taken seriously rather than waved at: the
// file is 0600 in a 0700 directory through `AtomicWrite(... sensitive:)`,
// exactly like `snippets.json`, because a pad's lines carry seat counts,
// prices and sometimes a hostname.
//
// ## Keyed by tab name
//
// Tools tabs are multi-instance ("Scratchpad", "Scratchpad 2"), and session
// restore reopens them **by name**. So the pads are a name -> text map: two
// open pads keep two documents, a relaunch puts each one back where it was,
// and a rename carries its text with it (`ToolInstance.padWasRenamed`).
//
// The map is pruned on write to `maximumPads` entries, most recently edited
// first (GL-35: nothing unbounded) - a captain who has named thirty pads over
// a year does not want the oldest twenty-odd resurrected as empty tabs, and
// the file should not grow forever.

import Foundation

/// One pad's saved text.
struct ScratchpadDocument: Codable, Equatable {
    var text: String
    var updatedAt: Date

    /// GL-01: a hand-written decoder with `decodeIfPresent` and a default for
    /// every field, so a file written by a build that did not have one of them
    /// still decodes. A Swift-side default does **not** make a declared key
    /// optional to the synthesised decoder, and getting that wrong made every
    /// existing `hosts.json` undecodable once.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    init(text: String, updatedAt: Date = Date()) {
        self.text = text
        self.updatedAt = updatedAt
    }
}

final class ScratchpadStore {

    /// GL-35: nothing unbounded. Thirty pads is well past any real use and
    /// still a file measured in kilobytes.
    static let maximumPads = 30

    private(set) var pads: [String: ScratchpadDocument] = [:]

    /// Set when `load()` backed up an undecodable file (GL-01).
    private(set) var loadFailureBackupPath: String?

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? ScratchpadStore.storeURL()
        load()
    }

    /// `~/Library/Application Support/GrandLine/scratchpad.json`,
    /// overridable via `FM_SCRATCHPAD_FILE` - the same shape
    /// `FM_SNIPPETS_FILE` uses, and the reason a self-test can exercise this
    /// without touching the captain's own pads.
    static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_SCRATCHPAD_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return AppPaths.dataRoot()
            .appendingPathComponent("scratchpad.json")
    }

    // MARK: Reading and writing

    func text(for name: String) -> String { pads[name]?.text ?? "" }

    /// Save one pad. An empty pad is **removed** rather than stored as an
    /// empty string, so clearing a pad and closing its tab leaves nothing
    /// behind.
    func save(_ text: String, for name: String, at date: Date = Date()) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard pads.removeValue(forKey: name) != nil else { return }
        } else {
            let existing = pads[name]
            guard existing?.text != text else { return }
            pads[name] = ScratchpadDocument(text: text, updatedAt: date)
        }
        persist()
    }

    /// Carry a pad's text to the tab's new name. A rename is the captain
    /// labelling the same pad, not starting a new one.
    func rename(from old: String, to new: String) {
        guard old != new, let document = pads.removeValue(forKey: old) else { return }
        pads[new] = document
        persist()
    }

    // MARK: Disk

    private func load() {
        var backup: String?
        pads = StoreLoadFailure.decodeJSON(
            [String: ScratchpadDocument].self, at: fileURL, label: "scratchpad.json", didBackUp: &backup
        ) ?? [:]
        loadFailureBackupPath = backup
    }

    private func persist() {
        prune()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(pads)
            // 0600/0700, for the reason this file's header gives.
            try AtomicWrite.data(data, to: fileURL, sensitive: true)
        } catch {
            // GL-10: reported, never a silent `try?`.
            PersistenceFailureReporter.report(what: "the scratchpad", path: fileURL.path, error: error)
        }
    }

    private func prune() {
        guard pads.count > Self.maximumPads else { return }
        let keep = pads.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(Self.maximumPads)
        pads = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })  // unique-keys-ok: a slice of an existing dictionary
    }
}
