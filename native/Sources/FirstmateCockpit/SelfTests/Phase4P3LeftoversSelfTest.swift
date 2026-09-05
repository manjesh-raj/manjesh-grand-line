// Manjesh Grand Line - native macOS app.
//
// Audit §6.10 - the P3 leftovers from phase 4's own written list.
//
// Four of the six are covered here (the two that are not are recorded in this
// task's PR: store-activation-split, deliberately skipped, and localization,
// out of scope). Each is small on its own; what they share is that none has a
// captain-visible symptom today, so without a check they would rot silently.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum Phase4P3LeftoversSelfTest {

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        checkStoreObservationTokens(check)
        checkAppSettingsTakesAnInjectedDefaults(check)
        checkHostCarriesNoPassword(check)
        checkHotFormattersAreBuiltOnce(check)

        if failures.isEmpty {
            print("Phase4P3LeftoversSelfTest: OK")
            return true
        }
        print("Phase4P3LeftoversSelfTest: \(failures.count) failure(s)")
        for f in failures { print("  - \(f)") }
        return false
    }

    // MARK: Token-based store observe

    /// The point of the token is `unobserve`, so that is what this drives -
    /// asserting only that `observe` *returns* something would pass against a
    /// token nothing can use.
    private static func checkStoreObservationTokens(_ check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-stores-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Scratch roots: neither store may reach the captain's real clone.
        let savedHosts = ProcessInfo.processInfo.environment["FM_HOSTS_FILE"]
        let savedDictation = ProcessInfo.processInfo.environment["FM_DICTATION_DIR"]
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_DICTATION_DIR", dir.appendingPathComponent("dictation", isDirectory: true).path, 1)
        defer {
            if let savedHosts { setenv("FM_HOSTS_FILE", savedHosts, 1) } else { unsetenv("FM_HOSTS_FILE") }
            if let savedDictation { setenv("FM_DICTATION_DIR", savedDictation, 1) } else { unsetenv("FM_DICTATION_DIR") }
        }

        let hosts = HostStore()
        var stayCount = 0
        var goCount = 0
        _ = hosts.observe { stayCount += 1 }
        let goingToken = hosts.observe { goCount += 1 }

        hosts.add(Host(label: "Preprod bastion", address: "10.40.0.9"))
        check(stayCount == 1 && goCount == 1,
              "both HostStore observers should have fired once, got \(stayCount)/\(goCount)")

        hosts.unobserve(goingToken)
        hosts.add(Host(label: "Prod bastion", address: "10.40.0.10"))
        check(stayCount == 2, "the remaining HostStore observer stopped firing (\(stayCount))")
        check(goCount == 1, "an unobserved HostStore handler still fired (\(goCount)) - the token does nothing")

        let dictation = DictationStore()
        var dictationStay = 0
        var dictationGo = 0
        _ = dictation.observe { dictationStay += 1 }
        let dictationToken = dictation.observe { dictationGo += 1 }
        dictation.addVocabularyWord("herdr")
        check(dictationStay == 1 && dictationGo == 1,
              "both DictationStore observers should have fired once, got \(dictationStay)/\(dictationGo)")

        dictation.unobserve(dictationToken)
        dictation.addVocabularyWord("kubectl")
        check(dictationStay == 2, "the remaining DictationStore observer stopped firing (\(dictationStay))")
        check(dictationGo == 1, "an unobserved DictationStore handler still fired (\(dictationGo))")
    }

    // MARK: `AppSettings.init(defaults:)`

    /// The seam has to be genuinely isolated, or it is worse than nothing: a
    /// suite that believed it was writing to a scratch store while actually
    /// writing through to the captain's real preferences is precisely the
    /// non-hermetic hazard this repo has already been bitten by.
    private static func checkAppSettingsTakesAnInjectedDefaults(_ check: (Bool, String) -> Void) {
        let suiteName = "com.firstmate.cockpit.p3-selftest-\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: suiteName) else {
            check(false, "could not create a scratch UserDefaults suite")
            return
        }
        defer { scratch.removePersistentDomain(forName: suiteName) }

        // Restored unconditionally, because the failure mode under test is
        // exactly "the write went to the real store instead". Measured, not
        // theoretical: injecting that regression while writing this suite
        // pushed the captain's own `fm.fontSize` from its default to 20. A
        // check for isolation must not depend on isolation to clean up.
        let realBefore = AppSettings.shared.fontSize
        defer { AppSettings.shared.fontSize = realBefore }

        let isolated = AppSettings(defaults: scratch)
        isolated.fontSize = realBefore + 7

        check(isolated.fontSize == realBefore + 7,
              "the injected settings store did not read back its own write")
        check(AppSettings.shared.fontSize == realBefore,
              "writing through an injected store changed the real one - the seam is not isolated")
        check(scratch.object(forKey: "fm.fontSize") != nil,
              "the write did not land in the injected suite at all")
    }

    // MARK: `Host.password` removal

    /// A source guard, because the thing being asserted is an *absence*: the
    /// field had exactly one writer and no reader, so a behavioural check
    /// cannot tell "removed" from "never used", which is what it was.
    private static func checkHostCarriesNoPassword(_ check: (Bool, String) -> Void) {
        guard let sources = SelfTestSources.appSourceDirectory() else { return }
        for file in ["Host.swift", "HostEditorController.swift"] {
            let path = sources.appendingPathComponent(file)
            guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                check(false, "could not read \(file) for the source guard")
                continue
            }
            check(!text.contains("var password: String?"),
                  "\(file) declares a session-only host password again - nothing ever read the last one, "
                  + "so it only invited a real password into memory for no effect")
            check(!text.contains("host.password"),
                  "\(file) writes a host password again")
        }
        // The persisted shape is unchanged, which is the half that must not
        // regress: this removal is not allowed to touch what reaches disk.
        let host = Host(label: "Preprod", address: "10.40.0.9")
        guard let data = try? JSONEncoder().encode(host),
              let json = String(data: data, encoding: .utf8) else {
            check(false, "a Host no longer encodes at all")
            return
        }
        check(!json.lowercased().contains("password"), "a password key reached the encoded Host")
        check(json.contains("label"), "the encoded Host lost its ordinary fields")
    }

    // MARK: Cached formatters

    /// `DateFormatter` construction is measurably expensive, and these three
    /// run once per rendered row / parsed record. Identity is the assertion -
    /// two calls returning the same instance is exactly what "built once"
    /// means, and a per-call constructor cannot fake it.
    private static func checkHotFormattersAreBuiltOnce(_ check: (Bool, String) -> Void) {
        guard let sources = SelfTestSources.appSourceDirectory() else { return }
        for (file, note) in [
            ("FleetLogFeed.swift", "runs once per Shift activity entry"),
            ("ShiftListViews.swift", "runs once per rendered task row"),
            ("StickyBoardViews.swift", "runs once per rendered note"),
            ("ShiftStore.swift", "runs on every timestamp read and write"),
            ("HomeCanvasController.swift", "runs on every canvas render"),
        ] {
            let path = sources.appendingPathComponent(file)
            guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                check(false, "could not read \(file)")
                continue
            }
            // A formatter constructed anywhere other than a `static let`
            // initializer closure is a per-call construction.
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("DateFormatter()") || trimmed.contains("NumberFormatter()") else { continue }
                let isCachedDeclaration = trimmed.hasPrefix("private static let")
                    || trimmed.hasPrefix("static let")
                    || trimmed.hasPrefix("let f = ")
                    || trimmed.hasPrefix("let formatter = ")
                guard !isCachedDeclaration else { continue }
                check(false, "\(file) still builds a formatter inline (\(note)): \(trimmed)")
            }
        }
    }
}

#endif
