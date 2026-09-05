// Manjesh Grand Line - native macOS app.
//
// The `.stickyBoard` destination: a freeform corkboard of draggable, colored
// sticky notes for quick thoughts (captain's own request).
//
// ## What the two reference mockups actually meant for this build
//
// The captain shared two pieces of HTML purely as visual/interaction
// inspiration, never to be embedded or reproduced literally (unlike
// Whiteboard's real, embedded Excalidraw - a genuinely different situation,
// since that one hosts a mature library rather than a from-scratch UI):
//
//   - A "detective corkboard" mockup (dark wood, red pushpins, red string,
//     torn/rotated cards, a typewriter header font) - explicitly NOT the
//     direction taken. No pushpins, no string, no wood texture anywhere in
//     this file.
//   - A cleaner "Sticky Board" mockup (a toolbar, a dotted-grid board,
//     draggable colored cards with a small header + "\u{2022}\u{2022}\u{2022}"
//     menu, an editable body, free positioning, a slight per-note rotation, a
//     footer note count) - this is the interaction model this build actually
//     follows, built natively rather than as embedded web content.
//
// ## What v1 deliberately does not build
//
// A checklist/checkbox variant of a note's body (the reference's note #3) is
// explicitly a "nice to have if cheap" in the brief; it is not cheap to build
// correctly alongside real drag mechanics and persistence in one pass, so v1
// ships plain multi-line text only - the captain's own spec calls this
// sufficient. A second, related "plain notebook/journal" feature is
// explicitly OUT of scope here - the captain is still deciding whether Sticky
// Board alone covers that need; do not build it as part of touching this
// file.
//
// ## Persistence and theming
//
// See `StickyBoardStore.swift`'s header for the git-sync story (a genuinely
// new, dedicated `GrandLineDocs/sticky-board/` folder, sharing
// `ShiftGitSync.shared`'s clone the same way `DocsRunbookGitSync` already
// does). Note paper colors are a deliberate, literal exception to this app's
// theme-token rule (see `StickyBoardModels.swift`'s header) - only the
// board's own background/toolbar chrome follows the active `HelmTheme`.

import AppKit

final class StickyBoardController: NSViewController, DaylightDrillActions {

    private var theme: HelmTheme = ThemeManager.shared.theme
    private let store = StickyBoardStore()

    /// Daylight §7's card around a scrollable content surface - the same
    /// treatment `WhiteboardController.canvasCard`/Docs' playbook card use.
    private let boardCard = NSView()
    private static let cardInset: CGFloat = HelmMetrics.s3

    private let scrollView = NSScrollView()
    private let canvas = StickyBoardCanvasView(frame: NSRect(origin: .zero, size: StickyBoardMetrics.canvasSize))

    private let footer = NSTextField(labelWithString: "")

    private var overlay: HelmEmptyState?
    private let overlayContainer = NSView()

    private var noteViews: [String: StickyNoteView] = [:]

    private lazy var newNoteButton = HelmPageToolbar.labeledButton(
        symbol: "plus", title: "New Note",
        tooltip: "Add a new sticky note to the board",
        target: self, action: #selector(newNoteTapped))

    // MARK: Drill header (Daylight §6.4)

    var onDrillSubtitleChanged: (() -> Void)?

    var drillHeaderActions: [NSView] { [newNoteButton] }

    var drillHeaderSubtitle: String? {
        let count = store.notes.count
        let noun = count == 1 ? "1 note" : "\(count) notes"
        if store.isInFailedLoadState {
            return "\(noun) \u{00B7} the saved file couldn't be read - see the backed-up copy"
        }
        return "\(noun) \u{00B7} synced to manjesh-config"
    }

    // MARK: Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        root.wantsLayer = true
        view = root

        boardCard.translatesAutoresizingMaskIntoConstraints = false
        boardCard.wantsLayer = true
        boardCard.layer?.masksToBounds = true
        root.addSubview(boardCard)

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.font = HelmType.caption()
        root.addSubview(footer)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = canvas
        boardCard.addSubview(scrollView)

        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.isHidden = true
        boardCard.addSubview(overlayContainer)

        NSLayoutConstraint.activate([
            boardCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.cardInset),
            boardCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.cardInset),
            boardCard.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.cardInset),
            boardCard.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -HelmMetrics.s2),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.cardInset + HelmMetrics.s1),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s2),

            scrollView.leadingAnchor.constraint(equalTo: boardCard.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: boardCard.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: boardCard.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: boardCard.bottomAnchor),

            overlayContainer.leadingAnchor.constraint(equalTo: boardCard.leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: boardCard.trailingAnchor),
            overlayContainer.topAnchor.constraint(equalTo: boardCard.topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: boardCard.bottomAnchor),
        ])

        ThemeManager.shared.observe { [weak self] theme in
            self?.theme = theme
            self?.applyTheme()
        }

        rebuildNoteViews()
        applyTheme()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // A relaunch or a git pull elsewhere in the app could have changed
        // the file on disk since this destination last mounted - reload and
        // reconcile the view tree with whatever the store now says, rather
        // than trusting a possibly-stale in-memory snapshot from first load.
        store.reloadAll()
        rebuildNoteViews()
        onDrillSubtitleChanged?()
    }

    // MARK: Notes

    private func rebuildNoteViews() {
        let current = Set(store.notes.map(\.id))
        for (id, noteView) in noteViews where !current.contains(id) {
            noteView.removeFromSuperview()
            noteViews.removeValue(forKey: id)
        }
        for note in store.notes where noteViews[note.id] == nil {
            addNoteView(for: note)
        }
        updateFooter()
        updateOverlay()
    }

    private func addNoteView(for note: StickyNote) {
        let noteView = StickyNoteView(note: note)
        noteView.onTextChanged = { [weak self, id = note.id] text in
            self?.store.updateText(id: id, text: text)
        }
        noteView.onMoved = { [weak self, id = note.id] origin in
            self?.store.updatePosition(id: id, x: Double(origin.x), y: Double(origin.y))
        }
        noteView.onDeleteRequested = { [weak self, id = note.id] in
            self?.deleteNote(id: id)
        }
        canvas.addSubview(noteView)
        noteViews[note.id] = noteView
    }

    private func deleteNote(id: String) {
        guard let removed = store.deleteNote(id: id) else { return }
        noteViews[id]?.removeFromSuperview()
        noteViews.removeValue(forKey: id)
        updateFooter()
        updateOverlay()
        onDrillSubtitleChanged?()
        // GL-33: undo restores the exact value already in hand, matching
        // every other delete-with-undo in this app (a host, a snippet, a
        // dictation word) - never a fabricated "recreate from scratch".
        Toast.showUndo(in: view, message: "Note deleted") { [weak self] in
            guard let self else { return }
            self.store.restoreNote(removed)
            self.addNoteView(for: removed)
            self.updateFooter()
            self.updateOverlay()
            self.onDrillSubtitleChanged?()
        }
    }

    private func updateFooter() {
        let count = store.notes.count
        footer.stringValue = count == 1 ? "1 note" : "\(count) notes"
    }

    private func updateOverlay() {
        let isEmpty = store.notes.isEmpty
        overlayContainer.isHidden = !isEmpty
        guard isEmpty else { return }
        if overlay == nil {
            let state = HelmEmptyState(
                symbol: "note.text",
                title: "Your board is empty",
                body: "Click \u{201C}New Note\u{201D} above to add your first sticky note.",
                size: .standard, boxed: false,
                hue: RailDestination.stickyBoard.domainHue)
            state.translatesAutoresizingMaskIntoConstraints = false
            overlayContainer.addSubview(state)
            NSLayoutConstraint.activate([
                state.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor),
                state.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor),
                state.topAnchor.constraint(equalTo: overlayContainer.topAnchor),
                state.bottomAnchor.constraint(equalTo: overlayContainer.bottomAnchor),
            ])
            overlay = state
        }
        overlay?.applyTheme(theme)
    }

    // MARK: Actions

    @objc private func newNoteTapped() {
        let position = nextPosition()
        let note = store.addNote(
            text: "",
            color: StickyNoteColor.allCases.randomElement() ?? .yellow,
            x: Double(position.x), y: Double(position.y),
            rotationDegrees: Double.random(in: -4...4))
        addNoteView(for: note)
        updateFooter()
        updateOverlay()
        onDrillSubtitleChanged?()
        // A fresh note is worth typing into right away.
        if let noteView = noteViews[note.id] {
            view.window?.makeFirstResponder(noteView.textViewForFocus)
        }
    }

    /// Cascades new notes through a simple grid, wrapping diagonally once a
    /// full grid's worth exist - deterministic and good enough for a
    /// personal quick-notes board; the captain can drag a note anywhere
    /// regardless.
    private func nextPosition() -> CGPoint {
        let index = store.notes.count
        let stepX = StickyBoardMetrics.noteSize.width + StickyBoardMetrics.noteMargin
        let stepY = StickyBoardMetrics.noteSize.height + StickyBoardMetrics.noteMargin
        let usableWidth = StickyBoardMetrics.canvasSize.width - StickyBoardMetrics.noteSize.width - StickyBoardMetrics.noteMargin
        let usableHeight = StickyBoardMetrics.canvasSize.height - StickyBoardMetrics.noteSize.height - StickyBoardMetrics.noteMargin
        let columns = max(1, Int(usableWidth / stepX))
        let rows = max(1, Int(usableHeight / stepY))
        let slot = index % (columns * rows)
        let col = slot % columns
        let row = slot / columns
        let cascade = CGFloat(index / (columns * rows)) * StickyBoardMetrics.noteCascadeStep
        let x = StickyBoardMetrics.noteMargin + CGFloat(col) * stepX + cascade
        let y = StickyBoardMetrics.noteMargin + CGFloat(row) * stepY + cascade
        return canvas.clamp(CGPoint(x: x, y: y))
    }

    // MARK: Theme

    private func applyTheme() {
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        HelmCard.applyCardSurface(to: boardCard, theme: theme,
                                  cornerRadius: HelmMetrics.rCard,
                                  daylightRadius: HelmMetrics.dSurface)
        canvas.applyTheme(theme)
        overlayContainer.wantsLayer = true
        overlayContainer.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        overlay?.applyTheme(theme)
        footer.textColor = HelmTheme.mutedInk(theme)
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugStore: StickyBoardStore { store }
    var debugCanvas: StickyBoardCanvasView { canvas }
    var debugBoardCard: NSView { boardCard }
    var debugNoteViews: [String: StickyNoteView] { noteViews }
    var debugOverlayVisible: Bool { !overlayContainer.isHidden }
    var debugFooterText: String { footer.stringValue }
    func debugNewNote() { newNoteTapped() }
    func debugDeleteNote(id: String) { deleteNote(id: id) }
    /// Re-themes this instance directly, bypassing `ThemeManager.shared.
    /// setTheme` - which persists to real `UserDefaults` - so a self-test
    /// theme sweep never clobbers the captain's own saved preference on a
    /// shared dev machine (`UnifiedSearch.swift`'s own `debugApplyTheme`
    /// establishes this exact pattern).
    func debugApplyTheme(_ theme: HelmTheme) {
        self.theme = theme
        applyTheme()
    }
    #endif
}
