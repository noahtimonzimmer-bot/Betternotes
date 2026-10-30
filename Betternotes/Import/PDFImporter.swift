import Foundation
import PDFKit

enum PDFImporter {
    /// Copies the PDF unchanged into a new notebook; one page entry per PDF page.
    @MainActor
    static func importPDF(_ url: URL, into store: DocumentStore) throws {
        guard let pdf = PDFDocument(url: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = "\(UUID().uuidString).pdf"
        var doc = NoteDocument(title: url.deletingPathExtension().lastPathComponent, pages: [])
        doc.pages = (0..<pdf.pageCount).map { NotePage(pdfAttachment: name, pdfPageIndex: $0) }
        store.save(doc)
        try FileManager.default.copyItem(at: url, to: store.attachmentURL(name, in: doc))
    }
}
