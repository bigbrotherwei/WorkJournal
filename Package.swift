// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "WorkJournal", platforms: [.macOS(.v14)],
    products: [.executable(name: "WorkJournal", targets: ["WorkJournal"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.6.0")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "JournalCore", dependencies: ["CSQLite", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .executableTarget(name: "WorkJournal", dependencies: ["JournalCore"], resources: [.copy("Resources/NotebookEditor")]),
        .testTarget(name: "JournalCoreTests", dependencies: ["JournalCore"])
    ], swiftLanguageModes: [.v5])
