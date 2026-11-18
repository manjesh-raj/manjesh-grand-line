// Grand Line - native macOS app.
//
// P9 of the Grand Line vs Automic Vault polish report: a page's own sidebar
// in a real split view.
//
// Seven pages drew their navigation column as a fixed-width view pinned
// beside their content. Automic Vault's `NavigationSplitView` gives the same
// column three things a pinned view cannot: a divider the captain can drag,
// a collapse that animates, and the standard Toggle Sidebar command. This is
// that, through `NSSplitViewController`.
//
// **What it deliberately does not take is the sidebar material.** The report
// suggested `NSSplitViewItem(sidebarWithViewController:)`, and that item puts
// an `NSVisualEffectView` with the sidebar material behind its pane - which
// composites against whatever is behind the *window* (AGENTS.md gotcha (8)),
// a tint none of the 26 palettes chose. Measured in an off-screen render of
// Schedules: the material drew as a black band around the pane and the
// column's rows did not draw at all. So the sidebar is a plain split item,
// and this controller supplies the one thing the sidebar behaviour would
// have given it, `toggleSidebar(_:)`. The pane paints the page ground for a
// page whose column floats as a card, and `HelmTheme.sidePanelFill` for a
// page whose column runs edge to edge. Each page looks the way it did; the
// column now behaves like a sidebar.
//
// The divider is the column's edge where a page already drew one, and clear
// where the column floats as a card and the gutter is the separation. It is
// dragged either way: AppKit keeps the resize cursor and the hit area for a
// clear divider.
//
// A collapsed sidebar's pane is hidden with zero width, so the constraints a
// page puts *inside* the pane must be able to give way. `pin(_:insets:)` is
// the one way in, and it holds the trailing edge below required for exactly
// that reason.
//
// **1.2.0: a column that gives way on a narrow page.** The hero-column pages
// (Health's H-4 and Connections' C-4 on the page-redesign board) put a 300pt
// gradient column in the sidebar pane, beside content that needs room of its
// own. `collapsesBelowWidth` puts the column away while the split's own view
// is narrower than that - a narrow window, or the shell's inspector opening -
// and brings it back when there is room again, without forgetting what the
// captain chose with Toggle Sidebar. The split's own width does not move when
// its sidebar collapses, so the rule cannot flap.
//
// For that the column must never be what holds the window open (gotcha
// (13)): a required column width beside content with a floor of its own made
// the window grow by 170pt when the inspector opened, so the split never saw
// a narrow width to collapse at. A page whose column gives way pins it with
// `pin(_:insets:yieldsWidth:)`, which holds the column's trailing edge under
// the window's 500, and gives the pane a low minimum, so the content's floor
// moves the divider rather than the window. The page sets
// `collapsesBelowWidth` to the column plus that floor, and the column comes
// back at `preferredSidebarWidth`. Reading the squeeze from the pane's frame
// instead was tried and measured wrong: `NSSplitView`'s own proportional
// resize runs before Auto Layout corrects it, so a pane reads squeezed for a
// pass on every resize.

import AppKit

/// A page whose sidebar lives in a `HelmSplitPage`, so the shell's Toggle
/// Sidebar command can reach it without knowing which page it is.
protocol HelmSplitPageHosting: AnyObject {
    var splitPage: HelmSplitPage? { get }
}

final class HelmSplitPage: NSSplitViewController {

    /// How the sidebar pane paints - see this file's header.
    enum SidebarSurface {
        /// The column floats on the page ground, and the gutter is the
        /// separation: a clear divider.
        case pageGround
        /// The column sits on the page ground with a hairline between it and
        /// the content (Tasks): the divider is that line.
        case pageGroundWithEdge
        /// The column runs edge to edge in its own fill, edged by the divider.
        case sidePanel
    }

    /// S05 of the 2026-11-17 UI/UX proposals (1.1.0): where a page's capped
    /// content column sits beside the sidebar.
    ///
    /// The cap is the same either way, and so is gotcha (13)'s mechanics -
    /// required maxima, a grow tie at `contentGrowPriority` (480), nothing
    /// that can be a floor on the window. Only the anchor differs.
    enum ContentAlignment {
        /// Centred in the visible space beside the sidebar, a `pageGutter`
        /// either side at least - the slack splits evenly.
        case centered
        /// Glued to the sidebar: `leadingContentGutter` from the content
        /// pane's edge, and the slack all on the right. What System Settings,
        /// Mail and Xcode's preferences do, and Settings' choice (the
        /// captain's call on S05): at 1512 the centred column left 155pt of
        /// ground between the nav and the page it shows.
        case leading
    }

    /// The gap between the sidebar's edge and a `.leading` column.
    static let leadingContentGutter: CGFloat = HelmMetrics.s6

    /// The position half of a capped column: what puts `column` inside
    /// `container` (the scroll view's clip view, gotcha (4)) for `alignment`.
    /// The caller still owns the cap (`width <=`) and the grow tie; these are
    /// the anchor and the two margins. Every constraint returned is a
    /// position or a maximum, so none of them can be a window floor
    /// (gotcha (13)).
    static func alignCappedColumn(_ column: NSView, in container: NSView,
                                  alignment: ContentAlignment) -> [NSLayoutConstraint] {
        switch alignment {
        case .centered:
            return [
                column.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                column.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor,
                                                constant: HelmMetrics.pageGutter),
                column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                 constant: -HelmMetrics.pageGutter),
            ]
        case .leading:
            return [
                column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingContentGutter),
                column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                 constant: -HelmMetrics.pageGutter),
            ]
        }
    }

    /// What a capped column's grow tie subtracts from its container's width:
    /// both margins, as `alignCappedColumn` lays them out.
    static func horizontalMargins(for alignment: ContentAlignment) -> CGFloat {
        switch alignment {
        case .centered: return 2 * HelmMetrics.pageGutter
        case .leading: return leadingContentGutter + HelmMetrics.pageGutter
        }
    }

    let sidebarPane = NSView()
    let contentPane = NSView()
    private let sidebarSurface: SidebarSurface
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var contentItem: NSSplitViewItem!
    private var themeToken: ThemeObservation?

    /// - Parameters:
    ///   - sidebarWidth: the pane's width when the page opens - the page's
    ///     column plus whatever gutter it sat in.
    ///   - minimum / maximum: how far the divider may be dragged.
    init(sidebarWidth: CGFloat, minimum: CGFloat, maximum: CGFloat, surface: SidebarSurface) {
        self.sidebarSurface = surface
        super.init(nibName: nil, bundle: nil)
        // The starting width is the pane's own frame when the split adopts
        // it, which the split then holds (see `holdingPriority` below). A
        // `setPosition` on the first layout pass was measured landing 16pt
        // short on Settings, because it ran inside a layout pass that was
        // still settling the page.
        sidebarPane.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: 600)
        contentPane.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let sidebarController = NSViewController()
        sidebarController.view = sidebarPane
        let contentController = NSViewController()
        contentController.view = contentPane
        sidebarPane.wantsLayer = true
        contentPane.wantsLayer = true

        let sidebar = NSSplitViewItem(viewController: sidebarController)
        sidebar.minimumThickness = minimum
        sidebar.maximumThickness = maximum
        sidebar.canCollapse = true
        // A collapse or a reopen moves the divider through constraints at the
        // sidebar's holding priority (489), under the window's own 500, so a
        // page's column never resizes the window (AGENTS.md gotcha (13)). The
        // default behaviour grows the window instead whenever the window's
        // minimum width plus the column would not fit, and in the sidebar
        // layout, with the shell's sidebar collapsed for room, that minimum
        // is the shell's 940pt content floor. Measured: Tasks' column coming
        // back for its board at 1100pt grew the window by the column's
        // 249pt, to 1349, where the floating bar shrank the content to 851;
        // a 500pt floor kept it at 1100 and an 860pt one grew it.
        sidebar.collapseBehavior = .useConstraints
        // The content takes what the window gains; the sidebar keeps its
        // width (a split view's own resizing rule, the same as Mail's).
        sidebar.holdingPriority = Self.sidebarHoldingPriority
        // No minimum on the content: a split item's minimum is a *required*
        // width, and a required width on a page is a floor on the window
        // (AGENTS.md gotcha (13)). The page's own content minimums, at 499,
        // already bound it; the sidebar's maximum bounds the divider.
        let content = NSSplitViewItem(viewController: contentController)
        content.holdingPriority = NSLayoutConstraint.Priority(250)
        addSplitViewItem(sidebar)
        addSplitViewItem(content)
        sidebarItem = sidebar
        contentItem = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let split = ThemedSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
        super.loadView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// Pin `child` inside `pane` at `insets`. The trailing and bottom edges
    /// sit just below required, so a collapsed (zero-width) pane can drop them
    /// rather than leave AppKit an unsatisfiable set to break at random.
    ///
    /// - Parameter yieldsWidth: 1.2.0: hold the trailing edge at
    ///   `yieldingPriority`, under the window's own 500, so a column with a
    ///   floor of its own overruns a squeezed pane for the moment before
    ///   `collapsesBelowWidth` puts it away, rather than growing the window.
    static func pin(_ child: NSView, in pane: NSView, insets: NSEdgeInsets, bottomIsCeiling: Bool = false,
                    yieldsWidth: Bool = false) {
        // A page's own column - directly, or inside a wrapper - takes the
        // pane's width rather than holding its own.
        yieldColumns(in: child)
        child.translatesAutoresizingMaskIntoConstraints = false
        if child.superview !== pane { pane.addSubview(child) }
        let trailing = child.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -insets.right)
        trailing.priority = yieldsWidth ? yieldingPriority : NSLayoutConstraint.Priority(999)
        let bottom = bottomIsCeiling
            ? child.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor, constant: -insets.bottom)
            : child.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -insets.bottom)
        bottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: insets.left),
            child.topAnchor.constraint(equalTo: pane.topAnchor, constant: insets.top),
            trailing,
            bottom,
        ])
    }

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    /// How firmly the sidebar keeps its width, and the ceiling for anything
    /// inside a page that would rather the divider moved.
    ///
    /// Measured, not chosen: a drag (and `setPosition`) moved the divider
    /// with the sidebar held at 489 and not at 495, so it has to stay under
    /// that. And it has to stay over anything in either pane that would
    /// rather the divider moved - at the default 250, Settings' two `contentTie`
    /// (499) grow ties jumped its column between its 214pt minimum and its
    /// 381pt maximum as the window widened. Those ties now sit at
    /// `contentGrowPriority` (480), and `HelmPageSidebar` yields its own 208
    /// preference inside a pane. Both well under 500, so neither can be a floor
    /// on the window (AGENTS.md gotcha (13)).
    static let sidebarHoldingPriority = NSLayoutConstraint.Priority(489)
    /// A yielding column's trailing pin (1.2.0): over the sidebar's hold, so
    /// it keeps the pane's width whenever the pane has one, and under the
    /// window's 500.
    static let yieldingPriority = NSLayoutConstraint.Priority(490)
    /// A yielding column's pane minimum: room to squeeze before it goes.
    static let yieldingMinimumThickness: CGFloat = 60

    /// 1.2.0: the narrowest `view` can be before its own constraints would
    /// hold the window open - only what is above the window's 500 counts, so
    /// a preferred width at a low priority (a search field's 460 at 251) does
    /// not. What a page adds to its column to get `collapsesBelowWidth`.
    /// `fittingSize` alone honours everything above 50, and overstated
    /// Connections' filter row by about 320pt.
    static func floorWidth(of view: NSView) -> CGFloat {
        let squeeze = view.widthAnchor.constraint(equalToConstant: 0)
        squeeze.priority = NSLayoutConstraint.Priority(501)
        squeeze.isActive = true
        defer { squeeze.isActive = false }
        return ceil(view.fittingSize.width)
    }
    static let contentGrowPriority = NSLayoutConstraint.Priority(480)

    private static func yieldColumns(in view: NSView) {
        if let column = view as? HelmPageSidebar { column.yieldWidthToContainer() }
        for sub in view.subviews { yieldColumns(in: sub) }
    }

    /// The thin divider's own width. A page that placed its content a fixed
    /// distance after its column subtracts this, so the content lands exactly
    /// where it did when the column was pinned.
    static let dividerThickness: CGFloat = 1

    /// The standard command (View > Show/Hide Sidebar, ⌃⌘S), animated - what
    /// a sidebar-behaviour item would have answered, for this plain one.
    override func toggleSidebar(_ sender: Any?) {
        // A column the page has put away is not the captain's to bring back
        // from here - Tasks' only belongs to its board.
        guard !collapseIsForced else { return }
        collapsedByCaptain.toggle()
        applyCollapse(animated: true)
        if !collapsedByCaptain { restorePreferredWidth() }
    }

    /// No drag handle on a column of one width (`preferredSidebarWidth`).
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard preferredSidebarWidth == nil else { return .zero }
        return super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect,
                               ofDividerAt: dividerIndex)
    }

    /// The captain's own choice, from Toggle Sidebar or a drag.
    private var collapsedByCaptain = false

    /// Set by a page whose column only belongs to some of its views (Tasks'
    /// column goes with its board). Forcing a collapse does not forget the
    /// captain's own choice: lifting it restores whatever they had.
    var pageForcesCollapse = false {
        didSet {
            guard pageForcesCollapse != oldValue else { return }
            applyCollapse(animated: false)
        }
    }

    /// 1.2.0: below this width of the split's own view the sidebar is put
    /// away, and above it the captain's own choice comes back. `nil` (the
    /// default) never collapses for width.
    var collapsesBelowWidth: CGFloat? {
        didSet { if collapsesBelowWidth != oldValue { evaluateWidth() } }
    }

    /// Whether `collapsesBelowWidth` is holding the sidebar away right now.
    private(set) var isNarrow = false

    /// 1.2.0: fired when the width rule is about to put the column away or
    /// bring it back, before the divider moves - so a page whose content
    /// floor depends on the column (Connections hides a button beside it)
    /// can change it first, and the reopening column never meets the wider
    /// floor.
    var onNarrowChanged: ((Bool) -> Void)?

    /// Whether the column would be open if the page let it - not put away
    /// by the width rule, and not by the captain.
    var sidebarIsWanted: Bool { !isNarrow && !collapsedByCaptain }

    /// 1.2.0: the pane's width when the column comes back from a narrow page
    /// (or is first given one). A column that yields was squeezed before it
    /// collapsed, and the split would otherwise reopen it at that width.
    ///
    /// A column with a preferred width has that one width: its divider does
    /// not drag, because a drag below the column's own floor would overrun
    /// it the way a squeeze does, with no width rule to put it away.
    var preferredSidebarWidth: CGFloat? {
        didSet { if preferredSidebarWidth != oldValue { restorePreferredWidth() } }
    }

    /// Move the divider to `preferredSidebarWidth`, a turn later, while the
    /// column is open - the way a drag would. Only ever asked for when the
    /// page has room for it (`evaluateWidth`), because the move outranks the
    /// window's own size.
    private func restorePreferredWidth() {
        guard preferredSidebarWidth != nil, !restoringWidth else { return }
        restoringWidth = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.restoringWidth = false
                if self.isViewLoaded { self.evaluateWidth() }
            }
            guard self.isViewLoaded, !self.sidebarItem.isCollapsed, let width = self.preferredSidebarWidth,
                  abs(self.sidebarPane.frame.width - width) > 0.5 else { return }
            self.splitView.setPosition(width, ofDividerAt: 0)
            self.view.layoutSubtreeIfNeeded()
        }
    }

    /// Whether anything other than the captain is holding the column away.
    private var collapseIsForced: Bool { pageForcesCollapse || isNarrow }

    private func applyCollapse(animated: Bool) {
        setSidebarCollapsed(collapseIsForced || collapsedByCaptain, animated: animated)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        evaluateWidth()
    }

    /// Set while the divider is on its way to `preferredSidebarWidth`.
    private var restoringWidth = false

    /// Re-read the width rule. The collapse itself waits a turn of the run
    /// loop: moving the divider inside the layout pass that measured the width
    /// would ask AppKit for a second pass from within the first.
    private func evaluateWidth() {
        let width = view.bounds.width
        let narrow = collapsesBelowWidth.map { width > 0 && width < $0 } ?? false
        if narrow != isNarrow {
            isNarrow = narrow
            DispatchQueue.main.async { [weak self] in
                self?.onNarrowChanged?(narrow)
                self?.applyCollapse(animated: false)
                if !narrow { self?.restorePreferredWidth() }
            }
        } else if !narrow, let preferred = preferredSidebarWidth, !restoringWidth, !sidebarItem.isCollapsed,
                  sidebarPane.frame.width > 0, sidebarPane.frame.width < preferred - 0.5 {
            // Open, with room, and short of its width: the pane's first width
            // was another column's, or it reopened at a squeezed one.
            restorePreferredWidth()
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // A drag that collapses or reopens the column is the captain's choice
        // too, unless the page is forcing it.
        // A column of one width has no drag (`preferredSidebarWidth`), so its
        // pane only collapses by Toggle Sidebar or by a squeeze, which is not
        // the captain's choice.
        if !collapseIsForced, preferredSidebarWidth == nil { collapsedByCaptain = sidebarItem.isCollapsed }
        reportCollapseIfChanged()
    }

    /// Fired when the column collapses or reopens, by any route: a page
    /// forcing it, Toggle Sidebar, or a drag. A page whose content placement
    /// depends on the column being there (Tasks, UXP-03) re-derives it here.
    var onSidebarCollapseChanged: ((Bool) -> Void)?
    private var lastReportedCollapse: Bool?

    private func reportCollapseIfChanged() {
        guard let item = sidebarItem, lastReportedCollapse != item.isCollapsed else { return }
        lastReportedCollapse = item.isCollapsed
        onSidebarCollapseChanged?(item.isCollapsed)
    }

    private func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        guard sidebarItem.isCollapsed != collapsed else { return }
        if animated, !HelmMotion.isReduced {
            // The split item's own animator proxy, which is how AppKit
            // animates a collapse - not `allowsImplicitAnimation`, which the
            // motion table bans (it does not animate layer properties).
            NSAnimationContext.runAnimationGroup { context in
                context.duration = HelmMotion.moveDuration
                sidebarItem.animator().isCollapsed = collapsed
            }
        } else {
            sidebarItem.isCollapsed = collapsed
        }
        reportCollapseIfChanged()
    }

    func applyTheme(_ theme: HelmTheme) {
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        let ground = HelmTheme.nsColor(theme.backgroundHex)
        sidebarPane.layer?.backgroundColor = (sidebarSurface == .sidePanel
            ? HelmTheme.sidePanelFill(theme) : ground).cgColor
        contentPane.layer?.backgroundColor = ground.cgColor
        (splitView as? ThemedSplitView)?.themedDividerColor = sidebarSurface == .pageGround
            ? .clear : HelmTheme.sidePanelEdge(theme)
        splitView.needsDisplay = true
    }

    #if FM_SELFTESTS
    var debugIsNarrow: Bool { isNarrow }
    var debugSidebarWidth: CGFloat { sidebarPane.frame.width }
    var debugDividerColor: NSColor { (splitView as? ThemedSplitView)?.themedDividerColor ?? .clear }
    #endif
}

/// An `NSSplitView` whose divider takes the theme's colour rather than the
/// system's.
final class ThemedSplitView: NSSplitView {
    var themedDividerColor: NSColor = .clear
    override var dividerColor: NSColor { themedDividerColor }
}

/// A view that paints but never takes a click - for a rule drawn over the
/// split's own divider, which has to keep receiving the drag.
final class HelmHitTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
