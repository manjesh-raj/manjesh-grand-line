// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: the page toolbar - the
// strip of controls above the terminal - plus the two popovers it opens
// (Compose, Claude usage) and the appearance/find/copy actions its buttons
// drive.
//
// `fm/grandline-menubar-remove-items` rewrote this file: it used to also
// build the tab-chip strip's leading side (`tabsStack` + a "+" button) and
// `refreshTabBar()`/`styleChips()`, all gone now that a console holds at
// most one session and there is nothing to show a strip of. See
// `ConsoleController.swift`'s header for the rest of what changed.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: Building the top bar

    func buildTabBar() {
        view.addSubview(toolbar)

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
        // Zoom in / zoom out stay icon squares deliberately - they have no
        // prototype counterpart and their glyphs are universally legible on
        // their own. The light/dark toggle that used to sit here moved onto
        // `DaylightBarController`, next to the bell
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

        // SRE Lead (design brief Part C) and block view (`fm/cockpit-block-
        // view-stage0`) are both dedicated-host-page-only affordances - the
        // shared Firstmate console has no single host cluster to
        // investigate, and its Shell session never gets a block tracker
        // at all (see `ConsoleSession.blockViewOptIn`) - a bug there took
        // down the whole app on every launch in the original PR #79/#80
        // attempt.
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
        // available on both the shared Firstmate console (its Shell session
        // is a plain `.shell` launch too) and every dedicated host page -
        // visibility is per-session (`updateComposeControls`), not per-
        // console like SRE Lead/block view above. Placed immediately after
        // SRE Lead (or first, on the shared console, which has no SRE Lead
        // button to sit next to) per captain request.
        toolViews.append(composeButton)
        // "Claude usage" sits immediately beside Compose, per captain
        // request - the toolbar prototype's own original pairing
        // (this file's header).
        toolViews.append(quotaUsageButton)
        // F8 (incident mode): the red action that ties SRE Lead and runbook
        // runs on this host into one record. Sits at the
        // end of the investigation cluster (SRE Lead / Compose)
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
        // `setTrailing` also installs the clearance inequality that keeps
        // this bar's controls from ever colliding with the leading edge.
        toolbar.setTrailing(HelmPageToolbar.group(toolViews))
    }

    func makeIconButton(symbol: String, tooltip: String, action: Selector) -> HelmButton {
        HelmPageToolbar.iconButton(symbol: symbol, tooltip: tooltip, target: self, action: action)
    }

    func makeLabeledButton(symbol: String, title: String, tooltip: String, action: Selector) -> HelmButton {
        HelmPageToolbar.labeledButton(symbol: symbol, title: title, tooltip: tooltip, target: self, action: action)
    }

    // MARK: Compose (`fm/grandline-console-command-composer`)

    /// Shown when this console has a session, as long as it's connected -
    /// the generated command still just gets sent as text into the
    /// session's own real terminal (`TerminalView.send(txt:)`), so it lands
    /// in whatever shell the remote host itself is running, the same as
    /// anything else typed into it. Closes the popover outright when this
    /// console stops having a session (e.g. disconnecting mid-review), so
    /// it never sits open pointed at nothing.
    func updateComposeControls() {
        let available = session != nil
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
    /// beside it. Closes the popover outright when this console stops
    /// having a session, so it never sits open pointed at nothing (matching
    /// Compose's own reasoning).
    func updateQuotaUsageControls() {
        let available = session != nil
        quotaUsageButton.isHidden = !available
        if !available { quotaUsage.close() }
    }

    @objc func toggleQuotaUsage() {
        guard !quotaUsageButton.isHidden else { return }
        quotaUsage.toggle(relativeTo: quotaUsageButton)
    }

    // MARK: Theme

    func applyTheme() {
        if let target = session {
            theme.apply(to: target.terminal)
            target.blockContainer?.applyTheme(theme)
        }

        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor
        // The bar's fill and hairline, and every glyph in it, are the
        // component's / `HelmButton`'s own business now - this page no longer
        // keeps a toolbar-button registry to re-tint (`ThemeManager.swift`'s
        // checklist item 4).
        toolbar.applyTheme(theme)
        content.layer?.backgroundColor = HelmTheme.nsColor(theme.backgroundHex).cgColor

        updateBlockViewControls()
        updateComposeControls()
        updateQuotaUsageControls()
        updateIncidentControls()
        incidentCard.applyTheme(theme)
        if incidentPopover.isShown { renderIncidentCard() }

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
        // The session's own chat, if it has one - a real, independent view
        // that needs to stay in sync with the active theme regardless.
        session?.sreLead?.chatView?.applyTheme(theme)
        // Re-applies `sreLeadButton`'s theme + refreshes the pane/postmortem
        // button/tooltip.
        updateSRELeadControls()
        onDrillSubtitleChanged?()
    }

    // MARK: Drill header (Daylight §6.4)

    /// Deliberately empty, and that is the §6.13 reading rather than an
    /// omission.
    ///
    /// §6.4's action cluster is "that page's primary + quiet actions", and
    /// §6.13 is explicit that Console's own actions stay in the page toolbar
    /// ("toolbar buttons, Compose popover, SRE Lead pane all take the
    /// Daylight button/well/card recipes") - that bar sits directly under
    /// the drill header and already carries every one of them. Hoisting a
    /// copy of Find / Compose up one row would put two of each on screen
    /// 44pt apart, which is the duplication §6.4 exists to remove.
    ///
    /// The conformance is still worth having: `drillHeaderSubtitle` below is
    /// what gives this destination - and every dedicated host page, which the
    /// shell also routes through this controller - a live header line.
    var drillHeaderActions: [NSView] { [] }

    /// §6.4's "`caption()` subtitle with live numbers", from state this page
    /// already has: whether there's a session, and its name.
    /// `fm/grandline-menubar-remove-items`: no longer a tab count (there's
    /// at most one session, so counting it would be a strange thing to say).
    var drillHeaderSubtitle: String? {
        guard let target = session else {
            return isFirstmateConsole ? "No session running" : "Not connected yet"
        }
        return target.name
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

    // MARK: Find + copy (routed to the session's terminal)

    @objc func showFind() {
        // Route to the session's native find bar. SwiftTerm's
        // `performFindPanelAction` expects a menu item whose tag is the
        // NSFindPanelAction; showFindPanel == 1.
        guard let term = session?.terminal else { return }
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        view.window?.makeFirstResponder(term)
        term.performFindPanelAction(item)
    }

    @objc func copySelection() {
        session?.terminal.copy(self)
    }
}
