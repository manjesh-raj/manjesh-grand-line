// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for F5's command-palette providers
// (`fm/grandline-feature-f5-command-palette-expansion`), run via
// `FM_RUN_UNIFIED_SEARCH_TESTS=1 .build/debug/FirstmateCockpit` - same
// convention as `CommandLibraryStoreSelfTest.swift`/`ShiftStoreSelfTest.swift`.
//
// What this covers, and why each case is here rather than "the providers look
// right":
//
//   * **Every provider's matching**, against real stores backed by real
//     scratch directories (`FM_HOSTS_FILE`, `FM_SHIFT_DIR`,
//     `FM_COMMAND_LIBRARY_DIR`, `FM_DOCS_RUNBOOKS_DIR`) - never the captain's
//     real data. A host must be findable by tag and by address, not only by
//     label; a command by its command *text*, not only its name; a task by
//     title. These are the four things a captain actually types.
//   * **Grouping and ordering**, since the mockup's whole point is one list
//     sectioned by kind. A regression that flattens the groups, drops a
//     section, or reorders them fails here.
//   * **No capability lost when ⌘⇧P was absorbed** - the Shift provider is
//     asserted to search exactly what `ShiftSearchIndex` searched: active
//     tasks, follow-ups (pending *and* done), and projects.
//   * **The empty-query contract**: content providers stay silent, the
//     actions provider lists the verb surface. Getting this backwards would
//     make ⌘K open onto every task and 70+ commands at once.
//   * **The command provider never sends a half-substituted template.** A
//     command with an unfilled `{{token}}` must resolve to the *open* action,
//     not the send action - this is the one case where a wrong answer would
//     put `kubectl ... -n {{namespace}}` into a live terminal.
//   * **Dispatch actually reaches the right action**, via recording closures
//     rather than by reading the wiring - `activate()` on a host row must
//     produce a connect for *that* host and nothing else.
//
// Deliberately not covered here: the destructive-confirmation gate itself.
// `CommandRiskConfirmation` is a blocking `NSAlert.runModal()`, which a
// headless self-test cannot answer. What *is* checked, in
// `Phase2HardeningSelfTest`'s style, is the structural guarantee that matters
// - a source guard asserting the palette's command action goes through
// `CommandRiskConfirmation` and that there is exactly one definition of that
// gate in the app, so a future edit cannot quietly add a second (or a
// gate-free) path from a risky command to a terminal.

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing a suite: `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Foundation

enum UnifiedSearchSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("unified-search-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        setenv("FM_HOSTS_FILE", scratchRoot.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_SHIFT_DIR", scratchRoot.appendingPathComponent("shift", isDirectory: true).path, 1)
        setenv("FM_COMMAND_LIBRARY_DIR", scratchRoot.appendingPathComponent("commands", isDirectory: true).path, 1)
        setenv("FM_DOCS_RUNBOOKS_DIR", scratchRoot.appendingPathComponent("runbooks", isDirectory: true).path, 1)
        defer {
            unsetenv("FM_HOSTS_FILE")
            unsetenv("FM_SHIFT_DIR")
            unsetenv("FM_COMMAND_LIBRARY_DIR")
            unsetenv("FM_DOCS_RUNBOOKS_DIR")
        }

        // MARK: Hosts

        let hostStore = HostStore()
        var prodHost = Host(label: "Prod Bastion", address: "bastion.prod.internal")
        prodHost.tags = ["PROD"]
        prodHost.username = "sre"
        var devHost = Host(label: "DEV Box", address: "dev.internal")
        devHost.tags = ["DEV"]
        var taggedOnly = Host(label: "Payments jump", address: "jump.pay.internal")
        taggedOnly.tags = ["prod-adjacent"]
        hostStore.add(prodHost)
        hostStore.add(devHost)
        hostStore.add(taggedOnly)

        var connected: [Host] = []
        let hostProvider = UnifiedSearchHostProvider(store: hostStore) { connected.append($0) }

        let hostByLabel = hostProvider.items(query: "prod")
        // "Prod Bastion" by label, "Payments jump" by its `prod-adjacent`
        // tag - a matcher that only looked at `label` would find one.
        check(hostByLabel.count == 2,
              "host search for 'prod' should match by label and by tag, got \(hostByLabel.map(\.title))")
        check(hostByLabel.contains { $0.title == "Prod Bastion" }, "'prod' should match the Prod Bastion label")
        check(hostByLabel.contains { $0.title == "Payments jump" }, "'prod' should match a host's prod-adjacent tag")
        check(hostProvider.items(query: "dev.internal").count == 1, "a host should be findable by its address")
        check(hostProvider.items(query: "sre").count == 1, "a host should be findable by its username")
        check(hostProvider.items(query: "").isEmpty, "an empty query must not list every host")
        check(hostByLabel.allSatisfy { $0.kind == .host }, "host rows must carry the .host kind")
        check(hostByLabel.allSatisfy { $0.actionHint?.hasPrefix("Connect") == true },
              "a host row's chip should say Connect, matching the mockup")
        check(UnifiedSearchHostProvider.meta(for: prodHost) == "tag: PROD",
              "a tagged host's meta line should read 'tag: PROD' (mockup), got \(UnifiedSearchHostProvider.meta(for: prodHost))")
        // A host with no tag and no group must fall back to something real,
        // never a fabricated label.
        let bare = Host(label: "Bare", address: "10.0.0.9")
        check(UnifiedSearchHostProvider.meta(for: bare).contains("10.0.0.9"),
              "an untagged host's meta should fall back to its real address")

        // Dispatch: activating a host row connects that host and no other.
        if let row = hostByLabel.first(where: { $0.title == "Prod Bastion" }) {
            row.activate()
            check(connected.count == 1 && connected.first?.label == "Prod Bastion",
                  "activating a host row must connect exactly that host, got \(connected.map(\.label))")
        } else {
            failures.append("no Prod Bastion row to activate")
        }

        // MARK: Command library

        let commandStore = CommandLibraryStore()
        var sent: [(String, String)] = []   // (command id, generated text)
        var openedCommands: [String] = []
        let commandProvider = UnifiedSearchCommandProvider(
            store: commandStore,
            onSend: { command, generated in sent.append((command.id, generated)) },
            onOpen: { openedCommands.append($0) }
        )

        check(commandProvider.items(query: "").isEmpty, "an empty query must not list every saved command")
        let kubectlMatches = commandProvider.items(query: "kubectl")
        check(!kubectlMatches.isEmpty, "the seeded library should match 'kubectl' (by command text, not just name)")
        check(kubectlMatches.allSatisfy { $0.kind == .command }, "command rows must carry the .command kind")
        // Matching must be the library's own shipped matcher
        // (`DevOpsCommand.matches`), not a name-only one written here - so a
        // query that appears *only* in a command's template still finds it.
        // The probe word is picked out of real seed data rather than
        // hardcoded, so this can't rot into a no-op if the seeds change.
        var templateOnlyProbe: (command: DevOpsCommand, word: String)?
        for command in commandStore.commands {
            let haystack = ([command.name, command.description, command.category, command.subcategory ?? ""]
                + command.tags + command.parameters.map(\.name)).joined(separator: " ").lowercased()
            let word = command.commandTemplate
                .lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .first { $0.count >= 6 && !haystack.contains($0) }
            if let word {
                templateOnlyProbe = (command, word)
                break
            }
        }
        if let templateOnlyProbe {
            let hit = commandProvider.items(query: templateOnlyProbe.word)
            check(hit.contains { $0.id == templateOnlyProbe.command.id },
                  "'\(templateOnlyProbe.word)' appears only in \(templateOnlyProbe.command.name)'s template - "
                  + "a template-only match must still be found (DevOpsCommand.matches)")
        } else {
            failures.append("found no seeded command with a template-only word, so template matching went unchecked")
        }

        // The safety-critical case: a command with an unfilled token must
        // open, never send.
        let parameterized = commandStore.commands.first { $0.commandTemplate.contains("{{") && $0.effectiveParameters.contains { $0.defaultValue == nil } }
        if let parameterized {
            check(!UnifiedSearchCommandProvider.isReadyToRunWithoutInput(parameterized),
                  "a command with an unfilled token must not be considered ready to run")
            let items = commandProvider.items(query: parameterized.name)
            if let row = items.first(where: { $0.id == parameterized.id }) {
                check(row.actionHint == "Open \u{21B5}",
                      "a parameterized command's chip should say Open, got \(row.actionHint ?? "nil")")
                check(row.meta.contains("Fill in"),
                      "a parameterized command's meta should say it needs filling in, got \(row.meta)")
                row.activate()
                check(openedCommands == [parameterized.id],
                      "activating a parameterized command must open it in the library, not send it")
                check(sent.isEmpty,
                      "a command with an unfilled {{token}} must never reach the terminal - sent \(sent.map(\.1))")
            } else {
                failures.append("could not find the parameterized command's own row by name")
            }
        } else {
            failures.append("the seeded library has no parameterized command to test the open-not-send path with")
        }

        // ...and a ready-to-run command sends its fully-resolved text.
        let ready = commandStore.commands.first { UnifiedSearchCommandProvider.isReadyToRunWithoutInput($0) }
        if let ready {
            sent.removeAll()
            openedCommands.removeAll()
            let items = commandProvider.items(query: ready.name)
            if let row = items.first(where: { $0.id == ready.id }) {
                check(row.actionHint == "Send \u{21B5}", "a ready command's chip should say Send, got \(row.actionHint ?? "nil")")
                row.activate()
                check(sent.count == 1 && sent.first?.0 == ready.id,
                      "activating a ready command must send it")
                check(sent.first?.1.contains("{{") == false,
                      "the sent text must have no unsubstituted token left in it: \(sent.first?.1 ?? "")")
                check(openedCommands.isEmpty, "a ready command should send, not open the library")
            } else {
                failures.append("could not find the ready-to-run command's own row by name")
            }
        }

        // MARK: Tasks, follow-ups, projects (⌘⇧P's own coverage, preserved)

        let shiftStore = ShiftStore()
        var project = ShiftProject.fresh()
        project.name = "Prod hardening"
        shiftStore.addProject(project)

        var task = ShiftTask.fresh()
        task.title = "Rotate prod DB credentials"
        task.projectID = project.id
        task.dueDate = isoDay(offsetDays: 1)
        shiftStore.addTask(task)

        var overdueTask = ShiftTask.fresh()
        overdueTask.title = "Patch prod kernel"
        overdueTask.dueDate = isoDay(offsetDays: -3)
        shiftStore.addTask(overdueTask)

        var pendingFollowUp = ShiftFollowUp.fresh()
        pendingFollowUp.title = "Check prod backup ran"
        pendingFollowUp.followUpAt = isoDay(offsetDays: 2)
        shiftStore.addFollowUp(pendingFollowUp)

        var doneFollowUp = ShiftFollowUp.fresh()
        doneFollowUp.title = "Prod cert renewal confirmed"
        doneFollowUp.status = .done
        shiftStore.addFollowUp(doneFollowUp)

        var openedTasks: [String] = []
        var openedFollowUps: [String] = []
        var openedProjects: [String] = []
        let shiftProvider = UnifiedSearchShiftProvider(
            store: shiftStore,
            onOpenTask: { openedTasks.append($0) },
            onOpenFollowUp: { openedFollowUps.append($0) },
            onOpenProject: { openedProjects.append($0) }
        )

        let shiftHits = shiftProvider.items(query: "prod")
        check(shiftHits.contains { $0.kind == .task && $0.title == "Rotate prod DB credentials" },
              "the Shift provider must search active tasks (⌘⇧P's own coverage)")
        check(shiftHits.contains { $0.kind == .followUp && $0.title == "Check prod backup ran" },
              "the Shift provider must search pending follow-ups")
        // ⌘⇧P searched *done* follow-ups too - dropping them would be a real
        // capability loss when it was absorbed.
        check(shiftHits.contains { $0.kind == .followUp && $0.title == "Prod cert renewal confirmed" },
              "the Shift provider must search done follow-ups too, not just pending")
        check(shiftHits.contains { $0.kind == .project && $0.title == "Prod hardening" },
              "the Shift provider must search projects")
        check(shiftProvider.items(query: "").isEmpty, "an empty query must not list every task")

        // Due status, from the app's own formatter - the mockup's "Due
        // tomorrow" line.
        if let dueRow = shiftHits.first(where: { $0.title == "Rotate prod DB credentials" }) {
            check(dueRow.meta.lowercased().contains("tomorrow"),
                  "a task due tomorrow should say so (mockup), got \(dueRow.meta)")
            check(dueRow.meta.contains("Prod hardening"),
                  "a task in a project should name it, got \(dueRow.meta)")
        }
        let overdueMeta = UnifiedSearchShiftProvider.taskMeta(overdueTask, projectName: nil)
        check(overdueMeta.contains("Overdue"), "a past-due task should read Overdue, got \(overdueMeta)")

        if let taskRow = shiftHits.first(where: { $0.kind == .task }) { taskRow.activate() }
        check(openedTasks.count == 1, "activating a task row must open exactly one task")
        check(openedFollowUps.isEmpty && openedProjects.isEmpty,
              "a task row must not also fire the follow-up/project actions")

        // MARK: Runbooks and postmortems (unchanged pre-F5 behaviour)

        let docsStore = DocsRunbookStore()
        _ = docsStore.createRunbook(title: "Prod rolling restart", content: """
        # Prod rolling restart

        ```
        kubectl rollout restart deployment/api -n prod
        kubectl rollout status deployment/api -n prod
        ```
        """)
        _ = docsStore.createPostmortem(title: "Prod outage 2026-01-04", content: """
        # Prod outage 2026-01-04

        ## Root Cause
        The prod api deployment ran out of memory after a config change.
        """)

        var openedRunbooks: [String] = []
        var openedPostmortems: [String] = []
        let docsProvider = UnifiedSearchDocsProvider(
            store: docsStore,
            onOpenRunbook: { openedRunbooks.append($0) },
            onOpenPostmortem: { openedPostmortems.append($0) }
        )
        let docsHits = docsProvider.items(query: "prod")
        check(docsHits.contains { $0.kind == .runbook }, "the docs provider must still find runbooks")
        check(docsHits.contains { $0.kind == .postmortem }, "the docs provider must still find postmortems")
        check(docsProvider.items(query: "").isEmpty,
              "an empty query must return nothing from docs (unchanged pre-F5 behaviour)")
        if let runbookRow = docsHits.first(where: { $0.kind == .runbook }) {
            // "Runbook · Kubernetes · 2 steps" - derived from the document's
            // own fenced commands, the same derivation the Docs cards show.
            check(runbookRow.meta.contains("2 steps"),
                  "a runbook's meta should carry its real step count (mockup), got \(runbookRow.meta)")
            runbookRow.activate()
            check(openedRunbooks.count == 1 && openedPostmortems.isEmpty,
                  "activating a runbook row must open a runbook, not a postmortem")
        }
        if let pmRow = docsHits.first(where: { $0.kind == .postmortem }) {
            check(pmRow.meta.contains("Root cause"),
                  "a postmortem's meta should carry its root cause, got \(pmRow.meta)")
        }

        // MARK: App actions and destinations

        // Built without an `AppShellController` (which needs a real view
        // hierarchy) - the shape and matching are what this checks; the real
        // wiring is `standard(shell:)`, one call per existing menu action.
        var ran: [String] = []
        let actionProvider = UnifiedSearchActionProvider(actions: [
            .init(title: "Switch to Vault", meta: "Destination", keywords: ["Vault"], run: { ran.append("vault") }),
            .init(title: "New Task\u{2026}", meta: "Tasks", keywords: ["add", "create"], run: { ran.append("newTask") }),
            .init(title: "Quick Connect", meta: "Hosts", keywords: ["ssh"], run: { ran.append("quickConnect") }),
        ])
        // The one provider that answers an empty query - this is what makes
        // ⌘K open as a verb list.
        check(actionProvider.items(query: "").count == 3,
              "the actions provider must list every verb for an empty query")
        check(actionProvider.items(query: "vault").count == 1, "an action should match by title")
        check(actionProvider.items(query: "ssh").count == 1, "an action should match by keyword alias")
        check(actionProvider.items(query: "create").count == 1, "an action should match by keyword alias")
        actionProvider.items(query: "vault").first?.activate()
        check(ran == ["vault"], "activating an action row must run that action, got \(ran)")

        // Every real destination is reachable as a verb, so no page is
        // keyboard-unreachable.
        check(RailDestination.allCases.count >= 15,
              "sanity: the destination list should still be the app's full set, got \(RailDestination.allCases.count)")

        // MARK: Grouping and ordering (the mockup's own structure)

        let index = UnifiedSearchIndex()
        index.register(hostProvider)
        index.register(commandProvider)
        index.register(shiftProvider)
        index.register(docsProvider)
        index.register(actionProvider)

        let groups = index.groups(query: "prod")
        let titles = groups.map(\.title)
        check(titles.contains("Hosts"), "grouped results should include a Hosts section for 'prod', got \(titles)")
        check(titles.contains("Tasks & follow-ups"), "grouped results should include Tasks & follow-ups, got \(titles)")
        check(titles.contains("Runbooks"), "grouped results should include Runbooks, got \(titles)")
        check(titles.contains("Postmortems"), "grouped results should include Postmortems, got \(titles)")
        // Ordering is the mockup's: hosts first, actions last.
        if let hostsAt = titles.firstIndex(of: "Hosts"), let tasksAt = titles.firstIndex(of: "Tasks & follow-ups") {
            check(hostsAt < tasksAt, "Hosts must come before Tasks & follow-ups, got \(titles)")
        }
        check(titles.last == "Actions" || !titles.contains("Actions"),
              "Actions, when present, must be the last section, got \(titles)")
        check(titles == UnifiedSearchKind.groupOrder.filter(titles.contains),
              "group order must follow UnifiedSearchKind.groupOrder, got \(titles)")
        // Tasks, follow-ups and projects collapse into one section, exactly
        // as the mockup shows - three kinds, one header.
        if let tasksGroup = groups.first(where: { $0.title == "Tasks & follow-ups" }) {
            let kinds = Set(tasksGroup.items.map(\.kind).map { "\($0)" })
            check(kinds.count >= 2,
                  "tasks/follow-ups/projects must share one section, got kinds \(kinds)")
        }
        // A group with no matches is omitted rather than rendered empty.
        let narrow = index.groups(query: "Prod Bastion")
        check(!narrow.map(\.title).contains("Postmortems"),
              "a section with no matches must be omitted, got \(narrow.map(\.title))")

        // The per-group cap, and its overflow being reported rather than
        // silently dropped (AGENTS.md's own "no silent caps" rule).
        let broad = index.groups(query: "e")
        if let commandsGroup = broad.first(where: { $0.title == "Commands" }) {
            check(commandsGroup.items.count <= UnifiedSearchIndex.maxPerGroup,
                  "a group must never render more than maxPerGroup rows, got \(commandsGroup.items.count)")
            let total = commandProvider.items(query: "e").count
            check(commandsGroup.overflow == max(0, total - UnifiedSearchIndex.maxPerGroup),
                  "the overflow count must report every match the cap dropped (\(total) matched)")
        } else {
            failures.append("expected a broad query to match commands so the cap can be checked")
        }
        // The flat list arrow keys walk must be exactly the rendered rows, in
        // display order - a mismatch would move the selection to a row the
        // captain is not looking at.
        check(index.flatItems(query: "prod").map(\.title) == groups.flatMap(\.items).map(\.title),
              "flatItems must be the grouped rows in display order")

        // MARK: Source guards - the gate, and no second palette

        // These skip (rather than fail) when the source tree is not
        // alongside the binary - the established convention for every source
        // guard in this directory, see `SelfTestSources`' own header.
        if let sources = SelfTestSources.appSourceDirectory(),
           let files = SelfTestSources.appSourceFiles() {
            func filesContaining(_ pattern: String) -> [String] {
                files.compactMap { url in
                    guard let text = try? String(contentsOf: url, encoding: .utf8),
                          text.contains(pattern) else { return nil }
                    return url.lastPathComponent
                }
            }
            // Exactly one definition of the destructive-command gate, so a
            // future edit cannot quietly add a second (or a gate-free) path
            // from a risky command to a terminal.
            let gateDefinitions = filesContaining("enum CommandRiskConfirmation")
            check(gateDefinitions.count == 1,
                  "there must be exactly one CommandRiskConfirmation definition, found \(gateDefinitions)")
            // ...and the palette's own command action goes through it.
            let mainText = (try? String(contentsOf: sources.appendingPathComponent("main.swift"), encoding: .utf8)) ?? ""
            check(mainText.contains("CommandRiskConfirmation.confirm"),
                  "the palette's command action must route through CommandRiskConfirmation - a palette "
                  + "must never be a way around a destructive command's confirmation")
            // ⌘⇧P is absorbed: no second palette type left behind.
            check(filesContaining("class ShiftSearchController").isEmpty,
                  "ShiftSearchController must be gone - ⌘K absorbed ⌘⇧P (two overlapping search UIs was the bug)")
            check(!FileManager.default.fileExists(atPath: sources.appendingPathComponent("ShiftSearch.swift").path),
                  "ShiftSearch.swift must be deleted, not left behind unused")
        }

        if failures.isEmpty {
            print("UnifiedSearchSelfTest: OK")
            return true
        }
        print("UnifiedSearchSelfTest: \(failures.count) failure(s)")
        for f in failures { print("  - \(f)") }
        return false
    }

    /// `"YYYY-MM-DD"` for today plus `offsetDays` - the format
    /// `ShiftTask.dueDate`/`ShiftFollowUp.followUpAt` persist, computed
    /// relative to now (never a hardcoded calendar date, which would rot).
    private static func isoDay(offsetDays: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offsetDays, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        return f.string(from: date)
    }

}

#endif
