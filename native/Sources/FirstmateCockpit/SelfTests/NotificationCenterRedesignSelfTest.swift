// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for the redesigned "Waiting for you" popover
// (`fm/grandline-notification-center-redesign`, captain reference:
// `data/grandline-notification-center-redesign/captain-reference/`) - run via
// `FM_RUN_NOTIFICATION_CENTER_REDESIGN_TESTS=1 .build/debug/FirstmateCockpit`.
//
// **Window-backed on purpose**, and listed in `NEEDS_SESSION` in
// `Scripts/run-all-tests.sh` accordingly. Almost everything the redesign is
// about is a rendered fact rather than a computed one, and AGENTS.md's own
// rule ("assert what is painted, not what was computed") is what decides the
// split here: the hover reveal is a real `HoverHighlightView` tracking-area
// hook, the inset hairline is a real frame measured against the real text
// column, and the two-tier grouping is read out of the live `NSStackView`
// rather than re-derived from the store the panel was handed. A pure-logic
// half exists and stays out of this file: `NotificationTimeText`'s boundaries
// and the store's own read/snooze/mute contract are asserted by
// `GrandLineNotificationCenterSelfTest`, which guards the blocking CI lane.
//
// Every check runs against the real `NotificationCenterController` - the same
// object the top bar owns - mounted in a real `OffScreenProbe` window, because
// a `HoverHighlightView`'s tracking area is `.activeInKeyWindow` and a row
// outside a key window never highlights at all.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum NotificationCenterRedesignSelfTest {

    /// A fixed instant every fabricated entry is dated against, so "3h ago" is
    /// a fact about the fixture rather than about when the suite ran.
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func run() -> Bool {
        var allOK = true
        // AGENTS.md's hermeticity rule: this suite drives
        // `ThemeManager.shared.setTheme`, so it captures the captain's own
        // theme by *reading* `theme` first and restores it on every exit.
        let captainTheme = ThemeManager.shared.theme
        defer {
            ThemeManager.shared.setTheme(captainTheme)
            GrandLineNotificationCenter.shared.resetForTesting()
        }

        for check in [checkTwoTierGrouping,
                      checkHoverAndSelectionSwapTimeForAction,
                      checkExpandCollapse,
                      checkContextMenuMatchesRowState,
                      checkFooterOmitsTheStruckButtons,
                      checkInsetSeparatorStartsAtTheTextColumn,
                      checkFilterCountsAndEmptyStates,
                      checkToastAndUndo,
                      checkKeyboardSelection,
                      checkRendersInBothThemes] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "NotificationCenterRedesignSelfTest: all checks passed"
                    : "NotificationCenterRedesignSelfTest: FAILED")
        return allOK
    }

    // MARK: - Fixture

    /// The reference's own four rows, in this app's own vocabulary: an overdue
    /// task and a drifted setup check under "Needs action", tool updates and
    /// fork drift under "Available", two of them expandable.
    private static func seed() {
        let center = GrandLineNotificationCenter.shared
        center.resetForTesting()
        center.clock = { now }

        center.set(AppNotification(
            id: "shift-due", title: "Renew staging wildcard certificate",
            subtext: "Overdue by 1 day", source: "Tasks",
            clearCondition: "Clears when you mark the task complete.",
            kind: .actionNeeded, tint: .warn,
            date: now.addingTimeInterval(-3600 * 26), timeText: "1d overdue", isWarning: true,
            primaryAction: AppNotificationAction(label: "Complete", doneMessage: "Completed the follow-up",
                                                 perform: { performed.append("complete") }),
            navigate: {}), id: "shift-due")

        center.set(AppNotification(
            id: "setup-drift", title: "Git commit signing is off",
            subtext: "Setup check drifted", source: "Bootstrap",
            clearCondition: "Clears when the check passes again.",
            kind: .actionNeeded, tint: .warn,
            date: now.addingTimeInterval(-3600 * 3),
            children: [
                AppNotificationChild(id: "k1", name: "commit.gpgsign",
                                     meta: "expected true, found false", actionLabel: "Fix",
                                     perform: { performed.append("fix:gpgsign") }),
                AppNotificationChild(id: "k2", name: "user.signingkey",
                                     meta: "expected a key, found unset", actionLabel: "Fix",
                                     perform: { performed.append("fix:signingkey") }),
            ],
            primaryAction: AppNotificationAction(label: "Fix", doneMessage: "Restored commit signing",
                                                 perform: { performed.append("fix-all") }),
            navigate: {}), id: "setup-drift")

        center.set(AppNotification(
            id: "tool-updates", title: "4 tools have updates",
            subtext: "kubectl, helm, terraform, aws-cli", source: "Updates",
            clearCondition: "Clears when every update is installed.",
            kind: .informational, tint: .info,
            date: now.addingTimeInterval(-3600 * 5),
            children: [
                AppNotificationChild(id: "u1", name: "kubectl", meta: "1.31.4 \u{2192} 1.32.1",
                                     actionLabel: "Update", isMonospaced: true,
                                     perform: { performed.append("update:kubectl") }),
                AppNotificationChild(id: "u2", name: "helm", meta: "3.16.2 \u{2192} 3.17.0",
                                     actionLabel: "Update", isMonospaced: true,
                                     perform: { performed.append("update:helm") }),
            ],
            primaryAction: AppNotificationAction(label: "Update all", doneMessage: "Updating every tool",
                                                 perform: { performed.append("update-all") }),
            navigate: {}), id: "tool-updates")

        center.set(AppNotification(
            id: "github-sync", title: "6 forks are behind upstream",
            subtext: "Furthest behind: ingress-nginx", source: "GitHub Sync",
            clearCondition: "Clears when each fork is synced.",
            kind: .informational, tint: .violet,
            date: now.addingTimeInterval(-3600 * 2),
            children: [
                AppNotificationChild(id: "f1", name: "ingress-nginx", meta: "142 commits behind",
                                     actionLabel: "Sync", perform: { performed.append("sync:ingress") }),
            ],
            primaryAction: AppNotificationAction(label: "Sync all", doneMessage: "Syncing every fork",
                                                 perform: { performed.append("sync-all") }),
            navigate: {}), id: "github-sync")
        // The last row read, so the read/unread half of the menu check has
        // both states to look at without fabricating a fifth entry.
        center.setRead(true, id: "github-sync")
    }

    private static var performed: [String] = []

    /// The real panel, in a real key window, wired to the real store.
    private static func mount() -> (NotificationCenterController, OffScreenProbeWindow) {
        let controller = NotificationCenterController()
        let content = controller.debugPanelContent
        content.clock = { now }
        let window = OffScreenProbe.window(width: 500, height: 900, styleMask: [.titled])
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        let panel = content.view
        panel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: host.topAnchor),
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
        content.reload()
        host.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    // MARK: - 1. Two-tier grouping

    private static func checkTwoTierGrouping(_ ok: inout Bool) {
        print("\n-- " + "two-tier grouping: Needs action, then Available" + " --")
        seed()
        let (controller, _) = mount()
        let content = controller.debugPanelContent

        // The fixture's own discriminating power first: two rows really are
        // action-needed and two really are not, so a grouping that collapsed
        // into one bucket fails loudly rather than passing vacuously.
        let entries = GrandLineNotificationCenter.shared.entries
        check(entries.filter { $0.kind == .actionNeeded }.count == 2
              && entries.filter { $0.kind == .informational }.count == 2,
              "fixture really has two of each kind", &ok)

        check(content.debugGroupHeaders == ["Needs action", "Available"],
              "group headers are \(content.debugGroupHeaders), want [Needs action, Available]", &ok)
        let titles = content.debugRowTitles
        check(titles == ["Renew staging wildcard certificate", "Git commit signing is off",
                         "4 tools have updates", "6 forks are behind upstream"],
              "rows are drawn action-first: \(titles)", &ok)

        let rows = content.debugRows
        guard rows.count == 4 else { return fail("drew \(rows.count) rows, want 4", &ok) }
        // The reference's `Source: detail` line, which is what makes four rows
        // from four pages scannable.
        check(rows[0].debugDetail == "Tasks: Overdue by 1 day",
              "detail line carries the source prefix: \(rows[0].debugDetail)", &ok)
        // The blue dot means unread and nothing else now.
        check(rows[0].debugUnreadDotVisible && !rows[3].debugUnreadDotVisible,
              "the unread dot tracks read state, not source", &ok)
        // A stated timestamp beats a derived one where the source knows better.
        check(rows[0].debugTimeText == "1d overdue",
              "a source-stated time wins: \(rows[0].debugTimeText)", &ok)
        check(rows[1].debugTimeText == "3h ago",
              "a derived time is relative to the injected clock: \(rows[1].debugTimeText)", &ok)
    }

    // MARK: - 2. Hover / selection swaps the timestamp for the action

    private static func checkHoverAndSelectionSwapTimeForAction(_ ok: inout Bool) {
        print("\n-- " + "hover and selection swap the timestamp for the action" + " --")
        seed()
        let (controller, _) = mount()
        let content = controller.debugPanelContent
        guard let row = content.debugRows.first else { return fail("no rows", &ok) }

        check(row.debugTimeVisible && !row.debugActionVisible,
              "at rest the row shows its timestamp and not its action", &ok)
        row.debugSetHovering(true)
        check(row.debugActionVisible && !row.debugTimeVisible,
              "hovering reveals the action and hides the timestamp", &ok)
        check(row.debugActionTitle == "Complete",
              "the action is the source's own: \(row.debugActionTitle)", &ok)
        row.debugSetHovering(false)
        check(row.debugTimeVisible && !row.debugActionVisible,
              "leaving puts the timestamp back", &ok)

        // Selection does the same, and outlives the mouse - which is what makes
        // the keyboard path usable at all.
        row.debugActivate()
        guard let selected = content.debugRows.first else { return fail("no rows after select", &ok) }
        check(content.debugSelectedID == "shift-due", "clicking selects the row", &ok)
        check(selected.debugActionVisible && !selected.debugTimeVisible,
              "a selected row keeps its action showing with no mouse over it", &ok)

        performed = []
        selected.debugClickAction()
        check(performed == ["complete"], "the action button runs the source's own action: \(performed)", &ok)
        check(content.debugFooterText == "Completed the follow-up",
              "the footer toasts the source's own done message: \(content.debugFooterText)", &ok)
    }

    // MARK: - 3. Expand / collapse

    private static func checkExpandCollapse(_ ok: inout Bool) {
        print("\n-- " + "expandable rows open in place, with per-child actions" + " --")
        seed()
        let (controller, _) = mount()
        let content = controller.debugPanelContent

        check(content.debugRows.map(\.debugHasDisclosure) == [false, true, true, true],
              "only rows with children carry a disclosure triangle", &ok)
        check(content.debugChildRows.isEmpty, "nothing is expanded to begin with", &ok)

        guard let updates = content.debugRows.first(where: { $0.debugTitle == "4 tools have updates" }) else {
            return fail("no updates row", &ok)
        }
        updates.debugClickDisclosure()
        let children = content.debugChildRows
        check(children.map(\.debugName) == ["kubectl", "helm"],
              "expanding draws every child: \(children.map(\.debugName))", &ok)
        guard children.count == 2 else {
            // Named, not crashed. A disclosure that stopped expanding would
            // otherwise take the whole suite out on an index, which reads as a
            // broken suite rather than a broken assertion.
            return fail("expanding drew \(children.count) children, want 2 - nothing further to check", &ok)
        }
        check(children[0].debugMeta == "1.31.4 \u{2192} 1.32.1",
              "each child carries its own meta line", &ok)
        check(children.allSatisfy { $0.debugActionTitle == "Update" },
              "each child carries its own action button", &ok)

        performed = []
        children[1].debugClickAction()
        check(performed == ["update:helm"],
              "a child's button runs that child's own action: \(performed)", &ok)

        check(content.debugExpandedIDs == ["tool-updates"], "expansion is remembered by id", &ok)
        // A poll landing while the list is open must not fold it - the whole
        // reason expansion lives on the controller rather than on a row.
        content.reload()
        check(content.debugChildRows.count == 2, "a reload does not collapse an open row", &ok)

        content.debugRows.first { $0.debugTitle == "4 tools have updates" }?.debugClickDisclosure()
        check(content.debugChildRows.isEmpty, "clicking the triangle again collapses it", &ok)
    }

    // MARK: - 4. The context menu, per row state

    private static func checkContextMenuMatchesRowState(_ ok: inout Bool) {
        print("\n-- " + "right-click menu matches the row's own read state" + " --")
        seed()
        let (controller, _) = mount()
        let content = controller.debugPanelContent
        let center = GrandLineNotificationCenter.shared

        guard let unread = center.entries.first(where: { !center.isRead($0) }),
              let read = center.entries.first(where: { center.isRead($0) }) else {
            return fail("fixture has no read/unread pair", &ok)
        }

        let unreadTitles = content.debugContextMenu(for: unread).items.map(\.title)
        check(unreadTitles == ["Snooze for 1 hour", "Snooze until tomorrow", "",
                               "Mark as read", "Copy details", "",
                               "Mute \(unread.source)"],
              "an unread row offers Mark as read: \(unreadTitles)", &ok)

        let readTitles = content.debugContextMenu(for: read).items.map(\.title)
        check(readTitles.contains("Mark as unread") && !readTitles.contains("Mark as read"),
              "a read row offers Mark as unread instead: \(readTitles)", &ok)
        check(readTitles.contains("Mute GitHub Sync"),
              "Mute names the row's own source: \(readTitles)", &ok)

        // The menu is built through the row's real `menu(for:)` too, not only
        // through this controller hook - a menu that never reaches AppKit is
        // a menu the captain never sees.
        check(content.debugRows.first?.debugBuildMenu() != nil,
              "the row itself answers a right-click with a menu", &ok)

        // And the items really act. Snooze is the one with a visible effect on
        // the list, so it is what proves the wiring rather than the shape.
        let before = center.badgeCount
        content.debugContextMenu(for: unread).items.first.map { item in
            _ = item.target?.perform(item.action, with: item)
        }
        check(center.badgeCount == before - 1,
              "Snooze for 1 hour really removes the row from the list", &ok)
        check(center.snoozedCount == 1, "and counts it as snoozed", &ok)
    }

    // MARK: - 5. The two the captain struck out

    private static func checkFooterOmitsTheStruckButtons(_ ok: inout Bool) {
        print("\n-- " + "no Settings and no Reset demo, anywhere in the panel" + " --")
        seed()
        let (controller, _) = mount()
        let content = controller.debugPanelContent

        // Discriminating power first: the walk really does find buttons, so an
        // empty result cannot pass this as "no struck buttons found".
        let all = content.debugAllButtonTitles
        check(all.contains("Mark all read"),
              "the button walk really reaches the panel's buttons: \(all)", &ok)

        let struck = all.filter { title in
            let lowered = title.lowercased()
            return lowered.contains("setting") || lowered.contains("reset")
        }
        check(struck.isEmpty, "struck buttons present: \(struck)", &ok)

        // The footer's own slot holds the toast and the two controls that are
        // meant to be there, and nothing else.
        check(content.debugFooterText == "Updated just now",
              "the resting footer is the toast slot: \(content.debugFooterText)", &ok)
        check(content.debugFooterButtonTitles.isEmpty,
              "nothing else sits in the footer at rest: \(content.debugFooterButtonTitles)", &ok)
    }

    // MARK: - 6. The inset hairline

    private static func checkInsetSeparatorStartsAtTheTextColumn(_ ok: inout Bool) {
        print("\n-- " + "the hairline is inset to the text column, NSTableView-style" + " --")
        seed()
        let (controller, window) = mount()
        let content = controller.debugPanelContent
        content.view.layoutSubtreeIfNeeded()

        guard let row = content.debugRows.first else { return fail("no rows", &ok) }
        // Measured against the row's own rendered title, not against the
        // constant - re-deriving the expected value from the constant under
        // test would assert nothing (AGENTS.md's own rule).
        let titleView = descendants(of: row).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Renew staging wildcard certificate" }
        guard let titleView else { return fail("no title label in the row", &ok) }
        // The label's own *frame* sits 2pt left of its glyphs - AppKit gives
        // an `NSTextField` a negative horizontal alignment-rect inset, and an
        // `NSStackView` positions it by that alignment rect. Measured live
        // (`FM_DEBUG_NOTIF_GEOM`): frame at 64.0 where the text renders at
        // 66.0. So the hairline has to line up with the alignment rect, which
        // is what the eye sees.
        let titleFrame = titleView.alignmentRect(forFrame: titleView.frame)
        let titleX = titleView.superview!.convert(titleFrame, to: window.contentView!).minX

        let hairlines = descendants(of: content.view).filter { view in
            view.layer?.backgroundColor != nil && view.bounds.height == 1 && view.bounds.width > 40
                && view.superview !== content.view
        }
        check(!hairlines.isEmpty, "the list really draws hairlines to measure", &ok)

        // The inset one - the between-rows rule, not the full-width header or
        // footer rules, which are the panel's own direct children and excluded
        // above.
        let insetXs = hairlines.map { $0.convert($0.bounds, to: window.contentView!).minX }
        let matched = insetXs.filter { abs($0 - titleX) < 1.5 }
        check(!matched.isEmpty,
              "no hairline starts at the text column (title at \(fmt(titleX)), hairlines at \(insetXs.map(fmt)))",
              &ok)
        check(insetXs.allSatisfy { $0 > 20 },
              "a between-rows hairline runs to the panel edge: \(insetXs.map(fmt))", &ok)
    }

    // MARK: - 7. The filter, its counts, and the empty states

    private static func checkFilterCountsAndEmptyStates(_ ok: inout Bool) {
        print("\n-- " + "the All / Needs-action filter and both empty states" + " --")
        seed()
        let (controller, _) = mount()
        let content = controller.debugPanelContent

        check(content.debugFilterTitles == ["All  4", "Needs action  2"],
              "the filter carries live counts: \(content.debugFilterTitles)", &ok)

        content.debugSetFilter(.needsAction)
        check(content.debugRowTitles.count == 2 && content.debugGroupHeaders == ["Needs action"],
              "the needs-action filter drops the Available half: \(content.debugGroupHeaders)", &ok)
        check(content.debugFilterTitles == ["All  4", "Needs action  2"],
              "filtering the list does not change the counts", &ok)

        // Both empty states, and the sentence each one is for.
        GrandLineNotificationCenter.shared.set(nil, id: "shift-due")
        GrandLineNotificationCenter.shared.set(nil, id: "setup-drift")
        content.reload()
        check(content.debugEmptyStateShowing && content.debugRowTitles.isEmpty,
              "an empty needs-action filter shows an empty state", &ok)
        check(content.debugAllButtonTitles.allSatisfy { !$0.lowercased().contains("reset") },
              "the empty state introduces no struck button either", &ok)

        content.debugSetFilter(.all)
        check(!content.debugEmptyStateShowing && content.debugRowTitles.count == 2,
              "switching back to All shows what is still waiting", &ok)
    }

    // MARK: - 8. The toast, and Undo where it is honest

    private static func checkToastAndUndo(_ ok: inout Bool) {
        print("\n-- " + "the footer toasts, and offers Undo only where one is real" + " --")
        seed()
        let (controller, _) = mount()
        let content = controller.debugPanelContent
        let center = GrandLineNotificationCenter.shared

        check(center.unreadCount == 3, "fixture starts with three unread", &ok)
        check(content.debugMarkAllReadEnabled, "Mark all read is live while something is unread", &ok)

        guard let markAllRead = descendants(of: content.view).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Mark all read" }) else {
            return fail("no Mark all read button", &ok)
        }
        markAllRead.performClick(nil)
        check(center.unreadCount == 0, "Mark all read clears every dot", &ok)
        check(center.badgeCount == 4, "Mark all read does NOT remove any row", &ok)
        check(content.debugFooterText == "Marked 3 as read",
              "the footer says what happened: \(content.debugFooterText)", &ok)
        check(content.debugFooterButtonTitles == ["Undo"],
              "a reversible action offers Undo: \(content.debugFooterButtonTitles)", &ok)
        check(!content.debugMarkAllReadEnabled, "with nothing unread the button goes quiet", &ok)

        guard let undo = descendants(of: content.view).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Undo" && !$0.isHidden }) else {
            return fail("no Undo button", &ok)
        }
        undo.performClick(nil)
        check(center.unreadCount == 3, "Undo puts all three dots back", &ok)

        // GL-33: where a real restore is impossible, no Undo at all.
        content.debugRows.first?.debugClickAction()
        check(content.debugFooterButtonTitles.isEmpty,
              "an already-started action offers no pretend Undo: \(content.debugFooterButtonTitles)", &ok)
    }

    // MARK: - 9. Keyboard

    private static func checkKeyboardSelection(_ ok: inout Bool) {
        print("\n-- " + "arrow keys select, right expands, Return acts" + " --")
        seed()
        let (controller, _) = mount()
        let content = controller.debugPanelContent

        check(content.debugSendKey(125), "down arrow is handled", &ok)
        check(content.debugSelectedID == "shift-due", "down from nothing selects the first row", &ok)
        _ = content.debugSendKey(125)
        check(content.debugSelectedID == "setup-drift", "down walks the drawn order", &ok)
        _ = content.debugSendKey(124)
        check(content.debugExpandedIDs == ["setup-drift"], "right expands the selected row", &ok)
        _ = content.debugSendKey(123)
        check(content.debugExpandedIDs.isEmpty, "left collapses it", &ok)
        _ = content.debugSendKey(126)
        check(content.debugSelectedID == "shift-due", "up walks back", &ok)

        performed = []
        _ = content.debugSendKey(36)
        check(performed == ["complete"], "Return runs the selected row's action: \(performed)", &ok)
        check(!content.debugSendKey(48), "an unhandled key is passed on rather than swallowed", &ok)
    }

    // MARK: - 10. Both themes, really painted

    private static func checkRendersInBothThemes(_ ok: inout Bool) {
        print("\n-- " + "the panel paints legibly under Daylight and Dusk" + " --")
        for theme in [HelmTheme.daylight, HelmTheme.dusk] {
            ThemeManager.shared.setTheme(theme)
            seed()
            let (controller, _) = mount()
            let content = controller.debugPanelContent
            content.applyTheme(theme)
            content.view.layoutSubtreeIfNeeded()

            guard let rep = content.view.bitmapImageRepForCachingDisplay(in: content.view.bounds) else {
                fail("\(theme.id): no bitmap rep", &ok)
                continue
            }
            content.view.cacheDisplay(in: content.view.bounds, to: rep)
            // AGENTS.md: the rep is in *pixels*, not points - scale before
            // indexing, or a retina sample lands in the top-left quadrant.
            let scale = CGFloat(rep.pixelsWide) / content.view.bounds.width
            let sample = NSPoint(x: content.view.bounds.width * 0.5, y: 40)
            guard let painted = rep.colorAt(x: Int(sample.x * scale), y: Int(sample.y * scale)) else {
                fail("\(theme.id): could not sample the header", &ok)
                continue
            }
            // Compare in the rep's own colour space, never via a conversion to
            // sRGB - `bitmapImageRepForCachingDisplay` hands back the display's
            // profile inside a real window.
            let expected = HelmTheme.nsColor(theme.chromeBackgroundHex)
                .usingColorSpace(rep.colorSpace) ?? painted
            let delta = abs(painted.redComponent - expected.redComponent)
                + abs(painted.greenComponent - expected.greenComponent)
                + abs(painted.blueComponent - expected.blueComponent)
            check(delta < 0.12,
                  "\(theme.id): the panel ground is the theme's own chrome background (delta \(fmt(delta)))",
                  &ok)

            // The rows' own title ink has to clear the floor against it, which
            // is the half a geometry check cannot see.
            let ink = HelmTheme.nsColor(theme.chromeInkHex)
            let ratio = HelmContrast.ratio(ink, HelmTheme.nsColor(theme.chromeBackgroundHex))
            check(ratio >= 4.5, "\(theme.id): title ink is \(fmt(ratio)):1 against the panel", &ok)

            // And a real rendered row, so a theme that produced a zero-height
            // list cannot pass the two colour checks above.
            check(content.debugRows.count == 4 && content.debugRows[0].bounds.height > 30,
                  "\(theme.id): four real rows, \(fmt(content.debugRows.first?.bounds.height ?? 0))pt tall", &ok)
        }
    }

    // MARK: - Helpers

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }
}

#endif
