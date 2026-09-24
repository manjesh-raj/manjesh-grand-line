// Grand Line - native macOS app.
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

    /// Which collection is showing.
    ///
    /// F16 widened this from `CredentialCategory?` to an enum, because the
    /// mockup's sidebar filters on two different axes: **Kinds** (what a
    /// credential is - a login, a 2FA code, a secure note) over
    /// **Collections** (what it is about). A single optional category could
    /// only ever express the second. `.all` is the no-filter state the old
    /// `nil` was.
    enum Selection: Equatable {
        case all
        case category(CredentialCategory)
        case kind(CredentialKind)
        /// Not a `CredentialKind` - "has a second factor" is a property of a
        /// login, not a third kind of thing. A credential can be a login
        /// *and* have 2FA, and the sidebar counts it under both, which is
        /// what the mockup shows (7 credentials, 4 logins, 3 with 2FA).
        case twoFactor

        /// Whether a credential belongs in this collection. The page's own
        /// filter calls this, so the row counts and the list can never
        /// disagree about what a row means.
        func includes(_ credential: VaultCredential) -> Bool {
            switch self {
            case .all: return true
            case .category(let category): return credential.category == category
            case .kind(let kind): return credential.kind == kind
            case .twoFactor: return credential.totp != nil
            }
        }
    }

    static let width: CGFloat = HelmPageSidebar.width

    var onSelect: ((Selection) -> Void)?

    private(set) var selection: Selection

    private let nav = HelmPageSidebar()

    // MARK: Build

    override init(frame frameRect: NSRect) {
        selection = .all
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
        // F16's second axis. Logins, then 2FA, then notes - the mockup's own
        // order, which is also frequency order.
        nav.appendHeader("Kinds")
        nav.appendRow(id: Self.rowID(for: .kind(.login)), symbol: CredentialKind.login.symbol,
                      title: CredentialKind.login.pluralTitle)
        nav.appendRow(id: Self.rowID(for: .twoFactor), symbol: "clock.fill", title: "2FA codes")
        nav.appendRow(id: Self.rowID(for: .kind(.secureNote)), symbol: CredentialKind.secureNote.symbol,
                      title: CredentialKind.secureNote.pluralTitle)
        nav.appendSpacer()
        nav.appendHeader("Collections")
        for category in CredentialCategory.allCases {
            nav.appendRow(id: Self.rowID(for: .category(category)), symbol: category.symbol, title: category.title)
        }
        nav.select(Self.allRowID)

        nav.onSelect = { [weak self] id in
            guard let self else { return }
            let selection = Self.selection(forRowID: id)
            self.selection = selection
            self.onSelect?(selection)
        }
    }

    // MARK: Selection and counts

    static let allRowID = "all"

    /// Every selection this sidebar can show, in row order - the one list
    /// both `setCounts` and the row-id mapping walk, so a row can never
    /// exist without a count or a count without a row.
    static var allSelections: [Selection] {
        [.all, .kind(.login), .twoFactor, .kind(.secureNote)]
            + CredentialCategory.allCases.map { Selection.category($0) }
    }

    /// Row ids are namespaced by axis (`kind:`, `category:`) because a
    /// category and a kind could otherwise collide on a raw value - and a
    /// collision here would silently filter the list by the wrong axis.
    static func rowID(for selection: Selection) -> String {
        switch selection {
        case .all: return allRowID
        case .category(let category): return "category:\(category.rawValue)"
        case .kind(let kind): return "kind:\(kind.rawValue)"
        case .twoFactor: return "kind:two-factor"
        }
    }

    private static func selection(forRowID id: String) -> Selection {
        allSelections.first { rowID(for: $0) == id } ?? .all
    }

    /// Move the selection without firing `onSelect` - what a caller restoring
    /// state wants, and the same split `HelmSegmentedTabs.select(_:)` draws.
    func select(_ selection: Selection) {
        self.selection = selection
        nav.select(Self.rowID(for: selection))
    }

    /// One count per row, computed by the page against the *current* search
    /// - so the sidebar says where the matches are rather than only what
    /// exists. Handed the already-filtered set rather than the store, since
    /// this view never touches one.
    func setCounts(matching credentials: [VaultCredential]) {
        var byID: [String: Int] = [:]
        for selection in Self.allSelections {
            byID[Self.rowID(for: selection)] = credentials.filter(selection.includes).count
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
