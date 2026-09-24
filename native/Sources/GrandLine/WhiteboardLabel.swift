// Grand Line - native macOS app.
//
// The one place a caption is made safe to hand Excalidraw as a *bound* label.
//
// ## The bug this exists for, measured rather than reasoned about
//
// A bound label - the `"label": {"text": …}` a skeleton puts *inside* a shape -
// containing `U+FE0F` (VARIATION SELECTOR-16, the code point that asks for a
// glyph's emoji presentation) is **silently truncated** when the vendored
// Excalidraw 0.18.1 renders it. A real captain screenshot showed a blue box
// captioned `🖥️ Server` rendering as `🖥️ Se`, which is exactly what the
// component palette's own labels looked like.
//
// The reproduction is in `WhiteboardLabelSelfTest` and the evidence is worth
// stating, because every plausible-sounding diagnosis is wrong:
//
//   * **Not a sizing problem.** The same string truncates at the same point in
//     a 120pt box, a 260pt box and a 900pt box. Widening the container changes
//     nothing.
//   * **Not a wrapping problem.** A 240pt-tall container shows one truncated
//     line, not several. The characters are genuinely gone, not pushed onto a
//     line nobody can see.
//   * **Not an emoji problem.** `⚡ Lambda` and `🪣 S3` - emoji carrying no
//     variation selector - render in full, while `A\u{FE0F}B Server`, which
//     has no emoji in it at all, truncates to `AB S`. The variation selector
//     alone is the trigger.
//   * **Not a length problem.** A 30-character ASCII label renders in full.
//   * **Not text rendering in general.** The identical string as a *standalone*
//     `text` element renders in full. It is the bound-label path only.
//
// The mechanism is inside the vendored bundle's own text segmentation: its
// per-character width cache keys on `charCodeAt(0)` (the first UTF-16 code
// unit, so every Supplementary-Plane emoji sharing a high surrogate collides)
// and its line-break pass mis-segments a sequence carrying a variation
// selector, dropping the tail. Patching minified upstream code is not something
// this repo does, and it does not need to: the app controls every string that
// reaches a bound label, so the fix is to stop handing the library the input it
// gets wrong.
//
// ## Why stripping is the right repair, and what it costs
//
// `U+FE0F` is a *presentation hint*, never content: removing it changes which
// glyph variant a platform picks, never which characters the reader sees. So
// the trade is "a base glyph that may render monochrome" against "a caption
// missing half its words", and only one of those is a caption. Confirmed in a
// real render: `🖥 Server` (no selector) still draws the colour monitor on
// macOS and keeps every letter.
//
// This is defence, not the primary fix for the component palette - since
// `fm/grand-line-whiteboard-component-icons-overhaul` a component's caption is
// plain text beside a real icon image and carries no emoji at all. What this
// still covers is every label the app does *not* author: a captain typing
// `db(🚀 Prod)` in the DSL, and anything the AI composer writes.

import Foundation

enum WhiteboardLabel {

    /// VARIATION SELECTOR-16, the emoji-presentation request.
    static let emojiPresentationSelector: Unicode.Scalar = "\u{FE0F}"

    /// VARIATION SELECTOR-15, its text-presentation sibling. Harmless today,
    /// dropped with it because the two are one concept and a caption has no
    /// business carrying either.
    static let textPresentationSelector: Unicode.Scalar = "\u{FE0E}"

    /// **Scalars, never `Character`s, and this is not a style preference.**
    /// Swift's `Character` is a grapheme cluster, so `U+FE0F` is folded into
    /// the emoji it modifies: `"\u{1F5A5}\u{FE0F} Server".contains("\u{FE0F}")`
    /// is **false**, and a `Character`-based filter leaves the selector exactly
    /// where it was while reporting success. Caught by this file's own
    /// self-test rather than by reading it - the same trap this codebase
    /// already records for CRLF, which is likewise one `Character`.
    private static func carries(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            $0 == emojiPresentationSelector || $0 == textPresentationSelector
        }
    }

    /// A caption Excalidraw will render in full.
    ///
    /// Applied at the *point a label is built*, never at a call site: a bound
    /// label is created in four places (this app's own shape captions, its two
    /// arrow captions, and whatever a model wrote), and a sanitiser a caller
    /// has to remember is one a caller forgets.
    static func renderable(_ text: String) -> String {
        guard carries(text) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars
        where scalar != emojiPresentationSelector && scalar != textPresentationSelector {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// True for a string the vendored bundle would truncate. The self-test's
    /// own predicate, kept here so the rule has one definition.
    static func wouldTruncate(_ text: String) -> Bool { carries(text) }
}
