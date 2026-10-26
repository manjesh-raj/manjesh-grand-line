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
// visibly (see `HostsListSection`'s own note), so a render cannot see this
// class of bug at all. Nor can an `isHidden` check, for the same reason the
// captain's buttons still worked.
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
        var allOK = true
        for check in [checkEveryRowFollowsOneRule,
                      checkAnUpdateAvailableRowShowsItsUpdateButton,
                      checkAQuietRowRevealsItsCheckOnHover,
                      checkTheCheckButtonKeepsItsOwnHoverFeedback,
                      checkThePageDecidesTheRuleOnce,
                      checkANeedsPasswordRowOffersTheTerminalNotUpdate] {
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

    /// An update that needs the captain's `sudo` password is not started in
    /// the background (`BrewCaskSudo`). Its row has to say so and offer the
    /// command in a terminal instead of an Update that would just ask again -
    /// and a timed-out update must keep its Update and never show the child's
    /// `Error: SIGTERM`. Both go through the real completion path
    /// (`debugApplyFailedUpdate` -> `apply`), and the button through a real
    /// `performClick`, whose closure is captured rather than run: running it
    /// would open a Console tab and re-check against the real `brew`.
    private static func checkANeedsPasswordRowOffersTheTerminalNotUpdate(_ ok: inout Bool) {
        let (c, window) = mount()
        defer { window.contentView = nil }
        let index = c.debugRowActionStates.firstIndex { $0.id == "automic-vault" } ?? 0
        let command = "brew upgrade --cask automic-vault/isotopes/automic-vault"

        c.debugApplyFailedUpdate(UpdateOutcome(
            ok: false, newVersionLabel: nil,
            detail: UpdateFailureText.needsPasswordDetail(command: command),
            log: UpdateFailureText.needsPasswordLog(command: command, reasons: ["probe"]),
            terminalCommand: command), atRow: index)
        guard let needs = c.debugRowButtons(atRow: index), let needsPill = c.debugPillPaint(atRow: index) else {
            print("UpdatesActionVisibility: no row at \(index)")
            ok = false
            return
        }
        if needs.runInTerminal.isHidden || !needs.update.isHidden {
            print("UpdatesActionVisibility: a needs-password row must show Run in Terminal and hide Update - "
                  + "runInTerminal hidden \(needs.runInTerminal.isHidden), update hidden \(needs.update.isHidden)")
            ok = false
        }
        if needsPill.text != "Needs Password" || !needs.detail.contains(command) {
            print("UpdatesActionVisibility: a needs-password row reads \"\(needsPill.text)\" / \"\(needs.detail)\"")
            ok = false
        }
        if c.debugRowActionStates[index].actionsAlpha < 0.99 {
            print("UpdatesActionVisibility: a needs-password row must keep its action visible at rest")
            ok = false
        }

        var asked: (label: String, command: String)?
        c.onRunCommandTracked = { label, command, _ in asked = (label, command) }
        needs.runInTerminal.performClick(nil)
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
        guard let timedOut = c.debugRowButtons(atRow: index), let timedOutPill = c.debugPillPaint(atRow: index) else {
            ok = false
            return
        }
        if timedOut.update.isHidden || !timedOut.runInTerminal.isHidden || timedOutPill.text != "Update Failed"
            || timedOut.detail.contains("SIGTERM") || !timedOut.detail.hasPrefix("Stopped after") {
            print("UpdatesActionVisibility: a timed-out row must offer Update again and say it was stopped - "
                  + "update hidden \(timedOut.update.isHidden), runInTerminal hidden \(timedOut.runInTerminal.isHidden), "
                  + "pill \"\(timedOutPill.text)\", detail \"\(timedOut.detail)\"")
            ok = false
        }
        if ok { print("UpdatesActionVisibility: a needs-password row offers Run in Terminal, a timed-out one offers Update") }
    }

    /// The captain's own report, as an assertion: no split by category.
    /// Every row in the same state has the same action treatment, whichever
    /// card it sits in - here, every not-yet-checked row reveals on aim.
    private static func checkEveryRowFollowsOneRule(_ ok: inout Bool) {
        let (c, window) = mount()
        defer { window.contentView = nil }

        let states = c.debugRowActionStates
        guard !states.isEmpty else {
            print("UpdatesActionVisibility: the page built no rows - the check would be vacuous")
            ok = false
            return
        }

        // Discriminating power, asserted before anything else. The original
        // bug only bit a category with MORE rows than `alwaysRevealRowCount`
        // beside one with fewer; without both, a per-category rule and a
        // per-page rule would render identically and this would prove nothing.
        var perCategory: [String: Int] = [:]
        for s in states { perCategory[s.category, default: 0] += 1 }
        let longest = perCategory.max { $0.value < $1.value }
        let shortest = perCategory.min { $0.value < $1.value }
        guard let longest, let shortest, longest.value > HelmAccentRow.alwaysRevealRowCount,
              shortest.value <= HelmAccentRow.alwaysRevealRowCount else {
            print("""
                  UpdatesActionVisibility: the catalog no longer has both a long and a short \
                  category (longest \(longest?.value ?? 0), shortest \(shortest?.value ?? 0)), so this \
                  check cannot tell a per-page rule from the per-category bug - see this file's header
                  """)
            ok = false
            return
        }

        let alphas = Set(states.map { ($0.actionsAlpha * 100).rounded() })
        if alphas.count != 1 {
            print("""
                  UpdatesActionVisibility: rows in one state render \(alphas.count) different action \
                  treatments at rest (\(states.map { "\($0.name)=\(String(format: "%.2f", $0.actionsAlpha))" })) - \
                  the split the captain reported
                  """)
            ok = false
        }
        for s in states where s.checkHidden {
            print("UpdatesActionVisibility: \(s.name) has no Check button at all")
            ok = false
        }
        if ok {
            print("""
                  UpdatesActionVisibility: all \(states.count) rows share one treatment at rest \
                  ("\(longest.key)" has \(longest.value) rows, "\(shortest.key)" \(shortest.value))
                  """)
        }
    }

    /// The quiet half: a row with nothing to do still offers its Check, on
    /// the real hover path (`HoverHighlightView.mouseEntered`), not a helper.
    private static func checkAQuietRowRevealsItsCheckOnHover(_ ok: inout Bool) {
        let (c, window) = mount()
        defer { window.contentView = nil }
        guard let container = c.debugRowContainer(atRow: 3) else {
            print("UpdatesActionVisibility: no row at 3")
            ok = false
            return
        }
        // Reduce Motion pinned on, so the reveal lands synchronously - the
        // eased fade reports its old alpha until the animation completes.
        let savedMotion = HelmMotion.reducedOverrideForTests
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = savedMotion }
        let rest = c.debugRowActionStates[3].actionsAlpha
        container.mouseEntered(with: hoverEvent(container))
        let aimed = c.debugRowTrailingStack(atRow: 3)?.alphaValue ?? -1
        container.mouseExited(with: hoverEvent(container))
        if rest > 0.01 || aimed < 0.99 {
            print("""
                  UpdatesActionVisibility: a quiet row should hide its Check at rest and show it \
                  on hover - rest \(String(format: "%.2f", rest)), hovered \(String(format: "%.2f", aimed))
                  """)
            ok = false
        } else {
            print("UpdatesActionVisibility: a quiet row reveals its Check on hover")
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

    /// A source guard: the rule is the page-wide one, never the per-row
    /// `ReviewPRListView.actionReveal(row:of:)` that produced the split.
    private static func checkThePageDecidesTheRuleOnce(_ ok: inout Bool) {
        // R2-ARCH-04: the card rows are the floating bar's presentation, so
        // they live in `UpdatesController+Classic.swift`; the page is both files.
        let dir = SelfTestSources.appSourceDirectory()
        let texts = ["UpdatesController.swift", "UpdatesController+Classic.swift"].map { name in
            dir.flatMap { try? String(contentsOf: $0.appendingPathComponent(name), encoding: .utf8) }
        }
        guard let main = texts[0], let classic = texts[1] else {
            print("UpdatesActionVisibility: could not read UpdatesController.swift and its +Classic file - skipping source guard")
            return
        }
        let raw = main + "\n" + classic
        // Strip whole-line comments: this file names the old token on
        // purpose, in the note explaining why it no longer uses it.
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        if code.contains("ReviewPRListView.actionReveal") {
            print("""
                  UpdatesActionVisibility: UpdatesController.swift decides the reveal per row again \
                  (ReviewPRListView.actionReveal) - the split the captain reported as broken
                  """)
            ok = false
        }
        if !code.contains("ToolRowLayout.actionReveal(forPageRowCount:") {
            print("UpdatesActionVisibility: UpdatesController.swift no longer uses the page-wide reveal rule")
            ok = false
        }
        if ok { print("UpdatesActionVisibility: the page decides its reveal rule once") }
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
