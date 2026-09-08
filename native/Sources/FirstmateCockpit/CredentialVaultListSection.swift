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
        /// Toggle this row's on-screen visibility. Never copies.
        var reveal: (() -> Void)?
        /// Copy this row's value. Never reveals.
        var copy: (() -> Void)?
        /// Whether the value is currently on screen for this row - drives which
        /// glyph the reveal button shows.
        var isRevealed: Bool = false
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

    func setItems(_ items: [Item]) {
        let previouslySelected = table.selectedRow
        self.items = items
        table.reloadData()
        if previouslySelected >= 0, previouslySelected < items.count, items[previouslySelected].isRecord {
            table.selectRowIndexes(IndexSet(integer: previouslySelected), byExtendingSelection: false)
        }
    }

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
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) where row < items.count {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CredentialVaultRecordView)?
                .setSelected(table.selectedRowIndexes.contains(row))
        }
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
private final class CredentialVaultRecordView: NSView {

    /// `.quiet`, so two icon buttons per row read as row-level affordances
    /// rather than two competing bordered controls on every line.
    private let revealButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "eye")
    private let copyButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "doc.on.doc")
    private let overflowButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "ellipsis")
    private let actions = NSStackView()
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
        for button in [revealButton, copyButton, overflowButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            actions.addArrangedSubview(button)
        }

        row = HelmAccentRow(trailingAccessory: actions, gradientBadge: true)
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
    func debugMenu() -> NSMenu? { overflow.isEmpty ? nil : buildMenu() }

    /// The `⋯` menu and the right-click menu are built from one array, so the
    /// two cannot drift apart - `HostsListSection`'s own reason for doing it
    /// this way.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, action) in overflow.enumerated() {
            let entry = NSMenuItem(title: action.title, action: #selector(overflowItemPicked(_:)), keyEquivalent: "")
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
