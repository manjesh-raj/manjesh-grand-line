// Grand Line - native macOS app.
//
// The pure half of terminal keyword highlighting (T1): which runs of a row's
// text match, what colour each class resolves to in every palette, and what a
// stored settings value decodes to. Run with:
//
//   swift build && FM_RUN_TERMINAL_KEYWORD_MATCHER_TESTS=1 .build/debug/GrandLine; echo $?
//
// Headless on purpose: nothing here needs a window. The window-backed half -
// that the colours actually reach a drawn row, and never the buffer - is
// `TerminalKeywordHighlightSelfTest`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum TerminalKeywordMatcherSelfTest {

    static func run() -> Bool {
        print("TerminalKeywordMatcherSelfTest")
        var ok = true
        checkBuiltInWords(&ok)
        checkWordBoundaries(&ok)
        checkAddresses(&ok)
        checkTheAddressPreCheck(&ok)
        checkDisabledClasses(&ok)
        checkColoursInEveryPalette(&ok)
        checkSettingsDecoding(&ok)
        print(ok ? "TerminalKeywordMatcherSelfTest: all checks passed"
                 : "TerminalKeywordMatcherSelfTest: FAILURES")
        return ok
    }

    private static let all = KeywordMatcher(classes: Set(KeywordHighlightClass.allCases))

    /// The matched substrings and their classes, in order.
    private static func matched(_ text: String, by matcher: KeywordMatcher = all) -> [(String, KeywordHighlightClass)] {
        let units = Array(text.utf16)
        return matcher.matches(in: units).map { match in
            let piece = String(utf16CodeUnits: Array(units[match.range]), count: match.range.count)
            switch match.slot {
            case .builtIn(let cls): return (piece, cls)
            }
        }
    }

    private static func describe(_ list: [(String, KeywordHighlightClass)]) -> String {
        list.map { "\($0.0)=\($0.1.rawValue)" }.joined(separator: ", ")
    }

    // MARK: Words

    private static func checkBuiltInWords(_ ok: inout Bool) {
        let line = "2026-10-26 ERROR db: connection Refused, retrying; Warning: deprecated flag. OK done INFO debug"
        let got = matched(line)
        let expected: [(String, KeywordHighlightClass)] = [
            ("ERROR", .error), ("Refused", .error), ("retrying", .warning), ("Warning", .warning),
            ("deprecated", .warning), ("OK", .ok), ("done", .ok), ("INFO", .info), ("debug", .debug),
        ]
        check(got.map(\.0) == expected.map(\.0) && got.map(\.1) == expected.map(\.1),
              "a mixed log line matched [\(describe(got))], expected [\(describe(expected))]", &ok)

        // Every built-in word must actually be reachable by the packed scan.
        // A word over 16 bytes or with a non-word character would silently
        // never match, and nothing else would notice.
        for cls in KeywordHighlightClass.allCases {
            for word in cls.words {
                let hit = matched("x \(word.uppercased()) y")
                check(hit.count == 1 && hit.first?.1 == cls,
                      "built-in \(cls.rawValue) word \"\(word)\" is not matched by the scan (got [\(describe(hit))])",
                      &ok)
            }
        }
    }

    private static func checkWordBoundaries(_ ok: inout Bool) {
        // Each of these contains a keyword as a substring and must not match.
        for text in ["terror", "errorcode", "error_code", "error2", "informal", "okay_then", "_debug",
                     "deprecatedly", "passedthrough"] {
            let got = matched(text)
            check(got.isEmpty, "\"\(text)\" matched [\(describe(got))]; a keyword must match as a whole word only", &ok)
        }
        // And these are whole words with punctuation around them.
        for (text, word) in [("[error]", "error"), ("error:", "error"), ("(FAILED)", "FAILED"),
                             ("non-fatal", "fatal"), ("\u{2014}ok\u{2014}", "ok")] {
            let got = matched(text)
            check(got.map(\.0) == [word], "\"\(text)\" matched [\(describe(got))], expected \(word)", &ok)
        }
    }

    // MARK: Addresses

    private static func checkAddresses(_ ok: inout Bool) {
        let positives: [(String, String)] = [
            ("from 192.168.1.20 port 22", "192.168.1.20"),
            ("addr:10.0.0.1:8080", "10.0.0.1"),
            ("route 10.20.0.0/16 via", "10.20.0.0/16"),
            ("end of sentence 8.8.8.8.", "8.8.8.8"),
            ("ether 3c:22:fb:91:0a:7e txq", "3c:22:fb:91:0a:7e"),
            ("hw 3C-22-FB-91-0A-7E", "3C-22-FB-91-0A-7E"),
            ("inet6 fe80::1c2a:3bff:fe4d:12 scope", "fe80::1c2a:3bff:fe4d:12"),
            ("dst 2001:0db8:0000:0000:0000:ff00:0042:8329 ok?", "2001:0db8:0000:0000:0000:ff00:0042:8329"),
            ("listen [::1]:443", "::1"),
        ]
        for (text, address) in positives {
            let got = matched(text).filter { $0.1 == .address }.map(\.0)
            check(got == [address], "\"\(text)\" matched addresses \(got), expected [\(address)]", &ok)
        }
        let negatives = [
            "at 10:15:03.123 the job ran",       // a timestamp
            "version 1.2.3 released",            // a version
            "2026-10-26T10:15:03Z",              // an ISO date
            "build 1.2.3.4.5",                   // too many groups
            "999.1.1.1",                         // not an octet
            "std::vector<int> and Foo::Bar",     // C++ / Ruby scope
            "3c:22:fb:91:0a",                    // five groups is not a MAC
            "sha 3c22fb910a7e",                  // no separators
        ]
        for text in negatives {
            let got = matched(text).filter { $0.1 == .address }.map(\.0)
            check(got.isEmpty, "\"\(text)\" matched addresses \(got); it is not an address", &ok)
        }
    }

    /// The pattern must not run on rows that cannot hold an address. This is
    /// the half of T1's performance budget a correctness test cannot see: a
    /// timestamp's colons reaching the regex on every log line still matches
    /// nothing, and costs a regex per row.
    private static func checkTheAddressPreCheck(_ ok: inout Bool) {
        let before = KeywordMatcher.debugAddressPatternRuns
        for text in ["2026-10-26T10:15:03.123Z INFO request completed in 12ms",
                     "Compiling GrandLine v1.2.3 (debug)",
                     "pod web-7f9c-abcd restarted"] {
            _ = matched(text)
        }
        let quiet = KeywordMatcher.debugAddressPatternRuns - before
        check(quiet == 0, "\(quiet) rows with no possible address still reached the address pattern", &ok)

        let beforeHit = KeywordMatcher.debugAddressPatternRuns
        _ = matched("GET / from 10.1.2.3")
        check(KeywordMatcher.debugAddressPatternRuns - beforeHit == 1,
              "a row holding an IPv4 address never reached the address pattern; the pre-check is too strict", &ok)
    }

    private static func checkDisabledClasses(_ ok: inout Bool) {
        let noErrors = KeywordMatcher(classes: Set(KeywordHighlightClass.allCases).subtracting([.error, .address]))
        let got = matched("ERROR at 10.0.0.1, retrying", by: noErrors)
        check(got.map(\.0) == ["retrying"],
              "with Error and IP & MAC switched off, matched [\(describe(got))]; expected only retrying", &ok)
        check(KeywordMatcher(classes: []).isEmpty, "a matcher with no classes should report itself empty", &ok)
    }

    // MARK: Colours

    /// Every class, in every palette, clears the text floor against the
    /// terminal's real cell background - and where the theme's own ANSI colour
    /// already does, it is used unchanged.
    private static func checkColoursInEveryPalette(_ ok: inout Bool) {
        check(HelmTheme.allThemes.count >= 26,
              "only \(HelmTheme.allThemes.count) palettes; the sweep below would not cover all 26", &ok)
        var unchanged = 0
        for theme in HelmTheme.allThemes {
            let background = TerminalKeywordHighlighter.terminalBackground(theme)
            let palette = theme.terminalCard?.ansiHex ?? theme.ansiHex
            for cls in KeywordHighlightClass.allCases {
                let color = TerminalKeywordHighlighter.resolvedColor(for: cls, settings: .defaults, theme: theme)
                let ratio = HelmContrast.ratio(color, background)
                check(ratio >= HelmContrast.textTarget - 0.01,
                      "\(theme.id) \(cls.rawValue) measures \(String(format: "%.2f", ratio)):1 on the terminal background",
                      &ok)
                let raw = HelmTheme.nsColor(palette[cls.defaultANSIIndex])
                if HelmContrast.ratio(raw, background) >= HelmContrast.textTarget {
                    let a = HelmContrast.components(raw)
                    let b = HelmContrast.components(color)
                    check(abs(a.0 - b.0) < 0.001 && abs(a.1 - b.1) < 0.001 && abs(a.2 - b.2) < 0.001,
                          "\(theme.id) \(cls.rawValue): the theme colour already clears the floor but was changed",
                          &ok)
                    unchanged += 1
                }
            }
        }
        // Discriminating power: the "unchanged" branch above must actually run.
        check(unchanged > 20, "only \(unchanged) class colours were used unchanged across every palette; "
              + "the identity check above barely ran", &ok)

        // A custom colour with no contrast at all is corrected, not used.
        var settings = KeywordHighlightSettings.defaults
        let dusk = HelmTheme.dusk
        let bgHex = dusk.terminalCard?.backgroundHex ?? dusk.backgroundHex
        settings[.error] = KeywordHighlightClassSetting(enabled: true, color: .custom(bgHex))
        let corrected = TerminalKeywordHighlighter.resolvedColor(for: .error, settings: settings, theme: dusk)
        check(HelmContrast.ratio(corrected, TerminalKeywordHighlighter.terminalBackground(dusk)) >= HelmContrast.textTarget - 0.01,
              "a custom colour equal to the terminal background was not corrected for contrast", &ok)
    }

    // MARK: Storage

    private static func checkSettingsDecoding(_ ok: inout Bool) {
        func decode(_ json: String) -> KeywordHighlightSettings? {
            try? JSONDecoder().decode(KeywordHighlightSettings.self, from: Data(json.utf8))
        }
        // GL-01: an empty object, an unknown class and an unknown colour kind
        // all decode, and keep what they can.
        check(decode("{}") == .defaults, "an empty stored value does not decode to the defaults", &ok)
        let future = decode("""
            {"enabled": false, "classes": {"error": {"enabled": false}, "fromTheFuture": {"enabled": true},
             "info": {"color": {"gradient": "x"}}}, "somethingNew": 1}
            """)
        check(future != nil, "a value written by a newer build does not decode at all (GL-01)", &ok)
        if let future {
            check(future.enabled == false, "the stored master switch was not kept", &ok)
            check(future[.error].enabled == false, "the stored Error class switch was not kept", &ok)
            check(future[.warning] == KeywordHighlightClassSetting(), "an absent class did not fall back to its default", &ok)
        }

        // Round trip through the real store. In an `FM_RUN_*` process
        // `AppDefaults.store` is this process's own domain, never the
        // captain's preferences.
        let store = AppSettings.shared
        let saved = store.terminalHighlighting
        defer { store.terminalHighlighting = saved }
        var settings = KeywordHighlightSettings.defaults
        settings.enabled = false
        settings[.debug] = KeywordHighlightClassSetting(enabled: false, color: .ansi(13))
        store.terminalHighlighting = settings
        check(store.terminalHighlighting == settings, "the highlight settings do not survive a write and read", &ok)
    }
}

#endif
