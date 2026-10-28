// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PhoenixLUTBaker", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../fotufilm-source")],
    targets: [.executableTarget(name: "PhoenixLUTBaker",
        dependencies: [.product(name: "FotufilmCore", package: "fotufilm-source")])])
