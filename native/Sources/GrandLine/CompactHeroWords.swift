// Grand Line - native macOS app.
//
// What the menu-bar popover's hero head says (MB-1 Hero head popover, Helm
// 10.4.0, from the hero restyle board in
// `data/grandline-hero-restyle-designs-scout/`).
//
// The popover used to open on a plain "Grand Line · compact mode" title over
// its tab strip. MB-1 leads with what is true on the tab that is showing, as
// every page hero does: "2 of 6 done today", "3 notes on the board", "3 codes
// ready", "Ask the crew". The kicker names the tab, and the second line says
// what to do next or what else is true.
//
// Pure, so `CompactModeSelfTest` asserts every sentence in CI's blocking lane.
// The popover passes in counts it already reads for its panes (the Tasks
// Bridge digest, the status menu's uncapped overdue count, the Sticky Board's
// note count and the vault's codes), so the head can never disagree with the
// rows under it.
//
// **Unknown is never zero (GL-14).** Each tab's count is optional. `nil` means
// the popover was never handed a way to read it, and the head says the count
// is not loaded rather than "Nothing due today" or "The board is empty".

import Foundation

struct CompactHeroWords: Equatable {

    /// The ring on the Today head: done today over what was on the plate.
    struct Ring: Equatable {
        let fraction: Double
        /// "2/6", the ring's centre.
        let text: String
        /// "2 of 6 done today", what VoiceOver reads for the ring.
        let spoken: String
    }

    /// The tile's glyph: the app's sailboat, or a padlock while the app is
    /// locked.
    let symbol: String
    /// "Today · Tue 24 Nov". Drawn in capitals, read in its own case.
    let kicker: String
    /// The verdict.
    let headline: String
    /// The quiet line under it.
    let detail: String
    /// Today's progress ring, or nil on every other tab and on a day with no
    /// progress to show.
    let ring: Ring?

    static let appSymbol = "sailboat"
    static let lockedSymbol = "lock.fill"

    // MARK: Today

    /// - Parameters:
    ///   - digest: the Today pane's own Bridge digest, or nil when the popover
    ///     has no way to read the tasks.
    ///   - overdue: the uncapped overdue count (`CompactTodayDigest.overdueCount`,
    ///     the status item's badge), or nil when it is not known.
    static func today(_ digest: TasksBridgeDigest?, overdue: Int?) -> CompactHeroWords {
        let date = digest?.dateText ?? ""
        let kicker = date.isEmpty ? CompactModeTab.today.title : "\(CompactModeTab.today.title) \u{00B7} \(date)"
        guard let digest else {
            return CompactHeroWords(symbol: appSymbol, kicker: kicker,
                                    headline: "Tasks aren\u{2019}t loaded yet",
                                    detail: "The count appears once they are read", ring: nil)
        }
        // GL-14, as the Bridge digest itself draws it: no progress is "nothing
        // was due and nothing was finished today", never "0 of 0".
        guard let progress = digest.progress else {
            return CompactHeroWords(
                symbol: appSymbol, kicker: kicker, headline: "Nothing due today",
                detail: digest.backlog.isEmpty ? "Capture a task below to start the day"
                                               : "Claim one from the backlog to start",
                ring: nil)
        }
        var parts: [String] = []
        if digest.streakDays > 0 { parts.append("\(digest.streakDays)-day streak") }
        if let overdue, overdue > 0 { parts.append("\(overdue) overdue") }
        let detail: String
        if !parts.isEmpty {
            detail = parts.joined(separator: " \u{00B7} ")
        } else if overdue == 0 {
            detail = "Nothing overdue"
        } else {
            detail = "No streak yet"
        }
        return CompactHeroWords(
            symbol: appSymbol, kicker: kicker, headline: progress.spokenText, detail: detail,
            ring: Ring(fraction: progress.fraction, text: progress.shortText, spoken: progress.spokenText))
    }

    // MARK: Notes

    /// - Parameters:
    ///   - onBoard: every note on the Sticky Board that is not archived
    ///     (`CompactModeDigest.noteCount`), or nil when it is not known.
    ///   - shown: how many rows the pane draws, which stops at
    ///     `CompactModeDigest.maxRows`.
    static func notes(onBoard: Int?, shown: Int) -> CompactHeroWords {
        let kicker = CompactModeTab.notes.title
        guard let onBoard else {
            return CompactHeroWords(symbol: appSymbol, kicker: kicker,
                                    headline: "Notes aren\u{2019}t loaded yet",
                                    detail: "The count appears once the board is read", ring: nil)
        }
        guard onBoard > 0 else {
            return CompactHeroWords(symbol: appSymbol, kicker: kicker, headline: "The board is empty",
                                    detail: "Capture a note below", ring: nil)
        }
        let detail: String
        if onBoard > shown {
            detail = "The newest \(shown) are below"
        } else {
            detail = onBoard == 1 ? "Click it to open it on the board" : "Click one to open it on the board"
        }
        return CompactHeroWords(symbol: appSymbol, kicker: kicker,
                                headline: "\(onBoard) \(onBoard == 1 ? "note" : "notes") on the board",
                                detail: detail, ring: nil)
    }

    // MARK: Vault

    /// - Parameters:
    ///   - codes: the 2FA codes the vault pane lists, or nil when not known.
    ///   - unlocked: whether the vault itself is unlocked. Locked and "none
    ///     stored" read differently, as the pane's own words already do.
    static func vault(codes: Int?, unlocked: Bool) -> CompactHeroWords {
        let kicker = CompactModeTab.vault.title
        guard unlocked else {
            return CompactHeroWords(symbol: appSymbol, kicker: kicker, headline: "Poneglyph is locked",
                                    detail: "Unlock it in the app to copy a code", ring: nil)
        }
        guard let codes else {
            return CompactHeroWords(symbol: appSymbol, kicker: kicker,
                                    headline: "Codes aren\u{2019}t loaded yet",
                                    detail: "The count appears once the vault is read", ring: nil)
        }
        guard codes > 0 else {
            return CompactHeroWords(symbol: appSymbol, kicker: kicker, headline: "No 2FA codes yet",
                                    detail: "Add a 2FA secret to a credential", ring: nil)
        }
        return CompactHeroWords(symbol: appSymbol, kicker: kicker,
                                headline: "\(codes) \(codes == 1 ? "code" : "codes") ready",
                                detail: codes == 1 ? "Copy it from its row" : "Copy one from its row",
                                ring: nil)
    }

    // MARK: Crew and the lock

    static let crew = CompactHeroWords(symbol: appSymbol, kicker: CompactModeTab.crew.title,
                                       headline: "Ask the crew",
                                       detail: "It knows your tasks, docs and health", ring: nil)

    /// The lock pane's own words, moved up into the head. The pane keeps the
    /// field, the error line and Unlock.
    static let locked = CompactHeroWords(symbol: lockedSymbol, kicker: "Grand Line",
                                         headline: "Grand Line is locked",
                                         detail: "Enter your password to unlock.", ring: nil)

    /// The words VoiceOver reads for the head, in drawn order.
    var spoken: String { [kicker, headline, detail].filter { !$0.isEmpty }.joined(separator: ", ") }
}
