// Grand Line - native macOS app.
//
// DevOps Hub's project view: one local project, with a Start button while it
// is stopped and its site in a web view while it runs. It is the page PR 619
// shipped, now one of the two views `DevOpsHubController` holds (the other is
// the project cards), with a Projects button back to the cards on both of its
// layouts. Layout C on the first design board (`data/grand-line-devops-hub/`):
//
//   - **Running**, the hero shrinks to a 44pt strip in the gradient: a state
//     dot, the address as a copy button, the uptime and files served, and
//     Reload, Open in Browser, Restart and Stop. The site gets every other
//     point, because it is a full app with columns of its own.
//   - **Anything else** (not started, starting, failed, folder not found)
//     is a centred hero card (`HelmHeroColumn` in `.panel`) over a dimmed
//     preview of the site, with a checks card under it that says what Start
//     checks, or checked.
//
// The state is not the page's: `LocalProjectRegistry` holds it, so the
// sidebar's badge, the cards and a launch-time start work while this view
// has never been shown (GL-37 mounts the page lazily). The page draws the registry
// and adds the one thing only it knows, whether the site has loaded into its
// web view. The words are `DevOpsHubWords`, pure and asserted headless.
//
// The strip is page code on `HelmHeroSurface`, with the kit's own ghost pills
// (`HelmButton.heroInk`). It moves into the kit only if a second page wants
// a strip.

import AppKit

final class DevOpsHubProjectController: NSViewController {

    /// The Projects button: back to the cards.
    var onBack: (() -> Void)?
    /// Project Settings and Change Port: the hub presents the sheet, the same
    /// one a card's pencil opens.
    var onEditSettings: ((String) -> Void)?

    /// Set by the hub: this view is the one showing. The uptime ticks and the
    /// folder is read only then (GL-13), since a hidden child view still gets
    /// its appearance callbacks while its parent is in the window.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            refreshActivity()
        }
    }

    private let registry: LocalProjectRegistry
    private(set) var projectID: String?

    // The hero half.
    private let heroStage = NSView()
    private let backdrop = NSImageView()
    private let backdropWash = NSView()
    private let heroScroll = NSScrollView()
    private let heroDocument = FlippedView()
    private let heroColumn = NSStackView()
    private let hero = HelmHeroColumn()
    private let checksCard = HelmCard()
    private let checksHeader = HelmSectionHeader(size: .card)
    private let checksRows = NSStackView()
    private let heroBackButton = HelmButton(title: "Projects", variant: .secondary, size: .small,
                                            symbol: "chevron.left")
    private var checkDetailLabels: [NSTextField] = []

    // The running half.
    private let courseStage = NSView()
    private let strip = DevOpsHubStrip()
    private var webViews: [String: DevOpsHubWebView] = [:]
    private var webContainer = NSView()

    /// What the web view has done for each project's current run.
    private var loadedOrigin: [String: URL] = [:]
    /// The run key each loaded site was given (S-02). A new run means a new
    /// key, so the site loads again with it.
    private var loadedToken: [String: String] = [:]
    private var finished: Set<String> = []
    private var progress: [String: Double] = [:]
    /// B-05: projects whose site crashed twice in a row, so their web view
    /// stopped reloading it. The page says so until Reload or a stop.
    private var crashing: Set<String> = []
    /// Projects whose site was asked for with "Show It Here"
    /// while "Show the site when it's ready" is off.
    private var shownOnRequest: Set<String> = []
    private var preflight: [String: LocalProjectPreflight.Outcome] = [:]
    private var preflightInFlight: Set<String> = []
    /// The folder each project's preflight read, so a new folder (from the
    /// settings sheet, Choose Folder or the sidebar menu) is read again.
    private var preflightFolder: [String: URL] = [:]

    private var registryObserver: NSObjectProtocol?
    private var themeToken: ThemeObservation?
    private var uptimeTimer: Timer?
    private(set) var words: DevOpsHubWords?

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

    var project: LocalProject? { projectID.flatMap(registry.project) }

    // MARK: Build

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 700))
        root.wantsLayer = true
        view = root
        buildHeroStage(in: root)
        buildCourseStage(in: root)
        registryObserver = NotificationCenter.default.addObserver(
            forName: LocalProjectRegistry.didChange, object: registry, queue: .main
        ) { [weak self] _ in self?.render() }
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        render()
    }

    static let pageInset: CGFloat = HelmMetrics.s5
    static let columnWidth: CGFloat = 720

    private func buildHeroStage(in root: NSView) {
        heroStage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(heroStage)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.imageScaling = .scaleProportionallyUpOrDown
        backdrop.imageAlignment = .alignTopLeft
        backdrop.wantsLayer = true
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.cornerRadius = HelmHeroColumn.cornerRadius
        // Gotcha (13): an image view's intrinsic size is its image's, and the
        // course's share image is 1200pt wide. At the default resistance it
        // held the window open at that width, so the preview gives way.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            backdrop.setContentCompressionResistancePriority(.defaultLow, for: axis)
            backdrop.setContentHuggingPriority(.defaultLow, for: axis)
        }
        backdropWash.translatesAutoresizingMaskIntoConstraints = false
        backdropWash.wantsLayer = true
        backdropWash.layer?.cornerRadius = HelmHeroColumn.cornerRadius
        for view in [backdrop, backdropWash] { heroStage.addSubview(view) }

        heroBackButton.translatesAutoresizingMaskIntoConstraints = false
        heroBackButton.target = self
        heroBackButton.action = #selector(backClicked)
        heroBackButton.identifier = NSUserInterfaceItemIdentifier("devopsHub.back")
        heroBackButton.toolTip = "Back to the projects"

        heroScroll.translatesAutoresizingMaskIntoConstraints = false
        heroScroll.drawsBackground = false
        heroScroll.hasVerticalScroller = true
        heroScroll.autohidesScrollers = true
        heroDocument.translatesAutoresizingMaskIntoConstraints = false
        heroScroll.documentView = heroDocument
        heroStage.addSubview(heroScroll)
        heroStage.addSubview(heroBackButton)

        hero.setArrangement(.panel)
        checksCard.setHeader(checksHeader)
        checksRows.orientation = .vertical
        checksRows.alignment = .leading
        checksRows.spacing = 0
        checksCard.setBody(checksRows, insets: NSEdgeInsets(top: HelmMetrics.s1, left: HelmMetrics.s4,
                                                             bottom: HelmMetrics.s3, right: HelmMetrics.s4))
        heroColumn.orientation = .vertical
        heroColumn.alignment = .leading
        heroColumn.spacing = HelmMetrics.s4
        heroColumn.translatesAutoresizingMaskIntoConstraints = false
        heroColumn.addArrangedSubview(hero)
        heroColumn.addArrangedSubview(checksCard)
        heroDocument.addSubview(heroColumn)
        // Both cards span the column. A vertical stack's alignment centres a
        // view at its own fitting width otherwise, and the hero's fitting
        // width is its pills'.
        for card in [hero, checksCard] as [NSView] {
            card.widthAnchor.constraint(equalTo: heroColumn.widthAnchor).isActive = true
        }

        let inset = Self.pageInset
        let clip = heroScroll.contentView
        // Gotcha (13): the column's width preference sits under 500, so it can
        // never hold the window open; the `<=` cap and the side insets do the
        // rest.
        let preferredWidth = heroColumn.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        preferredWidth.priority = NSLayoutConstraint.Priority(480)
        let centreY = heroColumn.centerYAnchor.constraint(equalTo: heroDocument.centerYAnchor)
        centreY.priority = .defaultLow
        NSLayoutConstraint.activate([
            heroStage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            heroStage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            heroStage.topAnchor.constraint(equalTo: root.topAnchor),
            heroStage.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            backdrop.leadingAnchor.constraint(equalTo: heroStage.leadingAnchor, constant: inset),
            backdrop.trailingAnchor.constraint(equalTo: heroStage.trailingAnchor, constant: -inset),
            backdrop.topAnchor.constraint(equalTo: heroStage.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: heroStage.bottomAnchor, constant: -inset),
            backdropWash.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            backdropWash.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            backdropWash.topAnchor.constraint(equalTo: backdrop.topAnchor),
            backdropWash.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),

            heroBackButton.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: HelmMetrics.s3),
            heroBackButton.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: HelmMetrics.s3),

            heroScroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            heroScroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            heroScroll.topAnchor.constraint(equalTo: backdrop.topAnchor),
            heroScroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),

            // Gotcha (4): the document pins to the clip view, not the scroll
            // view. It is at least the clip's height, so a short column
            // centres in it, and taller when the column needs to scroll.
            heroDocument.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            heroDocument.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            heroDocument.topAnchor.constraint(equalTo: clip.topAnchor),
            heroDocument.widthAnchor.constraint(equalTo: clip.widthAnchor),
            heroDocument.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),

            heroColumn.centerXAnchor.constraint(equalTo: heroDocument.centerXAnchor),
            heroColumn.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnWidth),
            heroColumn.leadingAnchor.constraint(greaterThanOrEqualTo: heroDocument.leadingAnchor, constant: inset),
            heroColumn.trailingAnchor.constraint(lessThanOrEqualTo: heroDocument.trailingAnchor, constant: -inset),
            // Clear of the Projects button above it.
            heroColumn.topAnchor.constraint(greaterThanOrEqualTo: heroDocument.topAnchor,
                                            constant: inset + HelmMetrics.s6),
            heroDocument.bottomAnchor.constraint(greaterThanOrEqualTo: heroColumn.bottomAnchor, constant: inset),
            preferredWidth,
            centreY,
        ])
    }

    private func buildCourseStage(in root: NSView) {
        courseStage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(courseStage)
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onAction = { [weak self] action in self?.perform(action) }
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        courseStage.addSubview(strip)
        courseStage.addSubview(webContainer)
        let inset = Self.pageInset
        NSLayoutConstraint.activate([
            courseStage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            courseStage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            courseStage.topAnchor.constraint(equalTo: root.topAnchor),
            courseStage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: courseStage.leadingAnchor, constant: inset),
            strip.trailingAnchor.constraint(equalTo: courseStage.trailingAnchor, constant: -inset),
            strip.topAnchor.constraint(equalTo: courseStage.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: DevOpsHubStrip.height),
            webContainer.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: HelmMetrics.s3),
            webContainer.bottomAnchor.constraint(equalTo: courseStage.bottomAnchor, constant: -inset),
        ])
    }

    // MARK: Showing a project

    /// Show `id`. The hub calls this for a card's Open.
    func show(projectID id: String) {
        guard registry.project(id) != nil else { return }
        projectID = id
        guard isViewLoaded else { return }
        if preflightFolder[id] != registry.project(id)?.folder { preflight[id] = nil }
        render()
        refreshActivity()
    }

    /// The site's progress for `id`, for a hub that shows the site because
    /// it was asked to before its setting would have.
    func showSiteOnRequest(_ id: String) {
        shownOnRequest.insert(id)
        if isViewLoaded, id == projectID { render() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshActivity()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopUptimeTimer()
    }

    /// Read the folder and tick the uptime while this view is the one
    /// showing in a window, and neither otherwise (GL-13).
    private func refreshActivity() {
        guard isViewLoaded else { return }
        guard isActive, view.window != nil else {
            stopUptimeTimer()
            return
        }
        refreshPreflight()
        render()
        startUptimeTimer()
    }

    private func stopUptimeTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
    }

    private func startUptimeTimer() {
        uptimeTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.uptimeInterval, repeats: true) { [weak self] _ in
            self?.renderStrip()
        }
        // A minute's reading can land seconds late; the tolerance lets the
        // system batch the wake-up (audit 3.4).
        timer.tolerance = Self.uptimeInterval / 6
        uptimeTimer = timer
    }

    static let uptimeInterval: TimeInterval = 60

    /// Count the folder's files off the main thread (GL-12), for the checks
    /// card and the preview image.
    private func refreshPreflight() {
        guard let project, !preflightInFlight.contains(project.id) else { return }
        let id = project.id
        let folder = project.folder
        preflightFolder[id] = folder
        preflightInFlight.insert(id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = LocalProjectPreflight.check(folder: folder)
            var preview: NSImage?
            if case .ready = outcome { preview = Self.previewImage(in: LocalProjectPreflight.servedFolder(for: folder)) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.preflightInFlight.remove(id)
                self.preflight[id] = outcome
                if id == self.projectID { self.backdrop.image = preview }
                self.render()
            }
        }
    }

    /// The site's own share image, when it ships one, as the dimmed preview
    /// behind the hero.
    static func previewImage(in folder: URL) -> NSImage? {
        for name in ["og.jpg", "og.png", "preview.png", "preview.jpg"] {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    /// The page's own check, with the count from the last Start once it has
    /// landed (PF-02): Start counts the folder again in the background.
    private func shownPreflight(for project: LocalProject) -> LocalProjectPreflight.Outcome? {
        let checked = preflight[project.id]
        if case .ready? = checked, let count = registry.folderCount(of: project.id) {
            return .ready(files: count.files, bytes: count.bytes)
        }
        return checked
    }

    // MARK: Render

    /// What the page is in for the shown project.
    private func phase(for project: LocalProject) -> DevOpsHubWords.Phase? {
        let state = registry.state(of: project.id)
        guard case .running = state else { return .project(state) }
        if crashing.contains(project.id) { return .siteKeepsCrashing }
        guard project.opensWhenReady || shownOnRequest.contains(project.id) else { return .runningNotShown }
        if finished.contains(project.id) { return nil }
        return .loading(progress[project.id] ?? 0)
    }

    private func render() {
        guard isViewLoaded, let project else { return }
        if preflightFolder[project.id] != project.folder {
            preflight[project.id] = nil
            backdrop.image = nil
            refreshPreflight()
        }
        let state = registry.state(of: project.id)
        syncWebView(for: project, state: state)
        guard let phase = phase(for: project) else {
            words = nil
            heroStage.isHidden = true
            courseStage.isHidden = false
            renderStrip()
            return
        }
        let words = DevOpsHubWords.make(project: project, phase: phase, preflight: shownPreflight(for: project),
                                        now: registry.clock())
        self.words = words
        heroStage.isHidden = false
        courseStage.isHidden = true
        renderHero(words)
    }

    /// Load the site when its server is up, and drop it when it stops, so a
    /// stale page never sits behind a stopped server.
    private func syncWebView(for project: LocalProject, state: LocalProjectState) {
        if state.isRunning {
            // The web view is built the first time a site runs, never for a
            // project that has only been looked at.
            let web = webView(for: project.id)
            web.siteName = project.name
            let token = registry.accessToken(of: project.id)
            guard loadedOrigin[project.id] != project.origin || loadedToken[project.id] != token else { return }
            loadedOrigin[project.id] = project.origin
            loadedToken[project.id] = token
            finished.remove(project.id)
            crashing.remove(project.id)
            progress[project.id] = 0
            web.load(origin: project.origin, accessToken: token, confined: registry.confinesNetwork(of: project.id))
        } else if loadedOrigin[project.id] != nil {
            loadedOrigin[project.id] = nil
            loadedToken[project.id] = nil
            finished.remove(project.id)
            crashing.remove(project.id)
            progress[project.id] = nil
            shownOnRequest.remove(project.id)
            webViews[project.id]?.unload()
        }
    }

    private func webView(for id: String) -> DevOpsHubWebView {
        if let existing = webViews[id] {
            if existing.superview !== webContainer { install(existing) }
            return existing
        }
        let web = DevOpsHubWebView(projectID: id)
        web.onProgress = { [weak self] value in
            guard let self else { return }
            self.progress[id] = value
            if id == self.projectID, self.words?.progress != nil { self.render() }
        }
        web.onFinished = { [weak self] in
            guard let self, self.loadedOrigin[id] != nil else { return }
            self.finished.insert(id)
            if id == self.projectID { self.render() }
        }
        web.onKeepsCrashing = { [weak self] in
            guard let self, self.loadedOrigin[id] != nil else { return }
            self.crashing.insert(id)
            if id == self.projectID { self.render() }
        }
        web.applyTheme(ThemeManager.shared.theme)
        webViews[id] = web
        install(web)
        return web
    }

    /// Only the shown project's web view sits in the page.
    private func install(_ web: DevOpsHubWebView) {
        for view in webContainer.subviews where view !== web { view.removeFromSuperview() }
        guard web.superview !== webContainer else { return }
        webContainer.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            web.topAnchor.constraint(equalTo: webContainer.topAnchor),
            web.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
    }

    private func renderHero(_ words: DevOpsHubWords) {
        let ring = words.progress.map { value in
            HelmHeroColumn.Ring(fraction: value, label: "\(Int((value * 100).rounded()))%",
                                caption: "Loading the site", spoken: "Loading, \(Int((value * 100).rounded())) percent",
                                state: .ok)
        }
        let buttons = words.actions.map { action -> HelmButton in
            let button = HelmButton(title: action.title, variant: .secondary, symbol: action.symbol,
                                    target: self, action: #selector(heroButtonClicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(Self.identifier(for: action))
            return button
        }
        hero.configure(header: .init(symbol: "shippingbox.fill", kicker: words.kicker, headline: words.headline,
                                     body: words.body, ring: ring),
                       sections: [], foot: buttons, tone: heroTone(words.tone))
        checksHeader.configure(leading: .tile(symbol: "checklist", tint: checksTint(words.tone)),
                               title: words.checksTitle, subline: "In order")
        renderChecks(words.checks)
    }

    private func renderChecks(_ checks: [DevOpsHubWords.Check]) {
        for view in checksRows.arrangedSubviews {
            checksRows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        checkDetailLabels = []
        let theme = ThemeManager.shared.theme
        for (index, check) in checks.enumerated() {
            let row = DevOpsHubCheckRow(check: check, showsTopRule: index > 0)
            row.applyTheme(theme)
            checksRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: checksRows.widthAnchor).isActive = true
            checkDetailLabels.append(row.detailLabel)
        }
        view.needsLayout = true
    }

    private func renderStrip() {
        guard let project, case .running(let since) = registry.state(of: project.id) else { return }
        strip.configure(address: "\(LocalStaticServer.loopbackHost):\(project.port)",
                        line: DevOpsHubWords.runningLine(since: since, now: registry.clock(),
                                                         counters: registry.counters(of: project.id)))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Gotcha (22): a check's detail wraps at the card's own width, less
        // the row's insets and its mark, never at its own resolved width.
        let width = max(160, floor(checksCard.bounds.width - 2 * HelmMetrics.s4 - DevOpsHubCheckRow.markColumn))
        for label in checkDetailLabels where abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
        }
    }

    // MARK: Theme

    private func heroTone(_ tone: DevOpsHubWords.Tone) -> HelmModuleCard.HeroTone {
        Self.heroTone(tone, in: ThemeManager.shared.theme)
    }

    /// The hero's colour for a tone: the accent, or the theme's own amber or
    /// red. The cards view's column uses the same rule.
    static func heroTone(_ tone: DevOpsHubWords.Tone, in theme: HelmTheme) -> HelmModuleCard.HeroTone {
        switch tone {
        case .accent:
            return HelmModuleCard.HeroTone(colour: .themeAccent)
        case .amber:
            let rgb = HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[3]))
            return HelmModuleCard.HeroTone(colour: .fixed(red: rgb.0, green: rgb.1, blue: rgb.2))
        case .red:
            let rgb = HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[1]))
            return HelmModuleCard.HeroTone(colour: .fixed(red: rgb.0, green: rgb.1, blue: rgb.2))
        }
    }

    private func checksTint(_ tone: DevOpsHubWords.Tone) -> HelmTint {
        switch tone {
        case .accent: return .good
        case .amber: return .warn
        case .red: return .critical
        }
    }

    private func applyTheme(_ theme: HelmTheme) {
        guard isViewLoaded else { return }
        // ThemeManager's checklist item 2: everything that resolves a system
        // colour (the scroller, the web view's own controls) follows the
        // theme's mode, not the OS's.
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        backdrop.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        backdropWash.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex)
            .withAlphaComponent(theme.mode == .dark ? Self.darkWashAlpha : Self.washAlpha).cgColor
        checksCard.applyTheme(theme)
        checksHeader.applyTheme(theme)
        for case let row as DevOpsHubCheckRow in checksRows.arrangedSubviews { row.applyTheme(theme) }
        for web in webViews.values { web.applyTheme(theme) }
        strip.applyTheme(theme)
        // GL-24: a theme change repaints. The hero's tone is a theme colour,
        // so the words are laid out again from what is already known.
        if let words { hero.configure(header: hero.header, sections: [], foot: hero.footViews, tone: heroTone(words.tone)) }
    }

    /// How much of the page ground lies over the preview, so the hero and
    /// the checks read on it.
    static let washAlpha: CGFloat = 0.82
    /// A dark ground over a light site's preview needs more, or the preview
    /// reads as a grey slab rather than as a hint of the site.
    static let darkWashAlpha: CGFloat = 0.9

    // MARK: Actions

    @objc private func backClicked() { onBack?() }

    @objc private func heroButtonClicked(_ sender: HelmButton) {
        guard let raw = sender.identifier?.rawValue, let action = Self.action(forIdentifier: raw) else { return }
        perform(action)
    }

    static func identifier(for action: DevOpsHubWords.Action) -> String { "devopsHub.action.\(action)" }

    static func action(forIdentifier identifier: String) -> DevOpsHubWords.Action? {
        let all: [DevOpsHubWords.Action] = [.start, .cancel, .retry, .stop, .showHere, .openInBrowser, .settings,
                                            .changePort, .chooseFolder, .showInFinder, .openPrivacySettings,
                                            .copyCloneCommand, .reloadSite]
        return all.first { Self.identifier(for: $0) == identifier }
    }

    func perform(_ action: DevOpsHubWords.Action) {
        guard let project else { return }
        let id = project.id
        switch action {
        case .start, .retry:
            preflight[id] = nil
            registry.start(id)
            refreshPreflight()
        case .cancel, .stop:
            registry.stop(id)
        case .showHere:
            showSiteOnRequest(id)
        case .openInBrowser:
            WebNavigationPolicy.openExternally(project.origin, from: "DevOps Hub")
        case .settings, .changePort:
            onEditSettings?(id)
        case .chooseFolder:
            chooseFolder()
        case .showInFinder:
            Self.showInFinder(project.folder)
        case .openPrivacySettings:
            Self.openFilesAndFoldersSettings()
        case .reloadSite:
            reloadSite(id)
        case .copyCloneCommand:
            guard let command = project.cloneCommand else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            Feedback.report("Clone command copied", kind: .done, persistence: .transient, in: view)
        }
    }

    /// The strip's buttons.
    func perform(_ action: DevOpsHubStrip.Action) {
        guard let project else { return }
        switch action {
        case .back:
            onBack?()
        case .copyAddress:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.origin.absoluteString, forType: .string)
            Feedback.report("Address copied", kind: .done, persistence: .transient, in: view)
        case .reload:
            reloadSite(project.id)
        case .openInBrowser:
            WebNavigationPolicy.openExternally(project.origin, from: "DevOps Hub")
        case .restart:
            registry.restart(project.id)
        case .stop:
            registry.stop(project.id)
        }
    }

    /// Reload the site (⌘R on the page).
    func reloadSite() {
        guard let project, registry.state(of: project.id).isRunning else { return }
        reloadSite(project.id)
    }

    /// Every Reload: the strip's, ⌘R and the crash state's. After a crash
    /// the page shows the load's progress again rather than a blank site.
    private func reloadSite(_ id: String) {
        let wasCrashing = crashing.remove(id) != nil
        if wasCrashing {
            finished.remove(id)
            progress[id] = 0
        }
        webViews[id]?.reload()
        if wasCrashing, id == projectID { render() }
    }

    /// The folder in Finder, or the nearest folder above it that exists.
    static func showInFinder(_ folder: URL) {
        guard !ExternalToolGuard.isActive else { return }
        var target = folder
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target.deleteLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Opens the exact pane a refused folder needs, a fixed System Settings
    /// URL rather than anything from data.
    static func openFilesAndFoldersSettings() {
        guard !ExternalToolGuard.isActive,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func chooseFolder() {
        guard let project, let window = view.window else { return }
        Self.chooseFolder(for: project, registry: registry, in: window)
    }

    /// Choose Folder: a folder panel over `window`, and the project's folder
    /// set to the choice. The hub's cards run the same one.
    static func chooseFolder(for project: LocalProject, registry: LocalProjectRegistry, in window: NSWindow) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds \(project.name)\u{2019}s index.html."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, var edited = registry.project(project.id) else { return }
            edited.folderOverride = LocalProject.abbreviate(url.path)
            // The view re-reads the folder on its next render, because the
            // folder it last read is no longer the project's.
            registry.update(edited)
        }
    }

    #if FM_SELFTESTS
    var debugShowsSite: Bool { isViewLoaded && !courseStage.isHidden && heroStage.isHidden }
    var debugHero: HelmHeroColumn { hero }
    var debugStrip: DevOpsHubStrip { strip }
    var debugCheckTitles: [String] {
        checksRows.arrangedSubviews.compactMap { ($0 as? DevOpsHubCheckRow)?.titleLabel.stringValue }
    }
    var debugHeroButtons: [HelmButton] { hero.debugFootButtons }
    var debugHeroBackButton: HelmButton { heroBackButton }
    var debugWebView: DevOpsHubWebView? { projectID.flatMap { webViews[$0] } }
    var debugBackdrop: NSImageView { backdrop }
    /// The web view finished its first load, as `didFinish` reports it.
    func debugFinishLoad() {
        guard let id = projectID else { return }
        webViews[id]?.onFinished?()
    }
    /// Draw the hero for `phase` whatever the registry says - for the
    /// render gallery's states that a real run passes through too fast to
    /// capture (starting, loading). Assertions never use it.
    func debugShowHero(phase: DevOpsHubWords.Phase) {
        guard let project else { return }
        let words = DevOpsHubWords.make(project: project, phase: phase, preflight: shownPreflight(for: project),
                                        now: registry.clock())
        self.words = words
        heroStage.isHidden = false
        courseStage.isHidden = true
        renderHero(words)
        view.layoutSubtreeIfNeeded()
    }
    func debugSetPreflight(_ outcome: LocalProjectPreflight.Outcome) {
        guard let id = projectID else { return }
        preflight[id] = outcome
        render()
    }
    #endif
}

// MARK: - The strip

/// The hero as a 44pt strip over a running site: a Projects button back to
/// the cards, a state dot, "Running", the address as a copy button, the
/// uptime and files served, and the four actions as the kit's ghost pills.
///
/// Narrower than `compactWidth`, Reload, Open in Browser and Restart keep
/// only their glyphs (their words move to the tooltip), so Projects and Stop
/// keep theirs at the shell's narrowest window. The quiet line gives way
/// first either way.
final class DevOpsHubStrip: NSView {

    enum Action: Equatable { case back, copyAddress, reload, openInBrowser, restart, stop }

    static let compactWidth: CGFloat = 820
    static let yieldingResistance = NSLayoutConstraint.Priority(490)

    var onAction: ((Action) -> Void)?

    static let height: CGFloat = 44
    static let cornerRadius: CGFloat = 12
    static let dotSide: CGFloat = 8

    private let surface = HelmHeroSurface()
    private let backButton = HelmButton(title: "Projects", variant: .secondary, size: .small, symbol: "chevron.left")
    private let dot = NSView()
    private let stateLabel = NSTextField(labelWithString: "Running")
    private let addressButton = HelmButton(title: "", variant: .secondary, size: .small, symbol: "doc.on.doc")
    private let lineLabel = NSTextField(labelWithString: "")
    private let reloadButton = HelmButton(title: "Reload", variant: .secondary, size: .small, symbol: "arrow.clockwise")
    private let browserButton = HelmButton(title: "Open in Browser", variant: .secondary, size: .small, symbol: "safari")
    private let restartButton = HelmButton(title: "Restart", variant: .secondary, size: .small,
                                           symbol: "arrow.counterclockwise")
    private let stopButton = HelmButton(title: "Stop", variant: .secondary, size: .small, symbol: "stop.fill")
    private var themeToken: ThemeObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Site controls")

        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: HelmType.scaled(13), weight: .bold)
        lineLabel.font = HelmType.caption()
        lineLabel.lineBreakMode = .byTruncatingTail
        addressButton.toolTip = "Copy the address"
        backButton.toolTip = "Back to the projects"
        let pairs: [(HelmButton, Action)] = [(backButton, .back), (addressButton, .copyAddress), (reloadButton, .reload),
                                             (browserButton, .openInBrowser), (restartButton, .restart),
                                             (stopButton, .stop)]
        for (button, action) in pairs {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier("devopsHub.strip.\(action)")
        }
        let leading = NSStackView(views: [backButton, dot, stateLabel, addressButton, lineLabel])
        leading.orientation = .horizontal
        leading.alignment = .centerY
        leading.spacing = HelmMetrics.s2
        leading.setCustomSpacing(HelmMetrics.s1 + 2, after: dot)
        leading.setCustomSpacing(HelmMetrics.s3, after: backButton)
        let trailing = NSStackView(views: [reloadButton, browserButton, restartButton, stopButton])
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = HelmMetrics.s1 + 2
        // Gotcha (5) and (10): only the quiet line gives way.
        for view in [backButton, dot, stateLabel, addressButton, reloadButton, browserButton, restartButton, stopButton] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        lineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lineLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Gotcha (13): the three buttons that drop their words when narrow
        // resist below the window's own hold (500), so a narrow window
        // squeezes them into their compact form rather than the strip
        // holding the window open at its full width.
        for button in [reloadButton, browserButton, restartButton] {
            button.setContentCompressionResistancePriority(Self.yieldingResistance, for: .horizontal)
        }
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s3
        row.translatesAutoresizingMaskIntoConstraints = false
        leading.setHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setClippingResistancePriority(.required, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    func configure(address: String, line: String) {
        addressButton.title = address
        addressButton.setAccessibilityLabel("Copy the address, \(address)")
        lineLabel.stringValue = line
    }

    /// The three buttons that drop their words when the strip is narrow,
    /// with the words they have when it is not.
    private var compactable: [(HelmButton, String)] {
        [(reloadButton, "Reload"), (browserButton, "Open in Browser"), (restartButton, "Restart")]
    }
    private(set) var isCompact = false

    override func layout() {
        super.layout()
        let compact = bounds.width > 0 && bounds.width < Self.compactWidth
        guard compact != isCompact else { return }
        isCompact = compact
        for (button, title) in compactable {
            button.title = compact ? "" : title
            button.toolTip = compact ? title : nil
            button.setAccessibilityLabel(title)
        }
        needsLayout = true
    }

    @objc private func buttonClicked(_ sender: HelmButton) {
        let all: [Action] = [.back, .copyAddress, .reload, .openInBrowser, .restart, .stop]
        guard let action = all.first(where: { sender.identifier?.rawValue == "devopsHub.strip.\($0)" }) else { return }
        onAction?(action)
    }

    func applyTheme(_ theme: HelmTheme) {
        let palette = HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: theme)
        surface.apply(palette)
        let ink = HelmContrast.color(palette.ink)
        appearance = HelmHeroColumn.NavInk(palette: palette).appearance
        stateLabel.textColor = ink
        lineLabel.textColor = ink.withAlphaComponent(HelmHeroColumn.quietInkAlpha)
        dot.layer?.backgroundColor = HelmHeroSurface.signalColor(tintHex: HelmTint.good.hex(in: theme), on: palette).cgColor
        for button in [backButton, addressButton, reloadButton, browserButton, restartButton, stopButton] {
            button.heroInk = ink
        }
    }

    #if FM_SELFTESTS
    var debugAddress: String { addressButton.title }
    var debugLine: String { lineLabel.stringValue }
    func debugButton(_ action: Action) -> HelmButton {
        switch action {
        case .back: return backButton
        case .copyAddress: return addressButton
        case .reload: return reloadButton
        case .openInBrowser: return browserButton
        case .restart: return restartButton
        case .stop: return stopButton
        }
    }
    #endif
}

// MARK: - A check

/// One line of the checks card: a mark, a title, and a detail under it.
final class DevOpsHubCheckRow: NSView {

    static let markColumn: CGFloat = 30

    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let markView = NSImageView()
    private let rule = NSView()
    private let check: DevOpsHubWords.Check

    init(check: DevOpsHubWords.Check, showsTopRule: Bool) {
        self.check = check
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = check.title
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.stringValue = check.detail
        detailLabel.isSelectable = check.detailIsCode
        detailLabel.font = check.detailIsCode
            ? .monospacedSystemFont(ofSize: HelmType.scaled(11.5), weight: .regular) : HelmType.caption()
        markView.translatesAutoresizingMaskIntoConstraints = false
        markView.image = HelmSymbol.image(Self.symbol(for: check.mark), pointSize: HelmType.scaled(15), weight: .semibold)
        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.isHidden = !showsTopRule
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        for view in [rule, markView, text] { addSubview(view) }
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            markView.leadingAnchor.constraint(equalTo: leadingAnchor),
            markView.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2 + 1),
            markView.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.markColumn),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s2),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func symbol(for mark: DevOpsHubWords.Check.Mark) -> String {
        switch mark {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .attention: return "questionmark.circle.fill"
        case .pending: return "circle"
        case .working: return "circle.dotted"
        case .info: return "info.circle"
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        rule.layer?.backgroundColor = HelmFlatList.hairRowColor(theme).cgColor
        let tint: HelmTint
        switch check.mark {
        case .done: tint = .good
        case .failed: tint = .critical
        case .attention: tint = .warn
        // The step in flight takes the accent, so it reads as the live one.
        case .working: tint = .accent
        case .pending, .info: tint = .neutral
        }
        markView.contentTintColor = tint == .neutral ? HelmTheme.mutedInk(theme)
            : HelmContrast.legibleOn(fill: HelmTheme.nsColor(theme.chromeBackgroundHex),
                                     preferring: HelmTheme.nsColor(tint.hex(in: theme)),
                                     target: HelmContrast.nonTextTarget)
    }
}
