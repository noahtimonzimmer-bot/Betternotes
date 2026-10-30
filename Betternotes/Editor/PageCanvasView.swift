import PDFKit
import PencilKit
import UIKit

/// One page: PDF (or blank) in the middle, free writing margin left and right,
/// PencilKit canvas spanning both. Drawings are kept in page coordinates
/// (x < 0 or x > page width = margin), independent of the on-screen scale.
final class PageCanvasView: UIView, PKCanvasViewDelegate {
    let canvas = PKCanvasView()
    private let paper = UIImageView()
    private let marginBackground = UIView()
    private var captureLayer: CAShapeLayer?
    private var captureStart: CGPoint?

    var pageSize: CGSize = CGSize(width: 1091.64, height: 1543.74)
    var margin: CGFloat = 0 { didSet { if margin != oldValue { setNeedsLayout() } } }
    var straighten = true
    var onChange: ((PKDrawing) -> Void)?
    var onEndUsingTool: (() -> Void)?
    var onCapture: ((UIImage) -> Void)?

    private(set) var pageDrawing = PKDrawing()
    private var scale: CGFloat = 0
    private var applying = false
    private var strokeCountAtToolStart = 0

    var captureMode = false {
        didSet {
            canvas.isUserInteractionEnabled = !captureMode
            captureGesture.isEnabled = captureMode
        }
    }
    private lazy var captureGesture = UIPanGestureRecognizer(target: self, action: #selector(capturePan(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        marginBackground.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.6)
        marginBackground.layer.cornerRadius = 6
        addSubview(marginBackground)
        paper.backgroundColor = .white
        paper.contentMode = .scaleToFill
        paper.layer.shadowOpacity = 0.15
        paper.layer.shadowRadius = 3
        paper.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(paper)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.delegate = self
        addSubview(canvas)
        captureGesture.isEnabled = false
        addGestureRecognizer(captureGesture)
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(drawing: PKDrawing, background: UIImage?) {
        pageDrawing = drawing
        paper.image = background
        scale = 0
        setNeedsLayout()
    }

    private var toView: CGAffineTransform {
        CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: margin, y: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let newScale = bounds.width / (pageSize.width + 2 * margin)
        guard newScale.isFinite, newScale > 0 else { return }
        marginBackground.frame = bounds
        marginBackground.isHidden = margin == 0
        paper.frame = CGRect(x: margin * newScale, y: 0,
                             width: pageSize.width * newScale, height: pageSize.height * newScale)
        canvas.frame = bounds
        if newScale != scale {
            scale = newScale
            applying = true
            canvas.drawing = pageDrawing.transformed(using: toView)
            applying = false
        }
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applying, scale > 0 else { return }
        pageDrawing = canvasView.drawing.transformed(using: toView.inverted())
        onChange?(pageDrawing)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        strokeCountAtToolStart = canvasView.drawing.strokes.count
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        if straighten, canvasView.tool is PKInkingTool,
           canvasView.drawing.strokes.count == strokeCountAtToolStart + 1,
           let last = canvasView.drawing.strokes.last, let straight = Self.straightened(last) {
            var d = canvasView.drawing
            d.strokes[d.strokes.count - 1] = straight
            canvasView.drawing = d   // triggers drawingDidChange → saved
        }
        onEndUsingTool?()
    }

    /// Replaces a nearly straight stroke by an exact line between its end points.
    static func straightened(_ stroke: PKStroke) -> PKStroke? {
        let pts = stroke.path.map { $0.location.applying(stroke.transform) }
        guard pts.count >= 3, let a = pts.first, let b = pts.last else { return nil }
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 60 else { return nil }
        let maxDev = pts.map { p in abs((b.y - a.y) * p.x - (b.x - a.x) * p.y + b.x * a.y - b.y * a.x) / len }.max() ?? 0
        guard maxDev < max(3, len * 0.025) else { return nil }
        let template = stroke.path.first!
        let n = 12
        let points = (0...n).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(n)
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                 timeOffset: TimeInterval(i) * 0.01, size: template.size,
                                 opacity: template.opacity, force: template.force,
                                 azimuth: template.azimuth, altitude: template.altitude)
        }
        return PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    // MARK: Capture (photo of a region)

    @objc private func capturePan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            captureStart = p
            let l = CAShapeLayer()
            l.fillColor = UIColor.systemBlue.withAlphaComponent(0.1).cgColor
            l.strokeColor = UIColor.systemBlue.cgColor
            l.lineDashPattern = [6, 4]
            layer.addSublayer(l)
            captureLayer = l
        case .changed:
            guard let s = captureStart else { return }
            captureLayer?.path = UIBezierPath(rect: CGRect(x: s.x, y: s.y, width: p.x - s.x, height: p.y - s.y).standardized).cgPath
        case .ended:
            defer { captureLayer?.removeFromSuperlayer(); captureLayer = nil; captureStart = nil }
            guard let s = captureStart else { return }
            let rect = CGRect(x: s.x, y: s.y, width: p.x - s.x, height: p.y - s.y).standardized
            guard rect.width > 10, rect.height > 10 else { return }
            captureLayer?.isHidden = true
            let image = UIGraphicsImageRenderer(bounds: rect).image { _ in
                drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            onCapture?(image)
        default:
            captureLayer?.removeFromSuperlayer(); captureLayer = nil; captureStart = nil
        }
    }
}

enum PageBackground {
    /// Renders a PDF page as the paper image (2× for sharpness).
    static func image(pdf url: URL, index: Int, size: CGSize) -> UIImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: index) else { return nil }
        return page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
    }
}
