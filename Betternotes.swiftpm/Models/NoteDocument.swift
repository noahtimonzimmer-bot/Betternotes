import Foundation
import CoreGraphics

/// A notebook on disk: `<id>.betternotes/` package containing
///   meta.json          – title, page list
///   pages/<pageID>.drawing – PKDrawing data per page, in page coordinates
///   attachments/<name>.pdf – imported PDF backgrounds (never modified)
struct NoteDocument: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var modified: Date = Date()
    var pages: [NotePage] = [NotePage()]
}

struct NotePage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Background PDF file name in attachments/ and page index inside it (0-based). Nil = blank page.
    var pdfAttachment: String?
    var pdfPageIndex: Int?
    /// Page size in page units (GoodNotes uses PDF points × ~1.8335; A4 = 1091.64 × 1543.74).
    var width: Double = 1091.64
    var height: Double = 1543.74
    /// Whiteboards: unbounded canvas, size grows with content.
    var isBoard: Bool = false

    var size: CGSize { CGSize(width: width, height: height) }
}
