// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "afm-bridge",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "afm-bridge-server", targets: ["afm-bridge-server"]),
    .library(name: "AFMBridgeCore", targets: ["AFMBridgeCore"]),
  ],
  targets: [
    .target(name: "AFMBridgeCore"),
    .executableTarget(name: "afm-bridge-server", dependencies: ["AFMBridgeCore"]),
    .testTarget(name: "AFMBridgeCoreTests", dependencies: ["AFMBridgeCore"]),
  ]
)
