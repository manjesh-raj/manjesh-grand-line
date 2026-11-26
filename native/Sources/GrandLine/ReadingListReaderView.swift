// Grand Line - native macOS app.
//
// F-03 of full review 4: the clean reading page - the saved article in a
// serif column, its highlights marked, and a small bar over a selection
// with Highlight, Copy and Send to Notebook. A page whose text could not be
// kept says so instead (`ReadingListReader.swift`).

import AppKit

final class ReadingListReaderView: NSView, NSTextViewDelegate {

    var onHighlight: ((Int, NSRange) -> Void)?
    var onSendToNotebook: ((Int, NSRange, NSView) -> Void)?
    var onTryAgain: (() -> Void)?
    var onOpenOriginal: (() -> Void)?

    static let columnWidth: CGFloat = 680

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    // Gotcha (17): the storage is retained here, or the layout manager's
    // unowned back-reference dangles.
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
    private lazy var textView: NSTextView = {
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        return NSTextView(frame: .zero, textContainer: container)
    }()
    private var textHeight: NSLayoutConstraint?
    private let selectionBar = NSStackView()
    private let noText = NSStackView()
    private let noTextTitle = NSTextField(labelWithString: "Only the link was saved")
    private let noTextBody = NSTextField(wrappingLabelWithString: "")
    /// Each block's start in the text, so a selection maps back to a block.
    private(set) var blockOffsets: [Int] = []
    private(set) var article: ReaderArticle?
    private var theme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = HelmType.caption()
        titleLabel.font = NSFont(name: "New York", size: HelmType.scaled(28)) ?? .systemFont(ofSize: HelmType.scaled(28), weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        document.translatesAutoresizingMaskIntoConstraints = false
        for v in [metaLabel, titleLabel, textView] as [NSView] { document.addSubview(v) }
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        selectionBar.orientation = .horizontal
        selectionBar.spacing = HelmMetrics.s1
        selectionBar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        selectionBar.wantsLayer = true
        selectionBar.isHidden = true
        selectionBar.translatesAutoresizingMaskIntoConstraints = false
        for (title, symbol, action) in [("Highlight", "highlighter", #selector(highlightTapped)),
                                        ("Copy", "doc.on.doc", #selector(copyTapped)),
                                        ("Send to Notebook", "book.closed", #selector(sendTapped))] {
            let button = HelmButton(title: title, variant: .quiet, size: .small, symbol: symbol, target: self, action: action)
            selectionBar.addArrangedSubview(button)
        }
        document.addSubview(selectionBar)

        noTextTitle.font = HelmType.sectionTitle()
        noTextBody.font = HelmType.body()
        noTextBody.stringValue = "This page builds its text with scripts after it loads, or would not show it to Grand Line, "
            + "so there was nothing to keep. Reader mode needs the text. The title and the link are still here."
        noTextBody.preferredMaxLayoutWidth = 460
        let tryAgain = HelmButton(title: "Try again", variant: .secondary, size: .small, symbol: "arrow.clockwise",
                                  target: self, action: #selector(tryAgainTapped))
        let original = HelmButton(title: "Open the original", variant: .primary, size: .small, symbol: "safari",
                                  target: self, action: #selector(originalTapped))
        let buttons = NSStackView(views: [tryAgain, original])
        buttons.spacing = HelmMetrics.s2
        for v in [noTextTitle, noTextBody, buttons] as [NSView] { noText.addArrangedSubview(v) }
        noText.orientation = .vertical
        noText.alignment = .leading
        noText.spacing = HelmMetrics.s3
        noText.isHidden = true
        noText.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noText)

        let height = textView.heightAnchor.constraint(equalToConstant: 100)
        textHeight = height
        let column = titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.columnWidth)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Gotcha (4) and (9): the document pins to the clip view, flipped.
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            metaLabel.topAnchor.constraint(equalTo: document.topAnchor, constant: HelmMetrics.s5),
            metaLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: HelmMetrics.s2),
            titleLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            column,
            textView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: HelmMetrics.s4),
            textView.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            textView.widthAnchor.constraint(equalTo: titleLabel.widthAnchor),
            textView.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor, constant: -2 * HelmMetrics.s5),
            height,
            document.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: HelmMetrics.s6),
            noText.centerXAnchor.constraint(equalTo: centerXAnchor),
            noText.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let preferWide = titleLabel.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        preferWide.priority = HelmDaylightPriority.columnHug
        preferWide.isActive = true
    }

    // MARK: Showing

    func show(_ article: ReaderArticle?, theme: HelmTheme) {
        self.article = article
        self.theme = theme
        selectionBar.isHidden = true
        guard let article, article.state == .saved, !article.blocks.isEmpty else {
            scroll.isHidden = true
            noText.isHidden = false
            applyTheme(theme)
            return
        }
        scroll.isHidden = false
        noText.isHidden = true
        metaLabel.stringValue = article.metaLine
        titleLabel.stringValue = article.title
        textView.textStorage?.setAttributedString(Self.attributed(article, theme: theme, offsets: &blockOffsets))
        applyTheme(theme)
        needsLayout = true
    }

    /// The article as one attributed string: paragraphs in a serif, quotes
    /// indented, code monospaced, and every highlight marked.
    static func attributed(_ article: ReaderArticle, theme: HelmTheme, offsets: inout [Int]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let serif = NSFont(name: "New York", size: HelmType.scaled(17)) ?? NSFont(name: "Georgia", size: HelmType.scaled(17))
            ?? .systemFont(ofSize: HelmType.scaled(17))
        offsets = []
        for (i, block) in article.blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            offsets.append(out.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 14
            var font = serif
            var color = ink
            switch block.kind {
            case .heading: font = .systemFont(ofSize: HelmType.scaled(20), weight: .bold)
            case .quote:
                paragraph.headIndent = 18
                paragraph.firstLineHeadIndent = 18
                color = HelmTheme.mutedInk(theme)
            case .item:
                paragraph.headIndent = 18
                paragraph.firstLineHeadIndent = 4
            case .code: font = .monospacedSystemFont(ofSize: HelmType.scaled(13), weight: .regular)
            case .paragraph: break
            }
            let prefix = block.kind == .item ? "\u{2022}  " : ""
            out.append(NSAttributedString(string: prefix + block.text,
                                          attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
            if !prefix.isEmpty { offsets[offsets.count - 1] += (prefix as NSString).length }
        }
        let mark = HelmTheme.nsColor(HelmTint.warn.hex(in: theme)).withAlphaComponent(theme.mode == .dark ? 0.35 : 0.3)
        for highlight in article.highlights where offsets.indices.contains(highlight.block) {
            let range = NSRange(location: offsets[highlight.block] + highlight.start, length: highlight.length)
            if NSMaxRange(range) <= out.length { out.addAttribute(.backgroundColor, value: mark, range: range) }
        }
        return out
    }

    /// A selection inside the text as (block, range within that block), or
    /// nil when it is empty or crosses blocks.
    func blockRange(for selection: NSRange) -> (block: Int, range: NSRange)? {
        guard selection.length > 0, let article else { return nil }
        guard let block = blockOffsets.lastIndex(where: { $0 <= selection.location }) else { return nil }
        let start = selection.location - blockOffsets[block]
        let blockLength = (article.blocks[block].text as NSString).length
        let length = min(selection.length, blockLength - start)
        guard start >= 0, length > 0 else { return nil }
        return (block, NSRange(location: start, length: length))
    }

    // MARK: Selection

    func textViewDidChangeSelection(_ notification: Notification) {
        let range = textView.selectedRange()
        guard blockRange(for: range) != nil, let rect = selectionRect(range) else {
            selectionBar.isHidden = true
            return
        }
        selectionBar.isHidden = false
        selectionBar.layoutSubtreeIfNeeded()
        let size = selectionBar.fittingSize
        let origin = NSPoint(x: max(0, min(rect.midX - size.width / 2, document.bounds.width - size.width)),
                             y: max(0, rect.minY - size.height - 6))
        selectionBar.frame = NSRect(origin: origin, size: size)
        selectionBar.translatesAutoresizingMaskIntoConstraints = true
    }

    private func selectionRect(_ range: NSRange) -> NSRect? {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        guard !rect.isEmpty else { return nil }
        return textView.convert(rect, to: document)
    }

    var currentSelection: (block: Int, range: NSRange)? { blockRange(for: textView.selectedRange()) }

    @objc private func highlightTapped() {
        guard let picked = currentSelection else { return }
        onHighlight?(picked.block, picked.range)
        selectionBar.isHidden = true
    }

    @objc private func copyTapped() {
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((textView.string as NSString).substring(with: range), forType: .string)
    }

    @objc private func sendTapped() {
        guard let picked = currentSelection else { return }
        onSendToNotebook?(picked.block, picked.range, selectionBar.arrangedSubviews.last ?? selectionBar)
    }

    @objc private func tryAgainTapped() { onTryAgain?() }
    @objc private func originalTapped() { onOpenOriginal?() }

    override func layout() {
        super.layout()
        guard !scroll.isHidden else { return }
        textView.layoutSubtreeIfNeeded()
        container.containerSize = NSSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        if abs((textHeight?.constant ?? 0) - used) > 0.5 { textHeight?.constant = ceil(used) + 4 }
        let width = min(Self.columnWidth, max(200, bounds.width - 2 * HelmMetrics.s5))
        if abs(titleLabel.preferredMaxLayoutWidth - width) > 0.5 { titleLabel.preferredMaxLayoutWidth = width }
    }

    func applyTheme(_ theme: HelmTheme) {
        metaLabel.textColor = HelmTheme.mutedInk(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        noTextTitle.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        noTextBody.textColor = HelmTheme.mutedInk(theme)
        selectionBar.layer?.cornerRadius = HelmMetrics.rControl
        selectionBar.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        selectionBar.layer?.borderWidth = 1
        selectionBar.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        textView.insertionPointColor = HelmTheme.nsColor(theme.chromeInkHex)
    }

    #if FM_SELFTESTS
    func debugSelect(_ range: NSRange) { textView.setSelectedRange(range) }
    var debugText: String { textView.string }
    var debugSelectionBarShown: Bool { !selectionBar.isHidden }
    var debugShowsNoText: Bool { !noText.isHidden }
    func debugHighlightedRanges() -> [NSRange] {
        var out: [NSRange] = []
        let all = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        textView.textStorage?.enumerateAttribute(.backgroundColor, in: all) { value, range, _ in if value != nil { out.append(range) } }
        return out
    }
    func debugPressHighlight() { highlightTapped() }
    #endif
}
