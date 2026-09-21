// Manjesh Grand Line - native macOS app.
//
// The Notebook's markdown -> render-model parser, for the live preview pane.
//
// ## Why this is not `SRELeadMarkdown`, and not `AttributedString(markdown:)`
//
// Both already exist in this app and both were tried first.
//
// `SRELeadMarkdown` parses a *chat reply*: paragraphs, bullets, fenced code,
// bold, inline code, and the two labelled callouts its persona is told to
// write. It has no headings, no links, no task items and no ordered lists,
// because an SRE Lead answer has none of those. A notebook page is the
// opposite shape - the mockup's own F1 page is a `# heading`, a `## heading`,
// a task list with two items ticked, and three links. Widening the chat parser
// to cover a document would give the chat view four block cases it must render
// and never receives, which is how one shared abstraction becomes two features
// that can only be changed together (the call `CodePreviewWebView`'s header
// makes for the same reason).
//
// Foundation's own `AttributedString(markdown:)` - which `SRELeadMarkdown`
// delegates its block structure to - was the obvious base and does not work
// here for two specific reasons, both measured rather than assumed:
//
//   1. **It eats `[[wiki-links]]`.** `[[RaaS cutover]]` is, to CommonMark, a
//      link *reference* nested in brackets; the parser rewrites the text and
//      the offsets, so the one syntax this whole feature is built around
//      cannot be recovered afterwards.
//   2. **`presentationIntent` carries no heading level and no task state.**
//      `.header(level:)` exists but the GFM task-list extension does not, so
//      `- [x] Freeze deploys` arrives as a list item whose text begins with
//      "[x] ", i.e. exactly the thing the preview must not show.
//
// So this is a hand-written line-based block scanner plus one inline scanner.
// It is deliberately small and deliberately not CommonMark: no tables, no
// setext headings, no reference links, no HTML, no nested block quotes. Every
// one of those is a real thing somebody could write, and the honest behaviour
// for all of them is the same - they render as the text they are, which is
// still readable. What it *does* cover is the set the mockup shows and the set
// a runbook-shaped page is actually written in.
//
// Pure logic: no AppKit, no disk. `NotebookPreviewView` turns this model into
// views, and its own suite is the window-backed half.

import Foundation

// MARK: - Inline

/// One run of inline content inside a block.
struct NotebookInline: Equatable {
    enum Kind: Equatable {
        case plain
        /// A backtick span - rendered monospaced on a washed chip.
        case code
        /// `[[target]]` / `[[target|label]]`. The *target*, not the label -
        /// resolution is the resolver's job, not the parser's.
        case wikiLink(target: String)
        /// `[label](https://…)`. Opened in the browser, never in the app.
        case link(url: String)
    }

    var text: String
    var kind: Kind = .plain
    var bold = false
    var italic = false

    init(text: String, kind: Kind = .plain, bold: Bool = false, italic: Bool = false) {
        self.text = text
        self.kind = kind
        self.bold = bold
        self.italic = italic
    }
}

// MARK: - Blocks

enum NotebookBlock: Equatable {
    case heading(level: Int, runs: [NotebookInline])
    case paragraph([NotebookInline])
    /// `checked` is `nil` for an ordinary bullet and non-`nil` for a GFM task
    /// item - the distinction the preview draws as a checkbox.
    case bullet(indent: Int, checked: Bool?, runs: [NotebookInline])
    case ordered(indent: Int, number: Int, runs: [NotebookInline])
    case code(language: String?, text: String)
    case quote([NotebookInline])
    case rule
}

// MARK: - The parser

enum NotebookMarkdown {

    /// How deeply a list may indent before further indentation stops
    /// counting. Four is two levels past anything the preview lays out
    /// distinctly, and the cap is what stops a pasted, deeply-indented YAML
    /// block from producing a row indented off the right edge of the pane.
    static let maxListIndent = 4

    static func parse(_ text: String) -> [NotebookBlock] {
        var blocks: [NotebookBlock] = []
        var paragraph: [String] = []
        var fence: (marker: String, language: String?, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
            blocks.append(.paragraph(parseInline(joined)))
            paragraph.removeAll()
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // A fence swallows everything, headings and all, until it closes.
            if var open = fence {
                if trimmed.hasPrefix(open.marker) {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(rawLine)
                    fence = open
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let marker = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fence = (marker, language.isEmpty ? nil : language, [])
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if let quote = parseQuote(trimmed) {
                flushParagraph()
                blocks.append(quote)
                continue
            }

            if let item = parseListItem(rawLine) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            paragraph.append(trimmed)
        }

        // An unterminated fence still has to render - the captain is typing
        // and has not closed it yet, which is the single most common state a
        // *live* preview ever sees.
        if let open = fence {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    // MARK: Block recognisers

    /// `---`, `***`, `___` - three or more of one character, nothing else on
    /// the line. Checked before the heading and list recognisers, because
    /// `---` is also what a naive list scanner would see as three bullets.
    private static func isThematicBreak(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let first = line.first!
        guard first == "-" || first == "*" || first == "_" else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ line: String) -> NotebookBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        // ATX requires the space. `#tag` at the start of a line is a tag, not
        // a heading - and this app's captain writes `#migration` tags (the
        // mockup shows two).
        guard rest.first == " " || rest.isEmpty else { return nil }
        let content = rest.trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, runs: parseInline(content))
    }

    private static func parseQuote(_ line: String) -> NotebookBlock? {
        guard line.hasPrefix(">") else { return nil }
        let content = line.dropFirst().trimmingCharacters(in: .whitespaces)
        return .quote(parseInline(content))
    }

    /// `- item`, `* item`, `+ item`, `1. item`, and the GFM task forms
    /// `- [ ] item` / `- [x] item`.
    private static func parseListItem(_ rawLine: String) -> NotebookBlock? {
        let leading = rawLine.prefix { $0 == " " || $0 == "\t" }
        // Tabs count as one level, spaces as two per level - the two
        // conventions a markdown file in the wild actually uses.
        let spaces = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let indent = min(spaces / 2, maxListIndent)
        let body = rawLine.dropFirst(leading.count)

        if let first = body.first, first == "-" || first == "*" || first == "+" {
            let rest = body.dropFirst()
            guard rest.first == " " else { return nil }
            var content = rest.trimmingCharacters(in: .whitespaces)
            var checked: Bool?
            if content.hasPrefix("[ ] ") || content == "[ ]" {
                checked = false
                content = String(content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if let mark = content.first, mark == "[",
                      content.count >= 3,
                      let close = content.dropFirst(2).first, close == "]",
                      let state = content.dropFirst().first,
                      state == "x" || state == "X" {
                checked = true
                content = String(content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            return .bullet(indent: indent, checked: checked, runs: parseInline(content))
        }

        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let afterDigits = body.dropFirst(digits.count)
            guard let punct = afterDigits.first, punct == "." || punct == ")" else { return nil }
            let rest = afterDigits.dropFirst()
            guard rest.first == " " else { return nil }
            let content = rest.trimmingCharacters(in: .whitespaces)
            return .ordered(indent: indent, number: Int(digits) ?? 1, runs: parseInline(content))
        }
        return nil
    }

    // MARK: Inline

    /// Bold (`**`), italic (`*` / `_`), code spans, `[[wiki-links]]` and
    /// `[text](url)`, in one left-to-right pass.
    ///
    /// Emphasis is deliberately non-nesting beyond bold-plus-italic: markdown's
    /// real emphasis rules are famously the hardest part of CommonMark, and
    /// the failure mode of getting them subtly wrong in a *preview* is text
    /// that silently disappears. This scanner only ever moves text from the
    /// input to the output, so the worst case is a stray asterisk rendered as
    /// itself.
    static func parseInline(_ text: String) -> [NotebookInline] {
        var runs: [NotebookInline] = []
        var buffer = ""
        var bold = false
        var italic = false
        var i = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(NotebookInline(text: buffer, kind: .plain, bold: bold, italic: italic))
            buffer.removeAll()
        }

        while i < text.endIndex {
            let ch = text[i]

            if ch == "\\", text.index(after: i) < text.endIndex {
                buffer.append(text[text.index(after: i)])
                i = text.index(i, offsetBy: 2)
                continue
            }

            if ch == "`" {
                if let close = text[text.index(after: i)...].firstIndex(of: "`") {
                    flush()
                    runs.append(NotebookInline(text: String(text[text.index(after: i)..<close]), kind: .code))
                    i = text.index(after: close)
                    continue
                }
            }

            if ch == "[", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "[" {
                if let parsed = wikiLink(in: text, at: i) {
                    flush()
                    runs.append(NotebookInline(text: parsed.label, kind: .wikiLink(target: parsed.target),
                                               bold: bold, italic: italic))
                    i = parsed.end
                    continue
                }
            }

            if ch == "[", let parsed = inlineLink(in: text, at: i) {
                flush()
                runs.append(NotebookInline(text: parsed.label, kind: .link(url: parsed.url),
                                           bold: bold, italic: italic))
                i = parsed.end
                continue
            }

            if ch == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                flush()
                bold.toggle()
                i = text.index(i, offsetBy: 2)
                continue
            }

            if ch == "*" || ch == "_" {
                // `snake_case_names` must not turn into italics. An `_` only
                // *opens* emphasis at a word boundary, which is the one GFM
                // refinement worth carrying here - this app's content is full
                // of identifiers. A `_` that **closes** an already-open run is
                // always emphasis, whatever precedes it: `_em_`'s closing
                // underscore follows a letter by construction, and treating
                // that as literal left the run open to the end of the line.
                let previous = i > text.startIndex ? text[text.index(before: i)] : " "
                if ch == "_", !italic, previous.isLetter || previous.isNumber {
                    buffer.append(ch)
                    i = text.index(after: i)
                    continue
                }
                flush()
                italic.toggle()
                i = text.index(after: i)
                continue
            }

            buffer.append(ch)
            i = text.index(after: i)
        }
        flush()
        return runs
    }

    private static func wikiLink(in text: String, at start: String.Index)
        -> (target: String, label: String, end: String.Index)? {
        let open = text.index(start, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
        var i = open
        while i < text.endIndex, text[i] != "\n" {
            if text[i] == "]", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "]" {
                let inner = String(text[open..<i])
                let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let target = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard !target.isEmpty else { return nil }
                let alias = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                return (target, alias.isEmpty ? target : alias, text.index(i, offsetBy: 2))
            }
            if text[i] == "[" { return nil }
            i = text.index(after: i)
        }
        return nil
    }

    private static func inlineLink(in text: String, at start: String.Index)
        -> (label: String, url: String, end: String.Index)? {
        var i = text.index(after: start)
        var label = ""
        while i < text.endIndex, text[i] != "\n", text[i] != "]" {
            label.append(text[i])
            i = text.index(after: i)
        }
        guard i < text.endIndex, text[i] == "]" else { return nil }
        let afterLabel = text.index(after: i)
        guard afterLabel < text.endIndex, text[afterLabel] == "(" else { return nil }
        var j = text.index(after: afterLabel)
        var url = ""
        while j < text.endIndex, text[j] != "\n", text[j] != ")" {
            url.append(text[j])
            j = text.index(after: j)
        }
        guard j < text.endIndex, text[j] == ")" else { return nil }
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty, !label.isEmpty else { return nil }
        return (label, trimmedURL, text.index(after: j))
    }

    // MARK: Derived facts the page inspector shows

    /// `#tag` words, in source order and de-duplicated - the chips the
    /// mockup's Page card carries.
    ///
    /// Only a `#` immediately followed by a letter, and only outside code, so
    /// a `# Heading` and a `#!/bin/sh` shebang are both left alone.
    static func tags(in text: String) -> [String] {
        var tags: [String] = []
        var seen = Set<String>()
        var inFence = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence || trimmed.hasPrefix("#!") { continue }
            var i = rawLine.startIndex
            while i < rawLine.endIndex {
                guard rawLine[i] == "#" else { i = rawLine.index(after: i); continue }
                let previous = i > rawLine.startIndex ? rawLine[rawLine.index(before: i)] : " "
                guard previous == " " || previous == "\t" || i == rawLine.startIndex else {
                    i = rawLine.index(after: i)
                    continue
                }
                var j = rawLine.index(after: i)
                var word = ""
                while j < rawLine.endIndex, rawLine[j].isLetter || rawLine[j].isNumber || rawLine[j] == "-" || rawLine[j] == "_" {
                    word.append(rawLine[j])
                    j = rawLine.index(after: j)
                }
                // A heading is `# ` - a space - so a real tag always has a
                // first character and it is a letter.
                if let first = word.first, first.isLetter, !seen.contains(word.lowercased()) {
                    seen.insert(word.lowercased())
                    tags.append(word)
                }
                i = j
            }
        }
        return tags
    }

    /// `(done, total)` across every task item on the page. `total == 0` means
    /// the page has no checklist, which the inspector shows as nothing at all
    /// rather than as "0 of 0" (GL-14: absent and zero are different).
    static func taskProgress(in text: String) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        for block in parse(text) {
            if case .bullet(_, let checked, _) = block, let checked {
                total += 1
                if checked { done += 1 }
            }
        }
        return (done, total)
    }
}
