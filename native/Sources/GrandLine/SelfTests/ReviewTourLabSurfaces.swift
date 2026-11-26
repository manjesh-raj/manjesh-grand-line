// Grand Line - native macOS app.
//
// Full review 4, T-03: the review lab's verbs for the surfaces restyled in
// Helm 10.3.0 and 10.4.0, which the lab could not render. Each ship round
// had written a throwaway probe for them and deleted it, so a review could
// not produce a real image of them from the current build.
//
// Every verb builds the surface's real controller or view, puts it in an
// `OffScreenProbe` window (never on a display), and writes `<name>.png` into
// the tour's directory. The last word of each is the PNG's name:
//
//     ux lock <name> [lit]                the lock screen, dark or lit
//     ux chest <name> [open]              the Secrets gate, shut or open
//     ux palette <name> [query...]        the ⌘K palette with a query typed
//     ux capture <name> [text...]         the ⌥Space capture panel
//     ux tasksheet <name> [title...]      the task editor, for that task or new
//     ux toast <done|warning|failure> <name>
//     ux hud <listening|transcribing|cleaningUp|success|copiedOnly|failure> <name>
//     ux menubar <name>                   the menu-bar popover
//     ux clipboard <name>                 the ⌘⇧V clipboard history, dummy entries
//     ux confirm <name> [destructive]     a HelmConfirm dialog
//
// Nothing here is ordered onto a screen: the dictation HUD is painted
// through `debugPaintWithoutShowing`, and the palette and capture panels
// are read from their own windows without `present()`. GL-27: debug builds
// only.

#if FM_SELFTESTS

import AppKit

extension ReviewTourLab {

    /// `ux <surface> ...` for the surfaces above, or nil when `parts` names
    /// none of them.
    static func applySurfaceUX(_ parts: [String], shell: WorkspaceShellController, outputDirectory: URL) -> String? {
        guard let verb = parts.first, surfaceVerbs.contains(verb) else { return nil }
        let rest = Array(parts.dropFirst())
        func url(_ name: String) -> URL { outputDirectory.appendingPathComponent("\(name).png") }
        func done(_ written: Bool, _ name: String, _ note: String = "") -> String {
            written ? "ux \(verb)\(note.isEmpty ? "" : " (\(note))") -> \(url(name).path)"
                : "ux \(verb) FAILED - nothing to cache for \(name)"
        }
        switch verb {
        case "lock":
            guard let name = rest.first else { return usage(verb, "lock <name> [lit]") }
            let controller = LockScreenController()
            let size = NSSize(width: 1220, height: 760)
            let window = OffScreenProbe.window(size: size)
            defer { controller.stopAnimations(); window.contentView = nil; window.orderOut(nil) }
            window.contentView = controller.view
            controller.view.frame = NSRect(origin: .zero, size: size)
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
            controller.apply(.locked(subtitle: "Grand Line is locked."))
            controller.restartAnimationsIfNeeded()
            let lit = rest.dropFirst().contains("lit")
            if lit { controller.debugKeyDown() }
            return done(writePNG(of: controller.view, to: url(name)), name, lit ? "lit" : "dark")

        case "chest":
            guard let name = rest.first else { return usage(verb, "chest <name> [open]") }
            let gate = CredentialVaultUnlockView()
            let window = OffScreenProbe.window(width: 1200, height: 700)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
            window.contentView = host
            defer { window.contentView = nil; window.orderOut(nil) }
            pin(gate, in: host)
            gate.setMode(.unlock(touchIDAvailable: true))
            for _ in 0..<2 { host.layoutSubtreeIfNeeded() }
            let open = rest.dropFirst().contains("open")
            if open { gate.openChest(.key) }
            return done(writePNG(of: host, to: url(name)), name, open ? "open" : "shut")

        case "palette":
            guard let name = rest.first else { return usage(verb, "palette <name> [query...]") }
            let query = rest.dropFirst().joined(separator: " ")
            let index = UnifiedSearchIndex()
            index.register(UnifiedSearchHostProvider(store: shell.workspace.hostStore, onConnect: { _ in },
                                                     isLive: { _ in false }))
            index.register(UnifiedSearchShiftProvider(store: shell.workspace.shiftStore, onOpenTask: { _ in },
                                                      onOpenFollowUp: { _ in }, onOpenProject: { _ in }))
            let palette = UnifiedSearchController(index: index)
            guard let content = palette.window?.contentView else { return "ux palette FAILED - no panel" }
            palette.debugSearchField.stringValue = query
            palette.debugReload(query: query)
            palette.debugLayoutNow()
            let written = renderDetached(content, size: NSSize(width: palette.debugContentWidth,
                                                               height: max(palette.debugPanelHeight, 120)),
                                         to: url(name))
            return done(written, name, "\"\(query)\", \(palette.debugRowCount) rows")

        case "capture":
            guard let name = rest.first else { return usage(verb, "capture <name> [text...]") }
            let capture = ShiftQuickCaptureController(filer: .unwired)
            guard let content = capture.window?.contentView else { return "ux capture FAILED - no panel" }
            capture.debugInputField.stringValue = rest.dropFirst().joined(separator: " ")
            content.layoutSubtreeIfNeeded()
            let size = capture.window?.frame.size ?? content.fittingSize
            return done(renderDetached(content, size: size, to: url(name)), name)

        case "tasksheet":
            guard let name = rest.first else { return usage(verb, "tasksheet <name> [title...]") }
            let store = shell.workspace.shiftStore
            let title = rest.dropFirst().joined(separator: " ")
            let task = title.isEmpty ? nil : store.activeTasks.first { $0.title == title }
            if !title.isEmpty, task == nil { return "ux tasksheet FAILED - no open task is called \(title)" }
            let editor = ShiftTaskEditorController(task: task, projects: store.projects,
                                                   allDayReminderAt: store.settings.allDayReminderAt)
            editor.loadView()
            // The sheet's own size: its body scrolls, so it fits to nothing.
            let size = NSSize(width: HelmFormSheet.width, height: ShiftTaskEditorController.sheetHeight)
            return done(renderDetached(editor.view, size: size, to: url(name)), name, task?.title ?? "new task")

        case "toast":
            guard rest.count == 2, let kind = toastKinds[rest[0]] else {
                return usage(verb, "toast <done|warning|failure> <name>")
            }
            let words = ["done": "Saved the runbook", "warning": "Saved, but the sync is paused",
                         "failure": "Couldn\u{2019}t save the runbook"][rest[0]] ?? rest[0]
            let pill = ToastPill(message: words, kind: kind, hasUndo: kind == .done, theme: ThemeManager.shared.theme)
            let host = backdrop(NSSize(width: 520, height: 120))
            pill.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                pill.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            ])
            // As `Toast.show` does: the capsule is rounded once it has its height.
            host.layoutSubtreeIfNeeded()
            pill.applyCapsule(theme: ThemeManager.shared.theme)
            return done(renderDetached(host, size: host.frame.size, to: url(rest[1])), rest[1], rest[0])

        case "hud":
            guard rest.count == 2, let state = hudStates[rest[0]] else {
                return usage(verb, "hud <listening|transcribing|cleaningUp|success|copiedOnly|failure> <name>")
            }
            let hud = DictationHUDController()
            guard let pill = hud.debugPaintWithoutShowing(state) else { return "ux hud FAILED - no pill" }
            let size = pill.frame.size == .zero ? pill.fittingSize : pill.frame.size
            return done(renderDetached(pill, size: size, to: url(rest[1])), rest[1], state.text)

        case "menubar":
            guard let name = rest.first else { return usage(verb, "menubar <name>") }
            let controller = CompactModePopoverController()
            let window = OffScreenProbe.window(width: CompactModePopoverController.width + 40, height: 620)
            defer { window.contentViewController = nil; window.orderOut(nil) }
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            return done(writePNG(of: controller.view, to: url(name)), name)

        case "clipboard":
            guard let name = rest.first else { return usage(verb, "clipboard <name>") }
            let folder = AppPaths.dataRoot().appendingPathComponent("tour-clipboard-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = ClipboardHistoryStore(fileURL: folder.appendingPathComponent("history.sealed"),
                                              key: ClipboardHistoryKey.ephemeralKey())
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("grandline-tour-clipboard-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let entries = ["kubectl get pods -n payments", "https://example.com/runbooks/rotate-keys",
                           "ssh deploy@bastion.example.internal", "Rotate the CI deploy key before Friday"]
            for (index, text) in entries.enumerated() {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                _ = store.record(from: pasteboard, sourceApp: "Console", now: Date(timeIntervalSinceNow: Double(index) - 600))
            }
            let content = ClipboardHistoryPanelViewController(store: store)
            content.loadView()
            content.reload()
            let size = NSSize(width: max(content.view.fittingSize.width, 480), height: max(content.view.fittingSize.height, 420))
            return done(renderDetached(content.view, size: size, to: url(name)), name, "\(entries.count) entries")

        case "confirm":
            guard let name = rest.first else { return usage(verb, "confirm <name> [destructive]") }
            let destructive = rest.dropFirst().contains("destructive")
            var request = HelmConfirm.Request(
                title: destructive ? "Delete \u{201C}payments-api\u{201D}?" : "Restart the session?",
                body: destructive ? "Its saved commands and notes go with it. This can\u{2019}t be undone."
                    : "The terminal closes and opens again on the same host.")
            request.confirmTitle = destructive ? "Delete" : "Restart"
            request.destructive = destructive
            request.symbol = destructive ? "trash" : "arrow.clockwise"
            let view = HelmConfirmView(request: request)
            let size = view.fittingSize
            return done(renderDetached(view, size: size, to: url(name)), name, destructive ? "destructive" : "plain")

        default:
            return nil
        }
    }

    /// The verbs this file answers.
    static let surfaceVerbs: Set<String> = ["lock", "chest", "palette", "capture", "tasksheet", "toast", "hud",
                                            "menubar", "clipboard", "confirm"]

    private static let toastKinds: [String: Feedback.Kind] = ["done": .done, "warning": .warning, "failure": .failure]

    private static let hudStates: [String: DictationHUDVisualState] = [
        "listening": .listening, "transcribing": .transcribing, "cleaningUp": .cleaningUp, "success": .success,
        "copiedOnly": .copiedOnly, "failure": .failure("Didn\u{2019}t catch that"),
    ]

    private static func usage(_ verb: String, _ form: String) -> String {
        "ux \(verb) FAILED - want `ux \(form)`"
    }

    private static func pin(_ view: NSView, in host: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    /// A page-coloured ground for a surface that floats over a page.
    private static func backdrop(_ size: NSSize) -> NSView {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = HelmTheme.nsColor(ThemeManager.shared.theme.backgroundHex).cgColor
        return host
    }

    /// Moves `view` into its own off-screen window at `size`, renders it,
    /// and takes the window down again.
    private static func renderDetached(_ view: NSView, size: NSSize, to url: URL) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let window = OffScreenProbe.window(size: size)
        let host = backdrop(NSSize(width: size.width, height: size.height))
        window.contentView = host
        defer { window.contentView = nil; window.orderOut(nil) }
        view.removeFromSuperview()
        if view === host { return writePNG(of: host, to: url) }
        pin(view, in: host)
        host.layoutSubtreeIfNeeded()
        return writePNG(of: host, to: url)
    }
}

#endif
