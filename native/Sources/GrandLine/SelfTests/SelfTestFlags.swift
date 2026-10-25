// Grand Line - native macOS app.
//
// R2-SEC-09: what `main.swift` treats as a suite flag nobody answered.
//
// The redirect block in `main.swift` arms on any `FM_RUN_` key, and every
// real suite block below it `exit()`s. So a process that reaches the end of
// those blocks with any `FM_RUN_` key still set was started as a test and
// named no suite - a typo (`FM_RUN_CONTRAST=1`), a wrong value
// (`FM_RUN_CONTRAST_TESTS=yes`) or a stale flag. It must exit 2 there, never
// fall through to the single-instance guard, which activates the captain's
// running app and exits 0 - a pass, by the runner's reading.
//
// Pure, so `SecretBoundariesSelfTest` can assert the rule without ever
// starting a process that could reach the real app.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum SelfTestFlags {
    /// Every `FM_RUN_*` key in `environment`, whatever its suffix or value.
    static func unknownSuiteFlags(in environment: [String: String]) -> [String] {
        environment.keys.filter { $0.hasPrefix("FM_RUN_") }.sorted()
    }
}

#endif
