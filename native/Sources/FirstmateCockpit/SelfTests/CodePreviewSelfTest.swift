// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for the Code Preview destination's
// *logic* half (`fm/grandline-monaco-code-preview`): where the vendored Monaco
// bundle is found, whether it is genuinely offline, which languages it really
// carries, what the paste-time detector does, how a snippet is stored, and
// whether the destination is wired into the shell's tables.
//
// The editor itself is not testable this way and this suite does not pretend
// otherwise - `CodePreviewViewSelfTest` covers the parts that need a real
// `WKWebView` and window (including reading Monaco's own tokenizer output back,
// which is the only honest proof that highlighting actually happened). What is
// covered here is everything that can silently rot: an asset path that stops
// resolving, a CDN reference creeping into the page, a language id that no
// longer exists in the bundle, a detector that starts guessing confidently, a
// store that writes into the captain's real repo from a test.
//
// `FM_RUN_CODE_PREVIEW_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CodePreviewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                ok = false
            }
        }

        checkAssets(check)
        checkOfflineByConstruction(check)
        checkBundleCarriesEveryLanguage(check)
        checkLanguageTable(check)
        checkFilenameMapping(check)
        checkDetection(check)
        checkStoreRoundTrip(check)
        checkStoreHonoursShiftDirOverride(check)
        checkNameSanitising(check)
        checkThemePalette(check)
        checkDestinationWiring(check)

        print(ok ? "CodePreviewSelfTest: OK" : "CodePreviewSelfTest: FAILURES")
        return ok
    }

    // MARK: Assets

    private static func checkAssets(_ check: (Bool, String) -> Void) {
        guard let dir = CodePreviewAssets.webDirectory() else {
            check(false, "no Monaco bundle found - run native/Scripts/build-monaco-web.sh")
            return
        }
        let fm = FileManager.default
        for file in ["index.html", "code-preview.js", "code-preview.css"] {
            check(fm.isReadableFile(atPath: dir.appendingPathComponent(file).path),
                  "the bundle is missing \(file)")
        }
        check(CodePreviewAssets.isAvailable, "isAvailable should agree with webDirectory()")
        check(CodePreviewAssets.indexURL()?.lastPathComponent == "index.html",
              "indexURL should point at index.html")

        // The override is what a self-test or a freshly rebuilt bundle uses;
        // it is checked after `Bundle.main.resourceURL` and before the source
        // tree, so pointing it somewhere real must win over the walk-up.
        // Restored afterwards rather than just cleared: a caller may have set
        // it deliberately, and a test that silently unsets a caller's
        // environment would make injecting a regression impossible.
        let priorOverride = ProcessInfo.processInfo.environment["FM_CODE_PREVIEW_WEB_DIR"]
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("code-preview-assets-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: scratch)
            if let priorOverride { setenv("FM_CODE_PREVIEW_WEB_DIR", priorOverride, 1) }
            else { unsetenv("FM_CODE_PREVIEW_WEB_DIR") }
        }
        try? "<html></html>".write(to: scratch.appendingPathComponent("index.html"),
                                   atomically: true, encoding: .utf8)
        setenv("FM_CODE_PREVIEW_WEB_DIR", scratch.path, 1)
        let overridden = CodePreviewAssets.webDirectory()?.standardizedFileURL
        unsetenv("FM_CODE_PREVIEW_WEB_DIR")
        check(overridden == scratch.standardizedFileURL,
              "FM_CODE_PREVIEW_WEB_DIR should win over the source-tree walk-up, got \(String(describing: overridden?.path))")
        check(CodePreviewAssets.webDirectory() != nil,
              "clearing the override should still resolve the vendored bundle from the source tree")
    }

    /// The offline guarantee, checked in the bytes rather than trusted.
    ///
    /// This app is offline-first by posture, and a code panel that could fetch
    /// a font, a language definition or - worst of all - a language server
    /// would be a real regression from it. The page's own CSP is the mechanism;
    /// this is what stops a future edit from quietly loosening it.
    private static func checkOfflineByConstruction(_ check: (Bool, String) -> Void) {
        guard let dir = CodePreviewAssets.webDirectory(),
              let html = try? String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8) else {
            check(false, "could not read the bundle's index.html")
            return
        }
        // The policy itself, not the file - the page's own comments discuss
        // directives by name, and a substring search over the whole document
        // would happily read one of those as the policy.
        guard let policy = cspPolicy(in: html) else {
            check(false, "index.html has no Content-Security-Policy meta tag")
            return
        }
        check(policy.contains("default-src 'self'"), "the CSP should default to 'self' only")
        check(policy.contains("connect-src 'self'"),
              "the CSP must pin connect-src to 'self' - that is what makes any language service or CDN fetch unreachable")
        check(!policy.contains("frame-src"),
              "frame-src should be absent so it falls back to default-src")
        check(policy.contains("object-src 'none'"), "the CSP should forbid plugins outright")
        // The worker is started from a Blob URL built out of source text
        // inlined in the bundle, so `worker-src` has to allow blob: - and that
        // is the *only* extra scheme it may allow.
        check(policy.contains("worker-src 'self' blob:"),
              "the CSP must allow a blob: worker - the editor worker is inlined and started from one")
        // A directive that allowed a remote origin would defeat all of the
        // above, whichever directive it was.
        check(!policy.contains("http://") && !policy.contains("https://") && !policy.contains("*"),
              "the CSP names a remote origin: \(policy)")

        // Any absolute URL in a real tag is a remote fetch by definition. The
        // page's own explanatory comments are stripped first, since they
        // legitimately talk about CDNs to explain why there is no CDN.
        let markup = html.replacingOccurrences(of: "<!--[^>]*(?:(?!-->)[\\s\\S])*?-->",
                                               with: "", options: .regularExpression)
        check(!markup.contains("http://") && !markup.contains("https://"),
              "index.html references an absolute URL - the page shell must be entirely local")

        // The stylesheet is the one place a font could still escape: Monaco's
        // codicon glyph font is inlined as a data: URI at build time, and a
        // rebuild that stopped doing that would put a fetch back.
        if let css = try? String(contentsOf: dir.appendingPathComponent("code-preview.css"), encoding: .utf8) {
            check(css.contains("src:url(data:font/ttf"),
                  "the codicon font should be inlined as a data: URI - a url() to a file means a fetch")
            let remoteURL = css.range(of: "url\\((?!data:)[^)]*//", options: .regularExpression)
            check(remoteURL == nil, "the stylesheet references a remote url()")
        } else {
            check(false, "could not read the bundle's code-preview.css")
        }

        // And the worker really is in the script rather than a sibling file
        // the page would have to load off a file:// origin.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check(!files.contains { $0.hasSuffix(".worker.js") },
              "a separate worker file appeared in the bundle - it is meant to be inlined (see code-preview.js)")
    }

    /// Every language this app offers has to genuinely be in the bundle.
    ///
    /// `CodePreviewLanguage.id` is handed straight to
    /// `monaco.editor.setModelLanguage`, and Monaco silently falls back to
    /// plain text for an id it does not know - so a typo here, or a language
    /// dropped from the build script's import list, is a snippet that quietly
    /// stops being highlighted. Grepping the committed bundle is the only way
    /// to catch that from Swift.
    private static func checkBundleCarriesEveryLanguage(_ check: (Bool, String) -> Void) {
        guard let dir = CodePreviewAssets.webDirectory(),
              let js = try? String(contentsOf: dir.appendingPathComponent("code-preview.js"), encoding: .utf8) else {
            check(false, "could not read the bundle's code-preview.js")
            return
        }
        for language in CodePreviewLanguage.all {
            // `plaintext` is Monaco's own built-in null language and is not
            // registered by any contribution, so it has no id string to find.
            guard language.id != "plaintext" else { continue }
            check(js.contains("\"\(language.id)\"") || js.contains("'\(language.id)'"),
                  "the bundle does not mention the language id \"\(language.id)\" - is it in build-monaco-web.sh's import list?")
        }
        // The two services this panel must never carry. Their monaco.contribution
        // modules define these exact defaults objects, so their presence is the
        // signal that an IntelliSense service was pulled in.
        check(!js.contains("typescriptDefaults"),
              "the TypeScript language *service* is in the bundle - this panel is highlight-only (see the README)")
        check(!js.contains("jsonDefaults"),
              "the JSON language *service* is in the bundle - JSON is meant to be the hand-written Monarch tokenizer")
    }

    /// The `content="…"` of the page's CSP meta tag.
    private static func cspPolicy(in html: String) -> String? {
        guard let tagStart = html.range(of: "Content-Security-Policy") else { return nil }
        let rest = html[tagStart.upperBound...]
        guard let contentKey = rest.range(of: "content=\"") else { return nil }
        let afterQuote = rest[contentKey.upperBound...]
        guard let closing = afterQuote.range(of: "\"") else { return nil }
        return String(afterQuote[..<closing.lowerBound])
    }

    // MARK: The table

    private static func checkLanguageTable(_ check: (Bool, String) -> Void) {
        check(CodePreviewLanguage.all.first?.id == "plaintext",
              "Plain Text should be first - it is the fallback and the honest default")

        var seenIDs = Set<String>()
        var seenExtensions: [String: String] = [:]
        for language in CodePreviewLanguage.all {
            check(seenIDs.insert(language.id).inserted, "duplicate language id \(language.id)")
            check(!language.extensions.isEmpty, "\(language.id) has no extensions - it needs a canonical one")
            for ext in language.extensions {
                check(ext == ext.lowercased(), "\(language.id)'s extension \"\(ext)\" should be lower-cased")
                check(!ext.hasPrefix("."), "\(language.id)'s extension \"\(ext)\" should not carry a dot")
                if let owner = seenExtensions[ext] {
                    check(false, "extension \"\(ext)\" is claimed by both \(owner) and \(language.id)")
                }
                seenExtensions[ext] = language.id
            }
            check(CodePreviewLanguage.named(language.id) != nil,
                  "named(\(language.id)) should find it")
        }

        // The task named these explicitly. A future trim of the bundle must
        // not quietly drop one.
        for required in ["swift", "yaml", "json", "shell", "python", "javascript", "typescript", "go", "rust"] {
            check(CodePreviewLanguage.named(required) != nil,
                  "the captain's own named set is missing \(required)")
        }
    }

    private static func checkFilenameMapping(_ check: (Bool, String) -> Void) {
        func language(_ name: String) -> String { CodePreviewLanguage.forFilename(name).id }

        check(language("HostRow.swift") == "swift", "a .swift file should be Swift")
        check(language("values.YAML") == "yaml", "the extension match should be case-insensitive")
        check(language("deploy.sh") == "shell", "a .sh file should be Shell")
        check(language("tsconfig.json") == "json", "a .json file should be JSON")
        check(language("main.go") == "go", "a .go file should be Go")
        check(language("notes") == "plaintext", "a file with no extension is plain text")
        check(language("archive.tar.gz") == "plaintext", "an unknown extension is plain text, not a guess")
        // The one filename that carries its language without a dot.
        check(language("Dockerfile") == "dockerfile", "a file called Dockerfile is a Dockerfile")
        check(language("dockerfile") == "dockerfile", "…case-insensitively")

        func renamed(_ name: String, _ id: String) -> String {
            CodePreviewLanguage.filename(name, as: CodePreviewLanguage.named(id)!)
        }
        check(renamed("snippet-1.txt", "python") == "snippet-1.py",
              "picking Python should move the file onto .py")
        check(renamed("snippet-1", "python") == "snippet-1.py",
              "…even from a name with no extension at all")
        check(renamed("HostRow.swift", "plaintext") == "HostRow.txt",
              "picking Plain Text should move it onto .txt rather than leaving a lying extension")
        check(renamed("Dockerfile", "dockerfile") == "Dockerfile",
              "a file already called Dockerfile keeps its name - the name already says what it is")
        check(renamed("api.yaml", "dockerfile") == "api.dockerfile",
              "…but any other stem gets the extension")
        // A rename must never lose the stem, whatever punctuation is in it.
        check(renamed("my notes v2.txt", "sql") == "my notes v2.sql",
              "a stem with spaces should survive a language change intact")
    }

    // MARK: Detection

    private static func checkDetection(_ check: (Bool, String) -> Void) {
        func detect(_ text: String) -> String? { CodePreviewLanguageDetector.detect(text)?.id }

        // Shebangs: the one signal that is never a coincidence.
        check(detect("#!/usr/bin/env python3\nprint('hi')\n") == "python", "a python shebang")
        check(detect("#!/bin/bash\nset -e\necho hi\n") == "shell", "a bash shebang")
        check(detect("#!/bin/sh\necho hi\n") == "shell", "a plain sh shebang")
        check(detect("#!/usr/bin/env node\nconsole.log(1)\n") == "javascript", "a node shebang")

        // Unambiguous markers.
        check(detect("<?xml version=\"1.0\"?><plist><dict/></plist>") == "xml", "an XML declaration")
        check(detect("{\"name\": \"grand-line\", \"private\": true}") == "json",
              "a document that really parses as JSON is JSON")
        check(detect("[1, 2, 3]") == "json", "…including an array")
        check(detect("---\napiVersion: v1\nkind: Service\n") == "yaml", "a YAML document marker")

        // Scored, on real-shaped samples.
        check(detect("""
        import Foundation

        struct Host: Codable {
            let label: String
            func connect() -> Bool { return true }
        }
        """) == "swift", "a Swift struct")
        check(detect("""
        package main

        import "fmt"

        func main() {
            if err != nil {
                fmt.Println(err)
            }
        }
        """) == "go", "a Go main")
        check(detect("""
        use std::collections::HashMap;

        pub fn main() {
            let mut map: HashMap<String, i32> = HashMap::new();
        }
        """) == "rust", "a Rust function")
        check(detect("""
        FROM alpine:3.19
        RUN apk add --no-cache curl
        WORKDIR /srv
        CMD ["/srv/app"]
        """) == "dockerfile", "a Dockerfile")
        check(detect("""
        resource "aws_s3_bucket" "logs" {
          bucket = var.bucket_name
        }

        variable "bucket_name" {
          type = string
        }
        """) == "hcl", "a Terraform file")
        check(detect("""
        SELECT id, name FROM hosts
        WHERE region = 'us-east-1'
        ORDER BY name;
        """) == "sql", "an uppercase SQL query")
        check(detect("""
        select id, name from hosts
        where region = 'us-east-1'
        group by name;
        """) == "sql", "…and a lowercase one - SQL is written both ways")
        check(detect("""
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          labels:
            app: api
        spec:
          containers:
            - name: api
        """) == "yaml", "a Kubernetes manifest without a leading ---")

        // INI/TOML needs both halves of its shape - a `[section]` header AND a
        // bare `key = value` - because neither is evidence on its own.
        check(detect("""
        [server]
        host = localhost
        port = 8080

        [logging]
        level = debug
        """) == "ini", "a real INI file")

        // The regression this suite exists for, caught by the *view* suite on
        // its first run: `ini` used to score a bare `=` and ` = `, which is
        // not evidence of anything - it matched `var greeting = "hello"` and
        // beat Swift's own score, so a pasted Swift file opened as INI.
        check(detect("""
        struct Host {
            let label: String
            var greeting = "hello"
        }
        """) == "swift", "a short Swift struct must not be detected as INI")
        check(detect("count = 3\nname = api\n") == nil,
              "key = value with no section header is not enough to call something INI")
        check(detect("let items = [first]\nlet other = 2\n") == nil,
              "a bracketed line plus an assignment is not an INI file")

        // The shy half, which matters as much as the confident half: a wrong
        // confident answer is worse than Plain Text, because the picker is
        // right there.
        check(detect("") == nil, "empty input detects nothing")
        check(detect("   \n\n  ") == nil, "whitespace detects nothing")
        check(detect("The deploy failed again, can you look?") == nil,
              "a sentence of prose should not be detected as a language")
        check(detect("2026-09-05 12:04:11 INFO  starting up") == nil,
              "a log line should not be detected as a language")
        check(detect("func") == nil,
              "a single keyword should not clear the floor - one word is not a language")

        // Determinism: a dictionary's iteration order is not stable, so a
        // detector that broke ties arbitrarily would flip-flop between runs.
        let sample = "const x = 1;\nlet y = 2;\nfunction f() { return x + y; }\n"
        let readings = Set((0..<20).map { _ in detect(sample) ?? "nil" })
        check(readings.count == 1, "detection is not deterministic: got \(readings)")
    }

    // MARK: Store

    private static func checkStoreRoundTrip(_ check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-preview-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CodePreviewStore(root: dir)

        check(store.gitSync == nil, "an explicitly-rooted store must never carry the production git sync")
        check(store.list().isEmpty, "a fresh store should be empty")
        check(store.nextUntitledName() == "snippet-1.txt", "the first untitled snippet")

        let swiftCode = "import Foundation\n\nlet greeting = \"hi\"\n"
        let created = store.create(name: "HostRow.swift", content: swiftCode)
        check(created.id == "HostRow.swift", "create should keep the name it was given")
        check(created.language.id == "swift", "the language comes from the extension")

        // The body on disk is the code, byte for byte - the whole reason this
        // store does not wrap a snippet in YAML.
        let onDisk = try? String(contentsOf: dir.appendingPathComponent("HostRow.swift"), encoding: .utf8)
        check(onDisk == swiftCode, "the file's bytes should be exactly the snippet, with no wrapper")

        // A *fresh* store over the same directory, so this is a real disk
        // round trip rather than an in-memory cache being read back.
        let reopened = CodePreviewStore(root: dir)
        check(reopened.list().count == 1, "the snippet should survive a reload")
        check(reopened.list().first?.content == swiftCode, "…with its content intact")

        // Disambiguation keeps the extension, or the language would be lost.
        let duplicate = store.create(name: "HostRow.swift", content: "// another")
        check(duplicate.id == "HostRow-2.swift",
              "a colliding name should disambiguate before the extension, got \(duplicate.id)")

        // Rename == move, which is also how a language change is expressed.
        let landed = store.rename(from: "HostRow-2.swift", to: "notes.py")
        check(landed == "notes.py", "rename should report where it landed")
        check(CodePreviewStore(root: dir).list().map(\.id).sorted() == ["HostRow.swift", "notes.py"],
              "the old filename should be gone after a rename")
        check(CodePreviewLanguage.forFilename(landed).id == "python",
              "a rename that changes the extension changes the language")

        // Tab order is filename order, and `snippet-2` must sort before
        // `snippet-10` - a plain lexicographic sort is the one place this
        // reads as a bug.
        for n in [10, 2, 1] { store.create(name: "snippet-\(n).txt", content: "x") }
        let ordered = CodePreviewStore(root: dir).list().map(\.id)
        let snippetOrder = ordered.filter { $0.hasPrefix("snippet-") }
        check(snippetOrder == ["snippet-1.txt", "snippet-2.txt", "snippet-10.txt"],
              "numeric ordering is wrong: \(snippetOrder)")

        // `names()` is the cheap listing the canvas uses - it has to agree
        // with `list()` or the hub and the page would disagree about what is
        // open.
        check(CodePreviewStore(root: dir).names() == ordered,
              "names() should match list()'s order exactly")

        store.delete(name: "notes.py")
        check(!CodePreviewStore(root: dir).list().contains { $0.id == "notes.py" },
              "delete should remove the file")

        // A file that is not text is something else that landed in this
        // folder; showing it as mojibake would be worse than skipping it.
        let binary = Data([0xFF, 0xFE, 0x00, 0x01, 0x02])
        try? binary.write(to: dir.appendingPathComponent("blob.bin"))
        check(!CodePreviewStore(root: dir).list().contains { $0.id == "blob.bin" },
              "a non-UTF-8 file should be skipped, not rendered as mojibake")
    }

    /// The `CommandLibraryStore` lesson, applied before it can bite again.
    ///
    /// This store lives inside `ShiftGitSync`'s working tree, so a suite that
    /// sets only `FM_SHIFT_DIR` - the established way to keep away from the
    /// captain's real synced clone, and what every shell-mounting harness in
    /// this directory already does - must not leave this one store still
    /// reaching into production. `IncidentStore` relies on exactly this
    /// fallback and proves it exactly this way.
    private static func checkStoreHonoursShiftDirOverride(_ check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-preview-shiftdir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let priorOwn = ProcessInfo.processInfo.environment["FM_CODE_PREVIEW_DIR"]
        let priorShift = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        defer {
            if let priorOwn { setenv("FM_CODE_PREVIEW_DIR", priorOwn, 1) } else { unsetenv("FM_CODE_PREVIEW_DIR") }
            if let priorShift { setenv("FM_SHIFT_DIR", priorShift, 1) } else { unsetenv("FM_SHIFT_DIR") }
        }

        unsetenv("FM_CODE_PREVIEW_DIR")
        setenv("FM_SHIFT_DIR", dir.path, 1)
        let viaShift = CodePreviewStore()
        check(viaShift.gitSync == nil,
              "FM_SHIFT_DIR alone must bypass git sync - otherwise a test writes into the captain's real repo")
        check(viaShift.root.path.hasPrefix(dir.path),
              "FM_SHIFT_DIR should root the store under it, got \(viaShift.root.path)")
        check(viaShift.root.lastPathComponent == "code-snippets",
              "…in this feature's own subfolder, never shared with Shift's own files")

        // The narrower override still wins, so a suite can isolate just this
        // store while a sibling `ShiftStore` uses its own real override.
        let own = dir.appendingPathComponent("own", isDirectory: true)
        setenv("FM_CODE_PREVIEW_DIR", own.path, 1)
        let viaOwn = CodePreviewStore()
        check(viaOwn.root.standardizedFileURL == own.standardizedFileURL,
              "FM_CODE_PREVIEW_DIR should win over FM_SHIFT_DIR, got \(viaOwn.root.path)")
    }

    private static func checkNameSanitising(_ check: (Bool, String) -> Void) {
        func clean(_ name: String) -> String { CodePreviewStore.sanitize(name) }

        // The goal is "the same name, minus what a filesystem cannot hold",
        // not a slug - the captain will see this name again.
        check(clean("My Notes v2.txt") == "My Notes v2.txt", "spaces and capitals are kept")
        check(clean("héllo wörld.py") == "héllo wörld.py", "unicode is kept")
        check(clean("a/b.txt") == "a-b.txt", "a path separator cannot be stored")
        check(clean("a:b.txt") == "a-b.txt", "…nor the classic HFS one, which Finder shows as /")
        check(clean(".hidden") == "hidden", "a leading dot would hide the file")
        check(clean("../../escape.txt") == "escape.txt", "a name must not escape the folder")
        check(clean("   padded.txt  ") == "padded.txt", "surrounding whitespace is trimmed")
        check(clean("") == "snippet.txt", "an empty name falls back rather than producing an unnamed file")
        check(clean("   ") == "snippet.txt", "…and so does a whitespace-only one")

        let long = String(repeating: "x", count: 400) + ".swift"
        let trimmed = clean(long)
        check(trimmed.count <= CodePreviewStore.maxNameLength,
              "a very long name should be trimmed to a length a filesystem will take, got \(trimmed.count)")
        check(trimmed.hasSuffix(".swift"),
              "…without losing the extension, which is what carries the language")
    }

    // MARK: Theme

    /// The palette this page hands Monaco, measured rather than trusted.
    ///
    /// Every syntax colour is a theme's own ANSI slot put through
    /// `HelmContrast.legibleOn`, so this asserts the property that guarantees
    /// buys: **every token colour clears the text floor against the editor's
    /// own background, in all fourteen themes**. That is the whole "correct and
    /// legible in both light and dark chrome" requirement, checked in numbers
    /// rather than in a screenshot.
    private static func checkThemePalette(_ check: (Bool, String) -> Void) {
        let tokenKeys: [CodePreviewTheme.Key] = [
            .ink, .comment, .keyword, .string, .constant, .type, .function, .operatorToken, .invalid, .lineNumber,
        ]
        for theme in HelmTheme.allThemes {
            let palette = CodePreviewTheme.palette(for: theme)
            for key in CodePreviewTheme.Key.allCases {
                check(palette[key.rawValue] != nil, "\(theme.id): the palette is missing \(key.rawValue)")
            }
            check(palette[CodePreviewTheme.Key.mode.rawValue] == (theme.mode == .dark ? "dark" : "light"),
                  "\(theme.id): the palette's mode should match the theme's")

            let background = HelmTheme.nsColor(theme.backgroundHex)
            for key in tokenKeys {
                guard let hex = palette[key.rawValue] else { continue }
                let colour = HelmTheme.nsColor(String(hex.dropFirst()))
                let ratio = HelmContrast.ratio(colour, background)
                check(ratio >= 4.5,
                      "\(theme.id): \(key.rawValue) is \(String(format: "%.2f", ratio)):1 on the editor background - below the 4.5:1 text floor")
            }

            // Distinguishable, not merely legible: a palette where keywords
            // and strings resolve to the same colour is legible and useless.
            let distinct = Set([CodePreviewTheme.Key.keyword, .string, .constant, .comment]
                .compactMap { palette[$0.rawValue] })
            check(distinct.count == 4,
                  "\(theme.id): keyword/string/constant/comment do not resolve to four distinct colours")
        }

        // The correction has to be a no-op where nothing needs correcting, or
        // it would be quietly restyling twelve palettes that were already
        // right. `helm-dark`'s slot 8 is documented as deliberately brightened
        // to 4.68:1, so it must survive untouched.
        let helmDark = HelmTheme.allThemes.first { $0.id == "helm-dark" }!
        let comment = CodePreviewTheme.palette(for: helmDark)[CodePreviewTheme.Key.comment.rawValue]
        check(comment?.lowercased() == "#" + helmDark.ansiHex[8].lowercased(),
              "helm-dark's already-legible dim slot should pass through uncorrected, got \(comment ?? "nil")")
    }

    // MARK: Wiring

    private static func checkDestinationWiring(_ check: (Bool, String) -> Void) {
        let dest = RailDestination.codePreview
        check(dest.slot == .codePreview, "the destination should have a body slot of its own")
        check(dest.title == "Code Preview", "the destination's title")
        check(dest.bodyTitle == dest.title, "it is not part of the Setup group, so its body title is its title")
        check(!dest.drillSubtitle.isEmpty, "every destination needs a drill subtitle")
        check(!dest.isDailyUse, "a code panel is a utility, like Tools and the Whiteboard")

        check(NSImage(systemSymbolName: dest.symbol, accessibilityDescription: nil) != nil,
              "the destination's SF Symbol \(dest.symbol) does not resolve - NSImage returns nil silently")

        // The module the canvas draws.
        let module = DaylightModule.allCases.first { $0.opens == .codePreview }
        guard let module else {
            check(false, "no canvas module opens .codePreview")
            return
        }
        check(module.space == .stores, "the Stores space is where the reference material lives")
        check(module.hue == dest.domainHue, "the card and the page it opens must not disagree about a hue")
        check(NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil) != nil,
              "the module's SF Symbol \(module.symbol) does not resolve")
        check(module.gridSpan == 1, "only the Morning briefing is a wide card")
    }
}

#endif
