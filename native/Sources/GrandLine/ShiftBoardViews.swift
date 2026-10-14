// Grand Line - native macOS app.
//
// The Tasks page's Kanban board (`fm/grandline-tasks-kanban-devops-split`).
//
// The captain supplied an HTML/CSS/JS mockup as a reference for the *UX* he
// wanted - columns with counts, draggable cards, a Board/List toggle, project
// filter chips - explicitly not as something to port. So nothing here is
// translated from that file: every surface is built out of this app's own
// design system (`HelmAccentRow` for a card, `HelmCard` for a column,
// `HelmButton` for a chip, `HelmTint`/`HelmTheme` for every colour), and the
// mockup's own palette, fonts and radii are not used anywhere.
//
// **Three columns, not the mockup's four.** The mockup shows Backlog / In
// Progress / Review / Done, but `ShiftTaskStatus` has no "review" state and
// inventing a persisted one to match a picture would be putting a field in
// the captain's YAML that nothing else in the app - Weekly Review, the stat
// tiles, the project detail, the morning briefing - knows how to read. The
// three columns map exactly onto the three statuses a task really has
// (`todo` / `inProgress` / `completed`); `cancelled` is filtered off the
// board entirely, since a board is a thing you move work across and a
// cancelled task is not in flight.
//
// **Dragging.** This app had no `NSDraggingSource` anywhere before this - the
// three existing drag-aware views (`LogDropZoneView`, `KeyDropZone`,
// `ShiftImageAttachmentWell`) are all *destinations* for Finder drags, and
// the Sticky Board's "dragging" is hand-rolled `mouseDragged` frame moving
// inside one canvas. Moving a card between two columns is genuinely a
// cross-container drag, which is what `NSDraggingSession` exists for: it
// gives the drag image, the cursor, autoscroll and cross-view hit testing for
// free, where hand-rolled hit testing across sibling scroll views would be
// re-implementing all four badly. The destination half follows the existing
// three verbatim (`registerForDraggedTypes` plus the four overrides on a
// plain `NSView`); only the source half is new.
//
// The minimum-movement threshold before a press becomes a drag is not
// optional - it is a convention AGENTS.md records twice (`StickyNoteHeaderView.
// dragThreshold`, `CockpitTerminalView.localSelectionDragThreshold`), because
// AppKit delivers `mouseDragged` for sub-pixel jitter and without a threshold
// an ordinary click becomes a drag.
//
// **Dragging is never the only way.** Every card carries the same moves in
// its right-click menu and as `NSAccessibilityCustomAction`s, so the board is
// fully usable with no pointer at all - the lesson `StickyNoteHandleView`
// already learned for its own drag-only affordance.

import AppKit

// MARK: - Columns

/// The board's columns, and the only place a column/status mapping is stated.
///
/// Deliberately its own type rather than a `ShiftTaskStatus` extension: a
/// column is a *presentation* concept (three of the four statuses, in a fixed
/// left-to-right order, with a heading and a hue), and `cancelled` having no
/// column is a fact about the board, not about the status.
enum ShiftBoardColumn: String, CaseIterable {
    case backlog
    case inProgress
    case done

    /// The status a task takes when it lands in this column.
    var status: ShiftTaskStatus {
        switch self {
        case .backlog: return .todo
        case .inProgress: return .inProgress
        case .done: return .completed
        }
    }

    var title: String {
        switch self {
        case .backlog: return "Backlog"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }

    /// The column heading's dot. Semantic, unlike a card's bar (which carries
    /// project identity): this is genuinely "what state is this pile in".
    var tint: HelmTint {
        switch self {
        case .backlog: return .neutral
        case .inProgress: return .warn
        case .done: return .good
        }
    }

    var symbol: String {
        switch self {
        case .backlog: return "tray"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle"
        }
    }

    /// Which column a task belongs in, or `nil` for a status that has no
    /// column (`cancelled`).
    static func column(for status: ShiftTaskStatus) -> ShiftBoardColumn? {
        switch status {
        case .todo: return .backlog
        case .inProgress: return .inProgress
        case .completed: return .done
        case .cancelled: return nil
        }
    }
}

// MARK: - Per-project colour

/// A stable colour per project, for the card bars and the filter chips.
///
/// **There was no per-project colour to reuse.** `ShiftProjectCardView` tints
/// itself from the project's *status*, which is a different idea - two "In
/// Progress" projects share that colour by design, which is exactly what an
/// identity marker must not do. `ShiftProject` carries no colour field, and
/// adding one would mean a new persisted field, a migration story and a
/// colour picker nobody asked for.
///
/// So the colour is derived from the project's own id, and two properties
/// make that honest:
///
///   - **`HelmTint`, never a literal hex.** `SSHKeyType` shipped four fixed
///     hexes picked against `helm-dark` and measurably washed out on Gruvbox
///     Light the moment they landed on a real accent bar; it carries a
///     `HelmTint` now for exactly this reason. A tint resolves against
///     whichever of the fourteen palettes is active.
///   - **A deterministic hash, never `String.hashValue`.** Swift seeds its
///     hasher randomly per process, so `hashValue` would give a project a
///     different colour on every launch and a different one on each machine.
///     FNV-1a over the id's UTF-8 bytes is stable everywhere, forever.
enum ShiftProjectPalette {

    /// Six hues, in a fixed order. `.neutral` is excluded deliberately: it is
    /// `chromeInkHex`, i.e. full page ink, which is what a task with *no*
    /// project falls back to - so keeping it out of the rotation is what lets
    /// "no project" stay visually distinct from "some project".
    static let tints: [HelmTint] = [.accent, .info, .violet, .good, .warn, .critical]

    /// The tint for a project id, or `.neutral` for a task with no project.
    ///
    /// `.neutral` as a bar is the same choice Dictation's history rows already
    /// ship (`HelmDomainHue(tint: .neutral)`) - a row that carries no identity
    /// signal gets the ink tone rather than a semantic hue it would be lying
    /// with.
    static func tint(forProjectID id: String?) -> HelmTint {
        guard let id, !id.isEmpty else { return .neutral }
        return tints[Int(fnv1a(id) % UInt64(tints.count))]
    }

    /// FNV-1a, 64-bit. Small, well-known, and - the only property that
    /// matters here - identical on every run and every machine.
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: - Pasteboard

/// The board's own drag payload: a task id, nothing else.
///
/// A private type rather than `.string`, so a drag from anywhere else in the
/// app (or from another app) can never be mistaken for a card and dropped
/// into a column.
enum ShiftBoardPasteboard {
    static let taskType = NSPasteboard.PasteboardType("com.manjesh.grandline.shift.task-id")

    static func item(taskID: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(taskID, forType: taskType)
        return item
    }

    static func taskID(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: taskType)
    }
}

// MARK: - Card

/// One card on the board: a drag source wrapping the app's shared
/// `HelmAccentRow`.
///
/// The row does every visual thing (bar, kicker, title, meta, chip, card
/// chrome, hover, per-theme contrast); this view adds only the press/drag
/// handling and the menu, so the board's cards and the list's rows stay one
/// visual language rather than two.
final class ShiftBoardCardView: NSView, NSDraggingSource {

    /// Matches `CockpitTerminalView.localSelectionDragThreshold` rather than
    /// the Sticky Board's 3: a stray click here opens an editor sheet, so the
    /// slightly more generous guard is the right trade.
    static let dragThreshold: CGFloat = 4

    /// `.belowBody`, matching the reference's own card: project line, then
    /// title, then the priority badge on its own line underneath.
    ///
    /// This costs the chip a line (a card measures ~81pt rather than ~58pt
    /// with the chip beside the title), and that is the reference's own
    /// proportion - its `.card` is around 85px for exactly the same three
    /// stacked pieces. The height the captain reacted to was the *column*,
    /// which was 515pt before `bodyHeight` was cut; a card that reads like
    /// the reference is the point of the card.
    ///
    /// UI-22: the revamp's `.cardFlat` - a neutral hairline (never the tint),
    /// the 3pt project bar, radius 10, 10/12 padding - with the chip on the
    /// meta line beside the due caption, so a card is three lines at most.
    private let row = HelmAccentRow(chipPlacement: .metaLine, style: .cardFlat)

    private(set) var taskID: String = ""
    private var currentColumn: ShiftBoardColumn = .backlog

    /// A single click with no drag.
    var onOpen: (() -> Void)?
    /// A move requested from the context menu or an accessibility action -
    /// the same call a real drop makes.
    var onMove: ((ShiftBoardColumn) -> Void)?
    var onDelete: (() -> Void)?

    private var pressLocation: NSPoint = .zero
    private var isDraggingCard = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(task: ShiftTask, project: ShiftProject?, column: ShiftBoardColumn, theme: HelmTheme) {
        taskID = task.id
        currentColumn = column

        // UI-23 / UI-24 through `ShiftTaskSignals`, the page's one rule: a
        // priority pill only for High, Low as a quiet word, and the due date
        // as a caption that is amber today and red when late.
        let pill = ShiftTaskSignals.priorityPill(task.priority)
        var bits: [String] = []
        var lead: ShiftTaskSignals.DueCaption?
        if column == .done {
            // UI-29: a finished card says when it finished, in the muted face.
            if let done = task.completedAt.flatMap(ShiftStore.date(fromISO8601:)) {
                lead = .init(text: "Done \(Self.doneDateFormatter.string(from: done))", tint: nil)
            }
        } else {
            lead = ShiftTaskSignals.dueCaption(date: task.dueDate, time: task.dueTime)
        }
        if !task.subtasks.isEmpty {
            let done = task.subtasks.filter(\.done).count
            bits.append("\(done)/\(task.subtasks.count) subtasks")
        }
        if let word = ShiftTaskSignals.priorityWord(task.priority) { bits.append(word) }

        row.configure(HelmAccentRow.Content(
            // The bar carries **project identity**, the one thing the board's
            // colour codes - and the list's rows now say the same (UI-24).
            tint: ShiftProjectPalette.tint(forProjectID: task.projectID),
            kicker: project?.name ?? "No project",
            title: task.title,
            meta: bits.isEmpty ? nil : bits.joined(separator: " \u{00B7} "),
            titleAccessorySymbol: task.hasAttachment ? "paperclip" : nil,
            chipText: pill?.text,
            chipTint: pill?.tint,
            // A lane is ~260-340pt wide; a one-line truncating title would
            // hide most of a real task's name.
            titleWraps: true,
            metaLead: lead?.text,
            metaLeadTint: lead?.tint,
            titleStruck: column == .done,
            hint: "Drag to another lane, or right-click to move."
        ), theme: theme)

        let priorityText = task.priority.rawValue.capitalized
        setAccessibilityLabel("\(task.title), \(column.title), \(priorityText) priority")
        menu = buildMenu()
        setAccessibilityCustomActions(accessibilityMoves())
    }

    func applyTheme(_ theme: HelmTheme) { row.applyTheme(theme) }

    static let doneDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    // MARK: Selection and keyboard (UI-28)

    /// A card takes the keyboard on a click or a Tab, and shows it: the
    /// row's own selected recipe (accent wash and stroke) plus the system
    /// focus ring. Return or Space opens it, the same as a click.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        row.isRowSelected = true
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        row.isRowSelected = false
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: HelmMetrics.rRow, yRadius: HelmMetrics.rRow).fill()
    }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter, 49 = Space.
        if [36, 76, 49].contains(event.keyCode) {
            onOpen?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Press, click and drag

    /// The card is the event target for its whole area, rather than whichever
    /// label or stack inside `HelmAccentRow` happens to be under the cursor.
    ///
    /// **This is load-bearing, not tidiness - measured, not assumed.** Without
    /// it a real press routed through AppKit's own hit testing lands on one of
    /// the row's internal `NSStackView`s and never reaches this view's
    /// `mouseDown` at all, so the board simply cannot be dragged - and nothing
    /// about the way it renders says so. `ShiftBoardViewSelfTest` sends its
    /// press through `window.sendEvent` precisely so that stays true;
    /// calling `mouseDown` on the card by hand passes either way.
    ///
    /// Nothing is lost by taking the events: this card never sets the row's
    /// `onClick`, so the recognizer inside it has nothing to do, and the
    /// row's hover highlight comes from its own `NSTrackingArea`, which is
    /// driven by the tracking rect rather than by hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// A card is draggable in a window that is not focused, the way a Finder
    /// item is - otherwise the first press after clicking in from another app
    /// is swallowed just to raise the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
        isDraggingCard = false
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingCard else { return }
        let dx = event.locationInWindow.x - pressLocation.x
        let dy = event.locationInWindow.y - pressLocation.y
        guard abs(dx) > Self.dragThreshold || abs(dy) > Self.dragThreshold else { return }
        isDraggingCard = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // A drag consumes the gesture, and its own `draggingSession(_:endedAt:
        // operation:)` is what clears the flag - so a release that gets here
        // with the flag set is a stale event, not a click.
        guard !isDraggingCard, event.clickCount == 1 else { return }
        onOpen?()
    }

    /// UI-27: the dragged card *lifts* - its drag image carries the raised
    /// elevation's shadow - and the card it left behind dims, so the board
    /// reads as "this card is moving" rather than as a ghost of it.
    private func beginDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: ShiftBoardPasteboard.item(taskID: taskID))
        let image = liftedSnapshot()
        let pad = Self.liftPadding
        item.setDraggingFrame(bounds.insetBy(dx: -pad, dy: -pad), contents: image)
        HelmMotion.fade(self, to: Self.draggingAlpha, duration: 0.12, animated: true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    static let liftPadding: CGFloat = 24
    static let draggingAlpha: CGFloat = 0.4

    /// The card, drawn into a padded image under `HelmCard.elevation`'s raised
    /// shadow - the same level a hovered module card takes.
    private func liftedSnapshot() -> NSImage? {
        guard let card = snapshot() else { return nil }
        let pad = Self.liftPadding
        let size = NSSize(width: bounds.width + pad * 2, height: bounds.height + pad * 2)
        let theme = ThemeManager.shared.theme
        return NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            HelmCard.elevation(for: theme, level: .raised).set()
            card.draw(in: NSRect(x: pad, y: pad, width: self.bounds.width, height: self.bounds.height))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// The app's own render idiom (`bitmapImageRepForCachingDisplay` +
    /// `cacheDisplay`) rather than a hand-drawn placeholder, so what the
    /// captain drags is literally the card they pressed.
    private func snapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Within this app only: a task id means nothing to anything else, and
        // offering `.copy` would imply a duplicate this board cannot make.
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingCard = false
        HelmMotion.fade(self, to: 1, duration: 0.12, animated: true)
    }

    // MARK: Pointer-free equivalents

    /// Every column except the one this card is already in.
    private var otherColumns: [ShiftBoardColumn] {
        ShiftBoardColumn.allCases.filter { $0 != currentColumn }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Task\u{2026}", action: #selector(menuOpen), keyEquivalent: "").withSymbol("arrow.up.forward.square")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        for column in otherColumns {
            let item = NSMenuItem(title: "Move to \(column.title)", action: #selector(menuMove(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // UX7's reschedule gesture, the same submenu the flat list's own row
        // menu carries - one gesture, offered wherever a task card is.
        let push = NSMenuItem(title: "Push to", action: nil, keyEquivalent: "").withSymbol("calendar.badge.clock")
        let pushMenu = NSMenu()
        for option in ShiftDuePush.allCases {
            let item = NSMenuItem(title: option.menuTitle, action: #selector(menuPush(_:)), keyEquivalent: "")
            item.representedObject = option.rawValue
            item.target = self
            pushMenu.addItem(item)
        }
        push.submenu = pushMenu
        menu.addItem(push)
        menu.addItem(.separator())
        // F7, and for the same reason "Push to" is here: the board is this
        // page's *default* view, so an action offered only on the flat list
        // is an action most captains never see. The list's rows carry the
        // 25-minute default on a visible button; a card's whole surface is
        // the drag handle, so here the menu is the gesture.
        let focus = NSMenuItem(title: "Focus for", action: nil, keyEquivalent: "").withSymbol("timer")
        let focusMenu = NSMenu()
        for minutes in FocusTimerEngine.durationChoices {
            let item = NSMenuItem(title: "\(minutes) minutes", action: #selector(menuFocus(_:)), keyEquivalent: "")
            item.representedObject = minutes
            item.target = self
            focusMenu.addItem(item)
        }
        focus.submenu = focusMenu
        menu.addItem(focus)
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete Task\u{2026}", action: #selector(menuDelete), keyEquivalent: "").withSymbol("trash")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    private func accessibilityMoves() -> [NSAccessibilityCustomAction] {
        otherColumns.map { column in
            NSAccessibilityCustomAction(name: "Move to \(column.title)") { [weak self] in
                self?.onMove?(column)
                return true
            }
        }
    }

    /// UX7, forwarded like every other card verb here.
    var onPushDue: ((ShiftDuePush) -> Void)?
    /// F7. Forwarded, never applied here - the same shape as `onPushDue`.
    var onStartFocus: ((Int) -> Void)?

    @objc private func menuFocus(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        onStartFocus?(minutes)
    }

    @objc private func menuPush(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = ShiftDuePush(rawValue: raw) else { return }
        onPushDue?(option)
    }

    @objc private func menuOpen() { onOpen?() }
    @objc private func menuDelete() { onDelete?() }

    @objc private func menuMove(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let column = ShiftBoardColumn(rawValue: raw) else { return }
        onMove?(column)
    }

    #if FM_SELFTESTS
    /// Whether a real press-then-move has actually started a drag session -
    /// the one thing a self-test cannot infer from the view's appearance.
    var debugIsDragging: Bool { isDraggingCard }
    var debugRow: HelmAccentRow { row }
    func debugLiftedSnapshotSize() -> NSSize? { liftedSnapshot()?.size }
    #endif
}

// MARK: - Drop target

/// A column's body: the drop half of the drag, following the three existing
/// drop zones in this app verbatim (`registerForDraggedTypes` plus the four
/// `NSDraggingDestination` overrides on a plain `NSView`).
///
/// Registered on the column's whole body rather than on the card stack, so a
/// drop into the empty space below the last card lands in the column rather
/// than falling through to nothing.
final class ShiftBoardDropView: NSView {

    /// `true` only while a card is genuinely hovering over this column.
    private(set) var isDropTargeted = false

    var column: ShiftBoardColumn = .backlog
    /// Returns whether the drop was actually applied, which is what
    /// `performDragOperation` reports back to AppKit.
    var onDropTask: ((String, ShiftBoardColumn) -> Bool)?
    var onDropTargetChanged: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([ShiftBoardPasteboard.taskType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    #if FM_SELFTESTS
    func debugSetTargeted(_ targeted: Bool) { setTargeted(targeted) }
    #endif

    private func setTargeted(_ targeted: Bool) {
        guard targeted != isDropTargeted else { return }
        isDropTargeted = targeted
        onDropTargetChanged?(targeted)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ShiftBoardPasteboard.taskID(from: sender.draggingPasteboard) != nil else { return [] }
        setTargeted(true)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }

    override func draggingEnded(_ sender: NSDraggingInfo) { setTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        guard let id = ShiftBoardPasteboard.taskID(from: sender.draggingPasteboard) else { return false }
        return onDropTask?(id, column) ?? false
    }
}

// MARK: - One column

/// One lane of the board.
///
/// **UI-21 (Q2, layout T-A): a lane is not a card.** It used to be a bordered
/// `HelmCard` holding bordered cards, on a page ground - nested outlines where
/// the mockup draws one. Now a lane is a grouping on the page ground: a
/// `HelmSectionHeader(.lane)` (dot, name, muted count, a quiet "+") over a
/// hairline, then the drop target holding the cards and a quiet "Add task".
/// The task cards are the only bordered surface on the board.
final class ShiftBoardColumnView: NSView {

    /// A fixed body height, so every column is the same height whatever it
    /// holds and a long pile scrolls inside its own card rather than making
    /// the whole page taller than its neighbours - the identical reason
    /// `ShiftController.taskFollowUpPanelBodyHeight` exists for the two list
    /// panels.
    ///
    /// The card area's bounds. Its actual height is set per render by
    /// `ShiftBoardView`, from how many cards the fullest column holds.
    ///
    /// **A fixed height was the thing the captain reacted to.** At a constant
    /// 420 every column was 515pt tall whatever it held, so a board with one
    /// card in two of its columns rendered two large empty voids and pushed
    /// the Follow-ups and Projects sections below it off the page.
    ///
    /// The floor keeps an *empty* column a real drop target rather than a
    /// sliver; the ceiling is what makes a long pile scroll inside its own
    /// card instead of making the page taller than the window.
    static let minBodyHeight: CGFloat = 96

    /// The ceiling, **derived from what `visibleRows` cards can actually be**
    /// rather than written down as a number.
    ///
    /// Review #3's B3: this was the literal 420, and the plan above it costs a
    /// card carrying a meta line at `cardRowHeightWithMeta` - so four of those
    /// plus their three gaps need 436, and the clamp sliced 16pt off the
    /// fourth card, cutting its priority chip. The plan was right; the cap
    /// was 16pt short of the plan's own worst case. A literal could not stay
    /// right either: both card heights go through `HelmType.scaledRowHeight`,
    /// so the gap widens again at the captain's "Larger" chrome text size.
    ///
    /// Computing the cap from the same two constants the plan uses is what
    /// makes "a full column shows `visibleRows` cards in full" true by
    /// construction at every text scale. It stays a *cap*: a column whose
    /// cards genuinely need more than this (a wrapped title, which no count
    /// can predict - see `applyBodyHeight`) still scrolls inside its own card
    /// rather than making the page taller than the window, which is the job
    /// this constant has always had.
    static var maxBodyHeight: CGFloat {
        let rows = CGFloat(ShiftBoardView.visibleRows)
        return ShiftBoardView.cardRowHeightWithMeta * rows + HelmMetrics.s2 * (rows - 1)
    }

    /// How many cards a column will actually build.
    ///
    /// A bound, not a product decision: these are permanent `NSStackView`
    /// arranged subviews, the shape this app has watched blow up into
    /// multi-second layout passes four times (see `DiffResultView.swift`'s
    /// header). Far beyond a usable board, and the remainder is **stated**
    /// rather than silently dropped - see `overflowLabel`.
    static let maxCards = 50

    /// The reference's own `.col-dot` is 8px.
    private static let dotSize: CGFloat = 8

    let column: ShiftBoardColumn

    /// The lane header: the kit's lane size - an 8pt dot (three tiles at the
    /// top of three lanes read as three buttons), the name, the count as
    /// muted text beside it, and a quiet "+" on the trailing edge (UI-25).
    private let header = HelmSectionHeader(size: .lane)
    private let headerRule = NSView()
    private let headerAdd = HelmButton(title: "", variant: .quiet, size: .small, symbol: "plus")
    private let dropView = ShiftBoardDropView()
    /// UI-27: the drop target's dashed outline, shown with the wash.
    private let dropOutline = CAShapeLayer()
    private let scroll = NSScrollView()
    private let cardsStack = NSStackView()
    private let overflowLabel = NSTextField(labelWithString: "")
    /// U1 of the review: "one empty-state shape ... pick `HelmEmptyState`
    /// everywhere". This column drew a bare centred `NSTextField` - "Nothing
    /// here." - while every other empty surface in the app draws a symbol,
    /// the page's own hue and a sentence. The action U1 also asks for is
    /// already here and always has been: `addButton` sits directly beneath,
    /// full width, so the column offers one without the empty state having to
    /// carry a second copy of it.
    ///
    /// `.compact`, because a board column is ~260pt wide and the standard
    /// size is written for a page.
    private let emptyState: HelmEmptyState
    /// UI-25: a quiet text button at the lane's foot, not a dashed box.
    private let addButton = HelmButton(title: "Add task", variant: .quiet, size: .small, symbol: "plus")

    private var cardViews: [ShiftBoardCardView] = []
    private var bodyHeight: NSLayoutConstraint?
    private var theme: HelmTheme = ThemeManager.shared.theme

    var onOpenTask: ((String) -> Void)?
    var onMoveTask: ((String, ShiftBoardColumn) -> Void)?
    var onDeleteTask: ((String) -> Void)?
    /// UX7's reschedule gesture, forwarded up with the task's id like every
    /// other card verb here.
    var onPushTaskDue: ((String, ShiftDuePush) -> Void)?
    /// F7, forwarded up to `ShiftController` exactly as `onPushTaskDue` is.
    var onStartFocusTask: ((String, Int) -> Void)?
    var onAddTask: ((ShiftBoardColumn) -> Void)?
    /// Returns whether the drop changed anything - forwarded straight to
    /// `performDragOperation`'s own return value.
    var onDropTask: ((String, ShiftBoardColumn) -> Bool)?

    init(column: ShiftBoardColumn) {
        self.column = column
        // Each column says what *it* is empty of. "Nothing here" three times
        // across a board is three labels that could be anywhere; the Done
        // column in particular is not a gap to fill but a normal state.
        // UI-26: the quiet card-level state - one caption, no tile - with
        // copy that names the lane properly ("Nothing in progress", never
        // "Nothing in in progress yet").
        emptyState = HelmEmptyState(symbol: column.symbol, body: Self.emptyCopy(for: column), size: .quiet)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func emptyCopy(for column: ShiftBoardColumn) -> String {
        switch column {
        case .backlog: return "Nothing in the backlog"
        case .inProgress: return "Nothing in progress"
        case .done: return "Completed tasks from the last 7 days land here."
        }
    }

    private func build() {
        header.configure(leading: .dot(column.tint), title: column.title, count: "0")
        headerAdd.toolTip = "Add a task to \(column.title)"
        headerAdd.setAccessibilityLabel("Add a task to \(column.title)")
        headerAdd.target = self
        headerAdd.action = #selector(addTapped)
        // The Done lane takes no new task - a task is finished by moving it
        // there, not created there.
        header.setActions(column == .done ? [] : [headerAdd])
        headerRule.wantsLayer = true
        headerRule.translatesAutoresizingMaskIntoConstraints = false

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = HelmMetrics.s2
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        // `FlippedView` (AGENTS.md gotcha (9)): an unflipped document view
        // shorter than the viewport rests against the *bottom* of the clip
        // view, so a lane with two cards would show them floating at the
        // bottom under a blank gap.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(cardsStack)
        NSLayoutConstraint.activate([
            cardsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: document.topAnchor),
            cardsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // The body's height is a real constant, recomputed from the cards'
        // own laid-out frames - see `applyBodyHeight`. Tying the scroll
        // view's height to its document's is vacuous: `NSScrollView` stretches
        // a short document to fill the clip view.
        bodyHeight = scroll.heightAnchor.constraint(equalToConstant: Self.minBodyHeight)
        bodyHeight?.isActive = true

        overflowLabel.font = HelmType.captionSmall()

        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.toolTip = "Add a task to \(column.title)"
        addButton.isHidden = column == .done

        dropView.column = column
        dropView.wantsLayer = true
        dropView.layer?.cornerRadius = HelmMetrics.rRow
        dropOutline.fillColor = NSColor.clear.cgColor
        dropOutline.lineWidth = 1
        dropOutline.lineDashPattern = [4, 3]
        dropOutline.isHidden = true
        dropView.layer?.addSublayer(dropOutline)
        dropView.onDropTask = { [weak self] id, column in self?.onDropTask?(id, column) ?? false }
        dropView.onDropTargetChanged = { [weak self] _ in self?.applyDropHighlight() }

        let body = NSStackView(views: [scroll, overflowLabel, addButton])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(body)
        dropView.addSubview(emptyState)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            body.topAnchor.constraint(equalTo: dropView.topAnchor),
            body.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: -HelmMetrics.s1),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            overflowLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            emptyState.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
        ])

        for view in [header, headerRule, dropView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            headerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s2),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
            dropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropView.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: HelmMetrics.s3),
            dropView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func addTapped() { onAddTask?(column) }

    override func layout() {
        super.layout()
        applyBodyHeight()
        HelmMotion.withoutImplicitAnimation {
            dropOutline.frame = dropView.bounds
            dropOutline.path = CGPath(roundedRect: dropView.bounds.insetBy(dx: 0.5, dy: 0.5),
                                      cornerWidth: HelmMetrics.rRow, cornerHeight: HelmMetrics.rRow,
                                      transform: nil)
        }
    }

    /// Rebuilds this column's cards. Called on every board render - the cards
    /// are cheap (`HelmAccentRow` is handed its theme rather than observing
    /// one, so a rebuilt card registers nothing), and the bounded count is
    /// what keeps the stack-of-permanent-rows shape safe here.
    func setTasks(_ tasks: [ShiftTask], projects: [String: ShiftProject], theme: HelmTheme) {
        self.theme = theme
        for view in cardsStack.arrangedSubviews {
            cardsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cardViews.removeAll()

        for task in tasks.prefix(Self.maxCards) {
            let cardView = ShiftBoardCardView()
            cardView.configure(task: task,
                               project: task.projectID.flatMap { projects[$0] },
                               column: column,
                               theme: theme)
            cardView.onOpen = { [weak self] in self?.onOpenTask?(task.id) }
            cardView.onMove = { [weak self] target in self?.onMoveTask?(task.id, target) }
            cardView.onDelete = { [weak self] in self?.onDeleteTask?(task.id) }
            cardView.onPushDue = { [weak self] option in self?.onPushTaskDue?(task.id, option) }
            cardView.onStartFocus = { [weak self] minutes in self?.onStartFocusTask?(task.id, minutes) }
            cardsStack.addArrangedSubview(cardView)
            cardView.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
            cardViews.append(cardView)
        }

        header.countLabel.stringValue = "\(tasks.count)"
        let hidden = max(0, tasks.count - Self.maxCards)
        overflowLabel.isHidden = hidden == 0
        overflowLabel.stringValue = hidden == 0
            ? ""
            : "+\(hidden) more \u{2013} switch to List view to see them all."
        emptyState.isHidden = !tasks.isEmpty
        needsLayout = true

        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        header.applyTheme(theme)
        headerRule.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(theme.isDaylight ? 1 : HelmCard.borderAlpha).cgColor
        overflowLabel.textColor = HelmTheme.mutedInk(theme)
        emptyState.applyTheme(theme)
        for cardView in cardViews { cardView.applyTheme(theme) }
        applyDropHighlight()
    }

    /// UI-27: while a card is over this lane the whole lane takes a wash of
    /// the accent and a dashed outline, so the target is unmistakable rather
    /// than a faint tint - and both go the instant the drag leaves.
    private func applyDropHighlight() {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let targeted = dropView.isDropTargeted
        HelmMotion.withoutImplicitAnimation {
            dropView.layer?.backgroundColor = targeted
                ? accent.withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
            dropOutline.strokeColor = accent.withAlphaComponent(0.7).cgColor
            dropOutline.isHidden = !targeted
        }
    }

    /// Sets the card area's height. Driven by `ShiftBoardView`, which sizes
    /// every column to the fullest one - see its own `setTasks`.
    func setBodyHeight(_ height: CGFloat) {
        plannedBodyHeight = height
        applyBodyHeight()
    }

    /// The planned height from the card *count*, raised to what the cards
    /// actually occupy once they have been laid out.
    ///
    /// Both halves are needed, and each fixes something the other cannot. The
    /// count is what makes the first render right with no settling pass - a
    /// frames-only version measured a column a whole render behind its own
    /// content. The frames are what stop a card whose title wrapped onto a
    /// second line being sliced through the middle, because the count cannot
    /// know which cards wrapped.
    ///
    /// Only ever raises, never lowers, so this converges: growing the body
    /// does not change a card's width and therefore does not change its
    /// height, so the second pass is the last one. Without the epsilon guard
    /// a sub-point difference would schedule another pass forever - the same
    /// shape `BriefingParagraphView`'s own self-sizing uses.
    private func applyBodyHeight() {
        guard let bodyHeight else { return }
        let measured = cardViews.reduce(CGFloat(0)) { $0 + $1.frame.height }
            + cardsStack.spacing * CGFloat(max(0, cardViews.count - 1))
        let desired = min(max(plannedBodyHeight, measured), Self.maxBodyHeight)
        if abs(bodyHeight.constant - desired) > 0.5 { bodyHeight.constant = desired }
    }

    private var plannedBodyHeight: CGFloat = ShiftBoardColumnView.minBodyHeight

    #if FM_SELFTESTS
    var debugCardViews: [ShiftBoardCardView] { cardViews }
    var debugCountText: String { header.countLabel.stringValue }
    var debugHeader: HelmSectionHeader { header }
    var debugAddButton: HelmButton { addButton }
    var debugDropOutlineVisible: Bool { !dropOutline.isHidden }
    func debugSetDropTargeted(_ targeted: Bool) { dropView.debugSetTargeted(targeted) }
    var debugOverflowText: String { overflowLabel.isHidden ? "" : overflowLabel.stringValue }
    var debugDropView: ShiftBoardDropView { dropView }
    var debugScrollHeight: CGFloat { scroll.frame.height }
    /// U1: the column's empty state, which is a `HelmEmptyState` now rather
    /// than a bare centred label. `isMounted` for the reason X9 measured -
    /// a view built and never added still has a frame.
    var debugEmptyState: (view: HelmEmptyState, isShowing: Bool, isMounted: Bool, frame: NSRect) {
        (emptyState, !emptyState.isHidden, emptyState.isDescendant(of: self),
         emptyState.convert(emptyState.bounds, to: self))
    }
    #endif
}

// MARK: - The board

/// The three columns side by side.
///
/// A plain `.fillEqually` horizontal stack: three fixed columns is not a
/// wrapping grid, so `HelmResponsiveGrid`'s column-count-from-width machinery
/// would be answering a question this layout does not ask.
final class ShiftBoardView: NSView {

    private let columnViews: [ShiftBoardColumnView]
    private let row = NSStackView()

    var onOpenTask: ((String) -> Void)?
    var onMoveTask: ((String, ShiftBoardColumn) -> Void)?
    var onDeleteTask: ((String) -> Void)?
    /// UX7's reschedule gesture, forwarded up with the task's id like every
    /// other card verb here.
    var onPushTaskDue: ((String, ShiftDuePush) -> Void)?
    /// F7, forwarded up to `ShiftController` exactly as `onPushTaskDue` is.
    var onStartFocusTask: ((String, Int) -> Void)?
    var onAddTask: ((ShiftBoardColumn) -> Void)?
    var onDropTask: ((String, ShiftBoardColumn) -> Bool)?

    override init(frame frameRect: NSRect) {
        columnViews = ShiftBoardColumn.allCases.map(ShiftBoardColumnView.init(column:))
        super.init(frame: frameRect)
        var lanes: [NSStackView] = []
        translatesAutoresizingMaskIntoConstraints = false

        for column in columnViews {
            column.onOpenTask = { [weak self] id in self?.onOpenTask?(id) }
            column.onMoveTask = { [weak self] id, target in self?.onMoveTask?(id, target) }
            column.onDeleteTask = { [weak self] id in self?.onDeleteTask?(id) }
            column.onPushTaskDue = { [weak self] id, option in self?.onPushTaskDue?(id, option) }
            column.onStartFocusTask = { [weak self] id, minutes in self?.onStartFocusTask?(id, minutes) }
            column.onAddTask = { [weak self] target in self?.onAddTask?(target) }
            column.onDropTask = { [weak self] id, target in self?.onDropTask?(id, target) ?? false }
            // Each column goes into the row inside a vertical stack of its
            // own rather than directly.
            //
            // Measured, not assumed: put straight into a horizontal
            // `.fillEqually` row, every column came out the height of the
            // tallest one (all three at 305pt with one holding a single 81pt
            // card), which is what produced the large empty voids the captain
            // reacted to - `alignment = .top` pins the tops but does not stop
            // the stretch. A vertical stack hugs its content vertically, so
            // the slack lands *below* the column instead of inside it. This is
            // the same wrapper `ShiftController.tasksRow` already puts around
            // its own two panels, for the same reason.
            let lane = NSStackView(views: [column])
            lane.orientation = .vertical
            lane.alignment = .leading
            lane.translatesAutoresizingMaskIntoConstraints = false
            // The stack-level hugging API, not the content-level one - a
            // stack has no intrinsic content size, so
            // `setContentHuggingPriority` on it is a documented no-op
            // (AGENTS.md gotcha (12)). Without this the lane does not resist
            // being stretched to the row's height and the column inside it
            // comes along, which is the whole reason the wrapper exists.
            // `.required` is safe here precisely because the row is
            // `.top`-aligned: it pins the lanes' tops and never their
            // bottoms, so hugging to content can never be unsatisfiable. It
            // is a hugging priority, which only ever pulls a view *smaller*,
            // so it cannot make the window bigger either (gotcha (13)).
            lane.setHuggingPriority(.required, for: .vertical)
            row.addArrangedSubview(lane)
            column.widthAnchor.constraint(equalTo: lane.widthAnchor).isActive = true
            if let first = lanes.first {
                lane.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
            }
            lanes.append(lane)
        }
        row.orientation = .horizontal
        // `.fill` plus explicit equal-width ties between the lanes, not
        // `.fillEqually`: measured, `.fillEqually` equalised the columns'
        // *height* as well as their width, so a column holding one card came
        // out as tall as the fullest one and rendered a large empty void -
        // which is what the captain reacted to. Equal widths are what this
        // row actually needs; equal heights are exactly what a board must not
        // have.
        row.distribution = .fill
        row.alignment = .top
        // 16 between lanes - with no card around a lane, the gap is what
        // separates them.
        row.spacing = HelmMetrics.s4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // A column's own content must never become a floor on the window's
        // width - AGENTS.md gotchas (12)/(13). A stack resists clipping at
        // `.defaultHigh` (750) by default, which is above
        // `NSLayoutPriorityWindowSizeStayPut` (500), so three of them in a
        // `.fillEqually` row would multiply into a real minimum width for the
        // whole app.
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setTasks(_ byColumn: [ShiftBoardColumn: [ShiftTask]],
                  projects: [ShiftProject],
                  theme: HelmTheme) {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for columnView in columnViews {
            columnView.setTasks(byColumn[columnView.column] ?? [], projects: byID, theme: theme)
        }

        // One height for all three columns, sized to whichever holds the most
        // cards - so a sparse board is short and a busy one scrolls, and the
        // three are never ragged against each other.
        //
        // Derived from the card count rather than from the cards' laid-out
        // frames, deliberately. Reading frames means assigning a constraint
        // constant from inside `layout()`, which needs a settling pass to
        // converge - measured, that left a column a whole render behind its
        // own content. A count is known the instant the data is.
        //
        // **The plan is content-aware, not a flat card count, and that is what
        // stops a card being sliced in half.** A card carries a meta line only
        // when the task has a due date or subtasks (see `configure`'s `bits`),
        // and that line is real height: measured, 82pt without it and 103pt
        // with. Costing every card at 82 under-counted a four-card column by
        // 21pt, so the fourth card rendered cut through its own priority pill -
        // visible on the captain's own board, in every theme.
        //
        // The frame-based raise in `ShiftBoardColumnView.applyBodyHeight` is
        // meant to be the safety net for that, and cannot be: a view's
        // `layout()` runs before its own descendants get their frames, so the
        // first pass measures zero, and nothing marks the column dirty again
        // afterwards (`layoutSubtreeIfNeeded` only descends into views already
        // flagged `needsLayout`). It stays as the net for a *wrapped title*,
        // which no count can predict - but the ordinary case has to be right
        // from the count, with no settling pass, exactly as the paragraph
        // above says.
        let planned = byColumn.values.map { Self.plannedBodyHeight(for: $0) }.max()
            ?? ShiftBoardColumnView.minBodyHeight
        let height = min(max(planned, ShiftBoardColumnView.minBodyHeight),
                         ShiftBoardColumnView.maxBodyHeight)
        for columnView in columnViews { columnView.setBodyHeight(height) }
    }

    /// The height one column needs to show its first `visibleRows` cards in
    /// full - the sum of what each of those cards will really be, not a flat
    /// card count times one average.
    ///
    /// Mirrors `ShiftBoardCardView.configure`'s own rule for whether a card
    /// gets a meta line, so the two cannot disagree about what a card costs.
    static func plannedBodyHeight(for tasks: [ShiftTask]) -> CGFloat {
        let rows = min(max(tasks.count, 1), visibleRows)
        let heights = tasks.prefix(rows).map { cardHeight(for: $0) }
        // An empty column still reserves one row, so the three stay level.
        let content = heights.isEmpty ? cardRowHeight : heights.reduce(0, +)
        return content + HelmMetrics.s2 * CGFloat(rows - 1)
    }

    /// One card's height: the taller shape when the task has something to put
    /// on its meta line, the plain one otherwise.
    static func cardHeight(for task: ShiftTask) -> CGFloat {
        guard cardHasMetaLine(task) else { return cardRowHeight }
        // The pill is taller than a caption, so a meta line carrying the
        // High pill costs more than one carrying only words.
        return ShiftTaskSignals.priorityPill(task.priority) != nil ? cardRowHeightWithMeta : cardRowHeightWithCaption
    }

    /// Mirrors `ShiftBoardCardView.configure`: a card has a meta line when it
    /// has a due date, subtasks, a priority that is not Normal (the pill or
    /// the "Low" word), or - in the Done lane - its completion date.
    static func cardHasMetaLine(_ task: ShiftTask) -> Bool {
        task.dueDate != nil || !task.subtasks.isEmpty || task.priority != .normal
            || task.status == .completed
    }

    /// How many cards a column shows before it scrolls. Four is what the
    /// captain's reference shows in its own fullest column.
    static let visibleRows = 4

    /// One card's height at the usual column width.
    ///
    /// **Re-measured for the UI/UX revamp's `.cardFlat` card (UI-22)**:
    /// 10/12 padding, the kicker over the title, and the chip on the meta line
    /// rather than on a line of its own. `TextScaleRowHeightSelfTest`
    /// measures the real card at every chrome text scale - 53pt at Default -
    /// and this carries one point over it for the Daylight family, which sets
    /// the same row a point taller than the legacy palettes do (the lesson the
    /// previous 81 -> 82 recorded). Run through `scaledRowHeight` (GL-32).
    static var cardRowHeight: CGFloat { HelmType.scaledRowHeight(55) }

    /// The same card once it carries a meta line (a due caption, subtasks, a
    /// priority that is not Normal, or a Done date) - measured the same way,
    /// 79pt at Default, plus the same one point.
    static var cardRowHeightWithMeta: CGFloat { HelmType.scaledRowHeight(81) }

    /// A card whose meta line holds only words (a due caption, subtasks,
    /// "Low"): 74pt measured at Default, plus the Daylight point.
    static var cardRowHeightWithCaption: CGFloat { HelmType.scaledRowHeight(75) }

    func applyTheme(_ theme: HelmTheme) {
        for columnView in columnViews { columnView.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugColumns: [ShiftBoardColumnView] { columnViews }
    func debugColumn(_ column: ShiftBoardColumn) -> ShiftBoardColumnView? {
        columnViews.first { $0.column == column }
    }
    #endif
}

// MARK: - Project filter chips

/// The board's "All projects | <project> | <project> …" filter row.
///
/// Deliberately `HelmButton` chips rather than a new component: this is
/// byte-for-byte the shape `HostsController`'s own tag-chip filter already
/// uses (`.pushOnPushOff`, `variant` carrying the selected state because the
/// stock bezel's on-state no longer exists), with one addition - a
/// `circle.fill` glyph tinted with the project's own colour, so a chip and
/// the cards it filters to carry the same marker.
final class ShiftProjectFilterBar: NSView {

    /// `nil` means "All projects".
    private(set) var selectedProjectID: String?

    var onSelect: ((String?) -> Void)?

    private let stack = NSStackView()
    private var chips: [(id: String?, button: HelmButton)] = []
    private var projects: [ShiftProject] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setProjects(_ projects: [ShiftProject], theme: HelmTheme) {
        self.projects = projects
        // A filter pinned to a project that has since gone away would hide
        // every task with no way to tell why.
        if let selected = selectedProjectID, !projects.contains(where: { $0.id == selected }) {
            selectedProjectID = nil
        }
        rebuild(theme: theme)
    }

    /// Move the chip without firing `onSelect` - what the sidebar's own
    /// project rows want when they are the control that moved, and the same
    /// split `HelmSegmentedTabs.select(_:)` and `HelmPageSidebar.select(_:)`
    /// already draw.
    func select(_ projectID: String?) {
        guard projectID != selectedProjectID else { return }
        selectedProjectID = projectID
        rebuild(theme: ThemeManager.shared.theme)
    }

    private func rebuild(theme: HelmTheme) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chips.removeAll()

        addChip(id: nil, title: "All projects", tint: .neutral)
        for project in projects {
            addChip(id: project.id,
                    title: project.name.isEmpty ? "Untitled project" : project.name,
                    tint: ShiftProjectPalette.tint(forProjectID: project.id))
        }
        applyTheme(theme)
    }

    private func addChip(id: String?, title: String, tint: HelmTint) {
        let selected = id == selectedProjectID
        let button = HelmButton(title: title,
                                variant: selected ? .primary : .secondary,
                                size: .small,
                                symbol: "circle.fill",
                                target: self,
                                action: #selector(chipClicked(_:)))
        // Only meaningful on the unselected `.secondary`/`.quiet` variants,
        // where `tint` colours the label and the glyph; a `.primary` chip is
        // already an accent fill saying "this filter is on", and `tint` is
        // ignored there by `HelmButton.palette`.
        button.tint = selected ? nil : tint
        button.identifier = NSUserInterfaceItemIdentifier(id ?? "")
        stack.addArrangedSubview(button)
        chips.append((id, button))
    }

    @objc private func chipClicked(_ sender: NSButton) {
        let raw = sender.identifier?.rawValue ?? ""
        let tapped: String? = raw.isEmpty ? nil : raw
        // Clicking the active project chip clears the filter, matching the
        // mockup's own toggle behaviour. "All projects" is never a toggle -
        // clicking it always means "show everything".
        selectedProjectID = (tapped != nil && tapped == selectedProjectID) ? nil : tapped
        rebuild(theme: ThemeManager.shared.theme)
        onSelect?(selectedProjectID)
    }

    func applyTheme(_ theme: HelmTheme) {
        for chip in chips {
            chip.button.variant = chip.id == selectedProjectID ? .primary : .secondary
            chip.button.tint = chip.id == selectedProjectID
                ? nil
                : ShiftProjectPalette.tint(forProjectID: chip.id)
        }
    }

    #if FM_SELFTESTS
    var debugChipTitles: [String] { chips.map { $0.button.title } }
    func debugClickChip(projectID: String?) {
        guard let chip = chips.first(where: { $0.id == projectID }) else { return }
        chip.button.performClick(nil)
    }
    #endif
}
