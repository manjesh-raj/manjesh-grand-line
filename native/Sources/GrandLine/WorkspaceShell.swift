// Grand Line - native macOS app.
//
// The Workspace shell's frame: a split view of the sidebar (the map), the
// content column (the module's tab strip over the showing page), and an
// inspector for the selected item.
//
// UX-01 and UX-12 of the 2026-10 review, design A. `AppShellController` still
// owns navigation, the destination mounter and every page; this file only
// gives them a frame the system draws:
//
//   - `WorkspaceSplitController` is an `NSSplitViewController` whose first
//     item is the sidebar, whose second is the content column, and whose
//     third is the inspector, collapsed until a module has something
//     selected to show. The window is full-size-content, so the sidebar runs
//     the full height of the window under the traffic lights, and the
//     toolbar's tracking separator keeps the title over the content column.
//   - `WorkspaceContentPane` is the content column's view: a hairline under
//     the toolbar, the module's tab strip when the module has more than one
//     tab, and the body container every page is mounted into.
//   - `WorkspaceModuleTabs` is that tab strip.
//
// **The sidebar is a plain split item, not `NSSplitViewItem(sidebarWith...)`**,
// for the reason `HelmSplitPage`'s header measured and one more: the
// sidebar behaviour puts the system's material behind the pane (a tint none
// of the 26 palettes chose, which an off-screen render draws as a black
// band), and on macOS 26 it floats the pane as an inset glass panel -
// measured, an 8pt inset and a 190pt view inside a 198pt container that the
// split would not hold at its opening width. The prototype the captain chose
// draws a flush, full-height column, so the column is flush and Helm-painted,
// and this controller supplies the two behaviours the sidebar item would
// have: Toggle Sidebar, and a divider the toolbar can track.

import AppKit

// MARK: - The module tab strip

/// One module's tabs, folder-style: the selected tab is a card-coloured
/// rounded tab open at the bottom, sitting on a hairline that runs the width
/// of the column.
final class WorkspaceModuleTabs: NSView {
    static let height: CGFloat = 34

    var onSelect: ((Int) -> Void)?

    private let stack = NSStackView()
    private var buttons: [NSButton] = []
    private var titles: [String] = []
    private(set) var selectedIndex = 0
    private var line = NSColor.clear
    private var card = NSColor.clear
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .bottom
        stack.spacing = 2
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Module tabs")
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    func configure(titles newTitles: [String], selected: Int) {
        if newTitles != titles {
            titles = newTitles
            buttons.forEach { $0.removeFromSuperview() }
            buttons = newTitles.enumerated().map { index, title in
                let button = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
                button.tag = index
                button.isBordered = false
                button.setButtonType(.momentaryChange)
                button.translatesAutoresizingMaskIntoConstraints = false
                button.heightAnchor.constraint(equalToConstant: Self.height - 1).isActive = true
                button.setAccessibilityRole(.radioButton)
                stack.addArrangedSubview(button)
                return button
            }
        }
        setSelected(selected)
    }

    func setSelected(_ index: Int) {
        selectedIndex = index
        applyTheme(ThemeManager.shared.theme)
    }

    @objc private func tabClicked(_ sender: NSButton) {
        onSelect?(sender.tag)
    }

    private func applyTheme(_ theme: HelmTheme) {
        line = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(theme.isDaylight ? 1.0 : 0.6)
        card = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.card)
            : HelmTheme.nsColor(theme.chromeBackgroundHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedIndex
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let title = titles.indices.contains(index) ? titles[index] : button.title
            button.attributedTitle = NSAttributedString(string: "  \(title)  ", attributes: [
                .font: NSFont.systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold),
                .foregroundColor: selected ? ink : muted,
                .paragraphStyle: paragraph,
            ])
            button.setAccessibilityValue(selected ? 1 : 0)
            button.setAccessibilityLabel(title)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard buttons.indices.contains(selectedIndex) else { return }
        layoutSubtreeIfNeeded()
        let tab = convert(buttons[selectedIndex].bounds, from: buttons[selectedIndex])
            .insetBy(dx: -4, dy: 0)
        let radius: CGFloat = HelmMetrics.rControl
        // The hairline across the column, broken under the selected tab.
        line.setFill()
        NSRect(x: bounds.minX, y: 0, width: max(0, tab.minX - bounds.minX), height: 1).fill()
        NSRect(x: tab.maxX, y: 0, width: max(0, bounds.maxX - tab.maxX), height: 1).fill()
        // The selected tab: open at the bottom, rounded at the top.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: tab.minX, y: 0))
        path.line(to: NSPoint(x: tab.minX, y: tab.maxY - radius))
        path.appendArc(withCenter: NSPoint(x: tab.minX + radius, y: tab.maxY - radius), radius: radius,
                       startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: tab.maxX - radius, y: tab.maxY))
        path.appendArc(withCenter: NSPoint(x: tab.maxX - radius, y: tab.maxY - radius), radius: radius,
                       startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: tab.maxX, y: 0))
        card.setFill()
        path.fill()
        line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    #if FM_SELFTESTS
    var debugTitles: [String] { titles }
    func debugClick(_ index: Int) { buttons[index].performClick(nil) }
    #endif
}

/// The module's name and the page's live line, in the toolbar band at the
/// leading edge of the content column - design A's toolbar title.
///
/// Drawn by the content column under the transparent titlebar rather than by
/// the system, for two measured reasons. AppKit places the window's own title
/// after a tracking separator only when the split's first item is a
/// sidebar-behaviour item, and this shell's is not (see this file's header) -
/// the system title sat over the sidebar. And a title given to the toolbar as
/// a view item is wrapped in macOS 26's glass capsule, which is a button's
/// chrome, not a title's. The window's `title` still names the module, so
/// Mission Control, the Window menu and VoiceOver's window name are unchanged.
final class WorkspaceTitleView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = HelmMetrics.s2 + 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let preferred = widthAnchor.constraint(equalToConstant: 520)
        preferred.priority = NSLayoutConstraint.Priority(300)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            preferred,
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    func configure(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        toolTip = subtitle.isEmpty ? title : "\(title) - \(subtitle)"
        setAccessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }

    private func applyTheme(_ theme: HelmTheme) {
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(15), weight: .bold)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .medium)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugSubtitle: String { subtitleLabel.isHidden ? "" : subtitleLabel.stringValue }
    #endif
}

// MARK: - The root

/// The shell's root view, with a layout hook: the body's width-tie repair
/// rides every layout pass of the window's content, because a layout pass is
/// when a constraint conflict resolves (`AppShellController.
/// reassertBodyContainerWidthTie`).
final class WorkspaceRootView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - The content column

/// The content column's view: the hairline under the toolbar, the module's
/// tab strip, and the body every page mounts into.
final class WorkspaceContentPane: NSView {
    let moduleTabs = WorkspaceModuleTabs()
    /// The module's name and the page's line, in the toolbar band.
    let titleView = WorkspaceTitleView()
    /// What `AppShellController` mounts every destination into. Its edges are
    /// that controller's to pin (it re-asserts the width tie on its own; see
    /// `reassertBodyContainerWidthTie`).
    let bodyHost = NSView()

    /// Fired on every layout pass, so the shell's width-tie repair can ride the
    /// pass in which a conflict resolves (the reason the old root view had
    /// the same hook).
    var onLayout: (() -> Void)?

    /// A toolbar control the title must not run under - the sidebar button,
    /// which the toolbar pushes past the divider when the icon-only column is
    /// too narrow to hold it beside the traffic lights.
    weak var titleObstacle: NSView?
    private var titleLeading: NSLayoutConstraint!

    private let toolbarRule = NSView()
    private var tabsHeight: NSLayoutConstraint!
    private var tabsTopGap: NSLayoutConstraint!
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for view in [toolbarRule, moduleTabs, bodyHost, titleView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The band the toolbar occupies: from the column's top to its safe
        // area. The title is centred in it, beside the toolbar's own items.
        let band = NSLayoutGuide()
        addLayoutGuide(band)
        titleLeading = titleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.titleInset)
        toolbarRule.wantsLayer = true
        tabsHeight = moduleTabs.heightAnchor.constraint(equalToConstant: 0)
        tabsTopGap = moduleTabs.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 0)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: topAnchor),
            band.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            titleView.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            titleLeading,
            titleView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.45),
            toolbarRule.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            toolbarRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarRule.heightAnchor.constraint(equalToConstant: 1),
            tabsTopGap,
            tabsHeight,
            moduleTabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.pageGutter),
            moduleTabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.pageGutter),
            bodyHost.topAnchor.constraint(equalTo: moduleTabs.bottomAnchor),
            bodyHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        moduleTabs.isHidden = true
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    /// Show the strip for a module with more than one tab, or collapse it.
    func setTabs(_ titles: [String], selected: Int) {
        let show = titles.count > 1
        moduleTabs.isHidden = !show
        tabsHeight.constant = show ? WorkspaceModuleTabs.height : 0
        tabsTopGap.constant = show ? HelmMetrics.s3 : 0
        if show { moduleTabs.configure(titles: titles, selected: selected) }
    }

    static let titleInset: CGFloat = HelmMetrics.s5 - 4

    override func layout() {
        super.layout()
        // Step the title past the sidebar button when the toolbar has put
        // that button over this column (the icon-only sidebar).
        var leading = Self.titleInset
        if let obstacle = titleObstacle, obstacle.window === window, window != nil {
            let frame = convert(obstacle.convert(obstacle.bounds, to: nil), from: nil)
            if frame.maxX > 0, frame.minX < bounds.width / 2 {
                leading = max(leading, frame.maxX + HelmMetrics.s3)
            }
        }
        if abs(titleLeading.constant - leading) > 0.5 { titleLeading.constant = leading }
        onLayout?()
    }

    private func applyTheme(_ theme: HelmTheme) {
        appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        toolbarRule.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(theme.isDaylight ? 0.8 : 0.45).cgColor
    }

    #if FM_SELFTESTS
    var debugTabsAreShown: Bool { !moduleTabs.isHidden && tabsHeight.constant > 0 }
    #endif
}

// MARK: - The split

final class WorkspaceSplitController: NSSplitViewController {

    let sidebar: WorkspaceSidebarController
    let contentPane: WorkspaceContentPane
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var contentItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    private let inspectorHost = WorkspaceInspectorHost()
    private weak var inspectorContent: NSViewController?


    static let inspectorWidth: CGFloat = 320

    init(sidebar: WorkspaceSidebarController, contentPane: WorkspaceContentPane) {
        self.sidebar = sidebar
        self.contentPane = contentPane
        super.init(nibName: nil, bundle: nil)
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

    private var themeToken: ThemeObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        // A fixed column, the prototype's 232pt (56pt as icons). Its minimum
        // and maximum are the same number, because a held width is not enough
        // here: every page states its own width preferences at 499 (AGENTS.md
        // gotcha (13)'s band), above any holding priority a draggable divider
        // can have (under 490), so a narrower window squeezed the sidebar to
        // its minimum while the page kept its preferred width - measured, 190pt
        // in a 1300pt window. A fixed column leaves the page to absorb the
        // change, which is what it did before there was a sidebar at all.
        sidebar.view.frame.size.width = WorkspaceSidebarController.expandedWidth
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = WorkspaceSidebarController.expandedWidth
        sidebarItem.maximumThickness = WorkspaceSidebarController.expandedWidth
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = HelmSplitPage.sidebarHoldingPriority

        let contentController = NSViewController()
        contentController.view = contentPane
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.holdingPriority = NSLayoutConstraint.Priority(250)

        let inspectorController = NSViewController()
        inspectorController.view = inspectorHost
        inspectorHost.frame.size.width = Self.inspectorWidth
        let inspectorItem: NSSplitViewItem
        if #available(macOS 14.0, *) {
            inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        } else {
            inspectorItem = NSSplitViewItem(viewController: inspectorController)
        }
        inspectorItem.minimumThickness = 280
        inspectorItem.maximumThickness = 420
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(270)
        inspectorItem.isCollapsed = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
        self.sidebarItem = sidebarItem
        self.contentItem = contentItem
        self.inspectorItem = inspectorItem

        themeToken = ThemeManager.shared.observe { [weak self] theme in
            guard let split = self?.splitView as? ThemedSplitView else { return }
            // The sidebar draws its own edge, so the divider beside it is the
            // same hairline rather than the system's grey.
            split.themedDividerColor = HelmTheme.sidePanelEdge(theme)
            split.needsDisplay = true
        }
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    // MARK: Toggle Sidebar

    /// ⌥⌘S and the toolbar's sidebar button. The split item's own animator
    /// proxy is how AppKit animates a collapse; Reduce Motion gets the end
    /// state at once.
    override func toggleSidebar(_ sender: Any?) {
        let collapse = !sidebarItem.isCollapsed
        if !HelmMotion.isReduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = HelmMotion.moveDuration
                sidebarItem.animator().isCollapsed = collapse
            }
        } else {
            sidebarItem.isCollapsed = collapse
        }
    }

    // MARK: Compact sidebar

    /// Icons only below `WorkspaceSidebarController.compactBelowWindowWidth`.
    func setSidebarCompact(_ compact: Bool) {
        guard isViewLoaded, compact != sidebar.isCompact else { return }
        sidebar.setCompact(compact)
        let width = compact ? WorkspaceSidebarController.compactWidth : WorkspaceSidebarController.expandedWidth
        // Lowering first and raising second keeps minimum <= maximum at every
        // step, which AppKit requires of a split item.
        if compact {
            sidebarItem.minimumThickness = width
            sidebarItem.maximumThickness = width
        } else {
            sidebarItem.maximumThickness = width
            sidebarItem.minimumThickness = width
        }
        if !sidebarItem.isCollapsed {
            splitView.setPosition(width, ofDividerAt: 0)
        }
    }

    // MARK: Inspector

    /// Show `controller` in the inspector, or collapse it for `nil`.
    func setInspector(_ controller: NSViewController?, animated: Bool = false) {
        if controller !== inspectorContent {
            inspectorContent?.view.removeFromSuperview()
            inspectorContent?.removeFromParent()
            inspectorContent = controller
            if let controller {
                addChild(controller)
                inspectorHost.embed(controller.view)
            }
        }
        let collapse = controller == nil
        guard inspectorItem.isCollapsed != collapse else { return }
        if animated && !HelmMotion.isReduced {
            inspectorItem.animator().isCollapsed = collapse
        } else {
            inspectorItem.isCollapsed = collapse
        }
    }

    var inspectorIsShown: Bool { !(inspectorItem?.isCollapsed ?? true) }
}

/// The inspector's ground: the card surface, edged on its leading side.
final class WorkspaceInspectorHost: NSView {
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themeToken = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.layer?.backgroundColor = (theme.isDaylight
                ? HelmTheme.nsColor(theme.daylightTokens.card)
                : HelmTheme.nsColor(theme.chromeBackgroundHex)).cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    func embed(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// A page that offers an inspector for its selected item. The shell asks on
/// every navigation and when the page says its selection changed.
protocol WorkspaceInspectorProviding: AnyObject {
    /// The inspector for what is selected now, or `nil` to collapse it.
    var workspaceInspector: NSViewController? { get }
    /// Set by the shell; the page calls it when its selection changes.
    var onWorkspaceInspectorChanged: (() -> Void)? { get set }
}

// MARK: - The window's chrome

/// UX-12: the main window wears a visible system title and a unified
/// `NSToolbar`, and its traffic lights stay where AppKit puts them.
///
/// The titlebar is transparent so the toolbar sits on the app's own ground
/// (the sidebar's fill over the sidebar, the page ground over the content
/// column) rather than on the system's window chrome colour, which none of
/// the 26 palettes chose; the content column draws the hairline under it.
enum WorkspaceWindowChrome {
    static func apply(to window: NSWindow, toolbar: NSToolbar) {
        window.styleMask.insert(.fullSizeContentView)
        // The title is drawn by the toolbar's own title item over the
        // content column (`WorkspaceTitleView`); `window.title` still names
        // the module for Mission Control, the Window menu and VoiceOver.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = false
        }
    }
}
