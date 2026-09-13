// Manjesh Grand Line - native macOS app.
//
// The credential inspector: Poneglyph's detail view, as a **permanent
// right-hand panel** rather than a centred modal.
//
// **Why it stopped being a sheet.** The captain's own words after living with
// the modal: the vault UI "is cramped, including the credential detail popup".
// Measured on the shipped build before this change, the sheet was the worse
// half of that - `HelmFormSheet` caps its column at `HelmFormSheet.width`
// (520) and centres it, so the detail's own content resolved to a ~190pt
// column adrift in the middle of the sheet, which is narrow enough that real
// data stopped being readable rather than merely looking tight: `Account`
// rendered as `manjesh@...`, `Location` as `mail.goo...`, `Created` as
// `13 Sep 2...`. A truncated account is not a cosmetic complaint about
// whitespace; it is the field failing to do its job.
//
// A panel fixes that and two other things a modal cannot. It is **permanent**,
// so moving between credentials is one click rather than open-read-dismiss-
// open; it sits beside the list, so the list stays on screen while a
// credential is read; and it has a fixed, generous width of its own
// (`Metrics.width`) instead of inheriting a dialog's.
//
// **It is a view, not an `NSViewController`.** It is owned by
// `CredentialVaultController` and mounted inside that page, which is what makes
// the security property below structural rather than something to remember.
//
// **The security property, and why this shape is stronger than the sheet's.**
// A `presentAsSheet` sheet is its own child *window*, layered above the app's
// lock overlay - the overlay is only a subview of the main window - which is
// the defect `fm/grandline-fix-high-severity`'s H2 had to fix by dismissing
// every sheet on every lock path. A panel is a subview of the page, so it is
// under that overlay by construction and there is no floating window to
// forget. Two things still have to be true and are asserted rather than
// assumed:
//
//   * Locking clears it (`CredentialVaultController.clearInspector`), because
//     the point is that the plaintext leaves memory and the screen, not merely
//     that something covers it.
//   * `onReveal` re-checks `store.isUnlocked` before putting a value on
//     screen - the same defence in depth the sheet carried, kept verbatim.
//
// **Reveal and Copy keep the captain's own split**, here as on a list row:
// Reveal shows the value and never touches the clipboard, Copy writes the
// clipboard and never puts the value on screen. Neither implies the other.

import AppKit

/// The one place this feature formats a date. Lifted out of the deleted
/// `CredentialVaultDetailController` unchanged - the settings sheet's audit log
/// reads it too, so it belongs to the feature rather than to any one screen.
///
/// GL-P3: cached, not per call. These are built for every history row of every
/// credential the captain clicks through.
enum CredentialVaultFormat {
    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func absolute(_ date: Date) -> String { absoluteFormatter.string(from: date) }
    static func relative(_ date: Date) -> String { relativeFormatter.localizedString(for: date, relativeTo: Date()) }
}

final class CredentialVaultInspectorView: NSView {

    /// The reference mockup's own proportions, translated. Its inspector is
    /// 320px wide with 25/22 body padding; this is 340 with the app's own
    /// `HelmMetrics` spacing, which lands at the same content width once the
    /// card's border and inset are taken off.
    enum Metrics {
        static let width: CGFloat = 340
        /// 50x50 at radius 14 in the reference. `HelmMetrics.tileLarge` is 40,
        /// so this is the one size in this file that is not already a token -
        /// the hero swatch is the panel's identity and is deliberately larger
        /// than any tile the rest of the app uses.
        static let heroTile: CGFloat = 48
        static let heroTileRadius: CGFloat = HelmMetrics.dWell
        /// Above a section header. The reference's `margin-top:23px`.
        static let sectionTop: CGFloat = 22
        /// A section header to its first row. The reference's `margin-bottom:12px`.
        static let sectionBottom: CGFloat = HelmMetrics.s3
        /// A field's label to the field itself.
        static let labelToField: CGFloat = HelmMetrics.s1 + 2
        /// One field to the next inside a section. The reference never puts two
        /// fields in one section, so this is the port's own choice - the panel's
        /// otherwise-consistent 12.
        static let fieldToField: CGFloat = HelmMetrics.s3
        static let rowSpacing: CGFloat = HelmMetrics.s2 + 2
    }

    // MARK: Callbacks

    var onEdit: ((VaultCredential) -> Void)?
    var onDelete: ((VaultCredential) -> Void)?
    /// Returns whether the reveal was allowed, so the panel keeps its
    /// masked/revealed state honest when a per-item Touch ID gate refuses. The
    /// page owns the gate and the audit event; this panel only asks.
    var onReveal: ((VaultCredential, @escaping (Bool) -> Void) -> Void)?
    var onCopy: ((VaultCredential) -> Void)?
    var onCopyAccount: ((VaultCredential) -> Void)?
    var onClose: (() -> Void)?

    // MARK: State

    private(set) var credential: VaultCredential?
    private var auditEvents: [VaultAuditEvent] = []
    private var isRevealed = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Chrome

    let card = HelmCard()
    private let headTitle = NSTextField(labelWithString: "Credential details")
    private let closeButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "xmark")
    private let headDivider = NSView()
    private let scroll = NSScrollView()
    private let column = FlippedView()
    private let stack = NSStackView()
    private let footer = NSView()
    private let footerDivider = NSView()
    private let deleteButton = HelmButton(title: "Delete", variant: .destructive, size: .small, symbol: "trash")
    private let editButton = HelmButton(title: "Edit credential", variant: .primary, size: .small, symbol: "pencil")
    private let emptyState = HelmEmptyState(symbol: "lock.doc",
                                            title: "Nothing selected",
                                            body: "Pick a credential on the left to read its account, history and notes here.",
                                            size: .compact)

    // MARK: Per-render views, re-themed rather than re-derived

    private var mutedLabels: [NSTextField] = []
    private var inkLabels: [NSTextField] = []
    private var kickerLabels: [NSTextField] = []
    private var codeLabels: [NSTextField] = []
    private var wells: [NSView] = []
    private var rules: [NSView] = []
    private var chips: [(pill: NSView, label: NSTextField, tint: HelmTint)] = []
    private var tiles: [IconTileView] = []
    private let secretLabel = NSTextField(labelWithString: "")
    private let revealButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "eye")

    // MARK: Build

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        headTitle.font = HelmType.cardTitle()
        headTitle.translatesAutoresizingMaskIntoConstraints = false
        // The head is fixed-width chrome in a fixed-width panel; the title is
        // the only thing that could otherwise make the panel a window floor.
        headTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close the inspector"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headDivider.wantsLayer = true
        headDivider.translatesAutoresizingMaskIntoConstraints = false

        // A flipped document view, or a body shorter than the panel rests
        // against the *bottom* of the clip view and leaves a gap above the hero
        // (AGENTS.md gotcha (9)).
        column.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(stack)

        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false

        footerDivider.wantsLayer = true
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        editButton.target = self
        editButton.action = #selector(editClicked)
        // Poneglyph's own hue, so the panel's one primary action reads as
        // belonging to this page. Set here rather than at construction because
        // `domainHue` re-points a `.primary`'s fill on every palette.
        editButton.domainHue = RailDestination.poneglyph.domainHue
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The reference gives Edit `flex:1` - it fills whatever Delete leaves.
        editButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        editButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footerRow = NSStackView(views: [deleteButton, editButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = HelmMetrics.s2
        // AGENTS.md gotcha (10): at the default `.gravityAreas` no hugging
        // priority is honoured, so Edit would not take the slack.
        footerRow.distribution = .fill
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerRow)
        footer.translatesAutoresizingMaskIntoConstraints = false

        secretLabel.font = HelmType.code()
        secretLabel.lineBreakMode = .byTruncatingTail
        secretLabel.isSelectable = true
        revealButton.target = self
        revealButton.action = #selector(revealClicked)

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        for child in [headTitle, closeButton, headDivider, scroll, emptyState, footerDivider, footer] as [NSView] {
            body.addSubview(child)
        }

        let gutter = HelmMetrics.s4
        NSLayoutConstraint.activate([
            headTitle.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: gutter),
            headTitle.topAnchor.constraint(equalTo: body.topAnchor, constant: HelmMetrics.s3),
            headTitle.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: headTitle.trailingAnchor, constant: HelmMetrics.s2),
            closeButton.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -HelmMetrics.s3),

            headDivider.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            headDivider.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            headDivider.topAnchor.constraint(equalTo: headTitle.bottomAnchor, constant: HelmMetrics.s3),
            headDivider.heightAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headDivider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            emptyState.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: gutter),
            emptyState.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -gutter),
            emptyState.topAnchor.constraint(equalTo: headDivider.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            column.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: gutter),
            stack.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -gutter),
            stack.topAnchor.constraint(equalTo: column.topAnchor, constant: HelmMetrics.s5),
            stack.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -HelmMetrics.s5),

            footerDivider.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            footerRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: gutter),
            footerRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -gutter),
            footerRow.topAnchor.constraint(equalTo: footer.topAnchor, constant: HelmMetrics.s3),
            footerRow.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -HelmMetrics.s3),
        ])

        card.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(body, insets: NSEdgeInsets())
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Content

    /// Show `credential`. `auditEvents` is this item's slice of the log,
    /// already filtered by the page - so this panel never touches the store.
    func show(_ credential: VaultCredential, auditEvents: [VaultAuditEvent]) {
        // A different credential always starts masked. Re-showing the *same*
        // one (a store change re-renders the page, including after a Copy) must
        // not silently re-mask a value the captain deliberately revealed and is
        // in the middle of reading.
        if self.credential?.id != credential.id { isRevealed = false }
        self.credential = credential
        self.auditEvents = auditEvents
        rebuild()
    }

    /// Clear the panel - no credential, nothing revealed, nothing in memory.
    /// Every lock path calls this; see this file's header for why that is the
    /// whole security contract of a panel rather than a sheet.
    func clear() {
        credential = nil
        auditEvents = []
        isRevealed = false
        rebuild()
    }

    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        mutedLabels.removeAll()
        inkLabels.removeAll()
        kickerLabels.removeAll()
        codeLabels.removeAll()
        wells.removeAll()
        rules.removeAll()
        chips.removeAll()
        tiles.removeAll()

        guard let credential else {
            emptyState.isHidden = false
            scroll.isHidden = true
            footer.isHidden = true
            footerDivider.isHidden = true
            closeButton.isHidden = true
            applyTheme(theme)
            return
        }
        emptyState.isHidden = true
        scroll.isHidden = false
        footer.isHidden = false
        footerDivider.isHidden = false
        closeButton.isHidden = false

        buildHero(credential)
        buildTags(credential)
        buildSecret(credential)
        buildUsage(credential)
        if !credential.notes.isEmpty { buildNotes(credential) }
        buildHistory(credential)

        applyTheme(theme)
        renderSecret()
        scroll.contentView.scroll(to: .zero)
    }

    // MARK: Sections

    private func buildHero(_ credential: VaultCredential) {
        let tile = IconTileView(size: Metrics.heroTile, cornerRadius: Metrics.heroTileRadius)
        tile.configure(symbol: credential.category.symbol, tint: credential.category.tint, pointSize: 21)
        tile.setContentHuggingPriority(.required, for: .horizontal)
        tiles.append(tile)

        let name = NSTextField(wrappingLabelWithString: credential.title)
        name.font = HelmType.sectionTitle()
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inkLabels.append(name)

        let type = NSTextField(labelWithString: credential.category.title)
        type.font = HelmType.caption()
        type.lineBreakMode = .byTruncatingTail
        type.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mutedLabels.append(type)

        let text = NSStackView(views: [name, type])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [tile, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        row.distribution = .fill
        append(row, spacingAfter: HelmMetrics.s4)
    }

    private func buildTags(_ credential: VaultCredential) {
        guard !credential.tags.isEmpty else { return }
        let flow = ChipFlowView()
        flow.translatesAutoresizingMaskIntoConstraints = false
        var pills: [NSView] = []
        for tag in credential.tags {
            let pill = NSView()
            let label = NSTextField(labelWithString: tag)
            // Deliberately NOT added to `pill` here: `ToolRowLayout.pill` adds
            // it and creates its padding constraints only when it is not
            // already a subview, so pre-adding it produces a chip with a label
            // and no size at all.
            chips.append((pill, label, .neutral))
            pills.append(pill)
        }
        flow.setChips(pills)
        appendFullWidth(flow, spacingAfter: HelmMetrics.s3)
    }

    private func buildSecret(_ credential: VaultCredential) {
        appendSection("01", "Secret")
        appendFieldLabel("Secret value")

        let well = NSView()
        HelmField.makeSunken(well)
        well.translatesAutoresizingMaskIntoConstraints = false
        wells.append(well)

        secretLabel.translatesAutoresizingMaskIntoConstraints = false
        secretLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        revealButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let copyButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "doc.on.doc",
                                    target: self, action: #selector(copyClicked))
        copyButton.toolTip = "Copy the value to the clipboard - does not show it on screen"
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let actions = NSStackView(views: [revealButton, copyButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 2
        actions.distribution = .fill
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setClippingResistancePriority(.required, for: .horizontal)
        actions.translatesAutoresizingMaskIntoConstraints = false

        well.addSubview(secretLabel)
        well.addSubview(actions)
        NSLayoutConstraint.activate([
            secretLabel.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: HelmMetrics.s3 - 2),
            secretLabel.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            actions.leadingAnchor.constraint(equalTo: secretLabel.trailingAnchor, constant: HelmMetrics.s2),
            actions.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -HelmMetrics.s1 - 2),
            actions.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            well.heightAnchor.constraint(equalToConstant: HelmField.controlHeight + 4),
        ])
        appendFullWidth(well, spacingAfter: HelmMetrics.s1 + 3)

        let hint = NSTextField(wrappingLabelWithString: credential.requiresTouchIDToReveal
            ? "Touch ID is required every time this value is revealed. Copy sends it straight to the clipboard without ever putting it on screen."
            : "Copy sends the value straight to the clipboard - it never has to appear on screen first. It clears itself afterward unless you have copied something else since.")
        hint.font = HelmType.captionSmall()
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mutedLabels.append(hint)
        appendFullWidth(hint)
    }

    private func buildUsage(_ credential: VaultCredential) {
        appendSection("02", "Where it's used")
        var any = false
        if !credential.account.isEmpty {
            appendFieldLabel("Account")
            let copy = HelmButton(title: "", variant: .quiet, size: .small, symbol: "doc.on.doc",
                                  target: self, action: #selector(copyAccountClicked))
            copy.toolTip = "Copy the account"
            appendValueWell(credential.account, code: true, trailing: copy)
            any = true
        }
        if !credential.location.isEmpty {
            if any { stack.setCustomSpacing(Metrics.fieldToField, after: stack.arrangedSubviews.last ?? stack) }
            appendFieldLabel("Location")
            appendValueWell(credential.location, code: true, trailing: nil)
            any = true
        }
        if !any {
            let caption = NSTextField(wrappingLabelWithString: "No account or location recorded for this credential.")
            caption.font = HelmType.caption()
            caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            mutedLabels.append(caption)
            appendFullWidth(caption)
        }
    }

    private func buildNotes(_ credential: VaultCredential) {
        appendSection("03", "Notes")
        let notes = NSTextField(wrappingLabelWithString: credential.notes)
        notes.font = HelmType.caption()
        notes.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mutedLabels.append(notes)
        appendFullWidth(notes)
    }

    private func buildHistory(_ credential: VaultCredential) {
        appendSection(credential.notes.isEmpty ? "03" : "04", "History")
        appendInfoRow("Created", CredentialVaultFormat.absolute(credential.createdAt))
        appendInfoRow("Updated", CredentialVaultFormat.absolute(credential.updatedAt))
        appendInfoRow("Last used", credential.lastUsedAt.map(CredentialVaultFormat.absolute) ?? "Never used")

        let reveals = auditEvents.filter { $0.kind == .revealed }.count
        let copies = auditEvents.filter { $0.kind == .copied }.count
        let summary = NSTextField(wrappingLabelWithString:
            "Revealed on screen \(Self.times(reveals)), copied \(Self.times(copies)).")
        summary.font = HelmType.captionSmall()
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mutedLabels.append(summary)
        stack.setCustomSpacing(HelmMetrics.s3, after: stack.arrangedSubviews.last ?? stack)
        appendFullWidth(summary)

        for event in auditEvents.sorted(by: { $0.at > $1.at }).prefix(Self.maxEvents) {
            appendAuditRow(event)
        }
        if auditEvents.count > Self.maxEvents {
            // "No silent caps" - say what was left out rather than trimming
            // quietly. The full log is in the settings sheet.
            let more = NSTextField(wrappingLabelWithString:
                "Showing the \(Self.maxEvents) most recent of \(auditEvents.count) events. The full log is in Poneglyph settings.")
            more.font = HelmType.captionSmall()
            more.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            mutedLabels.append(more)
            appendFullWidth(more)
        }
    }

    private static let maxEvents = 10

    // MARK: Row builders

    /// A section header: `01 · Secret` plus the trailing hairline the reference
    /// draws across the rest of the line.
    ///
    /// The number and the title are one uniform run, which is the reference's
    /// own treatment and also this app's - `HelmType.kickerAttributes` is the
    /// single kicker recipe, and a hand-rolled `.kern` anywhere else is a build
    /// failure (`HelmContrastSelfTest.checkNoHandRolledKickers`).
    private func appendSection(_ number: String, _ title: String) {
        let label = NSTextField(labelWithString: "")
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.tag = Self.sectionLabelTag
        // Stored on the label so `applyTheme` can re-run the attributes with
        // the new colour without this file keeping a parallel array of strings.
        label.placeholderString = "\(number) \u{00B7} \(title)"
        kickerLabels.append(label)

        let rule = NSView()
        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rules.append(rule)

        let row = NSStackView(views: [label, rule])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        // The first section sits directly under the tag row, which already
        // carries its own trailing spacing; every later one gets the full gap.
        let isFirst = !stack.arrangedSubviews.contains { $0.subviews.contains { $0.tag == Self.sectionLabelTag } }
        if let previous = stack.arrangedSubviews.last {
            stack.setCustomSpacing(isFirst ? HelmMetrics.s4 : Metrics.sectionTop, after: previous)
        }
        appendFullWidth(row, spacingAfter: Metrics.sectionBottom)
    }

    private static let sectionLabelTag = 8731

    private func appendFieldLabel(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.captionSmall()
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mutedLabels.append(label)
        appendFullWidth(label, spacingAfter: Metrics.labelToField)
    }

    /// A read-only value in a sunken well - the shape the reference uses for
    /// every value, and the reason this panel does not truncate the way the old
    /// sheet did: the well is full-width, so the value has the whole column.
    private func appendValueWell(_ value: String, code: Bool, trailing: NSView?) {
        let well = NSView()
        HelmField.makeSunken(well)
        well.translatesAutoresizingMaskIntoConstraints = false
        wells.append(well)

        let label = NSTextField(labelWithString: value)
        label.font = code ? HelmType.code() : HelmType.body()
        label.isSelectable = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.toolTip = value
        if code { codeLabels.append(label) } else { inkLabels.append(label) }
        well.addSubview(label)

        var constraints: [NSLayoutConstraint] = [
            label.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: HelmMetrics.s3 - 2),
            label.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            well.heightAnchor.constraint(equalToConstant: HelmField.controlHeight + 4),
        ]
        if let trailing {
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.translatesAutoresizingMaskIntoConstraints = false
            well.addSubview(trailing)
            constraints += [
                trailing.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: HelmMetrics.s2),
                trailing.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -HelmMetrics.s1 - 2),
                trailing.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(equalTo: well.trailingAnchor,
                                                               constant: -(HelmMetrics.s3 - 2)))
        }
        NSLayoutConstraint.activate(constraints)
        appendFullWidth(well)
    }

    /// A history line: label left, value right, both on one row. The value is
    /// the one that truncates, never the label - the old sheet's fixed 110pt
    /// label column plus a low-priority value is what produced `13 Sep 2...`.
    private func appendInfoRow(_ label: String, _ value: String) {
        let name = NSTextField(labelWithString: label)
        name.font = HelmType.caption()
        name.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        mutedLabels.append(name)

        let detail = NSTextField(labelWithString: value)
        detail.font = HelmType.caption()
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        detail.isSelectable = true
        detail.toolTip = value
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inkLabels.append(detail)

        let row = NSStackView(views: [name, detail])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = HelmMetrics.s3
        row.distribution = .fill
        appendFullWidth(row, spacingAfter: HelmMetrics.s2 - 2)
    }

    private func appendAuditRow(_ event: VaultAuditEvent) {
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: event.kind.symbol, accessibilityDescription: event.summary)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        glyph.contentTintColor = CredentialVaultInk.text(event.kind.tint, in: theme)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let text = NSTextField(labelWithString: event.summary)
        text.font = HelmType.captionSmall()
        text.lineBreakMode = .byTruncatingTail
        text.toolTip = event.summary
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mutedLabels.append(text)

        let when = NSTextField(labelWithString: CredentialVaultFormat.relative(event.at))
        when.font = HelmType.captionSmall()
        when.toolTip = CredentialVaultFormat.absolute(event.at)
        when.setContentHuggingPriority(.required, for: .horizontal)
        when.setContentCompressionResistancePriority(.required, for: .horizontal)
        mutedLabels.append(when)

        let row = NSStackView(views: [glyph, text, when])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        appendFullWidth(row, spacingAfter: HelmMetrics.s1)
    }

    // MARK: Stack plumbing

    private func append(_ view: NSView, spacingAfter: CGFloat? = nil) {
        stack.addArrangedSubview(view)
        if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: view) }
    }

    /// Every row in this panel is full width - the column is fixed and narrow,
    /// so a row hugging its own content is what leaves a value truncated beside
    /// empty space. `stack.alignment` is `.leading`, which does *not* stretch
    /// arranged subviews, so each one is tied to the stack's own width.
    private func appendFullWidth(_ view: NSView, spacingAfter: CGFloat? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: view) }
    }

    // MARK: Secret rendering

    private func renderSecret() {
        guard let credential else { return }
        if isRevealed {
            secretLabel.stringValue = credential.secret.isEmpty ? "(no value stored)" : credential.secret
            secretLabel.textColor = HelmField.ink(theme)
            secretLabel.toolTip = nil
            revealButton.symbolName = "eye.slash"
            revealButton.tint = .warn
            revealButton.toolTip = "Hide the value again (this never touched the clipboard)"
        } else {
            // A fixed-width mask rather than one dot per character: the length
            // of a secret is itself worth not disclosing to someone reading
            // over a shoulder.
            secretLabel.stringValue = String(repeating: "\u{2022}", count: 16)
            secretLabel.textColor = HelmField.mutedInk(theme)
            secretLabel.toolTip = nil
            revealButton.symbolName = "eye"
            revealButton.tint = nil
            revealButton.toolTip = "Show the value on screen - does not copy it"
        }
    }

    private static func times(_ count: Int) -> String {
        switch count {
        case 0: return "never"
        case 1: return "once"
        default: return "\(count) times"
        }
    }

    // MARK: Actions

    @objc private func revealClicked() {
        guard let credential else { return }
        if isRevealed {
            // Hiding needs no permission and logs nothing - only putting a
            // value on screen is an event worth recording.
            isRevealed = false
            renderSecret()
            return
        }
        guard let onReveal else {
            isRevealed = true
            renderSecret()
            return
        }
        onReveal(credential) { [weak self] allowed in
            guard let self, allowed else { return }
            self.isRevealed = true
            self.renderSecret()
        }
    }

    @objc private func copyClicked() {
        guard let credential else { return }
        onCopy?(credential)
    }

    @objc private func copyAccountClicked() {
        guard let credential else { return }
        onCopyAccount?(credential)
    }

    @objc private func editClicked() {
        guard let credential else { return }
        onEdit?(credential)
    }

    @objc private func deleteClicked() {
        guard let credential else { return }
        onDelete?(credential)
    }

    @objc private func closeClicked() { onClose?() }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        emptyState.applyTheme(theme)

        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let hairline = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor

        headTitle.textColor = ink
        headDivider.layer?.backgroundColor = hairline
        footerDivider.layer?.backgroundColor = hairline
        for rule in rules { rule.layer?.backgroundColor = hairline }
        for label in inkLabels { label.textColor = ink }
        for label in mutedLabels { label.textColor = muted }
        for label in codeLabels { label.textColor = HelmField.ink(theme) }
        for label in kickerLabels {
            label.attributedStringValue = NSAttributedString(
                string: (label.placeholderString ?? "").uppercased(),
                attributes: HelmType.kickerAttributes(color: muted))
        }
        for well in wells { HelmField.applySunken(to: well, theme: theme) }
        for tile in tiles { tile.applyTheme(theme) }
        for chip in chips {
            ToolRowLayout.pill(text: chip.label.stringValue,
                               colorHex: chip.tint.hex(in: theme),
                               into: chip.pill, label: chip.label, theme: theme)
        }
        renderSecret()
    }

    #if FM_SELFTESTS
    var debugIsRevealed: Bool { isRevealed }
    var debugSecretLabel: NSTextField { secretLabel }
    var debugRevealButton: HelmButton { revealButton }
    var debugEditButton: HelmButton { editButton }
    var debugDeleteButton: HelmButton { deleteButton }
    var debugCloseButton: HelmButton { closeButton }
    var debugIsEmptyStateShowing: Bool { !emptyState.isHidden }
    var debugSectionTitles: [String] { kickerLabels.compactMap { $0.placeholderString } }
    /// Every value this panel put on screen, so a probe can assert that a real
    /// account or date is rendered in full rather than truncated.
    var debugValueLabels: [NSTextField] { codeLabels + inkLabels }
    /// The sunken field boxes, and the width of the column they sit in.
    ///
    /// Asserted together because "the value is not truncated" is not on its own
    /// the property that was broken: a field hugging its own content never
    /// truncates *either*, it just sits in a narrow box beside empty space,
    /// which is what the old sheet's capped centred column produced. The fix is
    /// that a field **fills the column**, so the value has the whole of it.
    var debugValueWells: [NSView] { wells }
    var debugContentWidth: CGFloat { stack.frame.width }
    #endif
}
