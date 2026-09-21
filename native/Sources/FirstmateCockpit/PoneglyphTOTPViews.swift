// Manjesh Grand Line - native macOS app.
//
// F16's shared TOTP view pieces: one ticker every live surface reads, and the
// countdown ring the mockup draws on a 2FA row.
//
// **One clock, not one per view.** `TOTPTicker.shared.now` is the only `Date`
// any TOTP surface may read. That is AGENTS.md's rule, and F7's focus timer
// is why it exists: two views that each called `Date()` were reading two
// clocks, and the suite that drove a fabricated instant measured the real
// elapsed time instead - eleven checks failed on a feature that worked. Here
// the cost of getting it wrong is worse than a wrong test: the list row and
// the menu-bar popover would show the same credential's code with different
// countdowns, one of them wrong, and a captain would paste an expired code.
//
// The ticker fires once a second only while something is observing it, so a
// captain who never opens Poneglyph pays nothing - the same
// "background work stops when nobody can see it" rule as GL-13.

import AppKit

/// The app's one TOTP clock and its 1Hz tick.
final class TOTPTicker {

    static let shared = TOTPTicker()

    /// The instant every TOTP surface derives its code and its ring from.
    /// Injectable so a suite can drive a fabricated second without waiting
    /// for a real one.
    var clock: () -> Date = { Date() }

    var now: Date { clock() }

    private var observers: [UUID: () -> Void] = [:]
    private var timer: Timer?

    private init() {}

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        startIfNeeded()
        return token
    }

    func unobserve(_ token: UUID?) {
        guard let token else { return }
        observers.removeValue(forKey: token)
        if observers.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Drive one tick by hand - what a self-test does after moving `clock`,
    /// and what a view does on first render so it never shows a stale second.
    func tick() {
        for handler in observers.values { handler() }
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        // `.common`, so the countdown keeps running while a menu is tracking
        // or a sheet is up - a code that froze at 11 seconds behind a modal
        // is a code the captain would paste after it expired.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        // Audit §3.4: every repeating timer states a tolerance, so the OS
        // may coalesce it with other wake-ups instead of waking the CPU on
        // its own schedule. A quarter of a second is invisible on a
        // countdown whose whole job is to be roughly right about the next
        // thirty seconds.
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    #if FM_SELFTESTS
    var debugObserverCount: Int { observers.count }
    var debugIsRunning: Bool { timer != nil }
    /// Put the clock back, so a suite that moved it cannot leak a fabricated
    /// instant into whatever runs next - the same save/restore discipline
    /// AGENTS.md requires of `fm.themeID`.
    func debugResetClock() { clock = { Date() } }
    #endif
}

/// The mockup's 26pt countdown ring: a track, an arc that empties as the code
/// ages, and the remaining seconds in the middle.
///
/// Hand-drawn rather than a `HelmRingGauge`, for the reason `FocusMiniRing`
/// records one file over - that component is a fixed 66pt card ornament with
/// its own centre label, and this is a row-level chip. The arc convention
/// (12 o'clock, clockwise) is copied from it deliberately so the two rings in
/// this app turn the same way.
final class TOTPRingView: NSView {

    static let side: CGFloat = 26
    private static let lineWidth: CGFloat = 3

    /// `0...1`, how much of the window is left.
    var fraction: Double = 1 { didSet { needsDisplay = true } }
    /// The number in the middle. Empty draws the ring alone.
    var secondsText: String = "" { didSet { needsDisplay = true } }

    private var tint: NSColor = HelmTheme.nsColor(ThemeManager.shared.theme.accentHex)
    private var trackTint: NSColor = HelmTheme.nsColor(ThemeManager.shared.theme.chromeLineHex)
    private var textTint: NSColor = HelmTheme.mutedInk(ThemeManager.shared.theme)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The ring turns warn-coloured in its last five seconds, which is the
    /// one thing a glance needs to know: whether to copy now or wait for the
    /// next code. Routed through `HelmTint` rather than a literal so all
    /// fourteen palettes resolve their own.
    func applyTheme(_ theme: HelmTheme, urgent: Bool) {
        tint = HelmTheme.nsColor((urgent ? HelmTint.warn : HelmTint.accent).hex(in: theme))
        trackTint = HelmTheme.nsColor(theme.chromeLineHex)
        textTint = HelmTheme.mutedInk(theme)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = Self.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = min(rect.width, rect.height) / 2
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)

        let track = NSBezierPath()
        track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = Self.lineWidth
        trackTint.setStroke()
        track.stroke()

        if fraction > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: radius,
                          startAngle: 90, endAngle: 90 - CGFloat(min(1, fraction)) * 360,
                          clockwise: true)
            arc.lineWidth = Self.lineWidth
            arc.lineCapStyle = .round
            tint.setStroke()
            arc.stroke()
        }

        guard !secondsText.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: HelmType.scaled(9), weight: .regular),
            .foregroundColor: textTint,
        ]
        let text = NSAttributedString(string: secondsText, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2))
    }
}
