// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetMemento",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MeetMemento", targets: ["MeetMemento"])
    ],
    targets: [
        .executableTarget(
            name: "MeetMemento",
            path: "Sources/MeetMemento",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("EventKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Speech"),
                .linkedFramework("UserNotifications")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
