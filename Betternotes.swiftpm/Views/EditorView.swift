import PDFKit
import PencilKit
import PhotosUI
import SwiftUI

/// Shared state between the SwiftUI editor chrome and the UIKit document view.
@MainActor
final class EditorModel: ObservableObject {
    @Published var currentPage = 0
    @Published var toast: String?
    var scrollToPage: ((Int) -> Void)?
    var undoManager: () -> UndoManager? = { nil }

    func show(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }
}

struct EditorView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var settings: AppSettings
    @StateObject private var tools: ToolController
    @StateObject private var model = EditorModel()
    @State private var showThumbnails = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showSearch = false
    @State private var goToPage = ""
    @State private var askGoTo = false
    @State private var exportURL: URL?
    let document: NoteDocument

    init(document: NoteDocument, settings: AppSettings) {
        self.document = document
        _tools = StateObject(wrappedValue: ToolController(settings: settings))
    }

    private var doc: NoteDocument { store.document(document.id) ?? document }

    var body: some View {
        HStack(spacing: 0) {
            if showThumbnails {
                PageThumbnailList(doc: doc, model: model)
                    .frame(width: 170)
                    .transition(.move(edge: .leading))
                Divider()
            }
            ZStack(alignment: .top) {
                DocumentCanvas(docID: document.id, model: model)
                if let p = tools.paletteLocation {
                    ToolPaletteView()
                        .position(x: p.x, y: max(90, p.y - 90))
                        .transition(.scale.combined(with: .opacity))
                }
                if let t = model.toast {
                    Text(t).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Text("\(model.currentPage + 1) / \(doc.pages.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(12)
                    .onTapGesture { askGoTo = true }
            }
        }
        .animation(.spring(duration: 0.25), value: tools.paletteLocation)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .animation(.easeInOut(duration: 0.2), value: showThumbnails)
        .environmentObject(tools)
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { insertImage(data) }
                photoItem = nil
            }
        }
        .popover(isPresented: $showSearch) { SearchView(doc: doc, model: model).frame(width: 360, height: 460) }
        .alert("Gehe zu Seite", isPresented: $askGoTo) {
            TextField("1 – \(doc.pages.count)", text: $goToPage).keyboardType(.numberPad)
            Button("Abbrechen", role: .cancel) {}
            Button("Los") {
                if let n = Int(goToPage) { model.scrollToPage?(min(max(n, 1), doc.pages.count) - 1) }
                goToPage = ""
            }
        }
        .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { showThumbnails.toggle() } label: { Image(systemName: "rectangle.grid.1x2") }
            Button { model.undoManager()?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            Button { model.undoManager()?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
        }
        ToolbarItem(placement: .principal) { ToolBar() }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Menu("Neue Seite danach") {
                    ForEach(PageTemplate.allCases) { t in
                        Button(t.label) { addPage(template: t) }
                    }
                }
                Button("Seite duplizieren") { store.duplicatePage(at: model.currentPage, in: document.id) }
                Button("Gehe zu Seite…") { askGoTo = true }
                Menu("Vorlage dieser Seite") {
                    ForEach(PageTemplate.allCases) { t in
                        Button(t.label) { setTemplate(t) }
                    }
                }
                Button("Seite löschen", role: .destructive) { store.deletePage(at: model.currentPage, in: document.id) }
            } label: { Image(systemName: "doc.badge.plus") }
            Menu {
                Button { showPhotoPicker = true } label: { Label("Foto", systemImage: "photo") }
                Button {
                    if let img = UIPasteboard.general.image, let data = img.pngData() { insertImage(data) }
                    else { model.show("Kein Bild in der Zwischenablage") }
                } label: { Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") }
                Button { tools.select(.text) } label: { Label("Textfeld", systemImage: "textformat") }
            } label: { Image(systemName: "photo.badge.plus") }
            Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
            Button {
                do { exportURL = try PDFExporter.export(doc, store: store, marginRatio: settings.marginRatio) }
                catch { model.show("Export fehlgeschlagen: \(error.localizedDescription)") }
            } label: { Image(systemName: "square.and.arrow.up") }
        }
    }

    private func addPage(template: PageTemplate) {
        let current = doc.pages.indices.contains(model.currentPage) ? doc.pages[model.currentPage] : nil
        var page = NotePage(template: template)
        if let c = current, !c.isBoard { page.width = c.width; page.height = c.height }
        store.insertPage(page, at: model.currentPage + 1, in: document.id)
        let target = model.currentPage + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { model.scrollToPage?(target) }
    }

    private func setTemplate(_ t: PageTemplate) {
        guard doc.pages.indices.contains(model.currentPage) else { return }
        var p = doc.pages[model.currentPage]
        p.template = t
        store.updatePage(p, in: document.id)
    }

    private func insertImage(_ data: Data) {
        guard doc.pages.indices.contains(model.currentPage), let img = UIImage(data: data) else { return }
        let name = store.addAttachment(data, ext: "png", to: doc)
        var p = doc.pages[model.currentPage]
        let w = min(p.width * 0.6, img.size.width * 2)
        let h = w * img.size.height / max(img.size.width, 1)
        p.images.append(ImageItem(frame: CGRect(x: (p.width - w) / 2, y: 120, width: w, height: h), file: name))
        store.updatePage(p, in: document.id)
        tools.select(.text)
        model.show("Bild eingefügt – im Modus „Text & Objekte“ verschieben, mit zwei Fingern skalieren")
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

// MARK: - UIKit bridge

struct DocumentCanvas: UIViewRepresentable {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var tools: ToolController
    @EnvironmentObject var settings: AppSettings
    let docID: UUID
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(store: store, tools: tools, settings: settings, docID: docID, model: model) }

    func makeUIView(context: Context) -> DocumentScrollView {
        let v = DocumentScrollView()
        v.provider = context.coordinator
        context.coordinator.view = v
        context.coordinator.pencil.attach(to: v)
        model.scrollToPage = { [weak v] i in v?.scrollToPage(i) }
        model.undoManager = { [weak v] in v?.undoManager }
        v.setPages(store.document(docID)?.pages ?? [])
        return v
    }

    func updateUIView(_ v: DocumentScrollView, context: Context) {
        _ = tools.kind; _ = tools.color; _ = tools.markerColor; _ = tools.width   // observe tool changes
        _ = settings.marginRatio; _ = settings.straightenLines; _ = settings.onlyPencilDraws
        v.setPages(store.document(docID)?.pages ?? [])
        v.forEachPageView { view, page in context.coordinator.configure(view, page: page) }
    }

    @MainActor
    final class Coordinator: NSObject, DocumentPageProvider {
        let store: DocumentStore, tools: ToolController, settings: AppSettings, docID: UUID, model: EditorModel
        let pencil: PencilGestureHandler
        weak var view: DocumentScrollView?

        init(store: DocumentStore, tools: ToolController, settings: AppSettings, docID: UUID, model: EditorModel) {
            self.store = store; self.tools = tools; self.settings = settings; self.docID = docID; self.model = model
            pencil = PencilGestureHandler(tools: tools)
        }

        func marginRatio(for page: NotePage) -> CGFloat { page.isBoard ? 0 : settings.marginRatio }

        func makePageView(for page: NotePage) -> PageCanvasView {
            guard let doc = store.document(docID) else { return PageCanvasView(page: page, drawing: PKDrawing()) }
            let v = PageCanvasView(page: page, drawing: store.drawing(for: page, in: doc))
            let store = self.store
            let pdf = page.pdfAttachment.map { store.attachmentURL($0, in: doc) }
            v.imageLoader = { name in UIImage(contentsOfFile: store.attachmentURL(name, in: doc).path) }
            v.backgroundRenderer = { width, done in
                PageBackground.render(page: page, pdf: pdf, pixelWidth: width, completion: done)
            }
            v.onDrawingChange = { d in store.saveDrawing(d, for: page, in: doc) }
            let docID = self.docID
            v.onPageChange = { p in store.updatePage(p, in: docID) }
            v.onEndUsingTool = { [weak tools] in tools?.didEndUsingTool() }
            v.onCapture = { [weak model] img in
                UIPasteboard.general.image = img
                model?.show("Ausschnitt in die Zwischenablage kopiert")
            }
            configure(v, page: page)
            return v
        }

        func configure(_ v: PageCanvasView, page: NotePage) {
            v.margin = marginRatio(for: page) * page.width
            v.straighten = settings.straightenLines
            v.canvas.drawingPolicy = settings.onlyPencilDraws ? .pencilOnly : .anyInput
            v.canvas.tool = tools.tool
            v.mode = tools.pageMode
        }

        func currentPageChanged(_ index: Int) { model.currentPage = index }
    }
}

// MARK: - Toolbar & palette

struct ToolBar: View {
    @EnvironmentObject var tools: ToolController

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ToolController.Kind.allCases) { k in
                Button { tools.select(k) } label: {
                    Image(systemName: k.symbol)
                        .frame(width: 30, height: 30)
                        .background(tools.kind == k ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(k.label)
            }
            Divider().frame(height: 22)
            ForEach(ToolController.widths, id: \.self) { w in
                Button { tools.width = w } label: {
                    Capsule().frame(width: 18, height: w * 1.4)
                        .frame(width: 26, height: 30)
                        .background(tools.width == w ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Divider().frame(height: 22)
            ForEach(ToolController.palette, id: \.self) { c in
                Circle().fill(Color(uiColor: c)).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.primary.opacity(0.7), lineWidth: tools.currentColor == c ? 2 : 0).padding(-3))
                    .onTapGesture { tools.setColor(c) }
            }
        }
    }
}

/// Appears at the pencil tip on squeeze (Apple Pencil Pro).
struct ToolPaletteView: View {
    @EnvironmentObject var tools: ToolController

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(ToolController.Kind.allCases) { k in
                    Button { tools.select(k); tools.paletteLocation = nil } label: {
                        Image(systemName: k.symbol).font(.title3).frame(width: 38, height: 38)
                            .background(tools.kind == k ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(ToolController.palette, id: \.self) { c in
                    Circle().fill(Color(uiColor: c)).frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.primary.opacity(0.7), lineWidth: tools.currentColor == c ? 2 : 0).padding(-3))
                        .onTapGesture { tools.setColor(c); tools.paletteLocation = nil }
                }
            }
            HStack {
                Image(systemName: "scribble").font(.caption)
                Slider(value: $tools.width, in: 0.8...10)
                Image(systemName: "scribble").font(.title3)
            }
            .frame(width: 260)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .shadow(radius: 10)
    }
}

// MARK: - Page thumbnails

struct PageThumbnailList: View {
    @EnvironmentObject var store: DocumentStore
    let doc: NoteDocument
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array(doc.pages.enumerated()), id: \.element.id) { i, page in
                        VStack(spacing: 4) {
                            PageThumbnail(doc: doc, page: page)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.accentColor, lineWidth: model.currentPage == i ? 3 : 0))
                            Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .id(page.id)
                        .onTapGesture { model.scrollToPage?(i) }
                        .contextMenu {
                            Button("Duplizieren") { store.duplicatePage(at: i, in: doc.id) }
                            Button("Nach oben") { store.movePage(from: i, to: i - 1, in: doc.id) }.disabled(i == 0)
                            Button("Nach unten") { store.movePage(from: i, to: i + 1, in: doc.id) }.disabled(i == doc.pages.count - 1)
                            Button("Löschen", role: .destructive) { store.deletePage(at: i, in: doc.id) }
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(.secondarySystemBackground))
            .onChange(of: model.currentPage) { _, i in
                if doc.pages.indices.contains(i) { withAnimation { proxy.scrollTo(doc.pages[i].id, anchor: .center) } }
            }
        }
    }
}

struct PageThumbnail: View {
    @EnvironmentObject var store: DocumentStore
    let doc: NoteDocument
    let page: NotePage
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable() } else { Color.white }
        }
        .aspectRatio(page.width / page.height, contentMode: .fit)
        .shadow(radius: 1)
        .task(id: "\(page.id)-\(doc.modified.timeIntervalSince1970)") {
            let drawing = store.drawing(for: page, in: doc)
            let pdf = page.pdfAttachment.map { store.attachmentURL($0, in: doc) }
            let page = self.page
            image = await Task.detached(priority: .utility) {
                PageRenderer.image(page: page, drawing: drawing, pdf: pdf, width: 300)
            }.value
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var store: DocumentStore
    let doc: NoteDocument
    @ObservedObject var model: EditorModel
    @State private var query = ""
    @State private var results: [(page: Int, text: String)] = []

    var body: some View {
        VStack(alignment: .leading) {
            TextField("In PDF-Text und Textfeldern suchen", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
                .padding()
            List(results.indices, id: \.self) { k in
                Button {
                    model.scrollToPage?(results[k].page)
                } label: {
                    VStack(alignment: .leading) {
                        Text("Seite \(results[k].page + 1)").font(.headline)
                        Text(results[k].text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if results.isEmpty && !query.isEmpty { Text("Keine Treffer").foregroundStyle(.secondary) } }
        }
    }

    private func run() {
        var out: [(Int, String)] = []
        var pdfs: [String: PDFDocument] = [:]
        for (i, page) in doc.pages.enumerated() {
            for tb in page.textBoxes where tb.text.localizedCaseInsensitiveContains(query) { out.append((i, tb.text)) }
            guard let att = page.pdfAttachment, let idx = page.pdfPageIndex else { continue }
            if pdfs[att] == nil { pdfs[att] = PDFDocument(url: store.attachmentURL(att, in: doc)) }
            guard let p = pdfs[att]?.page(at: idx), let text = p.string,
                  let r = text.range(of: query, options: .caseInsensitive) else { continue }
            let lo = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let hi = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            out.append((i, String(text[lo..<hi]).replacingOccurrences(of: "\n", with: " ")))
        }
        results = out.map { (page: $0.0, text: $0.1) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
