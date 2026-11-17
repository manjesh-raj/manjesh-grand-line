// Grand Line - native macOS app.
//
// S01 of the 2026-11-17 UI/UX proposals: the guard that makes
// `HelmKit.version` mean something. `HelmKitVersion.swift`'s header has the
// model and the bump rule; this suite enforces it.
//
// Run with `FM_RUN_HELM_KIT_VERSION_TESTS=1 .build/debug/GrandLine`.
//
// Pure source reads and hashing - no window, no session. Deliberately NOT in
// `NEEDS_SESSION`, so it guards CI's blocking lane.
//
// What it checks:
//
//   1. Every top-level type in a kit file has a table entry, and every entry
//      still names a type in its file.
//   2. Every version is `major.minor.patch`.
//   3. Every kit file's digest matches the recorded one. When it does not, the
//      failure says whether a version has moved yet: if none of the file's
//      components moved, it asks for a bump and prints no digest, so the
//      table cannot be re-recorded without one.
//   4. The release notes (`docs/design-system/helm-kit-versions.md`) open with
//      `HelmKit.version`, carry a line for every component and surface that is
//      past 1.0.0, write the bump kind the numbers actually describe, and move
//      the kit version by the largest bump of each release.
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
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not next to this binary")
            return ok
        }
        let kitFiles = kitFileNames(in: dir)
        check(kitFiles.count >= 30, "found the kit's files (\(kitFiles.count))", &ok)
        checkEveryKitTypeIsInTheTable(dir, kitFiles, &ok)
        checkTheSourceDigests(dir, kitFiles, &ok)
        checkTheReleaseNotes(dir, &ok)
        print(ok ? "HelmKitVersionSelfTest: OK" : "HelmKitVersionSelfTest: FAILED")
        return ok
    }

    // MARK: - The kit's files and types

    /// Every `Helm*.swift` in the app's directory except the table itself,
    /// which changes with every release and would otherwise guard its own
    /// digests.
    static func kitFileNames(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix("Helm") && $0.hasSuffix(".swift") && $0 != "HelmKitVersion.swift" }
            .sorted()
    }

    /// Top-level `Helm*` types declared in one file's source.
    static func declaredTypes(in source: String) -> [String] {
        let pattern = #"^(?:final |public )?(?:class|enum|struct|protocol) (Helm[A-Za-z0-9]+)"#
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
        check(parse(HelmKit.version) != nil, "HelmKit.version \(HelmKit.version) is major.minor.patch", &ok)
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

    /// How a release's own bumps move the kit version: a new component is a
    /// minor release, a removal a major one.
    static func kitRank(_ kind: String) -> Int {
        switch kind {
        case "major", "removed": return 3
        case "minor", "new": return 2
        case "patch": return 1
        default: return 0
        }
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

    static func stamp(for file: String) -> String {
        HelmKit.components.filter { $0.file == file }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)@\($0.version)" }
            .joined(separator: ",")
    }

    private static func checkTheDigestIgnoresCommentsOnly(_ ok: inout Bool) {
        let base = "final class HelmX: NSView {\n    let a = 1\n}\n"
        let reworded = "// a new header\nfinal class HelmX: NSView {   \n\n    let a = 1 // why\n}\n"
        let changed = "final class HelmX: NSView {\n    let a = 2\n}\n"
        check(digest(of: base) == digest(of: reworded), "digest: a comment or blank-line change is not a release", &ok)
        check(digest(of: base) != digest(of: changed), "digest: a changed line of code is a release", &ok)
    }

    private static func checkTheSourceDigests(_ dir: URL, _ kitFiles: [String], _ ok: inout Bool) {
        let recorded = Dictionary(HelmKit.sourceDigests.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        check(recorded.count == HelmKit.sourceDigests.count, "each kit file has one recorded digest", &ok)
        for file in kitFiles {
            guard let source = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { continue }
            let sha = digest(of: source)
            let currentStamp = stamp(for: file)
            guard let entry = recorded[file] else {
                fail("\(file) has no recorded digest; add SourceDigest(file: \"\(file)\", stamp: \"\(currentStamp)\", sha256: \"\(sha)\")", &ok)
                continue
            }
            if entry.sha256 == sha && entry.stamp == currentStamp {
                continue
            }
            if entry.stamp == currentStamp {
                fail("\(file) changed since it was recorded at \(entry.stamp), and none of its components' versions moved. "
                     + "Bump the component you changed in HelmKitVersion.swift, move HelmKit.version, add the "
                     + "release-notes lines, and run this suite again for the digest to record.", &ok)
            } else if entry.sha256 == sha {
                fail("\(file)'s versions moved (\(entry.stamp) → \(currentStamp)) but its code did not; "
                     + "a version only moves with a change", &ok)
            } else {
                fail("\(file) changed and its versions moved; record SourceDigest(file: \"\(file)\", "
                     + "stamp: \"\(currentStamp)\", sha256: \"\(sha)\")", &ok)
            }
        }
        let gone = Set(recorded.keys).subtracting(kitFiles).sorted()
        check(gone.isEmpty, "every recorded digest names a kit file that exists (gone: \(gone))", &ok)
        check(!HelmKit.sourceDigests.isEmpty && Set(recorded.keys) == Set(kitFiles),
              "every kit file is covered (\(recorded.count) of \(kitFiles.count))", &ok)
    }

    // MARK: - Release notes

    struct Release {
        let version: String
        var bumps: [(name: String, from: String, to: String, kind: String)] = []
    }

    static func parseReleaseNotes(_ text: String) -> [Release] {
        var releases: [Release] = []
        let heading = try? NSRegularExpression(pattern: #"^## (\d+\.\d+\.\d+)\b"#)
        let bullet = try? NSRegularExpression(pattern: #"^- `([^`]+)` (\S+) → (\S+) \(([a-z]+)\)"#)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = heading?.firstMatch(in: line, range: range) {
                releases.append(Release(version: ns.substring(with: m.range(at: 1))))
            } else if let m = bullet?.firstMatch(in: line, range: range), !releases.isEmpty {
                releases[releases.count - 1].bumps.append((ns.substring(with: m.range(at: 1)),
                                                           ns.substring(with: m.range(at: 2)),
                                                           ns.substring(with: m.range(at: 3)),
                                                           ns.substring(with: m.range(at: 4))))
            }
        }
        return releases
    }

    /// The problems with a set of release notes against a table, empty when
    /// they agree. A function of its inputs so the fixture check below can
    /// prove each rule fires.
    static func releaseNoteProblems(_ releases: [Release], kitVersion: String,
                                    table: [HelmKit.Component]) -> [String] {
        var problems: [String] = []
        guard let newest = releases.first else { return ["the release notes have no `## x.y.z` heading"] }
        if newest.version != kitVersion {
            problems.append("the newest release is \(newest.version) but HelmKit.version is \(kitVersion)")
        }
        if releases.last?.version != "1.0.0" {
            problems.append("the oldest release is not the 1.0.0 baseline")
        }
        for release in releases {
            for b in release.bumps where bumpKind(from: b.from, to: b.to) != b.kind {
                problems.append("\(release.version): `\(b.name)` \(b.from) → \(b.to) is written as \(b.kind)")
            }
        }
        // Oldest first, so each release is compared with the one before it.
        let ordered = Array(releases.reversed())
        for (older, newer) in zip(ordered, ordered.dropFirst()) {
            let largest = newer.bumps.map { kitRank(bumpKind(from: $0.from, to: $0.to) ?? $0.kind) }.max() ?? 0
            let kitStep = bumpKind(from: older.version, to: newer.version).map(kitRank) ?? -1
            if largest == 0 {
                problems.append("\(newer.version) lists no component bump")
            } else if kitStep != largest {
                problems.append("\(older.version) → \(newer.version) does not match its largest bump")
            }
        }
        // Newest line per name wins.
        var latest: [String: String] = [:]
        for release in ordered {
            for b in release.bumps { latest[b.name] = b.to }
        }
        for c in table where c.version != "1.0.0" {
            if latest[c.name] != c.version {
                problems.append("`\(c.name)` is \(c.version) in the table but the release notes say \(latest[c.name] ?? "nothing")")
            }
        }
        let tabled = Set(table.map(\.name))
        for (name, to) in latest where to == "removed" && tabled.contains(name) {
            problems.append("`\(name)` is written as removed but is still in the table")
        }
        return problems
    }

    private static func checkTheReleaseNotes(_ dir: URL, _ ok: inout Bool) {
        let fixture = """
        ## 1.1.0 - fixture
        - `HelmA` 1.0.0 → 1.0.1 (minor)
        ## 1.0.0 - baseline
        """
        let fixtureTable = [HelmKit.Component("HelmA", "1.0.2", file: "HelmA.swift")]
        let fixtureProblems = releaseNoteProblems(parseReleaseNotes(fixture), kitVersion: "1.2.0", table: fixtureTable)
        check(fixtureProblems.contains { $0.contains("HelmKit.version") }, "release notes: a stale kit version fails", &ok)
        check(fixtureProblems.contains { $0.contains("written as minor") }, "release notes: a mislabelled bump fails", &ok)
        check(fixtureProblems.contains { $0.contains("largest bump") }, "release notes: a kit step that disagrees fails", &ok)
        check(fixtureProblems.contains { $0.contains("in the table") }, "release notes: a version with no line fails", &ok)

        let repo = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let notes = repo.appendingPathComponent("docs/design-system/helm-kit-versions.md")
        guard let text = try? String(contentsOf: notes, encoding: .utf8) else {
            fail("could not read \(notes.path)", &ok)
            return
        }
        let releases = parseReleaseNotes(text)
        check(!releases.isEmpty, "the release notes have at least the baseline (\(releases.map(\.version)))", &ok)
        let problems = releaseNoteProblems(releases, kitVersion: HelmKit.version,
                                           table: HelmKit.components + HelmKit.surfaces)
        check(problems.isEmpty, "the release notes agree with the table: \(problems)", &ok)
    }
}

#endif
