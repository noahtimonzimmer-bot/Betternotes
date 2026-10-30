import Foundation
import ZIPFoundation

/// Reads `.goodnotes` exports (a ZIP archive).
///
/// STATUS: container is opened and PDF attachments are imported. Stroke decoding
/// is not implemented yet – it needs sample files to determine the on-disk
/// schema. See docs/GOODNOTES_FORMAT.md for findings and the analysis workflow.
enum GoodNotesImporter {
    enum ImportError: LocalizedError {
        case notAnArchive
        var errorDescription: String? { "Die Datei ist kein gültiges .goodnotes-Archiv." }
    }

    @MainActor
    static func importFile(_ url: URL, into store: DocumentStore) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        do { try fm.unzipItem(at: url, to: tmp) } catch { throw ImportError.notAnArchive }

        // Collect embedded PDFs (the page backgrounds) – these are plain PDFs.
        let pdfs = (fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }

        // TODO: parse page/stroke records into PKDrawing once the schema is known.
        // Until then every embedded PDF becomes its own notebook (without strokes).
        for pdf in pdfs {
            try PDFImporter.importPDF(pdf, into: store)
        }
        if pdfs.isEmpty {
            _ = store.create(title: url.deletingPathExtension().lastPathComponent)
        }
    }
}
