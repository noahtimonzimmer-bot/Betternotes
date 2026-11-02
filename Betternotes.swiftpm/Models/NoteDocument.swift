import Foundation
import CoreGraphics

/// A notebook on disk: `<id>.betternotes/` package containing
///   meta.json              – title, folder, page list (incl. text boxes and images)
///   pages/<pageID>.drawing – PKDrawing data per page, in page coordinates
///   attachments/<name>     – imported PDFs and inserted images (never modified)
struct NoteDocument: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var modified: Date = Date()
    var folderID: UUID?
    var pages: [NotePage] = [NotePage()]

    init(id: UUID = UUID(), title: String, folderID: UUID? = nil, pages: [NotePage] = [NotePage()]) {
        self.id = id
        self.title = title
        self.folderID = folderID
        self.pages = pages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        pages = try c.decodeIfPresent([NotePage].self, forKey: .pages) ?? [NotePage()]
    }
}

struct Folder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var parentID: UUID?
}

enum PageTemplate: String, Codable, CaseIterable, Identifiable {
    case blank, lined, grid, dotted
    var id: String { rawValue }
    var label: String {
        switch self {
        case .blank: return "Leer"
        case .lined: return "Liniert"
        case .grid: return "Kariert"
        case .dotted: return "Gepunktet"
        }
    }
}

struct TextBox: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var frame: CGRect          // page coordinates
    var text: String = ""
    var fontSize: CGFloat = 24
    var colorHex: String = "#1F1B1B"
}

struct ImageItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var frame: CGRect          // page coordinates
    var file: String           // in attachments/
}

struct NotePage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Background PDF file name in attachments/ and page index inside it (0-based). Nil = paper page.
    var pdfAttachment: String?
    var pdfPageIndex: Int?
    /// Page size in page units (GoodNotes uses PDF points × ~1.8335; A4 = 1091.64 × 1543.74).
    var width: Double = 1091.64
    var height: Double = 1543.74
    /// Whiteboards: no margin, size from content.
    var isBoard: Bool = false
    var template: PageTemplate = .blank
    var textBoxes: [TextBox] = []
    var images: [ImageItem] = []

    var size: CGSize { CGSize(width: width, height: height) }

    init(pdfAttachment: String? = nil, pdfPageIndex: Int? = nil, width: Double = 1091.64,
         height: Double = 1543.74, template: PageTemplate = .blank) {
        self.pdfAttachment = pdfAttachment
        self.pdfPageIndex = pdfPageIndex
        self.width = width
        self.height = height
        self.template = template
    }

    // Tolerant decoding so older notebooks keep opening when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pdfAttachment = try c.decodeIfPresent(String.self, forKey: .pdfAttachment)
        pdfPageIndex = try c.decodeIfPresent(Int.self, forKey: .pdfPageIndex)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1091.64
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 1543.74
        isBoard = try c.decodeIfPresent(Bool.self, forKey: .isBoard) ?? false
        template = try c.decodeIfPresent(PageTemplate.self, forKey: .template) ?? .blank
        textBoxes = try c.decodeIfPresent([TextBox].self, forKey: .textBoxes) ?? []
        images = try c.decodeIfPresent([ImageItem].self, forKey: .images) ?? []
    }

    /// Fresh copy with a new id (drawing is copied separately by the store).
    func duplicated() -> NotePage {
        var p = self
        p.id = UUID()
        p.textBoxes = textBoxes.map { var t = $0; t.id = UUID(); return t }
        p.images = images.map { var i = $0; i.id = UUID(); return i }
        return p
    }
}
