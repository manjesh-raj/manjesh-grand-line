// Grand Line - native macOS app.
//
// F12's correctness surface: the trigger grammar, the lookup, the
// placeholders, the scope/exclusion policy, and the whole keystroke -> what
// would be injected path driven end to end through the real `SnippetExpander`.
//
// **Why this is not window-backed** (AGENTS.md's classification rule): every
// check here is a value check on a string, a `SnippetTypedTrigger`, a
// `SnippetInjection` or a decoded `Snippet`. Nothing builds a view, mounts a
// window or reads rendered geometry, so this runs in CI's *blocking* lane.
// `SnippetExpander` imports AppKit and that is deliberately not the test -
// nothing here installs a monitor or asks the window server for anything; the
// expander is driven through `debugType` and reports through
// `injectionSinkForTests`. The page's own render lives in
// `SnippetExpanderViewSelfTest`, which is in `NEEDS_SESSION`.
//
// **What this suite cannot prove**, stated rather than implied: that the
// synthetic backspaces and the synthetic ⌘V actually land in another
// application. That needs a real Accessibility grant and a real frontmost app.
// This suite asserts the *decision* and the exact `SnippetInjection` that
// decision produces, which is every inch of the path up to `CGEvent.post`.
//
// Run with `FM_RUN_SNIPPET_EXPANSION_TESTS=1 .build/debug/GrandLine`.

#if FM_SELFTESTS

import AppKit

enum SnippetExpansionSelfTest {

    /// A fixed instant, so `{{date}}`/`{{time}}` assert literals rather than
    /// re-deriving an expected value from the function under test.
    private static let t0 = Date(timeIntervalSince1970: 1_758_412_800)
    private static let utc = TimeZone(identifier: "UTC")!

    static func run() -> Bool {
        var ok = true

        checkTriggerGrammar(&ok)
        checkWordBoundaries(&ok)
        checkBufferHousekeeping(&ok)
        checkTable(&ok)
        checkPlaceholders(&ok)
        checkPolicy(&ok)
        checkLegacyDecode(&ok)
        checkKeyEventClassification(&ok)
        checkClipboardRefusesVaultMaterial(&ok)
        checkEndToEndExpansion(&ok)
        checkTheTrustReassertIsWired(&ok)

        if ok { print("[SnippetExpansionSelfTest] all checks passed") }
        return ok
    }

    // MARK: B20 - the monitor is re-armed after a mid-session grant

    /// A source guard, because the behaviour needs a real Accessibility grant
    /// arriving mid-process and this shell has none (AGENTS.md's "Verifying
    /// native UI bugs").
    ///
    /// AGENTS.md gotcha (21): macOS arms a global `NSEvent` monitor from the
    /// trust the process held **when the monitor was registered**, and never
    /// retroactively. The launch that first prompts for Accessibility installs
    /// the expander's monitors before the captain grants it, so the feature
    /// stayed silently dead until the next relaunch while its own card said
    /// "Granted - N triggers armed" (B20).
    private static func checkTheTrustReassertIsWired(_ ok: inout Bool) {
        guard let root = SelfTestSources.appSourceDirectory() else {
            check(false, "app sources are not next to this binary - "
                  + "this guard would pass vacuously", &ok)
            return
        }
        func text(_ name: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        guard let expander = text("SnippetExpander.swift"), let main = text("main.swift") else {
            check(false, "could not read SnippetExpander.swift / main.swift", &ok)
            return
        }
        // Discriminating power: these really are the files that install and
        // drive the monitors.
        check(expander.contains("addGlobalMonitorForEvents"),
              "SnippetExpander.swift should be the file that installs the global monitor", &ok)
        check(expander.contains("installedWhileTrusted = isAccessibilityTrusted"),
              "the expander must record the trust it had at install time, "
              + "or nothing can notice a later grant (B20)", &ok)
        check(expander.contains("func reassertIfTrustChanged()"),
              "and must offer the same re-arm ShiftGlobalHotkey does", &ok)
        check(main.contains("snippetExpander.reassertIfTrustChanged()"),
              "and main.swift must drive it from didBecomeActiveNotification - "
              + "an unreachable re-arm is the same bug with more code (B20)", &ok)
        check(main.range(of: "didBecomeActiveNotification") != nil,
              "on app activation, which is the first moment a grant can be noticed", &ok)
    }

    // MARK: The grammar

    private static func checkTriggerGrammar(_ ok: inout Bool) {
        check(SnippetTrigger.normalize(";sig") == "sig", "a typed ;sig stores as sig", &ok)
        check(SnippetTrigger.normalize("  ;;sig  ") == "sig", "leading semicolons and spaces go", &ok)
        check(SnippetTrigger.display("sig") == ";sig", "and reads back with its prefix", &ok)

        check(SnippetTrigger.rejection(for: "sig") == nil, "sig is a legal trigger", &ok)
        check(SnippetTrigger.rejection(for: "k8s-prod") == nil, "digits and - are legal", &ok)
        check(SnippetTrigger.rejection(for: "") != nil, "an empty trigger is rejected", &ok)
        check(SnippetTrigger.rejection(for: "my sig") != nil, "a space is rejected", &ok)
        check(SnippetTrigger.rejection(for: "si;g") != nil, "an inner semicolon is rejected", &ok)
        check(SnippetTrigger.rejection(for: String(repeating: "a", count: 25)) != nil,
              "25 characters is over the limit", &ok)
        check(SnippetTrigger.rejection(for: String(repeating: "a", count: 24)) == nil,
              "24 characters is exactly the limit - the fixture's own discriminating power, "
                + "so the case above is not passing for the wrong reason", &ok)

        // Rule 3, asserted directly: Return and Tab must not be terminators,
        // or the send-on-Return hazard in `SnippetTrigger.isTerminator`'s
        // comment is live.
        check(SnippetTrigger.isTerminator(" "), "a space fires", &ok)
        check(SnippetTrigger.isTerminator("."), "so does punctuation", &ok)
        check(!SnippetTrigger.isTerminator("\n"), "Return must not fire", &ok)
        check(!SnippetTrigger.isTerminator("\t"), "nor Tab", &ok)
        check(!SnippetTrigger.isTerminator(";"), "nor the prefix itself", &ok)
        check(!SnippetTrigger.isTerminator("a"), "nor a word character", &ok)
    }

    /// The task brief's own example, plus the rest of the matrix. Each entry
    /// is a literal typed run and the abbreviation it should - or should not -
    /// produce.
    private static func checkWordBoundaries(_ ok: inout Bool) {
        let cases: [(typed: String, expected: String?, why: String)] = [
            (";sig ", "sig", "the plain case"),
            ("Hello ;sig ", "sig", "after a space, mid-sentence"),
            (";sig.", "sig", "punctuation terminates too"),
            ("(;sig)", "sig", "an opening bracket is a boundary"),
            (";sig", nil, "an unterminated trigger has not fired yet"),
            ("foo;sig ", nil, "the brief's own case: not inside a word"),
            (";;sig ", nil, "the literal escape hatch"),
            (";sig\n", nil, "Return does not expand"),
            (";sig\t", nil, "nor does Tab"),
            (";ab", nil, ";ab alone, still being typed"),
            (";abcdef ", "abcdef", "the word that actually ended is abcdef, not ab"),
            ("; sig ", nil, "a space right after the prefix is not a trigger"),
            (";sig-x ", "sig-x", "a hyphen is inside the word, not a terminator"),
            (";SIG ", "SIG", "case is preserved in what was typed"),
            ("a;b;sig ", nil, "the ; before sig is preceded by b - still inside a word"),
            (".;sig ", "sig", "any non-word character opens a boundary"),
        ]
        for c in cases {
            var buffer = SnippetTypingBuffer()
            var produced: SnippetTypedTrigger?
            for character in c.typed {
                if let typed = buffer.consume(.character(character)) { produced = typed }
            }
            check(produced?.abbreviation == c.expected,
                  "typing \u{201c}\(c.typed.replacingOccurrences(of: "\n", with: "\\n"))\u{201d} "
                    + "should yield \(c.expected.map { "\u{201c}\($0)\u{201d}" } ?? "nothing") "
                    + "(\(c.why)), got \(produced?.abbreviation.debugDescription ?? "nothing")",
                  &ok)
        }

        // The deletion length is what the injection is measured in, so it gets
        // its own assertion rather than being implied by the abbreviation.
        var buffer = SnippetTypingBuffer()
        var typed: SnippetTypedTrigger?
        for character in ";sig " { if let t = buffer.consume(.character(character)) { typed = t } }
        check(typed?.typedLength == 5,
              "\u{201c};sig \u{201d} is five characters to delete, got "
                + "\(typed?.typedLength.description ?? "none")", &ok)
        check(typed?.terminator == " ", "and the terminator is the space", &ok)
    }

    private static func checkBufferHousekeeping(_ ok: inout Bool) {
        // Backspacing back into a trigger still lets it fire - a captain who
        // mistypes and corrects has not abandoned the run.
        var buffer = SnippetTypingBuffer()
        for character in ";sigx" { _ = buffer.consume(.character(character)) }
        _ = buffer.consume(.backspace)
        let typed = buffer.consume(.character(" "))
        check(typed?.abbreviation == "sig", "backspace pops one character and the run survives", &ok)

        // An abandon (a click, an arrow key, an app switch) drops it.
        var second = SnippetTypingBuffer()
        for character in ";sig" { _ = second.consume(.character(character)) }
        _ = second.consume(.abandon)
        check(second.consume(.character(" ")) == nil, "an abandoned run cannot fire", &ok)
        check(second.run.isEmpty, "and the run really is emptied, not just ignored", &ok)

        // The buffer is bounded - it is a record of the captain's typing, and
        // this is the assertion behind the privacy claim in
        // `SnippetExpander`'s header.
        var third = SnippetTypingBuffer()
        for character in String(repeating: "x", count: 500) { _ = third.consume(.character(character)) }
        check(third.run.count == SnippetTypingBuffer.capacity,
              "500 characters must leave only \(SnippetTypingBuffer.capacity) behind, got "
                + "\(third.run.count)", &ok)

        // A terminator ends the run whether or not it matched, or a second
        // trigger would be read against the first one's leftovers.
        var fourth = SnippetTypingBuffer()
        for character in "hello " { _ = fourth.consume(.character(character)) }
        check(fourth.run.isEmpty, "a terminator clears the run", &ok)
    }

    // MARK: Lookup

    private static func checkTable(_ ok: inout Bool) {
        let table = SnippetTriggerTable([
            Snippet(label: "Signature", command: "Manjesh P", trigger: "sig", scope: .systemWide),
            Snippet(label: "Context", command: "kubectl", trigger: ";kc"),
            Snippet(label: "No trigger", command: "echo hi"),
            Snippet(label: "Illegal", command: "echo hi", trigger: "bad trigger"),
        ])
        check(table.count == 2, "only the two legal triggers are armed, got \(table.count)", &ok)

        func typed(_ abbreviation: String) -> SnippetTypedTrigger {
            SnippetTypedTrigger(abbreviation: abbreviation, terminator: " ")
        }
        check(table.snippet(for: typed("sig"))?.label == "Signature", "sig resolves", &ok)
        check(table.snippet(for: typed("SIG"))?.label == "Signature",
              "matching is case-insensitive", &ok)
        check(table.snippet(for: typed("kc"))?.label == "Context",
              "a trigger stored with its prefix still resolves without one", &ok)
        check(table.snippet(for: typed("nope")) == nil, "an unknown abbreviation resolves to nothing", &ok)

        // The editor's duplicate check, including the "editing itself is not a
        // clash" case that would otherwise make every re-save fail.
        let existing = Snippet(label: "Signature", command: "x", trigger: "sig")
        let all = [existing]
        check(SnippetTriggerTable.existingSnippet(withTrigger: "sig", in: all, excluding: nil) != nil,
              "a new snippet cannot take a taken trigger", &ok)
        check(SnippetTriggerTable.existingSnippet(withTrigger: "SIG", in: all, excluding: nil) != nil,
              "and case does not get around it", &ok)
        check(SnippetTriggerTable.existingSnippet(withTrigger: "sig", in: all, excluding: existing.id) == nil,
              "but re-saving the snippet that owns it is not a clash", &ok)
    }

    // MARK: Placeholders

    private static func checkPlaceholders(_ ok: inout Bool) {
        check(SnippetPlaceholders.dateString(t0, timeZone: utc) == "2025-09-21",
              "the fixed instant's date, got \(SnippetPlaceholders.dateString(t0, timeZone: utc))", &ok)
        check(SnippetPlaceholders.timeString(t0, timeZone: utc) == "00:00",
              "and its time, got \(SnippetPlaceholders.timeString(t0, timeZone: utc))", &ok)

        let resolved = SnippetPlaceholders.resolve("## Incident {{date}} at {{time}}\n{{clipboard}}",
                                                   now: t0, clipboard: "PROD-91", timeZone: utc)
        check(resolved.text == "## Incident 2025-09-21 at 00:00\nPROD-91",
              "all three substitute, got \u{201c}\(resolved.text)\u{201d}", &ok)
        check(resolved.caretOffsetFromEnd == 0, "no {{cursor}} means no caret walk", &ok)

        let cursored = SnippetPlaceholders.resolve("Hi {{cursor}},\nthanks", now: t0, clipboard: nil,
                                                   timeZone: utc)
        check(cursored.text == "Hi ,\nthanks", "the marker itself is not pasted", &ok)
        check(cursored.caretOffsetFromEnd == 8,
              "the caret walks back over \u{201c},\\nthanks\u{201d}, got \(cursored.caretOffsetFromEnd)", &ok)

        let twoMarkers = SnippetPlaceholders.resolve("a{{cursor}}b{{cursor}}c", now: t0, clipboard: nil)
        check(twoMarkers.text == "abc", "a second marker is stripped rather than pasted", &ok)
        check(twoMarkers.caretOffsetFromEnd == 2, "and only the first positions the caret", &ok)

        // An unknown brace pair survives - a snippet that is itself a template
        // must not be mangled.
        let template = SnippetPlaceholders.resolve("image: {{ .Values.tag }}", now: t0, clipboard: nil)
        check(template.text == "image: {{ .Values.tag }}",
              "an unrecognised placeholder is left verbatim, got \u{201c}\(template.text)\u{201d}", &ok)

        // A nil clipboard is the concealed-pasteboard case, and it resolves to
        // nothing rather than to the literal marker.
        let concealed = SnippetPlaceholders.resolve("token: {{clipboard}}", now: t0, clipboard: nil)
        check(concealed.text == "token: ",
              "a refused clipboard expands to nothing, got \u{201c}\(concealed.text)\u{201d}", &ok)
    }

    // MARK: The clipboard placeholder and vault material

    /// `{{clipboard}}` makes this feature the app's fourth reader of the
    /// pasteboard, and AGENTS.md's rule for those is explicit: ask
    /// `CredentialVaultClipboard.isConcealed` **before** reading the string,
    /// so "a vault secret never reaches a snippet" is a property of the
    /// control flow. Asserted against a real, really-marked pasteboard rather
    /// than described.
    private static func checkClipboardRefusesVaultMaterial(_ ok: inout Bool) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("fm.snippet.selftest"))
        pasteboard.clearContents()
        pasteboard.setString("PROD-91", forType: .string)
        check(SnippetExpander.clipboardText(pasteboard) == "PROD-91",
              "an ordinary pasteboard is read, got "
                + "\(SnippetExpander.clipboardText(pasteboard).debugDescription)", &ok)

        _ = CredentialVaultClipboard.writeConcealed("hunter2", to: pasteboard)
        // The fixture's own discriminating power: the marker really is there,
        // or the refusal below proves nothing.
        check(CredentialVaultClipboard.isConcealed(pasteboard),
              "the fixture really is marked concealed", &ok)
        check(pasteboard.string(forType: .string) == "hunter2",
              "and the secret really is readable if nobody checks - which is the point", &ok)
        check(SnippetExpander.clipboardText(pasteboard) == nil,
              "but a concealed pasteboard is refused, got "
                + "\(SnippetExpander.clipboardText(pasteboard).debugDescription)", &ok)
        pasteboard.clearContents()
    }

    // MARK: Policy

    private static func base(_ overrides: (inout SnippetExpansionContext) -> Void = { _ in })
        -> SnippetExpansionContext {
        var context = SnippetExpansionContext(expansionEnabled: true,
                                              accessibilityTrusted: true,
                                              appIsLocked: false,
                                              isGrandLineFrontmost: false,
                                              isConsoleFocused: false,
                                              frontmostBundleID: "com.apple.mail",
                                              frontmostAppName: "Mail")
        overrides(&context)
        return context
    }

    private static func checkPolicy(_ ok: inout Bool) {
        let wide = Snippet(label: "Signature", command: "Manjesh P", trigger: "sig", scope: .systemWide)
        let shell = Snippet(label: "Drain", command: "kubectl drain", trigger: "drain")

        check(SnippetExpansionPolicy.refusal(for: wide, in: base()) == nil,
              "a system-wide snippet expands in Mail", &ok)
        check(SnippetExpansionPolicy.refusal(for: shell, in: base()) == .outsideConsole,
              "a Console-only snippet does not", &ok)
        check(SnippetExpansionPolicy.refusal(for: shell, in: base {
            $0.isGrandLineFrontmost = true
            $0.isConsoleFocused = true
        }) == nil, "but it does in the Console", &ok)
        check(SnippetExpansionPolicy.refusal(for: shell, in: base {
            $0.isGrandLineFrontmost = true
        }) == .outsideConsole, "frontmost alone is not enough - the Console has to be showing", &ok)

        // GL-09, and the reason `.snippetExpansion` is its own case.
        check(SnippetExpansionPolicy.refusal(for: wide, in: base { $0.appIsLocked = true }) == .appLocked,
              "nothing expands while the app is locked", &ok)
        check(SnippetExpansionPolicy.refusal(for: wide, in: base { $0.expansionEnabled = false })
                == .expansionTurnedOff, "nor while the feature is off", &ok)
        check(SnippetExpansionPolicy.refusal(for: wide, in: base { $0.accessibilityTrusted = false })
                == .accessibilityNotTrusted,
              "nor without Accessibility trust - it degrades to a named refusal, not a crash or a "
                + "silent no-op", &ok)

        // Precedence: a locked app that is also untrusted reports the lock,
        // because that is the one the captain can act on first.
        check(SnippetExpansionPolicy.refusal(for: wide, in: base {
            $0.appIsLocked = true
            $0.accessibilityTrusted = false
        }) == .appLocked, "the lock is reported before the permission", &ok)

        let untriggered = Snippet(label: "Plain", command: "echo", scope: .systemWide)
        check(SnippetExpansionPolicy.refusal(for: untriggered, in: base()) == .noTrigger,
              "a snippet with no trigger cannot expand however it is scoped", &ok)

        // Exclusions, by bundle id and by the name in the Dock.
        var excludedByID = wide
        excludedByID.excludedApps = ["com.apple.Mail"]
        check(SnippetExpansionPolicy.refusal(for: excludedByID, in: base())
                == .excludedApp("com.apple.Mail"),
              "an excluded bundle id refuses, case-insensitively", &ok)
        var excludedByName = wide
        excludedByName.excludedApps = ["  mail "]
        check(SnippetExpansionPolicy.refusal(for: excludedByName, in: base())
                == .excludedApp("  mail "),
              "so does the app's own name, trimmed", &ok)
        var excludedElsewhere = wide
        excludedElsewhere.excludedApps = ["1Password"]
        check(SnippetExpansionPolicy.refusal(for: excludedElsewhere, in: base()) == nil,
              "an exclusion that does not match the frontmost app is not a refusal", &ok)
    }

    // MARK: Store compatibility

    private static func checkLegacyDecode(_ ok: inout Bool) {
        // GL-01: the exact shape every `snippets.json` written before F12
        // holds. This must decode, and it must decode conservatively.
        let legacy = Data("""
            [{"id":"6C9B2F5E-0000-4000-8000-000000000001","label":"Drain","command":"kubectl drain"}]
            """.utf8)
        guard let decoded = try? JSONDecoder().decode([Snippet].self, from: legacy),
              let first = decoded.first else {
            fail("a pre-F12 snippets.json must still decode", &ok)
            return
        }
        check(first.label == "Drain", "the original fields survive", &ok)
        check(first.trigger.isEmpty, "with no trigger", &ok)
        check(first.scope == .consoleOnly, "and the conservative scope", &ok)
        check(first.excludedApps.isEmpty, "and no exclusions", &ok)

        // An unrecognised scope must not take the file with it.
        let futureScope = Data("""
            [{"id":"6C9B2F5E-0000-4000-8000-000000000002","label":"X","command":"y","scope":"martian"}]
            """.utf8)
        let recovered = try? JSONDecoder().decode([Snippet].self, from: futureScope)
        check(recovered?.first?.scope == .consoleOnly,
              "an unknown scope reads as Console-only rather than failing the whole decode", &ok)

        // And a round trip keeps everything, so the fixture above is testing
        // the decoder rather than a field that never encodes.
        let rich = Snippet(label: "Signature", command: "Manjesh P", trigger: "sig",
                           scope: .systemWide, excludedApps: ["1Password"])
        guard let data = try? JSONEncoder().encode([rich]),
              let back = try? JSONDecoder().decode([Snippet].self, from: data).first else {
            fail("a snippet with every F12 field must round trip", &ok)
            return
        }
        check(back == rich, "and come back byte-identical", &ok)
    }

    // MARK: Key events

    private static func keyDown(_ characters: String,
                                keyCode: UInt16 = 0,
                                flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    private static func checkKeyEventClassification(_ ok: inout Bool) {
        check(SnippetExpander.typingEvents(for: keyDown("a")) == [.character("a")],
              "an ordinary key is a character", &ok)
        check(SnippetExpander.typingEvents(for: keyDown("V", flags: .command)) == [.abandon],
              "⌘V is a verb, not typing - and it moves the caret", &ok)
        check(SnippetExpander.typingEvents(for: keyDown("A", flags: .shift)) == [.character("A")],
              "shift is how a capital gets typed, so it is not disqualifying", &ok)
        check(SnippetExpander.typingEvents(for: keyDown("\u{08}", keyCode: 51)) == [.backspace],
              "keycode 51 is delete", &ok)
        check(SnippetExpander.typingEvents(for: keyDown("\r", keyCode: 36)) == [.abandon],
              "Return abandons the run", &ok)
        check(SnippetExpander.typingEvents(for: keyDown("", keyCode: 123)) == [.abandon],
              "so does an arrow key", &ok)
    }

    // MARK: End to end

    /// A real `SnippetExpander` over a real scratch `SnippetStore`, typed into
    /// character by character, reporting through the injection sink. This is
    /// the whole path bar the `CGEvent.post` at the end of it.
    private static func checkEndToEndExpansion(_ ok: inout Bool) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippet-expansion-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FM_SNIPPETS_FILE", dir.appendingPathComponent("snippets.json").path, 1)

        let store = SnippetStore()
        store.add(Snippet(label: "Signature", command: "Manjesh P\nPlatform Engineering",
                          trigger: "sig", scope: .systemWide))
        store.add(Snippet(label: "Postmortem",
                          command: "## Incident {{date}}\n**Impact** {{cursor}}\n**Timeline**",
                          trigger: "pm", scope: .systemWide))
        store.add(Snippet(label: "Drain", command: "kubectl drain $NODE", trigger: "drain"))

        let expander = SnippetExpander(store: store)
        expander.clock = { t0 }
        expander.contextOverrideForTests = base()
        var injections: [SnippetInjection] = []
        expander.injectionSinkForTests = { injections.append($0) }

        check(expander.armedTriggerCount == 3,
              "three saved triggers are armed, got \(expander.armedTriggerCount)", &ok)

        expander.debugType("Thanks - will confirm. ;sig ")
        guard let signature = injections.first else {
            fail("typing ;sig in Mail should have produced an expansion", &ok)
            return
        }
        check(signature.deleteCount == 5,
              "five characters come off first, got \(signature.deleteCount)", &ok)
        check(signature.text == "Manjesh P\nPlatform Engineering ",
              "and the snippet plus the typed space goes on, got "
                + "\u{201c}\(signature.text)\u{201d}", &ok)
        check(signature.caretLeftCount == 0, "with no caret walk", &ok)

        // The store's own change signal has to reach the table, or an edit
        // made on the page would not take effect until relaunch.
        injections.removeAll()
        store.add(Snippet(label: "Address", command: "Prestige Tech Park", trigger: "addr",
                          scope: .systemWide))
        expander.rebuildTable()
        expander.debugType(";addr ")
        check(injections.count == 1, "a snippet added after launch expands", &ok)

        // `{{date}}` and `{{cursor}}` through the real path.
        injections.removeAll()
        expander.debugType(";pm ")
        guard let postmortem = injections.first else {
            fail(";pm should have expanded", &ok)
            return
        }
        check(postmortem.text == "## Incident 2025-09-21\n**Impact** \n**Timeline** ",
              "placeholders resolve on the real path, got \u{201c}\(postmortem.text)\u{201d}", &ok)
        // 13 characters of tail, plus the one re-typed terminator.
        check(postmortem.caretLeftCount == 14,
              "the caret walks back to where {{cursor}} was, got \(postmortem.caretLeftCount)", &ok)

        // A Console-only snippet in Mail is refused, and says why.
        injections.removeAll()
        expander.debugType(";drain ")
        check(injections.isEmpty, "a Console-only snippet does not expand in Mail", &ok)
        check(expander.lastRefusal?.refusal == .outsideConsole,
              "and the refusal is recorded, so the UI can answer for it", &ok)
        check(expander.lastRefusal?.trigger == ";drain", "naming the trigger that was typed", &ok)

        // The same snippet, in the Console.
        injections.removeAll()
        expander.contextOverrideForTests = base {
            $0.isGrandLineFrontmost = true
            $0.isConsoleFocused = true
            $0.frontmostBundleID = "com.manjesh.grandline.native"
            $0.frontmostAppName = "Grand Line"
        }
        expander.debugType(";drain ")
        check(injections.first?.text == "kubectl drain $NODE ",
              "and does expand in the Console, got "
                + "\(injections.first?.text.debugDescription ?? "nothing")", &ok)

        // The brief's boundary case, end to end rather than only in the buffer.
        injections.removeAll()
        expander.contextOverrideForTests = base()
        expander.debugType("foo;sig ")
        check(injections.isEmpty, "foo;sig does not expand - the brief's own case", &ok)

        // And the lock, end to end: this is the GL-09 assertion that would
        // pass just as happily with the gate deleted if it were only made
        // against the policy function.
        injections.removeAll()
        expander.contextOverrideForTests = base { $0.appIsLocked = true }
        expander.debugType(";sig ")
        check(injections.isEmpty, "nothing expands while the app is locked", &ok)
        check(expander.lastRefusal?.refusal == .appLocked, "and the reason is the lock", &ok)

        try? FileManager.default.removeItem(at: dir)
    }
}

#endif
