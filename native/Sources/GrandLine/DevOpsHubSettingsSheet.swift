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
    /// S-04 (full review 4). On by default.
    private let confineRow = HelmToggleRow(title: "Keep the site to its own address",
                                           subtitle: "Blocks requests to the internet and to other ports on this Mac. "
                                               + "Turn off for a site that needs a CDN or an API.")
    /// S-02 (full review 4).
    /// D-02: which kind a new project is. Fixed once it exists.
    private lazy var kindTabs = HelmSegmentedTabs(
        items: [.init(id: LocalProject.Kind.staticSite.rawValue, title: "Static folder"),
                .init(id: LocalProject.Kind.devServer.rawValue, title: "Dev server")],
        selected: project.kind.rawValue, size: .compact)
    /// D-02: a dev server's command.
    private let commandField = HelmTextField(placeholder: "npm run dev")
    private var commandRow: NSView?
    private var commandCaption: NSTextField?
    private let restartRow = HelmToggleRow(title: "Restart if it crashes",
                                           subtitle: "Up to \(DevServerRules.maxCrashes) times in \(Int(DevServerRules.crashWindow / 60)) minutes, then it is left stopped with the error.")
    /// D-02: always on, and shown so the captain can see it is.
    private let stopOnQuitRow = HelmToggleRow(title: "Stop it when Grand Line quits",
                                              subtitle: "Always. It also stops if Grand Line crashes, so nothing is left listening.")
    private var portCaption: NSTextField?
    private var addressField: HelmTextField?
    private weak var form: HelmFormSheet?
    private var kind: LocalProject.Kind { project.kind }
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

    /// Add Project: an empty sheet that suggests `port`, or, for a folder
    /// dropped on the page (UX-15), one filled in from that folder.
    static func adding(port: UInt16, takenPorts: Set<UInt16>, folder: URL? = nil) -> DevOpsHubSettingsSheet {
        let draft = LocalProject(id: "", name: "", kind: .staticSite, folderOverride: nil, port: port,
                                 opensWhenReady: true, startsAtLaunch: false, lastRun: nil)
        let sheet = DevOpsHubSettingsSheet(draft: draft, takenPorts: takenPorts)
        sheet.droppedFolder = folder
        return sheet
    }

    /// UX-15: a folder dropped on DevOps Hub, filled in once the sheet loads.
    private var droppedFolder: URL?

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let form = HelmFormSheet(title: mode == .add ? "Add a project" : "\(project.name) settings")
        view = form
        self.form = form
        form.setSubtitle(mode == .add ? "A folder with an index.html, or a command that serves one."
                                      : "Changes apply the next time it starts.")

        if mode == .add {
            form.addSection("The project")
            // Gotcha (19): every field here is read on Save, and the delegate
            // is what ends a typed-and-left value into the field.
            nameField.delegate = self
            form.addField("Name", nameField)
            kindTabs.onSelect = { [weak self] id in
                guard let self, let kind = LocalProject.Kind(rawValue: id) else { return }
                self.project.kind = kind
                self.applyKind()
            }
            form.addField("Kind", kindTabs)
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

        commandField.delegate = self
        commandField.stringValue = project.command ?? ""
        commandRow = form.addField("Command", commandField)
        commandCaption = form.addCaption("Runs in the folder in a login shell, with its output kept as the log.")

        form.addSection("How it is served")
        let address = HelmTextField(placeholder: "")
        addressField = address
        address.stringValue = "\(LocalStaticServer.loopbackHost) (this Mac only)"
        address.isEditable = false
        address.isSelectable = true
        portField.stringValue = "\(project.port)"
        portField.delegate = self
        form.addFieldColumns([("Address", address), ("Port", portField)])
        portCaption = form.addCaption(mode == .add ? Self.addPortCaption
                                     : "The site saves your progress per address, so a new port starts it with no progress.")
        restartRow.isOn = project.restartsOnCrash
        form.addRow(restartRow)
        stopOnQuitRow.isOn = true
        stopOnQuitRow.toggle.isEnabled = false
        form.addRow(stopOnQuitRow)
        browserRow.isOn = project.allowsBrowser
        form.addRow(browserRow)
        confineRow.isOn = project.confinesNetwork
        form.addRow(confineRow)

        form.addSection("Starting")
        opensRow.isOn = project.opensWhenReady
        launchRow.isOn = project.startsAtLaunch
        form.addRow(opensRow)
        form.addRow(launchRow)

        form.setFooter(target: self, confirmTitle: mode == .add ? "Add Project" : "Save", confirm: #selector(save),
                       cancel: #selector(cancel))
        applyKind(resize: false)
        form.refreshTheme()
        form.sizeToFitContent()
    }

    /// D-02: show the rows the chosen kind uses. A dev server has a command,
    /// a restart rule and a port it prints; a static site has a browser
    /// switch and an index.html to find.
    private func applyKind(resize: Bool = true) {
        let dev = kind == .devServer
        commandRow?.isHidden = !dev
        commandCaption?.isHidden = !dev
        restartRow.isHidden = !dev
        stopOnQuitRow.isHidden = !dev
        browserRow.isHidden = dev
        if dev, portField.stringValue == "\(project.port)", mode == .add { portField.stringValue = "" }
        portField.placeholderString = dev ? "Found in its output" : "7420"
        addressField?.stringValue = dev ? "Whatever the command prints" : "\(LocalStaticServer.loopbackHost) (this Mac only)"
        portCaption?.stringValue = dev
            ? "Leave it empty and Grand Line uses the address the command prints, such as localhost:5173."
            : (mode == .add ? Self.addPortCaption
                            : "The site saves your progress per address, so a new port starts it with no progress.")
        if dev {
            folderCheckLabel?.stringValue = "The folder the command runs in."
            checkedFolder = nil
        } else {
            checkedFolder = nil
            checkFolder()
        }
        if resize { form?.sizeToFitContent() }
    }

    // MARK: Actions

    override func viewDidLoad() {
        super.viewDidLoad()
        // UX-15: the dropped folder, as Choose would have filled it.
        guard mode == .add, let folder = droppedFolder else { return }
        folderField.stringValue = LocalProject.abbreviate(folder.path)
        nameField.stringValue = Self.suggestedName(for: folder)
        checkFolder()
    }

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
        guard mode == .add, kind == .staticSite, let label = folderCheckLabel else { return }
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
                       confinesNetwork: Bool? = nil, takenPorts: Set<UInt16> = [], requiresFolder: Bool = false,
                       command: String? = nil, restartsOnCrash: Bool? = nil) -> (LocalProject?, String?) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, trimmedName.isEmpty { return (nil, "Give the project a name.") }
        let folder = folderText.trimmingCharacters(in: .whitespacesAndNewlines)
        let dev = project.kind == .devServer
        if requiresFolder, folder.isEmpty {
            return (nil, dev ? "Choose the folder the command runs in." : "Choose the folder that holds its index.html.")
        }
        let trimmedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        if dev, (trimmedCommand ?? project.command ?? "").isEmpty { return (nil, "Give the command to run, such as npm run dev.") }
        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        // A dev server's port may be left empty: it is found in its output.
        let port: UInt16
        if dev, trimmedPort.isEmpty {
            port = 0
        } else if let parsed = UInt16(trimmedPort), parsed >= 1024 {
            port = parsed
        } else {
            return (nil, "Choose a port from 1024 to 65535.")
        }
        guard port == 0 || !takenPorts.contains(port) else {
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
        if let confinesNetwork { edited.confinesNetwork = confinesNetwork }
        if dev, let trimmedCommand { edited.command = trimmedCommand }
        if let restartsOnCrash { edited.restartsOnCrash = restartsOnCrash }
        return (edited, nil)
    }

    @objc private func save() {
        let adding = mode == .add
        let (edited, problem) = Self.edited(project, name: adding ? nameField.stringValue : nil,
                                            folderText: folderField.stringValue,
                                            portText: portField.stringValue,
                                            opensWhenReady: opensRow.isOn, startsAtLaunch: launchRow.isOn,
                                            allowsBrowser: browserRow.isOn, confinesNetwork: confineRow.isOn,
                                            takenPorts: takenPorts, requiresFolder: adding,
                                            command: commandField.stringValue, restartsOnCrash: restartRow.isOn)
        guard let edited else {
            let field: HelmTextField
            if problem?.hasPrefix("Give the command") == true {
                field = commandField
            } else if problem?.hasPrefix("Give") == true {
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
    func debugChooseKind(_ kind: LocalProject.Kind) { kindTabs.select(kind.rawValue); project.kind = kind; applyKind() }
    func debugSetCommand(_ command: String) { commandField.stringValue = command }
    var debugCommandRowHidden: Bool { commandRow?.isHidden ?? true }
    var debugBrowserRow: HelmToggleRow { browserRow }
    var debugConfineRow: HelmToggleRow { confineRow }
    func debugCheckFolder() { checkFolder() }
    func debugSave() { save() }
    #endif
}
