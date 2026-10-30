// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipboardManagerMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipboardManagerMac", targets: ["ClipboardManagerMac"])
    ],
    targets: [
        .executableTarget(
            name: "ClipboardManagerMac",
            path: "Sources/ClipboardManagerMac",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
