# Feature history

Everything in this directory used to live in the repository root `AGENTS.md`,
which `CLAUDE.md` imports into **every** agent session. By full review #3 that
file was 1.69MB / ~422K tokens - 3,107 lines, 81 sections, 471 mentions of 325
distinct branch names - and most of it was one-time narrative: what one branch
built, what it measured, what it tried first, what replaced it.

P1 of that review split it. The root `AGENTS.md` now holds only **standing
rules** (the AppKit gotcha catalogue, the GL invariants, the verification and
testing conventions, the worktree hazards, the component index) and is still
imported. **These files are not imported.** Read the one for the area you are
about to touch.

Nothing was deleted in the split - every line was relocated, and the losslessness
was checked at the word level: 0.011% of the original's tokens are absent from
the new tree, and every one of those is from the file header and two headings
that were deliberately rewritten.

## How to read one

Each file is chronological, in the order the entries were written. **A later
entry can correct an earlier one**, and several do - a feature that was built,
removed and rebuilt reads that way here. When two entries disagree, the later
one wins unless it says otherwise. Every entry names the branch it came from,
so `git log` is the tiebreaker.

## The files

45 files.


| File | Covers | Size |
|---|---|---|
| [`01-foundations.md`](01-foundations.md) | Foundations: the runtime, the build, and the vendored SwiftTerm | 5KB |
| [`02-console-and-terminal.md`](02-console-and-terminal.md) | Console, terminals, tabs, selection and splits | 94KB |
| [`03-navigation-and-chrome.md`](03-navigation-and-chrome.md) | Navigation: the rail, the Daylight bar, the window chrome | 111KB |
| [`04-design-system.md`](04-design-system.md) | The Helm design system | 157KB |
| [`05-daylight-migration.md`](05-daylight-migration.md) | The Daylight UI migration (phases 1-6) | 110KB |
| [`06-hosts-and-ssh.md`](06-hosts-and-ssh.md) | Hosts, SSH keys and the connection manager | 28KB |
| [`07-fleet-and-notifications.md`](07-fleet-and-notifications.md) | Fleet, Overview, notifications and the captain's log | 52KB |
| [`08-tasks-and-shift.md`](08-tasks-and-shift.md) | Tasks (Shift) and the Kanban board | 133KB |
| [`09-setup-updates-bootstrap.md`](09-setup-updates-bootstrap.md) | Setup: Updates, Bootstrap, Automation, GitHub Sync, Schedules, Settings | 133KB |
| [`10-docs-and-search.md`](10-docs-and-search.md) | Docs, runbooks, postmortems and unified search | 21KB |
| [`11-sre-lead-and-composer.md`](11-sre-lead-and-composer.md) | SRE Lead, the command composer and the command palette | 48KB |
| [`12-tools.md`](12-tools.md) | Tools | 38KB |
| [`13-block-view.md`](13-block-view.md) | Block view | 36KB |
| [`14-poneglyph-and-vault.md`](14-poneglyph-and-vault.md) | Poneglyph (the credential vault) and Vault (Automic Vault's panel) | 71KB |
| [`15-app-lock.md`](15-app-lock.md) | The app lock and the lock screen | 27KB |
| [`16-dictation.md`](16-dictation.md) | Dictation | 60KB |
| [`17-kubernetes.md`](17-kubernetes.md) | Kubernetes: the context badge, the cluster browser and Log Tail | 40KB |
| [`18-log-analyzer.md`](18-log-analyzer.md) | Log Analyzer | 14KB |
| [`19-incident-mode.md`](19-incident-mode.md) | Incident mode (F8) | 38KB |
| [`20-whiteboard.md`](20-whiteboard.md) | Whiteboard (embedded Excalidraw) | 32KB |
| [`21-sticky-board.md`](21-sticky-board.md) | Sticky Board | 26KB |
| [`22-code-preview.md`](22-code-preview.md) | Code Preview (embedded Monaco) | 17KB |
| [`23-straw-hat-pirates.md`](23-straw-hat-pirates.md) | Straw Hat Pirates (the AI crew) | 96KB |
| [`24-window-and-layout.md`](24-window-and-layout.md) | Window geometry: the body-width tie and the contentView drift | 21KB |
| [`25-removed-features.md`](25-removed-features.md) | Features that were built and then removed | 3KB |
| [`26-production-readiness.md`](26-production-readiness.md) | The production-readiness review (phases 1-4, GL-01..GL-38) | 51KB |
| [`27-full-app-audit-1.md`](27-full-app-audit-1.md) | The first full-app audit, and the AppKit-expert audit | 74KB |
| [`28-full-app-audit-2.md`](28-full-app-audit-2.md) | The second full-app audit | 44KB |
| [`29-end-to-end-review-1.md`](29-end-to-end-review-1.md) | End-to-end review #1 | 29KB |
| [`30-full-review-3.md`](30-full-review-3.md) | Full review #3 | 7KB |
| [`31-testing-policy.md`](31-testing-policy.md) | The self-test classification rule | 3KB |
| [`32-notebook.md`](32-notebook.md) | Notebook (F1): the page tree, wiki-links and backlinks | 13KB |
| [`33-capture-and-clipboard.md`](33-capture-and-clipboard.md) | Universal capture (⌥Space) and the encrypted clipboard history | 13KB |
| [`34-recurrence-and-calendar.md`](34-recurrence-and-calendar.md) | Recurring tasks, reminders and the Tasks calendar view (F5) | 10KB |
| [`35-reading-list.md`](35-reading-list.md) | Reading list (F4): the link inbox, its metadata, tags and AI summary | 10KB |
| [`36-focus-timer.md`](36-focus-timer.md) | Focus timer (F7): the task-bound Pomodoro, the bar chip and Weekly Review's "time on tasks" tile | 9KB |
| [`37-scratchpad-calculator.md`](37-scratchpad-calculator.md) | Scratchpad calculator (F9): the Tools tab, its expression engine and unit/currency tables | 12KB |
| [`38-snippet-expander.md`](38-snippet-expander.md) | Snippet expander (F12): the `;abbrev` trigger grammar and system-wide expansion | 13KB |
| [`39-daily-review.md`](39-daily-review.md) | Daily review (F20): Overview's general-user briefing and its read-only calendar | 14KB |
| [`40-menu-bar-mode.md`](40-menu-bar-mode.md) | Menu-bar (compact) mode (F22): the merged status item, its four-tab popover and the window/Dock lifecycle | 25KB |
| [`41-app-intents-and-full-export.md`](41-app-intents-and-full-export.md) | App Intents / Shortcuts (F21) and the `.glbackup` bundle's five new sections (F24) | 20KB |
| [`42-widgets.md`](42-widgets.md) | WidgetKit extension (F23): the Tasks-due and Sticky-note widgets and the Developer ID dependency | 13KB |
| [`43-google-accounts.md`](43-google-accounts.md) | Gmail sign-in, the OAuth/PKCE flow, and Google Calendar as a second read-only source for the daily review | 9KB |
| [`44-new-theme-families.md`](44-new-theme-families.md) | Six new theme families: the picker from 14 palettes to 26 (Nord, Dracula, One, Ayu, Night Owl, Oxocarbon) | 11KB |
| [`45-rename-to-grand-line.md`](45-rename-to-grand-line.md) | The rename to "Grand Line": the new bundle identifier, the Keychain and data-folder migrations, and the System Settings re-grant it costs | 9KB |
