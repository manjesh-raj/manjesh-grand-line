# Google accounts (Gmail sign-in) and Google Calendar

`fm/grandline-overview-layout-fix-gmail-settings`.

The captain's own words: "In the settings page let's add Gmail login for Google Calendar login and we can connect here as well.
Add a new section called Gmail: work-mail and personal-mail, it's not mandatory to login to both."

## What shipped

A new Settings category, **Gmail**, with two independent account slots and one consumer.

- `GoogleAccount.swift` - the two slots (`GoogleAccountSlot.work` / `.personal`), the stored record, and the Keychain store behind it.
- `GoogleOAuth.swift` - the pure half of the flow: PKCE, the authorization request, the redirect parsing, the token exchange and the record merge.
- `GoogleSignIn.swift` - the browser half (`ASWebAuthenticationSession`) and the token refresh.
- `GoogleCalendarSource.swift` - one connected account's calendar as a `DailyReviewCalendarReading`, plus `CompositeDailyReviewCalendar`, which merges it with the Mac's own calendars.
- `DailyReviewCalendarSources.swift` - which sources are on, in one place, read by both hosts of the daily review card.
- `GmailAccountRow.swift` - one slot's row in the Settings card.

## What is blocked, and on whom

**There is no OAuth client ID, and this task could not create one.**
A Google OAuth client is issued by a Google Cloud project with a consent screen, which only the captain can set up.
The flow is complete and real - it will run end to end the moment a client ID exists - but until then every surface says so rather than offering a Connect button that fails at Google with an opaque error.

Two things the captain has to do:

1. In the Google Cloud console, create a project, configure the OAuth consent screen (External, with the `calendar.readonly` and `userinfo.email` scopes), and create an **OAuth client of type "iOS"** - that client type is what issues a reversed-client-id redirect scheme, which is what `ASWebAuthenticationSession` listens on.
   A "Desktop app" client works too, with its own client secret, and the Settings card accepts both.
2. Paste the client ID into **Settings › Gmail › Google OAuth client ID**, or export `FM_GOOGLE_OAUTH_CLIENT_ID`.

This is the same class of "structurally complete, blocked on captain-owned external setup" as F23's widgets and the Developer ID gap (`docs/history/42-widgets.md`).

## The decisions worth keeping

**Secrets go in the Keychain, and the metadata goes with them.**
The whole record - tokens, the granted scopes, and the email address that describes them - is one generic-password item per slot, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never iCloud-synced.
Not two items: the address a card displays is a claim about which token is stored, and splitting them is how a card comes to name an account whose token was already deleted.
Nothing is written to a JSON store and nothing is git-synced.
GL-15 has nothing to apply to - there is no subprocess anywhere in this feature, so no token ever reaches an argv or an environment.

**`ASWebAuthenticationSession`, not a `WKWebView` and not Google's SDK.**
The consent screen runs in Safari's own process, so this app never sees the captain's password and cannot read the consent page.
That is RFC 8252's own recommendation for a native app, and it is the security-relevant half of the choice; the SDK would have been one `URLSession` POST wrapped in a dependency.

**PKCE is the actual protection, because the client secret is not one.**
Google documents an installed application's client secret as not confidential - it ships inside the app.
So each attempt generates a 32-byte verifier, sends only its SHA-256 up front, and sends the verifier itself only with the code.
`GoogleAccountsSelfTest` asserts that the verifier is *not* in the authorization URL, which is the check that fails if somebody "simplifies" this to `code_challenge_method=plain`.

**The redirect is the reversed client id, and needs no `Info.plist`.**
`ASWebAuthenticationSession` intercepts the callback itself by the scheme it was handed, and never asks the OS to route it.
That matters here specifically: the unbundled debug binary has no `Info.plist` at all, so an `Info.plist`-registered scheme would work in the packaged app and silently not in every development build - the same gap `DailyReviewCalendar.canPrompt` already works around.
A loopback redirect would also have worked, at the cost of opening a listening socket this app has no other reason to open.

**`access_type=offline` plus `prompt=consent` is load-bearing.**
Without both, a second sign-in to an account that has consented before returns an access token and no refresh token, and the connection stops working an hour later - which reads as a broken feature rather than as a missing query parameter.
The matching rule on the way back in: a token response with **no** refresh token keeps the stored one rather than nulling it, because Google omits it on a re-consent it considers unchanged.
Both are asserted.

**Read-only is enforced by the scope, one layer below the file.**
`DailyReviewCalendar.swift`'s read-only-ness has to be a source guard, because EventKit hands out an object that *can* write.
Here the guarantee is stronger: `calendar.readonly` is the only calendar scope this app ever requests, so the access token physically cannot write.
The suite asserts the scope list and that `GoogleCalendarSource.swift` issues no `POST`/`PUT`/`PATCH`/`DELETE`.

**The Google source caches, and "not read yet" is not "nothing on".**
`DailyReviewCalendarReading.events(on:)` is synchronous and called from `renderDailyReview()` on the main thread, so a network round trip cannot live there (GL-04/GL-12).
The source answers from a snapshot and refreshes in the background; before the first refresh lands it reports a **stated gap**, never an empty day.
That is GL-14 applied to a source the app does not hold in memory, and it is asserted in both directions - a calendar that *was* read and is empty does report an empty day.

**Additive, and a failing source is never swallowed.**
`CompositeDailyReviewCalendar` merges the Mac's calendars and every connected Google account.
A source with events contributes them; a source that is unavailable contributes its reason, even when another source had events - the captain has to be able to tell "nothing on" from "one of your two calendars could not be read".
Only when every source is unavailable does the column itself go unavailable.
A single source is deliberately **not** wrapped, which is what keeps the pre-Google behaviour byte-identical.

**Two flags, not one.**
`dailyReviewCalendarEnabled` gates the local Mac calendars behind a TCC grant this app has to ask for; `googleCalendarEnabled` gates a remote source the captain already consented to by signing in.
One flag for both would make turning off EventKit also turn off Google, which is not what either switch says.

**Four row states, not two.**
"Connected" and "usable" are not the same thing: a captain who unticked calendar on the consent screen is signed in and has no calendar.
`GmailAccountRow` renders not-configured, not-connected, connected-without-calendar and connected, and the view suite asserts the third exists - a two-state row would have shown a green tick over a calendar column saying "no events".

## Verification

- `GoogleAccountsSelfTest` (`FM_RUN_GOOGLE_ACCOUNTS_TESTS`) - **pure logic**, and deliberately not in `NEEDS_SESSION`, so it guards the blocking CI lane.
  Both the browser and the HTTP transport are stubbed, which is what lets the *whole* sign-in be driven end to end with no client ID and no network.
- `GmailSettingsViewSelfTest` (`FM_RUN_GMAIL_SETTINGS_VIEW_TESTS`) - window-backed, and in `NEEDS_SESSION`.
  Every case is a form of "one slot's state does not leak into the other's", which is the captain's requirement and is a UI property that cannot be asserted anywhere else.
- Both were confirmed to catch real regressions rather than merely pass.
  Eight injections: `code_challenge_method=plain` fails the PKCE check; dropping the state comparison fails the CSRF check; widening to the writable `calendar` scope fails two checks; dropping the refresh-token preservation fails by name; an unread calendar reporting `[]` fails the GL-14 check; keeping cancelled events fails the parse check; swallowing a failed source's reason fails the merge check; collapsing `connectedWithoutCalendar` into `connected` fails two view checks.
- The Settings pane was rendered off-screen at 1300pt in Dusk and Catppuccin Latte and read back (no screenshot grant in this environment, per AGENTS.md's convention); the probe was reverted before commit.
- What was **not** verified: that Google accepts any of it.
  No real sign-in has been performed, because there is no client ID to perform one with.

## The client-ID field did not save (`fm/grandline-gmail-oauth-field-not-saving`)

The captain pasted an OAuth client ID, clicked away, and the value was gone.

`buildGmailSection` hand-wired both fields with `target`/`action` alone, which AppKit fires on **Return** and on nothing else.
Pasting and then clicking Connect - the natural thing to do, and what the captain did - sent no action, so `GoogleOAuthClientStore.setConfiguration` was never called.
The text stayed visibly in the field, which is why it read as "it did not save" rather than as a crash.
The full mechanism is AGENTS.md's gotcha (19).

**Fix:** both fields now go through `SettingsController.configure(_:)`, the one place on this page that wires `target`, `action` **and** `delegate`, with a `gmailClientIDField, gmailClientSecretField` case in `textFieldChanged(_:)` calling the same commit.
Return still works - the delegate is additive, not a replacement.

**Why the existing suite missed it.**
`checkTheClientIDFieldAndItsStatusLine` called the `debugCommitGmailClient()` hook, which reaches the private commit directly and so passes with the wiring deleted entirely.
That hook's own doc comment claimed it drove "the field's real target/action", which it never did; it now says the opposite, in as many words.

**Verification.**
`checkPastingAndClickingAwayCommits` drives the real field editor in the real window - `makeFirstResponder`, `currentEditor()?.insertText`, then move first responder to the next field - and reads `GoogleOAuth.configuration()` afterwards, so it asserts what was *saved*.
It asserts mid-edit that nothing is committed yet, so a pass cannot come from an already-configured store.
It also drives the Return path in the same case, so a future change cannot trade one for the other.
Written before the fix and run against it: three named checks failed (`pasting and clicking away must save the client ID - got nothing`, and the two secret-field ones), and all passed after.
Full suite 197 passed / 0 failed afterwards.

**Scope, checked rather than assumed.**
Every other `NSTextField` action in the app was surveyed.
Three exist - `CompactModePopover`'s capture line, `IncidentCardView`'s note, `KubernetesController`'s namespace - and all three are *submit* actions, where Return-only is the correct behaviour and a blur commit would be its own bug.
The silent-loss shape is specific to a field whose value is **persisted**, and Gmail's two were the only such fields on this page wired by hand instead of through `configure(_:)`.

## Both OAuth fields are masked, with a reveal toggle (`fm/grandline-gmail-oauth-fields-mask-reveal`)

The captain's ask: "hide this by default and have a button/icon to make this visible for both client ID and secret".
Both fields were plain `HelmTextField`s, so a Settings page open on a shared screen put the client ID and the client secret on display.

**There was already exactly one implementation of this pattern**, in the credential editor's Secret row - a `HelmSecureTextField`, a `HelmTextField` and a Show/Hide toggle, kept in step by hand inside `CredentialVaultEditorController`.
Adding a second copy for Settings (and a third for the secret) is the thing this repository's component index exists to prevent, so the pattern was lifted into `HelmRevealableSecretField` and both hosts now use it.
The credential editor's behaviour is unchanged - its debug accessors forward to the component, so its own suite drives the same objects it always did.

**The component, and the three properties that matter.**

- Exactly one of the two fields is in layout at a time, so the row's height and the button's position do not move across a toggle.
  A single field whose cell is swapped would be one view rather than two, but `NSSecureTextFieldCell` is what does the masking and swapping a live cell loses the field editor.
- Both halves carry the same text at all times.
  The toggle copies from the outgoing half before it swaps, so a `controlTextDidEndEditing` commit fired *by* the toggle (moving the first responder ends editing on the outgoing field) reads the right value whichever half the delegate sees.
  Measured while writing this: `NSTextField.stringValue` reads back through the live field editor mid-edit, so no `currentEditor()` dance is needed - copying from the *incoming* half is the direction that breaks, and there is a named check for it.
- Masking is display-only.
  The component owns no store and no commit path, and `GoogleOAuthClientStore` holds the same strings in both states.

**`editableFields` is plural on purpose.**
A field whose value is persisted needs a `delegate` as well as a target/action (gotcha (19), and the section above).
A masked control that wired only its visible half would reopen `fm/grandline-gmail-oauth-field-not-saving` in the half nobody was looking at, so `SettingsController` wires both through `configure(_:)`.
`textFieldChanged(_:)` now asks `owns(_:)` before its `switch`, because the sender is one of the two halves and never the control itself - a `case` on the property would have matched neither, silently.

**The client ID is masked too**, as asked.
It is not a secret in the way the client secret is - it travels in the authorization URL - but it identifies the captain's own Google Cloud project, and neither belongs on screen by default.

**Verification.**
`checkBothFieldsAreMaskedUntilRevealed` and `checkTheRevealedHalfCommitsToo` in `GmailSettingsViewSelfTest` (window-backed, already in `NEEDS_SESSION`).
They assert the *painted* state rather than the control's own bookkeeping: the visible half's cell must really be an `NSSecureTextFieldCell`, since `isRevealed == false` alone would pass against a control that had lost its secure cell entirely.
The two fixture values are asserted to differ first, so a control showing the wrong one cannot pass by coincidence.
Independence is asserted in both directions, and the store is read at the end.
Four injections, each confirmed to fail by name: defaulting to revealed fails 21 checks; dropping `plainField` from `editableFields` fails `typing into the revealed half and clicking away must save it`; copying from the incoming half on toggle fails `toggling mid-edit must carry the typed text across`; and reading a stale `stringValue` instead of the editor fails nothing, which is how the `currentEditor()` read came to be dropped as a check that could not fail.
Full suite before: 199 passed / 0 failed. After: see the PR.

## Connecting an account now says whether the calendar actually reads (`fm/grandline-google-calendar-connection-health`)

The captain connected a Google account under Settings › Google Accounts.
OAuth succeeded, the row said "calendar readable", and every actual calendar read failed.
The reason was real, specific and one click away from being fixed: the Google Cloud project behind the client ID had the Calendar API switched off, and Google says so in as many words - "Google Calendar API has not been used in project N before or it is disabled. Enable it by visiting <url> then retry."

That sentence was already being captured.
`GoogleCalendarSource.parse` has always carried Google's own `error.message` straight through, and `refresh` has always stored it in `lastFailure`.
The only place it ever surfaced was the daily review card's fine print, on the Overview page, days later - nowhere near the account it was about, and with the URL rendered as inert text.

So the gap was never the error handling.
It was that nothing checked, and nothing reported, at the point where the captain was actually asking the question.

### What was added

**`GoogleCalendarHealthCheck`**, at the bottom of `GoogleCalendarSource.swift`.
One shared instance (GL-23), holding one verdict per slot.
It builds no second request machinery: the URL is `GoogleDailyReviewCalendar.eventsURL`, the transport is the same `GoogleCalendarTransport`, the token comes from the same `GoogleSignInController`, and the body goes through the same `GoogleDailyReviewCalendar.parse`.
That is deliberate rather than tidy - it is what makes "the check passed" and "the daily review can read this calendar" one claim instead of two.

**`GoogleAPIFailure`**, which keeps Google's error envelope whole - the message *and* the first `https://` URL inside it.
`parse` was threaded through it, and its `.unavailable` message is byte-identical to what it was, because the daily review card's own reporting had to stay exactly as it is.
The URL is pulled out of the message text rather than out of the structured `details` array: Google's `Help` detail is not present on every error shape, and the sentence is.
Trailing sentence punctuation is stripped, because a captain clicking a link with a `.` welded on lands on a 404 that looks like this app's fault.

**A health line on `GmailAccountRow`**, underneath the account.
It renders Google's sentence verbatim when a read fails - never a summary, since paraphrasing is exactly what kept the message hidden - and offers the fix-it URL as a real `HelmButton`.
A success says the read worked *and* how much came back, including zero: GL-14 at the happy end, where "no events today" without "the read worked" is the same ambiguity in the other direction.
An account that has never been checked shows nothing, rather than a permanent "unknown" line the eye learns to skip.

**When it runs**: once right after a successful connect, once on arriving at the page for an account with no verdict yet, and on demand from a "Test connection" button that is always there for a connected account.
Not on every repaint - `result(for:)` is `.notChecked` only until the first answer lands, so this is one request per account per launch plus whatever the captain asks for.

### The thing the off-screen render caught

The first working version still painted the row's own status line as a green "work@example.com · calendar readable" **directly above** a red "Calendar read failed".
Every assertion passed; the contradiction was only visible in a real render.

That green claim is the captain's original complaint moved one line up, so it is retracted now: a connected account whose last read failed reads "· calendar scope granted" in the muted register.
The scope half was the only part that was ever true.
`GmailAccountRow`'s own header already warned against collapsing "connected" into "usable" - this is the same rule one level further in, where the record says one thing and the network says another.

### What is deliberately unchanged

The daily review card's "not available - see below" reporting.
It is the review's own statement about the review, and this is additive: a second, earlier, clearer place the same real failure is surfaced.
`checkTheDailyReviewCardIsUnchanged` asserts both halves - `parse`'s message and the sentence `refresh` wraps it in - byte for byte.

### Verification

`GoogleAccountsSelfTest` (pure, blocking lane) gained four cases: the error envelope and URL extraction, the verdict for each Google reply shape, the whole check driven end to end through a stub transport, and the daily-review-unchanged guard.
`GmailSettingsViewSelfTest` (window-backed) gained five: the silent unchecked state, a rendered success, the captain's exact API-disabled failure with its link, the Test button reaching the real check through the real control, and contrast in both registers for both verdicts.

The Test and fix-it buttons are driven with `performClick` rather than by calling the handler, and the suite asserts `onOpenFixURL != nil` *before* swapping it for a recorder - gotcha (20)'s lesson, since two rows in this app have shipped dead under green checks that called the helper instead of the control.

Five injections, each confirmed to fail by name:

- paraphrasing the failure message instead of quoting Google - 4 failures.
- dropping `onOpenFixURL` and `onTest` in `SettingsController` - 3 failures, including "the button is decoration".
- returning `nil` from the fix-URL extraction - 3 failures.
- collapsing `parse`'s error branch to a generic string - 3 failures, two of them the daily-review guard.
- keeping the green "calendar readable" over a failed read - 3 failures.

`main.swift`'s `#if FM_SELFTESTS` block installs `RefusingGoogleCalendarTransport`.
Without it, any suite that plants a fixture record would issue a live HTTPS request from CI carrying a fabricated bearer token, because mounting a `SettingsController` now builds a page that runs a real read.

Full suite before: 207 passed / 0 failed / 1 skipped. After: see the PR.
