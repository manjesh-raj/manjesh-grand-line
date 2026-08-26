// Manjesh Grand Line - native macOS app.
//
// The Whiteboard's AI half: one plain-English description in, a real diagram on
// the canvas out.
//
// This is the sixth caller of `ClaudeOneShot` (GL-26's shared
// `claude -p ... --output-format json` runner) and adds no new invocation shape -
// see `ConsoleCommandComposer.swift`, the closest sibling, for the convention
// this follows verbatim: the caller resolves `claude` through
// `SRELead.resolveClaude()` behind its own `claudePathOverrideForTests` seam,
// bounds the wait, and treats every failure as "show it and let the captain
// retry" rather than anything fatal.
//
// ## Why the *skeleton* format, and not Excalidraw's real element shape
//
// A full Excalidraw element carries a dozen derived fields a model has no
// business inventing - `id`, `seed`, `version`, `versionNonce`, `updated`,
// `boundElements`, `containerId`, `frameId`, plus the arrow/label binding
// bookkeeping that has to agree across elements. Excalidraw publishes
// `convertToExcalidrawElements()` precisely so a host can hand it a small
// "skeleton" and let the library fill all of that in, and that is what the page
// side calls (`whiteboard.js`). So the prompt asks for the skeleton: a small,
// documented surface where the only things the model can get wrong are things
// this file can actually check.
//
// ## What is validated here, and why each check exists
//
//  - **It has to be JSON, and it has to be a list of objects.** A prose reply
//    or a half-written array is a clean failure, never a partially-loaded board.
//  - **Every element's `type` has to be one this app allows.** The list is
//    deliberately narrower than Excalidraw's own: `image` needs a `fileId` that
//    only exists for a file already in the scene, and `embeddable`/`iframe`
//    exist to load a remote URL - which the page's CSP blocks anyway, so
//    accepting one would only produce a broken box. Refusing up front says why.
//  - **A bounded element count.** A model that misreads "diagram" as "draw me a
//    city" should not be able to hand the canvas ten thousand elements.
//  - **A "frame" element's "children" list.** `convertToExcalidrawElements()`
//    requires every frame to name the ids of the elements it groups, calls
//    `.forEach` on that field with no nil guard, and never infers membership
//    from position - a frame with no "children" key crashes the library with
//    a raw JS TypeError, reproduced live from a real captain report
//    (`fm/grand-line-whiteboard-generate-crash`). Caught here so it never
//    reaches the page at all.
//
// Everything past that is genuinely Excalidraw's own business: a skeleton that
// converts cleanly renders. But "the model got something else wrong that this
// file cannot enumerate in advance" is a real possibility too, so `loadScene`
// in `whiteboard.js` wraps its own call to `convertToExcalidrawElements` in a
// second try/catch and never lets whatever comes out of *that* - a raw
// internal JS error - reach the bridge reply verbatim. A skeleton this file
// rejects gets one of the specific messages below; anything that gets past
// this file and still fails inside the library gets a generic, always-
// actionable one instead. Neither path can put raw JS crash text in front of
// the captain.

import Foundation

struct WhiteboardDiagramError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum WhiteboardDiagram {

    /// Bounded like every other `ClaudeOneShot` caller. A diagram is a bigger
    /// ask than a one-line shell command (`ConsoleCommandComposer`'s 20s) and a
    /// far smaller one than a whole log analysis (`LogAnalyzerAI`'s 120s).
    static let timeout: TimeInterval = 60

    /// The most elements one generation may put on the board. Generous enough
    /// for a real architecture diagram, small enough that a runaway reply
    /// cannot wedge the canvas.
    static let maxElements = 300

    /// The skeleton element types a generated diagram may use. See this file's
    /// header for why `image`, `embeddable`, `iframe` and `selection` are not
    /// in it.
    static let allowedTypes: Set<String> = [
        "rectangle", "diamond", "ellipse", "arrow", "line", "text", "frame", "freedraw",
    ]

    /// Test-only seam, same convention as
    /// `ConsoleCommandComposer.claudePathOverrideForTests`.
    static var claudePathOverrideForTests: String?

    // MARK: Prompt

    static func prompt(for description: String) -> String {
        """
        You produce diagrams for Excalidraw. Reply with ONLY a JSON array of \
        Excalidraw "element skeleton" objects - no prose, no explanation, no \
        markdown code fence.

        A skeleton element is a small object; Excalidraw fills in every derived \
        field (id, seed, versions, bindings) itself, so do not invent those. \
        Use only these element types: rectangle, diamond, ellipse, arrow, line, \
        text, frame.

        Shapes: {"type":"rectangle","x":0,"y":0,"width":200,"height":100,\
        "label":{"text":"API gateway"}}. The optional "label" binds text inside \
        the shape and is how you put a caption in a box - do not overlay a \
        separate text element on a shape.

        Standalone text: {"type":"text","x":0,"y":0,"text":"Ingress","fontSize":20}.

        Arrows between shapes: give the two shapes an "id" of your own choosing \
        and bind the arrow to them, so the arrow follows if a shape is moved: \
        {"type":"arrow","x":210,"y":50,"width":80,"height":0,\
        "start":{"id":"gateway"},"end":{"id":"service"},"label":{"text":"HTTPS"}}.

        Frames group elements into a labelled boundary box (e.g. "Kubernetes \
        Cluster" around several pods). A frame MUST have a non-empty \
        "children" array naming the "id" of every element inside it - Excalidraw \
        does not infer membership from position, and never omit "children" or \
        leave it empty: {"type":"frame","id":"cluster","name":"Kubernetes \
        Cluster","children":["pod-a","pod-b"]}. If you are not grouping \
        elements, use a plain rectangle instead of a frame.

        Optional styling fields you may use: strokeColor and backgroundColor \
        (hex strings), fillStyle ("hachure"|"cross-hatch"|"solid"), \
        strokeWidth (1|2|4), roughness (0|1|2), roundness ({"type":3}) and \
        fontSize.

        Lay the diagram out yourself in absolute coordinates with x growing \
        right and y growing down, starting near 0,0. Leave at least 60px of gap \
        between shapes so arrows and labels have room, and keep the whole \
        diagram under \(maxElements) elements.

        Diagram to draw:
        \(description)
        """
    }

    // MARK: Parsing

    /// Turns a model reply into the element skeletons the page can load.
    ///
    /// Kept `internal` (not private) so the self-test can drive it directly
    /// against hand-built payloads - including the malformed ones a fake
    /// `claude` cannot easily produce.
    static func parse(_ text: String) -> Result<[[String: Any]], WhiteboardDiagramError> {
        let unwrapped = stripCodeFence(text)
        guard let data = unwrapped.data(using: .utf8) else {
            return .failure(WhiteboardDiagramError(message: "the reply could not be read as text"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(WhiteboardDiagramError(
                message: "the reply wasn't valid JSON, so there was nothing to draw. Try again, or reword it."))
        }

        // A model asked for "a JSON array" quite often replies with the array
        // wrapped in the object Excalidraw's own scene file uses. Both are
        // unambiguous, so both are accepted rather than refused on a technicality.
        let raw: [Any]
        if let array = json as? [Any] {
            raw = array
        } else if let object = json as? [String: Any],
                  let array = (object["elements"] ?? object["skeleton"]) as? [Any] {
            raw = array
        } else {
            return .failure(WhiteboardDiagramError(
                message: "the reply was JSON but not a list of elements."))
        }

        guard !raw.isEmpty else {
            return .failure(WhiteboardDiagramError(message: "the reply had no elements in it."))
        }
        guard raw.count <= maxElements else {
            return .failure(WhiteboardDiagramError(
                message: "that came back as \(raw.count) elements, past the \(maxElements)-element limit. Try asking for something smaller."))
        }

        // Frame validation (below) needs to know every id the model declared
        // anywhere in the reply - a frame's own "children" list names the ids
        // of *sibling* elements, so the full set has to be known before any
        // one frame can be checked against it.
        var declaredIDs: Set<String> = []
        for entry in raw {
            if let element = entry as? [String: Any], let id = element["id"] as? String, !id.isEmpty {
                declaredIDs.insert(id)
            }
        }

        var elements: [[String: Any]] = []
        elements.reserveCapacity(raw.count)
        for (index, entry) in raw.enumerated() {
            guard let element = entry as? [String: Any] else {
                return .failure(WhiteboardDiagramError(
                    message: "element \(index + 1) wasn't an object."))
            }
            guard let type = element["type"] as? String, !type.isEmpty else {
                return .failure(WhiteboardDiagramError(
                    message: "element \(index + 1) has no type."))
            }
            guard allowedTypes.contains(type) else {
                return .failure(WhiteboardDiagramError(
                    message: "element \(index + 1) is a \"\(type)\", which this whiteboard doesn't generate."))
            }
            // `convertToExcalidrawElements` requires every "frame" (and
            // "magicframe", which is not in `allowedTypes` at all) skeleton
            // element to carry a "children" array naming the elements it
            // contains - it never infers membership from position, and it
            // calls `.forEach` on that field with no nil guard. A frame with
            // no "children" key throws a raw JS TypeError deep inside the
            // library ("undefined is not an object (evaluating
            // 'o.children.forEach')") - reproduced live from a real captain
            // report, root-caused by reading the vendored bundle's own
            // frame-processing loop. Caught here so a malformed frame is
            // refused with a real message before it ever reaches the page.
            if type == "frame" {
                guard let children = element["children"] as? [Any], !children.isEmpty else {
                    return .failure(WhiteboardDiagramError(
                        message: "element \(index + 1) is a frame with no \"children\" list. A frame has to name the ids of the elements inside it - give it a \"children\" array, or use a plain rectangle instead."))
                }
                guard let childIDs = children as? [String], !childIDs.contains(where: { $0.isEmpty }) else {
                    return .failure(WhiteboardDiagramError(
                        message: "element \(index + 1)'s frame \"children\" list has an entry that isn't a real id."))
                }
                let selfID = element["id"] as? String
                guard childIDs.allSatisfy({ declaredIDs.contains($0) && $0 != selfID }) else {
                    return .failure(WhiteboardDiagramError(
                        message: "element \(index + 1)'s frame \"children\" list names an id that isn't any other element in the diagram."))
                }
            }
            elements.append(sanitized(element))
        }
        return .success(elements)
    }

    /// S5: strip the fields a diagram has no business carrying.
    ///
    /// `parse` allowlisted `type` and validated the frame's `children`, then
    /// appended the *whole* dictionary - so every other string the model wrote
    /// (`text`, `label.text`, `link`, `fontFamily`, `strokeColor`) reached
    /// `convertToExcalidrawElements` verbatim. Excalidraw elements support a
    /// `link` property that becomes a clickable hyperlink, and a prompt-injected
    /// model could emit `"link":"javascript:…"`.
    ///
    /// That was safe in practice and safe by *accident*: the offline CSP blocks
    /// execution, and with no `WKUIDelegate` an external link's `window.open`
    /// returns nil. Both are true because nobody has added a UI delegate yet -
    /// which is not a property to rely on. `link` is dropped outright (this app
    /// generates diagrams, not link targets) and, for anything else that ever
    /// carries a URI, a `javascript:`/`data:`/`vbscript:` scheme is refused - so
    /// the class is closed by construction rather than by omission.
    private static func sanitized(_ element: [String: Any]) -> [String: Any] {
        var out = element
        out.removeValue(forKey: "link")
        for (key, value) in out {
            guard let text = value as? String, hasDangerousScheme(text) else { continue }
            out.removeValue(forKey: key)
        }
        if var label = out["label"] as? [String: Any] {
            label.removeValue(forKey: "link")
            for (key, value) in label {
                guard let text = value as? String, hasDangerousScheme(text) else { continue }
                label.removeValue(forKey: key)
            }
            out["label"] = label
        }
        return out
    }

    /// Scheme check on the *value*, deliberately not a substring search: a
    /// perfectly ordinary label may talk about JavaScript.
    static func hasDangerousScheme(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{0000}", with: "")
            .lowercased()
        return ["javascript:", "data:", "vbscript:", "file:"].contains { trimmed.hasPrefix($0) }
    }

    /// Defensive only, exactly as `ConsoleCommandComposer.stripWrappingFormatting`
    /// frames it: the prompt asks for no fence, and a model adds one anyway
    /// often enough to be worth two lines here rather than a failure the
    /// captain has to retry through.
    private static func stripCodeFence(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Generation

    /// Generates a diagram. `completion` is called on the main thread exactly
    /// once. A failure is always a message worth showing - never a reason to
    /// touch the board.
    static func generate(description: String,
                         completion: @escaping (Result<[[String: Any]], WhiteboardDiagramError>) -> Void) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(WhiteboardDiagramError(message: "describe the diagram you want")))
            return
        }
        guard let claude = claudePathOverrideForTests ?? SRELead.resolveClaude() else {
            completion(.failure(WhiteboardDiagramError(message: "claude is not installed or not on PATH")))
            return
        }
        ClaudeOneShot.run(executable: claude, prompt: prompt(for: trimmed),
                          timeout: timeout, label: "claude -p (whiteboard)") { result in
            switch result {
            case .success(let reply):
                completion(parse(reply.text))
            case .failure(let error):
                completion(.failure(WhiteboardDiagramError(message: error.message)))
            }
        }
    }
}
