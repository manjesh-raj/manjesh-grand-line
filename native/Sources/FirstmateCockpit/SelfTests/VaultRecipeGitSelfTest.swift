// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for `VaultRecipeGit.export`'s ahead/behind/diverged
// classification (fm/grandline-vault-recipe-export-diverged-fix), run via
// `FM_RUN_VAULT_RECIPE_GIT_TESTS=1 .build/debug/FirstmateCockpit` - same
// convention as `ShiftGitSyncSelfTest.swift`.
//
// `VaultDataSelfTest.swift`'s own header notes that the git/filesystem half
// of Vault's recipe backup was, until this task, exercised only live against
// a disposable local clone rather than via a self-test - the same shape
// `ShiftGitSyncSelfTest.swift` already proves is possible (a real `git`
// subprocess against a real, disposable local bare "origin", never the
// captain's actual `manjesh-config`). `VaultRecipeGit.export(recipe:
// repoPath:)` takes an arbitrary working-tree path directly with no clone
// resolution of its own, which makes this even simpler to test than
// `ShiftGitSync` - no `FM_*_DIR`-style override is needed at all, just a
// real disposable working tree pointed at a real disposable bare "origin".
//
// `ConfigRepoPrivacy.check()` is scoped to fire only when the export's own
// `origin` remote equals `DotfilesSource.cloneURL` (this task's own fix -
// it used to fire unconditionally, which meant every call to `export()`,
// including these tests, shelled out to a real `gh api` call against the
// real `manjesh-config` repo). Every scenario here uses a `file://`-style
// local path as `origin`, so that check never fires and this suite never
// touches the network or needs `gh` to be installed/authenticated.
#if FM_SELFTESTS

import Foundation

enum VaultRecipeGitSelfTest {
    @discardableResult
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("vault-recipe-git-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        func makeBareOrigin(name: String) -> URL {
            let path = scratch.appendingPathComponent(name, isDirectory: true)
            _ = shell("/usr/bin/git", ["init", "--bare", "-b", "main", path.path])
            return path
        }

        @discardableResult
        func seedOrigin(_ origin: URL, viaScratchClone name: String) -> URL {
            let clonePath = scratch.appendingPathComponent(name, isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", origin.path, clonePath.path])
            configureIdentity(clonePath)
            try? "base\n".write(to: clonePath.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/git", ["-C", clonePath.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", clonePath.path, "commit", "-m", "base"])
            _ = shell("/usr/bin/git", ["-C", clonePath.path, "push", "origin", "main"])
            return clonePath
        }

        func configureIdentity(_ repo: URL) {
            _ = shell("/usr/bin/git", ["-C", repo.path, "config", "user.email", "test@example.com"])
            _ = shell("/usr/bin/git", ["-C", repo.path, "config", "user.name", "Vault Recipe Test"])
        }

        func cloneWorkingTree(origin: URL, name: String) -> URL {
            let path = scratch.appendingPathComponent(name, isDirectory: true)
            _ = shell("/usr/bin/git", ["clone", origin.path, path.path])
            configureIdentity(path)
            return path
        }

        func commitMessages(_ repo: URL) -> [String] {
            let result = shell("/usr/bin/git", ["-C", repo.path, "log", "--format=%s"])
            guard result.status == 0 else { return [] }
            return result.stdout.split(separator: "\n").map(String.init)
        }

        func makeRecipe(secretNames: [String]) -> VaultRecipe {
            VaultRecipe(
                generatedAt: "2026-01-01T00:00:00Z",
                avVersion: "av 1.0.0",
                secrets: secretNames.map { VaultRecipeSecret(name: $0) },
                tools: []
            )
        }

        // MARK: 1. In sync, add a secret, export - the base case.

        do {
            let origin = makeBareOrigin(name: "origin-insync")
            seedOrigin(origin, viaScratchClone: "seed-insync")
            let captain = cloneWorkingTree(origin: origin, name: "captain-insync")

            let result = VaultRecipeGit.export(recipe: makeRecipe(secretNames: ["NEW_SECRET"]), repoPath: captain.path)
            check("in-sync export succeeds", result.ok)
            check("in-sync export message does not claim divergence", !result.message.lowercased().contains("diverged"))

            let verify = cloneWorkingTree(origin: origin, name: "verify-insync")
            let recipePath = verify.appendingPathComponent("automatic-vault-details-backup/automic-vault-recipe.json")
            check("in-sync export actually pushed the recipe file to origin", fm.fileExists(atPath: recipePath.path))
            if let decoded = try? JSONDecoder().decode(VaultRecipe.self, from: try Data(contentsOf: recipePath)) {
                check("pushed recipe has the new secret", decoded.secrets.map(\.name) == ["NEW_SECRET"])
            } else {
                failures.append("in-sync export: pushed recipe file did not decode")
            }
        }

        // MARK: 2. Local strictly AHEAD of origin (a prior export committed
        // locally but never pushed, unrelated to the new secret) - the
        // exact "captain added a secret, nothing new on the remote side"
        // shape from the bug report. Must export cleanly with NO merge
        // conflict/divergence message, and nothing already on either side
        // may be lost.

        do {
            let origin = makeBareOrigin(name: "origin-ahead")
            seedOrigin(origin, viaScratchClone: "seed-ahead")
            let captain = cloneWorkingTree(origin: origin, name: "captain-ahead")

            // Simulate a stuck, never-pushed local commit unrelated to Vault
            // (e.g. a manual dotfiles edit, or an earlier export whose
            // commit succeeded but whose push failed).
            try? "captain's own unpushed edit\n".write(to: captain.appendingPathComponent("unrelated.txt"), atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/git", ["-C", captain.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", captain.path, "commit", "-m", "captain's own unpushed edit"])

            let aheadBehindBeforeExport = VaultRecipeGit.revListAheadBehind(branch: "main", cwd: captain.path, remoteURL: nil)
            // Note: revListAheadBehind needs a fetch to have populated
            // origin/main's tracking ref first - the clone above already did
            // that implicitly (a fresh clone tracks the remote's tip), so
            // this reads correctly without an extra fetch here.
            check("setup sanity: local is ahead by 1, behind by 0 before export",
                  aheadBehindBeforeExport?.ahead == 1 && aheadBehindBeforeExport?.behind == 0)

            let result = VaultRecipeGit.export(recipe: makeRecipe(secretNames: ["NEW_SECRET"]), repoPath: captain.path)
            check("ahead-only export succeeds (the ordinary case)", result.ok)
            check("ahead-only export message does not claim divergence", !result.message.lowercased().contains("diverged"))

            let verify = cloneWorkingTree(origin: origin, name: "verify-ahead")
            check("ahead-only export: origin now has the captain's earlier unrelated commit too",
                  fm.fileExists(atPath: verify.appendingPathComponent("unrelated.txt").path))
            let recipePath = verify.appendingPathComponent("automatic-vault-details-backup/automic-vault-recipe.json")
            check("ahead-only export: origin now has the pushed recipe", fm.fileExists(atPath: recipePath.path))
            let messages = commitMessages(verify)
            check("ahead-only export: nothing was force-pushed - both commits present on origin",
                  messages.contains("captain's own unpushed edit") && messages.contains("Vault: update secret recipe backup"))
        }

        // MARK: 3. Genuinely diverged: real commits on BOTH sides. Must keep
        // today's exact safety message, block the export, and neither
        // side's history may be force-pushed or discarded.

        do {
            let origin = makeBareOrigin(name: "origin-diverged")
            seedOrigin(origin, viaScratchClone: "seed-diverged")

            // The captain's own clone is made FIRST, at the base commit -
            // it must not already contain the other machine's push below,
            // or this would just be the ahead-only case again.
            let captain = cloneWorkingTree(origin: origin, name: "captain-diverged")
            try? "captain's own unpushed edit\n".write(to: captain.appendingPathComponent("mine.txt"), atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/git", ["-C", captain.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", captain.path, "commit", "-m", "captain's own unpushed edit (diverged case)"])

            // Another machine, independently, pushes a real commit to
            // origin AFTER the captain's clone already exists - so the
            // captain's clone has no idea about it yet.
            let other = cloneWorkingTree(origin: origin, name: "other-machine-diverged")
            try? "pushed from another machine\n".write(to: other.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/git", ["-C", other.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", other.path, "commit", "-m", "pushed from another machine"])
            _ = shell("/usr/bin/git", ["-C", other.path, "push", "origin", "main"])

            let commitsBefore = commitMessages(captain)

            let result = VaultRecipeGit.export(recipe: makeRecipe(secretNames: ["NEW_SECRET"]), repoPath: captain.path)
            check("genuinely diverged export is refused", !result.ok)
            check(
                "genuinely diverged export shows today's EXACT unchanged safety message",
                result.message == "Your manjesh-config clone has diverged from GitHub (there are commits on each side the other doesn't have), so this can't fast-forward automatically. Resolve it by hand from Bootstrap's \"Dotfiles & machine config\" card, then export again - nothing was force-pushed or discarded."
            )

            let commitsAfter = commitMessages(captain)
            check("diverged export: local history is untouched (no force, no discard)", commitsBefore == commitsAfter)
            check("diverged export: local's own commit still exists", commitsAfter.contains("captain's own unpushed edit (diverged case)"))

            let verify = cloneWorkingTree(origin: origin, name: "verify-diverged")
            check("diverged export: origin was never touched - the other machine's commit is still the only one there",
                  !fm.fileExists(atPath: verify.appendingPathComponent("automatic-vault-details-backup").path))
            check("diverged export: origin's own commit from the other machine is untouched",
                  commitMessages(verify).contains("pushed from another machine"))
        }

        // MARK: 4. Bonus: purely behind (no local-only commits) but the
        // fast-forward is blocked by an unrelated dirty file in the
        // captain's own working tree - NOT graph-level divergence (ahead ==
        // 0), so this must NOT show the "diverged...commits on each side"
        // message (that claim would be false), but must still refuse rather
        // than silently discarding the captain's uncommitted edit.

        do {
            let origin = makeBareOrigin(name: "origin-dirtyblock")
            seedOrigin(origin, viaScratchClone: "seed-dirtyblock")
            let captain = cloneWorkingTree(origin: origin, name: "captain-dirtyblock")

            // Another machine pushes a change to the SAME file the captain
            // is about to leave dirty, uncommitted, locally.
            let other = cloneWorkingTree(origin: origin, name: "other-machine-dirtyblock")
            try? "changed by another machine\n".write(to: other.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
            _ = shell("/usr/bin/git", ["-C", other.path, "add", "-A"])
            _ = shell("/usr/bin/git", ["-C", other.path, "commit", "-m", "changed by another machine"])
            _ = shell("/usr/bin/git", ["-C", other.path, "push", "origin", "main"])

            // Captain has an in-progress, UNCOMMITTED edit to that same file.
            try? "captain's own in-progress edit\n".write(to: captain.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)

            let result = VaultRecipeGit.export(recipe: makeRecipe(secretNames: ["NEW_SECRET"]), repoPath: captain.path)
            check("dirty-tree-blocked pull is refused (still needs a human)", !result.ok)
            check(
                "dirty-tree-blocked pull is NOT reported as graph-level divergence (ahead == 0, so that claim would be false)",
                !result.message.contains("there are commits on each side the other doesn't have")
            )
            check("dirty-tree-blocked pull still points at Bootstrap's dotfiles card",
                  result.message.contains("Dotfiles & machine config"))

            let dirtyContent = try? String(contentsOf: captain.appendingPathComponent("base.txt"), encoding: .utf8)
            check("dirty-tree-blocked pull: the captain's uncommitted edit is untouched, not discarded",
                  dirtyContent == "captain's own in-progress edit\n")
        }

        if failures.isEmpty {
            print("VaultRecipeGitSelfTest: all checks passed")
            return true
        } else {
            print("VaultRecipeGitSelfTest: FAILED - \(failures.joined(separator: "; "))")
            return false
        }
    }

    private struct ShellResult { let status: Int32; let stdout: String }

    private static func shell(_ executable: String, _ args: [String]) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return ShellResult(status: -1, stdout: "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ShellResult(status: proc.terminationStatus, stdout: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

#endif
