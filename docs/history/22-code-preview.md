# Code Preview (embedded Monaco)

> Feature history, relocated out of `AGENTS.md` by P1 of full review #3.
> **This file is not imported into an agent session.** Read it when you are
> about to touch this area; the standing rules that apply everywhere live in
> the repository root `AGENTS.md`.
>
> Content below is verbatim from the `AGENTS.md` this was split out of. It is a
> record of what shipped, what was tried, and what replaced it - entries are in
> the order they were written, so a later one can correct an earlier one.

## Code Preview (embedded Monaco)

**`.codePreview` (`fm/grandline-monaco-code-preview`) is a Stores destination hosting the real, vendored Monaco Editor in a `WKWebView`: paste code, read it with genuine syntax highlighting, keep several snippets open, and find them all still there - and on GitHub - next time.** Seven Swift files (`CodePreviewAssets`, `CodePreviewLanguage`, `CodePreviewTheme`, `CodePreviewStore`, `CodePreviewWebView`, `CodePreviewController`, plus two suites), `native/Vendor/Monaco/` (**read its README before touching any of it**) and `native/Scripts/build-monaco-web.sh`.

- **Monaco was a captain decision, taken over a lighter CodeMirror 6 embed and a native `NSTextView` highlighter after reviewing mockups of all three.** Do not "simplify" it back to either. The embed technique is the Whiteboard's, deliberately: a committed, offline bundle loaded with `loadFileURL`, a CSP that makes offline structural rather than promised, a non-persistent `WKWebDataStore`, and the same three-layer display gating.
- **The bundle is ~4.1MB - about half the Excalidraw one - because of what is left out, and the omissions are the feature's scope.** `editor.all.js` (find, folding, bracket matching, multi-cursor, the context menu) plus fifteen `basic-languages` Monarch tokenizers are in; **every `vs/language/*` service is out**, which is what makes "no LSP, no IntelliSense" a bundle-level fact rather than a runtime toggle. `CodePreviewSelfTest.checkBundleCarriesEveryLanguage` greps the committed bundle for `typescriptDefaults`/`jsonDefaults` so a rebuild cannot quietly pull one in.
- **Two things the Excalidraw bundle keeps as files are inlined here, both because this page runs on a `file://` origin.** The codicon glyph font is a `data:` URI in the CSS (`--loader:.ttf=dataurl`); **Monaco's editor worker is inlined into the script as source text and started from a Blob URL**, because a sibling `editor.worker.js` cannot be started from a relative path on that origin and `fetch()`ing it to build a Blob is blocked outright. The worker is genuinely needed even with no language service registered - link detection and the unicode highlighter both run through `EditorWorkerService` on ordinary text, and Monaco throws the first time it wants a worker it cannot make. `web/` therefore has four files and no subdirectories.
- **JSON has a hand-written Monarch tokenizer in `code-preview.js`.** `monaco-editor` ships no `basic-languages/json` - JSON is covered by its full *service*, i.e. exactly the IntelliSense machinery this panel excludes. The tokenizer is deliberately a tokenizer and not a parser: a half-pasted fragment must still highlight rather than turn into error squiggles.
- **The chrome around the editor is AppKit, which is the opposite call from the Whiteboard and for a stated reason.** Excalidraw ships a complete toolbar, so redrawing it natively would be duplication; Monaco ships **no** tab bar and **no** status bar (those are VS Code *workbench* features), so they have to be built either way - and building them in HTML would put a second, un-themed visual language inside an app whose own self-tests ban a stock bezel. So the page is the editor surface only, and the tab strip is `TabChipView` (free rename/close/duplicate and accessibility), the toolbar is `HelmPageToolbar`, the picker is `HelmPopUpButton`. The drill-header action cluster is empty, exactly like Console's.
- **`⌘F` works here because of a method *name*.** The Edit menu's "Find…" is `nil`-target and routes through the responder chain to `#selector(ConsoleController.showFind)`, so `CodePreviewController.showFind()` picks it up while this destination is showing - the same holdover `ToolsController` already relies on. Renaming that method silently breaks ⌘F with no compile error.

### Storage: the filename *is* the tab name, the language and the identity

`GrandLineDocs/code-snippets/<name>.<ext>`, one file per snippet, the body being the code byte for byte. **No index file and no metadata sidecar**, and each omission is a decision:

- The filename is the tab label verbatim, so the repo on GitHub shows exactly the tabs that are open.
- The extension is the language, the way every editor decides it - so **picking a language in the picker renames the file**, which is a visible, self-explanatory side effect rather than hidden state, and is what VS Code does.
- A YAML/JSON wrapper would make every snippet one escaped line in `git diff` (`YamlBeautify.dump` escapes `\n` rather than emitting a block scalar). This is the one store in this app whose payload is *already* a file format.
- No shared file means no shared conflict across machines. **The cost, stated because it is real: tab order is filename order**, so renaming a tab can move it.

`CodePreviewStore()` also has an entry in `main.swift`'s global `#if FM_SELFTESTS` redirect block, per the rule Sticky Board wrote after being bitten by its absence: **any store reachable from a bare, no-argument production constructor needs one, added before its first self-test rather than after.** Nothing here is known to need it - both suites use the explicit `CodePreviewStore(root:)` seam, and every shell-mounting harness already sets `FM_SHIFT_DIR` - so it closes the case those two do not: a future suite constructing the controller with a bare store.

`CodePreviewGitSync` is `DocsRunbookGitSync` with one subpath changed - it shares `ShiftGitSync.shared`'s working tree and serial queue and owns only a debounced commit+push scoped to its own subtree. **`FM_CODE_PREVIEW_DIR` is the narrow override and `FM_SHIFT_DIR` is honoured as a fallback**, the `CommandLibraryStore` lesson applied before it could bite; no harness needed a new override because every shell-mounting one already sets `FM_SHIFT_DIR`, and `checkStoreHonoursShiftDirOverride` proves the fallback the way `IncidentStore`'s own suite does.

### Four real bugs this build found, three of them found by its own suites

- **`HelmContrast.legibleOn` guarantees the floor for the `NSColor` it returns, not for an 8-bit hex rendering of it.** It stops at the first blend that clears 4.5, so quantising each channel to `#rrggbb` on the way across the bridge moved fourteen token/theme pairs to **4.47-4.50**. `CodePreviewTheme.legibleHex` checks *after* quantisation and keeps stepping - **any caller that serialises a corrected colour needs the same treatment.**
- **A detector marker must be evidence, not merely common.** The first INI row scored `=` and ` = `, which beat Swift's own score on `var greeting = "hello"` - so a pasted Swift file opened as INI. INI has no discriminating *substring*, only the shape of a `[section]` header line, so it gets `looksLikeINI` (a section header **and** a bare `key = value`) instead of a row in the scored table.
- **An untitled name has to be taken by *stem*, and has to know about tabs that are not on disk yet.** A full-filename check hands out `snippet-1.txt` again once `snippet-1.txt` has become `snippet-1.swift`; and because a new tab is deliberately not written until it has content, a disk-only check gives two empty tabs the same name and the first one typed into takes the other's file.
- **Picking the language a snippet is *already* on is not a no-op.** `languagePicked` marks the override **before** its already-on-that-language early return, because the one case where that matters is choosing Plain Text on a snippet that is already plain text - the only way a captain can say "yes, this really is plain text" about a fresh tab, and otherwise the next paste overrules them.
- **`CodePreviewStore.sanitize` strips a leading `-` as well as a leading `.`.** Turning `/` into `-` makes `../../escape.txt` arrive as `..-..-escape.txt`; a filename starting with a dash is read as a *flag* by most CLI tools, `git` included, and these files are committed and pushed.

### Verification

`FM_RUN_CODE_PREVIEW_TESTS` is pure logic and runs in CI (assets, the offline CSP read out of the committed bytes, the language table, detection, the store's real-disk round trip, and every token colour's measured contrast against the editor background in **all fourteen themes**). `FM_RUN_CODE_PREVIEW_VIEW_TESTS` is window-backed and sits in `run-all-tests.sh`'s `NEEDS_SESSION` list: it mounts the real page and - the one thing no Swift-side test can see - **reads Monaco's own tokenizer output back** through a `tokensAt` bridge call, so "a Swift keyword is tokenized as a keyword" is asserted rather than assumed. It also proves the persistence round trip by mounting a *second* controller over the same folder, which is the honest stand-in for a relaunch.

**Nine injected regressions were each confirmed to reproduce by name**, not merely to pass: the un-quantised contrast guarantee, the loose INI markers, filename-not-stem untitled naming, a tab written before it had content, a hand-picked language overridden by detection, the late-clone retry firing after the captain closed tabs, two unsaved tabs allowed to share a name (which failed with the second tab's content genuinely missing), an override marked after the early return, and a renamed `actions.find` (which also proved the build script round-trips: the rebuilt bundle is byte-identical). **Two of those nine initially slipped through and the suite was extended rather than the finding dropped** - the flags they guard only matter in narrower cases than the first draft tested (a tab typed into *and then emptied*; picking **Plain Text** deliberately, the one choice that leaves the language on plaintext where detection would otherwise re-fire).

**One pre-existing fragility this build ran into, worth knowing before diagnosing it again.** A full-suite run on a machine whose `fm.themeID` is `daylight` fails `FM_RUN_CONTRAST_TESTS` and `FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS` - the exact pair, and the exact ambient-theme mechanism, this file already documents under "The self-test suite is not hermetic". Both pass standalone once the theme is pinned to a non-Daylight palette, and the whole suite is **100 passed / 0 failed / 1 skipped** that way. It is not a leak from these suites (verified: neither leaves `fm.themeID` changed, and a per-suite sweep of all twelve `setTheme` callers found no leaker either) and it is not this feature's to fix - the failing assertions measure `ToolRowLayout` pill columns and `HelmSegmentedTabs` radii, neither of which this branch touches. Check `defaults read FirstmateCockpit fm.themeID` before suspecting the code.

**A second pre-existing flake, diagnosed here because the diagnosis is reusable.** `FM_RUN_SETTINGS_THEME_LAYOUT_PARITY_TESTS` failed once on a GitHub runner with `daylight` and `helm-dark` reporting Settings column widths 7pt apart. It is not from this branch - that suite builds a `SettingsController` **directly**, so no destination table, store or shell wiring is in its path - and it passes locally. The mechanism, confirmed by reproducing it: **a CI runner has always-visible scrollbars** (`defaults write -g AppleShowScrollBars -string Always` reproduces it; every measured width drops by the ~15pt scroller track), and 7pt is exactly half a track split across two columns - i.e. one theme's content was tall enough for a vertical scroller and the other's was not. The two themes' content heights differ by a hair for a reason this file already documents: `HelmCard.applyTheme` sets a 13.5pt card title under Daylight against 15pt on the legacy palettes. That is a real threshold sitting close to the boundary, so the suite is marginal on any runner near it. **Set `AppleShowScrollBars` to `Always` before believing a width-parity failure is a code change** - and restore it afterwards.

**Not verified: the app was never launched.** Per the README's worktree rule this repo has no process isolation between builds sharing one bundle identity, so the visual result is the captain's own check. What is verified is that the editor really mounts, really tokenizes, really persists, and really suspends when hidden - all through the real bundle in a real window.

### `fm/grandline-recents-position-and-codepreview-theme`: the "half-themed" fix from `fm/grandline-sticky-code-preview-polish` was correct and incomplete

**The captain reported Code Preview was *still* stuck on a light appearance regardless of the theme toggle, after a prior PR had already added `view.appearance = ...` to this destination's `applyTheme()` specifically to fix that report.** That native-chrome fix was genuinely in the code and genuinely correct - `effectiveAppearance` really does follow the theme now, and `checkThemeSweep`'s existing assertion of it still passes. The bug that survived it was one level lower, and invisible to any Swift-only check: **`CodePreviewTheme.Key.operatorToken`'s auto-synthesised raw value ("operatorToken") did not match what `Vendor/Monaco/src/code-preview.js`'s `applyTheme(t)` reads (`t.operator`)** - every other `Key` case's raw value happens to equal the JS property name it feeds (`t.ink`, `t.comment`, `t.keyword`, ...), which made this one mismatch easy to miss by inspection. `t.operator` therefore always resolved to `undefined` on the JS side, `strip(undefined)` produced an empty string for two token rules ("operator" and "delimiter"), and `monaco.editor.defineTheme()` throws `"Illegal value for token color: "` on an empty rule foreground - **synchronously, before its own `monaco.editor.setTheme(THEME_ID)` call ever runs**. `CodePreviewController.pushTheme()` sent that bridge call with **no completion handler**, so the JS side's own caught-and-reported failure (`reply(callID, {ok: false, message: ...})`) was silently dropped on every single theme push since this feature shipped - Monaco never once left its initial default `vs` (light) base theme, regardless of the app's own toggle, which is exactly the captain's screenshots.

- **Fix, two parts.** (1) `Key.operatorToken` is now `case operatorToken = "operator"` - the Swift-side identifier stays a valid name (`operator` is a Swift keyword) while the wire key matches the vendored JS exactly. (2) `pushTheme()` now attaches a completion handler that logs a failure via `AppLog.lifecycle.error(...)` (GL-11: log before degrading) instead of firing-and-forgetting, so this exact class of regression - a JS-side throw the native side never looks at - cannot go silent again.
- **Why the existing self-test coverage missed it, and what actually closes the gap.** `checkThemeSweep` (`CodePreviewViewSelfTest.swift`) only ever asserted that `webView.call("stats")` still succeeded after a theme change (proving the page hadn't crashed, which it hadn't - a caught-and-replied JS error doesn't crash anything) and that `controller.view.effectiveAppearance` matched the theme's mode (native chrome only). Neither can see a Monaco-internal `defineTheme` failure. The fix is a new bridge method, `readThemeProbe` (`Vendor/Monaco/src/code-preview.js`), which reads back `document.documentElement.dataset.theme` and `.monaco-editor-background`'s real *computed* `background-color` - Monaco's own rendered state, not a value this app handed over, the same "read the tokenizer's own output" standard `tokensAt` already holds this feature to for highlighting. `checkThemeSweep` now asserts both a `"dark"` and a `"light"` `dataset.theme` were genuinely rendered across the sweep, and that the three swept themes produced three distinct rendered backgrounds. **Confirmed live to catch the regression by name**: reverting only the `operatorToken` fix (keeping the new probe assertion) reproduces `"helm-dark: Monaco's own rendered dataset.theme should be dark, was light"` and fails the sweep outright; restoring the fix passes cleanly. A live, direct-bridge-call probe (bypassing the controller's own wiring, isolating the JS handler) is what first surfaced the real error text - `webView.call("setTheme", ...)` replying `failure: Illegal value for token color: ` - rather than guessing from the symptom.
- **`native/Scripts/build-monaco-web.sh` was re-run to add `readThemeProbe` to the committed bundle** - confirmed the script still works end to end in this environment (network access + npm install succeeded) and produced a byte-diff scoped to `code-preview.js` only (`BUILD-INFO.txt`/`index.html`/`code-preview.css` unchanged, same versions).
- **Lesson for the next person to touch `CodePreviewTheme.Key` or `code-preview.js`'s `applyTheme(t)`: the two are a hand-maintained wire contract with no compiler check across the language boundary.** Adding, renaming, or reordering a case on either side needs the matching edit on the other, and "the Swift-side dictionary has the key" is not proof the JS side reads it - only a real render readback (like `readThemeProbe`) proves that.

**The Recents dropdown (`fm/grandline-recents-navigation`) got its second, captain-driven placement correction in the same task**: it sat right after the space pills - reading as a stray extra space pill next to Engineering - and now sits on the *other* side of the search field, grouped with the Sticky Board/Code Preview quick-access icons (search -> Recents -> Sticky Board -> Code Preview -> theme -> bell -> avatar). Pure `DaylightBarController` constraint-chain reordering (the button is still a fixed-size control with a plain required gap on both sides, same as its neighbours); no change to `RecentDestinations`' own logic. `RecentDestinationsSelfTest.test_barButtonSitsBeforeStickyBoardAfterSearch` measures real frame positions after a real layout pass and was confirmed to catch the old placement as a regression before being updated to the new one.

## `fm/grandline-feature-f11-code-preview-run-format`: Run and Format (F11 of full review #3 §8)

The report's own entry: "**F11 - Code Preview: run and format.** 'Run' for the scripting languages present
on the machine (python/node/swift/bash via `Subprocess`, sandboxed to a temp dir, output in a bottom pane)
and 'Format' per language. Scope: M."

Built to the shape the captain already reviewed in the F11 mockup
(`data/grandline-future-features-mockups-artifact/report.md`): a Format button carrying its formatter's
name, a Run button on ⌘R, a bottom pane whose header states the exit code, the wall clock and the
sandbox, and a list of which runners this machine actually has.

### What "sandboxed" means here, and what it does not

This is the only feature in the app that executes arbitrary code, so the claim is enumerated rather
than asserted, and `CodeRunnerSelfTest` checks the profile as **text** and the denials as **behaviour**.

Every run is `/usr/bin/sandbox-exec -f <profile>` around the interpreter, in a fresh temporary
directory, with:

- **the network denied** (`(deny network*)`);
- **every write denied** except inside that directory - a sandboxed `open("/tmp/x", "w")` raises
  `PermissionError`, measured;
- **the captain's home directory unreadable**, which is where the credentials worth stealing are
  (`~/.ssh`, `~/.aws`, this app's own stores). The one exception is an interpreter's own install
  prefix, so a `node` under `~/.nvm` still starts - and that exception is refused outright for a
  binary sitting loose in `$HOME`, because the narrowest exception that would help is `$HOME` itself;
- a **30-second wall clock**, enforced by `Subprocess`'s SIGTERM-then-SIGKILL bound;
- a **Stop button** (`SubprocessCancellation`);
- a **fixed five-variable environment** - `PATH`, `HOME`, `TMPDIR`, `LANG`, `LC_ALL`. Built from
  nothing rather than filtered from `ProcessInfo`, because a filter is a list somebody has to keep in
  step with the next secret, and this process's own environment carries a GitHub token and every
  `FM_*` store override;
- **stdin on `/dev/null`** and **output capped at 256 KB**, with the cap stated in the pane when it bites.

**What it is not, stated because the difference is the whole point.** The profile is `(allow default)`
with three denials layered on top, not an allowlist. Reads outside the home directory - `/usr`, `/etc`,
`/tmp`, another mounted volume - still succeed, and the interpreter runs as the captain with the
captain's own privileges. It stops a snippet destroying or leaking the captain's data. It is not a
virtual machine, and a local exploit of `sandbox-exec` itself is out of scope. An allowlist was
considered and rejected: the set of paths a working interpreter touches differs per tool, per version
and per machine, so it would fail closed on the captain's machine in ways this repo cannot reproduce.
If `sandbox-exec` is ever absent the run is **refused**, never quietly downgraded to an unconfined one.

### Four things that were measured rather than reasoned

- **`NSString`/`URL.resolvingSymlinksInPath` does not resolve a `/var/folders` temp path**, because it
  is documented to *strip* a leading `/private`. A profile naming `/var/folders/…` therefore matches
  nothing against a child whose real cwd is `/private/var/folders/…`, and the symptom is a denial
  **inside the directory that was supposed to be writable** - which reads as a broken sandbox rather
  than a broken path. `CodeSandbox.realPath` is `realpath(3)`. This also produced a second, confusing
  symptom worth recognising: `/usr/bin/python3` is an `xcrun` shim, and with the paths mismatched it
  printed `couldn't create cache file …/xcrun_db-…` on every run's stderr. Once the paths resolve
  correctly that noise is gone, so it is a symptom of the path bug and not something to allow around.
- **`swift <file>` needs `-module-cache-path` inside the sandbox.** The driver compiles before it runs
  and wants a module cache under the user's caches directory, which the write denial covers, so a
  perfectly good script dies with a bare `error: permissionDenied`.
- **A `height == 0` at `contentTie` (499) loses to the view's own content.** Collapsing the output
  pane that way left it at 45pt - its header row is a real 28pt button row with required constraints -
  so the editor gave up 155pt where 200 was expected. Raising the constraint above 500 is gotcha (13),
  so what moves instead is the **status bar's own top constraint**: it hangs off the pane while the
  pane is showing and off the editor card while it is not, and nothing then derives from a hidden
  pane's height at all.
- **`NSProgressIndicator.isDisplayedWhenStopped = false` stops it drawing and keeps its 16pt frame.**
  It read as a gap after the status word. A hidden *arranged subview* is the one thing an
  `NSStackView` genuinely excludes from layout, so it is hidden rather than merely undrawn.

### Three defects the render probe caught that no assertion would have

The pane was rendered off-screen in Dusk, Daylight and Light per the "Verifying native UI bugs"
convention, and looked at:

- **One header label holding the whole detail line truncated into nonsense.** "1.84 s · python3 3.12.4
  · no network · temp cwd /private/…/gl-run-9f2a/work" is longer than the row at any realistic width,
  and `byTruncatingMiddle` ate the middle of the *sentence*: it rendered as `no net…cwd /private/…`.
  Split into a sentence that never truncates and a path label that does, which is gotcha (5)'s rule
  applied properly.
- **`HelmField.fill` made the output body and the card one flat surface** in both registers - that
  token is a *well on a card*, separated by its own hairline border, and this body has none. The body
  now uses `theme.backgroundHex`, which is the ground Monaco is painted on immediately above (every
  syntax colour in `CodePreviewTheme.palette` is contrast-verified against it), so the output reads as
  a continuation of the code surface rather than as a form field below it.
- The spinner gap above, and a crowded `EXIT 1 0.21 s` boundary fixed with one custom stack spacing.

### Decisions worth knowing

- **The mockup's "Runners found" sidebar is a popover here.** This page has no sidebar - its snippets
  are tab chips along the toolbar - so the information is kept verbatim and the container changes.
  Absent tools are **listed as absent** rather than left out (the mockup's own `ruby · absent` row):
  GL-14's rule, since "this app cannot run Python" and "Python is not installed here" are different
  sentences.
- **Format supplies its own Undo, because Monaco's cannot.** The formatted text has to reach the page
  through `openSnippet`, which is `model.setValue` on the JS side, and that **resets Monaco's undo
  stack** - so ⌘Z in the editor cannot take a format back. Adding a `replaceContent` bridge command
  that used `executeEdits` would preserve it and would mean regenerating the 3.8MB bundle (node,
  network, a committed binary diff) for one call; deliberately not done. Instead the pre-format text
  is right there in memory, which is exactly the condition GL-33 sets for offering an Undo at all, so
  `Toast.showUndo` restores it.
- **Every formatter is a stdin-to-stdout filter**, asserted at the argv rather than promised: no
  formatter is ever pointed at a real file, and `-w`/`--write` in a recipe fails the suite. A
  formatter that exits 0 and prints nothing is treated as a **failure**, not as a format - applying
  that would empty the captain's snippet.
- **Formatters get a slightly wider profile than snippets** (`.installedTool`): still no network and
  still no writes outside the scratch directory, but home *reads* are allowed, because that is where
  `.prettierrc`, `pyproject.toml` and `.swift-format` live.
- **JSON has a formatter floor.** `python3 -m json.tool` is Python's standard library, so JSON
  formats anywhere python exists - which is every macOS. That is also what makes the format round trip
  testable on a machine with no formatters installed, which this one is.
- **⌘R does not navigate.** Every other contextual menu verb in `AppShellController` selects its
  destination first; this one is a no-op anywhere but Code Preview, because a chord that jumps to
  another page and executes a snippet the captain was not looking at is the wrong answer in a way a
  no-op is not. The chord was checked free against `main.swift`'s own chords first, per the duplicate
  key-equivalent rule.
- **One run at a time**, per tab. A pane belongs to the tab its run was started from, so switching
  tabs shows that tab's own last output rather than the neighbour's, and closing a tab cancels its run.

### Verification

`FM_RUN_CODE_RUNNER_TESTS` is pure logic and runs in the **blocking** CI lane - deliberately, because
it is the suite that asserts the sandbox profile's denials, their ordering, the path quoting, the wall
clock and the pruned environment. Every machine-dependent decision above it runs against an injected
`CodeToolProbing`, so "an absent tool reads as absent" means the same thing on a machine with every
formatter and on a CI runner with none. The real-run half (a sandboxed `python3`: scratch write allowed,
outside write denied, home read denied, network denied, a `while True` killed at a short-override wall
clock, a cancel honoured, a real JSON format round trip) is **skipped out loud** where there is no
`python3`. `FM_RUN_CODE_RUNNER_VIEW_TESTS` is window-backed and in `NEEDS_SESSION`.

**Three injected regressions, each confirmed to fail by name and then restored:**

- removing `(deny network*)` from the profile - failed the two profile-text cases *and* the real
  denial case;
- pinning the status bar to the pane unconditionally (the naive collapse) - failed both geometry
  cases, the editor losing 57pt to a pane that was not there;
- removing the pane's empty-output substitution - failed the GL-14 case.

**One of this task's own checks was found to be vacuous and fixed rather than kept.** The network
denial originally asserted only that a sandboxed `socket.create_connection(('1.1.1.1', 443))` fails -
and it *passed with the denial deliberately removed*, because this machine cannot reach that address
at all. It now runs the same DNS probe **unsandboxed first** and skips out loud if the machine has no
network, so the check measures the sandbox rather than the firewall.

**Not verified: the app was never launched** (the worktree rule). The pane's appearance is from real
off-screen renders in three palettes, and its status word's contrast is measured against a real render
in all fourteen; the live half is the captain's own check.
