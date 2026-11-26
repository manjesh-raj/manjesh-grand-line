// Grand Line - native macOS app.
//
// The review lab's verbs for the surfaces full review 4's feature build
// added (F-01 to F-15, D-01 to D-05). Same contract as
// `ReviewTourLabSurfaces.swift`: each verb builds the real view, renders it in
// an `OffScreenProbe` window (never on a display) and writes `<name>.png` into
// the tour's directory.
//
//     ux incident <name> [export]     D-05: the incident card, or its export panel
//
// GL-27: debug builds only.

#if FM_SELFTESTS

import AppKit

extension ReviewTourLab {

    static let featureVerbs: Set<String> = ["incident"]

    static func applyFeatureUX(_ parts: [String], shell: WorkspaceShellController, outputDirectory: URL) -> String? {
        guard let verb = parts.first, featureVerbs.contains(verb) else { return nil }
        let rest = Array(parts.dropFirst())
        func url(_ name: String) -> URL { outputDirectory.appendingPathComponent("\(name).png") }
        func done(_ written: Bool, _ name: String) -> String {
            written ? "ux \(verb) -> \(url(name).path)" : "ux \(verb) FAILED - nothing to cache for \(name)"
        }
        guard let name = rest.first else { return "ux \(verb) FAILED - want a name" }
        switch verb {
        case "incident":
            let card = IncidentCardView()
            card.render(IncidentExportSelfTest.fixture(ended: false), theme: ThemeManager.shared.theme)
            if rest.dropFirst().contains("export") { card.debugExportButton.performClick(nil) }
            let size = NSSize(width: IncidentCardView.cardWidth, height: IncidentCardView.cardHeight)
            return done(renderFixed(card, size: size, to: url(name)), name)
        default:
            return nil
        }
    }

    /// Renders a fixed-size view (a popover's content) in its own off-screen
    /// window.
    static func renderFixed(_ view: NSView, size: NSSize, to url: URL) -> Bool {
        let window = OffScreenProbe.window(size: size)
        defer { window.contentView = nil; window.orderOut(nil) }
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<2 { view.layoutSubtreeIfNeeded() }
        return writePNG(of: view, to: url)
    }
}

#endif
