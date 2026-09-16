// Manjesh Grand Line - native macOS app.
//
// Regression coverage for a real, captain-reported bug on Setup > Updates:
// most rows rendered their status pill with an EMPTY GAP where the
// "Check" button should be, while other rows in the same list rendered the
// button normally. Hovering a bare row made its button appear - so the
// button existed and worked; it was painted transparent at rest.
//
// **Root cause.** `UpdatesController.card(...)` built each row through
// `ReviewPRListView.actionReveal(row:of:)`, D1's discoverability rule:
//
//     (count <= HelmAccentRow.alwaysRevealRowCount || row == 0) ? .always : .onAim
//
// i.e. "a list of three rows or fewer keeps every row's actions, a longer
// one keeps only its first row's". `ToolRowLayout.build` implements `.onAim`
// by setting the action column's `alphaValue = 0` and restoring it on hover
// or focus-within. Applied per CATEGORY CARD against this page's real
// catalog, that resolves to exactly the split the captain photographed:
//
//     npm packages   5 rows  -> tasks-axi visible; gh-axi,
//                               chrome-devtools-axi, lavish-axi and
//                               quota-axi at alpha 0
//     Homebrew       3 rows  -> all three visible
//     Other tools    2 rows  -> both visible
//
// Two treatments for one kind of row, stacked in one scroll view, with
// nothing on screen explaining the difference. It also made Updates the odd
// one out among the five pages sharing `ToolRowLayout` - Bootstrap,
// Automation, GitHub Sync and Vault all take the `.always` default.
//
// Reproduced live before the fix by mounting the real controller and reading
// each row's action-column alpha: rows 1-4 of "npm packages" read 0.00 and
// every other row read 1.00, with `checkButton.isHidden == false` throughout
// - the button present and functional, merely invisible.
//
// **Fix.** This page passes `actionReveal: .always` for every row. D1 is
// untouched where it was approved: `HelmAccentRow`'s own mirror of the
// policy still backs Review's PR list and the Hosts/Keys/Snippets lists.
//
// **Why this suite reads `alphaValue` and not a render.** `cacheDisplay` -
// this repo's screenshot substitute - draws an `alphaValue = 0` view
// visibly (see `HostsListSection`'s own note), so a render cannot see this
// class of bug at all. Nor can an `isHidden` check, for the same reason the
// captain's buttons still worked.
//
// Run with:
//   swift build && FM_RUN_UPDATES_ACTION_VISIBILITY_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum UpdatesActionVisibilitySelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkEveryRowShowsItsActionsAtRest,
                      checkAnUpdateAvailableRowShowsItsUpdateButton,
                      checkTheCheckButtonKeepsItsOwnHoverFeedback,
                      checkThePageDoesNotOptBackIntoHoverReveal] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "UpdatesActionVisibilitySelfTest: all checks passed"
                    : "UpdatesActionVisibilitySelfTest: FAILED")
        return allOK
    }

    // MARK: Fixture

    /// Mounts through `window.contentView`, never `contentViewController`:
    /// the latter fires the appearance callbacks, and this page's
    /// `viewWillAppear` starts real `brew`/`npm` sweeps. `loadView` builds
    /// every category card and row on its own, which is all this needs.
    private static func mount() -> (UpdatesController, NSWindow) {
        let c = UpdatesController()
        let window = OffScreenProbe.window(width: 1100, height: 1400)
        window.contentView = c.view
        c.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 1400)
        c.view.layoutSubtreeIfNeeded()
        return (c, window)
    }

    // MARK: Checks

    /// The captain's own report, as an assertion: every row on the page shows
    /// its action buttons without being hovered.
    private static func checkEveryRowShowsItsActionsAtRest(_ ok: inout Bool) {
        let (c, window) = mount()
        defer { window.contentView = nil }

        let states = c.debugRowActionStates
        guard !states.isEmpty else {
            print("UpdatesActionVisibility: the page built no rows - the check would be vacuous")
            ok = false
            return
        }

        // Discriminating power, asserted before anything else. The bug only
        // bites a category with MORE rows than `alwaysRevealRowCount`; if the
        // catalog ever shrinks so every category is short, the reveal policy
        // could come back and every assertion below would still pass. Fail
        // loudly instead of quietly proving nothing.
        var perCategory: [String: Int] = [:]
        for s in states { perCategory[s.category, default: 0] += 1 }
        let longest = perCategory.max { $0.value < $1.value }
        guard let longest, longest.value > HelmAccentRow.alwaysRevealRowCount else {
            print("""
                  UpdatesActionVisibility: no category has more than \
                  \(HelmAccentRow.alwaysRevealRowCount) rows (longest is \
                  \(longest?.key ?? "none") at \(longest?.value ?? 0)), so this check \
                  cannot tell the fix from the bug - see this file's header
                  """)
            ok = false
            return
        }

        for s in states where s.actionsAlpha < 0.99 || s.checkHidden {
            print("""
                  UpdatesActionVisibility: \(s.name) (\(s.category)) hides its actions at \
                  rest - alpha \(String(format: "%.2f", s.actionsAlpha)), \
                  checkHidden=\(s.checkHidden). This is the captain's report: a status pill \
                  with an empty gap beside it until the row is hovered.
                  """)
            ok = false
        }
        if ok {
            print("""
                  UpdatesActionVisibility: all \(states.count) rows show their actions at rest \
                  (longest category "\(longest.key)" has \(longest.value) rows)
                  """)
        }
    }

    /// The other half of the captain's ask: the Update button, where a real
    /// update is available, is visible at rest too.
    private static func checkAnUpdateAvailableRowShowsItsUpdateButton(_ ok: inout Bool) {
        let (c, window) = mount()
        defer { window.contentView = nil }

        // A row the bug used to hide, so this exercises the fixed path rather
        // than one that always worked.
        let index = c.debugRowActionStates.firstIndex { $0.id == "lavish-axi" } ?? 3
        c.debugSetStatus(.updateAvailable, atRow: index)

        guard let s = c.debugRowActionStates.indices.contains(index)
                ? c.debugRowActionStates[index] : nil else {
            print("UpdatesActionVisibility: no row at \(index)")
            ok = false
            return
        }
        if s.updateHidden || s.actionsAlpha < 0.99 {
            print("""
                  UpdatesActionVisibility: \(s.name) reports .updateAvailable but its Update \
                  button is not visible at rest - hidden=\(s.updateHidden), \
                  alpha \(String(format: "%.2f", s.actionsAlpha))
                  """)
            ok = false
        } else {
            print("UpdatesActionVisibility: an .updateAvailable row shows its Update button at rest")
        }
    }

    /// The fix must not have cost the button its own hover/press feedback -
    /// only the gating that hid it entirely. Drives the real
    /// `HelmButton.mouseEntered`/`mouseExited` and reads the layer back.
    private static func checkTheCheckButtonKeepsItsOwnHoverFeedback(_ ok: inout Bool) {
        let (c, window) = mount()
        defer { window.contentView = nil }

        guard let button = c.debugCheckButton(atRow: 3) else {
            print("UpdatesActionVisibility: no Check button at row 3")
            ok = false
            return
        }
        let rest = button.layer?.backgroundColor
        button.mouseEntered(with: hoverEvent(button))
        button.layer?.removeAllAnimations()
        let hovered = button.layer?.backgroundColor
        button.mouseExited(with: hoverEvent(button))
        button.layer?.removeAllAnimations()
        let restored = button.layer?.backgroundColor

        if sameColor(rest, hovered) {
            print("""
                  UpdatesActionVisibility: the Check button no longer changes on hover \
                  (rest and hover both \(describe(rest))) - the fix was supposed to keep the \
                  button's own feedback and drop only the reveal gating
                  """)
            ok = false
        } else if !sameColor(rest, restored) {
            print("""
                  UpdatesActionVisibility: the Check button did not return to its resting fill \
                  after the cursor left - rest \(describe(rest)), after \(describe(restored))
                  """)
            ok = false
        } else {
            print("UpdatesActionVisibility: the Check button keeps its own hover feedback")
        }
    }

    /// A source guard, because the behavioural check above cannot see every
    /// way this can come back. It reads the page's REAL catalog, so a future
    /// catalog whose every category is short would let the reveal policy
    /// return while every row still happened to render visible.
    private static func checkThePageDoesNotOptBackIntoHoverReveal(_ ok: inout Bool) {
        let path = SelfTestSources.appSourceDirectory()?
            .appendingPathComponent("UpdatesController.swift")
        guard let path, let raw = try? String(contentsOf: path, encoding: .utf8) else {
            print("UpdatesActionVisibility: could not read UpdatesController.swift - skipping source guard")
            return
        }
        // Strip whole-line comments: this file names both tokens on purpose,
        // in the note explaining why it no longer uses them.
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for token in [".onAim", "ReviewPRListView.actionReveal"] where code.contains(token) {
            print("""
                  UpdatesActionVisibility: UpdatesController.swift uses \(token) again. That is \
                  D1's hover-reveal, which the captain reported as broken on this page - see \
                  this file's header before reinstating it.
                  """)
            ok = false
        }
        if ok { print("UpdatesActionVisibility: the page does not opt back into hover-reveal") }
    }

    // MARK: Helpers

    private static func hoverEvent(_ v: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 5, y: 5),
                           modifierFlags: [], timestamp: 0,
                           windowNumber: v.window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    }

    /// Component-wise, deliberately not a luminance ratio - two different
    /// hues of similar brightness pass a ratio check (the trap this codebase
    /// has walked into twice).
    private static func sameColor(_ a: CGColor?, _ b: CGColor?) -> Bool {
        guard let a, let b, let ca = a.components, let cb = b.components,
              ca.count >= 3, cb.count >= 3 else { return a == nil && b == nil }
        return abs(ca[0] - cb[0]) < 0.01 && abs(ca[1] - cb[1]) < 0.01
            && abs(ca[2] - cb[2]) < 0.01 && abs(a.alpha - b.alpha) < 0.01
    }

    private static func describe(_ c: CGColor?) -> String {
        guard let c, let k = c.components, k.count >= 3 else { return "nil" }
        return String(format: "#%02X%02X%02X@%.2f", Int(k[0] * 255), Int(k[1] * 255),
                      Int(k[2] * 255), c.alpha)
    }
}

#endif
