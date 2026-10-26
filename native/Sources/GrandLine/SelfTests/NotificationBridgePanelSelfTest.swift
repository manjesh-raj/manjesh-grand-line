// Grand Line - native macOS app.
//
// Permanent, env-gated self-test for the Bridge notification panel
// (`NotificationBridgePanel.swift`) - run via
// `FM_RUN_NOTIFICATION_BRIDGE_TESTS=1 .build/debug/GrandLine`.
//
// **Window-backed on purpose**, and listed in `NEEDS_SESSION` in
// `Scripts/run-all-tests.sh` accordingly. What the Bridge style is about is
// rendered: a title that wraps instead of truncating is a frame, a button
// visible at rest is a frame in a real window, and a colour that holds in
// every theme is a painted layer. The pure half - which entry is Now, and the
// order of the sections - is `NotificationBridgeSections`, asserted by
// `GrandLineNotificationCenterSelfTest` in CI's blocking lane.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum NotificationBridgePanelSelfTest {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static var performed: [String] = []

    /// Long enough that one line of the classic row would have truncated it
    /// at about four words.
    static let longTitle = "Rotate the staging certificate before the wildcard expires on Friday morning"

    static func run() -> Bool {
        var allOK = true
        let captainTheme = ThemeManager.shared.theme
        let captainScale = ChromeTextScale.shared.scale
        defer {
            ThemeManager.shared.setTheme(captainTheme)
            ChromeTextScale.shared.setScale(captainScale)
            GrandLineNotificationCenter.shared.resetForTesting()
        }
        for check in [checkSectionsFollowTheStoreKinds,
                      checkActionsAreVisibleAtRest,
                      checkTitlesWrapInsteadOfTruncating,
                      checkTheLargerTextScale,
                      checkKeyboard,
                      checkVoiceOverLabels,
                      checkRowsNeverSwallowAButtonClick,
                      checkHeaderAndFooter,
                      checkEmptyState,
                      checkEveryThemeHoldsTheNowCard,
                      checkOnlyTheSidebarShowsBridge] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "NotificationBridgePanelSelfTest: all checks passed"
                    : "NotificationBridgePanelSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixture

    private static func seed() {
        let center = GrandLineNotificationCenter.shared
        center.resetForTesting()
        center.clock = { now }
        performed = []
        center.set(AppNotification(
            id: "shift-due", title: longTitle, subtext: "1 is overdue", source: "Tasks",
            clearCondition: "Clears when you mark them complete.",
            kind: .actionNeeded, tint: .warn, date: now.addingTimeInterval(-600),
            timeText: "overdue", isWarning: true,
            primaryAction: AppNotificationAction(label: "Open Tasks", doneMessage: "Opened Tasks",
                                                 perform: { performed.append("tasks") }),
            navigate: {}), id: "shift-due")
        center.set(AppNotification(
            id: "fleet-decisions", title: "1 task needs your decision", subtext: "Waiting on your answer",
            source: "Fleet", kind: .actionNeeded, tint: .warn, date: now.addingTimeInterval(-3600),
            primaryAction: AppNotificationAction(label: "Answer", doneMessage: "Opened Fleet",
                                                 perform: { performed.append("answer") }),
            navigate: {}), id: "fleet-decisions")
        center.set(AppNotification(
            id: "pr-ready", title: "1 PR ready to merge", subtext: "Checks are green",
            source: "Review", kind: .actionNeeded, tint: .good, date: now.addingTimeInterval(-60),
            primaryAction: AppNotificationAction(label: "Review", doneMessage: "Opened Review",
                                                 perform: { performed.append("review") }),
            navigate: {}), id: "pr-ready")
        center.set(AppNotification(
            id: "tool-updates", title: "3 tools have updates", subtext: "kubectl, helm, terraform",
            source: "Updates", clearCondition: "Clears when every update is installed.",
            kind: .informational, tint: .info, date: now.addingTimeInterval(-1200),
            children: [
                AppNotificationChild(id: "kubectl", name: "kubectl", meta: "1.31.2 → 1.32.0", actionLabel: "Update",
                                     isMonospaced: true, perform: { performed.append("update:kubectl") }),
                AppNotificationChild(id: "helm", name: "helm", meta: "3.15 → 3.16", actionLabel: "Update",
                                     isMonospaced: true, perform: { performed.append("update:helm") }),
            ],
            primaryAction: AppNotificationAction(label: "Update all", doneMessage: "Updating every tool",
                                                 perform: { performed.append("update-all") }),
            navigate: {}), id: "tool-updates")
        center.set(AppNotification(
            id: "focus.completed", title: "Focus session finished", subtext: "25m logged",
            source: "Focus", kind: .informational, tint: .good, date: now.addingTimeInterval(-300),
            navigate: { performed.append("focus-open") }), id: "focus.completed")
    }

    private static func mount(scale: CGFloat = 1.0) -> (NotificationBridgePanelViewController, OffScreenProbeWindow) {
        ChromeTextScale.shared.setScale(scale)
        let controller = NotificationCenterController(style: .bridge)
        controller.onOpenHome = { performed.append("home") }
        let content = controller.debugBridgeContent
        content.clock = { now }
        let window = OffScreenProbe.window(width: 500, height: 1200, styleMask: [.titled])
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
        // Retained for the window's life, the way the shell retains it.
        objc_setAssociatedObject(window, &controllerKey, controller, .OBJC_ASSOCIATION_RETAIN)
        return (content, window)
    }
    private static var controllerKey = 0

    /// Whether the label shows its whole string: the height the text needs at
    /// the label's real width fits inside the label's real frame.
    private static func showsAllOf(_ label: NSTextField) -> Bool {
        guard let cell = label.cell, label.frame.width > 0 else { return false }
        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width,
                                                     height: .greatestFiniteMagnitude)).height
        return needed <= label.frame.height + 1
    }

    private static func lineHeight(_ label: NSTextField) -> CGFloat {
        guard let font = label.font else { return 0 }
        return ceil(font.ascender - font.descender + font.leading)
    }

    // MARK: 1. Sections

    private static func checkSectionsFollowTheStoreKinds(_ ok: inout Bool) {
        print("\n-- the store's kinds drive Now, Up next and When you have a minute --")
        seed()
        let (content, _) = mount()
        let entries = GrandLineNotificationCenter.shared.entries
        check(entries.filter { $0.kind == .actionNeeded }.count == 3
              && entries.filter { $0.kind == .informational }.count == 2,
              "the fixture lost its 3 action-needed and 2 informational entries", &ok)
        check(content.debugNowCard?.entryID == "shift-due",
              "the Now card holds \(content.debugNowCard?.entryID ?? "nothing"), want the overdue task", &ok)
        check(content.debugSectionHeaders == ["Up next", "When you have a minute"],
              "section headers are \(content.debugSectionHeaders)", &ok)
        let timed = content.debugRows.filter(\.debugIsTimed).map(\.entryID)
        let later = content.debugRows.filter { !$0.debugIsTimed }.map(\.entryID)
        check(timed == ["fleet-decisions", "pr-ready"],
              "Up next is \(timed), want the other action-needed entries oldest first", &ok)
        check(later == ["focus.completed", "tool-updates"],
              "When you have a minute is \(later), want the informational entries newest first", &ok)
        check(content.debugRows.first(where: { $0.entryID == "fleet-decisions" })?.debugDetail
                == "Fleet \u{00B7} Waiting on your answer",
              "an Up next row names its source in front of the detail", &ok)
    }

    // MARK: 2. Buttons at rest

    private static func checkActionsAreVisibleAtRest(_ ok: inout Bool) {
        print("\n-- every item's action is visible at rest, with no hover --")
        seed()
        let (content, window) = mount()
        for item in content.debugItems {
            let primary = item.actions.primary
            let frame = primary.convert(primary.bounds, to: nil)
            check(!primary.isHiddenOrHasHiddenAncestor && frame.width > 20 && frame.height > 12
                  && window.contentView!.bounds.intersects(frame),
                  "\(item.entryID)'s action is not on screen at rest (\(frame))", &ok)
        }
        check(content.debugNowCard?.actions.primary.variant == .primary,
              "the Now card's action must be the filled primary button", &ok)
        check(content.debugNowCard?.actions.snooze.isHidden == false,
              "the Now card offers snooze at rest", &ok)
        let titles = content.debugItems.map(\.actions.primary.title)
        check(titles == ["Open Tasks", "Answer", "Review", "Open", "Update all"],
              "action titles are \(titles)", &ok)
        // The action does what the source said.
        content.debugNowCard?.actions.primary.performClick(nil)
        check(performed == ["tasks"], "the Now card's button performed \(performed)", &ok)
        check(content.debugFooterText == "Opened Tasks", "the footer said \(content.debugFooterText)", &ok)
    }

    // MARK: 3. Wrapping

    private static func checkTitlesWrapInsteadOfTruncating(_ ok: inout Bool) {
        print("\n-- titles and details wrap instead of truncating --")
        seed()
        let center = GrandLineNotificationCenter.shared
        center.set(AppNotification(
            id: "long-info", title: longTitle, subtext: "A detail line long enough to need a second line here",
            source: "Schedules", kind: .informational, tint: .info, date: now, navigate: {}), id: "long-info")
        let (content, _) = mount()
        guard let card = content.debugNowCard,
              let row = content.debugRows.first(where: { $0.entryID == "long-info" }) else {
            fail("the fixture's long entries are not on screen", &ok)
            return
        }
        for (name, label) in [("Now card title", card.debugTitleLabel), ("row title", row.debugTitleLabel)] {
            check(label.stringValue == longTitle, "\(name) does not carry the whole title", &ok)
            check(label.frame.height >= 2 * lineHeight(label) - 2,
                  "\(name) did not wrap (\(label.frame.height)pt for a \(lineHeight(label))pt line)", &ok)
            check(showsAllOf(label), "\(name) is clipped: its frame cannot show the whole string", &ok)
            check(label.frame.maxX <= label.superview!.bounds.maxX + 0.5,
                  "\(name) runs past its column", &ok)
        }
    }

    // MARK: 4. Larger text

    private static func checkTheLargerTextScale(_ ok: inout Bool) {
        print("\n-- the Larger text scale still fits, with nothing clipped --")
        seed()
        let (content, _) = mount(scale: 1.3)
        let panelWidth = content.view.bounds.width
        check(panelWidth == NotificationBridgePanelViewController.width,
              "the panel grew to \(panelWidth)pt at the Larger scale", &ok)
        for item in content.debugItems {
            let frame = item.convert(item.bounds, to: content.view)
            check(frame.maxX <= panelWidth + 0.5, "\(item.entryID) runs past the panel at 1.3x", &ok)
            for button in [item.actions.primary, item.actions.expand] where !button.isHidden {
                let b = button.convert(button.bounds, to: content.view)
                check(b.maxX <= panelWidth - 8, "\(item.entryID)'s \(button.title) runs past the panel at 1.3x", &ok)
                check(button.fittingSize.height >= HelmButton.Size.small.minHeight * 1.29,
                      "\(button.title) did not scale with the text (\(button.fittingSize.height)pt)", &ok)
            }
        }
        if let card = content.debugNowCard {
            check(showsAllOf(card.debugTitleLabel), "the Now card's title is clipped at 1.3x", &ok)
        }
        for row in content.debugRows {
            check(showsAllOf(row.debugTitleLabel), "\(row.entryID)'s title is clipped at 1.3x", &ok)
        }
        ChromeTextScale.shared.setScale(1.0)
    }

    // MARK: 5. Keyboard

    private static func checkKeyboard(_ ok: inout Bool) {
        print("\n-- arrows select, right and left expand, Return acts --")
        seed()
        let (content, _) = mount()
        check(content.debugSendKey(125) && content.debugSelectedID == "shift-due",
              "the first ↓ selects the Now card, selected \(content.debugSelectedID ?? "nothing")", &ok)
        _ = content.debugSendKey(125)
        check(content.debugSelectedID == "fleet-decisions", "the second ↓ selects the first Up next row", &ok)
        _ = content.debugSendKey(125); _ = content.debugSendKey(125); _ = content.debugSendKey(125)
        check(content.debugSelectedID == "tool-updates", "↓ walks into the informational section in drawn order", &ok)
        check(content.debugSendKey(124) && content.debugExpandedIDs == ["tool-updates"],
              "→ expands the selected row", &ok)
        let children = content.debugRows.first { $0.entryID == "tool-updates" }?.debugChildRows ?? []
        check(children.map(\.debugName) == ["kubectl", "helm"], "the expanded row shows \(children.map(\.debugName))", &ok)
        children.first?.debugClickAction()
        check(performed.last == "update:kubectl", "a child's own button performed \(performed)", &ok)
        _ = content.debugSendKey(123)
        check(content.debugExpandedIDs.isEmpty, "← collapses it", &ok)
        _ = content.debugSendKey(126)
        check(content.debugSelectedID == "focus.completed", "↑ walks back", &ok)
        _ = content.debugSendKey(36)
        check(performed.last == "focus-open", "Return runs the selected item's action, ran \(performed)", &ok)
        let row = content.debugRows.first { $0.entryID == "fleet-decisions" }
        row?.debugSelectByClick()
        check(content.debugSelectedID == "fleet-decisions", "a click on a row's surface selects it", &ok)
        check(content.debugListDocument.window?.firstResponder === content.debugListDocument,
              "selecting hands focus to the list, so the arrows keep working", &ok)
    }

    // MARK: 6. VoiceOver

    private static func checkVoiceOverLabels(_ ok: inout Bool) {
        print("\n-- every item and every button is labelled for VoiceOver --")
        seed()
        let (content, _) = mount()
        guard let card = content.debugNowCard else { fail("no Now card", &ok); return }
        check(card.isAccessibilityElement() && card.accessibilityRole() == .group,
              "the Now card must be a group VoiceOver can enter", &ok)
        check(card.accessibilityLabel()?.hasPrefix("Now: Tasks, \(longTitle)") == true,
              "the Now card reads \(card.accessibilityLabel() ?? "nothing")", &ok)
        check(card.accessibilityLabel()?.contains("unread") == true, "an unread Now card says so", &ok)
        for row in content.debugRows {
            check(row.isAccessibilityElement() && row.accessibilityRole() == .group,
                  "\(row.entryID) must be a group, not a button that hides its children", &ok)
            check(row.accessibilityChildren()?.isEmpty == false,
                  "\(row.entryID)'s buttons must stay reachable inside it", &ok)
            check(row.accessibilityLabel()?.contains(row.debugTitle) == true,
                  "\(row.entryID) reads \(row.accessibilityLabel() ?? "nothing")", &ok)
        }
        for item in content.debugItems {
            let spoken = item.actions.primary.accessibilityLabel() ?? ""
            let title = GrandLineNotificationCenter.shared.entries.first { $0.id == item.entryID }?.title ?? "?"
            check(spoken.contains(title), "\(item.entryID)'s button says \"\(spoken)\", not what it acts on", &ok)
            if !item.actions.expand.isHidden {
                check(item.actions.expand.accessibilityLabel()?.contains(title) == true,
                      "\(item.entryID)'s Show button does not name its subject", &ok)
            }
        }
        check(card.actions.snooze.accessibilityLabel()?.hasPrefix("Snooze \(longTitle)") == true,
              "the snooze glyph reads \(card.actions.snooze.accessibilityLabel() ?? "nothing")", &ok)
        check(content.debugListDocument.accessibilityRole() == .list, "the list is announced as a list", &ok)
    }

    // MARK: 7. Gotcha (20)

    private static func checkRowsNeverSwallowAButtonClick(_ ok: inout Bool) {
        print("\n-- a row has no recognizer that could swallow its buttons' clicks --")
        seed()
        let (content, window) = mount()
        for row in content.debugRows {
            check(row.gestureRecognizers.isEmpty, "\(row.entryID) carries a gesture recognizer (gotcha (20))", &ok)
            // A real hit test at the button's centre lands on the button.
            let button = row.actions.primary
            row.scrollToVisible(row.bounds)
            window.contentView?.layoutSubtreeIfNeeded()
            let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let hit = window.contentView?.hitTest(window.contentView!.convert(centre, from: nil))
            check(hit === button || hit?.isDescendant(of: button) == true,
                  "a click on \(row.entryID)'s \(button.title) lands on \(String(describing: hit))", &ok)
        }
    }

    // MARK: 8. Header and footer

    private static func checkHeaderAndFooter(_ ok: inout Bool) {
        print("\n-- the Bridge header and footer --")
        seed()
        let (content, _) = mount()
        check(content.debugHeaderTitle == "Waiting for you", "header title is \(content.debugHeaderTitle)", &ok)
        check(content.debugNeedYouText == "3 need you", "the need-you chip reads \(content.debugNeedYouText ?? "nothing")", &ok)
        check(content.debugLaterText == "2 later", "the later count reads \(content.debugLaterText ?? "nothing")", &ok)
        check(content.debugFooterText == NotificationBridgePanelViewController.restingFooter,
              "the resting footer reads \(content.debugFooterText)", &ok)
        let titles = content.debugFooterButtons.map(\.title)
        check(titles == ["Mark all read", "Open Home"], "footer buttons are \(titles)", &ok)
        check(content.debugMarkAllReadEnabled, "Mark all read is enabled with unread rows", &ok)
        content.debugClickMarkAllRead()
        check(GrandLineNotificationCenter.shared.unreadCount == 0, "Mark all read left rows unread", &ok)
        check(content.debugRows.allSatisfy { !$0.debugUnreadDotVisible } && content.debugNowCard?.debugUnreadDotVisible == false,
              "a dot is still painted after Mark all read", &ok)
        check(content.debugFooterText == "Marked 5 as read"
              && content.debugFooterButtons.map(\.title).contains("Undo"),
              "the footer offers Undo after Mark all read: \(content.debugFooterText)", &ok)
        content.debugClickOpenHome()
        check(performed.last == "home", "Open Home performed \(performed)", &ok)
        // Snooze from the Now card, then Restore from the footer.
        content.debugNowCard?.actions.snooze.performClick(nil)
        check(!GrandLineNotificationCenter.shared.entries.contains { $0.id == "shift-due" },
              "the Now card's snooze did not hide it", &ok)
        check(content.debugNowCard?.entryID == "fleet-decisions", "the next most urgent item takes the Now card", &ok)
        content.debugShowToast(nil)
        check(content.debugFooterText == "1 snoozed" && content.debugFooterButtons.map(\.title).first == "Restore",
              "the footer offers Restore: \(content.debugFooterText) \(content.debugFooterButtons.map(\.title))", &ok)
        content.debugClickRestore()
        check(GrandLineNotificationCenter.shared.entries.contains { $0.id == "shift-due" }, "Restore brought it back", &ok)
    }

    // MARK: 9. Empty

    private static func checkEmptyState(_ ok: inout Bool) {
        print("\n-- the empty state --")
        GrandLineNotificationCenter.shared.resetForTesting()
        let (content, _) = mount()
        check(content.debugEmptyStateShowing && content.debugItems.isEmpty, "an empty store must show the empty state", &ok)
        check(content.debugEmptyState.debugTitle == "You\u{2019}re all caught up", "empty title is \(content.debugEmptyState.debugTitle)", &ok)
        check(content.debugFooterButtons.map(\.title) == ["Open Home"], "an empty panel offers \(content.debugFooterButtons.map(\.title))", &ok)
        check(content.debugNeedYouText == nil && content.debugLaterText == nil, "the header chips hide when empty", &ok)
    }

    // MARK: 10. Every theme

    /// Reads the painted layer, not the computed colour, in every palette.
    private static func checkEveryThemeHoldsTheNowCard(_ ok: inout Bool) {
        print("\n-- the Now card holds its contrast in every theme --")
        seed()
        let (content, _) = mount()
        for theme in HelmTheme.allThemes {
            ThemeManager.shared.setTheme(theme)
            content.reload()
            guard let card = content.debugNowCard, let fillCG = card.layer?.backgroundColor,
                  let fill = NSColor(cgColor: fillCG) else {
                fail("\(theme.id): no painted Now card", &ok)
                continue
            }
            let panelGround = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let distance = zip([HelmContrast.components(fill)].flatMap { [$0.0, $0.1, $0.2] },
                               [HelmContrast.components(panelGround)].flatMap { [$0.0, $0.1, $0.2] })
                .map { abs($0 - $1) }.max() ?? 0
            check(distance > 0.015, "\(theme.id): the Now card is indistinguishable from the panel (\(distance))", &ok)
            let title = card.debugTitleLabel.textColor ?? .clear
            check(HelmContrast.ratio(title, fill) >= HelmContrast.textTarget,
                  "\(theme.id): the Now card title is \(HelmContrast.ratio(title, fill)):1", &ok)
        }
        ThemeManager.shared.setTheme(HelmTheme.theme(id: "dusk")!)
    }

    // MARK: 11. Sidebar only

    private static func checkOnlyTheSidebarShowsBridge(_ ok: inout Bool) {
        print("\n-- the sidebar layout's bell opens Bridge; the floating bar keeps the classic panel --")
        check(NotificationCenterController(style: .bridge).debugPanelController is NotificationBridgePanelViewController,
              "a .bridge controller does not show the Bridge panel", &ok)
        check(NotificationCenterController().debugPanelController is NotificationPanelViewController,
              "the default controller is no longer the classic panel the floating bar is frozen on", &ok)
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not found - the two source guards below did not run")
            return
        }
        let shell = (try? String(contentsOf: dir.appendingPathComponent("MainSplitShellController.swift"), encoding: .utf8)) ?? ""
        let bar = (try? String(contentsOf: dir.appendingPathComponent("DaylightBarController.swift"), encoding: .utf8)) ?? ""
        check(shell.contains("NotificationCenterController(style: .bridge)"),
              "the sidebar shell no longer builds the Bridge panel", &ok)
        check(bar.contains("NotificationCenterController()") && !bar.contains("style: .bridge"),
              "the floating bar must keep the classic panel (R2-ARCH-01)", &ok)
    }
}

#endif
