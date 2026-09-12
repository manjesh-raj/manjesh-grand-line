// Manjesh Grand Line - native macOS app.
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
// button has no backing capability anywhere in this app (no connection-test
// code exists to call) and was deliberately left out rather than invented -
// see the PR description for this task.
//
// Section numbering also picked up a fifth section, "Appearance" (the icon/
// colour pickers), that the mockup itself doesn't show - those pickers are a
// real, already-shipped feature (`Host.iconSymbol`/`accentHex`) with no
// equivalent in the mockup's four sections, and removing them would be a
// functionality regression, not a restyle.

import AppKit

final class HostEditorController: NSViewController, NSTextFieldDelegate {

    /// The form's content column never grows past this, regardless of window
    /// width - a typical macOS dialog reading width, centred in whatever space
    /// the window actually has.
    private static let maxContentWidth: CGFloat = 520

    /// The host being edited; `nil` for a brand-new host.
    private let editing: Host?

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

    init(host: Host?, keyStore: SSHKeyStore, snippets: [Snippet], existingLabels: Set<String> = []) {
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

    override func loadView() {
        let form = HelmFormSheet(title: editing == nil ? "New Host" : "Edit Host",
                                 scrolls: true,
                                 maxContentWidth: Self.maxContentWidth,
                                 domainHue: RailDestination.hosts.domainHue)
        form.autoresizingMask = [.width, .height]
        form.setFrameSize(NSSize(width: 640, height: 780))
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
        environmentPicker.onSelect = { [weak self] title in self?.groupField.stringValue = title }
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
        form.addColumns([form.labelledField("Group", groupField),
                          form.labelledField("Tags", tagsColumn)])

        form.addSection("Advanced", number: "05")
        agentForwardRow.isOn = editing?.agentForward ?? false
        blockViewRow.isOn = editing?.blockViewOptIn ?? false
        kubeContextBadgeRow.isOn = editing?.kubeContextBadgeOptIn ?? false
        form.addRow(agentForwardRow)
        form.addRow(blockViewRow)
        form.addRow(kubeContextBadgeRow)
        jumpViaField.stringValue = editing?.jumpVia ?? ""
        form.addField("Jump via", jumpViaField)
        portForwardingButton.target = self
        portForwardingButton.action = #selector(editPortForwarding)
        updatePortForwardingButtonTitle()
        let forwardingRow = NSStackView(views: [portForwardingButton, NSView()])
        forwardingRow.orientation = .horizontal
        forwardingRow.distribution = .fill
        forwardingRow.translatesAutoresizingMaskIntoConstraints = false
        forwardingRow.arrangedSubviews[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        form.addRow(form.labelledField("Port forwarding", forwardingRow))
        buildSnippetChooser()
        form.addRow(snippetCard)
        form.addCaption("Jumping chains through another saved host's own jump host automatically. "
            + "Agent forwarding and port-forwarding rules apply to this host's own connection.")

        form.setFooter(target: self,
                       confirmTitle: editing == nil ? "Create Host" : "Save Changes",
                       confirm: #selector(save),
                       cancel: #selector(cancel),
                       delete: editing == nil ? nil : (title: "Delete Host", action: #selector(deleteHost)))

        form.setSubtitle("Stored on this Mac. Credentials stay in the Keychain.")
        form.refreshTheme()
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
            } catch {
                self.presentKeyStoreError(error, label: newKey.label)
            }
        }
        presentAsSheet(editor)
    }

    private func presentKeyStoreError(_ error: Error, label: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save \"\(label)\" to the Keychain"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
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
            return
        }
        guard field === tagInputField else { return }
        let text = tagInputField.stringValue
        guard text.hasSuffix(",") else { return }
        let candidate = String(text.dropLast())
        tagInputField.stringValue = ""
        commitTag(candidate)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === tagInputField, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        commitTag(tagInputField.stringValue)
        tagInputField.stringValue = ""
        return true
    }

    private func commitTag(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !tagChips.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        tagChips.append(trimmed)
        renderTagChips()
    }

    private func renderTagChips() {
        let theme = ThemeManager.shared.theme
        let chips: [NSView] = tagChips.map { tag in
            let chip = VocabularyChipView(word: tag)
            chip.applyTheme(theme)
            chip.onRemove = { [weak self] in
                self?.tagChips.removeAll { $0 == tag }
                self?.renderTagChips()
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
    }

    @objc private func pickColor(_ sender: NSButton) {
        selectedAccent = sender.identifier?.rawValue ?? selectedAccent
        styleIconButtons() // recolour the selected icon preview
        styleColorButtons()
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

    @objc private func save() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            flag(addressField)
            return
        }
        guard let port = Int(portField.stringValue), (1...65535).contains(port) else {
            flag(portField)
            warn(title: "Invalid port", body: "Port must be a whole number between 1 and 65535.")
            return
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
            return
        }
        if Host.hasUnsafeLeadingDash(usernameField.stringValue) {
            flag(usernameField)
            warn(title: "Username can't start with \u{201C}-\u{201D}",
                 body: "`ssh` would read it as a command-line option instead of a login name.")
            return
        }
        if Host.hasUnsafeLeadingDash(jumpViaField.stringValue) {
            flag(jumpViaField)
            warn(title: "Jump host can't start with \u{201C}-\u{201D}",
                 body: "`ssh` would read it as a command-line option instead of a jump destination.")
            return
        }

        var host = editing ?? Host(label: "", address: "")
        let resolvedLabel = label.isEmpty ? address : label
        if existingLabels.contains(resolvedLabel) {
            flag(labelField)
            warn(title: "Duplicate label", body: "Another saved host already uses the label \u{201C}\(resolvedLabel)\u{201D}. Quick-connect can't tell them apart - pick a unique label.")
            return
        }
        host.label = resolvedLabel
        host.address = address
        host.port = port
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
        host.portForwards = portForwards
        host.startupSnippetID = selectedSnippetID
        host.iconSymbol = selectedIcon
        host.accentHex = selectedAccent

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

    /// Briefly flash a required field's focus ring when it is empty.
    private func flag(_ field: NSTextField) {
        view.window?.makeFirstResponder(field)
        NSSound.beep()
    }

    /// A blocking validation warning at Save time (Finding 5, cockpit-audit-core) -
    /// same `NSAlert` shape as the Keychain-save-failure alert above.
    private func warn(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.runModal()
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
            label.font = .systemFont(ofSize: 10.5, weight: .bold)
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
