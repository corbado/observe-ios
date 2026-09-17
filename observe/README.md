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

## Optional raw-error diagnostics

Keep the normalized `error` for classification and attach optional diagnostics through `StepOptions`:

```swift
attempt.failed(error, options: StepOptions(rawError: .error(error)))
// Also supported by ceremonyFailed, StepHandle.error/errorTyped and conditional-UI errors.
```

Both an explicit `rawError` input and cached server config `rawErrors: true` are required.
The native fallback is **off**. Config received through event delivery is cached for the next
SDK initialization, including disabling the feature. This uses the existing config mechanism;
it does not require the separate live-config API. Ordinary `.error(error)` calls do not opt in.
Diagnostics appear as `stepData.rawError = {type, value}` only on `subflow_step_error`.
Disabled policy, non-error events and disabled collection do not traverse or serialize the input.
Serialization runs on the SDK worker before persistence, without changing normalized errors,
timestamps, user references or event ordering.

On iOS, `.error(error)` preserves the Swift type, NSError `domain` and numeric `code`, explicit
localized description/failure reason/recovery suggestion/debug description, and underlying errors.
It reads only these known `userInfo` keys; URLs, file paths, binary data and arbitrary objects are
excluded. For extra application-specific fields, supply `.value(.object([...]))` with `JSONValue`
scalars/containers. No reflection of Swift associated values or arbitrary object descriptions occurs.
Messages and explicit projections may contain personal data: only supply data suitable for
transmission. The privacy manifest declares diagnostics as linked because they accompany auth events.

Swift/NSError does not retain a throw-site stack. If your integration already captured one:

```swift
let options = StepOptions(
    rawError: .error(error, stack: capturedStackFrames),
    rawErrorLimits: RawErrorOptions(stack: true))
attempt.failed(error, options: options)
```

The SDK never substitutes the serialization worker's stack. `stack` fields in JSON projections
are omitted unless stack transmission is enabled too. Stack capture itself is the caller's work;
passing a computed value evaluates it even when remote diagnostics are off.

Default bounds match Android/web: depth 3, breadth 30, 1,024 UTF-16 units per string, 3 cause hops,
50 stack frames, 32 KiB of encoded JSON. `RawErrorOptions` clamps depth/cause depth to 0–10,
breadth to 1–1,000, string length to 1–10,000, frames to 1–100 and bytes to 0–64 KiB.
A 1,024-node traversal budget also bounds branching graphs; NSError cycles are marked. Oversized
values retry at lower depth, then emit a truncation marker or are omitted if even that cannot fit.
Zero bytes omits diagnostics. Foundation-supplied errors and Sendable JSON values are supported;
custom error accessors must obey Swift's Sendable contract and must not block or raise Objective-C
exceptions (Swift cannot catch those). No arbitrary userInfo collection is performed.

`serializeRawError(_:options:)` exposes the same bounded serializer as a standalone utility.
It has no config gate; use `StepOptions` when you want SDK policy to control serialization.
