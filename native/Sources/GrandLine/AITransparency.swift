// Grand Line - native macOS app.
//
// X11 (review UX): one definition of "where does this text go".
//
// The daily review card once carried the app's only trust line ("Generated
// locally · no data left this Mac"), while the Reading List's AI summary and
// the Straw Hat crew both sent the captain's own material to Claude and said
// nothing. The claims for the surfaces that send now live here, in one place,
// so they read as one voice and cannot drift into saying different things
// about the same runner - every AI turn in this app is a `ClaudeOneShot` run,
// whatever surface started it.
//
// (The local claim went with the daily review card, which was its only
// surface, in `fm/grandline-remove-today-calendar-1792553365`.)
//
// **These are claims about behaviour, so they are checked against it.**
// `AITransparencySelfTest` asserts that each surface that sends states the
// claim through this file. A sentence nobody verifies is worse than no
// sentence: it is a promise.

import Foundation

enum AITransparency {

    /// For a surface that sends the captain's own material to Claude.
    ///
    /// `what` names the material rather than the feature, because that is
    /// the part the captain cannot see: "the page's text", "what you type and
    /// the stores the crew can read". Naming the feature ("the summary") says
    /// nothing they did not already know.
    static func sentToClaude(_ what: String) -> String {
        "Written by Claude \u{00B7} \(what) left this Mac"
    }

    /// The same claim in the future tense, for a control that has not run
    /// yet - a button's tooltip, where the captain can still decline.
    ///
    /// Separate from `sentToClaude` rather than one string with a tense
    /// parameter: "left this Mac" on a button that has sent nothing would be
    /// false, and this is the one file in the app where a sloppy tense is a
    /// wrong statement about data rather than a style note.
    static func willSendToClaude(_ what: String) -> String {
        "Sends \(what) to Claude"
    }
}
