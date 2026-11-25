// Grand Line - native macOS app.
//
// The render half of the Needs Attention card, in a real off-screen window.
//
// Run with `FM_RUN_NEEDS_ATTENTION_VIEW_TESTS=1 .build/debug/GrandLine`.
//
// **Window-backed**, so it lives in `run-all-tests.sh`'s `NEEDS_SESSION` list:
// every case here measures a laid-out frame. `NeedsAttentionSelfTest` is the
// pure half and guards CI's blocking lane.
//
// **What is left after P-03.** The card was drawn only on the floating bar's
// hub, as its column 1, and P-03 of the 2026-11-25 full review removed that
// hub. Every case that mounted the card on Home went with it: what it
// painted from the injected `ShiftStore`, its wired checkbox and button, the
// all-clear state, the window-size cap, "the hub only", the revamp's recipe
// and the ticking subline. What remains builds the card on its own:
//
//   1. **A long row wraps** rather than truncating, and the card measures the
//      taller row.
//   2. **The list scrolls inside the card** when the card is given less
//      height than its rows need.
//   3. **A same-palette re-push keeps the rows.**

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit

enum NeedsAttentionViewSelfTest {

    @discardableResult
    static func run() -> Bool {
        var ok = true
        checkTheListScrollsInsideTheCard(&ok)
        checkASamePaletteRePushKeepsTheRows(&ok)
        checkALongRowWrapsInsteadOfTruncating(&ok)

        if ok {
            print("NeedsAttentionViewSelfTest: all checks passed")
        } else {
            print("NeedsAttentionViewSelfTest: FAILED")
        }
        return ok
    }

    // MARK: 1 - the list scrolls inside the card (`fm/grandline-home-fit-implement`)

    /// The real card, given less height than its rows need the way a page
    /// column gives it (a 499 tie, under the window's own 500), with the
    /// captain's ten-row worst case.
    /// R5-UI-03: the fleet row's line - "Fleet · Needs you · 1 decision
    /// waiting - the crew is holding for you." - rendered "the crew is
    /// holding f…" in the hub's column. It wraps now, and the card measures
    /// the taller row, so the list still ends at its last row.
    private static func checkALongRowWrapsInsteadOfTruncating(_ ok: inout Bool) {
        let window = OffScreenProbe.window(width: 700, height: 700, styleMask: [.titled, .resizable])
        defer { window.orderOut(nil) }
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = host
        window.orderFront(nil)
        let card = NeedsAttentionCard()
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.widthAnchor.constraint(equalToConstant: 470),
        ])
        card.setLayoutWidth(470)
        card.render(ReviewTourLab.demoAttentionSummary(count: 3), subline: "Fleet read just now.",
                    theme: ThemeManager.shared.theme)
        host.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()

        let rows = card.debugRows.compactMap { $0 as? NeedsAttentionRowView }
        guard rows.count == 3, let fleet = rows.last?.debugRow, let first = rows.first?.debugRow else {
            fail("the fixture should draw three attention rows, got \(card.debugRows.count)", &ok)
            return
        }
        // Discriminating power first: one line really cannot hold it.
        check(fleet.debugMetaOneLineWidth > fleet.debugMetaPaintedWidth + 20,
              "fixture: the fleet row's line (\(fleet.debugMetaOneLineWidth)pt) should not fit one line of "
              + "\(fleet.debugMetaPaintedWidth)pt", &ok)
        check(fleet.debugMetaFitsItsFrame,
              "the fleet row's line is cut short: \"\(fleet.debugMetaText)\" in \(fleet.debugMetaPaintedWidth)pt", &ok)
        check(first.debugMetaFitsItsFrame, "a one-line row's line is cut short: \"\(first.debugMetaText)\"", &ok)
        check((rows.last?.frame.height ?? 0) > (rows.first?.frame.height ?? 0) + 8,
              "the wrapped row should be taller than a one-line row, got \(rows.map(\.frame.height))", &ok)
        // The list is as tall as its rows, so nothing is clipped under the
        // card and no "+N more" cue claims a row is hidden.
        let scroll = card.debugListScroll
        let document = scroll.documentView?.frame.height ?? 0
        check(document <= scroll.contentView.bounds.height + 0.5 && card.debugMoreCount == nil,
              "the wrapped list (\(document)pt) does not fit its \(scroll.contentView.bounds.height)pt view, "
              + "cue \(card.debugMoreCount.map(String.init) ?? "none")", &ok)
    }

    private static func checkTheListScrollsInsideTheCard(_ ok: inout Bool) {
        let window = OffScreenProbe.window(width: 700, height: 700, styleMask: [.titled, .resizable])
        defer { window.orderOut(nil) }
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        window.contentView = host
        window.orderFront(nil)
        let card = NeedsAttentionCard()
        var opened: NeedsAttentionItem?
        card.onOpenItem = { opened = $0 }
        host.addSubview(card)
        let height = card.heightAnchor.constraint(equalToConstant: 460)
        height.priority = HelmDaylightPriority.contentTie
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.widthAnchor.constraint(equalToConstant: 477),
            height,
        ])
        card.setLayoutWidth(477)
        card.render(ReviewTourLab.demoAttentionSummary(count: 10), subline: "Fleet read just now.",
                    theme: ThemeManager.shared.theme)
        host.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        // No run-loop pump before reading the cue: it is computed
        // synchronously, and CI's runner showed a queued update still pending
        // after one. Reading it straight away is what keeps it that way.

        let scroll = card.debugListScroll
        let documentHeight = scroll.documentView?.frame.height ?? 0
        let visibleHeight = scroll.contentView.bounds.height
        // Discriminating power first: the fixture really is taller than the
        // room it was given, or every assertion below would pass vacuously.
        check(card.debugRows.count == 10, "the fixture should draw 10 rows, got \(card.debugRows.count)", &ok)
        check(documentHeight > visibleHeight + 50,
              "ten rows (\(documentHeight)pt) should not fit the \(visibleHeight)pt list", &ok)
        check(abs(card.frame.height - 460) < 1,
              "the card should take the height its host gave it, got \(card.frame.height)pt", &ok)
        check(card.debugEyebrow == "NEEDS ATTENTION \u{00B7} 10",
              "the eyebrow should carry the total, got \"\(card.debugEyebrow)\"", &ok)

        guard let hidden = card.debugMoreCount else {
            fail("rows are clipped but no \"+N more\" cue is shown", &ok)
            return
        }
        let fullyVisible = card.debugRows.filter { row in
            row.convert(row.bounds, to: scroll.documentView).maxY <= scroll.contentView.documentVisibleRect.maxY + 0.5
        }.count
        check(hidden == 10 - fullyVisible,
              "the cue says +\(hidden) more but \(10 - fullyVisible) rows are below the fold", &ok)
        check(card.debugListAccessibilityLabel == "Needs attention, 10 items, \(fullyVisible) visible",
              "VoiceOver should hear the list as one group with its counts, got "
              + "\(card.debugListAccessibilityLabel ?? "nothing")", &ok)
        check(scroll.verticalScroller?.controlSize == .small, "the list's scroller should be the small size", &ok)

        // The pill's own press pages down - through the accessibility press,
        // which is what VoiceOver and the pill's click both reach.
        let before = scroll.contentView.bounds.minY
        _ = card.debugMorePill.accessibilityPerformPress()
        check(scroll.contentView.bounds.minY > before + 1, "pressing the cue should scroll the list down", &ok)

        // Wheel routing: a clipped list keeps its wheel events. Asserted as
        // the scroll view's own decision rather than with a posted wheel
        // event, because a synthetic wheel event does not scroll an
        // off-screen window's scroll view even when delivered directly -
        // measured, so a check built on one could never fail.
        check(!scroll.forwardsWheelToPage, "a clipped list should keep its own wheel events", &ok)

        // Keyboard: with Full Keyboard Access, Tab lands on a row's checkbox
        // and its Open button (the row's own surface was never a key view).
        // Focus the last row's Open the way Tab does, and it must scroll its
        // row into view; then Space presses it.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        if let last = card.debugRows.last as? NeedsAttentionRowView {
            check(card.debugMoreCount != nil,
                  "fixture: the last row should start below the fold - \(card.debugCueState)", &ok)
            window.makeFirstResponder(last.debugActionButton)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let frame = last.convert(last.bounds, to: scroll.documentView)
            let visible = scroll.contentView.documentVisibleRect
            check(frame.maxY <= visible.maxY + 0.5 && frame.minY >= visible.minY - 0.5,
                  "a focused row should scroll into view - row \(frame), visible \(visible)", &ok)
            check(card.debugMoreCount == nil, "with the last row in view the cue should go away", &ok)
            if let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            characters: " ", charactersIgnoringModifiers: " ",
                                            isARepeat: false, keyCode: 49) {
                window.sendEvent(space)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                check(opened?.id == "signal.claude",
                      "Space on the focused Open should open its row, opened \(opened?.id ?? "nothing")", &ok)
            }
            // VoiceOver reads the row's kind and state, not only its title.
            let label = last.debugRow.accessibilityLabel() ?? ""
            check(label.contains("Claude usage") && label.contains("92%"),
                  "the row's VoiceOver label should carry its kind and state, got \"\(label)\"", &ok)
        } else {
            fail("the last row is not an attention row", &ok)
        }

        // Three rows fit, so nothing is clipped and there is no cue.
        card.render(ReviewTourLab.demoAttentionSummary(count: 3), subline: "Fleet read just now.",
                    theme: ThemeManager.shared.theme)
        card.layoutSubtreeIfNeeded()
        check(card.debugMoreCount == nil, "three rows in 460pt should show no cue", &ok)
        check(card.debugListScroll.forwardsWheelToPage,
              "a list with nothing to scroll should hand wheel events to the page", &ok)

        // The compact form, at the 960pt minimum window's 293pt column: a
        // 15pt headline wrapping to three lines, Refresh as a glyph that
        // still says "Refresh" to VoiceOver, the freshness subline kept, and
        // rows that keep only the state's first phrase with the rest on hover.
        card.onRefresh = {}
        card.setLayoutWidth(293)
        card.layoutSubtreeIfNeeded()
        check(card.debugIsCompact, "a 293pt card should be in its compact form", &ok)
        let headline = card.debugHeader.titleLabel
        check(headline.maximumNumberOfLines == NeedsAttentionCard.compactHeadlineLines
                && headline.cell?.wraps == true,
              "the compact headline should wrap to \(NeedsAttentionCard.compactHeadlineLines) lines", &ok)
        check(card.debugRefreshButton.title.isEmpty
                && card.debugRefreshButton.accessibilityLabel() == "Refresh",
              "compact Refresh is a glyph that VoiceOver still calls Refresh", &ok)
        check(!card.debugSubline.isEmpty, "the compact header keeps the freshness subline", &ok)
        // Whether the header stays inside a 293pt card is asserted on the
        // real page by `HomeFitSelfTest`: in this standalone card the wrong
        // arithmetic still resolved the good way, so a check here could not
        // fail.
        if let first = card.debugRows.first as? NeedsAttentionRowView {
            check(first.debugRow.debugMetaText == "Overdue 27 days",
                  "a compact row keeps the state's first phrase, got \"\(first.debugRow.debugMetaText)\"", &ok)
            let hover = first.debugRow.debugHitView.toolTip ?? ""
            check(hover.contains("Follow-up") && hover.contains("since 18 Sep"),
                  "and the full line moves to its hover text, got \"\(hover)\"", &ok)
        }
        card.setLayoutWidth(477)
        if let first = card.debugRows.first as? NeedsAttentionRowView {
            check(first.debugRow.debugMetaText == "Follow-up \u{00B7} Overdue 27 days \u{00B7} since 18 Sep",
                  "at 477pt the row carries the whole N1 line, got \"\(first.debugRow.debugMetaText)\"", &ok)
        }
        check(card.debugListAccessibilityLabel == "Needs attention, 3 items",
              "an unclipped list's label should not mention visibility, got "
              + "\(card.debugListAccessibilityLabel ?? "nothing")", &ok)
    }

    private static func otherTheme() -> HelmTheme {
        HelmTheme.allThemes.first { $0.id != ThemeManager.shared.theme.id } ?? ThemeManager.shared.theme
    }

    /// PERF-04, PF10's shape: the Home canvas pushes the theme from its
    /// observer, its own `render()` and its resize paths, and re-renders this
    /// card on every refresh. A push of the palette already showing, and a
    /// render of the summary already drawn, must leave the rows themselves -
    /// not equal copies - in place. A real palette change still rebuilds, and
    /// so does a text-size change, which re-fires the same theme.
    ///
    /// Injection: drop the `appliedKey` guard from `applyTheme` and the rows
    /// are replaced on the first re-push.
    private static func checkASamePaletteRePushKeepsTheRows(_ ok: inout Bool) {
        let window = OffScreenProbe.window(width: 700, height: 700, styleMask: [.titled, .resizable])
        defer { window.orderOut(nil) }
        let card = NeedsAttentionCard()
        window.contentView = card
        window.orderFront(nil)
        let theme = ThemeManager.shared.theme
        let summary = ReviewTourLab.demoAttentionSummary(count: 4)
        card.render(summary, subline: "Fleet read just now.", theme: theme)
        card.layoutSubtreeIfNeeded()
        let rows = card.debugRows.map(ObjectIdentifier.init)
        let rebuilds = card.debugRebuildCount
        check(!rows.isEmpty, "PERF-04: the fixture should draw rows, or identity proves nothing", &ok)

        for _ in 0..<3 { card.applyTheme(theme) }
        card.render(summary, subline: "Fleet read just now.", theme: theme)
        card.render(summary, subline: "Fleet read 1 min ago.", theme: theme)
        check(card.debugRows.map(ObjectIdentifier.init) == rows,
              "PERF-04: a same-palette re-push or an unchanged render replaced the rows", &ok)
        check(card.debugRebuildCount == rebuilds,
              "PERF-04: \(card.debugRebuildCount - rebuilds) rebuild(s) for nothing that changed", &ok)
        check(card.debugSubline == "Fleet read 1 min ago.",
              "PERF-04: an unchanged summary with a new subline must still show the new subline", &ok)

        // The other direction: a real change still repaints.
        card.applyTheme(otherTheme())
        check(card.debugRebuildCount == rebuilds + 1,
              "PERF-04: a palette change should rebuild the rows once", &ok)
        card.applyTheme(theme)
        let before = card.debugRebuildCount
        let scale = ChromeTextScale.shared.scale
        ChromeTextScale.shared.setScale(scale == ChromeTextScale.maxScale ? ChromeTextScale.minScale : ChromeTextScale.maxScale)
        card.applyTheme(theme)
        ChromeTextScale.shared.setScale(scale)
        check(card.debugRebuildCount == before + 1,
              "PERF-04: a text-size change re-fires the same theme and must still rebuild", &ok)
    }
}

#endif
