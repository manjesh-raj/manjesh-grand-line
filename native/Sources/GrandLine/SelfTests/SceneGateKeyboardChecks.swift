// Grand Line - native macOS app.
//
// Full review 4, A-02: the keyboard half of a scene gate, shared by the two
// suites that own one (`LockScreenSelfTest` for the lighthouse,
// `CredentialVaultViewSelfTest` for the chest). Not a suite of its own.
//
// What it proves, on a gate that is dark and has the password field focused:
//
//   - Tab from the field reaches the target (the window's own key view loop,
//     recalculated the way the main window does it).
//   - The target draws an `.exterior` focus ring with a real mask (GL-16).
//   - It is labelled by its action.
//   - A real Space and a real Return, sent through `NSWindow.sendEvent`, each
//     do exactly what a click does, once - and the gate's first-key monitor
//     stands aside while the target has the keyboard, so it cannot fire a
//     second time.
//   - A real click, queued and dispatched through `NSApplication` as a click
//     really arrives, still leaves the password field first responder.

#if FM_SELFTESTS
import AppKit

enum SceneGateKeyboardChecks {

    struct Gate {
        let name: String
        let window: NSWindow
        let hotspot: SceneGateHotspotView
        let field: NSTextField
        /// The label the target carries while the gate is dark.
        let darkLabel: String
        let isOpen: () -> Bool
        /// The gate's first-key monitor's own handler.
        let monitorKeyDown: () -> Void
        /// Puts the gate back to dark with the field focused.
        let reset: () -> Void
    }

    static func run(_ gate: Gate, _ ok: inout Bool) {
        let name = gate.name
        func fieldHasFocus() -> Bool {
            let responder = gate.window.firstResponder
            return responder === gate.field || (responder as? NSText)?.delegate === gate.field
        }
        gate.reset()
        guard !gate.isOpen(), fieldHasFocus() else {
            fail("\(name): the fixture is not a dark gate with the field focused, so these checks would prove nothing", &ok)
            return
        }

        // The ring and the words.
        check(gate.hotspot.focusRingType == .exterior, "\(name): the target draws no .exterior focus ring (GL-16)", &ok)
        check(!gate.hotspot.focusRingMaskBounds.isEmpty, "\(name): the focus ring's mask is empty", &ok)
        check(gate.hotspot.accessibilityLabel() == gate.darkLabel,
              "\(name): the target is labelled \"\(gate.hotspot.accessibilityLabel() ?? "")\", want \"\(gate.darkLabel)\"", &ok)

        // Tab reaches it.
        gate.window.autorecalculatesKeyViewLoop = true
        gate.window.recalculateKeyViewLoop()
        var view: NSView? = gate.field
        var reached = false
        for _ in 0..<64 {
            view = view?.nextValidKeyView
            if view === gate.hotspot { reached = true; break }
            if view == nil || view === gate.field { break }
        }
        check(reached, "\(name): Tab from the password field never reaches the target", &ok)

        // Space and Return, through the window's real key dispatch.
        for (key, code, chars) in [("Space", UInt16(49), " "), ("Return", UInt16(36), "\r")] {
            gate.reset()
            check(gate.window.makeFirstResponder(gate.hotspot), "\(name): the target refused focus from the keyboard", &ok)
            // The monitor sees the key first in the real app. It must stand
            // aside, or the key would act twice.
            gate.monitorKeyDown()
            check(!gate.isOpen(), "\(name): with the target focused, the first-key monitor opened the gate on \(key)", &ok)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: gate.window.windowNumber, context: nil,
                                               characters: chars, charactersIgnoringModifiers: chars,
                                               isARepeat: false, keyCode: code) else {
                fail("\(name): could not build a \(key) event", &ok)
                continue
            }
            gate.window.sendEvent(event)
            check(gate.isOpen(), "\(name): \(key) on the focused target did not open the gate", &ok)
        }

        // A real click leaves the field focused.
        gate.reset()
        let centre = gate.hotspot.convert(NSPoint(x: gate.hotspot.bounds.midX, y: gate.hotspot.bounds.midY), to: nil)
        let app = NSApplication.shared
        // An `OffScreenProbe` window stays off every display even when
        // ordered in, and a window that was never ordered in gets no mouse
        // events.
        gate.window.orderFront(nil)
        /// Queued and taken off the queue the way the run loop does it, so
        /// `NSApp.currentEvent` is the click while AppKit decides who gets
        /// focus - which is what the target reads.
        func click(_ type: NSEvent.EventType) {
            guard let event = NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [], timestamp: 0,
                                                 windowNumber: gate.window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { return }
            app.postEvent(event, atStart: true)
            for _ in 0..<32 {
                guard let next = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
                app.sendEvent(next)
                if next.type == type, next.windowNumber == gate.window.windowNumber { break }
            }
        }
        // Read between the two halves: the click handler puts focus back on
        // the field anyway, so only the press itself shows whether the
        // target took it.
        click(.leftMouseDown)
        check(fieldHasFocus(), "\(name): pressing on the target took the keyboard from the password field", &ok)
        click(.leftMouseUp)
        // The click really reached the target, so the focus check can fail.
        check(gate.isOpen(), "\(name): fixture: a click on the target's centre did not reach it", &ok)
        gate.reset()
    }
}
#endif
