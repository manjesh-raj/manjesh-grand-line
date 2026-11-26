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
//
// **Add Project is the same sheet** (`adding(port:takenPorts:)`), with a Name
// field above the folder and no default folder: a new project is any local
// folder with an `index.html` at its top. The folder is checked off the main
// thread as it is chosen or typed (GL-12), and a port another project uses is
// refused in both modes. A port some other app holds is found at Start, as
// before, because probing it here would be a guess about a later moment.

import AppKit

final class DevOpsHubSettingsSheet: NSViewController, NSTextFieldDelegate {

    enum Mode: Equatable { case edit, add }

    /// Called with the edited project on Save, or with the new project on
    /// Add (its id is the registry's to assign).
    var onSave: ((LocalProject) -> Void)?

    let mode: Mode
    private var project: LocalProject
    private let takenPorts: Set<UInt16>
    private let nameField = HelmTextField(placeholder: "runbook-site")
    private let folderField = HelmTextField(placeholder: "~/path/to/project")
    private let portField = HelmTextField(placeholder: "7420")
    private var folderCheckLabel: NSTextField?
    private var checkedFolder: String?
    private let opensRow = HelmToggleRow(title: "Show the site when it\u{2019}s ready",
                                         subtitle: "Start on the page opens the site here once it has loaded.")
    private let launchRow = HelmToggleRow(title: "Start when Grand Line opens",
                                          subtitle: "Once the window is up. Off by default.")
    /// S-02 (full review 4).
    private let browserRow = HelmToggleRow(title: "Allow my browser",
                                           subtitle: "Off, only Grand Line\u{2019}s own view can read the site. On, your "
                                               + "browser can too, and so can any other app on this Mac while it runs.")

    /// The sheet for an existing project. `takenPorts` are the other
    /// projects' ports.
    init(project: LocalProject, takenPorts: Set<UInt16> = []) {
        self.project = project
        self.takenPorts = takenPorts
        mode = .edit
        super.init(nibName: nil, bundle: nil)
    }

    private init(draft: LocalProject, takenPorts: Set<UInt16>) {
        project = draft
        self.takenPorts = takenPorts
        mode = .add
        super.init(nibName: nil, bundle: nil)
    }

    /// Add Project: an empty sheet that suggests `port`.
    static func adding(port: UInt16, takenPorts: Set<UInt16>) -> DevOpsHubSettingsSheet {
        let draft = LocalProject(id: "", name: "", kind: .staticSite, folderOverride: nil, port: port,
                                 opensWhenReady: true, startsAtLaunch: false, lastRun: nil)
        return DevOpsHubSettingsSheet(draft: draft, takenPorts: takenPorts)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let form = HelmFormSheet(title: mode == .add ? "Add a project" : "\(project.name) settings")
        view = form
        form.setSubtitle(mode == .add ? "A folder of built HTML, served on this Mac only."
                                      : "Changes apply the next time it starts.")

        if mode == .add {
            form.addSection("The project")
            // Gotcha (19): every field here is read on Save, and the delegate
            // is what ends a typed-and-left value into the field.
            nameField.delegate = self
            form.addField("Name", nameField)
        } else {
            form.addSection("Where it is")
        }
        if mode == .edit {
            folderField.stringValue = project.folderOverride.map(LocalProject.abbreviate)
                ?? LocalProject.abbreviate(LocalProject.defaultFolder(for: project.id).path)
        }
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
        if mode == .add {
            folderCheckLabel = form.addCaption(Self.folderHint)
        } else {
            form.addCaption("\(Self.folderHint) The default is projects/\(project.id) in your firstmate home.")
        }

        form.addSection("How it is served")
        let address = HelmTextField(placeholder: "")
        address.stringValue = "\(LocalStaticServer.loopbackHost) (this Mac only)"
        address.isEditable = false
        address.isSelectable = true
        portField.stringValue = "\(project.port)"
        portField.delegate = self
        form.addFieldColumns([("Address", address), ("Port", portField)])
        form.addCaption(mode == .add ? Self.addPortCaption
                                     : "The site saves your progress per address, so a new port starts it with no progress.")
        browserRow.isOn = project.allowsBrowser
        form.addRow(browserRow)

        form.addSection("Starting")
        opensRow.isOn = project.opensWhenReady
        launchRow.isOn = project.startsAtLaunch
        form.addRow(opensRow)
        form.addRow(launchRow)

        form.setFooter(target: self, confirmTitle: mode == .add ? "Add Project" : "Save", confirm: #selector(save),
                       cancel: #selector(cancel))
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
        if mode == .edit { panel.directoryURL = project.folder.deletingLastPathComponent() }
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.folderField.stringValue = LocalProject.abbreviate(url.path)
            if self.mode == .add, self.nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                self.nameField.stringValue = Self.suggestedName(for: url)
            }
            self.checkFolder()
        }
    }

    /// Where the site's `index.html` may be (S-02).
    static let folderHint = "It needs an index.html at its top, or in a dist, build or public folder, "
        + "which is then the folder served."

    /// S-02: the caption under Add Project's port. Loopback keeps the network
    /// out, not the other software on this Mac.
    static let addPortCaption = "The next port no other project uses. Nothing on your network can reach it, but "
        + "other apps on this Mac can reach the port while it runs, and can read the site if you allow your browser."

    /// A name for a chosen folder: its own name, or its parent's when the
    /// folder is a build output (`dist`, `build`, `public`, `out`, `site`).
    static func suggestedName(for folder: URL) -> String {
        let outputs: Set<String> = ["dist", "build", "public", "out", "site", "_site"]
        let name = folder.lastPathComponent
        guard outputs.contains(name.lowercased()) else { return name }
        return folder.deletingLastPathComponent().lastPathComponent
    }

    /// Add Project's one line under the folder: what Start would find there,
    /// read off the main thread (GL-12).
    private func checkFolder() {
        guard mode == .add, let label = folderCheckLabel else { return }
        let text = folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != checkedFolder else { return }
        checkedFolder = text
        guard !text.isEmpty else {
            label.stringValue = Self.folderHint
            return
        }
        let folder = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
        label.stringValue = "Checking the folder\u{2026}"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = LocalProjectPreflight.check(folder: folder)
            let served = LocalProjectPreflight.servedFolder(for: folder)
            let subfolder = served == folder ? nil : served.lastPathComponent
            DispatchQueue.main.async {
                guard let self, self.checkedFolder == text else { return }
                label.stringValue = Self.folderLine(outcome, servedSubfolder: subfolder)
            }
        }
    }

    static func folderLine(_ outcome: LocalProjectPreflight.Outcome, servedSubfolder: String? = nil) -> String {
        switch outcome {
        case .ready:
            let found = servedSubfolder.map { "Serves \($0)/ \u{00B7} " } ?? "index.html found \u{00B7} "
            return found + (DevOpsHubWords.folderDetail(outcome) ?? "")
        case .folderMissing:
            return "There is no folder at that path."
        case .indexMissing:
            return "That folder has no index.html at its top."
        case .notReadable:
            return "macOS didn\u{2019}t let Grand Line read that folder."
        }
    }

    /// The edited project, or nil (with the reason) when a field is not
    /// usable. `name` is Add Project's name field, and a nil `name` keeps the
    /// project's own. `takenPorts` are the other projects' ports.
    static func edited(_ project: LocalProject, name: String? = nil, folderText: String, portText: String,
                       opensWhenReady: Bool, startsAtLaunch: Bool, allowsBrowser: Bool? = nil,
                       takenPorts: Set<UInt16> = [], requiresFolder: Bool = false) -> (LocalProject?, String?) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, trimmedName.isEmpty { return (nil, "Give the project a name.") }
        let folder = folderText.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresFolder, folder.isEmpty { return (nil, "Choose the folder that holds its index.html.") }
        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(trimmedPort), port >= 1024 else {
            return (nil, "Choose a port from 1024 to 65535.")
        }
        guard !takenPorts.contains(port) else {
            return (nil, "Another project uses port \(port). Choose another.")
        }
        var edited = project
        if let trimmedName { edited.name = trimmedName }
        if requiresFolder {
            edited.folderOverride = folder
        } else {
            let defaultPath = LocalProject.defaultFolder(for: project.id).standardizedFileURL.path
            let typed = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
            edited.folderOverride = folder.isEmpty || typed == defaultPath ? nil : folder
        }
        edited.port = port
        edited.opensWhenReady = opensWhenReady
        edited.startsAtLaunch = startsAtLaunch
        if let allowsBrowser { edited.allowsBrowser = allowsBrowser }
        return (edited, nil)
    }

    @objc private func save() {
        let adding = mode == .add
        let (edited, problem) = Self.edited(project, name: adding ? nameField.stringValue : nil,
                                            folderText: folderField.stringValue,
                                            portText: portField.stringValue,
                                            opensWhenReady: opensRow.isOn, startsAtLaunch: launchRow.isOn,
                                            allowsBrowser: browserRow.isOn,
                                            takenPorts: takenPorts, requiresFolder: adding)
        guard let edited else {
            let field: HelmTextField
            if problem?.hasPrefix("Give") == true {
                field = nameField
            } else if problem?.hasPrefix("Choose the folder") == true {
                field = folderField
            } else {
                field = portField
            }
            field.toolTip = problem
            lastProblem = problem
            view.window?.makeFirstResponder(field)
            NSSound.beep()
            return
        }
        project = edited
        onSave?(edited)
        dismiss(self)
    }

    /// Why the last Save was refused, for the suite.
    private(set) var lastProblem: String?

    @objc private func cancel() {
        dismiss(self)
    }

    // The fields are read on Save, so ending an edit needs no work of its
    // own beyond Add Project's folder line. The delegate is what makes
    // AppKit end it into the field's value.
    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === folderField { checkFolder() }
    }

    #if FM_SELFTESTS
    var debugFolderText: String { folderField.stringValue }
    var debugPortText: String { portField.stringValue }
    var debugNameText: String { nameField.stringValue }
    var debugFolderLine: String? { folderCheckLabel?.stringValue }
    func debugSetFields(folder: String, port: String, opensWhenReady: Bool, startsAtLaunch: Bool) {
        folderField.stringValue = folder
        portField.stringValue = port
        opensRow.isOn = opensWhenReady
        launchRow.isOn = startsAtLaunch
    }
    func debugSetName(_ name: String) { nameField.stringValue = name }
    var debugBrowserRow: HelmToggleRow { browserRow }
    func debugCheckFolder() { checkFolder() }
    func debugSave() { save() }
    #endif
}
