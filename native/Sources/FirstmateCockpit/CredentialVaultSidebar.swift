// Manjesh Grand Line - native macOS app.
//
// Poneglyph's left navigation: **Vault** (all credentials) over **Collections**
// (one row per `CredentialCategory`), each row carrying its own count.
//
// **What it replaces, and why that is the roomier answer.** The page filtered
// by category through a `HelmSegmentedTabs` pill row sitting above the list -
// `All | Email | Cloud & AWS | API keys | Other`. That is a perfectly good
// control and it was not wrong; it was just spending a full-width row of the
// page on five chips, with no room to say how many credentials were in each,
// and it put navigation and content in the same column. The captain's reference
// mockup moves that decision into a column of its own with a count per row,
// which is both roomier and says more.
//
// **The counts are the reason this is not merely the pill row rotated.** Each
// row reports how many credentials match *that* collection under the current
// search, so the sidebar answers "where is the thing I am looking for" rather
// than only "what may I filter by". `setCounts` is handed already-computed
// numbers by the page - this view never touches the store.
//
// **Deliberately not ported from the reference:** its `Favorites` and
// `Recently deleted` rows. Neither has anything behind it - `VaultCredential`
// has no favourite flag and the store has no soft delete - so both would be
// nav rows that filter to nothing. Adding either is a data-model change, which
// is a feature rather than the layout pass this is; see the PR for the flag.
// Its `Vault storage` footer is out for the same reason: this vault reports no
// size or quota, and a progress bar with an invented percentage would be worse
// than no progress bar.

import AppKit

final class CredentialVaultSidebar: NSView {

    /// Which collection is showing. `nil` is "all credentials", which is the
    /// same no-filter state `categoryFilter` has always used - so the page's
    /// own filtering is unchanged by this control existing.
    typealias Selection = CredentialCategory?

    static let width: CGFloat = 208

    var onSelect: ((Selection) -> Void)?

    private(set) var selection: Selection

    private let stack = NSStackView()
    private var rows: [(button: HoverHighlightView, category: Selection, icon: NSImageView,
                        label: NSTextField, count: NSTextField)] = []

    private var headers: [NSTextField] = []
    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Build

    override init(frame frameRect: NSRect) {
        selection = nil
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
            // A fixed column, so the list beside it takes every point the
            // window gains. Required is safe at this size - it is nowhere near
            // `NSLayoutPriorityWindowSizeStayPut`'s concern (gotcha (13)); what
            // would be a window floor is a *label* refusing to compress, which
            // is why every one below is `.defaultLow`.
            widthAnchor.constraint(equalToConstant: Self.width),
        ])

        appendHeader("Vault")
        appendRow(nil, symbol: "square.grid.2x2.fill", title: "All credentials")
        appendSpacer()
        appendHeader("Collections")
        for category in CredentialCategory.allCases {
            appendRow(category, symbol: category.symbol, title: category.title)
        }
    }

    private func appendHeader(_ title: String) {
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

    private func appendSpacer() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: Metrics.sectionGap).isActive = true
        appendFullWidth(spacer)
    }

    /// One nav row. A `HoverHighlightView` rather than a hand-rolled clickable
    /// view: it is this app's one hover/press/focus-ring/accessibility
    /// treatment, and GL-16's `.button` role and keyboard activation come with
    /// it (see `HelmUIComponents.swift`). A nested real control would be the
    /// hit-testing hazard that class's header warns about, so the row carries
    /// only labels.
    private func appendRow(_ category: Selection, symbol: String, title: String) {
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

        // GL-16: a collection is one-of-many, so the row announces as a radio
        // button carrying its own selected state, exactly as
        // `HelmSegmentedTabs` does for the pill row this replaces.
        button.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:))))
        button.accessibilityRoleOverride = .radioButton
        button.accessibilityLabelOverride = title
        button.identifier = NSUserInterfaceItemIdentifier(category?.rawValue ?? Self.allRowID)
        rows.append((button, category, icon, label, count))
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

    static let allRowID = "all"

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view,
              let index = rows.firstIndex(where: { $0.button === view }) else { return }
        pick(index)
    }

    private func pick(_ index: Int) {
        guard index < rows.count else { return }
        select(rows[index].category)
        onSelect?(rows[index].category)
    }

    /// Move the selection without firing `onSelect` - what a caller restoring
    /// state wants, and the same split `HelmSegmentedTabs.select(_:)` draws.
    func select(_ category: Selection) {
        selection = category
        applyTheme(theme)
    }

    /// `counts` is keyed by category; `total` is the All row's own number. Both
    /// are computed by the page against the *current* search, so the sidebar
    /// says where the matches are rather than only what exists.
    func setCounts(total: Int, counts: [CredentialCategory: Int]) {
        for row in rows {
            let value = row.category.map { counts[$0] ?? 0 } ?? total
            row.count.stringValue = "\(value)"
            // A collection with nothing in it under the current search is still
            // reachable - it just says 0. Hiding it would make the sidebar's
            // shape change as the captain types, which is worse than a zero.
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
            let isSelected = row.category == selection
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
    var debugRowCounts: [String] { rows.map { $0.count.stringValue } }
    var debugSelectedIndex: Int? { rows.firstIndex { $0.category == selection } }
    func debugClickRow(_ index: Int) { pick(index) }
    var debugHeaders: [String] { headers.compactMap { $0.placeholderString } }
    #endif
}
