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

## Data policy

Select one of the project's data policies configured in Corbado (they control retention) by
its code, 0...255 with 0 as the project default:

```swift
ObserveOptions(projectId: "pro-...", apiBaseUrl: "https://api.cloud.corbado.io", dataPolicy: 0)
tracker.setDataPolicy(1)   // e.g. once the user agreed to extended processing
tracker.getDataPolicy()    // current code, nil while none was ever set
```

The persisted code loads asynchronously during initialization, so pass the code you intend
rather than deciding based on `getDataPolicy()` right after init.

Once set, the code is sent with every batch and persisted per project across launches,
`resetSession` and `destroy`; it is only ever overwritten, never cleared. The init option
overlays the persisted code; invalid codes are ignored. Nothing is sent until a code is set.

See [`examples/observe`](../examples/observe/) for a runnable app and
[limitations](../docs/LIMITATIONS.md) for known platform gaps.
