// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for the Whiteboard's deterministic
// text-to-diagram layer (`fm/grandline-devops-space-and-diagram-tool`).
//
// This one **runs in CI**, unlike its AI sibling: `WhiteboardSelfTest`'s
// generation cases need a fake `claude` on disk, and this file's whole subject
// is that no such thing is involved. `DiagramDSL.build` is a pure function -
// text in, element skeletons out - so every case here is an ordinary value
// assertion with no window, no subprocess and no network.
//
// What is worth asserting, and why each case exists:
//
//  - **The parse itself**, including the two things a local parser can do that
//    a model cannot: refuse with a line number, and produce byte-identical
//    output twice for the same input.
//  - **The layout**, at the level the layout actually promises. Not "the box is
//    at x=137" - that is the arithmetic restating itself - but the properties a
//    captain would notice breaking: ranks below their inputs, nothing
//    overlapping, messages evenly spaced in DSL order.
//  - **The invariant that keeps this usable at all**: every element type this
//    generator emits has to be in `WhiteboardDiagram.allowedTypes`, or the page
//    refuses a diagram that took no model call to produce and the whole
//    fast-path is a dead end.
//  - **A source guard that no `claude` call has crept in.** The value of this
//    feature is that it is instant and repeatable; a single `ClaudeOneShot`
//    call would still *work*, which is exactly why no behavioural test would
//    notice it.
//
// `FM_RUN_WHITEBOARD_DSL_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum WhiteboardDSLSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                ok = false
            }
        }

        checkFlowchartParsing(check)
        checkLabelledEdge(check)
        checkFlowchartLayout(check)
        checkChainsAndCycles(check)
        checkSequenceSpacing(check)
        checkSequenceReplyStyle(check)
        checkComponentLibrary(check)
        checkComponentInsertion(check)
        checkErrors(check)
        checkLimits(check)
        checkAllowedTypesInvariant(check)
        checkDeterminism(check)
        checkNoModelCall(check)
        checkToolbarSymbol(check)
        checkPopoverLiveParse(check)
        checkPopoverInsert(check)
        checkPaletteNeverReplaces(check)
        checkPreviewRenders(check)
        checkPopoverTheming(check)
        checkControllerWiring(check)

        print(ok ? "WhiteboardDSLSelfTest: OK" : "WhiteboardDSLSelfTest: FAILURES")
        return ok
    }

    // MARK: Helpers

    private static func built(_ text: String, _ mode: DiagramDSL.Mode,
                              _ check: (Bool, String) -> Void,
                              _ what: String) -> DiagramDSL.Diagram? {
        switch DiagramDSL.build(text, mode: mode) {
        case .success(let diagram): return diagram
        case .failure(let error):
            check(false, "\(what): expected a diagram, got \"\(error.description)\"")
            return nil
        }
    }

    private static func failure(_ text: String, _ mode: DiagramDSL.Mode,
                                _ check: (Bool, String) -> Void,
                                _ what: String) -> DiagramDSLError? {
        switch DiagramDSL.build(text, mode: mode) {
        case .success:
            check(false, "\(what): expected a failure, got a diagram")
            return nil
        case .failure(let error): return error
        }
    }

    private static func elements(_ diagram: DiagramDSL.Diagram, ofType type: String) -> [[String: Any]] {
        diagram.elements.filter { ($0["type"] as? String) == type }
    }

    private static func labelText(_ element: [String: Any]) -> String? {
        (element["label"] as? [String: Any])?["text"] as? String
    }

    // MARK: The simple case

    private static func checkFlowchartParsing(_ check: (Bool, String) -> Void) {
        guard let diagram = built("""
            Client --> LB
            LB --> ServiceA
            LB --> ServiceB
            ServiceA --> DB
            ServiceB --> DB
            """, .flowchart, check, "simple flowchart") else { return }

        let boxes = elements(diagram, ofType: "rectangle")
        let arrows = elements(diagram, ofType: "arrow")
        check(boxes.count == 5, "simple flowchart: expected 5 boxes, got \(boxes.count)")
        check(arrows.count == 5, "simple flowchart: expected 5 arrows, got \(arrows.count)")
        check(diagram.summary == "5 boxes, 5 arrows",
              "simple flowchart: summary read \"\(diagram.summary)\"")

        // Every distinct name becomes exactly one box, however many lines
        // mention it - `DB` appears on two lines and `LB` on three.
        let names = Set(boxes.compactMap { labelText($0) })
        check(names == ["Client", "LB", "ServiceA", "ServiceB", "DB"],
              "simple flowchart: boxes were \(names.sorted())")

        // Both arrow spellings mean the same thing in flowchart mode - the
        // whole point of picking the mode explicitly rather than inferring it.
        guard let short = built("Client -> LB", .flowchart, check, "short arrow") else { return }
        check(elements(short, ofType: "arrow").count == 1,
              "short arrow: `->` should be an edge in flowchart mode too")
        check(elements(short, ofType: "rectangle").count == 2,
              "short arrow: expected 2 boxes")
    }

    private static func checkLabelledEdge(_ check: (Bool, String) -> Void) {
        guard let diagram = built("Client --> Server: HTTPS", .flowchart, check, "labelled edge") else { return }
        let arrows = elements(diagram, ofType: "arrow")
        check(arrows.count == 1, "labelled edge: expected 1 arrow")
        check(labelText(arrows.first ?? [:]) == "HTTPS",
              "labelled edge: arrow label was \(labelText(arrows.first ?? [:]) ?? "nil")")
        // The label belongs to the arrow, never to either box.
        for box in elements(diagram, ofType: "rectangle") {
            check(labelText(box) != "HTTPS", "labelled edge: the edge label leaked onto a box")
        }

        // An arrow inside the label survives, because the label is peeled off
        // before anything is tokenised as an arrow. This is the case that
        // breaks if the two are ever done the other way round.
        guard let tricky = built("A --> B: maps a->b", .flowchart, check, "arrow in a label") else { return }
        check(elements(tricky, ofType: "rectangle").count == 2,
              "arrow in a label: expected 2 boxes, got \(elements(tricky, ofType: "rectangle").count)")
        check(labelText(elements(tricky, ofType: "arrow").first ?? [:]) == "maps a->b",
              "arrow in a label: the label was torn apart")

        // An unlabelled edge carries no label key at all, rather than an empty
        // one - an empty bound label renders as a stray text element.
        guard let bare = built("A --> B", .flowchart, check, "unlabelled edge") else { return }
        check(elements(bare, ofType: "arrow").first?["label"] == nil,
              "unlabelled edge: an arrow with no label should carry no label field")
    }

    // MARK: Layout

    private static func checkFlowchartLayout(_ check: (Bool, String) -> Void) {
        guard let diagram = built("""
            Client --> LB
            LB --> ServiceA
            LB --> ServiceB
            ServiceA --> DB
            ServiceB --> DB
            """, .flowchart, check, "layout") else { return }

        var byName: [String: DiagramDSL.PreviewBox] = [:]
        for box in diagram.boxes { byName[box.label] = box }
        guard let client = byName["Client"], let lb = byName["LB"],
              let a = byName["ServiceA"], let b = byName["ServiceB"],
              let db = byName["DB"] else {
            check(false, "layout: a box went missing")
            return
        }

        // Rank order: every node strictly below all of its inputs. This is the
        // property the ranking exists for; the exact pixel values are the
        // arithmetic restating itself and are deliberately not asserted.
        check(client.y < lb.y, "layout: LB should sit below Client")
        check(lb.y < a.y && lb.y < b.y, "layout: the services should sit below LB")
        check(a.y < db.y && b.y < db.y, "layout: DB should sit below both services")

        // A fan-out shares a rank, and `DB` takes the *longest* path - it has
        // two inputs at the same rank, so `max` and `first wins` agree here;
        // the case below where they disagree is the one that matters.
        check(a.y == b.y, "layout: ServiceA and ServiceB should share a rank")

        // Nothing overlaps. A layout that is merely "ranked" but stacks two
        // boxes on one another is not a layout.
        for (i, one) in diagram.boxes.enumerated() {
            for two in diagram.boxes[(i + 1)...] {
                let separated = one.x + one.width <= two.x || two.x + two.width <= one.x
                    || one.y + one.height <= two.y || two.y + two.height <= one.y
                check(separated, "layout: \"\(one.label)\" and \"\(two.label)\" overlap")
            }
        }

        // The longest path is what decides a rank, not the first edge to
        // arrive: `C` is reachable in one hop from `A` and in two via `B`, so
        // it has to land on rank 2 or the A->C arrow points sideways.
        let ranks = DiagramDSL.rankNodes(count: 3, edges: [(from: 0, to: 1), (from: 1, to: 2), (from: 0, to: 2)])
        check(ranks == [0, 1, 2], "layout: longest-path ranking gave \(ranks), expected [0, 1, 2]")
    }

    private static func checkChainsAndCycles(_ check: (Bool, String) -> Void) {
        guard let chain = built("A --> B --> C", .flowchart, check, "chain") else { return }
        check(elements(chain, ofType: "rectangle").count == 3, "chain: expected 3 boxes")
        check(elements(chain, ofType: "arrow").count == 2, "chain: expected 2 arrows")

        // A retry loop is an ordinary thing to draw, so a cycle lays out
        // rather than being refused. Kahn's algorithm ranks nothing here (every
        // node has an incoming edge), which is exactly the branch that would
        // otherwise return an empty or crashing layout.
        guard let cycle = built("""
            A --> B
            B --> C
            C --> A
            """, .flowchart, check, "cycle") else { return }
        check(elements(cycle, ofType: "rectangle").count == 3, "cycle: expected 3 boxes")
        check(elements(cycle, ofType: "arrow").count == 3, "cycle: expected 3 arrows")
        check(Set(cycle.boxes.map(\.y)).count == 3,
              "cycle: a cycle should still be spread over ranks, not collapsed into one row")

        // Chains bind each hop to the right pair, in order.
        let arrows = elements(chain, ofType: "arrow")
        let bindings = arrows.map { arrow -> String in
            let from = (arrow["start"] as? [String: Any])?["id"] as? String ?? "?"
            let to = (arrow["end"] as? [String: Any])?["id"] as? String ?? "?"
            return "\(from)->\(to)"
        }
        check(bindings == ["n0->n1", "n1->n2"], "chain: bindings were \(bindings)")
    }

    // MARK: Sequence

    private static func checkSequenceSpacing(_ check: (Bool, String) -> Void) {
        guard let diagram = built("""
            Client -> Server: request
            Server -> DB: query
            DB --> Server: rows
            Server --> Client: 200 OK
            """, .sequence, check, "sequence") else { return }

        let actors = elements(diagram, ofType: "rectangle")
        let lifelines = elements(diagram, ofType: "line")
        let messages = elements(diagram, ofType: "arrow")
        check(actors.count == 3, "sequence: expected 3 actors, got \(actors.count)")
        check(lifelines.count == 3, "sequence: expected one lifeline per actor, got \(lifelines.count)")
        check(messages.count == 4, "sequence: expected 4 messages, got \(messages.count)")
        check(diagram.summary == "3 actors, 4 messages",
              "sequence: summary read \"\(diagram.summary)\"")

        // Actors share the top row - that is what makes the lifelines line up.
        check(Set(actors.compactMap { $0["y"] as? Double }) == [0],
              "sequence: every actor box should sit on the top row")

        // The auto-spacing the captain asked for: message `i` is exactly one
        // step below message `i-1`, in the order the lines were written.
        let ys = messages.compactMap { $0["y"] as? Double }
        check(ys.count == 4, "sequence: a message lost its y")
        for (index, y) in ys.enumerated() where index > 0 {
            check(y - ys[index - 1] == DiagramDSL.messageSpacing,
                  "sequence: message \(index + 1) is \(y - ys[index - 1])pt below the last, expected \(DiagramDSL.messageSpacing)")
        }
        check(ys == ys.sorted(), "sequence: messages should run top to bottom in DSL order")

        // Every message is horizontal and lands on a lifeline, which is what
        // makes it readable as "A said this to B" rather than a loose arrow.
        let lifelineXs = Set(lifelines.compactMap { $0["x"] as? Double })
        for message in messages {
            check((message["height"] as? Double) == 0, "sequence: a message is not horizontal")
            let x = (message["x"] as? Double) ?? -1
            check(lifelineXs.contains(x), "sequence: a message starts at \(x), which is no lifeline")
        }

        // Messages are deliberately unbound: Excalidraw binds arrows to
        // shapes, and a lifeline is a `line`, so a binding would drag every
        // message up onto the actor box at the top.
        for message in messages {
            check(message["start"] == nil && message["end"] == nil,
                  "sequence: a message arrow should carry no binding")
        }
        // The lifelines reach past the last message, or the bottom one hangs
        // off the end of its own lifeline.
        let lastMessageY = ys.max() ?? 0
        for lifeline in lifelines {
            let bottom = ((lifeline["y"] as? Double) ?? 0) + ((lifeline["height"] as? Double) ?? 0)
            check(bottom > lastMessageY, "sequence: a lifeline stops above the last message")
        }
    }

    private static func checkSequenceReplyStyle(_ check: (Bool, String) -> Void) {
        guard let diagram = built("""
            Client -> Server: request
            Server --> Client: response
            """, .sequence, check, "reply style") else { return }
        let messages = elements(diagram, ofType: "arrow")
        check(messages.count == 2, "reply style: expected 2 messages")
        // `->` is a call, `-->` a reply. This is the one place the two
        // spellings differ, and it is mermaid's own convention - a styling
        // difference inside one element type, never a change of diagram kind.
        check((messages.first?["strokeStyle"] as? String) == "solid",
              "reply style: `->` should be a solid call")
        check((messages.last?["strokeStyle"] as? String) == "dashed",
              "reply style: `-->` should be a dashed reply")

        // A self-message has no second lifeline to land on and is drawn as a
        // stub rather than a zero-width arrow nobody can see.
        guard let selfMessage = built("Server -> Server: retry", .sequence, check, "self message") else { return }
        let stub = elements(selfMessage, ofType: "arrow").first ?? [:]
        check((stub["width"] as? Double) == DiagramDSL.selfMessageWidth,
              "self message: expected a \(DiagramDSL.selfMessageWidth)pt stub, got \(stub["width"] ?? "nil")")
        check(elements(selfMessage, ofType: "rectangle").count == 1,
              "self message: one actor, not two")
    }

    // MARK: The component library

    private static func checkComponentLibrary(_ check: (Bool, String) -> Void) {
        // Every component has to be reachable by its own keyword, or the
        // palette and the DSL disagree about what exists.
        for component in DiagramComponent.allCases {
            check(DiagramComponent.named(component.keyword) == component,
                  "component library: \"\(component.keyword)\" does not resolve back to \(component.rawValue)")
            check(component.aliases.contains(component.keyword),
                  "component library: \(component.rawValue)'s own keyword is not in its alias list")
            check(!component.emoji.isEmpty, "component library: \(component.rawValue) has no emoji")
            check(component.strokeColor.hasPrefix("#"),
                  "component library: \(component.rawValue)'s stroke is not a hex")
        }
        // No two components may answer to the same word, or `named` silently
        // resolves one of them and the other is unreachable.
        var seen: [String: String] = [:]
        for component in DiagramComponent.allCases {
            for alias in component.aliases {
                if let owner = seen[alias] {
                    check(false, "component library: \"\(alias)\" is claimed by both \(owner) and \(component.rawValue)")
                }
                seen[alias] = component.rawValue
            }
        }

        guard let diagram = built("lb(Ingress) --> k8s(api-pod) --> db(Postgres)",
                                  .flowchart, check, "typed nodes") else { return }
        let boxes = elements(diagram, ofType: "rectangle")
        check(boxes.count == 3, "typed nodes: expected 3 boxes")
        let strokes = Set(boxes.compactMap { $0["strokeColor"] as? String })
        check(strokes == [DiagramComponent.loadBalancer.strokeColor,
                          DiagramComponent.k8sPod.strokeColor,
                          DiagramComponent.database.strokeColor],
              "typed nodes: strokes were \(strokes.sorted())")
        // The emoji is the icon - there is no image element type this canvas
        // will accept, so the label carries it.
        check(boxes.contains { labelText($0)?.contains(DiagramComponent.database.emoji) == true },
              "typed nodes: the database box carries no emoji")
        // A hyphen in a name is not an arrow. `api-pod` has to survive whole.
        check(boxes.contains { labelText($0)?.contains("api-pod") == true },
              "typed nodes: \"api-pod\" was torn apart by the arrow tokeniser")

        // The name inside the brackets is the node's identity, so a bare
        // mention afterwards is the same node rather than a second box.
        guard let reused = built("""
            db(Postgres) --> Reports
            Ingest --> Postgres
            """, .flowchart, check, "typed node reuse") else { return }
        check(elements(reused, ofType: "rectangle").count == 3,
              "typed node reuse: expected 3 boxes, got \(elements(reused, ofType: "rectangle").count)")
        check(reused.boxes.contains { $0.strokeHex == DiagramComponent.database.strokeColor },
              "typed node reuse: the bare mention lost the declared type")

        // Typed actors work in sequence mode too.
        guard let sequence = built("actor(Captain) -> server(API): deploy", .sequence, check, "typed actors") else { return }
        check(elements(sequence, ofType: "rectangle").count == 2, "typed actors: expected 2 actors")
        check(sequence.boxes.contains { $0.strokeHex == DiagramComponent.actor.strokeColor },
              "typed actors: the actor kept no styling")
    }

    private static func checkComponentInsertion(_ check: (Bool, String) -> Void) {
        let one = DiagramDSL.component(.database, index: 0)
        check(one.elements.count == 1, "component insert: expected exactly 1 element")
        check((one.elements.first?["type"] as? String) == "rectangle",
              "component insert: a component is a rectangle, never an image")
        check(labelText(one.elements.first ?? [:]) == "\(DiagramComponent.database.emoji) Database",
              "component insert: label was \(labelText(one.elements.first ?? [:]) ?? "nil")")
        check((one.elements.first?["strokeColor"] as? String) == DiagramComponent.database.strokeColor,
              "component insert: the component lost its colour")
        check(one.summary == "1 box", "component insert: summary read \"\(one.summary)\"")

        // Clicking the same palette button twice must not stack two boxes in
        // exactly the same place - the cascade is what makes the second one
        // visible at all.
        let two = DiagramDSL.component(.database, index: 1)
        let firstX = one.boxes.first?.x ?? 0
        let secondX = two.boxes.first?.x ?? 0
        check(firstX != secondX || (one.boxes.first?.y ?? 0) != (two.boxes.first?.y ?? 0),
              "component insert: a second insert landed exactly on the first")

        // Every component in the palette inserts cleanly, so a button can
        // never be a dead end.
        for component in DiagramComponent.allCases {
            let diagram = DiagramDSL.component(component, index: 0)
            check(diagram.elements.count == 1, "component insert: \(component.rawValue) produced \(diagram.elements.count) elements")
            check((diagram.boxes.first?.width ?? 0) >= DiagramDSL.nodeMinWidth,
                  "component insert: \(component.rawValue) is narrower than the minimum")
        }
    }

    // MARK: Refusals

    private static func checkErrors(_ check: (Bool, String) -> Void) {
        // The thing a local parser can do that a model cannot: say *where*.
        if let error = failure("A --> B\nthis line is fine\nA --> ", .flowchart, check, "missing target") {
            check(error.line == 3, "missing target: reported line \(error.line.map(String.init) ?? "nil"), expected 3")
            check(error.description.hasPrefix("line 3:"), "missing target: description was \"\(error.description)\"")
        }
        if let error = failure("A --> nope(B)", .flowchart, check, "unknown component") {
            check(error.line == 1, "unknown component: reported line \(error.line.map(String.init) ?? "nil")")
            check(error.message.contains("nope"), "unknown component: the message does not name the word")
            check(error.message.contains(DiagramComponent.database.keyword),
                  "unknown component: the message should list what is available")
        }
        if let error = failure("A --> db(", .flowchart, check, "unclosed bracket") {
            check(error.message.contains("closing bracket"), "unclosed bracket: message was \"\(error.message)\"")
        }
        if let error = failure("A --> A", .flowchart, check, "self loop") {
            check(error.message.contains("itself"), "self loop: message was \"\(error.message)\"")
        }
        if let error = failure("   \n# just a comment\n", .flowchart, check, "empty input") {
            check(error.line == nil, "empty input: should have no line number")
            check(error.message.contains("Client --> Server"),
                  "empty input: the message should show what a line looks like")
        }
        // Comments and blank lines are skipped without shifting the line
        // numbers of everything after them - which is the one way a line
        // number becomes actively misleading rather than merely absent.
        if let error = failure("# heading\n\nA --> B\nA --> ", .flowchart, check, "line numbers past comments") {
            check(error.line == 4, "line numbers past comments: reported \(error.line.map(String.init) ?? "nil"), expected 4")
        }
    }

    private static func checkLimits(_ check: (Bool, String) -> Void) {
        // A pasted wall of text is refused for what it is, before the layout
        // pass runs over it.
        let tooManyLines = (0..<(DiagramDSL.maxLines + 1)).map { "A\($0) --> B\($0)" }.joined(separator: "\n")
        if let error = failure(tooManyLines, .flowchart, check, "line cap") {
            check(error.line == nil, "line cap: should be about the input as a whole")
            check(error.message.contains("\(DiagramDSL.maxLines)"), "line cap: the message should name the limit")
        }
        // And a compact input that still names too many boxes is refused on
        // its own terms - the two limits catch different things.
        let manyNodes = (0..<(DiagramDSL.maxNodes + 5)).map { "N\($0)" }.joined(separator: " --> ")
        if let error = failure(manyNodes, .flowchart, check, "node cap") {
            check(error.message.contains("\(DiagramDSL.maxNodes)"), "node cap: the message should name the limit")
        }
        // A diagram inside the limits stays inside `maxElements`, which is what
        // the page itself would otherwise refuse.
        let wide = (0..<40).map { "Root --> Leaf\($0)" }.joined(separator: "\n")
        if let diagram = built(wide, .flowchart, check, "wide fan-out") {
            check(diagram.elements.count <= WhiteboardDiagram.maxElements,
                  "wide fan-out: \(diagram.elements.count) elements, past the page's own cap")
        }
    }

    // MARK: Invariants

    private static func checkAllowedTypesInvariant(_ check: (Bool, String) -> Void) {
        // A type this generator emits that the page refuses would be a dead
        // end reached with no model call at all - the worst possible version of
        // this feature failing.
        var samples: [DiagramDSL.Diagram] = []
        if let a = built("lb(Ingress) --> k8s(API): HTTPS\nAPI --> db(Postgres)", .flowchart, check, "invariant flow") {
            samples.append(a)
        }
        if let b = built("actor(User) -> server(API): call\nAPI --> User: reply", .sequence, check, "invariant sequence") {
            samples.append(b)
        }
        samples.append(contentsOf: DiagramComponent.allCases.map { DiagramDSL.component($0, index: 0) })

        for diagram in samples {
            for element in diagram.elements {
                let type = (element["type"] as? String) ?? ""
                check(WhiteboardDiagram.allowedTypes.contains(type),
                      "invariant: generated a \"\(type)\", which WhiteboardDiagram.allowedTypes refuses")
                // Nothing this file writes may carry a link, and the page's own
                // sanitiser is aimed at model output rather than this path - so
                // the property is asserted here instead of inherited.
                check(element["link"] == nil, "invariant: a generated element carries a link")
            }
            // The skeleton has to survive the bridge, which is JSON.
            check(JSONSerialization.isValidJSONObject(diagram.elements),
                  "invariant: the generated skeleton is not JSON-serialisable")
        }
    }

    private static func checkDeterminism(_ check: (Bool, String) -> Void) {
        // The other half of the promise: the same text lays out identically
        // every time. A model cannot offer this, and a captain iterating on a
        // diagram would notice immediately if it stopped being true.
        let text = """
            lb(Ingress) --> k8s(API)
            API --> db(Postgres): read
            API --> queue(Events)
            """
        guard let first = built(text, .flowchart, check, "determinism a"),
              let second = built(text, .flowchart, check, "determinism b") else { return }
        let a = try? JSONSerialization.data(withJSONObject: first.elements, options: [.sortedKeys])
        let b = try? JSONSerialization.data(withJSONObject: second.elements, options: [.sortedKeys])
        check(a != nil && a == b, "determinism: the same DSL laid out differently twice")
    }

    private static func checkNoModelCall(_ check: (Bool, String) -> Void) {
        // A source guard, because the regression is invisible behaviourally: a
        // `claude` call added here would still produce a diagram, just slowly,
        // non-deterministically and offline-broken - and every case above would
        // keep passing.
        let root = SelfTestSources.appSourceDirectory()
        guard let root else {
            print("NOTE: could not locate the app's sources; skipping the no-model-call guard")
            return
        }
        let path = root.appendingPathComponent("WhiteboardDiagramDSL.swift")
        guard let source = try? String(contentsOf: path, encoding: .utf8) else {
            check(false, "no-model-call guard: could not read WhiteboardDiagramDSL.swift")
            return
        }
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for banned in ["ClaudeOneShot", "resolveClaude", "Subprocess", "URLSession", "Process("] {
            check(!code.contains(banned),
                  "no-model-call guard: WhiteboardDiagramDSL.swift mentions \(banned) - this layer has to stay local and instant")
        }
    }

    // MARK: The popover
    //
    // These are deliberately in this CI-runnable suite rather than a
    // window-backed one: none of them creates an `NSWindow`, because the
    // popover's content controller can be mounted, driven through its real
    // target/action handlers and rendered off-screen without one. Paying for a
    // session-only suite would have bought nothing here.

    private static func checkToolbarSymbol(_ check: (Bool, String) -> Void) {
        // `NSImage(systemSymbolName:)` returns nil *silently*, and this app has
        // shipped an invisible toolbar icon exactly that way before.
        let symbol = "point.topleft.down.to.point.bottomright.curvepath"
        check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
              "toolbar symbol: \"\(symbol)\" does not resolve")
        // And it has to be the one the page actually asks for, or the check
        // above is guarding a string nothing uses.
        guard let root = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: root.appendingPathComponent("WhiteboardController.swift"),
                                       encoding: .utf8) else { return }
        check(source.contains(symbol), "toolbar symbol: the page no longer uses \(symbol)")
    }

    private static func mountedPopover() -> WhiteboardDSLViewController {
        let controller = WhiteboardDSLViewController()
        // Forces `loadView`. The frame matters: the preview measures itself
        // against its own bounds, so a zero-sized view would render nothing and
        // the render check below would pass vacuously.
        controller.view.setFrameSize(NSSize(width: WhiteboardDSLViewController.width, height: 520))
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private static func checkPopoverLiveParse(_ check: (Bool, String) -> Void) {
        let popover = mountedPopover()

        // Empty: nothing to insert, and nothing shouted about either - an error
        // before the captain has typed anything is noise.
        check(!popover.debugInsertEnabled, "live parse: Insert should start disabled")
        check(popover.debugStatus.isEmpty, "live parse: an empty editor should say nothing")

        popover.debugSetText("Client --> LB\nLB --> DB")
        check(popover.debugInsertEnabled, "live parse: Insert should enable once the text parses")
        check(popover.debugPreviewBoxCount == 3,
              "live parse: the preview was handed \(popover.debugPreviewBoxCount) boxes, expected 3")
        check(popover.debugStatus == "3 boxes, 2 arrows",
              "live parse: status read \"\(popover.debugStatus)\"")
        check(!popover.debugStatusIsError, "live parse: a valid diagram should not read as an error")

        // The affordance the AI path cannot offer: a refusal that names the
        // line, live, before anything is sent anywhere.
        popover.debugSetText("Client --> LB\nLB --> ")
        check(!popover.debugInsertEnabled, "live parse: Insert should disable when the text stops parsing")
        check(popover.debugPreviewBoxCount == 0,
              "live parse: a broken diagram left \(popover.debugPreviewBoxCount) boxes in the preview")
        check(popover.debugStatusIsError, "live parse: a refusal should read as an error")
        check(popover.debugStatus.hasPrefix("line 2:"),
              "live parse: refusal read \"\(popover.debugStatus)\", expected it to name line 2")

        // Switching mode re-reads the same text: `->` is an edge in one mode
        // and a message in the other, and the picker is what decides.
        popover.debugSetText("Client -> Server: request")
        check(popover.debugStatus == "2 boxes, 1 arrow",
              "live parse: flowchart status read \"\(popover.debugStatus)\"")
        popover.debugSelectMode(.sequence)
        check(popover.debugMode == .sequence, "live parse: the mode did not change")
        check(popover.debugStatus == "2 actors, 1 message",
              "live parse: sequence status read \"\(popover.debugStatus)\"")
    }

    private static func checkPopoverInsert(_ check: (Bool, String) -> Void) {
        let popover = mountedPopover()
        var received: [[String: Any]] = []
        var appended: Bool?
        var calls = 0
        popover.onInsert = { elements, append, done in
            calls += 1
            received = elements
            appended = append
            done(nil)
        }

        // Nothing typed: no insert at all, rather than an empty one.
        popover.debugInsert()
        check(calls == 0, "insert: an empty editor should not reach the canvas")
        check(popover.debugStatusIsError, "insert: an empty insert should say why")

        popover.debugSetText("A --> B: go")
        popover.debugInsert()
        check(calls == 1, "insert: expected exactly one call, got \(calls)")
        check(appended == false, "insert: should replace by default, matching its AI sibling")
        check(received.count == 3, "insert: expected 3 elements, got \(received.count)")
        check(!popover.debugStatusIsError, "insert: a successful insert should not read as an error")
        check(popover.debugStatus.contains("2 boxes"), "insert: status read \"\(popover.debugStatus)\"")

        popover.debugSetAppend(true)
        popover.debugInsert()
        check(appended == true, "insert: the checkbox should reach the canvas")

        // A canvas-side refusal lands in the popover the captain is looking at,
        // rather than silently succeeding.
        popover.onInsert = { _, _, done in done("the canvas said no") }
        popover.debugInsert()
        check(popover.debugStatusIsError && popover.debugStatus == "the canvas said no",
              "insert: a canvas refusal read \"\(popover.debugStatus)\"")

        // An unwired sink has to answer too - the spinner is up until the
        // completion fires, so going quiet would hang the popover forever.
        popover.onInsert = nil
        popover.debugInsert()
        check(popover.debugStatusIsError, "insert: an unwired canvas should say so rather than go quiet")
        check(popover.debugInsertEnabled, "insert: the button should come back after a failure")
    }

    private static func checkPaletteNeverReplaces(_ check: (Bool, String) -> Void) {
        let popover = mountedPopover()
        var appends: [Bool] = []
        var payloads: [[[String: Any]]] = []
        popover.onInsert = { elements, append, done in
            appends.append(append)
            payloads.append(elements)
            done(nil)
        }

        // The safety property: a palette click must never wipe the board, even
        // with the replace-by-default checkbox off. The checkbox is about the
        // diagram the *text* describes; a component is always an addition.
        popover.debugSetAppend(false)
        // Through the real menu the button pops, so an item wired to nothing
        // fails here rather than rendering perfectly and doing nothing.
        let menu = popover.debugComponentMenu()
        check(menu.items.count == DiagramComponentCategory.allCases.count,
              "palette: expected \(DiagramComponentCategory.allCases.count) categories, got \(menu.items.count)")
        let leaves = menu.items.flatMap { $0.submenu?.items ?? [] }
        check(leaves.allSatisfy { $0.target != nil && $0.action != nil },
              "palette: a component item is wired to nothing")

        func leaf(_ component: DiagramComponent) -> NSMenuItem? {
            leaves.first { $0.representedObject as? String == component.rawValue }
        }
        guard let database = leaf(.database) else {
            check(false, "palette: no Database item")
            return
        }
        _ = database.target?.perform(database.action, with: database)
        check(appends == [true], "palette: a component insert must always append, got \(appends)")
        check(payloads.first?.count == 1, "palette: expected exactly one element")
        check(((payloads.first?.first?["label"] as? [String: Any])?["text"] as? String)?.contains("Database") == true,
              "palette: the wrong component was inserted")

        // Clicking twice cascades rather than stacking two boxes in one spot.
        _ = database.target?.perform(database.action, with: database)
        check(appends == [true, true], "palette: the second click did not append")
        let first = payloads.first?.first?["x"] as? Double
        let second = payloads.last?.first?["x"] as? Double
        check(first != second || (payloads.first?.first?["y"] as? Double) != (payloads.last?.first?["y"] as? Double),
              "palette: a second click landed exactly on the first")

        // Every component is reachable from the drop-down and every entry is
        // live - a component only findable by typing its keyword is one the
        // captain has no way to discover, and a drawer nobody can insert from
        // is worse than no drawer.
        var reached = Set<String>()
        popover.onInsert = { elements, _, done in
            if let label = (elements.first?["label"] as? [String: Any])?["text"] as? String {
                reached.insert(label)
            }
            done(nil)
        }
        for component in DiagramComponent.allCases {
            guard let item = leaf(component) else {
                check(false, "palette: \(component.rawValue) is in no category, so the drop-down cannot reach it")
                continue
            }
            _ = item.target?.perform(item.action, with: item)
            // The inserted label is "<emoji> <title>", so this matches on the
            // title rather than on set membership.
            check(reached.contains { $0.contains(component.title) },
                  "palette: picking \(component.rawValue) inserted nothing")
        }
    }

    private static func checkPreviewRenders(_ check: (Bool, String) -> Void) {
        // "The preview is wired up" and "the preview draws something" are
        // different claims, and only a real render can answer the second - a
        // view that silently draws nothing looks identical from every other
        // angle.
        let preview = DiagramPreviewView(frame: NSRect(x: 0, y: 0, width: 380, height: 132))
        preview.applyTheme(ThemeManager.shared.theme)

        func distinctTones(_ view: NSView) -> Int {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
            view.cacheDisplay(in: view.bounds, to: rep)
            var tones = Set<String>()
            for x in stride(from: 4, to: Int(view.bounds.width) - 4, by: 7) {
                for y in stride(from: 4, to: Int(view.bounds.height) - 4, by: 7) {
                    guard let colour = rep.colorAt(x: x, y: y) else { continue }
                    tones.insert(String(format: "%.2f,%.2f,%.2f",
                                        colour.redComponent, colour.greenComponent, colour.blueComponent))
                }
            }
            return tones.count
        }

        let blank = distinctTones(preview)
        check(blank >= 1, "preview: an empty preview rendered nothing at all (rep failed)")

        guard case .success(let diagram) = DiagramDSL.build("""
            lb(Ingress) --> k8s(API): HTTPS
            API --> db(Postgres)
            """, mode: .flowchart) else {
            check(false, "preview: the fixture stopped parsing")
            return
        }
        preview.show(diagram)
        let drawn = distinctTones(preview)
        check(drawn > blank,
              "preview: drawing a diagram changed nothing on screen (\(blank) tones before, \(drawn) after)")

        // A sequence diagram's lifelines run well below its boxes; a preview
        // that measured only the boxes would clip them off the bottom.
        guard case .success(let sequence) = DiagramDSL.build("""
            A -> B: one
            B -> C: two
            C --> A: three
            """, mode: .sequence) else {
            check(false, "preview: the sequence fixture stopped parsing")
            return
        }
        preview.show(sequence)
        check(distinctTones(preview) > blank, "preview: a sequence diagram rendered blank")
    }

    private static func checkPopoverTheming(_ check: (Bool, String) -> Void) {
        // Every theme, because the preview mixes app ink with component hues
        // and a panel that reads only in the light palettes would be a real
        // regression rather than a cosmetic one.
        let popover = mountedPopover()
        popover.debugSetText("db(Postgres) --> API")
        for theme in HelmTheme.allThemes {
            popover.applyTheme(theme)
            popover.view.layoutSubtreeIfNeeded()
            check(popover.view.layer?.backgroundColor != nil,
                  "theming: \(theme.id) left the popover with no background at all")
        }
        // Put the machine's own theme back: `applyTheme` does not persist
        // anything, but leaving the controller on an unrelated palette would
        // make a later case's reading confusing.
        popover.applyTheme(ThemeManager.shared.theme)
    }

    private static func checkControllerWiring(_ check: (Bool, String) -> Void) {
        // A source guard rather than a mounted page: constructing
        // `WhiteboardController` starts a real `WKWebView` and loads the whole
        // vendored bundle, which is `WhiteboardViewSelfTest`'s job and far more
        // than this needs. The regression worth catching is a popover that is
        // built, rendered and wired to nothing - which looks perfect from every
        // angle except the one where the captain presses Insert.
        guard let root = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: root.appendingPathComponent("WhiteboardController.swift"),
                                       encoding: .utf8) else {
            print("NOTE: could not locate the app's sources; skipping the wiring guard")
            return
        }
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        check(code.contains("dsl.onInsert"), "wiring: the DSL popover's sink is never connected to the canvas")
        check(code.contains("dslButton"), "wiring: the page has no button that opens the DSL popover")
        check(code.contains("dsl.close()"), "wiring: the DSL popover is never closed")
        // Both popovers write to the same board and both want the keyboard, so
        // opening one closes the other.
        check(code.contains("composer.close()"), "wiring: opening the DSL popover should close its AI sibling")
    }
}

#endif
