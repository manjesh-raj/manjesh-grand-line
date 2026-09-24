// Grand Line - native macOS app.
//
// The Notebook's link graph: `[[wiki-links]]`, how one resolves to a real
// page, and the reverse index that answers "what links *here*".
//
// Pure logic, no AppKit, no disk - which is why its suite
// (`FM_RUN_NOTEBOOK_TESTS`) is in CI's **blocking** lane rather than the
// windowed one. The rule is AGENTS.md's "Writing a self-test": the test is
// what the suite asserts, and none of this needs a window server.
//
// ## The syntax, and what is deliberately not supported
//
// `[[Target]]` and `[[Target|what to show]]`. That is all. No `[[page#heading]]`
// anchors, no `![[transclusion]]`, no aliases file. Each of those is a real
// feature in some other notebook app and each would need its own resolution
// rule, its own rendering and its own failure mode; the report's F1 entry asks
// for "wiki-links `[[page]]`, backlinks", and this is exactly that.
//
// **Links inside code are not links.** A fenced block or an inline code span
// that happens to contain `[[...]]` is quoted text - most often a shell glob
// or a nested-array index - and turning it into navigation would corrupt the
// one kind of content this app's captain writes most. The scanner therefore
// tracks fences and backtick runs, which is the only structural awareness in
// this file.
//
// ## Resolution
//
// A target is matched against the page corpus in a fixed order, most specific
// first, and the order is the whole contract:
//
//   1. an exact page id (`migrations/raas-cutover`) - a link somebody wrote
//      deliberately with a path in it means that path;
//   2. the same, case-insensitively;
//   3. a page *title* (`RaaS cutover`), case-insensitively - what a captain
//      actually types;
//   4. a slug match (`slugify(target)` against the page's own final path
//      component), which is what makes `[[RaaS cutover]]` find
//      `migrations/raas-cutover.md`.
//
// Ties inside one rule are broken **toward the linking page's own folder**
// first and then by shortest id. Two pages called "Notes" in two folders is a
// real thing a notebook grows, and "the one next to me" is the only answer
// that is ever right more often than a coin flip. Where the tie survives
// that, the resolution is still deterministic (shortest id, then
// alphabetical), because a link that resolved differently on each render
// would be worse than one that resolved wrongly but consistently.
//
// An unresolved link is **not an error**. It is a page that does not exist
// yet, which is how notebooks are actually written - you link forward and
// fill in later - so the renderer draws it distinctly and clicking it offers
// to create it.

import Foundation

// MARK: - One link occurrence

/// A `[[...]]` found in a page's source.
struct NotebookWikiLink: Equatable {
    /// What was written inside the brackets, before any `|`.
    let target: String
    /// The text to display - the `|alias` when there is one, else `target`.
    let label: String
    /// Byte-free character offsets into the source string, so a caller can
    /// slice around them without re-scanning. `range.lowerBound` is the first
    /// `[`, `range.upperBound` is one past the final `]`.
    let range: Range<String.Index>
}

/// A resolved link on a page, as the preview and the backlink panel see it.
struct NotebookResolvedLink: Equatable {
    let link: NotebookWikiLink
    /// The page this points at, or `nil` for a page that does not exist yet.
    let pageID: String?

    var exists: Bool { pageID != nil }
}

/// One entry in a page's "what links here" list.
struct NotebookBacklink: Equatable {
    /// The page that carries the link.
    let sourceID: String
    let sourceTitle: String
    /// The sentence the link sits in, trimmed to something a narrow column can
    /// show. Real text from the source page - the mockup's own
    /// `"…blocked on [[RaaS cutover]] window"` - rather than a bare page name,
    /// because the point of a backlink is remembering *why* you linked.
    let context: String
}

// MARK: - Parsing

enum NotebookLinks {

    /// Every `[[...]]` in `text`, in source order, skipping anything inside a
    /// fenced code block or an inline code span.
    ///
    /// Written as an explicit scan rather than an `NSRegularExpression`
    /// because the code-awareness above is not expressible as one pattern, and
    /// a regex that pretended to be would be the kind of check that passes
    /// while being wrong.
    static func parse(_ text: String) -> [NotebookWikiLink] {
        var links: [NotebookWikiLink] = []
        var inFence = false

        for line in lines(of: text) {
            let trimmed = text[line].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            scanLine(text, range: line, into: &links)
        }
        return links
    }

    /// Line ranges of `text`, newline excluded. `split` would lose the
    /// indices, and the ranges are what a caller slices with.
    private static func lines(of text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\n" {
                result.append(start..<i)
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        result.append(start..<text.endIndex)
        return result
    }

    private static func scanLine(_ text: String, range: Range<String.Index>, into links: inout [NotebookWikiLink]) {
        var i = range.lowerBound
        var inCodeSpan = false
        while i < range.upperBound {
            let ch = text[i]
            if ch == "`" {
                inCodeSpan.toggle()
                i = text.index(after: i)
                continue
            }
            // An escaped `\[[...]]` is literal text - the one escape this
            // syntax needs, and the one a captain writing *about* wiki-links
            // will reach for.
            if ch == "\\", text.index(after: i) < range.upperBound, text[text.index(after: i)] == "[" {
                i = text.index(i, offsetBy: 2)
                continue
            }
            guard !inCodeSpan, ch == "[" else {
                i = text.index(after: i)
                continue
            }
            let second = text.index(after: i)
            guard second < range.upperBound, text[second] == "[" else {
                i = text.index(after: i)
                continue
            }
            guard let close = closingBrackets(in: text, from: text.index(after: second), limit: range.upperBound) else {
                i = text.index(after: i)
                continue
            }
            let inner = String(text[text.index(after: second)..<close])
            if let link = makeLink(inner: inner, range: i..<text.index(close, offsetBy: 2)) {
                links.append(link)
            }
            i = text.index(close, offsetBy: 2)
        }
    }

    /// The index of the first `]` of a `]]` pair, or `nil` if the line ends
    /// first. A `[` inside the brackets aborts the match - an unterminated
    /// `[[` followed by another `[[` on the same line should not swallow the
    /// text between them.
    private static func closingBrackets(in text: String, from start: String.Index, limit: String.Index) -> String.Index? {
        var i = start
        while i < limit {
            if text[i] == "[" { return nil }
            if text[i] == "]" {
                let next = text.index(after: i)
                if next < limit, text[next] == "]" { return i }
                return nil
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func makeLink(inner: String, range: Range<String.Index>) -> NotebookWikiLink? {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !target.isEmpty else { return nil }
        let alias = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return NotebookWikiLink(target: target,
                                label: alias.isEmpty ? target : alias,
                                range: range)
    }

    /// Replaces a link's target wherever it appears in `text`, keeping any
    /// alias. Used when a page is renamed, so the graph does not decay every
    /// time the captain tidies a name.
    static func retarget(_ text: String, from oldTarget: String, to newTarget: String) -> String {
        let links = parse(text)
        guard !links.isEmpty else { return text }
        var result = text
        // Back to front, so an earlier replacement cannot invalidate a later
        // link's indices.
        for link in links.reversed() where matches(target: link.target, oldTarget) {
            let alias = link.label == link.target ? "" : "|\(link.label)"
            result.replaceSubrange(link.range, with: "[[\(newTarget)\(alias)]]")
        }
        return result
    }

    private static func matches(target: String, _ other: String) -> Bool {
        target.compare(other, options: .caseInsensitive) == .orderedSame
    }
}

// MARK: - Resolution

/// Resolves link targets against a page corpus.
///
/// Built once per corpus read rather than per link: a page with forty links
/// would otherwise be forty linear scans of the whole notebook, which is
/// exactly the O(files)-per-row shape GL-35 asks to be memoised.
struct NotebookLinkResolver {

    private let byID: [String: String]            // lowercased id -> id
    private let byTitle: [String: [String]]       // lowercased title -> ids
    private let bySlug: [String: [String]]        // slugified final component -> ids
    private let exactIDs: Set<String>

    init(pages: [NotebookPage]) {
        var byID: [String: String] = [:]
        var byTitle: [String: [String]] = [:]
        var bySlug: [String: [String]] = [:]
        var exact = Set<String>()
        for page in pages {
            exact.insert(page.id)
            byID[page.id.lowercased()] = page.id
            byTitle[page.title.lowercased(), default: []].append(page.id)
            bySlug[NotebookStore.slugify(page.slug), default: []].append(page.id)
            // A title's own slug too, so `[[RaaS cutover]]` finds a page whose
            // file is `raas-cutover.md` *and* one whose file is
            // `2026-cutover.md` but whose heading is "RaaS cutover".
            bySlug[NotebookStore.slugify(page.title), default: []].append(page.id)
        }
        self.byID = byID
        self.byTitle = byTitle
        self.bySlug = bySlug
        self.exactIDs = exact
    }

    /// The page a target names, or `nil` for a page that does not exist yet.
    ///
    /// `from` is the linking page's own id; its folder wins a tie. See the
    /// file header for the full order.
    func resolve(_ target: String, from sourceID: String? = nil) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if exactIDs.contains(trimmed) { return trimmed }
        if let hit = byID[trimmed.lowercased()] { return hit }
        if let hits = byTitle[trimmed.lowercased()], !hits.isEmpty { return pick(hits, from: sourceID) }
        if let hits = bySlug[NotebookStore.slugify(trimmed)], !hits.isEmpty { return pick(hits, from: sourceID) }
        return nil
    }

    /// The deterministic tie-break: same folder as the linking page first,
    /// then shortest id, then alphabetical. See the file header for why a
    /// stable wrong answer beats an unstable one.
    private func pick(_ candidates: [String], from sourceID: String?) -> String? {
        guard candidates.count > 1 else { return candidates.first }
        let sourceFolder: String = {
            guard let sourceID, let slash = sourceID.lastIndex(of: "/") else { return "" }
            return String(sourceID[sourceID.startIndex..<slash])
        }()
        func folder(of id: String) -> String {
            guard let slash = id.lastIndex(of: "/") else { return "" }
            return String(id[id.startIndex..<slash])
        }
        return candidates.sorted { a, b in
            let aLocal = folder(of: a) == sourceFolder
            let bLocal = folder(of: b) == sourceFolder
            if aLocal != bLocal { return aLocal }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }.first
    }

    /// Every link on a page, each with whatever it resolves to.
    func links(in page: NotebookPage) -> [NotebookResolvedLink] {
        NotebookLinks.parse(page.content).map {
            NotebookResolvedLink(link: $0, pageID: resolve($0.target, from: page.id))
        }
    }
}

// MARK: - The reverse index

/// "What links here", for every page at once.
///
/// **Built over the whole corpus, never per page.** The report's spec calls
/// this out explicitly ("a real index/scan mechanism over the notebook's
/// Markdown files, not just parsing one page in isolation"), and the reason is
/// not tidiness: a backlink is by definition information that is *not* on the
/// page you are looking at, so a per-page parse can never produce one.
struct NotebookBacklinkIndex {

    /// Target page id -> the pages pointing at it.
    private let incoming: [String: [NotebookBacklink]]
    /// Link targets that matched no page, with the page that wrote each -
    /// what a "3 links point at pages that do not exist" affordance reads.
    let unresolved: [(target: String, sourceID: String)]

    /// How much of the surrounding line a backlink row quotes. Sized off the
    /// mockup's own 188pt column at two lines of `caption()`.
    static let contextChars = 90

    init(pages: [NotebookPage], resolver: NotebookLinkResolver) {
        var incoming: [String: [NotebookBacklink]] = [:]
        var unresolved: [(target: String, sourceID: String)] = []
        for page in pages {
            for link in NotebookLinks.parse(page.content) {
                guard let targetID = resolver.resolve(link.target, from: page.id) else {
                    unresolved.append((link.target, page.id))
                    continue
                }
                // A page that links to itself is not a backlink - it would
                // show up on its own panel as "this page mentions this page",
                // which tells the captain nothing.
                guard targetID != page.id else { continue }
                let entry = NotebookBacklink(sourceID: page.id,
                                             sourceTitle: page.title,
                                             context: Self.context(around: link.range, in: page.content))
                // One row per source page, not per occurrence: five mentions
                // of the same target on one page is one relationship.
                if incoming[targetID]?.contains(where: { $0.sourceID == page.id }) == true { continue }
                incoming[targetID, default: []].append(entry)
            }
        }
        // Sorted so the panel's order is stable across rebuilds - a list that
        // reshuffles on every keystroke reads as broken.
        self.incoming = incoming.mapValues { $0.sorted { $0.sourceID.localizedStandardCompare($1.sourceID) == .orderedAscending } }
        self.unresolved = unresolved
    }

    func backlinks(to pageID: String) -> [NotebookBacklink] { incoming[pageID] ?? [] }

    /// How many distinct pages link to `pageID`.
    func count(to pageID: String) -> Int { incoming[pageID]?.count ?? 0 }

    /// Every page nothing links to and which links to nothing - the notebook's
    /// own loose ends. Cheap to derive here and genuinely useful; the sidebar
    /// does not show it yet, and the index is where it belongs when it does.
    func orphans(among pages: [NotebookPage]) -> [String] {
        let linked = Set(incoming.keys)
        return pages.map(\.id).filter { !linked.contains($0) }
    }

    /// The line a link sits in, elided around it.
    private static func context(around range: Range<String.Index>, in content: String) -> String {
        var start = range.lowerBound
        while start > content.startIndex {
            let previous = content.index(before: start)
            if content[previous] == "\n" { break }
            start = previous
        }
        var end = range.upperBound
        while end < content.endIndex, content[end] != "\n" { end = content.index(after: end) }
        var line = String(content[start..<end]).trimmingCharacters(in: .whitespaces)
        // Leading markdown furniture is noise in a one-line quote.
        while let first = line.first, first == "#" || first == ">" || first == "-" || first == "*" {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        if line.count <= contextChars { return line }
        // Keep the link itself in frame rather than truncating from the left.
        let linkOffset = content.distance(from: start, to: range.lowerBound)
        let window = max(0, min(linkOffset - contextChars / 3, max(0, line.count - contextChars)))
        let from = line.index(line.startIndex, offsetBy: window)
        let to = line.index(from, offsetBy: min(contextChars, line.distance(from: from, to: line.endIndex)))
        var excerpt = String(line[from..<to])
        if window > 0 { excerpt = "\u{2026}" + excerpt }
        if to < line.endIndex { excerpt += "\u{2026}" }
        return excerpt
    }
}
