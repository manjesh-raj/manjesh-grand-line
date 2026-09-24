// Grand Line - native macOS app.
//
// "Follow system appearance", and the light/dark pair it switches between.
//
// `fm/grandline-settings-page-redesign`. The captain's Settings reference
// opens with a Follow-system-appearance switch above a greyed-out light/dark
// pair, and this app had no such thing: `ThemeManager` held exactly one
// selected theme, and `toggle()` (⌘⌥T) flipped it to its own `pairId`
// counterpart by hand. So this is a real feature rather than a restyle, and
// it is here rather than inside `ThemeManager` for one reason: the manager is
// the app's theme *state*, and this is a policy that reads the **system's**
// state and writes that state. Keeping them apart is what lets the decision
// itself be a pure function with a suite over it.
//
// **Why `AppleInterfaceStyle` and not `NSApp.effectiveAppearance`.** Two
// reasons, and the second is the load-bearing one:
//
//   * Every themed view in this app forces its own `appearance` to its
//     theme's light/dark mode (`ThemeManager.swift`'s own checklist, item 2),
//     so reading an appearance back out of the view tree would read this
//     app's answer rather than the system's question.
//   * `NSApp` is an implicitly-unwrapped `NSApplication!` and is **nil in a
//     headless suite** (AGENTS.md's self-test conventions), so anything that
//     touched it here would crash a suite rather than fail one. The
//     `AppleInterfaceStyle` default and the distributed notification that
//     announces its change are the standard non-`NSApp` route, and they work
//     in a process with no application object at all.
//
// The notification is `DistributedNotificationCenter`'s, which is how macOS
// tells every process the interface style moved - including the automatic
// sunrise/sunset switch, which is the case the whole feature exists for.

import AppKit

final class SystemAppearanceFollower {

    static let shared = SystemAppearanceFollower()

    /// macOS writes "Dark" here in the *global* domain and removes the key
    /// entirely for light - there is no "Light" value, which is why the
    /// reader below tests for the string rather than for a Bool.
    static let interfaceStyleKey = "AppleInterfaceStyle"
    /// The notification macOS posts to every process on a style change.
    static let interfaceStyleChangedNotification =
        Notification.Name("AppleInterfaceThemeChangedNotification")

    /// Reads the system's own light/dark bit.
    ///
    /// Injectable so the decision below can be tested without a machine that
    /// happens to be in the right mode.
    private let isSystemDark: () -> Bool

    private var isObserving = false

    init(isSystemDark: @escaping () -> Bool = SystemAppearanceFollower.readSystemIsDark) {
        self.isSystemDark = isSystemDark
    }

    static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: interfaceStyleKey)?.lowercased().contains("dark") == true
    }

    // MARK: The decision

    /// Which theme the app should be on, given the system's mode and the
    /// captain's pair. `nil` means "leave the theme alone" - either the
    /// captain is not following the system, or the stored pair names a theme
    /// that no longer exists.
    ///
    /// A pure function on purpose: it is the whole of the feature's
    /// behaviour, and everything around it is plumbing. A suite drives it
    /// directly rather than having to arrange a real interface-style change.
    ///
    /// The **mode is checked, not only the id**. A pair whose "light" slot
    /// somehow holds a dark theme would otherwise put the app in the dark on
    /// a light system and look exactly like a broken observer; falling back
    /// to the family default is both honest and self-correcting.
    static func resolvedTheme(isSystemDark: Bool,
                              lightID: String,
                              darkID: String) -> HelmTheme? {
        let wanted: HelmTheme.Mode = isSystemDark ? .dark : .light
        if let picked = HelmTheme.theme(id: isSystemDark ? darkID : lightID), picked.mode == wanted {
            return picked
        }
        return HelmTheme.allThemes.first { $0.mode == wanted }
    }

    // MARK: Plumbing

    /// Start listening, and apply the system's current mode right away.
    ///
    /// Idempotent, and safe to call whether or not following is switched on -
    /// the observer costs nothing while `AppSettings.followSystemAppearance`
    /// is false, and registering it unconditionally is what makes turning the
    /// switch on take effect without a relaunch. Called once from `main.swift`
    /// and again from Settings whenever the switch or either popup moves.
    func start() {
        if !isObserving {
            isObserving = true
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(systemAppearanceChanged),
                name: Self.interfaceStyleChangedNotification,
                object: nil)
        }
        applyIfFollowing()
    }

    @objc private func systemAppearanceChanged() {
        // The notification is posted *as* the change lands, and the default it
        // announces is not reliably readable on the same turn of the run loop
        // - a same-tick read returns the old value often enough that the app
        // would settle one mode behind on every switch. One hop is enough and
        // is what every other app doing this does.
        DispatchQueue.main.async { [weak self] in self?.applyIfFollowing() }
    }

    /// Put the app on the theme the system's mode calls for, if following is
    /// on and that is not already the active theme.
    ///
    /// The "already active" guard matters beyond saving work: `setTheme` fans
    /// out to every observer in the app and, once a window exists, runs the
    /// 200ms crossfade - so an unguarded call on a notification that changed
    /// nothing would flash the whole window.
    func applyIfFollowing() {
        guard AppSettings.shared.followSystemAppearance else { return }
        guard let wanted = Self.resolvedTheme(isSystemDark: isSystemDark(),
                                              lightID: AppSettings.shared.systemLightThemeID,
                                              darkID: AppSettings.shared.systemDarkThemeID) else { return }
        guard wanted.id != ThemeManager.shared.theme.id else { return }
        ThemeManager.shared.setTheme(wanted)
    }
}
