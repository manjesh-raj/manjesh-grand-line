// Grand Line - native macOS app.
//
// `CredentialVaultController`'s floating-bar presentation (R2-ARCH-04): the grouped credential list the floating bar draws, where the sidebar layout draws the credential table.
//
// The floating bar is the classic layout, frozen by R2-ARCH-01: it gets
// fixes but no new features and no page redesigns. So the members only its
// presentation uses live here, moved verbatim out of `CredentialVaultController.swift`, and
// that file carries the presentation the sidebar layout draws. A member both
// layouts use stays there. Swift's `private` is file-scoped, so the few
// members this file and the main one share lost `private`; treat this pair
// as one type's private parts (GL-36). `ClassicPresentationSelfTest` fails if
// one of these members moves back.

import AppKit

extension CredentialVaultController {

    func renderList() {
        let matching = filteredCredentials()
        guard !matching.isEmpty else {
            let hasAny = !store.credentials.isEmpty
            list.setItems([.empty(
                symbol: hasAny ? "magnifyingglass" : "lock.shield",
                title: hasAny ? "No matches" : "Your vault is empty",
                body: hasAny
                    ? "Nothing here matches that search or category. Try a different one."
                    : "Add your first credential and it will be encrypted, backed up to your private config repo, and one click from your clipboard."
            )])
            return
        }

        // Grouped by category, in the enum's own order - which is the mockup's
        // order, and stable regardless of what the captain has stored.
        // Within a group, `VaultCredential.displayOrder` - the captain's own
        // manual position, not alphabetical - is the default: "I should be
        // able to sort anything irrespective of whether it's created first or
        // last."
        var items: [CredentialVaultListSection.Item] = []
        for category in CredentialCategory.allCases {
            let inCategory = matching.filter { $0.category == category }
                .sorted(by: VaultCredential.displayOrder)
            guard !inCategory.isEmpty else { continue }
            items.append(.group("\(category.title) \u{00B7} \(inCategory.count)"))
            items.append(contentsOf: inCategory.map(row(for:)))
        }
        list.setItems(items, selecting: selectedID)
    }
}
