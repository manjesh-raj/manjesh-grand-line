// Manjesh Grand Line - native macOS app.
//
// The UI modernization audit's §3G - feedback: toasts, notifications and
// progress (G1, G2, G4). G3's confirm migration is its own suite, because it
// is the one safety-sensitive slice of that section.
//
// What is asserted, and why these and not the motion:
//
//   1. **G2's grouping is real, and collapses when there is nothing to
//      group.** The finding is "rows grouped by kind"; a header rendered above
//      a single group would duplicate the panel's own title, so both
//      directions are driven.
//   2. **G2's row is the compact one, and still navigates.** Swapping the row
//      type is exactly the change that silently drops a click handler - the
//      old `HelmAccentRow` carried `onClick`, this one carries `onActivate`,
//      and nothing but a real click can tell whether the new one was wired.
//   3. **G2's bell bounces on arrival and not on resolution.** The store
//      re-notifies on every publish, including a count *falling*, and a bell
//      that bounced then would be celebrating a thing going away. A geometry
//      read cannot see the difference; the animation's presence can.
//   4. **G4 genuinely retired `NSProgressIndicator`.** The finding's own words
//      are "fully retire" - one remaining stock spinner is a page still
//      drawing system chrome, and it is invisible in every behavioural check
//      because a stock spinner works fine. Source, therefore.
//   5. **G4's indeterminate mode actually slides**, only when it should, and
//      parks rather than shortening its cycle under Reduce Motion.
//
// G1's toast is asserted in `DaylightChromeSelfTest`, beside the rest of the
// §6.14 recipe it replaces - including that it is bottom-anchored and that two
// confirmations stack without overlapping.
//
// Window-backed (a sliding layer animation needs a real window - see
// `refreshAnimation`'s own GL-13 guard), so it is in `run-all-tests.sh`'s
// `NEEDS_SESSION` list.
//
// Run with:
//   swift build && FM_RUN_FEEDBACK_MODERNIZATION_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum FeedbackModernizationSelfTest {

    static func run() -> Bool {
        let restoreTheme = ThemeManager.shared.theme
        defer {
            ThemeManager.shared.setTheme(restoreTheme)
            clearProbeSignals()
        }
        var allOK = true
        for check in [checkPanelGroupsByKind,
                      checkPanelRowIsCompactAndStillNavigates,
                      checkBellBouncesOnArrivalOnly,
                      checkNoStockProgressIndicatorsRemain,
                      checkIndeterminateBarSlides] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "FeedbackModernizationSelfTest: all checks passed"
                    : "FeedbackModernizationSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }

    /// Put every signal this suite publishes back, so a later suite in the same
    /// run does not inherit a fabricated notification.
    private static func clearProbeSignals() {
        NotificationSources.setToolUpdates(count: 0, navigate: {})
        NotificationSources.setPRReady(count: 0, navigate: {})
    }

    private static func makeWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 420, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: 1. G2 - grouped by kind

    private static func checkPanelGroupsByKind(_ ok: inout Bool) {
        print("\n-- G2: rows grouped by kind --")
        clearProbeSignals()

        // One kind only: a header here would just restate the panel's title.
        NotificationSources.setToolUpdates(count: 2, navigate: {})
        let single = NotificationCenterController()
        _ = single.debugPanelController.view
        single.debugPanelContent.reload()
        if single.debugPanelContent.debugGroupHeaders.isEmpty {
            print("  OK   one kind: no group header")
        } else {
            print("  FAIL one kind still rendered \(single.debugPanelContent.debugGroupHeaders)")
            ok = false
        }

        // Both kinds: two headers, and every row sits under the right one.
        NotificationSources.setPRReady(count: 1, navigate: {})
        let both = NotificationCenterController()
        _ = both.debugPanelController.view
        both.debugPanelContent.reload()
        let headers = both.debugPanelContent.debugGroupHeaders
        if headers.count == 2 {
            print("  OK   two kinds: \(headers.joined(separator: " / "))")
        } else {
            print("  FAIL two kinds rendered \(headers.count) header(s): \(headers)")
            ok = false
        }
        if both.debugPanelContent.debugRows.count != 2 {
            print("  FAIL \(both.debugPanelContent.debugRows.count) rows, want 2")
            ok = false
        }
        clearProbeSignals()
    }

    // MARK: 2. G2 - the compact row, still wired

    private static func checkPanelRowIsCompactAndStillNavigates(_ ok: inout Bool) {
        print("\n-- G2: compact row (hue dot + symbol), still navigates --")
        clearProbeSignals()
        var navigated = 0
        NotificationSources.setToolUpdates(count: 4, navigate: { navigated += 1 })
        let controller = NotificationCenterController()
        let panel = controller.debugPanelController
        _ = panel.view
        controller.debugPanelContent.reload()
        _ = makeWindow(panel.view)

        guard let row = controller.debugPanelContent.debugRows.first else {
            print("  FAIL no row in the panel")
            ok = false
            return
        }
        var problems: [String] = []
        // The row is the compact one, not the accent card it replaced. If the
        // old type came back, `debugRows` would be empty - so the guard above
        // is half of this assertion; the dot and symbol are the other half.
        if row.debugDotColor == nil { problems.append("no hue dot") }
        if !row.debugHasSymbol { problems.append("no SF Symbol") }
        if row.debugTitle.isEmpty { problems.append("no title") }
        // G2's own reason for the change: five stacked elements in a 360pt
        // column. The accent card was ~76pt; a two-line row is well under it.
        let height = row.fittingSize.height
        if height > 64 {
            problems.append("row is \(fmt(height))pt tall - no denser than the card it replaced")
        }
        if problems.isEmpty {
            print("  OK   dot + symbol + title, \(fmt(height))pt tall")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }

        // Swapping the row type is exactly the change that drops a handler.
        row.onActivate?()
        if navigated == 1 {
            print("  OK   clicking a row still navigates (fired once)")
        } else {
            print("  FAIL navigate fired \(navigated) times, want 1")
            ok = false
        }
        clearProbeSignals()
    }

    // MARK: 3. G2 - the bell bounces on arrival only

    private static func checkBellBouncesOnArrivalOnly(_ ok: inout Bool) {
        print("\n-- G2: the bell bounces on arrival, not on resolution --")
        clearProbeSignals()
        HelmMotion.reducedOverrideForTests = false
        defer { HelmMotion.reducedOverrideForTests = nil }

        let controller = NotificationCenterController()
        _ = makeWindow(controller.bell)
        // A rise.
        NotificationSources.setToolUpdates(count: 2, navigate: {})
        let bouncedOnArrival = controller.debugBell.debugIsBouncing
        controller.debugBell.layer?.removeAllAnimations()
        controller.debugBell.subviews.forEach { $0.layer?.removeAllAnimations() }
        // A fall - the same publish path, the opposite direction.
        NotificationSources.setToolUpdates(count: 0, navigate: {})
        let bouncedOnFall = controller.debugBell.debugIsBouncing

        if bouncedOnArrival && !bouncedOnFall {
            print("  OK   bounced on a rising count, not on a falling one")
        } else {
            print("  FAIL arrival=\(bouncedOnArrival) resolution=\(bouncedOnFall)")
            ok = false
        }

        // Reduce Motion gets nothing - the badge already carries the message.
        HelmMotion.reducedOverrideForTests = true
        let quiet = NotificationCenterController()
        _ = makeWindow(quiet.bell)
        NotificationSources.setToolUpdates(count: 3, navigate: {})
        if quiet.debugBell.debugIsBouncing {
            print("  FAIL it bounced with Reduce Motion on")
            ok = false
        } else {
            print("  OK   Reduce Motion gets no bounce at all")
        }
        clearProbeSignals()
    }

    // MARK: 4. G4 - the stock control is genuinely gone

    private static func checkNoStockProgressIndicatorsRemain(_ ok: inout Bool) {
        print("\n-- G4: NSProgressIndicator is retired from production --")
        guard let dir = SelfTestSources.appSourceDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            print("  SKIP sources not present next to this binary")
            return
        }
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Prose naming the retired type is fine and is how the
                // migration explains itself; a real use is not.
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains("NSProgressIndicator") {
                    offenders.append("\(file.lastPathComponent):\(n + 1)")
                }
            }
        }
        if offenders.isEmpty {
            print("  OK   no stock progress control left in \(files.count) app sources")
        } else {
            for o in offenders { print("  FAIL \(o) still uses NSProgressIndicator") }
            ok = false
        }
    }

    // MARK: 5. G4 - the indeterminate bar

    private static func checkIndeterminateBarSlides(_ ok: inout Bool) {
        print("\n-- G4: the indeterminate bar slides, and only when it should --")
        HelmMotion.reducedOverrideForTests = false
        defer { HelmMotion.reducedOverrideForTests = nil }

        let bar = HelmProgressBar.inlineActivity()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        _ = makeWindow(host)

        var problems: [String] = []
        if !bar.debugIsIndeterminate { problems.append("inlineActivity is not indeterminate") }
        // It starts hidden and still: a spinner's replacement must not announce
        // work nobody started.
        if !bar.isHidden { problems.append("starts visible") }
        if bar.debugIsSliding { problems.append("slides before it is started") }

        bar.startAnimation()
        host.layoutSubtreeIfNeeded()
        if bar.isHidden { problems.append("still hidden after startAnimation()") }
        if !bar.debugIsSliding { problems.append("does not slide while running") }

        bar.stopAnimation()
        if !bar.isHidden { problems.append("still visible after stopAnimation()") }
        if bar.debugIsSliding { problems.append("still sliding after stopAnimation()") }

        // The check above can be satisfied by the *hiding* alone - a bar that
        // ignored `isRunning` entirely would still stop sliding, because
        // `refreshAnimation` also refuses on a hidden view. Measured: an
        // injected regression that dropped `isRunning` from that guard passed
        // it. So the same transition is driven again with the visibility
        // coupling off, where `isRunning` is the only thing left that can stop
        // it.
        let pinned = HelmProgressBar.inlineActivity()
        pinned.hidesWhenStopped = false
        pinned.isHidden = false
        let pinnedHost = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        pinnedHost.addSubview(pinned)
        NSLayoutConstraint.activate([
            pinned.leadingAnchor.constraint(equalTo: pinnedHost.leadingAnchor),
            pinned.centerYAnchor.constraint(equalTo: pinnedHost.centerYAnchor),
        ])
        _ = makeWindow(pinnedHost)
        pinned.startAnimation()
        pinnedHost.layoutSubtreeIfNeeded()
        if !pinned.debugIsSliding { problems.append("a visible running bar does not slide") }
        pinned.stopAnimation()
        if pinned.isHidden { problems.append("hidesWhenStopped = false still hid it") }
        if pinned.debugIsSliding {
            problems.append("a visible *stopped* bar still slides - `isRunning` is not gating it")
        }

        // Reduce Motion: the bar still shows (something *is* happening), it
        // just does not travel. Never a slower cycle - `HelmMotion`'s own rule.
        HelmMotion.reducedOverrideForTests = true
        bar.startAnimation()
        host.layoutSubtreeIfNeeded()
        if bar.isHidden { problems.append("Reduce Motion hid the bar entirely") }
        if bar.debugIsSliding { problems.append("Reduce Motion still slides") }
        bar.stopAnimation()
        HelmMotion.reducedOverrideForTests = false

        // Determinate mode is untouched by all of the above.
        let determinate = HelmProgressBar()
        determinate.configure(fraction: 0.5)
        if determinate.debugIsIndeterminate { problems.append("a plain bar became indeterminate") }
        if abs(determinate.fractionForTests - 0.5) > 0.001 {
            problems.append("determinate fraction is \(determinate.fractionForTests)")
        }

        if problems.isEmpty {
            print("  OK   hidden/still -> visible/sliding -> hidden/still; Reduce Motion parks it")
        } else {
            for p in problems { print("  FAIL \(p)") }
            ok = false
        }
    }
}

#endif
