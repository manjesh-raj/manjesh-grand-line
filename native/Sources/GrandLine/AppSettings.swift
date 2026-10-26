// Grand Line - native macOS app.
//
// App-level preferences, backed by `UserDefaults`. Before the Settings panel
// (Fix 3), these lived as ad-hoc environment-variable reads scattered across
// `TerminalEnvironment.swift`, with no UI to change them. The env vars still
// win when set (so existing dev/CI workflows that export them keep working
// unchanged); otherwise the persisted value here applies, editable from
// Settings > General.
//
// `FM_SHELL_CWD` is the live example of that. This used to name
// `FM_MIRROR_TARGET` beside it, which was the review's L10 finding: the
// mirror feature was removed twice over (PR #291's E1 collapsed the
// abstraction, `fm/grand-line-remove-firstmate-mirror` deleted what was left)
// and nothing has read that variable since, so listing it under "the env vars
// still win when set" promised an override that does nothing. The README's
// env-var table is the authoritative list of what is actually read.

import Foundation

final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    private enum Keys {
        static let fontSize = "fm.fontSize"
        static let uiTextScale = "fm.uiTextScale"
        static let defaultShellCwd = "fm.defaultShellCwd"
        static let autoReconnect = "fm.autoReconnect"
        static let notifyOnNeedsDecision = "fm.notifyOnNeedsDecision"
        static let notificationMutedSources = "fm.notifications.mutedSources"
        static let notificationQuietWhileFocusing = "fm.notifications.quietWhileFocusing"
        static let fmHome = "fm.fmHome"
        static let dictationShortcut = "fm.dictationShortcut"
        static let quickCaptureShortcut = "fm.quickCaptureShortcut"
        static let dictationCleanupEnabled = "fm.dictationCleanupEnabled"
        static let dictationLocalWhisperEnabled = "fm.dictationLocalWhisperEnabled"
        static let morningBriefingEnabled = "fm.morningBriefingEnabled"
        static let morningBriefingRecord = "fm.morningBriefingRecord"
        static let didSeedDailyGitHubSyncSchedule = "fm.didSeedDailyGitHubSyncSchedule"
        static let terminalShortcuts = "fm.terminalShortcuts"
        static let terminalScrollbackRows = "fm.terminal.scrollbackRows"
        static let terminalTrimsBackgroundScrollback = "fm.terminal.trimBackgroundScrollback"
        static let terminalHighlighting = "fm.terminalHighlighting"
        static let quickAccess = "fm.quickAccess"
        static let hasSeenWelcome = "fm.hasSeenWelcome"
        static let snippetExpansionEnabled = "fm.snippetExpansionEnabled"
        static let dotfilesAutoCommitEnabled = "fm.dotfilesAutoCommitEnabled"
        static let compactModeEnabled = "fm.compactModeEnabled"
        static let compactModeHidesDockIcon = "fm.compactModeHidesDockIcon"
        static let compactModeBadgesOverdueCount = "fm.compactModeBadgesOverdueCount"
        /// X2. Stored inverted ("separate", default false) rather than as
        /// "merged" so the shipped default is the value `UserDefaults`
        /// already returns for a key nobody has written - a `bool(forKey:)`
        /// default of `false` that has to mean `true` is how a preference
        /// silently reverts on the machine that has never opened Settings.
        static let menuBarSeparateItems = "fm.menuBarSeparateItems"
        static let followSystemAppearance = "fm.followSystemAppearance"
        static let systemLightThemeID = "fm.systemLightThemeID"
        static let systemDarkThemeID = "fm.systemDarkThemeID"
        static let workspaceLayout = "fm.workspaceLayout"
        static let homeCardLayout = "fm.homeCardLayout"
        static let appLockEnabled = "fm.appLockEnabled"
        static let workspaceProfile = "fm.workspaceProfile"
        static let hiddenModules = "fm.hiddenModules"
        static let sidebarWidth = "fm.sidebarWidth"
        static let connectionsViewMode = "fm.connections.viewMode"
        static let hostTagMatchAll = "fm.connections.tagMatchAll"
        static let hostsGrouped = "fm.connections.hostsGrouped"
        static let workspaceToolbarItems = "fm.workspaceToolbar.items"
        static let workspaceToolbarDisplayMode = "fm.workspaceToolbar.displayMode"
        static let appLockIdleSeconds = "fm.appLockIdleSeconds"
        static let appLockSessionSeconds = "fm.appLockSessionSeconds"
    }

    /// GL-P3 (audit §6.10): the defaults store is injectable.
    ///
    /// `shared` is still the only instance the app ever builds, and still
    /// reads `UserDefaults.standard`. What this buys is a self-test that
    /// wants to exercise a settings-shaped behaviour without writing through
    /// to the captain's real preferences - the non-hermetic hazard this
    /// repo's own suites have been bitten by more than once (see
    /// `Phase3PolishSelfTest`'s theme-restore source guard, and every suite
    /// that saves and restores `AppSettings.uiTextScale` by hand around a
    /// `ChromeTextScale.setScale` call).
    ///
    /// Deliberately not adopted by those suites here: they save and restore
    /// the real value, which is the honest thing to do for a *singleton*'s
    /// behaviour, and switching them to an injected store would change what
    /// they prove. This is the seam, not a migration.
    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
    }

    /// Terminal font size in points. Settings > Terminal's +/- steppers and
    /// `ConsoleController.zoomIn/zoomOut` both read and write this so the
    /// choice survives relaunch.
    var fontSize: CGFloat {
        get {
            let v = defaults.double(forKey: Keys.fontSize)
            return v > 0 ? CGFloat(v) : 13
        }
        set { defaults.set(Double(newValue), forKey: Keys.fontSize) }
    }

    /// GL-32: a multiplier applied to every `HelmType` size - the app's UI
    /// chrome text, as distinct from `fontSize`, which is the *terminal* and
    /// monospace-tool size. 1.0 is the designed scale; Settings > Terminal's
    /// "Interface text" row writes 1.0 / 1.15 / 1.3.
    ///
    /// Clamped on read as well as on write, so a hand-edited preference
    /// cannot produce a layout nothing in this app was measured against.
    var uiTextScale: CGFloat {
        get {
            let v = defaults.double(forKey: Keys.uiTextScale)
            guard v > 0 else { return 1.0 }
            return min(ChromeTextScale.maxScale, max(ChromeTextScale.minScale, CGFloat(v)))
        }
        set {
            let clamped = min(ChromeTextScale.maxScale, max(ChromeTextScale.minScale, newValue))
            defaults.set(Double(clamped), forKey: Keys.uiTextScale)
        }
    }

    /// Settings > General's "Default working directory" - checked by
    /// `shellCwd()` after `FM_SHELL_CWD`, before falling back to `$HOME`.
    var defaultShellCwd: String? {
        get { defaults.string(forKey: Keys.defaultShellCwd) }
        set { defaults.set(newValue, forKey: Keys.defaultShellCwd) }
    }

    /// Settings > Terminal's "Reconnect automatically" toggle (Fix 3) -
    /// `ConsoleController.processTerminated` schedules a real reconnect of a
    /// tab whose process exited unexpectedly when this is on, rather than
    /// just showing the "press ⌘R to reconnect" hint. Defaults to on, since
    /// a dropped connection auto-recovering is the least surprising default.
    var autoReconnect: Bool {
        get { defaults.object(forKey: Keys.autoReconnect) == nil ? true : defaults.bool(forKey: Keys.autoReconnect) }
        set { defaults.set(newValue, forKey: Keys.autoReconnect) }
    }

    /// Settings > Terminal's "Bell & notifications" toggle (Fix 3) - when on,
    /// `FleetNotifier` posts a real macOS notification the moment a task
    /// newly needs the captain's decision. Off by default so a fresh launch
    /// never surprises anyone with a notification-permission prompt.
    var notifyOnNeedsDecision: Bool {
        get { defaults.bool(forKey: Keys.notifyOnNeedsDecision) }
        set { defaults.set(newValue, forKey: Keys.notifyOnNeedsDecision) }
    }

    /// The notification sources the captain has muted, by
    /// `AppNotification.source` ("Updates", "GitHub Sync"). The bell's
    /// "Mute ..." used to last for the session only; it is a setting now, so
    /// it survives a relaunch and Settings > Notifications can list and undo
    /// it. Sorted on write so the stored value does not churn with set order.
    var notificationMutedSources: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.notificationMutedSources) ?? []) }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Keys.notificationMutedSources)
            } else {
                defaults.set(newValue.sorted(), forKey: Keys.notificationMutedSources)
            }
        }
    }

    /// Hold informational notifications while a focus session runs. On by
    /// default: the captain approved the behaviour as part of the Bridge
    /// redesign, and a focus timer that let "3 tools have updates" through
    /// would not be doing its one job. Action-needed entries always show.
    var notificationQuietWhileFocusing: Bool {
        get { defaults.object(forKey: Keys.notificationQuietWhileFocusing) == nil
                ? true : defaults.bool(forKey: Keys.notificationQuietWhileFocusing) }
        set { defaults.set(newValue, forKey: Keys.notificationQuietWhileFocusing) }
    }

    /// Bootstrap page's "Firstmate home" card - checked by
    /// `FirstmateHome.resolve()` after `FM_HOME`/`FIRSTMATE_HOME`, before the
    /// hardcoded fallback candidates. `FirstmateHome.root` is computed once
    /// at process launch, so changing this only takes effect after a
    /// restart - the Bootstrap page makes that explicit on save.
    var fmHome: String? {
        get { defaults.string(forKey: Keys.fmHome) }
        set { defaults.set(newValue, forKey: Keys.fmHome) }
    }

    /// Dictation's configurable shortcut (phase 2, fm/grandline-dictation-
    /// phase2) - replaces the phase-1 fixed Right ⌥ Option combo. Stored as
    /// JSON `Data` (via `Codable`) rather than a fourth/fifth/sixth flat key,
    /// since `KeyChord` is a small, cohesive value that's always
    /// read/written as one unit - there's no scenario where only its keyCode
    /// or only its modifier flags would be read independently. Falls back to
    /// `.dictationDefault` (Right ⌥ Option) whenever nothing's been saved yet
    /// or the stored value fails to decode.
    var dictationShortcut: KeyChord {
        get {
            guard let data = defaults.data(forKey: Keys.dictationShortcut),
                  let decoded = try? JSONDecoder().decode(KeyChord.self, from: data) else {
                return .dictationDefault
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.dictationShortcut)
        }
    }

    /// Universal capture's configurable shortcut
    /// (`fm/grandline-capture-global-hotkey-configurable`) - ⌥Space until the
    /// captain records something else on Settings > Capture.
    ///
    /// Stored as JSON `Data` for exactly the reason `dictationShortcut` above
    /// states: a `KeyChord` is a small cohesive value that is always read and
    /// written as one unit, and splitting it into flat keys would invent a
    /// half-written state nothing wants. Falls back to `.quickCaptureDefault`
    /// whenever nothing has been saved yet or the stored value fails to
    /// decode, so a corrupted preference costs the captain their choice and
    /// not the feature.
    var quickCaptureShortcut: KeyChord {
        get {
            guard let data = defaults.data(forKey: Keys.quickCaptureShortcut),
                  let decoded = try? JSONDecoder().decode(KeyChord.self, from: data) else {
                return .quickCaptureDefault
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.quickCaptureShortcut)
        }
    }

    /// Settings > Shortcuts' nine configurable Console bindings
    /// (`fm/grand-line-terminal-shortcuts-settings`) - moving between tabs,
    /// splitting a terminal, and moving between the panes that produces.
    ///
    /// One JSON value rather than nine flat keys, on the same "always read
    /// and written as a unit" reasoning `dictationShortcut` above already
    /// follows. `TerminalShortcutSet` falls back per action, so a stored
    /// value that decodes but is missing an entry - or a captain who has only
    /// ever rebound one of the nine - keeps the shipped default for the rest
    /// rather than the whole set resetting.
    var terminalShortcuts: TerminalShortcutSet {
        get {
            guard let data = defaults.data(forKey: Keys.terminalShortcuts),
                  let decoded = try? JSONDecoder().decode(TerminalShortcutSet.self, from: data) else {
                return .defaults
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.terminalShortcuts)
        }
    }

    /// Settings > Terminal's scrollback depth (T4) - how many rows of
    /// history every interactive pane keeps. Read through
    /// `TerminalScrollback`, which owns the range and the live apply.
    ///
    /// A key nobody has written reads as the shipped 10,000, and a stored
    /// value is normalised on the way out as well as on the way in, so a
    /// hand-edited preference cannot give a pane a depth nothing here was
    /// measured against.
    var terminalScrollbackRows: Int {
        get {
            guard defaults.object(forKey: Keys.terminalScrollbackRows) != nil else {
                return TerminalScrollback.defaultRows
            }
            return TerminalScrollback.normalised(defaults.integer(forKey: Keys.terminalScrollbackRows))
        }
        set { defaults.set(TerminalScrollback.normalised(newValue), forKey: Keys.terminalScrollbackRows) }
    }

    /// Settings > Terminal's "Trim tabs left in the background" (T4): PERF-07's
    /// background trim, which used to be unconditional. On by default, because
    /// that is what shipped.
    var terminalTrimsBackgroundScrollback: Bool {
        get {
            defaults.object(forKey: Keys.terminalTrimsBackgroundScrollback) == nil
                ? true : defaults.bool(forKey: Keys.terminalTrimsBackgroundScrollback)
        }
        set { defaults.set(newValue, forKey: Keys.terminalTrimsBackgroundScrollback) }
    }

    /// Settings > Terminal's keyword highlighting (T1-T3 of the Termius-style
    /// plan): the master switch, the six built-in classes and the captain's
    /// own rules.
    ///
    /// One JSON value, the same shape as `terminalShortcuts` above (choice C2),
    /// and per Mac. `KeywordHighlightSettings` decodes every field with a
    /// default (GL-01), so an unreadable value falls back to the shipped
    /// defaults rather than to "off".
    var terminalHighlighting: KeywordHighlightSettings {
        get {
            guard let data = defaults.data(forKey: Keys.terminalHighlighting),
                  let decoded = try? JSONDecoder().decode(KeywordHighlightSettings.self, from: data) else {
                return .defaults
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.terminalHighlighting)
        }
    }

    /// Dictation's "Clean up my sentences" toggle (phase 3,
    /// fm/grandline-dictation-phase3) - when on, `DictationEngine.finish`
    /// rewrites the raw transcript via a one-shot `claude -p` call
    /// (`DictationCleanup.rewrite`) before pasting/recording it. Off by
    /// default: this step needs network access and the captain's own
    /// `claude` authentication, unlike the rest of the fully on-device
    /// pipeline, so a fresh install shouldn't silently start making network
    /// calls on every dictation.
    var dictationCleanupEnabled: Bool {
        get { defaults.bool(forKey: Keys.dictationCleanupEnabled) }
        set { defaults.set(newValue, forKey: Keys.dictationCleanupEnabled) }
    }

    /// F12's master switch: whether a snippet's `;abbrev` trigger expands
    /// while the captain is typing in other apps.
    ///
    /// Off by default, and unlike the Dictation toggles above the reason is
    /// not a download or a network call - it is that this one installs a
    /// global keyboard monitor. A feature that watches every keystroke on the
    /// machine is opt-in even when the watching is as bounded as
    /// `SnippetExpander`'s (see that file's "Keystroke privacy" note). Turning
    /// it off tears the monitors down rather than leaving them installed and
    /// ignored.
    /// C4 of the Termius-style plan: Connections' Hosts and Keys draw as a
    /// card grid or as the table. Grid is the default, so an unset key reads
    /// as grid and only a captain who chose List has anything stored.
    var connectionsShowList: Bool {
        get { defaults.string(forKey: Keys.connectionsViewMode) == "list" }
        set { defaults.set(newValue ? "list" : "grid", forKey: Keys.connectionsViewMode) }
    }

    /// Whether the Hosts card grid draws one section per group. Off by
    /// default: the grid is one flat run of cards, the way the Keys grid is,
    /// and each card names its group. An unset key reads as off, so nothing
    /// a captain saved before this existed changes what they see.
    var hostsGrouped: Bool {
        get { defaults.bool(forKey: Keys.hostsGrouped) }
        set { defaults.set(newValue, forKey: Keys.hostsGrouped) }
    }

    /// X4: the Hosts tag chips match a host carrying **all** of the selected
    /// tags rather than any one of them. Off by default, which is how the
    /// chips have always matched.
    var hostTagMatchAll: Bool {
        get { defaults.bool(forKey: Keys.hostTagMatchAll) }
        set { defaults.set(newValue, forKey: Keys.hostTagMatchAll) }
    }

    var snippetExpansionEnabled: Bool {
        get { defaults.bool(forKey: Keys.snippetExpansionEnabled) }
        set { defaults.set(newValue, forKey: Keys.snippetExpansionEnabled) }
    }

    /// Bootstrap's "Dotfiles & machine config" card: whether Grand Line
    /// commits and pushes changes under the dotfiles repo's `home/` tree by
    /// itself - see `DotfilesAutoSync.swift`.
    ///
    /// **On by default**, unlike the three opt-ins above, and the reason is
    /// that the alternative default is the bug. `home.nix` symlinks those
    /// files live into the home directory, so editing a herdr theme edits a
    /// tracked file in place; leaving this off by default means the captain
    /// keeps discovering uncommitted dotfiles by hand, which is exactly what
    /// this feature exists to stop. It also cannot surprise anyone with a
    /// permission prompt or a keyboard monitor: it touches one repository the
    /// captain already owns, it is scoped to `home/` alone, and it refuses
    /// rather than forces whenever the remote has genuinely diverged.
    ///
    /// Turning it off tears the file-system watcher and the periodic pass
    /// down rather than leaving them installed and ignored
    /// (`DotfilesAutoSync.settingChanged()`).
    var dotfilesAutoCommitEnabled: Bool {
        get { defaults.object(forKey: Keys.dotfilesAutoCommitEnabled) == nil ? true : defaults.bool(forKey: Keys.dotfilesAutoCommitEnabled) }
        set { defaults.set(newValue, forKey: Keys.dotfilesAutoCommitEnabled) }
    }

    /// F22's master switch: whether the app lives in the menu bar with no
    /// main window (Settings > Compact mode).
    ///
    /// Off by default, and for a different reason from the opt-ins above -
    /// nothing here downloads, calls the network or installs a keyboard
    /// monitor. It is off because it *hides the main window*, and a fresh
    /// install whose window never appeared would read as a launch failure.
    /// See `CompactModePolicy` for everything that follows from it.
    var compactModeEnabled: Bool {
        get { defaults.bool(forKey: Keys.compactModeEnabled) }
        set { defaults.set(newValue, forKey: Keys.compactModeEnabled) }
    }

    /// Whether compact mode also drops the Dock icon (`.accessory`, which is
    /// `LSUIElement` at runtime).
    ///
    /// Read only through `CompactModePolicy.activationPolicy`, which gates it
    /// on `compactModeEnabled` - so this can never leave a captain with a
    /// window and no Dock icon to raise it from.
    var compactModeHidesDockIcon: Bool {
        get { defaults.bool(forKey: Keys.compactModeHidesDockIcon) }
        set { defaults.set(newValue, forKey: Keys.compactModeHidesDockIcon) }
    }

    /// Whether the compact status item carries the overdue count as a title.
    ///
    /// Off by default, and the reviewed F22 mockup states the reason as part
    /// of the design rather than as caution: a permanent red number is a bad
    /// neighbour in a menu bar. The count is one click away either way.
    var compactModeBadgesOverdueCount: Bool {
        get { defaults.bool(forKey: Keys.compactModeBadgesOverdueCount) }
        set { defaults.set(newValue, forKey: Keys.compactModeBadgesOverdueCount) }
    }

    /// **UX issue X2 of the 2026-09-27 review.** Whether Tasks, the crew
    /// and Poneglyph each keep a status item of their own, instead of being
    /// reached through the one merged item's tabs.
    ///
    /// > `CompactMode`, `PoneglyphMenuBar`, `ShiftMenuBar` and
    /// > `StrawHatMenuBar` each create an `NSStatusItem`; the probe put
    /// > three in the menu bar at once.
    ///
    /// **Off by default, which is the change.** The merging already existed
    /// - F22's popover hosts Poneglyph's and the crew's own controllers as
    /// two of its four tabs - but it was reachable only by turning compact
    /// *mode* on, and that also hides the main window. So a captain who just
    /// wanted one icon had to accept a windowless app, and nobody did, and
    /// the menu bar carried three.
    ///
    /// The merged item is now independent of the mode: one "Grand Line" item
    /// with four tabs, always, and this switch is the way back to the old
    /// three for anyone who preferred them.
    ///
    /// Stored inverted - see `Keys.menuBarSeparateItems`.
    var menuBarSeparateItems: Bool {
        get { defaults.bool(forKey: Keys.menuBarSeparateItems) }
        set { defaults.set(newValue, forKey: Keys.menuBarSeparateItems) }
    }

    /// `fm/grandline-settings-page-redesign`: whether the app switches
    /// between `systemLightThemeID` and `systemDarkThemeID` when macOS
    /// switches between light and dark.
    ///
    /// **On for a fresh install, off for a captain who has already picked a
    /// palette** (X10 of the review). The two halves of that are the same
    /// rule, not a compromise:
    ///
    ///   - The review's point is that most people expect an app shipping
    ///     thirteen light/dark pairs to follow the system, and a fresh
    ///     install has expressed no preference to override.
    ///   - The reason this used to be off unconditionally still holds
    ///     exactly where it applied: a captain who has chosen one of the
    ///     twenty-six palettes has expressed a preference for *that palette*,
    ///     not for a mode, and turning this on for them would silently
    ///     discard their stored `fm.themeID` the first time the sun set -
    ///     the same "overriding a stored preference" defect
    ///     `ThemeManager.fallbackTheme`'s own note refuses to commit in the
    ///     other direction.
    ///
    /// So the default is read from `ThemeManager.hasStoredThemeChoice`, and
    /// **materialised on the first read**. That write is deliberate and is
    /// what makes the rule stable: `SystemAppearanceFollower` itself stores
    /// `fm.themeID` the first time it switches, so a default re-derived on
    /// every read would answer "on" at launch and "off" an hour later. The
    /// first read happens in `SystemAppearanceFollower.start()` at launch,
    /// before anything can have moved that key.
    ///
    /// `SystemAppearanceFollower` is the only reader.
    var followSystemAppearance: Bool {
        get {
            if let stored = defaults.object(forKey: Keys.followSystemAppearance) as? Bool {
                return stored
            }
            let fresh = !ThemeManager.hasStoredThemeChoice
            defaults.set(fresh, forKey: Keys.followSystemAppearance)
            return fresh
        }
        set { defaults.set(newValue, forKey: Keys.followSystemAppearance) }
    }

    /// The light half of the pair `followSystemAppearance` switches between.
    ///
    /// Defaults to the app's own light theme rather than to the *active*
    /// theme, so the stored pair is a real pair from the first read - a
    /// default of "whatever is selected right now" would let a captain who
    /// switched this on while in Dusk end up with a dark theme in the light
    /// slot, which `SystemAppearanceFollower.resolvedTheme` would then have
    /// to correct behind their back.
    var systemLightThemeID: String {
        get { defaults.string(forKey: Keys.systemLightThemeID) ?? HelmTheme.light.id }
        set { defaults.set(newValue, forKey: Keys.systemLightThemeID) }
    }

    /// The dark half. Defaults to `ThemeManager.fallbackTheme`, which is the
    /// palette a fresh install already opens on.
    var systemDarkThemeID: String {
        get { defaults.string(forKey: Keys.systemDarkThemeID) ?? ThemeManager.fallbackTheme.id }
        set { defaults.set(newValue, forKey: Keys.systemDarkThemeID) }
    }

    /// Dictation's "Use local Whisper engine" toggle
    /// (fm/grandline-dictation-whisper-engine) - when on AND the large-v3-
    /// turbo model has been downloaded AND it loads successfully, dictation
    /// runs through the vendored whisper.cpp engine instead of the Apple
    /// Speech framework. Off by default: the model is a real ~547MB download
    /// that has to happen explicitly, unlike the rest of Dictation, which
    /// works immediately after a fresh install with no extra setup.
    var dictationLocalWhisperEnabled: Bool {
        get { defaults.bool(forKey: Keys.dictationLocalWhisperEnabled) }
        set { defaults.set(newValue, forKey: Keys.dictationLocalWhisperEnabled) }
    }

    /// F12's "Morning briefing" toggle (Settings > Morning briefing). Off by
    /// default, and section 25's F12 entry is explicit about that being part
    /// of the design rather than caution: the briefing makes one `claude -p`
    /// call per day, which needs network access and the captain's own `claude`
    /// authentication, and it costs quota. Nothing about the card exists until
    /// this is switched on - see `FleetController.refreshMorningBriefing`,
    /// which returns before reading any input when this is false.
    var morningBriefingEnabled: Bool {
        get { defaults.bool(forKey: Keys.morningBriefingEnabled) }
        set { defaults.set(newValue, forKey: Keys.morningBriefingEnabled) }
    }

    /// The most recently generated briefing, JSON-encoded - the same
    /// "one cohesive value, always read and written as a unit" reasoning as
    /// `dictationShortcut` above, rather than five flat keys.
    ///
    /// Persisting it (rather than keeping it in memory for the session) is what
    /// makes "once per day" behave the way a captain expects across a
    /// relaunch: a briefing generated at 07:00 is still the one on screen after
    /// a restart at 11:00, and the AI call is not made a second time. It holds
    /// only the app's own already-displayed derived state - the same counts
    /// Overview, Review, Tasks, GitHub Sync and the quota popover already show.
    var morningBriefingRecord: MorningBriefingRecord? {
        get {
            guard let data = defaults.data(forKey: Keys.morningBriefingRecord),
                  let decoded = try? JSONDecoder().decode(MorningBriefingRecord.self, from: data) else {
                return nil
            }
            // Applied on read rather than in a migration: the record is the
            // day's briefing and is not regenerated until tomorrow, so a
            // record written before the quota clause was removed would
            // otherwise keep rendering it for the rest of today. See
            // `MorningBriefing.withoutQuotaClauses`.
            return MorningBriefing.withoutQuotaClauses(decoded)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.morningBriefingRecord)
                return
            }
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.morningBriefingRecord)
        }
    }

    /// Guards the one-time seed of the "daily-github-sync" schedule
    /// (`ScheduledActionKind.forkSync`, daily at 11:10 AM local time) - see
    /// `ScheduleSeeding.seedDailyGitHubSyncIfNeeded` and its call site in
    /// `main.swift`. Seeded exactly once: flipping this to `true` right after
    /// adding the schedule is what lets a captain later edit or delete it
    /// without it being silently re-added on the next launch - the same
    /// "seed once, never resurrect" contract `CommandLibraryStore.
    /// seedIfEmpty()` follows for its own starter catalog.
    var didSeedDailyGitHubSyncSchedule: Bool {
        get { defaults.bool(forKey: Keys.didSeedDailyGitHubSyncSchedule) }
        set { defaults.set(newValue, forKey: Keys.didSeedDailyGitHubSyncSchedule) }
    }

    /// F2 (audit §2 item 1): where the captain was at quit - the showing
    /// destination, the shared Console's and Tools' open tabs, and which
    /// hosts had a dedicated page. JSON-encoded, on the same "one cohesive
    /// value, always read and written as a unit" reasoning as
    /// `dictationShortcut`/`morningBriefingRecord` above rather than five
    /// flat keys.
    ///
    /// See `SessionRestore.swift` for exactly what is and is not restored,
    /// and why a host page comes back without connecting until it is opened.
    /// Full review #3's S3: the bytes live in a 0600 file now, not in the
    /// preferences plist. This stays the accessor every caller uses -
    /// `SessionRestoreStore` owns where it is written, and reads migrate an
    /// older build's `UserDefaults` copy across on first use. See that file's
    /// header for what the move is and is not worth.
    var sessionRestoreState: SessionRestoreState? {
        get { SessionRestoreStore.load(defaults: defaults) }
        set { SessionRestoreStore.save(newValue) }
    }

    /// Review #3's UX13: whether the first-run welcome sheet has been shown.
    ///
    /// Set when the sheet closes by any route, including Skip - a captain who
    /// dismissed it has decided, and re-asking on the next launch would be the
    /// app overruling them.
    ///
    /// Defaults to `false`, which means an existing captain sees it once after
    /// upgrading. That is deliberate rather than an oversight: half of what it
    /// says is about things this batch just added (the all-destinations map,
    /// the configurable bar), so it is a genuine what-is-new for them too.
    var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: Keys.hasSeenWelcome) }
        set { defaults.set(newValue, forKey: Keys.hasSeenWelcome) }
    }

    /// Review #3's UX1/UX2: which destinations the floating bar's shortcut row
    /// carries, and in what order - see `QuickAccessConfiguration`.
    ///
    /// JSON-encoded, on the same "one cohesive value, always read and written
    /// as a unit" reasoning as `dictationShortcut`/`morningBriefingRecord`
    /// above. An absent or undecodable value resolves to the seven shortcuts
    /// the bar shipped with, so a captain who never touches this - and a
    /// captain whose stored value this build cannot read - sees the bar they
    /// already had rather than an empty one.
    var quickAccess: QuickAccessConfiguration {
        get {
            guard let data = defaults.data(forKey: Keys.quickAccess),
                  let decoded = try? JSONDecoder().decode(QuickAccessConfiguration.self, from: data) else {
                return QuickAccessConfiguration()
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.quickAccess)
        }
    }

    /// Which shell the main window hosts - the floating bar or the sidebar
    /// (stage 3 of the modular-shell migration). Settings > Appearance writes
    /// it, and the app delegate reads it **once**, when it builds the window,
    /// so a change applies the next time the app opens: the two shells draw
    /// different window chrome (a hidden title bar against a system toolbar),
    /// and swapping that under a running window is not something either
    /// shell is built to survive.
    ///
    /// `WorkspaceLayout.standard` (the sidebar) until the captain picks
    /// otherwise, and for any value this build does not recognise - an
    /// unknown layout must never leave the app without a shell. A stored
    /// choice is kept as it is, so a captain who picked the floating bar
    /// still gets it.
    var workspaceLayout: WorkspaceLayout {
        get { defaults.string(forKey: Keys.workspaceLayout).flatMap(WorkspaceLayout.init(rawValue:)) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: Keys.workspaceLayout) }
    }

    /// Home's cards as the captain arranged them in the sidebar layout (stage
    /// 4): which ones Home's own space shows, in what order and at what size.
    /// Home's own set until the captain changes it, and again for a value that
    /// does not read - a preference that cannot be read is not worth more
    /// than the default it replaces.
    var homeCardLayout: HomeCardLayout {
        get {
            defaults.data(forKey: Keys.homeCardLayout).flatMap(HomeCardLayout.init(storedData:))
                ?? .standard(for: workspaceProfile ?? .operator)
        }
        set {
            guard let data = newValue.storedData else { return }
            defaults.set(data, forKey: Keys.homeCardLayout)
        }
    }

    /// R2-UX-01: whether Grand Line asks for its password when it opens, and
    /// again after the idle and session thresholds. `nil` means nothing has
    /// decided yet.
    ///
    /// The lock is an opt-in from Settings > Security now. A fresh install
    /// opens straight to Home (`settleFirstLaunch` writes `false` for it),
    /// so a general user's first launch is never gated on Automic Vault, a
    /// terminal command and a relaunch. An install from before this setting
    /// existed keeps exactly the lock it had: it reads `nil` here, its launch
    /// is locked as before, and the lock screen's own check settles it -
    /// `true` when the password is configured, `false` only when it is
    /// confirmed not to be (`AppLockMigration`). An unanswered check never
    /// settles anything, so it can never turn a protection off.
    var appLockEnabled: Bool? {
        get { defaults.object(forKey: Keys.appLockEnabled) == nil ? nil : defaults.bool(forKey: Keys.appLockEnabled) }
        set {
            if let newValue { defaults.set(newValue, forKey: Keys.appLockEnabled) } else {
                defaults.removeObject(forKey: Keys.appLockEnabled)
            }
            NotificationCenter.default.post(name: AppSettings.appLockPreferenceDidChange, object: self)
        }
    }

    static let appLockPreferenceDidChange = Notification.Name("fm.appLockPreferenceDidChange")

    /// R2-UX-08: how long the Mac may sit idle, and how long one unlocked
    /// session may run, before the lock screen comes back. Nil is the
    /// default. `AppLockController.configuredThresholds` clamps whatever is
    /// stored here to its own bounds, and an `FM_APP_LOCK_*` override still
    /// wins over both.
    var appLockIdleSeconds: TimeInterval? {
        get { defaults.object(forKey: Keys.appLockIdleSeconds) == nil ? nil : defaults.double(forKey: Keys.appLockIdleSeconds) }
        set {
            if let newValue { defaults.set(newValue, forKey: Keys.appLockIdleSeconds) } else {
                defaults.removeObject(forKey: Keys.appLockIdleSeconds)
            }
        }
    }

    var appLockSessionSeconds: TimeInterval? {
        get { defaults.object(forKey: Keys.appLockSessionSeconds) == nil ? nil : defaults.double(forKey: Keys.appLockSessionSeconds) }
        set {
            if let newValue { defaults.set(newValue, forKey: Keys.appLockSessionSeconds) } else {
                defaults.removeObject(forKey: Keys.appLockSessionSeconds)
            }
        }
    }

    /// R2-UX-01: whether this launch is the first one on this Mac. Read once,
    /// by `settleFirstLaunch`, before anything this launch writes: an install
    /// that has ever stored a preference (every key this app owns starts
    /// `fm.`), or that has a data folder with anything in it, is an existing
    /// install and keeps what it had.
    func isExistingInstall(dataRoot: URL = AppPaths.dataRoot()) -> Bool {
        if defaults.dictionaryRepresentation().keys.contains(where: { $0.hasPrefix("fm.") }) { return true }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dataRoot.path)) ?? []
        return contents.contains { !$0.hasPrefix(".") }
    }

    /// R2-UX-01: the decisions a first launch makes, written once so a later
    /// launch reads them rather than guessing again. Runs before anything
    /// else in `applicationDidFinishLaunching`.
    ///
    /// - A fresh install opens unlocked; an existing one is left undecided so
    ///   its lock screen settles it (see `appLockEnabled`).
    /// - A fresh install starts on the Personal profile, which the welcome
    ///   sheet offers to change; an existing one is Operator, so every module
    ///   it had stays in its sidebar.
    func settleFirstLaunch(isExistingInstall existing: Bool) {
        if appLockEnabled == nil, !existing { appLockEnabled = false }
        if workspaceProfile == nil { setProfile(existing ? .operator : .personal) }
    }

    /// R2-UX-01 (b): the profile the sidebar started from (`WorkspaceProfile`).
    /// `nil` only before `settleFirstLaunch` - and in a self-test or tour
    /// process, which never runs it, so those see every module.
    var workspaceProfile: WorkspaceProfile? {
        defaults.string(forKey: Keys.workspaceProfile).flatMap(WorkspaceProfile.init(rawValue:))
    }

    /// Choose a profile: its hidden set replaces the current one.
    func setProfile(_ profile: WorkspaceProfile) {
        defaults.set(profile.rawValue, forKey: Keys.workspaceProfile)
        hiddenModules = profile.hiddenModules
    }

    /// R2-UX-01 (b): the modules the sidebar layout leaves out of its sidebar,
    /// its Go menu, the ⌘K palette and Home's default cards. Stored as module
    /// ids; an id this build does not know is dropped on read, and Home and
    /// Settings can never be hidden. With nothing stored it is the profile's
    /// set, and with no profile, none.
    var hiddenModules: Set<WorkspaceModule> {
        get {
            guard let stored = defaults.stringArray(forKey: Keys.hiddenModules) else {
                return workspaceProfile?.hiddenModules ?? []
            }
            return Set(stored.compactMap(WorkspaceModule.init(rawValue:)).filter(\.canBeHidden))
        }
        set {
            defaults.set(newValue.filter(\.canBeHidden).map(\.rawValue).sorted(), forKey: Keys.hiddenModules)
            NotificationCenter.default.post(name: AppSettings.hiddenModulesDidChange, object: self)
        }
    }

    static let hiddenModulesDidChange = Notification.Name("fm.hiddenModulesDidChange")

    /// U-03: the sidebar's width as the captain last dragged it, in the
    /// sidebar layout. `nil` until they drag it; the shell clamps whatever it
    /// reads to its own range, so a stored width from another build or a
    /// hand-edited plist can never open the sidebar outside it.
    var sidebarWidth: CGFloat? {
        get { defaults.object(forKey: Keys.sidebarWidth) == nil ? nil : CGFloat(defaults.double(forKey: Keys.sidebarWidth)) }
        set {
            if let newValue { defaults.set(Double(newValue), forKey: Keys.sidebarWidth) } else {
                defaults.removeObject(forKey: Keys.sidebarWidth)
            }
        }
    }

    /// R2-ARCH-06: the sidebar layout's toolbar as the captain customised it -
    /// the identifiers of its customisable items, in order - or `nil` for the
    /// shipped default. Kept here, in `AppDefaults.store`, rather than by
    /// `NSToolbar.autosavesConfiguration`, which writes `UserDefaults.standard`
    /// under a key of its own. `WorkspaceToolbar` drops any identifier it
    /// does not know when it reads this, so another build's items cannot
    /// break the toolbar.
    var workspaceToolbarItems: [String]? {
        get { defaults.stringArray(forKey: Keys.workspaceToolbarItems) }
        set {
            if let newValue { defaults.set(newValue, forKey: Keys.workspaceToolbarItems) } else {
                defaults.removeObject(forKey: Keys.workspaceToolbarItems)
            }
        }
    }

    /// R2-ARCH-06: the toolbar's display mode from the same customisation
    /// sheet (`NSToolbar.DisplayMode`'s raw value), or `nil` for icons only.
    var workspaceToolbarDisplayMode: Int? {
        get { defaults.object(forKey: Keys.workspaceToolbarDisplayMode) == nil ? nil
                : defaults.integer(forKey: Keys.workspaceToolbarDisplayMode) }
        set {
            if let newValue { defaults.set(newValue, forKey: Keys.workspaceToolbarDisplayMode) } else {
                defaults.removeObject(forKey: Keys.workspaceToolbarDisplayMode)
            }
        }
    }
}
