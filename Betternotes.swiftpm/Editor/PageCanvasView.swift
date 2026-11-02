import PencilKit
import UIKit

/// One page: paper (PDF, template or blank) in the middle, free writing margin left and right,
/// images and text boxes, and a PencilKit canvas spanning everything. Drawings and items are
/// kept in page coordinates (x < 0 or x > page width = margin), independent of screen scale.
@MainActor
final class PageCanvasView: UIView, PKCanvasViewDelegate, UITextViewDelegate, UIContextMenuInteractionDelegate {
    enum Mode { case ink, shape, objects, camera, lasso }

    let canvas = PKCanvasView()
    private let marginBackground = UIView()
    private let paper = UIImageView()
    private let itemsLayer = UIView()
    private var textViews: [UUID: UITextView] = [:]
    private var imageViews: [UUID: UIImageView] = [:]

    private(set) var page: NotePage
    private(set) var pageDrawing: PKDrawing
    var margin: CGFloat = 0 { didSet { if margin != oldValue { scale = 0; setNeedsLayout() } } }
    var straighten = true
    var mode: Mode = .ink { didSet { applyMode() } }

    var onDrawingChange: ((PKDrawing) -> Void)?
    var onPageChange: ((NotePage) -> Void)?
    var onEndUsingTool: (() -> Void)?
    var onCapture: ((UIImage) -> Void)?
    /// Renders the paper at the given pixel width (async); called again when zooming.
    var backgroundRenderer: ((CGFloat, @escaping (UIImage?) -> Void) -> Void)? { didSet { renderedWidth = 0; setNeedsLayout() } }
    var imageLoader: ((String) -> UIImage?)?

    private var scale: CGFloat = 0
    private var zoom: CGFloat = 1
    private var renderedWidth: CGFloat = 0
    private var applying = false
    private var strokeCountAtToolStart = 0

    private lazy var cameraGesture = UIPanGestureRecognizer(target: self, action: #selector(cameraPan(_:)))
    private lazy var newTextGesture = UITapGestureRecognizer(target: self, action: #selector(tapToCreateText(_:)))
    private var lassoPath: UIBezierPath?
    private var lassoLayer: CAShapeLayer?

    init(page: NotePage, drawing: PKDrawing) {
        self.page = page
        self.pageDrawing = drawing
        super.init(frame: .zero)
        backgroundColor = .clear

        marginBackground.backgroundColor = UIColor.secondarySystemBackground
        marginBackground.layer.cornerRadius = 8
        addSubview(marginBackground)

        paper.backgroundColor = .white
        paper.contentMode = .scaleToFill
        paper.layer.shadowOpacity = 0.15
        paper.layer.shadowRadius = 3
        paper.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(paper)

        addSubview(itemsLayer)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.delegate = self
        addSubview(canvas)

        cameraGesture.isEnabled = false
        addGestureRecognizer(cameraGesture)
        newTextGesture.isEnabled = false
        itemsLayer.addGestureRecognizer(newTextGesture)

        syncItems()
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Geometry

    private var toView: CGAffineTransform {
        CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: margin, y: 0)
    }

    func viewRect(_ r: CGRect) -> CGRect { r.applying(toView) }
    func pagePoint(_ p: CGPoint) -> CGPoint { p.applying(toView.inverted()) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = bounds.width / (page.size.width + 2 * margin)
        guard s.isFinite, s > 0 else { return }
        let changed = s != scale
        scale = s
        marginBackground.frame = bounds
        marginBackground.isHidden = margin == 0
        paper.frame = viewRect(CGRect(origin: .zero, size: page.size))
        itemsLayer.frame = bounds
        canvas.frame = bounds
        layoutItems()
        if changed {
            applying = true
            canvas.drawing = pageDrawing.transformed(using: toView)
            applying = false
        }
        requestBackgroundIfNeeded()
    }

    /// Called by the document view when the zoom level settles.
    func setZoom(_ z: CGFloat) {
        zoom = z
        let screen = window?.screen.scale ?? 2
        canvas.contentScaleFactor = min(screen * max(z, 1), 8)
        requestBackgroundIfNeeded()
    }

    private func requestBackgroundIfNeeded() {
        guard let render = backgroundRenderer, paper.bounds.width > 0 else { return }
        let screen = window?.screen.scale ?? 2
        let wanted = min(paper.bounds.width * screen * max(zoom, 1), 3600)
        guard renderedWidth == 0 || wanted > renderedWidth * 1.3 || wanted < renderedWidth * 0.5 else { return }
        renderedWidth = wanted
        render(wanted) { [weak self] img in
            if let img { self?.paper.image = img }
        }
    }

    // MARK: Modes

    private func applyMode() {
        let objects = mode == .objects
        canvas.isUserInteractionEnabled = mode == .ink || mode == .shape || mode == .lasso
        cameraGesture.isEnabled = mode == .camera
        newTextGesture.isEnabled = objects
        itemsLayer.isUserInteractionEnabled = objects
        for tv in textViews.values {
            tv.isEditable = objects
            tv.isSelectable = objects
            if !objects, tv.isFirstResponder { tv.resignFirstResponder() }
        }
    }

    // MARK: Page model updates

    func update(page newPage: NotePage) {
        let sizeChanged = newPage.size != page.size
        page = newPage
        syncItems()
        if sizeChanged { scale = 0; renderedWidth = 0 }
        setNeedsLayout()
    }

    private func commitPage() { onPageChange?(page) }

    // MARK: Items (text boxes and images)

    private func syncItems() {
        let tbIDs = Set(page.textBoxes.map(\.id))
        for (id, v) in textViews where !tbIDs.contains(id) { v.removeFromSuperview(); textViews[id] = nil }
        for tb in page.textBoxes {
            let tv = textViews[tb.id] ?? makeTextView(tb.id)
            if !tv.isFirstResponder, tv.text != tb.text { tv.text = tb.text }
            tv.textColor = UIColor(hex: tb.colorHex)
        }
        let imgIDs = Set(page.images.map(\.id))
        for (id, v) in imageViews where !imgIDs.contains(id) { v.removeFromSuperview(); imageViews[id] = nil }
        for item in page.images where imageViews[item.id] == nil {
            let iv = UIImageView(image: imageLoader?(item.file))
            iv.contentMode = .scaleAspectFit
            iv.isUserInteractionEnabled = true
            iv.accessibilityIdentifier = "bn.item"
            iv.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveItem(_:))))
            iv.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinchItem(_:))))
            iv.addInteraction(UIContextMenuInteraction(delegate: self))
            itemsLayer.insertSubview(iv, at: 0)   // images below text
            imageViews[item.id] = iv
        }
        layoutItems()
    }

    private func makeTextView(_ id: UUID) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.delegate = self
        tv.accessibilityIdentifier = "bn.item"
        tv.textContainer.lineFragmentPadding = 0
        let pan = UIPanGestureRecognizer(target: self, action: #selector(moveItem(_:)))
        pan.minimumNumberOfTouches = 1
        tv.addGestureRecognizer(pan)
        tv.addInteraction(UIContextMenuInteraction(delegate: self))
        tv.isEditable = mode == .objects
        tv.isSelectable = mode == .objects
        itemsLayer.addSubview(tv)
        textViews[id] = tv
        return tv
    }

    private func layoutItems() {
        guard scale > 0 else { return }
        for tb in page.textBoxes {
            guard let tv = textViews[tb.id] else { continue }
            tv.frame = viewRect(tb.frame)
            tv.font = UIFont.systemFont(ofSize: tb.fontSize * scale)
            tv.textContainerInset = UIEdgeInsets(top: 4 * scale, left: 4 * scale, bottom: 4 * scale, right: 4 * scale)
            tv.layer.borderWidth = mode == .objects ? 1 : 0
            tv.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.4).cgColor
        }
        for item in page.images {
            imageViews[item.id]?.frame = viewRect(item.frame)
        }
    }

    private func itemID(for view: UIView) -> UUID? {
        if let id = textViews.first(where: { $0.value === view })?.key { return id }
        return imageViews.first(where: { $0.value === view })?.key
    }

    @objc private func tapToCreateText(_ g: UITapGestureRecognizer) {
        let p = pagePoint(g.location(in: self))
        let box = TextBox(frame: CGRect(x: p.x, y: p.y - 20, width: min(600, page.size.width - p.x + margin), height: 60))
        page.textBoxes.append(box)
        syncItems()
        textViews[box.id]?.becomeFirstResponder()
        commitPage()
    }

    @objc private func moveItem(_ g: UIPanGestureRecognizer) {
        guard let v = g.view, let id = itemID(for: v), scale > 0 else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let dx = t.x / scale, dy = t.y / scale
        if let i = page.textBoxes.firstIndex(where: { $0.id == id }) {
            page.textBoxes[i].frame = page.textBoxes[i].frame.offsetBy(dx: dx, dy: dy)
        } else if let i = page.images.firstIndex(where: { $0.id == id }) {
            page.images[i].frame = page.images[i].frame.offsetBy(dx: dx, dy: dy)
        }
        layoutItems()
        if g.state == .ended { commitPage() }
    }

    @objc private func pinchItem(_ g: UIPinchGestureRecognizer) {
        guard let v = g.view, let id = itemID(for: v), let i = page.images.firstIndex(where: { $0.id == id }) else { return }
        let f = page.images[i].frame
        let w = max(40, f.width * g.scale), h = max(40, f.height * g.scale)
        page.images[i].frame = CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
        g.scale = 1
        layoutItems()
        if g.state == .ended { commitPage() }
    }

    func textViewDidChange(_ tv: UITextView) {
        guard let id = itemID(for: tv), let i = page.textBoxes.firstIndex(where: { $0.id == id }), scale > 0 else { return }
        page.textBoxes[i].text = tv.text
        let fit = tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .greatestFiniteMagnitude))
        page.textBoxes[i].frame.size.height = max(40, fit.height / scale)
        layoutItems()
        commitPage()
    }

    func textViewDidEndEditing(_ tv: UITextView) {
        guard let id = itemID(for: tv) else { return }
        if tv.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            page.textBoxes.removeAll { $0.id == id }
            syncItems()
            commitPage()
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let v = interaction.view, let id = itemID(for: v) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIAction] = []
            if let iv = v as? UIImageView, let img = iv.image {
                actions.append(UIAction(title: "Kopieren", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.image = img
                })
            }
            actions.append(UIAction(title: "Löschen", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                guard let self else { return }
                self.page.textBoxes.removeAll { $0.id == id }
                self.page.images.removeAll { $0.id == id }
                self.syncItems()
                self.commitPage()
            })
            return UIMenu(children: actions)
        }
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applying, scale > 0 else { return }
        pageDrawing = canvasView.drawing.transformed(using: toView.inverted())
        onDrawingChange?(pageDrawing)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        strokeCountAtToolStart = canvasView.drawing.strokes.count
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        if canvasView.tool is PKInkingTool,
           canvasView.drawing.strokes.count == strokeCountAtToolStart + 1,
           let last = canvasView.drawing.strokes.last {
            let replacement = mode == .shape ? ShapeRecognizer.shape(from: last)
                : (straighten ? ShapeRecognizer.straightLine(from: last) : nil)
            if let replacement {
                var d = canvasView.drawing
                d.strokes[d.strokes.count - 1] = replacement
                canvasView.drawing = d   // triggers drawingDidChange → saved
            }
        }
        onEndUsingTool?()
    }

    // MARK: Camera lasso – circle an area, it is copied as an image

    @objc private func cameraPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let path = UIBezierPath()
            path.move(to: p)
            lassoPath = path
            let l = CAShapeLayer()
            l.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
            l.strokeColor = UIColor.systemBlue.cgColor
            l.lineWidth = 2
            l.lineDashPattern = [6, 4]
            layer.addSublayer(l)
            lassoLayer = l
        case .changed:
            lassoPath?.addLine(to: p)
            lassoLayer?.path = lassoPath?.cgPath
        case .ended:
            guard let path = lassoPath else { return }
            path.close()
            lassoLayer?.removeFromSuperlayer()
            lassoLayer = nil
            lassoPath = nil
            capture(path)
        default:
            lassoLayer?.removeFromSuperlayer()
            lassoLayer = nil
            lassoPath = nil
        }
    }

    private func capture(_ path: UIBezierPath) {
        let rect = path.bounds.intersection(bounds)
        guard rect.width > 8, rect.height > 8 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min((window?.screen.scale ?? 2) * max(zoom, 1), 6)
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
            path.addClip()
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        onCapture?(image)

        let flash = CAShapeLayer()
        flash.path = path.cgPath
        flash.fillColor = UIColor.white.cgColor
        layer.addSublayer(flash)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.9
        a.toValue = 0
        a.duration = 0.35
        flash.opacity = 0
        flash.add(a, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { flash.removeFromSuperlayer() }
    }
}

extension UIColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
