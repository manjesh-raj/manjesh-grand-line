// Grand Line - native macOS app.
//
// The 2026-11-17 UI/UX proposals the captain approved (S01, S02, S04 to S11),
// checked where a check can be made without a window. Each case names its
// proposal. The window-backed halves (geometry that needs a real layout pass
// in a real window) live in the existing window suites that already measure
// those pages.
//
// Run with `FM_RUN_UIUX_PROPOSALS_TESTS=1 .build/debug/GrandLine`.
//
// Pure logic: no window. Views are laid out on their own. Deliberately NOT in
// `NEEDS_SESSION`.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum UIUXProposalsSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        print("== UIUXProposalsSelfTest ==")
        var allOK = true
        let cases: [(String, (inout Bool) -> Void)] = [
            ("S11 one verdict per card", checkTheHealthCardHasOneVerdict),
        ]
        for (name, body) in cases {
            var ok = true
            autoreleasepool { body(&ok) }
            print("  \(ok ? "OK  " : "FAIL") \(name)")
            allOK = allOK && ok
        }
        print(allOK ? "UIUXProposalsSelfTest: all checks passed" : "UIUXProposalsSelfTest: FAILED")
        return allOK
    }

    // MARK: - S11

    /// The Home Health card with one failing service: the title says
    /// "1 failing" in the failing colour, the arc takes the same colour, and
    /// there is no header pill saying it a third time. An all-healthy card
    /// keeps the card's own hue and ink title.
    private static func checkTheHealthCardHasOneVerdict(_ ok: inout Bool) {
        func state(_ bucket: ServiceHealthSummary.Bucket) -> ServiceHealthState {
            var s = ServiceHealthState()
            switch bucket {
            case .healthy: s.lastSuccess = Date()
            case .degraded: s.lastSuccess = Date(); s.lastFailure = Date(); s.consecutiveFailures = 1
                s.lastFailureDetail = "x"
            case .failing: s.lastFailure = Date(); s.consecutiveFailures = ServiceHealthRegistry.failureThreshold
                s.lastFailureDetail = "x"
            case .notRun: break
            }
            return s
        }
        let failing = ServiceHealthSummary([
            .init(service: .backgroundSignals, state: state(.healthy)),
            .init(service: .persistence, state: state(.healthy)),
            .init(service: .docsSync, state: state(.failing)),
            .init(service: .scheduledAutomations, state: state(.notRun)),
        ])
        guard failing.failing == 1, failing.healthy == 2, failing.notRun == 1 else {
            fail("S11: the fixture does not hold 2 healthy, 1 failing, 1 not run (\(failing.spoken))", &ok)
            return
        }
        check(failing.headline == .failing, "S11: the headline of a summary with a failure is failing", &ok)

        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            let summary = HomeCanvasController.healthRingSummary(failing)
            let card = HelmModuleCard()
            card.configure(.init(title: "Health", subtitle: "background services", symbol: "heart.fill", hue: .green,
                                 body: .ring(value: summary.value, total: summary.total, title: summary.title,
                                             note: summary.note, tint: summary.tint)))
            card.frame = NSRect(x: 0, y: 0, width: 380, height: 230)
            card.applyTheme(theme)
            card.layoutSubtreeIfNeeded()
            let critical = HelmTheme.nsColor(HelmTint.critical.hex(in: theme))
            let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let expectedTitle = HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                                               over: surface, theme: theme)
            guard let title = card.debugRingTitle, let arc = card.debugRingGauge?.debugArcColor else {
                fail("S11 \(theme.id): the ring has no tinted title or arc", &ok)
                continue
            }
            check(title.text == "1 failing", "S11 \(theme.id): the title is the verdict, got \"\(title.text)\"", &ok)
            check(title.color.map { same($0, expectedTitle) } == true,
                  "S11 \(theme.id): the title is painted in the failing colour", &ok)
            check(same(NSColor(cgColor: arc) ?? .clear, critical),
                  "S11 \(theme.id): the arc takes the failing colour, not the card's green", &ok)
            check(card.anatomyForTests.chipText == nil,
                  "S11 \(theme.id): no header pill repeats the verdict, got \"\(card.anatomyForTests.chipText ?? "")\"", &ok)

            // Discriminating power: an all-healthy card paints the card's
            // own green arc and an ink title, so the two readings really differ.
            let well = ServiceHealthSummary([.init(service: .persistence, state: state(.healthy))])
            let wellSummary = HomeCanvasController.healthRingSummary(well)
            let calm = HelmModuleCard()
            calm.configure(.init(title: "Health", subtitle: "background services", symbol: "heart.fill", hue: .green,
                                 body: .ring(value: wellSummary.value, total: wellSummary.total,
                                             title: wellSummary.title, note: wellSummary.note, tint: wellSummary.tint)))
            calm.applyTheme(theme)
            check(calm.debugRingTitle == nil && wellSummary.title == "Healthy",
                  "S11 \(theme.id): a healthy card keeps an ink title", &ok)
            let green = HelmDomainHue.green.baseColor(in: theme)
            check(calm.debugRingGauge?.debugArcColor.flatMap { NSColor(cgColor: $0) }.map { same($0, green) } == true,
                  "S11 \(theme.id): a healthy card keeps the card's green arc", &ok)
            check(!same(green, critical), "S11 \(theme.id): the fixture's two colours really differ", &ok)
        }
    }

    // MARK: - Helpers

    /// Element-wise colour equality (AGENTS.md: a contrast ratio is not a
    /// colour-equality check).
    static func same(_ a: NSColor, _ b: NSColor, tolerance: Double = 0.004) -> Bool {
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) <= tolerance && abs(x.1 - y.1) <= tolerance && abs(x.2 - y.2) <= tolerance
    }
}

#endif
