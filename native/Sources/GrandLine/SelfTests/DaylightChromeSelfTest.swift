// Grand Line - native macOS app.
//
// Daylight **Phase 5**'s own suite: the app's chrome that is not a destination
// page - the nine editor sheets (§6.10), the ⌘K palette (§6.11), the
// notification panel (§6.12), and toasts plus empty states (§6.14).
//
// What each case is protecting, and why it is worth a test rather than a
// read-through:
//
//   1. **The scaffold really applied §6.10 to every sheet, uniformly.** The
//      whole reason §6.10 says "the scaffold makes that automatic" is that
//      nine hand-restyled sheets drift. So this walks all nine, reaching each
//      one's `HelmFormSheet` *through its own root view* rather than through a
//      stored property - which also proves the scaffold is still the root, the
//      thing that lets it own the sheet's background, appearance and single
//      theme observation.
//   2. **The close square dismisses the same way Cancel does.** It takes no
//      selector of its own; it borrows Cancel's. A square wired to nothing
//      renders perfectly and does nothing, which is invisible in a diff and in
//      a render.
//   3. **The Save capsule's gradient is legible end to end.** A white label on
//      a raw Daylight ramp measures as low as 2.5:1 at the midpoint - fine for
//      a `HelmGradientTile`, whose glyph always sits beside a text label saying
//      the same thing, and not fine for a button whose word *is* the
//      affordance. Both stops are asserted against the 4.5:1 floor, **and** the
//      raw pair is asserted to genuinely fail for at least one hue, so the
//      correction cannot pass for an unrelated reason.
//   4. **The twelve pre-Daylight palettes are byte-identical.** Every slice of
//      this migration has held to that, and this phase's two riskiest edits for
//      it are `HelmButton.domainHue` (which re-points a `.primary`'s fill in
//      *every* palette, not just Daylight) and the ghost-Cancel variant swap.
//   5. **§6.11's palette chrome and rows**, including that the gradient tile
//      and the flat tinted tile are never both visible, and that the selected
//      row's `inset` fill and 3px `ink` edge are real.
//   6. **The palette is a reskin only.** Query -> group -> arrow -> Return ->
//      the item's own `activate()` still runs, measured by counting a real
//      activation.
//   7. **§6.12's "Mark all read" is the shared button and still marks all
//      read.** It was a label in a `HoverHighlightView` predating `HelmButton`;
//      swapping the control is exactly the kind of change that silently drops
//      a target/action.
//   8. **The toast recipe**, measured off the real pill the real
//      `Toast.show` put in a real container. Since TO-1 that is the hero
//      capsule in Lavender and Powder: the quiet-ink gradient, white words,
//      the kind's glyph in its lifted hue, Undo as a ghost pill whose ring
//      drains (none under Reduce Motion), and G1's bottom-centre stacking.
//   9. **§6.14's empty state is still the Daylight plate.** Phase 4 shipped it;
//      this phase touches the same file, so it is pinned rather than assumed.
//  10. **§6.10's attachment well** is dashed on radius 14 with a link-coloured
//      "choose a file", and keeps its solid border on the other twelve.
//
// Run with:
//   swift build && FM_RUN_DAYLIGHT_CHROME_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DaylightChromeSelfTest {

    static func run() -> Bool {
        // `ThemeManager.setTheme` persists to the real `UserDefaults`, so the
        // captain's own selection is put back before this returns - the
        // convention every Daylight suite in this directory follows.
        let restoreTheme = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(restoreTheme) }
        var allOK = true
        for check in [checkSheetRecipeAcrossEverySheet,
                      checkCloseSquareDismissesThroughCancel,
                      checkSaveGradientIsLegible,
                      checkOtherPalettesUnchanged,
                      checkPaletteChrome,
                      checkPaletteStillDispatches,
                      checkNotificationPanelGhostAction,
                      checkToastRecipe,
                      checkEmptyStatePlate,
                      checkAttachmentWell] {
            var ok = true
            check(&ok)
            allOK = allOK && ok
        }
        print(allOK ? "DaylightChromeSelfTest: all checks passed"
                    : "DaylightChromeSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    private static var daylight: HelmTheme {
        HelmTheme.allThemes.first { $0.isDaylight } ?? HelmTheme.allThemes[0]
    }

    private static var otherThemes: [HelmTheme] {
        HelmTheme.allThemes.filter { !$0.isDaylight }
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }

    /// Component-wise, deliberately **not** a luminance-ratio comparison: that
    /// passes for two entirely different hues of similar brightness (the trap
    /// Phase 4 slice 2's own suite documents, hit twice).
    private static func sameColor(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a else { return false }
        let x = HelmContrast.components(a)
        let y = HelmContrast.components(b)
        return abs(x.0 - y.0) < 0.004 && abs(x.1 - y.1) < 0.004 && abs(x.2 - y.2) < 0.004
    }

    private static func scratchStores() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daylight-chrome-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_HOSTS_FILE", dir.appendingPathComponent("hosts.json").path, 1)
        setenv("FM_KEYS_FILE", dir.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)
        setenv("FM_SHIFT_DIR", dir.appendingPathComponent("shift").path, 1)
        setenv("FM_COMMAND_LIBRARY_DIR", dir.appendingPathComponent("commands").path, 1)
    }

    /// Every editor sheet in the app, each reached through its real controller.
    ///
    /// The six §6.10 names ("all six editor sheets") plus the three built after
    /// that section was written - Key, Schedule and the multi-host send picker -
    /// because the scaffold cannot restyle six of nine and leave three behind.
    private static func everySheet() -> [(name: String, controller: NSViewController)] {
        scratchStores()
        let keyStore = SSHKeyStore()
        return [
            ("Task", ShiftTaskEditorController(task: nil, projects: [])),
            ("Follow-up", ShiftFollowUpEditorController(followUp: nil, tasks: [], projects: [])),
            ("Project", ShiftProjectEditorController()),
            ("Snippet", SnippetEditorController(snippet: nil)),
            ("Command", CommandEditorController(editingID: nil, prefill: nil,
                                                config: .empty)),
            ("Host", HostEditorController(host: nil, keyStore: keyStore, snippets: [])),
            ("Key", KeyEditorController(key: nil)),
            ("Schedule", ScheduleEditorController(schedule: nil)),
            ("Send to…", MultiHostSendPickerController(command: sampleCommand(),
                                             generatedText: "kubectl get pods",
                                             hosts: [],
                                             isConnected: { _ in false })),
        ]
    }

    private static func sampleCommand() -> DevOpsCommand {
        DevOpsCommand(id: "k/get-pods", name: "Get pods", description: "",
                      category: "Kubernetes", commandTemplate: "kubectl get pods",
                      risk: .readOnly)
    }

    /// The sheet is the controller's root view - reaching it this way is also
    /// the assertion that that is still true.
    private static func sheet(of controller: NSViewController) -> HelmFormSheet? {
        controller.view as? HelmFormSheet
    }

    private static func mount(_ controller: NSViewController) {
        let window = OffScreenProbe.window(width: 700, height: 800)
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
    }

    // MARK: 1. §6.10 across every sheet

    private static func checkSheetRecipeAcrossEverySheet(_ ok: inout Bool) {
        print("\n-- §6.10: one scaffold, nine sheets --")
        let theme = daylight
        ThemeManager.shared.setTheme(theme)
        let card = HelmTheme.nsColor(DaylightPalette.card)
        let muted = HelmTheme.mutedInk(theme)
        var sheetsWithKeycaps = 0

        for (name, controller) in everySheet() {
            guard let form = sheet(of: controller) else {
                print("  FAIL \(name): root view is not a HelmFormSheet")
                ok = false
                continue
            }
            mount(controller)
            form.refreshTheme()
            let g = form.debugDaylightGeometry

            var problems: [String] = []
            if !sameColor(form.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }, card) {
                problems.append("ground is not `card`")
            }
            if g.ribbonHidden { problems.append("no domain ribbon") }
            if abs(g.ribbonHeight - HelmFormSheet.ribbonHeight) > 0.01 {
                problems.append("ribbon \(fmt(g.ribbonHeight))pt, want \(fmt(HelmFormSheet.ribbonHeight))")
            }
            let expectedPair = g.hue.pair(in: theme)
            if g.ribbonColors.count != 2
                || !sameColor(g.ribbonColors.first, expectedPair.h1)
                || !sameColor(g.ribbonColors.last, expectedPair.h2) {
                problems.append("ribbon is not \(g.hue)'s own pair")
            }
            if g.headingFont?.pointSize != HelmType.scaled(20) {
                problems.append("heading \(g.headingFont.map { fmt($0.pointSize) } ?? "nil"), want 20")
            }
            if g.subtitleText.isEmpty || g.subtitleHidden { problems.append("no header subtitle") }
            if !sameColor(g.subtitleColor, muted) { problems.append("subtitle is not `muted`") }
            if g.closeHidden { problems.append("no close square") }
            if abs(g.closeSide - HelmFormSheet.closeSquareSide) > 0.51 {
                problems.append("close square \(fmt(g.closeSide))pt, want \(fmt(HelmFormSheet.closeSquareSide))")
            }
            if abs(g.closeRadius - HelmMetrics.dTileSmall) > 0.01 {
                problems.append("close radius \(fmt(g.closeRadius)), want \(fmt(HelmMetrics.dTileSmall))")
            }
            if !sameColor(g.closeFill, HelmField.fill(theme)) {
                problems.append("close square is not an `inset` fill")
            }
            // F2c inverted this. The hint used to be one mono label holding
            // "⌘⏎ to save"; it is `HelmKeyHint` keycaps plus a caption now, so
            // "is it mono" no longer describes anything - what matters is that
            // there are real caps carrying real glyphs, at the keycap radius.
            if g.hintText.isEmpty { problems.append("no footer hint") }
            // A footer note has two legitimate shapes, and `setFooter`'s two
            // override parameters are exactly that distinction: keycaps plus a
            // caption (the default, and `hintCaption:`), or prose with no
            // keycaps at all (`hint:` - "Stored securely in macOS Keychain",
            // which is not about a key). So this asserts the keycap *recipe*
            // wherever caps exist, and `sheetsWithKeycaps` below asserts they
            // have not silently vanished everywhere.
            if !g.hintCapGlyphs.isEmpty {
                sheetsWithKeycaps += 1
                if g.hintCapGlyphs.contains(where: { $0.isEmpty }) {
                    problems.append("a footer keycap is blank")
                }
                // The whole point of F2c: macOS's own Return glyph, not U+23CE.
                if g.hintCapGlyphs.last != HelmKeyHint.returnKey {
                    problems.append("last cap is \(g.hintCapGlyphs.last ?? "nil"), want U+21A9")
                }
                if g.hintCapGlyphs.contains("\u{23ce}") {
                    problems.append("footer hint still uses U+23CE")
                }
                if g.hintCapRadii.contains(where: { abs($0 - HelmKeyHint.capCornerRadius) > 0.01 }) {
                    problems.append("a footer keycap is not at the keycap radius")
                }
            }
            if g.cancelVariant != .quiet { problems.append("Cancel is \(String(describing: g.cancelVariant)), want ghost/.quiet") }
            if g.confirmVariant != .primary { problems.append("Save is not .primary") }
            if g.confirmHue != g.hue { problems.append("Save does not carry the sheet's hue") }
            if !g.confirmGradient { problems.append("Save is not a gradient capsule") }

            if problems.isEmpty {
                print("  OK   \(name) (hue \(g.hue), hint \"\(g.hintText)\")")
            } else {
                print("  FAIL \(name): \(problems.joined(separator: "; "))")
                ok = false
            }
        }

        // F2c's own floor. Every per-sheet check above is conditional on a
        // sheet *having* keycaps, so a regression that stopped building them
        // altogether would leave each sheet reporting OK. This is what fails
        // instead.
        if sheetsWithKeycaps < 2 {
            print("  FAIL only \(sheetsWithKeycaps) sheet(s) render keycaps - F2c's hint is gone")
            ok = false
        } else {
            print("  OK   \(sheetsWithKeycaps) sheets render the shortcut as keycaps")
        }
    }

    // MARK: 2. The close square borrows Cancel's action

    private final class CancelRecorder: NSObject {
        var cancels = 0
        var confirms = 0
        @objc func cancelled() { cancels += 1 }
        @objc func confirmed() { confirms += 1 }
    }

    private static func checkCloseSquareDismissesThroughCancel(_ ok: inout Bool) {
        print("\n-- §6.10: the close square dismisses through Cancel --")
        ThemeManager.shared.setTheme(daylight)
        let form = HelmFormSheet(title: "Probe", domainHue: .rose)
        let recorder = CancelRecorder()
        _ = form.setFooter(target: recorder, confirmTitle: "Save",
                           confirm: #selector(CancelRecorder.confirmed),
                           cancel: #selector(CancelRecorder.cancelled))
        form.refreshTheme()
        form.debugClickCloseSquare()
        if recorder.cancels == 1 && recorder.confirms == 0 {
            print("  OK   one cancel, no confirm")
        } else {
            print("  FAIL cancels=\(recorder.cancels) confirms=\(recorder.confirms), want 1/0")
            ok = false
        }

        // Before `setFooter` there is nothing to dismiss to, so the square must
        // not be offered at all.
        let bare = HelmFormSheet(title: "Bare")
        bare.refreshTheme()
        if bare.debugDaylightGeometry.closeHidden {
            print("  OK   hidden until a footer exists")
        } else {
            print("  FAIL close square offered with no cancel action behind it")
            ok = false
        }
    }

    // MARK: 3. The Save capsule's gradient clears the text floor

    private static func checkSaveGradientIsLegible(_ ok: inout Bool) {
        print("\n-- §6.10: white on the Save gradient, every stop --")
        let theme = daylight
        var rawFailures = 0
        for hue in HelmDomainHue.allCases {
            let pair = DaylightPalette.primaryButtonGradient(for: hue, theme: theme)
            let r1 = HelmContrast.ratio(.white, pair.h1)
            let r2 = HelmContrast.ratio(.white, pair.h2)
            let raw = hue.pair(in: theme)
            let rawH2 = HelmContrast.ratio(.white, raw.h2)
            if rawH2 < HelmContrast.textTarget { rawFailures += 1 }
            if r1 >= HelmContrast.textTarget && r2 >= HelmContrast.textTarget {
                print("  OK   \(hue): \(fmt(r1)) / \(fmt(r2)) (raw h2 was \(fmt(rawH2)))")
            } else {
                print("  FAIL \(hue): \(fmt(r1)) / \(fmt(r2)), floor \(fmt(HelmContrast.textTarget))")
                ok = false
            }
        }
        // Without this the whole check could pass because the raw pairs happened
        // to be fine, which would make the correction untested rather than
        // correct.
        if rawFailures > 0 {
            print("  OK   \(rawFailures) raw lighter stops genuinely fail the floor - the correction is doing work")
        } else {
            print("  FAIL no raw stop fails; this check proves nothing")
            ok = false
        }
    }

    // MARK: 4. The twelve pre-Daylight palettes are untouched

    private static func checkOtherPalettesUnchanged(_ ok: inout Bool) {
        print("\n-- the other twelve palettes render what they always did --")
        let form = HelmFormSheet(title: "Probe", domainHue: .rose)
        let recorder = CancelRecorder()
        _ = form.setFooter(target: recorder, confirmTitle: "Save",
                           confirm: #selector(CancelRecorder.confirmed),
                           cancel: #selector(CancelRecorder.cancelled))
        for theme in otherThemes {
            ThemeManager.shared.setTheme(theme)
            form.refreshTheme()
            let g = form.debugDaylightGeometry
            var problems: [String] = []
            if !g.ribbonHidden || g.ribbonHeight != 0 { problems.append("ribbon showing") }
            if !g.closeHidden { problems.append("close square showing") }
            if g.cancelVariant != .secondary { problems.append("Cancel is not .secondary") }
            // The load-bearing one: `domainHue` re-points a `.primary`'s fill in
            // *every* palette, so leaving it set here would restyle twelve
            // themes' Save buttons.
            if g.confirmHue != nil { problems.append("Save carries a domain hue") }
            if g.confirmGradient { problems.append("Save is a gradient") }
            // F2c: the keycaps are the same on every palette - they are a
            // *structure*, not a Daylight recipe - so what the twelve must not
            // pick up is the ribbon/close-square/gradient chrome above, and the
            // hint is simply expected to be there.
            if g.hintCapGlyphs.isEmpty { problems.append("hint lost its keycaps") }
            if problems.isEmpty { continue }
            print("  FAIL \(theme.id): \(problems.joined(separator: "; "))")
            ok = false
        }
        if ok { print("  OK   all \(otherThemes.count) unchanged") }
        ThemeManager.shared.setTheme(daylight)
    }

    // MARK: 5. §6.11's palette chrome and rows

    private static func makePalette() -> UnifiedSearchController {
        let index = UnifiedSearchIndex()
        index.register(UnifiedSearchActionProvider(actions: RailDestination.allCases.map { dest in
            .init(title: "Switch to \(dest.title)", meta: "Destination",
                  keywords: [dest.title], run: {})
        }))
        return UnifiedSearchController(index: index)
    }

    private static func checkPaletteChrome(_ ok: inout Bool) {
        print("\n-- §6.11: the ⌘K palette --")
        ThemeManager.shared.setTheme(daylight)
        let palette = makePalette()
        palette.debugApplyTheme(daylight)
        palette.debugReload(query: "s")
        palette.debugLayoutNow()

        let chrome = palette.debugPanelChrome
        if abs(chrome.width - UnifiedSearchController.panelWidth) < 0.51 {
            print("  OK   width \(fmt(chrome.width))")
        } else {
            print("  FAIL width \(fmt(chrome.width)), want \(fmt(UnifiedSearchController.panelWidth))")
            ok = false
        }
        if abs(chrome.radius - HelmMetrics.dSurface) < 0.01 && chrome.masks
            && !chrome.opaque && chrome.hasShadow {
            print("  OK   radius \(fmt(chrome.radius)) on a clipped, non-opaque, shadowed panel")
        } else {
            print("  FAIL radius=\(fmt(chrome.radius)) masks=\(chrome.masks) opaque=\(chrome.opaque) shadow=\(chrome.hasShadow)")
            ok = false
        }

        guard palette.debugRowCount > 0, let row = palette.debugDaylightRowGeometry(at: 0) else {
            print("  FAIL no rows to measure (query matched nothing)")
            ok = false
            return
        }
        var problems: [String] = []
        if !row.flatTileHidden { problems.append("flat tinted tile still visible") }
        if row.gradientTileHidden { problems.append("no gradient tile") }
        if abs(row.gradientTileSide - 28) > 0.01 { problems.append("tile \(fmt(row.gradientTileSide))pt, want 28") }
        if abs(row.backgroundRadius - HelmMetrics.dTileSmall) > 0.01 {
            problems.append("row radius \(fmt(row.backgroundRadius))")
        }
        // Row 0 is the selected one after a reload.
        if row.selectionEdgeHidden { problems.append("selected row has no left edge") }
        if abs(row.selectionEdgeWidth - 3) > 0.01 { problems.append("edge \(fmt(row.selectionEdgeWidth))pt, want 3") }
        if !sameColor(row.selectionEdgeColor, HelmTheme.nsColor(DaylightPalette.ink)) {
            problems.append("edge is not `ink`")
        }
        if !sameColor(row.backgroundFill, HelmTheme.nsColor(DaylightPalette.inset)) {
            problems.append("selected fill is not `inset`")
        }
        if row.hintFont?.isFixedPitch != true { problems.append("shortcut hint is not mono") }
        if problems.isEmpty {
            print("  OK   selected row: 28pt gradient tile, `inset` fill, 3pt `ink` edge, mono hint")
        } else {
            print("  FAIL row: \(problems.joined(separator: "; "))")
            ok = false
        }

        // A second, unselected row must not carry the edge.
        if palette.debugRowCount > 1, let second = palette.debugDaylightRowGeometry(at: 1) {
            if second.selectionEdgeHidden {
                print("  OK   an unselected row has no edge")
            } else {
                print("  FAIL every row is drawing the selection edge")
                ok = false
            }
        }

        // And on a pre-Daylight palette the flat tile is back and the panel is
        // square and opaque again.
        let other = otherThemes[0]
        ThemeManager.shared.setTheme(other)
        palette.debugApplyTheme(other)
        palette.debugRefreshRows(other)
        let fallback = palette.debugDaylightRowGeometry(at: 0)
        let fbChrome = palette.debugPanelChrome
        if fallback?.gradientTileHidden == true, fallback?.flatTileHidden == false,
           fbChrome.radius == 0, fbChrome.opaque, fallback?.selectionEdgeHidden == true {
            print("  OK   \(other.id) unchanged")
        } else {
            print("  FAIL \(other.id) picked up Daylight chrome")
            ok = false
        }
        ThemeManager.shared.setTheme(daylight)
    }

    // MARK: 6. The palette is a reskin only

    private static func checkPaletteStillDispatches(_ ok: inout Bool) {
        print("\n-- §6.11: still a reskin - query/arrow/Return still dispatch --")
        ThemeManager.shared.setTheme(daylight)
        var fired: [String] = []
        let index = UnifiedSearchIndex()
        index.register(UnifiedSearchActionProvider(
            actions: [RailDestination.console, .hosts, .vault].map { dest in
                .init(title: "Switch to \(dest.title)", meta: "Destination",
                      keywords: [dest.title], run: { fired.append("nav:\(dest)") })
            }))
        let palette = UnifiedSearchController(index: index)
        palette.debugReload(query: "")
        let firstTitles = palette.debugItemTitles
        guard firstTitles.count >= 2 else {
            print("  FAIL expected several rows for an empty query, got \(firstTitles.count)")
            ok = false
            return
        }
        palette.debugMoveSelection(by: 1)
        if palette.debugSelectedIndex != 1 {
            print("  FAIL arrow key did not move the selection")
            ok = false
        }
        palette.debugActivateSelection()
        if fired.count == 1 {
            print("  OK   \(firstTitles.count) rows, arrow moved, Return activated exactly one (\(fired[0]))")
        } else {
            print("  FAIL activations=\(fired.count), want 1")
            ok = false
        }
    }

    // MARK: 7. §6.12's ghost "Mark all read"

    private static func checkNotificationPanelGhostAction(_ ok: inout Bool) {
        print("\n-- §6.12: ghost \"Mark all read\", still wired --")
        ThemeManager.shared.setTheme(daylight)
        GrandLineNotificationCenter.shared.set(nil, id: "daylight-chrome-probe")
        NotificationSources.setToolUpdates(count: 3, navigate: {})
        let controller = NotificationCenterController()
        let panel = controller.debugPanelController
        _ = panel.view

        let buttons = descendants(HelmButton.self, in: panel.view)
        guard let markAll = buttons.first(where: { $0.title == "Mark all read" }) else {
            print("  FAIL no HelmButton titled \"Mark all read\" (found \(buttons.map(\.title)))")
            ok = false
            return
        }
        if markAll.variant == .quiet {
            print("  OK   it is a HelmButton(.quiet)")
        } else {
            print("  FAIL variant is \(markAll.variant), want .quiet")
            ok = false
        }
        // `fm/grandline-notification-center-redesign` gave this button its
        // ordinary meaning: the dots go out and every row stays. It used to
        // dismiss every informational entry, so this used to watch the badge
        // fall - watching the badge now would assert the opposite of the
        // intended behaviour. The store's bulk dismiss still exists under its
        // own name and `GrandLineNotificationCenterSelfTest` still covers it.
        let center = GrandLineNotificationCenter.shared
        let before = center.unreadCount
        let rowsBefore = center.badgeCount
        markAll.performClick(nil)
        if before > 0 && center.unreadCount == 0 && center.badgeCount == rowsBefore {
            print("  OK   clicking it clears \(before) unread and keeps all \(rowsBefore) rows")
        } else {
            print("  FAIL unread \(before) -> \(center.unreadCount), rows \(rowsBefore) -> \(center.badgeCount)")
            ok = false
        }
        NotificationSources.setToolUpdates(count: 0, navigate: {})
    }

    private static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += descendants(type, in: sub) }
        return found
    }

    // MARK: 8. §6.14's toast

    /// The pill `Toast.show` just added: the container's newest layer-backed
    /// subview carrying the message. Found rather than handed over, so the test
    /// exercises the real presentation path.
    private static func toastPill(in container: NSView, message: String) -> NSView? {
        container.subviews.reversed().first { candidate in
            descendants(NSTextField.self, in: candidate).contains { $0.stringValue == message }
        }
    }

    private static func checkToastRecipe(_ ok: inout Bool) {
        print("\n-- §6.14 + G1 + TO-1: the toast --")
        // TO-1 inverted most of G1's recipe, as G1 inverted §6.14's, and on
        // purpose: the capsule is the hero gradient with white words now, not
        // the card surface with the theme's ink. What survives unchanged is
        // where it lands, how it stacks, and that Undo still restores.
        let savedMotion = HelmMotion.reducedOverrideForTests
        HelmMotion.reducedOverrideForTests = false
        defer { HelmMotion.reducedOverrideForTests = savedMotion }
        guard let lavender = HelmTheme.appTheme(id: "lavender"),
              let powder = HelmTheme.appTheme(id: "powder") else {
            print("  FAIL Lavender or Powder is missing - the checks below would be vacuous")
            ok = false
            return
        }
        for theme in [lavender, powder] {
            checkToastCapsule(theme, &ok)
        }
        checkToastStackAndUndo(lavender, &ok)
        ThemeManager.shared.setTheme(daylight)
    }

    /// One theme: the gradient, the words, the capsule, the shadow, where it
    /// lands, and the three kinds' glyphs.
    private static func checkToastCapsule(_ theme: HelmTheme, _ ok: inout Bool) {
        ThemeManager.shared.setTheme(theme)
        // The quiet-ink rule from the kit's own primitives, not through
        // `ToastPill.palette`, so a toast that drifts off the hero rule fails.
        let accent = HelmContrast.components(HelmTheme.nsColor(theme.heroAccentHex))
        let palette = HelmHeroSurface.palette(accent: accent, quietInk: Double(HelmHeroColumn.quietInkAlpha))
        let ink = HelmContrast.color(palette.ink)
        let card = HelmTheme.nsColor(theme.chromeBackgroundHex)
        // Discriminating power first: the gradient must not be the card the
        // capsule used to be, or the gradient check could not tell them apart.
        guard !sameColor(HelmContrast.color(palette.start), card) else {
            print("  FAIL \(theme.id): the hero's start stop is the card surface - the check would be vacuous")
            ok = false
            return
        }
        let kinds: [(Feedback.Kind, String)] = [(.done, "Saved"), (.warning, "Startup command held back"),
                                                (.failure, "Docs sync failed")]
        var glyphColors: [NSColor] = []
        for (kind, message) in kinds {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            Toast.show(in: container, message: message, kind: kind)
            container.layoutSubtreeIfNeeded()
            guard let pill = Toast.debugPills(in: container).first(where: { $0.message == message }) else {
                print("  FAIL \(theme.id): no toast pill for \"\(message)\"")
                ok = false
                continue
            }
            var problems: [String] = []
            let stops = pill.debugSurface.debugGradientColors.compactMap { NSColor(cgColor: $0) }
            if stops.count != 2 || !sameColor(stops[0], HelmContrast.color(palette.start))
                || !sameColor(stops[1], HelmContrast.color(palette.end)) {
                problems.append("the capsule does not paint the hero's quiet-ink gradient")
            }
            if abs(pill.bounds.height - Toast.pillHeight) > 0.51 {
                problems.append("height \(fmt(pill.bounds.height)), want \(fmt(Toast.pillHeight))")
            }
            // The capsule glow, centred on the top-right corner and no taller
            // than the pill: the card's 220pt glow washed the pill's right half.
            let glow = pill.debugSurface.debugGlowFrame
            if pill.debugSurface.glowShape != .capsule || abs(glow.midX - pill.bounds.maxX) > 0.51
                || abs(glow.midY - pill.bounds.maxY) > 0.51 || glow.height > pill.bounds.height * 1.2 {
                problems.append("the glow is not the capsule's (\(glow))")
            }
            let radius = pill.debugSurface.layer?.cornerRadius ?? 0
            if abs(radius - pill.bounds.height / 2) > 0.51 || pill.debugSurface.layer?.masksToBounds != true {
                problems.append("the gradient is not clipped to a capsule (radius \(fmt(radius)))")
            }
            let raised = HelmCard.elevation(for: theme, level: .raised)
            if abs((pill.layer?.shadowRadius ?? 0) - raised.shadowBlurRadius / 2) > 0.01
                || (pill.layer?.shadowOpacity ?? 0) == 0 {
                problems.append("no raised shadow")
            }
            let label = pill.debugLabel
            if label.stringValue != message { problems.append("the label reads \"\(label.stringValue)\"") }
            if !sameColor(label.textColor, ink) { problems.append("the words are not the hero's ink") }
            let font = label.font
            if font?.pointSize != HelmType.scaled(ToastPill.messageSize)
                || font?.fontName != NSFont.systemFont(ofSize: HelmType.scaled(ToastPill.messageSize), weight: .semibold).fontName {
                problems.append("label font \(font.map { "\($0.fontName) \(fmt($0.pointSize))" } ?? "nil"), want 12 semibold")
            }
            // The words on the lighter stop - the worse of the two.
            let wordsRatio = HelmContrast.ratio(palette.ink, palette.lighterStop)
            if wordsRatio < HelmContrast.textTarget {
                problems.append("the words measure \(String(format: "%.2f", wordsRatio)):1 on the lighter stop")
            }
            // The kind's glyph: its own symbol, in its own lifted hue, on a
            // glass circle, clearing the non-text floor on both stops.
            if pill.glyphSymbol != ToastHeroWords.symbol(for: kind) || pill.debugGlyph.image == nil {
                problems.append("the glyph is \(pill.glyphSymbol), want \(ToastHeroWords.symbol(for: kind))")
            }
            let want = HelmHeroSurface.signalColor(tintHex: kind.tint.hex(in: theme), on: palette)
            guard let painted = pill.debugGlyph.contentTintColor else {
                problems.append("the glyph has no colour")
                report(problems, theme: theme, kind: kind, &ok)
                continue
            }
            if !sameColor(painted, want) { problems.append("the glyph is not the kind's signal colour") }
            glyphColors.append(painted)
            let darker = HelmContrast.relativeLuminance(palette.start) < HelmContrast.relativeLuminance(palette.end)
                ? palette.start : palette.end
            let glyphRGB = HelmContrast.components(painted)
            let glyphRatio = min(HelmContrast.ratio(glyphRGB, palette.lighterStop), HelmContrast.ratio(glyphRGB, darker))
            if glyphRatio < HelmContrast.nonTextTarget {
                problems.append("the glyph measures \(String(format: "%.2f", glyphRatio)):1 on a stop")
            }
            let tile = pill.debugGlyphTile
            if abs(tile.frame.width - ToastPill.glyphSide) > 0.51 || abs((tile.layer?.cornerRadius ?? 0) - ToastPill.glyphSide / 2) > 0.01
                || (tile.layer?.borderWidth ?? 0) == 0 {
                problems.append("the glyph's glass circle is \(fmt(tile.frame.width))pt with no ring")
            }
            // G1's headline, unchanged: bottom-centre.
            let fromBottom = pill.frame.minY - container.bounds.minY
            if abs(fromBottom - Toast.bottomInset) > 0.51 || abs(pill.frame.midX - container.bounds.midX) > 0.51 {
                problems.append("the pill is not \(fmt(Toast.bottomInset))pt off the bottom centre")
            }
            if pill.debugDrainShape != nil { problems.append("a plain toast drew Undo's drain") }
            report(problems, theme: theme, kind: kind, &ok)
        }
        // The three kinds must look different, or the glyph says nothing.
        if glyphColors.count == 3 {
            let distinct = (0..<3).allSatisfy { i in ((i + 1)..<3).allSatisfy { !sameColor(glyphColors[i], glyphColors[$0]) } }
            if !distinct {
                print("  FAIL \(theme.id): two kinds share a glyph colour")
                ok = false
            }
        }
    }

    private static func report(_ problems: [String], theme: HelmTheme, kind: Feedback.Kind, _ ok: inout Bool) {
        if problems.isEmpty {
            print("  OK   \(theme.id) \(kind): hero capsule, white words, \(ToastHeroWords.symbol(for: kind)) in its signal colour")
        } else {
            print("  FAIL \(theme.id) \(kind): \(problems.joined(separator: "; "))")
            ok = false
        }
    }

    /// Stacking, the Undo ghost pill and its drain, and Reduce Motion.
    private static func checkToastStackAndUndo(_ theme: HelmTheme, _ ok: inout Bool) {
        ThemeManager.shared.setTheme(theme)
        // G1: "stackable". Two plain confirmations must both be on screen, and
        // the newer one must be the lower of the two - the stack grows upward,
        // away from the content.
        let stackContainer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        Toast.show(in: stackContainer, message: "First")
        Toast.show(in: stackContainer, message: "Second")
        stackContainer.layoutSubtreeIfNeeded()
        let first = toastPill(in: stackContainer, message: "First")
        let second = toastPill(in: stackContainer, message: "Second")
        if let first, let second {
            if second.frame.minY >= first.frame.minY {
                print("  FAIL the newer toast is not below the older one")
                ok = false
            } else if first.frame.minY < second.frame.maxY {
                print("  FAIL the two toasts overlap")
                ok = false
            } else {
                print("  OK   two toasts stack, newest lowest, no overlap")
            }
        } else {
            print("  FAIL toasts do not stack - \(first == nil ? "the first" : "the second") is gone")
            ok = false
        }

        // TO-1: Undo is a ghost pill in the hero's ink, ringed by a hairline
        // that drains over exactly the six seconds the offer stands.
        var undone = 0
        let undoContainer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        Toast.showUndo(in: undoContainer, message: "Deleted host") { undone += 1 }
        undoContainer.layoutSubtreeIfNeeded()
        guard let undoPill = Toast.debugPills(in: undoContainer).first(where: { $0.message == "Deleted host" }),
              let undoButton = undoPill.undoButton else {
            print("  FAIL no Undo button in the undo pill")
            ok = false
            return
        }
        var problems: [String] = []
        let ink = HelmContrast.color(undoPill.palette.ink)
        if undoButton.heroInk.map({ !sameColor($0, ink) }) ?? true {
            problems.append("Undo is not a ghost pill in the hero's ink")
        }
        if let ring = undoPill.debugDrainView {
            let want = undoButton.frame.insetBy(dx: -ToastPill.drainOutset, dy: -ToastPill.drainOutset)
            let got = ring.convert(ring.bounds, to: undoButton.superview)
            if abs(got.minX - want.minX) > 0.51 || abs(got.width - want.width) > 0.51 || abs(got.height - want.height) > 0.51 {
                problems.append("the drain's ring is not \(fmt(ToastPill.drainOutset))pt around Undo")
            }
            let drain = undoPill.debugDrainShape?.animation(forKey: ToastPill.drainKey) as? CABasicAnimation
            if drain?.keyPath != "strokeEnd" || drain?.duration != Toast.undoDuration {
                problems.append("the ring is not draining over \(Toast.undoDuration)s")
            }
            if ring.hitTest(NSPoint(x: ring.bounds.midX, y: ring.bounds.midY)) != nil {
                problems.append("the drain's ring takes clicks meant for Undo")
            }
        } else {
            problems.append("Undo has no draining ring")
        }
        undoButton.performClick(nil)
        if undone != 1 { problems.append("undo fired \(undone) times, want 1") }

        // Reduce Motion: no drain at all.
        HelmMotion.reducedOverrideForTests = true
        let stillContainer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        Toast.showUndo(in: stillContainer, message: "Deleted key") {}
        if let still = Toast.debugPills(in: stillContainer).first, still.debugDrainShape != nil || still.debugDrainView != nil {
            problems.append("Reduce Motion still drew the draining ring")
        }
        HelmMotion.reducedOverrideForTests = false
        if problems.isEmpty {
            print("  OK   Undo is a hero ghost pill, its ring drains over \(Toast.undoDuration)s, none under Reduce Motion, it restores once")
        } else {
            print("  FAIL \(problems.joined(separator: "; "))")
            ok = false
        }
    }


    // MARK: 9. §6.14's empty state (Phase 4's, pinned)

    private static func checkEmptyStatePlate(_ ok: inout Bool) {
        print("\n-- §6.14: the empty state's gradient plate --")
        ThemeManager.shared.setTheme(daylight)
        let state = HelmEmptyState(symbol: "checkmark.circle", title: "All clear",
                                   body: "Nothing needs you right now.", size: .standard)
        state.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        state.applyTheme(daylight)
        state.layoutSubtreeIfNeeded()
        let tiles = descendants(HelmGradientTile.self, in: state).filter { !$0.isHidden }
        // A `HelmGradientTile` owns an `NSImageView` of its own for the glyph,
        // so "the plain glyph" means an image view that is *not* inside a tile.
        let plainGlyphs = descendants(NSImageView.self, in: state).filter { view in
            !view.isHidden && !tiles.contains(where: { view.isDescendant(of: $0) })
        }
        let g = state.debugGeometry()
        if tiles.count == 1, plainGlyphs.isEmpty, g.glyphFrame.width > 0 {
            print("  OK   one gradient plate, no plain glyph")
        } else {
            print("  FAIL tiles=\(tiles.count) plainGlyphs=\(plainGlyphs.count)")
            ok = false
        }
    }

    // MARK: 10. §6.10's attachment well

    private static func checkAttachmentWell(_ ok: inout Bool) {
        print("\n-- §6.10: the attachment well --")
        ThemeManager.shared.setTheme(daylight)
        let well = ShiftImageAttachmentWell(frame: NSRect(x: 0, y: 0, width: 400, height: 96))
        well.applyTheme(daylight)
        well.layoutSubtreeIfNeeded()
        let g = well.debugDaylightGeometry
        var problems: [String] = []
        if g.dashHidden { problems.append("border is not dashed") }
        if g.dashPattern.isEmpty { problems.append("no dash pattern") }
        if (g.solidBorderWidth) != 0 { problems.append("solid border still painted") }
        if abs(g.cornerRadius - HelmMetrics.dWell) > 0.01 {
            problems.append("radius \(fmt(g.cornerRadius)), want \(fmt(HelmMetrics.dWell))")
        }
        if !sameColor(g.dashStroke, HelmTheme.nsColor(daylight.chromeLineHex).withAlphaComponent(0.9)) {
            // Alpha is folded into the stroke colour, so compare the RGB only.
            if !sameColor(g.dashStroke, HelmTheme.nsColor(daylight.chromeLineHex)) {
                problems.append("dash stroke is not `hair`")
            }
        }
        if !sameColor(g.linkColor, HelmTheme.nsColor(daylight.accentHex)) {
            problems.append("\"choose a file\" is not the link hue")
        }
        if problems.isEmpty {
            print("  OK   dashed `hair` on radius \(fmt(g.cornerRadius)) with a link-coloured action word")
        } else {
            print("  FAIL \(problems.joined(separator: "; "))")
            ok = false
        }

        let other = otherThemes[0]
        ThemeManager.shared.setTheme(other)
        well.applyTheme(other)
        let fb = well.debugDaylightGeometry
        if fb.dashHidden, fb.solidBorderWidth == 1, abs(fb.cornerRadius - 8) < 0.01 {
            print("  OK   \(other.id) keeps the solid radius-8 border")
        } else {
            print("  FAIL \(other.id) picked up the dashed border")
            ok = false
        }
        ThemeManager.shared.setTheme(daylight)
    }
}

#endif
