// Manjesh Grand Line - native macOS app.
//
// The UI-section findings from `data/grandline-full-app-audit/report.md`
// (`fm/grandline-audit-ui-fixes`) that are small enough not to each want a
// suite of their own, one case per finding - the same shape
// `AuditUIFixesSelfTest.swift` established for the previous audit's Section 2.
//
//   1  the Shift menu-bar popover forces its own appearance, like every
//      other popover in the app
//   4a the incident popover does the same
//   4b the Kubernetes tables are the app's shared `HelmTableView`
//
// Findings 2 (the sticky-note timestamp's type floor) and 3 (keyboard and
// VoiceOver access to a note's position and size) live in
// `StickyBoardViewSelfTest` instead - that suite already owns the real
// window-backed Sticky Board harness those two need, and splitting a feature's
// coverage across two files by which audit noticed it is how coverage rots.
//
// Run with:
//   swift build && FM_RUN_FULL_APP_AUDIT_UI_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// Window-backed (two of the three cases mount real controllers), so this sits
// in `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list.

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing a suite - `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum FullAppAuditUISelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("S1_shiftMenuBarPopoverFollowsTheActiveTheme", test_shiftMenuBarPopoverAppearance),
            ("S1_everyPopoverInTheAppForcesItsOwnAppearance", test_everyPopoverForcesAppearance),
            ("S4a_incidentPopoverFollowsTheActiveTheme", test_incidentPopoverAppearance),
            ("S4b_kubernetesTablesUseTheSharedTableComponent", test_kubernetesTables),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "FullAppAuditUISelfTest: all \(cases.count) cases passed"
              : "FullAppAuditUISelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A per-process scratch directory, so nothing here can reach the real
    /// git-synced clone of the captain's own config repo.
    private static func scratchDir(_ name: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-app-audit-ui-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// The name AppKit resolves an `NSAppearance` to, for a readable failure.
    private static func appearanceName(_ appearance: NSAppearance?) -> String {
        appearance.map { "\($0.name.rawValue)" } ?? "nil"
    }

    private static func expectedAppearance(for theme: HelmTheme) -> NSAppearance.Name {
        theme.mode == .dark ? .darkAqua : .aqua
    }

    /// One light theme and one dark theme, so a popover that happened to be
    /// right for the ambient mode cannot pass by luck.
    private static let sweptThemeIDs = ["helm-light", "helm-dark"]

    // MARK: 1 - the Shift menu-bar popover
    //
    // This was the ONE popover in the app that never set its own appearance.
    // Its content is deliberately plain `.labelColor` system-semantic text
    // (see `ShiftMenuBar.swift`), which resolves against the *OS's* light/dark
    // setting until the popover says otherwise - so on a Mac in system Dark
    // with a light Helm theme selected it rendered near-white text on AppKit's
    // own light vibrant material.
    //
    // Drives the real `prepareToShow()` - everything `iconClicked` does before
    // the popover is put on screen - rather than a reimplementation. It does
    // not call `NSPopover.show`: no suite in this codebase shows a real
    // popover headlessly, and the appearance is set before the show either
    // way, which is the whole contract.

    private static func test_shiftMenuBarPopoverAppearance() -> String? {
        setenv("FM_SHIFT_DIR", scratchDir("shift"), 1)
        // A real status item needs a real `NSApplication` - and `NSApp` is an
        // implicitly-unwrapped `NSApplication!` that is still nil until
        // `NSApplication.shared` has been touched at least once, so reach for
        // `.shared` here rather than `NSApp` (which every other suite in this
        // directory gets away with only because it builds an `NSWindow`
        // first).
        NSApplication.shared.setActivationPolicy(.accessory)

        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }

        let controller = ShiftMenuBarController(store: ShiftStore())

        // 1. Opening under each mode forces the matching appearance.
        for id in sweptThemeIDs {
            guard let theme = HelmTheme.theme(id: id) else { return "no HelmTheme registered for id \(id)" }
            ThemeManager.shared.setTheme(theme)
            controller.debugPrepareToShow()
            let want = expectedAppearance(for: theme)
            guard controller.debugPopover.appearance?.name == want else {
                return "\(id): the menu-bar popover should force \(want.rawValue), was "
                    + appearanceName(controller.debugPopover.appearance)
            }
        }

        // 2. ...and a theme toggled while it is already open reaches it too,
        // without a re-open. `prepareToShow()` is the open-time half; an
        // already-shown popover never goes back through it.
        for id in sweptThemeIDs.reversed() {
            guard let theme = HelmTheme.theme(id: id) else { return "no HelmTheme registered for id \(id)" }
            ThemeManager.shared.setTheme(theme)
            let want = expectedAppearance(for: theme)
            guard controller.debugPopover.appearance?.name == want else {
                return "\(id): toggling the theme with the popover already open should re-force "
                    + "\(want.rawValue), was \(appearanceName(controller.debugPopover.appearance))"
            }
        }
        return nil
    }

    // MARK: 1 + 4a - the general rule, as a source guard
    //
    // The behavioural cases above and below each pin one popover. This pins
    // the *rule*, which is what stops this review being needed a third time:
    // a file that owns an `NSPopover` must also force its appearance
    // somewhere. Every one of the app's eight popovers satisfies it today;
    // two of them only started to in `fm/grandline-audit-ui-fixes`.

    private static func test_everyPopoverForcesAppearance() -> String? {
        guard let files = SelfTestSources.appSourceFiles() else {
            return "could not locate the app's own source files - this check would silently pass"
        }
        var owners: [String] = []
        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                return "could not read \(file.lastPathComponent)"
            }
            // Code only: this file's own comments discuss the pattern.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            guard code.contains("NSPopover()") else { continue }
            let name = file.lastPathComponent
            owners.append(name)
            // The owning file, or - for `ConsoleController`'s six-file family
            // (GL-36) - any file in it, has to set the appearance.
            let family = name.hasPrefix("ConsoleController")
                ? files.filter { $0.lastPathComponent.hasPrefix("ConsoleController") }
                : [file]
            let familyText = family.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
            if !familyText.contains(".appearance = NSAppearance(named:") {
                offenders.append(name)
            }
        }
        guard owners.count >= 8 else {
            return "found only \(owners.count) files owning an NSPopover - has the app shrunk, or is "
                + "this check looking in the wrong place?"
        }
        guard offenders.isEmpty else {
            return "these popovers never force their own appearance, so their system-semantic "
                + "content follows the OS rather than the active theme: \(offenders.joined(separator: ", "))"
        }
        return nil
    }

    // MARK: 4a - the incident popover
    //
    // The card's own body was always right (`IncidentCardView` derives every
    // colour it paints from `theme`); what was not is everything AppKit
    // resolves semantically inside it. Driven through the real
    // `showIncidentCard()` on a real dedicated-host-page `ConsoleController`.

    private static func test_incidentPopoverAppearance() -> String? {
        setenv("FM_SHIFT_DIR", scratchDir("shift"), 1)
        setenv("FM_INCIDENTS_DIR", scratchDir("incidents"), 1)
        setenv("FM_KEYS_FILE", scratchDir("keys") + "/keys.json", 1)
        setenv("FM_SNIPPETS_FILE", scratchDir("snippets") + "/snippets.json", 1)

        let saved = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(saved) }

        let controller = ConsoleController(keyStore: SSHKeyStore(),
                                           snippetStore: SnippetStore(),
                                           isFirstmateConsole: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        // A dedicated host page is the only place incidents exist at all.
        controller.hostIdentity = ConsoleHostIdentity(id: "audit-bastion", label: "Audit Bastion")
        defer { controller.shutdown() }

        guard let button = controller.incidentButton, !button.isHidden else {
            return "a dedicated host page should show the incident toolbar button"
        }

        for id in sweptThemeIDs {
            guard let theme = HelmTheme.theme(id: id) else { return "no HelmTheme registered for id \(id)" }
            ThemeManager.shared.setTheme(theme)
            controller.showIncidentCard()
            let want = expectedAppearance(for: theme)
            guard controller.incidentPopover.appearance?.name == want else {
                return "\(id): the incident popover should force \(want.rawValue), was "
                    + appearanceName(controller.incidentPopover.appearance)
            }
            controller.incidentPopover.performClose(nil)
        }
        return nil
    }

    // MARK: 4b - the Kubernetes tables
    //
    // Both were built as bare `NSTableView()`s while the rest of the app's
    // lists are `HelmTableView` (GL-16's keyboard-activatable table). No
    // behaviour changes today - with no `doubleAction` wired, the subclass's
    // `keyDown` falls straight through - the point is that the newest code on
    // the page is not the one exception to the shared component.

    private static func test_kubernetesTables() -> String? {
        let resourceTable = KubeResourceTableView(frame: .zero)
        guard resourceTable.tableViewForTests is HelmTableView else {
            return "KubeResourceTableView still uses a bare NSTableView rather than the app's "
                + "shared HelmTableView"
        }
        let logTable = KubeLogListView(frame: .zero)
        guard logTable.tableViewForTests is HelmTableView else {
            return "KubeLogListView still uses a bare NSTableView rather than the app's shared "
                + "HelmTableView"
        }
        return nil
    }
}

#endif
