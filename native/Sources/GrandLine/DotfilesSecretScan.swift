// Grand Line - native macOS app.
//
// S15 (review security finding): the scan that stands between a file dropped
// into `~/.dotfiles/home/` and a public-ish git remote.
//
// `DotfilesAutoSync` defaults to **on**, watches the file system, and stages
// with the equivalent of `git add -A` over `home/`. So a file that happens to
// contain a secret - an `.npmrc` a package manager just wrote, an `.env` moved
// there while tidying, a private key copied in to test something - is
// committed and pushed within seconds of appearing, with no step where anyone
// looks at it. The review is right that this is a leak risk rather than a
// hygiene one, and right that a settings toggle is not the fix: a toggle
// leaves the dangerous default in place for everyone who never finds it.
//
// So the pass refuses instead. A held-back sync is loud, reversible and
// costs the captain one `git commit` by hand if they meant it; a pushed
// secret is none of those things, and on a remote it is permanent even after
// a later delete.
//
// **What this is and is not.** It is a coarse pattern scan, and every one of
// those has false positives and false negatives. It is not a claim that
// anything it passes is safe. It is the difference between "this went out
// before anyone could look" and "this stopped and said why", which is the
// only difference worth buying here.

import Foundation

enum DotfilesSecretScan {

    struct Finding: Equatable {
        /// Repository-relative path, exactly as `git status --short` gave it.
        let path: String
        /// One sentence, shown to the captain.
        let reason: String
    }

    /// Only the first slice of each file is read. A secret is a short string
    /// and it is near the top of the files that carry one; reading a 200MB
    /// binary that landed under `home/` to be thorough would make the watcher
    /// the expensive part of the pass.
    static let bytesInspected = 64 * 1024

    // MARK: Names

    /// Files whose *name alone* is enough, because their whole purpose is to
    /// hold a credential. Matched against the last path component,
    /// case-insensitively.
    static let secretFileNames: Set<String> = [
        ".npmrc", ".netrc", "_netrc", ".pgpass", ".pypirc", ".env",
        "credentials", "kubeconfig", ".dockercfg", ".git-credentials",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "id_ed25519_sk", "id_ecdsa_sk",
    ]

    /// Extensions with the same property.
    static let secretExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "jks", "keystore", "ppk", "kdbx", "asc", "gpg",
    ]

    /// Name *prefixes*, for the families that carry a suffix: `.env.local`,
    /// `.env.production`.
    static let secretNamePrefixes: [String] = [".env.", "id_rsa.", "id_ed25519."]

    /// Suffixes that mean "this file exists to be committed".
    static let templateSuffixes = [".example", ".sample", ".template", ".dist", ".tpl"]

    // MARK: Contents

    /// Literal markers. Substring matches, case-sensitive where the token
    /// itself is (`AKIA`, `ghp_`), because lowercasing them would match
    /// ordinary prose.
    static let contentMarkers: [(marker: String, what: String)] = [
        ("-----BEGIN RSA PRIVATE KEY-----", "an RSA private key"),
        ("-----BEGIN DSA PRIVATE KEY-----", "a DSA private key"),
        ("-----BEGIN EC PRIVATE KEY-----", "an EC private key"),
        ("-----BEGIN OPENSSH PRIVATE KEY-----", "an OpenSSH private key"),
        ("-----BEGIN PGP PRIVATE KEY BLOCK-----", "a PGP private key"),
        ("-----BEGIN PRIVATE KEY-----", "a private key"),
        ("-----BEGIN ENCRYPTED PRIVATE KEY-----", "an encrypted private key"),
        ("AKIA", "what looks like an AWS access key id"),
        ("ASIA", "what looks like an AWS session key id"),
        ("ghp_", "what looks like a GitHub personal access token"),
        ("gho_", "what looks like a GitHub OAuth token"),
        ("ghs_", "what looks like a GitHub server token"),
        ("ghu_", "what looks like a GitHub user token"),
        ("github_pat_", "what looks like a GitHub fine-grained token"),
        ("glpat-", "what looks like a GitLab token"),
        ("xoxb-", "what looks like a Slack bot token"),
        ("xoxp-", "what looks like a Slack user token"),
        ("xapp-", "what looks like a Slack app token"),
        ("sk-ant-", "what looks like an Anthropic API key"),
        ("sk_live_", "what looks like a live Stripe key"),
        ("rk_live_", "what looks like a live Stripe restricted key"),
        ("SG.", "what looks like a SendGrid key"),
        ("AIza", "what looks like a Google API key"),
        ("-----BEGIN CERTIFICATE REQUEST-----", "a certificate request"),
    ]

    /// `KEY = value` shapes, where the key names a secret and the value is
    /// long enough to be one. Deliberately not a bare `password` match:
    /// `# set your password here` is a comment, `PASSWORD=` with nothing
    /// after it is a template, and both are common in dotfiles.
    static let assignmentKeys = [
        "password", "passwd", "secret", "token", "api_key", "apikey",
        "api-key", "access_key", "secret_key", "private_key", "auth_token",
        "client_secret",
    ]

    /// How long an assigned value has to be before it is treated as real
    /// rather than a placeholder. Measured against the shortest credential
    /// worth catching rather than picked round.
    static let minimumAssignedValueLength = 12

    // MARK: The scan

    /// A finding for `path`, or `nil`.
    ///
    /// `contents` is `nil` for a file that could not be read as text, which
    /// includes every binary. That is deliberately **not** a finding: a
    /// wallpaper is not a credential, and refusing everything unreadable
    /// would make the gate one the captain routes around.
    static func inspect(path: String, contents: String?) -> Finding? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if secretFileNames.contains(name) {
            return Finding(path: path, reason: "\(name) is a credentials file")
        }
        if secretExtensions.contains((name as NSString).pathExtension) {
            return Finding(path: path, reason: "\(name) is a key or certificate file")
        }
        // `.env.example`, `.env.sample`, `.env.template` are the shape a repo
        // publishes *on purpose* - they exist to be committed, and holding
        // one back is how a gate gets turned off.
        let isTemplate = templateSuffixes.contains { name.hasSuffix($0) }
        if !isTemplate, let prefix = secretNamePrefixes.first(where: { name.hasPrefix($0) }) {
            return Finding(path: path, reason: "\(name) is a \(prefix.hasPrefix(".env") ? "dotenv" : "private key") file")
        }
        guard let contents else { return nil }
        let head = String(contents.prefix(bytesInspected))
        if let hit = contentMarkers.first(where: { head.contains($0.marker) }) {
            return Finding(path: path, reason: "\(name) contains \(hit.what)")
        }
        if let key = assignedSecretKey(in: head) {
            return Finding(path: path, reason: "\(name) assigns a value to '\(key)'")
        }
        return nil
    }

    /// The first secret-looking assignment in `text`, or `nil`.
    ///
    /// Line by line rather than by regular expression over the whole file,
    /// so "the value" is bounded by the line it is on and a long file cannot
    /// make one key match another line's value.
    static func assignedSecretKey(in text: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix("//") { continue }
            guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            // Strip the shell/config lead-in word if there is one, then only
            // whitespace and quotes. A character-set trim over the *letters*
            // of "export"/"setenv" looks tempting and is wrong: it eats the
            // trailing `t` of `client_secret`, which then matches nothing -
            // measured, and it let a real `client_secret:` line through.
            var key = line[..<separator].lowercased().trimmingCharacters(in: .whitespaces)
            for lead in ["export ", "setenv ", "set "] where key.hasPrefix(lead) {
                key = String(key.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            key = key.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            guard let matched = assignmentKeys.first(where: { key.hasSuffix($0) }) else { continue }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            // A placeholder, a template or an empty assignment is not a
            // secret, and treating one as a secret is how a gate gets turned
            // off. `$VAR` and `$(...)` are indirections, not values.
            guard value.count >= minimumAssignedValueLength,
                  !value.hasPrefix("$"),
                  !value.contains("{{"),
                  !value.lowercased().contains("changeme"),
                  !value.lowercased().contains("your-"),
                  !value.lowercased().contains("xxx") else { continue }
            return matched
        }
        return nil
    }

    /// The sentence the captain is shown when a pass is held back.
    static func refusalMessage(_ findings: [Finding]) -> String {
        let named = findings.prefix(3).map { "\($0.path) (\($0.reason))" }.joined(separator: ", ")
        let more = findings.count > 3 ? " and \(findings.count - 3) more" : ""
        return "Dotfiles auto-commit was held back: \(named)\(more). "
            + "Nothing was committed or pushed. Remove or .gitignore the file, or commit it "
            + "by hand if you meant to publish it."
    }
}
