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

/// A project's identity colour, for the card bars, the dots, the filter chips
/// and the calendar's project categories.
///
/// **Version 2.0.0 (S13 of the 2026-11-17 UI/UX proposals).** Version 1 hashed
/// the project id onto six *semantic* tints (accent, info, violet, good, warn,
/// critical). With three projects two shared a hue 44% of the time, and a
/// project could wear the overdue red or the warning amber, so a project tag
/// beside "Overdue 2 days" read as a second alert. Measured in the scout's two
/// tours: Daylight gave "Infra hardening" `BC4142`, which is also the `bad`
/// token, and Dusk gave two of three projects the same amber.
///
/// Now:
///
///   - **The identity set is the categorical ramp**, `HelmDomainHue`'s seven
///     §2.2 hues read through `categoricalHex`. That set was already measured
///     for separation as a set across all 26 palettes
///     (`DaylightBarIconTileSelfTest.checkEveryPaletteKeepsTheHuesApart`),
///     and none of its values is a theme's status token, so a project can
///     never borrow `bad` or `warn`.
///   - **The colour is stored on the project** (`ShiftProject.hue`).
///     `ShiftStore.addProject` assigns the first hue no other project wears,
///     and the project sheet can change it.
///   - **The hash is the fallback** for a record written before the field
///     existed. It is FNV-1a over the id's UTF-8 bytes, never
///     `String.hashValue`, which Swift seeds per process.
///
/// Breaking against 1.x: `tint(forProjectID:)` and `tints` are gone, because a
/// stored colour cannot be resolved from an id alone. Callers ask with the
/// project (or with the id and the store's project list) and get a hex.
enum ShiftProjectPalette {

    /// The identity hues, in the order new projects take them. `.slate` is
    /// last: it is the quietest, and it must still read apart from a task
    /// with no project, which takes page ink (`noProjectHex`).
    static let hues: [HelmDomainHue] = [.blue, .teal, .violet, .rose, .amber, .green, .slate]

    /// The hue `project` wears: its stored one, else the hash fallback.
    /// `nil` only for no project at all.
    static func hue(for project: ShiftProject?) -> HelmDomainHue? {
        guard let project else { return nil }
        return project.hue ?? fallbackHue(forProjectID: project.id)
    }

    /// The hue for a record that names `projectID` and whose `project` the
    /// caller already looked up: the project's hue when it was found, the
    /// hash fallback for an id with no record, `nil` for no project.
    static func hue(for project: ShiftProject?, projectID: String?) -> HelmDomainHue? {
        if let project { return hue(for: project) }
        guard let projectID, !projectID.isEmpty else { return nil }
        return fallbackHue(forProjectID: projectID)
    }

    /// The hue for a project id, looked up in `projects`. An id with no record
    /// there (a deleted project, a task from another machine) still resolves
    /// through the hash so it keeps a stable colour. `nil` for no project.
    static func hue(forProjectID id: String?, in projects: [ShiftProject]) -> HelmDomainHue? {
        guard let id, !id.isEmpty else { return nil }
        if let stored = projects.first(where: { $0.id == id })?.hue { return stored }
        return fallbackHue(forProjectID: id)
    }

    /// The hash fallback for a project that has no stored hue.
    static func fallbackHue(forProjectID id: String) -> HelmDomainHue {
        hues[Int(fnv1a(id) % UInt64(hues.count))]
    }

    /// The hex a hue paints in `theme`: the categorical value for a project,
    /// page ink for no project.
    static func hex(for hue: HelmDomainHue?, in theme: HelmTheme) -> String {
        hue?.categoricalHex ?? noProjectHex(in: theme)
    }

    /// Shorthand for `hex(for: hue(forProjectID:in:), in:)`.
    static func hex(forProjectID id: String?, in projects: [ShiftProject], theme: HelmTheme) -> String {
        hex(for: hue(forProjectID: id, in: projects), in: theme)
    }

    /// A task with no project: the ink tone, never an identity hue, so "no
    /// project" stays visually distinct from "some project".
    static func noProjectHex(in theme: HelmTheme) -> String { HelmTint.neutral.hex(in: theme) }

    /// The first hue in `hues` that none of `projects` wears (stored or by
    /// fallback). Once all seven are taken it cycles by count, so the eighth
    /// project repeats the first hue rather than piling onto one.
    static func firstFreeHue(among projects: [ShiftProject]) -> HelmDomainHue {
        let taken = Set(projects.compactMap { hue(for: $0) })
        return hues.first { !taken.contains($0) } ?? hues[projects.count % hues.count]
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
    /// The sidebar layout's card (stage 7), in place of `row` once
    /// `adoptWorkspaceStyle` has run. The press, drag, menu and keyboard
    /// handling below is the same for both.
    private lazy var workspaceCard = ShiftWorkspaceTaskCard()
    private(set) var usesWorkspaceStyle = false

    private(set) var taskID: String = ""
    private var currentColumn: ShiftBoardColumn = .backlog

    /// UX-04: this card's task fills the inspector, so it stays drawn as
    /// selected while the keyboard is over there.
    var isInspected = false {
        didSet {
            guard isInspected != oldValue, window?.firstResponder !== self else { return }
            row.isRowSelected = isInspected
            if usesWorkspaceStyle { workspaceCard.isSelected = isInspected }
        }
    }

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

    /// Draw the prototype's card rather than the floating bar's. Once, the
    /// first time the sidebar layout shows the board; never undone.
    func adoptWorkspaceStyle() {
        guard !usesWorkspaceStyle else { return }
        usesWorkspaceStyle = true
        row.isHidden = true
        workspaceCard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(workspaceCard)
        NSLayoutConstraint.activate([
            workspaceCard.leadingAnchor.constraint(equalTo: leadingAnchor),
            workspaceCard.trailingAnchor.constraint(equalTo: trailingAnchor),
            workspaceCard.topAnchor.constraint(equalTo: topAnchor),
            workspaceCard.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The row is still a subview, so its own height would hold the card
        // open around the shorter workspace card.
        row.removeFromSuperview()
    }

    func configure(task: ShiftTask, project: ShiftProject?, column: ShiftBoardColumn, theme: HelmTheme) {
        taskID = task.id
        currentColumn = column
        if usesWorkspaceStyle {
            workspaceCard.configure(task: task, project: project, column: column, theme: theme)
            // UX-03: a card still to do takes the quick actions.
            workspaceCard.offersQuickActions = column != .done
            workspaceCard.onQuickAction = { [weak self] action in self?.performQuickAction(action) }
            let priorityText = task.priority.rawValue.capitalized
            setAccessibilityLabel("\(task.title), \(column.title), \(priorityText) priority")
            menu = buildMenu()
            setAccessibilityCustomActions(accessibilityMoves())
            return
        }

        // UI-23 / UI-24 through `ShiftTaskSignals`, the page's one rule: a
        // priority chip only for High and Low (Q3), and the due date as a
        // caption that is amber today and red when late.
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

        row.configure(HelmAccentRow.Content(
            // The bar carries **project identity**, the one thing the board's
            // colour codes - and the list's rows now say the same (UI-24).
            // S13: the project's stored identity hue, a literal from the
            // categorical ramp rather than a semantic slot.
            tint: .neutral,
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
            hint: "Drag to another lane, or right-click to move.",
            tintHex: ShiftProjectPalette.hex(for: ShiftProjectPalette.hue(for: project, projectID: task.projectID),
                                             in: theme)
        ), theme: theme)

        let priorityText = task.priority.rawValue.capitalized
        setAccessibilityLabel("\(task.title), \(column.title), \(priorityText) priority")
        menu = buildMenu()
        setAccessibilityCustomActions(accessibilityMoves())
    }

    func applyTheme(_ theme: HelmTheme) {
        if usesWorkspaceStyle { workspaceCard.applyTheme(theme) } else { row.applyTheme(theme) }
    }

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
        workspaceCard.isSelected = usesWorkspaceStyle
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        row.isRowSelected = isInspected
        if usesWorkspaceStyle { workspaceCard.isSelected = isInspected }
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: HelmMetrics.rRow, yRadius: HelmMetrics.rRow).fill()
    }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter: open, as a click does.
        if [36, 76].contains(event.keyCode) {
            onOpen?()
            return
        }
        // UX-03: Space, T and F do a card's three quick actions, and J and K
        // move between cards. Without modifiers only, so ⌘T and ⌘F stay the
        // app's.
        let mods = event.modifierFlags.intersection(KeyChord.relevantModifierMask)
        if mods.isEmpty {
            if event.keyCode == 49 {
                if usesWorkspaceStyle && workspaceCard.offersQuickActions { performQuickAction(.done) } else { onOpen?() }
                return
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "t" where usesWorkspaceStyle && workspaceCard.offersQuickActions:
                performQuickAction(.tomorrow)
                return
            case "f" where usesWorkspaceStyle && workspaceCard.offersQuickActions:
                performQuickAction(.focus)
                return
            case "j":
                moveSelection(by: 1)
                return
            case "k":
                moveSelection(by: -1)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: UX-03 - the quick actions

    /// Done goes to the Done lane (`onMove`, the same call a drop makes, and
    /// the page offers Undo), Tomorrow pushes the due date (`onPushDue`), and
    /// Focus starts the default focus session (`onStartFocus`).
    func performQuickAction(_ action: ShiftWorkspaceTaskCard.QuickAction) {
        switch action {
        case .done:
            if let onComplete { onComplete() } else { onMove?(.done) }
        case .tomorrow: onPushDue?(.tomorrow)
        case .focus: onStartFocus?(FocusTimerEngine.defaultMinutes)
        }
    }

    /// Done with the page's Undo toast, when the page offers one.
    var onComplete: (() -> Void)?

    /// J and K: the next or previous card on the board, lane by lane.
    private func moveSelection(by step: Int) {
        var root: NSView? = superview
        while let view = root, !(view is ShiftBoardView) { root = view.superview }
        guard let board = root else { return }
        func cards(in view: NSView) -> [ShiftBoardCardView] {
            view.subviews.flatMap { ($0 as? ShiftBoardCardView).map { [$0] } ?? cards(in: $0) }
        }
        let all = cards(in: board).filter { !$0.isHiddenOrHasHiddenAncestor }
        guard let index = all.firstIndex(where: { $0 === self }) else { return }
        let next = index + step
        guard all.indices.contains(next) else { return }
        window?.makeFirstResponder(all[next])
        all[next].scrollToVisible(all[next].bounds)
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
        let local = convert(point, from: superview)
        // UX-03: a showing quick action takes its own click.
        if usesWorkspaceStyle, let button = workspaceCard.quickActionButton(at: workspaceCard.convert(local, from: self)) {
            return button
        }
        return bounds.contains(local) ? self : nil
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
        HelmMotion.fade(self, to: Self.draggingAlpha, duration: HelmMotion.stateDuration, animated: true)
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
        HelmMotion.fade(self, to: 1, duration: HelmMotion.stateDuration, animated: true)
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
    /// The prototype's card, once the board has adopted it - the card the
    /// page draws.
    var debugWorkspaceCard: ShiftWorkspaceTaskCard? { usesWorkspaceStyle ? workspaceCard : nil }
    /// The due caption the card paints, in either style.
    var debugDue: String? { usesWorkspaceStyle ? workspaceCard.debugDue : row.debugMetaText }
    func debugLiftedSnapshotSize() -> NSSize? { liftedSnapshot()?.size }
    #endif
}

// MARK: - The sidebar layout's card (stage 7)

/// The prototype's task card: the title first, then a meta line saying which
/// project (its dot and name), when it is due (a calendar glyph, amber today
/// and red once late, through `ShiftTaskSignals` - the page's one rule), and
/// a chip for Low. A card surface on the lane's tint, the accent stroke while
/// selected, and a darker edge under the pointer.
///
/// UI-04 of full review 4: High is a red flag before the title rather than a
/// third chip on the meta line, and the meta line wraps onto a second line
/// when it does not fit, so the project's name is never cut. Measured
/// before: "Infra har..." on the overdue, High card, and "Infra h..." at the
/// Large text size, with a second line of room unused.
///
/// What the floating bar's card says beyond that stays on this one too:
/// subtasks as "2/5", an attachment as a paperclip, and a Done card's
/// completion date in place of its due date.
final class ShiftWorkspaceTaskCard: NSView {
    static let radius: CGFloat = 10
    static let padding = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let projectDot = NSView()
    private let projectLabel = NSTextField(labelWithString: "")
    private let dueIcon = NSImageView()
    private let dueLabel = NSTextField(labelWithString: "")
    private let subtasksLabel = NSTextField(labelWithString: "")
    private let attachmentIcon = NSImageView()
    private let pill = HelmStatusPill(style: .pill)
    private let meta = ShiftCardMetaFlow()
    /// The task is High: its flag leads the title.
    private var flagged = false
    /// The title's words, without the flag the label may draw before them.
    private var titleText = ""
    private var tracking: NSTrackingArea?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var projectHue: HelmDomainHue?
    private var dueTint: HelmTint?
    private var struck = false

    var isSelected = false { didSet { if isSelected != oldValue { applyTheme(theme); refreshActions() } } }
    private var isHovered = false { didSet { if isHovered != oldValue { applyTheme(theme); refreshActions() } } }

    /// UX-03: the three things done most to a card, on hover or keyboard
    /// focus - Done (Space), Tomorrow (T) and Focus (F).
    enum QuickAction: CaseIterable {
        case done, tomorrow, focus

        var title: String {
            switch self {
            case .done: return "Done"
            case .tomorrow: return "Tomorrow"
            case .focus: return "Focus"
            }
        }
        var symbol: String {
            switch self {
            case .done: return "checkmark"
            case .tomorrow: return "arrow.right"
            case .focus: return "timer"
            }
        }
        /// The key that does it while the card is selected.
        var key: String {
            switch self {
            case .done: return "Space"
            case .tomorrow: return "T"
            case .focus: return "F"
            }
        }
    }

    var onQuickAction: ((QuickAction) -> Void)?
    /// A card that can take them: not a Done card, not a follow-up.
    var offersQuickActions = false { didSet { refreshActions() } }
    private(set) lazy var actionButtons: [HelmButton] = QuickAction.allCases.map { action in
        let button = HelmButton(title: action.title, variant: .secondary, size: .small, symbol: action.symbol,
                                target: self, action: #selector(quickActionTapped(_:)))
        button.toolTip = "\(action.title) (\(action.key))"
        button.setAccessibilityLabel("\(action.title), \(action.key)")
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    private lazy var actionRow: NSStackView = {
        let row = NSStackView(views: actionButtons)
        row.orientation = .horizontal
        row.spacing = HelmMetrics.s1 + 2
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }()
    private var metaToFoot: NSLayoutConstraint?
    private var actionsToFoot: NSLayoutConstraint?

    /// Whether the row shows: on hover or keyboard focus, on a card that
    /// takes them.
    var showsQuickActions: Bool { offersQuickActions && (isHovered || isSelected) }

    private func refreshActions() {
        let shows = showsQuickActions
        guard actionRow.isHidden == shows || actionRow.superview == nil else { return }
        if actionRow.superview == nil {
            addSubview(actionRow)
            NSLayoutConstraint.activate([
                actionRow.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: HelmMetrics.s2),
                actionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding.left),
                actionRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.padding.right),
            ])
            actionsToFoot = actionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding.bottom)
        }
        actionRow.isHidden = !shows
        if shows {
            metaToFoot?.isActive = false
            actionsToFoot?.isActive = true
        } else {
            actionsToFoot?.isActive = false
            metaToFoot?.isActive = true
        }
    }

    @objc private func quickActionTapped(_ sender: HelmButton) {
        guard let index = actionButtons.firstIndex(of: sender) else { return }
        onQuickAction?(QuickAction.allCases[index])
    }

    /// The button under `point` (in this card's coordinates) while the row
    /// shows, so the board card's own hit test hands it the click.
    func quickActionButton(at point: NSPoint) -> HelmButton? {
        guard showsQuickActions else { return nil }
        return actionButtons.first { !$0.isHidden && $0.frame.contains(actionRow.convert(point, from: self)) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(13), weight: .semibold)
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectDot.wantsLayer = true
        projectDot.layer?.cornerRadius = ShiftProjectTag.dotSide / 2
        projectDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            projectDot.widthAnchor.constraint(equalToConstant: ShiftProjectTag.dotSide),
            projectDot.heightAnchor.constraint(equalToConstant: ShiftProjectTag.dotSide),
        ])
        for label in [projectLabel, dueLabel, subtasksLabel] {
            label.font = HelmType.caption()
            label.lineBreakMode = .byTruncatingTail
        }
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dueIcon.image = HelmSymbol.image("calendar", pointSize: HelmType.scaled(11), weight: .regular)
        attachmentIcon.image = HelmSymbol.image("paperclip", pointSize: HelmType.scaled(11), weight: .regular)
        let project = NSStackView(views: [projectDot, projectLabel])
        project.orientation = .horizontal
        project.spacing = HelmMetrics.s1
        project.alignment = .centerY
        let due = NSStackView(views: [dueIcon, dueLabel])
        due.orientation = .horizontal
        due.spacing = HelmMetrics.s1
        due.alignment = .centerY
        due.identifier = NSUserInterfaceItemIdentifier("due")
        meta.items = [project, due, subtasksLabel, attachmentIcon, pill]
        meta.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(meta)
        let p = Self.padding
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: p.top),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.left),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p.right),
            meta.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.left),
            meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p.right),
        ])
        let foot = meta.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p.bottom)
        foot.isActive = true
        metaToFoot = foot
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Gotcha (22): the title wraps at the card's own width less its
    /// padding, which the lane decides - never at its own resolved width.
    override func layout() {
        super.layout()
        let width = max(80, floor(bounds.width - Self.padding.left - Self.padding.right))
        if abs(titleLabel.preferredMaxLayoutWidth - width) > 0.5 {
            titleLabel.preferredMaxLayoutWidth = width
            titleLabel.invalidateIntrinsicContentSize()
        }
        // The meta line wraps at the same width, for the same reason.
        meta.layoutWidth = width
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func configure(task: ShiftTask, project: ShiftProject?, column: ShiftBoardColumn, theme: HelmTheme) {
        titleText = task.title
        struck = column == .done
        projectHue = ShiftProjectPalette.hue(for: project, projectID: task.projectID)
        projectLabel.stringValue = project?.name ?? "No project"
        var caption: ShiftTaskSignals.DueCaption?
        if column == .done {
            if let done = task.completedAt.flatMap(ShiftStore.date(fromISO8601:)) {
                caption = .init(text: "Done \(ShiftBoardCardView.doneDateFormatter.string(from: done))", tint: nil)
            }
        } else {
            caption = ShiftTaskSignals.dueCaption(date: task.dueDate, time: task.dueTime)
        }
        dueTint = caption?.tint
        dueLabel.stringValue = caption?.text ?? ""
        dueLabel.superview?.isHidden = caption == nil
        let done = task.subtasks.filter(\.done).count
        subtasksLabel.stringValue = task.subtasks.isEmpty ? "" : "\(done)/\(task.subtasks.count)"
        subtasksLabel.isHidden = task.subtasks.isEmpty
        subtasksLabel.toolTip = task.subtasks.isEmpty ? nil : "\(done) of \(task.subtasks.count) subtasks done"
        attachmentIcon.isHidden = !task.hasAttachment
        applyPriority(task.priority, theme: theme)
        toolTip = "Drag to another lane, or right-click to move."
        applyTheme(theme)
    }

    /// R4-UI-09: a pending follow-up on the board's Follow-ups lane, in the
    /// same card a task takes - its title, its project, when it is due through
    /// the page's one due rule, and its priority chip.
    func configure(followUp: ShiftFollowUp, project: ShiftProject?, theme: HelmTheme) {
        titleText = followUp.title
        struck = false
        projectHue = ShiftProjectPalette.hue(for: project, projectID: followUp.projectID)
        projectLabel.stringValue = project?.name ?? "No project"
        let caption = ShiftTaskSignals.dueCaption(date: followUp.followUpAt, time: followUp.followUpTime)
        dueTint = caption?.tint
        dueLabel.stringValue = caption?.text ?? ""
        dueLabel.superview?.isHidden = caption == nil
        subtasksLabel.isHidden = true
        attachmentIcon.isHidden = true
        applyPriority(followUp.priority, theme: theme)
        toolTip = "Click to open, or right-click to mark it done or snooze it."
        applyTheme(theme)
    }

    /// High is the title's flag. Low keeps its quiet chip on the meta line,
    /// and Normal says nothing.
    private func applyPriority(_ priority: ShiftPriority, theme: HelmTheme) {
        flagged = priority == .high
        if !flagged, let chip = ShiftTaskSignals.priorityPill(priority) {
            pill.isHidden = false
            pill.configure(text: chip.text, tint: chip.tint, theme: theme)
        } else {
            pill.isHidden = true
        }
        meta.needsLayout = true
        meta.invalidateIntrinsicContentSize()
    }

    /// The flag's colour: the critical hue, lifted until it reads on the card.
    static func flagColor(_ theme: HelmTheme) -> NSColor {
        HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                       overAnyOf: [HelmTheme.nsColor(theme.chromeBackgroundHex)], theme: theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        HelmCard.applyCardSurface(to: self, theme: theme, cornerRadius: Self.radius, daylightRadius: Self.radius)
        let accent = HelmTheme.nsColor(theme.accentHex)
        if isSelected {
            layer?.borderColor = accent.cgColor
            layer?.borderWidth = 1.5
        } else if isHovered {
            layer?.borderColor = HelmTheme.nsColor(theme.chromeInkHex).withAlphaComponent(0.28).cgColor
        }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let words = titleText
        let font = NSFont.systemFont(ofSize: HelmType.scaled(13), weight: .semibold)
        let title = NSMutableAttributedString(string: words, attributes: [
            .font: font,
            .foregroundColor: struck ? muted : ink,
        ])
        if struck {
            title.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                               range: NSRange(location: 0, length: title.length))
        }
        if flagged, let flag = HelmSymbol.image("flag.fill", pointSize: HelmType.scaled(10), weight: .semibold)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Self.flagColor(theme)])) {
            let attachment = NSTextAttachment()
            attachment.image = flag
            // On the words' baseline, centred on their capitals.
            attachment.bounds = NSRect(x: 0, y: ((font.capHeight - flag.size.height) / 2).rounded(),
                                       width: flag.size.width, height: flag.size.height)
            let lead = NSMutableAttributedString(attachment: attachment)
            lead.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
            title.insert(lead, at: 0)
        }
        titleLabel.attributedStringValue = title
        // The flag is a picture; VoiceOver hears the word.
        titleLabel.setAccessibilityLabel(flagged ? "\(words), High priority" : words)
        projectLabel.textColor = muted
        subtasksLabel.textColor = muted
        dueIcon.contentTintColor = muted
        attachmentIcon.contentTintColor = muted
        projectDot.layer?.backgroundColor = HelmTheme.nsColor(ShiftProjectPalette.hex(for: projectHue, in: theme)).cgColor
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        if let dueTint {
            let tinted = HelmContrast.legibleTintedText(tintHex: dueTint.hex(in: theme), overAnyOf: [surface], theme: theme)
            dueLabel.textColor = tinted
            dueIcon.contentTintColor = tinted
            dueLabel.font = .systemFont(ofSize: HelmType.scaled(12), weight: .semibold)
        } else {
            dueLabel.textColor = muted
            dueLabel.font = HelmType.caption()
        }
        if !pill.isHidden { pill.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleText }
    var debugProject: String { projectLabel.stringValue }
    var debugDue: String? { dueLabel.superview?.isHidden == true ? nil : dueLabel.stringValue }
    var debugChip: String? { pill.isHidden ? nil : pill.text }
    var debugIsStruck: Bool { struck }
    /// Whether the title draws High's flag before its words.
    var debugIsFlagged: Bool {
        flagged && titleLabel.attributedStringValue.containsAttachments(in: NSRange(location: 0, length: 1))
    }
    var debugProjectLabel: NSTextField { projectLabel }
    var debugMeta: ShiftCardMetaFlow { meta }
    #endif
}

// MARK: - The Follow-ups lane (R4-UI-09)

/// A menu item that runs a closure, so a page can hand the lane a menu whose
/// verbs are its own.
final class ShiftLaneMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func fire() { run() }
}

/// Tasks' Follow-ups, as a lane on the board.
///
/// Full review #4 (R4-UX-09, R4-UI-09, review #3's UX-05): at 1512x950 the
/// board stacked two full-width cards under itself, Follow-ups and Projects,
/// so the page read as a board with a report under it. Follow-ups is a lane
/// beside the three status lanes now - the same wash, a band like theirs and
/// the same card a task takes - and Projects is the hero band's project
/// menu. A follow-up is not a task with a status, so the lane is neither a
/// drag source nor a drop target: a click opens it, and its menu marks it
/// done, snoozes it or deletes it, as the List tab's row does.
final class ShiftFollowUpLaneView: NSView {

    /// The most cards the lane draws before its foot says how many more.
    static let maxCards = 50

    private let laneBackground = NSView()
    private let cardsStack = NSStackView()
    private let moreLabel = NSTextField(labelWithString: "")
    private let emptyState = HelmEmptyState(symbol: "bell", body: "No follow-ups waiting", size: .quiet)
    private var cards: [(host: HoverHighlightView, card: ShiftWorkspaceTaskCard, id: String)] = []
    private var theme: HelmTheme = ThemeManager.shared.theme
    /// S08: the lane's foot, the same "Add" every status lane has: a dashed
    /// box with its button centred, the shape `ShiftBoardColumnView` draws.
    private let addHost = NSView()
    private let addOutline = CAShapeLayer()
    private let addButton = HelmButton(title: "Add follow-up", variant: .quiet, size: .small, symbol: "plus")
    /// T-4: the lane's band, amber, across the top of its card - the lane's
    /// header and its "+".
    private lazy var laneBand = ShiftLaneHeroBand(tone: .amber, title: "Follow-ups", addTooltip: "New follow-up",
                                                  target: self, action: #selector(addTapped))

    var onOpen: ((String) -> Void)?
    var onAdd: (() -> Void)?
    /// The row menu, built by the page, which owns what each verb does.
    var menuFor: ((String) -> NSMenu?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        laneBackground.wantsLayer = true
        laneBackground.layer?.cornerRadius = HelmMetrics.rPanel
        laneBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(laneBackground)

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = HelmMetrics.s2
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        cardsStack.setHuggingPriority(.required, for: .vertical)
        addSubview(cardsStack)
        moreLabel.font = HelmType.caption()
        moreLabel.translatesAutoresizingMaskIntoConstraints = false

        addHost.wantsLayer = true
        addHost.translatesAutoresizingMaskIntoConstraints = false
        addHost.layer?.addSublayer(addOutline)
        addOutline.fillColor = NSColor.clear.cgColor
        addOutline.lineWidth = 1
        addOutline.lineDashPattern = [4, 3]
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addHost.addSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.centerXAnchor.constraint(equalTo: addHost.centerXAnchor),
            addButton.centerYAnchor.constraint(equalTo: addHost.centerYAnchor),
            addHost.heightAnchor.constraint(equalToConstant: 32),
        ])
        // The whole dashed box is the button, as the status lanes draw it.
        addHost.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(addTapped)))

        // `ShiftBoardColumnView`'s workspace lane: a rounded wash ending under
        // the lane's last control, the band across its top, the cards and the
        // dashed add row 8pt in from its edges.
        let inset = HelmMetrics.s2
        laneBackground.addSubview(laneBand)
        NSLayoutConstraint.activate([
            laneBackground.topAnchor.constraint(equalTo: topAnchor),
            laneBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            laneBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            // The board's row may stretch this view to its tallest lane; the
            // card follows what the lane holds, as the status lanes' does.
            laneBackground.bottomAnchor.constraint(equalTo: cardsStack.bottomAnchor, constant: inset),
            // T-4: the amber band across the card's top, the cards 8pt under
            // it - the status lanes' own measure, so the four lanes' first
            // cards line up.
            laneBand.topAnchor.constraint(equalTo: laneBackground.topAnchor),
            laneBand.leadingAnchor.constraint(equalTo: laneBackground.leadingAnchor),
            laneBand.trailingAnchor.constraint(equalTo: laneBackground.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: laneBand.bottomAnchor, constant: inset),
            cardsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            cardsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            cardsStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -inset),
        ])
        applyTheme(theme)
    }

    override func layout() {
        super.layout()
        HelmMotion.withoutImplicitAnimation {
            addOutline.frame = addHost.bounds
            addOutline.path = CGPath(roundedRect: addHost.bounds.insetBy(dx: 0.5, dy: 0.5),
                                     cornerWidth: 10, cornerHeight: 10, transform: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Pending follow-ups, in the order the page sorts them.
    func setFollowUps(_ followUps: [ShiftFollowUp], projects: [String: ShiftProject], theme: HelmTheme) {
        self.theme = theme
        for view in cardsStack.arrangedSubviews {
            cardsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cards.removeAll()
        laneBand.configure(count: followUps.count, detail: ShiftHeroWords.laneDetail(
            dues: followUps.map { ($0.followUpAt, $0.followUpTime) }, empty: "Nothing waiting"))
        guard !followUps.isEmpty else {
            cardsStack.addArrangedSubview(emptyState)
            emptyState.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
            appendAddRow()
            applyTheme(theme)
            return
        }
        for item in followUps.prefix(Self.maxCards) {
            let card = ShiftWorkspaceTaskCard()
            card.translatesAutoresizingMaskIntoConstraints = false
            card.configure(followUp: item, project: item.projectID.flatMap { projects[$0] }, theme: theme)
            // GL-16: a clickable row is a `HoverHighlightView`, which gives
            // it the button role, the focus ring and Return and Space.
            let host = HoverHighlightView()
            host.cornerRadius = ShiftWorkspaceTaskCard.radius
            host.addSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                card.topAnchor.constraint(equalTo: host.topAnchor),
                card.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            host.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:))))
            host.menu = menuFor?(item.id)
            host.setAccessibilityLabel("Follow-up: \(item.title)")
            cardsStack.addArrangedSubview(host)
            host.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
            cards.append((host, card, item.id))
        }
        let hidden = followUps.count - Self.maxCards
        if hidden > 0 {
            moreLabel.stringValue = "+\(hidden) more in List"
            cardsStack.addArrangedSubview(moreLabel)
        }
        appendAddRow()
        applyTheme(theme)
    }

    /// The lane's foot, after its cards (S08).
    private func appendAddRow() {
        cardsStack.addArrangedSubview(addHost)
        addHost.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
    }

    @objc private func cardClicked(_ sender: NSClickGestureRecognizer) {
        guard let entry = cards.first(where: { $0.host === sender.view }) else { return }
        onOpen?(entry.id)
    }

    @objc private func addTapped() { onAdd?() }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // The status lanes' own card (`ShiftBoardColumnView.applyTheme`).
        ShiftBoardColumnView.paintLaneCard(laneBackground, theme: theme)
        laneBand.applyTheme(theme)
        emptyState.applyTheme(theme)
        moreLabel.textColor = HelmTheme.mutedInk(theme)
        // The status lanes' dashed outline.
        addOutline.strokeColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(theme.isDaylight ? 1 : 0.8).cgColor
        for entry in cards { entry.card.applyTheme(theme) }
    }

    #if FM_SELFTESTS
    var debugCardTitles: [String] { cards.map(\.card.debugTitle) }
    var debugCardDues: [String?] { cards.map(\.card.debugDue) }
    /// The band's count, which is the lane's.
    var debugCount: String { laneBand.debugCount }
    /// A real click's path: the card host's own recognizer and its action.
    func debugClickCard(at index: Int) -> Bool {
        guard cards.indices.contains(index) else { return false }
        return cards[index].host.performPrimaryAction()
    }
    /// S08: the lane's foot and whether its dashed outline shows.
    var debugAddRow: (button: HelmButton, outlined: Bool, inLane: Bool) {
        (addButton, !addOutline.isHidden, addHost.superview === cardsStack)
    }
    var debugLaneWashShown: Bool { !laneBackground.isHidden }
    var debugLaneBand: ShiftLaneHeroBand { laneBand }
    func debugMenuTitles(at index: Int) -> [String] {
        guard cards.indices.contains(index) else { return [] }
        return cards[index].host.menu?.items.map(\.title) ?? []
    }
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
    /// S20: the lane's "+" is a 28pt `HelmIconButton` target.
    private let headerAdd = HelmIconButton(symbol: "plus", label: "New task")
    private let dropView = ShiftBoardDropView()
    /// UI-27: the drop target's dashed outline, shown with the wash.
    private let dropOutline = CAShapeLayer()
    /// Nested in the page's scroll view, which does the scrolling once the
    /// sidebar layout grows the lane to its cards. A plain `NSScrollView`
    /// kept every wheel event over the cards even then, so the page stopped
    /// scrolling under the pointer (`TasksPageWheelSelfTest`).
    private let scroll = HelmNestedScrollView()
    private let cardsStack = NSStackView()
    private let overflowLabel = NSTextField(labelWithString: "")
    /// UXP-18: "3 more below" when the lane scrolls inside its card.
    private let overflowHint = HelmOverflowHint()
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
    /// UI-26: the filtered-empty state - a lane that is empty *because of a
    /// filter* says which, and offers the way out ("Show all projects"),
    /// rather than claiming there is nothing to do.
    private let filteredEmptyState: HelmEmptyState
    private let clearFilterButton = HelmButton(title: "Show all projects", variant: .quiet, size: .small)
    /// UI-31: the one loading idiom, shown on the page's first paint before
    /// the task files have been read.
    private let skeleton = HelmSkeletonList(rows: 3)
    var onClearFilter: (() -> Void)?
    private var isLoading = false
    private var filterDescription: String?

    /// UI-25: a quiet text button at the lane's foot, not a dashed box.
    private let addButton = HelmButton(title: "Add task", variant: .quiet, size: .small, symbol: "plus")

    private var cardViews: [ShiftBoardCardView] = []

    /// UXP-18: fired when this lane's "N more below" count changes, so the
    /// board can show the hint row on every lane or on none - a hint in one
    /// lane alone would drop its "Add task" a line below its neighbours'.
    var onOverflowHintChanged: (() -> Void)?
    var overflowHintCount: Int { overflowHint.countBelow }
    func setOverflowHintRowShown(_ shown: Bool) {
        // A workspace lane never scrolls, so it never has cards below.
        guard !usesWorkspaceStyle else { return }
        guard overflowHint.isHidden == shown else { return }
        overflowHint.isHidden = !shown
    }
    private lazy var cardRows = HelmKeyedRows(stack: cardsStack)
    private var bodyHeight: NSLayoutConstraint?
    private var theme: HelmTheme = ThemeManager.shared.theme

    // The sidebar layout's lane (stage 7) - see `adoptWorkspaceStyle`.
    private(set) var usesWorkspaceStyle = false
    private var headerLeading: NSLayoutConstraint?
    private var headerTop: NSLayoutConstraint?
    private var dropEdges: [NSLayoutConstraint] = []
    private var bodyBottom: NSLayoutConstraint?
    /// The lane's "Add task" in a dashed outline, which the button cannot
    /// carry itself (`HelmButton` repaints its own layer).
    private let addHost = NSView()
    private let addOutline = CAShapeLayer()
    /// The lane wraps its cards rather than scrolling them: the page scrolls.
    private var fitsCards: NSLayoutConstraint?
    /// The lane's tint, ending under its last control rather than at this
    /// view's foot: the board's row stretches every column to the tallest
    /// one, and only what the captain sees has to stay the lane's height.
    private let laneBackground = NSView()
    private var cardsStackBottom: NSLayoutConstraint?
    /// T-4: the lane's header as a toned hero band (`ShiftLaneHeroBand`), in
    /// the sidebar layout's lane - which is a card now, with the band across
    /// its top and the cards quiet under it.
    private var laneBand: ShiftLaneHeroBand?

    /// T-4's tone per lane: the accent, slate and green.
    static func laneTone(for column: ShiftBoardColumn) -> ShiftLaneTone {
        switch column {
        case .backlog: return .accent
        case .inProgress: return .slate
        case .done: return .green
        }
    }

    var onOpenTask: ((String) -> Void)?
    var onMoveTask: ((String, ShiftBoardColumn) -> Void)?
    var onDeleteTask: ((String) -> Void)?
    /// UX-04: the task the inspector shows, whose card stays selected.
    var inspectedTaskID: String? {
        didSet {
            guard inspectedTaskID != oldValue else { return }
            for card in cardViews { card.isInspected = card.taskID == inspectedTaskID }
        }
    }
    /// UX7's reschedule gesture, forwarded up with the task's id like every
    /// other card verb here.
    var onPushTaskDue: ((String, ShiftDuePush) -> Void)?
    /// UX-03: a card's Done, which the page does with Undo.
    var onCompleteTask: ((String) -> Void)?
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
        filteredEmptyState = HelmEmptyState(symbol: column.symbol, body: "", size: .quiet,
                                            accessory: clearFilterButton)
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
        if column == .done {
            header.countLabel.toolTip = "The Done lane shows tasks completed in the last "
                + "\(ShiftController.doneColumnLookbackDays) days. Older ones stay on their project's own page."
        }
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
        let stackBottom = cardsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        cardsStackBottom = stackBottom
        NSLayoutConstraint.activate([
            cardsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            cardsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            cardsStack.topAnchor.constraint(equalTo: document.topAnchor),
            stackBottom,
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

        overflowHint.watch(scroll) { [weak self] in self?.cardViews.map(\.frame) ?? [] }
        overflowHint.onCountChanged = { [weak self] _ in self?.onOverflowHintChanged?() }

        let body = NSStackView(views: [scroll, overflowHint, overflowLabel, addButton])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyStack = body
        dropView.addSubview(body)
        dropView.addSubview(emptyState)
        dropView.addSubview(filteredEmptyState)
        // A lane's width is the board's to decide, never its copy's - see
        // `HelmEmptyState.letBodyWrapToContainer` (B5 of the polish report).
        emptyState.letBodyWrapToContainer()
        filteredEmptyState.letBodyWrapToContainer()
        dropView.addSubview(skeleton)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        filteredEmptyState.translatesAutoresizingMaskIntoConstraints = false
        skeleton.translatesAutoresizingMaskIntoConstraints = false
        filteredEmptyState.isHidden = true
        skeleton.isHidden = true
        clearFilterButton.target = self
        clearFilterButton.action = #selector(clearFilterTapped)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            body.topAnchor.constraint(equalTo: dropView.topAnchor),
            bodyBottomConstraint(body),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            overflowLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            overflowHint.widthAnchor.constraint(equalTo: body.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            emptyState.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            filteredEmptyState.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            filteredEmptyState.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            filteredEmptyState.topAnchor.constraint(equalTo: scroll.topAnchor),
            skeleton.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            skeleton.topAnchor.constraint(equalTo: scroll.topAnchor),
        ])

        for view in [header, headerRule, dropView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let headerLeading = header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s1)
        let headerTop = header.topAnchor.constraint(equalTo: topAnchor)
        self.headerLeading = headerLeading
        self.headerTop = headerTop
        dropEdges = [
            dropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropView.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: HelmMetrics.s3),
            dropView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate([
            headerLeading,
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerTop,
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            headerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s2),
            headerRule.heightAnchor.constraint(equalToConstant: 1),
        ] + dropEdges)
    }

    private var bodyStack: NSStackView?

    private func bodyBottomConstraint(_ body: NSView) -> NSLayoutConstraint {
        let bottom = body.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: -HelmMetrics.s1)
        bodyBottom = bottom
        return bottom
    }

    /// The prototype's lane: a rounded tint holding the lane's name and
    /// count, its cards at their own height, and a dashed "Add task" - no
    /// dot, no rule, no scrolling inside the lane (the page scrolls). Once,
    /// the first time the sidebar layout shows the board; never undone.
    func adoptWorkspaceStyle() {
        guard !usesWorkspaceStyle else { return }
        usesWorkspaceStyle = true
        laneBackground.wantsLayer = true
        laneBackground.layer?.cornerRadius = HelmMetrics.rPanel
        laneBackground.layer?.masksToBounds = true
        laneBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(laneBackground, positioned: .below, relativeTo: nil)
        header.configure(leading: .none, title: column.title, count: header.countLabel.stringValue)
        header.heightAnchor.constraint(equalToConstant: 30).isActive = true
        headerRule.isHidden = true
        headerLeading?.constant = HelmMetrics.s3
        headerTop?.constant = HelmMetrics.s2
        // T-4: the band stands in for the header, its "+" for the header's.
        // The header stays built (and counted) for the floating bar's shape
        // and the suites that read its count, and is hidden here.
        header.isHidden = true
        let band = ShiftLaneHeroBand(tone: Self.laneTone(for: column), title: column.title,
                                     addTooltip: column == .done ? nil : "Add a task to \(column.title)",
                                     target: self, action: #selector(addTapped))
        laneBackground.addSubview(band)
        laneBand = band
        // Inside the card: the cards and the add button sit 8pt in from it,
        // and 8pt under the band.
        dropEdges[0].constant = HelmMetrics.s2
        dropEdges[1].constant = -HelmMetrics.s2
        dropEdges[2].isActive = false
        // The stretch lands below the lane, never inside it.
        dropEdges[3].isActive = false
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: laneBackground.topAnchor),
            band.leadingAnchor.constraint(equalTo: laneBackground.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: laneBackground.trailingAnchor),
            dropView.topAnchor.constraint(equalTo: band.bottomAnchor, constant: HelmMetrics.s2),
        ])
        NSLayoutConstraint.activate([
            dropView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -HelmMetrics.s2),
            laneBackground.topAnchor.constraint(equalTo: topAnchor),
            laneBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            laneBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            laneBackground.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: HelmMetrics.s2),
        ])
        bodyBottom?.constant = 0
        // The lane is as tall as what it holds: its stack hugs its contents,
        // a stack-level hug since a stack has no intrinsic size (gotcha (12)).
        bodyStack?.setHuggingPriority(.required, for: .vertical)
        overflowHint.isHidden = true
        bodyHeight?.isActive = false
        // The clip view stretches its document to fill it, and the stack was
        // pinned to both of the document's ends - so a tie to the stack's
        // height was a tie to the scroll view's own, and every lane came out
        // as tall as the fullest (measured on the first render). Released at
        // the bottom, the stack is its cards' height, which the lane follows.
        if let cardsStackBottom, let document = cardsStack.superview {
            cardsStackBottom.isActive = false
            cardsStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor).isActive = true
        }
        let fit = scroll.heightAnchor.constraint(equalTo: cardsStack.heightAnchor)
        // Below the stack's own defaults, above nothing that sizes the window:
        // the board sits in the page's scroll view, so a lane's height can
        // never reach the window (gotcha (13)).
        fit.priority = .defaultHigh
        fit.isActive = true
        fitsCards = fit
        // An empty lane keeps room for its empty state, and is still a drop
        // target.
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        scroll.hasVerticalScroller = false
        if let body = bodyStack, column != .done {
            body.removeArrangedSubview(addButton)
            addButton.removeFromSuperview()
            addHost.wantsLayer = true
            addHost.translatesAutoresizingMaskIntoConstraints = false
            addHost.layer?.addSublayer(addOutline)
            addOutline.fillColor = NSColor.clear.cgColor
            addOutline.lineWidth = 1
            addOutline.lineDashPattern = [4, 3]
            addButton.translatesAutoresizingMaskIntoConstraints = false
            addHost.addSubview(addButton)
            NSLayoutConstraint.activate([
                addButton.centerXAnchor.constraint(equalTo: addHost.centerXAnchor),
                addButton.centerYAnchor.constraint(equalTo: addHost.centerYAnchor),
                addHost.heightAnchor.constraint(equalToConstant: 32),
            ])
            body.addArrangedSubview(addHost)
            addHost.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            // The whole dashed box is the button, as the prototype draws it.
            addHost.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(addTapped)))
        }
        for cardView in cardViews { cardView.adoptWorkspaceStyle() }
        applyTheme(theme)
        needsLayout = true
    }

    @objc private func addTapped() { onAddTask?(column) }
    @objc private func clearFilterTapped() { onClearFilter?() }

    /// UI-31: skeleton bars in place of cards until the first read lands.
    func setLoading(_ loading: Bool) {
        isLoading = loading
        applyEmptyStates()
    }

    /// UI-26: what the page is filtering by, phrased to follow a lane's name
    /// ("in Ideas", "due today"), or `nil` when nothing is filtered.
    func setFilterDescription(_ description: String?, clearTitle: String) {
        filterDescription = description
        clearFilterButton.title = clearTitle
        applyEmptyStates()
    }

    private func applyEmptyStates() {
        let empty = cardViews.isEmpty
        skeleton.isHidden = !isLoading
        let filtered = !isLoading && empty && filterDescription != nil
        filteredEmptyState.isHidden = !filtered
        if filtered, let filterDescription {
            filteredEmptyState.setText(body: "No \(column.title) tasks \(filterDescription)")
        }
        emptyState.isHidden = isLoading || !empty || filtered
    }

    override func layout() {
        super.layout()
        if usesWorkspaceStyle {
            HelmMotion.withoutImplicitAnimation {
                addOutline.frame = addHost.bounds
                addOutline.path = CGPath(roundedRect: addHost.bounds.insetBy(dx: 0.5, dy: 0.5),
                                         cornerWidth: 10, cornerHeight: 10, transform: nil)
            }
        } else {
            applyBodyHeight()
            overflowHint.recount()
        }
        HelmMotion.withoutImplicitAnimation {
            dropOutline.frame = dropView.bounds
            dropOutline.path = CGPath(roundedRect: dropView.bounds.insetBy(dx: 0.5, dy: 0.5),
                                      cornerWidth: HelmMetrics.rRow, cornerHeight: HelmMetrics.rRow,
                                      transform: nil)
        }
    }

    /// Shows this column's cards. Called on every board render.
    ///
    /// P2: keyed by task id - a task still in this lane keeps its card and is
    /// reconfigured in place, only a task that arrived builds one, and only
    /// one that left loses its card (`HelmKeyedRows`). So a refresh does not
    /// flash the lane, and a card under the pointer keeps its hover.
    func setTasks(_ tasks: [ShiftTask], projects: [String: ShiftProject], theme: HelmTheme) {
        self.theme = theme
        cardRows.reconcile(Array(tasks.prefix(Self.maxCards)), key: \.id, make: { task in
            let cardView = ShiftBoardCardView()
            if self.usesWorkspaceStyle { cardView.adoptWorkspaceStyle() }
            // The handlers name the task by id, which is the card's key, so
            // they stay right for as long as the card is kept.
            let id = task.id
            cardView.onOpen = { [weak self] in self?.onOpenTask?(id) }
            cardView.onMove = { [weak self] target in self?.onMoveTask?(id, target) }
            cardView.onDelete = { [weak self] in self?.onDeleteTask?(id) }
            cardView.onPushDue = { [weak self] option in self?.onPushTaskDue?(id, option) }
            cardView.onStartFocus = { [weak self] minutes in self?.onStartFocusTask?(id, minutes) }
            cardView.onComplete = { [weak self] in self?.onCompleteTask?(id) }
            return cardView
        }, update: { [weak self] view, task in
            guard let self, let cardView = view as? ShiftBoardCardView else { return }
            cardView.configure(task: task,
                               project: task.projectID.flatMap { projects[$0] },
                               column: self.column,
                               theme: theme)
            cardView.isInspected = task.id == self.inspectedTaskID
        })
        cardViews = cardRows.orderedRows.compactMap { $0 as? ShiftBoardCardView }

        // S09: the Done lane says its own window beside its number, where
        // the filter row's free-standing note used to say it.
        header.countLabel.stringValue = column == .done
            ? "\(tasks.count) \u{00B7} \(ShiftController.doneWindowCaption)"
            : "\(tasks.count)"
        laneBand?.configure(count: tasks.count, detail: column == .done
            ? ShiftController.doneWindowCaption.prefix(1).uppercased() + ShiftController.doneWindowCaption.dropFirst()
            : ShiftHeroWords.laneDetail(dues: tasks.map { ($0.dueDate, $0.dueTime) }, empty: "Nothing here yet"))
        let hidden = max(0, tasks.count - Self.maxCards)
        overflowLabel.isHidden = hidden == 0
        overflowLabel.stringValue = hidden == 0
            ? ""
            : "+\(hidden) more \u{2013} switch to List view to see them all."
        applyEmptyStates()
        needsLayout = true

        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        headerAdd.applyTheme(theme)
        header.applyTheme(theme)
        headerRule.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(theme.isDaylight ? 1 : HelmCard.borderAlpha).cgColor
        if usesWorkspaceStyle {
            // T-4: the lane is a card, with its band across the top.
            ShiftBoardColumnView.paintLaneCard(laneBackground, theme: theme)
            laneBand?.applyTheme(theme)
            addOutline.strokeColor = HelmTheme.nsColor(theme.chromeLineHex)
                .withAlphaComponent(theme.isDaylight ? 1 : 0.8).cgColor
        }
        overflowLabel.textColor = HelmTheme.mutedInk(theme)
        overflowHint.applyTheme(theme)
        emptyState.applyTheme(theme)
        filteredEmptyState.applyTheme(theme)
        skeleton.applyTheme(theme)
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
        var desired = min(max(plannedBodyHeight, measured), Self.maxBodyHeight)
        // UXP-18: a lane that scrolls stops on a card boundary. The cap is
        // four of the *tallest* card shape, so four shorter cards left room
        // for an 8pt strip of the fifth - which read as a clipped card, with
        // "Add task" abutting it. Whole cards only, and the hint below says
        // how many more there are.
        var snapped: CGFloat?
        if measured > desired + 0.5 {
            desired = Self.wholeCardHeight(cardViews.map(\.frame.height), spacing: cardsStack.spacing,
                                           within: desired)
            snapped = desired
        } else if let level = levelBodyHeight, measured <= level + 0.5 {
            // A lane that does not scroll takes the scrolling lane's height,
            // so the lanes' feet stay on one line.
            desired = level
        }
        if abs(bodyHeight.constant - desired) > 0.5 { bodyHeight.constant = desired }
        if snapped != snappedBodyHeight {
            snappedBodyHeight = snapped
            onSnappedBodyHeightChanged?()
        }
    }

    /// The whole-card height this lane snapped to, or `nil` when it does not
    /// scroll. Read by the board, which levels the other lanes to it.
    private(set) var snappedBodyHeight: CGFloat?
    var onSnappedBodyHeightChanged: (() -> Void)?
    /// Set by the board: the height a lane that does not scroll should take.
    var levelBodyHeight: CGFloat? {
        didSet { if levelBodyHeight != oldValue { needsLayout = true } }
    }

    /// The tallest run of whole cards, from the top, that fits `limit`.
    /// `limit` itself when even the first card does not fit (or nothing has
    /// been laid out yet), so a lane never collapses to nothing.
    static func wholeCardHeight(_ heights: [CGFloat], spacing: CGFloat, within limit: CGFloat) -> CGFloat {
        var used: CGFloat = 0
        for (index, height) in heights.enumerated() where height > 0 {
            let next = used + (index > 0 ? spacing : 0) + height
            if next > limit + 0.5 { break }
            used = next
        }
        return used > 0 ? used : limit
    }

    private var plannedBodyHeight: CGFloat = ShiftBoardColumnView.minBodyHeight

    /// T-4's lane card: the card surface at the lane's own radius, clipping
    /// the band to its top corners. Shared with the Follow-ups lane.
    static func paintLaneCard(_ view: NSView, theme: HelmTheme) {
        HelmCard.applyCardSurface(to: view, theme: theme, cornerRadius: HelmMetrics.rPanel,
                                  daylightRadius: HelmMetrics.rPanel)
        view.layer?.masksToBounds = true
    }

    #if FM_SELFTESTS
    var debugLaneBand: ShiftLaneHeroBand? { laneBand }
    var debugCardViews: [ShiftBoardCardView] { cardViews }
    /// The sidebar layout's lane tint, which ends under the lane's last
    /// control rather than at this view's foot.
    var debugLaneBackground: NSView { laneBackground }
    var debugCountText: String { header.countLabel.stringValue }
    var debugHeader: HelmSectionHeader { header }
    var debugAddButton: HelmButton { addButton }
    var debugDropOutlineVisible: Bool { !dropOutline.isHidden }
    var debugSkeletonVisible: Bool { !skeleton.isHidden }
    var debugFilteredEmptyText: String? {
        filteredEmptyState.isHidden ? nil : filteredEmptyState.debugBodyText
    }
    func debugPressClearFilter() { clearFilterButton.performClick(nil) }
    func debugSetDropTargeted(_ targeted: Bool) { dropView.debugSetTargeted(targeted) }
    var debugOverflowText: String { overflowLabel.isHidden ? "" : overflowLabel.stringValue }
    /// UXP-18: the lane's "N more below" as drawn, and whether any card is
    /// cut by the bottom of the visible area.
    var debugOverflowHintText: String { overflowHint.debugText }
    var debugHasPartlyVisibleCard: Bool {
        let visible = scroll.contentView.bounds
        return cardViews.contains { $0.frame.minY < visible.maxY - 0.5 && $0.frame.maxY > visible.maxY + 0.5 }
    }
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
    #if FM_SELFTESTS
    var debugColumnViews: [ShiftBoardColumnView] { columnViews }
    #endif
    private let row = NSStackView()

    var onOpenTask: ((String) -> Void)?
    var onMoveTask: ((String, ShiftBoardColumn) -> Void)?
    var onDeleteTask: ((String) -> Void)?
    /// UX-04: the task the inspector shows, whose card stays selected.
    var inspectedTaskID: String? {
        didSet {
            guard inspectedTaskID != oldValue else { return }
            for column in columnViews { column.inspectedTaskID = inspectedTaskID }
        }
    }
    /// UX7's reschedule gesture, forwarded up with the task's id like every
    /// other card verb here.
    var onPushTaskDue: ((String, ShiftDuePush) -> Void)?
    /// UX-03: a card's Done, which the page does with Undo.
    var onCompleteTask: ((String) -> Void)?
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
            column.onOverflowHintChanged = { [weak self] in self?.applyOverflowHintRows() }
            column.onSnappedBodyHeightChanged = { [weak self] in self?.applyLevelBodyHeight() }
            column.onOpenTask = { [weak self] id in self?.onOpenTask?(id) }
            column.onMoveTask = { [weak self] id, target in self?.onMoveTask?(id, target) }
            column.onDeleteTask = { [weak self] id in self?.onDeleteTask?(id) }
            column.onPushTaskDue = { [weak self] id, option in self?.onPushTaskDue?(id, option) }
            column.onCompleteTask = { [weak self] id in self?.onCompleteTask?(id) }
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

    /// UXP-18: a lane that scrolls snaps to whole cards; the others follow
    /// it, so the three lanes still end on one line.
    private func applyLevelBodyHeight() {
        let level = columnViews.compactMap(\.snappedBodyHeight).min()
        for columnView in columnViews { columnView.levelBodyHeight = level }
    }

    /// UXP-18: the hint row on every lane or on none, so the lanes' "Add
    /// task" rows stay on one line.
    private func applyOverflowHintRows() {
        let anyBelow = columnViews.contains { $0.overflowHintCount > 0 }
        for columnView in columnViews { columnView.setOverflowHintRowShown(anyBelow) }
    }

    /// The sidebar layout's board (stage 7): each lane a tint that wraps its
    /// own cards, 12pt apart, as the prototype draws it.
    private(set) var usesWorkspaceStyle = false

    func adoptWorkspaceStyle() {
        guard !usesWorkspaceStyle else { return }
        usesWorkspaceStyle = true
        row.spacing = HelmMetrics.s3
        for columnView in columnViews { columnView.adoptWorkspaceStyle() }
    }

    /// R4-UI-09: a lane after the three status lanes, the width of each of
    /// them - the sidebar layout's Follow-ups. Wrapped exactly as a status
    /// lane is, so it hugs its own cards rather than taking the tallest
    /// lane's height. Hidden, it leaves the row and the three lanes share it.
    private var trailingLaneWrapper: NSStackView?

    func setTrailingLane(_ lane: NSView) {
        guard trailingLaneWrapper == nil, let first = row.arrangedSubviews.first else { return }
        let wrapper = NSStackView(views: [lane])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.setHuggingPriority(.required, for: .vertical)
        row.addArrangedSubview(wrapper)
        lane.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
        wrapper.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
        trailingLaneWrapper = wrapper
    }

    var trailingLaneShown: Bool {
        get { trailingLaneWrapper.map { !$0.isHidden } ?? false }
        set { trailingLaneWrapper?.isHidden = !newValue }
    }

    func setTasks(_ byColumn: [ShiftBoardColumn: [ShiftTask]],
                  projects: [ShiftProject],
                  theme: HelmTheme) {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for columnView in columnViews {
            columnView.setTasks(byColumn[columnView.column] ?? [], projects: byID, theme: theme)
        }
        // A workspace lane is as tall as its own cards; none of the plan
        // below applies to it.
        guard !usesWorkspaceStyle else { return }

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

    var onClearFilter: (() -> Void)? {
        didSet { for columnView in columnViews { columnView.onClearFilter = onClearFilter } }
    }

    func setLoading(_ loading: Bool) {
        for columnView in columnViews { columnView.setLoading(loading) }
    }

    func setFilterDescription(_ description: String?, clearTitle: String) {
        for columnView in columnViews { columnView.setFilterDescription(description, clearTitle: clearTitle) }
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

        addChip(id: nil, title: "All projects", tintHex: nil)
        for project in projects {
            addChip(id: project.id,
                    title: project.name.isEmpty ? "Untitled project" : project.name,
                    tintHex: ShiftProjectPalette.hex(for: ShiftProjectPalette.hue(for: project), in: theme))
        }
        applyTheme(theme)
    }

    private func addChip(id: String?, title: String, tintHex: String?) {
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
        button.tintHex = selected ? nil : tintHex
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
            chip.button.tintHex = chip.id == selectedProjectID || chip.id == nil
                ? nil
                : ShiftProjectPalette.hex(forProjectID: chip.id, in: projects, theme: theme)
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

/// UI-04: a task card's meta line - project, due, subtasks, attachment and
/// Low's chip - which wraps onto a second line rather than cutting what it
/// holds. Each item keeps its own fitting width and the line breaks between
/// items, so the project's name and the due state are never cut while they
/// fit a line of their own.
///
/// It is placed by frames, not a stack: an `NSStackView` lays its views on
/// one line and squeezes the one with the lowest compression resistance,
/// which was the project's name. Its width is the card's, handed in as
/// `layoutWidth` (gotcha (22)), and its intrinsic height follows from it.
final class ShiftCardMetaFlow: NSView {
    var items: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            for item in items {
                item.translatesAutoresizingMaskIntoConstraints = true
                addSubview(item)
            }
            invalidateIntrinsicContentSize()
        }
    }
    /// The width the line wraps at: the card's, less its padding.
    var layoutWidth: CGFloat = 0 {
        didSet {
            guard abs(layoutWidth - oldValue) > 0.5 else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    static let spacing = HelmMetrics.s2
    static let lineSpacing: CGFloat = 4

    override var isFlipped: Bool { true }

    /// The visible items, line by line, each at its own fitting size.
    func lines(width: CGFloat) -> [[(view: NSView, size: NSSize)]] {
        var lines: [[(view: NSView, size: NSSize)]] = [[]]
        var x: CGFloat = 0
        for item in items where !item.isHidden {
            var size = item.fittingSize
            size.width = min(size.width.rounded(.up), max(0, width))
            if !lines[lines.count - 1].isEmpty, x + Self.spacing + size.width > width {
                lines.append([])
                x = 0
            }
            x += (lines[lines.count - 1].isEmpty ? 0 : Self.spacing) + size.width
            lines[lines.count - 1].append((item, size))
        }
        return lines.filter { !$0.isEmpty }
    }

    override var intrinsicContentSize: NSSize {
        let width = layoutWidth > 0 ? layoutWidth : .greatestFiniteMagnitude
        let lines = self.lines(width: width)
        let height = lines.reduce(CGFloat(0)) { $0 + ($1.map(\.size.height).max() ?? 0) }
            + CGFloat(max(0, lines.count - 1)) * Self.lineSpacing
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for line in lines(width: bounds.width) {
            let height = line.map(\.size.height).max() ?? 0
            var x: CGFloat = 0
            for (view, size) in line {
                view.frame = NSRect(x: x, y: y + ((height - size.height) / 2).rounded(), width: size.width,
                                    height: size.height)
                x += size.width + Self.spacing
            }
            y += height + Self.lineSpacing
        }
    }

    #if FM_SELFTESTS
    /// How many lines the meta line takes at its width.
    var debugLineCount: Int { lines(width: bounds.width).count }
    #endif
}
