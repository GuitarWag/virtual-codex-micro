// swift-tools-version: 6.0
import PackageDescription

// No test target: this machine has Command Line Tools only, and neither XCTest
// nor swift-testing ships with CLT, so `swift test` cannot run here. Checks live
// in SelfCheck.swift and run via `VCM_SELFTEST=1 ./.build/debug/VirtualCodexMicro`.
// Restore a real test target if Xcode gets installed.
let package = Package(
    name: "VirtualCodexMicro",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VirtualCodexMicro", path: "Sources/VirtualCodexMicro")
    ]
)
