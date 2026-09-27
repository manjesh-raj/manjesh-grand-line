// Grand Line - native macOS app.
//
// S2/S8 (review security findings): what the shared-terminal bridge is allowed
// to type into the captain's already-authenticated bastion shell.
//
// ---------------------------------------------------------------------------
// WHY THIS EXISTS AT ALL, GIVEN THE PYTHON SCRIPT ALREADY VALIDATES
// ---------------------------------------------------------------------------
// `SRELeadBridge` used to take the `command` string out of any
// `request-<id>.json` that appeared in its scratch directory and type it into
// the connected host verbatim. Every safety property the feature claimed -
// read-only verbs, no shell metacharacters, no write verbs - lived in
// `Scripts/sre_kubectl_mcp.py`, a *different process*. The bridge's own
// protection was the directory's 0700 mode and nothing else.
//
// That is one mechanism, not two. Anything running as the captain can drop a
// file into a 0700 directory owned by the captain: another agent, a stray
// script, a compromised dependency of any tool in the session - and the
// bridge would have typed its contents into a root-capable bastion shell. The
// MCP script is also spawned by `claude`, so a prompt injection that reaches
// the model's tool loop reaches the request file; the script is inside the
// trust boundary it was being asked to enforce.
//
// So this is the second, independent check, applied at the point of
// execution. It deliberately restates the script's rules rather than sharing
// them: two copies that must agree is the point of defense in depth, and
// `SRELeadBridgeCommandPolicySelfTest` asserts both halves stay in step with
// `sre_kubectl_mcp.py`'s own tables by reading that file.
//
// ---------------------------------------------------------------------------
// WHAT A LEGITIMATE COMMAND LOOKS LIKE
// ---------------------------------------------------------------------------
// Both of the script's two producers (`_run_kubectl` and `_run_runbook`) build
// the string the same way: `" ".join(shlex.quote(tok) for tok in ["kubectl",
// verb] + args)`. So a legitimate command is always a `kubectl` invocation
// whose tokens are either bare or wrapped in POSIX single quotes - never a
// pipeline, a redirect, a substitution or a second command. Anything else is
// refused here whatever the script thought of it.

import Foundation

enum SRELeadBridgeCommandPolicy {

    /// Why a command was refused. The string is written into the bridge's
    /// response file, so the persona is told what it did wrong rather than
    /// silently timing out.
    struct Refusal: Error, Equatable {
        let reason: String
    }

    // MARK: The tables

    /// The read-only verb surface, restated from `_ALLOWED_VERBS`.
    static let allowedVerbs: Set<String> = ["get", "describe", "logs", "top", "events", "config"]

    /// Restated from `_CONFIG_READONLY_SUBCOMMANDS`.
    static let allowedConfigSubcommands: Set<String> = ["get-contexts", "current-context"]

    /// Restated from `_DENIED_FLAGS` (S2): flags that change *where* the
    /// command connects or *who* it authenticates as.
    static let deniedFlags: Set<String> = [
        "--server", "-s",
        "--kubeconfig",
        "--tls-server-name",
        "--token",
        "--username", "--password",
        "--certificate-authority",
    ]

    /// Restated from `_DENIED_FLAG_PREFIXES` (S2).
    static let deniedFlagPrefixes: [String] = ["--as", "--insecure", "--client-"]

    /// Restated from `_DENIED_RESOURCES` (S2).
    static let deniedResources: Set<String> = ["secret", "secrets"]

    /// Restated from the script's smuggled-write-verb list.
    static let writeVerbs: [String] = [
        "apply", "delete", "patch", "edit", "replace", "scale", "cordon",
        "drain", "exec", "attach", "port-forward", "proxy", "create",
        "annotate", "label", "restart",
    ]

    /// Restated from `_SAFE_CHARS`. Every character a validated token may
    /// hold once the shell quoting has been taken off.
    static let safeCharacters: Set<Character> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        + "-_./:=,@*{}[]'\" "
    )

    /// A command longer than this is refused outright. The longest real
    /// kubectl line this tool produces is well under 200 characters; the cap
    /// exists so a pathological request cannot make the tokenizer the
    /// expensive part of a 5Hz tick.
    static let maximumLength = 1024

    // MARK: The check

    /// Throws `Refusal` unless `command` is a kubectl invocation this bridge
    /// is willing to type into the connected host.
    static func validate(_ command: String) throws {
        guard !command.isEmpty else { throw Refusal(reason: "the request carried an empty command") }
        guard command.count <= maximumLength else {
            throw Refusal(reason: "the request's command is longer than \(maximumLength) characters")
        }
        // Control characters first: a newline in the string is a *second*
        // command line to an interactive shell, whatever the rest parses as,
        // and `sendCommand` appends its own terminator.
        if command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw Refusal(reason: "the request's command contains a control character")
        }

        let tokens = try tokenize(command)
        guard let program = tokens.first else {
            throw Refusal(reason: "the request carried an empty command")
        }
        guard program == "kubectl" else {
            throw Refusal(reason: "only kubectl commands may be run through this bridge, not '\(program)'")
        }
        guard tokens.count >= 2 else {
            throw Refusal(reason: "no kubectl subcommand given")
        }
        let verb = tokens[1]
        guard allowedVerbs.contains(verb) else {
            throw Refusal(reason: "'\(verb)' is not a read-only kubectl verb")
        }
        let args = Array(tokens.dropFirst(2))

        if verb == "config" {
            guard args.count == 1, allowedConfigSubcommands.contains(args[0]) else {
                throw Refusal(reason: "'kubectl config \(args.joined(separator: " "))' is not one of the two read-only config subcommands")
            }
            return
        }

        for arg in args where !arg.isEmpty {
            if let bad = arg.first(where: { !safeCharacters.contains($0) }) {
                throw Refusal(reason: "argument '\(arg)' contains the disallowed character '\(bad)'")
            }
            let low = arg.lowercased()
            if let flag = flagName(arg) {
                if deniedFlags.contains(flag) || deniedFlagPrefixes.contains(where: { flag.hasPrefix($0) }) {
                    throw Refusal(reason: "argument '\(arg)' uses '\(flag)', which changes where this command connects or who it authenticates as")
                }
            } else if deniedResources.contains(resourceHead(arg)) {
                throw Refusal(reason: "argument '\(arg)' reads the 'secrets' resource, which is never allowed through this bridge")
            }
            if let smuggled = writeVerbs.first(where: { low.contains($0) }) {
                throw Refusal(reason: "argument '\(arg)' references the write verb '\(smuggled)'")
            }
        }
    }

    /// `true` when `command` would be accepted. Convenience for call sites
    /// that only need the boolean.
    static func isAllowed(_ command: String) -> Bool {
        (try? validate(command)) != nil
    }

    // MARK: Pieces

    /// The flag's name - the token up to the first `=`, lowercased - or `nil`
    /// for a positional token. Mirrors the script's `_flag_name`.
    static func flagName(_ arg: String) -> String? {
        guard arg.count >= 2, arg.hasPrefix("-"), arg != "-", arg != "--" else { return nil }
        return String(arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]).lowercased()
    }

    /// The resource type in a positional token, lowercased. Mirrors the
    /// script's `_resource_head`: `secret/foo` and `secrets.v1.` both answer
    /// a denied head.
    static func resourceHead(_ arg: String) -> String {
        let beforeSlash = arg.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return String(beforeSlash.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]).lowercased()
    }

    /// Split a `shlex.quote`-produced string back into its tokens.
    ///
    /// Deliberately **not** a shell parser: it understands exactly the one
    /// quoting form `shlex.quote` emits (a whole token wrapped in single
    /// quotes, with an embedded quote written `'"'"'`) and refuses everything
    /// else - a double quote outside a quoted run, a backslash, a `$`, a
    /// backtick, a pipe, a semicolon, an ampersand, a redirect, a glob that
    /// the shell would expand. A permissive parser here would be the bug,
    /// because whatever it fails to notice is typed into a real shell.
    ///
    /// One deliberate over-refusal: `shlex.quote` writes a token holding a
    /// literal single quote as `'a'"'"'b'`, which puts a double quote outside
    /// a quoted run. That is refused here rather than decoded, because the
    /// alternative is teaching this function a second quoting form for the
    /// sake of an argument kubectl has no use for. Fail closed.
    static func tokenize(_ command: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var inQuotes = false
        for character in command {
            if inQuotes {
                if character == "'" {
                    inQuotes = false
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'":
                inQuotes = true
                started = true
            case " ", "\t":
                if started { tokens.append(current); current = ""; started = false }
            case "\\", "\"", "$", "`", "|", "&", ";", "<", ">", "(", ")",
                 "{", "}", "[", "]", "*", "?", "!", "~", "#", "\n":
                throw Refusal(reason: "the request's command contains the shell metacharacter '\(character)' outside a quoted argument")
            default:
                current.append(character)
                started = true
            }
        }
        if inQuotes { throw Refusal(reason: "the request's command has an unterminated quote") }
        if started { tokens.append(current) }
        return tokens
    }
}
