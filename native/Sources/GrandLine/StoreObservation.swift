// Grand Line - native macOS app.
//
// GL-P3 (phase 4's own written leftovers list, audit §6.10): the token a
// store's `observe(_:)` hands back.
//
// `ThemeManager`, `FontSizeManager`, `ChromeTextScale`, `AppActivityState`,
// `HostSessionRegistry` and `RecentDestinations` all return a token from
// `observe`; the plain data stores appended a bare closure to an array with no
// way back. Every observer of those is app-lifetime today, so nothing leaks
// right now - but "no way to unregister" is what made `ConsoleController` a
// problem the first time a page became destroyable (see `ThemeManager.swift`'s
// own checklist), and a store that cannot be safely watched by a
// short-lived object is a trap waiting for the next one.
//
// One shared token type rather than one per store: these carry no payload and
// exist only for reference identity, so `HostStore`'s and `DictationStore`'s
// would have been the same empty class twice. The observation-carrying
// singletons above keep their own named tokens - those are established API
// with their own call sites, and renaming them would be churn for nothing.
import Foundation

/// An opaque handle to a live store `observe(_:)` registration. Pass it back
/// to that store's `unobserve(_:)`; discard it if the observer outlives the
/// app, which every current one does.
final class StoreObservation {}

// MARK: - R2-ARCH-08: one way to watch a store

/// Every listener a store has, and the one way it tells them.
///
/// Review #1's ARCH-04 (T-18) and the second review's R2-ARCH-08: six types
/// exposed a single `var onChange: (() -> Void)?`, so the last assignment won
/// silently and every new reader needed a bespoke second channel - the
/// sidebar layout's Secrets badge got `CredentialVaultStore.observeLock`
/// precisely because `onChange` was Poneglyph's. A store now keeps one of
/// these and conforms to `StoreObservable`, and any number of readers can
/// watch it.
///
/// Delivery is on the main thread, inside the store: a change reported on
/// main is delivered at once, as `onChange` was, and one reported from a
/// background queue is hopped to main before any listener runs.
final class StoreObservers {
    private var handlers: [(token: StoreObservation, fn: () -> Void)] = []
    private let lock = NSLock()

    func add(_ handler: @escaping () -> Void) -> StoreObservation {
        let token = StoreObservation()
        lock.lock(); handlers.append((token, handler)); lock.unlock()
        return token
    }

    func remove(_ token: StoreObservation) {
        lock.lock(); handlers.removeAll { $0.token === token }; lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return handlers.count }

    #if FM_SELFTESTS
    /// Called with `Thread.isMainThread` each time the store reports a change.
    var notifyThreadForTests: ((Bool) -> Void)?
    #endif

    /// Tell every listener the store changed. Each one is read when it runs,
    /// so a listener that unobserves another during delivery is honoured.
    func notify() {
        #if FM_SELFTESTS
        // The thread the store reported the change on, before any hop - which
        // is the thread its mutation ran on. A suite asserting a store's
        // mutation thread reads this, never the delivery thread.
        notifyThreadForTests?(Thread.isMainThread)
        #endif
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in deliver() }
            return
        }
        deliver()
    }

    private func deliver() {
        lock.lock(); let current = handlers.map(\.fn); lock.unlock()
        current.forEach { $0() }
    }
}

/// A store that any number of readers can watch (R2-ARCH-08). Named for
/// stores rather than `Observable`, which is the Observation framework's
/// protocol and would be ambiguous in any file that imports SwiftUI.
protocol StoreObservable: AnyObject {
    var observers: StoreObservers { get }
}

extension StoreObservable {
    /// Hear about every change, on the main thread. Keep the token and pass
    /// it to `unobserve(_:)` when the reader goes away; an app-lifetime reader
    /// may discard it.
    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> StoreObservation { observers.add(handler) }

    func unobserve(_ token: StoreObservation) { observers.remove(token) }
}

