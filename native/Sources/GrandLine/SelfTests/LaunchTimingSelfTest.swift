// Grand Line - native macOS app.
//
// R2-PERF-01: the launch path's signposts, read in process.
//
// `LaunchSignposts.swift` puts an interval on every store the app delegate
// builds, on `WorkspaceShellController.init` and on each layout's `loadView`.
// The review's measurement is the captain's: Instruments' App Launch template
// against real data. This repository cannot launch the app to take it (the
// app shares one bundle identity with the captain's running copy, AGENTS.md),
// so this suite takes the closest measurement it can without a launch:
//
//   - the real `AppDelegate`, built as `main.swift` builds it, so every store
//     its properties initialise runs through its own interval.
//   - its real `appShell`, for each window layout in turn.
//   - an `OffScreenProbe` window given that shell, the default frame and one
//     display pass - the first frame, as far as a process with no composited
//     window can see one.
//
// What it is not: process start (dyld, the Swift runtime, `NSApplication`)
// is before any of this and is not counted, the window is never composited,
// and the stores are this suite's own scratch ones, empty. **Its numbers are
// not the real-data baseline** and `native/MANUAL-CHECKS.md` section 19 says
// so beside them. They are a floor and a trend.
//
// **One launch per process.** A second `AppDelegate` in the same process
// shares it with the first one's shell, observers and caches, and measured
// slower each round (431, then 466 ms), which is not what a warm launch is.
// A warm launch is a new process with the disk cache warm, so the suite
// launches once, in the layout `FM_LAUNCH_TIMING_LAYOUT` names (`sidebar`,
// the default, or `floatingBar`), and a warm figure is a second run of it.
//
// It asserts no time, because a CI runner is not this Mac. It asserts that
// every launch interval was recorded each time, so a store that loses its
// interval, or a recorder that stops recording, fails here. It also prints
// each round's numbers against the review's targets (first frame under
// 400 ms warm, no store `init` over 10 ms).
//
// Window-backed: listed in `NEEDS_SESSION` in `Scripts/run-all-tests.sh`.
//
// Run with:
//   swift build && FM_RUN_LAUNCH_TIMING_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum LaunchTimingSelfTest {

    /// Which layout to launch: `sidebar` (the default) or `floatingBar`.
    static let layoutVariable = "FM_LAUNCH_TIMING_LAYOUT"

    /// The review's pass criteria (MANUAL-CHECKS.md section 19).
    static let firstFrameTarget: Double = 400
    static let storeInitTarget: Double = 10

    /// Every interval a launch passes through before its first frame, as
    /// `LaunchPathSelfTest` lists them in the sources.
    static let storeIntervals = ["HostStore.init", "SSHKeyStore.init", "SnippetStore.init", "ShiftStore.init",
                                 "DictationStore.init", "CommandLibraryStore.init", "ScheduleStore.init",
                                 "DocsRunbookStore.init", "CodePreviewStore.init", "NotebookStore.init",
                                 "ReadingListStore.init", "StickyBoardStore.init", "LogAnalyzerStore.init"]

    struct Launch {
        let layout: WorkspaceLayout
        let firstFrame: Double
        let intervals: [(name: String, milliseconds: Double)]
        /// The launch's own steps, in order, and what each cost - what the
        /// first frame is made of beyond the named intervals.
        let phases: [(name: String, milliseconds: Double)]
    }

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedLayout = AppSettings.shared.workspaceLayout
        defer { AppSettings.shared.workspaceLayout = savedLayout }
        defer { LaunchSignposts.debugRecording = nil }

        var ok = true
        let layout = WorkspaceLayout(rawValue: ProcessInfo.processInfo.environment[layoutVariable] ?? "") ?? .sidebar
        let launch = launch(layout)

        let stores = launch.intervals.filter { $0.name.hasSuffix(".init") && $0.name != "WorkspaceShellController.init" }
        let slowest = stores.max { $0.milliseconds < $1.milliseconds }
        let shellInit = launch.intervals.first { $0.name == "WorkspaceShellController.init" }?.milliseconds ?? 0
        let loadView = launch.intervals.first { $0.name.hasSuffix(".loadView") }?.milliseconds ?? 0
        print(String(format: "LaunchTimingSelfTest: %@, macOS %@, debug build, scratch stores (empty), in process",
                     machine(), ProcessInfo.processInfo.operatingSystemVersionString))
        print(String(format: "  %@: first frame %.1f ms (%@ 400), WorkspaceShellController.init %.1f ms, loadView %.1f ms, "
                     + "slowest store %@ %.2f ms (%@ 10)",
                     layout.rawValue, launch.firstFrame, launch.firstFrame < firstFrameTarget ? "under" : "OVER",
                     shellInit, loadView, slowest?.name ?? "-", slowest?.milliseconds ?? 0,
                     (slowest?.milliseconds ?? 0) < storeInitTarget ? "under" : "OVER"))
        print("    phases: " + launch.phases.map { String(format: "%@ %.1f ms", $0.name, $0.milliseconds) }
            .joined(separator: ", "))
        for store in storeIntervals {
            guard let time = launch.intervals.first(where: { $0.name == store })?.milliseconds else { continue }
            print(String(format: "    %@ %.2f ms", store, time))
        }

        let names = Set(launch.intervals.map(\.name))
        for store in storeIntervals where !names.contains(store) {
            fail("\(layout.rawValue): \(store) recorded no interval", &ok)
        }
        let loadViewName = layout == .sidebar ? "MainSplitShellController.loadView" : "AppShellController.loadView"
        check(names.contains("WorkspaceShellController.init") && names.contains(loadViewName),
              "\(layout.rawValue): the shell's intervals were not recorded (\(names.sorted()))", &ok)
        check(launch.firstFrame > 0 && launch.firstFrame >= shellInit + loadView,
              "\(layout.rawValue): a first frame of \(launch.firstFrame) ms is shorter than the intervals inside it", &ok)
        print(ok ? "LaunchTimingSelfTest: all checks passed" : "LaunchTimingSelfTest: FAILED")
        return ok
    }

    /// One launch: the delegate, its shell and the first display, timed.
    private static func launch(_ layout: WorkspaceLayout) -> Launch {
        AppSettings.shared.workspaceLayout = layout
        LaunchSignposts.debugRecording = []
        let start = DispatchTime.now().uptimeNanoseconds
        var phases: [(name: String, milliseconds: Double)] = []
        var mark = start
        func phase(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            phases.append((name, Double(now - mark) / 1_000_000))
            mark = now
        }
        let delegate = AppDelegate()
        phase("AppDelegate()")
        let shell = delegate.appShell
        phase("appShell")
        let window = OffScreenProbe.window(width: 1220, height: 720,
                                           styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                                       .fullSizeContentView])
        if layout == .floatingBar { WindowChromeFusion.apply(to: window) }
        phase("window")
        window.contentViewController = shell
        phase("contentViewController")
        window.contentMinSize = AppDelegate.minContentSize
        window.setFrame(AppDelegate.defaultWindowFrame(), display: false)
        window.followHelmTheme()
        phase("frame")
        window.orderFront(nil)
        phase("orderFront")
        window.displayIfNeeded()
        CATransaction.flush()
        phase("display")
        let firstFrame = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let intervals = LaunchSignposts.debugRecording ?? []
        LaunchSignposts.debugRecording = nil
        window.orderOut(nil)
        window.contentViewController = nil
        return Launch(layout: layout, firstFrame: firstFrame, intervals: intervals, phases: phases)
    }

    private static func machine() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        return String(cString: name)
    }
}

#endif
