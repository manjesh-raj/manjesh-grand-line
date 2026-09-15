// Manjesh Grand Line - native macOS app.
//
// The seam between the generated artwork in `WhiteboardIcons.swift` and the
// canvas: what a component's icon is called on the board, and the file payload
// the bridge hands to `ExcalidrawAPI.addFiles`.
//
// Kept apart from the generated file so that file stays purely generated (it
// is rewritten wholesale by `Scripts/build-whiteboard-icons.py`), and apart
// from `WhiteboardDiagramDSL.swift` so the layout code never has to know what
// a data URL is.

import Foundation

enum WhiteboardIconLibrary {

    /// The size an icon is drawn at on the canvas. The artwork is 56pt square;
    /// 44 leaves the chip reading clearly at 100% zoom while keeping the node
    /// box short enough that a row of them still fits a screen.
    static let size: Double = 44

    /// Stable across inserts *and* across app launches, which is the whole
    /// point: Excalidraw keys its file cache by this id, so re-inserting the
    /// same component reuses artwork the scene already holds rather than
    /// growing the board with a second copy of identical bytes.
    ///
    /// Derived from `DiagramComponent.keyword`, which is already the
    /// identifier the DSL and every saved board use, so an icon cannot end up
    /// keyed to something that renames independently of the component.
    static func fileID(for component: DiagramComponent) -> String {
        "gl-icon-\(component.keyword)"
    }

    static func hasArtwork(_ component: DiagramComponent) -> Bool {
        WhiteboardIcons.dataURLs[component.keyword] != nil
    }

    /// The `addFiles` payload for one component, or `nil` when the generated
    /// table has nothing for it.
    ///
    /// A missing entry is not an error: the node still renders as its box with
    /// its caption, exactly as it did before there were icons. That is what
    /// makes adding a component to the enum safe to do without regenerating
    /// artwork in the same commit.
    static func file(for component: DiagramComponent) -> [String: Any]? {
        guard let url = WhiteboardIcons.dataURLs[component.keyword] else { return nil }
        return ["id": fileID(for: component), "dataURL": url, "mimeType": "image/svg+xml"]
    }

    /// Deduplicated files for a whole diagram, in first-appearance order.
    ///
    /// Order is stable rather than set-arbitrary so the same diagram text
    /// produces byte-identical output twice - the property the deterministic
    /// generator exists for, which a `Set` round trip would quietly break.
    static func files(for components: [DiagramComponent]) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for component in components where seen.insert(component.keyword).inserted {
            if let file = file(for: component) { out.append(file) }
        }
        return out
    }
}
