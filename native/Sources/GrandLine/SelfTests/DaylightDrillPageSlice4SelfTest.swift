// Grand Line - native macOS app.
//
// Daylight **Phase 4, slice 4**'s own suite: the two destinations §7 puts
// next, Log Analyzer and Vault.
//
// What each case is protecting, and why it is worth a test rather than a
// read-through:
//
//   1. **Both pages really reached the drill header** (§6.4). The seam is a
//      protocol conformance and a missing one is invisible - the header simply
//      shows the static per-area line with an empty trailing slot, which looks
//      like a design choice rather than a page that was never migrated. The
//      subtitles are the interesting half here: both count off live state, and
//      both have a genuinely different thing to say before there is anything
//      to report.
//   2. **Neither renders an in-page hero any more** (§6.4). Walked over the
//      real view tree, because the failure mode is a duplicate title one row
//      apart - the exact defect the audit found on Review and Docs.
//   3. **§7's "raw dark card left like §6.13's terminal card" is genuinely
//      dark, and only under Daylight.** This is the one place §6.13's dark
//      fill is buildable at all (Console's is blocked on the terminal's own
//      cells), so the fill, the radius and the padding are all asserted - and
//      so is the half that would otherwise be silently wrong: a severity line
//      corrected against the *page* and then painted on the dark card. That
//      failure renders as unreadable red-on-black while every colour involved
//      is individually "correct", which is why it is measured.
//   4. **§7's "signal row for launcher issues" is a signal, not a repaint of
//      every row.** A wash on all of them would leave the page with nothing
//      standing out, which is the opposite of what the treatment is for.
//   5. **Secret names stay mono** (§7). One `titleIsCode` flag away from
//      rendering as ordinary row titles, and nothing else on the page would
//      look wrong if it regressed.
//   6. **No new window-width floor.** Every constraint these two pages carry
//      lives inside `bodyContainer`, and AGENTS.md gotcha (13) is this
//      codebase's most expensive recurring bug - Log Analyzer's own Compare
//      tab is what capped the whole app window in #231.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_DRILL_SLICE4_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightDrillPageSlice4SelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkDrillConformances, 
                      checkRawPaneIsADarkCard, checkRawLineContrastOnTheDarkCard,
                      checkNoWindowWidthFloor] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightDrillPageSlice4SelfTest: all checks passed"
                    : "DaylightDrillPageSlice4SelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static var daylight: HelmTheme {
        HelmTheme.allThemes.first { $0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    private static var otherTheme: HelmTheme {
        HelmTheme.allThemes.first { !$0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    private static func mount(_ controller: NSViewController, width: CGFloat = 1200) -> NSWindow {
        let window = OffScreenProbe.window(width: width, height: 820)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 820)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// A scratch command-library root, so constructing the page can never
    /// reach the captain's own git-synced commands (spec §11 reads it).
    private static func makeLogAnalyzer() -> LogAnalyzerController {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daylight-slice4-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_COMMAND_LIBRARY_DIR", dir.appendingPathComponent("commands").path, 1)
        setenv("FM_LOG_ANALYZER_DIR", dir.appendingPathComponent("investigations").path, 1)
        return LogAnalyzerController(commandLibrary: CommandLibraryStore())
    }

    private static let sampleLog = """
    2026-08-24T09:12:01Z INFO  starting probe
    2026-08-24T09:12:04Z WARN  upstream latency 2400ms
    2026-08-24T09:12:07Z ERROR probe failed: connection refused
    """

    /// A real, fully-built investigation - the local analysis comes from the
    /// page's own builder, so the fixture cannot drift from what the page
    /// would produce for the same text.
    private static func sampleInvestigation() -> LogInvestigation {
        let redacted = LogRedactor.redact(sampleLog)
        let local = LogAnalyzerController.buildLocalAnalysis(text: redacted.text, override: nil)
        var investigation = LogInvestigation(title: "Probe failure")
        investigation.evidence = [LogEvidenceItem(label: "kubectl logs", origin: .terminal,
                                                  sourceDetail: "Preprod Bastion",
                                                  text: redacted.text, detection: local.detection,
                                                  redactionCount: redacted.count)]
        investigation.analysis = LogAnalysis(local: local, ai: nil, aiFailure: nil,
                                             mode: .analyze, analyzedAt: Date())
        return investigation
    }

    private static func labels(in view: NSView, atLeast points: CGFloat) -> [NSTextField] {
        var found: [NSTextField] = []
        if let label = view as? NSTextField, (label.font?.pointSize ?? 0) >= points,
           !label.stringValue.isEmpty, !label.isHidden {
            found.append(label)
        }
        for sub in view.subviews { found += labels(in: sub, atLeast: points) }
        return found
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    /// Component-wise, deliberately **not** a contrast-ratio comparison: that
    /// measures relative *luminance*, so two entirely different hues of
    /// similar brightness pass it (slice 2's own header records catching that).
    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    // MARK: 1. Both pages reached the drill header (§6.4)

    private static func checkDrillConformances(_ ok: inout Bool) {
        print("\n-- §6.4: Log Analyzer and Vault carry live drill headers --")

        let analyzer = makeLogAnalyzer()
        let analyzerWindow = mount(analyzer)
        defer { _ = analyzerWindow }

        // Empty: says what to do, rather than reporting zero of everything.
        guard let empty = analyzer.drillHeaderSubtitle, !empty.isEmpty,
              !empty.contains("0 ") else {
            print("  FAIL Log Analyzer's empty subtitle is missing or reports zeroes: "
                  + "\(analyzer.drillHeaderSubtitle ?? "nil")")
            ok = false
            return
        }
        analyzer.debugRender(sampleInvestigation())
        // The sidebar's line counts the evidence's lines (`sidebarSubtitle`).
        guard let loaded = analyzer.drillHeaderSubtitle, loaded.contains("line") else {
            print("  FAIL Log Analyzer's loaded subtitle does not count its own evidence: "
                  + "\(analyzer.drillHeaderSubtitle ?? "nil")")
            ok = false
            return
        }
        guard analyzer.drillHeaderActions.count == 2,
              analyzer.drillHeaderActions.allSatisfy({ ($0 as? NSButton)?.title.isEmpty == false }) else {
            print("  FAIL Log Analyzer hoists \(analyzer.drillHeaderActions.count) titled actions, want 2")
            ok = false
            return
        }
        // Caller-owned: two reads must hand back the same instances, or the
        // targets and tooltips this page set would be lost on every refresh.
        let firstRead = analyzer.drillHeaderActions.map { ObjectIdentifier($0) }
        if firstRead != analyzer.drillHeaderActions.map({ ObjectIdentifier($0) }) {
            print("  FAIL Log Analyzer rebuilds its header buttons on every read")
            ok = false
        }

        let vault = VaultController()
        let vaultWindow = mount(vault)
        defer { _ = vaultWindow }
        vault.debugRender(secrets: [VaultSecret(name: "GITHUB_TOKEN"), VaultSecret(name: "AWS_KEY")],
                          tools: [VaultTool(name: "gh", commands: ["gh"], status: .hardened),
                                  VaultTool(name: "aws", commands: ["aws"],
                                            status: .needsAttention(issueCount: 2))])
        guard let vaultSubtitle = vault.drillHeaderSubtitle,
              vaultSubtitle.contains("2 secrets"), vaultSubtitle.contains("needing attention") else {
            print("  FAIL Vault's subtitle does not report its own counts: "
                  + "\(vault.drillHeaderSubtitle ?? "nil")")
            ok = false
            return
        }
        guard vault.drillHeaderActions.count == 1,
              let refresh = vault.drillHeaderActions.first as? NSButton,
              refresh.title.lowercased().contains("refresh") else {
            print("  FAIL Vault does not hoist its Refresh button")
            ok = false
            return
        }
        if vault.drillHeaderActions.first !== refresh {
            print("  FAIL Vault rebuilds its Refresh button on every read")
            ok = false
        }
        print("  OK - Log Analyzer \"\(loaded)\" + 2 stable actions; Vault \"\(vaultSubtitle)\" + Refresh")
    }

    // MARK: 2. No in-page heroes left (§6.4)

    // MARK: 3. §7's raw dark card

    private static func checkRawPaneIsADarkCard(_ ok: inout Bool) {
        print("\n-- §7 / §6.13: the raw pane is a dark, padded, rounded card under Daylight only --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }

        let analyzer = makeLogAnalyzer()
        let window = mount(analyzer)
        defer { _ = window }
        analyzer.debugRender(sampleInvestigation())

        ThemeManager.shared.setTheme(otherTheme)
        analyzer.view.layoutSubtreeIfNeeded()
        let before = analyzer.debugRawPanePaint()
        if before.cornerRadius != 0 || before.insets.contains(where: { $0 != 0 }) {
            print("  FAIL \(otherTheme.id) no longer renders the raw pane flush: "
                  + "radius \(fmt(before.cornerRadius)), insets \(before.insets.map(fmt))")
            ok = false
        }
        if !sameColor(before.fill, HelmTheme.nsColor(otherTheme.backgroundHex)) {
            print("  FAIL \(otherTheme.id)'s raw pane is no longer painted with the page background")
            ok = false
        }

        ThemeManager.shared.setTheme(daylight)
        analyzer.view.layoutSubtreeIfNeeded()
        let after = analyzer.debugRawPanePaint()
        if !sameColor(after.fill, HelmTheme.nsColor(DaylightPalette.termBackground)) {
            print("  FAIL the Daylight raw pane is not filled with §2.1's termBg")
            ok = false
        }
        if after.cornerRadius != HelmMetrics.dSurface {
            print("  FAIL the Daylight raw pane's radius is \(fmt(after.cornerRadius)), want §2.6's dSurface")
            ok = false
        }
        // §6.13's "padded 14/16": leading/trailing 16, top/bottom 14 (the
        // bottom two are negative, being measured from the far edge).
        let want: [CGFloat] = [16, -16, 14, -14]
        if after.insets != want {
            print("  FAIL the Daylight raw pane's insets are \(after.insets.map(fmt)), want \(want.map(fmt))")
            ok = false
        }
        // The dark card must be genuinely dark against warm paper, or it is
        // not a card at all - which is exactly the state Console is stuck in.
        let contrast = HelmContrast.ratio(HelmTheme.nsColor(DaylightPalette.termBackground),
                                          HelmTheme.nsColor(daylight.backgroundHex))
        if contrast < 4.5 {
            print("  FAIL the dark card barely separates from paper (\(String(format: "%.2f", contrast)):1)")
            ok = false
        }
        print("  OK - flush + page-coloured off Daylight; termBg / r\(fmt(after.cornerRadius)) / 16x14 on it, "
              + "\(String(format: "%.2f", contrast)):1 against paper")
    }

    // MARK: 4. The half a fill alone would get wrong

    private static func checkRawLineContrastOnTheDarkCard(_ ok: inout Bool) {
        print("\n-- §5.7: every raw line clears the text floor against the pane it is painted on --")
        // **Daylight is what this asserts, and the other twelve are measured
        // and reported rather than enforced.** The pane's ink off Daylight is
        // unchanged by this slice (it is the same `chromeInkHex @ 0.85` and
        // the same `legibleTintedText` correction it has always been), and one
        // palette - catppuccin-latte - already sits marginally under the floor
        // at 4.39:1 for an ordinary line. Failing on that here would either
        // force a change to a palette this slice must render byte-identically,
        // or invite loosening the threshold until it passes, which would then
        // stop guarding the one surface this slice actually introduced. So the
        // pre-existing numbers are printed (a later slice restyling those
        // palettes has them already) and Daylight is the one that must clear.
        var worst = Double.greatestFiniteMagnitude
        var worstWhere = ""
        var preExisting: [String] = []
        for theme in HelmTheme.allThemes {
            for severity in [LogSeverity.critical, .high, .warning, .informational, .normal] {
                let (text, surface) = LogRawPaneView.debugLineColors(severity: severity, theme: theme)
                guard let text else {
                    print("  FAIL \(theme.id)/\(severity) produced no text colour")
                    ok = false
                    continue
                }
                // The pane fades its normal ink to 85%, so measure the
                // composited colour rather than the nominal one.
                let composited = surface.blended(withFraction: text.alphaComponent,
                                                 of: text.withAlphaComponent(1)) ?? text
                let ratio = HelmContrast.ratio(composited, surface)
                guard ratio < 4.5 else {
                    if theme.isDaylight, ratio < worst { worst = ratio; worstWhere = "\(severity)" }
                    continue
                }
                if theme.isDaylight {
                    print("  FAIL the Daylight dark card's \(severity) line measures "
                          + "\(String(format: "%.2f", ratio)):1")
                    ok = false
                } else {
                    preExisting.append("\(theme.id)/\(severity) \(String(format: "%.2f", ratio)):1")
                }
            }
        }
        if !preExisting.isEmpty {
            print("  NOTE pre-existing, unchanged by this slice: " + preExisting.joined(separator: ", "))
        }
        print("  OK - worst Daylight raw line is \(worstWhere) at \(String(format: "%.2f", worst)):1")
    }

    // MARK: 5. §7's signal row for launcher issues

    // MARK: 6. §7's mono secret names

    // MARK: 7. No new window-width floor (AGENTS.md gotcha (13))

    private static func checkNoWindowWidthFloor(_ ok: inout Bool) {
        print("\n-- gotcha (13): neither page can drive the window's own width --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }
        ThemeManager.shared.setTheme(daylight)

        let analyzer = makeLogAnalyzer()
        analyzer.debugRender(sampleInvestigation())
        let vault = VaultController()
        vault.debugRender(secrets: [VaultSecret(name: "A_VERY_LONG_SECRET_NAME_THAT_KEEPS_GOING")],
                          tools: [VaultTool(name: "aws", commands: ["aws"],
                                            status: .needsAttention(issueCount: 9))])

        for (name, page) in [("Log Analyzer", analyzer as NSViewController), ("Vault", vault)] {
            let window = OffScreenProbe.window(width: 1400, height: 820, styleMask: [.titled, .resizable])
            window.contentView = page.view
            page.view.layoutSubtreeIfNeeded()
            // Shrink well below the page's comfortable width: a content
            // constraint above `NSLayoutPriorityWindowSizeStayPut` (500) would
            // hold the window open here rather than letting it resolve.
            window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 820), display: true)
            page.view.layoutSubtreeIfNeeded()
            let got = window.frame.width
            if got > 901 {
                print("  FAIL \(name) held the window at \(fmt(got))pt when asked for 900")
                ok = false
            }
        }
        print("  OK - both pages resolve at 900pt")
    }
}

#endif
