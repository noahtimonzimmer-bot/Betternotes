import Foundation
import PDFKit
import PencilKit
import UIKit

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
        saveDrawing(drawing(for: original, in: doc, includeHidden: true), for: copy, in: doc)
        insertPage(copy, at: index + 1, in: id)
    }

    /// Removes ink (all layers), text boxes and images; keeps the paper.
    func clearPage(at index: Int, in id: UUID) {
        guard let doc = document(id), doc.pages.indices.contains(index) else { return }
        var p = doc.pages[index]
        for layer in p.allLayers { saveLayerDrawing(PKDrawing(), layer: layer.id, in: doc) }
        p.textBoxes = []
        p.images = []
        updatePage(p, in: id)
    }

    /// Inserts every page of a PDF at `index`.
    func insertPDFPages(_ url: URL, at index: Int, in id: UUID) throws -> Int {
        guard let doc = document(id), let pdf = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        let name = "\(UUID().uuidString).pdf"
        try FileManager.default.copyItem(at: url, to: attachmentURL(name, in: doc))
        let k = 1091.64 / 595.28
        let pages: [NotePage] = (0..<pdf.pageCount).map { i in
            let box = pdf.page(at: i)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
            return NotePage(pdfAttachment: name, pdfPageIndex: i, width: box.width * k, height: box.height * k)
        }
        update(id) { $0.pages.insert(contentsOf: pages, at: min(max(index, 0), $0.pages.count)) }
        return pages.count
    }

    /// One new page per image (scans, photos); the image fills the page.
    func insertImagePages(_ images: [UIImage], at index: Int, in id: UUID) {
        guard let doc = document(id) else { return }
        var pages: [NotePage] = []
        for img in images {
            guard let data = img.jpegData(compressionQuality: 0.85) else { continue }
            let name = addAttachment(data, ext: "jpg", to: doc)
            let w = 1091.64
            let h = w * Double(img.size.height / max(img.size.width, 1))
            var page = NotePage(width: w, height: h)
            page.images = [ImageItem(frame: CGRect(x: 0, y: 0, width: w, height: h), file: name)]
            pages.append(page)
        }
        update(id) { $0.pages.insert(contentsOf: pages, at: min(max(index, 0), $0.pages.count)) }
    }

    func deletePage(at index: Int, in id: UUID) {
        guard let doc = document(id), doc.pages.indices.contains(index) else { return }
        for layer in doc.pages[index].allLayers {
            try? FileManager.default.removeItem(at: layerURL(layer.id, doc))
        }
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

    private func layerURL(_ layer: UUID, _ doc: NoteDocument) -> URL {
        packageURL(doc).appendingPathComponent("pages/\(layer.uuidString).drawing")
    }

    /// Ink of one layer (the bottom layer's id is the page id).
    func layerDrawing(_ layer: UUID, in doc: NoteDocument) -> PKDrawing {
        guard let data = try? Data(contentsOf: layerURL(layer, doc)), let d = try? PKDrawing(data: data) else { return PKDrawing() }
        return d
    }

    func saveLayerDrawing(_ drawing: PKDrawing, layer: UUID, in doc: NoteDocument) {
        let url = layerURL(layer, doc)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    /// All visible layers combined (thumbnails, export, search).
    func drawing(for page: NotePage, in doc: NoteDocument, includeHidden: Bool = false) -> PKDrawing {
        var all = PKDrawing()
        for layer in page.allLayers where includeHidden || !layer.hidden {
            all.append(layerDrawing(layer.id, in: doc))
        }
        return all
    }

    /// Writes the bottom layer (used by importers and page duplication).
    func saveDrawing(_ drawing: PKDrawing, for page: NotePage, in doc: NoteDocument) {
        saveLayerDrawing(drawing, layer: page.id, in: doc)
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
