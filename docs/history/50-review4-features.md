# Full review 4 features

Twelve features from full review 4 (`data/grandline-full-review-4/report.md`, Part B) shipped together from `fm/grandline-review4-features` (2026-11-27).
Each took the report's recommended solution, and the mock-ups in `data/grandline-feature-visuals-scout/report.md` were the visual target.
Every feature has its own headless suite, and each suite was confirmed to fail with the fix reverted.

## What shipped

### D-05: incident postmortem export

- `IncidentPostmortemExport.swift` builds a Markdown postmortem draft from an incident: the timeline, the commands sent during it, the findings and the runbook runs.
- Commands sent to a terminal during an incident are recorded as a new `.command` kind, redacted through `LogRedactor` on the way in.
- The incident card has an Export button and a panel that picks the destination (a new postmortem or the clipboard).
- Suite: `FM_RUN_INCIDENT_EXPORT_TESTS`.

### D-03: SSH and TLS certificate expiry

- `ExpiryReminders.swift` parses SSH certificates (checked against real `ssh-keygen` output), probes TLS on saved hosts, and files a task 14 days before anything expires.
- TLS probes are on by default, as the brief asked.
- The check runs once a day after 06:00, and never in a suite or a tour.
- There is no Settings › Connections page, so the settings live in a Reminders popover on the Keys tab.
- Suite: `FM_RUN_EXPIRY_REMINDER_TESTS`.

### F-04: Core Spotlight

- `SpotlightIndex.swift` indexes tasks, notes, reading-list links and sticky notes.
- The vault is never indexed.
- While the app is locked the index holds titles only, and a result chosen while locked opens after unlock (`LockPresenter.showPendingOpen`).
- Settings live on the Security page.
- Core Spotlight needs a bundle identifier, so it only works in the packaged app, not the bare debug binary.
- Suite: `FM_RUN_SPOTLIGHT_INDEX_TESTS`.

### F-06: grab text from the screen

- `ScreenTextGrab.swift` runs `ScreenRegionCapture` and then Vision on the capture, and copies what it read.
- Vision reads `--timeout` as an em dash plus a hyphen, so `ScreenTextRecognizer.normaliseDashes` turns a dash run back into hyphens.
- It is a capture-panel tile (⌘7) and a Tasks menu item (⌥⌘7).
- Suite: `FM_RUN_SCREEN_TEXT_GRAB_TESTS`, which runs the real Vision pass on a rendered image.

### F-10: Services menu

- `GrandLineServicesMenu.swift` adds three Services: Send to Grand Line, New Task from Selection, and Add Page to Reading List.
- The share extension was deliberately not built.
  It needs a team-signed app (the Developer ID item, S-01).
- A selection marked concealed by its source app is never read (R2-SEC-03).
- Suite: `FM_RUN_SERVICES_MENU_TESTS`.

### D-02: managed dev servers

- A DevOps Hub project can be a dev server: a command Grand Line starts, logs and stops.
- `DevServerProcess` spawns the child in its own process group (`POSIX_SPAWN_SETPGROUP`) and stops the whole group.
- A small watchdog in the group kills it if Grand Line's pid goes away, so a crash does not leave a server listening.
- The log is bounded at 2,000 lines of 2,000 characters.
- A crash restarts the server up to 3 times in 2 minutes, then it is left stopped with the error.
- Suite: `FM_RUN_DEV_SERVER_TESTS`, with real children.

### D-01: runbook run mode

- `RunbookRunMode.swift` runs a runbook step by step in a terminal and captures each step's output and exit code between markers.
- Echoed command lines are stripped, the output is redacted and capped at 400 lines.
- A finished run can be attached to a postmortem as evidence.
- A skipped step no longer counts as a clean run.
- Suite: `FM_RUN_RUNBOOK_RUN_MODE_TESTS`.

### F-05: voice memos

- Right Option + Shift records a voice memo, and audio stays on this Mac (`FM_VOICE_MEMO_DIR`).
- The memo becomes a Notebook page with a transcript from the local Whisper model.
- The microphone prompt and the denied state are shown in the HUD, with a button to System Settings.
- The key works from other apps only with the Accessibility grant Dictation already uses, and the HUD says so.
- The monitor is gated at the consumer, like `DictationHotkey`, so a memo started before the lock still stops.
- Suite: `FM_RUN_VOICE_MEMO_TESTS`.

### F-03: reader mode and highlights

- `ReadingListReader.swift` extracts an article's text in a non-persistent off-screen web view and keeps it (`FM_READER_ARTICLES_DIR`).
- The reader page is set in the system serif (New York via `withDesign(.serif)`), never a named face, because J1 retired Georgia.
- A highlight can be sent to a Notebook page as a quote with its source.
- Suite: `FM_RUN_READER_MODE_TESTS`.

### F-15: a page in its own window

- `PageWindows.swift` moves the page's own mounted view into a new window, and the main window shows a placeholder.
- There is no second controller, so the two windows cannot disagree or race each other's writes (GL-23, GL-37).
- Notebook, Sticky Board and the Console (the whole page with its tabs) can pop out, and so can the focus timer.
- Every popped-out window registers with the lock gate.
- Suite: `FM_RUN_PAGE_WINDOWS_TESTS`.

### F-01: the Mac's calendars

- `MacCalendar.swift` reads the Mac's calendars through EventKit, read only.
- Meetings show in the Calendar view as striped, fixed events, Home's greeting names the first meeting, and a task dropped on a meeting is offered the next free gap.
- This brings back EventKit after the Today page's removal, so `TodayCalendarRemovalSelfTest` now allows it in `MacCalendar.swift` only.
- Suite: `FM_RUN_MAC_CALENDAR_TESTS`.

### F-02: plan my day, and close it

- `DayPlan.swift` is the model and its rules, `DayPlanSheets.swift` the two sheets, and `HomeCanvasController+DayPlan.swift` Home's half.
- Plan my day picks up to three tasks, places them around today's meetings, and starts the first focus session.
- The plan then becomes Home's hero.
- When the briefing is not drawn as the hero, Plan my day and Start focus sit under the greeting instead.
- Close the day completes what was ticked, moves the rest (Tomorrow, a picked day, or the backlog), and keeps one line for tomorrow.
- A plan does not change a task's due date. Only Close the day writes to tasks.
- The bell nudges at 9:00 and 18:00, once a day each, and the nudge clears once it is answered.
- The hero's focus pill says when the session ends ("Focusing until 10:15") rather than counting down, so Home does not render every second.
- Suite: `FM_RUN_DAY_PLAN_TESTS`.

## What the guard suites caught

Running the source-scanning suites before the PR found real gaps, each fixed on the branch:

- Two popovers (the Keys Reminders popover and a meeting's card) were not closed on the way into the lock.
- Three URL opens skipped the scheme check, and are now named fixed targets.
- The Services pasteboard was read without asking `CredentialVaultClipboard.isConcealed`.
- The reader used Georgia as a fallback, which J1 retired.
- Two new text views did not apply `HelmSelection`.
- A timer had no tolerance, a literal "duration" name read as a UI duration, and an em dash reached exported copy.
- Forty-odd feature inventory rows and four README environment rows were missing.

## Not verified

- No pixel came from a real screen.
  Every surface was rendered off screen with the review tour lab in Lavender and Powder.
- Core Spotlight, the Services menu registration and the macOS notification banner only work in the packaged, signed app.
- The real Whisper transcription is skipped in the suites.
- The calendar permission prompt and EventKit reads were driven through fakes; no suite asks EventKit.
