// Grand Line - native macOS app.
//
// What one credential row says and does, before `CredentialVaultTable.swift`'s
// cells and `HelmDataTable` draw it.
//
// `CredentialVaultController.row(for:)` builds one of these per credential and
// `renderTable()` turns it into the table's row: the name cell's two lines,
// the row controls (`CredentialRowControls`) and the row's menu. Keeping the
// reading in one value is what stops the name cell, the controls and the menu
// from disagreeing about a credential, for example about whether its value is
// on screen.
//
// **Where a revealed value is drawn, and why there.** On the name cell's
// second line, in the code face, in place of the account line. The row has a
// fixed height, so a third line is not available without making every row
// taller for the one that is revealed, and the switch to a monospace line is
// itself the signal that what is on screen now is the secret rather than a
// description of it. The title still names the credential, so nothing a
// captain scans by is lost.

import AppKit

// MARK: - Pasteboard

/// The credential table's own drag payload for a reorder: a credential id,
/// nothing else.
///
/// A private type rather than `.string`, matching `ShiftBoardPasteboard`'s own
/// reasoning: a drag from anywhere else in the app (or from another app) can
/// never be mistaken for a credential and dropped into the table.
enum CredentialVaultDragPasteboard {
    static let credentialType = NSPasteboard.PasteboardType("com.manjesh.grandline.vault.credential-id")

    static func item(credentialID: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(credentialID, forType: credentialType)
        return item
    }

    static func credentialID(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: credentialType)
    }
}

// MARK: - The row

struct CredentialRowModel {

    /// One entry in a row's menu.
    struct Action {
        let title: String
        let symbol: String?
        let run: () -> Void

        init(title: String, symbol: String? = nil, run: @escaping () -> Void) {
            self.title = title
            self.symbol = symbol
            self.run = run
        }
    }

    let title: String
    /// The name cell's second line: the account and when it was last used,
    /// a secure note's length, or the revealed value itself.
    let meta: String
    /// Whether `meta` is the revealed value, drawn in the code face.
    let metaIsCode: Bool
    /// The name cell's glyph: the category's, or a secure note's own.
    let symbol: String
    /// Whether the value is on screen for this row, which flips the Reveal
    /// button's glyph.
    let isRevealed: Bool
    /// Whether the credential asks for Touch ID before its value is shown,
    /// drawn as a glyph at the head of the row controls.
    let requiresTouchID: Bool
    /// Toggle the value on this row. Never copies. `nil` for a secure note.
    var reveal: (() -> Void)?
    /// Copy the value. Never reveals. `nil` for a secure note.
    var copy: (() -> Void)?
    /// The row's menu, in order.
    var overflow: [Action] = []
}
