// Grand Line - native macOS app.
//
// `ReviewTourLab`'s own coverage (P11 of the 2026-09-25 review).
//
// A probe driver that is kept rather than thrown away has to be checked like
// anything else, and it has one failure mode that matters more than the rest:
// **passing vacuously**. A tour whose steps silently did nothing, or whose
// render wrote a blank PNG, looks exactly like a run of a page that is fine -
// which is the same trap AGENTS.md records for every off-screen probe in this
// repo.
//
// So this asserts the grammar reports every bad line rather than the first,
// and that a real tour against a real off-screen shell actually moves the
// shell and writes a PNG with real pixels in it.
//
// Window-backed: it mounts a real `AppShellController` in a real
// `OffScreenProbe` window and renders it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ReviewTourLabSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== ReviewTourLabSelfTest ==")
        ok = checkTheGrammar() && ok
        ok = checkATourDrivesAShellAndRenders() && ok
        print(ok ? "ReviewTourLabSelfTest: OK" : "ReviewTourLabSelfTest: FAILED")
        return ok
    }

    private static func checkTheGrammar() -> Bool {
        var ok = true
        let tour = """
        # a comment, and the blank line below

        theme daylight
        resize 1512x950
        goto homeCanvas
        render 01-canvas
        menu
        """
        let (steps, errors) = ReviewTourLab.parse(tour: tour)
        check(errors.isEmpty, "a valid tour must parse clean, got \(errors)", &ok)
        check(steps == [.theme("daylight"),
                        .resize(width: 1512, height: 950),
                        .goto(.homeCanvas),
                        .render(name: "01-canvas"),
                        .menu],
              "the parsed steps do not match the tour, got \(steps)", &ok)

        // Every bad line, not just the first: a hand-written tour fixed one
        // error per run is a tool nobody keeps.
        let bad = """
        goto nowhere
        theme chartreuse
        resize wide
        wiggle
        render
        """
        let (badSteps, badErrors) = ReviewTourLab.parse(tour: bad)
        check(badErrors.count == 5, "expected 5 errors, one per line, got \(badErrors)", &ok)
        check(badSteps.isEmpty, "a tour that does not parse must produce no steps", &ok)
        check(badErrors.first?.contains("line 1") == true && badErrors.first?.contains("nowhere") == true,
              "an error must name its line and the token, got \(badErrors.first ?? "nothing")", &ok)
        return ok
    }

    private static func checkATourDrivesAShellAndRenders() -> Bool {
        var ok = true
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("gl-review-tour-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }

        autoreleasepool {
            let (window, shell) = ReviewTourLab.makeOffScreenShell()
            let before = Set(shell.mountedDestinationSlotsForTests)
            let log = ReviewTourLab.run(
                steps: [.resize(width: 1400, height: 900), .goto(.shift), .render(name: "tasks")],
                shell: shell, window: window, outputDirectory: out)

            check(log.contains("goto shift"), "the log must record what it did, got \(log)", &ok)
            // The tour really moved the shell, or the render below is a render
            // of whatever was already there.
            let after = Set(shell.mountedDestinationSlotsForTests)
            check(after.count > before.count,
                  "`goto shift` should have mounted a slot the launch did not, before "
                  + "\(before.count) after \(after.count)", &ok)
            check(abs(window.frame.width - 1400) < 1,
                  "`resize` should have resized the window, got \(window.frame.width)", &ok)

            let png = out.appendingPathComponent("tasks.png")
            guard let data = try? Data(contentsOf: png) else {
                fail("no PNG was written to \(png.path)", &ok)
                return
            }
            // Not just "a file exists": a blank or 1x1 render would pass that.
            check(data.count > 20_000, "the PNG is \(data.count) bytes - too small to be a real page", &ok)
            guard let rep = NSBitmapImageRep(data: data) else {
                fail("the PNG did not decode", &ok)
                return
            }
            // **The rep is in pixels and the view is in points**, and the two
            // differ by the backing scale - 2x on every dev Mac here, 1x on a
            // GitHub runner (AGENTS.md records both halves of this trap). The
            // expected size is therefore derived from the *view that was
            // rendered*, never from the window: a titled window's content view
            // is shorter than its frame by the title bar. Measured here, a
            // 1400x900 window renders a 1400x868 view, so the first version of
            // this check (`>= 1400 && >= 900`) passed locally only because 2x
            // doubled it to 2800x1736 - and failed on the runner at 1400x872,
            // which is the defect, caught by CI rather than by this machine.
            let scale = window.backingScaleFactor
            let expectedWide = Int((shell.view.bounds.width * scale).rounded())
            let expectedHigh = Int((shell.view.bounds.height * scale).rounded())
            check(abs(rep.pixelsWide - expectedWide) <= 1 && abs(rep.pixelsHigh - expectedHigh) <= 1,
                  "the render should be the rendered view's own size in pixels "
                  + "(\(expectedWide)x\(expectedHigh) at \(scale)x), got "
                  + "\(rep.pixelsWide)x\(rep.pixelsHigh)", &ok)

            // And it is not one flat colour, which is what a view that never
            // drew looks like.
            //
            // A sweep rather than two chosen points, for the same reason: two
            // points in *pixel* coordinates land in different places on the
            // page at 1x and at 2x, so a pair that straddles a card on one
            // machine can sit on the same background on the other - which is
            // the second half of what the runner caught. A sweep cannot be
            // scale-dependent.
            var distinct = Set<String>()
            for row in 1..<8 {
                for column in 1..<8 {
                    let x = min(rep.pixelsWide * column / 8, rep.pixelsWide - 1)
                    let y = min(rep.pixelsHigh * row / 8, rep.pixelsHigh - 1)
                    guard let colour = rep.colorAt(x: x, y: y) else { continue }
                    distinct.insert(String(describing: colour))
                }
            }
            check(distinct.count >= 3,
                  "a 7x7 sweep of the render found \(distinct.count) distinct colour(s) - "
                  + "the page did not draw", &ok)
        }
        return ok
    }
}

#endif
