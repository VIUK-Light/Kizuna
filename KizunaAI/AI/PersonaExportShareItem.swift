import CoreTransferable
import Foundation
import UniformTypeIdentifiers

enum KizunaPersonaExportFileLifecycle {
    static let directoryName = "Kizuna-Persona-Exports"

    static var directoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Remove files left behind by a previous export cleanup failure.
    ///
    /// Exported bytes are converted into an in-memory share item before the
    /// source file is removed, so files remaining here are never required by an
    /// active ShareLink. A failure is logged and retried on the next launch.
    static func cleanupOrphanedFiles() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in contents {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    NSLog(
                        "[KizunaPersonaExport] failed to remove orphaned export file: %@",
                        "\(url.path): \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            NSLog(
                "[KizunaPersonaExport] failed to inspect export directory: %@",
                "\(directoryURL.path): \(error.localizedDescription)"
            )
        }
    }
}

/// A share item that owns the exported bytes instead of the temporary source URL.
///
/// `ShareLink(item: URL)` may ask the receiving application to read the source
/// URL after the presenting view has disappeared. Keeping the bytes in this
/// value lets the view remove its temporary file immediately without invalidating
/// an in-flight share. The suggested filename preserves the export format for
/// Save to Files and other file-oriented share destinations.
struct KizunaPersonaExportShareItem: Transferable, Sendable {
    let data: Data
    let fileName: String

    init(fileURL: URL) throws {
        let fileName = fileURL.lastPathComponent
        guard !fileName.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.data = try Data(contentsOf: fileURL)
        self.fileName = fileName
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { item in
            item.data
        }
        .suggestedFileName { item in
            item.fileName
        }
    }
}
