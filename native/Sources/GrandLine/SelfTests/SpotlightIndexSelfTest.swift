// Grand Line - native macOS app.
//
// F-04 of full review 4: tasks, notes, links, sticky notes and runbooks in
// Spotlight. Run with `FM_RUN_SPOTLIGHT_INDEX_TESTS=1 .build/debug/GrandLine`.
//
// Headless. The real Core Spotlight index is never written: the indexer is
// handed a recording sink.
//
// What it pins:
//
//  - **What is indexed**: open tasks with their project, due date and
//    checklist; not completed ones; notes with their folder; links, sticky
//    notes and runbooks. A kind turned off in Settings is left out.
//  - **Titles only while locked**, and nothing at all under "Nothing" - read
//    off what the sink was actually handed.
//  - **A result chosen while locked waits for the unlock** (GL-09), says on
//    the lock screen what it will open, and then opens it.
//  - **Source guards**: the indexer is built from the five stores and never
//    from the vault, and the app delegate answers Spotlight's activity.

#if FM_SELFTESTS

import AppKit
import CoreSpotlight

enum SpotlightIndexSelfTest {

    static func run() -> Bool {
        var ok = true
        let saved = (AppSettings.shared.spotlightEnabled, AppSettings.shared.spotlightDisabledKinds,
                     AppSettings.shared.spotlightLockedMode)
        let wasLocked = AppLockGate.shared.isLocked
        defer {
            AppSettings.shared.spotlightEnabled = saved.0
            AppSettings.shared.spotlightDisabledKinds = saved.1
            AppSettings.shared.spotlightLockedMode = saved.2
            AppLockGate.shared.setLocked(wasLocked)
        }
        let cases: [(String, () -> String?)] = [
            ("entries from the stores", test_entries),
            ("a kind turned off is left out", test_disabledKind),
            ("identifiers round-trip", test_identifiers),
            ("locked shows titles only, or nothing", test_lockedVisibility),
            ("the indexer writes what the lock allows", test_indexerWrites),
            ("a result chosen while locked opens after unlock", test_lockedOpen),
            ("never the vault; the delegate answers Spotlight", test_sourceGuards),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[spotlight] \(name): \(failure)", &ok) } else { print("[spotlight] PASS \(name)") }
        }
        print(ok ? "[spotlight] ALL PASS" : "[spotlight] FAILED")
        return ok
    }

    final class RecordingSink: SpotlightSink {
        var written: [[SpotlightEntry]] = []
        var removals = 0
        func replace(with entries: [SpotlightEntry], completion: @escaping () -> Void) {
            written.append(entries)
            completion()
        }
        func removeAll(completion: @escaping () -> Void) {
            removals += 1
            written.append([])
            completion()
        }
    }

    static func sources() -> SpotlightIndex.Sources {
        var project = ShiftProject.fresh()
        project.name = "Infra hardening"
        var open = ShiftTask.fresh()
        open.title = "Renew the staging TLS certificate"
        open.projectID = project.id
        open.dueDate = "2026-11-23"
        open.priority = .high
        open.description = "Waiting on the CA to sign. Edge proxies first, then the bastion."
        open.subtasks = [ShiftSubtask(id: "a", title: "Generate the CSR", done: true),
                         ShiftSubtask(id: "b", title: "CA signs it", done: false)]
        var done = ShiftTask.fresh()
        done.title = "Upgrade Postgres on staging"
        done.status = .completed
        let note = StickyNote(id: "s1", title: "", text: "cert-manager: renewBefore 720h on staging",
                              color: .pink, x: 0, y: 0, width: 200, height: 200, rotationDegrees: 0, createdAt: Date())
        return SpotlightIndex.Sources(tasks: [open, done], followUps: [], projects: [project],
                                      pages: [NotebookPage(id: "edge-architecture/tls", title: "TLS termination",
                                                           content: "Short-lived certificates in practice", modifiedAt: Date())],
                                      links: [], stickies: [note],
                                      runbooks: [DocsRunbook(id: "rb1", title: "Rotate a TLS certificate",
                                                             content: "1. Check the expiry", modifiedAt: Date())])
    }

    static func test_entries() -> String? {
        let entries = SpotlightIndex.entries(from: sources(), enabled: Set(SpotlightEntry.Kind.allCases))
        guard let task = entries.first(where: { $0.kind == .task }) else { return "no task entry" }
        guard !entries.contains(where: { $0.title == "Upgrade Postgres on staging" }) else {
            return "a completed task was indexed"
        }
        for needle in ["Infra hardening", "Due 2026-11-23", "High priority", "Checklist 1 of 2 done", "Waiting on the CA"]
        where !task.detail.contains(needle) {
            return "the task preview is missing \(needle): \(task.detail)"
        }
        guard entries.contains(where: { $0.kind == .note && $0.title.hasSuffix("\u{203A} TLS termination") }) else {
            return "the note should carry its folder: \(entries.map(\.title))"
        }
        guard entries.contains(where: { $0.kind == .sticky && $0.title == "cert-manager: renewBefore 720h on staging" }) else {
            return "an untitled sticky should fall back to its first line"
        }
        guard entries.contains(where: { $0.kind == .runbook }) else { return "no runbook entry" }
        return nil
    }

    static func test_disabledKind() -> String? {
        var kinds = Set(SpotlightEntry.Kind.allCases)
        kinds.remove(.runbook)
        let entries = SpotlightIndex.entries(from: sources(), enabled: kinds)
        return entries.contains(where: { $0.kind == .runbook }) ? "a turned-off kind was indexed" : nil
    }

    static func test_identifiers() -> String? {
        guard let parsed = SpotlightEntry.parse(identifier: "note:edge/tls:termination"),
              parsed.kind == .note, parsed.recordID == "edge/tls:termination" else { return "an id with a colon did not survive" }
        if SpotlightEntry.parse(identifier: "vault:abc") != nil { return "an unknown kind parsed" }
        if SpotlightEntry.parse(identifier: "task:") != nil { return "an empty id parsed" }
        return nil
    }

    static func test_lockedVisibility() -> String? {
        let entries = SpotlightIndex.entries(from: sources(), enabled: Set(SpotlightEntry.Kind.allCases))
        guard entries.contains(where: { !$0.detail.isEmpty }) else { return "the fixture has no previews, so this is vacuous" }
        let titles = SpotlightIndex.visible(entries, locked: true, lockedMode: .titlesOnly)
        guard titles.count == entries.count, titles.allSatisfy({ $0.detail.isEmpty && $0.keywords.isEmpty }) else {
            return "titles-only kept a preview"
        }
        guard SpotlightIndex.visible(entries, locked: true, lockedMode: .nothing).isEmpty else { return "Nothing kept items" }
        guard SpotlightIndex.visible(entries, locked: false, lockedMode: .nothing) == entries else { return "unlocked lost items" }
        return nil
    }

    static func makeIndexer(_ sink: RecordingSink) -> SpotlightIndexer {
        let all = sources()
        var memory = all
        memory.pages = []
        memory.runbooks = []
        return SpotlightIndexer(sink: sink, inMemory: { memory }, onDisk: { (all.pages, all.runbooks) })
    }

    static func rebuild(_ indexer: SpotlightIndexer) {
        var finished = false
        indexer.rebuild { finished = true }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func test_indexerWrites() -> String? {
        AppSettings.shared.spotlightEnabled = true
        AppSettings.shared.spotlightDisabledKinds = []
        AppSettings.shared.spotlightLockedMode = .titlesOnly
        let sink = RecordingSink()
        let indexer = makeIndexer(sink)
        var locked = false
        indexer.isLocked = { locked }
        rebuild(indexer)
        guard let first = sink.written.last, first.count == 4, first.contains(where: { !$0.detail.isEmpty }) else {
            return "unlocked should write all four entries with previews: \(sink.written.last ?? [])"
        }
        locked = true
        rebuild(indexer)
        guard let second = sink.written.last, second.count == 4, second.allSatisfy({ $0.detail.isEmpty }) else {
            return "locked should write titles only"
        }
        AppSettings.shared.spotlightLockedMode = .nothing
        rebuild(indexer)
        guard sink.written.last?.isEmpty == true, sink.removals == 1 else { return "Nothing should empty the index" }
        AppSettings.shared.spotlightEnabled = false
        locked = false
        rebuild(indexer)
        guard sink.written.last?.isEmpty == true else { return "turned off should empty the index" }
        return nil
    }

    static func test_lockedOpen() -> String? {
        let sink = RecordingSink()
        let indexer = makeIndexer(sink)
        AppSettings.shared.spotlightEnabled = true
        AppSettings.shared.spotlightLockedMode = .titlesOnly
        rebuild(indexer)
        var opened: [String] = []
        var lockText: String?
        indexer.open = { kind, id in opened.append("\(kind.rawValue):\(id)") }
        indexer.showPendingOnLock = { lockText = $0 }
        guard let task = indexer.lastEntries.first(where: { $0.kind == .task }) else { return "no task entry" }
        AppLockGate.shared.setLocked(true)
        indexer.handle(identifier: task.identifier)
        guard opened.isEmpty else { return "a result opened while locked" }
        guard lockText == "Unlock to open \u{201C}Renew the staging TLS certificate\u{201D}. Spotlight showed the title only." else {
            return "the lock screen said \(lockText ?? "nothing")"
        }
        AppLockGate.shared.setLocked(false)
        indexer.openPendingIfUnlocked()
        guard opened == [task.identifier] else { return "after unlock it opened \(opened)" }
        indexer.openPendingIfUnlocked()
        return opened.count == 1 ? nil : "the pending open ran twice"
    }

    static func test_sourceGuards() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { print("[spotlight] SKIP guards"); return nil }
        func read(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        let index = read("SpotlightIndex.swift")
        let code = index.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for banned in ["CredentialVault", "VaultSource", "ClipboardHistory", "KeychainKeyStore"] where code.contains(banned) {
            return "SpotlightIndex.swift reaches \(banned)"
        }
        let delegate = read("AppComposition.swift")
        guard delegate.contains("CSSearchableItemActionType"), delegate.contains("spotlightIndexer.handle(identifier:"),
              delegate.contains("spotlightIndexer.start()") else {
            return "the app delegate no longer answers Spotlight's activity or starts the indexer"
        }
        return nil
    }
}

#endif
