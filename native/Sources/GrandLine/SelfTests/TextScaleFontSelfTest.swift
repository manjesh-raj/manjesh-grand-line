// Grand Line - native macOS app.
//
// GL-32's *font* half (review bug B33), and the raw log pane's row fit
// (review bug B38).
//
// `TextScaleRowHeightSelfTest` next door covers the row-height half. This one
// covers the other: a font set once when a view was built used to keep its
// size until relaunch, and - because it never went through `HelmType.scaled` -
// never got `HelmType.minimumUIPointSize`'s floor either, so roughly 150
// labels rendered at their designed 9.5-10.5pt at every setting.
//
// Four checks, and the first two only mean something together:
//
//   * a recorded font really is re-derived by `HelmTextScale.reapply(in:)`,
//     asserted *after* first proving the label is stale without it - a check
//     that cannot fail is worse than no check;
//   * a font that was set by hand, with no recipe, is left alone. That is what
//     keeps the walk clear of the terminal, the code preview and everything
//     else whose size belongs to `FontSizeManager` rather than to the chrome
//     scale;
//   * B38: a real `LogRawPaneView` row still fits its cell at every step. The
//     pane's own base row height (15) was measured against the unscaled 10.5pt
//     literal it used to draw; the floor alone raises that text to 11pt before
//     any scale is applied, so the height it was measured at is exactly the
//     thing this fix could have broken;
//   * the source guard - no raw `.systemFont(ofSize: <literal>)` assignment
//     comes back into this app's own chrome, which is what stops site 151.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TextScaleFontSelfTest {

    static func run() -> Bool {
        // Same hazard `TextScaleRowHeightSelfTest` documents: `setScale`
        // writes through to the real `AppSettings.uiTextScale`.
        let captainScale = ChromeTextScale.shared.scale
        defer { ChromeTextScale.shared.setScale(captainScale) }

        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        checkRecordedFontsReDeriveOnAScaleChange(check)
        checkAnUnrecordedFontIsLeftAlone(check)
        checkTheFloorReachesASubElevenPointSite(check)
        checkTheRawLogPaneRowStillFits(check)
        checkNoRawFontLiteralIsAssignedInAppChrome(check)

        ChromeTextScale.shared.setScale(captainScale)

        if failures.isEmpty {
            print("TextScaleFontSelfTest: OK")
            return true
        }
        print("TextScaleFontSelfTest: \(failures.count) failure(s)")
        for f in failures { print("  - \(f)") }
        return false
    }

    // MARK: - The mechanism

    /// The whole of B33: a label built once, never re-themed, still follows
    /// the setting.
    private static func checkRecordedFontsReDeriveOnAScaleChange(_ check: (Bool, String) -> Void) {
        ChromeTextScale.shared.setScale(1.0)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        let nested = NSView()
        container.addSubview(nested)

        let label = NSTextField(labelWithString: "contract-ingest-worker-0")
        label.setScaledFont(ofSize: 12.5, weight: .semibold)
        nested.addSubview(label)

        let code = NSTextField(labelWithString: "0xdeadbeef")
        code.setScaledFont(ofSize: 11.5, voice: .monospaced)
        nested.addSubview(code)

        check(abs((label.font?.pointSize ?? 0) - HelmType.scaled(12.5)) < 0.01,
              "a freshly recorded label is \(label.font?.pointSize ?? 0)pt, want \(HelmType.scaled(12.5))pt")
        check(code.font?.isFixedPitch == true,
              "the monospaced voice did not resolve to a fixed-pitch face")

        let before = label.font?.pointSize ?? 0
        ChromeTextScale.shared.setScale(1.3)

        // Discriminating power first: without the walk the label must still
        // be stale, or the assertion after it proves nothing.
        check(abs((label.font?.pointSize ?? 0) - before) < 0.01,
              "the label re-derived itself with no walk, so this check proves nothing")

        HelmTextScale.reapply(in: container)

        check(abs((label.font?.pointSize ?? 0) - HelmType.scaled(12.5)) < 0.01,
              "after the walk the label is \(label.font?.pointSize ?? 0)pt, want \(HelmType.scaled(12.5))pt")
        check(abs((code.font?.pointSize ?? 0) - HelmType.scaled(11.5)) < 0.01,
              "after the walk the nested code label is \(code.font?.pointSize ?? 0)pt, "
              + "want \(HelmType.scaled(11.5))pt - the walk did not reach a grandchild")
        check(code.font?.isFixedPitch == true,
              "the walk re-derived the monospaced label into a proportional face")

        // And a second change is derived from the *base*, not compounded from
        // what is on screen - the whole reason the recipe stores the designed
        // size rather than the rendered one.
        ChromeTextScale.shared.setScale(1.15)
        HelmTextScale.reapply(in: container)
        check(abs((label.font?.pointSize ?? 0) - HelmType.scaled(12.5)) < 0.01,
              "a second scale change compounded: the label is \(label.font?.pointSize ?? 0)pt, "
              + "want \(HelmType.scaled(12.5))pt")
    }

    /// The other half of the same mechanism: the walk must be a no-op for
    /// anything it was not given a recipe for.
    private static func checkAnUnrecordedFontIsLeftAlone(_ check: (Bool, String) -> Void) {
        ChromeTextScale.shared.setScale(1.0)
        let container = NSView()
        let terminalish = NSTextField(labelWithString: "$ swift build")
        terminalish.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        container.addSubview(terminalish)

        ChromeTextScale.shared.setScale(1.3)
        HelmTextScale.reapply(in: container)

        check(abs((terminalish.font?.pointSize ?? 0) - 22) < 0.01,
              "the walk resized a font it never recorded: \(terminalish.font?.pointSize ?? 0)pt, "
              + "want the 22pt it was set to - a FontSizeManager-owned view would be hijacked")
    }

    /// The floor half, at the smallest literal the sweep actually converted.
    /// `LogRawLineCell`'s gutter number was a 9.5pt literal, below GL-32's
    /// own 11pt minimum, at every setting including Default.
    private static func checkTheFloorReachesASubElevenPointSite(_ check: (Bool, String) -> Void) {
        ChromeTextScale.shared.setScale(1.0)
        let label = NSTextField(labelWithString: "1024")
        label.setScaledFont(ofSize: 9.5, weight: .regular, voice: .monospaced)
        check((label.font?.pointSize ?? 0) >= HelmType.minimumUIPointSize - 0.01,
              "a 9.5pt designed size rendered at \(label.font?.pointSize ?? 0)pt, below GL-32's "
              + "\(HelmType.minimumUIPointSize)pt floor")
    }

    // MARK: - B38

    /// B38, and the reason it is here rather than in the row-height suite:
    /// the row height was already scaled, and what was wrong was the *font*
    /// inside it. Raising 9.5/10.5 to a floored 11 is exactly the change that
    /// can make a 15pt row clip, so this measures a real cell from the real
    /// pane at all three steps.
    ///
    /// **Which class.** The 2026-09-25 review's condensed summary named
    /// `LogErrorGroupListView`; an earlier audit made the same citation error
    /// and `docs/history/28-full-app-audit-2.md` records the correction. The
    /// unscaled literals were in `LogRawPaneView`'s cell. Both are measured
    /// below so the answer is in the run output rather than in a claim.
    private static func checkTheRawLogPaneRowStillFits(_ check: (Bool, String) -> Void) {
        let theme = ThemeManager.shared.theme
        let text = (1...6).map { "2026-09-25T04:1\($0):22Z ERROR ingest worker failed: connection reset" }
            .joined(separator: "\n")

        for step in ChromeTextScale.steps {
            ChromeTextScale.shared.setScale(step.scale)
            autoreleasepool {
                let pane = LogRawPaneView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
                pane.setText(text, theme: theme)
                pane.layoutSubtreeIfNeeded()
                guard let cell = pane.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) else {
                    check(false, "the raw pane produced no cell at \(step.title)")
                    return
                }
                cell.frame = NSRect(x: 0, y: 0, width: 640, height: LogRawPaneView.rowHeight)
                cell.layoutSubtreeIfNeeded()
                // The cell's own `fittingSize.height` is 0 and always will
                // be: its two labels are pinned by `centerY` alone, so
                // nothing ties the cell's height to its content. What the row
                // actually has to hold is the taller label's own line box,
                // which is what this measures instead. (Measured, not
                // assumed - the first draft of this check asserted
                // `cell.fittingSize.height <= rowHeight` and passed 0 <= 15
                // at every scale, which is exactly the vacuous check this
                // repository's conventions forbid.)
                let needed = cell.subviews
                    .compactMap { ($0 as? NSTextField)?.fittingSize.height }
                    .max() ?? 0
                check(needed > 0, "the raw pane's cell measured no height at all at \(step.title)")
                check(needed <= LogRawPaneView.rowHeight + 0.01,
                      "at \(step.title) a raw log line needs \(needed)pt but LogRawPaneView gives "
                      + "it \(LogRawPaneView.rowHeight)pt - the floored font clips")
            }

            // The class the review named, measured too. Its sample cell was
            // already on `HelmType.code()`, so this should simply hold.
            autoreleasepool {
                let list = LogErrorGroupListView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
                list.layoutSubtreeIfNeeded()
                check(LogErrorGroupListView.sampleRowHeight
                      >= LogErrorGroupListView.baseSampleRowHeight * step.scale - 0.01,
                      "LogErrorGroupListView's sample row did not follow the scale at \(step.title)")
            }
        }
    }

    // MARK: - The source guard

    /// No new raw literal. The needle is the *assignment* form - `x.font =
    /// .systemFont(ofSize: 11)` - which is what every one of the ~150
    /// converted sites looked like, rather than any mention of the
    /// constructor: a size computed from `HelmType.scaled`, from
    /// `FontSizeManager`, or from a caller's parameter is legitimate and
    /// stays.
    private static func checkNoRawFontLiteralIsAssignedInAppChrome(_ check: (Bool, String) -> Void) {
        guard let files = SelfTestSources.appSourceFiles() else {
            check(false, "could not resolve the app's source directory - this guard cannot run")
            return
        }

        // A deliberate, stated exemption per file, never a blanket allowlist.
        let exempt: [String: String] = [
            // The recipe's own resolver. It *is* the scaled path.
            "HelmTextScale.swift": "builds the scaled font",
            // Every `HelmType` role, which applies `scaled` itself.
            "HelmDesignSystem.swift": "the roles are the scaled path",
            // A print/PDF view: fixed black on white, observes no theme and
            // no scale, and the same view renders both paper and file.
            "CredentialVaultRecoveryKitView.swift": "print view, deliberately unthemed",
        ]

        // Assert the needle matches something it must match before trusting a
        // clean sweep - a drifted pattern otherwise passes vacuously.
        let probe = "        label.font = .systemFont(ofSize: 11, weight: .semibold)"
        check(matchesRawAssignment(probe),
              "the guard's own pattern no longer matches a raw assignment - it would pass vacuously")
        check(!matchesRawAssignment("        label.font = .systemFont(ofSize: HelmType.scaled(11))"),
              "the guard's own pattern matches a scaled assignment - it would fail every clean file")

        var offenders: [String] = []
        var scanned = 0
        for url in files {
            let name = url.lastPathComponent
            if exempt[name] != nil { continue }
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for (index, line) in body.components(separatedBy: "\n").enumerated()
            where matchesRawAssignment(line) {
                offenders.append("\(name):\(index + 1) \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        check(scanned > 100, "only \(scanned) source files were scanned - the sweep did not run")
        check(offenders.isEmpty,
              "raw unscaled font assignments are back (GL-32/B33): "
              + offenders.prefix(6).joined(separator: "; "))
    }

    /// `<anything>.font = .systemFont(ofSize: <number>` and its two
    /// monospaced siblings, with comments excluded.
    private static func matchesRawAssignment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { return false }
        guard trimmed.contains(".font = .") else { return false }
        for ctor in [".systemFont(ofSize: ", ".monospacedSystemFont(ofSize: ",
                     ".monospacedDigitSystemFont(ofSize: "] {
            guard let range = trimmed.range(of: ctor) else { continue }
            let rest = trimmed[range.upperBound...]
            if let first = rest.first, first.isNumber { return true }
        }
        return false
    }
}

#endif
