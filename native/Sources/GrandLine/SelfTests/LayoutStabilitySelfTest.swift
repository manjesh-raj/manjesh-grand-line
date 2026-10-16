// Grand Line - native macOS app.
//
// `fm/grandline-layout-breaks-refresh-reply`: two layout breaks the captain
// reported, and the backstop for the class one of them belongs to.
//
// Run with `FM_RUN_LAYOUT_STABILITY_TESTS=1 .build/debug/GrandLine`.
//
//   1. **Reply never widens the window.** The Fleet reply composer's
//      "Replying to ..." line carries the open decision's own note. As a
//      one-line label at the default 750 compression resistance it was a
//      required width floor under the page, above the 500 a window holds its
//      size at (AGENTS.md gotcha (13)), so opening Reply on the captain's
//      decision grew the window from 1512 to 1746pt and it never shrank back.
//      Asserted with the captain's own line and with an unbroken 600-character
//      URL: the window keeps its width, the shell's fitting width does not
//      grow, nothing reaches past the window, and the line wraps.
//   2. **A widened window does not outlive its page.** `WindowOverflowGuard`
//      puts back a window that content pushed past its screen, on the next
//      navigation. Asserted with a deliberately over-wide view, because the
//      composer no longer produces the state.
//   3. **Home holds its layout through a refresh.** Every Fleet refresh pushes
//      its snapshot with `mergedPRs: nil` before the PR scan lands. Home used
//      to show the Merge queue's three-row skeleton for that push, and the
//      Morning briefing stretched to absorb the column (139pt to 600pt at
//      1512x945). Asserted at 960x620, 1512x945 and 1920x1050: across the
//      interim push every column width, the page height and every card's
//      height are unchanged, and in a first launch's loading state (no reading
//      yet for the Merge queue, Claude or Fleet) the column widths and page
//      height hold and the briefing absorbs less than one skeleton row.
//
// **Why this suite is window-backed.** Every case reads resolved frames from
// the real `AppShellController` in a real (off-screen) window, and the first
// two need the window ordered in: AppKit only re-derives a window's frame
// from its content's constraints while it is on the window list, which is the
// growth case 1 must rule out and case 2 must produce. Listed in
// `NEEDS_SESSION` in `Scripts/run-all-tests.sh`. No run-loop pumps, posted
// events, modal alerts or drag sessions: every click is `performClick` and
// every state is read synchronously after `layoutSubtreeIfNeeded`.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum LayoutStabilitySelfTest {

    /// An unbroken line: no space anywhere a word wrap could use.
    static let unbrokenNote = "https://127.0.0.1:4387/session/"
        + String(repeating: "76371d2d67d88839", count: 36)

    @discardableResult
    static func run() -> Bool {
        var ok = true
        let savedTheme = ThemeManager.shared.theme
        let savedBriefing = AppSettings.shared.morningBriefingRecord
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-stability-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.morningBriefingRecord = savedBriefing
            FleetActions.stateDirectoryOverrideForTests = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        if let daylight = HelmTheme.theme(id: "daylight") { ThemeManager.shared.setTheme(daylight) }

        checkTheGuardArithmetic(&ok)
        autoreleasepool {
            let (window, shell) = ReviewTourLab.makeOffScreenShell()
            defer { window.orderOut(nil) }
            window.orderFront(nil)
            shell.show(.homeCanvas)
            ReviewTourLab.seedDemoHome(shell.debugHomeCanvas)
            ReviewTourLab.seedDemoBriefing()

            for note in [ReviewTourLab.demoDecisionNote, unbrokenNote] {
                for size in [NSSize(width: 960, height: 620), NSSize(width: 1512, height: 945)] {
                    checkReplyKeepsTheWindow(note: note, size: size, shell: shell, window: window,
                                             scratch: scratch, &ok)
                }
            }
            checkTheGuardRestoresAWidenedWindow(shell: shell, window: window, &ok)
            for size in HomeFitSelfTest.sizes {
                checkHomeHoldsThroughARefresh(size: size, shell: shell, window: window, &ok)
            }
        }

        print(ok ? "LayoutStabilitySelfTest: all checks passed" : "LayoutStabilitySelfTest: FAILED")
        return ok
    }

    private static func resize(_ window: NSWindow, to size: NSSize, shell: AppShellController) {
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: false)
        settle(window, shell)
    }

    /// The shell's layout pass and then the window's own. AppKit re-derives
    /// the window's frame from its content in the second one, so a suite that
    /// ran only the first would never see the window grow - measured: the
    /// over-wide fixture below left the window at 960pt until
    /// `window.layoutIfNeeded()` ran, and then it was 2000pt.
    private static func settle(_ window: NSWindow, _ shell: AppShellController) {
        shell.view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
    }

    // MARK: 1. Reply never widens the window

    private static func checkReplyKeepsTheWindow(note: String, size: NSSize, shell: AppShellController,
                                                 window: NSWindow, scratch: URL, _ ok: inout Bool) {
        let label = "\(Int(size.width))x\(Int(size.height)), \(note == unbrokenNote ? "unbroken URL" : "captain's line")"
        resize(window, to: size, shell: shell)
        shell.show(.overview)
        let fleet = shell.debugOverview
        ReviewTourLab.seedDemoDecision(fleet, scratch: scratch, note: note)
        settle(window, shell)
        let fittingBefore = shell.view.fittingSize.width

        guard let reply = fleet.debugReplyButton(taskID: ReviewTourLab.demoDecisionTaskID) else {
            fail("\(label): the parked decision has no Reply button", &ok)
            return
        }
        reply.performClick(nil)
        settle(window, shell)
        guard let composer = fleet.debugOpenReplyComposerView else {
            fail("\(label): Reply opened no composer", &ok)
            return
        }
        let address = composer.debugAddressLabel
        // The fixture's own power: on one line the address is wider than the
        // window, so a check that it stays inside could not pass by accident.
        let oneLineWidth = address.attributedStringValue.size().width
        check(oneLineWidth > size.width,
              "\(label): the address on one line is wider than the window (\(Int(oneLineWidth))pt)", &ok)

        check(abs(window.frame.width - size.width) < 0.5,
              "\(label): opening Reply keeps the window at \(Int(size.width))pt (got \(window.frame.width))", &ok)
        let fittingAfter = shell.view.fittingSize.width
        check(fittingAfter <= fittingBefore + 0.5,
              "\(label): the shell's fitting width does not grow (\(fittingBefore) -> \(fittingAfter))", &ok)
        let past = ReviewTourLab.viewsPastTheWindow(shell: shell, window: window)
        check(past.isEmpty, "\(label): nothing reaches past the window (\(past.first ?? ""))", &ok)

        let addressRect = address.convert(address.bounds, to: nil)
        let contentWidth = window.contentView?.frame.width ?? size.width
        check(addressRect.maxX <= contentWidth + 0.5,
              "\(label): the address ends inside the window (maxX \(addressRect.maxX))", &ok)
        let lineHeight = ceil((address.font ?? HelmType.caption()).boundingRectForFont.height)
        check(address.frame.height > lineHeight * 1.5,
              "\(label): the address wraps rather than truncating at one line (\(address.frame.height)pt)", &ok)
        check(address.frame.height <= lineHeight * CGFloat(FleetMessageComposer.addressMaxLines) + 4,
              "\(label): and stops at \(FleetMessageComposer.addressMaxLines) lines (\(address.frame.height)pt)", &ok)

        // The placeholder sits where the first typed glyph lands, not on the
        // card's border.
        let textView = composer.debugTextView
        let placeholder = composer.debugPlaceholderLabel
        // Auto Layout pins a text field's alignment rect, which is inset from
        // its frame by the cell's own padding, so that is where its glyphs
        // start - the thing that has to line up with a typed glyph.
        let alignment = placeholder.alignmentRect(forFrame: placeholder.frame)
        let origin = placeholder.superview?.convert(alignment, to: textView).origin ?? .zero
        let expectedX = textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 0)
        check(abs(origin.x - expectedX) < 1 && abs(origin.y - textView.textContainerInset.height) < 1,
              "\(label): the placeholder sits at the text's origin (\(origin.x), \(origin.y))", &ok)

        // Cancel: the same button, now titled Cancel.
        fleet.debugReplyButton(taskID: ReviewTourLab.demoDecisionTaskID)?.performClick(nil)
        settle(window, shell)
        check(fleet.debugOpenReplyTaskID == nil, "\(label): the second press closes the composer", &ok)
        check(abs(window.frame.width - size.width) < 0.5,
              "\(label): and the window is still \(Int(size.width))pt", &ok)
    }

    // MARK: 2. A widened window does not outlive its page

    private static func checkTheGuardArithmetic(_ ok: inout Bool) {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 945)
        check(!WindowOverflowGuard.overflows(NSRect(x: 0, y: 0, width: 1512.4, height: 900), visible: screen),
              "guard: a window as wide as its screen is not overflow", &ok)
        check(WindowOverflowGuard.overflows(NSRect(x: 0, y: 0, width: 1746, height: 900), visible: screen),
              "guard: a window wider than its screen is overflow", &ok)
        let back = WindowOverflowGuard.restoredFrame(current: NSRect(x: 100, y: 40, width: 1746, height: 900),
                                                     lastFitting: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                                     visible: screen)
        check(back == NSRect(x: 100, y: 40, width: 1200, height: 900),
              "guard: restores the last fitting width and keeps the current top-left and height (\(back))", &ok)
        let clamped = WindowOverflowGuard.restoredFrame(current: NSRect(x: 600, y: 40, width: 1746, height: 900),
                                                        lastFitting: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                                        visible: screen)
        check(clamped.maxX <= screen.maxX && clamped.width == 1200,
              "guard: moves a restored window left until it ends inside the screen (\(clamped))", &ok)
        let fallback = WindowOverflowGuard.restoredFrame(current: NSRect(x: 0, y: 40, width: 1746, height: 900),
                                                         lastFitting: nil, visible: screen)
        check(fallback.width == screen.width,
              "guard: with no fitting frame on record it restores the screen's width (\(fallback.width))", &ok)
    }

    private static func checkTheGuardRestoresAWidenedWindow(shell: AppShellController, window: NSWindow,
                                                           _ ok: inout Bool) {
        let guardrail = shell.windowOverflowGuard
        let savedVisible = guardrail.visibleFrame
        defer {
            guardrail.visibleFrame = savedVisible
            guardrail.disarmForTests()
        }
        // An `OffScreenProbe` window is on no screen, so the guard is handed a
        // 1512pt one at the window's own parked origin.
        guardrail.visibleFrame = { NSRect(x: $0.frame.minX, y: $0.frame.minY, width: 1512, height: 945) }
        check(!guardrail.isArmed, "guard: a shell a suite mounts does not arm the guard on its own", &ok)

        resize(window, to: NSSize(width: 1000, height: 620), shell: shell)
        resize(window, to: NSSize(width: 960, height: 620), shell: shell)
        guardrail.arm(for: window)
        shell.show(.overview)
        settle(window, shell)

        // A view that makes the same mistake the composer's label made: a
        // required width wider than the screen, inside the showing page.
        let wide = NSView()
        wide.translatesAutoresizingMaskIntoConstraints = false
        shell.debugOverview.view.addSubview(wide)
        NSLayoutConstraint.activate([
            wide.leadingAnchor.constraint(equalTo: shell.debugOverview.view.leadingAnchor),
            wide.topAnchor.constraint(equalTo: shell.debugOverview.view.topAnchor),
            wide.trailingAnchor.constraint(lessThanOrEqualTo: shell.debugOverview.view.trailingAnchor),
            wide.widthAnchor.constraint(equalToConstant: 2000),
            wide.heightAnchor.constraint(equalToConstant: 1),
        ])
        settle(window, shell)
        // The fixture's own power: AppKit really grew the window.
        check(window.frame.width >= 2000 - 0.5,
              "guard: the over-wide view grows the window, as the composer's label did (\(window.frame.width))", &ok)

        wide.removeFromSuperview()
        settle(window, shell)
        shell.show(.homeCanvas)
        settle(window, shell)
        check(abs(window.frame.width - 960) < 0.5,
              "guard: navigating away puts the window back at its last fitting 960pt (got \(window.frame.width))", &ok)
    }

    // MARK: 3. Home holds its layout through a refresh

    private struct HomeLayout {
        var columns: [CGFloat]
        var documentHeight: CGFloat
        var cards: [String: CGFloat]
    }

    private static func homeLayout(_ canvas: HomeCanvasController) -> HomeLayout {
        let columns = canvas.gridRowsForTests.first?.arrangedSubviews.map(\.frame.width) ?? []
        var cards: [String: CGFloat] = [:]
        for card in canvas.moduleCardsForTests { cards[card.debugHeaderText.title] = card.frame.height }
        return HomeLayout(columns: columns, documentHeight: canvas.documentHeightForTests, cards: cards)
    }

    private static func sameColumns(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        a.count == 3 && a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.5 }
    }

    private static func card(_ title: String, in canvas: HomeCanvasController) -> HelmModuleCard? {
        canvas.moduleCardsForTests.first { $0.debugHeaderText.title == title }
    }

    private static func checkHomeHoldsThroughARefresh(size: NSSize, shell: AppShellController, window: NSWindow,
                                                     _ ok: inout Bool) {
        let label = "\(Int(size.width))x\(Int(size.height))"
        let canvas = shell.debugHomeCanvas
        shell.show(.homeCanvas)
        ReviewTourLab.seedDemoHome(canvas)
        HomeFitSelfTest.show(rows: 3, at: size, shell: shell, window: window)
        let loaded = homeLayout(canvas)
        // What the briefing already absorbs with every reading in: at 1920
        // the Merge queue reaches its row cap and the briefing takes the rest
        // by design. A loading state may not add a row's worth to that.
        let loadedAbsorbed = card("Morning briefing", in: canvas)
            .map { $0.frame.height - $0.fittingSize.height } ?? 0
        guard canvas.usesDashboardLayoutForTests, loaded.columns.count == 3,
              let snapshot = canvas.debugFleetSnapshot else {
            fail("\(label): Home is not on its three-column page (\(loaded.columns))", &ok)
            return
        }

        // The interim push every real refresh makes.
        canvas.debugInputsPinned = false
        canvas.applyFleet(snapshot: snapshot, mergedPRs: nil, prFetchFailure: nil)
        canvas.debugInputsPinned = true
        settle(window, shell)
        let refreshing = homeLayout(canvas)
        check(sameColumns(refreshing.columns, loaded.columns),
              "\(label) refresh: the columns keep their widths (\(loaded.columns) -> \(refreshing.columns))", &ok)
        check(abs(refreshing.documentHeight - loaded.documentHeight) < 0.5,
              "\(label) refresh: the page keeps its height (\(loaded.documentHeight) -> \(refreshing.documentHeight))", &ok)
        for (title, height) in loaded.cards {
            let now = refreshing.cards[title] ?? -1
            check(abs(now - height) < 0.5, "\(label) refresh: \(title) keeps its height (\(height) -> \(now))", &ok)
        }
        check(card("Merge queue", in: canvas)?.debugHeaderText.subtitle != "reading",
              "\(label) refresh: the Merge queue keeps its last list rather than a skeleton", &ok)

        // A first launch: no reading yet for each loading card in turn, then
        // all three at once.
        for cards in [["merge"], ["claude"], ["fleet"], ["merge", "claude", "fleet"]] {
            let name = cards.joined(separator: "+")
            ReviewTourLab.seedDemoHome(canvas)
            canvas.debugRenderNow()
            settle(window, shell)
            for card in cards { canvas.debugForgetReading(card) }
            settle(window, shell)
            let loading = homeLayout(canvas)
            check(sameColumns(loading.columns, loaded.columns),
                  "\(label) loading \(name): the columns keep their widths (\(loading.columns))", &ok)
            check(abs(loading.documentHeight - loaded.documentHeight) < 0.5,
                  "\(label) loading \(name): the page keeps its height (\(loading.documentHeight))", &ok)
            if let briefing = card("Morning briefing", in: canvas) {
                let absorbed = briefing.frame.height - briefing.fittingSize.height
                check(absorbed < loadedAbsorbed + 60,
                      "\(label) loading \(name): the briefing absorbs less than a row more than loaded "
                      + "(\(absorbed)pt against \(loadedAbsorbed)pt)", &ok)
            } else {
                fail("\(label) loading \(name): no Morning briefing card", &ok)
            }
        }
        ReviewTourLab.seedDemoHome(canvas)
        canvas.debugRenderNow()
        settle(window, shell)
    }
}

#endif
