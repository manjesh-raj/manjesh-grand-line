// Grand Line - native macOS app.
//
// The source guards for the second full review's security findings
// (R2-SEC-01 to R2-SEC-12): the places where a secret or the captain's data
// could cross a boundary - the pasteboard, the network, a log line, a git
// push, a URL handed to another app - and the one shared path each of them
// must take.
//
// Each finding's *behaviour* is asserted in the suite for its own area (the
// Log Analyzer's clipboard actions in `LogAnalyzerSelfTest`, the network gate
// in `NetworkGateSelfTest`, the vault's KDF bounds in `CredentialVaultSelfTest`
// and so on). What lives here is the other half AGENTS.md's verification
// conventions ask for: a guard that fails when a *new* call site skips the
// shared path, which no behavioural check of the existing sites can see.
//
// Every guard reads the app's own sources through `SelfTestSources` and fails
// loudly when it cannot, because a guard that cannot read its subject passes
// vacuously.
//
// Run with:
//   swift build && FM_RUN_SECRET_BOUNDARIES_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: source text only, no window.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum SecretBoundariesSelfTest {

    static func run() -> Bool {
        var ok = true
        guard let sources = ProductionSources.load() else {
            fail("could not read the app's sources - every guard below would pass vacuously", &ok)
            return false
        }
        checkEveryPasteboardReadAsksIsConcealedFirst(sources, &ok)
        checkEverySyncedCommitIsScanned(sources, &ok)
        checkAMisspeltSuiteFlagNeverReachesTheApp(&ok)
        print(ok ? "SecretBoundariesSelfTest: all checks passed" : "SecretBoundariesSelfTest: FAILED")
        return ok
    }

    // MARK: R2-SEC-03 - the pasteboard

    /// Files allowed to read the pasteboard's string without asking
    /// `isConcealed`, each with the reason. Per file, deliberately not a
    /// pattern, so a new reader has to be argued for here.
    static let pasteboardReadExemptions: [String: String] = [
        // The terminal's own ⌘V. It only asks whether there is text, then
        // hands the paste to the shell the captain is typing into - which is
        // exactly where a copied vault secret is meant to go. Nothing is
        // stored or sent anywhere else.
        "CockpitTerminalView.swift": "the terminal's own paste",
    ]

    /// AGENTS.md: `CredentialVaultClipboard.isConcealed(_:)` is the one
    /// definition of "a secret is on the pasteboard", and every reader asks it
    /// **before** reading the string. The Log Analyzer was a fifth reader that
    /// did not, and its evidence is persisted and sent to `claude -p`.
    ///
    /// Wider than the report's literal `NSPasteboard.general.string(`: any
    /// `.string(forType: .string)` read in production, so a reader that names
    /// its board through a local or a parameter is covered too.
    private static func checkEveryPasteboardReadAsksIsConcealedFirst(_ sources: ProductionSources, _ ok: inout Bool) {
        print("\n-- R2-SEC-03: every pasteboard string read asks isConcealed first --")
        var readers = 0
        for file in sources.files {
            let lines = file.codeLines
            for (index, line) in lines.enumerated() where line.contains(".string(forType: .string)") {
                if pasteboardReadExemptions[file.name] != nil { continue }
                readers += 1
                let body = ProductionSources.enclosingFunction(lines, upTo: index)
                let read = line.range(of: ".string(forType: .string)")!.lowerBound
                let asked = body.dropLast().contains { $0.contains("CredentialVaultClipboard.isConcealed(") }
                    || line[..<read].contains("CredentialVaultClipboard.isConcealed(")
                check(asked,
                      "R2-SEC-03: \(file.name):\(index + 1) reads the pasteboard's string without asking "
                      + "CredentialVaultClipboard.isConcealed first", &ok)
            }
        }
        check(readers >= 6, "fixture: found only \(readers) pasteboard readers - the scan is not seeing the app", &ok)
        if ok { print("  OK   \(readers) readers, each asks isConcealed before reading") }
    }
}

extension SecretBoundariesSelfTest {

    // MARK: R2-SEC-04 - every synced commit is scanned

    /// Synced stores whose commit path is not scanned, each with the reason.
    static let unscannedSyncedStores: [String: String] = [
        // The vault file is AES-GCM ciphertext: there is nothing readable to
        // scan, and a chance `AKIA`-shaped run in the base64 would hold the
        // vault's sync for no reason.
        "CredentialVaultSync.swift": "sealed ciphertext",
    ]

    /// Every `commitAndPushNow` runs `DotfilesSecretScan.scan` over its dirty
    /// files before `git add`, as the dotfiles sync already did.
    static func checkEverySyncedCommitIsScanned(_ sources: ProductionSources, _ ok: inout Bool) {
        print("\n-- R2-SEC-04: every synced store scans its dirty files before git add --")
        var scanned = 0
        for file in sources.files where unscannedSyncedStores[file.name] == nil {
            let lines = file.codeLines
            guard let start = lines.firstIndex(where: { $0.contains("func commitAndPushNow()") }) else { continue }
            guard let add = lines[start...].firstIndex(where: { $0.contains("\"add\", \"-A\"") }) else {
                fail("\(file.name): commitAndPushNow has no git add - the guard cannot place the scan", &ok)
                continue
            }
            let scan = lines[start..<add].firstIndex(where: { $0.contains("DotfilesSecretScan.scan(") })
            check(scan != nil, "R2-SEC-04: \(file.name)'s commitAndPushNow stages files before scanning them", &ok)
            scanned += 1
        }
        check(scanned >= 6, "fixture: found \(scanned) synced stores - the scan is not seeing the app", &ok)
        check(!sources.files.contains { $0.text.contains("func containsLikelySecret") },
              "R2-SEC-04: LogRedactor.containsLikelySecret is back with no caller", &ok)
        if ok { print("  OK   \(scanned) synced stores scan before staging") }
    }
}

extension SecretBoundariesSelfTest {

    // MARK: R2-SEC-09 - a misspelt suite flag exits 2

    /// Asserted on the pure predicate and on `main.swift`'s text, never by
    /// starting a process: with the fix reverted, such a process would
    /// activate the captain's running app.
    static func checkAMisspeltSuiteFlagNeverReachesTheApp(_ ok: inout Bool) {
        print("\n-- R2-SEC-09: any FM_RUN_ key that no suite answered exits 2 --")
        for flag in [["FM_RUN_CONTRAST": "1"], ["FM_RUN_CONTRAST_TESTS": "yes"], ["FM_RUN_CONTRAST_TESTS": "0"],
                     ["FM_RUN_CONTRAST_TEST": "1"], ["FM_RUN_X": ""], ["FM_RUN_CONTRAST_TESTS": "1"]] {
            check(SelfTestFlags.unknownSuiteFlags(in: flag.merging(["PATH": "/usr/bin", "FM_HOME": "/tmp"]) { a, _ in a })
                  == Array(flag.keys),
                  "R2-SEC-09: \(flag) reaching the end of the suite blocks is not treated as unknown", &ok)
        }
        check(SelfTestFlags.unknownSuiteFlags(in: ["PATH": "/usr/bin", "FM_REVIEW_TOUR": "/tmp/t.txt",
                                                   "FM_SHIFT_DIR": "/tmp/s"]).isEmpty,
              "R2-SEC-09: an ordinary launch environment reads as an unknown suite flag", &ok)

        guard let dir = SelfTestSources.appSourceDirectory(),
              let main = try? String(contentsOf: dir.appendingPathComponent("main.swift"), encoding: .utf8),
              let check2 = main.range(of: "SelfTestFlags.unknownSuiteFlags(in: ProcessInfo.processInfo.environment)"),
              let exit2 = main.range(of: "exit(2)", range: check2.upperBound..<main.endIndex),
              let acquire = main.range(of: "switch SingleInstanceGuard.acquire()") else {
            return fail("R2-SEC-09: main.swift no longer asks SelfTestFlags.unknownSuiteFlags before exit(2)", &ok)
        }
        check(exit2.upperBound < acquire.lowerBound,
              "R2-SEC-09: the unknown-flag exit sits after SingleInstanceGuard.acquire()", &ok)
        if ok { print("  OK   every FM_RUN_ key is unknown at the end of the blocks, and exits before the instance guard") }
    }
}

/// The app's production sources with comments stripped, read once.
struct ProductionSources {
    struct File {
        let name: String
        let text: String
        /// Each line with its `//` comment removed, so a guard matches code
        /// and never the comment that names what it is looking for.
        let codeLines: [String]
    }

    let files: [File]

    static func load() -> ProductionSources? {
        guard let urls = SelfTestSources.appSourceFiles(), urls.count > 50 else { return nil }
        var files: [File] = []
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let code = text.components(separatedBy: "\n").map(stripComment)
            files.append(File(name: url.lastPathComponent, text: text, codeLines: code))
        }
        return ProductionSources(files: files)
    }

    func file(_ name: String) -> File? { files.first { $0.name == name } }

    /// A line without its trailing `//` comment. A `//` inside a string
    /// literal (a URL) is kept: the cut is at the first `//` outside quotes.
    static func stripComment(_ line: String) -> String {
        var inString = false
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\"" && previous != "\\" { inString.toggle() }
            if !inString, char == "/", previous == "/" {
                return String(line[..<line.index(before: index)])
            }
            previous = char
            index = line.index(after: index)
        }
        return line
    }

    /// The lines from the nearest `func` or `init` declaration above `index`
    /// down to and including `index`.
    static func enclosingFunction(_ lines: [String], upTo index: Int) -> ArraySlice<String> {
        var start = index
        while start > 0 {
            let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"(^|\s)(func\s|init\(|init\?\()"#, options: .regularExpression) != nil { break }
            start -= 1
        }
        return lines[start...index]
    }
}

#endif
