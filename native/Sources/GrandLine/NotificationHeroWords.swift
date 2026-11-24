// Grand Line - native macOS app.
//
// What the notifications panel's hero head says (N-1, Helm 10.4.0, from the
// notifications hero board in `data/grandline-notifications-hero-design-scout/`).
//
// Every page hero in the app leads with what is true now rather than with a
// label: "Two services need you", not "Health". The panel's head does the
// same. Its kicker keeps the panel's old title and the date, the headline is
// the verdict, and the second line says how much of it is new.
//
// Pure, so `GrandLineNotificationCenterSelfTest` asserts every sentence in CI's
// blocking lane rather than only through a window. The panel passes in counts
// it already has (`NotificationBridgeSections`, the store's read state and its
// Snoozed list), so the words can never disagree with the cards under them.
//
// **The bell's badge is not these words.** It still counts every item waiting,
// read or not (`GrandLineNotificationCenter.badgeCount`). "Unread" lives here
// and in each card's dot.

import Foundation

struct NotificationHeroWords: Equatable {
    /// "Waiting for you · Tue 24 Nov". Drawn in capitals, read in its own case.
    let kicker: String
    /// The verdict: "4 things need you", "1 update for you", "All caught up".
    let title: String
    /// "4 unread · 3 when you have a minute", "All read".
    let subtitle: String
    /// The ring's centre: the unread count. `nil` when there is no ring.
    let ringText: String?
    /// The ring's arc: the unread share of what is waiting.
    let ringFraction: Double
    /// The ring as one sentence for VoiceOver ("4 unread of 7 waiting").
    let ringSpoken: String

    static let panelTitle = "Waiting for you"

    /// - Parameters:
    ///   - segment: which list is showing. The ring belongs to the inbox.
    ///   - needs: action-needed items in the inbox.
    ///   - informational: informational items in the inbox.
    ///   - unread: inbox items whose dot is lit.
    ///   - snoozed: items in the Snoozed list.
    ///   - dateText: the header date, already formatted
    ///     (`NotificationBridgeTimeText.headerDate`).
    static func make(segment: NotificationBridgeSegment, needs: Int, informational: Int,
                     unread: Int, snoozed: Int, dateText: String) -> NotificationHeroWords {
        let kicker = dateText.isEmpty ? panelTitle : "\(panelTitle) \u{00B7} \(dateText)"
        let waiting = max(0, needs) + max(0, informational)
        let unread = min(max(0, unread), waiting)
        switch segment {
        case .snoozed:
            return NotificationHeroWords(
                kicker: kicker,
                title: snoozed > 0 ? "\(snoozed) snoozed" : "Nothing snoozed",
                subtitle: snoozed > 0 ? "Each one comes back on its own."
                                      : "A snoozed notification comes back here on its own.",
                ringText: nil, ringFraction: 0, ringSpoken: "")
        case .inbox:
            guard waiting > 0 else {
                return NotificationHeroWords(kicker: kicker, title: "All caught up",
                                             subtitle: "Nothing needs you right now.",
                                             ringText: nil, ringFraction: 0, ringSpoken: "")
            }
            let title: String
            if needs > 0 {
                title = needs == 1 ? "1 thing needs you" : "\(needs) things need you"
            } else {
                title = informational == 1 ? "1 update for you" : "\(informational) updates for you"
            }
            var parts = [unread > 0 ? "\(unread) unread" : "All read"]
            if needs > 0 && informational > 0 { parts.append("\(informational) when you have a minute") }
            return NotificationHeroWords(
                kicker: kicker, title: title, subtitle: parts.joined(separator: " \u{00B7} "),
                ringText: "\(unread)", ringFraction: Double(unread) / Double(waiting),
                ringSpoken: "\(unread) unread of \(waiting) waiting")
        }
    }
}
