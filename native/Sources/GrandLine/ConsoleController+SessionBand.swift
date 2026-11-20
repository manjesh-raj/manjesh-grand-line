// Grand Line - native macOS app.
//
// Con-1's session band, the page's half (`ConsoleSessionBand` is the view and
// the router protocol). What the band says comes from state this page already
// holds - its tabs, the host it connected - and from the workspace's session
// registry, through `sessionRouter`.
//
// The shell and folder line reads the current tab's own shell process: its
// name with `proc_name` and its working directory with `proc_pidinfo`. Both
// are cheap reads of a child this app started. The line is refreshed when
// the tab changes, when the page comes on screen, when a shell reports its
// folder (OSC 7), and every two seconds while the page is visible - a timer
// that stops whenever the page is out of sight (GL-13).

import AppKit

extension ConsoleController {

    /// Rebuild the band's words and chips. Cheap, and a no-op until the page
    /// shows in the sidebar layout.
    func refreshSessionBand() {
        guard isViewLoaded, drawsSidebarLayout else { return }
        let registry = sessionRouter?.bandSessions
        let chips = registry.map(ConsoleSessionBand.chips(from:)) ?? []
        let content: ConsoleSessionBand.Content
        if let host = sessionHost, !isFirstmateConsole {
            let session = registry?.session(for: host.id)
            let environment = HostEnvironmentPicker.environment(for: host.group)?.title
            let state = session.map { $0.isConnected ? "Connected" : "Restored, not connected" } ?? "Not connected"
            let key = host.keyID.flatMap { id in keyStore.keys.first { $0.id == id }?.label }
            content = .init(kicker: [environment, "ssh session"].compactMap { $0 }.joined(separator: " \u{00B7} "),
                            title: "\(host.label) \u{00B7} \(state)",
                            subtitle: host.subtitle + (key.map { " \u{00B7} key \($0)" } ?? ""),
                            tileAccentHex: host.accentHex, currentHostID: host.id, showsThisMac: true)
        } else {
            content = .init(kicker: "This Mac \u{00B7} local shells",
                            title: Self.localTitle(tabs: tabs.count, liveSessions: chips.count),
                            subtitle: localShellLine(),
                            tileAccentHex: nil, currentHostID: nil, showsThisMac: false)
        }
        sessionBand.update(content, chips: chips)
    }

    /// "3 tabs · 1 live session", or "1 tab, no live sessions".
    static func localTitle(tabs: Int, liveSessions: Int) -> String {
        let tabWords = tabs == 1 ? "1 tab" : "\(tabs) tabs"
        switch liveSessions {
        case 0: return "\(tabWords), no live sessions"
        case 1: return "\(tabWords) \u{00B7} 1 live session"
        default: return "\(tabWords) \u{00B7} \(liveSessions) live sessions"
        }
    }

    /// The current tab's shell and folder ("zsh · ~/projects"), or its name
    /// when it is not a shell this page can read.
    func localShellLine() -> String {
        guard let tab = currentTab else { return "No tab open" }
        guard case .shell = tab.launch, let process = tab.terminal.process, process.running,
              process.shellPid > 0 else { return tab.name }
        let pid = process.shellPid
        let name = Self.processName(pid) ?? tab.name
        guard let folder = Self.workingDirectory(ofProcess: pid) else { return name }
        return "\(name) \u{00B7} \((folder as NSString).abbreviatingWithTildeInPath)"
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func workingDirectory(ofProcess pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    func startSessionBandTimer() {
        sessionBandTimer?.invalidate()
        guard drawsSidebarLayout else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.pageIsOutOfSight, self.view.window != nil else { return }
            self.refreshSessionBand()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        sessionBandTimer = timer
    }
}
