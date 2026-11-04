// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "WorkJournal", platforms: [.macOS(.v14)],
    products: [.executable(name: "WorkJournal", targets: ["WorkJournal"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "JournalCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "WorkJournal", dependencies: ["JournalCore"]),
        .testTarget(name: "JournalCoreTests", dependencies: ["JournalCore"])
    ], swiftLanguageModes: [.v5])
