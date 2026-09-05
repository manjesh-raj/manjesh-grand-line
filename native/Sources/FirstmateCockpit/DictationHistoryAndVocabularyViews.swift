// Manjesh Grand Line - native macOS app.
//
// Dictation, phase 2 (fm/grandline-dictation-phase2): rendering for the
// transcription history list and the personal vocabulary chip row - split
// out of `DictationController.swift` to keep that file's existing
// status/shortcut sections readable.
//
// The history list is `NSTableView`-based (`DictationHistoryListView`), not a
// plain `NSStackView` of permanent rows - the same convention
// `ShiftListViews.swift`/`DiffResultView.swift` already established in this
// codebase, since a growing, unbounded-length history is exactly the shape
// that blew up into a multi-second layout pass once row counts hit the
// hundreds (see `DiffResultView.swift`'s header for the full measured
// writeup). An `NSTableView` only builds row views for what's actually
// visible, so this stays fast regardless of how many weeks of dictation
// history accumulate. The vocabulary chip row, by contrast, is a genuinely
// small, bounded list (a captain's personal vocabulary), so a plain
// frame-based flow layout (`ChipFlowView`) is fine there - no table needed.
//
// Daylight Phase 4 slice 5 restyled the history row to §6.5 (see
// `DictationHistoryRowView`) and moved the vocabulary chips *inside* an input
// well: `ChipFlowView` and `VocabularyChipView` both survive unchanged, but
// their caller is now the shared `HelmChipInput` (§6.9) rather than this
// page's own field-plus-flow-plus-Add-button trio. Nothing here builds that
// row any more - `DictationController.buildVocabularySection` owns one well.

import AppKit

// MARK: - History list

final class DictationHistoryListView: NSObject {
    let tableView = NSTableView()

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var entries: [DictationHistoryEntry] = []

    /// GL-35: per-entry delete. Set by the page; the row's trash button calls
    /// it with the entry itself (not a row index), so a list that has been
    /// re-read since the row was drawn cannot delete the wrong entry.
    var onDeleteEntry: ((DictationHistoryEntry) -> Void)?

    /// A §6.5 row card is taller than the two bare labels it replaces: it
    /// carries a kicker line over the transcript and its own card insets.
    /// Measured from `HelmAccentRow`'s own fitting height plus the 2pt the row
    /// view insets it by, the same way Shift's two lists arrived at 78.
    static let rowHeight: CGFloat = 78

    private static let columnID = NSUserInterfaceItemIdentifier("dictationHistoryCol")
    private static let rowViewID = NSUserInterfaceItemIdentifier("dictationHistoryRow")
    private static let emptyViewID = NSUserInterfaceItemIdentifier("dictationHistoryEmpty")

    override init() {
        super.init()
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.autoresizingMask = [.width]
        tableView.dataSource = self
        tableView.delegate = self
    }

    func setEntries(_ entries: [DictationHistoryEntry]) {
        self.entries = entries
        tableView.reloadData()
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        tableView.reloadData()
    }
}

#if FM_SELFTESTS
extension DictationHistoryListView {
    /// The row view the table would build for `row`, so the suite can assert
    /// the §6.5 restyle landed on the real cell rather than on a stand-in.
    func debugRowView(at row: Int) -> NSView? {
        tableView(tableView, viewFor: tableView.tableColumns.first, row: row)
    }

    var debugEntryCount: Int { entries.count }
}
#endif

extension DictationHistoryListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { max(entries.count, 1) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        entries.isEmpty ? 100 : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !entries.isEmpty else {
            let empty = (tableView.makeView(withIdentifier: Self.emptyViewID, owner: nil) as? HelmEmptyState)
                ?? { let v = HelmEmptyState(symbol: "waveform",
                                            body: "No dictations yet - hold the shortcut and speak.",
                                            hue: RailDestination.dictation.domainHue)
                     v.identifier = Self.emptyViewID; return v }()
            empty.applyTheme(theme)
            return empty
        }
        let rowView = (tableView.makeView(withIdentifier: Self.rowViewID, owner: nil) as? DictationHistoryRowView)
            ?? { let v = DictationHistoryRowView(); v.identifier = Self.rowViewID; return v }()
        let entry = entries[row]
        rowView.configure(entry: entry, theme: theme)
        rowView.onDelete = { [weak self] in self?.onDeleteEntry?(entry) }
        return rowView
    }
}

/// Daylight §6.5 / §7: "history rows as §6.5". The two bare labels over a
/// hover rectangle this replaces are now the app's one accent-carrying row -
/// so a dictation reads like every other record in the app, with a gradient
/// badge under Daylight and the accent-bar card treatment on the other twelve
/// palettes.
///
/// `HelmAccentRow` fixes its structure at `init` and takes content on
/// `configure`, which is exactly what a reused table cell needs. The delete
/// glyph is passed as the row's `trailingAccessory` - a single control, not a
/// stack, so there is no distribution to get wrong (the reused-cell hazard
/// AGENTS.md documents for a row whose action column has several buttons).
private final class DictationHistoryRowView: NSView {
    private let deleteButton = HelmButton(symbol: "trash", variant: .quiet, size: .small)
    private let row: HelmAccentRow

    /// GL-35. Reassigned on every `configure`, since table cell views are
    /// reused.
    var onDelete: (() -> Void)?

    init() {
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        row = HelmAccentRow(trailingAccessory: deleteButton, gradientBadge: true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        deleteButton.toolTip = "Delete this transcription"
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)

        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    @objc private func deleteClicked() { onDelete?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(entry: DictationHistoryEntry, theme: HelmTheme) {
        // An *identity* hue, not a semantic one: a past transcription is not a
        // state - nothing about it is healthy, failing or overdue - so no
        // `HelmTint` describes it honestly. `domainHue` (audit §6.9) resolves
        // to this page's own rose under Daylight and to `.neutral` on the
        // twelve legacy palettes, which is what lets the row read as
        // Dictation's without a red alert bar on every entry there.
        //
        // Before that field existed this row passed `.neutral` outright and
        // lost its hue on Daylight too; `tint` below is now only the value
        // `domainHue` overrides, kept as the honest answer for any future
        // palette that resolves neither.
        row.configure(.init(tint: .neutral,
                            domainHue: RailDestination.dictation.domainHue,
                            kicker: DictationRelativeTime.string(from: entry.date),
                            title: entry.text,
                            meta: DictationRelativeTime.duration(entry.durationSeconds),
                            badgeSymbol: "waveform"),
                      theme: theme)
    }
}

// MARK: - Vocabulary chips

/// A simple frame-based flow layout - AppKit's `NSStackView` has no built-in
/// wrapping, so chips are laid out and wrapped manually against the view's
/// own width on every `layout()` pass. `isFlipped` so rows read top-to-bottom
/// in insertion order, matching every other flipped-document convention in
/// this app (see `AGENTS.md`'s AppKit gotcha catalogue, item 9).
final class ChipFlowView: NSView {
    private var chips: [NSView] = []
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func setChips(_ views: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        chips = views
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let hSpacing: CGFloat = 6
        let vSpacing: CGFloat = 8
        let width = max(bounds.width, 1)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for v in chips {
            let size = v.fittingSize
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            v.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        let totalHeight = chips.isEmpty ? 0 : y + rowHeight
        if heightConstraint.constant != totalHeight {
            heightConstraint.constant = totalHeight
            superview?.needsLayout = true
        }
    }
}

/// A single removable vocabulary word/phrase pill.
final class VocabularyChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    var onRemove: (() -> Void)?

    init(word: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11

        label.stringValue = word
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        removeButton.title = ""
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(word)")
        removeButton.isBordered = false
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            removeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 14),
            removeButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func removeTapped() { onRemove?() }

    // Daylight §6.9 asks for the remove affordance to turn `bad` on hover -
    // the one piece of state feedback a token has, and the difference between
    // "there is an x here" and "clicking this removes the tag".
    private var removeHovering = false
    private var removeTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let removeTracking { removeButton.removeTrackingArea(removeTracking) }
        let area = NSTrackingArea(rect: removeButton.bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp],
                                  owner: self, userInfo: nil)
        removeButton.addTrackingArea(area)
        removeTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        removeHovering = true
        applyTheme(lastTheme)
    }

    override func mouseExited(with event: NSEvent) {
        removeHovering = false
        applyTheme(lastTheme)
    }

    private var lastTheme: HelmTheme = ThemeManager.shared.theme

    func applyTheme(_ theme: HelmTheme) {
        lastTheme = theme
        // §6.9's Daylight token: a plain white capsule with a `hair` outline,
        // because these sit *inside* a tinted well and a second tinted fill
        // there reads as two competing surfaces. Every other palette keeps the
        // accent wash this chip has always rendered.
        if theme.isDaylight {
            layer?.backgroundColor = HelmTheme.nsColor(theme.daylightTokens.card).cgColor
            layer?.borderColor = HelmTheme.nsColor(theme.daylightTokens.hair).cgColor
        } else {
            layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.16).cgColor
            layer?.borderColor = HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.4).cgColor
        }
        layer?.borderWidth = 1
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        removeButton.contentTintColor = removeHovering
            ? HelmContrast.legibleTintedText(tintHex: theme.isDaylight ? DaylightPalette.bad : theme.ansiHex[1],
                                             over: HelmTheme.nsColor(theme.chromeBackgroundHex),
                                             theme: theme)
            : HelmTheme.mutedInk(theme)
    }

    // MARK: Probe / self-test surface

    var removeGlyphColorForTests: NSColor? { removeButton.contentTintColor }
    func debugSetRemoveHovering(_ hovering: Bool) {
        removeHovering = hovering
        applyTheme(lastTheme)
    }
}
