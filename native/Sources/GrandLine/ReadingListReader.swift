// Grand Line - native macOS app.
//
// F-03 of full review 4: reader mode and highlights.
//
// When a link is saved, its article's text is kept: the page is loaded once
// in a non-persistent, off-screen `WKWebView` (the same isolation the
// reader's own web view has, S13), and a small script reads the article's
// headings, paragraphs, quotes, lists and code out of it. The text is shown
// as a clean page inside the app, passages can be highlighted, and a
// highlight goes to a Notebook page as a quote with its source link.
//
// **Where it is kept.** On this Mac only (`reading-list-articles/<id>.json`
// under the data folder), as the mock-up's "text and highlights saved on
// this machine" says. The link itself stays in the synced reading list; the
// article text can always be read again from the page.
//
// **A page with no text.** A page that builds its text with scripts after
// it loads, or that refuses a non-browser, leaves nothing to keep. The link
// is still saved, and the reader says only the link was saved, with Try
// again and Open the original (GL-14: never an empty article passed off as
// one).

import AppKit
import WebKit

// MARK: - The article

struct ReaderArticle: Codable, Equatable {

    struct Block: Codable, Equatable {
        enum Kind: String, Codable { case heading, paragraph, quote, item, code }
        var kind: Kind
        var text: String
    }

    struct Highlight: Codable, Equatable, Identifiable {
        var id: String
        var block: Int
        var start: Int
        var length: Int
        var text: String
        var createdAt: Date
        /// The Notebook page it was sent to, if any.
        var sentToPageID: String?
    }

    enum State: String, Codable { case saved, noText }

    var linkID: String
    var url: String
    var title: String
    var site: String
    var byline: String?
    var savedAt: Date
    var state: State
    var blocks: [Block]
    var highlights: [Highlight]

    var wordCount: Int { blocks.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }

    /// Reading time at 220 words a minute, never under one minute.
    var minutes: Int { max(1, Int((Double(wordCount) / 220).rounded())) }

    /// "blog.example.dev · 18 November 2026 · 9 min read".
    var metaLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMMM yyyy"
        return [site, byline, f.string(from: savedAt), "\(minutes) min read"].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

/// The JSON the extraction script answers with, and how it becomes blocks.
enum ReaderExtraction {

    /// A page with less than this much text is a page with no article.
    static let minimumWords = 60

    /// Runs inside the page. Prefers `<article>`, then `<main>`, then the
    /// element holding the most paragraph text, and reads its blocks in
    /// order, skipping navigation, asides, forms and anything hidden.
    static let script = """
    (function() {
      function visible(el) { var s = window.getComputedStyle(el); return s && s.display !== 'none' && s.visibility !== 'hidden'; }
      var skip = 'nav,aside,footer,header,form,script,style,noscript,figure figcaption,[role=navigation],[aria-hidden=true]';
      function textOf(el) { return (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim(); }
      var root = document.querySelector('article') || document.querySelector('main') || document.querySelector('[role=main]');
      if (!root) {
        var best = null, bestLen = 0;
        document.querySelectorAll('div,section').forEach(function(d) {
          var len = 0; d.querySelectorAll(':scope > p').forEach(function(p) { len += textOf(p).length; });
          if (len > bestLen) { bestLen = len; best = d; }
        });
        root = best || document.body;
      }
      var blocks = [];
      root.querySelectorAll('h1,h2,h3,h4,p,blockquote,li,pre').forEach(function(el) {
        if (el.closest(skip) || !visible(el)) return;
        if (el.tagName === 'P' && el.closest('blockquote,li')) return;
        var t = el.tagName === 'PRE' ? (el.innerText || '').trim() : textOf(el);
        if (!t) return;
        var k = /^H[1-4]$/.test(el.tagName) ? 'heading' : el.tagName === 'BLOCKQUOTE' ? 'quote'
              : el.tagName === 'LI' ? 'item' : el.tagName === 'PRE' ? 'code' : 'paragraph';
        blocks.push({k: k, t: t});
      });
      var byline = document.querySelector('[rel=author],.byline,.author,meta[name=author]');
      return JSON.stringify({title: document.title || '', byline: byline ? (byline.content || textOf(byline)) : '', blocks: blocks});
    })();
    """

    /// Blocks from the script's JSON. The first heading is dropped when it
    /// repeats the title, and a run of identical blocks is kept once.
    static func blocks(fromJSON json: String, title: String) -> [ReaderArticle.Block] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["blocks"] as? [[String: Any]] else { return [] }
        var out: [ReaderArticle.Block] = []
        for entry in raw {
            guard let k = entry["k"] as? String, let t = entry["t"] as? String,
                  let kind = ReaderArticle.Block.Kind(rawValue: k) else { continue }
            let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, out.last?.text != text else { continue }
            if out.isEmpty, kind == .heading, text.caseInsensitiveCompare(title) == .orderedSame { continue }
            out.append(.init(kind: kind, text: text))
        }
        return out
    }

    static func byline(fromJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byline = (object["byline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !byline.isEmpty, byline.count < 80 else { return nil }
        return byline
    }

    static func hasArticle(_ blocks: [ReaderArticle.Block]) -> Bool {
        blocks.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } >= minimumWords
    }
}

// MARK: - The store

/// One JSON file per article under the data folder, on this Mac only.
final class ReaderArticleStore {

    static let directoryVariable = "FM_READER_ARTICLES_DIR"
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let env = ProcessInfo.processInfo.environment[Self.directoryVariable], !env.isEmpty {
            self.directory = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            self.directory = AppPaths.dataRoot().appendingPathComponent("reading-list-articles", isDirectory: true)
        }
    }

    private func url(for id: String) -> URL? {
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return directory.appendingPathComponent("\(id).json")
    }

    func article(id: String) -> ReaderArticle? {
        guard let url = url(for: id), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReaderArticle.self, from: data)
    }

    func save(_ article: ReaderArticle) {
        guard let url = url(for: article.linkID) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try AtomicWrite.data(encoder.encode(article), to: url)
        } catch {
            PersistenceFailureReporter.report(what: "the saved article text", path: url.path, error: error)
        }
    }

    func remove(id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Every highlight across every saved article, newest first.
    func allHighlights() -> [(article: ReaderArticle, highlight: ReaderArticle.Highlight)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { article(id: $0.deletingPathExtension().lastPathComponent) }
            .flatMap { a in a.highlights.map { (a, $0) } }
            .sorted { $0.highlight.createdAt > $1.highlight.createdAt }
    }

    func highlightCount() -> Int { allHighlights().count }
}

// MARK: - Highlights

enum ReaderHighlights {

    /// A highlight from a selection inside one block, or nil for an empty or
    /// out-of-range one.
    static func make(article: ReaderArticle, block: Int, range: NSRange, now: Date = Date()) -> ReaderArticle.Highlight? {
        guard article.blocks.indices.contains(block) else { return nil }
        let text = article.blocks[block].text as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        let picked = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !picked.isEmpty else { return nil }
        return .init(id: UUID().uuidString.lowercased(), block: block, start: range.location, length: range.length,
                     text: picked, createdAt: now, sentToPageID: nil)
    }

    /// The quote a Notebook page gets: the passage, then where it came from.
    static func notebookQuote(_ highlight: ReaderArticle.Highlight, article: ReaderArticle, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        let quote = highlight.text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        return "\(quote)\n>\n> From [\(article.title)](\(article.url)) \u{00B7} \(article.site) \u{00B7} saved \(f.string(from: article.savedAt)) \u{00B7} highlighted \(f.string(from: highlight.createdAt))\n"
    }
}

// MARK: - Fetching the text

/// Loads a page off screen and reads its article out of it. One page at a
/// time; each load is bounded.
final class ReaderArticleExtractor: NSObject, WKNavigationDelegate {

    static let timeout: TimeInterval = 20

    private var webView: WKWebView?
    private var completion: ((String?) -> Void)?
    private var timer: Timer?

    /// Answers the script's JSON, or nil when the page did not load.
    func extract(url: URL, completion: @escaping (String?) -> Void) {
        guard NetworkGate.allowsOutOfProcessLoad(url) else { completion(nil); return }
        start(completion: completion) { $0.load(URLRequest(url: url, timeoutInterval: Self.timeout)) }
    }

    /// The same read over HTML in hand - what a self-test drives.
    func extract(html: String, baseURL: URL?, completion: @escaping (String?) -> Void) {
        start(completion: completion) { $0.loadHTMLString(html, baseURL: baseURL) }
    }

    private func start(completion: @escaping (String?) -> Void, load: (WKWebView) -> Void) {
        cancel()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        self.completion = completion
        let timer = Timer(timeInterval: Self.timeout, repeats: false) { [weak self] _ in self?.finish(nil) }
        // Audit 3.4: a give-up deadline can be a second late.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        load(webView)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        completion = nil
    }

    private func finish(_ json: String?) {
        let done = completion
        cancel()
        done?(json)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A moment for scripts that fill the page in on load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak webView] in
            guard let self, let webView, webView === self.webView else { return }
            webView.evaluateJavaScript(ReaderExtraction.script) { result, _ in self.finish(result as? String) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    /// Only the page itself and what it loads; nothing opens elsewhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}

/// Keeps the article text for saved links, one at a time.
final class ReaderArticleQueue {

    let store: ReaderArticleStore
    private let extractor = ReaderArticleExtractor()
    private var queue: [ReadingLink] = []
    private var busy = false
    var onSaved: ((String) -> Void)?
    /// Replaced in a self-test, which hands it HTML.
    var fetch: (URL, @escaping (String?) -> Void) -> Void

    init(store: ReaderArticleStore = ReaderArticleStore()) {
        self.store = store
        let extractor = self.extractor
        fetch = { url, done in extractor.extract(url: url, completion: done) }
    }

    func enqueue(_ link: ReadingLink, force: Bool = false) {
        guard force || store.article(id: link.id) == nil, !queue.contains(where: { $0.id == link.id }) else { return }
        queue.append(link)
        pump()
    }

    var isWorking: Bool { busy || !queue.isEmpty }

    private func pump() {
        guard !busy, !queue.isEmpty, let url = URL(string: queue[0].url) else {
            if !queue.isEmpty, !busy { queue.removeFirst(); pump() }
            return
        }
        busy = true
        let link = queue.removeFirst()
        fetch(url) { [weak self] json in
            guard let self else { return }
            let title = link.displayTitle
            let blocks = json.map { ReaderExtraction.blocks(fromJSON: $0, title: title) } ?? []
            let keep = ReaderExtraction.hasArticle(blocks)
            var article = ReaderArticle(linkID: link.id, url: link.url, title: title,
                                        site: link.host, byline: json.flatMap(ReaderExtraction.byline(fromJSON:)),
                                        savedAt: Date(), state: keep ? .saved : .noText, blocks: keep ? blocks : [],
                                        highlights: [])
            if let existing = self.store.article(id: link.id) { article.highlights = existing.highlights }
            self.store.save(article)
            self.busy = false
            self.onSaved?(link.id)
            self.pump()
        }
    }
}
