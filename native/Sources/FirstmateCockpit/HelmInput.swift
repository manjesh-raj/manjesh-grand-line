// Manjesh Grand Line - native macOS app.
//
// Phase 0 of the Daylight UI migration (`data/grandline-ui-modernization-review/
// daylight-ui-design.md` §8 "Phase 0 - mechanism fixes", §6.9 `HelmInputSurface`;
// the audit behind it is `ui-report.md` §3.3 and defects D1/D4).
//
// Three mechanisms live here, and all three exist because the app's *look* for
// an input was already designed and its *wiring* was not:
//
// 1. `HelmFocusSensing` - one observation of the window's first responder,
//    feeding every registered input. This replaces `textDidBeginEditing`,
//    which is the shipped D1 bug: Apple documents that notification as firing
//    when "the user has begun *changing*" the text, so the three composer
//    surfaces lit their focus glow on the first keystroke rather than on the
//    click that focused them. A captain clicking into the Compose field saw
//    nothing happen and concluded the click had missed.
//
// 2. `HelmInputSurface` - the one focus treatment, so the answer to "did my
//    click land" is the same shape on every typing affordance in the app
//    rather than on the three composers only.
//
// 3. `HelmSelection` - themed text selection (D4). Selection is drawn by the
//    field editor's `selectedTextAttributes`, and exactly one place in the
//    whole app ever set it (`ToolInstance.swift`'s code editors), so every
//    other field in all 12 themes highlighted in macOS system blue.
//
// **What Phase 0 deliberately does not do:** the Daylight palette (`paper`/
// `card`/`inset`, the per-domain hues, the 4px 15%-alpha outer ring) is Phase
// 1's work. The focus recipe here is the active theme's own accent, painted
// the way `HelmComposerCard` already painted it - so the app stays coherent
// today and Phase 1 re-tokenizes one file instead of every call site.

import AppKit

// MARK: - HelmFocusSensing

/// A registration token. Holding it keeps the registration alive; dropping it
/// (or calling `HelmFocusSensing.shared.unregister`) ends it.
final class HelmFocusRegistration {
    fileprivate weak var target: NSView?
    fileprivate let onChange: (Bool) -> Void
    fileprivate var isFocused = false

    fileprivate init(target: NSView, onChange: @escaping (Bool) -> Void) {
        self.target = target
        self.onChange = onChange
    }
}

/// The app's one source of truth for "is this input focused right now".
///
/// **Why an observation of `NSWindow.firstResponder` rather than per-control
/// responder overrides.** For an `NSTextField` the window's first responder is
/// never the field: AppKit installs the window's shared *field editor* (an
/// `NSTextView` with `isFieldEditor == true`) and makes that the responder,
/// setting its `delegate` to the field. So a field never receives
/// `resignFirstResponder()` and cannot tell on its own when focus left it.
/// Measured, not assumed - a probe against a real window printed
/// `firstResponder` as `NSTextView` with `delegate === theField` for every
/// `makeFirstResponder(field)`.
///
/// KVO on `firstResponder` is likewise measured rather than assumed: the same
/// probe saw it fire on every transition, including the intermediate
/// field-editor install. It is not documented as observable, so a miss would
/// degrade to "no focus ring" rather than to anything incorrect, and
/// `refresh()` stays public so a caller (or a self-test) can always force a
/// re-evaluation.
final class HelmFocusSensing {

    static let shared = HelmFocusSensing()

    private var registrations: [HelmFocusRegistration] = []
    /// One KVO observer per window we have seen a registered input live in.
    private var windowObservers: [ObjectIdentifier: WindowObserver] = [:]

    private init() {}

    // MARK: Registration

    /// Register `view` - the control that actually takes focus (an
    /// `NSTextField`, or the `NSTextView` inside a scroll view) - and get told
    /// whenever its focused state changes. Fires once immediately with the
    /// current state, matching `ThemeManager.observe`'s own convention.
    @discardableResult
    func register(_ view: NSView, onChange: @escaping (Bool) -> Void) -> HelmFocusRegistration {
        let registration = HelmFocusRegistration(target: view, onChange: onChange)
        registrations.append(registration)
        observeWindow(of: view)
        let focused = Self.isFocused(view)
        registration.isFocused = focused
        onChange(focused)
        return registration
    }

    func unregister(_ registration: HelmFocusRegistration) {
        registrations.removeAll { $0 === registration }
    }

    /// Called by a `Helm*` input from `viewDidMoveToWindow()`: a control
    /// constructed before it is added to a hierarchy has no window to observe
    /// yet, so the registration has to pick one up when the view actually
    /// lands in one.
    func noteWindowChanged(for view: NSView) {
        observeWindow(of: view)
        refresh()
    }

    // MARK: Evaluation

    /// Is `view` the thing the captain is typing into?
    ///
    /// Two cases, both real: the view *is* the first responder (a real
    /// `NSTextView`, e.g. `HelmTextView`'s), or the first responder is the
    /// window's field editor standing in for it (every `NSTextField`).
    static func isFocused(_ view: NSView) -> Bool {
        guard let window = view.window, let responder = window.firstResponder else { return false }
        // A real first responder: `HelmTextView`'s text view, and the brief
        // moment a text field itself holds focus before its editor is
        // installed.
        if let responderView = responder as? NSView, responderView === view { return true }
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return false }
        // The field editor is in: which field is it standing in for?
        //
        // **Both tests are needed, and this is measured rather than defensive.**
        // A probe printing the state inside the KVO callback showed the editor
        // becoming first responder *before* its `delegate` is pointed at the
        // field: at that instant `delegate` is still nil while
        // `currentEditor()` already returns the editor, and by the time
        // `makeFirstResponder` returns the delegate is set. Checking only the
        // delegate therefore evaluated the transition as "focus left" and left
        // every text field in the app dark - caught by
        // `InputSurfaceSelfTest.checkFocusAnswersTheClick`, not by reading the
        // code.
        //
        // `currentEditor()` alone is not enough either: it reads stale-true for
        // one more notification after focus leaves (also measured), while the
        // responder is already the window - which the `isFieldEditor` guard
        // above rejects, so that staleness never reaches here.
        if (editor.delegate as? NSView) === view { return true }
        return (view as? NSControl)?.currentEditor() === editor
    }

    /// Re-evaluate every registration and notify the ones whose state changed.
    /// Also re-themes the live field editor's selection colours, which is the
    /// only reliable moment to do it - see `HelmSelection`.
    func refresh() {
        registrations.removeAll { $0.target == nil }
        for registration in registrations {
            guard let target = registration.target else { continue }
            let focused = Self.isFocused(target)
            guard focused != registration.isFocused else { continue }
            registration.isFocused = focused
            registration.onChange(focused)
        }
        HelmSelection.applyToLiveFieldEditors()
    }

    // MARK: Window observation

    private func observeWindow(of view: NSView) {
        guard let window = view.window else { return }
        let key = ObjectIdentifier(window)
        // Not just "is there an entry": an entry whose window has already been
        // deallocated is a stale key, and `ObjectIdentifier` is the object's
        // address, which the allocator is free to hand to the next window. A
        // plain nil-check would then silently leave that new window
        // unobserved (every input in it dark). Replacing a dead entry costs
        // nothing and cannot be wrong.
        if let existing = windowObservers[key], existing.isAlive { return }
        windowObservers[key] = WindowObserver(window: window) { [weak self] in self?.refresh() }
    }

    /// Called when an observed window closes. Keyed by the observer itself
    /// rather than by the window's address, so it cannot remove an entry a
    /// later window has since taken over.
    fileprivate func dropObserver(for observer: AnyObject) {
        if let key = windowObservers.first(where: { $0.value === observer })?.key {
            windowObservers[key] = nil
        }
    }

    /// A single window's `firstResponder` KVO observation, plus the
    /// `willClose` subscription that drops it. Its own class because KVO needs
    /// an `NSObject` and because `deinit` is the only place `removeObserver`
    /// can safely run - and because both teardowns then happen together
    /// rather than one of them being forgotten.
    private final class WindowObserver: NSObject {
        private weak var window: NSWindow?
        private let onChange: () -> Void
        private var closeToken: NSObjectProtocol?

        /// False once the window has gone, which is what makes a stale
        /// address-reuse entry detectable above.
        var isAlive: Bool { window != nil }

        init(window: NSWindow, onChange: @escaping () -> Void) {
            self.window = window
            self.onChange = onChange
            super.init()
            window.addObserver(self, forKeyPath: "firstResponder", options: [.new], context: nil)
            // A window that closes takes its observation with it - otherwise
            // the table grows for the app's lifetime as sheets and popovers
            // come and go.
            closeToken = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                HelmFocusSensing.shared.dropObserver(for: self)
            }
        }

        deinit {
            window?.removeObserver(self, forKeyPath: "firstResponder")
            if let closeToken { NotificationCenter.default.removeObserver(closeToken) }
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            guard keyPath == "firstResponder" else { return }
            onChange()
        }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugRegistrationCount: Int { registrations.count }
    var debugObservedWindowCount: Int { windowObservers.count }
    #endif
}

// MARK: - HelmSelection

/// Themed text selection (audit D4).
///
/// **Why this has to re-apply, and cannot just be set once.** The window's
/// field editor is a single shared object across every `NSTextField` in that
/// window - measured: the same `NSTextView` instance served two different
/// fields - and AppKit resets its `selectedTextAttributes` back to the system
/// value on every editing session. The same probe read
/// `System selectedTextBackgroundColor` back from the editor immediately after
/// focusing a second field, having set a custom colour on the first. So the
/// only correct moment to paint it is each time focus changes, which is why
/// this is driven from `HelmFocusSensing.refresh()` rather than from a
/// one-time call at launch.
///
/// That also means it covers *every* field in the app, including any that has
/// not been migrated onto `HelmTextField` yet - one observation, no per-site
/// work.
enum HelmSelection {

    /// How strongly the accent tints the selection. The terminal solved this
    /// same problem years ago with its own `selectionHex`; this is the UI
    /// layer's equivalent, at the alpha the audit's R4 specifies.
    static let alpha: CGFloat = 0.35

    static func attributes(_ theme: HelmTheme = ThemeManager.shared.theme) -> [NSAttributedString.Key: Any] {
        let accent = HelmTheme.nsColor(theme.accentHex)
        // The selection wash sits over a field fill, so the ink on top of it
        // is checked rather than assumed - the same rule `HelmField.ink`
        // applies one level out. `HelmContrast.legible` returns its input
        // untouched whenever it already clears the floor.
        let wash = accent.withAlphaComponent(alpha)
        // `HelmContrast.mix`, not `NSColor.blended(withFraction:of:)`: blended
        // converts both operands into a calibrated space first, so its result
        // drifts from the straight-sRGB composite alpha blending actually
        // performs and `HelmContrast.ratio` then measures. The same correction
        // Phase 4's segmented-tabs label needed.
        let composited = HelmContrast.color(
            HelmContrast.mix(HelmContrast.components(accent),
                             HelmContrast.components(HelmField.fill(theme)),
                             Double(alpha)))
        return [.backgroundColor: wash,
                .foregroundColor: HelmContrast.legible(HelmField.ink(theme), over: composited)]
    }

    /// Paint an `NSTextView` this app owns (`HelmTextView`, the composers, the
    /// Tools code editors).
    static func apply(to textView: NSTextView, theme: HelmTheme = ThemeManager.shared.theme) {
        textView.selectedTextAttributes = attributes(theme)
    }

    /// Paint whichever field editors are currently live. Called on every
    /// first-responder change.
    static func applyToLiveFieldEditors(theme: HelmTheme = ThemeManager.shared.theme) {
        let attrs = attributes(theme)
        for window in NSApp?.windows ?? [] {
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { continue }
            editor.selectedTextAttributes = attrs
        }
    }
}

// MARK: - HelmInputSurface

/// The one focus treatment for a typing affordance, and the one place Phase 1
/// will swap in Daylight's `inset`/`card`/hue tokens.
///
/// The chrome itself (fill, hairline, radius) stays `HelmField`'s - this adds
/// only the *focused* state on top of it, so an unfocused field renders
/// byte-identically to before Phase 0.
///
/// **Two shapes, because a clipped layer cannot cast a shadow.** A view whose
/// layer has `masksToBounds = true` (which every sunken well needs, or its
/// own fill ignores the corner radius) can show a brighter, thicker border but
/// not a glow outside its bounds. A component that owns an un-clipped wrapper
/// around its well - `HelmTextView`, `HelmSearchField`, `HelmComposerCard` -
/// passes that wrapper as `shadowHost` and gets the glow too. This is the same
/// two-layer arrangement `HelmComposerCard` documented first.
enum HelmInputSurface {

    /// The border weight a focused well takes, up from the hairline's 1.
    static let focusBorderWidth: CGFloat = 1.5

    /// How opaque the focused border's accent is. Below 1 so the border reads
    /// as lit rather than as a hard stroke.
    static let focusBorderAlpha: CGFloat = 0.75

    /// The glow's blur radius, where a `shadowHost` is available.
    static let focusGlowRadius: CGFloat = 8

    static func focusGlowOpacity(_ theme: HelmTheme) -> Float {
        theme.mode == .dark ? 0.35 : 0.22
    }

    /// Apply the resting or focused chrome to a sunken well.
    ///
    /// - Parameters:
    ///   - chrome: the clipped, filled, bordered view (the field itself, or
    ///     the scroll view wrapping a text view).
    ///   - shadowHost: an un-clipped ancestor that may carry the glow, or
    ///     `nil` for a border-only treatment.
    static func apply(chrome: NSView, shadowHost: NSView? = nil,
                      theme: HelmTheme, focused: Bool) {
        HelmField.applySunken(to: chrome, theme: theme)
        guard focused else {
            // Explicitly back to the hairline: `applySunken` only recolours,
            // so without this a well that has been focused once keeps the
            // thicker border forever.
            chrome.layer?.borderWidth = HelmField.hairlineBorderWidth
            shadowHost?.layer?.shadowOpacity = 0
            return
        }
        let accent = HelmTheme.nsColor(theme.accentHex)
        chrome.layer?.borderWidth = focusBorderWidth
        chrome.layer?.borderColor = accent.withAlphaComponent(focusBorderAlpha).cgColor
        guard let host = shadowHost else { return }
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.layer?.shadowColor = accent.cgColor
        host.layer?.shadowOpacity = focusGlowOpacity(theme)
        host.layer?.shadowRadius = focusGlowRadius
        host.layer?.shadowOffset = .zero
    }

    /// What a well actually resolved to, read from the real layer rather than
    /// re-derived - so a self-test cannot pass by repeating the component's
    /// own mistake. Mirrors `HelmField.geometry(of:)`'s reasoning.
    struct FocusGeometry {
        let borderWidth: CGFloat
        let borderColor: NSColor?
        let shadowOpacity: Float
    }

    static func focusGeometry(chrome: NSView, shadowHost: NSView? = nil) -> FocusGeometry {
        FocusGeometry(borderWidth: chrome.layer?.borderWidth ?? -1,
                      borderColor: chrome.layer?.borderColor.flatMap { NSColor(cgColor: $0) },
                      shadowOpacity: shadowHost?.layer?.shadowOpacity ?? 0)
    }
}
