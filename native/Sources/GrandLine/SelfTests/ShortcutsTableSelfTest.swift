// Grand Line - native macOS app.
//
// `ShortcutsTable` (T5 and T6 of the Termius-style plan): the table Settings >
// Shortcuts draws, and the conflict detection its recorders ask.
//
// Pure logic: the menu is the one `AppDelegate.buildMenu(installing: false)`
// builds, never installed, and every setting goes through a scratch
// `AppSettings` domain. No window, so this runs in CI's blocking `test` lane;
// the page that draws the table is `SettingsTerminalShortcutsSelfTest`.
//
// Run with:
//   swift build && FM_RUN_SHORTCUTS_TABLE_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ShortcutsTableSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkEveryMenuChordIsListedAndNoneIsInvented,
                      checkTheFixedRowsAreTheMonitorsOwn,
                      checkMenuCharactersBecomePhysicalChords,
                      checkTheShippedDefaultsHaveNoConflicts,
                      checkARecordedClashIsMarkedOnBothSides,
                      checkTheIntendedOverlapsAreNarrow,
                      checkSearchAndFilters] {
            var ok = true
            autoreleasepool { check(&ok) }
            allOK = allOK && ok
        }
        print(allOK ? "ShortcutsTableSelfTest: all checks passed" : "ShortcutsTableSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    static func menu() -> NSMenu { AppDelegate().buildMenu(installing: false) }

    /// A scratch defaults domain, removed afterwards, so a rebinding here
    /// never reaches the shared one.
    static func withScratchSettings(_ body: (AppSettings) -> Void) {
        let suite = "fm.selftest.shortcuts.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        body(AppSettings(defaults: defaults))
    }

    // MARK: Cases

    /// The page is the live menu walk: every menu item with a key equivalent
    /// is a row except the ⌘-digit items folded into the fixed row, and no
    /// menu row exists that the walk did not produce.
    ///
    /// Injection: skip a menu section in `menuRows` and the count comparison
    /// fails.
    private static func checkEveryMenuChordIsListedAndNoneIsInvented(_ ok: inout Bool) {
        print("\n-- T5: the page lists the live menu --")
        let mainMenu = menu()
        let walked = KeyboardShortcutCatalog.menuItems(from: mainMenu).flatMap { section in
            section.items.map { (section.title, $0) }
        }
        check(walked.count > 30, "the fixture menu walked to only \(walked.count) items - the check would be vacuous", &ok)
        let digitItems = walked.filter { _, item in
            item.keyEquivalentModifierMask.intersection(KeyChord.relevantModifierMask) == [.command]
                && Int(item.keyEquivalent).map { (1...9).contains($0) } == true
        }
        withScratchSettings { settings in
            let rows = ShortcutsTable.rows(mainMenu: mainMenu, settings: settings)
            let menuRows = rows.filter { $0.kind == .menu }
            check(menuRows.count == walked.count - digitItems.count,
                  "the page lists \(menuRows.count) menu rows for \(walked.count - digitItems.count) menu chords", &ok)
            for (section, item) in walked where !digitItems.contains(where: { $0.1 === item }) {
                check(menuRows.contains { $0.section == section && $0.title == item.title },
                      "\(section) › \(item.title) is in the menu but not on the page", &ok)
            }
            check(menuRows.allSatisfy { $0.source == "Set by the menu" },
                  "a menu row does not say it is set by the menu (choice C3)", &ok)
            let configurable = rows.compactMap(\.configurable)
            check(Set(configurable.map(\.id)) == Set(ConfigurableShortcut.all.map(\.id)),
                  "the configurable rows are \(configurable.map(\.id)), want every family C3 names", &ok)
        }
        if ok { print("  ok   \(walked.count) menu chords, \(digitItems.count) folded into the ⌘1-⌘9 row") }
    }

    /// The fixed rows are what `TabShortcut.from` answers to, and ⌘1-⌘9 is
    /// one row carrying all nine chords.
    private static func checkTheFixedRowsAreTheMonitorsOwn(_ ok: inout Bool) {
        print("\n-- T5: the fixed rows --")
        let fixed = ShortcutsTable.fixedRows()
        let tabRows = fixed.filter { $0.id != "fixed.modules" && $0.id != "fixed.openFromAnywhere" }
        check(tabRows.count == 5, "the fixed tab table has \(tabRows.count) rows, want ⌘T ⌘D ⌘W ⌘R ⇧⌘R", &ok)
        guard let modules = fixed.first(where: { $0.id == "fixed.modules" }) else {
            fail("there is no ⌘1-⌘9 row", &ok)
            return
        }
        check(modules.chords.count == 9, "the ⌘1-⌘9 row carries \(modules.chords.count) chords", &ok)
        for (index, chord) in modules.chords.enumerated() {
            let digit = "\(index + 1)"
            check(TabShortcut.from(characters: digit, modifiers: chord.modifiers) == .select(index: index),
                  "⌘\(digit) is on the fixed row but the tab table does not answer to it", &ok)
        }
        let global = fixed.first { $0.id == "fixed.openFromAnywhere" }
        check(global?.chords.first.map { $0.keyCode == CompactModeHotkey.gKeyCode } == true,
              "the global row is not CompactModeHotkey's chord", &ok)
        if ok { print("  ok   five tab-table rows, ⌘1-⌘9 as one, and the global hotkey") }
    }

    /// A menu stores a character; a recorder stores a keycode. A shifted
    /// character carries Shift, and Caps Lock never makes two chords differ.
    ///
    /// Injection: drop the `shiftedSymbols` lookup and `"}"` stops being ⇧].
    private static func checkMenuCharactersBecomePhysicalChords(_ ok: inout Bool) {
        print("\n-- T5: menu characters as physical chords --")
        let nextTab = KeyChord(key: 30, [.command, .shift])
        check(ShortcutsTable.chord(keyEquivalent: "}", modifiers: [.command]).map { ShortcutsTable.sameKeys($0, nextTab) } == true,
              "⌘} is not ⇧⌘]", &ok)
        let shiftN = KeyChord(key: 45, [.command, .shift])
        check(ShortcutsTable.chord(keyEquivalent: "N", modifiers: [.command]).map { ShortcutsTable.sameKeys($0, shiftN) } == true,
              "an upper-case N does not carry Shift", &ok)
        check(ShortcutsTable.chord(keyEquivalent: "n", modifiers: [.command, .shift]).map { ShortcutsTable.sameKeys($0, shiftN) } == true,
              "n with ⇧⌘ is not ⇧⌘N", &ok)
        let withCapsLock = KeyChord(keyCode: 45, modifierFlagsRaw: NSEvent.ModifierFlags([.command, .shift, .capsLock]).rawValue,
                                    isModifierOnly: false)
        check(ShortcutsTable.sameKeys(withCapsLock, shiftN), "Caps Lock made two chords different (gotcha (21))", &ok)
        check(!ShortcutsTable.sameKeys(KeyChord(key: 45, [.command]), shiftN), "⌘N and ⇧⌘N compared equal", &ok)
        check(ShortcutsTable.chord(keyEquivalent: "\u{F704}", modifiers: [.command]) == nil,
              "a function key no table covers should give no chord rather than a wrong one", &ok)
        if ok { print("  ok   shifted symbols, upper case, Caps Lock and an unknown key") }
    }

    /// Nothing this app ships collides with anything else it ships.
    private static func checkTheShippedDefaultsHaveNoConflicts(_ ok: inout Bool) {
        print("\n-- T5: the shipped defaults are clash-free --")
        withScratchSettings { settings in
            let rows = ShortcutsTable.rows(mainMenu: menu(), settings: settings)
            let clashing = rows.filter { !$0.conflicts.isEmpty }
            check(clashing.isEmpty, "the shipped defaults clash: \(clashing.map { "\($0.label) vs \($0.conflicts)" })", &ok)
            check(!rows.contains { $0.isChanged }, "a fresh domain reports a changed binding", &ok)
        }
        if ok { print("  ok   no conflicts and nothing changed on a fresh domain") }
    }

    /// The captain puts Split right on ⌘K, which the Edit menu's Search…
    /// owns: both rows say so, Conflicts shows exactly those two, and
    /// Changed shows only the one that moved.
    ///
    /// Injection: drop the `otherIndex` half of `markingConflicts` and the
    /// menu row stops saying it is shared.
    private static func checkARecordedClashIsMarkedOnBothSides(_ ok: inout Bool) {
        print("\n-- T5/T6: a clash is marked on both sides --")
        withScratchSettings { settings in
            let commandK = KeyChord(key: 40, [.command])
            ConfigurableShortcut.terminal(.splitRight).store(commandK, in: settings)
            let rows = ShortcutsTable.rows(mainMenu: menu(), settings: settings)
            guard let split = rows.first(where: { $0.configurable == .terminal(.splitRight) }),
                  let search = rows.first(where: { $0.kind == .menu && $0.chords.contains { ShortcutsTable.sameKeys($0, commandK) } })
            else {
                fail("the fixture has no ⌘K menu row - the check would be vacuous", &ok)
                return
            }
            check(split.conflicts == [search.label], "Split right names \(split.conflicts), want [\(search.label)]", &ok)
            check(search.conflicts == [split.label], "\(search.label) names \(search.conflicts), want [\(split.label)]", &ok)
            let conflicts = ShortcutsTable.visible(rows, filter: .conflicts, search: "")
            check(Set(conflicts.map(\.id)) == [split.id, search.id], "Conflicts shows \(conflicts.map(\.label))", &ok)
            let changed = ShortcutsTable.visible(rows, filter: .changed, search: "")
            check(changed.map(\.id) == [split.id], "Changed shows \(changed.map(\.label)), want only Split right", &ok)
            check(split.source.contains("default"), "a changed row does not say what its default was: \(split.source)", &ok)
            let owners = ShortcutsTable.owners(of: commandK, for: .quickCapture, in: rows)
            check(Set(owners.map(\.id)) == [split.id, search.id],
                  "recording ⌘K for capture names \(owners.map(\.label)), want the menu item and Split right", &ok)
            check(ShortcutsTable.owners(of: commandK, for: .terminal(.splitRight), in: rows).map(\.id) == [search.id],
                  "a row's own binding is reported as a clash with itself", &ok)
        }
        if ok { print("  ok   both sides marked, both filters right, the recorder's owners right") }
    }

    /// The three deliberate overlaps are exempt only for the binding they
    /// belong to: the Go menu's Next Tab is not a clash for the terminal's
    /// next tab, but it is for anything else put on ⇧⌘].
    private static func checkTheIntendedOverlapsAreNarrow(_ ok: inout Bool) {
        print("\n-- T5/T6: the intended overlaps are narrow --")
        withScratchSettings { settings in
            let rows = ShortcutsTable.rows(mainMenu: menu(), settings: settings)
            let nextTab = KeyChord(key: 30, [.command, .shift])
            check(ShortcutsTable.owners(of: nextTab, for: .terminal(.nextTab), in: rows).isEmpty,
                  "the terminal's next tab clashes with the Go menu's, which is by design", &ok)
            let forZoom = ShortcutsTable.owners(of: nextTab, for: .terminal(.zoomPane), in: rows)
            check(forZoom.contains { $0.kind == .menu } && forZoom.contains { $0.configurable == .terminal(.nextTab) },
                  "⇧⌘] for Zoom pane should name the Go menu and Next tab, names \(forZoom.map(\.label))", &ok)
            let capture = KeyChord.quickCaptureDefault
            check(ShortcutsTable.owners(of: capture, for: .quickCapture, in: rows).isEmpty,
                  "quick capture clashes with its own menu fallback", &ok)
            check(!ShortcutsTable.owners(of: capture, for: .dictation, in: rows).isEmpty,
                  "⌥Space for dictation should name capture and its menu item", &ok)
        }
        if ok { print("  ok   exempt for their own binding, a clash for any other") }
    }

    /// Search matches the title, the section and the chord as drawn.
    private static func checkSearchAndFilters(_ ok: inout Bool) {
        print("\n-- T5: search --")
        withScratchSettings { settings in
            let rows = ShortcutsTable.rows(mainMenu: menu(), settings: settings)
            let split = ShortcutsTable.visible(rows, filter: .all, search: "split")
            check(split.count == 3 && split.allSatisfy { $0.isConfigurable },
                  "\"split\" finds \(split.map(\.title)), want the three split rows", &ok)
            check(ShortcutsTable.visible(rows, filter: .all, search: "HOSTS").contains { $0.section == "Hosts" },
                  "search is not case-insensitive over the section", &ok)
            check(ShortcutsTable.visible(rows, filter: .all, search: "\u{2303}\u{2318}").contains { $0.title == "Split right" },
                  "searching ⌃⌘ does not find a ⌃⌘ binding", &ok)
            check(ShortcutsTable.visible(rows, filter: .all, search: "zzz-nothing").isEmpty, "nonsense matched a row", &ok)
            check(ShortcutsTable.visible(rows, filter: .changed, search: "").isEmpty, "Changed is not empty on defaults", &ok)
        }
        if ok { print("  ok   title, section, chord, case and the empty filters") }
    }
}

#endif
