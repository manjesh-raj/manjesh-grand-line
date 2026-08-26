// Manjesh Grand Line - native macOS app.
//
// One tab in the console's dynamic tab bar. A rounded chip with an editable name
// label and a close button. Interaction (design report A4/A5):
//
//   - single click  -> select the tab
//   - double click  -> rename it inline (the label becomes an editable field)
//   - right click    -> Rename / Duplicate / Close menu
//   - the "×" button -> close the tab
//
// The chip is a dumb view: every action is handed back to `ConsoleController`
// through a closure, so the chip knows nothing about the tab collection. The
// controller owns naming, selection, duplication, and closing.

import AppKit

/// A single tab chip. Selection, rename, duplicate, and close are delivered to
/// the owner via closures keyed by this chip's `tabID`.
final class TabChipView: NSView, NSTextFieldDelegate {

    let tabID: UUID

    private let label = NSTextField()
    private let closeButton = NSButton()

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDuplicate: (() -> Void)?
    /// Called with the edited text when an inline rename commits.
    var onRename: ((String) -> Void)?

    private(set) var isRenaming = false
    private var nameBeforeRename = ""

    // MARK: Init

    init(tabID: UUID, name: String) {
        self.tabID = tabID
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = name
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.focusRingType = .none
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.delegate = self
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        closeButton.isBordered = false
        // No `bezelStyle` here on purpose: with `isBordered = false` AppKit
        // never consults it for drawing or for layout - measured identical
        // `intrinsicContentSize` and `imageRect` with and without it - so the
        // line this used to carry was dead, and its only remaining effect was
        // to keep this file in the audit's stock-bezel count.
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab (⌘W)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 15),
            closeButton.heightAnchor.constraint(equalToConstant: 15),
        ])

        // GL-16. A chip is the console's own tab selector, and before this it
        // was mouse-only: ⌘1-9 covered the first nine tabs and nothing else
        // reached them. It is now a real focusable control - Tab to it, Return
        // or Space to select, Left/Right to move along the strip - and it
        // announces as a radio button carrying the tab's own name, which is
        // what a tab in a one-of-many strip is.
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        closeButton.setAccessibilityLabel("Close tab")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Accessibility and keyboard (GL-16)

    private var isSelectedChip = false

    override func accessibilityLabel() -> String? { label.stringValue }
    override func accessibilityValue() -> Any? { isSelectedChip ? "selected" : "not selected" }
    /// The close button stays reachable - it is the chip's other real action.
    override func accessibilityChildren() -> [Any]? { [closeButton] }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    override var acceptsFirstResponder: Bool { !isRenaming }
    override var canBecomeKeyView: Bool { !isRenaming && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let inset = min(HelmFocusRing.inset, min(bounds.width, bounds.height) / 4)
        NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 5, yRadius: 5).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard !isRenaming else { super.keyDown(with: event); return }
        switch Int(event.keyCode) {
        case 36, 76, 49:            // Return, keypad Enter, Space
            onSelect?()
        case 123, 126:              // Left, Up
            moveFocusToSiblingChip(by: -1)
        case 124, 125:              // Right, Down
            moveFocusToSiblingChip(by: 1)
        default:
            super.keyDown(with: event)
        }
    }

    /// Walks the chip's own superview for the next `TabChipView` in layout
    /// order. Deliberately not a closure back to `ConsoleController`: the strip
    /// is the view hierarchy, and asking the controller would mean a second,
    /// separately-maintained notion of chip order.
    private func moveFocusToSiblingChip(by step: Int) {
        guard let siblings = superview?.subviews.compactMap({ $0 as? TabChipView }),
              let index = siblings.firstIndex(where: { $0 === self }) else { return }
        let next = index + step
        guard siblings.indices.contains(next) else { return }
        window?.makeFirstResponder(siblings[next])
    }

    // MARK: Public API used by the controller

    /// Update the displayed name (after the controller has canonicalised it).
    func setName(_ name: String) {
        label.stringValue = name
    }

    /// Restyle for the current theme + selection state.
    ///
    /// Daylight §6.13 ("tab chips ... take the Daylight button/well/card
    /// recipes") is a branch, exactly like every other Phase 4 restyle: the
    /// twelve palettes render byte-identically to what they always have.
    /// Under Daylight the chip becomes a capsule and its selected label is
    /// **contrast-corrected against the wash it actually sits on** rather than
    /// painted in the raw hue - a chip's accent can be any host's own
    /// `accentHex`, and the raw-hue-over-a-wash-of-itself pairing is the
    /// audit's §5.7 defect (see `HelmContrast`'s doc comment).
    func applyStyle(selected: Bool, accent: NSColor, muted: NSColor, tint: NSColor) {
        isSelectedChip = selected
        let daylight = ThemeManager.shared.theme.isDaylight
        // A capsule needs the chip's own height, which is 0 before the first
        // layout pass - `layout()` re-derives it once real geometry exists.
        layer?.cornerRadius = daylight ? Self.daylightRadius(forHeight: bounds.height) : 7
        layer?.backgroundColor = (selected ? tint : .clear).cgColor
        let selectedInk = daylight ? HelmContrast.legible(accent, over: tint) : accent
        if !isRenaming {
            label.textColor = selected ? selectedInk : muted
            let size = HelmType.scaled(13)
            label.font = daylight
                ? HelmType.rounded(size, selected ? .semibold : .medium)
                : .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        }
        closeButton.contentTintColor = selected ? selectedInk : muted
    }

    /// A capsule's real radius for a chip of `height` - falling back to the
    /// chip's own resolved content height before its first layout pass.
    private static func daylightRadius(forHeight height: CGFloat) -> CGFloat {
        HelmMetrics.capsuleRadius(forHeight: height > 0 ? height : 28)
    }

    /// Keeps the Daylight capsule a capsule across a resize. A no-op in the
    /// twelve palettes, where the radius is a constant.
    override func layout() {
        super.layout()
        guard ThemeManager.shared.theme.isDaylight else { return }
        layer?.cornerRadius = Self.daylightRadius(forHeight: bounds.height)
    }

    /// Start an inline rename (also reachable by double-click and the menu).
    func beginRename() {
        guard !isRenaming else { return }
        isRenaming = true
        nameBeforeRename = label.stringValue

        label.isEditable = true
        label.isSelectable = true
        label.isBordered = true
        label.bezelStyle = .roundedBezel
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.textColor = .labelColor
        // Fix 9 (fixes4): `selectText(nil)` alone already makes an editable
        // field first responder and starts its editing session. Calling
        // `window.makeFirstResponder(label)` first (as this used to) makes
        // AppKit think a session is already active and needs ending before
        // `selectText` can start its own - which fires a spurious
        // `controlTextDidEndEditing` with the *pre-edit* text right here,
        // permanently flipping `isRenaming` false before the user types a
        // single character. The real commit later (Return) then hits the
        // `guard isRenaming` in `endRename` and is silently dropped - the
        // rename UI looks like it worked, but the typed name never lands.
        label.selectText(nil)
    }

    // MARK: Mouse routing

    // Route clicks that land on the chip (but not the close button, and not while
    // renaming) to the chip itself, so the label - a plain NSTextField - never
    // swallows a select/double-click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isRenaming { return super.hitTest(point) }
        guard let local = superview.map({ convert(point, from: $0) }) else {
            return super.hitTest(point)
        }
        if !closeButton.isHidden, closeButton.frame.contains(local) {
            return closeButton
        }
        if bounds.contains(local) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            beginRename()
        } else {
            onSelect?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename", action: #selector(renameFromMenu), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let duplicate = NSMenuItem(title: "Duplicate", action: #selector(duplicateFromMenu), keyEquivalent: "")
        duplicate.target = self
        menu.addItem(duplicate)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close", action: #selector(closeClicked), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameFromMenu() { beginRename() }
    @objc private func duplicateFromMenu() { onDuplicate?() }
    @objc private func closeClicked() { onClose?() }

    // MARK: NSTextFieldDelegate (inline rename lifecycle)

    func controlTextDidEndEditing(_ obj: Notification) {
        endRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            label.stringValue = nameBeforeRename
            endRename(commit: false)
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func endRename(commit: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        let edited = label.stringValue

        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.backgroundColor = .clear

        if commit {
            onRename?(edited)
        }
    }
}
