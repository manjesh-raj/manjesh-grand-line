// Manjesh Grand Line - native macOS app.
//
// Review #3's UI findings (`data/grandline-full-review-3/report.md` §5,
// UI1-UI13), for the ones whose fix has no existing suite that already owns
// it.
//
// The ones that do are strengthened in place instead, per this codebase's own
// rule that an assertion which has become a record of the old behaviour is
// inverted rather than left beside a new one:
//
// - **UI1** -> `HostsRedesignSelfTest`. Three of its cases moved with the
//   finding: the sidebar-badge check became
//   `checkWorkspacePanelCountsComeFromTheStores` (the counts have one home
//   now), the structure check asserts the WORKSPACE rows carry *no* badges
//   where it used to assert they did, and the one-mechanism check asserts the
//   duplicate tab strip is gone from the real rendered tree.
// - **UI5 (GitHub Sync)** -> `GitHubSyncRefreshSelfTest`, whose two layout
//   cases were written against the toolbar row and the "Sync All" card that
//   the finding removed.
//
// Everything else is here.
//
// **Deliberately window-free, so this runs on the blocking CI lane.** Nothing
// below needs a composited window: the palette checks are arithmetic, the page
// checks need a real `loadView()` and a real layout pass at a real width, and
// `GitHubSyncRefreshSelfTest` records the same reasoning for the same reason.
// Adding an `NSWindow` would move the whole suite onto the windowed lane (see
// `E2ETestingPolicySelfTest`) for no extra coverage.
//
// Run with:
//   swift build && FM_RUN_AUDIT3_UI_FIXES_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum Audit3UIFixesSelfTest {

    static func run() -> Bool {
        print("Audit3UIFixesSelfTest: review #3's UI findings")
        var allOK = true
        for check in [checkDisabledButtonIsNeutral,
                      checkUnselectedTabChipIsPainted,
                      checkVaultHeaderCountIsAPillAndCardsLoad,
                      checkBootstrapDropsTheDuplicateStepSummary,
                      checkAnalyzeModePickerIsNotTheAnalyzeButton,
                      checkCommandLibraryUsesNoEmoji,
                      checkSecondaryButtonOutlineClearsTheFloor,
                      checkConsoleCardDistinguishesACleanExit,
                      checkWarmingCanvasCardShowsASkeletonNotASentence,
                      checkThemeGridNamesFitAtEveryWidth,
                      checkDeadEndEmptyStatesGainedAnAction,
                      checkSegmentedTabsDivergenceStaysDocumented] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "Audit3UIFixesSelfTest: all checks passed"
                    : "Audit3UIFixesSelfTest: FAILED")
        return allOK
    }

    private static func check(_ condition: Bool, _ label: String, _ ok: inout Bool) {
        SelfTestAssertions.recordNarrated(condition, label, &ok)
    }

    /// Both theme families, and both ends of each. Every UI finding in §5 is
    /// marked "both themes" except UI11 (dusk) and UI2 (latte), and a recipe
    /// fixed in one register and not the other is exactly how several of these
    /// shipped - so every colour check below sweeps rather than spot-checks.
    private static var themes: [HelmTheme] {
        HelmTheme.allThemes
    }

    /// Every `FM_*` store this suite can reach, pointed at scratch, with the
    /// theme and font size saved and restored.
    ///
    /// The save/restore is not optional and not defensive: mounting a real
    /// controller writes the theme through to the real `UserDefaults` domain,
    /// and a run that leaves it changed makes unrelated suites measure
    /// geometry under a theme nobody selected. AGENTS.md records the four
    /// separate times this project paid for that.
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-audit3-ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
            "FM_CREDENTIAL_VAULT_DIR": dir.appendingPathComponent("vault").path,
            "FM_LOG_ANALYZER_DIR": dir.appendingPathComponent("log-analyzer").path,
            "FM_COMMAND_LIBRARY_DIR": dir.appendingPathComponent("commands").path,
            "FM_SCHEDULES_FILE": dir.appendingPathComponent("schedules.json").path,
        ]
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer { for (key, value) in previous { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }
        let savedTheme = ThemeManager.shared.theme
        let savedFontSize = AppSettings.shared.fontSize
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.fontSize = savedFontSize
        }
        return body()
    }

    /// Lay a controller's view out at a real size, with no window.
    private static func laidOut(_ controller: NSViewController, width: CGFloat, height: CGFloat) {
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
    }

    /// Element-wise, never a luminance ratio: `HelmContrast.ratio(a, b) < 1.01`
    /// compares *brightness*, so two different hues of similar brightness pass
    /// it - AGENTS.md's own note, and exactly the trap a colour-equality check
    /// falls into.
    private static func sameColour(_ a: NSColor, _ b: NSColor) -> Bool {
        let x = HelmContrast.components(a), y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.002 && abs(x.1 - y.1) < 0.002 && abs(x.2 - y.2) < 0.002
    }

    private static func everyView(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { everyView(in: $0) }
    }

    // MARK: UI2 - a disabled button reads as switched off, not broken

    /// The finding, in the captain's own terms: latte's disabled Refresh is
    /// "a washed lavender pill that reads as broken".
    ///
    /// Two assertions, and the first is the one that would have caught it. A
    /// disabled button must not paint a *washed version of its own hue* -
    /// which is what `alphaValue = 0.42` over an accent fill produces, and
    /// what makes a switched-off control look like a rendering fault. So the
    /// check is that the disabled fill has moved off the accent entirely, in
    /// every palette, for the one variant whose enabled fill is the accent.
    private static func checkDisabledButtonIsNeutral(_ ok: inout Bool) {
        print("\n-- UI2: a disabled button is neutral, not a washed accent --")
        for theme in themes {
            let enabled = HelmButton.palette(variant: .primary, tint: nil, theme: theme)
            let disabled = HelmButton.disabledPalette(variant: .primary, theme: theme)
            // 1.01 is this codebase's own "same colour" threshold, and it is
            // *not* a colour-equality test on its own (AGENTS.md: two hues of
            // similar brightness pass it) - so the components are compared
            // too, which is what that note prescribes.
            let sameAsAccent = HelmContrast.ratio(disabled.fill, enabled.fill) < 1.01
                && sameColour(disabled.fill, enabled.fill)
            check(!sameAsAccent,
                  "\(theme.id): the disabled fill has left the accent",
                  &ok)
            // And it is the *neutral* surface, not merely some other colour -
            // a disabled control that picked up a different hue would pass the
            // check above and still be wrong.
            let neutral = theme.isDaylight
                ? HelmTheme.nsColor(theme.daylightTokens.inset)
                : HelmField.fill(theme)
            check(sameColour(disabled.fill, neutral),
                  "\(theme.id): the disabled fill is the theme's own sunken surface",
                  &ok)
        }

        // The recipe reaching the real control. A palette function nothing
        // calls is the other half of this defect, and the two are separately
        // breakable: `restyleBody` used to resolve `palette(...)` for both
        // states and only drop the alpha.
        withScratchEnv {
            guard let latte = HelmTheme.theme(id: "catppuccin-latte") else {
                check(false, "catppuccin-latte resolves", &ok); return
            }
            ThemeManager.shared.setTheme(latte)
            let button = HelmButton(title: "Refresh", variant: .primary)
            button.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
            let expected = HelmButton.disabledPalette(variant: .primary, theme: latte)
            button.isEnabled = false
            button.layoutSubtreeIfNeeded()
            let painted = button.layer?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear }
            check(painted.map { sameColour($0, expected.fill) } == true,
                  "a real disabled .primary paints the disabled recipe",
                  &ok)
            // The whole-control dim is what turned the accent into a wash; a
            // reintroduced one would make every assertion above invisible on
            // screen while they all still passed.
            check(button.alphaValue == 1,
                  "the control is not additionally dimmed (alpha \(button.alphaValue))",
                  &ok)
        }
    }

    // MARK: UI3 - an unselected console tab still reads as a tab

    /// "Unselected first tab renders as bare text 'Shell' beside a bordered
    /// selected chip; reads as a label, not a tab."
    ///
    /// The vacuity guard matters here: a check that only asserted "the
    /// unselected chip paints something" would pass against a chip painted
    /// the *same* as the selected one, which is the other way to get this
    /// wrong. Both are asserted - the unselected chip is painted, and the two
    /// states still differ.
    private static func checkUnselectedTabChipIsPainted(_ ok: inout Bool) {
        print("\n-- UI3: an unselected tab chip is painted, and still differs from the selected one --")
        withScratchEnv {
            for theme in themes {
                ThemeManager.shared.setTheme(theme)
                let accent = HelmTheme.nsColor(theme.accentHex)
                let muted = HelmTheme.mutedInk(theme)
                let tint = HelmTheme.nsColor(theme.chromeInkHex)

                let unselected = TabChipView(tabID: UUID(), name: "Shell")
                unselected.applyStyle(selected: false, accent: accent, muted: muted, tint: tint)
                let selected = TabChipView(tabID: UUID(), name: "Shell 2")
                selected.applyStyle(selected: true, accent: accent, muted: muted, tint: tint)

                let unselectedFill = unselected.debugChipFill
                check((unselectedFill?.alphaComponent ?? 0) > 0.01,
                      "\(theme.id): an unselected chip paints a fill",
                      &ok)
                check(unselected.debugChipBorderWidth > 0
                        && (unselected.debugChipBorder?.alphaComponent ?? 0) > 0.01,
                      "\(theme.id): an unselected chip paints an outline",
                      &ok)
                // The elevation E4 asks for: the two states are not the same
                // surface.
                let differs = unselectedFill.map { a in
                    selected.debugChipFill.map { !sameColour(a, $0) } ?? false
                } ?? false
                check(differs,
                      "\(theme.id): the selected chip is still a different surface",
                      &ok)
            }
        }
    }

    // MARK: UI4 - the Vault header count is a pill, and its cards load

    private static func checkVaultHeaderCountIsAPillAndCardsLoad(_ ok: inout Bool) {
        print("\n-- UI4: the Vault count is a pill, and its two cards show a loading state --")
        withScratchEnv {
            let vault = VaultController()
            laidOut(vault, width: 1100, height: 700)

            check(vault.debugCountBadges.count == 2,
                  "both header counts are `HelmCountBadge`s (found \(vault.debugCountBadges.count))",
                  &ok)
            for badge in vault.debugCountBadges {
                badge.layoutSubtreeIfNeeded()
                check((badge.debugFill?.alphaComponent ?? 0) > 0.01,
                      "the count badge paints a pill rather than sitting bare",
                      &ok)
                check(badge.debugCornerRadius >= HelmCountBadge.height / 2 - 0.01,
                      "the pill is a capsule (radius \(badge.debugCornerRadius))",
                      &ok)
            }
            // GL-14, and the thing the render showed: a bare `0` beside a
            // subtitle reading "Checking Automic Vault…" is a confident count
            // the page has not earned.
            check(vault.debugSecretsBadge == "?" && vault.debugToolsBadge == "?",
                  "before the first read both counts read ? rather than 0 "
                  + "(\(vault.debugSecretsBadge)/\(vault.debugToolsBadge))",
                  &ok)
            // D3's skeleton, in both cards, from the moment the page exists.
            check(vault.debugSkeletonCount == 2,
                  "both cards show a D3 skeleton while the first read is in flight "
                  + "(found \(vault.debugSkeletonCount))",
                  &ok)
        }
    }

    // MARK: UI5 - Bootstrap states each step once

    /// "Bootstrap's 'Run full setup' lists the same 4 steps as the stepper
    /// under it, and its Refresh pill sits alone in a 40pt row."
    ///
    /// Asserted from the rendered tree rather than from the source, because
    /// the failure mode is a *duplicate* and a duplicate is only visible when
    /// you count what actually rendered.
    private static func checkBootstrapDropsTheDuplicateStepSummary(_ ok: inout Bool) {
        print("\n-- UI5: Bootstrap names each setup step once, and its Refresh pill has a home --")
        withScratchEnv {
            let bootstrap = BootstrapController(hostStore: HostStore(),
                                                keyStore: SSHKeyStore(),
                                                snippetStore: SnippetStore(),
                                                dictationStore: DictationStore())
            laidOut(bootstrap, width: 1100, height: 900)
            let labels = everyView(in: bootstrap.view)
                .compactMap { ($0 as? NSTextField)?.stringValue }

            for step in SetupStepKind.allCases {
                let times = labels.filter { $0 == step.title }.count
                check(times <= 1,
                      "\"\(step.title)\" is named \(times) time(s) on the page",
                      &ok)
            }
            // The fixture's own discriminating power: if the stepper stopped
            // rendering step titles at all, every count above would be 0 and
            // the case would pass vacuously.
            let named = SetupStepKind.allCases.filter { step in labels.contains(step.title) }.count
            check(named == SetupStepKind.allCases.count,
                  "every step is still named once (found \(named) of \(SetupStepKind.allCases.count))",
                  &ok)

            // The Refresh pill is inside a card header, not alone in a band
            // across the page. Found from the pill, so a pill dropped
            // somewhere arbitrary fails rather than being looked up by a name
            // that moved with it.
            let pills = everyView(in: bootstrap.view).filter {
                $0.accessibilityLabel() == "Refresh" && $0 is HoverHighlightView
            }
            guard let pill = pills.first else {
                check(false, "the Refresh pill is still on the page", &ok); return
            }
            var host: NSView? = pill.superview
            while let current = host, !(current is HelmCard) { host = current.superview }
            check(host != nil, "the Refresh pill lives inside a card", &ok)
        }
    }

    // MARK: UI6 - the mode picker and the action no longer share a name

    private static func checkAnalyzeModePickerIsNotTheAnalyzeButton(_ ok: inout Bool) {
        print("\n-- UI6: the Log Analyzer's mode picker is distinguishable from its Analyze button --")
        withScratchEnv {
            let analyzer = LogAnalyzerController(commandLibrary: CommandLibraryStore())
            laidOut(analyzer, width: 1100, height: 800)
            let views = everyView(in: analyzer.view)
            let buttonTitles = Set(views.compactMap { ($0 as? HelmButton)?.title })
            let popupTitles = views.compactMap { $0 as? NSPopUpButton }.flatMap { $0.itemTitles }

            check(buttonTitles.contains("Analyze"),
                  "the primary Analyze action is still titled \"Analyze\"",
                  &ok)
            let collisions = popupTitles.filter { buttonTitles.contains($0) }
            check(collisions.isEmpty,
                  "no popup item shares a button's title (collisions: \(collisions))",
                  &ok)
            // And the picker still offers every mode - a fix that solved the
            // collision by deleting the modes would pass the check above.
            check(popupTitles.filter { $0.hasPrefix("Mode: ") }.count == LogAnalysisMode.allCases.count,
                  "every analysis mode is still offered, prefixed",
                  &ok)
        }
    }

    // MARK: UI7 - one icon language on the DevOps Commands page

    /// A source guard **and** a view check, because they catch different
    /// things: the source guard catches a new emoji pasted into any label on
    /// the page, and the view check catches the three this finding named
    /// actually rendering.
    private static func checkCommandLibraryUsesNoEmoji(_ ok: inout Bool) {
        print("\n-- UI7: the DevOps Commands page draws icons one way --")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP sources are not next to this binary - the guard cannot run")
            check(false, "the app's sources are locatable", &ok)
            return
        }
        let path = dir.appendingPathComponent("CommandLibraryViews.swift")
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            check(false, "CommandLibraryViews.swift is readable", &ok); return
        }
        // The three this finding named, by codepoint: an open book, a clock
        // face and a black star. Matched as the `\u{...}` escapes this file
        // writes them with, which is how they were actually spelled.
        //
        // **Comments stripped first**, the same way
        // `FM_RUN_VENDORED_PATCHES_TESTS` matches its markers - and needed for
        // the same reason in reverse: the doc comment that explains *why*
        // these glyphs left names all three of them, so a guard reading the
        // raw file would fail against the very change it is guarding.
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let slashes = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<slashes.lowerBound])
            }
            .joined(separator: "\n")
        let banned = ["\\u{1F4D6}", "\\u{1F551}", "\\u{2605}"]
        for glyph in banned {
            check(!code.contains(glyph),
                  "no \(glyph) glyph left in CommandLibraryViews.swift",
                  &ok)
        }
        // The strip did not eat the file: a guard against an empty string
        // passes for every possible glyph.
        check(code.contains("NSTextField(labelWithString:"),
              "the comment strip left real code behind (\(code.count) chars)",
              &ok)
        // The guard's own discriminating power: the file has to still be the
        // one that draws this panel, or the absences above mean nothing.
        check(source.contains("symbolHeaderLabel"),
              "the file still builds this page's section headers",
              &ok)
        check(source.contains("HelmSymbol.image"),
              "the glyphs are built through the app's one SF Symbol helper",
              &ok)
    }

    // MARK: UI8 - a row-level button reads as a control in every palette

    /// The floor, written out as a literal **on purpose**.
    ///
    /// The first version of this case read `HelmButton.secondaryBorderMinRatio`
    /// - i.e. it re-derived its expectation from the thing under test - and the
    /// injection run proved what that is worth: dropping the real constant to
    /// 1.0 produced no failure at all, because the check moved with it. That is
    /// this repo's own "re-deriving an expected value from the function under
    /// test asserts nothing" rule, caught by following it.
    ///
    /// 2.3 is `catppuccin-latte`'s measured outline separation, the one palette
    /// where this control already read correctly. Changing the recipe means
    /// changing this number too, deliberately.
    private static let outlineFloor: Double = 2.3

    private static func checkSecondaryButtonOutlineClearsTheFloor(_ ok: inout Bool) {
        print("\n-- UI8: a .secondary button's outline separates from its card in every theme --")
        check(abs(HelmButton.secondaryBorderMinRatio - Self.outlineFloor) < 0.001,
              String(format: "the shipped floor is still %.2f (got %.2f)",
                     Self.outlineFloor, HelmButton.secondaryBorderMinRatio),
              &ok)
        for theme in themes {
            let palette = HelmButton.palette(variant: .secondary, tint: nil, theme: theme)
            let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
            let ratio = HelmContrast.ratio(palette.border, card)
            check(ratio >= Self.outlineFloor - 0.001,
                  String(format: "%@: outline vs card %.3f (floor %.2f)",
                         theme.id, ratio, Self.outlineFloor),
                  &ok)
            // A "fix" that made every outline opaque would clear the floor and
            // turn a soft control into a hard one everywhere. The twelve
            // palettes' outline is deliberately translucent; the strengthening
            // must not change that.
            let declared = theme.isDaylight ? 1.0 : 0.70
            check(abs(Double(palette.border.alphaComponent) - declared) < 0.01,
                  String(format: "%@: the outline kept its own alpha (%.2f)",
                         theme.id, Double(palette.border.alphaComponent)),
                  &ok)
        }
    }

    // MARK: UI9 - a normal shell exit does not read as a fault

    private static func checkConsoleCardDistinguishesACleanExit(_ ok: inout Bool) {
        print("\n-- UI9: the Console card tells a clean exit from a failure --")
        let cases: [(String, Bool, TabModel.ExitOutcome, String, HelmModuleRowState)] = [
            ("running", true, .none, "live", .ok),
            ("clean", false, .clean, "closed", .idle),
            ("failed", false, .failed(130), "exit 130", .warn),
            ("unknown", false, .unknown, "ended", .warn),
            ("never started", false, .none, "idle", .idle),
        ]
        for (label, running, outcome, wantValue, wantState) in cases {
            let row = AppShellController.consolePeekRow(name: "Shell", running: running, lastExit: outcome)
            check(row.value == wantValue,
                  "\(label) reads \"\(row.value)\", want \"\(wantValue)\"",
                  &ok)
            check(row.state == wantState,
                  "\(label) is \(wantState), want \(wantState)",
                  &ok)
        }
        // The word the finding objected to is gone from every state, and the
        // two that genuinely are faults are not quietly reported as clean.
        let clean = AppShellController.consolePeekRow(name: "Shell", running: false, lastExit: .clean)
        let failed = AppShellController.consolePeekRow(name: "Shell", running: false, lastExit: .failed(1))
        check(clean.state != failed.state,
              "GL-14: a clean exit and a failure are not the same state",
              &ok)
    }

    // MARK: UI10 - five loading cards are not five copies of one sentence

    private static func checkWarmingCanvasCardShowsASkeletonNotASentence(_ ok: inout Bool) {
        print("\n-- UI10: a warming canvas card shows a skeleton, not a repeated sentence --")
        withScratchEnv {
            // The canvas's own function, not a hand-built `.skeleton()`: the
            // first version of this case constructed the content itself, and
            // the injection run proved it worthless - putting the old chip and
            // sentence back in `applyPendingSetupSignal` produced no failure,
            // because the test never went near it.
            var warming = HelmModuleCard.Content(title: "Updates",
                                                 subtitle: "tools & packages",
                                                 symbol: "arrow.down.circle",
                                                 hue: .blue,
                                                 chip: nil,
                                                 body: .note(""))
            HomeCanvasController.applyPendingSetupSignal(
                &warming,
                warmingUp: true,
                checking: "Checking every tool for a newer version\u{2026}",
                stale: "Tool versions haven't been checked yet this session.")
            check(warming.chip == nil,
                  "a warming card carries no chip - five of them read as one wall",
                  &ok)
            if case .skeleton = warming.body {
                check(true, "a warming card's body is the D3 skeleton", &ok)
            } else {
                check(false, "a warming card's body is the D3 skeleton (got \(warming.body))", &ok)
            }

            // The other state is not a skeleton, and that distinction is the
            // half GL-14 cares about: a pass that finished and produced
            // nothing is a fault, and a shimmer would promise an answer that
            // is not coming.
            var stale = warming
            HomeCanvasController.applyPendingSetupSignal(
                &stale,
                warmingUp: false,
                checking: "Checking every tool for a newer version\u{2026}",
                stale: "Tool versions haven't been checked yet this session.")
            if case .note(let text, _) = stale.body {
                check(text.contains("haven't been checked"),
                      "a stale card still says so in words",
                      &ok)
            } else {
                check(false, "a stale card's body is a note (got \(stale.body))", &ok)
            }

            let card = HelmModuleCard()
            card.configure(warming)
            card.frame = NSRect(x: 0, y: 0, width: 260, height: 160)
            card.layoutSubtreeIfNeeded()
            let views = everyView(in: card)
            check(views.contains { $0 is HelmSkeletonList },
                  "the skeleton body renders a `HelmSkeletonList`",
                  &ok)
            let texts = views.compactMap { ($0 as? NSTextField)?.stringValue }
            check(!texts.contains { $0.contains("Checking") },
                  "no \"Checking\" sentence is drawn in the body (\(texts))",
                  &ok)
            // The information did not vanish - it moved to the hover text, and
            // a fix that simply deleted it would pass the check above.
            check((card.toolTip ?? "").contains("Checking"),
                  "the card still says what it is waiting on, on hover",
                  &ok)
        }
    }

    // MARK: UI11 - theme names fit the grid they are laid into

    /// "Theme names truncate in the 5-column grid at 1100."
    ///
    /// Measured from the **rendered labels**, not from the column count: a
    /// column count that looks sensible still truncates if the container was
    /// narrower than the grid believed, which is exactly what happened (the
    /// grid was built against `HelmResponsiveGrid`'s 860pt fallback because
    /// nothing ever re-derived it once the container had a real width).
    private static func checkThemeGridNamesFitAtEveryWidth(_ ok: inout Bool) {
        print("\n-- UI11: every theme name fits its card, at every window width --")
        withScratchEnv {
            guard let dusk = HelmTheme.theme(id: "dusk") else {
                check(false, "dusk resolves", &ok); return
            }
            ThemeManager.shared.setTheme(dusk)
            for width in [1100.0, 1280.0, 1512.0] as [CGFloat] {
                let settings = SettingsController(hostStore: HostStore(),
                                                  keyStore: SSHKeyStore(),
                                                  snippetStore: SnippetStore(),
                                                  dictationStore: DictationStore())
                laidOut(settings, width: width, height: 900)
                let labels = settings.debugThemeNameLabels
                check(labels.count == HelmTheme.allThemes.count,
                      "at \(Int(width)): the grid renders every theme "
                      + "(\(labels.count) of \(HelmTheme.allThemes.count))",
                      &ok)
                var truncated: [String] = []
                for label in labels {
                    // `intrinsicContentSize` is the width the string wants;
                    // the frame is what it got. A label narrower than its own
                    // content is a label showing an ellipsis.
                    if label.frame.width + 0.5 < label.intrinsicContentSize.width {
                        truncated.append(label.stringValue)
                    }
                }
                check(truncated.isEmpty,
                      "at \(Int(width)): nothing truncates (\(truncated))",
                      &ok)
            }
        }
    }

    // MARK: UI12 - an empty state offers a way out of itself

    private static func checkDeadEndEmptyStatesGainedAnAction(_ ok: inout Bool) {
        print("\n-- UI12: Health's and Postmortems' empty states carry a real action --")
        withScratchEnv {
            let postmortems = PostmortemsController()
            var opened: [RailDestination] = []
            postmortems.onNavigateToDestination = { opened.append($0) }
            laidOut(postmortems, width: 1100, height: 700)

            let buttons = everyView(in: postmortems.view).compactMap { $0 as? HelmButton }
            guard let action = buttons.first(where: { !$0.title.isEmpty }) else {
                check(false, "the Postmortems empty state offers a button", &ok); return
            }
            check(true, "the Postmortems empty state offers \"\(action.title)\"", &ok)
            // Wired, not decorative. A button with no target is the same dead
            // end with a border round it.
            action.performClick(nil)
            check(opened == [.logAnalyzer],
                  "pressing it navigates somewhere real (got \(opened))",
                  &ok)

            // Health's card, with no service having reported - the state the
            // finding names. A `HealthCardView` rather than the controller, so
            // the registry's real contents cannot make this vacuous.
            var healthOpened: [RailDestination] = []
            let health = HealthCardView()
            health.onOpenDestination = { healthOpened.append($0) }
            health.refresh(theme: ThemeManager.shared.theme)
            health.card.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
            health.card.layoutSubtreeIfNeeded()
            let healthViews = everyView(in: health.card)
            if healthViews.contains(where: { $0 is HelmEmptyState }) {
                guard let button = healthViews.compactMap({ $0 as? HelmButton })
                    .first(where: { !$0.title.isEmpty }) else {
                    check(false, "Health's empty state offers a button", &ok); return
                }
                check(true, "Health's empty state offers \"\(button.title)\"", &ok)
                button.performClick(nil)
                check(healthOpened == [.schedules],
                      "pressing it navigates somewhere real (got \(healthOpened))",
                      &ok)
            } else {
                // Not a failure: this process may have registered a real
                // service before the suite ran, in which case the card is
                // correctly showing rows instead. Said out loud rather than
                // passed silently, per this repo's "a check that cannot fail
                // is worse than no check" rule.
                print("  NOTE: a background service has already reported in this "
                      + "process, so Health's empty state is not the state on screen")
            }
        }
    }

    // MARK: UI13 - the segmented-tabs divergence is deliberate, and says so

    /// **UI13 is the one finding in §5 with no code change**, and this is why
    /// that is recorded rather than left to memory.
    ///
    /// The report notes latte draws a bordered container and dusk bare
    /// capsules, and marks it "(by design, but visible when the captain
    /// switches)". It is: `HelmSegmentedTabs.applyDaylightTheme` carries the
    /// reasoning in its own doc comment - §7's resolution, so a drill page's
    /// tab strip and the floating bar's space strip read as the same control
    /// one level apart, and an accent wash under a corrected accent label
    /// would be a third surface competing with the card below it on warm
    /// paper. `HelmContrastSelfTest.checkSegmentedTabsRecipe` already asserts
    /// both recipes.
    ///
    /// So this guards the *rationale*: a future reader who meets the
    /// divergence and assumes it is an oversight will find the reason in the
    /// file, and cannot delete the reason without failing a named check.
    private static func checkSegmentedTabsDivergenceStaysDocumented(_ ok: inout Bool) {
        print("\n-- UI13: the two segmented-tab recipes are deliberate, and documented --")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP sources are not next to this binary - the guard cannot run")
            check(false, "the app's sources are locatable", &ok)
            return
        }
        let path = dir.appendingPathComponent("HelmDesignSystem.swift")
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            check(false, "HelmDesignSystem.swift is readable", &ok); return
        }
        guard let start = source.range(of: "private func applyDaylightTheme(_ theme: HelmTheme) {") else {
            check(false, "HelmSegmentedTabs still has a Daylight branch", &ok); return
        }
        // The doc comment directly above the branch.
        let head = String(source[source.startIndex..<start.lowerBound].suffix(1400))
        check(head.contains("Deliberately **not** the twelve palettes"),
              "the Daylight branch still records why it diverges",
              &ok)

        // And the divergence itself is still real, so the comment is not
        // describing something that quietly went away.
        var bordered = 0
        var bare = 0
        withScratchEnv {
            for theme in themes {
                let tabs = HelmSegmentedTabs(items: [.init(id: "a", title: "A"),
                                                     .init(id: "b", title: "B")],
                                             selected: "a")
                tabs.applyTheme(theme)
                if tabs.debugGeometry().capsuleBorderWidth > 0 { bordered += 1 } else { bare += 1 }
            }
        }
        check(bordered > 0 && bare > 0,
              "both recipes are still in use (\(bordered) bordered, \(bare) bare)",
              &ok)
    }
}

#endif
