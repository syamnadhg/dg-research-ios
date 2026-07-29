// swift-tools-version:5.9
//
// The Firebase implementation of `PairingBackend`.
//
// ⚠ **A SEPARATE package on purpose.** Adding a Firebase dependency to the core package would make
// `swift test` require a network fetch of firebase-ios-sdk — a ~416k-object clone that did not
// complete in the environment this was written in. Keeping it separate means the core package's 53
// tests stay runnable offline, which is where all the logic worth testing lives.
//
// ⚠ **NOT COMPILE-VERIFIED HERE.** The SDK could not be fetched, so this target has never been
// built. The API surface it uses is small, long-stable, and listed in the file header of
// FirebasePairingBackend.swift so it can be checked against the SDK version you resolve. Expect to
// fix a signature or two on first build; the *sequence* it drives is already tested against a fake
// in the core package, so what remains is mechanical.
import PackageDescription

let package = Package(
    name: "SuperResearchFirebase",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SuperResearchFirebase", targets: ["SuperResearchFirebase"])
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
    ],
    targets: [
        .target(
            name: "SuperResearchFirebase",
            dependencies: [
                .product(name: "SuperResearchDeviceCore", package: "ios"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
            ]
        )
    ]
)
