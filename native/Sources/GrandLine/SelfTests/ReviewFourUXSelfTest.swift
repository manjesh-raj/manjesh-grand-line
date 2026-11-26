// Grand Line - native macOS app.
//
// The UX ideas the captain picked from the 2026-11-25 full review (UX-02 to
// UX-28): the half that needs no window.
//
// Each case is one idea's words, model or view, built and laid out without a
// window, so it runs in CI's blocking lane. Where an idea needs real event
// dispatch or the real shell, its check sits in the window-backed suite that
// already mounts that page.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum ReviewFourUXSelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        var ok = true
        checkTheToolbarNamesItsShortcuts(&ok)
        checkSettingsStaysInReach(&ok)
        print(ok ? "ReviewFourUXSelfTest: all checks passed" : "ReviewFourUXSelfTest: FAILED")
        return ok
    }

    // MARK: UX-25

    /// The three shortcut glyphs are named, their tooltips carry the key, the
    /// first week opens on names, and only the glyph items keep a name.
    private static func checkTheToolbarNamesItsShortcuts(_ ok: inout Bool) {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 24 * 60 * 60
        check(WorkspaceToolbar.defaultDisplayMode(saved: nil, labelsWeekStart: start, now: start + 3 * day) == .iconAndLabel,
              "UX-25: the first week does not open on names", &ok)
        check(WorkspaceToolbar.defaultDisplayMode(saved: nil, labelsWeekStart: start, now: start + 8 * day) == .iconOnly,
              "UX-25: names still show after the first week", &ok)
        check(WorkspaceToolbar.defaultDisplayMode(saved: nil, labelsWeekStart: nil, now: start) == .iconOnly,
              "UX-25: a launch that never started the week shows names", &ok)
        check(WorkspaceToolbar.defaultDisplayMode(saved: Int(NSToolbar.DisplayMode.iconOnly.rawValue),
                                                  labelsWeekStart: start, now: start + day) == .iconOnly,
              "UX-25: a mode the captain chose lost to the first week", &ok)

        let hidden: Set<WorkspaceModule> = []
        let chord = WorkspaceGoMenu.chordText(for: .console, hidden: hidden)
        check(chord != nil && WorkspaceToolbar.shortcutHelp("Go", module: .console, hidden: hidden) == "Go (\(chord ?? ""))",
              "UX-25: Console's tooltip does not end on its key", &ok)
        check(WorkspaceToolbar.shortcutHelp("Open", module: .calendar, hidden: hidden) == "Open (\u{2318}0)",
              "UX-25: the Calendar's tooltip does not name \u{2318}0", &ok)

        let toolbar = WorkspaceToolbar(splitView: NSSplitView(), identifier: "ux25.probe.\(UUID().uuidString)")
        toolbar.toolbar.displayMode = .iconOnly
        let ids: [NSToolbarItem.Identifier] = [WorkspaceToolbar.ItemID.quickConnectConsole,
                                                WorkspaceToolbar.ItemID.quickConnectHosts,
                                                WorkspaceToolbar.ItemID.calendar, WorkspaceToolbar.ItemID.crumb,
                                                WorkspaceToolbar.ItemID.search]
        for id in ids { toolbar.toolbar.insertItem(withItemIdentifier: id, at: toolbar.toolbar.items.count) }
        let items = Dictionary(uniqueKeysWithValues: toolbar.toolbar.items.map { ($0.itemIdentifier, $0) })
        check(items[WorkspaceToolbar.ItemID.quickConnectConsole]?.label == "Console"
                && items[WorkspaceToolbar.ItemID.quickConnectHosts]?.label == "Connections"
                && items[WorkspaceToolbar.ItemID.calendar]?.label == "Calendar",
              "UX-25: the shortcuts are named \(ids.prefix(3).map { items[$0]?.label ?? "-" })", &ok)
        check((items[WorkspaceToolbar.ItemID.quickConnectConsole]?.toolTip ?? "").hasSuffix("(\(chord ?? "?"))")
                && (items[WorkspaceToolbar.ItemID.calendar]?.toolTip ?? "").hasSuffix("(\u{2318}0)"),
              "UX-25: the shortcuts' tooltips do not carry their keys", &ok)
        check(items[WorkspaceToolbar.ItemID.crumb]?.label == "Location",
              "UX-25: icon mode put away the crumb's name, which the overflow menu reads", &ok)
        toolbar.toolbar.displayMode = .iconAndLabel
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(items[WorkspaceToolbar.ItemID.crumb]?.label == "" && items[WorkspaceToolbar.ItemID.search]?.label == ""
                && items[WorkspaceToolbar.ItemID.quickConnectConsole]?.label == "Console",
              "UX-25: Icon and Text names the crumb and Search, or drops Console's name", &ok)
        toolbar.toolbar.displayMode = .iconOnly
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(items[WorkspaceToolbar.ItemID.crumb]?.label == "Location" && items[WorkspaceToolbar.ItemID.search]?.label == "Search",
              "UX-25: going back to icons did not give the view items their names back", &ok)
    }

    // MARK: UX-28

    /// Settings sits in the sidebar's foot, out of the list, lit when it
    /// shows and lined up with the rows above; the list fades only while it
    /// continues below.
    private static func checkSettingsStaysInReach(_ ok: inout Bool) {
        let roots = WorkspaceSidebarModel.roots(sessions: [])
        let listed = roots.flatMap { [$0] + $0.children }.map(\.entry)
        check(!listed.contains(.module(.settings)) && listed.contains(.module(.setup)),
              "UX-28: Settings is still a row in the list, or Setup left with it", &ok)
        check(WorkspaceGoMenu.chord(for: .settings) == WorkspaceGoMenu.chord(for: .settings, hidden: []),
              "UX-28: the foot moved Settings' chord", &ok)

        autoreleasepool {
            let sidebar = WorkspaceSidebarController()
            sidebar.loadView()
            sidebar.view.frame = NSRect(x: 0, y: 0, width: MainSplitShellController.sidebarWidth, height: 360)
            sidebar.view.layoutSubtreeIfNeeded()
            sidebar.viewDidLayout()
            let foot = sidebar.debugFoot
            check(foot.frame.minY <= HelmMetrics.s2 + 0.5 && foot.frame.height > 0,
                  "UX-28: the foot is not at the sidebar's bottom (\(foot.frame))", &ok)
            check(sidebar.debugListFades, "UX-28: a list that continues below does not fade", &ok)
            // The foot's glyph lines up with the rows' glyphs.
            if let row = sidebar.debugCell(for: .module(.home)) as? WorkspaceSidebarPageCell {
                let listX = row.debugIcon.convert(row.debugIcon.bounds, to: sidebar.view).minX
                let footX = foot.debugCell.debugIcon.convert(foot.debugCell.debugIcon.bounds, to: sidebar.view).minX
                check(abs(listX - footX) < 1, "UX-28: the foot's glyph is at x \(footX), the rows' at \(listX)", &ok)
            } else {
                fail("UX-28: the list built no Home row", &ok)
            }
            let scroll = sidebar.debugScrollView
            let documentHeight = sidebar.outlineView.frame.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, documentHeight - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            sidebar.viewDidLayout()
            check(!sidebar.debugListFades, "UX-28: the list still fades scrolled to its end", &ok)
            sidebar.select(.rail(.settings))
            check(foot.debugIsLit && sidebar.outlineView.selectedRow < 0,
                  "UX-28: showing Settings does not light the foot, or lights a list row too", &ok)
            sidebar.select(.rail(.homeCanvas))
            check(!foot.debugIsLit, "UX-28: the foot stays lit on Home", &ok)
            var opened: WorkspaceModule?
            sidebar.onSelectModule = { opened = $0 }
            foot.row.performPrimaryAction()
            check(opened == .settings, "UX-28: the foot did not open Settings", &ok)
        }
    }
}

#endif
