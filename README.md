# Corbado iOS SDKs

[![Platform](https://img.shields.io/badge/Platform-iOS-brightgreen.svg)](https://developer.apple.com/ios/)
[![iOS](https://img.shields.io/badge/iOS-15%2B-brightgreen.svg?style=flat)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-6-blue.svg?logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Monorepo for Corbado's native iOS libraries, distributed via Swift Package Manager as
products of this package.

## Libraries

| Directory | Product | Description |
|---|---|---|
| [`observe/`](observe/) | `CorbadoObserve` | Authentication observability — instrument your auth flows and make them visible in the Corbado developer panel. |

Example / test applications live under [`examples/`](examples/) and are never published.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/corbado/observe-ios.git", from: "0.1.0")
]
```

Then depend on the product you need (e.g. `CorbadoObserve`).

## Requirements

- iOS 15+ (libraries are built to be embeddable in any app — they deliberately avoid
  APIs that would raise your app's deployment target)
- Swift 6, zero third-party dependencies (system frameworks only)

## Development

```bash
# UIKit dependency → simulator only; swift build/test on the macOS host do not work.
xcodebuild test -scheme corbado-ios \
  -destination 'platform=iOS Simulator,name=iPhone 16'  # build + unit tests
(cd examples/observe && xcodegen generate)   # generate the example Xcode project
swift format --in-place --recursive observe  # format
swiftlint                                    # static analysis
```

## Releasing

See [RELEASING.md](RELEASING.md). Short version: SPM resolves versions from repo-wide
git tags — pushing a tag `v<semver>` is the release. Integrators can track `main` as
the snapshot channel.

## License

[MIT](LICENSE)
