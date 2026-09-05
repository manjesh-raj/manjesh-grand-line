// Manjesh Grand Line - native macOS app.
//
// The Sticky Board's canvas + note card views. Real AppKit event handling for
// drag-to-reposition and drag-to-resize - no web content, no gesture
// recognizer, matching the
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
    /// The size a brand-new note starts at. No longer the size every note
    /// *is*: a note carries its own persisted `width`/`height` since
    /// `fm/grandline-sticky-code-preview-polish`, and the resize handle in
    /// the bottom-right corner is what changes them.
    static let noteSize = CGSize(width: 200, height: 196)
    static let noteMargin: CGFloat = 28
    static let noteCascadeStep: CGFloat = 26

    /// Resize bounds. The minimum is what still fits the title line, the pin,
    /// the overflow button and one line of body text without clipping; the
    /// maximum keeps one note from becoming the whole board (and keeps
    /// `clamp(_:)`'s arithmetic meaningful).
    static let minNoteSize = CGSize(width: 150, height: 130)
    static let maxNoteSize = CGSize(width: 620, height: 560)

    static func clampSize(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(minNoteSize.width, size.width), maxNoteSize.width),
               height: min(max(minNoteSize.height, size.height), maxNoteSize.height))
    }
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
/// one-line override rather than subclassing it).
///
/// **The surface is drawn cork, not a photo and not a flat fill**
/// (`fm/grandline-sticky-code-preview-polish`). The captain's reference is a
/// real corkboard, and a flat brown rectangle does not read as one - the
/// grain is what sells it. The technique is a small, tiled, procedurally
/// drawn `NSImage` used as a pattern colour, which the brief explicitly
/// sanctions and which is the only shape that stays cheap here: filling a
/// 2200x1500 canvas by drawing several thousand individual specks on every
/// `draw(_:)` would put real work on the main thread every time a note is
/// dragged over the board, whereas a pattern fill is one `NSRectFill`
/// regardless of canvas size. The tile is built at most once per light/dark
/// mode and cached.
///
/// The speck layout is **seeded, not random**: a fresh `Int.random` per tile
/// would give the board a different grain on every relaunch and, worse, make
/// an off-screen render impossible to compare against a baseline. A tiny
/// deterministic PRNG (see `seededSpecks`) gives the same grain forever.
final class StickyBoardCanvasView: NSView {
    override var isFlipped: Bool { true }

    /// The cork tone follows the app's light/dark **mode**, never the
    /// individual palette - see `StickyBoardModels.swift`'s header for why
    /// this is a deliberate third colour category.
    private var isDarkMode = false
    private var corkBase: NSColor = .brown
    private static var tileCache: [Bool: NSImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func applyTheme(_ theme: HelmTheme) {
        let dark = theme.mode == .dark
        // A theme switch inside the same mode (helm-light -> gruvbox-light)
        // legitimately changes nothing here, so redraw only on a real change.
        let changed = dark != isDarkMode || layer?.backgroundColor == nil
        isDarkMode = dark
        corkBase = HelmTheme.nsColor(StickyBoardCork.baseHex(dark: dark))
        // The layer fill is what shows through anywhere the pattern has not
        // painted yet (the first frame, and the moment a resize outruns a
        // redraw), so it is the cork base rather than a theme token - a flash
        // of page-background grey in the middle of a corkboard reads as a
        // rendering bug.
        layer?.backgroundColor = corkBase.cgColor
        if changed { needsDisplay = true }
    }

    /// The cork itself: a base fill plus a tiled speck pattern.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        corkBase.setFill()
        dirtyRect.fill()
        NSColor(patternImage: Self.tile(dark: isDarkMode)).setFill()
        dirtyRect.fill()
    }

    /// One tile of cork grain, drawn once per mode and cached. Transparent
    /// apart from the specks, so it composites straight over the base fill.
    static func tile(dark: Bool) -> NSImage {
        if let cached = tileCache[dark] { return cached }
        let side: CGFloat = 84
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let darkFleck = HelmTheme.nsColor(StickyBoardCork.fleckDarkHex(dark: dark))
        let lightFleck = HelmTheme.nsColor(StickyBoardCork.fleckLightHex(dark: dark))
        for speck in seededSpecks(side: side) {
            (speck.isDark ? darkFleck : lightFleck).withAlphaComponent(speck.alpha).setFill()
            // Cork's grain is granular rather than circular, so a squashed,
            // rotated oval reads far closer than a dot at the same cost.
            let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: speck.length, height: speck.thickness))
            var transform = AffineTransform(translationByX: speck.x, byY: speck.y)
            transform.rotate(byDegrees: speck.angle)
            path.transform(using: transform)
            path.fill()
        }
        image.unlockFocus()
        tileCache[dark] = image
        return image
    }

    struct Speck {
        let x, y, length, thickness, angle, alpha: CGFloat
        let isDark: Bool
    }

    /// A deterministic speck layout. The generator is a plain 64-bit LCG
    /// seeded with a fixed constant - it needs to be reproducible and
    /// uniform-ish, not cryptographic, and `Int.random` is explicitly the
    /// wrong tool here (`AGENTS.md` records the same reasoning for a note's
    /// own rotation, which is rolled once and then persisted).
    static func seededSpecks(side: CGFloat) -> [Speck] {
        var state: UInt64 = 0x5DEECE66D
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 100_000) / 100_000
        }
        return (0..<170).map { i in
            Speck(x: next() * side,
                  y: next() * side,
                  length: 1.6 + next() * 4.4,
                  thickness: 0.9 + next() * 1.5,
                  angle: next() * 180,
                  alpha: 0.16 + next() * 0.30,
                  isDark: i % 3 != 0)
        }
    }

    /// Keeps a dragged or resized note fully inside the fixed canvas. Takes
    /// the note's own size rather than assuming one: since notes are
    /// resizable, a single shared constant would let a grown note's
    /// bottom-right corner fall off the board.
    func clamp(_ point: CGPoint, size: CGSize = StickyBoardMetrics.noteSize) -> CGPoint {
        let maxX = max(0, StickyBoardMetrics.canvasSize.width - size.width)
        let maxY = max(0, StickyBoardMetrics.canvasSize.height - size.height)
        return CGPoint(x: min(max(0, point.x), maxX), y: min(max(0, point.y), maxY))
    }

    /// The resize counterpart of `clamp(_:size:)`: bounds a proposed size to
    /// the metric limits *and* to whatever room is left between the note's
    /// own origin and the canvas edge.
    func clampSize(_ size: CGSize, at origin: CGPoint) -> CGSize {
        let bounded = StickyBoardMetrics.clampSize(size)
        return CGSize(width: min(bounded.width, max(StickyBoardMetrics.minNoteSize.width,
                                                   StickyBoardMetrics.canvasSize.width - origin.x)),
                      height: min(bounded.height, max(StickyBoardMetrics.minNoteSize.height,
                                                      StickyBoardMetrics.canvasSize.height - origin.y)))
    }
}

/// Shared scaffolding for a sticky note's two handles - the header (move) and
/// the bottom-right grip (resize).
///
/// **Why this exists at all.** Both handles shipped as plain `NSView`s with
/// nothing but raw mouse event handlers: no accessibility markup, no role, no
/// label, and no keyboard path. Everything else about a note was already
/// mouse-free (the title and body are real text controls, and delete is a
/// real menu item on a real `NSButton`), so position and size were the one
/// complete VoiceOver dead end on this page - a captain using the keyboard
/// could write a note and never place it.
///
/// The fix is the two halves AppKit wants for a control like this, and this
/// app's own GL-16 accessibility pass already established both on
/// `HoverHighlightView`:
///
///   - **Keyboard**: the handle takes focus (`acceptsFirstResponder` +
///     `canBecomeKeyView`), shows a real system focus ring rather than
///     `focusRingType = .none` (a view that is a control by role has to show
///     where the keyboard is), and arrow keys nudge it. Shift+arrow takes the
///     larger step, matching how every canvas app treats a nudge.
///   - **VoiceOver**: the handle is a real accessibility element with the
///     `.handle` role, a label naming *which* note it belongs to (a board of
///     eight notes reading "handle" eight times is not an improvement), and
///     four `NSAccessibilityCustomAction`s so the four directions are
///     reachable straight from the rotor without knowing the arrow-key
///     binding exists.
///
/// **Nudges are coalesced before they are persisted**, deliberately, because
/// this file's own rule for the mouse is that only a drag's *end* is written
/// (see `StickyNoteView`'s wiring comment). A held arrow key repeats at
/// roughly 25Hz, and persisting each repeat would turn one gesture into
/// dozens of YAML writes for exactly the reason the mouse path avoids. The
/// visual move happens on every keypress; the write happens once the keypress
/// run stops.
class StickyNoteHandleView: NSView {
    /// The note this handle belongs to, in the words a captain would use -
    /// its title, or a fallback when the note has none yet. Kept current by
    /// `StickyNoteView`, which owns the title field.
    var noteDescription: String = ""

    /// One arrow press. Small enough to place a note precisely, large enough
    /// that crossing the board does not take a hundred presses - which is
    /// what Shift is for.
    static let nudgeStep: CGFloat = 8
    static let coarseNudgeStep: CGFloat = 40

    /// How long a run of keypresses has to stop for before the result is
    /// written. Comfortably longer than the ~40ms key-repeat interval, and
    /// short enough that a captain who nudges once and tabs away has already
    /// been saved by the time they get anywhere.
    static let commitDelay: TimeInterval = 0.35

    private var commitWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // GL-16: a real system focus ring, drawn from this view's own bounds
        // (`drawFocusRingMask`). Without it a keyboard captain can focus a
        // handle and have no idea they have.
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Subclass hooks

    /// Apply one step. `dx`/`dy` are in arrow-key direction terms - right and
    /// **down** positive - which is also the canvas's own flipped coordinate
    /// sense, so no sign flip is needed here (unlike the mouse paths, which
    /// receive unflipped window coordinates).
    /// Returns whether anything actually changed, so a nudge into a wall does
    /// not schedule a pointless write or report success to VoiceOver.
    @discardableResult
    func applyNudge(dx: CGFloat, dy: CGFloat) -> Bool { false }

    /// Persist whatever `applyNudge` has been moving. Called once, after a
    /// run of nudges settles.
    func commitNudges() {}

    /// "Move" / "Resize" - the verb this handle's label and custom actions
    /// are built from.
    var handleVerb: String { "" }

    /// The four rotor actions, in the order VoiceOver will read them.
    var directionalActionNames: [(name: String, dx: CGFloat, dy: CGFloat)] { [] }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        // A run of nudges that ends because focus left is still a finished
        // run - never leave the last one unwritten.
        flushPendingCommit()
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    }

    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? Self.coarseNudgeStep : Self.nudgeStep
        // 123/124/126/125 = left/right/up/down, the four `kVK_*Arrow` codes.
        let delta: (CGFloat, CGFloat)?
        switch event.keyCode {
        case 123: delta = (-step, 0)
        case 124: delta = (step, 0)
        case 126: delta = (0, -step)
        case 125: delta = (0, step)
        default: delta = nil
        }
        guard let delta else {
            super.keyDown(with: event)
            return
        }
        nudgeAndScheduleCommit(dx: delta.0, dy: delta.1)
    }

    /// The one path both the keyboard and the rotor actions go through.
    @discardableResult
    func nudgeAndScheduleCommit(dx: CGFloat, dy: CGFloat) -> Bool {
        let moved = applyNudge(dx: dx, dy: dy)
        guard moved else { return false }
        commitWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.commitWorkItem = nil
            self?.commitNudges()
        }
        commitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commitDelay, execute: work)
        return true
    }

    /// Write immediately rather than waiting out the coalescing delay.
    func flushPendingCommit() {
        guard let pending = commitWorkItem else { return }
        pending.cancel()
        commitWorkItem = nil
        commitNudges()
    }

    // MARK: Accessibility (GL-16)

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .handle }

    override func accessibilityLabel() -> String? {
        noteDescription.isEmpty ? handleVerb : "\(handleVerb) note: \(noteDescription)"
    }

    override func accessibilityHelp() -> String? {
        "Use the arrow keys to \(handleVerb.lowercased()) this note. Hold Shift for a bigger step."
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        directionalActionNames.map { entry in
            NSAccessibilityCustomAction(name: entry.name) { [weak self] in
                guard let self else { return false }
                let moved = self.nudgeAndScheduleCommit(dx: entry.dx, dy: entry.dy)
                // A rotor action is a discrete, deliberate act rather than one
                // repeat of a held key, so there is nothing to coalesce with -
                // write it straight away.
                if moved { self.flushPendingCommit() }
                return moved
            }
        }
    }

    /// Focus follows a real click too, so the keyboard path is discoverable
    /// the moment a captain has dragged a note once - and so a VoiceOver
    /// cursor landing here matches where the keyboard is.
    func takeFocus() {
        window?.makeFirstResponder(self)
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
final class StickyNoteHeaderView: StickyNoteHandleView {
    /// Called with the new top-left origin (already clamped by the canvas)
    /// on every drag update past the threshold.
    var onDragUpdate: ((CGPoint) -> Void)?
    /// Called once, when a genuine drag (past the threshold) ends.
    var onDragEnd: (() -> Void)?

    private static let dragThreshold: CGFloat = 3
    private var pressLocation: CGPoint = .zero
    private var originAtPress: CGPoint = .zero
    private var isDragging = false

    // MARK: Keyboard / VoiceOver (see `StickyNoteHandleView`)

    override var handleVerb: String { "Move" }

    override var directionalActionNames: [(name: String, dx: CGFloat, dy: CGFloat)] {
        let step = Self.nudgeStep
        return [("Move Left", -step, 0), ("Move Right", step, 0),
                ("Move Up", 0, -step), ("Move Down", 0, step)]
    }

    override func applyNudge(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let note = superview else { return false }
        let proposed = CGPoint(x: note.frame.origin.x + dx, y: note.frame.origin.y + dy)
        let clamped = (note.superview as? StickyBoardCanvasView)?
            .clamp(proposed, size: note.frame.size) ?? proposed
        guard clamped != note.frame.origin else { return false }
        note.setFrameOrigin(clamped)
        onDragUpdate?(clamped)
        return true
    }

    override func commitNudges() { onDragEnd?() }

    override func mouseDown(with event: NSEvent) {
        takeFocus()
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
        // Clamp against this note's OWN size: notes are resizable now, so a
        // shared constant would let a grown note's bottom-right corner be
        // dragged off the board.
        let clamped = (note.superview as? StickyBoardCanvasView)?
            .clamp(proposed, size: note.frame.size) ?? proposed
        note.setFrameOrigin(clamped)
        onDragUpdate?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging { onDragEnd?() }
        isDragging = false
    }
}

/// The note's bottom-right resize grip.
///
/// Deliberately its own tiny view rather than a hit-test region inside
/// `StickyNoteView`, for the same reason the drag handle is its own view: a
/// note's body is a live `NSTextView`, and any "was this mousedown near the
/// corner?" test done on the card itself has to reason about which subview
/// would otherwise have taken the event. A real 16x16 view in the corner
/// takes its own mouse events and nothing else changes.
///
/// It carries the same minimum-movement threshold the drag handle does, so a
/// click that merely lands on the corner never writes a (identical) size to
/// the store and never wakes the git debounce.
final class StickyNoteResizeHandleView: StickyNoteHandleView {
    var onResizeUpdate: ((CGSize) -> Void)?
    var onResizeEnd: (() -> Void)?

    static let side: CGFloat = 16
    private static let threshold: CGFloat = 3

    private var pressLocation: CGPoint = .zero
    private var sizeAtPress: CGSize = .zero
    private var isResizing = false
    private var gripColor: NSColor = .darkGray

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Keyboard / VoiceOver (see `StickyNoteHandleView`)

    override var handleVerb: String { "Resize" }

    override var directionalActionNames: [(name: String, dx: CGFloat, dy: CGFloat)] {
        let step = Self.nudgeStep
        return [("Increase Width", step, 0), ("Decrease Width", -step, 0),
                ("Increase Height", 0, step), ("Decrease Height", 0, -step)]
    }

    /// Right/down grow, matching where the grip sits and which way a mouse
    /// drag on it moves.
    override func applyNudge(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let note = superview else { return false }
        let proposed = CGSize(width: note.frame.size.width + dx, height: note.frame.size.height + dy)
        let clamped = (note.superview as? StickyBoardCanvasView)?
            .clampSize(proposed, at: note.frame.origin) ?? StickyBoardMetrics.clampSize(proposed)
        guard clamped != note.frame.size else { return false }
        note.setFrameSize(clamped)
        onResizeUpdate?(clamped)
        return true
    }

    override func commitNudges() { onResizeEnd?() }

    func applyInk(_ ink: NSColor) {
        gripColor = ink.withAlphaComponent(0.45)
        needsDisplay = true
    }

    /// Three short diagonal strokes - the platform's own visual shorthand for
    /// "drag me to resize", drawn rather than an SF Symbol so it inherits the
    /// note's ink and stays legible on all six paper colours.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        gripColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        for inset in [CGFloat(3), 7, 11] {
            path.move(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + inset))
            path.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 3))
        }
        path.stroke()
    }

    override func resetCursorRects() {
        // A real cursor change is most of what makes the affordance
        // discoverable at this size. `.crosshair` rather than a diagonal
        // resize arrow because AppKit exposes no public NW-SE resize cursor -
        // the one macOS itself uses on a window corner is private, and this
        // app's own standing rule is that a private API stays unused however
        // convenient (the same call `HelmButton` records for `NSSwitch`'s
        // private `trackColor`).
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        takeFocus()
        pressLocation = event.locationInWindow
        sizeAtPress = superview?.frame.size ?? .zero
        isResizing = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let note = superview else { return }
        let now = event.locationInWindow
        let dx = now.x - pressLocation.x
        // The canvas is flipped and the window is not, so growing the note
        // downward on screen is a NEGATIVE window dy - the same sign flip the
        // drag handle documents.
        let dy = pressLocation.y - now.y
        if !isResizing {
            guard abs(dx) > Self.threshold || abs(dy) > Self.threshold else { return }
            isResizing = true
        }
        let proposed = CGSize(width: sizeAtPress.width + dx, height: sizeAtPress.height + dy)
        let clamped = (note.superview as? StickyBoardCanvasView)?
            .clampSize(proposed, at: note.frame.origin) ?? StickyBoardMetrics.clampSize(proposed)
        note.setFrameSize(clamped)
        onResizeUpdate?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing { onResizeEnd?() }
        isResizing = false
    }
}

/// One sticky note card, redesigned in `fm/grandline-sticky-code-preview-polish`
/// against the captain's own reference photo of pinned index cards:
///
///   - a small red **pin** at the top (decorative - the note is dragged by its
///     header row, not by the pin, so making the pin the handle would move
///     the affordance somewhere smaller and less discoverable),
///   - an editable **title** line in a bold hand ("IDEA #01", "QUESTION",
///     "CLUE"),
///   - a **handwriting** body face rather than the system font,
///   - and a **resize grip** in the bottom-right corner.
///
/// The header row (timestamp + overflow menu) is still the drag handle, and
/// still the only draggable region - see `StickyNoteHeaderView`.
final class StickyNoteView: NSView {
    let noteID: String
    private var color: StickyNoteColor

    private let pin = NSView()
    private let header = StickyNoteHeaderView()
    private let timestampLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton(title: "\u{2022}\u{2022}\u{2022}", target: nil, action: nil)
    private let titleField = NSTextField(string: "")
    private let textView: NSTextView
    private let textScroll = NSScrollView()
    private let resizeHandle = StickyNoteResizeHandleView()

    var onTitleChanged: ((String) -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    var onResized: ((CGSize) -> Void)?
    var onDeleteRequested: (() -> Void)?
    /// Fired when the title field or the body text view gives up focus - the
    /// store's debounced write flushes on it. See `StickyBoardStore.
    /// persistDebounce`.
    var onEditingEnded: (() -> Void)?

    /// The reference photo's cards are labelled; an unlabelled note should
    /// still say where the label goes rather than hiding the field.
    static let titlePlaceholder = "Title"

    init(note: StickyNote) {
        self.noteID = note.id
        self.color = note.color
        let startSize = StickyBoardMetrics.clampSize(note.size)
        let container = NSTextContainer(size: NSSize(width: startSize.width - 16, height: .greatestFiniteMagnitude))
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: NSRect(origin: CGPoint(x: note.x, y: note.y), size: startSize))

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowColor = NSColor.black.cgColor

        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.wantsLayer = true
        pin.layer?.cornerRadius = Self.pinSide / 2
        // A real pushpin catches light at the top - one inner highlight layer
        // is the whole 3D effect, and costs nothing.
        pin.layer?.borderWidth = 1
        addSubview(pin)

        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        addSubview(header)

        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(timestampLabel)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.isBordered = false
        // Overwritten by `applyColor()`'s `attributedTitle`; set here so the
        // button has a sensible intrinsic width before its first colour pass.
        menuButton.font = .systemFont(ofSize: HelmType.scaled(13), weight: .bold)
        menuButton.target = self
        menuButton.action = #selector(overflowClicked(_:))
        header.addSubview(menuButton)

        // The title is a plain, chrome-less `NSTextField` rather than a
        // `HelmTextField`: this sits on a note's own literal paper colour, so
        // the app's sunken-well recipe (a theme-derived fill and border) would
        // be the one piece of the design system that genuinely does not
        // belong here. `HelmContrastSelfTest.checkNoRawTextInputs` bans the
        // bare `NSTextField()` *initializer*; `NSTextField(string:)` is a
        // different one and is what the app's own label-style fields use.
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.delegate = self
        titleField.stringValue = note.title
        addSubview(titleField)

        NSLayoutConstraint.activate([
            pin.centerXAnchor.constraint(equalTo: centerXAnchor),
            pin.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            pin.widthAnchor.constraint(equalToConstant: Self.pinSide),
            pin.heightAnchor.constraint(equalToConstant: Self.pinSide),

            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),

            timestampLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            timestampLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            menuButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            menuButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 1),
        ])

        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.hasVerticalScroller = false
        textScroll.hasHorizontalScroller = false
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        addSubview(textScroll)

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resizeHandle)

        NSLayoutConstraint.activate([
            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textScroll.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: StickyNoteResizeHandleView.side),
            resizeHandle.heightAnchor.constraint(equalToConstant: StickyNoteResizeHandleView.side),
        ])

        textView.string = note.text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = StickyFont.hand(HelmType.scaled(14))
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
        // write and one debounced git commit, not dozens. The resize grip
        // follows exactly the same rule.
        header.onDragEnd = { [weak self] in
            guard let self else { return }
            self.onMoved?(self.frame.origin)
        }
        resizeHandle.onResizeEnd = { [weak self] in
            guard let self else { return }
            self.onResized?(self.frame.size)
        }

        applyColor()
        applyRotation(note.rotationDegrees)
        applyRelativeTimestamp(note.createdAt)
        refreshHandleDescriptions()
    }

    /// Names *which* note each handle belongs to, so a board of eight notes
    /// does not read as eight identical "handle"s under VoiceOver. The title
    /// is what a captain named the thought; a note that has none yet borrows
    /// the opening of its body rather than announcing nothing.
    private func refreshHandleDescriptions() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let description: String
        if !title.isEmpty {
            description = title
        } else if !body.isEmpty {
            description = String(body.prefix(40))
        } else {
            description = "untitled"
        }
        header.noteDescription = description
        resizeHandle.noteDescription = description
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static let pinSide: CGFloat = 9

    /// The pin is the one thing on a note that is NOT drawn from the note's
    /// own ink: the reference photo's pushpins are red on every card colour,
    /// and a pin tinted to match its paper would disappear into it. It is
    /// purely decorative (it carries no state and takes no clicks), so it has
    /// no contrast obligation of its own - the note's meaning is entirely in
    /// its title and body text.
    private static let pinFill = "D6453F"
    private static let pinEdge = "8E241F"

    private func applyColor() {
        layer?.backgroundColor = HelmTheme.nsColor(color.paperHex).cgColor
        let ink = HelmTheme.nsColor(color.inkHex)
        timestampLabel.textColor = ink
        // GL-32: a raw `.systemFont(ofSize: 10.5, weight: .bold)` here was
        // the one piece of text on this page below the app's own readable
        // floor - `HelmType.chip()` is that exact designed size and weight,
        // routed through `HelmType.scaled` so it is clamped to
        // `HelmType.minimumUIPointSize` (11) and follows the captain's chrome
        // text scale. Set here rather than in `init` so it sits beside the
        // title's own scaled font: this is the one method that re-derives a
        // note's type and colour, so a future live re-theme of a note has a
        // single place to call.
        timestampLabel.font = HelmType.chip()
        titleField.textColor = ink
        titleField.font = StickyFont.handBold(HelmType.scaled(14))
        titleField.placeholderAttributedString = NSAttributedString(
            string: Self.titlePlaceholder,
            attributes: [.font: StickyFont.handBold(HelmType.scaled(14)),
                         .foregroundColor: ink.withAlphaComponent(0.42)])
        textView.textColor = ink
        textView.insertionPointColor = ink
        resizeHandle.applyInk(ink)
        pin.layer?.backgroundColor = HelmTheme.nsColor(Self.pinFill).cgColor
        pin.layer?.borderColor = HelmTheme.nsColor(Self.pinEdge).cgColor
        menuButton.attributedTitle = NSAttributedString(
            string: "\u{2022}\u{2022}\u{2022}",
            attributes: [.foregroundColor: ink,
                         .font: NSFont.systemFont(ofSize: HelmType.scaled(13), weight: .bold)])
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
        return Self.monthDayFormatter.string(from: date)
    }

    // GL-P3: built once. `DateFormatter` construction is measurably
    // expensive and this carries no per-call state - the same treatment
    // `FleetLogFeed`/`HealthCardView` already give theirs.
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

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
    /// (`StickyBoardController.newNoteTapped`). The **title** is what a new
    /// note focuses, matching the reference photo's labelled cards - the
    /// captain names the thought, then writes it.
    var titleFieldForFocus: NSTextField { titleField }
    var textViewForFocus: NSTextView { textView }

    #if FM_SELFTESTS
    var debugHeader: StickyNoteHeaderView { header }
    var debugResizeHandle: StickyNoteResizeHandleView { resizeHandle }
    var debugTextView: NSTextView { textView }
    var debugTitleField: NSTextField { titleField }
    var debugPin: NSView { pin }
    var debugTimestampText: String { timestampLabel.stringValue }
    var debugTimestampFont: NSFont? { timestampLabel.font }
    var debugMenuButtonFont: NSFont? { menuButton.font }
    #endif
}

extension StickyNoteView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        onTextChanged?(textView.string)
        refreshHandleDescriptions()
    }

    /// Findings 3.3/4.6: the store's text write is debounced, so giving up
    /// focus is one of its flush points - clicking straight from a note into
    /// another app must not be able to lose the last characters typed.
    func textDidEndEditing(_ notification: Notification) {
        onEditingEnded?()
    }
}

extension StickyNoteView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField else { return }
        onTitleChanged?(titleField.stringValue)
        refreshHandleDescriptions()
    }

    /// The title field's half of the same flush point as `textDidEndEditing`.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField else { return }
        onEditingEnded?()
    }
}
