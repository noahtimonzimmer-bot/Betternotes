import Foundation
import PencilKit

@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var documents: [NoteDocument] = []
    @Published private(set) var folders: [Folder] = []

    let root: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Notebooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var foldersURL: URL { root.appendingPathComponent("folders.json") }

    init() { reload() }

    func packageURL(_ doc: NoteDocument) -> URL { packageURL(doc.id) }
    func packageURL(_ id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).betternotes", isDirectory: true)
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        documents = urls
            .filter { $0.pathExtension == "betternotes" }
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent("meta.json")) }
            .compactMap { try? JSONDecoder().decode(NoteDocument.self, from: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        folders = (try? JSONDecoder().decode([Folder].self, from: Data(contentsOf: foldersURL))) ?? []
    }

    func document(_ id: UUID) -> NoteDocument? { documents.first { $0.id == id } }

    // MARK: Documents

    @discardableResult
    func create(title: String, in folder: UUID? = nil, template: PageTemplate = .blank) -> NoteDocument {
        let doc = NoteDocument(title: title, folderID: folder, pages: [NotePage(template: template)])
        save(doc)
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
        if let i = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[i] = doc
        } else {
            documents.append(doc)
            documents.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    func update(_ id: UUID, _ change: (inout NoteDocument) -> Void) {
        guard var doc = document(id) else { return }
        change(&doc)
        save(doc)
    }

    func rename(_ id: UUID, to title: String) { update(id) { $0.title = title } }
    func move(_ id: UUID, to folder: UUID?) { update(id) { $0.folderID = folder } }

    func delete(_ doc: NoteDocument) {
        try? FileManager.default.removeItem(at: packageURL(doc))
        documents.removeAll { $0.id == doc.id }
    }

    // MARK: Pages

    func insertPage(_ page: NotePage, at index: Int, in id: UUID) {
        update(id) { $0.pages.insert(page, at: min(max(index, 0), $0.pages.count)) }
    }

    func duplicatePage(at index: Int, in id: UUID) {
        guard let doc = document(id), doc.pages.indices.contains(index) else { return }
        let original = doc.pages[index]
        let copy = original.duplicated()
        saveDrawing(drawing(for: original, in: doc), for: copy, in: doc)
        insertPage(copy, at: index + 1, in: id)
    }

    func deletePage(at index: Int, in id: UUID) {
        guard let doc = document(id), doc.pages.indices.contains(index) else { return }
        try? FileManager.default.removeItem(at: drawingURL(doc.pages[index], doc))
        update(id) {
            $0.pages.remove(at: index)
            if $0.pages.isEmpty { $0.pages = [NotePage()] }
        }
    }

    func movePage(from: Int, to: Int, in id: UUID) {
        update(id) { d in
            guard d.pages.indices.contains(from) else { return }
            let p = d.pages.remove(at: from)
            d.pages.insert(p, at: min(max(to, 0), d.pages.count))
        }
    }

    func updatePage(_ page: NotePage, in id: UUID) {
        update(id) { d in
            if let i = d.pages.firstIndex(where: { $0.id == page.id }) { d.pages[i] = page }
        }
    }

    // MARK: Folders

    func createFolder(named name: String, in parent: UUID?) {
        folders.append(Folder(name: name, parentID: parent))
        saveFolders()
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        saveFolders()
    }

    func moveFolder(_ id: UUID, to parent: UUID?) {
        guard let i = folders.firstIndex(where: { $0.id == id }), parent != id,
              !descendants(of: id).contains(where: { $0 == parent }) else { return }
        folders[i].parentID = parent
        saveFolders()
    }

    /// Deletes the folder; its documents and subfolders move to the parent folder.
    func deleteFolder(_ id: UUID) {
        guard let f = folders.first(where: { $0.id == id }) else { return }
        for d in documents where d.folderID == id { move(d.id, to: f.parentID) }
        for i in folders.indices where folders[i].parentID == id { folders[i].parentID = f.parentID }
        folders.removeAll { $0.id == id }
        saveFolders()
    }

    func subfolders(of parent: UUID?) -> [Folder] {
        folders.filter { $0.parentID == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func documents(in folder: UUID?) -> [NoteDocument] { documents.filter { $0.folderID == folder } }

    private func descendants(of id: UUID) -> [UUID] {
        let kids = folders.filter { $0.parentID == id }.map(\.id)
        return kids + kids.flatMap { descendants(of: $0) }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders) { try? data.write(to: foldersURL, options: .atomic) }
    }

    // MARK: Drawings & attachments

    private func drawingURL(_ page: NotePage, _ doc: NoteDocument) -> URL {
        packageURL(doc).appendingPathComponent("pages/\(page.id.uuidString).drawing")
    }

    func drawing(for page: NotePage, in doc: NoteDocument) -> PKDrawing {
        guard let data = try? Data(contentsOf: drawingURL(page, doc)), let d = try? PKDrawing(data: data) else { return PKDrawing() }
        return d
    }

    func saveDrawing(_ drawing: PKDrawing, for page: NotePage, in doc: NoteDocument) {
        let url = drawingURL(page, doc)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    func attachmentURL(_ name: String, in doc: NoteDocument) -> URL {
        packageURL(doc).appendingPathComponent("attachments/\(name)")
    }

    /// Stores image data as a new attachment and returns its file name.
    func addAttachment(_ data: Data, ext: String, to doc: NoteDocument) -> String {
        let name = "\(UUID().uuidString).\(ext)"
        let url = attachmentURL(name, in: doc)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        return name
    }
}
