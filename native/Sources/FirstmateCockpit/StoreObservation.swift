// Manjesh Grand Line - native macOS app.
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
