// Manjesh Grand Line - native macOS app.
//
// `FM_RUN_STRAW_HAT_TRANSCRIPT_TESTS` - review #3's UX12 (M1.4's persistence
// half).
//
// Two things are worth guarding here, and the second is the one with teeth:
//
//   1. A conversation survives a quit. Asserted through a **real disk round
//      trip on a fresh store instance** over the same directory, not through
//      the store's own memory - the whole finding is "its history is lost on
//      quit", so an in-memory check would assert nothing about it.
//   2. **Nothing reaches that file unredacted.** A captain asks the crew about
//      a failing deploy by pasting the output, and that output carries tokens
//      and connection strings. In memory for a session was one risk; on disk,
//      synced, is another entirely - so the redaction is asserted at the
//      boundary, on the bytes, rather than on a call being made.
//
// Real files in a scratch directory, no window, no view - so this is not in
// `NEEDS_SESSION`. The store's `root:` seam is what keeps it off the captain's
// synced clone.
//
// GL-27: debug builds only.
#if FM_SELFTESTS

import Foundation

enum StrawHatTranscriptSelfTest {
    static func run() -> Bool {
        var ok = true
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("straw-hat-transcript-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        ok = checkRoundTrip(scratch: scratch) && ok
        ok = checkRedactionAtTheBoundary(scratch: scratch) && ok
        ok = checkDecodingIsForgiving() && ok
        ok = checkEnumerationFailureIsNotEmptiness(scratch: scratch) && ok
        return ok
    }

    private static func checkRoundTrip(scratch: URL) -> Bool {
        var ok = true
        let root = scratch.appendingPathComponent("round-trip", isDirectory: true)
        let store = StrawHatTranscriptStore(root: root)

        check(store.list()?.isEmpty == true, "UX12: a fresh store should list no conversations", &ok)

        var transcript = StrawHatTranscript(id: "c1", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        transcript = StrawHatTranscriptStore.appending("why did the deploy fail?", speaker: .captain, to: transcript)
        transcript = StrawHatTranscriptStore.appending("The rollout hit a readiness probe.",
                                                      speaker: .crew, member: "luffy", to: transcript)
        store.save(transcript)

        // A **fresh instance** over the same directory - the quit this finding
        // is about.
        let reread = StrawHatTranscriptStore(root: root)
        guard let listed = reread.list(), let loaded = listed.first else {
            fail("UX12: the conversation did not survive a reload - this is the whole finding", &ok)
            return ok
        }
        check(listed.count == 1, "UX12: expected one stored conversation, got \(listed.count)", &ok)
        check(loaded.id == "c1", "UX12: the conversation's id did not survive", &ok)
        check(loaded.messages.count == 2, "UX12: \(loaded.messages.count) turn(s) survived, expected 2", &ok)
        check(loaded.messages.first?.speaker == .captain, "UX12: the first turn should be the captain's", &ok)
        check(loaded.messages.first?.text == "why did the deploy fail?",
              "UX12: the captain's words did not survive intact", &ok)
        check(loaded.messages.last?.member == "luffy",
              "UX12: the crew member who spoke did not survive", &ok)
        check(loaded.title == "why did the deploy fail?",
              "UX12: the listing title should be the captain's opening line, got \(String(describing: loaded.title))", &ok)

        // An empty conversation is not written: a page opened and left is not
        // history.
        store.save(StrawHatTranscript(id: "empty"))
        check(StrawHatTranscriptStore(root: root).list()?.count == 1,
              "UX12: an exchange-free conversation was written to disk", &ok)

        // Two conversations, newest first - the order a listing wants.
        var second = StrawHatTranscript(id: "c2", startedAt: Date(timeIntervalSince1970: 1_700_009_999))
        second = StrawHatTranscriptStore.appending("and the database?", speaker: .captain, to: second)
        store.save(second)
        check(StrawHatTranscriptStore(root: root).list()?.map(\.id) == ["c2", "c1"],
              "UX12: conversations should list newest first", &ok)
        return ok
    }

    /// The security-shaped half. Asserted **on the bytes on disk**, not on the
    /// decoded model: the claim is that a secret never reaches the file, and
    /// only reading the file back can settle that.
    private static func checkRedactionAtTheBoundary(scratch: URL) -> Bool {
        var ok = true
        let root = scratch.appendingPathComponent("redaction", isDirectory: true)
        let store = StrawHatTranscriptStore(root: root)

        // A real-shaped secret, and one the redactor is known to catch - the
        // fixture's own discriminating power is asserted first, so a drifted
        // redactor fails loudly here instead of letting every check below
        // pass vacuously.
        let secret = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let probe = LogRedactor.redact(secret)
        guard probe.count > 0, !probe.text.contains(secret) else {
            fail("UX12: LogRedactor no longer masks the fixture secret - every redaction check below is vacuous", &ok)
            return ok
        }

        var transcript = StrawHatTranscript(id: "secretive")
        transcript = StrawHatTranscriptStore.appending("the deploy log says \(secret)",
                                                      speaker: .captain, to: transcript)
        check(!transcript.messages.contains { $0.text.contains(secret) },
              "UX12: the secret survived into the in-memory transcript", &ok)
        check(transcript.redactionCount > 0,
              "UX12: the redaction was not counted, so nothing can report that one happened", &ok)

        store.save(transcript)

        guard let files = try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("conversations", isDirectory: true),
                includingPropertiesForKeys: nil),
              let file = files.first(where: { $0.pathExtension == "json" }),
              let raw = try? String(contentsOf: file, encoding: .utf8) else {
            fail("UX12: could not read the written conversation back off disk", &ok)
            return ok
        }
        check(!raw.contains(secret),
              "UX12: the secret reached the file on disk - redaction must happen at the boundary, not at read time", &ok)
        check(raw.contains("the deploy log says"),
              "UX12: redaction ate the surrounding message as well as the secret", &ok)

        // An empty or whitespace-only turn is not a turn.
        let unchanged = StrawHatTranscriptStore.appending("   \n  ", speaker: .captain, to: transcript)
        check(unchanged.messages.count == transcript.messages.count,
              "UX12: a whitespace-only turn was recorded", &ok)
        return ok
    }

    /// GL-01: a file this build cannot fully read still loads.
    private static func checkDecodingIsForgiving() -> Bool {
        var ok = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Every optional field missing, which is what a file written by a
        // different build's shape looks like.
        let sparse = #"{"messages":[{"speaker":"captain","text":"hello"}]}"#.data(using: .utf8)!
        guard let decoded = try? decoder.decode(StrawHatTranscript.self, from: sparse) else {
            fail("UX12: a conversation missing every optional field failed to decode at all (GL-01)", &ok)
            return ok
        }
        check(decoded.messages.count == 1, "UX12: the one turn in a sparse file was lost", &ok)
        check(decoded.messages.first?.text == "hello", "UX12: the turn's text was lost", &ok)
        check(decoded.redactionCount == 0, "UX12: a missing redaction count should default to zero", &ok)
        check(!decoded.id.isEmpty, "UX12: a missing id should be defaulted, not left blank", &ok)
        return ok
    }

    /// GL-21: "the directory could not be enumerated" is not "the directory is
    /// empty", and the difference matters here because the follow-up roster UI
    /// will render one as "no history yet".
    private static func checkEnumerationFailureIsNotEmptiness(scratch: URL) -> Bool {
        var ok = true
        let root = scratch.appendingPathComponent("gone", isDirectory: true)
        let store = StrawHatTranscriptStore(root: root)
        // Remove the directory the store just made, under it.
        try? FileManager.default.removeItem(at: root)
        check(store.list() == nil,
              "UX12: an unreadable conversations directory reported as empty rather than as unknown (GL-21)", &ok)
        return ok
    }
}

#endif
