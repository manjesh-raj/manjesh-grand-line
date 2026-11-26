// Grand Line - native macOS app.
//
// F-03 of full review 4: reader mode and highlights.
// Run with `FM_RUN_READER_MODE_TESTS=1 .build/debug/GrandLine`.
//
// Headless, with no network: the extraction script runs in a real off-screen
// `WKWebView` over HTML this suite hands it.
//
// What it pins:
//
//  - **The script reads the article and nothing else**: headings,
//    paragraphs, quotes, lists and code in order, navigation and footers left
//    out, a repeated title dropped.
//  - **No text is said as no text**: a page under the word floor saves the
//    link only (GL-14).
//  - **The queue keeps the text, and keeps highlights across a re-read.**
//  - **A highlight** maps from a selection in the clean page to its block,
//    draws on the page, and goes to the Notebook as a quote with its source.
//  - **Source guards** on the page's wiring.

#if FM_SELFTESTS

import AppKit

enum ReaderModeSelfTest {

    static func run() -> Bool {
        var ok = true
        let cases: [(String, () -> String?)] = [
            ("the script reads the article", test_extractionScript),
            ("blocks from the script's answer", test_blocks),
            ("the queue keeps text and highlights", test_queue),
            ("highlights and the Notebook quote", test_highlights),
            ("the clean page and its selection", test_readerView),
            ("the page's wiring", test_wiring),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[reader] \(name): \(failure)", &ok) } else { print("[reader] PASS \(name)") }
        }
        print(ok ? "[reader] ALL PASS" : "[reader] FAILED")
        return ok
    }

    static let paragraph = "For a year our checkout API sat at a p99 of 820 ms, and every fix we tried moved the median instead. The tail was never the database. It was the connection pool waiting on a single slow upstream."
    static let html = """
    <html><head><title>How we cut our p99 latency in half</title></head><body>
    <nav><p>Home Blog About Careers Pricing</p></nav>
    <article>
      <h1>How we cut our p99 latency in half</h1>
      <p>\(paragraph)</p>
      <h2>Sampling the tail</h2>
      <p>We started by tracing only the slowest one percent of requests. Sampling the tail, not the average, showed that 70 percent of slow requests shared one span: a TLS handshake to the payments gateway.</p>
      <blockquote>Keep-alive had been switched off two years earlier to fix a load-balancer bug nobody remembered.</blockquote>
      <ul><li>Turn keep-alive back on</li><li>Watch the pool</li></ul>
      <pre>curl -w '%{time_connect}' https://payments.example.test</pre>
    </article>
    <footer><p>Copyright 2026 Example Inc. All rights reserved.</p></footer>
    </body></html>
    """

    static func article(_ blocks: [ReaderArticle.Block], highlights: [ReaderArticle.Highlight] = []) -> ReaderArticle {
        ReaderArticle(linkID: "link-1", url: "https://blog.example.dev/p99", title: "How we cut our p99 latency in half",
                      site: "blog.example.dev", byline: nil, savedAt: Date(timeIntervalSince1970: 1_795_000_000),
                      state: .saved, blocks: blocks, highlights: highlights)
    }

    static func test_extractionScript() -> String? {
        let extractor = ReaderArticleExtractor()
        var json: String?
        var finished = false
        extractor.extract(html: html, baseURL: URL(string: "https://blog.example.dev/")) { json = $0; finished = true }
        let deadline = Date().addingTimeInterval(15)
        while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let json else { return "the script answered nothing" }
        let blocks = ReaderExtraction.blocks(fromJSON: json, title: "How we cut our p99 latency in half")
        let kinds = blocks.map(\.kind)
        guard kinds == [.paragraph, .heading, .paragraph, .quote, .item, .item, .code] else { return "kinds \(kinds) from \(json)" }
        guard blocks.first?.text == paragraph else { return "the first paragraph is \(blocks.first?.text ?? "nil")" }
        guard !blocks.contains(where: { $0.text.contains("Careers") || $0.text.contains("Copyright") }) else {
            return "navigation or the footer was read as the article"
        }
        return ReaderExtraction.hasArticle(blocks) ? nil : "a real article fell under the word floor"
    }

    static func test_blocks() -> String? {
        let json = #"{"title":"T","byline":"Priya Raman","blocks":[{"k":"heading","t":"T"},{"k":"paragraph","t":"one"},{"k":"paragraph","t":"one"},{"k":"bogus","t":"x"}]}"#
        let blocks = ReaderExtraction.blocks(fromJSON: json, title: "T")
        guard blocks == [.init(kind: .paragraph, text: "one")] else { return "blocks \(blocks)" }
        guard ReaderExtraction.byline(fromJSON: json) == "Priya Raman" else { return "byline" }
        return ReaderExtraction.hasArticle(blocks) ? "four words passed the floor" : nil
    }

    static func test_queue() -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = ReaderArticleQueue(store: ReaderArticleStore(directory: dir))
        var answers: [String?] = [
            #"{"title":"x","blocks":[{"k":"paragraph","t":"\#(String(repeating: "word ", count: 80))"}]}"#,
            nil,
        ]
        queue.fetch = { _, done in let answer = answers.removeFirst(); DispatchQueue.main.async { done(answer) } }
        var saved: [String] = []
        queue.onSaved = { saved.append($0) }
        func link(_ id: String, _ url: String) -> ReadingLink {
            ReadingLink(id: id, url: url, title: "", summary: "", aiSummary: "", tags: [], addedAt: Date(),
                        readAt: nil, metadataState: .pending)
        }
        let good = link("link-good", "https://blog.example.dev/p99")
        let bad = link("link-bad", "https://spa.example.dev/")
        queue.enqueue(good)
        queue.enqueue(bad)
        let deadline = Date().addingTimeInterval(3)
        while saved.count < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard queue.store.article(id: "link-good")?.state == .saved else { return "the good page was not saved" }
        guard let noText = queue.store.article(id: "link-bad"), noText.state == .noText, noText.blocks.isEmpty else {
            return "a page with no text was not said as such"
        }
        // A re-read keeps the highlights.
        var withHighlight = queue.store.article(id: "link-good")!
        withHighlight.highlights = [ReaderHighlights.make(article: withHighlight, block: 0, range: NSRange(location: 0, length: 4))!]
        queue.store.save(withHighlight)
        answers = [#"{"title":"x","blocks":[{"k":"paragraph","t":"\#(String(repeating: "word ", count: 80))"}]}"#]
        saved.removeAll()
        queue.enqueue(good, force: true)
        let deadline2 = Date().addingTimeInterval(3)
        while saved.isEmpty, Date() < deadline2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return queue.store.article(id: "link-good")?.highlights.count == 1 ? nil : "a re-read lost the highlights"
    }

    static func test_highlights() -> String? {
        let a = article([.init(kind: .paragraph, text: paragraph)])
        guard ReaderHighlights.make(article: a, block: 3, range: NSRange(location: 0, length: 3)) == nil else { return "an out-of-range block made a highlight" }
        guard let h = ReaderHighlights.make(article: a, block: 0, range: NSRange(location: 51, length: 40)) else { return "no highlight" }
        guard h.text == "and every fix we tried moved the median" else { return "highlight text \(h.text.debugDescription)" }
        let quote = ReaderHighlights.notebookQuote(h, article: a)
        guard quote.hasPrefix("> and every fix"), quote.contains("From [How we cut our p99 latency in half](https://blog.example.dev/p99) \u{00B7} blog.example.dev") else {
            return "the quote reads \(quote)"
        }
        return nil
    }

    static func test_readerView() -> String? {
        let blocks: [ReaderArticle.Block] = [.init(kind: .paragraph, text: "First paragraph here."),
                                             .init(kind: .heading, text: "A heading"),
                                             .init(kind: .paragraph, text: paragraph)]
        let existing = ReaderArticle.Highlight(id: "h1", block: 2, start: 0, length: 9, text: "For a yea", createdAt: Date(), sentToPageID: nil)
        let view = ReadingListReaderView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.show(article(blocks, highlights: [existing]), theme: ThemeManager.shared.theme)
        view.layoutSubtreeIfNeeded()
        guard view.debugText.contains("A heading"), view.blockOffsets.count == 3 else { return "text \(view.debugText)" }
        guard view.debugHighlightedRanges() == [NSRange(location: view.blockOffsets[2], length: 9)] else {
            return "the existing highlight is drawn at \(view.debugHighlightedRanges()), offsets \(view.blockOffsets)"
        }
        var picked: (Int, NSRange)?
        view.onHighlight = { picked = ($0, $1) }
        view.debugSelect(NSRange(location: view.blockOffsets[2] + 10, length: 8))
        guard view.debugSelectionBarShown else { return "a selection did not show the bar" }
        view.debugPressHighlight()
        guard let (block, range) = picked, block == 2, range == NSRange(location: 10, length: 8) else {
            return "Highlight reported \(String(describing: picked))"
        }
        view.show(ReaderArticle(linkID: "x", url: "u", title: "t", site: "s", byline: nil, savedAt: Date(),
                                state: .noText, blocks: [], highlights: []), theme: ThemeManager.shared.theme)
        return view.debugShowsNoText ? nil : "a page with no text did not say so"
    }

    static func test_wiring() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { print("[reader] SKIP guard"); return nil }
        let text = (try? String(contentsOf: dir.appendingPathComponent("ReadingListController.swift"), encoding: .utf8)) ?? ""
        guard text.contains("if let link = self.store.link(id: id) { self.articles.enqueue(link) }") else {
            return "a saved link no longer keeps its text"
        }
        guard text.contains("let article = articles.store.article(id: id)"), text.contains("readerCard.addSubview(readerView)") else {
            return "opening a link no longer shows the saved text"
        }
        return nil
    }
}

#endif
