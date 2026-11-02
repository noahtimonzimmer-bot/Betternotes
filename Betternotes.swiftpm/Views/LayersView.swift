import SwiftUI

/// Layers of the current page (GoodNotes "Ebenen"): add, rename, show/hide, reorder, delete,
/// choose the one the pencil writes into.
struct LayersView: View {
    @EnvironmentObject var store: DocumentStore
    let docID: UUID
    let pageIndex: Int
    @State private var renaming: PageLayer?
    @State private var name = ""

    private var page: NotePage? {
        guard let d = store.document(docID), d.pages.indices.contains(pageIndex) else { return nil }
        return d.pages[pageIndex]
    }

    var body: some View {
        NavigationStack {
            List {
                if let page {
                    // top layer first, like GoodNotes
                    ForEach(page.allLayers.reversed()) { layer in
                        HStack {
                            Button { toggleHidden(layer) } label: {
                                Image(systemName: layer.hidden ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            Text(layer.name)
                            Spacer()
                            if layer.id == page.activeLayerID {
                                Image(systemName: "pencil.tip").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { change { $0.activeLayer = layer.id } }
                        .contextMenu {
                            Button("Umbenennen") { name = layer.name; renaming = layer }
                            Button("Nach oben") { move(layer, by: 1) }
                            Button("Nach unten") { move(layer, by: -1) }
                            if page.allLayers.count > 1, layer.id != page.id {
                                Button("Löschen", role: .destructive) { delete(layer) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ebenen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { addLayer() } label: { Image(systemName: "plus") }
            }
            .alert("Ebene umbenennen", isPresented: .constant(renaming != nil)) {
                TextField("Name", text: $name)
                Button("Abbrechen", role: .cancel) { renaming = nil }
                Button("OK") {
                    if let l = renaming { change { p in
                        p.layers = p.allLayers.map { $0.id == l.id ? PageLayer(id: $0.id, name: name, hidden: $0.hidden) : $0 }
                    } }
                    renaming = nil
                }
            }
            .overlay(alignment: .bottom) {
                Text("Antippen: in diese Ebene schreiben · lange drücken: mehr")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        }
        .frame(minWidth: 320, minHeight: 360)
    }

    private func change(_ f: (inout NotePage) -> Void) {
        guard var p = page else { return }
        if p.layers.isEmpty { p.layers = p.allLayers }
        f(&p)
        store.updatePage(p, in: docID)
    }

    private func addLayer() {
        change { p in
            let l = PageLayer(id: UUID(), name: "Ebene \(p.layers.count + 1)")
            p.layers.append(l)
            p.activeLayer = l.id
        }
    }

    private func toggleHidden(_ layer: PageLayer) {
        change { p in
            if let i = p.layers.firstIndex(where: { $0.id == layer.id }) { p.layers[i].hidden.toggle() }
        }
    }

    private func move(_ layer: PageLayer, by delta: Int) {
        change { p in
            guard let i = p.layers.firstIndex(where: { $0.id == layer.id }) else { return }
            let j = min(max(i + delta, 0), p.layers.count - 1)
            p.layers.swapAt(i, j)
        }
    }

    private func delete(_ layer: PageLayer) {
        guard let doc = store.document(docID) else { return }
        try? FileManager.default.removeItem(at: store.packageURL(doc).appendingPathComponent("pages/\(layer.id.uuidString).drawing"))
        change { p in
            p.layers.removeAll { $0.id == layer.id }
            if p.activeLayer == layer.id { p.activeLayer = nil }
        }
    }
}
