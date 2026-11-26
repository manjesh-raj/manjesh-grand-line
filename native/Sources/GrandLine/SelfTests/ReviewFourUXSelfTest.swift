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
}

#endif
