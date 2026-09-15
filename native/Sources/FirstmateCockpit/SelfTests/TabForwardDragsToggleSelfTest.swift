// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for the tab-lifecycle half of the "Forward Drags to
// This Tab's Program" toggle (`fm/grandline-terminal-selection-sidebar-bleed`)
// - the `ConsoleController`/`TabChipView` wiring around
// `CockpitTerminalView.forwardDragsToChild`, not the mouse-routing formula
// itself. That half is `TerminalSelectionRenderSelfTest.swift`'s case 7,
// proven from real pixels and real captured bytes; this file drives the
// *real* `ConsoleController.newShellTab`/`duplicateTab`/
// `toggleForwardDragsToChild` - not reimplementations - following
// `ConsoleClaudeUsageSelfTest.swift`'s construction pattern (a real
// `ConsoleController` mounted in a real, off-screen `NSWindow`).
//
// Only `.shell` launches are used here, on purpose - see
// `CockpitTerminalView.forwardDragsToChild`'s own doc comment and
// `data/grandline-terminal-selection-sidebar-bleed/report.md` for why the
// toggle is `.shell`-only, and `TerminalSelectionRenderSelfTest`'s case 5 for
// the source guard proving `.ssh` never wires it. Driving a real `.ssh`
// launch through a real, appeared `ConsoleController` would attempt a real
// `ssh` subprocess - genuinely unsafe in a headless suite - so that half is
// deliberately left to the source guard rather than a second, riskier
// behavioural harness here.
//
// `fm/grandline-herdr-selection-theme-fix` added the last case
// (`chipIndicatorTracksTheToggleImmediately`): a real live reproduction
// against the actual herdr binary attached to a real herdr session confirmed
// the mouse-routing mechanism itself was already correct (a default `.shell`
// tab's plain drag builds a real, theme-coloured local selection with zero
// bytes forwarded to herdr; a tab with `forwardDragsToChild` toggled on
// forwards the drag to herdr instead, which then paints its own, unrelated
// colours - the toggle's documented, intended effect). The one genuine gap
// that investigation found was visibility: nothing on the tab itself showed
// that state, only a right-click menu's checkmark - so a captain looking at
// two tabs with different selection colours (one toggled directly, or one
// carrying the state forward from `duplicateTab`) had no on-screen way to
// tell why. `TabChipView`'s small indicator (and this case) close that gap.
//
// Run with:
//   swift build && FM_RUN_TAB_FORWARD_DRAGS_TOGGLE_TESTS=1 .build/debug/FirstmateCockpit; echo $?

// GL-27: compiled into debug builds only - see ConsoleClaudeUsageSelfTest.swift's
// header for the full reasoning. Do not remove this guard: `Phase3PolishSelfTest`
// asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum TabForwardDragsToggleSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("freshShellTabStartsWithTheToggleOff", test_freshTabStartsOff),
            ("toggleFlipsAndTheChipClosureReflectsIt", test_toggleFlipsAndClosureReflectsIt),
            ("toggleActionClosureActuallyToggles", test_onToggleForwardDragsClosureToggles),
            ("duplicateCarriesAnAlreadyToggledStateForward", test_duplicatePropagatesToggle),
            ("aFreshTabNeverInheritsAnUnrelatedTabsToggle", test_freshTabDoesNotInheritSiblingState),
            ("chipIndicatorTracksTheToggleImmediately", test_chipIndicatorTracksToggle),
            ("indicatorLabelsAndGlyphsAreTheCaptainApprovedPair", test_indicatorLabelsAndGlyphs),
            ("toolbarButtonShowsTheIndicatorsOwnLabelAndGlyph", test_toolbarButtonReflectsIndicator),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
            ? "TabForwardDragsToggleSelfTest: all \(cases.count) cases passed"
            : "TabForwardDragsToggleSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Helpers

    /// Mirrors `ConsoleClaudeUsageSelfTest.makeTestConsole` - a real
    /// `ConsoleController` mounted in a real, off-screen `NSWindow`.
    private static func makeTestConsole() -> (window: NSWindow, controller: ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(), snippetStore: SnippetStore(), isFirstmateConsole: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    // MARK: Cases

    private static func test_freshTabStartsOff() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let tab = controller.currentTab else { return "no current tab after newShellTab()" }
        guard tab.terminal.forwardDragsToChild == false else {
            return "a fresh .shell tab's forwardDragsToChild was already true"
        }
        guard let chip = tab.chip, let enabled = chip.forwardDragsEnabled else {
            return "the .shell tab's chip never wired forwardDragsEnabled"
        }
        guard enabled() == false else {
            return "the chip's forwardDragsEnabled() closure reported true for a fresh tab"
        }
        guard chip.onToggleForwardDrags != nil else {
            return "the .shell tab's chip never wired onToggleForwardDrags"
        }
        _ = window
        return nil
    }

    private static func test_toggleFlipsAndClosureReflectsIt() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let tab = controller.currentTab else { return "no current tab after newShellTab()" }
        guard let enabled = tab.chip.forwardDragsEnabled else { return "forwardDragsEnabled never wired" }

        controller.toggleForwardDragsToChild(id: tab.id)
        guard tab.terminal.forwardDragsToChild == true else {
            return "toggleForwardDragsToChild(id:) did not flip forwardDragsToChild to true"
        }
        guard enabled() == true else {
            return "the chip's forwardDragsEnabled() closure still reads false after toggling on - the menu checkmark would be stale"
        }

        controller.toggleForwardDragsToChild(id: tab.id)
        guard tab.terminal.forwardDragsToChild == false else {
            return "a second toggleForwardDragsToChild(id:) call did not flip it back off"
        }
        guard enabled() == false else {
            return "the chip's forwardDragsEnabled() closure still reads true after toggling back off"
        }
        _ = window
        return nil
    }

    /// The right-click menu item's actual `@objc` action goes through
    /// `chip.onToggleForwardDrags`, not `toggleForwardDragsToChild(id:)`
    /// directly - proving the closure itself (what `TabChipView.rightMouseDown`
    /// actually wires to the menu item) performs the real toggle, not just
    /// that the controller method works when called by id.
    private static func test_onToggleForwardDragsClosureToggles() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let tab = controller.currentTab else { return "no current tab after newShellTab()" }
        guard let onToggle = tab.chip.onToggleForwardDrags else { return "onToggleForwardDrags never wired" }

        onToggle()
        guard tab.terminal.forwardDragsToChild == true else {
            return "calling the chip's onToggleForwardDrags closure did not flip forwardDragsToChild"
        }
        _ = window
        return nil
    }

    private static func test_duplicatePropagatesToggle() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let src = controller.currentTab else { return "no current tab after newShellTab()" }
        controller.toggleForwardDragsToChild(id: src.id)
        guard src.terminal.forwardDragsToChild == true else { return "setup: toggle did not take" }

        controller.duplicateTab(id: src.id)
        guard let dup = controller.currentTab, dup.id != src.id else {
            return "duplicateTab did not select a new, distinct tab"
        }
        guard dup.terminal.forwardDragsToChild == true else {
            return "a duplicate of an already-toggled tab did not carry forwardDragsToChild forward - it started false"
        }
        guard let dupEnabled = dup.chip.forwardDragsEnabled, dupEnabled() == true else {
            return "the duplicate's own chip closure does not reflect the carried-forward toggle"
        }
        _ = window
        return nil
    }

    /// The inverse of the case above: a *fresh* tab (⌘T, not a duplicate) must
    /// never pick up a sibling tab's own toggle state - each `.shell` tab's
    /// choice is independent unless the captain explicitly duplicates it.
    private static func test_freshTabDoesNotInheritSiblingState() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let first = controller.currentTab else { return "no current tab after first newShellTab()" }
        controller.toggleForwardDragsToChild(id: first.id)
        guard first.terminal.forwardDragsToChild == true else { return "setup: toggle did not take" }

        controller.newShellTab()
        guard let second = controller.currentTab, second.id != first.id else {
            return "the second newShellTab() did not open a new, distinct tab"
        }
        guard second.terminal.forwardDragsToChild == false else {
            return "a brand-new .shell tab inherited an unrelated tab's forwardDragsToChild state - each tab's toggle must start independent"
        }
        _ = window
        return nil
    }

    /// `fm/grandline-herdr-selection-theme-fix`: the tab chip's own visible
    /// "drags forwarded to this tab's program" indicator - the fix for the
    /// only real gap the live-herdr investigation found. The routing
    /// mechanism itself (`prefersLocalSelection`/`forwardDragsToChild`) was
    /// verified correct against a real, live herdr session (see that task's
    /// PR); the reported symptom - a `.shell` tab painting herdr's own dark
    /// selection colour instead of the theme's - only happens when this
    /// per-tab toggle is on, which is its documented, intended effect, not a
    /// bug. Before this, that state was visible nowhere but a right-click
    /// menu's checkmark, so a captain looking at two differently-behaving
    /// tabs (one toggled, one not - whether toggled directly or carried
    /// forward by a duplicate) had no way to tell why without hunting for it.
    private static func test_chipIndicatorTracksToggle() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let tab = controller.currentTab else { return "no current tab after newShellTab()" }

        guard !tab.chip.debugForwardDragsIndicatorVisible else {
            return "a fresh .shell tab's chip already shows the forward-drags indicator"
        }

        controller.toggleForwardDragsToChild(id: tab.id)
        guard tab.chip.debugForwardDragsIndicatorVisible else {
            return "toggling forwardDragsToChild on did not make the chip's indicator visible immediately - " +
                "it should not need a separate styleChips() pass to show"
        }

        controller.toggleForwardDragsToChild(id: tab.id)
        guard !tab.chip.debugForwardDragsIndicatorVisible else {
            return "toggling forwardDragsToChild back off left the chip's indicator visible"
        }

        // A second, untouched tab must never show the first tab's state -
        // the same independence `test_freshTabDoesNotInheritSiblingState`
        // proves for the underlying property, proven here for its visible
        // indicator too.
        controller.toggleForwardDragsToChild(id: tab.id)
        controller.newShellTab()
        guard let second = controller.currentTab, second.id != tab.id else {
            return "the second newShellTab() did not open a new, distinct tab"
        }
        guard !second.chip.debugForwardDragsIndicatorVisible else {
            return "a brand-new tab's chip showed the indicator for an unrelated tab's toggled state"
        }
        guard tab.chip.debugForwardDragsIndicatorVisible else {
            return "opening a second tab cleared the first tab's own already-visible indicator"
        }

        _ = window
        return nil
    }

    /// `fm/grandline-drag-selection-label-icon`: the `.local` state shipped
    /// as "Local Selection" with `character.cursor.ibeam`, and the captain
    /// read that glyph as the word **"AI"** - it draws a literal capital A
    /// beside an I-beam, which at this button's 11pt, immediately before a
    /// text label, parses as two letters rather than as a cursor.
    ///
    /// **The pixel comparison below is the point of this case, not
    /// belt-and-braces.** The obvious fix is to swap the symbol for a
    /// better-*named* one, and that is exactly the trap: `text.cursor`
    /// sounds like a bare I-beam and draws the **identical** A-plus-I-beam
    /// glyph, so a name-based assertion (`!= "character.cursor.ibeam"`)
    /// passes while the captain's own complaint is reshipped verbatim.
    /// Rendering both at the real configuration and requiring they differ
    /// catches any such alias or lookalike without having to know its name
    /// in advance - which is the only form of this check that can outlive
    /// the two names that happen to be known today.
    ///
    /// It also asserts both glyphs genuinely resolve:
    /// `NSImage(systemSymbolName:)` returns nil silently, and this app has
    /// shipped an invisible icon that way before (see `AGENTS.md`).
    private static func test_indicatorLabelsAndGlyphs() -> String? {
        guard DragForwardingIndicator.local.buttonTitle == "App Selection" else {
            return "the default state's label should be \"App Selection\" (the captain-approved pairing " +
                "with \"Forwarding Drags\"), got \"\(DragForwardingIndicator.local.buttonTitle)\""
        }
        guard DragForwardingIndicator.forwarding.buttonTitle == "Forwarding Drags" else {
            return "the forwarding state's label changed unexpectedly - it is the half the captain kept, " +
                "got \"\(DragForwardingIndicator.forwarding.buttonTitle)\""
        }

        // The real configuration this glyph is drawn at (`HelmButton`'s
        // `.small` size, see `rebuildImage()`), so the comparison is of what
        // the captain actually sees, not of some other optical size.
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        func render(_ name: String) -> Data? {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return nil }
            // Draw onto a TRANSPARENT canvas and compare the result. A
            // template symbol draws in black, so filling the canvas first
            // would render black-on-black and make every glyph compare
            // equal - i.e. the check would fail for every symbol rather
            // than only for a lookalike (caught the first time this ran).
            let size = NSSize(width: 24, height: 24)
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            let origin = NSPoint(x: ((size.width - image.size.width) / 2).rounded(),
                                 y: ((size.height - image.size.height) / 2).rounded())
            image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            canvas.unlockFocus()
            guard let tiff = canvas.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }

        for state in [DragForwardingIndicator.local, .forwarding] {
            guard NSImage(systemSymbolName: state.buttonSymbol, accessibilityDescription: nil) != nil else {
                return "\(state)'s symbol \"\(state.buttonSymbol)\" does not resolve on this OS - " +
                    "NSImage(systemSymbolName:) fails silently, so this ships an invisible icon"
            }
        }

        guard let chosen = render(DragForwardingIndicator.local.buttonSymbol) else {
            return "could not render the default state's glyph (\(DragForwardingIndicator.local.buttonSymbol))"
        }
        guard let letterform = render("character.cursor.ibeam") else {
            // Only the comparison is lost if this reference symbol is ever
            // withdrawn - say so rather than passing silently.
            return "could not render the reference letterform glyph character.cursor.ibeam"
        }
        guard chosen != letterform else {
            return "the default state's glyph (\"\(DragForwardingIndicator.local.buttonSymbol)\") renders " +
                "pixel-identically to character.cursor.ibeam, which the captain read as the word \"AI\" - " +
                "a symbol whose NAME differs is not enough, its GLYPH has to differ too (text.cursor is " +
                "the known lookalike that passes a name check and fails this one)"
        }
        return nil
    }

    /// The mapping above is only worth anything if the real toolbar button
    /// actually shows it, in both states - a correct enum beside a button
    /// that never reads it renders exactly like the bug. Drives the real
    /// `toggleDragForwarding()` action rather than setting the model
    /// directly, so an unwired button fails here too.
    private static func test_toolbarButtonReflectsIndicator() -> String? {
        let (window, controller) = makeTestConsole()
        controller.newShellTab()
        guard let tab = controller.currentTab else { return "no current tab after newShellTab()" }
        guard let button = controller.dragForwardingButton else {
            return "the console has no drag-routing toolbar button"
        }
        guard !button.isHidden else {
            return "the drag-routing button is hidden for a real .shell tab, which is the one kind it is for"
        }

        func expect(_ state: DragForwardingIndicator, _ label: String) -> String? {
            guard button.title == state.buttonTitle else {
                return "\(label): button title \"\(button.title)\", expected \"\(state.buttonTitle)\""
            }
            guard button.symbolName == state.buttonSymbol else {
                return "\(label): button symbol \(button.symbolName ?? "nil"), expected \(state.buttonSymbol)"
            }
            // A resolved name still has to have produced a real image.
            guard button.image != nil else {
                return "\(label): the button's glyph (\(state.buttonSymbol)) resolved to no image at all"
            }
            return nil
        }

        if let failure = expect(.local, "a fresh .shell tab") { _ = window; return failure }
        controller.toggleDragForwarding()
        guard tab.terminal.forwardDragsToChild else {
            _ = window
            return "the toolbar button's own action did not flip forwardDragsToChild"
        }
        if let failure = expect(.forwarding, "after the toolbar toggle") { _ = window; return failure }
        controller.toggleDragForwarding()
        if let failure = expect(.local, "after toggling back") { _ = window; return failure }

        _ = window
        return nil
    }
}

#endif
