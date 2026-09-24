// Grand Line - native macOS app.
//
// The Scratchpad calculator's **window-backed** half (F9 of full review #3
// §8): the real `ScratchpadPadView` mounted in a real `NSWindow`, laid out at
// a real width, with its result rows measured against the input's own text
// layout and its colours read back out of a real render.
//
// **This suite is in `NEEDS_SESSION`**, and that classification is operative
// rather than decorative: everything it asserts is a question about geometry
// that only exists once a view has been laid out. Everything that is a *rule*
// - what an expression means, what a result reads as, what the store keeps -
// is in `ScratchpadEngineSelfTest` and guards CI's blocking lane.
//
// ## The one thing worth reading before changing this file
//
// `checkResultsTrackWrappedLines` is the case the pad's whole layout design
// exists for. A result column built as a second text view lines up only while
// no input line wraps; the moment one does, every result below it is off by a
// row. So the case deliberately types a line long enough to wrap **at the
// width it is rendered at**, asserts that it really did wrap (otherwise the
// check is vacuous - AGENTS.md's "a check that cannot fail is worse than no
// check"), and only then asserts that the following line's result moved down
// with it.
//
// ## Render sampling
//
// `checkTheResultColumnIsActuallyPainted` uses
// `bitmapImageRepForCachingDisplay`, and respects both of that call's traps:
// the rep is measured in **pixels** (a factor of two on a retina machine, so
// the index is scaled by `rep.pixelsWide / bounds.width`), and the expected
// colour is converted into **`rep.colorSpace`** rather than the sample into
// sRGB.
//
// Hermeticity: the suite changes the theme, so it saves and restores
// `ThemeManager.shared.theme`; it writes to the general pasteboard, so it
// saves and restores that too; and every store it builds is rooted in a
// scratch directory.
//
// `FM_RUN_SCRATCHPAD_VIEW_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ScratchpadPadViewSelfTest {

    /// The same pinned Monday the engine's suite uses, so a date line's
    /// expected text is the same in both files.
    private static let now = Date(timeIntervalSince1970: 1_789_999_200)

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        // Saved and restored around the whole run - persisting a theme
        // selection is correct behaviour for the app, so the fix belongs at
        // the test (AGENTS.md's most-repeated operational lesson).
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }

        checkEveryLineGetsItsOwnRow(check)
        checkResultsTrackWrappedLines(check)
        checkErrorsAndProseReadDifferently(check)
        checkCopyPaths(check)
        checkThemeReachesEveryPart(check)
        checkTheWellShowsFocus(check)
        checkTheResultColumnIsActuallyPainted(check)
        checkTheTabPersistsItsPad(check)
        checkThePadDoesNotCapTheWindow(check)

        print(ok ? "ScratchpadPadViewSelfTest: OK" : "ScratchpadPadViewSelfTest: FAILURES")
        return ok
    }

    // MARK: Harness

    /// One pad, in a real window, laid out.
    ///
    /// `autoreleasepool` is mandatory around AppKit construction in a headless
    /// suite - nothing turns the run loop, so removed views are never drained
    /// (AGENTS.md's "Writing a self-test").
    private static func mounted(theme: HelmTheme? = nil,
                                width: CGFloat = 900,
                                text: String,
                                body: (ScratchpadPadView, NSWindow) -> Void) {
        autoreleasepool {
            if let theme { ThemeManager.shared.setTheme(theme) }
            let current = ThemeManager.shared.theme
            let pad = ScratchpadPadView(theme: current, fontSize: 13)
            pad.now = { now }
            pad.calendar = calendar
            // `OffScreenProbe.window(...)`, never a hand-rolled `NSWindow` - a
            // hand-rolled one is *not* off-screen whatever origin it is given.
            let window = OffScreenProbe.window(width: width, height: 640)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 640))
            host.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(pad)
            NSLayoutConstraint.activate([
                pad.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                pad.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                pad.topAnchor.constraint(equalTo: host.topAnchor),
                pad.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            window.contentView = host
            pad.text = text
            host.layoutSubtreeIfNeeded()
            pad.layoutSubtreeIfNeeded()
            body(pad, window)
            window.contentView = nil
            window.close()
        }
    }

    /// The vertical centre of one result row.
    private static func centre(_ label: NSTextField) -> CGFloat { label.frame.midY }

    // MARK: Cases

    private static func checkEveryLineGetsItsOwnRow(_ check: (Bool, String) -> Void) {
        let lines = [
            "seats = 42",
            "seat_price = 18.50 USD / month",
            "seats * seat_price",
            "",
            "0x1F + 12",
            "2 weeks from Friday",
        ]
        mounted(text: lines.joined(separator: "\n")) { pad, _ in
            check(pad.debugResultLabels.count == lines.count,
                  "one row per line: \(pad.debugResultLabels.count) rows for \(lines.count) lines")
            let shown = pad.debugResultLabels.map { $0.stringValue }
            let expected = ["42", "$18.50/mo", "$777.00/mo", "", "43", "9 Oct 2026"]
            check(shown == expected, "the rendered column reads \(shown), expected \(expected)")

            // Each row sits on its own input line, and the rows go down the
            // page in order. The second half is what would catch a row that
            // landed on the right y by accident.
            let rects = pad.debugInputLineRects
            check(rects.count == lines.count, "the probe measured \(rects.count) input lines for \(lines.count)")
            for (index, label) in pad.debugResultLabels.enumerated() where index < rects.count {
                let lineRect = rects[index]
                guard lineRect.height > 0 else { continue }
                let inside = centre(label) >= lineRect.minY - 2 && centre(label) <= lineRect.maxY + 2
                check(inside, "row \(index) (\"\(label.stringValue)\") sits at y \(centre(label)), its line spans \(lineRect.minY)...\(lineRect.maxY)")
            }
            let centres = pad.debugResultLabels.map { centre($0) }
            check(centres == centres.sorted(), "the result rows are out of order: \(centres)")
            check(Set(centres).count == centres.count, "two result rows share a y - one line's answer is on another line")
        }
    }

    private static func checkResultsTrackWrappedLines(_ check: (Bool, String) -> Void) {
        // Long enough to wrap at 620pt with a ~196pt result column taken out
        // of it. The case asserts below that it really did.
        let long = "(1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12 + 13 + 14 + 15 + 16 + 17 + 18 + 19 + 20"
            + " + 21 + 22 + 23 + 24 + 25 + 26 + 27 + 28 + 29 + 30 + 31 + 32 + 33 + 34 + 35 + 36) * 2"
        mounted(width: 620, text: "1 + 1\n\(long)\n2 + 2") { pad, _ in
            let rects = pad.debugInputLineRects
            check(rects.count == 3, "the probe measured \(rects.count) lines, expected 3")
            guard rects.count == 3 else { return }

            // Discriminating power first: the middle line must genuinely
            // occupy more than one visual row, or everything below asserts
            // nothing.
            let singleRow = rects[0].height
            check(rects[1].height > singleRow * 1.5,
                  "the fixture's long line did not wrap (\(rects[1].height)pt against a \(singleRow)pt row) - this case would be vacuous")

            let labels = pad.debugResultLabels
            check(labels.count == 3, "one row per line even when a line wraps, got \(labels.count)")
            guard labels.count == 3 else { return }
            check(labels[0].stringValue == "2" && labels[2].stringValue == "4",
                  "the rows either side of the wrapped line read \(labels[0].stringValue)/\(labels[2].stringValue)")

            // The wrapped line's own answer sits on its **last** visual row,
            // and the line after it has been pushed below the whole thing.
            check(centre(labels[1]) > rects[1].minY + singleRow,
                  "the wrapped line's answer sits on its first row (y \(centre(labels[1])), line starts \(rects[1].minY)) rather than its last")
            check(centre(labels[2]) > rects[1].maxY - 2,
                  "the line after a wrapped line did not move down with it: y \(centre(labels[2])) against a line ending at \(rects[1].maxY)")
            check(centre(labels[2]) - centre(labels[0]) > singleRow * 2,
                  "the third row is not clear of the wrapped second line")
        }
    }

    private static func checkErrorsAndProseReadDifferently(_ check: (Bool, String) -> Void) {
        mounted(theme: ThemeManager.shared.theme,
                text: "call finance about the renewal\n1 kg + 3 s\n2 + 2") { pad, _ in
            let labels = pad.debugResultLabels
            check(labels.count == 3, "three lines, three rows")
            guard labels.count == 3 else { return }
            check(labels[0].stringValue.isEmpty, "prose must stay silent on screen too, said \"\(labels[0].stringValue)\"")
            check(labels[1].stringValue.contains("not the same kind of thing"),
                  "a semantic error must be shown in the column, said \"\(labels[1].stringValue)\"")

            let bad = HelmTheme.nsColor(ThemeManager.shared.theme.ansiHex[1])
            check(labels[1].textColor == bad, "an error row is painted in the theme's bad hue")
            check(labels[2].textColor != bad, "an ordinary answer must not be painted as an error")
            check(labels[1].toolTip != nil, "a stated error carries its own tooltip, for a message wider than the column")
        }
    }

    private static func checkCopyPaths(_ check: (Bool, String) -> Void) {
        // The suite writes to the real pasteboard, so it puts back whatever
        // was there - the same courtesy the theme gets.
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        mounted(text: "2 + 2\n\n0x1F + 12") { pad, _ in
            var copied: [String] = []
            pad.onCopied = { copied.append($0) }

            check(pad.copyAllResults(), "Copy all results should report that it copied something")
            check(copied.last == "4\n\n43", "the copied column was \"\(copied.last ?? "")\", blank line included")
            check(NSPasteboard.general.string(forType: .string) == "4\n\n43",
                  "the column did not reach the pasteboard")

            // ⌘↩ copies the caret's own line, and nothing at all on a blank
            // one - the chord falls through rather than silently eating it.
            pad.input.setSelectedRange(NSRange(location: 0, length: 0))
            check(pad.lineIndexOfCaret() == 0, "the caret is on line 1")
            check(pad.copyCurrentLineResult(), "\u{2318}\u{21A9} on line 1 should copy")
            check(copied.last == "4", "\u{2318}\u{21A9} copied \"\(copied.last ?? "")\", expected \"4\"")

            let text = pad.text as NSString
            pad.input.setSelectedRange(NSRange(location: text.length, length: 0))
            check(pad.lineIndexOfCaret() == 2, "the caret is on line 3")
            check(pad.copyCurrentLineResult(), "\u{2318}\u{21A9} on line 3 should copy")
            check(copied.last == "43", "\u{2318}\u{21A9} copied \"\(copied.last ?? "")\", expected \"43\"")

            pad.input.setSelectedRange(NSRange(location: 6, length: 0))
            check(!pad.copyCurrentLineResult(), "\u{2318}\u{21A9} on a blank line copies nothing and says so")
        }

        mounted(text: "just a note") { pad, _ in
            check(!pad.copyAllResults(), "a pad with no answers at all must not claim to have copied one")
        }
    }

    private static func checkThemeReachesEveryPart(_ check: (Bool, String) -> Void) {
        for theme in [HelmTheme.theme(id: "dusk"), HelmTheme.theme(id: "daylight")].compactMap({ $0 }) {
            mounted(theme: theme, text: "2 + 2") { pad, _ in
                let ink = theme.isDaylight ? HelmField.ink(theme) : HelmTheme.nsColor(theme.chromeInkHex)
                check(pad.input.textColor == ink, "\(theme.id): the pad's own text is not the theme's ink")
                check(pad.input.insertionPointColor == HelmTheme.nsColor(theme.accentHex),
                      "\(theme.id): the caret is not the theme's accent")
                check(pad.debugResultLabels.first?.textColor == ink,
                      "\(theme.id): the result column is not the theme's ink")
                // GL-16 / the D4 selection rule: one definition, never a
                // hand-rolled alpha.
                check(pad.input.selectedTextAttributes[.backgroundColor] != nil,
                      "\(theme.id): the pad's selection was never themed")
            }
        }
    }

    /// GL-16: a focusable surface has to show that it has focus. The pad's
    /// text view suppresses its own ring on purpose and the **well** lights up
    /// instead, so this asserts the well - which is the half a
    /// `focusRingType = .none` could silently drop.
    private static func checkTheWellShowsFocus(_ check: (Bool, String) -> Void) {
        // Pinned rather than ambient: a well's resting border weight differs
        // between the Daylight family and the twelve, so a case asserting
        // "the border got thicker" passes or fails on whatever theme the
        // *previous* suite in the run happened to leave behind. What is
        // actually promised is that the well changes - which is asserted as a
        // composite of every property the focus treatment touches, in both
        // registers.
        for theme in [HelmTheme.theme(id: "dusk"), HelmTheme.theme(id: "daylight")].compactMap({ $0 }) {
            mounted(theme: theme, text: "2 + 2") { pad, window in
                window.orderFrontRegardless()
                guard let well = pad.input.enclosingScrollView, let layer = well.layer else {
                    check(false, "the pad's text view is not inside a layer-backed well")
                    return
                }
                // Described by its **components**, never by
                // `String(describing: CGColor)` - that carries the object's
                // address, so two identical colours compare unequal and a
                // "did it change back" check can never pass.
                func chrome() -> String {
                    let components = (layer.borderColor?.components ?? []).map { String(format: "%.3f", $0) }
                    return "\(layer.borderWidth)/[\(components.joined(separator: ","))]/\(layer.shadowOpacity)"
                }
                // A window hands first responder to the first text view in
                // its content view on its own, so "resting" has to be asked
                // for rather than assumed - measured: without this the pad was
                // already focused and the case compared a focused well with
                // itself.
                window.makeFirstResponder(window.contentView)
                let resting = chrome()
                check(layer.borderWidth > 0, "\(theme.id): the pad's well has no resting border at all")
                check(window.makeFirstResponder(pad.input), "\(theme.id): the pad's text view would not take focus")
                let focused = chrome()
                check(focused != resting, "\(theme.id): the well did not light up on focus: \(resting)")
                window.makeFirstResponder(window.contentView)
                check(chrome() == resting,
                      "\(theme.id): the well kept its focused chrome after focus left: \(chrome())")
            }
        }
    }

    /// The one check a resolved colour cannot make: that the column is
    /// actually painted, in a real render.
    private static func checkTheResultColumnIsActuallyPainted(_ check: (Bool, String) -> Void) {
        let theme = HelmTheme.theme(id: "dusk") ?? ThemeManager.shared.theme
        mounted(theme: theme, text: "2 + 2\n3 * 3") { pad, window in
            window.orderFrontRegardless()
            pad.layoutSubtreeIfNeeded()
            guard let rep = pad.bitmapImageRepForCachingDisplay(in: pad.bounds) else {
                check(false, "the pad would not produce a bitmap rep to sample")
                return
            }
            pad.cacheDisplay(in: pad.bounds, to: rep)
            let scaleX = CGFloat(rep.pixelsWide) / pad.bounds.width
            let scaleY = CGFloat(rep.pixelsHigh) / pad.bounds.height
            check(scaleX >= 1, "the rep is measured in pixels; a scale under 1 means the bounds are wrong")

            // A point inside the result column, clear of any glyph: two thirds
            // down the column's own width, near its bottom.
            guard let first = pad.debugResultLabels.first else { return }
            let columnRight = pad.bounds.maxX - 6
            let samplePoint = NSPoint(x: columnRight - 4, y: first.frame.minY + pad.bounds.height * 0.5)
            let x = Int((samplePoint.x * scaleX).rounded())
            let y = Int((samplePoint.y * scaleY).rounded())
            guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh, let sample = rep.colorAt(x: x, y: y) else {
                check(false, "the sample point fell outside the rendered rep")
                return
            }
            // The expected colour is converted into the rep's own space, never
            // the sample into sRGB - the trap that once reported a correct
            // accent as a colour bug.
            let page = HelmTheme.nsColor(theme.backgroundHex)
            guard let expected = page.usingColorSpace(rep.colorSpace),
                  let actual = sample.usingColorSpace(rep.colorSpace) else {
                check(false, "the rep's colour space would not take either colour")
                return
            }
            // The column is deliberately a step off the page it sits on, so
            // the assertion is that it differs - and the fixture's own
            // discriminating power is that the two colours are not equal to
            // begin with.
            let delta = abs(expected.redComponent - actual.redComponent)
                + abs(expected.greenComponent - actual.greenComponent)
                + abs(expected.blueComponent - actual.blueComponent)
            check(delta > 0.004,
                  "the result column renders identically to the page behind it (delta \(delta)) - it was never painted")
        }
    }

    private static func checkTheTabPersistsItsPad(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fm-scratchpad-tab-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("scratchpad.json")
            setenv("FM_SCRATCHPAD_FILE", file.path, 1)
            // Put the process-wide redirect back where `main.swift` set it, so
            // nothing after this case writes somewhere else.
            defer { setenv("FM_SCRATCHPAD_FILE", ScratchpadStore.storeURL().path, 1) }

            let theme = ThemeManager.shared.theme
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            let tab = ToolInstance(kind: .scratchpad, name: "Scratchpad", theme: theme, toastHost: host)
            check(tab.debugScratchpad != nil, "a Scratchpad tab must build a pad")
            tab.debugScratchpad?.text = "seats = 42\nseats * 2"
            tab.flushScratchpad()
            check(ScratchpadStore(fileURL: file).text(for: "Scratchpad") == "seats = 42\nseats * 2",
                  "closing a Scratchpad tab must write its pad")

            // A second tab of the same name - which is what a relaunch builds
            // - comes back with the text.
            let reopened = ToolInstance(kind: .scratchpad, name: "Scratchpad", theme: theme, toastHost: host)
            check(reopened.debugScratchpad?.text == "seats = 42\nseats * 2",
                  "a reopened tab did not restore its pad: \"\(reopened.debugScratchpad?.text ?? "")\"")
            check(reopened.debugScratchpad?.debugResults.first?.display == "42",
                  "a restored pad must evaluate itself on the way back up")

            // A rename carries it, so the label is a label rather than a new
            // document.
            reopened.tabWasRenamed(from: "Scratchpad", to: "Renewal maths")
            check(ScratchpadStore(fileURL: file).text(for: "Renewal maths") == "seats = 42\nseats * 2",
                  "a renamed tab must carry its pad to the new name")

            // Duplicate (⌘D) copies the text into an independent pad.
            let copy = ToolInstance(kind: .scratchpad, name: "Renewal maths 2", theme: theme, toastHost: host)
            copy.restoreContent(reopened.snapshotContent())
            check(copy.debugScratchpad?.text == "seats = 42\nseats * 2", "Duplicate must carry the pad's text")
            copy.debugScratchpad?.text = "1 + 1"
            check(reopened.debugScratchpad?.text == "seats = 42\nseats * 2",
                  "two open pads must be independent of each other")
        }
    }

    /// AGENTS.md gotcha (13): any content constraint above priority 500 can
    /// cap the whole window. A pad that wants to be 460pt tall must not become
    /// a floor under every page.
    private static func checkThePadDoesNotCapTheWindow(_ check: (Bool, String) -> Void) {
        mounted(text: "2 + 2") { pad, window in
            // Any height constraint above 500 counts, `>=` very much
            // included: a required minimum is the shape that becomes a floor
            // under the window's own height.
            let capping = pad.constraints.filter {
                $0.firstAttribute == .height && $0.relation != .lessThanOrEqual
                    && $0.priority.rawValue > NSLayoutConstraint.Priority(rawValue: 500).rawValue
            }
            check(capping.isEmpty, "the pad declares a height above priority 500, which is a window-size cap: \(capping)")
            window.setContentSize(NSSize(width: 700, height: 420))
            window.layoutIfNeeded()
            check(abs(window.frame.width - 700) < 40,
                  "the window would not shrink to 700pt with a pad mounted - it settled at \(window.frame.width)")
        }
    }
}

#endif
