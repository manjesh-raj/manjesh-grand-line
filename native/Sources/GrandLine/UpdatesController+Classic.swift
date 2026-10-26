// Grand Line - native macOS app.
//
// `UpdatesController`'s floating-bar presentation (R2-ARCH-04): the stats strip and the per-category cards of tool rows, with each row's own buttons, which the sidebar layout hides for Setup's summary and one tools table (stage 7).
//
// The floating bar is the classic layout, frozen by R2-ARCH-01: it gets
// fixes but no new features and no page redesigns. So the members only its
// presentation uses live here, moved verbatim out of `UpdatesController.swift`, and
// that file carries the presentation the sidebar layout draws. A member both
// layouts use stays there. Swift's `private` is file-scoped, so the few
// members this file and the main one share lost `private`; treat this pair
// as one type's private parts (GL-36). `ClassicPresentationSelfTest` fails if
// one of these members moves back.

import AppKit

extension UpdatesController {

    /// UI-44: the four numbers as a `HelmKPIStrip` on the page ground - the
    /// same strip Home's Fleet card and Weekly Review use. It used to be four
    /// boxed `HelmStatTile`s, a bordered surface per number directly above
    /// the bordered category cards. What the tiles got right stays: a figure
    /// the page cannot know yet is a dash, never a zero (GL-14).
    func buildStatsRow() -> NSView {
        summaryStrip.setAccessibilityLabel("Updates summary")
        // UI-51: the page's explanatory caption is a tooltip on its numbers.
        // The drill header names the page, and a sentence above every visit
        // was the longest line on it.
        summaryStrip.toolTip = "Every tool in the fleet, checked against its real source - npm, Homebrew, "
            + "herdr, no-mistakes, and firstmate's own upstream."
        renderStats()
        return summaryStrip
    }

    func iconFor(category: String) -> String {
        switch category {
        case "npm packages": return "shippingbox"
        case "Homebrew": return "wrench.and.screwdriver"
        case "Other tools": return "gearshape.2"
        case "Documentation": return "book.closed"
        default: return "sailboat"
        }
    }

    /// A per-category tint for each row's `IconTileView` (mirrors the
    /// mockup's blue/red/violet tool-row tiles) - resolved through the shared
    /// `HelmTint` enum (phase 1's `HelmUIComponents.swift`) rather than a raw
    /// hex, so it stays correct across all 8 Helm palettes.
    private func categoryTint(for category: String) -> HelmTint {
        DependencyCatalog.tint(for: category)
    }

    /// One `HelmCard` per tool category - the shared container from
    /// `HelmDesignSystem.swift`, replacing this file's own copy of a card
    /// helper that was byte-for-byte identical in four controllers, plus its
    /// own copy of the theming loop (audit §3.2).
    func card(icon: String, title: String, rows categoryRows: [UpdateRow]) -> HelmCard {
        var rowViews: [NSView] = []
        var sectionSeparators: [NSView] = []
        for (index, row) in categoryRows.enumerated() {
            // One reveal rule for every row on the page - see `buildRow`.
            rowViews.append(buildRow(row))
            if index < categoryRows.count - 1 {
                let sep = separator()
                rowViews.append(sep)
                sectionSeparators.append(sep)
            }
        }
        let rowsStack = NSStackView(views: rowViews)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for v in rowViews { v.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true }

        let card = HelmCard()
        // UI-51: the group header is the kit's section header - the
        // category's tile, its name and a muted count - the same header
        // Tasks' panels use.
        let header = HelmSectionHeader(size: .section)
        header.configure(leading: .tile(symbol: icon, tint: DependencyCatalog.tint(for: title)),
                         title: title, count: "\(categoryRows.count)")
        groupHeaders.append(header)
        card.setHeader(header)
        card.setBody(rowsStack, insets: HelmCard.contentInsets)
        cards.append(card)
        categorySections.append(CategorySection(background: card, rows: categoryRows, separators: sectionSeparators))
        return card
    }

    /// Builds one tool row. Its Check/Update buttons follow the page-wide
    /// reveal rule - see the `actionReveal` argument below.
    private func buildRow(_ row: UpdateRow) -> NSView {
        // Check / Update
        row.checkButton.target = self
        row.checkButton.action = #selector(checkTapped(_:))
        row.checkButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)

        row.updateButton.target = self
        row.updateButton.action = #selector(updateTapped(_:))
        row.updateButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)
        row.updateButton.isHidden = true

        // `.notInstalled` only - `.quiet` + an accent `tint`, so it reads as
        // "navigate elsewhere" and is never confusable with the accent-filled
        // `.primary` `updateButton` used for every other status. Its label
        // colour used to be a hand-rolled `attributedTitle` in `applyThemeToRow`
        // (`contentTintColor` does not colour a string title) - `tint` is that
        // same idea, shared and contrast-corrected.
        row.installInBootstrapButton.tint = .accent
        row.installInBootstrapButton.target = self
        row.installInBootstrapButton.action = #selector(installInBootstrapTapped(_:))
        row.installInBootstrapButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)
        row.installInBootstrapButton.isHidden = true

        row.runInTerminalButton.target = self
        row.runInTerminalButton.action = #selector(runInTerminalTapped(_:))
        row.runInTerminalButton.identifier = NSUserInterfaceItemIdentifier(row.item.id)
        row.runInTerminalButton.isHidden = true

        // Busy state
        row.progressLabel.setScaledFont(ofSize: 11, weight: .medium)

        let view = ToolRowLayout.build(
            row.toolRowViews,
            iconSymbol: row.item.kind.symbol,
            tint: categoryTint(for: row.item.category),
            name: row.item.name,
            // Status column: the pill, and the spinner/label that replace
            // it while a check or update runs. Actions stay in their own
            // trailing column (audit §5.4).
            statusViews: [row.pill, row.statusSkeleton, row.progressLabel],
            trailingViews: [row.checkButton, row.updateButton, row.runInTerminalButton, row.installInBootstrapButton],
            detailsTarget: self,
            detailsAction: #selector(detailsTapped(_:)),
            // UI-43: one rule for the whole page, from
            // `ToolRowLayout.actionReveal(forPageRowCount:)`. This page once
            // split its rows per category (five-row "npm packages" showed one
            // Check button and four gaps above "Homebrew", which showed all
            // three) and the captain reported that as broken. The page-wide
            // count gives every row the same treatment: the buttons appear on
            // hover or keyboard focus, and the status stays visible at rest.
            actionReveal: ToolRowLayout.actionReveal(forPageRowCount: rows.count),
            identifier: row.item.id
        )
        row.logContainer.isHidden = true // collapsed until the details chevron is tapped.
        return view
    }

    @objc private func detailsTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        row.isLogExpanded.toggle()
        ToolRowLayout.setLogExpanded(row.toolRowViews, expanded: row.isLogExpanded, log: row.log)
    }

    // The row's own "Check" button is this row's explicit re-check
    // affordance, so it always forces a real check rather than serving
    // whatever another page's sweep happened to cache.
    @objc private func checkTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        check(row, forceRefresh: true)
    }

    @objc private func updateTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        confirmAndUpdate(row)
    }

    @objc private func installInBootstrapTapped(_ sender: NSButton) {
        onNavigateToBootstrap?()
    }

    /// Opens the update the background run refused in a Console tab, then
    /// re-checks the row once that command exits, whatever its status - the
    /// machine is the source of truth, not the command's exit code.
    @objc private func runInTerminalTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        runInTerminal(row)
    }
}
