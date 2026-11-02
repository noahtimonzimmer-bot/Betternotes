import PencilKit
import UIKit

/// One page: paper (PDF, template or blank) in the middle, free writing margin left and right,
/// images and text boxes, and a PencilKit canvas spanning everything. Drawings and items are
/// kept in page coordinates (x < 0 or x > page width = margin), independent of screen scale.
@MainActor
final class PageCanvasView: UIView, PKCanvasViewDelegate, UITextViewDelegate, UIContextMenuInteractionDelegate,
                            UIEditMenuInteractionDelegate {
    static let strokesPasteboardType = "com.betternotes.strokes"
    enum Mode { case ink, shape, objects, camera, lasso }

    let canvas = PKCanvasView()
    private let marginBackground = UIView()
    private let paper = UIImageView()
    private let itemsLayer = UIView()
    private var textViews: [UUID: UITextView] = [:]
    private var imageViews: [UUID: UIImageView] = [:]

    private(set) var page: NotePage
    /// Ink of the active layer (page coordinates). `canvas` edits this layer.
    private(set) var pageDrawing: PKDrawing
    let activeLayerID: UUID
    /// Other visible layers: shown, not editable.
    private var layerCanvases: [(id: UUID, canvas: PKCanvasView, drawing: PKDrawing)] = []
    var marginLeft: CGFloat = 0 { didSet { if marginLeft != oldValue { scale = 0; setNeedsLayout() } } }
    var marginRight: CGFloat = 0 { didSet { if marginRight != oldValue { scale = 0; setNeedsLayout() } } }
    /// Writing close to an outer edge adds this much space on that side (page units); 0 = fixed.
    var growStep: CGFloat = 0
    var straighten = true
    /// Draw a shape, rest the pencil briefly, lift → clean shape (any pen).
    var holdToShape = true
    private let holdObserver = HoldObserver(target: nil, action: nil)
    /// Set when the shape was already placed while the pencil was resting.
    private var snappedDuringHold = false
    /// Shape placed while holding, adjustable until the pencil lifts.
    private var adjusting: (index: Int, stroke: PKStroke, center: CGPoint, anchor: CGPoint)?
    /// When false, only the Pencil drives the camera lasso (fingers keep scrolling).
    var fingerDraws = false {
        didSet {
            var types = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            if fingerDraws { types.append(NSNumber(value: UITouch.TouchType.direct.rawValue)) }
            cameraGesture.allowedTouchTypes = types
            selectGesture.allowedTouchTypes = types
            holdObserver.allowedTouchTypes = types
        }
    }
    var mode: Mode = .ink { didSet { applyMode() } }

    var onDrawingChange: ((UUID, PKDrawing) -> Void)?
    var onRequestCrop: ((UUID) -> Void)?
    /// Stores pasted image data as an attachment, returns the file name.
    var addAttachment: ((Data) -> String)?
    private lazy var pasteMenu = UIEditMenuInteraction(delegate: self)
    private lazy var pressGesture = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
    private var pastePoint: CGPoint = .zero

    // Object selection (photos and text boxes): tap to select, drag to move, handle to resize.
    fileprivate var selectedObject: UUID?
    fileprivate let objectOverlay = UIView()
    fileprivate let objectHandle = UIView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
    fileprivate let objectBar = UIStackView()
    fileprivate lazy var objectTap = UITapGestureRecognizer(target: self, action: #selector(objectTapped(_:)))
    fileprivate var editingText: UUID?
    var onPageChange: ((NotePage) -> Void)?
    var onEndUsingTool: (() -> Void)?
    var onCapture: ((UIImage) -> Void)?
    /// Renders the paper at the given pixel width (async); called again when zooming.
    var backgroundRenderer: ((CGFloat, @escaping (UIImage?) -> Void) -> Void)? { didSet { renderedWidth = 0; setNeedsLayout() } }
    var imageLoader: ((String) -> UIImage?)? {
        didSet { for item in page.images { imageViews[item.id]?.image = imageLoader?(item.file) } }
    }

    private var scale: CGFloat = 0
    private var marginPatternScale: CGFloat = 0
    private var zoom: CGFloat = 1
    private var renderedWidth: CGFloat = 0
    private var applying = false
    private var strokeCountAtToolStart = 0

    private lazy var cameraGesture = UIPanGestureRecognizer(target: self, action: #selector(cameraPan(_:)))
    private lazy var newTextGesture = UITapGestureRecognizer(target: self, action: #selector(tapToCreateText(_:)))
    private var lassoPath: UIBezierPath?
    private var lassoLayer: CAShapeLayer?

    // Selection lasso
    private lazy var selectGesture = UIPanGestureRecognizer(target: self, action: #selector(selectPan(_:)))
    private lazy var clearSelectionTap = UITapGestureRecognizer(target: self, action: #selector(tapOutsideSelection(_:)))
    private var selected: [Int] = []
    private var selectionBase: [PKStroke] = []
    private let selectionLayer = CAShapeLayer()
    private let resizeHandle = UIView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
    private let selectionBar = UIStackView()
    private enum SelectDrag { case lasso, move(CGPoint), resize(anchor: CGPoint, start: CGPoint) }
    private var selectDrag: SelectDrag?

    init(page: NotePage, layerDrawings: [UUID: PKDrawing]) {
        self.page = page
        self.activeLayerID = page.activeLayerID
        self.pageDrawing = layerDrawings[page.activeLayerID] ?? PKDrawing()
        super.init(frame: .zero)
        backgroundColor = .clear

        marginBackground.backgroundColor = UIColor(white: 0.975, alpha: 1)
        marginBackground.layer.cornerRadius = 10
        marginBackground.layer.cornerCurve = .continuous
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
        // Layers bottom → top; only the active one takes input.
        for layer in page.allLayers {
            if layer.id == activeLayerID {
                addSubview(canvas)
            } else if !layer.hidden {
                let c = PKCanvasView()
                c.backgroundColor = .clear
                c.isOpaque = false
                c.isScrollEnabled = false
                c.isUserInteractionEnabled = false
                addSubview(c)
                layerCanvases.append((layer.id, c, layerDrawings[layer.id] ?? PKDrawing()))
            }
        }
        if page.allLayers.first(where: { $0.id == activeLayerID })?.hidden == true { canvas.isHidden = true }
        setupSelectionUI()
        setupObjectSelection()
        addInteraction(pasteMenu)
        pressGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pressGesture.minimumPressDuration = 0.5
        addGestureRecognizer(pressGesture)
        holdObserver.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        canvas.addGestureRecognizer(holdObserver)
        holdObserver.onHold = { [weak self] pts in self?.snapWhileHolding(pts) }
        holdObserver.onMoveAfterHold = { [weak self] p in self?.adjustShape(to: p) }
        holdObserver.onEndAfterHold = { [weak self] in self?.finishSnap() }

        cameraGesture.isEnabled = false
        cameraGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(cameraGesture)
        newTextGesture.isEnabled = false
        itemsLayer.addGestureRecognizer(newTextGesture)

        syncItems()
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Geometry

    private var toView: CGAffineTransform {
        CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: marginLeft, y: 0)
    }

    func viewRect(_ r: CGRect) -> CGRect { r.applying(toView) }
    func pagePoint(_ p: CGPoint) -> CGPoint { p.applying(toView.inverted()) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = bounds.width / (page.size.width + marginLeft + marginRight)
        guard s.isFinite, s > 0 else { return }
        let changed = s != scale
        scale = s
        marginBackground.frame = bounds
        marginBackground.isHidden = marginLeft + marginRight == 0
        if changed || marginPatternScale != s {
            marginPatternScale = s
            marginBackground.backgroundColor = PageBackground.dotPattern(scale: s, originX: marginLeft * s)
        }
        paper.frame = viewRect(CGRect(origin: .zero, size: page.size))
        itemsLayer.frame = bounds
        canvas.frame = bounds
        for l in layerCanvases { l.canvas.frame = bounds }
        layoutItems()
        layoutObjectSelection()
        if changed {
            applying = true
            canvas.drawing = pageDrawing.transformed(using: toView)
            for l in layerCanvases { l.canvas.drawing = l.drawing.transformed(using: toView) }
            applying = false
            clearSelection()
        }
        requestBackgroundIfNeeded()
    }

    /// Called by the document view when the zoom level settles.
    func setZoom(_ z: CGFloat) {
        zoom = z
        let screen = window?.screen.scale ?? 2
        canvas.contentScaleFactor = min(screen * max(z, 1), 8)
        for l in layerCanvases { l.canvas.contentScaleFactor = canvas.contentScaleFactor }
        updateSelectionUI()
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
        canvas.isUserInteractionEnabled = (mode == .ink || mode == .shape) && selectedObject == nil && editingText == nil
        // fingers always select objects; the pencil too when it is not drawing
        var tapTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        if mode == .objects || mode == .lasso { tapTypes.append(NSNumber(value: UITouch.TouchType.pencil.rawValue)) }
        objectTap.allowedTouchTypes = tapTypes
        cameraGesture.isEnabled = mode == .camera
        selectGesture.isEnabled = mode == .lasso
        clearSelectionTap.isEnabled = mode == .lasso
        if mode != .lasso { clearSelection() }
        newTextGesture.isEnabled = objects
        itemsLayer.isUserInteractionEnabled = objects || editingText != nil
        for (id, tv) in textViews {
            let editable = objects || id == editingText
            tv.isEditable = editable
            tv.isSelectable = editable
            if !editable, tv.isFirstResponder { tv.resignFirstResponder() }
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
        let box = TextBox(frame: CGRect(x: p.x, y: p.y - 20, width: min(600, page.size.width - p.x + marginRight), height: 60))
        page.textBoxes.append(box)
        syncItems()
        commitPage()
        // after layout, so the text view has its frame and the keyboard can attach
        DispatchQueue.main.async { [weak self] in
            self?.layoutItems()
            self?.textViews[box.id]?.becomeFirstResponder()
        }
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
        if editingText == id {
            editingText = nil
            applyMode()
        }
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
                actions.append(UIAction(title: "Zuschneiden", image: UIImage(systemName: "crop")) { _ in
                    self?.onRequestCrop?(id)
                })
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
        onDrawingChange?(activeLayerID, pageDrawing)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        strokeCountAtToolStart = canvasView.drawing.strokes.count
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        // Next run-loop turn: the stroke is committed and the hold observer has seen touchesEnded.
        let expected = strokeCountAtToolStart + 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.snappedDuringHold {
                self.snappedDuringHold = false
            } else if canvasView.tool is PKInkingTool,
               canvasView.drawing.strokes.count == expected,
               let last = canvasView.drawing.strokes.last {
                let held = self.holdToShape && self.holdObserver.heldAtEnd
                let replacement = (self.mode == .shape || held) ? ShapeRecognizer.shape(from: last)
                    : (self.straighten ? ShapeRecognizer.straightLine(from: last) : nil)
                if let replacement {
                    var d = canvasView.drawing
                    d.strokes[d.strokes.count - 1] = replacement
                    canvasView.drawing = d   // triggers drawingDidChange → saved
                }
            }
            self.growIfNeeded(canvasView)
            self.onEndUsingTool?()
        }
    }

    /// Pencil rested while drawing: cancel the live PencilKit stroke and put the clean shape
    /// in its place right away (the pencil is still down), with a small haptic tick.
    private func snapWhileHolding(_ pts: [CGPoint]) {
        guard holdToShape || mode == .shape, let ink = canvas.tool as? PKInkingTool else { return }
        let size = CGSize(width: ink.width, height: ink.width)
        let raw = pts.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.005, size: size,
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let rawStroke = PKStroke(ink: ink.ink, path: PKStrokePath(controlPoints: raw, creationDate: Date()))
        guard ShapeRecognizer.shape(from: rawStroke) != nil else { return }
        let base = strokeCountAtToolStart
        snappedDuringHold = true
        // Toggling the drawing gesture ends the stroke in progress.
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.drawingGestureRecognizer.isEnabled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var d = self.canvas.drawing
            // PencilKit usually commits the partial stroke: use it (real width and pressure) and remove it.
            var source = rawStroke
            if d.strokes.count > base {
                source = d.strokes[base]
                d.strokes.removeLast(d.strokes.count - base)
            } else if let similar = d.strokes.last(where: { $0.ink.inkType == ink.inkType }) {
                source = Self.restyled(rawStroke, like: similar)
            }
            guard let shape = ShapeRecognizer.shape(from: source) ?? ShapeRecognizer.shape(from: rawStroke) else {
                self.snappedDuringHold = false
                return
            }
            d.strokes.append(shape)
            self.canvas.drawing = d
            let b = shape.renderBounds
            self.adjusting = (d.strokes.count - 1, shape, CGPoint(x: b.midX, y: b.midY), pts.last ?? .zero)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// Raw points with the point size/force/opacity of an existing stroke of the same pen.
    private static func restyled(_ raw: PKStroke, like model: PKStroke) -> PKStroke {
        let sizes = model.path.map(\.size.width).sorted()
        let w = sizes.isEmpty ? raw.path.first?.size.width ?? 2 : sizes[sizes.count / 2]
        let ref = model.path.first
        let pts = raw.path.enumerated().map { i, p in
            PKStrokePoint(location: p.location, timeOffset: TimeInterval(i) * 0.005, size: CGSize(width: w, height: w),
                          opacity: ref?.opacity ?? 1, force: ref?.force ?? 1,
                          azimuth: ref?.azimuth ?? 0, altitude: ref?.altitude ?? .pi / 2)
        }
        return PKStroke(ink: raw.ink, path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    /// Pencil lifted after a snap: make sure exactly the shape remains (PencilKit can deliver the
    /// cancelled stroke late, which could duplicate or replace it), then save.
    private func finishSnap() {
        guard let a = adjusting else { return }
        adjusting = nil
        let finalShape: PKStroke = canvas.drawing.strokes.indices.contains(a.index) ? canvas.drawing.strokes[a.index] : a.stroke
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            var d = self.canvas.drawing
            if d.strokes.count > a.index + 1 { d.strokes.removeLast(d.strokes.count - a.index - 1) }
            if d.strokes.count <= a.index { d.strokes.append(finalShape) } else { d.strokes[a.index] = finalShape }
            self.canvas.drawing = d   // saved via drawingDidChange
        }
    }

    /// GoodNotes-style: keep the pencil down after the shape appears and drag to scale/rotate it.
    private func adjustShape(to p: CGPoint) {
        guard let a = adjusting else { return }
        let v0 = CGPoint(x: a.anchor.x - a.center.x, y: a.anchor.y - a.center.y)
        let v1 = CGPoint(x: p.x - a.center.x, y: p.y - a.center.y)
        let l0 = hypot(v0.x, v0.y)
        guard l0 > 4 else { return }
        let scale = max(0.1, hypot(v1.x, v1.y) / l0)
        var angle = atan2(v1.y, v1.x) - atan2(v0.y, v0.x)
        let snapped = (angle / (.pi / 2)).rounded() * (.pi / 2)
        if abs(angle - snapped) < 5 * .pi / 180 { angle = snapped }
        var t = CGAffineTransform(translationX: a.center.x, y: a.center.y)
        t = t.rotated(by: angle).scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -a.center.x, y: -a.center.y)
        var s = a.stroke
        s.transform = a.stroke.transform.concatenating(t)
        var d = canvas.drawing
        guard d.strokes.indices.contains(a.index) else { return }
        d.strokes[a.index] = s
        canvas.drawing = d
    }

    /// Endless margin: ink near the outer edge extends the writing space on that side.
    private func growIfNeeded(_ canvasView: PKCanvasView) {
        guard growStep > 0, scale > 0, canvasView.tool is PKInkingTool,
              let last = canvasView.drawing.strokes.last else { return }
        let b = last.renderBounds.applying(toView.inverted())
        let trigger = growStep * 0.35
        var p = page
        if b.maxX > page.size.width + marginRight - trigger {
            p.marginRight = Double(b.maxX - page.size.width + growStep)
        }
        if b.minX < -marginLeft + trigger {
            p.marginLeft = Double(-b.minX + growStep)
        }
        if p != page {
            page = p
            commitPage()   // document view relayouts; margins are applied via configure
        }
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
        // The drawn loop only marks the area; the photo is its bounding rectangle.
        let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        onCapture?(image)

        let flash = CAShapeLayer()
        flash.path = UIBezierPath(rect: rect).cgPath
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

// MARK: - Selection lasso (move, resize, recolour, to text, copy, delete)

extension PageCanvasView {
    fileprivate func setupSelectionUI() {
        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.05).cgColor
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [6, 4]
        selectionLayer.isHidden = true
        layer.addSublayer(selectionLayer)

        resizeHandle.backgroundColor = .systemBlue
        resizeHandle.layer.cornerRadius = 14
        resizeHandle.layer.borderColor = UIColor.white.cgColor
        resizeHandle.layer.borderWidth = 3
        resizeHandle.isHidden = true
        resizeHandle.isUserInteractionEnabled = false
        addSubview(resizeHandle)

        selectionBar.axis = .horizontal
        selectionBar.spacing = 4
        selectionBar.isLayoutMarginsRelativeArrangement = true
        selectionBar.layoutMargins = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        selectionBar.backgroundColor = .secondarySystemBackground
        selectionBar.layer.cornerRadius = 12
        selectionBar.layer.shadowOpacity = 0.2
        selectionBar.layer.shadowRadius = 6
        selectionBar.isHidden = true

        let colors = UIButton(type: .system)
        colors.setImage(UIImage(systemName: "paintpalette"), for: .normal)
        colors.showsMenuAsPrimaryAction = true
        colors.menu = UIMenu(title: "Farbe", children: ToolController.palette.map { c in
            UIAction(title: "", image: UIImage(systemName: "circle.fill")?.withTintColor(c, renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.recolorSelection(c)
            }
        })
        selectionBar.addArrangedSubview(colors)
        selectionBar.addArrangedSubview(barButton("textformat", "In Text umwandeln") { [weak self] in self?.selectionToText() })
        selectionBar.addArrangedSubview(barButton("doc.on.doc", "Als Bild kopieren") { [weak self] in self?.copySelection() })
        selectionBar.addArrangedSubview(barButton("trash", "Löschen") { [weak self] in self?.deleteSelection() })
        addSubview(selectionBar)

        selectGesture.isEnabled = false
        selectGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(selectGesture)
        clearSelectionTap.isEnabled = false
        addGestureRecognizer(clearSelectionTap)
    }

    private func barButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.accessibilityLabel = label
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        return b
    }

    fileprivate var selectionRect: CGRect {
        let strokes = canvas.drawing.strokes
        var r = CGRect.null
        for i in selected where strokes.indices.contains(i) { r = r.union(strokes[i].renderBounds) }
        return r.isNull ? r : r.insetBy(dx: -8, dy: -8)
    }

    fileprivate func updateSelectionUI() {
        let r = selectionRect
        let hidden = selected.isEmpty || r.isNull
        selectionLayer.isHidden = hidden
        resizeHandle.isHidden = hidden
        selectionBar.isHidden = hidden
        guard !hidden else { return }
        selectionLayer.path = UIBezierPath(roundedRect: r, cornerRadius: 6).cgPath
        resizeHandle.center = CGPoint(x: r.maxX, y: r.maxY)
        let size = selectionBar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        var x = r.midX - size.width / 2
        x = min(max(x, 4), max(4, bounds.width - size.width - 4))
        let y = r.minY - size.height - 10 > 0 ? r.minY - size.height - 10 : r.maxY + 16
        selectionBar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        bringSubviewToFront(selectionBar)
        bringSubviewToFront(resizeHandle)
    }

    func clearSelection() {
        selected = []
        selectionBase = []
        updateSelectionUI()
    }

    private func saveCanvas() {
        pageDrawing = canvas.drawing.transformed(using: toView.inverted())
        onDrawingChange?(activeLayerID, pageDrawing)
    }

    @objc fileprivate func tapOutsideSelection(_ g: UITapGestureRecognizer) {
        if !selectionRect.contains(g.location(in: self)) { clearSelection() }
    }

    @objc fileprivate func selectPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let r = selectionRect
            if !selected.isEmpty, resizeHandle.frame.insetBy(dx: -14, dy: -14).contains(p) {
                selectDrag = .resize(anchor: CGPoint(x: r.minX, y: r.minY), start: p)
            } else if !selected.isEmpty, r.contains(p) {
                selectDrag = .move(p)
            } else {
                clearSelection()
                selectDrag = .lasso
                let path = UIBezierPath()
                path.move(to: p)
                lassoPath = path
                let l = CAShapeLayer()
                l.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
                l.strokeColor = UIColor.systemBlue.cgColor
                l.lineWidth = 1.5
                l.lineDashPattern = [5, 4]
                layer.addSublayer(l)
                lassoLayer = l
            }
        case .changed:
            switch selectDrag {
            case .lasso:
                lassoPath?.addLine(to: p)
                lassoLayer?.path = lassoPath?.cgPath
            case .move(let start):
                transformSelection(CGAffineTransform(translationX: p.x - start.x, y: p.y - start.y))
            case .resize(let anchor, let start):
                let d0 = max(hypot(start.x - anchor.x, start.y - anchor.y), 1)
                let k = max(0.1, hypot(p.x - anchor.x, p.y - anchor.y) / d0)
                var t = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                t = t.scaledBy(x: k, y: k).translatedBy(x: -anchor.x, y: -anchor.y)
                transformSelection(t)
            case .none:
                break
            }
        case .ended, .cancelled:
            switch selectDrag {
            case .lasso:
                lassoLayer?.removeFromSuperlayer()
                lassoLayer = nil
                if let path = lassoPath { path.close(); select(in: path) }
                lassoPath = nil
            case .move, .resize:
                selectionBase = selected.map { canvas.drawing.strokes[$0] }
                saveCanvas()
            case .none:
                break
            }
            selectDrag = nil
        default:
            break
        }
    }

    private func select(in path: UIBezierPath) {
        var hits: [Int] = []
        for (i, s) in canvas.drawing.strokes.enumerated() {
            let pts = s.path.map { $0.location.applying(s.transform) }
            guard !pts.isEmpty else { continue }
            let step = max(1, pts.count / 24)
            var inside = 0, total = 0
            for k in stride(from: 0, to: pts.count, by: step) {
                total += 1
                if path.contains(pts[k]) { inside += 1 }
            }
            if Double(inside) >= Double(total) * 0.6 { hits.append(i) }
        }
        selected = hits
        selectionBase = hits.map { canvas.drawing.strokes[$0] }
        updateSelectionUI()
    }

    private func transformSelection(_ t: CGAffineTransform) {
        var d = canvas.drawing
        for (k, i) in selected.enumerated() where d.strokes.indices.contains(i) {
            var s = selectionBase[k]
            s.transform = s.transform.concatenating(t)
            d.strokes[i] = s
        }
        applying = true
        canvas.drawing = d
        applying = false
        updateSelectionUI()
    }

    private func recolorSelection(_ color: UIColor) {
        var d = canvas.drawing
        for i in selected where d.strokes.indices.contains(i) {
            let ink = d.strokes[i].ink
            let c = ink.inkType == .marker ? color.withAlphaComponent(ink.color.cgColor.alpha) : color
            d.strokes[i].ink = PKInk(ink.inkType, color: c)
        }
        applying = true
        canvas.drawing = d
        applying = false
        selectionBase = selected.map { d.strokes[$0] }
        saveCanvas()
    }

    private func deleteSelection() {
        var d = canvas.drawing
        for i in selected.sorted(by: >) where d.strokes.indices.contains(i) { d.strokes.remove(at: i) }
        applying = true
        canvas.drawing = d
        applying = false
        clearSelection()
        saveCanvas()
    }

    private func copySelection() {
        let r = selectionRect
        guard !r.isNull else { return }
        let strokes = selected.compactMap { canvas.drawing.strokes.indices.contains($0) ? canvas.drawing.strokes[$0] : nil }
        let image = PKDrawing(strokes: strokes).image(from: r, scale: (window?.screen.scale ?? 2) * 2)
        onCapture?(image)   // shows the "copied" hint
        // Editable strokes (page units, top-left at 0,0) plus a picture for other apps.
        let pageStrokes = PKDrawing(strokes: strokes).transformed(using: toView.inverted())
        let b = pageStrokes.bounds
        let data = pageStrokes.transformed(using: CGAffineTransform(translationX: -b.minX, y: -b.minY)).dataRepresentation()
        var item: [String: Any] = [Self.strokesPasteboardType: data]
        if let png = image.pngData() { item["public.png"] = png }
        UIPasteboard.general.setItems([item])
    }

    /// Handwriting → text box at the same place (Vision, German/English).
    private func selectionToText() {
        let r = selectionRect
        guard !r.isNull, scale > 0 else { return }
        let strokes = selected.compactMap { canvas.drawing.strokes.indices.contains($0) ? canvas.drawing.strokes[$0] : nil }
        guard let first = strokes.first else { return }
        let drawing = PKDrawing(strokes: strokes)
        let indices = selected
        let colorHex = first.ink.color.withAlphaComponent(1).hexString
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) { HandwritingIndex.recognize(drawing) }.value
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            let pageRect = r.applying(self.toView.inverted())
            let lines = CGFloat(max(1, trimmed.components(separatedBy: "\n").count))
            let font = max(12, min(80, pageRect.height / lines * 0.62))
            var d = self.canvas.drawing
            for i in indices.sorted(by: >) where d.strokes.indices.contains(i) { d.strokes.remove(at: i) }
            self.applying = true
            self.canvas.drawing = d
            self.applying = false
            self.clearSelection()
            self.saveCanvas()
            self.page.textBoxes.append(TextBox(frame: pageRect, text: trimmed, fontSize: font, colorHex: colorHex))
            self.syncItems()
            self.commitPage()
        }
    }
}

// MARK: - Object selection (photos, text boxes)

extension PageCanvasView {
    fileprivate func setupObjectSelection() {
        objectOverlay.layer.borderColor = UIColor.systemBlue.cgColor
        objectOverlay.layer.borderWidth = 2
        objectOverlay.layer.cornerRadius = 4
        objectOverlay.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.04)
        objectOverlay.accessibilityIdentifier = "bn.item"   // fingers here move the object, not the page
        objectOverlay.isHidden = true
        objectOverlay.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moveObject(_:))))
        addSubview(objectOverlay)

        objectHandle.backgroundColor = .systemBlue
        objectHandle.layer.cornerRadius = 15
        objectHandle.layer.borderColor = UIColor.white.cgColor
        objectHandle.layer.borderWidth = 3
        objectHandle.accessibilityIdentifier = "bn.item"
        objectHandle.isHidden = true
        objectHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resizeObject(_:))))
        addSubview(objectHandle)

        objectBar.axis = .horizontal
        objectBar.spacing = 2
        objectBar.isLayoutMarginsRelativeArrangement = true
        objectBar.layoutMargins = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        objectBar.backgroundColor = .secondarySystemBackground
        objectBar.layer.cornerRadius = 12
        objectBar.layer.shadowOpacity = 0.2
        objectBar.layer.shadowRadius = 6
        objectBar.isHidden = true
        addSubview(objectBar)

        objectTap.cancelsTouchesInView = false
        addGestureRecognizer(objectTap)
    }

    private func objectFrame(_ id: UUID) -> CGRect? {
        page.textBoxes.first { $0.id == id }?.frame ?? page.images.first { $0.id == id }?.frame
    }

    @objc fileprivate func objectTapped(_ g: UITapGestureRecognizer) {
        guard scale > 0, editingText == nil else { return }
        let p = pagePoint(g.location(in: self))
        // text boxes lie above images; later items above earlier ones
        let hit = page.textBoxes.reversed().first { $0.frame.contains(p) }?.id
            ?? page.images.reversed().first { $0.frame.contains(p) }?.id
        if let hit {
            if mode == .objects, page.textBoxes.contains(where: { $0.id == hit }) { return }  // tap edits text there
            selectObject(hit)
        } else if selectedObject != nil {
            deselectObject()
        }
    }

    func selectObject(_ id: UUID) {
        selectedObject = id
        applyMode()
        rebuildObjectBar()
        layoutObjectSelection()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func deselectObject() {
        selectedObject = nil
        layoutObjectSelection()
        applyMode()
    }

    fileprivate func layoutObjectSelection() {
        guard let id = selectedObject, let f = objectFrame(id), scale > 0 else {
            if selectedObject != nil, scale > 0 {   // object was deleted elsewhere: unlock the pen
                selectedObject = nil
                applyMode()
            }
            objectOverlay.isHidden = true
            objectHandle.isHidden = true
            objectBar.isHidden = true
            return
        }
        let r = viewRect(f).insetBy(dx: -4, dy: -4)
        objectOverlay.frame = r
        objectHandle.center = CGPoint(x: r.maxX, y: r.maxY)
        let size = objectBar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let x = min(max(r.midX - size.width / 2, 4), max(4, bounds.width - size.width - 4))
        let y = r.minY - size.height - 10 > 0 ? r.minY - size.height - 10 : r.maxY + 20
        objectBar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        for v in [objectOverlay, objectHandle, objectBar] as [UIView] {
            v.isHidden = false
            bringSubviewToFront(v)
        }
    }

    private func rebuildObjectBar() {
        objectBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let id = selectedObject else { return }
        func add(_ symbol: String, _ label: String, _ action: @escaping () -> Void) {
            let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
            b.setImage(UIImage(systemName: symbol), for: .normal)
            b.accessibilityLabel = label
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            objectBar.addArrangedSubview(b)
        }
        if page.images.contains(where: { $0.id == id }) {
            add("crop", "Zuschneiden") { [weak self] in self?.deselectObject(); self?.onRequestCrop?(id) }
            add("doc.on.doc", "Kopieren") { [weak self] in
                if let v = self?.imageViews[id], let img = v.image { self?.onCapture?(img) }
            }
            add("square.3.layers.3d.top.filled", "Nach vorne") { [weak self] in self?.bringToFront(id) }
        } else {
            add("character.cursor.ibeam", "Bearbeiten") { [weak self] in self?.editText(id) }
            add("textformat.size.larger", "Größer") { [weak self] in self?.scaleFont(id, by: 1.15) }
            add("textformat.size.smaller", "Kleiner") { [weak self] in self?.scaleFont(id, by: 1 / 1.15) }
            add("doc.on.doc", "Kopieren") { [weak self] in
                UIPasteboard.general.string = self?.page.textBoxes.first { $0.id == id }?.text
            }
        }
        add("trash", "Löschen") { [weak self] in
            guard let self else { return }
            self.page.textBoxes.removeAll { $0.id == id }
            self.page.images.removeAll { $0.id == id }
            self.deselectObject()
            self.syncItems()
            self.commitPage()
        }
    }

    private func editText(_ id: UUID) {
        deselectObject()
        editingText = id
        applyMode()
        DispatchQueue.main.async { [weak self] in self?.textViews[id]?.becomeFirstResponder() }
    }

    private func scaleFont(_ id: UUID, by k: CGFloat) {
        guard let i = page.textBoxes.firstIndex(where: { $0.id == id }) else { return }
        page.textBoxes[i].fontSize = min(200, max(8, page.textBoxes[i].fontSize * k))
        layoutItems()
        if let tv = textViews[id], scale > 0 {
            let fit = tv.sizeThatFits(CGSize(width: tv.bounds.width, height: .greatestFiniteMagnitude))
            page.textBoxes[i].frame.size.height = max(30, fit.height / scale)
            layoutItems()
        }
        layoutObjectSelection()
        commitPage()
    }

    private func bringToFront(_ id: UUID) {
        guard let i = page.images.firstIndex(where: { $0.id == id }) else { return }
        let item = page.images.remove(at: i)
        page.images.append(item)
        if let v = imageViews[id] { itemsLayer.insertSubview(v, at: page.images.count - 1) }
        commitPage()
    }

    @objc fileprivate func moveObject(_ g: UIPanGestureRecognizer) {
        guard let id = selectedObject, scale > 0 else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let dx = t.x / scale, dy = t.y / scale
        if let i = page.textBoxes.firstIndex(where: { $0.id == id }) {
            page.textBoxes[i].frame = page.textBoxes[i].frame.offsetBy(dx: dx, dy: dy)
        } else if let i = page.images.firstIndex(where: { $0.id == id }) {
            page.images[i].frame = page.images[i].frame.offsetBy(dx: dx, dy: dy)
        }
        layoutItems()
        layoutObjectSelection()
        if g.state == .ended || g.state == .cancelled { commitPage() }
    }

    @objc fileprivate func resizeObject(_ g: UIPanGestureRecognizer) {
        guard let id = selectedObject, scale > 0 else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if let i = page.images.firstIndex(where: { $0.id == id }) {
            var f = page.images[i].frame
            let aspect = f.height / max(f.width, 1)
            f.size.width = max(40, f.width + t.x / scale)
            f.size.height = f.width * aspect          // photos keep their proportions
            page.images[i].frame = f
        } else if let i = page.textBoxes.firstIndex(where: { $0.id == id }) {
            var f = page.textBoxes[i].frame
            f.size.width = max(60, f.width + t.x / scale)
            f.size.height = max(30, f.height + t.y / scale)
            page.textBoxes[i].frame = f
        }
        layoutItems()
        layoutObjectSelection()
        if g.state == .ended || g.state == .cancelled { commitPage() }
    }
}

// MARK: - Long press → paste (strokes, image or text at that spot)

extension PageCanvasView {
    @objc fileprivate func longPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let pb = UIPasteboard.general
        guard pb.contains(pasteboardTypes: [Self.strokesPasteboardType]) || pb.hasImages || pb.hasStrings else { return }
        pastePoint = g.location(in: self)
        pasteMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: pastePoint))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [UIAction(title: "Einfügen", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste()
        }])
    }

    private func paste() {
        guard scale > 0 else { return }
        let at = pagePoint(pastePoint)
        let pb = UIPasteboard.general
        if let data = pb.data(forPasteboardType: Self.strokesPasteboardType), let pasted = try? PKDrawing(data: data) {
            let placed = pasted.transformed(using: CGAffineTransform(translationX: at.x, y: at.y))
            var d = canvas.drawing
            d.append(placed.transformed(using: toView))
            canvas.drawing = d   // saved via drawingDidChange
        } else if let img = pb.image, let data = img.pngData(), let name = addAttachment?(data) {
            let w = min(page.size.width * 0.6, img.size.width * 2)
            let h = w * img.size.height / max(img.size.width, 1)
            page.images.append(ImageItem(frame: CGRect(x: at.x, y: at.y, width: w, height: h), file: name))
            syncItems()
            commitPage()
        } else if let text = pb.string, !text.isEmpty {
            page.textBoxes.append(TextBox(frame: CGRect(x: at.x, y: at.y, width: 500, height: 60), text: text))
            syncItems()
            commitPage()
        }
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
