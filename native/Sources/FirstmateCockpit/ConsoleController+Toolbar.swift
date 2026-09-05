// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: the page toolbar - the
// strip of controls above the terminal - plus the two popovers it opens
// (Compose, Claude usage) and the appearance/find/copy actions its buttons
// drive.
//
// Split out verbatim along this controller's own existing `// MARK:` seams;
// no statement here changed in the move. See `ConsoleController.swift`'s
// header for what the split is and why some members stopped being
// `private`.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: Building the top bar

    func buildTabBar() {
        view.addSubview(tabBar)

        tabsStack.orientation = .horizontal
        tabsStack.spacing = 4
        tabsStack.alignment = .centerY
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.setLeading(tabsStack)

        plusButton = makeIconButton(symbol: "plus", tooltip: "New Shell Tab", action: #selector(newShellTab))

        // **Named features are labelled; pure utilities stay icon squares.**
        //
        // The audit prototype's Console toolbar
        // (`15-proposed-console-sre-lead.png`) reads "Find / Compose / Claude
        // usage / SRE Lead" - four labelled buttons, not four glyphs. Phase 7
        // unified this bar's *chrome* (bordered `.secondary` squares) but left
        // every control unlabelled, so a captain could not tell Compose from
        // Claude usage without hovering. These are the four the prototype
        // names, plus Block View, which is the same kind of thing: a named,
        // stateful feature toggle rather than a glyph-native utility.
        //
        // Zoom in / zoom out / "+" stay icon squares deliberately - they have
        // no prototype counterpart, their glyphs are universally legible on
        // their own, and labelling more controls would leave a long tab
        // strip nowhere to go. The light/dark toggle that used to sit here
        // moved onto `DaylightBarController`, next to the bell
        // (`fm/grandline-daylight-theme-toggle-relocate`) - it is an
        // app-wide preference, not something scoped to Console.
        findButton = makeLabeledButton(symbol: "magnifyingglass", title: "Find", tooltip: "Find (⌘F)", action: #selector(showFind))
        zoomOutButton = makeIconButton(symbol: "minus.magnifyingglass", tooltip: "Zoom Out (⌘−)", action: #selector(zoomOut))
        zoomInButton = makeIconButton(symbol: "plus.magnifyingglass", tooltip: "Zoom In (⌘+)", action: #selector(zoomIn))
        blockViewToggleButton = makeLabeledButton(symbol: "rectangle.grid.1x2", title: "Blocks", tooltip: "Show Parsed Blocks (Stage 0)", action: #selector(toggleBlockView))
        blockViewRefreshButton = makeIconButton(symbol: "arrow.clockwise", tooltip: "Refresh Blocks", action: #selector(refreshBlockView))
        composeButton = makeLabeledButton(symbol: "sparkles", title: "Compose", tooltip: "Compose a command…", action: #selector(toggleComposer))
        quotaUsageButton = makeLabeledButton(symbol: quotaUsageGaugeSymbol, title: "Claude usage",
                                             tooltip: "Check Claude usage", action: #selector(toggleQuotaUsage))
        // `fm/grandline-drag-forward-indicator`: seeded with `.local`'s
        // display (the default), refreshed to the real per-tab state by
        // `updateDragForwardingControls()` below every time it might have
        // changed - the same seed-then-refresh shape `kubeContextButton`/
        // `sreLeadButton` already use.
        dragForwardingButton = makeLabeledButton(symbol: DragForwardingIndicator.local.buttonSymbol,
                                                  title: DragForwardingIndicator.local.buttonTitle,
                                                  tooltip: DragForwardingIndicator.local.tooltip,
                                                  action: #selector(toggleDragForwarding))

        // SRE Lead (design brief Part C) and block view (`fm/cockpit-block-
        // view-stage0`) are both dedicated-host-page-only affordances - the
        // shared Firstmate console has no single host cluster to
        // investigate, and its Shell tab never gets a block tracker
        // at all (see `TabModel.blockViewOptIn`) - a bug there took down the
        // whole app on every launch in the original PR #79/#80 attempt.
        var toolViews: [NSView] = []
        if !isFirstmateConsole {
            // The context/namespace safety badge (`fm/grandline-k8s-context-
            // badge`) - a real per-tab toggle now (`fm/grandline-k8s-badge-
            // fixes`, issue 3), built alongside SRE Lead's own button and
            // hidden per-tab exactly the same way (`updateKubeContextBadgeControls`).
            // Sits first, ahead of every action button - the wrong-cluster
            // guard is the thing worth seeing before reaching for any of the
            // investigation actions beside it.
            let kubeButton = makeLabeledButton(symbol: KubeContextBadgeStatus.notStarted.buttonSymbol,
                                               title: KubeContextBadgeStatus.notStarted.buttonTitle,
                                               tooltip: KubeContextBadgeStatus.notStarted.tooltip,
                                               action: #selector(toggleKubeContextBadge))
            kubeContextButton = kubeButton
            toolViews.append(kubeButton)
            let button = makeLabeledButton(symbol: SRELeadPhase.notStarted.symbol,
                                           title: SRELeadPhase.notStarted.text,
                                           tooltip: "Toggle the SRE Lead investigation pane",
                                           action: #selector(toggleSRELead))
            button.tint = SRELeadPhase.notStarted.tint
            sreLeadButton = button
            toolViews.append(button)
        }
        // Compose (phase 3, `fm/grandline-console-command-composer`) is
        // available on both the shared Firstmate console (its Shell tab is a
        // plain `.shell` launch too) and every dedicated host page - visibility
        // is per-tab (`updateComposeControls`), not per-console like SRE
        // Lead/block view above. Placed immediately after SRE Lead (or first,
        // on the shared console, which has no SRE Lead button to sit next to)
        // per captain request.
        toolViews.append(composeButton)
        // "Claude usage" sits immediately beside Compose, per captain
        // request - the toolbar prototype's own original pairing
        // (this file's header).
        toolViews.append(quotaUsageButton)
        // The drag-routing indicator sits right after Claude usage - "near
        // the terminal's own toolbar/composer area", per the task that added
        // it. `.shell`-tabs-only, exactly like `TabChipView.
        // forwardDragsEnabled`'s own gating - hidden for every `.ssh` tab.
        toolViews.append(dragForwardingButton)
        // Analyze Logs sits immediately after Compose, so the three
        // investigation-shaped features (SRE Lead, Compose, Analyze Logs)
        // read as one cluster - the placement the captain asked for.
        if !isFirstmateConsole {
            let button = makeLabeledButton(symbol: "text.magnifyingglass", title: "Analyze Logs",
                                           tooltip: "Send this tab's last command output to the Log Analyzer. "
                                               + "Select text in the terminal first to send that instead.",
                                           action: #selector(analyzeLogsTapped))
            analyzeLogsButton = button
            toolViews.append(button)
        }
        // `fm/grandline-k8s-cluster-tail`: "Tail Logs" joins the same
        // investigation cluster, as a pre-scoped deep link into the
        // standalone `.kubernetes` destination rather than a panel of its own
        // (the scout report's Shape C). `!isFirstmateConsole` is the whole
        // gate, exactly like Analyze Logs above: every dedicated host page has
        // a saved host id by construction, and an ad-hoc quick-connect opens
        // in the *shared* console, which this branch already excludes. It
        // cannot be gated on `onTailLogs != nil` - the toolbar is built during
        // `loadView`, which `embed(controller.view)` triggers before
        // `connectHost` has assigned any of its closures.
        if !isFirstmateConsole {
            let button = makeLabeledButton(symbol: "list.bullet.rectangle.portrait", title: "Tail Logs",
                                           tooltip: "Open Kubernetes, scoped to this host, and tail pod logs there.",
                                           action: #selector(tailLogsTapped))
            tailLogsButton = button
            toolViews.append(button)
        }
        // F8 (incident mode): the red action that ties SRE Lead, the Log
        // Analyzer and runbook runs on this host into one record. Sits at the
        // end of the investigation cluster (SRE Lead / Compose / Analyze Logs)
        // and, like SRE Lead, only exists on a dedicated host page - an
        // incident belongs to a host.
        if !isFirstmateConsole {
            let button = makeLabeledButton(symbol: "bolt", title: "Start Incident",
                                           tooltip: "Start an incident on this host",
                                           action: #selector(incidentButtonClicked))
            button.tint = .critical
            incidentButton = button
            toolViews.append(button)
        }
        toolViews += [findButton, zoomOutButton, zoomInButton]
        if !isFirstmateConsole {
            toolViews += [blockViewToggleButton, blockViewRefreshButton]
        }
        // `setTrailing` also installs the clearance inequality that keeps a
        // long tab strip truncating rather than running under the actions -
        // the constraint this method used to activate by hand.
        tabBar.setTrailing(HelmPageToolbar.group(toolViews))
    }

    func makeIconButton(symbol: String, tooltip: String, action: Selector) -> HelmButton {
        HelmPageToolbar.iconButton(symbol: symbol, tooltip: tooltip, target: self, action: action)
    }

    func makeLabeledButton(symbol: String, title: String, tooltip: String, action: Selector) -> HelmButton {
        HelmPageToolbar.labeledButton(symbol: symbol, title: title, tooltip: tooltip, target: self, action: action)
    }

    /// Re-lay the tab bar: one chip per tab, then the "+" button.
    func refreshTabBar() {
        for v in tabsStack.arrangedSubviews {
            tabsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for tab in tabs {
            tabsStack.addArrangedSubview(tab.chip)
        }
        tabsStack.addArrangedSubview(plusButton)
        styleChips()
    }

    // MARK: Compose (`fm/grandline-console-command-composer`)

    /// Shown for a plain `.shell` tab or an `.ssh` tab (a dedicated host
    /// page's own SSH session), as long as it isn't a one-shot provisioning
    /// command (`isOneShotCommand`, which already has a fixed, tracked
    /// purpose). `.ssh` is included so Compose is available on a host page
    /// exactly like it already is on the shared Firstmate console's Shell
    /// tab - the generated command still just gets sent as text into that
    /// tab's own real terminal (`TerminalView.send(txt:)`), so it lands in
    /// whatever shell the remote host itself is running, the same as
    /// anything else typed into that tab. Closes the popover outright when
    /// the current tab stops qualifying (e.g. switching away mid-review), so
    /// it never sits open pointed at a tab it no longer applies to.
    func updateComposeControls() {
        let available = currentTab.map { !$0.isOneShotCommand } ?? false
        composeButton.isHidden = !available
        if !available { composer.close() }
        // No `contentTintColor` here - `HelmButton.restyle()` owns that
        // property (AGENTS.md, Phase 2) and this button themes itself. It was
        // a harmless no-op back when the control was image-only; now that it
        // carries a label too, letting the variant decide both is the point.
    }

    @objc func toggleComposer() {
        guard !composeButton.isHidden else { return }
        composer.toggle(relativeTo: composeButton)
    }

    // MARK: Claude usage (`fm/grandline-herdr-utilization-panel`,
    // restored beside Compose - see `quotaUsageButton`'s doc comment)

    /// Byte-for-byte `updateComposeControls()`'s own availability rule -
    /// "Claude usage" is the same shape of feature as Compose, sitting right
    /// beside it. Closes the popover outright when the current tab stops
    /// qualifying, so it never sits open pointed at a tab it no longer
    /// applies to (matching Compose's own reasoning).
    func updateQuotaUsageControls() {
        let available = currentTab.map { !$0.isOneShotCommand } ?? false
        quotaUsageButton.isHidden = !available
        if !available { quotaUsage.close() }
    }

    @objc func toggleQuotaUsage() {
        guard !quotaUsageButton.isHidden else { return }
        quotaUsage.toggle(relativeTo: quotaUsageButton)
    }

    // MARK: Drag routing indicator (`fm/grandline-drag-forward-indicator`)

    /// Shows/hides and restyles the toolbar's own "drag routing" button -
    /// hidden entirely unless `currentTab` is a `.shell` tab
    /// (`CockpitTerminalView.prefersLocalSelection` is only ever set for
    /// that launch kind, see `ConsoleController+Tabs.addTab`), matching
    /// `TabChipView.forwardDragsEnabled`'s exact per-tab-relevance gating -
    /// hidden for every `.ssh` tab, and for the shared Firstmate console
    /// before its first tab exists. When shown, always reflects
    /// `tab.terminal.forwardDragsToChild` directly via `DragForwardingIndicator`
    /// - the same single source of truth the tab chip's own icon reads, so
    /// the two can never disagree about which state is current.
    func updateDragForwardingControls() {
        guard let tab = currentTab, tab.terminal.prefersLocalSelection else {
            dragForwardingButton.isHidden = true
            return
        }
        dragForwardingButton.isHidden = false
        let indicator = DragForwardingIndicator(forwardDragsToChild: tab.terminal.forwardDragsToChild)
        dragForwardingButton.title = indicator.buttonTitle
        dragForwardingButton.symbolName = indicator.buttonSymbol
        dragForwardingButton.tint = indicator.buttonTint
        dragForwardingButton.toolTip = indicator.tooltip
    }

    /// The toolbar button's click action - flips the same
    /// `CockpitTerminalView.forwardDragsToChild` the tab chip's own
    /// right-click menu already flips (`toggleForwardDragsToChild(id:)`,
    /// unchanged), then refreshes this button immediately so a click is
    /// never left showing stale state until the next unrelated
    /// `updateDragForwardingControls()` call.
    @objc func toggleDragForwarding() {
        guard let tab = currentTab, tab.terminal.prefersLocalSelection else { return }
        toggleForwardDragsToChild(id: tab.id)
        updateDragForwardingControls()
    }

    // MARK: Context/namespace safety badge (`fm/grandline-k8s-context-badge`,
    // per-tab activation and backoff from `fm/grandline-k8s-badge-fixes`)

    /// Shows/hides and restyles the context/namespace badge toggle - hidden
    /// entirely unless the current tab is even eligible
    /// (`TabModel.kubeContextBadgeOptIn` - see that property's doc comment),
    /// matching `updateBlockViewControls`'s exact per-tab-relevance pattern.
    /// When eligible, the button always reflects `tab.kubeContextBadgeStatus`
    /// directly (`KubeContextBadgeStatus.buttonTitle`/`.buttonSymbol`/
    /// `.buttonTint`/`.tooltip`) - a single source of truth shared with
    /// `toggleKubeContextBadge`'s own click-behavior switch below, so the two
    /// can never disagree about what a given state means.
    func updateKubeContextBadgeControls() {
        guard let button = kubeContextButton else { return }
        guard let tab = currentTab, tab.kubeContextBadgeOptIn else {
            button.isHidden = true
            return
        }
        button.isHidden = false
        let status = tab.kubeContextBadgeStatus
        button.title = status.buttonTitle
        button.symbolName = status.buttonSymbol
        button.tint = status.buttonTint
        button.toolTip = status.tooltip
    }

    /// The context badge toggle's click action - operates on `currentTab`,
    /// never a page-level state, mirroring `toggleSRELead()`'s exact shape.
    ///
    /// `fm/grandline-k8s-badge-fixes` (issue 3): this is the ONE place
    /// activation happens - a captain click on a specific tab's own toolbar,
    /// never anything `addTab` does automatically. `.checking` is
    /// deliberately a no-op here (a click mid-check does nothing, matching
    /// `toggleSRELead()` ignoring a click during `.starting`) rather than
    /// e.g. cancelling - there is nothing meaningful to cancel into, since
    /// the alternative to "wait for this attempt" is just "wait for this
    /// attempt anyway, only later."
    @objc func toggleKubeContextBadge() {
        guard let tab = currentTab, tab.kubeContextBadgeOptIn else { return }
        switch tab.kubeContextBadgeStatus {
        case .checking:
            return
        case .notStarted, .unavailable:
            activateKubeContextBadge(for: tab)
        case .active:
            deactivateKubeContextBadge(for: tab)
        }
    }

    // MARK: Theme

    func applyTheme() {
        for tab in tabs {
            theme.apply(to: tab.terminal)
            tab.blockContainer?.applyTheme(theme)
        }

        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        // The bar's fill and hairline, and every glyph in it, are the
        // component's / `HelmButton`'s own business now - this page no longer
        // keeps a toolbar-button registry to re-tint (`ThemeManager.swift`'s
        // checklist item 4).
        tabBar.applyTheme(theme)
        content.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        styleChips()
        updateBlockViewControls()
        updateComposeControls()
        updateQuotaUsageControls()
        updateDragForwardingControls()
        updateKubeContextBadgeControls()
        updateIncidentControls()
        incidentCard.applyTheme(theme)
        if incidentPopover.isShown {
            // A theme change while the card is already open has to reach the
            // popover's own appearance too, not only the card's colours -
            // `showIncidentCard()` sets it, and an already-shown popover
            // never goes back through there.
            incidentPopover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            renderIncidentCard()
        }

        // The pane is a distinct surface/card, not a continuation of the
        // terminal - filled with `chromeBackgroundHex` (this app's "surface"
        // token) instead of `backgroundHex` (the terminal's own token),
        // fixing a captain-reported "melds into the terminal" report
        // (`fm/grandline-sre-lead-polish`). Checked live across all 12
        // `HelmTheme.allThemes`: `chromeBackgroundHex` differs from
        // `backgroundHex` in 9 of them, but is numerically IDENTICAL in
        // `gruvbox-light`/`tokyo-night-dark`/`tokyo-night-light` - so the
        // fill alone can't be the only thing carrying this distinction. What
        // carries it in every theme now is structural rather than tonal: a
        // real workspace gap with a 1pt outline down each side of it (see
        // `sreLeadCard`'s doc comment). Never go back to relying on the fill
        // pair alone here.
        //
        // `sreLeadPane` itself is transparent: it is only the clipping
        // backdrop, and `cardChrome` paints the floor and this card's shadow
        // through it.
        let paneBg = HelmTheme.nsColor(theme.chromeBackgroundHex)
        sreLeadPane.layer?.backgroundColor = NSColor.clear.cgColor
        HelmCard.applyCardSurface(to: sreLeadCard, theme: theme, cornerRadius: HelmMetrics.rPanel,
                                  daylightRadius: HelmMetrics.rPanel)
        // Transparent, so the card's own fill shows through - the header used
        // to paint `chromeBackgroundHex` itself, which is the same colour but
        // would square off the card's top corners inside its clip.
        sreLeadHeader.layer?.backgroundColor = NSColor.clear.cgColor
        sreLeadHeaderDivider.layer?.backgroundColor = line.withAlphaComponent(HelmCard.dividerAlpha).cgColor
        sreLeadHeaderIcon.applyTheme(theme)
        sreLeadHeaderLabel.textColor = ink
        sreLeadGeneratePostmortemButton.contentTintColor = ink
        sreLeadEmptyStateView.layer?.backgroundColor = paneBg.cgColor
        cardChrome.applyTheme(theme)
        // §6.13: whether the terminal card is drawn at all depends on the
        // theme now, so a switch has to re-ask - see
        // `refreshTerminalCardChrome()`.
        refreshTerminalCardChrome()
        sreLeadEmptyStateLabel.textColor = HelmTheme.mutedInk(theme)
        // Every started tab's own chat, not just the current one - each is a
        // real, independent view that needs to stay in sync with the active
        // theme whether or not it happens to be the one currently visible.
        for tab in tabs { tab.sreLead?.chatView?.applyTheme(theme) }
        // Re-applies `sreLeadButton`'s theme + refreshes the pane/postmortem
        // button/tooltip for whichever tab is current.
        updateSRELeadControls()
    }

    // MARK: Drill header (Daylight §6.4)

    /// Deliberately empty, and that is the §6.13 reading rather than an
    /// omission.
    ///
    /// §6.4's action cluster is "that page's primary + quiet actions", and
    /// §6.13 is explicit that Console's own actions stay in the page toolbar
    /// ("tab chips, toolbar buttons, Compose popover, SRE Lead pane all take
    /// the Daylight button/well/card recipes") - that bar sits directly under
    /// the drill header and already carries every one of them. Hoisting a
    /// copy of New Tab / Find / Compose up one row would put two of each on
    /// screen 44pt apart, which is the duplication §6.4 exists to remove.
    ///
    /// The conformance is still worth having: `drillHeaderSubtitle` below is
    /// what gives this destination - and every dedicated host page, which the
    /// shell also routes through this controller - a live header line.
    var drillHeaderActions: [NSView] { [] }

    /// §6.4's "`caption()` subtitle with live numbers", from state this page
    /// already has: how many tabs are open and which one is showing. No new
    /// collection, and nothing here can disagree with the tab strip, because
    /// both read the same `tabs`/`currentTab`.
    var drillHeaderSubtitle: String? {
        guard !tabs.isEmpty else {
            return isFirstmateConsole ? "No tabs open" : "Not connected yet"
        }
        let count = tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs"
        guard let name = currentTab?.name, !name.isEmpty else { return count }
        return "\(count) \u{00B7} \(name)"
    }

    func styleChips() {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        // `mutedInk` under Daylight, where that token is contrast-corrected
        // per theme against the surface a chip actually sits on; the twelve
        // palettes keep the hand-rolled 0.55 they have always rendered.
        let muted = theme.isDaylight ? HelmTheme.mutedInk(theme) : ink.withAlphaComponent(0.55)
        for tab in tabs {
            // Host tabs carry their own accent (A3); other tabs use the theme accent.
            let chipAccent = tab.accentHex.map(HelmTheme.nsColor) ?? accent
            let chipTint = chipAccent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
            tab.chip.applyStyle(selected: tab === currentTab, accent: chipAccent, muted: muted, tint: chipTint)
            // Both chip indicators own their own tinted fill, so a theme
            // change has to re-resolve them here rather than inheriting
            // `applyStyle`'s ink.
            tab.chip.refreshForwardDragsIndicator()
            tab.chip.refreshMachineReadableIndicator()
        }
        // §6.4's live subtitle. This method is the one choke point every tab
        // add / close / rename / selection already passes through, so hooking
        // it here is what keeps the drill header's "3 tabs · Shell" honest
        // without a second notification path.
        onDrillSubtitleChanged?()
        // `plusButton` is a `HelmButton` and themes itself: `restyle()` owns
        // `contentTintColor` and overwrites anything set here on the next
        // theme change, so this line was a coin-flip that also defeated the
        // button's own §6.6 Daylight recipe (Phase 2's own rule, and the same
        // correction `updateComposeControls` already took).
    }

    // MARK: Font zoom

    @objc func zoomIn() { FontSizeManager.shared.step(by: 1) }
    @objc func zoomOut() { FontSizeManager.shared.step(by: -1) }
    @objc func zoomReset() { FontSizeManager.shared.setSize(13) }

    /// The Settings panel's font-size stepper (Fix 3) - now a thin forward
    /// to `FontSizeManager`, which is the source of truth (`fm/cockpit-
    /// tools-page-ui-polish`); kept as a method on this class since
    /// `main.swift`'s existing `onFontSizeStep` wiring still calls it.
    func stepFontSize(by delta: CGFloat) { FontSizeManager.shared.step(by: delta) }
    var currentFontSize: CGFloat { fontSize }

    // MARK: Find + copy (routed to the active terminal)

    @objc func showFind() {
        // Route to the active terminal's native find bar. SwiftTerm's
        // `performFindPanelAction` expects a menu item whose tag is the
        // NSFindPanelAction; showFindPanel == 1.
        guard let term = activeTerminal() else { return }
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        view.window?.makeFirstResponder(term)
        term.performFindPanelAction(item)
    }

    @objc func copySelection() {
        activeTerminal()?.copy(self)
    }
}


// MARK: - Kubernetes deep link (`fm/grandline-k8s-cluster-tail`)

extension ConsoleController {
    /// Forwards, never handles. See `onTailLogs`' own doc comment.
    @objc func tailLogsTapped() { onTailLogs?() }
}
