// Grand Line - native macOS app.
//
// How a page draws itself in the sidebar layout - the later page work of the
// modular-shell migration (the host table and its inspector, the credential
// table and Crew's Needs you), and the pages stage 7 redesigned (Tasks and
// Setup's four tabs). Knowledge's tree was here too until stage 7 removed it.
//
// The floating bar and the sidebar layout host the same 29 page controllers
// (`Workspace`). A redesigned page keeps its floating-bar presentation exactly
// as it was, and switches to its sidebar one when the sidebar shell first
// shows it. The layout is chosen at launch (`AppSettings.workspaceLayout`), so
// a page lives its whole life in one presentation: nothing here ever switches
// back.
//
// Two small protocols rather than one, because they are separate decisions:
// Crew's Needs you is a new view with nothing to inspect, and a page could
// fill the inspector without drawing anything differently.

import AppKit

/// A page that draws itself differently in the sidebar layout.
protocol SidebarLayoutAdopting: AnyObject {
    /// Switch to the sidebar layout's presentation. Called once, the first
    /// time the sidebar shell shows the page, and never in the floating bar.
    func adoptSidebarLayout()
}

/// What the sidebar shell's inspector shows for the page's selection.
struct WorkspaceInspectorContent {
    /// The inspector's own title line, which names the selected item.
    let title: String
    /// The details. The page owns the view and keeps it filled; the inspector
    /// only hosts it.
    let view: NSView
    /// The view fills the pane under the title line and scrolls itself (it
    /// has a footer of its own, say), rather than being scrolled by the pane.
    var fillsPane = false
}

/// A page whose selected item's details go in the sidebar shell's inspector,
/// where the page's own detail column was in the floating bar.
protocol WorkspaceInspectorSource: AnyObject {
    /// The selected item's details, or `nil` when nothing is selected.
    var inspectorContent: WorkspaceInspectorContent? { get }
    /// What the inspector says when the captain opens it with nothing
    /// selected.
    var inspectorEmptyText: (title: String, body: String) { get }
    /// Called whenever `inspectorContent` may have changed: a new selection,
    /// a tab switch, or a store change under the selected item.
    var onInspectorContentChanged: (() -> Void)? { get set }
    /// The page asking the shell to open the inspector, as the captain's own
    /// request would - a row's Show in Inspector, or a double click.
    var onShowInspector: (() -> Void)? { get set }
    /// Whether the inspector may close now. A page with an edit in progress
    /// (H11: a host form with unsaved changes) asks the captain first, and
    /// answers `false` if they cancel.
    func inspectorShouldClose() -> Bool
}

extension WorkspaceInspectorSource {
    func inspectorShouldClose() -> Bool { true }
}

/// A page with one primary action, which the sidebar layout draws at the
/// toolbar's trailing edge after Search, as the prototype does (stage 6):
/// Connections' Add Host, New Key and New Snippet, Logs' Analyze, Health's
/// Copy diagnostics. The view is one of the page's own buttons, with the
/// target and tooltip the page set on it, exactly like its
/// `drillHeaderActions`. The shell leaves it out of the page's other actions,
/// and the floating bar never asks.
protocol WorkspacePrimaryActionProviding: AnyObject {
    /// The page's primary action right now, or `nil`. Re-read whenever the
    /// page says its actions may have changed.
    var workspacePrimaryAction: NSView? { get }
}
