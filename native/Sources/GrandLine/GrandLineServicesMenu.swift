// Grand Line - native macOS app.
//
// F-10 of full review 4: send to Grand Line from any app, through the
// macOS Services menu. Select text or a link anywhere, then Services:
//
//   - "Send to Grand Line…" opens a small filing panel, prefilled from the
//     selection (the note) and the page (the link), filing a task, a note, a
//     reading-list link or a sticky.
//   - "New Grand Line Task from Selection" files a task straight away.
//   - "Add Page to Grand Line Reading List" saves the link straight away.
//
// Every write goes through `CaptureFiler`, the same one the ⌥Space panel
// uses, so a Service files exactly what capture would. The result is a macOS
// notification banner, because Grand Line is in the background when this
// happens.
//
// The Services item works with today's self-signed build: it needs only the
// `NSServices` entry `build_native_app.sh` writes into Info.plist. The
// share-sheet extension (phase 2) needs a team-signed app (S-01, the open
// Developer ID item) and is deliberately not built.
//
// **The lock (GL-09).** A Service runs while another app is frontmost and
// writes the captain's data, so it consults `AppLockGate` through its own
// surface, `.servicesMenu`. While locked the panel says so and saves
// nothing; the two direct items refuse with a banner.

import AppKit
import UserNotifications

// MARK: - What arrived

struct ServiceSelection: Equatable {
    var text: String
    var url: String?
    var sourceApp: String?

    /// Reads a Services pasteboard: plain text, a URL, or both. A selection
    /// that is itself a single URL becomes the link.
    static func read(_ pasteboard: NSPasteboard, sourceApp: String?) -> ServiceSelection? {
        let text = (pasteboard.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var url = pasteboard.string(forType: .URL)
            ?? (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
        if url == nil, let single = URL(string: text), single.scheme?.hasPrefix("http") == true, !text.contains(" ") {
            url = single.absoluteString
        }
        guard !text.isEmpty || url != nil else { return nil }
        return ServiceSelection(text: text == url ? "" : text, url: url, sourceApp: sourceApp)
    }

    /// The title the panel starts with: the selection's first line, shortened.
    var suggestedTitle: String {
        let first = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if first.isEmpty { return url.flatMap { URL(string: $0)?.host } ?? "From \(sourceApp ?? "another app")" }
        return first.count > 80 ? String(first.prefix(79)) + "\u{2026}" : first
    }
}

enum ServiceFiling {

    /// The four kinds the panel offers, and the capture destination each is.
    enum Kind: String, CaseIterable {
        case task, note, link, sticky
        var title: String {
            switch self {
            case .task: return "Task"
            case .note: return "Note"
            case .link: return "Reading list"
            case .sticky: return "Sticky"
            }
        }
        var destination: CaptureDestination {
            switch self {
            case .task: return .task
            case .note: return .note
            case .link: return .link
            case .sticky: return .sticky
            }
        }
        /// "Tasks", "Notebook", ... for the banner.
        var placeName: String {
            switch self {
            case .task: return "Tasks"
            case .note: return "Notebook"
            case .link: return "Reading list"
            case .sticky: return "Sticky Board"
            }
        }
    }

    /// The draft each kind files. The selection becomes the body (quoted for
    /// a note), the page becomes the link, and the title is the panel's.
    static func draft(_ kind: Kind, title: String, selection: ServiceSelection) -> CaptureDraft {
        let source = selection.url.map { "\n\n\($0)" } ?? ""
        switch kind {
        case .link:
            let link = selection.url ?? selection.text
            return CaptureDraft(text: link, title: title, body: link, dueDate: nil, dueHasTime: false)
        case .note:
            let quote = selection.text.isEmpty ? "" : selection.text.components(separatedBy: "\n").map { "> \($0)" }
                .joined(separator: "\n")
            let from = selection.url.map { "\n\nFrom \($0)" } ?? (selection.sourceApp.map { "\n\nFrom \($0)" } ?? "")
            let body = quote + from
            return CaptureDraft(text: "# \(title)\n\n\(body)", title: title, body: body, dueDate: nil, dueHasTime: false)
        case .task, .sticky:
            let body = selection.text + source
            return CaptureDraft(text: title + "\n" + body, title: title, body: body, dueDate: nil, dueHasTime: false)
        }
    }

    /// "Added to Tasks: Try the HPA behavior field" / its subtitle.
    static func banner(kind: Kind, title: String, sourceApp: String?) -> (title: String, body: String) {
        ("Added to \(kind.placeName): \(title)", sourceApp.map { "From \($0)" } ?? "From the Services menu")
    }
}

// MARK: - The provider

/// The object `NSApp.servicesProvider` points at. Each `@objc` method name is
/// an `NSMessage` in Info.plist's `NSServices`.
final class GrandLineServicesProvider: NSObject {

    let filer: CaptureFiler
    private lazy var panel = SendToGrandLinePanel()
    /// Posts the banner. A suite records instead.
    var notify: (String, String) -> Void = GrandLineServicesProvider.postBanner
    var onUnlock: (() -> Void)?
    var frontmostAppName: () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName }

    init(filer: CaptureFiler) {
        self.filer = filer
        super.init()
    }

    /// Info.plist's message names, kept here so a guard can compare them.
    static let messages = ["sendToGrandLine", "newTaskFromSelection", "addPageToReadingList"]

    @objc func sendToGrandLine(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let selection = ServiceSelection.read(pasteboard, sourceApp: frontmostAppName()) else {
            error?.pointee = "Nothing was selected." as NSString
            return
        }
        presentPanel(selection)
    }

    @objc func newTaskFromSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let selection = ServiceSelection.read(pasteboard, sourceApp: frontmostAppName()) else {
            error?.pointee = "Nothing was selected." as NSString
            return
        }
        file(.task, title: selection.suggestedTitle, selection: selection)
    }

    @objc func addPageToReadingList(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let selection = ServiceSelection.read(pasteboard, sourceApp: frontmostAppName()) else {
            error?.pointee = "Nothing was selected." as NSString
            return
        }
        file(.link, title: selection.suggestedTitle, selection: selection)
    }

    func presentPanel(_ selection: ServiceSelection) {
        panel.onSave = { [weak self] kind, title in
            guard let self else { return false }
            return self.file(kind, title: title, selection: selection)
        }
        panel.onUnlock = { [weak self] in self?.onUnlock?() }
        panel.present(selection, locked: !AppLockGate.shared.allows(.servicesMenu))
    }

    /// Files through the capture filer and posts the banner. Refuses while
    /// locked (GL-09), saying so.
    @discardableResult
    func file(_ kind: ServiceFiling.Kind, title: String, selection: ServiceSelection) -> Bool {
        guard AppLockGate.shared.allows(.servicesMenu) else {
            notify("Grand Line is locked", "Unlock to file this. Nothing was saved yet.")
            return false
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = ServiceFiling.draft(kind, title: trimmed.isEmpty ? selection.suggestedTitle : trimmed, selection: selection)
        switch filer.file(kind.destination, draft) {
        case .filed, .handedOff:
            let banner = ServiceFiling.banner(kind: kind, title: draft.title, sourceApp: selection.sourceApp)
            notify(banner.title, banner.body)
            return true
        case .refused(let why):
            notify("Not saved", why)
            return false
        }
    }

    /// A macOS banner. The bare debug binary has no bundle and would raise in
    /// `UNUserNotificationCenter` (the same guard `UpdatesController` has).
    static func postBanner(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: "fm.services.\(UUID().uuidString)", content: content, trigger: nil))
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional: post()
            case .notDetermined: center.requestAuthorization(options: [.alert]) { granted, _ in if granted { post() } }
            default: break
            }
        }
    }
}

// MARK: - The panel

/// "Send to Grand Line from Safari": the four kinds, an editable title, the
/// quote and the link. Return saves without bringing Grand Line forward; Esc
/// closes. A floating, non-activating panel registered with the lock gate.
final class SendToGrandLinePanel: NSObject, NSWindowDelegate {

    var onSave: ((ServiceFiling.Kind, String) -> Bool)?
    var onUnlock: (() -> Void)?

    private var window: NSPanel?
    let view = SendToGrandLineView()

    override init() {
        super.init()
        view.onSave = { [weak self] kind, title in
            guard let self else { return }
            if self.onSave?(kind, title) == true { self.close() }
        }
        view.onCancel = { [weak self] in self?.close() }
        view.onUnlock = { [weak self] in self?.close(); self?.onUnlock?() }
        AppLockGate.shared.registerSecondaryWindow(owner: self) { [weak self] in self?.window }
    }

    func present(_ selection: ServiceSelection, locked: Bool) {
        view.configure(selection, locked: locked, theme: ThemeManager.shared.theme)
        let panel = window ?? makeWindow()
        window = panel
        panel.appearance = NSAppearance(named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY, width: size.width, height: size.height),
                           display: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        view.focusTitle()
    }

    func close() { window?.orderOut(nil) }

    private func makeWindow() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: SendToGrandLineView.width, height: 260),
                                 styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
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

    /// A non-activating panel still has to take typing in its title field.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

final class SendToGrandLineView: NSView, NSTextFieldDelegate {

    static let width: CGFloat = 520

    var onSave: ((ServiceFiling.Kind, String) -> Void)?
    var onCancel: (() -> Void)?
    var onUnlock: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let kinds = HelmSegmentedTabs(items: ServiceFiling.Kind.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                          selected: ServiceFiling.Kind.task.rawValue, size: .compact)
    private let titleField = HelmTextField(placeholder: "Title")
    private let quoteLabel = NSTextField(wrappingLabelWithString: "")
    private let linkLabel = NSTextField(labelWithString: "")
    private let footLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = HelmButton(title: "Cancel", variant: .quiet, size: .small)
    private let saveButton = HelmButton(title: "Save", variant: .primary, size: .small, symbol: "return")
    private let lockedStack = NSStackView()
    private let formStack = NSStackView()
    private var kind: ServiceFiling.Kind = .task
    private var isLocked = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 260))
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        titleLabel.font = HelmType.sectionTitle()
        kinds.onSelect = { [weak self] id in self?.kind = ServiceFiling.Kind(rawValue: id) ?? .task }
        titleField.target = self
        titleField.action = #selector(saveTapped)
        quoteLabel.font = HelmType.body()
        quoteLabel.preferredMaxLayoutWidth = Self.width - 64
        quoteLabel.maximumNumberOfLines = 3
        linkLabel.font = HelmType.caption()
        linkLabel.lineBreakMode = .byTruncatingMiddle
        footLabel.font = HelmType.caption()
        footLabel.preferredMaxLayoutWidth = Self.width - 48
        footLabel.stringValue = "The selection becomes the note, the page becomes the link, and the title is editable. "
            + "Return saves into Grand Line without bringing it forward."
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        buttons.spacing = HelmMetrics.s2

        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = HelmMetrics.s3
        for v in [kinds, titleField, quoteLabel, linkLabel, buttons, footLabel] as [NSView] { formStack.addArrangedSubview(v) }

        lockedStack.orientation = .vertical
        lockedStack.alignment = .leading
        lockedStack.spacing = HelmMetrics.s2
        let lockedTitle = NSTextField(labelWithString: "Grand Line is locked")
        lockedTitle.font = HelmType.body()
        let lockedBody = NSTextField(labelWithString: "Unlock to file this. Nothing was saved yet.")
        lockedBody.font = HelmType.caption()
        let unlock = HelmButton(title: "Unlock", variant: .primary, size: .small, symbol: "lock.open",
                                target: self, action: #selector(unlockTapped))
        for v in [lockedTitle, lockedBody, unlock] as [NSView] { lockedStack.addArrangedSubview(v) }
        lockedTexts = [lockedTitle, lockedBody]

        let stack = NSStackView(views: [titleLabel, formStack, lockedStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            formStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            titleField.widthAnchor.constraint(equalTo: formStack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: formStack.widthAnchor),
        ])
    }

    private var lockedTexts: [NSTextField] = []

    func configure(_ selection: ServiceSelection, locked: Bool, theme: HelmTheme) {
        isLocked = locked
        titleLabel.stringValue = "Send to Grand Line" + (selection.sourceApp.map { " from \($0)" } ?? "")
        titleField.stringValue = selection.suggestedTitle
        quoteLabel.stringValue = selection.text.isEmpty ? "" : "\u{201C}\(selection.text)\u{201D}"
        quoteLabel.isHidden = selection.text.isEmpty
        linkLabel.stringValue = selection.url ?? ""
        linkLabel.isHidden = selection.url == nil
        // A link with no text reads best as a reading-list item.
        kind = selection.text.isEmpty && selection.url != nil ? .link : .task
        kinds.select(kind.rawValue)
        formStack.isHidden = locked
        lockedStack.isHidden = !locked
        applyTheme(theme)
    }

    func focusTitle() {
        guard !isLocked else { return }
        window?.makeFirstResponder(titleField)
    }

    @objc private func saveTapped() {
        guard !isLocked else { return }
        onSave?(kind, titleField.stringValue)
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func unlockTapped() { onUnlock?() }

    func applyTheme(_ theme: HelmTheme) {
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        quoteLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        linkLabel.textColor = HelmTheme.mutedInk(theme)
        footLabel.textColor = HelmTheme.mutedInk(theme)
        lockedTexts.first?.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        lockedTexts.last?.textColor = HelmTheme.mutedInk(theme)
        kinds.applyTheme(theme)
        titleField.applyTheme(theme)
    }

    #if FM_SELFTESTS
    var debugKind: ServiceFiling.Kind { kind }
    var debugTitleField: HelmTextField { titleField }
    var debugSaveButton: HelmButton { saveButton }
    var debugIsShowingLocked: Bool { !lockedStack.isHidden }
    func debugSelect(_ kind: ServiceFiling.Kind) { kinds.select(kind.rawValue); self.kind = kind }
    #endif
}
