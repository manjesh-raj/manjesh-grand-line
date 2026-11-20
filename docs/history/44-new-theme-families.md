# Six new theme families (Nord, Dracula, One, Ayu, Night Owl, Oxocarbon)

`fm/grandline-new-themes-nord-dracula-etc`.
Twelve palettes, six families, each shipping a dark and a light register - taking the picker from 14 to **26**.

The captain reviewed an 8-family board (16 palettes) built by the `grandline-theme-suggestions-lavish` scout and picked these six.
That scout's report (`data/grandline-theme-suggestions-lavish/report.md`, firstmate's own repo) carries the sourcing work: which upstream file every hex was read out of, and a Python port of `HelmContrast` that scored all sixteen.
This file records what changed when those values met the real implementation.

## What shipped

| Family | Dark | Light | Character | Source |
|---|---|---|---|---|
| Nord | `nord-polar` | `nord-snow` | Cool arctic blue-grey, low chroma | `nordtheme/nord` `src/nord.css`, nord0-nord15 |
| Dracula | `dracula` | `alucard` | High-chroma violet and pink; cream paper | `dracula/dracula-theme` `README.md` palette tables |
| One | `one-dark` | `one-light` | The neutral editor default | `atom/one-dark-syntax` / `one-light-syntax` `styles/colors.less` |
| Ayu | `ayu-dark` | `ayu-light` | Near-black, one amber accent | `ayu-theme/vscode-ayu` built `ayu-dark.json` / `ayu-light.json` |
| Night Owl | `night-owl` | `light-owl` | Deep navy, built for low light | `sdras/night-owl-vscode-theme`, both theme JSONs |
| Oxocarbon | `oxocarbon-dark` | `oxocarbon-light` | IBM Carbon: neutral greys, electric accents | `nyoom-engineering/oxocarbon.nvim` `lua/oxocarbon/init.lua` |

Two families needed care at the source, and the scout did that work rather than copying a downstream port.
One publishes HSL in Less (`hsl(220, 13%, 18%)`), resolved arithmetically.
Ayu publishes a computed lightness ramp (`$palette.yellow.l4`), so the values come out of `vscode-ayu`'s built theme files, which is the same ramp already evaluated.

## The one structural decision

The scout's board raised it explicitly and did not settle it: all eight candidates publish **two** real surface steps (a page ground and a lighter card), and the board was mocked up that way.
Every pre-Daylight palette this app ships is **one** step - `backgroundHex == chromeBackgroundHex`, with `chromeLineHex` at `HelmDesignSystem.borderAlpha` doing all the card separation.

These twelve ship one step, and the reason is not consistency for its own sake.
`backgroundHex` is simultaneously the page ground **and** the terminal background.
`fm/grand-line-legacy-terminal-canvas-chrome-match` collapsed every legacy palette to one step precisely to kill a visible seam the captain reported between the terminal canvas and the chrome around it.
A second surface step here reopens exactly that seam, for a family that has no `terminalCard` of its own to solve it the Daylight way.

So each family's single surface is its **own canonical editor background** - Nord's nord0, Alucard's cream `fffbeb`, Ayu's `0d1017`, Night Owl's `011627`, Oxocarbon's Carbon gray-100 - rather than the elevated surface the mockups used.
That keeps the value a user recognises as the family, and it is the identity half of the decision: on Alucard in particular, collapsing to the *card* value would have made the whole app pure white and thrown the cream away.

Consequence, stated plainly: **these twelve render flatter than the board's mockups show.**
`ThemeFamilySelfTest.checkPaletteShape` now fails the run on any non-Daylight palette that reintroduces a second step, so this is a rule rather than a habit.

## Contrast, re-measured against the real implementation

The scout's numbers came from a standalone Python port.
Every palette was re-scored here against the app's own `HelmContrast` - via `FM_RUN_CONTRAST_TESTS`, which sweeps `HelmTheme.allThemes` and therefore needed no edit at all to cover twelve new entries.

**One value did not survive the re-measure.**
Nord Snow Storm's accent was proposed as nord10 darkened 14% (`516f94`), scored 3.50 -> 4.50 by the port.
Against the real `HelmContrast` that is **4.497:1** - under the 4.5 floor by three thousandths, and `checkTextSelectionContrast` failed it by name.
It ships one more step down the same hue line, `4e6b8f` at 4.77:1.
This is the whole reason the brief said to verify rather than transcribe.

Four accents are deviations, and all four are the same defect: `selectionTextHex` is the primary button's label on the accent fill as well as the terminal's selected-run ink, so it has to clear 4.5:1 on `accentHex`.
Each is a darkening along the hue's own line, never a new hue.

| Palette | Canonical | Ships | Label on the accent |
|---|---|---|---|
| Nord Snow Storm | `5e81ac` (nord10) | `4e6b8f` (-17%) | 3.50 -> 4.77 |
| One Light | `4078f2` (hue-2) | `3a6ddc` (-9%) | 3.88 -> 4.57 |
| Light Owl | `2aa298` | `218078` (-21%) | 3.13 -> 4.75 |
| Nord Snow Storm hairline | `d8dee9` (nord4) | `c2cbd8` | 1.11 -> 1.34 vs the page |

Two further deviations that are not contrast fixes:

- **Ayu Light's `selectionTextHex` is Ayu's own dark `common.ui` (`1f2430`), not the page ground.** Every other light palette here puts its page ground on the accent; Ayu Light's amber is a *light* fill, so a pale label measures under 2:1 on it. 6.81:1 as shipped.
- **Oxocarbon Light's ANSI slots use IBM Carbon v11's token ramp.** `oxocarbon.nvim`'s own light half leaves several slots on Material hues that are neither Carbon nor legible on gray-10. Carbon is the palette oxocarbon is itself derived from, so this is staying inside the family rather than inventing.

Everything else is verbatim.

### What the numbers came out at

Ink on the surface, and the primary button's label on the accent, measured by the app's own code:

```
nord-polar       ink  9.25  primary  6.24     nord-snow       ink 10.84  primary 4.77
dracula          ink 13.36  primary  5.90     alucard         ink 15.89  primary 6.02
one-dark         ink  6.57  primary  5.92     one-light       ink 10.86  primary 4.57
ayu-dark         ink 10.12  primary  9.98     ayu-light       ink  6.10  primary 6.81
night-owl        ink 13.54  primary 11.25     light-owl       ink  9.88  primary 4.75
oxocarbon-dark   ink 16.43  primary  7.65     oxocarbon-light ink 16.45  primary 5.00
```

All 26 palettes x 7 tint hues clear the pill floor (4.5) and the icon-tile floor (3.0).
`HelmTheme.computeMutedAlpha` raised four of the twelve off its 0.70 base - `one-dark` 0.76, `ayu-light` 0.87, `light-owl` 0.72, `one-light` 0.70 - and none anywhere near the 0.96 the scout measured for Everforest, which was one of the two families the captain did not pick.

### Ayu makes the hairline load-bearing

Ayu's `base` and `lift` are 1.03:1 apart upstream, so under the one-step convention `chromeLineHex` is the only thing separating a card from the page.
That is not novel here - `gruvbox-light` and both Tokyo Nights are already in the same position, and `HelmDesignSystem.borderAlpha`'s own doc comment says the border carries real load because of it.
Both Ayu halves use the strongest divider each publishes (`editorGroup.border`: `1b1f29` / `dfe2e6`) rather than the faintest.

## Coverage

Two new suites, split the way AGENTS.md's "Writing a self-test" requires.

**`FM_RUN_THEME_FAMILY_TESTS`** (pure logic, CI's **blocking** lane) - `ThemeFamilySelfTest`.
The family pairing was the real hole: `ThemeManager.toggle()` flips to `theme.pairId` and *falls back* to the plain `helm-dark`/`helm-light` swap when the lookup misses, so a typo'd or one-way `pairId` fails nothing and just quietly drops the captain out of the family they were in, on a keystroke they press constantly.
Six new families doubled the places that can happen.
Asserts every `pairId` resolves, is mutual and crosses the mode; that `toggle()` itself lands on the pair and back; that ids and display names are unique; and the palette shape (16 parseable ANSI slots, one surface step, one accent serving as cursor and selection).

**`FM_RUN_THEME_FAMILY_VIEW_TESTS`** (window-backed, `NEEDS_SESSION`) - `ThemeFamilyRenderSelfTest`.
Mounts the real `SettingsController` - the page these themes are selected on - in an `OffScreenProbe` window, under each of the twelve, and reads the render back.
Two claims a table of hexes cannot make:

- The page ground is **painted** in the palette's own colour, sampled out of a `cacheDisplay` render. Both of that call's traps are respected: the rep is measured in pixels (scaled by `rep.pixelsWide / bounds.width`) and the expected colour is converted into `rep.colorSpace` rather than the sample into sRGB.
- The forced appearance **wins over the window's**. The probe window is deliberately given the *opposite* register before mounting, so a page that merely inherits its appearance fails. That is the half-themed defect stated as an experiment rather than as a convention - it has shipped four times.

Both were confirmed to catch a real regression, not merely to pass.
Injecting a one-way `pairId` on `nord-snow` failed the mutual check, both toggle directions and nothing else.
Giving `night-owl` a second surface step failed the shape check by name.
Deleting `SettingsController`'s `root?.appearance = ...` line failed the render suite on all twelve palettes.
Each injection was made by copying the file aside and restoring it afterwards - never `git stash`, never `git checkout -- <file>`.

**`ThemeMotionWebIslandsSelfTest`'s K1 check was rewritten rather than renumbered.**
It asserted `HelmTheme.allThemes.count == 14`, whose stated intent was "K1 must not *remove* a palette".
A count guards the wrong direction: it fails on an addition, which is fine, and passes on a swap, which is the regression.
It now names the fourteen K1 ids and checks each still resolves.

**What is covered for free**, because these sweeps were already data-driven over `HelmTheme.allThemes` and needed no edit: the full contrast sweep (`FM_RUN_CONTRAST_TESTS` - text selection, pills, icon tiles, muted ink, button variants, accent rows, fields), Settings' theme-layout parity, the status-pill theme sweep, the canvas/lists/controls sweep, and the notebook, whiteboard and recent-destinations theme sweeps.

## What was not done

- **The other two families the captain reviewed were not built.** Everforest and Kanagawa are on the board and were not picked; the scout's own recommendation flagged Everforest as shipping visibly compromised (a muted alpha of 0.96, which erases the primary/secondary text distinction the token exists to create).
- **No screenshot.** This agent has no Screen Recording grant; the visual evidence is the `cacheDisplay` render described above, which is a real rasterised render rather than a screen capture. The live half - does Nord actually *look* like Nord on the captain's display - is his own check.
- **Nord's light half is ours to own forever.** Nord ships dark-only upstream; `nord-snow` reuses Nord's published Snow Storm ramp for the surfaces and darkens the Aurora/Frost hues for paper. There is no upstream to re-sync it from.

## The six palettes as app theme families (`fm/grand-line-color-options`, Helm 9.1.0)

The colour-options board (`data/grand-line-color-options/`) proposed six two-colour palettes, and all six shipped as app theme families in a group of their own.
Each has a light and a dark register in `AppThemeRegister.all`, with every token measured to clear 4.5:1 on its card, ground and side.
Chart/Fathom is deep blue `#07518A` and warm creme `#FFF0D5`.
Porcelain/Port is black cherry `#430D1C` and porcelain `#FFF0D5`. The request typed these with the letter O in place of a zero, and they were read as zeros.
Ice/Midnight is ice blue `#E9F0F5` and midnight navy `#172C45`.
Lavender/Powder is powder blue `#8DB9F0` and lavender white `#E9E8F8`.
Pearl/Abyss is midnight teal `#0B3048` and pearl `#F2F0E9`.
Oat/Forest is oat milk `#EEE5D4` and forest green `#1D4A35`.

**A hero colour separate from the accent.**
A dark register's accent has to be light enough to read as text on a dark card.
`HelmHeroSurface.palette(accent:)` then deepens it 32-38% toward black before white text clears the floor, which turned Fathom's hero a grey steel blue.
`AppThemeRegister.hero` pins a register's heroes to another colour, and `HelmTheme.heroAccentHex` is what every hero entry point reads now.
Only Fathom (`#07518A`) and Forest (`#1D4A35`) pin, because only those two still stand clear of their own dark ground (1.92:1 and 1.62:1).
Port, Midnight and Abyss would sink into their ground or their navy and teal cards (1.20 to 1.29:1), and Powder's pin would be a light hero needing dark ink.

**Nothing on a palette stays Daylight blue.**
The full page tour (every sidebar page in the Operator profile, the nine Settings pages and the new-host sheet) was rendered for all twelve registers, and a hue scan flagged saturated blue.
Two leaks were found and fixed.
First, primary buttons (New Task, Add Host) fell back to `HelmDomainHue.blue`'s fixed Daylight pair. On a palette that hue is now the palette's accent.
Second, four palettes had a separate blue `info`, which is the link colour and Settings' Menu Bar tile. Every palette's `info` is now its accent, as Daylight's is.
What is still blue on a palette is identity, not theme: a host's or a project's own colour, the host editor's colour swatches, and the other families' tiles on Appearance.

**The classic families are pixel-identical.**
The same tour was rendered with a build of `origin/main` and with the branch, for Daylight, Dusk, Grove and Moss.
26 of the 30 pages were byte-identical.
Home, Health and Secrets differed only where a clock draws: relative times, the auto-lock countdown and the Claude reset times. Two runs of the branch build differ in the same places.
Settings › Appearance differed only by the new Palettes group under the unchanged tiles.

Tests: `ThemePalettesSelfTest` (new, headless) guards the classic heroes, the pins, legibility, Home's card colours, the theme menu and search.
`ThemeSplitSelfTest` carries the twelve new rows.
`SettingsRedesignSelfTest.checkThePalettesAreTheirOwnGroup` drives the grid in a real window.
The welcome sheet's look step keeps the seven classics, so its S25 height check is unchanged.
