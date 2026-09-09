// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates **phase 2.5**: the crew's read-only MCP tools - the
// session that registers them, the pinned allowlist, and the per-turn health
// file bridge (the plan's milestones M2.5a/b/c).
//
// The captain-approved plan (`data/deepen-straw-hat-pirates-plan-explore-ja-3a/
// straw-hat-pirates-plan.html`, firstmate side) is the source of record.
// Read its "round-2 finding that upgrades the architecture" card and the
// M2.5a/b/c milestones before changing anything here, plus
// `native/Scripts/luffy_stores_mcp.py`'s own module docstring, which carries
// the Python half of every decision below.
//
// ## The finding this phase rests on
//
// Round 1 of the plan framed native tool use as a Phase-4 luxury needing the
// direct Anthropic API. That is true of the Messages API and wrong for the
// CLI path: **this app already runs genuine MCP tool use through `claude -p`,
// in production, today** - `SRELeadRunner` has passed `--mcp-config`,
// `--strict-mcp-config` and `--allowedTools` on every turn since SRE Lead
// shipped, backed by `sre_kubectl_mcp.py`. So the crew gets real tool use
// with zero new secrets, zero new networking, and no API key - the same
// already-authenticated `claude` CLI login every other AI feature here uses.
//
// This is additive to phase 2, not a replacement for it. `StrawHatContext`
// keeps *pushing* a bounded snapshot into every turn; these tools let the
// crew *pull* the half injection cannot carry - a runbook's body, a saved
// command, a task the snapshot's cap left out. The plan's own trade-off table
// treats push and pull as complementary, and that is exactly how they are
// wired: `capture` is unchanged and still runs on every turn.
//
// ## Writes: never, and two independent layers say so
//
// Proposals plus confirm cards (`StrawHatProposalExecutor`) remain the only
// write path this feature will ever have. The tool surface is read-only by
// construction, at two layers that fail independently:
//
//  1. **The CLI.** `allowedTools` below pins `--allowedTools` to exactly four
//     names. Measured live rather than assumed (see that constant's own note):
//     a tool the model asks for that is not on the list is denied by `claude`
//     itself, and the MCP server's handler is never reached.
//  2. **The server.** `luffy_stores_mcp.py` has four handlers in one closed
//     dispatch table and no write anywhere in the file - no `open(..., "w")`,
//     no `os.remove`, no `subprocess`. `test_luffy_stores_mcp.py` asserts
//     that as a property of the source, because "the tool list is read-only
//     today" and "this file cannot write" are different guarantees.
//
// ## Why `--permission-mode bypassPermissions` is NOT passed
//
// `SRELeadRunner` passes it and this deliberately does not. It was measured,
// with a throwaway MCP server and a real `claude -p` call, before the argv
// here was written:
//
//  - `--allowedTools "mcp__probe__magic_number"` **alone**, with no
//    `--permission-mode` at all, genuinely called the tool - the server's
//    handler ran and the reply carried a value only the tool could supply,
//    with `permission_denials: []`.
//  - The same call with the allowlist pointed at a *different* name left
//    `permission_denials` naming the attempted tool and the handler never
//    ran.
//
// So the allowlist alone both permits and restricts, and `bypassPermissions`
// - which turns off permission checking for the whole session - would be a
// strictly broader grant bought for nothing. A phase whose entire point is
// "read-only, provably" should not open with the widest permission mode the
// CLI has.
//
// ## Where the tools are pointed, and why not by this file
//
// Every path a tool reads comes from `StrawHatStoreRoots`, which the *caller*
// builds from stores it already holds. This file constructs no store - the
// same rule `StrawHatContextSnapshot.capture` follows, and for the same two
// reasons: `CommandLibraryStore()`'s initializer seeds and reloads (GL-24
// made that instance shared precisely so a second one could not diverge from
// it), and a store built with no override reaches the captain's real
// git-synced clone. Passing roots in also means a self-test's `FM_SHIFT_DIR`
// scratch directory reaches these tools with no extra wiring, because the
// stores the caller holds already resolved it.

import Foundation

/// The three store roots the crew's tools read, resolved by whoever already
/// owns those stores.
///
/// Deliberately URLs rather than the stores themselves: nothing in phase 2.5
/// reads a store *object*, and taking three live stores here would hand this
/// file (and `StrawHatRunner` behind it) dependencies it has no use for.
struct StrawHatStoreRoots {
    /// `ShiftStore.root` - `tasks/active.yaml` and `follow-ups/follow-ups.yaml`.
    let shift: URL
    /// `DocsRunbookStore.root` - top-level runbook markdown plus `postmortems/`.
    let docs: URL
    /// `CommandLibraryStore.root` - `<category>/[<subcategory>/]<slug>.yaml`.
    let commands: URL
}

/// One Straw Hat conversation's tool session: the MCP config every turn is
/// launched against, the health bridge file the app rewrites per turn, and the
/// scratch directory both live in so `tearDown()` can remove them.
///
/// Mirrors `SRELeadSession` field for field in intent. The difference is that
/// there is no request/response protocol here: health flows one way, app to
/// tool, one file, no polling and nothing to correlate.
struct StrawHatToolSession {
    /// The `--mcp-config <this>` argument for every turn.
    let mcpConfigPath: URL

    /// The per-turn health snapshot `luffy_stores_mcp.py`'s `health_snapshot`
    /// tool reads (`LUFFY_HEALTH_SNAPSHOT`). Rewritten by
    /// `StrawHatRunner` before each turn - see `writeHealthSnapshot`.
    let healthSnapshotPath: URL

    private let scratchDir: URL

    fileprivate init(mcpConfigPath: URL, healthSnapshotPath: URL, scratchDir: URL) {
        self.mcpConfigPath = mcpConfigPath
        self.healthSnapshotPath = healthSnapshotPath
        self.scratchDir = scratchDir
    }

    /// Remove this session's scratch directory - the MCP config and the health
    /// snapshot, nothing else lives there. Safe to call more than once.
    /// Killing an in-flight `claude` is `StrawHatRunner.cancel()`'s job.
    func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
    }

    /// Write this turn's health snapshot, atomically.
    ///
    /// Atomic (`.tmp` then a rename) for the reason `sre_kubectl_mcp.py`'s
    /// bridge writes its own requests that way: the reader is a different
    /// process on its own schedule, so a plain in-place write can be read
    /// half-finished. `FileManager.replaceItem` is the rename, and the
    /// fallback below covers the first write, when there is nothing to
    /// replace.
    ///
    /// Best effort by design: a failure here must never fail the turn. The
    /// tool degrades to "Grand Line hasn't written this turn's snapshot",
    /// which is an honest read failure the crew is told to report as such -
    /// never as a healthy machine (GL-14).
    func writeHealthSnapshot(_ payload: [String: Any]) {
        let tmp = scratchDir.appendingPathComponent("health-\(UUID().uuidString).tmp.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: healthSnapshotPath.path) {
                _ = try FileManager.default.replaceItemAt(healthSnapshotPath, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: healthSnapshotPath)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            AppLog.ai.error("straw hat: could not write the health snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension StrawHatCrew {

    /// The MCP server name every tool is namespaced under. A wire contract
    /// with `luffy_stores_mcp.py`'s `serverInfo.name` and with `allowedTools`
    /// below, which builds `mcp__<this>__<tool>`.
    static let mcpServerName = "luffy-stores"

    /// The four read-only tool names, matching `luffy_stores_mcp.py`'s
    /// `SHIFT_TOOL`/`DOCS_TOOL`/`COMMAND_TOOL`/`HEALTH_TOOL` exactly.
    ///
    /// Hand-maintained against that file with no compiler check between them:
    /// rename one here without the matching Python change and the tool is
    /// silently un-permitted - the model asks, `claude` denies, and the crew
    /// reports it cannot see something it should.
    /// `StrawHatMCPSelfTest`/`test_luffy_stores_mcp.py` each assert the other
    /// side names all four.
    static let readOnlyToolNames = ["shift_read", "docs_search", "command_search", "health_snapshot"]

    /// M2.5c: `--allowedTools`, pinned to exactly the four read-only tools.
    ///
    /// **No `Task` and no `TodoWrite`**, unlike `SRELead.allowedTools`. SRE
    /// Lead's persona explicitly asks for subagent delegation on independent
    /// checks; the crew's does not ask for either, so listing them would
    /// permit a capability nothing uses and widen the surface this milestone
    /// exists to narrow. M2.5c says "exactly the four read-only tools" and
    /// that is what this is.
    ///
    /// The allowlist is a real gate, not a hint - measured live, see this
    /// file's header. Everything the crew is allowed to do is in this one
    /// string, and a write is not in it.
    static var allowedTools: String {
        readOnlyToolNames.map { "mcp__\(mcpServerName)__\($0)" }.joined(separator: ",")
    }

    /// Prepare this conversation's tool session: write the MCP config into a
    /// private scratch directory and seed the health bridge file.
    ///
    /// Returns `nil` rather than throwing, and every failure is survivable:
    /// `StrawHatRunner` runs its turns without `--mcp-config` when this
    /// returns `nil`, which is exactly phase 2's behaviour. Losing the tools
    /// must degrade the crew to "told, not able to look", never break the
    /// chat - the pushed context snapshot is still there.
    ///
    /// Mirrors `SRELead.setUp()`'s shape (scratch dir at 0700, an
    /// `mcpServers` config naming a `python3` command plus the script path and
    /// its env). The env keys are this feature's own: `LUFFY_*` rather than
    /// `SRE_LEAD_*`, so the two servers cannot be pointed at each other's
    /// directories.
    static func setUpTools(roots: StrawHatStoreRoots) -> StrawHatToolSession? {
        guard let scriptPath = resolveStoresScript() else {
            AppLog.ai.error("straw hat: luffy_stores_mcp.py not found - the crew will run without tools")
            return nil
        }
        guard let python = SRELead.resolvePython3() else {
            AppLog.ai.error("straw hat: python3 not found - the crew will run without tools")
            return nil
        }

        let fm = FileManager.default
        let scratchDir = fm.temporaryDirectory
            .appendingPathComponent("fm-straw-hat-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: scratchDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            AppLog.ai.error("straw hat: could not create the tool scratch directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let healthSnapshotPath = scratchDir.appendingPathComponent("health.json")
        let mcpConfigPath = scratchDir.appendingPathComponent("mcp-config.json")
        let config: [String: Any] = [
            "mcpServers": [
                mcpServerName: [
                    "command": python,
                    "args": [scriptPath],
                    "env": [
                        "LUFFY_SHIFT_DIR": roots.shift.path,
                        "LUFFY_DOCS_DIR": roots.docs.path,
                        "LUFFY_COMMANDS_DIR": roots.commands.path,
                        "LUFFY_HEALTH_SNAPSHOT": healthSnapshotPath.path,
                    ],
                ]
            ]
        ]
        do {
            try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
                .write(to: mcpConfigPath)
        } catch {
            try? fm.removeItem(at: scratchDir)
            AppLog.ai.error("straw hat: could not write the MCP config: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return StrawHatToolSession(mcpConfigPath: mcpConfigPath,
                                   healthSnapshotPath: healthSnapshotPath,
                                   scratchDir: scratchDir)
    }

    /// Locate `luffy_stores_mcp.py`, exactly as `SRELead` locates its own
    /// script: the app bundle's `Contents/Resources` (where
    /// `build_native_app.sh` copies it, next to `sre_kubectl_mcp.py`), then an
    /// `FM_LUFFY_STORES_SCRIPT` override, then a walk up from the working
    /// directory for the `swift run`/`swift build` dev flow.
    static func resolveStoresScript() -> String? {
        let fm = FileManager.default
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("luffy_stores_mcp.py").path
            if fm.isReadableFile(atPath: candidate) { return candidate }
        }
        if let override = ProcessInfo.processInfo.environment["FM_LUFFY_STORES_SCRIPT"],
           fm.isReadableFile(atPath: override) {
            return override
        }
        var dir = fm.currentDirectoryPath
        for _ in 0..<6 {
            let candidate = (dir as NSString).appendingPathComponent("native/Scripts/luffy_stores_mcp.py")
            if fm.isReadableFile(atPath: candidate) { return candidate }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
