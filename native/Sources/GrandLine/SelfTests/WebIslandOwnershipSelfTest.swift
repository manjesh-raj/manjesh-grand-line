// Grand Line - native macOS app.
//
// R4-ARCH-01 of the fourth full review: the native side owns every web
// island's view state. The page reports, the native side decides, and a
// report that would change a native-owned value is logged and dropped.
// R4-BUG-01 was the instance: the Calendar adopted a Day view Schedule-X
// reported when a hidden page collapsed, and the captain's Month was gone for
// good.
//
// Two source guards, because the rule is a property of where code is written
// rather than of anything a run can observe:
//
//   - each of the three web hosts states the rule in its header, so the next
//     person adding a page report reads it before wiring one;
//   - no `on*` callback a controller hands one of them assigns `scale`. The
//     Calendar's scale changes in `show(scale:)` and in one named method the
//     page's own view handler reaches, never inline in a report's callback.
//
// The behavioural half - a range report naming another view moves the period,
// keeps the scale and is counted as dropped - runs against the real page in
// `ShiftCalendarViewSelfTest`, which needs a window.
//
// Run with:
//   swift build && FM_RUN_WEB_ISLAND_OWNERSHIP_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum WebIslandOwnershipSelfTest {

    /// The three hosts, and the files that wire their callbacks.
    static let hosts = ["ShiftCalendarWebView.swift", "WhiteboardWebView.swift", "CodePreviewWebView.swift"]
    static let wiring = ["ShiftCalendarViews.swift", "WhiteboardController.swift", "CodePreviewController.swift",
                         "NotebookController.swift"]

    static let rule = "The page reports, the native side decides, and a report that would change a "
        + "native-owned value is logged and dropped"

    static func run() -> Bool {
        var ok = true
        guard let dir = SelfTestSources.appSourceDirectory() else {
            fail("could not find the app's sources - every guard here would silently pass", &ok)
            return false
        }
        func source(_ name: String) -> String? {
            try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }

        print("\n-- each web host states the rule in its header --")
        for name in hosts {
            guard let text = source(name) else {
                fail("could not read \(name)", &ok)
                continue
            }
            check(headerProse(text).contains(rule), "\(name)'s header no longer states the ownership rule", &ok)
        }

        print("\n-- no on* callback assigns the scale --")
        // The detector's own discriminating power, on a callback that does.
        let planted = """
            webView.onRangeChanged = { [weak self] start, end, view in
                guard let self else { return }
                if let scale = ShiftCalendarScale(rawValue: view ?? "") { self.scale = scale }
            }
            """
        check(callbacksAssigningScale(in: planted) == ["onRangeChanged"],
              "the detector should flag a callback that assigns the scale", &ok)
        check(callbacksAssigningScale(in: "webView.onReady = { [weak self] in self?.show(scale: .month) }").isEmpty,
              "the detector must not flag a callback that only calls show(scale:)", &ok)

        var callbackCount = 0
        for name in wiring {
            guard let text = source(name) else {
                fail("could not read \(name)", &ok)
                continue
            }
            callbackCount += callbacks(in: text).count
            for callback in callbacksAssigningScale(in: text) {
                fail("\(name): webView.\(callback) assigns the scale itself - route it through a method that "
                     + "decides, or log and drop it (R4-ARCH-01)", &ok)
            }
        }
        // And the guard's own coverage: it must really be reading the wiring.
        check(callbackCount >= 15, "found only \(callbackCount) on* callbacks across \(wiring.joined(separator: ", ")) "
              + "- has the wiring moved?", &ok)

        print("WebIslandOwnershipSelfTest: \(ok ? "PASSED" : "FAILED")")
        return ok
    }

    /// The leading comment block, joined into one line of prose.
    private static func headerProse(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .prefix { $0.hasPrefix("//") }
            .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    /// Every `on<Name> = { ... }` callback, with its body.
    static func callbacks(in text: String) -> [(name: String, body: String)] {
        let code = text.components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")
        guard let pattern = try? NSRegularExpression(pattern: #"\.(on[A-Z][A-Za-z]*)\s*=\s*\{"#) else { return [] }
        var found: [(String, String)] = []
        let ns = code as NSString
        for match in pattern.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            // The body runs to the brace that closes the one the match ended on.
            var depth = 0
            var end = match.range.location + match.range.length - 1
            var index = end
            while index < ns.length {
                let char = ns.character(at: index)
                if char == 0x7B { depth += 1 }
                if char == 0x7D {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
                index += 1
            }
            let start = match.range.location + match.range.length
            found.append((name, ns.substring(with: NSRange(location: start, length: max(0, end - start)))))
        }
        return found
    }

    /// The callbacks whose body assigns `scale` - `scale =`, `self.scale =`
    /// or `self?.scale =`, and never `==`.
    static func callbacksAssigningScale(in text: String) -> [String] {
        guard let assignment = try? NSRegularExpression(pattern: #"(^|[^A-Za-z0-9_])scale\s*=(?!=)"#) else { return [] }
        return callbacks(in: text).compactMap { callback in
            let range = NSRange(location: 0, length: (callback.body as NSString).length)
            return assignment.firstMatch(in: callback.body, range: range) == nil ? nil : callback.name
        }
    }
}

#endif
