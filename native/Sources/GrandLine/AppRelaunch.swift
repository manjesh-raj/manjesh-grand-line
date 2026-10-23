// Grand Line - native macOS app.
//
// R2-UX-08 of the second full review: "Relaunch Grand Line".
//
// Two Settings rows (Window layout, Interface text size) take full effect
// only on the next launch, and said so with nothing to press. This is the
// button's mechanism.
//
// A new copy cannot simply be opened next to this one: `SingleInstanceGuard`
// (GL-05) would see this process still running and hand the new copy's
// launch straight back to it. So a small detached shell waits for this pid to
// exit and only then opens the bundle again. It gives up after a minute, and
// it opens nothing unless this process really exited - a quit that is
// cancelled (an unsaved sheet, a "terminate later" reply) leaves one copy
// running and starts no second one.
//
// An unbundled `swift build` binary has no bundle to reopen, so the button is
// offered only where `canRelaunch` is true. A self-test or tour process never
// relaunches: `perform` is replaced by a recorder in a suite, and the real
// path refuses under `ExternalToolGuard.isActive` as a backstop.

import AppKit

enum AppRelaunch {

    /// The bundle to reopen, or nil for an unbundled binary.
    static var bundleURL: URL? {
        Bundle.main.bundleIdentifier == nil ? nil : Bundle.main.bundleURL
    }

    static var canRelaunch: Bool {
        #if FM_SELFTESTS
        if let forced = canRelaunchOverrideForTests { return forced }
        #endif
        return bundleURL != nil
    }

    #if FM_SELFTESTS
    /// Lets a suite measure the enabled button in an unbundled binary.
    static var canRelaunchOverrideForTests: Bool?
    #endif

    /// The helper's argv. The pid and the path are positional parameters, never
    /// spliced into the script, so a bundle path with a quote in it is still
    /// one argument.
    /// `attempts` polls 0.2s apart, so the default is a minute.
    static func helperArguments(pid: Int32, bundlePath: String, attempts: Int = 300) -> [String] {
        let script = "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt \(attempts) ]; do "
            + "/bin/sleep 0.2; i=$((i+1)); done; "
            + "/bin/kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open \"$2\""
        return ["-c", script, "grand-line-relaunch", String(pid), bundlePath]
    }

    /// What the button calls. Replaced by a recorder in a suite.
    static var perform: () -> Void = relaunch

    /// Start the helper, then quit.
    static func relaunch() {
        guard !ExternalToolGuard.isActive, let url = bundleURL else { return }
        let started = Subprocess.launchDetached(
            executable: "/bin/sh",
            arguments: helperArguments(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: url.path),
            label: "relaunch")
        guard started else { return }
        NSApp.terminate(nil)
    }
}
