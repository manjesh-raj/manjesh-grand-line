// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: Overview's dashboard layout (the three fixed columns and the merge queue's row budget).
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    // MARK: Overview's dashboard layout

    /// The hub's page: the attention card and the five widgets, in three
    /// equal columns (`fm/grandline-home-fit-implement`, layout A).
    ///
    /// **Why Overview has a hand-placed layout and the other four spaces do
    /// not.** The wrapping grid is right for a shelf of interchangeable
    /// navigation cards, which is what Command, Operations, Stores and
    /// Engineering are: a card there is one of N equivalent doors, and the
    /// window's width should decide how many fit on a line. Overview is not
    /// that. It is a handful of specific readouts whose placement is the
    /// design, and letting the window decide is what produced the ragged
    /// masonry the captain rejected.
    ///
    /// **Why three columns rather than the 7:5 rows it replaced.** The
    /// captain asked for Home to fit the window without scrolling. Stacking
    /// the attention card above two rows of widgets added their heights
    /// together, and every attention row pushed the widgets further down:
    /// measured at the captain's 1512x945 window, the page was 29pt over the
    /// fold with three rows and 468pt over with ten, and 384pt over at the
    /// 960x620 minimum. Columns share the height instead of adding it.
    ///
    ///   - Column 1 is Needs Attention at its rows' height, capped at the
    ///     column's, its list scrolling inside it past that.
    ///   - Column 2 is Claude (the dense usage form), Fleet and Health.
    ///   - Column 3 is the Morning briefing and the Merge queue.
    ///
    /// The columns still end on one line, but a card is never stretched past
    /// what it holds (UXP-04): every column ends in a spacer that takes the
    /// leftover height, and every card sits at its own height
    /// (`dashboardKeepsOwnHeight`). Column 3 used to fill by the Merge
    /// queue's *row count* with the briefing absorbing the remainder; since
    /// the queue is capped at `maxPeekRows` (R5-UI-03) that remainder is most
    /// of the column, and an absorbing briefing rendered as a 600pt card
    /// holding one sentence.
    static let dashboardColumns: [[DaylightModule]] = [
        [.claudeStatus, .fleet, .health],
        [.briefing, .mergeQueue],
    ]
    /// Track spans out of `HelmResponsiveGrid.dashboardColumns`: equal thirds.
    static let dashboardSpans = [4, 4, 4]
    /// A non-absorbing card's preference for its own height. Under the 499
    /// the row ties each column with, so a column's absorber takes the slack
    /// rather than a card being stretched, and above nothing else.
    static let dashboardKeepsOwnHeight = NSLayoutConstraint.Priority(490)
    /// The fewest Merge queue rows the page shows before it would rather
    /// scroll.
    static let mergeQueueMinimumRows = 2

    /// Is this space laid out by hand? Only the hub.
    var usesDashboardLayout: Bool { space == .overview && cardLayout == nil }

    /// Whether the hub's own layout applies.
    ///
    /// Split out so the layout and anything asking "is the dashboard on"
    /// cannot answer differently - a `usesDashboard` flag set beside the
    /// build is exactly the shape that drifts.
    ///
    /// `nil` from `dashboardRowViews` - the caller falls back to the
    /// wrapping grid - when the modules on screen are not the five this
    /// layout was written for. That is not a defensive flourish:
    /// `DaylightModule.appearsOnOverview` is a captain-editable list, and a
    /// sixth card added there must render *somewhere* rather than silently
    /// vanish.
    func dashboardRowViewsWouldApply(available: CGFloat, modules: [DaylightModule]) -> Bool {
        let expected = Set(Self.dashboardColumns.flatMap { $0 })
        // R5-UI-08: the briefing may be left off, and its column is then the
        // Merge queue alone.
        guard Set(modules) == expected || Set(modules) == expected.subtracting([.briefing]) else { return false }
        // Under this width a 4-track column is narrower than one wrapping
        // column, so hand back to the wrapping grid, which stacks every
        // widget full width. The app's 960pt minimum window keeps it on.
        return HelmResponsiveGrid.fitsProportionally(containerWidth: available,
                                                     spans: Self.dashboardSpans,
                                                     minItemWidth: Self.minModuleWidth,
                                                     spacing: Self.gridSpacing)
    }

    /// Everything the hub's layout decides from the data: each card's
    /// content (Fleet's note trimmed or not, Health listing its services or
    /// not, how many Merge queue rows fit) and the own height of each card
    /// that does not absorb its column's slack. Measured from probe cards, so
    /// a build and an in-place refresh (P2) agree on every number.
    struct DashboardPlan {
        var width: CGFloat
        var contents: [DaylightModule: HelmModuleCard.Content]
        var ownHeights: [DaylightModule: CGFloat]
    }

    func dashboardPlan(available: CGFloat) -> DashboardPlan {
        // PERF-03: whatever this plan does not read is stale - a module's
        // content moved on, or the width did - so it leaves the memo.
        probeKeysInUse = []
        defer {
            if let used = probeKeysInUse { probeHeights = probeHeights.filter { used.contains($0.key) } }
            probeKeysInUse = nil
        }
        let span = Self.dashboardSpans[0]
        let width = HelmResponsiveGrid.proportionalWidth(containerWidth: available, span: span,
                                                         spacing: Self.gridSpacing)
        let placement = CardPlacement.dashboard(span: span, width: width)
        let height = gridContainerHeight()

        // Column 2: Claude, Fleet and Health at their own heights, a spacer
        // under them taking what is left.
        // Fleet's sentence is the first thing to go when the column is
        // short - its chip already says whether anyone needs the captain.
        let claudeContent = content(for: .claudeStatus, placement: placement)
        var fleetContent = content(for: .fleet, placement: placement)
        var healthContent = content(for: .health, placement: placement)
        let claudeHeight = probeHeight(claudeContent, width: width)
        let healthHeight = probeHeight(healthContent, width: width)
        var fleetHeight = probeHeight(fleetContent, width: width)
        if claudeHeight + fleetHeight + healthHeight + Self.gridSpacing * 2 > height,
           case let .kpis(_, items) = fleetContent.body {
            fleetContent.body = .kpis(note: nil, items: items)
            fleetHeight = probeHeight(fleetContent, width: width)
        }
        // Health lists its services under the ring when the column holds
        // them; otherwise it stays the ring and its sentence.
        healthListsServices = true
        let listed = content(for: .health, placement: placement)
        healthListsServices = false
        if case .ringWithLines = listed.body,
           claudeHeight + fleetHeight + probeHeight(listed, width: width)
            + Self.gridSpacing * 2 <= height {
            healthContent = listed
        }

        // Column 3: as many Merge queue rows as the column holds under the
        // briefing, up to the card's own `maxPeekRows`; the briefing takes
        // what is left, below its paragraph.
        //
        // R5-UI-03 (R4-UI-10): uncapped, this listed 20 of 22 pull requests
        // in an 850pt card, where the sidebar layout's same card shows three
        // and a "Showing 3 of 22" footer. The cap is the sidebar's.
        let showsBriefing = Self.briefingHasSomethingToSay
        let briefingContent = content(for: .briefing, placement: placement)
        let briefingHeight = showsBriefing ? probeHeight(briefingContent, width: width) : 0
        mergeQueueRowLimit = min(HelmModuleCard.maxPeekRows,
                                 mergeQueueRows(budget: height - (showsBriefing ? briefingHeight + Self.gridSpacing : 0),
                                                placement: placement, width: width))
        let mergeContent = content(for: .mergeQueue, placement: placement)
        mergeQueueRowLimit = HelmModuleCard.maxPeekRows
        let mergeHeight = probeHeight(mergeContent, width: width)

        return DashboardPlan(
            width: width,
            contents: [.claudeStatus: claudeContent, .fleet: fleetContent, .health: healthContent,
                       .briefing: briefingContent, .mergeQueue: mergeContent],
            // UXP-04: Health keeps its own height too. It used to absorb its
            // column's slack, so at a narrow width - where it drops its
            // service rows - it kept the height it had with seven of them.
            ownHeights: [.claudeStatus: claudeHeight, .fleet: fleetHeight,
                         .health: probeHeight(healthContent, width: width),
                         .briefing: briefingHeight, .mergeQueue: mergeHeight])
    }

    func dashboardRowViews(available: CGFloat, modules: [DaylightModule]) -> [NSStackView]? {
        guard dashboardRowViewsWouldApply(available: available, modules: modules) else { return nil }
        let plan = dashboardPlan(available: available)
        let placement = CardPlacement.dashboard(span: Self.dashboardSpans[0], width: plan.width)
        func card(_ module: DaylightModule) -> HelmModuleCard {
            makeCard(for: module, content: plan.contents[module] ?? content(for: module, placement: placement),
                     placement: placement)
        }
        let claude = card(.claudeStatus)
        let fleet = card(.fleet)
        let health = card(.health)
        let merge = card(.mergeQueue)
        let thirdColumn: [(DaylightModule, HelmModuleCard)] = modules.contains(.briefing)
            ? [(.briefing, card(.briefing)), (.mergeQueue, merge)]
            : [(.mergeQueue, merge)]

        attentionCard.setLayoutWidth(plan.width)
        let row = HelmResponsiveGrid.proportionalRow(
            views: [dashboardAttentionColumn(),
                    dashboardColumn([(.claudeStatus, claude), (.fleet, fleet), (.health, health)],
                                    absorbing: nil, ownHeights: plan.ownHeights, width: plan.width),
                    dashboardColumn(thirdColumn,
                                    absorbing: nil, ownHeights: plan.ownHeights, width: plan.width)],
            spans: Self.dashboardSpans,
            containerWidth: available,
            spacing: Self.gridSpacing)
        return [row]
    }

    /// UXP-04: what takes a column's leftover height when no card should -
    /// page ground below the column's last card, rather than a card drawn
    /// taller than what it holds.
    static func columnSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        return spacer
    }

    /// Column 1: the attention card at its rows' height, then the page.
    ///
    /// UXP-04: the card used to *be* the column, so the row's height tie
    /// stretched it to the full page - three rows over a mostly empty card.
    func dashboardAttentionColumn() -> NSStackView {
        attentionCard.removeFromSuperview()
        let column = NSStackView(views: [attentionCard, Self.columnSpacer()])
        column.orientation = .vertical
        column.alignment = .leading
        column.distribution = .fill
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.defaultLow, for: .horizontal)
        column.setClippingResistancePriority(.defaultLow, for: .horizontal)
        let tie = attentionCard.widthAnchor.constraint(equalTo: column.widthAnchor)
        tie.priority = HelmDaylightPriority.contentTie
        tie.isActive = true
        return column
    }

    /// One page column: a vertical stack whose members fill its width, and
    /// whose every member but `absorbing` prefers its own height. With no
    /// absorber every card keeps its own height and a spacer below takes the
    /// rest (UXP-04).
    func dashboardColumn(_ members: [(DaylightModule, HelmModuleCard)], absorbing: DaylightModule?,
                                 ownHeights: [DaylightModule: CGFloat], width: CGFloat) -> NSStackView {
        let column = NSStackView(views: members.map(\.1))
        if absorbing == nil, let last = members.last?.1 {
            column.addArrangedSubview(Self.columnSpacer())
            // The spacer is page, not a card: no gap in front of it, or the
            // column is a spacing taller than its cards and a tight window
            // scrolls by exactly that.
            column.setCustomSpacing(0, after: last)
        }
        column.orientation = .vertical
        column.alignment = .leading
        column.distribution = .fill
        column.spacing = Self.gridSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (12)+(13): the stack-level APIs, both yielding, or this
        // column is a window-width floor.
        column.setHuggingPriority(.defaultLow, for: .horizontal)
        column.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for (module, card) in members {
            let tie = card.widthAnchor.constraint(equalTo: column.widthAnchor)
            tie.priority = HelmDaylightPriority.contentTie
            tie.isActive = true
            guard module != absorbing, let ownHeight = ownHeights[module] else { continue }
            let own = card.heightAnchor.constraint(equalToConstant: ownHeight)
            own.priority = Self.dashboardKeepsOwnHeight
            own.isActive = true
            dashboardOwnHeights[module] = own
        }
        return column
    }

    /// How many Merge queue rows fit `budget` points: every one that does,
    /// and never fewer than `mergeQueueMinimumRows`. Measured from two real
    /// cards rather than from a row height written down here, so a change to
    /// the peek row or the footer moves it with them.
    func mergeQueueRows(budget: CGFloat, placement: CardPlacement, width: CGFloat) -> Int {
        let minimum = Self.mergeQueueMinimumRows
        mergeQueueRowLimit = minimum
        let first = probeHeight(content(for: .mergeQueue, placement: placement), width: width)
        mergeQueueRowLimit = minimum + 1
        let second = probeHeight(content(for: .mergeQueue, placement: placement), width: width)
        let perRow = second - first
        guard perRow > 0.5 else { return minimum }
        let extra = Int(((budget - first) / perRow).rounded(.down))
        return max(minimum, minimum + extra)
    }

    /// A probe card's height, from the memo when the same content was
    /// measured at the same width (PERF-03).
    ///
    /// The key is the content's `layoutSignature` - every field that can move
    /// a card's height, so a changed reading is a new key rather than a stale
    /// hit - and the width. During a live resize the width is bucketed to
    /// `liveResizeProbeBucket`, so the frames of a drag share measurements;
    /// otherwise it is the exact width, so a settled page is budgeted from
    /// exactly the width it is shown at. Either way the probe is measured at
    /// the real width the first time its key is seen.
    func probeHeight(_ content: HelmModuleCard.Content, width: CGFloat) -> CGFloat {
        let widthKey = isInLiveResize
            ? (width / Self.liveResizeProbeBucket).rounded(.down) * Self.liveResizeProbeBucket
            : (width * 2).rounded() / 2
        let key = ProbeKey(signature: content.layoutSignature, width: widthKey)
        probeKeysInUse?.insert(key)
        if let height = probeHeights[key] {
            #if FM_SELFTESTS
            debugProbeMemoHits += 1
            #endif
            return height
        }
        #if FM_SELFTESTS
        debugProbeMeasurements += 1
        #endif
        let height = Self.fittingHeight(of: Self.probeCard(content), width: width)
        probeHeights[key] = height
        return height
    }

    /// The review's "width rounded to 8 pt": how far apart two live-resize
    /// frames may be and still share a probe measurement.
    static let liveResizeProbeBucket: CGFloat = 8

    /// The width pin `proportionalRow`/`spanningRows` put on a cell: a
    /// constant width at `contentTie`, on the view itself.
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
    /// `layout()` (gotcha (22)), so a bare `fittingSize` measures Fleet's
    /// two-line sentence as one line - measured, 6pt over at 960x620.
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

    func makeCard(for module: DaylightModule, placement: CardPlacement) -> HelmModuleCard {
        makeCard(for: module, content: content(for: module, placement: placement), placement: placement)
    }

    func makeCard(for module: DaylightModule, content: HelmModuleCard.Content,
                          placement: CardPlacement) -> HelmModuleCard {
        let card = HelmModuleCard()
        card.configure(content)
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
        cardPlacements[module] = placement
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
}
