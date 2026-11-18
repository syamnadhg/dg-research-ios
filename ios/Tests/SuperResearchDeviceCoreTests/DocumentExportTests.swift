import XCTest

@testable import SuperResearchDeviceCore

/// P3 uploads files, so the files have to exist somewhere the iOS document picker can reach.
final class DocumentExportTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let reports = [
        "chatgpt": "# ChatGPT\n\nBody.",
        "gemini": "# Gemini\n\nBody.",
        "claude": "# Claude\n\nBody.",
    ]

    func testTheThreeReportsAreWrittenAsMarkdownFiles() throws {
        let urls = try DocumentExport.writeReports(reports, researchID: "res-1", root: root)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["chatgpt.md", "gemini.md", "claude.md"])
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "# ChatGPT\n\nBody.")
    }

    func testTheUPLOADORDERIsTheBackendsAndNotTheDictionarys() throws {
        // A dictionary's order records which platform happened to finish first. The notebook's
        // source list should read the same way the consolidated report does.
        let shuffled = ["claude": "C body", "gemini": "G body", "chatgpt": "X body"]
        let urls = try DocumentExport.writeReports(shuffled, researchID: "res-1", root: root)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["chatgpt.md", "gemini.md", "claude.md"])
    }

    func testEachRunGetsItsOWNDirectory() throws {
        // ⚠ The picker shows whatever is in the folder. A previous run's chatgpt.md sitting beside
        // this one's is a source nobody chose being uploaded into the notebook — no error, and
        // indistinguishable afterwards.
        _ = try DocumentExport.writeReports(reports, researchID: "res-1", root: root)
        _ = try DocumentExport.writeReports(reports, researchID: "res-2", root: root)

        let one = DocumentExport.runDirectory(root: root, researchID: "res-1")
        let two = DocumentExport.runDirectory(root: root, researchID: "res-2")
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: one.path).sorted(), ["chatgpt.md", "claude.md", "gemini.md"])
    }

    func testAMISSINGPlatformIsSkippedRatherThanWrittenEmpty() throws {
        let urls = try DocumentExport.writeReports(
            ["chatgpt": "X body", "claude": "C body"], researchID: "res-1", root: root
        )
        XCTAssertEqual(urls.map(\.lastPathComponent), ["chatgpt.md", "claude.md"])
    }

    func testAnEMPTYReportIsREFUSEDRatherThanWritten() {
        // An empty file is worse than a missing one: the picker lists it, NotebookLM accepts it,
        // and the notebook holds a source with nothing in it.
        XCTAssertThrowsError(
            try DocumentExport.writeReports(
                ["chatgpt": "   \n\t "], researchID: "res-1", root: root
            )
        ) { error in
            XCTAssertEqual(error as? DocumentExport.ExportError, .emptyDocument("chatgpt"))
        }
    }

    func testNoReportsAtAllIsAnErrorAndNotAnEmptyDirectory() {
        // Opening a picker onto an empty folder looks like the upload silently doing nothing.
        XCTAssertThrowsError(
            try DocumentExport.writeReports([:], researchID: "res-1", root: root)
        ) { error in
            XCTAssertEqual(error as? DocumentExport.ExportError, .noDocuments)
        }
    }

    func testCleanUpRemovesTheRunsFilesButNotTheOtherRuns() throws {
        _ = try DocumentExport.writeReports(reports, researchID: "res-1", root: root)
        _ = try DocumentExport.writeReports(reports, researchID: "res-2", root: root)

        DocumentExport.cleanUp(researchID: "res-1", root: root)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: DocumentExport.runDirectory(root: root, researchID: "res-1").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: DocumentExport.runDirectory(root: root, researchID: "res-2").path))
    }

    func testCleanUpOfSomethingAlreadyGoneDoesNotThrow() {
        // Cleanup runs after a run that has already succeeded; it must never turn that into a
        // failure.
        DocumentExport.cleanUp(researchID: "never-existed", root: root)
    }

    func testTheAppDeclaresITSDocumentsToTheFilesDomain() throws {
        // ⚠ Both keys, and they do different things: one publishes the directory to the Files app,
        // the other lets the picker open a file in place instead of handing back a sandboxed copy.
        // Without them the picker opens onto somewhere the run's files do not exist — which reads
        // as "the upload does nothing".
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(
            contentsOf: repo.appendingPathComponent("bin/build_app.sh"), encoding: .utf8
        )
        XCTAssertTrue(script.contains("<key>UIFileSharingEnabled</key><true/>"))
        XCTAssertTrue(script.contains("<key>LSSupportsOpeningDocumentsInPlace</key><true/>"))
    }
}
