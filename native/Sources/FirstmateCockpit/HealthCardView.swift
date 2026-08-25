// Manjesh Grand Line - native macOS app.
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

    private let healthStack = NSStackView()
    /// §7's "KPI chips in the header band region" - one per non-zero verdict
    /// bucket, in the card header's trailing action slot. Rebuilt in place
    /// (`refreshHeaderChips`) rather than recreated, so the header's own
    /// action stack is built once.
    private let headerChips = NSStackView()
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
        headerChips.orientation = .horizontal
        headerChips.alignment = .centerY
        headerChips.spacing = HelmMetrics.s1
        headerChips.distribution = .fill
        headerChips.translatesAutoresizingMaskIntoConstraints = false
        // AGENTS.md gotcha (12): the *stack*-level pair, not the content one -
        // this stack has no intrinsic content size, so without these it is
        // what the header's `.fill` distribution stretches.
        headerChips.setHuggingPriority(.required, for: .horizontal)
        headerChips.setClippingResistancePriority(.required, for: .horizontal)
        card.setHeader(
            symbol: "waveform.path.ecg",
            tint: .good,
            title: "Background services",
            subtitle: "Last run and last error for each one",
            actions: [headerChips]
        )
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

    /// Whether a rebuild would be visible to anyone.
    private var isOnScreen: Bool {
        card.window != nil && !card.isHiddenOrHasHiddenAncestor
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

    /// A streak longer than this is reported as a count in the row's own copy
    /// ("Last error ...") rather than as an unbounded glyph run.
    private static let maxRunTicks = 5

    /// One chip per non-empty bucket, most urgent first. Rebuilt in place -
    /// the header's action stack itself is built once, in `buildCard`.
    private func refreshHeaderChips() {
        for v in headerChips.arrangedSubviews {
            headerChips.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let counts = Self.verdictCounts()
        let buckets: [(Int, String, HelmTint)] = [
            (counts.failing, "failing", .critical),
            (counts.degraded, "recent failure", .warn),
            (counts.healthy, "healthy", .good),
            (counts.pending, "not run yet", .neutral),
        ]
        for (count, label, tint) in buckets where count > 0 {
            headerChips.addArrangedSubview(
                pillView(text: "\(count) \(label)", colorHex: tint.hex(in: theme)))
        }
        headerChips.isHidden = headerChips.arrangedSubviews.isEmpty
    }

    private func rebuild() {
        #if FM_SELFTESTS
        debugRebuildCount += 1
        #endif
        refreshHeaderChips()
        descriptionLabels.removeAll()
        for v in healthStack.arrangedSubviews {
            healthStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let services = ServiceHealthRegistry.shared.knownServices()
        var rows: [NSView] = []

        if services.isEmpty {
            // Honest rather than reassuring: nothing has reported yet, which at
            // launch is simply true.
            let label = NSTextField(wrappingLabelWithString:
                "No background service has reported yet. Rows appear as each one runs.")
            label.font = HelmType.caption()
            label.textColor = HelmTheme.mutedInk(theme)
            label.preferredMaxLayoutWidth = descriptionWidth()
            descriptionLabels.append(label)
            rows.append(label)
        } else {
            for (index, service) in services.enumerated() {
                if index > 0 { rows.append(separator()) }
                rows.append(healthRow(for: service))
            }
        }

        rows.append(separator())
        rows.append(healthFooter())

        for row in rows {
            healthStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: healthStack.widthAnchor).isActive = true
        }
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
        trailingViews.append(pillView(text: chip, colorHex: tint.hex(in: theme)))
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

    /// "Copy diagnostics" - the F1 spec's own affordance. Assembles the same
    /// text the rows show plus the recent persistence failures, so a captain can
    /// paste it somewhere without hand-transcribing timestamps. Deliberately not
    /// a log dump: reading the unified log needs a separate tool, and this
    /// button must not be the thing that surprises anyone by exporting more than
    /// what is on screen.
    /// The footer explains what "Copy diagnostics" does; the button itself has
    /// moved into the drill header (§7), so this row carries no control - a
    /// second copy of the same button a few rows apart is exactly the
    /// duplication §6.4's action cluster exists to remove.
    private func healthFooter() -> NSView {
        // B3: `nil`, not a bare spacer - see `descRow`'s own parameter note.
        return descRow(title: "Diagnostics",
                       desc: "\"Copy diagnostics\" in the page header copies these rows as text. "
                           + "Everything stays on this machine - detailed logs are in Console.app "
                           + "under \"com.firstmate.cockpit.native\".",
                       trailing: nil)
    }

    @objc private func copyDiagnostics() {
        var lines: [String] = ["Manjesh Grand Line - service health"]
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
    private func pillView(text: String, colorHex: String) -> NSView {
        let pill = NSView()
        ToolRowLayout.pill(text: text, colorHex: colorHex, into: pill,
                           label: NSTextField(labelWithString: ""), theme: theme)
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
    var debugHeaderChipCount: Int { headerChips.isHidden ? 0 : headerChips.arrangedSubviews.count }
    #endif
}
