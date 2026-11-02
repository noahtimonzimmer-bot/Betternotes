import PDFKit
import UIKit

/// Paper rendering (PDF page or template) on a serial background queue.
enum PageBackground {
    private static let queue = DispatchQueue(label: "betternotes.paper", qos: .userInitiated)
    nonisolated(unsafe) private static var pdfCache: [URL: PDFDocument] = [:]   // only touched on `queue`

    static func render(page: NotePage, pdf: URL?, pixelWidth: CGFloat, completion: @escaping (UIImage?) -> Void) {
        queue.async {
            let img = image(page: page, pdf: pdf, pixelWidth: pixelWidth)
            DispatchQueue.main.async { completion(img) }
        }
    }

    /// Synchronous variant for export/thumbnails; must not run concurrently with `render`.
    static func imageSync(page: NotePage, pdf: URL?, pixelWidth: CGFloat) -> UIImage? {
        queue.sync { image(page: page, pdf: pdf, pixelWidth: pixelWidth) }
    }

    static func pdfPage(_ url: URL, _ index: Int) -> PDFPage? {
        queue.sync { document(url)?.page(at: index) }
    }

    private static func document(_ url: URL) -> PDFDocument? {
        if let d = pdfCache[url] { return d }
        if pdfCache.count > 6 { pdfCache.removeAll() }
        let d = PDFDocument(url: url)
        pdfCache[url] = d
        return d
    }

    private static func image(page: NotePage, pdf: URL?, pixelWidth: CGFloat) -> UIImage? {
        let size = CGSize(width: pixelWidth, height: pixelWidth * page.height / page.width)
        if let pdf, let p = document(pdf)?.page(at: page.pdfPageIndex ?? 0) {
            return p.thumbnail(of: size, for: .mediaBox)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            drawTemplate(page.template, in: ctx.cgContext, size: size, unit: size.width / page.width)
        }
    }

    static let dotStep: CGFloat = 40
    static let dotRadius: CGFloat = 1.4
    static let dotColor = UIColor(white: 0.45, alpha: 0.32)

    /// Repeating tile for the dotted area around pages; dots line up with the page grid.
    /// `scale` = points per page unit, `originX` = x of the paper's left edge in the view.
    static func dotPattern(scale: CGFloat, originX: CGFloat) -> UIColor {
        let s = max(4, dotStep * scale)
        let r = max(0.7, dotRadius * scale)
        let ox = originX.truncatingRemainder(dividingBy: s)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let tile = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: format).image { ctx in
            UIColor(white: 0.975, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            dotColor.setFill()
            // dot sits on the tile corner row; draw wrapped copies so halves meet across tiles
            for dx in [ox - s, ox, ox + s] {
                for dy in [0, s] {
                    ctx.cgContext.fillEllipse(in: CGRect(x: dx - r, y: dy - r, width: 2 * r, height: 2 * r))
                }
            }
        }
        return UIColor(patternImage: tile)
    }

    /// Draws ruling in a context whose page origin is (0,0); `unit` = pixels per page unit.
    static func drawTemplate(_ t: PageTemplate, in c: CGContext, size: CGSize, unit: CGFloat) {
        let line = UIColor(red: 0.62, green: 0.72, blue: 0.86, alpha: 0.7).cgColor
        c.setStrokeColor(line)
        c.setFillColor(line)
        c.setLineWidth(max(1, 1.2 * unit))
        switch t {
        case .blank:
            break
        case .lined:
            var y = 160 * unit
            while y < size.height - 40 * unit {
                c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: size.width, y: y)); y += 52 * unit
            }
            c.strokePath()
        case .grid:
            let step = 40 * unit
            var x = step
            while x < size.width { c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y = step
            while y < size.height { c.move(to: CGPoint(x: 0, y: y)); c.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            c.strokePath()
        case .dotted:
            // subtle grey dots, same grid as the dotted writing area beside the page
            c.setFillColor(dotColor.cgColor)
            let step = dotStep * unit, r = max(0.8, dotRadius * unit)
            var y = step
            while y < size.height {
                var x = step
                while x < size.width { c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)); x += step }
                y += step
            }
        }
    }
}
