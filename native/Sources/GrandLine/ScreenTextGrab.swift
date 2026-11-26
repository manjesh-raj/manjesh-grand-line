// Grand Line - native macOS app.
//
// F-06 of full review 4: grab text from the screen.
//
// Drag a region with the system's own crosshair (`ScreenRegionCapture`, the
// interactive `screencapture -i` that needs no standing Screen Recording
// grant), and the Vision framework reads the words on this Mac. The text
// replaces the region's image on the clipboard, and a small card offers to
// keep it as a note, a task or a snippet. Nothing is uploaded.
//
// **Exactly what was on screen.** Language correction is off, so a command
// keeps its flags and its spelling (`--timeout=120s` is not "corrected"),
// and the lines come back top to bottom in the order they were drawn.
//
// **The lock (GL-09).** The crosshair draws over everything, including the
// lock screen, so a grab started while the app is locked is refused before
// the crosshair appears, and the card says so with an Unlock button. Its own
// surface, `AppLockedSurface.grabText`.
//
// Started from the ⌥Space panel's ⌘7 tile, or from Shift > Grab Text from
// Screen (⌥⌘7).

import AppKit
import Vision

// MARK: - Recognition

enum ScreenTextRecognizer {

    /// The recognised lines of `image`, top to bottom. Empty when there is no
    /// text, never nil, so "nothing found" and a failure read differently at
    /// the call site only through `error`.
    static func recognize(_ image: NSImage) -> (lines: [String], error: String?) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ([], "The capture could not be read as an image.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Keep commands, paths and flags exactly as drawn.
        request.usesLanguageCorrection = false
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ([], "Text recognition failed: \(error.localizedDescription)")
        }
        let observations = request.results ?? []
        return (order(observations.compactMap { observation in
            observation.topCandidates(1).first.map { (text: $0.string, box: observation.boundingBox) }
        }), nil)
    }

    /// Top to bottom, then left to right within a line. Vision's boxes are
    /// normalised with the origin at the bottom left.
    static func order(_ items: [(text: String, box: CGRect)]) -> [String] {
        let sorted = items.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) / 2 { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
        return sorted.map { normaliseDashes($0.text.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    /// Vision reads a command's `--flag` as an em dash and a hyphen
    /// (`—-timeout`), or as an em dash alone. Measured on this Mac with a
    /// monospaced `kubectl ... --timeout=120s`. In a line that already reads as
    /// a command (it carries a ` -x` flag or a path), a dash glued to a word
    /// after a space is put back as `--`. Prose keeps its dashes.
    static func normaliseDashes(_ line: String) -> String {
        var out = line.replacingOccurrences(of: "\u{2014}-", with: "--")
            .replacingOccurrences(of: "-\u{2014}", with: "--")
            .replacingOccurrences(of: "\u{2013}-", with: "--")
        let looksLikeCommand = out.range(of: #"(^|\s)-{1,2}[A-Za-z]"#, options: .regularExpression) != nil
            || out.contains("/")
        if looksLikeCommand {
            out = out.replacingOccurrences(of: #"(^|\s)[\u2014\u2013]([A-Za-z])"#, with: "$1--$2", options: .regularExpression)
        }
        return out
    }

    /// "Copied 3 lines" / "Copied 1 line".
    static func copiedTitle(lineCount: Int) -> String {
        lineCount == 1 ? "Copied 1 line" : "Copied \(lineCount) lines"
    }
}

// MARK: - The flow

final class ScreenTextGrab {

    enum State: Equatable {
        case copied([String])
        case nothingFound
        case locked
        case failed(String)
    }

    /// How the region is captured. Replaced in a self-test.
    var capture: (@escaping (ScreenRegionCapture.Result) -> Void) -> Void = { done in
        ScreenRegionCapture.capture(completion: done)
    }
    /// How the image is read. Replaced in a self-test.
    var recognize: (NSImage) -> (lines: [String], error: String?) = ScreenTextRecognizer.recognize
    var pasteboard: NSPasteboard = .general
    let filer: CaptureFiler
    /// Brings the app forward so the lock screen can be answered.
    var onUnlock: (() -> Void)?
    /// Shows the result. The real one is the floating card; a suite records.
    var present: ((State) -> Void)?

    private(set) var isRunning = false
    private lazy var panel = ScreenTextResultPanel()

    init(filer: CaptureFiler) {
        self.filer = filer
        present = { [weak self] state in self?.showPanel(state) }
    }

    func start() {
        guard !isRunning else { return }
        guard AppLockGate.shared.allows(.grabText) else {
            present?(.locked)
            return
        }
        isRunning = true
        capture { [weak self] result in
            guard let self else { return }
            switch result.outcome {
            case .cancelled:
                self.isRunning = false
            case .failed(let why):
                self.isRunning = false
                self.present?(.failed(why))
            case .captured:
                guard let image = result.image else {
                    self.isRunning = false
                    self.present?(.failed("Nothing usable reached the clipboard."))
                    return
                }
                let read = self.recognize
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = read(image)
                    DispatchQueue.main.async { self.finish(outcome) }
                }
            }
        }
    }

    private func finish(_ outcome: (lines: [String], error: String?)) {
        isRunning = false
        if let error = outcome.error { present?(.failed(error)); return }
        guard !outcome.lines.isEmpty else { present?(.nothingFound); return }
        pasteboard.clearContents()
        pasteboard.setString(outcome.lines.joined(separator: "\n"), forType: .string)
        // The result panel can also be asked again: re-check the lock, which
        // may have engaged while the crosshair was up.
        present?(AppLockGate.shared.allows(.grabText) ? .copied(outcome.lines) : .locked)
    }

    /// Keep the text as a note, a task or a snippet, through the same filer
    /// the ⌥Space panel uses.
    @discardableResult
    func keep(_ lines: [String], as destination: CaptureDestination) -> CaptureFilingOutcome {
        let text = lines.joined(separator: "\n")
        let draft: CaptureDraft
        switch destination {
        case .task:
            draft = CaptureDraft(text: text, title: lines.first ?? "Grabbed text",
                                 body: lines.dropFirst().joined(separator: "\n"), dueDate: nil, dueHasTime: false)
        default:
            draft = CaptureDraft(text: text, title: lines.first ?? "Grabbed text", body: text,
                                 dueDate: nil, dueHasTime: false)
        }
        return filer.file(destination, draft)
    }

    private func showPanel(_ state: State) {
        panel.onKeep = { [weak self] lines, destination in
            guard let self else { return }
            switch self.keep(lines, as: destination) {
            case .filed(let where_), .handedOff(let where_):
                self.panel.showConfirmation(where_.confirmation)
            case .refused(let why):
                self.panel.showConfirmation(why)
            }
        }
        panel.onRetry = { [weak self] in self?.panel.close(); self?.start() }
        panel.onUnlock = { [weak self] in self?.panel.close(); self?.onUnlock?() }
        panel.show(state)
    }
}

// MARK: - The card

/// The floating card the result appears in. Its own panel, because Grand Line
/// is usually not frontmost when a grab finishes; registered with the lock
/// gate so it never stays over the lock screen.
final class ScreenTextResultPanel {

    var onKeep: (([String], CaptureDestination) -> Void)?
    var onRetry: (() -> Void)?
    var onUnlock: (() -> Void)?

    private var window: NSPanel?
    let view = ScreenTextResultView()

    init() {
        view.onKeep = { [weak self] lines, destination in self?.onKeep?(lines, destination) }
        view.onRetry = { [weak self] in self?.onRetry?() }
        view.onUnlock = { [weak self] in self?.onUnlock?() }
        view.onClose = { [weak self] in self?.close() }
        AppLockGate.shared.registerSecondaryWindow(owner: self) { [weak self] in self?.window }
    }

    func show(_ state: ScreenTextGrab.State) {
        view.render(state, theme: ThemeManager.shared.theme)
        let panel = window ?? makeWindow()
        window = panel
        panel.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 80,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    func showConfirmation(_ text: String) {
        view.showConfirmation(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.close() }
    }

    func close() { window?.orderOut(nil) }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .closable],
                            backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        return panel
    }
}

/// The card's content: the mock-up's states 3 and 4.
final class ScreenTextResultView: NSView {

    var onKeep: (([String], CaptureDestination) -> Void)?
    var onRetry: (() -> Void)?
    var onUnlock: (() -> Void)?
    var onClose: (() -> Void)?

    static let width: CGFloat = 640

    private let icon = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let textWell = NSView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let footLabel = NSTextField(wrappingLabelWithString: "")
    private let buttonRow = NSStackView()
    private let stack = NSStackView()
    private var lines: [String] = []
    private var theme = ThemeManager.shared.theme

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        titleLabel.font = HelmType.sectionTitle()
        subtitleLabel.font = HelmType.caption()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.setHuggingPriority(.defaultLow, for: .horizontal)
        let close = HelmButton(title: "", variant: .quiet, size: .small, symbol: "xmark",
                               target: self, action: #selector(closeTapped))
        close.setAccessibilityLabel("Close")
        close.keyEquivalent = "\u{1b}"
        icon.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentHuggingPriority(.required, for: .horizontal)
        let head = NSStackView(views: [icon, titles, close])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.distribution = .fill
        head.spacing = HelmMetrics.s3

        textWell.wantsLayer = true
        textWell.layer?.cornerRadius = HelmMetrics.rControl
        textWell.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .monospacedSystemFont(ofSize: HelmType.scaled(12), weight: .regular)
        textLabel.isSelectable = true
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.preferredMaxLayoutWidth = Self.width - 48 - 24
        textWell.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: textWell.leadingAnchor, constant: 12),
            textLabel.trailingAnchor.constraint(equalTo: textWell.trailingAnchor, constant: -12),
            textLabel.topAnchor.constraint(equalTo: textWell.topAnchor, constant: 10),
            textLabel.bottomAnchor.constraint(equalTo: textWell.bottomAnchor, constant: -10),
        ])

        footLabel.font = HelmType.caption()
        footLabel.preferredMaxLayoutWidth = Self.width - 48

        buttonRow.orientation = .horizontal
        buttonRow.spacing = HelmMetrics.s2

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [head, textWell, buttonRow, footLabel] as [NSView] { stack.addArrangedSubview(view) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            textWell.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
    }

    func render(_ state: ScreenTextGrab.State, theme: HelmTheme) {
        self.theme = theme
        for view in buttonRow.arrangedSubviews { buttonRow.removeArrangedSubview(view); view.removeFromSuperview() }
        textWell.isHidden = true
        footLabel.isHidden = false
        switch state {
        case .copied(let lines):
            self.lines = lines
            icon.configure(symbol: "text.viewfinder", tint: .good)
            titleLabel.stringValue = ScreenTextRecognizer.copiedTitle(lineCount: lines.count)
            subtitleLabel.stringValue = "Recognised on this Mac \u{00B7} nothing uploaded"
            textWell.isHidden = false
            textLabel.stringValue = lines.joined(separator: "\n")
            addButton("New note", symbol: "book.closed", primary: false) { [weak self] in self?.keep(.note) }
            addButton("New task", symbol: "checkmark.circle", primary: false) { [weak self] in self?.keep(.task) }
            addButton("Save as snippet", symbol: "chevron.left.forwardslash.chevron.right", primary: false) { [weak self] in
                self?.keep(.codeSnippet)
            }
            footLabel.stringValue = "On the clipboard. Monospaced text is kept exactly, so a command can be pasted straight into Console."
        case .nothingFound:
            icon.configure(symbol: "text.magnifyingglass", tint: .warn)
            titleLabel.stringValue = "No text found in that area"
            subtitleLabel.stringValue = "Try a larger one. The clipboard was left as it was."
            addButton("Try again", symbol: "viewfinder", primary: true) { [weak self] in self?.onRetry?() }
            footLabel.isHidden = true
        case .locked:
            icon.configure(symbol: "lock.fill", tint: .critical)
            titleLabel.stringValue = "Grand Line is locked"
            subtitleLabel.stringValue = "Unlock to grab text."
            addButton("Unlock", symbol: "lock.open", primary: true) { [weak self] in self?.onUnlock?() }
            footLabel.stringValue = "Grab text checks the app lock like every capture does, because the crosshair draws over the lock screen."
        case .failed(let why):
            icon.configure(symbol: "exclamationmark.triangle", tint: .critical)
            titleLabel.stringValue = "Couldn\u{2019}t grab text"
            subtitleLabel.stringValue = why
            addButton("Try again", symbol: "viewfinder", primary: true) { [weak self] in self?.onRetry?() }
            footLabel.isHidden = true
        }
        applyTheme(theme)
    }

    func showConfirmation(_ text: String) {
        footLabel.isHidden = false
        footLabel.stringValue = text
        for case let button as NSButton in buttonRow.arrangedSubviews { button.isEnabled = false }
    }

    private var actions: [() -> Void] = []

    private func addButton(_ title: String, symbol: String, primary: Bool, run: @escaping () -> Void) {
        actions.append(run)
        let button = HelmButton(title: title, variant: primary ? .primary : .secondary, size: .small, symbol: symbol,
                                target: self, action: #selector(buttonTapped(_:)))
        button.tag = actions.count - 1
        buttonRow.addArrangedSubview(button)
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    private func keep(_ destination: CaptureDestination) { onKeep?(lines, destination) }

    @objc private func closeTapped() { onClose?() }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        icon.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        footLabel.textColor = HelmTheme.mutedInk(theme)
        textLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        textWell.layer?.backgroundColor = HelmField.fill(theme).cgColor
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugText: String { textLabel.stringValue }
    var debugButtons: [NSButton] { buttonRow.arrangedSubviews.compactMap { $0 as? NSButton } }
    #endif
}
