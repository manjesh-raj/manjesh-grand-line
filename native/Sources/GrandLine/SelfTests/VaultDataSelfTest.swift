// Grand Line - native macOS app.
//
// Permanent, env-gated self-test for `VaultData.swift`'s pure logic - run via
// `FM_RUN_VAULT_DATA_TESTS=1 .build/debug/GrandLine`, same convention
// as `HostStoreSelfTest.swift`/`YamlBeautifySelfTest.swift`. Covers only the
// parts of `VaultSource` that don't need a real `av` binary: token safety
// (what's allowed to be spliced into a shell command unquoted), the two
// command-string builders, and `av doctor --json` parsing against the exact
// shape `av` returned on this machine during development (see
// `VaultController.swift`'s header for the live probes that established the
// rest of this file's behavior - `av list` returning bare names, `av save`
// requiring a real `/dev/tty`, `av inject` working fine as a background
// process).
//
// Also covers `VaultRecipe.build`/`VaultRecipeChecklist.build`
// (fm/grandline-vault-recipe-backup) - a lossless JSON round trip, and the
// missing/matches/new-since-backup diff against a simulated post-wipe
// snapshot. The git/filesystem half (`VaultRecipeGit.swift`) is exercised
// live against a disposable local clone instead - see that task's PR
// description for the exact commands run, since a real `git commit`/`push`
// against a throwaway remote isn't something a pure in-process self-test can
// safely cover.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum VaultDataSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            SelfTestAssertions.record(condition, name, into: &failures)
        }

        // MARK: isSafeToken

        check("plain name is safe", VaultSource.isSafeToken("MANJESH_GITHUB_TOKEN"))
        check("dash/underscore mix is safe", VaultSource.isSafeToken("my-secret_1"))
        check("empty is unsafe", !VaultSource.isSafeToken(""))
        check("space is unsafe", !VaultSource.isSafeToken("has space"))
        check("shell metachar is unsafe", !VaultSource.isSafeToken("a;rm -rf /"))
        check("quote is unsafe", !VaultSource.isSafeToken("a'b"))
        check("dollar is unsafe", !VaultSource.isSafeToken("$HOME"))

        // MARK: saveSecretCommand

        check("save command for a safe name", VaultSource.saveSecretCommand(name: "MY_TOKEN") == "av save MY_TOKEN")
        check("save command rejects an unsafe name", VaultSource.saveSecretCommand(name: "a; rm -rf /") == nil)

        // MARK: injectCommand

        check(
            "inject command for a safe name + command",
            VaultSource.injectCommand(secretName: "MY_TOKEN", command: "gh auth status") == "av inject +MY_TOKEN -- gh auth status"
        )
        check("inject command rejects an unsafe secret name", VaultSource.injectCommand(secretName: "a b", command: "echo hi") == nil)
        check("inject command rejects an empty command", VaultSource.injectCommand(secretName: "MY_TOKEN", command: "   ") == nil)

        // MARK: parseDoctorTools

        let hardenedOnly = VaultSource.parseDoctorTools(#"{"results":[{"commands":["claude"],"issues":[],"name":"claude"}]}"#) ?? []
        check("one hardened tool parsed", hardenedOnly.count == 1)
        check("hardened tool name/commands", hardenedOnly.first?.name == "claude" && hardenedOnly.first?.commands == ["claude"])
        check("hardened tool status", hardenedOnly.first?.status == .hardened)

        let withIssues = VaultSource.parseDoctorTools(
            #"{"results":[{"commands":["gh"],"issues":[{"explanation":"x"},{"explanation":"y"}],"name":"gh"}]}"#
        ) ?? []
        check("tool with issues parsed", withIssues.count == 1)
        check("tool with issues status", withIssues.first?.status == .needsAttention(issueCount: 2))

        // MARK: parseDoctorTools keeps the doctor's detail (not just a count)

        let doctorJSON = #"""
        {"results":[{"name":"node","commands":["npm"],"issues":[{"command":"npm","kind":"stub_wrong_type",
        "message":"hardened launcher /usr/local/bin/npm is a symbolic link; expected a regular file",
        "remediation":"Remove /usr/local/bin/npm after reviewing it, then run `av harden node`. Manual repair: install the launcher directly.",
        "resolved_path":null,"stub_path":"/usr/local/bin/npm","target_path":"/opt/homebrew/bin/npm"}]},
        {"name":"claude","commands":["claude"],"issues":[]}]}
        """#
        let detailed = VaultSource.parseDoctorTools(doctorJSON) ?? []
        let nodeIssue = detailed.first?.issues.first
        check("the doctor's kind is kept", nodeIssue?.kind == "stub_wrong_type")
        check("the doctor's message is kept", nodeIssue?.message == "hardened launcher /usr/local/bin/npm is a symbolic link; expected a regular file")
        check("the doctor's remediation is kept", nodeIssue?.remediation.hasPrefix("Remove /usr/local/bin/npm") == true)
        check("stub and target paths are kept", nodeIssue?.stubPath == "/usr/local/bin/npm" && nodeIssue?.targetPath == "/opt/homebrew/bin/npm")
        check("a null path stays nil, never an empty string", VaultSource.parseDoctorTools(
            #"{"results":[{"name":"x","commands":[],"issues":[{"kind":"k","message":"m","remediation":"r"}]}]}"#)?.first?.issues.first?.stubPath == nil)
        check("the count still comes from the issues array", detailed.first?.status == .needsAttention(issueCount: 1))
        check("a hardened launcher carries no issues", detailed.last?.issues.isEmpty == true)
        check("remediation commands are the backticked spans only", nodeIssue?.commands == ["av harden node"])
        check("a remediation with no backticks has no commands",
              VaultToolIssue(kind: "k", message: "m", remediation: "Reinstall it.", stubPath: nil, targetPath: nil).commands == [])
        check("an unclosed backtick yields no command",
              VaultToolIssue(kind: "k", message: "m", remediation: "run `av harden", stubPath: nil, targetPath: nil).commands == [])

        // The launcher row's subtitle and the banner say the problem.
        check("the row subtitle is the doctor's message", detailed.first?.issueSummary == nodeIssue?.message)
        check("a second issue is counted, not dropped",
              VaultTool(name: "t", commands: [], status: .needsAttention(issueCount: 2),
                        issues: [VaultToolIssue(kind: "a", message: "first", remediation: "", stubPath: nil, targetPath: nil),
                                 VaultToolIssue(kind: "b", message: "second", remediation: "", stubPath: nil, targetPath: nil)]).issueSummary == "first (+1 more)")
        check("a tool with only a count has no summary", VaultTool(name: "t", commands: [], status: .needsAttention(issueCount: 1)).issueSummary == nil)
        check("the banner names the launcher and the problem",
              VaultSource.attentionBannerText(for: detailed)?.contains("node needs attention: hardened launcher /usr/local/bin/npm is a symbolic link") == true)
        check("no banner when nothing needs attention", VaultSource.attentionBannerText(for: [VaultTool(name: "c", commands: [], status: .hardened)]) == nil)
        check("the banner for several tools lists them",
              VaultSource.attentionBannerText(for: [VaultTool(name: "a", commands: [], status: .needsAttention(issueCount: 1)),
                                                    VaultTool(name: "b", commands: [], status: .needsAttention(issueCount: 1))])?.hasPrefix("2 tools need attention: a, b") == true)
        check("re-check refuses a name that is not a safe token", VaultSource.recheckTool(named: "--all") == nil)

        // MARK: child PATH order (Automic Vault's launchers live in /usr/local/bin)
        //
        // `av doctor` reports stub_not_first_on_path when a Homebrew binary
        // resolves ahead of a hardened stub, and every command this app runs
        // gets this PATH.

        func order(_ path: String, _ a: String, _ b: String) -> Bool {
            let parts = path.split(separator: ":").map(String.init)
            guard let i = parts.firstIndex(of: a), let j = parts.firstIndex(of: b) else { return false }
            return i < j
        }
        let bare = pathWithStandardLocations("/usr/bin:/bin:/usr/sbin:/sbin")
        check("a bare PATH puts /usr/local/bin ahead of /opt/homebrew/bin", order(bare, "/usr/local/bin", "/opt/homebrew/bin"))
        check("a bare PATH puts /usr/local/sbin ahead of /opt/homebrew/sbin", order(bare, "/usr/local/sbin", "/opt/homebrew/sbin"))
        check("the standard locations lead the PATH", bare.hasPrefix("/usr/local/bin:/usr/local/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin"))
        check("an empty PATH still gets all four", pathWithStandardLocations("") == "/usr/local/bin:/usr/local/sbin:/opt/homebrew/bin:/opt/homebrew/sbin")
        let homebrewFirst = pathWithStandardLocations("/opt/homebrew/bin:/usr/bin")
        check("a PATH that already has Homebrew gets /usr/local/bin ahead of it", order(homebrewFirst, "/usr/local/bin", "/opt/homebrew/bin"))
        check("an entry already present is not duplicated", homebrewFirst.split(separator: ":").filter { $0 == "/opt/homebrew/bin" }.count == 1)
        check("when both are already present the incoming order is kept",
              pathWithStandardLocations("/opt/homebrew/bin:/usr/local/bin:/usr/bin").hasPrefix("/usr/local/sbin:/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/sbin:/usr/bin"))
        check("a PATH with only /usr/local/bin gets Homebrew behind it",
              order(pathWithStandardLocations("/usr/local/bin:/usr/bin"), "/usr/local/bin", "/opt/homebrew/bin"))
        check("a PATH with only /opt/homebrew/sbin still gets /usr/local/sbin ahead of it",
              order(pathWithStandardLocations("/opt/homebrew/sbin:/usr/bin"), "/usr/local/sbin", "/opt/homebrew/sbin"))
        check("the child environment's PATH is built by pathWithStandardLocations",
              (childEnvironmentDict()["PATH"] ?? "").hasSuffix(ProcessInfo.processInfo.environment["PATH"] ?? ""))

        // MARK: parseSecretList (B1)

        check("a failed `av list` is a failed read (nil), not an empty vault",
              VaultSource.parseSecretList(stdout: "", status: 1) == nil)
        check("a failed `av list` that still printed something is still nil",
              VaultSource.parseSecretList(stdout: "GH_TOKEN", status: 1) == nil)
        check("a successful `av list` with no secrets is an empty list, not nil",
              VaultSource.parseSecretList(stdout: "\n  \n", status: 0) == [])
        check("a successful `av list` parses and trims its names",
              VaultSource.parseSecretList(stdout: "GH_TOKEN\n  AWS_SECRET  \n", status: 0)?.map(\.name) == ["GH_TOKEN", "AWS_SECRET"])

        // B1: a failed read and a genuinely empty report must not look the
        // same - this is the whole finding, one level down from the UI.
        check("malformed JSON is a failed read (nil), not an empty list",
              VaultSource.parseDoctorTools("not json") == nil)
        check("output of the wrong shape is a failed read too",
              VaultSource.parseDoctorTools(#"{"unexpected":true}"#) == nil)
        check("a well-formed report with no tools is an empty list, not nil",
              VaultSource.parseDoctorTools(#"{"results":[]}"#) == [])

        // MARK: VaultRecipe.build / VaultRecipeChecklist (fm/grandline-vault-recipe-backup)

        let snapshotA = VaultSnapshot(
            availability: .installed(versionLabel: "av 1.2.3"),
            secrets: [VaultSecret(name: "GH_TOKEN"), VaultSecret(name: "AWS_SECRET")],
            tools: [
                VaultTool(name: "claude", commands: ["claude"], status: .hardened),
                VaultTool(name: "gh", commands: ["gh"], status: .hardened),
            ],
            log: ""
        )
        let recipeA = VaultRecipe.build(from: snapshotA, generatedAt: "2026-01-01T00:00:00Z")
        check("recipe records av version", recipeA.avVersion == "av 1.2.3")
        check("recipe secrets sorted by name", recipeA.secrets.map(\.name) == ["AWS_SECRET", "GH_TOKEN"])
        check("recipe tools sorted by name", recipeA.tools.map(\.name) == ["claude", "gh"])
        check("recipe tool records hardened + launchers", recipeA.tools.first { $0.name == "gh" }?.verifiedLaunchers == ["gh"])

        // A round trip through JSON never contains a value - only names ever
        // flow into this model, but encode/decode should still be lossless.
        if let data = try? JSONEncoder().encode(recipeA), let decoded = try? JSONDecoder().decode(VaultRecipe.self, from: data) {
            check("recipe JSON round trip is lossless", decoded == recipeA)
        } else {
            failures.append("recipe JSON round trip failed to encode/decode")
        }

        // A machine wiped since export: AWS_SECRET and the `gh` hardening are
        // gone, a brand-new secret NEW_TOKEN was saved, `claude` is still
        // hardened.
        let snapshotB = VaultSnapshot(
            availability: .installed(versionLabel: "av 1.2.3"),
            secrets: [VaultSecret(name: "GH_TOKEN"), VaultSecret(name: "NEW_TOKEN")],
            tools: [
                VaultTool(name: "claude", commands: ["claude"], status: .hardened),
                VaultTool(name: "gh", commands: ["gh"], status: .needsAttention(issueCount: 1)),
            ],
            log: ""
        )
        let items = VaultRecipeChecklist.build(recipe: recipeA, currentSnapshot: snapshotB)
        let secretItems = Dictionary(uniqueKeysWithValues: items.filter { $0.kind == .secret }.map { ($0.name, $0.status) })
        let toolItems = Dictionary(uniqueKeysWithValues: items.filter { $0.kind == .tool }.map { ($0.name, $0.status) })
        check("missing secret detected (the important case)", secretItems["AWS_SECRET"] == .missingLocally)
        check("matching secret detected", secretItems["GH_TOKEN"] == .matches)
        check("new secret since backup detected", secretItems["NEW_TOKEN"] == .newSinceBackup)
        check("dehardened tool detected as missing", toolItems["gh"] == .missingLocally)
        check("still-hardened tool detected as matching", toolItems["claude"] == .matches)
        check("checklist item count is secrets+tools union", items.count == 5) // AWS_SECRET, GH_TOKEN, NEW_TOKEN, claude, gh

        // Nothing changed since export -> everything matches, nothing flagged missing.
        let itemsUnchanged = VaultRecipeChecklist.build(recipe: recipeA, currentSnapshot: snapshotA)
        check("no drift yields all-matches", itemsUnchanged.allSatisfy { $0.status == .matches })

        // MARK: isServiceRunning (fm/grandline-vault-no-unnecessary-relaunch)
        //
        // Real-machine check, not a mock: this development machine keeps
        // Automic Vault's helper alive via its own `RunAtLoad: true`
        // LaunchAgent, independent of this app - so `pgrep -x
        // AutomicVaultMenubar` should report it running here. This can't be
        // asserted unconditionally on every machine (the helper might
        // genuinely be absent), so it's a soft/logged check rather than a
        // hard failure either way - the real regression this task fixes
        // (`ensureServiceRunning()` calling `open` even when already
        // running, which reopens Automic Vault's real window) was verified
        // live separately, outside this pure self-test, per this file's own
        // header convention.
        print("VaultDataSelfTest: isServiceRunning() reports \(VaultSource.isServiceRunning()) on this machine")

        if failures.isEmpty {
            print("VaultDataSelfTest: all checks passed")
            return true
        } else {
            print("VaultDataSelfTest: FAILED - \(failures.joined(separator: "; "))")
            return false
        }
    }
}

#endif
