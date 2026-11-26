// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: Customize: hiding, sizing and colouring a card, dragging a card's size, building the grid and its cards, and each card's style menu.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    // MARK: Customize

    /// Enter or leave Customize.
    func setCustomizing(_ customizing: Bool) {
        guard customizing != isCustomizing else { return }
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
        var layout = cardLayout
        change(&layout)
        guard layout != cardLayout else { return }
        cardLayout = layout
        onCardLayoutChanged?(layout)
    }

    /// The tray sits above the tip and the cards while Customize is on.
    func placeCustomizeTray() {
        let wanted = isCustomizing
        if wanted, customizeTray.superview !== stack {
            stack.insertArrangedSubview(customizeTray, at: stack.arrangedSubviews.firstIndex(of: tipRow) ?? 2)
            customizeTray.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if !wanted, customizeTray.superview === stack {
            stack.removeArrangedSubview(customizeTray)
            customizeTray.removeFromSuperview()
        }
        customizeTray.hiddenCards = cardLayout.hidden
    }

    /// A card's controls while Customize is on: reset its size, earlier,
    /// later and hide, over the card's own header actions - and the grips on
    /// its edges that size it.
    func attachCustomizeStrip(to card: HelmModuleCard, module: DaylightModule) {
        guard isCustomizing else { return }
        let layout = cardLayout
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
        guard isCustomizing, let card = cardsByModule[module] else { return }
        let layout = cardLayout
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
        guard let resize = cardResize else { return }
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
        let layout = cardLayout
        guard layout != resize.startLayout else { return }
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
        var modules: [DaylightModule]
        /// Each card's span, which the captain can change.
        var spans: [Int]
        /// Each card's own height, -1 for one that takes its row's.
        var heights: [CGFloat]
        /// How many cards each row holds: the same spans can break into rows
        /// differently once the window makes room in one.
        var rowLengths: [Int]
        /// Customize puts controls on every card, so toggling it rebuilds.
        var customizing: Bool
        var width: CGFloat
    }

    func rebuildGrid() {
        let available = gridContainerWidth()
        lastGridWidth = available
        let modules = visibleModules()

        // P2: a render that changed only data keeps the grid and its cards.
        // Rebuilding them is what made Home flash on every fleet refresh and
        // dropped a card's hover; it also re-registered every card's theme
        // observer and re-solved the whole grid.
        if refreshGridInPlace(available: available, modules: modules) { return }

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
        cards.removeAll()
        cardsByModule.removeAll()
        cardWidths.removeAll()
        cardStrips.removeAll()
        resizeHandles.removeAll()
        gridLayoutKey = nil

        placeCustomizeTray()
        buildArrangedGrid(available: available, modules: modules, keeping: kept)
    }

    /// Home's arranged cards: the captain's widths, in `HomeCardGrid.columns`
    /// across the whole width, and their heights. `spanningRows` at a fixed
    /// column count, so a card left at its own size draws exactly as it did
    /// when sizes were fixed.
    ///
    /// The content is not composed into fewer columns (C1): the captain sized
    /// these cards against the full width, and a row they left short is
    /// theirs to leave.
    func buildArrangedGrid(available: CGFloat, modules: [DaylightModule],
                                   keeping kept: (module: DaylightModule, card: HelmModuleCard)?) {
        contentWidthConstraint?.constant = available
        let placed = arrangedRows(of: shownLayout, available: available)
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
                kept.card.configureIfChanged(self.content(for: module, width: cardWidth))
                card = kept.card
                self.cards.append(card)
                self.cardsByModule[module] = card
                self.cardWidths[module] = cardWidth
            } else {
                card = self.makeCard(for: module, width: cardWidth)
            }
            self.attachCustomizeStrip(to: card, module: module)
            return card
        }
        let unit = HomeCardGrid.unitWidth(containerWidth: available, spacing: Self.gridSpacing)
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
            gridLayoutKey = GridLayoutKey(modules: modules, spans: modules.map { spans[$0] ?? 1 },
                                          heights: modules.map { heights[$0].flatMap { $0 } ?? -1 },
                                          rowLengths: placed.map(\.count),
                                          customizing: isCustomizing, width: available)
        }
        view.layoutSubtreeIfNeeded()
        updateSizeBadge()
    }

    /// The arrangement changed mid-drag. A height on a card that already has
    /// one moves in place; anything that can change which row a card is on
    /// lays the grid out again, keeping the dragged card.
    func resizeArrangedGrid() {
        guard let resize = cardResize, let built = gridLayoutKey,
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
    func refreshGridInPlace(available: CGFloat, modules: [DaylightModule]) -> Bool {
        guard let previous = gridLayoutKey, previous.modules == modules,
              previous.spans == modules.map(cardSpan),
              previous.heights == arrangedHeightKey(modules),
              previous.rowLengths == arrangedRowLengths(available: available),
              previous.customizing == isCustomizing, abs(previous.width - available) <= 0.5,
              Set(cardsByModule.keys) == Set(modules) else { return false }
        var contents: [DaylightModule: HelmModuleCard.Content] = [:]
        for module in modules {
            guard let width = cardWidths[module] else { return false }
            contents[module] = content(for: module, width: width)
        }
        for module in modules {
            if let content = contents[module] { cardsByModule[module]?.configure(content) }
        }
        return true
    }

    /// The heights a built grid is keyed on: -1 for a card that takes its
    /// row's height.
    func arrangedHeightKey(_ modules: [DaylightModule]) -> [CGFloat] {
        let available = gridContainerWidth()
        return modules.map { module in
            guard shownLayout.size(of: module).height != nil else { return -1 }
            let width = HomeCardGrid.width(columns: cardSpan(module), containerWidth: available, spacing: Self.gridSpacing)
            return arrangedHeight(of: module, width: width) ?? -1
        }
    }

    // MARK: Building a card

    /// The width pin `spanningRows` puts on a cell: a constant width at
    /// `contentTie`, on the view itself.
    static func widthPin(of view: NSView) -> NSLayoutConstraint? {
        view.constraints.last {
            $0.firstItem === view && $0.secondItem == nil && $0.firstAttribute == .width
                && $0.priority == HelmDaylightPriority.contentTie
        }
    }

    /// A card built only to be measured - not added to `cards`, so it is
    /// never themed, mounted or handed to a test as one of the page's own.
    static func probeCard(_ content: HelmModuleCard.Content) -> HelmModuleCard {
        let card = HelmModuleCard()
        card.configure(content)
        return card
    }

    /// `view`'s height at `width`, after a real layout pass in a scratch
    /// host. The pass matters: a wrapping label sets its wrap width in
    /// `layout()` (gotcha (22)), so a bare `fittingSize` measures a two-line
    /// sentence as one line - measured, 6pt over at 960x620.
    /// `view` must not be in a hierarchy yet; it leaves the host on return.
    static func fittingHeight(of view: NSView, width: CGFloat) -> CGFloat {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 2000))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        host.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        view.removeFromSuperview()
        return height
    }

    func makeCard(for module: DaylightModule, width: CGFloat) -> HelmModuleCard {
        let card = HelmModuleCard()
        card.configure(content(for: module, width: width))
        // While the captain arranges Home a click on a card must not take
        // them off it.
        card.onOpen = { [weak self] in
            guard let self, !self.isCustomizing else { return }
            self.onOpenDestination?(module.opens)
        }
        card.onFollowLink = { [weak self] target in
            guard let self, !self.isCustomizing else { return }
            self.follow(target)
        }
        cards.append(card)
        cardsByModule[module] = card
        cardWidths[module] = width
        return card
    }

    /// The briefing's clause links, from the briefing card and from the
    /// hero's tiles. `HomeBriefingHero.page(of:)` is where each target goes
    /// (and why two of them differ from Overview's own briefing card).
    func follow(_ target: BriefingTarget) {
        // The one Shift task a `.tasks` clause is about, when the app itself
        // resolved there is exactly one; otherwise the clause's page.
        if target == .tasks, let id = AppSettings.shared.morningBriefingRecord?.shiftTaskID {
            onOpenShiftTask?(id)
            return
        }
        if let page = HomeBriefingHero.page(of: target) { onOpenDestination?(page) }
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
    /// offered only on a card the captain's arrangement shows, which is the
    /// only kind with a width and a place the captain owns.
    func makeStyleMenu(for module: DaylightModule) -> HomeCardStyleMenu {
        var sizing: HomeCardStyleMenu.Sizing?
        var hide: (() -> Void)?
        let layout = cardLayout
        if layout.shown.contains(module) {
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
        let before = cardLayout
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
