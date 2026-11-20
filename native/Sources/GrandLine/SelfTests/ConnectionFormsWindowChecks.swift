// Grand Line - native macOS app.
//
// The window half of Con-1, Host-1 and Key-1 (Console / Add Host / Add Key
// board, Helm 9.2.0): Console's session band and terminal card, and the host
// and key forms in the real sidebar shell's inspector, measured from their
// real layers after a real layout pass. Run from
// `PageRedesignsSelfTest`, which already owns an off-screen split shell, so
// this adds no window-backed suite (`NEEDS_SESSION` is at its ceiling).
//
// With `FM_CONNECTION_FORMS_RENDER_DIR` set it also writes the PR's renders:
// Console with only local shells and with a live session, the host form
// empty, filled, with errors and saving, and the key form on each path, in
// Daylight, Dusk and the Lavender palette.

#if FM_SELFTESTS

import AppKit

enum ConnectionFormsWindowChecks {

    static func checkForms(_ shell: MainSplitShellController, _ window: NSWindow, _ scratch: URL, _ ok: inout Bool) {
        let sshFolder = scratch.appendingPathComponent("ssh-fixture", isDirectory: true)
        ConnectionFormsSelfTest.writeKeyPairFixture(in: sshFolder)
        let saved = KeyEditorController.debugSSHDirectory
        KeyEditorController.debugSSHDirectory = sshFolder
        defer { KeyEditorController.debugSSHDirectory = saved }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        resize(window, width: 1512, shell)
        checkConsole(shell, &ok)
        checkHostForm(shell, &ok)
        checkKeyForm(shell, &ok)
        writeRenders(shell, window)
        shell.workspace.hostsPanel.debugCloseFormPanels()
        settle(shell)
    }

    // MARK: Con-1

    private static func checkConsole(_ shell: MainSplitShellController, _ ok: inout Bool) {
        print("\n-- Con-1: Console's session band and terminal card --")
        shell.workspace.navigator.show(.console)
        settle(shell)
        let console = shell.workspace.console
        let band = console.sessionBand
        check(!band.isHiddenOrHasHiddenAncestor && band.frame.height == ConsoleSessionBand.height,
              "Console's band is not showing (\(band.frame))", &ok)
        check(band.debugKicker == "This Mac \u{00B7} local shells", "the band's kicker reads \(band.debugKicker)", &ok)
        check(band.debugTitle.hasSuffix("no live sessions"), "with no sessions the band reads \(band.debugTitle)", &ok)
        // The band sits above the tabs, both inside the page.
        let bandFrame = band.convert(band.bounds, to: console.view)
        let tabFrame = console.tabBar.convert(console.tabBar.bounds, to: console.view)
        let above = console.view.isFlipped ? bandFrame.maxY <= tabFrame.minY + 0.5 : bandFrame.minY >= tabFrame.maxY - 0.5
        check(above, "the band \(bandFrame) is not above the tabs \(tabFrame)", &ok)
        // The shared console is a padded card now, like a host page.
        check(console.terminalInset >= 20, "the shared console's terminal inset is \(console.terminalInset)pt", &ok)
        check(console.debugTerminalCardVisible(), "the shared console draws no terminal card", &ok)
        // A live session is a chip, and the chip's verbs reach the shell.
        let host = UUID()
        shell.workspace.hosts.sessions.register(hostID: host, label: "DEV Bastion", accentHex: "6cd7e3", state: .connected)
        settle(shell)
        check(band.debugChipHostIDs() == [host], "the band lists \(band.debugChipHostIDs()) for one session", &ok)
        check(band.debugTitle.hasSuffix("1 live session"), "with one session the band reads \(band.debugTitle)", &ok)
        var switched: UUID?
        var ended: UUID?
        let (wiredSwitch, wiredEnd) = (band.onSwitch, band.onEnd)
        band.onSwitch = { switched = $0 }
        band.onEnd = { ended = $0 }
        band.debugClickChip(host.uuidString)
        band.debugClickClose(host)
        band.onSwitch = wiredSwitch
        band.onEnd = wiredEnd
        check(switched == host && ended == host, "the chip asked to switch to \(String(describing: switched)) and end \(String(describing: ended))", &ok)
        shell.workspace.hosts.sessions.unregister(hostID: host)
        settle(shell)
        check(band.debugChipHostIDs().isEmpty, "an ended session kept its chip", &ok)
    }

    // MARK: Host-1

    private static func checkHostForm(_ shell: MainSplitShellController, _ ok: inout Bool) {
        print("\n-- Host-1: the new host form in the inspector --")
        let hosts = shell.workspace.hostsPanel
        shell.workspace.navigator.show(.hosts)
        hosts.select(tab: .hosts)
        hosts.openNewHostPanel()
        settle(shell)
        guard let panel = hosts.hostPanel, let form = panel.view as? HelmFormSheet else {
            fail("Add Host opened no form", &ok)
            return
        }
        check(form.debugSectionCards.count == 5, "the host form has \(form.debugSectionCards.count) section cards, want 5", &ok)
        for card in form.debugSectionCards {
            check(card.frame.width > 200 && card.layer?.borderWidth == 1,
                  "a section card is \(card.frame.width)pt wide with a \(card.layer?.borderWidth ?? 0)pt edge", &ok)
        }
        // Raised wells: the card's colour, with a border that is not the
        // card's colour (the inset well on Lavender had neither).
        let theme = ThemeManager.shared.theme
        let address = panel.debugAddressField
        let fill = address.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
        let border = address.layer?.borderColor.flatMap { NSColor(cgColor: $0) }
        check(sameColor(fill, HelmField.fill(theme, surface: .raised)),
              "the address well is \(describe(fill)), not the raised fill", &ok)
        check(sameColor(border, HelmField.border(theme, surface: .raised)),
              "the address well's edge is \(describe(border)), not the raised border", &ok)
        // The key picker lists the agent and both seeded keys, and a click
        // on a row chooses it.
        let picker = panel.debugKeyPicker
        check(picker.debugRowTitles.first == "System ssh agent" && picker.debugRowTitles.count == 1 + hosts.keyStore.keys.count,
              "the key picker lists \(picker.debugRowTitles)", &ok)
        picker.debugClickRow(1)
        settle(shell)
        check(picker.selectedID == hosts.keyStore.keys.first?.id,
              "a click on the first saved key chose \(String(describing: picker.selectedID))", &ok)
        check(panel.debugPreview.debugFacts.first == hosts.keyStore.keys.first?.label,
              "the preview does not name the chosen key: \(panel.debugPreview.debugFacts)", &ok)
        // The preview follows the fields as they are typed.
        panel.debugType("DEV Bastion", into: panel.debugLabelField)
        panel.debugType("bastion.dev.example.test", into: address)
        settle(shell)
        check(panel.debugPreview.debugTitleText == "DEV Bastion", "the preview's title reads \(panel.debugPreview.debugTitleText)", &ok)
        check(panel.debugPreview.debugSubtitleText.contains("bastion.dev.example.test"),
              "the preview's address reads \(panel.debugPreview.debugSubtitleText)", &ok)
        // Save with a leading dash: inline, under the field, nothing saved.
        let before = hosts.hostStore.hosts.count
        panel.debugType("-bastion.dev.example.test", into: address)
        check(!panel.savePanel(), "a host with a leading-dash address saved", &ok)
        settle(shell)
        check(hosts.hostStore.hosts.count == before, "the refused host reached the store", &ok)
        check(panel.debugIssueText(.address)?.contains("option") == true,
              "the address field's issue line reads \(panel.debugIssueText(.address) ?? "nothing")", &ok)
        check(address.showsIssue, "the refused address well has no issue border", &ok)
        check(panel.debugFooterHint?.contains("1 field to fix") == true,
              "the footer hint reads \(panel.debugFooterHint ?? "nothing")", &ok)
        // Fixing the field clears its line as it is typed.
        panel.debugType("bastion.dev.example.test", into: address)
        settle(shell)
        check(panel.debugIssueText(.address) == nil && !address.showsIssue,
              "the fixed address still shows \(panel.debugIssueText(.address) ?? "a border")", &ok)
        hosts.debugCloseFormPanels()
        settle(shell)
    }

    // MARK: Key-1

    private static func checkKeyForm(_ shell: MainSplitShellController, _ ok: inout Bool) {
        print("\n-- Key-1: the new key form in the inspector --")
        let hosts = shell.workspace.hostsPanel
        hosts.openNewKeyPanel(preset: nil)
        settle(shell)
        guard let panel = hosts.keyPanel else {
            fail("New Key opened no form", &ok)
            return
        }
        check(panel.debugChoices.debugTitles == KeyPathChoices.Path.allCases.map { KeyPathChoices.words(for: $0).title },
              "the key form offers \(panel.debugChoices.debugTitles)", &ok)
        check(panel.debugMode == "generate", "a new key form opens in \(panel.debugMode)", &ok)
        check(panel.debugFooterHint == "Generate a key to save it.", "the key footer reads \(panel.debugFooterHint ?? "nothing")", &ok)
        // The public key well draws a box: full width, a real edge, the
        // raised fill - the panel used to lay it out zero points wide.
        let well = panel.debugPublicKeyView
        let chrome = well.chromeView
        check(well.frame.width > 200 && chrome.frame.width > 200,
              "the public key well is \(well.frame.width)pt wide (chrome \(chrome.frame.width)pt)", &ok)
        check(chrome.layer?.borderWidth ?? 0 >= 1,
              "the public key well has no edge (layer \(chrome.layer == nil ? "missing" : "present"), wantsLayer \(chrome.wantsLayer), in a window \(chrome.window != nil))", &ok)
        let certificate = panel.debugCertificateView
        check(certificate.frame.width > 200 && (certificate.chromeView.layer?.borderWidth ?? 0) >= 1,
              "the certificate well is \(certificate.frame.width)pt wide with a \(certificate.chromeView.layer?.borderWidth ?? 0)pt edge", &ok)
        // From ~/.ssh lists the fixture's pairs, and only pairs.
        panel.debugChoices.debugClick(.existing)
        settle(shell)
        check(panel.debugMode == "existing", "the ~/.ssh choice left the form in \(panel.debugMode)", &ok)
        check(panel.debugExistingPicker.debugRowTitles == ["id_ed25519", "work_rsa"],
              "the ~/.ssh list reads \(panel.debugExistingPicker.debugRowTitles)", &ok)
        check(panel.debugFooterHint == "Pick a key pair and use it to save it.",
              "the ~/.ssh footer reads \(panel.debugFooterHint ?? "nothing")", &ok)
        panel.debugChoices.debugClick(.importKey)
        settle(shell)
        check(panel.debugMode == "import", "the import choice left the form in \(panel.debugMode)", &ok)
        hosts.debugCloseFormPanels()
        settle(shell)
    }

    // MARK: Renders

    private static func writeRenders(_ shell: MainSplitShellController, _ window: NSWindow) {
        guard let dir = ProcessInfo.processInfo.environment["FM_CONNECTION_FORMS_RENDER_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hosts = shell.workspace.hostsPanel
        func write(_ name: String, _ theme: HelmTheme) {
            settle(shell)
            ReviewTourLab.writeSplitShellPNG(shell, window: window,
                                             to: folder.appendingPathComponent("\(name)-\(theme.id).png"))
        }
        let restoreHeight = window.frame.height
        defer { resize(window, width: 1512, height: restoreHeight, shell) }
        let console = shell.workspace.console
        func writeConsole(_ name: String, _ theme: HelmTheme) {
            shell.workspace.navigator.show(.console)
            console.refreshSessionBand()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            write(name, theme)
        }
        let themes = [TasksSecretsHeroViewSelfTest.daylight, TasksSecretsHeroViewSelfTest.dusk,
                      HelmTheme.appTheme(id: "lavender") ?? TasksSecretsHeroViewSelfTest.daylight]
        for theme in themes {
            ThemeManager.shared.setTheme(theme)
            resize(window, width: 1512, height: 1180, shell)
            writeConsole("console-1-local", theme)
            let live = UUID()
            shell.workspace.hosts.sessions.register(hostID: live, label: "DEV Bastion", accentHex: "6cd7e3", state: .connected)
            writeConsole("console-2-live", theme)
            resize(window, width: 1100, height: 1180, shell)
            writeConsole("console-3-live-narrow", theme)
            shell.workspace.hosts.sessions.unregister(hostID: live)
            resize(window, width: 1512, height: 1180, shell)
            shell.workspace.navigator.show(.hosts)
            hosts.select(tab: .hosts)
            hosts.openNewHostPanel()
            write("host-1-empty", theme)
            if let panel = hosts.hostPanel {
                panel.debugType("DEV Bastion", into: panel.debugLabelField)
                panel.debugType("bastion.dev.example.test", into: panel.debugAddressField)
                panel.debugType("ops", into: panel.debugUsernameField)
                panel.debugKeyPicker.debugClickRow(1)
                write("host-2-filled", theme)
                panel.debugType("-bastion.dev.example.test", into: panel.debugAddressField)
                panel.debugType("grafana", into: panel.debugLabelField)
                _ = panel.savePanel()
                write("host-3-error", theme)
                panel.debugType("bastion.dev.example.test", into: panel.debugAddressField)
                panel.debugType("DEV Bastion", into: panel.debugLabelField)
                panel.debugSetSaving(true)
                write("host-4-saving", theme)
                panel.debugSetSaving(false)
            }
            hosts.debugCloseFormPanels()
            for (index, path) in KeyPathChoices.Path.allCases.enumerated() {
                hosts.openNewKeyPanel(preset: nil)
                settle(shell)
                guard let panel = hosts.keyPanel else { continue }
                panel.debugChoices.debugClick(path)
                panel.debugType("ops-prod-ed25519", into: panel.debugLabelField)
                write("key-\(index + 1)-\(path.rawValue)", theme)
                hosts.debugCloseFormPanels()
            }
            hosts.openNewKeyPanel(preset: nil)
            settle(shell)
            if let panel = hosts.keyPanel {
                panel.debugType("ops-prod-ed25519", into: panel.debugLabelField)
                panel.debugSetPendingKey(publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyNotARealKey ops-prod-ed25519",
                                         fingerprint: "SHA256:fixtureOnlyNotARealFingerprint0000000000")
                write("key-4-ready", theme)
            }
            hosts.debugCloseFormPanels()
            resize(window, width: 1100, height: 1180, shell)
            hosts.openNewHostPanel()
            write("host-5-narrow", theme)
            hosts.debugCloseFormPanels()
        }
        resize(window, width: 1512, shell)
    }

    // MARK: Helpers

    private static func settle(_ shell: WorkspaceShellController) {
        shell.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        shell.view.layoutSubtreeIfNeeded()
    }

    private static func resize(_ window: NSWindow, width: CGFloat, height: CGFloat? = nil,
                               _ shell: WorkspaceShellController) {
        var frame = window.frame
        frame.size.width = width
        if let height { frame.size.height = height }
        window.setFrame(frame, display: true)
        settle(shell)
    }

    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    private static func describe(_ color: NSColor?) -> String {
        guard let c = color?.usingColorSpace(.sRGB) else { return "none" }
        return String(format: "(%.3f, %.3f, %.3f)", c.redComponent, c.greenComponent, c.blueComponent)
    }
}

#endif
