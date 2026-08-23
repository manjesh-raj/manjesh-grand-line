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

        plusButton = makeIconButton(symbol: "plus", tooltip: "New Shell Tab (⌘T)", action: #selector(newShellTab))

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
        // Zoom in / zoom out / theme / "+" stay icon squares deliberately -
        // they have no prototype counterpart, their glyphs are universally
        // legible on their own, and labelling four more controls would leave
        // a long tab strip nowhere to go.
        findButton = makeLabeledButton(symbol: "magnifyingglass", title: "Find", tooltip: "Find (⌘F)", action: #selector(showFind))
        zoomOutButton = makeIconButton(symbol: "minus.magnifyingglass", tooltip: "Zoom Out (⌘−)", action: #selector(zoomOut))
        zoomInButton = makeIconButton(symbol: "plus.magnifyingglass", tooltip: "Zoom In (⌘+)", action: #selector(zoomIn))
        themeButton = makeIconButton(symbol: "circle.lefthalf.filled", tooltip: "Toggle Light/Dark (⌘⌥T)", action: #selector(toggleTheme))
        blockViewToggleButton = makeLabeledButton(symbol: "rectangle.grid.1x2", title: "Blocks", tooltip: "Show Parsed Blocks (Stage 0)", action: #selector(toggleBlockView))
        blockViewRefreshButton = makeIconButton(symbol: "arrow.clockwise", tooltip: "Refresh Blocks", action: #selector(refreshBlockView))
        composeButton = makeLabeledButton(symbol: "sparkles", title: "Compose", tooltip: "Compose a command…", action: #selector(toggleComposer))
        utilizationButton = makeLabeledButton(symbol: quotaUsageGaugeSymbol, title: "Claude usage", tooltip: "Claude usage", action: #selector(toggleUtilization))

        // SRE Lead (design brief Part C) and block view (`fm/cockpit-block-
        // view-stage0`) are both dedicated-host-page-only affordances - the
        // shared Firstmate console has no single host cluster to
        // investigate, and its Shell/Mirror tabs never get a block tracker
        // at all (see `TabModel.blockViewOptIn`) - a bug there took down the
        // whole app on every launch in the original PR #79/#80 attempt.
        var toolViews: [NSView] = []
        if !isFirstmateConsole {
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
        // per captain request - `utilizationButton` (`fm/grandline-herdr-
        // utilization-panel`), which shares this slot the opposite way
        // (`updateUtilizationControls` - the two are never both visible on
        // the same tab), stays in its original trailing position.
        toolViews.append(composeButton)
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
        toolViews += [findButton, zoomOutButton, zoomInButton, themeButton]
        if !isFirstmateConsole {
            toolViews += [blockViewToggleButton, blockViewRefreshButton]
        }
        toolViews.append(utilizationButton)
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
    /// command (`isOneShotCommand`) - never a Mirror/Herdr tab (not a
    /// captain-typed shell at all - there's nothing to type a generated
    /// command into), or a one-shot command tab (already has a fixed,
    /// tracked purpose). `.ssh` is included so Compose is available on a
    /// host page exactly like it already is on the shared Firstmate
    /// console's Shell tab - the generated command still just gets sent as
    /// text into that tab's own real terminal (`TerminalView.send(txt:)`),
    /// so it lands in whatever shell the remote host itself is running, the
    /// same as anything else typed into that tab. Closes the popover
    /// outright when the current tab stops qualifying (e.g. switching away
    /// mid-review), so it never sits open pointed at a tab it no longer
    /// applies to.
    func updateComposeControls() {
        let available: Bool
        if let tab = currentTab, !tab.isOneShotCommand {
            switch tab.launch {
            case .shell, .ssh:
                available = true
            case .mirror:
                available = false
            }
        } else {
            available = false
        }
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

    // MARK: Claude usage (`fm/grandline-herdr-utilization-panel`)

    /// Only ever shown for a Herdr-backed `.mirror` tab - the opposite gating
    /// of `updateComposeControls` above, mirrored from the same two call
    /// sites (`select(tabID:)`, `applyTheme()`). Hidden, not merely disabled,
    /// on every other tab kind (`.shell`, `.ssh`, a tmux `.mirror`), and
    /// closes the popover outright when the current tab stops qualifying -
    /// same reasoning as Compose's own doc comment.
    func updateUtilizationControls() {
        let available: Bool
        if let tab = currentTab, case .mirror(let kind, _) = tab.launch, kind == .herdr {
            available = true
        } else {
            available = false
        }
        utilizationButton.isHidden = !available
        if !available { quotaUsage.close() }
        // See `updateComposeControls` - `HelmButton` owns its own tinting.
    }

    @objc func toggleUtilization() {
        guard !utilizationButton.isHidden else { return }
        quotaUsage.toggle(relativeTo: utilizationButton)
    }

    // MARK: Theme

    @objc func toggleTheme() {
        ThemeManager.shared.toggle()
        // `applyTheme()` runs via the `observe` callback registered in
        // `loadView`, so nothing else is needed here.
    }

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
        updateUtilizationControls()

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
        HelmCard.applyCardSurface(to: sreLeadCard, theme: theme, cornerRadius: HelmMetrics.rPanel)
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
        sreLeadEmptyStateLabel.textColor = HelmTheme.mutedInk(theme)
        // Every started tab's own chat, not just the current one - each is a
        // real, independent view that needs to stay in sync with the active
        // theme whether or not it happens to be the one currently visible.
        for tab in tabs { tab.sreLead?.chatView?.applyTheme(theme) }
        // Re-applies `sreLeadButton`'s theme + refreshes the pane/postmortem
        // button/tooltip for whichever tab is current.
        updateSRELeadControls()
    }

    func styleChips() {
        let accent = HelmTheme.nsColor(theme.accentHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = ink.withAlphaComponent(0.55)
        for tab in tabs {
            // Host tabs carry their own accent (A3); other tabs use the theme accent.
            let chipAccent = tab.accentHex.map(HelmTheme.nsColor) ?? accent
            let chipTint = chipAccent.withAlphaComponent(theme.mode == .dark ? 0.20 : 0.14)
            tab.chip.applyStyle(selected: tab === currentTab, accent: chipAccent, muted: muted, tint: chipTint)
        }
        plusButton.contentTintColor = ink
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
