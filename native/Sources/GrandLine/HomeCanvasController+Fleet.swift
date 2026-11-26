// Grand Line - native macOS app.
//
// P-05 of the 2026-11-25 full review (GL-36), part of `HomeCanvasController`'s
// decomposition by card family: the Fleet card and its full hero.
//
// Split out verbatim along the controller's own `// MARK:` seams. No statement
// changed in the move; `private` was dropped so the family can reach its own
// members across files, the same as `ConsoleController`'s split. See
// `HomeCanvasController.swift`'s header.

import AppKit

extension HomeCanvasController {

    /// The full hero's words for a fleet reading. `static` for the suite.
    struct FleetHero: Equatable {
        let subtitle: String
        let chip: HelmModuleChip?
        let headline: String
        let body: String
        let ring: HelmModuleCard.HeroRing?
        let items: [HelmKPIStrip.Item]
        /// GL-14: the card has no real fleet to show, so its colour dims.
        /// Only a fleet that was never read sets it - a stale watcher's
        /// counts are real and stay in the captain's colour.
        let isStale: Bool
    }

    /// Five states, worst first: a crewmate blocked (red), one waiting on a
    /// decision (amber), a watcher that has stopped reporting (amber pill),
    /// crew working, and all clear. Two of them are new on this card: today
    /// `blocked` and `needs_decision` both read amber, and the watcher's
    /// health was not read at all.
    ///
    /// The ring is the day's progress: what is done today out of everything
    /// the snapshot knows about (done, working and queued), so the arc fills
    /// as the queue drains. The centre is the done count.
    static func fleetHero(snapshot: FleetSnapshot?) -> FleetHero {
        let captions = ["Working", "Done today", "Queued"]
        let unread = captions.map { HelmKPIStrip.Item(.unread, caption: $0) }
        guard let snapshot else {
            return FleetHero(subtitle: "reading", chip: nil, headline: "Reading the fleet\u{2026}",
                             body: "Counting the crew's lanes.", ring: nil, items: unread, isStale: false)
        }
        // GL-14, as the plain card already had it: no firstmate home is not
        // a fleet of zeroes.
        guard snapshot.homeOk else {
            return FleetHero(subtitle: "not read", chip: .warn(HelmReading<String>.unknownCaption),
                             headline: "Fleet not read",
                             body: "Point Grand Line at your firstmate home in \(PlaceName.of(.bootstrap)).",
                             ring: nil, items: unread, isStale: true)
        }

        let working = snapshot.tasks.filter { $0.status == "working" }
        let blocked = snapshot.tasks.filter { $0.status == "blocked" }
        let deciding = snapshot.tasks.filter { $0.status == "needs_decision" }
        let items: [HelmKPIStrip.Item] = [
            .count(working.count, caption: "Working"),
            .count(snapshot.doneCount, caption: "Done today"),
            .count(snapshot.queuedCount, caption: "Queued"),
        ]
        let open = working.count + snapshot.queuedCount
        let total = snapshot.doneCount + open
        let state: HelmModuleRowState = !blocked.isEmpty ? .bad : (!deciding.isEmpty ? .warn : .ok)
        let ring = HelmModuleCard.HeroRing(
            fraction: total > 0 ? Double(snapshot.doneCount) / Double(total) : 0,
            label: "\(snapshot.doneCount)", caption: "done today \u{00B7} \(open) open",
            spoken: "\(snapshot.doneCount) done today, \(open) still open", state: state)
        let watcher: String
        switch snapshot.watcher.status {
        case "healthy": watcher = "watcher ok"
        case "stale": watcher = "watcher stale"
        default: watcher = "watcher off"
        }
        func names(_ tasks: [FleetTask]) -> String { tasks.prefix(2).map(\.id).joined(separator: ", ") }
        func crew(_ count: Int) -> String { count == 1 ? "crewmate" : "crewmates" }

        if !blocked.isEmpty {
            var body = "\(names(blocked)) \(blocked.count == 1 ? "is" : "are") blocked and \(blocked.count == 1 ? "needs" : "need") help."
            if !deciding.isEmpty { body += " \(deciding.count) more \(deciding.count == 1 ? "is" : "are") waiting on you." }
            return FleetHero(subtitle: watcher, chip: .bad("\(blocked.count) blocked"),
                             headline: "\(blocked.count) \(crew(blocked.count)) blocked", body: body,
                             ring: ring, items: items, isStale: false)
        }
        if !deciding.isEmpty {
            var body = "\(names(deciding)) \(deciding.count == 1 ? "wants" : "want") a decision."
            if !working.isEmpty { body += " \(working.count) other crew \(working.count == 1 ? "is" : "are") working." }
            return FleetHero(subtitle: watcher, chip: .warn("\(deciding.count) need\(deciding.count == 1 ? "s" : "") you"),
                             headline: "\(deciding.count) waiting on you", body: body,
                             ring: ring, items: items, isStale: false)
        }
        // A stale watcher keeps the card's colour (`fm/grandline-widget-polish`).
        // The counts are the snapshot's own, not unknowns, and the pill, the
        // headline and the body already say they may be behind. Dimmed, the
        // card turned grey for as long as the watcher stayed stopped, which
        // read as Fleet ignoring the theme beside Claude and Hosts.
        if snapshot.watcher.status == "stale" {
            return FleetHero(subtitle: watcher, chip: .warn("Watcher stale"), headline: "Counts may be behind",
                             body: "The watcher has stopped reporting, so these numbers may be out of date.",
                             ring: ring, items: items, isStale: false)
        }
        if !working.isEmpty {
            return FleetHero(subtitle: watcher, chip: .ok("All clear"),
                             headline: "\(working.count) crew working",
                             body: "\(working.count == 1 ? "One lane is" : "\(working.count) lanes are") running. Nothing is waiting on you.",
                             ring: ring, items: items, isStale: false)
        }
        return FleetHero(subtitle: watcher, chip: .ok("All clear"), headline: "All clear",
                         body: "All hands idle. Nothing is running and nothing is waiting on you.",
                         ring: ring, items: items, isStale: false)
    }

    /// The Fleet card as the full hero.
    func fillFleetHero(_ content: inout HelmModuleCard.Content, width: CGFloat) {
        let hero = Self.fleetHero(snapshot: fleetSnapshot)
        content.subtitle = hero.subtitle
        content.chip = hero.chip
        if fleetSnapshot == nil { content.toolTip = "Reading the fleet's state\u{2026}" }
        content.body = .heroSummary(HelmModuleCard.HeroSummary(
            headline: hero.headline, body: hero.body, ring: hero.ring, items: hero.items,
            layout: HelmModuleCard.HeroLayout(cardWidth: width)))
        content.hero = heroTone(for: .fleet, dimmed: hero.isStale)
        content.headerMenu = styleMenu(for: .fleet)
    }
}
