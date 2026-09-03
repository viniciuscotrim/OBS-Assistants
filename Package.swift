// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BambuStreamOverlay",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BambuStreamOverlay",
            path: "Sources/BambuStreamOverlay",
            exclude: [
                "App/Info.plist"
            ],
            linkerSettings: [
                // Embeds Info.plist into the built executable so it can run as a
                // proper LSUIElement (menu bar only, no Dock icon) app when
                // launched directly, and gives Xcode/xcodebuild what it needs
                // when the package is opened and built as a scheme.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/BambuStreamOverlay/App/Info.plist"
                ])
            ]
        )
    ]
)
