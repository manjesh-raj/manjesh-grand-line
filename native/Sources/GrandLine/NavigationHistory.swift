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

struct NavigationHistory {

    /// GL-35: nothing unbounded. Fifty steps back is far more than anyone
    /// walks, and the oldest entries fall off first.
    static let limit = 50

    enum Step: Equatable {
        case back
        case forward
    }

    /// Older pages, most recent last.
    private(set) var back: [RecentDestinationKind] = []
    /// Pages stepped back from, the next one last.
    private(set) var forward: [RecentDestinationKind] = []
    /// What is showing now.
    private(set) var current: RecentDestinationKind?

    /// Set just before the shell walks a step, so the arrival that walk
    /// causes moves along the stacks instead of being recorded as a new visit.
    private var expected: Step?

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Where Back would go, or nil.
    var backTarget: RecentDestinationKind? { back.last }
    /// Where Forward would go, or nil.
    var forwardTarget: RecentDestinationKind? { forward.last }

    /// The workspace reports what is showing now.
    ///
    /// Re-showing the page that is already current changes nothing (a host
    /// page can be revealed again after a rename, so its label is refreshed).
    /// An arrival that matches the step the shell is walking moves one entry
    /// across; any other arrival is a new visit, which is what clears Forward.
    mutating func arrive(_ kind: RecentDestinationKind) {
        defer { expected = nil }
        if let current, current.identityKey == kind.identityKey {
            self.current = kind
            return
        }
        switch expected {
        case .back? where back.last?.identityKey == kind.identityKey:
            back.removeLast()
            if let current { forward.append(current) }
        case .forward? where forward.last?.identityKey == kind.identityKey:
            forward.removeLast()
            if let current { back.append(current) }
        default:
            if let current { back.append(current) }
            forward.removeAll()
        }
        current = kind
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        if forward.count > Self.limit { forward.removeFirst(forward.count - Self.limit) }
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
        case .back: if !back.isEmpty { back.removeLast() }
        case .forward: if !forward.isEmpty { forward.removeLast() }
        }
    }
}
