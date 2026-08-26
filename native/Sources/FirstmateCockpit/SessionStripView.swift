// SessionStripView.swift - the persistent strip of live-SSH-session pills that
// rides along under the Daylight bar, everywhere in the app.
//
// `fm/grandline-session-switcher`, item 2 of the captain-approved mockup
// (`data/grandline-session-switcher/session-switcher-mockup.html`). The
// problem it solves: with a DEV and a PROD session both live, switching between
// them meant leaving the terminal, navigating to Hosts, finding the row and
// pressing Connect - a button that looks identical to opening a brand new
// connection. The strip makes an already-live session one click away from
// anywhere.
//
// **A plain view class, not a view controller**, matching
// `SchedulesCardView`/`HealthCardView`/`HostsListSection`: it owns rendering
// and hands every decision back through closures, and `AppShellController`
// owns navigation, teardown and the confirm alert. It is deliberately *not*
// folded into `DaylightBarController` - that controller's own geometry
// (`reservedTopHeight`, the two independently-anchored constraint chains, the
// B4 pill-label priority band) is heavily measured and self-tested, and this is
// a second row below the bar rather than a control inside it.
//
// **It reads `HostSessionRegistry` and stores nothing of its own.** A pill's
// colour is that host's own `Host.accentHex` (the same literal hue the Hosts
// row's accent bar already carries, which is what makes recognition instant -
// mockup callout b), its shortcut hint comes from the registry's insertion
// order, and "which one is filled in" is the registry's `activeHostID`. There
// is no second notion of liveness here to drift.
import AppKit

final class SessionStripView: NSView {

    /// Matches the bar's own side margin so the strip reads as docked to it
    /// rather than as an unrelated floating element.
    static let sideMargin: CGFloat = DaylightBarController.sideMargin
    /// The gap between the bar's bottom edge and this strip.
    static let gapBelowBar: CGFloat = HelmMetrics.s2
    static let height: CGFloat = 38

    /// A pill was clicked - switch to that session. `AppShellController`
    /// turns this into "reveal that host's already-built console page"; this
    /// view does not know what a console is.
    var onSelect: ((UUID) -> Void)?
    /// A pill's ✕ was clicked - end that session (after the shell's own
    /// confirm).
    var onClose: ((UUID) -> Void)?
    /// The trailing "+" - open Hosts to start a new connection. The strip
    /// complements Hosts, it does not replace it (mockup callout d).
    var onAddRequested: (() -> Void)?

    private let container = NSView()
    private let caption = NSTextField(labelWithString: "SESSIONS")
    private let pillRow = NSStackView()
    private let addButton = HoverHighlightView()
    private let addGlyph = NSImageView()

    private var pills: [Pill] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var themeToken: ThemeObservation?

    private struct Pill {
        let hostID: UUID
        let container: HoverHighlightView
        let dot: NSView
        let label: NSTextField
        let shortcut: NSTextField
        let close: HoverHighlightView?
        let closeGlyph: NSImageView?
        let isActive: Bool
        let accent: NSColor
    }

    // MARK: Build

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer?.cornerRadius = HelmMetrics.dBar
        container.layer?.borderWidth = 1
        container.layer?.masksToBounds = false
        addSubview(container)

        caption.font = HelmType.kicker()
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)

        pillRow.orientation = .horizontal
        pillRow.spacing = HelmMetrics.s1 + 2
        pillRow.distribution = .fill
        pillRow.alignment = .centerY
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        pillRow.setHuggingPriority(.required, for: .horizontal)
        // A strip is one row of a handful of pills, so it must never be the
        // thing that decides how wide this window can be (AGENTS.md gotcha
        // (13)): every stack in the chain yields rather than resisting, and
        // nothing here carries a required width.
        pillRow.setClippingResistancePriority(.defaultLow, for: .horizontal)

        buildAddButton()

        container.addSubview(caption)
        container.addSubview(pillRow)
        container.addSubview(addButton)

        let inset: CGFloat = 12
        // The "+" sits immediately after the last pill (the mockup's own
        // placement - it reads as "add another" rather than as unrelated
        // trailing chrome), with a trailing *inequality* so a strip with more
        // sessions than fit clips rather than widening the window (AGENTS.md
        // gotcha (13)) or pushing the button off the end.
        let addToTrailing = addButton.trailingAnchor.constraint(
            lessThanOrEqualTo: container.trailingAnchor, constant: -12)
        addToTrailing.priority = HelmDaylightPriority.contentTie

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideMargin),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideMargin),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            caption.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            pillRow.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: HelmMetrics.s3),
            pillRow.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            addToTrailing,
            addButton.leadingAnchor.constraint(equalTo: pillRow.trailingAnchor, constant: HelmMetrics.s2),
            addButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        themeToken = ThemeManager.shared.observe { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    private func buildAddButton() {
        addButton.cornerRadius = HelmMetrics.rControl
        addGlyph.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addGlyph.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        addGlyph.translatesAutoresizingMaskIntoConstraints = false
        addButton.addSubview(addGlyph)
        NSLayoutConstraint.activate([
            addGlyph.centerXAnchor.constraint(equalTo: addButton.centerXAnchor),
            addGlyph.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ])
        addButton.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(addClicked)))
        addButton.accessibilityRoleOverride = .button
        addButton.accessibilityLabelOverride = "New session"
        addButton.toolTip = "Open Hosts to start a new session"
    }

    // MARK: Render

    /// Rebuild the pill row from `registry`. Cheap and unconditional: this is
    /// at most a handful of small views, and rebuilding is what keeps the
    /// strip's order, shortcut hints and active highlight from ever needing a
    /// diff against a previous render.
    func render(_ registry: HostSessionRegistry) {
        for view in pillRow.arrangedSubviews {
            pillRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        pills.removeAll()

        for session in registry.sessions {
            let isActive = session.hostID == registry.activeHostID
            pills.append(makePill(session: session,
                                  isActive: isActive,
                                  shortcut: registry.shortcutIndex(for: session.hostID)))
        }
        for pill in pills { pillRow.addArrangedSubview(pill.container) }
        applyTheme()
    }

    private func makePill(session: HostSession, isActive: Bool, shortcut: Int?) -> Pill {
        let accent = session.accentHex.map { HelmTheme.nsColor($0) }
            ?? HelmTheme.nsColor(theme.accentHex)

        let container = HoverHighlightView()
        container.identifier = NSUserInterfaceItemIdentifier(session.hostID.uuidString)

        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 3.5

        let label = NSTextField(labelWithString: session.label)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        // Nothing on this strip may be a window-width floor, so the label
        // truncates before anything else gives (AGENTS.md gotchas (12)/(13)).
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let shortcutLabel = NSTextField(labelWithString: shortcut.map { "\u{2318}\u{2303}\($0)" } ?? "")
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.isHidden = shortcut == nil
        shortcutLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var closeButton: HoverHighlightView?
        var closeGlyph: NSImageView?
        // Mockup callout c: the ✕ deliberately does not appear on the active
        // pill, so a mis-click cannot close the session currently being read.
        // Ending the one you are looking at goes through the Hosts row's own
        // "End session" overflow item instead.
        if !isActive {
            let close = HoverHighlightView()
            close.cornerRadius = 7
            close.identifier = NSUserInterfaceItemIdentifier(session.hostID.uuidString)
            let glyph = NSImageView()
            glyph.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            glyph.symbolConfiguration = .init(pointSize: 7, weight: .bold)
            glyph.translatesAutoresizingMaskIntoConstraints = false
            close.addSubview(glyph)
            NSLayoutConstraint.activate([
                glyph.centerXAnchor.constraint(equalTo: close.centerXAnchor),
                glyph.centerYAnchor.constraint(equalTo: close.centerYAnchor),
                close.widthAnchor.constraint(equalToConstant: 14),
                close.heightAnchor.constraint(equalToConstant: 14),
            ])
            close.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(closeClicked(_:))))
            close.accessibilityRoleOverride = .button
            close.accessibilityLabelOverride = "End session on \(session.label)"
            close.toolTip = "End this session"
            closeButton = close
            closeGlyph = glyph
        }

        var row: [NSView] = [dot, label, shortcutLabel]
        if let closeButton { row.append(closeButton) }
        let stack = NSStackView(views: row)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s1 + 2
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
        ])

        container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pillClicked(_:))))
        // The strip is a one-of-many choice over the live sessions, exactly
        // like the bar's space pills - same `radioButton` + group treatment
        // (GL-16/§8 Phase 6), not a new accessibility idiom.
        container.accessibilityRoleOverride = .radioButton
        container.accessibilityLabelOverride = "\(session.label), connected \(session.durationText)"
        container.accessibilityValueOverride = isActive ? "selected" : "not selected"
        container.onKeyDown = { [weak self] event in self?.handleArrowKey(event, from: session.hostID) ?? false }
        container.toolTip = shortcut.map { "Switch to \(session.label) (\u{2318}\u{2303}\($0))" }
            ?? "Switch to \(session.label)"

        return Pill(hostID: session.hostID, container: container, dot: dot, label: label,
                    shortcut: shortcutLabel, close: closeButton, closeGlyph: closeGlyph,
                    isActive: isActive, accent: accent)
    }

    // MARK: Actions

    @objc private func pillClicked(_ sender: NSGestureRecognizer) {
        guard let raw = sender.view?.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        onSelect?(id)
    }

    @objc private func closeClicked(_ sender: NSGestureRecognizer) {
        guard let raw = sender.view?.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        onClose?(id)
    }

    @objc private func addClicked() { onAddRequested?() }

    /// Left/right arrows move between pills once one has keyboard focus - the
    /// same pattern `HelmSegmentedTabs` and the bar's space pills already use,
    /// rather than a second keyboard model for the same shape of control.
    private func handleArrowKey(_ event: NSEvent, from hostID: UUID) -> Bool {
        guard let index = pills.firstIndex(where: { $0.hostID == hostID }) else { return false }
        let step: Int
        switch event.keyCode {
        case 123: step = -1   // left
        case 124: step = 1    // right
        default: return false
        }
        let target = index + step
        guard pills.indices.contains(target) else { return true }
        onSelect?(pills[target].hostID)
        return true
    }

    var keyViewChain: [NSView] {
        var chain: [NSView] = []
        for pill in pills {
            chain.append(pill.container)
            if let close = pill.close { chain.append(close) }
        }
        chain.append(addButton)
        return chain.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    // MARK: Theme

    private func applyTheme() {
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)

        // The strip floats on the page ground exactly like the bar above it,
        // so this root paints the ground (gotcha (8)) and the container paints
        // the chrome.
        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        container.layer?.backgroundColor = surface.cgColor
        container.layer?.borderColor = line.withAlphaComponent(theme.isDaylight ? 1.0 : 0.6).cgColor

        caption.font = HelmType.kicker()
        caption.textColor = muted

        let hoverFill = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.inset)
            : line.withAlphaComponent(0.35)

        addButton.normalColor = .clear
        addButton.hoverColor = hoverFill
        addGlyph.contentTintColor = muted

        for pill in pills {
            // The active pill is the bar's own selected-pill recipe (a solid
            // `ink` capsule with a contrast-corrected label), so a live
            // session reads as "selected" in the same visual language the
            // space pills already use.
            let fill = pill.isActive ? ink : NSColor.clear
            let labelColor = pill.isActive
                ? HelmContrast.legible(surface, over: ink)
                : HelmContrast.legible(ink, over: surface)
            pill.container.cornerRadius = pill.container.bounds.height > 0
                ? HelmMetrics.capsuleRadius(forHeight: pill.container.bounds.height)
                : 14
            pill.container.normalColor = fill
            pill.container.hoverColor = pill.isActive ? fill : hoverFill
            pill.container.layer?.borderWidth = pill.isActive ? 0 : 1
            pill.container.layer?.borderColor = line.withAlphaComponent(0.6).cgColor

            // The dot is the host's own accent, painted as a *fill* rather
            // than as text - which is the one use `HelmContrast`'s rule says a
            // captain-chosen hue is always safe for. A 7pt dot beside a label
            // that already names the host is a redundant cue, not the sole
            // carrier of meaning, so it needs no contrast correction (the same
            // exemption §2.4's own gradient-tile caveat relies on).
            pill.dot.layer?.backgroundColor = pill.accent.cgColor

            pill.label.font = HelmType.rounded(HelmType.scaled(12.5), pill.isActive ? .semibold : .medium)
            pill.label.textColor = labelColor

            // Mono, matching the mockup's own `kbd` badge treatment and this
            // app's `HelmType.code()` role for a literal key combination.
            pill.shortcut.font = HelmType.code()
            pill.shortcut.textColor = pill.isActive
                ? labelColor.withAlphaComponent(0.7)
                : muted

            if let close = pill.close, let glyph = pill.closeGlyph {
                close.normalColor = .clear
                close.hoverColor = pill.isActive
                    ? NSColor.white.withAlphaComponent(0.18)
                    : line.withAlphaComponent(0.5)
                glyph.contentTintColor = muted
            }
        }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    func debugPillHostIDs() -> [UUID] { pills.map { $0.hostID } }
    func debugActiveHostID() -> UUID? { pills.first { $0.isActive }?.hostID }
    func debugPillHasCloseButton(_ hostID: UUID) -> Bool {
        pills.first { $0.hostID == hostID }?.close != nil
    }
    func debugPillShortcutText(_ hostID: UUID) -> String? {
        pills.first { $0.hostID == hostID }?.shortcut.stringValue
    }
    func debugPillAccessibilityLabel(_ hostID: UUID) -> String? {
        pills.first { $0.hostID == hostID }?.container.accessibilityLabelOverride
    }
    func debugPillView(_ hostID: UUID) -> HoverHighlightView? {
        pills.first { $0.hostID == hostID }?.container
    }
    func debugCloseView(_ hostID: UUID) -> HoverHighlightView? {
        pills.first { $0.hostID == hostID }?.close
    }
    func debugAddButton() -> HoverHighlightView { addButton }
    #endif
}
