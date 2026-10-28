// Grand Line - native macOS app.
//
// The sidebar shell's inspector (stage 3 of the modular-shell migration).
//
// Step 3 of the full review's plan builds it empty: the split view's third
// pane, collapsed until the captain opens it from the toolbar. Stage 4 gives
// it content one module at a time - a selected host's connection details, a
// task's fields, a credential's history - which is where the pages' own
// "Selected" boxes and quick-edit modals go (UX-03, UX-05, UX-07).
//
// Until a page has something to show, the pane says so plainly rather than
// pretending a selection would fill it.
//
// A page that fills it (`WorkspaceInspectorSource`) hands over a view it owns
// and keeps filled; the pane hosts that view in a scroll view under its title
// line, which names the selected item.
//
// **Who paints the column (R2-ARCH-06).** On macOS 14 and later the shell
// hosts this controller in the system's inspector item
// (`NSSplitViewItem(inspectorWithViewController:)`), which AppKit lays out
// full height beside the content column and, on macOS 26, wraps in glass -
// the prototype's inspector, drawn by the system. There this controller
// paints no column of its own: the root and the panel stay clear so the
// system's surface shows, and the system draws the edge. Before macOS 14 the
// item gives none of that, so the shell hosts this controller in an ordinary
// split pane and it draws the column itself: a card-coloured panel under the
// toolbar with a hairline on its leading edge (`drawsOwnPane`).
//
// Either way the title line, the close button, the content and the entrance
// motion are the same views, so every check of what the inspector shows reads
// the same controller. One thing an off-screen render cannot show is the
// system's glass, which the window server composites: a render of the system
// path draws the inspector's content over a clear column. R2-PROC-07
// corrected an earlier claim here that the item does not exist on macOS 13;
// it does (macOS 11), and macOS 14 is where it becomes the full-height
// inspector, which is why that is the line.

import AppKit

final class WorkspaceInspectorController: NSViewController {

    /// The prototype's 320pt column.
    static let width: CGFloat = 320

    /// The close button's click, forwarded to the shell, which owns the
    /// split view item.
    var onClose: (() -> Void)?

    /// Whether this controller paints its own column - the hand-drawn pane
    /// the shell uses before macOS 14 - or leaves it to the system's
    /// inspector item. Set by the shell before the view loads.
    var drawsOwnPane = true {
        didSet { if isViewLoaded { applyTheme(ThemeManager.shared.theme) } }
    }

    private let panel = NSView()
    private let edge = NSView()
    private let titleLabel = NSTextField(labelWithString: "Inspector")
    private let closeButton = NSButton()
    private let divider = NSView()
    private let empty = HelmEmptyState(
        symbol: "sidebar.right",
        title: WorkspaceInspectorController.noDetailsTitle,
        body: WorkspaceInspectorController.noDetailsBody,
        size: .standard)
    /// The page's details, under the title line.
    private let contentScroll = NSScrollView()
    private let contentDocument = FlippedView()
    private weak var hostedView: NSView?
    private var themeToken: ThemeObservation?

    static let noDetailsTitle = "No details for this page"
    /// R4-UI-07: the modules whose pages fill the inspector, by the names the
    /// sidebar gives them (`ModuleTable`), not by an older page's title. It
    /// read "Hosts and Poneglyph" beside a sidebar that says Connections and
    /// Secrets, and left out Setup, whose Updates and GitHub sync fill it too.
    static let modulesWithDetails: [WorkspaceModule] = [.connections, .secrets, .setup]
    static var noDetailsBody: String {
        let names = modulesWithDetails.map(\.title)
        let list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        return "This page has nothing to show here. \(list) show the selected item's details."
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 600))
        root.wantsLayer = true
        view = root

        for sub in [panel, edge, divider] {
            sub.wantsLayer = true
            sub.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(panel)
        panel.addSubview(edge)

        titleLabel.font = .systemFont(ofSize: HelmType.scaled(13), weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = HelmSymbol.image("xmark", pointSize: HelmType.scaled(11), weight: .semibold)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close the inspector"
        closeButton.setAccessibilityLabel("Close inspector")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        empty.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.documentView = contentDocument
        contentScroll.hasVerticalScroller = true
        contentScroll.drawsBackground = false
        contentScroll.automaticallyAdjustsContentInsets = false
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.isHidden = true
        contentDocument.translatesAutoresizingMaskIntoConstraints = false
        for sub in [titleLabel, closeButton, divider, empty, contentScroll] as [NSView] { panel.addSubview(sub) }

        NSLayoutConstraint.activate([
            // Under the toolbar, like the content column beside it.
            panel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            edge.topAnchor.constraint(equalTo: panel.topAnchor),
            edge.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),

            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: HelmMetrics.s4),
            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: HelmMetrics.s3 + 2),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: HelmMetrics.s2),
            closeButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -HelmMetrics.s3),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            divider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: HelmMetrics.s3 - 2),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 1),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            empty.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: HelmMetrics.s5),
            empty.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -HelmMetrics.s5),

            contentScroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentScroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 1),
            contentScroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            contentScroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            // Pinned to the clip view, never the scroll view (gotcha (4)).
            contentDocument.leadingAnchor.constraint(equalTo: contentScroll.contentView.leadingAnchor),
            contentDocument.trailingAnchor.constraint(equalTo: contentScroll.contentView.trailingAnchor),
            contentDocument.topAnchor.constraint(equalTo: contentScroll.contentView.topAnchor),
        ])

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    @objc private func closeClicked() { onClose?() }

    /// Show `content`, or - with none - the page's own words for having
    /// nothing selected (`emptyText`), or the plain "no details" state for a
    /// page that never fills the pane.
    func setContent(_ content: WorkspaceInspectorContent?, emptyText: (title: String, body: String)? = nil) {
        _ = view
        if let content {
            titleLabel.stringValue = content.title
            if hostedView !== content.view {
                hostedView?.removeFromSuperview()
                let hosted = content.view
                hosted.removeFromSuperview()
                hosted.translatesAutoresizingMaskIntoConstraints = false
                if content.fillsPane {
                    // It scrolls itself, so it takes the whole area under the
                    // title line.
                    panel.addSubview(hosted)
                    NSLayoutConstraint.activate([
                        hosted.topAnchor.constraint(equalTo: divider.bottomAnchor),
                        hosted.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 1),
                        hosted.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                        hosted.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
                    ])
                } else {
                    contentDocument.addSubview(hosted)
                    NSLayoutConstraint.activate([
                        hosted.topAnchor.constraint(equalTo: contentDocument.topAnchor),
                        hosted.leadingAnchor.constraint(equalTo: contentDocument.leadingAnchor),
                        hosted.trailingAnchor.constraint(equalTo: contentDocument.trailingAnchor),
                        hosted.bottomAnchor.constraint(equalTo: contentDocument.bottomAnchor),
                    ])
                    contentScroll.contentView.scroll(to: .zero)
                }
                hostedView = hosted
            }
            contentScroll.isHidden = content.fillsPane
            empty.isHidden = true
        } else {
            hostedView?.removeFromSuperview()
            hostedView = nil
            titleLabel.stringValue = "Inspector"
            empty.setText(title: emptyText?.title ?? Self.noDetailsTitle, body: emptyText?.body ?? Self.noDetailsBody)
            contentScroll.isHidden = true
            empty.isHidden = false
        }
    }

    /// The view the pane is hosting, if any.
    var hostedContentView: NSView? { hostedView }

    /// The panel slides in from the trailing edge as the pane opens, or as it
    /// changes to another page's details - the prototype's inspector entrance
    /// (`WorkspaceMotion`). Nothing moves under Reduce Motion.
    func playEntrance() {
        _ = view
        WorkspaceMotion.slideIn(panel)
    }

    private func applyTheme(_ theme: HelmTheme) {
        // The system's inspector item draws the column and its edge itself,
        // so a fill here would cover it (gotcha (8)'s reasoning, inverted:
        // the system's surface is the right one in this case).
        view.layer?.backgroundColor = drawsOwnPane ? HelmTheme.nsColor(theme.backgroundHex).cgColor : nil
        panel.layer?.backgroundColor = drawsOwnPane ? HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor : nil
        let line = HelmDisplayAccessibility.strengthenedEdge(
            HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.borderAlpha), theme: theme)
        edge.layer?.backgroundColor = line.cgColor
        edge.isHidden = !drawsOwnPane
        divider.layer?.backgroundColor = line.withAlphaComponent(line.alphaComponent * HelmCard.dividerAlpha).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        closeButton.contentTintColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugCloseButton: NSButton { closeButton }
    var debugEmptyState: HelmEmptyState { empty }
    var debugIsShowingContent: Bool { hostedView != nil }
    var debugPanelLayer: CALayer? { panel.layer }
    var debugEdgeIsHidden: Bool { edge.isHidden }
    #endif
}
