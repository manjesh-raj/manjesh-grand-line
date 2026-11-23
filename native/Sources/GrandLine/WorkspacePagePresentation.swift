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
    /// The page asking the shell to open the inspector on its details - a
    /// row's Show in Inspector, a double click, or a form like Add Host's.
    /// Unlike the toolbar's inspector button it does not hold the pane open:
    /// it closes with the details, and when the page changes.
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

/// A page control that belongs on the page's own row rather than in the
/// window toolbar: the sidebar layout draws it at the trailing end of the
/// module header, on the subtitle's line (R5-UI-01). For a control that
/// changes how the page itself is laid out, where the window toolbar's room
/// is better spent on the chrome every page shares. Notebook's Source /
/// Split / Preview switch is the one today: in the toolbar beside
/// Knowledge's five tabs it pushed the inspector button into the overflow
/// menu at 1512pt. Like the primary action, the view is one of the page's own
/// controls, the shell leaves it out of the page's other actions, and the
/// floating bar never asks.
protocol WorkspaceHeaderAccessoryProviding: AnyObject {
    /// The control for the header right now, or `nil`. Re-read whenever the
    /// page says its actions may have changed.
    var workspaceHeaderAccessory: NSView? { get }
}

/// A page whose own first content sits directly under the window toolbar
/// when the header line has nothing to say, rather than under S03's empty
/// 32pt slot. Console is the one (`fm/grandline-console-fixes`): it draws no
/// header line at all, so the slot was only ever dead space above its band,
/// which the captain asked to remove. The line still shows the moment it
/// carries a subtitle or a control.
protocol WorkspaceHeaderLineCollapsing: AnyObject {
    var collapsesEmptyHeaderLine: Bool { get }
    /// Whether the page's live subtitle is drawn on the line at all. Tasks
    /// (Tf-2, Cf-4) and the Sticky Board (Sk-1) say what the line said in
    /// their own hero, band or case tag, so a second copy above it was the
    /// duplicate the captain asked to remove. The subtitle is still the
    /// page's summary - the crew panel reads it as the page's context, and
    /// the floating bar's drill header draws it - it is only not repeated on
    /// this line. Defaults to true.
    var drawsSubtitleOnHeaderLine: Bool { get }
}

extension WorkspaceHeaderLineCollapsing {
    var drawsSubtitleOnHeaderLine: Bool { true }
}
