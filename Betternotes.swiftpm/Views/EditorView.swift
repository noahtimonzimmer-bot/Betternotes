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
                        // the band opens up-left of the tip: keep that much room
                        let r = ToolPaletteView.radius + 40
                        ToolPaletteView(onUndo: { model.undoManager()?.undo() })
                            .position(x: min(max(p.x, r), geo.size.width - 110),
                                      y: min(max(p.y, r), geo.size.height - 70))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                if let t = model.toast {
                    Label(t, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color(.systemBackground), in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .padding(.top, 70)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Text("\(model.currentPage + 1) / \(doc.pages.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color(.systemBackground).opacity(0.95), in: Capsule())
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
            // Fixed, generous space on both sides; never changes while you work (no jumping).
            let d = page.isBoard ? defaultMargin(for: page) : max(defaultMargin(for: page), page.width * 2)
            return (max(d, page.marginLeft.map { CGFloat($0) } ?? d), max(d, page.marginRight.map { CGFloat($0) } ?? d))
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
            v.growStep = 0
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
    /// Docked left/right: tools stacked top to bottom.
    var vertical = false

    private var divider: some View {
        Capsule().fill(Color.secondary.opacity(0.3))
            .frame(width: vertical ? 24 : 1, height: vertical ? 1 : 24)
            .padding(vertical ? .vertical : .horizontal, 4)
    }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            Image(systemName: vertical ? "line.3.horizontal" : "line.3.horizontal")
                .rotationEffect(.degrees(vertical ? 90 : 0))
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: vertical ? 36 : 22, height: vertical ? 22 : 36)
                .contentShape(Rectangle())
                .accessibilityLabel("Leiste andocken")
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
            divider
            ForEach(ToolController.widths, id: \.self) { w in
                Button { tools.width = w } label: {
                    Circle().fill(Color.primary)
                        .frame(width: 4 + w * 2.2, height: 4 + w * 2.2)
                        .frame(width: 30, height: 36)
                        .background(Circle().stroke(Color.accentColor, lineWidth: tools.width == w ? 2 : 0).frame(width: 28, height: 28))
                }
                .buttonStyle(.plain)
            }
            divider
            ForEach(ToolController.palette, id: \.self) { c in
                Circle().fill(Color(uiColor: c)).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.2), radius: 1)
                    .padding(4)
                    .overlay(Circle().stroke(Color.primary.opacity(0.6), lineWidth: tools.currentColor == c ? 2 : 0))
                    .onTapGesture { tools.setColor(c) }
            }
            divider
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
        .padding(.horizontal, vertical ? 4 : 8)
        .padding(.vertical, vertical ? 8 : 4)
    }

    private func toolTint(_ k: ToolController.Kind) -> Color {
        k.usesColor ? Color(uiColor: k == .marker ? tools.markerColor : tools.color).opacity(0.95) : Color.accentColor
    }
}

/// Tool bar docked at one of four places (top, bottom, left, right – each centred).
/// Drag it by the grip: on release it snaps to the nearest place.
struct FloatingToolBar: View {
    enum Dock: String { case top, bottom, left, right }
    @AppStorage("toolbar.dock") private var dockRaw = Dock.top.rawValue
    @State private var drag: CGSize = .zero
    let area: CGSize

    private var dock: Dock { Dock(rawValue: dockRaw) ?? .top }

    private func anchor(_ d: Dock) -> CGPoint {
        switch d {
        case .top: return CGPoint(x: area.width / 2, y: 34)
        case .bottom: return CGPoint(x: area.width / 2, y: area.height - 34)
        case .left: return CGPoint(x: 34, y: area.height / 2)
        case .right: return CGPoint(x: area.width - 34, y: area.height / 2)
        }
    }

    var body: some View {
        let vertical = dock == .left || dock == .right
        let a = anchor(dock)
        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            ToolBar(vertical: vertical).fixedSize()
        }
        .fixedSize(horizontal: !vertical, vertical: vertical)
        .frame(maxWidth: vertical ? nil : area.width - 24, maxHeight: vertical ? area.height - 24 : nil)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .position(x: a.x + drag.width, y: a.y + drag.height)
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { drag = $0.translation }
            .onEnded { v in
                let p = CGPoint(x: a.x + v.translation.width, y: a.y + v.translation.height)
                let target = [Dock.top, .bottom, .left, .right].min { d1, d2 in
                    let p1 = anchor(d1), p2 = anchor(d2)
                    return hypot(p1.x - p.x, p1.y - p.y) < hypot(p2.x - p.x, p2.y - p.y)
                } ?? .top
                withAnimation(.spring(duration: 0.3)) {
                    dockRaw = target.rawValue
                    drag = .zero
                }
            })
        .animation(.spring(duration: 0.3), value: dockRaw)
    }
}

/// Appears around the pencil tip on squeeze (Apple Pencil Pro): one curved band with
/// undo, tools, stroke width and colour; width/colour open a second arc outside.
struct ToolPaletteView: View {
    @EnvironmentObject var tools: ToolController
    var onUndo: () -> Void = {}
    static let radius: CGFloat = 190
    private static let band: CGFloat = 62
    private static let from: Double = 168, to: Double = 292   // degrees, 180 = left, 270 = up
    @State private var expanded: Expanded?
    enum Expanded { case colors, widths }

    private let kinds: [ToolController.Kind] = [.lasso, .cameraLasso, .pen, .marker, .shape, .eraser, .text]

    var body: some View {
        let r = Self.radius
        let count = kinds.count + 3          // undo + tools + width + colour
        ZStack {
            // the band
            arc(r).stroke(Color(.systemBackground), style: StrokeStyle(lineWidth: Self.band, lineCap: .round))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
            arc(r).stroke(Color.primary.opacity(0.06), style: StrokeStyle(lineWidth: Self.band, lineCap: .round))

            item(0, of: count) {
                Button(action: onUndo) { icon("arrow.uturn.backward", active: false) }
            }
            ForEach(Array(kinds.enumerated()), id: \.element) { i, k in
                item(i + 1, of: count) {
                    Button { tools.select(k); tools.paletteLocation = nil } label: { icon(k.symbol, active: tools.kind == k) }
                }
            }
            item(count - 2, of: count) {
                Button { expanded = expanded == .widths ? nil : .widths } label: {
                    VStack(spacing: 3) {
                        Capsule().frame(width: 22, height: max(1.5, tools.width * 0.9))
                        Capsule().frame(width: 22, height: 1).opacity(0.35)
                    }
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            item(count - 1, of: count) {
                Button { expanded = expanded == .colors ? nil : .colors } label: {
                    Circle().fill(Color(uiColor: tools.currentColor)).frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.2), radius: 1)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            // second arc: colours or widths
            if let expanded {
                let outer = r + Self.band + 8
                arc(outer).stroke(Color(.systemBackground), style: StrokeStyle(lineWidth: 54, lineCap: .round))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                switch expanded {
                case .colors:
                    let colors = ToolController.palette
                    ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
                        position(i, of: colors.count, radius: outer) {
                            Circle().fill(Color(uiColor: c)).frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .overlay(Circle().stroke(Color.accentColor, lineWidth: tools.currentColor == c ? 3 : 0).padding(-4))
                                .onTapGesture { tools.setColor(c); tools.paletteLocation = nil }
                        }
                    }
                case .widths:
                    let widths: [CGFloat] = [1, 1.6, 2.6, 4.5, 7]
                    ForEach(Array(widths.enumerated()), id: \.offset) { i, w in
                        position(i, of: widths.count, radius: outer) {
                            Button { tools.width = w; tools.paletteLocation = nil } label: {
                                Circle().fill(Color.primary).frame(width: 4 + w * 2.4, height: 4 + w * 2.4)
                                    .frame(width: 40, height: 40)
                                    .background(Circle().stroke(Color.accentColor, lineWidth: abs(tools.width - w) < 0.01 ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 2 * (r + 130), height: 2 * (r + 130))
        .animation(.spring(duration: 0.25), value: expanded)
    }

    private func arc(_ radius: CGFloat) -> Path {
        Path { p in
            let c = CGPoint(x: Self.radius + 130, y: Self.radius + 130)
            p.addArc(center: c, radius: radius, startAngle: .degrees(Self.from), endAngle: .degrees(Self.to), clockwise: false)
        }
    }

    private func angle(_ i: Int, of n: Int) -> CGFloat {
        let t = n > 1 ? Double(i) / Double(n - 1) : 0.5
        let pad = 6.0   // keep the first/last item inside the rounded ends
        return CGFloat((Self.from + pad + (Self.to - Self.from - 2 * pad) * t) * .pi / 180)
    }

    private func item<V: View>(_ i: Int, of n: Int, @ViewBuilder _ content: () -> V) -> some View {
        position(i, of: n, radius: Self.radius, content)
    }

    private func position<V: View>(_ i: Int, of n: Int, radius: CGFloat, @ViewBuilder _ content: () -> V) -> some View {
        let a = angle(i, of: n)
        return content().offset(x: radius * cos(a), y: radius * sin(a))
    }

    private func icon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(active ? Color.white : Color.primary)
            .frame(width: 42, height: 42)
            .background(Circle().fill(active ? Color(uiColor: tools.currentColor).opacity(0.9) : Color.clear))
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
