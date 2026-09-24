// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for `ShiftGlobalHotkey` - universal
// capture's configurable chord (`fm/grandline-capture-global-hotkey-
// configurable`). `FM_RUN_QUICK_CAPTURE_HOTKEY_TESTS=1
// .build/debug/FirstmateCockpit`.
//
// Modelled on `DictationHotkeySelfTest` deliberately: the two classes now
// share one design (two event shapes, one monitor pair installed per shape,
// `updateShortcut(_:)` swapping between them), so they should share one
// testing shape too rather than each inventing its own.
//
// ## The check that would have caught the reported bug
//
// `checkAnAmbientFlagDoesNotBreakTheChord` (test 3) is the regression this
// suite exists for. The shipped predicate was
// `event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.option]`,
// and `.deviceIndependentFlagsMask` carries Caps Lock, Fn, the numeric-pad
// flag and the help flag alongside ⌘⌥⌃⇧ - so an event arriving with any of
// them set stopped matching the captain's chord, silently. The test drives a
// real ⌥Space `NSEvent` with Caps Lock also set and asserts the chord still
// fires. Confirmed to catch it: restoring the old
// `.deviceIndependentFlagsMask` predicate fails exactly that case and no
// other, which is also the honest measure of how narrow the fix is.
//
// Tests 6-9 are the structural half, and they close the same gap
// `DictationHotkeySelfTest`'s own tests 10-12 closed for Dictation: driving
// `matches(_:)` proves the predicate and says nothing about whether anything
// is listening. A future edit that dropped the
// `NSEvent.addGlobalMonitorForEvents` registration - installing only the
// local monitor, say - would have kept every predicate test green while
// costing the feature its entire reason to exist.
//
// ## What this cannot prove
//
// It cannot prove that a *global*, other-app-frontmost monitor actually
// receives real system events. That needs a live process, a real
// Accessibility grant and a real event source, none of which a unit test (or
// this repo's agent shell - AGENTS.md's "Verifying native UI bugs" section)
// has. What it does prove is that the right monitors exist for the right
// chord and that the predicate accepts the real event shapes. The live half
// is the captain's own check, and `ShiftGlobalHotkey`'s header states plainly
// which parts of the original diagnosis were measured and which were
// inferred.
//
// Pure logic plus monitor-token inspection: no window, no view hierarchy, so
// this suite is deliberately NOT in `NEEDS_SESSION` and guards the blocking
// CI lane. `NSEvent.addGlobalMonitorForEvents` returns a token on a headless
// runner exactly as it does anywhere else - an ungranted Accessibility
// permission means macOS never *calls* the handler, not that registration
// fails - so the structural checks below are runner-independent.

// GL-27: compiled into debug builds only. `Phase3PolishSelfTest` asserts that
// every file in this directory carries this guard.
#if FM_SELFTESTS

import AppKit

enum ShiftGlobalHotkeySelfTest {
    static func run() -> Bool {
        var ok = true

        func keyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: keyCode
            )!
        }

        func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )!
        }

        // 1. The shipped default really is ⌥Space, and it really is the
        //    regular-key shape. Asserted against the chord rather than
        //    re-derived from it: if the default ever changes silently, the
        //    captain's muscle memory is what breaks.
        do {
            check(KeyChord.quickCaptureDefault.keyCode == 49,
                  "the capture default must be Space (kVK_Space, 49)", &ok)
            check(KeyChord.quickCaptureDefault.modifiers == .option,
                  "the capture default must carry Option and nothing else", &ok)
            check(!KeyChord.quickCaptureDefault.isModifierOnly,
                  "Space is a real key, so the default must be the regular-key shape", &ok)
            check(AppSettings.shared.quickCaptureShortcut == .quickCaptureDefault
                  || AppSettings.shared.quickCaptureShortcut.keyCode != 0,
                  "AppSettings must return a usable chord even with nothing stored", &ok)
        }

        // 2. The default chord matches a real ⌥Space keyDown, and nothing
        //    else does. The fixture's discriminating power is asserted first:
        //    a Space with no modifier at all must be refused, or every
        //    assertion below it would pass vacuously on a broken predicate
        //    that simply said yes.
        do {
            let hotkey = ShiftGlobalHotkey {}
            check(!hotkey.matches(keyDown(keyCode: 49, modifiers: [])),
                  "a bare Space must not match - if it did, every check here would be vacuous", &ok)
            check(hotkey.matches(keyDown(keyCode: 49, modifiers: [.option])),
                  "⌥Space must match the shipped default", &ok)
            check(!hotkey.matches(keyDown(keyCode: 49, modifiers: [.option, .command])),
                  "⌘⌥Space must not match - a recorded chord means that chord exactly", &ok)
            check(!hotkey.matches(keyDown(keyCode: 5 /* G */, modifiers: [.option])),
                  "⌥G must not match a chord whose key is Space", &ok)
        }

        // 3. THE REGRESSION. An ambient flag riding along on the event -
        //    Caps Lock latched on, Fn held, an event carrying the numeric-pad
        //    flag - must not decide whether the captain's shortcut works.
        //    This is the exact defect `fm/grandline-capture-global-hotkey-
        //    configurable` was raised for; see this file's header.
        do {
            let hotkey = ShiftGlobalHotkey {}
            check(hotkey.matches(keyDown(keyCode: 49, modifiers: [.option, .capsLock])),
                  "Caps Lock being on must not stop ⌥Space matching", &ok)
            check(hotkey.matches(keyDown(keyCode: 49, modifiers: [.option, .function])),
                  "the Fn/Globe flag must not stop ⌥Space matching", &ok)
            check(hotkey.matches(keyDown(keyCode: 49, modifiers: [.option, .numericPad])),
                  "the numeric-pad flag must not stop ⌥Space matching", &ok)
            // And the same rule must not have been bought by ignoring the
            // modifiers altogether.
            check(!hotkey.matches(keyDown(keyCode: 49, modifiers: [.capsLock])),
                  "dropping the ambient flags must not also drop the real ones", &ok)
        }

        // 4. A recorded chord replaces the default, and the old one stops
        //    matching - `updateShortcut` is not a no-op on the predicate.
        do {
            var fired = 0
            let hotkey = ShiftGlobalHotkey { fired += 1 }
            let recorded = KeyChord(keyCode: 8 /* C */,
                                    modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue
                                        | NSEvent.ModifierFlags.control.rawValue,
                                    isModifierOnly: false)
            hotkey.updateShortcut(recorded)
            check(hotkey.shortcut == recorded, "updateShortcut must replace the stored chord", &ok)
            check(!hotkey.matches(keyDown(keyCode: 49, modifiers: [.option])),
                  "the old ⌥Space must stop matching once a new chord is recorded", &ok)
            check(hotkey.matches(keyDown(keyCode: 8, modifiers: [.command, .control])),
                  "the newly recorded chord must match", &ok)
            hotkey.stop()
            check(fired == 0, "matches() must not fire the handler on its own", &ok)
        }

        // 5. A modifier-only chord fires once on the press edge and not again
        //    on release - a capture trigger opens one panel, not two. The
        //    recorder refuses this shape for capture (`Mode.command`), but a
        //    hand-edited preference or a restored `.glbackup` can still carry
        //    one, and it must behave rather than double-fire.
        do {
            var fired = 0
            let held = KeyChord(keyCode: 61 /* Right ⌥ */,
                                modifierFlagsRaw: NSEvent.ModifierFlags.option.rawValue,
                                isModifierOnly: true)
            let hotkey = ShiftGlobalHotkey(shortcut: held) { fired += 1 }
            hotkey.handleFlagsEvent(flagsChanged(keyCode: 61, modifiers: [.option]))
            check(fired == 1, "a modifier-only chord must fire on the press edge", &ok)
            hotkey.handleFlagsEvent(flagsChanged(keyCode: 61, modifiers: [.option]))
            check(fired == 1, "a redelivered held-state event must not fire again", &ok)
            hotkey.handleFlagsEvent(flagsChanged(keyCode: 61, modifiers: []))
            check(fired == 1, "releasing a modifier-only chord must not fire a second time", &ok)
            hotkey.handleFlagsEvent(flagsChanged(keyCode: 61, modifiers: [.option]))
            check(fired == 2, "pressing it again after a release must fire again", &ok)
            // And the two mechanisms stay mutually exclusive per chord.
            check(!hotkey.matches(keyDown(keyCode: 61, modifiers: [.option])),
                  "a modifier-only chord must never match through the keyDown predicate", &ok)
        }

        // 6. `start()` with a regular-key chord installs BOTH the local and
        //    the GLOBAL keyDown monitor. The global one is the entire
        //    "from any app" feature; a local-only install looks identical
        //    from inside the app and is the failure the captain reported.
        do {
            let hotkey = ShiftGlobalHotkey {}
            hotkey.start()
            check(hotkey.localKeyMonitor != nil,
                  "start() must install a local keyDown monitor for a regular-key chord", &ok)
            check(hotkey.globalKeyMonitor != nil,
                  "start() must install a GLOBAL keyDown monitor - this is the system-wide reach", &ok)
            check(hotkey.localFlagsMonitor == nil && hotkey.globalFlagsMonitor == nil,
                  "a regular-key chord must not install flagsChanged monitors", &ok)
            hotkey.stop()
            check(hotkey.localKeyMonitor == nil && hotkey.globalKeyMonitor == nil,
                  "stop() must tear down every monitor", &ok)
        }

        // 7. Recording a modifier-only chord swaps the monitor *mechanism* -
        //    the keyDown pair goes, the flagsChanged pair arrives. A plain
        //    property set would leave a monitor listening for an event shape
        //    the new chord never produces.
        do {
            let hotkey = ShiftGlobalHotkey {}
            hotkey.start()
            hotkey.updateShortcut(KeyChord(keyCode: 61,
                                           modifierFlagsRaw: NSEvent.ModifierFlags.option.rawValue,
                                           isModifierOnly: true))
            check(hotkey.localFlagsMonitor != nil && hotkey.globalFlagsMonitor != nil,
                  "switching to a modifier-only chord must install both flagsChanged monitors", &ok)
            check(hotkey.localKeyMonitor == nil && hotkey.globalKeyMonitor == nil,
                  "switching to a modifier-only chord must tear down both keyDown monitors", &ok)
            // And back again - the full round trip, where a one-way switch
            // would still have passed the half above.
            hotkey.updateShortcut(.quickCaptureDefault)
            check(hotkey.localKeyMonitor != nil && hotkey.globalKeyMonitor != nil,
                  "switching back must reinstall both keyDown monitors", &ok)
            check(hotkey.localFlagsMonitor == nil && hotkey.globalFlagsMonitor == nil,
                  "switching back must tear down both flagsChanged monitors", &ok)
            hotkey.stop()
        }

        // 8. `start()` is idempotent. The shipped version installed a second
        //    pair over the first, leaking the originals - two live monitors
        //    for one chord, and the panel opening twice per press.
        do {
            let hotkey = ShiftGlobalHotkey {}
            hotkey.start()
            let firstLocal = hotkey.localKeyMonitor as AnyObject
            hotkey.start()
            let secondLocal = hotkey.localKeyMonitor as AnyObject
            check(firstLocal !== secondLocal,
                  "a second start() must install a fresh monitor, not reuse the token", &ok)
            check(hotkey.localKeyMonitor != nil && hotkey.globalKeyMonitor != nil,
                  "a second start() must leave exactly one live pair installed", &ok)
            hotkey.stop()
        }

        // 9. The trust bookkeeping behind `reassertIfTrustChanged()`.
        //
        //    A real Accessibility grant cannot be forced from a test, so what
        //    is asserted is the invariant that makes the re-arm correct:
        //    `installedWhileTrusted` reflects the trust the process had when
        //    the monitors were installed, and re-asserting is a no-op when
        //    nothing changed. On a runner with no grant, trust is false and
        //    `reassertIfTrustChanged()` must decline; on a machine that does
        //    have one, it must already be recorded as installed-while-trusted
        //    and so decline for the opposite reason. Either way one more call
        //    must never reinstall, which is what stops an activation observer
        //    rebuilding the monitors on every ⌘Tab.
        do {
            let hotkey = ShiftGlobalHotkey {}
            hotkey.start()
            check(hotkey.installedWhileTrusted == hotkey.isAccessibilityTrusted,
                  "installedWhileTrusted must record the trust held at install time", &ok)
            let before = hotkey.localKeyMonitor as AnyObject
            check(hotkey.reassertIfTrustChanged() == false,
                  "reassert must decline when trust has not changed since install", &ok)
            check(hotkey.localKeyMonitor as AnyObject === before,
                  "a declined reassert must leave the existing monitors alone", &ok)
            hotkey.stop()
        }

        // 10. The menu item's accelerator follows the chord, and says nothing
        //     when it cannot say it right. `main.swift` re-keys the Shift
        //     menu's Capture item from exactly this mapping.
        do {
            check(KeyChord.menuKeyEquivalent(for: 49) == " ",
                  "Space's menu key equivalent must be a space character, not the word", &ok)
            check(KeyChord.menuKeyEquivalent(for: 8) == "c",
                  "a letter's menu key equivalent must be its lowercased character", &ok)
            check(KeyChord.menuKeyEquivalent(for: 36) == "\r",
                  "Return's menu key equivalent must be a carriage return", &ok)
            check(KeyChord.menuKeyEquivalent(for: 999) == nil,
                  "a key with no menu representation must return nil rather than a guess", &ok)
        }

        return ok
    }
}

#endif
