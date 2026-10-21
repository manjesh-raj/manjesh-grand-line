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
    static func pin(_ child: NSView, in pane: NSView, insets: NSEdgeInsets, bottomIsCeiling: Bool = false) {
        // A page's own column - directly, or inside a wrapper - takes the
        // pane's width rather than holding its own.
        yieldColumns(in: child)
        child.translatesAutoresizingMaskIntoConstraints = false
        if child.superview !== pane { pane.addSubview(child) }
        let trailing = child.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -insets.right)
        trailing.priority = NSLayoutConstraint.Priority(999)
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
        guard !pageForcesCollapse else { return }
        collapsedByCaptain.toggle()
        applyCollapse(animated: true)
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

    private func applyCollapse(animated: Bool) {
        setSidebarCollapsed(pageForcesCollapse || collapsedByCaptain, animated: animated)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // A drag that collapses or reopens the column is the captain's choice
        // too, unless the page is forcing it.
        if !pageForcesCollapse { collapsedByCaptain = sidebarItem.isCollapsed }
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
