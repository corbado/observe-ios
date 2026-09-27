# AS / AutoFill signal spec (iOS)

What the SDK may rely on when mapping AuthenticationServices ceremonies, conditional UI and
Password AutoFill onto the Observe taxonomy. Distilled from `as-af-research.md` §8 (verified
2026-09-03 on iOS 26.5 simulator and iOS 27.0 beta device; raw data in [`observe/Tests/Fixtures`](../observe/Tests/Fixtures)). Every
rule below is backed by a recorded run; anything not listed here is not known, see §7.

## 1. Modal ceremonies (`performRequests`)

The call site sees everything: request mix, options, one typed result or one `NSError`.

| Signal | Value | Meaning |
|---|---|---|
| 1001 + "No credentials available for login." | 25–81 ms (444 ms cold on the simulator) | silent probe answered: nothing to show |
| 1001, generic text | ≥ 0.95 s observed | user dismissal **or** app-side `cancel()` — indistinguishable |
| 1004 "Request already in progress for specified application identifier." | 4–100 ms | a second request while one is armed or running |
| 1004 "Unable to verify webcredentials association …" | install-time race | AASA not fetched yet; retry a few seconds later |
| 1004 "… does not have an application identifier" | instant | entitlements stripped (signing), not a user event |
| 1006 | after the user confirmed (6.3 s) | `excludedCredentials` match — not an instant answer |
| success | Keychain 3.8–7 s, provider 7–24 s | assertion / registration |

- The message is localized. Classify on flag + code; carry the message as raw error data. It
  is the only disambiguator between "nothing available" and "dismissed".
- `.preferImmediatelyAvailableCredentials` shows the full sheet whenever a passkey exists,
  **including passkeys held by a third-party provider**. Silent vs shown is visible only through
  duration + message.
- One request per process. A collision fails the *new* request instantly with 1004; the
  running one is untouched. `cancel()` settles the old one as 1001 within milliseconds; a
  modal request 50 ms later succeeds.
- The app is inactive for the whole sheet: `willResignActive` ~0.1–0.3 s after
  `performRequests`, `didBecomeActive` ~0.5 s after the delegate. Provider UI, passcode
  fallback and failed Face ID attempts all happen inside that window. Passcode fallback is
  invisible except as duration (11–28 s vs ~7 s).
- A registration for an account that already has a Keychain passkey ends in 1006 only after
  the user confirmed; with another provider selected as target it succeeds.

## 2. Conditional UI (`performAutoFillAssistedRequests`)

- The armed request is **process-scoped**: it survives keyboard dismissal, focus loss and
  regain, backgrounding, a failed identifier submit and SwiftUI view teardown. Only a chip
  pick, an error or `cancel()` settles it. Arming again while one is alive → 1004 in ~100 ms.
- Arm timing does not matter: armed at flow start or 100 ms after focus, the chip is present
  on focus (iOS 27). Chips are absent on 16.1–16.2 (research), so absence proves nothing.
- A pick is delivered ~0.5 s after the chip tap, inside a ~1.7 s lifecycle blip, preceded by
  the chip-tap precursor (§3). A password pick from the AF chip next to it fills the fields and
  leaves the passkey request armed.
- App-side `cancel()` yields the same 1001 as a dismissal. The integration knows it cancelled;
  the SDK cannot infer it.

## 3. Password AutoFill fill signature

Per filled view, in one runloop turn: one plural delegate call
(`shouldChangeCharactersInRanges`, iOS 26+; the singular delegate never fires) carrying the
whole value as one replacement, one text-change, forced begin/end editing without a tap.
Identifier before password, both fields within one runloop turn (15–16 ms apart in the
captures). Hidden 1 pt fields
(`.username` pairing field, harvest field) are filled like visible ones; a prefilled hidden
field is **replaced** (delete + insert as one call), not appended.

Observed shapes:

| Path | Precursor | Blip | Fill lands | Note |
|---|---|---|---|---|
| Keychain chip (S11/S12/S13/S21) | yes | 1.69–1.78 s | inside the blip, ~0.5 s after the tap | Face ID also for identifier-only fills |
| Provider chip, provider unlocked (S17a) | yes | 1.73 s | ~0.2 s **after** `didBecomeActive` | |
| Provider locked → key icon → provider UI (S17b) | no | **none** | with no lifecycle event at all | 2 of 2 runs |
| Key-icon picker, Keychain (S15/S24) | no | ~1.7 s to open the list | seconds later, no second blip | |
| Strong-password suggestion (S29) | — | none | delegate called **twice** with the same 20-char value, one text-change | |
| Paste (S19) | `paste(_:)` ~15 ms before the delegate | none | one bulk change, no churn | |
| Plain SwiftUI, chip | n/a (no delegate) | 1.78 s | inside the blip | `@FocusState` hops identifier → password between the two values |
| Plain SwiftUI, key-icon picker | n/a | ~1.7 s unlock, fill 3.3 s later | both fields, one runloop turn | **no** FocusState change at all |

- **Chip-tap precursor:** ~100 ms before `willResignActive` the focused field receives one
  delegate call with an **empty** replacement (5 of 5 chip picks, passkey chip included; never
  on the picker or locked-provider paths). Flags the tap, not the credential type.
- **Detector rule:** bulk change (≥ 3 chars in one call) + a second field changed in the same
  runloop turn + responder churn without a tap ⇒ system fill. Blip and precursor corroborate;
  their absence does not refute (S17b). A lone bulk change with no churn is paste or
  strong-password insert.
- The Face ID blip is not tied to the password: identifier-only fills blip too.

## 4. Lifecycle blip semantics

`willResignActive → didBecomeActive` is not a fill signal on its own:

| Blip | Cause |
|---|---|
| 1.69–1.78 s with bulk changes inside or ≤ 0.2 s after | Keychain / unlocked-provider fill |
| ~1.7 s, no changes | key-icon picker unlock, the pick follows seconds later |
| ceremony duration + ~0.5 s | modal AS sheet (3.8 s … 28 s) |
| arbitrary | app switch, notification, control centre |

Rule: a blip explains a bulk change; a bulk change never needs one.

## 5. Invisible by design

Chip presence, provider lock state, save/update prompt (no lifecycle event; strong-password
acceptance auto-saves indistinguishably), passcode fallback, biometry lockout unless five
mismatching faces occurred (`LAContext` answers "ok" through no-face timeouts), and whether
a 1001 was a dismissal or the app's own cancel.

## 6. Consequences for the SDK

1. `AutofillEngine.fieldChanged` bulk detection stays as is — Android emits the same two
   per-field `big-input-add` lows for a two-field fill; grouping by timestamp is a classifier
   topic for all platforms, not an iOS emitter change.
2. Emit `window-blur` / `window-focus` lows from `AppLifecycleWatcher` while a ceremony runs
   or a field is focused (web's two arming sources): the resign/become-active pair is the
   overlay shape web's classifier matches. It corroborates the 1.7 s shape and must never gate
   (S17b has no blip). Ingested today, matched only once the backend runs a ceremony detector
   for app client environments. An armed conditional request is idle and arms
   nothing; its focused field does.
3. Field `focus` / `blur` lows via `focusChanged(_:)`: UIKit forwards its editing callbacks
   (full churn); SwiftUI forwards `@FocusState` changes (sees the cross-field hop of a chip
   fill, nothing on the picker path). Optional evidence, lengths stay the base.
4. Silent-probe classification is a backend rule, not an SDK one: code 1001 + message +
   duration < ~200 ms ⇒ `no-credential`; duration ≥ ~1 s ⇒ dismissal. Provider-held passkeys
   count as available. The SDK ships the raw error and the step duration.
5. Conditional UI: process scope, the 1004 collision and the abort contract (the 1001 after
   the app's own `cancel()` stays unreported) live in `ConditionalUISteps` and the example.
6. `deviceOwnerAuth`/biometry probes: keep the `LAError` code, but expect "ok"
   under most real failures.

## 7. Not verified

S18 one-time-code fill (screen built, no SMS sender), S32 true biometry lockout, iPad
multi-scene blip noise, WKWebView surfaces, automatic passkey upgrades (S26/S27, modeling
deferred), any provider other than Bitwarden, iOS 17/18 delegate variants (singular
`shouldChangeCharactersIn` expected there; unmeasured).
