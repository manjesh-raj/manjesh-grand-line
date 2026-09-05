// Manjesh Grand Line - native macOS app.
//
// `RecentDestinations` - the app's one answer to "where was I recently,
// before I ended up here" (`fm/grandline-recents-navigation`).
//
// The captain's own problem statement: he jumps Command -> Console, then
// wanders off through Updates, Sticky Board, Vault, etc., and once a few
// destinations deep there is no quick way back to where he actually was
// working. He reviewed four approaches (a full back/forward history stack, a
// single "go back one step" toggle, a small "Recents" dropdown, a keyboard-
// shortcut-only version) and chose the dropdown - a small button opening a
// short list of recently-visited destinations, click any entry to jump
// straight there. He also corrected the reviewed mockup's placement: the
// button sits after the space pills (`DaylightBarController`), not next to
// the "Grand Line" logo.
//
// **It is a registry, not a monitor** - the same shape (and for the same
// reason) as `HostSessionRegistry`: it records nothing on its own. The one
// writer is `AppShellController`, from the two places it already funnels
// every real navigation through - `show(_:)` for a `RailDestination`, and
// `revealHostConsole` (the shared tail of both a fresh `connectHost` and
// `switchToSession`) for a saved host's own dedicated page, which is NOT a
// `RailDestination` case at all. A second writer would be a second source of
// truth again.
//
// **What gets recorded is the destination being LEFT, never the one being
// entered.** `recordNavigation(leaving:arriving:)` inserts `leaving` (if any,
// and if it genuinely differs from `arriving`) at the top of the list, and
// unconditionally removes `arriving` from the list if it was already there.
// That single rule is what makes three things true at once, all for free,
// with no special-casing at any call site:
//   - the list never contains the destination currently on screen, so a
//     captain opening this dropdown never sees "where I already am" pinned
//     at the top - the exact self-reference a naive "record where I just
//     navigated to" model would produce the moment a captain revisited an
//     already-recorded place;
//   - re-showing the same destination (a stray click on an already-selected
//     quick-access icon, switching between canvas spaces while staying on
//     `.homeCanvas`) manufactures no entry at all, since `leaving ==
//     arriving` short-circuits the insert;
//   - revisiting an already-recent destination moves it to the top rather
//     than adding a second row - the captain's own explicit requirement -
//     because the very next navigation away from it re-inserts it fresh,
//     and the dedup-by-identity removal already cleared its old position.
//
// **Deliberately NOT merged with `HostSessionRegistry`/the session strip.**
// That answers a narrower, different question - "which hosts have a live SSH
// session right now" - and is tied to a running process; this is a plain
// visit log with no notion of "still open" at all. A host page the captain
// closed still shows here until it ages out of the cap, same as any other
// destination.
//
// **In-memory only, deliberately.** The captain's own scoping call was that
// this does not need to survive a relaunch, matching `HostSessionRegistry`
// (also purely in-memory) - a short trail of "where was I a moment ago" has
// no value once the app has been quit and relaunched.
//
// Thread contract: main thread only, like every other observable in this
// app's chrome - `dispatchPrecondition` says so rather than leaving it to
// convention.

import Foundation

/// One destination the captain can navigate to and back from - either a
/// fixed `RailDestination` or a saved host's own dedicated page (which has
/// no `RailDestination` case of its own; see `AppShellController.
/// revealHostConsole`).
enum RecentDestinationKind: Equatable {
    case rail(RailDestination)
    case host(id: UUID, label: String)

    /// Dedup identity. A host page is identified by its id, never its
    /// (possibly stale, possibly renamed) label - a rename between visits
    /// must still be recognised as "the same destination".
    var identityKey: String {
        switch self {
        case .rail(let dest): return "rail:\(dest)"
        case .host(let id, _): return "host:\(id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .rail(let dest): return dest.title
        case .host(_, let label): return label
        }
    }

    /// The row's badge glyph - a saved host's own dedicated page borrows
    /// `.hosts`'s, the same glyph `revealHostConsole` already puts in that
    /// page's own drill header, rather than inventing a second one.
    var symbol: String {
        switch self {
        case .rail(let dest): return dest.symbol
        case .host: return RailDestination.hosts.symbol
        }
    }

    var hue: HelmDomainHue {
        switch self {
        case .rail(let dest): return dest.domainHue
        case .host: return RailDestination.hosts.domainHue
        }
    }

    /// A row's kicker - which space this destination belongs to, read from
    /// the module table rather than a second copy of that mapping (per
    /// `DaylightModule.space(forDestination:)`'s own "one mapping, not two
    /// that can disagree" doc comment). Falls back to "Overview" for the two
    /// destinations no module opens (`.homeCanvas`/`.overview` themselves).
    var kicker: String {
        switch self {
        case .rail(let dest): return DaylightModule.space(forDestination: dest)?.title ?? "Overview"
        case .host: return "Hosts"
        }
    }
}

/// One recorded visit.
struct RecentDestinationEntry {
    let kind: RecentDestinationKind
    let visitedAt: Date

    /// "just now" / "4m ago" / "2h 05m ago" - the same wording and whole-
    /// minute resolution as `HostSession.durationText`, since this string is
    /// likewise rendered in a popover rebuilt on open and on registry change
    /// rather than on a timer, so a seconds-precise value would be visibly
    /// stale within a second of being drawn.
    func relativeTimeText(now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(visitedAt)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return String(format: "%dh %02dm ago", hours, minutes % 60)
    }
}

/// The app's one recency tracker across every destination - rail or host
/// page alike. See this file's header for the full design.
final class RecentDestinations {
    /// The captain's own scoping call: "4-5 recent entries is about right,
    /// not a long history browser".
    static let capacity = 5

    private(set) var entries: [RecentDestinationEntry] = []
    private var observers: [UUID: (RecentDestinations) -> Void] = [:]

    /// Records a navigation.
    ///
    /// - Parameters:
    ///   - leaving: whatever was on screen right before this navigation -
    ///     `nil` for the app's very first navigation of the session, in
    ///     which case there is nothing to record yet.
    ///   - arriving: the destination now on screen.
    ///   - date: injectable for tests; defaults to now.
    func recordNavigation(leaving: RecentDestinationKind?, arriving: RecentDestinationKind, at date: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let leaving, leaving.identityKey != arriving.identityKey {
            entries.removeAll { $0.kind.identityKey == leaving.identityKey }
            entries.insert(RecentDestinationEntry(kind: leaving, visitedAt: date), at: 0)
        }
        // The destination now current must never appear in its own "recent"
        // list - true whether or not the `if` above fired (re-showing the
        // same place, or a first-ever navigation).
        entries.removeAll { $0.kind.identityKey == arriving.identityKey }
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        notify()
    }

    // MARK: Observation

    /// Token-based, matching `HostSessionRegistry.observe`/`ThemeManager.
    /// observe` rather than a single overwritable closure - fires
    /// immediately on registration too, so a freshly-built popover is
    /// correct before it is ever opened.
    @discardableResult
    func observe(_ handler: @escaping (RecentDestinations) -> Void) -> UUID {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = UUID()
        observers[token] = handler
        handler(self)
        return token
    }

    func unobserve(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notify() {
        for handler in observers.values { handler(self) }
    }
}
