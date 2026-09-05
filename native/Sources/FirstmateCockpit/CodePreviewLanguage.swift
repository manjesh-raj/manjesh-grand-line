// Manjesh Grand Line - native macOS app.
//
// The Code Preview destination's language table, and the paste-time detector.
//
// ## Why the table is here and not in the page
//
// It has to be here anyway - the picker is a native `HelmPopUpButton` and the
// store derives a snippet's language from its filename - but the *detector*
// could plausibly have lived in JavaScript beside Monaco. It does not, for one
// reason: a heuristic that guesses wrong is a real, visible defect ("I pasted
// YAML and it highlighted as INI"), and the only way to keep it honest over
// time is a suite that runs it against real samples. `FM_RUN_CODE_PREVIEW_TESTS`
// can drive this; nothing in this repo can unit-test a function inside the
// vendored bundle.
//
// ## The set, and why exactly this set
//
// The captain's own named list (Swift, YAML, JSON, shell, Python, JS/TS, Go,
// Rust) plus the formats this app already deals in everywhere else - a cockpit
// that reads Dockerfiles, Terraform and SQL in every other destination should
// not fail to highlight them here. Every id is a real Monaco language id, and
// every one is genuinely in the bundle: `id` is what crosses the bridge to
// `monaco.editor.setModelLanguage`, so a typo here is a snippet that silently
// renders as plain text. `CodePreviewSelfTest.checkLanguageIDsAreInTheBundle`
// greps the committed bundle for each one rather than trusting this comment.

import Foundation

/// One language the panel can highlight.
struct CodePreviewLanguage: Equatable {
    /// Monaco's own language id - the string that crosses the bridge.
    let id: String
    /// What the picker shows.
    let displayName: String
    /// Filename extensions that mean this language, **without** the dot. The
    /// first is canonical: it is what a snippet's filename gets when the
    /// captain picks this language (see `CodePreviewStore`'s note on why the
    /// filename carries the language rather than a metadata sidecar).
    let extensions: [String]

    var canonicalExtension: String { extensions[0] }
}

extension CodePreviewLanguage {

    /// Picker order, and the order the self-test asserts. Plain text first
    /// because it is the fallback and the honest default for a snippet nothing
    /// recognised; the rest alphabetical, so a captain scanning the menu can
    /// find one without learning a ranking.
    static let all: [CodePreviewLanguage] = [
        CodePreviewLanguage(id: "plaintext", displayName: "Plain Text", extensions: ["txt", "text", "log"]),
        CodePreviewLanguage(id: "dockerfile", displayName: "Dockerfile", extensions: ["dockerfile"]),
        CodePreviewLanguage(id: "go", displayName: "Go", extensions: ["go"]),
        CodePreviewLanguage(id: "hcl", displayName: "HCL / Terraform", extensions: ["tf", "hcl", "tfvars"]),
        CodePreviewLanguage(id: "ini", displayName: "INI / TOML", extensions: ["ini", "toml", "conf", "cfg", "properties"]),
        CodePreviewLanguage(id: "javascript", displayName: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"]),
        CodePreviewLanguage(id: "json", displayName: "JSON", extensions: ["json", "jsonc"]),
        CodePreviewLanguage(id: "markdown", displayName: "Markdown", extensions: ["md", "markdown"]),
        CodePreviewLanguage(id: "python", displayName: "Python", extensions: ["py", "pyi"]),
        CodePreviewLanguage(id: "rust", displayName: "Rust", extensions: ["rs"]),
        CodePreviewLanguage(id: "shell", displayName: "Shell", extensions: ["sh", "bash", "zsh", "ksh"]),
        CodePreviewLanguage(id: "sql", displayName: "SQL", extensions: ["sql"]),
        CodePreviewLanguage(id: "swift", displayName: "Swift", extensions: ["swift"]),
        CodePreviewLanguage(id: "typescript", displayName: "TypeScript", extensions: ["ts", "tsx", "mts", "cts"]),
        CodePreviewLanguage(id: "xml", displayName: "XML", extensions: ["xml", "plist", "svg", "xsd"]),
        CodePreviewLanguage(id: "yaml", displayName: "YAML", extensions: ["yaml", "yml"]),
    ]

    static let plainText = all[0]

    static func named(_ id: String) -> CodePreviewLanguage? {
        all.first { $0.id == id }
    }

    /// The language a filename implies. Case-insensitive on the extension, and
    /// `Dockerfile` with no extension at all is recognised by name because
    /// that is genuinely what the file is called - the one filename in this
    /// table that carries its language without a dot.
    static func forFilename(_ name: String) -> CodePreviewLanguage {
        let base = (name as NSString).lastPathComponent
        if base.caseInsensitiveCompare("Dockerfile") == .orderedSame { return named("dockerfile")! }
        let ext = (base as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return plainText }
        return all.first { $0.extensions.contains(ext) } ?? plainText
    }

    /// `name` with `language`'s canonical extension - the one place a language
    /// change is turned into a filename, because in this feature those are the
    /// same act (see `CodePreviewStore`'s header).
    ///
    /// The one exception is a file genuinely *called* `Dockerfile`: its name
    /// already says what it is, so moving it to `Dockerfile.dockerfile` would
    /// be a rename that makes it less recognisable, not more. Every other
    /// language, `Dockerfile` included when the stem is something else, gets
    /// the extension.
    static func filename(_ name: String, as language: CodePreviewLanguage) -> String {
        let ns = name as NSString
        let stem = ns.deletingPathExtension.isEmpty ? name : ns.deletingPathExtension
        if language.id == "dockerfile", stem.caseInsensitiveCompare("Dockerfile") == .orderedSame {
            return stem
        }
        return "\(stem).\(language.canonicalExtension)"
    }
}

// MARK: - Detection

/// Guesses a language from pasted text.
///
/// Deliberately cheap and deliberately shy. The task's own bar is "auto-detect
/// on paste where cheaply possible - a shebang line, obvious keywords - falling
/// back to Plain Text", and the picker is always there to override, so a
/// confident wrong answer is worse than an honest "Plain Text". Every rule
/// below is either an unambiguous marker (a shebang, an XML declaration, a
/// document that really parses as JSON) or a score that has to clear a floor.
enum CodePreviewLanguageDetector {

    /// How many keyword hits a scored language needs before it beats plain
    /// text. Two, not one: a single `func` or `class` shows up in prose about
    /// code as readily as in code, and this panel is as likely to be handed a
    /// log line as a source file.
    static let scoreFloor = 2

    /// The detected language, or `nil` when nothing was confident enough -
    /// which the caller renders as Plain Text.
    ///
    /// `nil` rather than `.plainText` on purpose: "I could not tell" and "this
    /// is definitely plain text" are different answers, and the caller uses
    /// the difference (a detector that says nothing must not overwrite a
    /// language the captain chose by hand).
    static func detect(_ text: String) -> CodePreviewLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let shebang = fromShebang(trimmed) { return shebang }
        if let marker = fromUnambiguousMarker(trimmed) { return marker }
        return fromKeywords(trimmed)
    }

    // MARK: Unambiguous markers

    /// `#!/usr/bin/env python3` and friends. The one signal a file gives about
    /// itself that is never a coincidence.
    private static func fromShebang(_ text: String) -> CodePreviewLanguage? {
        guard text.hasPrefix("#!") else { return nil }
        let line = text.prefix(while: { $0 != "\n" }).lowercased()
        // Ordered longest-first within a family so `python3` is not matched by
        // a shorter, unrelated needle.
        let interpreters: [(needle: String, id: String)] = [
            ("python", "python"), ("bash", "shell"), ("zsh", "shell"), ("ksh", "shell"),
            ("/sh", "shell"), ("env sh", "shell"), ("node", "javascript"), ("deno", "javascript"),
            ("ts-node", "typescript"), ("swift", "swift"),
        ]
        for (needle, id) in interpreters where line.contains(needle) {
            return named(id)
        }
        return nil
    }

    private static func fromUnambiguousMarker(_ text: String) -> CodePreviewLanguage? {
        let lower = text.lowercased()
        if lower.hasPrefix("<?xml") || lower.hasPrefix("<!doctype") || lower.hasPrefix("<svg") {
            return named("xml")
        }
        // A document that genuinely parses as JSON is JSON - no scoring
        // needed, and this is the case a keyword heuristic gets wrong most
        // often (a JSON object of shell commands scores as shell).
        if (text.hasPrefix("{") && text.hasSuffix("}")) || (text.hasPrefix("[") && text.hasSuffix("]")) {
            if let data = text.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                return named("json")
            }
        }
        // A YAML document marker is only ever a YAML document marker. Checked
        // before the keyword pass because `---` followed by Kubernetes-shaped
        // keys would otherwise be scored rather than known.
        if text.hasPrefix("---\n") || text == "---" || text.hasPrefix("---\r\n") {
            return named("yaml")
        }
        if looksLikeINI(text) { return named("ini") }
        return nil
    }

    /// A `[section]` header line, plus at least one `key = value` under it.
    ///
    /// INI/TOML gets a shape rule rather than a row in the scored table
    /// because it has no discriminating *substring* - see that table's own
    /// note. Both halves are required: a lone `[thing]` line is as likely to
    /// be a Swift array literal or a markdown link as a section header, and
    /// `key = value` on its own is most of the languages here.
    private static func looksLikeINI(_ text: String) -> Bool {
        var sawSection = false
        var sawAssignment = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]"), line.count > 2,
               line.dropFirst().dropLast().allSatisfy({
                   $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == "\"" || $0 == " "
               }) {
                sawSection = true
                continue
            }
            // A bare key on the left of the first `=`, i.e. no punctuation
            // that would make this a line of code rather than a setting.
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) {
                sawAssignment = true
            }
        }
        return sawSection && sawAssignment
    }

    // MARK: Scoring

    /// A weighted marker: a substring, and how much seeing it says.
    private struct Marker {
        let needle: String
        let weight: Int
        /// Must the needle appear at the very start of a line? The markers
        /// that would otherwise fire inside a string literal or a comment.
        let anchoredToLineStart: Bool

        init(_ needle: String, _ weight: Int = 1, lineStart: Bool = false) {
            self.needle = needle
            self.weight = weight
            self.anchoredToLineStart = lineStart
        }
    }

    /// The scored table. Each language's markers are chosen to be things that
    /// are *rare in the other languages here*, not merely common in this one -
    /// `func` alone separates Swift from Python but not from Go, so the ones
    /// that carry weight are the pairings that genuinely disambiguate
    /// (`func ` + `let `/`var ` + `->` for Swift; `func ` + `package `/`:=`
    /// for Go).
    private static let markers: [String: [Marker]] = [
        "swift": [
            Marker("import Foundation", 3), Marker("import AppKit", 3), Marker("import SwiftUI", 3),
            Marker("@objc", 2), Marker("guard let ", 2), Marker("if let ", 2),
            Marker("func ", 1, lineStart: false), Marker("-> ", 1),
            Marker("struct ", 1), Marker("enum ", 1), Marker("extension ", 2),
            Marker("private ", 1), Marker("weak var ", 2), Marker("nil", 1),
            Marker("let ", 1), Marker("var ", 1),
            // A capitalised type annotation. The single best Swift/TypeScript
            // discriminator in this whole table: both languages annotate with
            // `: Type`, and Swift's built-ins are capitalised where
            // TypeScript's are not (`: string` is in the TypeScript row).
            Marker(": String", 2), Marker(": Int", 2), Marker(": Bool", 2),
        ],
        "go": [
            Marker("package main", 3), Marker("func main()", 3),
            Marker("import (", 2), Marker(":= ", 2), Marker("err != nil", 3),
            Marker("fmt.", 2), Marker("go func", 2), Marker("package ", 1, lineStart: true),
        ],
        "rust": [
            Marker("fn main()", 3), Marker("use std::", 3), Marker("let mut ", 3),
            Marker("impl ", 2), Marker("->", 1), Marker("pub fn ", 3),
            Marker("#[derive", 3), Marker("&str", 2), Marker("::new(", 1),
            Marker("match ", 1), Marker("Option<", 2), Marker("Result<", 2),
        ],
        "python": [
            Marker("def ", 2, lineStart: false), Marker("import ", 1, lineStart: true),
            Marker("from ", 1, lineStart: true), Marker("self.", 2),
            Marker("if __name__", 3), Marker("elif ", 2), Marker("print(", 1),
            Marker("None", 1), Marker("True", 1), Marker("False", 1),
            Marker("class ", 1), Marker("):", 1),
        ],
        "typescript": [
            Marker("interface ", 2), Marker(": string", 3), Marker(": number", 3),
            Marker(": boolean", 3), Marker("export type", 3), Marker("as const", 2),
            Marker("readonly ", 2), Marker("implements ", 2), Marker("<T>", 2),
        ],
        "javascript": [
            Marker("const ", 1), Marker("let ", 1), Marker("=> ", 1),
            Marker("function ", 1), Marker("require(", 2), Marker("module.exports", 3),
            Marker("console.log", 2), Marker("async function", 2), Marker("export default", 2),
        ],
        "shell": [
            Marker("echo ", 1), Marker("set -e", 3), Marker("fi\n", 2), Marker("done\n", 2),
            Marker("$(", 1), Marker("${", 1), Marker("if [", 3), Marker("then\n", 2),
            Marker("export ", 1, lineStart: true), Marker("sudo ", 2), Marker("|| exit", 2),
        ],
        "sql": [
            Marker("select ", 2), Marker("from ", 1), Marker("where ", 1),
            Marker("insert into", 3), Marker("create table", 3), Marker("join ", 2),
            Marker("group by", 3), Marker("order by", 2), Marker("alter table", 3),
        ],
        "hcl": [
            Marker("resource \"", 3), Marker("variable \"", 3), Marker("provider \"", 3),
            Marker("module \"", 3), Marker("terraform {", 3), Marker("data \"", 2),
            Marker("output \"", 2), Marker("${var.", 3), Marker("= var.", 2),
        ],
        "dockerfile": [
            Marker("FROM ", 3, lineStart: true), Marker("RUN ", 2, lineStart: true),
            Marker("COPY ", 2, lineStart: true), Marker("ENTRYPOINT", 3, lineStart: true),
            Marker("WORKDIR ", 3, lineStart: true), Marker("CMD ", 2, lineStart: true),
            Marker("EXPOSE ", 2, lineStart: true),
        ],
        "yaml": [
            Marker("apiVersion:", 3), Marker("kind:", 3), Marker("metadata:", 2),
            Marker("spec:", 2), Marker("- name:", 2), Marker("  - ", 1),
            Marker("labels:", 2), Marker("containers:", 3),
        ],
        "markdown": [
            Marker("## ", 2, lineStart: true), Marker("### ", 2, lineStart: true),
            Marker("```", 2), Marker("- [ ] ", 3), Marker("](http", 2),
            Marker("**", 1),
        ],
        "xml": [
            Marker("</", 2), Marker("/>", 2), Marker("<?", 2), Marker("xmlns", 3),
        ],
        // INI/TOML is deliberately **absent** from the scored table - see
        // `looksLikeINI` for the precise rule it gets instead. Its first
        // version scored `=` and ` = `, which is not evidence of anything: it
        // matched the Swift sample below on `var greeting = "hello"` and beat
        // Swift's own score, so a pasted Swift file opened as an INI file.
        // There is no *substring* that means INI - only the shape of a
        // `[section]` header line does - so it gets a rule rather than a row.
    ]

    private static func fromKeywords(_ text: String) -> CodePreviewLanguage? {
        // Case-sensitive except for SQL, which is written both ways as often
        // as not - so SQL alone is scored against a lowered copy.
        let lowered = text.lowercased()
        let lineStarts = lineStartSet(text)

        var best: (id: String, score: Int)?
        for (id, markers) in markers {
            let haystack = (id == "sql") ? lowered : text
            var score = 0
            for marker in markers {
                let needle = (id == "sql") ? marker.needle.lowercased() : marker.needle
                if marker.anchoredToLineStart {
                    score += lineStarts.filter { $0.hasPrefix(needle) }.count > 0 ? marker.weight : 0
                } else if haystack.contains(needle) {
                    score += marker.weight
                }
            }
            guard score >= scoreFloor else { continue }
            // Ties broken by id so the same input always detects the same
            // language - a dictionary's iteration order is not stable, and a
            // detector that flip-flops between runs is worse than one that is
            // consistently a bit wrong.
            if let current = best {
                if score > current.score || (score == current.score && id < current.id) {
                    best = (id, score)
                }
            } else {
                best = (id, score)
            }
        }
        guard let best else { return nil }
        return named(best.id)
    }

    /// Every line with its leading whitespace stripped, for the markers that
    /// only mean something at the start of a line (`FROM` in a Dockerfile is a
    /// directive; `FROM` in the middle of a line is SQL or prose).
    private static func lineStartSet(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func named(_ id: String) -> CodePreviewLanguage? {
        CodePreviewLanguage.named(id)
    }
}
