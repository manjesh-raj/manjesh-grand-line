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
// It is an ordinary split pane under the toolbar, a card-coloured column with
// a hairline on its leading edge - the prototype's shape - rather than
// macOS 14's full-height inspector item: that one is drawn as glass the
// window server composites, which this app's off-screen renders cannot
// capture, and it does not exist on macOS 13, which this app still supports.

import AppKit

final class WorkspaceInspectorController: NSViewController {

    /// The prototype's 320pt column.
    static let width: CGFloat = 320

    /// The close button's click, forwarded to the shell, which owns the
    /// split view item.
    var onClose: (() -> Void)?

    private let panel = NSView()
    private let edge = NSView()
    private let titleLabel = NSTextField(labelWithString: "Inspector")
    private let closeButton = NSButton()
    private let divider = NSView()
    private let empty = HelmEmptyState(
        symbol: "sidebar.right",
        title: "No details for this page",
        body: "This page does not use the inspector yet. Pages show the selected item's details here as they move into modules.",
        size: .standard)
    private var themeToken: ThemeObservation?

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
        for sub in [titleLabel, closeButton, divider, empty] as [NSView] { panel.addSubview(sub) }

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
        ])

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    @objc private func closeClicked() { onClose?() }

    private func applyTheme(_ theme: HelmTheme) {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        panel.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        let line = HelmDisplayAccessibility.strengthenedEdge(
            HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.borderAlpha), theme: theme)
        edge.layer?.backgroundColor = line.cgColor
        divider.layer?.backgroundColor = line.withAlphaComponent(line.alphaComponent * HelmCard.dividerAlpha).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        closeButton.contentTintColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugCloseButton: NSButton { closeButton }
    var debugEmptyState: HelmEmptyState { empty }
    #endif
}
