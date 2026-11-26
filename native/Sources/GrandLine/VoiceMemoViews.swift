// Grand Line - native macOS app.
//
// F-05 of full review 4: the voice memo flow and its two surfaces - the
// recording HUD that floats over whatever app is in front, and the strip a
// memo page shows at the top of the Notebook's write pane. The model and the
// recorder are `VoiceMemo.swift`'s.

import AppKit
import AVFoundation

// MARK: - The flow

final class VoiceMemoController {

    enum Destination: Equatable {
        case notebook
        case task(id: String, title: String)
    }

    let hotkey = VoiceMemoHotkey()
    /// Discards a dictation the key started on ⌥ alone before ⇧ arrived.
    var discardDictation: (() -> Void)?
    var notebookStore: () -> NotebookStore? = { GrandLineServices.shared.notebookStore }
    var shiftStore: () -> ShiftStore? = { GrandLineServices.shared.shiftStore }
    var openNotebookPage: ((String) -> Void)?
    /// The microphone's state. Replaced in a self-test.
    var microphone: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var requestMicrophone: (@escaping (Bool) -> Void) -> Void = { done in
        AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { done(granted) } }
    }
    var accessibilityTrusted: () -> Bool = { DictationPermissions.isAccessibilityTrusted }
    var transcribe: (URL, @escaping (Double) -> Void, @escaping (Result<[VoiceMemoSegment], VoiceMemoError>) -> Void) -> Void = {
        VoiceMemoTranscriber.transcribe($0, progress: $1, completion: $2)
    }
    var makeRecorder: () -> VoiceMemoRecorder = { VoiceMemoRecorder() }
    var now: () -> Date = Date.init

    let hud = VoiceMemoHUD()
    private(set) var recorder: VoiceMemoRecorder?
    private var pending: Pending?
    private var tickTimer: Timer?

    /// A recorded memo waiting for its transcript, its destination, or both.
    private struct Pending {
        var id: String
        var url: URL
        var recordedAt: Date
        var duration: TimeInterval
        var segments: [VoiceMemoSegment]?
        var error: VoiceMemoError?
        var destination: Destination?
    }

    /// A memo shorter than this was a slip of the key, and is dropped.
    static let minimumRecordingSeconds: TimeInterval = 0.6

    init() {
        hotkey.onStart = { [weak self] in self?.keyDown() }
        hotkey.onStop = { [weak self] in self?.keyUp() }
        hud.onDestination = { [weak self] destination in self?.choose(destination) }
        hud.onDiscard = { [weak self] in self?.discard() }
        hud.onOpenSettings = { [weak self] url in self?.openPrivacySettings(url) }
        hud.onAllowAccessibility = { _ = DictationPermissions.requestAccessibility() }
    }

    func start() {
        guard !ProcessMode.current.isIsolated else { return }
        hotkey.start()
    }

    // MARK: Recording

    func keyDown() {
        guard AppLockGate.shared.allows(.voiceMemo) else {
            AppLog.lifecycle.info("voice memo key refused - app is locked (GL-09)")
            return
        }
        discardDictation?()
        switch microphone() {
        case .notDetermined:
            requestMicrophone { [weak self] granted in
                self?.hud.show(.message(granted ? "Microphone allowed. Hold Right \u{2325} + \u{21E7} again to record."
                                                : VoiceMemoError.microphoneDenied.message,
                                        settings: granted ? nil : Self.microphoneSettingsURL))
            }
            return
        case .denied, .restricted:
            hud.show(.message(VoiceMemoError.microphoneDenied.message, settings: Self.microphoneSettingsURL))
            return
        default:
            break
        }
        let recorder = makeRecorder()
        do { try recorder.start() } catch {
            hud.show(.message(VoiceMemoError.recorderFailed.message, settings: nil))
            return
        }
        self.recorder = recorder
        hud.show(.recording(elapsed: 0, needsAccessibility: !accessibilityTrusted()))
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            self.hud.show(.recording(elapsed: recorder.elapsed, needsAccessibility: !self.accessibilityTrusted()))
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func keyUp() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard let recorder else { return }
        self.recorder = nil
        let duration = recorder.stop()
        guard duration >= Self.minimumRecordingSeconds else {
            recorder.discard()
            hud.hide()
            return
        }
        begin(id: recorder.id, url: recorder.url, recordedAt: recorder.startedAt, duration: duration, showHUD: true)
    }

    /// Starts transcribing a recorded or dropped memo.
    private func begin(id: String, url: URL, recordedAt: Date, duration: TimeInterval, showHUD: Bool,
                       destination: Destination? = nil) {
        pending = Pending(id: id, url: url, recordedAt: recordedAt, duration: duration, destination: destination)
        if showHUD { hud.show(.saved(duration: duration, progress: 0, tasks: taskChoices())) }
        transcribe(url, { [weak self] value in
            guard let self, self.pending?.id == id, showHUD, self.pending?.destination == nil else { return }
            self.hud.show(.saved(duration: duration, progress: value, tasks: self.taskChoices()))
        }, { [weak self] result in
            guard let self, self.pending?.id == id else { return }
            switch result {
            case .success(let segments): self.pending?.segments = segments
            case .failure(let error): self.pending?.error = error
            }
            self.fileIfReady()
        })
    }

    func choose(_ destination: Destination) {
        pending?.destination = destination
        if pending?.segments == nil, pending?.error == nil {
            hud.show(.message("Transcribing on this Mac\u{2026} it will be filed as soon as it is done.", settings: nil))
        }
        fileIfReady()
    }

    func discard() {
        if let pending { try? FileManager.default.removeItem(at: pending.url) }
        pending = nil
        recorder?.discard()
        recorder = nil
        tickTimer?.invalidate()
        hud.hide()
    }

    /// Files once both the transcript and the destination are in.
    private func fileIfReady() {
        guard let pending, let destination = pending.destination else { return }
        if let error = pending.error {
            // The audio is kept; only the words are missing.
            let page = file(pending, segments: [], to: destination, note: error.message)
            hud.show(.message("Saved without a transcript. \(error.message)", settings: nil))
            if let page { openNotebookPage?(page) }
            self.pending = nil
            return
        }
        guard let segments = pending.segments else { return }
        let page = file(pending, segments: segments, to: destination, note: nil)
        self.pending = nil
        switch destination {
        case .notebook:
            hud.show(.message("Saved to \(PlaceName.of(.notebook)) \u{203A} Memos", settings: nil))
        case .task(_, let title):
            hud.show(.message("Added to \u{201C}\(title)\u{201D} as a voice note", settings: nil))
        }
        hud.hide(after: 1.6)
        if let page { openNotebookPage?(page) }
    }

    /// Writes the memo; answers the page id for a Notebook page.
    @discardableResult
    private func file(_ memo: Pending, segments: [VoiceMemoSegment], to destination: Destination, note: String?) -> String? {
        switch destination {
        case .notebook:
            guard let store = notebookStore() else { return nil }
            let title = VoiceMemoPage.title(recordedAt: memo.recordedAt)
            let size = (try? FileManager.default.attributesOfItem(atPath: memo.url.path)[.size] as? Int64) ?? 0
            let source = "transcribed on this Mac with Whisper \u{00B7} audio \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), kept on this Mac"
            var content = VoiceMemoPage.markdown(title: title,
                                                 marker: .init(id: memo.id, duration: memo.duration),
                                                 segments: segments, source: source)
            if let note { content += "\n_\(note)_\n" }
            return store.createPage(title: title, folder: "memos", content: content).id
        case .task(let id, _):
            guard let store = shiftStore(), var task = store.activeTasks.first(where: { $0.id == id }) else { return nil }
            let line = VoiceMemoPage.taskNote(segments: segments, duration: memo.duration, recordedAt: memo.recordedAt, id: memo.id)
            task.notes = [task.notes, line].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n\n")
            store.updateTask(task)
            return nil
        }
    }

    /// The open tasks a memo can be a note on: due soonest first.
    func taskChoices(limit: Int = 8) -> [(id: String, title: String)] {
        let tasks = shiftStore()?.activeTasks.filter { $0.status != .completed && $0.status != .cancelled } ?? []
        return tasks.sorted { ($0.dueDate ?? "9999") < ($1.dueDate ?? "9999") }.prefix(limit).map { ($0.id, $0.title) }
    }

    // MARK: Dropping a file

    /// An audio file dropped on the Notebook: copied next to the recorded
    /// memos, a page made at once with its progress, and the transcript put
    /// in as it arrives.
    @discardableResult
    func importAudio(_ source: URL, progress: ((Double) -> Void)? = nil) -> String? {
        guard VoiceMemoFiles.audioExtensions.contains(source.pathExtension.lowercased()),
              let store = notebookStore() else { return nil }
        let id = VoiceMemoFiles.newID(now: now())
        let target = VoiceMemoFiles.directory().appendingPathComponent("\(id).\(source.pathExtension.lowercased())")
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            return nil
        }
        let duration = (try? AVAudioPlayer(contentsOf: target))?.duration ?? 0
        let title = source.deletingPathExtension().lastPathComponent
        let page = store.createPage(title: title, folder: "memos",
                                    content: "# \(title)\n\n\(VoiceMemoPage.markerPrefix) id=\(id) duration=\(Int(duration.rounded())) -->\n\n_Transcribing on this Mac\u{2026}_\n")
        transcribe(target, { value in progress?(value) }, { result in
            let source = "\(target.pathExtension) file, transcribed on this Mac with Whisper \u{00B7} kept on this Mac"
            let content: String
            switch result {
            case .success(let segments):
                content = VoiceMemoPage.markdown(title: title, marker: .init(id: id, duration: duration),
                                                 segments: segments, source: source)
            case .failure(let error):
                content = VoiceMemoPage.markdown(title: title, marker: .init(id: id, duration: duration),
                                                 segments: [], source: source) + "\n_\(error.message)_\n"
            }
            store.updatePage(id: page.id, content: content)
            progress?(1)
        })
        return page.id
    }

    /// Opens one of this controller's own System Settings panes, and nothing
    /// else - the HUD hands back the URL it was given.
    func openPrivacySettings(_ url: URL) {
        guard [Self.microphoneSettingsURL, Self.accessibilitySettingsURL].contains(url) else { return }
        NSWorkspace.shared.open(url)
    }

    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}

// MARK: - The HUD

/// The memo's floating panel: recording with a red dot (so it never looks
/// like Dictation's HUD), then "where should it go?", then a confirmation.
final class VoiceMemoHUD {

    enum State: Equatable {
        case recording(elapsed: TimeInterval, needsAccessibility: Bool)
        case saved(duration: TimeInterval, progress: Double, tasks: [TaskChoice])
        case message(String, settings: URL?)

        struct TaskChoice: Equatable { var id: String; var title: String }

        static func saved(duration: TimeInterval, progress: Double, tasks: [(id: String, title: String)]) -> State {
            .saved(duration: duration, progress: progress, tasks: tasks.map { TaskChoice(id: $0.id, title: $0.title) })
        }
    }

    var onDestination: ((VoiceMemoController.Destination) -> Void)?
    var onDiscard: (() -> Void)?
    var onOpenSettings: ((URL) -> Void)?
    var onAllowAccessibility: (() -> Void)?

    let view = VoiceMemoHUDView()
    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?
    private(set) var state: State?

    init() {
        view.onDestination = { [weak self] in self?.onDestination?($0) }
        view.onDiscard = { [weak self] in self?.onDiscard?() }
        view.onOpenSettings = { [weak self] in self?.onOpenSettings?($0) }
        view.onAllowAccessibility = { [weak self] in self?.onAllowAccessibility?() }
        AppLockGate.shared.registerSecondaryWindow(owner: self) { [weak self] in self?.window }
    }

    func show(_ state: State) {
        hideWork?.cancel()
        self.state = state
        view.render(state, theme: ThemeManager.shared.theme)
        guard !ProcessMode.current.isIsolated else { return }
        let panel = window ?? makeWindow()
        window = panel
        panel.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 120, width: size.width, height: size.height),
                           display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
            self?.state = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: VoiceMemoHUDView.width, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        return panel
    }
}

final class VoiceMemoHUDView: NSView {

    static let width: CGFloat = 420

    var onDestination: ((VoiceMemoController.Destination) -> Void)?
    var onDiscard: (() -> Void)?
    var onOpenSettings: ((URL) -> Void)?
    var onAllowAccessibility: (() -> Void)?

    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSView()
    private let progressFill = NSView()
    private var progressWidth: NSLayoutConstraint?
    private let buttons = NSStackView()
    private var actions: [() -> Void] = []
    private var tasks: [VoiceMemoHUD.State.TaskChoice] = []
    private var progressValue: Double = 0

    /// The recording dot is a circle and the progress bar a capsule, so
    /// each radius is half its side.
    static let dotSide: CGFloat = 10
    static let barHeight: CGFloat = 4

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.dSurface
        layer?.masksToBounds = true
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSide / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: HelmType.scaled(14), weight: .semibold)
        detailLabel.font = HelmType.caption()
        detailLabel.preferredMaxLayoutWidth = Self.width - 40
        progress.wantsLayer = true
        progress.layer?.cornerRadius = Self.barHeight / 2
        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = Self.barHeight / 2
        progress.translatesAutoresizingMaskIntoConstraints = false
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progress.addSubview(progressFill)
        let width = progressFill.widthAnchor.constraint(equalToConstant: 0)
        progressWidth = width
        buttons.orientation = .horizontal
        buttons.spacing = HelmMetrics.s2
        let head = NSStackView(views: [dot, titleLabel])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = HelmMetrics.s2
        let stack = NSStackView(views: [head, detailLabel, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSide),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSide),
            progress.heightAnchor.constraint(equalToConstant: Self.barHeight),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            progressFill.leadingAnchor.constraint(equalTo: progress.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progress.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progress.bottomAnchor),
            width,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func render(_ state: VoiceMemoHUD.State, theme: HelmTheme) {
        actions.removeAll()
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        progress.isHidden = true
        dot.isHidden = false
        switch state {
        case .recording(let elapsed, let needsAccessibility):
            titleLabel.stringValue = "Recording memo \u{00B7} \(VoiceMemoPage.clock(elapsed))"
            detailLabel.stringValue = needsAccessibility
                ? "Let go to save. From another app this key needs Accessibility, the same grant Dictation uses."
                : "Let go to save."
            if needsAccessibility { addButton("Allow Accessibility\u{2026}", "lock.open", .secondary) { [weak self] in self?.onAllowAccessibility?() } }
            addButton("Discard", "xmark", .quiet) { [weak self] in self?.onDiscard?() }
        case .saved(let duration, let value, let choices):
            tasks = choices
            dot.isHidden = true
            titleLabel.stringValue = "Memo saved \u{00B7} \(VoiceMemoPage.clock(duration))"
            detailLabel.stringValue = value >= 1 ? "Transcribed on this Mac. Where should it go?"
                : "Where should it go? Transcribing on this Mac\u{2026}"
            progress.isHidden = value >= 1
            progressValue = value
            addButton("A new Notebook page", "book.closed", .primary) { [weak self] in self?.onDestination?(.notebook) }
            if !choices.isEmpty {
                addButton("A note on a task\u{2026}", "checkmark.circle", .secondary) { [weak self] in self?.showTaskMenu() }
            }
            addButton("Discard", "trash", .quiet) { [weak self] in self?.onDiscard?() }
        case .message(let text, let settings):
            dot.isHidden = true
            titleLabel.stringValue = "Voice memo"
            detailLabel.stringValue = text
            if let settings {
                addButton("Open System Settings", "gearshape", .secondary) { [weak self] in self?.onOpenSettings?(settings) }
            }
        }
        applyTheme(theme)
        needsLayout = true
    }

    private func showTaskMenu() {
        let menu = NSMenu()
        for (index, task) in tasks.enumerated() {
            let item = NSMenuItem(title: task.title, action: #selector(taskPicked(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        guard let anchor = buttons.arrangedSubviews.dropFirst().first else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func taskPicked(_ item: NSMenuItem) {
        guard tasks.indices.contains(item.tag) else { return }
        onDestination?(.task(id: tasks[item.tag].id, title: tasks[item.tag].title))
    }

    private func addButton(_ title: String, _ symbol: String, _ variant: HelmButton.Variant, run: @escaping () -> Void) {
        actions.append(run)
        let button = HelmButton(title: title, variant: variant, size: .small, symbol: symbol,
                                target: self, action: #selector(tapped(_:)))
        button.tag = actions.count - 1
        buttons.addArrangedSubview(button)
    }

    @objc private func tapped(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    override func layout() {
        super.layout()
        progressWidth?.constant = progress.bounds.width * CGFloat(min(1, max(0, progressValue)))
    }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(HelmCard.dividerAlpha).cgColor
        dot.layer?.backgroundColor = HelmTheme.nsColor(HelmTint.critical.hex(in: theme)).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        detailLabel.textColor = HelmTheme.mutedInk(theme)
        progress.layer?.backgroundColor = HelmField.fill(theme).cgColor
        progressFill.layer?.backgroundColor = HelmTheme.nsColor(theme.heroAccentHex).cgColor
    }

    #if FM_SELFTESTS
    var debugTitle: String { titleLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugButtonTitles: [String] { buttons.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    func debugPress(_ title: String) {
        (buttons.arrangedSubviews.first { ($0 as? NSButton)?.title == title } as? NSButton)?.performClick(nil)
    }
    #endif
}

// MARK: - The Notebook strip

/// The top of a memo page in the Notebook's write pane: play, the position,
/// a scrubber, where the audio is, and "Make a task from a line".
final class VoiceMemoStrip: NSView {

    var onMakeTask: ((String) -> Void)?
    var onCopyText: (() -> Void)?

    private let playButton = HelmButton(title: "", variant: .primary, size: .small, symbol: "play.fill")
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let kicker = NSTextField(labelWithString: "VOICE MEMO")
    private let footLabel = NSTextField(wrappingLabelWithString: "")
    private let taskButton = HelmButton(title: "Make a task from a line", variant: .secondary, size: .small, symbol: "checkmark.circle")
    private let copyButton = HelmButton(title: "Copy text", variant: .quiet, size: .small, symbol: "doc.on.doc")
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var lines: [String] = []
    private(set) var marker: VoiceMemoPage.Marker?
    private(set) var audioFound = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        kicker.font = HelmType.chip()
        timeLabel.font = .monospacedDigitSystemFont(ofSize: HelmType.scaled(12), weight: .medium)
        footLabel.font = HelmType.caption()
        playButton.target = self
        playButton.action = #selector(playTapped)
        playButton.setAccessibilityLabel("Play the memo")
        slider.target = self
        slider.action = #selector(scrubbed)
        slider.controlSize = .small
        taskButton.target = self
        taskButton.action = #selector(taskTapped)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        for view in [playButton, timeLabel, taskButton, copyButton] as [NSView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [playButton, timeLabel, slider, taskButton, copyButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s2
        let stack = NSStackView(views: [kicker, row, footLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s1
        stack.edgeInsets = NSEdgeInsets(top: HelmMetrics.s3, left: HelmMetrics.s3, bottom: HelmMetrics.s3, right: HelmMetrics.s3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * HelmMetrics.s3),
        ])
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Shows the strip for `content`, or hides it for an ordinary page.
    func show(content: String) {
        stopPlayback()
        marker = VoiceMemoPage.marker(in: content)
        isHidden = marker == nil
        guard let marker else { return }
        lines = VoiceMemoPage.transcriptLines(in: content)
        let file = ([VoiceMemoFiles.url(for: marker.id)] + VoiceMemoFiles.audioExtensions.map {
            VoiceMemoFiles.directory().appendingPathComponent("\(marker.id).\($0)")
        }).first { FileManager.default.fileExists(atPath: $0.path) }
        audioFound = file != nil
        player = file.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        playButton.isEnabled = player != nil
        slider.isEnabled = player != nil
        taskButton.isEnabled = !lines.isEmpty
        copyButton.isEnabled = !lines.isEmpty
        let duration = player?.duration ?? marker.duration
        timeLabel.stringValue = "0:00 / \(VoiceMemoPage.clock(duration))"
        slider.doubleValue = 0
        footLabel.stringValue = audioFound
            ? "Audio kept on this Mac, not synced. Hold Right \u{2325} + \u{21E7} anywhere to record another."
            : "The audio is on the Mac that recorded it. The transcript is here."
    }

    @objc private func playTapped() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            playButton.symbolName = "play.fill"
            timer?.invalidate()
        } else {
            player.play()
            playButton.symbolName = "pause.fill"
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func tick() {
        guard let player else { return }
        timeLabel.stringValue = "\(VoiceMemoPage.clock(player.currentTime)) / \(VoiceMemoPage.clock(player.duration))"
        slider.doubleValue = player.duration > 0 ? player.currentTime / player.duration : 0
        if !player.isPlaying { stopPlayback() }
    }

    @objc private func scrubbed() {
        guard let player else { return }
        player.currentTime = slider.doubleValue * player.duration
        tick()
    }

    func stopPlayback() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        playButton.symbolName = "play.fill"
    }

    @objc private func taskTapped() {
        let menu = NSMenu()
        for (index, line) in lines.enumerated() {
            let title = line.count > 70 ? String(line.prefix(69)) + "\u{2026}" : line
            let item = NSMenuItem(title: title, action: #selector(linePicked(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: taskButton.bounds.height + 4), in: taskButton)
    }

    @objc private func linePicked(_ item: NSMenuItem) {
        guard lines.indices.contains(item.tag) else { return }
        onMakeTask?(lines[item.tag])
    }

    @objc private func copyTapped() { onCopyText?() }

    var transcriptText: String { lines.joined(separator: "\n") }

    func applyTheme(_ theme: HelmTheme) {
        layer?.cornerRadius = HelmMetrics.rCard
        layer?.backgroundColor = HelmField.fill(theme).cgColor
        let ground = HelmField.fill(theme)
        kicker.textColor = HelmContrast.legibleTintedText(tintHex: HelmTint.critical.hex(in: theme), over: ground, theme: theme)
        timeLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        footLabel.textColor = HelmTheme.mutedInk(theme)
    }

    #if FM_SELFTESTS
    var debugTime: String { timeLabel.stringValue }
    var debugFoot: String { footLabel.stringValue }
    var debugPlayEnabled: Bool { playButton.isEnabled }
    #endif
}
