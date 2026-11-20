// Grand Line - native macOS app.
//
// DevOps Hub's page: the project cards (`DevOpsHubCardsController`) and one
// project's own view (`DevOpsHubProjectController`), with the page switching
// between them. The second DevOps Hub board's picks
// (`data/grand-line-devops-hub-page/`):
//
//   - The DevOps Hub row opens the cards. The projects are not rows in the
//     sidebar any more, so there is one destination and one row, and the row
//     is lit whichever view shows.
//   - Open shows a project inside this page rather than as a pushed view of
//     its own. The project view is the page PR 619 shipped, with a Projects
//     button back to the cards.
//   - The page keeps what it shows for the session only. Coming back from
//     another page finds it as it was left. A click on the DevOps Hub row
//     while it shows a project goes back to the cards, and a relaunch opens
//     the cards. The two views are places of their own in the window's history
//     (`WorkspaceHistoryPlace`), so Back steps from a project to the cards.
//
// Every action a card, a table row, the column, the project view or ⌘K runs
// is here, over the one registry (`LocalProjectRegistry`), so none of them can
// do a thing differently. The state is still the registry's: this page mounts
// lazily (GL-37) and the sidebar's badge needs none of it.

import AppKit

final class DevOpsHubController: NSViewController, HelmSplitPageHosting, WorkspaceHistoryPlace {

    enum Mode: Equatable {
        case cards
        case project(String)
    }

    /// The page moved between the cards and a project (the shell renames the
    /// crumb).
    var onModeChanged: (() -> Void)?
    var onHistoryPlaceChanged: (() -> Void)?

    private let registry: LocalProjectRegistry
    let cards: DevOpsHubCardsController
    let projectView: DevOpsHubProjectController
    private(set) var mode: Mode = .cards
    /// Projects started from this page whose site should open here once it
    /// serves ("Show the site when it's ready").
    private var opensWhenRunning: Set<String> = []
    private var registryObserver: NSObjectProtocol?
    /// Each view's pins to the page. A hidden view's are inactive, so its
    /// subtree has no required path to the window (gotcha (15)): the strip
    /// of a project shown earlier must not hold the window open while the
    /// cards show.
    private var cardsPins: [NSLayoutConstraint] = []
    private var projectPins: [NSLayoutConstraint] = []

    init(registry: LocalProjectRegistry = .shared) {
        self.registry = registry
        cards = DevOpsHubCardsController(registry: registry)
        projectView = DevOpsHubProjectController(registry: registry)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let registryObserver { NotificationCenter.default.removeObserver(registryObserver) }
    }

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        view = root
        for child in [cards, projectView] as [NSViewController] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child.view)
            let pins = [
                child.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                child.view.topAnchor.constraint(equalTo: root.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ]
            if child === cards { cardsPins = pins } else { projectPins = pins }
        }
        cards.handlers = DevOpsHubCardsController.Handlers(
            open: { [weak self] id in self?.showProject(id) },
            primary: { [weak self] id, primary in self?.perform(primary, on: id) },
            action: { [weak self] id, action in self?.perform(action, on: id) },
            edit: { [weak self] id in self?.presentSettings(projectID: id) },
            add: { [weak self] in self?.presentAddProject() })
        projectView.onBack = { [weak self] in self?.showCards() }
        projectView.onEditSettings = { [weak self] id in self?.presentSettings(projectID: id) }
        registryObserver = NotificationCenter.default.addObserver(
            forName: LocalProjectRegistry.didChange, object: registry, queue: .main
        ) { [weak self] _ in self?.registryChanged() }
        applyMode()
    }

    // MARK: Which view shows

    /// The project the page shows, or nil on the cards.
    var shownProject: LocalProject? {
        guard case .project(let id) = mode else { return nil }
        return registry.project(id)
    }

    /// The Split's Toggle Sidebar reaches the cards' column, and only while
    /// the cards show.
    var splitPage: HelmSplitPage? { mode == .cards ? cards.splitPage : nil }

    func showCards() { setMode(.cards) }

    func showProject(_ id: String) {
        guard registry.project(id) != nil else { return }
        setMode(.project(id))
    }

    private func setMode(_ next: Mode) {
        guard next != mode else { return }
        mode = next
        applyMode()
        onModeChanged?()
        onHistoryPlaceChanged?()
    }

    private func applyMode() {
        guard isViewLoaded else { return }
        let id: String?
        if case .project(let shown) = mode { id = shown } else { id = nil }
        // Pins first, so the view that shows has its frame before it renders.
        NSLayoutConstraint.deactivate(id == nil ? projectPins : cardsPins)
        NSLayoutConstraint.activate(id == nil ? cardsPins : projectPins)
        if let id { projectView.show(projectID: id) }
        cards.view.isHidden = id != nil
        projectView.view.isHidden = id == nil
        cards.isActive = id == nil
        projectView.isActive = id != nil
    }

    /// A removed project cannot stay on screen, and a project started from
    /// this page opens once it serves, when its setting says so.
    private func registryChanged() {
        if case .project(let id) = mode, registry.project(id) == nil { showCards() }
        for id in opensWhenRunning {
            switch registry.state(of: id) {
            case .running:
                opensWhenRunning.remove(id)
                showProject(id)
            case .starting:
                continue
            default:
                opensWhenRunning.remove(id)
            }
        }
    }

    // MARK: WorkspaceHistoryPlace

    static let cardsPlace = "cards"
    static let projectPlacePrefix = "project:"

    var historyPlace: String {
        switch mode {
        case .cards: return Self.cardsPlace
        case .project(let id): return Self.projectPlacePrefix + id
        }
    }

    func showHistoryPlace(_ place: String) {
        if place.hasPrefix(Self.projectPlacePrefix) {
            let id = String(place.dropFirst(Self.projectPlacePrefix.count))
            if registry.project(id) != nil {
                showProject(id)
                return
            }
        }
        showCards()
    }

    // MARK: Actions

    /// Start `id` from this page or from ⌘K: its site opens here once it
    /// serves, when "Show the site when it's ready" is on.
    func start(projectID id: String) {
        guard let project = registry.project(id) else { return }
        if project.opensWhenReady { opensWhenRunning.insert(id) }
        registry.start(id)
        registryChanged()
    }

    func perform(_ primary: DevOpsHubCardWords.Primary, on id: String) {
        switch primary {
        case .start, .retry: start(projectID: id)
        case .stop, .cancel:
            opensWhenRunning.remove(id)
            registry.stop(id)
        case .chooseFolder: chooseFolder(id)
        }
    }

    func perform(_ action: DevOpsHubCardWords.Action, on id: String) {
        guard let project = registry.project(id) else { return }
        switch action {
        case .start: start(projectID: id)
        case .stop:
            opensWhenRunning.remove(id)
            registry.stop(id)
        case .restart: registry.restart(id)
        case .open: showProject(id)
        case .openInBrowser: WebNavigationPolicy.openExternally(project.origin, from: "DevOps Hub")
        case .copyAddress:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.origin.absoluteString, forType: .string)
            Feedback.report("Address copied", kind: .done, persistence: .transient, in: view)
        case .settings: presentSettings(projectID: id)
        case .showInFinder: DevOpsHubProjectController.showInFinder(project.folder)
        case .remove: confirmRemove(id)
        }
    }

    private func chooseFolder(_ id: String) {
        guard let project = registry.project(id), let window = view.window else { return }
        DevOpsHubProjectController.chooseFolder(for: project, registry: registry, in: window)
    }

    /// The Project settings sheet for `id`, over this page: a card's pencil,
    /// its menu, ⌘E, and the project view's Project Settings and Change Port.
    func presentSettings(projectID id: String) {
        guard let project = registry.project(id) else { return }
        let others = Set(registry.projects.filter { $0.id != id }.map(\.port))
        let sheet = DevOpsHubSettingsSheet(project: project, takenPorts: others)
        sheet.onSave = { [weak self] edited in self?.registry.update(edited) }
        presentAsSheet(sheet)
    }

    /// Add Project: the same sheet with a name, suggesting the next free port.
    func presentAddProject() {
        let sheet = DevOpsHubSettingsSheet.adding(port: registry.nextFreePort(),
                                                  takenPorts: Set(registry.projects.map(\.port)))
        sheet.onSave = { [weak self] draft in
            guard let self, let added = self.registry.add(draft) else { return }
            Feedback.report("\(added.name) added", kind: .done, persistence: .transient, in: self.view)
        }
        presentAsSheet(sheet)
    }

    /// Remove asks first. It forgets the project and leaves its folder alone,
    /// so it is a plain confirmation rather than GL-06's delete prompt.
    private func confirmRemove(_ id: String) {
        guard let project = registry.project(id) else { return }
        let confirmed = HelmConfirm.confirm(
            title: "Remove \(project.name) from DevOps Hub?",
            body: "Grand Line stops serving it and forgets its settings. The folder \(project.displayFolder) "
                + "is left as it is.",
            confirmTitle: "Remove", destructive: true, confirmIsDefault: false, symbol: "shippingbox")
        guard confirmed else { return }
        opensWhenRunning.remove(id)
        registry.remove(id)
    }

    /// Reload the site (⌘R on the page), when a project's site shows.
    func reloadSite() {
        guard case .project = mode else { return }
        projectView.reloadSite()
    }

    #if FM_SELFTESTS
    var debugOpensWhenRunning: Set<String> { opensWhenRunning }
    #endif
}
