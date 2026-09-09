// Manjesh Grand Line - native macOS app.
//
// `fm/straw-hat-menubar-quick-chat-popover`: "Crew Roster" - a static
// tree/org-chart reference reached from the real Straw Hat Pirates page's
// drill header (`StrawHatController.rosterButton`/`rosterTapped()`).
//
// The captain's own ask: a simple, at-a-glance way to see "who's responsible
// for what" across the crew - Luffy at the root, branching down to the other
// six, each labelled with the same richer role phrase already written into
// `StrawHatMember.role` ("Nami \u{00B7} Tasks / Planner / Organization") -
// reused verbatim, not invented copy. This is a static reference, not a live
// dashboard: there is no per-conversation task assignment in this feature to
// visualise, so nothing here is derived from `StrawHatCanvasState` or from
// any store.
//
// ## Presentation shape
//
// The minimal, non-form sheet `ScheduleHistoryController`/
// `ScheduleRunLogController`/`ShiftSnoozeCustomController` all already
// establish: forced appearance only, no explicit themed root layer (a real
// `NSWindow` sheet already paints its own background once appearance is
// forced), a `[title, subtitle, content, footer]` vertical stack, and a
// Close button carrying the same "`dismiss(_:)` raises rather than
// no-opping when nothing presented this controller" fix and the same
// Return/Escape pairing (`cancelOperation`) every sibling sheet in this app
// carries.
//
// ## The tree itself
//
// One root card (Luffy, larger) above a single row of the other six -
// deliberately plain constraint-based "hairline" connector views
// (`AGENTS.md`'s own established idiom for a line - a thin `wantsLayer`
// view, never a custom `draw(_:)` override) rather than hand-drawn Bézier
// paths: a trunk down from Luffy, a bus line spanning the row, and one drop
// per child, each pinned to that child's own `centerXAnchor` so the lines
// always land exactly on a card regardless of window width. No custom
// drawing, no coordinate-space conversion, no clipping risk - just the
// constraint system this app already leans on everywhere else.
//
// Portraits reuse `StrawHatPortraits.image(for:)` - the same asset the real
// chat and the menu-bar popover use - with the plain SF Symbol fallback
// every reader of that API already carries. Deliberately **not**
// `StrawHatPortraitTile`: that view's lit/dim states (and the pulsing ring
// they drive) mean "did this voice speak in the most recent reply", which
// has no meaning on a static reference where every member is, by
// definition, equally "aboard" - a ring pulsing on all seven at once would
// read as busy rather than as the calm, at-a-glance diagram the captain
// asked for.

import AppKit

final class StrawHatRosterController: NSViewController {

    private var themeObservation: ThemeObservation?
    private var theme: HelmTheme = ThemeManager.shared.theme

    private let titleLabel = NSTextField(labelWithString: "Crew Roster")
    private let subtitleLabel = NSTextField(labelWithString:
        "Luffy leads the conversation. Every other voice speaks through him.")
    private weak var closeButton: HelmButton?

    /// The six non-Luffy members, in the order the plan's own roster table
    /// lists them - not `StrawHatMember.allCases`' declaration order, which
    /// exists for the parser's roster check and has nothing to say about a
    /// reading order for a diagram.
    private static let branches: [StrawHatMember] = [.nami, .robin, .chopper, .zoro, .usopp, .franky]

    private static let rootPortraitSide: CGFloat = 52
    private static let branchPortraitSide: CGFloat = 38
    private static let cardWidth: CGFloat = 128
    private static let trunkHeight: CGFloat = 22
    private static let lineWidth: CGFloat = 1.5

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 420))
        view = root
        themeObservation = ThemeManager.shared.observe { [weak self, weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self?.theme = theme
            self?.applyChromeTheme()
        }

        // `sectionTitle()`, matching every sibling read-only sheet
        // (`ScheduleRunLogController`, `ScheduleHistoryController`) - a
        // sheet title is not a page's own hero title, and Daylight §6.4's
        // "20pt hero floor" rule this app polices elsewhere has nothing to
        // do with a modal that is not a destination.
        titleLabel.font = HelmType.sectionTitle()
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let tree = buildTree()
        let footer = buildFooter()

        let stack = NSStackView(views: [titleLabel, subtitleLabel, tree, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(22, after: subtitleLabel)
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            tree.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        applyChromeTheme()
    }

    // MARK: The tree

    private func buildTree() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let root = memberCard(for: .luffy, isRoot: true)
        container.addSubview(root)

        let trunk = hairline()
        container.addSubview(trunk)

        let branchCards = Self.branches.map { memberCard(for: $0, isRoot: false) }
        let row = NSStackView(views: branchCards)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        let bus = hairline()
        container.addSubview(bus)

        NSLayoutConstraint.activate([
            root.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),

            trunk.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            trunk.topAnchor.constraint(equalTo: root.bottomAnchor),
            trunk.widthAnchor.constraint(equalToConstant: Self.lineWidth),
            trunk.heightAnchor.constraint(equalToConstant: Self.trunkHeight / 2),

            bus.topAnchor.constraint(equalTo: trunk.bottomAnchor),
            bus.heightAnchor.constraint(equalToConstant: Self.lineWidth),
            // Spans exactly the first-to-last child centre - never the whole
            // container, or the bus would run past the row's own outer
            // cards on a container wider than six cards actually need.
            bus.leadingAnchor.constraint(equalTo: branchCards[0].centerXAnchor),
            bus.trailingAnchor.constraint(equalTo: branchCards[branchCards.count - 1].centerXAnchor),

            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: bus.bottomAnchor, constant: Self.trunkHeight / 2),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // One drop per child, from the bus down to that card's own top edge -
        // pinned to each card's real `centerXAnchor`, so the connector always
        // lands correctly regardless of how `.equalSpacing` resolves the row.
        for card in branchCards {
            let drop = hairline()
            container.addSubview(drop)
            NSLayoutConstraint.activate([
                drop.centerXAnchor.constraint(equalTo: card.centerXAnchor),
                drop.topAnchor.constraint(equalTo: bus.bottomAnchor),
                drop.bottomAnchor.constraint(equalTo: card.topAnchor),
                drop.widthAnchor.constraint(equalToConstant: Self.lineWidth),
            ])
        }

        return container
    }

    /// A hairline connector - `AGENTS.md`'s own established idiom for a line
    /// in this app: a thin, layer-backed `NSView`, never a custom
    /// `draw(_:)` override.
    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        connectorLines.append(line)
        return line
    }

    private var connectorLines: [NSView] = []

    // MARK: One card

    /// `member.role` reused verbatim, never a shortened/invented summary -
    /// the captain's own instruction. The root card is larger (a bigger
    /// portrait, a heavier name weight) as the diagram's one visual
    /// emphasis; nothing about its *content* differs from a branch card.
    private func memberCard(for member: StrawHatMember, isRoot: Bool) -> NSView {
        let side = isRoot ? Self.rootPortraitSide : Self.branchPortraitSide
        let portrait = Self.portraitView(for: member, side: side, theme: theme)

        let name = NSTextField(labelWithString: member.displayName)
        name.font = isRoot ? HelmType.sectionTitle() : .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        name.alignment = .center
        name.translatesAutoresizingMaskIntoConstraints = false
        nameLabels.append(name)

        let role = NSTextField(wrappingLabelWithString: member.role)
        role.font = HelmType.captionSmall()
        role.alignment = .center
        role.lineBreakMode = .byWordWrapping
        role.maximumNumberOfLines = 0
        role.translatesAutoresizingMaskIntoConstraints = false
        roleLabels.append(role)

        let textColumn = NSStackView(views: [name, role])
        textColumn.orientation = .vertical
        textColumn.alignment = .centerX
        textColumn.spacing = 3
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        for label in [name, role] {
            label.widthAnchor.constraint(equalTo: textColumn.widthAnchor).isActive = true
        }

        let column = NSStackView(views: [portrait, textColumn])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        textColumn.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        column.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
        return column
    }

    /// A crew member's face - `StrawHatPortraits.image(for:)`, the same
    /// asset the real chat and the menu-bar popover read, with the plain
    /// SF-Symbol fallback every reader of that API already carries. No
    /// ring/pulse - see this file's header on why `StrawHatPortraitTile`'s
    /// "contributing" state does not apply to a static reference.
    private static func portraitView(for member: StrawHatMember, side: CGFloat, theme: HelmTheme) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = side / 2
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1.5
        container.layer?.borderColor = member.accentColor(in: theme).withAlphaComponent(0.55).cgColor
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: side),
            container.heightAnchor.constraint(equalToConstant: side),
        ])
        if let portrait = StrawHatPortraits.image(for: member) {
            let imageView = NSImageView()
            imageView.image = portrait
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        } else {
            let tile = IconTileView(size: side, cornerRadius: side / 2)
            tile.configure(symbol: member.symbol, tint: member.tint, pointSize: side * 0.42)
            container.addSubview(tile)
            NSLayoutConstraint.activate([
                tile.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                tile.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                tile.topAnchor.constraint(equalTo: container.topAnchor),
                tile.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    private var nameLabels: [NSTextField] = []
    private var roleLabels: [NSTextField] = []

    // MARK: Footer

    private func buildFooter() -> NSView {
        let close = HelmButton(title: "Close", variant: .primary, target: self, action: #selector(closeClicked))
        closeButton = close
        close.keyEquivalent = "\r"
        // The same `[fixed, flexible spacer, fixed]` recipe every sibling
        // read-only sheet in this app carries (gotchas 10 + 12): `.fill`
        // distribution plus a real, low-priority zero-width spacer plus
        // `.required` hugging on the button is what keeps its width its
        // own, rather than Auto Layout's tie-break stretching it across the
        // row.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        close.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentCompressionResistancePriority(.required, for: .horizontal)

        let footer = NSStackView(views: [spacer, close])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false
        return footer
    }

    @objc private func closeClicked() {
        #if FM_SELFTESTS
        debugCloseRequests += 1
        #endif
        // `dismiss(_:)` raises rather than no-opping when nothing presented
        // this controller (AGENTS.md gotcha 6) - the same fix every sibling
        // sheet in this app carries.
        guard presentingViewController != nil else { return }
        dismiss(self)
    }

    /// Every sibling sheet in this app pairs Return with Escape; this one -
    /// deliberately not a `HelmFormSheet`, since it is read-only - gets it
    /// from `cancelOperation` alone.
    override func cancelOperation(_ sender: Any?) {
        closeClicked()
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

    // MARK: Theming

    private func applyChromeTheme() {
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6)
        for connector in connectorLines { connector.layer?.backgroundColor = line.cgColor }
        for name in nameLabels { name.textColor = HelmTheme.nsColor(theme.chromeInkHex) }
        for role in roleLabels { role.textColor = HelmTheme.mutedInk(theme) }
        // `close` is a `HelmButton` and themes itself.
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugCloseRequests = 0
    var debugTitle: String { titleLabel.stringValue }
    var debugSubtitle: String { subtitleLabel.stringValue }
    /// Every card's member, name text and role text, in the order they were
    /// built - root (Luffy) first, then `Self.branches`' own order - so a
    /// suite can assert both membership and that `role` was reused verbatim
    /// with no view mounted or laid out.
    var debugCards: [(member: StrawHatMember, name: String, role: String)] {
        var order: [StrawHatMember] = [.luffy]
        order.append(contentsOf: Self.branches)
        var out: [(StrawHatMember, String, String)] = []
        for (i, member) in order.enumerated() {
            guard nameLabels.indices.contains(i), roleLabels.indices.contains(i) else { continue }
            out.append((member, nameLabels[i].stringValue, roleLabels[i].stringValue))
        }
        return out
    }
    func debugCloseClicked() { closeClicked() }
    var debugConnectorCount: Int { connectorLines.count }
    #endif
}
