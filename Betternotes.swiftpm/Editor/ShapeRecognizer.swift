import PencilKit
import UIKit

/// Turns hand-drawn strokes into clean shapes: lines, right angles, triangles,
/// rectangles (exact right angles, also rotated), polygons, circles and ellipses.
enum ShapeRecognizer {
    static func points(_ stroke: PKStroke) -> [CGPoint] {
        stroke.path.map { $0.location.applying(stroke.transform) }
    }

    /// Replaces a nearly straight stroke by an exact line between its end points (no hold needed).
    static func straightLine(from stroke: PKStroke) -> PKStroke? {
        let pts = points(stroke)
        guard pts.count >= 3, let a = pts.first, let b = pts.last else { return nil }
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 60 else { return nil }
        guard maxDeviation(pts, a, b) < max(3, len * 0.025) else { return nil }
        return make(snapLine(a, b), like: stroke, closed: false)
    }

    /// Best clean shape for the stroke, or nil if it doesn't look like one.
    static func shape(from stroke: PKStroke) -> PKStroke? {
        let pts = points(stroke)
        guard pts.count >= 3, let first = pts.first, let last = pts.last else { return nil }
        let box = pts.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let size = max(box.width, box.height)
        guard size > 20 else { return nil }
        let closed = dist(first, last) < size * 0.22

        var corners = simplify(pts, epsilon: size * 0.07)
        if !closed {
            if corners.count <= 2 || maxDeviation(pts, first, last) < size * 0.06 {
                return make(snapLine(first, last), like: stroke, closed: false)
            }
            if corners.count == 3 {
                return make(rightAngle(corners), like: stroke, closed: false)
            }
            return make(corners, like: stroke, closed: false)
        }

        if corners.count > 1, dist(corners[0], corners[corners.count - 1]) < size * 0.22 { corners.removeLast() }
        let polyError = meanDistance(pts, toPolygon: corners) / size
        let ellipse = ellipsePoints(box)
        let ellipseError = meanDistance(pts, toPolygon: ellipse) / size

        if corners.count >= 3, corners.count <= 6, polyError <= ellipseError * 1.1 {
            if corners.count == 4, let rect = rectangle(corners) { return make(rect, like: stroke, closed: true) }
            return make(corners, like: stroke, closed: true)
        }
        // Round: circle if nearly as wide as high, else ellipse.
        let ratio = min(box.width, box.height) / max(box.width, box.height)
        if ratio > 0.82 {
            let r = (box.width + box.height) / 4
            let c = CGPoint(x: box.midX, y: box.midY)
            return make(ellipsePoints(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                        like: stroke, closed: true, densify: false)
        }
        return make(ellipse, like: stroke, closed: true, densify: false)
    }

    // MARK: Geometry helpers

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx: CGFloat = b.x - a.x, dy: CGFloat = b.y - a.y
        let len2: CGFloat = dx * dx + dy * dy
        guard len2 > 0 else { return dist(p, a) }
        var t: CGFloat = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func maxDeviation(_ pts: [CGPoint], _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        var worst: CGFloat = 0
        for p in pts { worst = max(worst, distanceToSegment(p, a, b)) }
        return worst
    }

    private static func meanDistance(_ pts: [CGPoint], toPolygon poly: [CGPoint]) -> CGFloat {
        guard poly.count >= 2 else { return .greatestFiniteMagnitude }
        var total: CGFloat = 0
        for p in pts {
            var best = CGFloat.greatestFiniteMagnitude
            for i in 0..<poly.count {
                best = min(best, distanceToSegment(p, poly[i], poly[(i + 1) % poly.count]))
            }
            total += best
        }
        return total / CGFloat(pts.count)
    }

    /// Ramer–Douglas–Peucker polyline simplification → corner points.
    private static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2, let a = pts.first, let b = pts.last else { return pts }
        var index = 0
        var worst: CGFloat = 0
        for i in 1..<(pts.count - 1) {
            let d = distanceToSegment(pts[i], a, b)
            if d > worst { worst = d; index = i }
        }
        if worst <= epsilon { return [a, b] }
        let left = simplify(Array(pts[...index]), epsilon: epsilon)
        let right = simplify(Array(pts[index...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    /// Snaps nearly horizontal/vertical lines exactly.
    private static func snapLine(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let step = CGFloat.pi / 2
        let snapped = (angle / step).rounded() * step
        guard abs(angle - snapped) < 6 * .pi / 180 else { return [a, b] }
        let len = dist(a, b)
        return [a, CGPoint(x: a.x + len * cos(snapped), y: a.y + len * sin(snapped))]
    }

    /// Open stroke with one corner: if close to 90°, make it exactly 90°.
    private static func rightAngle(_ c: [CGPoint]) -> [CGPoint] {
        let a = c[0], m = c[1], b = c[2]
        let v1 = CGPoint(x: a.x - m.x, y: a.y - m.y), v2 = CGPoint(x: b.x - m.x, y: b.y - m.y)
        let l1 = hypot(v1.x, v1.y), l2 = hypot(v2.x, v2.y)
        guard l1 > 0, l2 > 0 else { return c }
        let cosA = (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)
        guard abs(acos(max(-1, min(1, cosA))) - .pi / 2) < 15 * .pi / 180 else { return c }
        // keep the first leg (snapped to axis if close), make the second perpendicular
        let leg = snapLine(m, a)[1]
        let d1 = CGPoint(x: (leg.x - m.x) / l1, y: (leg.y - m.y) / l1)
        var n = CGPoint(x: -d1.y, y: d1.x)
        if n.x * v2.x + n.y * v2.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
        return [leg, m, CGPoint(x: m.x + n.x * l2, y: m.y + n.y * l2)]
    }

    /// Four corners with roughly right angles → exact (possibly rotated) rectangle.
    private static func rectangle(_ c: [CGPoint]) -> [CGPoint]? {
        for i in 0..<4 {
            let p = c[(i + 3) % 4], m = c[i], n = c[(i + 1) % 4]
            let v1 = CGPoint(x: p.x - m.x, y: p.y - m.y), v2 = CGPoint(x: n.x - m.x, y: n.y - m.y)
            let l = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
            guard l > 0 else { return nil }
            let angle = acos(max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / l)))
            if abs(angle - .pi / 2) > 20 * .pi / 180 { return nil }
        }
        // orientation from the first edge, snapped to axis when close
        var theta = atan2(c[1].y - c[0].y, c[1].x - c[0].x)
        let snapped = (theta / (.pi / 2)).rounded() * (.pi / 2)
        if abs(theta - snapped) < 8 * .pi / 180 { theta = snapped }
        let w = (dist(c[0], c[1]) + dist(c[2], c[3])) / 2
        let h = (dist(c[1], c[2]) + dist(c[3], c[0])) / 2
        let center = CGPoint(x: c.map(\.x).reduce(0, +) / 4, y: c.map(\.y).reduce(0, +) / 4)
        let ux = CGPoint(x: cos(theta), y: sin(theta)), uy = CGPoint(x: -sin(theta), y: cos(theta))
        // keep the drawing direction of the second edge
        let side: CGFloat = ((c[2].x - c[1].x) * uy.x + (c[2].y - c[1].y) * uy.y) >= 0 ? 1 : -1
        let corners: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        return corners.map { sx, sy in
            CGPoint(x: center.x + sx * w / 2 * ux.x + sy * side * h / 2 * uy.x,
                    y: center.y + sx * w / 2 * ux.y + sy * side * h / 2 * uy.y)
        }
    }

    private static func ellipsePoints(_ box: CGRect, n: Int = 72) -> [CGPoint] {
        (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            return CGPoint(x: box.midX + box.width / 2 * cos(t), y: box.midY + box.height / 2 * sin(t))
        }
    }

    /// Builds a stroke along the polyline; edges are densified so PencilKit keeps sharp corners.
    private static func make(_ corners: [CGPoint], like stroke: PKStroke, closed: Bool, densify: Bool = true) -> PKStroke {
        var poly = closed ? corners + [corners[0]] : corners
        if densify {
            var dense: [CGPoint] = []
            for (p, q) in zip(poly, poly.dropFirst()) {
                for k in 0..<10 {
                    let t = CGFloat(k) / 10
                    dense.append(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
                }
            }
            dense.append(poly.last!)
            poly = dense
        }
        let template = stroke.path.first!
        let points = poly.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.005, size: template.size,
                          opacity: template.opacity, force: template.force,
                          azimuth: template.azimuth, altitude: template.altitude)
        }
        return PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}

/// Watches pencil touches without interfering with PencilKit and reports whether the
/// pencil rested in place just before it was lifted ("draw and hold" → shape).
final class HoldObserver: UIGestureRecognizer {
    var holdDuration: TimeInterval = 0.4
    private(set) var heldAtEnd = false
    /// Fires while the pencil is still down and has rested for `holdDuration`; gets all points so far.
    var onHold: (([CGPoint]) -> Void)?
    private(set) var points: [CGPoint] = []
    private var lastMoveTime: TimeInterval = 0
    private var lastPoint: CGPoint = .zero
    private var timer: Timer?
    private var fired = false

    private func restartTimer() {
        timer?.invalidate()
        guard onHold != nil, !fired else { return }
        timer = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
            guard let self, !self.fired, self.points.count > 2 else { return }
            self.fired = true
            self.onHold?(self.points)
        }
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        heldAtEnd = false
        fired = false
        lastPoint = t.location(in: view)
        lastMoveTime = t.timestamp
        points = [lastPoint]
        restartTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        for c in event.coalescedTouches(for: t) ?? [t] {
            let p = c.location(in: view)
            points.append(p)
            if hypot(p.x - lastPoint.x, p.y - lastPoint.y) > 3 {
                lastPoint = p
                lastMoveTime = c.timestamp
                restartTimer()
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        if let t = touches.first { heldAtEnd = t.timestamp - lastMoveTime >= holdDuration }
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        heldAtEnd = false
        state = .failed
    }
}
