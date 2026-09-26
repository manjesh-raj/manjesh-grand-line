// Grand Line - native macOS app.
//
// F7's three rendered surfaces. The logic they render lives in
// `FocusTimer.swift`; nothing here decides anything about a session.
//
//   - `FocusTimerChip` - the quiet bar chip. The mockup's own design
//     decision, in its words: "a timer that is only visible on the Tasks
//     page is a timer you forget you started."
//   - `FocusTimerPanelController` - the popover behind that chip: the ring
//     gauge, the task's name, and Pause / +5 min / Finish.
//   - `FocusWeekBarView` - Weekly Review's seven-day "time on tasks" chart.
//
// **Where the ring panel ended up, and why it is not where the mockup drew
// it.** The mockup puts the ring in a right-hand column on the Tasks page.
// This app's Tasks page has a *leading* `HelmPageSidebar` and no trailing
// column, and adding one would have been a page-layout change F7 does not
// need - while the ring's own content (how long is left, on what, and the
// three controls) is exactly what a captain wants while they are somewhere
// else in the app, which is the same argument the mockup makes for the chip.
// So the ring hangs off the chip as a popover: same content, reachable from
// every destination rather than one.

import AppKit

// MARK: - The feature's hue

/// The one place F7 picks a colour.
///
/// The reviewed mockup draws the whole feature in Daylight's rose. Rose is a
/// `HelmDomainHue`, and its `fallbackTint` is `.critical` - so resolving it
/// the usual way would paint a *red alert* chip on the twelve pre-Daylight
/// palettes for a benign running timer, which is precisely the trap
/// AGENTS.md's colour rules call out. `identityHex` is the sanctioned
/// identity path, but its non-Daylight answer is `.neutral`, i.e. page ink -
/// too quiet for the one chrome element whose whole job is to be noticed.
///
/// So: rose on the Daylight family (the captain's own default, and the only
/// register the mockup was reviewed in), and the theme's own accent
/// everywhere else. The accent is contrast-guaranteed across all thirteen
/// palettes by `FM_RUN_CONTRAST_TESTS`, and it already means "the live thing"
/// throughout this app.
enum FocusTint {
    static let daylightHue: HelmDomainHue = .rose

    static func hex(in theme: HelmTheme) -> String {
        theme.isDaylight ? daylightHue.identityHex(in: theme) : HelmTint.accent.hex(in: theme)
    }

    static func color(in theme: HelmTheme) -> NSColor { HelmTheme.nsColor(hex(in: theme)) }
}

// MARK: - The bar chip

/// The running timer, as one chip on the app-wide bar.
///
/// Built always and hidden while nothing is running - as an *arranged
/// subview* of its owner's stack, which is the only kind of hidden view
/// AppKit drops out of layout (AGENTS.md gotcha (11)); an ordinary hidden
/// `NSView` here would leave its width behind on the bar forever.
final class FocusTimerChip: HoverHighlightView {

    /// The little countdown ring inside the chip - the same arc the popover
    /// draws at 118pt, at a size that fits a 34pt bar.
    private let ring = FocusMiniRing()
    private let timeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")

    /// How much of the task's title the chip will carry before truncating.
    /// Wide enough for a real task name, narrow enough that the chip never
    /// becomes the thing that squeezes the bar's search pill.
    private static let titleMaxWidth: CGFloat = 190
    static let height: CGFloat = 26

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        cornerRadius = HelmMetrics.rChip
        layer?.borderWidth = 1
        // GL-16: a clickable chip is a button to VoiceOver and takes a real
        // focus ring. `HoverHighlightView` supplies both once the role is
        // set; the label is rewritten on every tick by `configure`.
        setAccessibilityRole(.button)
        focusRingType = .exterior

        timeLabel.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(11.5), weight: .semibold)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: HelmType.scaled(11.5), weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        // The title holds its natural width (up to the cap below) rather
        // than collapsing - measured: at `.defaultLow` the chip's own
        // `.required` hugging squeezed it to nothing and a 190pt title
        // rendered in 0pt, leaving a chip that said `25:00` and named no
        // task at all.
        //
        // `contentTie` (499), not the 750 default, and that is AGENTS.md
        // gotcha (13): a content constraint above 500 outranks
        // `NSLayoutPriorityWindowSizeStayPut` and becomes a floor on the
        // *window's* width. At 499 a genuinely narrow window truncates this
        // title, which is the correct thing for it to do.
        titleLabel.setContentCompressionResistancePriority(
            HelmDaylightPriority.contentTie, for: .horizontal)

        let stack = NSStackView(views: [ring, timeLabel, titleLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = HelmMetrics.s1 + 2
        // AGENTS.md gotcha (10): a horizontal stack left at `.gravityAreas`
        // honours no hugging priority at all, so the title would not be the
        // one thing that truncates.
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let titleCap = titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.titleMaxWidth)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s2 - 2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            titleCap,
        ])
        // AGENTS.md gotcha (13): a content constraint above 500 can resize
        // the whole window. This one is a `<=` cap, which can only ever be a
        // maximum - but the chip as a whole must never be what widens the
        // bar, so it hugs and resists at `.required` and grows no further
        // than the cap above.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Repaint from a live session. `fraction` drives the ring, `countdown`
    /// the mono digits, `title` the task's name.
    func configure(fraction: Double, countdown: String, title: String, paused: Bool) {
        ring.fraction = fraction
        ring.paused = paused
        timeLabel.stringValue = countdown
        titleLabel.stringValue = title
        toolTip = paused
            ? "Focus paused \u{00B7} \(title). Click to resume or finish."
            : "\(countdown) left on \(title). Click for the timer."
        setAccessibilityLabel(paused
            ? "Focus paused, \(countdown) left on \(title)"
            : "Focus timer, \(countdown) left on \(title)")
    }

    func applyTheme(_ theme: HelmTheme) {
        let hue = FocusTint.color(in: theme)
        // A `HelmTint` hue is safe as a fill and is **not** automatically
        // safe as text - AGENTS.md's colour rule. `tintedSurface` resolves
        // the pair together: the wash this chip is filled with, and the
        // label tone that clears 4.5:1 on it in every theme.
        let resolved = HelmContrast.tintedSurface(tintHex: FocusTint.hex(in: theme),
                                                  theme: theme,
                                                  target: HelmContrast.textTarget)
        normalColor = resolved.fill
        hoverColor = resolved.fill.hoverShifted(by: 0.10, forMode: theme.mode)
        layer?.borderColor = hue.withAlphaComponent(0.55).cgColor
        timeLabel.textColor = resolved.foreground
        titleLabel.textColor = resolved.foreground
        ring.tint = hue
        ring.trackTint = hue.withAlphaComponent(0.25)
        ring.needsDisplay = true
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugCountdownText: String { timeLabel.stringValue }
    var debugTitleText: String { titleLabel.stringValue }
    var debugRingFraction: Double { ring.fraction }
    #endif
}

/// The chip's 14pt arc. Hand-drawn rather than a `HelmRingGauge`, which is
/// a fixed 66pt with a centre label - five times too big for a bar chip and
/// carrying text this chip already renders beside it.
private final class FocusMiniRing: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var paused = false { didSet { needsDisplay = true } }
    var tint: NSColor = HelmTheme.nsColor(ThemeManager.shared.theme.chromeInkHex)
    var trackTint: NSColor = HelmTheme.nsColor(ThemeManager.shared.theme.chromeLineHex)

    private static let side: CGFloat = 14
    private static let lineWidth: CGFloat = 2.6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

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

        guard fraction > 0 else { return }
        // 12 o'clock is 90 degrees in AppKit's unflipped space, and clockwise
        // on screen means decreasing angle - the same convention
        // `HelmRingGauge.layout` uses, stated there in radians.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius,
                      startAngle: 90, endAngle: 90 - CGFloat(min(1, fraction)) * 360,
                      clockwise: true)
        arc.lineWidth = Self.lineWidth
        arc.lineCapStyle = .round
        // A paused ring is drawn at half strength: the chip stays on the bar
        // (the session has not ended) but must not read as still counting.
        (paused ? tint.withAlphaComponent(0.45) : tint).setStroke()
        arc.stroke()
    }
}

// MARK: - The popover panel

/// The ring, the task, and the three controls - the mockup's own card,
/// reached by clicking the chip.
final class FocusTimerPanelController: NSViewController {

    private let timer: FocusTimerController
    private let ring = HelmRingGauge()
    private let ofLabel = NSTextField(labelWithString: "")
    private let taskLabel = NSTextField(wrappingLabelWithString: "")
    private let pauseButton = HelmButton(title: "Pause", variant: .secondary, size: .small)
    private let extendButton = HelmButton(title: "+5 min", variant: .secondary, size: .small)
    private let finishButton = HelmButton(title: "Finish", variant: .primary, size: .small)
    private var themeObservation: ThemeObservation?
    private var timerObservation: UUID?

    static let panelWidth: CGFloat = 230

    init(timer: FocusTimerController) {
        self.timer = timer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let timerObservation { timer.unobserve(timerObservation) }
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true

        ofLabel.alignment = .center
        ofLabel.font = HelmType.captionSmall()

        taskLabel.alignment = .center
        taskLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        taskLabel.maximumNumberOfLines = 2
        taskLabel.lineBreakMode = .byTruncatingTail

        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        extendButton.target = self
        extendButton.action = #selector(extendTapped)
        finishButton.target = self
        finishButton.action = #selector(finishTapped)

        let buttons = NSStackView(views: [pauseButton, extendButton, finishButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = HelmMetrics.s1 + 3
        buttons.distribution = .fill
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [ring, ofLabel, taskLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = HelmMetrics.s2
        stack.setCustomSpacing(2, after: ring)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let insets = HelmCard.contentInsets
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: insets.left),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -insets.right),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: insets.top),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -insets.bottom),
            root.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            taskLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = root
        // Registered last: `observe` fires synchronously at registration
        // (AGENTS.md's theming rule), so everything it repaints must exist.
        themeObservation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        timerObservation = timer.observe { [weak self] in self?.render() }
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render()
    }

    // MARK: Rendering

    private func render() {
        guard isViewLoaded else { return }
        guard let session = timer.session else {
            // The popover can outlive the session it was opened for - the
            // timer can reach zero while it is on screen. It says so rather
            // than freezing on the last frame it drew.
            ring.configure(fraction: 1, text: "\u{2014}", monospaced: true)
            ofLabel.stringValue = "no session running"
            taskLabel.stringValue = "Nothing is being timed"
            pauseButton.isEnabled = false
            extendButton.isEnabled = false
            finishButton.isEnabled = false
            return
        }
        // Through the controller, not off a `Date()` of this panel's own -
        // see `FocusTimerController.fraction`.
        ring.configure(fraction: timer.fraction ?? 0,
                       text: timer.countdownText ?? "0:00",
                       monospaced: true)
        ofLabel.stringValue = "of \(timer.plannedText ?? "\u{2014}")"
        taskLabel.stringValue = session.taskTitle
        pauseButton.title = timer.isPaused ? "Resume" : "Pause"
        pauseButton.isEnabled = true
        extendButton.isEnabled = true
        finishButton.isEnabled = true
    }

    private func applyTheme(_ theme: HelmTheme) {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        // The ring's arc carries the feature's own hue rather than a
        // `HelmDomainHue`, which cannot express the Daylight/legacy split
        // `FocusTint` makes - see `HelmRingGauge.valueColorOverride`.
        ring.valueColorOverride = FocusTint.color(in: theme)
        ring.applyTheme(theme, hue: FocusTint.daylightHue)
        ofLabel.textColor = HelmTheme.mutedInk(theme)
        taskLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        finishButton.domainHue = theme.isDaylight ? FocusTint.daylightHue : nil
    }

    // MARK: Actions

    @objc private func pauseTapped() {
        timer.togglePauseByHand()
        render()
    }

    @objc private func extendTapped() {
        timer.extend()
        render()
    }

    @objc private func finishTapped() {
        let logged = timer.stop()
        // GL-30: "Logged 25m" is used and gone before the pill fades, so it
        // is a toast and nothing more. The *completion* of a full session is
        // the lasting one, and `FocusTimerController` files that itself.
        //
        // Reported into the **parent** window's content view deliberately:
        // this panel is about to go away, and a toast hosted in a view that
        // is being torn down is a toast nobody sees.
        Feedback.report(logged.map { "Logged \(FocusTimerFormat.total($0)) to the task" }
                            ?? "Focus stopped \u{00B7} too short to log",
                        kind: logged == nil ? .warning : .done,
                        persistence: .transient,
                        in: view.window?.parent?.contentView ?? view)
        // B28: this used to be `view.window?.parent?.performClose(nil)` plus
        // `dismiss(nil)`, and both halves were wrong.
        //
        // This controller is an `NSPopover`'s *assigned*
        // `contentViewController`, so `dismiss(_:)` is a no-op (AGENTS.md
        // gotcha (6)) - which is presumably why something reached for a
        // window close at all. But a popover's `view.window` is its own
        // `_NSPopoverWindow` and that window's `parent` is the window it is
        // anchored to: the **main window**. Finishing a focus session closed
        // the app's last window.
        //
        // The popover belongs to whoever showed it, so that is who closes it.
        onRequestClose?()
    }

    /// Called when the panel has finished its work and should go away.
    ///
    /// Set by whoever presents this controller - the only object that holds
    /// the `NSPopover` and can legitimately close it. See `finishTapped`.
    var onRequestClose: (() -> Void)?

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugRing: HelmRingGauge { ring }
    var debugTaskTitle: String { taskLabel.stringValue }
    var debugPauseButtonTitle: String { pauseButton.title }
    func debugTapPause() { pauseTapped() }
    func debugTapFinish() { finishTapped() }
    func debugTapExtend() { extendTapped() }
    #endif
}

// MARK: - Weekly Review's seven-day chart

/// "Time on tasks" over a week: one bar per day, the tallest scaled to the
/// full height, and a day with no logged focus drawn as a flat hairline
/// rather than as nothing.
///
/// That last part is GL-14 applied to a chart: an absent bar and a zero bar
/// look the same to a reader, and the hairline is what says "this day was
/// measured and the answer was none" rather than "this day is missing".
final class FocusWeekBarView: NSView {

    /// One day's total, plus the letter under it.
    struct Bar {
        var label: String
        var seconds: Int
        /// Drawn at full strength rather than washed - the day the chart is
        /// about.
        var isToday: Bool
    }

    private var bars: [Bar] = []
    // Seeded from the live theme, never from a system semantic colour: those
    // resolve against the OS's own light/dark setting rather than the Helm
    // palette, which is the "half-themed" defect this codebase has shipped
    // four times. `applyTheme` overwrites all three on the first pass; these
    // are what the view paints with if it is ever drawn before that.
    private var tint: NSColor = FocusTint.color(in: ThemeManager.shared.theme)
    private var hairline: NSColor = HelmTheme.nsColor(ThemeManager.shared.theme.chromeLineHex)
    private var captionColor: NSColor = HelmTheme.mutedInk(ThemeManager.shared.theme)

    static let barAreaHeight: CGFloat = 46
    private static let captionHeight: CGFloat = 14
    private static let captionGap: CGFloat = 3
    /// The height a zero day is drawn at, so it reads as a measured zero.
    private static let zeroBarHeight: CGFloat = 2
    private static let barGap: CGFloat = 6
    private static let barRadius: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant:
            Self.barAreaHeight + Self.captionGap + Self.captionHeight).isActive = true
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ bars: [Bar]) {
        self.bars = bars
        let spoken = bars.map { "\($0.label) \(FocusTimerFormat.total($0.seconds))" }
        setAccessibilityLabel("Time on tasks by day: " + spoken.joined(separator: ", "))
        needsDisplay = true
    }

    func applyTheme(_ theme: HelmTheme) {
        tint = FocusTint.color(in: theme)
        hairline = HelmTheme.nsColor(theme.chromeLineHex)
        captionColor = HelmTheme.mutedInk(theme)
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !bars.isEmpty, bounds.width > 0 else { return }
        let peak = bars.map(\.seconds).max() ?? 0
        let slot = (bounds.width - CGFloat(bars.count - 1) * Self.barGap) / CGFloat(bars.count)
        guard slot > 1 else { return }

        let captionFont = NSFont.systemFont(ofSize: HelmType.scaled(9.5), weight: .medium)
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: captionFont,
            .foregroundColor: captionColor,
        ]
        let baseline = Self.captionHeight + Self.captionGap

        for (index, bar) in bars.enumerated() {
            let x = CGFloat(index) * (slot + Self.barGap)

            let height: CGFloat = peak > 0 && bar.seconds > 0
                ? max(Self.zeroBarHeight,
                      Self.barAreaHeight * CGFloat(bar.seconds) / CGFloat(peak))
                : Self.zeroBarHeight
            let rect = NSRect(x: x, y: baseline, width: slot, height: height)
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: Self.barRadius, yRadius: Self.barRadius)
            if bar.seconds > 0 {
                (bar.isToday ? tint : tint.withAlphaComponent(0.55)).setFill()
            } else {
                hairline.setFill()
            }
            path.fill()

            let text = bar.label as NSString
            let size = text.size(withAttributes: captionAttributes)
            text.draw(at: NSPoint(x: x + (slot - size.width) / 2, y: 0),
                      withAttributes: captionAttributes)
        }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugBars: [Bar] { bars }
    #endif
}
