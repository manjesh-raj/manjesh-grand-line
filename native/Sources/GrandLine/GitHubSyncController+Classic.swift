// Grand Line - native macOS app.
//
// `GitHubSyncController`'s floating-bar presentation (R2-ARCH-04): each repo's row inside the Repos card, with its own Details and Sync buttons, which the sidebar layout hides for the forks table (stage 7).
//
// The floating bar is the classic layout, frozen by R2-ARCH-01: it gets
// fixes but no new features and no page redesigns. So the members only its
// presentation uses live here, moved verbatim out of `GitHubSyncController.swift`, and
// that file carries the presentation the sidebar layout draws. A member both
// layouts use stays there. Swift's `private` is file-scoped, so the few
// members this file and the main one share lost `private`; treat this pair
// as one type's private parts (GL-36). `ClassicPresentationSelfTest` fails if
// one of these members moves back.

import AppKit

extension GitHubSyncController {

    func buildRow(_ row: GitHubSyncRow) -> NSView {
        row.syncButton.title = "Sync now"
        row.syncButton.controlSize = .small
        row.syncButton.target = self
        row.syncButton.action = #selector(syncTapped(_:))
        row.syncButton.identifier = NSUserInterfaceItemIdentifier(row.repo.fullName)

        row.progressLabel.setScaledFont(ofSize: 11, weight: .medium)

        let view = ToolRowLayout.build(
            row.toolRowViews,
            iconSymbol: "point.3.connected.trianglepath.dotted",
            tint: .neutral,
            name: row.repo.fullName,
            statusViews: [row.pill, row.statusSkeleton, row.progressLabel],
            trailingViews: [row.syncButton],
            detailsTarget: self,
            detailsAction: #selector(detailsTapped(_:)),
            // UI-43: the page-wide rule. Eight repos is eight status lines,
            // with "Sync now" on the row you are pointing at.
            actionReveal: ToolRowLayout.actionReveal(forPageRowCount: rows.count),
            identifier: row.repo.fullName
        )
        row.logContainer.isHidden = true
        return view
    }

    @objc private func detailsTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        row.isLogExpanded.toggle()
        ToolRowLayout.setLogExpanded(row.toolRowViews, expanded: row.isLogExpanded, log: row.log)
    }

    @objc private func syncTapped(_ sender: NSButton) {
        guard let row = row(for: sender) else { return }
        sync(row)
    }
}
