// Grand Line - native macOS app.
//
// C1 of the Console fixes board (`fm/grandline-console-fixes`, Helm 9.4.0): a
// text input drawn as a terminal prompt. The captain asked for the Compose
// box to look like the shell's own input line - a "❯" prompt and a block
// cursor - and picked the same recipe for SRE Lead's composer, so both are
// one component.
//
// The well takes the terminal scheme's colours, not the chrome's: its fill is
// the terminal background, the prompt is the scheme's magenta, typed text its
// green and the cursor its cursor colour, each made legible over that fill.
// So Compose's input and the generated `$ command` under it read as one
// terminal, and the well follows a dark terminal scheme with no work of its
// own. Focus still lights the border and the glow the app's other wells use
// (`HelmInputSurface`), so the well answers a click like every other field.
//
// **The cursor is drawn here, not by AppKit.** The captain's other report on
// these two composers was that clicking into the field never showed the
// cursor until the first character was typed. Both put their placeholder
// label inside the text view, at the text's own origin, where AppKit draws
// the insertion point - and a subview draws over its superview, so the
// placeholder's first glyph covered the caret until typing hid the
// placeholder. The block cursor is the text view's topmost subview, the
// placeholder starts after it, and the system caret is turned off, so the
// cursor shows the moment the field has focus. A window that is not key
// shows a hollow block, the way a terminal does, and Reduce Motion stops the
// blink.

import AppKit

/// The text view inside a `HelmPromptWell`. It reports every change to its
/// text and its selection, including the ones a caller makes by setting
/// `string`, which `NSText.didChangeNotification` does not cover.
final class HelmPromptTextView: NSTextView {
    var onContentChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    override var string: String {
        didSet { onContentChange?() }
    }

    /// A field that stops taking input (SRE Lead during a turn) hides its
    /// cursor at once.
    override var isEditable: Bool {
        didSet { if isEditable != oldValue { onSelectionChange?() } }
    }

    override func didChangeText() {
        super.didChangeText()
        onContentChange?()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        onSelectionChange?()
    }
}

/// A terminal-prompt input well: an optional hint line, a "❯" prompt, a
/// growing text view with a block cursor, and the caller's own footer or
/// trailing control. The caller owns the text view's delegate (its key
/// handling and its submit), and calls `applyTheme(_:)` from its own theme
/// observer, as it did for `HelmComposerCard`. The terminal scheme is
/// observed here, because a caller has no reason to know about it.
final class HelmPromptWell: NSView {
    let textView = HelmPromptTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    let scroll = NSScrollView()

    /// The muted words after the cursor while the field is empty.
    var placeholder: String {
        get { placeholderLabel.stringValue }
        set {
            placeholderLabel.stringValue = newValue
            textView.setAccessibilityPlaceholderValue(newValue)
            refreshCursor()
        }
    }

    /// The page's hue, which a focused well lights with (`HelmComposerCard`'s
    /// rule). `nil` lights with the theme accent.
    var domainHue: HelmDomainHue? {
        didSet { if let lastTheme { applyTheme(lastTheme) } }
    }

    /// The well's corner radius.
    static let cornerRadius: CGFloat = HelmMetrics.rCard
    /// The space around the text inside the well.
    static let edgeInset: CGFloat = 12
    /// The text view's own vertical inset, above and below the text.
    static let textInset: CGFloat = 4
    /// The gap between the prompt and the text.
    static let promptGap: CGFloat = 7
    /// The prompt glyph the shell draws.
    static let promptGlyph = "\u{276F}"

    private let container = NSView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let promptLabel = NSTextField(labelWithString: HelmPromptWell.promptGlyph)
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let cursor = NSView()
    private let minLines: Int
    private let maxLines: Int
    private var scrollHeight: NSLayoutConstraint!
    private var scrollTrailing: NSLayoutConstraint!
    private var scrollBottom: NSLayoutConstraint!
    private var footer: NSView?
    private var trailingAccessory: NSView?

    private var isFocused = false
    private var lastTheme: HelmTheme?
    private var scheme = ThemeManager.shared.terminalScheme
    private var focus: HelmFocusRegistration?
    private var schemeObservation: ThemeObservation?
    private var keyObservers: [NSObjectProtocol] = []
    private var lastWidth: CGFloat = 0

    /// - Parameters:
    ///   - hint: a line above the prompt, drawn like the shell's folder line,
    ///     or `nil` for none.
    ///   - minLines: how many lines tall the empty well is.
    ///   - maxLines: how far it grows before it scrolls.
    init(hint: String? = nil, minLines: Int = 1, maxLines: Int = 5) {
        self.minLines = max(1, minLines)
        self.maxLines = max(self.minLines, maxLines)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        build(hint: hint)
        // Fires at once with the current scheme (`ThemeManager.observe`'s
        // convention), so it registers only after everything is built.
        schemeObservation = ThemeManager.shared.observeTerminalScheme { [weak self] scheme in
            guard let self else { return }
            self.scheme = scheme
            if let theme = self.lastTheme { self.applyTheme(theme) }
        }
        focus = HelmFocusSensing.shared.register(textView) { [weak self] focused in
            self?.setFocused(focused)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let focus { HelmFocusSensing.shared.unregister(focus) }
        if let schemeObservation { ThemeManager.shared.unobserve(schemeObservation) }
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Building

    private var font: NSFont { .monospacedSystemFont(ofSize: HelmType.scaled(13), weight: .regular) }

    private func build(hint: String?) {
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = font
        textView.textContainerInset = NSSize(width: 0, height: Self.textInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        // The block below is the cursor. AppKit's own would draw beside it.
        textView.insertionPointColor = .clear
        textView.onContentChange = { [weak self] in self?.contentChanged() }
        textView.onSelectionChange = { [weak self] in self?.refreshCursor() }

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        placeholderLabel.font = font
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.maximumNumberOfLines = 1
        placeholderLabel.setAccessibilityElement(false)
        // Under the cursor, which is added last so nothing draws over it.
        textView.addSubview(placeholderLabel)
        // Square, like the terminal's own block.
        cursor.wantsLayer = true
        cursor.setAccessibilityElement(false)
        textView.addSubview(cursor)

        promptLabel.font = .monospacedSystemFont(ofSize: HelmType.scaled(13), weight: .bold)
        promptLabel.setAccessibilityElement(false)
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        promptLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.addSubview(promptLabel)

        hintLabel.font = font
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.isHidden = hint == nil
        hintLabel.stringValue = hint.map { "~ \($0)" } ?? ""
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(hintLabel)

        let lineTop = hint == nil
            ? scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.edgeInset - Self.textInset - 1)
            : scroll.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 2 - Self.textInset)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: height(forLines: minLines))
        scrollTrailing = scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -HelmMetrics.s2)
        // A floor, with the exact fit preferred: a trailing control taller
        // than one line sets the well's height instead of fighting the text.
        scrollBottom = container.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.bottomAnchor,
                                                         constant: Self.edgeInset - Self.textInset - 1)
        let fit = container.bottomAnchor.constraint(equalTo: scroll.bottomAnchor,
                                                    constant: Self.edgeInset - Self.textInset - 1)
        fit.priority = NSLayoutConstraint.Priority(250)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            hintLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.edgeInset - 3),
            hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.edgeInset),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Self.edgeInset),
            promptLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.edgeInset),
            promptLabel.firstBaselineAnchor.constraint(equalTo: scroll.topAnchor,
                                                       constant: Self.textInset + ceil(font.ascender)),
            scroll.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: Self.promptGap),
            lineTop, scrollHeight, scrollTrailing, scrollBottom, fit,
        ])
    }

    /// Put `view` under the prompt line, across the well: Compose's target,
    /// shortcut and Generate.
    func setFooter(_ view: NSView) {
        footer?.removeFromSuperview()
        footer = view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: HelmMetrics.s1),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.edgeInset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -HelmMetrics.s2),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -HelmMetrics.s2),
        ])
    }

    /// Put `view` at the trailing end of the prompt line, on the well's
    /// bottom edge: SRE Lead's send button.
    func setTrailingAccessory(_ view: NSView) {
        trailingAccessory?.removeFromSuperview()
        trailingAccessory = view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        scrollTrailing.isActive = false
        scrollTrailing = scroll.trailingAnchor.constraint(equalTo: view.leadingAnchor, constant: -HelmMetrics.s1)
        NSLayoutConstraint.activate([
            scrollTrailing,
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -(HelmMetrics.s1 + 2)),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -(HelmMetrics.s1 + 2)),
            view.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: HelmMetrics.s1 + 2),
        ])
    }

    /// A small key cap, for a shortcut shown beside a button.
    static func keycap(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: HelmType.scaled(10.5), weight: .semibold)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = HelmMetrics.s1
        label.layer?.borderWidth = 1
        label.identifier = NSUserInterfaceItemIdentifier("helm.prompt.keycap")
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// A muted line of footer text that follows the scheme, such as
    /// "runs in Shell". Set its words with `setFootnote(_:on:)`.
    static func footnote() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = HelmType.caption()
        label.lineBreakMode = .byTruncatingTail
        label.identifier = NSUserInterfaceItemIdentifier("helm.prompt.footnote")
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Words for a `footnote()`, with `emphasis` (a tab's name) in semibold.
    func setFootnote(_ label: NSTextField, _ text: String, emphasis: String? = nil) {
        let font = HelmType.caption()
        let words = NSMutableAttributedString(string: text, attributes: [.font: font])
        if let emphasis {
            words.append(NSAttributedString(string: emphasis, attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)]))
        }
        label.attributedStringValue = words
        Self.recolor(label, Self.palette(for: scheme).ghost)
    }

    private static func recolor(_ label: NSTextField, _ color: NSColor) {
        let words = NSMutableAttributedString(attributedString: label.attributedStringValue)
        words.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: words.length))
        label.attributedStringValue = words
    }

    // MARK: Layout

    private var lineHeight: CGFloat {
        textView.layoutManager?.defaultLineHeight(for: font) ?? ceil(font.ascender - font.descender + font.leading)
    }

    private func height(forLines lines: Int) -> CGFloat {
        ceil(lineHeight * CGFloat(lines)) + Self.textInset * 2
    }

    override func layout() {
        super.layout()
        // The text view has to be at least as tall as what shows of it, or
        // a click below its last line lands on nothing.
        let visible = scroll.contentSize.height
        textView.minSize = NSSize(width: 0, height: visible)
        if textView.frame.height < visible { textView.setFrameSize(NSSize(width: textView.frame.width, height: visible)) }
        let width = scroll.contentSize.width
        if abs(width - lastWidth) > 0.5 {
            lastWidth = width
            fitHeight()
        }
        refreshCursor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        HelmFocusSensing.shared.noteWindowChanged(for: textView)
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in self?.refreshCursor()
            })
        }
    }

    private func contentChanged() {
        fitHeight()
        refreshCursor()
    }

    /// Grow or shrink the visible text to its content, between `minLines`
    /// and `maxLines`.
    private func fitHeight() {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer,
              scrollHeight != nil else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let desired = ceil(max(used, lineHeight)) + Self.textInset * 2
        let clamped = min(max(desired, height(forLines: minLines)), height(forLines: maxLines))
        if abs(clamped - scrollHeight.constant) > 0.5 { scrollHeight.constant = clamped }
    }

    // MARK: The cursor

    /// One cell of the monospaced font.
    private var cellWidth: CGFloat {
        ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Where the block sits, in the text view's own (flipped) coordinates,
    /// or `nil` while text is selected.
    var cursorRect: NSRect? {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        let text = textView.string as NSString
        let origin = textView.textContainerOrigin
        let width = cellWidth
        var rect = NSRect(x: 0, y: 0, width: width, height: lineHeight)
        if text.length > 0 {
            layoutManager.ensureLayout(for: textContainer)
            let extra = layoutManager.extraLineFragmentRect
            if selection.location >= text.length, !extra.isEmpty {
                // After a trailing newline: the empty line under the text.
                rect = NSRect(x: extra.minX, y: extra.minY, width: width, height: extra.height)
            } else if selection.location >= text.length {
                let glyph = layoutManager.glyphIndexForCharacter(at: text.length - 1)
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let last = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                rect = NSRect(x: min(last.maxX, max(0, textContainer.size.width - width)), y: line.minY,
                              width: width, height: line.height)
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: selection.location)
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let at = layoutManager.location(forGlyphAt: glyph)
                rect = NSRect(x: line.minX + at.x, y: line.minY, width: width, height: line.height)
            }
        }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Whether the cursor is drawn at all: the field has focus, it takes
    /// input, and nothing is selected.
    var showsCursor: Bool { isFocused && textView.isEditable && cursorRect != nil }

    /// Whether the cursor is the solid, blinking block rather than the
    /// hollow one an unfocused window shows.
    var cursorIsSolid: Bool { textView.window?.isKeyWindow ?? false }

    private func refreshCursor() {
        let empty = textView.string.isEmpty
        let width = cellWidth
        let origin = textView.textContainerOrigin
        let size = placeholderLabel.fittingSize
        // After the block while it shows, so the first ghost letter never
        // sits under the cursor; at the text's own start otherwise.
        let lead = showsCursor ? width + 2 : 0
        placeholderLabel.frame = NSRect(x: origin.x + lead, y: origin.y + 1,
                                        width: min(size.width, max(0, textView.bounds.width - lead)),
                                        height: size.height)
        placeholderLabel.isHidden = !empty || placeholderLabel.stringValue.isEmpty
        guard showsCursor, let rect = cursorRect else {
            cursor.isHidden = true
            cursor.layer?.removeAnimation(forKey: "blink")
            return
        }
        cursor.isHidden = false
        cursor.frame = rect.insetBy(dx: 0, dy: 1)
        let color = HelmTheme.nsColor(scheme.cursorHex)
        if cursorIsSolid {
            cursor.layer?.backgroundColor = color.withAlphaComponent(0.6).cgColor
            cursor.layer?.borderWidth = 0
            restartBlink()
        } else {
            cursor.layer?.backgroundColor = NSColor.clear.cgColor
            cursor.layer?.borderWidth = 1
            cursor.layer?.borderColor = color.cgColor
            cursor.layer?.removeAnimation(forKey: "blink")
        }
    }

    /// The block shows solid after every move and keystroke, then blinks -
    /// unless Reduce Motion is on, when it stays solid.
    private func restartBlink() {
        guard let layer = cursor.layer else { return }
        layer.removeAnimation(forKey: "blink")
        guard !HelmMotion.isReduced else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0]
        blink.keyTimes = [0, 0.5, 0.5, 1]
        blink.duration = 1.06
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + 0.5
        layer.add(blink, forKey: "blink")
    }

    // MARK: Focus and theme

    private func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        if let lastTheme { paintChrome(lastTheme, animated: true) }
        refreshCursor()
    }

    /// The scheme colours a well paints with. Text is the scheme's green and
    /// the prompt its magenta, as the shell's own line draws them, each made
    /// legible over the scheme's background.
    struct Palette {
        let fill: NSColor
        let edge: NSColor
        let text: NSColor
        let prompt: NSColor
        let hint: NSColor
        let ghost: NSColor
    }

    static func palette(for scheme: HelmTheme) -> Palette {
        let fill = HelmTheme.nsColor(scheme.backgroundHex)
        let ink = HelmTheme.nsColor(scheme.foregroundHex)
        func ansi(_ index: Int) -> NSColor {
            scheme.ansiHex.indices.contains(index) ? HelmTheme.nsColor(scheme.ansiHex[index]) : ink
        }
        let edge = fill.blended(withFraction: scheme.mode == .dark ? 0.16 : 0.14,
                                of: scheme.mode == .dark ? .white : .black) ?? ink
        let ghost = ink.blended(withFraction: 0.5, of: fill) ?? ink
        return Palette(fill: fill, edge: edge,
                       text: HelmContrast.legible(ansi(2), over: fill),
                       prompt: HelmContrast.legible(ansi(5), over: fill),
                       hint: HelmContrast.legible(ansi(6), over: fill),
                       ghost: HelmContrast.legible(ghost, over: fill))
    }

    func applyTheme(_ theme: HelmTheme) {
        lastTheme = theme
        paintChrome(theme, animated: false)
        let palette = Self.palette(for: scheme)
        textView.font = font
        textView.textColor = palette.text
        textView.typingAttributes = [.font: font, .foregroundColor: palette.text]
        textView.selectedTextAttributes = [
            .backgroundColor: HelmTheme.nsColor(scheme.selectionHex),
            .foregroundColor: HelmTheme.nsColor(scheme.selectionTextHex),
        ]
        promptLabel.textColor = palette.prompt
        hintLabel.textColor = palette.hint
        placeholderLabel.textColor = palette.ghost
        placeholderLabel.font = font
        for keycap in container.descendants(identifiedBy: "helm.prompt.keycap") {
            guard let label = keycap as? NSTextField else { continue }
            label.textColor = palette.ghost
            label.layer?.borderColor = palette.edge.cgColor
        }
        for note in container.descendants(identifiedBy: "helm.prompt.footnote") {
            guard let label = note as? NSTextField else { continue }
            Self.recolor(label, palette.ghost)
        }
        fitHeight()
        refreshCursor()
    }

    /// The app's focus recipe, then the scheme's fill and resting edge over
    /// it: focus is the accent border and glow, as on every other well.
    private func paintChrome(_ theme: HelmTheme, animated: Bool) {
        HelmInputSurface.apply(chrome: container, shadowHost: self, theme: theme, focused: isFocused,
                               hue: domainHue, surface: .raised, animated: animated)
        let palette = Self.palette(for: scheme)
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.backgroundColor = palette.fill.cgColor
        if !isFocused { container.layer?.borderColor = palette.edge.cgColor }
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius,
                                   cornerHeight: Self.cornerRadius, transform: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius,
                                   cornerHeight: Self.cornerRadius, transform: nil)
    }

    #if FM_SELFTESTS
    var debugCursorView: NSView { cursor }
    var debugPlaceholderLabel: NSTextField { placeholderLabel }
    var debugPromptLabel: NSTextField { promptLabel }
    var debugHintLabel: NSTextField { hintLabel }
    var debugChrome: NSView { container }
    var debugIsFocused: Bool { isFocused }
    #endif
}

private extension NSView {
    /// Every view under this one with `identifier`.
    func descendants(identifiedBy identifier: String) -> [NSView] {
        subviews.flatMap { sub -> [NSView] in
            (sub.identifier?.rawValue == identifier ? [sub] : []) + sub.descendants(identifiedBy: identifier)
        }
    }
}
