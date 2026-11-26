// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: how the captain's arranged cards are chosen,
// placed in rows and measured.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header. P-03 then removed the Needs Attention
// card this file also held, which was drawn only on the floating bar's hub,
// and the file was renamed from `+Attention` to say what is left in it.

import AppKit

extension HomeCanvasController {

    // MARK: The arranged cards

    func visibleModules() -> [DaylightModule] { shownLayout.shown }

    /// R5-UI-08 (full review #5): whether the Morning briefing card has
    /// anything of its own to show. Off, with no briefing on record, it took
    /// the largest slot on Home to say "Turn on Morning briefing in
    /// Settings". It is left off Home until the briefing is on
    /// (Settings > General, which is also where that card pointed), and it
    /// is still in Customize, so the captain can place it.
    static var briefingHasSomethingToSay: Bool {
        AppSettings.shared.morningBriefingEnabled
            || !(AppSettings.shared.morningBriefingRecord?.clauses.isEmpty ?? true)
    }

    /// The arranged cards as drawn: the captain's layout, less a briefing
    /// card with nothing to say (R5-UI-08) - except while customizing, where
    /// every card the captain placed is drawn so it can be moved, sized or
    /// hidden, and where the drag and resize maths index `cardLayout` itself.
    var shownLayout: HomeCardLayout {
        var layout = cardLayout
        // Out of the grid either way outside Customize: with nothing to say
        // (R5-UI-08), or because the feel pass draws it as the hero above
        // the grid (`briefingIsHero`). Customize keeps it a card, so it can
        // still be moved, sized or hidden like every other one.
        if !isCustomizing, layout.shown.contains(.briefing) {
            layout.hide(.briefing)
        }
        return layout
    }

    /// Whether the briefing is drawn as the feel pass's hero: Home's
    /// arranged cards include it, it has something to say, and Customize is
    /// not drawing it as a card.
    var briefingIsHero: Bool {
        !isCustomizing && Self.briefingHasSomethingToSay && cardLayout.shown.contains(.briefing)
    }

    /// A card's grid span, out of `HomeCardGrid.columns`: the width the
    /// captain gave it, as its row draws it at this width
    /// (`HomeCardGrid.rows`).
    func cardSpan(_ module: DaylightModule) -> Int {
        let layout = shownLayout
        return arrangedSpans(of: layout, available: gridContainerWidth())[module] ?? layout.size(of: module).columns
    }

    /// Home's arranged cards in rows at this width, each placement's `index`
    /// into `layout.shown` - the captain's rows, with room made in a row for
    /// a card the window has made too narrow to read.
    ///
    /// R5-UI-08: when `shownLayout` has left the briefing off, its slot is
    /// not left as a hole. If the captain's whole arrangement filled every
    /// row, the rows without it fill the width too; an arrangement that
    /// already had a short row keeps its shape.
    func arrangedRows(of layout: HomeCardLayout, available: CGFloat) -> [[HelmResponsiveGrid.SpanPlacement]] {
        let minimum = arrangedMinimumColumns(available: available)
        func spans(_ layout: HomeCardLayout) -> [Int] { layout.shown.map { layout.size(of: $0).columns } }
        var filling = false
        let full = cardLayout
        if full.shown.count > layout.shown.count {
            filling = !HomeCardGrid.rows(spans: spans(full), minimum: minimum).contains { row in
                row.reduce(0) { $0 + $1.span } < HomeCardGrid.columns
            }
        }
        return HomeCardGrid.rows(spans: spans(layout), minimum: minimum, fillingShortRows: filling)
    }

    /// Each arranged card's columns at this width, as its row draws it.
    func arrangedSpans(of layout: HomeCardLayout, available: CGFloat) -> [DaylightModule: Int] {
        let shown = layout.shown
        var spans: [DaylightModule: Int] = [:]
        for placement in arrangedRows(of: layout, available: available).joined() where shown.indices.contains(placement.index) {
            spans[shown[placement.index]] = placement.span
        }
        return spans
    }

    /// How many cards each row of Home's arranged grid holds at this width.
    func arrangedRowLengths(available: CGFloat) -> [Int] {
        arrangedRows(of: shownLayout, available: available).map(\.count)
    }

    /// `module`'s row stored at the widths it is drawn at
    /// (`HomeCardGrid.drawnSpans`) - what sizing that card starts from, so
    /// the captain sizes what they see.
    func keepDrawnRow(of module: DaylightModule, in layout: inout HomeCardLayout, available: CGFloat) {
        let shown = layout.shown
        guard let index = shown.firstIndex(of: module) else { return }
        let spans = shown.map { layout.size(of: $0).columns }
        let kept = HomeCardGrid.drawnSpans(spans, minimum: arrangedMinimumColumns(available: available), rowOf: index)
        for (index, other) in shown.enumerated() where kept[index] != spans[index] {
            var size = layout.size(of: other)
            size.columns = kept[index]
            layout.setSize(size, for: other)
        }
    }

    /// The fewest of `HomeCardGrid.columns` a card may take at this width:
    /// the canvas's own minimum card width (§6.1's 255).
    func arrangedMinimumColumns(available: CGFloat) -> Int {
        HomeCardGrid.minimumColumns(containerWidth: available, minWidth: Self.minModuleWidth, spacing: Self.gridSpacing)
    }

    /// The height a card on Home's arranged grid is drawn at, `width` wide:
    /// the captain's, but never less than its content needs - or nil for a
    /// card that takes its row's height. Measured after a real layout pass
    /// (gotcha (22)).
    func arrangedHeight(of module: DaylightModule, width: CGFloat) -> CGFloat? {
        guard let height = cardLayout.size(of: module).height else { return nil }
        return max(min(height, HomeCardGrid.maximumHeight), naturalHeight(of: module, width: width))
    }

    /// How tall a card's content needs it to be at `width`.
    func naturalHeight(of module: DaylightModule, width: CGFloat) -> CGFloat {
        let probe = Self.probeCard(content(for: module, width: width))
        return max(Self.fittingHeight(of: probe, width: width), HelmModuleCard.minimumHeight)
    }
}
