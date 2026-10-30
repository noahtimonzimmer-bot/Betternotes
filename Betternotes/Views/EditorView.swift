import SwiftUI
import PDFKit
import PencilKit

struct EditorView: View {
    @EnvironmentObject var store: DocumentStore
    let document: NoteDocument

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(document.pages) { page in
                    PageView(document: document, page: page)
                        .aspectRatio(595.0 / 842.0, contentMode: .fit)
                        .background(.white)
                        .shadow(radius: 2)
                }
            }
            .padding()
        }
        .background(Color(.systemGray5))
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// PDF (or blank) background with a PencilKit canvas on top. Strokes are stored
/// separately from the PDF, so they stay editable after reopening.
struct PageView: UIViewRepresentable {
    @EnvironmentObject var store: DocumentStore
    let document: NoteDocument
    let page: NotePage

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .white

        let bg = UIImageView()
        bg.contentMode = .scaleAspectFit
        bg.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bg)

        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.drawing = store.drawing(for: page, in: document)
        canvas.delegate = context.coordinator
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas)

        let picker = PKToolPicker()
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        context.coordinator.picker = picker
        canvas.becomeFirstResponder()

        for v in [bg, canvas] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        if let name = page.pdfAttachment, let idx = page.pdfPageIndex,
           let pdf = PDFDocument(url: store.attachmentURL(name, in: document)),
           let p = pdf.page(at: idx) {
            let size = p.bounds(for: .mediaBox).size
            bg.image = p.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: PageView
        var picker: PKToolPicker?
        init(_ parent: PageView) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.store.saveDrawing(canvasView.drawing, for: parent.page, in: parent.document)
        }
    }
}
