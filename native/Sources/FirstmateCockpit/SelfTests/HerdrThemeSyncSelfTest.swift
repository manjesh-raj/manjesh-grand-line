// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `HerdrThemeColors`/
// `HerdrConfigPatcher`/`HerdrThemeSync` (`fm/grandline-herdr-selection-color-sync`,
// then `fm/grandline-herdr-reload-on-theme-sync`, then `fix-herdr-panel-
// follows-grandline-theme` - which widened the whole sync from a single
// `selection_bg` field to `HerdrConfigPatcher.Field`'s full 19-field set -
// then `fix-herdr-theme-sync-regression-706b`, which found the write/patch
// path was never broken and instead corrected a false claim about what a
// successful `server reload-config` call accomplishes). Five halves:
//
//   1. `HerdrConfigPatcher.apply(colors:to:)` against literal fixture
//      strings - pure logic, no disk I/O, covering every insert/replace/
//      abort path the type's own header documents, generalised across
//      multiple fields (not just `selection_bg` any more).
//   2. `HerdrThemeColors.derive(from:)` - the exact `HelmTheme` -> herdr
//      hex mapping, checked field by field for both `.dark` and `.light`
//      so a mis-mapped Swift property (e.g. writing `surfaceDim`'s value
//      under the wrong TOML key) fails loudly.
//   3. `HerdrThemeSync.syncNow` driven end to end against a real scratch
//      file (`configPathOverrideForTests`) - the actual read/patch/
//      `AtomicWrite` pipeline, never the captain's real
//      `~/.config/herdr/config.toml`.
//   4. The live-reload trigger, driven against a real, disposable FAKE
//      `herdr` script (`herdrExecutablePathOverrideForTests`) that this
//      suite writes to a scratch directory and deletes afterward - never
//      the real installed `herdr` binary. This is what proves `syncNow`
//      actually invokes `server reload-config` (correct argv, only on a
//      changed write) and handles every exit shape (a fast success, a slow
//      success within timeout, a genuine failure, and a real timeout) without
//      crashing or blocking. Unaffected by the field-set widening above -
//      the reload mechanism itself did not change in this task, and these
//      cases are here unchanged to prove that.
//   5. `HerdrThemeSync.reloadOutcomeLogMessage(ok:failureSummary:)` - the
//      pure text-building `fix-herdr-theme-sync-regression-706b` split out
//      of `triggerLiveReload`'s completion handler specifically so this
//      claim is pinned rather than only described in a comment: NEITHER
//      outcome (success or failure) may imply an already-open herdr pane's
//      theme colours are now visible with no further captain action, because
//      `server reload-config` cannot reach client-owned presentation
//      settings at all (see `HerdrThemeSync.swift`'s own header for the
//      herdr-documentation evidence). The success branch previously read
//      "herdr theme sync: told the running server to reload config.toml" -
//      true and yet misleading, since it reads as "job done" when an
//      already-open pane's colours had not changed and, per herdr's own
//      docs, categorically could not have from this call alone.
//
// Deliberately NOT covered here, and why: the real `herdr` process's own
// live server-reload behaviour (does a running server's colours genuinely
// change without a restart) is never driven from this suite.
// `HerdrThemeSync.swift`'s header explains why in full: the sanctioned
// `fm-herdr-lab.sh` helper has no verb capable of invoking `herdr server
// reload-config` at all (its `run` verb categorically refuses any
// `server ...` command, confirmed live), and the task's own hard safety
// contract separately forbids running that command directly, even against
// an isolated lab session. What is tested here is everything this task
// could safely and honestly verify: the file gets patched correctly for
// every field herdr's own `[theme.custom]` table accepts, the mapping from
// each `HelmTheme` token to the right herdr field is correct, the reload
// call is built and dispatched correctly, neither a missing server nor a
// failing reload call can crash the app or hold up the caller, and neither
// outcome's own log text overstates what that call actually achieved.
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

        // MARK: - HerdrThemeColors fixtures

        /// Every field defaulted to its own uniquely identifiable placeholder
        /// hex (so a fixture leaving a field unspecified is easy to tell
        /// apart from one under active test), with named overrides for
        /// whichever field(s) a given scenario is actually exercising.
        func colors(
            panelBg: String = "#100001", sidebarBg: String = "#100002", activeRowBg: String = "#100003",
            selectionBg: String = "#100004", accent: String = "#100005", surface0: String = "#100006",
            surface1: String = "#100007", surfaceDim: String = "#100008", overlay0: String = "#100009",
            overlay1: String = "#10000a", text: String = "#10000b", subtext0: String = "#10000c",
            mauve: String = "#10000d", green: String = "#10000e", yellow: String = "#10000f",
            red: String = "#100010", blue: String = "#100011", teal: String = "#100012", peach: String = "#100013"
        ) -> HerdrThemeColors {
            HerdrThemeColors(
                panelBg: panelBg, sidebarBg: sidebarBg, activeRowBg: activeRowBg,
                selectionBg: selectionBg, accent: accent, surface0: surface0, surface1: surface1,
                surfaceDim: surfaceDim, overlay0: overlay0, overlay1: overlay1, text: text,
                subtext0: subtext0, mauve: mauve, green: green, yellow: yellow, red: red,
                blue: blue, teal: teal, peach: peach)
        }

        /// The exact `Field.allCases` declaration order this patcher writes
        /// a brand-new table in.
        let canonicalOrder = HerdrConfigPatcher.Field.allCases

        // MARK: - Pure patcher: the common shapes

        // 1. A file with no `[theme]` section at all - the captain's own
        //    real config.toml is exactly this shape. Should create a fresh
        //    `[theme.custom]` table appended at the end, holding all 19
        //    fields in the canonical order, with a blank separator line
        //    before it since the file didn't already end blank.
        do {
            let original = """
                onboarding = false
                [keys]
                prefix = "ctrl+b"
                """
            let c = colors()
            guard let result = HerdrConfigPatcher.apply(colors: c, to: original) else {
                check(false, "expected a patch result for a file with no [theme] section", &ok)
                return ok
            }
            check(result.changed, "creating a fresh table should report changed", &ok)
            var expected = "onboarding = false\n[keys]\nprefix = \"ctrl+b\"\n\n[theme.custom]\n"
            for field in canonicalOrder {
                expected += "\(field.tomlKey) = \"\(field.value(in: c))\"\n"
            }
            check(result.content == expected, "unexpected content for a fresh [theme.custom]:\n\(result.content)", &ok)
        }

        // 2. `[theme.custom]` exists but only has herdr's own commented-out
        //    sample keys - every commented sample line must be left
        //    untouched, and all 19 live keys inserted right after the
        //    header, preserving the commented lines' own order.
        do {
            let original = """
                [theme]
                # name = "catppuccin"

                [theme.custom]
                # sidebar_bg = "#181825"
                # active_row_bg = "#1e1e2e"
                # selection_bg = "#313244"
                # accent = "#f5c2e7"

                [terminal]
                # default_shell = ""
                """
            let c = colors()
            guard let result = HerdrConfigPatcher.apply(colors: c, to: original) else {
                check(false, "expected a patch result for a table with only commented keys", &ok)
                return ok
            }
            check(result.changed, "inserting into an existing table should report changed", &ok)
            for field in canonicalOrder {
                check(result.content.contains("\(field.tomlKey) = \"\(field.value(in: c))\""),
                      "missing/incorrect live value for \(field.tomlKey):\n\(result.content)", &ok)
            }
            check(result.content.contains("# sidebar_bg = \"#181825\""), "commented sample must survive:\n\(result.content)", &ok)
            check(result.content.contains("[terminal]\n# default_shell = \"\""), "[terminal] table must survive untouched:\n\(result.content)", &ok)
            // The live block lands right after the header, ahead of the
            // pre-existing commented samples.
            check(result.content.contains("[theme.custom]\naccent = \"\(c.accent)\""),
                  "live keys should be inserted immediately after the header:\n\(result.content)", &ok)
        }

        // 3. `[theme.custom]` exists with THREE live keys whose values
        //    DIFFER from desired, one carrying an inline trailing comment -
        //    only those three change, in place, preserving the comment; the
        //    other 16 missing fields are inserted; a sibling [terminal]
        //    table survives byte-for-byte.
        do {
            let original = """
                [theme.custom]
                sidebar_bg = "#181825"
                selection_bg = "#313244"
                accent = "#f5c2e7"  # matches the captain's terminal accent

                [terminal]
                default_shell = ""
                """
            let c = colors(sidebarBg: "#207020", selectionBg: "#307030", accent: "#407040")
            guard let result = HerdrConfigPatcher.apply(colors: c, to: original) else {
                check(false, "expected a patch result replacing live values", &ok)
                return ok
            }
            check(result.changed, "replacing differing values should report changed", &ok)
            check(result.content.contains("sidebar_bg = \"#207020\""), "sidebar_bg should be replaced:\n\(result.content)", &ok)
            check(result.content.contains("selection_bg = \"#307030\""), "selection_bg should be replaced:\n\(result.content)", &ok)
            check(result.content.contains("accent = \"#407040\"  # matches the captain's terminal accent"),
                  "accent should be replaced while preserving its inline comment:\n\(result.content)", &ok)
            check(result.content.contains("[terminal]\ndefault_shell = \"\""), "[terminal] table must survive untouched:\n\(result.content)", &ok)
            let alreadyReplaced: Set<HerdrConfigPatcher.Field> = [.sidebarBg, .selectionBg, .accent]
            for field in canonicalOrder where !alreadyReplaced.contains(field) {
                check(result.content.contains("\(field.tomlKey) = \"\(field.value(in: c))\""),
                      "missing inserted value for \(field.tomlKey):\n\(result.content)", &ok)
                let occurrences = result.content.components(separatedBy: "\(field.tomlKey) =").count - 1
                check(occurrences == 1, "\(field.tomlKey) should appear exactly once, found \(occurrences)", &ok)
            }
        }

        // 4. Already every target value - no-op, byte-identical, changed == false.
        do {
            let c = colors()
            var original = "[theme.custom]\n"
            for field in canonicalOrder { original += "\(field.tomlKey) = \"\(field.value(in: c))\"\n" }
            original.removeLast() // no trailing newline, so this also exercises that path
            guard let result = HerdrConfigPatcher.apply(colors: c, to: original) else {
                check(false, "expected a patch result for an already-correct table", &ok)
                return ok
            }
            check(!result.changed, "an already-correct table should report changed == false", &ok)
            check(result.content == original, "content should be byte-identical when nothing changed", &ok)
        }

        // 5. The rest of a real, hand-maintained file - the captain's own
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
            let c = colors()
            guard let result = HerdrConfigPatcher.apply(colors: c, to: original) else {
                check(false, "expected a patch result preserving a real [keys] table", &ok)
                return ok
            }
            check(result.content.contains(original), "the original [keys] table must survive byte-for-byte:\n\(result.content)", &ok)
            check(result.content.contains("[theme.custom]"), "should have added a [theme.custom] table", &ok)
            check(result.content.contains("accent = \"\(c.accent)\""), "should have set the requested accent", &ok)
        }

        // 6. A same-named key inside an UNRELATED table must never be
        //    touched or mistaken for the one under [theme.custom] -
        //    checked for two different fields, not just selection_bg.
        do {
            let original = """
                [some.other.table]
                text = "#000000"
                red = "#111111"

                [theme.custom]
                accent = "#f5c2e7"
                """
            let c = colors()
            guard let result = HerdrConfigPatcher.apply(colors: c, to: original) else {
                check(false, "expected a patch result with unrelated same-named keys elsewhere", &ok)
                return ok
            }
            check(result.content.contains("[some.other.table]\ntext = \"#000000\"\nred = \"#111111\""),
                  "the unrelated table's own text/red must be untouched:\n\(result.content)", &ok)
            check(result.content.contains("text = \"\(c.text)\""), "should still set the real text field:\n\(result.content)", &ok)
            check(result.content.contains("red = \"\(c.red)\""), "should still set the real red field:\n\(result.content)", &ok)
        }

        // 7. Idempotency: re-applying the SAME colours is a no-op; applying
        //    a DIFFERENT set updates in place rather than duplicating any key.
        do {
            let original = """
                [keys]
                prefix = "ctrl+b"
                """
            let first = colors()
            guard let firstResult = HerdrConfigPatcher.apply(colors: first, to: original) else {
                check(false, "expected a first patch result", &ok)
                return ok
            }
            guard let secondResult = HerdrConfigPatcher.apply(colors: first, to: firstResult.content) else {
                check(false, "expected a second patch result", &ok)
                return ok
            }
            check(!secondResult.changed, "re-applying the same colours should be a no-op", &ok)
            check(secondResult.content == firstResult.content, "re-applying the same colours should not alter content", &ok)

            let second = colors(accent: "#ff0000", peach: "#00ff00")
            guard let thirdResult = HerdrConfigPatcher.apply(colors: second, to: secondResult.content) else {
                check(false, "expected a third patch result with different colours", &ok)
                return ok
            }
            check(thirdResult.changed, "changing values should report changed", &ok)
            for field in canonicalOrder {
                let occurrences = thirdResult.content.components(separatedBy: "\(field.tomlKey) =").count - 1
                check(occurrences == 1, "\(field.tomlKey) must appear exactly once, found \(occurrences)", &ok)
            }
            check(thirdResult.content.contains("accent = \"#ff0000\""), "accent should hold the new value", &ok)
            check(thirdResult.content.contains("peach = \"#00ff00\""), "peach should hold the new value", &ok)
        }

        // 8. Trailing-newline preservation, both directions, for both the
        //    "replace in place" and "create a fresh table" paths.
        do {
            let c = colors()
            let noTrailingNewline = "[theme.custom]\naccent = \"#111111\""
            guard let replaced = HerdrConfigPatcher.apply(colors: c, to: noTrailingNewline) else {
                check(false, "expected a patch result with no trailing newline", &ok)
                return ok
            }
            check(!replaced.content.hasSuffix("\n"), "should not add a trailing newline that wasn't there", &ok)

            let withTrailingNewline = "[theme.custom]\naccent = \"#111111\"\n"
            guard let replaced2 = HerdrConfigPatcher.apply(colors: c, to: withTrailingNewline) else {
                check(false, "expected a patch result with a trailing newline", &ok)
                return ok
            }
            check(replaced2.content.hasSuffix("\n"), "should preserve an existing trailing newline", &ok)

            let noTheme = "onboarding = false"
            guard let created = HerdrConfigPatcher.apply(colors: c, to: noTheme) else {
                check(false, "expected a patch result creating a fresh table with no trailing newline in the original", &ok)
                return ok
            }
            check(created.content.hasSuffix("\n"), "a freshly-created table should always end with a newline", &ok)
        }

        // 9. `[theme.custom]` declared with no `[theme]` header at all is
        //    still valid TOML and must still be found - and an already-
        //    correct existing key inside it must not be duplicated.
        do {
            let c = colors()
            let original = "[theme.custom]\naccent = \"\(c.accent)\""
            guard let result = HerdrConfigPatcher.apply(colors: c, to: original) else {
                check(false, "expected a patch result for a bare [theme.custom] with no [theme] parent", &ok)
                return ok
            }
            let occurrences = result.content.components(separatedBy: "accent =").count - 1
            check(occurrences == 1, "accent should appear exactly once, found \(occurrences)", &ok)
            for field in canonicalOrder where field != .accent {
                check(result.content.contains("\(field.tomlKey) = \"\(field.value(in: c))\""),
                      "missing inserted value for \(field.tomlKey):\n\(result.content)", &ok)
            }
        }

        // 10. An unrecognised key inside `[theme.custom]` (some hypothetical
        //     future field this app does not manage) is left completely
        //     untouched and never causes an abort, whatever shape its value
        //     takes.
        do {
            let original = """
                [theme.custom]
                accent = "#f5c2e7"
                totally_unknown_future_field = rgb(1,2,3)
                """
            let c = colors()
            guard let result = HerdrConfigPatcher.apply(colors: c, to: original) else {
                check(false, "an unrecognised key should never cause an abort", &ok)
                return ok
            }
            check(result.content.contains("totally_unknown_future_field = rgb(1,2,3)"),
                  "the unrecognised key must survive untouched:\n\(result.content)", &ok)
            check(result.content.contains("accent = \"\(c.accent)\""), "accent should still be replaced:\n\(result.content)", &ok)
        }

        // MARK: - Pure patcher: refusals

        // 11. A triple-quoted multi-line string anywhere in the file - abort.
        do {
            let original = "[theme.custom]\nnote = \"\"\"a\n[theme.custom]\n\"\"\"\naccent = \"#313244\""
            let result = HerdrConfigPatcher.apply(colors: colors(), to: original)
            check(result == nil, "a triple-quoted string anywhere should abort, got \(String(describing: result))", &ok)
        }

        // 12. Two `[theme.custom]` headers - ambiguous, abort.
        do {
            let original = "[theme.custom]\naccent = \"#f5c2e7\"\n[theme.custom]\ntext = \"#313244\""
            let result = HerdrConfigPatcher.apply(colors: colors(), to: original)
            check(result == nil, "duplicate [theme.custom] headers should abort, got \(String(describing: result))", &ok)
        }

        // 13. Two live occurrences of the SAME known field - here deliberately
        //     NOT selection_bg, to prove the guard is general - must abort.
        do {
            let original = "[theme.custom]\ntext = \"#111111\"\ntext = \"#222222\""
            let result = HerdrConfigPatcher.apply(colors: colors(), to: original)
            check(result == nil, "duplicate live occurrences of a known field should abort, got \(String(describing: result))", &ok)
        }

        // 14. A known field's value that isn't a simple single-line quoted
        //     string (here: a different field than selection_bg, an
        //     unquoted bare literal) - abort rather than guess at its shape.
        do {
            let original = "[theme.custom]\npeach = fab387"
            let result = HerdrConfigPatcher.apply(colors: colors(), to: original)
            check(result == nil, "an unquoted known-field value should abort, got \(String(describing: result))", &ok)
        }

        // 15. A top-level dotted-key assignment starting with "theme" -
        //     the residual-risk idiom this patcher refuses to reason about.
        do {
            let original = "theme.custom.selection_bg = \"#313244\"\n[keys]\nprefix = \"ctrl+b\""
            let result = HerdrConfigPatcher.apply(colors: colors(), to: original)
            check(result == nil, "a dotted-key theme assignment should abort, got \(String(describing: result))", &ok)
        }

        // 16. An array-of-tables header must never be mistaken for
        //     `[theme.custom]`, even textually adjacent to it - a real
        //     table is still created for all 19 fields, and the
        //     array-of-tables block is left completely untouched.
        do {
            let original = "[[theme.custom]]\nselection_bg = \"#313244\""
            let c = colors()
            guard let result = HerdrConfigPatcher.apply(colors: c, to: original) else {
                check(false, "an [[array.of.tables]] header should not itself abort the whole file", &ok)
                return ok
            }
            check(result.content.contains("[[theme.custom]]\nselection_bg = \"#313244\""),
                  "the array-of-tables block must be left untouched:\n\(result.content)", &ok)
            for field in canonicalOrder {
                check(result.content.contains("\(field.tomlKey) = \"\(field.value(in: c))\""),
                      "a real [theme.custom] table should still be created holding \(field.tomlKey):\n\(result.content)", &ok)
            }
        }

        // MARK: - HerdrThemeColors.derive(from:): the field-by-field mapping

        // 17. Every field maps to the correct TOML key, for both a dark and
        //     a light theme - proven by driving the real end-to-end
        //     HerdrThemeSync.syncNow (which is what would actually catch a
        //     typo'd Swift field name written under the wrong TOML key).
        //     See the "HerdrThemeSync: end-to-end" section below (case 20)
        //     for the exhaustive per-field assertion.

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
        // PATH (as this dev machine does). Without this, cases below that
        // write a genuinely CHANGED value (which now triggers
        // `triggerLiveReload()`) would silently invoke a REAL `herdr server
        // reload-config` against whatever herdr server happens to be live on
        // the machine running this suite - precisely the property
        // `HerdrThemeSync.swift`'s own header explains this task could not,
        // and must not, exercise outside a sanctioned isolation contract
        // this test binary has none of. Cases below that specifically test
        // the reload trigger install their own fake script and restore this
        // one afterward.
        let quietFakeHerdrArgvLog = scratchDir.appendingPathComponent("quiet-fake-herdr-argv.log")
        let quietFakeHerdr = writeFakeHerdr(argvLogPath: quietFakeHerdrArgvLog)
        HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path
        defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = nil }

        // 18. "herdr not installed" is a hard no-op: no file is created at all.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = false
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            HerdrThemeSync.shared.syncNow(theme: .dark)
            check(!FileManager.default.fileExists(atPath: scratchConfig.path),
                  "syncNow should not create a config file when herdr is not installed", &ok)
        }

        // 19. "herdr installed", no existing file - creates one holding
        //     EVERY field, exhaustively checked against
        //     `HerdrThemeColors.derive(from: .dark)` - this is the case
        //     that actually catches a mis-mapped Swift field (e.g. a value
        //     written under the wrong TOML key, or a swapped mapping
        //     between two fields).
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            HerdrThemeSync.shared.syncNow(theme: .dark)
            guard let content = try? String(contentsOf: scratchConfig, encoding: .utf8) else {
                check(false, "expected a config file to exist after syncNow", &ok)
                return ok
            }
            check(content.contains("[theme.custom]"), "created config should contain [theme.custom]", &ok)
            let expected = HerdrThemeColors.derive(from: .dark)
            for field in canonicalOrder {
                let line = "\(field.tomlKey) = \"\(field.value(in: expected))\""
                check(content.contains(line), "created config should hold \(line), got:\n\(content)", &ok)
            }
            // A spot-check that the derivation is actually doing something
            // theme-specific, not just echoing one literal everywhere.
            check(expected.panelBg != expected.sidebarBg,
                  "panel_bg and sidebar_bg should be distinct tokens, both got \(expected.panelBg)", &ok)
            check(expected.accent == expected.selectionBg,
                  "accent and selection_bg should match (accentHex == selectionHex in every shipped palette)", &ok)
        }

        // 20. Re-syncing the same theme is a true no-op on disk - the
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

        // 21. Switching to a different theme updates every field in place -
        //     exactly one live occurrence per field, holding the new
        //     theme's derived colours, with no duplicate table or key left
        //     behind.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            HerdrThemeSync.shared.syncNow(theme: .light)
            guard let content = try? String(contentsOf: scratchConfig, encoding: .utf8) else {
                check(false, "expected the config file to still exist after switching themes", &ok)
                return ok
            }
            let expected = HerdrThemeColors.derive(from: .light)
            for field in canonicalOrder {
                let line = "\(field.tomlKey) = \"\(field.value(in: expected))\""
                check(content.contains(line), "switching themes should update \(field.tomlKey), got:\n\(content)", &ok)
                let occurrences = content.components(separatedBy: "\(field.tomlKey) =").count - 1
                check(occurrences == 1, "\(field.tomlKey) should appear exactly once after switching, found \(occurrences)", &ok)
            }
            let headerCount = content.components(separatedBy: "[theme.custom]").count - 1
            check(headerCount == 1, "should still have exactly one [theme.custom] table, found \(headerCount)", &ok)
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
        // (does a running server's own colours actually change) could not
        // be verified from this suite or this task at all. Unaffected by
        // the field-set widening above - this mechanism is unchanged.

        // 22. A genuinely CHANGED write triggers the reload, with exactly
        //     the argv `HerdrThemeSync.swift`'s header documents - no
        //     `--session`, matching how the captain's own herdr usage has
        //     no session concept in play (E1/`fm/grand-line-remove-
        //     firstmate-mirror`).
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            let argvLog = scratchDir.appendingPathComponent("reload-argv-22.log")
            let fakeHerdr = writeFakeHerdr(argvLogPath: argvLog)
            HerdrThemeSync.herdrExecutablePathOverrideForTests = fakeHerdr.path
            defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path }

            HerdrThemeSync.shared.syncNow(theme: .dark) // .light (from case 21) -> .dark: a real change

            check(waitForFile(argvLog, timeout: 5),
                  "a changed write should trigger the reload script within 5s", &ok)
            let argv = readArgv(argvLog)
            check(argv == ["server", "reload-config"],
                  "reload should be invoked with exactly ['server', 'reload-config'], got \(argv)", &ok)
        }

        // 23. An UNCHANGED write (re-syncing the same theme case 22 just
        //     landed on) must never even attempt a reload. This is provable
        //     with no wait at all - `syncNow`'s own `guard result.changed
        //     else { return }` runs synchronously, before any dispatch to
        //     `Subprocess.runAsync` - but a short, deliberate wait below
        //     still catches it if a future refactor ever moved the reload
        //     call to the wrong side of that guard.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            let argvLog = scratchDir.appendingPathComponent("reload-argv-23.log")
            let fakeHerdr = writeFakeHerdr(argvLogPath: argvLog)
            HerdrThemeSync.herdrExecutablePathOverrideForTests = fakeHerdr.path
            defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path }

            HerdrThemeSync.shared.syncNow(theme: .dark) // unchanged from case 22

            check(confirmFileNeverAppears(argvLog, timeout: 1.5),
                  "an unchanged write must never invoke the reload script", &ok)
        }

        // 24. A reload attempt that fails (herdr's own CLI exits non-zero -
        //     the shape it takes, per this file's own header, when no
        //     server happens to be running) must not crash or block
        //     `syncNow`, and must not affect the config write, which has
        //     already succeeded and remains the durable source of truth
        //     regardless of what the reload attempt does afterward.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            let argvLog = scratchDir.appendingPathComponent("reload-argv-24.log")
            let fakeHerdr = writeFakeHerdr(argvLogPath: argvLog, exitCode: 1)
            HerdrThemeSync.herdrExecutablePathOverrideForTests = fakeHerdr.path
            defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path }

            HerdrThemeSync.shared.syncNow(theme: .light) // .dark (from case 23) -> .light: a real change

            check(waitForFile(argvLog, timeout: 5),
                  "a failing reload script should still have been invoked", &ok)
            guard let content = try? String(contentsOf: scratchConfig, encoding: .utf8) else {
                check(false, "expected the config file to still exist after a failed reload attempt", &ok)
                return ok
            }
            let expected = HerdrThemeColors.derive(from: .light)
            check(content.contains("accent = \"\(expected.accent)\""),
                  "the config write must succeed regardless of the reload outcome, got:\n\(content)", &ok)
        }

        // 25. A reload that succeeds but takes a moment (well inside the
        //     production timeout) must still be genuinely awaited, not
        //     merely fired without ever checking its outcome - proven by a
        //     `doneMarker` the fake script only touches AFTER its own
        //     sleep, so seeing it appear proves the async completion
        //     handler genuinely ran to term, not just that the process was
        //     launched.
        do {
            HerdrThemeSync.herdrInstalledOverrideForTests = true
            defer { HerdrThemeSync.herdrInstalledOverrideForTests = nil }
            let argvLog = scratchDir.appendingPathComponent("reload-argv-25.log")
            let doneMarker = scratchDir.appendingPathComponent("reload-done-25.marker")
            let fakeHerdr = writeFakeHerdr(argvLogPath: argvLog, sleepSeconds: 1.2, doneMarkerPath: doneMarker)
            HerdrThemeSync.herdrExecutablePathOverrideForTests = fakeHerdr.path
            defer { HerdrThemeSync.herdrExecutablePathOverrideForTests = quietFakeHerdr.path }

            HerdrThemeSync.shared.syncNow(theme: .dark) // .light (from case 24) -> .dark: a real change

            check(waitForFile(argvLog, timeout: 5), "the slow reload script should still be invoked promptly", &ok)
            check(waitForFile(doneMarker, timeout: 8),
                  "a slow-but-successful reload should still be genuinely awaited to completion", &ok)
        }

        // MARK: - Config path resolution

        // 26. With no override at all, resolves under the home directory to
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

        // 27. `HERDR_CONFIG_PATH` (herdr's own documented override) wins
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

        // MARK: - Reload outcome messaging (fix-herdr-theme-sync-regression-706b)
        //
        // `HerdrThemeSync.reloadOutcomeLogMessage(ok:failureSummary:)` is
        // pure text, so it's asserted directly rather than by intercepting a
        // real `os.Logger` call (which has no test-observable return value).
        // The property under test is the one this task's whole investigation
        // was about: neither outcome may claim or imply an already-open
        // herdr pane's colours are now visible with no further captain
        // action - `server reload-config` cannot reach client-owned
        // presentation settings, confirmed against herdr's own published
        // docs (`HerdrThemeSync.swift`'s header has the full evidence).

        // 28. A successful reload's message must name the captain's own
        //     remaining action (`prefix+shift+r`, the literal keybinding the
        //     original false claim named as made unnecessary) AND must
        //     explicitly say the client/theme side is untouched by this
        //     call. Both are required together on purpose: the OLD text
        //     ("herdr theme sync: told the running server to reload
        //     config.toml") would slip past a check that only looked for
        //     the substring "reload config", since "reload config.toml"
        //     contains it coincidentally - confirmed live by reverting to
        //     that exact old wording and finding a "reload config"-only
        //     check still passed. `prefix+shift+r` never appears anywhere
        //     in the old wording, so it is what actually discriminates.
        do {
            let message = HerdrThemeSync.reloadOutcomeLogMessage(ok: true, failureSummary: nil)
            check(message.contains("prefix+shift+r"),
                  "a successful reload's message must name the captain's own prefix+shift+r reload action, got:\n\(message)", &ok)
            check(message.lowercased().contains("client-owned") || message.lowercased().contains("does not reach"),
                  "a successful reload's message must say the client/theme side is not reached by this call, got:\n\(message)", &ok)
            check(!message.lowercased().contains("without the captain") &&
                  !message.lowercased().contains("no further action") &&
                  !message.lowercased().contains("nothing further"),
                  "a successful reload's message must not claim no captain action remains, got:\n\(message)", &ok)
        }

        // 29. A failed reload's message must not claim the (unreachable)
        //     client-side theme half either - the failure path can't
        //     accidentally overstate what a SUCCESSFUL call would have done.
        //     Same discriminating marker as case 28, for the same reason.
        do {
            let message = HerdrThemeSync.reloadOutcomeLogMessage(ok: false, failureSummary: "server unavailable")
            check(message.contains("server unavailable"), "the failure reason should appear verbatim, got:\n\(message)", &ok)
            check(message.contains("prefix+shift+r"),
                  "a failed reload's message should still point at the captain's own prefix+shift+r reload action, got:\n\(message)", &ok)
            check(!message.lowercased().contains("colours are now") && !message.lowercased().contains("colours are visible"),
                  "a failed reload's message must not claim the pane's colours changed, got:\n\(message)", &ok)
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
