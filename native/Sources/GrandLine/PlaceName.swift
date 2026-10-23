// Grand Line - native macOS app.
//
// What a sentence calls a destination, in the window layout that is running.
//
// R2-BUG-06: copy written for the floating bar kept naming its map after the
// sidebar layout became the default. Review's failure block said "set the
// firstmate home again on Bootstrap", Updates' rows said "Install in
// Bootstrap", Kubernetes said "Open Hosts", Home's Fleet card said "Point
// Grand Line at your firstmate home in Settings" (Settings never had that
// field), and the attention row said "Open Setup" - four names for one place,
// which is Setup › Setup steps in the sidebar layout and Bootstrap in the
// floating bar. Every navigation sentence now asks this file, and
// `NavigationCoherenceSelfTest.checkCopyNamesPlacesThroughPlaceName` fails the
// run on a literal "Open Bootstrap", "on Hosts" or "in Settings" coming back.

import Foundation

enum PlaceName {

    /// The layout this process's window runs. A change in Settings takes
    /// effect at the next launch (`AppSettings.workspaceLayout`), so this is
    /// read once, the way the app delegate reads it to pick the shell.
    static var layout: WorkspaceLayout = AppSettings.shared.workspaceLayout

    /// Where `route` is, for a sentence: "Setup › Setup steps" in the
    /// sidebar layout, "Bootstrap" in the floating bar.
    static func of(_ route: RailDestination) -> String {
        switch layout {
        case .floatingBar:
            return route.title
        case .sidebar:
            guard let row = ModuleTable.descriptor(for: route) else { return route.title }
            let module = row.module.title
            guard let child = row.child, child != module else { return module }
            return "\(module) \u{203A} \(child)"
        }
    }

    /// The page's own name, for a button whose context already says which
    /// module it is in: "Setup steps" in the sidebar layout, "Bootstrap" in
    /// the floating bar.
    static func short(_ route: RailDestination) -> String {
        switch layout {
        case .floatingBar:
            return route.title
        case .sidebar:
            guard let row = ModuleTable.descriptor(for: route) else { return route.title }
            return row.child ?? row.module.title
        }
    }
}
