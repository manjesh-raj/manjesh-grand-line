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
//     torn/rotated cards, a typewriter header font).
//   - A cleaner "Sticky Board" mockup (a toolbar, a dotted-grid board,
//     draggable colored cards with a small header + "\u{2022}\u{2022}\u{2022}"
//     menu, an editable body, free positioning, a slight per-note rotation, a
//     footer note count) - this is the interaction model this build follows,
//     built natively rather than as embedded web content.
//
// **v1 took the second one and explicitly refused the first's decoration;
// `fm/grandline-sticky-code-preview-polish` reversed half of that**, after
// the captain reviewed v1 live and asked for the detective board's own
// identity back: the typewriter case-file header, the red pins, and a real
// cork surface in a wooden frame in place of the dotted grid. So this file's
// former "no pushpins, no wood texture anywhere" note is gone, deliberately.
// What is still NOT built from that mockup: the red string between cards,
// and torn/ragged card edges.
//
// A third reference arrived with that pass and outranks both: a plain photo
// of a real corkboard in a wooden picture frame. It is the authoritative
// colour/material direction for the board surface - tan/brown flecked cork,
// **not** the detective mockup's green felt (see `StickyBoardModels.swift`'s
// `StickyBoardCork` for the contradiction that resolved and how).
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
// does). Colour here is **three** categories, not two - board chrome follows
// the active `HelmTheme`, the cork and its wood frame are literal hues chosen
// by light/dark *mode*, and a note's paper is one literal value in all 14
// themes. `StickyBoardModels.swift`'s header is the authority on which is
// which; conflating any two of them is how this feature breaks.
//
// `applyTheme()` also forces `view.appearance`, which is not optional
// decoration: without it every system-semantic colour in this subtree
// (scrollers, the title field's editor, the overflow menu) follows the OS's
// light/dark rather than the app's, and the page re-themes only halfway. That
// omission was the captain's own "Sticky Board doesn't re-theme properly"
// report; see `ThemeManager.swift`'s checklist item 2.

import AppKit

final class StickyBoardController: NSViewController, DaylightDrillActions {

    private var theme: HelmTheme = ThemeManager.shared.theme
    /// This page's store.
    ///
    /// Internal rather than private so ⌘K's provider can read the **same**
    /// instance (audit §6.5b). GL-23's lesson applies directly here: this
    /// store caches its notes *and* writes them, so a second instance would
    /// both serve stale rows to the palette and become a second writer to one
    /// file - unlike the read-through-on-demand stores (`DocsRunbookStore`)
    /// where an independent copy is genuinely free.
    let store = StickyBoardStore()

    /// Daylight §7's card around a scrollable content surface - the same
    /// treatment `WhiteboardController.canvasCard`/Docs' playbook card use.
    private let boardCard = NSView()
    private static let cardInset: CGFloat = HelmMetrics.s3

    private let scrollView = NSScrollView()
    private let canvas = StickyBoardCanvasView(frame: NSRect(origin: .zero, size: StickyBoardMetrics.canvasSize))

    private let footer = NSTextField(labelWithString: "")

    // MARK: The board's own case-file header
    //
    // **A deliberate, documented exception to this app's "a page never
    // repeats its own destination name" convention** (Daylight §6.4 - the
    // shared drill header already names the destination, and Review/Docs/
    // Health were each corrected for exactly this duplication). The captain
    // asked for it explicitly and by name: the board is meant to read as a
    // detective's case file, and the typewriter title plus the "ACTIVE" pill
    // ARE that identity. This one *was* deliberately kept well under the 20pt
    // hero floor `DaylightDrillPageSelfTest` polices - `fm/grandline-sticky-
    // board-header-size-3x` is the captain's own explicit, second exception
    // on top of the first: he reviewed the smaller header live and asked for
    // it at roughly 3x its point size, since a case-file header this small
    // read as an afterthought next to the board rather than the identity it
    // is meant to be. `DaylightDrillPageSelfTest`'s general hero-floor sweep
    // never covered Sticky Board to begin with (it only visits Review and
    // Tasks); the guard this page actually had to answer to was its own,
    // narrower one in `StickyBoardViewSelfTest.checkBoardHeader` - updated in
    // the same commit to assert the new, sanctioned size instead of quietly
    // widening or deleting it. `buildBoardHeader()`'s own constraints changed
    // to match: the title now drives the header's own height (it used to be
    // the other way around, with the small "ACTIVE" pill's fixed 16pt height
    // setting the header's height and the title merely centred inside it,
    // which only worked because the title was smaller than the pill's box).
    private let boardHeader = NSView()
    private let boardTitle = NSTextField(labelWithString: "CASE: MY THOUGHTS")
    private let statusPill = NSView()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

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
        // Opaque, and filled with the cork base: the canvas is larger than
        // any realistic viewport so it normally covers this entirely, but a
        // window wider than the canvas (or the frame between a resize and the
        // next redraw) would otherwise show a strip of page background
        // through the middle of a corkboard.
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.documentView = canvas
        boardCard.addSubview(scrollView)

        buildBoardHeader()
        boardCard.addSubview(boardHeader)

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

            // Inset on all four sides by the frame width, so `boardCard`'s own
            // fill shows as a wood picture-frame band around the cork. The
            // frame belongs on the CARD, not the canvas: the canvas scrolls,
            // and a frame that scrolled away with it would not be a frame.
            scrollView.leadingAnchor.constraint(equalTo: boardCard.leadingAnchor, constant: StickyBoardCork.frameWidth),
            scrollView.trailingAnchor.constraint(equalTo: boardCard.trailingAnchor, constant: -StickyBoardCork.frameWidth),
            scrollView.topAnchor.constraint(equalTo: boardCard.topAnchor, constant: StickyBoardCork.frameWidth),
            scrollView.bottomAnchor.constraint(equalTo: boardCard.bottomAnchor, constant: -StickyBoardCork.frameWidth),

            // Pinned over the cork's top-left, inside the frame band.
            boardHeader.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: HelmMetrics.s3),
            boardHeader.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: HelmMetrics.s3),

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

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Findings 3.3/4.6: the store's text/title writes are debounced, so
        // the way out of the destination is one of the three places anything
        // still queued has to reach disk (the others are a field giving up
        // focus, and app termination). Without this, navigating away within
        // `StickyBoardStore.persistDebounce` of the last keystroke would lose
        // it - which is the trade a debounce always makes, and the reason it
        // is only ever paired with real flush points.
        store.flushPendingWrite()
    }

    /// Called by the app delegate on quit, so the last few characters typed
    /// before ⌘Q are written and committed like every other edit - the same
    /// contract `CodePreviewController.shutdown()` carries for the same
    /// reason.
    func shutdown() {
        store.flushPendingWrite()
        _ = store.gitSync?.commitAndPushNow()
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

    /// The title's designed point size, and the multiplier the captain asked
    /// for live (roughly 3x the original 15pt). Kept as named constants
    /// rather than an inline `45` so the "roughly 3x" relationship the
    /// self-test checks for is legible at both ends, not just asserted.
    private static let boardTitleBasePointSize: CGFloat = 15
    private static let boardTitleScale: CGFloat = 3

    /// The case-file header: a typewriter title and a live status pill. See
    /// the property declarations above for why a second in-page title is a
    /// sanctioned exception here specifically.
    private func buildBoardHeader() {
        boardHeader.translatesAutoresizingMaskIntoConstraints = false
        boardHeader.wantsLayer = true

        boardTitle.translatesAutoresizingMaskIntoConstraints = false
        boardTitle.font = StickyFont.typewriter(HelmType.scaled(Self.boardTitleBasePointSize * Self.boardTitleScale))
        boardHeader.addSubview(boardTitle)

        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 13
        statusPill.layer?.borderWidth = 1
        boardHeader.addSubview(statusPill)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4.5
        statusPill.addSubview(statusDot)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            // The title now drives `boardHeader`'s own height with a required
            // top+bottom pin, rather than a `>=` against a header whose
            // height a small, fixed-size pill used to set. A `>=` here (the
            // pre-3x shape) only worked because the title's natural height
            // was already smaller than the pill's fixed box; at 3x the title
            // is by far the taller element, and a `>=` paired with a
            // required `centerYAnchor` would have left AutoLayout resolving
            // the conflict by silently compressing the title's own frame
            // below its real line height (this app's AppKit gotcha
            // catalogue's own "vertical compression, not a visible warning"
            // failure mode) rather than growing the header to fit it.
            boardTitle.leadingAnchor.constraint(equalTo: boardHeader.leadingAnchor),
            boardTitle.topAnchor.constraint(equalTo: boardHeader.topAnchor),
            boardTitle.bottomAnchor.constraint(equalTo: boardHeader.bottomAnchor),

            // The pill stays a compact badge - scaled up a little for
            // proportion against the much taller title (16 -> 26pt, its
            // corner radius kept at exactly half its height for the same
            // capsule shape), not tripled itself, which would read as a
            // second oversized element competing with the title rather than
            // a small status badge beside it. Centred on the title's own
            // vertical midpoint, since the header's height is the title's
            // now.
            statusPill.leadingAnchor.constraint(equalTo: boardTitle.trailingAnchor, constant: HelmMetrics.s3),
            statusPill.trailingAnchor.constraint(equalTo: boardHeader.trailingAnchor),
            statusPill.centerYAnchor.constraint(equalTo: boardTitle.centerYAnchor),
            statusPill.heightAnchor.constraint(equalToConstant: 26),

            statusDot.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 9),
            statusDot.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 9),
            statusDot.heightAnchor.constraint(equalToConstant: 9),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),
        ])
    }

    /// The pill says something true about the board rather than a permanent
    /// "ACTIVE" sticker: an empty board is genuinely idle, and a board this
    /// app could not read is not a state to dress up (GL-14's rule - an
    /// unreadable file and an empty one must never render the same).
    private var statusText: String {
        if store.isInFailedLoadState { return "UNREADABLE" }
        return store.notes.isEmpty ? "EMPTY" : "ACTIVE"
    }

    private var statusTint: HelmTint {
        if store.isInFailedLoadState { return .critical }
        return store.notes.isEmpty ? .neutral : .good
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
        noteView.onTitleChanged = { [weak self, id = note.id] title in
            self?.store.updateTitle(id: id, title: title)
        }
        noteView.onMoved = { [weak self, id = note.id] origin in
            self?.store.updatePosition(id: id, x: Double(origin.x), y: Double(origin.y))
        }
        noteView.onEditingEnded = { [weak self] in self?.store.flushPendingWrite() }
        noteView.onResized = { [weak self, id = note.id] size in
            self?.store.updateSize(id: id, width: Double(size.width), height: Double(size.height))
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
        applyBoardHeaderTheme()
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
        // A fresh note is worth naming right away - the reference photo's
        // cards all carry a label, and the title is the field a captain is
        // least likely to discover on their own.
        if let noteView = noteViews[note.id] {
            view.window?.makeFirstResponder(noteView.titleFieldForFocus)
        }
    }

    /// Reveal one note by id - ⌘K's landing action (audit §6.5b).
    ///
    /// Scrolls it into view and gives it focus. The board is a freeform
    /// canvas, so a note the captain searched for can easily be off-screen;
    /// selecting the destination without moving to the note would be the same
    /// dead end a Recents row for an ended session used to be.
    func revealNote(id: String) {
        // The board only builds note views once its store has loaded, which
        // `viewWillAppear` drives - so a deep link arriving before the page
        // has ever appeared has to build them first.
        rebuildNoteViews()
        guard let noteView = noteViews[id] else { return }
        noteView.scrollToVisible(noteView.bounds.insetBy(dx: -40, dy: -40))
        view.window?.makeFirstResponder(noteView.titleFieldForFocus)
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
        // **`ThemeManager.swift`'s checklist item 2, and the actual root cause
        // of the captain's "Sticky Board only half re-themes" report.**
        //
        // Layer-backed fills (this page's root, card, canvas) already tracked
        // the theme and were already asserted by the self-test - which is
        // exactly why the bug survived review. What did NOT track it is
        // everything in the subtree that resolves a *system semantic* colour:
        // the scroll view's scroller track and knob, the field editor AppKit
        // lends `titleField`, the note overflow button's `NSMenu`, focus
        // rings. Those resolve against the OS's own light/dark setting, not
        // the in-app theme - so on a Mac in system Dark with a light Helm
        // theme selected, this page rendered dark scrollbars and dark control
        // chrome on a light board, and vice versa. Every other destination in
        // this app has forced this for years (Docs, Review, Hosts, Settings,
        // Updates, Shift, Log Analyzer, Kubernetes, ...); the two newest ones
        // never did.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)

        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        // The card is the wood picture frame the cork sits inside - its fill
        // shows only as the band `scrollView`'s inset leaves around the
        // board. It is a literal wood tone chosen by light/dark mode, not a
        // theme token, for the same reason the cork is (see
        // `StickyBoardModels.swift`'s header); `applyCardSurface` still owns
        // the radius/shadow so the board keeps the app's own card geometry.
        HelmCard.applyCardSurface(to: boardCard, theme: theme,
                                  cornerRadius: HelmMetrics.rCard,
                                  daylightRadius: HelmMetrics.dSurface)
        let dark = theme.mode == .dark
        boardCard.layer?.backgroundColor = HelmTheme.nsColor(StickyBoardCork.frameHex(dark: dark)).cgColor
        boardCard.layer?.borderColor = HelmTheme.nsColor(StickyBoardCork.frameHex(dark: dark))
            .blended(withFraction: dark ? 0.25 : 0.18, of: .black)?.cgColor
            ?? boardCard.layer?.borderColor
        scrollView.backgroundColor = HelmTheme.nsColor(StickyBoardCork.baseHex(dark: dark))
        canvas.applyTheme(theme)
        applyBoardHeaderTheme()
        overlayContainer.wantsLayer = true
        overlayContainer.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        overlay?.applyTheme(theme)
        footer.textColor = HelmTheme.mutedInk(theme)
    }

    /// The case-file header sits **on the cork**, not on a theme surface, so
    /// its ink is derived from the cork rather than from `chromeInkHex` - the
    /// theme's own ink is chosen against the theme's own background and would
    /// be measurably illegible on tan (a light theme's near-black ink is fine,
    /// a dark theme's near-white ink on light cork is not).
    /// `HelmContrast.legibleOn(fill:preferring:)` is the app's own guaranteed
    /// correction for exactly this "I chose this opaque fill myself" case.
    private func applyBoardHeaderTheme() {
        let dark = theme.mode == .dark
        let cork = HelmTheme.nsColor(StickyBoardCork.baseHex(dark: dark))
        let ink = HelmContrast.legibleOn(fill: cork, preferring: dark ? .white : .black)
        boardTitle.font = StickyFont.typewriter(HelmType.scaled(Self.boardTitleBasePointSize * Self.boardTitleScale))
        boardTitle.textColor = ink

        let tintHex = statusTint.hex(in: theme)
        let tint = HelmTheme.nsColor(tintHex)
        statusPill.layer?.backgroundColor = cork.blended(withFraction: dark ? 0.22 : 0.30, of: .white)?.cgColor
        statusPill.layer?.borderColor = ink.withAlphaComponent(0.30).cgColor
        statusDot.layer?.backgroundColor = tint.cgColor
        // `kickerAttributes` is the app's one uppercase/tracked label recipe -
        // hand-rolling `.kern:` anywhere outside `HelmType` is a build failure
        // (`HelmContrastSelfTest.checkNoHandRolledKickers`).
        statusLabel.attributedStringValue = NSAttributedString(
            string: statusText,
            attributes: HelmType.kickerAttributes(color: ink))
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugStore: StickyBoardStore { store }
    var debugCanvas: StickyBoardCanvasView { canvas }
    var debugBoardCard: NSView { boardCard }
    var debugNoteViews: [String: StickyNoteView] { noteViews }
    var debugOverlayVisible: Bool { !overlayContainer.isHidden }
    var debugFooterText: String { footer.stringValue }
    var debugBoardHeader: NSView { boardHeader }
    var debugBoardTitle: NSTextField { boardTitle }
    var debugStatusLabel: NSTextField { statusLabel }
    var debugStatusDot: NSView { statusDot }
    var debugScrollView: NSScrollView { scrollView }
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
