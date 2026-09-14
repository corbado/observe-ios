# Limitations

Known, accepted gaps of the iOS Observe SDK versus its Android/web siblings.

- No automatic autofill-affordance signals (`af-shown`/`af-hidden`/`af-unavailable`): iOS has
  no API to observe the QuickType/password-autofill bar; only manual `FieldObserver` reporting.
- Password-fill detection is the bulk-change heuristic; `window-blur`/`window-focus` (Face ID
  blip) and `focus`/`blur` (responder churn) only corroborate — a fill through a locked
  third-party provider's own UI leaves neither, SwiftUI focus forwarding sees the churn only
  when focus ends on another field, and integrations that forward lengths only get no window
  lows around fills (window lows are armed by ceremonies and focused fields).
- Focus arming is closed by the integration only: a field torn down while focused without a
  forwarded `focusChanged(false)` keeps the window lows armed (Android resets on activity pause;
  iOS has no screen-scoped equivalent).
- While a field is focused, every active-state churn emits the `window-blur`/`window-focus`
  pair: a real backgrounding, notification banners, Control Center, and on iPad Split View /
  Stage Manager focus switches — same shape as a Face ID blip; the backend separates them.
- Window lows are emitted by the SDK but the backend runs no ceremony detector for app client
  environments yet (see TASKS.md); today they are stored, not matched.
- Modal ceremonies ship `ASAuthorizationError.canceled` (1001) raw whether it was a user
  dismissal or the instant no-credential answer under `preferImmediatelyAvailableCredentials`
  (which also shows the sheet when a credential exists). The backend uses a 1200ms
  heuristic for immediate cancellation; fast dismissals and slow silent responses remain ambiguous.
  For conditional UI the 1001 after the
  app's own `cancel()` is left unreported by contract (`ConditionalUISteps`).
- Background flush is limited to the `beginBackgroundTask` grace window; anything undelivered at
  suspension ships via outbox recovery on next launch.
- Ceremony `error.type` is NSError `domain:code` (Android: fully-qualified exception class
  name) — platform-inherent; the backend stores `name`/`code`/`message` only, so the flavour
  identity today is the Swift type name plus the localized message (see TASKS.md).
- `destroy()` drains with configured retries and can keep the worker alive through backoff.
  A subsequent `initialize()` queues work until that shutdown completes before opening shared
  storage; those replacement-instance calls are not durable while waiting.
- Native event durability and session continuity are always enabled; web-only feature switches
  do not disable them. Config refresh is suspended while iOS suspends the app.
- Repo-wide SPM versioning; no per-library release tags (unlike `corbado/android`).
- `Sdk.version` is hand-bumped at release; no build-time injection.
- No macOS-host `swift build`/`swift test` (UIKit dependency); simulator only.
- App targets only: extensions are blocked at init, but the SDK links non-extension-safe
  API (`UIApplication.shared`) — behavior when linked into extension processes undefined.
- "Designed for iPad" on Mac and visionOS runs are unvalidated; device info reports them
  as iOS.
- Web-auth surfaces (`ASWebAuthenticationSession`, WKWebView logins) are outside the
  tracking model; only their endpoints are instrumentable.
