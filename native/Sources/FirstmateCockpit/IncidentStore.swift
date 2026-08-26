// Manjesh Grand Line - native macOS app.
//
// F8's storage: one directory per incident, YAML metadata plus artifact
// files. Modelled on `LogAnalyzerStore` deliberately and closely - same
// vendored-`Yaml` dump/load bridge (`ShiftYamlBridge`), same year/slug
// directory layout, same root resolution, same `gitSync?.markDirty()` after
// every write. An incident record is host-specific investigation data whose
// whole job is to reference Log Analyzer investigations, so putting it
// anywhere else would mean the record and the evidence it points at could end
// up on different machines.
//
// **The one behavioural difference from `LogAnalyzerStore`, and it is the
// point of this feature.** An investigation is written by one explicit
// "save it" decision at the end. An incident is written *as it happens*:
// `start`, every `append`, `end` and `setRCA` each hit the disk before
// returning. That is the narrow slice of durability F8 actually needs (see
// the F2 note below) - a crash mid-incident costs at most the artifact of the
// entry currently being written, never the incident.
//
// **What F8 does NOT get without F2 (session restoration), stated here so
// nobody assumes otherwise.** These records are durable, but the app has no
// general session restore: after a relaunch, the "Active incident" state is
// not automatically re-attached to the host page it was running on. The
// incident is still active, still on disk, and still shown the moment that
// host page is opened again (`activeIncident(hostID:)` is consulted on every
// connect) - but the app will not reopen that page for the captain. Closing
// that gap is F2's job, not this one's.
//
// Layout:
//
//   <root>/incidents/<YYYY>/<INC-014-slug>/
//       incident.yaml
//       artifacts/<entry-id>.md   (SRE Lead transcript snapshots)
//       rca.md                    (only once End Incident generated one)
//
// **Nothing written here is unredacted.** `incident.yaml` holds ids, titles,
// counts and one-line summaries only (`IncidentTimelineEntry` enforces the
// one-line rule). The single kind of free text this store writes at all - an
// SRE Lead transcript snapshot - goes through `LogRedactor.redact` on the way
// in, so even though that transcript is model prose rather than a raw
// terminal buffer, a credential quoted inside it never reaches disk.
// `IncidentStoreSelfTest` proves that by grepping the real bytes of a real
// saved incident, not by reasoning about it.

import Foundation
import Yaml

final class IncidentStore {

    let root: URL
    /// `nil` when an env override bypasses git sync - same convention as
    /// `ShiftStore.gitSync` / `LogAnalyzerStore.gitSync`.
    let gitSync: ShiftGitSync?

    private let fm = FileManager.default

    private var incidentsDir: URL { root.appendingPathComponent("incidents", isDirectory: true) }

    /// Root resolution mirrors `LogAnalyzerStore`'s exactly, **including
    /// honouring `FM_SHIFT_DIR`**: a store living inside `ShiftGitSync`'s
    /// `personal-tasks/` subtree that ignores it would let a self-test which
    /// sets only `FM_SHIFT_DIR` (the established way to keep away from the
    /// captain's real synced clone) still write into production. That was a
    /// real bug in `CommandLibraryStore` once; see AGENTS.md.
    init() {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_INCIDENTS_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else if let override = env["FM_SHIFT_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            gitSync = nil
        } else {
            let sync = ShiftGitSync.shared
            sync.start()
            root = sync.dataRoot
            gitSync = sync
        }
        try? fm.createDirectory(at: incidentsDir, withIntermediateDirectories: true)
    }

    /// Test seam: an explicitly-rooted, git-free store, so a suite never has
    /// to depend on process-wide environment to stay off the real clone.
    init(root: URL) {
        self.root = root
        self.gitSync = nil
        try? fm.createDirectory(at: incidentsDir, withIntermediateDirectories: true)
    }

    // MARK: Reading

    /// Memoised for the same reason `LogAnalyzerStore.history()` is: the card
    /// asks for the active incident on every render, and each miss walks and
    /// YAML-parses one folder per incident ever recorded.
    private var cache: [Incident]?

    func invalidateCache() { cache = nil }

    /// Every incident, newest first.
    func all() -> [Incident] {
        if let cache { return cache }
        let loaded = scan()
        cache = loaded
        return loaded
    }

    func load(id: String) -> Incident? {
        all().first { $0.id == id }
    }

    /// The one active incident for a host, if any - the whole basis of the
    /// "only one active incident per host at a time" rule.
    ///
    /// Should a record ever end up with two actives for one host (a hand-
    /// edited file; two machines' clones merged), the newest wins rather than
    /// this returning an arbitrary one or refusing to work at all.
    func activeIncident(hostID: String) -> Incident? {
        all().first { $0.hostID == hostID && $0.status == .active }
    }

    /// Newest first, so the caller can show a history list without sorting.
    func incidents(hostID: String) -> [Incident] {
        all().filter { $0.hostID == hostID }
    }

    // MARK: Writing

    enum StartFailure: Error, Equatable {
        /// This host already has an active incident - the record refuses
        /// rather than letting two overlapping incidents exist, so the rule
        /// holds even if a UI path ever forgets to check first.
        case alreadyActive(existingID: String)
        case couldNotWrite(String)
    }

    /// Creates and immediately persists a new active incident.
    @discardableResult
    func start(title: String, hostID: String, hostLabel: String,
               now: Date = Date()) -> Result<Incident, StartFailure> {
        if let existing = activeIncident(hostID: hostID) {
            return .failure(.alreadyActive(existingID: existing.id))
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let incident = Incident(id: nextIncidentID(),
                                title: IncidentTimelineEntry.sanitize(trimmed.isEmpty ? "Untitled incident" : trimmed),
                                hostID: hostID,
                                hostLabel: hostLabel,
                                startedAt: now,
                                endedAt: nil,
                                status: .active,
                                entries: [],
                                rcaMarkdown: nil)
        guard write(incident) else { return .failure(.couldNotWrite(incident.id)) }
        invalidateCache()
        return .success(incident)
    }

    /// Appends one timeline entry and writes it out **before returning** -
    /// never batched until "End Incident", which is the durability property
    /// this whole feature turns on.
    ///
    /// `artifactText`, when present, is written to its own file under the
    /// incident's `artifacts/` directory after being run through
    /// `LogRedactor`; only its relative path lands in `incident.yaml`.
    @discardableResult
    func append(_ entry: IncidentTimelineEntry, to incidentID: String, artifactText: String? = nil) -> Bool {
        guard var incident = load(id: incidentID), let dir = directory(forID: incidentID) else { return false }

        var stored = entry
        if let artifactText, !artifactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let redacted = LogRedactor.redact(artifactText).text
            let relative = "artifacts/\(entry.id).md"
            let url = dir.appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try redacted.write(to: url, atomically: true, encoding: .utf8)
                stored = IncidentTimelineEntry(id: entry.id, at: entry.at, kind: entry.kind,
                                               title: entry.title, detail: entry.detail,
                                               reference: entry.reference, artifact: relative)
            } catch {
                // The entry itself is still worth keeping - losing the record
                // that a turn happened is strictly worse than losing its
                // transcript snapshot.
                PersistenceFailureReporter.report(what: "incident artifact", path: url.path, error: error)
            }
        }

        incident.entries.append(stored)
        guard write(incident) else { return false }
        invalidateCache()
        return true
    }

    /// Marks the incident ended. Idempotent: ending an already-ended incident
    /// returns it unchanged rather than moving its `endedAt`.
    @discardableResult
    func end(id: String, now: Date = Date()) -> Incident? {
        guard var incident = load(id: id) else { return nil }
        guard incident.status == .active else { return incident }
        incident.status = .ended
        incident.endedAt = now
        guard write(incident) else { return nil }
        invalidateCache()
        return incident
    }

    /// Stores the generated postmortem alongside the record. Written to its
    /// own `rca.md` rather than into `incident.yaml`, so the metadata file
    /// stays a metadata file.
    @discardableResult
    func setRCA(id: String, markdown: String) -> Bool {
        guard var incident = load(id: id), let dir = directory(forID: id) else { return false }
        do {
            try markdown.write(to: dir.appendingPathComponent("rca.md"), atomically: true, encoding: .utf8)
        } catch {
            PersistenceFailureReporter.report(what: "incident RCA", path: dir.path, error: error)
            return false
        }
        incident.rcaMarkdown = markdown
        guard write(incident) else { return false }
        invalidateCache()
        return true
    }

    /// The stored text of an entry's artifact, if it has one.
    func artifactText(incidentID: String, entry: IncidentTimelineEntry) -> String? {
        guard let artifact = entry.artifact,
              let safe = Self.safeArtifactName(artifact),
              let dir = directory(forID: incidentID) else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(safe), encoding: .utf8)
    }

    /// S6: an entry's `artifact` is a *relative path read back off disk* (from
    /// the incident's own `incident.yaml`, which lives in the git-synced
    /// incident tree), and it was appended to the incident directory with no
    /// validation - so `artifact: ../../../../etc/passwd` would have made this
    /// read an arbitrary file and show it to the captain.
    ///
    /// This store only ever *writes* a plain `<entry-id>.md` next to the
    /// record, so anything that is not a single, non-dotted path component is
    /// not something this store produced. `slugify` already keeps the directory
    /// name safe; this is the file-name half it never had.
    ///
    /// Applied at load as well as here, so a traversal path never reaches the
    /// model in the first place.
    static func safeArtifactName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.hasPrefix("/"), !name.hasPrefix("~"),
              !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        // `artifacts/<entry-id>.md` is the one shape this store writes, so a
        // relative path of one or two plain components is allowed and anything
        // that could climb out - a `..`, a `.`-prefixed component, an empty
        // component from a doubled slash - is not.
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count <= 2 else { return nil }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.hasPrefix(".") else { return nil }
        }
        return name
    }

    /// Everything the postmortem generator is fed, assembled from the record
    /// rather than from any one surface's live state.
    ///
    /// This is the whole reason F8 feeds `SRELeadPostmortem` instead of a tab:
    /// the existing generator takes a transcript, and an incident's aggregate
    /// *is* a transcript - every SRE Lead turn's real text, plus a one-line
    /// account of every capture and runbook run that happened between them,
    /// in the order they happened.
    func aggregatedTranscript(for incident: Incident) -> String {
        var out: [String] = [
            "Incident \(incident.id): \(incident.title)",
            "Host: \(incident.hostLabel)",
            "Started: \(ShiftYamlBridge.isoString(incident.startedAt))",
        ]
        if let endedAt = incident.endedAt {
            out.append("Ended: \(ShiftYamlBridge.isoString(endedAt))")
        }
        out.append("")
        for entry in incident.entries {
            var block = "[\(entry.clockText)] \(entry.kind.kicker): \(entry.title)"
            if let detail = entry.detail, !detail.isEmpty { block += "\n\(detail)" }
            if let text = artifactText(incidentID: incident.id, entry: entry),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                block += "\n\(text)"
            }
            out.append(block)
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: Disk

    private func write(_ incident: Incident) -> Bool {
        let dir = directory(forID: incident.id) ?? newDirectory(for: incident)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try ShiftYamlBridge.writeMapping(path: dir.appendingPathComponent("incident.yaml").path,
                                             doc: yaml(incident))
        } catch {
            PersistenceFailureReporter.report(what: "incident record", path: dir.path, error: error)
            return false
        }
        gitSync?.markDirty()
        return true
    }

    private func yaml(_ incident: Incident) -> Yaml {
        var m = YamlOrderedMap()
        m[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str(incident.id)
        m[ShiftYamlBridge.key("title")] = ShiftYamlBridge.str(incident.title)
        m[ShiftYamlBridge.key("host_id")] = ShiftYamlBridge.str(incident.hostID)
        m[ShiftYamlBridge.key("host_label")] = ShiftYamlBridge.str(incident.hostLabel)
        m[ShiftYamlBridge.key("status")] = ShiftYamlBridge.str(incident.status.rawValue)
        m[ShiftYamlBridge.key("started_at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(incident.startedAt))
        m[ShiftYamlBridge.key("ended_at")] = incident.endedAt
            .map { ShiftYamlBridge.str(ShiftYamlBridge.isoString($0)) } ?? .null
        // The RCA lives in `rca.md`; the record only remembers that it exists.
        m[ShiftYamlBridge.key("has_rca")] = .bool(incident.rcaMarkdown != nil)
        m[ShiftYamlBridge.key("timeline")] = .array(incident.entries.map { entry in
            var e = YamlOrderedMap()
            e[ShiftYamlBridge.key("id")] = ShiftYamlBridge.str(entry.id)
            e[ShiftYamlBridge.key("at")] = ShiftYamlBridge.str(ShiftYamlBridge.isoString(entry.at))
            e[ShiftYamlBridge.key("kind")] = ShiftYamlBridge.str(entry.kind.rawValue)
            e[ShiftYamlBridge.key("title")] = ShiftYamlBridge.str(entry.title)
            e[ShiftYamlBridge.key("detail")] = entry.detail.map(ShiftYamlBridge.str) ?? .null
            e[ShiftYamlBridge.key("reference")] = entry.reference.map(ShiftYamlBridge.str) ?? .null
            e[ShiftYamlBridge.key("artifact")] = entry.artifact.map(ShiftYamlBridge.str) ?? .null
            return .dictionary(e)
        })
        return .dictionary(m)
    }

    private func scan() -> [Incident] {
        guard let years = try? fm.contentsOfDirectory(at: incidentsDir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [Incident] = []
        for year in years {
            guard (try? year.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let folders = try? fm.contentsOfDirectory(at: year,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if let incident = read(in: folder) { out.append(incident) }
            }
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    private func read(in folder: URL) -> Incident? {
        guard let doc = ShiftYamlBridge.readMapping(path: folder.appendingPathComponent("incident.yaml").path),
              let dict = doc.dictionary,
              let id = ShiftYamlBridge.string(dict["id"]) else { return nil }

        let entries: [IncidentTimelineEntry] = (dict["timeline"]?.array ?? []).compactMap { raw in
            guard let e = raw.dictionary,
                  let kind = IncidentEntryKind(rawValue: ShiftYamlBridge.string(e["kind"]) ?? ""),
                  let title = ShiftYamlBridge.string(e["title"]) else { return nil }
            return IncidentTimelineEntry(id: ShiftYamlBridge.string(e["id"]) ?? UUID().uuidString,
                                         at: ShiftYamlBridge.date(e["at"]) ?? Date(),
                                         kind: kind,
                                         title: title,
                                         detail: ShiftYamlBridge.string(e["detail"]),
                                         reference: ShiftYamlBridge.string(e["reference"]),
                                         artifact: ShiftYamlBridge.string(e["artifact"]).flatMap(Self.safeArtifactName))
        }

        let hasRCA = dict["has_rca"]?.bool ?? false
        var rca: String?
        if hasRCA {
            rca = try? String(contentsOf: folder.appendingPathComponent("rca.md"), encoding: .utf8)
        }

        return Incident(id: id,
                        title: ShiftYamlBridge.string(dict["title"]) ?? "Untitled incident",
                        hostID: ShiftYamlBridge.string(dict["host_id"]) ?? "",
                        hostLabel: ShiftYamlBridge.string(dict["host_label"]) ?? "",
                        startedAt: ShiftYamlBridge.date(dict["started_at"]) ?? Date(),
                        endedAt: ShiftYamlBridge.date(dict["ended_at"]),
                        status: IncidentStatus(rawValue: ShiftYamlBridge.string(dict["status"]) ?? "") ?? .ended,
                        entries: entries,
                        rcaMarkdown: rca)
    }

    // MARK: Paths + ids

    /// Finds an already-written folder by scanning rather than re-deriving it
    /// from the title, so an incident renamed after creation keeps its folder
    /// instead of the next write landing in a second one - the same lesson
    /// `LogAnalyzerStore.directory(forID:)` records.
    private func directory(forID id: String) -> URL? {
        guard let years = try? fm.contentsOfDirectory(at: incidentsDir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return nil }
        for year in years {
            guard let folders = try? fm.contentsOfDirectory(at: year,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for folder in folders where folder.lastPathComponent.hasPrefix("\(id)-") || folder.lastPathComponent == id {
                return folder
            }
        }
        return nil
    }

    private func newDirectory(for incident: Incident) -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let year = String(calendar.component(.year, from: incident.startedAt))
        let name = "\(incident.id)-\(LogAnalyzerStore.slugify(incident.title))"
        return incidentsDir
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// `INC-001`, `INC-002`, ... - one past the highest number already on
    /// disk, so numbering survives a relaunch and reads like a real incident
    /// number. Derived from the folder contents rather than a stored counter,
    /// which would be a second source of truth to keep in sync.
    static let idPrefix = "INC-"

    func nextIncidentID() -> String {
        let highest = all().compactMap { Int($0.id.dropFirst(Self.idPrefix.count)) }.max() ?? 0
        return String(format: "\(Self.idPrefix)%03d", highest + 1)
    }
}
