// Grand Line - native macOS app.
//
// Connections' hero column on the Snippets tab (UI-10 of full review 4).
//
// Keys got its own words in PR 616. Snippets fell through to the Hosts words,
// so the column said "No live session. Pick a host to connect" with a ring of
// hosts online and a Quick connect field beside a table of snippets. Now it
// speaks for snippets: how many there are and how many expand in every app,
// the trigger switch with its Accessibility state (moved here out of the
// page body), and the snippets that have a trigger.
//
// The review asked for the most used snippet. Nothing records a snippet's
// uses, and the column does not invent a reading (GL-14), so it lists the
// snippets with a trigger instead, the ones that expand in every app first.
//
// The switch and Grant access run the page's own handlers - the same ones
// the strip over the table runs, which comes back whenever the column is put
// away, so the switch is never out of reach.

import AppKit

/// What Connections' hero column says on the Snippets tab. A pure value,
/// asserted headless (`PageHeroColumnsSelfTest`).
struct SnippetsHeroWords: Equatable {

    let headline: String
    let body: String
    /// The trigger switch's state, in the strip's own words.
    let status: String
    let statusOK: Bool
    /// The column dims while the saved snippets could not be read.
    let isDimmed: Bool

    static func make(snippetsReadable: Bool, snippets: [Snippet], enabled: Bool, trusted: Bool, armed: Bool)
        -> SnippetsHeroWords {
        let triggered = snippets.filter { !$0.normalizedTrigger.isEmpty }
        let state = SnippetExpansionPanel.status(enabled: enabled, trusted: trusted, armed: armed,
                                                 triggerCount: triggered.count)
        guard snippetsReadable else {
            return SnippetsHeroWords(headline: "Saved snippets could not be read.",
                                     body: "Your snippets file is still on disk, backed up before any new save.",
                                     status: state.text, statusOK: state.ok, isDimmed: true)
        }
        guard !snippets.isEmpty else {
            return SnippetsHeroWords(
                headline: "No snippets yet.",
                body: "Save a command you type often, and give it a trigger such as ;duh to expand it as you type.",
                status: state.text, statusOK: state.ok, isDimmed: false)
        }
        let count = snippets.count == 1 ? "1 snippet" : "\(snippets.count) snippets"
        let everywhere = triggered.filter(\.expandsSystemWide)
        let headline: String
        if !everywhere.isEmpty {
            headline = "\(count), \(everywhere.count) \(everywhere.count == 1 ? "expands" : "expand") everywhere."
        } else if !triggered.isEmpty {
            headline = "\(count), \(triggered.count) with a trigger."
        } else {
            headline = "\(count), none with a trigger yet."
        }
        let body: String
        if let example = everywhere.first?.triggerDisplay {
            body = "Type a trigger such as \(example) in any app."
        } else if let example = triggered.first?.triggerDisplay {
            body = "Type a trigger such as \(example) in the Console."
        } else {
            body = "Give a snippet a trigger in its editor to expand it as you type."
        }
        return SnippetsHeroWords(headline: headline, body: body, status: state.text, statusOK: state.ok,
                                 isDimmed: false)
    }

    /// The snippets the column lists: those with a trigger, the ones that
    /// expand in every app first, then by name.
    static func listed(_ snippets: [Snippet], limit: Int) -> [Snippet] {
        let triggered = snippets.filter { !$0.normalizedTrigger.isEmpty }
        let sorted = triggered.sorted { a, b in
            if a.expandsSystemWide != b.expandsSystemWide { return a.expandsSystemWide }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
        return Array(sorted.prefix(limit))
    }
}

extension HostsController {

    /// The column's three snippets, as it has three hosts and three keys.
    static let heroSnippetLimit = 3

    /// Fill the column for the Snippets tab. `renderHeroColumn` hands over to
    /// this while Snippets shows.
    func renderSnippetsHeroColumn(_ column: HelmHeroColumn) {
        let snippets = snippetStore.snippets
        let state = snippetExpansionState?() ?? (enabled: false, trusted: false, armed: false, triggerCount: 0)
        let words = SnippetsHeroWords.make(snippetsReadable: snippetStore.loadStatus == .clean, snippets: snippets,
                                           enabled: state.enabled, trusted: state.trusted, armed: state.armed)
        let header = HelmHeroColumn.Header(symbol: "chevron.left.forwardslash.chevron.right", kicker: "Snippets",
                                           headline: words.headline, body: words.body, ring: nil)

        // The switch: the kit's segmented control, which the column inks.
        let toggle = HelmSegmentedTabs(items: [.init(id: "off", title: "Off"), .init(id: "on", title: "On")],
                                       selected: state.enabled ? "on" : "off", size: .compact)
        toggle.setAccessibilityLabel("Expand triggers while I type")
        toggle.onSelect = { [weak self] id in
            self?.onSnippetExpansionToggled?(id == "on")
            self?.refreshExpansionPanel()
        }
        var switchViews: [NSView] = [toggle]
        heroRecentRuns = []
        if !state.trusted {
            let grant = HelmButton(title: "Grant access\u{2026}", variant: .secondary, size: .small,
                                   symbol: "lock.open", target: self, action: #selector(heroRecentTapped(_:)))
            heroRecentRuns.append { [weak self] in
                self?.onRequestAccessibilityTrust?()
                self?.refreshExpansionPanel()
            }
            grant.tag = heroRecentRuns.count - 1
            grant.toolTip = SnippetExpansionPanel.reason
            grant.setContentHuggingPriority(.required, for: .horizontal)
            switchViews.append(grant)
        }
        let switchRow = NSStackView(views: switchViews)
        switchRow.orientation = .horizontal
        switchRow.spacing = HelmMetrics.s2
        switchRow.alignment = .centerY
        switchRow.setHuggingPriority(.required, for: .horizontal)
        let statusRow = HelmHeroRow(leading: .symbol(words.statusOK ? "checkmark.circle" : "exclamationmark.circle"),
                                    title: words.status,
                                    subtitle: state.trusted ? nil : "Needed to type into other apps.")

        let listed = SnippetsHeroWords.listed(snippets, limit: Self.heroSnippetLimit)
        var rows: [NSView] = listed.map { snippet in
            HelmHeroRow(leading: .symbol("chevron.left.forwardslash.chevron.right"), title: snippet.label,
                        subtitle: [snippet.triggerDisplay, snippet.scope.title].compactMap { $0 }
                            .joined(separator: " \u{00B7} "))
        }
        if rows.isEmpty {
            rows = [HelmHeroRow(leading: .symbol("keyboard"), title: "No triggers yet",
                                subtitle: "A snippet with a trigger shows here.")]
        }
        column.configure(
            header: header,
            sections: [
                .init(title: "Expand while I type", trailing: nil, views: [switchRow, statusRow]),
                .init(title: "Triggers", trailing: listed.isEmpty ? nil : "\(listed.count)", views: rows),
            ],
            foot: [heroFootFigures()],
            tone: HelmModuleCard.HeroTone(colour: .themeAccent, isDimmed: words.isDimmed))
    }
}
