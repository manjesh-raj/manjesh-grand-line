// Grand Line - native macOS app.
//
// The Scratchpad calculator's pad (F9 of full review #3 §8): a text view you
// type in, and a right-aligned column of results beside it, one per line.
//
// ## Why the results are a positioned column rather than a second text view
//
// The reviewed mockup puts results in their own right-aligned, tabular column
// so that twelve lines read as a column of numbers you can scan. The obvious
// build - a second, read-only `NSTextView` holding one result per line - lines
// up only for as long as **no input line ever wraps**, because the two views
// then disagree about how many *visual* lines a logical line takes. The moment
// a captain types a long expression, every result below it is off by one row,
// which is the worst possible failure for a pad whose entire job is telling
// you which answer belongs to which line.
//
// So the results are `NSTextField`s positioned against the input's own layout
// manager: for each logical line, `boundingRect(forGlyphRange:in:)` gives the
// rect that line actually occupies, and the result is placed on its **last**
// visual row. A wrapped line therefore pushes its own result down and nothing
// else moves. `ScratchpadPadViewSelfTest.checkResultsTrackWrappedLines`
// measures exactly that, with a line long enough to wrap at the width it is
// rendered at.
//
// ## Everything else here
//
// The engine is somewhere else entirely (`ScratchpadEngine`), which is what
// keeps this file about geometry and colour. This view knows how to recompute
// (on every keystroke), how to paint itself in a theme, how to copy one line's
// result (⌘↩) or all of them, and nothing about what `2 weeks from Friday`
// means.

import AppKit

/// The input text view. A subclass for one reason: ⌘↩ has to reach the pad
/// while the text view is first responder, and a text view swallows key
/// equivalents it does not handle.
final class ScratchpadTextView: NSTextView {
    var onCommandReturn: (() -> Bool)?
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocusChange?(true) }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { onFocusChange?(false) }
        return gave
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "\r" {
            if onCommandReturn?() == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class ScratchpadPadView: NSView, NSTextViewDelegate {

    /// How wide the result column is. Wide enough for `₹7,79,020/mo` and
    /// `21 Sep, 8:00 AM` at the default size without truncation, which is what
    /// the two longest result shapes the mockup shows actually need.
    private static let resultColumnWidth: CGFloat = 196
    private static let textInset = NSSize(width: 10, height: 10)

    private let scroll = NSScrollView()
    private let document = FlippedView()
    let input = ScratchpadTextView()
    private let resultsColumn = FlippedView()
    private let divider = NSView()
    private var resultLabels: [NSTextField] = []
    private var documentHeight: NSLayoutConstraint!

    private var theme: HelmTheme
    private var fontSize: CGFloat
    private var isFocused = false
    private var results: [ScratchpadEngine.LineResult] = []

    /// The clock and calendar every evaluation runs against. A stored closure
    /// rather than a direct `Date()` so a suite can pin "now" and assert a
    /// real date, exactly as the engine's own suite does.
    var now: () -> Date = Date.init
    var calendar: Calendar = .current

    /// Fired after every edit, with the pad's full text - the store's cue.
    var onTextChanged: ((String) -> Void)?
    /// Fired when something was copied, so the tab can raise its toast.
    var onCopied: ((String) -> Void)?

    var text: String {
        get { input.string }
        set {
            guard input.string != newValue else { return }
            input.string = newValue
            recompute()
        }
    }

    init(theme: HelmTheme, fontSize: CGFloat) {
        self.theme = theme
        self.fontSize = fontSize
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
        build()
        applyTheme(theme)
        applyFontSize(fontSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Construction

    private func build() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        input.isRichText = false
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticSpellingCorrectionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.textContainerInset = Self.textInset
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.textContainer?.widthTracksTextView = true
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false
        input.onCommandReturn = { [weak self] in self?.copyCurrentLineResult() ?? false }
        // The rows are positioned against the input's *laid-out* text, so they
        // have to be re-placed once the input actually has its new width - not
        // when this view's own `layout()` runs, which is earlier in the pass
        // and therefore still measuring the previous width. Measured: without
        // this, a line wide enough to wrap kept its answer on its first visual
        // row and every row below it stayed where the unwrapped layout had put
        // it (`ScratchpadPadViewSelfTest.checkResultsTrackWrappedLines` fails
        // by name with the fix removed).
        input.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(inputFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: input)

        // GL-16: a focusable surface has to show that it has focus. The ring
        // is drawn on the **well** rather than on the text view's own bounds -
        // the same division `HelmSearchField` and `HelmTextView` already use
        // (their editors set `.none` and their wells light up through
        // `HelmInputSurface`), which is why setting `.none` here is the
        // opposite of dropping the treatment.
        input.focusRingType = .none
        input.onFocusChange = { [weak self] focused in self?.setFocused(focused) }

        resultsColumn.wantsLayer = true
        resultsColumn.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(input)
        document.addSubview(divider)
        document.addSubview(resultsColumn)

        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        documentHeight = document.heightAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            // A scroll view's document view pins to the **clip** view, never
            // the scroll view - AGENTS.md gotcha (4).
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            documentHeight,

            input.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            input.topAnchor.constraint(equalTo: document.topAnchor),
            input.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            input.trailingAnchor.constraint(equalTo: divider.leadingAnchor),

            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: document.topAnchor),
            divider.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: resultsColumn.leadingAnchor),

            resultsColumn.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            resultsColumn.topAnchor.constraint(equalTo: document.topAnchor),
            resultsColumn.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            resultsColumn.widthAnchor.constraint(equalToConstant: Self.resultColumnWidth),
        ])
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func inputFrameChanged() {
        layoutResults()
    }

    private func setFocused(_ focused: Bool) {
        isFocused = focused
        HelmInputSurface.apply(chrome: scroll, theme: theme, focused: focused, animated: true)
        // The cell paints over the layer, so both have to move together -
        // `HelmInputSurface.fill`'s own note.
        input.backgroundColor = HelmInputSurface.fill(theme, focused: focused)
    }

    override func layout() {
        super.layout()
        // The result rows are positioned against the input's real laid-out
        // geometry, so they are re-placed after every layout pass - a width
        // change re-wraps the input, which moves every line under the one that
        // re-wrapped.
        layoutResults()
    }

    // MARK: Evaluation

    /// Re-evaluate the whole pad. Called on every keystroke: a pad is at most a
    /// few dozen short lines, and the engine is a hand-written parser over
    /// them, so this is cheaper than the text system work the keystroke
    /// already did.
    func recompute() {
        results = ScratchpadEngine.evaluate(document: input.string, now: now(), calendar: calendar)
        renderResults()
    }

    private func renderResults() {
        while resultLabels.count < results.count {
            let label = NSTextField(labelWithString: "")
            label.alignment = .right
            label.lineBreakMode = .byTruncatingHead
            label.font = resultFont
            label.translatesAutoresizingMaskIntoConstraints = true
            resultsColumn.addSubview(label)
            resultLabels.append(label)
        }
        while resultLabels.count > results.count {
            resultLabels.removeLast().removeFromSuperview()
        }
        for (index, result) in results.enumerated() {
            let label = resultLabels[index]
            label.stringValue = result.display
            label.textColor = result.isError ? errorInk : resultInk
            label.toolTip = result.isError ? result.display : nil
        }
        layoutResults()
    }

    /// Place each result on the **last visual row** of its own logical line.
    /// See this file's header for why that is the rule.
    private func layoutResults() {
        guard let manager = input.layoutManager, let container = input.textContainer else { return }
        manager.ensureLayout(for: container)
        let text = input.string as NSString
        let lineHeight = manager.defaultLineHeight(for: input.font ?? Self.fallbackFont(fontSize))
        let inset = input.textContainerInset.height
        var used = manager.usedRect(for: container).height + inset * 2

        var location = 0
        for label in resultLabels {
            let lineRange = lineRange(in: text, from: &location)
            var y = inset
            if lineRange.length > 0 || lineRange.location < text.length {
                let glyphs = manager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                y = rect.maxY - lineHeight + inset
            } else {
                // The trailing empty line has no glyphs of its own.
                y = manager.extraLineFragmentRect.minY + inset
            }
            label.frame = NSRect(x: 0, y: y.rounded(), width: Self.resultColumnWidth - 14, height: lineHeight.rounded(.up))
        }
        used = max(used, (resultLabels.last?.frame.maxY ?? 0) + inset)
        let viewport = scroll.contentView.bounds.height
        let height = max(used, viewport)
        if abs(documentHeight.constant - height) > 0.5 { documentHeight.constant = height }
    }

    /// The character range of logical line `line`, walking forward from the
    /// previous line's end - the pad is evaluated top to bottom, so the scan
    /// is linear rather than one `lineRange(for:)` per line.
    private func lineRange(in text: NSString, from location: inout Int) -> NSRange {
        guard location <= text.length else { return NSRange(location: text.length, length: 0) }
        let searchRange = NSRange(location: location, length: text.length - location)
        let newline = text.range(of: "\n", options: [], range: searchRange)
        let end = newline.location == NSNotFound ? text.length : newline.location
        let range = NSRange(location: location, length: end - location)
        location = newline.location == NSNotFound ? text.length + 1 : newline.location + 1
        return range
    }

    func textDidChange(_ notification: Notification) {
        recompute()
        onTextChanged?(input.string)
    }

    // MARK: Copy

    /// ⌘↩ - the result of the line the caret is on. Returns false when there
    /// is nothing to copy, so the key equivalent falls through rather than
    /// silently eating the chord.
    @discardableResult
    func copyCurrentLineResult() -> Bool {
        let index = lineIndexOfCaret()
        guard index >= 0, index < results.count else { return false }
        let result = results[index]
        guard !result.display.isEmpty, !result.isError else { return false }
        write(result.display)
        return true
    }

    /// The whole result column, blank lines kept blank so a paste still lines
    /// up with the pad on screen.
    @discardableResult
    func copyAllResults() -> Bool {
        let text = ScratchpadEngine.copyableResults(results)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        write(text)
        return true
    }

    private func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onCopied?(text)
    }

    func lineIndexOfCaret() -> Int {
        let caret = input.selectedRange().location
        let text = input.string as NSString
        guard caret <= text.length else { return -1 }
        return text.substring(to: caret).components(separatedBy: "\n").count - 1
    }

    // MARK: Theme

    private var resultInk: NSColor { theme.isDaylight ? HelmField.ink(theme) : HelmTheme.nsColor(theme.chromeInkHex) }
    private var errorInk: NSColor { HelmTheme.nsColor(theme.ansiHex[1]) }

    private var resultFont: NSFont { Self.fallbackFont(fontSize) }

    private static func fallbackFont(_ size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: max(8, size - 1.5), weight: .regular)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let daylight = theme.isDaylight
        scroll.layer?.masksToBounds = true
        // The well is painted by `HelmInputSurface`, in both states, rather
        // than by a hand-rolled copy here - which is what keeps a pad that has
        // been focused once from resting on a *different* border than a pad
        // that never was. (Measured: a hand-rolled resting border and
        // `HelmInputSurface`'s own differ, and the suite's focus case caught
        // exactly that.) The text view's own background has to resolve through
        // the same call, because AppKit paints it **over** the layer.
        HelmInputSurface.apply(chrome: scroll, theme: theme, focused: isFocused)
        let fill = HelmInputSurface.fill(theme, focused: isFocused)
        input.textColor = resultInk
        input.backgroundColor = fill
        input.insertionPointColor = HelmTheme.nsColor(theme.accentHex)
        // D4: one definition of a text selection, never a hand-rolled alpha -
        // `HelmContrastSelfTest`'s source guard fails the build on a file that
        // creates an `NSTextView` and does not come through here.
        HelmSelection.apply(to: input, theme: theme)

        // The result column sits a step back from the input, the way the
        // mockup draws it - the numbers are the answer, not the surface.
        resultsColumn.layer?.backgroundColor = (daylight ? HelmField.fill(theme) : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.12)).cgColor
        divider.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeLineHex)
            .withAlphaComponent(HelmField.borderAlpha).cgColor
        renderResults()
    }

    func applyFontSize(_ size: CGFloat) {
        fontSize = size
        input.font = Self.fallbackFont(size)
        for label in resultLabels { label.font = resultFont }
        layoutResults()
    }

    #if FM_SELFTESTS
    /// Probe surface for `ScratchpadPadViewSelfTest` - the real laid-out rows
    /// and the real evaluated results, read off the live pad rather than
    /// recomputed by the suite (which would assert nothing).
    var debugResults: [ScratchpadEngine.LineResult] { results }
    var debugResultLabels: [NSTextField] { resultLabels }
    var debugInputLineRects: [NSRect] {
        guard let manager = input.layoutManager, let container = input.textContainer else { return [] }
        manager.ensureLayout(for: container)
        let text = input.string as NSString
        var location = 0
        var rects: [NSRect] = []
        for _ in 0..<max(results.count, 1) {
            let range = lineRange(in: text, from: &location)
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += input.textContainerInset.height
            rects.append(rect)
        }
        return rects
    }
    var debugDocumentHeight: CGFloat { documentHeight.constant }
    #endif
}
