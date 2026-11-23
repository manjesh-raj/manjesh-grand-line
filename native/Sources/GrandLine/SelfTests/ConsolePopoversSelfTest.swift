// Grand Line - native macOS app.
//
// `fm/grandline-popover-redesign`: the three Console AI surfaces the captain
// picked on the console popovers board
// (`data/grand-line-console-popovers-sre-mockups/`) - Comp-1's Compose
// popover, Use-1's Claude usage popover and Sre-2's SRE Lead thread - plus
// the Helm 9.3.0 options they stand on.
//
// Headless: every check reads model, layer or string state from views built
// with no window, and the popovers are never shown. Nothing runs `claude` or
// `quota-axi`: Compose and Claude usage are put into their states through
// `debugShow` / `debugApply`, and the SRE Lead thread is fed messages. The
// controller half of Sre-2 (the Working pill, Stop, Try again) is driven
// through the real `ConsoleController` in `SRELeadPerTabSelfTest`.
//
// With `FM_CONSOLE_POPOVERS_RENDER_DIR` set it also writes the PR's renders:
// every state of each surface in Daylight, Dusk and the Lavender palette.
//
// Run with:
//   swift build && FM_RUN_CONSOLE_POPOVERS_TESTS=1 .build/debug/GrandLine; echo $?

#if FM_SELFTESTS

import AppKit

enum ConsolePopoversSelfTest {

    static func run() -> Bool {
        var ok = true
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let savedReduced = HelmMotion.reducedOverrideForTests
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = savedReduced }
        let lavender = HelmTheme.appTheme(id: "lavender") ?? ThemeManager.shared.theme
        ThemeManager.shared.setTheme(lavender)

        autoreleasepool { checkKit(lavender, &ok) }
        autoreleasepool { checkCompose(lavender, &ok) }
        autoreleasepool { checkUsage(lavender, &ok) }
        autoreleasepool { checkSRELeadThread(lavender, &ok) }
        if let dir = ProcessInfo.processInfo.environment["FM_CONSOLE_POPOVERS_RENDER_DIR"], !dir.isEmpty {
            autoreleasepool { writeRenders(to: URL(fileURLWithPath: dir, isDirectory: true)) }
        }
        print(ok ? "ConsolePopoversSelfTest: OK" : "ConsolePopoversSelfTest: FAILED")
        return ok
    }

    // MARK: Helpers

    static func close(_ a: NSColor?, _ b: NSColor?, tolerance: Double = 0.01) -> Bool {
        guard let a, let b else { return false }
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) < tolerance && abs(x.1 - y.1) < tolerance && abs(x.2 - y.2) < tolerance
    }

    static func color(_ cg: CGColor?) -> NSColor? { cg.flatMap { NSColor(cgColor: $0) } }

    static func layOut(_ view: NSView, width: CGFloat) {
        view.setFrameSize(NSSize(width: width, height: max(view.frame.height, 10)))
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        view.setFrameSize(NSSize(width: width, height: height))
        view.layoutSubtreeIfNeeded()
    }

    static func window(_ status: QuotaWindow.Kind, _ used: Double, resetsIn hours: Double?,
                       _ pace: QuotaWindow.PaceStatus, now: Date) -> QuotaWindow {
        QuotaWindow(kind: status, percentUsed: used, resetsAt: hours.map { now.addingTimeInterval($0 * 3600) }, pace: pace)
    }

    static func snapshot(session: QuotaWindow?, weekly: QuotaWindow?, fable: QuotaWindow?) -> QuotaSnapshot {
        QuotaSnapshot(plan: "team", session: session, weekly: weekly, fable: fable, extraUsage: nil,
                      latency: 1.3, log: "")
    }

    /// Local noon on a fixed day, so a countdown never lands on a boundary.
    static var fixedNow: Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 21; parts.hour = 10
        return Calendar.current.date(from: parts) ?? Date()
    }

    // MARK: Kit (Helm 9.3.0)

    private static func checkKit(_ theme: HelmTheme, _ ok: inout Bool) {
        print("\n-- Helm 9.3.0: the raised composer, raised chips, the hero pill and the dashed ring --")
        // The discriminating half first: on Lavender the two wells differ.
        let inset = HelmField.fill(theme, surface: .inset)
        let raised = HelmField.fill(theme, surface: .raised)
        check(!close(inset, raised), "Lavender's inset and raised wells are the same colour - the checks below prove nothing", &ok)

        let card = HelmComposerCard()
        card.applyTheme(theme)
        check(close(color(card.contentContainer.layer?.backgroundColor), inset),
              "a default HelmComposerCard does not paint the inset well", &ok)
        card.surface = .raised
        check(close(color(card.contentContainer.layer?.backgroundColor), raised),
              "HelmComposerCard.surface = .raised does not paint the raised well", &ok)

        let chip = HelmButton(title: "Chip", variant: .secondary, size: .small)
        let plainFill = color(chip.layer?.backgroundColor)
        chip.surface = .raised
        check(close(color(chip.layer?.backgroundColor), raised) && !close(plainFill, raised),
              "a raised secondary HelmButton paints \(String(describing: chip.layer?.backgroundColor)), want the raised well", &ok)

        let pill = HelmStatusPill()
        pill.configure(text: "READY", tint: .good, theme: theme)
        let tinted = color(pill.layer?.backgroundColor)
        pill.heroInk = .white
        let ghost = HelmButton.heroPalette(ink: .white, enabled: true)
        check(close(color(pill.layer?.backgroundColor), ghost.fill) && !close(tinted, ghost.fill),
              "a HelmStatusPill with heroInk is not the ghost fill", &ok)
        check(pill.label.textColor == .white && (pill.layer?.borderWidth ?? 0) == 1,
              "a HelmStatusPill with heroInk does not draw its word in the ink with a hairline", &ok)

        let ring = HelmRingGauge(side: 62)
        check(ring.debugTrackDash == nil, "a ring's track is dashed by default", &ok)
        ring.showsDashedTrack = true
        check(ring.debugTrackDash?.isEmpty == false, "showsDashedTrack draws no dash", &ok)
        if ok { print("  OK   raised composer and chip, ghost pill on a hero, dashed ring") }
    }

    // MARK: Comp-1

    private static func checkCompose(_ theme: HelmTheme, _ ok: inout Bool) {
        print("\n-- Comp-1: the Compose popover --")
        let composer = ConsoleComposerController()
        defer { composer.shutdown() }
        let view = composer.debugContentView
        composer.debugApplyTheme(theme)
        layOut(view, width: 420)

        checkPromptWell(composer.debugWell, "Compose", hint: true, &ok)
        check(composer.debugExampleButtons.count == 3 && composer.debugExampleButtons.allSatisfy { $0.surface == .raised && $0.symbolName != nil },
              "the examples are not three raised chips with a symbol", &ok)

        composer.debugShow(intent: "", phase: .idle, target: "Shell 2")
        check(composer.debugTargetText == "runs in Shell 2", "the target line reads \"\(composer.debugTargetText)\"", &ok)
        check(composer.debugVisibleSections.isEmpty, "an empty popover shows \(composer.debugVisibleSections)", &ok)
        let idleHeight = view.fittingSize.height

        composer.debugShow(intent: "Check disk usage on a host", phase: .generating, target: "Shell 2")
        check(composer.debugVisibleSections == ["working"], "generating shows \(composer.debugVisibleSections)", &ok)

        let long = "df -h --output=source,size,used,avail,pcent,target | sort -k5 -rh | head -20 && du -sh /var/log/* | sort -rh | head"
        composer.debugShow(intent: "Check disk usage on a host", phase: .result(long), target: "Shell 2")
        layOut(view, width: 420)
        check(composer.debugVisibleSections == ["result"], "a result shows \(composer.debugVisibleSections)", &ok)
        check(abs(view.fittingSize.width - 420) < 0.5,
              "a long command makes the popover \(view.fittingSize.width)pt wide, want a fixed 420pt", &ok)
        check(view.fittingSize.height > idleHeight, "the result card adds no height", &ok)

        composer.debugShow(intent: "Check disk usage on a host",
                           phase: .failed("Claude is not installed or not on PATH."), target: "Shell 2")
        check(composer.debugVisibleSections == ["error"], "a failure shows \(composer.debugVisibleSections)", &ok)
        check(abs(view.fittingSize.width - 420) < 0.5, "a failure changes the width", &ok)

        composer.debugShow(intent: "", phase: .idle, target: nil)
        check(composer.debugTargetText == "runs in this tab", "with no tab the target line reads \"\(composer.debugTargetText)\"", &ok)
        if ok { print("  OK   prompt well and raised chips, a fixed 420pt in every state, one section per state, the target tab") }
    }

    /// C1: a terminal-prompt well in the terminal scheme's colours, with
    /// AppKit's own caret off so there is one cursor, not two. The cursor
    /// itself is a window check (`ConsoleFixesWindowChecks`): it needs focus.
    static func checkPromptWell(_ well: HelmPromptWell, _ name: String, hint: Bool, _ ok: inout Bool) {
        layOut(well, width: 380)
        let palette = HelmPromptWell.palette(for: ThemeManager.shared.terminalScheme)
        check(close(color(well.debugChrome.layer?.backgroundColor), palette.fill),
              "\(name): the well is not the terminal background", &ok)
        check(well.debugPromptLabel.stringValue == HelmPromptWell.promptGlyph && !well.debugPromptLabel.isHidden,
              "\(name): the well draws no \(HelmPromptWell.promptGlyph) prompt", &ok)
        check(close(well.debugPromptLabel.textColor, palette.prompt), "\(name): the prompt is not the scheme's magenta", &ok)
        check(close(well.textView.textColor, palette.text), "\(name): typed text is not the scheme's green", &ok)
        check(well.textView.insertionPointColor.alphaComponent == 0, "\(name): AppKit's own caret still draws", &ok)
        check(well.debugHintLabel.isHidden == !hint, "\(name): the hint line shows \(!well.debugHintLabel.isHidden), want \(hint)", &ok)
        check(!well.debugPlaceholderLabel.isHidden, "\(name): an empty well shows no placeholder", &ok)
        // Both palettes in the run - a light scheme and a dark one - keep
        // the typed text and the prompt legible over the well.
        for scheme in [TasksSecretsHeroViewSelfTest.daylight, TasksSecretsHeroViewSelfTest.dusk] {
            let p = HelmPromptWell.palette(for: scheme)
            check(HelmContrast.ratio(p.text, p.fill) >= 4.5 && HelmContrast.ratio(p.prompt, p.fill) >= 3,
                  "\(name): in \(scheme.id) the prompt well's text is \(HelmContrast.ratio(p.text, p.fill)):1", &ok)
        }
    }

    // MARK: Use-1

    private static func checkUsage(_ theme: HelmTheme, _ ok: inout Bool) {
        print("\n-- Use-1: the Claude usage popover --")
        let now = fixedNow
        // The pace pill takes the pace's colour, never the bar's.
        let cases: [(QuotaWindow.PaceStatus, Double, String, HelmTint)] = [
            (.onPace, 23, "On pace", .accent), (.behind, 41, "Behind", .good),
            (.ahead, 84, "Ahead", .warn), (.ahead, 98, "Ahead", .critical), (.unknown, 0, "Pace unknown", .neutral),
        ]
        for (pace, used, text, tint) in cases {
            let got = QuotaWindowRowView.pace(for: window(.weekly, used, resetsIn: 10, pace, now: now))
            check(got.text == text && got.tint == tint,
                  "pace \(pace) at \(used)% is \(got.text)/\(got.tint), want \(text)/\(tint)", &ok)
        }
        // The old defect: a 0% session with an unknown pace was green.
        check(QuotaWindowRowView.pace(for: window(.session, 0, resetsIn: nil, .unknown, now: now)).tint != .good,
              "an unknown pace on an idle session is green again", &ok)

        let usage = QuotaUsageController()
        defer { usage.shutdown() }
        let view = usage.debugContentView
        usage.debugApplyTheme(theme)
        let healthy = snapshot(session: window(.session, 23, resetsIn: 2.5, .onPace, now: now),
                               weekly: window(.weekly, 41, resetsIn: 59.5, .behind, now: now),
                               fable: window(.fable, 18, resetsIn: 59.5, .onPace, now: now))
        usage.debugApply(.success(healthy), now: now)
        layOut(view, width: 320)
        check(usage.debugRings.map(\.gauge.debugLabel) == ["23%", "41%", "18%"],
              "the rings read \(usage.debugRings.map(\.gauge.debugLabel)), want Session, Weekly and the Fable week", &ok)
        check(usage.debugRows.map(\.title) == ["Session", "Weekly", "Fable week"], "the rows are \(usage.debugRows.map(\.title))", &ok)
        check(usage.debugRows.first?.debugDetail == "Resets in 2h 30m \u{00B7} Today 12:30 PM"
                || usage.debugRows.first?.debugDetail.hasPrefix("Resets in 2h 30m") == true,
              "the Session row reads \(usage.debugRows.first?.debugDetail ?? "nothing")", &ok)
        check(!usage.debugWarningVisible && !usage.debugErrorVisible, "a healthy reading shows a warning or an error", &ok)
        let palette = HelmHeroSurface.palette(for: theme)
        let ink = HelmContrast.color(palette.ink)
        check(close(color(usage.debugRings.first?.gauge.debugArcColor), ink),
              "a comfortable ring's arc is not the hero ink", &ok)

        // GL-14: no reading is a dash on a dashed track, never 0%.
        let critical = snapshot(session: nil,
                                weekly: window(.weekly, 98, resetsIn: 35.5, .ahead, now: now),
                                fable: nil)
        usage.debugApply(.success(critical), now: now)
        check(usage.debugRings.map(\.gauge.debugLabel) == ["\u{2014}", "98%"],
              "with no Session reading the rings read \(usage.debugRings.map(\.gauge.debugLabel))", &ok)
        check(usage.debugRings.first?.gauge.debugTrackDash != nil, "a no-reading ring's track is solid", &ok)
        check(usage.debugRings.last?.gauge.debugTrackDash == nil, "a read ring's track is dashed", &ok)
        let signal = HelmHeroSurface.signalColor(tintHex: HelmTint.critical.hex(in: theme), on: palette)
        check(close(color(usage.debugRings.last?.gauge.debugArcColor), signal),
              "a 98% ring's arc is not the critical hue on the gradient", &ok)
        check(usage.debugWarningVisible, "98% of the week shows no warning", &ok)
        layOut(view, width: 320)
        if let pill = usage.debugRows.last?.debugPacePill {
            // The word fits its pill: never "AHE…", whatever the rounding.
            check(pill.label.frame.width + 0.01 >= (pill.label.cell?.cellSize.width ?? 0),
                  "the pace pill's word is \(pill.label.frame.width)pt wide and needs \(pill.label.cell?.cellSize.width ?? 0)pt", &ok)
        }
        check(QuotaUsageViewController_warning(critical.weekly!, now: now).hasPrefix("2% of the week left."),
              "the warning reads \(QuotaUsageViewController_warning(critical.weekly!, now: now))", &ok)

        usage.debugApply(.failure("Couldn't reach Anthropic - check your connection, then try again."))
        check(usage.debugErrorVisible && usage.debugErrorText.hasPrefix("Couldn't reach"),
              "a failure shows no error row", &ok)
        check(usage.debugRetryButton.title == "Retry", "the error row offers \(usage.debugRetryButton.title)", &ok)
        check(QuotaUsageController.debugSummary(for: healthy).contains("Fable week: 18% used"),
              "Copy Summary leaves out the Fable week", &ok)
        if ok { print("  OK   pace colours from the pace, three rings with a dashed no-reading ring, warning, Retry, summary") }
    }

    /// The warning sentence, through the row view's public helpers.
    private static func QuotaUsageViewController_warning(_ window: QuotaWindow, now: Date) -> String {
        QuotaUsageController.debugWarningSentence(window, now: now)
    }

    // MARK: Sre-2

    static let longFinding = """
    **Finding:** `checkout-api-7d9f8c` in namespace `payments` has restarted 14 times in the last hour. The last \
    termination reason is `OOMKilled`: the container hit its `512Mi` memory limit, and `kubectl top` shows steady \
    use around `498Mi` before each restart. The other two replicas show the same pattern about 20 minutes apart, \
    which points at the workload rather than one node. The node itself reports no memory pressure and the pod's \
    requests sit well under what the node has free, so this is the container's own limit and not eviction.

    **Recommended next action:** Raise the memory limit to `768Mi` in the `checkout-api` deployment, or profile the \
    heap before the next deploy.

    ```
    kubectl describe pod checkout-api-7d9f8c -n payments
    ```

    Two smaller things to watch:
    - `payments-worker` is at 81% of its CPU limit
    - an image pull back-off on `fraud-score-6c4`
    """

    private static func checkSRELeadThread(_ theme: HelmTheme, _ ok: inout Bool) {
        print("\n-- Sre-2: the SRE Lead thread --")
        let chat = SRELeadChatView(frame: NSRect(x: 0, y: 0, width: 368, height: 640))
        chat.applyTheme(theme)
        checkPromptWell(chat.debugWell, "SRE Lead", hint: false, &ok)
        chat.append(SRELeadMessage(role: .status, text: "SRE Lead is ready."))
        check(chat.debugEmptyStateVisible, "a thread with only the ready line shows no empty state", &ok)
        check(chat.debugChipTitles == SRELeadChatView.starterQuestions.map(\.label),
              "before a question the chips are \(chat.debugChipTitles)", &ok)

        var submitted: [String] = []
        chat.onSubmit = { submitted.append($0) }
        chat.debugClickChip(1)
        check(chat.debugComposerText == SRELeadChatView.starterQuestions[1].question && submitted.isEmpty,
              "a starter chip sent instead of filling the composer (composer \"\(chat.debugComposerText)\", sent \(submitted))", &ok)
        chat.debugSetComposerText("")

        chat.append(SRELeadMessage(role: .user, text: "Why is checkout-api restarting in prod?"))
        check(!chat.debugEmptyStateVisible && chat.debugBubbleCount == 1, "a question is not one bubble", &ok)
        var stopped = false
        chat.onStop = { stopped = true }
        chat.setInputEnabled(false)
        chat.setWorking(since: Date())
        check(chat.debugIsWorking && chat.debugSendSymbol == "stop.fill" && chat.debugSendEnabled,
              "a running turn does not offer Stop", &ok)
        check(chat.debugChipTitles.isEmpty, "chips show while a turn runs: \(chat.debugChipTitles)", &ok)
        chat.debugClickSend()
        check(stopped, "Stop does not reach the controller", &ok)
        chat.setWorking(since: nil)
        chat.setInputEnabled(true)

        chat.append(SRELeadMessage(role: .assistant, text: longFinding, elapsed: 18))
        let toggles = chat.debugExpandToggles
        check(toggles.count == 1, "a long Finding has \(toggles.count) Show more toggle(s), want 1", &ok)
        if let toggle = toggles.first {
            check(chat.debugExpandedLabelLines(toggle) == SRELeadChatView.collapsedLines,
                  "the long Finding is not collapsed to \(SRELeadChatView.collapsedLines) lines", &ok)
            toggle.performClick(nil)
            check(chat.debugExpandedLabelLines(toggle) == 0 && toggle.title == "Show less",
                  "Show more does not expand the Finding", &ok)
        }
        check(chat.debugChipTitles == SRELeadChatView.followUpQuestions.map(\.label),
              "after an answer the chips are \(chat.debugChipTitles)", &ok)

        var retried = false
        chat.onRetry = { retried = true }
        chat.append(SRELeadMessage(role: .user, text: "And the worker?"))
        chat.append(SRELeadMessage(role: .error, text: "claude -p (SRE Lead) timed out after 300s.", retryable: true))
        check(chat.debugRetryButtons.count == 1, "a failed turn offers \(chat.debugRetryButtons.count) Try again", &ok)
        chat.debugRetryButtons.first?.performClick(nil)
        check(retried, "Try again does not reach the controller", &ok)
        chat.append(SRELeadMessage(role: .error, text: "Couldn't generate the postmortem: offline. You can try again."))
        check(chat.debugRetryButtons.count == 1, "a postmortem failure offers Try again", &ok)
        if ok { print("  OK   starter and follow-up chips fill, bubbles, Stop, a collapsing Finding, Try again on a turn only") }
    }

    // MARK: Renders

    private static func writePNG(_ view: NSView, width: CGFloat, height: CGFloat? = nil, to url: URL) {
        layOut(view, width: width)
        if let height { view.setFrameSize(NSSize(width: width, height: height)); view.layoutSubtreeIfNeeded() }
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func writeRenders(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let daylight = HelmTheme.appTheme(id: "daylight") ?? ThemeManager.shared.theme
        let dusk = HelmTheme.appTheme(id: "dusk") ?? ThemeManager.shared.theme
        let lavender = HelmTheme.appTheme(id: "lavender") ?? ThemeManager.shared.theme
        let now = fixedNow
        for theme in [lavender, daylight, dusk] {
            ThemeManager.shared.setTheme(theme)
            func file(_ name: String) -> URL { folder.appendingPathComponent("\(name)-\(theme.id).png") }

            let composer = ConsoleComposerController()
            let view = composer.debugContentView
            composer.debugApplyTheme(theme)
            composer.debugShow(intent: "", phase: .idle, target: "Shell 2")
            writePNG(view, width: 420, to: file("compose-1-empty"))
            composer.debugShow(intent: "Check disk usage on a host", phase: .idle, target: "Shell 2")
            writePNG(view, width: 420, to: file("compose-2-filled"))
            composer.debugShow(intent: "Check disk usage on a host", phase: .generating, target: "Shell 2")
            writePNG(view, width: 420, to: file("compose-3-generating"))
            composer.debugShow(intent: "Check disk usage on a host",
                               phase: .result("df -h --output=source,size,used,avail,pcent,target | sort -k5 -rh | head -20"),
                               target: "Shell 2")
            writePNG(view, width: 420, to: file("compose-4-result"))
            composer.debugShow(intent: "Check disk usage on a host",
                               phase: .failed("Claude is not installed or not on PATH. Install the Claude CLI, then try again."),
                               target: "Shell 2")
            writePNG(view, width: 420, to: file("compose-5-error"))
            composer.shutdown()

            let usage = QuotaUsageController()
            let usageView = usage.debugContentView
            usage.debugApplyTheme(theme)
            let states: [(String, QuotaFetchResult?, Bool)] = [
                ("usage-1-healthy", .success(snapshot(session: window(.session, 23, resetsIn: 2.5, .onPace, now: now),
                                                      weekly: window(.weekly, 41, resetsIn: 59.5, .behind, now: now),
                                                      fable: window(.fable, 18, resetsIn: 59.5, .onPace, now: now))), false),
                ("usage-2-warning", .success(snapshot(session: window(.session, 12, resetsIn: 4.1, .onPace, now: now),
                                                      weekly: window(.weekly, 84, resetsIn: 59.5, .ahead, now: now),
                                                      fable: window(.fable, 52, resetsIn: 59.5, .onPace, now: now))), false),
                ("usage-3-critical", .success(snapshot(session: window(.session, 0, resetsIn: nil, .unknown, now: now),
                                                       weekly: window(.weekly, 98, resetsIn: 35.5, .ahead, now: now),
                                                       fable: window(.fable, 41, resetsIn: 35.5, .onPace, now: now))), false),
                ("usage-4-unknown", .success(snapshot(session: window(.session, 0, resetsIn: nil, .unknown, now: now),
                                                      weekly: nil, fable: nil)), false),
                ("usage-5-error", .failure("Couldn't reach Anthropic - check your connection, then try again."), false),
                ("usage-6-loading", nil, true),
            ]
            for (name, result, loading) in states {
                usage.debugApply(result, loading: loading, now: now)
                writePNG(usageView, width: 320, to: file(name))
            }
            usage.shutdown()

            func sreCard(_ build: (SRELeadChatView) -> Void) -> NSView {
                let card = NSView(frame: NSRect(x: 0, y: 0, width: 368, height: 700))
                card.wantsLayer = true
                HelmCard.applyCardSurface(to: card, theme: theme, cornerRadius: HelmMetrics.rPanel,
                                          daylightRadius: HelmMetrics.rPanel)
                card.layer?.masksToBounds = true
                let hero = PopoverHeroHeader(symbol: "sparkles", tileStyle: .white,
                                             insets: NSEdgeInsets(top: 12, left: 12, bottom: 13, right: 12))
                hero.set(title: "SRE Lead", subtitle: "DEV Bastion \u{00B7} read-only kubectl")
                hero.applyTheme(theme)
                let pill = HelmStatusPill()
                hero.trailing.addArrangedSubview(pill)
                let postmortem = HelmButton(symbol: "doc.badge.plus", variant: .secondary, size: .small)
                hero.trailing.addArrangedSubview(postmortem)
                pill.label.setContentCompressionResistancePriority(.required, for: .horizontal)
                let insets = postmortem.alignmentRectInsets
                NSLayoutConstraint.activate([
                    postmortem.widthAnchor.constraint(equalToConstant: 26 - insets.left - insets.right),
                    postmortem.heightAnchor.constraint(equalToConstant: 26 - insets.top - insets.bottom),
                ])
                pill.heroInk = hero.ink
                postmortem.heroInk = hero.ink
                let chat = SRELeadChatView(frame: .zero)
                chat.hostLabel = "DEV Bastion"
                chat.applyTheme(theme)
                card.addSubview(hero)
                card.addSubview(chat)
                NSLayoutConstraint.activate([
                    hero.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                    hero.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                    hero.topAnchor.constraint(equalTo: card.topAnchor),
                    chat.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                    chat.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                    chat.topAnchor.constraint(equalTo: hero.bottomAnchor),
                    chat.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                ])
                build(chat)
                let working = chat.debugIsWorking
                pill.configure(text: working ? "WORKING" : "READY", tint: working ? .warn : .good, theme: theme)
                postmortem.isHidden = !chat.hasRealExchange
                return card
            }
            let ready = SRELeadMessage(role: .status, text: "SRE Lead is ready.")
            let question = SRELeadMessage(role: .user, text: "Why is checkout-api restarting in prod?")
            let shots: [(String, (SRELeadChatView) -> Void)] = [
                ("sre-1-empty", { $0.append(ready) }),
                ("sre-2-working", { chat in
                    chat.append(ready); chat.append(question)
                    chat.setInputEnabled(false); chat.setWorking(since: Date().addingTimeInterval(-14))
                }),
                ("sre-3-answer", { chat in
                    chat.append(ready); chat.append(question)
                    chat.append(SRELeadMessage(role: .assistant, text: longFinding, elapsed: 18))
                }),
                ("sre-4-error", { chat in
                    chat.append(ready); chat.append(question)
                    chat.append(SRELeadMessage(role: .error, text: "claude -p (SRE Lead) timed out after 300s.", retryable: true))
                }),
            ]
            for (name, build) in shots {
                let card = sreCard(build)
                card.layoutSubtreeIfNeeded()
                card.display()
                if let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) {
                    card.cacheDisplay(in: card.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: file(name))
                }
            }
        }
        print("  renders written to \(folder.path)")
    }
}

#endif
