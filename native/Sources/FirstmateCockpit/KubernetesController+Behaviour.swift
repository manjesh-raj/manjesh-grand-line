// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-cluster-tail`: `KubernetesController`'s behaviour half -
// scope/feed selection, the two poll loops, and rendering. Split from the
// view-building half for the same reason `ConsoleController` is six files
// (GL-36): one page owning a scope strip, a feed picker, two poll loops and
// five tables is past the size where one file is readable.
//
// Note the Swift consequence, exactly as that split records: `private` is
// file-scoped, so every member reached across this boundary is `internal`.
// Treat the whole `KubernetesController*.swift` family as private to itself.

import AppKit

extension KubernetesController {

    // MARK: - Deep link (Shape C)

    /// The host page's own "Tail Logs" toolbar button lands here, pre-scoped -
    /// the report's hybrid: both entry points, one implementation. The same
    /// idiom Overview's ready-to-merge tile already uses to reach Review.
    func openScoped(hostID: UUID, showTail: Bool) {
        // Force the mount. `loadViewIfNeeded()` is macOS 14+, and this app's
        // deployment target is lower; touching `view` is what every other
        // caller in this codebase uses to the same effect.
        _ = view
        if scopeHostID != hostID { selectScope(hostID) }
        if showTail {
            pageTab = .logTail
            pageTabs.select(PageTab.logTail.rawValue)
        }
        restartTimers()
        render()
    }

    // MARK: - Scope

    func sessionsChanged() {
        guard isViewLoaded else { return }
        // A scope whose session ended is dropped rather than left selected -
        // a strip pill for a host with no session would offer a feed that can
        // never work.
        if let scopeHostID, !sessions.isLive(scopeHostID) {
            teardownFeed()
            self.scopeHostID = nil
        }
        if scopeHostID == nil, let first = sessions.sessions.first { selectScope(first.hostID) }
        rebuildScopeTabs()
        render()
    }

    private func rebuildScopeTabs() {
        // Rebuilt rather than mutated: `HelmSegmentedTabs` fixes its pills at
        // `init` (its own documented contract), and the live set is small and
        // changes only when a session opens or closes.
        scopeTabs?.removeFromSuperview()
        scopeTabs = nil
        guard !sessions.isEmpty else { return }
        let tabs = HelmSegmentedTabs(
            items: sessions.sessions.map { .init(id: $0.hostID.uuidString, title: $0.label) },
            selected: scopeHostID?.uuidString,
            size: .compact)
        tabs.onSelect = { [weak self] id in
            guard let self, let uuid = UUID(uuidString: id) else { return }
            self.selectScope(uuid)
            self.render()
        }
        tabs.applyTheme(theme)
        scopeTabsHost.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: scopeTabsHost.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: scopeTabsHost.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: scopeTabsHost.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: scopeTabsHost.bottomAnchor),
        ])
        scopeTabs = tabs
    }

    func selectScope(_ hostID: UUID) {
        guard scopeHostID != hostID else { return }
        teardownFeed()
        scopeHostID = hostID
        clearClusterState()
        merger.clear()
        selectedPods.removeAll()
        // Auto-adopt a feed tab only when the host has exactly one tab: with
        // one there is no ambiguity, and with several the captain's working
        // tab must never be commandeered silently. That is the whole reason
        // this page has a visible picker at all.
        let tabs = access.tabs(hostID)
        if tabs.count == 1 { adoptFeedTab(tabs[0]) }
        onDrillSubtitleChanged?()
    }

    // MARK: - Feed tab

    func adoptFeedTab(_ tab: KubeFeedTab) {
        guard let hostID = scopeHostID else { return }
        teardownFeed()
        feedTabID = tab.id
        feedTabName = tab.name
        let newBridge = KubeBridge(target: tab.terminal)
        newBridge.isTerminalBusyElsewhere = { [access, hostID, tabID = tab.id] in
            access.isTabBusyElsewhere(hostID, tabID)
        }
        newBridge.onStateChanged = { [weak self] in
            self?.renderFeedStatus()
            self?.onDrillSubtitleChanged?()
        }
        newBridge.start()
        bridge = newBridge
        restartTimers()
        onDrillSubtitleChanged?()
        if pageTab == .cluster { refreshCluster() }
    }

    func teardownFeed() {
        bridge?.stop()
        bridge = nil
        feedTabID = nil
        feedTabName = nil
        clusterTimer?.invalidate(); clusterTimer = nil
        tailTimer?.invalidate(); tailTimer = nil
    }

    @objc func feedTabPicked() {
        guard let hostID = scopeHostID else { return }
        let tabs = access.tabs(hostID)
        let index = feedTabPicker.indexOfSelectedItem
        guard index >= 0, index < tabs.count else { return }
        guard tabs[index].id != feedTabID else { return }
        adoptFeedTab(tabs[index])
        render()
    }

    @objc func duplicateFeedTapped() {
        guard let hostID = scopeHostID else { return }
        guard let tab = access.duplicateTabForFeed(hostID) else {
            feedStatusLabel.stringValue = "That host has no open tab to duplicate. Open its page and connect first."
            return
        }
        adoptFeedTab(tab)
        render()
        Toast.show(in: view, message: "Duplicated \u{201C}\(tab.name)\u{201D} - log in on that tab once, then it runs hands-free.")
    }

    @objc func revealHostTapped() {
        guard let hostID = scopeHostID else { return }
        access.revealHost(hostID)
    }

    @objc func openHostsTapped() { access.openHosts() }

    @objc func retryFeedTapped() {
        bridge?.resume()
        restartTimers()
        if pageTab == .cluster { refreshCluster() }
        render()
    }

    // MARK: - Timers

    func restartTimers() {
        clusterTimer?.invalidate(); clusterTimer = nil
        tailTimer?.invalidate(); tailTimer = nil
        guard isViewLoaded, !view.isHidden, bridge != nil else { return }
        switch pageTab {
        case .cluster:
            let t = Timer.scheduledTimer(withTimeInterval: Self.clusterPollInterval, repeats: true) { [weak self] _ in
                self?.refreshCluster()
            }
            RunLoop.main.add(t, forMode: .common)
            clusterTimer = t
        case .logTail:
            let t = Timer.scheduledTimer(withTimeInterval: KubeLogTailSession.pollInterval, repeats: true) { [weak self] _ in
                self?.pollTail()
            }
            RunLoop.main.add(t, forMode: .common)
            tailTimer = t
            pollTail()
        }
    }

    // MARK: - Cluster

    func clearClusterState() {
        pods = []; deployments = []; services = []; events = []
        clusterMessage = nil
        lastRefreshedAt = nil
    }

    @objc func refreshTapped() {
        switch pageTab {
        case .cluster: refreshCluster()
        case .logTail: pollTail()
        }
    }

    @objc func namespaceCommitted() {
        let candidate = namespaceField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else {
            namespaceField.stringValue = namespace
            return
        }
        guard KubeCommand.isSafeToken(candidate) else {
            // Refused rather than silently corrected: a namespace this app
            // will not type is a namespace the captain must see rejected.
            namespaceField.stringValue = namespace
            clusterMessage = "\u{201C}\(candidate)\u{201D} isn't a namespace name this app will type into a shell."
            renderClusterTable()
            return
        }
        guard candidate != namespace else { return }
        namespace = candidate
        clearClusterState()
        merger.clear()
        selectedPods.removeAll()
        onDrillSubtitleChanged?()
        render()
        refreshCluster()
    }

    /// The discovery sweep. Serialized by `KubeBridge`'s own queue - one
    /// command in the tab at a time, which is the bridge's hard constraint,
    /// not a preference.
    ///
    /// The set is per visible tab (the mockup's own "each costs one more get,
    /// run only when that tab is opened"): Pods always, because the Log
    /// Tail's own picker is fed from it too, plus whichever other table is on
    /// screen.
    func refreshCluster() {
        guard let bridge, !isRefreshingCluster else { return }
        guard !bridge.hasStoppedRetrying else { return }
        isRefreshingCluster = true
        var commands: [KubeCommand] = [.getPods(namespace: namespace), .topPods(namespace: namespace)]
        switch clusterTab {
        case .pods: break
        case .deployments: commands.append(.getDeployments(namespace: namespace))
        case .services: commands.append(.getServices(namespace: namespace))
        case .events: commands.append(.getEvents(namespace: namespace))
        }
        renderClusterStatus(running: true)
        bridge.enqueueBatch(commands) { [weak self] results in
            guard let self else { return }
            self.isRefreshingCluster = false
            self.applySweep(results)
        }
    }

    private func applySweep(_ results: [(KubeCommand, Result<String, KubeBridgeError>)]) {
        var podsRaw: String?
        var topRaw: String?
        var hardFailure: String?
        for (command, result) in results {
            switch (command, result) {
            case (.getPods, .success(let raw)): podsRaw = raw
            // `top` legitimately fails on a cluster with no metrics-server -
            // that must degrade to "no cpu/mem columns", never to a failed
            // refresh, which is why its failure is swallowed here.
            case (.topPods, .success(let raw)): topRaw = raw
            case (.topPods, .failure): break
            case (.getDeployments, .success(let raw)): apply(KubeResourceParser.parseDeployments(raw), to: &deployments)
            case (.getServices, .success(let raw)): apply(KubeResourceParser.parseServices(raw), to: &services)
            case (.getEvents, .success(let raw)): apply(KubeResourceParser.parseEvents(raw), to: &events)
            case (_, .failure(let error)): hardFailure = hardFailure ?? error.message
            default: break
            }
        }
        if let podsRaw {
            switch KubeResourceParser.parsePods(getRaw: podsRaw, topRaw: topRaw) {
            case .rows(let rows):
                pods = rows
                clusterMessage = nil
                lastRefreshedAt = Date()
                pruneSelectedPods()
            case .empty:
                pods = []
                // GL-14's rule: an empty namespace and a failed fetch must not
                // render the same, so this says which one it is.
                clusterMessage = "No pods in \(namespace)."
                lastRefreshedAt = Date()
            case .failed(let message):
                clusterMessage = message
            }
        } else if let hardFailure {
            clusterMessage = hardFailure
        }
        renderClusterTable()
        renderPodPicker()
        renderFeedStatus()
        onDrillSubtitleChanged?()
    }

    private func apply<T>(_ outcome: KubeResourceParser.Outcome<T>, to store: inout [T]) {
        switch outcome {
        case .rows(let rows): store = rows
        case .empty: store = []
        // A failure leaves the previous rows alone: a stale table with a
        // visible "last refreshed" age is more useful than a blank one, and
        // the failure itself is reported on the status line.
        case .failed(let message): clusterMessage = clusterMessage ?? message
        }
    }

    func describePod(_ name: String) {
        guard let bridge else { return }
        describeDrawer.isHidden = false
        describeTitleLabel.stringValue = "describe pod \(name)"
        describeTextView.string = "Running kubectl describe\u{2026}"
        applyDescribeTheme()
        bridge.enqueue(.describePod(name: name, namespace: namespace)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let raw): self.describeTextView.string = raw.isEmpty ? "kubectl returned nothing." : raw
            case .failure(let error): self.describeTextView.string = "Couldn't describe \(name): \(error.message)"
            }
            self.applyDescribeTheme()
        }
    }

    @objc func closeDescribeTapped() { hideDescribeDrawer() }

    func hideDescribeDrawer() {
        describeDrawer.isHidden = true
        clusterTable.clearSelection()
    }

    // MARK: - Log tail

    func pruneSelectedPods() {
        let names = Set(pods.map(\.name))
        selectedPods.removeAll { !names.contains($0) }
    }

    @objc func togglePodSelection(_ sender: NSButton) {
        let name = sender.title
        if let index = selectedPods.firstIndex(of: name) {
            selectedPods.remove(at: index)
        } else {
            guard selectedPods.count < KubeLogTailSession.maxSelectedPods else {
                // Refused with a reason rather than silently ignored - see
                // `KubeLogTailSession.maxSelectedPods` for why there is a cap
                // at all.
                sender.state = .off
                tailStatus = "At most \(KubeLogTailSession.maxSelectedPods) pods at once - each one costs its own command every \(Int(KubeLogTailSession.pollInterval))s."
                renderTailStatus()
                return
            }
            selectedPods.append(name)
            merger.registerPod(name)
        }
        tailStatus = nil
        renderTailStatus()
        onDrillSubtitleChanged?()
        if !selectedPods.isEmpty, !isTailPaused { pollTail() }
    }

    @objc func togglePauseTapped() {
        isTailPaused.toggle()
        pauseButton.title = isTailPaused ? "Resume" : "Pause"
        pauseButton.variant = isTailPaused ? .primary : .secondary
        renderTailStatus()
        onDrillSubtitleChanged?()
        if !isTailPaused { pollTail() }
    }

    @objc func toggleErrorsOnlyTapped() {
        errorsOnly.toggle()
        errorsOnlyButton.variant = errorsOnly ? .primary : .secondary
        renderLogLines(follow: true)
    }

    @objc func clearTailTapped() {
        merger.clear()
        renderLogLines(follow: true)
    }

    /// One bounded command per selected pod, serialized by the bridge.
    func pollTail() {
        guard let bridge, !isTailPaused, !selectedPods.isEmpty else { return }
        guard !bridge.hasStoppedRetrying else { return }
        // Never stack a cycle on top of one still draining: at 5s with six
        // pods a slow cluster can legitimately overrun, and queueing a second
        // full cycle would compound rather than catch up.
        guard bridge.queueDepth == 0 else { return }
        let commands = selectedPods.map {
            KubeCommand.podLogs(pod: $0, namespace: namespace, sinceSeconds: KubeLogTailSession.sinceSeconds)
        }
        // Whether to auto-scroll is decided *before* the results land, off
        // where the captain is parked right now - appending must never yank
        // the view away from a line being read.
        let shouldFollow = logList.isScrolledToBottom
        bridge.enqueueBatch(commands) { [weak self] results in
            guard let self else { return }
            var failures: [String] = []
            for (command, result) in results {
                guard case .podLogs(let pod, _, _) = command else { continue }
                switch result {
                case .success(let raw): self.merger.append(KubeLogParser.parseBlock(raw, pod: pod))
                case .failure(let error): failures.append("\(pod): \(error.message)")
                }
            }
            self.tailStatus = failures.isEmpty ? nil : failures.joined(separator: " \u{00B7} ")
            self.renderLogLines(follow: shouldFollow)
            self.renderTailStatus()
            self.renderFeedStatus()
        }
    }
}
