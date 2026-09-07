// Manifest: the structural lock-gate guard - the second full-app audit's
// §2.7 proposal and §6.2's item, built in
// `fm/grandline-audit2-feature-enhancements`. Run with:
//
//   swift build && FM_RUN_LOCK_GATE_COVERAGE_TESTS=1 .build/debug/FirstmateCockpit
//
// ## Why a *structural* guard, when §5.1/§5.2 already have regression tests
//
// The half-themed class ("this destination does not follow the theme") died
// the release a structural test walked every destination instead of the ones
// a captain had happened to report. The lock-bypass class had no equivalent:
// one release shipped **three independent instances** of it (restore-under-
// lock, the incident popover, the tab-shortcut monitor), and #340 answered
// each with a targeted case plus `Audit2SecurityFixesSelfTest.test_gateCallSites`
// - a hardcoded seven-entry list of the sites that were *found*. A list of
// known sites cannot fail for a site nobody has thought of yet, which is
// precisely how instances two and three shipped alongside instance one.
//
// So this sweeps the two shapes that can reach the captain's data while the
// lock overlay is up, and requires every member of each to be either gated or
// explicitly exempt:
//
//   A. **`NSEvent` monitors.** A monitor bypasses the view hierarchy *and* the
//      menu system, so neither the opaque overlay nor
//      `AppDelegate.setContentMenusEnabled(false)` touches it. That is exactly
//      how §5.2 happened: the Tab menu the shortcuts replaced was disabled
//      while locked, and the monitor that replaced it inherited nothing.
//
//   B. **`NSPopover` owners.** A popover is its own window, layered above the
//      main window and therefore above the overlay (which is only a subview of
//      that window), so anything open when the lock fires stays readable and
//      writable - §5.1(b), where the incident card's note field appended to a
//      git-synced record over the lock screen.
//
// ## What "exempt" means here, and why it is not a rubber stamp
//
// A file may be excused only by naming, in the tables below, the *other* file
// and needle where its gate actually lives - and this suite then checks that
// claim. `DictationHotkey` is the honest case that forced this shape: its gate
// is real but lives at the consumer (`main.swift`'s `onDown` closure), because
// the monitor itself only reports a key transition. An allowlist would have
// let that entry rot the day someone deleted the gate it points at; a
// cross-checked claim fails instead.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum LockGateCoverageSelfTest {
    @discardableResult
    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("A: every NSEvent monitor is gated or verifiably excused", test_everyEventMonitorIsGated),
            ("B: every popover is dismissed on the way into the lock", test_everyPopoverIsLockDismissible),
            ("B: the gate closes popovers before it orders windows out", test_popoverClosePrecedesWindowSweep),
            ("B: a popover is closed, never ordered out", test_popoversAreClosedNotOrderedOut),
            ("the exemption tables name real code", test_exemptionsAreHonest),
        ]

        var ok = true
        for (name, body) in cases {
            if let failure = body() {
                ok = false
                print("FAIL \(name): \(failure)")
            } else {
                print("PASS \(name)")
            }
        }
        print(ok ? "LOCK GATE COVERAGE: OK" : "LOCK GATE COVERAGE: FAILURES")
        return ok
    }

    // MARK: Shape A - NSEvent monitors

    /// Files whose monitor is genuinely not a lock surface, or whose gate
    /// lives somewhere this file can point at. `gate` is checked against the
    /// named file, so a claim cannot outlive the code it claims.
    private struct MonitorExemption {
        let file: String
        /// Where the gate really is, as (file, needle). `nil` for a monitor
        /// that must not be gated at all - `reason` then carries why.
        let gate: (file: String, needle: String)?
        let reason: String
    }

    private static let monitorExemptions: [MonitorExemption] = [
        .init(file: "AppLock.swift", gate: nil,
              reason: "this is the lock itself - its monitor is what notices the captain is "
                  + "active and therefore decides when to lock. Gating it on the gate it "
                  + "feeds would be circular, and a locked app that stopped watching for "
                  + "activity could never re-arm its own idle timer."),
        .init(file: "CockpitTerminalView.swift", gate: nil,
              reason: "records a keystroke timestamp for `lastUserActivity` and routes "
                  + "drag-vs-selection inside one terminal view. It shows nothing, writes "
                  + "nothing, and reaches only a view that sits *under* the overlay - and "
                  + "the timestamp is what the SRE Lead/kube bridges read to avoid "
                  + "injecting while the captain types, so suppressing it while locked "
                  + "would make those bridges *less* careful, not more."),
        .init(file: "DictationHotkey.swift",
              gate: (file: "main.swift", needle: "allows(.dictation)"),
              reason: "the monitor only reports the hold/release transition; the gate is at "
                  + "the consumer, where the recording actually starts. Deliberate: "
                  + "`onUp` must stay ungated so a recording begun before the lock can "
                  + "still be stopped, or the microphone stays open."),
    ]

    private static func test_everyEventMonitorIsGated() -> String? {
        guard let files = SelfTestSources.appSourceFiles() else {
            return "could not locate the app's own source files - this check would silently pass"
        }
        var owners: [String] = []
        var offenders: [String] = []
        for file in files {
            guard let code = readCode(file) else { return "could not read \(file.lastPathComponent)" }
            guard code.contains("addLocalMonitorForEvents") || code.contains("addGlobalMonitorForEvents") else {
                continue
            }
            let name = file.lastPathComponent
            owners.append(name)
            if code.contains("AppLockGate") { continue }
            guard monitorExemptions.contains(where: { $0.file == name }) else {
                offenders.append(name)
                continue
            }
        }
        // The count floor is what stops a broken `appSourceFiles()`, a moved
        // directory or a renamed API from turning this into a check that
        // sweeps nothing and reports OK.
        guard owners.count >= 6 else {
            return "found only \(owners.count) files installing an NSEvent monitor - has the "
                + "app shrunk, or is this check looking in the wrong place?"
        }
        guard offenders.isEmpty else {
            return "these files install an NSEvent monitor without consulting AppLockGate and "
                + "are not on `monitorExemptions`: \(offenders.joined(separator: ", ")). A "
                + "monitor bypasses both the lock overlay and the disabled menus, so it needs "
                + "its own `AppLockedSurface` case (per the gate's add-a-case rule) - or an "
                + "exemption entry naming where its gate really lives."
        }
        return nil
    }

    // MARK: Shape B - popovers

    private struct PopoverExemption {
        let file: String
        let reason: String
    }

    /// Empty on purpose, and worth keeping that way: every popover in the app
    /// registers today. A future entry has to argue why a window layered above
    /// the lock overlay may stay there.
    private static let popoverExemptions: [PopoverExemption] = []

    private static func test_everyPopoverIsLockDismissible() -> String? {
        guard let files = SelfTestSources.appSourceFiles() else {
            return "could not locate the app's own source files - this check would silently pass"
        }
        var owners: [String] = []
        var offenders: [String] = []
        for file in files {
            guard let code = readCode(file) else { return "could not read \(file.lastPathComponent)" }
            guard code.contains("NSPopover()") else { continue }
            let name = file.lastPathComponent
            owners.append(name)
            // `ConsoleController`'s six-file family (GL-36) may satisfy this
            // from any of its files - `incidentPopover` is declared in the
            // core file and registered in `+Incident`.
            let family = name.hasPrefix("ConsoleController")
                ? files.filter { $0.lastPathComponent.hasPrefix("ConsoleController") }
                : [file]
            let familyCode = family.compactMap { readCode($0) }.joined(separator: "\n")
            if familyCode.contains("registerLockDismissiblePopover") { continue }
            if popoverExemptions.contains(where: { $0.file == name }) { continue }
            offenders.append(name)
        }
        guard owners.count >= 9 else {
            return "found only \(owners.count) files owning an NSPopover - has the app shrunk, "
                + "or is this check looking in the wrong place?"
        }
        guard offenders.isEmpty else {
            return "these popovers are never dismissed on the way into the lock, so one left "
                + "open when the lock fires stays readable and interactive above the overlay "
                + "(§5.1(b)): \(offenders.joined(separator: ", ")). Register them with "
                + "`AppLockGate.registerLockDismissiblePopover`."
        }
        return nil
    }

    /// The ordering `AppLockGate.setLocked` depends on, asserted rather than
    /// left to a comment: popovers get a real `performClose` first, so the
    /// window sweep that follows finds nothing of theirs to `orderOut` - which
    /// is the whole reason the two mechanisms are separate.
    private static func test_popoverClosePrecedesWindowSweep() -> String? {
        guard let code = readCode(named: "AppLockGate.swift") else {
            return "could not read AppLockGate.swift"
        }
        guard let close = code.range(of: "closeLockDismissiblePopovers()"),
              let sweep = code.range(of: "orderOutSecondaryWindows()") else {
            return "AppLockGate no longer calls both closeLockDismissiblePopovers() and "
                + "orderOutSecondaryWindows() - the lock's dismissal path has changed shape"
        }
        guard close.lowerBound < sweep.lowerBound else {
            return "AppLockGate orders secondary windows out before closing its popovers; a "
                + "popover whose window is ordered out behind its back keeps `isShown == true` "
                + "and its owner then declines to reopen it for the rest of the session"
        }
        return nil
    }

    /// A popover must never be handed to the window sweep. `orderOut` on one
    /// leaves it permanently broken - the mechanism
    /// `ConsoleController+Incident` documents and the reason
    /// `registerLockDismissiblePopover` exists at all.
    private static func test_popoversAreClosedNotOrderedOut() -> String? {
        guard let files = SelfTestSources.appSourceFiles() else {
            return "could not locate the app's own source files - this check would silently pass"
        }
        var offenders: [String] = []
        for file in files {
            guard let code = readCode(file) else { return "could not read \(file.lastPathComponent)" }
            for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.contains("registerSecondaryWindow") else { continue }
                // A provider handing back a popover's own window is the shape
                // that breaks it; `contentViewController.view.window` on a
                // popover is exactly that.
                if line.contains("Popover") || line.contains("popover") {
                    offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        guard offenders.isEmpty else {
            return "a popover is registered as a secondary *window*, which orders it out "
                + "rather than closing it: \(offenders.joined(separator: " | ")). Use "
                + "`registerLockDismissiblePopover`."
        }
        return nil
    }

    // MARK: The tables themselves

    /// An exemption that points at a gate which no longer exists is worse than
    /// no exemption: it reads as coverage. Every claim is resolved against the
    /// real file it names.
    private static func test_exemptionsAreHonest() -> String? {
        guard SelfTestSources.appSourceFiles() != nil else {
            return "could not locate the app's own source files - this check would silently pass"
        }
        for exemption in monitorExemptions {
            guard readCode(named: exemption.file) != nil else {
                return "`monitorExemptions` names \(exemption.file), which no longer exists - "
                    + "if that monitor is gone, drop its entry; if it moved, the new file needs "
                    + "checking rather than inheriting the excuse"
            }
            guard exemption.reason.count >= 40 else {
                return "\(exemption.file)'s exemption has no real reason written down"
            }
            guard let gate = exemption.gate else { continue }
            guard let gateCode = readCode(named: gate.file) else {
                return "\(exemption.file)'s exemption points at \(gate.file), which no longer exists"
            }
            guard gateCode.contains(gate.needle) else {
                return "\(exemption.file) is excused because \(gate.file) holds its gate "
                    + "(`\(gate.needle)`), but that gate is gone - so this monitor is now "
                    + "ungated with a stale note claiming otherwise"
            }
        }
        for exemption in popoverExemptions where exemption.reason.count < 40 {
            return "\(exemption.file)'s popover exemption has no real reason written down"
        }
        return nil
    }

    // MARK: Helpers

    /// Code only. Every check here greps for the very patterns these files -
    /// and this one - discuss at length in prose, so a comment mentioning
    /// `AppLockGate` must not read as a gate. The same comment-stripping
    /// `Audit2SecurityFixesSelfTest` needs, and for the same reason.
    private static func readCode(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func readCode(named name: String) -> String? {
        guard let files = SelfTestSources.appSourceFiles() else { return nil }
        guard let file = files.first(where: { $0.lastPathComponent == name }) else { return nil }
        return readCode(file)
    }
}

#endif
