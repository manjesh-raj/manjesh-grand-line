// Grand Line - native macOS app.
//
// DevOps Hub's Project settings sheet: one project's folder, port and the
// two start options, on the app's one editor scaffold (`HelmFormSheet`).
//
// A sheet on the page rather than a Settings category: each project carries
// its own path and port, and a Settings page for one project would sit far
// from the thing it configures. Settings › Appearance still shows or hides
// the DevOps Hub row, as it does for every module.
//
// The address is not editable. The server binds 127.0.0.1 and nothing else
// (`LocalStaticServer`), and the sheet says so rather than offering a field
// that could put a private repo on the LAN.
//
// Changes apply the next time the project starts; a running project keeps
// serving as it was (`LocalProjectRegistry.update`).

import AppKit

final class DevOpsHubSettingsSheet: NSViewController, NSTextFieldDelegate {

    /// Called with the edited project on Save.
    var onSave: ((LocalProject) -> Void)?

    private var project: LocalProject
    private let folderField = HelmTextField(placeholder: "~/path/to/project")
    private let portField = HelmTextField(placeholder: "7420")
    private let opensRow = HelmToggleRow(title: "Show the course when it\u{2019}s ready",
                                         subtitle: "Start on the page swaps the hero for the site once it has loaded.")
    private let launchRow = HelmToggleRow(title: "Start when Grand Line opens",
                                          subtitle: "Once the window is up. Off by default.")

    init(project: LocalProject) {
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let form = HelmFormSheet(title: "\(project.name) settings")
        view = form
        form.setSubtitle("Changes apply the next time it starts.")

        form.addSection("Where it is")
        folderField.stringValue = project.folderOverride.map(LocalProject.abbreviate)
            ?? LocalProject.abbreviate(LocalProject.defaultFolder(for: project.id).path)
        // Gotcha (19): a persisted field needs its delegate too, so a value
        // typed and left (not Return) is still the one Save reads.
        folderField.delegate = self
        let choose = HelmButton(title: "Choose\u{2026}", variant: .secondary, target: self,
                                action: #selector(chooseFolder))
        let folderRow = NSStackView(views: [folderField, choose])
        folderRow.orientation = .horizontal
        folderRow.spacing = HelmMetrics.s2
        folderRow.distribution = .fill
        folderField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        choose.setContentHuggingPriority(.required, for: .horizontal)
        choose.setContentCompressionResistancePriority(.required, for: .horizontal)
        form.addField("Folder", folderRow)
        form.addCaption("It needs an index.html at its top. The default is projects/\(project.id) in your firstmate home.")

        form.addSection("How it is served")
        let address = HelmTextField(placeholder: "")
        address.stringValue = "\(LocalStaticServer.loopbackHost) (this Mac only)"
        address.isEditable = false
        address.isSelectable = true
        portField.stringValue = "\(project.port)"
        portField.delegate = self
        form.addFieldColumns([("Address", address), ("Port", portField)])
        form.addCaption("The course saves your progress per address, so a new port starts it with no progress.")

        form.addSection("Starting")
        opensRow.isOn = project.opensWhenReady
        launchRow.isOn = project.startsAtLaunch
        form.addRow(opensRow)
        form.addRow(launchRow)

        form.setFooter(target: self, confirmTitle: "Save", confirm: #selector(save), cancel: #selector(cancel))
        form.refreshTheme()
        form.sizeToFitContent()
    }

    // MARK: Actions

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds the project\u{2019}s index.html."
        panel.directoryURL = project.folder.deletingLastPathComponent()
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.folderField.stringValue = LocalProject.abbreviate(url.path)
        }
    }

    /// The edited project, or nil (with the reason) when a field is not usable.
    static func edited(_ project: LocalProject, folderText: String, portText: String, opensWhenReady: Bool,
                       startsAtLaunch: Bool) -> (LocalProject?, String?) {
        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(trimmedPort), port >= 1024 else {
            return (nil, "Choose a port from 1024 to 65535.")
        }
        var edited = project
        let folder = folderText.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultPath = LocalProject.defaultFolder(for: project.id).standardizedFileURL.path
        let typed = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
        edited.folderOverride = folder.isEmpty || typed == defaultPath ? nil : folder
        edited.port = port
        edited.opensWhenReady = opensWhenReady
        edited.startsAtLaunch = startsAtLaunch
        return (edited, nil)
    }

    @objc private func save() {
        let (edited, problem) = Self.edited(project, folderText: folderField.stringValue,
                                            portText: portField.stringValue,
                                            opensWhenReady: opensRow.isOn, startsAtLaunch: launchRow.isOn)
        guard let edited else {
            portField.toolTip = problem
            view.window?.makeFirstResponder(portField)
            NSSound.beep()
            return
        }
        project = edited
        onSave?(edited)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }

    // The fields are read on Save, so ending an edit needs no work of its
    // own; the delegate is what makes AppKit end it into the field's value.
    func controlTextDidEndEditing(_ obj: Notification) {}

    #if FM_SELFTESTS
    var debugFolderText: String { folderField.stringValue }
    var debugPortText: String { portField.stringValue }
    func debugSetFields(folder: String, port: String, opensWhenReady: Bool, startsAtLaunch: Bool) {
        folderField.stringValue = folder
        portField.stringValue = port
        opensRow.isOn = opensWhenReady
        launchRow.isOn = startsAtLaunch
    }
    func debugSave() { save() }
    #endif
}
