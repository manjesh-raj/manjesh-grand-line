// Grand Line - native macOS app.
//
// `HelmModuleCard`'s header keeps its status column where the design puts it:
// hard against the header's trailing control, exactly as wide as the chip and
// caption it is showing, and identical on every rebuild of the card.
//
// Run with `FM_RUN_MODULE_CARD_HEADER_TESTS=1 .build/debug/GrandLine`.
//
// **The defect this exists for.** The captain reported that the Home page's
// Claude widget moved its "Near spend cap" chip and its "Updated just now"
// caption sideways relative to the Refresh button every time he pressed
// Refresh - two screenshots taken seconds apart, the chip clear of the button
// in one and almost touching it in the other.
//
// The cause was in the shared component rather than in the Claude card's own
// content: the header's status column was a vertical `NSStackView`, and a
// vertical stack does not state its own *width* at a priority that holds. It
// tied with the text column beside it for the header's leftover width, and
// Auto Layout broke the tie on its own - gotcha (10)'s "can differ between
// rows and between runs with no code change". `HomeCanvasController.render`
// rebuilds every card, so the tie was re-rolled on every refresh. Measured on
// a 849.5pt Claude card: the column resolved **670pt** wide with its chip
// pinned to its leading edge, 575pt clear of Refresh, on most rebuilds, and
// **107pt** hard against Refresh on the rest. See `HelmModuleCard.buildChrome`
// for the fix.
//
// **Why this suite is window-backed.** Every case reads a resolved
// `NSView.frame` after a real layout pass in a real window, so it is listed in
// `NEEDS_SESSION` and guards CI's windowed lane.
//
// The two cases are deliberately different shapes, because they fail for
// different reasons:
//
//   1. **The component**, swept over four card widths and both caption
//      states. This is the invariant, and it is what a future header change
//      breaks first.
//   2. **The captain's own page**, driving the real Claude widget's own
//      Refresh over several cycles on a real `HomeCanvasController`. This is
//      the end-to-end reproduction, and it is the case that fails when the
//      component is right and the wiring that rebuilds the card is not.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum ModuleCardHeaderStabilitySelfTest {

    @discardableResult
    static func run() -> Bool {
        var ok = true
        checkTheStatusColumnHugsItsContent(&ok)
        checkTheClaudeWidgetDoesNotShiftAcrossRefreshes(&ok)

        if ok {
            print("ModuleCardHeaderStabilitySelfTest: all checks passed")
        } else {
            print("ModuleCardHeaderStabilitySelfTest: FAILED")
        }
        return ok
    }

    /// The header row's own spacing, which is the whole of the gap the chip
    /// is meant to leave before the trailing control.
    private static let headerSpacing = HelmMetrics.s3

    /// A point of slack for the backing store, per AGENTS.md's note that a
    /// runner is 1x and every dev Mac here is 2x.
    private static let tolerance: CGFloat = 1.0

    // MARK: 1 - the component

    private static func checkTheStatusColumnHugsItsContent(_ ok: inout Bool) {
        for width in [849.5, 602.5, 420.0, 320.0] as [CGFloat] {
            for withCaption in [true, false] {
                let label = "a \(Int(width))pt card "
                    + (withCaption ? "with a caption" : "with no caption")
                let window = OffScreenProbe.window(size: NSSize(width: width + 120, height: 320))
                defer { window.orderOut(nil) }
                let host = NSView()
                host.translatesAutoresizingMaskIntoConstraints = false
                window.contentView = host

                let card = HelmModuleCard()
                card.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(card)
                NSLayoutConstraint.activate([
                    card.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
                    card.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
                    card.widthAnchor.constraint(equalToConstant: width),
                ])
                card.configure(content(withCaption: withCaption))
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()

                guard let chip = card.debugChipFrameInCard,
                      let button = card.debugHeaderActionFrameInCard,
                      let header = card.debugHeaderGeometry else {
                    fail("\(label): the header did not build a chip, a caption column "
                            + "and a trailing control", &ok)
                    continue
                }

                // The fixture's own discriminating power first. The defect is
                // the header's leftover width landing in the status column
                // instead of the text column, so a header with no leftover
                // width to misplace could not fail either of the checks
                // below - which is exactly how a drifted fixture passes
                // vacuously.
                let slack = header.row.width - header.status.width - button.width
                check(slack > 100,
                      "\(label): the fixture has no slack to misplace - a \(fmt(header.row.width))pt "
                          + "header row against a \(fmt(header.status.width))pt status column and a "
                          + "\(fmt(button.width))pt control leaves only \(fmt(slack))pt, so this "
                          + "case cannot fail", &ok)

                // The defect, stated as geometry: the status column took the
                // header's leftover width instead of the text column.
                let widest = withCaption
                    ? max(chip.width, card.debugHeaderCaptionFrameInCard?.width ?? 0)
                    : chip.width
                check(abs(header.status.width - widest) <= tolerance,
                      "\(label): the status column should be exactly as wide as its widest "
                          + "member (\(fmt(widest))pt), got \(fmt(header.status.width))pt", &ok)

                // ...and what the captain actually saw: where the chip lands
                // relative to the button he was pressing.
                let gap = button.minX - chip.maxX
                check(abs(gap - headerSpacing) <= tolerance,
                      "\(label): the chip should sit \(fmt(headerSpacing))pt before the header "
                          + "action, got \(fmt(gap))pt", &ok)

                // The caption is *under* the chip and right-aligned with it,
                // which is the shape the mockup draws. Compared on the
                // alignment rects rather than the frames: an `NSTextField`'s
                // frame overhangs its alignment rect by ~2pt and the chip's
                // does not, so comparing frames measures the inset rather
                // than the alignment.
                if withCaption {
                    guard let caption = card.debugHeaderCaptionAlignmentRectInCard else {
                        fail("\(label): a caption was configured and none was painted", &ok)
                        continue
                    }
                    let captionRight = caption.maxX
                    check(abs(captionRight - chip.maxX) <= tolerance,
                          "\(label): the caption should be right-aligned with the chip "
                              + "(\(fmt(chip.maxX))pt), got \(fmt(captionRight))pt", &ok)
                    check(caption.minY < chip.minY || caption.maxY <= chip.minY + tolerance,
                          "\(label): the caption should sit under the chip, not beside it", &ok)
                }
            }
        }
    }

    private static func content(withCaption: Bool) -> HelmModuleCard.Content {
        var content = HelmModuleCard.Content(
            title: "Claude",
            subtitle: "Team plan, updated just now",
            symbol: "sparkles",
            hue: .violet,
            chip: .bad("Near spend cap"),
            body: .note("A body, so the card has something under its header.", maxLines: 2))
        content.headerCaption = withCaption ? "Updated just now" : nil
        content.headerAction = HelmModuleCard.HeaderAction(
            symbol: "arrow.clockwise", tooltip: "Refresh", isBusy: false, handler: {})
        return content
    }

    // MARK: 2 - the captain's own page

    /// Drive the real Claude widget's own Refresh on a real hub, and read the
    /// header back after every cycle.
    ///
    /// The refresh is a *rebuild*: `refreshQuotaTapped` coalesces a render
    /// onto the next main-queue turn and `applyQuota` renders again when the
    /// reading lands, and each render builds a brand-new `HelmModuleCard`.
    /// So this drives both halves - the busy state and the settled one - and
    /// then a passive re-render, which is the 30-second interval's path and
    /// goes through no button at all.
    private static func checkTheClaudeWidgetDoesNotShiftAcrossRefreshes(_ ok: inout Bool) {
        withScratchShift { store in
            let canvas = makeCanvas(store)
            let window = OffScreenProbe.window(size: NSSize(width: 1512, height: 1000),
                                               styleMask: [.titled, .resizable])
            defer { window.orderOut(nil) }
            window.contentView = canvas.view
            window.orderFront(nil)
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            // A second pass: the grid is built from the clip view's bounds,
            // which is only real after the first one.
            canvas.debugRenderNow()
            canvas.view.layoutSubtreeIfNeeded()
            canvas.applyQuota(.success(snapshot()))
            settle()

            var measured = 0
            func measure(_ label: String) {
                canvas.view.layoutSubtreeIfNeeded()
                guard let card = canvas.moduleCardsForTests
                        .first(where: { $0.debugHeaderText.title == "Claude" }) else {
                    fail("\(label): the hub has no Claude widget", &ok)
                    return
                }
                guard let chip = card.debugChipFrameInCard,
                      let button = card.debugHeaderActionFrameInCard else {
                    fail("\(label): the Claude widget's header lost its chip or its Refresh", &ok)
                    return
                }
                measured += 1
                let gap = button.minX - chip.maxX
                check(abs(gap - headerSpacing) <= tolerance,
                      "\(label): the \"\(card.debugHeaderText.chip ?? "")\" chip should sit "
                          + "\(fmt(headerSpacing))pt before Refresh, got \(fmt(gap))pt "
                          + "(chip at x=\(fmt(chip.minX)))", &ok)
            }

            measure("the first reading")
            for cycle in 1...4 {
                guard let card = canvas.moduleCardsForTests
                        .first(where: { $0.debugHeaderText.title == "Claude" }) else { break }
                check(card.debugActivateHeaderAction(),
                      "refresh #\(cycle): the Claude widget's Refresh should be clickable", &ok)
                settle()
                measure("refresh #\(cycle), reading")
                canvas.applyQuota(.success(snapshot()))
                settle()
                measure("refresh #\(cycle), settled")
            }
            // The auto-refresh interval's path: a render with no click at all.
            for pass in 1...2 {
                canvas.debugRenderNow()
                settle()
                measure("passive render #\(pass)")
            }

            // Discriminating power again: a case that silently measured
            // nothing would pass.
            check(measured >= 11,
                  "the case should have measured the header on every cycle, got \(measured)", &ok)
        }
    }

    /// Turn the main queue over, so a `setNeedsRender` coalesced onto it has
    /// actually run before anything is measured.
    private static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    }

    private static func snapshot() -> QuotaSnapshot {
        // `ClaudeStatusCardSelfTest`'s own live shape, which is what puts
        // "Near spend cap" in the chip - the captain's screenshot.
        QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 90, resetsAt: nil, pace: .ahead),
            weekly: QuotaWindow(kind: .weekly, percentUsed: 69, resetsAt: nil, pace: .ahead),
            fable: QuotaWindow(kind: .fable, percentUsed: 100, resetsAt: nil, pace: .ahead),
            extraUsage: QuotaCreditWindow(percentUsed: 98, spentUsd: 137.62, limitUsd: 140),
            latency: 1.4, log: "")
    }

    /// One `ShiftStore` per case, pointed at its own scratch directory - the
    /// arrangement `HomeDashboardViewSelfTest` documents, and for its reason.
    private static func withScratchShift(_ body: (ShiftStore) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-module-header-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            if let previous { setenv("FM_SHIFT_DIR", previous, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }

    private static func makeCanvas(_ shiftStore: ShiftStore) -> HomeCanvasController {
        var seeded = ShiftTask.fresh()
        seeded.title = "a task, so the hub is not in its first-run state"
        shiftStore.addTask(seeded)
        let canvas = HomeCanvasController(sources: .init(
            shiftStore: shiftStore,
            hostStore: HostStore(),
            scheduleStore: ScheduleStore(),
            logAnalyzerStore: LogAnalyzerStore(),
            docsRunbookStore: DocsRunbookStore(),
            codePreviewStore: CodePreviewStore(),
            notebookStore: NotebookStore(),
            readingListStore: ReadingListStore(),
            commandLibraryStore: CommandLibraryStore(),
            stickyBoardStore: StickyBoardStore()))
        _ = canvas.view
        return canvas
    }

    private static func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

#endif
