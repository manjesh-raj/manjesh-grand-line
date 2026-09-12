// Manjesh Grand Line - native macOS app.
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
    static let taskType = NSPasteboard.PasteboardType("com.firstmate.cockpit.shift.task-id")

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
    private let row = HelmAccentRow(chipPlacement: .belowBody)

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

        let (priorityText, priorityTint): (String, HelmTint) = {
            switch task.priority {
            case .high: return ("High", .critical)
            case .normal: return ("Normal", .info)
            case .low: return ("Low", .neutral)
            }
        }()

        var bits: [String] = []
        if let due = task.dueDate { bits.append(ShiftDateFormatting.friendly(due)) }
        if !task.subtasks.isEmpty {
            let done = task.subtasks.filter(\.done).count
            bits.append("\(done)/\(task.subtasks.count) subtasks")
        }

        row.configure(HelmAccentRow.Content(
            // The bar carries **project identity** here, not the priority the
            // flat list's bar carries - that is the whole point of the board's
            // colour coding, and the priority is still stated in words by the
            // chip directly below it.
            tint: ShiftProjectPalette.tint(forProjectID: task.projectID),
            kicker: project?.name ?? "No project",
            title: task.title,
            meta: bits.joined(separator: " \u{00B7} "),
            titleAccessorySymbol: task.hasAttachment ? "paperclip" : nil,
            chipText: priorityText,
            chipTint: priorityTint,
            // A column is ~260-340pt wide; a one-line truncating title would
            // hide most of a real task's name.
            titleWraps: true
        ), theme: theme)

        setAccessibilityLabel("\(task.title), \(column.title), \(priorityText) priority")
        menu = buildMenu()
        setAccessibilityCustomActions(accessibilityMoves())
    }

    func applyTheme(_ theme: HelmTheme) { row.applyTheme(theme) }

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

    private func beginDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: ShiftBoardPasteboard.item(taskID: taskID))
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
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
    #endif
}

// MARK: - "+ Add task"

/// A column's own add affordance: a full-width, centred, dashed-outline
/// button spanning the bottom of the column.
///
/// The captain asked for exactly this shape after seeing the first pass,
/// which used a small `HelmButton(symbol: "plus")` hugging the column's
/// leading edge - at the bottom of a mostly-empty column that reads as a
/// stray glyph rather than as "drop a new card here". A dashed outline is
/// also the one border style in this app that says "nothing here yet", which
/// is what the space below the last card is.
///
/// `HoverHighlightView` with its own click recognizer, not `HelmButton`: a
/// `HelmButton` owns its fill, its border and its label colour (`restyle()`
/// overwrites all three on the next theme change), so a dashed outline would
/// have to fight it. The `HoverHighlightView` route is the app's established
/// one for a clickable styled region - `UpdatesController`'s Refresh pill and
/// `SettingsController`'s theme cards are the same shape - and GL-16 gives it
/// the `.button` role, the accessibility label, the focus ring and
/// Return/Space activation for free.
final class ShiftBoardAddCardView: HoverHighlightView {

    static let height: CGFloat = 34

    private let label = NSTextField(labelWithString: "+ Add task")
    /// `CALayer` has no dashed-border property, so the outline is its own
    /// shape layer, re-pathed on every `layout()` - a path set once would
    /// stay at the width the column happened to be built at.
    private let dash = CAShapeLayer()

    var onAdd: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rControl

        dash.fillColor = NSColor.clear.cgColor
        dash.lineWidth = 1
        dash.lineDashPattern = [4, 3]
        layer?.addSublayer(dash)

        label.font = HelmType.caption()
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
        toolTip = "Add a task to this column"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        // Inset by half the line width, or the stroke is clipped in half by
        // the layer's own bounds.
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: HelmMetrics.rControl,
                           cornerHeight: HelmMetrics.rControl,
                           transform: nil)
    }

    func applyTheme(_ theme: HelmTheme) {
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        dash.strokeColor = line.withAlphaComponent(0.8).cgColor
        label.textColor = HelmTheme.mutedInk(theme)
        normalColor = .clear
        hoverColor = line.withAlphaComponent(0.18)
    }

    @objc private func clicked() { onAdd?() }
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

/// One column of the board: a `HelmCard` whose header carries the column's
/// name and live count, and whose body is a drop target holding a scrolling
/// stack of cards plus that column's own "+ Add task".
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
    static let maxBodyHeight: CGFloat = 420

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

    private let card = HelmCard()
    /// The reference's `.col-dot`: a small filled circle, not this app's
    /// usual `IconTileView`. A 26pt tinted tile with a glyph in it is right
    /// for a page section's heading; at the top of a board column, three of
    /// them read as three buttons. The dot says the same thing (which pile
    /// this is) at a fraction of the weight.
    private let columnDot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let countPill = NSView()
    private let dropView = ShiftBoardDropView()
    private let scroll = NSScrollView()
    private let cardsStack = NSStackView()
    private let overflowLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let addButton = ShiftBoardAddCardView()

    private var cardViews: [ShiftBoardCardView] = []
    private var bodyHeight: NSLayoutConstraint?
    private var theme: HelmTheme = ThemeManager.shared.theme

    var onOpenTask: ((String) -> Void)?
    var onMoveTask: ((String, ShiftBoardColumn) -> Void)?
    var onDeleteTask: ((String) -> Void)?
    var onAddTask: ((ShiftBoardColumn) -> Void)?
    /// Returns whether the drop changed anything - forwarded straight to
    /// `performDragOperation`'s own return value.
    var onDropTask: ((String, ShiftBoardColumn) -> Bool)?

    init(column: ShiftBoardColumn) {
        self.column = column
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        columnDot.wantsLayer = true
        columnDot.translatesAutoresizingMaskIntoConstraints = false
        columnDot.layer?.cornerRadius = Self.dotSize / 2
        NSLayoutConstraint.activate([
            columnDot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            columnDot.heightAnchor.constraint(equalToConstant: Self.dotSize),
        ])
        titleLabel.font = HelmType.rowTitle()
        titleLabel.stringValue = column.title
        countLabel.font = HelmType.metric(11, weight: .medium)

        countPill.wantsLayer = true
        countPill.layer?.cornerRadius = HelmMetrics.rChip
        countPill.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countPill.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: countPill.leadingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: countPill.trailingAnchor, constant: -6),
            countLabel.topAnchor.constraint(equalTo: countPill.topAnchor, constant: 2),
            countLabel.bottomAnchor.constraint(equalTo: countPill.bottomAnchor, constant: -2),
        ])
        countPill.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [columnDot, titleLabel, countPill, spacer])
        header.orientation = .horizontal
        header.spacing = HelmMetrics.s2
        // `.centerY`, not `.firstBaseline`: the icon tile and the count pill
        // are plain views with no text baseline, and baseline alignment drops
        // the pill onto its own line - the same live-caught fix
        // `ShiftController.sectionHeaderRow` records.
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = HelmMetrics.s2
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        // `FlippedView` (AGENTS.md gotcha (9)): an unflipped document view
        // shorter than the viewport rests against the *bottom* of the clip
        // view, so a column with two cards would show them floating at the
        // bottom under a blank gap.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(cardsStack)
        NSLayoutConstraint.activate([
            cardsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: document.topAnchor),
            // `==`, so the document's own height *is* the stack's - which is
            // what lets the scroll view below size itself to its content.
            cardsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // The body's height is a real constant, recomputed from the cards'
        // own laid-out frames - see `recomputeBodyHeight`.
        //
        // The obvious alternative - tying the scroll view's height to its
        // document view's - is **vacuous**, measured rather than reasoned
        // about: `NSScrollView` stretches a document view shorter than its
        // clip view to fill it, so `document.height` follows the clip, the
        // constraint is satisfied at any height, and every column came out
        // the height of the fullest one.
        bodyHeight = scroll.heightAnchor.constraint(equalToConstant: Self.minBodyHeight)
        bodyHeight?.isActive = true

        emptyLabel.font = HelmType.caption()
        emptyLabel.alignment = .center
        overflowLabel.font = HelmType.captionSmall()

        addButton.onAdd = { [weak self] in self?.addClicked() }

        dropView.column = column
        dropView.wantsLayer = true
        dropView.layer?.cornerRadius = HelmMetrics.rControl
        dropView.onDropTask = { [weak self] id, column in self?.onDropTask?(id, column) ?? false }
        dropView.onDropTargetChanged = { [weak self] _ in self?.applyDropHighlight() }

        let body = NSStackView(views: [scroll, overflowLabel, addButton])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(body)
        dropView.addSubview(emptyLabel)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: HelmMetrics.s2),
            body.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -HelmMetrics.s2),
            body.topAnchor.constraint(equalTo: dropView.topAnchor, constant: HelmMetrics.s2),
            body.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: -HelmMetrics.s2),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            overflowLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            // Full width, not hugging the leading edge - see
            // `ShiftBoardAddCardView`'s own header.
            addButton.widthAnchor.constraint(equalTo: body.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: dropView.leadingAnchor, constant: HelmMetrics.s3),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: dropView.trailingAnchor, constant: -HelmMetrics.s3),
        ])

        card.setHeader(header)
        card.setBody(dropView)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
            cardsStack.addArrangedSubview(cardView)
            cardView.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
            cardViews.append(cardView)
        }

        countLabel.stringValue = "\(tasks.count)"
        let hidden = max(0, tasks.count - Self.maxCards)
        overflowLabel.isHidden = hidden == 0
        overflowLabel.stringValue = hidden == 0
            ? ""
            : "+\(hidden) more \u{2013} switch to List view to see them all."
        emptyLabel.isHidden = !tasks.isEmpty
        needsLayout = true
        emptyLabel.stringValue = column == .done ? "Nothing finished recently." : "Nothing here."
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        // A hue as a *fill* is always safe (it is never text) - the rule
        // `HelmContrast` states, and the reason this needs no correction.
        columnDot.layer?.backgroundColor = HelmTheme.nsColor(column.tint.hex(in: theme)).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        countLabel.textColor = HelmTheme.mutedInk(theme)
        countPill.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeInkHex)
            .withAlphaComponent(0.08).cgColor
        overflowLabel.textColor = HelmTheme.mutedInk(theme)
        emptyLabel.textColor = HelmTheme.mutedInk(theme)
        addButton.applyTheme(theme)
        for cardView in cardViews { cardView.applyTheme(theme) }
        applyDropHighlight()
    }

    /// A wash of the theme accent while a card is over this column. Painted
    /// on the drop view's own layer rather than on the card, so the highlight
    /// reads as "this pile will take it" and disappears the instant the drag
    /// leaves.
    private func applyDropHighlight() {
        dropView.layer?.backgroundColor = dropView.isDropTargeted
            ? HelmTheme.nsColor(theme.accentHex).withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    private func addClicked() { onAddTask?(column) }

    /// Sets the card area's height. Driven by `ShiftBoardView`, which sizes
    /// every column to the fullest one - see its own `setTasks`.
    func setBodyHeight(_ height: CGFloat) {
        plannedBodyHeight = height
        applyBodyHeight()
    }

    override func layout() {
        super.layout()
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
    var debugCountText: String { countLabel.stringValue }
    var debugOverflowText: String { overflowLabel.isHidden ? "" : overflowLabel.stringValue }
    var debugDropView: ShiftBoardDropView { dropView }
    var debugScrollHeight: CGFloat { scroll.frame.height }
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
        row.spacing = HelmMetrics.s3
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
        let fullest = byColumn.values.map(\.count).max() ?? 0
        let rows = min(max(fullest, 1), Self.visibleRows)
        let row = ShiftBoardView.cardRowHeight
        let content = row * CGFloat(rows) + HelmMetrics.s2 * CGFloat(rows - 1)
        let height = min(max(content, ShiftBoardColumnView.minBodyHeight),
                         ShiftBoardColumnView.maxBodyHeight)
        for columnView in columnViews { columnView.setBodyHeight(height) }
    }

    /// How many cards a column shows before it scrolls. Four is what the
    /// captain's reference shows in its own fullest column.
    static let visibleRows = 4

    /// One card's height at the usual column width.
    ///
    /// Measured (81pt for the reference's own three stacked pieces - project
    /// line, title, priority badge - plus the card's padding), not guessed,
    /// and run through `scaledRowHeight` so it grows with the captain's
    /// chrome text-size setting the way every other fixed row height in this
    /// app does (GL-32). A card whose title wraps onto a second line is
    /// taller than this, which is exactly what the column's own scroll view
    /// is for.
    static var cardRowHeight: CGFloat { HelmType.scaledRowHeight(81) }

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
