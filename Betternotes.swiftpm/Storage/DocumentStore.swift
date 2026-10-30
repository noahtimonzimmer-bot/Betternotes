import Foundation
import PencilKit

@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var documents: [NoteDocument] = []

    let root: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Notebooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { reload() }

    func packageURL(_ doc: NoteDocument) -> URL {
        root.appendingPathComponent("\(doc.id.uuidString).betternotes", isDirectory: true)
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        documents = urls
            .filter { $0.pathExtension == "betternotes" }
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent("meta.json")) }
            .compactMap { try? JSONDecoder().decode(NoteDocument.self, from: $0) }
            .sorted { $0.modified > $1.modified }
    }

    func create(title: String) -> NoteDocument {
        let doc = NoteDocument(title: title)
        save(doc)
        reload()
        return doc
    }

    func save(_ doc: NoteDocument) {
        var doc = doc
        doc.modified = Date()
        let dir = packageURL(doc)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    func delete(_ doc: NoteDocument) {
        try? FileManager.default.removeItem(at: packageURL(doc))
        reload()
    }

    // MARK: Drawings

    func drawing(for page: NotePage, in doc: NoteDocument) -> PKDrawing {
        let url = packageURL(doc).appendingPathComponent("pages/\(page.id.uuidString).drawing")
        guard let data = try? Data(contentsOf: url), let d = try? PKDrawing(data: data) else { return PKDrawing() }
        return d
    }

    func saveDrawing(_ drawing: PKDrawing, for page: NotePage, in doc: NoteDocument) {
        let url = packageURL(doc).appendingPathComponent("pages/\(page.id.uuidString).drawing")
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    func attachmentURL(_ name: String, in doc: NoteDocument) -> URL {
        packageURL(doc).appendingPathComponent("attachments/\(name)")
    }
}
