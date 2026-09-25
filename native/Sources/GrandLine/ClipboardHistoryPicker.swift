// Grand Line - native macOS app.
//
// F3's ⌘⇧V surface: the bar button, the panel, and its rows.
//
// **The chrome is `HelmBarPanel`**, which is what the report asks for and what
// Recents and the bell already are - so this is that file's third consumer
// rather than a fourth floating-card recipe (see `HelmBarPanel`'s header for
// the shadow, the outside-click monitor and the lock registration it brings).
// The rows are `HelmAccentRow`, this app's one record row, with the entry's
// own preview as the title, its time and source as the meta line, and the
// ⌘1-⌘9 digit as the chip - the mockup's own shape, mapped onto the existing
// component rather than a new one.
//
// **What the picker has to say honestly.** Three states are genuinely
// different and are drawn differently (GL-14):
//
//   - *empty*: nothing has been copied yet.
//   - *unavailable*: the Keychain would not give up the key, so there is no
//     history rather than an empty one. Never rendered as "0 items".
//   - *a skipped row*: a copy this app deliberately did not record. Drawn,
//     not hidden - the mockup's own note is that a history which silently
//     omits vault copies looks broken the first time you go looking for one.
//
// **Where ⌘⇧V comes from.** An Edit-menu item, so it works wherever the app is
// frontmost and shows up in Help > Keyboard Shortcuts for free. ⌘⇧V is
// checked-free against `main.swift`'s own menu (the Edit menu's Paste is ⌘V;
// nothing claimed ⇧⌘V), which is the check `NavigationCoherenceSelfTest`
// enforces for every chord in this app.

import AppKit

// MARK: - The bar button

final class ClipboardHistoryButton: DaylightBarIconButton {
    init() {
        super.init(symbol: "doc.on.clipboard",
                   tooltip: "Clipboard History (\u{21E7}\u{2318}V)",
                   accessibilityLabel: "Clipboard History")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - The controller

/// Owns the button, the panel and the panel's content - the same shape
/// `RecentDestinationsController` has, for the same reason.
final class ClipboardHistoryController: NSObject {
    let button = ClipboardHistoryButton()

    private let panel: HelmBarPanel
    private let content: ClipboardHistoryPanelViewController
    private let store: ClipboardHistoryStore
    private var themeObservation: ThemeObservation?

    /// Fired after an entry is put back on the pasteboard, so the shell can
    /// toast it. Forwarded, never owned - this controller has no idea what a
    /// toast is.
    var onPasted: ((ClipboardHistoryEntry) -> Void)?

    private var captureToken: UUID?

    /// **This controller owns the one `ClipboardHistoryStore`** (GL-23 - it
    /// caches its decrypted entries, so a second instance would be a second
    /// source of truth and a second writer to one file). Injectable for a
    /// suite, defaulted for the app, the same shape every store-backed
    /// controller here uses.
    init(store: ClipboardHistoryStore = ClipboardHistoryStore()) {
        self.store = store
        content = ClipboardHistoryPanelViewController(store: store)
        panel = HelmBarPanel(content: content)
        super.init()
        button.target = self
        button.action = #selector(buttonClicked)
        content.onSizeChanged = { [weak self] size in self?.panel.setContentSize(size) }
        content.onRequestClose = { [weak self] in self?.panel.close() }
        content.onPaste = { [weak self] entry in
            guard let self else { return }
            guard self.store.copyToPasteboard(entry) else { return }
            self.onPasted?(entry)
            self.panel.close()
        }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            self?.content.applyTheme(theme)
        }
        store.onChange = { [weak self] in
            // Only while it is open: a repaint of a panel nobody can see is
            // exactly the work GL-24's "a theme observer repaints, it never
            // fetches" and GL-13 both exist to avoid, and this fires on every
            // copy the captain makes anywhere on the machine.
            guard self?.panel.isShown == true else { return }
            self?.content.reload()
        }
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
        if let captureToken { CredentialVaultClipboard.shared.unobserveChanges(captureToken) }
    }

    /// Start recording copies.
    ///
    /// **Called explicitly from `main.swift` rather than at init**, and that
    /// is deliberate: a dozen self-test suites construct a real
    /// `DaylightBarController`, and a controller that armed a pasteboard watch
    /// in its own initialiser would have every one of them quietly recording
    /// the captain's real clipboard for the length of the run. The app arms
    /// it once; nothing else does.
    ///
    /// The watch itself is `CredentialVaultClipboard`'s single shared
    /// `changeCount` tick - see that class's own header for why there is not a
    /// second poller.
    func startCapturing() {
        guard captureToken == nil else { return }
        captureToken = CredentialVaultClipboard.shared.observeChanges { [weak self] _ in
            self?.recordCurrentPasteboard()
        }
    }

    private func recordCurrentPasteboard() {
        // GL-09: recording is a *write of the captain's data* driven by
        // activity outside this app, which is the exact shape the gate's own
        // header describes. A locked app records nothing - otherwise walking
        // away from a locked Mac and copying on it would still fill the
        // history.
        guard AppLockGate.shared.allows(.clipboardHistory) else { return }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName
        let outcome = store.record(sourceApp: source == "Grand Line" ? nil : source)
        if case .refusedConcealed = outcome {
            AppLog.ui.info("clipboard history: skipped a concealed copy")
        }
    }

    /// The ⌘⇧V verb, and the button's own click.
    ///
    /// GL-09: the history is a disclosure of everything the captain has
    /// copied, and this panel is `.floating` - so it is gated exactly like the
    /// other walk-up surfaces.
    func toggle() {
        guard AppLockGate.shared.allows(.clipboardHistory) else {
            AppLog.lifecycle.info("clipboard history refused - app is locked (GL-09)")
            NSSound.beep()
            return
        }
        if panel.isShown {
            panel.close()
        } else {
            content.reload()
            panel.show(under: button)
            content.focusFilter()
        }
    }

    @objc private func buttonClicked() { toggle() }

    #if FM_SELFTESTS
    var debugPanel: HelmBarPanel { panel }
    var debugContent: ClipboardHistoryPanelViewController { content }
    #endif
}

// MARK: - The panel content

final class ClipboardHistoryPanelViewController: NSViewController {

    /// Wider than Recents' 260 and the bell's 360: a row here carries a real
    /// clipping, and the mockup draws it at 540.
    static let width: CGFloat = 540

    /// How many rows carry a ⌘-digit shortcut. Nine, because ⌘0 is not a
    /// tenth digit anybody reaches for, and the rest are reachable by arrow
    /// keys and by clicking.
    static let numberedRows = 9

    private let store: ClipboardHistoryStore
    private var theme = ThemeManager.shared.theme

    private let titleLabel = NSTextField(labelWithString: "Clipboard")
    private let countLabel = NSTextField(labelWithString: "")
    private let hotkeyChip = NSTextField(labelWithString: "\u{21E7}\u{2318}V")
    private let filterField = HelmSearchField(placeholder: "Filter history\u{2026}")
    private let pinnedHeader = NSTextField(labelWithString: "PINNED")
    private let pinnedStack = NSStackView()
    private let recentHeader = NSTextField(labelWithString: "RECENT")
    private let recentStack = NSStackView()
    private let emptyState = HelmEmptyState(symbol: "doc.on.clipboard",
                                            body: "Nothing copied yet.")
    private let unavailableState = HelmEmptyState(
        symbol: "exclamationmark.triangle",
        body: "Clipboard history is unavailable \u{2014} its Keychain key could not be read.")
    private let hintLabel = NSTextField(labelWithString: "")
    private let headerSeparator = NSView()
    private let footerSeparator = NSView()

    var onSizeChanged: ((NSSize) -> Void)?
    var onRequestClose: (() -> Void)?
    var onPaste: ((ClipboardHistoryEntry) -> Void)?

    /// The rows currently drawn, in display order - what a ⌘-digit resolves
    /// against, so the digit printed on a chip and the digit that fires it can
    /// never disagree.
    private(set) var shownEntries: [ClipboardHistoryEntry] = []

    init(store: ClipboardHistoryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let root = ClipboardHistoryRootView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 260))
        root.wantsLayer = true
        root.onDigit = { [weak self] digit in self?.activateRow(number: digit) ?? false }
        root.onPin = { [weak self] in self?.togglePinOnFirstRow() ?? false }
        view = root

        for label in [titleLabel, countLabel, hotkeyChip, pinnedHeader, recentHeader, hintLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.onTextChanged = { [weak self] _ in self?.reload() }
        filterField.onCommand = { [weak self] selector in
            guard let self else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                return self.activateRow(number: 1)
            case #selector(NSResponder.cancelOperation(_:)):
                self.onRequestClose?()
                return true
            default:
                return false
            }
        }

        for stack in [pinnedStack, recentStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = HelmMetrics.s1
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        for separator in [headerSeparator, footerSeparator] {
            separator.wantsLayer = true
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        emptyState.heightAnchor.constraint(equalToConstant: 80).isActive = true
        unavailableState.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let header = NSStackView(views: [titleLabel, countLabel, NSView(), hotkeyChip])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = HelmMetrics.s2
        header.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, headerSeparator, filterField,
                                        unavailableState, emptyState,
                                        pinnedHeader, pinnedStack,
                                        recentHeader, recentStack,
                                        footerSeparator, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(HelmMetrics.s3, after: header)
        stack.setCustomSpacing(HelmMetrics.s3, after: headerSeparator)
        root.addSubview(stack)

        let gutter = HelmMetrics.s3
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s3),
        ])
        for view in [header, filterField, emptyState, unavailableState,
                     pinnedHeader, pinnedStack, recentHeader, recentStack, hintLabel] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: gutter),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -gutter),
            ])
        }
        NSLayoutConstraint.activate([
            headerSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        applyTheme(theme)
        reload()
    }

    func focusFilter() {
        view.window?.makeFirstResponder(filterField)
    }

    /// Rebuild every row from the store's current entries.
    ///
    /// A full rebuild rather than a diff, matching
    /// `RecentDestinationsPanelViewController.reload()`'s own reasoning: the
    /// list is capped and the panel is only ever open for a few seconds.
    func reload() {
        for stack in [pinnedStack, recentStack] {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        }

        // B1 (and review finding B17): the picker used to read only
        // `isAvailable`, so a history that was present-but-unopenable rendered
        // "Nothing copied yet" - GL-14's exact prohibition, and the reason the
        // captain did not learn for three days that two 200-entry files had
        // been shelved. `loadFailed` is the second state, and any shelved file
        // is named here because nothing else in the app ever mentioned them.
        let unavailable = !store.isAvailable || store.loadFailed
        unavailableState.isHidden = !unavailable
        if unavailable { unavailableState.setText(body: unavailableMessage()) }
        let matches = unavailable ? [] : store.filtered(filterField.stringValue)
        shownEntries = matches
        emptyState.isHidden = unavailable || !matches.isEmpty

        let pinned = matches.filter(\.isPinned)
        let recent = matches.filter { !$0.isPinned }
        pinnedHeader.isHidden = pinned.isEmpty
        pinnedStack.isHidden = pinned.isEmpty
        recentHeader.isHidden = recent.isEmpty
        recentStack.isHidden = recent.isEmpty

        pinnedHeader.attributedStringValue = kicker("PINNED \u{00B7} \(pinned.count)")
        recentHeader.attributedStringValue = kicker("RECENT")

        var number = 0
        for entry in matches {
            number += 1
            let row = makeRow(for: entry, number: number)
            let stack = entry.isPinned ? pinnedStack : recentStack
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }

        countLabel.stringValue = unavailable
            ? "unavailable"
            : "\(store.entries.filter { $0.kind == .text }.count) items \u{00B7} encrypted on disk"
        applyTheme(theme)
        updateSize()
    }

    /// What the unavailable state says, which depends on *why* it is
    /// unavailable and on whether anything was shelved.
    private func unavailableMessage() -> String {
        let shelved = store.shelvedBackups.count
        let cause = store.isAvailable
            ? "Clipboard history could not be opened \u{2014} the file is there, but this key does not read it."
            : "Clipboard history is unavailable \u{2014} its Keychain key could not be read."
        guard shelved > 0 else { return cause }
        let noun = shelved == 1 ? "copy" : "copies"
        return cause
            + "\n\(shelved) earlier \(noun) kept beside it in "
            + store.fileURL.deletingLastPathComponent().lastPathComponent + "."
    }

    private func makeRow(for entry: ClipboardHistoryEntry, number: Int) -> HelmAccentRow {
        let row = HelmAccentRow(chipPlacement: .trailing)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.configure(HelmAccentRow.Content(
            // A clipping is an identity, not a state - so the hue carries it
            // and the tint stays neutral (`HelmDomainHue.fallbackTint` would
            // paint a semantic alert bar on an ordinary row, which is the
            // defect `RecentDestinationsPopover.makeRow` records).
            tint: entry.kind == .skipped ? .critical : .neutral,
            domainHue: entry.kind == .skipped ? nil : (entry.isPinned ? .amber : .teal),
            kicker: "",
            title: entry.preview,
            meta: Self.metaLine(for: entry),
            badgeSymbol: entry.symbol,
            chipText: number <= Self.numberedRows ? "\u{2318}\(number)" : nil
        ), theme: theme)
        // A skipped marker is a statement, not a clipping: clicking it can
        // paste nothing, so it is not clickable at all.
        row.onClick = entry.kind == .text ? { [weak self] in self?.onPaste?(entry) } : nil
        return row
    }

    static func metaLine(for entry: ClipboardHistoryEntry) -> String {
        let when = relativeTime(since: entry.capturedAt)
        switch entry.kind {
        case .skipped:
            return "\(when) \u{00B7} concealed type, excluded by rule"
        case .text:
            var parts = [when]
            if entry.isPinned { parts.insert("pinned", at: 0) }
            if let source = entry.sourceApp, !source.isEmpty { parts.append("from \(source)") }
            return parts.joined(separator: " \u{00B7} ")
        }
    }

    static func relativeTime(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// ⌘1-⌘9. Returns whether the digit resolved to a real row - so an
    /// out-of-range digit falls through to the rest of the app rather than
    /// being swallowed.
    @discardableResult
    func activateRow(number: Int) -> Bool {
        guard number >= 1, number <= shownEntries.count else { return false }
        let entry = shownEntries[number - 1]
        guard entry.kind == .text else { return false }
        onPaste?(entry)
        return true
    }

    /// ⌘P pins (or unpins) the first row, which is what the filter has just
    /// narrowed to.
    @discardableResult
    func togglePinOnFirstRow() -> Bool {
        guard let entry = shownEntries.first, entry.kind == .text else { return false }
        store.setPinned(!entry.isPinned, id: entry.id)
        reload()
        return true
    }

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(view.fittingSize)
    }

    private func kicker(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text,
                           attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        titleLabel.font = HelmType.rowTitle()
        titleLabel.textColor = ink
        countLabel.font = .systemFont(ofSize: HelmType.scaled(11))
        countLabel.textColor = muted
        hotkeyChip.font = HelmType.code()
        hotkeyChip.textColor = muted
        hintLabel.font = .systemFont(ofSize: HelmType.scaled(11))
        hintLabel.textColor = muted
        hintLabel.stringValue = "\u{23CE} paste the top match \u{00B7} \u{2318}1\u{2013}\u{2318}9 paste \u{00B7} \u{2318}P pin \u{00B7} Esc dismiss"
        headerSeparator.layer?.backgroundColor = line.withAlphaComponent(0.6).cgColor
        footerSeparator.layer?.backgroundColor = line.withAlphaComponent(0.6).cgColor
        pinnedHeader.attributedStringValue = kicker(pinnedHeader.stringValue)
        recentHeader.attributedStringValue = kicker(recentHeader.stringValue)
        emptyState.applyTheme(theme)
        unavailableState.applyTheme(theme)
        for stack in [pinnedStack, recentStack] {
            for case let row as HelmAccentRow in stack.arrangedSubviews { row.applyTheme(theme) }
        }
    }

    #if FM_SELFTESTS
    func debugRows() -> [HelmAccentRow] {
        (pinnedStack.arrangedSubviews + recentStack.arrangedSubviews).compactMap { $0 as? HelmAccentRow }
    }
    var debugEmptyStateIsHidden: Bool { emptyState.isHidden }
    var debugUnavailableStateIsHidden: Bool { unavailableState.isHidden }
    var debugCountText: String { countLabel.stringValue }
    var debugRootView: ClipboardHistoryRootView? { view as? ClipboardHistoryRootView }
    func debugSetFilter(_ text: String) {
        filterField.stringValue = text
        reload()
    }
    #endif
}

// MARK: - The panel's root view

/// Reads ⌘1-⌘9 and ⌘P.
///
/// Same mechanism, and same reason, as `CaptureRootView`: the filter field's
/// editor holds focus while these are pressed, and a field editor's
/// `doCommandBy` never sees a command-modified key.
final class ClipboardHistoryRootView: NSView {
    var onDigit: ((Int) -> Bool)?
    var onPin: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let characters = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        if let digit = Int(characters), digit >= 1, digit <= 9 {
            return onDigit?(digit) ?? false
        }
        if characters.lowercased() == "p" {
            return onPin?() ?? false
        }
        return super.performKeyEquivalent(with: event)
    }
}
