// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for the "Waiting for you" row's **real**
// interaction layer - run via
// `FM_RUN_NOTIFICATION_ROW_INTERACTION_TESTS=1 .build/debug/FirstmateCockpit`.
//
// **Why this file exists, and it is the whole point of it.** The redesign
// (PR #451) shipped an expand/collapse mechanism, hover-reveal action buttons
// and a context menu, all covered by `NotificationCenterRedesignSelfTest` and
// all passing - while in the real app not one of them responded to a mouse.
// `fm/grandline-notification-rows-not-interactive` root-caused it: the row's
// own `NSClickGestureRecognizer` claimed every click in the row, including the
// ones landing on the disclosure chevron and the action button nested inside
// it, because AppKit defines no automatic exclusivity between an ancestor's
// recognizer and a descendant control. See `HelmGestureArbitration`.
//
// The existing suite could not see it, for two reasons worth stating because
// both are general:
//
//   1. `debugClickDisclosure()` calls `disclosureClicked()` - the row's own
//      private helper - rather than the button whose `action` reaches it.
//      AGENTS.md's "a `debug*` hook must enter where the real event enters"
//      names exactly this shape, and here it meant the check stayed green with
//      the entire click path swallowed one view up.
//   2. It mounts `content.view` in its own `OffScreenProbe` window and never
//      builds the real `HelmBarPanel`. Gesture arbitration is a property of
//      real event dispatch through a real window, so nothing in a suite that
//      never dispatches an event can observe it.
//
// So every check here drives a **real `NSEvent` through the real panel
// window** - the same `HelmBarPanelWindow` the bell opens - and reads the
// result off the store or the controller, never off the view it clicked.
//
// Window-backed by construction, and listed in `NEEDS_SESSION` in
// `Scripts/run-all-tests.sh` accordingly.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum NotificationRowInteractionSelfTest {

    private static var performed: [String] = []

    static func run() -> Bool {
        var allOK = true
        // AGENTS.md's hermeticity rule: nothing here sets a theme, but the
        // store is shared and must not be left holding this suite's fixture.
        defer { GrandLineNotificationCenter.shared.resetForTesting() }

        for check in [checkRealClickOnChevronTogglesTheRow,
                      checkRealClickOnActionButtonRunsTheAction,
                      checkRealClickOnRowBodyStillActivatesTheRow,
                      checkRealClickOnChildActionRunsThatChild,
                      checkTheRecognizerIsArbitratedRatherThanAbsent] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "notification row interaction: OK" : "notification row interaction: FAILED")
        return allOK
    }

    // MARK: - Fixture

    private static func seed() {
        let center = GrandLineNotificationCenter.shared
        center.resetForTesting()
        performed.removeAll()
        center.set(AppNotification(
            id: "tool-updates", title: "4 tools have updates",
            subtext: "kubectl, helm", source: "Updates",
            clearCondition: "Clears when every tool is on its latest version.",
            kind: .informational, tint: .info, date: Date(),
            children: [
                AppNotificationChild(id: "kubectl", name: "kubectl", meta: "1.29.0 -> 1.30.1",
                                     actionLabel: "Update",
                                     perform: { performed.append("update:kubectl") }),
            ],
            primaryAction: AppNotificationAction(label: "Update all",
                                                 doneMessage: "Updating every tool",
                                                 perform: { performed.append("update-all") }),
            navigate: {}), id: "tool-updates")
    }

    /// The real bell in a real window, and the real `HelmBarPanel` opened
    /// under it - not the content controller mounted by hand. The panel's own
    /// window is what a real click is dispatched to.
    private static func mount() -> (NotificationCenterController, NSWindow)? {
        seed()
        let controller = NotificationCenterController()
        let host = OffScreenProbe.window(width: 600, height: 400, styleMask: [.titled])
        let root = NSView(frame: host.contentLayoutRect)
        host.contentView = root
        let bell = controller.debugBell
        root.addSubview(bell)
        NSLayoutConstraint.activate([
            bell.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            bell.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        ])
        host.makeKeyAndOrderFront(nil)
        root.layoutSubtreeIfNeeded()

        controller.debugPanel.show(under: bell)
        controller.debugPanelContent.view.layoutSubtreeIfNeeded()
        guard let window = controller.debugPanel.panel.contentView?.window else { return nil }
        primeTheEventSystem()
        return (controller, window)
    }

    // MARK: - Driving a real click

    /// `NSApplication.shared`, never `NSApp` - AGENTS.md's rule, and the
    /// convention `CompactModeViewSelfTest` already states.
    private static var app: NSApplication { NSApplication.shared }

    /// The first `nextEvent(matching:)` of a process returns nothing useful,
    /// and an `NSButton`'s own tracking loop (`NSCell.trackMouse`) dequeues
    /// the matching mouse-up itself - so without this the *first* real click
    /// of a run is silently dropped and every later one works. Measured while
    /// building this suite; draining once up front makes click #1 behave like
    /// click #4.
    private static func primeTheEventSystem() {
        while let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.1),
                                        inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
    }

    /// A real left click at a point in the panel window's own coordinates,
    /// posted to the app's event queue and dispatched by the app - so an
    /// `NSButton`'s tracking loop can find its own mouse-up, which a direct
    /// `window.sendEvent` pair cannot give it.
    private static func click(at point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            app.postEvent(event, atStart: false)
        }
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            guard let event = app.nextEvent(matching: .any,
                                            until: Date().addingTimeInterval(0.05),
                                            inMode: .default, dequeue: true) else { break }
            app.sendEvent(event)
        }
    }

    /// The live row, re-read before every click.
    ///
    /// Every interaction here ends in `reload()`, which throws the row views
    /// away and rebuilds them, and an expansion also resizes the panel - which
    /// moves every row in *window* coordinates, because a window's origin is
    /// its bottom-left. A point captured before a click is therefore aimed at
    /// the wrong place afterwards, which cost a full debugging round while
    /// this suite was being written and reads exactly like a half-working
    /// toggle.
    private static func liveRow(_ content: NotificationPanelViewController) -> NotificationRowView? {
        content.view.layoutSubtreeIfNeeded()
        return content.debugRows.first { $0.debugTitle == "4 tools have updates" }
    }

    // MARK: - 1. The chevron

    private static func checkRealClickOnChevronTogglesTheRow(_ ok: inout Bool) {
        guard let (controller, window) = mount() else { return fail("no panel window", &ok) }
        let content = controller.debugPanelContent
        guard let row = liveRow(content) else { return fail("no row", &ok) }
        guard let chevron = row.debugDisclosureFrameInRow else {
            return fail("the row has no visible disclosure - the fixture lost its children", &ok)
        }
        // Discriminating power: the point really is inside the row and really
        // is on the chevron rather than on the text column beside it.
        check(row.bounds.contains(chevron), "the chevron sits inside the row", &ok)
        check(chevron.minX > NotificationRowMetrics.textColumn,
              "the chevron is trailing of the text column, so this is not a row-body click", &ok)
        check(row.debugRowClickWouldBeDeclined(at: NSPoint(x: chevron.midX, y: chevron.midY)),
              "the row's recognizer declines a click on the chevron", &ok)

        check(content.debugExpandedIDs.isEmpty, "starts collapsed", &ok)
        click(at: row.convert(NSPoint(x: chevron.midX, y: chevron.midY), to: nil), in: window)
        check(content.debugExpandedIDs == ["tool-updates"],
              "a real click on the chevron expands the row", &ok)

        guard let expandedRow = liveRow(content),
              let chevron2 = expandedRow.debugDisclosureFrameInRow else {
            return fail("no row after expanding", &ok)
        }
        click(at: expandedRow.convert(NSPoint(x: chevron2.midX, y: chevron2.midY), to: nil), in: window)
        check(content.debugExpandedIDs.isEmpty,
              "a second real click collapses it again", &ok)
        controller.debugPanel.close()
    }

    // MARK: - 2. The hover-reveal action button

    private static func checkRealClickOnActionButtonRunsTheAction(_ ok: inout Bool) {
        guard let (controller, window) = mount() else { return fail("no panel window", &ok) }
        let content = controller.debugPanelContent
        guard let row = liveRow(content) else { return fail("no row", &ok) }
        // The action only exists while the row is hovered or selected, which
        // is the state a real captain clicks it in.
        row.debugSetHovering(true)
        content.view.layoutSubtreeIfNeeded()
        guard let action = row.debugActionFrameInRow else {
            return fail("hovering did not reveal the action button", &ok)
        }
        check(row.bounds.contains(action), "the action button sits inside the row", &ok)
        check(row.debugRowClickWouldBeDeclined(at: NSPoint(x: action.midX, y: action.midY)),
              "the row's recognizer declines a click on the action button", &ok)

        check(performed.isEmpty, "nothing has run yet", &ok)
        click(at: row.convert(NSPoint(x: action.midX, y: action.midY), to: nil), in: window)
        check(performed == ["update-all"],
              "a real click on the action button runs the entry's primary action", &ok)
        controller.debugPanel.close()
    }

    // MARK: - 3. The row body still activates

    /// The other half of the arbitration, and the reason it is written against
    /// *actionable* controls rather than against `NSControl`: a row whose body
    /// stopped responding would be the same bug in the other direction, and a
    /// title is an actionless `NSControl`.
    private static func checkRealClickOnRowBodyStillActivatesTheRow(_ ok: inout Bool) {
        guard let (controller, window) = mount() else { return fail("no panel window", &ok) }
        let content = controller.debugPanelContent
        let center = GrandLineNotificationCenter.shared
        guard let row = liveRow(content) else { return fail("no row", &ok) }
        guard let entry = center.entries.first(where: { $0.id == "tool-updates" }) else {
            return fail("fixture missing", &ok)
        }
        check(!center.isRead(entry), "starts unread", &ok)
        // The title's own x, which is a control-free part of the row.
        let body = NSPoint(x: NotificationRowMetrics.textColumn + 20, y: row.bounds.midY)
        check(!row.debugRowClickWouldBeDeclined(at: body),
              "the row's recognizer accepts a click on the row body", &ok)
        click(at: row.convert(body, to: nil), in: window)
        check(center.isRead(entry), "a real click on the row body marks it read", &ok)
        controller.debugPanel.close()
    }

    // MARK: - 4. A child's own action

    private static func checkRealClickOnChildActionRunsThatChild(_ ok: inout Bool) {
        guard let (controller, window) = mount() else { return fail("no panel window", &ok) }
        let content = controller.debugPanelContent
        guard let row = liveRow(content),
              let chevron = row.debugDisclosureFrameInRow else { return fail("no row", &ok) }
        click(at: row.convert(NSPoint(x: chevron.midX, y: chevron.midY), to: nil), in: window)
        content.view.layoutSubtreeIfNeeded()
        guard let child = content.debugChildRows.first(where: { $0.debugName == "kubectl" }) else {
            return fail("expanding produced no child row", &ok)
        }
        guard let button = child.debugActionButtonFrameInRow else {
            return fail("the child row has no visible action button", &ok)
        }
        check(performed.isEmpty, "nothing has run yet", &ok)
        click(at: child.convert(NSPoint(x: button.midX, y: button.midY), to: nil), in: window)
        check(performed == ["update:kubectl"],
              "a real click on a child's action runs that child's action", &ok)
        controller.debugPanel.close()
    }

    // MARK: - 5. The wiring, not just the behaviour

    /// A behavioural check and a source-level one catch different things
    /// (AGENTS.md). The four above prove the clicks land; this one proves
    /// *why*, so a future row that drops the delegate fails by name rather
    /// than by a timing-sensitive click.
    private static func checkTheRecognizerIsArbitratedRatherThanAbsent(_ ok: inout Bool) {
        guard let (controller, _) = mount() else { return fail("no panel window", &ok) }
        guard let row = liveRow(controller.debugPanelContent) else { return fail("no row", &ok) }
        let recognizers = row.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
        check(recognizers.count == 1, "the row still has exactly one click recognizer", &ok)
        check(recognizers.first?.delegate != nil,
              "that recognizer has a delegate, so it can decline a nested control's click", &ok)
        check(row.isActivatable,
              "the row is still activatable, so GL-16's role and keyboard press survive", &ok)
        controller.debugPanel.close()
    }
}
#endif
