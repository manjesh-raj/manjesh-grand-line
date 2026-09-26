// Grand Line - native macOS app.
//
// "Put the captain's clipboard back exactly as it was", as one value.
//
// Written for the snippet expander (B20), which borrows `NSPasteboard.general`
// for the length of one synthetic ⌘V and has to hand it back. It used to hand
// back `string(forType: .string)` alone, so expanding `;sig` over a copied
// image, a copied file, a formatted run of RTF or a URL with its title
// destroyed all of it - the clipboard came back as a plain-text shadow of
// itself, or empty.
//
// **Why the data is copied rather than the items retained.** An
// `NSPasteboardItem` belongs to the pasteboard that owns it, and
// `clearContents()` invalidates it - a retained item reads back nil for every
// type afterwards. So every type's bytes are read out at snapshot time. That
// is also why this is not free: it is one borrow of the clipboard, not a
// history, and nothing here caches.
//
// **Promised (lazy) data is not captured.** An app can put a type on the
// pasteboard as a promise it fulfils only when someone asks, and asking is
// what `data(forType:)` does - which would make taking a snapshot expensive
// and, for a promise whose owner has since quit, impossible. A type whose
// data reads back nil is simply dropped, so a snapshot is a best-effort
// restore of what was really there rather than a claim to be lossless.

import AppKit

/// Every item on a pasteboard, with every type's bytes, ready to be written
/// back.
struct PasteboardSnapshot {

    /// One item: its types, in the pasteboard's own preference order, mapped
    /// to their bytes.
    private let items: [[NSPasteboard.PasteboardType: Data]]

    /// True when there was genuinely nothing to keep.
    var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    /// Reads `pasteboard` in full. Never asks about a type it was not offered.
    static func take(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let captured: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? [])
            .map { item in
                var byType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard let data = item.data(forType: type) else { continue }
                    byType[type] = data
                }
                return byType
            }
        return PasteboardSnapshot(items: captured)
    }

    /// Writes it back, replacing whatever is there.
    ///
    /// An empty snapshot still clears: "the clipboard was empty" is a state
    /// the captain can be in, and leaving the expansion behind instead would
    /// be the one outcome this whole type exists to avoid.
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let rebuilt: [NSPasteboardItem] = items.compactMap { byType in
            guard !byType.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in byType { item.setData(data, forType: type) }
            return item
        }
        guard !rebuilt.isEmpty else { return }
        pasteboard.writeObjects(rebuilt)
    }
}
