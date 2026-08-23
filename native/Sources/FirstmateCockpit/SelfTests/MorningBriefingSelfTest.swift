// Manjesh Grand Line - native macOS app.
//
// Permanent, env-gated self-test for F12's morning briefing - run via
// `FM_RUN_MORNING_BRIEFING_TESTS=1 .build/debug/FirstmateCockpit`, same
// convention as every other suite here.
//
// What this covers, and why it is the right half of the feature to pin:
//
//   1. **The local layer** (`MorningBriefingLocal`) - what data goes in and
//      what the deterministic clause list / stat line says about it. This is
//      the layer that decides every *number* the captain reads, and it is
//      fully offline, so it can be asserted exactly.
//   2. **The `nil`-is-not-zero rule** - a failed PR scan and a poller that has
//      not run yet must not read as "nothing is ready" / "nothing has
//      drifted". Getting this wrong is GL-14's exact bug, and it is the kind
//      of thing that looks fine in a screenshot.
//   3. **Degradation** - the real `ClaudeOneShot` path against a disposable
//      fake `claude`, both succeeding and failing, plus the guarantee the
//      whole feature rests on: a failed AI call still produces a briefing,
//      built from the local clauses, flagged as degraded.
//   4. **Reply validation** - a model cannot name a destination that does not
//      exist, cannot choose a colour, and cannot return a hundred clauses.
//
// The AI *wording* is deliberately not asserted (a model's prose is not a
// deterministic function of its input) - the prompt's contents are, since that
// is where "only already-computed derived state, never terminal output" is
// actually enforced.

// GL-27: compiled into debug builds only. Do not remove this guard when
// editing a suite - `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum MorningBriefingSelfTest {
    @discardableResult
    static func run() -> Bool {
        var ok = true
        checkLocalClauses(&ok)
        checkUnknownIsNotZero(&ok)
        checkStatLine(&ok)
        checkSources(&ok)
        checkPromptCarriesOnlyDerivedState(&ok)
        checkReplyValidation(&ok)
        checkRecordAndDayKey(&ok)
        checkShiftDue(&ok)
        checkDegradation(&ok)
        checkCardRendering(&ok)

        if ok {
            print("MorningBriefingSelfTest: all checks passed")
        } else {
            print("MorningBriefingSelfTest: FAILED")
        }
        return ok
    }

    // MARK: 1 - the local layer

    /// A realistic morning: two PRs green, one fleet task blocked, two forks
    /// behind, 40% of the weekly quota gone. The same shape section 25's F12
    /// example names.
    private static func busyMorning() -> BriefingInputs {
        var inputs = BriefingInputs()
        inputs.workingCount = 3
        inputs.needsDecisionCount = 1
        inputs.blockedCount = 0
        inputs.doneTodayCount = 4
        inputs.queuedCount = 2
        inputs.watcherStatus = "healthy"
        inputs.prReadyCount = 2
        inputs.dueTaskCount = 1
        inputs.dueFollowUpCount = 0
        inputs.singleDueTaskID = "task-142"
        inputs.forkDriftCount = 2
        inputs.toolUpdateCount = 0
        inputs.setupDriftCount = 0
        inputs.quotaWeeklyPercentUsed = 40
        inputs.quotaWeeklyPace = "On pace"
        return inputs
    }

    private static func checkLocalClauses(_ ok: inout Bool) {
        print("\n-- local clause list --")
        let clauses = MorningBriefingLocal.clauses(from: busyMorning())

        // Most-urgent first: the fleet decision leads, then the PR queue.
        check(clauses.first?.target == .fleet,
              "the fleet decision should lead, got \(clauses.first?.target.rawValue ?? "nothing")", &ok)

        let targets = clauses.map(\.target)
        for expected in [BriefingTarget.fleet, .review, .tasks, .githubSync, .quota] {
            check(targets.contains(expected), "no \(expected.rawValue) clause", &ok)
        }
        // Zero is not news: neither of these had anything to report.
        check(!targets.contains(.updates), "a zero tool-update count produced a clause", &ok)
        check(!targets.contains(.setup), "a zero setup-drift count produced a clause", &ok)

        guard let pr = clauses.first(where: { $0.target == .review }) else {
            check(false, "no PR clause to inspect", &ok); return
        }
        check(pr.text.contains("2 PRs"), "PR clause should name the real count, got \"\(pr.text)\"", &ok)
        guard let quota = clauses.first(where: { $0.target == .quota }) else {
            check(false, "no quota clause to inspect", &ok); return
        }
        check(quota.text.contains("40%"), "quota clause should name the real percentage, got \"\(quota.text)\"", &ok)
        check(quota.text.lowercased().contains("on pace"),
              "quota clause should carry the pace, got \"\(quota.text)\"", &ok)

        // The colour is the app's, derived from where the clause points - a
        // model reply cannot change it (see `BriefingTarget.tint`).
        check(BriefingTarget.review.tint == .good, "review clauses should read as good news", &ok)
        check(BriefingTarget.fleet.tint == .warn, "a fleet decision should read as needing attention", &ok)

        // An all-clear morning says one honest thing rather than nothing.
        var quiet = BriefingInputs()
        quiet.prReadyCount = 0
        quiet.forkDriftCount = 0
        quiet.toolUpdateCount = 0
        quiet.setupDriftCount = 0
        let quietClauses = MorningBriefingLocal.clauses(from: quiet)
        check(quietClauses.count == 1 && quietClauses[0].target == .none,
              "an all-clear morning should be one non-linked clause, got \(quietClauses.count)", &ok)

        // Setup not finished is the whole briefing, not one clause among five.
        var unconfigured = busyMorning()
        unconfigured.homeOk = false
        let unconfiguredClauses = MorningBriefingLocal.clauses(from: unconfigured)
        check(unconfiguredClauses.count == 1 && unconfiguredClauses[0].target == .setup,
              "an unconfigured home should be the whole briefing, got \(unconfiguredClauses.count) clauses", &ok)

        // Singular/plural, because a briefing reading "1 PRs" is the kind of
        // thing that makes the whole card look generated.
        var one = BriefingInputs()
        one.prReadyCount = 1
        one.forkDriftCount = 1
        one.toolUpdateCount = 1
        let oneClauses = MorningBriefingLocal.clauses(from: one)
        let joined = oneClauses.map(\.text).joined(separator: " | ")
        check(joined.contains("1 PR ready"), "singular PR wording, got \"\(joined)\"", &ok)
        check(joined.contains("1 fork behind"), "singular fork wording, got \"\(joined)\"", &ok)
        check(joined.contains("1 tool has an update"), "singular tool wording, got \"\(joined)\"", &ok)
        print("  OK - ordering, counts, plurals, all-clear and unconfigured states")
    }

    // MARK: 2 - unknown is not zero (GL-14's rule, one more signal)

    private static func checkUnknownIsNotZero(_ ok: inout Bool) {
        print("\n-- an unknown input must not read as an all-clear --")
        var unknown = BriefingInputs()
        unknown.prReadyCount = nil        // the forge could not be reached
        unknown.forkDriftCount = nil      // the poller has not run yet
        unknown.toolUpdateCount = nil
        unknown.setupDriftCount = nil
        unknown.quotaWeeklyPercentUsed = nil

        let clauses = MorningBriefingLocal.clauses(from: unknown)
        guard let pr = clauses.first(where: { $0.target == .review }) else {
            check(false, "an unreachable forge produced no PR clause at all - it reads as an all-clear", &ok)
            return
        }
        check(pr.text.lowercased().contains("unavailable"),
              "an unreachable forge should say so, got \"\(pr.text)\"", &ok)
        check(!pr.text.contains("0"), "an unreachable forge must never render as a count, got \"\(pr.text)\"", &ok)

        // A poller that has not run yet contributes nothing rather than a
        // confident zero - the clause is simply absent.
        check(!clauses.contains { $0.target == .githubSync },
              "an unchecked fork-drift count invented a clause", &ok)
        check(!clauses.contains { $0.target == .quota },
              "an unreadable quota invented a clause", &ok)

        // ...and a real zero is also silent, which is the other half of the
        // distinction being meaningful.
        var zero = unknown
        zero.forkDriftCount = 0
        check(!MorningBriefingLocal.clauses(from: zero).contains { $0.target == .githubSync },
              "a real zero fork-drift count produced a clause", &ok)
        print("  OK - unknown says unknown, zero says nothing, neither says the other")
    }

    // MARK: 3 - the plain stat line

    private static func checkStatLine(_ ok: inout Bool) {
        print("\n-- the degraded stat line --")
        let line = MorningBriefingLocal.statLine(from: busyMorning())
        check(line.contains("2 PRs ready to merge"), "stat line should name the PR count, got \"\(line)\"", &ok)
        check(line.contains("2 forks behind upstream"), "stat line should name the drift, got \"\(line)\"", &ok)
        check(line.contains("40%"), "stat line should name the quota, got \"\(line)\"", &ok)
        check(line.contains(" \u{00B7} "), "stat line should be middot-separated, got \"\(line)\"", &ok)
        check(!line.contains(" . "), "stat line should not carry sentence periods, got \"\(line)\"", &ok)
        // Built from the clauses, so the line and the links cannot drift apart.
        let clauseCount = MorningBriefingLocal.clauses(from: busyMorning()).count
        let segments = line.components(separatedBy: " \u{00B7} ").count
        check(segments == clauseCount,
              "stat line has \(segments) segments for \(clauseCount) clauses - they were built independently", &ok)
        print("  OK - \(line)")
    }

    // MARK: 4 - the subtitle only claims real sources

    private static func checkSources(_ ok: inout Bool) {
        print("\n-- the subtitle names only what contributed --")
        let full = busyMorning().contributingSources
        for expected in ["the fleet snapshot", "PR queue", "tasks", "drift", "quota"] {
            check(full.contains(expected), "a full briefing should name \(expected), got \(full)", &ok)
        }

        var bare = BriefingInputs()
        bare.prReadyCount = nil
        let sources = bare.contributingSources
        check(sources == ["the fleet snapshot"],
              "with nothing but the fleet available the subtitle should say so, got \(sources)", &ok)

        let record = MorningBriefing.record(inputs: busyMorning(),
                                            clauses: MorningBriefingLocal.clauses(from: busyMorning()),
                                            isDegraded: false, degradedReason: nil)
        let subtitle = MorningBriefing.subtitle(for: record)
        check(subtitle.hasPrefix("Generated "), "subtitle should lead with the time, got \"\(subtitle)\"", &ok)
        check(subtitle.contains("quota"), "subtitle should name quota when it contributed, got \"\(subtitle)\"", &ok)

        let bareRecord = MorningBriefing.record(inputs: bare, clauses: [], isDegraded: true, degradedReason: "x")
        check(!MorningBriefing.subtitle(for: bareRecord).contains("quota"),
              "the subtitle claimed quota as a source when there was no quota reading", &ok)
        print("  OK - \(subtitle)")
    }

    // MARK: 5 - the prompt carries derived state only

    private static func checkPromptCarriesOnlyDerivedState(_ ok: inout Bool) {
        print("\n-- the prompt is counts, not content --")
        let prompt = MorningBriefingAI.prompt(inputs: busyMorning())

        check(prompt.contains("pull requests ready to merge: 2"),
              "the prompt should hand over the exact PR count", &ok)
        check(prompt.contains("forks behind upstream: 2"),
              "the prompt should hand over the exact drift count", &ok)
        check(prompt.contains("40%"), "the prompt should hand over the exact quota reading", &ok)
        check(prompt.lowercased().contains("do not recompute"),
              "the prompt must forbid recomputing the counts it was given", &ok)

        // The link vocabulary has to be in the prompt, or the model has
        // nothing to choose from and every clause degrades to `.none`.
        for target in ["review", "tasks", "githubSync", "updates", "setup", "quota", "fleet"] {
            check(prompt.contains("\"\(target)\""), "the prompt should offer the \(target) link", &ok)
        }

        // An unknown input must reach the model as "unknown", never as 0 -
        // otherwise the prose asserts an all-clear the app never established.
        var unknown = busyMorning()
        unknown.prReadyCount = nil
        unknown.forkDriftCount = nil
        let unknownPrompt = MorningBriefingAI.prompt(inputs: unknown)
        check(unknownPrompt.contains("ready to merge: unknown"),
              "an unreachable forge should reach the model as unknown", &ok)
        check(unknownPrompt.contains("forks behind upstream: unknown"),
              "an unchecked drift count should reach the model as unknown", &ok)

        // `BriefingInputs` is counts and short titles by construction, so
        // there is no field a log line could travel in - assert the shape,
        // since that is the actual guarantee.
        check(!prompt.contains("BEGIN PROVIDED OUTPUT"),
              "the briefing prompt must never carry a captured-output block", &ok)
        print("  OK - exact counts, an explicit unknown, the link vocabulary, no output block")
    }

    // MARK: 6 - a reply cannot invent a destination or a colour

    private static func checkReplyValidation(_ ok: inout Bool) {
        print("\n-- reply validation --")

        switch MorningBriefingAI.parse(#"{"clauses":[{"text":"Two PRs are ready.","link":"review"}]}"#) {
        case .failure(let e): check(false, "a well-formed reply failed to parse: \(e.message)", &ok)
        case .success(let clauses):
            check(clauses.count == 1, "expected 1 clause, got \(clauses.count)", &ok)
            check(clauses.first?.target == .review, "the review link was lost", &ok)
        }

        // A fenced reply, which a model produces despite being told not to.
        let fenced = "```json\n{\"clauses\":[{\"text\":\"One task is blocked.\",\"link\":\"fleet\"}]}\n```"
        switch MorningBriefingAI.parse(fenced) {
        case .failure(let e): check(false, "a fenced reply failed to parse: \(e.message)", &ok)
        case .success(let clauses): check(clauses.first?.target == .fleet, "fenced reply lost its link", &ok)
        }

        // Prose either side of the object.
        let wrapped = "Here you go:\n{\"clauses\":[{\"text\":\"All quiet.\",\"link\":\"none\"}]}\nHope that helps."
        switch MorningBriefingAI.parse(wrapped) {
        case .failure(let e): check(false, "a prose-wrapped reply failed to parse: \(e.message)", &ok)
        case .success(let clauses): check(clauses.count == 1, "prose-wrapped reply lost its clause", &ok)
        }

        // The security property: an unrecognised destination becomes `.none`,
        // which renders as plain text rather than as a link that goes nowhere.
        switch MorningBriefingAI.parse(#"{"clauses":[{"text":"Go here.","link":"https://example.com/steal"}]}"#) {
        case .failure(let e): check(false, "an unknown link failed the whole reply: \(e.message)", &ok)
        case .success(let clauses):
            check(clauses.first?.target == BriefingTarget.none,
                  "an unrecognised link was not downgraded - it became \(clauses.first?.target.rawValue ?? "?")", &ok)
            check(clauses.first?.target.isLink == false, "an unrecognised link is still rendered as a link", &ok)
        }

        // A reply cannot pick a colour: there is no colour in `BriefingClause`
        // at all, and the tint comes from the target.
        switch MorningBriefingAI.parse(#"{"clauses":[{"text":"Quota is fine.","link":"quota","tint":"critical"}]}"#) {
        case .failure(let e): check(false, "a reply with an extra key failed: \(e.message)", &ok)
        case .success(let clauses):
            check(clauses.first?.target.tint == BriefingTarget.quota.tint,
                  "a reply managed to influence a clause's colour", &ok)
        }

        // Empty/blank clauses are dropped rather than rendered as gaps.
        switch MorningBriefingAI.parse(#"{"clauses":[{"text":"  ","link":"review"},{"text":"Real.","link":"review"}]}"#) {
        case .failure(let e): check(false, "a blank clause failed the reply: \(e.message)", &ok)
        case .success(let clauses): check(clauses.count == 1, "a blank clause was rendered, got \(clauses.count)", &ok)
        }

        // A runaway reply is capped, both in clause count and clause length.
        let many = (0..<40).map { #"{"text":"Clause \#($0).","link":"none"}"# }.joined(separator: ",")
        switch MorningBriefingAI.parse("{\"clauses\":[\(many)]}") {
        case .failure(let e): check(false, "a long reply failed: \(e.message)", &ok)
        case .success(let clauses):
            check(clauses.count == MorningBriefingAI.maxClauses,
                  "40 clauses were not capped to \(MorningBriefingAI.maxClauses), got \(clauses.count)", &ok)
        }
        let long = String(repeating: "x", count: 900)
        switch MorningBriefingAI.parse("{\"clauses\":[{\"text\":\"\(long)\",\"link\":\"none\"}]}") {
        case .failure(let e): check(false, "a long clause failed: \(e.message)", &ok)
        case .success(let clauses):
            let count = clauses.first?.text.count ?? 0
            check(count <= MorningBriefingAI.maxClauseLength + 1,
                  "a 900-character clause was not bounded, got \(count)", &ok)
        }

        // Malformed replies are failures, so the caller falls back to the
        // local clauses instead of rendering nothing.
        check(isFailure(MorningBriefingAI.parse("not json at all")), "non-JSON parsed as success", &ok)
        check(isFailure(MorningBriefingAI.parse(#"{"summary":"wrong schema"}"#)), "a reply with no clauses key parsed as success", &ok)
        check(isFailure(MorningBriefingAI.parse(#"{"clauses":[]}"#)), "an empty clause array parsed as success", &ok)
        print("  OK - fences, prose, unknown links, colour, blanks, caps, malformed")
    }

    // MARK: 7 - the once-per-day record

    private static func checkRecordAndDayKey(_ ok: inout Bool) {
        print("\n-- the day key and the record --")
        let key = MorningBriefing.dayKey(for: Date(timeIntervalSince1970: 1_760_000_000))
        check(key.count == 10 && key.contains("-"), "day key should be yyyy-MM-dd, got \"\(key)\"", &ok)
        check(MorningBriefing.dayKey(for: Date(timeIntervalSince1970: 1_760_000_000))
                == MorningBriefing.dayKey(for: Date(timeIntervalSince1970: 1_760_003_600)),
              "two moments an hour apart in the same day produced different keys", &ok)

        let inputs = busyMorning()
        let record = MorningBriefing.record(inputs: inputs,
                                            clauses: MorningBriefingLocal.clauses(from: inputs),
                                            isDegraded: false, degradedReason: nil)
        check(record.day == MorningBriefing.dayKey(), "a fresh record should be stamped today", &ok)
        check(!record.dismissed, "a fresh record should not start dismissed", &ok)
        check(record.shiftTaskID == "task-142",
              "the record should carry the app-resolved single due task, got \(record.shiftTaskID ?? "nil")", &ok)

        // Round-trips, which is what makes the card survive a relaunch inside
        // the same day instead of silently regenerating.
        guard let data = try? JSONEncoder().encode(record),
              let back = try? JSONDecoder().decode(MorningBriefingRecord.self, from: data) else {
            check(false, "the record did not round-trip through JSON", &ok); return
        }
        check(back.clauses == record.clauses, "clauses changed across a round trip", &ok)
        check(back.day == record.day, "the day stamp changed across a round trip", &ok)
        print("  OK - stable key, app-resolved task id, JSON round trip")
    }

    // MARK: 8 - the Shift half, against a real store

    private static func checkShiftDue(_ ok: inout Bool) {
        print("\n-- due tasks, from the real store --")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("briefing-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Never the captain's real Shift data, and never the git-synced clone.
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }

        let store = ShiftStore()
        let now = Date()
        let yesterday = day(offset: -1, from: now)
        let nextWeek = day(offset: 7, from: now)

        store.addTask(task(id: "overdue-1", title: "Rotate the bastion key", due: yesterday))
        store.addTask(task(id: "later-1", title: "Write the postmortem", due: nextWeek))
        store.addTask(task(id: "undated-1", title: "Read the runbook", due: nil))

        var due = MorningBriefing.shiftDue(store: store, now: now)
        check(due.tasks == 1, "expected 1 overdue task, got \(due.tasks)", &ok)
        check(due.followUps == 0, "expected no due follow-ups, got \(due.followUps)", &ok)
        check(due.singleTaskID == "overdue-1",
              "with exactly one due task the briefing should be able to open it, got \(due.singleTaskID ?? "nil")", &ok)

        // A second due task means there is no single record to open, so the
        // clause links to the destination instead of guessing between them.
        store.addTask(task(id: "overdue-2", title: "Chase the failing check", due: yesterday))
        due = MorningBriefing.shiftDue(store: store, now: now)
        check(due.tasks == 2, "expected 2 overdue tasks, got \(due.tasks)", &ok)
        check(due.singleTaskID == nil, "two due tasks should not resolve to one record", &ok)

        store.addFollowUp(ShiftFollowUp(
            id: "fu-1", title: "Check whether the deploy stuck", status: .pending,
            priority: .normal, followUpAt: yesterday, followUpTime: nil,
            relatedTaskID: nil, projectID: nil, notes: nil))
        due = MorningBriefing.shiftDue(store: store, now: now)
        check(due.followUps == 1, "expected 1 due follow-up, got \(due.followUps)", &ok)
        print("  OK - overdue counted, future and undated ignored, single-vs-many resolved")
    }

    // MARK: 9 - degradation (the whole point of the split)

    private static func checkDegradation(_ ok: inout Bool) {
        print("\n-- degradation --")
        let inputs = busyMorning()
        let localClauses = MorningBriefingLocal.clauses(from: inputs)

        defer { MorningBriefingAI.claudePathOverrideForTests = nil }

        // (a) a `claude` that cannot be launched at all - the offline/not-
        //     installed shape, through the real runner. It must report a
        //     failure promptly rather than hanging or trapping.
        MorningBriefingAI.claudePathOverrideForTests = "/nonexistent/claude-that-is-not-here"
        let unlaunchable = generateSync(inputs: inputs)
        check(unlaunchable?.isFailure == true,
              "an unlaunchable claude should report a failure, got \(String(describing: unlaunchable))", &ok)

        // (b) a `claude` that fails: the real `ClaudeOneShot` path, a real
        //     process, a real failure - and a briefing still comes out of it.
        let failing = writeFakeClaude(rawOutput: "boom\n", exitCode: 1)
        defer { try? FileManager.default.removeItem(at: failing) }
        MorningBriefingAI.claudePathOverrideForTests = failing.path
        let failed = generateSync(inputs: inputs)
        check(failed?.isFailure == true, "a failing claude should report a failure, got \(String(describing: failed))", &ok)

        let degraded = MorningBriefing.record(inputs: inputs, clauses: localClauses,
                                              isDegraded: true, degradedReason: "claude exited 1")
        check(degraded.isDegraded, "the fallback record should be flagged degraded", &ok)
        check(!degraded.clauses.isEmpty, "the fallback record has no clauses - the card would be blank", &ok)
        check(degraded.degradedReason != nil, "a degraded record should say why", &ok)
        check(degraded.clauses.contains { $0.target == .review },
              "the fallback lost its deep links", &ok)

        // (c) a `claude` that answers: same real path, a real success.
        let payload = #"{"clauses":[{"text":"2 PRs went green overnight.","link":"review"},{"text":"Fork drift on 2 repos.","link":"githubSync"}]}"#
        let envelope = "{\"result\":\(jsonString(payload)),\"session_id\":\"s1\"}"
        let working = writeFakeClaude(rawOutput: envelope + "\n", exitCode: 0)
        defer { try? FileManager.default.removeItem(at: working) }
        MorningBriefingAI.claudePathOverrideForTests = working.path
        switch generateSync(inputs: inputs) {
        case .some(.success(let clauses)):
            check(clauses.count == 2, "expected 2 clauses from the fake reply, got \(clauses.count)", &ok)
            check(clauses.first?.target == .review, "the first clause lost its review link", &ok)
            check(clauses.last?.target == .githubSync, "the second clause lost its githubSync link", &ok)
        case .some(.failure(let e)):
            check(false, "a well-formed fake reply failed end to end: \(e.message)", &ok)
        case nil:
            check(false, "the generate call never completed", &ok)
        }

        print("  OK - unlaunchable, failing, and answering all still produce a briefing")
    }

    // MARK: 10 - the card actually renders what it was given

    /// No `NSWindow` and no `app.run()` - just a real card in a real sized
    /// container, laid out for real. This exists specifically to catch a
    /// silently zero-height paragraph: `BriefingParagraphView` drives its own
    /// height from `NSLayoutManager.usedRect` inside `layout()`, and a
    /// briefing that renders as an invisible 0pt strip would look exactly like
    /// "the feature didn't run" while every logic check above still passed.
    private static func checkCardRendering(_ ok: inout Bool) {
        print("\n-- the card renders --")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 400))
        let card = MorningBriefingCard()
        container.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            card.topAnchor.constraint(equalTo: container.topAnchor),
        ])

        let inputs = busyMorning()
        let record = MorningBriefing.record(inputs: inputs,
                                           clauses: MorningBriefingLocal.clauses(from: inputs),
                                           isDegraded: false, degradedReason: nil)
        card.render(record, theme: ThemeManager.shared.theme)
        container.layoutSubtreeIfNeeded()

        check(card.debugParagraph.debugMeasuredHeight > BriefingParagraphView.unmeasuredHeight + 10,
              "the briefing paragraph measured \(card.debugParagraph.debugMeasuredHeight)pt - an invisible briefing", &ok)
        check(card.frame.height > 40, "the card measured \(card.frame.height)pt tall", &ok)
        check(card.debugSubtitle.hasPrefix("Generated "),
              "the card's subtitle should name when and from what, got \"\(card.debugSubtitle)\"", &ok)
        check(!card.debugFootnoteVisible,
              "an AI briefing should not carry the degraded footnote", &ok)
        check(card.debugParagraph.debugLinkedCharacterCount > 0,
              "no clause was rendered as a link", &ok)

        // Degraded: the footnote appears and says why.
        let degraded = MorningBriefing.record(inputs: inputs,
                                              clauses: MorningBriefingLocal.clauses(from: inputs),
                                              isDegraded: true, degradedReason: "claude exited 1")
        card.render(degraded, theme: ThemeManager.shared.theme)
        container.layoutSubtreeIfNeeded()
        check(card.debugFootnoteVisible, "a degraded briefing should show the footnote", &ok)
        check(card.debugFootnote.contains("claude exited 1"),
              "the footnote should name the real reason, got \"\(card.debugFootnote)\"", &ok)
        // The acceptance criterion, pinned against what is actually on screen:
        // a degraded card reads as exactly the plain stat line.
        check(card.debugParagraph.debugPlainText == MorningBriefingLocal.statLine(from: inputs),
              "a degraded card should read as the stat line.\n    rendered: \(card.debugParagraph.debugPlainText)\n    statLine: \(MorningBriefingLocal.statLine(from: inputs))", &ok)

        // A briefing made only of `.none` clauses carries no link range at
        // all - a link that navigates nowhere is the thing being avoided.
        var quiet = BriefingInputs()
        quiet.prReadyCount = 0
        let quietRecord = MorningBriefing.record(inputs: quiet,
                                                clauses: MorningBriefingLocal.clauses(from: quiet),
                                                isDegraded: true, degradedReason: "no claude")
        card.render(quietRecord, theme: ThemeManager.shared.theme)
        container.layoutSubtreeIfNeeded()
        check(card.debugParagraph.debugLinkedCharacterCount == 0,
              "an all-clear briefing rendered a link that goes nowhere", &ok)

        // Refresh and dismiss both reach their handler exactly once.
        var refreshed = 0, dismissed = 0
        card.onRefresh = { refreshed += 1 }
        card.onDismiss = { dismissed += 1 }
        card.debugPressRefresh()
        card.debugPressDismiss()
        check(refreshed == 1, "the refresh affordance fired \(refreshed) times", &ok)
        check(dismissed == 1, "the dismiss affordance fired \(dismissed) times", &ok)

        // A clause click reaches the deep-link handler with the right target.
        card.render(record, theme: ThemeManager.shared.theme)
        container.layoutSubtreeIfNeeded()
        var activated: [BriefingTarget] = []
        card.onActivate = { activated.append($0) }
        let clauses = record.clauses
        if let reviewIndex = clauses.firstIndex(where: { $0.target == .review }) {
            check(card.debugParagraph.debugActivate(clauseIndex: reviewIndex),
                  "clicking the PR clause was not handled", &ok)
            check(activated == [.review],
                  "clicking the PR clause reported \(activated)", &ok)
        } else {
            check(false, "no PR clause to click", &ok)
        }
        print("  OK - real height, subtitle, footnote only when degraded, links only where real, both affordances")
    }

    // MARK: - Helpers

    private static func generateSync(inputs: BriefingInputs) -> Result<[BriefingClause], MorningBriefingAIError>? {
        var outcome: Result<[BriefingClause], MorningBriefingAIError>?
        MorningBriefingAI.generate(inputs: inputs) { outcome = $0 }
        // See `DictationCleanupSelfTest.runRewriteSync`'s note: this runs on
        // the main thread before `app.run()`, so a semaphore would deadlock on
        // the very block it is waiting for. Pump the run loop instead.
        let deadline = Date().addingTimeInterval(20)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return outcome
    }

    /// A fake `claude`: prints one canned line and exits, ignoring its real
    /// arguments - the same harness `DictationCleanupSelfTest` uses, so the
    /// whole `ClaudeOneShot` path (argv, `/dev/null` stdin, both pipes, the
    /// envelope parse) runs for real with no network and no Claude auth.
    private static func writeFakeClaude(rawOutput: String, exitCode: Int32) -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-briefing-\(UUID().uuidString).sh")
        let escaped = rawOutput.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\nprintf '%s' '\(escaped)'\nexit \(exitCode)\n"
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private static func jsonString(_ raw: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [raw], options: [])
        guard let data, let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        // `["..."]` -> `"..."`
        return String(text.dropFirst().dropLast())
    }

    private static func task(id: String, title: String, due: String?) -> ShiftTask {
        ShiftTask(id: id, title: title, description: "", status: .todo, priority: .normal,
                  dueDate: due, dueTime: nil, projectID: nil, tags: [],
                  createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                  completedAt: nil, notes: nil, subtasks: [], hasAttachment: false)
    }

    private static func day(offset: Int, from date: Date) -> String {
        let shifted = Calendar.current.date(byAdding: .day, value: offset, to: date) ?? date
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: shifted)
    }

    private static func isFailure(_ result: Result<[BriefingClause], MorningBriefingAIError>) -> Bool {
        if case .failure = result { return true }
        return false
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("  FAIL: \(message)")
            ok = false
        }
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

#endif
