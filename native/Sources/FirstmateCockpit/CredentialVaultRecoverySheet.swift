// Manjesh Grand Line - native macOS app.
//
// F17: "Recovery & import", one sheet with two halves.
//
// **They are one sheet on purpose**, which is the mockup's own stated
// judgment call: the day you move a hundred credentials in is the day the
// recovery key should be printed, and splitting the two across separate
// flows is exactly how the key never gets printed. The sheet opens on
// whichever half the vault needs - import first when no key exists and the
// vault is empty, recovery first otherwise.
//
// **What this sheet never does:** write anything itself. The recovery half
// calls `CredentialVaultStore.enrollRecoveryKey`, the import half calls
// `CredentialVaultStore.importCredentials`, and both of those seal through
// the one `persist()` every manually-added credential already takes. The CSV
// is read into memory and parsed by `CredentialVaultImport` (pure logic, no
// I/O of its own); nothing is written to a temp file, and the parsed plan is
// dropped with this sheet.
//
// **The recovery code is rendered once and never stored.** It lives in this
// controller's `printedCode` for as long as the sheet is open, is handed to
// the print view and the PDF writer, and goes when the sheet closes. There
// is no property on the store, no Keychain item and no field in the vault
// file that a code could be read back out of - see
// `CredentialVaultRecovery`'s header for why that is the design rather than
// an oversight.

import AppKit
import UniformTypeIdentifiers

final class CredentialVaultRecoverySheetController: NSViewController {

    private let store: CredentialVaultStore

    /// Copy the recovery code, routed by the page through the vault's own
    /// concealed writer and auto-clear - a recovery key is the most valuable
    /// string this app will ever put on a pasteboard.
    var onCopyCode: ((String) -> Void)?
    /// Something changed in the vault - the page re-renders.
    var onChanged: (() -> Void)?

    // MARK: Recovery half

    private let recoveryStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let printKeyButton = HelmButton(title: "Print a recovery key", variant: .primary, size: .small, symbol: "printer")
    private let removeKeyButton = HelmButton(title: "Remove", variant: .quiet, size: .small, symbol: "trash")
    private let codeCard = NSView()
    private let codeKicker = NSTextField(labelWithString: "GRAND LINE \u{00B7} RECOVERY KEY")
    private let codeLabel = NSTextField(labelWithString: "")
    private let codeFootnote = NSTextField(wrappingLabelWithString: "")
    private let printButton = HelmButton(title: "Print", variant: .primary, size: .small, symbol: "printer")
    private let savePDFButton = HelmButton(title: "Save as PDF", variant: .secondary, size: .small, symbol: "doc")
    private let copyCodeButton = HelmButton(title: "Copy", variant: .quiet, size: .small, symbol: "doc.on.doc")
    private var filedRow: HelmToggleRow!
    private var codeCardViews: [NSView] = []

    private var printedCode: String?

    // MARK: Import half

    /// The three formats whose column layouts were taken from a real
    /// export. `.generic` is deliberately **not** a chip: a fourth pill
    /// clipped "Bitwarden" to "Bitw" in a real render of this sheet at its
    /// own column width, and a control that cannot show its own labels is
    /// worse than one option fewer. Nothing is lost - an unrecognised file
    /// still imports, because detection falls back to `.generic` on its own
    /// and the mapping is resolved by column name either way. The caption
    /// under the row says so.
    private static let sourceChips: [CredentialImportSource] = [.onePassword, .bitwarden, .chrome]
    private let sourceTabs = HelmSegmentedTabs(items: sourceChips.map {
        .init(id: $0.rawValue, title: $0.title)
    }, selected: CredentialImportSource.onePassword.rawValue, size: .compact)
    private let chooseFileButton = HelmButton(title: "Choose a CSV file\u{2026}", variant: .secondary, size: .small, symbol: "folder")
    private let fileLabel = NSTextField(labelWithString: "No file chosen")
    private let parsedPill = NSView()
    private let parsedPillLabel = NSTextField(labelWithString: "")
    private let mappingStack = NSStackView()
    private let skippedLabel = NSTextField(wrappingLabelWithString: "")
    private var mergeRow: HelmToggleRow!
    private let importButton = HelmButton(title: "Import", variant: .primary, size: .small, symbol: "square.and.arrow.down")

    private var plan: CredentialImportPlan?
    private var chosenFileName = ""
    /// The source the captain picked, or nil for "whatever the header says".
    /// The chips are a *correction*, not a requirement: detection is right
    /// almost always, and forcing a choice before the file is even read
    /// would be a step for nothing.
    private var forcedSource: CredentialImportSource?

    private var themeObservation: ThemeObservation?

    init(store: CredentialVaultStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func loadView() {
        let form = HelmFormSheet(title: "Recovery & import",
                                 scrolls: true,
                                 domainHue: RailDestination.poneglyph.domainHue)
        view = form

        form.addSection("If you forget your password", number: "01")
        recoveryStatusLabel.font = HelmType.caption()
        recoveryStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        form.addRow(recoveryStatusLabel)

        let enrolRow = NSStackView(views: [printKeyButton, removeKeyButton])
        enrolRow.orientation = .horizontal
        enrolRow.alignment = .centerY
        enrolRow.spacing = HelmMetrics.s2
        enrolRow.distribution = .fill
        enrolRow.translatesAutoresizingMaskIntoConstraints = false
        for button in [printKeyButton, removeKeyButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        form.addRow(enrolRow)

        buildCodeCard()
        form.addRow(codeCard)

        let cardActions = NSStackView(views: [printButton, savePDFButton, copyCodeButton])
        cardActions.orientation = .horizontal
        cardActions.alignment = .centerY
        cardActions.spacing = HelmMetrics.s2
        cardActions.distribution = .fill
        cardActions.translatesAutoresizingMaskIntoConstraints = false
        for button in [printButton, savePDFButton, copyCodeButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        form.addRow(cardActions)

        // A `HelmToggleRow` title is one line and truncates rather than
        // wrapping, so both of these are written to fit the sheet's column
        // - measured in a real off-screen render, not guessed. The longer
        // sentence each one wants to say lives in the caption above it.
        filedRow = HelmToggleRow(title: "I have printed it",
                                 subtitle: "Shown once, and stored nowhere.")
        filedRow.onToggle = { [weak self] in self?.renderRecovery() }
        form.addRow(filedRow)
        codeCardViews = [codeCard, cardActions, filedRow]

        printKeyButton.target = self
        printKeyButton.action = #selector(printNewKey)
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeKey)
        printButton.target = self
        printButton.action = #selector(printCard)
        savePDFButton.target = self
        savePDFButton.action = #selector(savePDF)
        copyCodeButton.target = self
        copyCodeButton.action = #selector(copyCode)

        form.addSection("Import a CSV export", number: "02")
        sourceTabs.onSelect = { [weak self] id in
            guard let self else { return }
            self.forcedSource = CredentialImportSource(rawValue: id)
            self.reparse()
        }
        form.addRow(sourceTabs)
        _ = form.addCaption("Pick the manager you exported from, or just choose the file - Grand Line reads "
                            + "the header and matches the columns by name. Anything else imports too.")

        chooseFileButton.target = self
        chooseFileButton.action = #selector(chooseFile)
        fileLabel.font = .monospacedSystemFont(ofSize: HelmType.scaled(11), weight: .regular)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parsedPill.translatesAutoresizingMaskIntoConstraints = false
        parsedPill.isHidden = true
        let fileRow = NSStackView(views: [chooseFileButton, fileLabel])
        fileRow.orientation = .horizontal
        fileRow.alignment = .centerY
        fileRow.spacing = HelmMetrics.s2
        fileRow.distribution = .fill
        fileRow.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (5): only the file name may shrink. Hugging alone was not
        // enough - without the compression resistance the *button* truncated
        // to "Choose a C…" while the label kept its width, which is exactly
        // backwards.
        for control in [chooseFileButton, parsedPill] as [NSView] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        form.addRow(fileRow)
        // Its own row: sharing one with the button and the file name left
        // the pill truncating its own count in a real render.
        let pillRow = NSStackView(views: [parsedPill])
        pillRow.orientation = .horizontal
        pillRow.alignment = .centerY
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        form.addRow(pillRow)

        mappingStack.orientation = .vertical
        mappingStack.alignment = .leading
        mappingStack.spacing = 3
        mappingStack.translatesAutoresizingMaskIntoConstraints = false
        form.addRow(mappingStack)

        skippedLabel.font = HelmType.caption()
        skippedLabel.translatesAutoresizingMaskIntoConstraints = false
        form.addRow(skippedLabel)

        mergeRow = HelmToggleRow(title: "Merge duplicates",
                                 subtitle: "Off, a duplicate is added twice.")
        form.addRow(mergeRow)

        importButton.target = self
        importButton.action = #selector(runImport)
        let importRow = NSStackView(views: [importButton])
        importRow.orientation = .horizontal
        importRow.alignment = .centerY
        importRow.translatesAutoresizingMaskIntoConstraints = false
        form.addRow(importRow)

        form.addInfoCard(symbol: "lock.shield",
                         text: "The CSV you export from another manager is plaintext. Grand Line reads it, "
                             + "encrypts every credential with your vault key, and never copies the file anywhere - "
                             + "delete it yourself once the import looks right.")

        // `hintCaption`, not the default "to save": nothing on this sheet is
        // saved by closing it - both halves write the moment their own
        // button is pressed.
        form.setFooter(target: self, confirmTitle: "Done", confirm: #selector(done), cancel: #selector(done),
                       hintCaption: "to close")
        form.setSubtitle("A printed key is the only way back into this vault if the master password is lost.")

        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.applyTheme(theme)
        }
        renderRecovery()
        renderImport()
        form.refreshTheme()
    }

    private func buildCodeCard() {
        codeCard.wantsLayer = true
        codeCard.layer?.cornerRadius = HelmMetrics.rCard
        codeCard.translatesAutoresizingMaskIntoConstraints = false

        codeKicker.font = HelmType.kicker()
        codeKicker.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.font = .monospacedSystemFont(ofSize: HelmType.scaled(17), weight: .medium)
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.isSelectable = true
        codeLabel.maximumNumberOfLines = 0
        codeFootnote.font = HelmType.caption()
        codeFootnote.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [codeKicker, codeLabel, codeFootnote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        codeCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: codeCard.leadingAnchor, constant: HelmMetrics.s3),
            stack.trailingAnchor.constraint(equalTo: codeCard.trailingAnchor, constant: -HelmMetrics.s3),
            stack.topAnchor.constraint(equalTo: codeCard.topAnchor, constant: HelmMetrics.s3),
            stack.bottomAnchor.constraint(equalTo: codeCard.bottomAnchor, constant: -HelmMetrics.s3),
        ])
    }

    // MARK: Recovery actions

    @objc private func printNewKey() {
        // Replacing an existing kit invalidates the sheet the captain may
        // already have filed, so it is a confirmed, irreversible action -
        // GL-06's shape. A first enrolment destroys nothing and needs no
        // prompt.
        guard store.hasRecoveryKey else {
            enrol()
            return
        }
        let confirmed = HelmConfirm.confirm(
            title: "Replace the recovery key?",
            body: "The key you printed before will stop working immediately. "
                + "Anything you have already filed away becomes waste paper.",
            confirmTitle: "Print a new key",
            destructive: true,
            confirmIsDefault: false,
            symbol: "printer.fill",
            hue: RailDestination.poneglyph.domainHue)
        guard confirmed else { return }
        enrol()
    }

    private func enrol() {
        switch store.enrollRecoveryKey() {
        case .success(let code):
            printedCode = code
            filedRow.isOn = false
            renderRecovery()
            onChanged?()
        case .failure(let error):
            Toast.show(in: view, message: "Could not print a recovery key: \(error.localizedDescription)")
        }
    }

    @objc private func removeKey() {
        // GL-06: one confirmation, through the app's one destructive prompt.
        guard DestructiveConfirm.confirm(
            message: "Remove the recovery key?",
            detail: "Any sheet you have printed stops working. If you then forget the master "
                  + "password, nothing - including Grand Line - can open this vault.",
            confirmTitle: "Remove") else { return }
        _ = store.removeRecoveryKey()
        printedCode = nil
        renderRecovery()
        onChanged?()
    }

    /// The printable card, built fresh per action so the print job and the
    /// PDF are rendered from the same view type with the same inputs.
    private func makeKitView() -> CredentialVaultRecoveryKitView? {
        guard let printedCode else { return nil }
        return CredentialVaultRecoveryKitView(code: printedCode,
                                              createdAt: store.recoveryKeyCreatedAt ?? Date(),
                                              vaultFileName: CredentialVaultGitSync.vaultFileName)
    }

    @objc private func printCard() {
        guard let kit = makeKitView() else { return }
        kit.runPrintOperation(in: view.window)
    }

    @objc private func savePDF() {
        guard let kit = makeKitView() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "grand-line-recovery-key.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.message = "This PDF contains your recovery key in the clear. Print it and delete the file."
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let host = self?.view else { return }
            do {
                try kit.pdfData().write(to: url, options: [.atomic])
                Toast.show(in: host, message: "Saved \u{2014} print it and delete the file")
            } catch {
                Toast.show(in: host, message: "Could not save the PDF: \(error.localizedDescription)")
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    @objc private func copyCode() {
        guard let printedCode else { return }
        onCopyCode?(printedCode)
    }

    private func renderRecovery() {
        let hasCode = printedCode != nil
        codeCardViews.forEach { $0.isHidden = !hasCode }
        if let printedCode {
            codeLabel.stringValue = wrapForDisplay(printedCode)
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM yyyy"
            codeFootnote.stringValue = "Vault \(CredentialVaultGitSync.vaultFileName) \u{00B7} created "
                + formatter.string(from: store.recoveryKeyCreatedAt ?? Date())
                + " \u{00B7} this key unlocks that file and nothing else."
        }
        removeKeyButton.isHidden = !store.hasRecoveryKey
        printKeyButton.title = store.hasRecoveryKey ? "Print a new key" : "Print a recovery key"

        if hasCode {
            recoveryStatusLabel.stringValue = filedRow.isOn
                ? "Filed. Grand Line will not show this key again."
                : "Print this now. It is shown once, and it is the only way back into the vault without the master password."
        } else if store.hasRecoveryKey, let created = store.recoveryKeyCreatedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM yyyy"
            recoveryStatusLabel.stringValue = "A recovery key was printed on \(formatter.string(from: created)). "
                + "Grand Line cannot show it again - if you no longer have that sheet, print a new key, which replaces it."
        } else {
            recoveryStatusLabel.stringValue = "This vault has no recovery key. If you forget the master password, "
                + "nothing - including Grand Line - can open it. A printed key is a second wrap of the vault key, "
                + "not a copy of your password."
        }
        applyTheme(ThemeManager.shared.theme)
    }

    /// Four groups per line, which is what fits the sheet's width at the
    /// code's own point size without truncating - the same two-line shape
    /// the printed card uses.
    private func wrapForDisplay(_ code: String) -> String {
        let groups = code.components(separatedBy: " \u{00B7} ")
        return stride(from: 0, to: groups.count, by: 4)
            .map { groups[$0..<min($0 + 4, groups.count)].joined(separator: "  ") }
            .joined(separator: "\n")
    }

    // MARK: Import actions

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Pick the CSV your other password manager exported."
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func load(_ url: URL) {
        // Read as UTF-8, then Latin-1 - a 1Password export is UTF-8 and a
        // Chrome one from a Windows profile sometimes is not, and failing
        // the whole import over one accented character would be a terrible
        // reason to lose the file.
        let text: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else if let latin = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = latin
        } else {
            Toast.show(in: view, message: "Could not read that file as text")
            return
        }
        chosenFileName = url.lastPathComponent
        csvText = text
        reparse()
    }

    /// Held only while the sheet is open, and only so changing the source
    /// chip can re-plan without asking for the file again. Plaintext by
    /// nature - it is the captain's own export - and it is never written
    /// anywhere.
    private var csvText: String?

    private func reparse() {
        guard let csvText else { return }
        plan = CredentialVaultImport.plan(text: csvText,
                                          source: forcedSource,
                                          existing: store.credentials)
        // Only move the chips for a format that HAS one - selecting an id
        // the control does not carry would silently clear the selection.
        if let detected = plan?.source, forcedSource == nil, Self.sourceChips.contains(detected) {
            sourceTabs.select(detected.rawValue)
        }
        renderImport()
    }

    @objc private func runImport() {
        guard let plan, !plan.credentials.isEmpty else { return }
        switch store.importCredentials(plan.credentials, merging: mergeRow.isOn) {
        case .success(let count):
            Toast.show(in: view, message: "Imported \(count) credential\(count == 1 ? "" : "s")")
            self.plan = nil
            self.csvText = nil
            self.chosenFileName = ""
            renderImport()
            onChanged?()
            // The mockup's own pairing: having just moved a vault's worth of
            // credentials in, this is the moment the key matters most.
            if !store.hasRecoveryKey {
                recoveryStatusLabel.stringValue = "You have just imported \(count) credential"
                    + "\(count == 1 ? "" : "s") into a vault with no recovery key. Print one now."
            }
        case .failure(let error):
            Toast.show(in: view, message: "Import failed: \(error.localizedDescription)")
        }
    }

    private func renderImport() {
        fileLabel.stringValue = chosenFileName.isEmpty ? "No file chosen" : chosenFileName
        mappingStack.arrangedSubviews.forEach {
            mappingStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let plan else {
            parsedPill.isHidden = true
            skippedLabel.stringValue = ""
            importButton.isEnabled = false
            importButton.title = "Import"
            applyTheme(ThemeManager.shared.theme)
            return
        }
        parsedPill.isHidden = false
        for row in plan.mapping.rows(header: plan.header) {
            mappingStack.addArrangedSubview(makeMappingRow(column: row.column, field: row.field))
        }
        // GL-14: a skip is a *state*, reported by name and count - never a
        // silently smaller number of imported rows.
        var notes: [String] = []
        if !plan.duplicateTitles.isEmpty {
            notes.append("\(plan.duplicateTitles.count) already in the vault (\(plan.duplicateTitles.prefix(3).joined(separator: ", "))"
                         + (plan.duplicateTitles.count > 3 ? "\u{2026})" : ")"))
        }
        for skip in plan.skipped.prefix(6) { notes.append("Line \(skip.line): \(skip.reason)") }
        if plan.skipped.count > 6 { notes.append("\u{2026} and \(plan.skipped.count - 6) more skipped rows.") }
        skippedLabel.stringValue = notes.joined(separator: "\n")

        importButton.isEnabled = !plan.credentials.isEmpty
        importButton.title = plan.credentials.isEmpty
            ? "Nothing to import"
            : "Import \(plan.credentials.count) credential\(plan.credentials.count == 1 ? "" : "s")"
        applyTheme(ThemeManager.shared.theme)
    }

    private func makeMappingRow(column: String, field: String) -> NSView {
        let from = NSTextField(labelWithString: column)
        from.font = .monospacedSystemFont(ofSize: HelmType.scaled(11), weight: .regular)
        from.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        let arrow = NSTextField(labelWithString: "\u{2192}")
        arrow.font = HelmType.caption()
        arrow.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        let to = NSTextField(labelWithString: field)
        to.font = field == "Skip" ? HelmType.caption() : .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
        to.textColor = field == "Skip"
            ? HelmTheme.mutedInk(ThemeManager.shared.theme)
            : HelmTheme.nsColor(ThemeManager.shared.theme.chromeInkHex)
        let row = NSStackView(views: [from, arrow, to])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        from.widthAnchor.constraint(equalToConstant: 130).isActive = true
        return row
    }

    @objc private func done() {
        if presentingViewController != nil {
            dismiss(self)
        } else {
            view.window?.close()
        }
    }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        // The card is washed in the same tint the printed sheet's dashed
        // border implies, routed through `HelmContrast` rather than painting
        // a raw hue - `CredentialVaultInk`'s own rule.
        // `tintedSurface` returns the fill AND the ink that is legible on it
        // - taking only the fill and picking an ink by hand is audit §5.7's
        // defect, which `CredentialVaultInk`'s own note names.
        let wash = HelmContrast.tintedSurface(tintHex: HelmTint.critical.hex(in: theme),
                                              theme: theme,
                                              target: HelmContrast.textTarget)
        codeCard.layer?.backgroundColor = wash.fill.cgColor
        codeCard.layer?.borderWidth = 1.5
        codeCard.layer?.borderColor = HelmTheme.nsColor(HelmTint.critical.hex(in: theme)).cgColor
        codeKicker.textColor = wash.foreground
        codeLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        codeFootnote.textColor = HelmTheme.mutedInk(theme)
        recoveryStatusLabel.textColor = HelmTheme.mutedInk(theme)
        fileLabel.textColor = HelmTheme.mutedInk(theme)
        skippedLabel.textColor = HelmTheme.mutedInk(theme)
        sourceTabs.applyTheme(theme)
        filedRow?.applyTheme(theme)
        mergeRow?.applyTheme(theme)
        if let plan {
            let ok = plan.credentials.isEmpty ? HelmTint.warn : HelmTint.good
            ToolRowLayout.pill(text: plan.summary, colorHex: ok.hex(in: theme),
                               into: parsedPill, label: parsedPillLabel, theme: theme)
        }
    }

    #if FM_SELFTESTS
    var debugRecoveryStatus: String { recoveryStatusLabel.stringValue }
    var debugCodeText: String { codeLabel.stringValue }
    var debugCodeCardIsShown: Bool { !codeCard.isHidden }
    var debugImportSummary: String { parsedPillLabel.stringValue }
    var debugSkippedText: String { skippedLabel.stringValue }
    var debugImportButtonTitle: String { importButton.title }
    var debugImportButtonEnabled: Bool { importButton.isEnabled }
    var debugMappingRowCount: Int { mappingStack.arrangedSubviews.count }
    var debugPrintedCode: String? { printedCode }
    func debugPrintNewKey() { enrol() }
    func debugLoadCSV(_ text: String, named name: String) {
        csvText = text
        chosenFileName = name
        reparse()
    }
    func debugSelectSource(_ source: CredentialImportSource) {
        forcedSource = source
        reparse()
    }
    func debugSetMerge(_ on: Bool) { mergeRow.isOn = on }
    func debugRunImport() { runImport() }
    func debugKitView() -> CredentialVaultRecoveryKitView? { makeKitView() }
    #endif
}
