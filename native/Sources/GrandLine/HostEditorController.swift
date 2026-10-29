// Grand Line - native macOS app.
//
// The host-details editor (design report A2/A3, Section D Phase 1). The
// Termius "New Host" fields - Label, Address, Port, Username, a credentials
// section, and the A3 icon/colour pickers. Add, edit, and delete all route
// back to the caller via closures; this view knows nothing about the host
// store. Presented as its own top-level window (`AppDelegate.presentHostEditor`)
// with the same visual weight as Settings, not a sheet on the Hosts panel.
//
// Phase 2 replaces the raw "key file path" field with a "Choose a key" popup
// sourced from the saved-keys Keychain (`SSHKeyStore`) - the host now carries
// a `keyID` reference, never a path, per design report Section A2/C3.
//
// Phase 3 (Section B1/B2/B4, Section D Phase 3) adds: Group + Tags (B4);
// Agent Forwarding and Jump Via (B1); a "Port Forwarding\u{2026}" button that
// opens `PortForwardingController` as a nested sheet (B1); and a Startup
// Snippet popup sourced from `SnippetStore` (B2/B5).
//
// Fix 5 adds a "+ New Key…" entry at the bottom of the key chooser, so a key
// can be created without leaving this form: it opens the Phase-2
// `KeyEditorController` sheet, persists through `SSHKeyStore.addNew` on
// save, and rebuilds the chooser selecting the new key. This is why it holds a
// live `SSHKeyStore` rather than a one-time snapshot of `keys` - unlike the
// icon/colour catalogues, it has to reflect a key created while this very sheet
// is still open.
//
// Phase 6 of the full-app UI audit moved the form onto the shared scaffold
// (`HelmForm.swift`, the scrolling variant). This was the biggest of the six
// migrations: a flat 15-row `NSGridView` with a 130pt label column, 7 stock
// bezeled fields, 2 stock popups and 2 unlabelled checkboxes sitting in empty
// grid cells became four kickered sections of the same field language the task
// editor uses. **The window presentation is unchanged** - it is still a
// top-level window, `closeEditor()` still closes it directly (`dismiss(self)`
// is a documented no-op here, see that method), and the capped/centred column
// is still built from inequalities rather than a required `==` width tie
// (AGENTS.md's host-editor gotcha (3)), now inside `HelmFormSheet.cappedColumn`.
// Every field, every validation rule and the inline "+ New Key…" flow behave
// exactly as before.
//
// `fm/grandline-hosts-keys-form-redesign` gave the form a real visual pass
// against a captain-approved mockup
// (`data/grandline-hosts-keys-mockup/mockup.html`) - numbered/kickered
// sections, an accent-tinted Keychain-security note, a DEV/UAT/PROD quick-pick
// row over the existing free-text `Host.group` (no new field - see
// `HostEnvironmentPicker`'s own doc comment), and a real chip-flow Tags input
// matching `ShiftTaskEditorController`'s own tag chips. This is presentation
// only: every field, every validation rule, save/cancel/delete and the inline
// "+ New Key…" flow are unchanged. The mockup's "Test Connection" footer
// button had no backing capability then and was left out rather than
// invented. R4-UX-04 built that capability (`HostConnectionTest`), and the
// side panel's footer carries it as Test.
//
// Section numbering also picked up a fifth section, "Appearance" (the icon/
// colour pickers), that the mockup itself doesn't show - those pickers are a
// real, already-shipped feature (`Host.iconSymbol`/`accentHex`) with no
// equivalent in the mockup's four sections, and removing them would be a
// functionality regression, not a restyle.

// **H6 of the Termius-style plan: the side panel.** In the sidebar layout
// this same controller is the host form in the shell's inspector, with
// `presentation: .panel` - there is no pop-up editor there. Same sections in
// the same order, the same validation and the same save; what differs is the
// frame around them:
//
//   - `HelmFormSheet`'s panel chrome: no heading (the inspector names the
//     host), a header with the host's tile and address, and a footer this
//     controller keeps current (C1): the host's own action (Connect, or
//     Switch to Session) while nothing has changed, then Cancel and Save
//     Changes. Return saves and Esc cancels.
//   - Group and Tags stack rather than share a row, for the 320pt panel.
//   - Advanced is collapsed unless the host uses something in it.
//   - Port forwards are edited inline (`PortForwardInlineEditor`) rather than
//     in a second pop-up.
//   - A save keeps the panel open on the saved host, and anything a save did
//     not touch (`lastConnectedAt`, stamped by a connect while the form was
//     open) is taken from the stored record rather than from the form.
//
// The floating bar keeps the window, unchanged (`presentation: .window`).

import AppKit

final class HostEditorController: NSViewController, NSTextFieldDelegate {

    /// Where the form is drawn: its own window (the floating bar's), or the
    /// sidebar shell's inspector.
    enum Presentation {
        case window
        case panel
    }

    let presentation: Presentation

    /// A panel footer's action while nothing has changed (Connect, Switch to
    /// Session), set by the page that hosts the panel.
    struct PanelAction {
        let title: String
        let symbol: String?
        let run: () -> Void
    }

    /// The panel's own action and its overflow menu (Duplicate, Delete, End
    /// Session) - both the page's, so the panel runs exactly what a card or
    /// a row does. Set them, then `refreshPanelFooter()`.
    var panelPrimary: PanelAction?
    /// R4-UX-04: the footer's Test, set by the page (which knows the other
    /// saved hosts a jump chain resolves through). `nil` hides the button.
    var onTestConnection: (() -> Void)?
    var panelMenu: [WorkspaceDetail.Action] = []
    /// The line under the host's name in the panel's header: its live state.
    var panelStatus: (text: String, tint: HelmTint)?
    /// Something in the form changed, or it was saved or reset.
    var onDirtyChange: ((Bool) -> Void)?
    /// The panel's Cancel (or Esc) with changes, or a new host's Cancel.
    var onPanelCancel: (() -> Void)?
    /// The record as it is stored now, read at save time, so a save carries
    /// what changed under the form (a connect's `lastConnectedAt`) rather
    /// than overwriting it with the copy the form opened with.
    var storedHost: (() -> Host?)?

    /// The host the form is for (the saved one, after a panel save), or
    /// `nil` for a new host not saved yet.
    var currentRecord: Host? { editing }

    /// Whether the form differs from what it opened with (C1's Save and
    /// Cancel appear only then).
    private(set) var isDirty = false
    /// What the form held when it opened, or when it was last saved.
    private var baseline: Host?

    /// The form's content column never grows past this, regardless of window
    /// width - a typical macOS dialog reading width, centred in whatever space
    /// the window actually has.
    private static let maxContentWidth: CGFloat = 520

    /// The host being edited; `nil` for a brand-new host.
    private var editing: Host?

    /// The saved-keys Keychain (Phase 2) - read to populate the key chooser,
    /// and written to by the inline "+ New Key…" flow (Fix 5).
    private let keyStore: SSHKeyStore

    /// Saved snippets to offer in the startup-snippet chooser - a snapshot
    /// taken when the sheet opens (matches how the icon/colour catalogues
    /// are snapshotted too; a snippet added while this sheet is open won't
    /// appear until reopened - unlike `keyStore`, nothing in this sheet can
    /// create a new snippet).
    private let snippets: [Snippet]

    /// Every other saved host's label (never including `editing`'s own, and
    /// never the pinned "Firstmate" entry's fixed display name - see
    /// `save()`), used only to warn on a duplicate label at Save time
    /// (Finding 5, cockpit-audit-core) - quick-connect resolves an ambiguous
    /// exact-label match with a plain `first(where:)`, so two hosts sharing a
    /// label can silently connect to the wrong one.
    private let existingLabels: Set<String>

    /// Called with the assembled host on Save. The caller persists it.
    var onSave: ((Host) -> Void)?
    /// Called with the host id on Delete (only offered when editing).
    var onDelete: ((UUID) -> Void)?

    // MARK: Fields

    private let labelField = HelmTextField(placeholder: "Name this host", style: .lead)
    private let addressField = HelmTextField(placeholder: "hostname or IP")
    private let portField = HelmTextField(placeholder: "22")
    private let usernameField = HelmTextField(placeholder: "Username")
    private let keyIconTile = IconTileView(size: 30, cornerRadius: HelmMetrics.rChip)
    private lazy var keyCard = HelmFieldCard(label: "SSH Key", accessory: keyIconTile)
    private let environmentPicker = HostEnvironmentPicker()
    private let groupField = HelmTextField(placeholder: "e.g. Production")
    private let tagInputField = HelmTextField(placeholder: "Add a tag, press Enter\u{2026}")
    private let tagsChipsFlow = ChipFlowView()
    private var tagChips: [String] = []
    private lazy var agentForwardRow = HelmToggleRow(
        title: "Forward SSH agent",
        subtitle: "Passes -A to ssh, so the remote host can use this machine's agent."
    )
    /// Block view Stage 0 opt-in (`fm/cockpit-block-view-stage0`) - see
    /// `Host.blockViewOptIn`'s doc comment. Only meaningful when
    /// `FM_BLOCK_VIEW_ENABLED` is also set, which the subtitle says.
    private lazy var blockViewRow = HelmToggleRow(
        title: "Render command blocks",
        subtitle: "Stage 0 - also needs FM_BLOCK_VIEW_ENABLED in the environment."
    )
    /// Context/namespace safety badge opt-in (`fm/grandline-k8s-context-badge`)
    /// - see `Host.kubeContextBadgeOptIn`'s doc comment.
    private lazy var kubeContextBadgeRow = HelmToggleRow(
        title: "Offer Kubernetes context badge",
        subtitle: "Only for a host with a kubectl context - adds a toolbar toggle so the captain can check the current context/namespace on any tab from this host, one tab at a time."
    )
    private let jumpViaField = HelmTextField(placeholder: "Host label or user@bastion")
    private let portForwardingButton = HelmButton(title: "", variant: .secondary)
    private let snippetCard = HelmFieldCard(label: "Startup snippet")

    /// The key chooser's current selection: `nil` is "None (use system ssh
    /// agent)", the same meaning index 0 carried when this was a popup.
    private var selectedKeyID: UUID?
    private var selectedSnippetID: UUID?

    /// Edited in the nested `PortForwardingController` sheet, carried here
    /// until Save.
    private var portForwards: [PortForwardRule]

    /// Current icon/colour selection, seeded from the host (or the defaults).
    private var selectedIcon: String
    private var selectedAccent: String
    private var iconButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    /// The selection checkmark overlaid on each colour swatch, by hex.
    private var colorTicks: [String: NSImageView] = [:]

    // MARK: Init

    init(host: Host?, keyStore: SSHKeyStore, snippets: [Snippet], existingLabels: Set<String> = [],
         presentation: Presentation = .window) {
        self.presentation = presentation
        self.editing = host
        self.keyStore = keyStore
        self.snippets = snippets
        self.existingLabels = existingLabels
        self.portForwards = host?.portForwards ?? []
        self.selectedIcon = host?.iconSymbol ?? HostCatalog.defaultIcon
        self.selectedAccent = host?.accentHex ?? HostCatalog.defaultAccent
        self.selectedKeyID = host?.keyID
        self.selectedSnippetID = host?.startupSnippetID
        self.tagChips = host?.tags ?? []
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    private var form: HelmFormSheet!

    override func loadView() {
        let panel = presentation == .panel
        let form = HelmFormSheet(title: editing == nil ? "New Host" : "Edit Host",
                                 scrolls: true,
                                 maxContentWidth: panel ? Self.panelContentWidth : Self.maxContentWidth,
                                 domainHue: RailDestination.hosts.domainHue,
                                 chrome: panel ? .panel : .sheet)
        self.form = form
        form.autoresizingMask = [.width, .height]
        form.setFrameSize(NSSize(width: panel ? WorkspaceInspectorController.width : 640, height: 780))
        view = form
        form.onApplyTheme = { [weak self] theme in
            // The icon/colour swatches carry the host's own chosen accent, not
            // a theme token, but their *unselected* tint is `mutedInk` - so
            // they still have to be re-derived on a theme change. Same for
            // the environment quick-pick row, which is tinted per-option
            // rather than by `mutedLabels`/`fieldCards`.
            self?.styleIconButtons()
            self?.styleColorButtons()
            self?.environmentPicker.applyTheme(theme)
            self?.keyIconTile.applyTheme(theme)
            self?.tagsChipsFlow.subviews.compactMap { $0 as? VocabularyChipView }.forEach { $0.applyTheme(theme) }
            self?.applyPanelTheme(theme)
        }
        if panel { form.setPanelHeader(buildPanelHeader()) }
        for field in [labelField, addressField, portField, usernameField, jumpViaField] { field.delegate = self }
        for row in [agentForwardRow, blockViewRow, kubeContextBadgeRow] {
            row.onToggle = { [weak self] in self?.fieldsChanged() }
        }

        labelField.stringValue = editing?.label ?? ""
        form.addLead(labelField)

        form.addSection("Connection", number: "01")
        addressField.stringValue = editing?.address ?? ""
        form.addField("Address", addressField)
        portField.stringValue = editing.map { String($0.port) } ?? "22"
        portField.formatter = intFormatter()
        usernameField.stringValue = editing?.username ?? ""
        form.addFieldColumns([("Port", portField), ("Username", usernameField)])
        environmentPicker.onSelect = { [weak self] title in
            self?.groupField.stringValue = title
            self?.fieldsChanged()
        }
        environmentPicker.select(editing?.group)
        form.addField("Environment", environmentPicker)

        form.addSection("Authentication", number: "02")
        keyIconTile.configure(symbol: "key.fill", tint: .warn, pointSize: 13)
        buildKeyChooser()
        form.addRow(keyCard)
        form.addInfoCard(text: "The private key is resolved from the macOS Keychain when connecting. "
            + "Grand Line never stores the private key material inside the host configuration.")

        form.addSection("Appearance", number: "03")
        form.addRow(form.labelledField("Icon", buildIconPicker()))
        form.addRow(form.labelledField("Colour", buildColorPicker()))

        form.addSection("Organization", number: "04")
        groupField.stringValue = editing?.group ?? ""
        groupField.delegate = self
        let tagsColumn = NSStackView(views: [tagInputField, tagsChipsFlow])
        tagsColumn.orientation = .vertical
        tagsColumn.alignment = .leading
        tagsColumn.spacing = HelmMetrics.s2
        tagsColumn.translatesAutoresizingMaskIntoConstraints = false
        tagInputField.delegate = self
        renderTagChips()
        if panel {
            // 320pt: one field per row.
            form.addField("Group", groupField)
            form.addField("Tags", tagsColumn)
        } else {
            form.addColumns([form.labelledField("Group", groupField),
                              form.labelledField("Tags", tagsColumn)])
        }

        let advancedStart = form.addSection("Advanced", number: "05", actions: panel ? [advancedToggle] : [])
        agentForwardRow.isOn = editing?.agentForward ?? false
        blockViewRow.isOn = editing?.blockViewOptIn ?? false
        kubeContextBadgeRow.isOn = editing?.kubeContextBadgeOptIn ?? false
        _ = advancedStart
        form.addRow(agentForwardRow)
        form.addRow(blockViewRow)
        form.addRow(kubeContextBadgeRow)
        advancedRows = [agentForwardRow, blockViewRow, kubeContextBadgeRow]
        jumpViaField.stringValue = editing?.jumpVia ?? ""
        advancedRows.append(form.addField("Jump via", jumpViaField))
        if panel {
            // Inline, rather than a second pop-up.
            let inline = PortForwardInlineEditor(rules: portForwards)
            inline.onChange = { [weak self] in self?.fieldsChanged() }
            inlineForwards = inline
            advancedRows.append(form.addField("Port forwarding", inline))
        } else {
            portForwardingButton.target = self
            portForwardingButton.action = #selector(editPortForwarding)
            updatePortForwardingButtonTitle()
            let forwardingRow = NSStackView(views: [portForwardingButton, NSView()])
            forwardingRow.orientation = .horizontal
            forwardingRow.distribution = .fill
            forwardingRow.translatesAutoresizingMaskIntoConstraints = false
            forwardingRow.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
            let wrapped = form.labelledField("Port forwarding", forwardingRow)
            form.addRow(wrapped)
            advancedRows.append(wrapped)
        }
        buildSnippetChooser()
        form.addRow(snippetCard)
        advancedRows.append(snippetCard)
        advancedRows.append(form.addCaption("Jumping chains through another saved host's own jump host automatically. "
            + "Agent forwarding and port-forwarding rules apply to this host's own connection."))

        if panel {
            // Advanced starts open only when the host uses something in it.
            setAdvancedShown(editing.map(Self.usesAdvanced) ?? false)
            form.setPanelFooter(panelFooter)
        } else {
            form.setFooter(target: self,
                           confirmTitle: editing == nil ? "Create Host" : "Save Changes",
                           confirm: #selector(save),
                           cancel: #selector(cancel),
                           delete: editing == nil ? nil : (title: "Delete Host", action: #selector(deleteHost)))
            form.setSubtitle("Stored on this Mac. Credentials stay in the Keychain.")
        }
        form.refreshTheme()
        baseline = assembledHost()
        refreshPanelFooter()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(labelField)
    }

    // MARK: Field helpers

    private func intFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 65_535
        f.allowsFloats = false
        return f
    }

    // MARK: Key chooser (Phase 2, + Fix 5's inline "New Key…")

    /// "None" plus every saved key (by label), then a separator and
    /// "+ New Key…" (Fix 5). Re-callable so a key created inline can be
    /// spliced into the same card - `selectedID` picks up where
    /// `editing?.keyID` otherwise would.
    private func buildKeyChooser(selecting selectedID: UUID? = nil) {
        let ids: [UUID?] = [nil] + keyStore.keys.map { $0.id }
        let titles = ["None (use system ssh agent)"] + keyStore.keys.map { "\($0.label) (\($0.type.displayName))" }
        let target = selectedID ?? selectedKeyID
        let index = target.flatMap { ids.firstIndex(of: $0) } ?? 0
        selectedKeyID = ids.indices.contains(index) ? ids[index] : nil
        keyCard.configureChoices(titles,
                                 selectedIndex: index,
                                 extra: [HelmFieldCard.ExtraItem(title: "+ New Key\u{2026}") { [weak self] in
                                     self?.presentNewKeySheet()
                                 }]) { [weak self] chosen in
            self?.selectedKeyID = ids.indices.contains(chosen) ? ids[chosen] : nil
            self?.fieldsChanged()
        }
    }

    /// Fix 5: create a key without leaving the host form. Opens the same
    /// Phase-2 sheet the SSH Keys tab uses; on save, persists through
    /// `SSHKeyStore.addNew` and rebuilds the chooser with the new key selected.
    /// On cancel (or a Keychain failure) the previous selection is left alone -
    /// unlike the old popup, picking "+ New Key…" from a menu never moves the
    /// card's own selection in the first place, so there is nothing to revert.
    private func presentNewKeySheet() {
        let editor = KeyEditorController(key: nil)
        editor.onSave = { [weak self] newKey, privateKeyData, passphrase in
            guard let self else { return }
            do {
                try self.keyStore.addNew(newKey, privateKeyData: privateKeyData, passphrase: passphrase)
                self.buildKeyChooser(selecting: newKey.id)
                self.fieldsChanged()
            } catch {
                self.presentKeyStoreError(error, label: newKey.label)
            }
        }
        presentAsSheet(editor)
    }

    private func presentKeyStoreError(_ error: Error, label: String) {
        HelmConfirm.problem(title: "Couldn't save \"\(label)\" to the Keychain",
                            body: error.localizedDescription)
    }

    // MARK: Snippet chooser + port forwarding (Phase 3)

    /// "None" plus every saved snippet, by label - the same shape as
    /// `buildKeyChooser`, so a startup snippet is picked the same way a key is.
    private func buildSnippetChooser() {
        let ids: [UUID?] = [nil] + snippets.map { $0.id }
        let titles = ["None"] + snippets.map { $0.label }
        let index = selectedSnippetID.flatMap { ids.firstIndex(of: $0) } ?? 0
        selectedSnippetID = ids.indices.contains(index) ? ids[index] : nil
        snippetCard.configureChoices(titles, selectedIndex: index) { [weak self] chosen in
            self?.selectedSnippetID = ids.indices.contains(chosen) ? ids[chosen] : nil
            self?.fieldsChanged()
        }
    }

    private func updatePortForwardingButtonTitle() {
        portForwardingButton.title = portForwards.isEmpty
            ? "Port Forwarding\u{2026}"
            : "Port Forwarding (\(portForwards.count))\u{2026}"
    }

    /// Open the rules sheet on top of this one (a sheet-on-sheet, which
    /// AppKit supports); the edited list only lands on `portForwards` - and
    /// therefore on the host - when that sheet's own Save is clicked.
    @objc private func editPortForwarding() {
        let editor = PortForwardingController(rules: portForwards)
        editor.onSave = { [weak self] rules in
            self?.portForwards = rules
            self?.updatePortForwardingButtonTitle()
        }
        presentAsSheet(editor)
    }

    // MARK: Environment quick-pick + Tags (redesign)

    /// `groupField` can also be typed into directly - keep the quick-pick row
    /// in sync either way, and keep the tag-chip input's Enter-to-commit
    /// behaviour (`ShiftTaskEditorController`'s own established pattern).
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === groupField {
            environmentPicker.select(groupField.stringValue)
            fieldsChanged()
            return
        }
        guard field === tagInputField else {
            fieldsChanged()
            return
        }
        let text = tagInputField.stringValue
        guard text.hasSuffix(",") else { return }
        let candidate = String(text.dropLast())
        tagInputField.stringValue = ""
        commitTag(candidate)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === tagInputField, commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTag(tagInputField.stringValue)
            tagInputField.stringValue = ""
            return true
        }
        // C1, in the panel: Return saves and Esc cancels, from any field.
        guard presentation == .panel else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), isDirty || editing == nil {
            savePanel()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), isDirty || editing == nil {
            cancelPanel()
            return true
        }
        return false
    }

    private func commitTag(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !tagChips.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        tagChips.append(trimmed)
        renderTagChips()
        fieldsChanged()
    }

    private func renderTagChips() {
        let theme = ThemeManager.shared.theme
        let chips: [NSView] = tagChips.map { tag in
            let chip = VocabularyChipView(word: tag)
            chip.applyTheme(theme)
            chip.onRemove = { [weak self] in
                self?.tagChips.removeAll { $0 == tag }
                self?.renderTagChips()
                self?.fieldsChanged()
            }
            return chip
        }
        tagsChipsFlow.setChips(chips)
    }

    // MARK: Icon + colour pickers (A3, restyled by F3)

    /// F3's "28-32pt targets". One number for both grids, so an icon tile and
    /// a colour swatch are the same size and the two rows line up.
    private static let swatchSide: CGFloat = 30
    /// How many swatches per row before wrapping. 12 icons and 8 colours both
    /// divide into rows no wider than the form's own capped column.
    private static let swatchesPerRow = 6
    private static let swatchSpacing: CGFloat = HelmMetrics.s2 - 2
    /// The ring a selected colour swatch wears, outside its own fill so the
    /// colour itself is never obscured by the selection state.
    private static let selectionRingWidth: CGFloat = 2.5

    /// Wrap `views` into a grid of rows - F3's "swatch grid" rather than the
    /// single long row both pickers used to be.
    private func swatchGrid(_ views: [NSView]) -> NSView {
        var rows: [NSView] = []
        for chunk in stride(from: 0, to: views.count, by: Self.swatchesPerRow) {
            let slice = Array(views[chunk..<min(chunk + Self.swatchesPerRow, views.count)])
            let row = NSStackView(views: slice)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Self.swatchSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            // Never `.fillEqually`: a short last row would stretch its
            // swatches to a different size from the full row above it, which
            // is exactly the raggedness a grid is meant to remove.
            row.distribution = .gravityAreas
            rows.append(row)
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = Self.swatchSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    private func buildIconPicker() -> NSView {
        var swatches: [NSView] = []
        for symbol in HostCatalog.icons {
            let b = NSButton(title: "", target: self, action: #selector(pickIcon(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = HelmMetrics.rChip
            b.imageScaling = .scaleProportionallyDown
            // I2: weight-matched to the label beside it rather than left at
            // the symbol's default, which renders light against this form's
            // semibold section kickers.
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            b.identifier = NSUserInterfaceItemIdentifier(symbol)
            b.toolTip = symbol
            b.setAccessibilityLabel(symbol)
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: Self.swatchSide),
                b.heightAnchor.constraint(equalToConstant: Self.swatchSide),
            ])
            iconButtons.append(b)
            swatches.append(b)
        }
        styleIconButtons()
        return swatchGrid(swatches)
    }

    private func buildColorPicker() -> NSView {
        var swatches: [NSView] = []
        for hex in HostCatalog.accents {
            let b = NSButton(title: "", target: self, action: #selector(pickColor(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = Self.swatchSide / 2
            b.layer?.backgroundColor = HelmTheme.nsColor(hex).cgColor
            b.identifier = NSUserInterfaceItemIdentifier(hex)
            b.toolTip = "#\(hex)"
            b.setAccessibilityLabel("Accent #\(hex)")
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: Self.swatchSide),
                b.heightAnchor.constraint(equalToConstant: Self.swatchSide),
            ])

            // F3's "checkmark on the chosen colour". A non-interactive overlay
            // rather than the button's own image: an `NSButton` draws its
            // image tinted by `contentTintColor`, which on a bordered-less
            // button also tints nothing else here - but the glyph has to be
            // legible against *this* swatch's own colour, which is a per-
            // swatch answer (`HelmContrast.legibleGlyph`), not a theme one.
            let tick = NSImageView()
            tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
            tick.contentTintColor = HelmContrast.legibleGlyph(over: HelmTheme.nsColor(hex))
            tick.isHidden = true
            tick.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(tick)
            NSLayoutConstraint.activate([
                tick.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                tick.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            ])
            colorTicks[hex] = tick

            colorButtons.append(b)
            swatches.append(b)
        }
        styleColorButtons()
        return swatchGrid(swatches)
    }

    @objc private func pickIcon(_ sender: NSButton) {
        selectedIcon = sender.identifier?.rawValue ?? selectedIcon
        styleIconButtons()
        fieldsChanged()
    }

    @objc private func pickColor(_ sender: NSButton) {
        selectedAccent = sender.identifier?.rawValue ?? selectedAccent
        styleIconButtons() // recolour the selected icon preview
        styleColorButtons()
        fieldsChanged()
    }

    /// F3: the chosen icon sits on a **filled** tile in the chosen accent, not
    /// the 18%-alpha wash this used to paint - a wash reads as a hover state,
    /// which is exactly the "selection is a faint wash" the finding names. The
    /// glyph on it is contrast-corrected against that fill rather than left as
    /// the accent itself, which on the accent would be invisible.
    private func styleIconButtons() {
        let accent = HelmTheme.nsColor(selectedAccent)
        let selectedGlyph = HelmContrast.legibleGlyph(over: accent)
        for b in iconButtons {
            let isSel = b.identifier?.rawValue == selectedIcon
            b.contentTintColor = isSel ? selectedGlyph : HelmTheme.mutedInk(ThemeManager.shared.theme)
            b.layer?.backgroundColor = (isSel ? accent : .clear).cgColor
            b.setAccessibilityValue(isSel)
        }
    }

    /// F3: the chosen colour gets a ring **and** a checkmark. The ring alone
    /// is ambiguous at a glance on a row of saturated dots (which ring is
    /// darker is a colour question, not a selection one); the tick says it
    /// outright, and is what a captain with a colour-vision difference reads.
    private func styleColorButtons() {
        let ring = HelmTheme.nsColor(ThemeManager.shared.theme.chromeInkHex)
        for b in colorButtons {
            let hex = b.identifier?.rawValue
            let isSel = hex == selectedAccent
            b.layer?.borderWidth = isSel ? Self.selectionRingWidth : 0
            b.layer?.borderColor = ring.cgColor
            b.setAccessibilityValue(isSel)
            if let hex { colorTicks[hex]?.isHidden = !isSel }
        }
    }

    #if FM_SELFTESTS
    // MARK: Probe surface (F3)

    struct DebugIconSwatch {
        let symbol: String
        let isSelected: Bool
        /// The tile's own fill, read off the real layer.
        let fill: NSColor?
        let glyphTint: NSColor?
        let side: CGFloat
        let centreY: CGFloat
    }

    struct DebugColourSwatch {
        let hex: String
        let isSelected: Bool
        let ringWidth: CGFloat
        let tickHidden: Bool
        let tickTint: NSColor?
        let side: CGFloat
    }

    var debugSelectedAccent: String { selectedAccent }

    var debugIconSwatches: [DebugIconSwatch] {
        iconButtons.map { b in
            let symbol = b.identifier?.rawValue ?? ""
            return DebugIconSwatch(symbol: symbol,
                                   isSelected: symbol == selectedIcon,
                                   fill: b.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) },
                                   glyphTint: b.contentTintColor,
                                   side: b.frame.width,
                                   centreY: b.convert(NSPoint(x: 0, y: b.bounds.midY), to: nil).y)
        }
    }

    var debugColourSwatches: [DebugColourSwatch] {
        colorButtons.map { b in
            let hex = b.identifier?.rawValue ?? ""
            let tick = colorTicks[hex]
            return DebugColourSwatch(hex: hex,
                                     isSelected: hex == selectedAccent,
                                     ringWidth: b.layer?.borderWidth ?? 0,
                                     tickHidden: tick?.isHidden ?? true,
                                     tickTint: tick?.contentTintColor,
                                     side: b.frame.width)
        }
    }

    /// Drive a real pick through the real target/action, so a check exercises
    /// the handler rather than setting the model behind it.
    func debugPickColour(_ hex: String) {
        guard let button = colorButtons.first(where: { $0.identifier?.rawValue == hex }) else { return }
        button.performClick(nil)
    }
    #endif

    // MARK: Actions

    /// Every field, checked the way Save always has, then assembled onto
    /// `base`. `nil` (after telling the captain why) when a field is not one
    /// `ssh` could use.
    private func validatedHost() -> Host? {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            flag(addressField)
            return nil
        }
        guard let port = Int(portField.stringValue), (1...65535).contains(port) else {
            flag(portField)
            warn(title: "Invalid port", body: "Port must be a whole number between 1 and 65535.")
            return nil
        }
        // GL-08: a leading dash makes `ssh` read the value as an option, not a
        // host - `-oProxyCommand=<cmd>` runs `<cmd>` locally on Connect. The
        // `--` terminator in `Host.sshArguments` already neutralises this at
        // the argv level, but refusing to *save* one keeps a host record that
        // was never meant to work out of the store entirely, and gives the
        // captain a real explanation rather than a mysteriously failing host.
        if Host.hasUnsafeLeadingDash(address) {
            flag(addressField)
            warn(title: "Address can't start with \u{201C}-\u{201D}",
                 body: "`ssh` would read it as a command-line option instead of a hostname. "
                     + "If you meant a hostname, remove the leading dash.")
            return nil
        }
        if Host.hasUnsafeLeadingDash(usernameField.stringValue) {
            flag(usernameField)
            warn(title: "Username can't start with \u{201C}-\u{201D}",
                 body: "`ssh` would read it as a command-line option instead of a login name.")
            return nil
        }
        if Host.hasUnsafeLeadingDash(jumpViaField.stringValue) {
            flag(jumpViaField)
            warn(title: "Jump host can't start with \u{201C}-\u{201D}",
                 body: "`ssh` would read it as a command-line option instead of a jump destination.")
            return nil
        }
        let resolvedLabel = label.isEmpty ? address : label
        if existingLabels.contains(resolvedLabel) {
            flag(labelField)
            warn(title: "Duplicate label", body: "Another saved host already uses the label \u{201C}\(resolvedLabel)\u{201D}. Quick-connect can't tell them apart - pick a unique label.")
            return nil
        }
        // The inline forwards are checked with the rules sheet's own words.
        if let inlineForwards {
            for rule in inlineForwards.rules {
                guard (1...65535).contains(rule.listenPort) else {
                    warn(title: "Invalid listen port", body: "Listen port must be a whole number between 1 and 65535.")
                    return nil
                }
                if rule.kind != .dynamic {
                    guard (1...65535).contains(rule.destPort) else {
                        warn(title: "Invalid destination port", body: "Destination port must be a whole number between 1 and 65535.")
                        return nil
                    }
                    guard !rule.destHost.isEmpty else {
                        warn(title: "Missing destination host", body: "Local and Remote forwarding rules need a destination host.")
                        return nil
                    }
                    if Host.hasUnsafeLeadingDash(rule.destHost) {
                        warn(title: "Destination can't start with \u{201C}-\u{201D}",
                             body: "`ssh` would read it as a command-line option.")
                        return nil
                    }
                }
            }
        }
        return assembledHost(base: storedHost?() ?? editing)
    }

    /// The form as a host, on `base` (whatever the form does not edit comes
    /// from there). No validation - this is also what the panel compares to
    /// decide whether anything changed.
    private func assembledHost(base: Host? = nil) -> Host {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = base ?? editing ?? Host(label: "", address: "")
        host.label = label.isEmpty ? address : label
        host.address = address
        host.port = Int(portField.stringValue) ?? 0
        host.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        host.keyID = selectedKeyID
        let group = groupField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        host.group = group.isEmpty ? nil : group
        host.tags = tagChips
        host.agentForward = agentForwardRow.isOn
        host.blockViewOptIn = blockViewRow.isOn
        host.kubeContextBadgeOptIn = kubeContextBadgeRow.isOn
        let jumpVia = jumpViaField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        host.jumpVia = jumpVia.isEmpty ? nil : jumpVia
        host.portForwards = inlineForwards?.rules ?? portForwards
        host.startupSnippetID = selectedSnippetID
        host.iconSymbol = selectedIcon
        host.accentHex = selectedAccent
        return host
    }

    @objc private func save() {
        guard let host = validatedHost() else { return }
        onSave?(host)
        closeEditor()
    }

    @objc private func deleteHost() {
        guard let id = editing?.id else { return }
        onDelete?(id)
        closeEditor()
    }

    @objc private func cancel() {
        closeEditor()
    }

    // MARK: The panel (H6, H10, H11)

    /// The panel's column: the inspector's width less its gutters.
    static let panelContentWidth: CGFloat = WorkspaceInspectorController.width - 2 * HelmFormSheet.panelGutter

    private var inlineForwards: PortForwardInlineEditor?
    private var advancedRows: [NSView] = []
    private var advancedShown = true
    private lazy var advancedToggle: HelmButton = {
        let b = HelmButton(title: "Show", variant: .quiet, size: .small, target: self, action: #selector(advancedToggled))
        b.setAccessibilityLabel("Show advanced settings")
        return b
    }()
    private let panelTile = IconTileView(size: 34, cornerRadius: 9)
    private let panelKicker = NSTextField(labelWithString: "")
    private let panelSubtitle = NSTextField(labelWithString: "")
    private let panelStatusPill = HelmStatusPill(style: .dotWord)
    /// R4-UX-04: what the last Test found, under the live state.
    private let panelTestPill = HelmStatusPill(style: .dotWord)
    private var panelTestOutcome: HostConnectionTest.Outcome?
    private var panelTestRunning = false
    private lazy var panelTestButton: HelmButton = {
        let b = HelmButton(title: "Test", variant: .secondary, symbol: "antenna.radiowaves.left.and.right",
                           target: self, action: #selector(panelTestClicked))
        b.toolTip = "Try to reach this host with ssh, without opening a session"
        b.setAccessibilityLabel("Test connection")
        return b
    }()
    private lazy var panelFooter = NSStackView()
    private lazy var panelPrimaryButton = HelmButton(title: "Connect", variant: .primary, symbol: "bolt.fill",
                                                     target: self, action: #selector(panelPrimaryClicked))
    private lazy var panelMenuButton: HelmButton = {
        let b = HelmButton(symbol: "ellipsis", variant: .secondary, target: self, action: #selector(panelMenuClicked(_:)))
        b.toolTip = "More actions"
        b.setAccessibilityLabel("More actions")
        return b
    }()
    private lazy var panelCancelButton = HelmButton(title: "Cancel", variant: .secondary,
                                                    target: self, action: #selector(panelCancelClicked))
    private lazy var panelSaveButton = HelmButton(title: "Save Changes", variant: .primary,
                                                  target: self, action: #selector(panelSaveClicked))

    /// Whether a host uses anything Advanced holds, so its section opens.
    static func usesAdvanced(_ host: Host) -> Bool {
        host.agentForward || host.blockViewOptIn || host.kubeContextBadgeOptIn
            || !(host.jumpVia ?? "").isEmpty || !host.portForwards.isEmpty || host.startupSnippetID != nil
    }

    private func buildPanelHeader() -> NSView {
        panelKicker.lineBreakMode = .byTruncatingTail
        panelSubtitle.lineBreakMode = .byTruncatingTail
        panelSubtitle.font = HelmType.code()
        let text = NSStackView(views: [panelKicker, panelSubtitle, panelStatusPill, panelTestPill])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = HelmMetrics.s0
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [panelTile, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        panelTile.setContentHuggingPriority(.required, for: .horizontal)
        refreshPanelHeader()
        return row
    }

    private func refreshPanelHeader() {
        guard presentation == .panel else { return }
        let theme = ThemeManager.shared.theme
        panelTile.configure(symbol: selectedIcon, tint: .accent, pointSize: HelmType.scaled(14))
        panelTile.overrideFill(hex: selectedAccent)
        panelTile.applyTheme(theme)
        let kicker = editing == nil ? "New host" : (editing.map(HostsController.roleKicker) ?? "SSH")
        panelKicker.attributedStringValue = NSAttributedString(
            string: kicker.uppercased(), attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        let draft = assembledHost()
        panelSubtitle.stringValue = draft.address.isEmpty ? "Not saved yet" : draft.subtitle
        panelSubtitle.textColor = HelmTheme.mutedInk(theme)
        panelSubtitle.toolTip = panelSubtitle.stringValue
        if let status = panelStatus {
            panelStatusPill.isHidden = false
            panelStatusPill.configure(text: status.text, tint: status.tint, theme: theme)
        } else {
            panelStatusPill.isHidden = true
        }
        if panelTestRunning {
            panelTestPill.isHidden = false
            panelTestPill.configure(text: "Testing\u{2026}", tint: .neutral, theme: theme)
            panelTestPill.toolTip = nil
        } else if let outcome = panelTestOutcome {
            panelTestPill.isHidden = false
            panelTestPill.configure(text: outcome.text, tint: outcome.tint, theme: theme)
            panelTestPill.toolTip = outcome.text
        } else {
            panelTestPill.isHidden = true
        }
    }

    /// R4-UX-04: a Test is under way.
    func showConnectionTestRunning() {
        panelTestRunning = true
        panelTestButton.isEnabled = false
        refreshPanelHeader()
    }

    /// R4-UX-04: what a Test found.
    func showConnectionTestOutcome(_ outcome: HostConnectionTest.Outcome) {
        panelTestRunning = false
        panelTestOutcome = outcome
        panelTestButton.isEnabled = true
        refreshPanelHeader()
    }

    @objc private func panelTestClicked() {
        guard !panelTestRunning else { return }
        onTestConnection?()
    }

    private func applyPanelTheme(_ theme: HelmTheme) {
        guard presentation == .panel else { return }
        refreshPanelHeader()
    }

    /// Something the form holds changed: re-decide whether it differs from
    /// what it opened with.
    private func fieldsChanged() {
        guard isViewLoaded, let baseline else { return }
        let dirty = assembledHost() != baseline
        refreshPanelHeader()
        guard dirty != isDirty else { return }
        isDirty = dirty
        refreshPanelFooter()
        onDirtyChange?(dirty)
    }

    /// C1: the host's own action while nothing changed; Cancel and Save
    /// Changes once something has. A new host is always Cancel and Create.
    func refreshPanelFooter() {
        guard presentation == .panel, isViewLoaded else { return }
        panelFooter.arrangedSubviews.forEach { panelFooter.removeArrangedSubview($0); $0.removeFromSuperview() }
        panelFooter.orientation = .horizontal
        panelFooter.spacing = HelmMetrics.s2
        panelFooter.alignment = .centerY
        let editingChanges = isDirty || editing == nil
        if editingChanges {
            panelSaveButton.title = editing == nil ? "Create Host" : "Save Changes"
            panelFooter.distribution = .fillEqually
            panelFooter.addArrangedSubview(panelCancelButton)
            panelFooter.addArrangedSubview(panelSaveButton)
        } else {
            panelFooter.distribution = .fill
            if let primary = panelPrimary {
                panelPrimaryButton.title = primary.title
                panelPrimaryButton.symbolName = primary.symbol
                panelFooter.addArrangedSubview(panelPrimaryButton)
                panelPrimaryButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
            }
            // R4-UX-04: a saved host, unchanged, can be tested. A form with
            // edits is Cancel and Save - the test reads the saved record,
            // whose fields passed Save's validation.
            if onTestConnection != nil {
                panelFooter.addArrangedSubview(panelTestButton)
                panelTestButton.setContentHuggingPriority(.required, for: .horizontal)
                panelTestButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            if !panelMenu.isEmpty {
                panelFooter.addArrangedSubview(panelMenuButton)
                panelMenuButton.setContentHuggingPriority(.required, for: .horizontal)
            }
        }
        refreshPanelHeader()
    }

    @objc private func panelPrimaryClicked() { panelPrimary?.run() }

    @objc private func panelMenuClicked(_ sender: NSButton) {
        makePanelMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + HelmMetrics.s1), in: sender)
    }

    private func makePanelMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, action) in panelMenu.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(panelMenuItemPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            if let symbol = action.symbol { item.image = HelmSymbol.image(symbol, pointSize: HelmType.scaled(12)) }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func panelMenuItemPicked(_ sender: NSMenuItem) {
        guard sender.tag < panelMenu.count else { return }
        panelMenu[sender.tag].run()
    }

    @objc private func panelCancelClicked() { cancelPanel() }
    @objc private func panelSaveClicked() { savePanel() }

    /// Save from the panel. The panel stays open on the saved host, clean.
    /// Returns whether it saved (a field Save refuses keeps it dirty).
    @discardableResult
    func savePanel() -> Bool {
        guard let host = validatedHost() else { return false }
        onSave?(host)
        editing = host
        baseline = assembledHost()
        isDirty = false
        refreshPanelFooter()
        onDirtyChange?(false)
        return true
    }

    /// The panel's Cancel: the page puts the stored host back (or closes a
    /// new host's form).
    func cancelPanel() {
        onPanelCancel?()
    }

    @objc private func advancedToggled() {
        setAdvancedShown(!advancedShown)
    }

    private func setAdvancedShown(_ shown: Bool) {
        advancedShown = shown
        // Arranged subviews of the form's stack: hidden drops them out of
        // layout (gotcha (11)'s stack exemption).
        advancedRows.forEach { $0.isHidden = !shown }
        advancedToggle.title = shown ? "Hide" : "Show"
        advancedToggle.setAccessibilityLabel(shown ? "Hide advanced settings" : "Show advanced settings")
    }

    /// Put the keyboard in the name field - the pencil's "ready to edit".
    func focusFirstField() {
        view.window?.makeFirstResponder(labelField)
    }

    #if FM_SELFTESTS
    var debugIsDirty: Bool { isDirty }
    var debugFooterTitles: [String] {
        panelFooter.arrangedSubviews.compactMap { ($0 as? HelmButton).map { $0.title.isEmpty ? ($0.accessibilityLabel() ?? "") : $0.title } }
    }
    var debugFooterButtons: [HelmButton] { panelFooter.arrangedSubviews.compactMap { $0 as? HelmButton } }
    var debugLabelField: HelmTextField { labelField }
    var debugAddressField: HelmTextField { addressField }
    var debugPortField: HelmTextField { portField }
    var debugUsernameField: HelmTextField { usernameField }
    var debugAdvancedShown: Bool { advancedShown }
    var debugAdvancedRowsHidden: Bool { advancedRows.allSatisfy(\.isHidden) }
    var debugAdvancedToggle: HelmButton { advancedToggle }
    var debugInlineForwards: PortForwardInlineEditor? { inlineForwards }
    var debugPanelMenuTitles: [String] { makePanelMenu().items.map(\.title) }
    var debugPanelSubtitle: String { panelSubtitle.stringValue }
    var debugTestButton: HelmButton { panelTestButton }
    var debugTestPill: HelmStatusPill { panelTestPill }
    /// Type into a field as the captain would: the text, then the delegate's
    /// own change callback.
    func debugType(_ text: String, into field: NSTextField) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    /// A key command as the field editor sends it to the delegate.
    @discardableResult
    func debugCommand(_ selector: Selector, in field: NSTextField) -> Bool {
        guard let editor = field.window?.fieldEditor(true, for: field) as? NSTextView else { return false }
        return control(field, textView: editor, doCommandBy: selector)
    }
    #endif

    /// Briefly flash a required field's focus ring when it is empty.
    private func flag(_ field: NSTextField) {
        view.window?.makeFirstResponder(field)
        NSSound.beep()
    }

    /// A blocking validation warning at Save time (Finding 5, cockpit-audit-core).
    /// Still blocking after G3: `save()` returns early right after this, and
    /// the captain has to have seen why.
    private func warn(title: String, body: String) {
        HelmConfirm.problem(title: title, body: body)
    }

    /// cockpit-native-host-form-fixes, Fix 2: this editor is presented as its
    /// own top-level window (`AppDelegate.presentHostEditor`), not via
    /// `presentAsSheet`/`presentAsModalWindow` from a parent view controller
    /// and not as a document-modal sheet either. `NSViewController.dismiss(_:)`
    /// only acts in those two cases (or the `presentingViewController` case);
    /// for a plain top-level window it is a documented no-op, which is why
    /// Cancel silently did nothing. Closing the window directly works
    /// regardless of how the view controller got there, and - since
    /// `isReleasedWhenClosed` is `false` on this cached, reused window - it
    /// still just orders out rather than deallocating, ready for the next
    /// Add/Edit call to set a fresh `contentViewController` on it.
    private func closeEditor() {
        view.window?.close()
    }
}

// MARK: - Environment quick-pick row

/// The mockup's DEV/UAT/PROD quick-pick row - a convenience over the
/// existing free-text `Host.group` field, **not** a new persisted concept
/// (per this task's own instruction: check `group`/`tags` before inventing a
/// field). Clicking a pill sets `onSelect` with that pill's title, which the
/// host editor writes straight into `groupField`; the row itself highlights
/// whichever pill case-insensitively matches the current `group` text, or
/// none when the group is empty or something else entirely (a host grouped
/// under, say, "Networking" shows no selected pill here, and the free-text
/// Group field in the Organization section is still the source of truth).
final class HostEnvironmentPicker: NSView {
    private struct Option {
        let title: String
        let tint: HelmTint
    }

    private static let options: [Option] = [
        Option(title: "DEV", tint: .info),
        Option(title: "UAT", tint: .warn),
        Option(title: "PROD", tint: .critical),
    ]

    private var pills: [(container: HoverHighlightView, dot: NSView, label: NSTextField, option: Option)] = []

    /// Fires with the clicked pill's title (`"DEV"`/`"UAT"`/`"PROD"`).
    var onSelect: ((String) -> Void)?

    private(set) var selectedTitle: String?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var containers: [NSView] = []
        for option in Self.options {
            let container = HoverHighlightView()
            container.cornerRadius = HelmField.cornerRadius
            container.identifier = NSUserInterfaceItemIdentifier(option.title)

            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: option.title)
            label.setScaledFont(ofSize: 10.5, weight: .bold)
            label.translatesAutoresizingMaskIntoConstraints = false

            let row = NSStackView(views: [dot, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 5
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
                container.heightAnchor.constraint(equalToConstant: HelmField.controlHeight),
            ])
            container.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pillClicked(_:))))
            pills.append((container, dot, label, option))
            containers.append(container)
        }

        let row = NSStackView(views: containers)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = HelmMetrics.s1 + 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func pillClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue else { return }
        select(id)
        onSelect?(id)
    }

    /// Move the highlight without firing `onSelect` - called whenever the
    /// bound `group` value changes from something other than a pill click
    /// (typing directly into the Group field, or loading an existing host).
    func select(_ groupValue: String?) {
        selectedTitle = Self.options.first { $0.title.caseInsensitiveCompare(groupValue ?? "") == .orderedSame }?.title
        applyTheme(ThemeManager.shared.theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        for (container, dot, label, option) in pills {
            let hue = HelmTheme.nsColor(option.tint.hex(in: theme))
            dot.layer?.backgroundColor = hue.cgColor
            if option.title == selectedTitle {
                let resolved = HelmContrast.tintedSurface(tintHex: option.tint.hex(in: theme),
                                                          theme: theme,
                                                          target: HelmContrast.textTarget)
                container.normalColor = resolved.fill
                container.hoverColor = resolved.fill
                container.layer?.borderWidth = 1
                container.layer?.borderColor = hue.withAlphaComponent(0.55).cgColor
                label.textColor = resolved.foreground
            } else {
                let fill = HelmField.fill(theme)
                container.normalColor = fill
                container.hoverColor = fill.hoverShifted(by: 0.10, forMode: theme.mode)
                container.layer?.borderWidth = 1
                container.layer?.borderColor = HelmField.border(theme).cgColor
                label.textColor = HelmField.mutedInk(theme)
            }
        }
    }
}
