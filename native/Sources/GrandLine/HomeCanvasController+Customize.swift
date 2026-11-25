// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: Customize: hiding, sizing and colouring a card, dragging a card's size, rebuilding the grid, and each card's style menu.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    // MARK: Customize

    /// Enter or leave Customize. Only Home's own space, and only with a
    /// layout to arrange - the floating bar has none.
    func setCustomizing(_ customizing: Bool) {
        let customizing = customizing && cardLayout != nil
        guard customizing != isCustomizing else { return }
        if customizing, space != .overview { space = .overview }
        // A drag still in progress ends with Customize. Left running, the
        // rebuild below keeps its card, strip and grips included, and that
        // card shows Customize's controls in place of its own until Home is
        // rebuilt again with no drag on.
        if !customizing { endCardResize() }
        isCustomizing = customizing
        guard isViewLoaded else { return }
        render()
        view.layoutSubtreeIfNeeded()
        if customizing { scrollToTop() }
    }

    func endCustomizing() {
        setCustomizing(false)
        onCustomizingChanged?(false)
    }

    /// The captain changed the arrangement: keep it, tell the shell, redraw.
    func arrange(_ change: (inout HomeCardLayout) -> Void) {
        guard var layout = cardLayout else { return }
        change(&layout)
        guard layout != cardLayout else { return }
        cardLayout = layout
        onCardLayoutChanged?(layout)
    }

    /// The tray sits above the attention card while Customize is on.
    func placeCustomizeTray() {
        let wanted = isCustomizing && showsArrangedCards
        if wanted, customizeTray.superview !== stack {
            stack.insertArrangedSubview(customizeTray, at: stack.arrangedSubviews.firstIndex(of: heroCard) ?? 1)
            customizeTray.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if !wanted, customizeTray.superview === stack {
            stack.removeArrangedSubview(customizeTray)
            customizeTray.removeFromSuperview()
        }
        customizeTray.hiddenCards = cardLayout?.hidden ?? []
    }

    /// A card's controls while Customize is on: reset its size, earlier,
    /// later and hide, over the card's own header actions - and the grips on
    /// its edges that size it.
    func attachCustomizeStrip(to card: HelmModuleCard, module: DaylightModule) {
        guard isCustomizing, showsArrangedCards, let layout = cardLayout else { return }
        let strip = HomeCardCustomizeStrip(cardTitle: module.title, hasCustomSize: layout.hasCustomSize(module),
                                           canMoveEarlier: layout.canMove(module, by: -1),
                                           canMoveLater: layout.canMove(module, by: 1))
        strip.onResetSize = { [weak self] in self?.arrange { $0.resetSize(of: module) } }
        strip.onMove = { [weak self] offset in self?.arrange { $0.move(module, by: offset) } }
        strip.onHide = { [weak self] in self?.arrange { $0.hide(module) } }
        card.setHeaderAccessory(strip)
        cardStrips[module] = strip
        attachResizeHandles(to: card, module: module)
    }

    /// The trailing, bottom and corner grips. A card kept through a rebuild
    /// mid-drag already has its own, and keeps them - they are the views the
    /// drag's events are going to.
    func attachResizeHandles(to card: HelmModuleCard, module: DaylightModule) {
        let existing = card.subviews.compactMap { $0 as? HomeCardResizeHandle }
        let handles = existing.isEmpty
            ? HomeCardResizeHandle.Edge.allCases.map { edge -> HomeCardResizeHandle in
                let handle = HomeCardResizeHandle(edge: edge, cardTitle: module.title)
                handle.install(in: card)
                handle.onBegin = { [weak self] edge, point in self?.beginCardResize(module, edge: edge, at: point) }
                handle.onDrag = { [weak self] _, point in self?.dragCardResize(to: point) }
                handle.onEnd = { [weak self] _ in self?.endCardResize() }
                handle.onReset = { [weak self] edge in self?.resetCardSize(module, edge: edge) }
                handle.onStep = { [weak self] edge, step in self?.stepCardSize(module, edge: edge, by: step) }
                return handle
            }
            : existing
        for handle in handles { handle.isActive = cardResize?.module == module }
        resizeHandles[module] = handles
    }

    // MARK: Sizing a card by dragging it


    func beginCardResize(_ module: DaylightModule, edge: HomeCardResizeHandle.Edge, at windowPoint: NSPoint) {
        guard isCustomizing, showsArrangedCards, let layout = cardLayout, let card = cardsByModule[module] else { return }
        var base = layout
        if edge.resizesWidth { keepDrawnRow(of: module, in: &base, available: gridContainerWidth()) }
        cardResize = CardResize(module: module, edge: edge, start: document.convert(windowPoint, from: nil),
                                startWidth: card.frame.width, startHeight: card.frame.height, startLayout: layout,
                                base: base)
        for handle in resizeHandles[module] ?? [] { handle.isActive = true }
        sizeBadge.removeFromSuperview()
        card.addSubview(sizeBadge, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            sizeBadge.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                                constant: -(HomeCardResizeHandle.cornerSize + HelmMetrics.s1)),
            sizeBadge.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -HelmMetrics.s2),
        ])
        updateSizeBadge()
    }

    /// The pointer moved: the size it now asks for, on the grid. The card is
    /// the preview - Home is laid out again at that size, so its neighbours
    /// reflow under the pointer - and nothing is kept until the drag ends.
    func dragCardResize(to windowPoint: NSPoint) {
        guard let resize = cardResize, cardLayout != nil else { return }
        if let event = NSApp?.currentEvent, event.type == .leftMouseDragged { document.autoscroll(with: event) }
        let point = document.convert(windowPoint, from: nil)
        let available = gridContainerWidth()
        var layout = resize.base
        var size = layout.size(of: resize.module)
        if resize.edge.resizesWidth {
            let wanted = HomeCardGrid.columns(nearestWidth: resize.startWidth + point.x - resize.start.x,
                                              containerWidth: available, spacing: Self.gridSpacing)
            size.columns = max(wanted, arrangedMinimumColumns(available: available))
        }
        if resize.edge.resizesHeight {
            let span = arrangedSpans(of: layout, available: available)[resize.module] ?? size.columns
            let width = HomeCardGrid.width(columns: span, containerWidth: available, spacing: Self.gridSpacing)
            // Never below what the content needs: dragging past it would
            // store a height the card cannot be drawn at.
            size.height = max(HomeCardGrid.storedHeight(resize.startHeight + point.y - resize.start.y),
                              naturalHeight(of: resize.module, width: width))
        }
        layout.setSize(size, for: resize.module)
        guard layout != cardLayout else { return }
        cardLayout = layout
    }

    /// The drag ended: keep the size it settled on.
    func endCardResize() {
        guard let resize = cardResize else { return }
        cardResize = nil
        sizeBadge.removeFromSuperview()
        for handle in resizeHandles[resize.module] ?? [] { handle.isActive = false }
        guard let layout = cardLayout, layout != resize.startLayout else { return }
        cardStrips[resize.module]?.setHasCustomSize(layout.hasCustomSize(resize.module))
        onCardLayoutChanged?(layout)
    }

    /// A double-click on a grip: the width back to the card's own, the
    /// height back to its content's, or both from the corner.
    func resetCardSize(_ module: DaylightModule, edge: HomeCardResizeHandle.Edge) {
        arrange { layout in
            var size = layout.size(of: module)
            let own = HomeCardLayout.ownSize(of: module)
            if edge.resizesWidth { size.columns = own.columns }
            if edge.resizesHeight { size.height = nil }
            if size == own { layout.resetSize(of: module) } else { layout.setSize(size, for: module) }
        }
    }

    /// VoiceOver's increment and decrement on a grip: a column wider or
    /// narrower, or four height steps taller or shorter.
    func stepCardSize(_ module: DaylightModule, edge: HomeCardResizeHandle.Edge, by step: Int) {
        guard let card = cardsByModule[module] else { return }
        let available = gridContainerWidth()
        arrange { layout in
            var size = layout.size(of: module)
            if edge.resizesWidth {
                // From the width it is drawn at, as a drag is.
                keepDrawnRow(of: module, in: &layout, available: available)
                size = layout.size(of: module)
                size.columns = min(max(size.columns + step, arrangedMinimumColumns(available: available)),
                                   HomeCardGrid.columns)
            }
            if edge.resizesHeight {
                let height = (size.height ?? card.frame.height) + CGFloat(step) * HomeCardGrid.heightStep * 4
                size.height = max(HomeCardGrid.storedHeight(height), naturalHeight(of: module, width: card.frame.width))
            }
            layout.setSize(size, for: module)
        }
    }

    /// The badge on the card being dragged: the size it is drawn at.
    func updateSizeBadge() {
        guard let resize = cardResize, let card = cardsByModule[resize.module] else { return }
        sizeBadge.show(width: card.frame.width, height: card.frame.height)
    }

    /// What a built grid depends on besides its cards' data. Two renders with
    /// the same key lay out identically, so the second can reuse the first's
    /// cards (P2).
    struct GridLayoutKey: Equatable {
        var space: DaylightSpace
        var modules: [DaylightModule]
        /// Each card's span, which the captain can change on Home.
        var spans: [Int]
        /// Each card's own height on Home, -1 for one that takes its row's.
        var heights: [CGFloat] = []
        /// How many cards each of Home's arranged rows holds: the same spans
        /// can break into rows differently once the window makes room in one.
        var rowLengths: [Int] = []
        /// Customize puts controls on every card, so toggling it rebuilds.
        var customizing: Bool
        var dashboard: Bool
        var width: CGFloat
        /// The hub's columns are budgeted from the height; the shelf's are not.
        var height: CGFloat
    }

    func rebuildGrid() {
        let available = gridContainerWidth()
        lastGridWidth = available
        lastGridHeight = gridContainerHeight()
        let modules = visibleModules()

        // Overview is hand-placed - see `dashboardRowViews` for why, and for
        // the two conditions under which it declines and this falls through
        // to the wrapping grid below.
        let dashboard = usesDashboardLayout && dashboardRowViewsWouldApply(available: available, modules: modules)

        // P2: a render that changed only data keeps the grid and its cards.
        // Rebuilding them is what made Home flash on every fleet refresh and
        // dropped a card's hover; it also re-registered every card's theme
        // observer and re-solved the whole grid.
        if refreshGridInPlace(available: available, modules: modules, dashboard: dashboard) { return }

        #if FM_SELFTESTS
        debugGridRebuilds += 1
        #endif
        // A card being dragged to a new size survives the rebuild its drag
        // causes: its grips are the views the drag's events are going to.
        // Only while Customize is on: outside it nothing would take the
        // kept card's strip and grips off again.
        let kept = isCustomizing
            ? cardResize.flatMap { resize in cardsByModule[resize.module].map { (resize.module, $0) } }
            : nil
        for row in gridStack.arrangedSubviews {
            gridStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        gridWidthPins.removeAll()
        builtShelfColumns = 0
        cards.removeAll()
        cardsByModule.removeAll()
        cardPlacements.removeAll()
        dashboardOwnHeights.removeAll()
        cardStrips.removeAll()
        resizeHandles.removeAll()
        gridLayoutKey = nil

        placeCustomizeTray()
        placeAttentionCard(inDashboard: dashboard)
        documentFillsViewport?.isActive = dashboard
        if dashboard,
           let rows = dashboardRowViews(available: available, modules: modules) {
            // The dashboard uses the full width by construction: its spans
            // sum to the whole track grid, so there is no leftover column to
            // turn into margin the way `composedContentWidth` does for a
            // space with fewer cards than columns.
            contentWidthConstraint?.constant = available
            for row in rows {
                gridStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
                gridWidthPins += row.arrangedSubviews.enumerated().compactMap { index, column in
                    Self.widthPin(of: column).map { ($0, Self.dashboardSpans[min(index, Self.dashboardSpans.count - 1)]) }
                }
            }
            gridLayoutKey = GridLayoutKey(space: space, modules: modules, spans: [], customizing: false, dashboard: true,
                                          width: available, height: lastGridHeight)
            return
        }

        if showsArrangedCards {
            buildArrangedGrid(available: available, modules: modules, keeping: kept)
            return
        }

        // C1: use only as many columns as this space has cards to fill, and
        // let the column that is left over become margin on both sides
        // instead of a one-sided void on the right.
        //
        // The card *size* is unchanged - `unit` is still derived from the
        // full available width and the full column count, which is what the
        // captain's uniform-height decision (and the uniform-width rule that
        // came with it) rests on. Only how many of those columns the content
        // occupies changes.
        let width = Self.composedContentWidth(available: available, modules: modules, spans: cardSpan)
        contentWidthConstraint?.constant = width
        // R2-A11Y-05: the full-width card is told its width as a column is,
        // so its headline wraps to two lines and its single lines truncate.
        // Told nothing, a long verdict stayed on one line and ran past the
        // card and out of the window - measured in the tour lab at 1100 and
        // 1512, and at the Larger text scale it hid Refresh as well.
        attentionCard.setLayoutWidth(width)

        // `spanningRows(_:)`, not `rows(_:)`: the Morning briefing spans two
        // columns and every other module spans one (`DaylightModule.gridSpan`).
        // Uniform *width* still comes from the layout rather than from
        // anything a card asks for - a span-1 card is exactly one column in
        // every row - and this path carries the same partial-row padding that
        // stops a lone leftover card stretching, expressed in columns rather
        // than cells. Uniform *height* is per row (`equalHeights` below):
        // full review #3's PF2 turned `HelmModuleCard`'s fixed height into a
        // floor, so a row of one-line cards is now as short as its content.
        let rows = HelmResponsiveGrid.spanningRows(
            modules,
            spans: cardSpan,
            containerWidth: width,
            minItemWidth: Self.minModuleWidth,
            spacing: Self.gridSpacing,
            // PF2: a card is content-sized now, so uniformity is per row.
            // Every card joins its row's tie, the Claude card included
            // (`fm/grandline-widget-polish`): the captain wants it as tall as
            // Fleet and Hosts beside it.
            equalHeights: true
        ) { [weak self] module, cardWidth in
            guard let self else { return NSView() }
            let card = self.makeCard(for: module, placement: .shelf(width: cardWidth))
            self.attachCustomizeStrip(to: card, module: module)
            return card
        }

        let columns = HelmResponsiveGrid.columns(containerWidth: width, minItemWidth: Self.minModuleWidth,
                                                 spacing: Self.gridSpacing)
        let unit = HelmResponsiveGrid.itemWidth(containerWidth: width, columns: columns, spacing: Self.gridSpacing)
        builtShelfColumns = columns
        for row in rows {
            gridStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
            // Each cell's span, read back off the width it was built at - the
            // inverse of `spanningRows`' own `unit * span + spacing * (span - 1)`.
            gridWidthPins += row.arrangedSubviews.compactMap { cell in
                Self.widthPin(of: cell).map {
                    ($0, max(1, Int((($0.constant + Self.gridSpacing) / (unit + Self.gridSpacing)).rounded())))
                }
            }
        }
        if Set(cardsByModule.keys) == Set(modules) {
            gridLayoutKey = GridLayoutKey(space: space, modules: modules, spans: modules.map(cardSpan),
                                          customizing: isCustomizing, dashboard: false,
                                          width: available, height: 0)
        }
    }

    /// Home's arranged cards: the captain's widths, in `HomeCardGrid.columns`
    /// across the whole width, and their heights. The same row builder as
    /// the shelf below, at a fixed column count, so a card left at its own
    /// size draws exactly as it did when sizes were fixed.
    ///
    /// The content is not composed into fewer columns (C1): the captain sized
    /// these cards against the full width, and a row they left short is
    /// theirs to leave.
    func buildArrangedGrid(available: CGFloat, modules: [DaylightModule],
                                   keeping kept: (module: DaylightModule, card: HelmModuleCard)?) {
        contentWidthConstraint?.constant = available
        attentionCard.setLayoutWidth(available)
        let placed = shownLayout.map { arrangedRows(of: $0, available: available) } ?? []
        var spans: [DaylightModule: Int] = [:]
        for placement in placed.joined() where modules.indices.contains(placement.index) {
            spans[modules[placement.index]] = placement.span
        }
        let widths = spans.mapValues { HomeCardGrid.width(columns: $0, containerWidth: available, spacing: Self.gridSpacing) }
        let heights = Dictionary(modules.map { ($0, arrangedHeight(of: $0, width: widths[$0] ?? 0)) },
                                 uniquingKeysWith: { first, _ in first })
        let rows = HelmResponsiveGrid.spanningRows(
            modules,
            spans: { spans[$0] ?? 1 },
            containerWidth: available,
            minItemWidth: Self.minModuleWidth,
            columnCount: HomeCardGrid.columns,
            spacing: Self.gridSpacing,
            equalHeights: true,
            fixedHeight: { heights[$0] ?? nil },
            packedRows: placed
        ) { [weak self] module, cardWidth in
            guard let self else { return NSView() }
            let placement = CardPlacement.shelf(width: cardWidth)
            let card: HelmModuleCard
            if let kept, kept.module == module {
                // Off its old row, and without the width and height that row
                // gave it; the new row gives it its own.
                let own = kept.card.constraints.filter {
                    $0.identifier == HelmResponsiveGrid.cellConstraintIdentifier
                        || $0.identifier == HelmResponsiveGrid.fixedHeightIdentifier
                }
                NSLayoutConstraint.deactivate(own)
                kept.card.removeFromSuperview()
                kept.card.configureIfChanged(self.content(for: module, placement: placement))
                card = kept.card
                self.cards.append(card)
                self.cardsByModule[module] = card
                self.cardPlacements[module] = placement
            } else {
                card = self.makeCard(for: module, placement: placement)
            }
            self.attachCustomizeStrip(to: card, module: module)
            return card
        }
        let unit = HomeCardGrid.unitWidth(containerWidth: available, spacing: Self.gridSpacing)
        builtShelfColumns = HomeCardGrid.columns
        for row in rows {
            gridStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
            gridWidthPins += row.arrangedSubviews.compactMap { cell in
                Self.widthPin(of: cell).map {
                    ($0, max(1, Int((($0.constant + Self.gridSpacing) / (unit + Self.gridSpacing)).rounded())))
                }
            }
        }
        if Set(cardsByModule.keys) == Set(modules) {
            gridLayoutKey = GridLayoutKey(space: space, modules: modules, spans: modules.map { spans[$0] ?? 1 },
                                          heights: modules.map { heights[$0].flatMap { $0 } ?? -1 },
                                          rowLengths: placed.map(\.count),
                                          customizing: isCustomizing, dashboard: false,
                                          width: available, height: 0)
        }
        view.layoutSubtreeIfNeeded()
        updateSizeBadge()
    }

    /// The arrangement changed mid-drag. A height on a card that already has
    /// one moves in place; anything that can change which row a card is on
    /// lays the grid out again, keeping the dragged card.
    func resizeArrangedGrid() {
        guard let resize = cardResize, let built = gridLayoutKey, built.space == space, !built.dashboard,
              let card = cardsByModule[resize.module] else {
            rebuildGrid()
            return
        }
        let modules = visibleModules()
        let available = gridContainerWidth()
        let spans = modules.map(cardSpan)
        if built.modules == modules, built.spans == spans, built.rowLengths == arrangedRowLengths(available: available),
           abs(built.width - available) <= 0.5,
           let index = modules.firstIndex(of: resize.module), built.heights.indices.contains(index),
           built.heights[index] >= 0,
           let height = arrangedHeight(of: resize.module, width: card.frame.width),
           let pin = card.constraints.first(where: { $0.identifier == HelmResponsiveGrid.fixedHeightIdentifier }) {
            pin.constant = height
            gridLayoutKey?.heights[index] = height
            view.layoutSubtreeIfNeeded()
            updateSizeBadge()
            return
        }
        rebuildGrid()
    }

    /// P2: reconfigure the grid's existing cards when nothing about the
    /// layout changed. `false` when the grid has to be rebuilt instead.
    ///
    /// Every card is configured from scratch from fresh content, exactly as
    /// a new card would be, so "refreshed in place" and "built fresh" render
    /// the same; only the card objects - their chrome, hover state and theme
    /// observers - and the rows holding them survive.
    func refreshGridInPlace(available: CGFloat, modules: [DaylightModule], dashboard: Bool) -> Bool {
        guard let previous = gridLayoutKey, previous.space == space, previous.modules == modules,
              previous.spans == (dashboard ? [] : modules.map(cardSpan)),
              previous.heights == (dashboard ? [] : arrangedHeightKey(modules)),
              previous.rowLengths == (dashboard ? [] : arrangedRowLengths(available: available)),
              previous.customizing == (dashboard ? false : isCustomizing),
              previous.dashboard == dashboard, abs(previous.width - available) <= 0.5,
              Set(cardsByModule.keys) == Set(modules) else { return false }
        if dashboard {
            guard abs(previous.height - lastGridHeight) <= 0.5 else { return false }
            let plan = dashboardPlan(available: available)
            for module in modules {
                guard let content = plan.contents[module] else { return false }
                cardsByModule[module]?.configure(content)
            }
            // The column's own-height preferences follow the content, which
            // is everything a rebuild would have re-measured.
            for (module, height) in plan.ownHeights {
                dashboardOwnHeights[module]?.constant = height
            }
            return true
        }
        var contents: [DaylightModule: HelmModuleCard.Content] = [:]
        for module in modules {
            guard let placement = cardPlacements[module] else { return false }
            contents[module] = content(for: module, placement: placement)
        }
        for module in modules {
            if let content = contents[module] { cardsByModule[module]?.configure(content) }
        }
        return true
    }

    /// The heights a built arranged grid is keyed on: -1 for a card that
    /// takes its row's height, and nothing at all off Home's arranged cards.
    func arrangedHeightKey(_ modules: [DaylightModule]) -> [CGFloat] {
        guard showsArrangedCards, let shownLayout else { return [] }
        let available = gridContainerWidth()
        return modules.map { module in
            guard shownLayout.size(of: module).height != nil else { return -1 }
            let width = HomeCardGrid.width(columns: cardSpan(module), containerWidth: available, spacing: Self.gridSpacing)
            return arrangedHeight(of: module, width: width) ?? -1
        }
    }

    /// The attention card is column 1 of the hub's three-column page, and a
    /// full-width card above the grid everywhere else (where it is hidden
    /// off the hub, and where the hub falls back to the wrapping grid).
    /// Moved rather than rebuilt, so its rows, its scroll position and its
    /// minute tick survive a rebuild.
    func placeAttentionCard(inDashboard: Bool) {
        // `proportionalRow` pins a column's width with a constant on the view
        // itself, which outlives the row it was made for - so the last
        // rebuild's pin is dropped before this one adds its own.
        attentionCard.removeConstraints(attentionCard.constraints.filter {
            $0.firstItem === attentionCard && $0.secondItem == nil && $0.firstAttribute == .width
        })
        if inDashboard {
            if attentionCard.superview === stack {
                stack.removeArrangedSubview(attentionCard)
                attentionCard.removeFromSuperview()
                attentionWidthTie = nil
            }
            return
        }
        attentionCard.setLayoutWidth(0)
        guard attentionCard.superview !== stack else { return }
        attentionCard.removeFromSuperview()
        stack.insertArrangedSubview(attentionCard, at: 1)
        let tie = attentionCard.widthAnchor.constraint(equalTo: stack.widthAnchor)
        tie.isActive = true
        attentionWidthTie = tie
    }

    // MARK: The hero cards (the widget-style board's picks)
    //
    // The captain picked the split hero for the Claude card and the full hero
    // for Fleet, each with a colour they choose (`HomeCardStyle`). The readings
    // and their thresholds are the cards' own - `claudeUsageSections`,
    // `claudeChip` and `QuotaSeverity` for Claude, the snapshot's counts for
    // Fleet - so the hero changes how a card looks and never what it says.

    /// The colour the captain chose for `module`, dimmed for a stale reading.
    func heroTone(for module: DaylightModule, dimmed: Bool) -> HelmModuleCard.HeroTone {
        HelmModuleCard.HeroTone(colour: HomeCardStyle.color(for: module).heroColour, isDimmed: dimmed)
    }

    /// The palette button on a hero card's header.
    func styleMenu(for module: DaylightModule) -> HelmModuleCard.HeaderMenu {
        HelmModuleCard.HeaderMenu(symbol: HomeCardStyleMenu.symbol, tooltip: HomeCardStyleMenu.tooltip) { [weak self] in
            self?.makeStyleMenu(for: module).makeMenu() ?? NSMenu()
        }
    }

    /// The style menu for `module` as it stands now. Size and Hide are
    /// offered only on Home's own arranged cards, which are the only cards
    /// with a width and a place the captain owns.
    func makeStyleMenu(for module: DaylightModule) -> HomeCardStyleMenu {
        var sizing: HomeCardStyleMenu.Sizing?
        var hide: (() -> Void)?
        if showsArrangedCards, let layout = cardLayout, layout.shown.contains(module) {
            sizing = HomeCardStyleMenu.Sizing(
                current: HomeCardSizeMode(columns: layout.size(of: module).columns),
                choose: { [weak self] mode in self?.setCardSize(mode, for: module) })
            hide = { [weak self] in self?.hideCard(module) }
        }
        return HomeCardStyleMenu(
            cardTitle: module.title, sizing: sizing, color: HomeCardStyle.color(for: module),
            chooseColor: { [weak self] color in self?.setCardColor(color, for: module) },
            chooseCustomColor: { [weak self] in self?.chooseCustomCardColor(for: module) },
            hide: hide)
    }

    /// The same edit Customize's hide button makes. Customize's Add a Card
    /// brings the card back, and the toast says so, with an Undo that puts
    /// back the arrangement as it was (GL-33).
    func hideCard(_ module: DaylightModule) {
        guard let before = cardLayout else { return }
        arrange { $0.hide(module) }
        guard isViewLoaded, cardLayout != before else { return }
        Toast.showUndo(in: view, message: "\(module.title) hidden. Add it back from Customize.") { [weak self] in
            guard let self else { return }
            self.cardLayout = before
            self.onCardLayoutChanged?(before)
        }
    }

    /// The same edit a resize drag makes, so it is kept with the rest of
    /// Home's arrangement. The captain's height, if any, stays.
    func setCardSize(_ mode: HomeCardSizeMode, for module: DaylightModule) {
        arrange { layout in
            var size = layout.size(of: module)
            size.columns = mode.columns
            layout.setSize(size, for: module)
        }
    }

    func setCardColor(_ color: HomeCardColor, for module: DaylightModule) {
        HomeCardStyle.setColor(color, for: module)
        guard isViewLoaded else { return }
        render()
    }

    func chooseCustomCardColor(for module: DaylightModule) {
        let current = HomeCardStyle.color(for: module).rgb(in: ThemeManager.shared.theme)
        HomeCardColorPanel.shared.open(current: current) { [weak self] color in
            self?.setCardColor(color, for: module)
        }
    }
}
