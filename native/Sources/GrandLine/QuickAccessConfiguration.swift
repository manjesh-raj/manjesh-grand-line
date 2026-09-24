// Grand Line - native macOS app.
//
// `QuickAccessConfiguration` - which destinations the floating bar's shortcut
// row carries, and in what order.
//
// Review #3's UX1 and UX2 are one finding seen from two sides, so they get one
// implementation:
//
//   - UX2: "the quick-access row is append-only and now ten icons wide […] its
//     order is history rather than frequency. *Direction:* cap at six visible
//     with an overflow menu; let the captain reorder."
//   - UX1: "make the quick-access row user-configurable (drag to pin/unpin,
//     the same `DaylightDestinationButton` list persisted in `AppSettings`)
//     rather than append-only by captain request".
//
// Before this, the row was seven `private let` stored properties in
// `DaylightBarController` with a hand-written constraint chain between them, so
// "add a shortcut" was a source edit and "reorder" was not expressible at all.
// `DaylightBarController`'s own comment recorded the consequence honestly: "a
// new icon **appends** to the trailing end of this group rather than being
// slotted in by topic". That rule existed to protect muscle memory, and it is
// the right rule *for a list nobody can edit*. Once the captain owns the list,
// the rule it replaces is better: nothing moves unless they move it.
//
// **The default is exactly the seven that shipped, in exactly their shipped
// order.** A captain who never opens the overlay sees precisely the bar they
// had - this is the migration, not a redesign. `visibleLimit` is what changes
// for them: the seventh icon moves into the overflow menu rather than off the
// end of the bar.

import Foundation

/// The pinned shortcut row, as a value.
///
/// `Codable` over the destinations' own `String` raw values, which is the same
/// stable-identity argument `RailDestination`'s own header makes for session
/// restore: a renamed case invalidates the saved order rather than silently
/// restoring the wrong page.
struct QuickAccessConfiguration: Codable, Equatable {
    /// UX2's cap. Six icon squares cost 6 x (34 + 8) = 252pt of a bar that
    /// also carries the drill cluster, the search pill, Recents, the theme
    /// toggle, the bell and the avatar - the measurement in
    /// `DaylightBarController.quickAccessCollapseWidth`'s own doc comment,
    /// which found seven already too many at 1300pt.
    ///
    /// Anything pinned past this is reachable from the overflow menu, in the
    /// captain's own order, rather than being dropped.
    static let visibleLimit = 6

    /// The seven the bar shipped with, in the order they shipped in - see this
    /// file's header for why the default is a migration rather than a
    /// redesign.
    static let defaultPinned: [RailDestination] = [
        .stickyBoard, .codePreview, .shift, .strawHat, .poneglyph, .console, .hosts,
    ]

    private(set) var pinned: [RailDestination]

    init(pinned: [RailDestination] = QuickAccessConfiguration.defaultPinned) {
        self.pinned = QuickAccessConfiguration.sanitised(pinned)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case pinned }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // GL-01: `decodeIfPresent` plus a default, so an older file (or a
        // newer one that drops the key) decodes rather than making the whole
        // value undecodable.
        let raw = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
        // An unknown raw value is a destination this build does not have -
        // a case renamed, or a downgrade. Dropping it silently is right here
        // (unlike a store of the captain's own data): the row is a view onto
        // an enum this build defines, and an entry it cannot resolve has
        // nothing to point at.
        self.pinned = QuickAccessConfiguration.sanitised(raw.compactMap(RailDestination.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pinned.map(\.rawValue), forKey: .pinned)
    }

    // MARK: Derived

    /// What the bar draws as real icon squares.
    var visible: [RailDestination] { Array(pinned.prefix(Self.visibleLimit)) }

    /// What the overflow menu lists *in addition* to the visible icons, while
    /// the bar is wide enough to show the row at all.
    ///
    /// Empty for a captain who pins six or fewer, which is what makes the
    /// overflow button disappear entirely rather than opening an empty menu.
    var overflow: [RailDestination] { Array(pinned.dropFirst(Self.visibleLimit)) }

    func contains(_ destination: RailDestination) -> Bool { pinned.contains(destination) }

    // MARK: Mutation

    /// Pin a destination (appending, so a new pin never displaces one the
    /// captain already reads at a fixed position) or unpin it.
    ///
    /// Returns a new value rather than mutating in place, so a caller cannot
    /// half-apply a change and then fail to persist it.
    func toggling(_ destination: RailDestination) -> QuickAccessConfiguration {
        var next = pinned
        if let index = next.firstIndex(of: destination) {
            next.remove(at: index)
        } else {
            next.append(destination)
        }
        return QuickAccessConfiguration(pinned: next)
    }

    /// Move the destination at `from` to `to`, for a drag inside the row.
    ///
    /// Out-of-range indices are a no-op rather than a crash: the caller is a
    /// drag session, and a drop can genuinely land after the model changed
    /// underneath it.
    func moving(from: Int, to: Int) -> QuickAccessConfiguration {
        guard pinned.indices.contains(from), to >= 0, to <= pinned.count, from != to else { return self }
        var next = pinned
        let moved = next.remove(at: from)
        next.insert(moved, at: min(to > from ? to - 1 : to, next.count))
        return QuickAccessConfiguration(pinned: next)
    }

    /// De-duplicate while preserving first-seen order.
    ///
    /// A duplicate is not hypothetical - a drag that races a pin from the
    /// overlay can produce one - and two icon squares for one destination is
    /// a row that cannot be reasoned about (which one does the active
    /// highlight light?).
    ///
    /// **An empty row is allowed and is not reset to the default.** "I want no
    /// shortcuts" is a real preference, and silently restoring seven icons
    /// because the captain unpinned the last one would be the app overruling
    /// them.
    private static func sanitised(_ destinations: [RailDestination]) -> [RailDestination] {
        var seen: Set<RailDestination> = []
        return destinations.filter { seen.insert($0).inserted }
    }
}
