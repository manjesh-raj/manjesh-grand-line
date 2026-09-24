// Grand Line - native macOS app.
//
// `StrawHatTranscriptStore` - the crew's conversations, kept across a quit.
//
// Review #3's UX12: "Straw Hat is the best-executed new surface, and its
// history is lost on quit […] a conversation lives as long as the app, there
// is no `FM_STRAW_HAT_DIR`, and the menu-bar popover can't scroll back."
//
// **This is the persistence half of M1.4 only.** The finding also asks to
// "list past conversations in the roster sheet"; that browsing UI is a named
// follow-up rather than something rushed in beside fourteen other items - see
// this batch's PR description. What is here is the half that cannot be added
// retroactively: once a conversation is gone at quit, no later UI can show it.
//
// # What is written, and what is deliberately not
//
// Each conversation is one JSON file under `conversations/`, named by its
// start time so a directory listing is chronological with no index to keep in
// step (the same reasoning `LogAnalyzerStore` gives for its own year/slug
// layout).
//
// **Every string is redacted on the way in, through `LogRedactor` - the same
// redactor the Log Analyzer uses**, which is what the finding means by
// "redacted, under the Log Analyzer roof". That is not belt-and-braces: a
// captain asks the crew about a failing deploy by pasting the output, and that
// output carries tokens, keys and connection strings. Before this, those lived
// in memory for a session; a file is forever and syncs, so the redaction has
// to happen at the boundary rather than at read time.
//
// Only the captain's words and the crew's prose are stored. Proposals,
// confirm-cards and their armed/confirmed state are **not**: a proposal is a
// live offer to run something, and a restored transcript that re-armed one
// would be offering to execute a command out of the context that produced it.
// A restored conversation is something to read, which is exactly what the
// finding asks for.
//
// # Where it goes
//
// `FM_STRAW_HAT_DIR`, falling back to `FM_SHIFT_DIR`, falling back to the
// git-synced data root - the store convention AGENTS.md states, and the
// variable the finding names by name. The `FM_SHIFT_DIR` fallback is not
// optional politeness: it is what stops a self-test that only sets the broad
// override from writing into the captain's real synced clone.

import Foundation

/// One stored turn.
struct StrawHatTranscriptMessage: Codable, Equatable {
    enum Speaker: String, Codable {
        case captain
        case crew
    }

    var speaker: Speaker
    /// The crew member who said it, for a `.crew` turn. `nil` for the
    /// captain, and for a rung-2 section that genuinely has no speaker - see
    /// `StrawHatMessage.crew`'s own note.
    var member: String?
    var text: String
    var at: Date

    init(speaker: Speaker, member: String? = nil, text: String, at: Date) {
        self.speaker = speaker
        self.member = member
        self.text = text
        self.at = at
    }

    // GL-01: every field decoded with a default, so a file written by a build
    // with a different shape loads rather than making the whole conversation
    // undecodable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speaker = try container.decodeIfPresent(Speaker.self, forKey: .speaker) ?? .crew
        member = try container.decodeIfPresent(String.self, forKey: .member)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        at = try container.decodeIfPresent(Date.self, forKey: .at) ?? Date()
    }
}

/// One stored conversation.
struct StrawHatTranscript: Codable, Equatable, Identifiable {
    var id: String
    var startedAt: Date
    var messages: [StrawHatTranscriptMessage]
    /// How many secrets `LogRedactor` masked on the way in, across the whole
    /// conversation.
    ///
    /// Recorded rather than discarded so the fact is *reportable*: a captain
    /// who wants to know whether a stored conversation ever contained
    /// credentials can be told, without the file having to contain them.
    var redactionCount: Int

    init(id: String = UUID().uuidString,
         startedAt: Date = Date(),
         messages: [StrawHatTranscriptMessage] = [],
         redactionCount: Int = 0) {
        self.id = id
        self.startedAt = startedAt
        self.messages = messages
        self.redactionCount = redactionCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        messages = try container.decodeIfPresent([StrawHatTranscriptMessage].self, forKey: .messages) ?? []
        redactionCount = try container.decodeIfPresent(Int.self, forKey: .redactionCount) ?? 0
    }

    /// The first thing the captain said, for a listing row. `nil` for a
    /// conversation that never got one, which the roster follow-up will render
    /// as a placeholder rather than a blank row.
    var title: String? {
        messages.first { $0.speaker == .captain }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether this is worth keeping: a conversation with nothing from the
    /// captain and nothing from the crew is a page that was opened and left.
    var hasRealExchange: Bool { !messages.isEmpty }
}

final class StrawHatTranscriptStore {
    let root: URL
    private let fm = FileManager.default

    /// How many conversations are kept. GL-35: nothing unbounded.
    ///
    /// Trimmed oldest-first, matching `VaultAuditEvent`'s own cap and for the
    /// same reason that one gives: capping the newest instead would leave the
    /// history permanently stale rather than merely bounded.
    static let maximumConversations = 200

    private var conversationsDir: URL { root.appendingPathComponent("conversations", isDirectory: true) }

    /// The `root:` seam every store in this app offers, so a suite stays off
    /// the captain's real clone without setting a process-wide environment
    /// variable.
    init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
    }

    convenience init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_STRAW_HAT_DIR"], !override.isEmpty {
            self.init(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            self.init(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        } else {
            let sync = ShiftGitSync.shared
            sync.start()
            self.init(root: sync.dataRoot)
        }
    }

    // MARK: Writing

    /// Write (or rewrite) one conversation.
    ///
    /// A conversation is saved under its own id, so appending a turn rewrites
    /// one small file rather than a whole history - and a crash between turns
    /// costs at most the turn in flight.
    ///
    /// GL-10: no silent `try?` on a persistence write. A failure is reported
    /// through `PersistenceFailureReporter`, which is the one place this app
    /// tells the captain a write did not land.
    func save(_ transcript: StrawHatTranscript) {
        guard transcript.hasRealExchange else { return }
        let url = fileURL(for: transcript)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(transcript)
            // `sensitive:` - the text is redacted, but a conversation with
            // the crew is still the captain's own words about their own
            // systems, and GL-30 routes anything carrying connection or
            // credential material through the 0600 path.
            try AtomicWrite.data(data, to: url, sensitive: true)
            trimIfNeeded()
        } catch {
            PersistenceFailureReporter.report(what: "a Straw Hat conversation", path: url.path, error: error)
        }
    }

    /// Redact a captain or crew turn and append it to `transcript`.
    ///
    /// The redaction happens **here**, at the boundary, rather than at read
    /// time - see this file's header. Returns the updated transcript rather
    /// than mutating in place so a caller cannot half-apply a turn and then
    /// fail to save it.
    static func appending(_ text: String,
                          speaker: StrawHatTranscriptMessage.Speaker,
                          member: String? = nil,
                          to transcript: StrawHatTranscript,
                          at date: Date = Date()) -> StrawHatTranscript {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }
        let redacted = LogRedactor.redact(trimmed)
        var updated = transcript
        updated.messages.append(StrawHatTranscriptMessage(
            speaker: speaker, member: member, text: redacted.text, at: date))
        updated.redactionCount += redacted.count
        return updated
    }

    // MARK: Reading

    /// Every stored conversation, newest first.
    ///
    /// GL-21: "the directory could not be enumerated" is not "the directory is
    /// empty". An enumeration failure returns `nil` so a caller can say so,
    /// rather than an empty array that reads as "you have no history" and
    /// would invite a seeder to overwrite real data.
    func list() -> [StrawHatTranscript]? {
        guard let files = try? fm.contentsOfDirectory(at: conversationsDir,
                                                      includingPropertiesForKeys: nil) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StrawHatTranscript? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(StrawHatTranscript.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Drop the oldest conversations past the cap.
    private func trimIfNeeded() {
        guard let all = list(), all.count > Self.maximumConversations else { return }
        for transcript in all.dropFirst(Self.maximumConversations) {
            try? fm.removeItem(at: fileURL(for: transcript))
        }
    }

    private func fileURL(for transcript: StrawHatTranscript) -> URL {
        // The start time leads the name so a directory listing is
        // chronological on its own, and the id follows so two conversations
        // started in the same second cannot collide.
        let stamp = Self.stampFormatter.string(from: transcript.startedAt)
        return conversationsDir.appendingPathComponent("\(stamp)-\(transcript.id).json")
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
