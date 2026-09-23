// Manjesh Grand Line - native macOS app.
//
// The window-backed half of F21 and F24: the two Settings cards, mounted in a
// real `NSWindow` and read back out of the live view hierarchy.
//
// **Window-backed, and listed in `NEEDS_SESSION`** - it mounts a real
// `SettingsController` (a real `NSScrollView`, real `HelmCard`s, real
// `HoverHighlightView` rows) and measures rendered geometry, which needs a
// window server. The logic halves - `AppIntentActionsSelfTest` and
// `BackupStoreSectionsSelfTest` - are pure and deliberately *not* listed, so
// they guard CI's blocking job (AGENTS.md's "Writing a self-test").
//
// What it is actually for. The two cards' content is generated: F21's rows
// come from `GrandLineIntentCatalog`, F24's from `BackupStoreSection.allCases`
// plus a live measurement. A model-level test of either would pass while the
// card rendered nothing - AGENTS.md's "assert what is painted, not what was
// computed" - so every assertion here walks the mounted hierarchy and reads
// the strings and frames that are really there.
//
// Two geometry claims are worth the window on their own:
//
//   - **Gotcha (13).** Both cards add rows with a trailing control pinned to
//     the row's own edge. A constraint above priority 500 on any of that would
//     cap the whole app window, on every page - the defect that shipped once
//     as a 1410pt cap and read to the captain as "the window doesn't cover the
//     screen". So the page is resized and asserted to follow.
//   - **Gotcha (10)/(12).** `descRow(alignsTrailingToEdge:)` is what makes the
//     five "guarded"/"action" controls line up in one column instead of at
//     five different x positions. That is invisible in a diff and obvious in a
//     render, so it is measured.
//
// `FM_RUN_INTENTS_BACKUP_VIEW_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum IntentsBackupSettingsViewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        // The suite mounts a real `SettingsController`, whose theme observer
        // reads `ThemeManager.shared.theme`. Save and restore it: AGENTS.md's
        // hermeticity note is that a suite leaving `fm.themeID` behind makes
        // every *later* suite in the run measure geometry under a theme nobody
        // selected. Nothing here calls `setTheme`, but capturing it is the
        // necessary condition `Phase3PolishSelfTest.checkSuitesRestoreTheTheme`
        // looks for, and it is cheap insurance against a later edit that does.
        let theme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(theme) }

        checkIntentsCardRendersEveryAction(check)
        checkGuardedChipIsOnCopyCredentialOnly(check)
        checkIntentRowsShareOneTrailingColumn(check)
        checkBackupCardListsEveryStore(check)
        checkBackupCardNamesTheExclusion(check)
        checkNeitherCardCapsTheWindow(check)

        print(ok ? "IntentsBackupSettingsViewSelfTest: OK" : "IntentsBackupSettingsViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Mounting

    /// Scratch store files, so nothing here reaches the captain's real data -
    /// the convention every store-backed suite here follows.
    private static func makeSettings() -> SettingsController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intents-backup-view-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_DICTATION_DIR", dir.appendingPathComponent("dictation").path, 1)
        return SettingsController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                                  snippetStore: SnippetStore(), dictationStore: DictationStore())
    }

    /// Mount the page and **select the category whose card the case is
    /// about**.
    ///
    /// `fm/grandline-settings-page-sidebar-redesign` made Settings a
    /// master/detail page: only the selected category's cards are in the view
    /// tree, and the other six are detached rather than hidden (gotcha (15)).
    /// So "walk the real hierarchy for this card" now has to say which pane
    /// it expects to find it in - which is a stronger claim than the old one,
    /// since it also asserts the card is reachable through the navigation.
    private static func withMountedSettings(_ category: SettingsController.Category,
                                            width: CGFloat = 1180,
                                            _ body: (SettingsController, NSWindow) -> Void) {
        // `autoreleasepool` is mandatory around AppKit construct/teardown in a
        // headless suite: nothing turns the run loop, so removed views are
        // never drained.
        autoreleasepool {
            let controller = makeSettings()
            // `OffScreenProbe.window`, never a hand-rolled `NSWindow` - a
            // hand-rolled one is not actually off-screen whatever origin it is
            // given, and these have been caught live on the captain's display.
            let window = OffScreenProbe.window(width: width, height: 1000)
            window.contentView = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
            controller.view.layoutSubtreeIfNeeded()
            controller.debugSidebar.debugClickRow(id: category.rawValue)
            controller.view.layoutSubtreeIfNeeded()
            body(controller, window)
            window.contentView = nil
        }
    }

    // MARK: Walking the real hierarchy

    /// Every `NSTextField` string in the mounted tree, which is what "what the
    /// card actually says" means here.
    private static func labels(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField { found.append(field.stringValue) }
        for subview in view.subviews { found.append(contentsOf: labels(in: subview)) }
        return found
    }

    /// The group card of the section headed `heading` on `category`'s page.
    ///
    /// **Was `card(titled:)`, a tree walk for a `HelmCard` carrying a header
    /// label.** `fm/grandline-settings-page-redesign` rebuilt the page to the
    /// captain's reference, where a page is a hero plus N sections and a
    /// section is a *heading beside* one header-less group card - so there is
    /// no titled card to find any more. The claims below are unchanged; only
    /// the way the card is reached is.
    private static func groupCard(_ controller: SettingsController,
                                  on category: SettingsController.Category,
                                  headed heading: String) -> HelmCard? {
        controller.debugSections(in: category)
            .first { $0.headingLabel?.stringValue == heading }?.group.card
    }

    /// The `SettingsRow`s of that same section, for a case that measures rows
    /// rather than reading their text.
    private static func rows(_ controller: SettingsController,
                             on category: SettingsController.Category,
                             headed heading: String) -> [SettingsRow] {
        controller.debugSections(in: category)
            .first { $0.headingLabel?.stringValue == heading }?.group.rows ?? []
    }

    // MARK: F21 - the intents card

    private static func checkIntentsCardRendersEveryAction(_ check: (Bool, String) -> Void) {
        withMountedSettings(.intents) { controller, _ in
            guard let card = groupCard(controller, on: .intents,
                                       headed: "Actions exposed to the system") else {
                check(false, "the intent list's group card is mounted on the Settings page")
                return
            }
            let text = labels(in: card)
            check(!GrandLineIntentCatalog.entries.isEmpty, "the catalogue is not empty - the loop below can fail")
            for entry in GrandLineIntentCatalog.entries {
                check(text.contains(entry.title), "the card renders a row for \u{201C}\(entry.title)\u{201D}")
                check(text.contains(entry.parameters),
                      "and states what \u{201C}\(entry.title)\u{201D} takes, rather than only naming it")
            }
            // GL-14: the card must say whether this copy actually publishes
            // its actions. An unbundled `swift build` binary - which is what a
            // suite runs - publishes none, so this is the branch under test.
            // The registration line is the section's own `foot` now, which
            // sits *below* the group card rather than inside it - so it is
            // read off the section rather than off `labels(in: card)`. The
            // claim is unchanged: this copy states what it really publishes.
            let sectionFoot = controller.debugSections(in: .intents)
                .compactMap { $0.footLabel?.stringValue }
            check(sectionFoot.contains(where: { $0.contains("unbundled") || $0.contains("Metadata.appintents") || $0.contains("Registered with the system") }),
                  "the card states this copy's real registration status rather than implying five live actions")
        }
    }

    private static func checkGuardedChipIsOnCopyCredentialOnly(_ check: (Bool, String) -> Void) {
        withMountedSettings(.intents) { controller, _ in
            guard let card = groupCard(controller, on: .intents,
                                       headed: "Actions exposed to the system") else {
                check(false, "the intent list's group card is mounted")
                return
            }
            let text = labels(in: card)
            let guardedCount = text.filter { $0 == "guarded" }.count
            check(guardedCount == 1, "exactly one row carries the \u{201C}guarded\u{201D} chip (got \(guardedCount))")
            check(text.contains("Copy Credential"), "and Copy Credential is on the card")

            // What the chip is *for*: the row has to say, in the card, that the
            // secret does not come back to the shortcut. A chip alone teaches
            // nobody anything.
            let copyRow = text.first { $0.contains("never returns the secret") }
            check(copyRow != nil, "the Copy Credential row states that the secret never reaches the shortcut")
            check(copyRow?.contains("vault's own unlock") == true,
                  "and that it goes through the vault's own unlock")
        }
    }

    /// Gotcha (10)/(12): with `.gravityAreas` and content-hugging priorities
    /// that are no-ops on a stack, five trailing controls land at five
    /// different x positions. `alignsTrailingToEdge` is what fixes it, and this
    /// is the only way to see that it did.
    private static func checkIntentRowsShareOneTrailingColumn(_ check: (Bool, String) -> Void) {
        withMountedSettings(.intents) { controller, _ in
            guard let card = groupCard(controller, on: .intents,
                                       headed: "Actions exposed to the system") else {
                check(false, "the intent list's group card is mounted")
                return
            }
            controller.view.layoutSubtreeIfNeeded()

            // **Measured off the rows themselves now, not off a tree walk.**
            // The walk this replaces looked for a `HoverHighlightView`
            // wrapping a two-subview horizontal stack, which is what the old
            // `descRow` built; a `SettingsRow` is a plain view whose row stack
            // holds two or three arranged subviews depending on whether it
            // carries a leading tile. Asking the row for its own `control` is
            // both simpler and immune to that shape changing again.
            let intentRows = rows(controller, on: .intents, headed: "Actions exposed to the system")
            let rightEdges = intentRows.compactMap { row -> CGFloat? in
                guard row.control.frame.width > 0 else { return nil }
                let frame = row.control.convert(row.control.bounds, to: card)
                return (frame.maxX * 10).rounded() / 10
            }

            check(rightEdges.count == GrandLineIntentCatalog.entries.count,
                  "found one trailing control per intent row (got \(rightEdges.count) for \(GrandLineIntentCatalog.entries.count) rows)")
            guard let first = rightEdges.first else { return }
            let spread = (rightEdges.max() ?? first) - (rightEdges.min() ?? first)
            // Four points is a real tolerance rather than a fudge: the four
            // `NSTextField` trailings land on the row's edge exactly, and the
            // one layer-backed pill container sits about 2pt inside it - its
            // width comes from its own label's intrinsic size plus fixed
            // padding, which rounds differently from a bare label's. What
            // gotcha (10) actually produces here is a spread of *hundreds* of
            // points, because each trailing control sits wherever its own
            // description text happened to end - and these five descriptions
            // range from four words to two lines.
            check(spread < 4.0,
                  "every row's trailing control shares one right edge - spread \(spread)pt (gotcha (10) makes this hundreds)")
        }
    }

    // MARK: F24 - the backup card

    private static func checkBackupCardListsEveryStore(_ check: (Bool, String) -> Void) {
        withMountedSettings(.backup) { controller, _ in
            guard let card = groupCard(controller, on: .backup, headed: "What's in a backup") else {
                check(false, "the backup inventory's group card is mounted")
                return
            }
            let text = labels(in: card)
            check(!BackupStoreSection.allCases.isEmpty, "there are sections to look for")
            for section in BackupStoreSection.allCases {
                check(text.contains(section.title), "the card lists \u{201C}\(section.title)\u{201D}")
            }
            check(text.contains("Poneglyph vault"), "and the vault")
            check(text.contains("Hosts, SSH keys, jump hosts"), "and the sections that were always in the bundle")

            check(text.contains("Sealed"), "the vault is chipped as sealed rather than as ordinary content")

            // The vault row's detail is generated from a live measurement, and
            // this suite mounts Settings on its own - no `AppShellController`,
            // so `GrandLineServices` has no registered stores. That is exactly
            // the state GL-14 is about, and the assertion is that the row says
            // so instead of inventing a number: an unmeasured store must never
            // render as an empty one.
            let honestStates = ["Not available until the app has finished starting up.",
                                "Measuring\u{2026}",
                                "No vault on this Mac yet."]
            let vaultDetail = text.first { detail in honestStates.contains { detail.hasPrefix($0) } || detail.contains("master password it had on the machine") }
            check(vaultDetail != nil,
                  "the vault row states a real status - unmeasured, absent, or a real count - never a fabricated zero")

            // The same rule for the four file-backed rows.
            for section in BackupStoreSection.allCases {
                let detail = text.first { $0.hasPrefix(section.detail) }
                check(detail != nil, "\u{201C}\(section.title)\u{201D} states what travels with it")
            }
        }
    }

    /// The mockup's own closing note: a one-file move is only trustworthy if
    /// you can see what it leaves behind. So the exclusion is a rendered row,
    /// not an omission.
    private static func checkBackupCardNamesTheExclusion(_ check: (Bool, String) -> Void) {
        withMountedSettings(.backup) { controller, _ in
            guard let card = groupCard(controller, on: .backup, headed: "What's in a backup") else {
                check(false, "the backup inventory's group card is mounted")
                return
            }
            let text = labels(in: card)
            check(text.contains("Terminal scrollback & session state"),
                  "the deliberately-excluded store is a visible row, not a silent omission")
            check(text.contains("Excluded"), "and is labelled as excluded")
            check(text.contains(where: { $0.contains("Deliberately left out") }),
                  "and says it is deliberate, with the reason")
        }
    }

    // MARK: Gotcha (13)

    /// A required `<=` plus a >500 proportional constraint on the same view is
    /// a window-size cap, on every page carrying it. Both new cards add rows
    /// with pinned trailing controls, which is exactly the shape that shipped
    /// the 1410pt cap once.
    private static func checkNeitherCardCapsTheWindow(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let controller = makeSettings()
            let window = OffScreenProbe.window(width: 900, height: 800)
            window.contentView = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 800)
            controller.view.layoutSubtreeIfNeeded()

            // Discriminating power first: the page must genuinely be at 900
            // before growing it proves anything.
            check(controller.view.frame.width == 900, "the page starts at 900pt")

            // Both cards, one pane each - the page shows only the selected
            // category now, so "with both new cards mounted" means visiting
            // both rather than trusting one render.
            for category in [SettingsController.Category.intents, .backup] {
                controller.debugSidebar.debugClickRow(id: category.rawValue)
                controller.view.layoutSubtreeIfNeeded()
                for target in [1400.0, 1512.0] as [CGFloat] {
                    var frame = window.frame
                    frame.size.width = target
                    window.setFrame(frame, display: true)
                    controller.view.layoutSubtreeIfNeeded()
                    check(abs(window.contentView!.frame.width - target) < 2,
                          "the window holds \(Int(target))pt on the \(category.rawValue) pane (got \(window.contentView!.frame.width))")
                }
            }

            // And back down, which is the direction gotcha (14) found a stale
            // frame in.
            var shrunk = window.frame
            shrunk.size.width = 820
            window.setFrame(shrunk, display: true)
            controller.view.layoutSubtreeIfNeeded()
            check(abs(window.contentView!.frame.width - 820) < 2,
                  "and shrinks back to 820pt (got \(window.contentView!.frame.width))")

            window.contentView = nil
        }
    }
}

#endif
