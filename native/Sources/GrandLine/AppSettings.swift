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
        static let fmHome = "fm.fmHome"
        static let dictationShortcut = "fm.dictationShortcut"
        static let quickCaptureShortcut = "fm.quickCaptureShortcut"
        static let dictationCleanupEnabled = "fm.dictationCleanupEnabled"
        static let dictationLocalWhisperEnabled = "fm.dictationLocalWhisperEnabled"
        static let morningBriefingEnabled = "fm.morningBriefingEnabled"
        static let morningBriefingRecord = "fm.morningBriefingRecord"
        static let didSeedDailyGitHubSyncSchedule = "fm.didSeedDailyGitHubSyncSchedule"
        static let terminalShortcuts = "fm.terminalShortcuts"
        static let quickAccess = "fm.quickAccess"
        static let hasSeenWelcome = "fm.hasSeenWelcome"
        static let snippetExpansionEnabled = "fm.snippetExpansionEnabled"
        static let dailyReviewEnabled = "fm.dailyReviewEnabled"
        static let dailyReviewCalendarEnabled = "fm.dailyReviewCalendarEnabled"
        static let googleCalendarEnabled = "fm.googleCalendarEnabled"
        static let dailyReviewDismissedDay = "fm.dailyReviewDismissedDay"
        static let compactModeEnabled = "fm.compactModeEnabled"
        static let compactModeHidesDockIcon = "fm.compactModeHidesDockIcon"
        static let compactModeBadgesOverdueCount = "fm.compactModeBadgesOverdueCount"
        static let followSystemAppearance = "fm.followSystemAppearance"
        static let systemLightThemeID = "fm.systemLightThemeID"
        static let systemDarkThemeID = "fm.systemDarkThemeID"
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
    init(defaults: UserDefaults = .standard) {
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

    /// Settings > Terminal Shortcuts' nine configurable Console bindings
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
    var snippetExpansionEnabled: Bool {
        get { defaults.bool(forKey: Keys.snippetExpansionEnabled) }
        set { defaults.set(newValue, forKey: Keys.snippetExpansionEnabled) }
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

    /// `fm/grandline-settings-page-redesign`: whether the app switches
    /// between `systemLightThemeID` and `systemDarkThemeID` when macOS
    /// switches between light and dark.
    ///
    /// **Off by default, and that is not caution.** A captain who has picked
    /// one of the twenty-six palettes has expressed a preference for that
    /// palette, not for a mode - turning this on by default would silently
    /// discard the stored `fm.themeID` the first time the sun set, which is
    /// the same "overriding a stored preference" defect `ThemeManager.
    /// fallbackTheme`'s own note refuses to commit in the other direction.
    /// Switching it on is what asks for a pair to be honoured instead.
    ///
    /// `SystemAppearanceFollower` is the only reader.
    var followSystemAppearance: Bool {
        get { defaults.bool(forKey: Keys.followSystemAppearance) }
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

    /// F20's "Daily review" card (Settings > Daily review). **On** by
    /// default, and the difference from `morningBriefingEnabled` above is not
    /// an oversight: F12 is off by default because it makes a `claude -p`
    /// call, which costs network, the captain's own Claude authentication and
    /// quota. F20 makes no call at all - it is an in-memory aggregation of
    /// stores this app has already loaded for other pages - so there is
    /// nothing to consent to before it runs. The one part of it that *does*
    /// need consent, the calendar, has its own flag below and is off.
    var dailyReviewEnabled: Bool {
        get { defaults.object(forKey: Keys.dailyReviewEnabled) == nil ? true : defaults.bool(forKey: Keys.dailyReviewEnabled) }
        set { defaults.set(newValue, forKey: Keys.dailyReviewEnabled) }
    }

    /// Whether the daily review may read today's calendar events. Off until
    /// the captain presses the card's own "Show today's calendar", which is
    /// the only thing in this app that asks EventKit for anything - see
    /// `DailyReviewCalendar.swift`'s header. Turning it off does not revoke
    /// the system grant (only System Settings can), it stops this app from
    /// reading.
    var dailyReviewCalendarEnabled: Bool {
        get { defaults.bool(forKey: Keys.dailyReviewCalendarEnabled) }
        set { defaults.set(newValue, forKey: Keys.dailyReviewCalendarEnabled) }
    }

    /// Whether a connected Google account's calendar joins the daily
    /// review's calendar column.
    ///
    /// `fm/grandline-overview-layout-fix-gmail-settings`. Separate from
    /// `dailyReviewCalendarEnabled` on purpose: that one gates the **local**
    /// Mac calendars behind a TCC grant this app has to ask for, and this one
    /// gates a remote source the captain already consented to by signing in.
    /// One flag for both would make turning off EventKit also turn off
    /// Google, which is not what either switch says.
    ///
    /// Off until asked, like its sibling, and useless on its own - a
    /// connected account is the other half.
    var googleCalendarEnabled: Bool {
        get { defaults.bool(forKey: Keys.googleCalendarEnabled) }
        set { defaults.set(newValue, forKey: Keys.googleCalendarEnabled) }
    }

    /// The day key (`MorningBriefing.dayKey`) the daily review was dismissed
    /// on, so the card stays gone for the rest of that day and comes back
    /// tomorrow.
    ///
    /// A day key rather than F12's `dismissed` flag inside a persisted record,
    /// because this card has no record to carry one: its digest is recomputed
    /// from the stores on every appearance (it is cheap, and a stale copy of
    /// "what is due today" would be worse than none), so the dismissal is the
    /// only thing there is to persist.
    var dailyReviewDismissedDay: String? {
        get { defaults.string(forKey: Keys.dailyReviewDismissedDay) }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.dailyReviewDismissedDay)
                return
            }
            defaults.set(newValue, forKey: Keys.dailyReviewDismissedDay)
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
}
