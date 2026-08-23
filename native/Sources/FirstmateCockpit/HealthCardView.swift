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

    private let healthStack = NSStackView()
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init() {
        super.init()
        buildCard()
        // Rebuilt on every report rather than mutated in place: the row count
        // grows as services register, and a row's trailing control differs by
        // verdict (a pill, or nothing).
        ServiceHealthRegistry.shared.observe { [weak self] _ in
            self?.rebuild()
        }
    }

    private func buildCard() {
        card.setHeader(
            symbol: "waveform.path.ecg",
            tint: .good,
            title: "Health",
            subtitle: "Last run and last error for each background service"
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
        rebuild()
    }

    // MARK: Rendering

    private func rebuild() {
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
            label.font = .systemFont(ofSize: 11)
            label.textColor = HelmTheme.mutedInk(theme)
            label.preferredMaxLayoutWidth = 420
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

        let tile = IconTileView(size: HelmMetrics.tileSmall, cornerRadius: 8)
        tile.configure(symbol: service.symbol, tint: tint, pointSize: 12)
        tile.applyTheme(theme)
        let row = descRow(title: service.title, desc: lines.joined(separator: " "),
                          trailing: pillView(text: chip, colorHex: tint.hex(in: theme)))
        let combined = NSStackView(views: [tile, row])
        combined.orientation = .horizontal
        combined.alignment = .centerY
        combined.spacing = 10
        combined.distribution = .fill
        // AGENTS.md gotcha (12): a content-priority call is a no-op on an
        // `NSStackView`, so `row` (itself a stack) has to yield through the
        // stack-level API while the leaf tile holds its size through the
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
    private func healthFooter() -> NSView {
        let button = HelmButton(title: "Copy diagnostics", variant: .secondary,
                                symbol: "doc.on.doc", target: self, action: #selector(copyDiagnostics))
        button.controlSize = .small
        let row = descRow(title: "Diagnostics",
                          desc: "Copies these rows as text. Everything stays on this machine - "
                              + "detailed logs are in Console.app under \"com.firstmate.cockpit.native\".",
                          trailing: button)
        return row
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

    private func descRow(title: String, desc: String, trailing: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        let descLabel = NSTextField(wrappingLabelWithString: desc)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = HelmTheme.mutedInk(theme)
        descLabel.preferredMaxLayoutWidth = 360

        let textStack = NSStackView(views: [titleLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [textStack, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = HoverHighlightView()
        container.cornerRadius = 8
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        container.normalColor = .clear
        container.hoverColor = line.withAlphaComponent(0.18)
        return container
    }

    private func pillView(text: String, colorHex: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = HelmTheme.nsColor(colorHex)
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.backgroundColor = HelmTheme.nsColor(colorHex).withAlphaComponent(0.15).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
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
    #endif
}
