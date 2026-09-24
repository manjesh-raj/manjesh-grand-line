// Grand Line - native macOS app.
//
// The Hosts destination's right-hand panel stack: Workspace, Selected, and
// Quick actions - the three cards the captain's reference mockup
// (`data/grand-line-hosts-page-redesign/reference-design.html`, firstmate-side)
// stacks beside the saved-host list.
//
// **Why the page gained a second column at all.** Before this, Hosts was one
// gutter-to-gutter list card: a row's two short strings sat at the far left and
// its Connect/`⋯` pair at the far right, with most of a laptop-width window of
// nothing between them, and a host's full endpoint, user and credential were
// only readable by opening the host editor. That is the same "cramped" shape
// Poneglyph was corrected for in
// `fm/grand-line-roomier-poneglyph-vault-ui-li-0f`, and the fix is the same
// one: give the detail a column of its own so the list gets a column it can
// actually fill, and so reading a host does not mean opening a modal over it.
//
// **Everything here is real, and that is the constraint that shaped it.** The
// reference is a standalone mockup carrying invented demo data (a "Terminal
// Hub" workspace, a hardcoded "100% Keychain protected" metric, a
// "Recently used" filter, `⌘⇧P Run snippet`). A panel that renders a shape
// with nothing behind it looks finished and lies, so each piece below is wired
// to a real store, a real system probe, or a real menu shortcut - and what
// could not be is left out rather than padded. What was left out, and why, is
// recorded on the pieces themselves.
//
// **Built from the app's own components, not new chrome**: `HelmCard`,
// `HelmStatTile`, `IconTileView`, `HelmButton`, `HelmType`/`HelmMetrics`
// tokens. Nothing here paints a colour of its own.

import AppKit

// MARK: - Workspace

/// At-a-glance inventory: the three stores' counts, how many hosts are live
/// right now, and whether the Keychain's Touch ID gate is actually available
/// on this Mac.
///
/// Every number is handed in by the page from the same stores the list beside
/// it renders, so this card and that list can never disagree within a frame -
/// the rule `FleetDataSource.readyToMerge` exists for one page over.
final class HostsWorkspacePanel: NSView {

    let card = HelmCard()

    private let hostsTile = HelmStatTile(symbol: "server.rack", caption: "Hosts")
    private let keysTile = HelmStatTile(symbol: "key.fill", caption: "SSH keys")
    private let snippetsTile = HelmStatTile(symbol: "chevron.left.forwardslash.chevron.right",
                                            caption: "Snippets")
    /// The reference's fourth metric is a hardcoded "100% Keychain protected",
    /// which is a claim rather than a measurement. Live sessions is the real
    /// number this page already knows (`HostsController.liveSession`, the
    /// app's one `HostSessionRegistry`) and the one most worth a glance.
    private let liveTile = HelmStatTile(symbol: "bolt.fill", caption: "Live sessions", tint: .good)

    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusOK = true
    /// The theme this panel was last *given*, re-applied when its content
    /// changes. Reading `ThemeManager.shared.theme` here instead would make a
    /// caller's `applyTheme(_:)` argument a lie the moment the two differ -
    /// the latent divergence `HelmSegmentedTabs.layout()` was corrected for.
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        // A 2x2 grid, the reference's own `.metric-grid`. Two `.fillEqually`
        // rows rather than an `NSGridView`: the tiles are all one fixed height
        // and want equal widths, which is exactly what that distribution is.
        let topRow = NSStackView(views: [hostsTile, keysTile])
        let bottomRow = NSStackView(views: [snippetsTile, liveTile])
        for row in [topRow, bottomRow] {
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = HelmMetrics.s2
        }

        statusDot.wantsLayer = true
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = HelmType.captionSmall()
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        // The panel is a fixed-width column, so the only thing in it that
        // could otherwise become a window floor is a long status string.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusRow = NSView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addSubview(statusDot)
        statusRow.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: HelmMetrics.s2),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusRow.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: statusRow.topAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: statusRow.bottomAnchor),
        ])

        let body = NSStackView(views: [topRow, bottomRow, statusRow])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.translatesAutoresizingMaskIntoConstraints = false
        for row in [topRow, bottomRow, statusRow] as [NSView] {
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        _ = card.setHeader(symbol: "square.grid.2x2.fill", tint: .neutral,
                           title: "Workspace",
                           subtitle: "At-a-glance inventory")
        card.setBody(body, insets: HelmCard.contentInsets)

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// `touchIDAvailable` is `CredentialVaultKeyStore.biometryAvailable`, a
    /// real `LAContext.canEvaluatePolicy` probe - not the reference's
    /// unconditional "Touch ID enabled".
    func setCounts(hosts: Int, keys: Int, snippets: Int, live: Int, touchIDAvailable: Bool) {
        hostsTile.value = "\(hosts)"
        keysTile.value = "\(keys)"
        snippetsTile.value = "\(snippets)"
        liveTile.value = "\(live)"
        statusOK = touchIDAvailable
        // UI1: one wording, defined once - see `HostsKeychainCard.biometryPhrase`.
        // The "Keychain available" half went with it: nothing here probes
        // whether the Keychain is reachable, so it was an unconditional claim
        // sitting beside the sidebar footer's own honest "Keychain / Empty"
        // verdict, which is about a different thing (how many keys this app
        // holds) and read as a contradiction.
        statusLabel.stringValue = HostsKeychainCard.biometryPhrase(touchIDAvailable,
                                                                   capitalized: true)
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        for tile in [hostsTile, keysTile, snippetsTile, liveTile] { tile.applyTheme(theme) }
        statusLabel.textColor = HelmTheme.mutedInk(theme)
        // The dot is a fill, so the hue is safe on it raw - unlike the label
        // beside it, which stays `mutedInk` (audit §5.7: a tint is safe as a
        // fill and is not automatically safe as text).
        let tint: HelmTint = statusOK ? .good : .warn
        statusDot.layer?.backgroundColor = HelmTheme.nsColor(tint.hex(in: theme)).cgColor
        statusDot.layer?.cornerRadius = 3.5
    }

    #if FM_SELFTESTS
    var debugMetrics: [(value: String, caption: String)] {
        [hostsTile, keysTile, snippetsTile, liveTile].map { $0.debugMetric }
    }
    var debugStatusText: String { statusLabel.stringValue }
    #endif
}

// MARK: - Selected record

/// What the selected list row is, in full: the reference's "Selected host"
/// panel, generalised to whichever of the three tabs is showing (its own demo
/// does the same - `detail(x)` is fed the current tab's record).
///
/// The fields are read straight off the real `Host` / `SSHKey` / `Snippet`, so
/// there is nothing here the host editor does not already own.
struct HostsDetailContent {
    struct Field {
        let label: String
        let value: String
        let isCode: Bool

        init(_ label: String, _ value: String, isCode: Bool = false) {
            self.label = label
            self.value = value
            self.isCode = isCode
        }
    }

    var symbol: String
    var tint: HelmTint = .accent
    /// A saved host's own `accentHex` - a colour the captain chose, which no
    /// semantic `HelmTint` honestly describes (the distinction
    /// `HelmAccentRow.Content.tintHex` already draws).
    var tintHex: String?
    var kicker: String
    var title: String
    var subtitle: String
    var fields: [Field]
    /// Real actions only - each one runs the same closure the row's own
    /// button does, never a second implementation.
    var actions: [HostsListSection.Action] = []
}

final class HostsDetailPanel: NSView {

    let card = HelmCard()

    private let tile = IconTileView(size: 38, cornerRadius: HelmMetrics.rRow)
    private let kickerLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let fieldsStack = NSStackView()
    private let actionsStack = NSStackView()
    private let content = NSView()
    private let emptyState = HelmEmptyState(
        symbol: "hand.tap",
        title: nil,
        body: "Select a row to see its details here.",
        size: .compact)

    private var fieldLabels: [NSTextField] = []
    /// The wrapping (code) value labels, which need their wrap width re-read
    /// from the resolved layout - see `layout()`.
    private var wrappingValues: [NSTextField] = []
    private var fieldValues: [(label: NSTextField, isCode: Bool)] = []
    private var actionButtons: [HelmButton] = []
    private var actions: [HostsListSection.Action] = []
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = HelmType.rowTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = HelmType.captionSmall()
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        for label in [kickerLabel, titleLabel, subtitleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            // A fixed-width panel: the text truncates, it never widens the page
            // (gotcha (13) - a label at `NSTextField`'s default 750 is a floor
            // on the whole window).
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let headText = NSStackView(views: [kickerLabel, titleLabel, subtitleLabel])
        headText.orientation = .vertical
        headText.alignment = .leading
        headText.spacing = 2
        headText.translatesAutoresizingMaskIntoConstraints = false
        headText.setHuggingPriority(.defaultLow, for: .horizontal)
        headText.setClippingResistancePriority(.defaultLow, for: .horizontal)

        tile.translatesAutoresizingMaskIntoConstraints = false
        let head = NSStackView(views: [tile, headText])
        head.orientation = .horizontal
        head.alignment = .top
        head.spacing = HelmMetrics.s2
        // AGENTS.md gotcha (10): at the default `.gravityAreas` no hugging
        // priority is honoured at all, so the text column would not take the
        // slack the tile leaves.
        head.distribution = .fill
        head.translatesAutoresizingMaskIntoConstraints = false

        fieldsStack.orientation = .vertical
        fieldsStack.alignment = .leading
        fieldsStack.spacing = HelmMetrics.s2
        fieldsStack.translatesAutoresizingMaskIntoConstraints = false
        fieldsStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = HelmMetrics.s2
        actionsStack.distribution = .fillEqually
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [head, fieldsStack, actionsStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s3
        column.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            head.widthAnchor.constraint(equalTo: column.widthAnchor),
            fieldsStack.widthAnchor.constraint(equalTo: column.widthAnchor),
            actionsStack.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(content)
        body.addSubview(emptyState)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            content.topAnchor.constraint(equalTo: body.topAnchor),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: body.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])

        _ = card.setHeader(symbol: "info.circle.fill", tint: .info,
                           title: "Selected",
                           subtitle: "Details for the highlighted row")
        card.setBody(body, insets: HelmCard.contentInsets)

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        clear()
    }

    // MARK: Content

    func show(_ detail: HostsDetailContent) {
        content.isHidden = false
        emptyState.isHidden = true

        tile.configure(symbol: detail.symbol, tint: detail.tint)
        if let hex = detail.tintHex { tile.overrideFill(hex: hex) }
        kickerLabel.stringValue = detail.kicker
        titleLabel.stringValue = detail.title
        subtitleLabel.stringValue = detail.subtitle

        rebuildFields(detail.fields)
        rebuildActions(detail.actions)
        applyTheme(theme)
    }

    func clear() {
        content.isHidden = true
        emptyState.isHidden = false
        // The rows are torn down, not merely hidden with the view above them:
        // an ordinary hidden `NSView`'s constraints still participate fully in
        // layout (AGENTS.md gotcha (11)), so leaving the last record's fields
        // in place kept this card as tall as whatever had been selected before
        // - measured at 317pt for an empty panel that needs 237 - and made its
        // height depend on a record nobody can see.
        tile.configure(symbol: "hand.tap", tint: .neutral)
        kickerLabel.stringValue = ""
        titleLabel.stringValue = ""
        subtitleLabel.stringValue = ""
        rebuildFields([])
        rebuildActions([])
        actions = []
    }

    private func rebuildFields(_ fields: [HostsDetailContent.Field]) {
        for view in fieldsStack.arrangedSubviews {
            fieldsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        fieldLabels.removeAll()
        fieldValues.removeAll()
        wrappingValues.removeAll()

        for field in fields {
            let name = NSTextField(labelWithString: field.label)
            name.font = HelmType.captionSmall()
            name.alignment = .left
            name.lineBreakMode = .byTruncatingTail
            name.translatesAutoresizingMaskIntoConstraints = false
            name.setContentHuggingPriority(.required, for: .horizontal)
            name.setContentCompressionResistancePriority(.required, for: .horizontal)

            let value = NSTextField(labelWithString: field.value)
            value.font = field.isCode ? HelmType.code() : HelmType.caption()
            value.isSelectable = true
            value.translatesAutoresizingMaskIntoConstraints = false
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // The whole value is on the tooltip either way, so nothing is ever
            // only half-readable.
            value.toolTip = field.value

            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(name)
            row.addSubview(value)

            if field.isCode {
                // A code value - an endpoint, a fingerprint, a command - gets
                // the panel's whole width on its own line, and wraps once
                // rather than truncating.
                //
                // This is Poneglyph's own lesson applied a page over: a label
                // that renders `ec2-44-206-131-…-1.amazonaws.com` has stopped
                // doing its job, and that is not a whitespace complaint. Beside
                // a label in a 320pt column there are ~180pt for it; stacked
                // there are ~286, which is the difference between a readable
                // endpoint and an elided one.
                value.alignment = .left
                value.lineBreakMode = .byCharWrapping
                value.maximumNumberOfLines = 2
                wrappingValues.append(value)
                NSLayoutConstraint.activate([
                    name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    name.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
                    name.topAnchor.constraint(equalTo: row.topAnchor),
                    value.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    value.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    value.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
                    value.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                ])
            } else {
                value.alignment = .right
                value.lineBreakMode = .byTruncatingTail
                NSLayoutConstraint.activate([
                    name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                    name.topAnchor.constraint(equalTo: row.topAnchor),
                    name.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                    value.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: HelmMetrics.s2),
                    value.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    value.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
                    value.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
                    value.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
                ])
            }

            fieldLabels.append(name)
            fieldValues.append((value, field.isCode))
            fieldsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: fieldsStack.widthAnchor).isActive = true
        }
        needsLayout = true
    }

    /// A wrapping label's intrinsic width is its `preferredMaxLayoutWidth`, so
    /// it has to be told the width it really got - read back from the stack
    /// that resolved it, never a hardcoded guess, which is the documented trap
    /// (`HelmEmptyState.layout()` does the same for the same reason: an
    /// over-estimate makes AppKit size the label one line tall and then draw
    /// the second line outside its own bounds).
    override func layout() {
        super.layout()
        let width = fieldsStack.frame.width
        guard width > 1 else { return }
        for label in wrappingValues where label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
        }
    }

    private func rebuildActions(_ newActions: [HostsListSection.Action]) {
        for view in actionsStack.arrangedSubviews {
            actionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        actionButtons.removeAll()
        actions = newActions
        actionsStack.isHidden = newActions.isEmpty

        for (index, action) in newActions.enumerated() {
            let button = HelmButton(title: action.title,
                                    variant: index == 0 ? .primary : .secondary,
                                    size: .small,
                                    symbol: action.symbol,
                                    target: self,
                                    action: #selector(actionClicked(_:)))
            button.tag = index
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            actionButtons.append(button)
            actionsStack.addArrangedSubview(button)
        }
    }

    @objc private func actionClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        actions[sender.tag].run()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        tile.applyTheme(theme)
        emptyState.applyTheme(theme)
        let muted = HelmTheme.mutedInk(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        kickerLabel.attributedStringValue = NSAttributedString(
            string: kickerLabel.stringValue.uppercased(),
            attributes: HelmType.kickerAttributes(color: muted))
        titleLabel.textColor = ink
        subtitleLabel.textColor = muted
        for label in fieldLabels { label.textColor = muted }
        for (label, _) in fieldValues { label.textColor = ink }
    }

    #if FM_SELFTESTS
    var debugIsEmpty: Bool { !emptyState.isHidden }
    var debugTitle: String { titleLabel.stringValue }
    var debugFields: [(String, String)] {
        zip(fieldLabels, fieldValues).map { ($0.stringValue, $1.label.stringValue) }
    }
    var debugActionTitles: [String] { actionButtons.map(\.title) }
    func debugClickAction(_ index: Int) {
        guard index < actionButtons.count else { return }
        actionButtons[index].performClick(nil)
    }
    #endif
}

// MARK: - Quick actions

/// The reference's shortcut grid. **Only shortcuts this app really has** - the
/// brief's own rule, and the reason this carries four of its six: the
/// reference's `⌘ ↵ Connect selected` and `⌘ ⇧ P Run snippet` are not bound to
/// anything in this app, and a button advertising a keystroke that does
/// nothing is worse than no button.
///
/// The four below are read off `main.swift`'s real menu items (`⌘K` Search…,
/// `⌘⌃N` New Host…, `⌘⇧N` New Key…, `⌘⌥N` New Snippet…), and clicking one
/// performs the action as well as naming it - so it is a real control, not a
/// legend.
final class HostsQuickActionsPanel: NSView {

    struct Item {
        let shortcut: String
        let title: String
        let run: () -> Void
    }

    let card = HelmCard()

    private let grid = NSStackView()
    private var buttons: [(button: HoverHighlightView, shortcut: NSTextField, title: NSTextField)] = []
    private var items: [Item] = []
    /// See `HostsWorkspacePanel.theme` - same reasoning.
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = HelmMetrics.s2
        grid.translatesAutoresizingMaskIntoConstraints = false

        _ = card.setHeader(symbol: "command", tint: .violet,
                           title: "Quick actions",
                           subtitle: "Keyboard and mouse, same result")
        card.setBody(grid, insets: HelmCard.contentInsets)

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Rebuilt whole - a handful of fixed items, so there is nothing to diff.
    func setItems(_ items: [Item]) {
        for view in grid.arrangedSubviews {
            grid.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        buttons.removeAll()
        self.items = items

        // Two per row, the reference's own 2x2.
        for pair in stride(from: 0, to: items.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = HelmMetrics.s2
            row.translatesAutoresizingMaskIntoConstraints = false
            for index in pair..<min(pair + 2, items.count) {
                row.addArrangedSubview(makeButton(items[index]))
            }
            // A trailing odd item would otherwise stretch across the whole
            // row under `.fillEqually` - the same partial-row padding
            // `HelmResponsiveGrid` does for a card grid.
            if items.count - pair == 1 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(spacer)
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        applyTheme(theme)
    }

    /// A `HoverHighlightView` rather than a hand-rolled clickable view: it is
    /// this app's one hover/press/focus-ring treatment, and GL-16's button
    /// role plus keyboard activation come with it. It carries only labels -
    /// a nested real control would be the hit-testing hazard that class's
    /// header warns about.
    private func makeButton(_ item: Item) -> NSView {
        let button = HoverHighlightView()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.cornerRadius = HelmMetrics.rControl
        button.pressScale = HelmModuleCard.pressScale

        let shortcut = NSTextField(labelWithString: item.shortcut)
        shortcut.font = HelmType.chip()
        shortcut.lineBreakMode = .byClipping
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        shortcut.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let title = NSTextField(labelWithString: item.title)
        title.font = HelmType.captionSmall()
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [shortcut, title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        button.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: HelmMetrics.s2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -HelmMetrics.s2),
            stack.topAnchor.constraint(equalTo: button.topAnchor, constant: HelmMetrics.s2),
            stack.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -HelmMetrics.s2),
        ])

        button.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(buttonClicked(_:))))
        button.accessibilityRoleOverride = .button
        button.accessibilityLabelOverride = "\(item.title) (\(item.shortcut))"
        button.toolTip = "\(item.title) \u{00B7} \(item.shortcut)"
        buttons.append((button, shortcut, title))
        return button
    }

    @objc private func buttonClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view,
              let index = buttons.firstIndex(where: { $0.button === view }),
              index < items.count else { return }
        items[index].run()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        let muted = HelmTheme.mutedInk(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        let hover = surface.blended(withFraction: HelmAccentRow.selectionWash, of: accent) ?? surface
        let rest = HelmField.fill(theme)
        for entry in buttons {
            entry.shortcut.textColor = ink
            entry.title.textColor = muted
            // Both colours, never `layer.backgroundColor` directly: a
            // `HoverHighlightView` owns persistent hover state and a direct
            // layer write is stranded by the next `mouseExited`
            // (`fm/grandline-updates-refresh-button-light-mode-fix`).
            entry.button.normalColor = rest
            entry.button.hoverColor = hover
            entry.button.layer?.cornerRadius = HelmMetrics.rControl
        }
    }

    #if FM_SELFTESTS
    var debugShortcuts: [String] { buttons.map { $0.shortcut.stringValue } }
    var debugTitles: [String] { buttons.map { $0.title.stringValue } }
    func debugClick(_ index: Int) {
        guard index < items.count else { return }
        items[index].run()
    }
    #endif
}

// MARK: - The stack

/// The three panels as one fixed-width column.
///
/// **Window-floor discipline** (gotchas (13)/(14)): the column's width sits at
/// `HelmDaylightPriority.contentTie` (499), below
/// `NSLayoutPriorityWindowSizeStayPut`, so it can never stop the window
/// shrinking - `AppShellBodyWidthSelfTest` sweeps every destination for
/// exactly that, and `HelmPageSidebar` records the measurement that made this
/// the rule rather than a precaution.
final class HostsSideStack: NSView {

    static let width: CGFloat = 320

    let workspace = HostsWorkspacePanel()
    let detail = HostsDetailPanel()
    let quickActions = HostsQuickActionsPanel()
    /// F12. Shown only on the Snippets tab - it is the one panel here that is
    /// about a single tab rather than about the page. An *arranged* subview,
    /// so hiding it genuinely removes it from the column's layout (gotcha
    /// (11): an ordinary hidden `NSView` would keep its height forever).
    let expansion = SnippetExpansionPanel()

    private let scroll = NSScrollView()
    private let document = FlippedView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [workspace, detail, expansion, quickActions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false

        // **The three cards scroll, and that is a window-*height* fix** -
        // review #3's B5.
        //
        // Both bottom pins here were already `<=`, which is what makes the
        // column end above the page's gutter rather than stretching a card -
        // and neither of them lets the column be *shorter* than its content.
        // Nothing else in the chain did either: each panel's own labels are
        // required-height, the stack is required to its own top, and the page
        // pins that top under the tab strip. So the whole column was a
        // required floor on the window's height, and it is the height twin of
        // the width class this app has fixed five times: measured at 1100x750,
        // showing Hosts and then selecting a host took the page's required
        // fitting height to **830pt against a 750pt window**, and it never
        // shrank back.
        //
        // A scroll view is the one shape that lets the content be taller than
        // the space it is given. `HelmPageSidebar` reached the same conclusion
        // for its own rows; this is that mechanism, with its three rules
        // intact: a `FlippedView` document (gotcha (9) - a plain one rests
        // against the *bottom* of a short clip view), pinned to the **clip**
        // view and only on the axis that does not scroll (gotcha (4)), and no
        // scroller, because a non-overlay one reserves a real ~15pt track.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            // **`==`, and review #3's UI1 is what made that necessary.**
            //
            // This was `<=`, on the reasoning that the three cards size to
            // their own content and the column should end above the page's
            // bottom gutter rather than stretch one of them to fill it. That
            // reasoning is right and is unchanged - it is just not this
            // constraint's job. With `<=` here and only `top ==` above,
            // nothing tied this view's *own* height to the scroll view inside
            // it, so the column's height was under-determined: the page pins
            // its top and caps its bottom, and the only thing with an opinion
            // about how tall it should be was the 499-priority content-height
            // preference below.
            //
            // Auto Layout resolves an under-determined system by picking, and
            // what it picked once the column got taller was to break the
            // required `top ==` and let the scroll view escape upward.
            // Measured at 1512x950 with a host selected (which grows the
            // detail panel, and therefore the document): the column's frame
            // was `(1168, 244, 320, 606)` while the scroll view inside it sat
            // at `(1168, 314, 320, 756)` - 220pt taller than its own
            // container and 120pt above the window's top edge, so the
            // Workspace panel rendered over the app's top bar. UI1 removing
            // the tab strip above this column moved its top up ~44pt, which is
            // what turned a latent overflow into a visible one.
            //
            // `==` determines it: the scroll view is exactly this view, this
            // view's height comes from the page (top pinned, bottom capped),
            // and "as tall as its cards, but never a floor" stays exactly
            // where it belongs - on the 499-priority `contentHeight` below.
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        for panel in [workspace, detail, quickActions] as [NSView] {
            panel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // A scroll view has no intrinsic height, so this is the only thing
        // giving the column one: it prefers to be exactly as tall as its cards
        // (which is what every window big enough gets, unchanged), and at
        // `contentTie` (499) it sits below `NSLayoutPriorityWindowSizeStayPut`,
        // so it can never be a floor on how short the window may get - gotcha
        // (13), and the whole point of the fix. `HelmPageSidebar` uses the
        // identical constraint for the identical reason.
        let contentHeight = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        contentHeight.priority = HelmDaylightPriority.contentTie
        contentHeight.isActive = true

        let columnWidth = widthAnchor.constraint(equalToConstant: Self.width)
        columnWidth.priority = HelmDaylightPriority.contentTie
        columnWidth.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: HelmTheme) {
        workspace.applyTheme(theme)
        detail.applyTheme(theme)
        expansion.applyTheme(theme)
        quickActions.applyTheme(theme)
    }
}
