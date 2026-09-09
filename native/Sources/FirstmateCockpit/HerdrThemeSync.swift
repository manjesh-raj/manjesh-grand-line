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
// The real, legitimate fix: herdr's own colours are a real, documented
// config mechanism - `[theme.custom]` in `~/.config/herdr/config.toml`
// (`herdr --default-config` prints a subset of it as commented-out samples).
// Confirmed against the real installed `herdr` (0.8.2, then re-confirmed
// against 0.9.0 for this task), not assumed from an older captured note:
//
//   - `herdr --help` / `herdr config --help`: no CLI flag or `herdr config`
//     subcommand sets a theme colour - `config check`/`config reset-keys`
//     are the only two, both unrelated. `herdr --help` documents exactly one
//     env var, `HERDR_CONFIG_PATH`, which overrides the *file path*, not any
//     individual value.
//   - `[theme.custom]` is a fixed, strictly-validated struct, not an
//     open-ended token map - confirmed live with `herdr config check` (a
//     purely local, read-only, non-lifecycle command: it validates a
//     `HERDR_CONFIG_PATH`-pointed file on disk and touches no session or
//     server) against a scratch config carrying every field name below,
//     which validated clean, and again against one carrying a made-up field
//     name, which was flagged `unknown config key ...; ignoring key`. The
//     exact field set (also confirmed via `strings` on the real binary in
//     the prior task): `accent`, `panel_bg`, `sidebar_bg`, `active_row_bg`,
//     `selection_bg`, `surface0`, `surface1`, `surface_dim`, `overlay0`,
//     `overlay1`, `text`, `subtext0`, `mauve`, `green`, `yellow`, `red`,
//     `blue`, `teal`, `peach`. There is no `selection_fg` - only the
//     selection *wash* is configurable, not the foreground painted over it.
//   - So the only way to change any of it is to edit that one file, which is
//     herdr's own persistent config - not something Grand Line launches
//     herdr with. Per `fm/grand-line-remove-firstmate-mirror`, this app
//     never launches herdr at all any more; the captain runs it by hand
//     inside a `.shell` tab. There is no "at launch" hook to thread a flag
//     or env var through even if one existed.
//
// **`fm/grandline-herdr-reload-on-theme-sync`: live reload is wired up, but
// `fix-herdr-theme-sync-regression-706b` found - and corrected - a mistaken
// belief about what it actually covers, baked into this comment ever since.**
// The original text here claimed `herdr server reload-config` makes "an
// already-running server picks up the new colours immediately, without the
// captain having to restart it or find the `prefix+shift+r` keybinding
// themselves" - naming the very keybinding this call was believed to make
// unnecessary. That claim was never verified against a real herdr server (the
// prior task's own header already says why: the sanctioned `fm-herdr-lab.sh`
// helper categorically refuses every `server ...` command, and the hard
// safety contract separately forbids running one directly even against an
// isolated lab session) - it was inferred from the subcommand's name.
//
// Herdr's own published docs say otherwise, in as many words
// (`docs/configuration.mdx`, "## Reload config", confirmed live against the
// real installed 0.9.0's `--help`/`herdr server --help` output and the
// socket API's own `Raw methods` table, which lists only `client.window_
// title.set`/`client.window_title.clear` under "Client" - nothing theme- or
// reload-shaped): **theme, sidebar and other presentation settings are the
// CLIENT's own local concern - loaded once at the client's own startup - and
// belong to a DIFFERENT reload path than the one this app calls.**
// `herdr server reload-config` (this app's own CLI call, and the only one
// the socket API's `server.reload_config` method backs) reloads only
// SERVER-owned settings - pane defaults, worktrees, integrations, custom
// commands. The captain's own in-app "reload config" action (the global
// menu item, or the `prefix+shift+r` keybinding this comment used to claim
// was made unnecessary) is the one that "reloads both the client's local
// settings and the selected server's config" - and there is no CLI or
// socket-API equivalent of that combined action; `Client`'s own socket
// methods don't include one, and no `herdr api`/`herdr` subcommand exposes
// it either. This app has no reliable way to target which Console tab, if
// any, is running a herdr client at all (`ConsoleController+Herdr.swift`'s
// own doc comment already says so, for the unrelated `herdr server stop`
// restart-button feature) - so there is no safe way to reach the client-side
// half of "reload config" from here, and this app does not attempt to.
//
// What this means in practice, and what the corrected log message below now
// says instead of implying "done": every write this file makes to
// config.toml is durable and immediately correct, and a captain who OPENS A
// NEW `herdr session attach ...` after that write sees the right colours
// right away (a fresh client reads the file at its own startup, no reload
// needed). An ALREADY-OPEN herdr pane's colours do not change until the
// captain reloads config from herdr's OWN interface (its global menu, or
// `prefix+shift+r`) or detaches and reattaches that pane - this app cannot
// do either safely on the captain's behalf. `triggerLiveReload()` below is
// kept (it is harmless, and genuinely reloads whatever settings the running
// server itself owns) but is no longer described, in comments or in its own
// log line, as solving "the panel updates with no captain action needed" -
// it never did.
//
// `herdr server reload-config` takes no flags of its own and exposes no
// machine-parseable result on the CLI surface (confirmed via `strings` and
// `herdr api schema --json`); only the process's own exit status is a
// reliable signal from outside, and "no server running" is detected
// client-side and exits non-zero, which this treats like any other
// unsuccessful reload (log it, never crash, never block the already-durable
// config write on it).
//
// **`fix-herdr-panel-follows-grandline-theme`: the sync now covers herdr's
// WHOLE colour set, not only `selection_bg`.** The captain reported that the
// herdr session tab's embedded terminal panel always rendered dark
// regardless of Grand Line's own light/dark theme toggle - which was
// working exactly as designed up to this point: every field above except
// `selection_bg` was left as whatever herdr's own generated config already
// held (or its own built-in default), since the original two tasks
// deliberately scoped themselves to "the text-selection wash follows the
// theme", not "the whole panel follows the theme". This task widens the
// same, already-legitimate mechanism to the full field set so the answer to
// "why is the panel always dark" becomes "it now isn't" rather than "that
// was out of scope".
//
// Mapping (see `HerdrThemeColors.derive(from:)` for the exact maths) -
// operating entirely on `HelmTheme`'s own already-resolved base fields
// (`chromeBackgroundHex`/`chromeInkHex`/`backgroundHex`/`accentHex`/
// `ansiHex`), which resolve correctly for Daylight/Dusk too
// (`HelmDaylight.swift`'s `.daylight`/`.dusk` populate those same base
// fields from `DaylightPalette`/`DaylightTokens`), so no theme needs special
// handling here:
//
//   - `panel_bg` (the main content pane - literally "the actual embedded
//     herdr terminal" the captain's report names) -> `backgroundHex`, Grand
//     Line's own terminal-background token; `sidebar_bg` (the surrounding
//     structural chrome) -> `chromeBackgroundHex`, the token this app
//     already uses for exactly "the window/chrome colours so the AppKit
//     shell around the terminal matches". These two tokens are already
//     Grand Line's own established "content vs. chrome" pair.
//   - `selection_bg`/`accent` -> `accentHex` (unchanged target value from
//     the prior task; `accentHex == selectionHex` in every shipped palette,
//     confirmed by inspection of `HelmTheme.swift`).
//   - `active_row_bg` (the highlighted row in herdr's own sidebar) -> a 20%
//     wash of `accentHex` over `chromeBackgroundHex` - the same "accent wash
//     behind a selected row" recipe `HelmAccentRow.isRowSelected`'s own
//     `selectionWash` (0.20) already uses throughout this app for exactly
//     "this row is the current one".
//   - `surface0`/`surface1`/`surface_dim`/`overlay0`/`overlay1` (background
//     fills with no 1:1 token) -> a deliberate ladder of `HelmContrast.mix`
//     blends toward `chromeInkHex`/`backgroundHex`, distinct-but-related as
//     the task calls for, rather than all collapsing onto one hex:
//     `surface_dim` (least elevated, closest to `panel_bg`) sits mostly
//     toward `backgroundHex`; `surface0`/`surface1` nudge `chromeBackgroundHex`
//     8%/16% toward ink, mirroring `HelmField.fill`'s own established "8%
//     toward ink" sunken-surface recipe; `overlay0`/`overlay1` sit further
//     up the same ink ladder (45%/65%), between the surfaces and `subtext0`.
//   - `subtext0` (Catppuccin's own "muted secondary text" role) -> this
//     app's one muted/secondary-ink derivation, `HelmTheme.mutedInk`,
//     flattened to a solid hex the way it renders once composited over
//     `chromeBackgroundHex` (one of the two surfaces its own alpha is
//     bisected against) - rather than inventing a second muted-text
//     formula.
//   - `text` -> now genuinely synced, reversing the prior task's deliberate
//     omission. That omission was about `selectionTextHex` specifically (a
//     narrow-purpose colour calibrated only against an opaque accent fill,
//     wrong for a whole-UI foreground); `chromeInkHex` is the correct,
//     general-purpose token for exactly this job - "the ink used for the
//     AppKit shell text" - and the whole point of this task is that the
//     panel's foreground, not only its background, should follow the theme.
//   - `mauve`/`green`/`yellow`/`red`/`blue`/`teal` (herdr's own accent/
//     status vocabulary - `mauve`/`teal`/`peach` are Catppuccin's own hue
//     names, the rest ordinary ANSI names) -> the theme's own NORMAL (not
//     "bright") `ansiHex` slots for magenta/green/yellow/red/blue/cyan.
//     Those slots are already each hue's own text-corrected variant for the
//     theme's own background (the design report's own words: "an ANSI
//     slot's job is precisely 'this hue used as text on the theme's own
//     background'"), which is exactly how herdr paints these - as coloured
//     label/status text, not raw terminal escape output.
//   - `peach` (orange) has no ANSI slot; synthesised as an even mix of the
//     theme's own red and yellow ansi hues.
//   - Every one of `text`/`mauve`/`green`/`yellow`/`red`/`blue`/`teal`/
//     `peach` is then re-checked with `HelmContrast.legible` against
//     whichever of `panel_bg`/`sidebar_bg` is the WORSE surface for it -
//     mirroring `HelmContrast.tintedSurface`'s own "score every candidate
//     surface and satisfy the worst" rule - since herdr paints this single
//     colour across its whole UI, on top of every surface this sync sets,
//     and (per this app's own established finding) a mix of two
//     individually-legible hues (`peach`) is not itself guaranteed to clear
//     the floor.
//
// Not touched, deliberately: `[theme.custom.light]`/`[theme.custom.dark]`
// (herdr 0.9.0's `auto_switch` appearance-specific overrides - a materially
// different feature, "follow the HOST TERMINAL's own light/dark", orthogonal
// to Grand Line's own theme; the captain's real config has no `[theme]`
// section at all, i.e. isn't using it, and `HerdrConfigPatcher`'s own
// `currentPath == ["theme", "custom"]` guard already protects those
// sub-tables from ever being mistaken for the base table this sync manages).
//
// Every live herdr lifecycle probe this task needed (would `herdr server
// reload-config` still behave correctly against the expanded field set) had
// to go through the same isolation constraints the prior task hit: the
// sanctioned `fm-herdr-lab.sh run` helper categorically refuses any command
// whose first word is `server`, with no reload-specific carve-out, and the
// task's own hard safety contract separately forbids running that command
// directly even against an isolated lab session. So the reload trigger
// itself (`triggerLiveReload`, unchanged by this task) is exercised only
// against a disposable fake `herdr` script (`herdrExecutablePathOverrideForTests`),
// exactly as the prior task left it - this task did not attempt to re-open
// that gap, since nothing about the argv/timeout/success/failure handling
// changed here.
//
// The captain's own `~/.config/herdr/config.toml` is real, hand-maintained
// state (this machine's copy has a `[keys]` table with custom bindings and
// no `[theme]` section at all) - `HerdrConfigPatcher` below is a careful,
// line-level surgical patch of exactly the fields it manages, never a
// rewrite of the whole file, and refuses to touch anything it is not
// confident it understands (see that type's own header for the exact
// guarantees and what it deliberately does not attempt to parse).
//
// **`fix-herdr-theme-sync-regression-706b`: re-investigated a captain report
// of the same visual symptom reappearing on a later rebuild - the write path
// was never the problem.** Verified live against the captain's real,
// unmodified `~/.config/herdr/config.toml`: it already held the full 19-field
// shape (not the old narrow `selection_bg`-only one), every value matched
// `HerdrThemeColors.derive(from: .catppuccinMocha)`'s own computed output
// exactly (checked by hand for `active_row_bg`'s mix maths), `herdr config
// check` validated it clean, and `herdr --version` still reported 0.9.0 - the
// same version the field-widening task verified against, so no herdr update
// silently changed the schema either. The real unified log (`log show
// --predicate 'process == "FirstmateCockpit"' --info`, filtered for the app's
// real launched PID rather than the many `fake-herdr-*.sh` self-test-suite
// entries that otherwise dominate it on this shared dev machine) showed a
// real, very recent app launch genuinely writing correct colours for BOTH
// directions of a real theme toggle and genuinely succeeding at `server
// reload-config` both times - so the write mechanism and the reload dispatch
// were both already working exactly as designed. What was wrong was the
// design's own understanding of what a successful `server reload-config`
// call actually accomplishes - see the correction above and in
// `triggerLiveReload`'s own doc comment. A real screenshot of the captain's
// actual running herdr pane (captured via `screencapture`, never via
// simulated clicks into the live pane itself - a stray `System Events`
// UI-scripting click sequence used to *navigate Grand Line's own chrome* to
// reach that screenshot triggered an unrelated macOS screen-lock, at which
// point all further GUI interaction was abandoned rather than risk touching
// the captain's real session or lock screen) showed colours consistent with
// the currently-active dark theme, which is exactly the "no visible error,
// nothing looks wrong at rest" signature this bug always had - the gap only
// shows up on a THEME TOGGLE with an already-open herdr pane, which needs
// herdr's own client-side "reload config" to actually repaint.

import AppKit

/// The full field set herdr deserializes `[theme.custom]` into (see this
/// file's header for how the exact set was confirmed) - one solid `"#rrggbb"`
/// hex value per field, always fully populated by `derive(from:)` below, so
/// `HerdrConfigPatcher` always writes the whole table rather than leaving
/// some fields at whatever herdr's own default or an earlier partial sync
/// left them.
struct HerdrThemeColors: Equatable {
    let panelBg: String
    let sidebarBg: String
    let activeRowBg: String
    let selectionBg: String
    let accent: String
    let surface0: String
    let surface1: String
    let surfaceDim: String
    let overlay0: String
    let overlay1: String
    let text: String
    let subtext0: String
    let mauve: String
    let green: String
    let yellow: String
    let red: String
    let blue: String
    let teal: String
    let peach: String
}

extension HerdrThemeColors {
    /// Maps `theme`'s own tokens onto herdr's colour vocabulary - see this
    /// file's header for the full per-field reasoning. Every value here is
    /// derived from `HelmTheme`'s own already-resolved fields (which resolve
    /// correctly under Daylight/Dusk too), never a literal hex, so a new
    /// theme or a retuned palette is picked up automatically with no change
    /// needed here.
    static func derive(from theme: HelmTheme) -> HerdrThemeColors {
        func hexToken(_ raw: String) -> String { "#" + raw.lowercased() }
        func hex(_ rgb: (Double, Double, Double)) -> String {
            func byte(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
            return String(format: "#%02x%02x%02x", byte(rgb.0), byte(rgb.1), byte(rgb.2))
        }

        let inkColor = HelmTheme.nsColor(theme.chromeInkHex)
        let chromeColor = HelmTheme.nsColor(theme.chromeBackgroundHex)
        let backgroundColor = HelmTheme.nsColor(theme.backgroundHex)
        let accentColor = HelmTheme.nsColor(theme.accentHex)

        let ink = HelmContrast.components(inkColor)
        let chrome = HelmContrast.components(chromeColor)
        let background = HelmContrast.components(backgroundColor)
        let accent = HelmContrast.components(accentColor)

        func mixHex(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> String {
            hex(HelmContrast.mix(a, b, t))
        }

        // herdr paints `text` and each of its named accent hues across BOTH
        // surfaces this sync sets - sidebar_bg (chromeBackgroundHex) and
        // panel_bg (backgroundHex) - so each is checked against whichever of
        // the two is the worse surface for it, mirroring
        // `HelmContrast.tintedSurface`'s own "score every candidate surface
        // and satisfy the worst" rule.
        let surfaces = [chromeColor, backgroundColor]
        func legibleEverywhere(_ base: NSColor) -> String {
            let worst = surfaces.min { HelmContrast.ratio(base, $0) < HelmContrast.ratio(base, $1) } ?? chromeColor
            return hex(HelmContrast.components(HelmContrast.legible(base, over: worst)))
        }

        // "peach" (orange) has no ANSI slot; synthesised as an even mix of
        // the theme's own red and yellow, then legibility-checked the same
        // way as every other text-bearing field - a mix of two individually
        // -legible hues is not itself guaranteed to clear the floor.
        let peachRaw = HelmContrast.color(HelmContrast.mix(
            HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[1])),
            HelmContrast.components(HelmTheme.nsColor(theme.ansiHex[3])), 0.5))

        let subtext0: String = theme.isDaylight
            ? hexToken(theme.daylightTokens.muted)
            : mixHex(ink, chrome, Double(HelmTheme.mutedAlpha(for: theme)))

        return HerdrThemeColors(
            panelBg: hexToken(theme.backgroundHex),
            sidebarBg: hexToken(theme.chromeBackgroundHex),
            // A wash of the theme's own accent over the sidebar surface -
            // `HelmAccentRow.isRowSelected`'s own `selectionWash` (0.20).
            activeRowBg: mixHex(accent, chrome, 0.20),
            selectionBg: hexToken(theme.accentHex),
            accent: hexToken(theme.accentHex),
            // A short "surface ladder" distinguishing the background roles
            // from one another (the task's own instruction: fields with no
            // obvious 1:1 token need "sensible distinct-but-related values,
            // not all mapped to the same background hex"). surface_dim sits
            // mostly toward panel_bg (the least elevated of the four);
            // surface0/1 step progressively toward ink off sidebar_bg, the
            // same magnitude `HelmField.fill` nudges a sunken field's fill
            // toward ink (8%); overlay0/1 continue the same ink ladder
            // further, between the surfaces and `subtext0`.
            surface0: mixHex(ink, chrome, 0.08),
            surface1: mixHex(ink, chrome, 0.16),
            surfaceDim: mixHex(background, chrome, 0.65),
            overlay0: mixHex(ink, chrome, 0.45),
            overlay1: mixHex(ink, chrome, 0.65),
            text: legibleEverywhere(inkColor),
            subtext0: subtext0,
            mauve: legibleEverywhere(HelmTheme.nsColor(theme.ansiHex[5])),  // magenta
            green: legibleEverywhere(HelmTheme.nsColor(theme.ansiHex[2])),
            yellow: legibleEverywhere(HelmTheme.nsColor(theme.ansiHex[3])),
            red: legibleEverywhere(HelmTheme.nsColor(theme.ansiHex[1])),
            blue: legibleEverywhere(HelmTheme.nsColor(theme.ansiHex[4])),
            teal: legibleEverywhere(HelmTheme.nsColor(theme.ansiHex[6])),  // cyan
            peach: legibleEverywhere(peachRaw)
        )
    }
}

/// Pure logic: no file I/O, no `Process`, no `ThemeManager`. Everything here
/// is a plain `String -> String?` transform, which is what makes it testable
/// with nothing more than literal fixtures (`HerdrThemeSyncSelfTest.swift`).
enum HerdrConfigPatcher {

    struct PatchResult: Equatable {
        /// The full, patched file content.
        let content: String
        /// `false` when the file already held every one of `Field`'s target
        /// values - the caller should skip the write rather than touch the
        /// file's mtime for no reason (`ThemeManager.reapplyCurrentTheme()`
        /// re-fires every observer on a plain font-scale change, not just a
        /// real theme switch, so this keeps a no-op re-fire from becoming a
        /// disk write).
        let changed: Bool
    }

    /// One recognised TOML key inside `[theme.custom]`, mapped to the
    /// corresponding `HerdrThemeColors` field. `CaseIterable`'s declaration
    /// order is the order this patcher writes a brand-new `[theme.custom]`
    /// table in - herdr's own confirmed field order (this file's header).
    enum Field: String, CaseIterable {
        case accent
        case panelBg = "panel_bg"
        case sidebarBg = "sidebar_bg"
        case activeRowBg = "active_row_bg"
        case selectionBg = "selection_bg"
        case surface0
        case surface1
        case surfaceDim = "surface_dim"
        case overlay0
        case overlay1
        case text
        case subtext0
        case mauve
        case green
        case yellow
        case red
        case blue
        case teal
        case peach

        var tomlKey: String { rawValue }

        func value(in colors: HerdrThemeColors) -> String {
            switch self {
            case .accent: return colors.accent
            case .panelBg: return colors.panelBg
            case .sidebarBg: return colors.sidebarBg
            case .activeRowBg: return colors.activeRowBg
            case .selectionBg: return colors.selectionBg
            case .surface0: return colors.surface0
            case .surface1: return colors.surface1
            case .surfaceDim: return colors.surfaceDim
            case .overlay0: return colors.overlay0
            case .overlay1: return colors.overlay1
            case .text: return colors.text
            case .subtext0: return colors.subtext0
            case .mauve: return colors.mauve
            case .green: return colors.green
            case .yellow: return colors.yellow
            case .red: return colors.red
            case .blue: return colors.blue
            case .teal: return colors.teal
            case .peach: return colors.peach
            }
        }
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
    ///     contain literal text that looks like a table header or one of
    ///     `Field`'s assignments, and this scanner has no notion of "inside
    ///     a string" to protect against misreading it. herdr's own config
    ///     never uses one (checked against `--default-config`).
    ///   - A dotted-key assignment starting with `theme` outside of a
    ///     `[section]` header (`theme.custom.selection_bg = "..."` or
    ///     `theme = { custom = { ... } }`) - legal TOML this scanner has no
    ///     way to reconcile against a `[theme.custom]` header it might also
    ///     add, which could produce a file with the same table declared
    ///     twice (invalid TOML). herdr's own generated config only ever uses
    ///     `[section]` headers.
    ///   - More than one `[theme.custom]` header, or more than one live
    ///     (uncommented) occurrence of any one `Field` inside it - either
    ///     means the file is already in a shape this patcher should not be
    ///     the one to resolve.
    ///   - A live value for a `Field` this scanner recognises that is not a
    ///     single-line, simple quoted string (no escapes) - anything else
    ///     means "I don't recognise this shape", not "let me guess." A key
    ///     inside `[theme.custom]` that isn't one of `Field`'s known names
    ///     is left completely alone, whatever shape its value takes - this
    ///     patcher only ever reasons about the fields it manages.
    static func apply(colors: HerdrThemeColors, to original: String) -> PatchResult? {
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
        // Any assignment "key = ..." for a key that MIGHT be one of `Field`'s
        // known names. Captures: 1 = key name.
        let anyAssignPattern = try! NSRegularExpression(
            pattern: #"^\s*([A-Za-z0-9_][A-Za-z0-9_-]*)\s*="#)
        // An assignment this scanner CAN safely read: a single-line quoted
        // string with no escapes. Captures: 1 = leading whitespace, 2 = key
        // name, 3 = the "= " separator (with its own surrounding
        // whitespace), 4 = the quote character, 5 = the inner value,
        // 6 = everything after the closing quote (preserved verbatim,
        // including a trailing inline comment).
        let simpleAssignPattern = try! NSRegularExpression(
            pattern: #"^(\s*)([A-Za-z0-9_][A-Za-z0-9_-]*)(\s*=\s*)(["'])([^"'\\]*)\4(.*)$"#)

        func fullRange(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
        func isCommentOrBlank(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#")
        }

        struct Existing {
            let lineIndex: Int
            /// Everything up to and including the "= " separator, preserved
            /// verbatim (leading indentation, spacing around "=").
            let prefix: String
            let currentValue: String
            /// Everything after the closing quote, preserved verbatim
            /// (including a trailing inline comment).
            let suffix: String
        }

        var currentPath: [String] = []
        var themeCustomHeaderLineIndex: Int?
        var themeCustomHeaderCount = 0
        var existingByField: [Field: Existing] = [:]

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
            guard let anyMatch = anyAssignPattern.firstMatch(in: line, range: fullRange(line)),
                  let keyRange = Range(anyMatch.range(at: 1), in: line)
            else { continue }
            guard let field = Field(rawValue: String(line[keyRange])) else { continue }
            if existingByField[field] != nil { return nil }
            guard let m = simpleAssignPattern.firstMatch(in: line, range: fullRange(line)),
                  let leadingWsRange = Range(m.range(at: 1), in: line),
                  let keyNameRange = Range(m.range(at: 2), in: line),
                  let separatorRange = Range(m.range(at: 3), in: line),
                  let valueRange = Range(m.range(at: 5), in: line),
                  let suffixRange = Range(m.range(at: 6), in: line)
            else { return nil }
            let prefix = String(line[leadingWsRange]) + String(line[keyNameRange]) + String(line[separatorRange])
            existingByField[field] = Existing(
                lineIndex: i, prefix: prefix,
                currentValue: String(line[valueRange]), suffix: String(line[suffixRange]))
        }

        var changed = false
        for field in Field.allCases {
            guard let existing = existingByField[field] else { continue }
            let desired = field.value(in: colors)
            if existing.currentValue != desired {
                lines[existing.lineIndex] = existing.prefix + "\"" + desired + "\"" + existing.suffix
                changed = true
            }
        }

        // Only creating a brand-new `[theme.custom]` table (the file had
        // none at all) should force a trailing newline regardless of the
        // original's own convention - that is genuinely new trailing
        // content, conventionally terminated the way herdr's own
        // `--default-config` output always is. Replacing an existing live
        // value, and inserting missing keys into an already-existing table,
        // both change nothing about how the file *ends* and must preserve
        // `hadTrailingNewline` exactly, whichever way it went.
        var createdBrandNewTable = false
        let missing = Field.allCases.filter { existingByField[$0] == nil }
        if !missing.isEmpty {
            changed = true
            let newLines = missing.map { "\($0.tomlKey) = \"\($0.value(in: colors))\"" }
            if let headerIdx = themeCustomHeaderLineIndex {
                lines.insert(contentsOf: newLines, at: headerIdx + 1)
            } else {
                if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("")
                }
                lines.append("[theme.custom]")
                lines.append(contentsOf: newLines)
                createdBrandNewTable = true
            }
        }

        var newContent = lines.joined(separator: "\n")
        if hadTrailingNewline || createdBrandNewTable {
            newContent += "\n"
        }

        // Self-check: re-scan the output through the same rules and confirm
        // it now describes exactly the state this function meant to produce
        // - defence against a bug in the logic above, not just in the input.
        guard verify(newContent, expected: colors,
                     headerPattern: headerPattern, anyAssignPattern: anyAssignPattern,
                     simpleAssignPattern: simpleAssignPattern)
        else { return nil }

        return PatchResult(content: newContent, changed: changed)
    }

    /// Re-derives the same facts `apply` computed on the input, this time on
    /// the output: exactly one `[theme.custom]` table, and for every
    /// `Field`, exactly one live occurrence in it, holding exactly the
    /// expected value. Reuses the same compiled patterns rather than
    /// re-deriving them.
    private static func verify(
        _ content: String, expected: HerdrThemeColors,
        headerPattern: NSRegularExpression, anyAssignPattern: NSRegularExpression,
        simpleAssignPattern: NSRegularExpression
    ) -> Bool {
        func fullRange(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
        var currentPath: [String] = []
        var themeCustomHeaders = 0
        var liveValues: [Field: [String]] = [:]
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
            guard let anyMatch = anyAssignPattern.firstMatch(in: line, range: fullRange(line)),
                  let keyRange = Range(anyMatch.range(at: 1), in: line),
                  let field = Field(rawValue: String(line[keyRange]))
            else { continue }
            guard let m = simpleAssignPattern.firstMatch(in: line, range: fullRange(line)),
                  let valueRange = Range(m.range(at: 5), in: line)
            else { return false }
            liveValues[field, default: []].append(String(line[valueRange]))
        }
        guard themeCustomHeaders == 1 else { return false }
        for field in Field.allCases {
            guard liveValues[field] == [field.value(in: expected)] else { return false }
        }
        return true
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
    /// config.toml so every field `HerdrConfigPatcher.Field` manages matches
    /// `theme`'s own derived colours (`HerdrThemeColors.derive(from:)`). A
    /// no-op, not a failure, whenever herdr is not installed, the file
    /// already holds every right value, or the file's structure is not one
    /// `HerdrConfigPatcher` is confident it understands - none of those are
    /// things a captain needs to be told about; a genuine write failure
    /// (permissions, a vanished volume) is logged, since GL-11's rule is
    /// "log before degrading", but is otherwise a soft, best-effort sync to
    /// a sibling tool's own config rather than anything Grand Line's own
    /// persistence-failure surfaces (`PersistenceFailureReporter`,
    /// scoped to this app's own stores) need to know about.
    func syncNow(theme: HelmTheme) {
        let installed = Self.herdrInstalledOverrideForTests
            ?? (Subprocess.resolveExecutable("herdr") != nil)
        guard installed else { return }

        let colors = HerdrThemeColors.derive(from: theme)
        let path = Self.configPath()
        let original = (try? String(contentsOf: path, encoding: .utf8)) ?? ""

        guard let result = HerdrConfigPatcher.apply(colors: colors, to: original) else {
            AppLog.store.notice("""
                herdr theme sync: config.toml at \(path.path, privacy: .public) is not in a \
                shape this app is confident it can patch safely - leaving it untouched
                """)
            return
        }
        guard result.changed else { return }

        do {
            try AtomicWrite.text(result.content, to: path)
            AppLog.store.info("""
                herdr theme sync: synced [theme.custom] colours to \(theme.name, privacy: .public) \
                in \(path.path, privacy: .public)
                """)
        } catch {
            AppLog.store.error("""
                herdr theme sync: failed to write \(path.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }

        triggerLiveReload()
    }

    /// Best-effort: tells an ALREADY-RUNNING herdr server to reload
    /// whatever settings IT owns from `config.toml` right now - pane
    /// defaults, worktrees, integrations, custom commands. **This does
    /// NOT make an already-open herdr pane's theme/presentation colours
    /// update** (this file's header explains why, with the herdr docs that
    /// confirm it) - that half is the captain's own client-side "reload
    /// config" action (herdr's global menu, or `prefix+shift+r`) or a
    /// detach/reattach, neither of which this app can safely trigger on
    /// the captain's behalf (it has no reliable way to know which Console
    /// tab, if any, is running a herdr client at all). Called only after
    /// the config write above has already succeeded - that write is the
    /// durable source of truth regardless of what happens here, so nothing
    /// below is allowed to be treated as fatal or to block the rest of
    /// Grand Line's own theme-apply flow. Fires via `Subprocess.runAsync`
    /// (GL-04) rather than blocking `syncNow`'s own caller -
    /// `ThemeManager.shared.observe`'s callback fires synchronously on
    /// whichever thread the captain's theme change happened on, almost
    /// always the main thread, so a blocking subprocess call here would
    /// hold up the very theme-apply flow this sync piggybacks on for as
    /// long as `reloadTimeout` if the running server ever became
    /// unresponsive.
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
            let message = Self.reloadOutcomeLogMessage(ok: result.ok, failureSummary: result.failureSummary)
            if result.ok {
                AppLog.store.info("\(message, privacy: .public)")
            } else {
                // Expected and harmless whenever no server is currently
                // running - the captain's next `herdr` launch already reads
                // the file this sync just wrote, so there is nothing left
                // to do.
                AppLog.store.notice("\(message, privacy: .public)")
            }
        }
    }

    /// Pure text-building, split out of `triggerLiveReload`'s completion
    /// handler purely so `HerdrThemeSyncSelfTest` can assert its exact
    /// wording directly (an `AppLog`/`os.Logger` call has no observable
    /// return value a test could otherwise intercept). The one property this
    /// message must NOT have - the exact property the success line got wrong
    /// for the whole life of this file until `fix-herdr-theme-sync-
    /// regression-706b` - is implying the captain has nothing further to do:
    /// a real, live-loaded config write plus a real, successful `server
    /// reload-config` call still leaves an already-open herdr pane showing
    /// its OLD colours, because that reload is server-scoped only (see this
    /// file's own header). Both branches therefore name the captain's own
    /// remaining action (herdr's "reload config" / `prefix+shift+r`, or a
    /// detach/reattach) explicitly, rather than staying silent about it.
    static func reloadOutcomeLogMessage(ok: Bool, failureSummary: String?) -> String {
        if ok {
            return """
                herdr theme sync: told the running server to reload its OWN settings (pane \
                defaults, worktrees, integrations) - config.toml on disk is already correct, but \
                herdr's theme/presentation colours are client-owned and this reload does not reach \
                them; an already-open herdr pane still needs its own "reload config" (herdr's global \
                menu, or prefix+shift+r) or a detach/reattach to show the new colours, while a freshly \
                attached client already reads them at startup with no action needed
                """
        }
        return """
            herdr theme sync: could not reload a running server's own settings (\
            \(failureSummary ?? "unknown reason")) - the file on disk is already correct and will \
            apply to any newly-started herdr client regardless; an already-open pane still needs its \
            own "reload config" (herdr's global menu, or prefix+shift+r) or a detach/reattach either way
            """
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
