// Grand Line - native macOS app.
//
// `NavigationHistory` - the sidebar shell's Back and Forward (stage 3 of the
// modular-shell migration).
//
// The floating bar's drill header had one way back: its chevron went to Home.
// The sidebar shell's toolbar has real Back and Forward buttons instead, the
// way Finder and Safari do, so this keeps the two stacks they walk.
//
// It records what the workspace says is showing - the same
// `RecentDestinationKind` every navigation funnels through
// (`Navigator.updateRecentDestinations`) - and nothing else, so a page reached
// from the sidebar, ⌘K, a notification or a Home card all land in it the same
// way. Walking it goes back through `Navigator.navigateToRecentDestination`,
// the dispatch Recents already uses, so a host page is switched to or
// reconnected exactly as a Recents click would.
//
// Pure logic: a value type with no AppKit, asserted by
// `NavigationHistorySelfTest` in CI's blocking lane.

import Foundation

/// R2-UX-08: a page with places of its own that Back and Forward should walk
/// - Settings' categories, which had their own pair of arrows inside the page
/// beside the window's. The page names where it is as a string, the shell
/// records it with the destination, and walking back to it asks the page to
/// go there again.
protocol WorkspaceHistoryPlace: AnyObject {
    /// Where the page is now.
    var historyPlace: String { get }
    /// Go back to a place `historyPlace` once named. Reports the arrival
    /// through `onHistoryPlaceChanged`, as any other move would.
    func showHistoryPlace(_ place: String)
    /// Set by the shell: the page moved to a new place.
    var onHistoryPlaceChanged: (() -> Void)? { get set }
}

struct NavigationHistory {

    /// GL-35: nothing unbounded. Fifty steps back is far more than anyone
    /// walks, and the oldest entries fall off first.
    static let limit = 50

    enum Step: Equatable {
        case back
        case forward
    }

    /// One step: a destination, and where inside it for a page that keeps
    /// places of its own (`WorkspaceHistoryPlace`). `place` is nil for
    /// every other page.
    struct Entry: Equatable {
        var kind: RecentDestinationKind
        var place: String?

        var identityKey: String { place.map { "\(kind.identityKey)#\($0)" } ?? kind.identityKey }

        /// Whether an arrival names this entry. An arrival with no place is
        /// the shell reporting the destination before it knows the page's
        /// place, so it matches any place on that destination.
        func isArrival(_ other: Entry) -> Bool {
            kind.identityKey == other.kind.identityKey && (other.place == nil || other.place == place)
        }
    }

    /// Older steps, most recent last.
    private(set) var backEntries: [Entry] = []
    /// Steps walked back from, the next one last.
    private(set) var forwardEntries: [Entry] = []
    /// What is showing now.
    private(set) var currentEntry: Entry?

    /// The destinations alone, for a reader that does not care about places.
    var back: [RecentDestinationKind] { backEntries.map(\.kind) }
    var forward: [RecentDestinationKind] { forwardEntries.map(\.kind) }
    var current: RecentDestinationKind? { currentEntry?.kind }

    /// Set just before the shell walks a step, so the arrival that walk
    /// causes moves along the stacks instead of being recorded as a new visit.
    private var expected: Step?

    var canGoBack: Bool { !backEntries.isEmpty }
    var canGoForward: Bool { !forwardEntries.isEmpty }

    /// Where Back would go, or nil.
    var backTarget: Entry? { backEntries.last }
    /// Where Forward would go, or nil.
    var forwardTarget: Entry? { forwardEntries.last }

    /// The workspace reports what is showing now, and where inside it when the
    /// page keeps places.
    ///
    /// Re-showing the step that is already current changes nothing (a host
    /// page can be revealed again after a rename, so its label is refreshed).
    /// An arrival that matches the step the shell is walking moves one entry
    /// across; any other arrival is a new visit, which is what clears Forward.
    mutating func arrive(_ kind: RecentDestinationKind, place: String? = nil) {
        defer { expected = nil }
        let arrival = Entry(kind: kind, place: place)
        if let current = currentEntry, current.isArrival(arrival) {
            currentEntry?.kind = kind
            return
        }
        // The page names its place before the shell settled one: that is
        // this step's place, not a second visit.
        if let current = currentEntry, current.place == nil, current.kind.identityKey == kind.identityKey {
            currentEntry = arrival
            return
        }
        switch expected {
        case .back? where backEntries.last?.isArrival(arrival) == true:
            let entry = backEntries.removeLast()
            if let currentEntry { forwardEntries.append(currentEntry) }
            currentEntry = Entry(kind: kind, place: place ?? entry.place)
        case .forward? where forwardEntries.last?.isArrival(arrival) == true:
            let entry = forwardEntries.removeLast()
            if let currentEntry { backEntries.append(currentEntry) }
            currentEntry = Entry(kind: kind, place: place ?? entry.place)
        default:
            if let currentEntry { backEntries.append(currentEntry) }
            forwardEntries.removeAll()
            currentEntry = arrival
        }
        if backEntries.count > Self.limit { backEntries.removeFirst(backEntries.count - Self.limit) }
        if forwardEntries.count > Self.limit { forwardEntries.removeFirst(forwardEntries.count - Self.limit) }
    }

    /// The page that just arrived says where it is. Fills in the current
    /// step's place when the arrival could not know it yet, and never
    /// records a visit of its own.
    mutating func settlePlace(_ place: String) {
        guard currentEntry != nil, currentEntry?.place == nil else { return }
        currentEntry?.place = place
    }

    /// The shell is about to navigate to `backTarget` or `forwardTarget`.
    mutating func expect(_ step: Step) {
        expected = step
    }

    /// The walk is over. If the target never arrived - a host that was
    /// deleted, say - it is dropped, so the button does not keep offering a
    /// page it cannot reach.
    mutating func finishStep(_ step: Step, arrived: Bool) {
        expected = nil
        guard !arrived else { return }
        switch step {
        case .back: if !backEntries.isEmpty { backEntries.removeLast() }
        case .forward: if !forwardEntries.isEmpty { forwardEntries.removeLast() }
        }
    }
}
