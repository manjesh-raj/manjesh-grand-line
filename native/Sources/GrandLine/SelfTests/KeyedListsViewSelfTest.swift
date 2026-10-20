// Grand Line - native macOS app.
//
// PERF-05 of the 2026-10 end-to-end review (section 3.6): the lists that
// grow with the captain's data refresh in place.
//
// Four places emptied a stack and rebuilt every row on each refresh: the
// Command Library's left column, the Reading List grid, the Vault page's
// secrets and launchers, and the Hosts page's tag strip (the host list
// itself is an `NSTableView` that already reuses its cells). Each now
// reconciles through `HelmKeyedRows`. The property that proves it is
// **identity**: after a refresh that changed nothing, the very same row
// objects are on screen - not equal copies - and after one that changed one
// item, every other row is still the same object. Each case also asserts the
// rendered text is unchanged, because the brief was "without changing what
// the captain sees".
//
// Window-backed: every case reads real arranged subviews after a real layout
// pass in an `OffScreenProbe` window.
//
// Run with:
//   swift build && FM_RUN_KEYED_LISTS_VIEW_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum KeyedListsViewSelfTest {

    static func run() -> Bool {
        var ok = true
        checkTheCommandLibraryColumnKeepsItsRows(&ok)
        checkTheReadingListGridKeepsItsCards(&ok)
        checkTheVaultListsKeepTheirRows(&ok)
        checkTheHostsTagStripKeepsItsChips(&ok)
        print("KeyedListsViewSelfTest: \(ok ? "all checks passed" : "FAILED")")
        return ok
    }

    private static func ids(_ views: [NSView]) -> [ObjectIdentifier] { views.map(ObjectIdentifier.init) }

    /// Every label's text under `view`, joined - what the row reads as.
    private static func text(_ view: NSView) -> String {
        var fields: [String] = []
        var queue: [NSView] = [view]
        while let next = queue.popLast() {
            if let field = next as? NSTextField { fields.append(field.stringValue) }
            queue.append(contentsOf: next.subviews)
        }
        return fields.joined(separator: " ")
    }

    /// A scratch directory, with `key` (when given) pointing at `path(dir)`
    /// for the duration - so no store here reaches the captain's own files.
    private static func withScratchEnv<T>(_ key: String, path: (URL) -> String = { $0.path },
                                          _ body: (URL) -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyed-lists-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, path(dir), 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        return body(dir)
    }

    private static func mount(_ view: NSView, width: CGFloat = 1200, height: CGFloat = 900) -> NSWindow {
        let window = OffScreenProbe.window(width: width, height: height, styleMask: [.titled, .resizable])
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: Command Library

    /// Injection: put the old teardown back in `renderLeftPanel` (empty the
    /// stack before reconciling) and every row is a new object.
    private static func checkTheCommandLibraryColumnKeepsItsRows(_ ok: inout Bool) {
        withScratchEnv("FM_COMMAND_LIBRARY_DIR") { _ in
            autoreleasepool {
                let store = CommandLibraryStore()
                let page = CommandLibraryPageView(store: store)
                let window = mount(page.view)
                defer { window.orderOut(nil) }
                page.debugRender()
                let before = ids(page.debugLeftPanelViews)
                let lines = page.debugLeftPanelContents().lines
                check(before.count > 5, "PERF-05: the seeded library should fill the column, got \(before.count) views", &ok)

                let passes = page.debugLeftPanelPasses
                page.debugRender()
                check(page.debugLeftPanelPasses == passes + 1,
                      "PERF-05: one render walked the column \(page.debugLeftPanelPasses - passes) times, expected once", &ok)
                check(ids(page.debugLeftPanelViews) == before,
                      "PERF-05: an unchanged render replaced the Command Library's rows", &ok)
                check(page.debugLeftPanelContents().lines == lines,
                      "PERF-05: an unchanged render changed what the column shows", &ok)

                // Selecting a command restyles one row; every row stays.
                if let first = store.commands.first {
                    page.debugSelectCommand(id: first.id)
                    let after = Set(ids(page.debugLeftPanelViews))
                    check(Set(before).isSubset(of: after),
                          "PERF-05: selecting a command rebuilt rows it did not change", &ok)
                } else {
                    fail("PERF-05: the seeded library has no commands to select", &ok)
                }
            }
        }
    }

    // MARK: Reading List

    /// Injection: empty `gridStack` before reconciling and every card is new.
    private static func checkTheReadingListGridKeepsItsCards(_ ok: inout Bool) {
        withScratchEnv("FM_READING_LIST_DIR") { dir in
            autoreleasepool {
                let store = ReadingListStore(root: dir)
                for index in 1...6 { _ = store.add("https://example.com/article-\(index)") }
                let controller = ReadingListController(store: store)
                let window = mount(controller.view)
                defer { window.orderOut(nil) }
                controller.debugReload()
                controller.view.layoutSubtreeIfNeeded()
                let before = ids(controller.debugCards)
                check(before.count == 6, "PERF-05: the fixture should show 6 cards, got \(before.count)", &ok)

                controller.debugReload()
                check(ids(controller.debugCards) == before,
                      "PERF-05: an unchanged reload replaced the Reading List's cards", &ok)

                // Marking one link read changes that card's content only.
                if let link = store.links.first, let card = controller.debugCard(link.id) {
                    let pillBefore = card.debugStatePillText
                    _ = store.setRead(id: link.id, read: true)
                    controller.debugReload()
                    check(Set(ids(controller.debugCards)) == Set(before),
                          "PERF-05: marking one link read rebuilt the grid's cards", &ok)
                    check(controller.debugCard(link.id) === card && card.debugStatePillText != pillBefore,
                          "PERF-05: the kept card did not show the link's new read state "
                              + "(pill \"\(pillBefore)\" -> \"\(card.debugStatePillText)\")", &ok)
                }
            }
        }
    }

    // MARK: Vault

    /// Injection: empty the stacks before reconciling and every row is new.
    private static func checkTheVaultListsKeepTheirRows(_ ok: inout Bool) {
        autoreleasepool {
            let controller = VaultController()
            let window = mount(controller.view)
            defer { window.orderOut(nil) }
            let secrets = ["GITHUB_TOKEN", "NPM_TOKEN", "AWS_PROFILE"].map(VaultSecret.init(name:))
            let tools = [VaultTool(name: "brew", commands: ["brew"], status: .hardened),
                         VaultTool(name: "gh", commands: ["gh"], status: .hardened)]
            controller.debugRender(secrets: secrets, tools: tools)
            let secretRows = ids(controller.debugSecretRows)
            let toolRows = ids(controller.debugToolRows)
            check(secretRows.count == 3 && toolRows.count == 2,
                  "PERF-05: the fixture should show 3 secrets and 2 launchers", &ok)

            controller.debugRender(secrets: secrets, tools: tools)
            check(ids(controller.debugSecretRows) == secretRows && ids(controller.debugToolRows) == toolRows,
                  "PERF-05: an unchanged snapshot replaced the Vault page's rows", &ok)

            // One launcher starts needing attention: its row is reconfigured,
            // the other stays, and a new secret adds exactly one row.
            controller.debugRender(secrets: secrets + [VaultSecret(name: "OPENAI_KEY")],
                                   tools: [tools[0], VaultTool(name: "gh", commands: ["gh"],
                                                               status: .needsAttention(issueCount: 2))])
            check(ids(controller.debugToolRows) == toolRows,
                  "PERF-05: a launcher's status change rebuilt the launcher rows", &ok)
            check(Array(ids(controller.debugSecretRows).prefix(3)) == secretRows
                    && controller.debugSecretRows.count == 4,
                  "PERF-05: one new secret should add one row and keep the other three", &ok)
            check(controller.debugToolRows.last.map { text($0).lowercased().contains("needs attention") } == true,
                  "PERF-05: the kept launcher row did not show its new status", &ok)

            // And back to a state view: the keyed rows leave cleanly.
            controller.debugRender(secrets: [], tools: [])
            check(controller.debugSecretRows.isEmpty && controller.debugSecretsPlaceholderText != nil,
                  "PERF-05: an empty snapshot should show the empty state and no rows", &ok)
        }
    }

    // MARK: Hosts

    /// Injection: empty `tagsStack` before reconciling and every chip is new.
    private static func checkTheHostsTagStripKeepsItsChips(_ ok: inout Bool) {
        withScratchEnv("FM_HOSTS_FILE", path: { $0.appendingPathComponent("hosts.json").path }) { _ in
            autoreleasepool {
                let hostStore = HostStore()
                hostStore.add(Host(label: "bastion", address: "198.51.100.1", tags: ["prod", "edge"]))
                hostStore.add(Host(label: "db", address: "198.51.100.2", tags: ["prod"]))
                let controller = HostsController(hostStore: hostStore, keyStore: SSHKeyStore(),
                                                 snippetStore: SnippetStore())
                let window = mount(controller.view)
                defer { window.orderOut(nil) }
                let before = ids(controller.debugTagChips)
                check(before.count == 2, "PERF-05: the fixture should show 2 tag chips, got \(before.count)", &ok)

                // A host edit that adds no tag reloads the page and keeps
                // every chip; one that adds a tag adds exactly one.
                hostStore.add(Host(label: "cache", address: "198.51.100.3", tags: ["edge"]))
                check(ids(controller.debugTagChips) == before,
                      "PERF-05: a host save that added no tag replaced the tag chips", &ok)
                hostStore.add(Host(label: "ci", address: "198.51.100.4", tags: ["staging"]))
                let after = ids(controller.debugTagChips)
                check(after.count == 3 && Set(before).isSubset(of: Set(after)),
                      "PERF-05: a new tag should add one chip and keep the others", &ok)
            }
        }
    }
}

#endif
