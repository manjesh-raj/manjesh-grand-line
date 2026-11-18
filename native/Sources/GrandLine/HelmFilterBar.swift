// Grand Line - native macOS app.
//
// S16 of the 2026-11-17 UI/UX proposals: one filter row, one collapse rule.
//
// Six pages composed a filter row by hand from the same parts - scope chips
// (`HelmSegmentedTabs`), a `HelmPopUpButton`, tag chips, a search field and a
// trailing sort - and each decided its own order, spacing and what happened
// at a narrow window. Tasks folded into a "Filter" button, Connections folded
// its tags into a "+5" chip, and Updates and Logs did not fold at all. The
// parts were shared; the row was not, so every new list page wrote another.
//
// `HelmFilterBar` is the row. A page declares which slots it fills; it never
// lays them out:
//
//   scope · popups · chips · search · (space) · trailing
//
// **The one collapse rule.** When the slots at their own widths do not fit -
// or, for a page that names one, below its `collapseWidth` - every slot but
// the scope folds into one "Filter · n" button, where n is the number of
// filters that are not at their default (the page says, through
// `activeFilterCount`). The button opens a popover holding the folded
// controls themselves, so a choice made there is the same control with the
// same handler, and they return to the row when the popover closes. The fold
// is measured from the expanded controls' fitting widths whichever form is
// showing, so it cannot flip back and forth (Tasks' R4-UI-08 rule, which this
// generalises).
//
// Priorities follow the gotchas: `.fill` distribution with a spacer as the
// only flexible member (10), stack-level hugging for the stacks (12), and
// nothing above 499 that could become a window-width floor (13).

import AppKit

final class HelmFilterBar: NSView, NSPopoverDelegate {

    /// The page's filters that are not at their default, for "Filter · n".
    var activeFilterCount: () -> Int = { 0 } {
        didSet { refreshFilterButtonTitle() }
    }

    /// Below this width the bar folds. `nil`: fold only when the slots do not
    /// fit, which is the rule for every page that has not measured a reason
    /// to fold earlier.
    var collapseWidth: CGFloat?

    /// The slot views in order, and which of them fold.
    private let scope: NSView?
    private let foldable: [NSView]
    private let trailing: [NSView]
    private let row = NSStackView()
    private let spacer = NSView()
    private(set) lazy var filterButton: HelmButton = {
        let button = HelmButton(title: "Filter", variant: .secondary, size: .small,
                                symbol: "line.3.horizontal.decrease", target: self, action: #selector(filterTapped))
        button.toolTip = "Show the filters that do not fit beside the tabs"
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.isHidden = true
        return button
    }()
    /// Views a page has hidden because they do not apply right now (the sort
    /// on the calendar, say). The bar never shows these, folded or not.
    private var pageHidden: Set<ObjectIdentifier> = []
    private(set) var isCollapsed = false
    private var lastFitWidth: CGFloat = -1
    private var popover: NSPopover?
    private let popoverStack = NSStackView()

    init(scope: NSView? = nil, popups: [NSView] = [], chips: [NSView] = [], search: NSView? = nil,
         trailing: [NSView] = []) {
        self.scope = scope
        foldable = popups + chips + (search.map { [$0] } ?? []) + trailing
        self.trailing = trailing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacerWidth = spacer.widthAnchor.constraint(equalToConstant: 0)
        spacerWidth.priority = .defaultLow
        spacerWidth.isActive = true

        var views: [NSView] = []
        if let scope { views.append(scope) }
        views += popups + chips + (search.map { [$0] } ?? [])
        views.append(filterButton)
        views.append(spacer)
        views += trailing
        for view in views where view !== spacer {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        // The search is the one slot that may take the row's slack: it is
        // flexible where every other control holds its own width, and it is
        // the first thing to give way (it has no intrinsic width, gotcha 12,
        // so a page that wants it fixed gives it a width constraint).
        if let search {
            search.setContentHuggingPriority(.defaultLow, for: .horizontal)
            search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        if let scope {
            // A stack-backed control has no intrinsic width, so its hugging is
            // a no-op (gotcha (12)); a real `width == 0` preference one step
            // above the spacer keeps the tabs at their own width.
            let narrow = scope.widthAnchor.constraint(equalToConstant: 0)
            narrow.priority = HelmDaylightPriority.columnHug
            narrow.isActive = true
        }
        for view in views { row.addArrangedSubview(view) }
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        popoverStack.orientation = .vertical
        popoverStack.alignment = .leading
        popoverStack.spacing = HelmMetrics.s3
        popoverStack.edgeInsets = NSEdgeInsets(top: HelmMetrics.s4, left: HelmMetrics.s4,
                                               bottom: HelmMetrics.s4, right: HelmMetrics.s4)
        setAccessibilityElement(false)
        // GL-09: a popover left open when the app locks would stay readable
        // and interactive above the overlay, so the lock closes it.
        AppLockGate.shared.registerLockDismissiblePopover(owner: self) { [weak self] in self?.popover }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Visibility

    /// Hide or show a slot view because of the page's own state. A view the
    /// page has hidden stays hidden whether or not the bar is folded.
    func setPageHidden(_ view: NSView, _ hidden: Bool) {
        let id = ObjectIdentifier(view)
        let changed = hidden ? pageHidden.insert(id).inserted : pageHidden.remove(id) != nil
        guard changed else { return }
        lastFitWidth = -1
        applyVisibility()
        needsLayout = true
    }

    private func wanted(_ view: NSView) -> Bool { !pageHidden.contains(ObjectIdentifier(view)) }

    // MARK: Fitting

    /// The width the expanded row needs: the scope and every wanted foldable
    /// at its own fitting width, plus the gaps.
    var expandedWidth: CGFloat {
        let views = (scope.map { [$0] } ?? []) + foldable.filter(wanted)
        return views.reduce(0) { $0 + $1.fittingSize.width } + row.spacing * CGFloat(max(0, views.count - 1))
    }

    /// Folds or unfolds for `width`. A page whose row takes its width after
    /// the column it sits in calls this with the column's width; otherwise
    /// the bar calls it from its own `layout`.
    func fit(width: CGFloat) {
        guard width > 0, abs(width - lastFitWidth) > 0.5 else { return }
        lastFitWidth = width
        let collapse = collapseWidth.map { width < $0 } ?? (expandedWidth > width)
        guard collapse != isCollapsed || filterButton.isHidden == collapse else {
            applyVisibility()
            return
        }
        isCollapsed = collapse
        if !collapse { popover?.close() }
        applyVisibility()
    }

    override func layout() {
        super.layout()
        fit(width: bounds.width)
    }

    /// Only a real change is written: a visibility change schedules another
    /// layout pass, and this can run from one.
    private func applyVisibility() {
        let folded = popover?.isShown == true
        for view in foldable where view.superview === row || !folded {
            let hidden = !wanted(view) || isCollapsed
            if view.isHidden != hidden { view.isHidden = hidden }
        }
        if let scope, scope.isHidden == wanted(scope) { scope.isHidden = !wanted(scope) }
        let showButton = isCollapsed && foldable.contains(where: wanted)
        if filterButton.isHidden == showButton { filterButton.isHidden = !showButton }
        refreshFilterButtonTitle()
    }

    func refreshFilterButtonTitle() {
        let count = activeFilterCount()
        let title = count > 0 ? "Filter \u{00B7} \(count)" : "Filter"
        if filterButton.title != title { filterButton.title = title }
        filterButton.setAccessibilityLabel(count > 0 ? "Filter, \(count) on" : "Filter")
    }

    // MARK: The folded controls

    @objc private func filterTapped() {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        // The folded controls themselves, in slot order: the same control and
        // the same handler as on the row.
        for view in foldable where wanted(view) {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
            view.isHidden = false
            popoverStack.addArrangedSubview(view)
        }
        let controller = NSViewController()
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = HelmTheme.nsColor(ThemeManager.shared.theme.chromeBackgroundHex).cgColor
        host.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        popoverStack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(popoverStack)
        NSLayoutConstraint.activate([
            popoverStack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            popoverStack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            popoverStack.topAnchor.constraint(equalTo: host.topAnchor),
            popoverStack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        controller.view = host
        let shown = NSPopover()
        shown.behavior = .transient
        shown.contentViewController = controller
        shown.delegate = self
        popover = shown
        shown.show(relativeTo: filterButton.bounds, of: filterButton, preferredEdge: .maxY)
    }

    /// Puts every folded control back in its slot.
    func popoverDidClose(_ notification: Notification) {
        restoreFoldedViews()
        popover = nil
    }

    private func restoreFoldedViews() {
        var anchor: NSView? = scope
        for view in foldable {
            if view.superview === popoverStack {
                popoverStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            if view.superview !== row {
                let after = anchor.flatMap { row.arrangedSubviews.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                // Trailing views go after the spacer, the rest before the
                // Filter button, so the order is the declared one.
                let index = isTrailing(view)
                    ? (row.arrangedSubviews.firstIndex(of: spacer).map { max($0 + 1, after) } ?? after)
                    : min(after, row.arrangedSubviews.firstIndex(of: filterButton) ?? after)
                row.insertArrangedSubview(view, at: index)
            }
            anchor = view
        }
        applyVisibility()
    }

    private func isTrailing(_ view: NSView) -> Bool { trailing.contains { $0 === view } }

    /// The row's views in order (the Filter button and the spacer included),
    /// the same reading an `NSStackView` row gave its callers.
    var arrangedSubviews: [NSView] { row.arrangedSubviews }

    #if FM_SELFTESTS
    var debugIsCollapsed: Bool { isCollapsed }
    var debugFilterButtonTitle: String { filterButton.title }
    var debugFilterButtonShown: Bool { !filterButton.isHidden }
    var debugRowOrder: [NSView] { row.arrangedSubviews.filter { $0 !== spacer } }
    var debugPopoverViews: [NSView] { popoverStack.arrangedSubviews }
    func debugOpenFilters() { filterTapped() }
    func debugCloseFilters() {
        popover?.close()
        restoreFoldedViews()
        popover = nil
    }
    #endif
}
