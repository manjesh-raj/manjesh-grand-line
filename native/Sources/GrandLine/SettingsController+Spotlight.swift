// Grand Line - native macOS app.
//
// F-04 of full review 4, the Settings half: what goes into Spotlight, what
// Spotlight may show while Grand Line is locked, and "Remove all from
// Spotlight". It sits on the Security page because it is a decision about
// what other apps and the system search can see. Secrets are listed as
// "Never indexed" with no control, because there is nothing to turn on.

import AppKit

extension SettingsController {

    /// The rows the section draws, by kind, in the mock-up's order.
    static let spotlightRows: [(kind: SpotlightEntry.Kind, title: String)] = [
        (.task, "Tasks"), (.followUp, "Follow-ups"), (.note, "Notebook pages"),
        (.link, "Reading list"), (.sticky, "Sticky notes"), (.runbook, "Runbooks"),
    ]

    func buildSpotlightSection() -> SettingsSection {
        let indexer = GrandLineServices.shared.spotlightIndexer
        var rows: [SettingsRow] = []

        let master = HelmToggle()
        master.isOn = AppSettings.shared.spotlightEnabled
        master.onToggle = { [weak master] in
            AppSettings.shared.spotlightEnabled = master?.isOn ?? true
            GrandLineServices.shared.spotlightIndexer?.rebuild()
        }
        rows.append(SettingsRow(title: "Show in Spotlight",
                                description: "What other apps and the system search can find. Everything stays on this Mac.",
                                control: master))

        for row in Self.spotlightRows {
            let toggle = HelmToggle()
            toggle.isOn = !AppSettings.shared.spotlightDisabledKinds.contains(row.kind)
            toggle.onToggle = { [weak toggle] in
                var disabled = AppSettings.shared.spotlightDisabledKinds
                if toggle?.isOn ?? true { disabled.remove(row.kind) } else { disabled.insert(row.kind) }
                AppSettings.shared.spotlightDisabledKinds = disabled
                GrandLineServices.shared.spotlightIndexer?.rebuild()
            }
            let count = indexer.map { "\($0.count(of: row.kind))" }
            rows.append(SettingsRow(title: row.title, description: count.map { "\($0) indexed" }, control: toggle))
        }

        let never = NSTextField(labelWithString: "Never indexed")
        never.font = HelmType.caption()
        never.textColor = HelmTheme.mutedInk(ThemeManager.shared.theme)
        rows.append(SettingsRow(title: "Secrets", description: "Vault items, Automic Vault and the clipboard history are never handed to Spotlight.",
                                control: never))

        let locked = HelmSegmentedTabs(items: SpotlightIndex.LockedMode.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                       selected: AppSettings.shared.spotlightLockedMode.rawValue, size: .compact)
        // A segmented row has no intrinsic width to hug with, so a low
        // priority zero width pulls it to the trailing edge (gotcha (12)).
        let hug = locked.widthAnchor.constraint(equalToConstant: 0)
        hug.priority = NSLayoutConstraint.Priority(252)
        hug.isActive = true
        locked.onSelect = { id in
            AppSettings.shared.spotlightLockedMode = SpotlightIndex.LockedMode(rawValue: id) ?? .titlesOnly
            GrandLineServices.shared.spotlightIndexer?.rebuild()
        }
        rows.append(SettingsRow(title: "While Grand Line is locked",
                                description: "Spotlight keeps what was indexed. Choose what it may show.",
                                control: locked))

        let remove = HelmButton(title: "Remove all from Spotlight", variant: .secondary, size: .small,
                                target: self, action: #selector(removeAllFromSpotlight))
        rows.append(SettingsRow(title: Self.spotlightSummary(indexer), description: nil, control: remove))

        return SettingsSection(heading: "Show in Spotlight", group: SettingsGroup(rows: rows),
                               foot: "Return on a Spotlight result opens Grand Line on that item. While the app is locked it opens after the unlock.")
    }

    /// "138 items · updated 10:41", or "Not indexed yet".
    static func spotlightSummary(_ indexer: SpotlightIndexer?) -> String {
        guard let indexer, let at = indexer.lastUpdatedAt else { return "Not indexed yet" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let n = indexer.lastWrittenCount
        return "\(n) item\(n == 1 ? "" : "s") \u{00B7} updated \(f.string(from: at))"
    }

    @objc func removeAllFromSpotlight() {
        GrandLineServices.shared.spotlightIndexer?.removeAll()
        Toast.show(in: view, message: "Removed from Spotlight. Turn Show in Spotlight off to keep it that way.")
    }
}
