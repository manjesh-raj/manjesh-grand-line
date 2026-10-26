// Grand Line - native macOS app.
//
// R2-ARCH-04 of the second full review: the pages that draw two presentations
// keep the floating bar's in an extension file of its own.
//
// R2-ARCH-01 froze the floating bar as the classic layout, so the members only
// its presentation uses were moved, verbatim, out of each page's main file into
// `<Page>+Classic.swift`. The main file carries what the sidebar layout draws.
// A move like that undoes itself one convenient edit at a time, so this suite
// pins the new structure:
//
//   1. each `+Classic.swift` file exists, extends its page, says it is the
//      frozen floating bar's, and declares every member that was moved there,
//   2. none of those members is declared in the page's main file again,
//   3. the five pages where nothing moved still adopt the sidebar layout - their
//      classic presentation is built inside methods both layouts run (Fleet,
//      Bootstrap, Automation) or is the same views the sidebar layout re-parents
//      (Log Analyzer, Health), so there was no member that only it uses.
//
// Pure logic, no window: a source guard over the app's own files.
//
// Run with:
//   swift build && FM_RUN_CLASSIC_PRESENTATION_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum ClassicPresentationSelfTest {

    /// Each page whose classic-only members moved, and those members.
    static let moved: [(page: String, members: [String])] = [
        ("HostsController", ["activityRowID", "commandsRowID", "buildSidebar", "sidebarSymbol", "refreshSidebar",
                             "buildSidePanels", "currentDetail", "detail", "hostItem", "pinnedItem", "keyItem",
                             "snippetItem"]),
        ("CredentialVaultController", ["renderList"]),
        ("VaultController", ["rebuildSecretsStack", "reconcileSecretRows", "showSecretsState", "rebuildToolsStack",
                             "reconcileToolRows", "showToolsState", "addUnknownState", "addEmptyState",
                             "secretRowView", "secretRowActions", "toolRowView"]),
        ("NotebookController", ["buildToolbar"]),
        ("ShiftController", ["buildSidebar", "rebuildSidebarSections", "pickProjectFromSidebar"]),
        ("UpdatesController", ["buildStatsRow", "iconFor", "categoryTint", "card", "buildRow", "detailsTapped",
                               "checkTapped", "updateTapped", "installInBootstrapTapped", "runInTerminalTapped"]),
        ("GitHubSyncController", ["buildRow", "detailsTapped", "syncTapped"]),
    ]

    /// The pages R2-ARCH-04 names where no member is the classic layout's
    /// alone. See this file's header for why.
    static let unmoved = ["FleetController", "BootstrapController", "AutomationController", "LogAnalyzerController",
                          "HealthController"]

    static func run() -> Bool {
        var ok = true
        guard let dir = SelfTestSources.appSourceDirectory() else {
            fail("could not locate the app's sources - every check here would pass vacuously", &ok)
            return false
        }
        func read(_ name: String) -> String? {
            try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        /// Whether `text` declares a member called `name` at type level (four
        /// spaces in, so a local of the same name inside a method is not one),
        /// comments aside.
        func declares(_ text: String, _ name: String) -> Bool {
            let code = text.split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
            let pattern = #"(?m)^ {4}(?:@objc\s+)?(?:(?:private|fileprivate)\s+)?(?:static\s+)?(?:func|let|var)\s+"#
                + NSRegularExpression.escapedPattern(for: name) + #"\b"#
            return code.range(of: pattern, options: .regularExpression) != nil
        }

        var movedCount = 0
        for entry in moved {
            guard let main = read("\(entry.page).swift") else {
                fail("\(entry.page).swift is not readable", &ok)
                continue
            }
            guard let classic = read("\(entry.page)+Classic.swift") else {
                fail("R2-ARCH-04: \(entry.page)+Classic.swift is gone - the floating bar's presentation is back in the main file", &ok)
                continue
            }
            check(classic.contains("extension \(entry.page) {"),
                  "\(entry.page)+Classic.swift does not extend \(entry.page)", &ok)
            check(classic.contains("frozen by R2-ARCH-01"),
                  "\(entry.page)+Classic.swift no longer says it is the frozen floating bar's", &ok)
            for member in entry.members {
                movedCount += 1
                check(declares(classic, member), "R2-ARCH-04: \(entry.page)+Classic.swift no longer declares `\(member)`", &ok)
                check(!declares(main, member),
                      "R2-ARCH-04: `\(member)` is declared in \(entry.page).swift again - the floating bar's code belongs in +Classic", &ok)
            }
        }
        // The fixture's own power: the table really names members, so an
        // emptied list cannot pass.
        check(movedCount >= 40, "only \(movedCount) moved members are listed - the guard has lost its table", &ok)

        for page in unmoved {
            guard let main = read("\(page).swift") else {
                fail("\(page).swift is not readable", &ok)
                continue
            }
            check(main.contains("func adoptSidebarLayout()"),
                  "\(page) no longer adopts the sidebar layout - revisit whether its classic presentation can move now", &ok)
            check(read("\(page)+Classic.swift") == nil,
                  "\(page)+Classic.swift exists - add it to `moved` with what it holds", &ok)
        }
        print(ok ? "ClassicPresentationSelfTest: all checks passed (\(movedCount) moved members in \(moved.count) pages)"
                 : "ClassicPresentationSelfTest: FAILED")
        return ok
    }
}

#endif
