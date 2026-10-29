// Grand Line - native macOS app.
//
// R4-ARCH-02 of the fourth full review: the part of `bin/fm-crew-state.sh`
// that can be read in Swift, and nothing more.
//
// **What the script reads, and why almost none of it is portable.** The
// script answers one line - `state: <s> · source: <src> · <detail>` - from five
// inputs: the task's `.meta`, its `.status` event log, the no-mistakes run
// ledger (`axi status`, a daemon round trip), the worktree's git HEAD, and the
// live backend pane's busy signature (herdr or tmux). Two of those are
// subprocesses of their own, and the logic that reconciles them is about a
// thousand lines of bash with its own invariants and its own tests in the
// firstmate repository. A Swift copy of that would be a second implementation
// of the fleet's most load-bearing rule, maintained in a different repository
// from the first, and it would drift.
//
// **What is portable is the one verdict the script reaches from the `.meta`
// alone**, before it sources a run, a pane or a log:
//
//     [ -f "$META" ] || emit unknown none "no metadata for $ID"
//     WT=$(meta_value worktree); REMOTE_HOST=$(meta_value remote_host)
//     if [ -z "$REMOTE_HOST" ] && { [ -z "$WT" ] || [ ! -d "$WT" ]; }; then
//       emit unknown none "worktree gone (torn down?)"
//     fi
//
// That is the torn-down task, which is exactly the task that piles up over a
// long day and that every poll used to pay a whole script run for. Anything
// else - a live worktree, a remote secondmate, a value this reader does not
// understand - returns `nil`, and the caller runs the script as it always did.
// So the output shown for a task is the script's output by construction: this
// either prints the identical line, or it says nothing.
//
// `FleetCrewStateReaderSelfTest` holds the proof: every real-shaped fixture's
// verdict against a golden copy of the script's line, and, wherever the real
// script is installed, against the script itself.
//
// **Read like `grep`, not like `parseMetaFile`.** The script's `meta_value` is
// `grep "^key=" | tail -1 | cut -d= -f2-`: the last line that starts with the
// key and `=` exactly, the value untrimmed. `FleetDataSource.parseMetaFile`
// trims keys and values and skips comments, which is right for the display
// fields and wrong here - ` worktree=/x` is no worktree at all to the script.
// Anything `grep` and bash might read differently from Swift (a NUL byte, a
// control character, bytes that are not UTF-8, a relative path) is a value
// this reader does not understand, so it defers.

import Foundation

/// One task's crew state, as `fm-crew-state.sh` reports it.
struct FleetCrewReading: Equatable {
    let state: String
    let source: String
    let detail: String

    /// What the fleet shows when the script is missing or failed: GL-14's
    /// unknown, never an invented state.
    static let unavailable = FleetCrewReading(state: "unknown", source: "none", detail: "")
}

enum FleetCrewStateReader {

    /// The script's own line for a torn-down worktree, word for word.
    static let worktreeGone = FleetCrewReading(state: "unknown", source: "none", detail: "worktree gone (torn down?)")

    /// The environment overrides that change which files the script reads.
    /// With any of them set the script may not be reading the file this
    /// reader would, so it defers.
    static let overridingEnvironment = [
        "FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CREW_STATE_META_OVERRIDE",
    ]

    /// The script's verdict for the task whose `.meta` is at `metaURL`, when
    /// the script reaches it from that file alone - or `nil`, and the script
    /// decides. A relative worktree path is deferred too: bash resolves it
    /// against the script's working directory, which is not this process's.
    static func reading(metaURL: URL,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        fileManager: FileManager = .default) -> FleetCrewReading? {
        guard !overridingEnvironment.contains(where: { environment[$0] != nil }) else { return nil }
        // A file that cannot be read now may be readable when the script
        // runs, and the script's own "no metadata" verdict is not this one.
        guard let data = try? Data(contentsOf: metaURL),
              let values = metaValues(data, keys: ["worktree", "remote_host"]) else { return nil }
        guard (values["remote_host"] ?? "").isEmpty else { return nil }
        let worktree = values["worktree"] ?? ""
        if worktree.isEmpty { return worktreeGone }
        guard worktree.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: worktree, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? nil : worktreeGone
    }

    /// `grep "^key=" | tail -1 | cut -d= -f2-` for each of `keys`, or `nil`
    /// when the file holds anything that pipeline and bash might read
    /// differently from this.
    static func metaValues(_ data: Data, keys: [String]) -> [String: String]? {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        // Split on the newline scalar, not on `Character`: in Swift "\r\n" is
        // one `Character`, so splitting the string itself would not split a
        // CRLF file at all, while `grep` splits it and keeps the "\r".
        for scalars in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(String.UnicodeScalarView(scalars))
            for key in keys where line.hasPrefix(key + "=") {
                values[key] = String(line.dropFirst(key.count + 1))
            }
        }
        // A carriage return, a tab or any other control character is a value
        // the shell could read differently, so it is not this reader's to call.
        let hasControl = { (value: String) in
            value.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        return values.values.contains(where: hasControl) ? nil : values
    }
}
