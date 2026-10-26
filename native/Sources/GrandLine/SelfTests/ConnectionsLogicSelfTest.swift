// Grand Line - native macOS app.
//
// The Termius-style Hosts and Keys work (PR 1 of 3 of the captain's plan):
// its pure-logic half. The arithmetic and parsing the pages rely on, asserted
// without mounting a view, so it runs in CI's blocking headless lane.
//
//   - H9: how many tag chips fit the filter row beside the "+N" chip.
//   - H7: the card grid's column plan, and its pixel grid at 1x and 2x for a
//     half-point column (the case CI's 1x runner hits and a 2x Mac cannot).
//   - X2: "last connected" in words, and the recent row's order.
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
        for check in [checkTagChipFit, checkGridPlan, checkLastConnected, checkKeyWords] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "ConnectionsLogicSelfTest: all checks passed" : "ConnectionsLogicSelfTest: FAILED")
        return allOK
    }

    // MARK: H7

    private static func checkGridPlan(_ ok: inout Bool) {
        let minimum = HelmCardGrid.minimumCardWidth, gap = HelmCardGrid.spacing
        let exact = HelmCardGrid.plan(width: 3 * minimum + 2 * gap)
        check(exact.columns == 3 && abs(exact.cardWidth - minimum) < 0.001, "H7: three minimum cards fit exactly (\(exact))", &ok)
        check(HelmCardGrid.plan(width: 3 * minimum + 2 * gap - 1).columns == 2, "H7: a point short drops a column", &ok)
        check(HelmCardGrid.plan(width: 120).columns == 1, "H7: a narrow column still shows one card", &ok)
        // A half-point column, at 1x and 2x: every edge lands on a device pixel.
        let width: CGFloat = 1100.5 - 300
        let plan = HelmCardGrid.plan(width: width)
        for scale: CGFloat in [1, 2] {
            for column in 0..<plan.columns {
                let x = CGFloat(column) * (plan.cardWidth + gap)
                let aligned = HelmCardGrid.pixelAligned(x, scale: scale)
                check(abs(aligned * scale - (aligned * scale).rounded()) < 0.0001 && abs(aligned - x) <= 0.5 / scale + 0.0001,
                      "H7: column \(column) at \(scale)x lands at \(aligned) for \(x)", &ok)
            }
        }
        check(HelmCardGrid.pixelAligned(10.25, scale: 1) == 10 && HelmCardGrid.pixelAligned(10.25, scale: 2) == 10.5,
              "H7: the pixel grid rounds differently at 1x and 2x", &ok)
    }

    // MARK: X2

    private static func checkLastConnected(_ ok: inout Bool) {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        check(HostsController.lastConnectedText(now.addingTimeInterval(-20), now: now) == "Last connected just now",
              "X2: a connection seconds ago reads \(HostsController.lastConnectedText(now.addingTimeInterval(-20), now: now))", &ok)
        let hours = HostsController.lastConnectedText(now.addingTimeInterval(-2 * 3600), now: now)
        check(hours.hasPrefix("Last connected ") && hours.contains("2"), "X2: two hours ago reads \(hours)", &ok)
        var a = Host(label: "a", address: "a.example.test"); a.lastConnectedAt = now.addingTimeInterval(-50)
        var b = Host(label: "b", address: "b.example.test"); b.lastConnectedAt = now
        let c = Host(label: "c", address: "c.example.test")
        check(HostsController.recentHosts([a, c, b]).map(\.label) == ["b", "a"],
              "X2: the recent row is newest first and leaves out a host never connected", &ok)
        check(HostsController.recentHosts([a, b], limit: 1).map(\.label) == ["b"], "X2: the recent row honours its limit", &ok)
    }

    // MARK: K4

    private static func checkKeyWords(_ ok: inout Bool) {
        let short = HostsController.shortFingerprint("SHA256:abcdefghijklmnopqrstuvwxyz0123456789")
        check(short == "SHA256:abcdefghijkl\u{2026}", "K4: the short fingerprint is \(short)", &ok)
        check(HostsController.shortFingerprint("SHA256:abc") == "SHA256:abc", "K4: a short hash gains an ellipsis", &ok)
        check(HostsController.lastUsedText(nil) == "Never used", "K4: a key never used reads \(HostsController.lastUsedText(nil))", &ok)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        check(HostsController.lastUsedText(now.addingTimeInterval(-5), now: now) == "Used just now", "K4: a key used now reads otherwise", &ok)
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
