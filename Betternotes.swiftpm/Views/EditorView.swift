import PDFKit
import PencilKit
import PhotosUI
import SwiftUI

/// Shared state between the SwiftUI editor chrome and the UIKit document view.
@MainActor
final class EditorModel: ObservableObject {
    @Published var currentPage = 0
    @Published var toast: String?
    /// Bumped per page when its ink changes, so thumbnails refresh.
    @Published var inkVersions: [UUID: Int] = [:]
    @Published var cropRequest: CropRequest?
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
    @StateObject private var recorder = AudioRecorder()
    @State private var showRecordings = false
    @State private var showLayers = false
    @State private var showAddPage = false
    @State private var showMore = false
    @State private var showEditorSettings = false
    @State private var showThumbnails = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showSearch = false
    @State private var goToPage = ""
    @State private var askGoTo = false
    @State private var exportURL: URL?
    @State private var askBookmark = false
    @State private var bookmarkTitle = ""
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
                GeometryReader { geo in
                    FloatingToolBar(area: geo.size)
                    if let p = tools.paletteLocation {
                        // tap anywhere else closes the ring
                        Color.black.opacity(0.001)
                            .onTapGesture { tools.paletteLocation = nil }
                        let r = ToolPaletteView.radius + 30
                        ToolPaletteView()
                            .position(x: min(max(p.x, r), geo.size.width - r),
                                      y: min(max(p.y, r), geo.size.height - 60))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                if let t = model.toast {
                    Label(t, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .padding(.top, 70)
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
        .sheet(isPresented: $showEditorSettings) {
            NavigationStack {
                SettingsView().toolbar { Button("Fertig") { showEditorSettings = false } }
            }
        }
        .sheet(item: $model.cropRequest) { req in ImageCropView(docID: document.id, request: req) }
        .alert("Gliederung", isPresented: $askBookmark) {
            TextField("Titel (leer = entfernen)", text: $bookmarkTitle)
            Button("Abbrechen", role: .cancel) {}
            Button("OK") {
                guard doc.pages.indices.contains(model.currentPage) else { return }
                var p = doc.pages[model.currentPage]
                let t = bookmarkTitle.trimmingCharacters(in: .whitespaces)
                p.bookmark = t.isEmpty ? nil : t
                store.updatePage(p, in: document.id)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { showThumbnails.toggle() } label: { Image(systemName: "rectangle.grid.1x2") }
            Button { model.undoManager()?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            Button { model.undoManager()?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showAddPage = true } label: { Image(systemName: "doc.badge.plus") }
                .popover(isPresented: $showAddPage, arrowEdge: .top) {
                    AddPagePanel(doc: doc, current: model.currentPage,
                                 didInsert: { i in model.scrollToPage?(i) },
                                 pickPhoto: { showPhotoPicker = true })
                }
            Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
            Button { exportPDF() } label: { Image(systemName: "square.and.arrow.up") }
            Button { showMore = true } label: { Image(systemName: "ellipsis.circle") }
                .popover(isPresented: $showMore, arrowEdge: .top) {
                    MorePanel(doc: doc, current: model.currentPage,
                              goTo: { askGoTo = true },
                              outline: {
                                  bookmarkTitle = doc.pages.indices.contains(model.currentPage) ? (doc.pages[model.currentPage].bookmark ?? "") : ""
                                  askBookmark = true
                              },
                              layers: { showLayers = true },
                              recordings: { showRecordings = true },
                              export: { exportPDF() },
                              settings: { showEditorSettings = true })
                }
                .popover(isPresented: $showLayers) {
                    LayersView(docID: document.id, pageIndex: model.currentPage)
                }
            Button { toggleRecording() } label: {
                if recorder.isRecording {
                    Label(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)),
                          systemImage: "stop.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Color.red)
                } else {
                    Image(systemName: "mic")
                }
            }
            .popover(isPresented: $showRecordings) {
                RecordingsView(recorder: recorder, doc: doc)
            }
        }
    }

    private func exportPDF() {
        do { exportURL = try PDFExporter.export(doc, store: store, includeMarginNotes: settings.exportMarginNotes) }
        catch { model.show("Export fehlgeschlagen: \(error.localizedDescription)") }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            if let rec = recorder.stop() { store.update(document.id) { $0.recordings.append(rec) } }
            model.show("Aufnahme gespeichert")
        } else {
            Task {
                if await recorder.start(in: doc, store: store) { model.show("Aufnahme läuft …") }
                else { model.show("Mikrofon nicht erlaubt (Einstellungen › Betternotes)") }
            }
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
        _ = tools.kind; _ = tools.color; _ = tools.markerColor; _ = tools.width; _ = tools.rulerActive   // observe tool changes
        _ = settings.marginRatio; _ = settings.exportMarginNotes; _ = settings.straightenLines; _ = settings.holdToShape; _ = settings.onlyPencilDraws
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

        func defaultMargin(for page: NotePage) -> CGFloat { page.isBoard ? 0 : settings.marginRatio * page.width }

        /// Space around each page is effectively endless: 1.5 page widths on both sides from the
        /// start (more if you write further out); the paper stays centred.
        func margins(for page: NotePage) -> (left: CGFloat, right: CGFloat) {
            let d = page.isBoard ? defaultMargin(for: page) : max(defaultMargin(for: page), page.width * 1.5)
            let l = d + (view?.extraLeft ?? 0) * page.width
            let r = d + (view?.extraRight ?? 0) * page.width
            return (max(l, page.marginLeft.map { CGFloat($0) } ?? l), max(r, page.marginRight.map { CGFloat($0) } ?? r))
        }

        func makePageView(for page: NotePage) -> PageCanvasView {
            guard let doc = store.document(docID) else { return PageCanvasView(page: page, layerDrawings: [:]) }
            var layers: [UUID: PKDrawing] = [:]
            for l in page.allLayers { layers[l.id] = store.layerDrawing(l.id, in: doc) }
            let v = PageCanvasView(page: page, layerDrawings: layers)
            let store = self.store
            let pdf = page.pdfAttachment.map { store.attachmentURL($0, in: doc) }
            v.imageLoader = { name in UIImage(contentsOfFile: store.attachmentURL(name, in: doc).path) }
            v.backgroundRenderer = { width, done in
                PageBackground.render(page: page, pdf: pdf, pixelWidth: width, completion: done)
            }
            v.onDrawingChange = { [weak model] layer, d in
                store.saveLayerDrawing(d, layer: layer, in: doc)
                model?.inkVersions[page.id, default: 0] += 1
            }
            let docID = self.docID
            v.onPageChange = { p in store.updatePage(p, in: docID) }
            v.onEndUsingTool = { [weak tools] in tools?.didEndUsingTool() }
            let pageID = page.id
            v.addAttachment = { data in store.addAttachment(data, ext: "png", to: doc) }
            v.onRequestCrop = { [weak model] item in model?.cropRequest = CropRequest(pageID: pageID, itemID: item) }
            v.onCapture = { [weak model] img in
                UIPasteboard.general.image = img
                model?.show("Ausschnitt in die Zwischenablage kopiert")
            }
            configure(v, page: page)
            return v
        }

        func configure(_ v: PageCanvasView, page: NotePage) {
            let m = margins(for: page)
            v.marginLeft = m.left
            v.marginRight = m.right
            v.growStep = page.width * 0.5
            v.straighten = settings.straightenLines
            v.holdToShape = settings.holdToShape
            v.canvas.drawingPolicy = settings.onlyPencilDraws ? .pencilOnly : .anyInput
            v.fingerDraws = !settings.onlyPencilDraws
            v.canvas.tool = tools.tool
            v.canvas.isRulerActive = tools.rulerActive
            v.mode = tools.pageMode
        }

        func currentPageChanged(_ index: Int) { model.currentPage = index }
    }
}

// MARK: - Toolbar & palette

/// Floating tool bar (drag the grip to move it anywhere; position is remembered).
struct ToolBar: View {
    @EnvironmentObject var tools: ToolController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 36)
                .contentShape(Rectangle())
                .accessibilityLabel("Leiste verschieben")
            ForEach(ToolController.Kind.allCases) { k in
                Button { tools.select(k) } label: {
                    Image(systemName: k.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(tools.kind == k ? Color.white : Color.primary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(tools.kind == k ? toolTint(k) : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(k.label)
            }
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 24).padding(.horizontal, 4)
            ForEach(ToolController.widths, id: \.self) { w in
                Button { tools.width = w } label: {
                    Circle().fill(Color.primary)
                        .frame(width: 4 + w * 2.2, height: 4 + w * 2.2)
                        .frame(width: 30, height: 36)
                        .background(Circle().stroke(Color.accentColor, lineWidth: tools.width == w ? 2 : 0).frame(width: 28, height: 28))
                }
                .buttonStyle(.plain)
            }
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 24).padding(.horizontal, 4)
            ForEach(ToolController.palette, id: \.self) { c in
                Circle().fill(Color(uiColor: c)).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.2), radius: 1)
                    .padding(4)
                    .overlay(Circle().stroke(Color.primary.opacity(0.6), lineWidth: tools.currentColor == c ? 2 : 0))
                    .onTapGesture { tools.setColor(c) }
            }
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 24).padding(.horizontal, 4)
            Button { tools.rulerActive.toggle() } label: {
                Image(systemName: "ruler")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tools.rulerActive ? Color.white : Color.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(tools.rulerActive ? Color.accentColor : Color.clear))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lineal")
            ForEach(tools.favorites) { f in
                Button { tools.apply(f) } label: {
                    Image(systemName: ToolController.Kind(rawValue: f.kind)?.symbol ?? "pencil.tip")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(uiColor: UIColor(hex: f.colorHex))))
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.2), radius: 1)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Favorit entfernen", role: .destructive) { tools.favorites.removeAll { $0 == f } }
                }
            }
            Button { tools.addFavorite() } label: {
                Image(systemName: "star")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!tools.kind.usesColor)
            .accessibilityLabel("Aktuellen Stift als Favorit speichern")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private func toolTint(_ k: ToolController.Kind) -> Color {
        k.usesColor ? Color(uiColor: k == .marker ? tools.markerColor : tools.color).opacity(0.95) : Color.accentColor
    }
}

/// Draggable container for the tool bar.
struct FloatingToolBar: View {
    @AppStorage("toolbar.x") private var fx = 0.5
    @AppStorage("toolbar.y") private var fy = 0.0
    @State private var drag: CGSize = .zero
    let area: CGSize

    var body: some View {
        ToolBar()
            .fixedSize()
            .background(GeometryReader { g in Color.clear.preference(key: BarSize.self, value: g.size) })
            .modifier(Positioned(fx: fx, fy: fy, drag: drag, area: area))
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    fx = min(max(fx + v.translation.width / max(area.width, 1), 0), 1)
                    fy = min(max(fy + v.translation.height / max(area.height, 1), 0), 1)
                    drag = .zero
                })
    }

    private struct BarSize: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
    }

    private struct Positioned: ViewModifier {
        let fx: Double, fy: Double, drag: CGSize, area: CGSize
        @State private var size: CGSize = CGSize(width: 600, height: 44)
        func body(content: Content) -> some View {
            let w = min(size.width, area.width - 16)
            let x = min(max(fx * area.width + drag.width, w / 2 + 8), area.width - w / 2 - 8)
            let y = min(max(fy * area.height + drag.height, size.height / 2 + 8), area.height - size.height / 2 - 8)
            content
                .onPreferenceChange(BarSize.self) { size = $0 }
                .position(x: x, y: y)
        }
    }
}

/// Appears around the pencil tip on squeeze (Apple Pencil Pro): tools on the inner arc,
/// colours on the outer arc, stroke widths below the tip.
struct ToolPaletteView: View {
    @EnvironmentObject var tools: ToolController
    static let radius: CGFloat = 150

    var body: some View {
        let kinds = ToolController.Kind.allCases
        let colors = ToolController.palette
        ZStack {
            Circle().fill(.ultraThinMaterial).frame(width: 2 * Self.radius + 40, height: 2 * Self.radius + 40)
                .mask(Circle().stroke(lineWidth: 120).frame(width: 2 * Self.radius - 20, height: 2 * Self.radius - 20))
                .shadow(color: .black.opacity(0.15), radius: 10)
            ForEach(Array(kinds.enumerated()), id: \.element) { i, k in
                let a = arcAngle(i, of: kinds.count, from: -165, to: -15)
                Button { tools.select(k); tools.paletteLocation = nil } label: {
                    Image(systemName: k.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(tools.kind == k ? Color.white : Color.primary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(tools.kind == k ? Color.accentColor : Color(.systemBackground)))
                        .shadow(color: .black.opacity(0.15), radius: 2)
                }
                .buttonStyle(.plain)
                .offset(x: 95 * cos(a), y: 95 * sin(a))
            }
            ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
                let a = arcAngle(i, of: colors.count, from: -150, to: -30)
                Circle().fill(Color(uiColor: c)).frame(width: 34, height: 34)
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: tools.currentColor == c ? 3 : 0).padding(-4))
                    .shadow(color: .black.opacity(0.2), radius: 2)
                    .offset(x: Self.radius * cos(a), y: Self.radius * sin(a))
                    .onTapGesture { tools.setColor(c); tools.paletteLocation = nil }
            }
            ForEach(Array(ToolController.widths.enumerated()), id: \.offset) { i, w in
                let a = arcAngle(i, of: ToolController.widths.count, from: 60, to: 120)
                Button { tools.width = w; tools.paletteLocation = nil } label: {
                    Circle().fill(Color.primary).frame(width: 4 + w * 2.4, height: 4 + w * 2.4)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color(.systemBackground)))
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: tools.width == w ? 2 : 0))
                        .shadow(color: .black.opacity(0.15), radius: 2)
                }
                .buttonStyle(.plain)
                .offset(x: 95 * cos(a), y: 95 * sin(a))
            }
            Circle().stroke(Color.accentColor.opacity(0.6), lineWidth: 2).frame(width: 14, height: 14)
        }
        .frame(width: 2 * Self.radius + 60, height: 2 * Self.radius + 60)
    }

    private func arcAngle(_ i: Int, of n: Int, from: Double, to: Double) -> CGFloat {
        let t = n > 1 ? Double(i) / Double(n - 1) : 0.5
        return CGFloat((from + (to - from) * t) * .pi / 180)
    }
}

// MARK: - Page thumbnails

struct PageThumbnailList: View {
    @EnvironmentObject var store: DocumentStore
    let doc: NoteDocument
    @ObservedObject var model: EditorModel
    @State private var showOutline = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showOutline) {
                Text("Seiten").tag(false)
                Text("Gliederung").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(8)
            if showOutline { outline } else { thumbnails }
        }
        .background(Color(.secondarySystemBackground))
    }

    private var outline: some View {
        List {
            ForEach(Array(doc.pages.enumerated()).filter { $0.element.bookmark != nil }, id: \.element.id) { i, page in
                Button { model.scrollToPage?(i) } label: {
                    HStack {
                        Text(page.bookmark ?? "").lineLimit(2)
                        Spacer()
                        Text("\(i + 1)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !doc.pages.contains(where: { $0.bookmark != nil }) {
                Text("Seitenmenü › „Zur Gliederung hinzufügen“").font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding()
            }
        }
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array(doc.pages.enumerated()), id: \.element.id) { i, page in
                        VStack(spacing: 4) {
                            PageThumbnail(doc: doc, page: page, version: model.inkVersions[page.id] ?? 0)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.accentColor, lineWidth: model.currentPage == i ? 3 : 0))
                            HStack(spacing: 3) {
                                if page.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                Text("\(i + 1)")
                            }
                            .font(.caption2).foregroundStyle(.secondary)
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
    let version: Int
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable() } else { Color.white }
        }
        .aspectRatio(page.width / page.height, contentMode: .fit)
        .shadow(radius: 1)
        .task(id: "\(page.id)-\(doc.modified.timeIntervalSince1970)-\(version)") {
            if image != nil { try? await Task.sleep(nanoseconds: 600_000_000) }   // debounce while writing
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
    @AppStorage("search.handwriting") private var includeHandwriting = true
    @State private var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Suchen in PDF, Textfeldern und Handschrift", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
            Toggle("Handschrift durchsuchen", isOn: $includeHandwriting).font(.callout)
            if let progress {
                ProgressView(value: progress) { Text("Handschrift wird gelesen…").font(.caption) }
            }
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
            .listStyle(.plain)
            .overlay {
                if results.isEmpty && !query.isEmpty && progress == nil {
                    Text("Keine Treffer").foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private static func snippet(_ text: String, _ query: String) -> String? {
        guard let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let lo = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let hi = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lo..<hi]).replacingOccurrences(of: "\n", with: " ")
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        var out: [(page: Int, text: String)] = []
        var pdfs: [String: PDFDocument] = [:]
        for (i, page) in doc.pages.enumerated() {
            for tb in page.textBoxes where tb.text.localizedCaseInsensitiveContains(q) { out.append((i, tb.text)) }
            guard let att = page.pdfAttachment, let idx = page.pdfPageIndex else { continue }
            if pdfs[att] == nil { pdfs[att] = PDFDocument(url: store.attachmentURL(att, in: doc)) }
            if let text = pdfs[att]?.page(at: idx)?.string, let sn = Self.snippet(text, q) { out.append((i, sn)) }
        }
        results = out
        guard includeHandwriting else { return }

        let jobs = doc.pages.enumerated().map { i, page in
            (i, page, store.drawing(for: page, in: doc),
             store.packageURL(doc).appendingPathComponent("pages/\(page.id.uuidString).ocr.json"))
        }
        progress = 0
        Task {
            for (n, job) in jobs.enumerated() {
                let (i, page, drawing, url) = job
                let text = await Task.detached(priority: .userInitiated) {
                    HandwritingIndex.text(for: page, drawing: drawing, cacheURL: url)
                }.value
                if let sn = Self.snippet(text, q) { results.append((i, "✍︎ " + sn)) }
                progress = Double(n + 1) / Double(max(jobs.count, 1))
            }
            results.sort { $0.page < $1.page }
            progress = nil
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
