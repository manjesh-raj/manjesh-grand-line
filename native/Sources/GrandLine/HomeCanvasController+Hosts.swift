// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: the Hosts card and its hero.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    func fillHosts(_ content: inout HelmModuleCard.Content, width: CGFloat) {
        // `fm/grandline-rail-icons-batch2`: the captain's own hosts
        // artwork, replacing the plain `server.rack` glyph - matches
        // `RailDestination.drillHeaderArtwork`'s `.hosts` case.
        content.artwork = HostsIcon.image
        fillHostsHero(&content, width: width)
    }

    // MARK: The Hosts hero card

    /// What the Hosts hero says. `static` and pure, so a suite can assert
    /// every state from fabricated hosts.
    struct HostsHero: Equatable {
        let headline: String
        let body: String
        let ring: HelmModuleCard.HeroRing?
        /// "Recent", or "Saved hosts" before anything has been connected to.
        let sectionTitle: String
        /// The rows' hosts, in order.
        let hostIDs: [UUID]
        /// GL-14: the hosts file could not be read, so the colour dims.
        let isStale: Bool
    }

    /// How many hosts the card lists.
    static let hostsHeroRowLimit = 3

    static func hostsHero(hosts: [Host], readable: Bool, live: [UUID: Date],
                          now: Date = Date()) -> HostsHero {
        guard readable else {
            return HostsHero(headline: "Saved hosts could not be read.",
                             body: "Your hosts file is still on disk. Open \(PlaceName.of(.hosts)) to see why.",
                             ring: nil, sectionTitle: "Recent", hostIDs: [], isStale: true)
        }
        let liveHosts = hosts.filter { live[$0.id] != nil }
            .sorted { (live[$0.id] ?? now) < (live[$1.id] ?? now) }
        let recent = HostsController.recentHosts(hosts, limit: hostsHeroRowLimit)
        let headline: String
        let body: String
        if liveHosts.count == 1, let host = liveHosts.first {
            headline = "1 live session, on \(host.label)."
            body = "Open for \(ConnectionsHeroWords.duration(since: live[host.id] ?? now, now: now))."
        } else if liveHosts.count > 1 {
            headline = "\(liveHosts.count) live sessions."
            let names = liveHosts.prefix(2).map(\.label)
            body = liveHosts.count > 2
                ? "\(names.joined(separator: ", ")) and \(liveHosts.count - 2) more."
                : "\(names.joined(separator: " and "))."
        } else if hosts.isEmpty {
            headline = "No saved hosts yet."
            body = "Add a host in \(PlaceName.of(.hosts)) and it connects from here in a click."
        } else if let last = recent.first, let at = last.lastConnectedAt {
            headline = "No live session."
            body = "Last connected to \(last.label) \(HostsController.relativeText(at, now: now))."
        } else {
            headline = "No live session."
            body = "Pick a host to connect."
        }
        // Recent first; before anything has been connected to, the saved
        // hosts in their own order, so the card is never a list of nothing.
        let shown = recent.isEmpty ? Array(hosts.prefix(hostsHeroRowLimit)) : recent
        let ring = hosts.isEmpty ? nil : HelmModuleCard.HeroRing(
            fraction: Double(liveHosts.count) / Double(hosts.count), label: "\(liveHosts.count)/\(hosts.count)",
            caption: "hosts online", spoken: "\(liveHosts.count) of \(hosts.count) saved hosts online", state: .ok)
        return HostsHero(headline: headline, body: body, ring: ring,
                         sectionTitle: recent.isEmpty ? "Saved hosts" : "Recent",
                         hostIDs: shown.map(\.id), isStale: false)
    }

    /// The Hosts card as the full hero with its rows: the session verdict,
    /// the ring of hosts online, and the three hosts connected last, each
    /// with Switch (a live session) or Connect.
    func fillHostsHero(_ content: inout HelmModuleCard.Content, width: CGFloat) {
        let hosts = sources.hostStore.hosts
        let connected = connectedHostIDs?() ?? []
        var live: [UUID: Date] = [:]
        for id in connected { live[id] = hostSession?(id)?.startedAt ?? Date() }
        let hero = Self.hostsHero(hosts: hosts, readable: sources.hostStore.loadStatus == .clean, live: live)
        content.subtitle = "\(hosts.count) saved"
        if !connected.isEmpty { content.chip = .ok("\(connected.count) live") }
        let byID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows: [HelmModuleCard.HeroListRow] = hero.hostIDs.compactMap { id in
            guard let host = byID[id] else { return nil }
            if connected.contains(id) {
                return HelmModuleCard.HeroListRow(
                    symbol: host.iconSymbol, title: host.label, subtitle: host.subtitle, subtitleIsCode: true,
                    actionTitle: "Switch", actionTooltip: "Switch to \(host.label)'s session",
                    handler: { [weak self] in self?.onSwitchToHostSession?(id) })
            }
            return HelmModuleCard.HeroListRow(
                symbol: host.iconSymbol, title: host.label, subtitle: host.subtitle, subtitleIsCode: true,
                actionTitle: nil, actionSymbol: "bolt.fill", actionTooltip: "Connect to \(host.label)",
                handler: { [weak self] in self?.onConnectHost?(id) })
        }
        content.body = .heroList(HelmModuleCard.HeroList(
            headline: hero.headline, body: hero.body, ring: hero.ring, sectionTitle: hero.sectionTitle,
            rows: rows, emptyText: hosts.isEmpty ? "Nothing saved yet" : "Nothing connected yet",
            layout: HelmModuleCard.HeroLayout(cardWidth: width)))
        content.hero = heroTone(for: .hosts, dimmed: hero.isStale)
        content.headerMenu = styleMenu(for: .hosts)
    }
}
