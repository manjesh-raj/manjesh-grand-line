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
//
// **A thin adapter over `HelmPageSidebar` since
// `fm/grand-line-schedules-sidebar-fullwidth-fix`.** Every visual decision this
// file used to make itself now lives in that shared component, unchanged, so
// Schedules' own column cannot drift from this one. What stays here is the only
// thing that was ever vault-specific: the `CredentialCategory` typing, and the
// mapping between a category and its row id.

import AppKit

final class CredentialVaultSidebar: NSView {

    /// Which collection is showing. `nil` is "all credentials", which is the
    /// same no-filter state `categoryFilter` has always used - so the page's
    /// own filtering is unchanged by this control existing.
    typealias Selection = CredentialCategory?

    static let width: CGFloat = HelmPageSidebar.width

    var onSelect: ((Selection) -> Void)?

    private(set) var selection: Selection

    private let nav = HelmPageSidebar()

    // MARK: Build

    override init(frame frameRect: NSRect) {
        selection = nil
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(nav)
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: trailingAnchor),
            nav.topAnchor.constraint(equalTo: topAnchor),
            nav.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        nav.appendHeader("Vault")
        nav.appendRow(id: Self.allRowID, symbol: "square.grid.2x2.fill", title: "All credentials")
        nav.appendSpacer()
        nav.appendHeader("Collections")
        for category in CredentialCategory.allCases {
            nav.appendRow(id: category.rawValue, symbol: category.symbol, title: category.title)
        }
        nav.select(Self.allRowID)

        nav.onSelect = { [weak self] id in
            guard let self else { return }
            let category = Self.category(forRowID: id)
            self.selection = category
            self.onSelect?(category)
        }
    }

    // MARK: Selection and counts

    static let allRowID = "all"

    private static func category(forRowID id: String) -> Selection {
        id == allRowID ? nil : CredentialCategory(rawValue: id)
    }

    private static func rowID(for category: Selection) -> String {
        category?.rawValue ?? allRowID
    }

    /// Move the selection without firing `onSelect` - what a caller restoring
    /// state wants, and the same split `HelmSegmentedTabs.select(_:)` draws.
    func select(_ category: Selection) {
        selection = category
        nav.select(Self.rowID(for: category))
    }

    /// `counts` is keyed by category; `total` is the All row's own number. Both
    /// are computed by the page against the *current* search, so the sidebar
    /// says where the matches are rather than only what exists.
    func setCounts(total: Int, counts: [CredentialCategory: Int]) {
        var byID: [String: Int] = [Self.allRowID: total]
        for category in CredentialCategory.allCases {
            byID[category.rawValue] = counts[category] ?? 0
        }
        nav.setCounts(byID)
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) { nav.applyTheme(theme) }

    #if FM_SELFTESTS
    var debugRowCount: Int { nav.debugRowCount }
    var debugRowTitles: [String] { nav.debugRowTitles }
    var debugRowCounts: [String] { nav.debugRowCounts }
    var debugSelectedIndex: Int? { nav.debugSelectedIndex }
    func debugClickRow(_ index: Int) { nav.debugClickRow(index) }
    var debugHeaders: [String] { nav.debugHeaders }
    #endif
}
