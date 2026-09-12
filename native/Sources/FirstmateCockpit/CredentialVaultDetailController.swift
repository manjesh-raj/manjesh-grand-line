// Manjesh Grand Line - native macOS app.
//
// Item Detail: what a list row genuinely cannot show.
//
// The captain's own review feedback settled what this screen is *for*. He asked
// for reveal and copy directly on every list row ("I do not want to go inside
// each of them here"), and the artifact records the resolution: the row got both
// icon buttons, and Item Detail was **kept rather than removed** for notes,
// exact timestamps, edit, delete and the per-item audit history. So this sheet
// deliberately does not try to be the primary way to reach a value - it is the
// place to read the surrounding facts, and it carries its own Reveal and Copy
// only because being here should not mean going back to the list to use them.
//
// Reveal and Copy are the same two independent actions they are on a row, with
// the same contract: Reveal shows the value on screen and never touches the
// clipboard, Copy writes the clipboard and never puts the value on screen.

import AppKit

final class CredentialVaultDetailController: NSViewController {

    var onEdit: ((VaultCredential) -> Void)?
    var onDelete: ((VaultCredential) -> Void)?
    /// Both return whether the action was allowed to proceed, so this sheet can
    /// keep its masked/revealed state honest when a per-item Touch ID gate
    /// refuses. The page owns the gate and the audit event; this sheet only
    /// asks.
    var onReveal: ((VaultCredential, @escaping (Bool) -> Void) -> Void)?
    var onCopy: ((VaultCredential) -> Void)?

    private let credential: VaultCredential
    private let auditEvents: [VaultAuditEvent]

    private let secretLabel = NSTextField(labelWithString: "")
    private let revealButton = HelmButton(title: "Reveal", variant: .secondary, symbol: "eye")
    private let copyButton = HelmButton(title: "Copy", variant: .primary, symbol: "doc.on.doc")
    private let secretHint = NSTextField(wrappingLabelWithString: "")
    private var isRevealed = false
    private var form: HelmFormSheet!

    /// `auditEvents` is this item's slice of the log, already filtered by the
    /// page - so this sheet never touches the store.
    init(credential: VaultCredential, auditEvents: [VaultAuditEvent]) {
        self.credential = credential
        self.auditEvents = auditEvents
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let sheet = HelmFormSheet(title: credential.title,
                                  scrolls: true,
                                  domainHue: RailDestination.poneglyph.domainHue)
        form = sheet
        view = sheet

        sheet.setSubtitle("\(credential.category.title)\(credential.tags.isEmpty ? "" : " \u{00B7} " + credential.tags.joined(separator: ", "))")

        sheet.addSection("Secret", number: "01")
        secretLabel.font = HelmType.code()
        secretLabel.lineBreakMode = .byTruncatingTail
        secretLabel.isSelectable = true
        let secretWell = NSView()
        HelmField.makeSunken(secretWell)
        secretWell.translatesAutoresizingMaskIntoConstraints = false
        secretLabel.translatesAutoresizingMaskIntoConstraints = false
        secretWell.addSubview(secretLabel)
        NSLayoutConstraint.activate([
            secretLabel.leadingAnchor.constraint(equalTo: secretWell.leadingAnchor, constant: HelmMetrics.s3),
            secretLabel.trailingAnchor.constraint(equalTo: secretWell.trailingAnchor, constant: -HelmMetrics.s3),
            secretLabel.centerYAnchor.constraint(equalTo: secretWell.centerYAnchor),
            secretWell.heightAnchor.constraint(equalToConstant: HelmField.controlHeight),
        ])

        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        revealButton.toolTip = "Show the value on screen - does not copy it"
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.toolTip = "Copy the value to the clipboard - does not show it on screen"
        // Poneglyph's own hue (`RailDestination.poneglyph.domainHue`), so the
        // one primary action on this sheet reads as belonging to this page
        // rather than as a generic accent button. Set here rather than at
        // construction because `domainHue` re-points a `.primary`'s fill on
        // every palette.
        copyButton.domainHue = RailDestination.poneglyph.domainHue

        let actionRow = NSStackView(views: [revealButton, copyButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = HelmMetrics.s2
        actionRow.distribution = .fill
        actionRow.setHuggingPriority(.required, for: .horizontal)
        for button in [revealButton, copyButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        sheet.addRow(secretWell)
        sheet.addRow(actionRow)
        secretHint.font = HelmType.caption()
        secretHint.stringValue = "Copy sends the value straight to your clipboard - it never has to appear on screen first, which is what you want the moment you're sharing your screen. It clears itself afterward unless you've copied something else since."
        sheet.addRow(secretHint)
        renderSecret()

        sheet.addSection("Where it's used", number: "02")
        if !credential.account.isEmpty {
            sheet.addRow(readOnlyRow("Account", credential.account, code: true))
        }
        if !credential.location.isEmpty {
            sheet.addRow(readOnlyRow("Location", credential.location, code: true))
        }
        if credential.account.isEmpty, credential.location.isEmpty {
            _ = sheet.addCaption("No account or location recorded for this credential.")
        }

        if !credential.notes.isEmpty {
            sheet.addSection("Notes", number: "03")
            let notes = NSTextField(wrappingLabelWithString: credential.notes)
            notes.font = HelmType.body()
            sheet.addRow(notes)
        }

        sheet.addSection("History", number: credential.notes.isEmpty ? "03" : "04")
        sheet.addRow(readOnlyRow("Created", Self.absolute(credential.createdAt), code: false))
        sheet.addRow(readOnlyRow("Updated", Self.absolute(credential.updatedAt), code: false))
        sheet.addRow(readOnlyRow("Last used",
                                 credential.lastUsedAt.map(Self.absolute) ?? "Never used",
                                 code: false))
        if credential.requiresTouchIDToReveal {
            _ = sheet.addInfoCard(symbol: "touchid", text: "This credential asks for Touch ID every time its value is revealed.")
        }

        // The per-item audit trail. Counted first, because "revealed once,
        // copied 3 times" is the line the mockup shows and the one a captain
        // actually reads; the individual events follow.
        let reveals = auditEvents.filter { $0.kind == .revealed }.count
        let copies = auditEvents.filter { $0.kind == .copied }.count
        _ = sheet.addCaption("Revealed on screen \(Self.times(reveals)), copied \(Self.times(copies)).")
        for event in auditEvents.sorted(by: { $0.at > $1.at }).prefix(Self.maxDetailEvents) {
            sheet.addRow(auditRow(event))
        }
        if auditEvents.count > Self.maxDetailEvents {
            // "No silent caps" - say what was left out rather than trimming
            // quietly. The full log is in the Vault's Settings sheet.
            _ = sheet.addCaption("Showing the \(Self.maxDetailEvents) most recent of \(auditEvents.count) events. The full log is in Vault settings.")
        }

        sheet.setFooter(target: self,
                        confirmTitle: "Edit",
                        confirm: #selector(editClicked),
                        cancel: #selector(closeClicked),
                        delete: (title: "Delete", action: #selector(deleteClicked)),
                        // This sheet saves nothing, so the scaffold's default
                        // "to save" caption would be a lie about what Return
                        // does. The keycap itself is still right, which is
                        // what `hintCaption` (rather than `hint`) keeps.
                        hintCaption: "opens the editor")
        sheet.refreshTheme()
    }

    private static let maxDetailEvents = 12

    // MARK: Secret rendering

    private func renderSecret() {
        let theme = ThemeManager.shared.theme
        if isRevealed {
            secretLabel.stringValue = credential.secret.isEmpty ? "(no value stored)" : credential.secret
            secretLabel.textColor = HelmField.ink(theme)
            revealButton.title = "Hide"
            revealButton.symbolName = "eye.slash"
        } else {
            // A fixed-width mask rather than one dot per character: the length
            // of a secret is itself worth not disclosing to someone reading
            // over a shoulder.
            secretLabel.stringValue = String(repeating: "\u{2022}", count: 16)
            secretLabel.textColor = HelmField.mutedInk(theme)
            revealButton.title = "Reveal"
            revealButton.symbolName = "eye"
        }
    }

    // MARK: Rows

    private func readOnlyRow(_ label: String, _ value: String, code: Bool) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = HelmType.caption()
        labelField.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let valueField = NSTextField(labelWithString: value)
        valueField.font = code ? HelmType.code() : HelmType.body()
        valueField.isSelectable = true
        valueField.lineBreakMode = .byTruncatingTail
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = HelmMetrics.s3
        row.distribution = .fill
        return row
    }

    private func auditRow(_ event: VaultAuditEvent) -> NSView {
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: event.kind.symbol, accessibilityDescription: event.summary)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        glyph.contentTintColor = CredentialVaultInk.text(event.kind.tint, in: ThemeManager.shared.theme)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let text = NSTextField(labelWithString: event.summary)
        text.font = HelmType.caption()
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let when = NSTextField(labelWithString: Self.relative(event.at))
        when.font = HelmType.captionSmall()
        when.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        when.setContentHuggingPriority(.required, for: .horizontal)
        when.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [glyph, text, when])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.distribution = .fill
        return row
    }

    // MARK: Actions

    @objc private func revealClicked() {
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
        onCopy?(credential)
    }

    @objc private func editClicked() {
        closeSheet()
        onEdit?(credential)
    }

    @objc private func deleteClicked() {
        closeSheet()
        onDelete?(credential)
    }

    @objc private func closeClicked() { closeSheet() }

    private func closeSheet() {
        if presentingViewController != nil {
            dismiss(self)
        } else {
            view.window?.close()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Re-mask on the way out, so a sheet reopened for the same item never
        // starts with the value already on screen. The report's own wording for
        // the reveal contract ("re-masks on navigating away").
        isRevealed = false
    }

    // MARK: Formatting

    // GL-P3: cached, not per call - these are built on every row of every
    // detail sheet.
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

    private static func times(_ count: Int) -> String {
        switch count {
        case 0: return "never"
        case 1: return "once"
        default: return "\(count) times"
        }
    }

    #if FM_SELFTESTS
    var debugRevealButton: HelmButton { revealButton }
    var debugCopyButton: HelmButton { copyButton }
    var debugSecretLabel: NSTextField { secretLabel }
    var debugIsRevealed: Bool { isRevealed }
    #endif
}
