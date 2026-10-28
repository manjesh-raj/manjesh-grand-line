// Grand Line - native macOS app.
//
// Permanent, env-gated self-test for the sidebar layout's notification panel
// (`NotificationBridgePanel.swift`, the triage cards) - run via
// `FM_RUN_NOTIFICATION_BRIDGE_TESTS=1 .build/debug/GrandLine`.
//
// **Window-backed on purpose**, and listed in `NEEDS_SESSION` in
// `Scripts/run-all-tests.sh` accordingly. What the triage cards are about is
// rendered: a snooze that stays inside its card is a frame, a button visible
// at rest is a frame in a real window, and a card that reads as a card in
// every theme is a painted layer. The pure half - the ordering rule, the
// persisted snooze and read state, the snooze menu's time strings - is
// asserted by `GrandLineNotificationCenterSelfTest` in CI's blocking lane.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum NotificationBridgePanelSelfTest {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static var performed: [String] = []
    private static var presentedMenus: [(menu: NSMenu, from: NSView)] = []

    /// Long enough that one line would have truncated it at about four words.
    static let longTitle = "Rotate the staging certificate before the wildcard expires on Friday morning"
    /// The label that pushed the old panel's snooze glyph out of its row,
    /// verbatim from the captain's screenshot.
    static let longLabel = "Open Setup \u{203A} GitHub sync"
    /// Longer than any label a source publishes today, so the bar genuinely
    /// overflows - the check below asserts that it does before trusting the
    /// result.
    static let stressLabel = "Open Connections \u{203A} Port forwarding rules for every host"

    static func run() -> Bool {
        var allOK = true
        let captainTheme = ThemeManager.shared.theme
        let captainScale = ChromeTextScale.shared.scale
        defer {
            ThemeManager.shared.setTheme(captainTheme)
            ChromeTextScale.shared.setScale(captainScale)
            GrandLineNotificationCenter.shared.resetForTesting()
        }
        for check in [checkCardsFollowTheStoreKinds,
                      checkActionsAreVisibleAtRest,
                      checkTheSnoozeIsNeverPushedOut,
                      checkTitlesWrapAndDetailsClamp,
                      checkTheLargerTextScale,
                      checkKeyboard,
                      checkVoiceOver,
                      checkCardsNeverSwallowAButtonClick,
                      checkHeaderAndFooter,
                      checkSnoozeMenuAndTheSnoozedList,
                      checkEmptyStates,
                      checkManyItems,
                      checkEveryThemeDrawsACard,
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
        presentedMenus = []
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

    /// The forks row from the captain's screenshot: the longest real primary
    /// label, plus a "Show 3" beside it.
    private static func seedForks() {
        GrandLineNotificationCenter.shared.set(AppNotification(
            id: "stress", title: "Port forwards drifted", subtext: "3 rules changed",
            source: "Hosts", kind: .informational, tint: .info, date: now.addingTimeInterval(-950),
            children: ["a", "b", "c"].map { AppNotificationChild(id: $0, name: $0, meta: "changed") },
            primaryAction: AppNotificationAction(label: stressLabel, doneMessage: "Opened Hosts", perform: {}),
            navigate: {}), id: "stress")
        GrandLineNotificationCenter.shared.set(AppNotification(
            id: "github-sync", title: "3 forks are behind upstream", subtext: "Furthest behind: treehouse",
            source: "GitHub Sync", kind: .informational, tint: .violet, date: now.addingTimeInterval(-900),
            children: ["treehouse", "herdr", "no-mistakes"].map {
                AppNotificationChild(id: $0, name: $0, meta: "behind", actionLabel: "Sync", perform: {})
            },
            primaryAction: AppNotificationAction(label: longLabel, doneMessage: "Opened GitHub Sync", perform: {}),
            navigate: {}), id: "github-sync")
    }

    /// The four rows in the captain's screenshot, as their sources publish
    /// them (the Dotfiles detail through the real `shortDetail`).
    private static func seedScreenshot() {
        let center = GrandLineNotificationCenter.shared
        center.resetForTesting()
        center.clock = { now }
        performed = []
        presentedMenus = []
        let detail = NotificationSources.shortDetail(
            "3 failures in a row \u{00B7} /Users/pat/manjesh/firstmate/projects/manjesh-config and origin/main have both moved on",
            home: "/Users/pat")
        let rows: [(String, String, String, String, HelmTint, String, Int)] = [
            ("service-failing.dotfiles", "Dotfiles auto-sync keeps failing", detail, "Settings", .warn, "Open Health", 0),
            ("setup-drift", "1 setup item has drifted", "Dotfiles & machine config", "Bootstrap", .warn, "Fix", 1),
            ("github-sync", "3 forks are behind upstream", "Furthest behind: treehouse", "GitHub Sync", .violet, "Open GitHub Sync", 3),
            ("tool-updates", "1 tool has an update", "lavish-axi", "Updates", .info, "Open Updates", 1),
        ]
        for (index, row) in rows.enumerated() {
            center.set(AppNotification(
                id: row.0, title: row.1, subtext: row.2, source: row.3, kind: .informational, tint: row.4,
                date: now.addingTimeInterval(-Double(index) * 3600),
                children: (0..<row.6).map { AppNotificationChild(id: "\($0)", name: "child \($0)", meta: "meta") },
                primaryAction: AppNotificationAction(label: row.5, doneMessage: "Done", perform: {}),
                navigate: {}), id: row.0)
        }
    }

    private static func presetItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.identifier?.rawValue.hasPrefix("notification.snooze.") == true }
    }

    private static func mount(scale: CGFloat = 1.0) -> (NotificationBridgePanelViewController, OffScreenProbeWindow) {
        ChromeTextScale.shared.setScale(scale)
        let controller = NotificationCenterController(style: .bridge)
        controller.onOpenHome = { performed.append("home") }
        let content = controller.debugBridgeContent
        content.clock = { now }
        content.presentMenu = { menu, view in presentedMenus.append((menu, view)) }
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

    /// Whether `button` is drawn whole, inside its card's padding.
    private static func sitsInside(_ button: NSView, _ card: NSView) -> Bool {
        let frame = button.convert(button.bounds, to: card)
        let pad = NotificationBridgeMetrics.cardPadding - 0.5
        return !button.isHiddenOrHasHiddenAncestor && frame.width >= 20
            && frame.minX >= pad && frame.maxX <= card.bounds.width - pad
    }

    // MARK: 1. Order and kind

    private static func checkCardsFollowTheStoreKinds(_ ok: inout Bool) {
        print("\n-- one card per item, action-needed first with an accent edge --")
        seed()
        let (content, _) = mount()
        let entries = GrandLineNotificationCenter.shared.entries
        check(entries.filter { $0.kind == .actionNeeded }.count == 3
              && entries.filter { $0.kind == .informational }.count == 2,
              "the fixture lost its 3 action-needed and 2 informational entries", &ok)
        let order = content.debugCards.map(\.entryID)
        check(order == ["shift-due", "fleet-decisions", "pr-ready", "focus.completed", "tool-updates"],
              "cards are \(order), want the overdue task, then the oldest action-needed, then FYI newest first", &ok)
        let edged = content.debugCards.filter(\.debugHasAccentEdge).map(\.entryID)
        check(edged == ["shift-due", "fleet-decisions", "pr-ready"],
              "the accent edge marks \(edged), want only the action-needed cards", &ok)
        check(content.debugCards.first?.debugKicker == "TASKS", "a card names its source as the kicker", &ok)
        check(content.debugCards.first?.debugAgeText == "overdue", "a stated time wins over the arrival age", &ok)
        check(content.debugCards.first { $0.entryID == "focus.completed" }?.debugAgeText == "5m ago",
              "the age is how long ago the item arrived", &ok)
        let hides = content.debugCards.filter { !$0.hide.isHidden }.map(\.entryID)
        check(hides == ["focus.completed", "tool-updates"],
              "Hide is offered on \(hides), want only the informational cards (action-needed never dismisses)", &ok)
    }

    // MARK: 2. Buttons at rest

    private static func checkActionsAreVisibleAtRest(_ ok: inout Bool) {
        print("\n-- every card's action and snooze are visible at rest, with no hover --")
        seed()
        let (content, window) = mount()
        for card in content.debugCards {
            for button in [card.primary, card.snooze] {
                let frame = button.convert(button.bounds, to: nil)
                check(!button.isHiddenOrHasHiddenAncestor && frame.width > 20 && frame.height > 12
                      && window.contentView!.bounds.intersects(frame),
                      "\(card.entryID)'s \(button.title) is not on screen at rest (\(frame))", &ok)
            }
            check(card.snooze.title == "Snooze", "\(card.entryID)'s snooze is labelled, not a bare glyph", &ok)
            check(card.snooze.fittingSize.height >= HelmButton.Size.regular.minHeight,
                  "\(card.entryID)'s snooze is a \(card.snooze.fittingSize.height)pt target", &ok)
        }
        let titles = content.debugCards.map(\.primary.title)
        check(titles == ["Open Tasks", "Answer", "Review", "Open", "Update all"], "action titles are \(titles)", &ok)
        content.debugCards.first?.primary.performClick(nil)
        check(performed == ["tasks"], "the first card's button performed \(performed)", &ok)
        check(content.debugFooterText == "Opened Tasks", "the footer said \(content.debugFooterText)", &ok)
    }

    // MARK: 3. F6

    /// The captain's screenshot showed the forks row with no snooze at all:
    /// the long label and "Show 3" pushed it out of a fixed-width row.
    private static func checkTheSnoozeIsNeverPushedOut(_ ok: inout Bool) {
        print("\n-- the longest real label never pushes the snooze off its card --")
        for scale in [CGFloat(1.0), 1.3] {
            seed()
            seedForks()
            let (content, _) = mount(scale: scale)
            guard let card = content.debugCards.first(where: { $0.entryID == "github-sync" }) else {
                fail("the forks card is missing at \(scale)x", &ok); continue
            }
            check(card.primary.title == longLabel && !card.expand.isHidden,
                  "the fixture must carry the long label and Show 3 (discriminating power)", &ok)
            for (name, button) in [("snooze", card.snooze), ("Show 3", card.expand), ("primary", card.primary)] {
                check(sitsInside(button, card),
                      "at \(scale)x the \(name) runs out of its card (\(button.convert(button.bounds, to: card)) in \(card.bounds.width)pt)", &ok)
            }
            let s = card.snooze.convert(card.snooze.bounds, to: card)
            let e = card.expand.convert(card.expand.bounds, to: card)
            check(s.minX >= e.maxX, "at \(scale)x the snooze overlaps Show 3", &ok)
            guard let stress = content.debugCards.first(where: { $0.entryID == "stress" }) else {
                fail("the stress card is missing at \(scale)x", &ok); continue
            }
            // Discriminating power: this bar really does not fit as drawn.
            let barWidth = stress.bounds.width - 2 * NotificationBridgeMetrics.cardPadding
            let wanted = stress.primary.fittingSize.width + stress.expand.fittingSize.width
                + HelmButton(title: "Snooze", variant: .quiet, size: .regular, symbol: "moon.zzz").fittingSize.width
            check(wanted > barWidth, "the stress label must overflow its bar (\(wanted) of \(barWidth)pt)", &ok)
            check(!stress.snoozeIsLabelled, "an overflowing bar collapses the snooze to its glyph", &ok)
            for (name, button) in [("snooze", stress.snooze), ("Show 3", stress.expand), ("primary", stress.primary)] {
                check(sitsInside(button, stress),
                      "at \(scale)x the stress card's \(name) is pushed out (\(button.convert(button.bounds, to: stress)))", &ok)
            }
            check(stress.snooze.accessibilityLabel()?.hasPrefix("Snooze") == true,
                  "a collapsed snooze still says Snooze to VoiceOver", &ok)
        }
        ChromeTextScale.shared.setScale(1.0)
    }

    // MARK: 4. Wrapping

    private static func checkTitlesWrapAndDetailsClamp(_ ok: inout Bool) {
        print("\n-- titles wrap; details clamp to two lines and keep the whole text in the tooltip --")
        seed()
        let longDetail = String(repeating: "A detail line long enough to need several lines here. ", count: 4)
        GrandLineNotificationCenter.shared.set(AppNotification(
            id: "long-info", title: longTitle, subtext: longDetail,
            source: "Schedules", kind: .informational, tint: .info, date: now, navigate: {}), id: "long-info")
        let (content, _) = mount()
        guard let card = content.debugCards.first(where: { $0.entryID == "long-info" }) else {
            fail("the fixture's long card is not on screen", &ok); return
        }
        let title = card.debugTitleLabel
        check(title.stringValue == longTitle, "the title does not carry the whole string", &ok)
        check(title.frame.height >= 2 * lineHeight(title) - 2,
              "the title did not wrap (\(title.frame.height)pt for a \(lineHeight(title))pt line)", &ok)
        check(showsAllOf(title), "the title is clipped: its frame cannot show the whole string", &ok)
        let detail = card.debugDetailLabel
        let unclamped = detail.attributedStringValue.boundingRect(
            with: NSSize(width: detail.frame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        check(unclamped > 3 * lineHeight(detail),
              "the detail must be long enough to need clamping (discriminating power, \(unclamped)pt)", &ok)
        check(detail.frame.height <= 2 * lineHeight(detail) + 2,
              "the detail is \(detail.frame.height)pt, more than two \(lineHeight(detail))pt lines", &ok)
        check(detail.toolTip == longDetail, "the clamped detail keeps its whole text in the tooltip", &ok)
        check(card.accessibilityLabel()?.contains(longDetail) == true, "VoiceOver reads the whole detail", &ok)
    }

    // MARK: 5. Larger text

    private static func checkTheLargerTextScale(_ ok: inout Bool) {
        print("\n-- the Larger text scale still fits, with nothing clipped --")
        seed()
        let (content, _) = mount(scale: 1.3)
        let panelWidth = content.view.bounds.width
        check(panelWidth == NotificationBridgePanelViewController.width,
              "the panel grew to \(panelWidth)pt at the Larger scale", &ok)
        for card in content.debugCards {
            let frame = card.convert(card.bounds, to: content.view)
            check(frame.maxX <= panelWidth + 0.5, "\(card.entryID) runs past the panel at 1.3x", &ok)
            for button in [card.primary, card.snooze] {
                check(sitsInside(button, card), "\(card.entryID)'s \(button.title) runs out of its card at 1.3x", &ok)
            }
            check(card.primary.fittingSize.height >= HelmButton.Size.regular.minHeight * 1.29,
                  "\(card.primary.title) did not scale with the text (\(card.primary.fittingSize.height)pt)", &ok)
            check(showsAllOf(card.debugTitleLabel), "\(card.entryID)'s title is clipped at 1.3x", &ok)
        }
        ChromeTextScale.shared.setScale(1.0)
    }

    // MARK: 6. Keyboard

    private static func checkKeyboard(_ ok: inout Bool) {
        print("\n-- arrows select, right and left expand, Return acts, S snoozes, Delete hides --")
        seed()
        let (content, _) = mount()
        check(content.debugSendKey(125) && content.debugSelectedID == "shift-due",
              "the first ↓ selects the first card, selected \(content.debugSelectedID ?? "nothing")", &ok)
        _ = content.debugSendKey(125)
        check(content.debugSelectedID == "fleet-decisions", "the second ↓ selects the next card", &ok)
        check(content.debugSendKey(51) && GrandLineNotificationCenter.shared.entries.contains { $0.id == "fleet-decisions" },
              "Delete must not hide an action-needed card", &ok)
        _ = content.debugSendKey(125); _ = content.debugSendKey(125); _ = content.debugSendKey(125)
        check(content.debugSelectedID == "tool-updates", "↓ walks into the informational cards in drawn order", &ok)
        check(content.debugSendKey(124) && content.debugExpandedIDs == ["tool-updates"], "→ expands the selected card", &ok)
        let children = content.debugCards.first { $0.entryID == "tool-updates" }?.debugChildRows ?? []
        check(children.map(\.debugName) == ["kubectl", "helm"], "the expanded card shows \(children.map(\.debugName))", &ok)
        children.first?.debugClickAction()
        check(performed.last == "update:kubectl", "a child's own button performed \(performed)", &ok)
        _ = content.debugSendKey(123)
        check(content.debugExpandedIDs.isEmpty, "← collapses it", &ok)
        _ = content.debugSendKey(1)
        check(presentedMenus.count == 1
              && presentedMenus.first?.from === content.debugCards.first { $0.entryID == "tool-updates" }?.snooze,
              "S opens the selected card's snooze menu under its Snooze button", &ok)
        _ = content.debugSendKey(126)
        check(content.debugSelectedID == "focus.completed", "↑ walks back", &ok)
        _ = content.debugSendKey(36)
        check(performed.last == "focus-open", "Return runs the selected card's action, ran \(performed)", &ok)
        _ = content.debugSendKey(51)
        check(!GrandLineNotificationCenter.shared.entries.contains { $0.id == "focus.completed" },
              "Delete hides the selected informational card", &ok)
        content.debugCards.first { $0.entryID == "fleet-decisions" }?.debugSelectByClick()
        check(content.debugSelectedID == "fleet-decisions", "a click on a card's surface selects it", &ok)
        check(content.debugListDocument.window?.firstResponder === content.debugListDocument,
              "selecting hands focus to the list, so the arrows keep working", &ok)
        _ = content.debugSendKey(30, modifiers: .command)
        check(content.segment == .snoozed, "⌘] switches to the Snoozed list", &ok)
        _ = content.debugSendKey(33, modifiers: .command)
        check(content.segment == .inbox, "⌘[ switches back to the inbox", &ok)
    }

    // MARK: 7. VoiceOver

    private static func checkVoiceOver(_ ok: inout Bool) {
        print("\n-- every card is a labelled group with custom actions, and every button names its subject --")
        seed()
        let (content, _) = mount()
        for card in content.debugCards {
            let entry = GrandLineNotificationCenter.shared.entries.first { $0.id == card.entryID }!
            check(card.isAccessibilityElement() && card.accessibilityRole() == .group,
                  "\(card.entryID) must be a group VoiceOver can enter", &ok)
            check(card.accessibilityLabel()?.contains(entry.title) == true,
                  "\(card.entryID) reads \(card.accessibilityLabel() ?? "nothing")", &ok)
            let names = (card.accessibilityCustomActions() ?? []).map(\.name)
            check(names.contains(card.primary.title) && names.contains("Snooze") && names.contains("Mark as read"),
                  "\(card.entryID)'s custom actions are \(names)", &ok)
            check(names.contains("Hide until it changes") == (entry.kind == .informational),
                  "\(card.entryID) offers Hide to VoiceOver only when it is informational: \(names)", &ok)
            for button in [card.primary, card.snooze] {
                check(button.accessibilityLabel()?.contains(entry.title) == true,
                      "\(card.entryID)'s \(button.title) says \"\(button.accessibilityLabel() ?? "")\"", &ok)
            }
            if !card.expand.isHidden {
                check(card.expand.accessibilityLabel()?.contains(entry.title) == true,
                      "\(card.entryID)'s Show button does not name its subject", &ok)
            }
        }
        check(content.debugCards.first?.accessibilityLabel()?.hasPrefix("Needs you, Tasks, \(longTitle)") == true,
              "an action-needed card says it needs you: \(content.debugCards.first?.accessibilityLabel() ?? "nothing")", &ok)
        // A custom action does what it says, through the card's own wiring.
        if let card = content.debugCards.first(where: { $0.entryID == "pr-ready" }),
           let snooze = card.accessibilityCustomActions()?.first(where: { $0.name == "Snooze" }) {
            _ = snooze.handler?()
            check(presentedMenus.last?.from === card.snooze, "the Snooze custom action opens the snooze menu", &ok)
        } else {
            fail("the PR card has no Snooze custom action", &ok)
        }
        check(content.debugListDocument.accessibilityRole() == .list, "the list is announced as a list", &ok)
    }

    // MARK: 8. Gotcha (20)

    private static func checkCardsNeverSwallowAButtonClick(_ ok: inout Bool) {
        print("\n-- a card has no recognizer that could swallow its buttons' clicks --")
        seed()
        let (content, window) = mount()
        for card in content.debugCards {
            check(card.gestureRecognizers.isEmpty, "\(card.entryID) carries a gesture recognizer (gotcha (20))", &ok)
            card.scrollToVisible(card.bounds)
            window.contentView?.layoutSubtreeIfNeeded()
            for button in [card.primary, card.snooze] {
                let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                let hit = window.contentView?.hitTest(window.contentView!.convert(centre, from: nil))
                check(hit === button || hit?.isDescendant(of: button) == true,
                      "a click on \(card.entryID)'s \(button.title) lands on \(String(describing: hit))", &ok)
            }
        }
    }

    // MARK: 9. Header and footer

    private static func checkHeaderAndFooter(_ ok: inout Bool) {
        print("\n-- the header's segment and the footer --")
        seed()
        let (content, _) = mount()
        check(content.debugHeaderTitle == "Waiting for you", "header title is \(content.debugHeaderTitle)", &ok)
        check(content.debugSegmentTitles == ["Inbox 5", "Snoozed"], "the segment reads \(content.debugSegmentTitles)", &ok)
        // F7: no fixed "Up to date" beside open items.
        check(content.debugFooterText.isEmpty, "the resting footer reads \"\(content.debugFooterText)\"", &ok)
        let titles = content.debugFooterButtons.map(\.title)
        check(titles == ["Mark all read", "Open Home"], "footer buttons are \(titles)", &ok)
        check(content.debugFooterButtons.allSatisfy { $0.variant == .quiet },
              "Open Home must not be the panel's one filled button any more", &ok)
        check(content.debugMarkAllReadEnabled, "Mark all read is enabled with unread cards", &ok)
        content.debugClickMarkAllRead()
        check(GrandLineNotificationCenter.shared.unreadCount == 0, "Mark all read left cards unread", &ok)
        check(content.debugCards.allSatisfy { !$0.debugUnreadDotVisible }, "a dot is still painted after Mark all read", &ok)
        check(content.debugFooterText == "Marked 5 as read" && content.debugFooterButtons.map(\.title).contains("Undo"),
              "the footer offers Undo after Mark all read: \(content.debugFooterText)", &ok)
        content.debugClickUndo()
        check(GrandLineNotificationCenter.shared.unreadCount == 5, "Undo put the dots back", &ok)
        content.debugClickOpenHome()
        check(performed.last == "home", "Open Home performed \(performed)", &ok)
    }

    // MARK: 10. Snooze menu, the Snoozed list, and mutes

    private static func checkSnoozeMenuAndTheSnoozedList(_ ok: inout Bool) {
        print("\n-- Snooze opens the presets as a menu; the Snoozed list brings one back; mutes stay --")
        seed()
        let center = GrandLineNotificationCenter.shared
        let (content, _) = mount()
        guard let card = content.debugCards.first(where: { $0.entryID == "tool-updates" }) else {
            fail("no tool-updates card", &ok); return
        }
        card.snooze.performClick(nil)
        guard let menu = presentedMenus.last?.menu, presentedMenus.last?.from === card.snooze else {
            fail("clicking Snooze did not open a menu under it", &ok); return
        }
        let offered = NotificationSnoozePreset.offered(at: now)
        let presets = presetItems(menu)
        check(presets.map(\.identifier) == offered.map { NotificationBridgePanelViewController.presetIdentifier($0) },
              "the menu offers \(presets.map(\.title))", &ok)
        check(zip(presets, offered).allSatisfy { item, preset in
                  let parts = (item.attributedTitle?.string ?? "").components(separatedBy: "\t")
                  return parts.count == 2 && parts[0] == preset.title && !parts[1].isEmpty
              },
              "each preset draws the time it resolves to beside its name: \(presets.map { $0.attributedTitle?.string ?? "" })", &ok)
        check(menu.items.first?.title == "Snooze until" && menu.items.first?.isEnabled == false,
              "the menu opens with a disabled Snooze until heading", &ok)
        check(menu.items.contains { $0.title == "Hide until it changes" } && menu.items.contains { $0.title == "Mute Updates" },
              "an informational card's menu also offers Hide and Mute", &ok)
        let decision = center.entries.first { $0.id == "fleet-decisions" }!
        check(!content.snoozeMenu(for: decision).items.contains { $0.title == "Hide until it changes" },
              "an action-needed card's menu must not offer Hide", &ok)

        let tomorrow = NotificationSnoozePreset.tomorrow
        guard let pick = presets.first(where: { $0.identifier == NotificationBridgePanelViewController.presetIdentifier(tomorrow) }) else {
            fail("no Tomorrow preset", &ok); return
        }
        HelmMenuAction.debugPerform(pick)
        check(!center.entries.contains { $0.id == "tool-updates" }, "Tomorrow did not snooze the card", &ok)
        check(content.debugFooterText == "Snoozed until tomorrow", "the footer said \(content.debugFooterText)", &ok)
        check(content.debugSegmentTitles == ["Inbox 4", "Snoozed 1"], "the segment counts it: \(content.debugSegmentTitles)", &ok)

        // A muted source must survive the Snoozed list's unsnooze (F3).
        center.setMuted(true, source: "Schedules")
        content.debugSegmentTabs?.debugClickTab(id: NotificationBridgeSegment.snoozed.rawValue)
        check(content.segment == .snoozed && content.debugCards.isEmpty, "the segment switches to the Snoozed list", &ok)
        guard let row = content.debugSnoozedRows.first else {
            fail("the Snoozed list is empty", &ok); return
        }
        check(row.entryID == "tool-updates", "the Snoozed list shows \(row.entryID)", &ok)
        check(row.debugReturnText.hasPrefix("Back tomorrow"), "the row says \(row.debugReturnText)", &ok)
        check(content.debugMutedNote?.contains("Schedules") == true,
              "the Snoozed list names the muted sources: \(content.debugMutedNote ?? "nothing")", &ok)
        row.unsnoozeButton.performClick(nil)
        check(center.entries.contains { $0.id == "tool-updates" }, "Unsnooze brought the card back", &ok)
        check(center.isMuted(source: "Schedules"), "Unsnooze must leave a Settings mute alone (F3)", &ok)
        check(content.debugSnoozedRows.isEmpty && content.debugEmptyState?.debugTitle == "Nothing snoozed",
              "an empty Snoozed list says so", &ok)
        center.setMuted(false, source: "Schedules")
        // The row menu offers the same presets.
        let context = content.debugContextMenu(for: decision)
        check(presetItems(context).count == offered.count,
              "the right-click menu offers the same presets", &ok)
    }

    // MARK: 11. Empty

    private static func checkEmptyStates(_ ok: inout Bool) {
        print("\n-- the empty states --")
        GrandLineNotificationCenter.shared.resetForTesting()
        let (content, _) = mount()
        check(content.debugCards.isEmpty && content.debugEmptyState?.debugTitle == "You\u{2019}re all caught up",
              "an empty inbox shows \(content.debugEmptyState?.debugTitle ?? "no empty state")", &ok)
        check(content.debugFooterButtons.map(\.title) == ["Open Home"], "an empty panel offers \(content.debugFooterButtons.map(\.title))", &ok)
        check(content.debugSegmentTitles == ["Inbox", "Snoozed"], "an empty segment shows no counts: \(content.debugSegmentTitles)", &ok)
        check(content.debugListHeight > 60, "the empty state has room (\(content.debugListHeight)pt)", &ok)
    }

    // MARK: 12. Many items

    private static func checkManyItems(_ ok: inout Bool) {
        print("\n-- the captain's four items fit without scrolling; many scroll, and FYI cards go compact --")
        seedScreenshot()
        let (few, _) = mount()
        let fewContent = few.debugScroll.documentView?.frame.height ?? 0
        // The cap itself must hold four real cards. Whether they all show here
        // also depends on this machine's screen: the list gives way to a short
        // display (CI's runner measured a 429pt limit), which is the panel
        // doing its job, so the second check compares against the limit in
        // force rather than assuming a tall screen.
        check(few.debugCards.count == 4 && fewContent <= NotificationBridgePanelViewController.maxListHeight,
              "the cap must hold the screenshot's four cards (\(fewContent)pt against \(NotificationBridgePanelViewController.maxListHeight)pt)", &ok)
        check(few.debugListHeight >= min(fewContent, few.debugListHeightLimit) - 0.5,
              "the list is shorter than its own limit: \(few.debugListHeight)pt shown of \(fewContent)pt, limit \(few.debugListHeightLimit)pt", &ok)
        check(few.debugCards.allSatisfy { !$0.debugIsCompact }, "four cards keep their detail lines", &ok)
        check(few.debugCards.allSatisfy { $0.snooze.title == "Snooze" },
              "every one of the screenshot's cards keeps a labelled snooze", &ok)
        print("  (four cards measure \(fewContent)pt against a \(NotificationBridgePanelViewController.maxListHeight)pt cap; this screen allows \(few.debugListHeightLimit)pt)")

        seed()

        let center = GrandLineNotificationCenter.shared
        for i in 0..<10 {
            center.set(AppNotification(id: "fyi-\(i)", title: "FYI \(i)", subtext: "detail \(i)", source: "Schedules",
                                       kind: .informational, tint: .info, date: now.addingTimeInterval(-Double(i)),
                                       navigate: {}), id: "fyi-\(i)")
        }
        let (many, _) = mount()
        let manyContent = many.debugScroll.documentView?.frame.height ?? 0
        check(many.debugCards.count == 15, "every item has a card (\(many.debugCards.count))", &ok)
        check(many.debugListHeight <= NotificationBridgePanelViewController.maxListHeight + 0.5
              && manyContent > many.debugListHeight + 100,
              "fifteen cards must scroll inside a capped list (\(many.debugListHeight)pt of \(manyContent)pt)", &ok)
        check(many.debugCards.filter { $0.debugIsCompact }.count == 12
              && many.debugCards.filter { !$0.debugIsCompact }.map(\.entryID) == ["shift-due", "fleet-decisions", "pr-ready"],
              "past six, FYI cards drop their detail and action-needed cards keep theirs", &ok)
        check(many.debugCards.first { $0.debugIsCompact }?.debugDetailLabel.isHidden == true,
              "a compact card hides its detail line", &ok)
    }

    // MARK: 13. Every theme

    /// Reads the painted layers, not the computed colours, in every palette.
    private static func checkEveryThemeDrawsACard(_ ok: inout Bool) {
        print("\n-- every palette draws a card that reads as a card, with legible text --")
        seed()
        let (content, _) = mount()
        // The app themes are their own catalogue (Graphite, Paper, Harbor...),
        // and the captain runs one of them.
        let themes = HelmTheme.allThemes + HelmTheme.appThemes.filter { app in
            !HelmTheme.allThemes.contains { $0.id == app.id }
        }
        check(themes.contains { $0.id == "graphite-light" }, "the sweep must include the app themes", &ok)
        for theme in themes {
            ThemeManager.shared.setTheme(theme)
            content.reload()
            guard let card = content.debugCards.first(where: { $0.entryID == "tool-updates" }),
                  let fillCG = card.layer?.backgroundColor, let fill = NSColor(cgColor: fillCG),
                  let groundColor = content.debugScroll.backgroundColor.usingColorSpace(.sRGB) else {
                fail("\(theme.id): no painted card", &ok); continue
            }
            let distance = zip([HelmContrast.components(fill)].flatMap { [$0.0, $0.1, $0.2] },
                               [HelmContrast.components(groundColor)].flatMap { [$0.0, $0.1, $0.2] })
                .map { abs($0 - $1) }.max() ?? 0
            let border = card.layer?.borderWidth ?? 0
            check(distance > 0.015 || border >= 1,
                  "\(theme.id): the card is indistinguishable from its ground (\(distance), border \(border))", &ok)
            let title = card.debugTitleLabel.textColor ?? .clear
            check(HelmContrast.ratio(title, fill) >= HelmContrast.textTarget,
                  "\(theme.id): the card title is \(HelmContrast.ratio(title, fill)):1", &ok)
            let detail = card.debugDetailLabel.textColor ?? .clear
            check(HelmContrast.ratio(detail, fill) >= HelmContrast.textTarget,
                  "\(theme.id): the card detail is \(HelmContrast.ratio(detail, fill)):1", &ok)
        }
        ThemeManager.shared.setTheme(HelmTheme.theme(id: "dusk")!)
    }

    // MARK: 14. Sidebar only

    private static func checkOnlyTheSidebarShowsBridge(_ ok: inout Bool) {
        print("\n-- the sidebar layout's bell opens the triage cards; the floating bar keeps the classic panel --")
        check(NotificationCenterController(style: .bridge).debugPanelController is NotificationBridgePanelViewController,
              "a .bridge controller does not show the triage-card panel", &ok)
        check(NotificationCenterController().debugPanelController is NotificationPanelViewController,
              "the default controller is no longer the classic panel the floating bar is frozen on", &ok)
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not found - the two source guards below did not run")
            return
        }
        let shell = (try? String(contentsOf: dir.appendingPathComponent("MainSplitShellController.swift"), encoding: .utf8)) ?? ""
        let bar = (try? String(contentsOf: dir.appendingPathComponent("DaylightBarController.swift"), encoding: .utf8)) ?? ""
        check(shell.contains("NotificationCenterController(style: .bridge)"),
              "the sidebar shell no longer builds the triage-card panel", &ok)
        check(bar.contains("NotificationCenterController()") && !bar.contains("style: .bridge"),
              "the floating bar must keep the classic panel (R2-ARCH-01)", &ok)
    }
}

#endif
