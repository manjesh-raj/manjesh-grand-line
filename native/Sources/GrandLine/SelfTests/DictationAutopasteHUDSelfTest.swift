// Grand Line - native macOS app.
//
// `fm/grandline-dictation-autopaste-not-firing`: a real captain-reported bug -
// the app's own floating HUD said "Pasted" (a green checkmark) after a
// dictation whose automatic ⌘V never actually posted, because
// `AXIsProcessTrusted()` read false at the moment of paste while System
// Settings > Privacy & Security > Accessibility still showed a "Grand Line"
// row toggled on. Live-confirmed during this task via a read-only `lldb -p`
// attach to the captain's own running instance (AGENTS.md's "Verifying
// native UI bugs" convention): `AXIsProcessTrusted()` returned `0` for that
// exact process at that exact moment.
//
// `DictationEngine.pasteAtCursor` now returns a `PasteOutcome` and
// `deliver(_:duration:)` reports the new `DictationStatus.copiedOnly` case
// whenever the synthetic keystroke was skipped or failed - see that file's
// own `DictationEngineSelfTest.swift` case for the engine half (pure logic,
// not here). What this file covers is the one thing that self-test cannot:
// `DictationHUDController.handle(_:)` used to fold `.needsAccessibility` (and
// every other terminal status) into the exact same `.success` visual state as
// a real `.ready` - so the fix at the engine layer alone would not have
// stopped the floating HUD, the surface the captain actually watches while
// dictating into another app, from still saying "Pasted."
//
// Window-backed: `DictationHUDController.present(_:)` builds and orders front
// a real (borderless, non-activating, never-key) `NSPanel` - so this is in
// `run-all-tests.sh`'s `NEEDS_SESSION` list, per AGENTS.md's "Writing a
// self-test" convention (the test is what the suite asserts, not what it
// imports - and what this asserts is a real painted label, which needs a
// real panel to paint into).
//
// Run with:
//   swift build && FM_RUN_DICTATION_AUTOPASTE_HUD_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DictationAutopasteHUDSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkCopiedOnlyIsNeverShownAsPasted,
                      checkARealSuccessfulPasteStillSaysPasted] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DictationAutopasteHUDSelfTest: all checks passed"
                    : "DictationAutopasteHUDSelfTest: FAILED")
        return allOK
    }

    /// The regression itself: a dictation that could not be auto-pasted must
    /// never read as "Pasted" on the one surface a captain dictating into
    /// another app is actually watching. Reverting `handle(_:)`'s
    /// `.needsAccessibility`/`.copiedOnly` case back to grouping with
    /// `.ready` (this bug's real shipped shape) makes this fail - confirmed
    /// during this task by doing exactly that, rebuilding, and watching this
    /// case report the mismatch, then restoring the fix and re-confirming a
    /// pass.
    ///
    /// Asserts what was painted (`debugTitleText`, the real
    /// `NSTextField.stringValue` the panel is showing), not only what was
    /// computed (`debugCurrentState`) - this file's own AGENTS.md convention:
    /// a model-level assertion is blind to a bug between computing the state
    /// and actually rendering it into the label.
    private static func checkCopiedOnlyIsNeverShownAsPasted(_ ok: inout Bool) {
        print("\n-- the HUD says \"Copied\", never \"Pasted\", when the synthetic keystroke didn't post --")
        let hud = DictationHUDController()
        var problems: [String] = []

        // `wasActive` only arms once a real `.recording` has been seen -
        // mirrors the real engine's own sequence (recording -> transcribing
        // -> a terminal status), not just the terminal status in isolation.
        hud.handle(.recording)
        hud.handle(.transcribing)
        hud.handle(.needsAccessibility)

        if hud.debugCurrentState == .success {
            problems.append("the HUD's own state is .success - the exact misleading-status bug")
        }
        guard hud.debugCurrentState == .copiedOnly else {
            problems.append("expected .copiedOnly, got \(String(describing: hud.debugCurrentState))")
            for p in problems { print("  FAIL \(p)") }
            ok = false
            return
        }
        if hud.debugTitleText == "Pasted" {
            problems.append("the painted label still reads \"Pasted\"")
        }
        guard hud.debugTitleText == "Copied - press \u{2318}V to paste" else {
            problems.append("unexpected painted text: \(String(describing: hud.debugTitleText))")
            for p in problems { print("  FAIL \(p)") }
            ok = false
            return
        }

        if problems.isEmpty {
            print("  OK   state is .copiedOnly, label reads \"\(hud.debugTitleText ?? "")\"")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
        hud.handle(.ready) // Let it settle back to a real terminal state before teardown.
    }

    /// The fix's own guard rail: a genuine successful paste must keep saying
    /// "Pasted" - this is not a case where `.ready` should also start
    /// reading as "copied only."
    private static func checkARealSuccessfulPasteStillSaysPasted(_ ok: inout Bool) {
        print("\n-- a real successful paste still reads \"Pasted\" --")
        let hud = DictationHUDController()
        var problems: [String] = []

        hud.handle(.recording)
        hud.handle(.ready)

        if hud.debugCurrentState != .success {
            problems.append("expected .success, got \(String(describing: hud.debugCurrentState))")
        }
        if hud.debugTitleText != "Pasted" {
            problems.append("expected \"Pasted\", got \(String(describing: hud.debugTitleText))")
        }

        if problems.isEmpty {
            print("  OK   a real .ready after .recording still shows \"Pasted\"")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }
}

#endif
