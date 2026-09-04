// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `HerdrConfigPatcher`/
// `HerdrThemeSync` (`fm/grandline-herdr-selection-color-sync`, then
// `fm/grandline-herdr-reload-on-theme-sync`). Three halves:
//
//   1. `HerdrConfigPatcher.apply` against literal fixture strings - pure
//      logic, no disk I/O, covering every insert/replace/abort path the
//      type's own header documents.
//   2. `HerdrThemeSync.syncNow` driven end to end against a real scratch
//      file (`configPathOverrideForTests`) - the actual read/patch/
//      `AtomicWrite` pipeline, never the captain's real
//      `~/.config/herdr/config.toml`.
//   3. The live-reload trigger, driven against a real, disposable FAKE
//      `herdr` script (`herdrExecutablePathOverrideForTests`) that this
//      suite writes to a scratch directory and deletes afterward - never
//      the real installed `herdr` binary. This is what proves `syncNow`
//      actually invokes `server reload-config` (correct argv, only on a
//      changed write) and handles every exit shape (a fast success, a slow
//      success within timeout, a genuine failure, and a real timeout) without
//      crashing or blocking - the Swift-side contract this task's own PR
//      description documents as verified.
//
// Deliberately NOT covered here, and why: the real `herdr` process's own
// live server-reload behaviour (does a running server's selection colour
// genuinely change without a restart) is never driven from this suite.
// `HerdrThemeSync.swift`'s header explains why in full: the sanctioned
// `fm-herdr-lab.sh` helper this task's brief mandated has no verb capable of
// invoking `herdr server reload-config` at all (its `run` verb categorically
// refuses any `server ...` command, confirmed live), and the brief's own
// hard safety contract separately forbids running that command directly,
// even against an isolated lab session. What is tested here is everything
// this task could safely and honestly verify: the file gets patched
// correctly, the reload call is built and dispatched correctly, and neither
// a missing server nor a failing reload call can crash the app or hold up
// the caller.
//
// `swift build && FM_RUN_HERDR_THEME_SYNC_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum HerdrThemeSyncSelfTest {

    static func run() -> Bool {
        var ok = true

        // MARK: - Pure patcher: the common shapes

        // 1. A file with no `[theme]` section at all - the captain's own
        //    real config.toml is exactly this shape. Should create a fresh
        //    `[theme.custom]` table appended at the end, with a blank
        //    separator line before it since the file didn't already end
        //    blank.
        do {
            let original = """
                onboarding = false
                [keys]
                prefix = "ctrl+b"
                """
            guard let result = HerdrConfigPatcher.apply(selectionBgHex: "#6cd7e3", to: original) else {
                check(false, "expected a patch result for a file with no [theme] section", &ok)
                return ok
            }
            check(result.changed, "creating a fresh table should report changed", &ok)
            let expected = """
                onboarding = false
                [keys]
                prefix = "ctrl+b"

                [theme.custom]
                selection_bg = "#6cd7e3"

                """
            check(result.content == expected, "unexpected content for a fresh [theme.custom]:\n\(result.content)", &ok)
        }

        // 2. `[theme.custom]` exists but only has herdr's own commented-out
        //    sample keys - the commented `# selection_bg = "#313244"` line
        //    must be left untouched, and a live key inserted right after the
        //    header, preserving every other key's order.
        do {
            let original = """
                [theme]
                # name = "catppuccin"

                [theme.custom]
                # sidebar_bg = "#181825"
                # selection_bg = "#313244"
                # accent = "#f5c2e7"

                [terminal]
                # default_shell = ""
                """
            guard let result = HerdrConfigPatcher.apply(selectionBgHex: "#007194", to: original) else {
                check(false, "expected a patch result for a table with only commented keys", &ok)
                return ok
            }
            check(result.changed, "inserting into an existing table should report changed", &ok)
            let expected = """
                [theme]
                # name = "catppuccin"

                [theme.custom]
                selection_bg = "#007194"
                # sidebar_bg = "#181825"
                # selection_bg = "#313244"
                # accent = "#f5c2e7"

                [terminal]
                # default_shell = ""
                """
            check(result.content == expected, "unexpected content inserting a live key:\n\(result.content)", &ok)
        }

        // 3. `[theme.custom]` exists with a LIVE `selection_bg` and other
        //    live keys around it - only the value changes, everything else
        //    (including an inline trailing comment on an unrelated line, and
        //    key ordering) is preserved exactly.
        do {
            let original = """
                [theme.custom]
                sidebar_bg = "#181825"
                selection_bg = "#313244"
                accent = "#f5c2e7"  # matches the captain's terminal accent

                [terminal]
                default_shell = ""
                """
            guard let result = HerdrConfigPatcher.apply(selectionBgHex: "#cba6f7", to: original) else {
                check(false, "expected a patch result replacing a live value", &ok)
                return ok
            }
            check(result.changed, "replacing a differing value should report changed", &ok)
            let expected = """
                [theme.custom]
                sidebar_bg = "#181825"
                selection_bg = "#cba6f7"
                accent = "#f5c2e7"  # matches the captain's terminal accent

                [terminal]
                default_shell = ""
                """
            check(result.content == expected, "unexpected content replacing a live value:\n\(result.content)", &ok)
        }

        // 4. An inline trailing comment directly on the selection_bg line
        //    itself is preserved after the value is replaced.
        do {
            let original = #"""
                [theme.custom]
                selection_bg = "#313244" # matches the old dark theme
                """#
            guard let result = HerdrConfigPatcher.apply(selectionBgHex: "#f5c2e7", to: original) else {
                check(false, "expected a patch result preserving a trailing inline comment", &ok)
                return ok
            }
            let expected = #"""
                [theme.custom]
                selection_bg = "#f5c2e7" # matches the old dark theme
                """#
            check(result.content == expected, "trailing comment not preserved:\n\(result.content)", &ok)
        }

        // 5. Already the target value - no-op, byte-identical, changed == false.
        do {
            let original = """
                [theme.custom]
                selection_bg = "#6cd7e3"
                """
            guard let result = HerdrConfigPatcher.apply(selectionBgHex: "#6cd7e3", to: original) else {
                check(false, "expected a patch result for an already-correct value", &ok)
                return ok
            }
            check(!result.changed, "an already-correct value should report changed == false", &ok)
            check(result.content == original, "content should be byte-identical when nothing changed", &ok)
        }

        // 6. The rest of a real, hand-maintained file - the captain's own
        //    `[keys]` table, with many custom bindings and an inline
        //    comment on one line - must survive completely untouched.
        do {
            let original = """
                onboarding = false
                [keys]
                prefix = "ctrl+b"
                focus_pane_left  = "prefix+h"
                copy_mode  = "prefix+y"  # herdr's copy-mode entry key; copy-mode's own internal keys (v/space select, y/Enter copy, q/Esc cancel) aren't configurable
                """
            guard let result = HerdrConfigPatcher.apply(selectionBgHex: "#2aa198", to: original) else {
                check(false, "expected a patch result preserving a real [keys] table", &ok)
                return ok
            }
            check(result.content.contains(original), "the original [keys] table must survive byte-for-byte:\n\(result.content)", &ok)
            check(result.content.contains("[theme.custom]"), "should have added a [theme.custom] table", &ok)
            check(result.content.contains("selection_bg = \"#2aa198\""), "should have set the requested value", &ok)
        }

        // 7. A `selection_bg`-named key inside an unrelated table must never
        //    be touched or mistaken for the one under [theme.custom].
        do {
            let original = """
                [some.other.table]
                selection_bg = "#000000"

                [theme.custom]
                accent = "#f5c2e7"
                """
            guard let result = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: original) else {
                check(false, "expected a patch result with an unrelated selection_bg elsewhere", &ok)
                return ok
            }
            check(result.content.contains("[some.other.table]") && result.content.contains("selection_bg = \"#000000\""),
                  "the unrelated table's own selection_bg must be untouched:\n\(result.content)", &ok)
            check(result.content.contains("[theme.custom]"), "should still find/patch [theme.custom]", &ok)
        }

        // 8. Idempotency: applying twice with the same hex the second time
        //    is a no-op; applying twice with a different hex the second
        //    time updates in place rather than duplicating the key.
        do {
            let original = """
                [keys]
                prefix = "ctrl+b"
                """
            guard let first = HerdrConfigPatcher.apply(selectionBgHex: "#6cd7e3", to: original) else {
                check(false, "expected a first patch result", &ok)
                return ok
            }
            guard let second = HerdrConfigPatcher.apply(selectionBgHex: "#6cd7e3", to: first.content) else {
                check(false, "expected a second patch result", &ok)
                return ok
            }
            check(!second.changed, "re-applying the same value should be a no-op", &ok)
            check(second.content == first.content, "re-applying the same value should not alter content", &ok)

            guard let third = HerdrConfigPatcher.apply(selectionBgHex: "#f5c2e7", to: second.content) else {
                check(false, "expected a third patch result with a different value", &ok)
                return ok
            }
            let occurrences = third.content.components(separatedBy: "selection_bg").count - 1
            check(occurrences == 1, "changing the value must update in place, not duplicate the key (found \(occurrences))", &ok)
            check(third.content.contains("selection_bg = \"#f5c2e7\""), "third patch should hold the new value", &ok)
        }

        // 9. Trailing-newline preservation, both directions, for both the
        //    "replace in place" and "create a fresh table" paths.
        do {
            let noTrailingNewline = "[theme.custom]\nselection_bg = \"#313244\""
            guard let replaced = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: noTrailingNewline) else {
                check(false, "expected a patch result with no trailing newline", &ok)
                return ok
            }
            check(!replaced.content.hasSuffix("\n"), "should not add a trailing newline that wasn't there", &ok)

            let withTrailingNewline = "[theme.custom]\nselection_bg = \"#313244\"\n"
            guard let replaced2 = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: withTrailingNewline) else {
                check(false, "expected a patch result with a trailing newline", &ok)
                return ok
            }
            check(replaced2.content.hasSuffix("\n"), "should preserve an existing trailing newline", &ok)

            let noTheme = "onboarding = false"
            guard let created = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: noTheme) else {
                check(false, "expected a patch result creating a fresh table with no trailing newline in the original", &ok)
                return ok
            }
            check(created.content.hasSuffix("\n"), "a freshly-created table should always end with a newline", &ok)
        }

        // 10. `[theme.custom]` declared with no `[theme]` header at all is
        //     still valid TOML and must still be found.
        do {
            let original = "[theme.custom]\naccent = \"#f5c2e7\""
            guard let result = HerdrConfigPatcher.apply(selectionBgHex: "#6cd7e3", to: original) else {
                check(false, "expected a patch result for a bare [theme.custom] with no [theme] parent", &ok)
                return ok
            }
            check(result.content.contains("selection_bg = \"#6cd7e3\""), "should have inserted the key", &ok)
            check(result.content.contains("accent = \"#f5c2e7\""), "existing accent key should survive", &ok)
        }

        // MARK: - Pure patcher: refusals

        // 11. A triple-quoted multi-line string anywhere in the file - abort.
        do {
            let original = "[theme.custom]\nnote = \"\"\"a\n[theme.custom]\n\"\"\"\nselection_bg = \"#313244\""
            let result = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: original)
            check(result == nil, "a triple-quoted string anywhere should abort, got \(String(describing: result))", &ok)
        }

        // 12. Two `[theme.custom]` headers - ambiguous, abort.
        do {
            let original = "[theme.custom]\naccent = \"#f5c2e7\"\n[theme.custom]\nselection_bg = \"#313244\""
            let result = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: original)
            check(result == nil, "duplicate [theme.custom] headers should abort, got \(String(describing: result))", &ok)
        }

        // 13. Two live `selection_bg` keys in the same table - abort.
        do {
            let original = "[theme.custom]\nselection_bg = \"#111111\"\nselection_bg = \"#222222\""
            let result = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: original)
            check(result == nil, "duplicate live selection_bg keys should abort, got \(String(describing: result))", &ok)
        }

        // 14. A `selection_bg` value that isn't a simple single-line quoted
        //     string (here: a bare unquoted literal) - abort rather than
        //     guess at its shape.
        do {
            let original = "[theme.custom]\nselection_bg = 313244"
            let result = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: original)
            check(result == nil, "an unquoted selection_bg value should abort, got \(String(describing: result))", &ok)
        }

        // 15. A top-level dotted-key assignment starting with "theme" -
        //     the residual-risk idiom this patcher refuses to reason about.
        do {
            let original = "theme.custom.selection_bg = \"#313244\"\n[keys]\nprefix = \"ctrl+b\""
            let result = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: original)
            check(result == nil, "a dotted-key theme assignment should abort, got \(String(describing: result))", &ok)
        }

        // 16. An array-of-tables header must never be mistaken for
        //     `[theme.custom]`, even textually adjacent to it.
        do {
            let original = "[[theme.custom]]\nselection_bg = \"#313244\""
            guard let result = HerdrConfigPatcher.apply(selectionBgHex: "#ffffff", to: original) else {
                check(false, "an [[array.of.tables]] header should not itself abort the whole file", &ok)
                return ok
            }
            // The [[theme.custom]] line is never recognised as a standard
            // table header, so currentPath never becomes ["theme","custom"]
            // and the existing selection_bg line inside it is left alone -
            // a brand-new [theme.custom] table is appended instead.
            check(result.content.contains("[[theme.custom]]\nselection_bg = \"#313244\""),
                  "the array-of-tables block must be left untouched:\n\(result.content)", &ok)
            check(result.content.hasSuffix("[theme.custom]\nselection_bg = \"#ffffff\"\n"),
                  "a real [theme.custom] table should still be created:\n\(result.content)", &ok)
        }

        // MARK: - HerdrThemeSync: end-to-end against a real scratch file

        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-herdr-theme-sync-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let scratchConfig = scratchDir.appendingPathComponent("herdr-config.toml")

        HerdrThemeSync.configPathOverrideForTests = scratchConfig
        defer { HerdrThemeSync.configPathOverrideForTests = nil }

        // A quiet, disposable no-op fake `herdr` covers every case in this
        // whole "end to end" section by default - never the real installed
        // binary, which a machine running this suite may genuinely have on
        // PATH (as this dev machine does). Without this, cases 18 and 20
        // below (both writing a genuinely CHANGED value, which is exactly
        // what now triggers `triggerLiveReload()`) would silently invoke a
        // REAL `herdr server reload-config` against whatever herdr server
        // happens to be live on the machine running this suite - precisely
        // the property `HerdrThemeSync.swift`'s own header explains this
        // task could not, and must not, exercise outside a sanctioned
        // isolation contract this test binary has none of. Cases below that
        // specifically test the reload trigger (21+) temporarily install
        // their own fake script and restore this one afterward.
        let quietFakeHerdrArgvLog = scratchDir.appendingPathComponent("quiet-fake-herdr-argv.log")
        let quietFakeHerdr = writeFakeHerdr(argvLogPath: quietFakeHerdrArgvLog)
        HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path
        defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = nil }

        // 17. "herdr not installed" is a hard no-op: no file is created at all.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = false
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            HerdrThemeSync.shared.syncNow(theme: .dark)
            check(!FileManager.default.fileExists(atPath: scratchConfig.path),
                  "syncNow should not create a config file when herdr is not installed", &ok)
        }

        // 18. "herdr installed", no existing file - creates one holding the
        //     dark theme's own accent, hash-prefixed.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            HerdrThemeSync.shared.syncNow(theme: .dark)
            guard let content = try? String(contentsOf: scratchConfig, encoding: .utf8) else {
                check(false, "expected a config file to exist after syncNow", &ok)
                return ok
            }
            let expectedValue = "\"#\(HelmTheme.dark.accentHex.lowercased())\""
            check(content.contains("[theme.custom]"), "created config should contain [theme.custom]", &ok)
            check(content.contains("selection_bg = \(expectedValue)"),
                  "created config should hold the dark theme's accent, got:\n\(content)", &ok)
        }

        // 19. Re-syncing the same theme is a true no-op on disk - the
        //     file's mtime does not move, proving the write was skipped
        //     rather than silently re-written with identical bytes.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            let attrsBefore = try? FileManager.default.attributesOfItem(atPath: scratchConfig.path)
            let mtimeBefore = attrsBefore?[.modificationDate] as? Date
            // A write's mtime resolution can coincide with "before" if the
            // clock hasn't ticked - sleep a beat so a real second write
            // would be observably later, making this a meaningful check.
            Thread.sleep(forTimeInterval: 1.05)
            HerdrThemeSync.shared.syncNow(theme: .dark)
            let attrsAfter = try? FileManager.default.attributesOfItem(atPath: scratchConfig.path)
            let mtimeAfter = attrsAfter?[.modificationDate] as? Date
            check(mtimeBefore != nil && mtimeAfter != nil && mtimeBefore == mtimeAfter,
                  "re-syncing an unchanged theme must not rewrite the file (mtime before \(String(describing: mtimeBefore)), after \(String(describing: mtimeAfter)))", &ok)
        }

        // 20. Switching to a different theme updates the value in place -
        //     exactly one live selection_bg key, holding the new theme's
        //     accent, with no duplicate table or key left behind.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            HerdrThemeSync.shared.syncNow(theme: .light)
            guard let content = try? String(contentsOf: scratchConfig, encoding: .utf8) else {
                check(false, "expected the config file to still exist after switching themes", &ok)
                return ok
            }
            let expectedValue = "\"#\(HelmTheme.light.accentHex.lowercased())\""
            check(content.contains("selection_bg = \(expectedValue)"),
                  "switching themes should update to the new theme's accent, got:\n\(content)", &ok)
            check(!content.contains("\"#\(HelmTheme.dark.accentHex.lowercased())\"") || HelmTheme.dark.accentHex == HelmTheme.light.accentHex,
                  "the old theme's accent should no longer be present:\n\(content)", &ok)
            let headerCount = content.components(separatedBy: "[theme.custom]").count - 1
            check(headerCount == 1, "should still have exactly one [theme.custom] table, found \(headerCount)", &ok)
            let keyCount = content.components(separatedBy: "selection_bg").count - 1
            check(keyCount == 1, "should still have exactly one selection_bg key, found \(keyCount)", &ok)
        }

        // MARK: - Live reload trigger (fm/grandline-herdr-reload-on-theme-sync)
        //
        // Every case below installs its OWN fake `herdr` for the duration
        // of that case, via `herdrExecutablePathOverrideForTests`, and
        // restores `quietFakeHerdr` afterward - never the real installed
        // binary, and never dependent on a case later in this file
        // accidentally inheriting a script built to answer a different
        // question. See this file's own header, and `HerdrThemeSync.
        // swift`'s, for why the real, live herdr-server-side behaviour
        // (does a running server's own selection colour actually change)
        // could not be verified from this suite or this task at all.

        // 21. A genuinely CHANGED write triggers the reload, with exactly
        //     the argv `HerdrThemeSync.swift`'s header documents - no
        //     `--session`, matching how the captain's own herdr usage has
        //     no session concept in play (E1/`fm/grand-line-remove-
        //     firstmate-mirror`).
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            let argvLog = scratchDir.appendingPathComponent("reload-argv-21.log")
            let fakeHerdr = writeFakeHerdr(argvLogPath: argvLog)
            HerdrThemeSync.herdrExecutablePathOverrideForTests = fakeHerdr.path
            defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path }

            HerdrThemeSync.shared.syncNow(theme: .dark) // .light (from case 20) -> .dark: a real change

            check(waitForFile(argvLog, timeout: 5),
                  "a changed write should trigger the reload script within 5s", &ok)
            let argv = readArgv(argvLog)
            check(argv == ["server", "reload-config"],
                  "reload should be invoked with exactly ['server', 'reload-config'], got \(argv)", &ok)
        }

        // 22. An UNCHANGED write (re-syncing the same theme case 21 just
        //     landed on) must never even attempt a reload. This is provable
        //     with no wait at all - `syncNow`'s own `guard result.changed
        //     else { return }` runs synchronously, before any dispatch to
        //     `Subprocess.runAsync` - but a short, deliberate wait below
        //     still catches it if a future refactor ever moved the reload
        //     call to the wrong side of that guard.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            let argvLog = scratchDir.appendingPathComponent("reload-argv-22.log")
            let fakeHerdr = writeFakeHerdr(argvLogPath: argvLog)
            HerdrThemeSync.herdrExecutablePathOverrideForTests = fakeHerdr.path
            defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path }

            HerdrThemeSync.shared.syncNow(theme: .dark) // unchanged from case 21

            check(confirmFileNeverAppears(argvLog, timeout: 1.5),
                  "an unchanged write must never invoke the reload script", &ok)
        }

        // 23. A reload attempt that fails (herdr's own CLI exits non-zero -
        //     the shape it takes, per this file's own header, when no
        //     server happens to be running) must not crash or block
        //     `syncNow`, and must not affect the config write, which has
        //     already succeeded and remains the durable source of truth
        //     regardless of what the reload attempt does afterward.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            let argvLog = scratchDir.appendingPathComponent("reload-argv-23.log")
            let fakeHerdr = writeFakeHerdr(argvLogPath: argvLog, exitCode: 1)
            HerdrThemeSync.herdrExecutablePathOverrideForTests = fakeHerdr.path
            defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path }

            HerdrThemeSync.shared.syncNow(theme: .light) // .dark (from case 22) -> .light: a real change

            check(waitForFile(argvLog, timeout: 5),
                  "a failing reload script should still have been invoked", &ok)
            guard let content = try? String(contentsOf: scratchConfig, encoding: .utf8) else {
                check(false, "expected the config file to still exist after a failed reload attempt", &ok)
                return ok
            }
            let expectedValue = "\"#\(HelmTheme.light.accentHex.lowercased())\""
            check(content.contains("selection_bg = \(expectedValue)"),
                  "the config write must succeed regardless of the reload outcome, got:\n\(content)", &ok)
        }

        // 24. A reload that succeeds but takes a moment (well inside the
        //     production timeout) must still be genuinely awaited, not
        //     merely fired without ever checking its outcome - proven by a
        //     `doneMarker` the fake script only touches AFTER its own
        //     sleep, so seeing it appear proves the async completion
        //     handler genuinely ran to term, not just that the process was
        //     launched.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            let argvLog = scratchDir.appendingPathComponent("reload-argv-24.log")
            let doneMarker = scratchDir.appendingPathComponent("reload-done-24.marker")
            let fakeHerdr = writeFakeHerdr(argvLogPath: argvLog, sleepSeconds: 1.2, doneMarkerPath: doneMarker)
            HerdrThemeSync.herdrExecutablePathOverrideForTests = fakeHerdr.path
            defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path }

            HerdrThemeSync.shared.syncNow(theme: .dark) // .light (from case 23) -> .dark: a real change

            check(waitForFile(argvLog, timeout: 5), "the slow reload script should still be invoked promptly", &ok)
            check(waitForFile(doneMarker, timeout: 8),
                  "a slow-but-successful reload should still be genuinely awaited to completion", &ok)
        }

        // MARK: - Config path resolution

        // 25. With no override at all, resolves under the home directory to
        //     the exact path herdr's own --help documents.
        do {
            HerdrThemeSync.configPathOverrideForTests = nil
            defer { HerdrThemeSync.configPathOverrideForTests = scratchConfig }
            let originalHerdrEnv = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"]
            unsetenv("HERDR_CONFIG_PATH")
            defer {
                if let originalHerdrEnv { setenv("HERDR_CONFIG_PATH", originalHerdrEnv, 1) }
                else { unsetenv("HERDR_CONFIG_PATH") }
            }
            let resolved = HerdrThemeSync.configPath()
            let expected = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/herdr/config.toml")
            check(resolved == expected, "unexpected default config path: \(resolved.path)", &ok)
        }

        // 26. `HERDR_CONFIG_PATH` (herdr's own documented override) wins
        //     over the default when set and no test override is in play -
        //     this app must write to the exact file herdr itself would read.
        do {
            HerdrThemeSync.configPathOverrideForTests = nil
            defer { HerdrThemeSync.configPathOverrideForTests = scratchConfig }
            let originalHerdrEnv = ProcessInfo.processInfo.environment["HERDR_CONFIG_PATH"]
            setenv("HERDR_CONFIG_PATH", "/tmp/grandline-herdr-selftest-custom-path.toml", 1)
            defer {
                if let originalHerdrEnv { setenv("HERDR_CONFIG_PATH", originalHerdrEnv, 1) }
                else { unsetenv("HERDR_CONFIG_PATH") }
            }
            let resolved = HerdrThemeSync.configPath()
            check(resolved.path == "/tmp/grandline-herdr-selftest-custom-path.toml",
                  "HERDR_CONFIG_PATH should win over the default, got \(resolved.path)", &ok)
        }

        print(ok ? "HerdrThemeSyncSelfTest: all checks passed" : "HerdrThemeSyncSelfTest: FAILED")
        return ok
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("FAIL: \(message)")
            ok = false
        }
    }

    /// A disposable, executable fake `herdr` for the reload-trigger cases
    /// above - never the real installed binary. Records its own argv (one
    /// line per argument, matching how `HerdrThemeSync.triggerLiveReload`
    /// invokes it: `["server", "reload-config"]`) to `argvLogPath`,
    /// optionally sleeps, optionally touches `doneMarkerPath` AFTER
    /// sleeping (so a case can prove the async completion handler genuinely
    /// ran, not merely that the process was launched), then exits with
    /// `exitCode`. Mirrors `DictationCleanupSelfTest.writeFakeClaude`'s
    /// exact convention (temp-dir script, `0o755`, `#!/bin/sh`).
    private static func writeFakeHerdr(
        argvLogPath: URL, sleepSeconds: Double = 0, doneMarkerPath: URL? = nil, exitCode: Int32 = 0
    ) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-herdr-\(UUID().uuidString).sh")
        var script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(argvLogPath.path)\"\n"
        if sleepSeconds > 0 { script += "sleep \(sleepSeconds)\n" }
        if let doneMarkerPath { script += ": > \"\(doneMarkerPath.path)\"\n" }
        script += "exit \(exitCode)\n"
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// Polls (pumping the main run loop rather than blocking on a
    /// semaphore) until `path` exists or `timeout` elapses - the same
    /// `RunLoop.main.run(mode:before:)` convention `DictationCleanupSelfTest.
    /// runRewriteSync`/`ConsoleCommandComposerSelfTest` use to observe an
    /// async `Subprocess.runAsync`/`ClaudeOneShot` completion with no
    /// `NSApplication.run()` loop active yet (`main.swift` calls this suite
    /// before `app.run()`).
    private static func waitForFile(_ path: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path.path) && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// The reverse of `waitForFile`: waits out `timeout` (still pumping the
    /// run loop, so a dispatch that WOULD have fired still gets the chance
    /// to) and confirms the file never appeared.
    private static func confirmFileNeverAppears(_ path: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path.path) { return false }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return !FileManager.default.fileExists(atPath: path.path)
    }

    private static func readArgv(_ path: URL) -> [String] {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

#endif
