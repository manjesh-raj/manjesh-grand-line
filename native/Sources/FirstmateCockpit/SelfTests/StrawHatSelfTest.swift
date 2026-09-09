// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates, the pure-logic half (phase 1's M1.5, extended by phase
// 2's M2.1-M2.3).
//
// Split from `StrawHatViewSelfTest` on the convention `WhiteboardSelfTest` /
// `WhiteboardViewSelfTest` and `FleetActionsSelfTest` /
// `FleetReplyLayoutSelfTest` already follow: this one builds no `NSWindow`
// and therefore runs in CI's blocking job; the view half mounts a real
// `FleetController` and lives in `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// What is asserted here, and why each one:
//
//  - **The persona's actual contents.** Two of its clauses are the feature's
//    only safety property in phase 1 - "you have no tools" and "never claim
//    you added anything". A prompt is not testable for what a model *does*
//    with it, but it is absolutely testable for whether the instruction is
//    still in the box, and a refactor that drops it looks like nothing.
//  - **`--resume` really threads.** Not "the runner stored a session id" -
//    the *argv the second turn actually ran with*, recorded by the fake
//    `claude` itself. A session id kept in a property and never passed is
//    exactly the bug that would make this a series of unrelated questions
//    while every in-process assertion still passed.
//  - **A stale session recovers without losing the thread** (M1.2's own
//    acceptance criterion), and recovers *with the recap* rather than by
//    silently dropping the conversation.
//  - **The lock gate.** `AppLockedSurface.strawHatChat`, which cannot be
//    observed any other way: a locked app must not spawn a `claude` turn.
//
// Phase 2 adds, one case per milestone:
//
//  - **Each of the three parser rungs, separately** (M2.1). Not "the parser
//    works" - each rung asserts the thing that rung exists *for*: rung 1 that
//    a validated envelope becomes attributed sections and confirm-able
//    proposals, rung 2 that an unknown speaker or kind still *renders* and
//    still never *executes*, rung 3 that a prose reply containing braces is
//    not shredded in the attempt to salvage one.
//  - **The closed proposal vocabulary** (M2.2), asserted as a literal list,
//    so a kind added without a matching executor branch fails here.
//  - **The confirm-only guarantee**, asserted by counting store contents
//    before and after *parsing* - the property the whole feature rests on,
//    and one no amount of prose in a header can prove.
//  - **The context snapshot** (M2.3), including GL-14's rule: an unreported
//    health registry must read as a stated gap, never as a clean bill of
//    health.
//
// Every `claude` here is a disposable shell script - the real CLI is never
// invoked, so there is no network call, no Claude auth and no quota spend.
//
// Run: `swift build && FM_RUN_STRAW_HAT_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum StrawHatSelfTest {

    static func run() -> Bool {
        var ok = true
        // The gate starts locked, because the app does. Every case below that
        // is not specifically testing the gate needs it open, and it is put
        // back the way it was found - `AppLockGate.shared` is process-wide
        // state and a suite that leaves it flipped poisons whatever runs next
        // in the same process.
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        checkPersona(&ok)

        checkVoice(&ok)
        checkRoster(&ok)
        checkProposalVocabulary(&ok)
        checkRung1ValidatedEnvelope(&ok)
        checkRung2PartialSalvage(&ok)
        checkRung3PlainText(&ok)
        checkToolNarrationSuppression(&ok)
        checkEnvelopeCaps(&ok)
        checkDueResolution(&ok)
        checkContextSnapshot(&ok)
        checkTurnEnvelope(&ok)
        checkProposalExecution(&ok)
        checkPhase3Parsing(&ok)
        checkPhase3Execution(&ok)
        checkCommandDraftGate(&ok)
        checkEditorRoutingCommandGate(&ok)
        checkRecapPrompt(&ok)
        checkLockGate(&ok)
        checkSingleTurn(&ok)
        checkResumeThreading(&ok)
        checkStaleSessionRecovery(&ok)
        checkFailuresAreReported(&ok)
        checkQuitCancelsAnInFlightTurn(&ok)

        print(ok ? "StrawHatSelfTest: all checks passed" : "StrawHatSelfTest: FAILED")
        return ok
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("  FAIL: \(message)")
            ok = false
        }
    }

    // MARK: The persona

    private static func checkPersona(_ ok: inout Bool) {
        let persona = StrawHatCrew.persona.lowercased()

        // Honesty rule 1: the crew cannot change anything themselves.
        //
        // Phase 1 asserted the literal words "no tools", which phase 2 has
        // outgrown - the crew now genuinely has *facts* (a bounded snapshot),
        // just not tools or write access. So the assertion moved to the clause
        // that still carries the whole property rather than being deleted with
        // the wording it happened to be written against.
        check(persona.contains("you cannot change anything in the app or on the machine"),
              "the persona must still say the crew cannot change anything itself", &ok)
        check(persona.contains("never say \"added\", \"saved\", \"created\", \"scheduled\", or \"done\" about a proposal"),
              "the persona must still forbid past-tense language about a proposal", &ok)
        // Honesty rule 3, unchanged from phase 1.
        check(persona.contains("never invent the contents"),
              "persona must still forbid inventing store contents", &ok)

        // The crew that is NOT aboard still has to be named as absent, or the
        // model answers as a colleague the parser will refuse.
        check(persona.contains("not aboard yet"),
              "persona must say the rest of the crew is not aboard yet", &ok)

        // The reply discipline SRE Lead already had to be corrected into once.
        // Both survive the voice pass below - character is meant to make a
        // short answer sound like someone, not to make it longer.
        check(persona.contains("lead with the answer"),
              "persona must still ask for answer-first replies", &ok)
        check(persona.contains("terse"),
              "persona must still ask for terse replies", &ok)

        // Phase 2's reply format IS the envelope, so the phase-1 assertions
        // that this must NOT mention JSON or confirm cards are inverted here
        // rather than deleted: they encoded phase 1 as the expected behaviour
        // (the same shape audit #2 §4.5 found in `SessionRestoreSelfTest` and
        // §1's own `checkSettingsTwoColumnLayout`), and phase 2's whole
        // contract is that the persona describes what `StrawHatEnvelope.parse`
        // reads.
        check(persona.contains("json"),
              "the persona must ask for a fenced json block - `StrawHatEnvelope` parses nothing else", &ok)
        check(persona.contains("sections"),
              "the persona must name the `sections` array the parser looks for", &ok)
        check(persona.contains("confirm"),
              "the persona must tell the crew a proposal is confirmed by the captain, not by them", &ok)

        // A write is a proposal, never a claim - the single worst failure this
        // feature can have, and the half of the defence a prompt owns.
        check(persona.contains("never write prose claiming a write has happened"),
              "the persona must forbid claiming a write happened", &ok)
        check(persona.contains("nothing you propose happens until they press it"),
              "the persona must say the captain's press is what writes", &ok)

        // The wire contract with the parser: every kind and every speaker id
        // the app accepts has to actually be named, or the model is being
        // asked to guess at a vocabulary that is then silently refused.
        for kind in StrawHatProposalKind.allCases {
            check(StrawHatCrew.persona.contains(kind.rawValue),
                  "the persona must name the \"\(kind.rawValue)\" proposal kind it is allowed to use", &ok)
        }
        for member in StrawHatMember.allCases {
            check(StrawHatCrew.persona.contains("\"\(member.rawValue)\""),
                  "the persona must name \(member.displayName)'s speaker id \"\(member.rawValue)\"", &ok)
        }

        // Phase 3's own additions to the same wire contract. The loops above
        // already assert every `StrawHatProposalKind` and every
        // `StrawHatMember` is named, which covers the eight kinds and seven
        // voices generically - these are the clauses a model cannot infer
        // from a name alone.
        //
        // The two closed sets a `kind` alone does not describe. A model that
        // is not told these lists writes a plausible action or destination,
        // the parser refuses it, and the captain sees a turn where a crew
        // member offered nothing for no visible reason.
        for action in ScheduledActionKind.allCases {
            check(StrawHatCrew.persona.contains(action.rawValue),
                  "the persona must name the \"\(action.rawValue)\" schedule action - the parser accepts only these", &ok)
        }
        for dest in StrawHatHandoff.allowedDestinations {
            check(StrawHatCrew.persona.contains(dest.rawValue),
                  "the persona must name \"\(dest.rawValue)\" as a handoff destination", &ok)
        }
        // The cadence grammar, which is strict and refuses anything else.
        check(StrawHatCrew.persona.contains("daily HH:MM")
                && StrawHatCrew.persona.contains("weekly <weekday> HH:MM"),
              "the persona must state both cadence shapes verbatim - the parser accepts no others", &ok)

        // M3.2: a handoff is a link, and describing one as a save is the
        // write/handoff split's own version of the "never claim a write
        // happened" rule.
        check(persona.contains("links, not writes"),
              "the persona must say the two handoffs are links rather than writes", &ok)

        // Zoro's whole scope is what he *cannot* do, so the persona has to say
        // it: an execution voice that thinks it can run a command produces the
        // one failure mode this feature cannot have.
        check(persona.contains("zoro drafts rather than runs"),
              "the persona must say Zoro drafts rather than runs", &ok)
        check(persona.contains("never say a command was run"),
              "the persona must forbid claiming a command ran", &ok)
        // The host hint is a name the *captain* used, never something looked
        // up - the crew cannot see hosts at all.
        check(persona.contains("if they never named one, leave it out rather than guessing"),
              "the persona must forbid guessing a host name", &ok)

        // A model-supplied risk level would be a vouch nobody made (audit #2
        // section 5.3, one store over).
        check(persona.contains("never state a risk level"),
              "the persona must forbid stating a command's risk level", &ok)

        // The three the plan does NOT give a v1 seat. Naming them as absent is
        // what stops a reply answering as a colleague the parser will refuse -
        // and Sanji's role is an open captain decision, so a persona clause
        // about the Morning Briefing would be inferring one.
        for absent in ["brook", "jinbe", "sanji"] {
            check(!persona.contains("\"\(absent)\""),
                  "\(absent) has no speaker id - the parser would refuse it", &ok)
        }
        check(!persona.contains("morning briefing"),
              "Sanji's role is an open captain decision - the persona must not infer one", &ok)

        // The bounded-context honesty rule (#2 in this file's header): the
        // crew sees a capped slice, so most things are still genuinely unknown.
        check(persona.contains("bounded"),
              "the persona must say the context snapshot is bounded", &ok)
        // Against the raw persona, not the lowercased copy - the label the
        // envelope actually emits is upper-case, and matching it in lower case
        // would pass for a persona that named a block that does not exist.
        check(StrawHatCrew.persona.contains("[CONTEXT"),
              "the persona must name the [CONTEXT] block so it is not answered directly", &ok)
        check(persona.contains("unavailable:"),
              "the persona must know what an `unavailable:` line means - GL-14, unknown is not empty", &ok)

        // `fm/straw-hat-voice-order-composer-polish-8dd2`: the captain's
        // screenshot caught a bare, unattributed message reading "Context
        // already says tasks_due_soon: 0, no need for a tool call." - the
        // model narrating whether to call a phase 2.5 tool, instead of only
        // emitting the envelope. Both places the persona says so are
        // asserted, plus the exact leaked phrasing named as a concrete
        // forbidden example (the same convention as "stuck it on the board"
        // above and "adjusts straw hat" below) - a vaguer instruction that
        // happens to avoid these particular words would still pass every
        // other check here while leaving the actual failure mode open.
        check(persona.contains("deciding whether to call a tool, which one, or why you skipped one is never part of the reply"),
              "the persona must forbid narrating a tool-use decision in the reply-format section", &ok)
        check(persona.contains("tasks_due_soon: 0, so no tool call needed"),
              "...with the captain's own leaked phrase named as a concrete forbidden example", &ok)
        check(persona.contains("whichever way you decide - to call a tool, or not - stays invisible"),
              "the persona must repeat the same rule where the four tools are actually described", &ok)
    }

    /// Each crew member's own manner of speaking, and the clamp that keeps it
    /// from touching what a reply *claims*.
    ///
    /// `fm/polish-straw-hat-overview-card-and-voice-c8d3` is the captain's own
    /// override of a clause this persona used to carry verbatim: "you are not
    /// mascots ... never more than a light touch of character". He read a real
    /// reply ("Hey - all quiet right now. No tasks due soon...") and said it
    /// sounded like a generic assistant - he wants Luffy to sound like Luffy
    /// and Zoro to sound like Zoro. So the old clamp is asserted **gone**
    /// rather than being deleted quietly, and each voice is asserted present
    /// by name.
    ///
    /// Why a literal table rather than something derived from the enum: a
    /// test that reads the same source it is checking asserts nothing (the
    /// reasoning `DaylightModuleSelfTest.lockedMembership` states for its own
    /// tables). These hooks are the distinctive bits of each character's
    /// speech, so flattening one member's voice back to a role description
    /// fails by that member's name instead of silently passing.
    private static let voiceHooks: [StrawHatMember: [String]] = [
        .luffy: ["short, blunt, cheerful", "cool", "a verdict first"],
        .nami: ["bossy", "overdue, by the way", "interest", "for once"],
        .robin: ["calm, precise", "morbid", "fufufu", "her own dry framing"],
        .chopper: ["easily rattled", "flustered", "doctor", "n-nobody"],
        .zoro: ["terse to the point of rudeness", "fragments", "no idea where he is", "stays a fragment"],
        .usopp: ["boastful", "captain usopp", "8,000 followers", "exaggerated flourish"],
        .franky: ["super", "shipwright", "even when the answer is a small one"],
    ]

    private static func checkVoice(_ ok: inout Bool) {
        let persona = StrawHatCrew.persona.lowercased()

        // The captain's override, stated as an absence. Left in, this clause
        // actively argues against everything below it.
        check(!persona.contains("light touch of character"),
              "the captain overrode the \"light touch of character\" clamp - it must not be back", &ok)
        check(!persona.contains("you are not mascots"),
              "...and so must the \"not mascots\" clause it sat in", &ok)

        // Every member has real voice guidance, not just a job description.
        for member in StrawHatMember.allCases {
            guard let hooks = voiceHooks[member] else {
                check(false, "\(member.displayName) has no voice hooks listed in this suite", &ok)
                continue
            }
            for hook in hooks {
                check(persona.contains(hook.lowercased()),
                      "\(member.displayName)'s voice must still say \"\(hook)\"", &ok)
            }
        }
        // One "Voice:" line per member, so a voice added to the table above
        // without one in the persona - or an eighth member with none - fails
        // rather than passing on the hooks alone.
        let voiceLines = StrawHatCrew.persona.components(separatedBy: "Voice:").count - 1
        check(voiceLines == StrawHatMember.allCases.count,
              "one Voice: line per crew member - expected \(StrawHatMember.allCases.count), found \(voiceLines)", &ok)

        // **The load-bearing half.** Voice is a tone layer; a charismatic line
        // that implies a write already happened is the single worst failure
        // this feature can have, and the honesty rules above are what stop it.
        // This asserts the persona says so *inside* the voice section, where a
        // model reading for tone will actually see it.
        check(persona.contains("voice is tone"),
              "the persona must say voice is tone and never content", &ok)
        check(persona.contains("it never changes what the sentence claims"),
              "...spelled out, not just as a heading", &ok)
        check(persona.contains("accuracy wins"),
              "the persona must say accuracy wins when flavour and accuracy conflict", &ok)
        // Each per-character clamp: the failure mode that character's own
        // voice makes most likely. Usopp brags, so his is about bragging;
        // Chopper frets, so his is about inventing something to fret about.
        for clamp in ["he may not brag about the captain's task list",
                      "he may not be casual about whether something was saved",
                      "he may not invent one to fret about",
                      "he may not say it is running",
                      "she may not fill the gap",
                      "he may not be certain about a machine he cannot see"] {
            check(persona.contains(clamp),
                  "the persona must keep the voice clamp \"\(clamp)\"", &ok)
        }

        // The good half of the old clause, kept: a crew member speaks, it does
        // not narrate its own gestures.
        // A real multi-turn `claude -p` run against the rewritten voices
        // produced "Got it stuck to the board" (Usopp) and "I've written one
        // from scratch" (Robin) - both past-tense claims about a record that
        // did not exist yet, and both sailing straight past the five-word
        // list because neither uses one of the five words. The rule is the
        // claim, not the vocabulary, and voice is what makes a colourful past
        // tense tempting - so this clause lives in the persona and is
        // asserted here.
        check(persona.contains("what is forbidden is the claim, not five particular words"),
              "the persona must forbid the claim rather than only the five words", &ok)
        check(persona.contains("stuck it on the board"),
              "...with the real examples that got past the word list", &ok)
        check(persona.contains("would still be true if the captain shut the app"),
              "...and the test a crew member can actually apply to its own line", &ok)
        check(persona.contains("the commonest way voice breaks honesty is tense"),
              "the voice section must name tense as the way character breaks honesty", &ok)

        check(persona.contains("no stage directions"),
              "the persona must still forbid stage directions", &ok)
        check(persona.contains("adjusts straw hat"),
              "...with the example that made it concrete", &ok)

        // A stale count in the format section sends the model looking for a
        // roster that no longer exists. It said "four" through all of phase 3.
        check(!persona.contains("one of the four ids above"),
              "the reply-format section must not still say there are four speaker ids", &ok)
        check(persona.contains("one of the seven ids above"),
              "...it names the real roster size", &ok)

        // `fm/straw-hat-voice-order-composer-polish-8dd2`: the captain's
        // first-real-use complaint - a live reply reading "like a competent
        // generic assistant, not Nami" on a mundane, nothing-to-report turn,
        // which is exactly the case terseness makes hardest to keep in
        // character. Two clauses close that gap: the voice section names a
        // boring answer as the real test of voice rather than an exemption
        // from it, and the "keep it short" section says terse and neutral are
        // not the same property, so cutting a reply down must never mean
        // cutting the character out of it.
        check(persona.contains("the real test of this, not an exemption from it"),
              "the persona must say a boring answer is the test of voice, not an exemption from it", &ok)
        check(persona.contains("terse and neutral are not the same thing"),
              "the persona must say terseness is not licence to go flat", &ok)
    }

    private static func checkRoster(_ ok: inout Bool) {
        // Phase 3's full v1 roster. Asserted as a literal ordered list rather
        // than a count, so an eighth voice - or Sanji arriving on a role
        // nobody has decided - fails by name.
        check(StrawHatMember.allCases.map(\.rawValue)
                == ["luffy", "nami", "chopper", "robin", "zoro", "usopp", "franky"],
              "phase 3 ships the plan's seven v1 voices, got \(StrawHatMember.allCases.map(\.rawValue))", &ok)
        check(StrawHatCrew.speaker == .luffy, "the fallback speaker is Luffy - he owns the conversation", &ok)

        // `NSImage(systemSymbolName:)` returns nil silently, and this app has
        // shipped an invisible icon that way before (the Hosts list's
        // "anchor", which is not an SF Symbol at all). These are the fallback
        // glyphs for a portrait that fails to decode, so an unresolvable one
        // would turn a bad payload into a blank tile.
        for member in StrawHatMember.allCases {
            check(NSImage(systemSymbolName: member.symbol, accessibilityDescription: nil) != nil,
                  "\(member.displayName)'s SF Symbol \"\(member.symbol)\" resolves", &ok)
        }

        // M2.4: the portraits themselves. A nil payload degrades to the glyph
        // above rather than to a hole, so this cannot be caught by a build.
        for member in StrawHatMember.allCases {
            guard let portrait = StrawHatPortraits.image(for: member) else {
                check(false, "\(member.displayName)'s portrait failed to decode", &ok)
                continue
            }
            check(portrait.size.width == StrawHatPortraits.side
                    && portrait.size.height == StrawHatPortraits.side,
                  "\(member.displayName)'s portrait is \(StrawHatPortraits.side)pt square, got \(portrait.size)", &ok)
        }

        // The Jolly Roger, the captain's own ask for the Overview card. Same
        // reasoning as the portraits above: `NSImage(data:)` returns nil on a
        // corrupt payload, every call site degrades to the SF Symbol, so a
        // bad regeneration is invisible to a build and nearly invisible on
        // screen.
        if let flag = StrawHatFlag.image {
            check(flag.size.width == StrawHatFlag.side && flag.size.height == StrawHatFlag.side,
                  "the Jolly Roger is \(StrawHatFlag.side)pt square, got \(flag.size)", &ok)
            // `isTemplate` would draw it as a tintable mask, flattening the
            // straw hat's tan and red and the skull's greys into one colour -
            // i.e. throwing away the whole reason it is a raster asset.
            check(!flag.isTemplate,
                  "the Jolly Roger must not be a template image - it would render as one flat colour", &ok)
        } else {
            check(false, "the Jolly Roger payload failed to decode", &ok)
        }
        // Its fallback glyph has to resolve for the same reason every other
        // one here does.
        check(NSImage(systemSymbolName: RailDestination.strawHat.symbol, accessibilityDescription: nil) != nil,
              "the crew destination's fallback symbol \"\(RailDestination.strawHat.symbol)\" resolves", &ok)
        check(DaylightModule.strawHat.symbol == RailDestination.strawHat.symbol,
              "the card and the page it opens agree on their fallback glyph", &ok)

        // A crew member's colour is an identity, so `.critical` - the app's
        // "something is wrong" hue - is not available to it. AGENTS.md records
        // this trap on Dictation's history rows: a semantic tint on a benign
        // row paints an alert bar on something that is not an alert.
        for member in StrawHatMember.allCases {
            check(member.tint != .critical,
                  "\(member.displayName)'s tint must not be `.critical` - it would read as an alert", &ok)
        }
        // The whole mapping, as a literal table.
        //
        // Phase 2 asserted only that every tint was *distinct*, which phase 3
        // makes impossible: `HelmTint` has seven cases, `.critical` is
        // unavailable to an identity for the reason above, and the roster is
        // seven voices - so six hues cover seven members and exactly one pair
        // shares. That is a decision (see `StrawHatMember.tint`'s own doc
        // comment for which pair and why), so it is asserted the way
        // `DaylightModuleSelfTest.checkSpaceTable` asserts its own locked
        // table: as data, restated here rather than derived from the enum,
        // because a check that reads the table it is checking asserts nothing.
        let expectedTints: [StrawHatMember: HelmTint] = [
            .luffy: .accent, .nami: .warn, .chopper: .good, .robin: .info,
            .zoro: .violet, .usopp: .neutral, .franky: .neutral,
        ]
        for member in StrawHatMember.allCases {
            check("\(member.tint)" == "\(expectedTints[member].map { "\($0)" } ?? "?")",
                  "\(member.displayName)'s tint is \(expectedTints[member].map { "\($0)" } ?? "unmapped"), got \(member.tint)", &ok)
        }
        // ...and the differentiation must not erode further: one shared pair
        // is the documented cost of a seven-member roster, two would mean
        // M2.4's per-crew colour had quietly stopped buying anything.
        let tints = StrawHatMember.allCases.map { "\($0.tint)" }
        check(Set(tints).count >= StrawHatMember.allCases.count - 1,
              "at most one pair of crew members may share a tint, got \(tints)", &ok)

        // The bar/ring colour, not the raw tint - and the difference is a
        // real render finding rather than a nicety.
        //
        // `HelmTint.neutral` resolves to `chromeInkHex`, the theme's
        // *full-strength* ink, which on a dark palette is the
        // highest-contrast colour there is. A real off-screen render of the
        // real page showed Franky's 3pt bar visibly brighter than Zoro's
        // magenta one - so the two voices that deliberately carry no identity
        // hue were rendering as the loudest on the page. `accentColor(in:)`
        // is the fix, and this is what stops it being reverted to
        // `tint.hex(in:)` by a later tidy-up.
        for theme in HelmTheme.allThemes {
            let muted = HelmTheme.mutedInk(theme)
            for member in StrawHatMember.allCases {
                let resolved = member.accentColor(in: theme)
                if member.tint == .neutral {
                    check(resolved == muted,
                          "\(member.displayName)'s bar must be muted ink in \(theme.id), not full-strength ink", &ok)
                } else {
                    check(resolved != muted,
                          "\(member.displayName) carries a real hue, so their bar must not be muted ink in \(theme.id)", &ok)
                }
            }
        }

        // Read-only by design: no store write is mapped to Chopper, and giving
        // him one would mean inventing a capability.
        check(StrawHatMember.chopper.proposalKinds.isEmpty,
              "Chopper is read-only in phase 2 - he must have no proposal kinds", &ok)
        check(StrawHatMember.luffy.proposalKinds.isEmpty,
              "Luffy orchestrates and proposes nothing himself", &ok)
        check(StrawHatMember.nami.proposalKinds.contains(.addTask)
                && StrawHatMember.nami.proposalKinds.contains(.addFollowUp),
              "Nami owns tasks and follow-ups", &ok)
        check(StrawHatMember.robin.proposalKinds == [.createRunbookDraft],
              "Robin owns runbook drafts", &ok)

        // Phase 3's three, and the two handoffs' owners.
        check(StrawHatMember.zoro.proposalKinds.contains(.saveCommandDraft),
              "Zoro owns command drafts", &ok)
        check(StrawHatMember.zoro.proposalKinds.contains(.openSRELead),
              "...and the SRE Lead handoff - his scope is defined by needing it", &ok)
        check(StrawHatMember.usopp.proposalKinds.contains(.addSticky),
              "Usopp owns sticky notes", &ok)
        check(StrawHatMember.usopp.proposalKinds.contains(.openDestination),
              "...and a destination handoff, which is the plan's \"draw it out\" into the Whiteboard", &ok)
        check(StrawHatMember.franky.proposalKinds == [.createScheduleDraft],
              "Franky is thin by design - one kind, schedule drafts", &ok)

        // Every kind has to be *briefed* to someone, or a vocabulary the
        // parser accepts is one no voice was ever told about.
        let briefed = Set(StrawHatMember.allCases.flatMap(\.proposalKinds))
        for kind in StrawHatProposalKind.allCases {
            check(briefed.contains(kind),
                  "no crew member is briefed on \"\(kind.rawValue)\" - the parser would accept a kind nobody offers", &ok)
        }
    }

    // MARK: M2.2 - the closed proposal vocabulary

    private static func checkProposalVocabulary(_ ok: inout Bool) {
        // The enum IS the security mechanism (`KubeCommand`/
        // `ScheduledActionKind`'s convention), so its membership is asserted
        // as a literal: a kind added without a matching executor branch and a
        // deliberate decision fails here rather than shipping.
        check(StrawHatProposalKind.allCases.map(\.rawValue)
                == ["add_task", "add_follow_up", "create_runbook_draft",
                    "add_sticky", "save_command_draft", "create_schedule_draft",
                    "open_sre_lead", "open_destination"],
              "phase 3's vocabulary is exactly these eight kinds, got \(StrawHatProposalKind.allCases.map(\.rawValue))", &ok)

        // The write/handoff split, as a literal list on both sides.
        //
        // This is the assertion that matters most in this file. A handoff runs
        // on a single click with **no confirm card**, so a kind that writes
        // anywhere and is filed as navigation would be a store write with no
        // confirmation at all - and it would render, and work, and look
        // right. A generic "isNavigation is consistent" check could not see
        // it; only naming both sides can.
        check(StrawHatProposalKind.allCases.filter { $0.isNavigation }.map(\.rawValue)
                == ["open_sre_lead", "open_destination"],
              "exactly two kinds are navigation, got \(StrawHatProposalKind.allCases.filter { $0.isNavigation }.map(\.rawValue))", &ok)
        check(StrawHatProposalKind.allCases.filter { !$0.isNavigation }.map(\.rawValue)
                == ["add_task", "add_follow_up", "create_runbook_draft",
                    "add_sticky", "save_command_draft", "create_schedule_draft"],
              "and exactly six write, got \(StrawHatProposalKind.allCases.filter { !$0.isNavigation }.map(\.rawValue))", &ok)

        // `fm/straw-hat-task-proposal-full-editor`: of the six writes, four
        // now route through an existing "New X" editor for the captain to
        // review before anything is written, rather than a confirm card
        // writing it straight to the store - `StrawHatProposalKind.
        // opensEditor`. Asserted as a literal on both sides, the same way the
        // write/handoff split above is: a kind quietly moved off this list
        // would go back to writing a bare default straight to the store with
        // no review, which is the exact captain complaint this change fixes.
        check(StrawHatProposalKind.allCases.filter(\.opensEditor).map(\.rawValue)
                == ["add_task", "add_follow_up", "save_command_draft", "create_schedule_draft"],
              "exactly four kinds open an editor for review, got \(StrawHatProposalKind.allCases.filter(\.opensEditor).map(\.rawValue))", &ok)
        check(StrawHatProposalKind.allCases.filter { !$0.opensEditor }.map(\.rawValue)
                == ["create_runbook_draft", "add_sticky", "open_sre_lead", "open_destination"],
              "and the rest do not, got \(StrawHatProposalKind.allCases.filter { !$0.opensEditor }.map(\.rawValue))", &ok)
        // Every editor-routed kind must actually say so on its card, or the
        // captain presses "Add task" and sees nothing distinguish it from a
        // write that already happened.
        for kind in StrawHatProposalKind.allCases where kind.opensEditor {
            check(!kind.openedForReviewLabel.isEmpty && kind.openedForReviewLabel != kind.confirmedTitle,
                  "\(kind.rawValue) needs its own \"opened for review\" wording, distinct from a past-tense claim", &ok)
        }

        // A navigation kind can never travel the write path, whatever the view
        // renders it as - `execute`'s own guard, asserted rather than trusted.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-nav-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        defer {
            if let previous { setenv("FM_SHIFT_DIR", previous, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }
        let navShift = ShiftStore()
        for kind in StrawHatProposalKind.allCases where kind.isNavigation {
            let proposal = StrawHatProposal(kind: kind, title: "should not write",
                                            handoff: .destination(.console, hint: nil))
            guard case .failed = StrawHatProposalExecutor.execute(
                proposal, stores: .init(shift: navShift)) else {
                check(false, "\(kind.rawValue) reached the write path and was not refused", &ok)
                continue
            }
        }
        check(navShift.activeTasks.isEmpty && navShift.followUps.isEmpty,
              "and it wrote nothing on the way to being refused", &ok)

        // Two independent refusals, and the behavioural check above cannot
        // tell them apart - which is a real finding rather than a note: the
        // first injected regression run for this suite removed `execute`'s
        // early `isNavigation` guard and every case above still passed,
        // because the switch's own explicit `.openSRELead, .openDestination`
        // branch returns `.failed` as well.
        //
        // Both are worth keeping, for different futures. The switch branch is
        // what makes *adding* a kind a compile error here. The guard is what
        // protects a kind added later and given a write branch by mistake -
        // exactly the case no behavioural test can construct today, because
        // the kind does not exist yet. So its presence is asserted as source,
        // the way this repo's other "the mechanism is still in front of it"
        // guards are.
        if let sources = SelfTestSources.appSourceDirectory(),
           let text = try? String(contentsOf: sources.appendingPathComponent("StrawHatProposalExecutor.swift"),
                                  encoding: .utf8) {
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            check(code.contains("guard !proposal.kind.isNavigation else {"),
                  "the write path must refuse a navigation kind up front, not only in its switch", &ok)
        } else {
            print("  NOTE: source tree not reachable - skipping the navigation-guard source check")
        }

        // The two closed sets a handoff resolves against.
        check(!StrawHatHandoff.allowedDestinations.contains(.poneglyph)
                && !StrawHatHandoff.allowedDestinations.contains(.vault),
              "a crew handoff must never be able to link to a credential surface", &ok)
        check(!StrawHatHandoff.allowedDestinations.contains(.overview)
                && !StrawHatHandoff.allowedDestinations.contains(.homeCanvas),
              "a handoff to the page the chat is on is a dead link", &ok)
        check(!StrawHatHandoff.allowedDestinations.contains(.settings),
              "machine configuration is not a conversational handoff", &ok)
        check(StrawHatHandoff.allowedDestinations.contains(.whiteboard),
              "the Whiteboard has to be reachable - it is the plan's own \"draw it out\"", &ok)
        check(Set(StrawHatHandoff.allowedDestinations).count == StrawHatHandoff.allowedDestinations.count,
              "the handoff allowlist must not carry a duplicate", &ok)

        // A title the app derives must be derived from real data, never left
        // blank - a link row with no title is an invisible button.
        check(StrawHatHandoff.destination(.logAnalyzer, hint: nil).title.contains("Log Analyzer"),
              "a destination handoff names its destination, got \(StrawHatHandoff.destination(.logAnalyzer, hint: nil).title)", &ok)
        check(StrawHatHandoff.sreLead(hostHint: "prod-bastion").title.contains("prod-bastion"),
              "an SRE Lead handoff names the host the captain named", &ok)
        check(!StrawHatHandoff.sreLead(hostHint: nil).title.isEmpty,
              "...and still has a title with no hint at all", &ok)

        for kind in StrawHatProposalKind.allCases {
            check(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil,
                  "\(kind.rawValue)'s SF Symbol \"\(kind.symbol)\" resolves", &ok)
            check(!kind.confirmTitle.isEmpty && !kind.confirmedTitle.isEmpty,
                  "\(kind.rawValue) needs both a confirm and a confirmed title", &ok)
        }
    }


    // MARK: The recap prompt

    private static func checkRecapPrompt(_ ok: inout Bool) {
        // No history: the message travels alone, with no recap scaffolding
        // wrapped around it.
        let bare = StrawHatRunner.promptWithRecap(message: "what next?", transcript: [])
        check(bare == "what next?",
              "with no transcript the recap prompt is just the message, got: \(bare)", &ok)

        let recapped = StrawHatRunner.promptWithRecap(
            message: "and the second one?",
            transcript: ["Captain: name two ports", "Crew: Loguetown and Water Seven"])
        check(recapped.contains("Loguetown"),
              "the recap must carry the earlier turns - that is the whole point of it", &ok)
        check(recapped.contains("and the second one?"),
              "the recap prompt must still carry the captain's actual message", &ok)
        // The two halves have to be distinguishable, or the model answers the
        // recap instead of the message. This is the minimal form of the plan's
        // phase-2 [CONTEXT]/[MESSAGE] envelope.
        check(recapped.contains("[RECAP") && recapped.contains("[MESSAGE FROM THE CAPTAIN"),
              "the recap and the live message must be separately labelled", &ok)
        check(recapped.range(of: "[RECAP")!.lowerBound < recapped.range(of: "[MESSAGE FROM THE CAPTAIN")!.lowerBound,
              "the recap comes before the message it is context for", &ok)
    }

    // MARK: The lock gate

    private static func checkLockGate(_ ok: inout Bool) {
        // A path that would spawn a real `claude` if the gate failed open -
        // pointed at a script that records being run, so "it was refused" is
        // proven by the absence of an invocation, not only by the error text.
        let log = scratchFile("lock-argv")
        let script = writeFakeClaude(reply: "should never run", argvLog: log)
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build against a fake claude", &ok)
            return
        }

        AppLockGate.shared.setLocked(true)
        let locked = ask(runner, "are you there?")
        check(locked.failure != nil, "a locked app must refuse a turn, got \(locked)", &ok)
        check(!FileManager.default.fileExists(atPath: log.path),
              "a locked app must not spawn claude at all", &ok)

        AppLockGate.shared.setLocked(false)
        let unlocked = ask(runner, "are you there?")
        check(unlocked.reply == "should never run",
              "an unlocked app runs the turn normally, got \(unlocked)", &ok)
        check(FileManager.default.fileExists(atPath: log.path),
              "...and that turn really did spawn claude", &ok)
    }

    // MARK: Turns

    private static func checkSingleTurn(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)
        let log = scratchFile("single-argv")
        let script = writeFakeClaude(reply: "Aye. What's the plan?", argvLog: log, sessionID: "sess-1")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build", &ok); return
        }
        let outcome = ask(runner, "hello")
        check(outcome.reply == "Aye. What's the plan?", "the reply text comes back verbatim, got \(outcome)", &ok)

        let argv = readArgv(log)
        let printable = printableArgv(log)
        // The captain's message travels as its own argv element - never
        // through a shell - which is what makes a message containing
        // backticks or `$(...)` inert.
        check(argv.contains("hello"), "the message is passed as an argv element, got \(printable)", &ok)
        check(argv.contains("--append-system-prompt"), "the persona is attached, got \(printable)", &ok)
        check(argv.contains(StrawHatCrew.persona), "the persona attached is the real one", &ok)
        check(argv.contains("--output-format") && argv.contains("json"),
              "the shared ClaudeOneShot argv shape is used", &ok)
        check(!argv.contains("--resume"), "a first turn has nothing to resume, got \(printable)", &ok)
        // Phase 1 has no tools, so it must not claim any - see
        // `StrawHatRunner`'s header.
        check(!argv.contains("--allowedTools"),
              "phase 1 grants no tools, so it must not pass an allowlist", &ok)
        check(!argv.contains("--mcp-config"), "phase 1 has no MCP server", &ok)
        check(!argv.contains("bypassPermissions"),
              "phase 1 has nothing to permit, so it must not bypass permissions", &ok)
        check(runner.debugSessionID == "sess-1",
              "the reply's session id is retained for the next turn, got \(String(describing: runner.debugSessionID))", &ok)
    }

    /// The multi-turn property, proven from the argv the *second* turn really
    /// ran with rather than from the runner's own bookkeeping.
    private static func checkResumeThreading(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)
        let log = scratchFile("resume-argv")
        let script = writeFakeClaude(reply: "Still here.", argvLog: log, sessionID: "sess-42")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build", &ok); return
        }
        _ = ask(runner, "first")
        let second = ask(runner, "second")
        check(second.reply == "Still here.", "the second turn succeeds, got \(second)", &ok)

        let argv = readArgv(log) // the log holds the LAST invocation
        let printable = printableArgv(log)
        check(argv.contains("second"), "the log should hold the second turn, got \(printable)", &ok)
        guard let resumeIndex = argv.firstIndex(of: "--resume") else {
            check(false, "the second turn must pass --resume, got \(printable)", &ok)
            return
        }
        check(argv.indices.contains(resumeIndex + 1) && argv[resumeIndex + 1] == "sess-42",
              "--resume must carry the first turn's own session id, got \(printable)", &ok)
        // A resumed turn carries no recap - the session already holds the
        // history, and sending it twice would pay for it twice.
        check(!argv.contains { $0.contains("[RECAP") },
              "an ordinary resumed turn must not carry a recap", &ok)

        // Third turn: still threading, not just the second.
        _ = ask(runner, "third")
        let third = readArgv(log)
        check(third.contains("--resume"), "every later turn keeps resuming, got \(third.map { $0 == StrawHatCrew.persona ? "<persona>" : $0 })", &ok)

        // A new conversation drops the thread deliberately.
        runner.reset()
        check(runner.debugSessionID == nil, "reset() clears the session id", &ok)
        check(runner.debugTranscriptCount == 0, "reset() clears the recap transcript", &ok)
        _ = ask(runner, "fresh start")
        check(!readArgv(log).contains("--resume"),
              "the turn after reset() starts a new session, got \(printableArgv(log))", &ok)
    }

    /// M1.2's own acceptance criterion: "killing the session id mid-
    /// conversation recovers without losing the thread."
    private static func checkStaleSessionRecovery(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)
        let log = scratchFile("stale-argv")
        // A fake `claude` that fails whenever `--resume` is present and
        // succeeds otherwise - exactly how a pruned/expired session behaves.
        let script = writeResumeRejectingClaude(reply: "Right - the login bug, and Rahul.", argvLog: log)
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build", &ok); return
        }

        // Turn one succeeds (no --resume yet) and gives the runner history.
        let first = ask(runner, "remind me what I said about the login bug")
        check(first.failure == nil, "the first turn should succeed, got \(first)", &ok)
        check(runner.debugTranscriptCount == 1, "the first turn is remembered for a recap", &ok)

        // Now force a session id `claude` will reject.
        runner.debugCorruptSessionID()
        let second = ask(runner, "and who was I supposed to ask?")

        check(second.failure == nil,
              "a stale session must recover rather than surfacing as a failed turn, got \(second)", &ok)
        let argv = readArgv(log) // the retry is the last invocation
        let printable = printableArgv(log)
        check(!argv.contains("--resume"),
              "the recovery retry must drop --resume, got \(printable)", &ok)
        // The whole point: recovering must not cost the conversation. Without
        // the recap the model would answer "who was I supposed to ask?" with
        // no idea what came before.
        check(argv.contains { $0.contains("[RECAP") },
              "the recovery retry must carry a transcript recap, got \(printable)", &ok)
        check(argv.contains { $0.contains("remind me what I said about the login bug") },
              "the recap must contain the earlier turn's real text", &ok)
        check(argv.contains { $0.contains("and who was I supposed to ask?") },
              "the recovery retry must still carry the captain's live message", &ok)
    }

    private static func checkFailuresAreReported(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)

        // A `claude` that is not there at all.
        StrawHatCrew.claudePathOverrideForTests = "/nonexistent/claude-\(UUID().uuidString)"
        check(StrawHatRunner() != nil,
              "the runner builds against any path - 'is it real' is the turn's problem, not init's", &ok)
        if let runner = StrawHatRunner() {
            let outcome = ask(runner, "hello")
            check(outcome.failure != nil, "a missing claude is a reported failure, got \(outcome)", &ok)
        }

        // Garbled output: a failure, never a silently-empty success.
        let script = writeRawClaude(stdout: "not json at all\n", exitCode: 1)
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        if let runner = StrawHatRunner() {
            let outcome = ask(runner, "hello")
            check(outcome.failure != nil, "garbled output is a reported failure, got \(outcome)", &ok)
        }

        // An empty message never reaches a process.
        let log = scratchFile("empty-argv")
        let ok2 = writeFakeClaude(reply: "should not run", argvLog: log)
        defer { try? FileManager.default.removeItem(at: ok2) }
        StrawHatCrew.claudePathOverrideForTests = ok2.path
        if let runner = StrawHatRunner() {
            let outcome = ask(runner, "   \n  ")
            check(outcome.failure != nil, "an empty message is refused, got \(outcome)", &ok)
            check(!FileManager.default.fileExists(atPath: log.path),
                  "an empty message must not spawn claude", &ok)
        }
        StrawHatCrew.claudePathOverrideForTests = nil
    }

    /// GL-13: an in-flight `claude -p` child must not outlive the app.
    ///
    /// Half behavioural, half source guard, because neither alone is enough:
    /// `cancel()` genuinely stops a turn from delivering (observable), but
    /// whether the app's quit path *calls* it leaves nothing to observe in
    /// process - and an unwired `shutdown` is exactly the shape
    /// `CodePreviewController.shutdown()` shipped in for its whole life with
    /// zero callers.
    private static func checkQuitCancelsAnInFlightTurn(_ ok: inout Bool) {
        AppLockGate.shared.setLocked(false)
        // A `claude` that never answers, so the turn is genuinely still in
        // flight when it is cancelled.
        let script = writeScript("sleep 30\nexit 0")
        defer { try? FileManager.default.removeItem(at: script) }
        StrawHatCrew.claudePathOverrideForTests = script.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner() else {
            check(false, "runner should build", &ok); return
        }
        var landed = false
        runner.ask("hello") { _ in landed = true }
        // Let the process actually start before pulling it out from under.
        let started = Date().addingTimeInterval(1.0)
        while Date() < started { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        check(!landed, "the turn should still be in flight against a sleeping claude", &ok)

        runner.cancel()
        let deadline = Date().addingTimeInterval(5)
        while !landed && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // `Subprocess` reports a cancelled run rather than hanging - what
        // matters is that it came back in seconds, not after `sleep 30`.
        check(landed, "cancel() must end the turn rather than leaving it running", &ok)

        // ...and the quit path really reaches it. Skips rather than passes
        // when the source tree is not reachable (a release/installed run),
        // matching every other source guard in this repo - a guard that
        // silently passes because it found nothing to read is worse than none.
        guard let sources = SelfTestSources.appSourceDirectory() else {
            print("  NOTE: source tree not reachable - skipping the quit-wiring source guard")
            return
        }
        let shell = (try? String(contentsOf: sources.appendingPathComponent("AppShellController.swift"), encoding: .utf8)) ?? ""
        let main = (try? String(contentsOf: sources.appendingPathComponent("main.swift"), encoding: .utf8)) ?? ""
        check(shell.contains("strawHat.shutdown()"),
              "AppShellController must forward the quit teardown to the crew page", &ok)
        check(main.contains("appShell.shutdownStrawHatCrew()"),
              "applicationWillTerminate must call that forward - an unwired shutdown is invisible", &ok)
    }

    // MARK: M2.1 - the three-rung parser
    //
    // Each rung gets its own case, and each asserts the thing that rung is
    // *for* rather than merely that parsing succeeded:
    //
    //   rung 1 - a validated envelope becomes attributed sections + proposals
    //   rung 2 - an unknown speaker/kind still renders, and never executes
    //   rung 3 - no envelope at all still shows the captain their reply
    //
    // Plus the invariant all three share: the reply is never dropped.

    private static func checkRung1ValidatedEnvelope(_ ok: inout Bool) {
        // The plan's own worked example, verbatim.
        let reply = """
        ```json
        { "sections": [
            { "speaker": "nami",
              "text": "I heard a task and a follow-up in there - drafted both:",
              "proposals": [
                { "kind": "add_task", "title": "Fix the login issue", "due": "2026-09-09" },
                { "kind": "add_follow_up", "title": "Ask Rahul about the Cognito config" } ] },
            { "speaker": "luffy",
              "text": "Both drafted - confirm to add.",
              "followup": "Want Robin to check for a Cognito runbook before you talk to Rahul?" }
        ] }
        ```
        """
        guard case .envelope(let sections) = StrawHatEnvelope.parse(reply) else {
            check(false, "the plan's own worked example must parse as a validated envelope", &ok)
            return
        }
        check(sections.count == 2, "that example is two sections, got \(sections.count)", &ok)
        check(sections.first?.speaker == .nami, "the first section is Nami's", &ok)
        check(sections.last?.speaker == .luffy, "the second is Luffy's", &ok)
        check(sections.first?.proposals.count == 2,
              "Nami's section carries both proposals, got \(sections.first?.proposals.count ?? -1)", &ok)
        check(sections.first?.proposals.first?.kind == .addTask, "a task first", &ok)
        check(sections.first?.proposals.first?.title == "Fix the login issue", "with the captain's own wording", &ok)
        check(sections.first?.proposals.last?.kind == .addFollowUp, "then a follow-up", &ok)
        check(sections.first?.droppedProposalCount == 0, "nothing was dropped from a valid envelope", &ok)
        check(sections.last?.followup?.contains("Cognito runbook") == true,
              "the closing question survives as a followup, not as a proposal", &ok)
        check(sections.last?.proposals.isEmpty == true,
              "a followup is not a proposal - it asks, it does not write", &ok)

        // The two shapes the extractor accepts, and only those.
        let bare = StrawHatEnvelope.parse(#"{ "sections": [ { "speaker": "luffy", "text": "hi" } ] }"#)
        guard case .envelope = bare else {
            check(false, "an unfenced object is the shape the persona asks for and must parse", &ok)
            return
        }
        let prosePrefixed = StrawHatEnvelope.parse("""
        One moment.

        ```json
        { "sections": [ { "speaker": "luffy", "text": "here you go" } ] }
        ```
        """)
        guard case .envelope(let salvaged) = prosePrefixed else {
            check(false, "a fence after a stray sentence must still parse - `stripCodeFence` only looks at line 0", &ok)
            return
        }
        check(salvaged.contains(where: { $0.speaker == .luffy && $0.text == "here you go" }),
              "the envelope's own section is attributed, got \(salvaged.map { "\($0.speaker?.rawValue ?? "-"):\($0.text)" })", &ok)
        // The stray sentence is kept too, unattributed - neither half of a
        // reply that is both prose and envelope is dropped.
        check(salvaged.contains(where: { $0.speaker == nil && $0.text == "One moment." }),
              "...and the prose around it survives as an unattributed section", &ok)
    }

    private static func checkRung2PartialSalvage(_ ok: inout Bool) {
        // An unknown speaker and an unknown proposal kind, in one reply.
        //
        // The unaboard voice is **Brook**, who the plan gives no code at all
        // (Dictation's hotkey already types into this composer) - phase 2's
        // fixture used Zoro, who is aboard as of phase 3, so this case had to
        // be re-pointed at a voice that is genuinely still absent rather than
        // left asserting the old roster.
        //
        // Note the unaboard speaker's proposal uses a **valid** kind. An
        // invented kind is refused by the kind check regardless of who
        // proposed it, so a fixture pairing the two leaves the speaker guard
        // completely untested - which is exactly what an injected regression
        // proved here: removing that guard passed the whole suite.
        let reply = """
        ```json
        { "sections": [
            { "speaker": "brook",
              "text": "I'd restart the pod.",
              "proposals": [ { "kind": "add_task", "title": "Should never be offered" } ] },
            { "speaker": "nami",
              "text": "Drafted the task anyway:",
              "proposals": [
                { "kind": "add_task", "title": "Restart the API pods" },
                { "kind": "delete_everything", "title": "wipe it" } ] }
        ] }
        ```
        """
        guard case .envelope(let sections) = StrawHatEnvelope.parse(reply) else {
            check(false, "a salvageable envelope must not fall all the way to plain text", &ok)
            return
        }
        check(sections.count == 2, "both sections still render, got \(sections.count)", &ok)

        // The unattributed one: text kept, speaker refused, proposals refused.
        let unknown = sections[0]
        check(unknown.speaker == nil,
              "a voice that is not aboard must not be credited, got \(unknown.speaker?.rawValue ?? "nil")", &ok)
        check(unknown.rawSpeaker == "brook", "...but what the model wrote is kept for the log", &ok)
        check(unknown.text == "I'd restart the pod.", "its text still renders - the reply is never dropped", &ok)
        check(unknown.proposals.isEmpty,
              "an unattributed section's proposals must never be executable, got \(unknown.proposals.map(\.title))", &ok)
        check(!unknown.proposals.contains(where: { $0.title == "Should never be offered" }),
              "...even when the kind itself is one the enum knows", &ok)
        check(unknown.droppedProposalCount == 1,
              "...and the refusal is counted, not silent, got \(unknown.droppedProposalCount)", &ok)

        // The attributed one: the good proposal survives, the invented one does not.
        let known = sections[1]
        check(known.speaker == .nami, "a real speaker is still credited", &ok)
        check(known.proposals.count == 1,
              "only the valid proposal survives, got \(known.proposals.count)", &ok)
        check(known.proposals.first?.kind == .addTask, "and it is the one the enum knows", &ok)
        check(known.droppedProposalCount == 1,
              "the invented kind is counted as dropped, got \(known.droppedProposalCount)", &ok)

        // A proposal missing the field its kind requires is refused too -
        // there is nothing safe to invent for either.
        let missing = StrawHatEnvelope.parse("""
        {"sections":[{"speaker":"nami","text":"x","proposals":[
          {"kind":"add_task"},
          {"kind":"create_runbook_draft","title":"No body"}
        ]}]}
        """)
        guard case .envelope(let refused) = missing, let only = refused.first else {
            check(false, "a section whose every proposal is refused still renders its text", &ok)
            return
        }
        check(only.proposals.isEmpty,
              "a titleless task and a bodyless runbook are both refused, got \(only.proposals.count)", &ok)
        check(only.droppedProposalCount == 2, "both counted, got \(only.droppedProposalCount)", &ok)
    }

    private static func checkRung3PlainText(_ ok: inout Bool) {
        // Ordinary prose - the common case, and phase 1's whole behaviour.
        let prose = "Loguetown and Water Seven. Want the rest?"
        guard case .plain(let text) = StrawHatEnvelope.parse(prose) else {
            check(false, "an ordinary prose reply is rung 3", &ok)
            return
        }
        check(text == prose, "and it renders verbatim, got: \(text)", &ok)

        // The direction that matters most: a prose answer that merely
        // *contains* braces must not be mistaken for an envelope and
        // shredded. This is why there is no brace-balanced last-resort scan -
        // see `StrawHatEnvelope`'s header.
        //
        // The object here has no `sections` key at all, so the only thing that
        // could turn this reply into an envelope is a widest-brace-span scan -
        // which is precisely what must not exist. An injected regression that
        // adds one is caught by this case.
        let bracey = """
        Your config needs a `logging` block:

        ```json
        { "level": "debug", "handlers": ["console"] }
        ```

        Drop that in and restart.
        """
        guard case .plain(let kept) = StrawHatEnvelope.parse(bracey) else {
            check(false, "a fenced json block that is not an envelope must not be read as one", &ok)
            return
        }
        check(kept.contains("Drop that in and restart."),
              "the prose after the block survives - losing it would be silent data loss", &ok)
        check(kept.contains("\"level\": \"debug\""), "and so does the code the captain asked for", &ok)

        // A reply that is genuinely *both* - a real envelope wrapped in real
        // prose, which is what "how does your reply format work?" produces -
        // keeps both, rather than choosing a side. See `Extracted`'s note.
        let both = StrawHatEnvelope.parse("""
        Your reply format looks like this:

        ```json
        { "sections": [ { "speaker": "nami", "text": "example" } ] }
        ```

        The `speaker` has to be one of the four of us.
        """)
        guard case .envelope(let mixed) = both else {
            check(false, "a real envelope inside prose still parses as one", &ok)
            return
        }
        check(mixed.count == 3,
              "leading prose, the envelope's section, then trailing prose - got \(mixed.count)", &ok)
        check(mixed.first?.speaker == nil && mixed.first?.text.contains("format looks like this") == true,
              "the prose before the fence comes first, unattributed", &ok)
        check(mixed.dropFirst().first?.speaker == .nami,
              "the envelope's own section keeps its attribution", &ok)
        check(mixed.last?.speaker == nil && mixed.last?.text.contains("one of the four of us") == true,
              "and the prose after it is kept too - nothing is lost either way", &ok)

        // The one shape a brace-balanced scan would genuinely destroy: an
        // *unfenced* inline example, whose widest brace span really is a
        // valid envelope. With no fence there is nothing for `extract` to
        // find, so the correct answer is the whole prose - and a scan would
        // return the span, drop everything around it, and render the
        // captain's own question back at them as Nami's reply.
        let inlineExample = """
        You'd send me something like {"sections": [{"speaker": "nami", "text": "hi"}]}         and I'd turn each entry into its own card. Want me to walk through the fields?
        """
        guard case .plain(let inlineKept) = StrawHatEnvelope.parse(inlineExample) else {
            check(false, "an unfenced inline example is prose, not an envelope - a brace scan would shred it", &ok)
            return
        }
        check(inlineKept.contains("Want me to walk through the fields?"),
              "...and every word of it survives", &ok)

        // Every way an envelope can be unusable lands here rather than
        // rendering nothing.
        let unusable = [
            "```json\n{ not json at all\n```",
            #"{"sections": []}"#,
            #"{"sections": [{"speaker":"nami"}]}"#,
            #"{"reply": "wrong key"}"#,
            #"{"sections": "not an array"}"#,
        ]
        for reply in unusable {
            guard case .plain(let shown) = StrawHatEnvelope.parse(reply) else {
                check(false, "an unusable envelope must fall to plain text: \(reply)", &ok)
                continue
            }
            check(!shown.isEmpty, "...and still show the captain something: \(reply)", &ok)
        }
    }

    /// `fm/straw-hat-voice-order-composer-polish-8dd2`: the parser-side half
    /// of fixing the leaked-tool-narration bug the captain's screenshot
    /// caught. `StrawHatCrew.persona` now forbids this outright (asserted in
    /// `checkPersona`); this is the belt to that braces, for whatever a model
    /// produces anyway.
    ///
    /// `StrawHatEnvelope.isLikelyToolNarration` is checked directly against
    /// the captain's own exact fixture text and against a handful of near
    /// misses, and - the case that matters most - against the "genuinely
    /// both" fixture `checkRung3PlainText` already proved keeps both halves,
    /// to prove this new, narrower check does not regress that deliberately
    /// preserved behaviour.
    private static func checkToolNarrationSuppression(_ ok: inout Bool) {
        // The captain's own screenshot, verbatim.
        check(StrawHatEnvelope.isLikelyToolNarration(
                "Context already says tasks_due_soon: 0, no need for a tool call."),
              "the exact leaked sentence from the captain's screenshot must be recognised", &ok)
        // A few phrasings a model could plausibly reach for instead of the
        // exact wording above - the check has to generalise, not memorise
        // one sentence.
        for phrase in [
            "I'll skip the tool call here since the context already covers it.",
            "No need to call shift_read for this one.",
            "Let me check... actually, no tool call needed.",
        ] {
            check(StrawHatEnvelope.isLikelyToolNarration(phrase),
                  "a near-miss phrasing of the same leak must still be caught: \(phrase)", &ok)
        }

        // The one thing this must NOT catch: `checkRung3PlainText`'s
        // "genuinely both" fixture, a reply explaining its own reply format
        // - real content the captain may have asked for, and the exact case
        // `Extracted`'s own note says must keep both halves. Neither its
        // leading nor its trailing half mentions a tool or a context field.
        for benign in [
            "Your reply format looks like this:",
            "The `speaker` has to be one of the four of us.",
            "Loguetown and Water Seven. Want the rest?",
        ] {
            check(!StrawHatEnvelope.isLikelyToolNarration(benign),
                  "ordinary prose must not be flagged as tool narration: \(benign)", &ok)
        }

        // End to end: a real envelope with the leaked sentence stitched on as
        // leading prose - the exact shape `Extracted.leading` produces -
        // renders with only the real crew section, not two.
        let withLeadingLeak = """
        Context already says tasks_due_soon: 0, no need for a tool call.

        ```json
        { "sections": [ { "speaker": "nami", "text": "Nothing due today." } ] }
        ```
        """
        guard case .envelope(let leadingCase) = StrawHatEnvelope.parse(withLeadingLeak) else {
            check(false, "a real envelope survives even with leaked prose stitched in front of it", &ok)
            return
        }
        check(leadingCase.count == 1,
              "the leaked leading sentence is dropped, not rendered as its own section - got \(leadingCase.count)", &ok)
        check(leadingCase.first?.speaker == .nami,
              "and the real section is untouched", &ok)

        // Same shape, trailing.
        let withTrailingLeak = """
        ```json
        { "sections": [ { "speaker": "nami", "text": "Nothing due today." } ] }
        ```

        Context already says tasks_due_soon: 0, no need for a tool call.
        """
        guard case .envelope(let trailingCase) = StrawHatEnvelope.parse(withTrailingLeak) else {
            check(false, "a real envelope survives even with leaked prose stitched after it", &ok)
            return
        }
        check(trailingCase.count == 1,
              "the leaked trailing sentence is dropped too, got \(trailingCase.count)", &ok)

        // The genuinely-both fixture must still keep both halves once the
        // narration filter is in place - the regression this whole check
        // exists to prevent.
        let genuinelyBoth = StrawHatEnvelope.parse("""
        Your reply format looks like this:

        ```json
        { "sections": [ { "speaker": "nami", "text": "example" } ] }
        ```

        The `speaker` has to be one of the four of us.
        """)
        guard case .envelope(let bothSections) = genuinelyBoth else {
            check(false, "the genuinely-both case must still parse as an envelope", &ok)
            return
        }
        check(bothSections.count == 3,
              "leading prose, the real section, then trailing prose - the narration filter must not have eaten one, got \(bothSections.count)", &ok)
    }

    private static func checkEnvelopeCaps(_ ok: inout Bool) {
        // Bounded, because these become permanent arranged subviews of the
        // transcript stack - and a runaway list of confirm cards is worse than
        // a truncated one, since every card is a button that writes.
        let manySections = (0..<(StrawHatEnvelope.maxSections + 4))
            .map { #"{"speaker":"luffy","text":"line \#($0)"}"# }
            .joined(separator: ",")
        guard case .envelope(let capped) = StrawHatEnvelope.parse("{\"sections\":[\(manySections)]}") else {
            check(false, "an over-long envelope still parses", &ok)
            return
        }
        // maxSections real sections plus the one "N more weren't shown" note -
        // the "no silent caps" rule.
        check(capped.count == StrawHatEnvelope.maxSections + 1,
              "sections are capped at \(StrawHatEnvelope.maxSections) plus an overflow note, got \(capped.count)", &ok)
        check(capped.last?.text.contains("weren't shown") == true,
              "the overflow must be stated, not silently truncated", &ok)

        let manyProposals = (0..<(StrawHatEnvelope.maxProposalsPerSection + 3))
            .map { #"{"kind":"add_task","title":"task \#($0)"}"# }
            .joined(separator: ",")
        guard case .envelope(let s) = StrawHatEnvelope.parse(
            "{\"sections\":[{\"speaker\":\"nami\",\"text\":\"lots\",\"proposals\":[\(manyProposals)]}]}"),
              let section = s.first else {
            check(false, "an over-long proposal list still parses", &ok)
            return
        }
        check(section.proposals.count == StrawHatEnvelope.maxProposalsPerSection,
              "proposals are capped at \(StrawHatEnvelope.maxProposalsPerSection), got \(section.proposals.count)", &ok)
        check(section.droppedProposalCount == 3,
              "the ones past the cap are counted, got \(section.droppedProposalCount)", &ok)
    }

    // MARK: M2.2 - due-date resolution

    private static func checkDueResolution(_ ok: inout Bool) {
        // A fixed reference, so "tomorrow" is a checkable date rather than
        // whatever day the suite happens to run on.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 9; comps.hour = 10
        guard let now = Calendar.current.date(from: comps) else {
            check(false, "could not build a reference date", &ok)
            return
        }

        // Strict ISO, the shape the persona prefers. No time invented.
        let iso = StrawHatProposal(kind: .addTask, title: "t", due: "2026-09-09")
        check(iso.resolvedDue(now: now)?.date == "2026-09-09",
              "an ISO due date resolves as written, got \(iso.resolvedDue(now: now)?.date ?? "nil")", &ok)
        check(iso.resolvedDue(now: now)?.time == nil,
              "a bare date carries no time - inventing one would show a due time nobody proposed", &ok)

        // Natural language, through the app's own scanner - so "tomorrow"
        // means the same thing whether the captain typed it or Nami proposed it.
        let tomorrow = StrawHatProposal(kind: .addTask, title: "t", due: "tomorrow")
        check(tomorrow.resolvedDue(now: now)?.date == "2026-09-10",
              "\"tomorrow\" resolves through ShiftDateParser, got \(tomorrow.resolvedDue(now: now)?.date ?? "nil")", &ok)
        let withTime = StrawHatProposal(kind: .addTask, title: "t", due: "tomorrow 3pm")
        check(withTime.resolvedDue(now: now)?.time == "15:00",
              "a time-of-day survives, got \(withTime.resolvedDue(now: now)?.time ?? "nil")", &ok)

        // The direction that matters: never a fabricated fallback. A wrong due
        // date presented as the captain's own choice is worse than none.
        let nonsense = StrawHatProposal(kind: .addTask, title: "t", due: "whenever, really")
        check(nonsense.resolvedDue(now: now) == nil,
              "an unreadable date leaves the task undated rather than landing on today", &ok)
        check(nonsense.detail(now: now).contains("couldn't read"),
              "...and says so, so the captain can fix it on the Tasks page", &ok)
        check(StrawHatProposal(kind: .addTask, title: "t").resolvedDue(now: now) == nil,
              "no date proposed, no date resolved", &ok)
    }

    // MARK: M2.3 - the bounded context snapshot

    private static func checkContextSnapshot(_ ok: inout Bool) {
        // Real stores against a scratch directory - never the captain's own.
        // `FM_SHIFT_DIR` is the root override the whole `GrandLineDocs/`
        // family resolves through, so this keeps both stores away from the
        // real clone (audit #2 §7.1's own lesson).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-ctx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Both overrides, not just `FM_SHIFT_DIR`: `DocsRunbookStore.init`
        // checks `FM_DOCS_RUNBOOKS_DIR` **first** and only falls back to
        // `FM_SHIFT_DIR`, and `main.swift`'s own self-test block already sets
        // the former - so setting only the root override leaves this case
        // sharing one docs folder with every other case in the process. Found
        // by a real failure here: a runbook one case created was still present
        // when another deleted its own, and the undo assertion read as broken.
        let previousShiftDir = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        let previousDocsDir = ProcessInfo.processInfo.environment["FM_DOCS_RUNBOOKS_DIR"]
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        setenv("FM_DOCS_RUNBOOKS_DIR", scratch.appendingPathComponent("runbooks").path, 1)
        defer {
            if let previousShiftDir { setenv("FM_SHIFT_DIR", previousShiftDir, 1) } else { unsetenv("FM_SHIFT_DIR") }
            if let previousDocsDir { setenv("FM_DOCS_RUNBOOKS_DIR", previousDocsDir, 1) } else { unsetenv("FM_DOCS_RUNBOOKS_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }

        let shift = ShiftStore()
        let docs = DocsRunbookStore()

        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 9; comps.hour = 10
        guard let now = Calendar.current.date(from: comps) else {
            check(false, "could not build a reference date", &ok)
            return
        }
        let day = ShiftDateFormatting.components(from: now).dateStr

        // Due today, well past the window, and a pending follow-up.
        var soon = ShiftTask.fresh(now: now)
        soon.title = "Rotate the staging certificate"
        soon.dueDate = day
        shift.addTask(soon)

        var faraway = ShiftTask.fresh(now: now)
        faraway.title = "Plan the Q4 migration"
        faraway.dueDate = "2027-01-01"
        shift.addTask(faraway)

        var followUp = ShiftFollowUp.fresh()
        followUp.title = "Ask Rahul about the Cognito config"
        followUp.followUpAt = day
        shift.addFollowUp(followUp)

        _ = docs.createRunbook(title: "Draining a node", content: "# Draining a node\n\nkubectl drain")

        let snapshot = StrawHatContextSnapshot.capture(shift: shift, docs: docs, now: now)
        let rendered = snapshot.render()

        check(snapshot.dueTaskCount == 1,
              "only the task inside the due-soon window counts, got \(snapshot.dueTaskCount)", &ok)
        check(rendered.contains("Rotate the staging certificate"),
              "a due-soon task's title reaches the crew - Nami cannot say \"you already have one\" otherwise", &ok)
        check(!rendered.contains("Plan the Q4 migration"),
              "a task months out is noise in every turn and must stay out of the snapshot", &ok)
        check(snapshot.pendingFollowUpCount == 1,
              "the pending follow-up counts, got \(snapshot.pendingFollowUpCount)", &ok)
        check(rendered.contains("Ask Rahul"), "...and is named", &ok)
        check(rendered.contains("Draining a node"),
              "a runbook title reaches Robin - recognition is her whole job", &ok)
        check(rendered.contains("runbooks: 1"), "with a real count beside it", &ok)

        // GL-14: unknown is never rendered as zero. A registry that has not
        // reported is a stated gap, not a clean bill of health.
        let emptyHealth = StrawHatContextSnapshot.capture(shift: shift, docs: docs,
                                                          healthStates: [], now: now)
        check(emptyHealth.health.isEmpty, "an unreported registry contributes no health lines", &ok)
        check(emptyHealth.unavailable.contains(where: { $0.contains("health") }),
              "...and says so - \"nothing has checked yet\" is not \"nothing is broken\"", &ok)
        check(emptyHealth.render().contains("unavailable:"),
              "the gap must be visible in the prompt itself", &ok)

        // A real failing service reads as failing, with its count. Built as a
        // real `ServiceHealthState` rather than by driving the shared
        // registry, which is process-wide and would poison whatever suite runs
        // next in the same process.
        var broken = ServiceHealthState()
        broken.lastFailure = now
        broken.lastFailureDetail = "boom"
        broken.consecutiveFailures = ServiceHealthRegistry.failureThreshold
        let failing = StrawHatContextSnapshot.capture(
            shift: shift, docs: docs,
            healthStates: [(service: .scheduledAutomations, state: broken)], now: now)
        check(failing.render().lowercased().contains("failing"),
              "a failing service must read as failing, got: \(failing.render())", &ok)
        check(failing.render().contains("\(ServiceHealthRegistry.failureThreshold)"),
              "...with its failure count, so Chopper can say how bad it is", &ok)

        // And a healthy one reads as ok, so "failing" is not just the only
        // word this ever produces.
        var fine = ServiceHealthState()
        fine.lastSuccess = now
        let healthy = StrawHatContextSnapshot.capture(
            shift: shift, docs: docs,
            healthStates: [(service: .docsSync, state: fine)], now: now)
        check(healthy.render().contains("=ok"),
              "a healthy service reads as ok, got: \(healthy.render())", &ok)
        check(healthy.unavailable.isEmpty, "...and is not also reported as unavailable", &ok)

        // Titles are capped; the count never is. Overflow is stated.
        for i in 0..<(StrawHatContextSnapshot.maxTaskTitles + 3) {
            var t = ShiftTask.fresh(now: now)
            t.title = "Bulk task \(i)"
            t.dueDate = day
            shift.addTask(t)
        }
        let big = StrawHatContextSnapshot.capture(shift: shift, docs: docs, now: now)
        check(big.dueTasks.count == StrawHatContextSnapshot.maxTaskTitles,
              "titles cap at \(StrawHatContextSnapshot.maxTaskTitles), got \(big.dueTasks.count)", &ok)
        check(big.dueTaskCount > big.dueTasks.count, "but the count stays exact", &ok)
        check(big.render().contains("and \(big.dueTaskCount - big.dueTasks.count) more"),
              "and the overflow is stated - \"no silent caps\"", &ok)

        // A docs folder that cannot be read is a stated gap, not "no runbooks".
        let noDocs = StrawHatContextSnapshot.capture(shift: shift, docs: nil, now: now)
        check(noDocs.unavailable.contains(where: { $0.contains("runbooks") }),
              "an unreadable docs folder is stated rather than reported empty", &ok)
    }

    // MARK: M2.3 - the turn envelope

    private static func checkTurnEnvelope(_ ok: inout Bool) {
        var snapshot = StrawHatContextSnapshot()
        snapshot.dueTaskCount = 2
        snapshot.dueTasks = [.init(title: "Rotate the cert", due: "Sep 9", isOverdue: false)]

        let prompt = StrawHatTurn.prompt(context: snapshot, message: "what should I do first?")
        check(prompt.contains("[CONTEXT"), "the snapshot is labelled as context", &ok)
        check(prompt.contains("[MESSAGE FROM THE CAPTAIN"), "the captain's words are labelled as theirs", &ok)
        check(prompt.contains("Rotate the cert"), "the snapshot's contents travel", &ok)
        check(prompt.contains("what should I do first?"), "and so does the message", &ok)
        // The whole reason for two labelled parts: the snapshot carries task
        // titles the captain wrote, and a model reading them as the current
        // message would answer the wrong question entirely.
        guard let ctx = prompt.range(of: "[CONTEXT"),
              let msg = prompt.range(of: "[MESSAGE FROM THE CAPTAIN") else {
            check(false, "both labels must be present", &ok)
            return
        }
        check(ctx.lowerBound < msg.lowerBound, "context comes before the message it is background for", &ok)
        check(prompt.contains("read-only"), "and says it is read-only, so it is not treated as an instruction", &ok)

        // No context and no recap: the bare message, exactly as phase 1 sent
        // it - which is also what the recap case asserts.
        check(StrawHatTurn.prompt(context: nil, message: "hello") == "hello",
              "an unadorned turn carries no scaffolding", &ok)

        // A recovered turn carries all three, in order.
        let recovered = StrawHatTurn.prompt(context: snapshot,
                                            recap: ["Captain: two ports?", "Crew: Loguetown"],
                                            message: "and the second?")
        check(recovered.contains("[RECAP"), "a recovered turn labels its recap", &ok)
        guard let r = recovered.range(of: "[RECAP"),
              let c = recovered.range(of: "[CONTEXT"),
              let m = recovered.range(of: "[MESSAGE FROM THE CAPTAIN") else {
            check(false, "all three labels must be present on a recovered turn", &ok)
            return
        }
        check(c.lowerBound < r.lowerBound && r.lowerBound < m.lowerBound,
              "context, then recap, then the live message", &ok)
        check(recovered.contains("Loguetown"), "the thread is genuinely carried, not just labelled", &ok)
    }

    // MARK: M2.2 - execution, and the confirm-only guarantee

    private static func checkProposalExecution(_ ok: inout Bool) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-exec-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Both overrides, not just `FM_SHIFT_DIR`: `DocsRunbookStore.init`
        // checks `FM_DOCS_RUNBOOKS_DIR` **first** and only falls back to
        // `FM_SHIFT_DIR`, and `main.swift`'s own self-test block already sets
        // the former - so setting only the root override leaves this case
        // sharing one docs folder with every other case in the process. Found
        // by a real failure here: a runbook one case created was still present
        // when another deleted its own, and the undo assertion read as broken.
        let previousShiftDir = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        let previousDocsDir = ProcessInfo.processInfo.environment["FM_DOCS_RUNBOOKS_DIR"]
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        setenv("FM_DOCS_RUNBOOKS_DIR", scratch.appendingPathComponent("runbooks").path, 1)
        defer {
            if let previousShiftDir { setenv("FM_SHIFT_DIR", previousShiftDir, 1) } else { unsetenv("FM_SHIFT_DIR") }
            if let previousDocsDir { setenv("FM_DOCS_RUNBOOKS_DIR", previousDocsDir, 1) } else { unsetenv("FM_DOCS_RUNBOOKS_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }

        let shift = ShiftStore()
        let docs = DocsRunbookStore()
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 9; comps.hour = 10
        guard let now = Calendar.current.date(from: comps) else {
            check(false, "could not build a reference date", &ok)
            return
        }

        // ---- The confirm-only guarantee, asserted rather than described ----
        //
        // Parsing the plan's own worked example must write nothing. This is
        // the property the whole feature rests on: a model cannot reach the
        // captain's stores, only hand the app a value that becomes a button.
        let tasksBefore = shift.activeTasks.count
        let followUpsBefore = shift.followUps.count
        let runbooksBefore = docs.listRunbooks().count
        _ = StrawHatEnvelope.parse("""
        {"sections":[{"speaker":"nami","text":"drafted","proposals":[
          {"kind":"add_task","title":"Should not exist"},
          {"kind":"add_follow_up","title":"Should not exist either"}]}]}
        """)
        check(shift.activeTasks.count == tasksBefore
                && shift.followUps.count == followUpsBefore
                && docs.listRunbooks().count == runbooksBefore,
              "parsing a reply must never write - only a captain's press does", &ok)

        // ---- add_task ----
        let taskProposal = StrawHatProposal(kind: .addTask, title: "Fix the login issue",
                                            due: "2026-09-09", notes: "from the crew")
        guard case .written(let taskMessage, let taskUndo) =
                StrawHatProposalExecutor.execute(taskProposal, stores: .init(shift: shift, docs: docs), now: now) else {
            check(false, "confirming a task proposal must write it", &ok)
            return
        }
        check(taskMessage.contains("Fix the login issue"), "the toast names what landed", &ok)
        // GL-33: an undo must genuinely restore. `ShiftStore` has no delete
        // for a task, so there is deliberately none here - see
        // `StrawHatProposalExecutor`'s header.
        check(taskUndo == nil,
              "a task add offers no undo - ShiftStore cannot delete one, and a fake undo would be a lie", &ok)
        guard let written = shift.activeTasks.first(where: { $0.title == "Fix the login issue" }) else {
            check(false, "the task must actually be in the store", &ok)
            return
        }
        check(written.dueDate == "2026-09-09", "with its due date, got \(written.dueDate ?? "nil")", &ok)
        check(written.notes == "from the crew", "and its notes", &ok)
        // Nothing invented: the model was asked for neither, so neither is set.
        check(written.projectID == nil, "no project is invented", &ok)
        check(written.priority == ShiftTask.fresh(now: now).priority,
              "and the priority stays the store's own default rather than a guess", &ok)

        // Survives a real reload - i.e. it reached disk, not just the array.
        let reloaded = ShiftStore()
        check(reloaded.activeTasks.contains(where: { $0.title == "Fix the login issue" }),
              "a confirmed task must survive a fresh store - otherwise it never reached disk", &ok)

        // ---- add_follow_up ----
        let followUpProposal = StrawHatProposal(kind: .addFollowUp,
                                                title: "Ask Rahul about the Cognito config",
                                                due: "tomorrow")
        guard case .written = StrawHatProposalExecutor.execute(followUpProposal, stores: .init(shift: shift, docs: docs), now: now) else {
            check(false, "confirming a follow-up proposal must write it", &ok)
            return
        }
        guard let wroteFollowUp = shift.followUps.first(where: { $0.title.contains("Rahul") }) else {
            check(false, "the follow-up must actually be in the store", &ok)
            return
        }
        check(wroteFollowUp.followUpAt == "2026-09-10",
              "\"tomorrow\" resolved through ShiftDateParser, got \(wroteFollowUp.followUpAt ?? "nil")", &ok)
        check(wroteFollowUp.status == .pending, "and it lands pending", &ok)

        // ---- create_runbook_draft, the one kind with a real undo ----
        let draft = StrawHatProposal(kind: .createRunbookDraft, title: "Draining a node",
                                     content: "# Draining a node\n\nkubectl drain node-1")
        guard case .written(let draftMessage, let draftUndo) =
                StrawHatProposalExecutor.execute(draft, stores: .init(shift: shift, docs: docs), now: now) else {
            check(false, "confirming a runbook draft must write it", &ok)
            return
        }
        check(draftMessage.contains("Draining a node"), "the toast names the runbook", &ok)
        check(docs.listRunbooks().contains(where: { $0.title == "Draining a node" }),
              "and it is really in the runbook list", &ok)
        guard let undo = draftUndo else {
            check(false, "a runbook draft DOES get an undo - `deleteRunbook` exists and the id is in hand", &ok)
            return
        }
        undo()
        check(!docs.listRunbooks().contains(where: { $0.title == "Draining a node" }),
              "and that undo genuinely removes the file it wrote - GL-33's whole rule", &ok)

        // A body with no heading gets one, or `DocsRunbookStore` reads the
        // display title back off the slug instead of the proposed title.
        let headless = StrawHatProposal(kind: .createRunbookDraft, title: "Rolling a secret",
                                        content: "Step one: revoke it.")
        guard case .written = StrawHatProposalExecutor.execute(headless, stores: .init(shift: shift, docs: docs), now: now) else {
            check(false, "a headingless body still saves", &ok)
            return
        }
        check(docs.listRunbooks().contains(where: { $0.title == "Rolling a secret" }),
              "...under the proposed title, because a `# ` heading was added", &ok)

        // A runbook proposal with nowhere to save fails visibly - the captain
        // pressed a button and is owed an answer either way.
        guard case .failed = StrawHatProposalExecutor.execute(draft, stores: .init(shift: shift, docs: nil), now: now) else {
            check(false, "a runbook draft with no docs store must fail visibly, not silently", &ok)
            return
        }
    }

    // MARK: Phase 3 (M3.1 / M3.2) - parsing the five new kinds

    /// Everything the parser must refuse, and everything it must derive.
    ///
    /// The refusals matter more than the acceptances here: three of the five
    /// new kinds carry a payload the app resolves against a *closed set*
    /// (`ScheduledActionKind`, `RailDestination`, the cadence grammar), and
    /// the whole point of resolving them at parse time is that an invented one
    /// produces no proposal at all rather than a card whose press has to
    /// guess.
    private static func checkPhase3Parsing(_ ok: inout Bool) {

        /// One section's proposals, from a bare envelope.
        func proposals(_ json: String, speaker: String = "zoro") -> (kept: [StrawHatProposal], dropped: Int) {
            let reply = "{\"sections\":[{\"speaker\":\"\(speaker)\",\"text\":\"x\",\"proposals\":[\(json)]}]}"
            guard case .envelope(let sections) = StrawHatEnvelope.parse(reply),
                  let only = sections.first else { return ([], 0) }
            return (only.proposals, only.droppedProposalCount)
        }

        // ---- add_sticky ----
        let sticky = proposals(#"{"kind":"add_sticky","title":"Board idea","notes":"the body"}"#, speaker: "usopp")
        check(sticky.kept.count == 1 && sticky.kept.first?.kind == .addSticky,
              "a sticky proposal parses, got \(sticky.kept.map(\.kind))", &ok)
        check(sticky.kept.first?.notes == "the body", "and carries its body", &ok)
        // A model writes `text` as readily as `notes` for a note's body.
        let stickyText = proposals(#"{"kind":"add_sticky","title":"T","text":"alt body"}"#, speaker: "usopp")
        check(stickyText.kept.first?.notes == "alt body",
              "a sticky's body is read from `text` as well as `notes`", &ok)

        // ---- save_command_draft ----
        let command = proposals(#"{"kind":"save_command_draft","title":"Restart login","command":"kubectl rollout restart deploy/login -n prod"}"#)
        check(command.kept.first?.command == "kubectl rollout restart deploy/login -n prod",
              "a command draft carries its template, got \(command.kept.first?.command ?? "nil")", &ok)
        // No command: nothing to derive, so no proposal.
        check(proposals(#"{"kind":"save_command_draft","title":"Named only"}"#).kept.isEmpty,
              "a command draft with no command is refused", &ok)
        // **Multi-line is refused before the captain ever sees a card**,
        // because `confirmAIAuthored` would refuse it at the gate anyway -
        // only the first line of a multi-line command is visible in that
        // alert, which is the whole reason that rule exists.
        let multiline = proposals("{\"kind\":\"save_command_draft\",\"title\":\"Two things\",\"command\":\"ls\\nrm -rf /\"}")
        check(multiline.kept.isEmpty && multiline.dropped == 1,
              "a multi-line command draft is refused and counted, got \(multiline.kept.count) kept", &ok)
        // A proposal can never carry a risk level - there is no field for one,
        // which is the structural half of audit #2 section 5.3's fix.
        check(command.kept.first.map { _ in true } == true,
              "the command draft parsed at all", &ok)

        // ---- create_schedule_draft ----
        let schedule = proposals(#"{"kind":"create_schedule_draft","action":"driftCheck","cadence":"daily 09:30"}"#, speaker: "franky")
        guard let onlySchedule = schedule.kept.first else {
            check(false, "a schedule draft with a real action and cadence must parse", &ok)
            return
        }
        check(onlySchedule.scheduleAction == .driftCheck,
              "the action resolves to the real enum, got \(onlySchedule.scheduleAction.map(\.rawValue) ?? "nil")", &ok)
        check(onlySchedule.scheduleCadence == .daily(hour: 9, minute: 30),
              "and the cadence to the real type, got \(onlySchedule.scheduleCadence?.displayString ?? "nil")", &ok)
        // Derived title - the model is not asked to name what the app names
        // better, and a blank title would be an unreadable card.
        check(onlySchedule.title == ScheduledActionKind.driftCheck.pickerTitle,
              "a schedule draft's title is derived from its action, got \(onlySchedule.title)", &ok)
        // snake_case, because a model writes it that way.
        check(proposals(#"{"kind":"create_schedule_draft","action":"tool_update_check","cadence":"nightly 02:00"}"#, speaker: "franky")
                .kept.first?.scheduleAction == .toolUpdateCheck,
              "a snake_case action still resolves", &ok)
        check(proposals(#"{"kind":"create_schedule_draft","action":"forkSync","cadence":"weekly monday 06:15"}"#, speaker: "franky")
                .kept.first?.scheduleCadence == .weekly(weekday: 2, hour: 6, minute: 15),
              "a weekly cadence resolves, Monday being Calendar's weekday 2", &ok)
        // **An invented automation cannot become a proposal.** This is the
        // security property of resolving at parse time rather than carrying a
        // string: the app has six unattended actions and no way to run a
        // seventh.
        check(proposals(#"{"kind":"create_schedule_draft","action":"deleteAllBackups","cadence":"daily 03:00"}"#, speaker: "franky")
                .kept.isEmpty,
              "an invented schedule action is refused", &ok)
        for bad in ["every day at nine", "daily", "daily 9", "daily 25:00", "weekly 06:00",
                    "weekly funday 06:00", "monthly 09:00", ""] {
            let parsed = proposals("{\"kind\":\"create_schedule_draft\",\"action\":\"driftCheck\",\"cadence\":\"\(bad)\"}", speaker: "franky")
            check(parsed.kept.isEmpty,
                  "the cadence grammar is strict - \"\(bad)\" must be refused, not guessed at", &ok)
        }

        // ---- open_destination ----
        let handoff = proposals(#"{"kind":"open_destination","destination":"logAnalyzer","notes":"paste the trace"}"#)
        guard case .destination(let dest, let hint)? = handoff.kept.first?.handoff else {
            check(false, "a destination handoff must parse into a real RailDestination", &ok)
            return
        }
        check(dest == .logAnalyzer, "...the one named, got \(dest.rawValue)", &ok)
        check(hint == "paste the trace", "and carries what to bring there", &ok)
        check(handoff.kept.first?.title.contains("Log Analyzer") == true,
              "its title is derived from the destination, got \(handoff.kept.first?.title ?? "nil")", &ok)
        check(proposals(#"{"kind":"open_destination","destination":"log_analyzer"}"#).kept.first?.handoff
                == .destination(.logAnalyzer, hint: nil),
              "a snake_case destination still resolves", &ok)
        // A destination that exists but is off the allowlist is refused
        // exactly like one that does not exist - and this is the one that
        // matters, because a link row runs on a single click.
        check(proposals(#"{"kind":"open_destination","destination":"poneglyph"}"#).kept.isEmpty,
              "a handoff to the credential vault is refused even though the destination is real", &ok)
        check(proposals(#"{"kind":"open_destination","destination":"settings"}"#).kept.isEmpty,
              "...and so is one to Settings", &ok)
        check(proposals(#"{"kind":"open_destination","destination":"middleEarth"}"#).kept.isEmpty,
              "...and one to a destination that does not exist at all", &ok)
        check(proposals(#"{"kind":"open_destination"}"#).kept.isEmpty,
              "a destination handoff with no destination is refused", &ok)

        // ---- open_sre_lead ----
        let sre = proposals(#"{"kind":"open_sre_lead","host":"prod-bastion"}"#)
        check(sre.kept.first?.handoff == .sreLead(hostHint: "prod-bastion"),
              "an SRE Lead handoff carries the host the captain named, got \(String(describing: sre.kept.first?.handoff))", &ok)
        // The hint is genuinely optional - the crew cannot see hosts, so a
        // conversation that never named one must still be able to hand off.
        check(proposals(#"{"kind":"open_sre_lead"}"#).kept.first?.handoff == .sreLead(hostHint: nil),
              "...and parses with no hint at all", &ok)
    }

    // MARK: Phase 3 - the three new writes, against real stores

    private static func checkPhase3Execution(_ ok: inout Bool) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-p3-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Every one of the four, narrowly: `CommandLibraryStore` and
        // `StickyBoardStore` both honour `FM_SHIFT_DIR` as a fallback and
        // would otherwise share this process's other cases' folders, and
        // `ScheduleStore` has only its own file override - a bare
        // `ScheduleStore()` reads this machine's **real** `schedules.json`,
        // which is exactly the hazard `main.swift`'s own redirect block
        // exists for.
        let saved = ["FM_SHIFT_DIR", "FM_STICKY_BOARD_DIR", "FM_COMMAND_LIBRARY_DIR", "FM_SCHEDULES_FILE"]
            .map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        setenv("FM_STICKY_BOARD_DIR", scratch.appendingPathComponent("sticky").path, 1)
        setenv("FM_COMMAND_LIBRARY_DIR", scratch.appendingPathComponent("commands").path, 1)
        setenv("FM_SCHEDULES_FILE", scratch.appendingPathComponent("schedules.json").path, 1)
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: scratch)
        }

        let shift = ShiftStore()
        let sticky = StickyBoardStore()
        let commands = CommandLibraryStore()
        let schedules = ScheduleStore()
        let stores = StrawHatProposalExecutor.Stores(
            shift: shift, docs: nil, sticky: sticky, commands: commands, schedules: schedules)

        // ---- add_sticky ----
        let stickyProposal = StrawHatProposal(kind: .addSticky, title: "Rate-limit idea",
                                              notes: "cap the retry loop")
        guard case .written(let stickyMessage, let stickyUndo) =
                StrawHatProposalExecutor.execute(stickyProposal, stores: stores) else {
            check(false, "confirming a sticky proposal must write it", &ok)
            return
        }
        check(stickyMessage.contains("Rate-limit idea"), "the toast names the note", &ok)
        guard let note = sticky.notes.first(where: { $0.title == "Rate-limit idea" }) else {
            check(false, "the note must actually be on the board", &ok)
            return
        }
        check(note.text == "cap the retry loop", "with its body, got \(note.text)", &ok)
        // Position, colour and tilt are the app's, and the position is the
        // *next free slot* rather than the origin - a proposed note stacked
        // under an existing one reads as a bug.
        check(note.x == Double(StickyBoardMetrics.cascadeOrigin(index: 0).x)
                && note.y == Double(StickyBoardMetrics.cascadeOrigin(index: 0).y),
              "a crew note lands where \"New Note\" would have put it, got (\(note.x), \(note.y))", &ok)
        // Reached disk, not just the array - the board debounces its own
        // writes 1.5s and a confirmed proposal must not wait on that.
        check(StickyBoardStore().notes.contains(where: { $0.title == "Rate-limit idea" }),
              "a confirmed note must survive a fresh store - otherwise it never reached disk", &ok)
        guard let undoSticky = stickyUndo else {
            check(false, "a sticky note DOES get an undo - `deleteNote`/`restoreNote` both exist", &ok)
            return
        }
        undoSticky()
        check(!StickyBoardStore().notes.contains(where: { $0.title == "Rate-limit idea" }),
              "and that undo genuinely removes it from disk", &ok)

        // A second note goes in the *next* slot, which is what makes the
        // cascade real rather than a constant.
        _ = StrawHatProposalExecutor.execute(
            StrawHatProposal(kind: .addSticky, title: "First"), stores: stores)
        _ = StrawHatProposalExecutor.execute(
            StrawHatProposal(kind: .addSticky, title: "Second"), stores: stores)
        let first = sticky.notes.first { $0.title == "First" }
        let second = sticky.notes.first { $0.title == "Second" }
        check(first != nil && second != nil && (first!.x != second!.x || first!.y != second!.y),
              "two crew notes must not land on top of each other", &ok)

        // ---- create_schedule_draft ----
        let scheduleProposal = StrawHatProposal(kind: .createScheduleDraft,
                                                title: "ignored - derived",
                                                scheduleAction: .driftCheck,
                                                scheduleCadence: .daily(hour: 9, minute: 0))
        let before = schedules.schedules.count
        guard case .written(let scheduleMessage, let scheduleUndo) =
                StrawHatProposalExecutor.execute(scheduleProposal, stores: stores) else {
            check(false, "confirming a schedule draft must write it", &ok)
            return
        }
        check(scheduleMessage.contains("Daily at 9:00 AM"),
              "the toast names the cadence, got \(scheduleMessage)", &ok)
        guard let written = schedules.schedules.last, schedules.schedules.count == before + 1 else {
            check(false, "the schedule must actually be in the store", &ok)
            return
        }
        check(written.action == .driftCheck, "with its action", &ok)
        check(written.isEnabled, "enabled, exactly as the Schedule Editor's own Save leaves it", &ok)
        check(written.notifyOn == .changeOnly,
              "and quiet-until-it-matters, which is the app's default rather than the model's choice", &ok)
        // `ScheduleStore.add` seeds this so a nightly job confirmed at 15:00
        // means "starting tonight" rather than "and also right now".
        check(written.lastFiredOccurrence != nil,
              "its first occurrence is seeded, or it would fire the instant it was saved", &ok)
        check(ScheduleStore().schedules.contains(where: { $0.id == written.id }),
              "a confirmed schedule must survive a fresh store", &ok)
        guard let undoSchedule = scheduleUndo else {
            check(false, "a schedule draft DOES get an undo - `delete(id:)` and the id are both in hand", &ok)
            return
        }
        undoSchedule()
        check(!ScheduleStore().schedules.contains(where: { $0.id == written.id }),
              "and that undo genuinely removes it", &ok)

        // ---- save_command_draft: the write half only ----
        //
        // `execute` runs `confirmAIAuthored`, an `NSAlert.runModal()` that a
        // headless suite cannot answer, so the *behaviour* is driven through
        // `commitCommandDraft` directly and the *routing* is asserted by
        // `checkCommandDraftGate`'s source guard. Both halves are needed: the
        // write being right proves nothing about the gate still being in
        // front of it.
        let draft = StrawHatProposal(kind: .saveCommandDraft, title: "Tail the login logs",
                                     notes: "follows the deployment",
                                     command: "kubectl logs -f deploy/login -n prod")
        guard case .written(let commandMessage, let commandUndo) = StrawHatProposalExecutor.commitCommandDraft(
                draft, command: draft.command ?? "", commands: commands) else {
            check(false, "committing a command draft must write it", &ok)
            return
        }
        guard let savedCommand = commands.commands.first(where: { $0.name == "Tail the login logs" }) else {
            check(false, "the command must actually be in the library", &ok)
            return
        }
        check(savedCommand.commandTemplate == "kubectl logs -f deploy/login -n prod",
              "with its exact template, got \(savedCommand.commandTemplate)", &ok)
        check(savedCommand.category == StrawHatProposalExecutor.crewCommandCategory,
              "in the crew's own folder rather than a category a model named, got \(savedCommand.category)", &ok)
        // **The load-bearing assertion of this whole kind.** Audit #2 section
        // 5.3: a stored `.readOnly` is a human's vouch, every later sink reads
        // the stored level instead of asking again, and `heuristicRisk` never
        // answers `.readOnly` - so a crew-authored command can never be
        // stale-low at the detail pane, the palette, or F9's fan-out.
        check(savedCommand.risk != .readOnly,
              "a crew-authored command must never be stored as readOnly - nobody vouched for it", &ok)
        check(savedCommand.risk == CommandRiskConfirmation.heuristicRisk(of: savedCommand.commandTemplate),
              "and its level is the heuristic's, got \(savedCommand.risk.rawValue)", &ok)
        check(commandMessage.contains(savedCommand.risk.displayName),
              "the toast says how it was classified, got \(commandMessage)", &ok)
        // A genuinely destructive template is classified as such rather than
        // taking the floor.
        let destructive = StrawHatProposal(kind: .saveCommandDraft, title: "Wipe the cache",
                                           command: "rm -rf /var/cache/app")
        _ = StrawHatProposalExecutor.commitCommandDraft(destructive, command: destructive.command ?? "",
                                                        commands: commands)
        check(commands.commands.first(where: { $0.name == "Wipe the cache" })?.risk == .destructive,
              "a destructive template is stored destructive", &ok)
        guard let undoCommand = commandUndo else {
            check(false, "a command draft DOES get an undo - `deleteCommand(id:)` removes the file", &ok)
            return
        }
        undoCommand()
        check(!CommandLibraryStore().commands.contains(where: { $0.name == "Tail the login logs" }),
              "and that undo genuinely removes it", &ok)

        // ---- a missing store fails visibly, never silently ----
        let bare = StrawHatProposalExecutor.Stores(shift: shift)
        for proposal in [StrawHatProposal(kind: .addSticky, title: "nowhere"),
                         StrawHatProposal(kind: .saveCommandDraft, title: "nowhere", command: "ls"),
                         StrawHatProposal(kind: .createScheduleDraft, title: "nowhere",
                                          scheduleAction: .driftCheck,
                                          scheduleCadence: .daily(hour: 1, minute: 0))] {
            guard case .failed = StrawHatProposalExecutor.execute(proposal, stores: bare) else {
                check(false, "\(proposal.kind.rawValue) with no store must fail visibly, not silently", &ok)
                continue
            }
        }
    }

    /// The routing half of `save_command_draft`'s gate.
    ///
    /// A source guard, because a modal cannot be answered from a headless
    /// suite and because the write being correct is *invisible* to whether the
    /// gate is still in front of it - which is exactly how audit #2 section
    /// 5.3's original defect shipped one store over.
    private static func checkCommandDraftGate(_ ok: inout Bool) {
        guard let sources = SelfTestSources.appSourceDirectory() else {
            print("  NOTE: source tree not reachable - skipping the command-draft gate source guard")
            return
        }
        let path = sources.appendingPathComponent("StrawHatProposalExecutor.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            check(false, "could not read StrawHatProposalExecutor.swift", &ok)
            return
        }
        // Whole-line comments stripped first: this file's own header explains
        // the gate by name, and a guard that trips on the comment documenting
        // it is a guard nobody can keep.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        check(code.contains("CommandRiskConfirmation.confirmAIAuthored"),
              "the executor must still run the AI-authored gate before saving a command", &ok)
        check(code.contains("intent: .saveTemplate"),
              "...with the save intent, whose wording is about letting text into the library", &ok)
        // Exactly one production caller of the write, and it is inside the
        // function that confirms. Two callers would mean one of them could
        // skip the alert.
        let callers = code.components(separatedBy: "commitCommandDraft(").count - 1
        check(callers == 2,
              "commitCommandDraft must be declared once and called from exactly one place, found \(callers) mentions", &ok)
        guard let gateRange = code.range(of: "func saveCommandDraft"),
              let confirmRange = code.range(of: "CommandRiskConfirmation.confirmAIAuthored"),
              let commitRange = code.range(of: "outcome = commitCommandDraft(") else {
            check(false, "the gate and the write must both live in `saveCommandDraft`", &ok)
            return
        }
        check(gateRange.lowerBound < confirmRange.lowerBound
                && confirmRange.lowerBound < commitRange.lowerBound,
              "the confirmation has to come before the write, not after it", &ok)
        // And the risk level is re-derived rather than trusted.
        check(code.contains("CommandRiskConfirmation.heuristicRisk(of: command)"),
              "the stored risk must be re-derived from the text, never taken from the model", &ok)
        check(!code.contains("risk: .readOnly"),
              "a crew-authored command must never be stored readOnly", &ok)
    }

    /// The *production* half of that same gate, since `fm/straw-hat-task-
    /// proposal-full-editor`: `save_command_draft` now routes through
    /// `StrawHatController.openCommandEditor` (see `StrawHatProposalExecutor.
    /// swift`'s header - `execute` is never called for this kind from the
    /// confirm-card flow any more), so the check above alone would leave the
    /// *real* gate unguarded - it only asserts the old, now production-dead
    /// path still has its own internal structure right.
    ///
    /// Same reasoning as `checkCommandDraftGate`: a modal cannot be answered
    /// from a headless suite, and a correctly pre-filled editor proves nothing
    /// about whether the captain was asked to read the raw command text
    /// first, so this is a source guard too.
    private static func checkEditorRoutingCommandGate(_ ok: inout Bool) {
        guard let sources = SelfTestSources.appSourceDirectory() else {
            print("  NOTE: source tree not reachable - skipping the editor-routing command gate source guard")
            return
        }
        guard let text = try? String(contentsOf: sources.appendingPathComponent("StrawHatController.swift"), encoding: .utf8) else {
            check(false, "could not read StrawHatController.swift", &ok)
            return
        }
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        guard let gateRange = code.range(of: "func openCommandEditor") else {
            check(false, "openCommandEditor is gone - a crew-authored command has no route to the library at all", &ok)
            return
        }
        let body = code[gateRange.lowerBound...]
        guard let confirmRange = body.range(of: "CommandRiskConfirmation.confirmAIAuthored"),
              let presentRange = body.range(of: "presentAsSheet(editor)") else {
            check(false, "openCommandEditor must both gate with confirmAIAuthored and present the pre-filled editor", &ok)
            return
        }
        check(confirmRange.lowerBound < presentRange.lowerBound,
              "the AI-authored gate has to run before the editor ever opens, not after", &ok)
        check(body.contains("intent: .saveTemplate"),
              "...with the save intent, not the run intent a shell send would use", &ok)
        // The editor is what lets the captain change everything else; the
        // heuristic only has to seed a starting point.
        check(body.contains("CommandRiskConfirmation.heuristicRisk(of: command)"),
              "the prefilled risk must still come from the text, never invented", &ok)
    }

    // MARK: Harness

    private struct Outcome: CustomStringConvertible {
        let reply: String?
        let failure: String?
        var description: String { reply.map { "success(\($0))" } ?? "failure(\(failure ?? "?"))" }
    }

    /// Drives `ask` and waits for its completion by pumping the main run loop
    /// - `ClaudeOneShot` always completes via `DispatchQueue.main.async`, and
    /// this suite runs before `NSApplication.run()`, so a semaphore would
    /// deadlock against the very block being waited on. Same convention as
    /// `ConsoleCommandComposerSelfTest.runGenerateSync`.
    private static func ask(_ runner: StrawHatRunner, _ message: String) -> Outcome {
        var outcome: Outcome?
        runner.ask(message) { result in
            switch result {
            case .success(let text): outcome = Outcome(reply: text, failure: nil)
            case .failure(let error): outcome = Outcome(reply: nil, failure: error.message)
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return outcome ?? Outcome(reply: nil, failure: "timed out waiting for the turn")
    }

    private static func scratchFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-\(name)-\(UUID().uuidString).log")
    }

    /// One argv element per line, so an element containing spaces or newlines
    /// still round-trips - which matters, because the persona and the recap
    /// are both multi-line.
    private static func readArgv(_ log: URL) -> [String] {
        guard let raw = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        // `printf '%s\0'` writes a NUL after each element; the last one leaves
        // a trailing empty component.
        var parts = raw.components(separatedBy: "\0")
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    /// The same argv with the ~2.5KB persona collapsed to a marker. A failure
    /// message that dumps the whole persona buries the one thing it is trying
    /// to say - found the first time an injected regression was verified here.
    private static func printableArgv(_ log: URL) -> [String] {
        readArgv(log).map { $0 == StrawHatCrew.persona ? "<persona>" : $0 }
    }

    private static func fakeClaudePayload(reply: String, sessionID: String?) -> String {
        var obj: [String: Any] = ["result": reply, "is_error": false]
        if let sessionID { obj["session_id"] = sessionID }
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// A fake `claude` that records its own argv NUL-separated and prints one
    /// `--output-format json` payload.
    private static func writeFakeClaude(reply: String, argvLog: URL, sessionID: String? = nil) -> URL {
        let payload = fakeClaudePayload(reply: reply, sessionID: sessionID)
        return writeScript("""
        printf '%s\\0' "$@" > "\(argvLog.path)"
        printf '%s\\n' '\(shellSingleQuoted(payload))'
        exit 0
        """)
    }

    /// A fake `claude` that rejects any turn carrying `--resume` - a pruned or
    /// expired session, exactly as the real CLI reports it.
    private static func writeResumeRejectingClaude(reply: String, argvLog: URL) -> URL {
        let good = fakeClaudePayload(reply: reply, sessionID: "sess-recovered")
        let bad = fakeClaudePayload(reply: "No conversation found with session ID", sessionID: nil)
            .replacingOccurrences(of: "\"is_error\":false", with: "\"is_error\":true")
        return writeScript("""
        printf '%s\\0' "$@" > "\(argvLog.path)"
        for arg in "$@"; do
          if [ "$arg" = "--resume" ]; then
            printf '%s\\n' '\(shellSingleQuoted(bad))'
            exit 1
          fi
        done
        printf '%s\\n' '\(shellSingleQuoted(good))'
        exit 0
        """)
    }

    private static func writeRawClaude(stdout: String, exitCode: Int32) -> URL {
        writeScript("""
        printf '%s' '\(shellSingleQuoted(stdout))'
        exit \(exitCode)
        """)
    }

    private static func shellSingleQuoted(_ raw: String) -> String {
        raw.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func writeScript(_ body: String) -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-strawhat-\(UUID().uuidString).sh")
        try? "#!/bin/sh\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }
}

#endif
