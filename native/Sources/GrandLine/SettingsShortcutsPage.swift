// Grand Line - native macOS app.
//
// Settings > Shortcuts (T5 of the Termius-style plan): every keyboard
// shortcut in one table, with search and the Changed and Conflicts filters.
//
// T6 is the rebinding half. A chord the captain records is checked against
// every other row - the live menu, the fixed tab table, the session chords
// and every configurable binding - before it is stored, and a clash names
// the owner and asks Use Anyway or Cancel. Each configurable row has its own
// reset, and Restore All Defaults puts every one back.
//
// The rows come from `ShortcutsTable`, which reads the live menu bar through
// the same walk the Help menu's sheet uses, so this page cannot list a chord
// the menu does not bind or miss one it does. The configurable families
// (choice C3: the nine terminal chords, quick capture and dictation) carry a
// recorder; everything else carries the chord as a key-cap pill and says
// where it is set.
//
// Its own file rather than a `build*` method on `SettingsController`: that
// controller is near three thousand lines (GL-36), and this page is the one
// Settings page whose rows are rebuilt as the captain types into its search,
// so it owns its own state. Every row is still a `SettingsRow` in a
// `SettingsSection`, so it looks like every other Settings page.

import AppKit

final class SettingsShortcutsPage: NSObject {

    /// The page's content, below the hero: the filter bar, then the sections.
    let view = NSStackView()

    private let settings: AppSettings
    /// The menu bar to read. `NSApp.mainMenu` in the app; a suite hands it a
    /// menu built with `buildMenu(installing: false)`, because `NSApp` is nil
    /// in a headless process.
    private let mainMenu: () -> NSMenu?

    /// A binding changed - tell whatever listens for it. Forwarded by
    /// `SettingsController`, which knows nothing about the monitors either.
    var onTerminalShortcutsChanged: ((TerminalShortcutSet) -> Void)?
    var onQuickCaptureShortcutChanged: ((KeyChord) -> Void)?
    var onDictationShortcutChanged: ((KeyChord) -> Void)?

    private let searchField = HelmSearchField(placeholder: "Search shortcuts")
    private let filterTabs = HelmSegmentedTabs(
        items: ShortcutsTable.Filter.allCases.map { .init(id: $0.rawValue, title: $0.title) },
        selected: ShortcutsTable.Filter.all.rawValue)
    private let restoreAllButton = HelmButton(title: "Restore All Defaults", variant: .secondary,
                                              target: nil, action: nil)
    private var resetButtons: [ObjectIdentifier: ConfigurableShortcut] = [:]
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    private(set) var rows: [ShortcutRow] = []
    private(set) var filter: ShortcutsTable.Filter = .all
    private(set) var sections: [SettingsSection] = []
    private(set) var recorders: [ConfigurableShortcut: KeyChordRecorderView] = [:]
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var cardWidth: CGFloat = 0

    init(settings: AppSettings = .shared, mainMenu: @escaping () -> NSMenu? = { NSApp?.mainMenu }) {
        self.settings = settings
        self.mainMenu = mainMenu
        super.init()

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 20
        view.translatesAutoresizingMaskIntoConstraints = false

        searchField.setAccessibilityLabel("Search shortcuts")
        searchField.onTextChanged = { [weak self] _ in self?.rebuildList() }
        filterTabs.setAccessibilityLabel("Show")
        filterTabs.onSelect = { [weak self] id in
            guard let self, let filter = ShortcutsTable.Filter(rawValue: id) else { return }
            self.filter = filter
            self.rebuildList()
        }
        // Gotcha (10): `.fill`, with the search field the one view that
        // flexes and the tabs at their own width.
        filterTabs.setContentHuggingPriority(.required, for: .horizontal)
        filterTabs.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        restoreAllButton.target = self
        restoreAllButton.action = #selector(restoreAllDefaults)
        restoreAllButton.setContentHuggingPriority(.required, for: .horizontal)
        restoreAllButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bar = NSStackView(views: [searchField, filterTabs, restoreAllButton])
        bar.orientation = .horizontal
        bar.distribution = .fill
        bar.alignment = .centerY
        bar.spacing = HelmMetrics.s3
        bar.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 20
        listStack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = HelmType.caption()
        emptyLabel.isHidden = true

        for subview in [bar, listStack, emptyLabel] as [NSView] {
            view.addArrangedSubview(subview)
            subview.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        reload()
    }

    // MARK: Data

    /// Re-read every family and the menu bar. Called when Settings appears
    /// (the Go menu's digit items follow the hidden modules) and after any
    /// binding changes.
    func reload() {
        rows = ShortcutsTable.rows(mainMenu: mainMenu(), settings: settings)
        rebuildList()
    }

    /// The rows the current search and filter leave, grouped under their
    /// sections in table order.
    private func rebuildList() {
        for section in sections {
            listStack.removeArrangedSubview(section)
            section.removeFromSuperview()
        }
        sections = []
        recorders = [:]
        resetButtons = [:]
        restoreAllButton.isEnabled = rows.contains { $0.isChanged }

        let visible = ShortcutsTable.visible(rows, filter: filter, search: searchField.stringValue)
        var order: [String] = []
        var grouped: [String: [ShortcutRow]] = [:]
        for row in visible {
            if grouped[row.section] == nil { order.append(row.section) }
            grouped[row.section, default: []].append(row)
        }
        for title in order {
            let settingsRows = (grouped[title] ?? []).map(makeRow)
            let section = SettingsSection(heading: title, group: SettingsGroup(rows: settingsRows))
            listStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            sections.append(section)
        }

        emptyLabel.isHidden = !visible.isEmpty
        emptyLabel.stringValue = emptyText()
        applyTheme(theme)
        if cardWidth > 0 { relayoutDescriptions(cardWidth: cardWidth) }
    }

    private func emptyText() -> String {
        let search = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch filter {
        case .conflicts where search.isEmpty: return "No conflicts. Every shortcut you can change has keys of its own."
        case .changed where search.isEmpty: return "Every shortcut is on its default."
        default: return "No shortcut matches \u{201C}\(search)\u{201D}."
        }
    }

    // MARK: Rows

    private func makeRow(_ row: ShortcutRow) -> SettingsRow {
        var detail = row.source
        if !row.conflicts.isEmpty {
            detail += "\n" + "Also used by " + row.conflicts.joined(separator: ", ")
        }
        guard let shortcut = row.configurable else {
            let pill = HelmKeyHint(keys: row.keys)
            pill.setAccessibilityLabel("\(row.title): \(row.keys.joined())")
            return SettingsRow(title: row.title, description: detail, control: Self.controlColumn(pill))
        }
        let recorder = KeyChordRecorderView(shortcut: shortcut.current(in: settings), mode: shortcut.recorderMode)
        recorder.setAccessibilityLabel("\(row.title) shortcut")
        // One width for the column, as Settings > Terminal's recorders had
        // before T7 moved them here:
        // a recorder sizes itself to its chord, and a ragged column of them
        // does not read as one.
        recorder.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        recorder.onChange = { [weak self] chord in self?.recorded(chord, for: shortcut) }
        recorders[shortcut] = recorder

        // T6: the row's own reset, enabled only while it is off its default.
        // Always laid out, so the recorder column does not move as rows
        // change.
        let reset = HelmButton(symbol: "arrow.uturn.backward", variant: .quiet,
                               target: self, action: #selector(resetRowClicked(_:)))
        let label = "Reset \(row.title) to \(shortcut.defaultChord.displayString)"
        reset.toolTip = label
        reset.setAccessibilityLabel(label)
        reset.isEnabled = row.isChanged
        reset.widthAnchor.constraint(equalToConstant: Self.resetWidth).isActive = true
        resetButtons[ObjectIdentifier(reset)] = shortcut
        let control = NSStackView(views: [recorder, reset])
        control.orientation = .horizontal
        control.spacing = Self.resetGap
        return SettingsRow(title: row.title, description: detail, control: control)
    }

    /// The control column's width: the recorders', so a read-only row's
    /// key caps end where a recorder ends and the page reads as one column.
    static let controlWidth: CGFloat = 168
    static let resetWidth: CGFloat = 28
    static let resetGap: CGFloat = HelmMetrics.s2

    /// A key-cap pill, trailing-aligned in a column as wide as a recorder.
    ///
    /// A container with an explicit width rather than the pill itself:
    /// `HelmKeyHint` is a stack of caps with no intrinsic size, so the row's
    /// content priorities are no-ops on it (gotcha (12)) and it rendered
    /// against the caption rather than at the row's trailing edge.
    private static func controlColumn(_ pill: NSView) -> NSView {
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(pill)
        // As wide as a recorder plus its reset button, with the caps ending
        // where the recorders end rather than where the resets do.
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalToConstant: controlWidth + resetGap + resetWidth),
            pill.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -(resetGap + resetWidth)),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor),
            pill.topAnchor.constraint(equalTo: column.topAnchor),
            pill.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        return column
    }

    /// A recorder captured a chord, or a reset asked for the default.
    ///
    /// T6: the chord is checked against every other row before it is stored
    /// - the live menu, the fixed tab table and ⌘1-⌘9, the session chords
    /// and every other configurable binding - with masks compared through
    /// `KeyChord.relevantModifierMask` (gotcha (21)). A clash names its
    /// owners and asks. Cancel puts the recorder back on the binding it had,
    /// so the row never shows a chord that was not stored.
    private func recorded(_ chord: KeyChord, for shortcut: ConfigurableShortcut) {
        let previous = shortcut.current(in: settings)
        guard !ShortcutsTable.sameKeys(chord, previous) else {
            recorders[shortcut]?.shortcut = previous
            return
        }
        let owners = ShortcutsTable.owners(of: chord, for: shortcut, in: rows)
        if !owners.isEmpty {
            let names = owners.map { "\u{201C}\($0.label)\u{201D}" }.joined(separator: " and ")
            let confirmed = HelmConfirm.confirm(
                title: "\(chord.displayString) is already in use",
                body: "It belongs to \(names). Use it for \u{201C}\(shortcut.title)\u{201D} anyway? Both keep the same keys, and whichever Grand Line checks first wins - a terminal shortcut is checked before the menu while a Console tab is showing.",
                confirmTitle: "Use Anyway", cancelTitle: "Cancel",
                confirmIsDefault: false, symbol: "exclamationmark.triangle", hue: .amber)
            guard confirmed else {
                recorders[shortcut]?.shortcut = previous
                return
            }
        }
        apply(chord, to: shortcut)
    }

    @objc private func resetRowClicked(_ sender: NSButton) {
        guard let shortcut = resetButtons[ObjectIdentifier(sender)] else { return }
        recorded(shortcut.defaultChord, for: shortcut)
    }

    /// Every configurable binding back to its default. Asks first, because
    /// it throws away every choice on the page at once.
    @objc private func restoreAllDefaults() {
        let changed = ConfigurableShortcut.all.filter { $0.current(in: settings) != $0.defaultChord }
        guard !changed.isEmpty else { return }
        let count = changed.count == 1 ? "1 shortcut you changed goes" : "\(changed.count) shortcuts you changed go"
        guard HelmConfirm.confirm(title: "Restore every shortcut to its default?",
                                  body: "\(count) back to the default Grand Line ships with.",
                                  confirmTitle: "Restore Defaults", symbol: "arrow.uturn.backward", hue: .amber)
        else { return }
        for shortcut in changed { shortcut.store(shortcut.defaultChord, in: settings) }
        if changed.contains(where: { if case .terminal = $0 { return true } else { return false } }) {
            onTerminalShortcutsChanged?(settings.terminalShortcuts)
        }
        if changed.contains(.quickCapture) { onQuickCaptureShortcutChanged?(settings.quickCaptureShortcut) }
        if changed.contains(.dictation) { onDictationShortcutChanged?(settings.dictationShortcut) }
        reload()
    }

    /// Store a binding, tell its listener, and rebuild the table so the
    /// Changed and Conflicts state follows at once.
    private func apply(_ chord: KeyChord, to shortcut: ConfigurableShortcut) {
        shortcut.store(chord, in: settings)
        switch shortcut {
        case .terminal: onTerminalShortcutsChanged?(settings.terminalShortcuts)
        case .quickCapture: onQuickCaptureShortcutChanged?(chord)
        case .dictation: onDictationShortcutChanged?(chord)
        }
        reload()
    }

    // MARK: Layout and theme

    func relayoutDescriptions(cardWidth: CGFloat) {
        self.cardWidth = cardWidth
        for section in sections { section.relayoutDescriptions(cardWidth: cardWidth) }
        emptyLabel.preferredMaxLayoutWidth = cardWidth
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        searchField.applyTheme(theme)
        filterTabs.applyTheme(theme)
        for section in sections { section.applyTheme(theme) }
        for recorder in recorders.values { recorder.applyTheme(theme) }
        emptyLabel.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugSearchField: HelmSearchField { searchField }
    var debugFilterTabs: HelmSegmentedTabs { filterTabs }
    var debugRestoreAllButton: HelmButton { restoreAllButton }
    func debugResetButton(for shortcut: ConfigurableShortcut) -> HelmButton? {
        sections.flatMap(\.group.rows).lazy
            .compactMap { ($0.control as? NSStackView)?.arrangedSubviews.last as? HelmButton }
            .first { self.resetButtons[ObjectIdentifier($0)] == shortcut }
    }
    var debugEmptyLabelShown: Bool { !emptyLabel.isHidden }
    var debugEmptyText: String { emptyLabel.stringValue }
    /// Every row on the page as drawn, by title.
    var debugVisibleRows: [SettingsRow] { sections.flatMap(\.group.rows) }
    #endif
}
