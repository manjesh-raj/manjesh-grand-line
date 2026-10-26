// Grand Line - native macOS app.
//
// Import hosts from `~/.ssh/config` (X1 of the captain's Termius-style plan).
//
// This file is the pure half: it reads an OpenSSH client config and turns
// each concrete `Host` alias into a candidate `Host`, with a reason when one
// should not be imported. The preview (`SSHConfigImportPanel`) shows every
// candidate and imports only what the captain leaves ticked.
//
// What it reads, and what it deliberately does not:
//
//   - `Host` blocks with concrete aliases. One block naming several aliases
//     (`Host web1 web2`) is one candidate per alias, each with the block's
//     options. A pattern (`*`, `?`, `!`) is not a host you can connect to by
//     name, so a block of only patterns is skipped, and a pattern beside
//     real aliases is dropped from it.
//   - `HostName`, `User`, `Port`, `ProxyJump`, `ForwardAgent`, and
//     `LocalForward` / `RemoteForward` / `DynamicForward` - every option a
//     Grand Line host already has a field for. ssh's rule holds: the first
//     value of an option in a block wins.
//   - **Not** `Match` blocks (conditional, and nothing here can evaluate
//     them), `Include` (it reaches other files the captain did not point
//     at), or defaults set by `Host *` (they would silently change every
//     host). The preview says so rather than guessing.
//   - **Not** `IdentityFile`. A Grand Line host refers to a key in the
//     Keychain, never a path, so a candidate notes the file and the captain
//     imports that key on Keys - this file never reads a private key.
//
// GL-08: a candidate whose address, user or jump host starts with "-" is
// refused here, exactly as the host editor and `.glbackup` import refuse
// one, because `ssh` would read it as an option.

import Foundation

enum SSHConfigImport {

    /// One host the config names, and whether to offer it ticked.
    struct Candidate: Equatable {
        var host: Host
        /// The `IdentityFile` the block names, for the preview's note.
        var identityFile: String?
        /// Why this one is not ticked by default, or `nil` to import it.
        var skipReason: SkipReason?

        static func == (a: Candidate, b: Candidate) -> Bool {
            a.host.label == b.host.label && a.host.address == b.host.address && a.host.port == b.host.port
                && a.host.username == b.host.username && a.identityFile == b.identityFile && a.skipReason == b.skipReason
        }
    }

    enum SkipReason: Equatable {
        /// A saved host already has this name or this destination.
        case alreadySaved
        /// A field starts with "-" (GL-08), or the port is not a port.
        case unsafe(String)

        var text: String {
            switch self {
            case .alreadySaved: return "Already saved"
            case .unsafe(let why): return why
            }
        }

        /// An unsafe candidate can never be ticked; an already-saved one can.
        var canImport: Bool {
            if case .unsafe = self { return false }
            return true
        }
    }

    /// What the parse found besides hosts, said in the preview.
    struct Result: Equatable {
        var candidates: [Candidate] = []
        /// `Host` patterns with no concrete alias (`Host *`), skipped.
        var skippedPatterns = 0
        /// `Match` blocks, skipped.
        var skippedMatchBlocks = 0
        /// `Include` lines, not followed.
        var includes = 0
    }

    // MARK: Where

    #if FM_SELFTESTS
    /// A suite's fixture config, so no suite ever reads the captain's own.
    static var configURLOverrideForTests: URL?
    #endif

    /// `~/.ssh/config`, or `FM_SSH_CONFIG_FILE`, or a scratch path in a run
    /// whose stores are redirected.
    static var configURL: URL {
        #if FM_SELFTESTS
        if let override = configURLOverrideForTests { return override }
        #endif
        if let override = ProcessInfo.processInfo.environment["FM_SSH_CONFIG_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        // A probe or an isolated run never reads the captain's config: it is
        // outside Application Support, so `FM_SCRATCH_ROOT` cannot move it.
        if AppPaths.isScratchRedirected() {
            return AppPaths.dataRoot().appendingPathComponent("ssh-config")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true).appendingPathComponent("config")
    }

    // MARK: Parsing

    /// Parse `text`, marking every candidate against `existing` hosts.
    static func parse(_ text: String, existing: [Host] = []) -> Result {
        var result = Result()
        var aliases: [String] = []
        var options: [String: [String]] = [:]
        var inMatch = false

        func flush() {
            defer { aliases = []; options = [:] }
            guard !aliases.isEmpty else { return }
            for alias in aliases { result.candidates.append(candidate(alias: alias, options: options)) }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (keyword, args) = split(line)
            switch keyword {
            case "host":
                flush()
                inMatch = false
                let concrete = args.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                if concrete.isEmpty { result.skippedPatterns += 1 }
                aliases = concrete
            case "match":
                flush()
                inMatch = true
                result.skippedMatchBlocks += 1
            case "include":
                result.includes += 1
            default:
                guard !inMatch, !aliases.isEmpty, let value = args.first else { continue }
                // ssh: the first value of an option wins. The forwards are
                // the exception - each line adds one.
                if keyword.hasSuffix("forward") && keyword != "forwardagent" {
                    options[keyword, default: []].append(args.joined(separator: " "))
                } else if options[keyword] == nil {
                    options[keyword] = [value]
                }
            }
        }
        flush()
        result.candidates = result.candidates.map { mark($0, against: existing) }
        return result
    }

    /// `Keyword value...`, or `Keyword=value`, with quotes removed.
    private static func split(_ line: String) -> (String, [String]) {
        var text = line
        var keyword = ""
        if let separator = text.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) {
            keyword = String(text[..<separator])
            text = String(text[text.index(after: separator)...])
        } else {
            return (line.lowercased(), [])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        var args: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle(); continue }
            if !quoted, character == " " || character == "\t" {
                if !current.isEmpty { args.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { args.append(current) }
        return (keyword.lowercased(), args)
    }

    private static func candidate(alias: String, options: [String: [String]]) -> Candidate {
        var host = Host(label: alias, address: options["hostname"]?.first ?? alias)
        host.username = options["user"]?.first ?? ""
        var reason: SkipReason?
        if let port = options["port"]?.first {
            if let value = Int(port), (1...65_535).contains(value) {
                host.port = value
            } else {
                reason = .unsafe("Port \u{201C}\(port)\u{201D} is not a port")
            }
        }
        host.jumpVia = options["proxyjump"]?.first.flatMap { $0.lowercased() == "none" ? nil : $0 }
        host.agentForward = options["forwardagent"]?.first?.lowercased() == "yes"
        for (keyword, kind) in [("localforward", PortForwardRule.Kind.local), ("remoteforward", .remote),
                                ("dynamicforward", .dynamic)] {
            for spec in options[keyword] ?? [] {
                if let rule = forward(spec, kind: kind) { host.portForwards.append(rule) }
            }
        }
        if reason == nil, !host.unsafeFieldNames.isEmpty {
            reason = .unsafe("\(host.unsafeFieldNames.joined(separator: " and ")) starts with \u{201C}-\u{201D}")
        }
        return Candidate(host: host, identityFile: options["identityfile"]?.first, skipReason: reason)
    }

    /// `LocalForward [bind:]port host:hostport`, `DynamicForward [bind:]port`.
    static func forward(_ spec: String, kind: PortForwardRule.Kind) -> PortForwardRule? {
        let parts = spec.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let listen = parts.first else { return nil }
        var rule = PortForwardRule()
        rule.kind = kind
        let parsedListen = PortForwardInlineEditor.parseListen(listen)
        guard (1...65_535).contains(parsedListen.port) else { return nil }
        rule.bindAddress = parsedListen.bind
        rule.listenPort = parsedListen.port
        if kind != .dynamic {
            guard parts.count >= 2 else { return nil }
            let destination = PortForwardInlineEditor.parseDestination(parts[1])
            guard !destination.host.isEmpty, (1...65_535).contains(destination.port),
                  !Host.hasUnsafeLeadingDash(destination.host) else { return nil }
            rule.destHost = destination.host
            rule.destPort = destination.port
        }
        return rule
    }

    /// Already saved: a host with this name, or the same destination and port.
    private static func mark(_ candidate: Candidate, against existing: [Host]) -> Candidate {
        guard candidate.skipReason == nil else { return candidate }
        let host = candidate.host
        let saved = existing.contains { other in
            other.label.caseInsensitiveCompare(host.label) == .orderedSame
                || (other.destination == host.destination && other.port == host.port)
        }
        var marked = candidate
        if saved { marked.skipReason = .alreadySaved }
        return marked
    }

    /// Read and parse the config. `nil` when there is no file to read.
    static func load(existing: [Host]) -> Result? {
        guard let data = try? Data(contentsOf: configURL), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parse(text, existing: existing)
    }
}
