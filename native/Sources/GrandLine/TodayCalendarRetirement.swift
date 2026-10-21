// Grand Line - native macOS app.
//
// A one-time cleanup of what the Today page and the calendar integration left
// on the captain's Mac, after both were removed
// (`fm/grandline-remove-today-calendar-1792553365`).
//
// Removing the code stops anything new being written, and it also removes the
// only code that knew these items existed. Without this pass they would stay
// on disk for good: a Keychain item holding a Google refresh token that
// nothing reads, an OAuth client id and secret that nothing uses, four
// preference keys and a capture log no surface shows.
//
// ## What it deletes
//
//   - **Two Keychain services**, under both the current and the pre-rename
//     names. One held each connected Google account's tokens, granted scopes
//     and address (one item per account slot). The other held the captain's
//     OAuth client id and secret. Deleted by service rather than by account,
//     so every slot goes, and in a loop because `SecItemDelete` removes one
//     matching item per call on the file-based login keychain (AGENTS.md's
//     "Stores, subprocesses and secrets").
//   - **Four preference keys**: the daily review's on/off switch and its
//     dismissed day, and the two calendar source switches.
//   - **The capture log**, `capture-inbox.json` under the data root. It was a
//     record of where each ⌥Space capture was filed, read only by the removed
//     "Captured today" card. Every capture itself lives in its own store and
//     is untouched.
//
// ## What it does not do
//
// It does not revoke the Google grant. Revoking needs the refresh token read
// back out of the Keychain and a network call, and a launch-time pass that
// reads secrets to send them somewhere is the wrong shape for a cleanup. The
// PR that removed the feature tells the captain where to revoke it by hand.
//
// ## Once, off the main thread, and never in a probe
//
// The Keychain half can show a system dialog (an item written by an earlier
// signature), so this runs on a background queue after the window is up,
// right after the rename's own Keychain migration (GL-25). It runs once per
// machine: `completedKey` is set whatever the outcome, and a failure is
// logged rather than retried on every launch (GL-11). A scratch-redirected
// process never reaches it, for the same reason it never runs the rename
// migration (B4).

import Foundation
import Security

enum TodayCalendarRetirement {

    /// Set once the pass has run.
    static let completedKey = "fm.todayCalendarRetired"

    /// The preference keys the removed features wrote.
    static let retiredDefaultsKeys = [
        "fm.dailyReviewEnabled",
        "fm.dailyReviewDismissedDay",
        "fm.dailyReviewCalendarEnabled",
        "fm.googleCalendarEnabled",
    ]

    /// The Keychain services the removed Google sign-in wrote, current names
    /// first and then their pre-rename spellings.
    ///
    /// Through `KeychainService.resolve`, so a self-test process deletes its
    /// own prefixed items rather than the captain's real ones.
    static var retiredKeychainServices: [String] {
        let current = [
            KeychainService.resolve("com.manjesh.grandline.native.google-oauth"),
            KeychainService.resolve("com.manjesh.grandline.native.google-oauth-client"),
        ]
        return current + current.compactMap(LegacyNameMigration.legacyName(for:))
    }

    /// The capture log's file name under the data root.
    static let captureLogFileName = "capture-inbox.json"

    /// What one pass did, for the log line and for a suite.
    struct Outcome: Equatable {
        var removedDefaultsKeys: [String] = []
        var removedKeychainItems = 0
        var removedCaptureLog = false
        var failures: [String] = []
    }

    /// Runs the pass unless it has already run. `nil` means it was skipped.
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = AppDefaults.store,
                            dataRoot: URL = AppPaths.dataRoot()) -> Outcome? {
        guard !defaults.bool(forKey: completedKey) else { return nil }
        let outcome = run(defaults: defaults, dataRoot: dataRoot)
        defaults.set(true, forKey: completedKey)
        if !outcome.failures.isEmpty {
            for failure in outcome.failures {
                AppLog.keychain.error("Today/calendar cleanup: \(failure, privacy: .public)")
            }
        }
        AppLog.lifecycle.notice("""
            Today/calendar cleanup: removed \(outcome.removedDefaultsKeys.count, privacy: .public) \
            preference key(s), \(outcome.removedKeychainItems, privacy: .public) Keychain item(s) \
            and \(outcome.removedCaptureLog ? "the" : "no", privacy: .public) capture log.
            """)
        return outcome
    }

    /// The pass itself, with no once-only gate.
    static func run(defaults: UserDefaults, dataRoot: URL) -> Outcome {
        var outcome = Outcome()

        for key in retiredDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            outcome.removedDefaultsKeys.append(key)
        }

        for service in retiredKeychainServices {
            let (removed, failure) = deleteEveryItem(service: service)
            outcome.removedKeychainItems += removed
            if let failure { outcome.failures.append(failure) }
        }

        let log = dataRoot.appendingPathComponent(captureLogFileName)
        if FileManager.default.fileExists(atPath: log.path) {
            do {
                try FileManager.default.removeItem(at: log)
                outcome.removedCaptureLog = true
            } catch {
                outcome.failures.append("could not remove \(log.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// Deletes every generic password under `service`, one call per item.
    ///
    /// Bounded, so an item that keeps answering "deleted" without going away
    /// cannot spin a background thread for ever.
    private static func deleteEveryItem(service: String) -> (removed: Int, failure: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        var removed = 0
        for _ in 0..<16 {
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess:
                removed += 1
            case errSecItemNotFound:
                return (removed, nil)
            default:
                return (removed, "the Keychain refused to delete \(service) (\(status))")
            }
        }
        return (removed, "\(service) still had items after 16 deletes")
    }
}
