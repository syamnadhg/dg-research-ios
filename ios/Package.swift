// swift-tools-version:5.9
//
// The device-side core of the Super Research iOS app (phase C0-FE).
//
// Deliberately has NO Firebase dependency. Everything here is the logic that must be exactly
// right for pairing to work — secret generation and hashing, code formatting, and the precise
// shape of the writes the Firestore rules will accept — and all of it is testable offline, with
// no `GoogleService-Info.plist` and no network.
//
// The Firebase glue (custom-token sign-in, the snapshot listener) is a thin layer over this and
// is the only part that waits on the plist. Splitting it this way means the parts that are easy
// to get subtly wrong are verified now rather than discovered during a live pairing attempt,
// where a failure shows up as a device that silently never appears in the web app.
import PackageDescription

let package = Package(
    name: "SuperResearchDeviceCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SuperResearchDeviceCore", targets: ["SuperResearchDeviceCore"])
    ],
    targets: [
        .target(name: "SuperResearchDeviceCore"),
        .testTarget(
            name: "SuperResearchDeviceCoreTests",
            dependencies: ["SuperResearchDeviceCore"]
        ),
    ]
)
