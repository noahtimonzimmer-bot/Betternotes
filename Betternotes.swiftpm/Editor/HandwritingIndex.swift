import PencilKit
import UIKit
import Vision

/// Handwriting recognition for search: ink of each page is rendered and read with Vision.
/// Results are cached next to the drawing (`pages/<id>.ocr.json`) and redone only when the ink changes.
enum HandwritingIndex {
    private struct Cache: Codable { var key: String; var text: String }

    /// Recognised text of a page's handwriting (empty if none).
    static func text(for page: NotePage, drawing: PKDrawing, cacheURL: URL) -> String {
        guard !drawing.strokes.isEmpty else { return "" }
        let key = "\(drawing.strokes.count)-\(Int(drawing.bounds.width))-\(Int(drawing.bounds.height))-\(Int(drawing.bounds.minX))"
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.key == key {
            return cache.text
        }
        let text = recognize(drawing)
        if let data = try? JSONEncoder().encode(Cache(key: key, text: text)) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return text
    }

    static func recognize(_ drawing: PKDrawing) -> String {
        let bounds = drawing.bounds.insetBy(dx: -10, dy: -10)
        guard bounds.width > 1, bounds.height > 1 else { return "" }
        // Dark ink on white, ~1600 px wide for good recognition.
        let scale = min(3, 1600 / bounds.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let traits = UITraitCollection(userInterfaceStyle: .light)
        var ink = UIImage()
        traits.performAsCurrent { ink = drawing.image(from: bounds, scale: scale) }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
