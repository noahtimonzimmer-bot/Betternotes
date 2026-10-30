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
        // Same page units as GoodNotes so imported and native notebooks behave alike.
        let scale = 1091.64 / 595.28
        doc.pages = (0..<pdf.pageCount).map { i in
            let box = pdf.page(at: i)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
            return NotePage(pdfAttachment: name, pdfPageIndex: i,
                            width: box.width * scale, height: box.height * scale)
        }
        store.save(doc)
        try FileManager.default.copyItem(at: url, to: store.attachmentURL(name, in: doc))
    }
}
