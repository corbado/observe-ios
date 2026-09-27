# CorbadoObserve

Corbado Observe SDK for iOS — authentication observability. Instrument your auth flows
and make them visible in the Corbado developer panel.

The iOS sibling of [`@corbado/observe`](https://github.com/corbado/js) (web) and
[`com.corbado:observe`](https://github.com/corbado/android) (Android).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/corbado/observe-ios.git", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "CorbadoObserve", package: "observe-ios")
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

See [`examples/observe`](../examples/observe/) for a runnable app and
[limitations](../docs/LIMITATIONS.md) for known platform gaps.
