// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-k8s-cluster-tail`: `KubernetesController`'s rendering half.
// See `KubernetesController.swift`'s header for the page's design and
// `+Behaviour.swift`'s for the split.

import AppKit

extension KubernetesController {

    // MARK: - Whole page

    func render() {
        guard isViewLoaded else { return }
        let hasSession = !sessions.isEmpty
        scopeTabsHost.isHidden = !hasSession
        scopeEmptyState.isHidden = hasSession

        let hasScope = hasSession && scopeHostID != nil
        feedSection.isHidden = !hasScope
        let ready = hasScope && feedTabID != nil
        workArea.isHidden = !ready

        clusterContainer.isHidden = !(ready && pageTab == .cluster)
        tailContainer.isHidden = !(ready && pageTab == .logTail)

        renderFeedPicker()
        renderFeedStatus()
        renderClusterTable()
        renderPodPicker()
        renderLogLines(follow: true)
        renderTailStatus()
        onDrillSubtitleChanged?()
    }

    // MARK: - Feed card

    func renderFeedPicker() {
        guard let hostID = scopeHostID else { return }
        let tabs = access.tabs(hostID)
        feedTabPicker.removeAllItems()
        if tabs.isEmpty {
            feedTabPicker.addItem(withTitle: "No open tabs")
            feedTabPicker.isEnabled = false
        } else {
            for tab in tabs { feedTabPicker.addItem(withTitle: tab.name) }
            feedTabPicker.isEnabled = true
            if let feedTabID, let index = tabs.firstIndex(where: { $0.id == feedTabID }) {
                feedTabPicker.selectItem(at: index)
            }
        }
    }

    func renderFeedStatus() {
        guard isViewLoaded, let hostID = scopeHostID,
              let session = sessions.session(for: hostID) else { return }
        guard feedTabID != nil, let bridge else {
            retryFeedButton.isHidden = true
            feedStatusLabel.stringValue =
                "Pick a tab on \(session.label) for this page to type into, or duplicate one. "
                + "It must be logged all the way in to the box that has kubectl - that hop is password-gated by policy, so it is one manual login per session, then hands-free. "
                + "Your other tabs are never touched."
            return
        }
        let name = feedTabName ?? "a tab"
        retryFeedButton.isHidden = !bridge.hasStoppedRetrying
        if bridge.hasStoppedRetrying {
            feedStatusLabel.stringValue =
                "kubectl kept failing in \u{201C}\(name)\u{201D} - \(bridge.lastFailureMessage ?? "no detail") - so this page stopped retrying. "
                + "That usually means the tab hasn't reached the box with kubectl on it yet. Log in there, then try again."
            return
        }
        var parts = ["Feeding from \u{201C}\(name)\u{201D}."]
        if let running = bridge.inFlightLabel {
            parts.append("Running \(running)\u{2026}")
        } else if let waiting = pendingWaitText() {
            // The distinction this task adds: contention (a sibling bridge,
            // or the captain typing in this exact tab) is not the same as
            // "kubectl is slow", and must not render identically to it.
            parts.append("\(waiting).")
        }
        if bridge.queueDepth > 0 { parts.append("\(bridge.queueDepth) queued.") }
        parts.append("Every command it runs is visible in that tab.")
        feedStatusLabel.stringValue = parts.joined(separator: " ")
    }

    /// The honest "why hasn't this run yet" line for whichever reason the
    /// bridge is currently blocked on - `nil` when it's genuinely running (or
    /// nothing is queued), in which case the caller falls back to its own
    /// "Running…"/"Refreshing…" text.
    ///
    /// `fm/grandline-k8s-feed-tab-stall-fix`: a request stuck behind recent
    /// feed-tab activity or a sibling bridge used to render identically to
    /// one genuinely in flight - a plain "Refreshing…" spinner that never
    /// told the captain their own typing in the feed tab was what was
    /// pausing it.
    func pendingWaitText() -> String? {
        guard let bridge, let reason = bridge.pendingReason else { return nil }
        guard let since = bridge.pendingSince else { return reason.statusText }
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        return "\(reason.statusText) (\(seconds)s so far)"
    }

    // MARK: - Cluster tables

    func renderClusterStatus(running: Bool) {
        guard isViewLoaded else { return }
        if running {
            // `pendingWaitText()` is non-nil exactly when the sweep hasn't
            // actually been issued yet (contention), so this distinguishes
            // that from genuinely running - `fm/grandline-k8s-feed-tab-stall-fix`.
            clusterStatusLabel.stringValue = pendingWaitText() ?? "Refreshing\u{2026}"
            clusterRetryButton.isHidden = true
            return
        }
        // `fm/grandline-k8s-refresh-stuck-audit`'s hard safety net: a forced
        // reset gets its own clear, unambiguous state and a real retry action
        // - never folded in among the ordinary "refreshed Ns ago" status line,
        // which would read as merely stale rather than as something that
        // needs a click.
        if clusterRefreshStuck {
            clusterStatusLabel.stringValue = clusterMessage ?? "Something went wrong - no response."
            clusterRetryButton.isHidden = false
            return
        }
        clusterRetryButton.isHidden = true
        var parts: [String] = []
        if let lastRefreshedAt {
            // `durationText` already reads as a phrase ("just now", "2m"), so
            // only the elapsed form takes an "ago".
            let elapsed = HostSession.durationText(since: lastRefreshedAt)
            parts.append(elapsed.first?.isNumber == true ? "refreshed \(elapsed) ago" : "refreshed \(elapsed)")
        }
        parts.append("polls every \(Int(Self.clusterPollInterval))s while open")
        if let clusterMessage { parts.insert(clusterMessage, at: 0) }
        clusterStatusLabel.stringValue = parts.joined(separator: " \u{00B7} ")
    }

    func renderClusterTable() {
        guard isViewLoaded else { return }
        renderClusterStatus(running: isRefreshingCluster)
        switch clusterTab {
        case .pods:
            let showsMetrics = pods.contains { $0.cpu != nil }
            var columns: [KubeResourceTableView.Column] = [
                .init("NAME", showsMetrics ? 0.36 : 0.44, monospaced: true),
                .init("READY", 0.09),
                .init("STATUS", 0.16),
                .init("RESTARTS", 0.11),
                .init("AGE", 0.10),
            ]
            if showsMetrics {
                columns.append(.init("CPU", 0.09, monospaced: true))
                columns.append(.init("MEM", 0.09, monospaced: true))
            } else {
                columns.append(.init("NODE", 0.21, monospaced: true))
            }
            let rows = pods.map { pod -> KubeResourceTableView.Row in
                var values = [pod.name, pod.ready, pod.status, "\(pod.restarts)", pod.age]
                if showsMetrics {
                    values.append(pod.cpu ?? "-")
                    values.append(pod.memory ?? "-")
                } else {
                    values.append(pod.node ?? "-")
                }
                let tint: HelmTint?
                switch pod.health {
                case .healthy: tint = nil
                case .warning: tint = .warn
                case .bad: tint = .critical
                }
                return .init(values: values, tint: tint, key: pod.name)
            }
            clusterTable.onSelectRow = { [weak self] key in self?.describePod(key) }
            clusterTable.setContent(columns: columns, rows: rows, theme: theme)
        case .deployments:
            let columns: [KubeResourceTableView.Column] = [
                .init("NAME", 0.46, monospaced: true), .init("READY", 0.14),
                .init("UP-TO-DATE", 0.16), .init("AVAILABLE", 0.14), .init("AGE", 0.10),
            ]
            clusterTable.onSelectRow = nil
            clusterTable.setContent(columns: columns, rows: deployments.map {
                .init(values: [$0.name, $0.ready, $0.upToDate, $0.available, $0.age],
                      tint: $0.isFullyReady ? nil : .warn, key: $0.name)
            }, theme: theme)
        case .services:
            let columns: [KubeResourceTableView.Column] = [
                .init("NAME", 0.32, monospaced: true), .init("TYPE", 0.15),
                .init("CLUSTER-IP", 0.18, monospaced: true), .init("EXTERNAL-IP", 0.15, monospaced: true),
                .init("PORT(S)", 0.20, monospaced: true),
            ]
            clusterTable.onSelectRow = nil
            clusterTable.setContent(columns: columns, rows: services.map {
                .init(values: [$0.name, $0.type, $0.clusterIP, $0.externalIP ?? "-", $0.ports], key: $0.name)
            }, theme: theme)
        case .events:
            let columns: [KubeResourceTableView.Column] = [
                .init("LAST SEEN", 0.12), .init("TYPE", 0.10), .init("REASON", 0.16),
                .init("OBJECT", 0.24, monospaced: true), .init("MESSAGE", 0.38),
            ]
            clusterTable.onSelectRow = nil
            clusterTable.setContent(columns: columns, rows: events.map {
                .init(values: [$0.lastSeen, $0.type, $0.reason, $0.object, $0.message],
                      tint: $0.isWarning ? .warn : nil, key: $0.object)
            }, theme: theme)
        }
    }

    // MARK: - Log tail

    /// Rebuilds the Log Tail's pod checkbox column.
    ///
    /// **Guarded on real change** (`fm/grandline-k8s-ui-revamp`, bug 4). This
    /// tears down and recreates one `NSButton` per pod plus a width
    /// constraint each, and it used to run on *every* completed sweep - so a
    /// 40-pod namespace destroyed and rebuilt 40 views every 30 seconds,
    /// forever, whether or not a single pod had changed and whether or not
    /// the Log Tail page was even visible. `renderSignature` is the cheap
    /// "would this produce the same views?" key: pod names, their selected
    /// state, and the theme.
    func renderPodPicker(force: Bool = false) {
        guard isViewLoaded else { return }
        let signature = podPickerSignature()
        guard force || signature != lastPodPickerSignature else { return }
        lastPodPickerSignature = signature
        for existing in podPickerStack.arrangedSubviews {
            podPickerStack.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }
        let heading = NSTextField(labelWithString: pods.isEmpty ? "No pods discovered" : "Pods in \(namespace)")
        heading.font = HelmType.kicker()
        heading.textColor = HelmTheme.mutedInk(theme)
        podPickerStack.addArrangedSubview(heading)

        for pod in pods {
            let checkbox = NSButton(checkboxWithTitle: pod.name, target: self,
                                    action: #selector(togglePodSelection(_:)))
            checkbox.state = selectedPods.contains(pod.name) ? .on : .off
            checkbox.font = HelmType.body()
            checkbox.toolTip = "\(pod.name) \u{00B7} \(pod.status)"
            checkbox.lineBreakMode = .byTruncatingMiddle
            // A pod name is long and this column is 230pt: without this, the
            // checkbox's own intrinsic width becomes a floor on the whole
            // window (gotcha (13), which has shipped four times here).
            checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if selectedPods.contains(pod.name) {
                checkbox.contentTintColor = HelmContrast.legibleTintedText(
                    tintHex: merger.tint(for: pod.name).hex(in: theme),
                    over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
            }
            podPickerStack.addArrangedSubview(checkbox)
            checkbox.widthAnchor.constraint(equalTo: podPickerStack.widthAnchor).isActive = true
        }
        if pods.isEmpty {
            let hint = NSTextField(wrappingLabelWithString:
                "Open the Cluster tab (or hit Refresh) to discover pods - the picker is built from a real `get pods`, never a hardcoded list.")
            hint.font = HelmType.caption()
            hint.textColor = HelmTheme.mutedInk(theme)
            hint.preferredMaxLayoutWidth = 200
            podPickerStack.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: podPickerStack.widthAnchor).isActive = true
        }
    }

    /// Everything the picker's own views are derived from. Deliberately not
    /// a hash of the whole `KubePod` - a pod's AGE or CPU changes on every
    /// poll and none of it reaches this column.
    private func podPickerSignature() -> String {
        pods.map { "\($0.name)|\(selectedPods.contains($0.name) ? 1 : 0)" }.joined(separator: ",")
            + "#\(namespace)#\(theme.id)"
    }

    func renderLogLines(follow: Bool) {
        guard isViewLoaded else { return }
        logList.setLines(merger.visibleLines(errorsOnly: errorsOnly),
                         tintForPod: { [merger] pod in merger.tint(for: pod) },
                         theme: theme, follow: follow)
    }

    func renderTailStatus() {
        guard isViewLoaded else { return }
        var parts: [String] = []
        if let tailStatus { parts.append(tailStatus) }
        if selectedPods.isEmpty {
            parts.append("Tick a pod on the left to start tailing.")
        } else if isTailPaused {
            parts.append("Paused - nothing is being typed into the feed tab.")
        } else {
            parts.append("Tailing \(selectedPods.count) pod\(selectedPods.count == 1 ? "" : "s").")
        }
        parts.append(KubeLogTailSession.limitsNote)
        tailStatusLabel.stringValue = parts.joined(separator: " ")
    }

    // MARK: - Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        root.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        root.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        sessionCard.applyTheme(theme)
        scopeTabs?.applyTheme(theme)
        scopeEmptyState.applyTheme(theme)
        pageTabs.applyTheme(theme)
        clusterTabs.applyTheme(theme)
        clusterTable.applyTheme(theme)
        logList.applyTheme(theme)
        namespaceField.applyTheme(theme)
        for label in [feedStatusLabel, clusterStatusLabel, tailStatusLabel, describeSubtitleLabel] {
            label?.textColor = HelmTheme.mutedInk(theme)
            label?.font = HelmType.caption()
        }
        describeTitleLabel.font = HelmType.rowTitle()
        describeTitleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        applyDescribeTheme()
        renderClusterTable()
        renderPodPicker(force: true)
        renderLogLines(follow: false)
    }

    func applyDescribeTheme() {
        guard isViewLoaded else { return }
        // The drawer is a real surface sitting *over* the table, so it needs
        // the card treatment plus a leading edge and a shadow - without both,
        // a panel overlaying content of the same colour reads as the content
        // having changed rather than as something new having opened. This is
        // `ConsoleController`'s own SRE Lead pane reasoning: a fill difference
        // alone is not enough, because `chromeBackgroundHex` and
        // `backgroundHex` are the same value in three of the fourteen themes.
        describeDrawer.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        describeDrawer.layer?.borderWidth = 1
        describeDrawer.layer?.borderColor = HelmTheme.nsColor(theme.accentHex)
            .withAlphaComponent(0.55).cgColor
        describeDrawer.layer?.cornerRadius = theme.isDaylight ? HelmMetrics.dSurface : HelmMetrics.rCard
        // `describe` output is a command's raw text, so it lands on the same
        // dark card the log stream uses rather than the page surface - one
        // definition (`KubeLogListView.surfaceColor`), so the two panes can
        // never disagree about what raw output looks like.
        let surface = KubeLogListView.surfaceColor(for: theme)
        describeScroll.backgroundColor = surface
        describeScroll.wantsLayer = true
        describeScroll.layer?.masksToBounds = true
        describeScroll.layer?.cornerRadius = theme.isDaylight ? HelmMetrics.dSurface : HelmMetrics.rCard
        describeTextView.backgroundColor = surface
        describeTextView.font = HelmType.code()
        describeTextView.textColor = KubeLogListView.inkColor(for: theme)
        // Phase 0's D4: an owned `NSTextView` paints its own selection, and
        // `HelmContrastSelfTest.checkEveryTextViewIsThemed` fails the build on
        // one that never reaches `HelmSelection`.
        HelmSelection.apply(to: describeTextView, theme: theme)
    }
}

#if FM_SELFTESTS
// MARK: - Probe / self-test surface (`fm/grandline-k8s-cluster-tail`)
//
// Reads real state this page already renders, so `KubernetesDestinationSelfTest`
// asserts what a captain would actually see rather than re-deriving it. Compiled
// into debug builds only (GL-27): `Package.swift` defines `FM_SELFTESTS` for the
// debug configuration, so none of this reaches the shipped `.app`.
extension KubernetesController {
    var debugEmptyStateVisible: Bool { isViewLoaded && !scopeEmptyState.isHidden }
    var debugScopeStripVisible: Bool { isViewLoaded && !scopeTabsHost.isHidden && scopeTabs != nil }
    var debugFeedCardVisible: Bool { isViewLoaded && !feedSection.isHidden }
    var debugWorkAreaVisible: Bool { isViewLoaded && !workArea.isHidden }
    var debugClusterVisible: Bool { isViewLoaded && !clusterContainer.isHidden }
    var debugTailVisible: Bool { isViewLoaded && !tailContainer.isHidden }
    var debugDescribeVisible: Bool { isViewLoaded && !describeDrawer.isHidden }
    /// The drawer's own animated width - `0` when closed, its open width
    /// otherwise. `isHidden` alone is not the whole story: the panel hides
    /// only once the slide has finished (`setDescribeDrawerOpen`).
    var debugDescribeDrawerWidth: CGFloat { isViewLoaded ? describeWidthConstraint.constant : 0 }
    var debugDescribeSubtitle: String { isViewLoaded ? describeSubtitleLabel.stringValue : "" }
    var debugDescribeSpinning: Bool { isViewLoaded && describeSpinner.isHidden == false }
    var debugDescribeCloseButton: NSButton? { isViewLoaded ? describeCloseButton : nil }
    var debugDescribeCopyEnabled: Bool { isViewLoaded && describeCopyButton.isEnabled }
    /// Escape, through the real responder-chain hook rather than by calling
    /// `hideDescribeDrawer()` directly.
    func debugPressEscape() { cancelOperation(nil) }
    /// The commands one sweep would run right now, for the visible-tab
    /// scoping (`sweepCommands`).
    var debugSweepCommands: [String] { sweepCommands().map(\.shortLabel) }
    /// Real, laid-out geometry - what the layout revamp is actually about.
    var debugClusterTableFrame: NSRect { isViewLoaded ? clusterTable.frame : .zero }
    var debugWorkAreaFrame: NSRect { isViewLoaded ? workArea.frame : .zero }
    var debugSessionCardFrame: NSRect { isViewLoaded ? sessionCard.frame : .zero }
    var debugPageHeight: CGFloat { isViewLoaded ? root.bounds.height : 0 }
    var debugPodPickerViewCount: Int { isViewLoaded ? podPickerStack.arrangedSubviews.count : 0 }
    func debugSelectPageTab(_ raw: String) {
        guard let tab = PageTab(rawValue: raw) else { return }
        pageTab = tab
        render()
    }
    var debugScopeHostID: UUID? { scopeHostID }
    var debugFeedTabID: UUID? { feedTabID }
    var debugPods: [KubePod] { pods }
    var debugClusterRows: [KubeResourceTableView.Row] { isViewLoaded ? clusterTable.debugRows : [] }
    var debugClusterColumns: [String] { isViewLoaded ? clusterTable.debugColumnTitles : [] }
    var debugEvents: [KubeEvent] { events }
    var debugDeployments: [KubeDeployment] { deployments }
    var debugLogLines: [KubeLogLine] { merger.visibleLines(errorsOnly: errorsOnly) }
    var debugSelectedPods: [String] { selectedPods }
    var debugFeedStatusText: String { isViewLoaded ? feedStatusLabel.stringValue : "" }
    var debugRetryVisible: Bool { isViewLoaded && !retryFeedButton.isHidden }
    var debugTailStatusText: String { isViewLoaded ? tailStatusLabel.stringValue : "" }
    var debugClusterStatusText: String { isViewLoaded ? clusterStatusLabel.stringValue : "" }
    var debugDescribeText: String { isViewLoaded ? describeTextView.string : "" }
    var debugBridge: KubeBridge? { bridge }
    var debugNamespace: String { namespace }
    var debugPodTint: (String) -> HelmTint { { [merger] pod in merger.tint(for: pod) } }
    var debugSubtitle: String? { drillHeaderSubtitle }

    // `fm/grandline-k8s-refresh-stuck-audit`'s hard safety net.
    var debugIsRefreshingCluster: Bool { isRefreshingCluster }
    var debugClusterRefreshStuck: Bool { clusterRefreshStuck }
    var debugClusterRetryVisible: Bool { isViewLoaded && !clusterRetryButton.isHidden }
    var debugClusterRetryButton: NSButton? { isViewLoaded ? clusterRetryButton : nil }
    var debugRefreshGeneration: Int { refreshGeneration }
    var debugRefreshWatchdogRunning: Bool { refreshWatchdogTimer != nil }

    /// Backdates `refreshStartedAt` without waiting on the wall clock, so a
    /// self-test can prove the hard ceiling fires without a real 75s sleep -
    /// the same "drive by hand" convention `debugTick` already uses for
    /// `KubeBridge`'s own timer.
    func debugBackdateRefreshStart(secondsAgo: TimeInterval) {
        refreshStartedAt = Date().addingTimeInterval(-secondsAgo)
    }
    /// Drives the watchdog's own check directly rather than waiting on its
    /// real `Timer`.
    func debugCheckRefreshWatchdog() { checkRefreshWatchdog() }
    /// Exercises `finishRefreshCluster`'s own generation guard directly -
    /// see that method's own doc comment for why a real, naturally-stale
    /// completion cannot be constructed through the bridge's normal FIFO
    /// queue.
    func debugFinishRefreshCluster(_ results: [(KubeCommand, Result<String, KubeBridgeError>)], generation: Int) {
        finishRefreshCluster(results, generation: generation)
    }

    /// Drives the bridge's own poll by hand - a headless suite never pumps a
    /// run loop, so the real `Timer` never fires (the same reason
    /// `KubeContextBridge.tick()` is not private).
    func debugTick(_ count: Int = 1) { for _ in 0..<count { bridge?.tick() } }
    func debugAdoptFeedTab(_ tab: KubeFeedTab) { adoptFeedTab(tab) }
    func debugRefreshCluster() { refreshCluster() }
    func debugPollTail() { pollTail() }
    func debugSelectClusterTab(_ raw: String) {
        guard let tab = ClusterTab(rawValue: raw) else { return }
        clusterTab = tab
        renderClusterTable()
    }
    func debugSetNamespace(_ value: String) {
        namespaceField.stringValue = value
        namespaceCommitted()
    }
    /// Fires the picker's *real* checkbox action, so the cap and the colour
    /// assignment are exercised through the same path a click takes.
    func debugTogglePod(_ name: String) {
        let button = NSButton(checkboxWithTitle: name, target: self, action: #selector(togglePodSelection(_:)))
        togglePodSelection(button)
    }
}
#endif
