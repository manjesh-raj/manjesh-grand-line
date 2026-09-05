// Manjesh Grand Line - native macOS app.
//
// The Sticky Board's canvas + note card views. Real AppKit event handling for
// drag-to-reposition - no web content, no gesture recognizer, matching the
// "no `NSClickGestureRecognizer` on an ancestor competing with a real
// control inside it" hazard AGENTS.md's AppKit gotcha catalogue calls out
// repeatedly. See `StickyBoardMetrics` for why plain `frame` positioning (not
// Auto Layout) is the right shape for a freeform, draggable surface, and this
// file's own drag-mechanics note below for why the drag handle is scoped to
// the note's header row rather than the whole card.

import AppKit

enum StickyBoardMetrics {
    /// A fixed, generous canvas - large enough to drag notes around and to
    /// scroll, without the "how big is an infinite canvas" question an
    /// Excalidraw-style surface has to answer. New notes cascade within this;
    /// a dragged note is clamped to stay inside it (see
    /// `StickyBoardCanvasView.clamp(_:)`).
    static let canvasSize = CGSize(width: 2200, height: 1500)
    static let noteSize = CGSize(width: 190, height: 172)
    static let noteMargin: CGFloat = 28
    static let noteCascadeStep: CGFloat = 26
}

/// The board's document view - a fixed-size, non-Auto-Layout canvas holding
/// every `StickyNoteView` at a plain `frame` position (not a constraint), for
/// the same reason `StickyNoteView` itself is frame-positioned: freeform
/// drag-anywhere positioning and Auto Layout constraints do not mix (this
/// codebase has shipped real window-size-cap bugs from exactly that
/// combination - AGENTS.md's AppKit gotcha catalogue, items (11)/(13)).
///
/// A flipped view (y grows downward, matching every persisted `StickyNote.y`
/// and the reference mockup's own top/left CSS positioning model, same idea
/// as this app's own `FlippedView` - which is `final`, so this repeats its
/// one-line override rather than subclassing it) drawing a dotted grid in
/// its own layer - the "cleaner" reference mockup's board look, never the
/// first "detective corkboard" mockup's wood grain/pushpins/string, which was
/// inspiration only.
final class StickyBoardCanvasView: NSView {
    override var isFlipped: Bool { true }

    private var dotColor: NSColor = .lightGray {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        dotColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)
    }

    /// A plain dotted grid, drawn once per `needsDisplay` - cheap (a handful
    /// of `NSBezierPath.fill` calls per visible tile-sized region) and needs
    /// no per-theme asset.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let spacing: CGFloat = 24
        let dotSize: CGFloat = 1.6
        dotColor.setFill()
        var y = spacing - (spacing.truncatingRemainder(dividingBy: spacing))
        while y < dirtyRect.maxY {
            if y >= dirtyRect.minY - spacing {
                var x = spacing - (spacing.truncatingRemainder(dividingBy: spacing))
                while x < dirtyRect.maxX {
                    if x >= dirtyRect.minX - spacing {
                        let dot = NSRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                        NSBezierPath(ovalIn: dot).fill()
                    }
                    x += spacing
                }
            }
            y += spacing
        }
    }

    /// Keeps a dragged note's top-left inside the fixed canvas - the whole
    /// reason the canvas is a fixed size rather than genuinely infinite (v1
    /// scope; see `StickyBoardController.swift`'s header).
    func clamp(_ point: CGPoint) -> CGPoint {
        let maxX = max(0, StickyBoardMetrics.canvasSize.width - StickyBoardMetrics.noteSize.width)
        let maxY = max(0, StickyBoardMetrics.canvasSize.height - StickyBoardMetrics.noteSize.height)
        return CGPoint(x: min(max(0, point.x), maxX), y: min(max(0, point.y), maxY))
    }
}

/// The note card's header row - the drag handle. Deliberately the ONLY
/// draggable region of a note: scoping the drag to this narrow strip (rather
/// than the whole card, or hijacking the body `NSTextView`'s own
/// `mouseDown`) is what lets a click inside the text body still place a
/// caret and start editing normally, with no ambiguity about which gesture
/// the captain meant. A minimum-movement threshold (mirroring
/// `CockpitTerminalView.localSelectionDragThreshold`'s own documented fix for
/// exactly this class of bug - AGENTS.md's "no minimum-movement threshold"
/// gotcha) is what stops an ordinary click-to-select-this-note from being
/// read as a drag on the first sub-pixel of trackpad jitter.
final class StickyNoteHeaderView: NSView {
    /// Called with the new top-left origin (already clamped by the canvas)
    /// on every drag update past the threshold.
    var onDragUpdate: ((CGPoint) -> Void)?
    /// Called once, when a genuine drag (past the threshold) ends.
    var onDragEnd: (() -> Void)?

    private static let dragThreshold: CGFloat = 3
    private var pressLocation: CGPoint = .zero
    private var originAtPress: CGPoint = .zero
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
        originAtPress = superview?.frame.origin ?? .zero
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let note = superview else { return }
        let now = event.locationInWindow
        let dx = now.x - pressLocation.x
        // AppKit's window coordinate space has y growing upward; the canvas
        // (and every persisted position) is flipped, y growing downward - so
        // a positive on-screen upward drag (positive window dy) must SUBTRACT
        // from the note's flipped y, not add.
        let dy = now.y - pressLocation.y
        if !isDragging {
            guard abs(dx) > Self.dragThreshold || abs(dy) > Self.dragThreshold else { return }
            isDragging = true
        }
        let proposed = CGPoint(x: originAtPress.x + dx, y: originAtPress.y - dy)
        let clamped = (note.superview as? StickyBoardCanvasView)?.clamp(proposed) ?? proposed
        note.setFrameOrigin(clamped)
        onDragUpdate?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging { onDragEnd?() }
        isDragging = false
    }
}

/// One sticky note card: a fixed paper color, a slight fixed rotation, a
/// header (timestamp + "\u{2022}\u{2022}\u{2022}" overflow menu) that doubles
/// as the drag handle, and an editable plain-text body.
final class StickyNoteView: NSView {
    let noteID: String
    private var color: StickyNoteColor

    private let header = StickyNoteHeaderView()
    private let timestampLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton(title: "\u{2022}\u{2022}\u{2022}", target: nil, action: nil)
    private let textView: NSTextView
    private let textScroll = NSScrollView()

    var onTextChanged: ((String) -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    var onDeleteRequested: (() -> Void)?

    init(note: StickyNote) {
        self.noteID = note.id
        self.color = note.color
        let container = NSTextContainer(size: NSSize(width: StickyBoardMetrics.noteSize.width - 16, height: .greatestFiniteMagnitude))
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: NSRect(origin: CGPoint(x: note.x, y: note.y), size: StickyBoardMetrics.noteSize))

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowColor = NSColor.black.cgColor

        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        addSubview(header)

        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        header.addSubview(timestampLabel)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.isBordered = false
        menuButton.font = .systemFont(ofSize: 13, weight: .bold)
        menuButton.target = self
        menuButton.action = #selector(overflowClicked(_:))
        header.addSubview(menuButton)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),

            timestampLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            timestampLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            menuButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            menuButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.hasVerticalScroller = false
        textScroll.hasHorizontalScroller = false
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        addSubview(textScroll)
        NSLayoutConstraint.activate([
            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        textView.string = note.text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.delegate = self
        // Every app-owned `NSTextView` paints its own selection through this
        // - left to AppKit, a selection paints the system highlight behind
        // whatever foreground the text already had, which is unbounded
        // (`HelmSelection.apply`'s own doc comment). The pair it sets is
        // self-consistent (background + foreground together), so it stays
        // legible regardless of which literal paper color sits underneath.
        HelmSelection.apply(to: textView)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        container.widthTracksTextView = true
        textScroll.documentView = textView

        // The header already moves this card's own `frame` directly on every
        // drag update (see `StickyNoteHeaderView.mouseDragged`) - that is
        // purely visual and needs no store write. Only the drag's END is
        // persisted, so dragging a note across the board costs one YAML
        // write and one debounced git commit, not dozens.
        header.onDragEnd = { [weak self] in
            guard let self else { return }
            self.onMoved?(self.frame.origin)
        }

        applyColor()
        applyRotation(note.rotationDegrees)
        applyRelativeTimestamp(note.createdAt)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func applyColor() {
        layer?.backgroundColor = HelmTheme.nsColor(color.paperHex).cgColor
        let ink = HelmTheme.nsColor(color.inkHex)
        timestampLabel.textColor = ink
        textView.textColor = ink
        textView.insertionPointColor = ink
        menuButton.attributedTitle = NSAttributedString(
            string: "\u{2022}\u{2022}\u{2022}",
            attributes: [.foregroundColor: ink, .font: NSFont.systemFont(ofSize: 13, weight: .bold)])
    }

    /// A small fixed tilt, applied once at construction from the note's own
    /// persisted rotation (never re-randomized) - `layer.transform` rotates
    /// around the layer's anchor point (0.5, 0.5 by default, i.e. the card's
    /// own center), and does not affect `frame`/`bounds`, so drag math stays
    /// a plain `frame.origin` update regardless.
    private func applyRotation(_ degrees: Double) {
        let radians = degrees * .pi / 180
        layer?.transform = CATransform3DMakeRotation(CGFloat(radians), 0, 0, 1)
    }

    private func applyRelativeTimestamp(_ date: Date) {
        timestampLabel.stringValue = Self.relativeLabel(for: date)
    }

    /// "Today" / "Yesterday" / a short date - matching the reference
    /// mockup's own header label, computed fresh rather than persisted (a
    /// note created "Today" should read "Yesterday" once the calendar day
    /// rolls over).
    static func relativeLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    @objc private func overflowClicked(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Delete Note", action: #selector(deleteClicked), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.width, y: sender.bounds.height), in: sender)
    }

    @objc private func deleteClicked() {
        onDeleteRequested?()
    }

    /// So a freshly created note can be focused for immediate typing
    /// (`StickyBoardController.newNoteTapped`).
    var textViewForFocus: NSTextView { textView }

    #if FM_SELFTESTS
    var debugHeader: StickyNoteHeaderView { header }
    var debugTextView: NSTextView { textView }
    var debugTimestampText: String { timestampLabel.stringValue }
    #endif
}

extension StickyNoteView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        onTextChanged?(textView.string)
    }
}
