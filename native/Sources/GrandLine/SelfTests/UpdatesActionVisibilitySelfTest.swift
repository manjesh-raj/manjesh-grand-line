// Grand Line - native macOS app.
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
// **First fix.** This page passed `actionReveal: .always` for every row.
//
// **What replaced it (UI-43, the UI/UX revamp the captain approved).** A
// 13-row page with a pill, a button and a chevron on every row is 39 controls
// at rest. The revamp keeps what the captain's report was about - **one
// treatment for every row on the page, never a split by category** - and
// changes what that treatment is:
//
//   - the rule is decided once per page (`ToolRowLayout.actionReveal(
//     forPageRowCount:)`), never per category;
//   - a row whose status asks the captain to act (an update available, a
//     failure) keeps its button at rest - the "Update button visible at rest"
//     half of the original ask, kept as an assertion below;
//   - a row with nothing to do shows its status as a dot and a word, and its
//     quiet "Check" appears on hover or keyboard focus.
//
// So an action is visible exactly where the status beside it is a pill,
// which is the explanation the original split lacked.
//
// **Why this suite reads `alphaValue` and not a render.** `cacheDisplay` -
// this repo's screenshot substitute - draws an `alphaValue = 0` view
// visibly (AGENTS.md's "Verifying native UI bugs" rules), so a render cannot see this
// class of bug at all. Nor can an `isHidden` check, for the same reason the
// captain's buttons still worked.
//
// **P-03 of the 2026-11-25 review removed the floating-bar layout**, and with
// it the category cards and their per-row buttons this suite was written
// against - the alpha rule, the per-category split and the hover reveal had
// no rows left to apply to. The page is one Tools table now, whose rows carry
// one action each (`HelmDataTable.Row.primary`). What is still true, and
// still asserted here, is the needs-password case: such a row offers Run in
// Terminal rather than an Update that would only ask again, and a timed-out
// update offers Update again and never shows `SIGTERM`. U10's
// one-action-per-state rule is `ReviewUIUXSelfTest`'s.
//
// Run with:
//   swift build && FM_RUN_UPDATES_ACTION_VISIBILITY_TESTS=1 \
//     .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum UpdatesActionVisibilitySelfTest {

    static func run() -> Bool {
        var ok = true
        checkANeedsPasswordRowOffersTheTerminalNotUpdate(&ok)
        print(ok ? "UpdatesActionVisibilitySelfTest: all checks passed"
                 : "UpdatesActionVisibilitySelfTest: FAILED")
        return ok
    }

    // MARK: Fixture

    /// Mounts through `window.contentView`, never `contentViewController`:
    /// the latter fires the appearance callbacks, and this page's
    /// `viewWillAppear` starts real `brew`/`npm` sweeps.
    private static func mount() -> (UpdatesController, NSWindow) {
        let c = UpdatesController()
        let window = OffScreenProbe.window(width: 1100, height: 1400)
        window.contentView = c.view
        c.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 1400)
        c.view.layoutSubtreeIfNeeded()
        return (c, window)
    }

    /// The table row for `id`, as the page last rendered it.
    private static func tableRow(_ c: UpdatesController, id: String) -> HelmDataTable.Row? {
        c.debugToolRows.first { $0.key == id }
    }

    private static func words(_ cell: HelmDataTable.Cell?) -> String {
        switch cell {
        case .status(let text, _)?, .muted(let text)?, .text(let text)?, .code(let text)?: return text
        case .title(_, let subtitle, _, _, _, _)?: return subtitle ?? ""
        default: return ""
        }
    }

    // MARK: Checks

    /// An update that needs the captain's `sudo` password is not started in
    /// the background (`BrewCaskSudo`). Its row has to say so and offer the
    /// command in a terminal instead of an Update that would just ask again -
    /// and a timed-out update must offer Update again and never show the
    /// child's `Error: SIGTERM`. Both go through the real completion path
    /// (`debugApplyFailedUpdate` -> `apply`), and the action through the
    /// row's own `primary`, whose Console request is captured rather than
    /// run: running it would open a Console tab and re-check against the
    /// real `brew`.
    private static func checkANeedsPasswordRowOffersTheTerminalNotUpdate(_ ok: inout Bool) {
        let (c, window) = mount()
        defer { window.contentView = nil }
        let id = "automic-vault"
        guard let index = c.rows.firstIndex(where: { $0.item.id == id }) else {
            print("UpdatesActionVisibility: the catalog has no \(id) row - the check would be vacuous")
            ok = false
            return
        }
        let command = "brew upgrade --cask automic-vault/isotopes/automic-vault"

        c.debugApplyFailedUpdate(UpdateOutcome(
            ok: false, newVersionLabel: nil,
            detail: UpdateFailureText.needsPasswordDetail(command: command),
            log: UpdateFailureText.needsPasswordLog(command: command, reasons: ["probe"]),
            terminalCommand: command), atRow: index)
        guard let needs = tableRow(c, id: id) else {
            print("UpdatesActionVisibility: no table row for \(id)")
            ok = false
            return
        }
        if needs.primary?.title != "Run in Terminal" {
            print("UpdatesActionVisibility: a needs-password row must offer Run in Terminal, not "
                  + "\(needs.primary?.title ?? "nothing")")
            ok = false
        }
        if words(needs.cells["available"]) != "Needs password" || !needs.pinsPrimary {
            print("UpdatesActionVisibility: a needs-password row reads \"\(words(needs.cells["available"]))\" "
                  + "with its action \(needs.pinsPrimary ? "pinned" : "only on hover")")
            ok = false
        }

        var asked: (label: String, command: String)?
        c.onRunCommandTracked = { label, command, _ in asked = (label, command) }
        needs.primary?.run()
        if asked?.command != command {
            print("UpdatesActionVisibility: Run in Terminal asked the Console for "
                  + "\(asked?.command ?? "nothing") - expected \(command)")
            ok = false
        }

        // A timeout is a retryable failure: Update back, terminal gone, and
        // no raw signal name anywhere the captain reads first.
        c.debugApplyFailedUpdate(UpdateOutcome(
            ok: false, newVersionLabel: nil,
            detail: UpdateFailureText.timedOutDetail(command: "brew upgrade automic-vault/isotopes/automic-vault"),
            log: "probe"), atRow: index)
        guard let timedOut = tableRow(c, id: id) else {
            ok = false
            return
        }
        let line = words(timedOut.cells["tool"])
        if timedOut.primary?.title != "Update" || words(timedOut.cells["available"]) != StateWord.updateFailed.label
            || line.contains("SIGTERM") || line.isEmpty {
            print("UpdatesActionVisibility: a timed-out row must offer Update again and say why - "
                  + "action \(timedOut.primary?.title ?? "none"), status \"\(words(timedOut.cells["available"]))\", "
                  + "line \"\(line)\"")
            ok = false
        }
        if ok { print("UpdatesActionVisibility: a needs-password row offers Run in Terminal, a timed-out one offers Update") }
    }
}

#endif
