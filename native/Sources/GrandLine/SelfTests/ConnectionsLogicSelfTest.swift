// Grand Line - native macOS app.
//
// The Termius-style Hosts and Keys work (PR 1 of 3 of the captain's plan):
// its pure-logic half. The arithmetic and parsing the pages rely on, asserted
// without mounting a view, so it runs in CI's blocking headless lane.
//
//   - H9: how many tag chips fit the filter row beside the "+N" chip.
//
// The window-backed half is `ConnectionsCardsSelfTest`.
//
// Run with:
//   swift build && FM_RUN_CONNECTIONS_LOGIC_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ConnectionsLogicSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkTagChipFit] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ConnectionsLogicSelfTest: all checks passed" : "ConnectionsLogicSelfTest: FAILED")
        return allOK
    }

    // MARK: H9

    private static func checkTagChipFit(_ ok: inout Bool) {
        let widths: [CGFloat] = [40, 50, 60, 30]
        // 40 + 50 + 60 + 30 + 3 * 4 = 192.
        func fit(_ strip: CGFloat, shown: Bool) -> Int {
            HostsController.fittingTagCount(chipWidths: widths, spacing: 4, stripWidth: strip,
                                            overflowWidth: 28, overflowShown: shown)
        }
        check(fit(192, shown: false) == 4, "H9: every chip shows when they all fit exactly", &ok)
        check(fit(400, shown: false) == 4, "H9: every chip shows in a wide strip", &ok)
        // With "+N" showing, the strip is narrower by its width and a gap;
        // all four still fit once it goes, so it must go.
        check(fit(192 - 32, shown: true) == 4, "H9: the +N chip goes once the strip has room for every chip", &ok)
        // 191pt: the four do not fit, and beside a 28pt chip (and a gap)
        // only 159pt is left - 40 + 50 + 60 + 2 * 4 = 158 fits, the fourth does not.
        check(fit(191, shown: false) == 3, "H9: a strip one point short puts the last chip behind +N", &ok)
        check(fit(159, shown: true) == 3, "H9: the count is stable once +N is showing", &ok)
        check(fit(20, shown: false) == 0, "H9: a strip too narrow for any chip shows none rather than a cut one", &ok)
        check(HostsController.fittingTagCount(chipWidths: [], spacing: 4, stripWidth: 100,
                                              overflowWidth: 28, overflowShown: false) == 0,
              "H9: no tags fit as zero", &ok)
        // The vacuity guard: the fixture's widths really do need the overflow
        // at 191 and not at 192.
        check(widths.reduce(0, +) + 12 == 192, "H9: the fixture's chips span 192pt", &ok)
    }
}

#endif
