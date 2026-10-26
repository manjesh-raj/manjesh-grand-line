// Grand Line - native macOS app.
//
// Settings > Shortcuts (T5 of the Termius-style plan): every keyboard
// shortcut in one table, with search and the Changed and Conflicts filters.
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
        let bar = NSStackView(views: [searchField, filterTabs])
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
        // One width for the column, as Settings > Terminal's recorders had:
        // a recorder sizes itself to its chord, and a ragged column of them
        // does not read as one.
        recorder.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        recorder.onChange = { [weak self] chord in self?.recorded(chord, for: shortcut) }
        recorders[shortcut] = recorder
        return SettingsRow(title: row.title, description: detail, control: recorder)
    }

    /// The control column's width: the recorders', so a read-only row's
    /// key caps end where a recorder ends and the page reads as one column.
    static let controlWidth: CGFloat = 168

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
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalToConstant: controlWidth),
            pill.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor),
            pill.topAnchor.constraint(equalTo: column.topAnchor),
            pill.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        return column
    }

    /// A recorder captured a chord.
    private func recorded(_ chord: KeyChord, for shortcut: ConfigurableShortcut) {
        apply(chord, to: shortcut)
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
    var debugEmptyLabelShown: Bool { !emptyLabel.isHidden }
    var debugEmptyText: String { emptyLabel.stringValue }
    /// Every row on the page as drawn, by title.
    var debugVisibleRows: [SettingsRow] { sections.flatMap(\.group.rows) }
    #endif
}
