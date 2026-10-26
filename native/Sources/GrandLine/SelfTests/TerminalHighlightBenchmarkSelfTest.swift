// Grand Line - native macOS app.
//
// T1's performance gate: a 100 MB log through a real terminal pane, with
// keyword highlighting off and on, may be at most 5% slower with it on.
//
//   swift build && FM_RUN_TERMINAL_HIGHLIGHT_BENCHMARK=1 .build/debug/GrandLine; echo $?
//
// Optional: `FM_BENCH_MB` (default 100), `FM_BENCH_RUNS` per mode (default 3).
// The numbers that matter come from an optimised build of the same suites:
//
//   swift build -c release -Xswiftc -DFM_SELFTESTS --build-path .build-bench
//   FM_RUN_TERMINAL_HIGHLIGHT_BENCHMARK=1 .build-bench/release/GrandLine
//
// **A benchmark, not a suite.** It is an `FM_RUN_*` flag so the process gets
// every self-test isolation (`ProcessMode`), and it is in `run-all-tests.sh`'s
// `SKIP_FLAGS`, so no run ever pays for it: a wall-clock ratio on a shared CI
// runner measures the runner, and a 5% budget there would be noise. The
// deterministic halves of the same budget - an unchanged screen scans
// nothing, the memo keeps a scrolling screen to its new lines, the address
// pattern never sees a timestamp - are asserted on every run by
// `TerminalKeywordHighlightSelfTest` and `TerminalKeywordMatcherSelfTest`.
// The numbers this prints go in the PR that changes the engine.
//
// What one run does, and why it is shaped like the app:
//
//  - A real `CockpitTerminalView` in a real (off-screen) window, the size of a
//    Console tab, themed and with the highlighter attached exactly as
//    `ConsoleController.makeTerminal` attaches it.
//  - The log is fed in 64 KB chunks through `feed(byteArray:)`, the same entry
//    point a PTY read reaches.
//  - A full `draw(_:)` pass runs whenever 1/60 s of wall time has passed,
//    which is SwiftTerm's own foreground display cadence. Rows that scroll
//    past between frames are never drawn, in the app or here.
//  - Modes alternate (off, on, off, on, ...) so drift in the machine's state
//    lands on both, and the medians are compared.
//
// The log is synthetic and deterministic: timestamped service lines at every
// level, IPv4 and MAC addresses, prose, program-coloured test and compiler
// output and a little non-ASCII, with a unique id on nearly every line so no
// cache can answer a row it has not really seen.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import SwiftTerm

enum TerminalHighlightBenchmarkSelfTest {

    static let maximumSlowdown = 0.05

    static func run() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let megabytes = max(1, Int(env["FM_BENCH_MB"] ?? "") ?? 100)
        let runs = max(1, Int(env["FM_BENCH_RUNS"] ?? "") ?? 3)
        print("TerminalHighlightBenchmarkSelfTest: \(megabytes) MB, \(runs) run(s) per mode")

        let log = makeLog(bytes: megabytes * 1_048_576)
        let lines = log.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        print("  log: \(log.count) bytes, \(lines) lines")

        var times: [Bool: [Double]] = [false: [], true: []]
        // `FM_BENCH_MODES=on` (or `off`) runs one mode only, for profiling.
        let modes: [Bool] = env["FM_BENCH_MODES"] == "on" ? [true]
            : env["FM_BENCH_MODES"] == "off" ? [false] : [false, true]
        for index in 0..<(runs * modes.count) {
            let enabled = modes[index % modes.count]
            let result = autoreleasepool { feed(log, highlighting: enabled) }
            times[enabled, default: []].append(result.seconds)
            print(String(format: "  run %d  %@  %.2f s  %.1f MB/s  %d frames  %d rows scanned",
                         index + 1, enabled ? "on " : "off", result.seconds,
                         Double(log.count) / 1_048_576 / result.seconds, result.frames, result.scans))
        }

        let off = median(times[false] ?? [])
        let on = median(times[true] ?? [])
        let slowdown = (on - off) / off
        print(String(format: "  median off %.2f s, on %.2f s: %+.2f%% (budget %.0f%%)",
                     off, on, slowdown * 100, maximumSlowdown * 100))
        let ok = slowdown <= maximumSlowdown
        print(ok ? "TerminalHighlightBenchmarkSelfTest: within budget" : "TerminalHighlightBenchmarkSelfTest: OVER BUDGET")
        return ok
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    private static func feed(_ log: [UInt8], highlighting: Bool) -> (seconds: Double, frames: Int, scans: Int) {
        let size = NSSize(width: 1100, height: 700)
        let window = OffScreenProbe.window(size: size)
        let view = CockpitTerminalView(frame: NSRect(origin: .zero, size: size))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        window.contentView = view
        var settings = KeywordHighlightSettings.defaults
        settings.enabled = highlighting
        let highlighter = TerminalKeywordHighlighter(settings: settings, theme: .dusk)
        highlighter.attach(view)
        HelmTheme.dusk.apply(to: view)
        view.getTerminal().changeScrollback(10_000)
        view.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { window.orderOut(nil) }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return (0, 0, 0) }
        let frameInterval = 1.0 / 60.0
        let chunk = 65_536
        var frames = 0
        let start = CFAbsoluteTimeGetCurrent()
        var lastFrame = start
        var offset = 0
        while offset < log.count {
            let end = min(offset + chunk, log.count)
            view.feed(byteArray: log[offset..<end])
            offset = end
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastFrame >= frameInterval || offset == log.count {
                autoreleasepool { view.cacheDisplay(in: view.bounds, to: rep) }
                frames += 1
                lastFrame = now
            }
        }
        let seconds = CFAbsoluteTimeGetCurrent() - start
        if highlighting {
            print(String(format: "         matching took %.1f ms of it", highlighter.debugMatchSeconds * 1000))
        }
        return (seconds, frames, view.rowHighlightScans)
    }

    /// A deterministic log of about `bytes` bytes.
    static func makeLog(bytes: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes + 512)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: (seed >> 33) & 0x7FFF_FFFF)
        }
        let services = ["api", "db", "cache", "worker", "net", "auth", "scheduler", "billing"]
        var line = 0
        while out.count < bytes {
            line += 1
            let r = next()
            let ts = String(format: "2026-10-26T%02d:%02d:%02d.%03dZ",
                            (line / 3_600_000) % 24, (line / 60_000) % 60, (line / 1_000) % 60, line % 1_000)
            let svc = services[r % services.count]
            let text: String
            switch r % 16 {
            case 0, 1, 2:
                text = "\(ts) INFO  [\(svc)] GET /v1/items/\(next() % 100_000) 200 in \(next() % 900)ms from 10.\(next() % 256).\(next() % 256).\(next() % 256)"
            case 3, 4:
                text = "\(ts) DEBUG [\(svc)] query took \(next() % 400)ms rows=\(next() % 5_000) plan=index_scan id=\(String(next(), radix: 16))"
            case 5:
                text = "\(ts) WARN  [\(svc)] cache miss ratio \(next() % 100)%, retrying shard \(next() % 64) after timeout"
            case 6:
                text = "\(ts) ERROR [\(svc)-\(next() % 16)] job \(String(next(), radix: 16)) failed: connection refused (attempt \(next() % 5))"
            case 7:
                text = String(format: "%@ INFO  [net] eth0 link up, mac 3c:22:fb:%02x:%02x:%02x, mtu 1500",
                              ts, next() % 256, next() % 256, next() % 256)
            case 8, 9:
                text = "   Compiling module \(next() % 300) of 300: Sources/Feature\(next() % 90)/Handler\(next() % 40).swift"
            case 10:
                text = "\u{1b}[32m\u{2713}\u{1b}[0m test_case_\(next() % 9_000) passed (\(next() % 300)ms)"
            case 11:
                text = "\u{1b}[1;31merror\u{1b}[0m: build script exited with status \(next() % 3) in target Grand\(next() % 50)"
            case 12:
                text = "\(ts) INFO  [\(svc)] request \(String(next(), radix: 16)) completed OK \u{2192} done in \(next() % 60)s"
            case 13:
                text = "\(ts) INFO  [\(svc)] " + String(repeating: "payload=\(String(next(), radix: 36)) ", count: 6)
            case 14:
                text = "the deployment of revision \(next() % 9_999) rolled out to every region without incident"
            default:
                text = "\(ts) NOTICE [\(svc)] healthy, \(next() % 64) peers, uptime \(next() % 99_999)s"
            }
            out.append(contentsOf: Array(text.utf8))
            out.append(0x0D)
            out.append(0x0A)
        }
        return out
    }
}

#endif
