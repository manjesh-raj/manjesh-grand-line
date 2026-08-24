// Manjesh Grand Line - native macOS app.
//
// Daylight §6.4's "`caption()` subtitle with live numbers", for the one
// destination whose numbers depend on which of four sub-pages is showing.
//
// **Why a protocol rather than a switch in `SetupContainerController`.** The
// container already holds all four pages concretely, so a `switch activeTab`
// would compile - but it would also mean the container had to know what each
// page counts, which is exactly the coupling `DestinationRegistry`'s own
// `DaylightDrillActions` seam was introduced to avoid one level up. Here the
// container asks the showing page for one already-composed line and knows
// nothing about updates, drift, forks or steps.
//
// **No new work, in any implementation.** Every line below is derived from
// state its page has already computed and is already rendering somewhere: the
// row/status arrays behind `UpdatesController`'s own stat tiles,
// `BootstrapController`'s and `AutomationController`'s in-memory stepper
// state, and `GitHubSyncController`'s row statuses. Nothing here checks,
// polls, shells out or reads a file - a subtitle that fired a `brew` sweep on
// every tab switch would be a far worse bug than a missing subtitle.
//
// Honesty rule, carried over from Phase 3's loading-state work: a page that
// has not finished its first check says so ("checking…") rather than
// reporting a confident zero it has not earned.

import AppKit

/// One Setup sub-page's live one-liner for the drill header.
protocol SetupPageSummary: AnyObject {
    /// Already composed, already-known numbers. Never a fresh check.
    var setupSummaryLine: String { get }

    /// Set by `SetupContainerController` - "my numbers moved, re-read me".
    /// The header belongs to the shell (see `HelmDrillHeader`'s own note on
    /// why), so a page tells the container rather than writing to it.
    var onSetupSummaryChanged: (() -> Void)? { get set }
}
