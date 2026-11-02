import SwiftUI
import UniformTypeIdentifiers

extension DocumentStore {
    /// Imports a PDF or .goodnotes file into `folder`; returns the new notebook ids.
    @discardableResult
    func importFile(_ url: URL, into folder: UUID?) throws -> [UUID] {
        let before = Set(documents.map(\.id))
        switch url.pathExtension.lowercased() {
        case "pdf": try PDFImporter.importPDF(url, into: self)
        case "goodnotes": try GoodNotesImporter.importFile(url, into: self)
        default: return []
        }
        reload()
        let new = documents.map(\.id).filter { !before.contains($0) }
        for id in new { move(id, to: folder) }
        return new
    }
}

/// GoodNotes-style document browser: folders and notebooks as tiles, tap a folder to go in,
/// drop PDFs/GoodNotes files (e.g. from Files in Split View) or notebooks onto a folder.
struct LibraryGridView: View {
    @EnvironmentObject var store: DocumentStore
    @Binding var folder: UUID?
    let actions: LibraryActions
    let open: (UUID) -> Void
    @State private var dropTarget: UUID?
    @State private var dropOnBackground = false
    @State private var message: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 28)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                breadcrumb
                LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                    ForEach(store.subfolders(of: folder)) { f in folderTile(f) }
                    ForEach(store.documents(in: folder)) { d in notebookTile(d) }
                    newTile
                }
                if store.subfolders(of: folder).isEmpty && store.documents(in: folder).isEmpty {
                    Text("Leer. PDFs oder GoodNotes-Dateien hierher ziehen oder mit + anlegen.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
        .background(dropOnBackground ? Color.accentColor.opacity(0.06) : Color(.systemGroupedBackground))
        .onDrop(of: [.pdf, .data, .plainText, .fileURL], isTargeted: $dropOnBackground) { providers in
            handleDrop(providers, into: folder)
        }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 24)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }

    // MARK: Pieces

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button("Dokumente") { folder = nil }.font(.title2.bold())
                .foregroundStyle(folder == nil ? Color.primary : Color.accentColor)
            ForEach(path, id: \.id) { f in
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                Button(f.name) { folder = f.id }.font(.title2.bold())
                    .foregroundStyle(f.id == folder ? Color.primary : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
    }

    private var path: [Folder] {
        var out: [Folder] = []
        var cur = folder
        while let id = cur, let f = store.folders.first(where: { $0.id == id }) {
            out.insert(f, at: 0)
            cur = f.parentID
        }
        return out
    }

    private func folderTile(_ f: Folder) -> some View {
        Button { folder = f.id } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.18))
                    Image(systemName: "folder.fill").font(.system(size: 64)).foregroundStyle(Color.accentColor)
                    Text("\(store.documents(in: f.id).count + store.subfolders(of: f.id).count)")
                        .font(.caption.bold()).foregroundStyle(.white).offset(y: 6)
                }
                .aspectRatio(0.78, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor, lineWidth: dropTarget == f.id ? 4 : 0))
                .scaleEffect(dropTarget == f.id ? 1.05 : 1)
                Text(f.name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .onDrop(of: [.pdf, .data, .plainText, .fileURL], isTargeted: Binding(
            get: { dropTarget == f.id }, set: { dropTarget = $0 ? f.id : (dropTarget == f.id ? nil : dropTarget) })) { providers in
            handleDrop(providers, into: f.id)
        }
        .draggable("folder:\(f.id.uuidString)")
        .contextMenu {
            Button("Umbenennen") { actions.renameFolder(f) }
            Button("Neuer Unterordner") { actions.newFolder(f.id) }
            Button("Ordner löschen", role: .destructive) { actions.deleteFolder(f) }
        }
    }

    private func notebookTile(_ d: NoteDocument) -> some View {
        Button { open(d.id) } label: {
            VStack(spacing: 8) {
                Group {
                    if let first = d.pages.first {
                        PageThumbnail(doc: d, page: first, version: 0)
                    } else {
                        Color.white
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(0.78, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                VStack(spacing: 2) {
                    Text(d.title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                    Text(d.modified.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .draggable("doc:\(d.id.uuidString)")
        .contextMenu {
            Button("Umbenennen") { actions.renameDocument(d) }
            Menu("Verschieben nach") {
                Button("Dokumente (oberste Ebene)") { store.move(d.id, to: nil) }
                ForEach(store.folders) { f in Button(f.name) { store.move(d.id, to: f.id) } }
            }
            Button("Löschen", role: .destructive) { actions.deleteDocument(d) }
        }
    }

    private var newTile: some View {
        Menu {
            Menu("Neues Notizbuch") {
                ForEach(PageTemplate.allCases) { t in Button(t.label) { actions.newNotebook(folder, t) } }
            }
            Button("Neuer Ordner") { actions.newFolder(folder) }
            Button("PDF / GoodNotes importieren…") { actions.importFiles(folder) }
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(.secondary)
                    .overlay(Image(systemName: "plus").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary))
                    .aspectRatio(0.78, contentMode: .fit)
                Text("Neu").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Drop handling

    private func handleDrop(_ providers: [NSItemProvider], into target: UUID?) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               !p.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                handled = true
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s else { return }
                    Task { @MainActor in moveDragged(s, to: target) }
                }
                continue
            }
            let isPDF = p.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            let isGN = (p.suggestedName ?? "").lowercased().hasSuffix("goodnotes")
            guard isPDF || isGN || p.hasItemConformingToTypeIdentifier(UTType.data.identifier) else { continue }
            handled = true
            let type = isPDF ? UTType.pdf.identifier : (p.registeredTypeIdentifiers.first ?? UTType.data.identifier)
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return }
                // The provided file is deleted after this closure: copy it first.
                var name = p.suggestedName ?? url.deletingPathExtension().lastPathComponent
                if isPDF, !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
                if isGN, !name.lowercased().hasSuffix(".goodnotes") { name += ".goodnotes" }
                if !isPDF, !isGN, url.pathExtension.lowercased() == "goodnotes" { name = url.lastPathComponent }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: url, to: copy)
                Task { @MainActor in
                    do {
                        let ids = try store.importFile(copy, into: target)
                        show(ids.isEmpty ? "Nur PDF- und GoodNotes-Dateien" : "Importiert: \(name)")
                    } catch {
                        show("Import fehlgeschlagen: \(error.localizedDescription)")
                    }
                }
            }
        }
        return handled
    }

    private func moveDragged(_ s: String, to target: UUID?) {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return }
        if parts[0] == "doc" { store.move(id, to: target) } else if id != target { store.moveFolder(id, to: target) }
    }

    private func show(_ s: String) {
        message = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if message == s { message = nil } }
    }
}
