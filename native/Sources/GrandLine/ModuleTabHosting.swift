// Grand Line - native macOS app.
//
// `ModuleTabHosting` - a page whose own tabs are its module's tabs in the
// sidebar layout (stage 4 of the modular-shell migration).
//
// Four pages draw a tab control of their own that the module table lists as
// the module's children (`WorkspaceModule.pageTabHost`):
//
//   - Shift's Board, List and Review are Tasks' three tabs,
//   - the Calendar page's Month, Week, Day and Agenda are its own four,
//   - the Fleet page's Dashboard and Log are Crew's In flight and Log, and
//     its sidebar-only Needs you is Crew's first tab,
//   - the Hosts page's Hosts, SSH Keys and Snippets are Connections' Hosts,
//     Keys and Snippets,
//   - Kubernetes' Cluster and Log Tail are its own two.
//
// In the sidebar layout the window toolbar draws a module's tabs, so the page
// hides its own control there and the toolbar drives it through this
// protocol. The floating bar never calls any of it, so in that layout the
// page looks and works exactly as it always has.
//
// The page keeps doing the switching. A toolbar click lands in the same
// method the page's own control reaches, and a switch the page makes by
// itself (a menu verb, ⌘K, a notification's Show in app) reports back through
// `onModuleTabChanged`, so the toolbar follows whichever way the tab changed.

import AppKit

protocol ModuleTabHosting: AnyObject {
    /// The module children this page's own tabs answer to, in its own order.
    var moduleTabNames: [String] { get }
    /// The showing tab, by its module child name.
    var selectedModuleTabName: String { get }
    /// Show the tab with this module child name, through the same path a click
    /// on the page's own control takes.
    func selectModuleTab(named name: String)
    /// Called after the page switched tab, by any route.
    var onModuleTabChanged: (() -> Void)? { get set }
    /// Hide the page's own tab control, which the toolbar replaces in the
    /// sidebar layout, or show it again.
    func setModuleTabControlHidden(_ hidden: Bool)
    /// How many records each tab holds, by module child name, for the
    /// toolbar to draw beside the tab's name (stage 6: Connections' "Hosts 3").
    /// A tab with no entry draws its name alone. A page reports a change
    /// through `onModuleTabChanged`.
    var moduleTabCounts: [String: Int] { get }
}

extension ModuleTabHosting {
    /// Most pages count nothing on their tabs.
    var moduleTabCounts: [String: Int] { [:] }
}
