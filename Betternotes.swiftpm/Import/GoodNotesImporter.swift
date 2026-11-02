import Foundation
import PencilKit
import UIKit

/// Converts a `.goodnotes` archive into a Betternotes notebook. Strokes become
/// editable PencilKit strokes; PDFs are copied unchanged.
enum GoodNotesImporter {
    @MainActor
    static func importFile(_ url: URL, into store: DocumentStore) throws {
        let file = try GoodNotesFile(url: url)
        var doc = NoteDocument(title: file.title ?? url.deletingPathExtension().lastPathComponent, pages: [])
        store.save(doc)

        var copied: [String: String] = [:]   // attachment id -> file name in package
        var drawings: [(NotePage, PKDrawing)] = []
        for gp in file.pages {
            var page = NotePage()
            if let att = gp.attachment, let path = file.attachmentFiles[att] {
                if copied[att] == nil {
                    let name = "\(att).pdf"
                    try file.data(path).write(to: store.attachmentURL(name, in: doc))
                    copied[att] = name
                }
                page.pdfAttachment = copied[att]
                page.pdfPageIndex = max(0, (gp.pdfPage ?? 1) - 1)
            }
            var strokes = try file.strokes(on: gp)
            var images = (try? file.images(on: gp)) ?? []
            if let size = gp.size {
                page.width = size.width
                page.height = size.height
            } else {
                page.isBoard = true
                let box = boundingBox(strokes)
                strokes = strokes.map { s in
                    var s = s
                    s.lines = s.lines.map { $0.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) } }
                    return s
                }
                images = images.map { var i = $0; i.frame = i.frame.offsetBy(dx: -box.minX, dy: -box.minY); return i }
                page.width = box.width
                page.height = box.height
            }
            for img in images {
                guard let path = file.attachmentFiles[img.attachmentID], let data = try? file.data(path) else { continue }
                let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
                let name = store.addAttachment(data, ext: ext, to: doc)
                page.images.append(ImageItem(frame: img.frame, file: name))
            }
            drawings.append((page, PKDrawing(strokes: strokes.flatMap(pkStrokes))))
            doc.pages.append(page)
        }
        if doc.pages.isEmpty { doc.pages = [NotePage()] }
        store.save(doc)
        for (page, drawing) in drawings { store.saveDrawing(drawing, for: page, in: doc) }
    }

    /// GoodNotes strokes are flattened to dense point lists, so each subpath maps to one PKStroke.
    static func pkStrokes(_ s: GNStroke) -> [PKStroke] {
        let isMarker = s.color.a < 0.95
        let color = UIColor(red: s.color.r, green: s.color.g, blue: s.color.b, alpha: isMarker ? s.color.a : 1)
        let ink = PKInk(isMarker ? .marker : .pen, color: color)
        let size = CGSize(width: max(s.width * 2, 0.5), height: max(s.width * 2, 0.5))
        return s.lines.filter { $0.count > 1 }.map { line in
            let points = line.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.008, size: size,
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
    }

    /// Whiteboards sit around (250000, 250000) and contain stray points; use percentiles.
    private static func boundingBox(_ strokes: [GNStroke]) -> CGRect {
        let pts = strokes.flatMap { $0.lines.flatMap { $0 } }
        guard !pts.isEmpty else { return CGRect(x: 0, y: 0, width: 1091.64, height: 1543.74) }
        let xs = pts.map(\.x).sorted(), ys = pts.map(\.y).sorted()
        func q(_ a: [CGFloat], _ f: Double) -> CGFloat { a[Int(f * Double(a.count - 1))] }
        let pad: CGFloat = 80
        return CGRect(x: q(xs, 0.005) - pad, y: q(ys, 0.005) - pad,
                      width: q(xs, 0.995) - q(xs, 0.005) + 2 * pad,
                      height: q(ys, 0.995) - q(ys, 0.005) + 2 * pad)
    }
}
