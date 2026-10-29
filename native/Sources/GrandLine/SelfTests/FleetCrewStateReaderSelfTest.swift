// Grand Line - native macOS app.
//
// R4-ARCH-02 of the fourth full review: the proof that the fleet shows the
// same thing whether a task's state came from `FleetCrewStateReader` or from
// `bin/fm-crew-state.sh`.
//
// The reader either prints the script's own line or defers, so the proof has
// two halves:
//
//   - **Golden.** Every fixture below is shaped like a real `.meta` from the
//     captain's fleet (the three in `state/` on 2026-10-29, with their paths
//     moved into scratch), plus the edge cases where `grep`-and-bash and Swift
//     could read one file differently. Each carries the verdict the script
//     reaches for it from the file alone, and the reader must give exactly
//     that verdict or `nil`. The suite also asserts it defers on every fixture
//     with a live worktree, because that is where the script reads things this
//     reader cannot.
//   - **Live.** Wherever the real script is installed (the captain's machine,
//     never CI), every fixture the reader answers is also run through the real
//     script, against a scratch state folder, and the two lines must match
//     byte for byte. Only those fixtures: the script stops at the `.meta` for
//     each of them, before it would ask a daemon or a pane anything.
//     `ExternalToolGuard` refuses to start anything inside the real firstmate
//     home from a suite, so the scripts are copied into this suite's temporary
//     folder first and the copy is what runs - the same isolation a stub gets.
//
// Pure logic - a scratch folder and, locally, a subprocess - so it guards the
// blocking CI lane.
//
// Run with:
//   swift build && FM_RUN_FLEET_CREW_STATE_READER_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum FleetCrewStateReaderSelfTest {

    private struct Fixture {
        let name: String
        let meta: String
        /// What the script says from the file alone, or `nil` where the
        /// script goes on to read a run, a pane or a log (or where this reader
        /// must defer for another reason).
        let expected: FleetCrewReading?
    }

    static func run() -> Bool {
        var ok = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-crew-state-reader-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        let live = root.appendingPathComponent("treehouse/grand-line-a904e0/1/grand-line", isDirectory: true)
        let gone = root.appendingPathComponent("treehouse/deploy_engine-a6a45b/1/deploy_engine").path
        let aFile = root.appendingPathComponent("not-a-folder").path
        let liveLink = root.appendingPathComponent("live-link").path
        let brokenLink = root.appendingPathComponent("broken-link").path
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: aFile, contents: Data("x".utf8))
        try? FileManager.default.createSymbolicLink(atPath: liveLink, withDestinationPath: live.path)
        try? FileManager.default.createSymbolicLink(atPath: brokenLink, withDestinationPath: gone)

        let fixtures = makeFixtures(live: live.path, gone: gone, aFile: aFile,
                                    liveLink: liveLink, brokenLink: brokenLink)
        // The fixture set's own discriminating power: it must hold both
        // verdicts, several of each, or a reader that always answers (or
        // never does) could pass it.
        let answered = fixtures.filter { $0.expected != nil }.count
        check(answered >= 6 && fixtures.count - answered >= 6,
              "the fixtures should hold at least six of each verdict, got \(answered) answered and "
              + "\(fixtures.count - answered) deferred", &ok)

        print("\n-- the reader gives the script's own verdict, or defers --")
        for fixture in fixtures {
            let url = state.appendingPathComponent("\(fixture.name).meta")
            FileManager.default.createFile(atPath: url.path, contents: Data(fixture.meta.utf8))
            let got = FleetCrewStateReader.reading(metaURL: url, environment: [:])
            check(got == fixture.expected,
                  "\(fixture.name): expected \(describe(fixture.expected)), the reader said \(describe(got))", &ok)
        }

        print("\n-- an override the script honours makes the reader defer --")
        let torn = state.appendingPathComponent("scout-torn-down.meta")
        for name in FleetCrewStateReader.overridingEnvironment {
            let got = FleetCrewStateReader.reading(metaURL: torn, environment: [name: "/elsewhere"])
            check(got == nil, "with \(name) set the reader should defer, it said \(describe(got))", &ok)
        }
        check(FleetCrewStateReader.reading(metaURL: torn, environment: [:]) == FleetCrewStateReader.worktreeGone,
              "the override fixture should be one the reader answers without an override", &ok)

        print("\n-- the golden line is the script's line, where the script is installed --")
        if let installed = installedScript(), let script = copyAside(installed, into: root) {
            for fixture in fixtures {
                guard let expected = fixture.expected else { continue }
                let result = Subprocess.run(
                    executable: "/bin/bash", arguments: [script, fixture.name],
                    cwd: root,
                    extraEnv: ["FM_STATE_OVERRIDE": state.path, "FM_HOME": root.path],
                    timeout: 20, stderr: .discard)
                let line = "state: \(expected.state) \u{00B7} source: \(expected.source) \u{00B7} \(expected.detail)"
                check(result.ok && result.stdout == line,
                      "\(fixture.name): the real script printed \"\(result.stdout)\" (exit ok: \(result.ok)), "
                      + "the reader's verdict is \"\(line)\"", &ok)
            }
            print("  compared against a copy of \(installed)")
        } else {
            print("  SKIP: fm-crew-state.sh is not installed here (CI) - the golden half above still ran")
        }

        print("FleetCrewStateReaderSelfTest: \(ok ? "PASSED" : "FAILED")")
        return ok
    }

    private static func describe(_ reading: FleetCrewReading?) -> String {
        reading.map { "\($0.state) / \($0.source) / \($0.detail)" } ?? "nil (defer to the script)"
    }

    /// The real script, from firstmate's conventional homes. Never
    /// `FirstmateHome`, which a suite may have pinned to scratch.
    private static func installedScript() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["manjesh/firstmate", "firstmate"]
            .map { home.appendingPathComponent($0).appendingPathComponent("bin/fm-crew-state.sh").path }
            .first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Every top-level `*.sh` beside `script` (it sources its libraries from
    /// its own folder), copied into `root`. Returns the copy's path.
    private static func copyAside(_ script: String, into root: URL) -> String? {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: script).deletingLastPathComponent()
        let bin = root.appendingPathComponent("bin-copy", isDirectory: true)
        guard (try? fm.createDirectory(at: bin, withIntermediateDirectories: true)) != nil,
              let names = try? fm.contentsOfDirectory(atPath: source.path) else { return nil }
        for name in names where name.hasSuffix(".sh") {
            try? fm.copyItem(at: source.appendingPathComponent(name), to: bin.appendingPathComponent(name))
        }
        let copy = bin.appendingPathComponent(URL(fileURLWithPath: script).lastPathComponent).path
        return fm.fileExists(atPath: copy) ? copy : nil
    }

    private static func makeFixtures(live: String, gone: String, aFile: String,
                                     liveLink: String, brokenLink: String) -> [Fixture] {
        let tornDown = FleetCrewStateReader.worktreeGone
        // The three real shapes, as they were in the captain's `state/`.
        func scout(_ worktree: String) -> String {
            """
            window=default:w5V:p2
            endpoint_task_id=deploy-engine-cognito-token-impact-1792390245
            worktree=\(worktree)
            project=/Users/captain/firstmate/projects/deploy_engine
            harness=claude
            kind=scout
            tasktmp=/tmp/fm-deploy-engine-cognito-token-impact-1792390245
            model=default
            effort=xhigh
            spawn_gen=s1792390258.29032.27637
            backend=herdr
            herdr_session=default
            herdr_workspace_id=w5V
            herdr_tab_id=w5V:t2
            herdr_pane_id=w5V:p2
            decisions_reviewed=1
            decision_keys=cognito-token-change-optout-decision-1792390245

            """
        }
        func ship(_ worktreeLines: String, extra: String = "") -> String {
            """
            window=default:w7N:p2
            endpoint_task_id=grandline-review4-archperf-1793251195
            \(worktreeLines)
            project=/Users/captain/firstmate/projects/grand-line
            harness=claude
            approval_mode=bypass
            kind=ship
            mode=direct-PR
            yolo=off
            branch=fm/grandline-review4-archperf-1793251195
            tasktmp=/tmp/fm-grandline-review4-archperf-1793251195
            model=claude-opus-5-5
            effort=high
            busy_gen=g1793251216.8085.19054
            spawn_gen=s1793251216.6095.9566
            backend=herdr
            herdr_session=default
            herdr_workspace_id=w7N
            herdr_tab_id=w7N:t2
            herdr_pane_id=w7N:p2\(extra)

            """
        }
        return [
            Fixture(name: "scout-live", meta: scout(live), expected: nil),
            Fixture(name: "scout-torn-down", meta: scout(gone), expected: tornDown),
            Fixture(name: "ship-live", meta: ship("worktree=\(live)"), expected: nil),
            Fixture(name: "ship-torn-down", meta: ship("worktree=\(gone)"), expected: tornDown),
            Fixture(name: "ship-no-worktree-key", meta: ship("harness_note=none"), expected: tornDown),
            Fixture(name: "ship-empty-worktree", meta: ship("worktree="), expected: tornDown),
            // `tail -1`: the last line wins, in both directions.
            Fixture(name: "worktree-twice-last-gone", meta: ship("worktree=\(live)\nworktree=\(gone)"),
                    expected: tornDown),
            Fixture(name: "worktree-twice-last-live", meta: ship("worktree=\(gone)\nworktree=\(live)"),
                    expected: nil),
            // `grep "^worktree="`: an indented or commented key is no key at
            // all to the script, though `parseMetaFile` would trim it into one.
            Fixture(name: "worktree-indented", meta: ship(" worktree=\(live)"), expected: tornDown),
            Fixture(name: "worktree-commented", meta: ship("#worktree=\(live)"), expected: tornDown),
            // `cut -d= -f2-`: a value keeps every later `=`.
            Fixture(name: "worktree-with-equals", meta: ship("worktree=\(gone)/a=b"), expected: tornDown),
            // An untrimmed value: the trailing space is part of the path.
            Fixture(name: "worktree-trailing-space", meta: ship("worktree=\(live) "), expected: tornDown),
            // `[ -d ]`: a file is not a folder, a link to one is, a broken one
            // is not.
            Fixture(name: "worktree-is-a-file", meta: ship("worktree=\(aFile)"), expected: tornDown),
            Fixture(name: "worktree-is-a-link", meta: ship("worktree=\(liveLink)"), expected: nil),
            Fixture(name: "worktree-broken-link", meta: ship("worktree=\(brokenLink)"), expected: tornDown),
            // A remote secondmate's worktree is a path on its own host.
            Fixture(name: "remote-secondmate", meta: ship("worktree=\(gone)", extra: "\nremote_host=fleet-2"),
                    expected: nil),
            Fixture(name: "remote-host-empty", meta: ship("worktree=\(gone)", extra: "\nremote_host="),
                    expected: tornDown),
            Fixture(name: "empty-meta", meta: "", expected: tornDown),
            // Values this reader does not understand, whatever the script says.
            Fixture(name: "relative-worktree", meta: ship("worktree=treehouse/x"), expected: nil),
            Fixture(name: "crlf-meta", meta: ship("worktree=\(gone)").replacingOccurrences(of: "\n", with: "\r\n"),
                    expected: nil),
            Fixture(name: "tab-in-worktree", meta: ship("worktree=\(gone)\tx"), expected: nil),
        ]
    }
}

#endif
