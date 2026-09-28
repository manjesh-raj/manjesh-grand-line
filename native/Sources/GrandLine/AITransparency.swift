// Grand Line - native macOS app.
//
// X11 (review UX): one definition of "where does this text go".
//
// The daily review card already carried a trust line - "Generated locally ·
// no data left this Mac" - and the review's point was that it was the *only*
// one. The Reading List's AI summary and the Straw Hat crew both send the
// captain's own material to Claude and said nothing, so the app's single
// visible claim about data was made by the one surface that sends none.
//
// The fix is not five sentences written five times. Both claims live here,
// in one place, so they read as one voice and cannot drift into saying
// different things about the same runner - every AI turn in this app is a
// `ClaudeOneShot` run, whatever surface started it.
//
// **These are claims about behaviour, so they are checked against it.**
// `AITransparencySelfTest` asserts that every surface stating `.local`
// reaches no AI runner, and that every surface reaching `ClaudeOneShot`
// states `.sentToClaude`. A sentence nobody verifies is worse than no
// sentence: it is a promise.

import Foundation

enum AITransparency {

    /// For a surface that computes its answer on this machine.
    ///
    /// The daily review's own wording, kept byte for byte - it is the line
    /// the captain has been reading and the review singled out as "a lovely
    /// trust line".
    static let local = "Generated locally \u{00B7} no data left this Mac"

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
