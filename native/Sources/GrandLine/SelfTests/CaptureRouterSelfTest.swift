// Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for universal capture's *logic* half
// (`fm/grandline-feature-f2-f3-capture-clipboard`, F2 of full review #3 §8):
// the digit-to-destination map, the one-line parse every destination shares,
// the derived names each store needs, the crew classifier's prompt and its
// reply parsing, and the pasteboard offer's refusal of anything Poneglyph
// copied.
//
// **Pure logic, no window** - and the classification is operative, not a style
// note: `NEEDS_SESSION` in `Scripts/run-all-tests.sh` decides whether a suite
// guards the *blocking* CI job, so a pure-logic suite parked there would still
// pass, still look healthy, and never once guard a merge (AGENTS.md's "Writing
// a self-test"). Nothing here builds a view. `CaptureRouterViewSelfTest` is the
// window-backed half, and it is the one in `NEEDS_SESSION`.
//
// **Every pasteboard here is a named one, never `.general`.** A suite that
// wrote to the system pasteboard would destroy whatever the captain had
// copied, on every single run - which is exactly the class of "never touch
// real captain data" the `#if FM_SELFTESTS` store redirects exist for, just
// one the redirect block cannot reach.
//
// `FM_RUN_CAPTURE_ROUTER_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CaptureRouterSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkChordMap(check)
        checkDraftSplitsTitleAndBody(check)
        checkDraftReadsTheDate(check)
        checkElide(check)
        checkDerivedNames(check)
        checkClassificationPrompt(check)
        checkClassificationParsing(check)
        checkPasteboardOffer(check)
        checkConcealedPasteboardIsRefused(check)
        checkDestinationIdentity(check)

        print(ok ? "CaptureRouterSelfTest: OK" : "CaptureRouterSelfTest: FAILURES")
        return ok
    }

    // MARK: A scratch pasteboard

    /// A private `NSPasteboard`, never `.general` - see this file's header.
    private static func withScratchPasteboard(_ body: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("grandline-capture-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        body(pasteboard)
    }

    // MARK: The chords

    private static func checkChordMap(_ check: (Bool, String) -> Void) {
        // The report's own mapping, asserted literally rather than derived
        // from the same `allCases` order the production code derives it from -
        // a check that re-derives its expectation from the function under test
        // asserts nothing at all (AGENTS.md's verification conventions).
        let expected: [(Int, CaptureDestination)] = [
            (1, .task), (2, .sticky), (3, .note), (4, .credential), (5, .codeSnippet),
        ]
        for (digit, destination) in expected {
            check(CaptureDestination.forChordDigit(digit) == destination,
                  "\u{2318}\(digit) files as \(destination.rawValue), got \(String(describing: CaptureDestination.forChordDigit(digit)))")
            check(destination.chordDigit == digit,
                  "\(destination.rawValue) prints \u{2318}\(digit), got \u{2318}\(destination.chordDigit)")
        }
        // The fixture's discriminating power: the map really does refuse
        // everything else, so a clamp or an off-by-one would fail here rather
        // than pass silently.
        // `fm/grandline-feature-f4-reading-list` appended `.link` as \u{2318}6,
        // so 6 moved out of this list and 7 took its place - appended rather
        // than inserted precisely so the five above kept their digits.
        for digit in [-1, 0, 7, 9] {
            check(CaptureDestination.forChordDigit(digit) == nil,
                  "\u{2318}\(digit) is not a destination, got \(String(describing: CaptureDestination.forChordDigit(digit)))")
        }
        check(CaptureDestination.allCases.count == 6,
              "six destinations, found \(CaptureDestination.allCases.count)")
    }

    // MARK: The draft

    private static func checkDraftSplitsTitleAndBody(_ check: (Bool, String) -> Void) {
        let draft = CaptureRouter.draft(from: "  Rotate the RaaS deploy key\n\nBefore Friday.\nAsk Ravi.  ")
        check(draft.title == "Rotate the RaaS deploy key",
              "the first line is the title, got \(draft.title)")
        check(draft.body == "Before Friday.\nAsk Ravi.",
              "the rest is the body, got \(draft.body.debugDescription)")
        check(draft.text == "Rotate the RaaS deploy key\n\nBefore Friday.\nAsk Ravi.",
              "the whole trimmed text is preserved, got \(draft.text.debugDescription)")

        let oneLine = CaptureRouter.draft(from: "kubectl -n raas get pods")
        check(oneLine.title == "kubectl -n raas get pods", "a one-line capture is all title")
        check(oneLine.body.isEmpty, "a one-line capture has no body, got \(oneLine.body.debugDescription)")

        check(CaptureRouter.draft(from: "   \n  ").isEmpty, "whitespace-only is empty")
        check(!oneLine.isEmpty, "a real capture is not empty")
    }

    private static func checkDraftReadsTheDate(_ check: (Bool, String) -> Void) {
        // A pinned clock, because "friday 3pm" is a function of it.
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 21      // a Monday
        components.hour = 10
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let now = calendar.date(from: components) else {
            check(false, "could not build the pinned clock")
            return
        }

        let dated = CaptureRouter.draft(from: "Ask Ravi for the VPC peering CIDR friday 3pm", now: now)
        guard let due = dated.dueDate else {
            check(false, "\u{201C}friday 3pm\u{201D} parsed to no date at all")
            return
        }
        check(dated.dueHasTime, "\u{201C}friday 3pm\u{201D} carries a time of day")
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: due)
        check(parts.hour == 15, "3pm is hour 15, got \(String(describing: parts.hour))")
        check(parts.day == 25 && parts.month == 9,
              "the Friday after Mon 21 Sep 2026 is the 25th, got \(String(describing: parts.day))/\(String(describing: parts.month))")

        // The discriminating half: text with no date really does produce nil,
        // so the check above is not passing on a parser that always answers.
        let plain = CaptureRouter.draft(from: "kubectl -n raas get pods", now: now)
        check(plain.dueDate == nil, "a command with no date parses to no date")
        check(!plain.dueHasTime, "a command with no date carries no time")
    }

    private static func checkElide(_ check: (Bool, String) -> Void) {
        let short = "a short title"
        check(CaptureRouter.elide(short) == short, "a short title is untouched")

        let words = String(repeating: "word ", count: 40)
        let elided = CaptureRouter.elide(words)
        check(elided.count <= CaptureRouter.derivedTitleLimit + 1,
              "an elided title fits the limit, got \(elided.count)")
        check(elided.hasSuffix("\u{2026}"), "an elided title is marked, got \(elided)")
        check(!elided.hasSuffix(" \u{2026}"), "the elide does not leave a trailing space")

        // The hard-cut branch: one token longer than the budget has no word
        // boundary to break on at all.
        let token = String(repeating: "x", count: 200)
        let cut = CaptureRouter.elide(token)
        check(cut.count == CaptureRouter.derivedTitleLimit + 1,
              "a single long token is hard-cut, got \(cut.count)")
    }

    private static func checkDerivedNames(_ check: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let named = CaptureRouter.draft(from: "deploy notes.sh\necho hi")
        check(CaptureRouter.snippetName(for: named, now: now) == "deploy notes.sh",
              "a usable first line names the snippet, got \(CaptureRouter.snippetName(for: named, now: now))")

        // A capture whose first line sanitises to nothing must not silently
        // become `snippet.txt` alongside every other such capture - that is
        // the substitution `CodePreviewStore.sanitize` makes, and the whole
        // reason `snippetName` checks its input as well as its output.
        let punctuation = CaptureRouter.draft(from: "...\nbody")
        let fallback = CaptureRouter.snippetName(for: punctuation, now: now)
        check(fallback.hasPrefix("capture-") && fallback.hasSuffix(".txt"),
              "an unusable first line falls back to a dated name, got \(fallback)")
        check(!fallback.contains(":"), "the dated name needs no sanitising, got \(fallback)")

        check(CaptureRouter.notebookTitle(for: named, now: now) == "deploy notes.sh",
              "the notebook page takes the first line")
        let empty = CaptureRouter.draft(from: "")
        check(CaptureRouter.notebookTitle(for: empty, now: now).hasPrefix("Capture "),
              "an empty capture still gets a notebook title")

        // ⌘4's title is deliberately NOT the captured text - the captured text
        // is the secret. A regression that "helpfully" titled it would put the
        // secret in a plaintext field, which is why this is asserted rather
        // than left to the call site.
        let secret = CaptureRouter.draft(from: "hunter2-the-real-production-token")
        check(!CaptureRouter.credentialTitle(now: now).contains("hunter2"),
              "the credential title never carries the captured secret")
        check(CaptureRouter.credentialTitle(now: now).hasPrefix("Captured "),
              "the credential title is dated, got \(CaptureRouter.credentialTitle(now: now))")
        check(secret.text == "hunter2-the-real-production-token", "the draft still holds the secret itself")
    }

    // MARK: The crew

    private static func checkClassificationPrompt(_ check: (Bool, String) -> Void) {
        let prompt = CaptureRouter.classificationPrompt(for: "rotate the deploy key")
        check(prompt.contains("rotate the deploy key"), "the prompt carries the captured text")
        for destination in CaptureDestination.allCases {
            check(prompt.contains(destination.rawValue),
                  "the prompt names \(destination.rawValue) as an answer")
        }
        check(prompt.contains("nothing but"), "the prompt states the output contract")
    }

    private static func checkClassificationParsing(_ check: (Bool, String) -> Void) {
        // The shapes a model actually produces.
        let accepted: [(String, CaptureDestination)] = [
            ("task", .task),
            ("  sticky\n", .sticky),
            ("\"note\"", .note),
            ("credential.", .credential),
            ("codeSnippet", .codeSnippet),
            ("CODESNIPPET", .codeSnippet),
            ("`task`", .task),
        ]
        for (reply, expected) in accepted {
            check(CaptureRouter.parseClassification(reply) == expected,
                  "\(reply.debugDescription) reads as \(expected.rawValue), got \(String(describing: CaptureRouter.parseClassification(reply)))")
        }

        // And the shapes that must NOT be guessed at. A prose answer that
        // merely *mentions* a destination is the dangerous one: a substring
        // match would file "this is not a task, it is a note" as a task.
        for reply in ["", "   ", "I think this is a task, or maybe a note.",
                      "task or sticky", "inbox", "Here you go: task"] {
            check(CaptureRouter.parseClassification(reply) == nil,
                  "\(reply.debugDescription) is not a destination, got \(String(describing: CaptureRouter.parseClassification(reply)))")
        }
    }

    // MARK: The pasteboard offer

    private static func checkPasteboardOffer(_ check: (Bool, String) -> Void) {
        withScratchPasteboard { pasteboard in
            pasteboard.clearContents()
            check(ShiftQuickCaptureController.pasteboardOffer(pasteboard) == nil,
                  "an empty pasteboard offers nothing")

            pasteboard.clearContents()
            pasteboard.setString("   \n  ", forType: .string)
            check(ShiftQuickCaptureController.pasteboardOffer(pasteboard) == nil,
                  "a whitespace-only pasteboard offers nothing")

            pasteboard.clearContents()
            pasteboard.setString("10.42.0.0/16", forType: .string)
            check(ShiftQuickCaptureController.pasteboardOffer(pasteboard) == "10.42.0.0/16",
                  "an ordinary copy is offered, got \(String(describing: ShiftQuickCaptureController.pasteboardOffer(pasteboard)))")

            pasteboard.clearContents()
            pasteboard.setString("first\nsecond", forType: .string)
            let multi = ShiftQuickCaptureController.pasteboardOffer(pasteboard) ?? ""
            check(!multi.contains("\n"), "a multi-line copy is offered as one line, got \(multi.debugDescription)")
            check(multi.contains("first") && multi.contains("second"),
                  "a multi-line offer keeps both lines' text, got \(multi.debugDescription)")
        }
    }

    /// **The security half of F2**, and the same rule F3's history enforces.
    private static func checkConcealedPasteboardIsRefused(_ check: (Bool, String) -> Void) {
        withScratchPasteboard { pasteboard in
            // Proof the fixture can see a secret at all before proving it
            // refuses one - a check that cannot fail is worse than no check.
            pasteboard.clearContents()
            pasteboard.setString("hunter2", forType: .string)
            check(ShiftQuickCaptureController.pasteboardOffer(pasteboard) == "hunter2",
                  "the same string IS offered when it is not marked concealed")
            check(!CredentialVaultClipboard.isConcealed(pasteboard),
                  "an ordinary copy is not concealed")

            CredentialVaultClipboard.writeConcealed("hunter2", to: pasteboard)
            check(CredentialVaultClipboard.isConcealed(pasteboard),
                  "a Poneglyph copy is recognised as concealed")
            check(pasteboard.string(forType: .string) == "hunter2",
                  "the value really is on the pasteboard - the refusal is a decision, not an empty read")
            check(ShiftQuickCaptureController.pasteboardOffer(pasteboard) == nil,
                  "the capture panel offers nothing for a Poneglyph copy, got \(String(describing: ShiftQuickCaptureController.pasteboardOffer(pasteboard)))")
        }

        // Each marker alone is enough - the point of honouring the
        // nspasteboard.org convention is to honour another app's write too,
        // and those carry one marker rather than this app's three.
        for marker in CredentialVaultClipboard.concealedMarkerTypes {
            withScratchPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("hunter2", forType: .string)
                pasteboard.setData(Data(), forType: marker)
                check(CredentialVaultClipboard.isConcealed(pasteboard),
                      "\(marker.rawValue) alone conceals")
                check(ShiftQuickCaptureController.pasteboardOffer(pasteboard) == nil,
                      "\(marker.rawValue) alone suppresses the capture chip")
            }
        }
    }

    // MARK: Identity

    private static func checkDestinationIdentity(_ check: (Bool, String) -> Void) {
        // Every tile has to resolve a real symbol and land on a real
        // destination; a nil symbol renders an invisible tile, which this app
        // has shipped before (`HelmSymbol.image`'s own note).
        var hues = Set<HelmDomainHue>()
        for destination in CaptureDestination.allCases {
            check(HelmSymbol.image(destination.symbol, pointSize: 14) != nil,
                  "\(destination.rawValue)'s symbol \(destination.symbol) resolves")
            check(!destination.title.isEmpty, "\(destination.rawValue) has a tile title")
            check(!destination.confirmation.isEmpty, "\(destination.rawValue) has a confirmation line")
            hues.insert(destination.hue)
        }
        check(hues.count == CaptureDestination.allCases.count,
              "each destination has its own hue, found \(hues.count) for \(CaptureDestination.allCases.count)")

        let expected: [CaptureDestination: RailDestination] = [
            .task: .shift, .sticky: .stickyBoard, .note: .notebook,
            .credential: .poneglyph, .codeSnippet: .codePreview,
        ]
        for (destination, rail) in expected {
            check(destination.railDestination == rail,
                  "\(destination.rawValue) points at \(rail), got \(destination.railDestination)")
        }
    }
}

#endif
