// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MakeLORACore", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "MakeLORACore", targets: ["MakeLORACore"])], targets: [.target(name: "MakeLORACore"), .testTarget(name: "MakeLORACoreTests", dependencies: ["MakeLORACore"])])
