// Grand Line - native macOS app.
//
// F1 / GL-11's Health card, given its own rail destination
// (`fm/grandline-health-sidebar-move`). It used to be the last card on the
// Settings page - the captain's own correction was the same one F11's
// Schedules card already got (`fm/grandline-schedules-sidebar-move`): a
// surface worth checking on directly should not need a scroll-within-Settings
// step to reach.
//
// **A plain view class rather than an extension on a controller** - the same
// convention `SchedulesCardView`/`HostsListSection`/`ShiftProjectDetailView`
// already follow: a self-contained view that owns its own rendering, so
// `HealthController` only owns presenting the page chrome around it.
//
// **Rebuilt from scratch on every report or theme change, not mutated in
// place.** The row count grows as services register and a row's content is
// entirely a function of `ServiceHealthRegistry`'s current state plus the
// active theme, so there is nothing worth diffing - the same reasoning
// `rebuildSecuritySection`/`SchedulesCardView.rebuild()` already use. This is
// also why there are no persistent "re-theme this row" registries here (unlike
// `SettingsController`'s page-wide `hoverRows`/`subtitleViews`): every row is
// built fresh with the current theme baked in, so nothing can go stale
// between rebuilds.
//
// `ServiceHealthRegistry`, `PersistenceFailureReporter`, and every reporter's
// call site are completely unchanged by this move - this file only reads
// them, exactly as `SettingsController`'s old `buildHealthSection()` did.
//
// **The sidebar layout draws the same readings as the prototype's page**
// (stage 6, `adoptTableLayout`): a row of summary cards (Healthy, Warnings,
// Failing, Not run yet) over one table of services, with each one's status,
// when it last ran, its recent runs and - only where the service has a real
// "run now" of its own - a Retry. It is a second rendering of this view's own
// state, driven by the same coalesced, hidden-gated rebuild, so the two
// layouts cannot disagree. The prototype's duration sparkline and app uptime
// are not drawn: the registry records neither, and a chart of numbers nobody
// measured would be the GL-14 lie this page exists to avoid.

import AppKit

final class HealthCardView: NSObject {

    /// The card to drop into the page's stack.
    let card = HelmCard()

    /// "Copy diagnostics", owned here and *positioned* by whoever hosts the
    /// card - Daylight §7 hoists it into the drill header. Still this view's
    /// button, with this view's handler, exactly as
    /// `HelmDrillHeader.setActions` requires of a caller-owned action.
    let diagnosticsButton: HelmButton

    /// Fired whenever the registry reports, so a host page's own live header
    /// line can follow the same signal the rows do rather than polling.
    var onStateChanged: (() -> Void)?

    /// UI12: where the empty state's "Open Schedules" goes. The same shape
    /// `SchedulesCardView.onOpenDestination` already uses - this view knows
    /// nothing about the shell, it just names a destination.
    var onOpenDestination: ((RailDestination) -> Void)?

    @objc private func openSchedulesTapped() { onOpenDestination?(.schedules) }

    /// The services that can be run again on demand, and how - handed in by
    /// the workspace, which owns the services. Only these rows offer Retry,
    /// and only while they are failing or have just failed. Today that is the
    /// background signals' `checkNow()` (also its manual entry point) and the
    /// dotfiles sync's `syncNowFromUI()` (Setup steps' Sync now). No other
    /// service has a "run now" of its own, so none is invented here.
    var retryActions: [HealthService: () -> Void] = [:]

    // MARK: The sidebar layout's table (stage 6)

    /// Set once, by `adoptTableLayout()`. Never set in the floating bar.
    private(set) var drawsTable = false
    private lazy var tableRoot = NSStackView()
    private lazy var healthyCard = HelmMetricCard(caption: "Healthy", tint: .good)
    private lazy var warningsCard = HelmMetricCard(caption: "Warnings", tint: .warn)
    private lazy var failingCard = HelmMetricCard(caption: "Failing", tint: .critical)
    private lazy var pendingCard = HelmMetricCard(caption: "Not run yet")
    private lazy var crashHost = NSStackView()
    private lazy var servicesTable: HelmDataTable = {
        let table = HelmDataTable(columns: [
            .init(id: "service", title: "Service", width: 320, minWidth: 220, flexible: true),
            .init(id: "status", title: "Status", width: 150),
            .init(id: "lastRun", title: "Last run", width: 150, hiddenBelow: 600),
            .init(id: "runs", title: "Recent runs", width: 110, hiddenBelow: 780),
        ], actionsWidth: 110)
        table.sizesToFitRows = true
        // The prototype shows Retry on the failing row at rest.
        table.actionsAlwaysVisible = true
        table.accessibilityName = "Background services"
        return table
    }()

    /// Build the sidebar layout's rendering and hand it to the page, which
    /// puts it where the card was. The card is not drawn in that layout.
    func adoptTableLayout() -> NSView {
        guard !drawsTable else { return tableRoot }
        drawsTable = true
        tableRoot.orientation = .vertical
        tableRoot.alignment = .leading
        tableRoot.spacing = HelmMetrics.s4
        tableRoot.translatesAutoresizingMaskIntoConstraints = false
        crashHost.orientation = .vertical
        crashHost.translatesAutoresizingMaskIntoConstraints = false
        let metrics = HelmMetricRow([healthyCard, warningsCard, failingCard, pendingCard])
        for view in [metrics, crashHost, servicesTable.card] as [NSView] {
            tableRoot.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: tableRoot.widthAnchor).isActive = true
        }
        card.isHidden = true
        rebuild()
        return tableRoot
    }

    /// The summary cards and the table, from the registry's current state.
    private func rebuildTable() {
        let counts = Self.verdictCounts()
        let known = counts.total > 0
        // Before anything has reported, every figure is unknown, not zero.
        let reason = "No background service has reported yet."
        healthyCard.configure(text: known ? "\(counts.healthy) / \(counts.total)" : nil, signals: false,
                              unknownReason: reason)
        warningsCard.configure(count: known ? counts.degraded : nil, unknownReason: reason)
        failingCard.configure(count: known ? counts.failing : nil, unknownReason: reason)
        pendingCard.configure(text: known ? "\(counts.pending)" : nil, signals: false, unknownReason: reason)
        for card in [healthyCard, warningsCard, failingCard, pendingCard] { card.applyTheme(theme) }

        for view in crashHost.arrangedSubviews {
            crashHost.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let crashRow = crashReportRow() {
            crashHost.addArrangedSubview(crashRow)
            crashRow.widthAnchor.constraint(equalTo: crashHost.widthAnchor).isActive = true
        }
        crashHost.isHidden = crashHost.arrangedSubviews.isEmpty

        let services = ServiceHealthRegistry.shared.knownServices()
        var rows = services.map(tableRow)
        if rows.isEmpty {
            rows = [.empty(
                symbol: "waveform.path.ecg", title: "Nothing has reported yet",
                body: "Background services report here as they run. A schedule is the usual way one runs without you.",
                action: .init(title: "Open Schedules", symbol: "calendar") { [weak self] in self?.openSchedulesTapped() })]
        }
        servicesTable.applyTheme(theme)
        servicesTable.setRows(rows)
    }

    /// One service: what it does (or its last error), its verdict, when it
    /// last ran, its run streak, and Retry where the service can be re-run.
    private func tableRow(_ service: HealthService) -> HelmDataTable.Row {
        let state = ServiceHealthRegistry.shared.state(service)
        let (tint, chip) = Self.healthVisuals(state)
        var row = HelmDataTable.Row.record(service.rawValue)
        let detail: String
        if let failure = state.lastFailureDetail, let when = state.lastFailure {
            detail = "Last error (\(Self.relative(when))): \(failure)"
        } else {
            detail = service.detail
        }
        let lastRun: HelmDataTable.Cell
        if state.verdict == .running {
            lastRun = .muted("Checking\u{2026}")
        } else if let last = state.lastSuccess {
            lastRun = .text(Self.relative(last))
        } else if state.hasReported {
            lastRun = .muted("Never succeeded")
        } else {
            lastRun = .muted("Not run yet")
        }
        let ticks = Self.runTicks(state)
        row.cells = [
            "service": .title(service.title, subtitle: detail, subtitleIsCode: false, symbol: service.symbol,
                              tint: tint, tintHex: nil),
            "status": .status(chip, tint: tint),
            "lastRun": lastRun,
            "runs": .marks(ticks, spoken: Self.runTicksSpoken(state)),
        ]
        let needsAttention = state.verdict == .degraded || state.verdict == .failing
        if needsAttention, let retry = retryActions[service] {
            row.primary = .init(title: "Retry", symbol: "arrow.clockwise", run: retry)
        }
        return row
    }

    private let healthStack = NSStackView()
    /// §7's "KPI chips in the header band region" - one per non-zero verdict
    /// bucket, in the card header's trailing action slot. Rebuilt in place
    /// (`refreshHeaderChips`) rather than recreated, so the header's own
    /// action stack is built once.
    /// UI-56: the verdict counts as a KPI line over the rows - one figure per
    /// bucket - rather than a run of pills in the card header.
    private let summaryStrip = HelmKPIStrip()
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init() {
        diagnosticsButton = HelmButton(title: "Copy diagnostics", variant: .secondary,
                                       size: .small, symbol: "doc.on.doc")
        super.init()
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(copyDiagnostics)
        buildCard()
        // Rebuilt on every report rather than mutated in place: the row count
        // grows as services register, and a row's trailing control differs by
        // verdict (a pill, or nothing).
        //
        // P4 (`data/grand-line-e2e-audit/report.md`): coalesced, and skipped
        // entirely while this card is off screen. The registry notifies on
        // *every* mutation including `markRunning`, and `FleetNotifier` marks
        // running + records success every 30s, `ShiftNotificationScheduler`
        // every 60s, a `BackgroundSignalsPoller` pass several - so once the
        // Health page had been visited once (it stays mounted for the session,
        // GL-37), the app performed 2-4 full card rebuilds per minute forever,
        // on the main thread, whether or not anyone was looking at it.
        ServiceHealthRegistry.shared.observe { [weak self] _ in
            self?.setNeedsRebuild()
        }
    }

    private func buildCard() {
        // D5: this used to be the *third* statement of "Health" / "last run
        // and last error" on one page (top bar, page subtitle, card header).
        // The top bar names the destination and the card header names what
        // this particular card lists - the page-level restatement and this
        // one's duplicate subtitle are both gone.
        card.setHeader(
            symbol: "waveform.path.ecg",
            tint: .good,
            title: "Background services",
            subtitle: "Last run and last error for each one"
        )
        summaryStrip.setAccessibilityLabel("Background services summary")
        healthStack.orientation = .vertical
        healthStack.alignment = .leading
        healthStack.spacing = 10
        healthStack.translatesAutoresizingMaskIntoConstraints = false
        card.setBody(healthStack, insets: HelmCard.contentInsets)
        rebuild()
    }

    /// The one entry point a hosting page calls - on its own `viewWillAppear`
    /// and on every theme change, matching `SchedulesCardView.setSchedules(_:
    /// runningID:theme:)`'s shape.
    func refresh(theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        pendingWhileHidden = false
        lastRebuiltAt = Date()
        rebuild()
        onStateChanged?()
    }

    /// P3: the same thing, but only when it would actually change what is on
    /// screen.
    ///
    /// `viewWillAppear` used to rebuild every row on **every** visit - 123ms
    /// measured for a steady-state revisit on a debug build, ~15 dropped
    /// frames at 120Hz - whether or not anything had moved since the last
    /// one. Three things can make it stale: a report arrived while this card
    /// was hidden (`pendingWhileHidden`, P4's gate), the theme changed, or
    /// enough time passed that the rows' own relative wording ("last ran 3m
    /// ago") is out of date. Nothing else can.
    func refreshIfNeeded(theme: HelmTheme) {
        let themeChanged = theme.id != self.theme.id
        let stale = lastRebuiltAt.map { Date().timeIntervalSince($0) >= Self.relativeWordingStaleAfter } ?? true
        guard pendingWhileHidden || themeChanged || stale else { return }
        refresh(theme: theme)
    }

    /// How long before a row's relative wording ("last ran 3m ago") is worth
    /// re-rendering for. A minute: that is the resolution those strings are
    /// written at below the hour mark.
    private static let relativeWordingStaleAfter: TimeInterval = 60
    private var lastRebuiltAt: Date?

    // MARK: P4 - one rebuild per turn, and none while hidden

    /// A rebuild has been asked for and the coalescing hop has not run yet.
    private var rebuildScheduled = false
    /// A report arrived while this card was off screen. The page's own
    /// `viewWillAppear` -> `refresh(theme:)` is what settles it, exactly as it
    /// already did before this gate - a hidden page rebuilding eagerly is pure
    /// waste, since it rebuilds again on appearance anyway.
    private var pendingWhileHidden = false

    /// Whether a rebuild would be visible to anyone - the card, or in the
    /// sidebar layout the table that replaces it.
    private var isOnScreen: Bool {
        let shown: NSView = drawsTable ? tableRoot : card
        return shown.window != nil && !shown.isHiddenOrHasHiddenAncestor
    }

    /// One rebuild per main-queue turn, the same latch shape
    /// `HomeCanvasController.setNeedsRender` uses - a `BackgroundSignalsPoller`
    /// pass emits several reports in quick succession and they are one visual
    /// change.
    private func setNeedsRebuild() {
        guard isOnScreen else {
            pendingWhileHidden = true
            // The header line still follows the signal - it is a string, not
            // a view tree, and a host page may be showing it elsewhere.
            onStateChanged?()
            return
        }
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard self.isOnScreen else { self.pendingWhileHidden = true; return }
            self.lastRebuiltAt = Date()
            self.rebuild()
            self.onStateChanged?()
        }
    }

    // MARK: Rendering

    /// Every wrapping description label this card has built, so the width
    /// they wrap at can be re-derived from the card's real width on every
    /// layout pass instead of being guessed once (see `descriptionWidth()`).
    /// Cleared on each rebuild, which is when the labels themselves go.
    private var descriptionLabels: [NSTextField] = []

    /// The width a description label may actually use: the card's own width
    /// less the body insets, the row's internal padding, the icon tile and
    /// the trailing pill/button column. Falls back to the old constant before
    /// the first layout pass, when the card has no width yet.
    private func descriptionWidth() -> CGFloat {
        let cardWidth = card.bounds.width
        guard cardWidth > 0 else { return 360 }
        let chrome: CGFloat = HelmCard.contentInsets.left + HelmCard.contentInsets.right
            + 16                                    // the row container's own 8pt padding, both sides
            + HelmMetrics.tileSmall + 10            // icon tile + its gap
            + 12 + 120                              // row spacing + the trailing pill/button column
        return max(240, cardWidth - chrome)
    }

    /// Re-wrap on a real resize. `HealthController` calls this from its own
    /// `viewDidLayout`, which is the first moment the card's width is known.
    func layoutDidChange() {
        let width = descriptionWidth()
        for label in descriptionLabels where abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
        }
    }

    // MARK: §7's KPI chips and run ticks

    /// How many known services sit in each verdict bucket. Static because
    /// `HealthController`'s own drill-header subtitle reads it too, and two
    /// separate counts of one registry is how a header and its rows start
    /// disagreeing.
    static func verdictCounts() -> (total: Int, healthy: Int, degraded: Int, failing: Int, pending: Int) {
        var healthy = 0, degraded = 0, failing = 0, pending = 0
        let services = ServiceHealthRegistry.shared.knownServices()
        for service in services {
            switch ServiceHealthRegistry.shared.state(service).verdict {
            case .healthy: healthy += 1
            case .degraded: degraded += 1
            case .failing: failing += 1
            case .running, .unknown: pending += 1
            }
        }
        return (services.count, healthy, degraded, failing, pending)
    }

    /// §7's "run-tick strings", built strictly from what the registry actually
    /// records.
    ///
    /// **There is no run history to draw**, and this deliberately does not
    /// invent one: `ServiceHealthState` carries `lastSuccess`, `lastFailure`
    /// and `consecutiveFailures` - not a series - and collecting a series
    /// would be new data collection, which this slice forbids. So the ticks
    /// are an exact rendering of the run *streak* the registry does know: one
    /// cross per consecutive failure (newest first, capped) followed by a
    /// check when a successful run is on record. A service that has never
    /// reported gets no ticks at all rather than a fabricated one.
    static func runTicks(_ state: ServiceHealthState) -> String {
        guard state.hasReported else { return "" }
        let failures = min(state.consecutiveFailures, maxRunTicks)
        var ticks = String(repeating: "\u{2715}", count: failures)
        if state.lastSuccess != nil, failures < maxRunTicks { ticks += "\u{2713}" }
        return ticks
    }

    /// R2-A11Y-04: the marks `runTicks` draws, in words - "3 failures,
    /// 1 success" - in the order they are drawn. A cross and a tick were the
    /// only carriers, and VoiceOver read them as "multiplication x, check
    /// mark".
    static func runTicksSpoken(_ state: ServiceHealthState) -> String {
        guard state.hasReported else { return "No runs yet" }
        let failures = min(state.consecutiveFailures, maxRunTicks)
        var parts: [String] = []
        if failures > 0 { parts.append(failures == 1 ? "1 failure" : "\(failures) failures") }
        if state.lastSuccess != nil, failures < maxRunTicks { parts.append("1 success") }
        return parts.joined(separator: ", ")
    }

    /// A streak longer than this is reported as a count in the row's own copy
    /// ("Last error ...") rather than as an unbounded glyph run.
    private static let maxRunTicks = 5

    /// UI-56: the counts, quiet when a bucket is empty and tinted when it is
    /// the signal. Shown only once something has reported - an all-zero line
    /// over "Nothing has reported yet" would say the same thing twice.
    private func refreshSummary() {
        let counts = Self.verdictCounts()
        summaryStrip.configure([
            .count(counts.total, caption: counts.total == 1 ? "Service" : "Services"),
            .count(counts.failing, caption: "Failing", tintWhenNonZero: .critical),
            .count(counts.degraded, caption: "Recent failure", tintWhenNonZero: .warn),
            .count(counts.healthy, caption: "Healthy", tintWhenNonZero: .good),
            .count(counts.pending, caption: "Not run yet"),
        ], theme: theme)
    }

    private func rebuild() {
        #if FM_SELFTESTS
        debugRebuildCount += 1
        #endif
        if drawsTable {
            rebuildTable()
            return
        }
        refreshSummary()
        descriptionLabels.removeAll()
        for v in healthStack.arrangedSubviews {
            healthStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let services = ServiceHealthRegistry.shared.knownServices()
        var rows: [NSView] = []

        // P9: two SIGABRTs in 24 hours sat unnoticed in
        // `~/Library/Logs/DiagnosticReports` because nothing in this app ever
        // looked. This row is the looking. It is above the service rows
        // because it is about the app itself rather than about one background
        // service, and it appears only when there is something to say - an
        // always-present "no crashes" row is noise on every other day.
        if let crashRow = crashReportRow() { rows.append(crashRow) }

        if services.isEmpty {
            // Review #3's UI12. Honest rather than reassuring - nothing has
            // reported yet, which at launch is simply true - but until this it
            // was one muted sentence and a dead end: it said rows appear as
            // each service runs without saying where a run comes from.
            //
            // It is the app's shared `HelmEmptyState` now, with the
            // call-to-action in the `accessory` slot every other actionable
            // empty state in this app uses (Docs' "Sync Now", Kubernetes'
            // "Open Hosts"). Schedules is the button because a schedule is the
            // one thing in this app that *makes* a background service run on
            // its own, and its own card says so ("Runs log to Health").
            //
            // `.compact` and unboxed: this sits inside a `HelmCard`'s body,
            // which already draws the surface and the border.
            let empty = HelmEmptyState(
                symbol: "waveform.path.ecg",
                title: "Nothing has reported yet",
                body: "Background services report here as they run. A schedule is the usual way one runs without you.",
                size: .compact,
                accessory: {
                    let button = HelmButton(title: "Open Schedules", variant: .secondary, size: .small)
                    button.target = self
                    button.action = #selector(openSchedulesTapped)
                    button.toolTip = "Unattended runs log their verdict here."
                    return button
                }(),
                hue: RailDestination.health.domainHue)
            empty.applyTheme(theme)
            rows.append(empty)
        } else {
            rows.append(summaryStrip)
            for (index, service) in services.enumerated() {
                if index > 0 { rows.append(separator()) }
                rows.append(healthRow(for: service))
            }
        }

        for row in rows {
            healthStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: healthStack.widthAnchor).isActive = true
        }
    }

    /// `nil` when this run has no crash report to report, which is almost
    /// always. `DiagnosticsLog` answers "none" rather than guessing whenever
    /// it cannot tell - no previous launch recorded, no reports directory, an
    /// unreadable directory - so this row is only ever built from a real file
    /// with a real timestamp after the previous launch.
    private func crashReportRow() -> NSView? {
        let crashes = DiagnosticsLog.shared.crashReportsSinceLastLaunch()
        guard !crashes.isEmpty else { return nil }
        let count = crashes.count == 1 ? "1 crash report" : "\(crashes.count) crash reports"
        let row = HelmAccentRow(hover: false)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.configure(HelmAccentRow.Content(
            tint: .critical,
            kicker: "Since the previous launch",
            title: "\(count) from this app",
            meta: "In ~/Library/Logs/DiagnosticReports: "
                + crashes.joined(separator: ", ")
                + ". \u{201C}Copy diagnostics\u{201D} includes these names and this app\u{2019}s own recent error log.",
            badgeSymbol: "exclamationmark.triangle.fill"), theme: theme)
        return row
    }

    private func healthRow(for service: HealthService) -> NSView {
        let state = ServiceHealthRegistry.shared.state(service)
        let (tint, chip) = Self.healthVisuals(state)

        var lines: [String] = [service.detail]
        if let last = state.lastSuccess {
            lines.append("Last ran \(Self.relative(last)).")
        } else if state.hasReported {
            lines.append("Has never completed successfully.")
        } else {
            lines.append("Not run yet.")
        }
        if let failure = state.lastFailureDetail, let when = state.lastFailure {
            lines.append("Last error (\(Self.relative(when))): \(failure)")
        }

        // §6.5's "34pt gradient tile (solid semantic fill ... when the row's
        // icon expresses state rather than domain)" under Daylight; the twelve
        // palettes keep the `IconTileView` wash they already render. Both are
        // built and exactly one is shown, the same pair `HelmAccentRow` and
        // `HelmEmptyState` already use.
        let daylight = theme.isDaylight
        let tile = IconTileView(size: HelmMetrics.tileSmall, cornerRadius: 8)
        tile.configure(symbol: service.symbol, tint: tint, pointSize: 12)
        tile.applyTheme(theme)
        tile.isHidden = daylight
        let gradientTile = HelmGradientTile(size: .drill)
        gradientTile.configure(symbol: service.symbol, hue: HelmDomainHue(tint: tint))
        gradientTile.isHidden = !daylight

        // §6.8's run ticks, in the trailing column beside the verdict chip.
        let ticks = Self.runTicks(state)
        var trailingViews: [NSView] = []
        if !ticks.isEmpty {
            let ticksLabel = NSTextField(labelWithString: ticks)
            ticksLabel.font = HelmType.code()
            ticksLabel.textColor = HelmTheme.nsColor(
                (state.consecutiveFailures > 0 ? HelmTint.critical : .good).hex(in: theme))
            ticksLabel.toolTip = state.consecutiveFailures > 0
                ? "\(state.consecutiveFailures) consecutive failure(s) since the last recorded success"
                : "The last recorded run succeeded"
            ticksLabel.setContentHuggingPriority(.required, for: .horizontal)
            trailingViews.append(ticksLabel)
        }
        trailingViews.append(pillView(text: chip, tint: tint))
        let trailing = NSStackView(views: trailingViews)
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = HelmMetrics.s2
        trailing.distribution = .fill
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setClippingResistancePriority(.required, for: .horizontal)

        // §6.5's signal edge: a row that needs attention gets the 3pt inset
        // semantic bar plus a wash of the same hue, through the shared helper
        // that exists for exactly this case - a page with its own bespoke row
        // container rather than a `ToolRowLayout.Views`.
        let needsAttention = state.verdict == .degraded || state.verdict == .failing
        let row = descRow(title: service.title, desc: lines.joined(separator: " "),
                          trailing: trailing,
                          signalHex: needsAttention ? tint.hex(in: theme) : nil)
        let combined = NSStackView(views: [tile, gradientTile, row])
        combined.orientation = .horizontal
        combined.alignment = .centerY
        combined.spacing = 10
        combined.distribution = .fill
        // AGENTS.md gotcha (12): a content-priority call is a no-op on an
        // `NSStackView`, so `row` (itself a stack) has to yield through the
        // stack-level API while the leaf tiles hold their size through the
        // content-level one.
        tile.setContentHuggingPriority(.required, for: .horizontal)
        combined.setHuggingPriority(.defaultLow, for: .horizontal)
        return combined
    }

    /// "Copy diagnostics" - the F1 spec's own affordance, wired to
    /// `diagnosticsButton` and positioned by whoever hosts the card (see that
    /// property's own doc comment). Assembles the same text the rows show plus
    /// the recent persistence failures, so a captain can paste it somewhere
    /// without hand-transcribing timestamps. Deliberately not a log dump:
    /// reading the unified log needs a separate tool, and this button must not
    /// be the thing that surprises anyone by exporting more than what is on
    /// screen. Everything stays on this machine - detailed logs are in
    /// Console.app under "com.manjesh.grandline.native".
    @objc private func copyDiagnostics() {
        var lines: [String] = ["Grand Line - service health"]
        for service in ServiceHealthRegistry.shared.knownServices() {
            let state = ServiceHealthRegistry.shared.state(service)
            let (_, chip) = Self.healthVisuals(state)
            var line = "- \(service.title): \(chip)"
            if let last = state.lastSuccess { line += ", last ran \(Self.relative(last))" }
            if let detail = state.lastFailureDetail { line += ", last error: \(detail)" }
            lines.append(line)
        }
        if PersistenceFailureReporter.recent.isEmpty {
            lines.append("- No failed saves recorded this session.")
        } else {
            lines.append("Failed saves this session (newest first):")
            for failure in PersistenceFailureReporter.recent {
                lines.append("- \(failure.what) -> \(failure.path): \(failure.reason)")
            }
        }
        // P9: the two things an investigation an hour later actually wants,
        // and neither was reachable before - `log show` returns nothing for
        // this subsystem and the crash reports sit unread in
        // `~/Library/Logs/DiagnosticReports`. Both are this machine's own
        // files; nothing new leaves it.
        let crashes = DiagnosticsLog.shared.crashReportsSinceLastLaunch()
        if crashes.isEmpty {
            lines.append("No crash report since the previous launch.")
        } else {
            lines.append("Crash reports since the previous launch:")
            for name in crashes { lines.append("- \(name)") }
        }
        let recent = DiagnosticsLog.shared.recentLines()
        if !recent.isEmpty {
            lines.append("Recent diagnostics (newest last):")
            lines.append(contentsOf: recent.map { "  \($0)" })
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        Toast.show(in: card, message: "Diagnostics copied")
        PersistenceFailureReporter.acknowledge()
    }

    private static func healthVisuals(_ state: ServiceHealthState) -> (HelmTint, String) {
        switch state.verdict {
        case .unknown: return (.neutral, "Not run yet")
        case .running: return (.info, "Checking\u{2026}")
        case .healthy: return (.good, "Healthy")
        case .degraded: return (.warn, "1 recent failure")
        case .failing: return (.critical, "Failing")
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = relativeFormatter
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Built once - `DateFormatter`/`RelativeDateTimeFormatter` construction is
    /// expensive and this runs inside a rebuilt row path.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // MARK: Small row builders, moved verbatim from `SettingsController`
    //
    // These no longer need `SettingsController`'s page-wide `hoverRows`/
    // `subtitleViews`/`separatorViews` re-theming registries, because this
    // view rebuilds every row from scratch (with the current `theme` baked
    // in) on every call to `refresh(theme:)` - see this file's header.

    /// - Parameter signalHex: §6.5's signal edge - a 3pt inset bar in this
    ///   hue plus a faint wash of it behind the row. `nil` for an ordinary
    ///   row, which renders exactly as it did before.
    /// - Parameter trailing: this row's own control/chip, or `nil` for a row
    ///   that has none. B3 (`data/grand-line-e2e-audit/report.md`): this used
    ///   to take a non-optional `NSView`, and the footer passed a bare
    ///   `NSView()` as a spacer - a view with no intrinsic size, whose
    ///   `.required` **content** hugging is a no-op (AGENTS.md gotcha 12).
    ///   With the text column deliberately yielding, `.fill` then handed
    ///   nearly the whole row to that empty spacer: the footer's description
    ///   label measured **78.5pt against a 931pt intrinsic width**, rendering
    ///   as `Diagnostics` / `"Copy` - one clipped word of a two-sentence
    ///   explanation, at every window width and in every theme.
    private func descRow(title: String, desc: String, trailing: NSView?,
                         signalHex: String? = nil) -> NSView {
        // D6: `HelmType`, not raw `.systemFont(ofSize:)` sizes - which is
        // also what restores the captain's own chrome-text-scale setting
        // (GL-32) on this page, since every `HelmType` role runs through
        // `HelmType.scaled(_:)`.
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = HelmType.rowTitle()
        let descLabel = NSTextField(wrappingLabelWithString: desc)
        descLabel.font = HelmType.caption()
        descLabel.textColor = HelmTheme.mutedInk(theme)
        // Was a hardcoded 360pt, which is what left the audit's screenshot-4
        // text column adrift in the right half of a wide window. The real
        // width is not known until layout, so it is read back then.
        descLabel.preferredMaxLayoutWidth = descriptionWidth()
        descriptionLabels.append(descLabel)

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        // AGENTS.md gotcha (12): `setContentHuggingPriority` is a no-op on an
        // `NSStackView` (it has no intrinsic content size) - the *stack*-level
        // API (`ToolRowLayout.columnHugging`'s own convention) is what
        // actually lets this column absorb the row's slack.
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        trailing?.translatesAutoresizingMaskIntoConstraints = false
        trailing?.setContentHuggingPriority(.required, for: .horizontal)
        trailing?.setContentCompressionResistancePriority(.required, for: .horizontal)

        // B3: a row with no trailing control is a one-view row, so the text
        // column has nothing to lose its width to. Deliberately not "pass a
        // spacer with a `width == 0` constraint": there is simply nothing to
        // put there, and an empty arranged subview is what caused this.
        let row = NSStackView(views: [textStack, trailing].compactMap { $0 })
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        // AGENTS.md gotcha (10): left at the default `.gravityAreas`
        // distribution, neither view's hugging priority is honoured at all -
        // both land in the center gravity area at their natural size, so
        // `trailing` (the status chip) crams in immediately after the title/
        // description text instead of sitting at the row's trailing edge, the
        // way `HelmCard.setHeader`'s own row already gets right. `.fill` is
        // what makes the hugging/clipping-resistance priorities above matter.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = HoverHighlightView()
        container.cornerRadius = theme.isDaylight ? HelmMetrics.dTileSmall : 8
        container.addSubview(row)
        // A signal row's content is pushed in past its own accent bar; an
        // ordinary row keeps the 8pt inset it always had.
        let leading: CGFloat = signalHex == nil ? 8 : 8 + Self.signalBarWidth + 6
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leading),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        if let signalHex {
            // The shared accent-bar helper (`fm/grandline-setup-attention-row-
            // style`), not a hand-rolled bar - it is the app's one definition
            // of this idiom and already handles the vertical inset that keeps
            // the bar clear of the row's own rounded corners.
            let bar = NSView()
            ToolRowLayout.attachAccentBar(bar, to: container, width: Self.signalBarWidth)
            ToolRowLayout.setAccentBar(bar, colorHex: signalHex)
            // §6.5's "4-8% wash" of the same hue, behind the row.
            let wash = HelmTheme.nsColor(signalHex).withAlphaComponent(Self.signalWashAlpha)
            container.normalColor = wash
            container.hoverColor = wash
        } else {
            container.normalColor = .clear
            container.hoverColor = line.withAlphaComponent(0.18)
        }
        return container
    }

    /// §6.5's signal-edge geometry.
    private static let signalBarWidth: CGFloat = 3
    private static let signalWashAlpha: CGFloat = 0.07

    /// The app's one status pill (audit D3).
    ///
    /// This method used to be a private re-implementation of it, painting the
    /// label in the **raw** tint hue over a 15% wash of itself - which is
    /// exactly the §5.7 contrast defect the first audit measured failing
    /// 4.5:1 in 44 of 72 theme/hue pairs, and which the shared
    /// `ToolRowLayout.pill` fixed (and `HelmContrastSelfTest.checkPills`
    /// guards) via `HelmContrast.tintedSurface`. The regression rode in with
    /// this card when it was moved verbatim out of `SettingsController`; a
    /// contrast fix landed in the shared component is only a fix for the
    /// callers that actually call it.
    private func pillView(text: String, tint: HelmTint) -> NSView {
        let pill = HelmStatusPill()
        pill.configure(text: text, tint: tint, theme: theme)
        return pill
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5).cgColor
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugRowCount: Int { healthStack.arrangedSubviews.count }
    /// P4: how many full row rebuilds this card has actually performed, so a
    /// test can count them rather than infer them.
    private(set) var debugRebuildCount = 0
    var debugPendingWhileHidden: Bool { pendingWhileHidden }
    /// §7's KPI chips - how many the header band is currently showing.
    /// UI-56: the KPI line's figures, as rendered - empty while it is not
    /// in the card.
    var debugSummaryValues: [String] { summaryStrip.superview == nil ? [] : summaryStrip.debugValues }
    var debugMetricCards: [HelmMetricCard] { [healthyCard, warningsCard, failingCard, pendingCard] }
    var debugServicesTable: HelmDataTable { servicesTable }
    /// Rebuild now, whether or not the card is on screen.
    func debugRebuild() { rebuild() }
    #endif
}
