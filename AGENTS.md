# Corbado iOS SDKs — Agent Instructions

Swift Package Manager monorepo for Corbado's native iOS libraries. One `Package.swift` at
the repo root (SPM requirement), one product per published library; library sources live in
top-level per-library directories mirroring the `corbado/android` repo. Example apps live
under `examples/` and are never published.

## Layout

- `observe/` — `CorbadoObserve`, the Corbado Observe SDK (auth observability). The iOS
  sibling of `@corbado/observe` from the `corbado/js` repo and `com.corbado:observe` from
  the `corbado/android` repo.
- `examples/observe/` — SwiftUI test app for the Observe SDK; the SDK's development vehicle.
- `.swiftlint.yml` — static analysis config. Formatting is `swift format` (bundled with the
  toolchain), configured in `.swift-format`.

## Commands

```bash
# UIKit dependency → simulator only; swift build/test on the macOS host do NOT work.
xcodebuild test -scheme corbado-ios \
  -destination 'platform=iOS Simulator,name=iPhone 16'  # build + unit tests (CI runs this)
(cd examples/observe && xcodegen generate)   # (re)generate the example Xcode project
xcodebuild build -project examples/observe/ObserveExample.xcodeproj -scheme ObserveExample \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
swift format --in-place --recursive observe  # auto-format; lint --strict runs in CI
swiftlint --strict                           # static analysis (CI-enforced)
```

`docs/LIMITATIONS.md` tracks the accepted platform gaps; keep it current (short bullets, no
solution domain).

CI: `.github/workflows/observe-ci.yml` (PRs + main). Releases: see `RELEASING.md`
(repo-wide `v<semver>` tags — SPM cannot resolve per-library tags; the version constant in
`observe/Sources/Sdk.swift` must match the tag).
