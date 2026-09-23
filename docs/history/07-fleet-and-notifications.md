# Fleet, Overview, notifications and the captain's log

> Feature history, relocated out of `AGENTS.md` by P1 of full review #3.
> **This file is not imported into an agent session.** Read it when you are
> about to touch this area; the standing rules that apply everywhere live in
> the repository root `AGENTS.md`.
>
> Content below is verbatim from the `AGENTS.md` this was split out of. It is a
> record of what shipped, what was tried, and what replaced it - entries are in
> the order they were written, so a later one can correct an earlier one.

- **Fleet dashboard (`FleetController.swift` + `FleetData.swift`, cockpit-native-ui-fixes2).** The `.overview` rail destination is a real port of `backend/fleet.py`'s `snapshot()` and `backend/openprs.py`'s `open_prs()` into Swift - greeting header, calm/loud answer banner, stat tiles (working/ready-to-merge/queued/done/projects/watcher), and an "In flight" list of working crew. **No embedded backend**: `FirstmateHome.swift` resolves `$FM_HOME` the same way `backend/config.py` does, then `FleetData.swift` reads `data/projects.md` / `data/backlog.md` / `state/*.meta` directly and shells out to `bin/fm-crew-state.sh` per task (the same authoritative, non-tailed state read the Python backend uses); `OpenPRsSource` walks `$FM_HOME/projects/*` and re-implements `openprs.py`'s remote-parsing + `gh pr list` + Bitbucket-REST logic natively. `FleetController.refresh()` runs this whole pipeline off the main thread and re-renders on completion - there is no live websocket push (unlike the web app), only a refresh on `viewWillAppear` plus a manual refresh button. **`fm/grandline-overview-drop-duplicate-pr-list` removed Overview's own itemized "Ready to merge" list** (one row per PR with its own Review/Merge actions) - it was a captain-flagged triplication of the exact same `OpenPRsSource.fetch()` + `FleetDataSource.mergedPRs` data `.review` (`ReviewController.swift`, below) already presents in full, grouped by forge, plus the stat tile that already summarized it. The "ready to merge" stat tile is the one signal left on Overview (per the captain's own call, Overview stays a quick pulse-check, not a second copy of Review's list) and is now clickable - it calls `onNavigateToReview`, wired by `AppShellController` to `show(.review)`, so a captain can still jump straight from the count to the actionable list. `FleetDataSource.mergePR`/`bin/fm-pr-merge.sh` (the Merge action) is unaffected - `.review` still calls it directly.

## Fleet history / captain's log (Overview > Log)

**`fm/grandline-feature-f6-fleet-history-log` added F6 of the production-readiness review's feature roadmap** (`data/grandline-production-review/MANJESH_GRAND_LINE_PRODUCTION_REVIEW.md` section 25, plus the captain-approved mockup in that folder's `lavish-plan.html`): a second tab on Overview holding a reverse-chronological, kind-filterable record of what already happened. Four files - `FleetLogEvent.swift` (record + `FleetLogSources`, the phrasing layer), `FleetLogStore.swift` (the JSONL sink), `FleetLogFeed.swift` (the read/merge/group side, AppKit-free), `FleetLogListView.swift` (the table).

- **It is the opposite half of the Notification Center, and the two share no code on purpose.** `GrandLineNotificationCenter` answers "what needs you right now" - live conditions that clear themselves. This is durable history that nothing ever clears. What they do share is the discipline: **format at the edge, detect nowhere new.** `FleetLogSources` is the direct counterpart of `NotificationSources` - every call site hands it values it already had, and no detection logic lives in either.
- **Every event is appended synchronously by the code path that caused it - there is no poller, and adding one would be the wrong fix for anything.** Three write sites: `ReviewController.recordMergeInFleetLog` (on a `FleetDataSource.mergePR` that genuinely returned `ok` - never an attempt or a failure), `ShiftGitSync.recordResolutionInFleetLog` (one event per record the captain actually decided; `detectAndResolveConflicts`'s *automatic* merge path is deliberately silent, since there was no decision and no divergence the captain ever saw), and `LogAnalyzerStore.save` (gated on `isFirstSave` - `save` also runs on every later edit of the same investigation, and the log wants "saved investigation X" once, not once per edit).
- **The task half is NOT in the JSONL file, and that is the design, not an omission.** `ShiftStore` has logged `task_created`/`task_completed`/`follow_up_snoozed`/... into `activity/<YYYY-MM>.yaml` since Shift phase 1, already phrased for display. `FleetLogFeed.events` merges those (via the new `ShiftStore.recentActivity(monthsBack:reference:)`, a thin wrapper over the same bounded read Weekly Review already does) with the store's own events at render time. Copying them would mean two sources of truth, a write path that can half-fail, and this side's retention cap silently truncating history Shift's own files still hold - and reading them instead is why the tab is useful on first launch against months of pre-existing task history.
- **Retention: at most `maxEvents + trimSlack` (2000 + 200) lines, trimmed back to the newest 2000.** The slack is load-bearing - trimming exactly at the cap turns every append past it into a full rewrite forever, which is the cost JSONL was chosen to avoid. Oldest go first; a cap that dropped the newest would leave the feed permanently stale rather than merely bounded.
- **Security (the spec's own constraint): an event carries an id and a one-line title, never command output.** `FleetLogEvent.init` runs every title through `sanitize` - newlines collapsed, length bounded - so an accidental multi-line paste (the shape a stray log excerpt would take) is structurally unstorable rather than merely discouraged.
- **`FM_FLEET_LOG_DIR` overrides the store's directory** (`~/Library/Application Support/FirstmateCockpit/fleet-log/`), same convention as `FM_DICTATION_DIR`. Its own directory, deliberately not inside `ShiftGitSync`'s `personal-tasks/` subtree: this is a record of what happened *on this machine*, and syncing it would both merge two machines' histories into one confusing feed and push a record of the captain's activity to GitHub that nothing asked for.
- **A real defect this shipped with for one test run, worth not repeating: `main.swift`'s `#if FM_SELFTESTS` block now redirects `FM_FLEET_LOG_DIR` to a scratch path for any process running an `FM_RUN_*` suite.** `ShiftConflictSelfTest` and `LogAnalyzerSelfTest` drive real code paths that reach `FleetLogStore.shared` *indirectly*, through a singleton neither suite constructs - so they correctly overrode every store they knew about and still wrote three fabricated events into the captain's real `events.jsonl` on a plain `./Scripts/run-all-tests.sh` (confirmed live, then cleaned up). The redirect lives at the process entry point rather than in those two suites so it also covers a single suite run by hand, and every future suite that reaches an append path. **Any new singleton sink reached indirectly from a real code path needs the same treatment** - the per-suite fix is the one that keeps missing cases.
- **`FM_RUN_FLEET_LOG_TESTS=1`** covers append-and-reread-from-disk (every case drops the cache first, so a check that only read `events()` back cannot pass vacuously), the on-disk JSONL shape, the retention cap, the kind filter, day grouping, the title sanitiser, and the Shift merge against a real `ShiftStore` on a scratch `FM_SHIFT_DIR`. **Confirmed to catch four real injected regressions**, not merely to pass: removing the trim (2205 lines retained), a filter that ignores its kind, a pass-through sanitiser (a newline and a 5000-character title both survived), and a pretty-printing encoder (which broke the format while every in-process read still worked - the exact failure mode a shape check exists for).
- **Overview is a two-tab page now, and F12's morning-briefing card lives inside the Overview tab rather than above the tab strip.** F6 and F12 landed within a day of each other and both touch this page's `loadView`; the rebase put `briefingCard` into `overviewContainer` alongside the banner/stats/In-flight sections, so switching to Log takes the whole dashboard with it. The tab strip is the only page-level chrome between the header and the two tab bodies. F12 already owned the shared `ShiftStore` injection and `init(shiftStore:)` this feature also needed - there is one of each, not two.
- **Verified with `swift build` (zero warnings), `swift build -c release` (0 `FM_RUN_*` strings in the shipped binary) and all 58 runnable suites - without launching the app**, per the README's worktree rule.

## Notification Center

`fm/grandline-notification-center` added a bell + badge + dropdown panel between `TopBarController`'s `searchPill` and `themeButton` (design: `data/grandline-notification-center/design-reference.html`), aggregating nine already-computed "the captain should know about this" signals into one place instead of six separate pages.

- **`GrandLineNotificationCenter.swift`** is the store: an app-lifetime singleton (`ThemeManager`-style `observe`/notify), `AppNotification` (id/title/subtext/kind/tint/navigate), and one entry point, `set(_:id:)` - present means "this condition is true right now," `nil` means "resolved." One id per source, so dedup is structural, not a diffing step. `.actionNeeded` ("waiting for you": fleet decisions, PRs ready, SRE Lead replies, fleet tasks finished) auto-clears on resolution only, no manual dismiss. `.informational` ("FYI": tool updates, fork drift, Vault attention, setup drift, Shift due items) also supports `dismiss(id:)`/`markAllRead()`, remembered by the dismissed entry's exact subtext (`dismissedDetail`) - the same condition with unchanged text stays hidden, a materially changed detail resurfaces it. See the file's own header for the full reasoning.
- **`NotificationSources.swift`** is the only place that formats each signal's title/subtext/tint - no detection logic lives here, every function takes a count/list a page or poller already computed.
- **`NotificationCenterPopover.swift`** is the bell (`NotificationBellButton`, fixed white-on-systemRed badge, same non-theme-tinted convention as `IconRailController.attachBadge`) and the panel (`NSPopover`, mirrors `ConsoleComposerPopover.swift`/`QuotaUsagePopover.swift`'s idiom exactly). `TopBarController.notificationCenter` owns both.
- **`fm/grandline-notification-bell-badge-fix-2` fixed the bell badge for good, after a first pass (`fm/grandline-notification-bell-badge-fix`, shaving the overlap from 5pt to 2pt) still wasn't enough per a second captain screenshot.** Root cause: at a 34x34 box with a 9pt corner radius, the rounded curve starts well before the flat edges, so *any* small overlap positioned at that diagonal corner cuts across the curve itself - shaving the overlap number further was never going to fix it. This is the exact same lesson `IconRailController.attachBadge` already learned the hard way (two overlap-tuning attempts before it stopped overlapping the icon's box entirely - see that method's own doc comment). The fix applies that same shape here: `NotificationBellButton` now separates the *visible bordered icon square* (`iconBackground`, a fixed 34x34 subview matching `TopBarController.themeButton` exactly) from the button's own overall frame, which is widened (`NotificationBellButton.controlWidth` = icon + a 3pt gap + a 32pt reserved badge zone) so the badge sits entirely to the icon's right, never overlapping its frame - verified live via a temporary geometry probe confirming zero intersection between the badge's frame and the icon square's frame at every count (including "99+"). `TopBarController`'s bell width constraint reads `NotificationBellButton.controlWidth` instead of a literal `34`; its leading/trailing anchor formulas versus `searchPill`/`themeButton` were deliberately left untouched, so both gaps stay the same 10pt they always were - the reserved badge zone just occupies what used to be dead space in the existing gap to `themeButton`, rather than shrinking it. The popover itself anchors on `bell.visibleIconFrame` (the icon square), not `bell.bounds` (now wider), so it still opens flush under the icon. Any future badge placed near a rounded corner in this app should go straight to the "fully outside the box" shape rather than re-attempting an overlap-amount tweak.
- **Wiring, per signal** (see `AppShellController.loadView()`/`connectHost`, `main.swift`, `FleetNotifier.swift`, `ShiftNotifications.swift`, `ConsoleController.swift`):
  1. Fleet decisions/blocked and 2. PR-ready reuse `FleetController.onNeedsDecisionCountChanged`/`ReviewController.onOpenPRCountChanged` verbatim (already computed for the rail badges) - zero new polling.
  3/4/5/6 (tool updates, GitHub Sync drift, Vault attention, Bootstrap setup drift) are polled by **`BackgroundSignalsPoller.swift`**, a new slow (15-minute) background poll - deliberately not `FleetNotifier`'s 30s cadence, since these four each shell out to `brew`/`npm`/`gh api`/`av` per catalog item/repo/tool; see that file's header for the cadence tradeoff (a deliberate decision, not a default).
  7. SRE Lead replying on a backgrounded tab is detected in `ConsoleController.handleSRELeadSubmit` (fires `onSRELeadReplyWhileBackground` when the replying tab isn't `currentTab` or the page is hidden) and cleared in `select(tabID:)`/`markCurrentTabAsRead()`/`closeTab`/`shutdown()` - the one signal with more than one live id at once (`sre-lead.<tabID>`).
  8. Shift due/overdue is fed from `ShiftNotificationScheduler.poll()`'s own existing due-detection (`onDueCountsChanged`) - the same computation that already drives the OS banner, not a second implementation.
  9. Fleet tasks finishing (done/failed) has no other computed home - `FleetNotifier` was extended to detect it. This also required decoupling `FleetNotifier`'s poll from the "Bell & notifications" Settings toggle: the poll (`start()`) now always runs from launch regardless, and `setEnabled(_:)` only gates whether an OS banner is *also* posted - the in-app center must stay current whether or not OS banners are opted into. A finished task is "acknowledged" (stops resurfacing) only once the captain opens the aggregated notification (`FleetNotifier.acknowledgeFinishedTasks(ids:)`), separate from the OS banner's own one-shot dedup set.
- **Self-tests**: `GrandLineNotificationCenterSelfTest.swift` (`FM_RUN_NOTIFICATION_CENTER_TESTS=1`) covers the store's pure logic (dedup, both clear semantics, dismiss/resurface-on-change, badge count, observer fan-out). `NotificationCenterSRELeadSelfTest.swift` (`FM_RUN_NOTIFICATION_CENTER_SRE_LEAD_TESTS=1`) drives the real `ConsoleController` (via its existing `debugStartSRELead`/`debugAskSRELead`/`debugSelectTab`/`debugCloseTab` hooks, same fake-`claude` harness as `SRELeadPerTabSelfTest.swift`) for signal #7 specifically - the trickiest one, since nothing outside a tab's own pane previously observed its phase changing.
- **`fm/grandline-notification-row-redesign` restyled each panel row (`NotificationRowView`, `NotificationCenterPopover.swift`) from a flat, borderless dot+title+subtext line into its own bordered card** - a colored left accent bar, a small round `IconTileView`-style icon badge, a bold uppercase kicker label, the body message, and a trailing chip carrying the entry's source/clear-rule text (captain reference: a Slack-RCA claims panel). Rendering-only: the store, the 9 signal adapters, dedup/clear semantics, and the badge count are untouched. `NotificationRowPresentation` maps each entry's already-stable `id` (from `NotificationSources.swift`) to a per-source icon + kicker - a rendering-layer lookup, not a new field on `AppNotification`; a future signal added without a matching case here still renders via a generic fallback. The card border/fill reuses `ToolRowLayout`'s `cardStyle` idiom and the chip reuses `ToolRowLayout.pill` directly (`HelmUIComponents.swift`), but the row itself stays a bespoke view rather than going through `ToolRowLayout.build` - that assembly's icon-tile/trailing-stack/chevron/log shape has no concept of a left accent bar and carries controls (expandable log, button stack) this row doesn't need. The panel widened from 320pt to 340pt to fit the richer card without feeling cramped. Each row's own leading/trailing anchors to `rowsStack` (not a width-equal-to-stack constraint) are what create the card's margin from the panel edges - the old full-bleed row relied on width-equal-to-stack. Verified live (temporary env-gated probe, reverted before commit, per this file's "Verifying native UI bugs" convention): all 8 real sourced entries rendered as distinct, non-overlapping cards with no element overflowing its card's bounds, across `helm-dark`/`helm-light`/`catppuccin-mocha`/`gruvbox-light`, plus confirmed click-to-navigate and "Mark all read" visibility are unaffected. The probe deliberately never called `ThemeManager.shared.setTheme` (which persists to the real `UserDefaults.standard` "fm.themeID" key) - it re-themed the panel instance directly via `applyTheme(_:)` to avoid clobbering the real captain's saved theme preference on a shared dev machine; any future multi-theme sweep probe in this codebase should do the same rather than reach for `setTheme`.

## Actionable notifications (F4, `fm/grandline-feature-f4-actionable-notifications`)

F4 from the production-readiness review's feature roadmap (section 25 of
`data/grandline-production-review/MANJESH_GRAND_LINE_PRODUCTION_REVIEW.md`, with the
captain-approved mockup in that folder's `lavish-plan.html`) - `UNNotification` action
buttons on the OS banners this app already posted, so acting no longer means activating
the app and navigating by hand. `NotificationActions.swift` is the whole feature; read its
header before changing any of it.

- **The split that matters: `NotificationActionRouting.resolve(...)` is pure, the router
  performs.** Action identifier + the post's archived `userInfo` payload in, a list of
  `NotificationRoutedAction` out, nothing executed. Every policy decision - including the
  merge gate - lives in `resolve`, which is what makes the gate assertable without running
  a real merge. `NotificationActionRouter` (the `UNUserNotificationCenterDelegate`) only
  dispatches those values onto injected closures, wired in `main.swift` to
  `AppShellController.show(_:)`/`openShiftTask(id:)`/`openShiftFollowUp(id:)` and
  `ShiftStore.snoozeFollowUp(id:to:)` - the forward-don't-own convention every other
  out-of-window surface here uses. There is no second merge, navigation or snooze path.
- **The merge gate is enforced twice, and both halves are load-bearing.**
  `FleetNotifier.reconcilePRs` only *posts* a PR notification for a PR
  `FleetDataSource.canMerge` already accepts, so a red/pending PR never carries a Merge
  button; and `resolve` re-checks the payload through the **same** `canMerge` when the
  button is tapped, returning `.refused` instead. The second half is not belt-and-braces:
  a `userInfo` dictionary is archived by the system and handed back to a *later* launch,
  so a notification still sitting in Notification Center after its checks went red would
  otherwise merge on a stale claim.
- **`FleetDataSource.canMerge(checks:taskID:)` is the one definition both forms delegate
  to** (`canMerge(_ pr:)` now calls it). It trims the task id rather than only checking
  `isEmpty`, because a whitespace-only id reaches `bin/fm-pr-merge.sh` as a real argument
  and fails *its* validation - a guaranteed-failure merge instead of a refusal. Unreachable
  from a row built out of `state/*.meta`; reachable from a hand-crafted payload.
- **The PR-ready OS banner is new; the in-app entry is not.**
  `NotificationSources.setPRReady` (a count, fed from Review's `onOpenPRCountChanged`)
  already existed, but nothing ever reached the captain looking at something else.
  `FleetNotifier.reconcilePRs` is fed by a new `ReviewController.onPRsChanged` wired in
  `AppShellController` next to the existing count callback - so it rides Review's own
  refresh triggers and adds **no poll**. It lives on `FleetNotifier` rather than in the
  view controller because that class already owns the seen-since-launch sets and the
  `osBannersEnabled` gate; duplicating either in a controller is how a signal starts
  double-firing.
- **The three pre-existing posts are otherwise untouched.** Title, body, sound and
  `identifier` are byte-for-byte what they were; only `categoryIdentifier` + `userInfo`
  were added. A captain who never presses a button sees exactly the old notification.
- **Category ids and action ids are a wire format.** They are written into posted
  notifications, so renaming one silently strips the buttons off anything already sitting
  in Notification Center.
- **Merge is deliberately not a `.foreground` action** - it does not need the app brought
  forward, and stealing focus to show a page nobody asked for is the opposite of the
  one-click principle. That leaves no window for an `NSAlert`, so the outcome (and a
  refusal) comes back as its own notification via `NotificationActionRouter.postFeedback`.
  The button press is itself the confirmation, in place of the Review page's modal.
- **GL-09: `AppLockedSurface.notificationAction`** gates every action uniformly - an action
  runs while the main window is not frontmost and both navigates and writes, which is
  exactly `AppLockGate`'s documented rule. A locked app therefore behaves as it did before
  F4: activating shows the lock screen, nothing else moves.
- **`willPresent` returns `[.banner, .sound]`** so a notification still shows while the app
  is frontmost. Without it the system suppresses it entirely, which makes the buttons
  unreachable precisely when the captain is at the keyboard.
- **Verified with `swift build` (clean, zero warnings), `swift build -c release`, and all
  55 runnable suites - without launching the app**, per the README's worktree rule.
  `FM_RUN_NOTIFICATION_ACTIONS_TESTS` covers the gate (every non-green checks value, an
  absent/blank/whitespace task id, a non-PR payload), the whole routing table, the
  `userInfo` round trip, that every action a category offers resolves to *something*, that
  a green tap reaches the real merge executor with the task id, and that Snooze 1h moves a
  real `ShiftStore` follow-up's persisted fields and survives a reload. **Confirmed to
  catch real regressions**: removing the gate (15 failures), turning Snooze into an Open
  (3), and dropping the lock gate (2) each reproduced named failures, then restored.
  **Not verifiable here, and not claimed:** real interactive delivery - there is no way to
  raise a live macOS banner and click its buttons in this sandbox.

## Morning briefing (F12, `fm/grandline-feature-f12-morning-briefing`)

The first *feature* from the production-readiness review's roadmap (section 25's
F12), after the four fix-side phases. One short generated paragraph atop
Overview on the first activation of the day, each clause deep-linking to the
page it came from. `MorningBriefingData.swift` owns what it says,
`MorningBriefingCard.swift` how it looks, `FleetController` when.

- **Off by default and off means nothing happens.** Settings > Morning briefing
  (`AppSettings.morningBriefingEnabled`). With it off,
  `FleetController.considerMorningBriefing` returns before reading a single
  input - no quota fetch, no `claude` call, and the card is a hidden *arranged
  subview* of an `NSStackView`, which leaves layout entirely (gotcha (11)), so
  the feature costs Overview nothing.
- **The local/AI split is the whole design, and it is `LogAnalyzerModels.swift`'s
  split applied to a second feature** (the review names it as the precedent).
  `MorningBriefingLocal.clauses(from:)` is deterministic, offline, and *always*
  computed first; its joined form is `statLine`, the plain summary the degraded
  card renders. `MorningBriefingAI` is one `ClaudeOneShot` call (GL-26's sixth
  caller - do not add a seventh subprocess path) that only rephrases those same
  numbers. Every failure - no `claude`, unlaunchable, timeout, garbled reply -
  falls back to the local clauses with `isDegraded` set and the real reason on
  the card's footnote, never to a blank card and never silently.
- **No new collection, enforced by the input type.** `BriefingInputs` is a flat
  struct of counts and short already-displayed titles; there is no field a
  terminal buffer or log line could travel in. Four of the five inputs are
  handed in by whoever already fetched them (Overview's own snapshot + merged
  PRs, the shared `ShiftStore`, `BackgroundSignalsPoller.lastCounts`); only the
  quota is fetched here, once per generated briefing, from the same
  `QuotaSource.fetch()` the Claude-usage popover uses.
- **`BackgroundSignalsPoller.lastCounts` is new and is why the briefing is
  cheap.** That poller already computes fork drift / tool updates / setup drift
  every 15 minutes for the Notification Center; it now records each result as it
  publishes it. Recomputing them from the briefing would have been ~50 fresh
  `brew`/`npm`/`gh api` spawns on the first Overview visit of the day. Every
  field is `Int?` - `nil` means "not computed yet this session", rendered as an
  *absent* clause, never a confident zero (GL-14's rule, one more signal).
- **Two things the model is not allowed to decide, enforced in code** (mirroring
  `LogAnalyzerAI`'s observed→inferred downgrade): a clause's `link` is matched
  against `BriefingTarget`'s raw values and anything unrecognised becomes
  `.none`, which renders as plain text rather than as a link that goes nowhere;
  and the colour comes from `BriefingTarget.tint`, so `BriefingClause` has no
  colour field at all. The `.tasks` deep link's task id is likewise resolved by
  the app from its own store (`BriefingInputs.singleDueTaskID`), never from an
  id a model wrote.
- **Deep links reuse the existing navigation, they do not add any.**
  `FleetController.onNavigateToDestination` is one closure over
  `RailDestination` wired to `AppShellController.show(_:)`, plus the existing
  `onNavigateToReview`/`onNavigateToSetup` and `openShiftTask(id:)`. The
  `.quota` clause opens this page's own `QuotaUsageController` popover,
  anchored on the briefing paragraph (Console used to also have a toolbar
  trigger for the same popover, gated to its herdr-attached "Mirror" tab -
  removed along with that tab by `fm/grand-line-remove-firstmate-mirror`).
- **Once per day survives a relaunch** because the generated briefing is
  persisted (`AppSettings.morningBriefingRecord`, JSON, the same
  one-cohesive-value convention as `dictationShortcut`) and keyed by
  `MorningBriefing.dayKey()`. Dismiss stamps the record rather than a separate
  flag; the clock affordance regenerates regardless of day or dismissal.
- **The paragraph is an `NSTextView`, and that is deliberate** - it is the only
  AppKit control giving inline link ranges with a click callback the app can
  intercept (a selectable `NSTextField` hands the URL to `NSWorkspace`). Two
  mechanics worth knowing before editing `BriefingParagraphView`: it drives its
  own height constraint from `NSLayoutManager.usedRect` inside `layout()` (with
  an epsilon guard, which is what makes assigning a constraint constant there
  converge), starting from a deliberately implausible 1pt so a broken
  measurement fails the self-test instead of looking like one line of text; and
  `linkTextAttributes` is set to the cursor only, because left at its default
  `NSTextView` paints the system link blue over the per-clause `HelmContrast`
  tint.
- **One deliberate deviation from the captain-approved mockup**, flagged rather
  than silently taken: the mockup titles the card "Good morning", which would
  sit a few points under Overview's own "Good morning, <captain>" header. This
  codebase has twice been corrected for that shape of duplication (Review's
  in-page hero, Docs' headings), so the card is titled "Morning briefing" and
  keeps the mockup's subtitle structure verbatim.
- **Verified** with `swift build` (clean debug and release, zero warnings in
  `Sources/FirstmateCockpit`), the release binary confirmed to carry no
  `FM_RUN_*` strings, and all 55 runnable suites passing - **without launching
  the app**, per the README's worktree rule. `FM_RUN_MORNING_BRIEFING_TESTS`
  covers the local layer, the unknown-is-not-zero rule, the prompt's contents,
  reply validation, the record/day key, the real `ShiftStore` due-item read, the
  degradation path through the real `ClaudeOneShot` against a fake `claude`, and
  the card's own rendering. **Confirmed to catch four real regressions**, not
  just to pass: treating an unreadable PR scan as an all-clear, not downgrading
  an unrecognised link marker, removing the clause cap, and a paragraph that
  never measures its own height.
- **Still open**: nothing about the AI *wording* is asserted (a model's prose is
  not a deterministic function of its input - the prompt's contents are pinned
  instead), and the briefing generated at launch runs before
  `BackgroundSignalsPoller`'s first pass (~10s in), so the drift clauses are
  absent on that first briefing of a cold launch and appear on a refresh.

## Answering the crew (F7)

**`fm/grandline-feature-f7-answer-crew-from-cockpit` closed the app's founding "act in one click" promise: a needs-decision task can be answered from Overview, without opening a raw terminal tab.** F7 of the production-readiness review (section 25). `FleetActions.swift` is the write half of Overview (`FleetData.swift` stays read-only); `FleetMessageComposer.swift` is the input surface; `FleetController+Reply.swift` is the page's own F7 UI; `FleetActionsSelfTest` / `FleetReplyLayoutSelfTest` are the coverage.

- **F7 originally shipped two channels; only one remains.** A reply *to a task* shells out to `bin/fm-send.sh <task-id> [--resolve-key <key>] "<text>"` through the shared `Subprocess` runner - firstmate's own **verified** submit (types once, sends Enter, retries only the Enter, reads back whether the submit landed); this is the channel everything below describes, and it is unaffected by anything that follows. A *general*, unaddressed "message the first mate" - reachable from Overview's header and ⌘K - used to go through `ConsoleController.sendToFirstmateMirror` → `TerminalView.send(txt:)` into the herdr-attached "Mirror" tab, since it had no task id for `fm-send.sh` to target. `fm/grand-line-remove-firstmate-mirror` removed that whole channel along with the tab it typed into (`sendToFirstmateMirror`/`FirstmateMirrorSendResult`, the header button, `AppShellController.sendToFirstmate`/`messageFirstMateFromMenu`, `FleetGeneralMessageOutcome`) - it had nowhere left to send once the tab was gone. `FleetActionsSelfTest`'s source guard (now named `checkFmSendCalledFromExactlyOnePlace`) still asserts `fm-send.sh` is named in exactly one file - a real, standing invariant on its own even with the second channel gone.
- **`fm-send.sh`'s exit status is a three-way contract, not zero-or-broken** - read that script's header before touching `FleetReplyOutcome`. `0` = confirmed; **`3` = the text was typed and Enter was sent but the submit read-back stayed unconfirmed** (not a failure, and explicitly *not* a reason to resend blindly); anything else = nothing may be assumed delivered. The three are reported to the captain differently on purpose, and the composer clears on 0/3 but **keeps the text on a failure**, which is the one case where retyping is pure loss.
- **`FleetStatusDecisions` is a narrow Swift port of `bin/fm-classify-lib.sh`'s `status_open_decisions` fold**, and the only thing this app takes from that library (`fm-crew-state.sh` is still the authoritative current-state read). The grammar is restated in its doc comment because getting it wrong is silent in the worst direction: `fm-send` **validates `--resolve-key` against the same ledger and refuses the whole send before typing anything**, so a key this app believes is open but firstmate does not means the captain's answer never leaves the app. Worth remembering from that grammar: a `[key=…]` token may sit before the colon *or* at the head of the note (both state the key; the before-colon one wins and strips), a token deeper in the note is prose, an invalid slug **skips the line rather than falling back to `default`**, `default` is itself a real closable key, and the reserved `pending-reply-` namespace only moves for a line speaking its own vocabulary.
- **`--resolve-key` is passed only when exactly one decision is open** (`FleetActions.resolveKey(among:)`). Two open is genuinely ambiguous and closing the wrong record is worse than closing none - the composer's caption says so rather than picking one. The key is re-read at composer-open and again at send time, never from the snapshot the page last rendered.
- **`AppLockedSurface.crewReply` (GL-09) gates the reply channel** (it gated the removed general-message channel too, before that channel existed). Not reachable by a walk-up today (the reply composer sits under the lock overlay) - the case exists because of *what* it does: it is the app's one remaining write into the captain's running agent session, and the gate is where that coverage is single-sourced and assertable.
- **Overview grew a "Needs your call" section.** Before F7 the needs-decision/blocked tasks were only *counted* by the banner - "In flight" lists working crew only. The new section is the same plain-heading-over-`HelmAccentRow`-cards shape, with each row's Reply button in the row's `trailingAccessory` and the composer inserted as the next arranged subview of the same stack (expand-in-place, per the mockup). An open composer survives a re-render, so a background refresh cannot discard a half-typed answer. It keeps its own `needsAccentRows` list rather than joining `accentRows`, which `render` clears - these rows are also rebuilt whenever a composer opens or closes.
- **No AI anywhere in this feature.** The reply is byte-for-byte what the captain typed; `FleetActionsSelfTest` asserts the message reaches the script as one unmodified argument, including text that merely *mentions* `--resolve-key`.
- **⌘Return sends, plain Return inserts a newline** - the opposite of `SRELeadChatView`, deliberately: an answer to a parked decision is often a paragraph, and losing it to a stray Return is the worse failure. Matches the six editor sheets and the Console composer.
- **Verified with `swift build` (debug and release, zero warnings in this app's sources), the release binary carrying no `FM_RUN_*` strings, and all 62 runnable suites - without launching the app**, per the README's worktree rule. `FM_RUN_FLEET_ACTIONS_TESTS` is pure logic and runs in CI; `FM_RUN_FLEET_REPLY_LAYOUT_TESTS` mounts a real off-screen `FleetController` and drives real `NSButton` clicks, so it is in `run-all-tests.sh`'s `NEEDS_SESSION` list. **Both were confirmed to catch real regressions**, not merely to pass (collapsing exit 3 into success, guessing a key when several are open, reordering the argv, a fold that rewrites an invalid slug to `default`, a general message routed through `fm-send.sh`, a composer that stops expanding in place, and a refresh that discards it). **The layout suite also found a real shipped-in-progress bug on its first run**: the general composer activated a constraint against a label it never adds to the tree when there is no address line - a hard "no common ancestor" AppKit exception that took the whole process down, and exactly the class of defect `swift build` cannot see.
- **`fm-send.sh` itself is never run by a self-test** - it resolves a live crewmate endpoint and would steer a real crewmate in the captain's actual fleet. `FleetActions.sendScriptOverrideForTests` points at a disposable recording script instead (the same seam `DictationCleanupSelfTest` uses for `claude`), so the subprocess plumbing, argv and outcome mapping are genuinely exercised while the script's own verified-submit behaviour is not. A real end-to-end send is the captain's own check.

## One definition of "ready to merge"

**`fm/grandline-ready-to-merge-count-mismatch` fixed the UI modernization audit's one *functional* finding (kept separate from §3A-§3M's design work, as the captain asked): the phrase "ready to merge" was answered by three genuinely different questions, each computed independently, so any two surfaces could disagree in one frame without either being wrong on its own terms.** Read `FleetDataSource.readyToMerge`'s own doc comment before adding a surface that says those words.

- **What the captain saw, and why neither number was a bug on its own.** One Review screenshot: the drill subtitle read "50 open - 0 ready to merge" (counting `canMerge`) while its own stat tile a few inches below read "34 ready to merge" (counting bare `checks == "green"`). Minutes later Overview's greeting said "50 PRs ready to merge" against Fleet's banner saying 0. **Nine surfaces rendered the phrase and three definitions answered it** - `canMerge` (green *and* task-assigned), `checks == "green"`, and the raw open count - which is why every individual call site read as correct in review.
- **`canMerge` is the definition that survives, and the reason is the merge action rather than taste.** A PR with green checks but no tracked task has no working path through `bin/fm-pr-merge.sh` (GL-38 - the script validates the task id before it will touch anything), so calling it "ready to merge" is a claim this app cannot honour. `FleetDataSource.readyToMerge(_:)` / `readyToMergeCount(_:)` sit beside `canMerge` and delegate to it; every count-shaped caller reads them, while the per-row *gate* keeps calling `canMerge` directly (singular vs. collection, not two definitions).
- **Six call sites changed, and two of them were already right - which is the finding in miniature.** `ReviewController`'s tile, `FleetController`'s banner + tile + morning briefing, and `HomeCanvasController`'s hero were re-derived; Review's subtitle, the canvas merge-queue card and `FleetNotifier` already used `canMerge` and now route through the shared function so the set cannot drift again. **`FleetController.render` pushes the *same* `mergedPRs` array to the banner, the tile and the canvas**, so before this the canvas could render "50 PRs ready to merge" in its hero and "none ready" in its merge-queue chip off one array in one frame - a tighter reproduction than the audit itself found.
- **`onOpenPRCountChanged` is `onReadyToMergeCountChanged`, and that is a behaviour fix rather than a rename.** It fed `NotificationSources.setPRReady`, which titles its entry "N PRs ready to merge", marks it `.actionNeeded` and says it "clears when merged" - while being handed the *open* count. A captain with fifty open red PRs was told all fifty were waiting to be merged.
- **A doc comment claiming an invariant is not an invariant.** `drillHeaderSubtitle`'s own comment said the header, the tiles and the Merge buttons "can never disagree about how many PRs are ready" - and they did, in one screenshot, because only two of the three routed through the gate. Sharing a *function* is what makes that claim true; sharing an intention did not, and the comment now says so rather than restating the promise.
- **`FM_RUN_READY_TO_MERGE_TESTS`** is window-backed (it mounts the real Review page, the real Overview page and the real canvas) so it joins `run-all-tests.sh`'s `NEEDS_SESSION` list. Three lessons from writing it:
  - **The fixture asserts its own discriminating power before it asserts anything else.** Six PRs chosen so the three old definitions return 6 / 3 / 2; if they ever coincide the whole suite passes against the bug, so a mismatch fails loudly rather than silently proving nothing.
  - **It reads the numbers off the *rendered views*** (`HelmStatTile.debugMetric`, `HelmAccentRow.debugMetaText`, `ReviewController.debugStatTiles`, `FleetController.debugBannerMeta`/`debugRender`), parsing the integer out of the real sentence. A check that recomputed the count would agree with itself forever and is blind to the failure that actually shipped - a surface that stopped calling the shared function.
  - **A behavioural check cannot see a filter nobody has written yet**, so a source guard bans a re-derived `checks == "green"` outside `FleetData.swift`. Use `SelfTestSources.appSourceFiles()` (non-recursive) rather than a recursive walk: this suite's own fixture computes the old definition on purpose, and a recursive scan flagged that line. **Four injected regressions each reproduced by name**, including the audit's exact screenshot ("subtitle '6 open - 2 ready to merge' beside a tile reading 3 - two numbers under one label, in one frame") and a brand-new surface bringing its own filter.
- **A hazard this task walked into, already documented and worth restating: `git checkout -- <file>` on a branch with no commits yet discards the whole task's changes to that file**, not just the experiment you were undoing. Reverting a scripted injection silently took a doc fix with it. Copy the file aside first (`cp` to a scratch path) and restore from that, or re-apply the intended edit by hand.

## A hub summary card and its own detail page (`fm/grandline-engineering-cards-stale-counts`)

**The captain updated every tool and synced every fork by hand, and the Engineering hub went on reading "3 updates" and "6 behind, of 8 tracked" while the Updates page one click away read "13 tools - all up to date" and GitHub Sync read "8 forks - all in sync".** Read `BackgroundSignalsPoller`'s "The one published count per signal" section before touching any of this.

- **The cause was duplication, not a missing refresh, and that distinction decided the fix.** `BackgroundSignalsPoller.lastCounts` was a private snapshot only that poller's own 15-minute pass could ever write; each detail page independently recomputed the very same fact from a real check and kept the answer to itself. Two computations of one number with no way for the fresher one to win - so returning to the hub did not help (it re-renders on `viewWillAppear`, from the same stale snapshot), and nor did anything else short of waiting out the poll.
- **Five cards were affected, not the two the captain named**: Updates, Bootstrap, Automation, GitHub Sync (Engineering) and **Vault** (Stores) all render `lastCounts`. Settings reads only `lastCompletedPassAt` ("has a pass ever run"), which cannot go stale this way.
- **The notification bell was wrong for the same reason, and is fixed by the same change.** `NotificationSources.setToolUpdates`/`setGitHubSync`/`setVaultAttention`/`setSetupDrift` had exactly one caller each - the poller - so the badge in the captain's own screenshot was counting things he had already fixed. Every publish now goes through one path that updates the count *and* the notification entry.
- **The fix: one count per signal, derived in one place, from whatever the freshest known raw outcomes are.** Deliberately **not** a second mechanism reconciling two counts. Each producer - the poller's own pass, and each detail page at the single choke point its status changes already funnel through (`UpdatesController.renderStats`, `GitHubSyncController.render(_:)`, `BootstrapController.refreshStepperVisuals`, `AutomationController.rebuildStepper`, `VaultController.renderAll`) - hands over the **raw outcomes it just learned** and lets `BackgroundSignalsPoller.publish*` do the counting. **A page never computes a count, so a page can never disagree with the hub about how to count**, only about when.
- **This is a convention the app already had; the five poller-backed cards were the ones that never adopted it.** `FleetController.onSnapshotChanged` and `ReviewController.onOpenPRCountChanged` have always pushed their own freshly-computed state to the hub and to the notification center. Checked before designing anything - the Fleet, Merge queue, Tasks, Hosts, Schedules, Runbooks, Postmortems, Code Preview, Command Library, Health, Docs and Sticky Board cards all read a live shared store or a pushed snapshot and were already correct.
- **Three rules the publish surface enforces, all of them GL-14's, all in one place.** A sweep still in flight publishes nothing (mid-check statuses are not an answer, and "0 updates" while 13 checks run is a confident claim about an answer nobody has yet); an all-`.unknown` set publishes nothing (a freshly built page must not stamp a zero over a real number the poller established at launch); and a degraded `av` read leaves both vault counts exactly as they were (B1). `nil` from a derivation means "no publishable count", which leaves the previous one standing.
- **A publish carries when its data was *gathered*, not when it was published, and an older reading never displaces a newer one (`acceptsReading`).** This is not caution: a pass spends tens of seconds gathering (13 `brew`/`npm` checks, then 8 `gh` checks, then `av`, then a `git fetch`) and only publishes at the end, so a captain who resolves something during that window would otherwise watch the hub go correct and then stale again seconds later - the reported bug, reintroduced through the back door. Per-signal high-water marks, because a pass's fork check being outrun says nothing about its tool check.
- **A hidden page does not publish.** Bootstrap and Automation publish one shared `setupDrift` signal, and a mounted-but-hidden page is re-rendered by ordinary events (a theme change, a font-scale change) off state that can be older than the poller's own last sweep. The gate encodes the invariant worth having: **the hub agrees with what the captain last actually saw on the detail page.**
- **`FM_RUN_SUMMARY_FRESHNESS_TESTS`** (window-backed - it mounts a real shell and drives the real pages, so it is in `run-all-tests.sh`'s `NEEDS_SESSION` list) drives the captain's own scenario end to end per signal: seed a stale count, confirm the hub renders it, drive the **real** page's choke point, confirm the card moved. It drives the choke point (`debugApplyStatusesAndRender`) rather than the publish method deliberately - **a test that called `publishToolStatuses` itself would pass with the page's wiring deleted, which is exactly the bug.** Confirmed to catch three real regressions by scripted revert (never `git stash` - see this file's own warning about the shared stash stack): removing either page's wiring reproduces the captain's screenshots **verbatim** (`'3 Ready to install from the Updates page. 3 updates'`, `'6 Behind upstream, of 8 tracked. 6 behind'`), and removing the freshness guard reproduces the mid-pass overwrite.
  - **A freshness fixture has to model a real gap, and a bare `Date()` pair is not one.** That last case captured "the pass started" with `Date()` microseconds before the publish it had to lose to - and two `Date()` calls that close can return the *same* instant, which `acceptsReading` accepts by design ("at least as new"). Measured: **1 spurious failure in 6 runs**, on an unchanged binary. The fixture's own doc comment already said what it should have been doing - "a pass spends tens of seconds gathering" - so the fix is `addingTimeInterval(-30)`, which both removes the flake and makes the case model the scenario it describes. Re-confirmed it still catches the removed guard deterministically afterwards: **a fixture made non-flaky by weakening what it asserts is the worse bug.**
- **Checked and deliberately left alone, each a materially different mechanism**: `ShiftNotificationScheduler`'s due-items badge (a 60s poll over the live shared `ShiftStore` - self-heals within a minute, not a private snapshot); the morning briefing (a once-per-day generated record by design, and it reads `lastCounts`, so it now gets fresher inputs for free); and `BackgroundSignalsPoller` bypassing `DependencyCheckCache` for its own 13-item sweep (a real redundancy - the poller's results never populate the shared cache the three Setup pages read - but an efficiency and freshness-contract question, not the correctness bug, and changing the poller's cost profile was outside what this task was confident bundling).

## The poller shares the dependency sweep too (`fm/grandline-poller-dependency-cache-bypass`)

**`BackgroundSignalsPoller` was the one reader of `DependencyCatalog` that never shared anything with the other three: it called `UpdatesSource.check` directly on its own 15-minute cadence, so a captain who opened Updates and then sat still paid for the identical 13-item `brew`/`npm` sweep twice within minutes.** Found and deliberately deferred by PR #395's own stale-cards fix, filed by the captain as its own cleanup. Read `BackgroundSignalsPoller.sharedCheckMaxAge`'s doc comment before touching any of it.

- **The interesting half is not "route it through the cache" - it is that the obvious routing is wrong in a way every behavioural check would miss.** Reading through `DependencyCheckCache` at its `defaultTTL` (15 min, what the three Setup pages use) lets **one poller pass be satisfied by the previous poller pass**: an entry is stamped when its check *finishes*, so an item checked 40s into a sweep is only `pollInterval - 40s` old when the next tick lands - fresh under a 15-minute window. The poller would then publish 15-minute-old counts and skip the sweep entirely, alternating real/no-op passes and silently halving its own cadence to 30 minutes. `sharedCheckMaxAge` (5 min) is sized below `pollInterval - passWatchdog` (10 min), the worst case being an entry written by the last item of a sweep that ran right up to the watchdog. **`FleetTaskCache.ttl` is sized against the same trap in reverse** and its guard (`AuditEnergyFixesSelfTest.test_35_shorterThanPoll`) is the precedent this one copies: assert the *relationship* between the window and the poll, never the literal.
- **The stated price: the poller's published counts can now be up to `pollInterval + sharedCheckMaxAge` (20 min) old rather than 15.** Inside the envelope this file's own header already accepts for a backgrounded app, and the publish carries the honest `gatheredAt` either way.
- **`DependencyCheckCache.checkDated` exists because of PR #395's freshness rule, not for convenience.** A publish carries when its data was *gathered*, and `acceptsReading` refuses a reading older than the published high-water mark - so a partly-cached sweep is a mixture of vintages, and stamping the whole thing `Date()` claims it is as new as its newest half. That would let a poller pass overwrite a page's genuinely fresher number: the exact bug #395 closed, reintroduced through the cache. `sweepSoftware` therefore stamps the **oldest** contributing sample. The three pages deliberately do not use `checkDated` - each renders rows as it has them, and `publish*` already defaults to `Date()` for that case.
- **`sweepSoftware(cache:items:)` is extracted with both collaborators defaulted so a self-test drives the REAL function.** The pass's other three checks (`gh`, `av`, a dotfiles `git fetch`) have no such seam and are never driven from a suite; re-implementing the sweep's policy in a test instead would have proven nothing about the policy that ships.
- **A self-test lesson this cost a round to learn, and it generalises past this feature: a counting fake cannot see a regression that stops calling the fake.** Both dedup cases asserted "the real check ran exactly 13 times" against `DependencyCheckCache.checkOverrideForTests`' counter - and the *original bypass*, reinstated verbatim, passed both, because `UpdatesSource.check` never touches the fake and the count stayed at the page's own 13. The discriminating assertions are about provenance rather than volume: the poller's returned statuses must be **the ones this cache holds**, and the poller's sweep must have **left an entry** for every item (asserted *before* the page runs - checking only the total afterwards passes against a poller that wrote nothing, since the page would simply run all 13 itself).
- **A source guard covers the wiring the behavioural cases cannot**: `sweepSoftware` could be perfect while `checkNow` swept some other way. Confirmed by injection - a `checkNow` rewritten to call `DependencyCheckCache.shared.check` at the pages' default TTL (i.e. correct-looking, cache-using, and cadence-halving) is caught only by that guard. It strips whole-line `//` comments first, since the file names `UpdatesSource.check` in order to explain that it no longer calls it.
- **Two adjacent direct callers were deliberately left alone, and widening to them would be wrong rather than merely out of scope.** `ScheduleRunner`'s `toolUpdateCheck`/`toolUpdateInstall` are captain-scheduled "check now" actions, semantically a forced refresh - and the install arm mutates the toolchain, so its own check results are stale the instant it finishes. `VaultData.checkInstall` is one item on a different page.
- **Verified** by `swift build` (clean debug and release, zero warnings in this app's sources), the release binary confirmed to carry no `FM_RUN_*` strings or the new symbols, and the full `./Scripts/run-all-tests.sh` run (147 passed / 0 failed / 1 documented skip, `fm.themeID`/`fm.fontSize` unchanged) under the documented `dusk` pre-flight - **without launching the app**, per the README's worktree rule. **Four injected regressions each reproduced by name** (scripted file copies, never `git stash`): the original direct-`UpdatesSource.check` bypass, the window widened to `defaultTTL`, `gatheredAt` stamped `Date()`, and `checkNow` unwired from `sweepSoftware`.

## The Claude status strip on Home (`fm/grandline-claude-status-card-implement`)

A Claude quota readout as a real card on the Home canvas, and the second
reader of the `quota-axi` call this page's Morning briefing was already
paying for.

**Where it came from.** `data/grandline-claude-status-widget-lavish/` is the
design exploration: five style mockups, built in real Daylight/Dusk token
values, rendered in real Home-canvas chrome.
The captain reviewed them and picked style 3, "Status strip" - one dense row
of five hairline-separated columns - with "we can start implementing this".
That report also did the data investigation, and its headline finding held up:
every one of the five figures is already in the output of a command this app
runs today, so no Anthropic Admin API, no new credential class and no second
integration were needed.

**One correction to the report, measured rather than assumed.** It recorded
the command as `quota-axi --json --full --provider claude`.
All four windows come back **without** `--full`, which is what
`QuotaSource.fetch()` already runs - so the argv is unchanged and this feature
added no new subprocess work at all.

### The two labelling decisions

Both were implicit in the mockup the captain picked, and both are decisions
about what the data does *not* say.
They are asserted as prohibitions in `ClaudeStatusCardSelfTest`, not only as
expected strings, because a future edit that "tidies" a label would
reintroduce exactly the claim they exist to avoid.

- **"Session (5h)", never "Daily".** Claude's quota has no daily window and
  `quota-axi` reports none. The window is `five_hour`, which the tool itself
  labels `session`. "Daily" would name a reset cadence that does not exist.
- **"Extra usage" / "Spend cap", never "MTD spend".** The window's id is
  `extra_usage` and its kind is `credits` - an extra-usage credit pool against
  its own cap, not organisation month-to-date spend. `quota-axi` returns
  `pace: {status: "unknown", reason: "missing_cycle"}` for it, so it does not
  know the billing cycle's boundaries and nothing derived from it may honestly
  say "month to date". True org MTD spend would need the Admin/Usage API and
  an Admin key.

### The data layer

`QuotaSource.parse`'s `switch id` used to drop `model:fable` and `extra_usage`
through `default: continue`; its own doc comment named them as the things it
ignored. Both are parsed now.

- `QuotaWindow.Kind` gains `.fable`. The Fable window has the same shape as
  the other two, so it is the same type.
- `extra_usage` is a **sibling type** (`QuotaCreditWindow`), not a
  `QuotaWindow` with unused fields: it is measured in dollars, has no
  `resetsAt` in the real output, and its pace is permanently `unknown`.
- **A real shape variant the live output alone would not have shown.** The
  popover's own long-standing live fixture in `QuotaDataSelfTest` carries an
  `extra_usage` with `spentUsd` and **no** `percentRemaining` and **no**
  `limitUsd` (`pace.reason: "missing_usage"`). The first parse required
  `percentRemaining` for every window and silently dropped this one. So
  `QuotaCreditWindow.percentUsed` and both dollar figures are independently
  optional, and `extra_usage` is handled before that guard. The account this
  was developed against happened to send all three, which is exactly why the
  fixture rather than the live call is what caught it.
- **`QuotaSeverity` is new, and is the one copy of the 80/90 decision.** Those
  thresholds were specified in the Claude-usage popover's own review and lived
  only inside `QuotaUsageWindowRow.tint(for:)`. The strip needs the same
  verdict in a different vocabulary (`HelmModuleRowState` rather than
  `HelmTint`), and two surfaces reading one number must not be able to
  disagree about whether it is a warning. Both map from the enum now.

GL-14 runs through all of it: every column is independently optional, and an
absent window renders "Not reported" in the muted face with no track - never a
`0%` or a `$0`, which on a quota readout are real and alarming values rather
than synonyms for "unknown". The Fable window's own live reading is
genuinely `0%` used, which is the clearest possible reason the two must look
different.

### The card

`HelmModuleCard.Body` gains `.statusStrip([HelmModuleStripColumn], perRow:)`,
and `DaylightModule` gains `.claudeStatus` - Overview-only (it has the same
"no other home" property as the briefing, the fleet board and the Straw Hat
card), span 2, opening `.console` where the Claude-usage popover lives.

- **`maxStripColumns` (5) is `maxPeekRows`' horizontal twin**, capped for the
  same reason and enforced the same way.
- **Equal columns are a declaration, not a hope** (AGENTS.md gotcha (10)). The
  column stacks are tied to one another explicitly at `contentTie` (499).
  Removing those ties was one of this task's regression injections and
  reproduced the trap exactly: columns ranged **33pt to 239.5pt** against a
  uniform 98pt, with the long dollar figure taking the slack.
  `.fillEqually` is not usable on the strip itself because the 1pt hairlines
  are arranged subviews too and would be divided equally along with the
  columns.
- **Cross-row ties need the container to exist first.** The wrapped form
  activates width constraints between columns in *different* row stacks, which
  throws "no common ancestor" unless the vertical stack is built first. Caught
  by `DaylightModuleSelfTest.checkUniformCardHeight`'s own new
  `statusStrip-1col` case, as a crash rather than a failure, on the first run
  after it was added.

### The height caveat, which turned out not to be one

The design report flagged style 3 as ~104pt - shorter than a module card - and
expected it to need a grid restructure to keep
`DaylightModuleSelfTest.checkUniformCardHeight` passing (a dedicated
non-uniform-height allowance, a filler element, or similar).

**It needed none, and the reason is that the report was reading a rule that
had already been replaced.** Full review #3's PF2 had removed the fixed card
height: `HelmModuleCard` now sizes to its content above a `minimumHeight`
floor (124pt base), and `HelmResponsiveGrid`'s `equalHeights` makes a *row*
uniform rather than the whole canvas. So the strip simply sits on the floor,
exactly as the `.note` body every other one-line card uses already does, and
reads as deliberately compact rather than as a card that was cut off.
Measured: 124.0pt, body needing 46.0pt of 49.0pt.

The only guard that genuinely had to change was
`checkUniformCardSizing`'s `wide == [.briefing]` literal, which is a
deliberate two-place table edit of exactly the kind that literal exists to
force.

**What the two wide cards do differently when the grid narrows.**
`HelmResponsiveGrid.packRows` degrades a span-2 card to one column, where five
keys in 255pt would each truncate to an initial. The briefing *cuts clauses*
there (`briefingClauseCap`). The strip instead **wraps** into aligned rows
(`claudeStripColumnsPerRow`), so a narrow window costs the card height and
never costs it a reading - measured at 179pt with all five columns intact.

### Two bugs this task's own verification found

Neither was reported by a captain; both would have shipped.

- **The card's reading was gated on a feature that is off by default.** It was
  first fed from the quota fetch the Morning briefing already paid for. That
  fetch happens *inside* `considerMorningBriefing`, which returns early when
  the briefing is disabled (it is off by default) **and** again when one has
  already been generated today. So the card would have shown its loading
  skeleton forever on a machine with the briefing off, and on every launch
  after the day's first briefing - which is most launches.
  The reading is `FleetController`'s own now (`refreshQuota`, taken by the
  refresh pass, behind a five-minute freshness window so `viewWillAppear`
  cannot spawn `quota-axi` per visit), and the briefing is one of its two
  readers rather than its owner.
  `ClaudeStatusCardSelfTest.checkTheReadingIsNotGatedOnTheBriefing` is a
  source guard, because the behaviour needs a mounted Fleet page and the
  failure is a call site moving rather than a function misbehaving.
- **Two modules opening one destination made Console's Recents kicker read
  "Home".** `DaylightModule.space(forDestination:)` took
  `allCases.first { $0.opens == dest }`, and `allCases` is declaration order -
  so `.claudeStatus`, declared before `.console` and also opening it,
  shadowed Console's own space. Caught by
  `RecentDestinationsSelfTest.kindPropertiesForRailAndHost` in the full run.
  The lookup now prefers the module with a real `space` (an Overview-only
  module that merely deep-links elsewhere does not own that destination),
  which makes it independent of declaration order rather than dependent on
  where the new case happened to be put.

### Verification

- `ClaudeStatusCardSelfTest` (`FM_RUN_CLAUDE_STATUS_CARD_TESTS`) is
  window-backed and listed in `NEEDS_SESSION`. The column mapping alone is
  pure logic, but "the five columns are actually painted, equally wide and
  legibly, in both registers" is not. It renders in real Daylight and Dusk and
  reads a real rasterised pixel back, following both of AGENTS.md's
  `bitmapImageRepForCachingDisplay` rules (sample in `rep.colorSpace`; scale
  points into pixels).
- `QuotaDataSelfTest` grew the two new windows, the absent-window case and the
  `QuotaSeverity` boundaries.
- **Five regression injections, each confirmed to fail the named case**:
  removing the `model:fable` parse arm (3 parse checks), rendering a stated gap
  as `0%` (the GL-14 case, by name), renaming the labels back to "Daily" /
  "MTD spend" (the prohibition case), removing the equal-column ties (the
  geometry case, with the 33pt/239.5pt spread above), and moving
  `refreshQuota()` back under the briefing gate (the ownership guard).
- **Not verified**: no live visual check by the captain, and none was claimed.
  This machine's agent shell has neither Screen Recording nor Accessibility
  permission, so the evidence here is real off-screen renders and real layout
  geometry rather than a screenshot - AGENTS.md's "Verifying native UI bugs
  without a real screenshot" convention.

## Rebuilding the panel to the captain's reference (`fm/grandline-notification-center-redesign`)

The captain hand-picked a complete HTML/CSS/JS reference for the "Waiting for
you" popover and asked for it to be matched closely - "keep the UI almost the
same". It is saved at
`data/grandline-notification-center-redesign/captain-reference/` (firstmate's
own repo, not this one), with the real screenshot beside it.

Two elements were struck out by name: the footer's **Settings…** and **Reset
demo** buttons. Everything else was to be built.

### What the reference is actually about

Not the pixels. The panel it replaced listed every entry as one equal row with
one dot and a sentence explaining how that row clears. The reference sorts by
*what the captain has to do*, puts one real action on every row, and hides the
explanation until it is asked for. So the rebuild is an information-architecture
change with a visual one following it:

- **Two tiers.** "Needs action" above "Available", which is the store's own
  `AppNotificationKind` given a visible name rather than a second
  classification the two could drift apart on.
- **An inset hairline** between rows *inside* a tier, starting at the text
  column the way `NSTableView`'s inset style reads - a full-width rule between
  every row makes a popover read as a form.
- **A per-source colour tile**, so the list is scannable by shape and colour
  before it is read. Painted from this app's own `HelmTint` tokens against the
  live theme, never the reference's literal hexes.
- **The blue dot demoted** to meaning unread and nothing else.
- **The timestamp swaps for the row's action** on hover and on selection.
- **Rows with sub-items expand in place** - tools, forks, drifted checks - each
  child carrying its own action, over the "clears when…" line that used to be
  crammed into every row's subtext.
- A segmented **All / Needs-action** filter with live counts, a right-click
  menu (snooze 1h, snooze until tomorrow, read/unread, copy, mute source), a
  toast-and-undo footer, and an empty state.

### What was kept rather than replaced

The reference's own AppKit note suggests `NSPopover` plus an `NSOutlineView`.
Neither was adopted, and the brief allowed for that: the chrome is a
`HelmBarPanel` for the reasons B5 already recorded, and the list stays an
`NSStackView` of rows because it is small by design. Replacing two working
mechanisms to arrive at the same pixels would have bought nothing.

### What the store grew, and what it did not

`GrandLineNotificationCenter` gained three captain-facing states, and **none of
them is a clearing semantic**. `stored` holds everything the sources have
published; `entries` derives what is visible from it.

- **Read state** (the dot), keyed by the exact subtext on `dismissedDetail`'s
  own precedent - a row whose detail moves on after being read goes back to
  unread rather than hiding new information under a cleared dot.
- **Snooze**, which expires on its own with no source involved. That only works
  because visibility is recomputed rather than remembered, which is why
  `entries` is a computed property.
- **Per-source mute**, session-scoped. A mute that outlived a relaunch would be
  a setting, and this app has a Settings page for settings.

`markAllRead()` now means what it says everywhere else in macOS: the dots go
out and every row stays. The old behaviour - dismiss every informational entry,
with its resurface-on-change rule - is unchanged under the name
`dismissAllInformational()`, and its contract is still the thing
`GrandLineNotificationCenterSelfTest` covers most closely. Nothing in the UI
reaches it today; it stays because deleting the bulk form would leave that
contract half-tested.

`AppNotification` grew `source`, `clearCondition`, `date`, `timeText`,
`isWarning`, `children` and `primaryAction`, all defaulted so the twelve
adapters in `NotificationSources.swift` could be moved over one at a time.
**`date` is excluded from `==` on purpose**: every source republishes its own
freshly-computed truth on every poll, so a date that counted towards equality
would make each pass look like a change - re-notifying every observer,
re-marking a read row unread, and resetting "3h ago" to "just now" every
fifteen minutes.

### Where the children come from

The reference's `initialItems()` is sample content, so the expandable rows are
wired to the real sources. `BackgroundSignalsPoller`'s three publish methods
take an optional `children` list beside the statuses they already took:

- **Updates** and **GitHub Sync** can only be supplied by their own pages,
  which hold the names and version pairs the poller's cached reading does not.
  Each child carries that page's own per-row action as its `perform`, so a tool
  updates or a fork syncs without leaving the popover. `UpdatesController`
  gained `updateAllPending()` for the row's "Update all" - serial, matching
  `GitHubSyncController.syncAll` and `AutomationController.installAllMissing`,
  because this app's standing rule is that two external-tool invocations never
  race.
- **Bootstrap**'s drifted steps name themselves out of the `[SetupStepKind:
  Bool?]` the poller is already handed, so neither setup page changed.

A source with no children renders without a disclosure triangle rather than
with an empty one, which is the honest rendering of "this reading has no
per-item detail".

### Undo, and where it is withheld

The reference offers Undo on everything. This follows GL-33 instead: Undo is
offered where a real restore exists (mark read, mark all read) and withheld
where it does not (an update or a sync that has already started). A pretend
Undo beside a running `brew upgrade` is worse than none. Snooze and mute have
no toast Undo either - the footer's own "N snoozed" is their restore, and it is
a standing control rather than one that fades in four seconds.

### Two real defects, both found only in a render

Neither was visible in the code or in any passing assertion.

- **A wrapper view ate the text column.** The timestamp and the action button
  started life as two children of a `trail` container. A plain `NSView` has no
  intrinsic size, so neither a content- nor a stack-priority API decides its
  width (AGENTS.md gotcha (12)), and nothing tied its leading edge - so it
  absorbed the row's slack and squeezed "Renew staging wildcard certificate"
  down to "Renew staging wild…" with 100pt of empty space beside it. The two
  are siblings of the row now, each pinned to the disclosure triangle, and the
  text column is bounded by **both** so it does not reflow on hover.
- **A capped child column truncated by accident.** `text.trailing <= button.
  leading` let the stack's width come from whichever of its two labels Auto
  Layout settled on: "helm" over "3.1…" in the same row where "kubectl" over
  its full version pair fitted. An equality makes the column definite and every
  child truncate the same way.

### Verification

- `NotificationCenterRedesignSelfTest`
  (`FM_RUN_NOTIFICATION_CENTER_REDESIGN_TESTS`) is window-backed and listed in
  `NEEDS_SESSION`: a `HoverHighlightView`'s tracking area is
  `.activeInKeyWindow`, so the hover-reveals-the-action swap - the thing the
  reference is built around - cannot be asserted outside a key window. Ten
  cases: the two tiers, the hover and selection swap, expand/collapse with
  per-child actions, the context menu per read state, the absence of the two
  struck buttons, the inset hairline's real x against the title's real
  alignment rect, the filter's counts and both empty states, the toast and its
  Undo, the four key bindings, and a real rasterised render in both registers.
- **Six regression injections, each confirmed to fail the named case**:
  flattening the two tiers, deleting the `onHoverChange` wiring, making the
  disclosure a no-op, making the menu always say "Mark as read", adding a
  "Settings…" button to the footer, and un-insetting the hairline.
- **One check could not fail and was rewritten.** `debugSetHovering` called
  `setActionVisible` directly, so deleting the entire `onHoverChange` wiring
  left it green - it was asserting the private helper rather than the hook that
  reaches it. It goes through `HoverHighlightView.mouseEntered`/`mouseExited`
  now, and the injection fails as it should. A crash found the same way
  (`children[1]` on an empty list) is a guarded `fail(...)`, because a crash
  reads as a broken suite rather than a broken assertion.
- **Four existing suites failed and all four were right to.**
  `NavigationCoherenceSelfTest` caught `source: "Overview"` - the Fleet page is
  called Fleet, and "Overview" names the daily review page and nothing else.
  `AuditEnergyFixesSelfTest` caught the toast timer with no tolerance.
  `FeedbackModernizationSelfTest` and `DaylightChromeSelfTest` each encoded a
  contract the redesign deliberately reverses (G2's "one kind needs no header",
  and "Mark all read" meaning dismiss); both were rewritten to the new contract
  with the reasoning recorded at the check.
- **Not verified**: no live visual check by the captain, and none is claimed.
  The evidence is real off-screen renders of the real panel in both registers
  plus real layout geometry - AGENTS.md's "Verifying native UI bugs without a
  real screenshot" convention - not a screenshot of the running app.

## A Refresh on the Claude card, and the briefing's quota clause removed (`fm/grandline-claude-card-refresh-and-color-fix`)

**Two captain requests against the same reading, one of which turned out not to
be a bug.**

### The reported colour bug was not one

The captain's first screenshot showed "Fable week 100%" painted red and read it
as inverted - 100% of the allowance still *available*, shown as an alarm. He
retracted it himself a few minutes later: a second screenshot, after he
refreshed the page, showed the same window green at 0%.

The logic was checked end to end anyway rather than taken on the retraction.
`QuotaSeverity.init(percentUsed:)` is `> 90` critical / `>= 80` warning / else
comfortable, over **percent used** - `QuotaSource.parse` converts
`quota-axi`'s `percentRemaining` to "used" once, at the parse boundary - and
every call site in `HomeCanvasController.claudeStripColumns` reads it that way,
with `fill: percentUsed / 100` running the bar in the same direction. So a
window with none of its allowance spent is comfortable and green, and one with
all of it spent is critical and red. **Nothing was changed.**

What the captain actually saw was a stale first paint: the card renders from
whatever reading `FleetController` last published, that reading is cached for
five minutes (`quotaFreshness`), and until this task there was no way to ask
for a new one from the card. The Fable window really had been at 100% used when
the reading was taken.

The confirmation is permanent rather than a note here.
`ClaudeStatusCardSelfTest.checkSeverityIsNotInverted` asserts the six threshold
boundaries and then renders a fabricated 0%-used and 100%-used snapshot in a
real window, in both Daylight and Dusk, and reads the **painted** track back -
the layer colour and the fraction of its bed the fill actually covers. Both
halves matter: a bar painted the right colour and filled the wrong way round
would still read as inverted. It checks that `.ok` and `.bad` resolve to
different colours in the palette first, so a theme that painted both the same
fails loudly instead of passing vacuously. `HelmModuleCard.Anatomy.
stripTrackFills` is what exposes the painted layer; the model-level severity
could already be asserted and could not see any of this.

### The Refresh button

`HelmModuleCard.Content.headerAction` is a new, opt-in control at the header's
trailing edge, right of the chip - `HelmPageToolbar.iconButton`'s bordered
28pt square, the same recipe `MorningBriefingCard`'s own header actions use.
`nil` on every card but this one.

Three things it needed that a page could have got wrong on its own, so they
live in the component:

- **Gesture arbitration.** A module card is one click target; AppKit defines no
  exclusivity between an ancestor's recognizer and a descendant control, so
  without this a Refresh press would *also* open the card's destination. The
  hit-test rule is `SessionStripView`'s, verbatim and for its reasons.
- **A second, frame-based rule, and it is not redundant.** AppKit does not
  hit-test a **disabled** control, so while the button is in its in-flight
  state the click lands on the card behind it and navigates away. Measured -
  the suite caught it on its first run, with the hit-test rule alone in place.
- **No separate accessibility label.** `HelmButton.accessibilityLabel()`
  already returns an icon-only button's tooltip (GL-16, so VoiceOver never
  reads out a raw SF Symbol name), so a second string would silently lose to
  it. `HeaderAction` carries one string and the suite reads the announced
  label back off the control.

The press does not fetch. `HomeCanvasController.onRefreshQuota` reaches
`FleetController.refreshQuotaNow()`, which is `refreshQuota(force: true)` -
the existing reading, on its existing `quotaQueue` (GL-04/GL-12), forced past
the freshness window. **The force is the whole point**: an unforced press
inside those five minutes hands back the very number the captain is asking to
replace, which looks exactly like a button that does nothing. The card's
`isRefreshingQuota` flag disables the button between the press and the reading,
and is cleared in `applyQuota` - which `refreshQuota` publishes on failure as
well as on success, so it cannot wedge on a `quota-axi` that is offline.

The action is set **before** `fillClaudeStatus`'s no-snapshot early return, so
the loading and failure states carry it too - those are the two states a
captain most wants to re-read from.

### The briefing's Claude-quota clause, removed

Same task, captain's call: the Morning briefing card sat a few hundred points
left of a card showing five quota figures and restated one of them ("Weekly
Claude quota is at 70%, ahead of pace"). The quota is no longer an input to the
briefing at all - `BriefingInputs`' three quota fields, the local clause, the
prompt's two facts, the `"quota"` link in the model's vocabulary and "quota" as
a claimed source are all gone, and the prompt now tells the model explicitly to
say nothing about Claude usage (it knows what a cockpit shows, and the facts
list is not the only thing it could write from).

Two consequences worth knowing:

- **`BriefingTarget.quota` stays in the enum.** It is the persisted form as
  well as the vocabulary, and dropping the case would make a record written by
  an earlier build undecodable - GL-01 in miniature.
- **The removal is visible today, not tomorrow.** A briefing is generated once
  a day and re-rendered from the stored record for the rest of it, so
  `MorningBriefing.withoutQuotaClauses` strips the old clause (and "quota" from
  `sources`) in `AppSettings.morningBriefingRecord`'s getter, and returns `nil`
  when that leaves nothing - so the next refresh generates a real briefing
  rather than the card rendering an empty paragraph.

`FleetController.withQuotaReading` went with it: the briefing was its only
caller, so composing a briefing no longer waits on a 1-2s subprocess.
`refreshQuota` is untouched and still runs on every refresh pass for the card.

### Verification

- Full suite green before (200 passed, 0 failed, 1 skipped) and after.
- **Six regression injections, each confirmed to fail the named case**:
  inverting `QuotaSeverity`'s two outer arms (the boundary checks plus every
  painted-track check, in both themes); moving the header action after
  `fillClaudeStatus`'s early return; dropping `force: true` from
  `refreshQuotaNow`; removing the frame-based arbitration rule (the busy-state
  navigation check - this one was a real defect found this way, not a
  simulation); re-adding the local quota clause and its prompt link; and
  skipping the purge in `AppSettings`.
- **Not verified**: no live visual check by the captain, and none is claimed -
  same permission constraint as the card's own original entry above. The
  evidence is real off-screen renders, real layout geometry and real
  target/action presses, per AGENTS.md's "Verifying native UI bugs without a
  real screenshot" convention.
