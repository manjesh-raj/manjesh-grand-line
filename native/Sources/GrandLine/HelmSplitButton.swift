// Grand Line - native macOS app.
//
// `HelmSplitButton` - one action, and a menu of the other ways to do it, as
// one control (H8 of the captain's Termius-style plan).
//
// Connections' Add Host and New Key each had several ways in that only the
// menu bar listed: a new host, a quick connect, an import; a generated key,
// an imported file, a pasted key, a certificate. Termius puts them behind one
// split button, and so does this app now - one component for both, rather
// than two hand-built pairs (AGENTS.md, "The component index").
//
// What it is built from: two `HelmButton`s of the same variant, joined. The
// leading half is the main action. The trailing half is a chevron that opens
// the menu under the control. Each half keeps its own layer, so only the
// outer corners are rounded (`maskedCorners`), and a hairline in the
// button's own label colour divides them. Both halves are real buttons:
// keyboard reachable, with their own VoiceOver labels, and each fires
// through its own target and action - there is no recognizer on the
// container to swallow either click (gotcha (20)).
//
// In the window toolbar's overflow menu it lists the main action and then
// every menu item (`WorkspaceToolbarMenuRepresentable`).

import AppKit

final class HelmSplitButton: NSView, WorkspaceToolbarMenuRepresentable {

    struct Item {
        let title: String
        let symbol: String?
        /// Read each time the menu opens, so an item can follow the page's
        /// state (Attach Certificate needs a selected key).
        let isEnabled: () -> Bool
        let run: () -> Void

        init(_ title: String, symbol: String? = nil,
             isEnabled: @escaping () -> Bool = { true }, run: @escaping () -> Void) {
            self.title = title
            self.symbol = symbol
            self.isEnabled = isEnabled
            self.run = run
        }

        /// A separator between groups of items.
        static var separator: Item { Item("", run: {}) }
        var isSeparator: Bool { title.isEmpty }
    }

    let mainButton: HelmButton
    let menuButton: HelmButton
    private let divider = NSView()
    private let items: [Item]
    private let mainRun: () -> Void
    private let mainTitle: String
    private var themeObservation: ThemeObservation?

    /// - Parameters:
    ///   - title / symbol: the main action's label and glyph.
    ///   - menuLabel: what VoiceOver and the tooltip call the chevron
    ///     ("More ways to add a host").
    ///   - items: the menu, in order. `Item.separator` divides groups.
    init(title: String, symbol: String?, variant: HelmButton.Variant = .primary,
         size: HelmButton.Size = .small, menuLabel: String,
         items: [Item], action: @escaping () -> Void) {
        mainButton = HelmButton(title: title, variant: variant, size: size, symbol: symbol)
        menuButton = HelmButton(title: "", variant: variant, size: size, symbol: "chevron.down")
        self.items = items
        mainRun = action
        mainTitle = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        mainButton.target = self
        mainButton.action = #selector(mainClicked)
        menuButton.target = self
        menuButton.action = #selector(menuClicked)
        menuButton.toolTip = menuLabel
        menuButton.setAccessibilityLabel(menuLabel)
        menuButton.menuFormTitle = menuLabel

        divider.wantsLayer = true
        for view in [mainButton, menuButton, divider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for button in [mainButton, menuButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            mainButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainButton.topAnchor.constraint(equalTo: topAnchor),
            mainButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            menuButton.leadingAnchor.constraint(equalTo: mainButton.trailingAnchor, constant: Self.dividerWidth),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuButton.topAnchor.constraint(equalTo: topAnchor),
            menuButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            menuButton.widthAnchor.constraint(equalTo: menuButton.heightAnchor),
            divider.leadingAnchor.constraint(equalTo: mainButton.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: Self.dividerWidth),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        themeObservation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    static let dividerWidth: CGFloat = 1

    override func layout() {
        super.layout()
        // Only the outer corners round, so the two halves read as one
        // control. `HelmButton` sets the radius in its own `layout()`; the
        // mask is a separate property it never touches.
        let leading: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        let trailing: CACornerMask = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        for (button, corners) in [(mainButton, leading), (menuButton, trailing)] {
            button.layer?.maskedCorners = corners
            // A Daylight `.primary` paints a gradient sublayer with its own
            // radius; it takes the same mask, or the inner corners notch.
            button.layer?.sublayers?.forEach { $0.maskedCorners = corners }
        }
    }

    private func applyTheme(_ theme: HelmTheme) {
        // The halves' own fill, a step darker: a seam, not a gap.
        let fill = mainButton.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
            ?? HelmTheme.nsColor(theme.accentHex)
        divider.layer?.backgroundColor = (fill.blended(withFraction: 0.25, of: .black) ?? fill).cgColor
        needsLayout = true
    }

    // MARK: Actions

    @objc private func mainClicked() { mainRun() }

    @objc private func menuClicked() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: -mainButton.frame.width - Self.dividerWidth,
                                                       y: menuButton.bounds.maxY + HelmMetrics.s1),
                         in: menuButton)
    }

    /// The chevron's menu. Built fresh each time it opens, so every item's
    /// `isEnabled` is read now.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item.title, action: #selector(HelmSplitButtonItemBox.fire), keyEquivalent: "")
            let box = HelmSplitButtonItemBox(item.run)
            entry.target = box
            entry.representedObject = box
            entry.isEnabled = item.isEnabled()
            if let symbol = item.symbol { entry.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(12)) }
            menu.addItem(entry)
        }
        return menu
    }

    func workspaceToolbarMenuItems() -> [NSMenuItem] {
        var out = [WorkspaceToolbar.closureItem(mainTitle) { [weak self] in self?.mainRun() }]
        for item in items {
            if item.isSeparator { out.append(.separator()); continue }
            let entry = WorkspaceToolbar.closureItem(item.title, item.run)
            entry.isEnabled = item.isEnabled()
            out.append(entry)
        }
        return out
    }

    #if FM_SELFTESTS
    var debugMenuTitles: [String] { makeMenu().items.map { $0.isSeparatorItem ? "-" : $0.title } }
    /// Fire one menu item through its own target and action, as picking it
    /// does.
    @discardableResult
    func debugPick(_ title: String) -> Bool {
        guard let item = makeMenu().items.first(where: { $0.title == title }), item.isEnabled,
              let action = item.action, let target = item.target as? NSObject else { return false }
        target.perform(action, with: item)
        return true
    }
    func debugIsEnabled(_ title: String) -> Bool? { makeMenu().items.first { $0.title == title }?.isEnabled }
    var debugDivider: NSView { divider }
    #endif
}

/// A menu item's closure, held by the item itself (`representedObject`) so
/// it lives exactly as long as the menu.
private final class HelmSplitButtonItemBox: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
