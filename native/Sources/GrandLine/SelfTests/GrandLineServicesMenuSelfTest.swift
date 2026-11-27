// Grand Line - native macOS app.
//
// F-10 of full review 4: Services > Send to Grand Line.
// Run with `FM_RUN_SERVICES_MENU_TESTS=1 .build/debug/GrandLine`.
//
// Headless. Pasteboards are private named ones, never the general one, and
// the banner is recorded rather than posted.
//
// What it pins:
//
//  - **Reading the selection**: text and a link, a bare URL as the link.
//  - **The drafts**: a note quotes the selection and names its source, a
//    task carries the link, a reading-list item is the URL.
//  - **The provider files through the capture filer and posts a banner**,
//    and refuses while locked (GL-09) with nothing filed.
//  - **Every `NSMessage` in Info.plist answers**: build_native_app.sh's
//    `NSServices` names and the provider's `@objc` selectors agree, so a
//    renamed method cannot leave a dead Services item.
//  - **The panel**: a link with no text starts on Reading list, Save hands
//    back the kind and the edited title, and the locked panel saves nothing.

#if FM_SELFTESTS

import AppKit

enum GrandLineServicesMenuSelfTest {

    static func run() -> Bool {
        var ok = true
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        let cases: [(String, () -> String?)] = [
            ("reads text and a link", test_read),
            ("drafts per kind", test_drafts),
            ("provider files and posts a banner", test_provider),
            ("locked refuses and files nothing", test_locked),
            ("every Info.plist message answers", test_plistMessages),
            ("the filing panel", test_panel),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[services] \(name): \(failure)", &ok) } else { print("[services] PASS \(name)") }
        }
        print(ok ? "[services] ALL PASS" : "[services] FAILED")
        return ok
    }

    static let hpa = "You can use the behavior field to configure separate scale-up and scale-down behaviors."
    static let page = "https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale"

    static func board(text: String?, url: String?) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("fm.selftest.services.\(UUID().uuidString)"))
        board.clearContents()
        var types: [NSPasteboard.PasteboardType] = []
        if text != nil { types.append(.string) }
        if url != nil { types.append(.URL) }
        board.declareTypes(types, owner: nil)
        if let text { board.setString(text, forType: .string) }
        if let url { board.setString(url, forType: .URL) }
        return board
    }

    final class Recorder {
        var filed: [(CaptureDestination, CaptureDraft)] = []
        var banners: [(String, String)] = []
    }

    static func provider(_ recorder: Recorder) -> GrandLineServicesProvider {
        let provider = GrandLineServicesProvider(filer: CaptureFiler { destination, draft in
            recorder.filed.append((destination, draft))
            return .filed(destination)
        })
        provider.notify = { recorder.banners.append(($0, $1)) }
        provider.frontmostAppName = { "Safari" }
        return provider
    }

    static func test_read() -> String? {
        let both = board(text: hpa, url: page)
        defer { both.releaseGlobally() }
        guard let selection = ServiceSelection.read(both, sourceApp: "Safari"),
              selection.text == hpa, selection.url == page else { return "text and link: \(String(describing: ServiceSelection.read(both, sourceApp: nil)))" }
        let bare = board(text: page, url: nil)
        defer { bare.releaseGlobally() }
        guard let link = ServiceSelection.read(bare, sourceApp: nil), link.url == page, link.text.isEmpty else {
            return "a bare URL should be the link"
        }
        guard link.suggestedTitle == "kubernetes.io" else { return "a link's title is \(link.suggestedTitle)" }
        let empty = board(text: "   ", url: nil)
        defer { empty.releaseGlobally() }
        return ServiceSelection.read(empty, sourceApp: nil) == nil ? nil : "whitespace was a selection"
    }

    static func test_drafts() -> String? {
        let selection = ServiceSelection(text: hpa, url: page, sourceApp: "Safari")
        let note = ServiceFiling.draft(.note, title: "HPA behavior", selection: selection)
        guard note.body.hasPrefix("> You can use"), note.body.hasSuffix("From \(page)") else { return "note body: \(note.body)" }
        let task = ServiceFiling.draft(.task, title: "Try the HPA behavior field", selection: selection)
        guard task.title == "Try the HPA behavior field", task.body.contains(page), task.body.hasPrefix(hpa) else {
            return "task: \(task)"
        }
        let link = ServiceFiling.draft(.link, title: "HPA", selection: selection)
        return link.text == page ? nil : "link text \(link.text)"
    }

    static func test_provider() -> String? {
        AppLockGate.shared.setLocked(false)
        let recorder = Recorder()
        let p = provider(recorder)
        let pb = board(text: hpa, url: page)
        defer { pb.releaseGlobally() }
        // Through the real @objc entry point Services calls.
        p.newTaskFromSelection(pb, userData: nil, error: nil)
        guard recorder.filed.count == 1, recorder.filed[0].0 == .task else { return "filed \(recorder.filed.map(\.0))" }
        // The title is the selection's first line, shortened to 80 characters.
        guard recorder.banners.first?.0.hasPrefix("Added to Tasks: You can use the behavior field") == true,
              recorder.banners.first?.0.hasSuffix("\u{2026}") == true,
              recorder.banners.first?.1 == "From Safari" else { return "banner \(recorder.banners)" }
        p.addPageToReadingList(pb, userData: nil, error: nil)
        guard recorder.filed.count == 2, recorder.filed[1].0 == .link, recorder.filed[1].1.text == page else {
            return "reading list filed \(recorder.filed.map(\.0))"
        }
        return nil
    }

    static func test_locked() -> String? {
        AppLockGate.shared.setLocked(true)
        defer { AppLockGate.shared.setLocked(false) }
        let recorder = Recorder()
        let p = provider(recorder)
        let pb = board(text: hpa, url: page)
        defer { pb.releaseGlobally() }
        p.newTaskFromSelection(pb, userData: nil, error: nil)
        guard recorder.filed.isEmpty else { return "filed while locked" }
        return recorder.banners.first?.0 == "Grand Line is locked" ? nil : "banner \(recorder.banners)"
    }

    static func test_plistMessages() -> String? {
        let p = provider(Recorder())
        for message in GrandLineServicesProvider.messages {
            guard p.responds(to: NSSelectorFromString("\(message):userData:error:")) else {
                return "the provider does not answer \(message):userData:error:"
            }
        }
        guard let dir = SelfTestSources.appSourceDirectory() else { print("[services] SKIP plist guard"); return nil }
        let script = dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build_native_app.sh")
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { return "could not read build_native_app.sh" }
        guard text.contains("<key>NSServices</key>") else { return "Info.plist has no NSServices" }
        let names = text.components(separatedBy: "<key>NSMessage</key>").dropFirst().compactMap { chunk -> String? in
            guard let start = chunk.range(of: "<string>"), let end = chunk.range(of: "</string>") else { return nil }
            return String(chunk[start.upperBound..<end.lowerBound])
        }
        return names == GrandLineServicesProvider.messages ? nil : "Info.plist messages \(names) vs \(GrandLineServicesProvider.messages)"
    }

    static func test_panel() -> String? {
        let view = SendToGrandLineView()
        view.configure(ServiceSelection(text: "", url: page, sourceApp: "Safari"), locked: false, theme: ThemeManager.shared.theme)
        guard view.debugKind == .link else { return "a bare link should start on Reading list, got \(view.debugKind)" }
        view.configure(ServiceSelection(text: hpa, url: page, sourceApp: "Safari"), locked: false, theme: ThemeManager.shared.theme)
        guard view.debugKind == .task else { return "a selection should start on Task" }
        var saved: (ServiceFiling.Kind, String)?
        view.onSave = { saved = ($0, $1) }
        view.debugSelect(.note)
        view.debugTitleField.stringValue = "HPA behavior field"
        view.debugSaveButton.performClick(nil)
        guard let (kind, title) = saved, kind == .note, title == "HPA behavior field" else { return "saved \(String(describing: saved))" }
        saved = nil
        view.configure(ServiceSelection(text: hpa, url: page, sourceApp: "Safari"), locked: true, theme: ThemeManager.shared.theme)
        guard view.debugIsShowingLocked else { return "the locked panel does not say so" }
        view.debugSaveButton.performClick(nil)
        return saved == nil ? nil : "the locked panel saved"
    }
}

#endif
