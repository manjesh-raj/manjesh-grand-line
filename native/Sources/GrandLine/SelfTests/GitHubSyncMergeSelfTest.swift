// Grand Line - native macOS app.
//
// `fm/grandline-github-sync-counts`: the captain could not sync a fork with
// any difference from upstream, and Setup's GitHub sync card read "3 behind"
// above a list where no fork was behind and one was diverged.
//
// Why each half happened, and what this suite pins:
//
// 1. A diverged fork had no action at all. Sync is a fast-forward and refuses
//    it by design, so the row offered nothing and "Diverged" was a dead end.
//    It now offers "Merge upstream", which only ever adds a merge commit on
//    top of the fork's own commits: GitHub's merge-upstream for a real fork,
//    and a `git merge --no-ff` plus a no-force push in the scratch clone for
//    a manual-upstream repo. The merge half runs here against real local
//    repositories, because "it cannot lose a commit" is a property of the git
//    commands, not of a fixture.
// 2. The card counted only forks a fast-forward could catch up (so a
//    diverged fork read "In sync"), and the page published only while it was
//    on screen (so a check that finished behind another page never reached
//    the card, and an older poll's "3 behind" stood).
//
// Headless on purpose: a real page's `loadView` and render path, the real
// poller and the real notification center, and no window - so it guards a
// merge from CI's blocking lane.
//
// Run with:
//   swift build && FM_RUN_GITHUB_SYNC_MERGE_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum GitHubSyncMergeSelfTest {

    static func run() -> Bool {
        print("GitHubSyncMergeSelfTest")
        var ok = true
        checkClassification(&ok)
        checkInputValidation(&ok)
        checkMergeUpstreamResponses(&ok)
        checkCleanMergeKeepsTheForksCommits(&ok)
        checkConflictPushesNothing(&ok)
        checkMovedForkIsNeverOverwritten(&ok)
        checkPageOffersTheRightAction(&ok)
        checkMergeIsConfirmedFirst(&ok)
        checkARefusalKeepsItsReason(&ok)
        checkSyncAllNeverMerges(&ok)
        checkTheCaptainsCount(&ok)
        checkEachForkKeepsItsNewestReading(&ok)
        checkThePageAdoptsNewerReadings(&ok)
        checkTheFigureWords(&ok)
        checkTheBellCountsDivergedForks(&ok)
        checkTheScheduleNeverMergesButPublishes(&ok)
        print(ok ? "\nGitHubSyncMergeSelfTest: all checks passed" : "\nGitHubSyncMergeSelfTest: FAILED")
        return ok
    }

    // MARK: - Fixtures

    private static let repos = GitHubSyncCatalog.repos

    private static func outcome(_ status: GitHubSyncStatus, _ detail: String = "fixture") -> GitHubSyncCheckOutcome {
        GitHubSyncCheckOutcome(status: status, upstreamFullName: "kunchenguid/x", detail: detail, log: "")
    }

    private static func pump(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// The real shared poller and center, restored afterwards (AGENTS.md's
    /// hermeticity rule), with the confirm dialog answered by `answer`.
    private static func isolated(answer: HelmConfirm.Response = .confirm,
                                 _ body: (_ asked: () -> [HelmConfirm.Request]) -> Void) {
        let poller = BackgroundSignalsPoller.shared
        let counts = poller.lastCounts
        let responder = HelmConfirm.responderForTests
        var asked: [HelmConfirm.Request] = []
        HelmConfirm.responderForTests = { request in
            asked.append(request)
            return answer
        }
        poller.debugResetReadingClock()
        poller.debugSetCounts(.init())
        defer {
            HelmConfirm.responderForTests = responder
            poller.debugResetReadingClock()
            poller.debugSetCounts(counts)
            GrandLineNotificationCenter.shared.debugReset()
        }
        body({ asked })
    }

    /// A real page with `loadView` run and no window - so no first-visit
    /// sweep - and fixture actions that record what they were asked to do.
    private final class Recorder {
        var checked: [String] = []
        var synced: [String] = []
        var merged: [String] = []
        var checkResult: (GitHubSyncRepoConfig) -> GitHubSyncCheckOutcome = { _ in outcome(.inSync) }
        var syncResult = GitHubSyncSyncOutcome(ok: true, refusedDiverged: false, detail: "synced", log: "")
        var mergeResult = GitHubSyncSyncOutcome(ok: true, refusedDiverged: false, detail: "merged", log: "")
    }

    private static func page(_ recorder: Recorder) -> GitHubSyncController {
        let page = GitHubSyncController()
        page.actions = GitHubSyncActions(
            check: { repo in
                DispatchQueue.main.sync { recorder.checked.append(repo.fullName) }
                return recorder.checkResult(repo)
            },
            sync: { repo in
                DispatchQueue.main.sync { recorder.synced.append(repo.fullName) }
                return recorder.syncResult
            },
            mergeUpstream: { repo in
                DispatchQueue.main.sync { recorder.merged.append(repo.fullName) }
                return recorder.mergeResult
            })
        page.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
        page.adoptSidebarLayout()
        page.view.layoutSubtreeIfNeeded()
        return page
    }

    // MARK: 1 - four states from two counts

    private static func checkClassification(_ ok: inout Bool) {
        print("\n-- a fork's state from its two commit counts --")
        check(GitHubSyncStatus.from(localOnly: 1, upstreamAhead: 26) == .diverged(localOnly: 1, upstreamAhead: 26),
              "own commits and upstream ahead is diverged", &ok)
        // The discriminating case: this used to be `.diverged`, a red alarm
        // with nothing to pull and nothing anyone could do.
        check(GitHubSyncStatus.from(localOnly: 2, upstreamAhead: 0) == .ahead(2),
              "own commits and nothing upstream is ahead, not diverged", &ok)
        check(GitHubSyncStatus.from(localOnly: 0, upstreamAhead: 3) == .behind(3), "upstream ahead only is behind", &ok)
        check(GitHubSyncStatus.from(localOnly: 0, upstreamAhead: 0) == .inSync, "neither is in sync", &ok)
        check(GitHubSyncStatus.diverged(localOnly: 1, upstreamAhead: 26).showsMergeUpstream
              && !GitHubSyncStatus.diverged(localOnly: 1, upstreamAhead: 26).showsSyncButton,
              "a diverged fork offers a merge and never a fast-forward", &ok)
        check(!GitHubSyncStatus.ahead(2).needsSync && GitHubSyncStatus.ahead(2).isUpToDate,
              "an ahead fork needs nothing", &ok)
        let detail = GitHubSyncStatus.detail(localOnly: 1, upstreamAhead: 26, upstream: "automic-vault/automic-vault")
        check(detail == "Diverged - 1 commit of its own, 26 commits behind automic-vault/automic-vault",
              "the diverged detail reads '\(detail)'", &ok)
    }

    // MARK: 2 - nothing that starts with a dash reaches gh or git

    private static func checkInputValidation(_ ok: inout Bool) {
        print("\n-- every name is validated before it reaches an argv --")
        for bad in ["-x", "--upload-pack=touch", ".hidden", "a b", "a;b", "", "a/b"] {
            check(!GitHubSyncInput.isSafeName(bad), "'\(bad)' is refused as a name", &ok)
        }
        for good in ["manjesh-raj", "automic-vault", "gh-axi", "repo.name", "x_1"] {
            check(GitHubSyncInput.isSafeName(good), "'\(good)' is accepted as a name", &ok)
        }
        for bad in ["-main", "--exec=x", "a..b", "a b", "/main", "main/", "x.lock", "a;b"] {
            check(!GitHubSyncInput.isSafeBranch(bad), "'\(bad)' is refused as a branch", &ok)
        }
        for good in ["main", "master", "release/1.2", "dev_x"] {
            check(GitHubSyncInput.isSafeBranch(good), "'\(good)' is accepted as a branch", &ok)
        }
        // Behaviourally: the three entry points refuse before running
        // anything. `gh` is refused in a test process anyway, so the detail
        // is what tells a validation refusal from a launch refusal.
        let hostile = GitHubSyncRepoConfig(owner: "--upload-pack=touch", name: "x")
        check(GitHubSyncSource.check(hostile).detail.hasPrefix("Refused"), "check refuses a hostile owner", &ok)
        check(GitHubSyncSource.sync(hostile).detail.hasPrefix("Refused"), "sync refuses a hostile owner", &ok)
        check(GitHubSyncSource.mergeUpstream(hostile).detail.hasPrefix("Refused"), "merge refuses a hostile owner", &ok)
        let hostileUpstream = GitHubSyncRepoConfig(owner: "manjesh-raj", name: "x",
                                                   manualUpstreamOwner: "-o", manualUpstreamName: "y")
        check(GitHubSyncSource.mergeUpstream(hostileUpstream).detail.hasPrefix("Refused"),
              "merge refuses a hostile manual upstream", &ok)
    }

    // MARK: 3 - GitHub's merge-upstream answers

    private static func checkMergeUpstreamResponses(_ ok: inout Bool) {
        print("\n-- each merge-upstream answer, as an outcome --")
        let repo = GitHubSyncRepoConfig(owner: "manjesh-raj", name: "gh-axi")
        func classify(_ status: Int32, _ stdout: String, _ log: String) -> GitHubSyncSyncOutcome {
            GitHubSyncSource.classifyMergeUpstream(status: status, stdout: stdout, log: log, repo: repo,
                                                   upstream: "kunchenguid/gh-axi", branch: "main")
        }
        let merged = classify(0, #"{"merge_type":"merge","base_branch":"kunchenguid:main"}"#, "")
        check(merged.ok && merged.problem == nil && merged.detail.contains("own commits are unchanged"),
              "a 200 merge is a success that says the fork's commits stayed: \(merged.detail)", &ok)
        check(classify(0, #"{"merge_type":"fast-forward"}"#, "").ok, "a 200 fast-forward is a success", &ok)
        check(classify(0, #"{"merge_type":"none"}"#, "").detail.hasPrefix("Already up to date"), "a 200 none says so", &ok)

        let conflict = classify(1, "", "gh: Merge conflict (HTTP 409)")
        check(!conflict.ok && conflict.refusedDiverged, "a 409 is a refusal, not a generic failure", &ok)
        check(conflict.problem?.nextStep.contains("Nothing was changed") == true
              && conflict.problem?.nextStep.contains("git merge upstream/main") == true,
              "a 409 says nothing changed and how to merge by hand: \(conflict.problem?.nextStep ?? "nil")", &ok)
        check(conflict.problem?.compareURL?.absoluteString
              == "https://github.com/manjesh-raj/gh-axi/compare/main...kunchenguid:gh-axi:main",
              "a 409 offers GitHub's compare page: \(conflict.problem?.compareURL?.absoluteString ?? "nil")", &ok)
        let refused = classify(1, "", "gh: Validation Failed (HTTP 422)")
        check(!refused.ok && refused.problem != nil, "a 422 carries a reason and a next step", &ok)
        let offline = classify(1, "", "error connecting to api.github.com")
        check(!offline.ok && !offline.refusedDiverged && offline.problem == nil,
              "a network failure is a plain failure, not a refusal", &ok)
    }

    // MARK: 4..6 - the scratch-clone merge, against real repositories

    /// Two bare repositories standing in for the fork and its upstream on
    /// GitHub, sharing one base commit, and a scratch clone of the fork with
    /// both fetched - the exact state `mergeManual` hands `mergeInClone`.
    private struct GitRig {
        let root: URL
        let origin: URL
        let upstream: URL
        let clone: URL

        @discardableResult
        func git(_ args: [String], in dir: URL) -> SubprocessResult {
            Subprocess.git(args, cwd: dir, timeout: 30)
        }

        func tip(_ repo: URL, _ ref: String = "main") -> String {
            git(["rev-parse", ref], in: repo).stdout
        }

        func isAncestor(_ commit: String, of descendant: String, in repo: URL) -> Bool {
            git(["merge-base", "--is-ancestor", commit, descendant], in: repo).status == 0
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// `forkFile`/`upstreamFile` name the file each side changes; the same
    /// name on both sides is a conflict.
    private static func makeRig(forkFile: String, upstreamFile: String) -> GitRig? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gl-merge-\(UUID().uuidString)", isDirectory: true)
        let origin = root.appendingPathComponent("origin.git")
        let upstream = root.appendingPathComponent("upstream.git")
        let seed = root.appendingPathComponent("seed")
        let clone = root.appendingPathComponent("clone")
        let rig = GitRig(root: root, origin: origin, upstream: upstream, clone: clone)
        try? fm.createDirectory(at: seed, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String, in dir: URL) {
            try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func commit(_ message: String, in dir: URL) {
            rig.git(["add", "-A"], in: dir)
            rig.git(["commit", "-q", "-m", message], in: dir)
        }
        func identify(_ dir: URL) {
            rig.git(["config", "user.name", "Self Test"], in: dir)
            rig.git(["config", "user.email", "selftest@example.test"], in: dir)
            rig.git(["config", "commit.gpgsign", "false"], in: dir)
        }
        rig.git(["init", "-q", "-b", "main"], in: seed)
        identify(seed)
        write("base.txt", "base\n", in: seed)
        write("shared.txt", "one\ntwo\nthree\n", in: seed)
        commit("base", in: seed)
        rig.git(["clone", "-q", "--bare", seed.path, upstream.path], in: root)
        rig.git(["clone", "-q", "--bare", seed.path, origin.path], in: root)

        // The fork's own commit, pushed to the fork.
        let forkWork = root.appendingPathComponent("fork-work")
        rig.git(["clone", "-q", origin.path, forkWork.path], in: root)
        identify(forkWork)
        write(forkFile, "the fork's own change\n", in: forkWork)
        commit("fork's own commit", in: forkWork)
        rig.git(["push", "-q", "origin", "main"], in: forkWork)

        // Two upstream commits the fork does not have.
        let upstreamWork = root.appendingPathComponent("upstream-work")
        rig.git(["clone", "-q", upstream.path, upstreamWork.path], in: root)
        identify(upstreamWork)
        write(upstreamFile, "upstream's change\n", in: upstreamWork)
        commit("upstream one", in: upstreamWork)
        write("upstream-two.txt", "two\n", in: upstreamWork)
        commit("upstream two", in: upstreamWork)
        rig.git(["push", "-q", "origin", "main"], in: upstreamWork)

        // The scratch clone, as `ensureManualClone` + `ensureUpstreamRemote`
        // + the two fetches leave it.
        rig.git(["clone", "-q", "--single-branch", "--no-tags", origin.path, clone.path], in: root)
        identify(clone)
        rig.git(["remote", "add", "upstream", upstream.path], in: clone)
        rig.git(["fetch", "-q", "origin", "main"], in: clone)
        rig.git(["fetch", "-q", "upstream", "main"], in: clone)
        guard rig.tip(origin) != rig.tip(upstream),
              rig.git(["rev-parse", "upstream/main"], in: clone).status == 0 else {
            rig.remove()
            return nil
        }
        return rig
    }

    private static func merge(_ rig: GitRig) -> GitHubSyncSyncOutcome {
        GitHubSyncSource.mergeInClone(dir: rig.clone, branch: "main", upstreamBranch: "main",
                                      repoFullName: "manjesh-raj/automic-vault",
                                      upstreamFullName: "automic-vault/automic-vault", authenticated: false)
    }

    private static func checkCleanMergeKeepsTheForksCommits(_ ok: inout Bool) {
        print("\n-- a clean merge adds a merge commit and keeps every commit of the fork's own --")
        guard let rig = makeRig(forkFile: "fork.txt", upstreamFile: "upstream.txt") else {
            fail("could not build the git fixture", &ok)
            return
        }
        defer { rig.remove() }
        let forkTipBefore = rig.tip(rig.origin)
        let upstreamTip = rig.tip(rig.upstream)
        let outcome = merge(rig)
        check(outcome.ok, "the merge succeeded: \(outcome.detail)\n\(outcome.log)", &ok)
        let forkTipAfter = rig.tip(rig.origin)
        check(forkTipAfter != forkTipBefore, "the fork moved on 'GitHub'", &ok)
        check(rig.isAncestor(forkTipBefore, of: forkTipAfter, in: rig.origin),
              "the fork's previous tip - its own commit - is in the result", &ok)
        let parents = rig.git(["rev-list", "--parents", "-n", "1", "main"], in: rig.origin).stdout
            .split(separator: " ").dropFirst().map(String.init)
        check(parents.first == forkTipBefore, "the merge's first parent is the fork's own tip: \(parents)", &ok)
        // The bare upstream repo is not reachable from the fork's bare repo by
        // name, so ask the clone, which has both.
        check(rig.isAncestor(upstreamTip, of: forkTipAfter, in: rig.clone), "upstream's tip is in the result", &ok)
    }

    private static func checkConflictPushesNothing(_ ok: inout Bool) {
        print("\n-- a conflict pushes nothing and leaves the clone clean --")
        guard let rig = makeRig(forkFile: "shared.txt", upstreamFile: "shared.txt") else {
            fail("could not build the conflicting git fixture", &ok)
            return
        }
        defer { rig.remove() }
        let forkTipBefore = rig.tip(rig.origin)
        let outcome = merge(rig)
        check(!outcome.ok && outcome.refusedDiverged, "a conflict is a refusal: \(outcome.detail)", &ok)
        check(outcome.problem?.reason.contains("shared.txt") == true,
              "the reason names the conflicting file: \(outcome.problem?.reason ?? "nil")", &ok)
        check(outcome.problem?.nextStep.contains("Nothing was pushed") == true, "and says nothing was pushed", &ok)
        check(rig.tip(rig.origin) == forkTipBefore, "the fork on 'GitHub' is exactly where it was", &ok)
        let mergeHead = rig.clone.appendingPathComponent(".git/MERGE_HEAD")
        check(!FileManager.default.fileExists(atPath: mergeHead.path), "the half-done merge was aborted", &ok)
        check(rig.git(["status", "--porcelain"], in: rig.clone).stdout.isEmpty, "the scratch clone is clean", &ok)
    }

    private static func checkMovedForkIsNeverOverwritten(_ ok: inout Bool) {
        print("\n-- a fork that moved on GitHub mid-merge is refused, not overwritten --")
        guard let rig = makeRig(forkFile: "fork.txt", upstreamFile: "upstream.txt") else {
            fail("could not build the git fixture", &ok)
            return
        }
        defer { rig.remove() }
        // Someone pushes to the fork after the clone fetched it.
        let elsewhere = rig.root.appendingPathComponent("elsewhere")
        rig.git(["clone", "-q", rig.origin.path, elsewhere.path], in: rig.root)
        rig.git(["config", "user.name", "Self Test"], in: elsewhere)
        rig.git(["config", "user.email", "selftest@example.test"], in: elsewhere)
        try? "late\n".write(to: elsewhere.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
        rig.git(["add", "-A"], in: elsewhere)
        rig.git(["commit", "-q", "-m", "a late commit on the fork"], in: elsewhere)
        rig.git(["push", "-q", "origin", "main"], in: elsewhere)
        let movedTip = rig.tip(rig.origin)
        let outcome = merge(rig)
        check(!outcome.ok && outcome.problem != nil, "the push was refused with a reason: \(outcome.detail)", &ok)
        check(rig.tip(rig.origin) == movedTip, "the late commit is still the fork's tip - nothing was overwritten", &ok)
    }

    // MARK: 7..10 - the page

    private static func checkPageOffersTheRightAction(_ ok: inout Bool) {
        print("\n-- each row offers the one action its state allows --")
        isolated { _ in
            let page = page(Recorder())
            page.debugApplyCheck(index: 0, status: .behind(3), upstream: "kunchenguid/x")
            page.debugApplyCheck(index: 1, status: .inSync, upstream: "kunchenguid/x")
            page.debugApplyCheck(index: 6, status: .diverged(localOnly: 1, upstreamAhead: 26),
                                 upstream: "automic-vault/automic-vault")
            page.debugApplyCheck(index: 7, status: .ahead(2), upstream: "kunchenguid/x")
            let tableRows = page.debugForksTable.debugRows
            func row(_ index: Int) -> HelmDataTable.Row? {
                tableRows.first { if case .record(let key) = $0.kind { return key == repos[index].fullName }; return false }
            }
            check(row(0)?.primary?.title == "Sync", "a behind fork's button is Sync: \(row(0)?.primary?.title ?? "none")", &ok)
            check(row(6)?.primary?.title == "Merge",
                  "the diverged fork has a button, and it is Merge: \(row(6)?.primary?.title ?? "none")", &ok)
            check(row(6)?.menu.first?.title == "Merge Upstream\u{2026}",
                  "the diverged fork's \u{22EF} menu leads with the merge: \(row(6)?.menu.map(\.title) ?? [])", &ok)
            check(row(1)?.primary == nil && row(7)?.primary == nil, "an in-sync or ahead fork offers nothing", &ok)
        }
    }

    private static func checkMergeIsConfirmedFirst(_ ok: inout Bool) {
        print("\n-- a merge says what it will do, and does nothing when cancelled --")
        isolated(answer: .cancel) { asked in
            let recorder = Recorder()
            let page = page(recorder)
            page.debugApplyCheck(index: 6, status: .diverged(localOnly: 1, upstreamAhead: 26),
                                 upstream: "automic-vault/automic-vault")
            page.requestSync(page.rows[6])
            pump(until: { false }, timeout: 0.2)
            let request = asked().first
            check(request?.title == "Merge automic-vault/automic-vault into manjesh-raj/automic-vault?",
                  "the confirm names both sides: \(request?.title ?? "no confirm at all")", &ok)
            let body = request?.body ?? ""
            check(body.contains("1 commit of its own") && body.contains("26 commits behind"),
                  "the confirm states the two counts: \(body)", &ok)
            check(body.contains("stay exactly as they are") && body.contains("nothing is force-pushed"),
                  "the confirm says the fork's commits stay and nothing is forced", &ok)
            check(recorder.merged.isEmpty && recorder.synced.isEmpty, "cancel ran nothing", &ok)
        }
        isolated(answer: .confirm) { asked in
            let recorder = Recorder()
            recorder.checkResult = { _ in outcome(.ahead(2)) }
            let page = page(recorder)
            page.debugApplyCheck(index: 6, status: .diverged(localOnly: 1, upstreamAhead: 26),
                                 upstream: "automic-vault/automic-vault")
            page.requestSync(page.rows[6])
            pump(until: { page.rows[6].status == .ahead(2) })
            check(recorder.merged == ["manjesh-raj/automic-vault"] && recorder.synced.isEmpty,
                  "confirming ran the merge once and never a fast-forward: merged \(recorder.merged), synced \(recorder.synced)", &ok)
            check(recorder.checked == ["manjesh-raj/automic-vault"], "and re-checked the fork afterwards", &ok)
            check(asked().count == 1, "one confirm, no problem notice", &ok)
        }
        isolated(answer: .confirm) { asked in
            let recorder = Recorder()
            let page = page(recorder)
            page.debugApplyCheck(index: 0, status: .behind(3), upstream: "kunchenguid/chrome-devtools-axi")
            page.requestSync(page.rows[0])
            pump(until: { !recorder.checked.isEmpty })
            check(asked().first?.body.contains("fast-forward") == true, "a behind fork's confirm says fast-forward", &ok)
            check(recorder.synced == [repos[0].fullName] && recorder.merged.isEmpty,
                  "a behind fork is fast-forwarded and never merged", &ok)
        }
    }

    private static func checkARefusalKeepsItsReason(_ ok: inout Bool) {
        print("\n-- a conflict is said out loud and stays on the row --")
        isolated(answer: .cancel) { asked in
            let recorder = Recorder()
            recorder.checkResult = { _ in outcome(.diverged(localOnly: 1, upstreamAhead: 26), "still diverged") }
            let problem = GitHubSyncProblem(reason: "both change shared.txt", nextStep: "Nothing was pushed.", compareURL: nil)
            recorder.mergeResult = GitHubSyncSyncOutcome(ok: false, refusedDiverged: true, detail: "Not merged",
                                                         log: "CONFLICT", problem: problem)
            let page = page(recorder)
            page.debugApplyCheck(index: 6, status: .diverged(localOnly: 1, upstreamAhead: 26),
                                 upstream: "automic-vault/automic-vault")
            page.mergeUpstream(page.rows[6])
            pump(until: { !recorder.checked.isEmpty && !page.rows[6].isBusy })
            check(asked().contains { $0.title == "manjesh-raj/automic-vault was not changed" && $0.body.contains("shared.txt") },
                  "a notice said why and what next: \(asked().map(\.title))", &ok)
            check(page.rows[6].problem == problem, "the reason survived the re-check", &ok)
            let fork = page.debugForksTable.debugRows.first {
                if case .record(let key) = $0.kind { return key == "manjesh-raj/automic-vault" }
                return false
            }?.cells["fork"]
            if case .title(_, let subtitle, _, _, _, _)? = fork {
                check(subtitle == "both change shared.txt", "the row's subtitle is the reason: \(subtitle ?? "nil")", &ok)
            } else {
                fail("the fork cell is missing", &ok)
            }
        }
    }

    private static func checkSyncAllNeverMerges(_ ok: inout Bool) {
        print("\n-- Sync all fast-forwards and leaves a diverged fork to its own row --")
        isolated(answer: .confirm) { asked in
            let recorder = Recorder()
            let page = page(recorder)
            page.debugApplyCheck(index: 0, status: .behind(3), upstream: "kunchenguid/x")
            page.debugApplyCheck(index: 6, status: .diverged(localOnly: 1, upstreamAhead: 26), upstream: "automic-vault/automic-vault")
            page.requestSyncAll()
            pump(until: { recorder.checked.count == 1 })
            check(asked().first?.body.contains("The diverged fork is left alone") == true,
                  "the confirm says the diverged fork is left alone: \(asked().first?.body ?? "no confirm")", &ok)
            check(recorder.synced == [repos[0].fullName] && recorder.merged.isEmpty,
                  "Sync all synced \(recorder.synced) and merged \(recorder.merged)", &ok)
        }
    }

    // MARK: 11..13 - the counts

    /// The captain's own screen: a poll found three forks behind, then the
    /// page's own check - finished while another page was showing - found
    /// seven in sync and automic-vault diverged. The card must say what the
    /// list says.
    private static func checkTheCaptainsCount(_ ok: inout Bool) {
        print("\n-- the captain's report: the card agrees with the list --")
        isolated { _ in
            let poller = BackgroundSignalsPoller.shared
            let passAt = Date()
            poller.publishForkReadings(repos.enumerated().map { index, repo in
                .init(fullName: repo.fullName, status: [0, 2, 4].contains(index) ? .behind(2) : .inSync,
                      detail: "pass", log: "", gatheredAt: passAt)
            })
            check(SetupSummary.githubCard(poller.lastCounts, configRepo: nil).text == "3 behind",
                  "the fixture starts from the captain's '3 behind'", &ok)

            let page = page(Recorder())
            page.view.isHidden = true
            for index in repos.indices {
                let diverged = repos[index].manualUpstreamFullName != nil
                page.debugApplyCheck(index: index,
                                     status: diverged ? .diverged(localOnly: 1, upstreamAhead: 26) : .inSync,
                                     upstream: "x/y", at: passAt.addingTimeInterval(1))
            }
            let card = SetupSummary.githubCard(poller.lastCounts, configRepo: nil)
            check(card.text == "1 diverged",
                  "a check that finished while the page was hidden reached the card: it reads '\(card.text ?? "-")'", &ok)
            check(card.tint == .critical && card.signals, "and it is painted as the alarm the list shows", &ok)
            check(page.drillHeaderSubtitle == "8 forks \u{00B7} 1 diverged",
                  "the page header agrees: \(page.drillHeaderSubtitle ?? "nil")", &ok)
        }
    }

    private static func checkEachForkKeepsItsNewestReading(_ ok: inout Bool) {
        print("\n-- each fork keeps its newest reading, whoever took it --")
        isolated { _ in
            let poller = BackgroundSignalsPoller.shared
            let now = Date()
            poller.publishForkReadings(repos.map {
                .init(fullName: $0.fullName, status: .inSync, detail: "", log: "", gatheredAt: now)
            })
            // An older pass lands late and says the first fork is behind.
            poller.publishForkReadings([.init(fullName: repos[0].fullName, status: .behind(4), detail: "",
                                              log: "", gatheredAt: now.addingTimeInterval(-60))])
            check(poller.lastCounts.forkDrift == 0, "an older reading did not displace a newer one", &ok)
            // A newer check of one fork changes that fork and nothing else.
            poller.publishForkReadings([.init(fullName: repos[1].fullName, status: .behind(2), detail: "",
                                              log: "", gatheredAt: now.addingTimeInterval(5))])
            check(poller.lastCounts.forkDrift == 1 && poller.lastCounts.forksChecked == repos.count,
                  "one newer reading moved one fork: \(String(describing: poller.lastCounts.forkDrift)) behind", &ok)
            // In-flight states are not answers.
            poller.publishForkReadings([.init(fullName: repos[1].fullName, status: .checking, detail: "",
                                              log: "", gatheredAt: now.addingTimeInterval(9))])
            check(poller.lastCounts.forkDrift == 1, "a .checking row did not overwrite an answer", &ok)
        }
    }

    private static func checkThePageAdoptsNewerReadings(_ ok: inout Bool) {
        print("\n-- the list takes a newer reading another producer took --")
        isolated { _ in
            let page = page(Recorder())
            page.debugApplyCheck(index: 2, status: .behind(5), upstream: "kunchenguid/tasks-axi",
                                 at: Date().addingTimeInterval(-600))
            BackgroundSignalsPoller.shared.publishForkReadings([
                .init(fullName: repos[2].fullName, status: .inSync, upstreamFullName: "kunchenguid/tasks-axi",
                      detail: "In sync with kunchenguid/tasks-axi", log: "", gatheredAt: Date())])
            pump(until: { page.rows[2].status == .inSync }, timeout: 2)
            check(page.rows[2].status == .inSync,
                  "a scheduled sync's newer reading reached the row: \(page.rows[2].status)", &ok)
        }
    }

    private static func checkTheFigureWords(_ ok: inout Bool) {
        print("\n-- the card's word for each mix of forks --")
        func counts(drift: Int, diverged: Int, checked: Int = 8) -> BackgroundSignalsPoller.SignalCounts {
            var counts = BackgroundSignalsPoller.SignalCounts()
            counts.forkDrift = drift
            counts.forksDiverged = diverged
            counts.forksTotal = 8
            counts.forksChecked = checked
            return counts
        }
        let cases: [(BackgroundSignalsPoller.SignalCounts, String?)] = [
            (counts(drift: 3, diverged: 0), "3 behind"),
            (counts(drift: 0, diverged: 1), "1 diverged"),
            (counts(drift: 1, diverged: 1), "2 to sync"),
            (counts(drift: 0, diverged: 0, checked: 0), "Couldn\u{2019}t check"),
            (counts(drift: 0, diverged: 0, checked: 7), "7 / 8 read"),
            (counts(drift: 0, diverged: 0), "In sync"),
            (.init(), nil),
        ]
        for (input, expected) in cases {
            let text = SetupSummary.githubCard(input, configRepo: nil).text
            check(text == expected, "\(expected ?? "a dash") - got \(text ?? "a dash")", &ok)
        }
        // The longest words must fit a card at the narrowest width five of
        // them share: about 140pt each beside the sidebar at 1100pt (measured on the 1100pt render). Measured
        // off the real card after a real layout pass.
        for word in ["1 diverged", "2 to sync", "Couldn\u{2019}t check", "12 / 12 read"] {
            let card = HelmMetricCard(caption: "GitHub sync")
            card.frame = NSRect(x: 0, y: 0, width: 140, height: HelmMetricCard.height)
            card.configure(text: word, signals: true)
            card.layoutSubtreeIfNeeded()
            check(card.debugValueFits, "'\(word)' fits a 140pt card (\(card.debugValuePointSize)pt) rather than truncating", &ok)
        }
        let roomy = HelmMetricCard(caption: "GitHub sync")
        roomy.frame = NSRect(x: 0, y: 0, width: 300, height: HelmMetricCard.height)
        roomy.configure(text: "3 behind", signals: true)
        roomy.layoutSubtreeIfNeeded()
        check(roomy.debugValuePointSize == HelmType.metric(HelmMetricCard.metricSize).pointSize,
              "a figure that fits keeps the full size: \(roomy.debugValuePointSize)pt", &ok)
        // Home's card states the same figure: one definition, asserted as a
        // source guard because Home's card is window-backed.
        if let dir = SelfTestSources.appSourceDirectory(),
           let home = try? String(contentsOf: dir.appendingPathComponent("HomeCanvasController.swift"), encoding: .utf8) {
            check(home.contains("SetupSummary.ForksFigure(BackgroundSignalsPoller.shared.lastCounts)"),
                  "Home's GitHub sync card reads the shared ForksFigure", &ok)
        } else {
            print("  NOTE: could not resolve the app sources - skipping Home's source guard")
        }
    }

    private static func checkTheBellCountsDivergedForks(_ ok: inout Bool) {
        print("\n-- the bell counts a diverged fork, and its button says Merge --")
        isolated { _ in
            BackgroundSignalsPoller.shared.debugRunAmbientForkPass(
                repos: repos,
                outcomes: repos.map { $0.manualUpstreamFullName != nil ? outcome(.diverged(localOnly: 1, upstreamAhead: 26)) : outcome(.inSync) })
            let entry = GrandLineNotificationCenter.shared.entries.first { $0.id == NotificationSources.githubSyncID }
            check(entry?.title == "1 fork is behind upstream", "the bell's title is \(entry?.title ?? "absent")", &ok)
            check(entry?.children.map(\.actionLabel) == ["Merge"], "its child says Merge: \(entry?.children.map(\.actionLabel) ?? [])", &ok)
            check(entry?.primaryAction?.label != "Sync" && entry?.primaryAction?.label != "Sync all",
                  "its primary action never claims a fast-forward: \(entry?.primaryAction?.label ?? "nil")", &ok)
        }
    }

    private static func checkTheScheduleNeverMergesButPublishes(_ ok: inout Bool) {
        print("\n-- a scheduled fork sync publishes what it read, and never merges --")
        isolated { _ in
            // `gh` is refused in a test process, so every check fails - which
            // is still a reading, and it has to reach the poller.
            _ = ScheduleActions.run(.forkSync, backupStores: nil)
            pump(until: { BackgroundSignalsPoller.shared.forkReadings.count == repos.count }, timeout: 3)
            check(BackgroundSignalsPoller.shared.forkReadings.count == repos.count,
                  "the run published \(BackgroundSignalsPoller.shared.forkReadings.count) of \(repos.count) readings", &ok)
            check(SetupSummary.githubCard(BackgroundSignalsPoller.shared.lastCounts, configRepo: nil).text == "Couldn\u{2019}t check",
                  "and the card says so", &ok)
        }
        if let dir = SelfTestSources.appSourceDirectory(),
           let runner = try? String(contentsOf: dir.appendingPathComponent("ScheduleRunner.swift"), encoding: .utf8) {
            check(!runner.contains("mergeUpstream"), "ScheduleRunner never reaches mergeUpstream", &ok)
        }
    }
}

#endif
