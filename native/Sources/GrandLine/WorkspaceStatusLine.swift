// Grand Line - native macOS app.
//
// The sidebar shell's status line (stage 3 of the modular-shell migration):
// one row under the content column, from the review's Direction B and the
// prototype's footer.
//
// In this stage it carries what has a real, observable source today:
//
//   - **the focus timer chip** (F7) - the floating bar shows it beside the
//     search pill while a timer runs; here it is the first thing on the line,
//     with the same ring popover,
//   - **the live sessions**, read off the session registry: how many are
//     connected, and how many are restored pages that have not started.
//
// The prototype's other readouts (crew decisions, a failing service, the
// vault's lock, Claude usage, sync) arrive with their modules in stage 4.
// Each needs a source that can be observed by more than one surface - the
// vault store's `onChange` is a single closure Poneglyph already owns
// (ARCH-04) - and a readout that cannot be kept current would be the
// "unknown rendered as zero" GL-14 forbids.

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
        stack.distribution = .fill
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            topEdge.topAnchor.constraint(equalTo: topAnchor),
            topEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            topEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            topEdge.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
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
    }

    #if FM_SELFTESTS
    var debugSessionsText: String { sessionsLabel.stringValue }
    var debugFocusChip: FocusTimerChip { focusChip }
    var debugFocusChipIsVisible: Bool { !focusChip.isHidden }
    func debugClickFocusChip() { focusChipClicked() }
    var debugFocusPopoverIsShown: Bool { focusPopover?.isShown ?? false }
    #endif
}
