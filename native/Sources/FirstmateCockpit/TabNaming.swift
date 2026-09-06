// Manjesh Grand Line - native macOS app.
//
// The numbered-disambiguation convention Console's and Tools' tab strips both
// use: the bare kind name for the first currently-open tab of that kind, and
// "<name> N" for each concurrently-open one after it - "Shell", "Shell 2",
// "Shell 3"; "Diff", "Diff 2".
//
// **Why this is one function rather than two.** It was two, and they had the
// same bug. Console ported the convention from Tools by copying the
// expression, so both read:
//
//     let existing = tabs.filter { ... }.count
//     return existing == 0 ? bare : "\(bare) \(existing + 1)"
//
// which is only correct while the *highest*-numbered tab is the one that gets
// closed. Close a middle one - "Shell 2" out of Shell / Shell 2 / Shell 3 -
// and the count drops to 2, so the next tab is named "Shell 3" and the strip
// shows **two tabs called "Shell 3"**. Both call sites' doc comments promised
// the opposite in as many words ("closing 'Shell 2' and opening a new shell
// reuses that name rather than climbing to 'Shell 3'"), and so does AGENTS.md.
//
// Found by `ConsoleTabLifecycleSelfTest`, the general tab-lifecycle suite the
// full-app audit's §7 asked for - the first thing to assert this convention
// beyond the simple open-three-in-a-row case.
//
// The fix is to answer the question the convention actually poses - *which
// number is free* - instead of inferring it from a count.
import Foundation

enum TabNaming {

    /// The name for a new tab of a kind, given the names of the tabs of that
    /// same kind currently open.
    ///
    /// Returns `bare` when no tab of the kind is open, otherwise `bare` plus
    /// the lowest integer from 2 upward that is not already taken. Bounded by
    /// `taken.count + 2` iterations: with N names taken, one of 2...N+2 is
    /// necessarily free, so the loop always terminates.
    ///
    /// `taken` is passed as names rather than parsed numbers on purpose - a
    /// tab the captain renamed by hand ("deploys") no longer participates in
    /// the numbering at all, which is what makes a rename genuinely just a
    /// label change and keeps this from ever handing out a name already on
    /// screen.
    static func nextName(bare: String, taken: [String]) -> String {
        let takenSet = Set(taken)
        if !takenSet.contains(bare) { return bare }
        for n in 2...(taken.count + 2) {
            let candidate = "\(bare) \(n)"
            if !takenSet.contains(candidate) { return candidate }
        }
        // Unreachable given the bound above; a distinct name beats a crash.
        return "\(bare) \(taken.count + 2)"
    }
}
