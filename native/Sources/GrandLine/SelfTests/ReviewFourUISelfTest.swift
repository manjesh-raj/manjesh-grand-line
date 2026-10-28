// Grand Line - native macOS app.
//
// Full review #4, section 7 (UI issues): the fixes a check can assert,
// beyond the ones that live in their page's own suite.
//
//   - R4-UI-02: Home's Fleet card fits "Done today", and the Health ring's
//     note wraps beside the gauge rather than truncating on one line.
//   - R4-UI-04: the Morning briefing underlines only the clause under the
//     pointer, never the whole paragraph.
//   - R4-UI-06: an editable shortcut draws its chord in the fixed rows' keycaps.
//   - R4-UI-07: copy names a module by the name the sidebar gives it.
//   - R4-UI-09: Snippets says why it asks for Accessibility.
//
// Elsewhere: R4-UI-01 is `WorkspaceToolbarSelfTest`, R4-UI-05 is
// `ReadingListViewSelfTest`, R2-UI-12's Code invitation is
// `CodePreviewViewSelfTest`, and the Tasks page's half of R4-UI-08 and
// R4-UI-09 (the Follow-ups lane, the Filter button, the Weekly review's
// agenda) is `MainSplitShellSelfTest.checkTasksBoardAndFilterRow`, which
// has the shell they need.
//
// Pure logic: no window. Every view here is laid out on its own, and the
// briefing's pointer is placed in its root view's coordinates, which is what
// `convert(_:from: nil)` reads for a view that is in no window.
//
// Run with:
//   swift build && FM_RUN_REVIEW4_UI_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum ReviewFourUISelfTest {

    static func run() -> Bool {
        HelmMotion.reducedOverrideForTests = true
        defer { HelmMotion.reducedOverrideForTests = nil }
        let captainScale = ChromeTextScale.shared.scale
        defer { ChromeTextScale.shared.setScale(captainScale) }

        var allOK = true
        for check in [checkFleetCaptionsFit, checkHealthNoteWrapsBesideTheRing, checkBriefingUnderlinesOneClause,
                      checkRecorderDrawsKeycaps, checkModuleNamesInCopy, checkSnippetsSayWhy] {
            var ok = true
            autoreleasepool { check(&ok) }
            allOK = allOK && ok
        }
        print(allOK ? "ReviewFourUISelfTest: all checks passed" : "ReviewFourUISelfTest: FAILED")
        return allOK
    }

    // MARK: R4-UI-02

    /// The Fleet card's strip at the width its body had at 1512 and 1280
    /// (a 283pt card less its 16pt insets), at Default and Larger text.
    private static func checkFleetCaptionsFit(_ ok: inout Bool) {
        let items: [HelmKPIStrip.Item] = [
            .count(0, caption: "Working"), .count(20, caption: "Done today"), .count(30, caption: "Queued"),
        ]
        for scale in [CGFloat(1.0), 1.3] {
            ChromeTextScale.shared.setScale(scale)
            let width: CGFloat = 251
            let strip = HelmKPIStrip()
            strip.configure(items)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
            host.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                strip.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            host.layoutSubtreeIfNeeded()
            let done = strip.debugCaptionLabels[1]
            // The fixture's discriminating power: three equal columns leave the
            // middle caption less than it needs, which is the defect.
            let equalShare = width / 3 - HelmKPIStrip.columnInset - HelmMetrics.s2
            check(done.intrinsicContentSize.width > equalShare,
                  "at \(scale)x \"Done today\" fits an equal third - the check is vacuous", &ok)
            for label in strip.debugCaptionLabels {
                check(label.frame.width + 0.5 >= label.intrinsicContentSize.width,
                      "R4-UI-02: at \(scale)x \"\(label.stringValue)\" is \(label.frame.width)pt of "
                      + "\(label.intrinsicContentSize.width)pt", &ok)
            }
        }
        ChromeTextScale.shared.setScale(1.0)
    }

    /// A Health card at the width it had at 1512: the note's wrap width is
    /// its column beside the gauge, and the note takes more than one line.
    private static func checkHealthNoteWrapsBesideTheRing(_ ok: inout Bool) {
        let card = HelmModuleCard()
        card.configure(.init(title: "Health", subtitle: "background services", symbol: "heart.fill", hue: .rose,
                             chip: .bad("1 failing"),
                             body: .ring(value: 7, total: 8, title: "Reporting",
                                         note: "Docs & runbooks sync needs a look.")))
        card.frame = NSRect(x: 0, y: 0, width: 283, height: 230)
        card.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        guard let note = card.debugRingNote else {
            check(false, "R4-UI-02: the ring body has no note label", &ok)
            return
        }
        let oneLine = note.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 14
        check(note.preferredMaxLayoutWidth <= note.frame.width + 0.5,
              "R4-UI-02: the note wraps at \(note.preferredMaxLayoutWidth)pt in a \(note.frame.width)pt column", &ok)
        check(note.frame.height > oneLine * 1.5,
              "R4-UI-02: the note is one \(note.frame.height)pt line beside the gauge, not wrapped", &ok)
    }

    // MARK: R4-UI-04

    /// Every clause a link, as the fleet and the follow-ups produce them: at
    /// rest nothing is underlined, the pointer over a clause underlines that
    /// clause alone, and leaving the paragraph clears it. The pointer enters
    /// through the view's own `mouseMoved`, which is what its tracking area
    /// calls, and the tracking area is asserted to ask for moves.
    private static func checkBriefingUnderlinesOneClause(_ ok: inout Bool) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        let paragraph = BriefingParagraphView()
        host.addSubview(paragraph)
        NSLayoutConstraint.activate([
            paragraph.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            paragraph.widthAnchor.constraint(equalToConstant: 420),
            paragraph.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
        ])
        paragraph.render([
            BriefingClause(text: "One fleet task needs a decision.", target: .fleet),
            BriefingClause(text: "Two personal follow-ups are due or overdue.", target: .tasks),
            BriefingClause(text: "20 fleet tasks finished today and 31 are queued.", target: .fleet),
        ], separator: " ", theme: ThemeManager.shared.theme)
        host.layoutSubtreeIfNeeded()
        paragraph.layoutSubtreeIfNeeded()
        paragraph.updateTrackingAreas()
        check(paragraph.debugLinkedCharacterCount > 0, "the fixture's clauses carry no links - the check is vacuous", &ok)
        check(paragraph.debugHoverAreaTracksMoves, "R4-UI-04: the paragraph does not track the pointer", &ok)
        check(paragraph.debugUnderlinedRanges.isEmpty,
              "R4-UI-04: at rest the paragraph is underlined at \(paragraph.debugUnderlinedRanges)", &ok)
        guard let second = paragraph.debugLinkRange(ofClause: 1),
              let point = paragraph.debugWindowPoint(over: second),
              let moved = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             eventNumber: 0, clickCount: 0, pressure: 0) else {
            check(false, "R4-UI-04: could not place the pointer over the second clause", &ok)
            return
        }
        paragraph.mouseMoved(with: moved)
        check(paragraph.debugUnderlinedRanges == [second],
              "R4-UI-04: over the second clause the underline is \(paragraph.debugUnderlinedRanges), want [\(second)]", &ok)
        if let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, eventNumber: 0,
                                               trackingNumber: 0, userData: nil) {
            paragraph.mouseExited(with: exited)
        }
        check(paragraph.debugUnderlinedRanges.isEmpty, "R4-UI-04: the underline stayed after the pointer left", &ok)
    }

    // MARK: R4-UI-06

    /// The recorder's caps are the fixed rows' caps for the same chord.
    private static func checkRecorderDrawsKeycaps(_ ok: inout Bool) {
        let zoom = KeyChord(keyCode: 36, modifierFlagsRaw: NSEvent.ModifierFlags([.control, .command]).rawValue,
                            isModifierOnly: false)
        let recorder = KeyChordRecorderView(shortcut: zoom, mode: .command)
        let fixed = KeyboardShortcutCatalog.keycaps(keyEquivalent: "\r", modifiers: [.control, .command])
        check(recorder.debugKeycapGlyphs == fixed,
              "R4-UI-06: ⌃⌘Return draws \(recorder.debugKeycapGlyphs ?? []) on an editable row, \(fixed) on a fixed one", &ok)
        check(recorder.debugShowsEditAffordance, "R4-UI-06: the editable row draws no edit affordance", &ok)
        check(!recorder.debugShowsTextLabel, "R4-UI-06: the editable row still prints the chord as text", &ok)
        let capture = KeyChordRecorderView(shortcut: KeyChord(keyCode: 49, modifierFlagsRaw:
            NSEvent.ModifierFlags.option.rawValue, isModifierOnly: false), mode: .command)
        check(capture.debugKeycapGlyphs == KeyboardShortcutCatalog.keycaps(keyEquivalent: " ", modifiers: [.option]),
              "R4-UI-06: ⌥Space draws \(capture.debugKeycapGlyphs ?? [])", &ok)
        let held = KeyChordRecorderView(shortcut: .dictationDefault)
        check(held.debugKeycapGlyphs == ["Right \u{2325}"],
              "R4-UI-06: a held modifier draws \(held.debugKeycapGlyphs ?? [])", &ok)
    }

    // MARK: R4-UI-07

    /// The copy the review quoted reads each module's name from `ModuleTable`.
    private static func checkModuleNamesInCopy(_ ok: inout Bool) {
        let saved = PlaceName.layout
        defer { PlaceName.layout = saved }
        PlaceName.layout = .sidebar
        let body = WorkspaceInspectorController.noDetailsBody
        for module in WorkspaceInspectorController.modulesWithDetails {
            check(body.contains(module.title), "R4-UI-07: the inspector's empty state omits \(module.title): \(body)", &ok)
        }
        check(!body.contains("Hosts") && !body.contains("Poneglyph"),
              "R4-UI-07: the inspector's empty state names a page, not a module: \(body)", &ok)
        check(ShortcutsTable.terminalPlaces == "\(WorkspaceModule.console.title) and \(WorkspaceModule.tools.title)",
              "R4-UI-07: the terminal shortcuts work in \"\(ShortcutsTable.terminalPlaces)\"", &ok)
        check(KubernetesController.openHostTitle == "Open in \(WorkspaceModule.console.title)",
              "R4-UI-07: Kubernetes offers \"\(KubernetesController.openHostTitle)\"", &ok)
        let persistence = HealthService.persistence.detail
        check(persistence.contains(WorkspaceModule.connections.title) && persistence.contains(WorkspaceModule.tasks.title),
              "R4-UI-07: Health describes persistence as \"\(persistence)\"", &ok)
    }

    // MARK: R4-UI-09 - Snippets

    private static func checkSnippetsSayWhy(_ ok: inout Bool) {
        let panel = SnippetExpansionPanel(style: .inline)
        panel.setState(enabled: false, trusted: false, armed: false, triggerCount: 0)
        check(!panel.debugGrantButtonIsHidden, "the fixture shows no Grant access - the check is vacuous", &ok)
        check(panel.debugGrantReason?.contains("Accessibility") == true,
              "R4-UI-09: Grant access shows without saying why (\(panel.debugGrantReason ?? "nil"))", &ok)
        panel.setState(enabled: true, trusted: true, armed: true, triggerCount: 2)
        check(panel.debugGrantReason == nil, "R4-UI-09: the reason stayed after access was granted", &ok)
    }

}

#endif
