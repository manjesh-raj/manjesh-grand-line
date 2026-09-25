// Grand Line - native macOS app.
//
// Review bug B10: "the Dictation page's status card lays out wrong on first
// render".
//
// What the review saw, in two live renders of the real app: the sentence
// "Grand Line needs permission to use your microphone before it can dictate."
// rendered **one word per line in a roughly 50pt column**, with words broken
// mid-word ("permis / sion", "microp / hone"), and the Status card grown to
// 380pt tall. A second process wrapped at 470pt but kept the 380pt card with
// the icon and button centred far below the text. After a theme change - i.e.
// after another full layout pass - the card was compact and correct.
//
// The mechanism is a circular derivation. `DictationController.viewDidLayout`
// read `stack.bounds.width` and fed it back into the wrapping label's
// `preferredMaxLayoutWidth` - but an `NSStackView` has no intrinsic size
// (AGENTS.md gotcha (12)), so its resolved width comes *from* that label's
// intrinsic width, which comes from `preferredMaxLayoutWidth`. Whichever pass
// ran first with a small width therefore became permanent.
//
// Measured on this branch with an env-gated probe, page settling from an
// intermediate width to 1512: the old code set the column to **11pt** (from a
// 700pt intermediate), **91pt** (860) and **161pt** (1000). An 11pt column is
// the captain's "one word per line, words broken mid-word" exactly.
//
// `availableDetailWidth` replaces it with the same non-circular derivation
// `SettingsRow.relayoutDescription` uses - the row's own resolved width minus
// its rigid siblings - plus a floor, and this suite is what keeps it that way.
//
// **Window-backed**: it asserts real resolved geometry from a real layout
// pass, so it is listed in `NEEDS_SESSION`.
//
// `FM_RUN_DICTATION_STATUS_CARD_LAYOUT_TESTS=1 .build/debug/GrandLine`.
#if FM_SELFTESTS

import AppKit
import Foundation

enum DictationStatusCardLayoutSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== DictationStatusCardLayoutSelfTest ==")
        ok = checkTheTextColumnNeverCollapses() && ok
        ok = checkTheSettledCardWrapsAtTheRowsRealWidth() && ok
        print(ok ? "DictationStatusCardLayoutSelfTest: OK" : "DictationStatusCardLayoutSelfTest: FAILED")
        return ok
    }

    /// The defect proper. A layout pass at an intermediate width must not be
    /// able to lock the column narrower than the floor.
    ///
    /// The intermediate widths are not arbitrary: `main.swift` assigns the
    /// content view controller and only then sets the window's frame (its own
    /// note on gotcha (3) says why that order is required), so the page really
    /// does get laid out at a width that is not its final one, and
    /// `viewDidLayout` really does run against it.
    private static func checkTheTextColumnNeverCollapses() -> Bool {
        var ok = true
        let finalWidth: CGFloat = 1512
        var observed: [CGFloat] = []

        for intermediate in [200.0, 400.0, 700.0, 860.0, 1000.0] as [CGFloat] {
            autoreleasepool {
                let controller = DictationController(store: DictationStore())
                let window = OffScreenProbe.window(width: finalWidth, height: 900)
                defer { window.contentView = nil; window.close() }
                window.contentView = controller.view

                controller.view.frame = NSRect(x: 0, y: 0, width: intermediate, height: 900)
                // The longest of the permission sentences, which is the state
                // the captain reported.
                controller.debugSetStatus(.needsMicrophone)
                controller.view.layoutSubtreeIfNeeded()
                controller.viewDidLayout()

                let locked = controller.debugStatusDetailMaxLayoutWidth
                observed.append(locked)
                check(locked >= DictationController.debugDetailMinimumWidth,
                      "@\(intermediate)pt intermediate: the text column was set to \(locked)pt, below "
                      + "the \(DictationController.debugDetailMinimumWidth)pt floor - that is the "
                      + "one-word-per-line card (B10)", &ok)
            }
        }

        // Discriminating power: the sweep has to have produced real numbers.
        check(observed.count == 5, "expected five intermediate passes, got \(observed.count)", &ok)
        check(observed.allSatisfy { $0 > 0 }, "every pass set a real width, got \(observed)", &ok)
        return ok
    }

    /// The other direction, so the floor cannot be satisfied by simply pinning
    /// every column at 180pt: once the page has its real width, the column
    /// must actually use it, and the card must stay the height of its content.
    private static func checkTheSettledCardWrapsAtTheRowsRealWidth() -> Bool {
        var ok = true
        for width in [1512.0, 1100.0] as [CGFloat] {
            autoreleasepool {
                let controller = DictationController(store: DictationStore())
                let window = OffScreenProbe.window(width: width, height: 900)
                defer { window.contentView = nil; window.close() }
                window.contentView = controller.view

                controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
                controller.debugSetStatus(.needsMicrophone)
                controller.view.layoutSubtreeIfNeeded()
                controller.viewDidLayout()
                // Then the page reaches its real width, as it does at launch.
                controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                controller.view.layoutSubtreeIfNeeded()
                controller.viewDidLayout()
                controller.view.layoutSubtreeIfNeeded()

                let row = controller.debugStatusRowWidth
                let column = controller.debugStatusDetailMaxLayoutWidth
                let card = controller.debugStatusCardFrame
                let label = controller.debugStatusDetailFrame

                check(row > 400,
                      "@\(width): the fixture is vacuous unless the row really resolved wide, got \(row)pt", &ok)
                check(column > DictationController.debugDetailMinimumWidth,
                      "@\(width): a settled row must give the column more than the floor, got \(column)pt", &ok)
                check(column <= row,
                      "@\(width): the column (\(column)pt) must not exceed its row (\(row)pt)", &ok)
                // The captain's own symptom: a card grown to 380pt around a
                // sentence that needs two or three lines.
                check(card.height < 200,
                      "@\(width): the Status card is \(card.height)pt tall for a two-line sentence - "
                      + "the review measured 380pt with the icon and button centred far below the "
                      + "text (B10)", &ok)
                check(label.height > 0 && label.height < card.height,
                      "@\(width): the label (\(label.height)pt) sits inside its card (\(card.height)pt)", &ok)
            }
        }
        return ok
    }
}

#endif
