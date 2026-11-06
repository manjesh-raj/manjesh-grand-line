// Grand Line - native macOS app.
//
// B1 of `data/grand-line-e2e-audit/report.md`: the Vault page (Automic
// Vault's hardening panel) must never render a failed or still-pending `av`
// read as a confident "0 secrets · 0 verified launchers". Run with:
//
//   swift build && FM_RUN_VAULT_LOADING_STATE_TESTS=1 .build/debug/GrandLine; echo $?
//
// Renamed back to its original name, and this suite along with it, by
// `fm/swap-vault-poneglyph-naming-in-grand-lin-1f`: this page briefly lived at
// `.vault`, then moved under Setup as "Poneglyph"
// (`fm/implement-grand-line-secrets-vault-poneg-ad`), then reclaimed the
// `.vault` destination and the "Vault" name by the captain's own later
// correction - see `VaultController.swift`'s header for the full history.
// Nothing about what it asserts changed across any of that - the GL-14
// nil-versus-empty property is a property of Automic Vault's own reads,
// which moved with the panel each time.
//
// The bug is worth restating, because "an empty list" and "a failed fetch" are
// the same *shape* and only different *meaning*: `VaultSource.loadSnapshot()`
// mapped a non-zero `av list` exit to `[]`, and the page counted straight off
// that. The audit's probe reproduced it on a machine that genuinely has four
// secrets and a hardened launcher, and it is the state a captain whose Automic
// Vault approval helper is wedged sits in - a documented, real state the lock
// screen already handles by name. On a security surface "0 secrets" is a
// materially false statement, not a cosmetic one; that is the GL-14 class the
// production review spent a phase eliminating.
//
// Driven through `debugRender(secrets:tools:)` - the page's own real render
// path - never through `refresh()`, which would shell out to `av`. The `av`
// plumbing itself is `VaultDataSelfTest`'s job, and it now has its own
// nil-vs-empty cases.
//
// Window-backed (the page builds real cards), so this sits in
// `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list.

#if FM_SELFTESTS

import AppKit

enum VaultLoadingStateSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("beforeTheFirstReadThePageSaysChecking", test_checkingBeforeFirstRead),
            ("aFailedReadIsNotAnEmptyVault", test_failedReadIsNotEmpty),
            ("aGenuinelyEmptyVaultStillSaysEmpty", test_realEmptyStillSaysEmpty),
            ("realDataRendersRealRows", test_realDataRenders),
            ("aFailedReadNeverClaimsAllClear", test_failedReadDoesNotClaimAllClear),
            ("recipeExportRefusesADegradedRead", test_recipeGuardsSourceCheck),
            ("aLauncherWithIssuesShowsTheDoctorsMessage", test_doctorDetailIsShown),
            ("aLauncherRowOffersTheFixAndARecheck", test_launcherRowActions),
            ("aRecheckReplacesOnlyThatLauncherAndAFailedOneKeepsTheReading", test_recheckResult),
            ("theFixSheetShowsCopyableCommandsAndRunsNothing", test_issueSheet),
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
              ? "VaultLoadingStateSelfTest: all \(cases.count) cases passed"
              : "VaultLoadingStateSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    private static func mounted() -> (NSWindow, VaultController) {
        let controller = VaultController()
        let window = OffScreenProbe.window(width: 1000, height: 800)
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private static func test_checkingBeforeFirstRead() -> String? {
        let (window, controller) = mounted()
        defer { window.contentView = nil }
        controller.debugPrepareUnreadForTests()
        guard let subtitle = controller.drillHeaderSubtitle else {
            return "the drill subtitle was nil before the first read"
        }
        guard subtitle.lowercased().contains("checking") else {
            return "before any read the page says \"\(subtitle)\" - it must not assert a count it does not have"
        }
        guard !subtitle.contains("0 secrets") else {
            return "before any read the page claims \"0 secrets\""
        }
        return nil
    }

    private static func test_failedReadIsNotEmpty() -> String? {
        let (window, controller) = mounted()
        defer { window.contentView = nil }
        // nil = the read failed. This is exactly what a wedged approval helper
        // produces.
        controller.debugRender(secrets: nil, tools: nil)

        guard let subtitle = controller.drillHeaderSubtitle else {
            return "the drill subtitle was nil after a failed read"
        }
        if subtitle.contains("0 secrets") || subtitle.contains("0 verified launchers") {
            return "a failed read still renders \"\(subtitle)\""
        }
        guard subtitle.lowercased().contains("couldn") else {
            return "a failed read renders \"\(subtitle)\", which does not tell the captain the read failed"
        }
        // The counts must not read as zero either.
        if controller.debugSecretsBadge == "0" || controller.debugToolsBadge == "0" {
            return "count badges show 0/0 for a failed read (secrets=\(controller.debugSecretsBadge), tools=\(controller.debugToolsBadge))"
        }
        // And the card bodies must say so, not show the "no saved secrets
        // yet" copy that invites the captain to add one.
        guard let secretsText = controller.debugSecretsPlaceholderText else {
            return "the Secrets card showed no placeholder at all for a failed read"
        }
        if secretsText.lowercased().contains("no saved secrets yet") {
            return "a failed read shows the genuinely-empty copy: \"\(secretsText)\""
        }
        guard secretsText.lowercased().contains("automic vault") else {
            return "the failure copy does not name what to fix: \"\(secretsText)\""
        }
        return nil
    }

    private static func test_realEmptyStillSaysEmpty() -> String? {
        let (window, controller) = mounted()
        defer { window.contentView = nil }
        // A successful read of a genuinely empty vault - the state the old
        // code was *right* about, and which must not regress into an error.
        controller.debugRender(secrets: [], tools: [])
        guard let subtitle = controller.drillHeaderSubtitle else {
            return "the drill subtitle was nil for a genuinely empty vault"
        }
        guard subtitle.contains("0 secrets") else {
            return "a genuinely empty vault renders \"\(subtitle)\" instead of a real zero"
        }
        guard controller.debugSecretsBadge == "0", controller.debugToolsBadge == "0" else {
            return "badges read \(controller.debugSecretsBadge)/\(controller.debugToolsBadge) for a real zero"
        }
        guard let text = controller.debugSecretsPlaceholderText,
              text.lowercased().contains("no saved secrets yet") else {
            return "a genuinely empty vault lost its \"no saved secrets yet\" copy"
        }
        return nil
    }

    private static func test_realDataRenders() -> String? {
        let (window, controller) = mounted()
        defer { window.contentView = nil }
        controller.debugRender(
            secrets: [VaultSecret(name: "GRANDLINE_APP_PASSWORD"), VaultSecret(name: "GH_TOKEN")],
            tools: [VaultTool(name: "claude", commands: ["claude"], status: .hardened)]
        )
        guard controller.debugSecretRows.count == 2 else {
            return "2 secrets rendered \(controller.debugSecretRows.count) rows"
        }
        guard controller.debugSecretsBadge == "2", controller.debugToolsBadge == "1" else {
            return "badges read \(controller.debugSecretsBadge)/\(controller.debugToolsBadge) for 2 secrets and 1 tool"
        }
        guard let subtitle = controller.drillHeaderSubtitle, subtitle.contains("2 secrets") else {
            return "the drill subtitle lost its real counts: \(controller.drillHeaderSubtitle ?? "nil")"
        }
        return nil
    }

    private static func test_failedReadDoesNotClaimAllClear() -> String? {
        let (window, controller) = mounted()
        defer { window.contentView = nil }
        controller.debugRender(secrets: nil, tools: nil)
        // The banner is "N tools need attention". A failed read says nothing
        // about that either way, so it must stay down - but the *subtitle*
        // must not read as an all-clear.
        if controller.debugAttentionBannerVisible {
            return "a failed read raised the needs-attention banner it has no data for"
        }
        if let subtitle = controller.drillHeaderSubtitle,
           subtitle.contains("names and metadata only, never a value"),
           !subtitle.lowercased().contains("couldn") {
            return "a failed read renders the normal all-clear subtitle"
        }
        return nil
    }

    /// Source guard: the recipe backup is pushed to a git remote, so an export
    /// built from a failed read would commit a file claiming this machine has
    /// no secrets - a wrong backup being worse than no backup is the whole
    /// reason this refusal exists, and it is invisible without a real `av`.
    private static func test_recipeGuardsSourceCheck() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: dir.appendingPathComponent("VaultController.swift"), encoding: .utf8) else {
            return nil
        }
        let guards = text.components(separatedBy: "guard !snapshot.isDegraded else {").count - 1
        guard guards >= 2 else {
            return "only \(guards) of the two recipe actions (Export Recipe, Check Against Backup) refuse a failed read"
        }
        return nil
    }

    private static let nodeIssue = VaultToolIssue(
        kind: "stub_wrong_type",
        message: "hardened launcher /usr/local/bin/npm is a symbolic link; expected a regular file",
        remediation: "Remove /usr/local/bin/npm after reviewing it, then run `av harden node`.",
        stubPath: "/usr/local/bin/npm", targetPath: "/opt/homebrew/bin/npm")
    private static var nodeTool: VaultTool {
        VaultTool(name: "node", commands: ["npm"], status: .needsAttention(issueCount: 1), issues: [nodeIssue])
    }

    private static func test_doctorDetailIsShown() -> String? {
        let (window, controller) = mounted()
        defer { window.contentView = nil }
        controller.debugRender(secrets: [], tools: [nodeTool])
        guard controller.debugAttentionBannerVisible,
              controller.debugAttentionBannerText.contains("symbolic link") else {
            return "the banner does not name the problem: \"\(controller.debugAttentionBannerText)\""
        }
        guard controller.debugToolRows.count == 1,
              (controller.toolRowContent(nodeTool).meta ?? "").contains("symbolic link") else {
            return "the launcher row does not carry the doctor's message"
        }
        return nil
    }

    private static func test_launcherRowActions() -> String? {
        let (window, controller) = mounted()
        defer { window.contentView = nil }
        controller.debugRender(secrets: [], tools: [nodeTool, VaultTool(name: "claude", commands: ["claude"], status: .hardened)])
        let rows = controller.debugToolTableRows
        guard rows.count == 2 else { return "expected 2 launcher rows, got \(rows.count)" }
        guard case .title(_, let subtitle, _, _, _, _)? = rows[0].cells["launcher"],
              subtitle?.contains("symbolic link") == true else {
            return "the table row's subtitle is not the doctor's message"
        }
        guard rows[0].primary?.title == "View Fix\u{2026}", rows[0].activate != nil else {
            return "an issue row has no way to open its fix steps"
        }
        guard rows[0].menu.map(\.title) == ["Re-check"] else {
            return "an issue row's menu is \(rows[0].menu.map(\.title)), expected only Re-check"
        }
        guard rows[1].primary == nil, rows[1].activate == nil, rows[1].menu.isEmpty else {
            return "a hardened launcher grew an action it has nothing to do with"
        }
        return nil
    }

    private static func test_recheckResult() -> String? {
        let (window, controller) = mounted()
        defer { window.contentView = nil }
        let other = VaultTool(name: "terraform", commands: ["terraform"], status: .needsAttention(issueCount: 1))
        controller.debugRender(secrets: [], tools: [nodeTool, other])
        controller.debugFinishRecheck("node", nil)
        guard controller.debugAttentionBannerText.contains("node, terraform") else {
            return "a failed re-check cleared the reading it could not replace: \(controller.debugAttentionBannerText)"
        }
        controller.debugFinishRecheck("node", VaultTool(name: "node", commands: ["npm"], status: .hardened))
        guard controller.debugToolRows.count == 2 else { return "a re-check changed the number of launchers" }
        guard !controller.debugAttentionBannerText.contains("node") else {
            return "node is still named in the banner after a clean re-check: \(controller.debugAttentionBannerText)"
        }
        guard controller.debugAttentionBannerText.hasPrefix("terraform needs attention") else {
            return "the other launcher's reading was disturbed: \(controller.debugAttentionBannerText)"
        }
        return nil
    }

    private static func test_issueSheet() -> String? {
        let sheet = VaultLauncherIssueSheetController(tool: nodeTool)
        _ = sheet.view
        guard sheet.debugCommandTexts == ["av harden node"] else {
            return "the sheet offers \(sheet.debugCommandTexts) as copyable commands"
        }
        var rechecked = 0
        sheet.onRecheck = { rechecked += 1 }
        sheet.debugClickRecheck()
        guard rechecked == 1 else { return "Re-check did not reach the page" }
        // Nothing on the sheet may run a command: `av harden` writes a
        // launcher. The sheet is a view onto text, a Copy and a Re-check.
        guard let dir = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: dir.appendingPathComponent("VaultLauncherIssueSheet.swift"), encoding: .utf8) else {
            return nil
        }
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for forbidden in ["onRunCommand", "Subprocess", "Process(", "runInConsole", "VaultSource.run"] where code.contains(forbidden) {
            return "the fix sheet reaches \(forbidden), which can run a command"
        }
        return nil
    }
}

#endif
