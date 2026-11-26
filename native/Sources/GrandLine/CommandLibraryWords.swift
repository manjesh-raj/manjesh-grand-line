// Grand Line - native macOS app.
//
// UX-10 of full review 4: the Commands page's words, pure, so a suite can
// assert them without a window. `CommandLibraryViews.swift` draws them.
//
//   - The categories are chips above the list: All, the first few, and a
//     "+N" chip that shows the rest.
//   - Favourites and recently used lead the list, each recent one saying
//     when it was sent.
//   - The detail pane says the risk level in words, and where and when the
//     command was last sent.

import Foundation

enum CommandLibraryWords {

    /// How many categories show as chips before the "+N" chip.
    static let chipsShown = 4

    struct Chip: Equatable {
        let id: String
        let title: String
    }

    /// All, then the first `chipsShown` categories in the library's own
    /// order, then "+N" for the rest - or every category, and "Fewer", once
    /// expanded. A chosen category past the first few is always shown.
    static func chips(categories: [(id: String, name: String, count: Int)], total: Int,
                      selected: String?, expanded: Bool) -> [Chip] {
        var chips = [Chip(id: CommandLibraryPageView.allCategoryID, title: "All")]
        let listed = categories.filter { $0.count > 0 }
        var shown = expanded ? listed : Array(listed.prefix(chipsShown))
        if !expanded, let selected, let chosen = listed.first(where: { $0.id == selected }),
           !shown.contains(where: { $0.id == selected }) {
            shown.append(chosen)
        }
        chips += shown.map { Chip(id: $0.id, title: "\($0.name) \($0.count)") }
        let hidden = listed.count - shown.count
        if expanded, listed.count > chipsShown {
            chips.append(Chip(id: moreChipID, title: "Fewer"))
        } else if hidden > 0 {
            chips.append(Chip(id: moreChipID, title: "+\(hidden)"))
        }
        return chips
    }

    static let moreChipID = "__more__"

    /// The search field's placeholder, which carries the count the header
    /// line used to.
    static func searchPlaceholder(count: Int) -> String {
        count == 0 ? "Search commands\u{2026}" : "Search \(count) command\(count == 1 ? "" : "s")\u{2026}"
    }

    /// The risk level as a sentence fragment rather than a slug.
    static func riskWords(_ level: CommandRiskLevel) -> String {
        switch level {
        case .readOnly: return "Read-only \u{00B7} changes nothing"
        case .potentiallyDisruptive: return "Changes things \u{00B7} check first"
        case .destructive: return "Destructive \u{00B7} cannot be undone"
        }
    }

    /// "To DEV Bastion", "To DEV Bastion and 2 more hosts".
    static func sentTo(hosts: [String]) -> String {
        guard let first = hosts.first else { return "To saved hosts" }
        switch hosts.count {
        case 1: return "To \(first)"
        case 2: return "To \(first) and 1 more host"
        default: return "To \(first) and \(hosts.count - 1) more hosts"
        }
    }

    /// The Last sent card's line: where, then when. GL-14: an unreadable
    /// usage file is said, never read as "never sent".
    static func lastSent(_ entry: CommandLibraryUsageEntry?, unreadable: Bool, now: Date,
                         calendar: Calendar = .current) -> String {
        guard let entry else {
            return unreadable ? "Couldn\u{2019}t read when it was last sent." : "Not sent from here yet."
        }
        return "\(entry.via ?? "Sent") \u{00B7} \(when(entry.usedAt, now: now, calendar: calendar))"
    }

    /// "today 9:12", "yesterday 14:05", "Mon 9:12", "24 Nov 9:12".
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let clock = clockFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(clock)"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if (2...6).contains(days) { return "\(weekdayFormatter.string(from: date)) \(clock)" }
        return "\(ShiftDateFormatting.monthDay(date)) \(clock)"
    }

    /// A recent row's second line: "sent 2 hours ago".
    static func sentAgo(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "sent just now" }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "sent \(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            let hours = Int(seconds / 3600)
            return "sent \(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days == 1 { return "sent yesterday" }
        if days < 7 { return "sent \(days) days ago" }
        return "sent \(ShiftDateFormatting.monthDay(date))"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()
}
