// Grand Line - native macOS app.
//
// P7 of full review #3: the one place a self-test records a check.
//
// # What this replaces
//
// Measured before it existed: **93 hand-rolled `check`/`fail` helpers across 84
// of the 158 files in this directory**, in 13 distinct signatures and 16
// distinct bodies. This project applied "one component, not N copies"
// relentlessly to the UI - `HelmButton`, `ToolRowLayout`, `HelmCard`, each with
// a source guard - and never once to its own test harness.
//
// Two of those signatures took their arguments in the **opposite order** from
// the other eleven (`check(_ name: String, _ condition: Bool)` and
// `fail(_ ok: inout Bool, _ message: String)`), so `check(a, b)` meant
// different things in different files - which is exactly the kind of thing that
// reads fine in review and produces a check nobody notices is backwards.
//
// The 16 bodies also printed four different prefixes (`FAIL:`, ` FAIL `,
// ` FAIL: `, `[host-store-test] FAIL:`), so a full run's output was
// inconsistent about the one line a reader is scanning for.
//
// # The two shapes, and why there are two
//
// The suites accumulate a verdict in one of two ways, and both are legitimate:
//
//   * a `var ok = true` that a check sets false (44 of the 88 bodies), read by
//     `run()`'s `return ok`;
//   * a `var failures: [String]` that a check appends to (34), where the case
//     returns the list so the caller can print every failure together.
//
// Both are served here. Nothing is asked to change its accumulator.
//
// # How a suite uses it
//
// The `inout Bool` shape needs **no call-site change at all**: the two free
// functions below have exactly the signature the dominant hand-rolled helpers
// had, so deleting a local `private static func check(_:_:_:)` leaves every
// existing `check(cond, "msg", &ok)` resolving here instead.
//
// A nested helper that captures a local `ok` cannot be replaced by a free
// function (it has nothing to capture), and a helper that prints on *success*
// or accumulates into an array is doing something the free functions do not.
// Those keep their declaration and **delegate their body** to
// `SelfTestAssertions`, which is what puts the format in one place.
//
// `E2ETestingPolicySelfTest.checkSuitesUseTheSharedAssertions` is the guard: a
// `check`/`fail` helper in this directory must delegate here rather than
// reimplement the three lines. It bans a *copy*, not a thin adapter - which is
// the distinction that matters, since an adapter is the only way to serve a
// captured accumulator.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum SelfTestAssertions {

    /// The one failure line. Every suite's failures read the same way, so a
    /// full run's output can be scanned for a single token.
    static let failurePrefix = "  FAIL "

    /// The one pass line, for the suites that narrate every check rather than
    /// only the failures.
    static let passPrefix = "  OK   "

    static func reportFailure(_ message: String) {
        print("\(failurePrefix)\(message)")
    }

    static func reportPass(_ message: String) {
        print("\(passPrefix)\(message)")
    }

    // MARK: The `var ok = true` accumulator

    /// Records `condition`, printing and clearing `ok` when it does not hold.
    static func record(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        guard !condition else { return }
        reportFailure(message)
        ok = false
    }

    /// An unconditional failure - the `fail(...)` half of the pair.
    static func recordFailure(_ message: String, _ ok: inout Bool) {
        reportFailure(message)
        ok = false
    }

    /// Records `condition` and narrates the pass as well as the failure, for a
    /// suite whose output is a per-check list rather than a verdict.
    static func recordNarrated(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if condition {
            reportPass(message)
        } else {
            reportFailure(message)
            ok = false
        }
    }

    // MARK: The `var failures: [String]` accumulator

    /// Records `condition` into a failure list, which the caller prints or
    /// returns as a whole.
    static func record(_ condition: Bool, _ message: String, into failures: inout [String]) {
        guard !condition else { return }
        failures.append(message)
    }

    /// The same, narrating each check as it goes.
    static func recordNarrated(_ condition: Bool, _ message: String,
                               into failures: inout [String]) {
        if condition {
            reportPass(message)
        } else {
            reportFailure(message)
            failures.append(message)
        }
    }
}

// MARK: Free functions - the zero-migration shape

// These exist so a suite can delete its local helper and change nothing else:
// the signatures are byte-for-byte what the two dominant hand-rolled helpers
// had. A file that still declares its own shadows these, so a migration can be
// done one file at a time without a flag day.

func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
    SelfTestAssertions.record(condition, message, &ok)
}

func fail(_ message: String, _ ok: inout Bool) {
    SelfTestAssertions.recordFailure(message, &ok)
}

#endif
