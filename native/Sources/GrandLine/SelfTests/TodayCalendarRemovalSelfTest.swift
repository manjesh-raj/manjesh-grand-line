// Grand Line - native macOS app - self-test.
//
// `fm/grandline-remove-today-calendar-1792553365` removed the Today page and
// the calendar integration behind it: the "Today" space pill and its
// destination, the "Nothing is due today" card, the "Captured today" card and
// its capture log, the read-only EventKit path, and the Google sign-in, OAuth
// client and Google Calendar reader that only that page used. This suite is
// what keeps them removed, and what proves the one-time launch cleanup
// deletes what they left on the Mac.
//
// Run with `FM_RUN_TODAY_CALENDAR_REMOVAL_TESTS=1 .build/debug/GrandLine`.
//
// **Pure logic, so it guards CI's blocking lane.** No window is mounted: the
// destination and pill tables are enums, the source guard reads files, and
// the cleanup runs against a scratch defaults domain, this process's own
// prefixed Keychain service names and a scratch directory. The two halves
// that do need a window live where a window already is -
// `SessionRestoreSelfTest.aSavedTodayPageLandsOnHome` and
// `SettingsSidebarNavigationSelfTest.checkNoPageOffersTheRemovedCalendar`.
//
// What it covers:
//
//   1. **The destination table has no Today page**, and a saved raw value
//      for it no longer decodes.
//   2. **The bar has no Today pill** - five pills, Home first, in the order
//      ⌘1-⌘5 index into.
//   3. **No source names the removed pieces**, comments stripped, and neither
//      bundle's Info.plist asks for calendar access.
//   4. **The launch cleanup removes what they left**, leaves everything else
//      alone, and runs once.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Foundation
import Security

enum TodayCalendarRemovalSelfTest {

    static func run() -> Bool {
        var ok = true
        checkTheDestinationTableHasNoTodayPage(&ok)
        checkTheBarHasNoTodayPill(&ok)
        checkNoSourceNamesTheRemovedPieces(&ok)
        checkNeitherBundleAsksForCalendarAccess(&ok)
        checkTheCleanupRemovesWhatTheyLeft(&ok)
        checkTheCleanupRunsOnce(&ok)
        print(ok ? "TodayCalendarRemovalSelfTest: all checks passed"
                 : "TodayCalendarRemovalSelfTest: FAILED")
        return ok
    }

    // MARK: 1. The destination table

    private static func checkTheDestinationTableHasNoTodayPage(_ ok: inout Bool) {
        print("\n-- the destination table has no Today page --")
        // Discriminating power first: the table decodes a page it does have.
        check(RailDestination(rawValue: "homeCanvas") == .homeCanvas,
              "fixture: the table should decode Home by its raw value", &ok)

        check(RailDestination(rawValue: "dailyOverview") == nil,
              "the Today page's raw value still decodes to a destination", &ok)
        check(DestinationSlotID(rawValue: "dailyOverview") == nil,
              "the Today page still has a body slot", &ok)
        let titles = RailDestination.allCases.map(\.title)
        check(!titles.contains("Today"), "a destination is still titled Today: \(titles)", &ok)
    }

    // MARK: 2. The bar's pills

    private static func checkTheBarHasNoTodayPill(_ ok: inout Bool) {
        print("\n-- the bar has no Today pill --")
        let titles = DaylightSpace.allCases.map(\.title)
        check(titles == ["Home", "Command", "Operations", "Stores", "Engineering"],
              "the pills should be Home, Command, Operations, Stores, Engineering, got \(titles)", &ok)
        check(DaylightSpace(rawValue: "dailyOverview") == nil,
              "the Today pill's raw value still decodes to a space", &ok)
        check(DaylightSpace.overview.shortcutIndex == 1,
              "Home should be \u{2318}1 again, reports \u{2318}\(DaylightSpace.overview.shortcutIndex)", &ok)
    }

    // MARK: 3. The sources

    /// The removed types, the removed settings keys, and the sentences the
    /// captain pointed at, matched in code with comments stripped - so a
    /// source comment explaining the removal does not fail the run, and code
    /// bringing any of it back does.
    ///
    /// `TodayCalendarRetirement.swift` is exempt because naming the leftover
    /// keys and Keychain services is its whole job; it is asserted
    /// separately to hold none of the removed *types*.
    static let bannedInCode = [
        "DailyOverviewController", "DailyReviewCard", "DailyReviewCalendar",
        "DailyReviewEventRow", "DailyReviewStickyRow", "DailyReviewReadingSummary",
        "GoogleAccount", "GoogleOAuth", "GoogleSignIn", "GoogleCalendar", "GmailAccountRow",
        "CaptureInboxStore", "CaptureInboxCard",
        "import EventKit", "EKEventStore", "import AuthenticationServices", "ASWebAuthenticationSession",
        "dailyOverview", "dailyReviewEnabled", "dailyReviewDismissedDay",
        "dailyReviewCalendarEnabled", "googleCalendarEnabled",
        "Show today\u{2019}s calendar", "Plan the day in Tasks", "Captured today",
        "Nothing captured today", "Work mail", "calendar isn\u{2019}t connected",
        "Google Accounts",
    ]

    static let cleanupFile = "TodayCalendarRetirement.swift"

    private static func checkNoSourceNamesTheRemovedPieces(_ ok: inout Bool) {
        print("\n-- no source names the removed pieces --")
        guard let files = SelfTestSources.appSourceFiles(), !files.isEmpty else {
            fail("could not read the app's sources - this guard would pass vacuously", &ok)
            return
        }
        // Discriminating power: the scan really reads code, and the comment
        // stripping really leaves it.
        // The shell's API lives in `WorkspaceShellController` since stage 3 of
        // the modular-shell migration.
        let shell = files.first { $0.lastPathComponent == "WorkspaceShellController.swift" }
        let shellCode = shell.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(stripComments) ?? ""
        check(shellCode.contains("func restoreDestination"),
              "fixture: the scan should see the shell's code", &ok)

        var offenders: [String] = []
        for file in files where file.lastPathComponent != cleanupFile {
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = stripComments(raw)
            for needle in bannedInCode where code.contains(needle) {
                offenders.append("\(file.lastPathComponent): \(needle)")
            }
        }
        check(offenders.isEmpty,
              "the removed Today page or calendar integration is back: \(offenders.joined(separator: "; "))", &ok)

        // The cleanup names keys and services, never a removed type.
        if let cleanup = files.first(where: { $0.lastPathComponent == cleanupFile }),
           let raw = try? String(contentsOf: cleanup, encoding: .utf8) {
            let code = stripComments(raw)
            let types = bannedInCode.filter { $0.first?.isUppercase == true && !$0.contains(" ") }
            for needle in types where code.contains(needle) {
                fail("\(cleanupFile) reaches a removed type, \(needle)", &ok)
            }
        } else {
            fail("could not read \(cleanupFile) - the launch cleanup is missing", &ok)
        }
    }

    /// Neither bundle may carry a calendar usage description. The key is
    /// what makes macOS show a calendar prompt at all, and nothing in this
    /// app reads a calendar any more.
    private static func checkNeitherBundleAsksForCalendarAccess(_ ok: inout Bool) {
        print("\n-- neither bundle asks for calendar access --")
        guard let sources = SelfTestSources.appSourceDirectory() else {
            fail("could not resolve the app's source directory - this guard would pass vacuously", &ok)
            return
        }
        let native = sources.deletingLastPathComponent().deletingLastPathComponent()
        for relative in ["build_native_app.sh", "Scripts/build-probe-app.sh"] {
            let url = native.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                fail("could not read \(relative)", &ok)
                continue
            }
            // Discriminating power: this really is the script that writes the
            // Info.plist, so an absence is a real absence.
            check(text.contains("NSMicrophoneUsageDescription"),
                  "fixture: \(relative) should write the Info.plist's usage descriptions", &ok)
            check(!text.contains("NSCalendars"),
                  "\(relative) still asks for calendar access", &ok)
        }
    }

    // MARK: 4. The launch cleanup

    /// What the removed features wrote, restated here as literals rather than
    /// read off `TodayCalendarRetirement`. Seeding from the production list
    /// would let a key dropped from it go unseeded and unnoticed.
    static let leftDefaultsKeys = [
        "fm.dailyReviewEnabled", "fm.dailyReviewDismissedDay",
        "fm.dailyReviewCalendarEnabled", "fm.googleCalendarEnabled",
    ]
    static let leftKeychainItems: [(service: String, account: String)] = [
        (KeychainService.resolve("com.manjesh.grandline.native.google-oauth"), "google.work"),
        (KeychainService.resolve("com.manjesh.grandline.native.google-oauth"), "google.personal"),
        (KeychainService.resolve("com.manjesh.grandline.native.google-oauth-client"), "client"),
        (KeychainService.resolve("com.firstmate.cockpit.native.google-oauth"), "google.work"),
        (KeychainService.resolve("com.firstmate.cockpit.native.google-oauth-client"), "client"),
    ]

    private static func checkTheCleanupRemovesWhatTheyLeft(_ ok: inout Bool) {
        print("\n-- the launch cleanup removes what the removed features left --")
        guard let (defaults, domain) = scratchDefaults() else {
            fail("could not open a scratch defaults domain", &ok)
            return
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Every service name the pass touches must be this process's own, or
        // it would delete the captain's real items.
        let services = TodayCalendarRetirement.retiredKeychainServices
        guard !KeychainService.testPrefix.isEmpty,
              services.allSatisfy({ $0 != KeychainService.bare($0) }) else {
            fail("the retired Keychain services are not this process's prefixed names, so the "
                 + "cleanup cannot be exercised safely: \(services)", &ok)
            return
        }

        // What the features left: their four keys, both Google slots and the
        // OAuth client under the current names and the pre-rename ones, and
        // the capture log.
        for key in leftDefaultsKeys { defaults.set(true, forKey: key) }
        defaults.set("kept", forKey: "fm.unrelatedSetting")
        let seeded = leftKeychainItems
        for (service, account) in seeded {
            do {
                try seed(service: service, account: account)
            } catch {
                fail("could not seed \(service)/\(account): \(error)", &ok)
                return
            }
        }
        let unrelatedService = KeychainService.resolve("com.manjesh.grandline.native.credential-vault")
        try? seed(service: unrelatedService, account: "today-calendar-removal-probe")
        defer { delete(service: unrelatedService, account: "today-calendar-removal-probe") }
        let log = root.appendingPathComponent(TodayCalendarRetirement.captureLogFileName)
        let otherFile = root.appendingPathComponent("tasks.json")
        try? Data("[]".utf8).write(to: log)
        try? Data("[]".utf8).write(to: otherFile)

        // Discriminating power: everything is really there before the pass.
        check(seeded.allSatisfy { exists(service: $0.0, account: $0.1) },
              "fixture: every seeded Keychain item should exist before the pass", &ok)
        check(FileManager.default.fileExists(atPath: log.path), "fixture: the capture log should exist", &ok)

        let outcome = TodayCalendarRetirement.run(defaults: defaults, dataRoot: root)

        check(outcome.failures.isEmpty, "the pass reported failures: \(outcome.failures)", &ok)
        check(Set(outcome.removedDefaultsKeys) == Set(leftDefaultsKeys),
              "every retired key should be removed, got \(outcome.removedDefaultsKeys)", &ok)
        for key in leftDefaultsKeys {
            check(defaults.object(forKey: key) == nil, "\(key) is still set", &ok)
        }
        check(defaults.string(forKey: "fm.unrelatedSetting") == "kept",
              "the pass removed a key it does not own", &ok)

        check(outcome.removedKeychainItems == seeded.count,
              "every seeded Keychain item should be removed, got \(outcome.removedKeychainItems) of \(seeded.count)",
              &ok)
        for (service, account) in seeded {
            check(!exists(service: service, account: account), "\(service)/\(account) is still in the Keychain", &ok)
        }
        check(exists(service: unrelatedService, account: "today-calendar-removal-probe"),
              "the pass deleted an item under a service it does not own", &ok)

        check(outcome.removedCaptureLog && !FileManager.default.fileExists(atPath: log.path),
              "the capture log should be gone", &ok)
        check(FileManager.default.fileExists(atPath: otherFile.path),
              "the pass deleted a file it does not own", &ok)
    }

    private static func checkTheCleanupRunsOnce(_ ok: inout Bool) {
        print("\n-- the launch cleanup runs once --")
        guard let (defaults, domain) = scratchDefaults() else {
            fail("could not open a scratch defaults domain", &ok)
            return
        }
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        check(TodayCalendarRetirement.runIfNeeded(defaults: defaults, dataRoot: root) != nil,
              "a machine that never ran the pass should run it", &ok)
        check(defaults.bool(forKey: TodayCalendarRetirement.completedKey),
              "the pass should record that it ran", &ok)

        // A key reappearing after the pass is left alone: the pass is a
        // one-time migration, not a standing filter over the domain.
        defaults.set(true, forKey: TodayCalendarRetirement.retiredDefaultsKeys[0])
        check(TodayCalendarRetirement.runIfNeeded(defaults: defaults, dataRoot: root) == nil,
              "a second launch should skip the pass", &ok)
        check(defaults.object(forKey: TodayCalendarRetirement.retiredDefaultsKeys[0]) != nil,
              "a skipped pass should not have touched the domain", &ok)
    }

    // MARK: Helpers

    private static func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let slashes = line.range(of: "//") else { return line }
            return line[line.startIndex..<slashes.lowerBound]
        }.joined(separator: "\n")
    }

    private static func scratchDefaults() -> (UserDefaults, String)? {
        let domain = "fm.selftest.today-calendar-removal.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { return nil }
        return (defaults, domain)
    }

    private static func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("today-calendar-removal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func seed(service: String, account: String) throws {
        delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data("fabricated".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    private static func exists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#endif
