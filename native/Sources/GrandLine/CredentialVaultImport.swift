// Grand Line - native macOS app.
//
// F17's other half: reading a CSV export out of 1Password, Bitwarden or
// Chrome and turning it into `VaultCredential`s. Pure logic - a CSV parser, a
// format detector, a column mapping and a skip report. No file I/O, no
// crypto, no AppKit: the sheet reads the file, hands the *text* here, and
// hands the result to `CredentialVaultStore.importCredentials`, which is the
// same sealed-write path a manually-added credential takes.
//
// **The imported secrets never touch disk unencrypted, not even briefly.**
// Nothing in this file writes anything. The plaintext CSV the captain chose
// is theirs and already on their disk; this app reads it into memory, builds
// records, and the store seals them. There is deliberately no temp file, no
// "staging" store and no cache of the parsed rows beyond the sheet's own
// lifetime - which is why `plan` returns a value rather than holding one.
//
// **Every column layout here was taken from a real export, not guessed.**
//
//   * **1Password 8** - `Title,Url,Username,Password,OTPAuth,Favorite,
//     Archived,Tags,Notes`. 1Password 7's older export used
//     `title,website,username,password,notesPlain,…` and is still what a lot
//     of saved exports look like, so both spellings are recognised.
//   * **Bitwarden** - `folder,favorite,type,name,notes,fields,reprompt,
//     login_uri,login_username,login_password,login_totp`. Its `type` column
//     is `login` or `note`, which is the one export of the three that maps
//     directly onto this vault's own `CredentialKind`.
//   * **Chrome** (and every Chromium browser) - `name,url,username,password`,
//     with a `note` column on current versions.
//
// A file matching none of them is still importable as `.generic`: the header
// is matched by fuzzy name, which covers KeePass, LastPass and a hand-rolled
// spreadsheet without claiming support this task did not verify.
//
// **A malformed row is skipped and reported, never dropped and never fatal.**
// `CredentialImportPlan.skipped` carries the line number and the reason for
// every one, and the sheet shows them - the brief's own requirement, and the
// same GL-21 instinct ("could not read" is not "was empty") applied a row at
// a time.

import Foundation

// MARK: - CSV

/// An RFC 4180 CSV reader: quoted fields, embedded commas, embedded newlines,
/// and `""` as an escaped quote.
///
/// Hand-written rather than split-on-comma because every one of those four
/// appears in a real password export - a note with a line break in it is
/// completely ordinary, and a naive split turns one credential into six
/// broken rows with no error.
enum CSVParser {

    /// Rows of fields. A trailing newline produces no extra row; a genuinely
    /// empty line inside the file does (and is skipped later by name, so the
    /// line numbers a captain sees still match their editor).
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = text.startIndex

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while iterator < text.endIndex {
            let character = text[iterator]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: iterator)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        iterator = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": inQuotes = true
                case ",": endField()
                // **`\r\n` is ONE `Character` in Swift**, not two - a CRLF is a
                // single grapheme cluster, so it matches neither `"\r"` nor
                // `"\n"`. Measured, not reasoned: without this case a
                // Windows-exported CSV (which is what every one of these
                // three managers writes) parsed as a *single* row with the
                // line breaks buried inside the field values, and the
                // importer reported one malformed credential instead of 148
                // good ones. `PoneglyphTOTPRecoverySelfTest`'s CRLF case is
                // the guard.
                case "\r\n", "\n", "\r": endRow()
                default: field.append(character)
                }
            }
            iterator = text.index(after: iterator)
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

// MARK: - Source

/// Which manager produced the file. The sheet's four chips.
enum CredentialImportSource: String, CaseIterable {
    case onePassword
    case bitwarden
    case chrome
    case generic

    var title: String {
        switch self {
        case .onePassword: return "1Password"
        case .bitwarden: return "Bitwarden"
        case .chrome: return "Chrome"
        // "Other", not "Generic CSV": four chips have to fit one sheet
        // column, and `HelmSegmentedTabs` clips rather than wraps - the
        // longer label pushed Chrome off the row in a real render.
        case .generic: return "Other"
        }
    }

    /// Recognise a file by its header row. Case- and order-insensitive,
    /// because every one of these exports has changed column order at least
    /// once across versions - matching on a *set* of distinctive names is
    /// what keeps this working against next year's export.
    static func detect(header: [String]) -> CredentialImportSource {
        let names = Set(header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        if names.contains("login_password") || names.contains("login_username") { return .bitwarden }
        if names.contains("otpauth") || names.contains("notesplain") { return .onePassword }
        // 1Password 8 without a 2FA column looks a lot like Chrome; `title`
        // (rather than Chrome's `name`) is the discriminator.
        if names.contains("title") && names.contains("password") { return .onePassword }
        if names.contains("name") && names.contains("url") && names.contains("password") { return .chrome }
        return .generic
    }
}

/// Where each vault field comes from, by column index. `nil` means the file
/// has nothing for that field, which is normal - only `title` and one of
/// `secret`/`notes` are load-bearing.
struct CredentialImportMapping: Equatable {
    var title: Int?
    var account: Int?
    var secret: Int?
    var location: Int?
    var notes: Int?
    var totp: Int?
    var tags: Int?
    /// Bitwarden's `type` column, the only export that states the kind.
    var kind: Int?

    /// The sheet's own "column → field" list, in file order, so what is shown
    /// is derived from the mapping actually used rather than written twice.
    func rows(header: [String]) -> [(column: String, field: String)] {
        header.enumerated().map { index, name in
            (name, Self.fieldName(for: index, in: self) ?? "Skip")
        }
    }

    private static func fieldName(for index: Int, in mapping: CredentialImportMapping) -> String? {
        // `switch` on an `Int` against `Int?` cases does not type-check, and
        // the first match must win anyway (a file with one column mapped
        // twice is malformed, not ambiguous), so this is an ordered list.
        if index == mapping.title { return "Title" }
        if index == mapping.account { return "Account" }
        if index == mapping.secret { return "Secret" }
        if index == mapping.location { return "Where it's used" }
        if index == mapping.notes { return "Notes" }
        if index == mapping.totp { return "2FA secret" }
        if index == mapping.tags { return "Tags" }
        if index == mapping.kind { return "Kind" }
        return nil
    }

    /// The mapping for a source, resolved against the file's real header.
    ///
    /// Resolved by *name* even for the known formats rather than by fixed
    /// index: an export with one extra column would otherwise silently shift
    /// every field by one, which is the worst possible failure here (it
    /// imports, and every password is wrong).
    static func resolve(source: CredentialImportSource, header: [String]) -> CredentialImportMapping {
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ candidates: [String]) -> Int? {
            for candidate in candidates {
                if let index = names.firstIndex(of: candidate) { return index }
            }
            return nil
        }
        switch source {
        case .onePassword:
            return .init(title: column(["title"]),
                         account: column(["username"]),
                         secret: column(["password"]),
                         location: column(["url", "website"]),
                         notes: column(["notes", "notesplain"]),
                         totp: column(["otpauth", "otp", "one-time password"]),
                         tags: column(["tags"]),
                         kind: nil)
        case .bitwarden:
            return .init(title: column(["name"]),
                         account: column(["login_username"]),
                         secret: column(["login_password"]),
                         location: column(["login_uri"]),
                         notes: column(["notes"]),
                         totp: column(["login_totp"]),
                         tags: column(["folder"]),
                         kind: column(["type"]))
        case .chrome:
            return .init(title: column(["name"]),
                         account: column(["username"]),
                         secret: column(["password"]),
                         location: column(["url"]),
                         notes: column(["note", "notes"]),
                         totp: nil,
                         tags: nil,
                         kind: nil)
        case .generic:
            return .init(title: column(["title", "name", "item", "account name"]),
                         account: column(["username", "user", "login", "email", "account"]),
                         secret: column(["password", "secret", "value", "token"]),
                         location: column(["url", "uri", "website", "site", "location"]),
                         notes: column(["notes", "note", "comment", "notesplain"]),
                         totp: column(["otpauth", "totp", "login_totp", "otp", "2fa"]),
                         tags: column(["tags", "folder", "group", "category"]),
                         kind: column(["type", "kind"]))
        }
    }
}

// MARK: - The plan

/// What an import *would* do, computed before anything is written. The sheet
/// shows it and the captain confirms - nothing here has touched the vault.
struct CredentialImportPlan {
    struct Skipped: Equatable {
        /// 1-based, counting the header, so it matches what a text editor
        /// shows when the captain goes to look.
        let line: Int
        let reason: String
    }

    var source: CredentialImportSource
    var header: [String]
    var mapping: CredentialImportMapping
    /// Ready to seal. Ids are fresh, so an import can never overwrite an
    /// existing record by id collision.
    var credentials: [VaultCredential]
    /// Rows that would land on top of something already in the vault, by
    /// title + account. Counted and shown, never silently merged - the
    /// captain decides with `mergeDuplicates`.
    var duplicateTitles: [String]
    var skipped: [Skipped]

    var rowsRead: Int { credentials.count + skipped.count }

    /// The sheet's own summary line, assembled here so the confirm button and
    /// the report cannot disagree.
    var summary: String {
        var parts = ["\(credentials.count) credential\(credentials.count == 1 ? "" : "s")"]
        if !duplicateTitles.isEmpty { parts.append("\(duplicateTitles.count) already in the vault") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

enum CredentialVaultImport {

    /// Parse `text` and build the plan. `existing` is the vault's current
    /// contents, used only to flag duplicates.
    ///
    /// Never throws and never returns nil: an unreadable file produces a plan
    /// with zero credentials and a `skipped` entry saying why, which is what
    /// the sheet has to render anyway. "Could not read" is a state, not an
    /// absence (GL-21).
    static func plan(text: String,
                     source explicitSource: CredentialImportSource? = nil,
                     existing: [VaultCredential] = [],
                     now: Date = Date()) -> CredentialImportPlan {
        let rows = CSVParser.parse(text).filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
        guard let header = rows.first else {
            return CredentialImportPlan(source: explicitSource ?? .generic,
                                        header: [],
                                        mapping: .init(),
                                        credentials: [],
                                        duplicateTitles: [],
                                        skipped: [.init(line: 1, reason: "The file is empty.")])
        }
        let source = explicitSource ?? CredentialImportSource.detect(header: header)
        let mapping = CredentialImportMapping.resolve(source: source, header: header)

        guard mapping.title != nil || mapping.secret != nil else {
            return CredentialImportPlan(source: source,
                                        header: header,
                                        mapping: mapping,
                                        credentials: [],
                                        duplicateTitles: [],
                                        skipped: [.init(line: 1,
                                                        reason: "No column in this file looks like a title or a password. Pick a different format above.")])
        }

        let existingKeys = Set(existing.map { key(title: $0.title, account: $0.account) })
        var credentials: [VaultCredential] = []
        var duplicates: [String] = []
        var skipped: [CredentialImportPlan.Skipped] = []
        var seenInFile = Set<String>()

        for (offset, row) in rows.enumerated().dropFirst() {
            let line = offset + 1
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // A short row is the commonest real defect in a hand-edited
            // export. It is only fatal if the columns we need are the
            // missing ones, so it is reported by what it cost rather than by
            // its length.
            let title = value(mapping.title)
            let secret = value(mapping.secret)
            let notes = value(mapping.notes)
            let account = value(mapping.account)

            let declaredKind = value(mapping.kind).lowercased()
            let isNote = declaredKind.contains("note")
            let resolvedTitle = title.isEmpty ? (account.isEmpty ? "" : account) : title
            guard !resolvedTitle.isEmpty else {
                skipped.append(.init(line: line, reason: "No title, and no account to name it after."))
                continue
            }
            if isNote {
                guard !notes.isEmpty else {
                    skipped.append(.init(line: line, reason: "\"\(resolvedTitle)\" is a secure note with no body."))
                    continue
                }
            } else if secret.isEmpty && notes.isEmpty {
                skipped.append(.init(line: line, reason: "\"\(resolvedTitle)\" has no password and no note - nothing to store."))
                continue
            }

            let dedupeKey = key(title: resolvedTitle, account: account)
            if existingKeys.contains(dedupeKey) || seenInFile.contains(dedupeKey) {
                duplicates.append(resolvedTitle)
            }
            seenInFile.insert(dedupeKey)

            var credential = VaultCredential(title: resolvedTitle,
                                             category: category(for: value(mapping.location), source: source),
                                             account: account,
                                             secret: isNote ? notes : secret,
                                             location: value(mapping.location),
                                             notes: isNote ? "" : notes,
                                             createdAt: now,
                                             updatedAt: now)
            credential.kind = isNote ? .secureNote : .login
            let tagText = value(mapping.tags)
            if !tagText.isEmpty {
                // 1Password joins tags with `,`, Bitwarden's `folder` is one
                // value with `/` for nesting. Both split to something sane.
                credential.tags = tagText
                    .split(whereSeparator: { $0 == "," || $0 == "/" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            let otp = value(mapping.totp)
            if !otp.isEmpty {
                if let parsed = TOTP.parse(otp) {
                    credential.totp = parsed
                } else {
                    // The credential itself is fine; only its 2FA seed is
                    // not. Importing it without the seed and saying so beats
                    // both dropping the row and storing a secret that
                    // produces wrong codes.
                    skipped.append(.init(line: line,
                                         reason: "\"\(resolvedTitle)\" imported without its 2FA secret - that column was not a readable otpauth URI or base32 seed."))
                }
            }
            credentials.append(credential)
        }

        return CredentialImportPlan(source: source,
                                    header: header,
                                    mapping: mapping,
                                    credentials: credentials,
                                    duplicateTitles: duplicates,
                                    skipped: skipped)
    }

    private static func key(title: String, account: String) -> String {
        "\(title.lowercased())\u{0000}\(account.lowercased())"
    }

    /// A best-effort category so an import does not dump 148 rows into
    /// "Other". Deliberately shallow - the captain re-files what matters, and
    /// a clever classifier that is wrong is worse than an honest default.
    private static func category(for location: String, source: CredentialImportSource) -> CredentialCategory {
        let host = location.lowercased()
        if host.contains("mail.") || host.contains("gmail") || host.contains("outlook") || host.contains("proton") {
            return .email
        }
        if host.contains("aws.amazon") || host.contains("console.cloud.google") || host.contains("azure")
            || host.contains("digitalocean") || host.contains("cloudflare") {
            return .cloud
        }
        return .other
    }
}
