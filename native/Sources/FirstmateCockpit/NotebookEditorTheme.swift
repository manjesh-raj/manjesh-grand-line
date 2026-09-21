// Manjesh Grand Line - native macOS app.
//
// The Notebook editor's syntax palette: `CodePreviewTheme`'s, with the two
// slots a *markdown* page actually uses re-pointed so a `[[wiki-link]]` reads
// as a link in the source pane and not as a string literal.
//
// ## Why this file exists at all
//
// The Monaco bundle is vendored and committed (`native/Vendor/Monaco/web`),
// and regenerating it needs node, npm and network access - "the one and only
// time either is needed", per `Scripts/build-monaco-web.sh`'s own header. So
// this feature does **not** add a `notebook-markdown` Monarch language, and
// does not touch the bundle in any way. It uses the bundle's existing
// `markdown` tokenizer and colours its output.
//
// That is a real constraint with a real consequence, stated rather than
// hidden: there is no *dedicated* wiki-link token, so the highlighting below
// is as specific as Monaco's own markdown tokenizer lets it be. Monaco's
// markdown Monarch grammar emits `string.link` for the bracketed part of a
// link - which is what `[[Target]]` is, to that grammar - and nothing else in
// a markdown document takes the `string` family. So re-pointing `string` is
// exactly "colour the links", with no collateral: markdown has no string
// literals of its own, and a fenced code block inside a markdown document is
// tokenized by the *embedded* language, not by this one.
//
// **Measured, not assumed.** `NotebookViewSelfTest.checkWikiLinkIsHighlighted`
// reads Monaco's own tokenizer output back through the bridge's `tokensAt`
// call for a line containing a `[[wiki-link]]`, asserts the token family it
// actually produces, and asserts the colour that family resolves to here is
// both distinct from body ink and above the contrast floor on the editor's
// own ground. If a future bundle bump changes the grammar, that case fails by
// name rather than the highlighting quietly going away.
//
// Everything else - the background, the ink, the selection, the scrollbars,
// the correction path that keeps each colour above 4.5:1 on the editor's own
// ground - is `CodePreviewTheme`'s, unchanged and deliberately not copied.

import AppKit

enum NotebookEditorTheme {

    /// The palette the notebook's editor page is handed.
    ///
    /// Two overrides on top of `CodePreviewTheme.palette(for:)`:
    ///
    ///   - **`string` -> the theme's link/accent colour.** In a markdown
    ///     document this is the link family, `[[wiki-links]]` included. In
    ///     every Daylight palette `accentHex` *is* `linkBlue`, so this is
    ///     literally the colour the reviewed mockup draws a link in; in the
    ///     twelve other palettes it is that theme's own accent, which is the
    ///     app's one "this is interactive" hue.
    ///   - **`keyword` -> the theme's ink at full strength.** Monaco's
    ///     markdown grammar tokenizes a `#` heading as `keyword`, and
    ///     `CodePreviewTheme` points `keyword` at magenta because in *code* a
    ///     keyword is a keyword. A magenta `## Pre-flight` in a prose document
    ///     reads as an error, so a heading takes the page's strongest ink -
    ///     which, with Monaco's own bold rendering of a markdown heading, is
    ///     what makes it read as a heading.
    ///
    /// Both go through `CodePreviewTheme.legibleHex(_:on:)`, which is the
    /// correction that measures the **quantised** 8-bit colour rather than the
    /// `NSColor` nobody renders - that file's own header records the fourteen
    /// token/theme pairs that fell below the floor without it.
    static func palette(for theme: HelmTheme) -> [String: String] {
        var palette = CodePreviewTheme.palette(for: theme)
        let ground = HelmTheme.nsColor(theme.backgroundHex)
        palette[CodePreviewTheme.Key.string.rawValue] =
            CodePreviewTheme.legibleHex(HelmTheme.nsColor(theme.accentHex), on: ground)
        palette[CodePreviewTheme.Key.keyword.rawValue] =
            CodePreviewTheme.legibleHex(HelmTheme.nsColor(theme.foregroundHex), on: ground)
        return palette
    }

    /// The colour a link - and therefore a `[[wiki-link]]` - is painted in the
    /// source pane, as the shipped `#rrggbb` string. Named so the self-test
    /// asserts the value that actually crosses the bridge rather than
    /// re-deriving it from the function under test.
    static func linkHex(for theme: HelmTheme) -> String {
        palette(for: theme)[CodePreviewTheme.Key.string.rawValue] ?? "#000000"
    }

    /// The body ink the link colour has to be distinguishable from. Same
    /// reason: a check that compared the link colour against itself would
    /// pass vacuously.
    static func inkHex(for theme: HelmTheme) -> String {
        palette(for: theme)[CodePreviewTheme.Key.ink.rawValue] ?? "#000000"
    }
}
