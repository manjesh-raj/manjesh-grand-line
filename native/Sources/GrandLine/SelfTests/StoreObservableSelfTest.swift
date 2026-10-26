// Grand Line - native macOS app.
//
// R2-ARCH-08 of the second full review (review #1's T-18): one way to watch a
// store, `StoreObservable`, in place of six single-subscriber `onChange`
// closures - `CredentialVaultStore`, `SnippetStore`, `SSHKeyStore`,
// `ScheduleStore`, `ClipboardHistoryStore` and `TerminalBlockTracker`.
//
// The defect the closures had: the last assignment won, silently, so a second
// reader took the first one's updates away. The sidebar layout's Secrets
// badge had to get a lock-only channel of its own for exactly that reason.
// This suite asserts the property that replaces it, on each of the six:
//
//   1. a real change reaches two observers, both of them,
//   2. an observer that unobserves hears nothing more, and the other still
//      does,
//   3. a change reported off the main thread is delivered on it, and the
//      store's own report thread is still visible to a suite
//      (`notifyThreadForTests`), so the vault's threading checks keep
//      measuring the mutation rather than the delivery,
//   4. a source guard: none of the six declares `onChange` again.
//
// Pure logic, no window. Every store is built on this process's scratch
// root; the vault is created with a throwaway password and never saved
// anywhere real.
//
// Run with:
//   swift build && FM_RUN_STORE_OBSERVABLE_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum StoreObservableSelfTest {

    static func run() -> Bool {
        var ok = true
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-observable-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let snippets = SnippetStore()
        twoObserversHear("SnippetStore", snippets, &ok) {
            snippets.add(Snippet(label: "Observed \(UUID().uuidString)", command: "echo observed"))
        }
        let keys = SSHKeyStore()
        twoObserversHear("SSHKeyStore", keys, &ok) {
            keys.add(SSHKey(label: "Observed", type: .ed25519, publicKey: "ssh-ed25519 AAAAobserved",
                            fingerprint: "SHA256:observed-\(UUID().uuidString)"))
        }
        let schedules = ScheduleStore()
        twoObserversHear("ScheduleStore", schedules, &ok) {
            schedules.add(AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 9, minute: 0)))
        }
        let clipboard = ClipboardHistoryStore(fileURL: scratch.appendingPathComponent("clipboard.json"), key: nil)
        twoObserversHear("ClipboardHistoryStore", clipboard, &ok) { clipboard.clearAll() }
        let tracker = TerminalBlockTracker()
        twoObserversHear("TerminalBlockTracker", tracker, &ok) { tracker.reset() }
        let vault = CredentialVaultStore(root: scratch.appendingPathComponent("vault", isDirectory: true))
        twoObserversHear("CredentialVaultStore", vault, &ok) {
            var finished = false
            vault.createVault(masterPassword: "store-observable-password") { _ in finished = true }
            let deadline = Date().addingTimeInterval(60)
            while !finished, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }

        checkOffMainDeliveryHopsToMain(&ok)
        checkNoOnChangeComesBack(&ok)
        print(ok ? "StoreObservableSelfTest: all checks passed" : "StoreObservableSelfTest: FAILED")
        return ok
    }

    /// Drain the main queue, so a hop to main has landed before anything
    /// is counted.
    private static func drain() {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    private static func twoObserversHear(_ name: String, _ store: StoreObservable, _ ok: inout Bool,
                                         change: () -> Void) {
        var first = 0
        var second = 0
        let firstToken = store.observe { first += 1 }
        let secondToken = store.observe { second += 1 }
        change()
        drain()
        check(first > 0 && second > 0,
              "R2-ARCH-08: \(name)'s change reached \(first) and \(second) times - both observers must hear it", &ok)

        // The first one leaves; the second still hears the next change.
        store.unobserve(firstToken)
        let (firstBefore, secondBefore) = (first, second)
        store.observers.notify()
        drain()
        check(first == firstBefore, "\(name): an observer that unobserved still heard a change", &ok)
        check(second > secondBefore, "\(name): unobserving one observer silenced the other", &ok)
        store.unobserve(secondToken)
        check(store.observers.count == 0, "\(name): \(store.observers.count) observers left after both unobserved", &ok)
        if ok { print("  OK   \(name): two observers both hear a change, and unobserving one leaves the other") }
    }

    /// A change reported from a background queue reaches its observers on
    /// main, and the report thread is still readable before the hop.
    private static func checkOffMainDeliveryHopsToMain(_ ok: inout Bool) {
        let observers = StoreObservers()
        var deliveredOnMain: [Bool] = []
        var reportedOnMain: [Bool] = []
        _ = observers.add { deliveredOnMain.append(Thread.isMainThread) }
        observers.notifyThreadForTests = { reportedOnMain.append($0) }
        let reported = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            observers.notify()
            reported.signal()
        }
        reported.wait()
        let deadline = Date().addingTimeInterval(5)
        while deliveredOnMain.isEmpty, Date() < deadline { drain() }
        check(reportedOnMain == [false], "a background report was seen as \(reportedOnMain), want one off-main report", &ok)
        check(deliveredOnMain == [true], "a background report was delivered as \(deliveredOnMain), want once, on main", &ok)
        if ok { print("  OK   a change reported off main is delivered on main, and its report thread is still visible") }
    }

    /// The six types keep one observer list, never a second `onChange`.
    private static func checkNoOnChangeComesBack(_ ok: inout Bool) {
        let files = ["CredentialVaultStore.swift", "SnippetStore.swift", "SSHKeyStore.swift", "ScheduleStore.swift",
                     "ClipboardHistoryStore.swift", "TerminalBlockTracker.swift"]
        guard let dir = SelfTestSources.appSourceDirectory() else {
            fail("could not locate the app's sources - the guard would pass vacuously", &ok)
            return
        }
        for file in files {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else {
                fail("\(file) is not readable", &ok)
                continue
            }
            let code = text.split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
            check(code.contains(": StoreObservable"), "R2-ARCH-08: \(file) no longer conforms to StoreObservable", &ok)
            check(!code.contains("var onChange") && !code.contains("onChange?()"),
                  "R2-ARCH-08: \(file) has a single-subscriber onChange again", &ok)
        }
        if ok { print("  OK   none of the six declares a single-subscriber onChange") }
    }
}

#endif
