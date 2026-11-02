import SwiftUI

struct CropRequest: Identifiable {
    let pageID: UUID
    let itemID: UUID
    var id: UUID { itemID }
}

/// Crop an image on the page: drag the corners, "Fertig" saves a cropped copy and
/// shrinks the image frame accordingly (the original file stays untouched).
struct ImageCropView: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    let docID: UUID
    let request: CropRequest
    @State private var image: UIImage?
    /// Crop rectangle in unit coordinates (0…1) of the image.
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var startCrop: CGRect?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if let image {
                    let fit = fitted(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height)
                        cropOverlay(fit)
                    }
                    .frame(width: fit.width, height: fit.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(24)
            .background(Color(.systemGray6))
            .navigationTitle("Zuschneiden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Button("Zurücksetzen") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { apply(); dismiss() } }
            }
        }
        .onAppear(perform: load)
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
        let k = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
        return CGSize(width: size.width * k, height: size.height * k)
    }

    @ViewBuilder
    private func cropOverlay(_ fit: CGSize) -> some View {
        let r = CGRect(x: crop.minX * fit.width, y: crop.minY * fit.height,
                       width: crop.width * fit.width, height: crop.height * fit.height)
        // dim outside
        Path { p in
            p.addRect(CGRect(origin: .zero, size: fit))
            p.addRect(r)
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        Rectangle().stroke(Color.white, lineWidth: 2)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .gesture(drag(fit) { c, dx, dy in c.offsetBy(dx: dx, dy: dy) })
        ForEach(0..<4, id: \.self) { corner in
            let left = corner == 0 || corner == 3, top = corner < 2
            Circle().fill(Color.white).frame(width: 26, height: 26).shadow(radius: 2)
                .position(x: left ? r.minX : r.maxX, y: top ? r.minY : r.maxY)
                .gesture(drag(fit) { c, dx, dy in
                    var minX = c.minX, minY = c.minY, maxX = c.maxX, maxY = c.maxY
                    if left { minX += dx } else { maxX += dx }
                    if top { minY += dy } else { maxY += dy }
                    return CGRect(x: min(minX, maxX - 0.05), y: min(minY, maxY - 0.05),
                                  width: max(0.05, maxX - minX), height: max(0.05, maxY - minY))
                })
        }
    }

    private func drag(_ fit: CGSize, _ change: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let base = startCrop ?? crop
                if startCrop == nil { startCrop = crop }
                let next = change(base, v.translation.width / fit.width, v.translation.height / fit.height)
                crop = next.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            .onEnded { _ in startCrop = nil }
    }

    private var item: (doc: NoteDocument, page: NotePage, item: ImageItem)? {
        guard let doc = store.document(docID),
              let page = doc.pages.first(where: { $0.id == request.pageID }),
              let item = page.images.first(where: { $0.id == request.itemID }) else { return nil }
        return (doc, page, item)
    }

    private func load() {
        guard let it = item, let img = UIImage(contentsOfFile: store.attachmentURL(it.item.file, in: it.doc).path) else { return }
        // normalise orientation so pixel crop matches what is shown
        let format = UIGraphicsImageRendererFormat()
        format.scale = img.scale
        image = UIGraphicsImageRenderer(size: img.size, format: format).image { _ in img.draw(at: .zero) }
    }

    private func apply() {
        guard let it = item, let image, let cg = image.cgImage else { return }
        let px = CGRect(x: crop.minX * CGFloat(cg.width), y: crop.minY * CGFloat(cg.height),
                        width: crop.width * CGFloat(cg.width), height: crop.height * CGFloat(cg.height)).integral
        guard let cropped = cg.cropping(to: px), let data = UIImage(cgImage: cropped).pngData() else { return }
        let name = store.addAttachment(data, ext: "png", to: it.doc)
        var page = it.page
        guard let i = page.images.firstIndex(where: { $0.id == it.item.id }) else { return }
        let f = it.item.frame
        page.images[i].file = name
        page.images[i].frame = CGRect(x: f.minX + crop.minX * f.width, y: f.minY + crop.minY * f.height,
                                      width: crop.width * f.width, height: crop.height * f.height)
        page.images[i].id = UUID()   // new id so the page shows the new file
        store.updatePage(page, in: docID)
    }
}
