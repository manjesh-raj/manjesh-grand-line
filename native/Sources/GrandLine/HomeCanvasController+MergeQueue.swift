// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: the merge queue card.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    func fillMergeQueue(_ content: inout HelmModuleCard.Content) {
        var stale: Date?
        let prs: [MergedPR]
        if let current = mergedPRs {
            prs = current
        } else if let failure = prFetchFailure, let last = lastGoodPRs {
            // UI-12's error state: keep the last reading and say how old it
            // is, with the reason on hover - stale-but-real beats a blank.
            prs = last
            stale = lastGoodPRsAt
            content.toolTip = "GitHub did not answer: \(failure)"
        } else if let last = lastGoodPRs {
            // A refresh in flight. Every Fleet refresh pushes its fast
            // snapshot with `mergedPRs: nil` and the slow PR scan seconds
            // later, so falling through to the skeleton here put the card
            // back into its loading layout on every Refresh and every Fleet
            // visit (`fm/grandline-layout-breaks-refresh-reply`). The last
            // list stays until the new one lands.
            prs = last
        } else if let failure = prFetchFailure {
            content.subtitle = "not read"
            content.chip = .warn("Can't reach")
            // GL-14: a failed scan must never render as a confident zero.
            content.body = .note("PR status unavailable - \(failure)")
            return
        } else {
            content.subtitle = "reading"
            content.toolTip = "Reading open pull requests\u{2026}"
            // As many placeholder rows as the loaded list would get.
            content.body = .skeleton(rows: HelmModuleCard.maxPeekRows)
            return
        }
        let ready = FleetDataSource.readyToMerge(prs)
        content.subtitle = "\(prs.count) open"
        content.chip = ready.isEmpty ? .mute("none ready") : .ok("\(ready.count) ready")
        if let stale {
            content.subtitle = "\(prs.count) open \u{00B7} as of \(Self.briefingTimeFormatter.string(from: stale))"
            content.chip = .warn("Can't reach")
        }
        if prs.isEmpty {
            content.body = .note("Nothing open. The queue is clear.")
            return
        }
        let rows = prs.prefix(HelmModuleCard.maxPeekRows).map { pr -> HelmModulePeekRow in
            let state: HelmModuleRowState
            switch pr.checks {
            case "green": state = .ok
            case "red": state = .bad
            case "pending": state = .warn
            default: state = .idle
            }
            // UI-10: a row is a link to its pull request rather than inert
            // text; the card itself still opens the whole queue.
            let url = URL(string: pr.url)
            return HelmModulePeekRow(state: state, text: pr.displayTitle,
                                     value: pr.checks == "none" ? "No checks" : "Checks \(pr.checks)",
                                     onOpen: url.map { url in { WebNavigationPolicy.openExternally(url, from: "Home's merge queue") } },
                                     openHelp: pr.number.map { "Open pull request #\($0)" } ?? "Open the pull request")
        }
        content.body = .peekRows(Array(rows))
        // The reference's footer, and the reason it is worth having: this
        // card shows at most `maxPeekRows` of however many are open, and
        // until now it said so nowhere. "Showing 3 of 33" is the difference
        // between a queue with three PRs in it and a queue whose first three
        // are on screen, which a captain glancing at the hub cannot
        // otherwise tell.
        //
        // Only when there is genuinely more than the card is showing - a
        // footer reading "Showing 2 of 2" is furniture.
        if prs.count > rows.count {
            content.footer = HelmModuleCard.Footer(
                caption: "Showing \(rows.count) of \(prs.count)",
                actionTitle: "All \(prs.count) open",
                handler: { [weak self] in self?.onOpenDestination?(.review) })
        }
    }
}
