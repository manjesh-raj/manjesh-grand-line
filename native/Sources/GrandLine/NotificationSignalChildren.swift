// Grand Line - native macOS app.
//
// `fm/grandline-notification-ambient-expand-fix`: the one mapping from "a
// pending tool / a fork that is behind" to the expandable popover's child
// rows.
//
// There are two producers of each of those two signals, and before this file
// only one of them could build children at all. The Updates and GitHub Sync
// pages build them from their own rows; `BackgroundSignalsPoller`'s ambient
// pass builds them from the outcomes its own sweep already had in hand. The
// captain sees the ambient one first - it is what populates the popover at
// launch, before either page has ever been mounted - so the two must agree
// about what counts as pending and about how a child reads, or the same
// notification changes shape the moment a page is visited.
//
// The filter is deliberately the same predicate the counting rule uses
// (`showsUpdateButton` / `showsSyncButton`, the ones
// `BackgroundSignalsPoller.toolUpdateCount`/`forkDriftCount` apply), so the
// children can never list more or fewer items than the title counts.

import Foundation

/// Builds the `AppNotificationChild` rows for the two expandable engineering
/// signals. Pure mapping - it starts nothing and knows nothing about pages.
enum NotificationSignalChildren {

    /// One tool, as both producers already hold it: the catalog item's id and
    /// name, plus the status and the ready-to-render detail line that a check
    /// (cached or live) produced.
    struct Tool {
        let id: String
        let name: String
        let status: DependencyStatus
        /// `CheckOutcome.detail` / `UpdateRow.detail` - the version pair.
        let detail: String
    }

    /// One fork, same shape: `GitHubSyncCheckOutcome.detail` is the
    /// "12 commits behind kunchenguid/gh-axi" line the row shows.
    struct Fork {
        let id: String
        let name: String
        let status: GitHubSyncStatus
        let detail: String
    }

    /// The tools that are offering an Update, in catalog order.
    ///
    /// `perform` takes the tool's id rather than a closure per row because the
    /// ambient producer has no row to capture - it hands the id back to the
    /// shell, which shows the Updates page and runs that tool's real update
    /// there. The page's own producer passes the same routing method.
    static func tools(_ tools: [Tool],
                      perform: @escaping (String) -> Void) -> [AppNotificationChild] {
        tools.filter { $0.status.showsUpdateButton }.map { tool in
            AppNotificationChild(id: tool.id, name: tool.name, meta: tool.detail,
                                 actionLabel: "Update", isMonospaced: true,
                                 perform: { perform(tool.id) })
        }
    }

    /// The forks that are offering a Sync, **furthest behind first** - which
    /// is also what the notification's own detail line names ("Furthest
    /// behind: …"), so the ordering is load-bearing rather than cosmetic.
    static func forks(_ forks: [Fork],
                      perform: @escaping (String) -> Void) -> [AppNotificationChild] {
        forks.filter { $0.status.showsSyncButton }
            .sorted { behindCount($0.status) > behindCount($1.status) }
            .map { fork in
                AppNotificationChild(id: fork.id, name: fork.name, meta: fork.detail,
                                     actionLabel: "Sync",
                                     perform: { perform(fork.id) })
            }
    }

    /// How far behind a status is, for the ordering above - `0` for every
    /// status that carries no count, which keeps the sort total without
    /// pretending a `.syncFailed` is "0 behind" anywhere else.
    static func behindCount(_ status: GitHubSyncStatus) -> Int {
        if case .behind(let n) = status { return n }
        return 0
    }
}
