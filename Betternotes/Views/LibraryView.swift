import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var store: DocumentStore
    @State private var importing = false
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 24)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(store.documents) { doc in
                        NavigationLink(value: doc) {
                            VStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.white)
                                    .shadow(radius: 3)
                                    .aspectRatio(0.75, contentMode: .fit)
                                Text(doc.title).font(.headline).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Löschen", role: .destructive) { store.delete(doc) }
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Betternotes")
            .navigationDestination(for: NoteDocument.self) { EditorView(document: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Neues Notizbuch") { _ = store.create(title: "Unbenannt") }
                        Button("GoodNotes / PDF importieren…") { importing = true }
                    } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.pdf, UTType(filenameExtension: "goodnotes") ?? .data],
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .alert("Import fehlgeschlagen", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                switch url.pathExtension.lowercased() {
                case "pdf": try PDFImporter.importPDF(url, into: store)
                case "goodnotes": try GoodNotesImporter.importFile(url, into: store)
                default: break
                }
            } catch { errorText = error.localizedDescription }
        }
        store.reload()
    }
}
