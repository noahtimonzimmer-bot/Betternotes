import PencilKit
import SwiftUI

struct EditorView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var settings: AppSettings
    @StateObject private var tools: ToolController
    @State private var toast: String?
    let document: NoteDocument

    init(document: NoteDocument, settings: AppSettings) {
        self.document = document
        _tools = StateObject(wrappedValue: ToolController(settings: settings))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PencilGestureView(tools: tools)
            ScrollView(.vertical) {
                LazyVStack(spacing: 24) {
                    ForEach(document.pages) { page in
                        PageView(document: document, page: page, margin: margin(for: page)) { image in
                            UIPasteboard.general.image = image
                            showToast("Ausschnitt in die Zwischenablage kopiert")
                        }
                        .aspectRatio((page.width + 2 * margin(for: page)) / page.height, contentMode: .fit)
                        .frame(maxWidth: page.isBoard ? nil : 1400)
                    }
                }
                .padding()
            }
            if let p = tools.paletteLocation {
                ToolPaletteView()
                    .position(x: p.x, y: max(80, p.y - 70))
                    .transition(.scale.combined(with: .opacity))
            }
            if let t = toast {
                Text(t).padding(10).background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }
        }
        .animation(.spring(duration: 0.2), value: tools.paletteLocation)
        .environmentObject(tools)
        .background(Color(.systemGray5))
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { ToolBar().environmentObject(tools) } }
    }

    private func margin(for page: NotePage) -> Double {
        page.isBoard ? 0 : page.width * settings.marginRatio
    }

    private func showToast(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { toast = nil }
    }
}

struct ToolBar: View {
    @EnvironmentObject var tools: ToolController

    var body: some View {
        HStack(spacing: 14) {
            ForEach(ToolController.Kind.allCases) { k in
                Button { tools.select(k) } label: {
                    Image(systemName: k.symbol)
                        .padding(6)
                        .background(tools.kind == k ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Divider().frame(height: 22)
            ForEach(ToolController.palette, id: \.self) { c in
                Circle().fill(Color(c)).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.primary, lineWidth: tools.color == c ? 2 : 0).padding(-3))
                    .onTapGesture { tools.color = c; if tools.kind == .eraser || tools.kind == .lasso { tools.select(.pen) } }
            }
        }
    }
}

/// Appears at the pencil tip on squeeze (Apple Pencil Pro).
struct ToolPaletteView: View {
    @EnvironmentObject var tools: ToolController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ForEach([ToolController.Kind.pen, .pencil, .marker, .eraser, .lasso]) { k in
                    Button { tools.select(k); tools.paletteLocation = nil } label: {
                        Image(systemName: k.symbol).font(.title3).frame(width: 36, height: 36)
                            .background(tools.kind == k ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(ToolController.palette, id: \.self) { c in
                    Circle().fill(Color(c)).frame(width: 26, height: 26)
                        .onTapGesture {
                            tools.color = c
                            if tools.kind == .eraser || tools.kind == .lasso { tools.select(.pen) }
                            tools.paletteLocation = nil
                        }
                }
            }
            Slider(value: $tools.width, in: 0.5...12).frame(width: 220)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(radius: 8)
    }
}

struct PageView: UIViewRepresentable {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var tools: ToolController
    @EnvironmentObject var settings: AppSettings
    let document: NoteDocument
    let page: NotePage
    let margin: Double
    let onCapture: (UIImage) -> Void

    func makeUIView(context: Context) -> PageCanvasView {
        let v = PageCanvasView()
        v.pageSize = page.size
        v.margin = margin
        let bg = page.pdfAttachment.flatMap { name in
            PageBackground.image(pdf: store.attachmentURL(name, in: document), index: page.pdfPageIndex ?? 0, size: page.size)
        }
        v.load(drawing: store.drawing(for: page, in: document), background: bg)
        v.onChange = { [store, document, page] d in store.saveDrawing(d, for: page, in: document) }
        let controller = tools
        v.onEndUsingTool = { [weak controller] in controller?.didEndUsingTool() }
        v.onCapture = onCapture
        return v
    }

    func updateUIView(_ v: PageCanvasView, context: Context) {
        v.margin = margin
        v.straighten = settings.straightenLines
        v.canvas.drawingPolicy = settings.onlyPencilDraws ? .pencilOnly : .anyInput
        v.captureMode = tools.kind == .capture
        v.canvas.tool = tools.tool
    }
}
