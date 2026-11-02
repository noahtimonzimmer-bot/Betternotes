import PDFKit
import PencilKit
import UIKit

/// Off-screen rendering of a whole page (paper + images + text + ink) for thumbnails and export.
enum PageRenderer {
    /// Thumbnail image of the page area (margins excluded).
    static func image(page: NotePage, drawing: PKDrawing, pdf: URL?, width: CGFloat) -> UIImage {
        let scale = width / page.width
        let size = CGSize(width: width, height: page.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.scaleBy(x: scale, y: scale)
            draw(page: page, drawing: drawing, pdf: pdf, attachments: nil, in: ctx.cgContext,
                 rect: CGRect(origin: .zero, size: page.size))
        }
    }

    /// Draws `rect` (page coordinates, may include margins) into a context set up in page units.
    static func draw(page: NotePage, drawing: PKDrawing, pdf: URL?, attachments: ((String) -> URL)?,
                     in c: CGContext, rect: CGRect) {
        c.saveGState()
        UIColor.white.setFill()
        c.fill(rect)
        let paper = CGRect(origin: .zero, size: page.size)
        if let pdf, let p = PDFDocument(url: pdf)?.page(at: page.pdfPageIndex ?? 0) {
            let box = p.bounds(for: .mediaBox)
            c.saveGState()
            c.translateBy(x: 0, y: page.height)
            c.scaleBy(x: page.width / box.width, y: -page.height / box.height)
            c.translateBy(x: -box.minX, y: -box.minY)
            p.draw(with: .mediaBox, to: c)
            c.restoreGState()
        } else {
            PageBackground.drawTemplate(page.template, in: c, size: page.size, unit: 1)
        }
        if let attachments {
            for item in page.images {
                if let img = UIImage(contentsOfFile: attachments(item.file).path) {
                    UIGraphicsPushContext(c); img.draw(in: item.frame); UIGraphicsPopContext()
                }
            }
        }
        UIGraphicsPushContext(c)
        for tb in page.textBoxes {
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: tb.fontSize),
                                                        .foregroundColor: UIColor(hex: tb.colorHex)]
            (tb.text as NSString).draw(in: tb.frame.insetBy(dx: 4, dy: 4), withAttributes: attrs)
        }
        // Ink rasterised at 3× for crisp output; PencilKit has no vector export.
        let inkRect = rect.intersection(drawing.bounds.insetBy(dx: -4, dy: -4))
        if !inkRect.isNull, !inkRect.isEmpty {
            let img = drawing.image(from: inkRect, scale: 3)
            img.draw(in: inkRect)
        }
        UIGraphicsPopContext()
        _ = paper
        c.restoreGState()
    }
}

enum PDFExporter {
    /// Writes the notebook as a PDF. Pages grow to include the writing margin if it contains ink.
    @MainActor
    static func export(_ doc: NoteDocument, store: DocumentStore, marginRatio: CGFloat) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(doc.title.replacingOccurrences(of: "/", with: "-"))
            .appendingPathExtension("pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try renderer.writePDF(to: url) { ctx in
            for page in doc.pages {
                let drawing = store.drawing(for: page, in: doc)
                let m = page.isBoard ? 0 : marginRatio * page.width
                var rect = CGRect(origin: .zero, size: page.size)
                let ink = drawing.bounds
                if !ink.isNull, ink.minX < 0 || ink.maxX > page.width {
                    rect = CGRect(x: -m, y: 0, width: page.width + 2 * m, height: page.height)
                }
                // PDF points: GoodNotes-style page units are ~1.8335 × points.
                let k = 595.28 / 1091.64
                ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: rect.width * k, height: rect.height * k), pageInfo: [:])
                let c = ctx.cgContext
                c.scaleBy(x: k, y: k)
                c.translateBy(x: -rect.minX, y: -rect.minY)
                PageRenderer.draw(page: page, drawing: drawing,
                                  pdf: page.pdfAttachment.map { store.attachmentURL($0, in: doc) },
                                  attachments: { store.attachmentURL($0, in: doc) }, in: c, rect: rect)
            }
        }
        return url
    }
}
