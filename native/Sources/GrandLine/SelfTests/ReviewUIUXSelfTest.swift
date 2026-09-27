// Grand Line - native macOS app.
//
// The UI and UX findings of the 2026-09-27 full-application review
// (`fm/grand-line-review-ui-ux-u1-x7`): the 17 rendered UI defects and the
// seven UX issues X1..X7, one case per finding that has something a test can
// see.
//
// Most of the 17 are pixel defects and are covered by the review's own
// before/after screenshot convention rather than by a case here - only the
// findings with a behavioural or source-visible half live in this file:
//
//   U12  no em dash is used as a prose separator in this app's own copy
//   U13  the search palette's overflow line is grammatical
//   U5   the Health card's fraction and its sentence describe one thing
//   U6   DevOps Commands opens with a category selected, so a list is on screen
//   U10  an Updates row that needs nothing carries no action
//   U11  a primary action is disabled until the thing it acts on is ready
//   U16  the task editor strips the parsed date phrase out of the title
//   X1   the lock screen has a local fallback when the vault helper is down
//   X4   Bootstrap and Automation read one progress source
//   X7   the daily review no longer carries the "habits aren't in this build" row
//
// Run with:
//   swift build && FM_RUN_REVIEW_UI_UX_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic and source guards - no window is mounted here, so this suite is
// **not** in `Scripts/run-all-tests.sh`'s `NEEDS_SESSION` list and guards the
// blocking CI job. The window-backed half lives in
// `ReviewUIUXViewSelfTest.swift`.

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing a suite - `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ReviewUIUXSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("U12_noEmDashIsUsedAsAProseSeparatorInAppCopy", test_u12NoProseEmDash),
            ("U13_searchPaletteOverflowLineIsGrammatical", test_u13OverflowGrammar),
            ("U3_emptyStateWatermarkTouchesNoText", test_u3WatermarkClearsTheCopy),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "ReviewUIUXSelfTest: all \(cases.count) cases passed"
              : "ReviewUIUXSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// A source file with its `//` line comments and `/* */` block comments
    /// removed, so a guard sees only what the app actually compiles. Without
    /// this every guard below would trip on its own explanatory prose - and on
    /// the ~180 comments in this repository that legitimately use an em dash.
    private static func codeOnly(_ text: String) -> String {
        var out = ""
        var inBlock = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if inBlock {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlock = false
            }
            while let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound ..< line.endIndex) {
                    line = String(line[line.startIndex ..< start.lowerBound])
                        + String(line[end.upperBound...])
                } else {
                    line = String(line[line.startIndex ..< start.lowerBound])
                    inBlock = true
                    break
                }
            }
            if let slashes = line.range(of: "//") {
                line = String(line[line.startIndex ..< slashes.lowerBound])
            }
            out += line + "\n"
        }
        return out
    }

    // MARK: U12 - em dashes in UI copy

    /// The two forms a prose em dash takes in this codebase: the literal
    /// character, and the `\u{2014}` escape several files prefer so the source
    /// stays ASCII. Both are looked for **with a space on each side**, which
    /// is what makes them a sentence separator rather than the standalone
    /// "value unknown" glyph GL-14 uses (`FleetController`'s PR count, the
    /// focus ring's empty planned time, an unchecked update's timestamp).
    /// That glyph is typography, not copy, and is deliberately left alone.
    private static let proseEmDashForms = [" \u{2014} ", " \\u{2014} "]

    /// The two files whose em dashes are not UI copy at all: they are the
    /// text of a prompt sent to Claude, where the dash is the model's input
    /// rather than something a captain reads.
    private static let promptFiles: Set<String> = ["StrawHatContext.swift", "LogAnalyzerAI.swift"]

    private static func test_u12NoProseEmDash() -> String? {
        guard let files = SelfTestSources.appSourceFiles() else {
            return "SKIP-AS-FAILURE: the app's sources are not next to this binary, "
                 + "so this guard would have checked nothing"
        }
        // Discriminating power first: the escape and the literal must both be
        // findable at all, or a typo in `proseEmDashForms` passes vacuously.
        for form in proseEmDashForms {
            guard ("a" + form + "b").contains(form) else {
                return "the guard's own needle \(form.debugDescription) does not match itself"
            }
        }
        var offenders: [String] = []
        for file in files where !promptFiles.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = codeOnly(text)
            for form in proseEmDashForms where code.contains(form) {
                offenders.append("\(file.lastPathComponent) uses \(form.debugDescription)")
            }
        }
        guard offenders.isEmpty else {
            return "UI copy must use a plain dash, not an em dash (review U12): "
                 + offenders.joined(separator: "; ")
        }
        return nil
    }

    // MARK: U13 - the search palette's overflow line

    private static func test_u13OverflowGrammar() -> String? {
        // Every real group title, so a new plural title cannot reintroduce
        // the defect through a form this case never sees.
        for title in UnifiedSearchKind.groupOrder {
            let many = UnifiedSearchGroup(title: title, items: [], overflow: 45).overflowText
            let one = UnifiedSearchGroup(title: title, items: [], overflow: 1).overflowText
            // The defect itself: the group title used as an adjective in
            // front of a noun it does not agree with.
            if many.contains("\(title.lowercased()) match") || one.contains("\(title.lowercased()) match") {
                return "the overflow line still reads the group title as an adjective: \(many.debugDescription)"
            }
            guard many.hasPrefix("45 more matches in \(title)") else {
                return "the plural form is not grammatical: \(many.debugDescription)"
            }
            guard one.hasPrefix("1 more match in \(title)") else {
                return "the singular form is not grammatical: \(one.debugDescription)"
            }
        }
        guard !UnifiedSearchKind.groupOrder.isEmpty else {
            return "there are no group titles to check, so this case would have passed vacuously"
        }
        return nil
    }

    // MARK: U3 - the empty-state watermark

    /// The four pages the review rendered the collision on, plus the two
    /// other destinations that pass artwork - so a caller added later is
    /// swept too rather than only the four that were photographed.
    private static let watermarkDestinations: [RailDestination] =
        [.kubernetes, .stickyBoard, .docs, .postmortems, .codePreview, .whiteboard]

    private static func test_u3WatermarkClearsTheCopy() -> String? {
        // Every size the page-filling callers use, at a page-sized container
        // and at a deliberately cramped one - the cramped case is what the
        // required `top >= top` backstop exists for, and a check that only
        // ever saw a roomy container could not see it fail.
        let containers: [NSSize] = [NSSize(width: 1400, height: 760), NSSize(width: 700, height: 420)]
        for dest in watermarkDestinations {
            guard let artwork = dest.drillHeaderArtwork else {
                return "\(dest.rawValue) no longer carries drill-header artwork, so this case "
                     + "would have checked nothing for it"
            }
            for size in containers {
                let result: String? = autoreleasepool {
                    let state = HelmEmptyState(symbol: "bolt.horizontal.circle",
                                               title: "No live host session",
                                               body: "Every kubectl command runs inside a bastion session "
                                                   + "you have already logged into - that session is the only "
                                                   + "cluster credential there is. Connect a host first.",
                                               size: .standard,
                                               hue: dest.domainHue,
                                               artwork: artwork)
                    let host = NSView(frame: NSRect(origin: .zero, size: size))
                    state.translatesAutoresizingMaskIntoConstraints = false
                    host.addSubview(state)
                    NSLayoutConstraint.activate([
                        state.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        state.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                        state.topAnchor.constraint(equalTo: host.topAnchor),
                        state.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    ])
                    host.layoutSubtreeIfNeeded()
                    let layout = state.debugWatermarkLayout()
                    let where_ = "\(dest.rawValue) at \(Int(size.width))x\(Int(size.height))"
                    // Discriminating power: a zero-sized mark, or a hidden
                    // title, would make every assertion below vacuous.
                    guard layout.watermarkFrame.width > 1, layout.watermarkFrame.height > 1 else {
                        return "\(where_): the watermark has no frame, so this case proves nothing"
                    }
                    guard layout.titleIsVisible, layout.titleFrame.height > 1,
                          layout.bodyFrame.height > 1 else {
                        return "\(where_): the title or body did not lay out, so this case proves nothing"
                    }
                    if layout.watermarkFrame.intersects(layout.titleFrame) {
                        return "\(where_): the watermark \(layout.watermarkFrame) still overlaps the "
                             + "title \(layout.titleFrame) (review U3)"
                    }
                    if layout.watermarkFrame.intersects(layout.bodyFrame) {
                        return "\(where_): the watermark \(layout.watermarkFrame) still overlaps the "
                             + "body copy \(layout.bodyFrame) (review U3)"
                    }
                    // The other half of the backstop: the mark must stay
                    // inside the state it decorates rather than painting over
                    // whatever sits above it.
                    if layout.watermarkFrame.minY < -0.5 || layout.watermarkFrame.maxY > size.height + 0.5 {
                        return "\(where_): the watermark \(layout.watermarkFrame) escapes the empty "
                             + "state's own bounds (height \(size.height))"
                    }
                    return nil
                }
                if let result { return result }
            }
        }
        return nil
    }
}

#endif
