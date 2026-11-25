// Grand Line - native macOS app.
//
// What a sentence calls a destination.
//
// R2-BUG-06: copy written for the floating bar kept naming its map after the
// sidebar layout became the default. Review's failure block said "set the
// firstmate home again on Bootstrap", Updates' rows said "Install in
// Bootstrap", Kubernetes said "Open Hosts", Home's Fleet card said "Point
// Grand Line at your firstmate home in Settings" (Settings never had that
// field), and the attention row said "Open Setup" - four names for one place,
// which is Setup › Setup steps. Every navigation sentence now asks this file,
// and `NavigationCoherenceSelfTest.checkCopyNamesPlacesThroughPlaceName` fails
// the run on a literal "Open Bootstrap", "on Hosts" or "in Settings" coming
// back. P-03 of the 2026-11-25 review removed the floating bar, so the
// sidebar's names are the only ones.

import Foundation

enum PlaceName {

    /// Where `route` is, for a sentence: "Setup › Setup steps".
    static func of(_ route: RailDestination) -> String {
        guard let row = ModuleTable.descriptor(for: route) else { return route.title }
        // R5-UX-04 / R5-UX-05: a listed door row is a place of its own
        // (the Calendar, a Personal Notebook), so it is named as the
        // sidebar names it rather than as the tab behind it.
        if let door = row.door, !AppSettings.shared.hiddenModules.contains(door) { return door.title }
        let module = row.module.title
        guard let child = row.child, child != module else { return module }
        return "\(module) \u{203A} \(child)"
    }

    /// The page's own name, for a button whose context already says which
    /// module it is in: "Setup steps".
    static func short(_ route: RailDestination) -> String {
        guard let row = ModuleTable.descriptor(for: route) else { return route.title }
        return row.child ?? row.module.title
    }
}
