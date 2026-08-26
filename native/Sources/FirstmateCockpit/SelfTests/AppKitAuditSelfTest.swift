// Manjesh Grand Line - native macOS app.
//
// The fixes for `data/grand-line-appkit-expert-audit/report.md`, one case per
// finding id, for the findings small enough not to want a suite of their own.
// Run with:
//
//   swift build && FM_RUN_APPKIT_AUDIT_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
//   H3  no two main-menu items declare the same shortcut
//   M1  navigating back to the canvas re-syncs the space pill
//   M5  the Run History sheet's footer pins Close to the trailing edge
//   M6  ... and can be dismissed with Escape
//   S3  a command carrying an embedded newline never reaches a terminal
//   Pr1 a self-test process never reads or writes the real schedule stores
//   T5  the dictation audio tap reads a snapshot, not shared mutable state
//   A1  the notification bell's badge count reaches VoiceOver
//   A2  every dictation HUD state change is announced
//
// Window-backed (M5 is a real measurement on a real view), so this sits in
// `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list.

#if FM_SELFTESTS

import AppKit

enum AppKitAuditSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("H3_noTwoMenuItemsShareAShortcut", test_h3),
            ("M1_backToCanvasSyncsTheSpacePill", test_m1),
            ("M5_runHistoryFooterPinsCloseToTheTrailingEdge", test_m5),
            ("M6_runHistorySheetDismissesOnEscape", test_m6),
            ("S1_S2_aiCommandsReachTheTerminalOnlyThroughTheGate", test_s1_s2),
            ("S3_multiLineAiCommandsAreRefused", test_s3),
            ("Pr1_scheduleStoresRedirectToScratchInASelfTestProcess", test_pr1),
            ("T5_audioTapReadsSnapshotsNotSharedMutableState", test_t5),
            ("A1_notificationBellSpeaksItsBadgeCount", test_a1),
            ("A2_dictationHUDAnnouncesEveryStateChange", test_a2),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "AppKitAuditSelfTest: all \(cases.count) cases passed"
              : "AppKitAuditSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: A1 / A2 - the two non-visual gaps

    /// A1: the bell's accessibility label was set once at construction, so a
    /// VoiceOver user heard "Notifications, button" whether nothing or 99+
    /// items were waiting - the whole "quiet until it matters" signal was
    /// sighted-only.
    private static func test_a1() -> String? {
        let bell = NotificationBellButton()
        var seen: [String] = []
        for count in [0, 1, 5, 250] {
            bell.setBadgeCount(count)
            guard let label = bell.accessibilityLabel() else {
                return "the bell has no accessibility label at count \(count)"
            }
            seen.append(label)
            if count > 0, !label.contains("\(count)") {
                return "the bell says \(label.debugDescription) at count \(count) - the count is invisible to VoiceOver"
            }
            if count > 0, bell.accessibilityValue() as? Int != count {
                return "the bell's accessibility value does not carry the count at \(count)"
            }
        }
        if Set(seen).count != seen.count {
            return "the bell says the same thing at different counts: \(seen)"
        }
        // The badge label must not surface as its own stray element.
        bell.setBadgeCount(5)
        for sub in bell.subviews where sub.isAccessibilityElement() {
            if (sub.accessibilityValue() as? String) == "5" {
                return "the badge label surfaces as its own \"5, text\" element beside the button"
            }
        }
        return nil
    }

    /// A2: `DictationHUD` had zero accessibility API usage, so a VoiceOver user
    /// got no "Listening…" / "Pasted" / "Didn't catch that" at all. A source
    /// guard: an announcement is posted to the system, not stored anywhere a
    /// test can read back.
    private static func test_a2() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let raw = try? String(contentsOf: dir.appendingPathComponent("DictationHUD.swift"), encoding: .utf8) else {
            return nil
        }
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        if !code.contains("NSAccessibility.post(") || !code.contains(".announcementRequested") {
            return "the dictation HUD no longer announces its state changes - it is the one status surface with no non-visual channel"
        }
        if !code.contains("if isNewState {") {
            return "the HUD announces unconditionally - a re-presented identical state would repeat itself in the captain's ear"
        }
        return nil
    }

    // MARK: T5 - the dictation audio-tap race

    /// T5: the `installTap` closure runs on `AVAudioEngine`'s real-time render
    /// thread and used to read `self.recognitionRequest` (an Optional class
    /// reference) and `self.usingLocalWhisperThisRecording`, both written on
    /// main - a formal data race, since `finish()` nils that reference while a
    /// tap callback may be in flight.
    ///
    /// A source guard: the audio path needs a real input device, which a
    /// headless suite does not have (and reaching for `audioEngine.inputNode`
    /// in one *blocks*, which is why the teardown is guarded at all). What can
    /// regress is the closure going back to reading `self.`, and that is what
    /// this reads.
    private static func test_t5() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let raw = try? String(contentsOf: dir.appendingPathComponent("DictationEngine.swift"), encoding: .utf8) else {
            return nil
        }
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let tapStart = code.range(of: "inputNode.installTap(") else {
            return "DictationEngine no longer installs a tap - re-check what reads shared state on the audio thread"
        }
        let closure = String(code[tapStart.lowerBound...].prefix(400))
        for banned in ["self.recognitionRequest", "self.usingLocalWhisperThisRecording"] {
            if closure.contains(banned) {
                return "the audio tap reads \(banned) off the main thread again - snapshot it at install time instead"
            }
        }
        if !code.contains("let capturedRequest = request") {
            return "the tap no longer snapshots the recognition request at install time"
        }
        // And the teardown ordering: the tap holds the request, so it comes off
        // before anything drops the reference.
        guard let finishStart = code.range(of: "private func finish(text: String?"),
              let removeIndex = code.range(of: "removeTapIfInstalled()", range: finishStart.upperBound..<code.endIndex),
              let nilIndex = code.range(of: "recognitionRequest = nil", range: finishStart.upperBound..<code.endIndex) else {
            return "could not find finish()'s teardown - re-check the ordering T5 depends on"
        }
        if removeIndex.lowerBound > nilIndex.lowerBound {
            return "finish() drops the recognition request before removing the tap - the race is back"
        }
        return nil
    }

    // MARK: Pr1 - schedule-store scratch redirects

    /// Pr1: several suites construct a bare `ScheduleStore()` just to satisfy
    /// an initializer's parameter list, and their `withScratchEnv` blocks omit
    /// `FM_SCHEDULES_FILE` - so each of those read the captain's real
    /// `schedules.json` on every full test run. `ScheduleRunHistoryStore.shared`
    /// is a second indirectly-reachable singleton with the same gap. Both are
    /// redirected at process entry now, which is the only fix that also covers
    /// the next suite nobody has written yet.
    private static func test_pr1() -> String? {
        // Both resolvers read the environment every time, so this measures
        // exactly what a bare `ScheduleStore()` in this process would open.
        let schedules = ScheduleStore.storeURL().path
        if !schedules.contains("selftest-process-") {
            return "a bare ScheduleStore() in a self-test process resolves to \(schedules) - the captain's real schedules.json is being read on every test run"
        }
        let history = ScheduleRunHistoryStore.defaultDirectory().path
        if !history.contains("selftest-process-") {
            return "ScheduleRunHistoryStore.shared resolves to \(history) - the real run history is reachable from a self-test process"
        }
        // The real locations must genuinely be somewhere else, or a scratch
        // path that happens to look right would pass vacuously.
        if schedules.contains("Application Support/FirstmateCockpit/schedules.json") {
            return "the scratch redirect still lands inside the real Application Support store"
        }
        return nil
    }

    // MARK: S1 / S2 / S3 - the AI-authored command gate

    /// S1/S2: the app built one destructive-command confirmation and routed
    /// its *least* AI-influenced path through it while leaving its two most
    /// AI-influenced paths ungated. This is a source guard because the gate is
    /// an `NSAlert.runModal()` - driving it for real means answering a modal,
    /// which a headless suite cannot do without becoming a worse copy of the
    /// thing it is checking. What can go wrong is a send site added or
    /// restored that does not route through the gate, and that is what this
    /// reads.
    private static func test_s1_s2() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }

        func code(_ file: String) -> String? {
            guard let raw = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { return nil }
            return raw.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        guard let analyzer = code("LogAnalyzerController.swift") else { return nil }
        // Every suggested command reaches the console through this one method
        // (the row button and spec §24's ⌘⇧T both call it), so the gate has to
        // be inside it.
        guard let body = analyzer.range(of: "private func sendToTerminal(_ command: String) {").map({ String(analyzer[$0.lowerBound...].prefix(900)) }) else {
            return "LogAnalyzerController.sendToTerminal no longer exists - re-check where suggested commands reach the terminal"
        }
        if !body.contains("CommandRiskConfirmation.confirmAIAuthored") {
            return "the Log Analyzer sends an AI-written command to the terminal without a confirmation (S1)"
        }
        // ... and nothing may call the sink around it.
        let sinkCalls = analyzer.components(separatedBy: "onSendCommandToTerminal(").count - 1
        if sinkCalls > 1 {
            return "the Log Analyzer calls its terminal sink from \(sinkCalls) places - only the gated sendToTerminal may (S1)"
        }

        guard let console = code("ConsoleController.swift") else { return nil }
        guard let composer = console.range(of: "composer.onRunInTerminal = ").map({ String(console[$0.lowerBound...].prefix(500)) }) else {
            return "Console's Compose Run-in-Terminal wiring has moved - re-check its gate"
        }
        if !composer.contains("CommandRiskConfirmation.confirmAIAuthored") {
            return "Console Compose runs an AI-written command with no confirmation (S2)"
        }
        return nil
    }

    /// S3: an AI command carrying an embedded newline runs every line as its
    /// own shell command while the review shows one - which is what made the
    /// human-in-the-loop mitigation S1/S2 rest on deceptive.
    private static func test_s3() -> String? {
        let multiline = [
            "kubectl get pods\nrm -rf ~/work",
            "kubectl get pods\r\nrm -rf ~/work",
            "echo one\necho two",
        ]
        for command in multiline where CommandRiskConfirmation.isSingleCommand(command) {
            return "a command containing a line break was accepted as a single command: \(command.debugDescription)"
        }
        // Trailing/leading whitespace is not a second command.
        for command in ["  kubectl get pods  ", "\nkubectl get pods\n"] where !CommandRiskConfirmation.isSingleCommand(command) {
            return "a plain command with surrounding whitespace was rejected: \(command.debugDescription)"
        }
        // The heuristic never clears anything - the quietest answer still confirms.
        if CommandRiskConfirmation.heuristicRisk(of: "kubectl get pods -n prod") == .readOnly {
            return "the AI-command heuristic can clear a command outright, which reintroduces exactly the trust S1 closes"
        }
        if CommandRiskConfirmation.heuristicRisk(of: "rm -rf /tmp/x") != .destructive {
            return "an obviously destructive AI command was not classified as destructive"
        }
        return nil
    }

    // MARK: M5 / M6 - the Run History sheet

    private static func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appkit-audit-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func mountSheet() -> (ScheduleHistoryController, NSWindow) {
        let schedule = AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 9, minute: 0))
        let sheet = ScheduleHistoryController(schedule: schedule,
                                              historyStore: ScheduleRunHistoryStore(directory: scratchDir()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = sheet.view
        sheet.view.layoutSubtreeIfNeeded()
        return (sheet, window)
    }

    /// M5: the footer is `[flexible spacer, Close]` pinned to the sheet's full
    /// width, and it shipped at the default `.gravityAreas` distribution with
    /// the slack plan resting on a content-hugging priority set on a bare
    /// `NSView` - a documented no-op (gotcha 12) - and no hugging on the button
    /// at all (gotcha 10). Who absorbed the row's slack was Auto Layout
    /// tie-breaking, which is how "Connect" once rendered ~900pt wide.
    ///
    /// Measured on the real sheet, at two widths, because the failure is a
    /// button whose width tracks the row rather than its own content.
    private static func test_m5() -> String? {
        var widths: [CGFloat] = []
        for sheetWidth in [460.0, 900.0] as [CGFloat] {
            let (sheet, window) = mountSheet()
            defer { window.contentView = nil }
            window.setContentSize(NSSize(width: sheetWidth, height: 480))
            sheet.view.layoutSubtreeIfNeeded()
            guard let frames = sheet.debugFooterFrames else {
                return "could not reach the footer's Close button"
            }
            guard frames.footer.width > sheetWidth * 0.5 else {
                return "the footer did not stretch to the sheet's width (\(frames.footer.width) of \(sheetWidth)) - this check would measure nothing"
            }
            if frames.close.width > 200 {
                return "the Close button resolved to \(Int(frames.close.width))pt in a \(Int(sheetWidth))pt sheet - it is absorbing the row's slack instead of the spacer"
            }
            let trailingGap = frames.footer.width - frames.close.maxX
            if trailingGap > 1 {
                return "the Close button is \(trailingGap)pt short of the footer's trailing edge - it is no longer pinned there"
            }
            widths.append(frames.close.width)
        }
        // The same button, twice the sheet: its width must not have moved.
        if let first = widths.first, let last = widths.last, abs(first - last) > 1 {
            return "the Close button's width changed with the sheet's (\(first) -> \(last)) - its size is being decided by tie-breaking, not by its own content"
        }

        // Paired with a source guard on purpose, and this is the half that
        // actually catches the regression: under `.gravityAreas` the outcome is
        // Auto Layout *tie-breaking*, so it can measure correct on one run,
        // one theme or one sibling-content shape and wrong on the next - which
        // is exactly what makes the whole class hard to see. The measurement
        // above proves today's geometry; this proves the row can no longer be
        // decided by a coin toss.
        guard let dir = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: dir.appendingPathComponent("ScheduleHistoryController.swift"), encoding: .utf8) else {
            return nil
        }
        if !source.contains("footer.distribution = .fill") {
            return "the footer is back at the default .gravityAreas distribution - the row's slack is decided by tie-breaking again (gotcha 10)"
        }
        // The comment above the fix quotes the old call to explain what was
        // removed, so the guard reads code lines only.
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        if code.contains("spacer.setContentHuggingPriority") {
            return "the spacer is back on a content-hugging priority, which is a no-op on a view with no intrinsic size (gotcha 12)"
        }
        if !source.contains("spacer.widthAnchor.constraint(equalToConstant: 0)") {
            return "the spacer no longer carries a real zero-width constraint, so nothing holds it collapsed"
        }
        if !source.contains("close.setContentHuggingPriority(.required, for: .horizontal)") {
            return "the Close button no longer hugs its content, so it can absorb the row's slack"
        }
        return nil
    }

    /// M6: every sibling sheet pairs Return with Escape; this one shipped only
    /// Return, so a keyboard user had to tab to Close.
    private static func test_m6() -> String? {
        let (sheet, window) = mountSheet()
        defer { window.contentView = nil }
        let before = sheet.debugCloseRequests
        // What AppKit routes an Escape key press to on the first responder.
        sheet.cancelOperation(nil)
        guard sheet.debugCloseRequests == before + 1 else {
            return "Escape did not reach the sheet's own close action - a keyboard user is stuck tabbing to Close"
        }
        return nil
    }

    // MARK: M1 - the space pill on the way back to the canvas

    /// M1: `DaylightModule.space(forDestination:)` returns nil for the canvas
    /// itself, and both the drill-header back button and `showHomeCanvas()`
    /// route through `show(_:)` rather than `selectSpace` - so B5's fix left
    /// the pill asserting the drill page's space while the canvas rendered the
    /// space the captain last chose.
    ///
    /// A source guard for the same reason B5's own case is one: exercising it
    /// for real needs a mounted `AppShellController`, which constructs every
    /// store in the app. What can go wrong here is the branch being dropped,
    /// and that is exactly what this reads.
    private static func test_m1() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let shell = try? String(contentsOf: dir.appendingPathComponent("AppShellController.swift"), encoding: .utf8) else {
            return nil
        }
        guard shell.contains("bar.setSelectedSpace(homeCanvas.selectedSpace)") else {
            return "show(_:) no longer syncs the pill for .homeCanvas - the back button leaves the previous drill page's space lit"
        }
        // And the canvas has to be the one that owns the space, not a second copy.
        guard DaylightModule.space(forDestination: .homeCanvas) == nil else {
            return "space(forDestination:) now answers for .homeCanvas, so this branch is dead code - re-check which one wins"
        }
        return nil
    }

    // MARK: H3 - shortcut collisions in the main menu

    /// A declared shortcut this parser could recover from `main.swift`.
    private struct MenuShortcut {
        let title: String
        let key: String
        let mask: String
        let line: Int
    }

    /// H3: two menu items declaring the same key equivalent is a defect on its
    /// own (macOS HIG), and in this app it was a *dead* shortcut: AppKit
    /// resolves a key equivalent to the first **enabled** match in menu order,
    /// this app implements no `validateMenuItem` anywhere, so the second
    /// declaration can never fire. "New Host…" and "New Task…" both shipped a
    /// plain ⌘N for months and the Tasks one was inert the whole time.
    ///
    /// This is a source parse rather than a real menu walk on purpose:
    /// `AppDelegate.buildMenu()` needs a real `AppShellController`, which
    /// constructs every store in the app - far too much machinery to stand up
    /// for a table of string literals. The parse errs toward *reporting* a
    /// collision when it cannot recover a modifier mask, which is the safe
    /// direction: it forces someone to look.
    private static func test_h3() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: dir.appendingPathComponent("main.swift"), encoding: .utf8) else {
            return nil  // sources unreachable; nothing to assert
        }
        let lines = source.components(separatedBy: "\n")
        var shortcuts: [MenuShortcut] = []

        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//") == false else { continue }
            guard let key = literalKeyEquivalent(in: line), !key.isEmpty else { continue }
            // A `"\(n)"`-style interpolated key is the ⌘1…⌘9 tab selector and
            // the ⌘1…⌘5 space picker - the one *documented* collision in this
            // app, resolved at runtime because the Tab items get disabled off
            // Console and a disabled item does not consume its equivalent.
            if key.contains("\\(") { continue }

            // A construction wrapped over several lines puts the `let x =` and
            // the title above the `keyEquivalent:` argument.
            var declared = declaredIdentifier(in: line)
            var itemTitle = title(in: line)
            if declared == nil || itemTitle == nil {
                for lookback in 1...4 where index - lookback >= 0 {
                    let previous = lines[index - lookback].trimmingCharacters(in: .whitespaces)
                    if previous.isEmpty || previous.hasPrefix("//") { break }
                    declared = declared ?? declaredIdentifier(in: previous)
                    itemTitle = itemTitle ?? title(in: previous)
                    if declared != nil, itemTitle != nil { break }
                }
            }
            var mask = "[.command]"
            for lookahead in 1...3 where index + lookahead < lines.count {
                let next = lines[index + lookahead].trimmingCharacters(in: .whitespaces)
                guard let found = modifierMask(in: next) else { continue }
                // A chained `.keyEquivalentModifierMask = …` continuation
                // belongs to the item on the line immediately above it,
                // whatever identifier happens to be in scope.
                if lookahead == 1, next.hasPrefix(".keyEquivalentModifierMask") {
                    mask = found
                    break
                }
                if let declared, next.hasPrefix("\(declared).") {
                    mask = found
                    break
                }
            }
            shortcuts.append(MenuShortcut(title: itemTitle ?? "?",
                                          key: key,
                                          mask: normalized(mask),
                                          line: index + 1))
        }

        if shortcuts.count < 15 {
            return "only parsed \(shortcuts.count) menu shortcuts out of main.swift - the parser has drifted and this check would pass vacuously"
        }

        var seen: [String: MenuShortcut] = [:]
        var collisions: [String] = []
        for shortcut in shortcuts {
            let id = "\(shortcut.mask)+\(shortcut.key)"
            if let previous = seen[id] {
                collisions.append("\(shortcut.mask) \(shortcut.key): \u{201c}\(previous.title)\u{201d} (line \(previous.line)) and \u{201c}\(shortcut.title)\u{201d} (line \(shortcut.line))")
            } else {
                seen[id] = shortcut
            }
        }
        if !collisions.isEmpty {
            return "two menu items declare the same shortcut, so the later one can never fire: " + collisions.joined(separator: "; ")
        }
        return nil
    }

    private static func literalKeyEquivalent(in line: String) -> String? {
        guard let range = line.range(of: "keyEquivalent: \"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }

    private static func declaredIdentifier(in line: String) -> String? {
        guard line.hasPrefix("let ") else { return nil }
        let rest = line.dropFirst(4)
        guard let space = rest.firstIndex(of: " ") else { return nil }
        return String(rest[rest.startIndex..<space])
    }

    private static func modifierMask(in line: String) -> String? {
        guard let range = line.range(of: "keyEquivalentModifierMask = ") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func title(in line: String) -> String? {
        for marker in ["NSMenuItem(title: \"", "addItem(withTitle: \""] {
            guard let range = line.range(of: marker) else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            return String(rest[rest.startIndex..<end])
        }
        return nil
    }

    private static func normalized(_ mask: String) -> String {
        mask.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ",")
            .map(String.init)
            .sorted()
            .joined(separator: "+")
    }
}

#endif
