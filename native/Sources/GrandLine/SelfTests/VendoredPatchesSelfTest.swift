// Grand Line - native macOS app.
//
// Permanent guard on the seven local patches carried in
// `native/Vendor/SwiftTerm` (P9 of full review #3). Run with:
//
//   swift build && FM_RUN_VENDORED_PATCHES_TESTS=1 .build/debug/GrandLine; echo $?
//
// **What this exists for, and what it deliberately does not do.**
//
// The review's finding about the pin is that "every sync is a five-patch
// re-apply"; it is a seven-patch re-apply now. The hazard in that sentence is
// not the pin being old - a stale pin is a decision, recorded and re-taken on a
// schedule in that directory's own README - it is a *re-apply that silently
// drops one of them*. Five of the seven live in two files upstream rewrites
// heavily (measured at v1.20.0:
// `Apple/AppleTerminalView.swift` +813/-157, `Mac/MacTerminalView.swift`
// +647/-54), so the realistic failure is a hunk lost in a merge, not a
// deliberate removal - and every one of them then fails silently, in a way this
// project has already paid for once each: illegible dim text on a light theme,
// a duplicated character at a wrap boundary, 6-16% CPU while backgrounded, a
// corrupt `kubectl` table row, and ~25ms of CoreText work per background frame.
//
// So this asserts *presence*, by the narrowest marker each patch cannot exist
// without. It is not a behavioural test: each patch already has one (see the
// README's re-apply table), and those prove the behaviour once the code is
// there. This proves the code is there at all, which is the half a behavioural
// suite cannot report usefully - `FM_RUN_CONTRAST_TESTS` failing on a colour
// ratio does not say "patch 1 did not come back from the sync".
//
// The other half of P9 - "is upstream worth bumping to yet" - is a network and
// judgement check and is in `native/MANUAL-CHECKS.md`, not here. What this
// suite does contribute to it is a **NOTE, never a failure**, once the README's
// recorded `Last checked` date is older than the re-check interval: a date
// cannot break somebody else's build, and a scheduled check that no build ever
// mentions is one nobody can tell was skipped.

// GL-27: compiled into debug builds only. Do not remove this guard when editing
// a suite - `Phase3PolishSelfTest` asserts every file here carries it.
#if FM_SELFTESTS

import Foundation

enum VendoredPatchesSelfTest {

    /// How long a recorded upstream check stays current. Six months, matching
    /// the README's own stated cadence; the two are asserted to agree below, so
    /// changing one without the other fails rather than drifting.
    static let recheckIntervalDays = 183

    /// One entry per local patch: the file it lives in, and a marker that
    /// cannot be present unless the patch is.
    ///
    /// Each marker is a **symbol this app's own code or a sibling suite reads**,
    /// never a comment - a comment survives a merge that drops the code under
    /// it, which is the exact failure this guards. `minimumColumns` appears in
    /// three files and is asserted in all three, because the property without
    /// the two clamps is inert and the clamps without the property do not
    /// compile.
    private static let patches: [(number: Int, name: String, sites: [(String, String)])] = [
        (1, "dimmedColor contrast floor", [
            ("Sources/SwiftTerm/Dimming.swift", "static func blendFraction"),
            ("Sources/SwiftTerm/Mac/MacExtensions.swift", "Dimming.blendFraction"),
            ("Sources/SwiftTerm/iOS/iOSExtensions.swift", "Dimming.blendFraction"),
        ]),
        (2, "truecolor legibleColor", [
            ("Sources/SwiftTerm/Dimming.swift", "static func contrastFixBlendFraction"),
            ("Sources/SwiftTerm/Mac/MacExtensions.swift", "func legibleColor"),
            ("Sources/SwiftTerm/iOS/iOSExtensions.swift", "func legibleColor"),
            ("Sources/SwiftTerm/Apple/AppleTerminalView.swift", "legibleColor (against:"),
        ]),
        (3, "invalidationRegion upward extension", [
            ("Sources/SwiftTerm/Apple/AppleTerminalView.swift", "static func invalidationRegion"),
        ]),
        (4, "display gating", [
            ("Sources/SwiftTerm/Mac/MacTerminalView.swift", "public var displaySuspended"),
            ("Sources/SwiftTerm/Mac/MacTerminalView.swift", "public var displayIntervalNanos"),
            ("Sources/SwiftTerm/Apple/AppleTerminalView.swift", "suspendedDisplayPending"),
            ("Sources/SwiftTerm/Apple/AppleTerminalView.swift", "displayIntervalNanos"),
        ]),
        (5, "minimumColumns floor", [
            ("Sources/SwiftTerm/Mac/MacTerminalView.swift", "public var minimumColumns"),
            ("Sources/SwiftTerm/iOS/iOSTerminalView.swift", "public var minimumColumns"),
            ("Sources/SwiftTerm/Apple/AppleTerminalView.swift", "max(minimumColumns,"),
            ("Sources/SwiftTerm/Apple/AppleTerminalView.swift", "max (minimumColumns,"),
        ]),
        (6, "discarded withUnsafeBytes result", [
            ("Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift",
             "_ = vertices.withUnsafeBytes"),
        ]),
        (7, "per-row CoreText render cache", [
            ("Sources/SwiftTerm/Mac/MacTerminalView.swift", "var lineRenderCache"),
            ("Sources/SwiftTerm/iOS/iOSTerminalView.swift", "var lineRenderCache"),
            ("Sources/SwiftTerm/Apple/AppleTerminalView.swift", "func preparedLineRender"),
            ("Sources/SwiftTerm/Apple/AppleTerminalView.swift", "func invalidateLineRenderCache"),
            ("Sources/SwiftTerm/Apple/AppleTerminalView.swift", "preparedLineRender(row:"),
        ]),
    ]

    /// Patch 6 is applied at **two** call sites in one file, and the presence
    /// check above is a `contains` - so it is satisfied by either of them. That
    /// is not enough here: a re-apply that fixes one `makeBuffer` and misses
    /// the other passes that check while the build is still warning-dirty. This
    /// asserts the real invariant instead - every `vertices.withUnsafeBytes`
    /// call in that file discards its result.
    private static let patch6File = "Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift"
    private static let patch6Call = "vertices.withUnsafeBytes"
    private static let patch6Fixed = "_ = vertices.withUnsafeBytes"

    static func run() -> Bool {
        print("VendoredPatchesSelfTest")
        var ok = true

        guard let vendor = vendorDirectory() else {
            print("  SKIP - sources not present next to this binary")
            return true
        }

        checkEveryPatchIsStillPresent(vendor, &ok)
        checkBothWithUnsafeBytesCallsDiscardTheirResult(vendor, &ok)
        checkTheUpstreamCheckIsRecorded(vendor, &ok)

        print(ok ? "VendoredPatchesSelfTest: all checks passed"
                 : "VendoredPatchesSelfTest: FAILURES")
        return ok
    }

    /// `native/Vendor/SwiftTerm`.
    private static func vendorDirectory() -> URL? {
        guard let appSources = SelfTestSources.appSourceDirectory() else { return nil }
        let dir = appSources
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // native/
            .appendingPathComponent("Vendor/SwiftTerm")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path) else {
            return nil
        }
        return dir
    }

    // MARK: - Every patch is still in the tree

    private static func checkEveryPatchIsStillPresent(_ vendor: URL, _ ok: inout Bool) {
        // A marker list that resolved to nothing would report every patch as
        // present without reading a single file, so the file reads are counted
        // and a zero fails loudly.
        var sitesRead = 0

        for patch in patches {
            var missing: [String] = []
            var oneSiteHeld = false

            for (relativePath, marker) in patch.sites {
                let file = vendor.appendingPathComponent(relativePath)
                guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
                    missing.append("\(relativePath) is unreadable")
                    continue
                }
                let text = strippingComments(raw)
                sitesRead += 1
                // Patch 5's two clamps differ only in Swift's optional space
                // before the paren, and the vendored tree carries one of each -
                // so the pair is satisfied by either, which is why they are
                // listed as alternatives rather than both required.
                if text.contains(marker) {
                    oneSiteHeld = true
                } else if !isAlternativeMarker(marker) {
                    missing.append("\(relativePath) no longer contains \"\(marker)\"")
                }
            }

            if !oneSiteHeld {
                missing.append("not one of its sites held")
            }

            if missing.isEmpty {
                print("  OK   patch \(patch.number) (\(patch.name)) is still applied")
            } else {
                fail("patch \(patch.number) (\(patch.name)) looks dropped: "
                     + missing.joined(separator: "; ")
                     + "\n      A sync must re-apply every one of them - see "
                     + "native/Vendor/SwiftTerm/README.md's re-apply table, then "
                     + "re-run that patch's own behavioural suite.", &ok)
            }
        }

        if sitesRead == 0 {
            fail("read no vendored file at all - this guard was asserting nothing", &ok)
        }
    }

    /// Every line with its `//` comment removed.
    ///
    /// This is not tidiness, it is the point: a patch's own doc comment names
    /// the symbols the patch introduces, and a merge that drops the code under
    /// a comment leaves the comment behind - which is precisely the silent
    /// re-apply failure this suite exists to catch. Found by injecting exactly
    /// that: reverting `dimmedColor`'s body to upstream's flat 50% blend while
    /// leaving its doc comment in place passed the un-stripped version.
    ///
    /// Line-wise rather than a real tokenizer, so a `//` inside a string
    /// literal truncates that line early. No marker here is inside one, and
    /// the failure direction is safe: a truncated line can only ever make this
    /// guard report a patch as missing, never as present.
    private static func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// Patch 5 exists in the vendored tree as both `max(minimumColumns,` and
    /// `max (minimumColumns,`; either spelling proves the clamp is there, so
    /// neither is individually required.
    private static func isAlternativeMarker(_ marker: String) -> Bool {
        marker.hasPrefix("max(minimumColumns") || marker.hasPrefix("max (minimumColumns")
    }

    // MARK: - Patch 6 covers every call site, not just one

    /// Every `vertices.withUnsafeBytes` call in the Metal renderer discards its
    /// result.
    ///
    /// `memcpy` returns its destination pointer, so a single-expression closure
    /// around it infers that pointer as its own result type and
    /// `withUnsafeBytes` then hands back a value nobody wants - which the
    /// compiler reports as `result of call to 'withUnsafeBytes' is unused`.
    /// There were two such calls and both warned; a re-apply that catches one
    /// and misses the other satisfies the `contains` check above while the
    /// build is still dirty, so the count is what is asserted here.
    ///
    /// The discriminating power is asserted first: a file with no such call at
    /// all would otherwise pass this vacuously.
    private static func checkBothWithUnsafeBytesCallsDiscardTheirResult(_ vendor: URL, _ ok: inout Bool) {
        let file = vendor.appendingPathComponent(patch6File)
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
            fail("could not read \(patch6File)", &ok)
            return
        }
        let text = strippingComments(raw)

        let calls = occurrences(of: patch6Call, in: text)
        let discarded = occurrences(of: patch6Fixed, in: text)

        guard calls > 0 else {
            fail("\(patch6File) contains no \"\(patch6Call)\" call at all - this "
                 + "check was asserting nothing. If upstream restructured the "
                 + "renderer, re-derive patch 6 against the new shape rather "
                 + "than deleting this.", &ok)
            return
        }

        if calls == discarded {
            print("  OK   patch 6 covers all \(calls) withUnsafeBytes call sites")
        } else {
            fail("\(calls - discarded) of \(calls) \"\(patch6Call)\" calls in "
                 + "\(patch6File) still use their result - each one is a "
                 + "`result of call to 'withUnsafeBytes' is unused` warning. "
                 + "Prefix it with `_ = `; see native/Vendor/SwiftTerm/README.md's "
                 + "sixth patch.", &ok)
        }
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var index = text.startIndex
        while let r = text.range(of: needle, range: index..<text.endIndex) {
            count += 1
            index = r.upperBound
        }
        return count
    }

    // MARK: - The scheduled check left a record

    /// The README carries the pin and the date of the last upstream check. This
    /// asserts the *record exists and parses* - which is deterministic - and
    /// only ever prints a NOTE about the date itself.
    private static func checkTheUpstreamCheckIsRecorded(_ vendor: URL, _ ok: inout Bool) {
        let readme = vendor.appendingPathComponent("README.md")
        guard let text = try? String(contentsOf: readme, encoding: .utf8) else {
            fail("could not read \(readme.path)", &ok)
            return
        }

        guard let pinned = value(after: "**Pinned:**", in: text) else {
            fail("README no longer records a **Pinned:** upstream version", &ok)
            return
        }
        guard let lastChecked = value(after: "**Last checked:**", in: text) else {
            fail("README no longer records a **Last checked:** date - the "
                 + "scheduled check has no record, so nobody can tell it was skipped", &ok)
            return
        }
        guard let recheck = value(after: "**Re-check:**", in: text) else {
            fail("README no longer records a **Re-check:** cadence", &ok)
            return
        }

        // The cadence in prose and this suite's own interval have to agree, or
        // the NOTE below measures something the README does not promise. Keyed
        // on the day count rather than the words, because "six months" is not a
        // number and "6 months" is also a substring of "16 months".
        if !recheck.contains("\(recheckIntervalDays) days") {
            fail("README's re-check cadence (\"\(recheck)\") does not state the "
                 + "\(recheckIntervalDays) days this suite measures against", &ok)
        }

        guard let date = firstISODate(in: lastChecked) else {
            fail("the **Last checked:** line (\"\(lastChecked)\") carries no "
                 + "parseable yyyy-MM-dd date", &ok)
            return
        }

        print("  OK   pinned \(pinned), last checked \(lastChecked)")

        let days = Int(Date().timeIntervalSince(date) / 86_400)
        if days > recheckIntervalDays {
            // Never a failure: the code has not changed, and a build that goes
            // red because time passed trains everyone to ignore red.
            print("  NOTE the upstream check is \(days) days old (interval "
                  + "\(recheckIntervalDays)) - run the recipe in "
                  + "native/Vendor/SwiftTerm/README.md and record the result, "
                  + "even if the answer is \"stay pinned\"")
        }
    }

    /// The remainder of the first line containing `label`, trimmed. Bold labels
    /// are on their own line in that README, one value each.
    private static func value(after label: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let r = line.range(of: label) else { continue }
            let rest = line[r.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    private static func firstISODate(in string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for token in string.split(whereSeparator: { !"0123456789-".contains($0) }) {
            if let date = formatter.date(from: String(token)) {
                return date
            }
        }
        return nil
    }
}

#endif
