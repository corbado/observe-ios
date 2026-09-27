# AuthenticationServices & AutoFill — behavior research

Basis for the iOS Observe SDK tracking-model validation (how to track credential
operations). Sibling of `corbado/android` `docs/cm-af-research.md` — same lens per system
(*architecture · triggers · UI forms · effects · variants*), different actors. Compiled
2026-08-31 from Apple documentation, WWDC 2022–2025 sessions, Apple Developer Forums, the
**iPhoneOS 26.5 SDK interface** (ground truth for API surface/availability), and a large
production consumer app — **native2**, the iOS sibling of the android doc's `native1`
reference-integration role. Claims marked **[verify]** are exactly what the example-app
experiments must pin down — documentation is silent, vague, or sources contradict there.

Note: iOS 26 availability is spelled `ios(19.0)` in ObjC headers (pre-rename numbering);
cited as 26 throughout.

---

## 1. AuthenticationServices ceremonies (AS)

### 1.1 Architecture

- One machine for everything modal: `ASAuthorizationController(authorizationRequests:)` +
  delegate (`didCompleteWithAuthorization`/`didCompleteWithError`) + presentation anchor.
  iOS 13+. Providers: AppleID (SiwA), Password (keychain passwords), Platform passkey
  (API iOS 15, UX GA 16), SecurityKey (iOS 15).
- **Any provider mix in one controller**; exactly **one credential per ceremony** comes
  back regardless of mix. Passkey+password+SiwA in one `performRequests` is the WWDC22
  launch pattern. native2 mixes only platform+security-key (driven by server-sent
  `transports`/`authenticatorAttachment`) and never adds password/SiwA requests.
- Delegate is held **weakly**; nothing retaining delegate+controller ⇒ callbacks silently
  never fire (native2 keeps the delegate alive via closure self-capture — and consequently can
  never call `cancel()`). One-shot per attempt by convention; controller reuse undocumented
  **[verify]**.
- `performRequests(options:)` + `cancel()`: iOS 16. `RequestOptions` has exactly one
  member to date: `.preferImmediatelyAvailableCredentials`.
- Same controller class serves Conditional UI via `performAutoFillAssistedRequests()` (§3);
  a pending assisted request is the #1 cause of modal requests failing (§1.2).

### 1.2 When AS can be triggered

- **Only by an explicit app call** — no system-spontaneous sheet. The call site is a
  complete observation point (same property as Android CM).
- `.preferImmediatelyAvailableCredentials` (iOS 16+), per Apple engineers/WWDC:
  - no matching **local** credential → **no UI**, delegate errors immediately — the silent
    probe. The error is plain `.canceled` (1001), same code as user dismissal (WWDC22
    sample comment: "Either the user canceled the sheet, or there were no credentials
    available"). Silent = no UI; the delegate always fires.
  - credentials exist → the full normal sheet *including* cross-device options.
  - **ignored entirely when a security-key request is in the mix** (hardware prompt
    needs UI).
  - whether third-party-provider passkeys count as "immediately available" is
    undocumented **[verify]**.
- **One in-flight request per app.** A second `performRequests` (or a retry right after
  cancel, typically with an assisted request still pending) fails with "Request already in
  progress for specified application identifier" — Apple says cancel→retry should just
  work, developers reproduce the failure; workarounds: `cancel()` the old controller or
  ~1s delay. Exact surfaced error code **[verify]**.
- No documented cooldown/dampening after user cancel (unlike Chrome web) — empirical
  confirmation of absence needed per version **[verify]**.
- SiwA only: `getCredentialState(forUserID:)` is a sanctioned zero-UI probe
  (authorized/revoked/notFound) + `credentialRevokedNotification`. Nothing comparable for
  passkeys/passwords.

### 1.3 UI forms

| UI | When | Notes |
|---|---|---|
| **Sheet, single credential** | 1 match | collapses toward direct Face ID/Touch ID confirm; exact collapse conditions per version undocumented **[verify]** |
| **Sheet, account chooser** | multiple matches | passkey presented first; passwords behind "Other Sign-in Options". Whether passkey+password for the *same account* ever shows both: no authoritative source **[verify]**; forum report of a passkey-only request surfacing saved passwords is disputed by Apple **[verify]** |
| **Hybrid / cross-device QR** | passkey requested, zero local, default options | sheet appears anyway ("Choose how you'd like to sign in"); result via same delegate. Suppressed only by preferImmediatelyAvailable |
| **No UI at all** | preferImmediatelyAvailable + nothing local | instant `.canceled` — the silent probe |
| **Security-key prompts** | security-key request in mix | insert/tap key; disables the silent-probe option |
| **Provider unlock step** | third-party provider credential chosen (17+) | provider-owned vault-unlock UI between tap and result — distinct latency profile **[verify]** |
| **Account-creation sheet** (26) | `ASAuthorizationAccountCreationProvider` | prefilled contact+name+passkey, Face ID confirm; iOS 26.0 defect: only completes with Apple Passwords, third-party pick yields `.canceled` |

### 1.4 Effects on the login

Result families (one per ceremony): `PlatformPublicKeyCredentialAssertion` (login complete
up to server verification; UV happened in-ceremony), `…Registration` (enrollment, not
sign-in), `ASPasswordCredential` (user+password to app code; effect app-defined — submit
or prefill), `ASAuthorizationAppleIDCredential` (federated token → typically full login),
security-key siblings, and (26) `passkeyAccountCreation`.

`ASAuthorizationError` complete as of SDK 26.5 (domain
`com.apple.AuthenticationServices.AuthorizationError`):

| code | name | since | meaning |
|---|---|---|---|
| 1000 | unknown | 13 | shouldn't surface; reported on SiwA settings-alert dismissal **[verify]** |
| 1001 | canceled | 13 | user dismissal **or** silent no-credential probe **or** `cancel()` **or** third-party failure in the 26 account-creation flow — the overloaded code |
| 1002 | invalidResponse | 13 | malformed response; rare |
| 1003 | notHandled | 13 | no provider handled it; entitlement/config problems |
| 1004 | failed | 13 | generic; **the associated-domain failure** ("not associated with domain"); pre-18 also hid exclude-matches; inspect `NSUnderlyingErrorKey` |
| 1005 | notInteractive | 15 | non-interactive context |
| 1006 | matchedExcludedCredential | 18 | registration hit `excludedCredentials` (pre-18: 1004 — native2 string-matches a bogus `WKError` code 7 as its pre-18 workaround) |
| 1007/1008 | credentialImport/Export | 18.2 | credential-exchange failures (manager-app territory; codes shipped before the 26.0 manager API) |
| 1009 | preferSignInWithApple | 26 | user has a SiwA account and prefers it → start a SiwA request |
| 1010 | deviceNotConfiguredForPasskeyCreation | 26 | no passcode/keychain → fall back to standard signup |

- **The 1001 ambiguity is Apple-sanctioned** — no dedicated no-credential code ever
  shipped. Disambiguators: the flag was set + near-instant arrival (latency threshold — the
  native sibling of the web IMPK 1200ms heuristic; distributions unknown **[verify]**);
  localized failure string exists but breaks on non-English devices.
- Errors also arrive at the same delegate **outside** `ASAuthorizationError` (e.g.
  `NSCocoaErrorDomain 4097`, dead XPC agent) — classify by domain+code, never code alone.
- SDK-interface facts that contradict common web knowledge: `excludedCredentials` on
  platform registration exists only via the iOS 17.4 "WebBrowser"-named protocol category
  (no plain property); `shouldShowHybridTransport` is assertion-side only on iOS
  (registration-side is macOS-only). Extensions: largeBlob 17.0, prf 18.0,
  `requestStyle` 18.0.

### 1.5 Variants

- **15**: API exists, passkeys dev-preview. **16**: passkeys GA, options/cancel/CUI split,
  hybrid QR. **16.6**: `attachment`. **17**: third-party passkey providers, largeBlob,
  managed-attestation MDM. **17.4**: `excludedCredentials`. **18**: 1006, automatic
  upgrades (`.conditional`), prf. **18.2**: 1007/1008. **26**: account-creation provider,
  1009/1010, Signal API (`ASCredentialUpdater` — native2 already calls
  `reportUnknownPublicKeyCredential`), credential import/export,
  `/.well-known/passkey-endpoints`.
- Third-party provider active: sheet aggregates provider entries, selection routes through
  provider unlock; providers must implement each new API individually (upgrade/creation
  support varies).
- SiwA: same machinery; mixed AppleID+password chooser is the canonical launch pattern;
  `fullName`/`email`/`realUserStatus` only on **first** authorization — a SiwA success is
  not self-describing about new-vs-returning. native2 has no SiwA at all.

---

## 2. Password AutoFill / QuickType (AF)

### 2.1 Architecture

- Field classification is explicit-first (`textContentType` `.username`/`.password`/
  `.newPassword`/`.oneTimeCode`; SwiftUI modifier) **plus heuristics**: since iOS 12 any
  `isSecureTextEntry` field is treated as a password field regardless of contentType (why
  suppression tricks fail), and field order/labels infer login vs signup vs
  change-password.
- Stores: iCloud Keychain (fronted by the Passwords app since 18 — same store) + up to
  **3 simultaneous** credential-provider extensions (18+; pre-17: keychain + one
  third-party; the exact 1→3 release is unpinned **[verify]**). Providers hand the system
  metadata only (username+site) until the user picks.
- **Associated domains scope the chips**: QuickType offers only credentials for the app's
  `webcredentials` domains; the **key icon** always opens the full picker over *all*
  device credentials regardless. Without domains: no chip, no strong password, no
  domain-scoped save — manual picker still works.
- native2 reality: two-step flow forces a hidden 1px `.username` field (save-prompt pairing)
  and a hidden `.password` field on the *welcome* screen that harvests a QuickType pick
  and carries the password out-of-band through the flow so the password screen is skipped.
  A tracking model must be able to express "credential arrived before its screen existed."

### 2.2 When AF triggers

- **Field focus** on a supported view, given ≥1 saved password + AutoFill enabled. The
  chip is part of the QuickType bar, not a dismissible popup — no dismissal state, every
  focus re-shows it, no documented cooldown. Persistence while typing / after ignoring
  **[verify]**.
- Manual path: key icon any time the keyboard is up. App-side: no API to trigger (only
  `becomeFirstResponder` indirectly; `ASAuthorizationPasswordRequest` is the sole
  programmatic request and it's sheet-bearing) and no supported API to suppress.
- iPad hardware keyboard: QuickType bar absent; autofill only via the bottom shortcuts
  bar — evidence is 2018-era **[verify current iPadOS]**.
- MDM (supervised): `allowPasswordAutoFill=false` kills AF wholesale, incl. third-party
  providers.

### 2.3 UI forms

| UI | Notes |
|---|---|
| QuickType chip | best candidate(s) inline; multi-match chip count / provider slotting with 3 active providers undocumented **[verify]** |
| Key-icon full picker | all credentials, cross-domain |
| Face ID/Touch ID gate | on every credential chip tap, *before* fill |
| **Save/update prompt** | exists for native apps; associated-domain-gated; trigger = credential fields leaving the view hierarchy / VC closing after new text; save-vs-update by username existence. Can fire with untagged secure fields once domain trust exists (reported unwanted). Exact heuristics + suppression **[verify]** — native2 actively fights it by wiping field text |
| Strong password | `.newPassword` (+ domain) → pregenerated password UI; **acceptance auto-saves with no prompt**; `passwordRules` constrains format. native2 maps even new-password fields to `.password`, disabling this entirely |
| `.oneTimeCode` chip | SMS codes for ~3 min after receipt, pushed live into the bar if focused; no biometric gate **[verify]**. Plain SMS codes are **not** association-gated; only domain-bound codes (`@domain #code`) check associations. 26: third-party mail/messaging sources + delete-after-use |

### 2.4 Effects on the login

- One chip tap fills **all relevant views** (system force-moves first responder onto each
  and fills them — dataset-like, username+password together). Partial fills exist
  (username-only screens; multi-step quirks).
- **Never a completed authentication** — fill only, user still submits; Apple explicitly
  discourages auto-submit on fill detection. native2 auto-submits anyway (0.1s after
  bulk change).
- OTP: system inserts the whole code; segmented multi-field inputs redistribute it in
  `shouldChangeCharactersIn` — broken on iOS 26 (empty `replacementString`, §2.5).

### 2.5 App-side observability — the defining fact

**Confirmed absent (Apple-refused use case, unchanged 2017→26):** chip shown/hidden,
suggestion availability (no silent "does a credential exist" probe; the old
`SecRequestSharedWebCredential` is deprecated), fill occurrence as a first-class event,
save-prompt shown/outcome.

**What app code can see — the fill signature (Apple-documented):**

- per filled view: `textDidChangeNotification` ("always") + the matching delegate call
  (`shouldChangeCharactersIn` / `insertText`) with the value as one **bulk insertion**,
  not keystrokes;
- forced first-responder churn onto each filled view (begin/end editing without a tap);
- the Face ID gate is a **lifecycle blip**: `willResignActive` → `didBecomeActive`
  immediately before the text change — the strongest available password-fill fingerprint;
  timing distribution and whether OTP/username-only fills skip it **[verify]**;
- same-runloop ordering of the two fields' events: undocumented **[verify]**.

**Heuristic failure modes:** bulk-change also fires on paste, CJK marked-text commits,
dictation (Apple's on-record objection). `UIControl.editingChanged` is unreliable on
system fills; notification+delegate are the robust pair **[verify matrix per version]**.
No keyboard-geometry signal for chip presence **[verify]**. Native fields have no
`:-webkit-autofill`-style visual marker — no introspection signal. The lifecycle blip is
iPhone-strength only: on iPad, Split View/Stage Manager makes active-state churn ambient
(every neighboring-window focus switch), and LAContext app-lock gates produce the same
blip — blip+bulk-change coincidences become routine there **[verify]**. A second iPad
scene can also host its own login screen against the same tracker (interleaved flows).

**iOS 26 regressions (load-bearing):** new plural delegate
`shouldChangeCharactersInRanges` preferred by the system with inconsistent range values;
OTP fills arriving with an **empty** `replacementString`; transient focus loss during
fill. Every bulk-change heuristic (ours, and native2's three home-grown ones: >1-char
password insert → auto-submit, <0.5s OTP timing, 6-char paste) must be revalidated per OS
major **[verify]**.

### 2.6 Variants

- Third-party provider chips: rendered from provider metadata; tap → provider's own
  unlock UI → same system fill. App-side signature identical; latency differs.
- Providers gained passkeys 17, one-time codes + text-to-insert 18. Passkey storage is
  provider-locked (asserted only through the provider that holds it).
- Save-prompt routing with third-party providers (does anything replace the keychain
  save?): undocumented **[verify]**.

---

## 3. Conditional UI (CUI)

- `performAutoFillAssistedRequests()`: iOS 16+, **iOS-family only** (no macOS). Platform
  passkey **assertion only** — restriction is runtime, not type-level; other request
  types' behavior **[verify]**. Challenge must be mintable without a username
  (discoverable-credential flow); populated `allowedCredentials` filtering **[verify]**.
- Arm **before** the `.username` field gets focus ("so passkeys are ready when the
  keyboard appears"); arming after focus **[verify]**. Whether `.password` focus also
  surfaces the chip **[verify]**. Stays armed indefinitely across focus changes/keyboard
  dismissals; no documented timeout, but challenge staleness is real (no TTL documented)
  **[verify]**.
- **Cannot coexist with a modal request** — one in-flight request per app. WWDC22 frames
  the transition as "just swap the call"; practice requires `cancel()` first or the modal
  fails "already in progress". `cancel()` → delegate `.canceled`.
- Delegate outcomes: same `didCompleteWithAuthorization` as modal on chip-tap+Face ID.
  User never taps → **no callback at all**; focus loss/keyboard dismiss/backgrounding →
  believed silent **[verify]**. Re-arm semantics after completion/cancel **[verify]**.
- **No chip-visibility signal, deliberately** (anti-fingerprinting symmetry with web
  conditional mediation). Observable shape: armed → (silence | success | error) — display
  is never observable. Same shape as web CUI; the `cui-*` step guidance carries over.
- Classic password AutoFill on the same field is independent and unaffected — password
  chips come from AF, the passkey chip from the armed request; a password pick fills
  fields and leaves the CUI request running. Chip ordering/dedup for the same account
  (passkey vs password chip): undocumented — iOS has **no** Android-style "safest method"
  rule **[verify]**.
- Early-OS reality check: chips were absent on 16.1–16.2 (fixed 16.3) — absence-of-chip
  is not absence-of-passkey; caveat for any timing heuristic.
- native2 does **not** use CUI. Its "conditional passkey modal" is a modal assertion
  auto-fired on the welcome/onboarding screens with preferImmediatelyAvailable — the
  silent-probe pattern — and `.canceled` is swallowed with zero telemetry today.

**Automatic passkey upgrades** (`requestStyle: .conditional` on *registration*, iOS 18+):
opportunistic, zero UI either way. Conditions: provider set up + supports upgrades +
device passkey-capable, and — decisive — the same credential manager **just filled** a
password for that account (typed passwords don't qualify; iCloud Keychain additionally
wants RPID==saved-domain, no existing passkey, sync on; 18.4 "loosened" conditions
unspecified **[verify]**). Outcome is binary: credential, or one generic error meaning
"not this time" — indistinguishable from a plumbing bug **[verify userInfo]**. Apple's
guidance: attempt on every password sign-in ⇒ app-side, upgrade rate is only measurable
as successes over password logins — a natural Observe funnel.

---

## 4. Cross-cutting gates

### 4.1 Associated domains (`webcredentials`)

- Gates: modal passkey ceremonies (unassociated RP ID → **1004** `failed`, "not
  associated with domain"; whether any path surfaces as 1001 **[verify]**), CUI, AF chip
  scoping, save prompt, strong password. NOT plain SMS OTP (domain-bound format only).
- AASA served via **Apple's CDN**, fetched at install/update + ~weekly; first ingestion up
  to 24h; device-side **cached failure** states exist (one production report: ~5% of users;
  healing without reinstall **[verify]**).
- `?mode=developer` + Settings toggle bypasses the CDN — **development-signed builds
  only**.
- The same CDN + cached-failure mechanics govern `applinks`: a magic-link universal link
  then opens in Safari instead, and the flow finishes outside the app entirely.
- **Simulator**: passkey ceremonies work (simulated Face ID; vendor guides demo full
  ceremonies) *iff* the AASA is on a real public domain; the simulator was never observed
  fetching AASA from origin even in developer mode, and local/self-signed domains fail
  with 1004. Working assumption: simulator uses the CDN path **[verify]** — decides our
  experiment infra (public AASA domain, e.g. a staging domain, vs device-only).

### 4.2 Environment matrix

| | Simulator | Real device |
|---|---|---|
| Biometrics | simulated (Features > Face ID, ⌘⇧M) | real |
| Modal passkey ceremony | works with public-AASA domain | works |
| AASA developer mode | apparently no-op **[verify]** | works (dev-signed) |
| iCloud Keychain sync | non-functional; passkeys local-only **[verify persistence]** | needs iCloud+2FA |
| QuickType / Password AF | notoriously flaky (no autofill on some versions, missing save dialog) **[verify]** | works |
| CUI chip | reliability unknown **[verify]** | works |
| Hybrid/QR | no (camera/BT) | works |

- MDM can kill AF wholesale, block password sharing, require enterprise passkey
  attestation (17+). China: iCloud by GCBD; passkey-creation failures plausibly from
  CDN/well-known unreachability — relevant only if a customer ships there.

### 4.3 Web-auth surfaces (scope note)

- `ASWebAuthenticationSession` / `SFSafariViewController` (OAuth, SSO, web fallback): the
  *Safari* credential stack applies — passkeys/AF run against the **website's**
  `webcredentials`; the app's own associations are irrelevant.
  `prefersEphemeralWebBrowserSession=true` silently disables cookie sharing *and* the
  save/strong-password prompts. Observable at exactly two points — session start and
  callback-URL-or-error — the whole middle of the login is a black box, and
  `canceledLogin` is another overloaded cancel (user dismissal vs app cancel vs
  presentation failure).
- `WKWebView` login pages: WebAuthn works only for the app's associated first-party
  domains (arbitrary origins need the browser entitlement); third-party credential
  providers never surface into WKWebView; AF follows HTML `autocomplete` semantics, not
  `textContentType` — every §2.5 fill signature differs there **[verify]**. native2 has
  WebView login surfaces (the android doc flags the same for native1).

### 4.4 Process & timing realities

- **Prewarming**: iOS launches app processes without UI; `didFinishLaunching` has been
  observed running during prewarm (15 *and* 18), and the `ActivePrewarm` env marker is
  unreliable on 16+. Prewarm before first unlock runs with
  `isProtectedDataAvailable == false` — UserDefaults and protected files are unreadable,
  so an SDK init there re-mints device identity and misses outbox recovery; prewarmed
  launches also fake session starts **[verify]**.
- **Magic links**: the journey exits to Mail and returns via universal link into a
  possibly fresh process (old one jetsam-killed) — flow start and finish land in
  different sessions unless the model stitches them.
- **Wall clock only**: `Date()` timing (including the §7.1 latency disambiguator) is
  distorted by mid-sheet suspension (incoming call, app switch — the sheet survives) and
  clock changes. The monotonic alternatives (`systemUptime`, `mach_absolute_time`) are
  required-reason APIs and pause during device sleep — no `elapsedRealtime` equivalent.
- **Biometry states**: biometry lockout (5 failed attempts) makes `canEvaluatePolicy`
  report a Face ID device as passcode-only (capability-cohort pollution — the LAError
  distinguishing lockout/notEnrolled/passcodeNotSet is easy to discard) and turns passkey
  ceremonies into passcode-fallback UX with different latency/cancel profiles
  **[verify]**.

### 4.5 OS delta table

| iOS | Credential-surface changes |
|---|---|
| 16 | passkeys GA; modal/CUI split; `preferImmediatelyAvailableCredentials`; `cancel()`; hybrid QR |
| 17 / 17.4 | third-party passkey providers; largeBlob; `excludedCredentials` (17.4, WebBrowser category) |
| 18 / 18.2 / 18.4 | Passwords app; automatic upgrades; `matchedExcludedCredential`; prf; provider OTP; 3-provider AutoFill; credential-exchange error codes (18.2); upgrade-condition loosening (18.4) |
| 26 | account-creation provider (+1009/1010); Signal API (`ASCredentialUpdater`); credential import/export; `/.well-known/passkey-endpoints`; OTP from third-party mail/messaging + delete-after-use; **AF delegate regressions** (§2.5); zeroed AAGUID on consumer keychain passkeys |

---

## 5. How the systems combine in practice

1. **The same credential reaches the user through up to three surfaces**: a saved password
   via AS sheet (`ASAuthorizationPasswordProvider`), QuickType chip, or a native2-style
   hidden-field harvest; a passkey via modal sheet or CUI chip. Which surface wins depends
   on what the app calls and what it armed first — same double-journey reality as Android,
   with identical-looking form submissions at the end.
2. **Recommended pattern** (WWDC): arm CUI on screen load, modal on button tap — with the
   undocumented-in-sessions trap that the CUI request must be canceled first.
3. **No dedup rule**: Android 14+ documents "safest method" dedup; iOS documents nothing —
   passkey chip (CUI) and password chip (AF) for one account coexist by different
   mechanisms **[verify]**.
4. **Production reality (native2)**: modal-only (no CUI, no SiwA, no strong password); silent
   probe on welcome/onboarding; out-of-band password harvest via hidden field; active
   save-prompt suppression; three home-grown fill heuristics; **zero analytics on any
   credential surface today** — sheet shown/canceled/failed is currently unmeasurable.
   That gap is precisely Observe's pitch, and the reason the `.canceled` ambiguity and the
   fill fingerprint matter most.

---

## 6. Observability map (what our SDK/mapping layer can see)

| Surface | Observable? | How |
|---|---|---|
| AS modal ceremony (any provider mix) | **fully** | call-site decoration: request options, timing, typed result/error. Caveats: 1001 overload; non-AS error domains at the same delegate |
| Silent probe (preferImmediatelyAvailable) | **fully, ambiguously** | instant `.canceled` vs human dismissal — latency threshold required **[verify distributions]**, incl. provider-unlock tail |
| CUI armed request | **partially** | arm/cancel/success/error observable; chip display and user-ignore invisible (silence) — by design |
| Automatic upgrade attempt | **binary** | credential or generic "not this time"; rate-over-password-logins is the metric |
| SiwA | **fully + probe** | ceremony + `getCredentialState` + revoked notification; first-auth-only fields mark new-vs-returning |
| Classic AF password fill | **heuristics only** | bulk-insert delegate/notification per view + forced first-responder churn + resignActive→becomeActive blip **[verify timing]**; iOS 26 delegate regressions |
| AF affordance (chip shown/available) | **not at all** | Apple-refused use case; no probe API. Our `af-shown/af-hidden` taxonomy has **no iOS emitter** — manual FieldObserver only (known limitation) |
| Save/update prompt | **not directly** | only inferable from next-visit credential availability (same as Android) |
| ASWebAuthenticationSession / SFSafariViewController | **endpoints only** | session start + callback-or-error; `canceledLogin` overloaded; the middle is a black box |
| WKWebView login pages | unmapped | HTML-autocomplete AF signatures, first-party-only WebAuthn — different rules throughout **[verify]** |
| Strong-password generation | partially | `.newPassword` field + bulk insert; acceptance auto-save invisible |
| `.oneTimeCode` fill | heuristics only | bulk insert; no biometric blip expected **[verify]**; iOS 26 empty-string bug |

---

## 7. Open questions → experiment matrix input

Ordered by leverage for the tracking model.

1. **`.canceled` latency distributions**: silent no-credential vs human dismissal vs
   provider-unlock, per surface and provider — the native IMPK-threshold sibling. Decides
   whether system-credential silent-probe suppression can ever be made honest.
2. **Fill signature anatomy**: both-field fills — event order, same-runloop or not,
   notification vs delegate reliability, `editingChanged` matrix, on 17/18/26 (plural-
   ranges delegate); OTP vs password vs username-only differences.
3. **Lifecycle blip**: resignActive→becomeActive presence/timing per fill type and
   provider; false-positive rate — especially iPad multi-scene ambient churn and
   LAContext app-lock gates (any other cause of blip+bulk-change within ~1s?).
4. Sheet dedup: combined passkey+password request for an account holding both — what
   shows; passkey-only request + password-only user.
5. Single-credential collapse (straight to Face ID) — exact conditions per version.
6. Re-trigger after cancel: "already in progress" reproduction without a pending assisted
   request; exact error of a second concurrent controller; controller reuse.
7. CUI lifetime: arm-after-focus, timeout/challenge staleness, delegate silence on focus
   loss/backgrounding, re-arm after completion/cancel, `.password`-field trigger,
   non-assertion request types, populated allowedCredentials.
8. Chip semantics: persistence while typing, multi-credential chip counts, passkey-vs-
   password chip slotting for one account, 3-provider slotting.
9. Save/update prompt: exact disappearance heuristics, suppression, third-party routing,
   fire-without-adoption on trusted domains.
10. `.conditional` upgrade: userInfo distinguishability of "conditions unmet" vs
    misconfiguration; the 18.4 loosening; third-party-provider condition deltas.
11. `preferImmediatelyAvailableCredentials` with third-party-provider-only passkeys.
12. Simulator infra: AASA-via-CDN hypothesis, CUI chip + QuickType reliability, passkey
    persistence without iCloud — decides device vs simulator per experiment group.
13. ~~Association failure surfacing~~ — dropped 2026-09-01: signature already pinned by
    research (1004 + "not associated" message), enough for backend classification; not
    worth breaking a live association for (android never tested its sibling either).
14. iPad hardware-keyboard AF path on current iPadOS.
15. Domain-bound SMS chip in native apps: association strictly required for the chip?
16. iOS 26 sheet chrome/dedup changes (no source addresses them).
17. Web surfaces: `canceledLogin` disambiguation (latency again?); WKWebView fill
    signatures and WebAuthn behavior on associated domains.
18. Prewarming: `ActivePrewarm` reliability at the recommended init point;
    prefs/outbox behavior when protected data is unavailable at init.
19. Biometry lockout: how often capability probes misreport locked-out devices; ceremony
    latency/cancel profile under passcode fallback.

---

## 8. Verified findings (manual tests)

Dated entries with SDK consequences, appended as experiments run — never silently merged
into the prose above.

- **2026-09-03 · S1 silent probe, simulator (iOS 26.5, no local passkey).** `performRequests`
  with `.preferImmediatelyAvailableCredentials` settles as `ASAuthorizationError` 1001 with
  message *"No credentials available for login."* after ~500 ms on the first run. No UI. The
  message differs from a user dismissal, but it is localized (§1.4) — the SDK keeps classifying
  on flag + code, the message rides along as raw error data. Latency is not instant; the
  distribution question (§1.4 [verify]) stays open for repeated runs and devices.
- **2026-09-03 · Associated domains, simulator.** Ceremonies fail with 1004 *"Unable to verify
  webcredentials association … Please try again in a few seconds"* when the ceremony races the
  install-time AASA fetch; a relaunch a few seconds later succeeds. Apple's CDN
  (`app-site-association.cdn-apple.com/a/v1/<domain>`) served an updated AASA within minutes
  of deployment — the ~24h ingestion figure is an upper bound. The simulator resolved the
  association through the CDN (no developer-mode path exists there), settling §4.1 [verify].
- **2026-09-03 · Entitlements on the simulator.** Xcode strips *all* entitlements from
  ad-hoc-signed simulator builds when the app id cannot be provisioned for the team; the
  symptom is 1004 *"The calling process does not have an application identifier"*. A bundle id
  already registered to another team blocks provisioning silently on simulator builds (the
  device build surfaces "Failed Registering Bundle Identifier"). Fix: unique bundle id + one
  `-allowProvisioningUpdates` build.
- **2026-09-03 · Full situation run, simulator (iOS 26.5, one account with password + one
  passkey, hardware keyboard).** S1–S4, S8–S9, S11–S14, S19, S21–S24 recorded; findings:
  - *1001 disambiguation:* the no-credential probe answer carries "No credentials available
    for login." (444 ms cold, 25 ms warm); every user dismissal and every `cancel()` carries
    only the generic "error 1001" text. Message is a real (localized) disambiguator on top of
    the flag; `cancel()` is indistinguishable from a dismissal by code *and* message — the
    integration must know it cancelled (§3 handover).
  - *S2 spec identity:* the same `passkey-immediate` request shows the full sheet once a
    passkey exists (dismissal 1001 after seconds; success as normal assertion). Silent vs shown
    is only visible through duration + message.
  - *S4 single-credential collapse:* usernameless request with one passkey collapses to a
    direct Face ID confirm (tester report) — §1.3 collapse [verify] observed once.
  - *S8 retry after dismissal:* modal re-fire 1.1 s after a dismissed auto sheet succeeded;
    no "already in progress" once the first request had settled.
  - *S9 exclude match:* second registration for the same account → 1006 after 6.3 s (the
    sheet appears and the user confirms before the rejection; not an instant answer).
  - *S23 collision:* a modal `performRequests` while an assisted request is armed fails
    **instantly with 1004** "Request already in progress for specified application
    identifier." (4 ms) — not 1001; the armed request survives and keeps working. `cancel()`
    → delegate 1001 within 3 ms; a modal request 50 ms later succeeds. §1.2 [verify] settled.
  - *S22 silence:* typing, keyboard dismissal, backgrounding (`didEnterBackground`) and a
    failed identifier submit never settle an armed request (observed over 50–90 s); only
    `cancel()` or a pick does. §3 [verify] settled for those cases.
  - *S24 same account, passkey + password:* the full picker lists both — "Passkeys" section
    first, "Passwords" second; a password pick fills both fields and leaves the armed request
    running (cancelled only on navigation, 92 s later). Chip *ordering* still needs a device:
    the simulator with a hardware keyboard never showed a QuickType bar, every pick went
    through the key-icon picker (S15 path), which also surfaces the armed passkey.
  - *Fill signature (S11/S12/S13/S14):* per filled view one `shouldChangeCharactersInRanges`
    (iOS 26 plural delegate; the singular one never fired, for typing either) with the full
    value as one replacement, one `textDidChange`, forced `begin/endEditing` churn between
    views, all within ~50 ms; identifier before password; the hidden 1 pt `.username` field
    (S12) and the hidden `.password` harvest field (S14) are filled like visible ones. The
    **Face ID blip was not adjacent** to the fill on the simulator (3–15 s earlier: the picker
    sheet closes before the simulated Face ID) — blip adjacency (§2.5) must be measured on a
    device.
  - *S19 paste:* `UITextField.paste(_:)` fires ~15 ms *before* the delegate call, so a
    paste flag must outlive the paste call (fixed in the probe); paste of 9 / 20 chars is a
    bulk change with no responder churn, as expected.
  - *Simulator limits:* no QuickType bar with a hardware keyboard, so chip-dependent
    situations (S21 chip pick, S24 chip order, S25 arm timing) and blip adjacency need a
    device run; everything ceremony-side transferred.
- **2026-09-03 · Device run (iPhone 13 on iOS 27.0 beta, iCloud Keychain, one account holding
  a password and a passkey; d-setup, S1, S9, S11, S12, S13, S21, S24, S25).** Findings,
  device-specific unless noted:
  - *Blip adjacency (§2.5, §7.3) settled:* every AutoFill fill sits **inside** the Face ID blip.
    Order: chip tap → `willResignActive` → fill ~0.5 s later while inactive → `didBecomeActive`
    ~1.2 s after the fill. Blip length was 1.69–1.74 s in all six fills. Modal ceremonies look
    different: the app is inactive for the whole sheet (S9 registration: 4.2 s blip around a
    3.8 s ceremony). A blip without bulk changes is sheet-shaped, a ~1.7 s blip with bulk
    changes inside it is fill-shaped.
  - *Chip-tap precursor:* ~100 ms before `willResignActive` the focused field receives one
    `shouldChangeCharactersInRanges` with an **empty replacement** (5 of 5 chip picks: S11,
    S12, S13, S21 passkey chip, S25). The picker-path pick in S24 did not have it. Candidate
    early "system fill incoming" signal; the passkey chip produces it too, so it flags the
    tap, not the credential type.
  - *S13 identifier-only fill:* the Face ID blip fires for a lone `.username` field as well
    (tester: "Face ID was asked for identifier only") — §2.4 [verify] settled: no
    password-free exemption.
  - *S12 hidden identifier:* the hidden 1 pt field is **replaced** (delete 16 + insert 16 as one
    ranges call), not appended; visible fields go from empty to full. Same-millisecond fill of
    both views confirmed on device.
  - *S11 chip presence:* chip above the keyboard plus the key icon, both present (tester).
  - *S21 chip pick:* armed at flow start, chip visible on focus; pick → precursor → blip →
    assertion delivered 0.5 s after the tap, inside the blip; `login_success` before
    `didBecomeActive`.
  - *S24 chip order (tester):* passkey chip first, then the email + password chip. The recorded
    pick went through the picker (blip 8 s before the fill, no precursor); the password pick
    left the armed request running until navigation cancelled it (generic 1001 after 33 s) —
    same as the simulator.
  - *S25 not measured:* the flow-start-armed request from the previous attempt survived a screen
    change (SwiftUI view torn down, request alive). Every arm-on-focus then failed with 1004
    "Request already in progress" in ~95 ms (three tries), and the stale request delivered the
    pick 77 s after arming, on a re-created screen. **Armed requests are process-scoped, not
    view-scoped**: an integration that navigates away without `cancel()` gets 1004 on its next
    arm and a late success on the wrong screen. Example app now cancels on disappear.
  - *S25 arm after focus (re-run, clean):* armed 100 ms after focus, chip visible immediately
    (tester). The request survived two focus-loss/regain cycles over 13 s and settled on the
    chip pick with the usual precursor → blip → assertion 0.5 s after the tap. Arm timing does
    not matter on this OS; §3 [verify] for arm-after-focus settled.
  - *S1 on device:* 1001 "No credentials available for login." in 81 ms cold, 32 ms warm (sim:
    444 / 25 ms). Silent-probe latency is one order below any human answer on both.
  - *Setup / S28:* the suggested-strong-password insert calls the plural delegate **twice** with
    the same 20-char replacement and posts one text change. Account creation produced no
    lifecycle event at all; the credential existed afterwards, but a save prompt and the
    strong-password auto-save are indistinguishable from the app.
  - *Tooling:* the SDK's debug-level `Track:` lines are not persisted on device, so
    `log collect --device` (root) returned nothing; device runs currently yield probe data
    only. SDK-side mapping was verified on the simulator run and is code-path identical.
- **2026-09-03 · Third-party provider + lockout run (same iPhone 13 / iOS 27.0 beta, Bitwarden as
  the only enabled credential provider for S17/S10/S1; iCloud Passwords re-enabled for S32).**
  - *S17 provider chip, three distinct paths:* (a) Bitwarden **unlocked** → chip like iCloud
    Keychain: precursor → `willResignActive` → 1.73 s blip → but the fill lands **~200 ms after
    `didBecomeActive`** (iCloud fills inside the blip). Same-millisecond two-field fill and
    responder churn otherwise identical. (b) Bitwarden **locked** → no chip; key icon → the
    provider's own unlock UI → pick: the fill arrives with **no lifecycle event and no precursor
    at all** (2 of 2), only the bulk change + responder churn. The provider extension UI does
    not resign the app. (c) key-icon picker with the provider unlocked behaves like (a) minus the
    precursor. So the blip is a Keychain/unlocked-provider artefact, not a fill invariant:
    the fill detector must rest on the bulk-change + churn shape and treat the blip as
    corroboration. §7.2/§7.3 provider deltas settled for one provider.
  - *S10 provider ceremonies:* registration into Bitwarden 24.1 s (sheet announced the provider,
    tester); assertion 6.9 s. Delegate identical, the app stays inactive for the whole
    provider UI (blip = ceremony + ~0.5 s, like Keychain). Latency tail is the only delta.
  - *S1 with a provider-only passkey:* `.preferImmediatelyAvailableCredentials` **counts
    provider passkeys** — the full sheet appeared and the assertion completed (13.2 s).
    §1.2 [verify] settled: silent-probe suppression cannot assume Keychain-only.
  - *S32 lockout not reached:* covering the camera produces no-face timeouts, not mismatches,
    so `LAContext` reported "ok" before every ceremony and no lockout occurred. The sheet still
    fell back to passcode: passcode-completed successes took 11–28 s (normal ~7 s), a cancel
    after failed attempts was 1001 at 25 s, a straight dismissal 1001 at 0.95 s. App-side,
    passcode fallback is invisible except through duration. A real lockout needs five
    mismatching faces — left open.
  - *S18 OTP:* screen built, not run (no SMS sender at hand) — left open.
- **2026-09-03 · Plain SwiftUI form (TextField + SecureField, `@FocusState` only, same
  iPhone 13 / iOS 27.0 beta, Keychain chip).** Chip path: focus set to identifier → blip →
  identifier value lands (16 chars, one change) → **FocusState hops identifier → password** →
  password lands 30 ms later → `didBecomeActive` 1.2 s after. So SwiftUI does report the
  responder move of a two-field fill, minus the UIKit-visible return hop. Picker path (key
  icon, field = password): **no focus change at all**; both values land in the same
  millisecond 3.3 s after the unlock blip, focus stays on password. FocusState only reflects
  a hop that ends on another field; the transient begin/end churn on the same field is
  collapsed. Value changes arrive as one bulk change per field on both paths.
- **2026-09-03 · S5/S6 mixed request (same iPhone 13 / iOS 27.0 beta, Keychain holding a
  password and a passkey for the account).** One controller with a passkey assertion request
  and `ASAuthorizationPasswordProvider`:
  - *Passkey wins:* with both credentials present the sheet offered **only the passkey**
    (tester; 3 of 3 picks were assertions, 4.7–10 s). The password appeared as a result only
    once no passkey was available (`ASPasswordCredential`, 4.8 s). §1.3 [verify] "same
    account, both shown" → no: the chooser collapses to the passkey.
  - *`preferImmediatelyAvailableCredentials` with a password in the mix:* the sheet still
    shows when a credential exists (success 4.1 s, dismissal 1001 generic after 2.3 s). The
    SDK's system-credential rule "flag + 1001 ⇒ not shown" therefore swallows a real dismissal
    on iOS — 1001 is overloaded here, unlike Android's distinct `NoCredentialException`.
  - *S6 password-only request:* password chooser + Face ID, `ASPasswordCredential` with the
    Keychain password (20 chars) after 6.1 s; the app submits it, no form involved.
  - The app is inactive for the whole sheet in every variant (blip = ceremony + ~0.3–0.6 s).
- **2026-09-03 · SDK consequence of S5/S6.** The system-credential "flag + 1001 ⇒ not shown"
  rule quoted above is gone: emission is eager (subflow start and ceremony start on `begin`),
  a probe flags both as `ignoreAsInteraction`, and every settle ships raw. Dismissal vs
  no-credential under the flag is a backend duration rule.
