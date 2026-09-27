# Releasing

Our upstream distribution uses Git tags and GitHub release assets. Customers can import
those assets into a Swift package registry. Tags must be plain repo-wide
semver (`v<semver>`) — SPM cannot resolve per-library tags like `observe-v0.1.0`, so unlike
the `corbado/android` repo, all libraries in this package share one version line
(firebase-ios-sdk model).

## Channels

| Channel | Trigger | Result |
|---|---|---|
| Staging | push to `main` | integrators pin `.package(url: ..., branch: "main")` |
| Production | push tag `v<semver>` | resolvable via `from: "X.Y.Z"`; GitHub release created by `observe-release.yml` |

## Releasing

1. Make sure `main` is green.
2. Set `Sdk.version` in `observe/Sources/Sdk.swift` to the concrete version (e.g. `0.1.0`)
   and merge — every batch stamps this value, it must match the tag.
3. Tag and push:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```
   The release workflow re-runs the tests, verifies `Sdk.version` matches the tag, and
   creates a source archive, tests the extracted package, and attaches the archive,
   `SHA256SUMS`, `RELEASE.txt` (version, commit and toolchain), and `LICENSE`
   to the GitHub release. The archive includes the privacy manifest
   and test fixtures; `.gitattributes` excludes examples, docs and internal tooling.
   `docs/LIMITATIONS.md` stays in the repository and is not attached to releases.
4. Afterwards, bump `Sdk.version` to the next `X.Y.(Z+1)-dev` on `main`.

Consuming `main` (integrator testing):

```swift
dependencies: [
    .package(url: "https://github.com/corbado/observe-ios.git", branch: "main")
]
```

## Required GitHub secrets

Only the workflow-provided `GITHUB_TOKEN` with `contents: write` is needed. Customers
publish to their own registries with their own credentials. The workflow does not sign
the source archive; coordinate with the customer if their registry requires signing.

## Registry handoff

Give the customer the release URL, version, commit and the attached assets above. Use
the explicitly attached `corbado-ios-X.Y.Z.zip`, not GitHub’s automatic source download.
They verify `SHA256SUMS` and import those exact archive bytes into their Swift registry.
The registry identity is customer-owned; the Swift product remains `CorbadoObserve`.
Never replace the contents of a released version.

A public repository lets customers fetch releases without GitHub credentials. While
the repository is private, give them read access or transfer the release assets through
an agreed channel. Publishing to their registry does not require Corbado write access.

Git tags become visible before the workflow finishes. A release is ready for handoff
only after the workflow succeeds and its tested assets are attached.
