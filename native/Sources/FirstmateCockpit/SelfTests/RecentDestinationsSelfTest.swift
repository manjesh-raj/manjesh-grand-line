// Manjesh Grand Line - native macOS app.
//
// Coverage for the Recents dropdown (`fm/grandline-recents-navigation`): the
// captain's own scenario is jumping Command -> Console, then wandering off
// through Updates, Sticky Board, Vault, etc. with no quick way back to where
// he actually was working. He reviewed four approaches and chose a small
// "Recents" button opening a dropdown of recently-visited destinations, with
// an explicit placement correction - it sits after the space pills, not next
// to the logo.
//
// **What this drives for real, and what it deliberately does not.**
// `RecentDestinations`'s own dedup/reorder/cap logic is pure Swift, tested
// directly with no AppKit at all. The navigation half is driven through a
// real `AppShellController` mounted in a real `NSWindow` - real `show(_:)`
// calls, and (for the host-page half) a real `switchToSession` against a
// seeded `ConsoleController` via `debugSeedHostConsole`, which bypasses only
// the real `ssh` fork `connectHost` would otherwise perform, matching
// `SessionSwitcherSelfTest`'s own established approach for the identical
// reason. The bar's own button/popover wiring is driven through a real
// `DaylightBarController`/`RecentDestinationsController`, real theme
// application, and a real geometry read after a real layout pass.
//
// Run with:
//   swift build && FM_RUN_RECENT_DESTINATIONS_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum RecentDestinationsSelfTest {

    static func run() -> Bool {
        // A suite that changes the active theme MUST put it back - see
        // `AppShellBodyWidthSelfTest.withScratchEnv`'s own long note on why a
        // leaked `fm.themeID` poisons every later suite in the run.
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        var failures: [String] = []
        let cases: [(String, () -> String?)] = [
            ("recordRemovesArrivingAndInsertsLeavingDeduped", test_recordRemovesArrivingAndInsertsLeavingDeduped),
            ("recordCapsAtFive", test_recordCapsAtFive),
            ("recordOfTheSameDestinationIsANoOp", test_recordOfTheSameDestinationIsANoOp),
            ("relativeTimeTextFormatting", test_relativeTimeTextFormatting),
            ("kindPropertiesForRailAndHost", test_kindPropertiesForRailAndHost),
            ("identityKeyDistinguishesHostsByIdNotLabel", test_identityKeyDistinguishesHostsByIdNotLabel),
            ("shellNavigationBuildsRecentsExcludingCurrent", test_shellNavigationBuildsRecentsExcludingCurrent),
            ("revisitingADestinationMovesItToTopWithNoDuplicate", test_revisitingADestinationMovesItToTopWithNoDuplicate),
            ("hostPageNavigationIsTracked", test_hostPageNavigationIsTracked),
            ("panelRendersRowsAndClickNavigates", test_panelRendersRowsAndClickNavigates),
            ("panelShowsEmptyStateWithNothingRecorded", test_panelShowsEmptyStateWithNothingRecorded),
            ("barButtonSitsAfterThePillsBeforeSearch", test_barButtonSitsAfterThePillsBeforeSearch),
            ("barButtonThemesAcrossLightAndDark", test_barButtonThemesAcrossLightAndDark),
            ("recordNavigationIsTheOnlyWriter", test_recordNavigationIsTheOnlyWriter),
        ]
        for (name, check) in cases {
            if let failure = check() { failures.append("\(name): \(failure)") }
        }
        for failure in failures { print("RecentDestinationsSelfTest FAIL - \(failure)") }
        print(failures.isEmpty ? "RecentDestinationsSelfTest: all \(cases.count) checks passed"
                               : "RecentDestinationsSelfTest: FAILED (\(failures.count)/\(cases.count))")
        return failures.isEmpty
    }

    // MARK: Fixtures

    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-recent-destinations-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
            "FM_COMMAND_LIBRARY_DIR": dir.appendingPathComponent("commands").path,
        ]
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let savedTheme = ThemeManager.shared.theme
        let savedFontSize = AppSettings.shared.fontSize
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.fontSize = savedFontSize
        }
        return body()
    }

    /// The exact production dependency shape `main.swift` builds, mounted in
    /// a real (never ordered-front) window - copied from
    /// `SessionSwitcherSelfTest.makeMountedShell` so both suites drive the
    /// same real object graph.
    private static func makeMountedShell() -> (window: NSWindow, shell: AppShellController, keyStore: SSHKeyStore, snippetStore: SnippetStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                         snippetStore: snippetStore, dictationStore: DictationStore()),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore,
            shiftStore: ShiftStore(), dictationStore: DictationStore(),
            commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        shell.view.layoutSubtreeIfNeeded()
        return (window, shell, keyStore, snippetStore)
    }

    // MARK: Registry - pure logic

    private static func test_recordRemovesArrivingAndInsertsLeavingDeduped() -> String? {
        let registry = RecentDestinations()
        let console = RecentDestinationKind.rail(.console)
        let updates = RecentDestinationKind.rail(.updates)
        let stickyBoard = RecentDestinationKind.rail(.stickyBoard)
        let vault = RecentDestinationKind.rail(.vault)

        // The app's very first navigation - nothing to record yet.
        registry.recordNavigation(leaving: nil, arriving: console)
        guard registry.entries.isEmpty else { return "a first-ever navigation manufactured an entry" }

        registry.recordNavigation(leaving: console, arriving: updates)
        registry.recordNavigation(leaving: updates, arriving: stickyBoard)
        registry.recordNavigation(leaving: stickyBoard, arriving: vault)
        guard registry.entries.map(\.kind.title) == ["Sticky Board", "Updates", "Console"] else {
            return "expected [Sticky Board, Updates, Console], got \(registry.entries.map(\.kind.title))"
        }
        // Vault is current - it must never appear in its own recent list.
        guard !registry.entries.contains(where: { $0.kind.identityKey == vault.identityKey }) else {
            return "the currently-showing destination appeared in its own Recents list"
        }

        // Revisiting Updates: it dedups out of its old position and the
        // captain's own explicit requirement ("revisiting moves an entry to
        // the top") is satisfied by inserting the freshly-left Vault instead.
        registry.recordNavigation(leaving: vault, arriving: updates)
        guard registry.entries.map(\.kind.title) == ["Vault", "Sticky Board", "Console"] else {
            return "revisit did not dedup/reorder correctly - got \(registry.entries.map(\.kind.title))"
        }
        return nil
    }

    private static func test_recordCapsAtFive() -> String? {
        let registry = RecentDestinations()
        let rails: [RailDestination] = [.console, .updates, .stickyBoard, .vault, .docs, .tools, .dictation]
        var previous: RecentDestinationKind?
        for dest in rails {
            let kind = RecentDestinationKind.rail(dest)
            registry.recordNavigation(leaving: previous, arriving: kind)
            previous = kind
        }
        guard registry.entries.count == RecentDestinations.capacity else {
            return "expected a cap of \(RecentDestinations.capacity), got \(registry.entries.count)"
        }
        // The oldest (Console, the first one ever left) must have aged out.
        guard !registry.entries.contains(where: { $0.kind.title == "Console" }) else {
            return "the oldest entry should have been trimmed by the cap"
        }
        // The most recent one left (Tools - the last stop before the final
        // `.dictation`, which is current and therefore excluded) must be at
        // the top.
        guard registry.entries.first?.kind.title == "Tools" else {
            return "expected the most recently left destination at the top, got \(registry.entries.first?.kind.title ?? "nil")"
        }
        return nil
    }

    private static func test_recordOfTheSameDestinationIsANoOp() -> String? {
        let registry = RecentDestinations()
        let console = RecentDestinationKind.rail(.console)
        registry.recordNavigation(leaving: nil, arriving: console)
        // Re-showing the same destination (a stray click on an already-
        // selected quick-access icon) must not manufacture a "just visited"
        // entry for the place the captain never left.
        registry.recordNavigation(leaving: console, arriving: console)
        guard registry.entries.isEmpty else {
            return "re-showing the current destination created an entry: \(registry.entries.map(\.kind.title))"
        }
        return nil
    }

    private static func test_relativeTimeTextFormatting() -> String? {
        let now = Date()
        let table: [(TimeInterval, String)] = [
            (5, "just now"), (65, "1m ago"), (14 * 60, "14m ago"),
            (60 * 60, "1h 00m ago"), (125 * 60, "2h 05m ago"),
        ]
        for (seconds, expected) in table {
            let entry = RecentDestinationEntry(kind: .rail(.console), visitedAt: now.addingTimeInterval(-seconds))
            let text = entry.relativeTimeText(now: now)
            guard text == expected else { return "for \(seconds)s expected '\(expected)', got '\(text)'" }
        }
        return nil
    }

    private static func test_kindPropertiesForRailAndHost() -> String? {
        let console = RecentDestinationKind.rail(.console)
        guard console.title == "Console", console.symbol == RailDestination.console.symbol,
              console.kicker == "Command" else {
            return "console kind resolved wrong: title=\(console.title) symbol=\(console.symbol) kicker=\(console.kicker)"
        }
        let updates = RecentDestinationKind.rail(.updates)
        guard updates.kicker == "Engineering" else { return "updates kicker expected Engineering, got \(updates.kicker)" }
        // The two destinations no module opens fall back to "Overview".
        let home = RecentDestinationKind.rail(.homeCanvas)
        guard home.kicker == "Overview" else { return "home canvas kicker expected Overview, got \(home.kicker)" }

        let id = UUID()
        let host = RecentDestinationKind.host(id: id, label: "DEV Bastion")
        guard host.title == "DEV Bastion", host.symbol == RailDestination.hosts.symbol,
              host.hue == RailDestination.hosts.domainHue, host.kicker == "Hosts" else {
            return "host kind resolved wrong: \(host)"
        }
        return nil
    }

    private static func test_identityKeyDistinguishesHostsByIdNotLabel() -> String? {
        let id = UUID()
        let a = RecentDestinationKind.host(id: id, label: "DEV Bastion")
        let b = RecentDestinationKind.host(id: id, label: "DEV Bastion (renamed)")
        guard a.identityKey == b.identityKey else {
            return "a renamed host stopped matching its own identity: \(a.identityKey) vs \(b.identityKey)"
        }
        let other = RecentDestinationKind.host(id: UUID(), label: "DEV Bastion")
        guard a.identityKey != other.identityKey else {
            return "two different hosts with the same label collapsed to one identity"
        }
        return nil
    }

    // MARK: Shell navigation - integration

    private static func test_shellNavigationBuildsRecentsExcludingCurrent() -> String? {
        withScratchEnv {
            let (_, shell, _, _) = makeMountedShell()
            // Mounting the shell already ran its own real launch navigation
            // (GL-31: Home, or Bootstrap on a machine with no firstmate home
            // resolved) - `updateRecentDestinations` correctly recorded it as
            // "left" the moment my first `show(_:)` below moves away from it,
            // so it trails these four real entries. Checking the leading
            // prefix is what makes this assertion honest about what my own
            // sequence produced without needing to know or care which one the
            // launch landed on.
            shell.show(.console)
            shell.show(.updates)
            shell.show(.stickyBoard)
            shell.show(.vault)
            let titles = shell.recentDestinations.entries.map(\.kind.title)
            guard Array(titles.prefix(3)) == ["Sticky Board", "Updates", "Console"] else {
                return "expected [Sticky Board, Updates, Console, ...] while on Vault, got \(titles)"
            }
            guard !titles.contains("Vault") else {
                return "the currently-showing destination (Vault) appeared in its own Recents list"
            }
            return nil
        }
    }

    private static func test_revisitingADestinationMovesItToTopWithNoDuplicate() -> String? {
        withScratchEnv {
            let (_, shell, _, _) = makeMountedShell()
            shell.show(.console)
            shell.show(.updates)
            shell.show(.stickyBoard)
            shell.show(.vault)
            shell.show(.updates)
            let titles = shell.recentDestinations.entries.map(\.kind.title)
            guard Array(titles.prefix(3)) == ["Vault", "Sticky Board", "Console"] else {
                return "expected [Vault, Sticky Board, Console, ...] while back on Updates, got \(titles)"
            }
            guard !titles.contains("Updates") else {
                return "the currently-showing destination (Updates) appeared in its own Recents list after a revisit"
            }
            // A stray re-click on the destination already showing must not
            // add or move anything.
            shell.show(.updates)
            let titlesAfterReshow = shell.recentDestinations.entries.map(\.kind.title)
            guard titlesAfterReshow == titles else {
                return "re-showing the current destination changed Recents: \(titlesAfterReshow)"
            }
            return nil
        }
    }

    private static func test_hostPageNavigationIsTracked() -> String? {
        withScratchEnv {
            let (_, shell, keyStore, snippetStore) = makeMountedShell()
            shell.show(.console)

            let hostID = UUID()
            let hostConsole = ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false)
            shell.debugSeedHostConsole(hostConsole, hostID: hostID)
            shell.sessions.register(hostID: hostID, label: "DEV Bastion", accentHex: "#e8a23d")
            shell.switchToSession(hostID: hostID)
            guard shell.activeHostIDForTests == hostID else { return "switchToSession did not reveal the seeded host page" }

            // Console must now be recorded first (it was left for the host
            // page) - a real launch navigation (Home/Bootstrap) may trail it,
            // per `test_shellNavigationBuildsRecentsExcludingCurrent`'s own
            // note on why this only checks the leading entry.
            guard shell.recentDestinations.entries.first?.kind.title == "Console" else {
                return "leaving Console for a host page did not record it: \(shell.recentDestinations.entries.map(\.kind.title))"
            }

            // Leaving the host page for a rail destination records the host
            // page by its label, under a `host:<uuid>` identity.
            shell.show(.docs)
            guard let hostEntry = shell.recentDestinations.entries.first(where: { $0.kind.title == "DEV Bastion" }) else {
                return "the host page was not recorded after leaving it: \(shell.recentDestinations.entries.map(\.kind.title))"
            }
            guard hostEntry.kind.identityKey == "host:\(hostID.uuidString)" else {
                return "host entry identity is wrong: \(hostEntry.kind.identityKey)"
            }
            guard hostEntry.kind.kicker == "Hosts" else { return "host entry kicker is \(hostEntry.kind.kicker), expected Hosts" }
            // Docs (now current) must not appear in its own list.
            guard !shell.recentDestinations.entries.contains(where: { $0.kind.title == "Docs" }) else {
                return "the currently-showing destination (Docs) appeared in Recents"
            }
            return nil
        }
    }

    // MARK: Popover panel - real rows, real click

    private static func test_panelRendersRowsAndClickNavigates() -> String? {
        let registry = RecentDestinations()
        registry.recordNavigation(leaving: nil, arriving: .rail(.console))
        registry.recordNavigation(leaving: .rail(.console), arriving: .rail(.updates))
        registry.recordNavigation(leaving: .rail(.updates), arriving: .rail(.stickyBoard))

        var selected: [RecentDestinationKind] = []
        let controller = RecentDestinationsController()
        controller.configure(registry: registry) { kind in selected.append(kind) }

        guard let panel = controller.debugPanelController as? RecentDestinationsPanelViewController else {
            return "debugPanelController is not a RecentDestinationsPanelViewController"
        }
        let rows = panel.debugRows()
        guard rows.count == 2 else { return "expected 2 rows (Updates, Console), got \(rows.count)" }
        guard panel.debugEmptyStateIsHidden else { return "empty state is showing while rows exist" }
        guard rows[0].debugTitle == "Updates", rows[1].debugTitle == "Console" else {
            return "row order/titles wrong: \(rows.map(\.debugTitle))"
        }
        guard rows[0].debugKickerText == "ENGINEERING" else {
            return "Updates row kicker is '\(rows[0].debugKickerText)', expected 'ENGINEERING'"
        }
        guard let chip = rows[0].debugChipText, !chip.isEmpty else {
            return "row has no relative-time chip"
        }

        // A real click on the first row must dispatch back through the
        // exact kind that row represents.
        rows[0].onClick?()
        guard selected.map(\.title) == ["Updates"] else {
            return "clicking the Updates row selected \(selected.map(\.title)) instead"
        }

        // A second registry change (a live navigation happening while the
        // popover is open) must re-render the real rows.
        registry.recordNavigation(leaving: .rail(.stickyBoard), arriving: .rail(.vault))
        guard panel.debugRows().count == 3 else {
            return "the panel did not re-render after the registry changed"
        }
        return nil
    }

    private static func test_panelShowsEmptyStateWithNothingRecorded() -> String? {
        let registry = RecentDestinations()
        let controller = RecentDestinationsController()
        controller.configure(registry: registry) { _ in }
        guard let panel = controller.debugPanelController as? RecentDestinationsPanelViewController else {
            return "debugPanelController is not a RecentDestinationsPanelViewController"
        }
        guard panel.debugRows().isEmpty else { return "rows exist with an empty registry" }
        guard !panel.debugEmptyStateIsHidden else { return "the empty state is hidden with nothing recorded" }
        return nil
    }

    // MARK: Bar placement + theming

    private static func test_barButtonSitsAfterThePillsBeforeSearch() -> String? {
        let bar = DaylightBarController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = bar
        bar.view.layoutSubtreeIfNeeded()

        let pills = bar.debugPills()
        guard !pills.isEmpty else { return "no pills built" }
        let lastPillMaxX = pills.map { $0.frame.maxX }.max() ?? 0
        let button = bar.recentDestinations.button
        let search = bar.debugSearchPill()

        guard button.frame.width > 1, button.frame.height > 1 else {
            return "the Recents button resolved a zero-size frame"
        }
        guard button.frame.minX >= lastPillMaxX - 0.5 else {
            return "the Recents button (minX=\(button.frame.minX)) starts before the space pills end (maxX=\(lastPillMaxX))"
        }
        guard button.frame.maxX <= search.frame.minX + 0.5 else {
            return "the Recents button (maxX=\(button.frame.maxX)) overlaps the search pill (minX=\(search.frame.minX))"
        }
        // The explicit captain correction: not next to the logo, i.e. not at
        // the bar's own leading inset.
        guard button.frame.minX > 40 else {
            return "the Recents button sits right at the bar's leading edge, next to the logo"
        }
        // AGENTS.md gotcha (13)/DaylightModuleSelfTest.checkBarDoesNotCapWindow
        // already owns the "no bar width constraint can cap the window"
        // guarantee - checked there straight off `loadView()`, before any real
        // layout pass has run, which is what keeps it from also tripping on
        // `NSTextField`'s own lazily-materialised intrinsic-size constraints
        // (a pre-existing, unrelated artifact this test's own real layout
        // pass would otherwise surface as a false positive). Not re-checked
        // here to avoid exactly that.
        return nil
    }

    private static func test_barButtonThemesAcrossLightAndDark() -> String? {
        let themes = [
            HelmTheme.allThemes.first { $0.mode == .light },
            HelmTheme.allThemes.first { $0.mode == .dark },
        ].compactMap { $0 }
        guard themes.count == 2 else { return "could not find one light and one dark real HelmTheme" }
        for theme in themes {
            ThemeManager.shared.setTheme(theme)
            let bar = DaylightBarController()
            bar.loadView()
            let button = bar.recentDestinations.button
            guard button.debugHasIcon else { return "\(theme.id): the Recents button's icon did not resolve" }
            guard button.debugIconBackground.layer?.backgroundColor != nil else {
                return "\(theme.id): the Recents button's icon square was never painted"
            }
        }
        return nil
    }

    // MARK: Source guard

    /// `updateRecentDestinations` (which calls `recordNavigation(leaving:`)
    /// is the one place a navigation is recorded - the property that makes
    /// this registry a single source of truth rather than a second, possibly-
    /// scattered notion of "where the captain has been". A behavioural check
    /// cannot see a second writer added elsewhere, so this reads the source.
    private static func test_recordNavigationIsTheOnlyWriter() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        var writers: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in files where name.hasSuffix(".swift") && name != "RecentDestinations.swift" {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name)) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.contains(".recordNavigation(leaving:") { writers.append(name) }
            }
        }
        guard writers == ["AppShellController.swift"] else {
            return "recordNavigation is called from \(writers) - expected only AppShellController.swift"
        }
        return nil
    }
}

#endif
