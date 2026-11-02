import PencilKit
import UIKit

/// Turns hand-drawn strokes into clean lines, rectangles and ellipses.
enum ShapeRecognizer {
    static func points(_ stroke: PKStroke) -> [CGPoint] {
        stroke.path.map { $0.location.applying(stroke.transform) }
    }

    /// Replaces a nearly straight stroke by an exact line between its end points.
    static func straightLine(from stroke: PKStroke) -> PKStroke? {
        let pts = points(stroke)
        guard pts.count >= 3, let a = pts.first, let b = pts.last else { return nil }
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 60 else { return nil }
        guard deviation(pts, a, b) < max(3, len * 0.025) else { return nil }
        return make([a, b], like: stroke, closed: false)
    }

    /// Shape tool: open strokes become lines, closed strokes rectangles or ellipses.
    static func shape(from stroke: PKStroke) -> PKStroke? {
        let pts = points(stroke)
        guard pts.count >= 3, let a = pts.first, let b = pts.last else { return nil }
        let box = pts.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let size = max(box.width, box.height)
        guard size > 20 else { return nil }
        let closed = hypot(b.x - a.x, b.y - a.y) < size * 0.25
        if !closed { return make([a, b], like: stroke, closed: false) }

        let c = CGPoint(x: box.midX, y: box.midY)
        let rx = max(box.width / 2, 1), ry = max(box.height / 2, 1)
        let ellipseError = pts.map { p -> CGFloat in
            let nx = (p.x - c.x) / rx, ny = (p.y - c.y) / ry
            return abs(sqrt(nx * nx + ny * ny) - 1)
        }.reduce(0, +) / CGFloat(pts.count)
        let rectError = pts.map { p -> CGFloat in
            let dx = min(abs(p.x - box.minX), abs(p.x - box.maxX)) / rx
            let dy = min(abs(p.y - box.minY), abs(p.y - box.maxY)) / ry
            return min(dx, dy)
        }.reduce(0, +) / CGFloat(pts.count)

        if rectError < ellipseError {
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            return make(corners, like: stroke, closed: true)
        }
        let n = 72
        let ellipse = (0..<n).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            return CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t))
        }
        return make(ellipse, like: stroke, closed: true, densify: false)
    }

    private static func deviation(_ pts: [CGPoint], _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx: CGFloat = b.x - a.x
        let dy: CGFloat = b.y - a.y
        let len: CGFloat = max(hypot(dx, dy), 0.001)
        let offset: CGFloat = b.x * a.y - b.y * a.x
        var worst: CGFloat = 0
        for p in pts {
            let cross: CGFloat = dy * p.x - dx * p.y + offset
            worst = max(worst, abs(cross) / len)
        }
        return worst
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
