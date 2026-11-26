// Grand Line - native macOS app.
//
// Connections' hero column (C-4 on the page-redesign board, the captain's
// pick).
//
// The page's split sidebar was its nav column, which went because the
// toolbar carries the tabs. C-4 puts a `HelmHeroColumn` in that pane
// instead: the session verdict and the online ring, the three hosts
// connected most recently with a Switch or Connect pill each, a Quick connect
// field, and the Keys / Snippets / Groups figures at its foot. The host cards
// (C-1's 98pt card, `HelmCardGrid` 1.1.0) fill the rest, two to a row.
//
// **Recent is the column's job while the column shows.** The grid's own
// Recent row (X2) goes, and it comes back above All hosts whenever the column
// is put away - a page too narrow for both (`heroCollapseWidth`, which the
// shell's inspector opening can cause), or the captain's Toggle Sidebar - so
// the hosts the captain reaches for are never more than a glance away. The
// filter row's find-or-connect field (H3) is unchanged: it still finds, and
// Return still connects; the column's field only connects.
//
// On the Keys tab the same column speaks for the keys instead
// (`HostsController+KeysHero.swift`): it follows the showing tab.
//
// Every action the column runs is the page's own - `connect`,
// `onSwitchToSession`, `quickConnectTarget` - so nothing here can connect
// differently from a card, a row or the filter row's field.

import AppKit

/// What Connections' hero column says, from the stores and the live sessions.
/// A pure value, asserted headless (`PageHeroColumnsSelfTest`).
struct ConnectionsHeroWords: Equatable {

    struct LiveSession: Equatable {
        let label: String
        let startedAt: Date
    }

    let headline: String
    let body: String
    /// Hosts with a live session over saved hosts, or `nil` with no saved
    /// host, or a `hosts.json` that could not be read (GL-14).
    let ring: (online: Int, total: Int)?
    let ringCaption: String
    /// The column dims while the saved hosts could not be read.
    let isDimmed: Bool

    static func == (a: ConnectionsHeroWords, b: ConnectionsHeroWords) -> Bool {
        a.headline == b.headline && a.body == b.body && a.ring?.online == b.ring?.online
            && a.ring?.total == b.ring?.total && a.ringCaption == b.ringCaption && a.isDimmed == b.isDimmed
    }

    static func make(hostsReadable: Bool, hostCount: Int, live: [LiveSession], keyCount: Int,
                     biometryAvailable: Bool, snippetCount: Int, lastConnected: (label: String, at: Date)?,
                     now: Date = Date()) -> ConnectionsHeroWords {
        guard hostsReadable else {
            return ConnectionsHeroWords(
                headline: "Saved hosts could not be read.",
                body: "Your hosts file is still on disk. Quick connect works while it is unreadable.",
                ring: nil, ringCaption: "", isDimmed: true)
        }
        let keys: String
        switch keyCount {
        case 0: keys = ""
        case 1: keys = biometryAvailable ? "1 key ready with Touch ID." : "1 key in the Keychain."
        default: keys = biometryAvailable ? "\(keyCount) keys ready with Touch ID." : "\(keyCount) keys in the Keychain."
        }
        let headline: String
        var body: String
        if live.count == 1, let session = live.first {
            headline = "1 live session, on \(session.label)."
            body = "Open for \(duration(since: session.startedAt, now: now))."
        } else if live.count > 1 {
            headline = "\(live.count) live sessions."
            let names = live.prefix(2).map(\.label)
            body = live.count > 2
                ? "\(names.joined(separator: ", ")) and \(live.count - 2) more."
                : "\(names.joined(separator: " and "))."
        } else if hostCount == 0 {
            headline = "No saved hosts yet."
            body = "Add a host, or type user@host below to connect without saving it."
        } else {
            headline = "No live session."
            if let lastConnected {
                body = "Last connected to \(lastConnected.label) \(HostsController.relativeText(lastConnected.at, now: now))."
            } else {
                body = "Pick a host to connect, or type user@host below."
            }
        }
        if !keys.isEmpty { body += " " + keys }
        let snippets = snippetCount == 1 ? "1 snippet" : "\(snippetCount) snippets"
        return ConnectionsHeroWords(
            headline: headline, body: body,
            ring: hostCount > 0 ? (live.count, hostCount) : nil,
            ringCaption: "hosts online\n\(hostCount) saved \u{00B7} \(snippets)",
            isDimmed: false)
    }

    /// "42 minutes", "1 hour", "3 hours" - how long a session has been open,
    /// in words for a sentence.
    static func duration(since start: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}

extension HostsController {

    /// The least the page is ever allowed before the column goes: the
    /// column, its gutters and one 280pt card column with room for its
    /// address.
    static let heroCollapseWidth: CGFloat = 880

    /// Below this page width the column is put away and Recent goes back
    /// into the grid: the column, its gap, and the narrowest the showing
    /// tab's top row can be (its search, filters and switches) before the
    /// window would have to grow for it (gotcha (13)), or `heroCollapseWidth`
    /// if that is more.
    func heroCollapseThreshold() -> CGFloat {
        let row: NSView?
        switch activeTab {
        case .hosts: row = hostsFilterRow
        case .keys: row = keysTopRow
        case .snippets: row = nil
        }
        var floor = row.map(HelmSplitPage.floorWidth(of:)) ?? 0
        // Measured beside the column, which hides H3's Connect button.
        if activeTab == .hosts { floor -= findOrConnectRoom }
        let column = HelmMetrics.pageGutter + HelmHeroColumn.width + HelmMetrics.s5
        return max(Self.heroCollapseWidth, column + floor + HelmMetrics.pageGutter + HelmMetrics.s2)
    }

    /// UX-27: Quick connect's width on the band.
    static let bandQuickConnectWidth: CGFloat = 220

    /// The column's three hosts.
    static let heroRecentLimit = 3

    /// The column is on screen: built, and its pane open.
    var heroColumnShowing: Bool {
        guard let heroColumn, !heroColumn.isHidden, let split = splitPage else { return false }
        return !split.isSidebarCollapsed
    }

    /// The column is on screen or on its way back: what the filter row's
    /// floor is measured against.
    var heroColumnWanted: Bool {
        guard let heroColumn, !heroColumn.isHidden, let split = splitPage else { return false }
        return split.sidebarIsWanted
    }

    /// Build the column and put it in the split's sidebar pane.
    func adoptHeroColumn() {
        guard heroColumn == nil, let split = splitPage else { return }
        let column = HelmHeroColumn()
        column.setAccessibilityLabel("Connections summary")
        heroColumn = column
        heroQuickConnectField.onCommand = { [weak self] selector in
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            self?.heroQuickConnect()
            return true
        }
        heroQuickConnectField.setAccessibilityLabel("Quick connect: type user@host and press Return")
        // UX-27: on the band the field keeps a usable width beside the
        // figures; in the column it is wider than this anyway.
        heroQuickConnectField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.bandQuickConnectWidth).isActive = true
        heroQuickConnectField.toolTip = "Type user@host, or a saved host's name, and press Return to connect"
        HelmSplitPage.pin(column, in: split.sidebarPane,
                          insets: NSEdgeInsets(top: HelmMetrics.pageContentInset, left: HelmMetrics.pageGutter,
                                               bottom: HelmMetrics.pageGutter, right: 0),
                          yieldsWidth: true)
        // The column's own width: the board's 300pt. The split was built with
        // a low minimum, so the content's floor squeezes it rather than
        // growing the window, and the width rule then puts the column away
        // (`HelmSplitPage` 1.2.0).
        split.preferredSidebarWidth = HelmMetrics.pageGutter + HelmHeroColumn.width
        split.onNarrowChanged = { [weak self] _ in self?.refreshFindOrConnectButton() }
        split.onSidebarCollapseChanged = { [weak self] _ in
            // Reported from inside the split's own resize; the grid's
            // re-render waits a turn.
            DispatchQueue.main.async { self?.heroColumnVisibilityChanged() }
        }
        refreshSplitColumn()
        renderHeroColumn()
    }

    /// The pane holds the hero column, which the width rule puts away on a
    /// page too narrow for both it and the showing tab's top row.
    func refreshSplitColumn() {
        guard let split = splitPage, heroColumn != nil else { return }
        split.collapsesBelowWidth = heroCollapseThreshold()
        refreshContentLeading()
    }

    /// The column was put away or came back: the content's leading gap
    /// follows, and Recent moves between the column and the grid.
    func heroColumnVisibilityChanged() {
        placeHeroColumn()
        refreshContentLeading()
        refreshExpansionStripPlacement()
        applyHostFilter(searchField.stringValue)
        reloadKeysForSearch()
        refreshFindOrConnectButton()
    }

    /// UX-27: the column in the split's pane, or across the top of the tabs
    /// as Health's one-line band while the pane is put away (a window under
    /// about 1200pt, or the inspector open), so the page keeps its verdict,
    /// its ring and Quick connect.
    func placeHeroColumn() {
        guard let column = heroColumn, let split = splitPage else { return }
        let asBand = !split.sidebarIsWanted || split.isSidebarCollapsed
        let alreadyThere = asBand ? column.superview === bandHost : column.superview === split.sidebarPane
        guard !alreadyThere else { return }
        column.removeFromSuperview()
        column.setArrangement(asBand ? .band : .column)
        if asBand {
            column.translatesAutoresizingMaskIntoConstraints = false
            bandHost.addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: bandHost.topAnchor),
                column.leadingAnchor.constraint(equalTo: bandHost.leadingAnchor),
                column.trailingAnchor.constraint(equalTo: bandHost.trailingAnchor),
                column.bottomAnchor.constraint(equalTo: bandHost.bottomAnchor),
            ])
        } else {
            HelmSplitPage.pin(column, in: split.sidebarPane,
                              insets: NSEdgeInsets(top: HelmMetrics.pageContentInset, left: HelmMetrics.pageGutter,
                                                   bottom: HelmMetrics.pageGutter, right: 0),
                              yieldsWidth: true)
        }
        for gap in bandGaps { gap.constant = asBand ? HelmMetrics.s4 : 0 }
        renderHeroColumn()
    }

    /// UX-27: the column is drawn as the band over the tabs.
    var heroIsBand: Bool { heroColumn?.superview === bandHost }

    // MARK: Rendering

    /// Fill the column from the stores and the live sessions. Called from
    /// every reload that can change what it says.
    func renderHeroColumn() {
        guard let column = heroColumn else { return }
        refreshExpansionStripPlacement()
        if activeTab == .keys {
            renderKeysHeroColumn(column)
            return
        }
        if activeTab == .snippets {
            renderSnippetsHeroColumn(column)
            return
        }
        let hosts = hostStore.hosts
        let readable = hostStore.loadStatus == .clean
        let live = hosts.compactMap { host -> ConnectionsHeroWords.LiveSession? in
            guard let session = liveSession?(host.id), session.isConnected else { return nil }
            return .init(label: host.label, startedAt: session.startedAt)
        }.sorted { $0.startedAt < $1.startedAt }
        let recent = Self.recentHosts(hosts, limit: Self.heroRecentLimit)
        let words = ConnectionsHeroWords.make(
            hostsReadable: readable, hostCount: hosts.count, live: live, keyCount: keyStore.keys.count,
            biometryAvailable: CredentialVaultKeyStore.biometryAvailable, snippetCount: snippetStore.snippets.count,
            lastConnected: recent.first.flatMap { host in host.lastConnectedAt.map { (host.label, $0) } })
        let ring = words.ring.map { ring in
            HelmHeroColumn.Ring(fraction: ring.total > 0 ? Double(ring.online) / Double(ring.total) : 0,
                                label: "\(ring.online)/\(ring.total)", caption: words.ringCaption,
                                spoken: "\(ring.online) of \(ring.total) saved hosts online", state: .ok)
        }
        let header = HelmHeroColumn.Header(symbol: "server.rack", kicker: "Connections",
                                           headline: words.headline, body: words.body, ring: ring)

        heroRecentRuns = []
        var recentRows: [NSView] = recent.map { host in
            let session = liveSession?(host.id)
            let pill: HelmButton
            if session != nil {
                pill = HelmButton(title: "Switch", variant: .secondary, size: .small,
                                  target: self, action: #selector(heroRecentTapped(_:)))
                pill.toolTip = "Switch to \(host.label)'s session"
                heroRecentRuns.append { [weak self] in self?.onSwitchToSession?(host.id) }
            } else {
                pill = HelmButton(title: "", variant: .secondary, size: .small, symbol: "bolt.fill",
                                  target: self, action: #selector(heroRecentTapped(_:)))
                pill.toolTip = "Connect to \(host.label)"
                heroRecentRuns.append { [weak self] in self?.connect(host) }
            }
            pill.tag = heroRecentRuns.count - 1
            pill.setAccessibilityLabel(pill.toolTip)
            return HelmHeroRow(leading: .symbol(host.iconSymbol), title: host.label, subtitle: host.subtitle,
                               subtitleIsCode: true, subtitleTruncation: .byTruncatingMiddle, trailing: pill)
        }
        if recentRows.isEmpty {
            recentRows = [HelmHeroRow(leading: .symbol("clock"), title: "Nothing yet",
                                      subtitle: "The hosts you connect to show here.")]
        }
        // UX-27: the band has no sections, so Quick connect moves to its
        // foot beside the figures.
        let bandFoot: [NSView] = heroIsBand ? [heroQuickConnectField] : []
        column.configure(
            header: header,
            sections: heroIsBand ? [] : [
                .init(title: "Recent", trailing: recent.isEmpty ? nil : "\(recent.count)", views: recentRows),
                .init(title: "Quick connect", trailing: nil, views: [heroQuickConnectField]),
            ],
            foot: bandFoot + [heroFootFigures()],
            tone: HelmModuleCard.HeroTone(colour: .themeAccent, isDimmed: words.isDimmed))
    }

    /// The column's foot on every tab: the Keys, Snippets and Groups figures.
    func heroFootFigures() -> HelmKPIStrip {
        let groups = Set(hostStore.hosts.compactMap { normalizedGroup($0) }).count
        let figures = HelmKPIStrip(density: .inline)
        figures.figureSize = 20
        figures.configure([
            .count(keyStore.keys.count, caption: "Keys"),
            .count(snippetStore.snippets.count, caption: "Snippets"),
            .count(groups, caption: groups == 1 ? "Group" : "Groups"),
        ])
        figures.setAccessibilityLabel("Keys, snippets and groups")
        return figures
    }

    @objc func heroRecentTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < heroRecentRuns.count else { return }
        heroRecentRuns[sender.tag]()
    }

    /// Return in the column's field: what Return in the filter row's field
    /// runs - a saved host by name, else an ad-hoc `[user@]host[:port]` - and
    /// a beep for anything else.
    func heroQuickConnect() {
        let text = heroQuickConnectField.stringValue
        switch quickConnectTarget(for: text) {
        case .saved(let host)?:
            connect(host)
            heroQuickConnectField.stringValue = ""
        case .adHoc(let label, let args)?:
            onConnect?(nil, label, args, nil, nil, nil)
            heroQuickConnectField.stringValue = ""
        case nil:
            NSSound.beep()
        }
    }
}
