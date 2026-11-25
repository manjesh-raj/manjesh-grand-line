// Grand Line - native macOS app.
//
// S01 of the 2026-11-17 UI/UX proposals: the guard that makes
// `HelmKit.version` mean something. `HelmKitVersion.swift`'s header has the
// model and the bump rule; this suite enforces it.
//
// Run with `FM_RUN_HELM_KIT_VERSION_TESTS=1 .build/debug/GrandLine`.
//
// Source reads, hashing and read-only `git` (`ls-tree`, `show`, `rev-parse`,
// `merge-base`) - no window, no session. Deliberately NOT in `NEEDS_SESSION`,
// so it guards CI's blocking lane, whose checkout has the full history.
//
// What it checks:
//
//   1. Every top-level type in a kit file has a table entry, and every entry
//      still names a type in its file.
//   2. Every version is `major.minor.patch`.
//   3. P-01 of the 2026-11-25 review: every kit file is hashed at the base
//      revision and in the working tree, and a file whose code changed must
//      move at least one of its components' versions (and a version may only
//      move with a change). No digest is committed; both sides are computed
//      here, so the table stops being a merge point. The base is
//      `FM_HELM_KIT_BASE` when set (CI sets it, and a base that does not
//      resolve fails the run), and otherwise the merge base with
//      `origin/main`, skipped loudly when there is none.
//   4. The release notes - the frozen history in
//      `docs/design-system/helm-kit-versions.md` and one file per release in
//      `docs/design-system/helm-kit-releases/` - write the bump kind the
//      numbers actually describe, name the removed or renamed API on a major,
//      and reach every version in the table.
//
// Each rule is first run against a fixture it must fail, so a drifted check
// fails loudly instead of passing vacuously.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import CryptoKit
import Foundation

enum HelmKitVersionSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== HelmKitVersionSelfTest ==")
        checkTheDigestIgnoresCommentsOnly(&ok)
        checkTheBumpClassifier(&ok)
        checkVersionsAreSemver(&ok)
        checkTheChangeRuleFires(&ok)
        checkTheReleaseRulesFire(&ok)
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not next to this binary")
            return ok
        }
        let kitFiles = kitFileNames(in: dir)
        check(kitFiles.count >= 30, "found the kit's files (\(kitFiles.count))", &ok)
        checkEveryKitTypeIsInTheTable(dir, kitFiles, &ok)
        checkAgainstTheBase(dir, kitFiles, &ok)
        checkTheReleaseNotes(dir, &ok)
        print(ok ? "HelmKitVersionSelfTest: OK" : "HelmKitVersionSelfTest: FAILED")
        return ok
    }

    // MARK: - The kit's files and types

    /// Every `Helm*.swift` in the app's directory except the table itself.
    static func kitFileNames(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return kitFiles(among: names)
    }

    static func kitFiles(among names: [String]) -> [String] {
        names.filter { $0.hasPrefix("Helm") && $0.hasSuffix(".swift") && $0 != "HelmKitVersion.swift" }.sorted()
    }

    /// Top-level `Helm*` types declared in one file's source.
    static func declaredTypes(in source: String) -> [String] {
        let pattern = #"^(?:@MainActor )?(?:final |public )?(?:class|enum|struct|protocol) (Helm[A-Za-z0-9]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let ns = source as NSString
        return re.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func checkEveryKitTypeIsInTheTable(_ dir: URL, _ kitFiles: [String], _ ok: inout Bool) {
        var declared: Set<String> = []
        for file in kitFiles {
            guard let source = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else {
                fail("could not read \(file)", &ok)
                continue
            }
            for name in declaredTypes(in: source) { declared.insert("\(name)@\(file)") }
        }
        let tabled = HelmKit.components.map { "\($0.name)@\($0.file)" }
        let duplicates = Dictionary(grouping: HelmKit.components.map(\.name), by: { $0 }).filter { $0.value.count > 1 }.keys
        check(duplicates.isEmpty, "no component is in the table twice (\(duplicates.sorted()))", &ok)
        let missing = declared.subtracting(tabled).sorted()
        check(missing.isEmpty,
              "every kit type has a table entry in HelmKitVersion.swift (missing: \(missing))", &ok)
        let stale = Set(tabled).subtracting(declared).sorted()
        check(stale.isEmpty,
              "every table entry still names a type in its file (stale: \(stale))", &ok)
        for surface in HelmKit.surfaces {
            check(FileManager.default.fileExists(atPath: dir.appendingPathComponent(surface.file).path),
                  "surface \(surface.name)'s file \(surface.file) exists", &ok)
        }
    }

    // MARK: - Versions

    static func parse(_ version: String) -> (Int, Int, Int)? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let a = parts[0], let b = parts[1], let c = parts[2] else { return nil }
        return (a, b, c)
    }

    private static func checkVersionsAreSemver(_ ok: inout Bool) {
        let bad = (HelmKit.components + HelmKit.surfaces).filter { parse($0.version) == nil }.map(\.name)
        check(bad.isEmpty, "every component version is major.minor.patch (bad: \(bad))", &ok)
    }

    /// The bump kind a version change describes, or `nil` when it is not a
    /// single semver step (a skipped number, a reset that did not happen).
    static func bumpKind(from: String, to: String) -> String? {
        if from == "none" { return to == "1.0.0" ? "new" : nil }
        if to == "removed" { return parse(from) == nil ? nil : "removed" }
        guard let a = parse(from), let b = parse(to) else { return nil }
        if b == (a.0 + 1, 0, 0) { return "major" }
        if b == (a.0, a.1 + 1, 0) { return "minor" }
        if b == (a.0, a.1, a.2 + 1) { return "patch" }
        return nil
    }

    private static func checkTheBumpClassifier(_ ok: inout Bool) {
        check(bumpKind(from: "1.0.0", to: "1.0.1") == "patch", "classifier: 1.0.0 → 1.0.1 is a patch", &ok)
        check(bumpKind(from: "1.0.3", to: "1.1.0") == "minor", "classifier: 1.0.3 → 1.1.0 is a minor", &ok)
        check(bumpKind(from: "1.4.2", to: "2.0.0") == "major", "classifier: 1.4.2 → 2.0.0 is a major", &ok)
        check(bumpKind(from: "1.0.0", to: "1.2.0") == nil, "classifier: a skipped minor is not a bump", &ok)
        check(bumpKind(from: "1.1.0", to: "1.1.0") == nil, "classifier: no change is not a bump", &ok)
        check(bumpKind(from: "none", to: "1.0.0") == "new", "classifier: none → 1.0.0 is new", &ok)
    }

    // MARK: - Digests

    /// The text a digest is taken over: every line with its `//` comment
    /// removed and its trailing space trimmed, blank lines dropped. The same
    /// line-wise stripping `VendoredPatchesSelfTest` uses, so a reworded comment
    /// is not a release and a changed line of code is.
    static func normalised(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let r = line.range(of: "//") else { return line }
                return line[..<r.lowerBound]
            }
            .map { String($0).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func digest(of source: String) -> String {
        SHA256.hash(data: Data(normalised(source).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A file's components and their versions, as `Name@1.0.0` pairs sorted
    /// by name.
    static func stamp(for file: String, in table: [HelmKit.Component]) -> String {
        table.filter { $0.file == file }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)@\($0.version)" }
            .joined(separator: ",")
    }

    /// The `Component("Name", "1.0.0", file: "File.swift")` entries in a
    /// revision of `HelmKitVersion.swift`, read as text so an older revision
    /// can be compared with this build's table.
    static func parseTable(_ source: String) -> [HelmKit.Component] {
        let pattern = #"Component\("([^"]+)", "([^"]+)", file: "([^"]+)"\)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return re.matches(in: source, range: NSRange(location: 0, length: ns.length)).map {
            HelmKit.Component(ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)),
                              file: ns.substring(with: $0.range(at: 3)))
        }
    }

    private static func checkTheDigestIgnoresCommentsOnly(_ ok: inout Bool) {
        let base = "final class HelmX: NSView {\n    let a = 1\n}\n"
        let reworded = "// a new header\nfinal class HelmX: NSView {   \n\n    let a = 1 // why\n}\n"
        let changed = "final class HelmX: NSView {\n    let a = 2\n}\n"
        check(digest(of: base) == digest(of: reworded), "digest: a comment or blank-line change is not a release", &ok)
        check(digest(of: base) != digest(of: changed), "digest: a changed line of code is a release", &ok)
    }

    /// One kit file on one side of the comparison.
    struct FileState: Equatable {
        let digest: String
        let stamp: String
    }

    /// The problems with a branch's kit changes, empty when every changed
    /// file moved a version and every moved version came with a change. A
    /// file that is new on the branch is skipped: its components are new, and
    /// the table and release-notes checks cover them.
    static func changeProblems(base: [String: FileState], head: [String: FileState]) -> [String] {
        var problems: [String] = []
        for file in head.keys.sorted() {
            guard let now = head[file], let was = base[file] else { continue }
            if now.digest != was.digest && now.stamp == was.stamp {
                problems.append("\(file) changed and none of its components' versions moved (\(now.stamp)). "
                                + "Bump the component you changed in HelmKitVersion.swift and add a release file "
                                + "under docs/design-system/helm-kit-releases/.")
            } else if now.digest == was.digest && now.stamp != was.stamp {
                problems.append("\(file)'s versions moved (\(was.stamp) → \(now.stamp)) but its code did not; "
                                + "a version only moves with a change")
            }
        }
        return problems
    }

    private static func checkTheChangeRuleFires(_ ok: inout Bool) {
        let base = ["HelmA.swift": FileState(digest: "1", stamp: "HelmA@1.0.0"),
                    "HelmB.swift": FileState(digest: "2", stamp: "HelmB@1.0.0"),
                    "HelmC.swift": FileState(digest: "3", stamp: "HelmC@1.0.0")]
        let head = ["HelmA.swift": FileState(digest: "1x", stamp: "HelmA@1.0.0"),
                    "HelmB.swift": FileState(digest: "2", stamp: "HelmB@1.0.1"),
                    "HelmC.swift": FileState(digest: "3x", stamp: "HelmC@1.1.0"),
                    "HelmD.swift": FileState(digest: "4", stamp: "HelmD@1.0.0")]
        let problems = changeProblems(base: base, head: head)
        check(problems.contains { $0.hasPrefix("HelmA.swift changed") }, "change rule: a change with no bump fails", &ok)
        check(problems.contains { $0.hasPrefix("HelmB.swift's versions moved") }, "change rule: a bump with no change fails", &ok)
        check(problems.count == 2, "change rule: a bumped change and a new file pass (\(problems.count) problems)", &ok)
        let table = parseTable(#"Component("HelmA", "1.2.0", file: "HelmA.swift"), Component("HelmB", "2.0.0", file: "HelmB.swift")"#)
        check(stamp(for: "HelmA.swift", in: table) == "HelmA@1.2.0" && table.count == 2,
              "change rule: an older table is read back from its source text", &ok)
    }

    enum Base {
        case revision(String)
        case skip(String)
        case failure(String)
    }

    static func git(_ repo: URL, _ arguments: [String]) -> SubprocessResult {
        Subprocess.run(executable: "/usr/bin/git", arguments: ["-C", repo.path] + arguments, timeout: 30)
    }

    /// The revision the working tree is compared with. CI names it; a local
    /// run falls back to the merge base with `origin/main`.
    static func resolveBase(_ repo: URL) -> Base {
        let named = (ProcessInfo.processInfo.environment["FM_HELM_KIT_BASE"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty {
            let r = git(repo, ["rev-parse", "--verify", "--quiet", named + "^{commit}"])
            guard r.ok, !r.stdout.isEmpty else {
                return .failure("FM_HELM_KIT_BASE=\(named) does not name a commit in this checkout")
            }
            return .revision(r.stdout)
        }
        let r = git(repo, ["merge-base", "HEAD", "origin/main"])
        guard r.ok, !r.stdout.isEmpty else {
            return .skip("no FM_HELM_KIT_BASE and no merge base with origin/main")
        }
        return .revision(r.stdout)
    }

    private static func checkAgainstTheBase(_ dir: URL, _ kitFiles: [String], _ ok: inout Bool) {
        let repo = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourcePath = "native/Sources/GrandLine/"
        let base: String
        switch resolveBase(repo) {
        case .failure(let why):
            fail(why, &ok)
            return
        case .skip(let why):
            print("  SKIP: the change rule against a base revision - \(why)")
            return
        case .revision(let sha):
            base = sha
        }
        let listing = git(repo, ["ls-tree", "--name-only", base, sourcePath])
        guard listing.ok else {
            fail("could not list the kit files at \(base): \(listing.stderr)", &ok)
            return
        }
        let baseNames = listing.stdout.split(separator: "\n").map { String($0.split(separator: "/").last ?? "") }
        let baseKitFiles = Self.kitFiles(among: baseNames)
        let tableSource = git(repo, ["show", "\(base):\(sourcePath)HelmKitVersion.swift"])
        guard tableSource.ok else {
            fail("could not read HelmKitVersion.swift at \(base)", &ok)
            return
        }
        let baseTable = parseTable(String(decoding: tableSource.stdoutData, as: UTF8.self))
        check(!baseTable.isEmpty, "read the base revision's table (\(baseTable.count) entries)", &ok)
        var baseStates: [String: FileState] = [:]
        for file in baseKitFiles {
            let shown = git(repo, ["show", "\(base):\(sourcePath)\(file)"])
            guard shown.ok else {
                fail("could not read \(file) at \(base)", &ok)
                continue
            }
            baseStates[file] = FileState(digest: digest(of: String(decoding: shown.stdoutData, as: UTF8.self)),
                                         stamp: stamp(for: file, in: baseTable))
        }
        var headStates: [String: FileState] = [:]
        for file in kitFiles {
            guard let source = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { continue }
            headStates[file] = FileState(digest: digest(of: source), stamp: stamp(for: file, in: HelmKit.components))
        }
        let changed = headStates.filter { file, now in baseStates[file] != now }.keys.sorted()
        print("  compared \(headStates.count) kit files with \(base.prefix(10)): changed or new \(changed)")
        let problems = changeProblems(base: baseStates, head: headStates)
        check(problems.isEmpty, "every changed kit file moved a version: \(problems)", &ok)
    }

    // MARK: - Release notes

    struct Bump {
        let name: String
        let from: String
        let to: String
        let kind: String
        let text: String
    }

    struct Release {
        let title: String
        var bumps: [Bump] = []
    }

    static let bulletPattern = #"^- `([^`]+)` (\S+) → (\S+) \(([a-z]+)\)(.*)$"#

    /// The frozen history: one `## x.y.z` section per kit release up to 10.4.0.
    static func parseHistory(_ text: String) -> [Release] {
        parse(text, heading: #"^## (\d+\.\d+\.\d+)\b"#)
    }

    /// One release file: a `# YYYY-MM-DD - title` heading and its bullets.
    static func parseReleaseFile(_ text: String) -> Release? {
        let releases = parse(text, heading: #"^# (\d{4}-\d{2}-\d{2}) - "#)
        return releases.count == 1 ? releases[0] : nil
    }

    private static func parse(_ text: String, heading pattern: String) -> [Release] {
        var releases: [Release] = []
        let heading = try? NSRegularExpression(pattern: pattern)
        let bullet = try? NSRegularExpression(pattern: bulletPattern)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = heading?.firstMatch(in: line, range: range) {
                releases.append(Release(title: ns.substring(with: m.range(at: 1))))
            } else if let m = bullet?.firstMatch(in: line, range: range), !releases.isEmpty {
                releases[releases.count - 1].bumps.append(Bump(name: ns.substring(with: m.range(at: 1)),
                                                               from: ns.substring(with: m.range(at: 2)),
                                                               to: ns.substring(with: m.range(at: 3)),
                                                               kind: ns.substring(with: m.range(at: 4)),
                                                               text: ns.substring(with: m.range(at: 5))))
            }
        }
        return releases
    }

    static let releaseFileName = #"^(\d{4}-\d{2}-\d{2})-[a-z0-9]+(-[a-z0-9]+)*\.md$"#

    /// The problems with the release notes against a table, empty when they
    /// agree. `files` maps a release file's name to its text. A function of
    /// its inputs so the fixture check below can prove each rule fires.
    static func releaseProblems(history: [Release], files: [String: String],
                                table: [HelmKit.Component]) -> [String] {
        var problems: [String] = []
        if history.last?.title != "1.0.0" {
            problems.append("the history does not end at the 1.0.0 baseline")
        }
        var all: [(String, Bump)] = history.flatMap { r in r.bumps.map { (r.title, $0) } }
        let nameRule = try? NSRegularExpression(pattern: releaseFileName)
        for (file, text) in files.sorted(by: { $0.key < $1.key }) {
            let ns = file as NSString
            guard let m = nameRule?.firstMatch(in: file, range: NSRange(location: 0, length: ns.length)) else {
                problems.append("\(file) is not named YYYY-MM-DD-<slug>.md")
                continue
            }
            guard let release = parseReleaseFile(text) else {
                problems.append("\(file) does not open with one `# YYYY-MM-DD - title` heading")
                continue
            }
            if release.title != ns.substring(with: m.range(at: 1)) {
                problems.append("\(file)'s heading is dated \(release.title)")
            }
            if release.bumps.isEmpty {
                problems.append("\(file) lists no component bump")
            }
            for b in release.bumps where b.kind == "major" {
                let words = b.text.lowercased()
                if !words.contains("removed") && !words.contains("renamed") {
                    problems.append("\(file): `\(b.name)` is a major bump that does not say which API was removed or renamed")
                }
            }
            all += release.bumps.map { (file, $0) }
        }
        for (where_, b) in all where bumpKind(from: b.from, to: b.to) != b.kind {
            problems.append("\(where_): `\(b.name)` \(b.from) → \(b.to) is written as \(b.kind)")
        }
        // The version a name ends on is the one no later line moves past.
        // Order-free, so two releases on one day need no ordering rule.
        var froms: [String: Set<String>] = [:]
        var tos: [String: Set<String>] = [:]
        for (_, b) in all {
            froms[b.name, default: []].insert(b.from)
            tos[b.name, default: []].insert(b.to)
        }
        let tabled = Dictionary(table.map { ($0.name, $0.version) }, uniquingKeysWith: { a, _ in a })
        for name in Set(tos.keys).union(tabled.keys).sorted() {
            let ends = (tos[name] ?? []).subtracting(froms[name] ?? [])
            let version = tabled[name]
            if ends.isEmpty {
                if let version, version != "1.0.0" {
                    problems.append("`\(name)` is \(version) in the table but the release notes say nothing")
                }
                continue
            }
            if ends.count > 1 {
                problems.append("`\(name)` ends on more than one version in the release notes (\(ends.sorted()))")
            } else if let end = ends.first {
                if end == "removed" {
                    if version != nil { problems.append("`\(name)` is written as removed but is still in the table") }
                } else if end != version {
                    problems.append("`\(name)` is \(version ?? "missing") in the table but the release notes say \(end)")
                }
            }
        }
        return problems
    }

    private static func checkTheReleaseRulesFire(_ ok: inout Bool) {
        let history = parseHistory("""
        ## 1.1.0 - fixture
        - `HelmA` 1.0.0 → 1.0.1 (minor): mislabelled.
        ## 1.0.0 - baseline
        """)
        let files = [
            "2026-11-26-good.md": "# 2026-11-26 - good\n\n- `HelmB` 1.0.0 → 1.1.0 (minor): an option.\n",
            "2026-11-26-also.md": "# 2026-11-26 - also\n\n- `HelmB` 1.1.0 → 1.2.0 (minor): another, same day.\n",
            "2026-11-27-major.md": "# 2026-11-27 - major\n\n- `HelmC` 1.0.0 → 2.0.0 (major): looks different.\n",
            "2026-11-28-dated.md": "# 2026-11-29 - wrong date\n\n- `HelmD` 1.0.0 → 1.0.1 (patch): a fix.\n",
            "notes.md": "# 2026-11-30 - misnamed\n",
        ]
        let table = [HelmKit.Component("HelmA", "1.0.2", file: "HelmA.swift"),
                     HelmKit.Component("HelmB", "1.2.0", file: "HelmA.swift"),
                     HelmKit.Component("HelmC", "2.0.0", file: "HelmA.swift"),
                     HelmKit.Component("HelmD", "1.0.1", file: "HelmA.swift"),
                     HelmKit.Component("HelmE", "1.3.0", file: "HelmA.swift")]
        let problems = releaseProblems(history: history, files: files, table: table)
        check(problems.contains { $0.contains("written as minor") }, "release notes: a mislabelled bump fails", &ok)
        check(problems.contains { $0.contains("`HelmA` is 1.0.2") }, "release notes: a version the notes do not reach fails", &ok)
        check(problems.contains { $0.contains("`HelmE` is 1.3.0") }, "release notes: a version with no line fails", &ok)
        check(problems.contains { $0.contains("removed or renamed") }, "release notes: a major that names no removal fails", &ok)
        check(problems.contains { $0.contains("dated 2026-11-29") }, "release notes: a heading dated off its file name fails", &ok)
        check(problems.contains { $0.contains("notes.md is not named") }, "release notes: a misnamed release file fails", &ok)
        check(!problems.contains { $0.contains("`HelmB`") }, "release notes: two releases on one day chain in either order", &ok)
        check(!problems.contains { $0.contains("`HelmD`") && !$0.contains("dated") },
              "release notes: a well-formed patch passes", &ok)
    }

    private static func checkTheReleaseNotes(_ dir: URL, _ ok: inout Bool) {
        let repo = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let historyURL = repo.appendingPathComponent("docs/design-system/helm-kit-versions.md")
        let releasesURL = repo.appendingPathComponent("docs/design-system/helm-kit-releases")
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else {
            fail("could not read \(historyURL.path)", &ok)
            return
        }
        let history = parseHistory(text)
        check(history.first?.title == "10.4.0",
              "the frozen history ends at 10.4.0, the last kit-wide number (\(history.first?.title ?? "none"))", &ok)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: releasesURL.path).filter { $0.hasSuffix(".md") }
        } catch {
            fail("could not list \(releasesURL.path): \(error)", &ok)
            return
        }
        var files: [String: String] = [:]
        for name in names where name != "README.md" {
            guard let body = try? String(contentsOf: releasesURL.appendingPathComponent(name), encoding: .utf8) else {
                fail("could not read release file \(name)", &ok)
                continue
            }
            files[name] = body
        }
        let newest = files.keys.sorted().last.map { String($0.prefix(10)) } ?? "none"
        print("  the kit is Helm \(newest) (\(files.count) release files)")
        let problems = releaseProblems(history: history, files: files, table: HelmKit.components + HelmKit.surfaces)
        check(problems.isEmpty, "the release notes agree with the table: \(problems)", &ok)
    }
}

#endif
