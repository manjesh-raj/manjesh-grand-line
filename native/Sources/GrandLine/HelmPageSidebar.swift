// Grand Line - native macOS app.
//
// The app's one **page-scoped** left navigation column: section headers over
// rows, each row optionally carrying its own count, one row selected.
//
// **Page-scoped, and that distinction is the whole reason this is safe to
// have.** Daylight Phase 2 deliberately deleted this app's app-wide
// `IconRailController` left rail and made `AppShellController.bodyContainer`
// span the window's full width; nothing here revives that. This is a column
// *inside* one destination's own body, the way Poneglyph has had one since
// `fm/grand-line-roomier-poneglyph-vault-ui-li-0f` - a page deciding how to
// lay out its own content, which is a different question from what the window
// chrome carries.
//
// **Extracted from `CredentialVaultSidebar`** when Schedules needed the same
// column (`fm/grand-line-schedules-sidebar-fullwidth-fix`). Every visual
// decision below is that file's, verbatim and deliberately unchanged - the
// `HoverHighlightView` row, the accent-wash selected fill, the corrected
// selected ink, the kicker headers, the right-aligned plain-text count. What
// changed is only that the rows are keyed by a caller-supplied `String` id
// instead of `CredentialCategory`, so a second page can have one without a
// near-copy drifting from the first (this codebase's own repeated lesson -
// see `HelmRefreshPill`'s header for the same extraction, same reasoning).
//
// **Three callers now**, Hosts having asked for one in
// `fm/grand-line-hosts-sidebar-restore` - which is what `Surface`,
// `CountStyle` and `setFooter(_:)` below are for. All three are opt-in and
// default to what Poneglyph and Schedules already had, so a page taking its
// own reference's treatment cannot restyle theirs.
//
// **Four callers now**, Tasks having asked for a row per project in
// `fm/grand-line-tasks-sidebar-project-list`. Three more additions, every one
// of them opt-in for the same reason:
//
//   - `RowIndicator.dot` - a row led by a filled colour dot rather than an SF
//     Symbol, which is what a *project* row is: an identity marker, not an
//     icon for an action.
//   - **Row groups.** A row's selection is scoped to its group, because a
//     page can carry two genuinely orthogonal one-of-many filters at once
//     (Tasks filters by *slice* and by *project*, and picking a project must
//     not un-pick "All tasks"). Every existing caller stays in the one default
//     group and cannot tell the difference.
//   - `setSections(_:)`. The append API builds a column once; a project list
//     changes while the page is open, so this one is declarative and rebuilds
//     - preserving each group's selection across the rebuild, which is what
//     stops a re-render dropping the captain's filter.
//
// The rows live in a scroll view, so a captain with twenty projects gets a
// scrolling nav rather than rows drawn over the footer. The column is still
// content-sized for a caller that pins only `bottom <=` (Poneglyph,
// Schedules): the equality that does that sits at priority 499, below
// `NSLayoutPriorityWindowSizeStayPut`, so a caller that *does* give the column
// a definite height (Hosts and Tasks, both of which pin their bottom so a
// footer lands on the page's own bottom edge) simply wins and the content
// scrolls.

import AppKit

final class HelmPageSidebar: NSView {

    /// A row is either a **filter** (one-of-many: it stays selected, and
    /// announces as a radio button) or an **action** (it fires and leaves the
    /// selection where it was, and announces as a button).
    ///
    /// The split matters for more than accessibility: a "Run History" row that
    /// latched selected would claim the list below it had been filtered to
    /// something, which is exactly the kind of false claim this app's own
    /// conventions keep out of a nav control.
    enum RowKind {
        case filter
        case action
    }

    /// Does the column paint a surface of its own, or sit straight on the
    /// page?
    ///
    /// **Opt-in, and `.plain` is the default on purpose.** Poneglyph and
    /// Schedules both shipped this column flush on the page background, and
    /// this enum exists so a third page can take the reference mockup's
    /// panelled treatment without restyling the two that did not ask for it -
    /// the same "widen the shared component, leave every existing caller
    /// byte-identical" shape `HelmButton.gradientFill` and
    /// `HelmAccentRow.gradientBadge` already use here.
    enum Surface {
        /// No fill, no border - the column is just its rows. Poneglyph and
        /// Schedules.
        case plain
        /// `HelmCard`'s own fill/border/radius, so the column reads as a panel
        /// beside the page's cards rather than as loose rows. Hosts.
        case panel
    }

    /// How a row's count is drawn.
    ///
    /// **Opt-in, `.plain` by default**, same reasoning as `Surface` above:
    /// Poneglyph and Schedules shipped the plain right-aligned number this
    /// component was extracted with, and a third page taking its reference's
    /// badge must not restyle theirs.
    enum CountStyle {
        /// Right-aligned plain text - a column of six rows carries six numbers
        /// and no extra chrome.
        case plain
        /// A small filled pill, which is what the Hosts reference draws: a
        /// muted chip on a resting row, an accent-tinted one on the selected
        /// row.
        case badge
    }

    /// What leads a row: an SF Symbol (an action or a slice), a filled colour
    /// dot (an identity - a project), or a colour **tile** (a destination).
    ///
    /// **`.tile` is the same opt-in widening `Surface`, `CountStyle` and
    /// `.dot` already are**, and every caller that does not construct one
    /// renders byte-identically. It exists because Settings' reference gives
    /// each of its eight pages a rounded colour square rather than a bare
    /// monochrome glyph - which is what makes a column of eight rows
    /// *scannable*, where eight glyphs in one muted ink are a list you have to
    /// read. That is a real distinction from `.dot`: a dot is an identity
    /// marker for a record the captain named (a project), a tile is a
    /// destination's own standing colour.
    ///
    /// It renders through `IconTileView` - this app's one colour-tile
    /// component, already drawing exactly this on the Updates page's tool rows
    /// - so the tile's wash, its contrast-corrected glyph and its theme
    /// response are the shared ones rather than a second copy.
    ///
    /// **A tile is wider than the 16pt `indicatorColumn`**, so a tile row's
    /// label starts further in than a symbol or dot row's. That is deliberate
    /// and costs nothing today (no caller mixes `.tile` with the other two in
    /// one column); a column that did would want the wider lead applied to all
    /// of its rows, not this case changed.
    enum RowIndicator {
        case symbol(String)
        case dot(HelmTint)
        case tile(symbol: String, tint: HelmTint)
    }

    /// The group every row built through the append API belongs to, and the
    /// one `select(_:)`/`selection` talk about.
    static let defaultGroup = "default"

    /// One row, for the declarative `setSections(_:)` path.
    struct Row {
        var id: String
        var indicator: RowIndicator
        var title: String
        var kind: RowKind = .filter
        var group: String = HelmPageSidebar.defaultGroup
        var showsCount: Bool = true

        init(id: String, indicator: RowIndicator, title: String,
             kind: RowKind = .filter, group: String = HelmPageSidebar.defaultGroup,
             showsCount: Bool = true) {
            self.id = id
            self.indicator = indicator
            self.title = title
            self.kind = kind
            self.group = group
            self.showsCount = showsCount
        }
    }

    /// A titled run of rows. `header` is `nil` for an untitled run.
    struct Section {
        var header: String?
        var rows: [Row]

        init(header: String?, rows: [Row]) {
            self.header = header
            self.rows = rows
        }
    }

    /// One muted text link in a `setFooter(links:)` footer.
    struct FooterLink {
        var id: String
        var title: String

        init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    static let width: CGFloat = 208

    private let surface: Surface
    private let countStyle: CountStyle

    /// Bottom-anchored content, below the rows: `setFooter(_:)`'s view.
    ///
    /// Absent unless a caller sets one, which is what keeps the two pages that
    /// predate it unchanged - with no footer the stack is pinned exactly as it
    /// always was (`bottom <=` this view's own bottom, so the column hugs its
    /// rows and a page may pin it with an inequality).
    private var footer: NSView?
    private var scrollBottom: NSLayoutConstraint!

    /// Fired with the row's id. A `.filter` row has already moved its **own
    /// group's** selection by the time this runs; an `.action` row has not. A
    /// `setFooter(links:)` link fires this too, with its own id.
    var onSelect: ((String) -> Void)?

    /// The selected `.filter` row's id in the default group. Only ever a
    /// filter row - an action never becomes a selection.
    var selection: String? { selections[Self.defaultGroup] }

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private var rows: [(button: HoverHighlightView, id: String, kind: RowKind, group: String,
                        icon: NSImageView, dot: NSView, tile: IconTileView?,
                        label: NSTextField, count: NSTextField,
                        chip: NSView?, indicator: RowIndicator)] = []
    private var headers: [NSTextField] = []
    private var selections: [String: String] = [:]
    private var linkItems: [(button: HoverHighlightView, id: String, label: NSTextField)] = []
    private var linkSeparators: [NSTextField] = []
    private var linkDivider: NSView?
    private var theme: HelmTheme = ThemeManager.shared.theme

    // MARK: Build

    init(surface: Surface = .plain, countStyle: CountStyle = .plain) {
        self.surface = surface
        self.countStyle = countStyle
        super.init(frame: .zero)
        build()
    }

    override init(frame frameRect: NSRect) {
        self.surface = .plain
        self.countStyle = .plain
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // `.plain` keeps a zero inset, so the two pages that predate `Surface`
        // lay their rows out exactly where they always did. A `.panel` column
        // has a border to keep clear of.
        let inset = surface == .panel ? Metrics.panelInset : 0

        // The rows scroll, so a column with more rows than the page is tall
        // gets a scrolling nav rather than rows drawn over a footer. No
        // scroller: a non-overlay vertical scroller reserves a real ~15pt
        // track that would narrow this 208pt column (gotcha (4)), and the
        // wheel/trackpad still scrolls without one.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        // A plain `NSView()` document is **not** flipped, so a document
        // shorter than its clip view rests against the *bottom* of it and
        // leaves a gap above the first row (gotcha (9)). `FlippedView` is this
        // app's fix for that, and every scroll-backed surface here uses it.
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        addSubview(scroll)

        scrollBottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            scrollBottom,

            // Gotcha (4): the document is pinned to the **clip** view, never
            // the scroll view itself - and only on the axis that does not
            // scroll. A vertical pin would fight the clip view's own bounds
            // origin, which is what scrolling moves.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        // A scroll view has no intrinsic height, so without this the column
        // would be ambiguous: it is the only thing driving the height when
        // nothing else does (content-sized, exactly as before this component
        // grew a scroll view - which is what Poneglyph and Schedules, pinning
        // only `bottom <=`, rely on), and it breaks cleanly for a caller that
        // genuinely pins the column's bottom (Hosts, Tasks), leaving the
        // content to scroll. At `contentTie` (499) it sits below
        // `NSLayoutPriorityWindowSizeStayPut`, so it can never be a floor on
        // how short the window may get (gotcha (13)).
        let contentHeight = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        contentHeight.priority = HelmDaylightPriority.contentTie
        contentHeight.isActive = true

        // A fixed column, so the content beside it takes every point the window
        // gains - but **below `NSLayoutPriorityWindowSizeStayPut`** (gotcha
        // (13)), because this column's width reaches `bodyContainer` through
        // its page, and a required one is therefore a floor on how narrow the
        // whole window may get.
        //
        // Measured rather than assumed: as a required constraint it stuck
        // `bodyContainer` at 1220pt against a 1100pt window and - because every
        // destination shares that container - took the other twenty-six down
        // with it (`AppShellBodyWidthSelfTest`'s
        // `bodyContainerTracksWindowAcrossAllDestinations`). At any width these
        // pages are really used at, 499 still beats every label beside it, so
        // the column is exactly `width`; it simply yields before the window has
        // to.
        let columnWidth = widthAnchor.constraint(equalToConstant: Self.width)
        columnWidth.priority = HelmDaylightPriority.contentTie
        columnWidth.isActive = true
    }

    // MARK: Composition

    func appendHeader(_ title: String) {
        let label = NSTextField(labelWithString: "")
        label.placeholderString = title
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        headers.append(label)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Metrics.rowInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -Metrics.rowInset),
            label.topAnchor.constraint(equalTo: holder.topAnchor),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -HelmMetrics.s2),
        ])
        appendFullWidth(holder)
    }

    func appendSpacer() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: Metrics.sectionGap).isActive = true
        appendFullWidth(spacer)
    }

    /// One nav row. A `HoverHighlightView` rather than a hand-rolled clickable
    /// view: it is this app's one hover/press/focus-ring/accessibility
    /// treatment, and GL-16's role and keyboard activation come with it (see
    /// `HelmUIComponents.swift`). A nested real control would be the
    /// hit-testing hazard that class's header warns about, so the row carries
    /// only labels.
    func appendRow(id: String, symbol: String, title: String,
                   kind: RowKind = .filter, showsCount: Bool = true) {
        appendRow(Row(id: id, indicator: .symbol(symbol), title: title,
                      kind: kind, showsCount: showsCount))
    }

    func appendRow(_ spec: Row) {
        let button = HoverHighlightView()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.cornerRadius = HelmMetrics.rControl

        // Both leads are built and exactly one is shown - the arrangement
        // `HelmAccentRow` already uses for its gradient-vs-symbol badge, so a
        // theme change never has to rebuild a row. They share one 16pt column
        // so a dot row's label lines up with a symbol row's.
        let icon = NSImageView()
        if case let .symbol(name) = spec.indicator {
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Metrics.dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The tile is the third lead, and like the other two it is built only
        // when it is the one asked for - `nil` keeps every pre-existing caller
        // on exactly the views it had.
        var tile: IconTileView?
        switch spec.indicator {
        case .symbol: dot.isHidden = true
        case .dot: icon.isHidden = true
        case let .tile(symbolName, tint):
            dot.isHidden = true
            icon.isHidden = true
            let built = IconTileView(size: Metrics.tileSize, cornerRadius: Metrics.tileRadius)
            built.configure(symbol: symbolName, tint: tint, pointSize: Metrics.tileGlyphPointSize)
            tile = built
        }

        // The lead column is as wide as whichever lead this row carries, and
        // the label is measured from `icon`'s trailing edge either way - so a
        // tile row's label clears its tile without a second layout branch.
        let leadWidth: CGFloat
        if case .tile = spec.indicator { leadWidth = Metrics.tileSize } else { leadWidth = Metrics.indicatorColumn }

        let title = spec.title
        let id = spec.id
        let kind = spec.kind
        let showsCount = spec.showsCount

        let label = NSTextField(labelWithString: title)
        label.font = HelmType.caption()
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The reference's count is plain right-aligned text, not a chip - so a
        // sidebar of six rows carries six numbers and no extra chrome.
        let count = NSTextField(labelWithString: "")
        count.font = HelmType.captionSmall()
        count.alignment = .right
        count.translatesAutoresizingMaskIntoConstraints = false
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.isHidden = !showsCount

        // A `.badge` count is drawn by a container's layer, never by the
        // label's own `backgroundColor`: with `drawsBackground` the *cell*
        // paints a square fill over whatever the layer holds, so the corners
        // would never round (the `NSTextField` overpaint trap `HelmField`'s
        // header records).
        var chip: NSView?
        let countHost: NSView
        if countStyle == .badge {
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.wantsLayer = true
            holder.addSubview(count)
            NSLayoutConstraint.activate([
                count.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Metrics.badgeInset),
                count.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Metrics.badgeInset),
                count.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                holder.heightAnchor.constraint(equalToConstant: Metrics.badgeHeight),
                holder.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.badgeHeight + 2),
            ])
            holder.setContentHuggingPriority(.required, for: .horizontal)
            holder.setContentCompressionResistancePriority(.required, for: .horizontal)
            holder.isHidden = !showsCount
            chip = holder
            countHost = holder
        } else {
            countHost = count
        }

        for child in [icon, dot, label, countHost] as [NSView] { button.addSubview(child) }
        if let tile {
            button.addSubview(tile)
            NSLayoutConstraint.activate([
                tile.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
                tile.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Metrics.rowInset),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: leadWidth),
            dot.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Metrics.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Metrics.dotSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: HelmMetrics.s2),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            countHost.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: HelmMetrics.s1),
            countHost.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Metrics.rowInset),
            countHost.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),
        ])

        // GL-16: a filter is one-of-many, so it announces as a radio button
        // carrying its own selected state, exactly as `HelmSegmentedTabs` does
        // for a pill row. An action is a plain button.
        button.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:))))
        button.accessibilityRoleOverride = kind == .filter ? .radioButton : .button
        button.accessibilityLabelOverride = title
        button.identifier = NSUserInterfaceItemIdentifier(id)
        rows.append((button, id, kind, spec.group, icon, dot, tile, label, count, chip, spec.indicator))
        appendFullWidth(button)
    }

    // MARK: Declarative composition

    /// Rebuild the whole column from a description of it.
    ///
    /// Declarative rather than append-only because a project list changes
    /// while the page is open, and each group's selection is carried across
    /// the rebuild - a re-render that silently dropped the captain's project
    /// filter would be a worse bug than the missing rows this exists for.
    func setSections(_ sections: [Section]) {
        let carried = selections
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows.removeAll()
        headers.removeAll()

        for (index, section) in sections.enumerated() {
            if index > 0 { appendSpacer() }
            if let header = section.header { appendHeader(header) }
            for row in section.rows { appendRow(row) }
        }

        // A selection pointing at a row that has since gone away would leave
        // the column showing nothing selected while the page is still filtered
        // by it, so it is dropped rather than kept.
        selections = carried.filter { group, id in
            rows.contains { $0.group == group && $0.id == id && $0.kind == .filter }
        }
        applyTheme(theme)
    }

    private func appendFullWidth(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    enum Metrics {
        static let rowHeight: CGFloat = 34
        static let rowInset: CGFloat = HelmMetrics.s3 - 2
        static let sectionGap: CGFloat = HelmMetrics.s3
        /// The padding a `.panel` column keeps between its border and its
        /// rows. The reference mockup's own sidebar padding (12) over its row
        /// padding (10), which is `rowInset` above.
        static let panelInset: CGFloat = HelmMetrics.s3
        /// The gap between the last row and a footer.
        static let footerGap: CGFloat = HelmMetrics.s4
        /// A `.badge` count's pill.
        static let badgeHeight: CGFloat = 18
        static let badgeInset: CGFloat = HelmMetrics.s2 - 2
        /// One column for both leads, so a dot row's label starts where a
        /// symbol row's does.
        static let indicatorColumn: CGFloat = 16
        static let dotSize: CGFloat = 8
        /// A `.tile` lead. 22pt in a 34pt row leaves 6pt of breathing room
        /// above and below, which is the proportion the reference draws; the
        /// radius is `HelmMetrics.rChip` itself rather than a new number, so
        /// a tile and a chip round alike and cannot drift apart.
        static let tileSize: CGFloat = 22
        static let tileRadius: CGFloat = HelmMetrics.rChip
        /// Smaller than `IconTileView`'s 15pt default, because that default is
        /// sized for the 34pt tile the Updates page draws and a 15pt glyph in
        /// a 22pt tile leaves no margin at all.
        static let tileGlyphPointSize: CGFloat = 11
    }

    // MARK: Footer

    /// Bottom-anchored content under the rows - the reference's keychain card
    /// and user row.
    ///
    /// **A page that sets one has to pin this column's bottom with a required
    /// `==`, not the `<=` Poneglyph and Schedules use.** Without a footer this
    /// view hugs its rows, so an inequality is right; with one, the footer is
    /// pinned to this view's own bottom edge, and that edge only reaches the
    /// page's bottom if the page says so.
    func setFooter(_ view: NSView) {
        footer?.removeFromSuperview()
        footer = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let inset = surface == .panel ? Metrics.panelInset : 0
        scrollBottom.isActive = false
        scrollBottom = scroll.bottomAnchor.constraint(equalTo: view.topAnchor,
                                                      constant: -Metrics.footerGap)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            scrollBottom,
        ])
    }

    /// A footer of muted text links, the shape the Tasks reference draws -
    /// built on top of `setFooter(_:)` rather than beside it, so this column
    /// has exactly one footer mechanism and a page can have only one footer.
    ///
    /// Each link fires `onSelect` with its own id. An empty array removes the
    /// footer, restoring the column to hugging its rows.
    func setFooter(links: [FooterLink]) {
        linkItems.removeAll()
        linkSeparators.removeAll()
        linkDivider = nil
        guard !links.isEmpty else {
            clearFooter()
            return
        }

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        linkDivider = divider

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.translatesAutoresizingMaskIntoConstraints = false

        for (index, link) in links.enumerated() {
            if index > 0 {
                let separator = NSTextField(labelWithString: "\u{00B7}")
                separator.font = HelmType.captionSmall()
                linkSeparators.append(separator)
                row.addArrangedSubview(separator)
            }
            let button = HoverHighlightView()
            button.wantsLayer = true
            button.cornerRadius = HelmMetrics.rChip
            button.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: link.title)
            label.font = HelmType.captionSmall()
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: HelmMetrics.s1),
                label.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -HelmMetrics.s1),
                label.topAnchor.constraint(equalTo: button.topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4),
            ])
            button.addGestureRecognizer(
                NSClickGestureRecognizer(target: self, action: #selector(footerLinkClicked(_:))))
            button.accessibilityRoleOverride = .button
            button.accessibilityLabelOverride = link.title
            button.identifier = NSUserInterfaceItemIdentifier(link.id)
            linkItems.append((button, link.id, label))
            row.addArrangedSubview(button)
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)
        container.addSubview(row)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.rowInset),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.rowInset),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.rowInset),
            row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                          constant: -Metrics.rowInset),
            row.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: HelmMetrics.s2),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        setFooter(container)
        applyTheme(theme)
    }

    private func clearFooter() {
        guard let existing = footer else { return }
        existing.removeFromSuperview()
        footer = nil
        let inset = surface == .panel ? Metrics.panelInset : 0
        scrollBottom.isActive = false
        scrollBottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        scrollBottom.isActive = true
    }

    @objc private func footerLinkClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view,
              let item = linkItems.first(where: { $0.button === view }) else { return }
        onSelect?(item.id)
    }

    // MARK: Selection and counts

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view,
              let index = rows.firstIndex(where: { $0.button === view }) else { return }
        pick(index)
    }

    private func pick(_ index: Int) {
        guard index < rows.count else { return }
        let row = rows[index]
        if row.kind == .filter { select(row.id, inGroup: row.group) }
        onSelect?(row.id)
    }

    /// Move the default group's selection without firing `onSelect` - what a
    /// caller restoring state wants, and the same split
    /// `HelmSegmentedTabs.select(_:)` draws.
    func select(_ id: String?) { select(id, inGroup: Self.defaultGroup) }

    /// Move one group's selection. A group is an independent one-of-many set,
    /// so this never touches any other group's.
    func select(_ id: String?, inGroup group: String) {
        selections[group] = id
        applyTheme(theme)
    }

    /// The selected `.filter` row's id in `group`, if any.
    func selection(inGroup group: String) -> String? { selections[group] }

    /// Keyed by row id. A row built with `showsCount: false` ignores whatever
    /// it is handed here, so a caller need not special-case its action rows.
    func setCounts(_ counts: [String: Int]) {
        for row in rows {
            guard let value = counts[row.id] else { continue }
            row.count.stringValue = "\(value)"
            // A filter with nothing under it is still reachable - it just says
            // 0. Hiding it would make the sidebar's shape change as the captain
            // types, which is worse than a zero.
            row.count.alphaValue = value == 0 ? 0.55 : 1
            row.chip?.alphaValue = value == 0 ? 0.55 : 1
        }
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // A `.plain` column never touches its own layer, so the two pages that
        // predate `Surface` render exactly as before.
        if surface == .panel {
            HelmCard.applyCardSurface(to: self, theme: theme)
        }
        let muted = HelmTheme.mutedInk(theme)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let accent = HelmTheme.nsColor(theme.accentHex)
        // The same accent wash `HelmAccentRow` paints for its own selected
        // card, so a selected nav row and a selected list row are one idiom.
        let surfaceColor = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let selectedFill = surfaceColor.blended(withFraction: HelmAccentRow.selectionWash, of: accent) ?? surfaceColor
        let hoverFill = surfaceColor.blended(withFraction: HelmAccentRow.selectionWash / 2.5, of: accent) ?? surfaceColor

        for header in headers {
            header.attributedStringValue = NSAttributedString(
                string: (header.placeholderString ?? "").uppercased(),
                attributes: HelmType.kickerAttributes(color: muted))
        }

        for row in rows {
            let isSelected = row.kind == .filter && row.id == selections[row.group]
            // A selected row's label takes the corrected accent - never the raw
            // hue, which is audit §5.7's defect (`HelmContrast`'s own rule: a
            // tint is safe as a fill and is not automatically safe as text).
            let selectedInk = HelmContrast.legibleTintedText(
                tintHex: theme.accentHex,
                overAnyOf: [selectedFill, HelmTheme.nsColor(theme.chromeBackgroundHex)],
                theme: theme)
            row.label.textColor = isSelected ? selectedInk : ink
            row.icon.contentTintColor = isSelected ? selectedInk : muted
            // The dot carries the **raw** tint, deliberately: it is the same
            // hue this project's board cards and filter chip already paint
            // (`ShiftProjectPalette`), and a sidebar dot that corrected itself
            // would be a different colour from the board for the same project -
            // which is the one thing an identity marker must not be. §2.4's own
            // caveat covers it: the dot sits beside a label naming the project,
            // so it is redundant decoration rather than the sole carrier of
            // meaning.
            if case let .dot(tint) = row.indicator {
                row.dot.layer?.backgroundColor = HelmTheme.nsColor(tint.hex(in: theme)).cgColor
            }
            // A tile owns its own wash and its own contrast-corrected glyph,
            // so it is handed the theme and re-derives both - the same as any
            // other `IconTileView` on a themed page. It is deliberately NOT
            // re-tinted for selection: the tile is the destination's standing
            // colour, and a tile that changed hue when its row was picked
            // would be a different section's colour for as long as it was
            // selected.
            row.tile?.applyTheme(theme)
            row.count.textColor = isSelected && countStyle == .badge ? selectedInk : muted
            if let chip = row.chip {
                chip.layer?.cornerRadius = Metrics.badgeHeight / 2
                // The selected badge takes a stronger wash of the same accent
                // the row already carries, so the two read as one object; a
                // resting one takes the theme's own line tone rather than a
                // hue, because it is carrying a number, not a state.
                chip.layer?.backgroundColor = isSelected
                    ? (surfaceColor.blended(withFraction: HelmAccentRow.selectionWash * 2.2, of: accent) ?? surfaceColor).cgColor
                    : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.55).cgColor
            }
            // Both colours, never `layer.backgroundColor` directly: a
            // `HoverHighlightView` owns persistent hover state, and a direct
            // layer write is stranded by the next `mouseExited`
            // (`fm/grandline-updates-refresh-button-light-mode-fix`).
            row.button.normalColor = isSelected ? selectedFill : .clear
            row.button.hoverColor = isSelected ? selectedFill : hoverFill
            row.button.layer?.cornerRadius = HelmMetrics.rControl
        }

        linkDivider?.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(0.6).cgColor
        for separator in linkSeparators { separator.textColor = muted }
        for item in linkItems {
            item.label.textColor = muted
            item.button.normalColor = .clear
            item.button.hoverColor = hoverFill
            item.button.layer?.cornerRadius = HelmMetrics.rChip
        }
    }

    #if FM_SELFTESTS
    var debugRowCount: Int { rows.count }
    var debugRowTitles: [String] { rows.map { $0.label.stringValue } }
    var debugRowIDs: [String] { rows.map { $0.id } }
    var debugRowCounts: [String] { rows.map { $0.count.stringValue } }
    var debugSelectedIndex: Int? {
        rows.firstIndex { $0.kind == .filter && $0.id == selections[$0.group] }
    }
    var debugRowGroups: [String] { rows.map { $0.group } }

    /// The ids of the rows that are **actually rendering selected**, not the
    /// ids `select(_:inGroup:)` was handed - a check that reads the stored
    /// value passes for a selection pointing at a row that is not in that
    /// group at all.
    var debugSelectedRowIDs: [String] {
        rows.filter { $0.kind == .filter && $0.id == selections[$0.group] }.map { $0.id }
    }

    /// Whether each row shows a dot (`true`) or a symbol (`false`), read off
    /// the views rather than the spec - a check that re-derives what it asked
    /// for agrees with itself forever.
    var debugRowUsesDot: [Bool] { rows.map { !$0.dot.isHidden && $0.icon.isHidden } }

    /// A dot row's painted fill.
    func debugDotColor(id: String) -> NSColor? {
        guard let row = rows.first(where: { $0.id == id }),
              !row.dot.isHidden, let cg = row.dot.layer?.backgroundColor else { return nil }
        return NSColor(cgColor: cg)
    }

    var debugFooterLinkTitles: [String] { linkItems.map { $0.label.stringValue } }
    func debugClickFooterLink(_ id: String) {
        guard let item = linkItems.first(where: { $0.id == id }) else { return }
        onSelect?(item.id)
    }

    /// How far the footer's own bottom edge sits above the column's. A footer
    /// floating halfway up an otherwise empty column is not a footer, and that
    /// is what a column pinned only `bottom <=` would give.
    ///
    /// This view is not flipped, so the bottom edge is `minY` - reading
    /// `maxY` here measures the distance to the *top* and reports a correct
    /// footer as its whole height out of place.
    var debugFooterBottomGap: CGFloat {
        guard let footer else { return .nan }
        return footer.frame.minY - bounds.minY
    }
    var debugHeaders: [String] { headers.compactMap { $0.placeholderString } }
    var debugRowKinds: [String] { rows.map { $0.kind == .filter ? "filter" : "action" } }
    var debugHasFooter: Bool { footer != nil }
    var debugSurfaceIsPanel: Bool { surface == .panel }
    var debugHasCountBadges: Bool { rows.contains { $0.chip != nil } }
    func debugClickRow(_ index: Int) { pick(index) }
    func debugRowIndex(id: String) -> Int? { rows.firstIndex { $0.id == id } }
    /// Drives the real row's own handler by id, so a caller cannot pass by
    /// re-deriving a position the column does not actually use.
    func debugClickRow(id: String) { if let index = debugRowIndex(id: id) { pick(index) } }

    /// What each row is actually showing, read off the labels rather than
    /// recomputed - a check that re-derives a count agrees with itself forever.
    var debugCounts: [String: String] {
        Dictionary(rows.map { ($0.id, $0.count.stringValue) }, uniquingKeysWith: { a, _ in a })
    }
    #endif
}
