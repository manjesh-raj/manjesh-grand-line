// Manjesh Grand Line - native macOS app.
//
// F11 (production-readiness review section 25): the model behind the
// Automation page's "Schedules" card.
//
// The problem F11 names: every check in this app is either on-demand (a page
// visit, a button) or on a fixed poll nobody chose (`BackgroundSignalsPoller`'s
// 15 minutes). There was no way to say "run the drift check nightly and tell me
// only if it drifted". This file is the vocabulary for saying that: which
// already-existing action, how often, and when it is worth interrupting the
// captain over.
//
// The one rule this file exists to enforce is `ScheduledActionKind`'s own
// closed set. F11's security framing is explicit - "only ever schedules actions
// that exist today with their existing confirmations; nothing new becomes
// unattended that is destructive (git pushes and exports are the ceiling;
// `av harden`-class interactive actions are excluded)". Making that a fixed
// enum rather than, say, a stored command string is what makes it structurally
// true: a schedule cannot name an action this app did not already ship, and
// adding a case is a deliberate edit with the bar written down right above it.
//
// What was considered and deliberately left out, each for a stated reason -
// see `ScheduledActionKind`'s doc comment for the full list.
//
// **`grandline-schedule-daily-updates` is a deliberate, captain-approved
// exception to that stated ceiling, not a widening nobody reviewed.** F11's
// original bar excluded software install/upgrade (`UpdatesSource.update`)
// outright, named by this file's own doc comment as "well past a push and an
// export" - it mutates the machine's toolchain via `brew`/`npm`, unattended,
// with no human present to notice a bad upgrade. The captain was shown that
// exact tradeoff, including the two highest-blast-radius items it drags in
// (firstmate's own self-update, a git merge+push of the crewmate control
// plane itself; the Automic Vault security cask), and asked for it anyway
// with zero exceptions - see `ScheduledActionKind.toolUpdateInstall`. The one
// distinction that survives from before this exception: a tool this app
// already treats as needing a human (`.notInstalled`, which Updates' own row
// routes to Bootstrap rather than its own Update button - see
// `UpdatesController`'s history) is still never auto-installed here. Only a
// tool with a genuine update to something *already present* is touched.

import Foundation

// MARK: - What can be scheduled

/// The closed set of schedulable actions.
///
/// **The bar for adding a case**, from F11's own security framing:
///  1. The action already exists in this app as a callable path, and this file
///     calls *that* path. Never a reimplementation, and never a new action.
///  2. It runs to completion with no human present - no `NSOpenPanel`, no
///     `sudo` TTY, no approval prompt from another app.
///  3. Its worst outcome is no worse than a fast-forward git push or an export
///     of data the app already holds. That is the stated ceiling.
///
/// **Deliberately excluded**, each because it fails one of those:
///  - Software install / upgrade (`UpdatesSource.update`) - mutates the
///    machine's toolchain through `brew`/`npm`. Well past "a push and an
///    export", and Bootstrap's own "Install everything missing" is a
///    deliberate click for that reason.
///  - Dotfiles clone / rebuild (`DotfilesRunCommand.runOrCloneCommand`) -
///    runs `darwin-rebuild switch`, which needs a real interactive `sudo`
///    prompt, which is why Bootstrap and Automation both open it as a real
///    Console tab rather than a background process.
///  - Every `av harden …` action (`NotSyncedController`) - named by F11
///    itself as the excluded class. Automic Vault's own approval helper can
///    prompt, and the Homebrew hardener additionally requires an explicit
///    acknowledgement checkbox today.
///  - Restore Grand Line config (`BackupUI.importFlow`) - the captain picks a
///    file in a real open panel, and it overwrites local records.
///  - Install an app update (`AppUpdateInstaller`) - replaces the running
///    bundle and relaunches.
enum ScheduledActionKind: String, Codable, CaseIterable {

    /// Read-only. `DotfilesSource.repoState` + `.agentInstructionItems`, judged
    /// by the same `SetupStepChecks` predicates Bootstrap's own drift card and
    /// Automation's stepper use.
    case driftCheck

    /// Read-only. `UpdatesSource.check` per `DependencyCatalog` item - the
    /// exact call the Updates page makes. Never `UpdatesSource.update`.
    case toolUpdateCheck

    /// A fast-forward push of the captain's own forks: `GitHubSyncSource.check`
    /// then `.sync` only for a repo genuinely behind upstream. `gh repo sync`
    /// with no `--force` anywhere, and a diverged repo is refused, not
    /// overwritten - all of which is that action's existing behaviour, not
    /// something relaxed here.
    case forkSync

    /// A commit + push of the Vault recipe (secret *names* and hardened-tool
    /// metadata, never a value) into `manjesh-config`, through
    /// `VaultRecipeGit.export` - including its `ConfigRepoPrivacy` gate.
    case vaultRecipeExport

    /// A `.glbackup` bundle pushed to the fixed `export-backup/` path in
    /// `manjesh-config`, through `GitHubBackupSource.export`. Same redaction
    /// posture as the manual export: host/snippet/settings records and
    /// non-secret key metadata, never private key bytes or a passphrase.
    case configBackupExport

    /// The captain-approved exception to F11's original ceiling - see this
    /// file's own header for the decision record. `UpdatesSource.check` per
    /// `DependencyCatalog` item, exactly like `.toolUpdateCheck`, followed by
    /// `UpdatesSource.update` for any tool reporting `.updateAvailable` - with
    /// **no confirmation prompt**, including firstmate's own git self-update
    /// and the Automic Vault security cask. A `.notInstalled` tool is left
    /// alone (see `ScheduleActions.toolUpdateInstall`'s doc comment for why);
    /// a `.checkFailed` tool is left alone too, since its check never
    /// established there was anything safe to act on.
    case toolUpdateInstall

    /// Card row title. Matches the captain-approved mockup's own wording for
    /// the three it shows.
    var title: String {
        switch self {
        case .driftCheck:
            return "Drift check \u{2014} dotfiles & agent instructions"
        case .toolUpdateCheck:
            return "Tool update check \u{2014} \(DependencyCatalog.items.count) tools"
        case .forkSync:
            return "Fork sync \u{2014} all \(GitHubSyncCatalog.repos.count) forks"
        case .vaultRecipeExport:
            return "Vault recipe export"
        case .configBackupExport:
            return "Grand Line config backup to GitHub"
        case .toolUpdateInstall:
            return "Tool update check + install \u{2014} \(DependencyCatalog.items.count) tools"
        }
    }

    /// A shorter label for the editor's action picker, where the row title's
    /// live counts would read oddly beside a cadence and a notify setting.
    var pickerTitle: String {
        switch self {
        case .driftCheck: return "Drift check (dotfiles & agent instructions)"
        case .toolUpdateCheck: return "Tool update check"
        case .forkSync: return "Fork sync (personal forks)"
        case .vaultRecipeExport: return "Vault recipe export"
        case .configBackupExport: return "Grand Line config backup to GitHub"
        case .toolUpdateInstall: return "Tool update check + install (no confirmation)"
        }
    }

    var symbol: String {
        switch self {
        case .driftCheck: return "clock.arrow.circlepath"
        case .toolUpdateCheck: return "arrow.down.circle"
        case .forkSync: return "arrow.triangle.branch"
        case .vaultRecipeExport: return "doc.text"
        case .configBackupExport: return "shippingbox"
        case .toolUpdateInstall: return "arrow.down.circle.fill"
        }
    }

    /// The row badge / accent hue when a run has never happened or came back
    /// clean. A read-only check reads informational; an action that writes
    /// somewhere reads as the app's violet "this touches a remote" family,
    /// matching the mockup's own two colours.
    var tint: HelmTint {
        switch self {
        case .driftCheck, .toolUpdateCheck, .forkSync: return .info
        case .vaultRecipeExport, .configBackupExport, .toolUpdateInstall: return .violet
        }
    }

    /// Whether this action writes anywhere outside this machine. Surfaced in
    /// the editor so "unattended git push" is a stated, visible property of
    /// the choice rather than a footnote.
    ///
    /// `.toolUpdateInstall` is `true`: it writes to the machine's own
    /// toolchain unattended regardless, and its firstmate arm can also push a
    /// commit to GitHub (`UpdatesSource.update`'s `.firstmate` case runs
    /// `fm-sync-upstream.sh`, a fetch/merge/push - never force-pushed, a
    /// merge conflict or dirty tree is reported as a failed check rather than
    /// forced through).
    var writesRemotely: Bool {
        switch self {
        case .driftCheck, .toolUpdateCheck: return false
        case .forkSync, .vaultRecipeExport, .configBackupExport, .toolUpdateInstall: return true
        }
    }

    /// What `.changeOnly` means for this action, in the mockup's own phrasing
    /// ("notify on drift only"). A generic "on change" would be true but
    /// uselessly vague on a row the captain reads at a glance.
    var changeNoticeLabel: String {
        switch self {
        case .driftCheck: return "on drift only"
        case .toolUpdateCheck: return "on updates available only"
        case .forkSync: return "on forks synced only"
        case .vaultRecipeExport: return "on recipe change only"
        case .configBackupExport: return "on backup change only"
        case .toolUpdateInstall: return "on updates installed only"
        }
    }

    /// One line in the editor saying exactly what will run, so an unattended
    /// action is never a name the captain has to guess at.
    var explanation: String {
        switch self {
        case .driftCheck:
            return "Fetches ~/.dotfiles and re-checks the AGENTS.md/CLAUDE.md symlinks. "
                + "Read-only: it reports drift, it never rebuilds or pulls."
        case .toolUpdateCheck:
            return "Checks every tracked tool for a newer version, exactly as the Updates page does. "
                + "Read-only: it never installs or upgrades anything."
        case .forkSync:
            return "Fast-forwards each personal fork that is behind its upstream. "
                + "A fork with local-only commits is reported and left alone, never force-pushed."
        case .vaultRecipeExport:
            return "Commits and pushes the recipe (secret names and which tools are hardened) to manjesh-config. "
                + "A secret's value is never read, stored, or sent."
        case .configBackupExport:
            return "Pushes a .glbackup bundle of hosts, snippets and preferences to manjesh-config. "
                + "Private key material and passphrases are never included."
        case .toolUpdateInstall:
            return "Checks every tracked tool exactly as the Updates page does, then installs any update it "
                + "finds - with no confirmation prompt, including firstmate's own self-update and the Automic "
                + "Vault security cask. A tool that isn't installed yet, or whose check itself fails, is left "
                + "alone rather than force-installed."
        }
    }
}

// MARK: - Cadence

/// Deliberately just the two shapes F11's UX names ("Nightly at 2:00 AM",
/// "Weekly, Sunday 6:00 AM"). A cron expression would be more expressive and
/// materially harder to read back on a row the captain glances at - and this
/// app already has a cron *explainer* (`CronExplainer`) for the day that
/// becomes worth it.
enum ScheduleCadence: Codable, Equatable {
    case daily(hour: Int, minute: Int)
    /// `weekday` is `Calendar`'s own 1-based numbering, 1 = Sunday, so it can
    /// be handed straight to `DateComponents(weekday:)` with no translation
    /// layer to get wrong.
    case weekly(weekday: Int, hour: Int, minute: Int)

    var hour: Int {
        switch self {
        case .daily(let h, _), .weekly(_, let h, _): return h
        }
    }

    var minute: Int {
        switch self {
        case .daily(_, let m), .weekly(_, _, let m): return m
        }
    }

    /// Clamped into range, so a hand-edited `schedules.json` cannot produce a
    /// `DateComponents` that matches nothing and silently never fires.
    var normalized: ScheduleCadence {
        let h = min(23, max(0, hour))
        let m = min(59, max(0, minute))
        switch self {
        case .daily: return .daily(hour: h, minute: m)
        case .weekly(let wd, _, _): return .weekly(weekday: min(7, max(1, wd)), hour: h, minute: m)
        }
    }

    /// The `DateComponents` a `Calendar` occurrence search matches on.
    var matchingComponents: DateComponents {
        switch normalized {
        case .daily(let h, let m):
            return DateComponents(hour: h, minute: m, second: 0)
        case .weekly(let wd, let h, let m):
            return DateComponents(hour: h, minute: m, second: 0, weekday: wd)
        }
    }

    static let weekdayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// "Nightly at 2:00 AM" / "Daily at 9:00 AM" / "Weekly, Sunday 6:00 AM" -
    /// the mockup's own strings. "Nightly" rather than "Daily" for an hour that
    /// genuinely is night, since that is what the mockup shows for 2 AM and it
    /// reads better than a uniform "Daily" on the row it was designed for.
    var displayString: String {
        let n = normalized
        switch n {
        case .daily(let h, _):
            let word = (h >= 22 || h <= 5) ? "Nightly" : "Daily"
            return "\(word) at \(Self.clockString(hour: h, minute: n.minute))"
        case .weekly(let wd, let h, _):
            let day = Self.weekdayNames[min(7, max(1, wd))]
            return "Weekly, \(day) \(Self.clockString(hour: h, minute: n.minute))"
        }
    }

    static func clockString(hour: Int, minute: Int) -> String {
        let suffix = hour < 12 ? "AM" : "PM"
        var display = hour % 12
        if display == 0 { display = 12 }
        return String(format: "%d:%02d %@", display, minute, suffix)
    }
}

// MARK: - Notify-on

/// When a completed run is worth an in-app Notification Center entry. Every
/// run reports to the Health surface regardless (F11: "runs log to the Health
/// surface") - this only governs the louder half.
enum ScheduleNotifyOn: String, Codable, CaseIterable {
    /// Every run, clean or not.
    case always
    /// Only a run that failed.
    case failureOnly
    /// A failure, or a run that actually found/did something - "notify on
    /// drift only" in the mockup. The default, and the one that matches this
    /// app's "quiet until it matters" principle.
    case changeOnly

    /// Row wording, per action so `.changeOnly` can say "on drift only".
    func displayString(for action: ScheduledActionKind) -> String {
        switch self {
        case .always: return "notify always"
        case .failureOnly: return "notify on failure only"
        case .changeOnly: return "notify \(action.changeNoticeLabel)"
        }
    }

    func pickerTitle(for action: ScheduledActionKind) -> String {
        switch self {
        case .always: return "Always"
        case .failureOnly: return "Only on failure"
        case .changeOnly: return "Only \(action.changeNoticeLabel.replacingOccurrences(of: " only", with: ""))"
        }
    }
}

// MARK: - Run results

/// What a completed run amounted to. Three states, because "it ran and there
/// was nothing to do" and "it ran and it changed something" are genuinely
/// different things to the captain - that distinction is exactly what
/// `.changeOnly` keys off.
enum ScheduleRunVerdict: String, Codable {
    /// Ran successfully, nothing needed doing.
    case clean
    /// Ran successfully and either found something (a read-only check) or did
    /// something (a write action).
    case changed
    case failed

    var label: String {
        switch self {
        case .clean: return "Clean"
        case .changed: return "Needs you"
        case .failed: return "Failed"
        }
    }

    var tint: HelmTint {
        switch self {
        case .clean: return .good
        case .changed: return .warn
        case .failed: return .critical
        }
    }
}

struct ScheduleRunRecord: Codable, Equatable {
    var verdict: ScheduleRunVerdict
    /// A short, already-composed sentence from the action itself (e.g.
    /// "2 of 8 forks fast-forwarded") - never re-derived generically here, the
    /// same convention `CheckOutcome.detail` and `GitHubSyncCheckOutcome.detail`
    /// already follow.
    var summary: String
    var at: Date
}

// MARK: - The schedule

struct AutomationSchedule: Codable, Equatable, Identifiable {
    var id: UUID
    var action: ScheduledActionKind
    var cadence: ScheduleCadence
    var notifyOn: ScheduleNotifyOn
    /// Disabled means "keep the schedule, stop running it" - the mockup's
    /// toggle, which is deliberately not a delete.
    var isEnabled: Bool
    var lastRun: ScheduleRunRecord?

    /// The scheduled occurrence this schedule has already been run for.
    ///
    /// This is the whole missed-while-asleep mechanism, and it is why there is
    /// no stored "next run" field. `ScheduleDueCalculator` compares the most
    /// recent occurrence at-or-before *now* against this: a Mac asleep from
    /// 01:00 to 09:00 wakes with today's 02:00 occurrence being the most recent
    /// one and this still pointing at yesterday's, so the run fires on wake
    /// rather than being skipped. It also means a long gap produces exactly
    /// *one* catch-up run rather than one per missed occurrence, which is the
    /// right shape for every action here - re-running a drift check seven times
    /// to "catch up" on a week away would be pure noise.
    ///
    /// Seeded at creation to the occurrence current at that moment (see
    /// `ScheduleStore.add`), so a nightly-at-02:00 schedule created at 15:00
    /// does not fire the instant it is saved.
    var lastFiredOccurrence: Date?

    init(id: UUID = UUID(),
         action: ScheduledActionKind,
         cadence: ScheduleCadence,
         notifyOn: ScheduleNotifyOn = .changeOnly,
         isEnabled: Bool = true,
         lastRun: ScheduleRunRecord? = nil,
         lastFiredOccurrence: Date? = nil) {
        self.id = id
        self.action = action
        self.cadence = cadence
        self.notifyOn = notifyOn
        self.isEnabled = isEnabled
        self.lastRun = lastRun
        self.lastFiredOccurrence = lastFiredOccurrence
    }

    /// Old-format tolerance, the same lesson `Host.init(from:)` records: a
    /// Swift-side default does not protect on-disk JSON once a key is listed in
    /// `CodingKeys`, so every field that has a default decodes with
    /// `decodeIfPresent`. `id`/`action`/`cadence` have no meaningful default
    /// and stay required - a schedule with no action is not a schedule.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        action = try c.decode(ScheduledActionKind.self, forKey: .action)
        cadence = try c.decode(ScheduleCadence.self, forKey: .cadence)
        notifyOn = try c.decodeIfPresent(ScheduleNotifyOn.self, forKey: .notifyOn) ?? .changeOnly
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastRun = try c.decodeIfPresent(ScheduleRunRecord.self, forKey: .lastRun)
        lastFiredOccurrence = try c.decodeIfPresent(Date.self, forKey: .lastFiredOccurrence)
    }

    /// The mockup's meta line: cadence, notify setting, and the last run.
    func metaLine(now: Date = Date()) -> String {
        var parts = [cadence.displayString, notifyOn.displayString(for: action)]
        if !isEnabled {
            parts.append("paused")
        }
        if let lastRun {
            parts.append("last run: \(lastRun.verdict.rawValue), \(Self.relativeAge(from: lastRun.at, to: now))")
        } else {
            parts.append("not run yet")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "6h ago" / "just now" / "3d ago". Deliberately not
    /// `RelativeDateTimeFormatter`, whose output ("in 6 hours"/"6 hours ago")
    /// is longer than this row's meta line has space for.
    static func relativeAge(from: Date, to: Date) -> String {
        let seconds = max(0, to.timeIntervalSince(from))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
