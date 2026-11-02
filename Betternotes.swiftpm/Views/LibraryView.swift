import SwiftUI
import UniformTypeIdentifiers

/// OneNote-style layout: folders and notebooks in a sidebar on the left, the open notebook on the right.
struct LibraryView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var settings: AppSettings
    @State private var selection: UUID?
    /// Open notebooks as tabs (like GoodNotes), most recent selection is active.
    @State private var tabs: [UUID] = []
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var importing = false
    @State private var importFolder: UUID?
    @State private var errorText: String?
    @State private var search = ""
    @State private var renaming: RenameTarget?
    @State private var newName = ""
    @State private var showSettings = false

    enum RenameTarget: Identifiable {
        case document(UUID), folder(UUID), newFolder(parent: UUID?)
        var id: String {
            switch self {
            case .document(let i): return "d\(i)"
            case .folder(let i): return "f\(i)"
            case .newFolder(let p): return "n\(p?.uuidString ?? "root")"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                if search.isEmpty {
                    FolderContents(parent: nil, actions: actions)
                } else {
                    ForEach(store.documents.filter { $0.title.localizedCaseInsensitiveContains(search) }) { doc in
                        DocumentRow(doc: doc, actions: actions)
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Suchen")
            .navigationTitle("Betternotes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .primaryAction) { AddMenu(folder: nil, actions: actions) }
            }
        } detail: {
            if let id = selection, let doc = store.document(id) {
                VStack(spacing: 0) {
                    if tabs.count > 1 { tabStrip }
                    EditorView(document: doc, settings: settings)
                        .id(doc.id)
                }
            } else {
                ContentUnavailableView("Kein Notizbuch geöffnet", systemImage: "book.closed",
                                       description: Text("Links ein Notizbuch wählen oder mit + ein neues anlegen."))
            }
        }
        .onChange(of: selection) { _, id in
            guard let id, !tabs.contains(id) else { return }
            tabs.append(id)
            if tabs.count > 8 { tabs.removeFirst() }
        }
        .onChange(of: store.documents.map(\.id)) { _, ids in
            tabs.removeAll { !ids.contains($0) }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView().toolbar { Button("Fertig") { showSettings = false } }
            }
        }
        .fileImporter(isPresented: $importing,
                      // .item: .goodnotes has no system-declared type; we branch on the extension.
                      allowedContentTypes: [.pdf, .item],
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .alert("Fehler", isPresented: .constant(errorText != nil)) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
        .alert("Name", isPresented: .constant(renaming != nil)) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("OK") { commitRename() }
        }
    }

    private var actions: LibraryActions {
        LibraryActions(
            newNotebook: { folder, template in
                selection = store.create(title: "Unbenannt", in: folder, template: template).id
            },
            newFolder: { parent in newName = "Neuer Ordner"; renaming = .newFolder(parent: parent) },
            importFiles: { folder in importFolder = folder; importing = true },
            renameDocument: { doc in newName = doc.title; renaming = .document(doc.id) },
            renameFolder: { f in newName = f.name; renaming = .folder(f.id) },
            deleteDocument: { doc in if selection == doc.id { selection = nil }; store.delete(doc) },
            deleteFolder: { f in store.deleteFolder(f.id) }
        )
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.self) { id in
                    if let d = store.document(id) {
                        HStack(spacing: 6) {
                            Text(d.title).lineLimit(1).font(.callout)
                            Button {
                                tabs.removeAll { $0 == id }
                                if selection == id { selection = tabs.last }
                            } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selection == id ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { selection = id }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func commitRename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        defer { renaming = nil }
        guard !name.isEmpty, let target = renaming else { return }
        switch target {
        case .document(let id): store.rename(id, to: name)
        case .folder(let id): store.renameFolder(id, to: name)
        case .newFolder(let parent): store.createFolder(named: name, in: parent)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let before = Set(store.documents.map(\.id))
                switch url.pathExtension.lowercased() {
                case "pdf": try PDFImporter.importPDF(url, into: store)
                case "goodnotes": try GoodNotesImporter.importFile(url, into: store)
                default: errorText = "\(url.lastPathComponent): nur PDF- und GoodNotes-Dateien."
                }
                store.reload()
                for doc in store.documents where !before.contains(doc.id) {
                    store.move(doc.id, to: importFolder)
                    selection = doc.id
                }
            } catch { errorText = "\(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }
}

struct LibraryActions {
    var newNotebook: (UUID?, PageTemplate) -> Void
    var newFolder: (UUID?) -> Void
    var importFiles: (UUID?) -> Void
    var renameDocument: (NoteDocument) -> Void
    var renameFolder: (Folder) -> Void
    var deleteDocument: (NoteDocument) -> Void
    var deleteFolder: (Folder) -> Void
}

private struct AddMenu: View {
    let folder: UUID?
    let actions: LibraryActions

    var body: some View {
        Menu {
            Menu("Neues Notizbuch") {
                ForEach(PageTemplate.allCases) { t in
                    Button(t.label) { actions.newNotebook(folder, t) }
                }
            }
            Button { actions.newFolder(folder) } label: { Label("Neuer Ordner", systemImage: "folder.badge.plus") }
            Button { actions.importFiles(folder) } label: { Label("PDF / GoodNotes importieren…", systemImage: "square.and.arrow.down") }
        } label: { Image(systemName: "plus") }
    }
}

/// Recursive folder tree: subfolders (expandable) followed by notebooks.
private struct FolderContents: View {
    @EnvironmentObject var store: DocumentStore
    let parent: UUID?
    let actions: LibraryActions

    var body: some View {
        ForEach(store.subfolders(of: parent)) { folder in
            DisclosureGroup {
                FolderContents(parent: folder.id, actions: actions)
            } label: {
                Label(folder.name, systemImage: "folder")
                    .dropDestination(for: String.self) { items, _ in
                        drop(items, into: folder.id)
                    }
                    .contextMenu {
                        Menu("Neues Notizbuch") {
                            ForEach(PageTemplate.allCases) { t in
                                Button(t.label) { actions.newNotebook(folder.id, t) }
                            }
                        }
                        Button("Neuer Unterordner") { actions.newFolder(folder.id) }
                        Button("Hierher importieren…") { actions.importFiles(folder.id) }
                        Button("Umbenennen") { actions.renameFolder(folder) }
                        Menu("Verschieben nach") { MoveTargets(exclude: folder.id) { store.moveFolder(folder.id, to: $0) } }
                        Button("Ordner löschen", role: .destructive) { actions.deleteFolder(folder) }
                    }
                    .draggable("folder:\(folder.id.uuidString)")
            }
        }
        ForEach(store.documents(in: parent)) { doc in
            DocumentRow(doc: doc, actions: actions)
        }
    }

    private func drop(_ items: [String], into folder: UUID) -> Bool {
        for item in items {
            let parts = item.split(separator: ":")
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { continue }
            if parts[0] == "doc" { store.move(id, to: folder) } else { store.moveFolder(id, to: folder) }
        }
        return true
    }
}

private struct DocumentRow: View {
    @EnvironmentObject var store: DocumentStore
    let doc: NoteDocument
    let actions: LibraryActions

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(doc.title).lineLimit(1)
                Text("\(doc.pages.count) Seiten").font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: doc.pages.first?.isBoard == true ? "rectangle.on.rectangle" : "book.closed") }
        .tag(Optional(doc.id))
        .draggable("doc:\(doc.id.uuidString)")
        .contextMenu {
            Button("Umbenennen") { actions.renameDocument(doc) }
            Menu("Verschieben nach") { MoveTargets(exclude: nil) { store.move(doc.id, to: $0) } }
            Button("Löschen", role: .destructive) { actions.deleteDocument(doc) }
        }
    }
}

/// Flat list of all folders (indented) as move targets.
private struct MoveTargets: View {
    @EnvironmentObject var store: DocumentStore
    let exclude: UUID?
    let move: (UUID?) -> Void

    var body: some View {
        Button("Oberste Ebene") { move(nil) }
        ForEach(flattened(parent: nil, depth: 0), id: \.0.id) { folder, depth in
            Button(String(repeating: "   ", count: depth) + folder.name) { move(folder.id) }
        }
    }

    private func flattened(parent: UUID?, depth: Int) -> [(Folder, Int)] {
        store.subfolders(of: parent).filter { $0.id != exclude }.flatMap { f in
            [(f, depth)] + flattened(parent: f.id, depth: depth + 1)
        }
    }
}
