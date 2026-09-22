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
