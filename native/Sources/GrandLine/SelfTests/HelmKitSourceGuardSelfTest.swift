// Grand Line - native macOS app.
//
// The UI/UX revamp's source guards (UI-40): the recipes the revamp put into
// shared components, kept there.
//
// The revamp's own finding was that the layout proposals of the previous
// rounds landed and the *recipe* proposals did not survive the port - each
// page re-derived a pill, a shadow or a spacing number privately, and the
// next page copied the copy. A recipe that only lives in a component is one
// grep away from being re-spelled, so each one the revamp fixed gets a guard
// here, in CI's blocking lane.
//
// Run with `FM_RUN_HELM_KIT_GUARD_TESTS=1 .build/debug/GrandLine`.
//
// Pure source reads - no window, no session. Deliberately NOT in
// `NEEDS_SESSION`.
//
// What it guards:
//
//   1. **Depth is painted once (UI-5, Rule 2).** A file that reads
//      `HelmCard.elevation(for:)` must not also assign `shadowOpacity`
//      itself. That pairing is exactly the squared-alpha defect: the
//      elevation colour already carries the level's alpha, and copying it
//      into `shadowOpacity` multiplies it in twice. `HelmCard.applyElevation`
//      is the one place that does the conversion.
//   2. **One status pill (UI-32, Rule 4).** `ToolRowLayout.pill(` is called
//      only by `HelmStatusPill` (and the helper's own file). A page that
//      paints a pill by hand fails here and should build a `HelmStatusPill`.
//   3. **Spacing and radii come from the scale (UI-40).** A literal
//      `.spacing =`, `spacing:` or `cornerRadius =` whose value is not on
//      `HelmMetrics`' scale is counted per file. The files the revamp rebuilt
//      carry no non-zero literal at all; every other file may not exceed the
//      count it had when the guard landed. That is a ratchet, not a cleanup:
//      a file that loses literals passes, and its entry can be lowered.
//   4. **No stock system chrome (UI-61).** `NSAlert()` only where a command
//      or binary is about to run outside this app's control - the risk gates
//      and the AI-authored gate in `CommandLibraryViews.swift`, and the herdr
//      restart - which is AGENTS.md's own carve-out for `HelmConfirm`.
//      `NSProgressIndicator()` nowhere (`HelmProgressBar`, `HelmSkeleton`),
//      and `NSSwitch()` only inside `HelmToggle`, which keeps one as its
//      pre-Daylight shape.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum HelmKitSourceGuardSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== HelmKitSourceGuardSelfTest ==")
        guard let files = SelfTestSources.appSourceFiles(), !files.isEmpty else {
            print("  SKIP: app sources not next to this binary")
            return true
        }
        checkShadowsArePaintedOnce(files, &ok)
        checkPillsGoThroughTheKit(files, &ok)
        checkLiteralScanner(&ok)
        checkSpacingComesFromTheScale(files, &ok)
        checkNoStockSystemChrome(files, &ok)
        print(ok ? "HelmKitSourceGuardSelfTest: OK" : "HelmKitSourceGuardSelfTest: FAILED")
        return ok
    }

    /// Strips `//` comments so a doc comment that *describes* the forbidden
    /// shape (this file's header does, and so does `applyElevation`'s) does
    /// not trip the guard it documents.
    static func codeLines(_ source: String) -> [String] {
        source.components(separatedBy: "\n").map { line in
            guard let range = line.range(of: "//") else { return line }
            return String(line[..<range.lowerBound])
        }
    }

    // MARK: 1 - depth is painted once

    /// The one file allowed to read the elevation colour and set an opacity
    /// from it: the file that defines the conversion.
    static let elevationOwner = "HelmDesignSystem.swift"

    private static func checkShadowsArePaintedOnce(_ files: [URL], _ ok: inout Bool) {
        var readers = 0
        for file in files where file.lastPathComponent != elevationOwner {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = codeLines(source).joined(separator: "\n")
            guard code.contains("HelmCard.elevation(for") else { continue }
            readers += 1
            let assignsOpacity = code.range(of: #"\.shadowOpacity\s*="#, options: .regularExpression) != nil
            check(!assignsOpacity,
                  "\(file.lastPathComponent) reads HelmCard.elevation(for:) and assigns shadowOpacity "
                      + "itself - route the layer through HelmCard.applyElevation, which applies the "
                      + "level's alpha once", &ok)
        }
        // The discriminating half: the guard has to be looking at the files
        // that genuinely read the elevation, or it passes by finding nothing.
        check(readers >= 1,
              "expected at least one file outside \(elevationOwner) to read HelmCard.elevation(for:), "
                  + "found \(readers) - the guard is no longer looking at anything", &ok)
    }

    // MARK: 2 - one status pill

    /// Files allowed to call `ToolRowLayout.pill(` directly: the class that
    /// defines it and the kit class that wraps it. Every page's pill is a
    /// `HelmStatusPill` since the revamp's sweep.
    static let pillCallAllowlist: Set<String> = [
        "HelmUIComponents.swift",
        "HelmKit.swift",
    ]

    private static func checkPillsGoThroughTheKit(_ files: [URL], _ ok: inout Bool) {
        var seenKit = false
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = codeLines(source).joined(separator: "\n")
            guard code.contains("ToolRowLayout.pill(") else { continue }
            if file.lastPathComponent == "HelmKit.swift" { seenKit = true }
            check(pillCallAllowlist.contains(file.lastPathComponent),
                  "\(file.lastPathComponent) paints a pill with ToolRowLayout.pill - build a HelmStatusPill "
                      + "(HelmKit.swift) instead, so the recipe cannot be re-spelled", &ok)
        }
        check(seenKit, "HelmStatusPill should be found wrapping ToolRowLayout.pill - the guard is blind", &ok)
    }
    // MARK: 3 - spacing and radii come from the scale

    /// `HelmMetrics.s0 ... s6`, plus zero.
    static let spacingScale: Set<CGFloat> = [0, HelmMetrics.s0, HelmMetrics.s1, HelmMetrics.s2, HelmMetrics.s3,
                                             HelmMetrics.s4, HelmMetrics.s5, HelmMetrics.s6]
    /// The pre-Daylight role radii, the Daylight set, plus zero.
    static let radiusScale: Set<CGFloat> = Set([0, HelmMetrics.rChip, HelmMetrics.rControl, HelmMetrics.rCard,
                                                HelmMetrics.rRow]).union(HelmMetrics.daylightRadii)

    /// The files the revamp rebuilt. They spell no spacing or radius as a
    /// number at all, on the scale or off it - only tokens (and zero).
    static let tokenOnlyFiles: Set<String> = [
        "DaylightBarController.swift",
        "HelmKit.swift",
        "HelmModuleCard.swift",
        "HelmPlateCard.swift",
        "HomeCanvasController.swift",
        "NeedsAttentionCard.swift",
        "ShiftBoardViews.swift",
        "ShiftController.swift",
        "ShiftListViews.swift",
    ]

    /// Off-scale literals per file when the guard landed. A file may go
    /// down, never up, and a file not listed here must have none.
    static let offScaleBaseline: [String: Int] = [
        "AutomationController.swift": 3,
        "BlockView.swift": 2,
        "BootstrapController.swift": 15,
        "CommandLibraryAIPopover.swift": 2,
        "CommandLibraryViews.swift": 3,
        "CompactModePopover.swift": 4,
        "ConsoleComposerPopover.swift": 2,
        "CredentialVaultRecoverySheet.swift": 1,
        "DailyReviewCard.swift": 3,
        "DictationController.swift": 11,
        "DictationHistoryAndVocabularyViews.swift": 1,
        "DiffResultView.swift": 4,
        "DocsController.swift": 1,
        "FleetController+Reply.swift": 1,
        "FleetController.swift": 1,
        "GitHubSyncController.swift": 3,
        "HealthCardView.swift": 2,
        "HealthController.swift": 1,
        "HelmDesignSystem.swift": 4,
        "HelmForm.swift": 4,
        "HelmSkeleton.swift": 1,
        "HelmUIComponents.swift": 1,
        "HostEditorController.swift": 2,
        "HostsSidebar.swift": 1,
        "IncidentCardView.swift": 1,
        "KeyChordRecorderView.swift": 1,
        "KeyboardShortcutsSheetController.swift": 1,
        "LockScreenController.swift": 2,
        "LogAnalyzerController.swift": 16,
        "LogAnalyzerViews.swift": 1,
        "NotebookController.swift": 1,
        "NotebookPreviewView.swift": 3,
        "NotificationCenterPopover.swift": 2,
        "PoneglyphMenuBar.swift": 1,
        "PortForwardingController.swift": 3,
        "QuotaUsagePopover.swift": 7,
        "ReadingListCardView.swift": 1,
        "ReviewController.swift": 3,
        "ReviewPRListView.swift": 1,
        "RunbooksController.swift": 1,
        "SRELeadChatView.swift": 7,
        "ScheduleHistoryController.swift": 2,
        "ScheduleRunLogController.swift": 2,
        "SchedulesCardView.swift": 1,
        "SchedulesController.swift": 1,
        "SchedulesInsights.swift": 1,
        "SessionStripView.swift": 1,
        "SettingsController.swift": 4,
        "SettingsForm.swift": 1,
        "SettingsThemeCard.swift": 2,
        "ShiftCalendarViews.swift": 1,
        "ShiftConflictController.swift": 7,
        "ShiftImageAttachmentWell.swift": 1,
        "ShiftMenuBar.swift": 1,
        "ShiftProjectDetailView.swift": 1,
        "ShiftSnoozeCustomController.swift": 2,
        "SnippetExpansionPanel.swift": 1,
        "StickyBoardController.swift": 2,
        "StickyBoardViews.swift": 2,
        "StrawHatChatView.swift": 6,
        "StrawHatMenuBar.swift": 3,
        "StrawHatRosterView.swift": 2,
        "TabChipView.swift": 1,
        "ToolInstance.swift": 2,
        "ToolsController.swift": 3,
        "UnifiedSearch.swift": 3,
        "UpdatesController.swift": 2,
        "VaultController.swift": 10,
        "WhiteboardComposerPopover.swift": 2,
        "WhiteboardDSLPopover.swift": 1,
    ]

    struct Literal: Equatable {
        let isRadius: Bool
        let value: CGFloat
    }

    /// Every `.spacing = N`, `spacing: N` and `cornerRadius = N` in code
    /// (comments stripped).
    static func literals(in source: String) -> [Literal] {
        let pattern = #"(\.spacing = |spacing: |cornerRadius = )([0-9]+(?:\.[0-9]+)?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [Literal] = []
        for line in codeLines(source) {
            let ns = line as NSString
            for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let prefix = ns.substring(with: match.range(at: 1))
                guard let value = Double(ns.substring(with: match.range(at: 2))) else { continue }
                found.append(Literal(isRadius: prefix.hasPrefix("cornerRadius"), value: CGFloat(value)))
            }
        }
        return found
    }

    static func isOnScale(_ literal: Literal) -> Bool {
        literal.isRadius ? radiusScale.contains(literal.value) : spacingScale.contains(literal.value)
    }

    /// The discriminating half: the scanner has to find what it is looking
    /// for, and has to tell the scale from a near miss, or the ratchet below
    /// passes by counting nothing.
    private static func checkLiteralScanner(_ ok: inout Bool) {
        let fixture = """
        stack.spacing = 7
        row.spacing = HelmMetrics.s2
        verticalStack([a], spacing: 8)
        layer?.cornerRadius = 9
        layer?.cornerRadius = 10 // stack.spacing = 5 in a comment
        """
        let found = literals(in: fixture)
        check(found == [Literal(isRadius: false, value: 7), Literal(isRadius: false, value: 8),
                        Literal(isRadius: true, value: 9), Literal(isRadius: true, value: 10)],
              "the literal scanner should find exactly 7, 8, radius 9 and radius 10 in the fixture, got \(found)", &ok)
        check(found.filter { !isOnScale($0) }.count == 2,
              "7 and radius 9 are off the scale; 8 and radius 10 are on it", &ok)
    }

    private static func checkSpacingComesFromTheScale(_ files: [URL], _ ok: inout Bool) {
        var total = 0
        var seen = Set<String>()
        for file in files {
            let name = file.lastPathComponent
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            seen.insert(name)
            let found = literals(in: source)
            let offScale = found.filter { !isOnScale($0) }
            total += offScale.count
            if tokenOnlyFiles.contains(name) {
                let numbers = found.filter { $0.value != 0 }
                check(numbers.isEmpty,
                      "\(name) was rebuilt on the kit and must spell spacing and radii as HelmMetrics tokens, "
                          + "found \(numbers.map { ($0.isRadius ? "cornerRadius " : "spacing ") + "\($0.value)" })", &ok)
                continue
            }
            let allowed = offScaleBaseline[name] ?? 0
            check(offScale.count <= allowed,
                  "\(name) has \(offScale.count) off-scale spacing/radius literal(s), its baseline is \(allowed) - "
                      + "use HelmMetrics.s0...s6 or a radius token "
                      + "(\(offScale.map { ($0.isRadius ? "cornerRadius " : "spacing ") + "\($0.value)" }))", &ok)
        }
        for name in tokenOnlyFiles {
            check(seen.contains(name), "\(name) is listed as token-only but no longer exists", &ok)
        }
        // The guard has to be looking at the app's real sources.
        check(total > 0, "expected the existing off-scale literals to be counted, found none - the guard is blind", &ok)
        print("  off-scale spacing/radius literals across the app: \(total) "
              + "(baseline \(offScaleBaseline.values.reduce(0, +)))")
    }
    // MARK: 4 - no stock system chrome

    /// Where each stock control may still be constructed, and why.
    static let stockChromeAllowlist: [String: Set<String>] = [
        // A system-level stop is the point: the command is about to run
        // outside the app (AGENTS.md's `HelmConfirm` carve-out).
        "NSAlert()": ["CommandLibraryViews.swift", "ConsoleController+Herdr.swift"],
        "NSProgressIndicator()": [],
        // `HelmToggle`'s pre-Daylight shape.
        "NSSwitch()": ["HelmForm.swift"],
    ]

    private static func checkNoStockSystemChrome(_ files: [URL], _ ok: inout Bool) {
        var seenAllowed = 0
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = codeLines(source).joined(separator: "\n")
            for (token, allowed) in stockChromeAllowlist where code.contains(token) {
                if allowed.contains(file.lastPathComponent) {
                    seenAllowed += 1
                    continue
                }
                fail("\(file.lastPathComponent) constructs \(token) - use HelmConfirm, HelmProgressBar or "
                     + "HelmToggle (UI-61)", &ok)
            }
        }
        // The discriminating half: the scan has to see the sanctioned sites.
        check(seenAllowed >= 3, "expected the sanctioned NSAlert/NSSwitch sites to be found, saw "
              + "\(seenAllowed) - the guard is blind", &ok)
    }
}

#endif
