// Manjesh Grand Line - native macOS app.
//
// `DaylightBarController` - the floating top bar (migration §5.2, §6.3).
//
// **What it replaces.** Both `IconRailController` (an 84pt full-height icon
// rail) and `TopBarController` (a 52pt destination-title strip) are gone;
// this one 50pt floating bar is the whole navigation chrome. That is §5.1's
// "what dies" list, and it is the single largest structural change in the
// Daylight migration.
//
// **What it deliberately does NOT do.** It owns no destination state, no
// store, and no notion of what a space *means*. It draws five pills, reports
// which one was clicked, and hosts the bell and avatar popovers that already
// existed. `HomeCanvasController` owns the selected space; `AppShellController`
// owns navigation. That split is what keeps §5.3's rule true - "no store,
// poller or registry knows spaces exist".
//
// **No `NSVisualEffectView`, and this is not a stylistic call.** The
// prototype's bar is blurred glass; AGENTS.md gotcha (8) is this codebase's
// single most-repeated bug class, and `.behindWindow` vibrancy composites
// against the *desktop*, not against the window's own content, so a bar built
// that way renders the wrong tint on every theme. §6.3 says so explicitly:
// "a solid fill with a shadow reads 95% the same. The blur in the prototype
// is a web nicety, not a requirement."
//
// **Window-size safety (AGENTS.md gotcha (13)).** A window only holds its own
// size at priority 500, so any content constraint above that is a window-width
// cap. This bar spans the full window width, which makes it the single most
// dangerous new surface in this phase for that class of bug: every label in it
// gets `.defaultLow` compression resistance, the search pill is the designated
// first thing to yield, and the one place a real floor could appear (the pill
// row) is tied at `HelmDaylightPriority.contentTie` (499).
// `DaylightModuleSelfTest.checkBarDoesNotCapWindow` measures that against a
// real window rather than trusting the reasoning.

import AppKit

final class DaylightBarController: NSViewController {

    // §6.3's geometry, exactly.
    static let height: CGFloat = 50
    static let topMargin: CGFloat = 14
    static let sideMargin: CGFloat = 22
    /// The gap between the bar's bottom edge and the body area beneath it
    /// (§2.7: "Drill page: ... top margin under the bar 20").
    static let contentGap: CGFloat = 20

    /// Everything the shell needs to reserve above the body container.
    static var reservedTopHeight: CGFloat { topMargin + height + contentGap }

    /// §6.3's own stated floor: "the bar needs roughly 700pt to lay out".
    static let comfortableWidth: CGFloat = 700

    // MARK: Callbacks (forward, never own)

    /// A space pill was picked. `AppShellController` turns this into
    /// "navigate to the canvas, then filter" - this controller does not know
    /// what a canvas is.
    var onSelectSpace: ((DaylightSpace) -> Void)?
    /// The search pill / its ⌘K badge - forwarded exactly as
    /// `TopBarController.onSearchTapped` was.
    var onSearchTapped: (() -> Void)?
    /// The avatar popover's two rows. Unchanged behaviour, moved off the
    /// rail's avatar onto this bar's.
    var onSelectSettings: (() -> Void)?
    var onLogoutRequested: (() -> Void)?

    /// The bell keeps its own store, adapters and dedup logic untouched -
    /// only its trigger location moved.
    let notificationCenter = NotificationCenterController()

    private let bar = NSView()
    private let logoTile = HelmGradientTile(size: .logo)
    private let wordmark = NSTextField(labelWithString: "Grand Line")
    private let searchPill = DaylightSearchPill()
    /// The light/dark quick-toggle, moved here from Console's own toolbar
    /// (`fm/grandline-daylight-theme-toggle-relocate`) - it flips the whole
    /// app's theme, not just one page's, so it belongs on the app-wide bar
    /// rather than a per-destination toolbar. Sits between the search pill
    /// and the bell, matching the captain's own reviewed layout.
    private let themeToggleButton = DaylightThemeToggleButton()
    private let avatar = HoverTrackingButton()
    private let avatarGradient = CAGradientLayer()
    private let avatarPopover = NSPopover()

    private var pills: [SpacePill] = []
    private var selectedSpace: DaylightSpace = .overview
    private var themeToken: ThemeObservation?

    private struct SpacePill {
        let space: DaylightSpace
        let container: HoverHighlightView
        let label: NSTextField
    }

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: Self.height + Self.topMargin))
        root.wantsLayer = true
        view = root

        bar.wantsLayer = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        // The shadow host must not clip (§2.5). The bar has no children that
        // need clipping - every pill rounds its own layer - so unlike
        // `HelmModuleCard` this needs no second layer.
        bar.layer?.masksToBounds = false
        bar.layer?.cornerRadius = HelmMetrics.dBar
        bar.layer?.borderWidth = 1
        root.addSubview(bar)

        logoTile.configure(symbol: "sailboat.fill", hue: .blue)
        wordmark.font = HelmType.rounded(HelmType.scaled(14.5), .heavy)
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        wordmark.lineBreakMode = .byTruncatingTail
        wordmark.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let logoRow = NSStackView(views: [logoTile, wordmark])
        logoRow.orientation = .horizontal
        logoRow.alignment = .centerY
        logoRow.spacing = HelmMetrics.s2
        logoRow.distribution = .fill
        logoRow.translatesAutoresizingMaskIntoConstraints = false
        logoRow.setHuggingPriority(.required, for: .horizontal)

        let pillRow = buildPillRow()

        searchPill.translatesAutoresizingMaskIntoConstraints = false
        searchPill.onClick = { [weak self] in self?.onSearchTapped?() }
        // §6.3: "give the search pill `.defaultLow` compression so it yields
        // before pills". This is the one control on the bar that is allowed
        // to shrink, and saying so here is what keeps a narrow window from
        // truncating the navigation instead.
        searchPill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchPill.setContentHuggingPriority(.defaultLow, for: .horizontal)

        themeToggleButton.target = self
        themeToggleButton.action = #selector(themeToggleClicked)

        buildAvatar()

        bar.addSubview(logoRow)
        bar.addSubview(pillRow)
        bar.addSubview(searchPill)
        bar.addSubview(themeToggleButton)
        bar.addSubview(notificationCenter.bell)
        bar.addSubview(avatar)

        let inset: CGFloat = 12

        // The horizontal chain is deliberately *not* one stack: the pills sit
        // just after the logo (leading-anchored), the trailing cluster is
        // trailing-anchored, and the gap between them is an inequality - so a
        // narrow window compresses the gap to nothing before anything is asked
        // to truncate, and nothing here can push the window wider.
        let pillsToSearch = searchPill.leadingAnchor.constraint(
            greaterThanOrEqualTo: pillRow.trailingAnchor, constant: HelmMetrics.s3)
        pillsToSearch.priority = HelmDaylightPriority.contentTie

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.sideMargin),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.sideMargin),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.topMargin),
            bar.heightAnchor.constraint(equalToConstant: Self.height),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            logoRow.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: inset),
            logoRow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            pillRow.leadingAnchor.constraint(equalTo: logoRow.trailingAnchor, constant: HelmMetrics.s5),
            pillRow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            pillsToSearch,
            searchPill.trailingAnchor.constraint(equalTo: themeToggleButton.leadingAnchor, constant: -HelmMetrics.s2),
            searchPill.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            themeToggleButton.trailingAnchor.constraint(equalTo: notificationCenter.bell.leadingAnchor, constant: -HelmMetrics.s2),
            themeToggleButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            themeToggleButton.widthAnchor.constraint(equalToConstant: DaylightThemeToggleButton.side),
            themeToggleButton.heightAnchor.constraint(equalToConstant: DaylightThemeToggleButton.side),

            notificationCenter.bell.trailingAnchor.constraint(equalTo: avatar.leadingAnchor, constant: -HelmMetrics.s2),
            notificationCenter.bell.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            notificationCenter.bell.widthAnchor.constraint(equalToConstant: NotificationBellButton.controlWidth),
            notificationCenter.bell.heightAnchor.constraint(equalToConstant: NotificationBellButton.iconSize),

            avatar.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -inset),
            avatar.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 34),
            avatar.heightAnchor.constraint(equalToConstant: 34),
        ])

        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        // `ThemeManager.observe` fires synchronously at registration, which
        // for this controller is before `avatarGradient` has a frame - the
        // `refreshTheme()` convention (AGENTS.md's ThemeManager checklist,
        // item 8) is what makes the first paint correct anyway.
        applyTheme(ThemeManager.shared.theme)
    }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    private func buildPillRow() -> NSStackView {
        var views: [NSView] = []
        for space in DaylightSpace.allCases {
            let container = HoverHighlightView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.identifier = NSUserInterfaceItemIdentifier(space.rawValue)

            let label = NSTextField(labelWithString: space.title)
            label.font = HelmType.rounded(HelmType.scaled(12.5), .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 15),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -15),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
            container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pillClicked(_:))))
            // §6.3: radio-button semantics with arrow-key movement, reusing
            // exactly the pattern `HelmSegmentedTabs` already established
            // (GL-16) rather than a second one.
            container.accessibilityRoleOverride = .radioButton
            container.accessibilityLabelOverride = space.title
            container.onKeyDown = { [weak self] event in
                self?.handleArrowKey(event, from: space) ?? false
            }
            pills.append(SpacePill(space: space, container: container, label: label))
            views.append(container)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 2
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func buildAvatar() {
        avatar.title = ""
        avatar.isBordered = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = HelmMetrics.dTileLarge
        avatar.layer?.masksToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.target = self
        avatar.action = #selector(avatarClicked)
        avatar.toolTip = "Account"
        avatar.attributedTitle = NSAttributedString(string: "M", attributes: [
            .font: HelmType.rounded(HelmType.scaled(11), .heavy),
            .foregroundColor: NSColor.white,
        ])
        avatarGradient.startPoint = HelmDomainHue.tileStart
        avatarGradient.endPoint = HelmDomainHue.tileEnd
        avatarGradient.cornerRadius = HelmMetrics.dTileLarge
        // Below the title, which AppKit draws in the button's own layer.
        avatar.layer?.insertSublayer(avatarGradient, at: 0)

        let popoverContent = AvatarLogoutPopoverController()
        popoverContent.onSettings = { [weak self] in
            self?.avatarPopover.performClose(nil)
            self?.onSelectSettings?()
        }
        popoverContent.onLogout = { [weak self] in
            self?.avatarPopover.performClose(nil)
            self?.logoutClicked()
        }
        avatarPopover.contentViewController = popoverContent
        avatarPopover.behavior = .transient
    }

    // MARK: Selection

    /// Moves the selected pill without firing `onSelectSpace` - for a
    /// selection that came from somewhere else (a `⌘N` shortcut the canvas
    /// handled, or the shell restoring the last space on a back-navigation).
    func setSelectedSpace(_ space: DaylightSpace) {
        selectedSpace = space
        applyTheme(ThemeManager.shared.theme)
    }

    var selectedSpaceForTests: DaylightSpace { selectedSpace }

    @objc private func pillClicked(_ sender: NSClickGestureRecognizer) {
        guard let raw = sender.view?.identifier?.rawValue,
              let space = DaylightSpace(rawValue: raw) else { return }
        setSelectedSpace(space)
        onSelectSpace?(space)
    }

    private func handleArrowKey(_ event: NSEvent, from space: DaylightSpace) -> Bool {
        let step: Int
        switch Int(event.keyCode) {
        case 123, 126: step = -1   // left, up
        case 124, 125: step = 1    // right, down
        default: return false
        }
        guard let index = pills.firstIndex(where: { $0.space == space }) else { return false }
        let next = index + step
        guard pills.indices.contains(next) else { return true }
        let target = pills[next]
        setSelectedSpace(target.space)
        onSelectSpace?(target.space)
        view.window?.makeFirstResponder(target.container)
        return true
    }

    // MARK: Avatar

    @objc private func avatarClicked() {
        if avatarPopover.isShown {
            avatarPopover.performClose(nil)
        } else {
            (avatarPopover.contentViewController as? AvatarLogoutPopoverController)?
                .applyTheme(ThemeManager.shared.theme)
            avatarPopover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
            avatarPopover.show(relativeTo: avatar.bounds, of: avatar, preferredEdge: .minY)
        }
    }

    /// Unchanged from the rail's own Logout: one confirmation, same copy.
    /// `fm/grandline-avatar-menu-and-setup-guide` collapsed this from two
    /// alerts to one after live captain feedback; that decision stands.
    private func logoutClicked() {
        let alert = NSAlert()
        alert.messageText = "Log out of Manjesh Grand Line?"
        alert.informativeText = "This locks the app immediately. You'll need your Grand Line password to get back in. Your terminal sessions keep running in the background."
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onLogoutRequested?()
    }

    /// The exact call Console's own toolbar button used to make - the quick
    /// flip within a theme's own light/dark family pair (`pairId`), never
    /// the full 13-theme picker (`ThemeMenu.swift`/Settings' Appearance
    /// grid). `applyTheme()` runs via the `observe` callback registered in
    /// `loadView`, so nothing else is needed here.
    @objc private func themeToggleClicked() {
        ThemeManager.shared.toggle()
    }

    // MARK: Theme

    override func viewDidLayout() {
        super.viewDidLayout()
        avatarGradient.frame = avatar.bounds
        bar.layer?.shadowPath = CGPath(roundedRect: bar.bounds,
                                       cornerWidth: HelmMetrics.dBar,
                                       cornerHeight: HelmMetrics.dBar,
                                       transform: nil)
    }

    private func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        // The bar floats on the page ground, so the root behind it paints the
        // ground itself - a transparent root would let the window's own
        // backing show through (AGENTS.md gotcha (8)'s other half).
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        bar.layer?.backgroundColor = surface.cgColor
        bar.layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor
        let shadow = HelmCard.elevation(for: theme, level: .resting)
        bar.layer?.shadowColor = (shadow.shadowColor ?? .black).cgColor
        bar.layer?.shadowOpacity = Float(shadow.shadowColor?.alphaComponent ?? 0.1)
        bar.layer?.shadowRadius = shadow.shadowBlurRadius
        bar.layer?.shadowOffset = CGSize(width: shadow.shadowOffset.width, height: shadow.shadowOffset.height)

        wordmark.font = HelmType.rounded(HelmType.scaled(14.5), .heavy)
        wordmark.textColor = ink

        // §6.3: selected = white on `ink` (measured 14.08:1 on Daylight);
        // idle = `muted` on nothing; hover = `ink` on `inset`.
        let selectedFill = ink
        let selectedInk = HelmContrast.legible(HelmTheme.nsColor(theme.chromeBackgroundHex), over: selectedFill)
        let hoverFill = theme.isDaylight
            ? HelmTheme.nsColor(DaylightPalette.inset)
            : line.withAlphaComponent(0.35)
        for pill in pills {
            let isSelected = pill.space == selectedSpace
            pill.container.cornerRadius = pill.container.bounds.height > 0
                ? pill.container.bounds.height / 2
                : 14
            pill.container.normalColor = isSelected ? selectedFill : .clear
            pill.container.hoverColor = isSelected ? selectedFill : hoverFill
            pill.container.accessibilityValueOverride = isSelected ? "selected" : "not selected"
            pill.label.font = HelmType.rounded(HelmType.scaled(12.5), .semibold)
            pill.label.textColor = isSelected ? selectedInk : muted
        }

        searchPill.applyTheme(theme)
        themeToggleButton.applyTheme(ink: muted, line: line, surface: theme.isDaylight
            ? HelmTheme.nsColor(DaylightPalette.inset) : surface)
        notificationCenter.bell.applyTheme(ink: muted, line: line, surface: theme.isDaylight
            ? HelmTheme.nsColor(DaylightPalette.inset) : surface)

        let avatarPair = (h1: HelmDomainHue.amber.pair(in: theme).h2,
                          h2: HelmDomainHue.rose.pair(in: theme).h2)
        avatarGradient.colors = [avatarPair.h1.cgColor, avatarPair.h2.cgColor]
        avatar.attributedTitle = NSAttributedString(string: "M", attributes: [
            .font: HelmType.rounded(HelmType.scaled(11), .heavy),
            .foregroundColor: HelmContrast.legibleGlyph(over: avatarPair.h1, target: HelmContrast.textTarget),
        ])
    }

    // MARK: Probe / self-test surface

    struct Geometry {
        let barFrame: NSRect
        let cornerRadius: CGFloat
        let usesVisualEffect: Bool
        let pillCount: Int
        let selected: String
        let shadowOpacity: Float
    }

    var geometryForTests: Geometry {
        Geometry(barFrame: bar.frame,
                 cornerRadius: bar.layer?.cornerRadius ?? 0,
                 usesVisualEffect: containsVisualEffectView(view),
                 pillCount: pills.count,
                 selected: selectedSpace.rawValue,
                 shadowOpacity: bar.layer?.shadowOpacity ?? 0)
    }

    private func containsVisualEffectView(_ root: NSView) -> Bool {
        if root is NSVisualEffectView { return true }
        return root.subviews.contains { containsVisualEffectView($0) }
    }

    /// The pill views, so a test can drive a real click/press through the
    /// same recognizer a captain's mouse would.
    func debugPills() -> [HoverHighlightView] { pills.map { $0.container } }

    /// The highest constraint priority anywhere in the bar's own subtree that
    /// could act on width. `checkBarDoesNotCapWindow` asserts nothing here
    /// exceeds `NSLayoutPriorityWindowSizeStayPut`.
    /// Every width constraint in the bar's own subtree that is **not** a
    /// fixed size on a fixed-size control, as `(description, priority)`.
    ///
    /// The exemption is not a loophole: a required `width == 34` on the bell
    /// or the avatar cannot widen the window, because those controls sum to a
    /// tiny fraction of the bar and the chain between them is built from
    /// inequalities. What *can* cap a window is a required constraint tying a
    /// flexible view's width to its own content or to the bar - and those are
    /// exactly what this reports.
    func debugWidthConstraints() -> [(String, Float)] {
        var out: [(String, Float)] = []
        func walk(_ v: NSView) {
            // A control whose own outer width is already pinned to a constant
            // (the bell, the avatar, a gradient tile) is not a window floor,
            // and neither is anything *inside* it - the bell's badge zone and
            // its icon square are chrome laid out within a 63pt button. Skip
            // the whole subtree rather than exempting each internal constraint,
            // which would otherwise mean this check re-litigating
            // `NotificationBellButton`'s private layout.
            if v is NSButton || v is HelmGradientTile { return }
            for c in v.constraints where c.firstAttribute == .width || c.secondAttribute == .width {
                out.append((String(describing: c), c.priority.rawValue))
            }
            v.subviews.forEach(walk)
        }
        for subview in bar.subviews { walk(subview) }
        for c in bar.constraints where c.firstAttribute == .width || c.secondAttribute == .width {
            out.append((String(describing: c), c.priority.rawValue))
        }
        return out
    }

    func debugMaxWidthConstraintPriority() -> Float {
        debugWidthConstraints().map(\.1).max() ?? 0
    }
}

// MARK: - The search pill (§6.3)

/// Capsule, `inset` fill, `hair` border, magnifier + placeholder + a `⌘K` chip.
///
/// A `HoverHighlightView` for the same reason `PillButton` was (GL-16): the
/// role, label, focus ring and Return/Space activation all come from that one
/// component rather than four overrides here.
final class DaylightSearchPill: HoverHighlightView {
    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "Search anything\u{2026}")
    private let badge = NSTextField(labelWithString: "\u{2318}K")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1

        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: HelmType.scaled(12))
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        badge.font = .monospacedSystemFont(ofSize: HelmType.scaled(10), weight: .medium)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = HelmMetrics.rChip
        badge.layer?.borderWidth = 1
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, label, badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // 499, never required: this is the one bar control designed to shrink,
        // so its own preferred width must never be able to widen the window.
        let preferred = widthAnchor.constraint(equalToConstant: 230)
        preferred.priority = HelmDaylightPriority.contentTie
        let floor = widthAnchor.constraint(greaterThanOrEqualToConstant: 92)
        floor.priority = HelmDaylightPriority.contentTie

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            preferred,
            floor,
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        accessibilityLabelOverride = "Search anything, Command K"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { onClick?() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    func applyTheme(_ theme: HelmTheme) {
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let fill = theme.isDaylight
            ? HelmTheme.nsColor(DaylightPalette.inset)
            : HelmTheme.nsColor(theme.backgroundHex)
        normalColor = fill
        hoverColor = line.withAlphaComponent(theme.isDaylight ? 0.45 : 0.3)
        layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor
        iconView.contentTintColor = muted
        label.font = .systemFont(ofSize: HelmType.scaled(12))
        // §2.4: placeholder-weight copy uses `muted`, never `faint` - `faint`
        // measures 2.04:1 and is decorative only.
        label.textColor = muted
        badge.font = .monospacedSystemFont(ofSize: HelmType.scaled(10), weight: .medium)
        badge.textColor = muted
        badge.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        badge.layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor
    }
}

// MARK: - The theme toggle (moved from Console's own toolbar)

/// A bordered 34x34 icon square - the exact same visible chrome as
/// `NotificationBellButton`'s own icon square (`iconBackground`: radius 9,
/// `chromeBackgroundHex` fill, `chromeLineHex` @ 0.5 border), so the two
/// square icon buttons on this bar read as one visual language rather than
/// two different button recipes sitting side by side.
///
/// Moved here from Console's per-tab toolbar
/// (`fm/grandline-daylight-theme-toggle-relocate`): the light/dark flip is
/// an app-wide preference (it calls `ThemeManager.shared.toggle()`, the
/// same quick within-family flip Console's button always called - never the
/// full 13-theme picker, which stays on `ThemeMenu.swift`/Settings'
/// Appearance grid), so it belongs on the app-wide floating bar rather than
/// a per-destination toolbar that only exists on Console.
final class DaylightThemeToggleButton: NSButton {
    /// Matches `NotificationBellButton.iconSize` exactly.
    static let side: CGFloat = NotificationBellButton.iconSize

    private let iconBackground = NSView()
    private let iconImageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        image = nil
        toolTip = "Toggle Light/Dark (⌘⌥T)"
        setAccessibilityLabel("Toggle Light/Dark")
        translatesAutoresizingMaskIntoConstraints = false

        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 9
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        // Decorative only - clicks are handled by the button itself, exactly
        // as `NotificationBellButton.iconBackground` is.
        addSubview(iconBackground)

        iconImageView.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: Self.side),
            iconBackground.heightAnchor.constraint(equalToConstant: Self.side),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(ink: NSColor, line: NSColor, surface: NSColor) {
        iconImageView.contentTintColor = ink.withAlphaComponent(0.75)
        iconBackground.layer?.backgroundColor = surface.cgColor
        iconBackground.layer?.borderWidth = 1
        iconBackground.layer?.borderColor = line.withAlphaComponent(0.5).cgColor
    }
}

// MARK: - Hover tracking (moved from the rail)

/// An `NSButton` that reports mouse enter/exit - `NSButton` has no built-in
/// hover callback. Moved verbatim from `IconRailController.swift` when the
/// rail's visible surface was removed; the avatar is its only remaining user.
final class HoverTrackingButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

// MARK: - The avatar popover (moved from the rail)

/// Settings above a divider above Logout - an identity/account menu, not a
/// general dumping ground for destinations. Moved verbatim from
/// `IconRailController.swift`; only its host changed.
final class AvatarLogoutPopoverController: NSViewController {
    private let settingsRow = HoverHighlightView()
    private let settingsIcon = NSImageView()
    private let settingsLabel = NSTextField(labelWithString: "Settings")
    private let divider = NSView()
    private let logoutRow = HoverHighlightView()
    private let logoutIcon = NSImageView()
    private let logoutLabel = NSTextField(labelWithString: "Logout")

    var onSettings: (() -> Void)?
    var onLogout: (() -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 172, height: 89))
        root.wantsLayer = true
        view = root

        settingsIcon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        settingsIcon.translatesAutoresizingMaskIntoConstraints = false
        settingsLabel.font = .systemFont(ofSize: HelmType.scaled(13), weight: .medium)
        settingsLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsRow.translatesAutoresizingMaskIntoConstraints = false
        settingsRow.addSubview(settingsIcon)
        settingsRow.addSubview(settingsLabel)
        root.addSubview(settingsRow)
        settingsRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(settingsRowClicked)))
        settingsRow.accessibilityLabelOverride = "Settings"

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        logoutIcon.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: "Logout")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        logoutIcon.translatesAutoresizingMaskIntoConstraints = false
        logoutLabel.font = .systemFont(ofSize: HelmType.scaled(13), weight: .medium)
        logoutLabel.translatesAutoresizingMaskIntoConstraints = false
        logoutRow.translatesAutoresizingMaskIntoConstraints = false
        logoutRow.addSubview(logoutIcon)
        logoutRow.addSubview(logoutLabel)
        root.addSubview(logoutRow)
        logoutRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(logoutRowClicked)))
        logoutRow.accessibilityLabelOverride = "Logout"

        NSLayoutConstraint.activate([
            settingsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            settingsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            settingsRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            settingsRow.heightAnchor.constraint(equalToConstant: 32),

            settingsIcon.leadingAnchor.constraint(equalTo: settingsRow.leadingAnchor, constant: 10),
            settingsIcon.centerYAnchor.constraint(equalTo: settingsRow.centerYAnchor),
            settingsIcon.widthAnchor.constraint(equalToConstant: 16),

            settingsLabel.leadingAnchor.constraint(equalTo: settingsIcon.trailingAnchor, constant: 8),
            settingsLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsRow.trailingAnchor, constant: -10),
            settingsLabel.centerYAnchor.constraint(equalTo: settingsRow.centerYAnchor),

            divider.topAnchor.constraint(equalTo: settingsRow.bottomAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            divider.heightAnchor.constraint(equalToConstant: 1),

            logoutRow.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            logoutRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            logoutRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            logoutRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            logoutRow.heightAnchor.constraint(equalToConstant: 32),

            logoutIcon.leadingAnchor.constraint(equalTo: logoutRow.leadingAnchor, constant: 10),
            logoutIcon.centerYAnchor.constraint(equalTo: logoutRow.centerYAnchor),
            logoutIcon.widthAnchor.constraint(equalToConstant: 16),

            logoutLabel.leadingAnchor.constraint(equalTo: logoutIcon.trailingAnchor, constant: 8),
            logoutLabel.trailingAnchor.constraint(lessThanOrEqualTo: logoutRow.trailingAnchor, constant: -10),
            logoutLabel.centerYAnchor.constraint(equalTo: logoutRow.centerYAnchor),
        ])

        settingsRow.cornerRadius = HelmMetrics.rControl
        logoutRow.cornerRadius = HelmMetrics.rControl
        applyTheme(ThemeManager.shared.theme)
    }

    @objc private func settingsRowClicked() { onSettings?() }
    @objc private func logoutRowClicked() { onLogout?() }

    func applyTheme(_ theme: HelmTheme) {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        divider.layer?.backgroundColor = line.cgColor
        settingsIcon.contentTintColor = ink
        settingsLabel.textColor = ink
        settingsRow.normalColor = .clear
        settingsRow.hoverColor = line.withAlphaComponent(0.5)
        // Red, as a destructive-ish action - routed through the contrast
        // correction rather than painted raw (audit §5.7).
        logoutIcon.contentTintColor = HelmContrast.legibleTintedText(
            tintHex: theme.ansiHex[1], over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
        logoutLabel.textColor = ink
        logoutRow.normalColor = .clear
        logoutRow.hoverColor = line.withAlphaComponent(0.5)
    }
}
