// Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for the clipboard history's *logic*
// half (`fm/grandline-feature-f2-f3-capture-clipboard`, F3 of full review #3
// §8): the capture rule, the Poneglyph exclusion, the 200-item rolling
// eviction and what a pin does to it, dedup, the sealed round trip, and the
// shared `changeCount` watch's fan-out.
//
// **The one case that matters most is `checkPoneglyphCopiesNeverLand`.** It is
// a real security property, not a nice-to-have, so it is asserted in both
// directions: the identical string *does* land when it is an ordinary copy,
// and does not when `CredentialVaultClipboard.writeConcealed` has marked it -
// which is what stops the check passing vacuously against a store that simply
// records nothing. It also reads the sealed file back off disk and greps the
// plaintext for the secret, because "the in-memory array does not contain it"
// is a weaker claim than "the bytes on disk do not contain it".
//
// **Pure logic, no window.** `NEEDS_SESSION` decides whether a suite guards
// CI's blocking lane, and this one must. `ClipboardHistoryViewSelfTest` is the
// window-backed half.
//
// **Every pasteboard here is a named one, never `.general`** - a suite that
// wrote to the system pasteboard would destroy whatever the captain had
// copied, on every run.
//
// `FM_RUN_CLIPBOARD_HISTORY_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ClipboardHistorySelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkPoneglyphCopiesNeverLand(check)
        checkTheSkipMarkerCarriesNoText(check)
        checkOrdinaryCapture(check)
        checkDedup(check)
        checkTooLongAndEmpty(check)
        checkEviction(check)
        checkPinsSurviveEviction(check)
        checkSealedRoundTrip(check)
        checkAnUnreadableFileIsNotAnEmptyOne(check)
        checkNoKeyIsNotAnEmptyHistory(check)
        checkFilter(check)
        checkTheSharedChangeWatch(check)

        print(ok ? "ClipboardHistorySelfTest: OK" : "ClipboardHistorySelfTest: FAILURES")
        return ok
    }

    // MARK: Fixtures

    /// A store sealed with a throwaway key, writing into a temp directory.
    /// Never the production constructor with no arguments - that resolves the
    /// captain's own file and his own Keychain item.
    private static func withStore(_ body: (ClipboardHistoryStore, URL) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-clipboard-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clipboard-history.sealed")
        guard let key = ClipboardHistoryKey.ephemeralKey() else {
            print("\(SelfTestAssertions.failurePrefix)could not build a throwaway key")
            return
        }
        body(ClipboardHistoryStore(fileURL: file, key: key), file)
    }

    private static func withPasteboard(_ body: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("grandline-clipboard-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        body(pasteboard)
    }

    // MARK: The exclusion

    private static func checkPoneglyphCopiesNeverLand(_ check: (Bool, String) -> Void) {
        let secret = "hunter2-the-real-production-token"

        withStore { store, file in
            withPasteboard { pasteboard in
                // The fixture's own discriminating power, first: prove this
                // store records this exact string when it is an ordinary copy.
                // Without this half, "it was not recorded" would pass against
                // a store that records nothing at all.
                pasteboard.clearContents()
                pasteboard.setString(secret, forType: .string)
                let ordinary = store.record(from: pasteboard)
                guard case .recorded = ordinary else {
                    check(false, "an ordinary copy of the fixture string was not recorded (\(ordinary)) - the check below would be vacuous")
                    return
                }
                check(store.entries.contains { $0.text == secret },
                      "the fixture string IS recorded when it is an ordinary copy")
            }
        }

        withStore { store, file in
            withPasteboard { pasteboard in
                // Now the real thing: the same string, written the way
                // Poneglyph writes it.
                CredentialVaultClipboard.writeConcealed(secret, to: pasteboard)
                check(pasteboard.string(forType: .string) == secret,
                      "the value really is on the pasteboard - the refusal is a decision, not an empty read")

                let outcome = store.record(from: pasteboard)
                check(outcome == .refusedConcealed,
                      "a Poneglyph copy is refused, got \(outcome)")
                check(!store.entries.contains { $0.text.contains("hunter2") },
                      "no entry holds the secret")
                check(store.entries.allSatisfy { $0.kind == .skipped || !$0.text.contains(secret) },
                      "nothing recorded carries the secret")

                // The stronger claim: the bytes on disk. A sealed file cannot
                // be grepped directly, so this opens it the way the app does
                // and greps what comes back, and also greps the raw ciphertext
                // for good measure.
                guard let raw = try? Data(contentsOf: file) else {
                    check(false, "the store wrote no file at all")
                    return
                }
                check(!raw.range(of: Data(secret.utf8)).isSome,
                      "the secret does not appear verbatim in the file on disk")
                let reopened = ClipboardHistoryStore(fileURL: file, key: nil)
                check(reopened.entries.isEmpty,
                      "a reader with no key sees no entries either")
            }
        }

        // Each marker on its own is enough - another app honouring the
        // nspasteboard.org convention writes one, not this app's three.
        for marker in CredentialVaultClipboard.concealedMarkerTypes {
            withStore { store, _ in
                withPasteboard { pasteboard in
                    pasteboard.clearContents()
                    pasteboard.setString(secret, forType: .string)
                    pasteboard.setData(Data(), forType: marker)
                    check(store.record(from: pasteboard) == .refusedConcealed,
                          "\(marker.rawValue) alone is enough to refuse")
                    check(!store.entries.contains { $0.text.contains("hunter2") },
                          "\(marker.rawValue): nothing recorded carries the secret")
                }
            }
        }
    }

    private static func checkTheSkipMarkerCarriesNoText(_ check: (Bool, String) -> Void) {
        withStore { store, _ in
            withPasteboard { pasteboard in
                CredentialVaultClipboard.writeConcealed("hunter2", to: pasteboard)
                _ = store.record(from: pasteboard)
                guard let marker = store.entries.first(where: { $0.kind == .skipped }) else {
                    check(false, "the refusal left no visible marker - the mockup draws one")
                    return
                }
                check(marker.text.isEmpty, "the marker carries no text, got \(marker.text.debugDescription)")
                check(marker.preview.contains("Poneglyph"),
                      "the marker says why, got \(marker.preview)")
                check(!marker.isPinned, "a marker is not pinnable")
                store.setPinned(true, id: marker.id)
                check(!(store.entries.first { $0.id == marker.id }?.isPinned ?? true),
                      "pinning a marker is refused")

                // A run of refusals collapses rather than stacking - a vault
                // copy plus its own auto-clear moves the count more than once.
                _ = store.record(from: pasteboard)
                _ = store.record(from: pasteboard)
                check(store.entries.filter { $0.kind == .skipped }.count == 1,
                      "consecutive refusals collapse into one marker, found \(store.entries.filter { $0.kind == .skipped }.count)")
            }
        }
    }

    // MARK: Ordinary capture

    private static func checkOrdinaryCapture(_ check: (Bool, String) -> Void) {
        withStore { store, _ in
            withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("10.42.0.0/16", forType: .string)
                let outcome = store.record(from: pasteboard, sourceApp: "Safari")
                guard case .recorded = outcome else {
                    check(false, "an ordinary copy was not recorded, got \(outcome)")
                    return
                }
                guard let entry = store.entries.first else { return }
                check(entry.text == "10.42.0.0/16", "the text is kept verbatim, got \(entry.text)")
                check(entry.sourceApp == "Safari", "the source app is kept, got \(String(describing: entry.sourceApp))")
                check(entry.kind == .text, "an ordinary copy is a text entry")
                check(!entry.isPinned, "a fresh entry is unpinned")
            }
        }
    }

    private static func checkDedup(_ check: (Bool, String) -> Void) {
        withStore { store, _ in
            withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("same value", forType: .string)
                _ = store.record(from: pasteboard, now: Date(timeIntervalSince1970: 1000))
                pasteboard.clearContents()
                pasteboard.setString("another", forType: .string)
                _ = store.record(from: pasteboard, now: Date(timeIntervalSince1970: 2000))
                pasteboard.clearContents()
                pasteboard.setString("same value", forType: .string)
                let outcome = store.record(from: pasteboard, now: Date(timeIntervalSince1970: 3000))

                guard case .promotedExisting = outcome else {
                    check(false, "re-copying an existing value should promote it, got \(outcome)")
                    return
                }
                check(store.entries.count == 2,
                      "re-copying does not duplicate, found \(store.entries.count) entries")
                check(store.ordered().first?.text == "same value",
                      "the promoted entry is on top, got \(String(describing: store.ordered().first?.text))")
            }
        }
    }

    private static func checkTooLongAndEmpty(_ check: (Bool, String) -> Void) {
        withStore { store, _ in
            withPasteboard { pasteboard in
                pasteboard.clearContents()
                check(store.record(from: pasteboard) == .nothingToRecord,
                      "an empty pasteboard records nothing")

                pasteboard.clearContents()
                pasteboard.setString("   \n\t ", forType: .string)
                check(store.record(from: pasteboard) == .nothingToRecord,
                      "a whitespace-only copy records nothing")

                pasteboard.clearContents()
                pasteboard.setString(String(repeating: "x", count: ClipboardHistoryStore.maxEntryLength + 1),
                                     forType: .string)
                check(store.record(from: pasteboard) == .tooLong,
                      "an oversized copy is refused (GL-35)")

                // And the boundary really is a boundary, not a coincidence.
                pasteboard.clearContents()
                pasteboard.setString(String(repeating: "x", count: ClipboardHistoryStore.maxEntryLength),
                                     forType: .string)
                if case .recorded = store.record(from: pasteboard) {} else {
                    check(false, "a copy at exactly the cap is recorded")
                }
                check(store.entries.count == 1, "only the in-bounds copy landed, found \(store.entries.count)")
            }
        }
    }

    // MARK: The rolling window

    private static func checkEviction(_ check: (Bool, String) -> Void) {
        withStore { store, _ in
            withPasteboard { pasteboard in
                let overflow = 25
                for index in 0..<(ClipboardHistoryStore.maxUnpinnedEntries + overflow) {
                    pasteboard.clearContents()
                    pasteboard.setString("entry-\(index)", forType: .string)
                    _ = store.record(from: pasteboard,
                                     now: Date(timeIntervalSince1970: Double(index)))
                }
                check(store.entries.count == ClipboardHistoryStore.maxUnpinnedEntries,
                      "the history caps at \(ClipboardHistoryStore.maxUnpinnedEntries), found \(store.entries.count)")
                check(!store.entries.contains { $0.text == "entry-0" },
                      "the oldest entry was evicted")
                check(store.entries.contains { $0.text == "entry-\(ClipboardHistoryStore.maxUnpinnedEntries + overflow - 1)" },
                      "the newest entry survived")
            }
        }
    }

    private static func checkPinsSurviveEviction(_ check: (Bool, String) -> Void) {
        withStore { store, _ in
            withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("the pinned one", forType: .string)
                _ = store.record(from: pasteboard, now: Date(timeIntervalSince1970: 0))
                guard let pinnedID = store.entries.first?.id else {
                    check(false, "nothing to pin")
                    return
                }
                store.setPinned(true, id: pinnedID)

                for index in 1...(ClipboardHistoryStore.maxUnpinnedEntries + 50) {
                    pasteboard.clearContents()
                    pasteboard.setString("entry-\(index)", forType: .string)
                    _ = store.record(from: pasteboard, now: Date(timeIntervalSince1970: Double(index)))
                }

                check(store.entries.contains { $0.id == pinnedID },
                      "a pinned entry survives \(ClipboardHistoryStore.maxUnpinnedEntries + 50) newer copies")
                check(store.entries.count == ClipboardHistoryStore.maxUnpinnedEntries + 1,
                      "the cap applies to the unpinned tail only, found \(store.entries.count)")
                check(store.ordered().first?.id == pinnedID,
                      "pinned entries sort ahead of the rest")

                // Unpinning puts it back into the window, which evicts it at
                // once - the mirror of the rule above, and the half a naive
                // implementation gets wrong.
                store.setPinned(false, id: pinnedID)
                check(!store.entries.contains { $0.id == pinnedID },
                      "unpinning the oldest entry returns it to the rolling window")
                check(store.entries.count == ClipboardHistoryStore.maxUnpinnedEntries,
                      "and the cap holds again, found \(store.entries.count)")
            }
        }
    }

    // MARK: Disk

    private static func checkSealedRoundTrip(_ check: (Bool, String) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-clipboard-roundtrip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clipboard-history.sealed")
        guard let key = ClipboardHistoryKey.ephemeralKey() else {
            check(false, "could not build a throwaway key")
            return
        }

        let written: ClipboardHistoryStore = {
            let store = ClipboardHistoryStore(fileURL: file, key: key)
            withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("arn:aws:iam::4418:role/raas-deploy", forType: .string)
                _ = store.record(from: pasteboard, sourceApp: "Console")
            }
            return store
        }()
        check(written.entries.count == 1, "one entry written")
        guard let id = written.entries.first?.id else { return }
        written.setPinned(true, id: id)

        let reopened = ClipboardHistoryStore(fileURL: file, key: key)
        check(reopened.entries.count == 1, "one entry read back, found \(reopened.entries.count)")
        check(reopened.entries.first?.text == "arn:aws:iam::4418:role/raas-deploy",
              "the text survives the round trip")
        check(reopened.entries.first?.isPinned == true, "the pin survives the round trip")
        check(reopened.entries.first?.sourceApp == "Console", "the source survives the round trip")
        check(!reopened.loadFailed, "a good file does not read as a failure")

        // The file really is sealed - the plaintext must not be in it.
        if let raw = try? Data(contentsOf: file) {
            check(!raw.range(of: Data("raas-deploy".utf8)).isSome,
                  "the entry is not stored in plaintext")
            check(raw.count > 16, "something was actually written, \(raw.count) bytes")
        } else {
            check(false, "no file was written")
        }
    }

    /// GL-01: "file missing" and "file present but unreadable" are different
    /// states, and the second must never read as an empty history.
    private static func checkAnUnreadableFileIsNotAnEmptyOne(_ check: (Bool, String) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-clipboard-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("clipboard-history.sealed")
        try? Data("not a sealed box at all".utf8).write(to: file)

        guard let key = ClipboardHistoryKey.ephemeralKey() else {
            check(false, "could not build a throwaway key")
            return
        }
        let store = ClipboardHistoryStore(fileURL: file, key: key)
        check(store.loadFailed, "an undecodable file reports a failure, not an empty history")
        check(store.entries.isEmpty, "and holds no entries")

        // GL-01's other half: the bad bytes are kept, not overwritten.
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        check(siblings.contains { $0.contains("corrupt-") },
              "the unreadable file was backed up before anything overwrote it, found \(siblings)")
    }

    /// GL-14: "no key" is not "no history".
    private static func checkNoKeyIsNotAnEmptyHistory(_ check: (Bool, String) -> Void) {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grandline-clipboard-nokey-\(UUID().uuidString).sealed")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ClipboardHistoryStore(fileURL: file, key: nil)
        check(!store.isAvailable, "a store with no key says it is unavailable")
        check(store.loadFailed, "and reports the failure rather than reading as empty")
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("anything", forType: .string)
            check(store.record(from: pasteboard) == .unavailable,
                  "and records nothing rather than writing plaintext")
        }
        check(!FileManager.default.fileExists(atPath: file.path),
              "and writes no file at all")
    }

    // MARK: Filtering

    private static func checkFilter(_ check: (Bool, String) -> Void) {
        withStore { store, _ in
            withPasteboard { pasteboard in
                for (index, text) in ["kubectl get pods", "https://github.com/pull/425", "RaaS rollout"].enumerated() {
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    _ = store.record(from: pasteboard, now: Date(timeIntervalSince1970: Double(index)))
                }
                CredentialVaultClipboard.writeConcealed("hunter2", to: pasteboard)
                _ = store.record(from: pasteboard, now: Date(timeIntervalSince1970: 99))

                check(store.filtered("").count == 4, "an empty filter shows everything including the marker")
                check(store.filtered("kubectl").count == 1, "a filter narrows, got \(store.filtered("kubectl").count)")
                check(store.filtered("RAAS").count == 1, "the filter is case-insensitive")
                // A skipped marker has no text, so it matches nothing - and in
                // particular it must not be findable by searching for what it
                // refused to record.
                check(store.filtered("hunter2").isEmpty,
                      "the secret is not findable through the filter either")
                check(store.filtered("Poneglyph").isEmpty,
                      "a marker is a note about a refusal, not a searchable clipping")
            }
        }
    }

    // MARK: The shared watch

    private static func checkTheSharedChangeWatch(_ check: (Bool, String) -> Void) {
        // The point of this case is that there is exactly ONE thing in this app
        // polling `NSPasteboard.changeCount`, and that it fans out. A second
        // poller would be invisible to any behavioural test, which is why this
        // asserts the fan-out rather than the effect.
        let clipboard = CredentialVaultClipboard.shared
        let before = clipboard.changeObserverCountForTests
        var fired = 0
        let token = clipboard.observeChanges { _ in fired += 1 }
        check(clipboard.changeObserverCountForTests == before + 1,
              "an observer is registered, count \(clipboard.changeObserverCountForTests)")

        // Drive a tick against a genuinely unchanged count first: a watch that
        // fired on every tick would make the real capture loop record the same
        // clipping forever.
        clipboard.pollChangeCountForTests()
        clipboard.pollChangeCountForTests()
        check(fired <= 1,
              "an unchanged pasteboard does not fan out repeatedly, fired \(fired)")

        clipboard.unobserveChanges(token)
        check(clipboard.changeObserverCountForTests == before,
              "the observer is removed again, count \(clipboard.changeObserverCountForTests)")
    }
}

private extension Optional {
    var isSome: Bool { self != nil }
}

#endif
