// Manjesh Grand Line - native macOS app.
//
// The Whiteboard's "Draw from text" popover: a few lines of mermaid-lite DSL
// in, real Excalidraw elements on the board out - instantly, with no model.
//
// ## Why a popover on this page, rather than a destination of its own
//
// The captain's own brief left the choice open, with one hard constraint: the
// output has to land on **the** whiteboard, never a second Excalidraw
// instance. That constraint is most of the answer.
//
// A separate destination would have to reach across into `WhiteboardController`
// for its `WKWebView` - a cross-destination dependency pointing the wrong way,
// on a page that is lazily mounted (GL-37), so the tool would have to mount
// another destination before it could do anything. And the captain would type
// on one page and watch the result appear on another, which is a worse version
// of the reviewed mockup rather than a faithful one: that mockup puts the
// canvas *next to* the text, and a popover over the real canvas is the closest
// this app can get to that - the board behind it **is** the middle panel.
//
// So this is a second popover beside "Generate diagram", built to
// `WhiteboardComposerPopover.swift`'s conventions verbatim (same `NSPopover`
// plus plain content controller, same `HelmComposerCard` well, same `⌘⏎`, the
// same live `ThemeManager` observation and forced `popover.appearance` that
// file's header explains, the same `AppLockGate` registration), and it feeds
// the exact same `WhiteboardController.load(elements:append:)` sink. The page
// needed no new bridge call and `whiteboard.js` needed no change at all.
//
// ## What it adds that its AI sibling cannot
//
// Parsing is instant and local, so the popover can answer *while the captain
// types*: a live element count, or a refusal naming the line. Both are
// impossible for a path that has to ask a model and wait.
//
// The preview below the field is a **structure** preview, and deliberately not
// a WYSIWYG one. It cannot be faithful - Excalidraw draws with a hand-drawn
// font at a roughness this process has no renderer for - so pretending would
// be a worse promise than the honest one. It answers the question that
// actually matters before inserting ("is that the shape I meant?") using the
// app's own ink on the app's own field fill, with each component's hue as an
// accent, which is also what keeps it legible in all fourteen themes rather
// than only the light ones Excalidraw's own pastel palette is designed for.

import AppKit

// MARK: - The structure preview

/// A miniature of what will be inserted: boxes, connectors and lifelines,
/// scaled to fit.
///
/// Draws from `DiagramDSL.Diagram`'s own `boxes`/`connectors` rather than
/// re-reading the element dictionaries, so the preview and the skeleton come
/// out of one pass and cannot disagree about where anything is.
final class DiagramPreviewView: NSView {

    private var theme: HelmTheme = ThemeManager.shared.theme
    private var diagram: DiagramDSL.Diagram?

    /// Room for the outermost strokes and for a label that slightly overhangs
    /// its box at small scales.
    private static let inset: CGFloat = 8
    /// Below this a box is a smudge and a label is noise, so labels are
    /// dropped rather than drawn as illegible grey mush.
    private static let labelScaleFloor: CGFloat = 0.34

    override var isFlipped: Bool { true }

    func show(_ diagram: DiagramDSL.Diagram?) {
        self.diagram = diagram
        needsDisplay = true
    }

    #if FM_SELFTESTS
    /// What the *view* was handed, not what the popover parsed. Those are two
    /// different claims, and asserting the second while meaning the first is
    /// how a self-test misses a preview that is never told anything (found by
    /// injecting exactly that).
    var debugBoxCount: Int { diagram?.boxes.count ?? 0 }
    #endif

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        wantsLayer = true
        layer?.backgroundColor = HelmField.fill(theme).cgColor
        layer?.cornerRadius = HelmMetrics.rRow
        layer?.borderWidth = 1
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.6).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let diagram, !diagram.boxes.isEmpty else { return }

        // The content's own bounds, taking connectors in as well as boxes: a
        // sequence lifeline runs well below the last box, and a preview that
        // measured only the boxes would clip it.
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for box in diagram.boxes {
            minX = min(minX, box.x); maxX = max(maxX, box.x + box.width)
            minY = min(minY, box.y); maxY = max(maxY, box.y + box.height)
        }
        for connector in diagram.connectors {
            minX = min(minX, min(connector.x1, connector.x2))
            maxX = max(maxX, max(connector.x1, connector.x2))
            minY = min(minY, min(connector.y1, connector.y2))
            maxY = max(maxY, max(connector.y1, connector.y2))
        }
        let contentWidth = max(1, maxX - minX), contentHeight = max(1, maxY - minY)
        let available = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        guard available.width > 0, available.height > 0 else { return }

        // Never scaled up: a two-box diagram blown up to fill the panel reads
        // as a different drawing from the one that lands on the board.
        let scale = min(1, min(available.width / contentWidth, available.height / contentHeight))
        let drawnWidth = contentWidth * scale, drawnHeight = contentHeight * scale
        let originX = available.minX + (available.width - drawnWidth) / 2
        let originY = available.minY + (available.height - drawnHeight) / 2
        func point(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: originX + (x - minX) * scale, y: originY + (y - minY) * scale)
        }

        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)

        // Connectors first, so a box always sits on top of the line reaching it.
        for connector in diagram.connectors {
            let path = NSBezierPath()
            path.move(to: point(connector.x1, connector.y1))
            path.line(to: point(connector.x2, connector.y2))
            path.lineWidth = connector.isLifeline ? 1 : 1.4
            if connector.dashed || connector.isLifeline {
                path.setLineDash([3, 3], count: 2, phase: 0)
            }
            (connector.isLifeline ? muted : ink).setStroke()
            path.stroke()
            if !connector.isLifeline {
                drawArrowhead(at: point(connector.x2, connector.y2),
                              from: point(connector.x1, connector.y1), color: ink)
            }
        }

        for box in diagram.boxes {
            let origin = point(box.x, box.y)
            let rect = NSRect(x: origin.x, y: origin.y,
                              width: box.width * scale, height: box.height * scale)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            // A component's own hue is an accent here, never the literal fill
            // Excalidraw will paint: those are pastels chosen for a light
            // canvas, and this panel has to read on a dark one too.
            let accent = box.fillHex == "transparent" ? nil : HelmTheme.nsColor(box.strokeHex)
            if let accent {
                accent.withAlphaComponent(0.22).setFill()
                path.fill()
            }
            (accent ?? ink).setStroke()
            path.lineWidth = 1.2
            path.stroke()

            guard scale >= Self.labelScaleFloor else { continue }
            let font = NSFont.systemFont(ofSize: max(7, min(11, 11 * scale)))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
            ]
            let text = box.label as NSString
            let size = text.size(withAttributes: attributes)
            guard size.width <= rect.width - 4 || rect.width > 24 else { continue }
            let clipped = rect.insetBy(dx: 3, dy: 1)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clipped).setClip()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                      withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawArrowhead(at tip: NSPoint, from tail: NSPoint, color: NSColor) {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        let ux = dx / length, uy = dy / length
        let size: CGFloat = 5
        let base = NSPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: base.x - uy * size * 0.5, y: base.y + ux * size * 0.5))
        path.line(to: NSPoint(x: base.x + uy * size * 0.5, y: base.y - ux * size * 0.5))
        path.close()
        color.setFill()
        path.fill()
    }
}

// MARK: - The popover

final class WhiteboardDSLController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let content = WhiteboardDSLViewController()
    private var themeObservation: ThemeObservation?

    /// Set by `WhiteboardController` - the same sink, and the same shape, its
    /// AI sibling's `onGenerated` uses: elements, whether to append, and a
    /// completion carrying a canvas-side refusal so it lands in the popover the
    /// captain is looking at rather than somewhere behind it.
    var onInsert: (([[String: Any]], Bool, @escaping (String?) -> Void) -> Void)?

    override init() {
        super.init()
        // Audit 2 §6.2: a popover is its own window, layered above the lock
        // overlay, so one left open when the lock fires would stay readable and
        // interactive over the lock screen. Weak - there is no unregister.
        AppLockGate.shared.registerLockDismissiblePopover { [weak self] in self?.popover }
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        content.onInsert = { [weak self] elements, append, done in
            // A nil sink has to answer rather than go quiet: the popover shows
            // a spinner until this completion fires, and an unwired canvas
            // would otherwise leave it up forever with nothing to distinguish
            // it from slow work. (Its AI sibling learned this by injection.)
            guard let handler = self?.onInsert else {
                done("the canvas isn't connected")
                return
            }
            handler(elements, append, done)
        }
        content.onSizeChanged = { [weak self] size in self?.popover.contentSize = size }
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            self.popover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
            self.content.applyTheme(theme)
        }
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            content.focusEditor()
        }
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {}

    #if FM_SELFTESTS
    var debugContent: WhiteboardDSLViewController { content }
    #endif
}

final class WhiteboardDSLViewController: NSViewController, NSTextViewDelegate {

    static let width: CGFloat = 420
    static let editorHeight: CGFloat = 96
    static let previewHeight: CGFloat = 132

    private var theme = ThemeManager.shared.theme

    private let iconTile = IconTileView(size: 30, cornerRadius: 8)
    private let titleLabel = NSTextField(labelWithString: "Draw from text")
    private let kicker = NSTextField(labelWithString: "")
    private lazy var modeTabs = HelmSegmentedTabs(
        items: DiagramDSL.Mode.allCases.map { .init(id: $0.rawValue, title: $0.title) },
        selected: DiagramDSL.Mode.flowchart.rawValue,
        size: .compact)
    private let composerCard = HelmComposerCard(cornerRadius: HelmMetrics.rRow)
    private let editor = HelmTextView(height: WhiteboardDSLViewController.editorHeight, monospaced: true)
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "\u{2318}\u{23ce} to insert")
    private let insertButton = HelmButton(title: "Insert", variant: .primary, target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let preview = DiagramPreviewView()
    private let componentsKicker = NSTextField(labelWithString: "")
    private let componentsFlow = ChipFlowView(frame: .zero)
    private var componentButtons: [HelmButton] = []
    private let appendToggle = NSButton(checkboxWithTitle: "Add to what's already on the board", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    var onInsert: (([[String: Any]], Bool, @escaping (String?) -> Void) -> Void)?
    var onSizeChanged: ((NSSize) -> Void)?

    private var mode: DiagramDSL.Mode = .flowchart
    private var parsed: DiagramDSL.Diagram?
    private var isInserting = false
    private var statusIsError = false
    /// Cascades successive palette inserts so clicking one twice does not stack
    /// two boxes in exactly the same place. Popover-local on purpose - see
    /// `DiagramDSL.component(_:index:)` for why it does not read the board.
    private var paletteInserts = 0

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 520))
        root.wantsLayer = true
        view = root

        // Teal, not the AI sibling's violet: violet is this app's "a model did
        // this" hue (the composer popovers, Dictation's clean-up card), and the
        // whole point of this panel is that no model is involved. Teal is the
        // "running systems" hue the Console and the command library already
        // carry, which is what these diagrams are about.
        iconTile.configure(symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: .accent)

        titleLabel.font = HelmType.rowTitle()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let titleRow = NSStackView(views: [iconTile, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        kicker.translatesAutoresizingMaskIntoConstraints = false
        componentsKicker.translatesAutoresizingMaskIntoConstraints = false

        modeTabs.onSelect = { [weak self] id in
            guard let self, let mode = DiagramDSL.Mode(rawValue: id) else { return }
            self.mode = mode
            self.updatePlaceholder()
            self.reparse()
            self.focusEditor()
        }

        editor.textView.delegate = self
        editor.domainHue = RailDestination.whiteboard.domainHue
        composerCard.domainHue = RailDestination.whiteboard.domainHue
        composerCard.senseFocus(on: editor.textView)

        placeholderLabel.font = HelmType.code()
        placeholderLabel.maximumNumberOfLines = 3
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        insertButton.target = self
        insertButton.action = #selector(insertClicked)
        insertButton.controlSize = .small
        // Reaches Insert from anywhere in the popover - `NSWindow`'s
        // `performKeyEquivalent:` runs before the first responder sees the
        // event - so a plain Return stays a newline in a field whose whole
        // content is multi-line by nature.
        insertButton.keyEquivalent = "\r"
        insertButton.keyEquivalentModifierMask = [.command]
        insertButton.setContentHuggingPriority(.required, for: .horizontal)
        insertButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        hintLabel.font = HelmType.caption()
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // "Hint left, action right" needs a flexible spacer plus `.fill` -
        // gotcha (10): a `.gravityAreas` row stretches nothing on its own.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerRow = NSStackView(views: [hintLabel, spacer, spinner, insertButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.distribution = .fill
        footerRow.spacing = HelmMetrics.s2
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        let cardStack = NSStackView(views: [editor, footerRow])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = HelmMetrics.s2
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        composerCard.contentContainer.addSubview(cardStack)
        composerCard.translatesAutoresizingMaskIntoConstraints = false

        preview.translatesAutoresizingMaskIntoConstraints = false

        componentButtons = DiagramComponent.allCases.map { component in
            let button = HelmButton(title: "\(component.emoji) \(component.title)",
                                    variant: .secondary, size: .small)
            button.target = self
            button.action = #selector(componentClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(component.rawValue)
            button.toolTip = "Drop a \(component.title) on the board, or write \(component.keyword)(Name) above"
            return button
        }
        componentsFlow.translatesAutoresizingMaskIntoConstraints = false
        componentsFlow.setChips(componentButtons)

        appendToggle.target = self
        appendToggle.action = #selector(appendToggled)
        appendToggle.font = HelmType.caption()
        appendToggle.translatesAutoresizingMaskIntoConstraints = false
        appendToggle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = HelmType.caption()
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 4
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleRow, kicker, modeTabs, composerCard, preview,
                                        componentsKicker, componentsFlow, appendToggle, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.setCustomSpacing(6, after: titleRow)
        stack.setCustomSpacing(HelmMetrics.s3, after: preview)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: HelmMetrics.s3),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -HelmMetrics.s3),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: HelmMetrics.s3),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -HelmMetrics.s3),

            modeTabs.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            composerCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: Self.previewHeight),
            componentsFlow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            appendToggle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),

            cardStack.leadingAnchor.constraint(equalTo: composerCard.contentContainer.leadingAnchor, constant: HelmMetrics.s2),
            cardStack.trailingAnchor.constraint(equalTo: composerCard.contentContainer.trailingAnchor, constant: -HelmMetrics.s2),
            cardStack.topAnchor.constraint(equalTo: composerCard.contentContainer.topAnchor, constant: HelmMetrics.s2),
            cardStack.bottomAnchor.constraint(equalTo: composerCard.contentContainer.bottomAnchor, constant: -HelmMetrics.s2),
            editor.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor),

            // `NSTextView` has no placeholder, so this is a muted label pinned
            // at the text container's own inset and toggled from
            // `textDidChange` - the arrangement both sibling composers use.
            placeholderLabel.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 10),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: editor.trailingAnchor, constant: -8),
            placeholderLabel.topAnchor.constraint(equalTo: editor.topAnchor, constant: 8),
        ])

        updatePlaceholder()
        reparse()
        applyTheme(theme)
        DispatchQueue.main.async { [weak self] in self?.reportSize() }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        iconTile.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        // The colour goes *into* the attributed string: an `NSTextField`
        // showing an `attributedStringValue` ignores a later `textColor`, which
        // is how its sibling once shipped an invisible kicker.
        kicker.attributedStringValue = NSAttributedString(
            string: "Mermaid-lite \u{00B7} no model, no waiting".uppercased(),
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        componentsKicker.attributedStringValue = NSAttributedString(
            string: "Component library".uppercased(),
            attributes: HelmType.kickerAttributes(color: HelmTheme.mutedInk(theme)))
        placeholderLabel.textColor = HelmTheme.mutedInk(theme)
        hintLabel.textColor = HelmTheme.mutedInk(theme)
        appendToggle.attributedTitle = NSAttributedString(
            string: appendToggle.title,
            attributes: [.font: HelmType.caption(),
                         .foregroundColor: HelmTheme.mutedInk(theme)])
        statusLabel.textColor = statusColor
        composerCard.applyTheme(theme)
        editor.applyTheme(theme)
        modeTabs.applyTheme(theme)
        preview.applyTheme(theme)
    }

    func focusEditor() {
        view.window?.makeFirstResponder(editor.textView)
    }

    // MARK: Live parse

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
        reparse()
    }

    private func updatePlaceholder() {
        placeholderLabel.stringValue = mode.placeholder
        placeholderLabel.isHidden = !editor.string.isEmpty
    }

    /// Re-parses on every keystroke. Cheap enough to be unconditional: this is
    /// a bounded amount of string work over at most `DiagramDSL.maxLines`, and
    /// the whole value of a local parser is that it can answer immediately.
    private func reparse() {
        let text = editor.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsed = nil
            preview.show(nil)
            insertButton.isEnabled = false
            show(status: "", isError: false)
            reportSize()
            return
        }
        switch DiagramDSL.build(text, mode: mode) {
        case .success(let diagram):
            parsed = diagram
            preview.show(diagram)
            insertButton.isEnabled = !isInserting
            show(status: diagram.summary, isError: false)
        case .failure(let error):
            parsed = nil
            preview.show(nil)
            insertButton.isEnabled = false
            show(status: error.description, isError: true)
        }
        reportSize()
    }

    // MARK: Actions

    @objc private func appendToggled() {}

    @objc private func insertClicked() {
        guard !isInserting else { return }
        guard let diagram = parsed else {
            show(status: editor.string.isEmpty
                    ? "Write a line like \"\(mode == .flowchart ? "Client --> Server" : "Client -> Server: request")\" first."
                    : statusLabel.stringValue,
                 isError: true)
            return
        }
        deliver(diagram, append: appendToggle.state == .on,
                success: "Drew \(diagram.summary) on the board. Edit it there like anything else you drew.")
    }

    @objc private func componentClicked(_ sender: HelmButton) {
        guard !isInserting else { return }
        guard let raw = sender.identifier?.rawValue, let component = DiagramComponent(rawValue: raw) else { return }
        let diagram = DiagramDSL.component(component, index: paletteInserts)
        // Always appended, never a replace: clicking a palette button must not
        // wipe a board, whatever the checkbox above happens to say - that
        // checkbox is about the diagram the text describes.
        deliver(diagram, append: true,
                success: "Added a \(component.title). Write \(component.keyword)(Name) above to wire it up.") { [weak self] in
            self?.paletteInserts += 1
        }
    }

    private func deliver(_ diagram: DiagramDSL.Diagram, append: Bool,
                         success: String, onSuccess: (() -> Void)? = nil) {
        guard let onInsert else {
            show(status: "The canvas isn't connected.", isError: true)
            return
        }
        setInserting(true)
        onInsert(diagram.elements, append) { [weak self] failure in
            guard let self else { return }
            self.setInserting(false)
            if let failure {
                self.show(status: failure, isError: true)
                return
            }
            onSuccess?()
            self.show(status: success, isError: false)
        }
    }

    private func setInserting(_ inserting: Bool) {
        isInserting = inserting
        insertButton.isEnabled = !inserting && parsed != nil
        for button in componentButtons { button.isEnabled = !inserting }
        if inserting { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private var statusColor: NSColor {
        statusIsError
            ? HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme),
                                             over: HelmTheme.nsColor(theme.chromeBackgroundHex), theme: theme)
            : HelmTheme.mutedInk(theme)
    }

    private func show(status: String, isError: Bool) {
        statusIsError = isError
        statusLabel.stringValue = status
        statusLabel.isHidden = status.isEmpty
        statusLabel.textColor = statusColor
    }

    private func reportSize() {
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        let size = NSSize(width: Self.width, height: max(fitting.height, 360))
        view.setFrameSize(size)
        onSizeChanged?(size)
    }

    #if FM_SELFTESTS
    var debugMode: DiagramDSL.Mode { mode }
    var debugStatus: String { statusLabel.stringValue }
    var debugStatusIsError: Bool { statusIsError }
    var debugInsertEnabled: Bool { insertButton.isEnabled }
    /// Reads through to the preview view itself rather than to `parsed`: a
    /// `reparse` that computes a diagram and forgets to hand it over renders a
    /// blank panel and would otherwise pass.
    var debugPreviewBoxCount: Int { preview.debugBoxCount }
    var debugComponentButtons: [HelmButton] { componentButtons }
    func debugSetText(_ text: String) {
        _ = view
        editor.string = text
        updatePlaceholder()
        reparse()
    }
    func debugSelectMode(_ mode: DiagramDSL.Mode) {
        _ = view
        modeTabs.select(mode.rawValue)
        self.mode = mode
        updatePlaceholder()
        reparse()
    }
    func debugInsert() { _ = view; insertClicked() }
    func debugSetAppend(_ on: Bool) { _ = view; appendToggle.state = on ? .on : .off }
    #endif
}
