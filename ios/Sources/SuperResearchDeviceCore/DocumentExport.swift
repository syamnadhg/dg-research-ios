import Foundation

/// Write the run's documents where the **iOS document picker** can see them.
///
/// ⭐ P3 uploads the three phase-2 markdown files to NotebookLM, and the picker is the only route on
/// this surface: the mobile page carries **zero `input[type=file]`**, so there is no equivalent of
/// the backend's `set_input_files`. The picker browses the Files domain, so the files must live in a
/// directory that has been published to it — which is what `UIFileSharingEnabled` and
/// `LSSupportsOpeningDocumentsInPlace` do in the app's `Info.plist`.
///
/// ⚠ Without both keys the picker opens onto a place the run's files do not exist, and the symptom
/// is a picker that appears to work and uploads nothing.
public enum DocumentExport {

    public enum ExportError: Error, Equatable {
        case emptyDocument(String)
        case noDocuments
    }

    /// One run's export directory, named by research id so two runs cannot collide.
    ///
    /// ⚠ Per-run rather than a single shared folder: the picker shows whatever is there, and a
    /// previous run's `chatgpt.md` sitting beside this one's is a source nobody chose being uploaded
    /// into the notebook — with no error, and no way to tell from the notebook afterwards.
    public static func runDirectory(root: URL, researchID: String) -> URL {
        root.appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(researchID, isDirectory: true)
    }

    /// Write the phase-2 reports as `.md` files and return them **in upload order**.
    ///
    /// Order is the backend's — chatgpt, gemini, claude — so the notebook's source list reads the
    /// same way the consolidated report does. A dictionary's own order is a record of which platform
    /// happened to finish first.
    @discardableResult
    public static func writeReports(
        _ reports: [String: String], researchID: String, root: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let directory = runDirectory(root: root, researchID: researchID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [URL] = []
        for platform in Prompts.p2Platforms {
            guard let body = reports[platform] else { continue }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // ⚠ An empty file is worse than a missing one: the picker lists it, the owner selects
            // it, NotebookLM accepts it, and the notebook then contains a source with nothing in it
            // — indistinguishable afterwards from a platform that found nothing.
            guard !trimmed.isEmpty else { throw ExportError.emptyDocument(platform) }
            let url = directory.appendingPathComponent("\(platform).md")
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }
        guard !written.isEmpty else { throw ExportError.noDocuments }
        return written
    }

    /// Remove a finished run's exported files.
    ///
    /// ⚠ Called after the upload, not before the next run: leaving them means the next run's picker
    /// shows both runs' files, and the owner's Files app slowly fills with research nobody asked to
    /// keep. Failure here is logged and swallowed — a cleanup that throws would fail a run that has
    /// already succeeded.
    public static func cleanUp(
        researchID: String, root: URL, fileManager: FileManager = .default
    ) {
        let directory = runDirectory(root: root, researchID: researchID)
        do {
            try fileManager.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // Already gone is the goal.
        } catch {
            NSLog("[SR] could not clean up the export directory: %@", String(describing: error))
        }
    }
}
