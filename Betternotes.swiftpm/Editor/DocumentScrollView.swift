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
    private let spacing: CGFloat = 20

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 0.6
        maximumZoomScale = 6
        backgroundColor = .systemGray6
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
            let m = provider?.margins(for: p) ?? (0, 0)
            return "\(p.id)|\(p.width)|\(p.height)|\(m.left)|\(m.right)|\(provider?.defaultMargin(for: p) ?? 0)"
        }
        pages = new
        for (id, v) in views {
            if let p = new.first(where: { $0.id == id }) { v.update(page: p) } else { v.removeFromSuperview(); views[id] = nil }
        }
        if sig != signature {
            signature = sig
            laidOutWidth = 0
            setNeedsLayout()
        }
    }

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
        let zoom = zoomScale, offset = contentOffset
        if zoom != 1 { setZoomScale(1, animated: false) }
        defer {
            if zoom != 1 {
                setZoomScale(zoom, animated: false)
                contentOffset = offset
            }
        }
        laidOutWidth = bounds.width
        let side: CGFloat = 8
        let width = bounds.width - 2 * side
        var y = spacing
        // Same scale as if every page had the default margins; extended margins make a page
        // wider than the screen (scroll sideways) instead of shrinking the paper.
        frames = pages.map { p in
            let d = provider?.defaultMargin(for: p) ?? 0
            let m = provider?.margins(for: p) ?? (d, d)
            let k = width / (p.width + 2 * d)
            let f = CGRect(x: side + (d - m.left) * k, y: y, width: (p.width + m.left + m.right) * k, height: p.height * k)
            y += f.height + spacing
            return f
        }
        let minX = min(side, frames.map(\.minX).min() ?? side)
        frames = frames.map { $0.offsetBy(dx: side - minX, dy: 0) }
        let maxX = (frames.map(\.maxX).max() ?? bounds.width) + side
        content.frame = CGRect(x: 0, y: 0, width: max(bounds.width, maxX), height: y)
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
        for v in views.values { v.setZoom(scale) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisiblePages() }

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
