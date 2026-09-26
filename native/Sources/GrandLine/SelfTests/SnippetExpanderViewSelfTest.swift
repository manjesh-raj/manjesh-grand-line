// Grand Line - native macOS app.
//
// F12's render: the real Hosts page, on its Snippets tab, in a real
// `NSWindow`, plus the real New/Edit Snippet sheet.
//
// **Why this is window-backed and separate from `SnippetExpansionSelfTest`.**
// Everything here is a question about a render or about real laid-out
// geometry: whether the Accessibility card is actually *on* the column when
// the Snippets tab is showing and actually takes no height when it is not
// (AGENTS.md gotcha (11) - an ordinary hidden `NSView` keeps its height, which
// is why the card is an arranged subview), whether a row's kicker really
// carries the trigger and its chip the scope, whether the detail panel's
// fields follow the selection, and whether the card re-themes in both
// registers. The grammar and the policy run in CI's *blocking* lane in the
// sibling suite; this one sits in `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// Run with `FM_RUN_SNIPPET_EXPANDER_VIEW_TESTS=1 .build/debug/GrandLine`.

#if FM_SELFTESTS

import AppKit

enum SnippetExpanderViewSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        let themeBefore = ThemeManager.shared.theme
        // AGENTS.md's hermeticity rule: this suite changes the theme, so it
        // captures it first and restores it. `Phase3PolishSelfTest` fails the
        // run on a suite that calls `setTheme` without reading `theme`.
        defer { ThemeManager.shared.setTheme(themeBefore) }

        checkCardVisibility(check)
        checkCardStates(check)
        checkRowsAndDetail(check)
        checkCardRethemes(check)
        checkEditorRoundTrip(check)

        if failures.isEmpty {
            print("[SnippetExpanderViewSelfTest] all checks passed")
            return true
        }
        print("[SnippetExpanderViewSelfTest] \(failures.count) failure(s):")
        for failure in failures { SelfTestAssertions.reportFailure(failure) }
        return false
    }

    // MARK: Harness

    private static let signature = Snippet(label: "Email signature",
                                           command: "Manjesh P\nPlatform Engineering",
                                           trigger: "sig", scope: .systemWide,
                                           excludedApps: ["1Password"])
    private static let drain = Snippet(label: "Node drain one-liner",
                                       command: "kubectl drain $NODE --ignore-daemonsets",
                                       trigger: "drain")
    private static let plain = Snippet(label: "Tail the proxy log", command: "tail -f proxy.log")

    /// A real page over a scratch store in an off-screen window - the same
    /// harness shape `HostsRedesignSelfTest.page` uses, and never made key:
    /// this machine may be running the captain's own instance.
    private static func page(_ snippets: [Snippet],
                             state: (enabled: Bool, trusted: Bool, armed: Bool, triggerCount: Int)
                                = (enabled: true, trusted: true, armed: true, triggerCount: 2))
        -> (HostsController, NSWindow) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippet-view-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)

        let snippetStore = SnippetStore()
        for snippet in snippets { snippetStore.add(snippet) }
        let controller = HostsController(hostStore: HostStore(),
                                         keyStore: SSHKeyStore(),
                                         snippetStore: snippetStore)
        controller.snippetExpansionState = { state }
        let window = OffScreenProbe.window(width: 1400, height: 860)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 860)
        controller.select(tab: .snippets)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    // MARK: The card is on the column, and only on this tab

    private static func checkCardVisibility(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let (controller, window) = page([signature, drain])
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let card = controller.debugSideStack.expansion

            // The column's own content stack - the thing whose height the card
            // is supposed to stop contributing to.
            let column = card.superview

            check(!card.isHidden, "the Accessibility card is on the column on the Snippets tab")
            let shownHeight = card.frame.height
            check(shownHeight > 60,
                  "and it is genuinely laid out, not a zero-height stub - got \(fmt(shownHeight))")
            let shownColumnHeight = column?.frame.height ?? 0

            controller.select(tab: .hosts)
            controller.view.layoutSubtreeIfNeeded()
            check(card.isHidden, "it leaves on the Hosts tab")
            // Gotcha (11)/(15): `isHidden` is not the claim, and measuring the
            // hidden card's own frame would not be either - `NSStackView`
            // takes a hidden arranged subview out of its layout but leaves the
            // view's last frame on it, so `card.frame.height` still reads its
            // old \(fmt(shownHeight))pt. What actually has to be true is that
            // the column gives the height back, so this measures the *stack
            // the card sits in* getting shorter. An ordinary hidden `NSView`
            // would leave that stack exactly as tall as it was.
            let hiddenColumnHeight = column?.frame.height ?? 0
            check(hiddenColumnHeight < shownColumnHeight - 60,
                  "the card's height comes back to the column - it was "
                    + "\(fmt(shownColumnHeight)) tall and should now be at least 60pt shorter, got "
                    + "\(fmt(hiddenColumnHeight))")

            controller.select(tab: .snippets)
            controller.view.layoutSubtreeIfNeeded()
            check(!card.isHidden, "and it comes back on the way back")
            check(abs((column?.frame.height ?? 0) - shownColumnHeight) < 1,
                  "putting the column back exactly as tall as it was, got "
                    + "\(fmt(column?.frame.height ?? 0)) against \(fmt(shownColumnHeight))")
        }
    }

    // MARK: The four states read differently (GL-14)

    private static func checkCardStates(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let (off, offWindow) = page([signature], state: (false, true, true, 2))
            offWindow.orderFront(nil)
            defer { offWindow.orderOut(nil) }
            let offCard = off.debugSideStack.expansion
            check(offCard.debugStatusText == "Turned off",
                  "off reads as off, got \u{201c}\(offCard.debugStatusText)\u{201d}")
            check(!offCard.debugToggleIsOn, "and the switch agrees")
        }
        autoreleasepool {
            let (untrusted, window) = page([signature], state: (true, false, false, 2))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let card = untrusted.debugSideStack.expansion
            check(card.debugStatusText.contains("not granted"),
                  "on-but-untrusted says so rather than claiming it is armed, got "
                    + "\u{201c}\(card.debugStatusText)\u{201d}")
            check(!card.debugGrantButtonIsHidden,
                  "and the one-grant prompt is offered - graceful degradation, not a silent no-op")
        }
        autoreleasepool {
            let (armed, window) = page([signature, drain], state: (true, true, true, 2))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let card = armed.debugSideStack.expansion
            check(card.debugStatusText == "Granted \u{00b7} 2 triggers armed",
                  "armed names the real count, got \u{201c}\(card.debugStatusText)\u{201d}")
            check(card.debugGrantButtonIsHidden, "and stops asking for a permission it already has")

            // The fixture's own discriminating power: the three strings must
            // differ, or every check above is vacuous.
            let (other, otherWindow) = page([signature], state: (true, true, true, 1))
            otherWindow.orderFront(nil)
            defer { otherWindow.orderOut(nil) }
            check(other.debugSideStack.expansion.debugStatusText == "Granted \u{00b7} 1 trigger armed",
                  "and one trigger is singular, got "
                    + "\u{201c}\(other.debugSideStack.expansion.debugStatusText)\u{201d}")
        }
        // B20: granted, but the monitor predates the grant. macOS never arms
        // an already-registered global monitor retroactively, so this is a
        // real fourth state - and it is the one that used to read
        // "Granted - 2 triggers armed" over a permanently deaf monitor.
        autoreleasepool {
            let (stale, window) = page([signature, drain], state: (true, true, false, 2))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let card = stale.debugSideStack.expansion
            check(!card.debugStatusText.contains("armed"),
                  "granted-but-not-armed must not claim the triggers will fire (B20), got "
                    + "\u{201c}\(card.debugStatusText)\u{201d}")
            check(card.debugStatusText.lowercased().contains("restart"),
                  "and must say what fixes it, got \u{201c}\(card.debugStatusText)\u{201d}")
            check(card.debugGrantButtonIsHidden,
                  "the grant is not what is missing, so the grant button stays away")
        }
    }

    // MARK: Rows and the detail panel

    private static func checkRowsAndDetail(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let (controller, window) = page([signature, drain, plain])
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let list = controller.debugList(.snippets)
            controller.view.layoutSubtreeIfNeeded()

            check(list.debugRowCount == 3, "all three snippets render, got \(list.debugRowCount)")

            guard let systemRow = list.debugAccentRow(0),
                  let consoleRow = list.debugAccentRow(1),
                  let plainRow = list.debugAccentRow(2) else {
                check(false, "the three rows should have real accent-row views")
                return
            }
            check(systemRow.debugKickerText.uppercased() == ";SIG",
                  "a triggered row leads with its trigger, got "
                    + "\u{201c}\(systemRow.debugKickerText)\u{201d}")
            check(systemRow.debugChipText == "system-wide",
                  "and its chip says it will fire elsewhere, got "
                    + "\(systemRow.debugChipText.debugDescription)")
            check(consoleRow.debugChipText == "Console only",
                  "a Console-only trigger reads differently (GL-14), got "
                    + "\(consoleRow.debugChipText.debugDescription)")
            check(plainRow.debugChipText == nil,
                  "and an untriggered snippet has no scope chip at all, got "
                    + "\(plainRow.debugChipText.debugDescription)")
            check(plainRow.debugKickerText.uppercased() == "SNIPPET",
                  "falling back to the old kicker, got \u{201c}\(plainRow.debugKickerText)\u{201d}")

            list.debugSelect(0)
            controller.view.layoutSubtreeIfNeeded()
            let fields = controller.debugSideStack.detail.debugFields
            let labels = fields.map(\.0)
            check(labels.contains("Trigger"), "the detail panel states the trigger, got \(labels)")
            check(labels.contains("Where"), "and where it may fire")
            check(labels.contains("Never in"),
                  "and the exclusion, which is the answer to \u{201c}why did it not fire there\u{201d}")
            check(fields.first(where: { $0.0 == "Trigger" })?.1 == ";sig",
                  "with the trigger as typed, got "
                    + "\(fields.first(where: { $0.0 == "Trigger" })?.1.debugDescription ?? "none")")

            list.debugSelect(2)
            controller.view.layoutSubtreeIfNeeded()
            let plainLabels = controller.debugSideStack.detail.debugFields.map(\.0)
            check(plainLabels.contains("Trigger") && !plainLabels.contains("Where"),
                  "an untriggered snippet says it has none and stops there, got \(plainLabels)")

            check(controller.drillHeaderSubtitle?.contains("1 expand system-wide") == true,
                  "the header counts what actually expands, got "
                    + "\(controller.drillHeaderSubtitle.debugDescription)")
        }
    }

    // MARK: Both registers

    private static func checkCardRethemes(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let (controller, window) = page([signature], state: (true, true, true, 1))
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let card = controller.debugSideStack.expansion

            guard let daylight = HelmTheme.allThemes.first(where: { $0.isDaylight }),
                  let dusk = HelmTheme.allThemes.first(where: { $0.id == "dusk" }) else {
                check(false, "the theme catalogue should carry both a Daylight palette and Dusk")
                return
            }
            ThemeManager.shared.setTheme(daylight)
            controller.view.layoutSubtreeIfNeeded()
            let lightDot = card.debugStatusDotColor.flatMap { NSColor(cgColor: $0) }

            ThemeManager.shared.setTheme(dusk)
            controller.view.layoutSubtreeIfNeeded()
            let duskDot = card.debugStatusDotColor.flatMap { NSColor(cgColor: $0) }

            check(lightDot != nil && duskDot != nil, "the status dot is painted in both registers")
            if let light = lightDot, let dusk = duskDot {
                // The dot is the card's one tinted element, so a card that
                // stopped following the theme shows up here first. The two
                // must differ, or this whole case is vacuous.
                check(HelmContrast.components(light) != HelmContrast.components(dusk),
                      "and the two registers are genuinely different colours - "
                        + "\(HelmContrast.components(light)) vs \(HelmContrast.components(dusk))")
            }
        }
    }

    // MARK: The editor sheet

    private static func checkEditorRoundTrip(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            // Presented as a real sheet, from a real host controller in a real
            // window - not simply assigned as a window's
            // `contentViewController`. AGENTS.md gotcha (6) is the reason:
            // `dismiss(_:)` is a documented no-op for a controller that was
            // never presented, and here it is worse than a no-op - it throws.
            // The app presents this sheet with `presentAsSheet`, so the suite
            // does too, or Save's own dismissal is never the path under test.
            let (host, window) = page([signature])
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let editor = SnippetEditorController(snippet: nil, existingSnippets: [signature])
            host.presentAsSheet(editor)
            defer { if editor.presentingViewController != nil { host.dismiss(editor) } }
            editor.view.layoutSubtreeIfNeeded()

            editor.debugLabelField.stringValue = "Office address"
            editor.debugCommandView.string = "Prestige Tech Park, Bengaluru 560103"
            editor.debugTriggerField.stringValue = ";sig"
            check(editor.validationFailure()?.contains("Email signature") == true,
                  "a taken trigger is refused by name, got "
                    + "\(editor.validationFailure().debugDescription)")

            editor.debugTriggerField.stringValue = "addr you"
            check(editor.validationFailure() != nil, "and so is an illegal one")

            editor.debugTriggerField.stringValue = ";addr"
            editor.debugScopePopUp.selectItem(at: 1)
            editor.debugExcludedInput.setTokens(["1Password"])
            check(editor.validationFailure() == nil, "a legal, unused trigger saves")

            var saved: Snippet?
            editor.onSave = { saved = $0 }
            editor.debugSave()
            check(saved?.trigger == "addr",
                  "the prefix is stripped on the way in, got \(saved?.trigger.debugDescription ?? "none")")
            check(saved?.scope == .systemWide, "the scope comes off the popup")
            check(saved?.excludedApps == ["1Password"], "and the exclusions off the chip well")
            check(saved?.label == "Office address", "with the original two fields intact")

            // An empty trigger is legal - the pre-F12 shape has to stay
            // saveable, or every existing snippet becomes uneditable.
            let second = SnippetEditorController(snippet: nil, existingSnippets: [signature])
            second.view.layoutSubtreeIfNeeded()
            second.debugLabelField.stringValue = "Tail the proxy log"
            second.debugCommandView.string = "tail -f proxy.log"
            check(second.validationFailure() == nil, "a snippet with no trigger at all still saves")
        }
    }

    private static func fmt(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
}

#endif
