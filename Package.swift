// swift-tools-version: 6.0

import PackageDescription

// Monorepo package: one Package.swift (SPM requires it at the repo root), one product per
// published library. Library sources live in top-level per-library directories
// (observe/Sources, observe/Tests).
let package = Package(
    name: "corbado-ios",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "CorbadoObserve",
            targets: ["CorbadoObserve"]
        )
    ],
    targets: [
        .target(
            name: "CorbadoObserve",
            path: "observe/Sources",
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "CorbadoObserveTests",
            dependencies: ["CorbadoObserve"],
            path: "observe/Tests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
