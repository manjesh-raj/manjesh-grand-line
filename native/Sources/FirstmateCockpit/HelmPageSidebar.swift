// Manjesh Grand Line - native macOS app.
//
// The app's one **page-scoped** left navigation column: section headers over
// rows, each row optionally carrying its own count, one row selected.
//
// **Page-scoped, and that distinction is the whole reason this is safe to
// have.** Daylight Phase 2 deliberately deleted this app's app-wide
// `IconRailController` left rail and made `AppShellController.bodyContainer`
// span the window's full width; nothing here revives that. This is a column
// *inside* one destination's own body, the way Poneglyph has had one since
// `fm/grand-line-roomier-poneglyph-vault-ui-li-0f` - a page deciding how to
// lay out its own content, which is a different question from what the window
// chrome carries.
//
// **Extracted from `CredentialVaultSidebar`** when Schedules needed the same
// column (`fm/grand-line-schedules-sidebar-fullwidth-fix`). Every visual
// decision below is that file's, verbatim and deliberately unchanged - the
// `HoverHighlightView` row, the accent-wash selected fill, the corrected
// selected ink, the kicker headers, the right-aligned plain-text count. What
// changed is only that the rows are keyed by a caller-supplied `String` id
// instead of `CredentialCategory`, so a second page can have one without a
// near-copy drifting from the first (this codebase's own repeated lesson -
// see `HelmRefreshPill`'s header for the same extraction, same reasoning).

import AppKit

final class HelmPageSidebar: NSView {

    /// A row is either a **filter** (one-of-many: it stays selected, and
    /// announces as a radio button) or an **action** (it fires and leaves the
    /// selection where it was, and announces as a button).
    ///
    /// The split matters for more than accessibility: a "Run History" row that
    /// latched selected would claim the list below it had been filtered to
    /// something, which is exactly the kind of false claim this app's own
    /// conventions keep out of a nav control.
    enum RowKind {
        case filter
        case action
    }

    static let width: CGFloat = 208

    /// Fired with the row's id. A `.filter` row has already moved the
    /// selection by the time this runs; an `.action` row has not.
    var onSelect: ((String) -> Void)?

    /// The selected `.filter` row's id. Only ever a filter row - an action
    /// never becomes the selection.
    private(set) var selection: String?

    private let stack = NSStackView()
    private var rows: [(button: HoverHighlightView, id: String, kind: RowKind,
                        icon: NSImageView, label: NSTextField, count: NSTextField)] = []
    private var headers: [NSTextField] = []
    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Build

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        // A fixed column, so the content beside it takes every point the window
        // gains - but **below `NSLayoutPriorityWindowSizeStayPut`** (gotcha
        // (13)), because this column's width reaches `bodyContainer` through
        // its page, and a required one is therefore a floor on how narrow the
        // whole window may get.
        //
        // Measured rather than assumed: as a required constraint it stuck
        // `bodyContainer` at 1220pt against a 1100pt window and - because every
        // destination shares that container - took the other twenty-six down
        // with it (`AppShellBodyWidthSelfTest`'s
        // `bodyContainerTracksWindowAcrossAllDestinations`). At any width these
        // pages are really used at, 499 still beats every label beside it, so
        // the column is exactly `width`; it simply yields before the window has
        // to.
        let columnWidth = widthAnchor.constraint(equalToConstant: Self.width)
        columnWidth.priority = HelmDaylightPriority.contentTie
        columnWidth.isActive = true
    }

    // MARK: Composition

    func appendHeader(_ title: String) {
        let label = NSTextField(labelWithString: "")
        label.placeholderString = title
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        headers.append(label)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Metrics.rowInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -Metrics.rowInset),
            label.topAnchor.constraint(equalTo: holder.topAnchor),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -HelmMetrics.s2),
        ])
        appendFullWidth(holder)
    }

    func appendSpacer() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: Metrics.sectionGap).isActive = true
        appendFullWidth(spacer)
    }

    /// One nav row. A `HoverHighlightView` rather than a hand-rolled clickable
    /// view: it is this app's one hover/press/focus-ring/accessibility
    /// treatment, and GL-16's role and keyboard activation come with it (see
    /// `HelmUIComponents.swift`). A nested real control would be the
    /// hit-testing hazard that class's header warns about, so the row carries
    /// only labels.
    func appendRow(id: String, symbol: String, title: String,
                   kind: RowKind = .filter, showsCount: Bool = true) {
        let button = HoverHighlightView()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.cornerRadius = HelmMetrics.rControl

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: title)
        label.font = HelmType.caption()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The reference's count is plain right-aligned text, not a chip - so a
        // sidebar of six rows carries six numbers and no extra chrome.
        let count = NSTextField(labelWithString: "")
        count.font = HelmType.captionSmall()
        count.alignment = .right
        count.translatesAutoresizingMaskIntoConstraints = false
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.isHidden = !showsCount

        for child in [icon, label, count] as [NSView] { button.addSubview(child) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Metrics.rowInset),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: HelmMetrics.s2),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: HelmMetrics.s1),
            count.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Metrics.rowInset),
            count.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
        ])

        // GL-16: a filter is one-of-many, so it announces as a radio button
        // carrying its own selected state, exactly as `HelmSegmentedTabs` does
        // for a pill row. An action is a plain button.
        button.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:))))
        button.accessibilityRoleOverride = kind == .filter ? .radioButton : .button
        button.accessibilityLabelOverride = title
        button.identifier = NSUserInterfaceItemIdentifier(id)
        rows.append((button, id, kind, icon, label, count))
        appendFullWidth(button)
    }

    private func appendFullWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    enum Metrics {
        static let rowHeight: CGFloat = 34
        static let rowInset: CGFloat = HelmMetrics.s3 - 2
        static let sectionGap: CGFloat = HelmMetrics.s3
    }

    // MARK: Selection and counts

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view,
              let index = rows.firstIndex(where: { $0.button === view }) else { return }
        pick(index)
    }

    private func pick(_ index: Int) {
        guard index < rows.count else { return }
        let row = rows[index]
        if row.kind == .filter { select(row.id) }
        onSelect?(row.id)
    }

    /// Move the selection without firing `onSelect` - what a caller restoring
    /// state wants, and the same split `HelmSegmentedTabs.select(_:)` draws.
    func select(_ id: String?) {
        selection = id
        applyTheme(theme)
    }

    /// Keyed by row id. A row built with `showsCount: false` ignores whatever
    /// it is handed here, so a caller need not special-case its action rows.
    func setCounts(_ counts: [String: Int]) {
        for row in rows {
            guard let value = counts[row.id] else { continue }
            row.count.stringValue = "\(value)"
            // A filter with nothing under it is still reachable - it just says
            // 0. Hiding it would make the sidebar's shape change as the captain
            // types, which is worse than a zero.
            row.count.alphaValue = value == 0 ? 0.55 : 1
        }
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let muted = HelmTheme.mutedInk(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        // The same accent wash `HelmAccentRow` paints for its own selected
        // card, so a selected nav row and a selected list row are one idiom.
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let selectedFill = surface.blended(withFraction: HelmAccentRow.selectionWash, of: accent) ?? surface
        let hoverFill = surface.blended(withFraction: HelmAccentRow.selectionWash / 2.5, of: accent) ?? surface

        for header in headers {
            header.attributedStringValue = NSAttributedString(
                string: (header.placeholderString ?? "").uppercased(),
                attributes: HelmType.kickerAttributes(color: muted))
        }

        for row in rows {
            let isSelected = row.kind == .filter && row.id == selection
            // A selected row's label takes the corrected accent - never the raw
            // hue, which is audit §5.7's defect (`HelmContrast`'s own rule: a
            // tint is safe as a fill and is not automatically safe as text).
            let selectedInk = HelmContrast.legibleTintedText(
                tintHex: theme.accentHex,
                overAnyOf: [selectedFill, HelmTheme.nsColor(theme.chromeBackgroundHex)],
                theme: theme)
            row.label.textColor = isSelected ? selectedInk : ink
            row.icon.contentTintColor = isSelected ? selectedInk : muted
            row.count.textColor = muted
            // Both colours, never `layer.backgroundColor` directly: a
            // `HoverHighlightView` owns persistent hover state, and a direct
            // layer write is stranded by the next `mouseExited`
            // (`fm/grandline-updates-refresh-button-light-mode-fix`).
            row.button.normalColor = isSelected ? selectedFill : .clear
            row.button.hoverColor = isSelected ? selectedFill : hoverFill
            row.button.layer?.cornerRadius = HelmMetrics.rControl
        }
    }

    #if FM_SELFTESTS
    var debugRowCount: Int { rows.count }
    var debugRowTitles: [String] { rows.map { $0.label.stringValue } }
    var debugRowIDs: [String] { rows.map { $0.id } }
    var debugRowCounts: [String] { rows.map { $0.count.stringValue } }
    var debugSelectedIndex: Int? { rows.firstIndex { $0.kind == .filter && $0.id == selection } }
    var debugHeaders: [String] { headers.compactMap { $0.placeholderString } }
    func debugClickRow(_ index: Int) { pick(index) }
    #endif
}
