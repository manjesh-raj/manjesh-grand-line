// Grand Line - native macOS app.
//
// `FM_RUN_CONNECTION_FORMS_TESTS`: the pure half of Con-1, Host-1 and Key-1 of the
// Console / Add Host / Add Key board (Helm 9.2.0). No window - the forms are
// built and read headless, the way `ConnectionsLogicSelfTest` reads its own.
// The window half (the forms in the real inspector, and the renders) is
// `ConnectionFormsWindowChecks`, run from `PageRedesignsSelfTest`.
//
//   - The ~/.ssh scan lists pairs and only pairs, fingerprints a public key
//     exactly as `ssh-keygen -l` does, tells an unreadable folder from an
//     empty one, and never looks in the real folder from a redirected run.
//   - The host form reports every validation rule inline, all at once, and
//     still refuses exactly what Save always refused. No beep, no modal.
//   - The raised well's edge is visible on every app theme, which the inset
//     well's was not on Lavender (the fixture proves that first).
//   - Field text sits off the well's edge, section cards hold their rows, and
//     the key form's status line takes no room while it is empty.

#if FM_SELFTESTS

import AppKit

enum ConnectionFormsSelfTest {

    static func run() -> Bool {
        print("ConnectionFormsSelfTest")
        var allOK = true
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("connection-forms-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for check in [checkTheSSHScan, checkTheScanFolder, checkHostValidation, checkKeyUsage,
                      checkRaisedWells, checkTextInset, checkSectionCards, checkEnvironmentBadge,
                      checkNoBeepsOrModals, checkKeyStatusLine, checkSessionBandWords] {
            var ok = true
            check(scratch, &ok)
            allOK = allOK && ok
        }
        print(allOK ? "ConnectionFormsSelfTest: all checks passed" : "ConnectionFormsSelfTest: FAILED")
        return allOK
    }

    /// A real Ed25519 public key line (made for this fixture, private half
    /// discarded) and the fingerprint `ssh-keygen -lf` printed for it.
    static let fixtureEd25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJMhLDGtZdgo53dVV4cRHBMKVD/uRrHk/qecy3xJZOmr fixture@example.test"
    static let fixtureEd25519Fingerprint = "SHA256:bObc0FjMQHsp19uvFWBoXgR2m2oCbfP4est2IpcZSCE"

    /// Two pairs, an orphan `.pub`, a `.pub` that is not a key, and a file
    /// that is not a `.pub`. The "private" files hold no key material: the
    /// scan never reads them.
    static func writeKeyPairFixture(in folder: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) {
            try? Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        write("id_ed25519", "fixture - not a key")
        write("id_ed25519.pub", fixtureEd25519 + "\n")
        write("work_rsa", "fixture - not a key")
        write("work_rsa.pub", "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQC7 work@example.test\n")
        write("orphan.pub", fixtureEd25519 + "\n")
        write("broken", "fixture - not a key")
        write("broken.pub", "this is not a public key\n")
        write("config", "Host *\n")
    }

    // MARK: The ~/.ssh scan

    private static func checkTheSSHScan(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Key-1: the ~/.ssh scan lists pairs, and only pairs --")
        let folder = scratch.appendingPathComponent("ssh", isDirectory: true)
        writeKeyPairFixture(in: folder)
        // The fixture's own discriminating power: the orphan and the broken
        // .pub really are there, so leaving them out is the scan's doing.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check(names.contains("orphan.pub") && names.contains("broken.pub"), "the fixture is missing its decoys: \(names)", &ok)
        let pairs = SSHKeyDirectoryScan.scan(folder) ?? []
        check(pairs.map(\.name) == ["id_ed25519", "work_rsa"], "the scan listed \(pairs.map(\.name))", &ok)
        check(pairs.map(\.typeName) == ["Ed25519", "RSA"], "the scan typed them \(pairs.map(\.typeName))", &ok)
        check(pairs.first?.fingerprint == fixtureEd25519Fingerprint,
              "the Ed25519 fingerprint is \(pairs.first?.fingerprint ?? "-"), ssh-keygen says \(fixtureEd25519Fingerprint)", &ok)
        check(pairs.first?.comment == "fixture@example.test", "the comment reads \(pairs.first?.comment ?? "-")", &ok)
        check(pairs.first?.privateKeyURL.lastPathComponent == "id_ed25519", "the private file is \(String(describing: pairs.first?.privateKeyURL))", &ok)
        // GL-21: a folder that cannot be read is not an empty one.
        check(SSHKeyDirectoryScan.scan(scratch.appendingPathComponent("no-such-folder")) == nil,
              "a missing folder read as a list", &ok)
        let empty = scratch.appendingPathComponent("empty-ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        check(SSHKeyDirectoryScan.scan(empty) == [], "an empty folder did not read as an empty list", &ok)
        check(SSHKeyDirectoryScan.displayType("ecdsa-sha2-nistp256") == "ECDSA"
              && SSHKeyDirectoryScan.displayType("sk-ssh-ed25519@openssh.com") == "Security key",
              "ECDSA and security keys are not named", &ok)
        check(KeyEditorController.shortFingerprint(fixtureEd25519Fingerprint) == "SHA256:bObc0Fj\u{2026}ZSCE",
              "the short fingerprint reads \(KeyEditorController.shortFingerprint(fixtureEd25519Fingerprint))", &ok)
    }

    private static func checkTheScanFolder(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Key-1: the scan's folder, and never the real one from a redirected run --")
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").path
        check(SSHKeyDirectoryScan.defaultDirectory(environment: [:]).path == home,
              "a plain run looks in \(SSHKeyDirectoryScan.defaultDirectory(environment: [:]).path)", &ok)
        check(SSHKeyDirectoryScan.defaultDirectory(environment: ["FM_SSH_DIR": "/tmp/fixture-ssh"]).path == "/tmp/fixture-ssh",
              "FM_SSH_DIR is not honoured", &ok)
        let redirected = SSHKeyDirectoryScan.defaultDirectory(environment: ["FM_SCRATCH_ROOT": scratch.path])
        check(redirected.path.hasPrefix(scratch.path) && redirected.path != home,
              "a scratch-redirected run looks in \(redirected.path)", &ok)
        // This very process is a self-test run, so its default is redirected too.
        check(SSHKeyDirectoryScan.defaultDirectory().path != home, "a self-test process would list the real ~/.ssh", &ok)
    }

    // MARK: Host-1 validation

    private static func hostForm(existing: Set<String> = []) -> HostEditorController {
        let editor = HostEditorController(host: nil, keyStore: SSHKeyStore(), snippets: [], existingLabels: existing,
                                          keyUsage: [:], presentation: .panel)
        _ = editor.view
        return editor
    }

    private static func checkHostValidation(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Host-1: every rule reported inline, all at once --")
        let form = hostForm(existing: ["grafana"])
        check(form.validationIssues().map(\.field) == [.address], "an empty form reports \(form.validationIssues())", &ok)
        form.debugType("grafana", into: form.debugLabelField)
        form.debugType("-grafana.example.test", into: form.debugAddressField)
        form.debugType("70000", into: form.debugPortField)
        form.debugType("-l", into: form.debugUsernameField)
        form.debugType("-J", into: form.debugJumpViaField)
        let fields = form.validationIssues().map(\.field)
        check(Set(fields) == [.address, .port, .username, .jumpVia, .label] && fields.count == 5,
              "five broken fields reported \(fields)", &ok)
        var saved: [Host] = []
        form.onSave = { saved.append($0) }
        check(!form.savePanel() && saved.isEmpty, "a form with five issues saved", &ok)
        check(form.debugIssues.count == 5, "Save showed \(form.debugIssues.count) issues, want 5", &ok)
        check(form.debugIssueText(.port) == "A whole number from 1 to 65535.", "the port line reads \(form.debugIssueText(.port) ?? "nothing")", &ok)
        check(form.debugFooterHint == "5 fields to fix before this host can be saved",
              "the footer reads \(form.debugFooterHint ?? "nothing")", &ok)
        check(form.debugAddressField.showsIssue && form.debugPortField.showsIssue, "the broken wells have no issue border", &ok)
        // Fixing the fields clears them one by one, live.
        form.debugType("grafana-2", into: form.debugLabelField)
        form.debugType("grafana.example.test", into: form.debugAddressField)
        check(form.debugIssueText(.address) == nil && form.debugIssueText(.label) == nil && !form.debugAddressField.showsIssue,
              "fixed fields still show \(form.debugIssues)", &ok)
        form.debugType("22", into: form.debugPortField)
        form.debugType("ops", into: form.debugUsernameField)
        form.debugType("bastion", into: form.debugJumpViaField)
        check(form.debugIssues.isEmpty && form.validationIssues().isEmpty, "a fixed form still reports \(form.validationIssues())", &ok)
        check(form.savePanel() && saved.count == 1 && saved.first?.address == "grafana.example.test",
              "the fixed form did not save once: \(saved.map(\.address))", &ok)
        // The label defaults to the address, and that default is what the
        // duplicate check compares, as before.
        let unnamed = hostForm(existing: ["grafana.example.test"])
        unnamed.debugType("grafana.example.test", into: unnamed.debugAddressField)
        check(unnamed.validationIssues().map(\.field) == [.label], "an unnamed duplicate reported \(unnamed.validationIssues())", &ok)
        // The preview follows the form.
        check(unnamed.debugPreview.debugTitleText == "grafana.example.test",
              "the preview's title reads \(unnamed.debugPreview.debugTitleText)", &ok)
        check(hostForm().debugFooterHint == "Add an address to create this host. The name defaults to the address.",
              "an empty form's footer reads \(hostForm().debugFooterHint ?? "nothing")", &ok)
    }

    private static func checkKeyUsage(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Host-1: each key's host count --")
        let a = UUID(), b = UUID()
        var hosts = [Host(label: "one", address: "one.example.test"), Host(label: "two", address: "two.example.test"),
                     Host(label: "three", address: "three.example.test")]
        hosts[0].keyID = a
        hosts[1].keyID = a
        hosts[2].keyID = b
        let usage = HostsController.keyUsage(hosts)
        check(usage == [a: 2, b: 1], "key usage counted \(usage)", &ok)
    }

    // MARK: Kit

    private static func checkRaisedWells(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Helm 9.2.0: a raised well has a visible edge on every app theme --")
        // The defect first: on Lavender the inset well and the panel around
        // it are both lavender, near enough the same tone.
        guard let lavender = HelmTheme.appTheme(id: "lavender") else {
            fail("the Lavender theme is missing", &ok)
            return
        }
        let insetEdge = HelmContrast.ratio(HelmField.fill(lavender), HelmTheme.nsColor(lavender.chromeBackgroundHex))
        print("  NOTE Lavender's inset well against its card: \(String(format: "%.3f", insetEdge)):1")
        var worst = (ratio: 99.0, theme: "")
        for theme in HelmTheme.appThemes {
            let fill = HelmField.fill(theme, surface: .raised)
            let edge = HelmContrast.ratio(HelmField.border(theme, surface: .raised), fill)
            if edge < worst.ratio { worst = (edge, theme.id) }
            if theme.mode == .light {
                check(HelmContrast.ratio(fill, HelmTheme.nsColor(theme.chromeBackgroundHex)) < 1.01,
                      "\(theme.id): a light raised well is not the card's own colour", &ok)
            }
            check(HelmContrast.ratio(HelmField.ink(theme, surface: .raised), fill) >= HelmContrast.textTarget,
                  "\(theme.id): text on a raised well is below the floor", &ok)
        }
        print("  NOTE the faintest raised edge is \(String(format: "%.3f", worst.ratio)):1 on \(worst.theme)")
        check(worst.ratio > insetEdge + 0.15 && worst.ratio >= 1.35,
              "the faintest raised edge (\(worst.theme), \(String(format: "%.3f", worst.ratio)):1) is no clearer than Lavender's inset well", &ok)
        // The well is opt-in: every other form keeps its inset recipe.
        check(HelmField.fill(lavender, surface: .inset) == HelmField.fill(lavender), "the inset recipe moved", &ok)
    }

    private static func checkTextInset(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Helm 9.2.0: field text sits off the well's edge --")
        let rect = HelmFieldCentering.inset(NSRect(x: 0, y: 0, width: 200, height: 32))
        check(rect.minX == HelmFieldCentering.horizontalInset && rect.maxX == 200 - HelmFieldCentering.horizontalInset,
              "the inset rect is \(rect)", &ok)
        let field = HelmTextField(placeholder: "hostname or IP")
        field.frame = NSRect(x: 0, y: 0, width: 200, height: HelmField.controlHeight)
        let drawn = field.cell?.drawingRect(forBounds: field.bounds) ?? .zero
        check(drawn.minX >= HelmFieldCentering.horizontalInset, "a field draws its text from x=\(drawn.minX)", &ok)
        // A narrow well (a stepper's) keeps its full width.
        check(HelmFieldCentering.inset(NSRect(x: 0, y: 0, width: 20, height: 20)).width == 20, "a 20pt well lost its width", &ok)
    }

    private static func checkSectionCards(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Helm 9.2.0: section cards hold their rows --")
        let carded = HelmFormSheet(title: "Probe", sectionStyle: .cards, wellSurface: .raised)
        carded.addSection("One", number: "01")
        let first = HelmTextField(placeholder: "first")
        carded.addField("First", first)
        carded.addSection("Two", number: "02")
        let second = HelmTextField(placeholder: "second")
        carded.addField("Second", second)
        carded.refreshTheme()
        let cards = carded.debugSectionCards
        check(cards.count == 2, "two sections made \(cards.count) cards", &ok)
        check(cards.count == 2 && first.isDescendant(of: cards[0]) && second.isDescendant(of: cards[1]),
              "a field is not inside its own section's card", &ok)
        check(first.wellSurface == .raised && second.wellSurface == .raised, "a carded form's fields are not raised", &ok)
        let plain = HelmFormSheet(title: "Probe")
        plain.addSection("One")
        let third = HelmTextField(placeholder: "third")
        plain.addField("Third", third)
        plain.refreshTheme()
        check(plain.debugSectionCards.isEmpty && third.wellSurface == .inset, "a kicker form grew cards or raised wells", &ok)
    }

    private static func checkEnvironmentBadge(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Host-1: the preview's environment badge --")
        check(HostEnvironmentPicker.environment(for: "prod")?.title == "PROD"
              && HostEnvironmentPicker.environment(for: "prod")?.tint == .critical,
              "prod did not resolve to PROD", &ok)
        check(HostEnvironmentPicker.environment(for: "Networking") == nil, "a free-text group became an environment", &ok)
    }

    private static func checkNoBeepsOrModals(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Host-1 and Key-1: validation is inline - no beep, no modal --")
        guard let root = SelfTestSources.appSourceDirectory() else {
            print("  SKIP sources not present - the source guard cannot run")
            return
        }
        for file in ["HostEditorController.swift", "KeyEditorController.swift"] {
            let text = FeatureInventorySelfTest.stripComments(
                (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? "")
            check(!text.isEmpty, "\(file) could not be read", &ok)
            check(!text.contains("NSSound.beep"), "\(file) beeps again", &ok)
        }
        let host = FeatureInventorySelfTest.stripComments(
            (try? String(contentsOf: root.appendingPathComponent("HostEditorController.swift"), encoding: .utf8)) ?? "")
        // A Keychain failure on the inline New Key path still alerts; a field
        // that fails validation never does.
        check(!host.contains("func warn(") && !host.contains("\"Invalid port\""),
              "the host form raises a modal for a field again", &ok)
    }

    private static func checkKeyStatusLine(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Key-1: the status line takes no room while it is empty --")
        let label = KeyStatusLabel(wrappingLabelWithString: "")
        label.stringValue = "Verified Ed25519 key."
        check(!label.isHidden, "a status with words is hidden", &ok)
        label.stringValue = ""
        check(label.isHidden, "an empty status still takes room", &ok)
        let editor = KeyEditorController(key: nil, presentation: .panel)
        _ = editor.view
        check(editor.debugStatus.isEmpty && editor.debugFooterHint == "Generate a key to save it.",
              "a new key form's footer reads \(editor.debugFooterHint ?? "nothing")", &ok)
    }

    // MARK: Con-1

    private static func checkSessionBandWords(_ scratch: URL, _ ok: inout Bool) {
        print("\n-- Con-1 and B2: the band's words --")
        // B2: one line of plain words. No tab count (the strip under the
        // band says it) and no shell or folder (the prompt says them).
        check(ConsoleController.localDetail(liveSessions: 0) == "no ssh sessions"
              && ConsoleController.localDetail(liveSessions: 1) == "1 ssh session"
              && ConsoleController.localDetail(liveSessions: 4) == "4 ssh sessions",
              "the band's detail reads \(ConsoleController.localDetail(liveSessions: 0))", &ok)
        // The chips follow the registry's order and its shortcut numbers.
        let registry = HostSessionRegistry()
        let a = UUID(), b = UUID()
        registry.register(hostID: a, label: "DEV Bastion", accentHex: "6cd7e3", state: .connected)
        registry.register(hostID: b, label: "PROD Web", accentHex: nil, state: .restored)
        let chips = ConsoleSessionBand.chips(from: registry)
        check(chips.map(\.hostID) == [a, b] && chips.map(\.shortcut) == [1, 2] && chips.map(\.connected) == [true, false],
              "the chips read \(chips)", &ok)
    }
}

#endif
