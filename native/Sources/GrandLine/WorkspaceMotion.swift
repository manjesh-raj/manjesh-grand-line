// Grand Line - native macOS app.
//
// The sidebar layout's motion (the modular-shell migration's polish), from the
// prototype's transitions, on the app's one motion table (`HelmMotion.swift`'s
// header). Nothing here has a number of its own: every duration is a row of
// that table, and every path lands its end state at once under Reduce Motion.
//
// | Prototype                                 | Here                                         |
// |-------------------------------------------|----------------------------------------------|
// | the sidebar's width, 200ms                | `paneDuration` (move, 180ms)                 |
// | the inspector sliding in 16px, 220ms      | `inspectorEntrance` (move, 180ms, 16pt)      |
// | a module or tab's content entering, 220ms | the page change's own entrance, on a tab too |
// | a row's hover and selection fill, 120ms   | `HelmRowWash` (state, 120ms)                 |
// | a card's hover lift, 120ms                | `HelmModuleCard`'s lift, unchanged           |
//
// The prototype's 200 and 220ms are not new rows: the table's move row is what
// every travelling thing in this app takes, and a page change in the floating
// bar already uses it. Two curves only - the ease-out everywhere here.
//
// A module switch was already animated in both layouts: it is a navigation,
// and every navigation fades the outgoing page (`PageCrossfade`) and eases the
// incoming one in (`WorkspaceContent.animateDestinationEntrance`). What this
// layout adds is the same motion for a switch that is not a navigation - one
// of a page's own tabs, or one of Home's spaces - where the page stays and its
// content changes under it.

import AppKit

enum WorkspaceMotion {

    /// The sidebar and the inspector collapsing and expanding.
    static let paneDuration: TimeInterval = HelmMotion.moveDuration

    /// The inspector's panel arriving as the pane opens, or as it changes to
    /// another page's details.
    static let inspectorEntranceDuration: TimeInterval = HelmMotion.moveDuration
    /// How far it travels in from the trailing edge - the prototype's 16px.
    static let inspectorEntranceOffset: CGFloat = 16

    /// A tab or a space arriving: the page change's own move.
    static let tabDuration: TimeInterval = WorkspaceContent.destinationTransitionDuration

    /// Collapse or expand `item`, easing it when `animated` and Reduce Motion
    /// is off, and run `completion` once the pane has its new state. Returns
    /// the duration it eased over, or nil when it landed at once - which is
    /// what the sidebar layout records for its suite.
    @discardableResult
    static func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool, animated: Bool,
                             completion: @escaping () -> Void) -> TimeInterval? {
        guard animated, !HelmMotion.isReduced else {
            item.isCollapsed = collapsed
            completion()
            return nil
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = paneDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            item.animator().isCollapsed = collapsed
        }, completionHandler: completion)
        return paneDuration
    }

    /// Slide `view` in from the trailing edge with a fade. Layer properties
    /// only, so it never moves a frame Auto Layout owns; nothing at all under
    /// Reduce Motion.
    static func slideIn(_ view: NSView) {
        view.wantsLayer = true
        guard !HelmMotion.isReduced, let layer = view.layer else { return }
        HelmMotion.withoutActions {
            layer.opacity = 0
            layer.transform = CATransform3DMakeTranslation(inspectorEntranceOffset, 0, 0)
        }
        HelmMotion.animateLayers(duration: inspectorEntranceDuration, on: [layer]) {
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
        }
    }
}
