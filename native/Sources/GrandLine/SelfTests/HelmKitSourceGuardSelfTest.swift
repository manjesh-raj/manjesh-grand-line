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
//   2. **One status pill (UI-32, Rule 4).** `ToolRowLayout.pill(` is called
//      only by `HelmStatusPill` and by the files on the migration list below.
//      The list only ever shrinks: a new file that paints a pill by hand
//      fails here and should build a `HelmStatusPill` instead.
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
        checkPillsGoThroughTheKit(files, &ok)
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

    // MARK: 2 - one status pill

    /// Files allowed to call `ToolRowLayout.pill(` directly: the class that
    /// defines it, the kit class that wraps it, and the call sites not yet
    /// moved onto `HelmStatusPill`. Shrinks; never grows.
    static let pillCallAllowlist: Set<String> = [
        "HelmUIComponents.swift",
        "HelmKit.swift",
        // Migration list.
        "BootstrapController.swift",
        "CommandLibraryViews.swift",
        "CredentialVaultController.swift",
        "ConsoleController+SRELead.swift",
        "CredentialVaultInspector.swift",
        "CredentialVaultRecoverySheet.swift",
        "DictationController.swift",
        "GitHubSyncController.swift",
        "HealthCardView.swift",
        "HelmModuleCard.swift",
        "IncidentCardView.swift",
        "LogAnalyzerController.swift",
        "NeedsAttentionCard.swift",
        "PasswordGeneratorPanel.swift",
        "SettingsController.swift",
        "ShiftController.swift",
        "UpdatesController.swift",
    ]

    private static func checkPillsGoThroughTheKit(_ files: [URL], _ ok: inout Bool) {
        var seenKit = false
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = codeLines(source).joined(separator: "\n")
            guard code.contains("ToolRowLayout.pill(") else { continue }
            if file.lastPathComponent == "HelmKit.swift" { seenKit = true }
            check(pillCallAllowlist.contains(file.lastPathComponent),
                  "\(file.lastPathComponent) paints a pill with ToolRowLayout.pill - build a HelmStatusPill "
                      + "(HelmKit.swift) instead, so the recipe cannot be re-spelled", &ok)
        }
        check(seenKit, "HelmStatusPill should be found wrapping ToolRowLayout.pill - the guard is blind", &ok)
    }
}

#endif
