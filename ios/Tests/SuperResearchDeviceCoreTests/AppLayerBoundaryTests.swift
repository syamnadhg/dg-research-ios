import XCTest

@testable import SuperResearchDeviceCore

/// The guard that keeps `ios/App` from silently accumulating untested logic.
///
/// **The failure this exists to prevent, which already happened once.** `ios/App` is not an SPM
/// target — the app is built by one `swiftc` invocation in `bin/build_app.sh`, not by the package
/// graph — so `swift test` compiles none of it. For months the operation catalogue, the device
/// snapshot decoding, the release path and the heartbeat all lived in `ios/App/AppState.swift` and
/// `ios/App/DeviceBackend.swift` behind a single `import SwiftUI`, and the suite reported 104 green
/// tests while covering zero lines of any of them.
///
/// The rule that fixes it is mechanical rather than advisory: **a file in `ios/App` must import a
/// UI framework.** If it does not, it is logic, it belongs in `ios/Sources/SuperResearchDeviceCore`,
/// and it is currently untestable where it sits. Anyone can move a file; nobody has to remember to.
final class AppLayerBoundaryTests: XCTestCase {

    /// Frameworks that make a file genuinely a view. `Foundation` is deliberately absent — it is
    /// what pure logic imports, and treating it as a UI framework would defeat the whole check.
    private static let uiFrameworks = ["SwiftUI", "UIKit", "WebKit"]

    private static var repoRoot: URL {
        // Tests/SuperResearchDeviceCoreTests/<this file> -> Tests -> ios
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func appSwiftFiles() throws -> [URL] {
        let appDir = repoRoot.appendingPathComponent("App")
        return try FileManager.default
            .contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Vacuity guard. Every assertion below is a loop over this list, so an empty or unreachable
    /// directory would make all of them pass while checking nothing — the exact shape of a
    /// decorative test. Fail loudly instead.
    func testTheAppDirectoryIsActuallyFoundAndNonEmpty() throws {
        let files = try Self.appSwiftFiles()
        XCTAssertGreaterThan(
            files.count, 5,
            "Found \(files.count) Swift files in ios/App — the path resolution is probably wrong, "
            + "which would make every other test in this file vacuously pass."
        )
    }

    func testEveryFileInTheAppDirectoryIsAView() throws {
        var offenders: [String] = []
        for file in try Self.appSwiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let imports = source.split(separator: "\n")
                .filter { $0.hasPrefix("import ") }
                .map { $0.dropFirst("import ".count).trimmingCharacters(in: .whitespaces) }
            if imports.contains(where: Self.uiFrameworks.contains) { continue }
            offenders.append(file.lastPathComponent)
        }
        XCTAssertEqual(
            offenders, [],
            "These files in ios/App import no UI framework, so they are logic, not views — and "
            + "NOTHING in ios/App is compiled by `swift test`. Move them to "
            + "ios/Sources/SuperResearchDeviceCore so the suite can actually reach them: "
            + offenders.joined(separator: ", ")
        )
    }

    /// The moved types must stay reachable from the test target, not merely exist somewhere.
    ///
    /// Asserts on behaviour rather than on the symbol names: naming a type proves it compiles, which
    /// `swift build` already told us. Reading a value back through it proves the suite can exercise
    /// it, which is the property this whole refactor was for.
    func testTheRelocatedModelLayerIsReachableFromTests() {
        XCTAssertFalse(DeviceSnapshot.unpaired.paired)
        XCTAssertEqual(Operations.byID("unpair")?.risk, .destructive)
        XCTAssertNil(Operations.byID("no-such-operation"))
    }
}
