// Grand Line - native macOS app.
//
// What Poneglyph's sidebar filters by: **All credentials**, the **Kinds** (a
// login, a 2FA code, a secure note) and the **Collections** (one per
// `CredentialCategory`). The rows themselves are the hero column's
// (`CredentialVaultController.adoptHeroColumn`), each carrying its own count.
//
// **The counts are the reason this is navigation and not a filter.** Each row
// reports how many credentials match *that* collection under the current
// search, so the column answers "where is the thing I am looking for" rather
// than only "what may I filter by".
//
// **Deliberately not ported from the reference:** its `Favorites` and
// `Recently deleted` rows. Neither has anything behind it - `VaultCredential`
// has no favourite flag and the store has no soft delete - so both would be
// nav rows that filter to nothing. Its `Vault storage` footer is out for the
// same reason: this vault reports no size or quota, and a progress bar with an
// invented percentage would be worse than no progress bar.
//
// P-03 of the 2026-11-25 review removed the plain `HelmPageSidebar` column
// this file used to build for the floating bar. What stays is the only thing
// that was ever vault-specific: the selection type, and the mapping between a
// selection and its row id.

import Foundation

enum CredentialVaultSidebar {

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
        /// *and* have 2FA, and the column counts it under both, which is
        /// what the mockup shows (7 credentials, 4 logins, 3 with 2FA).
        case twoFactor

        /// Whether a credential belongs in this collection. The page's own
        /// filter calls this, so the row counts and the table can never
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

    static let allRowID = "all"

    /// Every selection the column can show, in row order - the one list both
    /// the counts and the row-id mapping walk, so a row can never exist
    /// without a count or a count without a row.
    static var allSelections: [Selection] {
        [.all, .kind(.login), .twoFactor, .kind(.secureNote)]
            + CredentialCategory.allCases.map { Selection.category($0) }
    }

    /// Row ids are namespaced by axis (`kind:`, `category:`) because a
    /// category and a kind could otherwise collide on a raw value - and a
    /// collision here would silently filter the table by the wrong axis.
    static func rowID(for selection: Selection) -> String {
        switch selection {
        case .all: return allRowID
        case .category(let category): return "category:\(category.rawValue)"
        case .kind(let kind): return "kind:\(kind.rawValue)"
        case .twoFactor: return "kind:two-factor"
        }
    }
}
