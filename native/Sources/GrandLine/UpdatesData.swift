// Grand Line - native macOS app.
//
// "Firstmate Latest Updates" (the new `.updates` rail destination): the data
// side. Every dependency in the captain's ecosystem is checked and updated by
// shelling out to the same real CLIs a human would use at a terminal - npm,
// Homebrew, herdr's own updater, no-mistakes' own updater, and (for firstmate
// itself) a fetch-upstream/merge/push script - never a fabricated version
// number. Meant to run entirely off the main thread; `UpdatesController`
// dispatches every `check`/`update` call to a background queue exactly like
// `FleetController.refresh`/`FleetDataSource.mergePR` already do.

import Foundation

// MARK: - Catalog

enum DependencyKind {
    case npmGlobal(package: String)
    case brewFormula(formula: String)
    /// `app` is the bundle the cask installs into `/Applications`, when it
    /// installs one (`nil` for a binary-only cask such as `claude-code`). It
    /// is the second, brew-independent source of the installed version - see
    /// `BrewCaskInstallation`.
    case brewCask(cask: String, app: String? = nil)
    case herdr
    case noMistakes
    case firstmate
    case docs

    var symbol: String {
        switch self {
        case .npmGlobal: return "shippingbox"
        case .brewFormula, .brewCask: return "wrench.and.screwdriver"
        case .herdr: return "bolt.horizontal.circle"
        case .noMistakes: return "checkmark.shield"
        case .firstmate: return "sailboat"
        case .docs: return "book.closed"
        }
    }
}

struct DependencyItem {
    let id: String
    let name: String
    let category: String
    let kind: DependencyKind
}

enum DependencyCatalog {
    /// Section order matches the captain's brief: npm-global tools, Homebrew
    /// tools, then the two special self-updaters, then firstmate itself.
    static let items: [DependencyItem] = [
        .init(id: "tasks-axi", name: "tasks-axi", category: "npm packages", kind: .npmGlobal(package: "tasks-axi")),
        .init(id: "gh-axi", name: "gh-axi", category: "npm packages", kind: .npmGlobal(package: "gh-axi")),
        .init(id: "chrome-devtools-axi", name: "chrome-devtools-axi", category: "npm packages", kind: .npmGlobal(package: "chrome-devtools-axi")),
        .init(id: "lavish-axi", name: "lavish-axi", category: "npm packages", kind: .npmGlobal(package: "lavish-axi")),
        .init(id: "quota-axi", name: "quota-axi", category: "npm packages", kind: .npmGlobal(package: "quota-axi")),
        .init(id: "gh", name: "gh (GitHub CLI)", category: "Homebrew", kind: .brewFormula(formula: "gh")),
        .init(id: "tmux", name: "tmux", category: "Homebrew", kind: .brewFormula(formula: "tmux")),
        .init(id: "claude-code", name: "Claude Code", category: "Homebrew", kind: .brewCask(cask: "claude-code")),
        .init(id: "herdr", name: "herdr", category: "Other tools", kind: .herdr),
        .init(id: "no-mistakes", name: "no-mistakes", category: "Other tools", kind: .noMistakes),
        .init(id: "firstmate", name: "firstmate", category: "Firstmate", kind: .firstmate),
        .init(id: "automic-vault", name: "Automic Vault", category: "Security", kind: .brewCask(cask: "automic-vault/isotopes/automic-vault", app: "Automic Vault.app")),
        .init(id: "devops-playbook", name: "DevOps Playbook", category: "Documentation", kind: .docs),
    ]

    /// Category display order - `Dictionary`-grouping in `UpdatesController`
    /// would otherwise be unordered.
    static let categoryOrder = ["npm packages", "Homebrew", "Other tools", "Firstmate", "Security", "Documentation"]

    /// Per-category tint for a row's `IconTileView` (mirrors the mockup's
    /// blue/red/violet tool-row tiles) - shared by `UpdatesController` and
    /// `BootstrapController`'s software checklist (cockpit-bootstrap-software-
    /// row-parity) so both pages tint the same category identically.
    static func tint(for category: String) -> HelmTint {
        switch category {
        case "npm packages": return .info
        case "Homebrew": return .warn
        case "Other tools": return .neutral
        case "Security": return .violet
        case "Documentation": return .info
        default: return .accent // Firstmate
        }
    }
}

// MARK: - Outcomes

enum DependencyStatus: Equatable {
    case unknown
    case checking
    case upToDate
    case updateAvailable
    case notInstalled
    case checkFailed
    case updating
    case updateFailed

    /// Step 1 of the captain-specified flow: Update is only ever shown once a
    /// Check has run, and never while already up to date - every other
    /// terminal state (update available, not installed, or a failed/unknown
    /// check) is safe to offer Update for, since every update command this
    /// file runs is itself idempotent (installing/upgrading to "latest" when
    /// already current is a safe no-op for npm, brew, herdr, no-mistakes, and
    /// the firstmate sync script alike).
    var showsUpdateButton: Bool {
        switch self {
        case .unknown, .checking, .upToDate, .updating: return false
        case .updateAvailable, .notInstalled, .checkFailed, .updateFailed: return true
        }
    }

    /// **Review defect U10.** Every row carried a "Check" button in every
    /// state, so a page where all thirteen tools were up to date still
    /// invited thirteen clicks that would each re-confirm what the row
    /// already said - and the review's own rule is that "rows that need
    /// nothing should carry no action".
    ///
    /// Check is offered in exactly the two states where it is the row's own
    /// next step:
    ///
    /// - `.unknown`, the row has never been checked, so Check is the only
    ///   thing that can change it;
    /// - `.checkFailed`, where it is a retry.
    ///
    /// It is deliberately **not** offered beside an Update button. A row with
    /// an update available already has its action, and a second control that
    /// re-asks the question the row has just answered is noise next to it.
    /// Nothing is lost: the page-level Refresh re-checks every row, which is
    /// the affordance for "ask again" and is where it belongs.
    var showsCheckButton: Bool {
        switch self {
        case .unknown, .checkFailed: return true
        case .checking, .upToDate, .updating, .updateAvailable, .notInstalled, .updateFailed: return false
        }
    }
}

/// One sweep's statuses, counted once, for every place that states them.
///
/// R2-BUG-03: the Updates page read one state three ways at once. Its toast
/// said "Checked 13 tools, 8 updates available" by counting
/// `showsUpdateButton`, which is also true for a tool that is not installed
/// or whose check failed. Its header said "8 need attention" from the same
/// predicate, its summary strip counted two of the four states, and Setup's
/// Updates card read 0. A sweep where `brew` was unreachable told the
/// captain every tool had an update. The toast, the drill header, the strip
/// and the scheduled tool check now render this one value, and "updates
/// available" counts only `.updateAvailable`.
struct UpdatesSummary: Equatable {
    let total: Int
    let upToDate: Int
    let updatesAvailable: Int
    let notInstalled: Int
    let couldNotCheck: Int
    let updatesFailed: Int
    /// A check or an update is still running, so nothing derived is known.
    let isPending: Bool
    /// Nothing has been checked yet.
    let neverChecked: Bool

    init(_ statuses: [DependencyStatus]) {
        total = statuses.count
        upToDate = statuses.filter { $0 == .upToDate }.count
        updatesAvailable = statuses.filter { $0 == .updateAvailable }.count
        notInstalled = statuses.filter { $0 == .notInstalled }.count
        couldNotCheck = statuses.filter { $0 == .checkFailed }.count
        updatesFailed = statuses.filter { $0 == .updateFailed }.count
        isPending = statuses.contains { $0 == .checking || $0 == .updating }
        neverChecked = !statuses.isEmpty && statuses.allSatisfy { $0 == .unknown }
    }

    /// GL-14: the derived counts are an answer only once nothing is pending
    /// and something has been checked.
    var isKnown: Bool { !isPending && !neverChecked }

    /// Every tool with something to do or something wrong - the rows that
    /// offer an action (`DependencyStatus.showsUpdateButton`).
    var needsAttention: Int { updatesAvailable + notInstalled + couldNotCheck + updatesFailed }

    /// Each non-zero count, worded for a sentence, updates first.
    var parts: [String] {
        var parts: [String] = []
        if updatesAvailable > 0 {
            parts.append(updatesAvailable == 1 ? "1 update available" : "\(updatesAvailable) updates available")
        }
        if upToDate > 0 { parts.append("\(upToDate) up to date") }
        if notInstalled > 0 { parts.append("\(notInstalled) not installed") }
        if couldNotCheck > 0 { parts.append("\(couldNotCheck) could not be checked") }
        if updatesFailed > 0 {
            parts.append(updatesFailed == 1 ? "1 update failed" : "\(updatesFailed) updates failed")
        }
        return parts
    }

    /// The drill header's live line.
    var subtitle: String {
        guard total > 0 else { return "No tools in the catalog" }
        if isPending { return "\(total) tools \u{00B7} checking\u{2026}" }
        if neverChecked { return "\(total) tools \u{00B7} not checked yet" }
        if needsAttention > 0 { return "\(total) tools \u{00B7} \(needsAttention) need attention" }
        return "\(total) tools \u{00B7} all up to date"
    }

    /// The toast a finished sweep shows.
    var completionMessage: String {
        if total > 0 && upToDate == total { return "Checked \(total) tools - all up to date" }
        return "Checked \(total) tools: " + parts.joined(separator: ", ")
    }
}

struct CheckOutcome {
    let installedLabel: String
    let latestLabel: String?
    let status: DependencyStatus
    /// Ready-to-render one-line summary for the row's subtitle - crafted by
    /// whichever `checkXxx` produced it rather than re-derived generically,
    /// since e.g. firstmate's "N commits behind upstream" has no equivalent
    /// in a plain installed/latest version pair.
    let detail: String
    /// Raw command output, shown in the row's expandable log - Safety
    /// principle: "every action's real command/tool output should be visible
    /// to the captain in some form... don't just show a green checkmark with
    /// no evidence."
    let log: String
}

struct UpdateOutcome {
    let ok: Bool
    let newVersionLabel: String?
    let detail: String
    let log: String
    /// Set when the update was not attempted because it needs something a
    /// background child cannot give it (today: an administrator password for
    /// `sudo`). It is the exact command for the captain to run in a terminal,
    /// which the Updates page offers to open in its Console.
    var terminalCommand: String? = nil
}

/// The text a captain reads when an update could not finish in the background.
/// Shared by every update path so a timeout reads the same on every row and
/// never surfaces as the child's own dying words.
///
/// That was the shipped bug: `brew` prints `Error: SIGTERM` when `Subprocess`
/// stops it at the time limit, and the cask row showed exactly that, which
/// reads like a Homebrew crash rather than "we stopped it after five minutes".
enum UpdateFailureText {
    /// `updatesRunTimeout` in words, e.g. "5 minutes".
    static var limitText: String {
        let minutes = Int((UpdatesRunLimits.timeout / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func timedOutDetail(command: String) -> String {
        "Stopped after \(limitText): \(command) was still running"
    }

    /// The log keeps the tool's own output, under a plain account of what
    /// happened and what it means for the machine.
    static func timedOutLog(command: String, output: String) -> String {
        let lines = [
            "Grand Line stopped `\(command)` because it was still running after \(limitText).",
            "It may have been waiting for a password or another answer, which a background update cannot give.",
            "The update may be partly done. Check the app before trying again, or run the command in Terminal to see what it is waiting for.",
        ]
        return ([lines.joined(separator: "\n")] + (output.isEmpty ? [] : ["", output])).joined(separator: "\n")
    }

    static func needsPasswordDetail(command: String) -> String {
        "Needs your administrator password - run in Terminal: \(command)"
    }

    static func needsPasswordLog(command: String, reasons: [String]) -> String {
        var lines = [
            "Not started: this update runs `sudo`, which asks for your administrator password (or Touch ID).",
            "A background update cannot answer that prompt, so it would wait until it was stopped.",
            "",
            "Run this in Terminal instead:",
            "  \(command)",
            "",
            "Why it needs sudo:",
        ]
        lines += reasons.map { "  - \($0)" }
        return lines.joined(separator: "\n")
    }
}

/// One place for how long an update or check command may run.
enum UpdatesRunLimits {
    /// `brew upgrade`, `npm -g install` and `git fetch` legitimately take
    /// minutes on a slow link, so this is far above `Subprocess.defaultTimeout`
    /// - but it is a bound, which is the whole point of GL-02. A check or
    /// update that has not finished in five minutes is wedged, and reporting
    /// that beats a background thread parked forever (the failure that took
    /// every notification signal down with it in GL-03).
    ///
    /// Not raised for casks. The Automic Vault timeout that looked like "five
    /// minutes is too short" was a `sudo` password dialog nobody answered for
    /// thirteen minutes, and no limit fixes that - `BrewCaskSudo` does.
    static let timeout: TimeInterval = 300
}

// MARK: - Process plumbing

// GL-15: this file used to carry its own `resolveExecutable`, its own
// `RunResult` and its own unbounded `Process` runner (which drained stdout to
// EOF and stderr only afterwards - GL-02's half-fix, and a real deadlock for
// `npm -g`/`brew` output). All three now come from `Subprocess`, which drains
// both streams concurrently and bounds every run.

#if FM_SELFTESTS
/// The one interception point for every subprocess this file runs.
///
/// The full-app audit's §7 found the whole Setup/Bootstrap data layer had
/// **zero** coverage, for a straightforward reason: `UpdatesSource.check`/
/// `.update` shell out to real `brew`, `npm`, `git` and `av`, so a suite that
/// drove them would depend on - and mutate - whatever that machine happens to
/// have installed. Not a hazard worth taking for a test.
///
/// The parsing and status-mapping underneath those calls is where the real
/// defects have been, though, and it is pure. Two shipped bugs this file's own
/// comments record: `no-mistakes --version` printing a decoy "v" inside the
/// word "version" before the real token, and `brew list --versions --cask`
/// failing outright for a fully-qualified `owner/tap/cask` token. Both were
/// found live, by hand, with nothing to stop them coming back.
///
/// So this seam replaces the *transport* only, exactly where every call
/// already funnels through, following the `claudePathOverrideForTests`
/// convention this codebase uses for `claude`. It is compiled out of release
/// entirely (GL-27), which CI proves separately by asserting the shipped
/// binary carries no self-test symbols.
///
/// Set both closures together: a fake `run` with real `resolveExecutable`
/// would still depend on what is installed.
///
/// **Every field is behind one lock.** The Updates page, the Setup page and
/// the signals poller check several tools at once on concurrent queues, and
/// every one of those checks reaches `run(_:_:cwd:)` - which appends to
/// `invocations` - in any process that mounts them. An unsynchronised
/// `Array.append` from several threads corrupted the heap: it was the
/// intermittent SIGSEGV/SIGABRT in `FM_RUN_PANEL_AND_PAGE_MOTION_TESTS`
/// (measured 2 in 25 local runs, and red on `main` in CI), crashing inside
/// `run` under `UpdatesController.check`.
enum UpdatesDataTestSeam {
    private static let lock = NSLock()

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static var _run: ((String, [String], URL?) -> SubprocessResult)?
    private static var _resolveExecutable: ((String) -> String?)?
    private static var _homebrewPrefixes: [URL]?
    private static var _applicationsDirectory: URL?
    private static var _invocations: [(executable: String, args: [String])] = []

    /// `(executable, args, cwd) -> result`. `nil` means "really run it".
    static var run: ((String, [String], URL?) -> SubprocessResult)? {
        get { locked { _run } }
        set { locked { _run = newValue } }
    }
    /// `name -> absolute path`, or `nil` to report the tool as missing.
    static var resolveExecutable: ((String) -> String?)? {
        get { locked { _resolveExecutable } }
        set { locked { _resolveExecutable = newValue } }
    }
    /// Replaces every Homebrew prefix `BrewCaskInstallation` would look under
    /// for a `Caskroom`, so a suite reads a fixture directory and never the
    /// machine's real Caskroom. `nil` means "the real prefixes".
    static var homebrewPrefixes: [URL]? {
        get { locked { _homebrewPrefixes } }
        set { locked { _homebrewPrefixes = newValue } }
    }
    /// Replaces `/Applications` for the app-bundle half of the same lookup.
    static var applicationsDirectory: URL? {
        get { locked { _applicationsDirectory } }
        set { locked { _applicationsDirectory = newValue } }
    }

    /// Every `(executable, args)` pair the seam saw, in order - so a test can
    /// assert what was *asked of the tool*, not only what was made of the
    /// reply. That is the half that catches the fully-qualified-cask bug,
    /// whose whole symptom is the wrong argument being sent.
    static var invocations: [(executable: String, args: [String])] {
        get { locked { _invocations } }
        set { locked { _invocations = newValue } }
    }

    /// The one write `run(_:_:cwd:)` makes, atomic as a whole - a
    /// read-modify-write through the `invocations` accessor would still lose
    /// appends between two threads.
    static func record(_ executable: String, _ args: [String]) {
        locked { _invocations.append((executable, args)) }
    }

    static func reset() {
        locked {
            _run = nil
            _resolveExecutable = nil
            _homebrewPrefixes = nil
            _applicationsDirectory = nil
            _invocations = []
        }
    }
}
#endif

private func resolveExecutable(_ name: String) -> String? {
    #if FM_SELFTESTS
    if let override = UpdatesDataTestSeam.resolveExecutable { return override(name) }
    #endif
    return Subprocess.resolveExecutable(name)
}

private typealias RunResult = SubprocessResult

private func run(_ executable: String, _ args: [String], cwd: URL? = nil) -> RunResult {
    #if FM_SELFTESTS
    UpdatesDataTestSeam.record(executable, args)
    if let override = UpdatesDataTestSeam.run { return override(executable, args, cwd) }
    #endif
    return Subprocess.run(executable: executable, arguments: args, cwd: cwd,
                          timeout: UpdatesRunLimits.timeout, log: AppLog.subprocess)
}

/// The failed-update outcome every path below returns. A timeout gets
/// `UpdateFailureText`'s account instead of `detail`, whatever the tool
/// printed on its way out.
private func failedUpdate(_ command: String, _ result: RunResult, detail: String? = nil, log: String? = nil) -> UpdateOutcome {
    let output = log ?? result.combinedLog
    if result.timedOut {
        return UpdateOutcome(ok: false, newVersionLabel: nil,
                             detail: UpdateFailureText.timedOutDetail(command: command),
                             log: UpdateFailureText.timedOutLog(command: command, output: output))
    }
    return UpdateOutcome(ok: false, newVersionLabel: nil, detail: detail ?? "\(command) failed", log: output)
}

private func missingToolOutcome(_ tool: String) -> CheckOutcome {
    CheckOutcome(installedLabel: "\u{2014}", latestLabel: nil, status: .checkFailed, detail: "'\(tool)' not found on PATH", log: "")
}

// MARK: - Checking / updating

enum UpdatesSource {

    static func check(_ item: DependencyItem) -> CheckOutcome {
        switch item.kind {
        case .npmGlobal(let package): return checkNpm(package)
        case .brewFormula(let formula): return checkBrewFormula(formula)
        case .brewCask(let cask, let app): return checkBrewCask(cask, app: app)
        case .herdr: return checkHerdr()
        case .noMistakes: return checkNoMistakes()
        case .firstmate: return checkFirstmate()
        case .docs: return DocsSyncSource.check()
        }
    }

    static func update(_ item: DependencyItem) -> UpdateOutcome {
        switch item.kind {
        case .npmGlobal(let package): return updateNpm(package)
        case .brewFormula(let formula): return updateBrewFormula(formula)
        case .brewCask(let cask, let app): return updateBrewCask(cask, app: app)
        case .herdr: return updateHerdr()
        case .noMistakes: return updateNoMistakes()
        case .firstmate: return updateFirstmate()
        case .docs: return DocsSyncSource.update()
        }
    }

    // MARK: npm-global

    private static func checkNpm(_ package: String) -> CheckOutcome {
        guard let npm = resolveExecutable("npm") else { return missingToolOutcome("npm") }
        let installed = installedNpmVersion(npm: npm, package: package)
        let latestResult = run(npm, ["view", package, "version"])
        let latest = latestResult.status == 0 && !latestResult.stdout.isEmpty ? latestResult.stdout : nil
        let log = [installedNpmLog(npm: npm, package: package), latestResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")

        guard let installed else {
            return CheckOutcome(
                installedLabel: "not installed", latestLabel: latest, status: .notInstalled,
                detail: latest != nil ? "Not installed - \(latest!) available" : "Not installed", log: log
            )
        }
        guard let latest else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - could not reach npm registry for the latest version", log: log)
        }
        if installed == latest {
            return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    private static func installedNpmVersion(npm: String, package: String) -> String? {
        let result = run(npm, ["ls", "-g", package, "--depth=0", "--json"])
        guard let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = obj["dependencies"] as? [String: Any],
              let entry = deps[package] as? [String: Any],
              let version = entry["version"] as? String
        else { return nil }
        return version
    }

    private static func installedNpmLog(npm: String, package: String) -> String {
        run(npm, ["ls", "-g", package, "--depth=0"]).combinedLog
    }

    private static func updateNpm(_ package: String) -> UpdateOutcome {
        guard let npm = resolveExecutable("npm") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'npm' not found on PATH", log: "")
        }
        let result = run(npm, ["install", "-g", package])
        guard result.status == 0 else { return failedUpdate("npm install -g \(package)", result) }
        let version = installedNpmVersion(npm: npm, package: package)
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Installed \(version ?? "latest")", log: result.combinedLog)
    }

    // MARK: Homebrew formula

    private static func checkBrewFormula(_ formula: String) -> CheckOutcome {
        guard let brew = resolveExecutable("brew") else { return missingToolOutcome("brew") }
        let installed = installedBrewVersion(brew: brew, formula: formula)
        let infoResult = run(brew, ["info", "--json=v2", formula])
        let latest = latestBrewFormulaVersion(from: infoResult.stdout)
        let log = infoResult.combinedLog

        guard let installed else {
            return CheckOutcome(installedLabel: "not installed", latestLabel: latest, status: .notInstalled, detail: latest != nil ? "Not installed - \(latest!) available" : "Not installed", log: log)
        }
        guard let latest else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - could not reach Homebrew for the latest version", log: log)
        }
        if installed == latest {
            return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    /// Formulae only. A cask's installed version is read from disk by
    /// `BrewCaskInstallation`, because `brew list --cask` has to load the
    /// cask's definition first and fails outright when a tap ships one this
    /// Homebrew cannot parse.
    private static func installedBrewVersion(brew: String, formula: String) -> String? {
        let result = run(brew, ["list", "--versions", formula])
        guard result.status == 0, !result.stdout.isEmpty else { return nil }
        // "<name> <version>[ <version>...]" - the installed formula/cask name
        // followed by one version per installed copy; the last is the newest.
        return result.stdout.split(separator: " ").last.map(String.init)
    }

    private static func latestBrewFormulaVersion(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = obj["formulae"] as? [[String: Any]],
              let first = formulae.first,
              let versions = first["versions"] as? [String: Any],
              let stable = versions["stable"] as? String
        else { return nil }
        return stable
    }

    private static func updateBrewFormula(_ formula: String) -> UpdateOutcome {
        guard let brew = resolveExecutable("brew") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'brew' not found on PATH", log: "")
        }
        let result = run(brew, ["upgrade", formula])
        guard result.status == 0 else { return failedUpdate("brew upgrade \(formula)", result) }
        let version = installedBrewVersion(brew: brew, formula: formula)
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Upgraded to \(version ?? "latest")", log: result.combinedLog)
    }

    // MARK: Homebrew cask (Claude Code, Automic Vault)

    /// Installed state comes from disk (`BrewCaskInstallation`) and brew is
    /// asked only for the latest version. The order matters because brew
    /// has to load a cask's Ruby definition before it can answer anything
    /// about it, including `brew list --cask`, and a tap can ship a
    /// definition the installed Homebrew cannot parse. That happened live:
    /// `automic-vault/isotopes` moved to an `uninstall_postflight_steps`
    /// block with a `run` step, the Nix-pinned Homebrew 6.0.1 failed every
    /// command with "undefined method 'run'", and this check reported an
    /// installed Automic Vault 4.18.0 as "Not installed" and offered to
    /// install it. A brew failure is therefore never read as absence.
    private static func checkBrewCask(_ cask: String, app: String?) -> CheckOutcome {
        let brew = resolveExecutable("brew")
        let found = BrewCaskInstallation.find(cask: cask, app: app, brewPath: brew)
        guard let brew else {
            guard let found else { return missingToolOutcome("brew") }
            return CheckOutcome(installedLabel: found.version, latestLabel: nil, status: .checkFailed,
                                detail: "Installed \(found.version) - Homebrew not found, cannot determine latest",
                                log: found.evidence)
        }
        ensureTapped(brew: brew, cask: cask)
        let infoResult = run(brew, ["info", "--cask", "--json=v2", cask])
        let latest = infoResult.status == 0 ? latestBrewCaskVersion(from: infoResult.stdout) : nil
        let brewError = infoResult.status != 0 ? BrewCaskInstallation.firstErrorLine(of: infoResult) : nil
        let log = [found?.evidence ?? "", brewError.map { "Homebrew error: \($0)" } ?? "", infoResult.combinedLog]
            .filter { !$0.isEmpty }.joined(separator: "\n")

        guard let installed = found?.version else {
            return CheckOutcome(installedLabel: "not installed", latestLabel: latest, status: .notInstalled, detail: latest != nil ? "Not installed - \(latest!) available" : "Not installed", log: log)
        }
        guard let latest else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - Homebrew could not read the latest version", log: log)
        }
        if installed == latest {
            return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    private static func latestBrewCaskVersion(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]],
              let first = casks.first,
              let version = first["version"] as? String
        else { return nil }
        return version
    }

    /// A fully-qualified `owner/tap/cask` token (unlike a short homebrew-core
    /// name such as `claude-code`) 404s from every brew subcommand until its
    /// tap has been added at least once - confirmed live: `brew info --cask`
    /// on `automic-vault/isotopes/automic-vault` fails with "requires the tap
    /// ... tap it explicitly" before the one-time `brew tap` below. Tapping
    /// only clones the tap's Ruby cask/formula definitions (no code execution,
    /// no install) and is a no-op once already tapped, so it's safe to call
    /// unconditionally ahead of every check/update rather than parsing the
    /// error text to decide whether it's needed.
    private static func ensureTapped(brew: String, cask: String) {
        let segments = cask.split(separator: "/")
        guard segments.count == 3 else { return }
        let tap = "\(segments[0])/\(segments[1])"
        _ = run(brew, ["tap", tap])
    }

    private static func updateBrewCask(_ cask: String, app: String?) -> UpdateOutcome {
        guard let brew = resolveExecutable("brew") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'brew' not found on PATH", log: "")
        }
        ensureTapped(brew: brew, cask: cask)
        // A cask whose upgrade runs `sudo` is not started in the background
        // at all - see `BrewCaskSudo` for the Automic Vault run that waited
        // on an unanswered password dialog until it was stopped.
        let info = run(brew, ["info", "--cask", "--json=v2", cask])
        let current = info.status == 0 ? BrewCaskSudo.artifacts(fromInfoJSON: info.stdout) : []
        let sudoReasons = BrewCaskSudo.reasons(cask: cask, brewPath: brew, currentArtifacts: current)
        if !sudoReasons.isEmpty {
            let command = "brew upgrade --cask \(cask)"
            return UpdateOutcome(ok: false, newVersionLabel: nil,
                                 detail: UpdateFailureText.needsPasswordDetail(command: command),
                                 log: UpdateFailureText.needsPasswordLog(command: command, reasons: sudoReasons),
                                 terminalCommand: command)
        }
        // Matches the exact hint text Claude Code itself prints ("Update
        // available! Run: brew upgrade claude-code") rather than the more
        // explicit `--cask` form - brew resolves it unambiguously on this
        // machine since no formula shares the name.
        let result = run(brew, ["upgrade", cask])
        guard result.status == 0 else {
            // Name brew's own reason. A cask brew cannot load fails here
            // too, and "brew upgrade failed" alone reads like a network blip
            // worth retrying rather than a Homebrew/tap mismatch.
            let reason = BrewCaskInstallation.firstErrorLine(of: result).map { ": \($0)" } ?? ""
            return failedUpdate("brew upgrade \(cask)", result, detail: "brew upgrade \(cask) failed\(reason)")
        }
        let version = BrewCaskInstallation.find(cask: cask, app: app, brewPath: brew)?.version
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Upgraded to \(version ?? "latest")", log: result.combinedLog)
    }

    // MARK: herdr

    /// Installed version comes from `herdr status --json`'s `.client.version`
    /// - the same field firstmate's own `fm_backend_herdr_version_check`
    /// (`bin/backends/herdr.sh`) reads before every herdr-backed spawn.
    /// herdr's CLI has no "check for a newer release without installing it"
    /// flag; the latest-available version is instead read from Homebrew,
    /// since herdr happens to be homebrew-core tapped on this machine
    /// (confirmed live: `brew list --versions herdr` succeeds). The actual
    /// Update action below also goes through Homebrew (`brew update && brew
    /// upgrade herdr`), not `herdr update` - a Homebrew-installed herdr
    /// refuses to self-update by design ("self-update is disabled for
    /// Homebrew installs; run `brew update && brew upgrade herdr`"),
    /// confirmed live, so `herdr update` fails 100% of the time here.
    private static func checkHerdr() -> CheckOutcome {
        guard let herdrPath = resolveExecutable("herdr") else { return missingToolOutcome("herdr") }
        let statusResult = run(herdrPath, ["status", "--json"])
        guard statusResult.status == 0,
              let data = statusResult.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let client = obj["client"] as? [String: Any],
              let installed = client["version"] as? String
        else {
            return CheckOutcome(installedLabel: "\u{2014}", latestLabel: nil, status: .checkFailed, detail: "'herdr status --json' failed", log: statusResult.combinedLog)
        }

        guard let brew = resolveExecutable("brew") else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - Homebrew not found, cannot determine latest", log: statusResult.combinedLog)
        }
        let infoResult = run(brew, ["info", "--json=v2", "herdr"])
        let log = [statusResult.combinedLog, infoResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")
        guard let latest = latestBrewFormulaVersion(from: infoResult.stdout) else {
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: "Installed \(installed) - could not determine the latest herdr release", log: log)
        }
        if installed == latest {
            return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    private static func updateHerdr() -> UpdateOutcome {
        guard let brew = resolveExecutable("brew") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'brew' not found on PATH", log: "")
        }
        let updateResult = run(brew, ["update"])
        let upgradeResult = run(brew, ["upgrade", "herdr"])
        let log = [updateResult.combinedLog, upgradeResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")
        guard upgradeResult.status == 0 else {
            return failedUpdate("brew upgrade herdr", upgradeResult, log: log)
        }
        let version = installedBrewVersion(brew: brew, formula: "herdr")
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Upgraded to \(version ?? "latest")", log: log)
    }

    // MARK: no-mistakes

    /// no-mistakes has no `--check`/JSON flag either, but every subcommand's
    /// `--help` (itself a safe, side-effect-free no-op that never touches the
    /// shared daemon) prints a stderr banner - "A new version of no-mistakes
    /// is available: vX -> vY" - whenever it's outdated, and prints nothing
    /// when current. That banner is the one real signal available without
    /// running the update itself, so it is parsed rather than guessed at.
    private static func checkNoMistakes() -> CheckOutcome {
        guard let path = resolveExecutable("no-mistakes") else { return missingToolOutcome("no-mistakes") }
        let versionResult = run(path, ["--version"])
        guard versionResult.status == 0, let installed = parseNoMistakesVersion(versionResult.stdout) else {
            return CheckOutcome(installedLabel: "\u{2014}", latestLabel: nil, status: .checkFailed, detail: "'no-mistakes --version' failed", log: versionResult.combinedLog)
        }
        // `--help` on a subcommand is a pure no-op (cobra prints usage and
        // exits before touching the daemon) but still triggers the update
        // banner check.
        let helpResult = run(path, ["doctor", "--help"])
        let log = [versionResult.combinedLog, helpResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")
        guard let latest = parseNoMistakesBannerLatest(helpResult.stderr) else {
            return CheckOutcome(installedLabel: installed, latestLabel: installed, status: .upToDate, detail: "\(installed) - up to date", log: log)
        }
        return CheckOutcome(installedLabel: installed, latestLabel: latest, status: .updateAvailable, detail: "\(installed) \u{2192} \(latest)", log: log)
    }

    /// `"no-mistakes version v1.37.0 (78e4dcb) 2026-07-13T03:11:57Z"` -> `"1.37.0"`.
    /// Scans whitespace-separated tokens for one shaped like `v<digit>...`
    /// rather than the first bare "v" in the string - the literal word
    /// "version" starts with a "v" too, and matching that instead left the
    /// rest of the string ("ersion v1.37.0...") with no leading digits,
    /// silently failing every check (caught live: this is exactly what
    /// happened before this fix).
    private static func parseNoMistakesVersion(_ text: String) -> String? {
        for token in text.split(separator: " ") {
            guard token.hasPrefix("v"), let firstAfterV = token.dropFirst().first, firstAfterV.isNumber else { continue }
            let version = token.dropFirst().prefix { $0.isNumber || $0 == "." }
            return version.isEmpty ? nil : String(version)
        }
        return nil
    }

    /// `"A new version of no-mistakes is available: v1.37.0 -> v1.41.2"` -> `"1.41.2"`.
    private static func parseNoMistakesBannerLatest(_ stderr: String) -> String? {
        guard let arrow = stderr.range(of: "-> v") else { return nil }
        let rest = stderr[arrow.upperBound...]
        let version = rest.prefix { $0.isNumber || $0 == "." }
        return version.isEmpty ? nil : String(version)
    }

    /// Never called by this task's own verification (rule: never restart or
    /// update the shared no-mistakes daemon from an agent session) - wired
    /// for the captain's own explicit click in the running app, same as every
    /// other row. `no-mistakes update` is its own idempotent self-updater
    /// (also resets the shared daemon, which is exactly why only an explicit
    /// human click may trigger it - never an automatic check).
    private static func updateNoMistakes() -> UpdateOutcome {
        guard let path = resolveExecutable("no-mistakes") else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "'no-mistakes' not found on PATH", log: "")
        }
        let result = run(path, ["update", "-y"])
        guard result.status == 0 else { return failedUpdate("no-mistakes update", result) }
        let versionResult = run(path, ["--version"])
        let version = parseNoMistakesVersion(versionResult.stdout)
        return UpdateOutcome(ok: true, newVersionLabel: version, detail: "Updated to \(version ?? "latest")", log: result.combinedLog)
    }

    // MARK: firstmate (fetch upstream, ff-merge, push to origin)

    /// Runs `bin/fm-sync-upstream.sh --check` (a new script this task's PR
    /// describes but cannot commit into the firstmate repo itself - see the
    /// PR description). Until the captain adds it, this reports `.notInstalled`
    /// rather than failing or fabricating a result.
    private static func checkFirstmate() -> CheckOutcome {
        let script = FirstmateHome.bin.appendingPathComponent("fm-sync-upstream.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return CheckOutcome(
                installedLabel: firstmateLocalLabel(), latestLabel: nil, status: .notInstalled,
                detail: "bin/fm-sync-upstream.sh not found - see this PR's description for the script to add to the firstmate repo",
                log: ""
            )
        }
        let result = run("/bin/bash", [script.path, "--check"], cwd: FirstmateHome.root)
        guard result.status == 0, let parsed = parseSyncLine(result.stdout) else {
            return CheckOutcome(installedLabel: firstmateLocalLabel(), latestLabel: nil, status: .checkFailed, detail: "fm-sync-upstream.sh --check failed", log: result.combinedLog)
        }
        let installed = firstmateLocalLabel()
        switch parsed.status {
        case "already-current":
            return CheckOutcome(installedLabel: installed, latestLabel: "level with upstream", status: .upToDate, detail: parsed.detail, log: result.combinedLog)
        case "would-update":
            return CheckOutcome(installedLabel: installed, latestLabel: "\(parsed.behind) commit(s) behind", status: .updateAvailable, detail: parsed.detail, log: result.combinedLog)
        case "would-merge":
            return CheckOutcome(installedLabel: installed, latestLabel: "\(parsed.behind) commit(s) to merge", status: .updateAvailable, detail: parsed.detail, log: result.combinedLog)
        default:
            // merge-conflict, dirty tree, no upstream remote, etc. - never
            // treated as "safe to auto-update", surfaced as a failed check
            // with the script's own explanation as the detail.
            return CheckOutcome(installedLabel: installed, latestLabel: nil, status: .checkFailed, detail: parsed.detail, log: result.combinedLog)
        }
    }

    private static func updateFirstmate() -> UpdateOutcome {
        let script = FirstmateHome.bin.appendingPathComponent("fm-sync-upstream.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: "bin/fm-sync-upstream.sh not found", log: "")
        }
        let result = run("/bin/bash", [script.path], cwd: FirstmateHome.root)
        guard result.status == 0, let parsed = parseSyncLine(result.stdout) else {
            return failedUpdate("fm-sync-upstream.sh", result)
        }
        switch parsed.status {
        case "updated":
            return UpdateOutcome(ok: true, newVersionLabel: firstmateLocalLabel(), detail: parsed.detail, log: result.combinedLog)
        case "merged":
            return UpdateOutcome(ok: true, newVersionLabel: firstmateLocalLabel(), detail: parsed.detail, log: result.combinedLog)
        case "already-current":
            return UpdateOutcome(ok: true, newVersionLabel: firstmateLocalLabel(), detail: parsed.detail, log: result.combinedLog)
        default:
            return UpdateOutcome(ok: false, newVersionLabel: nil, detail: parsed.detail, log: result.combinedLog)
        }
    }

    private static func firstmateLocalLabel() -> String {
        let branchResult = run("/usr/bin/git", ["-C", FirstmateHome.root.path, "symbolic-ref", "--short", "HEAD"])
        let shaResult = run("/usr/bin/git", ["-C", FirstmateHome.root.path, "rev-parse", "--short", "HEAD"])
        let branch = branchResult.status == 0 && !branchResult.stdout.isEmpty ? branchResult.stdout : "detached"
        let sha = shaResult.status == 0 && !shaResult.stdout.isEmpty ? shaResult.stdout : "unknown"
        return "\(branch) @ \(sha)"
    }

    /// `"status: would-update \u{00B7} ahead: 0 \u{00B7} behind: 12 \u{00B7} 12 commit(s) behind..."`
    /// - the same "key: value \u{00B7} ..." convention `fm-crew-state.sh`
    /// already uses, so this parser mirrors `FleetDataSource.parseCrewLine`.
    private static func parseSyncLine(_ line: String) -> (status: String, ahead: Int, behind: Int, detail: String)? {
        let parts = line.components(separatedBy: "\u{00B7}").map { $0.trimmingCharacters(in: .whitespaces) }
        var status = "", ahead = 0, behind = 0
        var detailParts: [String] = []
        var sawBehind = false
        for part in parts {
            if part.hasPrefix("status:") {
                status = part.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)
            } else if part.hasPrefix("ahead:") {
                ahead = Int(part.dropFirst("ahead:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if part.hasPrefix("behind:") {
                behind = Int(part.dropFirst("behind:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                sawBehind = true
            } else if sawBehind {
                detailParts.append(part)
            }
        }
        guard !status.isEmpty else { return nil }
        return (status, ahead, behind, detailParts.joined(separator: " \u{00B7} "))
    }
}

// MARK: - Homebrew cask install state, read from disk

/// Where an installed Homebrew cask is, answered from the filesystem rather
/// than from brew. Shared by every page that asks `UpdatesSource.check` about
/// a cask (Updates, Bootstrap, Automation and the Vault page all do), so the
/// rule lives once.
///
/// Two sources, in order:
///
/// 1. `<prefix>/Caskroom/<token>/<version>/`, which is where brew itself
///    records an install. The newest version directory wins.
/// 2. For a cask that installs an app bundle, `/Applications/<app>` and its
///    `CFBundleShortVersionString`.
///
/// Neither needs brew to be able to load the cask's definition, which is the
/// whole point - see `UpdatesSource.checkBrewCask`.
enum BrewCaskInstallation {
    struct Found: Equatable {
        let version: String
        /// One line for the row's log saying where the version was read, so
        /// the captain can see the evidence rather than only the claim.
        let evidence: String
    }

    static func find(cask: String, app: String?, brewPath: String?) -> Found? {
        let token = shortToken(cask)
        for prefix in prefixes(brewPath: brewPath) {
            let dir = prefix.appendingPathComponent("Caskroom").appendingPathComponent(token)
            if let version = newestVersion(in: dir) {
                return Found(version: version, evidence: "Installed: \(dir.appendingPathComponent(version).path)")
            }
        }
        if let app {
            let bundle = applicationsDirectory().appendingPathComponent(app)
            if let version = bundleVersion(of: bundle) {
                return Found(version: version, evidence: "Installed: \(bundle.path) (CFBundleShortVersionString \(version))")
            }
        }
        return nil
    }

    /// The Caskroom is keyed by the short token, so a fully-qualified
    /// `owner/tap/name` has to be cut down to `name` first.
    static func shortToken(_ cask: String) -> String {
        String(cask.split(separator: "/").last ?? Substring(cask))
    }

    /// The prefix of the `brew` this app already resolved (`<prefix>/bin/brew`),
    /// then the two standard ones. The brew path is deliberately not
    /// symlink-resolved: on a nix-homebrew machine it points into the Nix
    /// store while the Caskroom stays under `/opt/homebrew`.
    static func prefixes(brewPath: String?) -> [URL] {
        #if FM_SELFTESTS
        if let override = UpdatesDataTestSeam.homebrewPrefixes { return override }
        #endif
        var paths: [String] = []
        if let brewPath {
            let bin = (brewPath as NSString).deletingLastPathComponent
            if (bin as NSString).lastPathComponent == "bin" {
                paths.append((bin as NSString).deletingLastPathComponent)
            }
        }
        for standard in ["/opt/homebrew", "/usr/local"] where !paths.contains(standard) {
            paths.append(standard)
        }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func applicationsDirectory() -> URL {
        #if FM_SELFTESTS
        if let override = UpdatesDataTestSeam.applicationsDirectory { return override }
        #endif
        return URL(fileURLWithPath: "/Applications", isDirectory: true)
    }

    /// The newest version directory under a cask's Caskroom folder, ignoring
    /// brew's own `.metadata`. Compared numerically so 4.18.0 beats 4.9.0.
    static func newestVersion(in dir: URL) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let versions = names.filter { name in
            var isDir: ObjCBool = false
            return !name.hasPrefix(".")
                && fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
                && isDir.boolValue
        }
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Read from the plist directly rather than through `Bundle`, which
    /// caches by path for the life of the process and would keep reporting
    /// the pre-upgrade version after an update.
    private static func bundleVersion(of bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let version = info["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return nil }
        return version
    }

    /// The line a captain needs from a failed brew run: the first `Error:`
    /// line if there is one, otherwise the first non-empty line of stderr,
    /// then of stdout.
    ///
    /// A run this app stopped at its time limit is the exception. brew's own
    /// last words there are `Error: SIGTERM`, which names our signal rather
    /// than brew's problem, so the line says what actually happened instead.
    static func firstErrorLine(of result: SubprocessResult) -> String? {
        if result.timedOut { return "stopped after \(UpdateFailureText.limitText) because it was still running" }
        let lines = [result.stderr, result.stdout]
            .flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first { $0.hasPrefix("Error:") } ?? lines.first
    }
}

// MARK: - Will this cask's upgrade run sudo?

/// Answers, before anything runs, whether `brew upgrade` on a cask will call
/// `sudo`, and why.
///
/// This exists because of a measured hang. Grand Line's Update on Automic
/// Vault ended with `Error: SIGTERM` after the five-minute limit, and the
/// unified log showed why: brew's uninstall step ran `sudo`, `pam_tid` (Touch
/// ID for sudo, which the captain's nix-darwin config turns on) found no
/// terminal and raised a SecurityAgent password dialog, and that dialog was
/// answered thirteen minutes later - long after the limit had stopped brew.
/// A child of a GUI app has no terminal for `sudo` to fail fast on, and no
/// environment variable stops `pam_tid` from asking, so the only reliable fix
/// is to not start such an upgrade in the background.
///
/// Where the answer comes from matters. On upgrade, brew uninstalls the *old*
/// version with the old version's own stanzas: the installed cask file under
/// `Caskroom/<token>/.metadata/<version>/`, then `INSTALL_RECEIPT.json`'s
/// `uninstall_artifacts` when that file will not load, then the current
/// definition. Automic Vault's installed cask file is `{}`, so brew rebuilt
/// the old cask from a receipt still carrying `uninstall launchctl:` from the
/// 3.2.0 install, even though today's cask no longer has it. All three
/// sources are read and their answers combined, because over-reporting only
/// moves one upgrade into Terminal a release early, while under-reporting is
/// the five-minute hang.
///
/// The directive list mirrors Homebrew 6.0.22's own `sudo: true` call sites
/// in `cask/artifact/abstract_uninstall.rb` and `cask/artifact/pkg.rb`.
/// `quit` is deliberately absent: Homebrew bounds it at ten seconds and moves
/// on when the app does not quit.
enum BrewCaskSudo {

    /// Uninstall directives that always run `sudo` when present.
    private static let sudoUninstallDirectives: [(key: String, why: String)] = [
        ("launchctl", "Homebrew also looks for it in the system launchd domain with sudo"),
        ("kext", "unloading a kernel extension runs sudo"),
        ("pkgutil", "removing an installer package runs sudo"),
        ("delete", "Homebrew deletes these paths with sudo"),
        ("rmdir", "Homebrew lists these directories with sudo"),
    ]

    static func reasons(cask: String, brewPath: String?, currentArtifacts: [Any]) -> [String] {
        var found: [String] = []
        func add(_ more: [String]) {
            for reason in more where !found.contains(reason) { found.append(reason) }
        }
        if let caskroom = installedCaskroom(cask: cask, brewPath: brewPath) {
            add(reasons(in: installedCaskfileArtifacts(caskroom: caskroom, token: BrewCaskInstallation.shortToken(cask))))
            add(reasons(in: receiptUninstallArtifacts(caskroom: caskroom)))
            add(reasons(in: currentArtifacts))
        } else {
            // Nothing to uninstall, so only the install side can ask.
            add(reasons(in: currentArtifacts, uninstall: false))
        }
        return found
    }

    /// The reasons one artifact list carries, as brew's JSON spells it:
    /// an array of single-key objects such as `{"uninstall": [{...}]}`.
    static func reasons(in artifacts: [Any], uninstall: Bool = true) -> [String] {
        var found: [String] = []
        for case let artifact as [String: Any] in artifacts {
            if uninstall, let stanzas = artifact["uninstall"] as? [Any] {
                for case let stanza as [String: Any] in stanzas {
                    for (key, why) in sudoUninstallDirectives {
                        if let value = stanza[key] { found.append("uninstall \(key): \(describe(value)) - \(why)") }
                    }
                    for key in ["early_script", "script"] {
                        if let script = stanza[key] as? [String: Any], script["sudo"] as? Bool == true {
                            found.append("uninstall \(key): \(describe(script["executable"] ?? "")) - runs with sudo: true")
                        }
                    }
                }
            }
            if let pkg = artifact["pkg"] {
                found.append("pkg: \(describe(pkg)) - the macOS installer runs with sudo")
            }
            if let installers = artifact["installer"] as? [Any] {
                for case let installer as [String: Any] in installers {
                    if let script = installer["script"] as? [String: Any], script["sudo"] as? Bool == true {
                        found.append("installer script: \(describe(script["executable"] ?? "")) - runs with sudo: true")
                    }
                }
            }
        }
        return found
    }

    /// `casks[0].artifacts` from `brew info --cask --json=v2`.
    static func artifacts(fromInfoJSON json: String) -> [Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = obj["casks"] as? [[String: Any]],
              let artifacts = casks.first?["artifacts"] as? [Any]
        else { return [] }
        return artifacts
    }

    /// The installed cask's `Caskroom/<token>` folder, under the same
    /// prefixes `BrewCaskInstallation.find` looks in.
    private static func installedCaskroom(cask: String, brewPath: String?) -> URL? {
        let token = BrewCaskInstallation.shortToken(cask)
        for prefix in BrewCaskInstallation.prefixes(brewPath: brewPath) {
            let dir = prefix.appendingPathComponent("Caskroom").appendingPathComponent(token)
            if BrewCaskInstallation.newestVersion(in: dir) != nil { return dir }
        }
        return nil
    }

    private static func receiptUninstallArtifacts(caskroom: URL) -> [Any] {
        let receipt = caskroom.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
        guard let data = try? Data(contentsOf: receipt),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return obj["uninstall_artifacts"] as? [Any] ?? []
    }

    /// `.metadata/<newest version>/<newest timestamp>/Casks/<token>.json`,
    /// the definition brew saved at install time.
    private static func installedCaskfileArtifacts(caskroom: URL, token: String) -> [Any] {
        let metadata = caskroom.appendingPathComponent(".metadata")
        guard let version = BrewCaskInstallation.newestVersion(in: metadata) else { return [] }
        let versionDir = metadata.appendingPathComponent(version)
        guard let stamp = BrewCaskInstallation.newestVersion(in: versionDir) else { return [] }
        let file = versionDir.appendingPathComponent(stamp).appendingPathComponent("Casks/\(token).json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return obj["artifacts"] as? [Any] ?? []
    }

    private static func describe(_ value: Any) -> String {
        if let list = value as? [Any] { return list.map { describe($0) }.joined(separator: ", ") }
        return "\(value)"
    }
}
