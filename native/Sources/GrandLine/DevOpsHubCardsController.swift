// Grand Line - native macOS app.
//
// DevOps Hub's project cards: the page the DevOps Hub row opens, on
// Connections' pattern (C-4), which is the design picked on the second
// DevOps Hub board (`data/grand-line-devops-hub-page/`, layout A).
//
//   - **The hero column** (`HelmHeroColumn` in a `HelmSplitPage` sidebar
//     pane): the hub's verdict, a ring of projects running over projects
//     registered, the projects running (or, with none, the ones that ran
//     last), an Add Project row, and Projects / Running / Need attention at
//     its foot. Below the collapse width it moves into the content as a
//     band, the way Health's does, so the verdict stays on screen.
//   - **The filter row**: a search over name, folder and port, All / Running
//     / Attention with their counts, and Grid / List.
//   - **The projects**: the host card's roomy 98pt card (`HelmCardGrid`), two
//     to a row, or the same projects as a `HelmDataTable`. A card's three
//     icon buttons are its state's first action (Start, Stop, Cancel, Retry
//     or Choose Folder), Open, and Edit, which is the Project settings sheet.
//
// The words are `DevOpsHubHeroWords` and `DevOpsHubCardWords`, pure and
// asserted headless. Every action is the hub's (`DevOpsHubController`), so a
// card, a table row, the column and ⌘K cannot do a thing differently.

import AppKit

final class DevOpsHubCardsController: NSViewController, HelmSplitPageHosting {

    /// What the hub runs for this view.
    struct Handlers {
        var open: (String) -> Void = { _ in }
        var primary: (String, DevOpsHubCardWords.Primary) -> Void = { _, _ in }
        var action: (String, DevOpsHubCardWords.Action) -> Void = { _, _ in }
        var edit: (String) -> Void = { _ in }
        var add: () -> Void = {}
        /// UX-15: a folder dropped on the page, to add as a project.
        var addFolder: (URL) -> Void = { _ in }
    }

    var handlers = Handlers()

    /// Set by the hub: this view is the one showing, so the uptime on the
    /// cards ticks (GL-13).
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            refreshTimer()
        }
    }

    private let registry: LocalProjectRegistry
    private(set) var splitPage: HelmSplitPage?
    let heroColumn = HelmHeroColumn()
    /// Holds the column as a band while the split's pane is put away.
    private let bandHolder = NSView()
    private var bandCollapsed: NSLayoutConstraint?
    private var filterTop: NSLayoutConstraint?
    private var contentLeading: NSLayoutConstraint?
    private let filterRow = NSStackView()
    private let searchField = HelmSearchField(placeholder: "Find a project, folder or port")
    private let filterTabs = HelmSegmentedTabs(
        items: DevOpsHubFilter.allCases.map { .init(id: $0.rawValue, title: $0.title) },
        selected: DevOpsHubFilter.all.rawValue, size: .compact)
    private lazy var viewModeTabs: HelmSegmentedTabs = {
        let tabs = HelmSegmentedTabs(items: [.init(id: Self.gridModeID, title: "Grid"),
                                            .init(id: Self.listModeID, title: "List")],
                                     selected: AppSettings.shared.devopsHubShowList ? Self.listModeID : Self.gridModeID,
                                     size: .compact)
        tabs.onSelect = { [weak self] id in self?.setShowsList(id == Self.listModeID) }
        tabs.setAccessibilityLabel("Show as cards or as a list")
        tabs.toolTip = "Show as cards or as a list"
        return tabs
    }()
    let grid = HelmCardGrid(cardHeight: HelmCardGrid.roomyCardHeight,
                            minimumCardWidth: HelmCardGrid.roomyMinimumCardWidth)
    let table = HelmDataTable(columns: [
        .init(id: "project", title: "Project", width: 200),
        .init(id: "state", title: "State", width: 190, minWidth: 150, flexible: true),
        .init(id: "address", title: "Address", width: 140, hiddenBelow: 560),
        .init(id: "folder", title: "Folder", width: 240, hiddenBelow: 760),
    ], actionsWidth: 120)

    private var filter: DevOpsHubFilter = .all
    private(set) var heroWords: DevOpsHubHeroWords?
    private var heroRuns: [() -> Void] = []
    private var registryObserver: NSObjectProtocol?
    private var themeToken: ThemeObservation?
    private var uptimeTimer: Timer?

    static let gridModeID = "grid"
    static let listModeID = "list"
    /// The key the grid's "Add a project" card carries.
    static let addCardKey = "devopsHub.add"

    init(registry: LocalProjectRegistry = .shared) {
        self.registry = registry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let registryObserver { NotificationCenter.default.removeObserver(registryObserver) }
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
        uptimeTimer?.invalidate()
    }

    // MARK: Build

    override func loadView() {
        // UX-15: a folder dropped anywhere on the cards adds a project.
        let root = DevOpsHubFolderDropView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        root.onDropFolder = { [weak self] folder in self?.handlers.addFolder(folder) }
        root.wantsLayer = true
        view = root
        buildSplit(in: root)
        registryObserver = NotificationCenter.default.addObserver(
            forName: LocalProjectRegistry.didChange, object: registry, queue: .main
        ) { [weak self] _ in self?.render() }
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        render()
    }

    private func buildSplit(in root: NSView) {
        let paneWidth = HelmMetrics.pageGutter + HelmHeroColumn.width
        // A column of one width that yields to the content's floor, so the
        // window never grows for it (`HelmSplitPage` 1.2.0, gotcha (13)).
        let split = HelmSplitPage(sidebarWidth: paneWidth, minimum: HelmSplitPage.yieldingMinimumThickness,
                                  maximum: paneWidth, surface: .pageGround)
        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        heroColumn.setAccessibilityLabel("DevOps Hub summary")
        buildContent(in: split.contentPane)
        splitPage = split
        placeHeroColumn(asBand: false, in: split)
        split.preferredSidebarWidth = paneWidth
        split.collapsesBelowWidth = collapseWidth()
        split.onNarrowChanged = { [weak self, weak split] _ in
            guard let self, let split else { return }
            self.placeHeroColumn(asBand: !split.sidebarIsWanted, in: split)
        }
        split.onSidebarCollapseChanged = { [weak self, weak split] collapsed in
            // Reported from inside the split's own resize; moving a view
            // between panes waits a turn.
            DispatchQueue.main.async {
                guard let self, let split else { return }
                self.placeHeroColumn(asBand: collapsed, in: split)
            }
        }
    }

    /// The least the page is allowed before the column goes: Connections'
    /// 880, or the column beside the filter row's own floor if that is more.
    static let heroCollapseWidth: CGFloat = 880

    private func collapseWidth() -> CGFloat {
        let column = HelmMetrics.pageGutter + HelmHeroColumn.width + HelmMetrics.s4
        return max(Self.heroCollapseWidth,
                   column + HelmSplitPage.floorWidth(of: filterRow) + HelmMetrics.pageGutter + HelmMetrics.s2)
    }

    private func buildContent(in pane: NSView) {
        let guide = NSLayoutGuide()
        pane.addLayoutGuide(guide)
        bandHolder.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(bandHolder)

        searchField.onTextChanged = { [weak self] _ in self?.renderProjects() }
        searchField.setAccessibilityLabel("Find a project by name, folder or port")
        // Wide enough for its placeholder, and the first thing to give way.
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 360)
        searchWidth.priority = HelmDaylightPriority.columnHug
        searchWidth.isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filterTabs.onSelect = { [weak self] id in
            self?.filter = DevOpsHubFilter(rawValue: id) ?? .all
            self?.renderProjects()
        }
        filterTabs.setAccessibilityLabel("Show all projects, the running ones, or the ones that need attention")
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapse = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        collapse.isActive = true
        for view in [searchField, filterTabs, spacer, viewModeTabs] as [NSView] { filterRow.addArrangedSubview(view) }
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.distribution = .fill
        filterRow.spacing = HelmMetrics.s3
        filterRow.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (12): the segmented controls have no intrinsic width to hug
        // with, so a real width hug just above the spacer's collapse keeps
        // them at their pills and the spacer takes the slack.
        for tabs in [filterTabs, viewModeTabs] {
            tabs.setContentHuggingPriority(.required, for: .horizontal)
            tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
            let hug = tabs.widthAnchor.constraint(equalToConstant: 0)
            hug.priority = NSLayoutConstraint.Priority(252)
            hug.isActive = true
        }
        pane.addSubview(filterRow)

        grid.accessibilityName = "Projects"
        table.accessibilityName = "Projects"
        table.actionsAlwaysVisible = true
        table.card.translatesAutoresizingMaskIntoConstraints = false
        for body in [grid, table.card] as [NSView] {
            body.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(body)
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                body.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: HelmMetrics.s3),
                body.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -HelmMetrics.pageGutter),
            ])
        }
        applyShowsList()

        let leading = guide.leadingAnchor.constraint(equalTo: pane.leadingAnchor,
                                                     constant: HelmMetrics.s4 - HelmSplitPage.dividerThickness)
        contentLeading = leading
        let collapsed = bandHolder.heightAnchor.constraint(equalToConstant: 0)
        bandCollapsed = collapsed
        let top = filterRow.topAnchor.constraint(equalTo: bandHolder.bottomAnchor)
        filterTop = top
        NSLayoutConstraint.activate([
            leading,
            guide.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -HelmMetrics.pageGutter),
            guide.topAnchor.constraint(equalTo: pane.topAnchor, constant: HelmMetrics.pageContentInset),
            guide.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            bandHolder.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            bandHolder.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            bandHolder.topAnchor.constraint(equalTo: guide.topAnchor),
            collapsed,
            top,
            filterRow.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            filterRow.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            filterRow.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    /// The column in the split's pane, or across the top of the content as
    /// a band while the pane is put away (Health's `placeHeroColumn`).
    private func placeHeroColumn(asBand: Bool, in split: HelmSplitPage) {
        let alreadyThere = asBand ? heroColumn.superview === bandHolder : heroColumn.superview === split.sidebarPane
        guard !alreadyThere else { return }
        heroColumn.removeFromSuperview()
        heroColumn.setArrangement(asBand ? .band : .column)
        if asBand {
            heroColumn.translatesAutoresizingMaskIntoConstraints = false
            bandHolder.addSubview(heroColumn)
            NSLayoutConstraint.activate([
                heroColumn.leadingAnchor.constraint(equalTo: bandHolder.leadingAnchor),
                heroColumn.trailingAnchor.constraint(equalTo: bandHolder.trailingAnchor),
                heroColumn.topAnchor.constraint(equalTo: bandHolder.topAnchor),
                heroColumn.bottomAnchor.constraint(equalTo: bandHolder.bottomAnchor),
            ])
        } else {
            HelmSplitPage.pin(heroColumn, in: split.sidebarPane,
                              insets: NSEdgeInsets(top: HelmMetrics.pageContentInset, left: HelmMetrics.pageGutter,
                                                   bottom: HelmMetrics.pageGutter, right: 0),
                              yieldsWidth: true)
        }
        bandCollapsed?.isActive = !asBand
        filterTop?.constant = asBand ? HelmMetrics.s4 : 0
        // The pane's gutter is the column's. With the pane away, the content
        // takes the page's own.
        contentLeading?.constant = asBand ? HelmMetrics.pageGutter : HelmMetrics.s4 - HelmSplitPage.dividerThickness
        renderHero()
    }

    var showsBand: Bool { heroColumn.superview === bandHolder }

    // MARK: Grid or list

    private func setShowsList(_ list: Bool) {
        AppSettings.shared.devopsHubShowList = list
        applyShowsList()
        renderProjects()
    }

    private func applyShowsList() {
        let list = AppSettings.shared.devopsHubShowList
        grid.isHidden = list
        table.card.isHidden = !list
        viewModeTabs.select(list ? Self.listModeID : Self.gridModeID)
    }

    // MARK: Render

    override func viewWillAppear() {
        super.viewWillAppear()
        render()
        refreshTimer()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        uptimeTimer?.invalidate()
        uptimeTimer = nil
    }

    private func refreshTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        guard isViewLoaded, isActive, view.window != nil else { return }
        render()
        // A minute's reading can land seconds late; the tolerance lets the
        // system batch the wake-up (audit 3.4).
        let timer = Timer.scheduledTimer(withTimeInterval: DevOpsHubProjectController.uptimeInterval,
                                         repeats: true) { [weak self] _ in self?.render() }
        timer.tolerance = DevOpsHubProjectController.uptimeInterval / 6
        uptimeTimer = timer
    }

    func render() {
        guard isViewLoaded else { return }
        renderHero()
        renderProjects()
    }

    private func renderHero() {
        let projects = registry.projects
        let words = DevOpsHubHeroWords.make(projects: projects, state: registry.state(of:), now: registry.clock())
        heroWords = words
        let ring = words.ring.map { ring in
            HelmHeroColumn.Ring(fraction: ring.total > 0 ? Double(ring.running) / Double(ring.total) : 0,
                                label: "\(ring.running)/\(ring.total)",
                                caption: "projects running\n\(ring.total) registered",
                                spoken: "\(ring.running) of \(ring.total) projects running", state: .ok)
        }
        let header = HelmHeroColumn.Header(symbol: "shippingbox.fill", kicker: "DevOps Hub",
                                           headline: words.headline, body: words.body, ring: ring)
        heroRuns = []
        var sections: [HelmHeroColumn.Section] = []
        if let list = words.list {
            let rows: [NSView] = list.projectIDs.compactMap { id in
                guard let project = registry.project(id) else { return nil }
                let state = registry.state(of: id)
                let pill: HelmButton
                if state.isRunning {
                    pill = HelmButton(title: "Open", variant: .secondary, size: .small,
                                      target: self, action: #selector(heroRowTapped(_:)))
                    pill.toolTip = "Open \(project.name)"
                    heroRuns.append { [weak self] in self?.handlers.open(id) }
                } else {
                    let card = DevOpsHubCardWords.make(project: project, state: state, now: registry.clock())
                    pill = HelmButton(title: "", variant: .secondary, size: .small, symbol: card.primary.symbol,
                                      target: self, action: #selector(heroRowTapped(_:)))
                    pill.toolTip = "\(card.primary.title) \(project.name)"
                    heroRuns.append { [weak self] in self?.handlers.primary(id, card.primary) }
                }
                pill.tag = heroRuns.count - 1
                pill.setAccessibilityLabel(pill.toolTip)
                let subtitle = state.isRunning ? "\(LocalStaticServer.loopbackHost):\(project.port)"
                    : DevOpsHubCardWords.make(project: project, state: state, now: registry.clock()).line
                return HelmHeroRow(leading: .symbol("shippingbox"), title: project.name, subtitle: subtitle,
                                   subtitleIsCode: state.isRunning, subtitleTruncation: .byTruncatingTail,
                                   trailing: pill)
            }
            sections.append(.init(title: list.title, trailing: "\(rows.count)", views: rows))
        }
        let add = HelmButton(title: "Add", variant: .secondary, size: .small, symbol: "plus",
                             target: self, action: #selector(addTapped))
        add.toolTip = "Add a project: a folder with an index.html"
        add.identifier = NSUserInterfaceItemIdentifier("devopsHub.addProject")
        sections.append(.init(title: "Add a project", trailing: nil, views: [
            HelmHeroRow(leading: .symbol("folder.badge.plus"), title: "A local folder",
                        subtitle: "With an index.html at its top", trailing: add),
        ]))
        let figures = HelmKPIStrip(density: .inline)
        figures.figureSize = 20
        figures.configure([
            .count(words.projectCount, caption: words.projectCount == 1 ? "Project" : "Projects"),
            .count(words.runningCount, caption: "Running"),
            .count(words.attentionCount, caption: "Attention"),
        ])
        figures.setAccessibilityLabel("Projects, running and needing attention")
        heroColumn.configure(header: header, sections: sections, foot: [figures],
                             tone: DevOpsHubProjectController.heroTone(words.tone, in: ThemeManager.shared.theme))
    }

    @objc private func heroRowTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < heroRuns.count else { return }
        heroRuns[sender.tag]()
    }

    @objc private func addTapped() { handlers.add() }

    /// The projects the search and the filter leave, in the store's order.
    var shownProjects: [LocalProject] {
        registry.projects.filter { project in
            filter.includes(registry.state(of: project.id))
                && DevOpsHubFilter.matches(project, query: searchField.stringValue)
        }
    }

    private func renderProjects() {
        guard isViewLoaded else { return }
        let all = registry.projects
        let states = all.map { registry.state(of: $0.id) }
        filterTabs.setTitle("All\u{2002}\(all.count)", forID: DevOpsHubFilter.all.rawValue)
        filterTabs.setTitle("Running\u{2002}\(states.filter { DevOpsHubFilter.running.includes($0) }.count)",
                            forID: DevOpsHubFilter.running.rawValue)
        filterTabs.setTitle("Attention\u{2002}\(states.filter(\.needsAttention).count)",
                            forID: DevOpsHubFilter.attention.rawValue)
        let shown = shownProjects
        let narrowed = filter != .all || !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        if AppSettings.shared.devopsHubShowList {
            renderTable(shown, narrowed: narrowed)
        } else {
            renderGrid(shown, narrowed: narrowed)
        }
    }

    private func renderGrid(_ shown: [LocalProject], narrowed: Bool) {
        var cards = shown.map(card(for:))
        if !narrowed, !cards.isEmpty { cards.append(addCard()) }
        grid.setSections([.init(title: nil, cards: cards)])
        if registry.projects.isEmpty {
            grid.setEmptyState(symbol: "shippingbox", title: "No projects yet",
                               body: "Add a folder of built HTML to serve it here, on this Mac only.",
                               action: .init(title: "Add Project\u{2026}", symbol: "plus") { [weak self] in
                                   self?.handlers.add()
                               })
        } else if shown.isEmpty {
            grid.setEmptyState(symbol: "line.3.horizontal.decrease.circle", title: "No projects match",
                               body: "Try All, or clear the search.", action: nil)
        } else {
            grid.clearEmptyState()
        }
    }

    private func card(for project: LocalProject) -> HelmCardGrid.Card {
        let id = project.id
        let state = registry.state(of: id)
        let words = DevOpsHubCardWords.make(project: project, state: state, now: registry.clock(),
                                            servedFiles: registry.folderCount(of: id)?.files)
        var card = HelmCardGrid.Card(key: id, symbol: "shippingbox", tint: .accent, tintHex: nil,
                                     title: project.name, subtitle: words.subtitle,
                                     accessibilityLabel: words.accessibilityLabel)
        card.subtitleTruncation = .byTruncatingMiddle
        card.status = words.status.map { ($0, Self.tint(words.tint)) }
        card.detail = words.detail
        card.actions = [
            .init(symbol: words.primary.symbol, label: "\(words.primary.title) \(project.name)") { [weak self] in
                self?.handlers.primary(id, words.primary)
            },
            // UX-15: a running card's address is one press from the
            // clipboard. Opening is still the card's own click.
            state.isRunning
                ? .init(symbol: "doc.on.doc", label: "Copy \(words.subtitle)") { [weak self] in
                    self?.handlers.action(id, .copyAddress)
                }
                : .init(symbol: DevOpsHubCardWords.openSymbol, label: "Open \(project.name)") { [weak self] in
                    self?.handlers.open(id)
                },
            .init(symbol: DevOpsHubCardWords.editSymbol, label: "Edit \(project.name)\u{2019}s settings") { [weak self] in
                self?.handlers.edit(id)
            },
        ]
        card.activate = { [weak self] in self?.handlers.open(id) }
        card.showDetails = { [weak self] in self?.handlers.open(id) }
        card.edit = { [weak self] in self?.handlers.edit(id) }
        card.menu = words.menu.map { action in
            HelmDataTable.Action(title: action.title, symbol: action.symbol) { [weak self] in
                self?.handlers.action(id, action)
            }
        }
        return card
    }

    /// The grid's last card, after the projects: Add Project, as the hosts
    /// grid leads with its built-in card.
    /// UX-15: the add card says a folder can be dropped.
    static let addCardSubtitle = "Drop a folder on this page"

    private func addCard() -> HelmCardGrid.Card {
        var card = HelmCardGrid.Card(key: Self.addCardKey, symbol: "plus", tint: .neutral, tintHex: nil,
                                     title: "Add a project", subtitle: Self.addCardSubtitle,
                                     accessibilityLabel: "Add a project")
        card.subtitleIsCode = false
        card.detail = "It needs an index.html at its top"
        card.activate = { [weak self] in self?.handlers.add() }
        card.actions = [.init(symbol: "plus", label: "Add a project") { [weak self] in self?.handlers.add() }]
        return card
    }

    private func renderTable(_ shown: [LocalProject], narrowed: Bool) {
        var rows: [HelmDataTable.Row] = shown.map { project in
            let id = project.id
            let state = registry.state(of: id)
            let words = DevOpsHubCardWords.make(project: project, state: state, now: registry.clock())
            var row = HelmDataTable.Row.record(id)
            row.cells = [
                "project": .title(project.name, subtitle: nil, subtitleIsCode: false, symbol: "shippingbox",
                                  tint: .accent, tintHex: nil),
                "state": words.status.map { .status($0, tint: Self.tint(words.tint)) } ?? .muted(words.line),
                "address": .code("\(LocalStaticServer.loopbackHost):\(project.port)"),
                "folder": .code(project.displayFolder),
            ]
            row.primary = .init(title: words.primary.title, symbol: words.primary.symbol) { [weak self] in
                self?.handlers.primary(id, words.primary)
            }
            row.pinsPrimary = true
            row.menu = words.menu.map { action in
                HelmDataTable.Action(title: action.title, symbol: action.symbol) { [weak self] in
                    self?.handlers.action(id, action)
                }
            }
            row.activate = { [weak self] in self?.handlers.open(id) }
            return row
        }
        if registry.projects.isEmpty {
            rows = [.empty(symbol: "shippingbox", title: "No projects yet",
                           body: "Add a folder of built HTML to serve it here, on this Mac only.",
                           action: .init(title: "Add Project\u{2026}", symbol: "plus") { [weak self] in
                               self?.handlers.add()
                           })]
        } else if rows.isEmpty, narrowed {
            rows = [.empty(symbol: "line.3.horizontal.decrease.circle", title: "No projects match",
                           body: "Try All, or clear the search.")]
        }
        table.setRows(rows)
    }

    static func tint(_ tint: DevOpsHubCardWords.Tint) -> HelmTint {
        switch tint {
        case .neutral: return .neutral
        case .good: return .good
        case .warn: return .warn
        case .critical: return .critical
        }
    }

    // MARK: Theme

    private func applyTheme(_ theme: HelmTheme) {
        guard isViewLoaded else { return }
        // ThemeManager's checklist item 2: the scroller, the field editor and
        // the menus follow the theme's mode, not the OS's.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        splitPage?.applyTheme(theme)
        grid.applyTheme(theme)
        table.applyTheme(theme)
        // GL-24: a theme change repaints from what is already known.
        renderHero()
    }

    #if FM_SELFTESTS
    var debugFilterTabs: HelmSegmentedTabs { filterTabs }
    var debugViewModeTabs: HelmSegmentedTabs { viewModeTabs }
    var debugSearchField: HelmSearchField { searchField }
    func debugSetFilter(_ filter: DevOpsHubFilter) {
        filterTabs.select(filter.rawValue)
        self.filter = filter
        renderProjects()
    }
    func debugSetSearch(_ text: String) {
        searchField.stringValue = text
        renderProjects()
    }
    #endif
}

/// UX-15: DevOps Hub's cards view takes a dropped folder, which opens Add a
/// project filled in from it. Only a folder is accepted; the sheet still
/// checks it for an `index.html` and asks for a name and a port.
final class DevOpsHubFolderDropView: NSView {
    var onDropFolder: ((URL) -> Void)?
    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The dragged folder, or nil: the decision, so a suite drives the real
    /// accept or refuse without a drag session.
    static func droppedFolder(fromPasteboard pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let url = urls.first else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = Self.droppedFolder(fromPasteboard: sender.draggingPasteboard) != nil
        isHighlighted = accepted
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let folder = Self.droppedFolder(fromPasteboard: sender.draggingPasteboard) else { return false }
        onDropFolder?(folder)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        let accent = HelmTheme.nsColor(ThemeManager.shared.theme.accentHex)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3),
                                xRadius: HelmMetrics.rCard, yRadius: HelmMetrics.rCard)
        accent.withAlphaComponent(0.06).setFill()
        path.fill()
        accent.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
