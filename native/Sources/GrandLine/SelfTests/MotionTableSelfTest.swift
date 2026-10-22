// Grand Line - native macOS app.
//
// P8 of the Grand Line vs Automic Vault polish report: one motion table,
// written down, with a guard. The table itself is in `HelmMotion.swift`'s
// header; this suite is what keeps it true.
//
// Four things are asserted:
//
// 1. **The table's three values**, and that they are ordered (a state change
//    is quicker than a move, which is quicker than an arrival).
// 2. **No literal UI duration outside `HelmMotion`.** The report counted nine
//    different durations in use, two of them tokens, and nineteen literals
//    outside the motion file. A literal is how the tenth one arrives. The
//    allowlist below is the place a genuine exception says why, and an entry
//    that no longer matches anything fails too, so the list cannot rot into a
//    blanket licence.
// 3. **No `allowsImplicitAnimation` used to animate a layer property.**
//    Measured on macOS 26.7: inside that flag, AppKit's view-backed layer
//    delegate supplies no action for `backgroundColor`, `borderColor`,
//    `borderWidth`, `shadowOpacity` or `transform`. Every one of the app's
//    hover fills, presses and spring rises was written that way and landed in
//    a single frame. The flag still animates a *layout* change (frames,
//    through `bounds` and `position`), so the three layout slides keep it, by
//    name. Anything else uses `HelmMotion.animateLayers(on:)`.
// 4. **`animateLayers` itself**, on a plain `CALayer` with no window: it eases
//    a changed property, leaves an unchanged one alone, picks up an entrance's
//    start state, and lands the end state with nothing animating under Reduce
//    Motion. `HoverPressEasingSelfTest` asserts the same thing on the real
//    components inside a window; this is the half the blocking CI lane runs.
//
// Run with:
//   swift build && FM_RUN_MOTION_TABLE_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: source text and standalone layers, no window.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum MotionTableSelfTest {

    static func run() -> Bool {
        var ok = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        checkTheTable(&ok)
        checkTheTimingDefault(&ok)
        if let sources = loadSources() {
            checkNoLiteralDurations(sources, &ok)
            checkImplicitAnimationIsLayoutOnly(sources, &ok)
        } else {
            print("  SKIP the app's sources are not next to this binary - the two source guards did not run")
        }
        checkAnimateLayersEasesAChange(&ok)
        checkAnimateLayersPicksUpAnEntrance(&ok)
        checkAnimateLayersUnderReduceMotion(&ok)
        print(ok ? "MotionTableSelfTest: all checks passed" : "MotionTableSelfTest: FAILED")
        return ok
    }

    // MARK: 1. The table

    private static func checkTheTable(_ ok: inout Bool) {
        check(HelmMotion.stateDuration == 0.12, "the state duration is \(HelmMotion.stateDuration)s, the table says 0.12", &ok)
        check(HelmMotion.moveDuration == 0.18, "the move duration is \(HelmMotion.moveDuration)s, the table says 0.18", &ok)
        check(HelmMotion.springDuration == 0.25, "the spring duration is \(HelmMotion.springDuration)s, the table says 0.25", &ok)
        check(HelmMotion.stateDuration < HelmMotion.moveDuration && HelmMotion.moveDuration < HelmMotion.springDuration,
              "the three durations are not ordered state < move < spring", &ok)
        // The named constants the rest of the app reads must resolve to a
        // table row, not to a number of their own.
        let rows: Set<TimeInterval> = [HelmMotion.stateDuration, HelmMotion.moveDuration, HelmMotion.springDuration]
        let named: [(String, TimeInterval)] = [
            ("HelmButton.stateChangeDuration", HelmButton.stateChangeDuration),
            ("HelmAccentRow.actionRevealDuration", HelmAccentRow.actionRevealDuration),
            ("HelmModuleCard.hoverDuration", HelmModuleCard.hoverDuration),
            ("AppShellController.destinationTransitionDuration", AppShellController.destinationTransitionDuration),
            ("HelmScrollEdgeHairline.fadeDuration", HelmScrollEdgeHairline.fadeDuration),
            ("HelmRowEntrance.duration", HelmRowEntrance.duration),
            ("HelmInputSurface.focusTransitionDuration", HelmInputSurface.focusTransitionDuration),
            ("HelmToggle.animationDuration", HelmToggle.animationDuration),
            ("HelmRowWash.duration", HelmRowWash.duration),
            ("WorkspaceMotion.paneDuration", WorkspaceMotion.paneDuration),
            ("WorkspaceMotion.inspectorEntranceDuration", WorkspaceMotion.inspectorEntranceDuration),
            ("WorkspaceMotion.tabDuration", WorkspaceMotion.tabDuration),
        ]
        for (name, value) in named {
            check(rows.contains(value), "\(name) is \(value)s, which is not a row of the motion table", &ok)
        }
    }

    private static func checkTheTimingDefault(_ ok: inout Bool) {
        // `animateLayers`' default curve is the one ease-out. Read through a
        // real animation rather than the source, so a changed default fails.
        HelmMotion.reducedOverrideForTests = false
        let layer = CALayer()
        HelmMotion.animateLayers(duration: 1, on: [layer]) { layer.opacity = 0.5 }
        let applied = (layer.animation(forKey: "opacity") as? CABasicAnimation)?.timingFunction
        check(applied.map { sameCurve($0, CAMediaTimingFunction(name: .easeOut)) } == true,
              "animateLayers' default curve is not the motion table's one ease-out", &ok)
    }

    // MARK: 2. Literal durations

    /// A literal is allowed only where it is a one-off with its own reason.
    /// `file` and `snippet` must both match the offending line.
    private struct Exception {
        let file: String
        let snippet: String
        let reason: String
    }

    private static let literalExceptions: [Exception] = [
        Exception(file: "ThemeTransition.swift", snippet: "static let duration",
                  reason: "the theme crossfade is K3's own 200ms, asserted by ThemeMotionWebIslandsSelfTest"),
        Exception(file: "HelmSkeleton.swift", snippet: "shimmerDuration",
                  reason: "an ambient loop, not a transition"),
        Exception(file: "Toast.swift", snippet: "plainDuration",
                  reason: "how long a toast stays up, not how it moves"),
        Exception(file: "Toast.swift", snippet: "undoDuration",
                  reason: "how long an Undo toast stays up, not how it moves"),
        Exception(file: "LockScreenController.swift", snippet: "bob.duration",
                  reason: "the lock screen's ambient scene, on the migration's must-not-change list"),
        Exception(file: "LockScreenController.swift", snippet: "drift.duration",
                  reason: "the lock screen's ambient scene"),
        Exception(file: "LockScreenController.swift", snippet: "backDrift.duration",
                  reason: "the lock screen's ambient scene"),
        Exception(file: "LockScreenController.swift", snippet: "shake.duration",
                  reason: "the wrong-password shake, a keyframe gesture rather than a transition"),
        Exception(file: "LockScreenController.swift", snippet: "rock.duration",
                  reason: "the wrong-password rock, paired with the shake"),
        Exception(file: "LockScreenController.swift", snippet: "let duration = 0.55",
                  reason: "the unlock scene's own choreography"),
        Exception(file: "DictationHUD.swift", snippet: "animation.duration",
                  reason: "the listening pulse, an ambient loop"),
        Exception(file: "StrawHatCrewViews.swift", snippet: "pulse.duration",
                  reason: "the crew's working pulse, an ambient loop"),
        Exception(file: "NotificationCenterPopover.swift", snippet: "bounce.duration",
                  reason: "the bell's arrival bounce, a keyframe gesture"),
    ]

    /// The three shapes a UI duration is written in here.
    private static let literalPatterns: [NSRegularExpression] = [
        // `context.duration = 0.18`, `animation.duration = 2.2`
        #"\.duration\s*=\s*[0-9]"#,
        // `HelmMotion.animate(duration: 0.18)`, `HelmMotion.fade(v, to: 0, duration: 0.12, ...)`
        #"HelmMotion\.(animate|animateLayers|fade)\([^)]*duration:\s*[0-9]"#,
        // `static let hoverDuration: TimeInterval = 0.14`, `let duration = 0.55`
        #"\b(let|var)\s+\w*[dD]uration\s*(:\s*TimeInterval)?\s*=\s*[0-9]"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func checkNoLiteralDurations(_ sources: [(name: String, code: [String])], _ ok: inout Bool) {
        var used = Set<Int>()
        var offenders: [String] = []
        for (name, lines) in sources where name != "HelmMotion.swift" {
            for (number, line) in lines.enumerated() where matchesAny(literalPatterns, line) {
                if let index = literalExceptions.firstIndex(where: { $0.file == name && line.contains($0.snippet) }) {
                    used.insert(index)
                } else {
                    offenders.append("\(name):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        check(offenders.isEmpty,
              "a literal UI duration outside HelmMotion - use stateDuration, moveDuration or springDuration "
              + "(the table is in HelmMotion.swift's header), or add an exception here that says why:\n      "
              + offenders.joined(separator: "\n      "), &ok)
        let stale = literalExceptions.indices.filter { !used.contains($0) }.map {
            "\(literalExceptions[$0].file): \(literalExceptions[$0].snippet)"
        }
        check(stale.isEmpty, "a literal-duration exception no longer matches anything - remove it: \(stale)", &ok)
        if offenders.isEmpty && stale.isEmpty {
            print("  OK   no literal UI duration outside HelmMotion (\(literalExceptions.count) named exceptions, all live)")
        }
    }

    // MARK: 3. Implicit animation

    /// The sites where `allowsImplicitAnimation` animates a *layout* change,
    /// which it really does (frames move through `bounds` and `position`).
    private static let implicitAnimationSites: [Exception] = [
        Exception(file: "KubernetesController+Behaviour.swift", snippet: "allowsImplicitAnimation",
                  reason: "the describe drawer's width slide is a layout pass"),
        Exception(file: "ConsoleController+SRELead.swift", snippet: "allowsImplicitAnimation",
                  reason: "the SRE Lead pane's slide is a layout pass"),
        Exception(file: "HelmForm.swift", snippet: "allowsImplicitAnimation",
                  reason: "the toggle knob's slide is a constraint constant and a layout pass"),
    ]

    private static func checkImplicitAnimationIsLayoutOnly(_ sources: [(name: String, code: [String])], _ ok: inout Bool) {
        var used = Set<Int>()
        var offenders: [String] = []
        for (name, lines) in sources where name != "HelmMotion.swift" {
            for (number, line) in lines.enumerated() where line.contains("allowsImplicitAnimation") {
                if let index = implicitAnimationSites.firstIndex(where: { $0.file == name }) {
                    used.insert(index)
                } else {
                    offenders.append("\(name):\(number + 1)")
                }
            }
        }
        check(offenders.isEmpty,
              "allowsImplicitAnimation does not animate a view-backed layer's fill, border, shadow opacity or "
              + "transform (measured) - use HelmMotion.animateLayers(on:) instead: \(offenders)", &ok)
        let stale = implicitAnimationSites.indices.filter { !used.contains($0) }.map { implicitAnimationSites[$0].file }
        check(stale.isEmpty, "an implicit-animation site no longer uses the flag - remove it from the list: \(stale)", &ok)
        if offenders.isEmpty && stale.isEmpty {
            print("  OK   allowsImplicitAnimation is used only for the \(implicitAnimationSites.count) layout slides")
        }
    }

    // MARK: 4. The primitive

    private static func checkAnimateLayersEasesAChange(_ ok: inout Bool) {
        HelmMotion.reducedOverrideForTests = false
        let layer = CALayer()
        layer.backgroundColor = NSColor.white.cgColor
        layer.borderWidth = 1
        HelmMotion.animateLayers(duration: HelmMotion.stateDuration, on: [layer]) {
            layer.backgroundColor = NSColor.black.cgColor
            layer.borderWidth = 1   // unchanged
        }
        let keys = layer.animationKeys() ?? []
        check(keys.contains("backgroundColor"), "animateLayers did not ease a changed fill (keys \(keys))", &ok)
        check(!keys.contains("borderWidth"), "animateLayers animated a property that did not change (keys \(keys))", &ok)
        let ease = layer.animation(forKey: "backgroundColor") as? CABasicAnimation
        check(ease?.duration == HelmMotion.stateDuration, "the fill's animation does not carry the caller's duration", &ok)
        check((ease?.fromValue as AnyObject?)?.isEqual(NSColor.white.cgColor) == true,
              "the fill's animation does not start from the old fill", &ok)
    }

    private static func checkAnimateLayersPicksUpAnEntrance(_ ok: inout Bool) {
        HelmMotion.reducedOverrideForTests = false
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 100, height: 40)
        HelmMotion.withoutActions { layer.transform = HelmMotion.centredScale(0.9, of: layer) }
        check((layer.animationKeys() ?? []).isEmpty, "setting an entrance's start state animated", &ok)
        HelmMotion.animateLayers(duration: HelmMotion.springDuration, timing: HelmMotion.spring(), on: [layer]) {
            layer.transform = CATransform3DIdentity
        }
        let ease = layer.animation(forKey: "transform") as? CABasicAnimation
        check(ease != nil, "an entrance from a scale to identity did not animate", &ok)
        check(ease?.timingFunction.map { sameCurve($0, HelmMotion.spring()) } == true,
              "an entrance on the spring did not take the spring curve", &ok)
        check(CATransform3DIsIdentity(layer.transform), "the entrance's end state is not identity", &ok)
    }

    private static func checkAnimateLayersUnderReduceMotion(_ ok: inout Bool) {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let layer = CALayer()
        layer.transform = CATransform3DMakeScale(0.9, 0.9, 1)
        HelmMotion.animateLayers(duration: 1, on: [layer]) { layer.transform = CATransform3DIdentity }
        check(CATransform3DIsIdentity(layer.transform), "Reduce Motion did not reach the end state", &ok)
        check((layer.animationKeys() ?? []).isEmpty,
              "Reduce Motion still animated (\(layer.animationKeys() ?? [])) - the end state, instantly, never slower", &ok)
    }

    // MARK: Helpers

    private static func loadSources() -> [(name: String, code: [String])]? {
        guard let files = SelfTestSources.appSourceFiles(), !files.isEmpty else { return nil }
        return files.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.lastPathComponent, codeLines(text))
        }
    }

    /// The file's lines with `//` comments and `/* */` blocks blanked, so a
    /// guard matches code rather than the paragraph explaining it. Line
    /// numbers are preserved for the failure message.
    private static func codeLines(_ text: String) -> [String] {
        var out: [String] = []
        var inBlock = false
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            if inBlock {
                guard let end = line.range(of: "*/") else { out.append(""); continue }
                line = String(line[end.upperBound...])
                inBlock = false
            }
            if let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line = String(line[..<start.lowerBound]) + String(line[end.upperBound...])
                } else {
                    line = String(line[..<start.lowerBound])
                    inBlock = true
                }
            }
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            out.append(line)
        }
        return out
    }

    /// `CAMediaTimingFunction` has no value equality, so compare the curve.
    private static func sameCurve(_ a: CAMediaTimingFunction, _ b: CAMediaTimingFunction) -> Bool {
        for index in 1...2 {
            var pa: [Float] = [0, 0], pb: [Float] = [0, 0]
            a.getControlPoint(at: index, values: &pa)
            b.getControlPoint(at: index, values: &pb)
            if abs(pa[0] - pb[0]) > 0.0001 || abs(pa[1] - pb[1]) > 0.0001 { return false }
        }
        return true
    }

    private static func matchesAny(_ patterns: [NSRegularExpression], _ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return patterns.contains { $0.firstMatch(in: line, range: range) != nil }
    }
}

#endif
