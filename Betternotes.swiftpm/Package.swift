// swift-tools-version: 5.9

// Swift Playgrounds app package: open Betternotes.swiftpm on the iPad in Swift Playgrounds
// (or on a Mac in Xcode) and press Run.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Betternotes",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Betternotes",
            targets: ["AppModule"],
            bundleIdentifier: "com.betternotes.app",
            displayVersion: "0.2",
            bundleVersion: "1",
            supportedDeviceFamilies: [
                .pad
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .portraitUpsideDown,
                .landscapeRight,
                .landscapeLeft
            ],
            capabilities: [
                .microphone(purposeString: "Für Audioaufnahmen in deinen Notizen.")
            ]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", "0.9.19"..<"1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "."
        )
    ]
)
