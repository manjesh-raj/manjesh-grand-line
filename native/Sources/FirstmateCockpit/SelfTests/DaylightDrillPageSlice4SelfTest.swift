// Manjesh Grand Line - native macOS app.
//
// Daylight **Phase 4, slice 4**'s own suite: originally the two destinations
// §7 put next, Log Analyzer and Vault. The Log Analyzer feature (and every
// check here that exercised it - the drill-header half of what is now
// `checkDrillConformances`, the in-page-hero check, and the two raw-dark-card
// checks) was removed outright by `fm/grandline-menubar-remove-items`; this
// file kept its name (main.swift's `FM_RUN_DAYLIGHT_DRILL_SLICE4_TESTS`
// dispatch and the historical PR record both refer to it) but is Vault-only
// now.
//
// What each remaining case is actually protecting, and why it is worth a
// test rather than a read-through:
//
//   1. **Vault really reached the drill header** (§6.4). The seam is a
//      protocol conformance and a missing one is invisible - the header simply
//      shows the static per-area line with an empty trailing slot, which looks
//      like a design choice rather than a page that was never migrated.
//   2. **Vault renders no in-page hero any more** (§6.4). Walked over the
//      real view tree, because the failure mode is a duplicate title one row
//      apart - the exact defect the audit found on Review and Docs.
//   3. **§7's "signal row for launcher issues" is a signal, not a repaint of
//      every row.** A wash on all of them would leave the page with nothing
//      standing out, which is the opposite of what the treatment is for.
//   4. **Secret names stay mono** (§7). One `titleIsCode` flag away from
//      rendering as ordinary row titles, and nothing else on the page would
//      look wrong if it regressed.
//   5. **No new window-width floor.** Every constraint this page carries
//      lives inside `bodyContainer`, and AGENTS.md gotcha (13) is this
//      codebase's most expensive recurring bug.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_DRILL_SLICE4_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightDrillPageSlice4SelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkDrillConformances, checkHeroTitlesAreGone,
                      checkVaultSignalRows, checkSecretNamesAreMono,
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 820)
        controller.view.layoutSubtreeIfNeeded()
        return window
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

    // MARK: 1. Vault reached the drill header (§6.4)

    private static func checkDrillConformances(_ ok: inout Bool) {
        print("\n-- §6.4: Vault carries a live drill header --")

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
        print("  OK - Vault \"\(vaultSubtitle)\" + stable Refresh action")
    }

    // MARK: 2. No in-page hero left (§6.4)

    private static func checkHeroTitlesAreGone(_ ok: inout Bool) {
        print("\n-- §6.4: no in-page hero title on Vault --")
        // The drill header's own title is 26pt, so anything at or above 20pt
        // inside a page body is a second title competing with it.
        let heroFloor: CGFloat = 20
        let vault = VaultController()
        let window = mount(vault)
        defer { _ = window }
        let heroes = labels(in: vault.view, atLeast: heroFloor)
        if !heroes.isEmpty {
            print("  FAIL Vault still renders \(heroes.count) hero-sized label(s): "
                  + heroes.map { "\"\($0.stringValue)\" @\(fmt($0.font?.pointSize ?? 0))" }
                      .joined(separator: ", "))
            ok = false
        } else {
            print("  OK - Vault's page body is free of hero-sized titles")
        }
    }

    // MARK: 3. §7's signal row for launcher issues

    private static func checkVaultSignalRows(_ ok: inout Bool) {
        print("\n-- §6.5 / §7: only a launcher with real issues gets the signal wash --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }
        ThemeManager.shared.setTheme(daylight)

        let vault = VaultController()
        let window = mount(vault)
        defer { _ = window }
        vault.debugRender(secrets: [VaultSecret(name: "GITHUB_TOKEN")],
                          tools: [VaultTool(name: "gh", commands: ["gh"], status: .hardened),
                                  VaultTool(name: "aws", commands: ["aws"],
                                            status: .needsAttention(issueCount: 2))])
        vault.view.layoutSubtreeIfNeeded()

        let rows = vault.debugToolRows
        guard rows.count == 2 else {
            print("  FAIL expected 2 launcher rows, got \(rows.count)")
            ok = false
            return
        }
        let card = HelmTheme.nsColor(daylight.chromeBackgroundHex)
        let hardened = rows[0].debugPaint()
        let attention = rows[1].debugPaint()
        if !sameColor(hardened.fill, card) {
            print("  FAIL the hardened launcher row is washed - the signal treatment is on every row")
            ok = false
        }
        if sameColor(attention.fill, card) {
            print("  FAIL the needs-attention launcher row carries no signal wash")
            ok = false
        }
        // A secret is a record, not a signal.
        if let secret = vault.debugSecretRows.first, !sameColor(secret.debugPaint().fill, card) {
            print("  FAIL a stored secret row is washed as if it needed attention")
            ok = false
        }
        if !vault.debugAttentionBannerVisible {
            print("  FAIL the attention banner is hidden with a launcher genuinely needing attention")
            ok = false
        }

        // And the twelve palettes are untouched: the wash is Daylight-only.
        ThemeManager.shared.setTheme(otherTheme)
        vault.view.layoutSubtreeIfNeeded()
        let otherCard = HelmTheme.nsColor(otherTheme.chromeBackgroundHex)
        if !sameColor(vault.debugToolRows[1].debugPaint().fill, otherCard) {
            print("  FAIL \(otherTheme.id) picked up the Daylight-only signal wash")
            ok = false
        }
        print("  OK - washed only on the needs-attention row, only under Daylight, banner shown")
    }

    // MARK: 4. §7's mono secret names

    private static func checkSecretNamesAreMono(_ ok: inout Bool) {
        print("\n-- §7: secret names render in the mono role --")
        let vault = VaultController()
        let window = mount(vault)
        defer { _ = window }
        vault.debugRender(secrets: [VaultSecret(name: "GITHUB_TOKEN")],
                          tools: [VaultTool(name: "gh", commands: ["gh"], status: .hardened)])
        vault.view.layoutSubtreeIfNeeded()

        guard let secret = vault.debugSecretRows.first else {
            print("  FAIL no secret row rendered")
            ok = false
            return
        }
        let secretFont = secret.debugPaint().titleFont
        if secretFont?.fontName != HelmType.code().fontName {
            print("  FAIL a secret name renders in \(secretFont?.fontName ?? "nil"), "
                  + "want \(HelmType.code().fontName)")
            ok = false
        }
        // A launcher is a tool name, not an identifier the captain types -
        // it stays in the ordinary row title face, so this is a real
        // distinction rather than "everything on the page is mono".
        if let tool = vault.debugToolRows.first,
           tool.debugPaint().titleFont?.fontName == HelmType.code().fontName {
            print("  FAIL a launcher name is mono too - the mono treatment is not carrying meaning")
            ok = false
        }
        print("  OK - secret \"\(secret.debugTitle)\" is \(secretFont?.fontName ?? "nil")")
    }

    // MARK: 5. No new window-width floor (AGENTS.md gotcha (13))

    private static func checkNoWindowWidthFloor(_ ok: inout Bool) {
        print("\n-- gotcha (13): Vault cannot drive the window's own width --")
        let restore = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restore) }
        ThemeManager.shared.setTheme(daylight)

        let vault = VaultController()
        vault.debugRender(secrets: [VaultSecret(name: "A_VERY_LONG_SECRET_NAME_THAT_KEEPS_GOING")],
                          tools: [VaultTool(name: "aws", commands: ["aws"],
                                            status: .needsAttention(issueCount: 9))])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = vault.view
        vault.view.layoutSubtreeIfNeeded()
        // Shrink well below the page's comfortable width: a content
        // constraint above `NSLayoutPriorityWindowSizeStayPut` (500) would
        // hold the window open here rather than letting it resolve.
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 820), display: true)
        vault.view.layoutSubtreeIfNeeded()
        let got = window.frame.width
        if got > 901 {
            print("  FAIL Vault held the window at \(fmt(got))pt when asked for 900")
            ok = false
        } else {
            print("  OK - Vault resolves at 900pt")
        }
    }
}

#endif
