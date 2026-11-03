import PencilKit
import UIKit

@MainActor
protocol DocumentPageProvider: AnyObject {
    func makePageView(for page: NotePage) -> PageCanvasView
    func configure(_ view: PageCanvasView, page: NotePage)
    /// Default writing space per side (page units); sets the shared on-screen scale.
    func defaultMargin(for page: NotePage) -> CGFloat
    /// Actual (possibly extended) writing space left and right.
    func margins(for page: NotePage) -> (left: CGFloat, right: CGFloat)
    func currentPageChanged(_ index: Int)
}

/// Vertically scrolling, zoomable stack of pages. Only pages near the visible area keep a
/// view, so notebooks with hundreds of pages stay light. Fingers scroll and zoom, the Pencil writes.
@MainActor
final class DocumentScrollView: UIScrollView, UIScrollViewDelegate {
    weak var provider: DocumentPageProvider?
    private let content = UIView()
    private(set) var pages: [NotePage] = []
    private var frames: [CGRect] = []
    private var views: [UUID: PageCanvasView] = [:]
    private var laidOutWidth: CGFloat = 0
    private var signature: [String] = []
    private(set) var currentIndex = 0
    private var shiftX: CGFloat = 0        // how far pages were moved right to fit left margins
    private var didCenter = false
    /// Zoom that is baked into the layout: after a pinch the pages are laid out again at the
    /// new size (zoomScale back to 1), so PencilKit and the paper render crisply instead of a
    /// scaled-up bitmap.
    private(set) var layoutZoom: CGFloat = 1
    private var pendingCenter: CGPoint?
    static let minZoom: CGFloat = 0.6, maxZoom: CGFloat = 3
    /// Extra writing space (in page widths) added on both sides while scrolling outwards –
    /// the area around the pages never ends.
    private(set) var extraLeft: CGFloat = 0
    private(set) var extraRight: CGFloat = 0
    private var growing = false
    private let spacing: CGFloat = 20

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 0.6
        maximumZoomScale = 3
        backgroundColor = PageBackground.surfaceColor
        delaysContentTouches = false
        let finger = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        panGestureRecognizer.allowedTouchTypes = finger
        pinchGestureRecognizer?.allowedTouchTypes = finger
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Data

    func setPages(_ new: [NotePage]) {
        let sig = new.map { p -> String in
            let m = provider?.margins(for: p) ?? (left: 0, right: 0)
            return "\(p.id)|\(p.width)|\(p.height)|\(m.left)|\(m.right)|\(provider?.defaultMargin(for: p) ?? 0)"
        }
        pages = new
        for (id, v) in views {
            // A page view is rebuilt when its layers change (other canvases, active layer).
            if let p = new.first(where: { $0.id == id }), Self.layerKey(p) == Self.layerKey(v.page) {
                v.update(page: p)
            } else {
                v.removeFromSuperview()
                views[id] = nil
            }
        }
        if views.isEmpty || views.count < pages.count { setNeedsLayout() }
        if sig != signature {
            signature = sig
            laidOutWidth = 0
            setNeedsLayout()
        }
    }

    private static func layerKey(_ p: NotePage) -> String {
        p.allLayers.map { "\($0.id)\($0.hidden)" }.joined() + "\(p.activeLayerID)"
    }

    /// Page view currently on screen for a page (nil when scrolled away).
    func pageView(for id: UUID) -> PageCanvasView? { views[id] }

    func forEachPageView(_ body: (PageCanvasView, NotePage) -> Void) {
        for p in pages { if let v = views[p.id] { body(v, p) } }
    }

    func scrollToPage(_ index: Int, animated: Bool = true) {
        guard frames.indices.contains(index) else { return }
        let y = max(0, frames[index].minY * zoomScale - spacing)
        setContentOffset(CGPoint(x: contentOffset.x, y: min(y, max(0, contentSize.height - bounds.height))), animated: animated)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.width != laidOutWidth { relayout() }
        updateVisiblePages()
    }

    private func relayout() {
        // Keep zoom and position when pages change size (e.g. the margin grows while writing).
        let zoom = zoomScale
        var offset = contentOffset
        if zoom != 1 { setZoomScale(1, animated: false) }
        defer {
            if zoom != 1 { setZoomScale(zoom, animated: false) }
            contentOffset = CGPoint(x: min(max(offset.x, -contentInset.left), max(0, contentSize.width - bounds.width)),
                                    y: offset.y)
        }
        laidOutWidth = bounds.width
        let side: CGFloat = 8
        let width = (bounds.width - 2 * side) * layoutZoom
        var y = spacing
        // Same scale as if every page had the default margins; extended margins make a page
        // wider than the screen (scroll sideways) instead of shrinking the paper.
        frames = pages.map { p in
            let d = provider?.defaultMargin(for: p) ?? 0
            let m = provider?.margins(for: p) ?? (left: d, right: d)
            let k = width / (p.width + 2 * d)
            let f = CGRect(x: side + (d - m.left) * k, y: y, width: (p.width + m.left + m.right) * k, height: p.height * k)
            y += f.height + spacing
            return f
        }
        let minX = min(side, frames.map(\.minX).min() ?? side)
        let shift = side - minX
        frames = frames.map { $0.offsetBy(dx: shift, dy: 0) }
        if let c = pendingCenter {
            // after a pinch: keep the same spot under the fingers
            offset = CGPoint(x: c.x - bounds.width / 2, y: c.y - bounds.height / 2)
            offset.y = min(max(offset.y, 0), max(0, y - bounds.height))
            pendingCenter = nil
        } else if didCenter {
            // margin grew on the left: keep the view where it was instead of jumping
            offset.x += (shift - shiftX) * zoom
        } else if !pages.isEmpty {
            // start with the paper of the first page centred
            offset.x = max(0, shift + side + (bounds.width - 2 * side) / 2 - bounds.width / 2)
            didCenter = true
        }
        shiftX = shift
        let maxX = (frames.map(\.maxX).max() ?? bounds.width) + side
        content.frame = CGRect(x: 0, y: 0, width: max(bounds.width, maxX), height: y)
        // one continuous, subtly dotted surface behind all pages (scales with zoom)
        if let p = pages.first {
            let d = provider?.defaultMargin(for: p) ?? 0
            content.backgroundColor = PageBackground.dotPattern(scale: width / (p.width + 2 * d), originX: 0)
        }
        contentSize = content.frame.size
        for (i, p) in pages.enumerated() { views[p.id]?.frame = frames[i] }
    }

    private func updateVisiblePages() {
        guard frames.count == pages.count else { return }
        let visible = convert(bounds, to: content)
        let preload = visible.insetBy(dx: 0, dy: -visible.height * 0.75)
        for (i, f) in frames.enumerated() {
            let page = pages[i]
            if f.intersects(preload) {
                if views[page.id] == nil, let v = provider?.makePageView(for: page) {
                    v.frame = f
                    content.addSubview(v)
                    views[page.id] = v
                    v.setZoom(zoomScale)
                }
            } else if let v = views[page.id] {
                v.removeFromSuperview()
                views[page.id] = nil
            }
        }
        let center = convert(CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.4), to: content).y
        let index = frames.firstIndex { $0.maxY + spacing / 2 > center } ?? max(0, frames.count - 1)
        if index != currentIndex {
            currentIndex = index
            provider?.currentPageChanged(index)
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Centre the pages when zoomed out (frame of a transformed view must not be set).
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        contentInset = UIEdgeInsets(top: 0, left: dx, bottom: 0, right: dx)
        updateVisiblePages()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard abs(scale - 1) > 0.01 else { return }
        let newZoom = min(max(layoutZoom * scale, Self.minZoom), Self.maxZoom)
        let k = newZoom / layoutZoom
        // visible centre in (unzoomed) layout coordinates
        let center = CGPoint(x: (contentOffset.x + bounds.width / 2) / scale,
                             y: (contentOffset.y + bounds.height / 2) / scale)
        setZoomScale(1, animated: false)
        contentInset = .zero
        layoutZoom = newZoom
        minimumZoomScale = Self.minZoom / layoutZoom
        maximumZoomScale = Self.maxZoom / layoutZoom
        pendingCenter = CGPoint(x: center.x * k, y: center.y * k)
        laidOutWidth = 0
        setNeedsLayout()
        layoutIfNeeded()
        for v in views.values { v.setZoom(1) }
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        contentInset = UIEdgeInsets(top: 0, left: dx, bottom: 0, right: dx)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisiblePages()
    }

    /// Near the left/right end of the content: add another page width of space on that side.
    private func growIfNearHorizontalEdge() {
        guard !growing, !pages.isEmpty, bounds.width > 0, contentSize.width > bounds.width else { return }
        let nearRight = contentOffset.x + bounds.width > contentSize.width - bounds.width * 0.6
        let nearLeft = contentOffset.x < bounds.width * 0.6 - contentInset.left
        guard nearRight || nearLeft else { return }
        growing = true
        if nearRight { extraRight += 1 }
        if nearLeft { extraLeft += 1 }
        let current = pages
        signature = []            // force relayout with the bigger margins
        setPages(current)
        for p in pages { if let v = views[p.id] { provider?.configure(v, page: p) } }
        layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.growing = false }
    }

    // Fingers on movable items (text boxes, images) move the item instead of scrolling.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer {
            var v = hitTest(g.location(in: self), with: nil)
            while let view = v {
                if view.accessibilityIdentifier == "bn.item", view.isUserInteractionEnabled,
                   view.superview?.isUserInteractionEnabled == true { return false }
                if view === self { break }
                v = view.superview
            }
        }
        return super.gestureRecognizerShouldBegin(g)
    }
}
