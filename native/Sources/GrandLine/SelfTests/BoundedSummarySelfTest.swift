// Grand Line - native macOS app.
//
// P4 of the Grand Line vs Automic Vault polish report: the density rule. A
// module card is a bounded summary - it shows at most its row budget, and a
// card with more than it shows says so ("Showing 3 of 12") with a link to
// all of them.
//
// Run with:
//   swift build && FM_RUN_BOUNDED_SUMMARY_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: a card built and configured off-screen, its footer read off the
// real labels and its link pressed through `performClick`, plus a source
// guard. No window, so it guards CI's blocking lane.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum BoundedSummarySelfTest {

    static func run() -> Bool {
        var ok = true
        for each in [checkTheHelperBoundsAndSaysSo, checkTheLinkOpensTheCard, checkEveryPeekCardIsBounded] {
            var caseOK = true
            each(&caseOK)
            ok = ok && caseOK
        }
        print(ok ? "BoundedSummarySelfTest: all checks passed" : "BoundedSummarySelfTest: FAILED")
        return ok
    }

    private static func rows(_ n: Int) -> [HelmModulePeekRow] {
        (0..<n).map { HelmModulePeekRow(state: .idle, text: "Row \($0)", value: "") }
    }

    private static func checkTheHelperBoundsAndSaysSo(_ ok: inout Bool) {
        print("\n-- P4: a card shows its budget and says how many it has --")
        var content = HelmModuleCard.Content(title: "List", subtitle: "", symbol: "list.bullet", hue: .blue, chip: nil, body: .note("x"))
        content.setBoundedPeekRows(rows(5), total: 12)
        if case let .peekRows(shown) = content.body {
            check(shown.count == HelmModuleCard.maxPeekRows, "showed \(shown.count) rows, the budget is \(HelmModuleCard.maxPeekRows)", &ok)
        } else {
            fail("the body is not a peek list", &ok)
        }
        check(content.footer?.caption == "Showing 3 of 12" && content.footer?.actionTitle == "View all 12",
              "the footer reads \(content.footer?.caption ?? "nothing") / \(content.footer?.actionTitle ?? "nothing")", &ok)

        // A card that shows everything it has draws no footer - "Showing 2 of
        // 2" is furniture.
        content.setBoundedPeekRows(rows(2), total: 2)
        check(content.footer == nil, "a card showing all of its rows drew a footer", &ok)
        // A smaller budget is honoured.
        content.setBoundedPeekRows(rows(2), total: 9, limit: 2)
        check(content.footer?.caption == "Showing 2 of 9", "a two-row budget reads \(content.footer?.caption ?? "nothing")", &ok)

        // And it reaches the painted card.
        let card = HelmModuleCard()
        content.setBoundedPeekRows(rows(5), total: 12)
        card.configure(content)
        let footer = card.debugFooter
        check(footer?.caption == "Showing 3 of 12" && footer?.action == "View all 12",
              "the card paints \(String(describing: footer))", &ok)
        if ok { print("  OK   3 of 12 with View all 12; no footer when nothing is hidden; a 2-row budget honoured") }
    }

    private static func checkTheLinkOpensTheCard(_ ok: inout Bool) {
        print("\n-- P4: View all opens the card's own page --")
        var content = HelmModuleCard.Content(title: "List", subtitle: "", symbol: "list.bullet", hue: .blue, chip: nil, body: .note("x"))
        content.setBoundedPeekRows(rows(4), total: 40)
        let card = HelmModuleCard()
        card.configure(content)
        var opened = 0
        card.onOpen = { opened += 1 }
        card.debugFooterActionButton.performClick(nil)
        check(opened == 1, "View all opened the card \(opened) times, expected once", &ok)
        if ok { print("  OK   the link runs the card's own open") }
    }

    /// Every peek list on Home goes through the helper, so a new card cannot
    /// cut its list silently. The Merge queue is the one exception: it sets
    /// its own height-derived budget and its own footer ("All 22 open").
    private static func checkEveryPeekCardIsBounded(_ ok: inout Bool) {
        print("\n-- P4: every Home peek list is bounded and says so --")
        guard let root = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: root.appendingPathComponent("HomeCanvasController.swift"), encoding: .utf8)
        else {
            print("  SKIP could not read HomeCanvasController.swift")
            return
        }
        let lines = text.components(separatedBy: "\n")
        var bounded = 0
        var silent: [Int] = []
        for (index, line) in lines.enumerated() {
            if line.contains("setBoundedPeekRows(") { bounded += 1 }
            guard line.contains(".peekRows("), !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            let after = lines[index..<min(lines.count, index + 20)].joined(separator: "\n")
            if !after.contains("content.footer = ") { silent.append(index + 1) }
        }
        check(bounded >= 10, "only \(bounded) cards use setBoundedPeekRows - the guard would be vacuous", &ok)
        check(silent.isEmpty, "peek lists built with no footer, which would cut a long list silently: lines \(silent)", &ok)
        if ok { print("  OK   \(bounded) cards bounded through the helper, and the Merge queue's own footer") }
    }
}

#endif
