// Grand Line - native macOS app.
//
// The "Claude usage" popover (`fm/grandline-herdr-utilization-panel`).
// Structurally mirrors `ConsoleComposerPopover.swift` (the "✨ Compose"
// popover) byte-for-byte - transient `NSPopover`, `IconTileView` header, live
// `ThemeManager` observation, a `wantsLayer` root with an explicit theme
// background rather than relying on `NSPopover`'s own system vibrancy
// (AGENTS.md gotcha #8; Compose's own file header documents getting this
// wrong the first time).
//
// Originally reachable from a toolbar button on Console's herdr-attached
// "Mirror" tab - `fm/grand-line-remove-firstmate-mirror` deleted that tab and
// the toolbar button along with it (the captain: he'll check Claude usage in
// his own terminal now, same as everything else that tab used to embed).
// `FleetController`'s own `QuotaUsageController` instance (the Morning
// Briefing card's `.quota` deep link) is the one remaining live entry point.
//
// Unlike Compose, this popover shows read-only live status, not a
// generate-review-run flow - the closest existing precedent for that shape
// is SRE Lead's sliding pane, but that's a heavier full-agentic
// panel; a transient popover is the right weight for a quick "check my
// quota" glance (design plan, following the scout report's own
// recommendation).
//
// Data comes from `QuotaData.swift` (`quota-axi --json --provider claude`),
// Claude only per the captain's explicit scope decision in review - no
// multi-provider picker.
//
// Auto-refresh: every 10 minutes while the popover stays open (captain's
// explicit ask - unlike Compose, which never refreshes on its own), plus once
// immediately on every open (matching Compose's own `content.reset()` open
// behavior). The timer is owned by `QuotaUsageController` and invalidated in
// `close()`/`popoverDidClose` and `shutdown()`, mirroring `FleetNotifier`'s
// `timer?.invalidate(); timer = nil` teardown shape - never left running
// after the popover is dismissed by any path (explicit toggle, outside
// click, or the toolbar icon disappearing because the tab stopped
// qualifying).
//
// `fm/grandline-popover-redesign` (Use-1 of the console popovers board,
// `data/grand-line-console-popovers-sre-mockups/`): the popover is Home's
// Claude card in small. A hero gradient holds the title, the plan and when it
// was read, a Refresh button and one ring per window - Session, Weekly and the
// Fable week, which the parser already read and the popover never showed. As
// on Home, a comfortable arc is the hero's ink and only a warning or critical
// window takes its state hue, lifted onto the gradient by
// `HelmHeroSurface.signalColor`; a window with no reading draws a dashed
// track and an em dash, never 0% (GL-14). Under the hero each window is one
// row: a severity dot, the reset as a countdown with the absolute time, and a
// pace pill whose colour now comes from the pace rather than the bar - the
// old chip took `QuotaSeverity`'s tint, so "Unknown" on an idle session was
// green and "Behind" was the same green as "On pace". A failure is a critical
// `HelmAccentRow` with Retry, painted in `HelmTint.critical` rather than
// `.systemRed`.

import AppKit

/// `gauge.with.dots.needle.33percent` (SF Symbols 4, macOS 13+ - this
/// project's minimum target per `Package.swift`) - a gauge-family glyph,
/// deliberately not a circle/dot shape: this popover's toolbar trigger used
/// to sit right next to the light/dark toggle (a half-filled circle) on
/// Console, and a similar-looking icon would have been confusable (flagged
/// directly in visual review of the design mock). That trigger is gone with
/// the toolbar button it lived on (`fm/grand-line-remove-firstmate-mirror`),
/// but the gauge shape stays - it is still the right glyph for the popover's
/// own header tile below.
let quotaUsageGaugeSymbol = "gauge.with.dots.needle.33percent"

final class QuotaUsageController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let content = QuotaUsageViewController()
    private var themeObservation: ThemeObservation?
    private var refreshTimer: Timer?

    /// 10 minutes, per the captain's explicit review ask.
    private let autoRefreshInterval: TimeInterval = 600

    override init() {
        super.init()
        // Audit 2 §2.7/§6.2: a popover is its own window, layered above the
        // lock overlay, so anything open when the lock fires would stay
        // readable and interactive over the lock screen (§5.1(b)'s harm, of
        // which the incident card was one instance). Weak, because there is
        // no unregister.
        AppLockGate.shared.registerLockDismissiblePopover(owner: self) { [weak self] in self?.popover }
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onSizeChanged = { [weak self] size in
            self?.popover.contentSize = size
        }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            content.reset()
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            startAutoRefresh()
        }
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// `NSPopoverDelegate` - fires for every dismissal path (explicit
    /// re-click via `toggle`, a click outside the popover, or the toolbar
    /// icon's own gating hiding it out from under an open popover), so the
    /// timer can never keep firing after the content is no longer visible.
    func popoverDidClose(_ notification: Notification) {
        stopAutoRefresh()
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        let t = Timer.scheduledTimer(withTimeInterval: autoRefreshInterval, repeats: true) { [weak self] _ in
            self?.content.refresh()
        }
        t.tolerance = 5
        refreshTimer = t
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Mirrors `ConsoleComposerController.shutdown()`'s theme-observer
    /// teardown shape - a defensive counterpart to `init`'s `observe` call
    /// for any owner that isn't strictly app-lifetime. `FleetController`'s
    /// own instance is a permanently-mounted destination (GL-37) that is
    /// never deallocated mid-session, so nothing calls this today; kept for
    /// symmetry and for a future caller that owns one under different
    /// lifetime rules.
    func shutdown() {
        stopAutoRefresh()
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
            self.themeObservation = nil
        }
    }
}


/// The popover's content (Use-1): the hero with a ring per window, one row per
/// window with its countdown and pace, the warning or the failure, and the
/// footer with the source and Copy Summary. No history is kept between opens -
/// `reset()` always starts fresh.
private final class QuotaUsageViewController: NSViewController {
    private var theme = ThemeManager.shared.theme

    static let width: CGFloat = 320
    static let inset: CGFloat = 14
    static let iconButtonSide: CGFloat = 26

    private let ringsRow = NSStackView()
    private lazy var header = PopoverHeroHeader(symbol: quotaUsageGaugeSymbol, tileStyle: .glass, tileSide: 30,
                                                insets: NSEdgeInsets(top: 13, left: 14, bottom: 14, right: 14),
                                                body: ringsRow)
    private let refreshButton = HelmButton(symbol: "arrow.clockwise", variant: .secondary, size: .small)
    private var rings: [QuotaHeroRing] = []

    private let rowsStack = NSStackView()
    private var rows: [QuotaWindowRowView] = []
    private let loadingStack = NSStackView()
    private let warningBody = NSTextField(wrappingLabelWithString: "")
    private lazy var warningRow = HelmAccentRow(contentView: warningBody, hover: false)
    private let errorBody = NSTextField(wrappingLabelWithString: "")
    private let retryButton = HelmButton(title: "Retry", variant: .quiet, size: .small)
    private lazy var errorRow = HelmAccentRow(contentView: errorBody, trailingAccessory: retryButton, hover: false)

    private let footerRule = NSView()
    private let footerLabel = NSTextField(labelWithString: "quota-axi")
    private let copyButton = HelmButton(title: "Copy Summary", variant: .secondary, size: .small, symbol: "doc.on.doc")

    var onSizeChanged: ((NSSize) -> Void)?

    /// What the popover last read, and whether a read is in flight.
    private(set) var latestSnapshot: QuotaSnapshot?
    private var failure: String?
    private var isLoading = false
    /// The clock the countdowns read, injectable for a suite or a render
    /// (AGENTS.md: a live view reads one clock, never its own `Date()`).
    var now: () -> Date = Date.init

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        root.wantsLayer = true
        view = root

        ringsRow.orientation = .horizontal
        ringsRow.distribution = .fillEqually
        ringsRow.alignment = .top
        ringsRow.spacing = 0
        refreshButton.toolTip = "Read Claude usage again"
        refreshButton.setAccessibilityLabel("Refresh Claude usage")
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        header.trailing.addArrangedSubview(refreshButton)
        // An icon button is square; left to the row it took the slack.
        let insets = refreshButton.alignmentRectInsets
        NSLayoutConstraint.activate([
            refreshButton.widthAnchor.constraint(equalToConstant: Self.iconButtonSide - insets.left - insets.right),
            refreshButton.heightAnchor.constraint(equalToConstant: Self.iconButtonSide - insets.top - insets.bottom),
        ])

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0

        loadingStack.orientation = .vertical
        loadingStack.alignment = .leading
        loadingStack.spacing = 10
        for (fraction, height) in [(0.7, 9.0), (1.0, 6.0), (0.55, 9.0), (1.0, 6.0)] {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = CGFloat(height) / 2
            bar.translatesAutoresizingMaskIntoConstraints = false
            loadingStack.addArrangedSubview(bar)
            NSLayoutConstraint.activate([
                bar.heightAnchor.constraint(equalToConstant: CGFloat(height)),
                bar.widthAnchor.constraint(equalTo: loadingStack.widthAnchor, multiplier: CGFloat(fraction)),
            ])
        }
        loadingStack.setAccessibilityElement(true)
        loadingStack.setAccessibilityRole(.staticText)
        loadingStack.setAccessibilityLabel("Reading Claude usage")

        for body in [warningBody, errorBody] {
            body.font = .systemFont(ofSize: HelmType.scaled(12))
            body.isSelectable = true
            body.translatesAutoresizingMaskIntoConstraints = false
        }
        retryButton.tint = .accent
        retryButton.target = self
        retryButton.action = #selector(refreshClicked)
        retryButton.toolTip = "Read Claude usage again"
        errorRow.actionReveal = .always

        let body = NSStackView(views: [rowsStack, loadingStack, warningRow, errorRow])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.translatesAutoresizingMaskIntoConstraints = false

        footerRule.wantsLayer = true
        footerRule.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = HelmType.caption()
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyButton.surface = .raised
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [footerLabel, copyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(body)
        root.addSubview(footerRule)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s2),
            rowsStack.widthAnchor.constraint(equalTo: body.widthAnchor),
            loadingStack.widthAnchor.constraint(equalTo: body.widthAnchor),
            warningRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            errorRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            footerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerRule.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 10),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            footer.topAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: 9),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),
        ])

        render()
        applyTheme(theme)
    }

    // MARK: Fetch

    func reset() {
        latestSnapshot = nil
        failure = nil
        refresh()
    }

    /// Reads the same windows again and updates the views in place - on every
    /// open, every 10 minutes while open, and from Refresh and Retry.
    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        render()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = QuotaSource.fetch()
            DispatchQueue.main.async {
                self?.apply(result)
            }
        }
    }

    private func apply(_ result: QuotaFetchResult) {
        isLoading = false
        switch result {
        case .success(let snapshot):
            latestSnapshot = snapshot
            failure = nil
        case .failure(let message):
            latestSnapshot = nil
            failure = message
        }
        render()
    }

    @objc private func refreshClicked() { refresh() }

    // MARK: Render

    /// The windows this popover draws: Session and Weekly always (a missing
    /// one is "No reading", GL-14), and the Fable week when the account has
    /// one.
    static func windows(in snapshot: QuotaSnapshot?) -> [(title: String, window: QuotaWindow?)] {
        var windows: [(String, QuotaWindow?)] = [("Session", snapshot?.session), ("Weekly", snapshot?.weekly)]
        if let fable = snapshot?.fable { windows.append(("Fable week", fable)) }
        return windows
    }

    private func render() {
        guard isViewLoaded else { return }
        let snapshot = latestSnapshot
        var subtitle: [String] = []
        if let plan = snapshot?.plan, !plan.isEmpty { subtitle.append(plan.capitalized) }
        if isLoading && snapshot == nil {
            subtitle = ["Loading\u{2026}"]
        } else if isLoading {
            subtitle.append("refreshing\u{2026}")
        } else if snapshot != nil {
            subtitle.append("refreshed just now")
        } else {
            subtitle = ["Not refreshed"]
        }
        header.set(title: "Claude usage", subtitle: subtitle.joined(separator: " \u{00B7} "))
        refreshButton.isEnabled = !isLoading

        let windows = Self.windows(in: snapshot)
        let titles = snapshot == nil ? ["Session", "Weekly"] : windows.map(\.title)
        if rings.map(\.title) != titles {
            rings.forEach { $0.removeFromSuperview() }
            rings = titles.map { QuotaHeroRing(title: $0) }
            rings.forEach { ringsRow.addArrangedSubview($0) }
        }
        for (ring, entry) in zip(rings, windows) {
            ring.reading = snapshot == nil ? (isLoading ? .loading : .none) : .window(entry.window)
        }

        if rows.map(\.title) != (snapshot == nil ? [] : titles) {
            rows.forEach { $0.removeFromSuperview() }
            rows = snapshot == nil ? [] : titles.map { QuotaWindowRowView(title: $0) }
            for (index, row) in rows.enumerated() {
                row.showsRule = index > 0
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }
        for (row, entry) in zip(rows, windows) {
            row.configure(window: entry.window, now: now(), theme: theme)
        }
        rowsStack.isHidden = snapshot == nil
        loadingStack.isHidden = !(snapshot == nil && failure == nil)

        if let critical = Self.criticalWindow(in: snapshot) {
            warningRow.isHidden = false
            warningRow.configure(HelmAccentRow.Content(tint: .critical, kicker: critical.kicker,
                                                       badgeSymbol: "exclamationmark.triangle.fill"), theme: theme)
            warningBody.stringValue = Self.warningSentence(critical.window, now: now())
        } else {
            warningRow.isHidden = true
        }

        if let failure, snapshot == nil {
            errorRow.isHidden = false
            errorRow.configure(HelmAccentRow.Content(tint: .critical, kicker: "Couldn't read usage",
                                                     badgeSymbol: "exclamationmark.triangle.fill"), theme: theme)
            errorBody.stringValue = failure
        } else {
            errorRow.isHidden = true
        }

        footerLabel.stringValue = snapshot.map { String(format: "quota-axi \u{00B7} %.1fs", $0.latency) } ?? "quota-axi"
        copyButton.isEnabled = snapshot != nil
        applyRingTheme()
        updateSize()
    }

    /// The window that earns the warning: the first one above 90%, worded as
    /// it always was.
    static func criticalWindow(in snapshot: QuotaSnapshot?) -> (window: QuotaWindow, kicker: String)? {
        guard let snapshot else { return nil }
        let windows = [snapshot.session, snapshot.weekly, snapshot.fable].compactMap { $0 }
        guard let critical = windows.first(where: { $0.percentUsed > 90 }) else { return nil }
        let kicker: String
        switch critical.kind {
        case .weekly: kicker = "Near your weekly limit"
        case .session: kicker = "Near your session limit"
        case .fable: kicker = "Near your Fable limit"
        }
        return (critical, kicker)
    }

    /// "2% of the week left. It resets Sat 9:00 AM." - how much is left, and
    /// when it comes back.
    static func warningSentence(_ window: QuotaWindow, now: Date) -> String {
        let left = max(0, Int((100 - window.percentUsed).rounded()))
        let span = window.kind == .session ? "session" : "week"
        var sentence = "\(left)% of the \(span) left."
        if let resetsAt = window.resetsAt {
            sentence += " It resets \(QuotaWindowRowView.absoluteText(resetsAt, now: now))."
        }
        return sentence
    }

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        onSizeChanged?(NSSize(width: Self.width, height: view.fittingSize.height))
    }

    // MARK: Theming

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        view.layer?.backgroundColor = surface.cgColor
        header.applyTheme(theme)
        refreshButton.heroInk = header.ink
        applyRingTheme()
        rows.forEach { $0.applyTheme(theme, now: now()) }
        let track = theme.mode == .dark ? surface.blended(withFraction: 0.14, of: ink) ?? line
                                        : line.blended(withFraction: 0.25, of: surface) ?? line
        loadingStack.arrangedSubviews.forEach { $0.layer?.backgroundColor = track.cgColor }
        warningBody.textColor = ink
        errorBody.textColor = ink
        footerRule.layer?.backgroundColor = line.cgColor
        footerLabel.textColor = muted
        render()
    }

    private func applyRingTheme() {
        guard let palette = header.palette else { return }
        rings.forEach { $0.applyTheme(theme, palette: palette) }
    }

    // MARK: Copy

    @objc private func copyClicked() {
        guard let snapshot = latestSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.summary(for: snapshot), forType: .string)
    }

    /// Plain-text usage summary for the Copy Summary button. Not `private` so
    /// a suite can exercise it standalone.
    static func summary(for snapshot: QuotaSnapshot) -> String {
        var lines: [String] = ["Claude usage"]
        if let plan = snapshot.plan { lines.append("Plan: \(plan.capitalized)") }
        for (label, window) in windows(in: snapshot) {
            guard let window else { continue }
            var line = "\(label): \(Int(window.percentUsed.rounded()))% used, pace \(window.pace.label.lowercased())"
            if let resetsAt = window.resetsAt {
                line += ", resets \(QuotaWindow.resetsAtText(resetsAt))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    #if FM_SELFTESTS
    /// Paints a fixture result with no fetch: `quota-axi` never runs.
    func debugApply(_ result: QuotaFetchResult?, loading: Bool = false) {
        isLoading = loading
        switch result {
        case .success(let snapshot)?: latestSnapshot = snapshot; failure = nil
        case .failure(let message)?: latestSnapshot = nil; failure = message
        case nil: latestSnapshot = nil; failure = nil
        }
        render()
    }
    var debugRings: [QuotaHeroRing] { rings }
    var debugRows: [QuotaWindowRowView] { rows }
    var debugWarningVisible: Bool { !warningRow.isHidden }
    var debugErrorVisible: Bool { !errorRow.isHidden }
    var debugRetryButton: HelmButton { retryButton }
    var debugRefreshButton: HelmButton { refreshButton }
    var debugErrorText: String { errorBody.stringValue }
    #endif
}

/// One ring in the hero: the window's arc and figure over its caption.
final class QuotaHeroRing: NSView {
    enum Reading: Equatable {
        case loading
        case none
        case window(QuotaWindow?)
    }

    let title: String
    let gauge = HelmRingGauge(side: QuotaUsageMetrics.ringSide)
    private let caption = NSTextField(labelWithString: "")
    var reading: Reading = .none {
        didSet { if reading != oldValue { configureGauge() } }
    }
    private var lastTheme: HelmTheme?
    private var lastPalette: HelmHeroSurface.Palette?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        caption.stringValue = title
        caption.font = .systemFont(ofSize: HelmType.scaled(11), weight: .semibold)
        caption.alignment = .center
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gauge)
        addSubview(caption)
        NSLayoutConstraint.activate([
            gauge.topAnchor.constraint(equalTo: topAnchor),
            gauge.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.topAnchor.constraint(equalTo: gauge.bottomAnchor, constant: 5),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        configureGauge()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The figure a window shows: its percentage, or an em dash for no
    /// reading - never 0% (GL-14).
    static func figure(for window: QuotaWindow?) -> String {
        guard let window else { return "\u{2014}" }
        return "\(Int(max(0, min(100, window.percentUsed)).rounded()))%"
    }

    private func configureGauge() {
        switch reading {
        case .loading:
            gauge.configure(fraction: 0, text: "")
            gauge.showsDashedTrack = false
            setAccessibilityLabel("\(title): reading")
        case .none:
            gauge.configure(fraction: 0, text: "\u{2014}")
            gauge.showsDashedTrack = true
            setAccessibilityLabel("\(title): not read")
        case .window(let window):
            gauge.configure(fraction: (window?.percentUsed ?? 0) / 100, text: Self.figure(for: window))
            gauge.showsDashedTrack = window == nil
            setAccessibilityLabel(window.map { "\(title): \(Self.figure(for: $0)) used" } ?? "\(title): no reading")
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        if let lastTheme, let lastPalette { applyTheme(lastTheme, palette: lastPalette) }
    }

    /// The arc is the ink while comfortable and the state hue, lifted onto
    /// the gradient, at a warning or past it - Home's Claude hero's rule.
    static func arcColor(for window: QuotaWindow?, ink: NSColor, palette: HelmHeroSurface.Palette,
                         theme: HelmTheme) -> NSColor {
        guard let window else { return ink.withAlphaComponent(0.5) }
        switch QuotaSeverity(percentUsed: window.percentUsed) {
        case .comfortable: return ink
        case .warning: return HelmHeroSurface.signalColor(tintHex: HelmTint.warn.hex(in: theme), on: palette)
        case .critical: return HelmHeroSurface.signalColor(tintHex: HelmTint.critical.hex(in: theme), on: palette)
        }
    }

    func applyTheme(_ theme: HelmTheme, palette: HelmHeroSurface.Palette) {
        lastTheme = theme
        lastPalette = palette
        let ink = HelmContrast.color(palette.ink)
        var window: QuotaWindow?
        var known = false
        if case .window(let w) = reading { window = w; known = w != nil }
        gauge.trackColorOverride = ink.withAlphaComponent(gauge.showsDashedTrack
            ? QuotaUsageMetrics.ringDashAlpha : QuotaUsageMetrics.ringTrackAlpha)
        gauge.valueColorOverride = Self.arcColor(for: window, ink: ink, palette: palette, theme: theme)
        gauge.labelColorOverride = known ? ink : ink.withAlphaComponent(0.72)
        gauge.applyTheme(theme, hue: .blue)
        caption.textColor = ink.withAlphaComponent(0.92)
    }
}

/// One window's row under the hero: a severity dot, the title with its reset
/// countdown and absolute time, and the pace pill.
final class QuotaWindowRowView: NSView {
    let title: String
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let pacePill = HelmStatusPill(style: .dotWord)
    private let rule = NSView()
    private var quotaWindow: QuotaWindow?
    private var lastNow = Date()
    var showsRule = false { didSet { rule.isHidden = !showsRule } }

    static let dotSide: CGFloat = 8

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(12.5), weight: .semibold)
        detailLabel.font = HelmType.caption()
        detailLabel.lineBreakMode = .byTruncatingTail
        // Above the stack's own 250, so the words keep their width until the
        // pill needs the room - and below required, so they are what gives.
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(HelmDaylightPriority.columnHug + 200, for: .horizontal)
        }
        let words = NSStackView(views: [titleLabel, detailLabel])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        words.setClippingResistancePriority(.defaultLow, for: .horizontal)
        words.setHuggingPriority(.defaultLow, for: .horizontal)
        pacePill.style = .pill
        // Gotcha (12): the pill is a container, so its own priorities do
        // nothing - the word inside it is what must not give way.
        pacePill.label.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Pinned by hand rather than one stack row: the pill keeps its
        // width and the words take what is left (gotchas (5) and (12) - a
        // stack row squeezed "AHEAD" to "AHE…").
        words.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.isHidden = true
        rule.translatesAutoresizingMaskIntoConstraints = false
        for view in [rule, dot, words, pacePill] { addSubview(view) }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: words.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            words.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: HelmMetrics.s2),
            words.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            words.trailingAnchor.constraint(lessThanOrEqualTo: pacePill.leadingAnchor, constant: -HelmMetrics.s2),
            words.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            pacePill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pacePill.centerYAnchor.constraint(equalTo: words.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The pace pill's word and hue. The colour is the pace's, never the
    /// bar's: on pace is the accent, behind (spending slower than the window)
    /// is green, ahead is amber and red past 90%, and an unknown pace is grey.
    static func pace(for window: QuotaWindow) -> (text: String, tint: HelmTint) {
        switch window.pace {
        case .onPace: return ("On pace", .accent)
        case .behind: return ("Behind", .good)
        case .ahead: return ("Ahead", window.percentUsed > 90 ? .critical : .warn)
        case .unknown: return ("Pace unknown", .neutral)
        }
    }

    /// The severity dot's hue: the bar's verdict, or neutral for no reading.
    static func severityTint(for window: QuotaWindow?) -> HelmTint {
        guard let window else { return .neutral }
        return QuotaSeverity(percentUsed: window.percentUsed).tint
    }

    /// "Resets in 1d 11h" or "Resets in 2h 30m" - the time left, to the
    /// minute under a day.
    static func countdownText(until date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int(seconds / 60)
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        return "Resets in \(hours)h \(minutes % 60)m"
    }

    /// "Today 12:30 PM" or "Sat 9:00 AM" - `QuotaWindow.resetsCompactText`,
    /// with today named.
    static func absoluteText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let compact = QuotaWindow.resetsCompactText(date, now: now, calendar: calendar)
        return calendar.isDate(date, inSameDayAs: now) ? "Today \(compact)" : compact
    }

    static func detailText(for window: QuotaWindow?, now: Date) -> String {
        guard let window else { return "No reading" }
        guard let resetsAt = window.resetsAt else { return "Reset time unavailable" }
        return "\(countdownText(until: resetsAt, now: now)) \u{00B7} \(absoluteText(resetsAt, now: now))"
    }

    func configure(window: QuotaWindow?, now: Date, theme: HelmTheme) {
        self.quotaWindow = window
        applyTheme(theme, now: now)
    }

    func applyTheme(_ theme: HelmTheme, now: Date) {
        lastNow = now
        let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        detailLabel.stringValue = Self.detailText(for: quotaWindow, now: now)
        detailLabel.toolTip = quotaWindow?.resetsSentence
        // No reading is the muted ink: `.neutral` is page ink, a white dot in
        // a dark register.
        dot.layer?.backgroundColor = (quotaWindow == nil ? HelmTheme.mutedInk(theme)
            : HelmTheme.nsColor(Self.severityTint(for: quotaWindow).hex(in: theme))).cgColor
        rule.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        if let quotaWindow {
            let pace = Self.pace(for: quotaWindow)
            pacePill.isHidden = false
            pacePill.configure(text: pace.text.uppercased(), tint: pace.tint, theme: theme)
        } else {
            pacePill.isHidden = true
        }
        _ = surface
        let figure = quotaWindow.map { "\(Int($0.percentUsed.rounded()))% used" } ?? "no reading"
        setAccessibilityLabel("\(title), \(figure), \(detailLabel.stringValue)"
            + (quotaWindow.map { ", \(Self.pace(for: $0).text)" } ?? ""))
    }

    #if FM_SELFTESTS
    var debugPacePill: HelmStatusPill { pacePill }
    var debugDetail: String { detailLabel.stringValue }
    var debugDotColor: CGColor? { dot.layer?.backgroundColor }
    #endif
}

#if FM_SELFTESTS
extension QuotaUsageController {
    /// The popover's content view, for a render or a suite.
    var debugContentView: NSView { content.view }
    /// Paints a fixture result directly. Never calls `reset()` or `refresh()`,
    /// which run `quota-axi`.
    func debugApply(_ result: QuotaFetchResult?, loading: Bool = false, now: Date? = nil) {
        if let now { content.now = { now } }
        content.debugApply(result, loading: loading)
    }
    func debugApplyTheme(_ theme: HelmTheme) { content.applyTheme(theme) }
    var debugRings: [QuotaHeroRing] { content.debugRings }
    var debugRows: [QuotaWindowRowView] { content.debugRows }
    var debugWarningVisible: Bool { content.debugWarningVisible }
    var debugErrorVisible: Bool { content.debugErrorVisible }
    var debugRetryButton: HelmButton { content.debugRetryButton }
    var debugErrorText: String { content.debugErrorText }
    static func debugSummary(for snapshot: QuotaSnapshot) -> String { QuotaUsageViewController.summary(for: snapshot) }
    static func debugWarningSentence(_ window: QuotaWindow, now: Date) -> String {
        QuotaUsageViewController.warningSentence(window, now: now)
    }
}
#endif

/// Use-1's ring measurements, shared by the popover and its ring view.
enum QuotaUsageMetrics {
    /// Three of them fit the 292pt the popover has inside its insets.
    static let ringSide: CGFloat = 62
    static let ringTrackAlpha: CGFloat = 0.22
    /// A no-reading ring's dashed track is a touch brighter, so the dash reads.
    static let ringDashAlpha: CGFloat = 0.35
}
