# CorbadoObserve

Corbado Observe SDK for iOS — authentication observability. Instrument your auth flows
and make them visible in the Corbado developer panel.

The iOS sibling of [`@corbado/observe`](https://github.com/corbado/js) (web) and
[`com.corbado:observe`](https://github.com/corbado/android) (Android).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/corbado/ios.git", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "CorbadoObserve", package: "ios")
    ])
]
```

## Quickstart

```swift
import CorbadoObserve

// App startup (explicit — the SDK is inert until you call this):
let tracker = CorbadoObserve.initialize(
    options: ObserveOptions(projectId: "pro-...", apiBaseUrl: "https://api.cloud.corbado.io"))

// Auth journey:
guard let tracker else { return }
tracker.flowStarted("login")
let op = tracker.passwordLoginOperation()
op.start(specType: .withIdentifier)
// Field evidence (lengths and focus only, never values):
//   .onChange(of: password) { op.passwordField.changed(newLength: $0.count) }
//   .onChange(of: focus)    { op.passwordField.focusChanged($0 == .password) }
// UIKit: the same two calls from textDidChange / didBegin- and didEndEditing.
op.postResponse.start()
// ... call your backend ...
op.postResponse.finished(options: StepOptions(userReference: UserReference(userId: "usr-1")))
tracker.flowFinished("login")
```

The tracker also reports the app's active-state churn around system UI (`window-blur` /
`window-focus`) while a ceremony runs or a field is focused — the Face ID gate of a password
fill and every system sheet show up there. See `docs/as-af-signal-spec.md` for what these lows mean.

See [`examples/observe`](../examples/observe/) for a runnable app,
[TASKS.md](../TASKS.md) / [limitations](../docs/LIMITATIONS.md) for status.

## Reliability configuration

The SDK starts immediately with its last-known cached policy (or native defaults). It fetches
`GET /v1/observe/config/{projectId}?sdkName=observe-ios` independently of event delivery, then
applies valid policy live and caches it for the next launch. Event requests no longer negotiate
configuration or consume configuration response bodies. The backend must support the `sdkName`
selector so native clients receive app policy; deploy that backend support before releasing this SDK.

Config requests have a 10-second timeout and retry transient network errors, 408, 429 and 5xx
responses after 1 second and then 3 seconds. A `Retry-After` header suppresses these immediate
HTTP retries. Other HTTP errors, malformed JSON and missing/empty policy versions wait for the
next regular refresh. Refresh runs every 10 minutes from the start of the previous refresh,
independently of its retries; failure keeps the last-known policy. Shutdown cancels config work
without waiting for it. Public calls, event recording and ingestion keep running during config I/O.

Use `apiConfigPath` to mount configuration under a proxy path on the same `apiBaseUrl`:

```swift
ObserveOptions(
    projectId: "pro-...",
    apiBaseUrl: "https://auth.example.com",
    apiConfigPath: "/observe/config",
    sdkConfig: SdkConfigOverrides(
        telemetry: false,
        retry: RetryConfigOverrides(maxAttempts: 3)
    )
)
```

Explicit `sdkConfig` fields override server policy and defaults; retry fields merge individually.
A complete override (every native policy field, version and all retry fields) skips both config
fetching and its cache. The existing `flushOnBackground: false` option remains a host-side veto.
Native durable event storage and session continuity remain always enabled. A live update preserves
queued events and session identity and does not restart an active delivery or shorten its backoff.
