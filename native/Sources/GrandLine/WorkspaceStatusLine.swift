// Grand Line - native macOS app.
//
// The sidebar shell's status line (stage 3 of the modular-shell migration):
// one row under the content column, from the review's Direction B and the
// prototype's footer.
//
// Left to right:
//
//   - **the focus timer chip** (F7) - the floating bar shows it beside the
//     search pill while a timer runs; here it is the first thing on the line,
//     with the same ring popover,
//   - **the live sessions**, read off the session registry: how many are
//     connected, and how many are restored pages that have not started,
//   - the prototype's other readouts, from the polish stage: **the crew**
//     ("2 need you", "Crew all clear"), **a failing service**, and
//     **Poneglyph's lock**, then on the right **Claude usage** and **Tasks
//     sync**. Each comes from `WorkspaceSignals`, which says where it reads
//     and what each honest state looks like, and each opens its module.
//
// A readout with nothing known draws nothing at all, rather than a zero.

import AppKit

final class WorkspaceStatusLine: NSView {

    /// Room for the 26pt focus chip with a point either side.
    static let height: CGFloat = 30

    private let focusChip = FocusTimerChip()
    private let sessionsDot = NSView()
    private let sessionsLabel = NSTextField(labelWithString: "")
    private let topEdge = NSView()
    private let stack = NSStackView()

    private weak var focusTimer: FocusTimerController?
    private var focusTimerToken: UUID?
    private var focusPopover: NSPopover?
    private var themeToken: ThemeObservation?
    private var sessionsAreLive = false
    /// The signals' readouts, leading and trailing, rebuilt from
    /// `WorkspaceSignals.statusItems` on every change.
    private let leadingReadouts = NSStackView()
    private let trailingReadouts = NSStackView()
    private var readouts: [WorkspaceStatusItem.ID: WorkspaceStatusReadout] = [:]
    private var signals = WorkspaceSignals()
    /// "Synced 2 min ago" ages, so the line repaints its words once a minute
    /// while the window is up - a repaint of what it holds, never a read.
    private var ageTimer: Timer?
    /// A readout was clicked: open its page.
    var onOpen: ((RailDestination) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        topEdge.wantsLayer = true
        topEdge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topEdge)

        focusChip.isHidden = true
        // `HoverHighlightView` reads its primary action off a real click
        // recognizer (`performPrimaryAction`, which is also what makes the
        // chip keyboard-activatable under GL-16) - the floating bar wires it
        // the same way.
        focusChip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(focusChipClicked)))

        sessionsDot.wantsLayer = true
        sessionsDot.layer?.cornerRadius = WorkspaceSidebarSessionCell.dotSide / 2
        sessionsDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sessionsDot.widthAnchor.constraint(equalToConstant: WorkspaceSidebarSessionCell.dotSide),
            sessionsDot.heightAnchor.constraint(equalToConstant: WorkspaceSidebarSessionCell.dotSide),
        ])
        sessionsLabel.font = .systemFont(ofSize: HelmType.scaled(11.5))
        sessionsLabel.lineBreakMode = .byTruncatingTail
        sessionsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sessions = NSStackView(views: [sessionsDot, sessionsLabel])
        sessions.orientation = .horizontal
        sessions.alignment = .centerY
        sessions.spacing = HelmMetrics.s1 + 2

        // Gotcha (10): `.fill`, never the default `.gravityAreas`. The stack
        // is only as wide as what it holds (its trailing edge is a `<=`), so
        // there is no slack for it to hand out.
        stack.addArrangedSubview(focusChip)
        stack.addArrangedSubview(sessions)
        stack.addArrangedSubview(leadingReadouts)
        stack.distribution = .fill
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for readouts in [leadingReadouts, trailingReadouts] {
            readouts.orientation = .horizontal
            readouts.alignment = .centerY
            readouts.distribution = .fill
            readouts.spacing = HelmMetrics.s4
            readouts.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(trailingReadouts)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            topEdge.topAnchor.constraint(equalTo: topAnchor),
            topEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            topEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            topEdge.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingReadouts.leadingAnchor, constant: -HelmMetrics.s4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            trailingReadouts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s4),
            trailingReadouts.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])

        // GL-09 / §5.1(b): a popover left open when the app lock fires stays
        // readable and interactive above the overlay, so it is closed on the
        // way in - it names the captain's current task.
        AppLockGate.shared.registerLockDismissiblePopover(owner: self) { [weak self] in self?.focusPopover }
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        render(sessions: [])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        if let focusTimerToken { focusTimer?.unobserve(focusTimerToken) }
        ageTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ageTimer?.invalidate()
        ageTimer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.render(signals: self.signals)
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        ageTimer = timer
    }

    // MARK: The signals' readouts

    /// Draw what the signals say now. A readout appears, changes or goes in
    /// place; the line keeps its order.
    func render(signals: WorkspaceSignals, now: Date = Date()) {
        self.signals = signals
        let items = signals.statusItems(now: now)
        let shown = Set(items.map(\.id))
        for (id, readout) in readouts where !shown.contains(id) {
            readout.removeFromSuperview()
            readouts[id] = nil
        }
        let theme = ThemeManager.shared.theme
        for item in items {
            let readout = readouts[item.id] ?? {
                let made = WorkspaceStatusReadout()
                made.onClick = { [weak self] destination in self?.onOpen?(destination) }
                readouts[item.id] = made
                return made
            }()
            readout.configure(item, theme: theme)
        }
        // Re-seat in the model's order, leading and trailing.
        for (stackView, trailing) in [(leadingReadouts, false), (trailingReadouts, true)] {
            let ordered = items.filter { $0.trailing == trailing }.compactMap { readouts[$0.id] }
            if stackView.arrangedSubviews != ordered {
                stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }
                ordered.forEach { stackView.addArrangedSubview($0) }
            }
        }
    }

    // MARK: The sessions readout

    /// Say what the registry holds. A restored page is a page, not a
    /// connection, so it is counted apart from the live ones and never
    /// claimed as connected - the registry's own rule.
    func render(sessions: [HostSession]) {
        let live = sessions.filter(\.isConnected).count
        let restored = sessions.count - live
        var parts: [String] = []
        if live > 0 { parts.append(live == 1 ? "1 session live" : "\(live) sessions live") }
        if restored > 0 { parts.append("\(restored) restored, not connected") }
        sessionsLabel.stringValue = parts.isEmpty ? "No live sessions" : parts.joined(separator: " \u{00B7} ")
        sessionsAreLive = live > 0
        applyTheme(ThemeManager.shared.theme)
    }

    // MARK: F7 - the focus timer chip

    /// Hand the line the app's one `FocusTimerController`. It observes the
    /// timer to know when to repaint, and every button in the popover acts on
    /// the controller directly - the floating bar's own contract.
    func attachFocusTimer(_ timer: FocusTimerController) {
        if let focusTimerToken, let previous = focusTimer { previous.unobserve(focusTimerToken) }
        focusTimer = timer
        focusTimerToken = timer.observe { [weak self] in self?.renderFocusChip() }
        renderFocusChip()
    }

    /// Repaint the chip from the live session, and take it off the line
    /// entirely when nothing is running. It is an arranged subview, so hiding
    /// it really does give its width back (gotcha (11)'s stack exemption).
    private func renderFocusChip() {
        guard let session = focusTimer?.session else {
            focusChip.isHidden = true
            // The popover is about a session that no longer exists.
            focusPopover?.performClose(nil)
            focusPopover = nil
            return
        }
        focusChip.isHidden = false
        // Read through the controller, never off a `Date()` of this view's
        // own - see `FocusTimerController.fraction` for why.
        focusChip.configure(fraction: focusTimer?.fraction ?? 0,
                            countdown: focusTimer?.countdownText ?? "0:00",
                            title: session.taskTitle,
                            paused: focusTimer?.isPaused ?? false)
        focusChip.applyTheme(ThemeManager.shared.theme)
    }

    @objc private func focusChipClicked() {
        guard let focusTimer, focusTimer.isRunning else { return }
        if let focusPopover, focusPopover.isShown {
            focusPopover.performClose(nil)
            self.focusPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        // ThemeManager's checklist item 2: the popover's own chrome resolves
        // system semantic colours, so it needs the theme's light/dark mode.
        popover.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        let panel = FocusTimerPanelController(timer: focusTimer)
        // B28: the panel closes *this* popover, never a window.
        panel.onRequestClose = { [weak self, weak popover] in
            popover?.performClose(nil)
            self?.focusPopover = nil
        }
        popover.contentViewController = panel
        // Above the chip: the line is the bottom edge of the window.
        popover.show(relativeTo: focusChip.bounds, of: focusChip, preferredEdge: .maxY)
        focusPopover = popover
    }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        topEdge.layer?.backgroundColor = HelmDisplayAccessibility.strengthenedEdge(
            HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.dividerAlpha), theme: theme).cgColor
        sessionsLabel.textColor = HelmTheme.mutedInk(theme)
        sessionsDot.layer?.backgroundColor = sessionsAreLive
            ? HelmTheme.nsColor(HelmTint.good.hex(in: theme)).cgColor
            : HelmTheme.mutedInk(theme).withAlphaComponent(0.5).cgColor
        if !focusChip.isHidden { focusChip.applyTheme(theme) }
        for readout in readouts.values { readout.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugSessionsText: String { sessionsLabel.stringValue }
    var debugFocusChip: FocusTimerChip { focusChip }
    var debugFocusChipIsVisible: Bool { !focusChip.isHidden }
    func debugClickFocusChip() { focusChipClicked() }
    var debugFocusPopoverIsShown: Bool { focusPopover?.isShown ?? false }
    /// The readouts as drawn, in order: leading, then trailing.
    var debugReadouts: [WorkspaceStatusReadout] {
        (leadingReadouts.arrangedSubviews + trailingReadouts.arrangedSubviews).compactMap { $0 as? WorkspaceStatusReadout }
    }
    var debugReadoutTexts: [String] { debugReadouts.map(\.debugText) }
    #endif
}

/// One readout on the status line: a dot or a symbol, then its words. A
/// click (or Return, Space or VoiceOver's press, through `HoverHighlightView`)
/// opens the page it is about.
final class WorkspaceStatusReadout: HoverHighlightView {
    private let dot = NSView()
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var item: WorkspaceStatusItem?
    var onClick: ((RailDestination) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cornerRadius = HelmMetrics.rChip
        dot.wantsLayer = true
        dot.layer?.cornerRadius = WorkspaceSidebarSessionCell.dotSide / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: HelmType.scaled(11.5))
        label.lineBreakMode = .byTruncatingTail
        // Gotcha (5): the words give way, the mark never does.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [dot, symbol, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s1 + 2
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: WorkspaceSidebarSessionCell.dotSide),
            dot.heightAnchor.constraint(equalToConstant: WorkspaceSidebarSessionCell.dotSide),
            symbol.widthAnchor.constraint(equalToConstant: HelmType.scaled(12)),
            symbol.heightAnchor.constraint(equalToConstant: HelmType.scaled(12)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s1),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ item: WorkspaceStatusItem, theme: HelmTheme) {
        self.item = item
        label.stringValue = item.text
        toolTip = item.toolTip
        accessibilityLabelOverride = item.text
        setAccessibilityHelp(item.toolTip)
        switch item.lead {
        case .dot:
            dot.isHidden = false
            symbol.isHidden = true
        case .symbol(let name, _):
            dot.isHidden = true
            symbol.isHidden = false
            symbol.image = HelmSymbol.image(name, pointSize: HelmType.scaled(10.5), weight: .semibold)
        case .none:
            dot.isHidden = true
            symbol.isHidden = true
        }
        applyTheme(theme)
    }

    /// Muted words, as the prototype's line has them; the mark carries the
    /// state, in a tint corrected to clear the text floor on the line's
    /// ground - it is the only thing that says "failing" before the words do.
    func applyTheme(_ theme: HelmTheme) {
        let ground = HelmTheme.nsColor(theme.backgroundHex)
        let muted = HelmTheme.mutedInk(theme)
        label.textColor = muted
        hoverColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(WorkspaceSidebarHeader.hoverAlpha)
        guard let item else { return }
        switch item.lead {
        case .dot(let tone, let quiet):
            let color = WorkspaceSidebarBadgeView.ink(for: tone, over: ground, theme: theme)
            dot.layer?.backgroundColor = (quiet ? color.withAlphaComponent(0.5) : color).cgColor
        case .symbol(_, let tone):
            symbol.contentTintColor = tone == .neutral ? muted : WorkspaceSidebarBadgeView.ink(for: tone, over: ground, theme: theme)
        case .none:
            break
        }
    }

    @objc private func clicked() {
        guard let item else { return }
        onClick?(item.destination)
    }

    #if FM_SELFTESTS
    var debugText: String { label.stringValue }
    var debugItem: WorkspaceStatusItem? { item }
    var debugDotColor: CGColor? { dot.isHidden ? nil : dot.layer?.backgroundColor }
    var debugLabelColor: NSColor? { label.textColor }
    #endif
}
