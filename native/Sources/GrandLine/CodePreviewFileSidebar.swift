// Grand Line - native macOS app.
//
// Code Preview's snippet list: a left column naming every open snippet, the
// way VS Code's Explorer names the files in a folder, which the captain can
// hide and bring back with ⌘B.
//
// ## Why a flat list and not a folder tree
//
// A snippet is one file in one folder, `GrandLineDocs/code-snippets/`, and
// `CodePreviewStore.sanitize` turns every `/` a captain types into `-`. So
// there is no folder to group by and no folder ever will be one: a tree here
// would be a single root node with every file under it. The column is the
// flat list that structure actually is, sorted the way a file explorer sorts
// a folder (`localizedStandardCompare`, so `snippet-2` comes before
// `snippet-10`). The tab strip keeps its own order - the order snippets were
// opened in - so the two views answer two different questions.
//
// ## Why it is not a `HelmPageSidebar`
//
// The same call DevOps Commands made for its column (UI-45): that component
// is a nav of a handful of filter rows, and this is a list of up to hundreds
// of records with a close control per row, a filter field and keyboard
// navigation. So the column wears `HelmPageSidebar`'s plain surface, its
// kicker header (`headerString`) and its row recipe (`rowPalette`) rather
// than being one, and a selected row here reads exactly like a selected row
// in Hosts, Notebook or Tasks.
//
// ## The unsaved dot, and how short-lived it is
//
// There is no Save button: an edit reaches disk on the page's own 500ms
// debounce and git a few seconds later (`CodePreviewStore`'s header). So the
// only unsaved state is that half second, and the sidebar layout marks it -
// the editor page posts `pending` on the first keystroke of a burst and the
// dot goes when the debounced `change` has been written. The floating bar's
// column never receives a dirty key and draws exactly what it did. The orange
// dot a tab chip carries is still `TabChipView`'s *selected* marker (E4).

import AppKit

// MARK: - The list model (pure)

/// One open snippet as the column sees it: the controller's stable `key` (the
/// editor model's identity, which survives a rename) and the filename.
struct CodePreviewFileEntry: Equatable {
    let key: String
    let name: String

    var language: CodePreviewLanguage { CodePreviewLanguage.forFilename(name) }
}

/// The column's rows, as a pure function of the open snippets and the filter -
/// so the order, the filter and the icon table are asserted without a window.
enum CodePreviewFileList {

    /// Every entry the column shows for `filter`, in explorer order.
    ///
    /// Explorer order is the folder's own order: `localizedStandardCompare`, so
    /// a numbered run sorts the way a person counts. Two names that compare
    /// equal (`Notes.txt` / `notes.txt` on a case-sensitive volume) fall back
    /// to a plain comparison and then to the key, so the order is total and a
    /// rebuild can never shuffle them.
    static func visibleEntries(_ entries: [CodePreviewFileEntry], filter: String) -> [CodePreviewFileEntry] {
        entries
            .filter { matches($0.name, filter: filter) }
            .sorted { lhs, rhs in
                switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return (lhs.name, lhs.key) < (rhs.name, rhs.key)
                }
            }
    }

    /// Whether `name` survives `filter`.
    ///
    /// Every whitespace-separated term has to appear somewhere in the name,
    /// ignoring case and diacritics - so `hook slack` finds
    /// `https-hooks-slack-com-services.txt`, and a blank filter keeps
    /// everything.
    static func matches(_ name: String, filter: String) -> Bool {
        let terms = filter.split(whereSeparator: { $0.isWhitespace })
        return terms.allSatisfy { term in
            name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The SF Symbol a row leads with, by language.
    ///
    /// SF Symbols has no per-language glyphs beyond Swift's, so this is a
    /// family table: a shell script reads as a terminal, a data file as
    /// braces, a config file as a gear. Every name here is asserted to resolve
    /// by `CodePreviewSidebarSelfTest`, because `NSImage(systemSymbolName:)`
    /// fails silently and this app has shipped an invisible icon that way.
    static func symbol(for language: CodePreviewLanguage) -> String {
        switch language.id {
        case "swift": return "swift"
        case "shell": return "terminal"
        case "json": return "curlybraces"
        case "javascript", "typescript": return "curlybraces.square"
        case "python", "go", "rust": return "chevron.left.forwardslash.chevron.right"
        case "xml": return "chevron.left.slash.chevron.right"
        case "yaml": return "list.bullet.indent"
        case "ini", "hcl": return "gearshape"
        case "markdown": return "doc.richtext"
        case "sql": return "cylinder"
        case "dockerfile": return "shippingbox"
        default: return plainSymbol
        }
    }

    static let plainSymbol = "doc.text"
}

// MARK: - Preferences

/// Whether the column is showing, and how wide it is - both remembered across
/// launches through `AppDefaults.store`, which a self-test process redirects
/// to its own domain.
enum CodePreviewSidebarPreferences {
    static let visibleKey = "fm.codePreview.sidebarVisible"
    static let widthKey = "fm.codePreview.sidebarWidth"

    /// `HelmPageSidebar`'s own column width, so a fresh profile's column
    /// matches every other sidebar in the app until the captain drags it.
    static let defaultWidth: CGFloat = HelmPageSidebar.width
    /// Narrow enough to give the editor room on a small window, wide enough
    /// that a middle-truncated name still shows both ends.
    static let minimumWidth: CGFloat = 160
    /// Past this the column stops helping and starts costing the editor.
    static let maximumWidth: CGFloat = 420

    /// Shown unless the captain has hidden it: a missing key is a profile that
    /// has never toggled it, and the list is the whole point of the change.
    static func isVisible(in defaults: UserDefaults = AppDefaults.store) -> Bool {
        (defaults.object(forKey: visibleKey) as? Bool) ?? true
    }

    static func setVisible(_ visible: Bool, in defaults: UserDefaults = AppDefaults.store) {
        defaults.set(visible, forKey: visibleKey)
    }

    /// The stored width, clamped. A missing or nonsensical value (a hand-edited
    /// domain, a value from a build with different bounds) reads as the
    /// default rather than as a zero-width column nobody can grab.
    static func width(in defaults: UserDefaults = AppDefaults.store) -> CGFloat {
        guard let stored = defaults.object(forKey: widthKey) as? Double, stored.isFinite, stored > 0 else {
            return defaultWidth
        }
        return clamp(CGFloat(stored))
    }

    static func setWidth(_ width: CGFloat, in defaults: UserDefaults = AppDefaults.store) {
        defaults.set(Double(clamp(width)), forKey: widthKey)
    }

    static func clamp(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minimumWidth), maximumWidth)
    }
}

// MARK: - The column

/// The snippet list itself: a kicker header with a count, a filter field, and
/// a scrolling list of rows.
///
/// A dumb view, like `TabChipView`: every action goes back to
/// `CodePreviewController` through a closure, and the controller decides what
/// opening, closing or renaming a snippet means.
final class CodePreviewFileSidebar: NSView {

    var onOpen: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onDuplicate: ((String) -> Void)?
    var onRename: ((String) -> Void)?
    /// Escape from the list hands the keyboard back to the editor.
    var onDismissKeyboardFocus: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    let filterField = HelmSearchField(placeholder: "Filter snippets")
    private let scroll = NSScrollView()
    private let listView = CodePreviewFileListView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    private var allEntries: [CodePreviewFileEntry] = []
    private var dirtyKeys: Set<String> = []
    /// The sidebar layout's card header: "Snippets" as a card title and the
    /// count as "8 items", rather than the floating bar's kicker and bare
    /// number. Set once, when the page adopts that layout.
    var usesCardHeader = false {
        didSet {
            countLabel.stringValue = Self.countText(allEntries.count, card: usesCardHeader)
            applyTheme(theme)
        }
    }
    private var visible: [CodePreviewFileEntry] = []
    private var rows: [CodePreviewFileRow] = []
    private var activeKey: String?
    private var filter = ""
    /// Which row the arrow keys are on. Separate from `activeKey`: moving
    /// through the list must not open every snippet it passes, which is the
    /// whole difference between browsing and choosing.
    private var focusedIndex: Int?
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Denser than `HelmPageSidebar.Metrics.rowHeight` (34): that column is a
    /// nav of a handful of rows, this one is a list that has to stay scannable
    /// at a hundred. 28pt is `TabChipView`'s own height, so a row and a tab
    /// are one size.
    static let rowHeight: CGFloat = HelmPageToolbar.iconButtonSide

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Snippets")

        let inset = HelmPageSidebar.Metrics.rowInset

        headerLabel.placeholderString = "Snippets"
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = HelmType.captionSmall()
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(headerLabel)
        addSubview(countLabel)

        filterField.toolTip = "Filter the open snippets by name - every word has to match"
        filterField.onTextChanged = { [weak self] text in self?.filterChanged(text) }
        filterField.onCommand = { [weak self] selector in self?.handleFilterCommand(selector) ?? false }
        // Nothing in this column may be a floor on the window (gotcha (13)):
        // the field's placeholder must truncate rather than widen the page.
        filterField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(filterField)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s0
        stack.translatesAutoresizingMaskIntoConstraints = false
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.addSubview(stack)
        listView.owner = self

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Overlay, so a long list does not narrow every row by a scroller
        // track when "Show scroll bars: Always" is on (gotcha (4)'s ~15pt).
        scroll.scrollerStyle = .overlay
        scroll.documentView = listView
        addSubview(scroll)

        emptyLabel.font = HelmType.caption()
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        // A wrapping label's whole string is otherwise a width floor on the
        // column and through it on the window (`HelmPageSidebar`'s U9 note).
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.preferredMaxLayoutWidth = CodePreviewSidebarPreferences.minimumWidth - 2 * inset
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s1),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: headerLabel.trailingAnchor,
                                                constant: HelmMetrics.s1),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            countLabel.firstBaselineAnchor.constraint(equalTo: headerLabel.firstBaselineAnchor),

            filterField.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterField.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterField.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: HelmMetrics.s2),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: HelmMetrics.s2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Gotcha (4): the document follows the clip view's width, never
            // the scroll view's, and only on the axis that does not scroll.
            listView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: listView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: listView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: listView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: listView.bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: HelmMetrics.s1),
        ])
        applyTheme(theme)
    }

    // MARK: Content

    /// Hands the column the open snippets and which one is on screen.
    ///
    /// Rows are rebuilt only when the set of names actually changed; a
    /// selection change is a repaint. The controller calls this on every
    /// select, and a hundred-row rebuild per click is the PF11 shape
    /// `HelmPageSidebar.setSections` already had to un-learn.
    func setEntries(_ entries: [CodePreviewFileEntry], activeKey: String?, dirtyKeys: Set<String> = []) {
        let changed = entries != allEntries
        allEntries = entries
        self.activeKey = activeKey
        self.dirtyKeys = dirtyKeys
        if changed {
            rebuildRows()
        } else {
            restyleRows()
        }
        countLabel.stringValue = Self.countText(entries.count, card: usesCardHeader)
    }

    static func countText(_ count: Int, card: Bool) -> String {
        guard card else { return "\(count)" }
        return count == 1 ? "1 item" : "\(count) items"
    }

    /// "The list is as tall as its rows", for a container that wants to hug
    /// them - the sidebar layout's snippet card. The caller picks the
    /// priority, so a page-height cap can still win. Never shorter than one
    /// row, so the empty-filter sentence has somewhere to sit.
    func contentHeightPreference() -> NSLayoutConstraint {
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.rowHeight).isActive = true
        return scroll.heightAnchor.constraint(equalTo: listView.heightAnchor)
    }

    /// Scrolls the active row into view - the list's half of "the file you are
    /// looking at is never off screen".
    func revealActiveRow() {
        guard let index = visible.firstIndex(where: { $0.key == activeKey }) else { return }
        reveal(index)
    }

    private func filterChanged(_ text: String) {
        filter = text
        focusedIndex = nil
        rebuildRows()
    }

    private func rebuildRows() {
        visible = CodePreviewFileList.visibleEntries(allEntries, filter: filter)
        for row in rows {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rows = visible.map { entry in
            let row = CodePreviewFileRow(entry: entry)
            row.onOpen = { [weak self] in self?.open(key: entry.key) }
            row.onClose = { [weak self] in self?.onClose?(entry.key) }
            row.onDuplicate = { [weak self] in self?.onDuplicate?(entry.key) }
            row.onRename = { [weak self] in self?.onRename?(entry.key) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return row
        }
        if let focusedIndex, focusedIndex >= rows.count {
            self.focusedIndex = rows.isEmpty ? nil : rows.count - 1
        }
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        emptyLabel.isHidden = !(rows.isEmpty && !allEntries.isEmpty)
        emptyLabel.stringValue = trimmed.isEmpty ? "" : "No open snippet matches \u{201C}\(trimmed)\u{201D}."
        restyleRows()
    }

    private func open(key: String) {
        if let index = visible.firstIndex(where: { $0.key == key }) { focusedIndex = index }
        onOpen?(key)
    }

    // MARK: Keyboard

    /// The filter field's Return, arrows and Escape.
    private func handleFilterCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            guard !rows.isEmpty else { return false }
            focusList(at: 0)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Return in the filter opens the best (first) match, so "type a
            // few letters, press Return" is the whole keyboard path to a file.
            guard let first = visible.first else { return true }
            open(key: first.key)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if filter.isEmpty {
                onDismissKeyboardFocus?()
            } else {
                filterField.stringValue = ""
                filterChanged("")
            }
            return true
        default:
            return false
        }
    }

    /// Puts the keyboard on the list, on `index` or on the active row.
    func focusList(at index: Int? = nil) {
        guard !rows.isEmpty else {
            filterField.focusEditor()
            return
        }
        let start = index ?? visible.firstIndex(where: { $0.key == activeKey }) ?? 0
        focusedIndex = min(max(start, 0), rows.count - 1)
        window?.makeFirstResponder(listView)
        restyleRows()
        if let focusedIndex { reveal(focusedIndex) }
    }

    /// The list's own key handling - see `CodePreviewFileListView`.
    fileprivate func listKeyDown(_ event: NSEvent) -> Bool {
        guard !rows.isEmpty else { return false }
        let current = focusedIndex ?? visible.firstIndex(where: { $0.key == activeKey }) ?? 0
        switch Int(event.keyCode) {
        case 125: // down arrow
            moveFocus(to: current + 1)
        case 126: // up arrow
            if current == 0 {
                filterField.focusEditor()
            } else {
                moveFocus(to: current - 1)
            }
        case 115: // home
            moveFocus(to: 0)
        case 119: // end
            moveFocus(to: rows.count - 1)
        case 36, 76, 49: // return, keypad enter, space
            guard current < visible.count else { return false }
            open(key: visible[current].key)
        case 53: // escape
            onDismissKeyboardFocus?()
        default:
            return false
        }
        return true
    }

    private func moveFocus(to index: Int) {
        focusedIndex = min(max(index, 0), rows.count - 1)
        restyleRows()
        if let focusedIndex { reveal(focusedIndex) }
    }

    fileprivate func listFocusChanged() { restyleRows() }

    private func reveal(_ index: Int) {
        guard index < rows.count else { return }
        layoutSubtreeIfNeeded()
        let row = rows[index]
        row.scrollToVisible(row.bounds)
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let palette = HelmPageSidebar.rowPalette(theme)
        if usesCardHeader {
            headerLabel.stringValue = headerLabel.placeholderString ?? ""
            headerLabel.font = HelmType.rowTitle()
            headerLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        } else {
            headerLabel.attributedStringValue = HelmPageSidebar.headerString(headerLabel.placeholderString ?? "",
                                                                             theme: theme)
        }
        countLabel.textColor = palette.muted
        emptyLabel.textColor = palette.muted
        filterField.applyTheme(theme)
        restyleRows()
    }

    private func restyleRows() {
        let palette = HelmPageSidebar.rowPalette(theme)
        let listHasFocus = window?.firstResponder === listView
        for (index, row) in rows.enumerated() {
            row.apply(palette: palette,
                      isActive: row.entry.key == activeKey,
                      showsKeyboardFocus: listHasFocus && index == focusedIndex)
            row.setUnsaved(dirtyKeys.contains(row.entry.key), accent: HelmTheme.nsColor(theme.accentHex))
        }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugRowNames: [String] { rows.map(\.entry.name) }
    var debugActiveRowName: String? { rows.first(where: \.debugIsActive)?.entry.name }
    var debugFocusedRowName: String? { focusedIndex.flatMap { $0 < rows.count ? rows[$0].entry.name : nil } }
    var debugCountText: String { countLabel.stringValue }
    var debugHeaderText: String { headerLabel.stringValue }
    var debugEmptyMessage: String? { emptyLabel.isHidden ? nil : emptyLabel.stringValue }
    var debugRows: [CodePreviewFileRow] { rows }
    var debugListView: NSView { listView }
    var debugScrollView: NSScrollView { scroll }
    func debugSetFilter(_ text: String) {
        filterField.stringValue = text
        filterChanged(text)
    }
    func debugFilterCommand(_ selector: Selector) -> Bool { handleFilterCommand(selector) }
    #endif
}

/// The list's document view, and the one key view the whole list is.
///
/// One responder for the list rather than one per row: with a hundred
/// snippets open, a row per key view would be a hundred Tab presses between
/// the filter field and the editor. Arrow keys move inside it instead, which
/// is how every file list on the Mac behaves.
final class CodePreviewFileListView: NSView {
    weak var owner: CodePreviewFileSidebar?

    /// Flipped for the reason `FlippedView` is (gotcha (9)): a short list
    /// rests against the top of the clip view rather than its bottom.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        defer { owner?.listFocusChanged() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.owner?.listFocusChanged() } }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if owner?.listKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Open snippets" }
}

// MARK: - One row

/// One snippet in the list: a type icon, the name (middle-truncated, so both
/// a long hash's start and its extension stay visible) and a close control
/// that appears on hover.
///
/// A `HoverHighlightView` for GL-16's role, press and hover treatment, with
/// the close control nested inside it - `HelmGestureArbitration` (gotcha
/// (20)) is what lets that button keep its own click, and `HoverHighlightView`
/// applies it to the row's recognizer for free.
final class CodePreviewFileRow: HoverHighlightView {
    let entry: CodePreviewFileEntry

    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onRename: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) lazy var closeButton = HelmButton(symbol: "xmark", variant: .quiet, size: .small,
                                                   target: self, action: #selector(closeClicked))
    /// What actually fades. Never the button itself: `HelmButton.restyle()`
    /// owns its `alphaValue` and resets it to 1 on every theme change, which
    /// would reveal every row's close control at once - measured that way in a
    /// real render after a Daylight-to-Dusk switch.
    private let closeHost = NSView()
    /// The unsaved dot, in the close control's place - shown while the
    /// snippet's text is ahead of the disk and the pointer is not over the
    /// row (hovering shows the close control instead, as in VS Code).
    private let unsavedDot = NSView()
    private var isActive = false
    private var hovering = false
    private var unsaved = false

    static let closeSide: CGFloat = 18

    init(entry: CodePreviewFileEntry) {
        self.entry = entry
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The list is the key view, not each row - see `CodePreviewFileListView`.
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        cornerRadius = HelmMetrics.rControl
        let inset = HelmPageSidebar.Metrics.rowInset

        let symbol = CodePreviewFileList.symbol(for: entry.language)
        icon.image = HelmSymbol.image(symbol, pointSize: 12, weight: .medium)
            ?? HelmSymbol.image(CodePreviewFileList.plainSymbol, pointSize: 12, weight: .medium)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.stringValue = entry.name
        label.font = HelmType.caption()
        // Middle, not tail: two snippets that differ only at the end of a long
        // name (`https-hooks-slack-com-services-a.txt` and `...-b.txt`) must
        // not truncate to the same string, and the extension is the type.
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.toolTip = entry.name
        toolTip = entry.name

        closeButton.toolTip = "Close \(entry.name)"
        closeButton.setAccessibilityLabel("Close \(entry.name)")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Faded rather than hidden, so VoiceOver can still find it: a hidden
        // control is out of the accessibility tree, and a pointer user only
        // reaches it by hovering, which is exactly when it shows.
        closeHost.translatesAutoresizingMaskIntoConstraints = false
        closeHost.alphaValue = 0
        closeHost.addSubview(closeButton)

        unsavedDot.wantsLayer = true
        unsavedDot.layer?.cornerRadius = 3
        unsavedDot.translatesAutoresizingMaskIntoConstraints = false
        unsavedDot.isHidden = true
        unsavedDot.setAccessibilityElement(false)
        for child in [icon, label, closeHost, unsavedDot] as [NSView] { addSubview(child) }
        let insets = closeButton.alignmentRectInsets
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: closeHost.leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: closeHost.trailingAnchor),
            closeButton.topAnchor.constraint(equalTo: closeHost.topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: closeHost.bottomAnchor),
            heightAnchor.constraint(equalToConstant: CodePreviewFileSidebar.rowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: HelmPageSidebar.Metrics.indicatorColumn),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: HelmMetrics.s2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeHost.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: HelmMetrics.s1),
            closeHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s1),
            closeHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Self.closeSide - insets.left - insets.right),
            unsavedDot.centerXAnchor.constraint(equalTo: closeHost.centerXAnchor),
            unsavedDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            unsavedDot.widthAnchor.constraint(equalToConstant: 6),
            unsavedDot.heightAnchor.constraint(equalToConstant: 6),
            closeButton.heightAnchor.constraint(equalToConstant: Self.closeSide - insets.top - insets.bottom),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked)))
        onHoverChange = { [weak self] hovering in
            self?.hovering = hovering
            self?.refreshCloseVisibility()
        }
        accessibilityLabelOverride = "\(entry.name), \(entry.language.displayName)"
    }

    @objc private func rowClicked() { onOpen?() }
    @objc private func closeClicked() { onClose?() }

    private func refreshCloseVisibility() {
        closeHost.alphaValue = hovering ? 1 : 0
        unsavedDot.isHidden = !unsaved || hovering
    }

    func setUnsaved(_ unsaved: Bool, accent: NSColor) {
        self.unsaved = unsaved
        unsavedDot.layer?.backgroundColor = accent.cgColor
        let value = [isActive ? "open in the editor" : nil, unsaved ? "unsaved" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        accessibilityValueOverride = value.isEmpty ? nil : value
        refreshCloseVisibility()
    }

    func apply(palette: HelmPageSidebar.RowPalette, isActive: Bool, showsKeyboardFocus: Bool) {
        self.isActive = isActive
        label.textColor = isActive ? palette.selectedInk : palette.ink
        label.font = isActive
            ? .systemFont(ofSize: HelmType.caption().pointSize, weight: .semibold)
            : HelmType.caption()
        icon.contentTintColor = isActive ? palette.selectedInk : palette.muted
        // Both colours, never `layer.backgroundColor` directly - the same
        // `HoverHighlightView` rule `HelmPageSidebar.applyTheme` follows.
        normalColor = isActive ? palette.selectedFill : .clear
        hoverColor = isActive ? palette.selectedFill : palette.hoverFill
        accessibilityValueOverride = isActive ? "open in the editor" : nil
        // The list is one key view, so the row the arrows are on draws the
        // ring itself, in the system's own focus colour.
        layer?.borderWidth = showsKeyboardFocus ? 2 : 0
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let items: [(String, String, Selector)] = [
            ("Rename", "pencil", #selector(renameFromMenu)),
            ("Duplicate", "plus.square.on.square", #selector(duplicateFromMenu)),
            ("Close", "xmark", #selector(closeClicked)),
        ]
        for (title, symbol, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "").withSymbol(symbol)
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func renameFromMenu() { onRename?() }
    @objc private func duplicateFromMenu() { onDuplicate?() }

    #if FM_SELFTESTS
    var debugIsActive: Bool { isActive }
    var debugLabel: NSTextField { label }
    var debugIconImage: NSImage? { icon.image }
    /// What the close control actually composites at: the host's fade times
    /// the button's own alpha, so a check cannot pass by reading the wrong one.
    var debugCloseAlpha: CGFloat { closeHost.alphaValue * closeButton.alphaValue }
    var debugShowsKeyboardFocus: Bool { (layer?.borderWidth ?? 0) > 0 }
    var debugUnsavedDotVisible: Bool { !unsavedDot.isHidden }
    func debugSetHovering(_ hovering: Bool) {
        // Through the real tracking-area handlers, never `refreshCloseVisibility`
        // directly (AGENTS.md: a hook enters where the real event enters).
        let event = NSEvent.enterExitEvent(with: hovering ? .mouseEntered : .mouseExited,
                                           location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil,
                                           eventNumber: 0, trackingNumber: 0, userData: nil)
        if let event {
            if hovering { mouseEntered(with: event) } else { mouseExited(with: event) }
        }
    }
    #endif
}

// MARK: - The resize handle

/// The gap between the column and the editor, made draggable.
///
/// A plain mouse-tracking view rather than an `NSSplitView`: the page's other
/// geometry (the output pane's two status-bar constraints, the card insets) is
/// hand-built Auto Layout, and a split view would own the editor's frame. The
/// handle reports a width; the controller decides what to do with it.
final class CodePreviewSidebarResizeHandle: NSView {
    /// Live, during a drag.
    var onResize: ((CGFloat) -> Void)?
    /// Once, when the drag ends - the point at which the width is remembered.
    var onResizeEnded: ((CGFloat) -> Void)?
    /// Double-click puts the column back to its default width.
    var onReset: (() -> Void)?
    /// The column's width when a drag starts.
    var currentWidth: (() -> CGFloat)?

    private var dragStartX: CGFloat?
    private var dragStartWidth: CGFloat = 0
    private var lastWidth: CGFloat = 0
    private var hovering = false
    private var tracking: NSTrackingArea?
    private let line = NSView()
    var lineColor: NSColor = .clear {
        didSet { refreshLine() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: centerXAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize the snippet list")
        toolTip = "Drag to resize the snippet list - double-click to reset"
        refreshLine()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshLine()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshLine()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStartX = nil
            onReset?()
            return
        }
        dragStartX = event.locationInWindow.x
        dragStartWidth = currentWidth?() ?? 0
        lastWidth = dragStartWidth
        refreshLine()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        lastWidth = CodePreviewSidebarPreferences.clamp(dragStartWidth + event.locationInWindow.x - dragStartX)
        onResize?(lastWidth)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartX != nil else { return }
        dragStartX = nil
        onResizeEnded?(lastWidth)
        refreshLine()
    }

    private func refreshLine() {
        let active = hovering || dragStartX != nil
        line.layer?.backgroundColor = (active ? lineColor : .clear).cgColor
    }

    #if FM_SELFTESTS
    /// A whole drag through the real mouse handlers, from the handle's centre
    /// by `dx` points - so a suite exercises the same arithmetic a pointer does.
    func debugDrag(by dx: CGFloat) {
        let start = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                               timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                               eventNumber: 0, clickCount: clicks, pressure: 1)
        }
        if let down = event(.leftMouseDown, x: start.x) { mouseDown(with: down) }
        if let drag = event(.leftMouseDragged, x: start.x + dx) { mouseDragged(with: drag) }
        if let up = event(.leftMouseUp, x: start.x + dx) { mouseUp(with: up) }
    }

    func debugDoubleClick() {
        let start = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [],
                                         timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                         context: nil, eventNumber: 0, clickCount: 2, pressure: 1) {
            mouseDown(with: down)
        }
    }
    #endif
}

// MARK: - The tab strip's scroll view

/// The tab strip, scrolling sideways once the tabs outgrow the toolbar.
///
/// A plain mouse wheel only ever reports vertical deltas, and a sideways-only
/// scroll view ignores those - so without this, a captain without a trackpad
/// could not scroll the strip at all. A vertical delta is turned into a
/// horizontal one, which is what VS Code's own tab strip does.
final class CodePreviewTabStripScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard abs(dy) > abs(dx) else {
            super.scrollWheel(with: event)
            return
        }
        // A notched wheel reports whole lines; a trackpad reports points.
        let step = event.hasPreciseScrollingDeltas ? dy : dy * 10
        scrollHorizontally(by: -step)
    }

    /// Moves the strip sideways by `delta` points, clamped to its content.
    func scrollHorizontally(by delta: CGFloat) {
        guard let document = documentView else { return }
        let maxX = max(0, document.frame.width - contentView.bounds.width)
        let x = min(max(contentView.bounds.origin.x + delta, 0), maxX)
        contentView.scroll(to: NSPoint(x: x, y: contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}
