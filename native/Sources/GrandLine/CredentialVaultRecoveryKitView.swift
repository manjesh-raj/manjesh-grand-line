// Grand Line - native macOS app.
//
// F17's printable card: the one view that is drawn for *paper* rather than
// for a screen.
//
// **This is the app's first print view, so its conventions are set here.**
// It is a plain `NSView` sized to a US Letter page's printable area, drawn
// with explicit black-on-white colours and no theme at all - which is the
// single most important thing about it. Every other view in this app asks
// `HelmTheme`, and a themed view sent to a printer under Dusk prints a
// near-black rectangle: the captain would burn a toner cartridge on a card
// they then could not read. So this view deliberately does **not** observe
// `ThemeManager` and deliberately does not use a `HelmTint`.
//
// It is also what "Save as PDF" renders (`dataWithPDF(inside:)`), so the
// printed page and the saved file cannot drift.
//
// **Nothing on this card identifies the vault beyond its own file name.** No
// account list, no titles, no hostname - a recovery key taped inside a
// filing cabinet should not also be an inventory of what it opens.

import AppKit

final class CredentialVaultRecoveryKitView: NSView {

    /// US Letter at 72dpi, less a 54pt (0.75in) margin on each side - which
    /// is inside every desktop printer's unprintable border, so nothing is
    /// clipped.
    static let pageSize = NSSize(width: 612, height: 792)
    static let margin: CGFloat = 54

    private let code: String
    private let createdAt: Date
    private let vaultFileName: String

    init(code: String, createdAt: Date, vaultFileName: String) {
        self.code = code
        self.createdAt = createdAt
        self.vaultFileName = vaultFileName
        super.init(frame: NSRect(origin: .zero, size: Self.pageSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Top-down, like a page.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        let ink = NSColor.black
        let muted = NSColor(white: 0.35, alpha: 1)
        var y = Self.margin

        func draw(_ text: String, font: NSFont, color: NSColor, spacingAfter: CGFloat, kern: CGFloat = 0) {
            // kern-exempt: this view draws for paper, not for chrome - see
            // the file header. `HelmType.kickerKern` is a chrome value that
            // scales with the captain's UI text setting, which must not
            // change what comes out of a printer.
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]  // kern-exempt: paper
            let string = NSAttributedString(string: text, attributes: attributes)
            let width = Self.pageSize.width - Self.margin * 2
            let rect = NSRect(x: Self.margin, y: y, width: width, height: 400)
            let bounding = string.boundingRect(with: NSSize(width: width, height: 400),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
            string.draw(with: NSRect(x: rect.minX, y: rect.minY, width: width, height: bounding.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += bounding.height + spacingAfter
        }

        draw("GRAND LINE \u{00B7} RECOVERY KEY", font: .systemFont(ofSize: 11, weight: .heavy),
             color: muted, spacingAfter: 6, kern: 1.6)
        draw("Poneglyph credential vault", font: .systemFont(ofSize: 22, weight: .semibold),
             color: ink, spacingAfter: 22)

        // The code itself, in a boxed monospace block: two rows of four
        // groups, which is what fits at a size that is comfortable to
        // transcribe by hand.
        let groups = code.components(separatedBy: " \u{00B7} ")
        let half = max(1, (groups.count + 1) / 2)
        let lines = [groups.prefix(half).joined(separator: "  "),
                     groups.dropFirst(half).joined(separator: "  ")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let codeFont = NSFont.monospacedSystemFont(ofSize: 20, weight: .medium)
        let codeString = NSAttributedString(string: lines, attributes: [
            .font: codeFont,
            .foregroundColor: ink,
            // kern-exempt: 2.2pt between characters of a 20pt monospaced
            // recovery code, so a human transcribing it off paper does not
            // lose their place. Not a kicker.
            .kern: 2.2,  // kern-exempt: paper
        ])
        let codeBounding = codeString.boundingRect(
            with: NSSize(width: Self.pageSize.width - Self.margin * 2 - 36, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let box = NSRect(x: Self.margin, y: y,
                         width: Self.pageSize.width - Self.margin * 2,
                         height: codeBounding.height + 36)
        let boxPath = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        boxPath.lineWidth = 1.5
        boxPath.setLineDash([6, 4], count: 2, phase: 0)
        ink.setStroke()
        boxPath.stroke()
        codeString.draw(with: NSRect(x: box.minX + 18, y: box.minY + 18,
                                     width: box.width - 36, height: codeBounding.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        y = box.maxY + 20

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        draw("Vault \(vaultFileName) \u{00B7} key created \(formatter.string(from: createdAt)). "
             + "This key unlocks that file and nothing else.",
             font: .systemFont(ofSize: 11), color: muted, spacingAfter: 26)

        draw("What this is", font: .systemFont(ofSize: 13, weight: .semibold), color: ink, spacingAfter: 6)
        draw("""
        A second way into your Poneglyph vault. It is a second wrap of the vault's encryption key, \
        not a copy of your master password - typing it opens the same vault, and Grand Line will then \
        ask you to choose a new master password.

        Grand Line showed this key once and stored nothing about it: not on this Mac, not in your \
        Keychain, and not in the encrypted vault file that syncs to git. If you lose this sheet and \
        forget your master password, nobody - including Grand Line - can open the vault.

        Changing your master password replaces the vault key, so this sheet stops working the moment \
        you do. Print a new one from Poneglyph's Recovery & import sheet when that happens.
        """, font: .systemFont(ofSize: 11.5), color: ink, spacingAfter: 26)

        draw("Where to keep it", font: .systemFont(ofSize: 13, weight: .semibold), color: ink, spacingAfter: 6)
        draw("""
        Somewhere physical: a safe, a locked drawer, a sealed envelope with your other documents. \
        Anyone holding this sheet can open the vault, so do not photograph it, do not put it in \
        another password manager, and do not store it on the same Mac as the vault.
        """, font: .systemFont(ofSize: 11.5), color: ink, spacingAfter: 0)
    }

    // MARK: Output

    /// The page as PDF bytes - what "Save as PDF" writes, and what the print
    /// operation rasterises. One renderer for both, so the two cannot drift.
    func pdfData() -> Data { dataWithPDF(inside: bounds) }

    /// Run the standard print panel over this card.
    ///
    /// `NSPrintOperation` needs the view in a window to run modally for one,
    /// which a freshly-built card is not - so the caller passes the window
    /// to sheet from, and the operation gets its own `NSPrintInfo` sized to
    /// this page rather than inheriting whatever the app last printed.
    func runPrintOperation(in window: NSWindow?) {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.paperSize = Self.pageSize
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let operation = NSPrintOperation(view: self, printInfo: info)
        operation.jobTitle = "Grand Line recovery key"
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
