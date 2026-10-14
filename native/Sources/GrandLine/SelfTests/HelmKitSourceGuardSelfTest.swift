// Grand Line - native macOS app.
//
// The UI/UX revamp's source guards (UI-40): the recipes the revamp put into
// shared components, kept there.
//
// The revamp's own finding was that the layout proposals of the previous
// rounds landed and the *recipe* proposals did not survive the port - each
// page re-derived a pill, a shadow or a spacing number privately, and the
// next page copied the copy. A recipe that only lives in a component is one
// grep away from being re-spelled, so each one the revamp fixed gets a guard
// here, in CI's blocking lane.
//
// Run with `FM_RUN_HELM_KIT_GUARD_TESTS=1 .build/debug/GrandLine`.
//
// Pure source reads - no window, no session. Deliberately NOT in
// `NEEDS_SESSION`.
//
// What it guards:
//
//   1. **Depth is painted once (UI-5, Rule 2).** A file that reads
//      `HelmCard.elevation(for:)` must not also assign `shadowOpacity`
//      itself. That pairing is exactly the squared-alpha defect: the
//      elevation colour already carries the level's alpha, and copying it
//      into `shadowOpacity` multiplies it in twice. `HelmCard.applyElevation`
//      is the one place that does the conversion.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum HelmKitSourceGuardSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== HelmKitSourceGuardSelfTest ==")
        guard let files = SelfTestSources.appSourceFiles(), !files.isEmpty else {
            print("  SKIP: app sources not next to this binary")
            return true
        }
        checkShadowsArePaintedOnce(files, &ok)
        print(ok ? "HelmKitSourceGuardSelfTest: OK" : "HelmKitSourceGuardSelfTest: FAILED")
        return ok
    }

    /// Strips `//` comments so a doc comment that *describes* the forbidden
    /// shape (this file's header does, and so does `applyElevation`'s) does
    /// not trip the guard it documents.
    static func codeLines(_ source: String) -> [String] {
        source.components(separatedBy: "\n").map { line in
            guard let range = line.range(of: "//") else { return line }
            return String(line[..<range.lowerBound])
        }
    }

    // MARK: 1 - depth is painted once

    /// The one file allowed to read the elevation colour and set an opacity
    /// from it: the file that defines the conversion.
    static let elevationOwner = "HelmDesignSystem.swift"

    private static func checkShadowsArePaintedOnce(_ files: [URL], _ ok: inout Bool) {
        var readers = 0
        for file in files where file.lastPathComponent != elevationOwner {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = codeLines(source).joined(separator: "\n")
            guard code.contains("HelmCard.elevation(for") else { continue }
            readers += 1
            let assignsOpacity = code.range(of: #"\.shadowOpacity\s*="#, options: .regularExpression) != nil
            check(!assignsOpacity,
                  "\(file.lastPathComponent) reads HelmCard.elevation(for:) and assigns shadowOpacity "
                      + "itself - route the layer through HelmCard.applyElevation, which applies the "
                      + "level's alpha once", &ok)
        }
        // The discriminating half: the guard has to be looking at the files
        // that genuinely read the elevation, or it passes by finding nothing.
        check(readers >= 1,
              "expected at least one file outside \(elevationOwner) to read HelmCard.elevation(for:), "
                  + "found \(readers) - the guard is no longer looking at anything", &ok)
    }
}

#endif
