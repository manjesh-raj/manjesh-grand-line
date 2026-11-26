// Grand Line - native macOS app.
//
// UX-12 of full review 4: the Notebook writes in one pane.
//
// Write is the Notebook's default view. It is a native text view that shows
// the page formatted as it is typed: headings at their size, bold, italics,
// code, `[[wiki-links]]` and Markdown links in the link colour, and quotes
// and lists set in. The Markdown marks themselves (`#`, `**`, `[[`, the
// brackets of a link) are hidden on every line but the one the caret is on,
// where they show dimmed, so the source is always one click away and never
// in the way. Split and Source keep the Monaco editor for the times the
// source itself is the point.
//
// The file on disk is plain Markdown and nothing here changes it: the view
// only paints attributes over the text it holds. `NotebookLiveMarkdown` finds
// what to paint, pure, so a suite asserts the spans without a window.

import AppKit

// MARK: - What to paint

enum NotebookLiveMarkdown {

    enum Kind: Equatable {
        /// A heading line's words, at its level.
        case heading(Int)
        case bold
        case italic
        case code
        /// A `[[wiki-link]]`'s target, or a Markdown link's URL.
        case link(String)
        /// Syntax: hidden off the caret's line, dimmed on it.
        case mark
        /// A list bullet, a task box or a quote bar: always shown, quiet.
        case structure
        /// A fenced code block's line.
        case codeBlock
    }

    struct Span: Equatable {
        let range: NSRange
        let kind: Kind
    }

    /// Every span in `text`, line by line. Ranges are UTF-16, as
    /// `NSTextStorage` counts.
    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        var inFence = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let lineText = ns.substring(with: line)
            if lineText.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                spans.append(Span(range: line, kind: .mark))
                inFence.toggle()
                return
            }
            if inFence {
                spans.append(Span(range: line, kind: .codeBlock))
                return
            }
            var bodyStart = line.location
            if let m = match(#"^(#{1,6})\s+"#, in: lineText) {
                let level = m.range(at: 1).length
                spans.append(Span(range: NSRange(location: line.location, length: m.range.length), kind: .mark))
                spans.append(Span(range: NSRange(location: line.location + m.range.length,
                                                 length: line.length - m.range.length), kind: .heading(level)))
                bodyStart = line.location + m.range.length
            } else if let m = match(#"^\s*([-*+]\s\[[ xX]\]|[-*+]|\d+\.)\s"#, in: lineText) {
                spans.append(Span(range: NSRange(location: line.location, length: m.range.length), kind: .structure))
                bodyStart = line.location + m.range.length
            } else if let m = match(#"^>\s?"#, in: lineText) {
                spans.append(Span(range: NSRange(location: line.location, length: m.range.length), kind: .structure))
                bodyStart = line.location + m.range.length
            }
            let body = NSRange(location: bodyStart, length: line.location + line.length - bodyStart)
            spans.append(contentsOf: inlineSpans(in: ns, range: body))
        }
        return spans
    }

    private static func match(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = regexes[pattern] ?? (try? NSRegularExpression(pattern: pattern)) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static let regexes: [String: NSRegularExpression] = {
        var out: [String: NSRegularExpression] = [:]
        for pattern in [#"^(#{1,6})\s+"#, #"^\s*([-*+]\s\[[ xX]\]|[-*+]|\d+\.)\s"#, #"^>\s?"#,
                        #"`([^`\n]+)`"#, #"\*\*([^*\n]+)\*\*"#, #"(?<![*\w])[*_]([^*_\n]+)[*_](?![*\w])"#,
                        #"\[\[([^\]\n|]+)(\|([^\]\n]+))?\]\]"#, #"(?<!\[)\[([^\]\n]+)\]\(([^)\n]+)\)"#] {
            out[pattern] = try? NSRegularExpression(pattern: pattern)
        }
        return out
    }()

    /// Code first, so nothing inside a code span is read as emphasis or a
    /// link.
    private static func inlineSpans(in ns: NSString, range: NSRange) -> [Span] {
        guard range.length > 0 else { return [] }
        var spans: [Span] = []
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        func each(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            regexes[pattern]?.enumerateMatches(in: ns as String, range: range) { m, _, _ in
                if let m, free(m.range) { body(m) }
            }
        }
        each(#"`([^`\n]+)`"#) { m in
            spans += [Span(range: NSRange(location: m.range.location, length: 1), kind: .mark),
                      Span(range: m.range(at: 1), kind: .code),
                      Span(range: NSRange(location: NSMaxRange(m.range) - 1, length: 1), kind: .mark)]
            taken.append(m.range)
        }
        each(#"\[\[([^\]\n|]+)(\|([^\]\n]+))?\]\]"#) { m in
            let target = ns.substring(with: m.range(at: 1))
            spans.append(Span(range: NSRange(location: m.range.location, length: 2), kind: .mark))
            if m.range(at: 3).location != NSNotFound {
                // `[[target|shown]]`: the target and the bar are marks too.
                spans.append(Span(range: NSRange(location: m.range(at: 1).location, length: m.range(at: 1).length + 1), kind: .mark))
                spans.append(Span(range: m.range(at: 3), kind: .link(target)))
            } else {
                spans.append(Span(range: m.range(at: 1), kind: .link(target)))
            }
            spans.append(Span(range: NSRange(location: NSMaxRange(m.range) - 2, length: 2), kind: .mark))
            taken.append(m.range)
        }
        each(#"(?<!\[)\[([^\]\n]+)\]\(([^)\n]+)\)"#) { m in
            let url = ns.substring(with: m.range(at: 2))
            spans.append(Span(range: NSRange(location: m.range.location, length: 1), kind: .mark))
            spans.append(Span(range: m.range(at: 1), kind: .link(url)))
            spans.append(Span(range: NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))), kind: .mark))
            taken.append(m.range)
        }
        each(#"\*\*([^*\n]+)\*\*"#) { m in
            spans += [Span(range: NSRange(location: m.range.location, length: 2), kind: .mark),
                      Span(range: m.range(at: 1), kind: .bold),
                      Span(range: NSRange(location: NSMaxRange(m.range) - 2, length: 2), kind: .mark)]
            taken.append(m.range)
        }
        each(#"(?<![*\w])[*_]([^*_\n]+)[*_](?![*\w])"#) { m in
            spans += [Span(range: NSRange(location: m.range.location, length: 1), kind: .mark),
                      Span(range: m.range(at: 1), kind: .italic),
                      Span(range: NSRange(location: NSMaxRange(m.range) - 1, length: 1), kind: .mark)]
            taken.append(m.range)
        }
        return spans
    }

    /// The scheme a link carries inside the text view, so a click can tell a
    /// page link from a web link.
    static let pageLinkScheme = "grandline-notebook"
}

// MARK: - The pane

/// The Write pane: a scrolling text view that paints the page as it is
/// typed and reports edits after a short pause, the way Monaco's debounce
/// does.
final class NotebookWriteView: NSView, NSTextViewDelegate {

    static let debounce: TimeInterval = 0.5
    static let bodySize: CGFloat = 14
    /// How long a page has to be before marks are dimmed rather than hidden
    /// off the caret's line - repainting a very long page on every caret move
    /// is not worth the hidden marks.
    static let hideMarksBelow = 200_000

    /// The page's id and its whole text, after a pause or when the pane
    /// loses the keyboard.
    var onEdit: ((String, String) -> Void)?
    /// A `[[wiki-link]]` was clicked: its target as written.
    var onOpenLink: ((String) -> Void)?

    let scroll = NSScrollView()
    let textView = NSTextView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private(set) var pageID: String?
    private var pending: DispatchWorkItem?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var caretLine = NSRange(location: NSNotFound, length: 0)
    private var styling = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: HelmMetrics.s4, height: HelmMetrics.s4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.delegate = self
        textView.setAccessibilityLabel("Page")
        // Gotcha (17): the text view repaints link ranges with its own
        // colours unless told not to. The link colour is ours.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        scroll.documentView = textView
        addSubview(scroll)
        placeholder.stringValue = "Start writing. A # starts a heading, - a list, and [[a page name]] links a page."
        placeholder.font = HelmType.caption()
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4 + 5),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s4),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Show `content` for `id`. The same page with the same words keeps the
    /// caret where it is: a save coming back must not move it.
    func show(id: String, content: String) {
        if id != pageID { flush() }
        if id == pageID, textView.string == content { return }
        pageID = id
        textView.string = content
        restyle()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        textView.insertionPointColor = HelmTheme.nsColor(theme.chromeInkHex)
        // The app's one selection colour, legible in every theme.
        HelmSelection.apply(to: textView, theme: theme)
        placeholder.textColor = HelmTheme.mutedInk(theme)
        restyle()
    }

    /// Reports now whatever a pause would have reported.
    func flush() {
        guard let pending else { return }
        self.pending = nil
        pending.cancel()
        if let pageID { onEdit?(pageID, textView.string) }
    }

    // MARK: Painting

    private var baseFont: NSFont { .systemFont(ofSize: HelmType.scaled(Self.bodySize)) }

    func restyle() {
        guard let storage = textView.textStorage else { return }
        styling = true
        defer { styling = false }
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        let ground = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let link = HelmContrast.legibleOn(fill: ground, preferring: HelmTheme.nsColor(theme.accentHex))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        caretLine = (text as NSString).lineRange(for: NSRange(location: min(textView.selectedRange().location, storage.length), length: 0))
        let hides = storage.length < Self.hideMarksBelow
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: ink, .paragraphStyle: paragraph], range: whole)
        for span in NotebookLiveMarkdown.spans(in: text) where NSMaxRange(span.range) <= storage.length {
            switch span.kind {
            case .heading(let level):
                let sizes: [CGFloat] = [24, 20, 17, 15, 14, 14]
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: HelmType.scaled(sizes[min(level, 6) - 1]), weight: .bold),
                                     range: span.range)
            case .bold:
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: HelmType.scaled(Self.bodySize), weight: .bold), range: span.range)
            case .italic:
                storage.addAttribute(.font, value: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask), range: span.range)
            case .code, .codeBlock:
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: HelmType.scaled(Self.bodySize - 1), weight: .regular),
                                       .backgroundColor: HelmField.fill(theme)], range: span.range)
            case .link(let target):
                let isPage = !target.contains("://")
                let url = isPage
                    ? URL(string: "\(NotebookLiveMarkdown.pageLinkScheme):\(target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target)")
                    : URL(string: target)
                storage.addAttributes([.foregroundColor: link, .underlineStyle: NSUnderlineStyle.single.rawValue], range: span.range)
                if let url { storage.addAttribute(.link, value: url, range: span.range) }
            case .structure:
                storage.addAttribute(.foregroundColor, value: muted, range: span.range)
            case .mark:
                if !hides || NSIntersectionRange(span.range, caretLine).length > 0 || NSLocationInRange(span.range.location, caretLine) {
                    storage.addAttribute(.foregroundColor, value: muted.withAlphaComponent(0.6), range: span.range)
                } else {
                    // Hidden, not removed: the file keeps every character.
                    storage.addAttributes([.foregroundColor: NSColor.clear, .font: NSFont.systemFont(ofSize: 0.1)], range: span.range)
                }
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: baseFont, .foregroundColor: ink, .paragraphStyle: paragraph]
        placeholder.isHidden = !text.isEmpty
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        restyle()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            if let id = self.pageID { self.onEdit?(id, self.textView.string) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    func textDidEndEditing(_ notification: Notification) { flush() }

    /// The marks follow the caret from line to line.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !styling, let storage = textView.textStorage else { return }
        let line = (storage.string as NSString).lineRange(for: NSRange(location: min(textView.selectedRange().location, storage.length), length: 0))
        if line != caretLine { restyle() }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        if url.scheme == NotebookLiveMarkdown.pageLinkScheme {
            let target = String(url.absoluteString.dropFirst(NotebookLiveMarkdown.pageLinkScheme.count + 1))
            onOpenLink?(target.removingPercentEncoding ?? target)
            return true
        }
        // A web link opens in the browser, through the app's one scheme check.
        _ = WebNavigationPolicy.openExternally(url, from: "the Notebook's Write pane")
        return true
    }

    #if FM_SELFTESTS
    var debugHasPendingEdit: Bool { pending != nil }
    /// Whether the character at `index` is drawn (a hidden mark is not).
    func debugIsDrawn(at index: Int) -> Bool {
        guard let storage = textView.textStorage, index < storage.length else { return false }
        let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        return (color?.alphaComponent ?? 0) > 0.05
    }
    func debugFontSize(at index: Int) -> CGFloat {
        (textView.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }
    #endif
}
