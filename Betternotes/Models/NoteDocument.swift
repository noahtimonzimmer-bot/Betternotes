import Foundation

/// A notebook on disk: `<id>.betternotes/` package containing
///   meta.json          – title, page list
///   pages/<pageID>.drawing – PKDrawing data per page
///   attachments/<name>.pdf – imported PDF backgrounds (never modified)
struct NoteDocument: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var modified: Date = Date()
    var pages: [NotePage] = [NotePage()]
}

struct NotePage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Background PDF file name in attachments/ and page index inside it. Nil = blank page.
    var pdfAttachment: String?
    var pdfPageIndex: Int?
}
