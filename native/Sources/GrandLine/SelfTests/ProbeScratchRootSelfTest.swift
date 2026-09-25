// Grand Line - native macOS app.
//
// Review bug B4: "a probe launch corrupts or overwrites the captain's real
// data, contrary to the script's own guarantee".
//
// `Scripts/build-probe-app.sh` used to carry the whole promise by itself - a
// hand-maintained `ENV_ARGS` list described as "every FM_* location override,
// in one place, so a launch cannot reach real data through a store somebody
// forgot". It was a list, so it drifted: by 2026-09-25 seven stores resolved a
// real path under it (the sealed clipboard history, session restore, the
// scratchpad, the widget snapshot, the dotfiles auto-sync working tree, and
// both git clone roots), and a probe launch wrote the captain's real files.
// One of those writes - a random-keyed seal over the real
// `clipboard-history.sealed` - is a contributing cause of B1, where two
// 200-entry histories were orphaned in five minutes.
//
// The fix moved the guarantee into the app: `FM_SCRATCH_ROOT`, resolved by
// `AppPaths.dataRoot()`, which every file-backed store's default now comes
// through. This suite is what stops it drifting again, and it checks the two
// directions a list cannot:
//
//   1. **No production file resolves `.applicationSupportDirectory` itself.**
//      That is the only way back to a store the scratch root cannot move.
//      `AppPaths` is the one sanctioned site, and `WidgetSharedContract`'s is
//      an explicitly-marked exemption (it is compiled into the widget
//      extension, which cannot link this module, so it reads the variable by
//      name and case 3 asserts the name agrees).
//   2. **The probe script actually sets `FM_SCRATCH_ROOT`.** A script that
//      lost the line would silently go back to the drift-prone list.
//
// Pure logic and a real file read - no window, no session. Deliberately NOT in
// `NEEDS_SESSION`, so it guards CI's blocking lane.
#if FM_SELFTESTS

import Foundation

enum ProbeScratchRootSelfTest {

    /// Files allowed to resolve `.applicationSupportDirectory` for themselves,
    /// each with the reason it cannot come through `AppPaths.dataRoot()`.
    ///
    /// Per-entry with a stated reason rather than a blanket allowlist - the
    /// same shape as `E2ETestingPolicySelfTest`'s `OffScreenProbe-exempt:`
    /// markers, and for the same reason: the legitimate cases are two, not a
    /// standing licence.
    private static let exempt: [String: String] = [
        // The definition itself.
        "AppPaths.swift": "defines dataRoot()",
        // Compiled into the widget extension as well as the app, so it cannot
        // import AppPaths. Case 3 asserts it spells the variable identically.
        "WidgetSharedContract.swift": "compiled into the widget extension too",
        // Takes the base as a parameter: its whole job is to rename the real
        // folder, which is a location no redirect should move.
        "LegacyNameMigration.swift": "renames the real Application Support folder",
    ]

    static func run() -> Bool {
        var ok = true
        print("== ProbeScratchRootSelfTest ==")
        ok = checkNoStoreResolvesApplicationSupportItself() && ok
        ok = checkScratchRootMovesEveryDefault() && ok
        ok = checkEveryStoreDefaultFollowsTheRoot() && ok
        ok = checkTheWidgetContractSpellsTheVariableIdentically() && ok
        ok = checkTheProbeScriptSetsTheScratchRoot() && ok
        print(ok ? "ProbeScratchRootSelfTest: OK" : "ProbeScratchRootSelfTest: FAILED")
        return ok
    }

    /// The guard proper: a new store that writes its own
    /// `urls(for: .applicationSupportDirectory ...)` is a store `FM_SCRATCH_ROOT`
    /// cannot move, which is exactly how B4 happened.
    private static func checkNoStoreResolvesApplicationSupportItself() -> Bool {
        guard let files = SelfTestSources.appSourceFiles() else {
            print("  SKIP: app sources not next to this binary")
            return true
        }
        var ok = true
        var scanned = 0
        var offenders: [String] = []
        for file in files {
            let name = file.lastPathComponent
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            scanned += 1
            guard text.contains(".applicationSupportDirectory") else { continue }
            if exempt[name] != nil { continue }
            offenders.append(name)
        }
        // The fixture's own discriminating power: if this ever scans nothing,
        // or never sees the token at all, it is passing vacuously.
        check(scanned > 100, "expected to scan the app's sources, scanned \(scanned)", &ok)
        check(exempt.keys.allSatisfy { name in
            files.contains { $0.lastPathComponent == name }
        }, "every exempt file must still exist", &ok)
        check(offenders.isEmpty,
              "these files resolve .applicationSupportDirectory themselves, so FM_SCRATCH_ROOT "
              + "cannot move them - route the default through AppPaths.dataRoot(): "
              + offenders.joined(separator: ", "),
              &ok)
        return ok
    }

    /// `dataRoot()` honours the variable, and the per-store `FM_*` override
    /// still wins over it (a suite that points one store somewhere specific
    /// must keep working).
    private static func checkScratchRootMovesEveryDefault() -> Bool {
        var ok = true
        let real = AppPaths.dataRoot(environment: [:])
        check(real.lastPathComponent == AppPaths.applicationSupportFolderName,
              "with no override dataRoot() is the real folder, got \(real.path)", &ok)
        check(!AppPaths.isScratchRedirected([:]), "no variable means not redirected", &ok)
        check(!AppPaths.isScratchRedirected(["FM_SCRATCH_ROOT": ""]),
              "an empty variable means not redirected", &ok)

        let scratch = AppPaths.dataRoot(environment: ["FM_SCRATCH_ROOT": "/tmp/gl-scratch-probe"])
        check(scratch.path == "/tmp/gl-scratch-probe",
              "FM_SCRATCH_ROOT should be honoured verbatim, got \(scratch.path)", &ok)
        check(scratch.path != real.path,
              "the fixture is vacuous unless the two roots actually differ", &ok)
        check(AppPaths.isScratchRedirected(["FM_SCRATCH_ROOT": "/tmp/gl-scratch-probe"]),
              "a set variable means redirected", &ok)

        let tilde = AppPaths.dataRoot(environment: ["FM_SCRATCH_ROOT": "~/gl-scratch-probe"])
        check(!tilde.path.contains("~"), "a tilde should be expanded, got \(tilde.path)", &ok)

        // The widget snapshot is the one store whose real default is a shared
        // App Group container rather than a path under the root above, so it
        // is the one most likely to be missed - assert it directly.
        let widget = GrandLineWidgetContainer.directory(environment: ["FM_SCRATCH_ROOT": "/tmp/gl-scratch-probe"])
        check(widget.path.hasPrefix("/tmp/gl-scratch-probe"),
              "the widget snapshot should follow FM_SCRATCH_ROOT, got \(widget.path)", &ok)
        let widgetNarrow = GrandLineWidgetContainer.directory(
            environment: ["FM_SCRATCH_ROOT": "/tmp/gl-scratch-probe", "FM_WIDGET_DIR": "/tmp/gl-narrow"])
        check(widgetNarrow.path == "/tmp/gl-narrow",
              "the narrow FM_WIDGET_DIR must still win, got \(widgetNarrow.path)", &ok)
        return ok
    }


    /// The behavioural half of case 1, and the one that actually proves the
    /// promise: with `FM_SCRATCH_ROOT` set and no narrow override in sight,
    /// every store's own default resolver must answer a path inside it.
    ///
    /// A source grep can only see the shape of the code. This drives the real
    /// resolvers, which is what a probe launch drives - and it is how this
    /// suite would catch a store that comes through `AppPaths.dataRoot()` and
    /// then appends its way back out, or one that resolves its default from
    /// somewhere the grep never looks.
    private static func checkEveryStoreDefaultFollowsTheRoot() -> Bool {
        var ok = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gl-scratch-root-case-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)

        // The narrow per-store overrides `run-all-tests.sh` and `main.swift`'s
        // own redirect block leave set in this process would each win over the
        // root, which would make every check below pass for the wrong reason.
        // Clear them for the duration and put them back.
        let narrow = ["FM_CLIPBOARD_HISTORY_FILE", "FM_SESSION_RESTORE_FILE", "FM_SCRATCHPAD_FILE",
                      "FM_HOSTS_FILE", "FM_KEYS_FILE", "FM_SNIPPETS_FILE", "FM_SCHEDULES_FILE",
                      "FM_SCHEDULE_HISTORY_DIR", "FM_FLEET_LOG_DIR", "FM_DICTATION_DIR",
                      "FM_GITHUB_SYNC_CLONE_ROOT", "FM_SHIFT_GIT_CLONE_PATH", "FM_WHISPER_MODEL_DIR",
                      "FM_INSTANCE_LOCK_FILE", "FM_CREDENTIAL_VAULT_DIR", "FM_DOTFILES_AUTOSYNC_PATH",
                      "FM_WIDGET_DIR", "FM_DOCS_DIR", "FM_SCRATCH_ROOT"]
        let saved = narrow.reduce(into: [String: String]()) { out, key in
            if let value = ProcessInfo.processInfo.environment[key] { out[key] = value }
        }
        defer {
            for key in narrow { unsetenv(key) }
            for (key, value) in saved { setenv(key, value, 1) }
        }
        for key in narrow { unsetenv(key) }
        setenv(AppPaths.scratchRootVariable, root.path, 1)

        // Each pair is a store's own default resolver and the name to print.
        // `SSHKeyStore`/`SnippetStore`/`HostStore`/`DictationStore` resolve
        // privately, so they are reached through the value the store exposes.
        var resolved: [(String, URL)] = [
            ("clipboard history", ClipboardHistoryStore.resolveFileURL()),
            ("session restore", SessionRestoreStore.storeURL()),
            ("scratchpad", ScratchpadStore.storeURL()),
            ("schedules", ScheduleStore.storeURL()),
            ("schedule history", ScheduleRunHistoryStore.defaultDirectory()),
            ("fleet log", FleetLogStore.defaultDirectory()),
            ("shift git clone", ShiftGitSync.resolveDefaultWorkingTree()),
            ("whisper models", WhisperModelManager.directoryURL()),
            ("instance lock", SingleInstanceGuard.lockFileURL()),
            ("credential vault root", CredentialVaultStore.applicationSupportRoot),
            ("dotfiles auto-sync", DotfilesAutoSync.resolveDefaultWorkingTree()),
            ("widget snapshot", GrandLineWidgetContainer.directory()),
        ]
        // `SRELead`'s resolver is private; the crew's is not. Both build the
        // same `dataRoot()/<name>` shape and the source guard above covers the
        // private one.
        if let crew = StrawHatCrew.resolveWorkingDirectory() { resolved.append(("straw hat", crew)) }

        check(resolved.count >= 12, "expected every named store, got \(resolved.count)", &ok)
        for (name, url) in resolved {
            check(url.path.hasPrefix(root.path),
                  "\(name) resolved outside FM_SCRATCH_ROOT: \(url.path)", &ok)
        }
        return ok
    }

    /// `WidgetSharedContract` cannot import `AppPaths`, so it restates the
    /// variable name. Same shape as that file's palette and App Group guards.
    private static func checkTheWidgetContractSpellsTheVariableIdentically() -> Bool {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not next to this binary")
            return true
        }
        var ok = true
        guard let text = try? String(contentsOf: dir.appendingPathComponent("WidgetSharedContract.swift"),
                                     encoding: .utf8) else {
            fail("WidgetSharedContract.swift not readable", &ok)
            return ok
        }
        check(text.contains("\"\(AppPaths.scratchRootVariable)\""),
              "WidgetSharedContract must read \(AppPaths.scratchRootVariable) by that exact name", &ok)
        return ok
    }

    /// The script half. It no longer carries the guarantee on its own, but it
    /// is still what a launch passes, so losing the line would put every probe
    /// back on the captain's real data.
    private static func checkTheProbeScriptSetsTheScratchRoot() -> Bool {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not next to this binary")
            return true
        }
        // .../Sources/GrandLine -> .../Sources -> native/
        let nativeRoot = dir.deletingLastPathComponent().deletingLastPathComponent()
        let script = nativeRoot.appendingPathComponent("Scripts/build-probe-app.sh")
        var ok = true
        guard let text = try? String(contentsOf: script, encoding: .utf8) else {
            print("  SKIP: build-probe-app.sh not found at \(script.path)")
            return true
        }
        check(text.contains("\(AppPaths.scratchRootVariable)="),
              "build-probe-app.sh must launch with \(AppPaths.scratchRootVariable) set", &ok)
        check(text.contains("--env \"\(AppPaths.scratchRootVariable)="),
              "\(AppPaths.scratchRootVariable) must be in the launch env, not only a shell variable", &ok)
        return ok
    }
}

#endif
