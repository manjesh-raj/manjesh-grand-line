// Grand Line - native macOS app.
//
// Con-1's session band, the page's half (`ConsoleSessionBand` is the view and
// the router protocol). What the band says comes from state this page already
// holds - its tabs, the host it connected - and from the workspace's session
// registry, through `sessionRouter`.
//
// B2 (`fm/grandline-console-fixes`): the band is one line - where, and the
// live state in plain words. It no longer reads the shell's name and folder
// (the prompt shows both), so it no longer polls: it is refreshed when the
// session registry, the page's host or its router changes.

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
            let detail = [state, environment, host.subtitle, key.map { "key \($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            content = .init(title: host.label, detail: detail,
                            tileAccentHex: host.accentHex, currentHostID: host.id, showsThisMac: true)
        } else {
            content = .init(title: "This Mac", detail: Self.localDetail(liveSessions: chips.count),
                            tileAccentHex: nil, currentHostID: nil, showsThisMac: false)
        }
        sessionBand.update(content, chips: chips)
    }

    /// "no ssh sessions", "1 ssh session", "3 ssh sessions".
    static func localDetail(liveSessions: Int) -> String {
        switch liveSessions {
        case 0: return "no ssh sessions"
        case 1: return "1 ssh session"
        default: return "\(liveSessions) ssh sessions"
        }
    }
}
