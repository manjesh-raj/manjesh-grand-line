// Manjesh Grand Line - native macOS app.
//
// The credential list: a `HelmCard` whose body is a demand-driven
// `NSTableView` of `HelmAccentRow` cards, grouped by category, with a
// `HelmEmptyState` rendered as a row of the same table.
//
// **The whole point of this file is that Reveal and Copy live on the row.**
// That is the captain's own review feedback, twice over: "I would like
// something like view which would be showing my hidden password as well as
// copy... I do not want to go inside each of them here", and separately
// "Reveal and copy should be separate, with their own icons. I don't always
// want to reveal when I copy, for example while screen sharing." So each row
// carries two independent icon buttons and neither implies the other:
//
//   * **Reveal** toggles the value visible *on this row* and never touches the
//     clipboard.
//   * **Copy** writes the value to the clipboard and never puts it on screen.
//
// Item Detail still exists, for what a row genuinely cannot show - notes, exact
// timestamps, edit, delete, per-item audit history - which is why the row also
// has a `⋯` overflow. Routine use never needs it.
//
// **Where the revealed value is rendered, and why there.** In the row's own
// meta line, in `HelmType.code()`, replacing the account line while revealed.
// Two reasons: the table has a fixed `rowHeight` (a card list's height has to
// stay predictable, which is why every sibling list in this app fixes it), so a
// third line is not available without making every row taller for the one that
// is revealed; and the switch to a monospace line is itself the signal that
// what is on screen now is the secret rather than a description of it. The
// title still names the credential and the kicker still shows the category, so
// nothing a captain scans by is lost.
//
// **Structure is `HostsListSection`'s, deliberately** - an `NSTableView` and
// never an `NSStackView` of permanent rows (see `DiffResultView.swift`'s header
// for the ~13-second layout pass that pattern produced once a list grew, and
// `ShiftListViews.swift` for the same call made for the same reason), the same
// `.fullWidth`/`selectionHighlightStyle = .none` selection treatment (audit
// §5.2: `.sourceList` installs the private system-accent-blue material), and
// the same group-header and empty-state-as-a-row furniture.

import AppKit

// MARK: - Pasteboard

/// The list's own drag payload for a reorder: a credential id, nothing else.
///
/// A private type rather than `.string`, matching `ShiftBoardPasteboard`'s own
/// reasoning verbatim: a drag from anywhere else in the app (or from another
/// app) can never be mistaken for a credential and dropped into the list.
enum CredentialVaultDragPasteboard {
    static let credentialType = NSPasteboard.PasteboardType("com.firstmate.cockpit.vault.credential-id")

    static func item(credentialID: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(credentialID, forType: credentialType)
        return item
    }

    static func credentialID(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: credentialType)
    }
}

final class CredentialVaultListSection: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    /// One action offered by a row's `⋯` menu.
    struct Action {
        let title: String
        let symbol: String?
        let run: () -> Void

        init(title: String, symbol: String? = nil, run: @escaping () -> Void) {
            self.title = title
            self.symbol = symbol
            self.run = run
        }
    }

    struct Item {
        enum Kind {
            case record
            case group(String)
            case empty(symbol: String, title: String, body: String)
        }

        var kind: Kind = .record
        var content: HelmAccentRow.Content
        /// The credential's id, so the reveal state survives a `reloadData`
        /// (which happens on every store change, including one caused from a
        /// different row).
        var credentialID: String = ""
        /// The credential's own category - `nil` for a `.group`/`.empty` row.
        /// Drag-and-drop reorder is scoped to one category's own records (a
        /// drop may never move a credential across a category boundary), and
        /// this is how the table's drag validation tells which group a given
        /// row - or the boundary between two rows - belongs to, with no need
        /// to parse the group header's own display string.
        var category: CredentialCategory? = nil
        /// Toggle this row's on-screen visibility. Never copies.
        var reveal: (() -> Void)?
        /// Copy this row's value. Never reveals.
        var copy: (() -> Void)?
        /// Whether the value is currently on screen for this row - drives which
        /// glyph the reveal button shows.
        var isRevealed: Bool = false
        /// Whether this credential requires Touch ID to reveal. Rendered as a
        /// small non-interactive glyph in `CredentialVaultRecordView`'s own
        /// trailing icon cluster - first, before Reveal/Copy/Overflow - rather
        /// than as `HelmAccentRow.Content.titleAccessorySymbol`. That field
        /// sits inline next to the title, vertically centered only against
        /// the title *line*; putting it in the same cluster as the row's
        /// other icons is what makes it centered against the row's full
        /// height by construction, matching them, instead of needing its own
        /// alignment math.
        var requiresTouchIDIndicator: Bool = false
        var overflow: [Action] = []
        /// Double-click, and the `⋯` menu's first entry: open Item Detail.
        var activate: (() -> Void)?

        init(content: HelmAccentRow.Content) { self.content = content }

        static func group(_ name: String) -> Item {
            var item = Item(content: .init(tint: .neutral, kicker: name))
            item.kind = .group(name)
            return item
        }

        static func empty(symbol: String, title: String, body: String) -> Item {
            var item = Item(content: .init(tint: .neutral, kicker: ""))
            item.kind = .empty(symbol: symbol, title: title, body: body)
            return item
        }

        var isRecord: Bool {
            if case .record = kind { return true }
            return false
        }
    }

    let card = HelmCard()

    /// A row was picked. One click, not two - the inspector is permanent, so
    /// selecting a credential *is* opening it.
    var onSelectRow: ((String) -> Void)?

    /// The captain dragged a row to a new position within its own category
    /// group. `beforeID` is the *visible* neighboring credential it should
    /// now sit directly above, or `nil` for "at the end of what is currently
    /// shown" - deliberately a neighbor rather than an absolute row index, so
    /// the caller (which knows the credential's real, complete, possibly
    /// search-filtered-out category list) can splice the move in without this
    /// section having to reason about anything outside what it renders.
    var onReorder: ((_ draggedID: String, _ beforeID: String?) -> Void)?

    private let table = HelmTableView()
    private let scroll = NSScrollView()
    private var items: [Item] = []
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Measured for `ShiftListViews` on the same three text lines and shared by
    /// every `HelmAccentRow` list in this app. Scaled, so GL-32's chrome-text
    /// setting actually grows the row instead of clipping its descenders.
    static let baseRecordRowHeight: CGFloat = 78
    static var recordRowHeight: CGFloat { HelmType.scaledRowHeight(baseRecordRowHeight) }
    static let groupRowHeight: CGFloat = 26
    static let minimumEmptyRowHeight: CGFloat = 180

    private static let columnID = NSUserInterfaceItemIdentifier("vaultListCol")
    private static let recordID = NSUserInterfaceItemIdentifier("vaultListRecord")
    private static let groupID = NSUserInterfaceItemIdentifier("vaultListGroup")
    private static let emptyID = NSUserInterfaceItemIdentifier("vaultListEmpty")

    override init() {
        super.init()

        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.rowHeight = Self.recordRowHeight
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.allowsEmptySelection = true
        // Drag-and-drop reorder within the table - `NSTableView`'s own
        // built-in mechanism (`pasteboardWriterForRow`/`validateDrop`/
        // `acceptDrop` below), rather than a bespoke `NSDraggingSource` like
        // `ShiftBoardCardView`'s: that one exists because the Kanban board is
        // several independent card views spread across separate columns, not
        // rows of one `NSTableView` - this list is exactly the case AppKit's
        // own reorder API is for. `.gap`, not `.regular`, shows a thin
        // insertion line between rows rather than highlighting a whole row,
        // which is the "moving between two positions" feedback a reorder
        // needs.
        table.registerForDraggedTypes([CredentialVaultDragPasteboard.credentialType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewResized),
                                               name: NSView.frameDidChangeNotification,
                                               object: scroll.contentView)

        card.setBody(scroll, insets: NSEdgeInsets(top: HelmMetrics.s3, left: HelmMetrics.s3,
                                                  bottom: HelmMetrics.s3, right: HelmMetrics.s3))
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Content

    /// `selecting` is the credential the page wants highlighted - the one the
    /// inspector is showing. Selection is keyed by credential id rather than by
    /// row index because the rows are rebuilt on every store change, search and
    /// filter, and an index means a different credential after any of those.
    func setItems(_ items: [Item], selecting selectedID: String? = nil) {
        self.items = items
        isRestoringSelection = true
        table.reloadData()
        if let selectedID, let row = items.firstIndex(where: { $0.isRecord && $0.credentialID == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        isRestoringSelection = false
    }

    /// Set while this section is re-applying the page's own selection, so
    /// restoring it does not report back as a fresh click and re-enter
    /// `render()`.
    private var isRestoringSelection = false

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        // Every cell carries theme-derived colours that do not re-derive
        // themselves, and a chrome-text-scale change arrives as an app-wide
        // theme re-fire - so the row height is re-read here too (GL-32).
        table.rowHeight = Self.recordRowHeight
        table.reloadData()
    }

    /// Scroll back to the top - called when the filter changes, so a captain
    /// who searches does not land halfway down the results of the last query.
    func scrollToTop() {
        table.scrollRowToVisible(0)
    }

    @objc private func clipViewResized() {
        // GL-20: gate on visibility. This is a permanently-mounted,
        // `isHidden`-toggled destination, so an ungated handler recomputes row
        // heights on every resize frame no matter which page is showing.
        guard let clip = table.enclosingScrollView?.contentView,
              clip.window != nil, !clip.isHiddenOrHasHiddenAncestor else { return }
        guard items.contains(where: { if case .empty = $0.kind { return true }; return false }) else { return }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        items[row].activate?()
    }

    // MARK: Probe / self-test surface

    var debugRowCount: Int { items.count }
    var debugTable: NSTableView { table }

    func debugRowView(_ row: Int) -> NSView? {
        table.view(atColumn: 0, row: row, makeIfNecessary: true)
    }

    func debugAccentRow(_ row: Int) -> HelmAccentRow? {
        (debugRowView(row) as? CredentialVaultRecordView)?.debugAccentRow
    }

    /// `row`'s real Reveal button, so a probe drives the genuine control's
    /// target/action rather than calling the closure behind it.
    func debugRevealButton(_ row: Int) -> NSButton? {
        (debugRowView(row) as? CredentialVaultRecordView)?.debugRevealButton
    }

    /// `row`'s real Copy button - the other half of the split the captain asked
    /// for, and the reason a probe has to be able to click each independently.
    func debugCopyButton(_ row: Int) -> NSButton? {
        (debugRowView(row) as? CredentialVaultRecordView)?.debugCopyButton
    }

    /// `row`'s Touch ID glyph, when it has one - so a probe can measure its
    /// frame against `debugRevealButton`'s to confirm both now share a
    /// centerY, and that it renders first in the trailing icon cluster.
    func debugTouchIDIndicator(_ row: Int) -> NSImageView? {
        (debugRowView(row) as? CredentialVaultRecordView)?.debugTouchIDIndicator
    }

    /// `row`'s real trailing-icon-cluster stack, for direct constraint/
    /// geometry inspection - a probe measuring only final `.frame` values
    /// cannot tell whether a discrepancy comes from the stack's own internal
    /// alignment constraints or from something else entirely.
    func debugActionsStack(_ row: Int) -> NSStackView? {
        (debugRowView(row) as? CredentialVaultRecordView)?.debugActionsStack
    }

    func debugRowMenu(_ row: Int) -> NSMenu? {
        (debugRowView(row) as? CredentialVaultRecordView)?.debugMenu()
    }

    func debugItem(_ row: Int) -> Item? {
        row < items.count ? items[row] : nil
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < items.count else { return Self.recordRowHeight }
        switch items[row].kind {
        case .record: return Self.recordRowHeight
        case .group: return Self.groupRowHeight
        case .empty:
            let others = items.enumerated().reduce(CGFloat(0)) { total, pair in
                guard pair.offset != row else { return total }
                switch pair.element.kind {
                case .record: return total + Self.recordRowHeight
                case .group: return total + Self.groupRowHeight
                case .empty: return total
                }
            }
            let spacing = CGFloat(max(items.count - 1, 0)) * tableView.intercellSpacing.height
            let available = scroll.contentView.bounds.height - others - spacing
            return max(Self.minimumEmptyRowHeight, available)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < items.count && items[row].isRecord
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]
        switch item.kind {
        case .group(let name):
            let cell = (tableView.makeView(withIdentifier: Self.groupID, owner: nil) as? CredentialVaultGroupHeaderView)
                ?? { let v = CredentialVaultGroupHeaderView(); v.identifier = Self.groupID; return v }()
            cell.configure(name: name, theme: theme)
            return cell
        case .empty(let symbol, let title, let body):
            // `.standard`, not `.compact`: this state is the whole card body of
            // a full-width page. Reused by identifier, but only while the
            // symbol matches - the glyph is fixed at init.
            let reused = tableView.makeView(withIdentifier: Self.emptyID, owner: nil) as? HelmEmptyState
            let cell = (reused?.symbolName == symbol ? reused : nil)
                ?? { let v = HelmEmptyState(symbol: symbol, title: title, body: body, size: .standard)
                     v.identifier = Self.emptyID
                     return v }()
            cell.setText(title: title, body: body)
            cell.applyTheme(theme)
            return cell
        case .record:
            let cell = (tableView.makeView(withIdentifier: Self.recordID, owner: nil) as? CredentialVaultRecordView)
                ?? { let v = CredentialVaultRecordView(); v.identifier = Self.recordID; return v }()
            cell.configure(item, theme: theme, selected: tableView.selectedRowIndexes.contains(row))
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isRestoringSelection {
            let row = table.selectedRow
            if row >= 0, row < items.count, items[row].isRecord {
                onSelectRow?(items[row].credentialID)
            }
        }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) where row < items.count {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CredentialVaultRecordView)?
                .setSelected(table.selectedRowIndexes.contains(row))
        }
    }

    // MARK: NSTableView - drag-and-drop reorder
    //
    // The manual reorder the captain asked for, verbatim: "I need that
    // freedom to rearrange... I should be able to sort anything irrespective
    // of whether it's created first or last." Reordering is scoped to one
    // category's own group - a drop may never move a credential across a
    // category boundary, which is what `categoryGroup(atBoundary:)` enforces
    // in both `validateDrop` and `acceptDrop` below.

    /// Only a `.record` row may be dragged - a group header or the empty
    /// state has no credential to move.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < items.count, items[row].isRecord else { return nil }
        return CredentialVaultDragPasteboard.item(credentialID: items[row].credentialID)
    }

    /// Only `.above` (insert-between-rows) is meaningful for a reorder - a
    /// `.on` drop (onto a row) has no defined behaviour here - and only when
    /// the drop position is inside the dragged credential's own category
    /// group.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above,
              let sourceID = CredentialVaultDragPasteboard.credentialID(from: info.draggingPasteboard),
              let sourceCategory = category(ofCredential: sourceID),
              categoryGroup(atBoundary: row) == sourceCategory else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard dropOperation == .above,
              let sourceID = CredentialVaultDragPasteboard.credentialID(from: info.draggingPasteboard),
              let sourceCategory = category(ofCredential: sourceID),
              categoryGroup(atBoundary: row) == sourceCategory else { return false }
        // The record currently sitting right at the drop boundary - the
        // *visible* neighbor the dragged credential should now sit directly
        // above - or nil when the boundary is past the last visible record
        // of this category (dropped at the end of what is currently shown).
        let beforeID: String? = (row < items.count && items[row].isRecord && items[row].category == sourceCategory)
            ? items[row].credentialID
            : nil
        onReorder?(sourceID, beforeID)
        return true
    }

    private func category(ofCredential id: String) -> CredentialCategory? {
        items.first { $0.isRecord && $0.credentialID == id }?.category
    }

    /// The category whose group brackets `boundaryRow` - i.e. the category of
    /// whichever *record* straddles this drop position. A boundary is
    /// checked against the row just before it first (the common case: the
    /// end of a group, or a position in its middle), then the row right at
    /// it (the top of a group, which has no record before it - the header
    /// does). `nil` when the boundary sits between two different
    /// categories' own groups, or right before/after a group header with no
    /// record on either side to disambiguate it, or past the end of the
    /// list.
    private func categoryGroup(atBoundary boundaryRow: Int) -> CredentialCategory? {
        if boundaryRow > 0, boundaryRow - 1 < items.count, let category = items[boundaryRow - 1].category {
            return category
        }
        if boundaryRow < items.count, let category = items[boundaryRow].category {
            return category
        }
        return nil
    }
}

// MARK: - Group header

/// A category section header - the app's one kicker treatment
/// (`HelmType.kickerAttributes`, never a hand-rolled kern; see
/// `HelmContrastSelfTest.checkNoHandRolledKickers`).
private final class CredentialVaultGroupHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, theme: HelmTheme) {
        label.attributedStringValue = NSAttributedString(
            string: name.uppercased(),
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme))
        )
    }
}

// MARK: - Record row

/// One credential row: the shared `HelmAccentRow` plus this list's own three
/// trailing controls - Reveal, Copy, and a `⋯` overflow.
///
/// The stack-and-button priority trio (`.fill` distribution, `.required` at the
/// *stack* level, `.required` content hugging on each button) is not
/// boilerplate: without it `.fill` stretches whichever control can grow, which
/// is what made a 90pt "Connect" render ~900pt wide in the first Phase 5 render
/// of the Hosts page (AGENTS.md gotcha (12) - the content-level API is a no-op
/// on the stack itself, and the stack-level one is a no-op on the buttons).
///
/// **`TrailingActionsStack` corrects `touchIDIndicator`'s vertical position
/// directly, in frame space, at the end of every one of ITS OWN layout
/// passes - and it has to be a subclass of the stack itself, not an override
/// on an ancestor.** Measured, not theorized: `NSView.layout()` is called
/// once per view during a top-down `layoutSubtreeIfNeeded()` walk, and a
/// view's own override only resolves what constraints attached to *that*
/// view govern - a subview further down the tree gets its OWN separate
/// `layout()` call, LATER in the same pass, which can (and does, for an
/// `NSStackView`) re-derive and overwrite its own arranged subviews'
/// positions from its own internal `.Align` constraints regardless of what
/// an ancestor did moments earlier. An earlier attempt at this fix put the
/// correction on `CredentialVaultRecordView.layout()` (an ANCESTOR of this
/// stack) and it appeared to work locally purely by coincidence - a
/// dedicated probe confirmed the stack's own subsequent layout pass silently
/// discarded that correction every time, and the reason it "passed" anyway
/// is that this dev machine's underlying Auto-Layout-resolved answer already
/// happens to be correct on its own (see the class comment on why that
/// doesn't hold on every macOS/AppKit build). Overriding `layout()` HERE,
/// on the stack itself, is what actually runs last for this relationship.
private final class TrailingActionsStack: NSStackView {
    /// Set once, after every arranged subview has been added - the glyph to
    /// correct, and the button whose alignment-rect-resolved centerY it
    /// should match exactly.
    var glyphToCorrect: NSView?
    var referenceCandidates: [NSView] = []

    override func layout() {
        super.layout()
        guard let glyphToCorrect, !glyphToCorrect.isHidden else { return }
        guard let reference = referenceCandidates.first(where: { !$0.isHidden }) else { return }
        let targetCenterY = reference.frame.midY
        var frame = glyphToCorrect.frame
        let correctedOriginY = targetCenterY - frame.height / 2
        guard abs(frame.origin.y - correctedOriginY) > 0.001 else { return }
        frame.origin.y = correctedOriginY
        glyphToCorrect.frame = frame
    }
}

private final class CredentialVaultRecordView: NSView {

    /// A non-interactive glyph, not a fourth button - it states a fact about
    /// the credential rather than offering an action. First in `actions`, so
    /// the row reads chip, then fingerprint, then Reveal/Copy/Overflow as one
    /// icon cluster - the captain's own ordering ask, addressed by the same
    /// move that fixes its vertical alignment (see `TrailingActionsStack`'s
    /// own header note above).
    private let touchIDIndicator = NSImageView()
    /// `.quiet`, so two icon buttons per row read as row-level affordances
    /// rather than two competing bordered controls on every line.
    private let revealButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "eye")
    private let copyButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "doc.on.doc")
    private let overflowButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "ellipsis")
    private let actions = TrailingActionsStack()
    private let row: HelmAccentRow

    private var reveal: (() -> Void)?
    private var copy: (() -> Void)?
    private var overflow: [CredentialVaultListSection.Action] = []

    init() {
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = HelmMetrics.s1
        actions.distribution = .fill
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setClippingResistancePriority(.required, for: .horizontal)
        actions.translatesAutoresizingMaskIntoConstraints = false

        // 11pt / `.semibold`, matching `HelmButton.Size.small`'s own symbol
        // size (`rebuildImage()`'s configuration) - so the glyph reads as
        // part of the same icon cluster as the buttons beside it rather than
        // a differently-scaled visitor. A flat template image (no
        // `hierarchicalColor`), tinted per theme in `configure`, the same way
        // `HelmAccentRow`'s own `titleAccessory` tinted this exact glyph
        // before it moved here.
        touchIDIndicator.image = HelmSymbol.image("touchid", pointSize: 11, weight: .semibold)
        touchIDIndicator.imageScaling = .scaleProportionallyUpOrDown
        touchIDIndicator.translatesAutoresizingMaskIntoConstraints = false
        touchIDIndicator.setContentHuggingPriority(.required, for: .horizontal)
        touchIDIndicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        touchIDIndicator.isHidden = true
        actions.addArrangedSubview(touchIDIndicator)

        for button in [revealButton, copyButton, overflowButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            actions.addArrangedSubview(button)
        }

        // See `TrailingActionsStack`'s own header for why this correction
        // has to live on the stack itself, not on an ancestor.
        actions.glyphToCorrect = touchIDIndicator
        actions.referenceCandidates = [revealButton, copyButton, overflowButton]

        row = HelmAccentRow(trailingAccessory: actions, gradientBadge: true,
                                  maxContentWidth: HelmAccentRow.recordContentWidth)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked)
        overflowButton.toolTip = "More actions"

        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: CredentialVaultListSection.Item, theme: HelmTheme, selected: Bool) {
        reveal = item.reveal
        copy = item.copy
        overflow = item.overflow

        touchIDIndicator.isHidden = !item.requiresTouchIDIndicator
        touchIDIndicator.toolTip = item.requiresTouchIDIndicator ? "Requires Touch ID to reveal" : nil
        // `mutedInk`, matching every other row-level status glyph
        // (`HelmAccentRow`'s own `titleAccessory` used the identical tint
        // before this moved).
        touchIDIndicator.contentTintColor = HelmTheme.mutedInk(theme)

        // The glyph and the tooltip both say which way the toggle goes, so the
        // control is readable without hovering and legible to VoiceOver.
        revealButton.symbolName = item.isRevealed ? "eye.slash" : "eye"
        revealButton.toolTip = item.isRevealed
            ? "Hide the value again (this never touched the clipboard)"
            : "Show the value on this row - does not copy it"
        // The tint is the one visible difference between the two buttons'
        // *states*: a revealed row's eye is accented so it is obvious at a
        // glance which rows currently have a value on screen.
        revealButton.tint = item.isRevealed ? .warn : nil
        revealButton.isHidden = item.reveal == nil

        copyButton.toolTip = "Copy the value to the clipboard - does not show it on screen"
        copyButton.isHidden = item.copy == nil

        overflowButton.isHidden = item.overflow.isEmpty
        menu = item.overflow.isEmpty ? nil : buildMenu()
        row.isRowSelected = selected
        row.configure(item.content, theme: theme)
    }

    func setSelected(_ selected: Bool) { row.isRowSelected = selected }

    var debugAccentRow: HelmAccentRow { row }
    var debugRevealButton: NSButton? { revealButton.isHidden ? nil : revealButton }
    var debugCopyButton: NSButton? { copyButton.isHidden ? nil : copyButton }
    /// The Touch ID glyph itself, so a probe can measure its frame against
    /// `debugRevealButton`'s to confirm the two now share a centerY.
    var debugTouchIDIndicator: NSImageView? { touchIDIndicator.isHidden ? nil : touchIDIndicator }
    var debugActionsStack: NSStackView { actions }
    func debugMenu() -> NSMenu? { overflow.isEmpty ? nil : buildMenu() }

    /// The `⋯` menu and the right-click menu are built from one array, so the
    /// two cannot drift apart - `HostsListSection`'s own reason for doing it
    /// this way.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, action) in overflow.enumerated() {
            let entry = NSMenuItem(title: action.title, action: #selector(overflowItemPicked(_:)), keyEquivalent: "")
            if let symbol = action.symbol { entry.withSymbol(symbol) }
            entry.target = self
            entry.tag = index
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func revealClicked() { reveal?() }
    @objc private func copyClicked() { copy?() }

    @objc private func overflowClicked() {
        guard !overflow.isEmpty else { return }
        buildMenu().popUp(positioning: nil,
                          at: NSPoint(x: 0, y: overflowButton.bounds.height + 2),
                          in: overflowButton)
    }

    @objc private func overflowItemPicked(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < overflow.count else { return }
        overflow[sender.tag].run()
    }
}
