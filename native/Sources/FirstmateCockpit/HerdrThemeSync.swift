// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-herdr-selection-color-sync`: the follow-up to
// `fm/grandline-herdr-selection-theme-fix`. That task fixed the plain-drag
// path (`CockpitTerminalView.prefersLocalSelection`) - a plain drag now
// builds Grand Line's *own* selection, coloured from the active `HelmTheme`.
// A Shift+drag on a `.shell` tab with "Forward Drags to This Tab's Program"
// enabled is deliberately different: it forwards the whole gesture to the
// child program (herdr, when that's what's running), which draws its *own*
// pane-aware selection - genuinely herdr's own rendering, on herdr's own
// pixels, which this app cannot reach into and recolour. Read that task's
// own AGENTS.md entry ("A selection the app never draws cannot be
// recoloured") before touching anything here; the fix below is deliberately
// NOT another attempt at the same class of workaround.
//
// The real, legitimate fix: herdr's own selection colour is a real,
// documented config token - `[theme.custom].selection_bg` in
// `~/.config/herdr/config.toml` (`herdr --default-config` prints it as a
// commented-out sample, default `"#313244"`, a dark navy that never changes
// with Grand Line's own theme). Confirmed against the real installed
// `herdr` 0.8.2 on this machine, not assumed from the earlier AGENTS.md
// note (which only recorded the default value, not the live mechanism):
//
//   - `herdr --help` / `herdr config --help`: no CLI flag or `herdr config`
//     subcommand sets a theme colour - `config check`/`config reset-keys`
//     are the only two, both unrelated. `herdr --help` documents exactly one
//     env var, `HERDR_CONFIG_PATH`, which overrides the *file path*, not any
//     individual value.
//   - `strings` on the real binary confirms the full, exact field set of
//     the `CustomThemeColors` struct herdr deserializes `[theme.custom]`
//     into: `accent`, `panel_bg`, `sidebar_bg`, `active_row_bg`,
//     `selection_bg`, `surface0`, `surface1`, `surface_dim`, `overlay0`,
//     `overlay1`, `text`, `subtext0`, `mauve`, `green`, `yellow`, `red`,
//     `blue`, `teal`, `peach`. There is no `selection_fg` - only the
//     selection *wash* is configurable, not the foreground painted over it,
//     so this sync only ever touches `selection_bg`. (`text` recolours
//     herdr's whole UI foreground and is deliberately never touched here -
//     matching it to Grand Line's selection-text colour would make herdr's
//     entire interface, not just a selection, follow a colour chosen for a
//     narrower purpose.)
//   - So the only way to change it is to edit that one file, which is
//     herdr's own persistent config - not something Grand Line launches
//     herdr with. Per `fm/grand-line-remove-firstmate-mirror`, this app
//     never launches herdr at all any more; the captain runs it by hand
//     inside a `.shell` tab. There is no "at launch" hook to thread a flag
//     or env var through even if one existed.
//
// **`fm/grandline-herdr-reload-on-theme-sync`: live reload is now wired up.**
// The prior task above investigated `herdr server reload-config` and
// deliberately stopped at writing the config file, out of caution about
// touching a live herdr server from inside a routine theme-sync task with
// no `--herdr-lab` isolation. This task's own brief was explicitly generated
// with `--herdr-lab` for exactly this reason, and the captain has now
// authorised closing the gap: after a successful, *changed* config write,
// `syncNow` also runs `herdr server reload-config` so an already-running
// server picks up the new colour immediately, without the captain having to
// restart it or find the `prefix+shift+r` keybinding themselves.
//
// What re-confirming this against the real installed `herdr` 0.8.2 binary
// found, beyond what the header above already established:
//
//   - `herdr server reload-config` takes no flags of its own - its usage
//     string (`strings` on the real binary: `usage: herdr server
//     reload-config`, with no trailing `[OPTIONS]`, unlike e.g.
//     `agent-manifests`' own `usage: herdr server agent-manifests [--json]`)
//     - so there is no way to ask it for machine-parseable output. The
//     socket-level `ConfigReloadStatus` enum (`applied`/`partial`/`failed`,
//     confirmed again via `herdr api schema --json`) is real, but nothing
//     in the CLI surface exposes it structurally to a caller; only the
//     process's own exit status is a reliable signal from outside.
//   - The binary's own strings confirm the CLI detects "no server running"
//     itself (a client-side connection error, distinct from the socket-level
//     `server_unavailable` error code used for the narrower "server exists
//     but is mid-shutdown" race) and exits non-zero rather than hanging -
//     this is what makes "no server running" safe to treat as just another
//     unsuccessful-reload outcome: log it, never crash, never block the
//     config write (already durable on disk) on it.
//   - This app never manages herdr sessions (E1/`fm/grand-line-remove-
//     firstmate-mirror`), so production never passes `--session` here -
//     `herdr server reload-config` targets whatever the captain's own
//     ambient/default session's server is, exactly the CLI's own default
//     behaviour when run from an ordinary shell.
//
// **Why this could not be, and was not, verified end-to-end against a real,
// running herdr server - lab or otherwise, despite the brief's explicit
// `--herdr-lab` isolation contract.** `fm-herdr-lab.sh run` categorically
// refuses any command whose first word is `server` ("run forbids server
// operations; use provision for the named lab server") with no reload-
// specific carve-out, and the helper offers no other verb that could invoke
// it (only `name`/`prepare`/`provision`/`run`/`stop`/`teardown`). Confirmed
// live: `fm-herdr-lab.sh run <lab-session> server reload-config` exits 1
// with exactly that refusal, inside a real, freshly provisioned, cleanly
// torn-down lab session. The task's own hard safety contract separately,
// explicitly forbids running `herdr server reload-config` *directly*
// (bypassing the helper) as one of its "reload/update operations" under
// "server-global operation" - and rule 6 ("never bypass the helper, even
// for a read-only lifecycle probe") leaves no exception for doing this
// scoped-but-unsanctioned, even against an isolated lab session's own
// server rather than the captain's real `default` one. So the mechanism
// below is built and unit-tested against a disposable fake `herdr` script
// (see `herdrExecutablePathOverrideForTests` and
// `HerdrThemeSyncSelfTest.swift`'s reload-specific cases), which proves the
// Swift-side logic (argv, timeout, success/failure handling, never
// crashing) - but a real herdr server's own live colour change in response
// to a real reload call was never observed in this task, because the
// sanctioned tooling has no verb capable of triggering that call at all.
// This gap was raised to firstmate as a `needs-decision` before this PR was
// opened; see that task's own status/PR history for the resolution.
//
// The captain's own `~/.config/herdr/config.toml` is real, hand-maintained
// state (this machine's copy has a `[keys]` table with custom bindings and
// no `[theme]` section at all) - `HerdrConfigPatcher` below is a careful,
// line-level surgical patch of exactly one key, never a rewrite of the
// whole file, and refuses to touch anything it is not confident it
// understands (see that type's own header for the exact guarantees and
// what it deliberately does not attempt to parse).

import Foundation

/// Pure logic: no file I/O, no `Process`, no `ThemeManager`. Everything here
/// is a plain `String -> String?` transform, which is what makes it testable
/// with nothing more than literal fixtures (`HerdrThemeSyncSelfTest.swift`).
enum HerdrConfigPatcher {

    struct PatchResult: Equatable {
        /// The full, patched file content.
        let content: String
        /// `false` when the file already had the target value - the caller
        /// should skip the write rather than touch the file's mtime for no
        /// reason (`ThemeManager.reapplyCurrentTheme()` re-fires every
        /// observer on a plain font-scale change, not just a real theme
        /// switch, so this keeps a no-op re-fire from becoming a disk write).
        let changed: Bool
    }

    /// Returns the patched content, or `nil` when `original`'s structure is
    /// not one this patcher is confident it understands - in which case the
    /// caller MUST NOT write anything. This is deliberately conservative
    /// rather than clever: the task this backs explicitly allows "if this
    /// feels too invasive or fragile... conclude this isn't safely
    /// buildable" for any one captain's file, without that meaning the
    /// mechanism itself is unbuildable for the common case (which is what
    /// herdr's own generated config, and the captain's real hand-edited one,
    /// both look like).
    ///
    /// What this refuses to guess about, on purpose:
    ///   - A triple-quoted multi-line string (`"""..."""`/`'''...'''`)
    ///     anywhere in the file - a continuation line inside one could
    ///     contain literal text that looks like a table header or a
    ///     `selection_bg = ...` assignment, and this scanner has no notion
    ///     of "inside a string" to protect against misreading it. herdr's
    ///     own config never uses one (checked against `--default-config`).
    ///   - A dotted-key assignment starting with `theme` outside of a
    ///     `[section]` header (`theme.custom.selection_bg = "..."` or
    ///     `theme = { custom = { ... } }`) - legal TOML this scanner has no
    ///     way to reconcile against a `[theme.custom]` header it might also
    ///     add, which could produce a file with the same table declared
    ///     twice (invalid TOML). herdr's own generated config only ever uses
    ///     `[section]` headers.
    ///   - More than one `[theme.custom]` header, or more than one live
    ///     (uncommented) `selection_bg` key inside it - either means the
    ///     file is already in a shape this patcher should not be the one to
    ///     resolve.
    ///   - A live `selection_bg` value that is not a single-line, simple
    ///     quoted string (no escapes) - anything else means "I don't
    ///     recognise this shape", not "let me guess."
    static func apply(selectionBgHex: String, to original: String) -> PatchResult? {
        guard !original.contains("\"\"\"") && !original.contains("'''") else { return nil }

        var lines = original.components(separatedBy: "\n")
        var hadTrailingNewline = false
        if lines.last == "" {
            hadTrailingNewline = true
            lines.removeLast()
        }

        // A standard-table header, e.g. "[theme.custom]" - deliberately
        // excludes "[[array.of.tables]]" (the first bracket char after the
        // opening "[" must be an identifier character, not another "[") and
        // anything with quoted/spaced segments this scanner does not model.
        let headerPattern = try! NSRegularExpression(
            pattern: #"^\s*\[([A-Za-z0-9_][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_][A-Za-z0-9_-]*)*)\]\s*$"#)
        // A top-level dotted-key assignment whose path starts with "theme" -
        // the residual-risk idiom this patcher refuses to reason about.
        let dottedThemeKeyPattern = try! NSRegularExpression(
            pattern: #"^\s*theme(?:\.[A-Za-z0-9_][A-Za-z0-9_-]*)*\s*="#)
        // Any assignment that looks like it is trying to set selection_bg,
        // whether or not this scanner can safely read its value.
        let selectionBgAnyPattern = try! NSRegularExpression(pattern: #"^\s*selection_bg\s*="#)
        // A selection_bg assignment this scanner CAN safely read: a single-
        // line quoted string with no escapes. Captures: 1 = everything up to
        // and including "= " (preserved verbatim), 2 = the quote character,
        // 3 = the inner value, 4 = everything after the closing quote
        // (preserved verbatim, including a trailing inline comment).
        let selectionBgPattern = try! NSRegularExpression(
            pattern: #"^(\s*selection_bg\s*=\s*)(["'])([^"'\\]*)\2(.*)$"#)

        func fullRange(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
        func isCommentOrBlank(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }

        var currentPath: [String] = []
        var themeCustomHeaderLineIndex: Int?
        var themeCustomHeaderCount = 0
        var existingSelectionBgLineIndex: Int?

        for (i, line) in lines.enumerated() {
            if isCommentOrBlank(line) { continue }

            if let m = headerPattern.firstMatch(in: line, range: fullRange(line)) {
                guard let nameRange = Range(m.range(at: 1), in: line) else { return nil }
                let path = String(line[nameRange]).split(separator: ".").map(String.init)
                guard !path.isEmpty else { return nil }
                currentPath = path
                if path == ["theme", "custom"] {
                    themeCustomHeaderCount += 1
                    if themeCustomHeaderCount > 1 { return nil }
                    themeCustomHeaderLineIndex = i
                }
                continue
            }

            if dottedThemeKeyPattern.firstMatch(in: line, range: fullRange(line)) != nil {
                return nil
            }

            guard currentPath == ["theme", "custom"] else { continue }
            guard selectionBgAnyPattern.firstMatch(in: line, range: fullRange(line)) != nil else { continue }
            if existingSelectionBgLineIndex != nil { return nil }
            guard selectionBgPattern.firstMatch(in: line, range: fullRange(line)) != nil else { return nil }
            existingSelectionBgLineIndex = i
        }

        var changed = true
        // Only creating a brand-new `[theme.custom]` table (the file had
        // none at all) should force a trailing newline regardless of the
        // original's own convention - that is genuinely new trailing
        // content, conventionally terminated the way herdr's own
        // `--default-config` output always is. Replacing an existing live
        // value, and inserting a new key into an already-existing table,
        // both change nothing about how the file *ends* and must preserve
        // `hadTrailingNewline` exactly, whichever way it went.
        var createdBrandNewTable = false

        if let idx = existingSelectionBgLineIndex {
            let line = lines[idx]
            guard let m = selectionBgPattern.firstMatch(in: line, range: fullRange(line)),
                  let prefixRange = Range(m.range(at: 1), in: line),
                  let valueRange = Range(m.range(at: 3), in: line),
                  let suffixRange = Range(m.range(at: 4), in: line)
            else { return nil }
            let currentValue = String(line[valueRange])
            if currentValue == selectionBgHex {
                changed = false
            } else {
                lines[idx] = String(line[prefixRange]) + "\"" + selectionBgHex + "\"" + String(line[suffixRange])
            }
        } else if let headerIdx = themeCustomHeaderLineIndex {
            lines.insert("selection_bg = \"\(selectionBgHex)\"", at: headerIdx + 1)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("[theme.custom]")
            lines.append("selection_bg = \"\(selectionBgHex)\"")
            createdBrandNewTable = true
        }

        var newContent = lines.joined(separator: "\n")
        if hadTrailingNewline || createdBrandNewTable {
            newContent += "\n"
        }

        // Self-check: re-scan the output through the same rules and confirm
        // it now describes exactly the state this function meant to produce
        // - defence against a bug in the logic above, not just in the input.
        guard verify(newContent, expectedSelectionBgHex: selectionBgHex,
                     headerPattern: headerPattern, selectionBgAnyPattern: selectionBgAnyPattern,
                     selectionBgPattern: selectionBgPattern)
        else { return nil }

        return PatchResult(content: newContent, changed: changed)
    }

    /// Re-derives the same two facts `apply` computed on the input, this
    /// time on the output: exactly one `[theme.custom]` table, and exactly
    /// one live `selection_bg` key in it, holding exactly the value asked
    /// for. Reuses the same compiled patterns rather than re-deriving them.
    private static func verify(
        _ content: String, expectedSelectionBgHex: String,
        headerPattern: NSRegularExpression, selectionBgAnyPattern: NSRegularExpression,
        selectionBgPattern: NSRegularExpression
    ) -> Bool {
        func fullRange(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
        var currentPath: [String] = []
        var themeCustomHeaders = 0
        var liveSelectionBgValues: [String] = []
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let m = headerPattern.firstMatch(in: line, range: fullRange(line)),
               let nameRange = Range(m.range(at: 1), in: line) {
                let path = String(line[nameRange]).split(separator: ".").map(String.init)
                currentPath = path
                if path == ["theme", "custom"] { themeCustomHeaders += 1 }
                continue
            }
            guard currentPath == ["theme", "custom"] else { continue }
            guard selectionBgAnyPattern.firstMatch(in: line, range: fullRange(line)) != nil else { continue }
            guard let m = selectionBgPattern.firstMatch(in: line, range: fullRange(line)),
                  let valueRange = Range(m.range(at: 3), in: line)
            else { return false }
            liveSelectionBgValues.append(String(line[valueRange]))
        }
        return themeCustomHeaders == 1
            && liveSelectionBgValues == [expectedSelectionBgHex]
    }
}

/// The app-lifetime singleton wiring `HerdrConfigPatcher` up to
/// `ThemeManager` - registered once from `main.swift`, same shape as
/// `FleetNotifier`/`BackgroundSignalsPoller`/`AppActivityState`.
///
/// Unconditional on any tab's own `forwardDragsToChild` toggle: herdr has
/// exactly one config file for the whole machine, not one per Grand Line
/// tab, so "sync it to the active theme" is a standing fact about the
/// captain's herdr installation, not something to gate behind whether some
/// `.shell` tab happens to have drag-forwarding on right now.
final class HerdrThemeSync {
    static let shared = HerdrThemeSync()
    private init() {}

    private var themeToken: ThemeObservation?

    /// Test-only seam: `HerdrThemeSyncSelfTest` points this at a real
    /// scratch file so `syncNow` can be driven end to end (read, patch,
    /// atomic write) without ever touching the real
    /// `~/.config/herdr/config.toml`. `nil` (the production default) means
    /// "resolve the real path", exactly as `DictationCleanup.
    /// claudePathOverrideForTests`'s own convention.
    static var configPathOverrideForTests: URL?

    /// Test-only seam, same shape: bypasses the real `PATH` lookup so a test
    /// can exercise both the "herdr installed" and "herdr not installed"
    /// branches regardless of whether this machine happens to have herdr on
    /// PATH. `nil` means "ask `Subprocess.resolveExecutable`, as production
    /// does."
    static var herdrInstalledOverrideForTests: Bool?

    /// Test-only seam, same `nil`-means-"ask reality" convention as
    /// `DictationCleanup.claudePathOverrideForTests`/`SRELead.
    /// resolveClaude()`: when set, `triggerLiveReload()` runs THIS
    /// executable instead of resolving the real `herdr` on PATH, so a
    /// disposable fake script can stand in for `herdr server reload-config`
    /// - exercising the argv/timeout/success/failure handling below without
    /// ever starting, attaching to, or reloading a real herdr process,
    /// lab session or otherwise (see this file's header for why a real one
    /// could not be driven from this task at all).
    static var herdrExecutablePathOverrideForTests: String?

    /// Registered once at launch. Idempotent.
    func start() {
        guard themeToken == nil else { return }
        themeToken = ThemeManager.shared.observe { [weak self] theme in
            self?.syncNow(theme: theme)
        }
    }

    /// Reads, patches, and (if anything changed) atomically rewrites herdr's
    /// config.toml so `[theme.custom].selection_bg` matches `theme`'s
    /// accent. A no-op, not a failure, whenever herdr is not installed, the
    /// file already holds the right value, or the file's structure is not
    /// one `HerdrConfigPatcher` is confident it understands - none of those
    /// are things a captain needs to be told about; a genuine write failure
    /// (permissions, a vanished volume) is logged, since GL-11's rule is
    /// "log before degrading", but is otherwise a soft, best-effort sync to
    /// a sibling tool's own config rather than anything Grand Line's own
    /// persistence-failure surfaces (`PersistenceFailureReporter`,
    /// scoped to this app's own stores) need to know about.
    func syncNow(theme: HelmTheme) {
        let installed = Self.herdrInstalledOverrideForTests
            ?? (Subprocess.resolveExecutable("herdr") != nil)
        guard installed else { return }

        let hex = "#" + theme.accentHex.lowercased()
        let path = Self.configPath()
        let original = (try? String(contentsOf: path, encoding: .utf8)) ?? ""

        guard let result = HerdrConfigPatcher.apply(selectionBgHex: hex, to: original) else {
            AppLog.store.notice("""
                herdr theme sync: config.toml at \(path.path, privacy: .public) is not in a \
                shape this app is confident it can patch safely - leaving it untouched
                """)
            return
        }
        guard result.changed else { return }

        do {
            try AtomicWrite.text(result.content, to: path)
            AppLog.store.info("herdr theme sync: set selection_bg to \(hex, privacy: .public) in \(path.path, privacy: .public)")
        } catch {
            AppLog.store.error("""
                herdr theme sync: failed to write \(path.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }

        triggerLiveReload()
    }

    /// Best-effort: tells an ALREADY-RUNNING herdr server to re-read
    /// `config.toml` right now, so a captain who never restarts/reattaches
    /// still sees the new selection colour without delay. Called only after
    /// the config write above has already succeeded - that write is the
    /// durable source of truth regardless of what happens here, so nothing
    /// below is allowed to be treated as fatal or to block the rest of
    /// Grand Line's own theme-apply flow. Fires via `Subprocess.runAsync`
    /// (GL-04) rather than blocking `syncNow`'s own caller -
    /// `ThemeManager.shared.observe`'s callback fires synchronously on
    /// whichever thread the captain's theme change happened on, almost
    /// always the main thread, so a blocking subprocess call here would
    /// hold up the very theme-apply flow this sync piggybacks on for as long
    /// as `reloadTimeout` if the running server ever became unresponsive.
    ///
    /// `herdr server reload-config` is a no-op, not a failure, whenever no
    /// server happens to be running - the CLI itself detects that (a
    /// client-side connection error, per this file's header) and exits
    /// non-zero, which this treats exactly like any other unsuccessful
    /// reload attempt: logged for a human to see, never surfaced anywhere
    /// louder than the log (GL-11's "log before degrading", not Grand
    /// Line's own `PersistenceFailureReporter`, which is scoped to this
    /// app's own stores rather than a sibling tool's best-effort sync).
    ///
    /// `herdr server reload-config` takes no flags of its own (confirmed
    /// against the real installed binary's usage string - see this file's
    /// header), so there is no way to ask it for a machine-parseable
    /// applied/partial/failed result here; the raw text it prints is logged
    /// verbatim for a human to read, and the signal this code itself acts
    /// on is the process's own exit status.
    private func triggerLiveReload() {
        guard let herdrPath = Self.herdrExecutablePathOverrideForTests
            ?? Subprocess.resolveExecutable("herdr")
        else { return }

        Subprocess.runAsync(
            executable: herdrPath,
            arguments: ["server", "reload-config"],
            timeout: Self.reloadTimeout
        ) { result in
            if result.ok {
                AppLog.store.info("herdr theme sync: told the running server to reload config.toml")
            } else {
                // Expected and harmless whenever no server is currently
                // running - the captain's next `herdr` launch already reads
                // the file this sync just wrote, so there is nothing left
                // to do.
                AppLog.store.notice("""
                    herdr theme sync: could not reload a running server's config (\
                    \(result.failureSummary ?? "unknown reason", privacy: .public)) - the file on \
                    disk is already correct and will apply the next time herdr's own server starts
                    """)
            }
        }
    }

    /// Generous enough for a real reload round trip over the socket, short
    /// enough that a captain reading the log soon after a theme change
    /// still sees a timely result if something about the running server is
    /// unresponsive. Runs off-thread (`triggerLiveReload`'s own doc
    /// comment), so this bounds only how long the log line above can lag
    /// behind the theme change - never the UI.
    private static let reloadTimeout: TimeInterval = 10

    /// Mirrors herdr's own documented precedence (`herdr --help`: "Env:
    /// HERDR_CONFIG_PATH overrides config file path") so this app writes to
    /// the exact file herdr itself would read, including when the captain
    /// has customised `HERDR_CONFIG_PATH`.
    static func configPath() -> URL {
        if let override = configPathOverrideForTests { return override }
        let env = ProcessInfo.processInfo.environment
        if let herdrOverride = env["HERDR_CONFIG_PATH"], !herdrOverride.isEmpty {
            return URL(fileURLWithPath: herdrOverride)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/herdr/config.toml")
    }
}
