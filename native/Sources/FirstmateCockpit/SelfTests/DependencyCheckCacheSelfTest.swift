// Manjesh Grand Line - native macOS app.
//
// Permanent coverage for `DependencyCheckCache.swift` - the shared, TTL'd
// cache `UpdatesController`, `BootstrapController` and `AutomationController`
// all read from instead of each independently re-running the same 13-item
// `DependencyCatalog` sweep on first mount (`data/grand-line-energy-
// regression-scout/report.md`, section 2).
//
// Everything here uses `DependencyCheckCache.checkOverrideForTests` - a fake,
// counting stand-in for `UpdatesSource.check` - and either a fresh, disposable
// `DependencyCheckCache()` instance or fake `DependencyItem`s, never the real
// npm/brew/herdr subprocesses or the app's shared `.shared` singleton. That is
// what lets this suite prove "the underlying sweep ran exactly once" as a hard
// count rather than inferring it from timing or logs.
//
// `fm/grandline-poller-dependency-cache-bypass` added the last five cases:
// `BackgroundSignalsPoller` ran the same 13-item sweep on its own 15-minute
// cadence while calling `UpdatesSource.check` directly, so it was the one
// reader of this catalog that never shared anything with the other three -
// a captain who opened Updates and then sat still paid for the identical
// sweep twice within minutes. Those cases drive the **real**
// `BackgroundSignalsPoller.sweepSoftware` (against a disposable cache and the
// same counting fake) rather than re-implementing its policy, plus the one
// arithmetic invariant and the one wiring fact no behavioural check can see.
//
// Run: `FM_RUN_DEPENDENCY_CHECK_CACHE_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing a suite - `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Foundation

enum DependencyCheckCacheSelfTest {

    static func run() -> Bool {
        var ok = true
        checkFirstMountCostIsPaidOnceAcrossThreePages(&ok)
        checkForceRefreshAlwaysBypassesTheCache(&ok)
        checkMaxAgeBoundaryIsHonored(&ok)
        checkConcurrentCallersForTheSameItemAreCoalesced(&ok)
        checkDifferentItemsAreNotCoalescedTogether(&ok)
        checkInvalidateForcesARealRecheck(&ok)
        checkCachedOutcomeNeverTriggersASubprocess(&ok)
        checkAPageVisitSatisfiesTheNextPollerSweep(&ok)
        checkAPollerSweepSatisfiesTheNextPageVisit(&ok)
        checkPollerSweepReportsItsOldestContributingSample(&ok)
        checkPollerWindowCannotBeSatisfiedByThePreviousPollerSweep(&ok)
        checkPollerSweepDoesNotBypassTheSharedCache(&ok)
        print(ok ? "DependencyCheckCacheSelfTest: all checks passed" : "DependencyCheckCacheSelfTest: FAILED")
        DependencyCheckCache.checkOverrideForTests = nil
        return ok
    }


    // MARK: - Fakes

    private static func fakeItem(_ id: String) -> DependencyItem {
        DependencyItem(id: id, name: id, category: "Test", kind: .npmGlobal(package: id))
    }

    private static func fakeOutcome(for id: String) -> CheckOutcome {
        CheckOutcome(installedLabel: "1.0.0", latestLabel: "1.0.0", status: .upToDate, detail: "\(id) is up to date", log: "")
    }

    /// Thread-safe call counter, keyed by item id - a fake stand-in for a
    /// real subprocess spawn that never actually shells out.
    private final class CountingChecker {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        /// Optional artificial delay before returning, so a test can widen
        /// the window a concurrent caller needs to observe an in-flight check.
        var delay: TimeInterval = 0

        func callback(_ item: DependencyItem) -> CheckOutcome {
            lock.lock()
            counts[item.id, default: 0] += 1
            lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return fakeOutcome(for: item.id)
        }

        func count(_ id: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[id] ?? 0
        }

        var totalCount: Int {
            lock.lock(); defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }
    }

    // MARK: The scenario the task exists to fix

    /// Directly mirrors the acceptance criteria: "visiting Updates, then
    /// Bootstrap, then Automation in one session runs the underlying checks
    /// once, not three times." Runs the real `DependencyCatalog.items` (all
    /// 13 of them) through three independent "page visit" sweeps against one
    /// shared cache instance, exactly the shape `UpdatesController.checkAll`/
    /// `BootstrapController.checkAllSoftware`/`AutomationController.
    /// checkAllSoftware` each run on their own first mount.
    private static func checkFirstMountCostIsPaidOnceAcrossThreePages(_ ok: inout Bool) {
        print("\n-- visiting Updates, then Bootstrap, then Automation runs the 13-item sweep once --")
        let checker = CountingChecker()
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let items = DependencyCatalog.items

        func simulatePageVisit() {
            for item in items { _ = cache.check(item, forceRefresh: false) }
        }

        simulatePageVisit() // "Updates" mounts first.
        simulatePageVisit() // "Bootstrap" mounts moments later.
        simulatePageVisit() // "Automation" mounts moments after that.

        if checker.totalCount != items.count {
            fail("expected the real check to run exactly \(items.count) times (once per catalog item across all three page visits), got \(checker.totalCount)", &ok)
        }
        for item in items where checker.count(item.id) != 1 {
            fail("item '\(item.id)' was checked \(checker.count(item.id)) time(s), expected exactly 1", &ok)
        }
    }

    // MARK: Explicit refresh never serves a stale hit

    /// "Each page's explicit refresh/recheck action still does a real, live
    /// check" - `forceRefresh: true` must always run the real check, however
    /// fresh the cache already is, and must leave the cache refreshed with
    /// the new result for the next reader.
    private static func checkForceRefreshAlwaysBypassesTheCache(_ ok: inout Bool) {
        print("\n-- forceRefresh always runs a real check, even immediately after a fresh one --")
        let checker = CountingChecker()
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let item = fakeItem("refresh-target")

        _ = cache.check(item, forceRefresh: false) // warms the cache
        if checker.count(item.id) != 1 {
            fail("the first, unforced check should have run the real check once, got \(checker.count(item.id))", &ok)
        }

        _ = cache.check(item, forceRefresh: false) // should be a pure cache hit
        if checker.count(item.id) != 1 {
            fail("a second unforced check on an already-fresh entry must not re-run the real check, got \(checker.count(item.id))", &ok)
        }

        _ = cache.check(item, forceRefresh: true) // the explicit "Check"/"Refresh" path
        if checker.count(item.id) != 2 {
            fail("forceRefresh must always run a real check regardless of freshness, got \(checker.count(item.id)) total runs", &ok)
        }

        // And the entry it just wrote is what the next unforced reader sees -
        // a forced refresh must not leave the shared cache stale for the
        // other two pages.
        _ = cache.check(item, forceRefresh: false)
        if checker.count(item.id) != 2 {
            fail("the forced refresh should have refreshed the cache for the next unforced reader too, got \(checker.count(item.id)) total runs", &ok)
        }
    }

    // MARK: TTL boundary

    /// A cache entry is only served when it is younger than the caller's
    /// `maxAge`. Tested with a negative `maxAge` rather than a sleep, so this
    /// case is deterministic regardless of how fast the machine running it
    /// is - `elapsed < maxAge` can never hold true once `maxAge` is negative.
    private static func checkMaxAgeBoundaryIsHonored(_ ok: inout Bool) {
        print("\n-- an entry older than maxAge is treated as stale, not served from cache --")
        let checker = CountingChecker()
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let item = fakeItem("ttl-target")

        _ = cache.check(item, forceRefresh: false, maxAge: DependencyCheckCache.defaultTTL)
        if cache.cachedOutcome(for: item, maxAge: DependencyCheckCache.defaultTTL) == nil {
            fail("a just-written entry should be readable via cachedOutcome under the default TTL", &ok)
        }
        if cache.cachedOutcome(for: item, maxAge: -1) != nil {
            fail("a negative maxAge should never consider any entry fresh enough", &ok)
        }

        // An unforced check with a maxAge that treats the fresh entry as
        // stale must fall through to a real check, not silently serve it.
        _ = cache.check(item, forceRefresh: false, maxAge: -1)
        if checker.count(item.id) != 2 {
            fail("a maxAge that rejects the existing entry must trigger a second real check, got \(checker.count(item.id))", &ok)
        }
    }

    // MARK: Coalescing concurrent callers

    /// The real product risk this cache has to close, not just a first-mount
    /// convenience: `UpdatesController`/`BootstrapController`/
    /// `AutomationController` each dispatch their own sweep to
    /// `DispatchQueue.global` on `viewWillAppear`, so two pages mounting
    /// within the same few hundred milliseconds can genuinely race for the
    /// same item with no cache entry yet. Five concurrent callers for the
    /// *same* item, none of them forced, must still trigger exactly one real
    /// check - everyone else waits for and shares that one result.
    private static func checkConcurrentCallersForTheSameItemAreCoalesced(_ ok: inout Bool) {
        print("\n-- five concurrent callers for the same not-yet-cached item share one real check --")
        let checker = CountingChecker()
        checker.delay = 0.2 // wide enough for every concurrent caller below to reach the wait, not just the first.
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let item = fakeItem("coalesce-target")

        let resultsLock = NSLock()
        var results: [CheckOutcome] = []
        DispatchQueue.concurrentPerform(iterations: 5) { _ in
            let outcome = cache.check(item, forceRefresh: false)
            resultsLock.lock()
            results.append(outcome)
            resultsLock.unlock()
        }

        if checker.count(item.id) != 1 {
            fail("expected the real check to run exactly once across 5 concurrent unforced callers, got \(checker.count(item.id))", &ok)
        }
        if results.count != 5 {
            fail("expected all 5 callers to receive a result, got \(results.count)", &ok)
        }
        if results.contains(where: { $0.detail != fakeOutcome(for: item.id).detail }) {
            fail("every concurrent caller should receive the same, correct outcome", &ok)
        }
    }

    /// The coalescing above must key on item id, not just "a check is
    /// running somewhere" - concurrent callers for two *different* items
    /// must not block each other, and each must still get its own real check.
    private static func checkDifferentItemsAreNotCoalescedTogether(_ ok: inout Bool) {
        print("\n-- concurrent callers for different items each get their own real check --")
        let checker = CountingChecker()
        checker.delay = 0.1
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let itemA = fakeItem("distinct-a")
        let itemB = fakeItem("distinct-b")

        DispatchQueue.concurrentPerform(iterations: 2) { i in
            _ = cache.check(i == 0 ? itemA : itemB, forceRefresh: false)
        }

        if checker.count(itemA.id) != 1 {
            fail("item A should have been checked exactly once, got \(checker.count(itemA.id))", &ok)
        }
        if checker.count(itemB.id) != 1 {
            fail("item B should have been checked exactly once, got \(checker.count(itemB.id))", &ok)
        }
    }

    // MARK: invalidate

    private static func checkInvalidateForcesARealRecheck(_ ok: inout Bool) {
        print("\n-- invalidate drops a cached entry so the next unforced read runs a real check --")
        let checker = CountingChecker()
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let item = fakeItem("invalidate-target")

        _ = cache.check(item, forceRefresh: false)
        cache.invalidate(item.id)
        _ = cache.check(item, forceRefresh: false)
        if checker.count(item.id) != 2 {
            fail("invalidate() should have made the next unforced check a real one, got \(checker.count(item.id)) total runs", &ok)
        }
    }

    // MARK: cachedOutcome never triggers a subprocess

    private static func checkCachedOutcomeNeverTriggersASubprocess(_ ok: inout Bool) {
        print("\n-- cachedOutcome is a pure read, never a check --")
        let checker = CountingChecker()
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let item = fakeItem("read-only-target")

        if cache.cachedOutcome(for: item) != nil {
            fail("an empty cache should have nothing to return", &ok)
        }
        if checker.count(item.id) != 0 {
            fail("cachedOutcome must never itself run the real check, got \(checker.count(item.id))", &ok)
        }
    }
    // MARK: The poller shares this sweep too
    //
    // Both directions of the acceptance criteria, driven through the real
    // `BackgroundSignalsPoller.sweepSoftware` with its real
    // `sharedCheckMaxAge` - only the cache instance and the item list are
    // injected, so a regression in the poller's own policy (a wrong maxAge, a
    // reverted direct `UpdatesSource.check`) fails here rather than rendering
    // plausibly and costing 13 subprocesses every quarter hour.

    /// "A page-triggered check followed shortly by a poller sweep does not
    /// re-run the same checks." The page sweeps first at the pages' own
    /// `defaultTTL`; the poller follows moments later at its tighter window
    /// and must find every entry fresh enough.
    private static func checkAPageVisitSatisfiesTheNextPollerSweep(_ ok: inout Bool) {
        print("\n-- a page visit satisfies the poller sweep that follows it --")
        let checker = CountingChecker()
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let items = (1...13).map { fakeItem("poller-after-page-\($0)") }

        for item in items { _ = cache.check(item, forceRefresh: false) } // the captain opens Updates
        let sweep = BackgroundSignalsPoller.sweepSoftware(cache: cache, items: items) // the poller ticks

        if checker.totalCount != items.count {
            fail("expected \(items.count) real checks total (the poller reusing the page's), got \(checker.totalCount)", &ok)
        }
        if sweep.statuses.count != items.count {
            fail("the poller must still get a status for every item, got \(sweep.statuses.count)", &ok)
        }
        // The count alone is not enough, and this is the half that catches the
        // real regression: a poller that went back to calling
        // `UpdatesSource.check` itself never touches the fake, so the count
        // stays at the page's own 13 and the case passes while the bypass is
        // fully reinstated. Asserting the sweep returned *this cache's*
        // outcomes is what distinguishes "reused" from "did its own thing".
        if !sweep.statuses.allSatisfy({ $0 == fakeOutcome(for: "x").status }) {
            fail("the poller's statuses did not come from the shared cache - it answered from somewhere else entirely", &ok)
        }
    }

    /// The other direction, which is what makes this a shared cache rather
    /// than a poller-side optimisation: the poller's own sweep must leave the
    /// entries a page's next unforced mount reads.
    private static func checkAPollerSweepSatisfiesTheNextPageVisit(_ ok: inout Bool) {
        print("\n-- a poller sweep satisfies the page visit that follows it --")
        let checker = CountingChecker()
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let items = (1...13).map { fakeItem("page-after-poller-\($0)") }

        _ = BackgroundSignalsPoller.sweepSoftware(cache: cache, items: items) // the poller ticks first
        // Asserted before the page runs, because that is the actual property:
        // the poller must *populate* the shared cache. Checking only the total
        // afterwards passes vacuously against a poller that wrote nothing -
        // the page would simply run all 13 itself and the count would match.
        for item in items where cache.cachedOutcome(for: item) == nil {
            fail("the poller's sweep left no cache entry for '\(item.id)', so the next page visit pays for it again", &ok)
        }

        for item in items { _ = cache.check(item, forceRefresh: false) } // then the captain opens Updates

        if checker.totalCount != items.count {
            fail("expected \(items.count) real checks total (the page reusing the poller's), got \(checker.totalCount)", &ok)
        }
    }

    /// PR #395's rule, carried across this cache: a publish carries when its
    /// data was **gathered**, and a partly-cached sweep is a mixture of
    /// vintages. Stamping such a sweep `Date()` would claim it is as new as
    /// its newest half, letting it displace a page's genuinely fresher
    /// reading through `acceptsReading` - the exact overwrite bug #395 closed.
    ///
    /// Deterministic without aging the cache: item A is checked, a real
    /// measurable pause follows, then the sweep covers A (a cache hit, sampled
    /// before the pause) and B (a live check, sampled after it). A correct
    /// sweep reports A's timestamp, so the result must land at or before the
    /// pause; the `Date()` bug lands after it.
    private static func checkPollerSweepReportsItsOldestContributingSample(_ ok: inout Bool) {
        print("\n-- a partly-cached poller sweep reports its oldest sample, not the moment it ran --")
        let checker = CountingChecker()
        DependencyCheckCache.checkOverrideForTests = checker.callback
        let cache = DependencyCheckCache()
        let cached = fakeItem("vintage-cached")
        let fresh = fakeItem("vintage-fresh")

        _ = cache.check(cached, forceRefresh: false)
        let afterTheCachedSample = Date()
        Thread.sleep(forTimeInterval: 0.2) // wide enough that the two vintages cannot be confused
        let sweep = BackgroundSignalsPoller.sweepSoftware(cache: cache, items: [cached, fresh])

        if sweep.gatheredAt > afterTheCachedSample {
            fail("""
                the sweep reported gatheredAt \(sweep.gatheredAt.timeIntervalSince(afterTheCachedSample))s                 after its oldest sample - it is claiming cached data is as new as the live half, which is                 what lets a poller pass overwrite a fresher page reading
                """, &ok)
        }
        if checker.count(fresh.id) != 1 {
            fail("the uncached half of the sweep should still have run a real check, got \(checker.count(fresh.id))", &ok)
        }
        if checker.count(cached.id) != 1 {
            fail("the cached half must not have been re-checked, got \(checker.count(cached.id)) runs", &ok)
        }
    }

    /// The load-bearing arithmetic, in the shape `AuditEnergyFixesSelfTest`
    /// already uses for `FleetTaskCache.ttl` vs `FleetNotifier.pollInterval`:
    /// the poller's window must be short enough that **one poller pass can
    /// never be satisfied by the previous poller pass**. The worst case is an
    /// entry written by the last item of a slow sweep, which is only
    /// `pollInterval - passWatchdog` old when the next tick lands - so a
    /// window at or above that silently halves the poller's cadence while
    /// every behavioural case above still passes.
    private static func checkPollerWindowCannotBeSatisfiedByThePreviousPollerSweep(_ ok: inout Bool) {
        print("\n-- the poller's cache window is strictly tighter than its own cadence --")
        let window = BackgroundSignalsPoller.sharedCheckMaxAge
        let headroom = BackgroundSignalsPoller.pollInterval - BackgroundSignalsPoller.passWatchdog
        if window >= headroom {
            fail("""
                BackgroundSignalsPoller.sharedCheckMaxAge (\(window)s) is no longer below                 pollInterval - passWatchdog (\(headroom)s) - a pass that ran up to the watchdog would                 leave entries young enough to satisfy the next tick, so the poller would publish                 15-minute-old data and skip the sweep entirely
                """, &ok)
        }
        if window >= DependencyCheckCache.defaultTTL {
            fail("""
                sharedCheckMaxAge (\(window)s) must stay tighter than the pages' defaultTTL                 (\(DependencyCheckCache.defaultTTL)s); at or above it the poller inherits exactly the                 staleness window the pages accept, which is the cadence-halving case above
                """, &ok)
        }
    }

    /// The wiring half, which no behavioural case can see: `sweepSoftware`
    /// could be perfect and `checkNow` could still call `UpdatesSource.check`
    /// itself, costing the full 13 subprocesses every tick while every
    /// assertion above kept passing. Asserts the poller reaches this cache and
    /// nothing else.
    private static func checkPollerSweepDoesNotBypassTheSharedCache(_ ok: inout Bool) {
        print("\n-- the poller's pass actually goes through the shared cache --")
        guard let dir = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: dir.appendingPathComponent("BackgroundSignalsPoller.swift"),
                                     encoding: .utf8) else {
            print("  NOTE: could not read BackgroundSignalsPoller.swift - skipping the source guard")
            return
        }
        // Comments in that file name `UpdatesSource.check` in order to explain
        // that it is no longer called, so strip whole-line comments first -
        // the same treatment `AuditSecurityFixesSelfTest.read` applies for the
        // same reason.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        if code.contains("UpdatesSource.check(") {
            fail("BackgroundSignalsPoller calls UpdatesSource.check directly again - that is the bypass this fix removed", &ok)
        }
        if !code.contains("cache.checkDated(") {
            fail("sweepSoftware no longer reads through DependencyCheckCache", &ok)
        }
        if !code.contains("maxAge: sharedCheckMaxAge") {
            fail("sweepSoftware no longer passes its own sharedCheckMaxAge - the pages' longer default would halve the poller's cadence", &ok)
        }
        if !code.contains("Self.sweepSoftware()") {
            fail("checkNow no longer calls sweepSoftware, so the pass may be sweeping some other way", &ok)
        }
    }
}

#endif
