// Grand Line - native macOS app.
//
// One policy for the app's two endless scenes: the lock screen's lighthouse
// (the turning lens, the fog, the waves and the boat) and the Secrets page's
// treasure chest (the seam's pulse, the rays and the twinkles).
//
// Full review 4, PF-01. Both scenes are render-server animation, so the app's
// own CPU stays low, but the window server composites large masked gradients
// on every frame for as long as the loops are attached. Auto-lock means the
// lock screen is the state the app sits in most when nobody is there: beside
// another app on a second display, or behind a screensaver that has not
// started. Until this type, the loops stopped only on unlock and under Reduce
// Motion.
//
// **The rule.** A scene holds still - it shows exactly what its Reduce Motion
// path draws - whenever any of these is true:
//
//   - Reduce Motion is on.
//   - The app is not the active app.
//   - The scene's window is not visible (`occlusionState` has lost
//     `.visible`: covered, on a Space nobody is on, or the display asleep).
//   - Low Power Mode is on.
//
// It resumes the moment all four clear. The gate only answers the question
// and calls back when the answer changes; each scene decides what "still"
// means for its own layers, because only it knows its Reduce Motion picture.
//
// **Low Power Mode is the odd one out**, because it is the one condition
// that holds while somebody *is* looking. So the gate also says when Low
// Power Mode is the only thing holding the scene still
// (`heldOnlyByLowPower`), and a scene may keep its signature motion then.
// The lighthouse keeps its lens turning (`LockScreenController.beamHoldsStill`)
// and pauses the rest. The chest has no such motion: its seam, rays and
// twinkles all pause.
//
// **Attach and detach with the scene.** `attach(to:)` registers the
// observers for one window and `detach()` removes them, so a scene that is
// hidden costs no notifications either (GL-13).

import AppKit

final class DecorativeMotionGate {

    /// What the gate reads. `allowsMotion` is the whole rule.
    struct Conditions: Equatable {
        var reduceMotion: Bool
        var appActive: Bool
        var windowVisible: Bool
        var lowPower: Bool

        var allowsMotion: Bool { !reduceMotion && appActive && windowVisible && !lowPower }

        /// Someone is looking and nothing but Low Power Mode holds the
        /// scene still.
        var heldOnlyByLowPower: Bool { lowPower && !reduceMotion && appActive && windowVisible }
    }

    /// True while the scene should show its still picture.
    private(set) var holdsStill: Bool
    /// True while Low Power Mode is the only reason `holdsStill` is true.
    private(set) var heldOnlyByLowPower = false
    private let onChange: (_ holdsStill: Bool) -> Void
    private weak var window: NSWindow?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(onChange: @escaping (_ holdsStill: Bool) -> Void) {
        self.onChange = onChange
        holdsStill = HelmMotion.isReduced
    }

    deinit { detach() }

    var isAttached: Bool { !observers.isEmpty }

    /// Starts watching on behalf of a scene in `window`, and settles
    /// `holdsStill` to the current answer without calling back: the caller
    /// is about to draw its scene and reads `holdsStill` to decide how.
    func attach(to window: NSWindow) {
        if isAttached, self.window === window {
            settle(conditions)
            return
        }
        detach()
        self.window = window
        let center = NotificationCenter.default
        let reevaluate: (Notification) -> Void = { [weak self] _ in self?.reevaluate() }
        observers = [
            (center, center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                        queue: .main, using: reevaluate)),
            (center, center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                        queue: .main, using: reevaluate)),
            (center, center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                        queue: .main, using: reevaluate)),
            // Posted on an arbitrary thread; `queue: .main` hops it.
            (center, center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil,
                                        queue: .main, using: reevaluate)),
            (NSWorkspace.shared.notificationCenter, HelmDisplayAccessibility.observeChanges { [weak self] in
                self?.reevaluate()
            }),
        ]
        settle(conditions)
    }

    private func settle(_ now: Conditions) {
        holdsStill = !now.allowsMotion
        heldOnlyByLowPower = now.heldOnlyByLowPower
    }

    /// Stops watching. The scene is gone, so nothing calls back.
    func detach() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        window = nil
    }

    /// Reads the conditions again and calls back if either answer changed.
    func reevaluate() {
        let now = conditions
        guard !now.allowsMotion != holdsStill || now.heldOnlyByLowPower != heldOnlyByLowPower else { return }
        settle(now)
        onChange(holdsStill)
    }

    var conditions: Conditions {
        Conditions(reduceMotion: HelmMotion.isReduced,
                   appActive: Self.appIsActive,
                   windowVisible: Self.isVisible(window),
                   lowPower: Self.lowPowerModeEnabled)
    }

    private static var appIsActive: Bool {
        #if FM_SELFTESTS
        if let forced = appActiveOverrideForTests { return forced }
        if isSelfTestProcess { return true }
        #endif
        // `NSApp` is nil in a headless process. No app object, nothing to
        // compete with, so motion is not held back on that account.
        return NSApp?.isActive ?? true
    }

    private static func isVisible(_ window: NSWindow?) -> Bool {
        #if FM_SELFTESTS
        if let forced = windowVisibleOverrideForTests { return forced }
        if isSelfTestProcess { return true }
        #endif
        guard let window else { return false }
        return window.occlusionState.contains(.visible)
    }

    private static var lowPowerModeEnabled: Bool {
        #if FM_SELFTESTS
        if let forced = lowPowerOverrideForTests { return forced }
        if isSelfTestProcess { return false }
        #endif
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    #if FM_SELFTESTS
    /// A suite pins one of the three conditions, then posts the real
    /// notification, so the change enters through the same observer a real
    /// one does. `nil` reads the real value, or, in a self-test process, the
    /// value that allows motion: a suite runs in an off-screen probe window
    /// that the window server never reports visible, in a process that is
    /// never the active app, and every scene suite before PF-01 measured the
    /// loops on that basis.
    static var appActiveOverrideForTests: Bool?
    static var windowVisibleOverrideForTests: Bool?
    static var lowPowerOverrideForTests: Bool?

    private static var isSelfTestProcess: Bool { ProcessMode.current == .selfTest }

    static func resetOverridesForTests() {
        appActiveOverrideForTests = nil
        windowVisibleOverrideForTests = nil
        lowPowerOverrideForTests = nil
    }
    #endif
}
