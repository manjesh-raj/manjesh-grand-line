// Grand Line - native macOS app.
//
// The Dictation page's layout, from review bug B10 to Dic-1.
//
// **B10**, "the Dictation page's status card lays out wrong on first render".
// The review saw "Grand Line needs permission to use your microphone before it
// can dictate." rendered one word per line in a roughly 50pt column, with
// words broken mid-word, and the Status card grown to 380pt tall. The
// mechanism was a circular derivation: the wrapping label's
// `preferredMaxLayoutWidth` was fed from a stack whose width came from that
// same label (AGENTS.md gotcha (22)), so whichever pass ran first with a small
// width became permanent. Measured then: an intermediate 700pt layout locked
// the column at 11pt.
//
// **Dic-1** (fm/grand-line-dictation-dic1) replaced the Status card with the
// split card's gradient panel and the three control cards with `SettingsRow`s
// beside it. The B10 checks still stand, against the new owners of the
// wrapping text: the panel's words, and each control row's description. The
// rest of the suite asserts the split card itself, in the real sidebar shell:
// the panel's words, tone, ring and pill in each state, the four controls and
// their wiring, the library row's two columns, the narrow page, and the empty
// states.
//
// With `FM_DICTATION_RENDER_DIR` set it also writes one PNG per state, width
// and theme into that folder (the PR's renders). Nothing is written otherwise.
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
        print("== DictationStatusCardLayoutSelfTest ==")
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let savedTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(savedTheme) }
        let savedShortcut = AppSettings.shared.dictationShortcut
        defer { AppSettings.shared.dictationShortcut = savedShortcut }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-dic1-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let callerStores = SelfTestScratchStores.fingerprints()
        var ok = SelfTestScratchStores.within(scratch.appendingPathComponent("stores", isDirectory: true)) {
            var ok = true
            ThemeManager.shared.setTheme(daylight)
            ok = checkTheTextNeverCollapses() && ok
            ok = checkTheSettledPanelWrapsInsideItsCard() && ok
            ok = checkTheFirstPaintIsRendered() && ok
            let (window, shell) = ReviewTourLab.makeOffScreenSplitShell()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let checks: [(MainSplitShellController, NSWindow, inout Bool) -> Void] = [
                checkTheSplitCard, checkAMissingPermission, checkTheModelRing, checkTheControlsAreWired,
                checkTheNarrowPage, checkTheEmptyStates, writeRenders,
            ]
            for check in checks {
                var caseOK = true
                autoreleasepool { check(shell, window, &caseOK) }
                ok = ok && caseOK
            }
            return ok
        }
        let touched = SelfTestScratchStores.fingerprints().filter { callerStores[$0.key] != $0.value }.keys.sorted()
        check(touched.isEmpty, "the suite wrote to the caller's stores: \(touched)", &ok)
        print(ok ? "DictationStatusCardLayoutSelfTest: OK" : "DictationStatusCardLayoutSelfTest: FAILED")
        return ok
    }

    // MARK: Harness

    static var daylight: HelmTheme { HelmTheme.appThemes.first { $0.id == "daylight" } ?? ThemeManager.shared.theme }
    static var dusk: HelmTheme { HelmTheme.appThemes.first { $0.id == "dusk" } ?? ThemeManager.shared.theme }

    private static func settle(_ shell: WorkspaceShellController) {
        for _ in 0..<3 {
            shell.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        shell.view.layoutSubtreeIfNeeded()
    }

    private static func resize(_ window: NSWindow, width: CGFloat, _ shell: WorkspaceShellController) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
        settle(shell)
    }

    /// Dictation in the real sidebar shell, in `status` and with the model
    /// in `model`. Both are set after the page's own appear, which reads the
    /// test process's real permissions and the real model file.
    @discardableResult
    private static func showDictation(_ shell: MainSplitShellController, status: DictationStatus = .ready,
                                      model: WhisperModelState = .ready, localWhisper: Bool = true,
                                      cleanup: Bool = true) -> DictationController {
        shell.workspace.navigator.show(.dictation)
        shell.setInspectorShown(false)
        let page = shell.workspace.dictation
        settle(shell)
        page.debugSetToggles(cleanup: cleanup, localWhisper: localWhisper)
        page.debugSetModelState(model)
        page.debugSetStatus(status)
        settle(shell)
        return page
    }

    private static func seed(_ store: DictationStore, words: [String], dictations: Int) {
        for word in store.vocabulary { store.removeVocabularyWord(word) }
        for word in words { store.addVocabularyWord(word) }
        store.clearHistory()
        let lines = ["Initially, we can have something like a client and the internet, and that is also fine.",
                     "Spin an opus model crewmate for the Grand Line project and cover these three in one PR.",
                     "The S03 is not clear, let us fix this before the review.",
                     "Check the no-mistakes daemon status and reattach to the run.",
                     "Tear down the crewmate once every PR from it is merged."]
        for index in 0..<dictations {
            store.recordHistory(text: lines[index % lines.count], durationSeconds: Double(4 + index * 3),
                                date: Date().addingTimeInterval(-Double(index + 1) * 3600))
        }
    }

    private static func frame(of view: NSView, in page: NSView) -> NSRect {
        view.convert(view.bounds, to: page)
    }

    /// The height `label` needs at the width it was given, so a check can
    /// tell a wrapped sentence from a clipped one.
    private static func neededHeight(_ label: NSTextField) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height ?? 0)
    }

    // MARK: B10

    /// The defect proper. A layout pass at an intermediate width must not be
    /// able to lock a text column narrower than the floor.
    ///
    /// The intermediate widths are not arbitrary: `main.swift` assigns the
    /// content view controller and only then sets the window's frame (its own
    /// note on gotcha (3) says why that order is required), so the page really
    /// does get laid out at a width that is not its final one, and
    /// `viewDidLayout` really does run against it.
    private static func checkTheTextNeverCollapses() -> Bool {
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
                controller.view.frame = NSRect(x: 0, y: 0, width: finalWidth, height: 900)
                controller.view.layoutSubtreeIfNeeded()
                controller.viewDidLayout()
                controller.view.layoutSubtreeIfNeeded()

                let floor = DictationController.debugDetailMinimumWidth
                for row in controller.debugControlRows {
                    let locked = row.descriptionLabel?.preferredMaxLayoutWidth ?? 0
                    observed.append(locked)
                    check(locked >= floor,
                          "@\(intermediate)pt intermediate: \"\(row.titleLabel.stringValue)\"'s description was set "
                          + "to \(locked)pt, below the \(floor)pt floor - that is the one-word-per-line card (B10)", &ok)
                }
                let body = controller.debugHeroCard.panel.debugBodyLabel
                check(body.frame.width >= floor,
                      "@\(intermediate)pt intermediate: the panel's sentence settled \(body.frame.width)pt wide (B10)", &ok)
            }
        }

        // Discriminating power: the sweep has to have produced real numbers.
        check(observed.count == 20, "expected four rows over five passes, got \(observed.count)", &ok)
        check(observed.allSatisfy { $0 > 0 }, "every pass set a real width, got \(observed)", &ok)
        return ok
    }

    /// The other direction, so the floor cannot be satisfied by pinning every
    /// column at 180pt: once the page has its real width, the words wrap at
    /// it, are drawn in full, and stay inside a card the height of its content.
    private static func checkTheSettledPanelWrapsInsideItsCard() -> Bool {
        var ok = true
        // 830: the page beside the window sidebar at a 1100pt window. The
        // last case shrinks from the page's width at 1512 to that, the way a
        // window resize reaches it.
        for (first, width) in [(700.0, 1512.0), (700.0, 1100.0), (1240.0, 830.0)] as [(CGFloat, CGFloat)] {
            for status in [DictationStatus.needsMicrophone, .copiedOnly] {
                autoreleasepool {
                    let controller = DictationController(store: DictationStore())
                    let window = OffScreenProbe.window(width: width, height: 900)
                    defer { window.contentView = nil; window.close() }
                    window.contentView = controller.view

                    controller.view.frame = NSRect(x: 0, y: 0, width: first, height: 900)
                    controller.debugSetStatus(status)
                    controller.view.layoutSubtreeIfNeeded()
                    controller.viewDidLayout()
                    controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                    controller.view.layoutSubtreeIfNeeded()
                    controller.viewDidLayout()
                    controller.view.layoutSubtreeIfNeeded()

                    let card = controller.debugHeroCard
                    let panel = card.panel
                    let body = panel.debugBodyLabel
                    check(card.bounds.width > 300,
                          "@\(width): the fixture is vacuous unless the card really resolved wide, got \(card.bounds.width)pt", &ok)
                    check(body.stringValue == status.detail(shortcutDisplay: KeyChord.dictationDefault.displayString)
                          || body.stringValue.hasPrefix(String(status.detail(shortcutDisplay: "").prefix(20))),
                          "@\(width) \(status): the panel's sentence is \"\(body.stringValue)\"", &ok)
                    // S15/B10: the sentence is wrapped, not cut off. The
                    // copied-only guidance is the longest words on the page,
                    // and the panel says all of it.
                    check(body.frame.height + 1 >= neededHeight(body),
                          "@\(width) \(status): the sentence needs \(neededHeight(body))pt and got \(body.frame.height)pt", &ok)
                    let inPanel = body.convert(body.bounds, to: panel)
                    check(panel.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inPanel),
                          "@\(width) \(status): the sentence \(inPanel) runs out of the panel \(panel.bounds)", &ok)
                    let inCard = panel.convert(panel.bounds, to: card)
                    check(card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inCard),
                          "@\(width) \(status): the panel \(inCard) runs out of its card \(card.bounds)", &ok)
                    // The captain's own B10 symptom was a card grown far past
                    // its words. A side-by-side card is as tall as its rows.
                    if !card.isStacked, status == .needsMicrophone {
                        check(card.bounds.height < 340,
                              "@\(width): the split card is \(card.bounds.height)pt tall for four rows", &ok)
                    }
                }
            }
        }
        return ok
    }

    /// UI-53: mounted with no `viewWillAppear` and no status pushed - a
    /// destination's first frame. The old Status card used to show its
    /// unfilled chrome: an empty tile, no title, and an untitled button.
    private static func checkTheFirstPaintIsRendered() -> Bool {
        var ok = true
        autoreleasepool {
            let controller = DictationController(store: DictationStore())
            let window = OffScreenProbe.window(width: 1512, height: 900)
            defer { window.contentView = nil; window.close() }
            window.contentView = controller.view
            controller.view.layoutSubtreeIfNeeded()
            let panel = controller.debugHeroCard.panel
            check(!panel.debugHeadline.isEmpty, "the first paint's verdict is empty - the panel was never rendered", &ok)
            check(panel.debugFootButtons.count == 1 && !(panel.debugFootButtons.first?.title.isEmpty ?? true),
                  "the first paint's pill is \(panel.debugFootButtons.map(\.title)), want one titled pill", &ok)
        }
        return ok
    }

    // MARK: Dic-1

    private static func checkTheSplitCard(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        seed(shell.workspace.dictationStore, words: ["Herdr", "Claude", "Firstmate"], dictations: 5)
        let page = showDictation(shell)
        let card = page.debugHeroCard
        let panel = card.panel
        check(!card.isStacked, "Dic-1: the split card stacks on a \(card.bounds.width)pt page at 1512", &ok)
        check(panel.arrangement == .panel, "Dic-1: the gradient is a \(panel.arrangement), want .panel", &ok)
        check(panel.debugKicker == "Dictation \u{00B7} On device", "Dic-1: the kicker is \"\(panel.debugKicker)\"", &ok)
        check(panel.debugHeadline == "Ready. " + DictationStatus.ready.detail(
                shortcutDisplay: AppSettings.shared.dictationShortcut.displayString),
              "Dic-1: the verdict is \"\(panel.debugHeadline)\"", &ok)
        check(panel.debugBody?.contains("3 words in your vocabulary, 5 dictations kept here.") == true,
              "Dic-1: the body does not count the library: \"\(panel.debugBody ?? "")\"", &ok)
        check(panel.debugBody?.hasPrefix("Whisper large-v3-turbo on this Mac, cleanup on.") == true,
              "Dic-1: the body does not name the engine: \"\(panel.debugBody ?? "")\"", &ok)
        check(panel.debugRing?.debugLabel == "\u{2713}", "Dic-1: a ready model's ring reads \(panel.debugRing?.debugLabel ?? "nothing")", &ok)
        check(panel.debugFootButtons.map(\.title) == ["Re-check permissions"],
              "Dic-1: the pills are \(panel.debugFootButtons.map(\.title))", &ok)
        // The pill is its own width. The panel's leading-aligned column
        // stretched a lone pill across the whole panel until its foot row
        // hugged at stack level (gotcha (12)).
        if let pill = panel.debugFootButtons.first {
            check(pill.frame.width > 0 && pill.frame.width <= ceil(pill.fittingSize.width) + 1,
                  "Dic-1: the pill is \(pill.frame.width)pt wide for \(pill.fittingSize.width)pt of content", &ok)
        }
        check(panel.debugPalette == HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: daylight),
              "Dic-1: a ready page is not the accent", &ok)
        check(page.debugControlRows.map(\.titleLabel.stringValue)
                == ["Shortcut", "Clean up my sentences", "Use local Whisper engine", "Whisper model"],
              "Dic-1: the controls are \(page.debugControlRows.map(\.titleLabel.stringValue))", &ok)
        // Every control is on the card's own half, beside the panel.
        let panelFrame = frame(of: panel, in: card)
        for row in page.debugControlRows {
            let rowFrame = frame(of: row, in: card)
            check(rowFrame.minX >= panelFrame.maxX - 0.5 && rowFrame.maxX <= card.bounds.maxX + 0.5,
                  "Dic-1: \"\(row.titleLabel.stringValue)\" \(rowFrame) is not beside the panel \(panelFrame)", &ok)
            let control = frame(of: row.control, in: card)
            check(control.maxX <= card.bounds.maxX + 0.5 && control.width > 0,
                  "Dic-1: \"\(row.titleLabel.stringValue)\"'s control \(control) runs out of the card", &ok)
        }
        // The model row: Ready, Re-download and the menu.
        check(!page.debugModelDeleteButton.isHidden && page.debugModelActionButton.title == "Re-download",
              "Dic-1: a ready model's row offers \(page.debugModelActionButton.title)", &ok)
        let pill = page.debugModelReadyPillFrame
        check(pill.width > 0 && pill.width < 120, "B10: the model's Ready pill is \(pill.width)pt wide", &ok)
        // Words and Recent side by side, under the card.
        check(!page.libraryIsStacked, "Dic-1: Words and Recent are not side by side at 1512", &ok)
        let words = frame(of: page.debugVocabularyCard, in: page.view)
        let recent = frame(of: page.debugHistoryCard, in: page.view)
        check(abs(words.width - recent.width) < 1 && recent.minX > words.maxX,
              "Dic-1: Words \(words) and Recent \(recent) are not two equal columns", &ok)
        let top: (NSRect) -> CGFloat = { page.view.isFlipped ? $0.minY : $0.maxY }
        check(abs(top(words) - top(recent)) < 0.5, "Dic-1: Words \(words) and Recent \(recent) do not start level", &ok)
        let cardFrame = frame(of: card, in: page.view)
        check(page.view.isFlipped ? words.minY > cardFrame.maxY : words.maxY < cardFrame.minY,
              "Dic-1: Words \(words) is not under the split card \(cardFrame)", &ok)
        check(abs(words.minX - cardFrame.minX) < 0.5 && abs(recent.maxX - cardFrame.maxX) < 0.5,
              "Dic-1: the library row \(words.minX)...\(recent.maxX) is not the card's width \(cardFrame)", &ok)
        check(page.debugHistoryList.tableView.numberOfRows == 5, "Dic-1: Recent lists \(page.debugHistoryList.tableView.numberOfRows) rows", &ok)
    }

    private static func checkAMissingPermission(_ shell: MainSplitShellController, _ window: NSWindow,
                                                _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        for (status, permission) in [(DictationStatus.needsMicrophone, "Microphone"),
                                     (.needsSpeechRecognition, "Speech Recognition"),
                                     (.needsAccessibility, "Accessibility"), (.copiedOnly, "Accessibility")] {
            let page = showDictation(shell, status: status, model: .notDownloaded)
            let panel = page.debugHeroCard.panel
            let words = DictationHeroWords.make(status: status, shortcutDisplay: "", localWhisperEnabled: true,
                                                cleanupEnabled: true, model: .notDownloaded, modelBytes: nil,
                                                words: 0, dictations: 0)
            check(words.tone == .amber, "Dic-1: \(status) does not tone the panel amber", &ok)
            let accent = HelmHeroColumn.palette(for: HelmModuleCard.HeroTone(colour: .themeAccent), in: daylight)
            check(panel.debugPalette != accent, "Dic-1: \(status) still paints the accent", &ok)
            check(panel.debugFootButtons.map(\.title) == ["Request Access"],
                  "Dic-1: \(status)'s pills are \(panel.debugFootButtons.map(\.title))", &ok)
            check(page.debugStatusActionButton.toolTip == "Request \(permission) Access",
                  "Dic-1: \(status)'s pill asks for \(page.debugStatusActionButton.toolTip ?? "nothing")", &ok)
            check(panel.debugKicker.hasPrefix("Dictation \u{00B7} ") && !panel.debugKicker.hasSuffix("On device"),
                  "Dic-1: \(status) still claims \"\(panel.debugKicker)\"", &ok)
            // UXP-08: one primary. The missing permission is the blocker, so
            // the model's Download steps down, as it did beside the old card.
            check(page.debugModelActionVariant == .secondary,
                  "UXP-08: \(status) leaves the model's Download a primary", &ok)
        }
        let page = showDictation(shell, status: .ready, model: .notDownloaded)
        check(page.debugModelActionVariant == .primary,
              "UXP-08: with every permission granted the model's Download is the page's primary again", &ok)
    }

    private static func checkTheModelRing(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        var page = showDictation(shell, model: .downloading(progress: 0.42))
        var panel = page.debugHeroCard.panel
        check(panel.debugRing?.debugLabel == "42%", "Dic-1: a download's ring reads \(panel.debugRing?.debugLabel ?? "nothing")", &ok)
        check(!page.debugModelProgressBar.isHidden && page.debugModelActionButton.title == "Cancel",
              "Dic-1: a download's row offers \(page.debugModelActionButton.title)", &ok)
        check(page.debugModelRow.descriptionLabel?.stringValue == "Downloading\u{2026} 42%",
              "Dic-1: the model row says \"\(page.debugModelRow.descriptionLabel?.stringValue ?? "")\"", &ok)

        page = showDictation(shell, model: .notDownloaded)
        panel = page.debugHeroCard.panel
        check(panel.debugRing?.debugLabel == "\u{2013}", "Dic-1: an absent model's ring reads \(panel.debugRing?.debugLabel ?? "nothing")", &ok)
        check(page.debugModelActionButton.title == "Download Model" && page.debugModelDeleteButton.isHidden,
              "Dic-1: an absent model's row offers \(page.debugModelActionButton.title)", &ok)
        check(panel.debugBody?.hasPrefix("Apple Speech until the Whisper model is downloaded") == true,
              "Dic-1: with no model the body says \"\(panel.debugBody ?? "")\"", &ok)

        page = showDictation(shell, model: .failed("offline"))
        check(page.debugModelActionButton.title == "Retry Download"
                && page.debugModelRow.descriptionLabel?.stringValue == "Download failed: offline",
              "Dic-1: a failed download's row offers \(page.debugModelActionButton.title)", &ok)

        page = showDictation(shell, model: .ready, localWhisper: false, cleanup: false)
        panel = page.debugHeroCard.panel
        // UI-09 of full review 4: the ring says which engine listens - a
        // microphone captioned "Apple Speech" - and says it in the ink,
        // since Apple Speech is a working engine, not an absent reading.
        check(panel.debugRing?.debugSymbol == "mic.fill" && panel.debugRing?.debugLabel != "Off",
              "UI-09: the engine off draws \(panel.debugRing?.debugSymbol ?? panel.debugRing?.debugLabel ?? "nothing")", &ok)
        check(panel.debugBody?.hasPrefix("Listening with Apple Speech, cleanup off. The local Whisper model is off.") == true,
              "UI-09: the engine and cleanup off say \"\(panel.debugBody ?? "")\"", &ok)
        if let gauge = panel.debugRing {
            let ink = panel.ink
            check(abs((gauge.labelColorOverride?.alphaComponent ?? 0) - ink.alphaComponent) < 0.05,
                  "UI-09: Apple Speech's ring is drawn dimmed", &ok)
        }
    }

    private static func checkTheControlsAreWired(_ shell: MainSplitShellController, _ window: NSWindow,
                                                 _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        let page = showDictation(shell)
        // Target and action are what a real click runs - a click on a pill or
        // a toggle reaches exactly these.
        check(page.debugRecheckButton.target === page && page.debugRecheckButton.action == Selector(("refreshTapped")),
              "Dic-1: Re-check permissions does not run the page's refresh", &ok)
        check(page.debugStatusActionButton.target === page
                && page.debugStatusActionButton.action == Selector(("statusActionTapped")),
              "Dic-1: Request Access does not run the permission request", &ok)
        check(page.debugCleanupSwitch.target === page && page.debugCleanupSwitch.action == Selector(("cleanupToggled")),
              "Dic-1: Clean up my sentences is not wired", &ok)
        check(page.debugLocalWhisperSwitch.target === page
                && page.debugLocalWhisperSwitch.action == Selector(("localWhisperToggled")),
              "Dic-1: Use local Whisper engine is not wired", &ok)
        check(page.debugModelActionButton.target === page
                && page.debugModelActionButton.action == Selector(("modelActionTapped")),
              "Dic-1: the model's action is not wired", &ok)
        check(page.debugModelDeleteButton.action == Selector(("modelMoreTapped:")), "Dic-1: the model's menu is not wired", &ok)
        // UXP-16 on the new row: the reset shows only off the default.
        page.debugSetShortcut(.dictationDefault)
        check(!page.debugShortcutResetIsShowing, "UXP-16: Reset shows while the chord is the default", &ok)
        var other = KeyChord.dictationDefault
        other.keyCode = other.keyCode == 0 ? 1 : 0
        page.debugSetShortcut(other)
        check(page.debugShortcutResetIsShowing, "UXP-16: Reset hides while the chord is not the default", &ok)
        check(page.debugHeroCard.panel.debugHeadline.contains(other.displayString),
              "Dic-1: the verdict does not follow the new chord: \"\(page.debugHeroCard.panel.debugHeadline)\"", &ok)
        page.debugSetShortcut(.dictationDefault)
    }

    private static func checkTheNarrowPage(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        for width in [1100, 960] as [CGFloat] {
            resize(window, width: width, shell)
            let page = showDictation(shell, status: .needsAccessibility, model: .downloading(progress: 0.3))
            let card = page.debugHeroCard
            check(card.isStacked == (card.bounds.width < card.stackedBelow),
                  "Dic-1: a \(card.bounds.width)pt card is \(card.isStacked ? "" : "not ")stacked", &ok)
            let pageWidth = page.view.bounds.width
            check(frame(of: card, in: page.view).maxX <= pageWidth + 0.5,
                  "Dic-1 @\(width): the card runs past the page's \(pageWidth)pt", &ok)
            for row in page.debugControlRows {
                let control = frame(of: row.control, in: page.view)
                check(control.maxX <= frame(of: card, in: page.view).maxX + 0.5,
                      "Dic-1 @\(width): \"\(row.titleLabel.stringValue)\"'s control \(control) runs out of the card", &ok)
                if let label = row.descriptionLabel {
                    check(label.frame.width >= DictationController.debugDetailMinimumWidth - 0.5,
                          "Dic-1 @\(width): \"\(row.titleLabel.stringValue)\" wraps at \(label.frame.width)pt", &ok)
                }
            }
            let library = page.debugLibraryRow
            let wantsTwo = library.bounds.width >= 2 * DictationController.libraryColumnMinWidth
                + DictationController.libraryGap
            check(page.libraryIsStacked != wantsTwo,
                  "Dic-1 @\(width): a \(library.bounds.width)pt library row is \(page.libraryIsStacked ? "one column" : "two")", &ok)
            if page.libraryIsStacked {
                let words = frame(of: page.debugVocabularyCard, in: page.view)
                let recent = frame(of: page.debugHistoryCard, in: page.view)
                check(abs(words.width - library.bounds.width) < 1 && abs(recent.width - library.bounds.width) < 1,
                      "Dic-1 @\(width): stacked, Words \(words.width) and Recent \(recent.width) do not fill \(library.bounds.width)", &ok)
            }
        }
        // Back to wide: each card is its own height again. A stack that
        // flipped vertical and back left both at the taller one's height.
        resize(window, width: 1512, shell)
        seed(shell.workspace.dictationStore, words: ["Herdr"], dictations: 5)
        let page = showDictation(shell)
        let words = page.debugVocabularyCard.frame.height
        let recent = page.debugHistoryCard.frame.height
        check(!page.libraryIsStacked && words < recent - 20,
              "Dic-1: back at 1512 Words is \(words)pt beside Recent's \(recent)pt - stretched to the taller card", &ok)
    }

    private static func checkTheEmptyStates(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        resize(window, width: 1512, shell)
        seed(shell.workspace.dictationStore, words: [], dictations: 0)
        let page = showDictation(shell)
        let panel = page.debugHeroCard.panel
        check(panel.debugBody?.hasSuffix("No words in your vocabulary yet, no dictations kept yet.") == true,
              "Dic-1: an empty library says \"\(panel.debugBody ?? "")\"", &ok)
        check(page.debugHistoryList.tableView.numberOfRows == 1,
              "Dic-1: an empty history draws \(page.debugHistoryList.tableView.numberOfRows) rows, want its one empty state", &ok)
        check(!page.debugVocabularyPlaceholder.isEmpty, "Dic-1: an empty words well has no placeholder", &ok)
    }

    // MARK: Renders

    private static func writeRenders(_ shell: MainSplitShellController, _ window: NSWindow, _ ok: inout Bool) {
        guard let dir = ProcessInfo.processInfo.environment["FM_DICTATION_RENDER_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = shell.workspace.dictationStore
        let vocabulary = ["Herdr", "Claude", "Firstmate", "claude.md", "agents.md", "Manjesh", "Grand Line",
                          "chrome-devtools-axi", "lavish", "tmux", "logs", "crewmate", "repo"]
        let states: [(name: String, status: DictationStatus, model: WhisperModelState, whisper: Bool, full: Bool)] = [
            ("ready", .ready, .ready, true, true),
            ("downloading", .ready, .downloading(progress: 0.42), true, true),
            ("no-model", .ready, .notDownloaded, true, true),
            ("whisper-off", .ready, .ready, false, true),
            ("needs-microphone", .needsMicrophone, .ready, true, true),
            ("recording", .recording, .ready, true, true),
            ("empty", .ready, .ready, true, false),
        ]
        for theme in [daylight, dusk] {
            ThemeManager.shared.setTheme(theme)
            for width in [1512, 1100] as [CGFloat] {
                resize(window, width: width, shell)
                for state in states {
                    seed(store, words: state.full ? vocabulary : [], dictations: state.full ? 5 : 0)
                    let page = showDictation(shell, status: state.status, model: state.model, localWhisper: state.whisper)
                    write(page.view, to: folder.appendingPathComponent("dictation-\(state.name)-\(theme.id)-\(Int(width)).png"))
                }
            }
        }
        ThemeManager.shared.setTheme(daylight)
        resize(window, width: 1512, shell)
        print("DictationStatusCardLayoutSelfTest: renders written to \(dir)")
    }

    private static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

#endif
